import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RecallKit

/// Lives inside the workspace's single clipped scroll area; no floating title/overlay.
struct WeeklyReviewView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var template = ReviewTemplate(kind: .personal)
    @State private var periodKind: ReviewPeriodKind = .recentSeven
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var customEnd = Date.now
    @State private var scope = ReviewScope()
    @State private var useModel = false
    @State private var selectedID: UUID?
    @State private var historyCount = 8
    @State private var showsComposer = true
    @State private var showsScope = false
    @State private var showsTemplates = false
    @State private var showsSchedules = false
    @State private var editing: WeeklyReport?
    @State private var exporting: WeeklyReport?
    @State private var sourceItem: ReviewItem?
    @State private var deleting: WeeklyReport?
    var scrollToReport: () -> Void = {}

    private var period: ReviewPeriod {
        if periodKind != .custom { return .make(periodKind) }
        let c = Calendar.current
        let end = min(Date.now, c.date(byAdding: .day, value: 1, to: c.startOfDay(for: customEnd)) ?? customEnd)
        return ReviewPeriod(start: c.startOfDay(for: customStart), end: end)
    }
    private var report: WeeklyReport? {
        model.state.weeklyReports.first { $0.id == selectedID } ?? model.state.weeklyReports.first
    }
    private var allTemplates: [ReviewTemplate] { ReviewTemplate.builtIns + model.state.reviewTemplates }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            introduction
            if model.state.weeklyReports.isEmpty { composer }
            else { DisclosureGroup("生成另一份回顾", isExpanded: $showsComposer) { composer.padding(.top, 16) } }
            if let message = model.weeklyReviewMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.isGeneratingWeeklyReview {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("正在核对整周记录，整理主题的变化…").foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { model.cancelWeeklyReview() }
                }.padding(22).reviewSurface()
            }
            if let report { reportBody(report).id("weekly-report") }
            else { emptyState }
            history
        }
        .onAppear {
            showsComposer = model.state.weeklyReports.isEmpty
            if let id = model.weeklyReportToOpen { selectedID = id }
        }
        .onChange(of: customStart) { _, start in if customEnd < start { customEnd = start } }
        .onChange(of: model.weeklyReportToOpen) { _, id in
            selectedID = id
            if id != nil { showsComposer = false; DispatchQueue.main.async { scrollToReport() } }
        }
        .sheet(isPresented: $showsScope) { ReviewScopeSheet(kind: template.kind, scope: $scope).environmentObject(model) }
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
            Text("把这一周，整理成一份回顾。").font(.title2.weight(.semibold))
            Text("从已保存的经历中找回变化，按你的用途表达。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var utilityActions: some View {
        HStack(spacing: 14) {
            Button { showsTemplates = true } label: { Label("模板", systemImage: "slider.horizontal.3") }
            Button { showsSchedules = true } label: {
                Label(model.state.reviewSchedules.contains(where: \.isEnabled) ? "定时已开启" : "定时生成", systemImage: "clock")
            }
        }.fixedSize()
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
                ForEach(ReviewTemplateKind.allCases) { kind in
                    templateButton(kind)
                }
            }
            if !model.state.reviewTemplates.isEmpty {
                HStack {
                    Text("我的模板").font(.caption).foregroundStyle(.secondary)
                    Picker("选择保存的模板", selection: Binding(get: { template.id }, set: { id in
                        if let selected = allTemplates.first(where: { $0.id == id }) { template = selected }
                    })) {
                        ForEach(allTemplates) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 240)
                    Spacer()
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) { rangeControls; Spacer(); generateButton }
                VStack(alignment: .leading, spacing: 16) { rangeControls; generateButton }
            }
            if periodKind == .custom {
                HStack(spacing: 20) {
                    DatePicker("开始", selection: $customStart, in: ...Date.now, displayedComponents: .date)
                    DatePicker("结束", selection: $customEnd, in: customStart...max(customStart, Date.now), displayedComponents: .date)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(period.label).font(.callout.monospacedDigit())
                    Text(template.kind.requiresWorkScope ? "只纳入标为工作或本次明确选中的主题，生活与学习分类会被排除。" : "只整理已保存的记录；没有依据的栏目会自然省略。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Toggle("用已连接的模型辅助挑选重点", isOn: $useModel)
                .font(.callout).disabled(!model.state.privacy.cloudUseEnabled)
                .help("仅发送范围内经过脱敏的事实片段；关闭时在本地整理。模型不能新增事实或下一步。")
            if !model.state.privacy.cloudUseEnabled {
                Text("当前在本地整理；可在“隐私与模型”中开启模型文本使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).reviewSurface()
    }
    private func templateButton(_ kind: ReviewTemplateKind) -> some View {
        let selected = template.kind == kind
        return Button {
            template = ReviewTemplate(kind: kind); scope = ReviewScope()
            if kind.requiresWorkScope && !model.reviewTopics.contains(where: { WeeklyReviewEngine().category(for: $0, in: model.state) == .work }) { showsScope = true }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: kind.symbol).font(.title3).foregroundStyle(selected ? Color.accentColor : .secondary)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                Text(kind.title).font(.headline).foregroundStyle(.primary)
                Text(kind.subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
                .background(selected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.07), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var rangeControls: some View {
        HStack(spacing: 14) {
            Picker("时间范围", selection: $periodKind) {
                ForEach(ReviewPeriodKind.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(maxWidth: 200)
            Button { showsScope = true } label: {
                Label(scope.useSelectedTopics ? "已选 \(scope.topicIDs.count) 个主题" : (template.kind.requiresWorkScope ? "选择工作主题" : "内容范围"), systemImage: "line.3.horizontal.decrease")
            }
        }
    }
    private var generateButton: some View {
        Button {
            model.generateWeeklyReview(period: period, template: template, scope: scope, useModel: useModel)
        } label: { Label("生成回顾", systemImage: "sparkles").padding(.vertical, 4).padding(.horizontal, 6) }
            .buttonStyle(.borderedProminent).disabled(model.isGeneratingWeeklyReview || !period.isValid)
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "book.closed").font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor)
            Text("你的第一份一周回顾，从这里开始").font(.title3.weight(.semibold))
            Text("选一个用途和时间范围，Recall 会沿着主题回看发生过的变化。工作、学习或生活记录，都可以成为回顾的一部分。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(32).frame(maxWidth: .infinity, alignment: .leading).reviewSurface()
    }

    private func reportBody(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { reportHeading(report); Spacer(); reportActions(report) }
                VStack(alignment: .leading, spacing: 16) { reportHeading(report); reportActions(report) }
            }
            Divider()
            if !report.isReadable {
                Label("来源已删除、更正或重新分类，旧内容已移除。更新后可重新阅读。", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            } else if let edited = report.editedMarkdown {
                MarkdownDocumentView(markdown: edited).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 17)).lineSpacing(7)
                Text("已保留你的修改。每条原始依据仍可从下方查看。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("查看原始整理与依据") { reportSections(report).padding(.top, 18) }
            } else {
                Text(report.overview).font(.system(size: 18, weight: .medium)).lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                reportSections(report)
            }
            Text("保存于 \(report.createdAt.formatted()) · \(report.modelAssisted ? "模型辅助选取重点" : "本地事实整理")")
                .font(.caption).foregroundStyle(.secondary)
            if report.refinementPending { Text("已保留可用的本地版本，模型整理待重试。") .font(.caption).foregroundStyle(.orange) }
        }.padding(28).reviewSurface()
    }
    private func reportHeading(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(report.template.name, systemImage: report.template.kind.symbol).font(.title2.weight(.semibold))
            Text(report.period.label).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            if report.isReadable {
                let days = Set(report.items.flatMap(\.excerpts).map { report.period.calendar.startOfDay(for: $0.date) }).count
                Text("\(report.items.count) 个主题 · 涵盖 \(days) 个记录日" + (report.editedMarkdown == nil ? "" : " · 已编辑"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func reportActions(_ report: WeeklyReport) -> some View {
        HStack(spacing: 12) {
            Button { editing = report } label: { Label("编辑", systemImage: "pencil") }.disabled(!report.isReadable)
            Button { exporting = report } label: { Label("复制与导出", systemImage: "square.and.arrow.up") }.disabled(!report.isReadable)
            Menu {
                Button(report.editedMarkdown == nil ? "更新这份回顾" : "保留修改，生成新版") {
                    model.generateWeeklyReview(period: report.period, template: report.template, scope: report.scope,
                        useModel: useModel, replacing: report.editedMarkdown == nil ? report.id : nil)
                }.disabled(model.isGeneratingWeeklyReview)
                Button("删除回顾", role: .destructive) { deleting = report }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }.fixedSize()
    }
    private func reportSections(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(report.template.sections) { section in
                let items = report.items.filter { $0.section == section }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        Label(report.template.heading(section), systemImage: section.symbol)
                            .font(.headline).foregroundStyle(sectionColor(section))
                        ForEach(items) { item in reviewItem(item, report: report) }
                    }
                }
            }
        }
    }
    private func reviewItem(_ item: ReviewItem, report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let previous = item.previous {
                VStack(alignment: .leading, spacing: 6) {
                    Text("此前 · " + (previous.eventTimeKnown == true ? "发生于 " : "记录于 ") + stamp(previous.date, report: report)).font(.caption).foregroundStyle(.secondary)
                    Text(previous.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(item.featured(for: report.template.length)) { excerpt in
                VStack(alignment: .leading, spacing: 6) {
                    Text((excerpt.eventTimeKnown == true ? "发生于 " : "记录于 ") + stamp(excerpt.date, report: report)).font(.caption).foregroundStyle(.secondary)
                    Text(excerpt.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let action = item.nextAction {
                VStack(alignment: .leading, spacing: 6) {
                    Text("记录中的后续安排").font(.caption).foregroundStyle(.secondary)
                    Text(action).fixedSize(horizontal: false, vertical: true)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
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
        switch section { case .progress: .green; case .open: .orange; case .plans: .blue; case .notes: .purple }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("已保存的回顾").font(.headline); Spacer(); Text("\(model.state.weeklyReports.count) 份").foregroundStyle(.secondary) }
            if model.state.weeklyReports.isEmpty {
                Text("生成后会保存在这里，之后可以随时回看或调整。").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(model.state.weeklyReports.prefix(historyCount))) { report in
                Button { selectedID = report.id; DispatchQueue.main.async { scrollToReport() } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: report.template.kind.symbol).foregroundStyle(Color.accentColor)
                            .frame(width: 38, height: 38).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(report.template.name).font(.headline).foregroundStyle(.primary)
                            Text(report.period.label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(report.isReadable ? (report.editedMarkdown == nil ? "已保存" : "已编辑") : "待更新")
                            .font(.caption).foregroundStyle(.secondary)
                        Image(systemName: report.id == self.report?.id ? "checkmark.circle.fill" : "chevron.right")
                            .foregroundStyle(report.id == self.report?.id ? Color.accentColor : .secondary)
                    }.padding(16).reviewSurface()
                }.buttonStyle(.plain)
            }
            if model.state.weeklyReports.count > historyCount { Button("再显示 8 份") { historyCount += 8 } }
        }
    }
}

private extension View {
    func reviewSurface() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.075), lineWidth: 1))
    }
}

struct ReviewScopeSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let kind: ReviewTemplateKind
    @Binding var scope: ReviewScope
    @State private var search = ""
    private var topics: [MatterFile] {
        model.reviewTopics.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("选择回顾内容").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.buttonStyle(.borderedProminent) }
            Text(kind.requiresWorkScope ? "只选择这次工作汇报需要的主题。标为生活或学习的主题始终不会进入工作周报。" : "可以整理符合模板的全部主题，也可以只回看选中的事情。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("只整理我选中的主题", isOn: $scope.useSelectedTopics)
            TextField("搜索主题", text: $search).textFieldStyle(.roundedBorder)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if topics.isEmpty { Text("还没有匹配的主题。可以先补充一条记录，并选择工作、生活或学习分类。").foregroundStyle(.secondary) }
                    ForEach(topics) { topic in
                        scopeRow(topic)
                    }
                }.padding(.vertical, 8)
            }.clipped()
            Text("分类用于以后回顾的范围筛选；更改分类后，包含该主题的旧回顾需要重新生成。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 660, height: 590)
    }
    private func scopeRow(_ topic: MatterFile) -> some View {
        let category = WeeklyReviewEngine().category(for: topic, in: model.state)
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
        }.padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
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
            HStack { Text("自己的回顾格式").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("调整栏目名称、顺序和篇幅。内容仍按事实性质归类，没有依据的栏目会省略。")
                .foregroundStyle(.secondary)
            TextField("模板名称", text: $template.name).textFieldStyle(.roundedBorder)
            HStack {
                Picker("篇幅", selection: $template.length) { ForEach(ReviewLength.allCases) { Text($0.title).tag($0) } }
                Picker("表达", selection: $template.tone) { ForEach(ReviewTone.allCases) { Text($0.title).tag($0) } }
            }
            ForEach(Array(template.sections.enumerated()), id: \.element) { index, section in
                HStack {
                    Image(systemName: section.symbol).frame(width: 22).foregroundStyle(.secondary)
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
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
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
            Text("可以补充遗漏、调整措辞。修改会单独保存，原始依据仍然保留。") .foregroundStyle(.secondary)
            TextEditor(text: $markdown).font(.system(size: 17)).padding(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
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
            Text("下方就是将要输出的完整内容，可以先核对再用于工作汇报或分享。") .foregroundStyle(.secondary)
            ScrollView {
                MarkdownDocumentView(markdown: report?.markdown ?? "来源已变化，请重新生成。").textSelection(.enabled)
                    .font(.system(size: 16)).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.reviewSurface().clipped()
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
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
            Text("回看原始记录，核对发生时间、归属与前后变化。") .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if !current { Text("来源已删除或更正，请关闭后更新回顾。").foregroundStyle(.secondary) }
                    else {
                        ForEach((item.previous.map { [$0] } ?? []) + item.excerpts) { entry in
                            VStack(alignment: .leading, spacing: 10) {
                                Text((entry.eventTimeKnown == true ? "发生于 " : "记录于 ") + entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
                                Text(entry.text).textSelection(.enabled)
                                ForEach(model.state.captures.filter { entry.sourceIDs.contains($0.id) }) { capture in
                                    Button("查看原记录 · " + (capture.sourceAppName ?? "已保存记录")) { source = capture }
                                }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).reviewSurface()
                        }
                        if let action = item.nextAction {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("记录中的后续安排").font(.caption).foregroundStyle(.secondary)
                                Text(action).textSelection(.enabled)
                                ForEach(model.state.captures.filter { item.nextActionSourceIDs.contains($0.id) }) { capture in
                                    Button("查看原记录 · " + (capture.sourceAppName ?? "已保存记录")) { source = capture }
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
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.state.reviewSchedules.isEmpty {
                        Text("例如，周五下班前整理工作，周日晚上回看生活。计划默认使用本地记录整理，不会新增采集。") .foregroundStyle(.secondary)
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
                            Text(value.timeZoneIdentifier + " · " + value.periodKind.title).font(.caption).foregroundStyle(.secondary)
                            if value.failureCount > 0 { Text("模型或保存暂未完成，将自动重试；已有的本地版本可以阅读。") .font(.caption).foregroundStyle(.orange) }
                            else if value.isEnabled, let next = value.nextRunAt { Text("下次生成：" + next.formatted()).font(.caption).foregroundStyle(.secondary) }
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
            HStack {
                Picker("生成时间", selection: $schedule.weekday) {
                    Text("周一").tag(2); Text("周二").tag(3); Text("周三").tag(4); Text("周四").tag(5)
                    Text("周五").tag(6); Text("周六").tag(7); Text("周日").tag(1)
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
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("使用已连接模型辅助挑选重点", isOn: $schedule.useModel).disabled(!model.state.privacy.cloudUseEnabled)
            Toggle("生成后发送系统通知", isOn: $schedule.notifyWhenReady)
            Text("支持暂停或删除计划；失败会记录日志并重试，不自动发送周报或创建提醒。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
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
            .sheet(isPresented: $showsScope) { ReviewScopeSheet(kind: schedule.template.kind, scope: $schedule.scope).environmentObject(model) }
    }
}
