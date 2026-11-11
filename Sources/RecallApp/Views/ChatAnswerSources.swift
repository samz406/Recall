import SwiftUI
import RecallKit

struct ChatAnswerSources: View {
    @EnvironmentObject private var model: RecallAppModel
    @ObservedObject var workspace: ChatSourcesWorkspace
    let citations: [UUID]
    @State private var showsSources = false

    var body: some View {
        let ids = workspace.availableIDs(citations)
        HStack(spacing: 8) {
            let memories = model.state.memoryKnowledge.claims.filter { $0.kind.isPersonal && $0.usable() && !Set($0.sourceIDs).isDisjoint(with: ids) }
            if !memories.isEmpty {
                Menu(RecallLocalization.both("参考的记忆（\(memories.count)）", "Memories (\(memories.count))")) {
                    ForEach(memories) { claim in Button(claim.content) { model.knowledgeToOpen = claim.id; model.destination = .knowledge(claim.id) } }
                }.font(.caption).fixedSize()
            }
            if ids.count == 1, let id = ids.first, workspace.record(id: id)?.memoryDirective != nil,
               model.state.messages.last?.role == .assistant, model.state.messages.last?.content.hasPrefix("已记住：") == true,
               model.state.messages.last?.citations == citations,
               model.state.memoryKnowledge.claims.contains(where: { $0.usable() && $0.sourceIDs.contains(id) }) {
                Button(RecallLocalization.both("撤销记住", "Undo remember")) { model.undoRemembering(id) }.font(.caption)
            }
            ForEach(Array(ids.prefix(2)), id: \.self) { id in
                if let record = workspace.record(id: id) {
                    Button { open(id) } label: {
                        Label((record.sourceAppName ?? RecallLocalization.text("时间线")) + " · "
                            + record.createdAt.formatted(.dateTime.month().day().hour().minute()), systemImage: "paperclip")
                            .font(.caption).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RecallPalette.border.opacity(0.25), in: Capsule())
                    }.buttonStyle(.plain).foregroundStyle(RecallPalette.secondary)
                }
            }
            if ids.count > 2 {
                Button { showsSources = true } label: {
                    HStack(spacing: 5) {
                        Text(RecallLocalization.both("另有 \(ids.count - 2) 条来源", "\(ids.count - 2) more sources"))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RecallPalette.border.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).fixedSize()
                    .popover(isPresented: $showsSources, arrowEdge: .bottom) {
                        ChatSourcesPopover(workspace: workspace, citations: Array(ids.dropFirst(2)), onOpen: open)
                    }
            }
        }
    }
    private func open(_ id: UUID) {
        showsSources = false
        // Resolve on click, not from the record snapshot captured when a row was constructed.
        guard let current = workspace.record(id: id) else { return }
        model.sourceToOpen = current
    }
}

/// Bounded rows in a real popover: opening it never constructs a menu of hundreds of OCR summaries.
struct ChatSourcesPopover: View {
    @ObservedObject var workspace: ChatSourcesWorkspace
    let citations: [UUID]
    let onOpen: (UUID) -> Void
    @State private var search = ""
    @State private var page = 0
    @State private var loaded: ChatSourcePage?
    @State private var loadedKey: QueryKey?
    @State private var failed = false
    private struct QueryKey: Hashable, Sendable {
        let revision: UUID
        let citations: [UUID]
        let search: String
        let page: Int
    }
    private var key: QueryKey { QueryKey(revision: workspace.revision, citations: citations, search: search, page: page) }
    private var visible: ChatSourcePage? { loadedKey == key ? loaded : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(RecallLocalization.both("更多来源", "More sources")).font(.headline)
                Spacer()
                Text(RecallLocalization.both("\(workspace.availableIDs(citations).count) 条", "\(workspace.availableIDs(citations).count) sources"))
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            TextField(RecallLocalization.both("搜索标题或应用", "Search titles or apps"), text: $search)
                .textFieldStyle(.roundedBorder)
                .onChange(of: search) { _, _ in page = 0 }
            Divider()
            results
            Divider()
            pagination
        }
        .padding(16).frame(width: 390, height: 430)
        .background(RecallPalette.surface)
        .task(id: key) { await load() }
    }

    @ViewBuilder private var results: some View {
        if let visible {
            if visible.rows.isEmpty {
                Text(RecallLocalization.both("没有匹配的来源", "No matching sources"))
                    .foregroundStyle(RecallPalette.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).id("source-list-top")
                            ForEach(visible.rows) { row in
                                Button { onOpen(row.id) } label: { sourceRow(row) }
                                    .buttonStyle(.plain)
                                if row.id != visible.rows.last?.id { Divider() }
                            }
                        }
                    }
                    .onChange(of: loadedKey) { _, _ in proxy.scrollTo("source-list-top", anchor: .top) }
                }
            }
        } else {
            VStack(spacing: 10) {
                if failed { Text(RecallLocalization.both("来源加载未完成", "Unable to load sources")) }
                else { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sourceRow(_ row: ChatSourceRow) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "doc.text").foregroundStyle(RecallPalette.accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title.isEmpty ? RecallLocalization.text("时间线") : row.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                Text(row.app + " · " + row.createdAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: 11)).foregroundStyle(RecallPalette.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(RecallPalette.secondary)
        }.padding(.vertical, 10).padding(.horizontal, 3).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
    private var pagination: some View {
        HStack(spacing: 10) {
            if let visible {
                Text("\(visible.firstPosition)–\(visible.lastPosition) / \(visible.total)")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                Spacer()
                Button(RecallLocalization.text("上一页")) { page = max(0, visible.page - 1) }.disabled(visible.page == 0)
                Button(RecallLocalization.text("下一页")) { page = visible.page + 1 }.disabled(visible.page + 1 >= visible.pageCount)
            } else { Text(" ").font(.caption); Spacer() }
        }.font(.caption).buttonStyle(.borderless)
    }
    private func load() async {
        let requested = key, snapshot = workspace.snapshot()
        failed = false
        do {
            if !requested.search.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) {
                try snapshot.page(citations: requested.citations, search: requested.search, page: requested.page)
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, key == requested else { return }
            loaded = result; loadedKey = requested
        } catch {
            guard !Task.isCancelled, key == requested else { return }
            failed = true
        }
    }
}

/// Synthetic preview of the same popover, including the hundreds-of-sources case.
struct ChatSourcesPreview: View {
    @StateObject private var workspace = ChatSourcesWorkspace()
    private static let records: [CaptureRecord] = (0..<452).map { index in
        var record = CaptureRecord(eventTemplate: .manualMoment, sourceAppName: index.isMultiple(of: 2) ? "Synthetic Browser" : "Synthetic Chat",
            contentHash: "preview-source-\(index)", ocrText: "合成的来源正文，点击详情后才读取完整记录。")
        record.summary = index.isMultiple(of: 2) ? "Atlas 发布流程核对 \(index + 1)" : "Nova 方案与验收边界 \(index + 1)"
        return record
    }
    var body: some View {
        ChatSourcesPopover(workspace: workspace, citations: Array(Self.records.dropFirst(2).map(\.id)), onOpen: { _ in })
            .onAppear { workspace.update(RecallState(captures: Self.records)) }
    }
}
