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
    @State private var useModel = false
    @State private var initializedModelChoice = false
    @State private var selectedID: UUID?
    @State private var historyCount = 8
    @State private var showsComposer = true
    @State private var showsScope = false
    @State private var showsAdvanced = false
    @State private var showsTemplates = false
    @State private var showsSchedules = false
    @State private var editing: WeeklyReport?
    @State private var exporting: WeeklyReport?
    @State private var sourceItem: ReviewItem?
    @State private var deleting: WeeklyReport?
    var scrollToReport: () -> Void = {}

    private var period: ReviewPeriod {
        if periodKind != .custom { return .make(periodKind, at: rangeNow) }
        let c = Calendar.current
        let end = min(rangeNow, c.date(byAdding: .day, value: 1, to: c.startOfDay(for: customEnd)) ?? customEnd)
        return ReviewPeriod(start: c.startOfDay(for: customStart), end: end)
    }
    private var report: WeeklyReport? {
        model.state.weeklyReports.first { $0.id == selectedID } ?? model.state.weeklyReports.first
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
            showsComposer = model.state.weeklyReports.isEmpty
            if let id = model.weeklyReportToOpen { selectedID = id }
            if !initializedModelChoice {
                useModel = model.state.privacy.cloudUseEnabled
                    && model.state.llmConfiguration.provider != .localOnly
                    && !model.state.llmConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                initializedModelChoice = true
            }
        }
        .onChange(of: customStart) { _, start in if customEnd < start { customEnd = start } }
        .onChange(of: model.memoryWorkspace?.revision) { _, _ in rangeNow = .now }
        .onChange(of: model.weeklyReportToOpen) { _, id in
            selectedID = id
            if id != nil { showsComposer = false; DispatchQueue.main.async { scrollToReport() } }
        }
        .sheet(isPresented: $showsScope) { ReviewScopeSheet(kind: template.kind, period: period, scope: $scope).environmentObject(model) }
        .sheet(isPresented: $showsTemplates) { ReviewTemplateSheet(template: template) { saved in template = saved }.environmentObject(model) }
        .sheet(isPresented: $showsSchedules) { ReviewSchedulesSheet(template: template, scope: scope).environmentObject(model) }
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
        let coverage = preview.coverage
        let eligibleTopicCount = preview.eligibleTopicCount
        return VStack(alignment: .leading, spacing: 20) {
            Picker("模板", selection: Binding(get: { template.id }, set: { id in
                if let value = allTemplates.first(where: { $0.id == id }) { template = value }
            })) {
                ForEach(allTemplates) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 340)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) { rangeControls; Spacer(); generateButton(range: range, eligibleTopicCount: eligibleTopicCount) }
                VStack(alignment: .leading, spacing: 16) { rangeControls; generateButton(range: range, eligibleTopicCount: eligibleTopicCount) }
            }
            if periodKind == .custom {
                HStack(spacing: 20) {
                    DatePicker("开始", selection: $customStart, in: ...Date.now, displayedComponents: .date)
                    DatePicker("结束", selection: $customEnd, in: customStart...max(customStart, Date.now), displayedComponents: .date)
                }
            }
            DisclosureGroup("更多选项与范围说明", isExpanded: $showsAdvanced) {
            Button("筛选主题") { showsScope = true }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar").foregroundStyle(RecallPalette.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(range.label).font(.callout.monospacedDigit())
                    Text("全部 \(coverage.totalRecords) 条记录 · 所选日期 \(coverage.periodRecords) 条（\(coverage.textRecords) 条含文字）")
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                    Text(scope.useSelectedTopics ? "仅回顾所选日期内勾选的主题；模板决定栏目和表达方式。" : "默认回顾所选日期内的全部适用记录，无需逐项选择；模板决定栏目和表达方式。")
                        .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
                    if template.kind.requiresWorkScope {
                        Text("工作回顾只采用工作分类或你明确选中的未分类主题，生活与学习内容会被排除。")
                            .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            if model.isBuildingMatters {
                Text("正在检查范围内的记录…").font(.caption).foregroundStyle(RecallPalette.secondary)
            } else if eligibleTopicCount > 0 {
                Label("将整理 \(eligibleTopicCount) 个主题，生成后可查看每条依据。", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            } else if template.kind.requiresWorkScope && preview.topicCount > 0 && !scope.useSelectedTopics {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这个范围内还没有标为工作的主题。可主动选入未分类主题，或用‘我的一周’回顾全部内容。")
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                    Button("筛选工作主题") { showsScope = true }
                }
            } else if coverage.periodRecords == 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("所选日期内没有保存的记录；总记录数包含其他日期。")
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                    if let latest = coverage.latestRecordAt, latest <= .now {
                        Text("最近记录于 " + latest.formatted()).font(.caption).foregroundStyle(RecallPalette.secondary)
                        Button("查看最近有记录的一周") {
                            customStart = Calendar.current.date(byAdding: .day, value: -6, to: latest) ?? latest
                            customEnd = latest; periodKind = .custom
                        }
                    }
                }
            } else {
                Text(scope.useSelectedTopics ? "所选主题在这个日期范围内没有适用记录，可关闭主题筛选。" :
                    (coverage.textRecords == 0 ? "这些记录没有可读取的文字。请在时间线核对是否只有截图或文字识别未成功。" : "这些记录暂未形成可回顾的正文。可在‘长期记忆 → 保存的资料与线索’查看整理结果，并在时间线核对原始文字。"))
                    .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("使用已连接的模型整理正文", isOn: $useModel)
                .font(.callout).disabled(!model.state.privacy.cloudUseEnabled && !useModel)
                .help("仅发送范围内经过脱敏的事实，按用途和篇幅整理正文，再核对来源；未通过的条目保留原始记录。关闭时完全在本地整理。")
            if !model.state.privacy.cloudUseEnabled {
                Text("当前在本地整理；可在“设置”中开启模型文本使用。")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
        }
        }.padding(24).reviewSurface()
    }
    private func templateButton(_ kind: ReviewTemplateKind) -> some View {
        let selected = template.kind == kind
        return Button {
            template = ReviewTemplate(kind: kind)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: kind.symbol).font(.title3).foregroundStyle(selected ? RecallPalette.accent : RecallPalette.secondary)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(RecallPalette.accent) }
                }
                Text(kind.title).font(.headline).foregroundStyle(RecallPalette.text)
                Text(kind.subtitle).font(.caption).foregroundStyle(RecallPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
                .background(selected ? RecallPalette.selected : RecallPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? RecallPalette.accent.opacity(0.5) : RecallPalette.border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var rangeControls: some View {
        HStack(spacing: 14) {
            Picker("时间范围", selection: $periodKind) {
                ForEach(ReviewPeriodKind.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(maxWidth: 200)
            Button { showsScope = true } label: {
                Label(scope.useSelectedTopics ? "仅选中主题（\(scope.topicIDs.count)）" : "筛选主题（可选）", systemImage: "line.3.horizontal.decrease")
            }
        }
    }
    private func generateButton(range: ReviewPeriod, eligibleTopicCount: Int) -> some View {
        Button {
            model.generateWeeklyReview(period: range, template: template, scope: scope, useModel: useModel)
        } label: { Label("生成回顾", systemImage: "sparkles").padding(.vertical, 4).padding(.horizontal, 6) }
            .buttonStyle(.borderedProminent)
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
            if !report.isReadable {
                Label("来源已删除、更正或重新分类，旧内容已移除。更新后可重新阅读。", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(RecallPalette.secondary)
            } else if let edited = report.editedMarkdown {
                MarkdownDocumentView(markdown: edited).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 17)).lineSpacing(7)
                Text("已保留你的修改。每条原始依据仍可从下方查看。")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                DisclosureGroup("查看原始整理与依据") { reportSections(report).padding(.top, 18) }
            } else {
                Text(report.overview).font(.system(size: 18, weight: .medium)).lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                reportSections(report)
            }
            Text("保存于 \(report.createdAt.formatted()) · \(report.modelAssisted ? "模型整理与来源核对" : "本地事实整理")")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            if report.refinementPending {
                Text(report.canRefine(at: .now) && report.scheduleID != nil
                     ? "部分条目保留原始记录，将在一天内有限重试；不会影响下一期回顾。"
                     : "部分条目保留原始记录，你可以使用模型重新整理。")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
        }.padding(28).reviewSurface()
    }
    private func reportHeading(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(report.displayName, systemImage: report.template.kind.symbol).font(.title2.weight(.semibold))
            Text(report.period.label).font(.callout.monospacedDigit()).foregroundStyle(RecallPalette.secondary)
            if report.isReadable {
                let days = Set(report.items.flatMap(\.excerpts).map { report.period.calendar.startOfDay(for: $0.date) }).count
                Text("\(report.items.count) 个主题 · 涵盖 \(days) 个记录日" + (report.editedMarkdown == nil ? "" : " · 已编辑"))
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
        }
    }
    private func reportActions(_ report: WeeklyReport) -> some View {
        HStack(spacing: 12) {
            Button { editing = report } label: { Label("编辑", systemImage: "pencil") }.disabled(!report.isReadable)
            Button { exporting = report } label: { Label("复制与导出", systemImage: "square.and.arrow.up") }.disabled(!report.isReadable)
            Menu {
                Button("重新生成（保留原版本）") {
                    model.generateWeeklyReview(period: report.period, template: report.template, scope: report.scope,
                        useModel: useModel || (model.state.privacy.cloudUseEnabled && (report.modelAssisted || report.refinementPending)), replacing: nil)
                }.disabled(model.isGeneratingWeeklyReview)
                Button("删除回顾", role: .destructive) { deleting = report }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }.fixedSize()
    }
    private func reportSections(_ report: WeeklyReport) -> some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            ForEach(report.template.sections) { section in
                let items = report.items.filter { $0.section == section }
                if !items.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Label(report.heading(section), systemImage: section.symbol)
                            .font(.headline).foregroundStyle(sectionColor(section))
                        ForEach(items) { item in reviewItem(item, report: report) }
                    }
                }
            }
        }
    }
    private func reviewItem(_ item: ReviewItem, report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.displayTitle).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let narrative = item.narrative {
                Text(narrative.summary).fixedSize(horizontal: false, vertical: true)
            }
            if item.narrative == nil || report.template.length == .detailed {
                if let previous = item.previous {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("此前 · " + (previous.eventTimeKnown == true ? "发生于 " : "记录于 ") + stamp(previous.date, report: report)).font(.caption).foregroundStyle(RecallPalette.secondary)
                        Text(previous.text).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(item.featured(for: report.template.length)) { excerpt in
                    VStack(alignment: .leading, spacing: 6) {
                        Text((excerpt.eventTimeKnown == true ? "发生于 " : "记录于 ") + stamp(excerpt.date, report: report)).font(.caption).foregroundStyle(RecallPalette.secondary)
                        Text(excerpt.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let action = item.nextAction {
                Button("设为提醒") { model.prepareReminder(title: action, detail: item.title, sourceIDs: item.nextActionSourceIDs) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("记录中的后续安排").font(.caption).foregroundStyle(RecallPalette.secondary)
                    Text(action).fixedSize(horizontal: false, vertical: true)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
            }
            Button { sourceItem = item } label: {
                Label("查看依据与完整过程（\(item.sourceIDs.count) 条来源）", systemImage: "link")
                    .font(.caption)
            }.buttonStyle(.link)
        }.font(.system(size: 17)).lineSpacing(6).textSelection(.enabled)
            .padding(.leading, 2)
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

struct ReviewScopeSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let kind: ReviewTemplateKind
    let period: ReviewPeriod?
    @Binding var scope: ReviewScope
    @State private var search = ""
    private var topics: [ReviewTopicSummary] {
        model.reviewIndex.topics.filter { topic in
            (period.map { topic.occurs(in: $0) } ?? true)
                && (search.isEmpty || topic.title.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        let rows = topics
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("筛选回顾主题").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.buttonStyle(.borderedProminent) }
            Text("这是可选筛选。默认按所选日期整理适用记录，只有想缩小内容范围时才需要勾选。")
                .foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            if let period { Text(period.label).font(.caption.monospacedDigit()).foregroundStyle(RecallPalette.secondary) }
            else { Text("定时计划会按每次生成时的日期范围整理。").font(.caption).foregroundStyle(RecallPalette.secondary) }
            Toggle("只整理我选中的主题", isOn: $scope.useSelectedTopics)
            TextField("搜索主题", text: $search).textFieldStyle(.roundedBorder)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if rows.isEmpty { Text("这个日期范围内没有匹配的主题。可以调整日期、清空搜索或补充记录。").foregroundStyle(RecallPalette.secondary) }
                    ForEach(rows) { topic in
                        scopeRow(topic)
                    }
                }.padding(.vertical, 8)
            }.clipped()
            Text(kind.requiresWorkScope ? "标为生活或学习的主题不会进入工作回顾。分类调整会让依赖该主题的旧回顾等待更新。" : "关闭“只整理我选中的主题”后，会恢复整理所选日期内的全部适用记录。")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        }.padding(28).frame(width: 660, height: 590)
    }
    private func scopeRow(_ topic: ReviewTopicSummary) -> some View {
        let category = topic.category
        let excluded = kind.requiresWorkScope && (category == .personal || category == .learning)
        return HStack(spacing: 16) {
            Toggle(isOn: Binding(get: { scope.topicIDs.contains(topic.id) }, set: { selected in
                scope.useSelectedTopics = true
                if selected { scope.topicIDs.insert(topic.id) } else { scope.topicIDs.remove(topic.id) }
            })) { Text(topic.title).fixedSize(horizontal: false, vertical: true) }
                .disabled(excluded)
            Spacer(minLength: 8)
            Picker("分类", selection: Binding(get: { category }, set: { value in
                Task { await model.setReviewCategory(topicID: topic.id, category: value) }
            })) { ForEach(ReviewCategory.allCases) { Text($0.title).tag($0) } }
                .labelsHidden().frame(width: 105)
        }.padding(14).background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
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
            Text("当前模板：\(template.kind.title)。这里仅调整栏目名称、顺序、篇幅和表达，不改变你选择的日期与主题范围。没有依据的栏目会省略。")
                .foregroundStyle(RecallPalette.secondary)
            TextField("模板名称", text: $template.name).textFieldStyle(.roundedBorder)
            HStack {
                Picker("篇幅", selection: $template.length) { ForEach(ReviewLength.allCases) { Text($0.title).tag($0) } }
                Picker("表达", selection: $template.tone) { ForEach(ReviewTone.allCases) { Text($0.title).tag($0) } }
            }
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
        panel.nameFieldStringValue = "Recall-" + (report?.template.kind.title ?? "回顾") + ".md"
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
                            Text("每\(weekday(value.weekday)) \(String(format: "%02d:%02d", value.hour, value.minute)) · \(value.template.name)")
                            Text(value.timeZoneIdentifier + " · " + value.periodKind.title).font(.caption).foregroundStyle(RecallPalette.secondary)
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
    @State private var showsScope = false
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
            Button { showsScope = true } label: {
                Label(schedule.scope.useSelectedTopics ? "已选 \(schedule.scope.topicIDs.count) 个主题" : "设置内容范围", systemImage: "line.3.horizontal.decrease")
            }
            DisclosureGroup("时区") {
                TextField("例如 Asia/Shanghai", text: $schedule.timeZoneIdentifier).textFieldStyle(.roundedBorder)
            }
            Text("使用 \(schedule.timeZoneIdentifier) 时区。选择‘本周’时，只总结到计划生成时刻；需要完整周一至周日，可在周一生成‘上一个完整周’。")
                .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("使用模型按模板整理成文", isOn: $schedule.useModel).disabled(!model.state.privacy.cloudUseEnabled && !schedule.useModel)
            Toggle("生成后发送系统通知", isOn: $schedule.notifyWhenReady)
            Text("支持暂停或删除计划；失败会记录日志并重试，不自动发送周报或创建提醒。")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            if let error { Text(error).foregroundStyle(RecallPalette.danger).font(.callout) }
            HStack {
                Spacer(); Button("取消") { dismiss() }.disabled(saving)
                Button(saving ? "保存中…" : "保存计划") {
                    saving = true
                    Task {
                        if await model.saveReviewSchedule(schedule) { dismiss() }
                        else { error = "保存失败，请检查时间与模板设置后重试。" }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(!schedule.isValid || saving)
            }
        }.padding(28).frame(width: 620).interactiveDismissDisabled(saving)
            .sheet(isPresented: $showsScope) { ReviewScopeSheet(kind: schedule.template.kind, period: nil, scope: $schedule.scope).environmentObject(model) }
    }
}
