import Foundation
import RecallKit
import AppKit
import SwiftUI

extension RecallLayoutPreviews {
    @MainActor static func verifyTimelineLoading() async throws {
        let calendar = Calendar.current, day = calendar.startOfDay(for: .now)
        let records = (0..<6_351).map { offset in
            CaptureRecord(eventTemplate: .manualMoment, createdAt: day.addingTimeInterval(86_000 - Double(offset * 10)),
                          sourceAppName: offset.isMultiple(of: 2) ? "Synthetic Chat" : "Synthetic Browser",
                          contentHash: String(offset), ocrText: "合成验收记录 Atlas \(offset)")
        }
        let workspace = TimelineWorkspace(), start = Date.now
        workspace.update(captures: records)
        try await waitForTimeline(workspace)
        let initialBuilds = workspace.indexBuildCount, resultBuilds = workspace.resultBuildCount
        let originalIDs = workspace.result.captures.map(\.id)
        guard !originalIDs.isEmpty else { throw TimelineLoadingFailure.failed("首屏为空") }
        for _ in 0..<30 { workspace.update(captures: records) }
        guard workspace.indexBuildCount == initialBuilds, workspace.resultBuildCount == resultBuilds,
              !workspace.isLoading, workspace.result.captures.map(\.id) == originalIDs else {
            throw TimelineLoadingFailure.failed("菜单切换或无关快照触发了重复构建")
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: day)!
        workspace.query.day = yesterday; try await waitForTimeline(workspace)
        workspace.query.day = day
        guard !workspace.isLoading, workspace.result.captures.map(\.id) == originalIDs else {
            throw TimelineLoadingFailure.failed("回到已访问日期没有立即复用结果")
        }
        workspace.query.searchAllDates = true; workspace.query.searchText = "Browser"
        workspace.query.searchText = "Atlas"; workspace.query.source = "Synthetic Browser"
        try await waitForTimeline(workspace)
        guard workspace.result.captures.count == 3_175,
              workspace.result.captures.allSatisfy({ $0.sourceAppName == "Synthetic Browser" }) else {
            throw TimelineLoadingFailure.failed("旧搜索覆盖了新筛选")
        }
        let retained = [records[1]]
        workspace.update(captures: retained)
        guard workspace.result.captures.isEmpty else { throw TimelineLoadingFailure.failed("删除时仍展示过期缓存") }
        try await waitForTimeline(workspace)
        guard workspace.result.captures.map(\.id) == retained.map(\.id) else { throw TimelineLoadingFailure.failed("删除后结果未更新") }
        var corrected = retained; corrected[0].summary = "经过用户纠正的合成说明"
        workspace.update(captures: corrected); try await waitForTimeline(workspace)
        guard workspace.result.captures.first?.summary == corrected[0].summary else { throw TimelineLoadingFailure.failed("同 ID 更正未刷新") }
        let model = RecallAppModel(previewState: RecallState())
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        model.state.captures = records
        try await waitForTimeline(model.timelineWorkspace)
        let buildCount = model.timelineWorkspace.indexBuildCount
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        for page in ["timeline", "chat", "timeline"] {
            let host = NSHostingView(rootView: RecallRootView.previewPage(page).environmentObject(model)
                .frame(width: 1050, height: 740))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        guard model.timelineWorkspace.indexBuildCount == buildCount, !model.timelineWorkspace.isLoading else {
            throw TimelineLoadingFailure.failed("实际页面切换丢失了已准备的时间线")
        }
        print("PASS: native timeline 6351-record loading, menu/date reuse, search races, deletion and correction; total \(Int(Date.now.timeIntervalSince(start) * 1_000)) ms")
    }
    @MainActor private static func waitForTimeline(_ workspace: TimelineWorkspace) async throws {
        for _ in 0..<1_000 {
            if !workspace.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimelineLoadingFailure.failed("时间线合成验收超时")
    }
    private enum TimelineLoadingFailure: Error { case failed(String) }
}
