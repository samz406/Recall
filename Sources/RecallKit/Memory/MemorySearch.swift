import Foundation

public struct MemorySearchQuery: Sendable, Equatable {
    public var text: String
    public var startDate: Date?
    public var endDate: Date?
    public var appName: String?

    public init(text: String, startDate: Date? = nil, endDate: Date? = nil, appName: String? = nil) {
        self.text = text
        self.startDate = startDate
        self.endDate = endDate
        self.appName = appName
    }
}

public struct MemorySearchResult: Identifiable, Sendable {
    public var id: UUID { capture.id }
    public var capture: CaptureRecord
    public var score: Double
    public var matchedTerms: [String]

    public init(capture: CaptureRecord, score: Double, matchedTerms: [String]) {
        self.capture = capture
        self.score = score
        self.matchedTerms = matchedTerms
    }
}

public struct MemorySearchEngine: Sendable {
    public init() {}

    public func search(_ query: MemorySearchQuery, in captures: [CaptureRecord], limit: Int = 8) -> [MemorySearchResult] {
        let terms = normalizedTerms(from: query.text)
        // 时间概览问题（如“今天做什么”）的价值来自日期过滤；即使没有文本关键词命中，
        // 也应将该时间范围内的记录交给会话层综合，而不是错误地报告“没有记忆”。
        let hasTimeWindow = query.startDate != nil || query.endDate != nil
        return captures.compactMap { capture in
            guard matchesFilters(capture, query: query) else { return nil }
            let searchable = [capture.ocrText, capture.summary ?? "", capture.sourceAppName ?? "", capture.windowTitle ?? "", capture.tags.joined(separator: " ")]
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let matches = terms.filter { searchable.contains($0) }
            guard terms.isEmpty || !matches.isEmpty || hasTimeWindow else { return nil }
            let recency = max(0, 1 - Date.now.timeIntervalSince(capture.createdAt) / (60 * 60 * 24 * 30))
            let coverage: Double
            if terms.isEmpty {
                coverage = 0.1
            } else if matches.isEmpty {
                coverage = hasTimeWindow ? 0.05 : 0
            } else {
                coverage = Double(matches.count) / Double(terms.count)
            }
            let score = coverage * 0.8 + recency * 0.2
            return MemorySearchResult(capture: capture, score: score, matchedTerms: matches)
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.capture.createdAt > rhs.capture.createdAt : lhs.score > rhs.score
        }
        .prefix(limit)
        .map { $0 }
    }

    private func normalizedTerms(from text: String) -> [String] {
        let stopWords: Set<String> = ["我", "的", "了", "和", "是", "在", "有", "什么", "哪些", "一下", "帮我", "请", "内容", "the", "a", "an", "is", "are", "to", "of", "and", "for"]
        let stopPhrases = ["什么时候", "什么时间", "哪一天", "哪天", "几号", "请问", "告诉我", "帮我查", "帮我找", "看一下", "看下"]
        var normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for phrase in stopPhrases {
            normalized = normalized.replacingOccurrences(of: phrase, with: " ")
        }

        var terms: [String] = []
        for token in normalized.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init) {
            guard token.count > 1, !stopWords.contains(token) else { continue }
            terms.append(token)
            // 中文没有天然空格。为较长问句补充二字词召回，避免把
            // “妙妙什么时候过生日”作为一个永远无法命中的完整关键词。
            if token.contains(where: isHanCharacter), token.count > 2 {
                let characters = Array(token)
                for index in 0..<(characters.count - 1) {
                    let pair = String(characters[index...index + 1])
                    if pair.allSatisfy(isHanCharacter), !stopWords.contains(pair) {
                        terms.append(pair)
                    }
                }
            }
        }

        var seen: Set<String> = []
        return terms.filter { seen.insert($0).inserted }
    }

    private func isHanCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }

    private func matchesFilters(_ capture: CaptureRecord, query: MemorySearchQuery) -> Bool {
        if let startDate = query.startDate, capture.createdAt < startDate { return false }
        if let endDate = query.endDate, capture.createdAt > endDate { return false }
        if let appName = query.appName,
           !(capture.sourceAppName ?? "").localizedCaseInsensitiveContains(appName) { return false }
        return true
    }
}
