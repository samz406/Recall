import CoreGraphics
import Foundation

public enum TextRecognitionContext: Sendable, Equatable {
    case document
    case conversation
    /// Native, window-only capture of a messenger with left/right message bubbles.
    case messaging
}

public struct PositionedTextLine: Sendable, Equatable {
    public var text: String
    public var boundingBox: CGRect
    public init(text: String, boundingBox: CGRect) { self.text = text; self.boundingBox = boundingBox }
}

public enum ConversationSpeaker: Sendable { case user, other, unknown }

public struct ConversationBubble: Sendable {
    public var bounds: CGRect
    public var speaker: ConversationSpeaker
    public init(bounds: CGRect, speaker: ConversationSpeaker) { self.bounds = bounds; self.speaker = speaker }
}

/// Bounds use Vision's normalized, bottom-left coordinate system.
public struct ConversationOCRLayout: Sendable {
    public var contentBounds: CGRect
    public var bubbles: [ConversationBubble]
    public init(contentBounds: CGRect, bubbles: [ConversationBubble]) {
        self.contentBounds = contentBounds; self.bubbles = bubbles
    }
}

public enum ConversationOCRFormatter {
    public static func format(_ lines: [PositionedTextLine], context: TextRecognitionContext, layout: ConversationOCRLayout? = nil) -> String {
        if context == .document { return lines.map(\.text).map(trim).filter { !$0.isEmpty }.joined(separator: "\n") }
        guard let layout else {
            return lines.compactMap { line in
                let text = trim(line.text)
                guard !text.isEmpty else { return nil }
                // Without a verified native-chat pane, do not assign roles by the whole
                // screenshot's center. Narrow edge-aligned lines are the only fallback.
                var speaker = ConversationSpeaker.unknown
                if context == .conversation {
                    if line.boundingBox.minX <= 0.2 && line.boundingBox.maxX < 0.75 { speaker = .other }
                    else if line.boundingBox.maxX >= 0.8 && line.boundingBox.minX > 0.25 { speaker = .user }
                }
                return marker(speaker) + text
            }.joined(separator: "\n")
        }
        var groups: [Int: [PositionedTextLine]] = [:]
        var metadata: [PositionedTextLine] = []
        var unattributed: [PositionedTextLine] = []
        for line in lines where overlap(line.boundingBox, with: layout.contentBounds) >= 0.7 {
            guard !trim(line.text).isEmpty else { continue }
            let matches = layout.bubbles.enumerated().map { ($0.offset, overlap(line.boundingBox, with: $0.element.bounds)) }
            if let best = matches.max(by: { $0.1 < $1.1 }), best.1 >= 0.55 {
                groups[best.0, default: []].append(line)
            } else if isTimestamp(trim(line.text)) {
                metadata.append(line)
            } else {
                // Preserve unbubbled messages/sender names instead of losing evidence
                // when a transparent or unusual bubble cannot be located.
                unattributed.append(line)
            }
        }
        var messages: [(y: CGFloat, x: CGFloat, text: String)] = []
        for (index, values) in groups {
            let ordered = values.sorted(by: readingOrder)
            let body = ordered.map { trim($0.text) }.filter { text in
                !(ordered.count > 1 && text.range(of: #"^(?:解析中|加载中)[…⋯.。]*$"#, options: .regularExpression) != nil)
            }.joined(separator: " ")
            guard !body.isEmpty else { continue }
            let bubble = layout.bubbles[index]
            messages.append((bubble.bounds.maxY, bubble.bounds.minX, marker(bubble.speaker) + body))
        }
        messages += unattributed.map { ($0.boundingBox.maxY, $0.boundingBox.minX, marker(.unknown) + trim($0.text)) }
        messages += metadata.map { ($0.boundingBox.maxY, $0.boundingBox.minX, marker(.unknown) + trim($0.text)) }
        return messages.sorted { abs($0.y - $1.y) > 0.008 ? $0.y > $1.y : $0.x < $1.x }.map(\.text).joined(separator: "\n")
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func marker(_ speaker: ConversationSpeaker) -> String {
        switch speaker {
        case .user: "[聊天·自己] "
        case .other: "[聊天·对方] "
        case .unknown: "[聊天·角色未知] "
        }
    }
    private static func overlap(_ rect: CGRect, with bounds: CGRect) -> CGFloat {
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        return intersection.width * intersection.height / (rect.width * rect.height)
    }
    private static func readingOrder(_ a: PositionedTextLine, _ b: PositionedTextLine) -> Bool {
        abs(a.boundingBox.midY - b.boundingBox.midY) > min(a.boundingBox.height, b.boundingBox.height) * 0.5
            ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
    }
    private static func isTimestamp(_ text: String) -> Bool {
        text.range(of: #"^(?:(?:今天|昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天])\s*)?\d{1,2}[:：]\d{2}(?:\s*(?:AM|PM))?$|^(?:今天|昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天])$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Local visual layout detection. No OCR word blacklist or fixed sidebar percentage:
/// find persistent pane dividers, then connected bubble backgrounds inside that pane.
public enum ConversationImageLayout {
    public static func detect(in image: CGImage) -> ConversationOCRLayout? {
        let scale = min(1, 960 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard width >= 160, height >= 160 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        func intensity(_ x: Int, _ y: Int) -> Int {
            let i = (y * width + x) * 4
            return (Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2])) / 3
        }
        func verticalScore(_ x: Int, threshold: Int) -> Double {
            let start = height / 25, end = height * 24 / 25
            let count = (start..<end).filter { abs(intensity(x, $0) - intensity(x + 1, $0)) > threshold }.count
            return Double(count) / Double(end - start)
        }
        // The last persistent split in the left portion separates the conversation list.
        let splits = (width * 12 / 100..<width * 65 / 100).filter { verticalScore($0, threshold: 5) > 0.55 }
        let left = splits.last.map { $0 + 2 } ?? 0
        let rightEdges = (width * 7 / 10..<width - 2).filter { verticalScore($0, threshold: 3) > 0.65 }
        let right = rightEdges.last.map { $0 + 1 } ?? width
        guard right - left >= width / 3 else { return nil }
        let paneWidth = right - left
        func horizontalScore(_ y: Int) -> Double {
            let start = left + 3, end = right - 3
            let count = (start..<end).filter { abs(intensity($0, y) - intensity($0, y + 1)) > 5 }.count
            return Double(count) / Double(end - start)
        }
        let header = (height * 3 / 100..<height / 4).last { horizontalScore($0) > 0.88 }
        let composer = (height * 45 / 100..<height * 9 / 10).first { horizontalScore($0) > 0.88 }
        let top = header.map { $0 + 2 } ?? 0
        let bottom = composer ?? height
        guard bottom - top > 50 else { return nil }
        // Median background tolerates dark/light themes and differently colored self bubbles.
        var channels = [[Int]](repeating: [], count: 3)
        for y in stride(from: top, to: bottom, by: 4) {
            for x in stride(from: left, to: right, by: 4) {
                let i = (y * width + x) * 4
                for c in 0..<3 { channels[c].append(Int(rgba[i + c])) }
            }
        }
        let background = channels.map { channel -> Int in let sorted = channel.sorted(); return sorted[sorted.count / 2] }
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in top..<bottom {
            for x in left..<right {
                let p = y * width + x, i = p * 4
                if (0..<3).contains(where: { abs(Int(rgba[i + $0]) - background[$0]) >= 12 }) { mask[p] = 1 }
            }
        }
        func normalizedRect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
            CGRect(x: Double(x) / Double(width), y: 1 - Double(y + h) / Double(height), width: Double(w) / Double(width), height: Double(h) / Double(height))
        }
        var bubbles: [ConversationBubble] = []
        var queue: [Int] = []
        for y in top..<bottom {
            for x in left..<right {
                let seed = y * width + x
                guard mask[seed] == 1 else { continue }
                queue.removeAll(keepingCapacity: true)
                queue.append(seed); mask[seed] = 0
                var cursor = 0, minX = x, maxX = x, minY = y, maxY = y
                while cursor < queue.count {
                    let p = queue[cursor]; cursor += 1
                    let px = p % width, py = p / width
                    minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
                    for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)] {
                        if nx >= left && nx < right && ny >= top && ny < bottom {
                            let next = ny * width + nx
                            if mask[next] == 1 { mask[next] = 0; queue.append(next) }
                        }
                    }
                }
                let w = maxX - minX + 1, h = maxY - minY + 1
                guard w >= max(16, paneWidth * 3 / 100), h >= 10,
                      Double(queue.count) / Double(w * h) >= 0.42 else { continue }
                let leading = Double(minX - left) / Double(paneWidth)
                let trailing = Double(maxX + 1 - left) / Double(paneWidth)
                let speaker: ConversationSpeaker
                if trailing >= 0.78 && trailing <= 0.96 && leading >= 0.12 { speaker = .user }
                else if leading >= 0.04 && leading <= 0.24 && trailing < 0.86 { speaker = .other }
                else { continue }
                bubbles.append(ConversationBubble(bounds: normalizedRect(x: max(left, minX - 2), y: max(top, minY - 2), w: min(right, maxX + 3) - max(left, minX - 2), h: min(bottom, maxY + 3) - max(top, minY - 2)), speaker: speaker))
            }
        }
        // A verified divider or complete header/composer pair is required. A busy screenshot
        // with a few colored objects must not be mistaken for a native chat pane.
        guard !splits.isEmpty || (header != nil && composer != nil) else { return nil }
        guard !bubbles.isEmpty || (header != nil && composer != nil) else { return nil }
        return ConversationOCRLayout(contentBounds: normalizedRect(x: left, y: top, w: paneWidth, h: bottom - top), bubbles: bubbles)
    }
}
