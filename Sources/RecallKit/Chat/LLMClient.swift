import Foundation
import Security

public enum LLMProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case localOnly
    case openAICompatible

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .localOnly: "本地摘要模式"
        case .openAICompatible: "兼容 OpenAI 的云端模型"
        }
    }
}

public struct LLMConfiguration: Codable, Hashable, Sendable {
    public var provider: LLMProviderKind
    public var baseURLString: String
    public var model: String
    public var keychainAccount: String

    public init(
        provider: LLMProviderKind = .localOnly,
        baseURLString: String = "https://api.openai.com/v1",
        model: String = "gpt-4.1-mini",
        keychainAccount: String = "cloud-model-api-key"
    ) {
        self.provider = provider
        self.baseURLString = baseURLString
        self.model = model
        self.keychainAccount = keychainAccount
    }
}

public struct LLMRequest: Sendable {
    public var question: String
    public var context: [CaptureRecord]

    public init(question: String, context: [CaptureRecord]) {
        self.question = question
        self.context = context
    }
}

public struct LLMAnswer: Sendable {
    public var content: String
    public var citedCaptureIDs: [UUID]

    public init(content: String, citedCaptureIDs: [UUID]) {
        self.content = content
        self.citedCaptureIDs = citedCaptureIDs
    }
}

public enum LLMError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case invalidResponse
    case serviceError(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "尚未在设置中配置云端模型密钥。"
        case .invalidBaseURL: "云端模型地址无效。"
        case .invalidResponse: "模型服务返回了无法识别的响应。"
        case .serviceError(let message): "模型服务请求失败：\(message)"
        }
    }
}

public protocol LLMResponding: Sendable {
    func answer(to request: LLMRequest) async throws -> LLMAnswer
}

public struct ExtractiveMemoryResponder: LLMResponding {
    public init() {}

    public func answer(to request: LLMRequest) async throws -> LLMAnswer {
        guard !request.context.isEmpty else {
            return LLMAnswer(content: "我没有在本地记忆中找到与“\(request.question)”相关的记录。你可以先使用“记录此刻”保存一个工作节点。", citedCaptureIDs: [])
        }

        let citationLines = request.context.enumerated().map { index, record in
            let date = record.createdAt.formatted(date: .abbreviated, time: .shortened)
            let excerpt = record.ocrText.replacingOccurrences(of: "\n", with: " ").prefix(260)
            return "[\(index + 1)] \(date) · \(record.sourceAppName ?? "未知来源")：\(excerpt)"
        }
        let preface = "以下是基于本地检索记录的可追溯摘要；它不使用云端模型。"
        return LLMAnswer(content: "\(preface)\n\n\(citationLines.joined(separator: "\n\n"))", citedCaptureIDs: request.context.map(\.id))
    }
}

public struct OpenAICompatibleLLM: LLMResponding {
    private let configuration: LLMConfiguration
    private let apiKey: String
    private let session: URLSession

    public init(configuration: LLMConfiguration, apiKey: String, session: URLSession = .shared) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.session = session
    }

    public func answer(to request: LLMRequest) async throws -> LLMAnswer {
        guard let baseURL = URL(string: configuration.baseURLString) else { throw LLMError.invalidBaseURL }
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        let context = request.context.enumerated().map { index, record in
            let timestamp = record.createdAt.formatted(date: .abbreviated, time: .shortened)
            return "来源 [\(index + 1)]（\(timestamp)，\(record.sourceAppName ?? "未知应用")）：\n\(record.ocrText)"
        }.joined(separator: "\n\n")

        let system = """
        你是 Recall 的个人记忆助理。只根据提供的记忆来源回答；不确定时明确说明。
        使用简体中文回答。每个事实性结论后以 [数字] 标明来源。不要执行任何外部操作。
        """
        let body = OpenAIRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: "问题：\(request.question)\n\n可用记忆：\n\(context)")
            ],
            temperature: 0.2
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw LLMError.serviceError(detail)
        }
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw LLMError.invalidResponse
        }
        return LLMAnswer(content: content, citedCaptureIDs: request.context.map(\.id))
    }
}

private struct OpenAIRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }

    let choices: [Choice]
}

public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()
    private let service = "im.recall.app"

    private init() {}

    public func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var addition = query
        addition[kSecValueData as String] = data
        let status = SecItemAdd(addition as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

public enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): "钥匙串操作失败（状态码：\(status)）。"
        }
    }
}
