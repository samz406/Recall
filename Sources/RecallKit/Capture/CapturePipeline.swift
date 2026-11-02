import AppKit
import CoreGraphics
import CryptoKit
import Foundation
// Older SDKs omit concurrency annotations for SCShareableContent. Its objects
// remain confined to the @MainActor ScreenCaptureService below.
@preconcurrency import ScreenCaptureKit
@preconcurrency import Vision

public enum CapturePipelineError: LocalizedError {
    case screenRecordingPermissionRequired
    case noShareableWindow
    case captureExcluded(String)
    case duplicateCapture
    case suppressedByUser
    case screenshotUnavailable

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired: "需要在系统设置中授予屏幕与系统音频录制权限。"
        case .noShareableWindow: "找不到可供记录的当前窗口。"
        case .captureExcluded(let reason): reason
        case .duplicateCapture: "检测到与刚才相同的内容，已跳过重复记录。"
        case .suppressedByUser: "这条内容符合你设置的忽略规则，已跳过记录。"
        case .screenshotUnavailable: "未能取得当前窗口的截图。"
        }
    }
}

@MainActor
public protocol ScreenCapturing {
    func capture(scope: CaptureScope) async throws -> CapturePayload
    func requestScreenRecordingAccess() -> Bool
    func currentTarget() -> CaptureTarget?
    func capture(scope: CaptureScope, target: CaptureTarget?) async throws -> CapturePayload
}
public extension ScreenCapturing {
    func currentTarget() -> CaptureTarget? { nil }
    func capture(scope: CaptureScope, target: CaptureTarget?) async throws -> CapturePayload { try await capture(scope: scope) }
}

@MainActor
public final class ScreenCaptureService: ScreenCapturing {
    public init() {}

    public func requestScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    public func capture(scope: CaptureScope) async throws -> CapturePayload {
        try await capture(scope: scope, target: currentTarget())
    }
    public func currentTarget() -> CaptureTarget? { CaptureTargetResolver.current() }
    public func capture(scope: CaptureScope, target: CaptureTarget?) async throws -> CapturePayload {
        let appName = target?.appName
        let bundleIdentifier = target?.bundleIdentifier

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
            guard let target, let selectedWindow = content.windows.first(where: {
                $0.windowID == target.windowID && $0.owningApplication?.processID == target.processID
                    && $0.owningApplication?.bundleIdentifier == target.bundleIdentifier && $0.isOnScreen
            }) else { throw CapturePipelineError.noShareableWindow }
            let filter = SCContentFilter(desktopIndependentWindow: selectedWindow)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CapturePayload(
                imageData: NSImage(cgImage: image, size: .zero).pngData(),
                sourceAppName: appName,
                sourceBundleIdentifier: bundleIdentifier,
                windowTitle: selectedWindow.title
            )
        case .activeDisplay:
            guard let display = content.displays.first(where: { $0.displayID == target?.displayID }) else { throw CapturePipelineError.noShareableWindow }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            // Without a title a full-display record cannot be linked to the same session's window captures.
            let frontTitle = content.windows.first(where: { window in
                window.owningApplication?.bundleIdentifier == bundleIdentifier && window.isOnScreen && window.windowLayer == 0
                    && window.frame.width > 80 && window.frame.height > 80 && window.title?.isEmpty == false
            })?.title
            return CapturePayload(
                imageData: NSImage(cgImage: image, size: .zero).pngData(),
                sourceAppName: appName,
                sourceBundleIdentifier: bundleIdentifier,
                windowTitle: frontTitle
            )
        case .textOnly:
            fatalError("Text-only scope returns before ScreenCaptureKit is used.")
        }
    }
}

public struct RecognizedCaptureText: Sendable {
    public var text: String
    public var recognition: CaptureRecognition?
    public init(text: String, recognition: CaptureRecognition? = nil) { self.text = text; self.recognition = recognition }
}

public protocol TextRecognizing: Sendable {
    func recognizeCapture(in imageData: Data, context: TextRecognitionContext) async throws -> RecognizedCaptureText
    func recognizeText(in imageData: Data) async throws -> String
    func recognizeText(in imageData: Data, context: TextRecognitionContext) async throws -> String
}

public extension TextRecognizing {
    func recognizeCapture(in imageData: Data, context: TextRecognitionContext) async throws -> RecognizedCaptureText {
        RecognizedCaptureText(text: try await recognizeText(in: imageData, context: context))
    }
    func recognizeText(in imageData: Data, context: TextRecognitionContext) async throws -> String {
        try await recognizeText(in: imageData)
    }
}

public final class VisionTextRecognizer: TextRecognizing, @unchecked Sendable {
    static let minimumConfidence: Float = 0.35
    public init() {}

    public func recognizeText(in imageData: Data) async throws -> String {
        try await recognizeText(in: imageData, context: .document)
    }

    public func recognizeText(in imageData: Data, context: TextRecognitionContext) async throws -> String {
        try await recognizeCapture(in: imageData, context: context).text
    }

    public func recognizeCapture(in imageData: Data, context: TextRecognitionContext) async throws -> RecognizedCaptureText {
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
                let lines = observations.compactMap { observation -> PositionedTextLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    // Garbled low-confidence recognition is indistinguishable from content once stored.
                    guard candidate.confidence >= Self.minimumConfidence else { return nil }
                    return PositionedTextLine(text: candidate.string, boundingBox: observation.boundingBox, confidence: Double(candidate.confidence))
                }
                let layout = context.layoutStyle.flatMap { ConversationImageLayout.detect(in: cgImage, style: $0, lines: lines) }
                let text = ConversationOCRFormatter.format(lines, context: context, layout: layout)
                // Store geometry only for text retained by the conversation formatter.
                // Never reintroduce the discarded sidebar or an unredacted copy.
                let kept = lines.filter { !$0.text.isEmpty && text.contains($0.text) }.map { line in
                    CaptureRecognition.Line(text: PrivacyEngine().redact(line.text),
                        x: Double(line.boundingBox.minX), y: Double(line.boundingBox.minY),
                        width: Double(line.boundingBox.width), height: Double(line.boundingBox.height), confidence: line.confidence)
                }
                continuation.resume(returning: RecognizedCaptureText(text: text, recognition: CaptureRecognition(lines: kept)))
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
    public func record(using rule: EventRule, userText: String? = nil, meetingID: UUID? = nil, targetOverride: CaptureTarget? = nil) async throws -> CaptureRecord {
        let currentState = await store.snapshot()
        guard rule.isEnabled else {
            throw CapturePipelineError.captureExcluded("该事件模板目前未启用。")
        }
        let target = targetOverride ?? screenCapturer.currentTarget()
        let before = privacyEngine.decision(for: target?.bundleIdentifier, settings: currentState.privacy)
        guard before.mayCapture else { throw CapturePipelineError.captureExcluded(before.reason ?? "采集已暂停") }
        if !rule.appAllowList.isEmpty, let target, !rule.appAllowList.contains(target.bundleIdentifier) {
            throw CapturePipelineError.captureExcluded("当前应用不在此事件的应用白名单中。")
        }
        let payload = try await screenCapturer.capture(scope: rule.scope, target: target)
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
        var recognition: CaptureRecognition?
        if let userText, !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            extractedText = userText
        } else if let imageData = payload.imageData {
            let recognized = try await recognizer.recognizeCapture(
                in: imageData,
                context: Self.recognitionContext(for: payload, scope: rule.scope)
            )
            extractedText = recognized.text; recognition = recognized.recognition
        } else {
            extractedText = ""
        }
        let redactedText = privacyEngine.redact(extractedText)
        guard !currentState.memorySuppressionRules.contains(where: {
            $0.matches(text: redactedText, sourceBundleIdentifier: payload.sourceBundleIdentifier)
        }) else {
            throw CapturePipelineError.suppressedByUser
        }
        // Hash the recognized text: pixel hashes differ for a cursor blink or clock tick. Fall back to the
        // image only when nothing was recognized.
        let normalizedText = CaptureTextFingerprint.normalized(redactedText)
        let digestSource = normalizedText.isEmpty ? (payload.imageData ?? Data()) : Data(normalizedText.utf8)
        let contentHash = SHA256.hash(data: digestSource).map { String(format: "%02x", $0) }.joined()
        guard !(await store.hasRecentHash(contentHash)) else { throw CapturePipelineError.duplicateCapture }
        if userText == nil, await store.hasRecentNearDuplicate(text: redactedText, bundleIdentifier: payload.sourceBundleIdentifier) {
            throw CapturePipelineError.duplicateCapture
        }

        let captureID = UUID()
        let imageRelativePath: String?
        if currentState.privacy.retainScreenshots, rule.retainImageDays > 0, let imageData = payload.imageData {
            imageRelativePath = try storage.saveScreenshot(imageData, captureID: captureID)
        } else {
            imageRelativePath = nil
        }

        var record = CaptureRecord(
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
            tags: LocalSummary.tags(from: redactedText),
            textOrigin: userText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? .userInput : .screenOCR,
            recognition: recognition
        )
        record.meetingSessionID = meetingID
        record.sourceMessages = SourceNormalizer.messages(for: record, bindings: currentState.workflow.identityBindings)
        let latest = await store.snapshot()
        guard privacyEngine.decision(for: payload.sourceBundleIdentifier, settings: latest.privacy).mayCapture,
              latest.rules.first(where: { $0.id == rule.id })?.isEnabled != false else {
            if let path = imageRelativePath { try? FileManager.default.removeItem(at: storage.rootURL.appendingPathComponent(path)) }
            throw CapturePipelineError.captureExcluded("采集设置已变化，未保存记录。")
        }
        do { try await store.addCapture(record) }
        catch {
            if let path = imageRelativePath { try? storage.deleteScreenshot(relativePath: path) }
            throw error
        }
        return record
    }

    private static func recognitionContext(for payload: CapturePayload, scope: CaptureScope) -> TextRecognitionContext {
        TextRecognitionContext.resolve(appName: payload.sourceAppName, bundleIdentifier: payload.sourceBundleIdentifier,
            windowTitle: payload.windowTitle, scope: scope)
    }

    public func removeCapture(_ record: CaptureRecord) async throws {
        _ = try await store.deleteCapture(id: record.id)
        if let imagePath = record.imageRelativePath {
            try storage.deleteScreenshot(relativePath: imagePath)
        }
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
