import Foundation
import RecallKit

enum ChatSourceIndexVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(errorDescription: message) }
    }
    static func run() async throws {
        try citationsAndPages(); try largeArchive(); try await cancellation()
        print("PASS: 3 chat-source suites (citation identity/order, bounded pages/search, large OCR archive and cancellation)")
    }
    static func records(_ count: Int) -> [CaptureRecord] {
        let text = String(repeating: "合成原始记录保留完整证据，不应在打开来源列表时重新概括。", count: 500)
        return (0..<count).map { i in
            var record = CaptureRecord(eventTemplate: .manualMoment, sourceAppName: i.isMultiple(of: 2) ? "Synthetic Browser" : "Synthetic Chat",
                sourceBundleIdentifier: "synthetic.app", contentHash: "source-\(i)", ocrText: text)
            record.summary = "合成来源 \(i)"
            return record
        }
    }
    private static func citationsAndPages() throws {
        var records = Self.records(452); records[451].summary = "Needle 最后一条来源"
        let index = ChatSourceIndex(captures: records), ids = records.map(\.id)
        try expect(index.availableIDs([ids[4], UUID(), ids[1], ids[4]]) == [ids[4], ids[1]], "引用顺序、去重或删除过滤不正确")
        let first = try index.page(citations: ids)
        try expect(first.rows.count == 20 && first.total == 452 && first.pageCount == 23 && first.rows.map(\.id) == Array(ids.prefix(20)), "首次加载不受页数限制或漏了来源")
        let last = try index.page(citations: ids, page: 999)
        try expect(last.page == 22 && last.rows.count == 12 && last.lastPosition == 452, "无法查看末页来源")
        let search = try index.page(citations: ids, search: "needle")
        try expect(search.total == 1 && search.rows.first?.id == ids[451], "搜索只覆盖当前页")
        let app = try index.page(citations: ids, search: "browser")
        try expect(app.total == 226 && app.rows.count == 20, "应用筛选丢失或一次加载全部")
        let empty = try index.page(citations: [], page: Int.max)
        try expect(empty.total == 0 && empty.firstPosition == 0 && empty.rows.isEmpty, "空列表页边界不正确")
        var long = records[0]; long.summary = String(repeating: "长标题", count: 10_000)
        let bounded = try ChatSourceIndex(captures: [long]).page(citations: [long.id])
        try expect(bounded.rows[0].title.count <= 97 && index.record(id: ids[0])?.ocrText == records[0].ocrText, "列表标题不受限或改写了原始证据")
    }
    private static func largeArchive() throws {
        let records = Self.records(6_351), started = Date.now
        let index = ChatSourceIndex(captures: records), ids = Array(records.suffix(452).map(\.id))
        let built = Date.now
        var total = 0
        for page in 0..<23 {
            let result = try index.page(citations: ids, page: page)
            try expect(result.rows.count <= 20, "列表无界创建条目")
            total += result.rows.count
        }
        try expect(total == 452, "分页未完整保留所有来源")
        print("PERF: chat-source 6351-record index \(Int(built.timeIntervalSince(started) * 1000)) ms; 452 sources across 23 pages \(Int(Date.now.timeIntervalSince(built) * 1000)) ms (synthetic, not a device latency guarantee)")
    }
    private static func cancellation() async throws {
        let records = Self.records(500), index = ChatSourceIndex(captures: records), ids = records.map(\.id)
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try index.page(citations: ids, search: "Browser")
        }
        task.cancel()
        do { _ = try await task.value; throw Failure(errorDescription: "关闭或更换查询后搜索没有取消") }
        catch is CancellationError {}
    }
}
