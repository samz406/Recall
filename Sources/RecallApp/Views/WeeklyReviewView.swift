import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RecallKit

/// Lives inside the workspace's single clipped scroll area; no floating title/overlay.
struct WeeklyReviewView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var template = ReviewTemplate(kind: .personal)
    @State private var periodKind: ReviewPeriodKind = .recentSeven
    @State private var rangeNow = Date.now
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var customEnd = Date.now
    @State private var scope = ReviewScope()
    @State private var selectedID: UUID?
    @State private var historyCount = 8
    @State private var showsComposer = true
    @State private var showsTemplates = false
    @State private var showsSchedules = false
    @State private var editing: WeeklyReport?
    @State private var exporting: WeeklyReport?
    @State private var sourceItem: ReviewItem?
    @State private var deleting: WeeklyReport?
    @State private var materials: WeeklyReport?
    var scrollToReport: () -> Void = {}

    private var period: ReviewPeriod {
        if periodKind != .custom { return .make(periodKind, at: rangeNow) }
        let c = Calendar.current
        let end = min(rangeNow, c.date(byAdding: .day, value: 1, to: c.startOfDay(for: customEnd)) ?? customEnd)
        return ReviewPeriod(start: c.startOfDay(for: customStart), end: end)
    }
    private var report: WeeklyReport? {
        model.state.weeklyReports.first { $0.id == selectedID } ?? model.state.weeklyReports.first(where: \.isReadable) ?? model.state.weeklyReports.first
    }
    private var allTemplates: [ReviewTemplate] { ReviewTemplate.builtIns + model.state.reviewTemplates }
    var body: some View {
        let range = period
        let preview = model.reviewIndex.preview(in: range, kind: template.kind, scope: scope)
        VStack(alignment: .leading, spacing: 24) {
            introduction
            if model.state.weeklyReports.isEmpty { composer(range: range, preview: preview) }
            else { DisclosureGroup("生成另一份回顾", isExpanded: $showsComposer) { composer(range: range, preview: preview).padding(.top, 16) } }
            if let message = model.weeklyReviewMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let task = model.tasks.first(where: { $0.kind == "周期回顾" }) {
                RecallTaskStatusView(task: task, cancel: model.cancelWeeklyReview)
            }
            if let report { reportBody(report).id("weekly-report") }
            else if !model.isGeneratingWeeklyReview { emptyState }
            history
        }
        .onAppear {
            rangeNow = .now
            scope = ReviewScope()
            showsComposer = model.state.weeklyReports.isEmpty
            if let id = model.reviewTopicToOpen { openTopicReview(id) }
            if let id = model.weeklyReportToOpen { selectedID = id }
        }
        .onChange(of: model.reviewTopicToOpen) { _, id in
            if let id { openTopicReview(id) }
        }
        .onChange(of: selectedID) { _, id in if let id { model.weeklyReportToOpen = id } }
        .onChange(of: customStart) { _, start in if customEnd < start { customEnd = start } }
        .onChange(of: model.memoryWorkspace?.revision) { _, _ in rangeNow = .now }
        .onChange(of: model.weeklyReportToOpen) { _, id in
            selectedID = id
            if id != nil { showsComposer = false; DispatchQueue.main.async { scrollToReport() } }
        }
        .sheet(isPresented: $showsTemplates) { ReviewTemplateSheet(template: template) { saved in template = saved }.environmentObject(model) }
        .sheet(isPresented: $showsSchedules) { ReviewSchedulesSheet(template: template, scope: scope).environmentObject(model) }
        .sheet(item: $materials) { ReviewMaterialsSheet(reportID: $0.id).environmentObject(model) }
        .sheet(item: $editing) { ReviewEditSheet(reportID: $0.id).environmentObject(model) }
        .sheet(item: $exporting) { ReviewExportSheet(reportID: $0.id).environmentObject(model) }
        .sheet(item: $sourceItem) { ReviewSourcesSheet(item: $0, reportID: report?.id).environmentObject(model) }
        .alert("删除这份回顾？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除回顾", role: .destructive) {
                if let id = deleting?.id { Task { await model.deleteWeeklyReport(id) } }
                deleting = nil
            }
        } message: { Text("原始记录会保留。这份回顾会进入最近删除，七天内可以恢复。") }
    }

    private func openTopicReview(_ id: String) {
        scope = ReviewScope(topicIDs: [id])
        let category = model.reviewIndex.topics.first { $0.id == id }?.category
        template = ReviewTemplate(kind: category == .work ? .project : (category == .learning ? .learning : .personal))
        showsComposer = true
        // Consume navigation intent: revisiting the ordinary tab must not inherit it.
        model.reviewTopicToOpen = nil
    }
    private var introduction: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) { introductionText; Spacer(); utilityActions }
            VStack(alignment: .leading, spacing: 16) { introductionText; utilityActions }
        }
    }
    private var introductionText: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("把一段时间，整理成一份回顾。").font(.title2.weight(.semibold))
            Text("按周、按月或选择日期，找回值得记住的变化。")
                .foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var utilityActions: some View {
        HStack(spacing: 14) {
            Button { showsTemplates = true } label: { Label("调整输出格式", systemImage: "slider.horizontal.3") }
            Button { showsSchedules = true } label: {
                Label(model.state.reviewSchedules.contains(where: \.isEnabled) ? "定时已开启" : "定时生成", systemImage: "clock")
            }
        }.fixedSize()
    }
    private func composer(range: ReviewPeriod, preview: ReviewRangePreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 20) {
                    templateControl.frame(width: 220)
                    rangeControl.frame(width: 200)
                    Spacer(minLength: 20)
                    generateButton(range: range, eligibleTopicCount: preview.eligibleTopicCount)
                }
                VStack(alignment: .leading, spacing: 18) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) { templateControl; rangeControl }
                        VStack(alignment: .leading, spacing: 16) { templateControl; rangeControl }
                    }
                    HStack {
                        Spacer(minLength: 0)
                        generateButton(range: range, eligibleTopicCount: preview.eligibleTopicCount)
                    }
                }
            }
            if periodKind == .custom {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { customStartControl; customEndControl; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 14) { customStartControl; customEndControl }
                }
            }
            if scope.useSelectedTopics {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label("回顾这件事：" + (model.reviewIndex.topics.first { scope.topicIDs.contains($0.id) }?.title ?? "指定事项"), systemImage: "text.book.closed")
                        .font(.callout).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("回顾全部内容") { scope = ReviewScope(); model.reviewTopicToOpen = nil }.fixedSize()
                }
            }
            // Only explain a blocked action; ordinary generation has no diagnostic/configuration panel.
            if !range.isValid {
                Text("请选择不超过 31 天的有效日期范围。")
                    .font(.caption).foregroundStyle(RecallPalette.warning)
            } else if !model.isBuildingMatters && preview.eligibleTopicCount == 0 {
                Text(template.kind.requiresWorkScope && preview.topicCount > 0
                     ? "这段时间暂未找到可回顾的工作内容，可以换个模板或日期。"
                     : "这段时间暂无可回顾的内容，可以换个日期。")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).reviewSurface()
    }

    private var templateControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("回顾模板").font(.caption).foregroundStyle(RecallPalette.secondary)
            Menu {
                ForEach(allTemplates) { option in
                    Button { template = option } label: {
                        if template.id == option.id { Label(option.name, systemImage: "checkmark") }
                        else { Text(option.name) }
                    }
                }
            } label: { selectionLabel(template.name, symbol: template.kind.symbol) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("回顾模板").accessibilityValue(template.name)
                .help(template.name)
        }
    }
    private var rangeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("时间范围").font(.caption).foregroundStyle(RecallPalette.secondary)
            Menu {
                ForEach(ReviewPeriodKind.allCases) { option in
                    Button { periodKind = option; rangeNow = .now } label: {
                        if periodKind == option { Label(option.title, systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                }
            } label: { selectionLabel(periodKind.title, symbol: "calendar") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("时间范围").accessibilityValue(periodKind.title)
        }
    }
    private func selectionLabel(_ text: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(RecallPalette.secondary)
            Text(text).font(.system(size: 15, weight: .medium)).lineLimit(1)
            Spacer(minLength: 10)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(RecallPalette.secondary)
        }
        .foregroundStyle(RecallPalette.text).padding(.horizontal, 13)
        .frame(minWidth: 160, maxWidth: .infinity, minHeight: 44)
        .background(RecallPalette.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RecallPalette.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    private var customStartControl: some View {
        DatePicker("开始日期", selection: $customStart, in: ...Date.now, displayedComponents: .date)
            .controlSize(.regular).fixedSize()
    }
    private var customEndControl: some View {
        DatePicker("结束日期", selection: $customEnd, in: customStart...max(customStart, Date.now), displayedComponents: .date)
            .controlSize(.regular).fixedSize()
    }
    private func generateButton(range: ReviewPeriod, eligibleTopicCount: Int) -> some View {
        Button {
            model.generateWeeklyReview(period: range, template: template, scope: scope)
        } label: {
            Label("生成回顾", systemImage: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 8).frame(minHeight: 30)
        }
            .buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: 44).fixedSize()
            .disabled(model.isGeneratingWeeklyReview || model.isBuildingMatters || !range.isValid || eligibleTopicCount == 0)
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "book.closed").font(.system(size: 30, weight: .light)).foregroundStyle(RecallPalette.accent)
            Text("你的第一份回顾，从这里开始").font(.title3.weight(.semibold))
            Text("选一个用途和时间范围，Recall 会回看本人事项与保存的内容。记录线索会单独标明，不会被写成你完成的工作、形成的偏好或已经学会的技能。")
                .foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(32).frame(maxWidth: .infinity, alignment: .leading).reviewSurface()
    }

    private func reportBody(_ report: WeeklyReport) -> some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { reportHeading(report); Spacer(); reportActions(report) }
                VStack(alignment: .leading, spacing: 16) { reportHeading(report); reportActions(report) }
            }
            Divider()
            if report.isReadable, let notice = report.modelCoverage?.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(RecallPalette.secondary)
            }
            if !report.isReadable {
                Label("来源已删除、更正或重新分类，旧内容已移除。更新后可重新阅读。", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(RecallPalette.secondary)
            } else if let edited = report.editedMarkdown {
                MarkdownDocumentView(markdown: edited).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 17)).lineSpacing(7)
                DisclosureGroup("查看自动整理的小结") { reportSections(report).padding(.top, 18) }
            } else {
                Text(report.overview).font(.system(size: 18, weight: .medium)).lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                reportSections(report)
            }
            if report.isReadable { SummaryFeedbackFooter(target: .period(report)) }
            Text("创建于 \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        }.padding(28).reviewSurface()
    }
    private func reportHeading(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(report.displayName, systemImage: report.template.kind.symbol).font(.title2.weight(.semibold))
            Text(report.period.label).font(.callout.monospacedDigit()).foregroundStyle(RecallPalette.secondary)
            if report.isReadable {
                Text("\(report.digestRows.count) 项重点 · 涵盖 \(report.coveredDayCount) 个记录日" + (report.editedMarkdown == nil ? "" : " · 已编辑"))
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
        }
    }
    private func reportActions(_ report: WeeklyReport) -> some View {
        HStack(spacing: 12) {
            Button { editing = report } label: { Label("编辑", systemImage: "pencil") }.disabled(!report.isReadable)
            Button { exporting = report } label: { Label("复制与导出", systemImage: "square.and.arrow.up") }.disabled(!report.isReadable)
            Menu {
                Button("查看本期来源") { materials = report }.disabled(!report.isReadable)
                Divider()
                Button("重新生成（保留原版本）") {
                    model.generateWeeklyReview(period: report.period, template: report.template, scope: report.scope,
                        replacing: nil)
                }.disabled(model.isGeneratingWeeklyReview)
                Button("删除回顾", role: .destructive) { deleting = report }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }.fixedSize()
    }
    private func reportSections(_ report: WeeklyReport) -> some View {
        let rows = report.digestRows
        return LazyVStack(alignment: .leading, spacing: 30) {
            ForEach(report.template.sections) { section in
                let items = rows.filter { $0.item.section == section }
                if !items.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Label(report.heading(section), systemImage: section.symbol)
                            .font(.headline).foregroundStyle(sectionColor(section))
                        ForEach(items) { row in reviewItem(row, report: report) }
                    }
                }
            }
        }
    }
    private func reviewItem(_ row: ReviewDigestRow, report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.title).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !row.summary.isEmpty { Text(row.summary).fixedSize(horizontal: false, vertical: true) }
            if let action = row.action {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已明确的后续安排").font(.caption).foregroundStyle(RecallPalette.secondary)
                    Text(action).fixedSize(horizontal: false, vertical: true)
                    Button("设为提醒") { model.prepareReminder(title: action, detail: row.title, sourceIDs: row.item.nextActionSourceIDs) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
            }
        }.font(.system(size: 17)).lineSpacing(6).textSelection(.enabled).padding(.leading, 2)
            .contextMenu {
                Button("反馈这条内容") { model.summaryFeedbackTarget = .period(report, item: row.item) }
                Button("查看这条内容的来源") { sourceItem = row.item }
            }
    }
    private func stamp(_ date: Date, report: WeeklyReport) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = report.period.calendar.timeZone; formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
    private func sectionColor(_ section: ReviewSection) -> Color {
        switch section { case .progress: RecallPalette.accent; case .open: RecallPalette.warning; case .plans: RecallPalette.accent; case .notes: RecallPalette.accent }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("已保存的回顾").font(.headline); Spacer(); Text("\(model.state.weeklyReports.count) 份").foregroundStyle(RecallPalette.secondary) }
            if model.state.weeklyReports.isEmpty {
                Text("生成后会保存在这里，之后可以随时回看或调整。").font(.callout).foregroundStyle(RecallPalette.secondary)
            }
            ForEach(Array(model.state.weeklyReports.prefix(historyCount))) { report in
                Button { selectedID = report.id; DispatchQueue.main.async { scrollToReport() } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: report.template.kind.symbol).foregroundStyle(RecallPalette.accent)
                            .frame(width: 38, height: 38).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(report.displayName).font(.headline).foregroundStyle(RecallPalette.text)
                            Text(report.period.label).font(.caption.monospacedDigit()).foregroundStyle(RecallPalette.secondary)
                        }
                        Spacer()
                        Text(report.isReadable ? (report.editedMarkdown == nil ? "已保存" : "已编辑") : "待更新")
                            .font(.caption).foregroundStyle(RecallPalette.secondary)
                        Image(systemName: report.id == self.report?.id ? "checkmark.circle.fill" : "chevron.right")
                            .foregroundStyle(report.id == self.report?.id ? RecallPalette.accent : RecallPalette.secondary)
                    }.padding(16).reviewSurface()
                }.buttonStyle(.plain)
            }
            if model.state.weeklyReports.count > historyCount { Button("再显示 8 份") { historyCount += 8 } }
        }
    }
}

private extension View {
    func reviewSurface() -> some View {
        background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(RecallPalette.text.opacity(0.075), lineWidth: 1))
    }
}

private struct ReviewTemplateSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @State var template: ReviewTemplate
    let selected: (ReviewTemplate) -> Void
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("调整输出格式").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("当前模板：\(template.kind.title)。这里仅调整栏目名称、顺序、篇幅和表达，不改变你选择的日期范围。没有依据的栏目会省略。")
                .foregroundStyle(RecallPalette.secondary)
            TextField("模板名称", text: $template.name).textFieldStyle(.roundedBorder)
            HStack {
                Picker("篇幅", selection: $template.length) { ForEach(ReviewLength.allCases) { Text($0.title).tag($0) } }
                Picker("表达", selection: $template.tone) { ForEach(ReviewTone.allCases) { Text($0.title).tag($0) } }
            }
            Text(template.length.explanation).font(.caption).foregroundStyle(RecallPalette.secondary)
            ForEach(Array(template.sections.enumerated()), id: \.element) { index, section in
                HStack {
                    Image(systemName: section.symbol).frame(width: 22).foregroundStyle(RecallPalette.secondary)
                    TextField(template.heading(section), text: Binding(get: { template.heading(section) }, set: { template.headings[section.rawValue] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Button { template.sections.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                    Button { template.sections.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index == template.sections.count - 1)
                }
            }
            if !model.state.reviewTemplates.isEmpty {
                DisclosureGroup("已保存的模板") {
                    ForEach(model.state.reviewTemplates) { value in
                        HStack {
                            Button(value.name) { template = value }
                            Spacer()
                            Button("删除", role: .destructive) { Task { await model.deleteReviewTemplate(value.id) } }
                        }.padding(.vertical, 5)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(RecallPalette.danger).font(.callout) }
            HStack {
                Spacer()
                Button("保存为新模板") { save(copy: true) }.disabled(!template.isValid)
                Button("保存并使用") { save(copy: false) }.buttonStyle(.borderedProminent).disabled(!template.isValid)
            }
        }.padding(28).frame(width: 620)
    }
    private func save(copy: Bool) {
        var value = template
        if copy || ReviewTemplateKind.allCases.contains(where: { $0.rawValue == value.id }) { value.id = UUID().uuidString }
        value.version += 1
        Task {
            if await model.saveReviewTemplate(value) { selected(value); dismiss() }
            else { error = "未能保存模板，请重试。" }
        }
    }
}

private struct ReviewEditSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let reportID: UUID
    @State private var markdown = ""
    @State private var error: String?
    @State private var isSaving = false
    private var report: WeeklyReport? { model.state.weeklyReports.first { $0.id == reportID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("调整这份回顾").font(.title2.bold())
            Text("可以补充遗漏、调整措辞。修改会单独保存，原始依据仍然保留。") .foregroundStyle(RecallPalette.secondary)
            TextEditor(text: $markdown).font(.system(size: 17)).scrollContentBackground(.hidden).padding(12)
                .background(RecallPalette.surface)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecallPalette.secondary.opacity(0.2)))
            if let error { Text(error).foregroundStyle(RecallPalette.danger).font(.callout) }
            HStack {
                Button("还原为原始整理") { save(nil) }.disabled(report?.editedMarkdown == nil || isSaving)
                Spacer()
                Button("取消") { dismiss() }.disabled(isSaving)
                Button("保存修改") { save(markdown) }.buttonStyle(.borderedProminent)
                    .disabled(isSaving || markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || markdown.count > 60_000 || report?.isReadable != true)
            }
        }.padding(28).frame(width: 740, height: 610)
            .onAppear { markdown = report?.markdown ?? "" }.interactiveDismissDisabled(isSaving)
    }
    private func save(_ value: String?) {
        isSaving = true
        Task {
            if await model.editWeeklyReport(reportID, markdown: value) { dismiss() }
            else { error = "来源可能已变化，未能保存。请关闭后更新回顾。" }
            isSaving = false
        }
    }
}

private struct ReviewExportSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let reportID: UUID
    @State private var message: String?
    private var report: WeeklyReport? { model.state.weeklyReports.first { $0.id == reportID && $0.isReadable } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("复制与导出").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("下方就是将要输出的完整内容，可以先核对再用于工作汇报或分享。") .foregroundStyle(RecallPalette.secondary)
            ScrollView {
                MarkdownDocumentView(markdown: report?.markdown ?? "来源已变化，请重新生成。").textSelection(.enabled)
                    .font(.system(size: 16)).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.reviewSurface().clipped()
            if let message { Text(message).font(.callout).foregroundStyle(RecallPalette.secondary) }
            HStack {
                Spacer()
                Button("复制文字") {
                    Task {
                        if let content = await model.weeklyMarkdownForExport(reportID) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content, forType: .string)
                            message = "已复制。"
                        } else { message = "来源已变化，未能复制。请先更新回顾。" }
                    }
                }.disabled(report == nil)
                Button("导出 Markdown") { export() }.buttonStyle(.borderedProminent).disabled(report == nil)
            }
        }.padding(28).frame(width: 740, height: 620)
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Recall-" + (report?.displayName ?? "回顾") + ".md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let content = await model.weeklyMarkdownForExport(reportID) else { message = "来源已变化，请先更新回顾。"; return }
                do { try content.write(to: url, atomically: true, encoding: .utf8); message = "文件已导出。" }
                catch { model.logWeeklyExportFailure(error); message = "导出失败，请换一个位置重试。" }
            }
        }
    }
}

/// Materials are deliberately outside the report body and paginated. They are not summaries.
private struct ReviewMaterialsSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let reportID: UUID
    @State private var query = ""
    @State private var limit = 20
    @State private var selected: ReviewItem?
    private var report: WeeklyReport? { model.state.weeklyReports.first { $0.id == reportID && $0.isReadable } }
    var body: some View {
        let rows = report?.items.filter { $0.memberTopicIDs == nil && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) } ?? []
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("本期整理依据").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("这里保留本期的候选材料与完整过程，包含未进入回顾正文的零碎记录；材料标题不代表已确认的真实事项。")
                .foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("搜索材料标题", text: $query).textFieldStyle(.roundedBorder)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if report == nil { Text("来源已删除或更正，请更新回顾后再查看。") }
                    else if rows.isEmpty { Text("没有匹配的材料。") }
                    ForEach(Array(rows.prefix(limit))) { item in
                        Button { selected = item } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.headline).lineLimit(2)
                                Text("\(item.sourceIDs.count) 条来源 · 查看完整过程").font(.caption).foregroundStyle(RecallPalette.secondary)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).reviewSurface()
                        }.buttonStyle(.plain)
                    }
                    if rows.count > limit { Button("再显示 20 组材料") { limit += 20 } }
                }
            }.clipped()
        }.padding(28).frame(width: 720, height: 600)
            .onChange(of: query) { _, _ in limit = 20 }
            .sheet(item: $selected) { ReviewSourcesSheet(item: $0, reportID: reportID).environmentObject(model) }
    }
}

private struct ReviewSourcesSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let item: ReviewItem
    let reportID: UUID?
    @State private var source: CaptureRecord?
    private var current: Bool {
        guard let report = model.state.weeklyReports.first(where: { $0.id == reportID && $0.isReadable }),
              report.items.contains(where: { $0.id == item.id }) else { return false }
        return WeeklyReviewEngine.sourcesUnchanged(report, in: model.state)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(current ? item.title : "依据已变化").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("回看原始记录，核对发生时间、归属与前后变化。") .foregroundStyle(RecallPalette.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if !current { Text("来源已删除或更正，请关闭后更新回顾。").foregroundStyle(RecallPalette.secondary) }
                    else {
                        ForEach((item.previous.map { [$0] } ?? []) + item.excerpts) { entry in
                            VStack(alignment: .leading, spacing: 10) {
                                Text((entry.eventTimeKnown == true ? "发生于 " : "记录于 ") + entry.date.formatted()).font(.caption).foregroundStyle(RecallPalette.secondary)
                                Text(entry.text).textSelection(.enabled)
                                ForEach(model.state.captures.filter { entry.sourceIDs.contains($0.id) }) { capture in
                                    Button("在时间线定位 · " + (capture.sourceAppName ?? "已保存记录")) { dismiss(); model.destination = .record(capture.id) }
                                }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).reviewSurface()
                        }
                        if let action = item.nextAction {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("记录中的后续安排").font(.caption).foregroundStyle(RecallPalette.secondary)
                                Text(action).textSelection(.enabled)
                                ForEach(model.state.captures.filter { item.nextActionSourceIDs.contains($0.id) }) { capture in
                                    Button("在时间线定位 · " + (capture.sourceAppName ?? "已保存记录")) { dismiss(); model.destination = .record(capture.id) }
                                }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).reviewSurface()
                        }
                    }
                }
            }.clipped()
        }.padding(28).frame(width: 700, height: 590)
            .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
    }
}

private struct ReviewSchedulesSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let template: ReviewTemplate
    let scope: ReviewScope
    @State private var editing: ReviewSchedule?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("定时生成回顾").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("为不同用途分别设置时间和范围。应用关闭时，将在下次启动后补生成最近一次回顾。")
                .foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.state.reviewSchedules.isEmpty {
                        Text("例如，周五下班前整理工作，周日晚上回看生活。计划默认使用本地记录整理，不会新增采集。") .foregroundStyle(RecallPalette.secondary)
                    }
                    ForEach(model.state.reviewSchedules) { value in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(value.name).font(.headline)
                                Spacer()
                                Toggle("开启", isOn: Binding(get: { value.isEnabled }, set: { enabled in
                                    var updated = value; updated.isEnabled = enabled
                                    Task { _ = await model.saveReviewSchedule(updated) }
                                })).labelsHidden()
                            }
                            Text((value.monthDay.map { "每月 \($0) 日" } ?? "每\(weekday(value.weekday))") + " \(String(format: "%02d:%02d", value.hour, value.minute)) · \(value.template.name)")
                            Text(value.timeZoneIdentifier + " · " + value.periodKind.title).font(.caption).foregroundStyle(RecallPalette.secondary)
                            if value.scope.useSelectedTopics {
                                Text("仅回顾指定事项；可编辑计划改为整个日期范围。")
                                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                            }
                            if value.failureCount > 0 { Text("模型或保存暂未完成，将自动重试；已有的本地版本可以阅读。") .font(.caption).foregroundStyle(RecallPalette.warning) }
                            else if value.isEnabled, let next = value.nextRunAt { Text("下次生成：" + next.formatted()).font(.caption).foregroundStyle(RecallPalette.secondary) }
                            HStack {
                                Button("编辑计划") { editing = value }
                                Spacer()
                                Button("删除计划", role: .destructive) { Task { await model.deleteReviewSchedule(value.id) } }
                            }
                        }.padding(18).reviewSurface()
                    }
                }
            }.clipped()
            HStack { Spacer(); Button("新建生成计划") { editing = ReviewSchedule(template: template, scope: scope) }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 680, height: 580)
            .sheet(item: $editing) { ReviewScheduleEditor(schedule: $0).environmentObject(model) }
    }
    private func weekday(_ value: Int) -> String { ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"][min(max(value, 1), 7)] }
}

private struct ReviewScheduleEditor: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @State var schedule: ReviewSchedule
    @State private var showsAdvanced = false
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("安排一份定时回顾").font(.title2.bold())
            TextField("计划名称", text: $schedule.name).textFieldStyle(.roundedBorder)
            Picker("使用模板", selection: Binding(get: { schedule.template.id }, set: { id in
                if let value = (ReviewTemplate.builtIns + model.state.reviewTemplates).first(where: { $0.id == id }) { schedule.template = value }
            })) {
                ForEach(ReviewTemplate.builtIns + model.state.reviewTemplates) { Text($0.name).tag($0.id) }
            }
            Picker("重复周期", selection: Binding(get: { schedule.monthDay != nil }, set: { schedule.monthDay = $0 ? 1 : nil })) {
                Text("每周").tag(false); Text("每月").tag(true)
            }.pickerStyle(.segmented)
            HStack {
                if schedule.monthDay != nil {
                    Stepper("每月 \(schedule.monthDay ?? 1) 日", value: Binding(get: { schedule.monthDay ?? 1 }, set: { schedule.monthDay = $0 }), in: 1...28)
                } else {
                Picker("生成时间", selection: $schedule.weekday) {
                    Text("周一").tag(2); Text("周二").tag(3); Text("周三").tag(4); Text("周四").tag(5)
                    Text("周五").tag(6); Text("周六").tag(7); Text("周日").tag(1)
                }
                }
                DatePicker("时刻", selection: Binding(get: {
                    schedule.calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: .now) ?? .now
                }, set: { date in
                    schedule.hour = schedule.calendar.component(.hour, from: date)
                    schedule.minute = schedule.calendar.component(.minute, from: date)
                }), displayedComponents: .hourAndMinute).labelsHidden().environment(\.timeZone, schedule.calendar.timeZone)
            }
            Picker("回顾范围", selection: $schedule.periodKind) {
                ForEach(ReviewPeriodKind.allCases.filter { $0 != .custom }) { Text($0.title).tag($0) }
            }
            if schedule.scope.useSelectedTopics {
                HStack {
                    Label("此计划仅回顾指定事项", systemImage: "text.book.closed")
                    Spacer()
                    Button("改为整个日期范围") { schedule.scope = ReviewScope() }
                }.font(.callout)
            } else {
                Text("按所选日期范围自动整理，模板决定内容用途和输出格式。")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            DisclosureGroup("时区") {
                TextField("例如 Asia/Shanghai", text: $schedule.timeZoneIdentifier).textFieldStyle(.roundedBorder)
            }
            Text("使用 \(schedule.timeZoneIdentifier) 时区。选择‘本周’时，只总结到计划生成时刻；需要完整周一至周日，可在周一生成‘上一个完整周’。")
                .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            Text("回顾由已连接的模型生成。生成前会先补齐这段时间的记录理解；模型不可用时保留原回顾，稍后重试。")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            Toggle("生成后发送系统通知", isOn: $schedule.notifyWhenReady)
            Text("支持暂停或删除计划；失败会记录日志并重试，不自动发送周报或创建提醒。")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            if let error { Text(error).foregroundStyle(RecallPalette.danger).font(.callout) }
            HStack {
                Spacer(); Button("取消") { dismiss() }.disabled(saving)
                Button(saving ? "保存中…" : "保存计划") {
                    saving = true
                    Task {
                        schedule.useModel = true
                        if await model.saveReviewSchedule(schedule) { dismiss() }
                        else { error = "保存失败，请检查时间与模板设置后重试。" }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(!schedule.isValid || saving)
            }
        }.padding(28).frame(width: 620).interactiveDismissDisabled(saving)
    }
}
