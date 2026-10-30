import SwiftUI
import RecallKit

struct ReminderHistoryView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var filter: ReminderHistoryFilter = .all
    @State private var search = ""
    @State private var sourceID: String?
    @State private var page = 1
    @State private var deletion: HistoryDeletion?
    @State private var confirmsDeletion = false
    @State private var disabledSource: ReminderSourceChoice?
    @State private var confirmsSource = false
    let previewHover: Bool
    let showSources: (ReminderCandidate) -> Void
    private let pageSize = 20

    private var index: ReminderHistoryIndex { ReminderHistoryIndex(reminders: model.state.reminders, captures: model.state.captures) }
    private var matched: [ReminderCandidate] { index.matching(search: search, sourceID: sourceID) }
    private var rows: [ReminderHistoryRow] { index.rows(filter: filter, search: search, sourceID: sourceID) }
    private var ignoredIDs: Set<UUID> { Set(matched.filter { filter.includes($0.status) && $0.status == .dismissed }.map(\.id)) }
    private var pageCount: Int { max(1, (rows.count + pageSize - 1) / pageSize) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if rows.isEmpty { emptyState }
                            else {
                                let start = min((max(1, min(page, pageCount)) - 1) * pageSize, rows.count)
                                let visible = Array(rows[start..<min(start + pageSize, rows.count)])
                                ForEach(ReminderHistoryIndex.days(for: visible)) { group in
                                    dayGroup(group, compact: geometry.size.width < 1_000)
                                }
                                if pageCount > 1 { pagination }
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 20).id("history-top")
                    }.clipped()
                        .onChange(of: page) { _, _ in proxy.scrollTo("history-top", anchor: .top) }
                }
                footer
            }
        }
        .onChange(of: filter) { _, _ in page = 1 }
        .onChange(of: search) { _, _ in page = 1 }
        .onChange(of: sourceID) { _, _ in page = 1 }
        .onChange(of: rows.count) { _, _ in page = min(page, pageCount) }
        .onAppear(perform: openDestination)
        .onChange(of: model.navigationRevision) { _, _ in openDestination() }
        .confirmationDialog(deletion?.onlyDismissed == true ? "清理已忽略记录？" : "删除历史记录？", isPresented: $confirmsDeletion,
                            titleVisibility: .visible, presenting: deletion) { item in
            Button("删除 \(item.ids.count) 条历史记录", role: .destructive) {
                model.deleteReminderHistory(item.ids, onlyDismissed: item.onlyDismissed)
            }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text(item.onlyDismissed
                 ? "清理当前筛选范围内的全部已忽略记录，包含其他页。原始记忆、已完成与已取消记录保留；有效期内的忽略规则继续生效。"
                 : "只删除所选历史记录，原始记忆和已安排的提醒保留。有效期内的忽略规则继续生效。")
        }
        .confirmationDialog("不再从此应用识别待办？", isPresented: $confirmsSource, titleVisibility: .visible, presenting: disabledSource) { source in
            Button("停止从“\(source.title)”识别", role: .destructive) { model.setReminderApplication(source, disabled: true) }
            Button("取消", role: .cancel) {}
        } message: { source in
            Text("已有记录、待处理提醒和采集设置保持不变。可在“来源”菜单中恢复从“\(source.title)”识别待办。")
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { filters; Spacer(minLength: 12); searchAndSource }
            VStack(alignment: .leading, spacing: 12) { filters; searchAndSource }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private var filters: some View {
        HStack(spacing: 8) {
            ForEach(ReminderHistoryFilter.allCases) { value in
                let count = matched.filter { value.includes($0.status) }.count
                Button { filter = value } label: {
                    Text(value.title + " \(count)").font(.system(size: 13, weight: filter == value ? .medium : .regular))
                        .fixedSize().padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(filter == value ? RecallPalette.onAccent : RecallPalette.secondary)
                        .background(filter == value ? RecallPalette.accent : RecallPalette.border.opacity(0.35), in: Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
            }
        }
    }
    private var searchAndSource: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(RecallPalette.secondary)
                TextField("搜索历史", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                    .accessibilityLabel("搜索提醒历史")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(RecallPalette.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清除历史搜索")
                }
            }.padding(.horizontal, 11).frame(minWidth: 180, idealWidth: 210, maxWidth: 260).frame(height: 34)
                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(RecallPalette.border, lineWidth: 1))
            Menu {
                Button("全部来源") { sourceID = nil }
                ForEach(index.sourceChoices) { source in
                    Button(source.title) { sourceID = source.id }
                }
                let blocked = model.state.reminderLearningProfile.disabledReminderApplications
                if !blocked.isEmpty {
                    Divider()
                    Section("已停止识别的应用") {
                        ForEach(blocked.keys.sorted(), id: \.self) { key in
                            Button("恢复从“\(blocked[key] ?? key)”识别") {
                                model.setReminderApplication(ReminderSourceChoice(id: key, title: blocked[key] ?? key), disabled: false)
                            }
                        }
                    }
                }
            } label: {
                Text("来源：" + (sourceID.flatMap { id in index.sourceChoices.first { $0.id == id }?.title } ?? (sourceID == nil ? "全部" : "所选来源")))
                    .font(.system(size: 13)).lineLimit(1)
            }.menuStyle(.borderlessButton).padding(.horizontal, 12).frame(minWidth: 116, maxWidth: 180).frame(height: 34)
                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(RecallPalette.border, lineWidth: 1))
        }
    }
    private func dayGroup(_ group: ReminderHistoryDay, compact: Bool) -> some View {
        VStack(spacing: 9) {
            HStack {
                Text(group.title()).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(group.recordCount) 条").font(.system(size: 13)).foregroundStyle(RecallPalette.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { offset, row in
                    if offset > 0 { Divider().overlay(RecallPalette.border) }
                    ReminderHistoryEntry(row: row, compact: compact, previewHovered: previewHover && row.id == rows.first?.id,
                        busy: model.isUpdatingReminderHistory,
                        source: { showSources(row.sourceReminder) },
                        restore: { model.restoreReminderHistory(row.reminderIDs) },
                        block: { disabledSource = $0; confirmsSource = true },
                        delete: { deletion = HistoryDeletion(ids: row.reminderIDs, onlyDismissed: false); confirmsDeletion = true })
                }
            }.background(RecallPalette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecallPalette.border, lineWidth: 1))
        }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 30, weight: .light)).foregroundStyle(RecallPalette.secondary)
            Text(index.reminders.isEmpty ? "还没有历史记录" : "没有符合条件的历史记录").font(.headline)
            Text(index.reminders.isEmpty ? "完成、忽略或取消的提醒会按处理日期保存在这里。" : "换个关键词、状态或来源试试。")
                .font(.system(size: 13)).foregroundStyle(RecallPalette.secondary)
            if !index.reminders.isEmpty { Button("清除筛选") { search = ""; sourceID = nil; filter = .all } }
        }.frame(maxWidth: .infinity, minHeight: 270)
    }
    private var pagination: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("上一页") { page = max(1, page - 1) }.disabled(page <= 1)
            Text("\(min(page, pageCount)) / \(pageCount) 页").font(.system(size: 12)).foregroundStyle(RecallPalette.secondary)
            Button("下一页") { page = min(pageCount, page + 1) }.disabled(page >= pageCount)
        }.buttonStyle(.borderless).padding(.vertical, 4)
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(RecallPalette.border)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { discoveryStatus; cleanupButton }
                VStack(spacing: 8) { discoveryStatus; cleanupButton }
            }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 12)
        }
    }
    private var discoveryStatus: some View {
        ReminderDiscoveryStatusView()
    }
    @ViewBuilder private var cleanupButton: some View {
        if !ignoredIDs.isEmpty {
            Button("清理 \(ignoredIDs.count) 条已忽略记录") {
                deletion = HistoryDeletion(ids: ignoredIDs, onlyDismissed: true); confirmsDeletion = true
            }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(RecallPalette.accent)
                .disabled(model.isUpdatingReminderHistory).help("仅清理当前筛选范围内的已忽略记录，包含其他页")
        }
    }
    private func openDestination() {
        guard case .reminder(let id) = model.destination,
              model.state.reminders.contains(where: { $0.id == id && $0.status.isHistory }) else { return }
        filter = .all; sourceID = nil; search = ""
        let all = index.rows()
        let destinationPage = (all.firstIndex { $0.reminderIDs.contains(id) } ?? 0) / pageSize + 1
        Task { @MainActor in await Task.yield(); page = destinationPage }
    }
    private struct HistoryDeletion { let ids: Set<UUID>; let onlyDismissed: Bool }
}

private struct ReminderHistoryEntry: View {
    let row: ReminderHistoryRow
    let compact: Bool
    let previewHovered: Bool
    let busy: Bool
    let source: () -> Void
    let restore: () -> Void
    let block: (ReminderSourceChoice) -> Void
    let delete: () -> Void
    @State private var hovered = false
    private enum Focus: Hashable { case row, source, restore, block, delete, more }
    @FocusState private var focus: Focus?
    private var showsActions: Bool { hovered || focus != nil || previewHovered }
    private var color: Color {
        switch row.latest.status { case .completed: RecallPalette.accent; case .cancelled: RecallPalette.warning; default: RecallPalette.secondary }
    }
    private var label: String {
        switch row.latest.status { case .completed: "已完成"; case .cancelled: "已取消"; default: "已忽略" }
    }
    private var icon: String {
        switch row.latest.status { case .completed: "checkmark"; case .cancelled: "xmark"; default: "nosign" }
    }
    var body: some View {
        HStack(spacing: 12) {
            stateIcon
            entryTitle
            trailingControls
        }.font(.system(size: 12)).foregroundStyle(RecallPalette.accent)
            .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 54)
            .background(showsActions ? RecallPalette.selected : RecallPalette.surface)
            .contentShape(Rectangle()).onHover { hovered = $0 }
            .focusable().focused($focus, equals: .row)
            .onKeyPress(.return) {
                guard focus == .row else { return .ignored }
                source(); return .handled
            }
            .contextMenu { actions }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(row.title + "，" + label + "，" + row.sourceDescription)
            .accessibilityAction(named: Text("查看来源"), source)
            .accessibilityAction(named: Text("恢复为待确认"), restore)
            .accessibilityAction(named: Text("删除历史记录"), delete)
            .disabled(busy)
    }
    private var stateIcon: some View {
        Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            .frame(width: 30, height: 30).background(color.opacity(0.10), in: Circle())
    }
    private var entryTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(row.title).font(.system(size: 15)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(row.latest.status == .dismissed ? RecallPalette.secondary : RecallPalette.text)
                if row.reminders.count > 1 { duplicateBadge }
            }
            Text("来自 " + row.sourceDescription + " · " + reminderHistoryTime(row.date))
                .font(.system(size: 13)).foregroundStyle(RecallPalette.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).help(row.title)
    }
    private var duplicateBadge: some View {
        Text("×\(row.reminders.count)").font(.system(size: 11)).foregroundStyle(RecallPalette.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2).background(RecallPalette.border.opacity(0.35), in: Capsule())
            .fixedSize().help("同一天、同来源和同状态的 \(row.reminders.count) 条记录；恢复或删除会处理这整组")
    }
    @ViewBuilder private var trailingControls: some View {
        if showsActions {
            if compact { compactActions } else { wideActions }
        } else {
            Text(label).font(.system(size: 12)).foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 3)
                .background(color.opacity(0.10), in: Capsule()).fixedSize()
        }
    }
    private var compactActions: some View {
        HStack(spacing: 12) {
            Button("查看来源", action: source).buttonStyle(.plain).focused($focus, equals: .source)
            Menu { actions } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("历史记录操作").focused($focus, equals: .more)
        }
    }
    private var wideActions: some View {
        HStack(spacing: 12) {
            Button("查看来源", action: source).focused($focus, equals: .source)
            Button("恢复为待确认", action: restore).focused($focus, equals: .restore)
            if let application = row.sources.first, row.sources.count == 1 && application.isApplication {
                Button("不再从此应用识别") { block(application) }.focused($focus, equals: .block)
            } else if row.sources.contains(where: \.isApplication) {
                Menu("停止识别来源") { applicationActions }
            }
            Button(action: delete) { Image(systemName: "trash") }
                .accessibilityLabel("删除历史记录").focused($focus, equals: .delete)
        }.buttonStyle(.plain)
    }
    @ViewBuilder private var actions: some View {
        Button("查看来源", action: source)
        Button("恢复为待确认", action: restore)
        applicationActions
        Divider()
        Button("删除历史记录", role: .destructive, action: delete)
    }
    @ViewBuilder private var applicationActions: some View {
        ForEach(row.sources.filter(\.isApplication)) { application in
            Button("不再从“\(application.title)”识别") { block(application) }
        }
    }
}

private func reminderHistoryTime(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}
