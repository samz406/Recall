import SwiftUI
import RecallKit

/// Fixed header outside the clipped scroll view, shared by all three memory views.
struct MatterWorkspaceView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var tab = 0
    @State private var search = ""
    @State private var visibleCount = 20
    @State private var selected: MatterFile?
    @State private var source: CaptureRecord?
    @State private var correctionEvent: MatterEvent?
    let continueChat: (String) -> Void

    private var files: [MatterFile] {
        model.matterFiles.filter { search.isEmpty || ($0.title + $0.latest.detail).localizedCaseInsensitiveContains(search) }
    }
    private var resumeFiles: [MatterFile] { files.filter { [.progressed, .pending, .blocked].contains($0.latest.status) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("我的事情").font(.largeTitle.bold())
                    Text("找回上次的进展，看清这周的变化。所有内容都能回到原始记录。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBuildingMatters { ProgressView().controlSize(.small) }
            }.padding(24)
            HStack {
                Picker("查看", selection: $tab) {
                    Text("接着上次做").tag(0)
                    Text("事情档案").tag(1)
                    Text("最近七天").tag(2)
                    Text("纠错记录").tag(3)
                }.pickerStyle(.segmented).frame(maxWidth: 560)
                Spacer()
                TextField("搜索事情", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }.padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if tab == 0 {
                        if resumeFiles.isEmpty { empty("暂时没有可以继续的事情", detail: "记录具体事情后，这里会整理上次的进展；不会把浏览内容强行变成待办。") }
                        ForEach(Array(resumeFiles.prefix(visibleCount))) { file in
                            fileCard(file, resume: true)
                        }
                        more(total: resumeFiles.count)
                        Toggle("在这里提示相关的历史经验", isOn: Binding(get: { model.state.experienceHintsEnabled }, set: { model.setExperienceHints($0) }))
                            .padding(.top, 8)
                        Text("开启后，每次最多显示一条有独立来源的相关结果。仅在本页显示，不发送系统通知。")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.state.experienceHintsEnabled, let hint = model.experienceHint {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("以前的结果，也许能帮上忙", systemImage: "sparkles").font(.headline).foregroundStyle(.purple)
                                Text(hint.past.detail).textSelection(.enabled)
                                Text("相关主题：\(hint.matchingTerms.joined(separator: "、"))。当时的条件可能不同，请先查看来源。")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("查看当时记录") { source = model.state.captures.first { hint.past.evidenceIDs.contains($0.id) } }
                                    Button("不再提示这一条") { model.dismissExperience(hint.id) }
                                }
                            }.padding(20).background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                        }
                    } else if tab == 1 {
                        if files.isEmpty { empty("还没有匹配的事情档案", detail: "仅将有具体主题和来源的记录串联；原始内容仍可在时间线查看。") }
                        ForEach(Array(files.prefix(visibleCount))) { file in fileCard(file, resume: false) }
                        more(total: files.count)
                    } else if tab == 2 {
                        let reviews = MatterMemoryEngine().weeklyReview(files: files)
                        Text("按事情比较最近七天与更早的记录；记录时间不一定是实际发生时间，可在档案中更正。")
                            .foregroundStyle(.secondary)
                        if reviews.isEmpty { empty("这七天还没有可回顾的事情", detail: "没有记录不代表没有进展。") }
                        ForEach(Array(reviews.prefix(visibleCount))) { review in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(review.matter.title).font(.title3.bold())
                                if let previous = review.previous {
                                    Text("更早的记录").font(.caption).foregroundStyle(.secondary)
                                    Text(previous.detail)
                                } else { Text("这次首次记录到").font(.caption).foregroundStyle(.secondary) }
                                ForEach(review.changes) { change in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(change.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                        Text(change.detail).textSelection(.enabled)
                                    }
                                }
                                Button("查看事情档案") { selected = review.matter }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
                        }
                        more(total: reviews.count)
                    } else {
                        if model.state.matterCorrections.isEmpty { empty("暂无纠错记录", detail: "在事情档案中查看来源后，可以更正归属、完成状态、分类或发生时间。") }
                        ForEach(Array(model.state.matterCorrections.reversed().prefix(visibleCount))) { correction in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(correction.kind.title).font(.headline)
                                if !correction.text.isEmpty { Text(correction.text) }
                                Text("\(correction.createdAt.formatted()) · \(correction.evidenceIDs.count) 条来源").foregroundStyle(.secondary)
                                Button("删除这条纠错记录") { model.removeMatterCorrection(correction.id) }
                                Text("删除后将重新使用原始证据；已经完成的提醒不会自动恢复。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(18)
                        }
                        more(total: model.state.matterCorrections.count)
                    }
                }.padding(24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.clipped()
        }
        .onChange(of: tab) { _, _ in visibleCount = 20 }
        .onChange(of: search) { _, _ in visibleCount = 20 }
        .sheet(item: $selected) { file in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.title).font(.title2.bold())
                        Text("按记录串联；未明确说明的负责人和发生时间不作推测。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { selected = nil }
                }.padding(24)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(file.events.reversed()) { event in
                            VStack(alignment: .leading, spacing: 10) {
                                Text((event.eventAt == nil ? "记录于 " : "发生于 ") + event.date.formatted())
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(event.detail).textSelection(.enabled)
                                HStack {
                                    Menu("查看来源（\(event.evidenceIDs.count)）") {
                                        ForEach(model.state.captures.filter { event.evidenceIDs.contains($0.id) }) { capture in
                                            Button((capture.sourceAppName ?? "记录") + " · " + capture.createdAt.formatted()) { source = capture }
                                        }
                                    }
                                    Button("纠正这条内容") { correctionEvent = event }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }.padding(24)
                }
                Button("围绕这件事继续问") {
                    selected = nil
                    continueChat("关于\(file.title)，上次进展是什么？有哪些已确认的结论和仍未知的信息？")
                }.buttonStyle(.borderedProminent).padding(24)
            }.frame(minWidth: 650, idealWidth: 820, minHeight: 500, idealHeight: 720)
                .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
                .sheet(item: $correctionEvent) { event in
                    MatterCorrectionSheet(event: event) { correction in
                        model.correctMatter(correction)
                        correctionEvent = nil
                        selected = nil
                    }
                }
        }
        .sheet(item: Binding(get: { selected == nil ? source : nil }, set: { source = $0 })) {
            CaptureDetailSheet(capture: $0).environmentObject(model)
        }
    }

    private func fileCard(_ file: MatterFile, resume: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(file.title).font(.title3.bold())
                Spacer()
                Text(file.latest.status == .completed ? "记录为已完成" : "上次进展")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(resume ? file.resumeText : file.latest.detail).textSelection(.enabled)
            Text("最近记录 \(file.latest.recordedAt.formatted(date: .abbreviated, time: .omitted)) · \(file.events.count) 段进展")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("查看档案") { selected = file }
                if resume {
                    Button("接着问") { continueChat("关于\(file.title)，请找回上次的进展、已确认的结论和仍缺少的信息。") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.blue)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary)
        }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func more(total: Int) -> some View {
        if total > visibleCount { Button("再显示 20 条") { visibleCount += 20 } }
    }
}

private struct MatterCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let event: MatterEvent
    let save: (MatterCorrection) -> Void
    @State private var kind: MatterCorrectionKind = .inaccurate
    @State private var text = ""
    @State private var eventDate = Date.now
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("纠正这条内容").font(.title2.bold())
            Text(event.detail).lineLimit(5).foregroundStyle(.secondary)
            Picker("如何更正", selection: $kind) {
                ForEach(MatterCorrectionKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if kind == .separate { TextField("这件事的名称", text: $text).textFieldStyle(.roundedBorder) }
            if kind == .eventDate { DatePicker("实际发生时间", selection: $eventDate) }
            Text("更正作用于这段内容关联的 \(event.evidenceIDs.count) 条来源。原始记录保留。“不是我说的”和“结论不准确”会停止用这些来源推断；已安排的提醒只有选择“已经完成”才会关闭。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存更正") {
                    save(MatterCorrection(evidenceIDs: event.evidenceIDs, kind: kind, text: kind == .completed ? event.title : text, eventAt: kind == .eventDate ? eventDate : nil))
                }.buttonStyle(.borderedProminent)
                    .disabled(kind == .separate && text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            }
        }.padding(28).frame(width: 560)
    }
}
