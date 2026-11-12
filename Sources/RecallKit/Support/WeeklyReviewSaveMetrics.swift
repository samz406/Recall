import Foundation

public struct WeeklyReviewSaveMetrics: Sendable {
    public let sourceCheckMilliseconds: Int
    public let encodeMilliseconds: Int
    public let writeMilliseconds: Int
    public let archiveBytes: Int
    public let totalMilliseconds: Int
    public var diagnosticMetadata: [String: String] {
        ["saveSourceCheckMs": String(sourceCheckMilliseconds), "saveEncodeMs": String(encodeMilliseconds),
         "saveWriteMs": String(writeMilliseconds), "archiveBytes": String(archiveBytes), "saveMs": String(totalMilliseconds)]
    }
}

struct ArchiveWriteMetrics {
    var encodeMilliseconds: Int
    var writeMilliseconds: Int
    var bytes: Int
}
