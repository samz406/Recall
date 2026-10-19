import Foundation

/// A matter is a concrete, attributed action, not a window title or an old OCR summary.
/// Re-evaluated for historical captures as well as new ones; original evidence is never edited.
struct MatterEvidence {
    struct Entry {
        var title: String
        var detail: String
        var status: WorkEpisodeStatus
    }

    static func entry(in record: CaptureRecord, proposedTitle: String, userNamed: Bool = false) -> Entry? {
        let title = clean(proposedTitle)
        let segments = RecordedText.segments(in: record)
        var entries: [(entry: Entry, ordinal: Int)] = []
        for segment in segments {
            let text = clean(segment.text)
            guard usableSentence(text) else { continue }
            // An unlabelled page/article and an assistant's report are not the user's work.
            // Explicit regrouping can retain such material as a neutral record, never progress.
            guard segment.speaker == .user || userNamed else { continue }
            let status = segment.speaker == .user ? status(of: text, record: record) : .explored
            guard status != .explored || userNamed else { continue }
            let name: String
            if userNamed, !title.isEmpty { name = title }
            else if let object = subject(in: text), usableTitle(title, app: record.sourceAppName), relates(title, to: object) { name = title }
            else if let subject = subject(in: text), usableTitle(subject, app: record.sourceAppName) { name = subject }
            else { continue }
            entries.append((Entry(title: name, detail: text, status: status), segment.ordinal))
        }
        // Prefer the proposed topic only when the actual sentence supports it. Within that
        // topic use the last statement, so "still failing" cannot be overwritten by old success.
        let related = entries.filter { key($0.entry.title) == key(title) }
        return (related.isEmpty ? entries : related).max { $0.ordinal < $1.ordinal }?.entry
    }

    static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func clean(_ text: String) -> String {
        DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(from: text)
            .replacingOccurrences(of: #"^\s*(?:[-*•]+\s+|\d+[.、)]\s*)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func usableSentence(_ text: String) -> Bool {
        guard (8...420).contains(text.count), !text.contains("…"), !text.contains("..."),
              !matches(text, #"[|×�]|https?://|www\.|[?&][a-z_]+=|[{}]|^\s*(?:import|func|class|public|private|return|const|let)\s"#),
              !matches(text, #"(?:的|与|和|及|把|将|一个|一座|一份|是否能|需要|准备|正在)[。；;]?$"#) else { return false }
        let chrome = ["通讯录", "微盘", "工作台", "新标签", "我的收藏", "有新版", "源码学习", "课外知识", "登录后返回", "网络异常"]
        guard !chrome.contains(where: text.contains) else { return false }
        // These can be useful reading notes, but aren't evidence of an actual personal action.
        return !matches(text, #"^(?:如果|假如|例如|比如|教程|文章|作者|你可以|建议你|请问|如何|为什么|模型会|作为).*"#)
    }

    private static func usableTitle(_ title: String, app: String?) -> Bool {
        guard (3...56).contains(title.count), !title.contains("…"),
              !matches(title, #"[|×�<>={}\n]|(?:https?://|www\.)|\.(?:com|ai|org|net|cn|io)(?:/|$)|^(?:的|与|和|及|、|，|一座|一个)|(?:的|与|和|及|对|把|将|需要|正在)$"#) else { return false }
        let name = key(title)
        let generic = ["google", "百度一下你就知道", "百度", "微信", "微信窗口", "企业微信", "googlechrome", "safari", "chatgpt", "claude", "deepseek", "perplexity", "认证后返回应用", "新标签页", "登录", "搜索", "未分类工作", "具体事项证据不足", "下一步是修复", "已定位原因", "完成更新", "测试通过", "main", "local"]
        guard !generic.contains(name), name != key(app ?? ""),
              !matches(name, #"^[a-f0-9]{6,40}[a-z]?$"#) else { return false }
        return !["通讯录", "微盘", "工作台", "我的收藏", "课外知识", "源码学习"].contains(where: title.contains)
    }

    private static func relates(_ title: String, to text: String) -> Bool {
        guard !title.isEmpty else { return false }
        if key(text).contains(key(title)) { return true }
        let ignored: Set<String> = ["修复", "验证", "测试", "提交", "开发", "实现", "原因", "分析", "修改", "定位", "正在", "计划"]
        let terms = MatterMemoryEngine.subjectTerms(title).subtracting(ignored)
        let shared = terms.filter { text.localizedCaseInsensitiveContains($0) }.count
        return shared >= 2 && shared * 2 >= terms.count
    }

    /// Keep an intact object clause. Never take the first N characters of OCR as a title.
    private static func subject(in text: String) -> String? {
        let patterns = [
            #"^(?:我(?:们)?(?:的)?\s*)?(.{3,48}?)(?:已经|已|仍然|仍|正在|尚未|还没|需要|计划|准备)(?:完成|定位|修复|验证|测试|提交|发布|处理|检查|确认|失败|阻塞|解决|修改|开发|回滚|合并)"#,
            #"^(?:(?:我|我们|今天|昨天|明天|下一步|待办|提醒我|请|已经|已|正在|继续|需要|计划|准备|要|会)[\s:：]*)*(?:完成|推进|修复|优化|重构|开发|实现|排查|分析|设计|验证|测试|提交|发布|处理|编写|接入|迁移|解决|确认|预约|购买|回复|整理|创建|搭建)[了\s:：]*(.{3,48}?)(?=[，。；！;]|$)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let subject = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let generic = ["原因", "修复", "验证", "测试", "其他", "问题", "这个问题", "全部内容", "所有内容", "更新", "代码", "工作", "任务"]
            if !generic.contains(subject), !matches(subject, #"^(?:后|前|并|且|然后|一个|一座)|(?:即可|就行|之后|以后)$"#) { return subject }
        }
        return nil
    }

    private static func status(of text: String, record: CaptureRecord) -> WorkEpisodeStatus {
        guard !matches(text, #"[？?]|如果|假如|例如|比如|据说|文中|文章里|引用|他说|她说|对方说|下一步是修复"#) else { return .explored }
        // The subject must be explicit in this sentence; generic "tests passed" is not enough.
        guard subject(in: text) != nil else { return .explored }
        if matches(text, #"仍然?失败|仍未解决|仍被阻塞|卡住了|被阻塞"#) { return .blocked }
        let mainClause = text.components(separatedBy: CharacterSet(charactersIn: "，,"))[0]
        // "已定位，需要检查边界" contains real progress followed by a future action.
        // Conversely "测试通过后提交" and "尚未测试通过" do not assert success.
        let future = matches(mainClause, #"计划|准备|明天|将会|需要|尚未|未完成|还没|没有|请|待办|提醒我|我要|我会"#)
            || matches(text, #"(?:完成|通过|发布|合并|解决)(?:后|以后|之后|的话|才|就)|未(?:测试|验证)通过"#)
        if !future, matches(text, #"已完成|完成了|已验证通过|验证通过|测试通过|已合并|已发布|已解决|已提交"#) { return .completed }
        if !future, matches(text, #"正在|已定位|已修改|推进了|修复了|实现了"#) { return .progressed }
        var isolated = record
        isolated.ocrText = "[聊天·自己] " + text
        isolated.summary = nil
        return ReminderExtractor().candidates(from: [isolated], existing: []).isEmpty ? .explored : .pending
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
