import Foundation

/// A promise needs the user's own words. A request, a delivery update or a conversation title
/// cannot establish a promise or identify its recipient.
enum CommitmentAnswer {
    static func matches(_ question: String) -> Bool {
        let text = question.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let forms = [
            "我答应了谁什么事", "我答应过谁什么事", "我答应谁什么事", "我答应了谁什么",
            "我答应了什么", "我答应过什么", "我做过哪些承诺", "我有哪些承诺", "我承诺了哪些事",
            "我答应了哪些事", "我答应了哪些事情", "我承诺了什么",
            "whatdidipromise", "whatdidipromiseandtowhom", "whathaveipromised"
        ]
        if forms.contains(text) { return true }
        // Allow a date prefix without routing a question about a named project to the general list.
        let withoutDate = text.replacingOccurrences(
            of: #"^(?:今天|今日|昨天|昨日|前天|本周|这周|上周|本月|上个月|最近(?:[0-9一二三四五六七八九十两]+天|一周|一个月))"#,
            with: "", options: .regularExpression)
        return forms.contains(withoutDate)
    }

    static func reply(in state: RecallState) -> (content: String, citations: [UUID]) {
        let records = EvidenceAccess.records(state).filter { record in
            state.rules.first { $0.template == record.eventTemplate }?.participatesInChat ?? true
        }.sorted { $0.createdAt > $1.createdAt }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var versions: [UUID: String] = [:]
        let explicit = try? NSRegularExpression(
            pattern: #"^(?:(?:如果|只要|等).{1,40}[，,]\s*)?(?:我(?:答应|承诺|保证)(?!过|不|你不是).{2,}|I\s+(?:promise|can commit)\b.+)"#,
            options: .caseInsensitive)
        var seen: Set<String> = []
        var citations: [UUID] = []
        var lines: [String] = []
        for record in records {
            var checkedQuotes: [String] = []
            if let understood = record.understanding,
               understood.processorVersion == CaptureUnderstandingEngine.version,
               !understood.sourceVersions.isEmpty,
               understood.sourceVersions.allSatisfy({ id, signature in
                   guard let source = byID[id], CaptureUnderstandingEngine.eligible(source, in: state) else { return false }
                   let current = versions[id] ?? CaptureUnderstandingEngine.sourceVersion(source, in: state)
                   versions[id] = current
                   return signature == current
               }) {
                checkedQuotes = understood.facts.filter {
                    $0.kind == .commitment && $0.actor == .user && $0.speaker == .user && $0.status == .pending
                }.flatMap(\.evidence).filter { $0.blockID.hasPrefix(record.id.uuidString + ":") && !$0.quote.isEmpty }.map(\.quote)
            }
            let messages = SourceNormalizer.messages(for: record, bindings: state.workflow.identityBindings)
            for message in messages where message.speaker == .user && !message.isReference {
                let text = message.text.replacingOccurrences(
                    of: #"^(?:\[(?:聊天·自己|聊天·角色未知|发言者·[^\]]+)\]\s*)+"#,
                    with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Keep the original sentence, including any stated recipient, deadline and condition.
                let isExplicit = explicit?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                guard isExplicit || checkedQuotes.contains(where: message.text.contains) else { continue }
                let visible = PrivacyEngine().redact(String(text.prefix(500)))
                guard seen.insert(visible).inserted else { continue }
                if !citations.contains(record.id) { citations.append(record.id) }
                guard let index = citations.firstIndex(of: record.id) else { continue }
                lines.append("- \(visible) [\(index + 1)]")
                if lines.count == 8 { break }
            }
            if lines.count == 8 { break }
        }
        guard !lines.isEmpty else {
            return (RecallLocalization.both("在当前范围内，没有找到能确认是你本人作出的承诺。", "I found no saved statements in this scope that confirm a promise made by you."), [])
        }
        let heading = RecallLocalization.both("找到这些明确的承诺原话。对象和期限以原文为准。", "These are your recorded commitments. Recipients and deadlines are shown where stated.")
        return (([heading] + lines).joined(separator: "\n\n"), citations)
    }
}

extension FileMemoryStore {
    func answerCommitments(in scope: MemoryQueryScope, range: ResolvedMemoryTimeRange?, conversationID: UUID) throws -> ConversationMessage {
        let scoped = scope.applying(to: preparedForChat(), questionRange: range)
        let result = CommitmentAnswer.reply(in: scoped)
        let message = ConversationMessage(role: .assistant, content: result.content, citations: result.citations)
        try addAnswer(message, inConversation: conversationID, topicID: scope.topicID)
        return message
    }
}
