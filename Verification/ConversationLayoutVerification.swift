import AppKit
import CoreGraphics
import CoreText
import Foundation
import RecallKit

/// Synthetic shapes and invented content only; no user screenshots or personal text.
enum ConversationLayoutVerification {
    private struct Fixture {
        let width = 1000, height = 900, left = 280
        var pixels = [UInt8](repeating: 255, count: 1000 * 900 * 4)
        var lines: [PositionedTextLine] = []
        init(background: [UInt8], header: Int?, composer: Int?) {
            fill(0, 0, width, height, background)
            fill(0, 0, left, height, [120, 120, 120])
            fill(left - 1, 0, 1, height, [100, 100, 100])
            if let header { fill(left, header, width - left, 1, [100, 100, 100]) }
            if let composer { fill(left, composer, width - left, 1, [100, 100, 100]) }
        }
        mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: [UInt8]) {
            for row in y..<(y + h) { for column in x..<(x + w) {
                let i = (row * width + column) * 4
                for c in 0..<3 { pixels[i + c] = color[c] }
            } }
        }
        mutating func line(_ text: String, _ x: Int, _ y: Int, _ w: Int = 160, _ h: Int = 18) {
            lines.append(PositionedTextLine(text: text, boundingBox: CGRect(x: Double(x) / Double(width),
                y: 1 - Double(y + h) / Double(height), width: Double(w) / Double(width), height: Double(h) / Double(height))))
        }
        func image(drawText: Bool = false) -> CGImage {
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            guard drawText else { return image }
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            for line in lines {
                let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
                let string = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: NSColor.black])
                context.textPosition = CGPoint(x: line.boundingBox.minX * CGFloat(width), y: line.boundingBox.minY * CGFloat(height) + 2)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            }
            return context.makeImage()!
        }
        func layout(_ style: ConversationLayoutStyle = .alternating) throws -> ConversationOCRLayout {
            guard let result = ConversationImageLayout.detect(in: image(), style: style, lines: lines) else {
                throw VerificationError.failed("未识别合成聊天窗口")
            }
            return result
        }
        func text(_ style: ConversationLayoutStyle = .alternating) throws -> String {
            ConversationOCRFormatter.format(Array(lines.reversed()), context: style == .leftAligned ? .leftAlignedMessaging : .messaging, layout: try layout(style))
        }
    }

    static func runGeometry() throws {
        var archive = Fixture(background: [30, 30, 31], header: 60, composer: 760)
        archive.line("文件传输助手", 310, 22)
        archive.fill(405, 65, 535, 545, [40, 205, 136])
        archive.fill(390, 650, 550, 55, [40, 205, 136])
        archive.line(String(repeating: "这是一份关于工具使用的参考文章。", count: 30), 420, 90, 450)
        archive.line("我很关注无障碍产品，希望做一个相关工具", 410, 665, 500)
        archive.line("通讯录 工作台", 15, 300)
        archive.line("发送", 880, 820, 60)
        let archiveLayout = try archive.layout()
        let archiveText = try archive.text()
        try require(abs(archiveLayout.contentBounds.minX - 0.28) < 0.01, "超长气泡被误当成左侧会话分隔线")
        try require(archiveText.contains("[聊天·自己] [内容·资料]"), "个人存档中的长材料没有独立标记")
        try require(archiveText.contains("[聊天·自己] 我很关注无障碍产品"), "长气泡后的本人表达被截掉或被资料标记污染")
        try require(!archiveText.contains("通讯录") && !archiveText.contains("发送"), "侧栏或输入区进入正文")

        var leftAligned = Fixture(background: [252, 252, 252], header: 100, composer: 830)
        leftAligned.fill(350, 105, 610, 440, [235, 235, 237])
        leftAligned.fill(700, 555, 260, 50, [211, 230, 255])
        leftAligned.line("右对齐设置的本人消息", 715, 570, 230)
        leftAligned.fill(350, 620, 250, 65, [211, 230, 255])
        leftAligned.fill(300, 620, 40, 40, [10, 180, 140])
        leftAligned.fill(350, 700, 250, 30, [230, 190, 220]) // unsupported tint: unknown
        leftAligned.fill(350, 740, 610, 65, [235, 235, 237])
        leftAligned.line("助手给出的参考分析", 370, 140, 240)
        leftAligned.line("我会明天确认账单导出验收结果", 370, 640, 215)
        leftAligned.line("我的头像", 302, 628, 32)
        leftAligned.line("主题颜色不明确的消息", 370, 704, 210)
        leftAligned.line("请指定通知发送位置", 370, 760, 250)
        leftAligned.line("发送给测试助手", 315, 855)
        let leftText = try leftAligned.text(.leftAligned)
        try require(leftText.contains("[聊天·对方] 助手给出的参考分析"), "左对齐长卡片误判为本人或裁剪边界")
        try require(leftText.contains("[聊天·自己] 右对齐设置的本人消息"), "飞书右对齐设置的蓝色本人消息被丢弃")
        try require(leftText.contains("[聊天·自己] 我会明天确认账单导出验收结果"), "飞书左侧蓝色本人消息没有保留归属")
        try require(leftText.contains("[聊天·对方] 请指定通知发送位置"), "长卡片后的机器人消息丢失")
        try require(leftText.contains("[聊天·角色未知] 主题颜色不明确的消息"), "未知主题不应猜测发送者")
        try require(!leftText.contains("我的头像") && !leftText.contains("发送给"), "头像或输入提示进入正文")

        var borderless = Fixture(background: [40, 40, 40], header: nil, composer: nil)
        borderless.fill(300, 8, 40, 40, [180, 100, 60])
        borderless.line("测试联系人", 360, 20, 100)
        borderless.fill(390, 70, 550, 70, [110, 110, 180])
        borderless.fill(390, 140, 550, 4, [40, 40, 54]) // compressed seam still connected in binary mask
        borderless.fill(390, 144, 550, 60, [115, 110, 180])
        borderless.fill(300, 260, 210, 50, [62, 62, 62])
        borderless.fill(340, 840, 520, 45, [62, 62, 62])
        borderless.line("第一条消息", 410, 90)
        borderless.line("第二条消息", 410, 165)
        borderless.line("对方回复确认", 315, 275)
        borderless.line("消息", 365, 855, 60)
        let borderlessText = try borderless.text()
        try require(borderlessText.contains("[聊天·自己] 第一条消息\n[聊天·自己] 第二条消息"), "压缩产生的相邻气泡桥接未拆开")
        try require(borderlessText.contains("[聊天·对方] 对方回复确认"), "靠近左侧正文边缘的接收消息丢失")
        try require(!borderlessText.contains("测试联系人") && !borderlessText.contains("角色未知] 消息"), "无分隔线的标题或居中输入框进入正文")

        var tools = Fixture(background: [241, 242, 243], header: 50, composer: 760)
        tools.fill(300, 60, 50, 50, [40, 140, 230])
        tools.line("测试会话", 370, 70)
        tools.fill(710, 130, 230, 300, [50, 160, 130]) // image attachment; no invented image description
        tools.fill(730, 640, 210, 50, [190, 225, 255])
        tools.line("我确认了", 750, 655)
        tools.line("收藏", 300, 710, 70)
        tools.line("AI听记", 400, 710, 90)
        tools.line("PDF转格式", 530, 710, 140)
        let toolsText = try tools.text()
        try require(toolsText.contains("[聊天·自己] 我确认了"), "钉钉本人短消息丢失")
        try require(!toolsText.contains("测试会话") && !toolsText.contains("收藏") && !toolsText.contains("PDF转格式"), "第二层标题或输入区上方工具栏进入正文")

        var transparent = Fixture(background: [40, 40, 40], header: nil, composer: 760)
        transparent.line("我准备核对导出结果", 360, 25, 230)
        transparent.fill(390, 200, 550, 60, [110, 110, 180])
        transparent.line("可以开始核对", 410, 215)
        let transparentText = try transparent.text()
        try require(transparentText.contains("[聊天·角色未知] 我准备核对导出结果"), "无头像/气泡的顶部正文被误当标题裁剪")

        try require(TextRecognitionContext.resolve(appName: "测试飞书", bundleIdentifier: "example.lark", windowTitle: nil, scope: .selectedWindow) == .leftAlignedMessaging, "飞书未使用独立布局规则")
        try require(TextRecognitionContext.resolve(appName: "Signal", bundleIdentifier: nil, windowTitle: nil, scope: .selectedWindow) == .messaging, "未覆盖 Signal 原生窗口")
        try require(TextRecognitionContext.resolve(appName: "Beeper", bundleIdentifier: nil, windowTitle: nil, scope: .selectedWindow) == .messaging, "未覆盖 Beeper 原生窗口")
        try require(TextRecognitionContext.resolve(appName: "飞书", bundleIdentifier: nil, windowTitle: nil, scope: .activeDisplay).layoutStyle == nil, "整屏采集误启用原生窗口裁剪")
        let fallback = ConversationOCRFormatter.format([PositionedTextLine(text: "无法确认说话人", boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.1))], context: .conversation)
        try require(fallback.hasPrefix("[聊天·角色未知]"), "未验证的会话布局仍按整图左右猜角色")
    }

    static func runVision() async throws {
        var fixture = Fixture(background: [252, 252, 252], header: 100, composer: 830)
        fixture.fill(350, 120, 610, 370, [235, 235, 237])
        fixture.fill(350, 620, 560, 65, [211, 230, 255])
        fixture.fill(350, 740, 610, 65, [235, 235, 237])
        fixture.line("Assistant", 310, 30)
        fixture.line("CONTACTS", 20, 300)
        fixture.line("This is reference information.", 370, 150, 550)
        fixture.line("I will review the billing report tomorrow.", 370, 640, 520)
        fixture.line("Please choose the delivery channel.", 370, 760, 550)
        fixture.line("Send to assistant", 310, 855)
        guard let png = NSBitmapImageRep(cgImage: fixture.image(drawText: true)).representation(using: .png, properties: [:]) else {
            throw VerificationError.failed("无法生成合成 Vision 验证图片")
        }
        let text = try await VisionTextRecognizer().recognizeText(in: png, context: .leftAlignedMessaging)
        try require(text.contains("[聊天·自己] I will review the billing report tomorrow"), "真实 Vision 输出的左对齐本人消息归属失败")
        try require(text.contains("[聊天·对方] Please choose the delivery channel"), "真实 Vision 漏掉长卡片后的接收消息")
        try require(!text.contains("CONTACTS") && !text.contains("Send to assistant"), "真实 Vision 的侧栏或输入框未过滤")
    }

    static func runChannel() async throws {
        for dark in [false, true] {
            let background: [UInt8] = dark ? [26, 29, 32] : [252, 252, 252]
            var fixture = Fixture(background: background, header: 100, composer: 800)
            fixture.line("#test-project", 310, 30, 240)
            fixture.line("CONTACTS", 20, 250)
            fixture.line("草稿和已发送", 20, 350)
            fixture.line("October 12", 600, 140, 140)
            fixture.line("Casey has joined #test-project. 10:10 AM", 340, 190, 560)
            // Simulate Vision observations splitting name and time at the same baseline.
            fixture.line("Casey", 350, 300, 80)
            fixture.line("10:15 AM", 440, 300, 100)
            fixture.line("AB", 300, 320, 26, 16) // avatar initials, not message text
            fixture.line("Please review the invoice export.", 350, 330, 510)
            fixture.line("1 reply", 400, 365, 110)
            fixture.line("Morgan 10:19 AM", 350, 450, 250)
            fixture.line("I have completed the paging checks.", 350, 480, 560)
            fixture.line("Send message #test-project", 310, 840, 500)
            let layout = try fixture.layout(.channel)
            let text = ConversationOCRFormatter.format(Array(fixture.lines.reversed()), context: .channelMessaging, layout: layout)
            try require(text.contains("[频道·#test-project]") && text.contains("[时间·October 12 10:15 AM]"), "频道或聊天日期时间没有保留")
            try require(text.contains("[发言者·Casey]") && text.contains("[发言者·Morgan]"), "Slack 姓名与时间未正确组合")
            try require(text.contains("Please review the invoice export.") && text.contains("I have completed the paging checks."), "Slack 可见消息正文丢失")
            try require(text.contains("[内容·系统]") && !text.contains("[发言者·Casey has joined"), "系统事件误当发言人")
            try require(!text.contains("AB") && !text.contains("CONTACTS") && !text.contains("草稿") && !text.contains("Send message") && !text.contains("1 reply"), "Slack 侧栏、输入区或线程按钮混入正文")
            try require(!text.contains("[聊天·自己]") && !text.contains("[聊天·对方]"), "仅凭频道姓名不能判断当前用户身份")
            let capture = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "Slack", contentHash: "synthetic-channel", ocrText: text, textOrigin: .screenOCR)
            try require(ReminderExtractor().candidates(from: [capture], existing: []).isEmpty, "身份未知的频道发言生成用户待办")
            let preview = CapturePresentation(capture: capture)
            try require(!preview.summary.contains("发言者·") && !preview.summary.contains("joined") && !preview.summary.contains("频道·"), "频道元信息或系统事件污染摘要预览")
            if !dark {
                guard let png = NSBitmapImageRep(cgImage: fixture.image(drawText: true)).representation(using: .png, properties: [:]) else {
                    throw VerificationError.failed("无法生成 Slack 合成窗口")
                }
                let actual = try await VisionTextRecognizer().recognizeText(in: png, context: .channelMessaging)
                try require(actual.contains("[发言者·Casey]") && actual.contains("[发言者·Morgan]"), "真实 Vision 没有识别 Slack 作者分组")
                try require(actual.contains("invoice export") && actual.contains("paging checks"), "真实 Vision 丢失频道正文")
                try require(!actual.contains("AB") && !actual.contains("CONTACTS") && !actual.contains("Send message") && !actual.contains("1 reply"), "真实 Vision 的 Slack 界面过滤失败")
            }
        }
        try require(TextRecognitionContext.resolve(appName: "Slack", bundleIdentifier: "example.slack", windowTitle: nil, scope: .selectedWindow) == .channelMessaging, "Slack 未启用频道解析")
        try require(TextRecognitionContext.resolve(appName: "Slack", bundleIdentifier: nil, windowTitle: nil, scope: .activeDisplay).layoutStyle == nil, "Slack 整屏误裁剪")
        var partial = Fixture(background: [252, 252, 252], header: 100, composer: 800)
        partial.line("上半条消息没有显示作者", 350, 115, 350)
        partial.line("测试成员 晚上 8:19", 350, 230, 300)
        partial.line("我准备明天提交导出验收报告。", 350, 260, 500)
        partial.line("天明 1 条回复", 400, 300, 200)
        let text = ConversationOCRFormatter.format(partial.lines, context: .channelMessaging, layout: try partial.layout(.channel))
        try require(text.contains("[内容·片段] 上半条消息没有显示作者"), "顶部截断内容没有保留为未知片段")
        try require(text.contains("[发言者·测试成员]") && text.contains("晚上 8:19"), "中文姓名和晚上时间未识别")
        try require(!text.contains("1 条回复"), "带头像文字的线程按钮混入正文")
        let fallback = ConversationOCRFormatter.format(partial.lines, context: .channelMessaging)
        try require(fallback.contains("上半条消息") && !fallback.contains("[聊天·自己]"), "Slack 无可靠边界时没有保守回退")
    }

    static func runEvidence() throws {
        let text = "[聊天·自己] [内容·资料] 转发：我喜欢每天安排复盘。明天记得提交验收报告。\n[聊天·自己] [内容·附件] report.zip 2.5 MB\n[聊天·自己] 我不喜欢没有结论的会议。\n[聊天·自己] 我会明天回复账单导出验收结果。"
        let capture = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "测试聊天工具", contentHash: "synthetic-reference", ocrText: text, textOrigin: .screenOCR)
        let reminders = ReminderExtractor().candidates(from: [capture], existing: [])
        try require(!reminders.contains(where: { $0.title.contains("提交验收报告") || $0.title.contains("report.zip") }), "资料或附件仍生成用户待办")
        try require(reminders.contains(where: { $0.title.contains("账单导出") }), "资料标记影响了下一条本人待办")
        let memories = PersonalIntelligenceEngine().consolidate(day: capture.createdAt, records: [capture]).memories.map(\.content).joined(separator: "\n")
        try require(!memories.contains("喜欢每天安排复盘") && memories.contains("不喜欢没有结论的会议"), "引用资料冒认为个人偏好，或真实表达被丢弃")
        try require(!CapturePresentation(capture: capture).summary.contains("内容·"), "内部资料标记泄漏到时间线预览")
        if case .attachment = ConversationContentClassifier.classify("bundle.zip 2.5 MB") {} else { throw VerificationError.failed("文件卡片未识别") }
        if case .message = ConversationContentClassifier.classify("我会明天提交 review.pdf") {} else { throw VerificationError.failed("提到文件名的个人表达被误认附件") }
        if case .reference = ConversationContentClassifier.classify("引用：完成检查后应当提交报告") {} else { throw VerificationError.failed("显式引用未识别") }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw VerificationError.failed(message) }
    }
}
