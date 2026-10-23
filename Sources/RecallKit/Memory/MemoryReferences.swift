import Foundation
import CryptoKit

/// Saved subject matter can be useful without proving who acted or whether work finished.
/// This lane never creates personal preferences, commitments, or completed experiences.
public struct MemoryReferenceEngine: Sendable {
    public init() {}
    public func files(in state: RecallState, excluding ownedSources: Set<UUID> = []) -> [MatterFile] {
        let safe = state.correctedForAnalysis()
        let retired = Set(state.memoryKnowledge.claims.filter {
            $0.kind == .reference && !$0.usable()
        }.flatMap(\.sourceIDs))
        var names: [String: String] = [:]
        var events: [String: [UUID: MatterEvent]] = [:]
        let originals = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0.createdAt) })
        for source in safe.captures {
            guard !ownedSources.contains(source.id), !retired.contains(source.id), source.memoryDirective == nil,
                  source.manualMatter == nil, source.eventTemplate != .dailyReview,
                  !state.privacy.excludedBundleIdentifiers.contains(source.sourceBundleIdentifier ?? "") else { continue }
            let paragraphs = Self.paragraphs(source.ocrText)
            guard paragraphs.map({ $0.text.count }).reduce(0, +) >= 100 else { continue }
            let title = Self.title(source, paragraphs: paragraphs.map(\.text))
            let identity = (source.sourceBundleIdentifier ?? source.sourceAppName ?? "") + ":" + title
            let key = "reference:" + Self.hash(identity)
            names[key] = title
            let day = Calendar.current.startOfDay(for: source.createdAt).timeIntervalSince1970
            for paragraph in paragraphs {
                let id = MatterEvidence.eventID(source: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    topic: key + ":" + String(day) + ":" + Self.hash(MatterEvidence.key(paragraph.text)), ordinal: 0)
                if var previous = events[key]?[id] {
                    previous.evidenceIDs.append(source.id)
                    if source.createdAt < previous.date {
                        previous.recordedAt = originals[source.id] ?? source.createdAt
                        previous.eventAt = state.matterCorrections.last { $0.kind == .eventDate && $0.evidenceIDs.contains(source.id) }?.eventAt
                    }
                    events[key]?[id] = previous
                } else {
                    var event = MatterEvent(id: id, title: title, detail: paragraph.text,
                        recordedAt: originals[source.id] ?? source.createdAt,
                        eventAt: state.matterCorrections.last { $0.kind == .eventDate && $0.evidenceIDs.contains(source.id) }?.eventAt,
                        status: .explored, evidenceIDs: [source.id])
                    event.sequence = paragraph.ordinal; event.isReference = true
                    events[key, default: [:]][id] = event
                }
            }
        }
        return events.compactMap { key, rows in
            let ordered = rows.values.sorted { a, b in
                if a.date != b.date { return a.date < b.date }
                return a.sequence == b.sequence ? a.id.uuidString < b.id.uuidString : a.sequence < b.sequence
            }
            return ordered.isEmpty ? nil : MatterFile(id: key, title: names[key] ?? "保存的内容", events: ordered)
        }.sorted { $0.latest.date > $1.latest.date }
    }
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func paragraphs(_ raw: String) -> [(text: String, ordinal: Int)] {
        var result: [(text: String, ordinal: Int)] = [], budget = 0
        let chrome = ["通讯录", "工作台", "微盘", "智能助理", "新标签页", "所有书签", "消息 邮件 文档", "网络异常，请检查网络后再试"]
        for (index, line) in raw.components(separatedBy: .newlines).enumerated() {
            var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.replacingOccurrences(of: #"^\[(?:聊天·(?:自己|对方|角色未知)|内容·(?:资料|附件)|频道·[^\]]*|发言者·[^\]]*)\]\s*"#,
                with: "", options: .regularExpression)
            guard !text.hasPrefix("[内容·系统]"), !text.hasPrefix("[内容·片段]"),
                  (16...2200).contains(text.count), text.filter(\.isLetter).count >= 10,
                  !text.hasSuffix("…"), !text.hasSuffix("..."),
                  (text.filter { $0.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } }.count >= 10 || text.filter(\.isLetter).count >= 40),
                  !chrome.contains(where: text.contains),
                  text.range(of: #"^(?:https?://|www\.|import |public |private |func |class |const |let )|[{}]|[�]|(?:\s[×x]\s.*){2}"#, options: .regularExpression) == nil,
                  (text.count >= 24 || text.contains(where: { "，。；：,.;:!?！？".contains($0) })) else { continue }
            guard budget + text.count <= 6500 else { continue }
            result.append((text, index)); budget += text.count
            if result.count == 6 { break }
        }
        return result
    }
    private static func title(_ source: CaptureRecord, paragraphs: [String]) -> String {
        let generic: Set<String> = ["google", "googlechrome", "chrome", "safari", "微信", "企业微信", "chatgpt", "claude", "flomo", "notion", "新标签页", "搜索"]
        let window = (source.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if (4...96).contains(window.count), window != source.sourceAppName,
           !generic.contains(MatterEvidence.key(window)), !window.contains("…"), !window.contains("|"), !window.contains("×") { return window }
        if let heading = paragraphs.first(where: { (12...70).contains($0.count) && !$0.contains("…") }) { return heading }
        // A neutral source label deliberately makes no claim about the user's actions.
        return "保存的内容 · " + (source.sourceAppName ?? "本地记录")
    }
}

public struct MemoryOrganizationSummary: Sendable {
    public var records: Int
    public var textRecords: Int
    public var attributedRecords: Int
    public var matters: Int
    public var references: Int
    public var agreements: Int
    public var people: Int
    public var experiences: Int
    public init(state: RecallState) {
        records = state.captures.count
        textRecords = state.captures.filter { $0.ocrText.contains { !$0.isWhitespace } }.count
        attributedRecords = state.captures.filter { $0.textOrigin == .userInput || $0.ocrText.contains("[聊天·自己]") }.count
        let active = state.memoryKnowledge.claims.filter { $0.usable() }
        matters = Set(active.filter { $0.kind == .event }.map(\.subjectID)).count
        references = Set(active.filter { $0.kind == .reference }.map(\.subjectID)).count
        agreements = active.filter { $0.kind.isPersonal && $0.kind != .person && $0.scope != .conversation }.count
        people = Set(active.filter { $0.kind == .person }.map(\.subjectID)).count
        experiences = active.filter { $0.kind == .experience }.count
    }
    public var message: String {
        "已检查 \(records) 条记录（\(textRecords) 条含文字），整理出 \(matters) 个本人事项、\(references) 个记录主题、\(agreements) 条约定、\(people) 个人物线索和 \(experiences) 项历史经验。"
    }
}

public struct ReviewRecordCoverage: Sendable {
    public let totalRecords: Int
    public let periodRecords: Int
    public let textRecords: Int
    public let latestRecordAt: Date?
    public init(state: RecallState, period: ReviewPeriod) {
        let sources = state.correctedForAnalysis().captures.filter {
            $0.memoryDirective == nil && $0.eventTemplate != .dailyReview
                && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "")
        }
        totalRecords = sources.count
        let within = sources.filter { period.contains($0.createdAt) }
        periodRecords = within.count
        textRecords = within.filter { $0.ocrText.contains { !$0.isWhitespace } }.count
        latestRecordAt = sources.map(\.createdAt).max()
    }
}
