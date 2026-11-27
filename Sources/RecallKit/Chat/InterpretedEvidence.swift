import Foundation

/// 问一问只拿模型整理过的内容当材料：每日回顾的事项、记录理解出的事实、主题与提醒，以及用户自己输入或导入的文字。
/// 屏幕 OCR 原文只用于检索定位，不发给回答模型，也不出现在回答里。
public struct InterpretedEvidence: Sendable {
    /// One readable piece of material. `id` is what the answer cites; `sourceIDs` are the records behind it.
    public struct Entry: Sendable {
        var id: UUID
        var day: Date
        var label: String
        var text: String
        var sourceIDs: [UUID]

        /// The shape the answer model and the check read: a record whose text is the interpreted content.
        var record: CaptureRecord {
            CaptureRecord(id: id, eventTemplate: .dailyReview, createdAt: day, sourceAppName: label,
                          sourceBundleIdentifier: "im.recall.interpreted", contentHash: "interpreted-\(id.uuidString)", ocrText: text)
        }
    }

    let state: RecallState
    let calendar: Calendar
    private let captures: [UUID: CaptureRecord]

    init(state: RecallState, calendar: Calendar = .current) {
        self.state = state
        self.calendar = calendar
        captures = Dictionary(state.captures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Text the user typed, imported, selected or corrected reads cleanly. Raw screen OCR does not.
    static func readableText(_ record: CaptureRecord) -> String? {
        if let corrected = record.correctedText, !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return corrected }
        switch record.textOrigin {
        case .userInput, .importedText, .selectedText: return record.ocrText
        case .screenOCR, nil: return nil
        }
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "completed", "done": "已完成"
        case "inProgress": "进行中"
        case "pending": "待处理"
        case "blocked": "受阻"
        case "cancelled": "已取消"
        default: "状态未明"
        }
    }

    /// The entries of one saved review: highlighted items first, then the day's other matters/agreements,
    /// followed by structured reference/reading notes from the review ledger so study materials and non-highlighted
    /// records remain answerable without exposing raw OCR.
    func entries(of review: DailySummary, budget: Int) -> [Entry] {
        let day = calendar.startOfDay(for: review.day)
        var result: [Entry] = []
        var titles: Set<String> = []
        var used = 0
        func add(id: UUID, topic: String?, title: String, detail: String, status: String?, kind: DailyItemKind?, sourceIDs: [UUID]) {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !sourceIDs.isEmpty, titles.insert(title).inserted else { return }
            let cleanTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var text = (!cleanTopic.isEmpty && !title.localizedCaseInsensitiveContains(cleanTopic))
                ? "[\(cleanTopic)] \(title)"
                : title
            let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty, detail != title { text += "：" + detail }
            if let status { text += "（" + Self.statusLabel(status) + "）" }
            text = PrivacyEngine().redact(String(text.prefix(600)))
            guard used + text.count <= budget || result.isEmpty else { return }
            used += text.count
            let label = kind == .reference ? "每日回顾·资料线索" : "每日回顾"
            result.append(Entry(id: id, day: day, label: label, text: text, sourceIDs: sourceIDs))
        }
        for item in review.items {
            add(id: item.id, topic: item.knowledge?.topic, title: item.title, detail: item.detail,
                status: item.knowledge?.status, kind: item.knowledge?.kind, sourceIDs: item.evidenceIDs)
        }
        for entry in review.ledger where entry.kind == .matter || entry.kind == .agreement {
            add(id: entry.id, topic: entry.topic, title: entry.title, detail: entry.detail,
                status: entry.status, kind: entry.kind, sourceIDs: entry.evidenceIDs)
        }
        for entry in review.ledger where entry.kind == .reference || entry.kind == .preference {
            add(id: entry.id, topic: entry.topic, title: entry.title, detail: entry.detail,
                status: entry.status, kind: entry.kind, sourceIDs: entry.evidenceIDs)
        }
        return result
    }

    /// A single record's own interpretation: current understanding facts, or text the user wrote. Nil means only raw OCR exists.
    func entry(for record: CaptureRecord) -> Entry? {
        let day = calendar.startOfDay(for: record.createdAt)
        let label = record.sourceAppName ?? "记录"
        if let understood = record.understanding, isCurrent(understood) {
            let primary = understood.facts.filter { $0.kind != .reference }
            let chosen = primary.isEmpty ? understood.facts : primary
            let facts = chosen.prefix(8).map { "- " + $0.statement }
            if !facts.isEmpty {
                return Entry(id: record.id, day: day, label: label, text: PrivacyEngine().redact(String(facts.joined(separator: "\n").prefix(600))), sourceIDs: [record.id])
            }
        }
        guard let text = Self.readableText(record)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return Entry(id: record.id, day: day, label: label, text: PrivacyEngine().redact(String(text.prefix(600))), sourceIDs: [record.id])
    }

    /// Records first map to review entries that cite them, then to their own interpretation.
    /// Records with neither are returned as uncovered, so the answer can say which days still need a review.
    func entries(forRecords ids: [UUID], reviews: [DailySummary]) -> (entries: [Entry], uncovered: [CaptureRecord]) {
        var result: [Entry] = []
        var seen: Set<UUID> = []
        var uncovered: [CaptureRecord] = []
        let reviewEntries = reviews.flatMap { entries(of: $0, budget: .max) }
        for id in ids {
            let citing = reviewEntries.filter { $0.sourceIDs.contains(id) }
            if !citing.isEmpty {
                for entry in citing where seen.insert(entry.id).inserted { result.append(entry) }
                continue
            }
            guard let record = captures[id] else { continue }
            if let own = entry(for: record) {
                if seen.insert(own.id).inserted { result.append(own) }
            } else {
                uncovered.append(record)
            }
        }
        return (result, uncovered)
    }

    private func isCurrent(_ result: CaptureUnderstanding) -> Bool {
        guard result.processorVersion == CaptureUnderstandingEngine.version, !result.sourceVersions.isEmpty else { return false }
        return result.sourceVersions.allSatisfy { id, signature in
            captures[id].map { CaptureUnderstandingEngine.eligible($0, in: state) && CaptureUnderstandingEngine.sourceVersion($0, in: state) == signature } ?? false
        }
    }
}
