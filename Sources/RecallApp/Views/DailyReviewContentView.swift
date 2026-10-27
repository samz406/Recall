import SwiftUI
import RecallKit

struct DailyReviewContentView: View {
    @EnvironmentObject private var model: RecallAppModel
    let summary: DailySummary
    @State private var expandedSections: Set<DailySummarySection> = []
    @State private var source: DailySummaryItem?
    private var items: [DailySummaryItem] {
        let live = Set(model.state.captures.map(\.id))
        let presented = summary.modelCoverage == nil ? DailySummaryItemParser.sanitized(summary.items) : DailySummaryItemParser.modelValidated(summary.items)
        return presented.filter { item in
            guard Set(item.evidenceIDs).isSubset(of: live) else { return false }
            if item.section == .actions,
               let reminder = model.reminder(for: item.title, sourceIDs: item.evidenceIDs, candidateID: item.actionCandidateID),
               [.completed, .cancelled, .dismissed].contains(reminder.status) { return false }
            return true
        }
    }
    var body: some View {
        let rows = items
        VStack(alignment: .leading, spacing: 24) {
            if summary.formatVersion != 2 {
                Text("这份回顾使用较早的整理规则，可以重新生成；原版本会保留。")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            if rows.isEmpty { Text("这一天暂无可以可靠整理的内容，原始记录仍可在时间线查看。") }
            ForEach(DailySummarySection.displaySections) { section in
                let sectionRows = rows.filter { $0.section == section }
                if !sectionRows.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(section.title, systemImage: section.systemImage)
                            .font(RecallTypography.title).foregroundStyle(section == .actions ? RecallPalette.warning : RecallPalette.accent)
                        let limit = section == .insights ? 2 : 5
                        ForEach(Array((expandedSections.contains(section) ? sectionRows : Array(sectionRows.prefix(limit))))) { item in
                            itemRow(item)
                        }
                        if sectionRows.count > limit {
                            Button(expandedSections.contains(section) ? "收起其余内容" : "展开其余 \(sectionRows.count - limit) 项") {
                                if !expandedSections.insert(section).inserted { expandedSections.remove(section) }
                            }.font(.callout)
                        }
                    }
                }
            }
            SummaryFeedbackFooter(target: .daily(summary))
            if let versions = summary.versions, !versions.isEmpty {
                DisclosureGroup("历史版本（\(versions.count)）") {
                    ForEach(versions) { version in
                        DisclosureGroup(version.createdAt.formatted()) {
                            MarkdownDocumentView(markdown: DailySummaryItemParser.markdown(from: version.items)).font(RecallTypography.body).textSelection(.enabled).padding(.vertical, 12)
                        }.padding(.vertical, 8)
                    }
                }.font(.callout).foregroundStyle(RecallPalette.secondary)
            }
        }.sheet(item: $source) { item in RecallSourcesView(title: item.title, ids: item.evidenceIDs).environmentObject(model) }
    }
    private func itemRow(_ item: DailySummaryItem) -> some View {
        let text = ReviewContentQuality.presentation(item)
        let action = summary.todos.first { $0.id == item.actionCandidateID || $0.title == item.title }
        return VStack(alignment: .leading, spacing: 9) {
            Text(text.title).font(RecallTypography.title).fixedSize(horizontal: false, vertical: true)
            if !text.detail.isEmpty {
                Text(text.detail)
                    .font(RecallTypography.body)
                    .foregroundStyle(RecallPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 16) {
                if item.section == .actions, let action {
                    Button(model.reminder(for: action.title, sourceIDs: action.sourceCaptureIDs, candidateID: action.id) == nil ? "设为提醒" : "查看提醒") {
                        model.prepareReminder(title: action.title, detail: action.detail, sourceIDs: action.sourceCaptureIDs, candidateID: action.id)
                    }
                    Button("已完成") { model.completeSummaryAction(item, summary: summary) }
                }
                Spacer(minLength: 0)
                Menu {
                    Button("反馈这条内容") { model.summaryFeedbackTarget = .daily(summary, item: item) }
                    Button("从这份回顾移除") { model.removeSummaryItem(item, from: summary, reason: .noLongerNeeded) }
                    Button("核对来源并更正") { source = item }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.font(.caption)
            Divider().padding(.top, 6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TopicMergeSheet: View {
    @EnvironmentObject var model: RecallAppModel
    @Environment(\.dismiss) var dismiss
    @State private var selected: Set<String> = []
    @State private var title = ""
    @State private var search = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("合并为同一个主题").font(.title2.bold())
            Text("只合并浏览方式，原始记录、时间和状态都会保留。可以在主题中撤销合并，相关旧回顾需重新生成。")
                .foregroundStyle(RecallPalette.secondary)
            TextField("合并后的主题名称", text: $title).textFieldStyle(.roundedBorder)
            TextField("筛选主题", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.matterFiles.filter { !$0.id.hasPrefix("group:") && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { file in
                        Toggle(file.title, isOn: Binding(get: { selected.contains(file.id) }, set: { value in
                            if value { selected.insert(file.id); if title.isEmpty { title = file.title } } else { selected.remove(file.id) }
                        }))
                    }
                }
            }.clipped()
            if let error { Text(error).foregroundStyle(RecallPalette.warning) }
            HStack {
                Text("已选 \(selected.count) 个主题").font(.caption)
                Spacer(); Button("取消") { dismiss() }.disabled(saving)
                Button("合并主题") {
                    saving = true
                    Task { if await model.mergeTopics(title: title, members: selected) { dismiss() } else { error = "未能合并，主题或分类可能已经变化。" }; saving = false }
                }.buttonStyle(.borderedProminent).disabled(saving || selected.count < 2 || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 640, height: 560).interactiveDismissDisabled(saving)
    }
}
