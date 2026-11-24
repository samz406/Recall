import Foundation

public struct PrivacyDecision: Sendable, Equatable {
    public var mayCapture: Bool
    public var reason: String?

    public init(mayCapture: Bool, reason: String? = nil) {
        self.mayCapture = mayCapture
        self.reason = reason
    }
}

public struct PrivacyEngine: Sendable {
    public init() {}

    public func decision(for bundleIdentifier: String?, settings: PrivacySettings) -> PrivacyDecision {
        guard !settings.screenCapturePaused else {
            return PrivacyDecision(mayCapture: false, reason: "用户已暂停屏幕采集。")
        }
        guard let bundleIdentifier else { return PrivacyDecision(mayCapture: true) }
        if settings.excludedBundleIdentifiers.contains(bundleIdentifier) {
            return PrivacyDecision(mayCapture: false, reason: "此应用在隐私排除列表中。")
        }
        return PrivacyDecision(mayCapture: true)
    }

    public func redact(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            (#"(?i)\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}\b"#, "[REDACTED]"),
            (#"(?i)(?:api[ _-]?key|x-api-key|authorization)\s*[:=]\s*[\"']?(?:Bearer\s+)?[^\s\"',;]+"#, "[REDACTED]"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[已隐藏邮箱]"),
            (#"\b(?:\d[ -]?){13,19}\b"#, "[已隐藏卡号]"),
            (#"(?i)(password|密码|验证码|verification code)\s*[:：]?\s*\S+"#, "[已隐藏凭证]")
        ]
        for (pattern, replacement) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }

    public func cloudContext(from records: [CaptureRecord], settings: PrivacySettings) -> [CaptureRecord] {
        guard settings.cloudUseEnabled else { return [] }
        return records.map { record in
            var copy = record
            copy.ocrText = redact(record.ocrText)
            copy.imageRelativePath = nil
            // The OCR text above already includes the note; never retain an unredacted copy.
            copy.manualMatter = nil
            return copy
        }
    }
}

/// What is known about the front window at the moment of a record. Nothing here is persisted
/// unless the corresponding setting allows it.
public struct CaptureContext: Sendable, Equatable {
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var pageURL: String?
    public var secureInputActive: Bool
    public init(bundleIdentifier: String?, windowTitle: String? = nil, pageURL: String? = nil, secureInputActive: Bool = false) {
        self.bundleIdentifier = bundleIdentifier; self.windowTitle = windowTitle; self.pageURL = pageURL; self.secureInputActive = secureInputActive
    }
}

public extension PrivacyEngine {
    static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera"
    ]

    /// Full decision for one record. Order matters: pause and secure input are checked before anything else is read.
    func decision(for context: CaptureContext, settings: PrivacySettings) -> PrivacyDecision {
        let base = decision(for: context.bundleIdentifier, settings: settings)
        guard base.mayCapture else { return base }
        if settings.skipDuringSecureInput && context.secureInputActive {
            return PrivacyDecision(mayCapture: false, reason: "正在输入密码等安全内容，本次未记录。")
        }
        if let title = context.windowTitle?.lowercased(), !title.isEmpty,
           settings.excludedTitleKeywords.contains(where: { let k = $0.trimmingCharacters(in: .whitespaces).lowercased(); return !k.isEmpty && title.contains(k) }) {
            return PrivacyDecision(mayCapture: false, reason: "窗口标题命中排除关键词（如无痕窗口），本次未记录。")
        }
        let domains = settings.excludedDomains.compactMap(Self.normalizedDomain)
        if !domains.isEmpty, let bundle = context.bundleIdentifier, Self.browserBundleIdentifiers.contains(bundle) {
            // Fail closed: with excluded sites configured, an unreadable address could be one of them.
            guard let host = context.pageURL.flatMap({ URL(string: $0)?.host?.lowercased() }) else {
                return PrivacyDecision(mayCapture: false, reason: "已设置排除网站，但无法读取当前网页地址（需要辅助功能权限），本次未记录。")
            }
            if domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return PrivacyDecision(mayCapture: false, reason: "当前网站在排除列表中，本次未记录。")
            }
        }
        return PrivacyDecision(mayCapture: true)
    }

    /// Keeps scheme, host and path. Query strings, fragments, credentials and ports are dropped,
    /// since tokens and personal identifiers usually live there.
    static func sanitizedPageURL(_ raw: String?) -> String? {
        guard let raw, var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty else { return nil }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil; parts.port = nil
        parts.scheme = scheme; parts.host = host.lowercased()
        return parts.string.map { String($0.prefix(512)) }
    }

    static func normalizedDomain(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URL(string: text)?.host, text.contains("://") { text = host }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if text.hasPrefix(".") { text.removeFirst() }
        text = text.split(separator: "/").first.map(String.init) ?? ""
        return text.contains(".") ? text : nil
    }
}
