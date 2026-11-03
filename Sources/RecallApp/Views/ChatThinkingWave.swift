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
    nonisolated static func heights(phase: Double) -> [Double] {
        var result: [Double] = []
        for index in 0..<5 {
            let offset: Double = Double(index) * 0.7
            let angle: Double = phase * 4.0 - offset
            let oscillation: Double = sin(angle)
            let height: Double = 4.0 + 9.0 * (oscillation + 1.0) / 2.0
            result.append(height)
        }
        return result
    }
}
