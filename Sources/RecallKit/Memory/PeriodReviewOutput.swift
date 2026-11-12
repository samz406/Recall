import Foundation

/// Fixed diagnostics only. Neither model text nor arbitrary JSON keys enter logs or errors.
public struct PeriodReviewOutputFailure: LocalizedError, Sendable {
    public enum Reason: String, Sendable { case syntax, missingField, wrongType, ambiguous }
    public let reason: Reason
    public let field: String
    public var errorDescription: String? { RecallLocalization.both(
        "回顾未完成：模型结果未按要求返回完整字段。原回顾已保留。",
        "The model did not return the required review fields. The previous review is preserved.") }
    public var detail: String { "review.output.\(reason.rawValue) · \(field)" }
    var repairInstruction: String {
        "JSON 校验位置：\(field)，错误：\(reason.rawValue)。仅返回一个完整对象；overview 是字符串，items 和 coverage 是数组；每项 section/title/detail 是字符串、evidence 是对象数组，每条 evidence 都有字符串 id 和逐字 quote；coverage 每条都有字符串 id/disposition/category。不得省略必需字段，不要返回多个版本。"
    }
}

extension PeriodReviewFromDaily {
    /// Recover transport/presentation differences, never missing facts, quotes or closing braces.
    /// A second plausible report is ambiguous rather than an invitation to silently select one.
    func decodeOutput(_ text: String) throws -> Draft {
        let bytes = Array(text.utf8)
        var ranges: [Range<Int>] = [], start: Int?, depth = 0, quoted = false, escaped = false
        for (i, byte) in bytes.enumerated() {
            if depth > 0 && quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if depth > 0 && byte == 34 { quoted = true; continue }
            if byte == 123 || byte == 91 {
                if depth == 0 { start = i }
                depth += 1
            } else if byte == 125 || byte == 93, depth > 0 {
                depth -= 1
                if depth == 0, let begin = start { ranges.append(begin..<(i + 1)) }
            }
        }
        // A JSON-encoded string is another common gateway wrapper. Decode it before scanning.
        if let value = try? JSONSerialization.jsonObject(with: Data(bytes), options: .fragmentsAllowed),
           let nested = value as? String, nested != text { return try decodeOutput(nested) }
        var objects: [[String: Any]] = []
        for range in ranges {
            let data = Data(bytes[range])
            let value = (try? JSONSerialization.jsonObject(with: data))
                ?? (try? JSONSerialization.jsonObject(with: removingTrailingCommas(data)))
            if let object = reviewObject(value) { objects.append(object) }
        }
        guard objects.count == 1 else {
            throw PeriodReviewOutputFailure(reason: objects.count > 1 ? .ambiguous : .syntax, field: "root")
        }
        var object = objects[0]
        if object["overview"] == nil || object["overview"] is NSNull { object["overview"] = "" }
        // A singleton object in an array field has exactly the same content and evidence.
        if let item = object["items"] as? [String: Any] { object["items"] = [item] }
        if var items = object["items"] as? [[String: Any]] {
            for i in items.indices {
                if let evidence = items[i]["evidence"] as? [String: Any] { items[i]["evidence"] = [evidence] }
            }
            object["items"] = items
        }
        if let receipt = object["coverage"] as? [String: Any], receipt["id"] != nil { object["coverage"] = [receipt] }
        do { return try JSONDecoder().decode(Draft.self, from: JSONSerialization.data(withJSONObject: object)) }
        catch let error as DecodingError {
            let path: [any CodingKey], reason: PeriodReviewOutputFailure.Reason
            switch error {
            case .keyNotFound(let key, let context): path = context.codingPath + [key]; reason = .missingField
            case .typeMismatch(_, let context), .valueNotFound(_, let context): path = context.codingPath; reason = .wrongType
            case .dataCorrupted(let context): path = context.codingPath; reason = .syntax
            @unknown default: path = []; reason = .syntax
            }
            let allowed = Set(["overview", "items", "section", "title", "detail", "evidence", "id", "quote", "coverage", "disposition", "category", "reason"])
            let field = path.map { key in key.intValue.map { "[\($0)]" } ?? (allowed.contains(key.stringValue) ? key.stringValue : "field") }.joined(separator: ".")
            throw PeriodReviewOutputFailure(reason: reason, field: field.isEmpty ? "root" : field)
        }
    }

    private func reviewObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if object["items"] != nil || object["overview"] != nil { return object }
            for key in ["result", "data"] {
                if let nested = object[key] as? [String: Any], nested["items"] != nil { return nested }
            }
        }
        if let list = value as? [[String: Any]], list.count == 1 { return reviewObject(list[0]) }
        return nil
    }

    private func removingTrailingCommas(_ data: Data) -> Data {
        let bytes = Array(data)
        var result: [UInt8] = [], quoted = false, escaped = false
        for (i, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 44 {
                let next = bytes[(i + 1)...].first { ![9, 10, 13, 32].contains($0) }
                if next == 93 || next == 125 { continue }
            }
            result.append(byte)
        }
        return Data(result)
    }
}
