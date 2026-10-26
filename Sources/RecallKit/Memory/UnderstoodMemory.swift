import Foundation

extension UnderstoodFact {
    var eventID: UUID {
        MatterEvidence.eventID(source: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, topic: id, ordinal: 0)
    }
    var isPersonalEvent: Bool { actor == .user && speaker == .user && kind != .reference && kind != .request }
    var eventStatus: WorkEpisodeStatus {
        switch status {
        case .completed: .completed
        case .inProgress: .progressed
        case .pending: .pending
        case .blocked: .blocked
        case .cancelled, .unknown: .explored
        }
    }
    var readableDetail: String {
        detail + (condition.map { "；条件：\($0)" } ?? "")
            + (eventTime.map { "；原文时间：\($0.text)" } ?? "")
    }
    /// Only a complete unambiguous absolute timestamp is eligible for a notification draft.
    /// Relative dates and dates without a clock stay visible as text for the user to arrange.
    var explicitDeadline: Date? {
        guard let text = deadline?.text else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)
    }
    var explicitEventDate: Date? {
        guard let text = eventTime?.text else { return nil }
        if let exact = ISO8601DateFormatter().date(from: text) { return exact }
        // A complete calendar date is useful for chronology without inventing a clock.
        // Ambiguous month/day and relative language remain unresolved text.
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.isLenient = false
        for format in ["yyyy-MM-dd", "yyyy年M月d日", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text), formatter.string(from: date) == text { return date }
        }
        return nil
    }
}

public extension CaptureRecord {
    /// Ready results replace heuristic extraction, including valid zero-fact results.
    /// Raw text stays available for searching, provenance and future reprocessing.
    var understoodContext: String? {
        guard let result = understanding else { return nil }
        let content = result.facts.map(\.statement).joined(separator: "\n")
        return "已核对的记录理解（不是原文，也不代表独立验证）：\n"
            + (content.isEmpty ? "未提取到明确事实或行动。" : content)
            + (result.uncertainBlockCount > 0 ? "\n部分片段含义不明；未归纳不代表未发生，请结合原文。" : "")
    }
}

extension CaptureUnderstandingEngine {
    /// Preserve full facts within a bounded request; never cut a title or sentence in half.
    static func context(_ capture: CaptureRecord, limit: Int) -> String {
        guard let result = capture.understanding else { return String(capture.ocrText.prefix(limit)) }
        var lines: [String] = [], size = 0
        for fact in result.facts {
            let line = fact.statement
            if size + line.count > max(limit, 900) { break }
            lines.append(line); size += line.count
        }
        let remaining = result.facts.count - lines.count
        return "核对后的记录理解（来源陈述，非独立验证）：\n"
            + (lines.isEmpty ? "没有可确认的事实或本人行动。" : lines.joined(separator: "\n"))
            + (remaining > 0 ? "\n还有 \(remaining) 条事实未放入本次上下文，不得声称已覆盖全部。" : "")
            + (result.uncertainBlockCount > 0 ? "\n有 \(result.uncertainBlockCount) 个原文片段暂无法可靠判断。" : "")
    }
}
