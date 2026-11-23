import Foundation
import PDFKit
import UniformTypeIdentifiers

public enum FileTextImportError: LocalizedError {
    case unsupported, unreadable, empty, tooLarge
    public var errorDescription: String? {
        let description = switch self {
        case .unsupported: "不支持这种文件。可以拖入图片、PDF、纯文本或 Markdown。"
        case .unreadable: "无法读取这个文件。"
        case .empty: "文件中没有可识别的文字。"
        case .tooLarge: "文件超过 25 MB，未导入。"
        }
        return RecallLocalization.text(description)
    }
}

/// Turns a file the user dropped into text. Only text is kept: the original file is never copied
/// into the archive, and images are recognized on this Mac.
public struct FileTextImporter: Sendable {
    public static let maximumBytes = 25 * 1024 * 1024
    public static let maximumPDFPages = 200
    private let recognizer: any TextRecognizing
    public init(recognizer: any TextRecognizing = VisionTextRecognizer()) { self.recognizer = recognizer }

    public enum Kind: Sendable, Equatable { case image, pdf, text }

    public static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || ["md", "markdown", "csv", "log"].contains(url.pathExtension.lowercased()) { return .text }
        return nil
    }

    public func text(from url: URL) async throws -> String {
        guard let kind = Self.kind(of: url) else { throw FileTextImportError.unsupported }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumBytes else { throw FileTextImportError.tooLarge }
        let text: String
        switch kind {
        case .text:
            guard let data = try? Data(contentsOf: url) else { throw FileTextImportError.unreadable }
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
        case .pdf:
            guard let document = PDFDocument(url: url) else { throw FileTextImportError.unreadable }
            text = (0..<min(document.pageCount, Self.maximumPDFPages)).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        case .image:
            guard let data = try? Data(contentsOf: url) else { throw FileTextImportError.unreadable }
            text = try await recognizer.recognizeText(in: data, context: .document)
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw FileTextImportError.empty }
        return String(clean.prefix(240_000))
    }
}
