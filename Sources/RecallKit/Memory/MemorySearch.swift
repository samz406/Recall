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

public struct ResolvedMemoryTimeRange: Sendable, Equatable {
    public var startDate: Date
    public var endDate: Date
    public var requestedDayCount: Int

    public init(startDate: Date, endDate: Date, requestedDayCount: Int) {
        self.startDate = startDate
        self.endDate = endDate
        self.requestedDayCount = max(requestedDayCount, 1)
    }
}

/// 把用户问题中的自然语言时间表达转换为确定的本地日历范围。
public struct MemoryTimeRangeResolver: Sendable {
    public init() {}

    public func resolve(
        _ text: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ResolvedMemoryTimeRange? {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let relativeDayCount: Int?
        if ["最近一周", "近一周", "过去一周", "最近一个星期", "过去一个星期"].contains(where: normalized.contains) {
            relativeDayCount = 7
        } else if ["最近一个月", "近一个月", "过去一个月"].contains(where: normalized.contains) {
            relativeDayCount = 30
        } else {
            relativeDayCount = explicitRecentDayCount(in: normalized)
        }
        if let relativeDayCount {
            let boundedDays = min(max(relativeDayCount, 1), 90)
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -(boundedDays - 1), to: today) ?? today
            return ResolvedMemoryTimeRange(startDate: start, endDate: now, requestedDayCount: boundedDays)
        }
        if let day = explicitDay(in: normalized, now: now, calendar: calendar),
           let interval = calendar.dateInterval(of: .day, for: day) {
            return ResolvedMemoryTimeRange(startDate: interval.start, endDate: min(interval.end, now), requestedDayCount: 1)
        }
        if let range = weekdayRange(in: normalized, now: now, calendar: calendar) { return range }
        if let range = monthRange(in: normalized, now: now, calendar: calendar) { return range }
        if normalized.contains("前天") {
            guard let day = calendar.date(byAdding: .day, value: -2, to: now), let interval = calendar.dateInterval(of: .day, for: day) else { return nil }
            return ResolvedMemoryTimeRange(startDate: interval.start, endDate: interval.end, requestedDayCount: 1)
        }
        if normalized.contains("上周") || normalized.localizedCaseInsensitiveContains("last week") {
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
                  let previousWeek = calendar.dateInterval(of: .weekOfYear, for: thisWeek.start.addingTimeInterval(-1)) else { return nil }
            return ResolvedMemoryTimeRange(startDate: previousWeek.start, endDate: previousWeek.end, requestedDayCount: 7)
        }
        if normalized.contains("本周") || normalized.contains("这周") || normalized.localizedCaseInsensitiveContains("this week") {
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            let days = max(calendar.dateComponents([.day], from: interval.start, to: now).day ?? 0, 0) + 1
            return ResolvedMemoryTimeRange(startDate: interval.start, endDate: now, requestedDayCount: days)
        }
        if normalized.contains("今天") || normalized.contains("今日") || normalized.localizedCaseInsensitiveContains("today") {
            guard let interval = calendar.dateInterval(of: .day, for: now) else { return nil }
            return ResolvedMemoryTimeRange(startDate: interval.start, endDate: now, requestedDayCount: 1)
        }
        if normalized.contains("昨天") || normalized.contains("昨日") || normalized.localizedCaseInsensitiveContains("yesterday") {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  let interval = calendar.dateInterval(of: .day, for: yesterday) else { return nil }
            return ResolvedMemoryTimeRange(startDate: interval.start, endDate: interval.end, requestedDayCount: 1)
        }
        return nil
    }

    /// "10月25日", "10月25号", "2026年10月25日", "10/25", "2026-10-25". Never a day in the future.
    private func explicitDay(in text: String, now: Date, calendar: Calendar) -> Date? {
        let patterns: [(String, Bool)] = [
            (#"(\d{4})\s*[年\-/.]\s*(\d{1,2})\s*[月\-/.]\s*(\d{1,2})\s*(?:日|号)?"#, true),
            (#"(?<![\d])(\d{1,2})\s*月\s*(\d{1,2})\s*(?:日|号)"#, false),
            (#"(?<![\d])(\d{1,2})\s*/\s*(\d{1,2})(?![\d/])"#, false)
        ]
        for (pattern, hasYear) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func value(_ index: Int) -> Int? { Range(match.range(at: index), in: text).flatMap { Int(text[$0]) } }
            var components = DateComponents()
            if hasYear { components.year = value(1); components.month = value(2); components.day = value(3) }
            else { components.year = calendar.component(.year, from: now); components.month = value(1); components.day = value(2) }
            guard let candidate = calendar.date(from: components), calendar.component(.day, from: candidate) == components.day else { continue }
            if candidate > now {
                // "10月25日" asked in January means last year's.
                guard !hasYear, let previous = calendar.date(byAdding: .year, value: -1, to: candidate) else { continue }
                return previous
            }
            return candidate
        }
        return nil
    }

    /// "上周三", "周二", "星期五": the most recent such day, or last week's for "上周".
    private func weekdayRange(in text: String, now: Date, calendar: Calendar) -> ResolvedMemoryTimeRange? {
        guard let expression = try? NSRegularExpression(pattern: #"(上上?|这|本)?\s*(?:周|星期|礼拜)\s*([一二三四五六日天])"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let dayRange = Range(match.range(at: 2), in: text) else { return nil }
        let names: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        guard let weekday = text[dayRange].first.flatMap({ names[$0] }) else { return nil }
        let prefix = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
        let today = calendar.startOfDay(for: now)
        let weeksBack = prefix == "上上" ? 2 : (prefix == "上" ? 1 : 0)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today),
              let weekStart = calendar.date(byAdding: .day, value: -7 * weeksBack, to: thisWeek.start) else { return nil }
        var offset = (weekday - calendar.component(.weekday, from: weekStart) + 7) % 7
        if weeksBack == 0 {
            // Without "上", a weekday that has not happened yet this week means its previous occurrence.
            var candidate = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? today
            if candidate > today { candidate = calendar.date(byAdding: .day, value: -7, to: candidate) ?? candidate }
            offset = calendar.dateComponents([.day], from: weekStart, to: candidate).day ?? offset
        }
        guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart), day <= now,
              let interval = calendar.dateInterval(of: .day, for: day) else { return nil }
        return ResolvedMemoryTimeRange(startDate: interval.start, endDate: min(interval.end, now), requestedDayCount: 1)
    }

    /// "10月" / "10月份" / "上个月" / "本月" as a whole month. A month that has not started yet is not a range.
    private func monthRange(in text: String, now: Date, calendar: Calendar) -> ResolvedMemoryTimeRange? {
        var start: Date?
        if text.contains("上个月") || text.contains("上月") {
            start = calendar.date(byAdding: .month, value: -1, to: calendar.dateInterval(of: .month, for: now)?.start ?? now)
        } else if text.contains("这个月") || text.contains("本月") {
            start = calendar.dateInterval(of: .month, for: now)?.start
        } else if let expression = try? NSRegularExpression(pattern: #"(?<![\d])(\d{1,2})\s*月(?:份)?(?!\s*\d)"#),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), let month = Int(text[range]), (1...12).contains(month) {
            var components = DateComponents(); components.year = calendar.component(.year, from: now); components.month = month; components.day = 1
            if var candidate = calendar.date(from: components) {
                if candidate > now { candidate = calendar.date(byAdding: .year, value: -1, to: candidate) ?? candidate }
                start = candidate
            }
        }
        guard let start, let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
        let end = min(interval.end, now)
        let days = max(calendar.dateComponents([.day], from: interval.start, to: end).day ?? 1, 1)
        return ResolvedMemoryTimeRange(startDate: interval.start, endDate: end, requestedDayCount: min(days, 31))
    }

    private func explicitRecentDayCount(in text: String) -> Int? {
        let patterns = [
            #"(?:最近|近|过去)\s*([0-9一二三四五六七八九十两]+)\s*(?:天|日)"#,
            #"last\s+([0-9]+)\s+days?"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let value = parseNumber(String(text[range])) else { continue }
            return value
        }
        return nil
    }

    private func parseNumber(_ text: String) -> Int? {
        if let number = Int(text) { return number }
        let digits: [Character: Int] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text == "十" { return 10 }
        if let tenIndex = text.firstIndex(of: "十") {
            let left = text[..<tenIndex].first.flatMap { digits[$0] } ?? 1
            let afterTen = text.index(after: tenIndex)
            let right = afterTen < text.endIndex ? digits[text[afterTen]] ?? 0 : 0
            return left * 10 + right
        }
        guard text.count == 1, let character = text.first else { return nil }
        return digits[character]
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
        // Template words ("上次", "进展", "请找回") carry no topic information and are removed first.
        let stopPhrases = ["什么时候", "什么时间", "哪一天", "哪天", "几号"]
        var normalized = text
        for phrase in stopPhrases { normalized = normalized.replacingOccurrences(of: phrase, with: " ") }
        return QuestionTerms.topicTerms(normalized)
    }

    private func isHanCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
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
