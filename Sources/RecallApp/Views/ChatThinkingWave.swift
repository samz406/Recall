import SwiftUI

/// Only this tiny canvas ticks. It never publishes changes to the conversation or source list.
struct ChatThinkingWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion { wave(phase: 0) }
            else {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                    wave(phase: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }.frame(width: 25, height: 16).accessibilityHidden(true)
    }
    private func wave(phase: Double) -> some View {
        Canvas { context, size in
            for (index, height) in Self.heights(phase: phase).enumerated() {
                let rect = CGRect(x: CGFloat(index) * 5, y: (size.height - CGFloat(height)) / 2, width: 3, height: CGFloat(height))
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(RecallPalette.accent))
            }
        }
    }
    static func heights(phase: Double) -> [Double] {
        (0..<5).map { index in 4 + 9 * (sin(phase * 4 - Double(index) * 0.7) + 1) / 2 }
    }
}
