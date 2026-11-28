import SwiftUI
import AppKit
import RecallKit

private func t(_ chinese: String, _ english: String) -> String { RecallLocalization.both(chinese, english) }

struct QuickProgressDraft: Identifiable, Equatable {
    let id = UUID()
    var topicTitle: String
    var lockedTopic: Bool
    var markAsNextStep: Bool = false
}

/// "Today": ten-second context recovery — focus on the top #1 matter, scan the urgency-sorted queue,
/// keep waiting-on-others and missing-review prompts cleanly separated at the bottom.
struct TodayWorkspaceView: View {
    @EnvironmentObject private var model: RecallAppModel
    @AppStorage("recall.today.tab") private var tab = TodayTab.overview.rawValue
    @State private var quickProgressDraft: QuickProgressDraft?
    enum TodayTab: String { case overview, reviews, reminders }

    private var proposedReminderCount: Int {
        model.state.reminders.filter { $0.status == .proposed }.count
    }

    private var recentTopicTitles: [String] {
        Array(
            TopicListPresentation.sections(model.matterFiles, registry: model.state.topicRegistry)
                .active
                .map(\.title)
                .prefix(4)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecallPageHeader(
                title: t("今天", "Today"),
                subtitle: t("十秒看清上次停在哪，先做最要紧的一件", "See where you stopped in seconds and tackle what matters first")
            ) {
                if (TodayTab(rawValue: tab) ?? .overview) == .overview {
                    HStack(spacing: 10) {
                        Button {
                            quickProgressDraft = QuickProgressDraft(topicTitle: "", lockedTopic: false)
                        } label: {
                            Label(t("记下进展", "Log progress"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            model.openAskRequested = true
                        } label: {
                            Label(t("问一问", "Ask"), systemImage: "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            HStack(spacing: 24) {
                tabButton(t("概览", "Overview"), .overview)
                tabButton(t("回顾", "Reviews"), .reviews)
                tabButton(t("提醒", "Reminders"), .reminders, badge: proposedReminderCount)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            Divider()
            switch TodayTab(rawValue: tab) ?? .overview {
            case .overview:
                GeometryReader { viewport in
                    ScrollView {
                        TodayOverview(
                            wideLayout: viewport.size.width >= 900,
                            openQuickProgress: { draft in quickProgressDraft = draft },
                            switchToRemindersTab: { tab = TodayTab.reminders.rawValue }
                        )
                        .padding(24)
                        .frame(maxWidth: 1120, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                }
            case .reviews:
                ReviewWorkspaceView(showsHeader: false)
            case .reminders:
                RemindersView()
            }
        }
        // Navigation can switch to Today before this view exists, so read the request on appear as well.
        .onAppear { followDestination(); if model.reviewsRequested { tab = TodayTab.reviews.rawValue } }
        .onChange(of: model.navigationRevision) { _, _ in followDestination() }
        .onReceive(NotificationCenter.default.publisher(for: .recallOpenReminders)) { _ in tab = TodayTab.reminders.rawValue }
        .onChange(of: model.reviewsRequested) { _, requested in if requested { tab = TodayTab.reviews.rawValue } }
        .sheet(item: $quickProgressDraft) { draft in
            QuickProgressSheet(draft: draft, recentTopics: recentTopicTitles) { note in
                await model.saveManualMatter(note)
            }
        }
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
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RecallPalette.selected, in: Capsule())
                }
            }
            .foregroundStyle(tab == value.rawValue ? RecallPalette.accent : RecallPalette.secondary)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                if tab == value.rawValue {
                    Rectangle().fill(RecallPalette.accent).frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value.rawValue ? .isSelected : [])
    }
}

private struct TodayOverview: View {
    @EnvironmentObject private var model: RecallAppModel
    let wideLayout: Bool
    let openQuickProgress: (QuickProgressDraft) -> Void
    let switchToRemindersTab: () -> Void

    @State private var showsAllResume = false
    @State private var showsAllCommitments = false
    @State private var hoveredItemID: String?

    var body: some View {
        let brief = LocalBriefing.todayBrief(
            in: model.state,
            matters: model.matterFiles,
            matterLimit: showsAllResume ? 40 : 5
        )
        let proposed = ReminderListLocation.proposed(model.state.reminders)
        let iOweCommitments = LocalBriefing.commitments(in: model.state).filter { $0.direction == .iOwe }
        let latestSummary = model.state.dailySummaries.max(by: { $0.day < $1.day })
        let offlineMode = !model.state.privacy.cloudUseEnabled || !model.state.llmConfiguration.hasCredential
        let hasRightColumnContent = latestSummary != nil || !iOweCommitments.isEmpty || offlineMode

        VStack(alignment: .leading, spacing: 18) {
            if model.shouldAskAboutPersona { personaQuestion }
            if !model.state.attentionInbox.isEmpty { inbox }

            if wideLayout && hasRightColumnContent {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        resumeSection(brief)
                        if !proposed.isEmpty {
                            proposedRemindersCard(proposed)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 18) {
                        if let latestSummary {
                            recentReview(latestSummary)
                        }
                        if !iOweCommitments.isEmpty {
                            commitmentsSection(iOweCommitments)
                        }
                        if offlineMode {
                            OfflineDayCard()
                        }
                    }
                    .frame(width: 356, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    resumeSection(brief)
                    if !proposed.isEmpty {
                        proposedRemindersCard(proposed)
                    }
                    if let latestSummary {
                        recentReview(latestSummary)
                    }
                    if !iOweCommitments.isEmpty {
                        commitmentsSection(iOweCommitments)
                    }
                    if offlineMode {
                        OfflineDayCard()
                    }
                }
            }
        }
    }

    // MARK: - Resume ("接着干": Top Focus Card + Compact Queue + Waiting + Review Prompt)

    private func resumeSection(_ brief: LocalBriefing.TodayBrief) -> some View {
        let blockedCount = brief.actionItems.filter { $0.status == .blocked }.count
        let shownMatterCount = brief.actionItems.filter { $0.kind == .openMatter }.count
        let hiddenOpenCount = max(0, brief.totalOpenMatterCount - shownMatterCount)
        let queueItems = Array(brief.actionItems.dropFirst())

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(t("接着干", "Pick up where you stopped"))
                        .font(.headline)
                    if blockedCount > 0 {
                        RecallStatusBadge(title: t("\(blockedCount) 项卡住了", "\(blockedCount) blocked"), warning: true)
                    }
                }
                Text(resumeSubtitle(brief, hiddenOpenCount: hiddenOpenCount))
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
            }

            if let focus = brief.actionItems.first {
                focusMatterCard(focus)

                if !queueItems.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(queueItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().opacity(0.5) }
                            compactQueueRow(item)
                        }
                    }
                }

                if hiddenOpenCount > 0 || showsAllResume {
                    Button(showsAllResume
                           ? t("收起较早事项", "Show fewer")
                           : t("展开其余 \(hiddenOpenCount) 件待续事项", "Show \(hiddenOpenCount) more items")) {
                        withAnimation(.easeInOut(duration: 0.16)) { showsAllResume.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.accent)
                }
            } else {
                emptyActionState(hasWaiting: !brief.waitingItems.isEmpty)
            }

            if !brief.waitingItems.isEmpty {
                waitingSubsection(brief.waitingItems)
            }

            if let missing = brief.missingReview {
                missingReviewSubsection(missing)
            }
        }
        .recallSurface()
    }

    private func resumeSubtitle(_ brief: LocalBriefing.TodayBrief, hiddenOpenCount: Int) -> String {
        let totalActions = brief.actionItems.count + hiddenOpenCount
        if totalActions == 0 {
            if !brief.waitingItems.isEmpty {
                return t("当前没有需要你立刻动手的事项，下方有 \(brief.waitingItems.count) 件正在等结果", "Nothing needs immediate action right now; \(brief.waitingItems.count) waiting on others below")
            }
            return t("来自最近回顾和手动记录里尚未闭环的事，有据才列。", "Only evidence-backed unfinished work from recent reviews and notes.")
        }
        if totalActions == 1 {
            return t("当前就这 1 件事待处理，可以直接接着往下推", "Just this 1 item to pick up right now")
        }
        let rest = totalActions - 1
        return t("先处理最上面这一件，下面还有 \(rest) 件（按轻重排列）", "Start with the top focus item; \(rest) more below ordered by urgency")
    }

    private func emptyActionState(hasWaiting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(RecallPalette.accent)
                Text(hasWaiting
                     ? t("需要你亲自动手的事今天都清完了", "Your own hands-on items are clear for now")
                     : t("当前没有悬而未决的事项", "Nothing left hanging right now"))
                    .font(.subheadline.weight(.semibold))
            }
            if !hasWaiting {
                Text(t("工作告一段落时点「记下进展」留一句下次从哪开始，隔天打开就能十秒接上。", "Log progress or leave a note for your future self before switching context."))
                    .font(.callout)
                    .foregroundStyle(RecallPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(t("记下进展", "Log progress")) {
                    openQuickProgress(QuickProgressDraft(topicTitle: "", lockedTopic: false))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if !model.matterFiles.isEmpty {
                    Button(t("浏览全部主题", "Browse topics")) {
                        model.openMattersSectionRequested = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.accent)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Top Expanded Focus Card

    private func focusMatterCard(_ item: LocalBriefing.ResumeItem) -> some View {
        let isWarning = item.status == .blocked || (item.kind == .dueReminder && item.date < .now)
        let primaryHeadline = (item.nextAction?.isEmpty == false) ? item.nextAction! : item.title
        let contextBody: String = {
            if item.nextAction?.isEmpty == false {
                if DailyKnowledgeEngine.topicKey(item.fullDetail) != DailyKnowledgeEngine.topicKey(primaryHeadline) {
                    return item.fullDetail
                }
                if DailyKnowledgeEngine.topicKey(item.title) != DailyKnowledgeEngine.topicKey(primaryHeadline) {
                    return item.title
                }
                return ""
            }
            if DailyKnowledgeEngine.topicKey(item.fullDetail) != DailyKnowledgeEngine.topicKey(primaryHeadline) {
                return item.fullDetail
            }
            return ""
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                if let badge = statusBadgeText(for: item) {
                    semanticStatusPill(badge, isWarning: isWarning)
                }
                Text(focusMetaLine(for: item))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    openItem(item)
                } label: {
                    HStack(spacing: 3) {
                        Text(item.kind == .dueReminder ? t("看提醒", "Reminder") : t("看主题", "Topic"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.accent)
                }
                .buttonStyle(.plain)
            }

            Button {
                openItem(item)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(primaryHeadline)
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(RecallPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    if !contextBody.isEmpty {
                        Text(contextBody)
                            .font(.system(size: 14))
                            .foregroundStyle(RecallPalette.text.opacity(0.84))
                            .lineSpacing(3.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                focusPrimaryEntryControls(for: item)

                if item.kind == .openMatter {
                    Button(t("记下进展", "Log progress")) {
                        openQuickProgress(QuickProgressDraft(topicTitle: item.topicTitle ?? item.title, lockedTopic: true))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    Task { await model.completeResumeItem(item) }
                } label: {
                    Label(t("做完了", "Mark done"), systemImage: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if item.kind == .openMatter {
                    Button(t("今天先放下", "Pause for today")) {
                        Task { await model.shelveResumeItem(item) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if item.kind == .dueReminder,
                          let id = item.reminderID,
                          let reminder = model.state.reminders.first(where: { $0.id == id }) {
                    Menu(t("今天先放下", "Snooze")) {
                        ForEach(ReminderSnoozeOption.allCases.filter { $0.isAvailable() }) { option in
                            Button(option.title(preferredHour: model.state.reminderLearningProfile.preferredHour)) {
                                model.snoozeReminder(reminder, until: option.date(preferredHour: model.state.reminderLearningProfile.preferredHour))
                            }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }

                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((isWarning ? RecallPalette.warning : RecallPalette.accent).opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((isWarning ? RecallPalette.warning : RecallPalette.accent).opacity(0.28), lineWidth: 1)
        )
        .contextMenu { rowContextMenu(item) }
    }

    @ViewBuilder
    private func focusPrimaryEntryControls(for item: LocalBriefing.ResumeItem) -> some View {
        if let rawURL = item.savedPageURL, let url = URL(string: rawURL) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(t("打开原网页 ↗", "Open page ↗"), systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if !item.evidenceIDs.isEmpty {
                Button(t("看上次记录", "Last record")) {
                    model.openSources(item.evidenceIDs)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else if !item.evidenceIDs.isEmpty {
            Button(t("看上次记录", "Last record")) {
                model.openSources(item.evidenceIDs)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if let token = item.referenceToken {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                    model.noticeMessage = t("已复制 \(token)", "Copied \(token)")
                } label: {
                    Label(t("复制 \(token)", "Copy \(token)"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Button(t("看主题", "Open topic")) {
                openItem(item)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func focusMetaLine(for item: LocalBriefing.ResumeItem) -> String {
        if item.kind == .dueReminder {
            return item.date < .now
                ? t("到期时间：", "Due: ") + item.date.formatted(date: .abbreviated, time: .shortened)
                : t("今天 ", "Today ") + item.date.formatted(date: .omitted, time: .shortened)
        }
        let relative = lastConfirmedShortLabel(item.date)
        if let topic = item.topicTitle, !topic.isEmpty {
            return "\(topic) · \(relative)"
        }
        return relative
    }

    private func lastConfirmedShortLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day ?? 0
        if days <= 0 { return t("今天最后确认", "Confirmed today") }
        if days == 1 { return t("昨天最后确认", "Confirmed yesterday") }
        return t("\(days) 天前最后确认", "Confirmed \(days)d ago")
    }

    // MARK: - Compact Single-Line Queue Row

    private func compactQueueRow(_ item: LocalBriefing.ResumeItem) -> some View {
        let isHovered = hoveredItemID == item.id
        let isWarning = item.status == .blocked || (item.kind == .dueReminder && item.date < .now)
        let displayTitle = (item.nextAction?.isEmpty == false) ? item.nextAction! : item.title
        let topicPrefix: String? = {
            guard let topic = item.topicTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !topic.isEmpty,
                  DailyKnowledgeEngine.topicKey(topic) != DailyKnowledgeEngine.topicKey(displayTitle) else { return nil }
            return topic
        }()

        return HStack(alignment: .center, spacing: 10) {
            Button {
                openItem(item)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    if let badge = statusBadgeText(for: item) {
                        semanticStatusPill(badge, isWarning: isWarning)
                    }
                    if let topicPrefix {
                        Text(topicPrefix)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RecallPalette.text.opacity(0.9))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(RecallPalette.secondary)
                    }
                    Text(item.kind == .dueReminder
                         ? item.date.formatted(date: .omitted, time: .shortened)
                         : TopicListPresentation.relativeTime(item.date))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                        .fixedSize()

                    Text(displayTitle)
                        .font(.system(size: 14))
                        .foregroundStyle(RecallPalette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered {
                compactHoverActions(for: item)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RecallPalette.secondary.opacity(0.6))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? RecallPalette.selected : Color.clear)
        )
        .onHover { hovering in
            if hovering { hoveredItemID = item.id }
            else if hoveredItemID == item.id { hoveredItemID = nil }
        }
        .contextMenu { rowContextMenu(item) }
    }

    @ViewBuilder
    private func compactHoverActions(for item: LocalBriefing.ResumeItem) -> some View {
        HStack(spacing: 6) {
            if item.kind == .openMatter {
                Button(t("记下进展", "Log")) {
                    openQuickProgress(QuickProgressDraft(topicTitle: item.topicTitle ?? item.title, lockedTopic: true))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Button(t("做完了", "Done")) {
                Task { await model.completeResumeItem(item) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            if item.kind == .openMatter {
                Button(t("先放下", "Pause")) {
                    Task { await model.shelveResumeItem(item) }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else if item.kind == .dueReminder,
                      let id = item.reminderID,
                      let reminder = model.state.reminders.first(where: { $0.id == id }) {
                Menu(t("先放下", "Snooze")) {
                    ForEach(ReminderSnoozeOption.allCases.filter { $0.isAvailable() }) { option in
                        Button(option.title(preferredHour: model.state.reminderLearningProfile.preferredHour)) {
                            model.snoozeReminder(reminder, until: option.date(preferredHour: model.state.reminderLearningProfile.preferredHour))
                        }
                    }
                }
                .controlSize(.mini)
                .fixedSize()
            }
        }
        .fixedSize()
    }

    // MARK: - Waiting on Others ("等结果") & Bottom Review Prompt ("整理")

    private func waitingSubsection(_ items: [LocalBriefing.ResumeItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledDivider(t("等结果（\(items.count)）", "Waiting on results (\(items.count))"))

            ForEach(items) { item in
                let isHovered = hoveredItemID == item.id
                HStack(alignment: .center, spacing: 10) {
                    Button {
                        openItem(item)
                    } label: {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(RecallPalette.text)
                                .lineLimit(1)
                            Text("·")
                                .foregroundStyle(RecallPalette.secondary)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isHovered {
                        HStack(spacing: 6) {
                            Button(t("我来跟进", "Follow up")) {
                                openQuickProgress(QuickProgressDraft(topicTitle: item.topicTitle ?? item.title, lockedTopic: false, markAsNextStep: true))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            if !item.evidenceIDs.isEmpty {
                                Button(t("设提醒", "Remind me")) {
                                    model.prepareReminder(title: item.title, detail: item.detail, sourceIDs: item.evidenceIDs)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        .fixedSize()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RecallPalette.secondary.opacity(0.6))
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? RecallPalette.selected : Color.clear)
                )
                .onHover { hovering in
                    if hovering { hoveredItemID = item.id }
                    else if hoveredItemID == item.id { hoveredItemID = nil }
                }
            }
        }
    }

    private func missingReviewSubsection(_ missing: LocalBriefing.MissingReviewPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledDivider(t("整理", "Organize"))

            HStack(spacing: 10) {
                Image(systemName: "doc.badge.plus")
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                if model.generatingDailyReviewDay == missing.day {
                    ProgressView().controlSize(.mini)
                    Text(t("正在生成\(missing.dayLabel)的回顾…", "Generating review for \(missing.dayLabel)…"))
                        .font(.callout)
                        .foregroundStyle(RecallPalette.secondary)
                    Spacer()
                } else {
                    Text(missing.title)
                        .font(.callout)
                        .foregroundStyle(RecallPalette.secondary)
                    Spacer()
                    Button(t("生成回顾", "Generate review")) {
                        model.generateDailyReview(on: missing.day)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func labeledDivider(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RecallPalette.secondary)
                .fixedSize()
            Rectangle()
                .fill(RecallPalette.border.opacity(0.75))
                .frame(height: 1)
        }
        .padding(.top, 2)
    }

    private func semanticStatusPill(_ text: String, isWarning: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(isWarning ? RecallPalette.warning : RecallPalette.accent)
            .background((isWarning ? RecallPalette.warning : RecallPalette.accent).opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private func statusBadgeText(for item: LocalBriefing.ResumeItem) -> String? {
        if item.hasUserNextStep {
            return t("下一步", "Next step")
        }
        switch item.kind {
        case .openMatter:
            switch item.status {
            case .blocked: return t("卡住了", "Blocked")
            case .pending: return t("还没做", "To do")
            default: return t("推进中", "In progress")
            }
        case .dueReminder:
            return item.date < .now ? t("已到期", "Overdue") : t("今天到期", "Due today")
        case .waitingOnOthers:
            return t("等结果", "Waiting")
        case .missingReview:
            return nil
        }
    }

    private func openItem(_ item: LocalBriefing.ResumeItem) {
        if item.kind == .missingReview {
            model.generateDailyReview(on: item.date)
        } else if item.kind == .openMatter, let file = model.resolveMatterFile(for: item) {
            model.destination = .topic(file.id)
        } else {
            model.destination = item.destination
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ item: LocalBriefing.ResumeItem) -> some View {
        Button(t("看主题", "Open topic")) { openItem(item) }
        if item.kind == .openMatter {
            Button(t("记下进展", "Log progress")) {
                openQuickProgress(QuickProgressDraft(topicTitle: item.topicTitle ?? item.title, lockedTopic: true))
            }
            Button(t("做完了", "Mark done")) {
                Task { await model.completeResumeItem(item) }
            }
            Button(t("今天先放下", "Pause for today")) {
                Task { await model.shelveResumeItem(item) }
            }
            Divider()
            if let topicID = model.resolveMatterFile(for: item)?.id ?? item.topicID {
                Button(t("继续问", "Continue asking")) {
                    model.openTopicConversation(topicID, fallbackEvidenceIDs: item.evidenceIDs)
                }
                Button(t("在记忆主题中打开", "Open in Topics")) {
                    model.openTopicInWorkspace(topicID)
                }
            }
            if !item.evidenceIDs.isEmpty {
                Button(t("设为提醒…", "Schedule reminder…")) {
                    model.prepareReminder(title: item.title, detail: item.summaryText, sourceIDs: item.evidenceIDs)
                }
                Button(t("看上次记录", "Last record")) {
                    model.openSources(item.evidenceIDs)
                }
            }
        } else if item.kind == .dueReminder, let id = item.reminderID,
                  let reminder = model.state.reminders.first(where: { $0.id == id }) {
            Button(t("做完了", "Mark done")) { model.completeReminder(reminder) }
            Menu(t("今天先放下", "Snooze")) {
                ForEach(ReminderSnoozeOption.allCases.filter { $0.isAvailable() }) { option in
                    Button(option.title(preferredHour: model.state.reminderLearningProfile.preferredHour)) {
                        model.snoozeReminder(reminder, until: option.date(preferredHour: model.state.reminderLearningProfile.preferredHour))
                    }
                }
            }
        }
    }

    // MARK: - Proposed Reminders Triage

    private func proposedRemindersCard(_ proposed: [ReminderCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Text(t("待确认的待办", "Suggested reminders"))
                        .font(.headline)
                    RecallStatusBadge(title: "\(proposed.count)")
                }
                Spacer()
                Button(t("查看全部", "View all")) {
                    switchToRemindersTab()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(RecallPalette.accent)
            }
            Text(t("从最近回顾识别到的明确承诺，由你决定是否加入今天或安排提醒时间。", "Explicit commitments found in recent reviews. Add to today or pick an alert time."))
                .font(.caption)
                .foregroundStyle(RecallPalette.secondary)

            ForEach(Array(proposed.prefix(3).enumerated()), id: \.element.id) { index, reminder in
                if index > 0 { Divider().opacity(0.5) }
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reminder.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        if !reminder.detail.isEmpty {
                            Text(reminder.detail)
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Button(t("加入今天", "Today")) {
                            model.addActionToToday(reminder.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button(t("设时间", "Schedule")) {
                            model.reminderDraft = reminder
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button {
                            model.dismissReminder(reminder)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(t("忽略这条候选", "Dismiss suggestion"))
                    }
                    .fixedSize()
                }
                .padding(.vertical, 4)
            }
        }
        .recallSurface()
    }

    // MARK: - Recent Review & Own Commitments

    private func recentReview(_ summary: DailySummary) -> some View {
        let itemCount = summary.items.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(t("最近回顾", "Latest review")).font(.headline)
                Text(summary.day.formatted(.dateTime.month().day().weekday()))
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(RecallPalette.secondary)
                    .background(RecallPalette.border.opacity(0.4), in: Capsule())
                Spacer(minLength: 8)
                Button(t("打开回顾", "Open review")) { model.destination = .daily(summary.id) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.accent)
            }
            let preview = reviewPreview(summary)
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(RecallPalette.text.opacity(0.88))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if itemCount > 0 {
                HStack(spacing: 8) {
                    Label(t("\(itemCount) 项重点", "\(itemCount) highlights"), systemImage: "list.bullet.indent")
                    Text("·")
                    Text(t("\(summary.sourceCaptureIDs.count) 条来源依据", "\(summary.sourceCaptureIDs.count) sources"))
                }
                .font(.caption)
                .foregroundStyle(RecallPalette.secondary)
            }
        }
        .recallSurface()
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

    private func commitmentsSection(_ iOwe: [LocalBriefing.Commitment]) -> some View {
        section(
            t("我答应的事", "Promises I made"),
            detail: t("来自已理解的聊天记录；对方欠你的已归入「接着干 → 等结果」。", "From understood conversations; items owed to you appear under Waiting on results.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(iOwe.prefix(showsAllCommitments ? 30 : 5)) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Button { model.destination = .record(row.sourceID) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                                Text(row.counterpart + (row.deadline.map { " · " + $0 } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(RecallPalette.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            model.prepareReminder(title: row.title, detail: row.counterpart, sourceIDs: [row.sourceID])
                        } label: {
                            Image(systemName: "bell")
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(t("设为提醒", "Schedule reminder"))
                    }
                }
            }
            if iOwe.count > 5 {
                Button(showsAllCommitments ? t("收起", "Show less") : t("显示全部 \(iOwe.count) 项", "Show all \(iOwe.count)")) {
                    showsAllCommitments.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(RecallPalette.accent)
            }
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

    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(RecallPalette.secondary)
            content()
        }.recallSurface()
    }
}

/// Minimalist progress logger shared across Today and Topics:
/// When opened for an existing topic (`lockedTopic == true`), hides topic name, category, and timestamp —
/// leaving only status selection (`推进中` / `还没做` / `卡住了` / `做完了`) and content / next-step note.
struct QuickProgressSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: QuickProgressDraft
    var recentTopics: [String] = []
    var onOpenHistoricalForm: (() -> Void)? = nil
    let save: (ManualMatterNote) async -> Bool

    @State private var title: String
    @State private var detail = ""
    @State private var status: WorkEpisodeStatus = .progressed
    @State private var markAsNextStep: Bool
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        draft: QuickProgressDraft,
        recentTopics: [String] = [],
        onOpenHistoricalForm: (() -> Void)? = nil,
        save: @escaping (ManualMatterNote) async -> Bool
    ) {
        self.draft = draft
        self.recentTopics = recentTopics
        self.onOpenHistoricalForm = onOpenHistoricalForm
        self.save = save
        _title = State(initialValue: draft.topicTitle)
        _markAsNextStep = State(initialValue: draft.markAsNextStep)
    }

    private var resolvedNextStep: String? {
        guard status != .completed, markAsNextStep else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ManualMatterNote.extractedNextAction(from: trimmed) ?? LocalBriefing.firstClause(trimmed)
    }

    private var note: ManualMatterNote {
        ManualMatterNote(
            title: title,
            detail: detail,
            status: status,
            eventAt: .now,
            nextAction: resolvedNextStep
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.markAsNextStep ? t("给下次的自己留一句", "Note for next time") : t("记下进展", "Log progress"))
                    .font(.title2.bold())
                Spacer()
                if draft.lockedTopic {
                    HStack(spacing: 5) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 10))
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .foregroundStyle(RecallPalette.accent)
                    .background(RecallPalette.selected, in: Capsule())
                }
            }

            if !draft.lockedTopic {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("哪件事", "Topic")).font(.subheadline.weight(.semibold))
                    TextField(t("例如：Atlas 问答改造（3–80 字）", "e.g. Atlas Q&A redesign (3–80 chars)"), text: $title)
                        .textFieldStyle(.roundedBorder)
                    if !recentTopics.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(recentTopics, id: \.self) { recent in
                                    Button(recent) { title = recent }
                                        .buttonStyle(.plain)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .foregroundStyle(title == recent ? RecallPalette.accent : RecallPalette.secondary)
                                        .background(title == recent ? RecallPalette.selected : RecallPalette.border.opacity(0.28), in: Capsule())
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(t("状态", "Status")).font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach([WorkEpisodeStatus.progressed, .pending, .blocked, .completed], id: \.self) { item in
                        RecallFilterChip(title: item.progressChoiceLabel, selected: status == item) {
                            status = item
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(markAsNextStep
                     ? t("下次接手先做什么", "Where to start next time")
                     : t("这次做了什么 / 下次从哪开始", "What happened / where to start next"))
                    .font(.subheadline.weight(.semibold))

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $detail)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 112)
                        .padding(8)
                        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RecallPalette.border, lineWidth: 1))

                    if detail.isEmpty {
                        Text(status == .completed
                             ? t("写一句最终结果或验收结论…", "Jot down the final outcome or verification result…")
                             : t("写下这次推进了什么、卡在哪，或写一句“下一步：…”留给下次接手…", "Write what moved forward, what blocked you, or “Next step: …” for next time…"))
                            .font(.callout)
                            .foregroundStyle(RecallPalette.secondary.opacity(0.75))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 15)
                            .allowsHitTesting(false)
                    }
                }

                if status != .completed {
                    Toggle(
                        t("作为下次接手提醒（在「今天 · 接着干」排到首位）", "Pin as my next step on Today"),
                        isOn: $markAsNextStep
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                    .padding(.top, 2)
                }
            }

            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(RecallPalette.danger)
            }

            HStack {
                if let onOpenHistoricalForm, !draft.lockedTopic {
                    Button(t("补记更早时间的记录…", "Backdate an earlier entry…")) {
                        dismiss()
                        onOpenHistoricalForm()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.accent)
                } else {
                    Text(t("仅保存在本机，可在时间线追溯或删除", "Saved locally only; traceable and deletable in Timeline"))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button(t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(isSaving ? t("正在保存…", "Saving…") : t("保存", "Save")) {
                    isSaving = true
                    saveError = nil
                    let submitted = note
                    Task { @MainActor in
                        if await save(submitted) { dismiss() }
                        else { saveError = t("未能保存，请检查字数后重试。", "Could not save. Check length and try again.") }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !note.isValid)
            }
        }
        .padding(24)
        .frame(width: 540)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
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
