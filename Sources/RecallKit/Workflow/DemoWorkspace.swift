import Foundation

/// Fully synthetic, in-memory, read-only sample. Never passed to FileMemoryStore or a model.
public enum DemoWorkspace {
    public static func records(now: Date = .now) -> [CaptureRecord] {
        let notes = [("Atlas release", "I finished the Atlas checkout test. I will send the test report to Morgan tomorrow.", "Slack"),
                     ("Atlas decision", "We chose the smaller release so the checkout fix can ship independently.", "Notion")]
        return notes.enumerated().map { index, row in
            CaptureRecord(eventTemplate: .manualMoment, createdAt: now.addingTimeInterval(Double(index - 1) * 3600),
                sourceAppName: row.2, sourceBundleIdentifier: "im.recall.sample", windowTitle: row.0, imageRelativePath: nil,
                contentHash: "sample-\(index)", isRedacted: true, ocrText: row.1, summary: row.0, tags: ["Sample"], textOrigin: .userInput)
        }
    }
    public static let review = "Atlas checkout testing is complete. The team chose a smaller release to ship the fix independently. You said you would send Morgan the test report tomorrow."
    public static let answer = "You finished checkout testing and chose a smaller release. Your next commitment was to send Morgan the test report."
}
