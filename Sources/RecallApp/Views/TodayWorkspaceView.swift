import AppKit
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
            case .overview: ScrollView { TodayOverview(showReminders: { tab = TodayTab.reminders.rawValue }).padding(24) }
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
    @State private var now = Date.now
    let showReminders: () -> Void

    var body: some View {
        let plan = LocalBriefing.today(in: model.state, matters: model.matterFiles, now: now)
        let commitments = plan.commitments
        VStack(alignment: .leading, spacing: 16) {
            TodayFocusCard(plan: plan)
            if !plan.reminders.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(t("到期提醒", "Reminders due"), systemImage: "bell").font(.headline)
                        Spacer()
                        Button(t("查看全部", "View all"), action: showReminders).buttonStyle(.link)
                    }
                    ForEach(plan.reminders.prefix(3)) { item in
                        Button { model.destination = item.destination } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(item.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer()
                                Text(item.detail).font(.callout).foregroundStyle(RecallPalette.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.recallSurface()
            }
            if let missing = plan.missingReview {
                let generating = model.generatingDailyReviewDay.map { Calendar.current.isDate($0, inSameDayAs: missing) } ?? false
                HStack {
                    Label(t("\(missing.formatted(.dateTime.month().day())) 的记录还没回顾", "Records for \(missing.formatted(.dateTime.month().day())) haven’t been reviewed"),
                          systemImage: "doc.text").foregroundStyle(RecallPalette.secondary)
                    Spacer()
                    Button(generating ? t("正在生成…", "Generating…") : t("生成当天回顾", "Review this day")) { model.generateDailyReview(on: missing) }
                        .disabled(generating)
                }.recallSurface(padding: 14)
            }
            if let latest = model.state.dailySummaries.max(by: { $0.day < $1.day }) { recentReview(latest) }
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
            if !model.state.attentionInbox.isEmpty { inbox }
            if model.shouldAskAboutPersona { personaQuestion }
            if !model.state.privacy.cloudUseEnabled || !model.state.llmConfiguration.hasCredential { OfflineDayCard() }
        }
        // A single reading column instead of lines that stretch to the window edge.
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { now = .now }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = .now }
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
    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(RecallPalette.secondary)
            content()
        }.recallSurface()
    }
}

private struct TodayFocusCard: View {
    @EnvironmentObject private var model: RecallAppModel
    @AppStorage("recall.today.focus") private var selection = ""
    @State private var choosing = false
    @State private var writing = false
    let plan: LocalBriefing.TodayPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let focus = plan.focus(selection: selection) {
                HStack(alignment: .firstTextBaseline) {
                    Label(t("接着做", "Pick up here"), systemImage: "arrow.turn.down.right")
                        .font(.headline).foregroundStyle(RecallPalette.accent)
                    Spacer()
                    if plan.matters.count > 1 {
                        Button(choosing ? t("收起", "Show less") : t("换一件（\(plan.matters.count - 1)）", "Choose another (\(plan.matters.count - 1))")) {
                            choosing.toggle()
                        }.buttonStyle(.link)
                    }
                }
                Text(focus.title).font(RecallTypography.section).fixedSize(horizontal: false, vertical: true)
                if !focus.detail.isEmpty && focus.detail != focus.title {
                    Text(focus.detail).foregroundStyle(RecallPalette.secondary).lineLimit(3)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { attribution(focus); Spacer(minLength: 12); openButton(focus) }
                    VStack(alignment: .leading, spacing: 10) { attribution(focus); openButton(focus) }
                }
                if choosing && plan.matters.count > 1 {
                    Divider()
                    ForEach(plan.matters.filter { $0.id != focus.id }) { item in
                        Button {
                            selection = plan.selectionKey(for: item)
                            choosing = false
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                                    attribution(item)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.to.line").foregroundStyle(RecallPalette.accent)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).multilineTextAlignment(.leading)
                        .help(t("设为今天先做的事", "Make this today’s focus"))
                    }
                }
            } else if model.isLoadingSavedState || model.isBuildingMatters {
                HStack { ProgressView().controlSize(.small); Text(t("正在读取进展…", "Loading progress…")) }
            } else {
                Text(t("接下来想做哪件事？", "What would you like to pick up?")).font(RecallTypography.title)
                Button(t("给下次留一步", "Leave a next step")) { writing = true }.buttonStyle(.borderedProminent)
            }
        }
        .recallSurface()
        .sheet(isPresented: $writing) { TopicNextStepSheet(file: nil) }
    }

    private func attribution(_ item: LocalBriefing.ResumeItem) -> some View {
        let reason: String
        switch item.basis {
        case .handwritten: reason = t("你留的下一步", "Your next step")
        case .action: reason = t("回顾里的下一步", "Next step from review")
        case .progress: reason = item.status == .blocked ? t("上次受阻", "Previously blocked") : t("上次进展", "Last update")
        }
        let parts = [item.topic, reason, TopicListPresentation.relativeTime(item.date)].compactMap { $0 }.filter { !$0.isEmpty }
        return Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(RecallPalette.secondary)
    }

    private func openButton(_ item: LocalBriefing.ResumeItem) -> some View {
        let label: String
        if case .topic = item.destination { label = t("继续这个主题", "Open topic") }
        else { label = t("查看当天回顾", "Open daily review") }
        return Button(label) { model.destination = item.destination }.buttonStyle(.borderedProminent)
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
