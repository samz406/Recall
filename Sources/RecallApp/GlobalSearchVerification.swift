import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private enum SearchFailure: Error { case failed(String) }
    @MainActor private static func waitForGlobalSearch(_ workspace: GlobalSearchWorkspace) async throws {
        for _ in 0..<600 {
            if !workspace.isLoading {
                if let message = workspace.message { throw SearchFailure.failed(message) }
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SearchFailure.failed("全局搜索未在合成验证时限内结束")
    }
    @MainActor static func verifyGlobalSearchWorkspace() async throws {
        let body = String(repeating: "合成的长正文只在检索时匹配，不应反复生成摘要。", count: 400)
        var state = RecallState(captures: (0..<6_351).map { i in
            CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "Synthetic Notes", sourceBundleIdentifier: "synthetic.notes",
                contentHash: "source-\(i)", ocrText: body, summary: "合成记录 \(i)", textOrigin: .userInput)
        })
        state.captures[6_350].ocrText += " CacheTailToken"
        let workspace = GlobalSearchWorkspace()
        workspace.update(state, matters: [])
        workspace.activate()
        guard !workspace.isLoading, workspace.indexBuildCount == 0, workspace.hits.isEmpty else {
            throw SearchFailure.failed("空白打开搜索仍遍历整库并显示加载")
        }
        workspace.setQuery(.init(text: "CacheTailToken"), debounce: false)
        try await waitForGlobalSearch(workspace)
        guard workspace.indexBuildCount == 1, workspace.hits.count == 1 else { throw SearchFailure.failed("首次搜索没有覆盖完整存档") }
        let builds = workspace.indexBuildCount, queries = workspace.resultBuildCount
        let coldBuild = workspace.lastBuildMilliseconds
        workspace.deactivate(); workspace.activate(.init(text: "CacheTailToken"))
        guard !workspace.isLoading, workspace.indexBuildCount == builds, workspace.resultBuildCount == queries else {
            throw SearchFailure.failed("关闭后重开没有复用索引和结果")
        }
        for index in 0..<20 {
            state.messages = [ConversationMessage(role: .user, content: "无关的合成会话更新 \(index)")]
            workspace.update(state, matters: [])
        }
        guard !workspace.isLoading, workspace.indexBuildCount == builds, workspace.hits.count == 1 else {
            throw SearchFailure.failed("无关会话变化重建了搜索")
        }
        // Equal ID, equal count and equal contentHash: corrected text still invalidates the index.
        state.captures[6_350].correctedText = "CorrectedCacheToken 用户修正后的文本"
        workspace.update(state, matters: [])
        guard workspace.hits.isEmpty else { throw SearchFailure.failed("更正后仍展示旧结果") }
        try await waitForGlobalSearch(workspace)
        guard workspace.hits.isEmpty, workspace.indexBuildCount == builds + 1 else {
            throw SearchFailure.failed("同 ID 更正未刷新搜索或仍匹配旧文字")
        }
        workspace.setQuery(.init(text: "CorrectedCacheToken"), debounce: false)
        try await waitForGlobalSearch(workspace)
        guard workspace.hits.count == 1 else { throw SearchFailure.failed("更正后新文字无法搜索") }
        workspace.setQuery(.init(text: "合成"))
        workspace.setQuery(.init(text: "NoMatchingToken"))
        try await waitForGlobalSearch(workspace)
        guard workspace.hits.isEmpty else { throw SearchFailure.failed("较旧查询覆盖了较新查询") }
        workspace.setQuery(.init(text: "CorrectedCacheToken"), debounce: false)
        try await waitForGlobalSearch(workspace)
        state.privacy.excludedBundleIdentifiers = ["synthetic.notes"]
        workspace.update(state, matters: [])
        guard workspace.hits.isEmpty, workspace.sources.isEmpty else { throw SearchFailure.failed("隐私设置变更后旧结果/来源仍可见") }
        try await waitForGlobalSearch(workspace)
        guard workspace.hits.isEmpty else { throw SearchFailure.failed("排除来源重新出现在异步结果中") }
        workspace.deactivate(); workspace.activate()
        guard !workspace.isLoading else { throw SearchFailure.failed("清空筛选后仍保留加载状态") }
        workspace.deactivate()
        print("PASS: native global-search empty open, 6351-record cold build \(coldBuild) ms, warm cache, same-ID correction, query races and privacy invalidation")
    }
}

