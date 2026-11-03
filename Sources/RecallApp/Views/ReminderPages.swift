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
    private let pageSize = 6

    private var proposed: [ReminderCandidate] {
        model.state.reminders
            .filter { $0.status == .proposed }
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture)
            }
    }

    private var scheduled: [ReminderCandidate] {
        model.state.reminders
            .filter { $0.status.isAction }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    private var overdue: [ReminderCandidate] {
        scheduled.filter { ($0.dueAt ?? .distantFuture) < .now }
    }

    private var today: [ReminderCandidate] {
        scheduled.filter { reminder in
            guard let dueAt = reminder.dueAt else { return false }
            return dueAt >= .now && Calendar.current.isDateInToday(dueAt)
        }
    }

    private var upcoming: [ReminderCandidate] {
        scheduled.filter { reminder in
            guard let dueAt = reminder.dueAt else { return true }
            return dueAt >= .now && !Calendar.current.isDateInToday(dueAt)
        }
    }

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
                reminderTabButton("历史", count: model.state.reminders.filter { [.completed, .cancelled, .dismissed].contains($0.status) }.count, tab: 2)
                Spacer()
            }.padding(.horizontal, 24)
            Divider()
            if reminderTab == 2 {
                ReminderHistoryView(previewHover: previewHistoryHover) { reminderShowingSources = $0 }
            } else {
            ScrollView {
            VStack(spacing: 20) {
                if (reminderTab == 0 && scheduled.isEmpty) || (reminderTab == 1 && proposed.isEmpty) {
                    VStack(spacing: 16) {
                        Image(systemName: "bell").font(.system(size: 38, weight: .light)).foregroundStyle(RecallPalette.accent)
                        Text(RecallLocalization.text(reminderTab == 0 ? "暂时没有待处理的提醒" : (reminderTab == 1 ? "没有需要确认的待办" : "还没有历史记录"))).font(.headline)
                        Text(RecallLocalization.text("每日回顾中的明确行动会先进入‘待确认’，安排时间后才通知；也可以手动深查原始记录。"))
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
            reminderDiscoveryFeedback.padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .background(RecallPalette.background)
        .onAppear { openRequestedReminder() }
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
                model.createReminder(title: title, detail: detail, dueAt: dueAt, recurrence: recurrence)
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
        if case .reminder(let id) = model.destination, let row = model.state.reminders.first(where: { $0.id == id }) {
            reminderTab = row.status == .proposed ? 1 : ([.completed, .cancelled, .dismissed].contains(row.status) ? 2 : 0)
            proposedPage = max(1, ((proposed.firstIndex { $0.id == id } ?? 0) / pageSize) + 1)
            scheduledPage = max(1, ((scheduled.firstIndex { $0.id == id } ?? 0) / pageSize) + 1)
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
        ReminderDiscoveryStatusView(openPending: { reminderTab = 1 })
    }

    @ViewBuilder
    private var reminderLists: some View {
        VStack(alignment: .leading, spacing: 22) {
            if reminderTab == 0 && !scheduled.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(overdue.isEmpty && today.isEmpty ? "接下来" : "现在需要处理")
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
                        if index == 0 || timeGroup(rows[index - 1]) != timeGroup(reminder) {
                            Text(RecallLocalization.text(timeGroup(reminder))).font(.headline).foregroundStyle(RecallPalette.secondary).padding(.top, 8)
                        }
                        reminderCard(reminder, deliveryState: model.reminderDeliveryStates[reminder.id])
                    }
                    ReminderPagination(page: $scheduledPage, itemCount: scheduled.count, pageSize: pageSize)
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
                        Button(RecallLocalization.text("全部忽略"), role: .destructive) {
                            isConfirmingDismissAll = true
                        }
                        .buttonStyle(.bordered)
                    }
                    ForEach(paged(proposed, page: proposedPage)) { reminder in
                        reminderCard(reminder, deliveryState: nil)
                    }
                    ReminderPagination(page: $proposedPage, itemCount: proposed.count, pageSize: pageSize)
                }
            }

        }
    }

    private func timeGroup(_ reminder: ReminderCandidate) -> String {
        if let day = reminder.plannedForDay, reminder.status == .planned { return day.sortKey == LocalDay().sortKey ? "今天" : (day.sortKey < LocalDay().sortKey ? "此前安排" : "以后") }
        guard let due = reminder.dueAt else { return "以后" }
        if due < .now { return "已逾期" }
        return Calendar.current.isDateInToday(due) ? "今天" : "以后"
    }
    private func reminderCard(_ reminder: ReminderCandidate, deliveryState: ReminderDeliveryState?) -> some View {
        ReminderCandidateCard(
            reminder: reminder,
            deliveryState: deliveryState,
            schedule: { reminderBeingScheduled = reminder },
            complete: { model.completeReminder(reminder) },
            snooze: { date in model.snoozeReminder(reminder, until: date) },
            dismiss: { model.dismissReminder(reminder) },
            remove: { model.removeReminder(reminder) },
            viewSources: { reminderShowingSources = reminder },
            preferredHour: model.state.reminderLearningProfile.preferredHour
        )
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

private struct ReminderMetric: View {
    let title: String
    let value: Int
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit()
                Text(RecallLocalization.text(title)).font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RecallPalette.border, lineWidth: 1))
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

private struct ReminderWorkflowStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(RecallPalette.onAccent)
                .frame(width: 23, height: 23)
                .background(RecallPalette.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(RecallLocalization.text(title)).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReminderEmptyState: View {
    let totalRecordCount: Int
    let eligibleRecordCount: Int
    let lastRunAt: Date?
    let isDiscovering: Bool
    let onCreate: () -> Void
    let onDiscover: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(RecallPalette.accent)
                .frame(width: 58, height: 58)
                .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 7) {
                Text(RecallLocalization.text("今天没有需要处理的提醒"))
                    .font(.title3.weight(.semibold))
                Text(discoveryDescription)
                    .font(.subheadline)
                    .foregroundStyle(RecallPalette.secondary)
                if let lastRunAt {
                    Text("上次后台分析：\(lastRunAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                Button(action: onDiscover) {
                    if isDiscovering {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(RecallLocalization.text("正在分析"))
                        }
                    } else {
                        Label(RecallLocalization.text("重新分析"), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isDiscovering)
                Button(action: onCreate) {
                    Label(RecallLocalization.text("新建提醒"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(RecallPalette.border, lineWidth: 1))
    }

    private var discoveryDescription: String {
        if totalRecordCount > 0, eligibleRecordCount == 0 {
            return "已有 \(totalRecordCount) 条记忆，但当前没有记录类型被允许参与提醒分析。可在“记录管理”中调整范围。"
        }
        return "后台已从 \(eligibleRecordCount) 条可用记忆中检查待办、承诺与截止事项；只有你确认后才会通知。"
    }
}

private struct ReminderFeature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon).foregroundStyle(RecallPalette.accent)
            Text(RecallLocalization.text(title)).font(.caption.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(RecallPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReminderScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: ReminderCandidate
    let onConfirm: (Date, ReminderRecurrence) -> Void
    @State private var selectedDate: Date
    @State private var recurrence: ReminderRecurrence

    init(reminder: ReminderCandidate, preferredHour: Int, onConfirm: @escaping (Date, ReminderRecurrence) -> Void) {
        self.reminder = reminder
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
                if reminder.status == .scheduled || reminder.status == .snoozed, let currentDate = reminder.dueAt {
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
                    Text(RecallLocalization.text("记录中没有明确时间；已预填明天上午 9:00，请按需要调整。"))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
            }

            DatePicker(
                "提醒时间",
                selection: $selectedDate,
                in: Date.now...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.field)

            Picker(RecallLocalization.text("重复"), selection: $recurrence) {
                ForEach(ReminderRecurrence.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(RecallLocalization.text("创建后仍可在“已安排”中取消提醒。"))
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

private struct NewReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, String, Date, ReminderRecurrence) -> Void
    @State private var title = ""
    @State private var detail = ""
    @State private var dueAt: Date
    @State private var recurrence: ReminderRecurrence = .none

    init(preferredHour: Int, onCreate: @escaping (String, String, Date, ReminderRecurrence) -> Void) {
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
                .lineLimit(2...4)
            DatePicker("提醒时间", selection: $dueAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
            Picker(RecallLocalization.text("重复"), selection: $recurrence) {
                ForEach(ReminderRecurrence.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button(RecallLocalization.text("取消")) { dismiss() }
                Button(RecallLocalization.text("创建提醒")) {
                    onCreate(title, detail, dueAt, recurrence)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dueAt <= .now)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct ReminderSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: ReminderCandidate
    let captures: [CaptureRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecallLocalization.text("提醒来源"))
                        .font(.title2.weight(.semibold))
                    Text(reminder.title)
                        .font(.subheadline)
                        .foregroundStyle(RecallPalette.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(RecallLocalization.text("关闭")) { dismiss() }
                    .buttonStyle(.bordered)
            }

            if let analysis = reminder.analysis {
                Label(analysis.basis, systemImage: "text.bubble")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }

            if captures.isEmpty {
                ContentUnavailableView(
                    reminder.origin == .manual ? "这是手动创建的提醒" : "来源记录已不存在",
                    systemImage: "doc.questionmark",
                    description: Text(reminder.origin == .manual ? (reminder.detail.isEmpty ? "没有关联采集记录。" : reminder.detail) : "对应记录可能已被删除或超过了保留期限。")
                )
            } else {
                List(captures.sorted(by: { $0.createdAt > $1.createdAt })) { capture in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(capture.sourceAppName ?? capture.eventTemplate.title)
                                .font(.headline)
                            Spacer()
                            Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                        }
                        Text(capture.ocrText.isEmpty ? (capture.summary ?? "未保留原始文字") : capture.ocrText)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(RecallPalette.background)
            }
        }
        .padding(24)
        .frame(width: 680, height: 480)
    }
}

private struct ReminderCandidateCard: View {
    @EnvironmentObject private var model: RecallAppModel
    let reminder: ReminderCandidate
    let deliveryState: ReminderDeliveryState?
    let schedule: () -> Void
    let complete: () -> Void
    let snooze: (Date) -> Void
    let dismiss: () -> Void
    let remove: () -> Void
    let viewSources: () -> Void
    let preferredHour: Int

    private var isActive: Bool {
        reminder.status == .scheduled || reminder.status == .snoozed
    }

    private var isOverdue: Bool {
        isActive && (reminder.dueAt ?? .distantFuture) < .now
    }

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
                    if let dueAt = reminder.dueAt {
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
                if isActive, deliveryState == .notFound, !isOverdue {
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
                    Button(RecallLocalization.text("取消"), role: .destructive, action: dismiss)
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
                            Button(RecallLocalization.text("1 小时后")) { snooze(.now.addingTimeInterval(60 * 60)) }
                            Button("明天 \(preferredHour):00") {
                                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(86_400)
                                snooze(Calendar.current.date(bySettingHour: preferredHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
                            }
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

