import SwiftUI
import RecallKit

struct TopicNextStepSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    private enum Field: Hashable { case topic, step }

    let file: MatterFile?
    var previous: String? = nil
    @State private var title = ""
    @State private var step = ""
    @State private var saving = false
    @State private var failed = false

    private var note: ManualMatterNote {
        if let file { return ManualMatterNote(nextStep: step, for: file) }
        return ManualMatterNote(nextStep: step, starting: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(RecallLocalization.both("给下次留一步", "Leave a next step")).font(.title2.bold())
            if let file {
                Text(file.title).font(.headline).foregroundStyle(RecallPalette.secondary)
            } else {
                TextField(RecallLocalization.both("主题名称（3–80 字）", "Topic name (3–80 characters)"), text: $title)
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .topic)
                    .onSubmit { focus = .step }
            }
            TextField(RecallLocalization.both("下次打开时，先做哪一步？", "Where do you want to start next time?"), text: $step, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).focused($focus, equals: .step)
            Text(RecallLocalization.both("保存后会出现在「今天」，也会留在这个主题的记录里。", "Your next step will appear in Today and in this topic’s history."))
                .font(.callout).foregroundStyle(RecallPalette.secondary)
            if step.count > 4000 { Text(RecallLocalization.both("最多 4000 字", "Up to 4,000 characters")).foregroundStyle(RecallPalette.danger) }
            if failed { Text(RecallLocalization.both("保存失败，文字已保留，可以重试。", "Couldn’t save. Your draft is here to retry.")).foregroundStyle(RecallPalette.danger) }
            HStack {
                Spacer()
                Button(RecallLocalization.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? RecallLocalization.both("保存中…", "Saving…") : RecallLocalization.text("保存")) { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!note.isValid || note.detail == previous)
            }
        }
        .padding(24).frame(width: 460).disabled(saving).interactiveDismissDisabled(saving)
        .onAppear { step = previous ?? ""; focus = file == nil ? .topic : .step }
    }

    private func save() {
        let submitted = note
        guard !saving, submitted.isValid, submitted.detail != previous else { return }
        saving = true
        failed = false
        Task {
            if await model.saveManualMatter(submitted) { dismiss() } else { failed = true }
            saving = false
        }
    }
}
