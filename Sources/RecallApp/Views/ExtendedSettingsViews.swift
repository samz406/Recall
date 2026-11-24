import AppKit
import SwiftUI
import RecallKit

private func t(_ chinese: String, _ english: String) -> String { RecallLocalization.both(chinese, english) }

/// Window, site and secure-input exclusions. Each rule only prevents recording; none of them reads more.
struct SensitiveContentSettings: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var keywords = ""
    @State private var domains = ""
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("敏感内容", "Sensitive content")).font(.headline).foregroundStyle(RecallPalette.accent)
            RecallSwitchRow(title: t("输入密码时不记录", "Skip while typing a password"),
                            detail: t("macOS 报告正在安全输入（任意应用的密码框获得焦点）时，本次记录直接跳过。", "When macOS reports secure input (a focused password field in any app), the record is skipped."),
                            isOn: binding(\.skipDuringSecureInput))
            VStack(alignment: .leading, spacing: 6) {
                Text(t("排除窗口标题关键词", "Excluded window title keywords")).font(.subheadline)
                Text(t("标题包含任一关键词时不记录，默认覆盖常见浏览器的无痕窗口。用逗号分隔。", "Windows whose title contains any keyword are not recorded. Defaults cover common private browsing windows. Separate with commas."))
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                HStack {
                    TextField("Private Browsing, Incognito", text: $keywords).textFieldStyle(.roundedBorder)
                    Button(t("保存", "Save")) { save() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(t("排除网站", "Excluded sites")).font(.subheadline)
                Text(t("这些域名及其子域名的网页不记录。需要辅助功能权限读取网址；读不到网址时，浏览器内的记录会被保守跳过。", "Pages on these domains and subdomains are not recorded. Reading the address needs Accessibility; if it cannot be read, browser records are skipped to be safe."))
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                HStack {
                    TextField("bank.example.com, mail.example.com", text: $domains).textFieldStyle(.roundedBorder)
                    Button(t("保存", "Save")) { save() }
                }
            }
            RecallSwitchRow(title: t("保存网页地址", "Keep page addresses"),
                            detail: t("默认关闭。开启后浏览器记录会保存网址（去掉 ? 和 # 之后的参数），可从记录详情点回原网页。需要辅助功能权限。", "Off by default. When on, browser records keep the address without query or fragment, so details can link back. Needs Accessibility."),
                            isOn: binding(\.recordPageAddress))
            HStack(spacing: 8) {
                Image(systemName: AXIsProcessTrusted() ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(AXIsProcessTrusted() ? RecallPalette.accent : RecallPalette.warning)
                Text(AXIsProcessTrusted() ? t("辅助功能已允许", "Accessibility allowed") : t("辅助功能未允许：排除网站、网页地址和保存选中文字不可用", "Accessibility not allowed: site exclusion, page addresses and saving selections are unavailable"))
                    .font(.caption)
                Spacer()
                if !AXIsProcessTrusted() {
                    Button(t("打开系统设置", "Open System Settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }.font(.caption)
                }
            }
        }.recallSurface()
        .onAppear {
            guard !loaded else { return }
            keywords = model.state.privacy.excludedTitleKeywords.joined(separator: ", ")
            domains = model.state.privacy.excludedDomains.joined(separator: ", ")
            loaded = true
        }
    }
    private func split(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private func save() {
        var privacy = model.state.privacy
        privacy.excludedTitleKeywords = split(keywords)
        let parsed = split(domains)
        privacy.excludedDomains = parsed.compactMap(PrivacyEngine.normalizedDomain)
        if parsed.count != privacy.excludedDomains.count {
            model.noticeMessage = t("有些网站格式无法识别，已忽略。请填写如 example.com。", "Some sites were not recognized and were ignored. Use a form like example.com.")
        }
        domains = privacy.excludedDomains.joined(separator: ", ")
        model.updatePrivacy(privacy)
    }
    private func binding(_ keyPath: WritableKeyPath<PrivacySettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.state.privacy[keyPath: keyPath] }, set: { var p = model.state.privacy; p[keyPath: keyPath] = $0; model.updatePrivacy(p) })
    }
}

/// Reports whether FileVault protects the disk the archive lives on. Recall never changes the setting.
struct DiskEncryptionCard: View {
    @State private var status: FileVaultStatus = .checking
    enum FileVaultStatus { case checking, on, off, unknown }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .on ? "lock.fill" : status == .off ? "lock.open" : "lock")
                .foregroundStyle(status == .off ? RecallPalette.warning : RecallPalette.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status == .off {
                Button(t("打开 FileVault 设置", "Open FileVault settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")!)
                }
            }
        }.recallSurface()
        .task { status = await Self.check() }
    }
    private var title: String {
        switch status {
        case .checking: t("正在检查磁盘加密…", "Checking disk encryption…")
        case .on: t("FileVault 已开启", "FileVault is on")
        case .off: t("FileVault 未开启", "FileVault is off")
        case .unknown: t("无法确认磁盘加密状态", "Disk encryption status unknown")
        }
    }
    private var detail: String {
        switch status {
        case .off: t("截图、识别文字和索引以普通文件保存在本机。Mac 丢失或被他人取下硬盘时可被读取，建议开启 FileVault。", "Screenshots, text and the index are ordinary files on this Mac. If the Mac or its disk is taken, they can be read. Turning on FileVault is recommended.")
        case .on: t("本机记录随系统磁盘一起加密。", "Saved records are encrypted with the system disk.")
        default: t("可在系统设置 → 隐私与安全性 → FileVault 中查看。", "Check System Settings → Privacy & Security → FileVault.")
        }
    }
    static func check() async -> FileVaultStatus {
        await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup"); process.arguments = ["status"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
            do { try process.run() } catch { return .unknown }
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if output.contains("FileVault is On") { return .on }
            if output.contains("FileVault is Off") { return .off }
            return .unknown
        }.value
    }
}

/// Daily budget for Recall's own notifications, plus the opt-in meeting brief.
struct AttentionSettingsCard: View {
    @EnvironmentObject private var model: RecallAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("通知与打扰", "Notifications")).font(.headline).foregroundStyle(RecallPalette.accent)
            Stepper(value: Binding(get: { model.state.attentionSettings.dailyProactiveLimit }, set: { model.setAttentionLimit($0) }), in: 0...10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("Recall 主动通知每天最多 \(model.state.attentionSettings.dailyProactiveLimit) 条", "At most \(model.state.attentionSettings.dailyProactiveLimit) proactive notifications a day")).font(.subheadline)
                    Text(t("包括回顾完成、会前简报。超出的放进“今天”页的收件箱。你安排的提醒不受此限制。", "Covers finished reviews and meeting briefs. Extra ones wait in the Today inbox. Reminders you scheduled are never limited."))
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                }
            }
            Divider()
            RecallSwitchRow(title: t("会前简报", "Meeting briefs"),
                            detail: t("默认关闭。开启后只读取日历中的会议标题、时间和参会人，会前汇总相关的本地记录。不修改日历，不发送内容。", "Off by default. Reads only meeting titles, times and attendees, and gathers related local records beforehand. The calendar is not changed and nothing is sent."),
                            isOn: Binding(get: { model.state.meetingBriefSettings.enabled }, set: { model.setMeetingBrief(enabled: $0, minutesBefore: model.state.meetingBriefSettings.minutesBefore) }))
            if model.state.meetingBriefSettings.enabled {
                Stepper(t("会前 \(model.state.meetingBriefSettings.minutesBefore) 分钟", "\(model.state.meetingBriefSettings.minutesBefore) minutes before"),
                        value: Binding(get: { model.state.meetingBriefSettings.minutesBefore }, set: { model.setMeetingBrief(enabled: true, minutesBefore: $0) }), in: 1...60)
            }
        }.recallSurface()
    }
}

/// Success rate and typical duration of reviews over the last 30 days. Counts only; no review text.
struct ReviewReliabilityCard: View {
    @EnvironmentObject private var model: RecallAppModel
    var body: some View {
        let since = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let daily = LocalBriefing.reviewStats(model.state.reviewAttemptMetrics, kind: .daily, since: since)
        let period = LocalBriefing.reviewStats(model.state.reviewAttemptMetrics, kind: .period, since: since)
        VStack(alignment: .leading, spacing: 10) {
            Text(t("回顾可靠性（近 30 天）", "Review reliability (30 days)")).font(.subheadline.weight(.semibold))
            row(t("每日回顾", "Daily"), daily)
            row(t("周期回顾", "Period"), period)
            Text(t("仅统计结果与耗时，不含回顾内容。", "Outcomes and durations only; no review content."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        }
    }
    private func row(_ title: String, _ stats: LocalBriefing.ReviewStats) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            if stats.attempts == 0 { Text(t("暂无", "No runs yet")).foregroundStyle(RecallPalette.secondary) }
            else {
                Text(t("成功率 ", "Success ") + (stats.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"))
                Text(t("· 共 \(stats.attempts) 次 · 失败 \(stats.failed)", "· \(stats.attempts) runs · \(stats.failed) failed")).foregroundStyle(RecallPalette.secondary)
                if let median = stats.medianSeconds { Text(t("· 中位耗时 \(median) 秒", "· median \(median)s")).foregroundStyle(RecallPalette.secondary) }
            }
            Spacer()
        }.font(.caption)
    }
}

/// Offers model servers found on this Mac. Probing reads only the model list from loopback addresses.
struct LocalModelPicker: View {
    let apply: (LocalModelServer, String) -> Void
    @State private var servers: [LocalModelServer] = []
    @State private var searching = false
    @State private var searched = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(t("本机模型（不出本机）", "On-device model (stays on this Mac)"), systemImage: "desktopcomputer").font(.subheadline.weight(.medium))
                Spacer()
                Button(searching ? t("查找中…", "Searching…") : t("查找 Ollama / LM Studio", "Find Ollama / LM Studio")) { Task { await search() } }.disabled(searching)
            }
            Text(t("连接本机的 Ollama 或 LM Studio，无需 API Key，文字不会离开这台 Mac。", "Connect Ollama or LM Studio on this Mac. No API key, and text never leaves the machine."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            if searched && servers.isEmpty {
                Text(t("没有找到运行中的本机模型服务。启动 Ollama（端口 11434）或 LM Studio 本地服务（端口 1234）后重试。", "No local model server found. Start Ollama (port 11434) or the LM Studio server (port 1234) and try again."))
                    .font(.caption).foregroundStyle(RecallPalette.warning)
            }
            ForEach(servers) { server in
                HStack {
                    Text(server.name).font(.callout.weight(.medium))
                    if server.models.isEmpty { Text(t("未加载模型", "No models loaded")).font(.caption).foregroundStyle(RecallPalette.secondary) }
                    Spacer()
                    Menu(t("使用此服务", "Use this server")) {
                        ForEach(server.models, id: \.self) { name in Button(name) { apply(server, name) } }
                    }.disabled(server.models.isEmpty).fixedSize()
                }
            }
        }
    }
    @MainActor private func search() async {
        searching = true; servers = await LocalModelDiscovery.discover(); searching = false; searched = true
    }
}
