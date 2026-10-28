import Foundation

/// Splits a question into the words that identify *what* it is about. Words such as "上次" or "进展" fit every
/// question about any topic, so they say nothing about which records are relevant; scoring them equally with the
/// topic words floods results with unrelated records.
public enum QuestionTerms {
    /// Phrases removed before splitting. Longest first so "请找回上次的" goes before "上次".
    static let templatePhrases: [String] = [
        "请找回上次的", "请帮我找回", "请帮我查一下", "请帮我", "请问一下", "请找回", "请问", "请你", "麻烦你", "帮我找回", "帮我查一下", "帮我回忆",
        "已确认的结论", "已确认的", "仍缺少的信息", "仍缺少的", "仍然缺少", "还缺少的", "还缺什么", "还缺少",
        "上次的", "上一次", "上次", "之前的", "之前", "刚才", "最近的", "最近", "目前的", "目前", "现在的", "现在",
        "的进展", "进展", "进度", "情况", "状态", "结论", "结果", "信息", "内容", "相关的", "相关", "有关", "关于",
        "是什么", "是怎样", "怎么样", "怎么办", "怎么", "如何", "为什么", "能不能", "可以", "告诉我", "给我", "找回", "回忆", "查一下", "看一下", "看下"
    ]
    static let stopWords: Set<String> = ["我", "的", "了", "和", "是", "在", "有", "什么", "哪些", "一下", "帮我", "请", "内容", "the", "a", "an", "is", "are", "to", "of", "and", "for", "about", "what", "how", "last", "time"]

    /// Two-character pieces that appear in any sentence and only add noise when split off a longer run.
    static let pieceStopwords: Set<String> = ["的进", "次的", "认的", "论和", "和仍", "少的", "的信", "的结", "的是", "是否", "了吗", "吗？", "一个", "这个", "那个", "我的", "你的", "他的", "它的", "过的", "在的"]

    /// Normalized topic words in question order, without duplicates. Latin words stay whole; long Chinese runs add
    /// overlapping two-character pieces only for runs that stay after template removal.
    public static func topicTerms(_ question: String) -> [String] {
        var text = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for phrase in templatePhrases.sorted(by: { $0.count > $1.count }) { text = text.replacingOccurrences(of: phrase, with: " ") }
        var terms: [String] = []
        for token in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            guard token.count > 1 || token.contains(where: { $0.isNumber }) && token.count > 0, !stopWords.contains(token) else { continue }
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
        var text = question
        for phrase in templatePhrases.sorted(by: { $0.count > $1.count }) { text = text.replacingOccurrences(of: phrase, with: " ") }
        return text
    }

    private static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x2FA1F).contains($0.value) }
    }
}
