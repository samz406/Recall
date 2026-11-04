import Foundation
import AppKit
import SwiftUI
import RecallKit

extension RecallLayoutPreviews {
    private enum ChatSourceFailure: Error { case failed(String) }
    @MainActor static func verifyChatSources() async throws {
        let records: [CaptureRecord] = (0..<6_351).map { i in
            var row = CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "Synthetic Browser",
                sourceBundleIdentifier: "synthetic.browser", contentHash: "source-\(i)", ocrText: "原始合成来源 \(i)")
            row.summary = "合成来源标题 \(i)"; return row
        }
        let ids = Array(records.suffix(452).map(\.id)), workspace = ChatSourcesWorkspace()
        var state = RecallState(captures: records)
        workspace.update(state)
        let builds = workspace.buildCount, revision = workspace.revision
        for i in 0..<30 {
            state.messages = [ConversationMessage(role: .user, content: "无关的合成消息 \(i)")]
            workspace.update(state)
            guard workspace.availableIDs(ids) == ids else { throw ChatSourceFailure.failed("重复刷新丢失引用") }
        }
        guard workspace.buildCount == builds, workspace.revision == revision else { throw ChatSourceFailure.failed("无关消息变化重建了来源索引") }
        let correctedID = ids[0], slot = state.captures.firstIndex { $0.id == correctedID }!
        state.captures[slot].summary = "用户更正后的来源标题"
        workspace.update(state)
        let updated = try workspace.snapshot().page(citations: ids)
        guard updated.rows.first?.title == "用户更正后的来源标题", workspace.revision != revision else {
            throw ChatSourceFailure.failed("同 ID 更正未失效来源缓存")
        }
        let priorSnapshot = workspace.snapshot()
        state.captures.removeAll { $0.id == correctedID }; workspace.update(state)
        guard workspace.record(id: correctedID) == nil, !workspace.availableIDs(ids).contains(correctedID),
              priorSnapshot.record(id: correctedID) != nil else { throw ChatSourceFailure.failed("删除后仍可通过缓存打开来源") }
        state.privacy.excludedBundleIdentifiers.insert("synthetic.browser"); workspace.update(state)
        guard workspace.availableIDs(ids).isEmpty else { throw ChatSourceFailure.failed("来源设置变化后缓存仍可访问") }

        let firstPhase = ChatThinkingWave.heights(phase: 0), nextPhase = ChatThinkingWave.heights(phase: 0.2)
        guard firstPhase.count == 5, firstPhase != nextPhase,
              (firstPhase + nextPhase).allSatisfy({ $0.isFinite && (4...13).contains($0) }) else { throw ChatSourceFailure.failed("波形不是连续、有界的五段状态") }
        let model = try RecallAppModel(previewState: RecallState())
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        model.state = RecallState(captures: Array(records.suffix(452)))
        let host = NSHostingView(rootView: ChatSourcesPopover(workspace: model.chatSources, citations: ids, onOpen: { _ in })
            .environmentObject(model).recallColors().frame(width: 430, height: 470))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let start = Date.now
        window.contentView = host; window.makeKeyAndOrderFront(nil); host.layoutSubtreeIfNeeded()
        let firstFrame = Int(Date.now.timeIntervalSince(start) * 1000)
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard host.bitmapImageRepForCachingDisplay(in: host.bounds) != nil else { throw ChatSourceFailure.failed("来源弹层未能显示") }
        model.isThinking = true; model.stopChat()
        guard !model.isThinking else { throw ChatSourceFailure.failed("取消回答仍保留忙碌状态") }
        print("PASS: native chat-source cache reuse, same-ID correction, deletion/privacy invalidation, waveform and 452-source popover; first synthetic frame \(firstFrame) ms")
    }
}
