import Foundation
import Security

public enum CredentialError: LocalizedError {
    case unavailable, accessDenied, endpointChanged
    public var errorDescription: String? {
        switch self {
        case .unavailable: RecallLocalization.text("无法读取模型凭据，请解锁钥匙串或重新配置连接。")
        case .accessDenied: RecallLocalization.text("钥匙串保存失败，原配置未修改。请重试。")
        case .endpointChanged: RecallLocalization.text("服务地址已更换，请重新输入该服务的 API Key。")
        }
    }
}
public protocol CredentialStore: Sendable {
    func read(_ id: UUID) throws -> String?
    func write(_ value: String, id: UUID) throws
    func delete(_ id: UUID) throws
}
/// macOS login Keychain works with both the existing developer app and Developer ID builds.
/// No iCloud synchronisation, shared access groups, custom cryptography or plaintext fallback.
/// A future data-protection Keychain migration requires a signed/provisioned App and CLI.
public struct KeychainCredentialStore: CredentialStore {
    public static let shared = KeychainCredentialStore()
    public init() {}
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "im.recall.app.model-credentials",
         kSecAttrAccount as String: id.uuidString]
    }
    public func read(_ id: UUID) throws -> String? {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw CredentialError.unavailable }
        return text
    }
    public func write(_ value: String, id: UUID) throws {
        let q = query(id), data = Data(value.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CredentialError.accessDenied }; return
        }
        guard status == errSecSuccess else { throw CredentialError.accessDenied }
    }
    public func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.accessDenied }
    }
}
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    public init() {}
    public func read(_ id: UUID) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[id] }
    public func write(_ value: String, id: UUID) throws { lock.lock(); defer { lock.unlock() }; values[id] = value }
    public func delete(_ id: UUID) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id) }
}
public enum ModelResponderFactory {
    public static func make(configuration: LLMConfiguration, credentials: any CredentialStore = KeychainCredentialStore.shared) throws -> CompatibleLLM {
        guard LLMConfiguration.credentialOrigin(configuration.baseURLString) != nil else { throw LLMError.invalidBaseURL }
        let key = configuration.apiKey.isEmpty ? try credentials.read(configuration.connectionID) : configuration.apiKey
        guard let key, !key.isEmpty else { throw CredentialError.unavailable }
        return CompatibleLLM(configuration: configuration, apiKey: key)
    }
}
extension FileMemoryStore {
    public func retryCredentialMaintenance() throws {
        if let pending = pendingLegacyCredential {
            let before = state
            if try credentials.read(pending.id) == nil { try credentials.write(pending.key, id: pending.id) }
            guard try credentials.read(pending.id) != nil else { throw CredentialError.unavailable }
            state.llmConfiguration.credentialReference = pending.id.uuidString; state.llmConfiguration.credentialRevision += 1
            pendingLegacyCredential = nil
            do { try persistReviewState() } catch { state = before; pendingLegacyCredential = pending; throw error }
        }
        do { try Self.scrubLegacyBackups(in: storage.rootURL); credentialMaintenanceWarning = nil }
        catch { credentialMaintenanceWarning = "Legacy backup cleanup failed; retry from Settings."; throw error }
    }

    public func modelResponder() throws -> CompatibleLLM { try ModelResponderFactory.make(configuration: state.llmConfiguration, credentials: credentials) }
    public func deleteModelCredential() throws {
        let before = state
        let config = state.llmConfiguration
        let key = try credentials.read(config.connectionID)
        try credentials.delete(config.connectionID)
        state.llmConfiguration.credentialReference = nil; state.llmConfiguration.apiKey = ""
        state.llmConfiguration.credentialRevision += 1
        reconcileDailyReviewCheckpoints()
        do { try persistReviewState() }
        catch { state = before; if let key { try? credentials.write(key, id: config.connectionID) }; throw error }
    }
}
