import RecallKit
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DailySummariesView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var selectedID: UUID?
    @State private var selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
    @State private var showsCalendar = false
    @State private var managing: DailySummary?
    @State private var visibleCount = 30
    private var summaries: [DailySummary] { model.state.dailySummaries.sorted { $0.day > $1.day } }
    private var selected: DailySummary? { summaries.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            RecallPageHeader(title: "每日回顾", subtitle: "回看一天里值得记住的事") {
                HStack(spacing: 10) {
                    Button { showsCalendar = true } label: {
                        Label(selectedDate.formatted(.dateTime.month().day()), systemImage: "calendar")
                    }.popover(isPresented: $showsCalendar) {
                        TimelineCalendarPopover(selectedDay: selectedDate) { day in
                            selectedDate = day
                            selectedID = summaries.first { Calendar.current.isDate($0.day, inSameDayAs: day) }?.id
                            showsCalendar = false
                        }
                    }
                    Button(RecallLocalization.text("生成回顾")) { model.generateDailyReview(on: selectedDate) }
                        .buttonStyle(.borderedProminent).disabled(model.isLoadingSavedState || model.isGeneratingDailySummary)
                }
            }
            if model.isLoadingSavedState {
                ProgressView("正在读取已保存的回顾…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    dateList.frame(width: 214)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let task = model.dailyReviewTask(on: selectedDate), task.isRunning || task.state == .failed {
                                RecallTaskStatusView(task: task, cancel: model.cancelDailyReview)
                            }
                            if let selected {
                                DailySummaryCard(summary: selected, isExpanded: true, onToggle: {}, onManage: { managing = selected }, onReviewInsight: { model.reviewInsight($0, rating: $1) }, onUpdateRoutine: { model.updateLearnedRoutine($0, status: $1) })
                            } else {
                                VStack(spacing: 14) {
                                    Image(systemName: "calendar").font(.system(size: 34, weight: .light)).foregroundStyle(RecallPalette.accent)
                                    Text(summaries.isEmpty ? "还没有每日回顾" : "这一天还没有回顾").font(.headline)
                                    Text(RecallLocalization.text("选择日期，生成这一天值得记住的事。")).foregroundStyle(RecallPalette.secondary)
                                    Button(RecallLocalization.text("生成回顾")) { model.generateDailyReview(on: selectedDate) }.buttonStyle(.borderedProminent).disabled(model.isGeneratingDailySummary)
                                }.frame(maxWidth: .infinity, minHeight: 360).recallSurface()
                            }
                        }.frame(maxWidth: 880, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
                    }.clipped().id(selectedID)
                }.padding(.horizontal, 24).padding(.bottom, 16)
            }
        }.onAppear { openSelection() }
            .onChange(of: model.dailyToOpen) { _, id in if let id { select(id) } }
            .onChange(of: model.state.dailySummaries.map(\.id)) { _, ids in
                if selectedID == nil || !ids.contains(selectedID!) { openSelection() }
            }
            .onChange(of: model.navigationRevision) { _, _ in if case .daily(let id) = model.destination { select(id) } }
            .sheet(item: $managing) { DailySummaryManagementSheet(summary: $0).environmentObject(model) }
    }
    private var dateList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(RecallLocalization.both("已保存 \(summaries.count) 天", "\(summaries.count) days saved")).font(.caption).foregroundStyle(RecallPalette.secondary).padding(.bottom, 4)
                ForEach(Array(summaries.prefix(visibleCount))) { summary in
                    RecallListChoice(title: summary.day.formatted(.dateTime.month().day().weekday()), detail: keywords(summary), selected: selectedID == summary.id) { select(summary.id) }
                }
                if summaries.count > visibleCount { Button(RecallLocalization.text("更早的回顾")) { visibleCount += 30 }.padding(.vertical, 8) }
            }
        }.clipped()
    }
    private func keywords(_ summary: DailySummary) -> String {
        let topics = summary.items.filter { $0.section.canonical == .progress }.map { $0.knowledge?.topic ?? $0.title }
        var seen = Set<String>()
        let words = topics.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(2)
        return words.isEmpty ? "查看当天回顾" : words.joined(separator: " · ")
    }
    private func select(_ id: UUID) {
        guard let item = summaries.first(where: { $0.id == id }) else { return }
        selectedID = id; selectedDate = item.day; model.dailyToOpen = id
        visibleCount = max(visibleCount, (summaries.firstIndex { $0.id == id } ?? 0) + 1)
    }
    private func openSelection() {
        if let id = model.dailyToOpen, summaries.contains(where: { $0.id == id }) { select(id) }
        else if let id = summaries.first?.id { select(id) }
        else { selectedID = nil }
    }
}

private struct DailySummaryCard: View {
    let summary: DailySummary
    let isExpanded: Bool
    let onToggle: () -> Void
    let onManage: () -> Void
    let onReviewInsight: (PersonalInsight, InsightFeedbackRating) -> Void
    let onUpdateRoutine: (LearnedRoutine, LearnedRoutineStatus) -> Void

    private var displayContent: String {
        if !summary.items.isEmpty {
            return DailySummaryItemParser.markdown(from: summary.items)
        }
        guard summary.generationKind == .cloud else {
            return DailySummaryContentFormatter.removingCitationMarkers(from: summary.content)
        }
        let todoActions = summary.todos.map(\.title)
        let briefingActions = summary.briefing?.nextActions.map { "\($0.title)：\($0.detail)" } ?? []
        return DailySummaryContentFormatter.normalizingNextActionSection(
            in: summary.content,
            fallbackActions: todoActions + briefingActions
        )
    }

    private var preview: String {
        if summary.generationKind == .localFallback, let briefing = summary.briefing {
            return DailySummaryContentFormatter.removingCitationMarkers(from: briefing.headline)
        }
        if let overview = summary.modelOverview, !overview.isEmpty { return overview }
        let text = displayContent
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .prefix(3)
            .joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        return text.isEmpty ? "这条总结暂无可预览内容。" : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 15 : 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.day.formatted(.dateTime.month().day().weekday())).font(.system(size: 20, weight: .semibold))
                    Text(RecallLocalization.text("更新于 ") + summary.createdAt.formatted(date: .omitted, time: .shortened) + " · " + RecallLocalization.text("已保存"))
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                Spacer(minLength: 8)
                Button { model.summaryFeedbackTarget = .daily(summary) } label: {
                    Label(RecallLocalization.text("纠正回顾"), systemImage: "square.and.pencil")
                }.help(RecallLocalization.text("说明遗漏或不准确的地方，对这整篇回顾进行纠正"))
                Menu {
                    Button(RecallLocalization.text("重新生成")) { model.generateDailyReview(on: summary.day) }.disabled(model.isGeneratingDailySummary)
                    Button(RecallLocalization.text("管理这份回顾"), action: onManage)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多回顾操作")
            }
            if isExpanded {
                Divider()
                if let overview = summary.modelOverview, !overview.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(RecallLocalization.text("当天概览")).font(.caption).foregroundStyle(RecallPalette.secondary)
                        Text(DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(from: DailySummaryContentFormatter.removingCitationMarkers(from: overview)))
                            .font(.system(size: 17, weight: .medium)).lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }.padding(.vertical, 8).padding(.bottom, 8)
                }
                if !summary.items.isEmpty {
                    DailyReviewContentView(summary: summary)
                        .textSelection(.enabled)
                } else if summary.generationKind == .cloud {
                    MarkdownDocumentView(markdown: displayContent)
                        .textSelection(.enabled)
                } else if let briefing = summary.briefing {
                    DailyBriefingView(
                        briefing: briefing,
                        feedback: summaryFeedback,
                        routineStates: routineStates,
                        onReviewInsight: onReviewInsight,
                        onUpdateRoutine: onUpdateRoutine
                    )
                } else {
                    MarkdownDocumentView(markdown: displayContent)
                        .textSelection(.enabled)
                }
                SummaryFeedbackFooter(target: .daily(summary), showsFeedbackButton: false, showsHistoryButton: false)
            } else {
                Text(preview)
                    .font(.system(size: 15))
                    .foregroundStyle(RecallPalette.secondary)
                    .lineLimit(2)
                    .padding(.leading, 34)
            }
        }
        .padding(isExpanded ? 24 : 15)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RecallPalette.border, lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @EnvironmentObject private var model: RecallAppModel

    private var summaryFeedback: [UUID: InsightFeedbackRating] {
        Dictionary(uniqueKeysWithValues: model.state.insightFeedback.map { ($0.insightID, $0.rating) })
    }

    private var routineStates: [UUID: LearnedRoutineStatus] {
        Dictionary(uniqueKeysWithValues: model.state.learnedRoutines.map { ($0.id, $0.status) })
    }

    private var activeActionCount: Int {
        summary.todos.filter { $0.status == .pending || $0.status == .inProgress }.count
    }
}

private struct DailySummaryItemsView: View {
    let items: [DailySummaryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(DailySummarySection.displaySections) { section in
                let sectionItems = items.filter { $0.section == section }
                if !sectionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(color(for: section))
                        ForEach(sectionItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                if !item.detail.isEmpty, item.detail != item.title {
                                    Text(item.detail)
                                        .font(.system(size: 15))
                                        .foregroundStyle(RecallPalette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.leading, 2)
                        }
                    }
                }
            }
        }
    }

    private func color(for section: DailySummarySection) -> Color {
        switch section {
        case .headline, .nextActions: RecallPalette.accent
        case .progress: RecallPalette.accent
        case .openLoops, .todos, .actions: RecallPalette.warning
        case .insights: RecallPalette.accent
        case .recent: RecallPalette.accent
        }
    }
}

private struct DailySummaryManagementSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let summary: DailySummary
    @State private var pendingForgetItem: DailySummaryItem?
    @State private var isConfirmingSummaryDeletion = false
    @State private var sourceItem: DailySummaryItem?

    private var currentSummary: DailySummary {
        model.state.dailySummaries.first(where: { $0.id == summary.id }) ?? summary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(RecallPalette.onAccent)
                    .frame(width: 46, height: 46)
                    .background(RecallPalette.accent, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecallLocalization.text("管理每日回顾"))
                        .font(.title2.weight(.semibold))
                    Text(summary.day.formatted(.dateTime.year().month().day().weekday()))
                        .foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button(RecallLocalization.text("完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(DailySummarySection.displaySections) { section in
                        let sectionItems = currentSummary.items.filter { $0.section == section }
                        if !sectionItems.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(section.title, systemImage: section.systemImage)
                                    .font(.headline)
                                ForEach(sectionItems) { item in
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.title).font(.system(size: 15, weight: .semibold))
                                            if !item.detail.isEmpty, item.detail != item.title {
                                                Text(item.detail).font(.system(size: 14)).foregroundStyle(RecallPalette.secondary).lineLimit(3)
                                            }
                                            Label("关联 \(item.evidenceIDs.count) 条原始记忆", systemImage: "link")
                                                .font(.caption)
                                                .foregroundStyle(RecallPalette.secondary)
                                        }
                                        Spacer()
                                        Button {
                                            sourceItem = item
                                        } label: {
                                            Label(RecallLocalization.text("来源"), systemImage: "link")
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(item.evidenceIDs.isEmpty)
                                        Menu {
                                            Button(RecallLocalization.text("只删除这条总结内容")) {
                                                model.removeSummaryItem(item, from: currentSummary, reason: .noLongerNeeded)
                                            }
                                            Button(RecallLocalization.text("连同原始记录一起删除…"), role: .destructive) {
                                                pendingForgetItem = item
                                            }
                                        } label: {
                                            Label(RecallLocalization.text("处理"), systemImage: "ellipsis.circle")
                                        }
                                        .menuStyle(.borderlessButton)
                                        .fixedSize()
                                    }
                                    .padding(14)
                                    .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecallPalette.border, lineWidth: 1))
                                }
                            }
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(RecallLocalization.text("只删除这份总结")).font(.headline)
                            Text(RecallLocalization.text("原始记录会保留，之后仍可重新生成。"))
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                        }
                        Spacer()
                        Button(RecallLocalization.text("删除总结"), role: .destructive) { isConfirmingSummaryDeletion = true }
                            .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(RecallPalette.danger.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(RecallPalette.danger.opacity(0.18), lineWidth: 1))
                }
                .padding(24)
            }
        }
        .frame(width: 760, height: 720)
        .sheet(item: $sourceItem) { item in
            SummaryItemSourceSheet(
                item: item,
                captures: model.state.captures.filter { item.evidenceIDs.contains($0.id) }
            )
        }
        .sheet(item: $pendingForgetItem) { item in
            SummarySourceDeletionSheet(
                item: item,
                sourceCount: item.evidenceIDs.isEmpty ? currentSummary.sourceCaptureIDs.count : item.evidenceIDs.count
            ) { reason, suppressSimilar in
                model.forgetSources(
                    for: item,
                    in: currentSummary,
                    reason: reason,
                    suppressSimilar: suppressSimilar
                )
            }
        }
        .confirmationDialog("只删除这份总结？", isPresented: $isConfirmingSummaryDeletion) {
            Button(RecallLocalization.text("删除总结"), role: .destructive) {
                model.deleteDailySummary(currentSummary)
                dismiss()
            }
            Button(RecallLocalization.text("取消"), role: .cancel) {}
        } message: {
            Text(RecallLocalization.text("原始记录不会被删除，可在 7 天内从最近删除恢复总结。"))
        }
    }
}

private struct SummarySourceDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: DailySummaryItem
    let sourceCount: Int
    let onConfirm: (MemoryDeletionReason, Bool) -> Void
    @State private var reason: MemoryDeletionReason = .noLongerNeeded
    @State private var suppressSimilar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.slash.fill")
                    .font(.title2)
                    .foregroundStyle(RecallPalette.warning)
                    .frame(width: 48, height: 48)
                    .background(RecallPalette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecallLocalization.text("删除内容和原始记录？"))
                        .font(.title2.weight(.semibold))
                    Text(item.title)
                        .foregroundStyle(RecallPalette.secondary)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("本次会删除 \(sourceCount) 条来源记录", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text(RecallLocalization.text("相关内容会退出时间线、搜索、问一问和派生提醒，并在“最近删除”中保留 7 天。"))
                    .foregroundStyle(RecallPalette.secondary)
            }
            .padding(16)
            .background(RecallPalette.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))

            Picker(RecallLocalization.text("为什么删除（仅用于本机整理）"), selection: $reason) {
                ForEach(MemoryDeletionReason.allCases) { Text($0.title).tag($0) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(RecallLocalization.text("以后不再记录类似内容"), isOn: $suppressSimilar)
                Text(RecallLocalization.text("可选。它只影响之后的新采集，不会改变本次删除的内容和范围；过滤规则可在“设置”中移除。"))
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
            }

            HStack {
                Button(RecallLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(RecallLocalization.text("删除内容和原始记录"), role: .destructive) {
                    onConfirm(reason, suppressSimilar)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 590)
    }
}

private struct SummaryItemSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: DailySummaryItem
    let captures: [CaptureRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecallLocalization.text("记忆来源")).font(.title2.weight(.semibold))
                    Text(item.title).foregroundStyle(RecallPalette.secondary).lineLimit(2)
                }
                Spacer()
                Button(RecallLocalization.text("关闭")) { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(22)
            Divider()
            if captures.isEmpty {
                ContentUnavailableView(RecallLocalization.text("来源已不可用"), systemImage: "link.badge.plus", description: Text(RecallLocalization.text("这可能是旧总结，或关联记录已经被删除。")))
            } else {
                List(captures.sorted { $0.createdAt > $1.createdAt }) { capture in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(capture.sourceAppName ?? capture.eventTemplate.title).font(.headline)
                            Spacer()
                            Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                        }
                        Text(capture.summary ?? capture.ocrText)
                            .font(.system(size: 15))
                            .foregroundStyle(RecallPalette.secondary)
                            .lineLimit(5)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(RecallPalette.background)
            }
        }
        .frame(width: 680, height: 520)
    }
}

private struct DailyBriefingView: View {
    let briefing: DailyBriefing
    let feedback: [UUID: InsightFeedbackRating]
    let routineStates: [UUID: LearnedRoutineStatus]
    let onReviewInsight: (PersonalInsight, InsightFeedbackRating) -> Void
    let onUpdateRoutine: (LearnedRoutine, LearnedRoutineStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "scope")
                    .font(.title2)
                    .foregroundStyle(RecallPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecallLocalization.text("当天进展")).font(.caption.weight(.semibold)).foregroundStyle(RecallPalette.secondary)
                    Text(clean(briefing.headline)).font(.system(size: 15, weight: .semibold))
                }
            }
            if !briefing.progress.isEmpty {
                briefingSection("具体进展", icon: "checkmark.seal.fill", color: RecallPalette.accent, items: briefing.progress, empty: "")
            }
            if !actionItems.isEmpty {
                briefingSection("接下来要处理", icon: "checklist", color: RecallPalette.warning, items: actionItems, empty: "")
            }

            let visibleInsights = briefing.insights.filter { $0.confidence >= 0.75 }
            if !visibleInsights.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("值得留意", icon: "sparkles", color: RecallPalette.accent)
                    ForEach(visibleInsights) { insight in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(clean(insight.title))
                                .font(.system(size: 15, weight: .semibold))
                            Text(clean(insight.detail)).font(.system(size: 15)).foregroundStyle(RecallPalette.secondary)
                            if let recommendation = insight.recommendation {
                                Label(clean(recommendation), systemImage: "arrow.right.circle.fill")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(RecallPalette.accent)
                            }
                            insightFeedbackControls(insight)
                        }
                        .padding(12)
                        .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            routineReview
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func briefingSection(_ title: String, icon: String, color: Color, items: [BriefingItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title, icon: icon, color: color)
            if items.isEmpty {
                Text(empty).font(.system(size: 15)).foregroundStyle(RecallPalette.secondary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(clean(item.title)).font(.system(size: 15, weight: .semibold))
                        Text(clean(item.detail)).font(.system(size: 15)).foregroundStyle(RecallPalette.secondary)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
    }

    private var actionItems: [BriefingItem] {
        var seen: Set<String> = []
        return (briefing.openLoops + briefing.nextActions).filter { item in
            let key = "\(item.title)\(item.detail)"
                .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
                .lowercased()
            return seen.insert(key).inserted
        }
    }

    @ViewBuilder
    private func insightFeedbackControls(_ insight: PersonalInsight) -> some View {
        if let rating = feedback[insight.id] {
            Label(feedbackTitle(rating), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        } else {
            HStack(spacing: 14) {
                Text(RecallLocalization.text("这个判断准确吗？")).font(.caption).foregroundStyle(RecallPalette.secondary)
                Button(RecallLocalization.text("准确")) { onReviewInsight(insight, .accurate) }
                Button(RecallLocalization.text("部分准确")) { onReviewInsight(insight, .partiallyAccurate) }
                Button(RecallLocalization.text("不准确")) { onReviewInsight(insight, .inaccurate) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var routineReview: some View {
        if !briefing.routineCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("可学习的个人规则", icon: "wand.and.stars", color: RecallPalette.accent)
                ForEach(briefing.routineCandidates) { routine in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(clean(routine.title)).font(.system(size: 15, weight: .semibold))
                            Text(clean("\(routine.trigger)，\(routine.suggestedAction)")).font(.system(size: 15)).foregroundStyle(RecallPalette.secondary)
                        }
                        Spacer()
                        let status = routineStates[routine.id] ?? routine.status
                        if status == .proposed {
                            Button(RecallLocalization.text("启用")) { onUpdateRoutine(routine, .enabled) }
                            Button(RecallLocalization.text("忽略")) { onUpdateRoutine(routine, .dismissed) }
                        } else {
                            Text(status == .enabled ? "已启用" : "已忽略").font(.caption).foregroundStyle(RecallPalette.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
            .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func feedbackTitle(_ rating: InsightFeedbackRating) -> String {
        switch rating {
        case .accurate: "已反馈：准确"
        case .partiallyAccurate: "已反馈：部分准确"
        case .inaccurate: "已反馈：不准确"
        case .acted: "已反馈：已采取行动"
        case .dismissed: "已忽略"
        }
    }

    private func clean(_ text: String) -> String {
        DailySummaryContentFormatter.removingCitationMarkers(from: text)
    }
}

struct MarkdownDocumentView: View {
    private enum Block {
        case heading(level: Int, text: String)
        case unorderedList(text: String)
        case orderedList(marker: String, text: String)
        case divider
        case paragraph(text: String)
        case spacer
    }

    let markdown: String

    private var blocks: [Block] {
        markdown
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return .spacer }
                if trimmed == "---" || trimmed == "***" || trimmed == "___" { return .divider }
                if trimmed.hasPrefix("### ") { return .heading(level: 3, text: String(trimmed.dropFirst(4))) }
                if trimmed.hasPrefix("## ") { return .heading(level: 2, text: String(trimmed.dropFirst(3))) }
                if trimmed.hasPrefix("# ") { return .heading(level: 1, text: String(trimmed.dropFirst(2))) }
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                    return .unorderedList(text: String(trimmed.dropFirst(2)))
                }
                if let ordered = orderedListParts(from: trimmed) {
                    return .orderedList(marker: ordered.marker, text: ordered.text)
                }
                return .paragraph(text: trimmed)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    inlineText(text)
                        .font(headingFont(for: level))
                        .padding(.top, level == 1 ? 8 : 4)
                case let .unorderedList(text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.system(size: 15, weight: .bold))
                        inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 4)
                case let .orderedList(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).font(.system(size: 15, weight: .semibold)).foregroundStyle(RecallPalette.secondary)
                        inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 4)
                case .divider:
                    Divider().padding(.vertical, 4)
                case let .paragraph(text):
                    inlineText(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .spacer:
                    Spacer().frame(height: 4)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inlineText(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return Text(text).font(.system(size: 15))
        }
        return Text(attributed).font(.system(size: 15))
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        default: .system(size: 15, weight: .semibold)
        }
    }

    private func orderedListParts(from line: String) -> (marker: String, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let markerDigits = line[..<dot]
        guard !markerDigits.isEmpty, markerDigits.allSatisfy(\.isNumber) else { return nil }
        let contentStart = line.index(after: dot)
        guard contentStart < line.endIndex, line[contentStart] == " " else { return nil }
        let textStart = line.index(after: contentStart)
        return (marker: "\(markerDigits).", text: String(line[textStart...]))
    }
}


