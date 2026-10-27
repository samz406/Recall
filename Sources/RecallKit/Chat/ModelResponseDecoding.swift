import Foundation

/// Diagnostic fields are generated from enums and integers only. Never store a provider's
/// body, reasoning, refusal text, credentials or request/response fragments in an error.
public struct LLMResponseFailure: LocalizedError, Sendable {
    public enum Reason: String, Sendable {
        case truncated, reasoningOnly, empty, invalidFormat, structuredFormat
        case refusal, toolRequest, contextLimit, authentication, rateLimited, service
    }
    public let reason: Reason
    public let provider: LLMProviderKind?
    public let outputLimit: Int?
    private let stop: String?
    private let generatedTokens: Int?
    private let status: Int?
    private let serviceCode: Int?

    public init(reason: Reason, provider: LLMProviderKind? = nil, outputLimit: Int? = nil,
                stop: String? = nil, generatedTokens: Int? = nil, status: Int? = nil, serviceCode: Int? = nil) {
        self.reason = reason; self.provider = provider; self.outputLimit = outputLimit
        let known = ["length", "max_tokens", "stop", "end_turn", "stop_sequence", "refusal", "content_filter",
                     "tool_calls", "function_call", "tool_use", "pause_turn", "model_context_window_exceeded"]
        self.stop = stop.map { known.contains($0) ? $0 : "unknown" }
        self.generatedTokens = generatedTokens.flatMap { (0...1_000_000).contains($0) ? $0 : nil }
        self.status = status.flatMap { (100...599).contains($0) ? $0 : nil }
        self.serviceCode = serviceCode.flatMap { (0...1_000_000).contains($0) ? $0 : nil }
    }
    public var errorDescription: String? {
        switch reason {
        case .truncated: "模型输出达到上限，未生成完整回答。可稍后重试或更换模型。"
        case .reasoningOnly: "模型只返回了推理信息，没有回答正文。请重试或调整模型设置。"
        case .empty: "模型服务没有返回回答正文，请稍后重试。"
        case .invalidFormat: "模型服务的响应格式与所选接口不匹配，请检查连接类型和 API 地址。"
        case .structuredFormat: "模型未按回顾格式返回完整内容，请重新生成。"
        case .refusal: "模型未提供本次回答，已有内容已保留。"
        case .toolRequest: "模型返回了工具调用而非回答正文，请使用可直接返回文本的模型。"
        case .contextLimit: "本次资料超出模型上下文容量，请换用容量更大的模型。"
        case .authentication: "模型服务认证失败，请检查 API Key 和连接类型。"
        case .rateLimited: "模型服务当前限流或额度不足，请稍后重试并检查服务用量。"
        case .service:
            status == 200
                ? "模型服务返回了业务错误\(serviceCode.map { "（服务代码 \($0)）" } ?? "")，请检查服务状态或用量。"
                : "模型服务暂时无法处理请求\(status.map { "（HTTP \($0)）" } ?? "")，请稍后重试。"
        }
    }
    public var diagnosticMetadata: [String: String] {
        var fields = ["modelReason": reason.rawValue]
        if let provider { fields["modelProtocol"] = provider.rawValue }
        if let outputLimit { fields["outputBudget"] = String(outputLimit) }
        if let stop { fields["modelStop"] = stop }
        if let generatedTokens { fields["generatedTokens"] = String(generatedTokens) }
        if let status { fields["httpStatus"] = String(status) }
        if let serviceCode { fields["providerStatus"] = String(serviceCode) }
        return fields
    }
}

enum ModelResponseDecoding {
    static func text(from data: Data, provider: LLMProviderKind, outputLimit: Int) throws -> String {
        guard let root = object(data) else {
            throw LLMResponseFailure(reason: .invalidFormat, provider: provider, outputLimit: outputLimit)
        }
        if hasError(root) { throw serviceFailure(root, status: 200, provider: provider, outputLimit: outputLimit) }
        let usage = root["usage"] as? [String: Any] ?? [:]
        let tokens = integer(usage[provider == .anthropicCompatible ? "output_tokens" : "completion_tokens"])
        let stop: String?
        let content: Any?
        let reasoning: Bool
        let tools: Bool
        let refusal: Bool
        switch provider {
        case .openAICompatible:
            guard let choices = root["choices"] as? [[String: Any]] else {
                throw LLMResponseFailure(reason: .invalidFormat, provider: provider, outputLimit: outputLimit)
            }
            guard let choice = choices.first else { throw LLMResponseFailure(reason: .empty, provider: provider, outputLimit: outputLimit) }
            guard let message = choice["message"] as? [String: Any],
                  message["role"] == nil || message["role"] as? String == "assistant" else {
                throw LLMResponseFailure(reason: .invalidFormat, provider: provider, outputLimit: outputLimit)
            }
            stop = choice["finish_reason"] as? String
            content = message["content"]
            reasoning = nonempty(message["reasoning_content"]) != nil || nonempty(message["reasoning"]) != nil
            tools = !(message["tool_calls"] as? [Any] ?? []).isEmpty || message["function_call"] as? [String: Any] != nil
            refusal = nonempty(message["refusal"]) != nil
        case .anthropicCompatible:
            guard let blocks = root["content"] as? [[String: Any]] else {
                throw LLMResponseFailure(reason: .invalidFormat, provider: provider, outputLimit: outputLimit)
            }
            stop = root["stop_reason"] as? String
            content = blocks
            reasoning = blocks.contains { ["thinking", "redacted_thinking", "reasoning"].contains($0["type"] as? String ?? "") }
            tools = blocks.contains { $0["type"] as? String == "tool_use" }
            refusal = false
        case .localOnly:
            throw LLMResponseFailure(reason: .invalidFormat, provider: provider, outputLimit: outputLimit)
        }
        func failure(_ reason: LLMResponseFailure.Reason) -> LLMResponseFailure {
            LLMResponseFailure(reason: reason, provider: provider, outputLimit: outputLimit, stop: stop, generatedTokens: tokens)
        }
        // Even nonempty text can be a cut JSON document or an unfinished claim.
        if stop == "length" || stop == "max_tokens" { throw failure(.truncated) }
        if stop == "model_context_window_exceeded" { throw failure(.contextLimit) }
        if refusal || stop == "refusal" || stop == "content_filter" { throw failure(.refusal) }
        if tools || ["tool_calls", "function_call", "tool_use", "pause_turn"].contains(stop ?? "") { throw failure(.toolRequest) }
        let answer: String?
        if let string = content as? String { answer = nonempty(string) }
        else if let blocks = content as? [[String: Any]] {
            answer = nonempty(blocks.compactMap { block -> String? in
                guard ["text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
                return nonempty(block["text"])
            }.joined(separator: "\n"))
        } else if content == nil || content is NSNull { answer = nil }
        else { throw failure(.invalidFormat) }
        guard let answer else { throw failure(reasoning ? .reasoningOnly : .empty) }
        return answer
    }
    static func httpFailure(_ data: Data, status: Int, provider: LLMProviderKind, outputLimit: Int) -> LLMResponseFailure {
        serviceFailure(object(data) ?? [:], status: status, provider: provider, outputLimit: outputLimit)
    }
    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func hasError(_ root: [String: Any]) -> Bool {
        if root["error"] as? [String: Any] != nil || nonempty(root["error"]) != nil || root["type"] as? String == "error" { return true }
        if let base = root["base_resp"] as? [String: Any], let code = integer(base["status_code"]), code != 0 { return true }
        return false
    }
    private static func serviceFailure(_ root: [String: Any], status: Int, provider: LLMProviderKind, outputLimit: Int) -> LLMResponseFailure {
        let error = root["error"] as? [String: Any] ?? [:]
        let code = error["code"] as? String ?? error["type"] as? String ?? ""
        let reason: LLMResponseFailure.Reason
        if ["context_length_exceeded", "request_too_large", "request_too_large_error"].contains(code) || status == 413 { reason = .contextLimit }
        else if [401, 403].contains(status) || ["authentication_error", "invalid_api_key", "permission_error"].contains(code) { reason = .authentication }
        else if status == 429 || ["rate_limit_error", "rate_limit_exceeded", "insufficient_quota"].contains(code) { reason = .rateLimited }
        else { reason = .service }
        return LLMResponseFailure(reason: reason, provider: provider, outputLimit: outputLimit, status: status, serviceCode: integer((root["base_resp"] as? [String: Any])?["status_code"]))
    }
    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite,
              (0...1_000_000).contains(number.doubleValue) else { return nil }
        return number.intValue
    }
}
