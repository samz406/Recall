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
            return copy
        }
    }
}
