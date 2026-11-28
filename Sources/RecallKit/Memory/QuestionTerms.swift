import Foundation

/// Splits a question into the words that identify *what* it is about. Words such as "上次" or "进展" fit every
/// question about any topic, so they say nothing about which records are relevant; scoring them equally with the
/// topic words floods results with unrelated records.
public enum QuestionTerms {
    /// Phrases removed before splitting. Longest first so "请找回上次的" goes before "上次".
    static let templatePhrases: [String] = [
        "请找回上次的", "请帮我找回", "请帮我查一下", "请帮我梳理下", "请帮我梳理", "请帮我总结", "请帮我",
        "请问一下", "请找回", "请问", "请你", "麻烦你", "帮我找回", "帮我查一下", "帮我回忆", "帮我梳理一下", "帮我梳理下", "帮我梳理", "帮我总结一下", "帮我总结",
        "你梳理一下", "你梳理下", "梳理一下", "梳理下", "总结一下", "总结下", "回顾一下", "回顾下", "汇总一下", "汇总下",
        "已确认的结论", "已确认的", "仍缺少的信息", "仍缺少的", "仍然缺少", "还缺少的", "还缺什么", "还缺少",
        "都回复了什么", "回复了什么", "回答了什么", "都说了什么", "说了什么", "写的什么", "什么意思", "啥意思",
        "没看懂", "看不懂", "简单说一下", "简单说下", "说简单点", "精简一下", "重新整理一下", "重新整理",
        "最近一个星期", "过去一个星期", "最近一个月", "过去一个月", "近一个月", "最近一周", "过去一周", "近一周", "最近几天",
        "我学了哪些", "我学了什么", "我做了哪些", "我做了什么", "学了哪些", "学了什么", "做了哪些", "做了什么", "干了哪些", "干了什么",
        "后来怎样了", "后来怎么样", "后来进展怎样", "后来进展", "后来呢",
        "上次的", "上一次", "上次", "之前的", "之前", "刚才", "最近的", "最近", "目前的", "目前", "现在的", "现在", "当前状态", "当前的", "当前",
        "本周", "这周", "上周", "今天", "今日", "昨天", "昨日", "前天", "一周",
        "的进展", "进展", "进度", "情况", "状态", "结论", "结果", "信息", "内容", "相关的", "相关", "有关", "关于",
        "是什么", "是怎样", "怎么样", "怎么办", "怎么", "如何", "为什么", "能不能", "可以",
        "有哪些", "有什么", "哪些", "什么", "告诉我", "给我", "找回", "回忆", "查一下", "看一下", "看下", "梳理"
    ]
    static let stopWords: Set<String> = [
        "我", "你", "他", "她", "它", "的", "了", "和", "是", "在", "有", "什么", "哪些", "一下", "帮我", "请", "内容",
        "一", "天", "周", "月", "年", "吗", "呢", "么", "吧", "啊", "呀", "啦", "哦", "嘛", "这", "那", "都", "回复", "回答",
        "the", "a", "an", "is", "are", "to", "of", "and", "for", "about", "what", "how", "last", "time"
    ]

    /// Two-character pieces that appear in any sentence and only add noise when split off a longer run.
    static let pieceStopwords: Set<String> = [
        "的进", "次的", "认的", "论和", "和仍", "少的", "的信", "的结", "的是", "是否", "了吗", "吗？",
        "一个", "这个", "那个", "我的", "你的", "他的", "它的", "过的", "在的",
        "一周", "周我", "我学", "学了", "了哪", "哪些", "些管", "周有", "有什", "你梳", "梳理", "理下"
    ]

    /// Separates adjacent CJK and non-CJK alphanumeric runs so "你梳理下recall" yields both scripts cleanly.
    private static func separateScriptBoundaries(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count + 8)
        var previousHan: Bool?
        for character in source {
            if character.isLetter || character.isNumber {
                let currentHan = isHan(character)
                if let previousHan, previousHan != currentHan {
                    result.append(" ")
                }
                previousHan = currentHan
            } else {
                previousHan = nil
            }
            result.append(character)
        }
        return result
    }

    /// Normalized topic words in question order, without duplicates. Latin words stay whole; long Chinese runs add
    /// overlapping two-character pieces only for runs that stay after template removal.
    public static func topicTerms(_ question: String) -> [String] {
        var text = separateScriptBoundaries(question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        for phrase in templatePhrases.sorted(by: { $0.count > $1.count }) { text = text.replacingOccurrences(of: phrase, with: " ") }
        var terms: [String] = []
        for token in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            guard token.count > 1 || token.contains(where: { $0.isNumber }) && token.count > 0, !stopWords.contains(token), !pieceStopwords.contains(token) else { continue }
            if token.contains(where: isHan) {
                // The whole run for exact phrases, plus overlapping two-character pieces so "妙妙过生日" still
                // reaches "生日". Template words are already gone, so the pieces left are topic material.
                let chars = Array(token)
                terms.append(token)
                if chars.count > 2 {
                    for index in 0..<(chars.count - 1) {
                        let pair = String(chars[index...index + 1])
                        if pair.allSatisfy(isHan), !stopWords.contains(pair), !pieceStopwords.contains(pair) { terms.append(pair) }
                    }
                }
            } else { terms.append(token) }
        }
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    /// The question with template phrases removed, for the older two-character term extraction.
    public static func stripped(_ question: String) -> String {
        var text = separateScriptBoundaries(question)
        for phrase in templatePhrases.sorted(by: { $0.count > $1.count }) { text = text.replacingOccurrences(of: phrase, with: " ") }
        return text
    }

    private static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x2FA1F).contains($0.value) }
    }

    static func isIndexedTerm(_ term: String) -> Bool {
        term.count > 1 && !stopWords.contains(term) && !pieceStopwords.contains(term)
    }

    /// Words and two-character pieces written when a capture is saved. Questions look these up
    /// instead of reading every saved text again.
    public static func documentTerms(_ text: String) -> [String] {
        let folded = separateScriptBoundaries(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        var seen = Set<String>()
        var terms: [String] = []
        func add(_ term: String) {
            guard isIndexedTerm(term), seen.insert(term).inserted else { return }
            terms.append(term)
        }
        for token in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(token)
            if word.contains(where: isHan) {
                let chars = Array(word)
                if chars.count <= 12 { add(word) }
                for pair in pairs(in: chars) { add(pair) }
            } else if word.count <= 40 { add(word) }
        }
        return terms
    }

    /// How a question's topic terms hit the saved-text index. Each group is a phrase that must
    /// occur together; groups and whole words are combined by union.
    public static func termLookup(_ terms: [String]) -> (groups: [[String]], words: [String]) {
        let phrases = terms.filter { $0.count >= 4 && $0.contains(where: isHan) }
        let words = terms.filter { !$0.contains(where: isHan) && isIndexedTerm($0) }
        if phrases.isEmpty && words.isEmpty {
            let pairs = terms.filter { $0.count == 2 && $0.allSatisfy(isHan) && isIndexedTerm($0) }
            return (pairs.map { [$0] }, [])
        }
        var groups: [[String]] = []
        for phrase in phrases {
            let chars = Array(phrase)
            if chars.count <= 4 {
                let keys = pairs(in: chars)
                if !keys.isEmpty { groups.append(keys) }
            } else {
                let last = min(chars.count - 4, 10)
                for offset in 0...last {
                    let keys = pairs(in: Array(chars[offset..<(offset + 4)]))
                    if !keys.isEmpty { groups.append(keys) }
                }
            }
        }
        return (groups, words)
    }

    /// Constituent two-character Han words used only when exact 4-character phrase lookup returns sparse results
    /// (for example "管理知识" matching notes that write "管理决策" or "知识体系" separately).
    static func fallbackPairs(_ terms: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for phrase in terms where phrase.count >= 4 && phrase.allSatisfy(isHan) {
            let chars = Array(phrase)
            var index = 0
            while index + 1 < chars.count {
                let pair = String(chars[index...index + 1])
                if isIndexedTerm(pair), seen.insert(pair).inserted { result.append(pair) }
                index += 2
            }
            if chars.count % 2 == 1, chars.count >= 3 {
                let tail = String(chars[(chars.count - 2)...(chars.count - 1)])
                if isIndexedTerm(tail), seen.insert(tail).inserted { result.append(tail) }
            }
        }
        return result
    }

    private static func pairs(in chars: [Character]) -> [String] {
        guard chars.count > 1 else { return [] }
        var result: [String] = []
        for index in 0..<(chars.count - 1) {
            let pair = String(chars[index...index + 1])
            guard pair.allSatisfy(isHan), isIndexedTerm(pair) else { continue }
            result.append(pair)
        }
        return result
    }
}
