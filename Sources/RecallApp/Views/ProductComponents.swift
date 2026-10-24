import SwiftUI
import RecallKit

enum RecallTypography {
    static let page = Font.system(size: 24, weight: .semibold)
    static let title = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 17)
    static let caption = Font.system(size: 13)
}

struct RecallPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) { introduction; Spacer(minLength: 16); actions() }
            VStack(alignment: .leading, spacing: 16) { introduction; actions() }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(RecallPalette.background)
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(RecallTypography.page)
            Text(subtitle).font(.subheadline).foregroundStyle(RecallPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 220, alignment: .leading)
    }
}

struct RecallTaskStatusView: View {
    let task: RecallTaskStatus
    var cancel: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if task.isRunning { ProgressView().controlSize(.small).frame(width: 22, height: 22) }
            else { Image(systemName: symbol).foregroundStyle(task.state == .failed ? RecallPalette.warning : RecallPalette.accent) }
            VStack(alignment: .leading, spacing: 5) {
                Text(task.kind + " · " + task.target).font(.subheadline.weight(.medium))
                Text(task.phase).font(.callout).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if task.isRunning, let cancel { Button("取消", action: cancel) }
        }.padding(16).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
    }
    private var symbol: String {
        switch task.state {
        case .running: "clock"
        case .succeeded: "checkmark.circle"
        case .partial: "info.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        }
    }
}

struct RecallTaskHistory: View {
    @EnvironmentObject var model: RecallAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近的处理结果").font(.headline)
            Text("保留本次打开应用后的任务；切换页面不会中断生成。")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.tasks.isEmpty { Text("暂时没有任务").foregroundStyle(RecallPalette.secondary) }
                    ForEach(model.tasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            RecallTaskStatusView(task: task)
                            if let target = task.destination {
                                Button("查看结果") { model.destination = target }
                            }
                        }
                    }
                }
            }
        }.padding(20).frame(width: 420, height: 430)
    }
}

struct RecallSourcesView: View {
    @EnvironmentObject var model: RecallAppModel
    @Environment(\.dismiss) var dismiss
    let title: String
    let ids: [UUID]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecallPageHeader(title: "内容依据", subtitle: title) { Button("完成") { dismiss() } }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    let sources = model.state.captures.filter { ids.contains($0.id) }
                    if sources.isEmpty { Text("来源已删除或不再可用。") }
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 10) {
                            Text((source.sourceAppName ?? "记录") + " · " + source.createdAt.formatted()).font(.caption).foregroundStyle(RecallPalette.secondary)
                            Text(source.ocrText).font(RecallTypography.body).textSelection(.enabled)
                            HStack {
                                Button("在时间线定位") { dismiss(); model.destination = .record(source.id) }
                                Menu("更正这条记录") {
                                    Button("不是我说的") { model.correctMatter(MatterCorrection(evidenceIDs: [source.id], kind: .notMine)); dismiss() }
                                    Button("内容不准确") { model.correctMatter(MatterCorrection(evidenceIDs: [source.id], kind: .inaccurate)); dismiss() }
                                }
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(24)
            }.clipped()
        }.frame(minWidth: 600, idealWidth: 720, minHeight: 430, idealHeight: 650)
    }
}

struct GlobalMemorySearchSheet: View {
    @EnvironmentObject var model: RecallAppModel
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var app = ""
    @State private var topicID = ""
    @State private var usesDates = false
    @State private var start = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var end = Date.now
    @State private var index: GlobalMemorySearch?
    @State private var hits: [MemorySearchHit] = []
    @State private var building = false
    private var revision: String {
        model.state.captures.map { $0.id.uuidString + $0.contentHash }.joined()
        + model.state.dailySummaries.map { $0.id.uuidString }.joined()
        + model.state.weeklyReports.map { $0.id.uuidString + String($0.updatedAt.timeIntervalSince1970) }.joined()
        + model.state.reminders.map { $0.id.uuidString + String($0.updatedAt.timeIntervalSince1970) }.joined()
        + (model.memoryWorkspace?.revision.uuidString ?? "")
    }
    private var queryKey: String { query + app + topicID + String(usesDates) + start.description + end.description }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("搜索记忆").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            TextField("关键词、主题或人名", text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Picker("来源", selection: $app) {
                    Text("全部应用").tag("")
                    ForEach(Array(Set(model.state.captures.compactMap(\.sourceAppName))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 220)
                Picker("主题", selection: $topicID) {
                    Text("全部主题").tag("")
                    ForEach(model.matterFiles) { Text($0.title).tag($0.id) }
                }.frame(maxWidth: 240)
                Spacer()
            }
            HStack {
                Toggle("限定日期", isOn: $usesDates)
                if usesDates {
                    DatePicker("从", selection: $start, displayedComponents: .date).labelsHidden()
                    DatePicker("到", selection: $end, in: start..., displayedComponents: .date).labelsHidden()
                }
            }
            Divider()
            if building { ProgressView("正在准备本地搜索…") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !building && !query.isEmpty && hits.isEmpty { Text("没有匹配内容，可以换一个词或扩大范围。") }
                    if query.isEmpty { Text("搜索记录、主题、每日回顾、周期回顾、提醒与长期记忆。支持多个关键词组合；全程本地检索。") }
                    ForEach(hits) { hit in
                        Button {
                            model.destination = hit.destination; dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(hit.kind + " · " + hit.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(RecallPalette.secondary)
                                Text(highlight(hit.title)).font(.headline)
                                Text(highlight(ReviewContentQuality.shortDetail(hit.detail))).lineLimit(2).foregroundStyle(RecallPalette.secondary)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 8)
            }.clipped()
            Text("最多显示 50 项；缩小关键词、日期或来源可继续定位。")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        }.padding(24).frame(minWidth: 720, idealWidth: 820, minHeight: 540, idealHeight: 670)
            .task(id: revision) {
                building = true; hits = []; index = nil
                let snapshot = model.state, files = model.matterFiles
                let result = await Task.detached(priority: .utility) { GlobalMemorySearch(state: snapshot, matters: files) }.value
                guard !Task.isCancelled else { return }
                index = result; building = false; await search()
            }
            .task(id: queryKey) { await search() }
            .onChange(of: start) { _, value in if end < value { end = value } }
    }
    private func search() async {
        guard let index else { return }
        let text = query, source = app.isEmpty ? nil : app
        let first = usesDates ? Calendar.current.startOfDay(for: start) : nil
        let last = usesDates ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) : nil
        let topicSources = topicID.isEmpty ? nil : Set(model.matterFiles.first { $0.id == topicID }?.evidenceIDs ?? [])
        let result = await Task.detached(priority: .userInitiated) { index.search(text, start: first, end: last, app: source, topicSources: topicSources) }.value
        guard !Task.isCancelled else { return }; hits = result
    }
    private func highlight(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        for term in query.split(whereSeparator: \.isWhitespace) {
            if let range = value.range(of: String(term), options: .caseInsensitive) { value[range].foregroundColor = RecallPalette.accent; value[range].font = .body.bold() }
        }
        return value
    }
}
