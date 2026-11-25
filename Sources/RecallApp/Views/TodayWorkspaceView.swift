import SwiftUI
import RecallKit

private func t(_ chinese: String, _ english: String) -> String { RecallLocalization.both(chinese, english) }

/// "Today": what to pick up, what is owed either way, and the reviews and reminders for the day.
/// Everything at the top is computed from saved records; nothing here records, sends or schedules.
struct TodayWorkspaceView: View {
    @EnvironmentObject private var model: RecallAppModel
    @AppStorage("recall.today.tab") private var tab = TodayTab.overview.rawValue
    enum TodayTab: String { case overview, reviews, reminders }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecallPageHeader(title: "今天", subtitle: "接着昨天停下的地方，处理今天要做的事") { EmptyView() }
            HStack(spacing: 24) {
                tabButton(t("概览", "Overview"), .overview)
                tabButton(t("回顾", "Reviews"), .reviews)
                tabButton(t("提醒", "Reminders"), .reminders, badge: model.state.reminders.filter { $0.status == .proposed }.count)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 14)
            Divider()
            switch TodayTab(rawValue: tab) ?? .overview {
            case .overview: ScrollView { TodayOverview().padding(24) }
            case .reviews: ReviewWorkspaceView(showsHeader: false)
            case .reminders: RemindersView()
            }
        }
        // Navigation can switch to Today before this view exists, so read the request on appear as well.
        .onAppear { followDestination(); if model.reviewsRequested { tab = TodayTab.reviews.rawValue } }
        .onChange(of: model.navigationRevision) { _, _ in followDestination() }
        .onReceive(NotificationCenter.default.publisher(for: .recallOpenReminders)) { _ in tab = TodayTab.reminders.rawValue }
        .onChange(of: model.reviewsRequested) { _, requested in if requested { tab = TodayTab.reviews.rawValue } }
    }
    private func followDestination() {
        switch model.destination {
        case .daily?, .review?: tab = TodayTab.reviews.rawValue
        case .reminder?: tab = TodayTab.reminders.rawValue
        default: break
        }
    }
    private func tabButton(_ title: String, _ value: TodayTab, badge: Int = 0) -> some View {
        Button { tab = value.rawValue } label: {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if badge > 0 { Text("\(badge)").font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1).background(RecallPalette.selected, in: Capsule()) }
            }
            .foregroundStyle(tab == value.rawValue ? RecallPalette.accent : RecallPalette.secondary)
            .padding(.vertical, 9).overlay(alignment: .bottom) { if tab == value.rawValue { Rectangle().fill(RecallPalette.accent).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(tab == value.rawValue ? .isSelected : [])
    }
}

private struct TodayOverview: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var showsAllCommitments = false
    @State private var hoveredItemID: String?
    var body: some View {
        let resume = LocalBriefing.resume(in: model.state, matters: model.matterFiles)
        let commitments = LocalBriefing.commitments(in: model.state)
        let commitmentCount = commitments.count
        VStack(alignment: .leading, spacing: 18) {
            if model.shouldAskAboutPersona { personaQuestion }
            if !model.state.attentionInbox.isEmpty { inbox }
            section(t("接着干", "Pick up where you stopped"), detail: resumeSummary(resume, commitmentCount: commitmentCount)) {
                if resume.isEmpty {
                    Text(t("还没有可以接续的内容。记录一个工作节点后，明天这里会告诉你停在哪。", "Nothing to pick up yet. Record a moment and tomorrow this shows where you stopped."))
                        .foregroundStyle(RecallPalette.secondary)
                } else {
                    ForEach(Array(resume.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().opacity(0.55) }
                        resumeRow(item)
                    }
                }
            }
            if let latest = model.state.dailySummaries.max(by: { $0.day < $1.day }) {
                recentReview(latest)
            }
            if !commitments.isEmpty {
                section(t("往来承诺", "Commitments"), detail: t("仅来自已理解的聊天记录；对象是会话窗口，不代表具体某人。", "Only from understood conversations. The counterpart is the conversation window, not a verified person.")) {
                    let iOwe = commitments.filter { $0.direction == .iOwe }, owed = commitments.filter { $0.direction == .owedToMe }
                    HStack(alignment: .top, spacing: 18) {
                        commitmentColumn(t("你欠别人的", "You owe"), iOwe)
                        commitmentColumn(t("别人欠你的", "Owed to you"), owed)
                    }
                    if commitments.count > 10 {
                        Button(showsAllCommitments ? t("收起", "Show less") : t("显示全部 \(commitments.count) 项", "Show all \(commitments.count)")) { showsAllCommitments.toggle() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(RecallPalette.accent)
                    }
                }
            }
            if !model.state.privacy.cloudUseEnabled || !model.state.llmConfiguration.hasCredential { OfflineDayCard() }
        }
        // A single reading column instead of lines that stretch to the window edge.
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The day's review is the other half of "where did I stop": the list says what is
    /// still open, this says what actually happened. Read-only, from already saved text.
    private func recentReview(_ summary: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(t("最近回顾", "Latest review")).font(.headline)
                Text(summary.day.formatted(.dateTime.month().day().weekday()))
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                Spacer(minLength: 12)
                Button(t("打开回顾", "Open review")) { model.destination = .daily(summary.id) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(RecallPalette.accent)
            }
            let preview = reviewPreview(summary)
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 14))
                    .foregroundStyle(RecallPalette.text.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.recallSurface()
    }

    private func reviewPreview(_ summary: DailySummary) -> String {
        let raw = summary.modelOverview.flatMap { $0.isEmpty ? nil : $0 } ?? summary.content
        let cleaned = DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(
            from: DailySummaryContentFormatter.removingCitationMarkers(from: raw)
        )
        return cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: " ")
    }

    /// The old footnote explained where the data came from. A count tells the
    /// reader whether anything here needs attention.
    private func resumeSummary(_ resume: [LocalBriefing.ResumeItem], commitmentCount: Int) -> String {
        guard !resume.isEmpty else {
            return t("来自已保存的记录、进行中的主题和今天的提醒。", "From saved records, open topics and today's reminders.")
        }
        var parts = [t("\(resume.count) 项可以继续", "\(resume.count) to continue")]
        if commitmentCount > 0 { parts.append(t("\(commitmentCount) 项往来承诺", "\(commitmentCount) commitments")) }
        return parts.joined(separator: " · ")
    }

    private func resumeRow(_ item: LocalBriefing.ResumeItem) -> some View {
        Button { model.destination = item.destination } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon(item.kind))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RecallPalette.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 15, weight: .semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.system(size: 13))
                            .foregroundStyle(RecallPalette.secondary)
                            .lineLimit(1).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RecallPalette.secondary.opacity(0.7))
            }
            .padding(.vertical, 7)
            // Inset the highlight from the separators; flush edges read as cut lines.
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(hoveredItemID == item.id ? RecallPalette.selected : Color.clear)
                    .padding(.vertical, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredItemID = item.id }
            else if hoveredItemID == item.id { hoveredItemID = nil }
        }
    }
    private var personaQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("要不要让 Recall 了解你的工作习惯？", "Let Recall learn your working habits?")).font(.headline)
            Text(t("开启后，模型会从已保存的回顾里归纳习惯（例如“你常在下午集中回复消息”），写在“记忆 → 关于我”，每条都附依据，可逐条标记不准确或清空。默认不开启，只问这一次。",
                   "If you turn this on, the model summarizes habits from saved reviews (for example, \"you tend to reply to messages in the afternoon\") under Memory → About me. Each one shows its evidence and can be marked inaccurate or cleared. Off by default; Recall asks only once."))
                .font(.callout).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(t("开启", "Turn on")) { model.answerPersonaQuestion(enable: true) }.buttonStyle(.borderedProminent)
                Button(t("暂不", "Not now")) { model.answerPersonaQuestion(enable: false) }
            }
        }.recallSurface()
    }
    private var inbox: some View {
        section(t("收件箱", "Inbox"), detail: t("今天的主动通知已达上限（\(model.state.attentionSettings.dailyProactiveLimit) 条），其余放在这里。", "Today's proactive notification limit (\(model.state.attentionSettings.dailyProactiveLimit)) was reached; the rest wait here.")) {
            ForEach(model.state.attentionInbox.prefix(6)) { notice in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.title).font(.subheadline.weight(.medium))
                        Text(notice.body + " · " + notice.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(RecallPalette.secondary)
                    }
                    Spacer()
                    if notice.dailyReviewID != nil || notice.weeklyReportID != nil { Button(t("打开", "Open")) { model.openAttention(notice) } }
                    Button { model.dismissAttention([notice.id]) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            if model.state.attentionInbox.count > 1 {
                Button(t("全部清除", "Clear all")) { model.dismissAttention(Set(model.state.attentionInbox.map(\.id))) }.buttonStyle(.plain).font(.caption).foregroundStyle(RecallPalette.accent)
            }
        }
    }
    private func commitmentColumn(_ title: String, _ rows: [LocalBriefing.Commitment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title + " · \(rows.count)").font(.subheadline.weight(.semibold))
            if rows.isEmpty { Text(t("暂无", "None")).font(.caption).foregroundStyle(RecallPalette.secondary) }
            ForEach(rows.prefix(showsAllCommitments ? 30 : 5)) { row in
                Button { model.destination = .record(row.sourceID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                        Text(row.counterpart + (row.deadline.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func icon(_ kind: LocalBriefing.ResumeItem.Kind) -> String {
        switch kind { case .lastRecord: "clock.arrow.circlepath"; case .openTopic: "square.stack.3d.up"; case .dueReminder: "bell"; case .waitingOnOthers: "hourglass" }
    }
    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(RecallPalette.secondary)
            content()
        }.recallSurface()
    }
}

/// The review that works without any model: grouped by app, with rule-based leads and the user's notes.
struct OfflineDayCard: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var day = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
    var body: some View {
        let result = LocalBriefing.offlineDay(day, in: model.state)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("本地回顾", "Local review")).font(.headline)
                    Text(t("未连接模型时按应用整理，不发送任何内容。连接模型后可生成完整回顾。", "Without a model, records are grouped by app and nothing is sent. Connect a model for a full review."))
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                DatePicker("", selection: $day, in: ...Date.now, displayedComponents: .date).labelsHidden().fixedSize()
            }
            if result.recordCount == 0 {
                Text(t("这一天没有保存的记录。", "No records were saved on this day.")).foregroundStyle(RecallPalette.secondary)
            } else {
                Text(t("共 \(result.recordCount) 条记录", "\(result.recordCount) records")).font(.subheadline.weight(.medium))
                ForEach(result.groups.prefix(6)) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(group.app).font(.subheadline.weight(.medium))
                            Text("\(group.count) · " + group.first.formatted(date: .omitted, time: .shortened) + "–" + group.last.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                            Spacer()
                            if let first = group.sourceIDs.first { Button(t("查看", "View")) { model.destination = .record(first) }.buttonStyle(.plain).font(.caption).foregroundStyle(RecallPalette.accent) }
                        }
                        ForEach(group.titles, id: \.self) { Text("· " + $0).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(1) }
                    }
                }
                if !result.notes.isEmpty {
                    Divider()
                    Text(t("你的备注", "Your notes")).font(.subheadline.weight(.semibold))
                    ForEach(result.notes, id: \.id) { note in
                        Button { model.destination = .record(note.id) } label: { Text("· " + note.text).font(.callout).lineLimit(2).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                    }
                }
                if !result.actionLeads.isEmpty {
                    Divider()
                    Text(t("可能的待办线索", "Possible to-dos")).font(.subheadline.weight(.semibold))
                    Text(t("按本地规则识别，可能有误；需要时点“提醒我”再安排时间。", "Found by local rules and may be wrong. Choose Remind me to schedule one."))
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                    ForEach(result.actionLeads) { lead in
                        HStack {
                            Text("· " + lead.title).font(.callout).lineLimit(2)
                            Spacer()
                            Button(t("提醒我", "Remind me")) { model.prepareReminder(title: lead.title, detail: "", sourceIDs: lead.sourceIDs) }.font(.caption)
                        }
                    }
                }
            }
        }.recallSurface()
    }
}
