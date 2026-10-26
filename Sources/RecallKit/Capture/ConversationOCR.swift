import CoreGraphics
import Foundation

public enum TextRecognitionContext: Sendable, Equatable {
    case document, conversation, messaging, leftAlignedMessaging, channelMessaging

    public var layoutStyle: ConversationLayoutStyle? {
        switch self {
        case .messaging: .alternating
        case .leftAlignedMessaging: .leftAligned
        case .channelMessaging: .channel
        default: nil
        }
    }

    public static func resolve(appName: String?, bundleIdentifier: String?, windowTitle: String?, scope: CaptureScope) -> Self {
        let app = [appName, bundleIdentifier].compactMap { $0 }.joined(separator: " ").lowercased()
        if scope == .selectedWindow, app.contains("slack") { return .channelMessaging }
        let native = ["微信", "wechat", "wework", "wecom", "imessage", "com.apple.ichat", "飞书", "lark", "feishu", "钉钉", "dingtalk", "telegram", "whatsapp", "signal", "beeper"]
        if scope == .selectedWindow, native.contains(where: app.contains) {
            return ["飞书", "lark", "feishu"].contains(where: app.contains) ? .leftAlignedMessaging : .messaging
        }
        let identity = app + " " + (windowTitle ?? "").lowercased()
        return (native + ["messages", "slack", "teams", "discord", "chatgpt", "claude", "gemini", "perplexity"])
            .contains(where: identity.contains) ? .conversation : .document
    }
}

public enum ConversationLayoutStyle: Sendable, Equatable { case alternating, leftAligned, channel }
public enum ConversationSpeaker: Sendable { case user, other, unknown }
public enum ConversationContentKind: Sendable { case message, reference, attachment }

public struct PositionedTextLine: Sendable, Equatable {
    public var text: String
    public var boundingBox: CGRect
    public var confidence: Double?
    public init(text: String, boundingBox: CGRect, confidence: Double? = nil) {
        self.text = text; self.boundingBox = boundingBox; self.confidence = confidence
    }
}

public struct ConversationBubble: Sendable {
    public var bounds: CGRect
    public var speaker: ConversationSpeaker
    public init(bounds: CGRect, speaker: ConversationSpeaker) { self.bounds = bounds; self.speaker = speaker }
}

/// All bounds use Vision's normalized bottom-left coordinates. Not persisted as user data.
public struct ConversationOCRLayout: Sendable {
    public var contentBounds: CGRect
    public var bubbles: [ConversationBubble]
    public var excludedBounds: [CGRect]
    public var isPersonalArchive: Bool
    public init(contentBounds: CGRect, bubbles: [ConversationBubble], excludedBounds: [CGRect] = [], isPersonalArchive: Bool = false) {
        self.contentBounds = contentBounds; self.bubbles = bubbles
        self.excludedBounds = excludedBounds; self.isPersonalArchive = isPersonalArchive
    }
}

public enum ConversationContentClassifier {
    public static func classify(_ text: String, inPersonalArchive: Bool = false) -> ConversationContentKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"(?i)^[^\n]{1,120}\.(?:zip|rar|7z|pdf|docx?|xlsx?|pptx?|png|jpe?g|mp4|mov)\s+\d+(?:\.\d+)?\s*(?:KB|MB|GB|字节)$"#, options: .regularExpression) != nil { return .attachment }
        if ["转发：", "转发:", "引用：", "引用:", "原文：", "原文:", "> "].contains(where: trimmed.hasPrefix) { return .reference }
        // A long item saved in a personal archive is material, not automatically a
        // personal belief. Short comments in the next bubble remain user expressions.
        let sentences = trimmed.filter { "。！？.!?".contains($0) }.count
        if inPersonalArchive, trimmed.count >= 360, sentences >= 4 { return .reference }
        return .message
    }
}

public enum ConversationOCRFormatter {
    public static func format(_ lines: [PositionedTextLine], context: TextRecognitionContext, layout: ConversationOCRLayout? = nil) -> String {
        if context == .channelMessaging { return ChannelOCRFormatter.format(lines, layout: layout) }
        if context == .document { return lines.map(\.text).map(trim).filter { !$0.isEmpty }.joined(separator: "\n") }
        guard let layout else {
            return lines.map { trim($0.text) }.filter { !$0.isEmpty }.map { marker(.unknown) + $0 }.joined(separator: "\n")
        }
        var groups: [Int: [PositionedTextLine]] = [:]
        var messages: [(y: CGFloat, x: CGFloat, text: String)] = []
        for line in lines where overlap(line.boundingBox, layout.contentBounds) >= 0.7 {
            let text = trim(line.text)
            guard !text.isEmpty, !layout.excludedBounds.contains(where: { overlap(line.boundingBox, $0) >= 0.5 }) else { continue }
            let matches = layout.bubbles.enumerated().map { ($0.offset, overlap(line.boundingBox, $0.element.bounds)) }
            if let best = matches.max(by: { $0.1 < $1.1 }), best.1 >= 0.55 {
                groups[best.0, default: []].append(line)
            } else {
                messages.append((line.boundingBox.maxY, line.boundingBox.minX, marker(.unknown) + text))
            }
        }
        for (index, values) in groups {
            let ordered = values.sorted(by: readingOrder)
            let body = ordered.map { trim($0.text) }.filter { text in
                !(ordered.count > 1 && text.range(of: #"^(?:解析中|加载中)[…⋯.。]*$"#, options: .regularExpression) != nil)
            }.joined(separator: " ")
            guard !body.isEmpty else { continue }
            let kind = ConversationContentClassifier.classify(body, inPersonalArchive: layout.isPersonalArchive)
            let tag: String = switch kind { case .message: ""; case .reference: "[内容·资料] "; case .attachment: "[内容·附件] " }
            let bubble = layout.bubbles[index]
            messages.append((bubble.bounds.maxY, bubble.bounds.minX, marker(bubble.speaker) + tag + body))
        }
        return messages.sorted { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }.map(\.text).joined(separator: "\n")
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func marker(_ speaker: ConversationSpeaker) -> String {
        switch speaker { case .user: "[聊天·自己] "; case .other: "[聊天·对方] "; case .unknown: "[聊天·角色未知] " }
    }
    private static func overlap(_ rect: CGRect, _ bounds: CGRect) -> CGFloat {
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        return intersection.width * intersection.height / (rect.width * rect.height)
    }
    private static func readingOrder(_ a: PositionedTextLine, _ b: PositionedTextLine) -> Bool {
        a.boundingBox.midY != b.boundingBox.midY ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
    }
}

/// Local window geometry plus message surfaces. No cloud image calls or fixed crop widths.
public enum ConversationImageLayout {
    public static func detect(in image: CGImage, style: ConversationLayoutStyle = .alternating, lines: [PositionedTextLine] = []) -> ConversationOCRLayout? {
        guard let raster = ChatRaster(image) else { return nil }
        let width = raster.width, height = raster.height
        func verticalScore(_ x: Int, _ range: Range<Int>) -> Double {
            Double(range.filter { raster.distance(x, $0, x + 1, $0) > 2 }.count) / Double(range.count)
        }
        let full = height / 25..<height * 24 / 25, lower = height * 8 / 10..<height * 94 / 100
        // A bubble can occupy most of the screen. A real column divider also
        // persists into the lower composer strip; a bubble edge normally doesn't.
        let splits = (width / 10..<width * 65 / 100).filter { verticalScore($0, full) > 0.55 && verticalScore($0, lower) > 0.9 }
        let left = splits.last.map { $0 + 2 } ?? 0
        let edges = (width * 7 / 10..<width - 2).filter { verticalScore($0, full) > 0.65 && verticalScore($0, lower) > 0.9 }
        let right = edges.last.map { $0 + 1 } ?? width
        let paneWidth = right - left
        guard paneWidth >= width / 3 else { return nil }
        func horizontalScore(_ y: Int, _ range: Range<Int>) -> Double {
            Double(range.filter { raster.distance($0, y, $0, y + 1) > 2 }.count) / Double(range.count)
        }
        func isSeparator(_ y: Int) -> Bool {
            // Check both gutters: a wide message/card bottom is not a composer divider.
            horizontalScore(y, left + 3..<right - 3) > 0.6
                && horizontalScore(y, left + max(3, paneWidth / 50)..<left + max(5, paneWidth * 5 / 100)) > 0.4
                && horizontalScore(y, right - max(5, paneWidth * 5 / 100)..<right - max(3, paneWidth / 50)) > 0.4
        }
        let header = (height * 3 / 100..<height / 4).last(where: isSeparator)
        let composer = (height * 45 / 100..<height * 98 / 100).first(where: isSeparator)
        var top = header.map { $0 + 2 } ?? 0, bottom = composer ?? height
        guard bottom - top > 50 else { return nil }
        let fontHeights = lines.map { Int($0.boundingBox.height * CGFloat(height)) }.filter { $0 >= 4 && $0 < height / 12 }.sorted()
        let font = fontHeights.isEmpty ? 8 : fontHeights[fontHeights.count / 2]
        if style == .channel {
            // Slack has unboxed, left-aligned messages, not alternating bubbles.
            // Only crop when the column, tabs/header and composer all agree.
            guard !splits.isEmpty, header != nil, composer != nil else { return nil }
            let pane = CGRect(x: Double(left) / Double(width), y: 1 - Double(bottom) / Double(height),
                width: Double(paneWidth) / Double(width), height: Double(bottom - top) / Double(height))
            return ConversationOCRLayout(contentBounds: pane, bubbles: [])
        }
        // Sample empty gutters, not the whole chat area (which may be one huge colored bubble).
        var samples = [[Int]](repeating: [], count: 3)
        let gutters = [left + max(2, paneWidth / 80)..<left + max(4, paneWidth / 40), right - max(4, paneWidth / 40)..<right - max(2, paneWidth / 80)]
        for y in stride(from: top, to: bottom, by: 3) {
            for gutter in gutters { for x in stride(from: gutter.lowerBound, to: gutter.upperBound, by: 2) {
                let color = raster.color(x, y)
                for c in 0..<3 { samples[c].append(color[c]) }
            } }
        }
        let background = samples.map { values -> Int in let s = values.sorted(); return s[s.count / 2] }
        let body = ChatPixelRect(x: left, y: top, w: paneWidth, h: bottom - top)
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in top..<bottom { for x in left..<right {
            if raster.backgroundDistance(x, y, background) >= 10 { mask[y * width + x] = 1 }
        } }
        // Remove thin text strokes and one-pixel bridges before component detection.
        let opened = raster.open(mask, in: body)
        var surfaces: [ChatPixelRect] = []
        for component in raster.components(opened, in: body) {
            let rect = component.bounds
            guard rect.w >= max(18, paneWidth * 3 / 100), rect.h >= max(12, font * 7 / 5), component.fill >= 0.68 else { continue }
            surfaces += raster.split(component, background: background)
        }
        // Drop nested text/link decorations; keep the containing message as one surface.
        surfaces = surfaces.filter { child in !surfaces.contains { parent in parent.area > child.area && parent.contains(child) } }
        let avatars = surfaces.filter { rect in
            abs(rect.w - rect.h) < max(4, rect.h / 5) && rect.w < paneWidth / 7
                && surfaces.contains { message in
                    let beside = (message.x > rect.maxX && message.x - rect.maxX < max(font * 3, paneWidth / 12))
                        || (rect.x > message.maxX && rect.x - message.maxX < max(font * 3, paneWidth / 12))
                    return beside && abs(message.y - rect.y) < max(font, rect.h / 3) && message.area > rect.area * 2
                }
        }
        surfaces.removeAll { avatars.contains($0) }
        // A centered footer input has different anchors from either side's messages.
        for rect in surfaces where rect.y > height * 86 / 100 && rect.x > left + paneWidth * 6 / 100
            && rect.maxX < left + paneWidth * 9 / 10 && rect.w > paneWidth * 55 / 100 {
            bottom = min(bottom, rect.y)
        }
        do {
            // Borderless or two-level headers: a short title beside the contact avatar, above messages.
            let titleLines = lines.filter { line in
                let r = raster.pixels(line.boundingBox)
                let besideHeaderAvatar = surfaces.contains { avatar in
                    abs(avatar.w - avatar.h) < max(4, avatar.h / 5) && avatar.h >= font * 2 && avatar.h <= font * 5
                        && avatar.x >= left && avatar.x < left + paneWidth * 12 / 100 && avatar.y < height * 8 / 100
                        && r.x >= avatar.maxX && r.x - avatar.maxX < paneWidth * 15 / 100
                        && r.y >= avatar.y && r.maxY <= avatar.maxY + font / 2
                }
                return besideHeaderAvatar && r.x >= left + paneWidth / 40 && r.x < left + paneWidth * 35 / 100
                    && r.y >= 0 && r.maxY < height * 12 / 100
                    && !surfaces.contains { $0.contains(r) && $0.h > r.h * 3 / 2 }
            }
            if let titleEnd = titleLines.map({ raster.pixels($0.boundingBox).maxY }).max() { top = max(top, titleEnd + font * 3 / 4) }
        }
        // Multi-button utility rows immediately above the composer (e.g. file tools).
        let toolLabels: Set<String> = ["收藏", "AI听记", "PDF转格式", "更多", "快速会议"]
        let utility = lines.filter { line in
            let r = raster.pixels(line.boundingBox)
            return r.x >= left && r.y > height * 65 / 100 && r.y < bottom
                && toolLabels.contains(line.text.trimmingCharacters(in: .whitespacesAndNewlines))
                && !surfaces.contains { $0.contains(r) && $0.w > paneWidth / 5 }
        }
        for line in utility {
            let r = raster.pixels(line.boundingBox)
            if utility.filter({ abs(raster.pixels($0.boundingBox).y - r.y) < font }).count >= 2 { bottom = min(bottom, r.y - font / 2) }
        }
        guard bottom - top > 50 else { return nil }
        var bubbles: [ConversationBubble] = []
        for rect in surfaces where rect.y >= top && rect.maxY <= bottom + 2 {
            let leading = Double(rect.x - left) / Double(paneWidth), trailing = Double(rect.maxX - left) / Double(paneWidth)
            let speaker: ConversationSpeaker
            switch style {
            case .alternating:
                if trailing >= 0.78 && trailing <= 0.975 && leading >= 0.1 { speaker = .user }
                else if leading >= 0.015 && leading <= 0.24 && trailing < 0.92 { speaker = .other }
                else { continue }
            case .channel: continue
            case .leftAligned:
                let onLeft = leading >= 0.04 && leading <= 0.24
                let onRight = leading >= 0.1 && trailing >= 0.78 && trailing <= 0.975
                guard onLeft || onRight else { continue }
                let tint = raster.medianColor(in: rect)
                if tint[2] - tint[0] >= 15 && tint[2] - tint[1] >= 4 { speaker = .user }
                else if onLeft && abs(tint[0] - tint[1]) < 7 && abs(tint[1] - tint[2]) < 7 { speaker = .other }
                else { speaker = .unknown }
            }
            bubbles.append(ConversationBubble(bounds: raster.normalized(rect.padded(2, within: body)), speaker: speaker))
        }
        guard !splits.isEmpty || (header != nil && composer != nil) else { return nil }
        guard !bubbles.isEmpty || (header != nil && composer != nil) else { return nil }
        let archive = lines.contains { line in
            let r = raster.pixels(line.boundingBox)
            return r.x >= left && r.maxY <= top + font && ["文件传输助手", "File Transfer"].contains(line.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ConversationOCRLayout(contentBounds: raster.normalized(ChatPixelRect(x: left, y: top, w: paneWidth, h: bottom - top)), bubbles: bubbles,
            excludedBounds: avatars.map { raster.normalized($0.padded(2, within: body)) }, isPersonalArchive: archive)
    }
}

private struct ChatPixelRect: Equatable {
    var x: Int, y: Int, w: Int, h: Int
    var maxX: Int { x + w }; var maxY: Int { y + h }; var area: Int { w * h }
    func contains(_ other: Self) -> Bool { x <= other.x && y <= other.y && maxX >= other.maxX && maxY >= other.maxY }
    func padded(_ amount: Int, within limit: Self) -> Self {
        let a = max(limit.x, x - amount), b = max(limit.y, y - amount)
        return Self(x: a, y: b, w: min(limit.maxX, maxX + amount) - a, h: min(limit.maxY, maxY + amount) - b)
    }
}

private struct ChatComponent {
    var bounds: ChatPixelRect
    var points: [Int]
    var fill: Double { Double(points.count) / Double(bounds.area) }
}

private struct ChatRaster {
    let width: Int, height: Int, rgba: [UInt8]
    init?(_ image: CGImage) {
        let scale = min(1, 1280 / Double(max(image.width, image.height)))
        width = max(1, Int(Double(image.width) * scale)); height = max(1, Int(Double(image.height) * scale))
        guard width >= 160 && height >= 160 else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard success else { return nil }; rgba = data
    }
    func color(_ x: Int, _ y: Int) -> [Int] { let i = (y * width + x) * 4; return [Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2])] }
    func distance(_ x: Int, _ y: Int, _ a: Int, _ b: Int) -> Int {
        let i = (y * width + x) * 4, j = (b * width + a) * 4
        return max(abs(Int(rgba[i]) - Int(rgba[j])), abs(Int(rgba[i + 1]) - Int(rgba[j + 1])), abs(Int(rgba[i + 2]) - Int(rgba[j + 2])))
    }
    func backgroundDistance(_ x: Int, _ y: Int, _ background: [Int]) -> Int {
        let i = (y * width + x) * 4
        return max(abs(Int(rgba[i]) - background[0]), abs(Int(rgba[i + 1]) - background[1]), abs(Int(rgba[i + 2]) - background[2]))
    }
    func pixels(_ rect: CGRect) -> ChatPixelRect {
        ChatPixelRect(x: Int(rect.minX * CGFloat(width)), y: Int((1 - rect.maxY) * CGFloat(height)),
            w: max(1, Int(rect.width * CGFloat(width))), h: max(1, Int(rect.height * CGFloat(height))))
    }
    func normalized(_ r: ChatPixelRect) -> CGRect {
        CGRect(x: Double(r.x) / Double(width), y: 1 - Double(r.maxY) / Double(height), width: Double(r.w) / Double(width), height: Double(r.h) / Double(height))
    }
    func medianColor(in rect: ChatPixelRect) -> [Int] {
        var channels = [[Int]](repeating: [], count: 3)
        for y in stride(from: rect.y, to: rect.maxY, by: 3) { for x in stride(from: rect.x, to: rect.maxX, by: 3) {
            let c = color(x, y); for i in 0..<3 { channels[i].append(c[i]) }
        } }
        return channels.map { let sorted = $0.sorted(); return sorted[sorted.count / 2] }
    }
    func open(_ mask: [UInt8], in bounds: ChatPixelRect) -> [UInt8] {
        var eroded = [UInt8](repeating: 0, count: mask.count), result = eroded
        guard bounds.w > 2 && bounds.h > 2 else { return result }
        for y in bounds.y + 1..<bounds.maxY - 1 { for x in bounds.x + 1..<bounds.maxX - 1 {
            let p = y * width + x
            if mask[p] == 1 && mask[p - 1] == 1 && mask[p + 1] == 1
                && mask[p - width - 1] == 1 && mask[p - width] == 1 && mask[p - width + 1] == 1
                && mask[p + width - 1] == 1 && mask[p + width] == 1 && mask[p + width + 1] == 1 { eroded[p] = 1 }
        } }
        for y in bounds.y + 1..<bounds.maxY - 1 { for x in bounds.x + 1..<bounds.maxX - 1 {
            let p = y * width + x
            if eroded[p] == 1 { for dy in -1...1 { for dx in -1...1 { result[p + dy * width + dx] = 1 } } }
        } }
        return result
    }
    func components(_ source: [UInt8], in bounds: ChatPixelRect) -> [ChatComponent] {
        var mask = source, result: [ChatComponent] = []
        for y in bounds.y..<bounds.maxY { for x in bounds.x..<bounds.maxX {
            let seed = y * width + x
            guard mask[seed] == 1 else { continue }
            var points = [seed], cursor = 0, minX = x, maxX = x, minY = y, maxY = y
            mask[seed] = 0
            while cursor < points.count {
                let p = points[cursor]; cursor += 1
                let px = p % width, py = p / width
                minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
                for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)] {
                    if nx >= bounds.x && nx < bounds.maxX && ny >= bounds.y && ny < bounds.maxY {
                        let next = ny * width + nx
                        if mask[next] == 1 { mask[next] = 0; points.append(next) }
                    }
                }
            }
            result.append(ChatComponent(bounds: ChatPixelRect(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1), points: points))
        } }
        return result
    }
    func split(_ component: ChatComponent, background: [Int]) -> [ChatPixelRect] {
        let r = component.bounds
        guard r.h >= 30 else { return [r] }
        // Compression/resize can bridge two adjacent bubbles. Look for an internal
        // seam close to the pane background, with colored surfaces above and below.
        let rowDistances = (r.y..<r.maxY).map { y -> Int in
            let values = stride(from: r.x + r.w / 8, to: r.maxX - max(1, r.w / 20), by: 3)
                .map { backgroundDistance($0, y, background) }.sorted()
            return values.isEmpty ? 0 : values[values.count / 2]
        }
        let cuts = (4..<r.h - 4).filter { i in
            rowDistances[i] < 30 && Double(rowDistances[i]) < Double(min(rowDistances[i - 3], rowDistances[i + 3])) * 0.45
        }
        guard !cuts.isEmpty else { return [r] }
        var boundaries = [r.y]
        for cut in cuts where r.y + cut - boundaries.last! >= 8 { boundaries.append(r.y + cut) }
        boundaries.append(r.maxY)
        var result: [ChatPixelRect] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let points = component.points.filter { (start..<end).contains($0 / width) }
            guard end - start >= 8, let minX = points.map({ $0 % width }).min(), let maxX = points.map({ $0 % width }).max() else { continue }
            result.append(ChatPixelRect(x: minX, y: start, w: maxX - minX + 1, h: end - start))
        }
        return result.isEmpty ? [r] : result
    }
}
