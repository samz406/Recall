import Foundation

/// Only fixed reason codes leave the processing boundary. No OCR, provider body or keys.
public enum ModelValidationIssue: String, Codable, Sendable {
    case format, structure, coverage, evidence, attribution, time, actionState
    case importantContentMissing, unsupportedClaim, narrative, consolidation

    public var explanation: String {
        switch self {
        case .format: "模型返回的内容格式不完整"
        case .structure: "条目的字段或长度不符合要求"
        case .coverage: "部分输入片段没有被逐一核对"
        case .evidence: "部分结论未能对应到原文片段"
        case .attribution: "人物或说话人的归属尚未核对清楚"
        case .time: "时间或条件未能对应到原文"
        case .actionState: "待办与已确认的归属或状态不一致"
        case .importantContentMissing: "核对发现仍有重要信息被遗漏"
        case .unsupportedClaim: "部分表述超出了来源能够支持的范围"
        case .narrative: "标题或正文仍有重复、碎片或含义不清的问题"
        case .consolidation: "材料尚未归并成可保存的回顾"
        }
    }
    public var repairInstruction: String {
        switch self {
        case .format: "只返回规定结构的完整 JSON，所有必需字段均须存在，使用规定枚举值，不输出解释。"
        case .structure: "检查字段、唯一 ID、条目数及标题和正文的长度；标题完整，正文不重复标题；不要截取半句话。"
        case .coverage: "逐一核对全部输入 ID；每个主片段恰好出现一次，不给 contextOnly 片段独立生成事实。"
        case .evidence: "引用必须逐字出现在给定原文，blockID/factIDs 只能用输入已有 ID；删除无依据的主张，不编造引用。"
        case .attribution: "重新核对角色标记、引用性质、说话人与负责人；未知保留未知，其他人和资料不能成为本人行动。"
        case .time: "保留原文明示的时间、用途和条件；不能确定则 null，不用采集时间补写发生时间或截止时间。"
        case .actionState: "行动仅保留已核对的本人明确承诺且仍未完成、无条件的事项；不满足时保留正确事实或省略行动。"
        case .importantContentMissing: "重新阅读所有主片段与输入事实，补回遗漏的重要结果、变化、限制和阻碍；不靠将其改标 noise/background 消除遗漏。"
        case .unsupportedClaim: "回到原文重写，删除无法支持的主张，保留否定、条件、部分完成和待验证；不升级为确定事实。"
        case .narrative: "用完整短句概括具体事情，正文补充实际变化或限制，不重复标题，不输出泛泛评价和碎片。"
        case .consolidation: "合并同一事情的重复内容，保留变化和最终状态，不合并不同主体或目标。"
        }
    }
}

public struct ReviewGenerationProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case preparing, generating, checking, saving }
    public var stage: Stage
    public var detail: String
    public init(_ stage: Stage, detail: String) { self.stage = stage; self.detail = detail }
    public var title: String {
        switch stage {
        case .preparing: "准备记录"
        case .generating: "生成回顾"
        case .checking: "检查并保存"
        case .saving: "检查并保存"
        }
    }
}

/// A failed page blocks publication, but keeps the checkpoint and identifies what to retry.
public struct ReviewPreparationFailure: LocalizedError, Sendable {
    public var record: Int
    public var total: Int
    public var page: Int
    public var pageCount: Int
    public var reason: String
    public var code: String
    public var errorDescription: String? {
        "准备记录未完成：\(reason)。已保留处理进度和原回顾，可重试。"
    }
    public var detail: String { "第 \(record)/\(total) 条记录 · 第 \(page)/\(pageCount) 段 · \(code)" }
}

public enum ReviewProcessingDiagnostics {
    public static func code(for error: Error) -> String {
        if let failure = error as? ReviewPreparationFailure { return failure.code }
        if let error = error as? CaptureUnderstandingError, case .validation(let issue) = error { return "understanding." + issue.rawValue }
        if let error = error as? CaptureUnderstandingError, case .outputCapacity = error { return "understanding.outputCapacity" }
        if let error = error as? ModelReviewError, case .validation(let issue) = error { return "review." + issue.rawValue }
        if let error = error as? LLMResponseFailure { return "model." + error.reason.rawValue }
        if error is URLError { return "model.connection" }
        return "processing.failed"
    }
    public static func reason(for error: Error) -> String {
        if let error = error as? CaptureUnderstandingError, case .validation(let issue) = error { return issue.explanation + "，自动修正后仍未通过" }
        if let error = error as? CaptureUnderstandingError, case .outputCapacity = error { return error.localizedDescription }
        if let error = error as? LLMResponseFailure { return error.localizedDescription }
        if error is URLError { return "连接模型失败，请检查网络后重试" }
        return "本次记录处理未能完成"
    }
}
