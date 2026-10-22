import Foundation
import CryptoKit

/// A matter is a concrete, attributed action, not a window title or an old OCR summary.
/// Re-evaluated for historical captures as well as new ones; original evidence is never edited.
struct MatterEvidence {
    struct Entry {
        var title: String
        var detail: String
        var status: WorkEpisodeStatus
        var nextAction: String? = nil
        var ordinal: Int = 0
        var resultStatus: WorkEpisodeStatus? = nil
    }

    static func entries(in record: CaptureRecord, proposedTitle: String, userNamed: Bool = false) -> [Entry] {
        let title = clean(proposedTitle)
        let segments = RecordedText.segments(in: record)
        var entries: [(entry: Entry, ordinal: Int)] = []
        for segment in segments {
            let text = clean(segment.text)
            guard usableSentence(text) else { continue }
            // An unlabelled page/article and an assistant's report are not the user's work.
            // Explicit regrouping can retain such material as a neutral record, never progress.
            guard segment.speaker == .user || userNamed else { continue }
            let status = segment.speaker == .user ? status(of: text) : .explored
            guard status != .explored || userNamed else { continue }
            let name: String
            if userNamed, !title.isEmpty { name = title }
            else if let object = subject(in: text), usableTitle(title, app: record.sourceAppName), relates(title, to: object) { name = title }
            else if let subject = subject(in: text), usableTitle(subject, app: record.sourceAppName) { name = subject }
            else { continue }
            entries.append((Entry(title: name, detail: text, status: status), segment.ordinal))
        }
        // A later todo is a next action, not a replacement for a concrete progress/result.
        // Keep separate topics separate, and never fill missing content from an old summary.
        let topics = Dictionary(grouping: entries) { key($0.entry.title) }
        return topics.values.flatMap { topic -> [Entry] in
            let ordered = topic.sorted { $0.ordinal < $1.ordinal }
            guard let last = ordered.last else { return [] }
            let actual = ordered.filter { $0.entry.status != .pending }
            guard let latest = actual.last else {
                var result = last.entry; result.ordinal = last.ordinal
                return [result]
            }
            // Keep every observed change, including other topics in the same screenshot.
            var result = actual.map { row -> Entry in
                var value = row.entry; value.ordinal = row.ordinal; return value
            }
            if let action = ordered.last(where: { $0.entry.status == .pending && $0.ordinal > latest.ordinal }) {
                result[result.count - 1].nextAction = action.entry.detail
                if result[result.count - 1].status == .completed {
                    result[result.count - 1].resultStatus = .completed
                    result[result.count - 1].status = .pending
                }
            }
            return result
        }.sorted { $0.ordinal < $1.ordinal }
    }

    /// Stable event identity is separate from the shared screenshot/source identity.
    static func eventID(source: UUID, topic: String, ordinal: Int) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(source.uuidString):\(topic):\(ordinal)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func clean(_ text: String) -> String {
        DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(from: text)
            .replacingOccurrences(of: #"^\s*(?:[-*•]+\s+|\d+[.、)]\s*|[①-⑳]\s*)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func usableSentence(_ text: String) -> Bool {
        guard (8...420).contains(text.count), !text.contains("…"), !text.contains("..."),
              !matches(text, #"[|×�]|https?://|www\.|[?&][a-z_]+=|[{}]|^\s*(?:import|func|class|public|private|return|const|let)\s"#),
              !matches(text, #"(?:的|与|和|及|把|将|一个|一座|一份|是否能|需要|准备|正在)[。；;]?$"#) else { return false }
        let chrome = ["通讯录", "微盘", "工作台", "新标签", "我的收藏", "有新版", "源码学习", "课外知识", "登录后返回", "网络异常"]
        guard !chrome.contains(where: text.contains) else { return false }
        // These can be useful reading notes, but aren't evidence of an actual personal action.
        return !matches(text, #"^(?:如果|假如|假设|例如|比如|教程(?:[：:]|中|里|步骤|介绍|说明)|文章(?:[：:]|中|里|提到|指出|观点|案例|介绍|认为)|作者(?:认为|指出|表示|提到|建议)|你(?:们)?(?:可以|需要|应该|必须|要)|建议|请问|如何|为什么|模型会|作为|当你|只要|每个人|人们|不要|步骤[一二三四五六七八九十\d：:]|方法[一二三四五六七八九十\d：:]|(?:重试|再试|尝试)(?:几|多|数|[一二三四五六七八九十\d两]+)(?:次|回)|(?:重新启动|完全退出)(?:应用|客户端|程序|后|再|。|$)).*"#)
            && !matches(text, #"(?:过去|以前|曾经|从前).*(?:才能|能够|可以)|(?:失败|不成功)(?:后|时|的话).*(?:退出|重启|重试)|^(?:先|再).*(?:点击|打开|退出|重启)"#)
    }

    private static func usableTitle(_ title: String, app: String?) -> Bool {
        guard (3...56).contains(title.count), !title.contains("…"),
              !matches(title, #"[|×�<>={}\n，,。；;！？!?]|(?:https?://|www\.)|\.(?:com|ai|org|net|cn|io)(?:/|$)|^(?:的|与|和|及|、|，|一座|一个)|(?:的|与|和|及|对|把|将|需要|正在)$"#) else { return false }
        let name = key(title)
        let generic = ["google", "百度一下你就知道", "百度", "微信", "微信窗口", "企业微信", "googlechrome", "safari", "chatgpt", "claude", "deepseek", "perplexity", "认证后返回应用", "新标签页", "登录", "搜索", "未分类工作", "具体事项证据不足", "下一步是修复", "已定位原因", "完成更新", "测试通过", "main", "local"]
        guard !generic.contains(name), name != key(app ?? ""),
              !matches(name, #"^[a-f0-9]{6,40}[a-z]?$"#) else { return false }
        return concreteSubject(title)
            && !["通讯录", "微盘", "工作台", "我的收藏", "课外知识", "源码学习"].contains(where: title.contains)
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
            #"^(?:我(?:们)?(?:的)?\s*)?([^，,。；;！？!?\n]{3,48}?)(?:已经|已|仍然|仍在|仍|正在|尚未|还没|需要|计划|准备)(?:完成|定位|修复|验证|测试|提交|发布|处理|检查|确认|失败|阻塞|解决|修改|开发|回滚|合并)"#,
            #"^(?:(?:我|我们|今天|昨天|明天|今晚|本周|下周|下一步|接下来|待办|提醒我|请|已经|已|正在|继续|需要|计划|准备|要|会|将)[\s:：]*)*(?:完成|推进|修复|优化|重构|开发|实现|排查|分析|定位|修改|设计|验证|测试|提交|发布|处理|检查|编写|接入|迁移|解决|确认|预约|购买|回复|整理|创建|搭建)[了\s:：]*([^，,。；;！？!?\n]{3,48}?)(?=[，,。；;！？!?]|$)"#,
            #"^(?:我(?:们)?(?:的)?\s*)?([^，,。；;！？!?\n]{3,48}?)(?:仍未解决|卡住了|被阻塞|持续失败)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let subject = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if concreteSubject(subject) { return subject }
        }
        return nil
    }

    /// A verb alone does not identify a matter. An object must carry enough information
    /// to distinguish it from a generic instruction, slogan or unnamed piece of work.
    private static func concreteSubject(_ subject: String) -> Bool {
        guard (3...56).contains(subject.count),
              !matches(subject, #"^(?:并|且|然后|一个|一座|过去|以前|未来|整个|任何|这些|那些|这种|这样|它|这个|某个)|^(?:重试|再试|尝试)(?:几|多|数|[一二三四五六七八九十\d两]+)(?:次|回)|^(?:重新|再次|点击|打开|关闭|返回|退出|切换|等待)(?:应用|客户端|程序|窗口|页面|系统|网络|连接|结果)$|才能|能够|应该|可以|需要.*(?:组织|团队|公司|人们)|(?:即可|就行|之后|以后)$"#) else { return false }
        let generic: Set<String> = ["原因", "根因", "根本原因", "具体原因", "异常原因", "故障原因", "修复", "验证", "测试", "其他", "问题", "全部内容", "所有内容", "更新", "代码", "工作", "任务",
            "游戏代码", "游戏逻辑", "程序代码", "代码实现", "功能代码", "功能实现", "项目开发", "系统开发", "接口开发", "开发工作", "测试工作", "工作内容", "任务内容", "当前项目", "当前任务", "下一步", "修复工作", "生产环境", "测试环境", "重新打开", "重新启动", "再次尝试"]
        return !generic.contains(key(subject))
    }

    private static func status(of text: String) -> WorkEpisodeStatus {
        guard !matches(text, #"[？?]|如果|假如|例如|比如|据说|文中|文章里|引用|他说|她说|对方说|下一步是修复"#) else { return .explored }
        // The subject must be explicit in this sentence; generic "tests passed" is not enough.
        guard subject(in: text) != nil else { return .explored }
        let mainClause = text.components(separatedBy: CharacterSet(charactersIn: "，,"))[0]
        if matches(mainClause, #"仍然?失败|仍未解决|仍被阻塞|卡住了|被阻塞|持续失败"#) { return .blocked }
        // "已定位，需要检查边界" contains real progress followed by a future action.
        // Conversely "测试通过后提交" and "尚未测试通过" do not assert success.
        let future = matches(mainClause, #"计划|准备|明天|将会|需要|尚未|未完成|还没|没有|请|待办|提醒我|我要|我会"#)
            || matches(mainClause, #"(?:完成|通过|发布|合并|解决)(?:后|以后|之后|的话|才|就)|未(?:测试|验证)通过"#)
        if !future, matches(mainClause, #"已完成|完成了|已验证通过|验证通过|测试通过|已合并|已发布|已解决|已提交"#) { return .completed }
        if !future, matches(mainClause, #"正在|仍在|已定位|已修改|已修复|推进了|修复了|实现了"#) { return .progressed }
        // Do not promote every "完成/需要" into a todo through the reminder extractor.
        // Only an explicit personal commitment with a concrete object is an open action.
        guard !matches(text, #"准备|打算|希望|想要|计划|(?:完成|通过|发布|合并|解决)(?:后|以后|之后|的话|才|就)"#),
              matches(mainClause, #"^(?:我(?:们)?(?:今天|明天|今晚|本周|下周)?(?:需要|要|会|将)|(?:今天|明天|今晚|本周|下周)\s*(?:(?:需要|要|我会)\s*)?|(?:接下来|下一步)\s*(?:需要|要|我会)|待办[：:]?|提醒我|需要|请提醒我)"#) else { return .explored }
        return .pending
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
