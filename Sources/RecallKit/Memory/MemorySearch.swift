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
        let stopWords: Set<String> = ["我", "的", "了", "和", "是", "在", "有", "什么", "哪些", "一下", "帮我", "请", "the", "a", "an", "is", "are", "to", "of", "and", "for"]
        return text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    private func matchesFilters(_ capture: CaptureRecord, query: MemorySearchQuery) -> Bool {
        if let startDate = query.startDate, capture.createdAt < startDate { return false }
        if let endDate = query.endDate, capture.createdAt > endDate { return false }
        if let appName = query.appName,
           !(capture.sourceAppName ?? "").localizedCaseInsensitiveContains(appName) { return false }
        return true
    }
}
