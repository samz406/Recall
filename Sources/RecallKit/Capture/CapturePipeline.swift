import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ScreenCaptureKit
@preconcurrency import Vision

public enum CapturePipelineError: LocalizedError {
    case screenRecordingPermissionRequired
    case noShareableWindow
    case captureExcluded(String)
    case duplicateCapture
    case screenshotUnavailable

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired: "需要在系统设置中授予屏幕与系统音频录制权限。"
        case .noShareableWindow: "找不到可供记录的当前窗口。"
        case .captureExcluded(let reason): reason
        case .duplicateCapture: "检测到与刚才相同的内容，已跳过重复记录。"
        case .screenshotUnavailable: "未能取得当前窗口的截图。"
        }
    }
}

@MainActor
public protocol ScreenCapturing {
    func capture(scope: CaptureScope) async throws -> CapturePayload
    func requestScreenRecordingAccess() -> Bool
}

@MainActor
public final class ScreenCaptureService: ScreenCapturing {
    public init() {}

    public func requestScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    public func capture(scope: CaptureScope) async throws -> CapturePayload {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName
        let bundleIdentifier = frontmost?.bundleIdentifier

        guard scope != .textOnly else {
            return CapturePayload(imageData: nil, sourceAppName: appName, sourceBundleIdentifier: bundleIdentifier, windowTitle: nil)
        }
        // CGPreflightScreenCaptureAccess can report a stale false result for a
        // newly re-signed development bundle even when TCC has granted access.
        // The user has explicitly requested this capture, so ScreenCaptureKit is
        // the authoritative permission check and will reject genuine denials.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false

        switch scope {
        case .selectedWindow:
            guard let selectedWindow = content.windows.first(where: { window in
                window.owningApplication?.bundleIdentifier == bundleIdentifier && window.isOnScreen && window.frame.width > 80 && window.frame.height > 80
            }) ?? content.windows.first(where: { $0.isOnScreen && $0.frame.width > 80 && $0.frame.height > 80 }) else {
                throw CapturePipelineError.noShareableWindow
            }
            let filter = SCContentFilter(desktopIndependentWindow: selectedWindow)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CapturePayload(
                imageData: NSImage(cgImage: image, size: .zero).pngData(),
                sourceAppName: appName,
                sourceBundleIdentifier: bundleIdentifier,
                windowTitle: selectedWindow.title
            )
        case .activeDisplay:
            guard let display = content.displays.first else { throw CapturePipelineError.noShareableWindow }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CapturePayload(
                imageData: NSImage(cgImage: image, size: .zero).pngData(),
                sourceAppName: appName,
                sourceBundleIdentifier: bundleIdentifier,
                windowTitle: nil
            )
        case .textOnly:
            fatalError("Text-only scope returns before ScreenCaptureKit is used.")
        }
    }
}

public protocol TextRecognizing: Sendable {
    func recognizeText(in imageData: Data) async throws -> String
}

public final class VisionTextRecognizer: TextRecognizing, @unchecked Sendable {
    public init() {}

    public func recognizeText(in imageData: Data) async throws -> String {
        guard let image = NSImage(data: imageData), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CapturePipelineError.screenshotUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
public final class CapturePipeline {
    private let store: FileMemoryStore
    private let storage: RecallStorage
    private let screenCapturer: any ScreenCapturing
    private let recognizer: any TextRecognizing
    private let privacyEngine: PrivacyEngine

    public init(
        store: FileMemoryStore,
        storage: RecallStorage,
        screenCapturer: any ScreenCapturing = ScreenCaptureService(),
        recognizer: any TextRecognizing = VisionTextRecognizer(),
        privacyEngine: PrivacyEngine = PrivacyEngine()
    ) {
        self.store = store
        self.storage = storage
        self.screenCapturer = screenCapturer
        self.recognizer = recognizer
        self.privacyEngine = privacyEngine
    }

    @discardableResult
    public func record(using rule: EventRule, userText: String? = nil) async throws -> CaptureRecord {
        let currentState = await store.snapshot()
        guard rule.isEnabled else {
            throw CapturePipelineError.captureExcluded("该事件模板目前未启用。")
        }
        let payload = try await screenCapturer.capture(scope: rule.scope)
        let decision = privacyEngine.decision(for: payload.sourceBundleIdentifier, settings: currentState.privacy)
        guard decision.mayCapture else {
            throw CapturePipelineError.captureExcluded(decision.reason ?? "该内容被隐私策略排除。")
        }
        if !rule.appAllowList.isEmpty,
           let bundleIdentifier = payload.sourceBundleIdentifier,
           !rule.appAllowList.contains(bundleIdentifier) {
            throw CapturePipelineError.captureExcluded("当前应用不在此事件的应用白名单中。")
        }

        let extractedText: String
        if let userText, !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            extractedText = userText
        } else if let imageData = payload.imageData {
            extractedText = try await recognizer.recognizeText(in: imageData)
        } else {
            extractedText = ""
        }
        let redactedText = privacyEngine.redact(extractedText)
        let digestSource = payload.imageData ?? Data(redactedText.utf8)
        let contentHash = SHA256.hash(data: digestSource).map { String(format: "%02x", $0) }.joined()
        guard !(await store.hasRecentHash(contentHash)) else { throw CapturePipelineError.duplicateCapture }

        let captureID = UUID()
        let imageRelativePath: String?
        if currentState.privacy.retainScreenshots, rule.retainImageDays > 0, let imageData = payload.imageData {
            imageRelativePath = try storage.saveScreenshot(imageData, captureID: captureID)
        } else {
            imageRelativePath = nil
        }

        let record = CaptureRecord(
            id: captureID,
            eventTemplate: rule.template,
            sourceAppName: payload.sourceAppName,
            sourceBundleIdentifier: payload.sourceBundleIdentifier,
            windowTitle: payload.windowTitle,
            imageRelativePath: imageRelativePath,
            contentHash: contentHash,
            isRedacted: redactedText != extractedText,
            ocrText: redactedText,
            summary: LocalSummary.make(from: redactedText),
            tags: LocalSummary.tags(from: redactedText)
        )
        try await store.addCapture(record)
        return record
    }

    public func removeCapture(_ record: CaptureRecord) async throws {
        _ = try await store.deleteCapture(id: record.id)
        if let imagePath = record.imageRelativePath {
            try storage.deleteScreenshot(relativePath: imagePath)
        }
    }
}

public enum LocalSummary {
    public static func make(from text: String) -> String? {
        let sentences = text
            .components(separatedBy: CharacterSet(charactersIn: "。！？!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return nil }
        let cues = ["完成", "通过", "决定", "结论", "待办", "下一步", "阻塞", "失败", "目标", "需要", "implemented", "passed", "decision", "todo"]
        let ranked = sentences.enumerated().sorted { lhs, rhs in
            let left = sentenceScore(lhs.element, position: lhs.offset, cues: cues)
            let right = sentenceScore(rhs.element, position: rhs.offset, cues: cues)
            return left == right ? lhs.offset < rhs.offset : left > right
        }
        let selected = ranked.prefix(2).sorted { $0.offset < $1.offset }.map(\.element)
        return String(selected.joined(separator: "；").prefix(240))
    }

    public static func tags(from text: String) -> [String] {
        let stopWords: Set<String> = ["今天", "当前", "这个", "那个", "可以", "需要", "已经", "然后", "页面", "用户", "window", "chrome", "safari", "chatgpt"]
        let tokens = text
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
            .filter { (2...32).contains($0.count) && !stopWords.contains($0.lowercased()) }
        let counts = Dictionary(grouping: tokens, by: { $0.lowercased() }).mapValues { $0.count }
        var seen: Set<String> = []
        return tokens
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { lhs, rhs in
                let left = counts[lhs.lowercased(), default: 0]
                let right = counts[rhs.lowercased(), default: 0]
                return left == right ? lhs.count < rhs.count : left > right
            }
            .prefix(8)
            .map { $0 }
    }

    private static func sentenceScore(_ sentence: String, position: Int, cues: [String]) -> Double {
        let normalized = sentence.lowercased()
        var score = max(0, 0.2 - Double(position) * 0.01)
        score += Double(cues.filter { normalized.contains($0) }.count) * 0.45
        if (18...180).contains(sentence.count) { score += 0.18 }
        if sentence.contains("://") || sentence.count > 300 { score -= 0.25 }
        return score
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
