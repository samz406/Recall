import RecallKit
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RemindersView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var reminderBeingScheduled: ReminderCandidate?
    @State private var reminderShowingSources: ReminderCandidate?
    @State private var isCreatingReminder = false
    @State private var isConfirmingDismissAll = false
    @State private var reminderTab = 0
    @State private var proposedPage = 1
    @State private var scheduledPage = 1
    @State private var creationResult: ReminderCreationResult?
    @State private var highlightedReminderID: UUID?
    @State private var lists = ReminderPageLists()
    @State private var isConfirmingAddAll = false
    private let pageSize = 6

    // Filtered and sorted once per reminder change instead of on every property access.
    private var proposed: [ReminderCandidate] { lists.proposed }
    private var scheduled: [ReminderCandidate] { lists.active }

    let previewHistoryHover: Bool
    init(initialTab: Int = 0, previewHistoryHover: Bool = false) {
        _reminderTab = State(initialValue: initialTab); self.previewHistoryHover = previewHistoryHover
    }

    private var isDiscovering: Bool {
        if case .searching = model.reminderDiscoveryStatus { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            reminderHeader
            HStack(spacing: 24) {
                reminderTabButton("待处理", count: scheduled.count, tab: 0)
                reminderTabButton("待确认", count: proposed.count, tab: 1)
                reminderTabButton("历史", count: lists.historyRows, tab: 2)
                Spacer()
            }.padding(.horizontal, 24)
            Divider()
            if model.reminderNotificationsAllowed == false && !scheduled.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash")
                    Text(RecallLocalization.both("通知权限未开启，已安排的提醒不会推送。", "Notifications are off, so scheduled reminders won't alert you."))
                        .font(.callout)
                    Spacer(minLength: 8)
                    Button(RecallLocalization.both("去系统设置", "Open System Settings")) { model.openNotificationSettings() }
                }.foregroundStyle(RecallPalette.warning)
                    .padding(14).background(RecallPalette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24).padding(.top, 12)
            }
            if let result = creationResult {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.notificationIssue == nil ? "checkmark.circle" : "info.circle")
                    Text(result.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { creationResult = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(RecallLocalization.text("关闭"))
                }.foregroundStyle(result.notificationIssue == nil ? RecallPalette.accent : RecallPalette.warning)
                    .padding(14).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24).padding(.top, 12)
            }
            if reminderTab == 2 {
                ReminderHistoryView(previewHover: previewHistoryHover) { reminderShowingSources = $0 }
            } else {
            ScrollViewReader { proxy in
            ScrollView {
            VStack(spacing: 20) {
                if (reminderTab == 0 && scheduled.isEmpty) || (reminderTab == 1 && proposed.isEmpty) {
                    VStack(spacing: 16) {
                        Image(systemName: "bell").font(.system(size: 38, weight: .light)).foregroundStyle(RecallPalette.accent)
                        Text(RecallLocalization.text(reminderTab == 0 ? "暂时没有待处理的提醒" : "没有需要确认的待办")).font(.headline)
                        Text(reminderTab == 0
                             ? RecallLocalization.both("在‘待确认’中选择时间或加入今天后，事项会出现在这里；也可以直接新建提醒。", "Items appear here after you schedule them or add them to today from To confirm. You can also create one directly.")
                             : RecallLocalization.both("每日回顾中的明确行动会自动出现在这里；也可以手动深查允许参与的原始记录。", "Explicit actions from daily reviews appear here automatically. You can also search allowed records manually."))
                            .font(.callout).foregroundStyle(RecallPalette.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            Button(RecallLocalization.text("新建提醒")) { isCreatingReminder = true }.buttonStyle(.borderedProminent)
                            if reminderTab != 1 && !proposed.isEmpty {
                                Button(RecallLocalization.both("去看待确认（\(proposed.count)）", "To confirm (\(proposed.count))")) { reminderTab = 1 }
                            } else {
                                Button(RecallLocalization.text("发现待办")) { model.proposeReminders() }.disabled(isDiscovering)
                            }
                        }
                    }.frame(maxWidth: .infinity, minHeight: 400)
                } else { reminderLists }

            }
            .frame(maxWidth: 1_100)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
            .task(id: highlightedReminderID) {
                guard let id = highlightedReminderID else { return }
                await Task.yield()
                proxy.scrollTo(id, anchor: .center)
            }
            }
            reminderDiscoveryFeedback.padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .background(RecallPalette.background)
        .onAppear { lists = ReminderPageLists(model.state.reminders, captures: model.state.captures); openRequestedReminder() }
        .onChange(of: model.state.reminders) { _, reminders in lists = ReminderPageLists(reminders, captures: model.state.captures) }
        .onChange(of: model.navigationRevision) { _, _ in openRequestedReminder() }
        .sheet(item: $reminderBeingScheduled) { reminder in
            ReminderScheduleSheet(
                reminder: reminder,
                preferredHour: model.state.reminderLearningProfile.preferredHour
            ) { dueAt, recurrence in
                model.approveReminder(reminder, dueAt: dueAt, recurrence: recurrence)
            }
        }
        .sheet(isPresented: $isCreatingReminder) {
            NewReminderSheet(preferredHour: model.state.reminderLearningProfile.preferredHour) { title, detail, dueAt, recurrence in
                let result = try await model.createReminder(title: title, detail: detail, dueAt: dueAt, recurrence: recurrence)
                creationResult = result
                model.destination = .reminder(result.reminder.id)
                openRequestedReminder()
            }
        }
        .sheet(item: $reminderShowingSources) { reminder in
            ReminderSourceSheet(
                reminder: reminder,
                captures: model.state.captures.filter { reminder.sourceCaptureIDs.contains($0.id) }
            )
        }
        .onChange(of: proposed.count) { _, count in proposedPage = clampedPage(proposedPage, itemCount: count) }
        .onChange(of: scheduled.count) { _, count in scheduledPage = clampedPage(scheduledPage, itemCount: count) }
        .confirmationDialog(
            "忽略全部待确认提醒？",
            isPresented: $isConfirmingDismissAll,
            titleVisibility: .visible
        ) {
            Button("忽略 \(proposed.count) 项提醒", role: .destructive) {
                model.dismissAllProposedReminders()
            }
            Button(RecallLocalization.text("取消"), role: .cancel) {}
        } message: {
            Text(RecallLocalization.text("这些候选会标记为已忽略，不会创建或取消已安排的 macOS 通知。"))
        }
        .confirmationDialog(RecallLocalization.both("全部加入今天？", "Add all to today?"), isPresented: $isConfirmingAddAll, titleVisibility: .visible) {
            Button(RecallLocalization.both("加入 \(proposed.count) 项", "Add \(proposed.count) items")) { model.confirmAllProposedForToday() }
            Button(RecallLocalization.text("取消"), role: .cancel) {}
        } message: {
            Text(RecallLocalization.both("这些事项会出现在‘待处理’的今天分组，不会安排系统通知；需要提醒时可再选择时间。", "They appear under Today in Pending without system notifications. Pick a time later if you want an alert."))
        }
    }

    private func reminderTabButton(_ title: String, count: Int, tab: Int) -> some View {
        Button { reminderTab = tab } label: {
            Text(RecallLocalization.text(title) + " \(count)").font(.system(size: 14, weight: reminderTab == tab ? .semibold : .regular))
                .foregroundStyle(reminderTab == tab ? RecallPalette.accent : RecallPalette.secondary)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { if reminderTab == tab { Rectangle().fill(RecallPalette.accent).frame(height: 2) } }
        }.buttonStyle(.plain)
    }
    private func openRequestedReminder() {
        if case .reminder(let id) = model.destination,
           let location = ReminderListLocation(id: id, reminders: model.state.reminders, pageSize: pageSize) {
            highlightedReminderID = id
            reminderTab = location.tab
            if location.tab == 1 { proposedPage = location.page }
            if location.tab == 0 { scheduledPage = location.page }
        }
    }
    private var reminderHeader: some View {
        RecallPageHeader(title: "提醒", subtitle: "把需要跟进的事，放到合适的时间") {
            HStack(spacing: 12) {
                Button(RecallLocalization.text(isDiscovering ? "正在发现…" : "发现待办")) { model.proposeReminders() }.disabled(isDiscovering)
                    .help(RecallLocalization.text("手动深查允许参与的原始记录；每日回顾中的明确行动会自动进入待确认"))
                Menu {
                    Toggle(RecallLocalization.text("从每日回顾更新提醒"), isOn: Binding(get: { model.state.reminderLearningProfile.reviewDiscoveryEnabled != false }, set: { value in model.setReviewReminderDiscovery(value) }))
                    Text(RecallLocalization.text("复用已生成的回顾，不增加模型调用；安排时间后才通知。"))
                } label: { Image(systemName: "slider.horizontal.3").accessibilityLabel("待办发现设置") }
                .menuStyle(.borderlessButton).fixedSize()
                Button { isCreatingReminder = true } label: { Label(RecallLocalization.text("新建提醒"), systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var reminderDiscoveryFeedback: some View {
        ReminderDiscoveryStatusView()
    }

    @ViewBuilder
    private var reminderLists: some View {
        VStack(alignment: .leading, spacing: 22) {
            if reminderTab == 0 && !scheduled.isEmpty {
                // Re-evaluated every minute so rows turn overdue while the page stays open.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                let now = context.date
                let overdue = scheduled.filter { ReminderTimeline.isOverdue($0, now: now) }
                let dueToday = scheduled.filter { ReminderTimeline.effectiveDueAt($0).map { $0 >= now && Calendar.current.isDate($0, inSameDayAs: now) } == true }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(overdue.isEmpty && dueToday.isEmpty ? "接下来" : "现在需要处理")
                            .font(.title3.weight(.semibold))
                        Text("\(scheduled.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(overdue.isEmpty ? RecallPalette.accent : RecallPalette.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background((overdue.isEmpty ? RecallPalette.accent : RecallPalette.danger).opacity(0.12), in: Capsule())
                        Spacer()
                        if !overdue.isEmpty {
                            Label("\(overdue.count) 项已过期", systemImage: "exclamationmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(RecallPalette.danger)
                        }
                    }
                    let rows = paged(scheduled, page: scheduledPage)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, reminder in
                        if index == 0 || timeGroup(rows[index - 1], now: now) != timeGroup(reminder, now: now) {
                            Text(RecallLocalization.text(timeGroup(reminder, now: now))).font(.headline).foregroundStyle(RecallPalette.secondary).padding(.top, 8)
                        }
                        reminderCard(reminder, deliveryState: model.reminderDeliveryStates[reminder.id], now: now)
                    }
                    ReminderPagination(page: $scheduledPage, itemCount: scheduled.count, pageSize: pageSize)
                }
                }
            }
            if reminderTab == 1 && !proposed.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(RecallLocalization.text("待你确认"))
                            .font(.title3.weight(.semibold))
                        Text("\(proposed.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RecallPalette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(RecallPalette.selected, in: Capsule())
                        Spacer()
                        Button(RecallLocalization.both("全部加入今天", "Add all to today")) { isConfirmingAddAll = true }
                            .buttonStyle(.bordered)
                        Button(RecallLocalization.text("全部忽略"), role: .destructive) {
                            isConfirmingDismissAll = true
                        }
                        .buttonStyle(.bordered)
                    }
                    ForEach(paged(proposed, page: proposedPage)) { reminder in
                        reminderCard(reminder, deliveryState: nil, now: .now)
                    }
                    ReminderPagination(page: $proposedPage, itemCount: proposed.count, pageSize: pageSize)
                }
            }

        }
    }

    private func timeGroup(_ reminder: ReminderCandidate, now: Date) -> String {
        if let day = reminder.plannedForDay, reminder.status == .planned { return day.sortKey == LocalDay().sortKey ? "今天" : (day.sortKey < LocalDay().sortKey ? "此前安排" : "未定时间") }
        guard let due = ReminderTimeline.effectiveDueAt(reminder) else { return "未定时间" }
        if due < now { return "已逾期" }
        return Calendar.current.isDate(due, inSameDayAs: now) ? "今天" : "以后"
    }
    private func reminderCard(_ reminder: ReminderCandidate, deliveryState: ReminderDeliveryState?, now: Date) -> some View {
        ReminderCandidateCard(
            reminder: reminder,
            deliveryState: deliveryState,
            now: now,
            schedule: { reminderBeingScheduled = reminder },
            complete: { model.completeReminder(reminder) },
            snooze: { date in model.snoozeReminder(reminder, until: date) },
            dismiss: { model.dismissReminder(reminder) },
            remove: { model.removeReminder(reminder) },
            viewSources: { reminderShowingSources = reminder },
            preferredHour: model.state.reminderLearningProfile.preferredHour
        )
        .id(reminder.id)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(highlightedReminderID == reminder.id ? RecallPalette.accent : .clear, lineWidth: 1.5))
    }

    private func paged<T>(_ items: [T], page: Int) -> [T] {
        let start = min(max(page - 1, 0) * pageSize, items.count)
        let end = min(start + pageSize, items.count)
        return Array(items[start..<end])
    }

    private func clampedPage(_ page: Int, itemCount: Int) -> Int {
        min(max(page, 1), max(1, Int(ceil(Double(itemCount) / Double(pageSize)))))
    }
}

private struct ReminderPagination: View {
    @Binding var page: Int
    let itemCount: Int
    let pageSize: Int

    private var pageCount: Int {
        max(1, Int(ceil(Double(itemCount) / Double(pageSize))))
    }

    var body: some View {
        if pageCount > 1 {
            HStack(spacing: 10) {
                Spacer()
                Button(RecallLocalization.text("上一页")) { page = max(1, page - 1) }
                    .disabled(page <= 1)
                Text("\(page) / \(pageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RecallPalette.secondary)
                Button(RecallLocalization.text("下一页")) { page = min(pageCount, page + 1) }
                    .disabled(page >= pageCount)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct ReminderScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: ReminderCandidate
    let preferredHour: Int
    let onConfirm: (Date, ReminderRecurrence) -> Void
    @State private var selectedDate: Date
    @State private var recurrence: ReminderRecurrence

    init(reminder: ReminderCandidate, preferredHour: Int, onConfirm: @escaping (Date, ReminderRecurrence) -> Void) {
        self.reminder = reminder
        self.preferredHour = preferredHour
        self.onConfirm = onConfirm
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(24 * 60 * 60)
        let fallback = calendar.date(bySettingHour: preferredHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let earliest = Date.now.addingTimeInterval(60)
        _selectedDate = State(initialValue: max(reminder.dueAt ?? fallback, earliest))
        _recurrence = State(initialValue: reminder.recurrence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.status == .scheduled || reminder.status == .snoozed ? "修改提醒时间" : "设置提醒时间")
                    .font(.title2.weight(.semibold))
                Text(reminder.title)
                    .font(.subheadline)
                    .foregroundStyle(RecallPalette.secondary)
                    .lineLimit(2)
                if reminder.status == .scheduled || reminder.status == .snoozed, let currentDate = ReminderTimeline.effectiveDueAt(reminder) {
                    Text("当前安排：\(currentDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RecallPalette.accent)
                } else if let suggestedDate = reminder.dueAt {
                    Text(RecallLocalization.text("已根据记录中的时间线索预填建议时间，你可以直接修改。"))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                    Text("建议：\(suggestedDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RecallPalette.accent)
                } else {
                    Text(RecallLocalization.both(String(format: "记录中没有明确时间；已预填明天 %02d:00，请按需要调整。", preferredHour),
                                                 String(format: "No time was found in the record. Prefilled tomorrow at %02d:00; adjust as needed.", preferredHour)))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
            }

            ReminderDateTimeField(date: $selectedDate)
            if selectedDate <= .now {
                Text(RecallLocalization.both("请选择未来的提醒时间。", "Choose a future reminder time."))
                    .font(.caption).foregroundStyle(RecallPalette.warning)
            }

            Picker(RecallLocalization.text("重复"), selection: $recurrence) {
                ForEach(ReminderRecurrence.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(RecallLocalization.both("安排后可在‘待处理’中修改或取消。", "Edit or cancel it later from Pending."))
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                Spacer()
                Button(RecallLocalization.text("取消")) { dismiss() }
                Button(reminder.status == .scheduled || reminder.status == .snoozed ? "保存修改" : "确认并创建") {
                    onConfirm(selectedDate, recurrence)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedDate <= Date.now)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct NewReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: @MainActor (String, String, Date, ReminderRecurrence) async throws -> Void
    @State private var title = ""
    @State private var detail = ""
    @State private var dueAt: Date
    @State private var recurrence: ReminderRecurrence = .none
    @State private var isSaving = false
    @State private var saveError: String?

    init(preferredHour: Int, onCreate: @escaping @MainActor (String, String, Date, ReminderRecurrence) async throws -> Void) {
        self.onCreate = onCreate
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(86_400)
        _dueAt = State(initialValue: Calendar.current.date(bySettingHour: preferredHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(RecallLocalization.text("新建提醒")).font(.title2.weight(.semibold))
                Text(RecallLocalization.text("直接创建你已经确认的事项，不需要先经过记忆识别。"))
                    .font(.subheadline).foregroundStyle(RecallPalette.secondary)
            }
            TextField(RecallLocalization.text("要提醒什么"), text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16))
            TextField(RecallLocalization.text("补充说明（可选）"), text: $detail, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...6).frame(minHeight: 82)
            ReminderDateTimeField(date: $dueAt)
            if dueAt <= .now {
                Text(RecallLocalization.both("请选择未来的提醒时间。", "Choose a future reminder time."))
                    .font(.caption).foregroundStyle(RecallPalette.warning)
            }
            Picker(RecallLocalization.text("重复"), selection: $recurrence) {
                ForEach(ReminderRecurrence.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(RecallPalette.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(RecallLocalization.both("保存后显示在‘待处理’；通知未授权时显示在‘待确认’。", "Saved reminders appear in Pending, or To confirm if notifications are unavailable."))
                    .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(RecallLocalization.text("取消")) { dismiss() }
                Button {
                    guard !isSaving else { return }
                    isSaving = true; saveError = nil
                    Task { @MainActor in
                        defer { isSaving = false }
                        do {
                            try await onCreate(title, detail, dueAt, recurrence)
                            dismiss()
                        } catch { saveError = error.localizedDescription }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text(RecallLocalization.both(isSaving ? "正在保存" : "创建提醒", isSaving ? "Saving" : "Create reminder"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dueAt <= .now)
            }
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .padding(24)
        .frame(width: 500)
    }
}

struct ReminderSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: ReminderCandidate
    let captures: [CaptureRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(RecallLocalization.text("提醒来源"))
                    .font(RecallTypography.title)
                Spacer()
                Button(RecallLocalization.text("关闭")) { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            // Short reminders use their natural height; long text and multiple sources scroll.
            ViewThatFits(in: .vertical) {
                sourceContent.fixedSize(horizontal: false, vertical: true)
                ScrollView { sourceContent }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: min(520, max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 200)))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: captures.isEmpty ? 540 : 660)
        .background(RecallPalette.surface)
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reminder.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if captures.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: reminder.origin == .manual ? "square.and.pencil" : "doc.questionmark")
                        .font(.system(size: 20))
                        .foregroundStyle(reminder.origin == .manual ? RecallPalette.accent : RecallPalette.secondary)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(RecallLocalization.both(reminder.origin == .manual ? "手动创建的提醒" : "来源记录已不可用",
                                                     reminder.origin == .manual ? "Manually created reminder" : "Source records unavailable"))
                            .font(.subheadline.weight(.medium))
                        Text(RecallLocalization.both(reminder.origin == .manual ? "由你直接创建，没有关联的采集记录。" : "对应记录可能已被删除或超过保留期限。",
                                                     reminder.origin == .manual ? "Created by you, with no linked capture records." : "The records may have been deleted or passed their retention period."))
                            .font(.caption).foregroundStyle(RecallPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RecallPalette.background, in: RoundedRectangle(cornerRadius: 10))
            }
            if !reminder.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(RecallLocalization.both("补充说明", "Details"))
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                    Text(reminder.detail).font(.callout)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if let basis = reminder.analysis?.basis, !basis.isEmpty {
                Label(basis, systemImage: "text.bubble")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !captures.isEmpty {
                HStack {
                    Text(RecallLocalization.both("关联记录", "Linked records")).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(RecallLocalization.both("\(captures.count) 条", "\(captures.count) records"))
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                let missing = Set(reminder.sourceCaptureIDs).subtracting(captures.map(\.id)).count
                if missing > 0 {
                    Text(RecallLocalization.both("另有 \(missing) 条来源已删除或超过保留期限。", "Another \(missing) source records were deleted or passed their retention period."))
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                ForEach(captures.sorted(by: { $0.createdAt > $1.createdAt })) { capture in
                    sourceRow(capture)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceRow(_ capture: CaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(capture.sourceAppName ?? RecallLocalization.text(capture.eventTemplate.title)).font(.subheadline.weight(.medium))
                    Spacer(minLength: 12)
                    sourceDate(capture)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(capture.sourceAppName ?? RecallLocalization.text(capture.eventTemplate.title)).font(.subheadline.weight(.medium))
                    sourceDate(capture)
                }
            }
            if !capture.ocrText.isEmpty {
                Text(capture.ocrText).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if let summary = capture.summary, !summary.isEmpty {
                Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else {
                Text(RecallLocalization.both("未保留原始文字", "Original text was not retained"))
                    .font(.callout).foregroundStyle(RecallPalette.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RecallPalette.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceDate(_ capture: CaptureRecord) -> some View {
        Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize()
    }
}

private struct ReminderCandidateCard: View {
    @EnvironmentObject private var model: RecallAppModel
    let reminder: ReminderCandidate
    let deliveryState: ReminderDeliveryState?
    let now: Date
    let schedule: () -> Void
    let complete: () -> Void
    let snooze: (Date) -> Void
    let dismiss: () -> Void
    let remove: () -> Void
    let viewSources: () -> Void
    let preferredHour: Int

    private var isActive: Bool { reminder.status.needsNotification }
    private var isOverdue: Bool { ReminderTimeline.isOverdue(reminder, now: now) }

    private var statusColor: Color {
        switch reminder.status {
        case .planned: RecallPalette.accent
        case .proposed: RecallPalette.warning
        case .scheduled, .snoozed: isOverdue ? RecallPalette.danger : .accentColor
        case .completed: RecallPalette.accent
        case .dismissed, .cancelled: RecallPalette.secondary
        }
    }

    private var statusIcon: String {
        switch reminder.status {
        case .planned: "checklist"
        case .proposed: "bell.badge"
        case .scheduled: isOverdue ? "exclamationmark.bell.fill" : "bell.fill"
        case .snoozed: "clock.badge"
        case .completed: "checkmark.circle.fill"
        case .dismissed, .cancelled: "bell.slash"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 36, height: 36)
                .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.title).font(.headline)
                if !reminder.detail.isEmpty {
                    Text(reminder.detail)
                        .font(.subheadline)
                        .foregroundStyle(RecallPalette.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 10) {
                    if !reminder.sourceCaptureIDs.isEmpty {
                        Button(action: viewSources) {
                            Label("\(reminder.sourceCaptureIDs.count) 条来源", systemImage: "link")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(RecallPalette.accent)
                    }
                    if reminder.status == .planned, let day = reminder.plannedForDay { Text(day.label) }
                    if let snoozed = reminder.snoozedUntil, reminder.status == .snoozed {
                        Label(RecallLocalization.both("稍后至 \(snoozed.formatted(date: .abbreviated, time: .shortened))", "Snoozed until \(snoozed.formatted(date: .abbreviated, time: .shortened))"), systemImage: "clock.badge")
                    } else if let dueAt = reminder.dueAt {
                        Label(
                            reminder.status == .proposed ? "建议：\(dueAt.formatted(date: .abbreviated, time: .shortened))" : dueAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "calendar"
                        )
                    } else if reminder.status == .proposed {
                        Label(RecallLocalization.text("创建前选择时间"), systemImage: "calendar.badge.clock")
                    }
                    if reminder.status == .proposed {
                        Text(reminder.analysis?.basis ?? "请核对行动与时间")
                    }
                    if reminder.recurrence != .none {
                        Label(reminder.recurrence.title, systemImage: "repeat")
                    }
                    Text(reminder.origin.title)
                }
                .font(.caption)
                .foregroundStyle(RecallPalette.secondary)
                if isActive, deliveryState == .notFound, !isOverdue, model.reminderNotificationsAllowed != false {
                    ReminderDeliveryBadge(state: deliveryState)
                } else if reminder.status == .completed {
                    Label(reminder.origin == .discovered ? "已完成" : "已由你标记完成", systemImage: "checkmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RecallPalette.secondary)
                }
            }
            Spacer()
            if reminder.status == .planned {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(RecallLocalization.text("今天要办"))
                    Button(RecallLocalization.text("标记完成"), action: complete).buttonStyle(.borderedProminent)
                    Button(RecallLocalization.text("提醒我…"), action: schedule)
                    Button(RecallLocalization.both("移出今天", "Remove from today"), role: .destructive, action: dismiss)
                }.font(.caption)
            } else if isActive {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(isOverdue ? "已过期" : (reminder.status == .snoozed ? "已稍后" : "已安排"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOverdue ? RecallPalette.danger : RecallPalette.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background((isOverdue ? RecallPalette.danger : RecallPalette.accent).opacity(0.10), in: Capsule())
                    Button(RecallLocalization.text("标记完成"), action: complete)
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                    HStack(spacing: 8) {
                        Menu(RecallLocalization.text("稍后")) {
                            ForEach(ReminderSnoozeOption.allCases.filter { $0.isAvailable(now: now) }) { option in
                                Button(option.title(preferredHour: preferredHour)) { snooze(option.date(preferredHour: preferredHour, now: .now)) }
                            }
                            Divider()
                            Button(RecallLocalization.both("选择时间…", "Choose a time…"), action: schedule)
                        }
                        .menuStyle(.borderlessButton)
                        Button(RecallLocalization.text("修改"), action: schedule)
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    Button(RecallLocalization.text("取消"), role: .destructive, action: dismiss).buttonStyle(.borderless).font(.caption)
                }
            } else if reminder.status == .proposed {
                VStack(alignment: .trailing, spacing: 8) {
                    Button(RecallLocalization.text("加入今天")) { model.addActionToToday(reminder.id) }.buttonStyle(.borderedProminent)
                    Button(RecallLocalization.text("提醒我…"), action: schedule).buttonStyle(.borderless)
                    Button(RecallLocalization.text("忽略"), role: .destructive, action: dismiss)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else if reminder.status == .completed || reminder.status == .cancelled {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(reminder.status == .completed ? "已完成" : "已取消")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RecallPalette.secondary)
                    Button(RecallLocalization.text("从列表移除"), action: remove)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .padding(18)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RecallPalette.border, lineWidth: 1))
    }
}

private struct ReminderDeliveryBadge: View {
    let state: ReminderDeliveryState?

    private var presentation: (text: String, symbol: String, color: Color) {
        switch state {
        case .pending:
            return ("已写入系统通知队列，等待投递", "clock.badge.checkmark", RecallPalette.accent)
        case .delivered:
            return ("已推送到 macOS 通知中心", "checkmark.bubble", RecallPalette.accent)
        case .notFound:
            return ("未在 macOS 通知队列中找到", "exclamationmark.triangle", RecallPalette.warning)
        case .none:
            return ("正在核验 macOS 通知状态", "arrow.triangle.2.circlepath", RecallPalette.secondary)
        }
    }

    var body: some View {
        Label(presentation.text, systemImage: presentation.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(presentation.color)
    }
}


/// Derived lists for the reminder page, rebuilt only when reminders change.
struct ReminderPageLists {
    var proposed: [ReminderCandidate] = []
    var active: [ReminderCandidate] = []
    /// Matches the merged rows the history tab shows, not raw records.
    var historyRows = 0
    init() {}
    init(_ reminders: [ReminderCandidate], captures: [CaptureRecord]) {
        proposed = ReminderListLocation.proposed(reminders)
        active = ReminderListLocation.active(reminders)
        historyRows = ReminderHistoryIndex(reminders: reminders, captures: captures).rows().count
    }
}
