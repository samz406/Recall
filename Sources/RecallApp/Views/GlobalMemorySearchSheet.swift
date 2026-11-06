import SwiftUI
import RecallKit

struct GlobalMemorySearchSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    var initialQuery = ""
    var initialDates = false
    var body: some View { GlobalMemorySearchContent(workspace: model.globalSearch, initialQuery: initialQuery, initialDates: initialDates) }
}

struct GlobalMemorySearchContent: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: GlobalSearchWorkspace
    @State private var query: String
    @State private var usesDates: Bool
    @FocusState private var queryFocused: Bool
    @State private var app = ""
    @State private var topicID = ""
    @State private var start = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var end = Date.now

    init(workspace: GlobalSearchWorkspace, initialQuery: String = "", initialDates: Bool = false) {
        self.workspace = workspace
        _query = State(initialValue: initialQuery); _usesDates = State(initialValue: initialDates)
    }
    private var request: GlobalMemorySearchQuery {
        let calendar = Calendar.current
        return GlobalMemorySearchQuery(text: query,
            start: usesDates ? calendar.startOfDay(for: start) : nil,
            end: usesDates ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) : nil,
            app: app.isEmpty ? nil : app,
            topicSources: topicID.isEmpty ? nil : workspace.topics.first(where: { $0.id == topicID })?.sourceIDs ?? [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(RecallLocalization.text("搜索记忆")).font(.title2.bold())
                Spacer()
                Button(RecallLocalization.text("完成")) { dismiss() }
            }
            TextField(RecallLocalization.text("关键词、主题或人名"), text: $query)
                .font(.system(size: 16)).textFieldStyle(.plain).focused($queryFocused)
                .padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 52)
                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(queryFocused ? RecallPalette.accent : RecallPalette.border, lineWidth: queryFocused ? 1.5 : 1))
                .accessibilityIdentifier("global-memory-search-input")
            HStack {
                Picker(RecallLocalization.text("来源"), selection: $app) {
                    Text(RecallLocalization.text("全部应用")).tag("")
                    ForEach(workspace.sources, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 220)
                Picker(RecallLocalization.text("主题"), selection: $topicID) {
                    Text(RecallLocalization.text("全部主题")).tag("")
                    ForEach(workspace.topics) { Text($0.title).tag($0.id) }
                }.frame(maxWidth: 240)
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle(RecallLocalization.text("限定日期"), isOn: $usesDates).fixedSize()
                    .help(RecallLocalization.both("记录按保存日期、回顾按涵盖日期、提醒按提醒日期筛选。", "Filter records by saved date, reviews by covered dates, and reminders by their date."))
                if usesDates {
                    CalendarDateField(title: RecallLocalization.text("从"), date: $start)
                    CalendarDateField(title: RecallLocalization.text("到"), date: $end, earliest: start)
                }
                Spacer(minLength: 0)
            }
            Divider()
            if workspace.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(RecallLocalization.both("正在搜索…", "Searching…")).font(.callout).foregroundStyle(RecallPalette.secondary)
                }
            }
            if let message = workspace.message {
                HStack {
                    Text(message)
                    Button(RecallLocalization.text("重试")) { workspace.setQuery(request, debounce: false) }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !workspace.isLoading, request.hasCriteria, workspace.hits.isEmpty, workspace.message == nil {
                        Text(RecallLocalization.text("没有匹配内容，可以换一个词或扩大范围。"))
                    }
                    if !request.hasCriteria {
                        Text(RecallLocalization.text("搜索记录、主题、每日回顾、周期回顾、提醒与长期记忆。支持多个关键词组合；全程本地检索。"))
                            .foregroundStyle(RecallPalette.secondary)
                    }
                    ForEach(workspace.hits) { hit in
                        Button { model.destination = hit.destination; dismiss() } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(RecallLocalization.text(hit.kind) + " · " + dateLabel(hit))
                                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                                Text(highlight(hit.title)).font(.headline)
                                Text(highlight(hit.detail)).lineLimit(3).foregroundStyle(RecallPalette.secondary)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }.clipped()
            Text(RecallLocalization.text("最多显示 50 项；缩小关键词、日期或来源可继续定位。"))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        }.padding(24).frame(minWidth: 720, idealWidth: 820, minHeight: 540, idealHeight: 670)
            .onAppear { queryFocused = true; workspace.activate(request) }
            .onDisappear { workspace.deactivate() }
            .onChange(of: request) { _, value in workspace.setQuery(value) }
            .onChange(of: start) { _, value in if end < value { end = value } }
    }
    private func dateLabel(_ hit: MemorySearchHit) -> String {
        let first = hit.date.formatted(date: .abbreviated, time: .omitted)
        guard let end = hit.endDate else { return first }
        return first + " – " + end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)
    }
    private func highlight(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        for term in query.split(whereSeparator: \.isWhitespace) {
            if let range = value.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) {
                value[range].foregroundColor = RecallPalette.accent
                value[range].font = .body.bold()
            }
        }
        return value
    }
}

