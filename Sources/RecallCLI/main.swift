import Foundation
import RecallKit

// recall-cli: batch maintenance for an existing Recall data directory.
//   summarize  Regenerate the daily review for every day that has records, in the structured format.
// Nothing is changed or sent anywhere unless --apply is given. The API key is read from the data directory's own
// settings and is never printed.

struct Options {
    var command = ""
    var dataDir: URL?
    var apply = false
    var from: Date?
    var to: Date?
    var onlyMissing = false
    var limit: Int?
    var assumeYes = false
}

func usage() -> Never {
    print("""
    用法：recall-cli summarize [选项]

      summarize   对每一天有记录的日期重新生成每日回顾（结构化格式，旧版本保留）。需要模型，会发送脱敏文本。

    选项：
      --data-dir <路径>   数据目录（默认 ~/Library/Application Support/Recall）。在另一台电脑上指向那边的目录。
      --from <日期>       只处理该日期（含）之后，格式 2026-10-01
      --to <日期>         只处理该日期（含）之前
      --only-missing      跳过已有结构化回顾的日期
      --limit <N>         最多处理 N 天（按日期从新到旧）
      --apply             真正执行。不带此参数只预览，不改任何数据、不调用模型。
      --yes               跳过执行前的确认提示
    """)
    exit(2)
}

func parseDate(_ text: String) -> Date? {
    let f = DateFormatter(); f.calendar = Calendar.current; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
    return f.date(from: text)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let first = arguments.first, first == "summarize" else { usage() }
    options.command = first; arguments.removeFirst()
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        func value() -> String { index += 1; guard index < arguments.count else { usage() }; return arguments[index] }
        switch flag {
        case "--data-dir": options.dataDir = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath, isDirectory: true)
        case "--from": guard let d = parseDate(value()) else { print("日期格式应为 2026-10-01"); exit(2) }; options.from = Calendar.current.startOfDay(for: d)
        case "--to": guard let d = parseDate(value()) else { print("日期格式应为 2026-10-01"); exit(2) }
            options.to = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: d))
        case "--only-missing": options.onlyMissing = true
        case "--limit": guard let n = Int(value()), n > 0 else { usage() }; options.limit = n
        case "--apply": options.apply = true
        case "--yes": options.assumeYes = true
        default: usage()
        }
        index += 1
    }
    return options
}
let options = parseOptions()

func say(_ text: String) { print(text); fflush(stdout) }

func confirm(_ question: String) -> Bool {
    if options.assumeYes { return true }
    print(question + " [y/N] ", terminator: ""); fflush(stdout)
    return (readLine() ?? "").lowercased().hasPrefix("y")
}

/// One dated copy of the state file before the first write of a run, so a run can always be rolled back by hand.
nonisolated(unsafe) var backedUp = false
func backupOnce(_ storage: RecallStorage) throws {
    guard options.apply, !backedUp else { return }
    backedUp = true
    let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
    let backup = storage.rootURL.appendingPathComponent("recall-state.backup-\(stamp).json")
    try FileManager.default.copyItem(at: storage.stateURL, to: backup)
    say("已备份状态文件：\(backup.lastPathComponent)")
}

func dayStart(_ date: Date) -> Date { Calendar.current.startOfDay(for: date) }

func runSummarize(_ store: FileMemoryStore, _ storage: RecallStorage) async throws {
    say("— 重新生成每日回顾 —")
    var state = await store.snapshot()
    let calendar = Calendar.current
    let excluded = state.privacy.excludedBundleIdentifiers
    var days = Set<Date>()
    for capture in state.captures where capture.eventTemplate != .dailyReview && capture.isMemoryEvidenceArchive != true && capture.memoryDirective == nil
        && !excluded.contains(capture.sourceBundleIdentifier ?? "") && !capture.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let day = dayStart(capture.createdAt)
        if let from = options.from, day < from { continue }
        if let to = options.to, day >= to { continue }
        days.insert(day)
    }
    let structured = Set(state.dailySummaries.filter { $0.items.contains { $0.knowledge != nil } }.map { dayStart($0.day) })
    var ordered = days.sorted(by: >)
    if options.onlyMissing { ordered.removeAll { structured.contains($0) } }
    if let limit = options.limit { ordered = Array(ordered.prefix(limit)) }
    ordered.sort()
    let today = dayStart(.now)
    let counts = Dictionary(grouping: state.captures, by: { dayStart($0.createdAt) }).mapValues(\.count)
    say("有记录的日期 \(days.count) 天；已有结构化回顾 \(days.intersection(structured).count) 天；本次将处理 \(ordered.count) 天。")
    if ordered.count > 0 {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        say("日期：" + ordered.map { f.string(from: $0) + ($0 == today ? "(今天,未结束)" : "") + "·\(counts[$0] ?? 0)条" }.joined(separator: "  "))
    }
    let provider = state.llmConfiguration.provider
    say("模型：\(provider == .localOnly ? "未配置（仅本地）" : state.llmConfiguration.model)；允许发送脱敏文本：\(state.privacy.cloudUseEnabled ? "是" : "否")；密钥：\(state.llmConfiguration.apiKey.isEmpty ? "未配置" : "已配置（不显示）")。")
    guard options.apply else { say("预览结束：未调用模型、未改动数据。加 --apply 执行（每天一次模型调用）。"); return }
    guard state.privacy.cloudUseEnabled, provider != .localOnly, !state.llmConfiguration.apiKey.isEmpty else {
        say("无法执行：这个数据目录里没有可用的模型配置，或未允许发送脱敏文本。请先在那台电脑的应用里配置模型并开启云端使用。"); exit(1)
    }
    guard !ordered.isEmpty else { say("没有需要处理的日期。"); return }
    guard confirm("将向 \(state.llmConfiguration.baseURLString) 发送 \(ordered.count) 天的脱敏文本。继续？") else { say("已取消。"); return }
    try backupOnce(storage)
    let responder = CompatibleLLM(configuration: state.llmConfiguration, apiKey: state.llmConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    var succeeded = 0, failed: [(Date, String)] = []
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    for (offset, day) in ordered.enumerated() {
        let end = min(calendar.date(byAdding: .day, value: 1, to: day) ?? day, .now)
        let period = ReviewPeriod(start: day, end: end, timeZoneIdentifier: calendar.timeZone.identifier)
        let started = Date.now
        do {
            let outcome = try await store.generateDirectDailyReview(day: day, period: period, responder: responder)
            succeeded += 1
            say("[\(offset + 1)/\(ordered.count)] \(f.string(from: day)) 完成：\(outcome.metrics.detail)")
        } catch {
            let reason = ReviewProcessingDiagnostics.reason(for: error)
            failed.append((day, ReviewProcessingDiagnostics.code(for: error)))
            say("[\(offset + 1)/\(ordered.count)] \(f.string(from: day)) 失败（\(ReviewProcessingDiagnostics.code(for: error))）：\(reason)；用时 \(Int(Date.now.timeIntervalSince(started))) 秒，已有回顾保持不变。")
        }
    }
    // Derived views (topics, long-term memory) are rebuilt once at the end.
    try await store.organizeMemory(force: true)
    state = await store.snapshot()
    say("完成：成功 \(succeeded) 天，失败 \(failed.count) 天。失败的日期可以再次运行（加 --only-missing 只补缺）。")
    if !failed.isEmpty { say("失败：" + failed.map { f.string(from: $0.0) + "[\($0.1)]" }.joined(separator: "  ")) }
}

let storage: RecallStorage
do {
    if let dataDir = options.dataDir {
        guard FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("recall-state.json").path) else {
            say("在 \(dataDir.path) 里没有找到 recall-state.json。"); exit(1)
        }
        storage = try RecallStorage(rootURL: dataDir)
    } else { storage = try RecallStorage() }
    guard FileManager.default.fileExists(atPath: storage.stateURL.path) else { say("没有找到数据：\(storage.stateURL.path)"); exit(1) }
    say("数据目录：\(storage.rootURL.path)")
    let store = try FileMemoryStore(storage: storage)
    try await runSummarize(store, storage)
} catch {
    say("出错：\(error.localizedDescription)")
    exit(1)
}
