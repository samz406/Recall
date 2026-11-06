import SwiftUI
import RecallKit

enum RecallTypography {
    static let page = Font.system(size: 24, weight: .semibold)
    static let title = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 13)
}

struct RecallFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(RecallLocalization.text(title)).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .foregroundStyle(selected ? RecallPalette.accent : RecallPalette.secondary)
                .background(selected ? RecallPalette.selected : RecallPalette.border.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RecallStatusBadge: View {
    let title: String
    var warning = false
    var body: some View {
        Text(RecallLocalization.text(title)).font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(warning ? RecallPalette.warning : RecallPalette.accent)
            .background((warning ? RecallPalette.warning : RecallPalette.accent).opacity(0.10), in: Capsule())
    }
}

struct RecallListChoice: View {
    let title: String
    let detail: String
    let selected: Bool
    var warning: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(RecallLocalization.text(title)).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    if let warning { RecallStatusBadge(title: warning, warning: true) }
                }
                Text(RecallLocalization.text(detail)).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
                .foregroundStyle(RecallPalette.text)
                .background(selected ? RecallPalette.selected.opacity(0.7) : RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? RecallPalette.accent : RecallPalette.border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RecallSwitchRow: View {
    let title: String
    var detail: String = ""
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(RecallLocalization.text(title)).font(.system(size: 14, weight: .medium))
                if !detail.isEmpty { Text(RecallLocalization.text(detail)).font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
        }.frame(maxWidth: .infinity)
    }

}

extension View {
    func recallSurface(padding: CGFloat = 20) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecallPalette.border, lineWidth: 1))
    }
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
            Text(RecallLocalization.text(title)).font(RecallTypography.page)
            Text(RecallLocalization.text(subtitle)).font(.subheadline).foregroundStyle(RecallPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 220, alignment: .leading)
    }
}

struct RecallTaskStatusView: View {
    @EnvironmentObject private var model: RecallAppModel
    let task: RecallTaskStatus
    var cancel: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if task.isRunning { ProgressView().controlSize(.small).frame(width: 22, height: 22) }
            else { Image(systemName: symbol).foregroundStyle(task.state == .failed ? RecallPalette.warning : RecallPalette.accent) }
            VStack(alignment: .leading, spacing: 5) {
                Text(task.kind + " · " + task.target).font(.subheadline.weight(.medium))
                Text(task.phase).font(.callout).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
                if let detail = task.detail, !detail.isEmpty {
                    DisclosureGroup(RecallLocalization.text("处理详情")) {
                        Text(RecallLocalization.text(detail)).font(.caption).foregroundStyle(RecallPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 4)
                    }.font(.caption).foregroundStyle(RecallPalette.secondary)
                }
            }
            Spacer(minLength: 8)
            if task.isRunning, let cancel {
                Button(task.isCancelling ? "取消中…" : "取消", action: cancel).disabled(task.isCancelling)
            }
            if model.canRetryTask(task) {
                Button(RecallLocalization.text("重试")) { model.retryTask(task.id) }
                    .disabled(model.isGeneratingDailySummary || model.isGeneratingWeeklyReview || model.generatingTopicID != nil)
            }
        }.padding(16).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
    }
    private var symbol: String {
        switch task.state {
        case .running: "clock"
        case .cancelling: "xmark.circle"
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
            HStack {
                Text(RecallLocalization.text("最近的处理结果")).font(.headline)
                Spacer()
                Button(RecallLocalization.text("反馈记录")) { model.showsSummaryFeedbackHistory = true }
            }
            Text(RecallLocalization.text("保留本次打开应用后的任务；切换页面不会中断生成。"))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.tasks.isEmpty { Text(RecallLocalization.text("暂时没有任务")).foregroundStyle(RecallPalette.secondary) }
                    ForEach(model.tasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            RecallTaskStatusView(task: task)
                            if let target = task.destination {
                                Button(RecallLocalization.text("查看结果")) { model.destination = target }
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
            RecallPageHeader(title: "内容依据", subtitle: title) { Button(RecallLocalization.text("完成")) { dismiss() } }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    let sources = model.state.captures.filter { ids.contains($0.id) }
                    if sources.isEmpty { Text(RecallLocalization.text("来源已删除或不再可用。")) }
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 10) {
                            Text((source.sourceAppName ?? "记录") + " · " + source.createdAt.formatted()).font(.caption).foregroundStyle(RecallPalette.secondary)
                            Text(source.ocrText).font(RecallTypography.body).textSelection(.enabled)
                            HStack {
                                Button(RecallLocalization.text("在时间线定位")) { dismiss(); model.destination = .record(source.id) }
                                Menu(RecallLocalization.text("更正这条记录")) {
                                    Button(RecallLocalization.text("不是我说的")) { model.correctMatter(MatterCorrection(evidenceIDs: [source.id], kind: .notMine)); dismiss() }
                                    Button(RecallLocalization.text("内容不准确")) { model.correctMatter(MatterCorrection(evidenceIDs: [source.id], kind: .inaccurate)); dismiss() }
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
