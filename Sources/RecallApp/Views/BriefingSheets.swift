import SwiftUI
import RecallKit

private func t(_ chinese: String, _ english: String) -> String { RecallLocalization.both(chinese, english) }

/// Past records related to the window the user was looking at. Opening a row shows the saved source.
struct LastTimeSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let query: LastTimeQuery
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("我上次怎么做的", "How did I do this last time")).font(.title2.bold())
                    Text(query.appName + " · " + query.title).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(2)
                }
                Spacer()
                Button(t("完成", "Done")) { dismiss() }
            }
            Text(t("按当前窗口标题在本机记录中查找，没有截图，也不发送任何内容。", "Matched against saved records by the current window title. Nothing is captured or sent."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            if query.records.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("没有找到相关的记录。", "No related records found.")).font(.headline)
                    Button(t("改用搜索", "Search instead")) { dismiss(); model.showsGlobalSearch = true }
                }.recallSurface()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(query.records) { record in
                            Button { dismiss(); model.sourceToOpen = record } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.userNote ?? record.windowTitle ?? record.summary ?? t("记录", "Record")).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text((record.sourceAppName ?? "") + " · " + record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(RecallPalette.secondary)
                                    Text(String(record.searchableText.prefix(160))).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).recallSurface(padding: 14)
                        }
                    }
                }
            }
        }.padding(26).frame(width: 620, height: 520).background(RecallPalette.background)
    }
}

struct MeetingBriefItem: Identifiable {
    let brief: MeetingBrief
    var id: String { brief.event.key }
}

struct MeetingBriefSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let brief: MeetingBrief
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("会前简报", "Before your meeting")).font(.title2.bold())
                    Text(brief.event.title + " · " + brief.event.start.formatted(date: .omitted, time: .shortened)).font(.callout).foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button(t("完成", "Done")) { dismiss() }
            }
            Text(t("按日程标题和参会人在本机记录中查找，只读日历，不修改日程。", "Matched by event title and attendees against saved records. The calendar is only read."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !brief.openReminders.isEmpty {
                        Text(t("相关的未完成事项", "Related open items")).font(.headline)
                        ForEach(brief.openReminders) { reminder in
                            Button { dismiss(); model.destination = .reminder(reminder.id) } label: { Label(reminder.title, systemImage: "bell") }.buttonStyle(.plain)
                        }
                    }
                    Text(t("相关记录", "Related records")).font(.headline)
                    ForEach(brief.records) { record in
                        Button { dismiss(); model.sourceToOpen = record } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.userNote ?? record.windowTitle ?? record.summary ?? t("记录", "Record")).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text((record.sourceAppName ?? "") + " · " + record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(RecallPalette.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).recallSurface(padding: 12)
                    }
                }
            }
        }.padding(26).frame(width: 600, height: 520).background(RecallPalette.background)
    }
}

/// The user's one line about why a record matters. Shown and editable in record details.
struct CaptureNoteEditor: View {
    @EnvironmentObject private var model: RecallAppModel
    let capture: CaptureRecord
    @State private var editing = false
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("备注", "Note")).font(.subheadline.weight(.semibold))
            if editing {
                TextField(t("为什么存这条？", "Why keep this?"), text: $text).textFieldStyle(.roundedBorder).onSubmit(save)
                HStack {
                    Button(t("保存", "Save"), action: save).buttonStyle(.borderedProminent)
                    Button(t("取消", "Cancel")) { editing = false }
                    if capture.userNote != nil { Button(t("删除备注", "Remove note"), role: .destructive) { model.setNote(capture.id, note: nil); editing = false } }
                }
            } else {
                HStack(alignment: .top) {
                    Text(capture.userNote ?? t("还没有备注。一句话说明为什么存这条，回顾和搜索会更准。", "No note yet. One line about why this matters makes reviews and search more accurate."))
                        .font(.callout).foregroundStyle(capture.userNote == nil ? RecallPalette.secondary : RecallPalette.text)
                    Spacer()
                    Button(capture.userNote == nil ? t("添加", "Add") : t("编辑", "Edit")) { text = capture.userNote ?? ""; editing = true }
                }
            }
            if let url = capture.pageURL {
                HStack(spacing: 6) {
                    Image(systemName: "link").foregroundStyle(RecallPalette.secondary)
                    Link(url, destination: URL(string: url) ?? URL(string: "about:blank")!).font(.caption).lineLimit(1)
                }
            }
        }.recallSurface(padding: 14)
    }
    private func save() { model.setNote(capture.id, note: text); editing = false }
}
