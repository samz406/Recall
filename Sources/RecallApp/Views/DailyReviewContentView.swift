import SwiftUI
import RecallKit

/// The report is read and corrected as one document. Rows only expose real actions.
struct DailyReviewContentView: View {
    @EnvironmentObject private var model: RecallAppModel
    let summary: DailySummary
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
        VStack(alignment: .leading, spacing: 30) {
            if let notice = summary.modelCoverage?.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(RecallPalette.secondary)
            }
            if summary.formatVersion != 2 {
                Text("这份回顾使用较早的整理规则，可以重新生成；原版本会保留。")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            if rows.isEmpty { Text("这一天暂无可以可靠整理的内容，原始记录仍可在时间线查看。") }
            ForEach(DailySummarySection.displaySections) { section in
                let sectionRows = rows.filter { $0.section == section }
                if !sectionRows.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionHeading(section)
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(sectionRows) { item in itemRow(item) }
                        }.padding(.leading, 28)
                    }
                }
            }
            if let versions = summary.versions, !versions.isEmpty {
                DisclosureGroup("历史版本（\(versions.count)）") {
                    ForEach(versions) { version in
                        DisclosureGroup(version.createdAt.formatted()) {
                            MarkdownDocumentView(markdown: DailySummaryItemParser.markdown(from: version.items))
                                .font(RecallTypography.body).textSelection(.enabled).padding(.vertical, 12)
                        }.padding(.vertical, 8)
                    }
                }.font(.callout).foregroundStyle(RecallPalette.secondary)
            }
        }
    }
    private func sectionHeading(_ section: DailySummarySection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage).font(.system(size: 16, weight: .medium))
                .foregroundStyle(section == .actions ? RecallPalette.warning : RecallPalette.accent).frame(width: 18)
            Text(section == .progress ? "主线进展" : (section == .insights ? "值得留意" : "接下来要处理"))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(RecallPalette.text)
        }.accessibilityAddTraits(.isHeader)
    }
    private func statusLabel(_ status: String) -> String? {
        switch status { case "completed": "已完成"; case "inProgress": "进行中"; case "blocked": "受阻"; case "pending": "待处理"; default: nil }
    }
    private func itemRow(_ item: DailySummaryItem) -> some View {
        let text = ReviewContentQuality.presentation(item)
        let action = summary.todos.first { $0.id == item.actionCandidateID || $0.title == item.title }
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { itemTitle(text.title); itemStatus(item) }
                VStack(alignment: .leading, spacing: 6) { itemTitle(text.title); itemStatus(item) }
            }
            if !text.detail.isEmpty {
                Text(text.detail).font(RecallTypography.body).lineSpacing(5)
                    .foregroundStyle(RecallPalette.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if item.section == .actions, let action {
                HStack(spacing: 16) {
                    Button(model.reminder(for: action.title, sourceIDs: action.sourceCaptureIDs, candidateID: action.id) == nil ? "设为提醒" : "查看提醒") {
                        model.prepareReminder(title: action.title, detail: action.detail, sourceIDs: action.sourceCaptureIDs, candidateID: action.id)
                    }
                    Button("已完成") { model.completeSummaryAction(item, summary: summary) }
                }.buttonStyle(.borderless).font(.caption).padding(.top, 2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func itemTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold)).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    @ViewBuilder private func itemStatus(_ item: DailySummaryItem) -> some View {
        if let status = item.knowledge?.status, let label = statusLabel(status) {
            RecallStatusBadge(title: label, warning: status == "blocked").fixedSize()
        }
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
