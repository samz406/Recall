import Foundation

/// Cleans screen text for analysis without touching the original. The result is stored in `correctedText`, which
/// analysis already prefers and which the user can revert from the record's detail ("恢复原始文字").
/// Only lines that carry no content are removed: menu-bar words, one-character fragments and punctuation, and a
/// line already recorded earlier for the same app. A user-entered record is never cleaned.
public struct CaptureCleaner: Sendable {
    public struct Result: Sendable {
        public var cleaned: String
        public var removedShort: Int
        public var removedRepeated: Int
        public var changed: Bool
    }

    /// Menu-bar and window-chrome words that are not content in any application.
    static let chrome: Set<String> = [
        "帮助", "窗口", "编辑", "文件", "查看", "显示", "视图", "历史记录", "书签", "标签页", "前往", "工具", "格式", "插入", "访达", "终端",
        "File", "Edit", "View", "Window", "Help", "History", "Bookmarks", "Tab", "Go", "Tools", "Format", "Insert"
    ]

    public init() {}

    /// Text of a line without its role marker, so "[聊天·自己] 好" is judged by "好".
    static func body(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("["), let close = text.firstIndex(of: "]"), text.distance(from: text.startIndex, to: close) <= 24 {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// A line is content when it has letters or digits beyond a trivial length and is not window chrome.
    static func isContent(_ line: String) -> Bool {
        let body = body(line)
        guard !body.isEmpty, !chrome.contains(body) else { return false }
        guard body.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        if body.count < 4 && !body.contains(where: \.isNumber) { return false }
        return true
    }

    /// `seen` carries the lines already recorded for the same application, in time order, so a line that stays on
    /// screen across many captures is kept once.
    public func clean(_ capture: CaptureRecord, seen: inout Set<String>) -> Result {
        let original = capture.ocrText
        guard capture.textOrigin != .userInput, capture.manualMatter == nil, capture.memoryDirective == nil else {
            return Result(cleaned: original, removedShort: 0, removedRepeated: 0, changed: false)
        }
        let app = capture.sourceBundleIdentifier ?? capture.sourceAppName ?? ""
        var kept: [String] = [], short = 0, repeated = 0
        for line in original.components(separatedBy: .newlines) {
            guard Self.isContent(line) else { if !line.trimmingCharacters(in: .whitespaces).isEmpty { short += 1 }; continue }
            let body = Self.body(line)
            // Short lines ("同步空间", "Orca") are mostly sidebars and tab bars that stay on screen for days. A
            // content word survives because its first occurrence in each application is kept; only the repeats go.
            let key = app + "\u{1}" + body
            if !seen.insert(key).inserted { repeated += 1; continue }
            kept.append(line)
        }
        let cleaned = kept.joined(separator: "\n")
        return Result(cleaned: cleaned, removedShort: short, removedRepeated: repeated,
                      changed: cleaned != original && !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

public struct CaptureCleaningSummary: Sendable {
    public var records = 0, changed = 0, skippedEmpty = 0, alreadyCorrected = 0
    public var linesBefore = 0, linesAfter = 0, charsBefore = 0, charsAfter = 0
    public var removedShort = 0, removedRepeated = 0
}

extension FileMemoryStore {
    /// Computes and (unless `dryRun`) stores cleaned text for captures in order. A record whose text would become
    /// empty is left as it was, and a record the user already corrected by hand is never overwritten.
    @discardableResult
    public func cleanCaptureText(dryRun: Bool, from start: Date? = nil, to end: Date? = nil,
                                 onProgress: (@Sendable (Int, Int) -> Void)? = nil) throws -> CaptureCleaningSummary {
        let cleaner = CaptureCleaner()
        let eligible = state.captures.filter { capture in
            guard capture.eventTemplate != .dailyReview, capture.isMemoryEvidenceArchive != true,
                  !capture.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if let start, capture.createdAt < start { return false }
            if let end, capture.createdAt >= end { return false }
            return true
        }.sorted { $0.createdAt < $1.createdAt }
        var summary = CaptureCleaningSummary(), seen = Set<String>(), updates: [(UUID, String)] = []
        for (offset, capture) in eligible.enumerated() {
            try Task.checkCancellation()
            summary.records += 1
            summary.linesBefore += capture.ocrText.components(separatedBy: .newlines).count; summary.charsBefore += capture.ocrText.count
            // A hand-corrected record is the user's text: count it, keep it, and still learn its lines.
            if capture.correctedText != nil {
                summary.alreadyCorrected += 1
                for line in (capture.correctedText ?? "").components(separatedBy: .newlines) where CaptureCleaner.isContent(line) {
                    seen.insert((capture.sourceBundleIdentifier ?? capture.sourceAppName ?? "") + "\u{1}" + CaptureCleaner.body(line))
                }
                summary.linesAfter += (capture.correctedText ?? "").components(separatedBy: .newlines).count; summary.charsAfter += capture.correctedText?.count ?? 0
                continue
            }
            let result = cleaner.clean(capture, seen: &seen)
            if result.cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { summary.skippedEmpty += 1 }
            summary.removedShort += result.removedShort; summary.removedRepeated += result.removedRepeated
            let finalText = result.changed ? result.cleaned : capture.ocrText
            summary.linesAfter += finalText.components(separatedBy: .newlines).count; summary.charsAfter += finalText.count
            if result.changed { summary.changed += 1; updates.append((capture.id, result.cleaned)) }
            if offset % 200 == 0 { onProgress?(offset, eligible.count) }
        }
        guard !dryRun, !updates.isEmpty else { return summary }
        let before = state
        let index = Dictionary(uniqueKeysWithValues: updates)
        for i in state.captures.indices {
            guard let text = index[state.captures[i].id] else { continue }
            state.captures[i].correctedText = PrivacyEngine().redact(text)
        }
        invalidateMemoryOutputs(sourceIDs: Set(index.keys))
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
        do { try persist() } catch { state = before; throw error }
        return summary
    }
}
