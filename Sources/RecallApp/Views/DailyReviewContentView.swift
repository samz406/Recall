import SwiftUI
import RecallKit

/// The report is read and corrected as one document. Rows only expose real actions.
struct DailyReviewContentView: View {
    @EnvironmentObject private var model: RecallAppModel
    let summary: DailySummary
    @State private var pendingCorrection: (item: DailySummaryItem, kind: MatterCorrectionKind)?
    /// Long sections show the first few items; the rest stay one click away, never removed.
    @State private var expandedSections: Set<DailySummarySection> = []
    static let visiblePerSection = 3
    private var items: [DailySummaryItem] {
        DailyReviewPresentation.items(in: summary, state: model.state)
    }
    private var completedActions: [DailySummaryItem] {
        let live = Set(model.state.captures.filter { !model.state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }.map(\.id))
        return summary.items.filter { item in
            guard item.section == .actions, item.evidenceIDs.contains(where: live.contains) else { return false }
            if item.knowledge?.status == "completed" { return true }
            if let action = DailyReviewPresentation.action(for: item, in: summary) {
                if action.status == .completed { return true }
                if let reminder = DailyReviewPresentation.reminder(for: action, item: item, in: model.state), reminder.status == .completed { return true }
            }
            return false
        }
    }
    var body: some View {
        let rows = items
        let completed = completedActions
        VStack(alignment: .leading, spacing: 30) {
            if let message = model.dailyReviewActionMessages[summary.id] {
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(RecallPalette.secondary)
            }
            if let notice = summary.modelCoverage?.notice {
                Label(RecallLocalization.text(notice), systemImage: "info.circle").font(.callout).foregroundStyle(RecallPalette.secondary)
            }
            if summary.formatVersion != 2 {
                Text(RecallLocalization.text("这份回顾使用较早的整理规则，可以重新生成；原版本会保留。"))
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            if rows.isEmpty && completed.isEmpty { Text(RecallLocalization.text("这一天暂无可以可靠整理的内容，原始记录仍可在时间线查看。")) }
            ForEach(DailySummarySection.displaySections) { section in
                let sectionRows = rows.filter { $0.section == section }
                if !sectionRows.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionHeading(section)
                        let expanded = expandedSections.contains(section)
                        let visible = expanded ? sectionRows : Array(sectionRows.prefix(Self.visiblePerSection))
                        VStack(alignment: .leading, spacing: 18) {
                            // A hairline between items gives the eye a stopping point;
                            // spacing alone made long items run together.
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().opacity(0.55) }
                                itemRow(item)
                            }
                            if sectionRows.count > Self.visiblePerSection {
                                Button(expanded ? RecallLocalization.both("收起", "Show less")
                                                : RecallLocalization.both("再看 \(sectionRows.count - Self.visiblePerSection) 条", "Show \(sectionRows.count - Self.visiblePerSection) more")) {
                                    if expanded { expandedSections.remove(section) } else { expandedSections.insert(section) }
                                }.buttonStyle(.plain).font(.callout).foregroundStyle(RecallPalette.accent)
                            }
                        }.padding(.leading, 28)
                    }
                }
            }
            if !completed.isEmpty {
                DisclosureGroup(RecallLocalization.both("已完成待办（\(completed.count)）", "Completed actions (\(completed.count))")) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(completed) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    itemTitle(item.title)
                                    Spacer(minLength: 8)
                                    RecallStatusBadge(title: RecallLocalization.text("已完成"), warning: false).fixedSize()
                                }
                                if !item.detail.isEmpty {
                                    Text(ReviewTextHighlight.attributed(item.detail)).font(RecallTypography.body).lineSpacing(5)
                                        .foregroundStyle(RecallPalette.secondary)
                                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                            }
                        }
                    }.padding(.top, 10)
                }.font(.callout).foregroundStyle(RecallPalette.secondary)
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
        .confirmationDialog(
            RecallLocalization.both("确认纠正这条内容？", "Correct this item?"),
            isPresented: Binding(get: { pendingCorrection != nil }, set: { if !$0 { pendingCorrection = nil } }),
            titleVisibility: .visible
        ) {
            Button(RecallLocalization.both("确认纠正", "Correct"), role: .destructive) {
                if let pending = pendingCorrection { model.correctMatter(MatterCorrection(evidenceIDs: pending.item.evidenceIDs, kind: pending.kind)) }
                pendingCorrection = nil
            }
            Button(RecallLocalization.text("取消"), role: .cancel) { pendingCorrection = nil }
        } message: {
            Text(RecallLocalization.both("该内容的来源记录将不再用于分析，会让相关回顾重新生成。", "The source records will no longer be used, and related reviews will be regenerated."))
        }
    }
    private func sectionHeading(_ section: DailySummarySection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage).font(.system(size: 16, weight: .medium))
                .foregroundStyle(section == .actions ? RecallPalette.warning : RecallPalette.accent).frame(width: 18)
            Text(RecallLocalization.text(section == .progress ? "主线进展" : (section == .insights ? "值得留意" : "接下来要处理")))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(RecallPalette.text)
        }.accessibilityAddTraits(.isHeader)
    }
    private func statusLabel(_ status: String) -> String? {
        switch status { case "completed": "已完成"; case "inProgress": "进行中"; case "blocked": "受阻"; case "pending": "待处理"; default: nil }
    }
    private func itemRow(_ item: DailySummaryItem) -> some View {
        let action = DailyReviewPresentation.action(for: item, in: summary)
        return VStack(alignment: .leading, spacing: 8) {
            // The status chip is pinned to the trailing edge so a long title wraps
            // underneath it instead of pushing it onto its own broken line.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { itemTitle(item.title); Spacer(minLength: 8); itemStatus(item); correctionMenu(item) }
                VStack(alignment: .leading, spacing: 6) { HStack { itemTitle(item.title); Spacer(minLength: 8); correctionMenu(item) }; itemStatus(item) }
            }
            if !item.detail.isEmpty {
                Text(ReviewTextHighlight.attributed(item.detail)).font(RecallTypography.body).lineSpacing(5)
                    .foregroundStyle(RecallPalette.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if item.section == .actions, let action {
                let reminder = DailyReviewPresentation.reminder(for: action, item: item, in: model.state)
                HStack(spacing: 16) {
                    if let reminder, reminder.status == .proposed {
                        Button(RecallLocalization.text("加入今天")) { model.addActionToToday(reminder.id) }
                    }
                    Button(reminder == nil ? RecallLocalization.text("设为提醒") : RecallLocalization.text("查看提醒")) {
                        model.prepareReminder(title: item.title, detail: item.detail, sourceIDs: Array(Set(action.sourceCaptureIDs + item.evidenceIDs)), candidateID: action.id)
                    }
                    Button(model.completingSummaryActionIDs.contains(item.id) ? RecallLocalization.both("保存中…", "Saving…") : RecallLocalization.both("标记完成", "Mark complete")) {
                        Task { await model.completeSummaryAction(item, summary: summary) }
                    }.accessibilityIdentifier("complete-daily-action-" + item.id.uuidString)
                        .help(RecallLocalization.both("确认这条待办已处理，完成后从待处理列表移除。", "Confirm this action is done and remove it from pending actions."))
                }.buttonStyle(.bordered).controlSize(.small).font(.caption).padding(.top, 2)
                    .textSelection(.disabled).disabled(model.completingSummaryActionIDs.contains(item.id))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func correctionMenu(_ item: DailySummaryItem) -> some View {
        Menu {
            Button(RecallLocalization.text("不是我说的")) { pendingCorrection = (item, .notMine) }
            Button(RecallLocalization.text("内容不准确")) { pendingCorrection = (item, .inaccurate) }
        } label: { Image(systemName: "ellipsis").foregroundStyle(RecallPalette.secondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(RecallLocalization.text("纠正内容"))
            .help(RecallLocalization.both("不再把相关记录用于回顾和记忆判断，原始记录仍保留。", "Exclude related records from reviews and memory analysis. Original records are kept."))
    }
    private func itemTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold)).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    @ViewBuilder private func itemStatus(_ item: DailySummaryItem) -> some View {
        if let status = item.knowledge?.status, let label = statusLabel(status) {
            RecallStatusBadge(title: RecallLocalization.text(label), warning: status == "blocked").fixedSize()
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
            Text(RecallLocalization.text("合并为同一个主题")).font(.title2.bold())
            Text(RecallLocalization.text("只合并浏览方式，原始记录、时间和状态都会保留。可以在主题中撤销合并，相关旧回顾需重新生成。"))
                .foregroundStyle(RecallPalette.secondary)
            TextField(RecallLocalization.text("合并后的主题名称"), text: $title).textFieldStyle(.roundedBorder)
            TextField(RecallLocalization.text("筛选主题"), text: $search).textFieldStyle(.roundedBorder)
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
                Spacer(); Button(RecallLocalization.text("取消")) { dismiss() }.disabled(saving)
                Button(RecallLocalization.text("合并主题")) {
                    saving = true
                    Task { if await model.mergeTopics(title: title, members: selected) { dismiss() } else { error = "未能合并，主题或分类可能已经变化。" }; saving = false }
                }.buttonStyle(.borderedProminent).disabled(saving || selected.count < 2 || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 640, height: 560).interactiveDismissDisabled(saving)
    }
}

/// Marks code-like tokens (snake_case names, ALL-CAPS markers, hex ids) inside
/// review prose so they are scannable. It only changes rendering; the stored
/// text and the copied text keep their original form.
@MainActor
enum ReviewTextHighlight {
    private static let regex = try? NSRegularExpression(
        pattern: #"\b[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+\b|\b[A-Z]{2,}\b|\b[0-9a-f]{7,40}\b"#
    )

    static func attributed(_ text: String) -> AttributedString {
        guard let regex, !text.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        let full = NSRange(location: 0, length: (text as NSString).length)
        for match in regex.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text), range.lowerBound >= cursor else { continue }
            result.append(AttributedString(String(text[cursor..<range.lowerBound])))
            var token = AttributedString(String(text[range]))
            token.font = .system(size: 14, weight: .medium, design: .monospaced)
            token.backgroundColor = RecallPalette.border.opacity(0.45)
            result.append(token)
            cursor = range.upperBound
        }
        result.append(AttributedString(String(text[cursor..<text.endIndex])))
        return result
    }
}

