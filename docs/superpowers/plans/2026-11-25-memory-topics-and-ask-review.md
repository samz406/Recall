# 记忆主题与问一问优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/memory-topics-and-ask-review.md` 落地阶段 0–8：问一问提速与上下文统一、主题列表瘦身、主题身份与名字分离（登记表、生命周期、项目层级）。

**Architecture:** 先做不改行为的工程修复和纯 UI 调整，再改每日回顾提示词与归并（别名），再减少模型调用次数，最后引入 `TopicRegistry` 持久化登记表、`ConversationSession` 结构化会话和项目层级。所有新数据是 `RecallState` 的可选字段，旧存档解码为空值，保证向后兼容。

**Tech Stack:** Swift 6.2 / SwiftPM、SwiftUI + AppKit、`RecallKit`（核心）、`Verification/`（`swift run RecallVerifier` 集成验证器，无 XCTest）。

## Global Constraints

- 项目三个不变式：用户明确触发、敏感数据最小化、结果可以删除和追溯（`AGENTS.md`）。
- 不新增默认连续采集、音频录制、自动外发；新增模型调用能力必须有暂停、关闭、删除和失败回退路径。
- 发给云端模型的只能是与当前任务相关且最小化的文本片段；传给每日回顾的已有主题只含「名字（以及阶段 6 的 id）」，不含原文。
- 仓库中不得出现真实截图、真实 OCR 文本、个人数据、密钥；验证夹具全部用合成文本。
- 验证命令（核心改动后）：`swift build --jobs 1` 与 `swift run RecallVerifier`。
- UI 改动、ScreenCaptureKit、Vision、UserNotifications 需在装有完整 Xcode 的 macOS 手动验收；当前环境只有 Command Line Tools 时不得声称完成图形端到端验收。
- 验证器风格：`enum XxxVerification { static func run() async throws }`，在 `Verification/RecallVerifier.swift` 的 `main` 里加一行 `try await XxxVerification.run()`，断言用文件内私有 `expect(_:_:)`（参考 `Verification/AskAgentVerification.swift:7-10`）。
- 决策已定：阶段 5 选方案 B（不展示草稿，本地确定性检查，必要时才调用模型核对）；阶段 6、7、8 都做。
- 每个任务单独提交，提交信息末尾加 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`。

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/RecallKit/Chat/LiveMemoryResponder.swift` | 改 | `validate()` 改为比较修订号 |
| `Sources/RecallKit/Support/Storage.swift` | 改 | 暴露 `archiveRevision`/内容修订号；会话消息 sidecar；登记表与会话字段 |
| `Sources/RecallKit/Support/ConversationStore.swift` | 新建 | 会话消息 sidecar 文件读写（参考 `reviewSchedules`） |
| `Sources/RecallKit/Chat/AskAgent.swift` | 改 | 去重 transcript；本地先检索；失败用已读材料回答；预算 |
| `Sources/RecallKit/Chat/AnswerGrounding.swift` | 改 | 本地确定性预检；核对只返回被删句子编号 |
| `Sources/RecallKit/Chat/MemoryAssistant.swift` | 改 | 检索移出主线程；接入会话状态 |
| `Sources/RecallKit/Chat/ConversationSession.swift` | 新建 | 结构化会话状态（阶段 7） |
| `Sources/RecallKit/Memory/TopicRegistry.swift` | 新建 | 主题登记表、别名、生命周期、状态推断（阶段 3、6） |
| `Sources/RecallKit/Memory/DailyKnowledge.swift` | 改 | 归并走登记表/别名；卡片摘要用 title |
| `Sources/RecallKit/Memory/DirectDailyReview.swift` | 改 | 提示词传入已有主题名（后升级为 id+title） |
| `Sources/RecallKit/Memory/MemoryExperience.swift` | 改 | `TopicReading.headline` 用最近事件 title |
| `Sources/RecallApp/Views/MatterWorkspaceView.swift` | 改 | 卡片瘦身、分段控件、分组折叠、项目分组 |
| `Verification/TopicRegistryVerification.swift` | 新建 | 登记表/别名/生命周期/迁移验证 |
| `Verification/AskPerformanceVerification.swift` | 新建 | 修订号、预算、回退、预检验证 |
| `Verification/ConversationSessionVerification.swift` | 新建 | 追问复用来源、主题会话隔离、删除联动 |
| `Verification/TopicListVerification.swift` | 新建 | 主题摘要与状态分组的纯逻辑验证 |

---

## Phase 0 / Task 1: 确认瓶颈（只读，不改代码）

**Files:** 无改动。

- [ ] **Step 1: 导出诊断日志并统计耗时**

诊断日志来自 `RecallAppModel.swift:1280` 的 `问一问耗时` / `问一问回退原因`（metadata 为 `step`、`ms`）。在 App 的诊断页导出最近一周日志，按 `step` 汇总：`analysis`、`planning`、`tool:*`、`answer`、`grounding:*`、`agent-fallback:*`。

- [ ] **Step 2: 把结论记入文档**

在 `docs/memory-topics-and-ask-review.md` 末尾追加「实测结论」小节：各步 P50/P90 耗时、回退频率。没有真实日志时写明「待补」，并继续按文档推断顺序执行后续任务。

- [ ] **Step 3: Commit**

```bash
git add docs/memory-topics-and-ask-review.md
git commit -m "docs: 记录问一问耗时实测结论"
```

---

## Phase 1 / Task 2: `validate()` 改为比较修订号

**Files:**
- Modify: `Sources/RecallKit/Support/Storage.swift`（`archiveRevision` 附近，约 316 行；`snapshot()` 约 441 行）
- Modify: `Sources/RecallKit/Chat/LiveMemoryResponder.swift:24-36`
- Create: `Verification/AskPerformanceVerification.swift`
- Modify: `Verification/RecallVerifier.swift`

**Interfaces:**
- Produces: `FileMemoryStore.captureContentRevision() -> UInt64`：仅当任何截图的 `searchableText` 或集合发生变化时递增；聊天消息写入不递增。`LiveMemoryResponder` 记录创建时的值，相等则跳过逐条比较。

说明：`archiveRevision` 每次 `persist`（含聊天消息）都会递增（`Storage.swift:1602,1616`），直接比较会让每条消息都触发慢路径但仍然正确。单独维护 `captureContentRevision`，在所有修改 `state.captures` 的写入点递增；为避免漏改，递增点放在 `writeState()` 里按「captures 摘要」判断是否变化。

- [ ] **Step 1: 写失败验证**

```swift
// Verification/AskPerformanceVerification.swift
import Foundation
import RecallKit

@MainActor
enum AskPerformanceVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }

    static func run() async throws {
        try await messagesDoNotBumpCaptureRevision()
        print("PASS: ask performance scenarios")
    }

    private static func messagesDoNotBumpCaptureRevision() async throws {
        let storage = RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-verify-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try await FileMemoryStore.open(storage: storage, credentials: InMemoryCredentialStore())
        let capture = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成", sourceBundleIdentifier: "example.visible",
            contentHash: UUID().uuidString, ocrText: "AtlasScopeToken 合成文本", textOrigin: .userInput)
        try await store.addCapture(capture)
        let before = await store.captureContentRevision()
        try await store.addMessage(ConversationMessage(role: .user, content: "你好"))
        let afterMessage = await store.captureContentRevision()
        try expect(before == afterMessage, "聊天消息不应改变截图内容修订号")
        let other = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成", sourceBundleIdentifier: "example.visible",
            contentHash: UUID().uuidString, ocrText: "另一条合成文本", textOrigin: .userInput)
        try await store.addCapture(other)
        let afterCapture = await store.captureContentRevision()
        try expect(afterCapture != afterMessage, "新增截图必须改变修订号")
    }
}
```

先对照 `Verification/AskAgentVerification.swift` 的 `fixture(_:)` 辅助函数，沿用它创建 `storage/store`（`InMemoryCredentialStore` 和 `RecallStorage(rootURL:)` 的真实名字以该文件为准，写代码时直接复制其创建方式）。在 `RecallVerifier.main` 里 `try await AskAgentVerification.run()` 下一行加 `try await AskPerformanceVerification.run()`。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 2>&1 | tail -20`
Expected: 编译失败，`captureContentRevision` 未定义。

- [ ] **Step 3: 实现修订号**

在 `FileMemoryStore`（`Storage.swift`）加属性与方法：

```swift
private var captureDigest: Int = 0
private(set) var captureContentRev: UInt64 = 0

public func captureContentRevision() -> UInt64 { captureContentRev }

/// writeState() 里调用；只在截图集合或文本变化时递增。
private func refreshCaptureRevision() {
    var hasher = Hasher()
    for capture in state.captures { hasher.combine(capture.id); hasher.combine(capture.searchableText) }
    let digest = hasher.finalize()
    if digest != captureDigest { captureDigest = digest; captureContentRev &+= 1 }
}
```

在 `writeState()` 的 `state.reconcilePersonaProfile()` 之后调用 `refreshCaptureRevision()`。注意 `Hasher` 每个进程随机种子，只做进程内比较，符合用途。性能：哈希全部文本仍是 O(全部文本)，但只在写盘时算一次，而每次提问原本要算 3–4 遍；写盘本身已经编码整份 state，成本可忽略。

- [ ] **Step 4: 让 `LiveMemoryResponder` 用修订号**

```swift
struct LiveMemoryResponder: LLMResponding {
    let base: any LLMResponding
    let store: FileMemoryStore
    let original: RecallState
    let originalRevision: UInt64
    ...
    // 替换 24-36 行：
    let revision = await store.captureContentRevision()
    if revision == originalRevision { return }
    // 修订号变化时保留原来的逐条比较作为慢路径（原 24-36 行逻辑原样保留）
```

所有构造 `LiveMemoryResponder(...)` 的位置（`grep -rn "LiveMemoryResponder(" Sources`）补传 `originalRevision: await store.captureContentRevision()`，且要与取得 `original` 快照在同一次 actor 调用序列内取得，避免快照与修订号错位。

- [ ] **Step 5: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS，含 `PASS: ask performance scenarios`。

- [ ] **Step 6: Commit**

```bash
git add -A Sources Verification
git commit -m "perf: 问一问隐私复核改用截图内容修订号"
```

---

## Phase 1 / Task 3: 最终回答请求去掉重复 transcript

**Files:**
- Modify: `Sources/RecallKit/Chat/AskAgent.swift:117-123`
- Modify: `Verification/AskPerformanceVerification.swift`

**Interfaces:** 无新增。

背景：`shown` 里每个来源已带有各自原文（`remember(...)`），`transcript` 是工具结果文本，内容基本重复。但 `transcript` 也承载没有逐来源文本的工具输出（`get_memories`、`list_reminders`、`list_days` 等），不能一刀切删除。规则：只在 `shown` 非空且 `transcript` 中包含的主要是来源正文时去掉；否则保留。实现为：把 transcript 里 `[get_overview]`、`[read_records]`、`[search_records]`、`[get_daily_reviews]` 段落过滤掉，保留其余工具段落。

- [ ] **Step 1: 写失败验证**

在 `AskPerformanceVerification` 加场景：脚本化模型，先规划 `read_records`，再给出回答；断言最终 `.chat` 请求的 `supplementaryContext` 不含 `[read_records]` 段，但仍含 `get_memories` 段。若项目里没有 `ScriptedAskModel` 的公共版本，复用 `AskAgentVerification.swift` 中该类型（把它从 `private` 改为 `internal`）。

```swift
private static func finalRequestDropsDuplicatedToolText() async throws {
    let (storage, store, capture) = try await AskAgentVerification.fixture("AtlasScopeToken was saved")
    defer { try? FileManager.default.removeItem(at: storage.rootURL) }
    let script = ScriptedAskModel { request in
        if request.purpose == .chatPlanning, !request.question.contains("已读取的工具结果") {
            return LLMAnswer(content: #"{"calls":[{"tool":"read_records","args":{"ids":[""# + capture.id.uuidString + #""]}}]}"#, citedCaptureIDs: [])
        }
        return LLMAnswer(content: "已记录 AtlasScopeToken [1]", citedCaptureIDs: [])
    }
    _ = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script)
    let final = await script.recorded().first { $0.purpose == .chat }
    try expect(final != nil, "应走到最终回答请求")
    try expect(final?.supplementaryContext?.contains("[read_records]") != true, "最终回答请求不应重复带工具原文")
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | grep -i "FAIL\|error" | head`
Expected: 失败，信息为「最终回答请求不应重复带工具原文」。

- [ ] **Step 3: 实现**

在 `AskAgent` 里加：

```swift
/// 逐来源原文已经在 shown 里，最终回答不再重复带这些工具段落。
private static let duplicatedTools: Set<String> = ["get_overview", "get_daily_reviews", "search_records", "read_records"]

private static func finalSupplement(transcript: String, shown: [CaptureRecord], profile: String) -> String {
    var kept: [String] = []
    if shown.isEmpty { kept.append(transcript) }
    else {
        for block in transcript.components(separatedBy: "\n\n[") {
            let normalized = block.hasPrefix("[") ? block : "[" + block
            let name = normalized.dropFirst().prefix { $0 != "]" }
            if !duplicatedTools.contains(String(name)) { kept.append(normalized) }
        }
    }
    return (kept + [profile]).filter { !$0.isEmpty }.joined(separator: "\n")
}
```

并把 119–120 行改为 `supplementaryContext: finalSupplement(transcript: transcript, shown: shown, profile: profile)`。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -10`
Expected: 全部 PASS，包括已有的 15 个 ask-agent 场景。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "perf: 最终回答请求不再重复携带工具原文"
```

---

## Phase 1 / Task 4: `MemoryAssistant` 检索移出主线程

**Files:**
- Modify: `Sources/RecallKit/Chat/MemoryAssistant.swift:3, 99-258`

**Interfaces:**
- Produces: `MemoryAssistant` 去掉整体 `@MainActor`，只给与 UI 交互的方法（`ask`、回调）保留 `@MainActor` 约束；检索/排序（`retrievalText`、搜索、语义补查前的排序）放到 `nonisolated` 或 `Task.detached` 中执行。

- [ ] **Step 1: 摸清主线程依赖**

Run: `grep -n "@MainActor\|onPartial\|onStatus\|onStep\|searchEngine\.\|contextManager\." Sources/RecallKit/Chat/MemoryAssistant.swift`
把使用了回调（`@MainActor @Sendable`）的位置与纯计算位置分开，写进任务笔记。

- [ ] **Step 2: 先写验证（保持行为）**

`AskAgentVerification` 已覆盖回退路径行为；本任务不改行为，所以以现有验证作回归。额外加一个断言：在非主线程环境下调用 `ask` 不崩溃（验证器 `main` 本身是 `async`，直接运行即可）。

- [ ] **Step 3: 实现**

1. 把类声明的 `@MainActor` 去掉，改为 `public final class MemoryAssistant: @unchecked Sendable`（属性均为 `let` 且类型是 `Sendable` 值或 actor，满足约束；`store` 是 actor）。
2. `ask(...)` 保持 `async`，在调用 `onPartial` 等回调处已经是 `@MainActor @Sendable` 闭包，用 `await onPartial?(...)` 即可，无需标注整个类。
3. 检索与排序函数标 `nonisolated` 并只接收值类型参数（`RecallState`、`String`）。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 2>&1 | tail -30 && swift run RecallVerifier 2>&1 | tail -10`
Expected: 无新增并发警告；全部 PASS。出现 Swift 6 严格并发错误时，逐处加 `@Sendable`/`nonisolated`，不要用 `@preconcurrency` 压警告。

- [ ] **Step 5: Commit**

```bash
git add -A Sources
git commit -m "perf: 问一问回退路径的检索移出主线程"
```

---

## Phase 1 / Task 5: 会话消息改存 sidecar 文件

**Files:**
- Create: `Sources/RecallKit/Support/ConversationStore.swift`
- Modify: `Sources/RecallKit/Support/Storage.swift`（`RecallStorage` 路径、`addMessage` 约 1378、`clearConversation` 约 450、`rateMessage`、编码键 `messages`）
- Modify: `Sources/RecallKit/Support/ArchiveReliability.swift`（备份/清理时一并处理 sidecar，参考 137 行对 `reviewSchedulesURL` 的处理）
- Modify: `Verification/AskPerformanceVerification.swift`

**Interfaces:**
- Produces: `RecallStorage.conversationURL: URL`（`conversation.json`）；`ConversationStore.read(from:) -> [ConversationMessage]`、`ConversationStore.write(_:to:)`。`RecallState.messages` 仍在内存里存在，供现有读取方使用；但从主存档编码里剔除（`encode` 不写 `messages`），`decode` 仍兼容读取旧存档里的 `messages` 并在首次保存时迁移到 sidecar。

先读 `reviewSchedules` 的实现作模板：`Storage.swift:19,30,43,107,177,207,273,294,443` 与 `ArchiveReliability.swift:137`，沿用同样的「独立文件 + 启动时合并 + 单独写」模式。

- [ ] **Step 1: 写失败验证**

```swift
private static func messagesLiveInSidecar() async throws {
    let storage = RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-verify-" + UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: storage.rootURL) }
    var store: FileMemoryStore? = try await FileMemoryStore.open(storage: storage, credentials: InMemoryCredentialStore())
    try await store!.addMessage(ConversationMessage(role: .user, content: "SIDECAR-SYNTHETIC-1"))
    let main = try String(contentsOf: storage.stateURL, encoding: .utf8)
    try expect(!main.contains("SIDECAR-SYNTHETIC-1"), "消息不应再写入主存档")
    try expect(FileManager.default.fileExists(atPath: storage.conversationURL.path), "应生成 sidecar 文件")
    store = nil
    let reopened = try await FileMemoryStore.open(storage: storage, credentials: InMemoryCredentialStore())
    let messages = await reopened.snapshot().messages
    try expect(messages.contains { $0.content == "SIDECAR-SYNTHETIC-1" }, "重新打开后消息应还在")
}
```

`storage.stateURL` 以 `RecallStorage` 里主存档文件属性的真实名字为准（查看 `Storage.swift:14-45`）。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 2>&1 | tail`
Expected: 编译失败（`conversationURL` 未定义）。

- [ ] **Step 3: 实现 `ConversationStore`**

```swift
// Sources/RecallKit/Support/ConversationStore.swift
import Foundation

/// 会话消息独立落盘：每条消息只写这个小文件，不再编码包含 OCR 的整份主存档。
enum ConversationStore {
    static func read(from url: URL, decoder: JSONDecoder) -> [ConversationMessage]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([ConversationMessage].self, from: data)
    }
    static func write(_ messages: [ConversationMessage], to url: URL, encoder: JSONEncoder) throws {
        let data = try encoder.encode(messages)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
```

- [ ] **Step 4: 接入 `Storage.swift`**

1. `RecallStorage` 两个 `init` 里加 `conversationURL = rootURL.appendingPathComponent("conversation.json")`（与 `reviewSchedulesURL` 同位置）。
2. 启动加载：读主存档后，若 sidecar 存在则 `state.messages = ConversationStore.read(...)`；否则保留主存档里解码出的旧 `messages`，并标记 `needsConversationMigration = true`。
3. `RecallState.encode` 不再写 `.messages`（保留 `decodeIfPresent` 读旧数据）。
4. 新增 `private func persistConversation() throws { try ConversationStore.write(state.messages, to: storage.conversationURL, encoder: encoder) }`。`addMessage`、`rateMessage`、`clearConversation` 改为：修改 `state.messages` → `persistConversation()`；失败时回滚 `state = before`。`addMessage` 不再调用 `persistReviewState`。
5. 首次迁移：`needsConversationMigration` 为真时，启动后立即 `persistConversation()` 再 `writeState()`（主存档去掉 messages），保持这两步顺序以便崩溃可恢复：先写 sidecar，成功后再写主存档。
6. 删除全部数据、重置存档、`ArchiveReliability` 的清理流程里，一并删除 `conversationURL`（仿照 137 行）。
7. 删除某条截图时，保存在 `message.citations` 里的引用的处理保持现状。

- [ ] **Step 5: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS，包含 sidecar 场景与既有的 `MemoryReliabilityVerification`、`ReviewScheduleSaveVerification`（确认未破坏备份与恢复）。

- [ ] **Step 6: Commit**

```bash
git add -A Sources Verification
git commit -m "perf: 会话消息改存独立文件，不再每条消息重写整个存档"
```

---

## Phase 2 / Task 6: 主题卡片摘要与状态展示（纯逻辑）

**Files:**
- Modify: `Sources/RecallKit/Memory/MemoryExperience.swift`（`TopicReading`，约 4–41 行）
- Create: `Sources/RecallKit/Memory/TopicListPresentation.swift`
- Create: `Verification/TopicListVerification.swift`
- Modify: `Verification/RecallVerifier.swift`

**Interfaces:**
- Produces:
  - `TopicReading.headline: String`：一句话摘要。有最新的主题小结时用 `overview` 的首句；否则用最近事件的 `title`（`MatterEvent.title` 在 `DailyKnowledge.matterFiles` 中被赋值为 topic 名，不是具体事情，所以需要新增字段，见 Step 3）。
  - `TopicListPresentation.group(_ files: [MatterFile], now: Date, calendar: Calendar) -> (active: [MatterFile], done: [MatterFile])`
  - `TopicListPresentation.relativeTime(_ date: Date, now: Date, calendar: Calendar) -> String`（今天/昨天/N 天前/具体日期）

要点：`DailyKnowledge.matterFiles` 现在把 `MatterEvent.title` 设为 topic 名，把 `entry.item.title` 拼进 `detail`。文档要求「最近事件的 title（每日回顾已生成的具体事情）」，所以给 `MatterEvent` 加可选字段 `headline: String?`，在 `matterFiles` 里赋值为 `entry.item.title`。

- [ ] **Step 1: 写失败验证**

```swift
// Verification/TopicListVerification.swift
import Foundation
import RecallKit

enum TopicListVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func run() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!
        func file(_ id: String, daysAgo: Int, status: WorkEpisodeStatus, headline: String?) -> MatterFile {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            var event = MatterEvent(id: UUID(), title: id, detail: "PR #123 修复 env=FOO 表 t_order 细节",
                recordedAt: day, eventAt: day, status: status, evidenceIDs: [UUID()], nextAction: nil)
            event.headline = headline
            return MatterFile(id: id, title: id, events: [event])
        }
        let reading = TopicReading(file: file("topic:a", daysAgo: 1, status: .progressed, headline: "历史气泡误挂思考中表情的问题已定位并修复"))
        try expect(reading.headline == "历史气泡误挂思考中表情的问题已定位并修复", "摘要应使用最近事件的 headline 而不是 detail 全文")
        let fallback = TopicReading(file: file("topic:b", daysAgo: 1, status: .progressed, headline: nil))
        try expect(fallback.headline.count <= 60, "没有 headline 时回退为截断的 detail")
        let groups = TopicListPresentation.group([
            file("topic:a", daysAgo: 1, status: .progressed, headline: nil),
            file("topic:b", daysAgo: 2, status: .completed, headline: nil),
            file("topic:c", daysAgo: 30, status: .progressed, headline: nil)
        ], now: now, calendar: calendar)
        try expect(groups.active.map(\.id) == ["topic:a"], "进行中只含近期未完成")
        try expect(Set(groups.done.map(\.id)) == ["topic:b", "topic:c"], "完成与搁置（超过 14 天）归入折叠组")
        try expect(TopicListPresentation.relativeTime(calendar.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: calendar) == "昨天", "相对时间：昨天")
        try expect(TopicListPresentation.relativeTime(calendar.date(byAdding: .day, value: -3, to: now)!, now: now, calendar: calendar) == "3 天前", "相对时间：N 天前")
        print("PASS: topic list presentation")
    }
}
```

`MatterEvent` 初始化器的真实参数以 `Sources/RecallKit/Memory/MatterMemory.swift` 为准，写代码时对照（`DailyKnowledge.swift:140-144` 是一个现成用例）。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 2>&1 | tail`
Expected: 编译失败（`headline`、`TopicListPresentation` 未定义）。

- [ ] **Step 3: 实现**

1. `MatterEvent` 加 `public var headline: String? = nil`（`Codable` 用 `decodeIfPresent`，若该类型是自动合成的 `Codable`，可选字段天然兼容旧数据）。
2. `DailyKnowledge.matterFiles`：`event.headline = entry.item.title`（紧跟 `event.quotes = ...` 之后）。
3. `TopicReading` 加：

```swift
public let headline: String
// init 内，resolvedOverview 计算之后：
let firstSentence = usable.flatMap { current ? $0.overview : nil }
    .flatMap { $0.split(whereSeparator: { "。！？!?\n".contains($0) }).first.map(String.init) }
let eventHeadline = file.latest.headline?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
headline = String((firstSentence ?? eventHeadline ?? file.latest.detail).prefix(60))
```

4. `TopicListPresentation`：

```swift
import Foundation

public enum TopicListPresentation {
    /// 进行中：最近事件未完成且 14 天内有动静；其余（已完成、搁置）折叠。
    public static func group(_ files: [MatterFile], now: Date = .now, calendar: Calendar = .current) -> (active: [MatterFile], done: [MatterFile]) {
        var active: [MatterFile] = [], done: [MatterFile] = []
        for file in files {
            if file.latest.status.isOpenMatter && !file.needsStatusUpdate(at: now, calendar: calendar) { active.append(file) }
            else { done.append(file) }
        }
        return (active, done)
    }

    public static func relativeTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return RecallLocalization.both("今天", "Today")
        case 1: return RecallLocalization.both("昨天", "Yesterday")
        case 2...30: return RecallLocalization.both("\(days) 天前", "\(days) days ago")
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}
```

验证器里语言固定为 `zh-Hans`（`RecallVerifier.main` 已设置）。阶段 6 会把这里的「状态」替换为登记表的 `state`，届时改 `group` 的实现即可，接口保持不变。

- [ ] **Step 4: 注册并运行**

在 `RecallVerifier.main` 加 `try TopicListVerification.run()`。
Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -10`
Expected: 全部 PASS，含 `PASS: topic list presentation`。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 主题摘要取最近事件标题，并提供状态分组与相对时间"
```

---

## Phase 2 / Task 7: 主题列表 UI 瘦身

**Files:**
- Modify: `Sources/RecallApp/Views/MatterWorkspaceView.swift:54-82, 108-139`（筛选区与 `card`）

**Interfaces:**
- Consumes: `TopicReading.headline`、`TopicListPresentation.group`、`TopicListPresentation.relativeTime`。

- [ ] **Step 1: 筛选合并为分段控件**

把 56–61 行的 `RecallFilterChip` 与 `Menu` 换成：

```swift
Picker("", selection: $filter) {
    Text(RecallLocalization.text("全部")).tag(0)
    Text(RecallLocalization.text("进行中")).tag(1)
    Text(RecallLocalization.text("已完成")).tag(2)
}.pickerStyle(.segmented).labelsHidden().fixedSize()
```

`filter` 的取值含义保持不变（0 全部、1 进行中、2 已完成），`files` 计算属性不用改。

- [ ] **Step 2: 列表分组**

`filter == 0` 时：先渲染 `group.active`，其后放一个默认折叠的 `DisclosureGroup(RecallLocalization.both("已完成与搁置（\(group.done.count)）", "Done and dormant (\(group.done.count))"), isExpanded: $showDone)`，里面渲染 `group.done`。`filter == 1/2` 或搜索非空时不分组（搜索时直接平铺，避免命中项被折叠）。新增 `@State private var showDone = false`。

- [ ] **Step 3: 卡片改造**

`card(_:)` 改为：

```swift
private func card(_ file: MatterFile) -> some View {
    let reading = TopicReading(file: file, review: model.state.topicReviews.first { $0.id == file.id })
    return Button { selectedID = file.id } label: {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(file.latest.status.isOpenMatter ? RecallPalette.accent : RecallPalette.secondary.opacity(0.5)).frame(width: 8, height: 8)
                    .accessibilityLabel(RecallLocalization.text(file.latest.status.manualMatterLabel))
                Text(file.title).font(.headline).lineLimit(1)
                Spacer()
                if model.completingMatterIDs.contains(file.id) { Text(RecallLocalization.both("保存中…", "Saving…")).font(.caption) }
                Text(TopicListPresentation.relativeTime(file.latest.date)).font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            Text(reading.headline).font(RecallTypography.body).foregroundStyle(RecallPalette.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 16)
        }.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("open-topic-" + file.id)
    .padding(.vertical, 10).padding(.horizontal, 12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    .contextMenu {
        Button(RecallLocalization.both("继续问", "Ask about this")) { continueChat(file.id) }
        Button(RecallLocalization.both("补充进展", "Add progress")) { addingTitle = file.title; adding = true }
        if file.latest.status.isOpenMatter {
            Button(RecallLocalization.both("标记完成", "Mark complete")) { Task { await model.completeMatter(file) } }.disabled(model.completingMatterIDs.contains(file.id))
        } else if model.state.matterCorrections.contains(where: { $0.isTopicCompletion && $0.topicID == file.id }) {
            Button(RecallLocalization.both("撤销完成标记", "Undo completion")) { model.undoTopicCompletion(file.id) }
        }
    }
}
```

保留 `.accessibilityIdentifier("open-topic-…")`，UI 自动化可能依赖。把 `recallSurface()` 的大卡片换成上面更紧凑的背景；`LazyVStack` 的 `spacing` 可从 18 降到 10。「继续问」与来源数量只在详情页保留（详情页已有「继续问」，来源数量已在「查看来源（N）」里）。

- [ ] **Step 4: 构建**

Run: `swift build --jobs 1 2>&1 | tail -20`
Expected: 编译通过。

- [ ] **Step 5: 手动验收（需完整 Xcode 环境）**

启动 App，检查：一屏能看到 8 个以上主题；分段控件切换正确；已完成折叠组展开/收起；右键菜单四个动作可用；点整张卡进入详情；VoiceOver 能读出状态标签。无完整 Xcode 时在最终说明里写明「图形验收未做」。

- [ ] **Step 6: Commit**

```bash
git add -A Sources
git commit -m "feat: 主题列表改为紧凑卡片、分段筛选与已完成折叠"
```

---

## Phase 3 / Task 8: 每日回顾传入最近 30 天主题名

**Files:**
- Modify: `Sources/RecallKit/Memory/DirectDailyReview.swift`（`DailyReviewInput` 约 97–109 行，`prompt(_:)` 约 314 行，构造 `DailyReviewInput` 的位置）
- Modify: `Verification/DirectDailyReviewVerification.swift`

**Interfaces:**
- Produces: `DailyReviewInput.knownTopics: [String] = []`；提示词新增「已有主题」一段。
- 构造 `knownTopics` 的函数：`DailyKnowledgeEngine.recentTopicNames(in state: RecallState, now: Date, days: Int = 30, limit: Int = 40) -> [String]`，新建在 `DailyKnowledge.swift`。

- [ ] **Step 1: 写失败验证**

在 `DirectDailyReviewVerification.swift` 里沿用已有的脚本化模型夹具（先看该文件已有场景的写法），加场景：存档里已有主题「一键发版功能」的每日回顾，生成新一天回顾时，断言发给模型的 prompt 含「一键发版功能」，且不含任何 `ocrText` 原文。

```swift
// 同文件内新增场景函数，调用方式与已有场景一致
let names = DailyKnowledgeEngine().recentTopicNames(in: state, now: now)
try expect(names.contains("一键发版功能"), "最近 30 天主题名应传入")
try expect(!names.joined().contains("合成原文片段"), "只传主题名，不传原文")
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 2>&1 | tail`
Expected: 编译失败（`recentTopicNames` 未定义）。

- [ ] **Step 3: 实现**

```swift
// DailyKnowledge.swift，DailyKnowledgeEngine 内
/// 最近活跃的主题显示名，按最近一次出现排序。只含名字，不含原文。
public func recentTopicNames(in state: RecallState, now: Date = .now, days: Int = 30, limit: Int = 40, calendar: Calendar = .current) -> [String] {
    let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
    return matterFiles(in: state).filter { $0.latest.date >= cutoff }.prefix(limit).map(\.title)
}
```

`DailyReviewInput` 加 `var knownTopics: [String] = []`；在 `prompt(_:)` 的 `topic=` 句后追加：

```swift
let known = input.knownTopics.isEmpty ? "" : """
已有主题（仅名称，不是当天证据）：\(input.knownTopics.map { PrivacyEngine().redact($0) }.joined(separator: "、"))。若当天事项属于其中某个，topic 必须原样使用该名称，不要改写；确实是新的事再起新名字，并尽量并入已有范围，不要一件小事一个主题。

"""
```

并把 `known` 拼进 prompt（放在 `用户已生效的纠错要求` 之前）。构造 `DailyReviewInput` 的调用方（`grep -n "DailyReviewInput(" Sources`）填入 `knownTopics: DailyKnowledgeEngine().recentTopicNames(in: state)`；用户关闭云端模型时此路径本来就不会走，保持默认关闭。主题名要走 `PrivacyEngine().redact`，满足最小化。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -10`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 每日回顾提示词带入最近 30 天主题名以复用叫法"
```

---

## Phase 3 / Task 9: 别名归并（过渡方案）

**Files:**
- Modify: `Sources/RecallKit/Memory/DailyKnowledge.swift:131-157`（`matterFiles`）
- Modify: `Sources/RecallKit/Support/Storage.swift`（`RecallState.topicAliases: [String: String]`，约 130 行 `topicGroups` 附近及 `CodingKeys`/`init(from:)`）
- Modify: `Sources/RecallApp/ProductExperienceModel.swift:75` 附近（合并主题时写入别名）
- Modify: `Sources/RecallKit/Memory/ProductExperience.swift`（`MemoryTopicGroup`）
- Create: `Verification/TopicRegistryVerification.swift`

**Interfaces:**
- Produces:
  - `RecallState.topicAliases: [String: String]`：`旧 topicKey → 规范 topicKey`。默认 `[:]`，`decodeIfPresent`。
  - `DailyKnowledgeEngine.canonicalKey(_ topic: String, aliases: [String: String]) -> String`：先 `topicKey(topic)`，若在 `aliases` 中则映射（最多跟随 4 跳，防环）。
  - `matterFiles` 用 `canonicalKey` 分桶，显示名取规范 key 对应的最新叫法。
  - 合并主题时：被合并成员的 key 写入 `topicAliases[memberKey] = 主题 key`。

说明：阶段 6 的登记表会把 `topicAliases` 吸收进 `Topic.aliases`。这里的结构刻意保持最小，并在迁移任务里转换。

- [ ] **Step 1: 写失败验证**

```swift
// Verification/TopicRegistryVerification.swift
import Foundation
import RecallKit

enum TopicRegistryVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func run() throws {
        let key = DailyKnowledgeEngine.topicKey
        let aliases = [key("一键发版上线"): key("一键发版功能")]
        try expect(DailyKnowledgeEngine.canonicalKey("一键发版上线", aliases: aliases) == key("一键发版功能"), "别名应映射到规范 key")
        try expect(DailyKnowledgeEngine.canonicalKey("一键发版功能", aliases: aliases) == key("一键发版功能"), "规范名自身不变")
        let loop = [key("甲"): key("乙"), key("乙"): key("甲")]
        try expect(!DailyKnowledgeEngine.canonicalKey("甲", aliases: loop).isEmpty, "别名环不能死循环")
        print("PASS: topic aliases")
    }
}
```

另在同文件加一个用合成每日回顾状态的场景（构造方式参考 `Verification/TopicCompletionVerification.swift` 与 `KnowledgeProjectionVerification.swift` 里已有的夹具）：两天分别以「一键发版功能」「一键发版上线」为 topic，`topicAliases` 设置后，`matterFiles` 只产出一个主题，且 `evidenceIDs` 为两天来源之并集；不设置别名时产出两个。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 2>&1 | tail`
Expected: 编译失败。

- [ ] **Step 3: 实现**

```swift
// DailyKnowledge.swift
public static func canonicalKey(_ topic: String, aliases: [String: String]) -> String {
    var key = topicKey(topic)
    var hops = 0
    while let next = aliases[key], next != key, hops < 4 { key = next; hops += 1 }
    return key
}
```

`matterFiles` 里 `let key = "topic:" + Self.topicKey(topic)` 改为 `"topic:" + Self.canonicalKey(topic, aliases: state.topicAliases)`；`current.name` 的「最新叫法」规则保持：由于 `entries` 按日顺序产生，最后遍历到的名字胜出——要改成显式取「最新一天」的名字，避免遍历顺序影响（给 `groups` 值加 `latestDay: Date`，仅当 `entry.summary.day >= latestDay` 时更新名字）。

`RecallState` 加 `public var topicAliases: [String: String] = [:]`，补 `CodingKeys` 与 `init(from:)` 的 `decodeIfPresent(... ) ?? [:]`（与 `topicGroups` 同写法，见 `Storage.swift:267`）。

合并主题（`ProductExperienceModel.swift:75` 附近 `MemoryTopicGroup(title:memberIDs:)` 创建处）之后，对每个成员 id（形如 `topic:<key>`）去掉前缀，写 `topicAliases[memberKey] = canonical`，其中 canonical 取成员中证据最多的那个；通过新方法 `FileMemoryStore.saveTopicAliases(_:)` 持久化（仿 `saveTopicGroup`，`Storage.swift:719`）。撤销合并时移除对应别名。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -10`
Expected: 全部 PASS。同时跑到既有的 `TopicCompletionVerification`、`MemoryKnowledgeVerification`，确认完成标记与合并组未被破坏。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 主题归并支持别名，合并后新叫法自动接上"
```

---

## Phase 4 / Task 10: 本地先检索，把候选摘录放进第一次规划

**Files:**
- Modify: `Sources/RecallKit/Chat/AskAgent.swift:58-100`（规划前）
- Modify: `Sources/RecallKit/Chat/MemoryReadTools.swift`（已有 `preliminary(question:limit:)`，79 行）
- Modify: `Verification/AskPerformanceVerification.swift`

**Interfaces:**
- Consumes: `MemoryReadTools.preliminary(question:limit:) -> [(record: CaptureRecord, aliases: [UUID: [UUID]])]`（已存在）。
- Produces: 第一轮规划请求的 `context` 预置这些候选，并在规划提示里说明「候选摘录已读，材料够时直接输出 answer」。

先读 `MemoryReadTools.preliminary` 和它现有调用点（`grep -rn "preliminary(" Sources`）；若已被用于别处，复用其返回值，不重复实现。

- [ ] **Step 1: 写失败验证**

场景：问题含记录里的关键词；脚本化模型第一次规划请求收到的 `context` 非空，且一轮就返回 `answer`；断言总共只出现 `[.chatPlanning, .answerVerification]`（不再需要 `search_records` 往返）。

```swift
private static func candidatesAnswerInOneRound() async throws {
    let (storage, store, capture) = try await AskAgentVerification.fixture("AtlasScopeToken was saved")
    defer { try? FileManager.default.removeItem(at: storage.rootURL) }
    let script = ScriptedAskModel { request in
        try expectSync(!request.context.isEmpty, "第一轮规划应已带候选摘录")
        return LLMAnswer(content: #"{"answer":"已记录 AtlasScopeToken","citations":[""# + capture.id.uuidString + #""]}"#, citedCaptureIDs: [])
    }
    _ = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script)
    let purposes = await script.recorded().map(\.purpose)
    try expect(purposes == [.chatPlanning, .answerVerification], "有候选时应一轮出答案")
}
```

（`expectSync` 用 `precondition`/抛出 Failure 均可，保持与同文件风格一致。）

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | grep -i fail | head`
Expected: 失败于「第一轮规划应已带候选摘录」。

- [ ] **Step 3: 实现**

在 `AskAgent.answer` 里，`forceAnswer` 判定后、`for round` 前：

```swift
if !forceAnswer {
    for candidate in tools.preliminary(question: question, limit: 6) {
        for (id, sources) in candidate.aliases { aliases[id] = sources }
        if allowed.insert(candidate.record.id).inserted {
            inspected.append(candidate.record.id)
            remember(candidate.record.id, text: nil, shown: &shown, state: tools.state)
        }
    }
}
```

规划提示（`planningQuestion`）追加一行：`"已附本地检索到的候选摘录（见上下文）。材料足够时直接输出 answer；不够再用工具读取。"`，仅当 `shown` 非空时加入。候选走的是现有的本地检索与脱敏路径（`remember` 内 `PrivacyEngine().redact`），不新增外发数据类别，但每次规划请求会多带最多 6 条脱敏摘录，这是文档优化 2 的预期代价。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -10`
Expected: 全部 PASS。既有场景「toolsThenAnswerDropFakeCitations」预期的调用顺序可能改变（候选已命中则不再需要 search），按新行为更新该断言，并在提交信息里说明。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "perf: 问一问先本地检索，候选摘录进入第一次规划"
```

---

## Phase 4 / Task 11: 核对只返回被剔除的句子，不重写全文（含阶段 5 方案 B 的本地预检）

**Files:**
- Modify: `Sources/RecallKit/Chat/AnswerGrounding.swift`
- Modify: `Sources/RecallKit/Chat/AskAgent.swift:96-100, 130-134`
- Modify: `Verification/AskPerformanceVerification.swift`

**Interfaces:**
- Produces:
  - `AnswerGrounding.sentences(_ draft: String) -> [String]`：按 `。！？!?\n` 切句，保留 `[n]` 引用。
  - `AnswerGrounding.localPrecheck(draft: String, question: String, records: [CaptureRecord]) -> PrecheckResult`，其中 `PrecheckResult { needsModelAudit: Bool; unsupportedSentenceIndexes: [Int] }`：对每句做本地确定性检查——数字集合、日期词、「已完成/已上线/已发布/已部署」断言必须在被引用来源文本里出现（复用 `validate` 里的 `numbers`、`dateTerms`、`assertedRelease`、`assertsCompletion`、`uncertain` 正则）。
  - `AnswerGrounding.verify` 新增 `mode`：先预检；预检没有触发「完成/上线/日期/数字」类断言，且所有句子带有效引用 → 跳过模型核对，直接返回草稿（保留 `[n]` 引用与来源）；否则调用模型核对。
  - 模型核对的输出格式改为 `{"unsupported":[句子编号...]}`，不再重写全文；`verify` 在原回答中删除这些句子。解析失败/调用失败沿用现有 `fallback(...)`。

这一方案落实 5-B（不展示草稿、本地确定性检查优先）与优化 3（只删句子）。`AnswerGrounding.swift:33` 的「核对前不流式输出」约束保持不变。

- [ ] **Step 1: 写失败验证**

```swift
private static func precheckSkipsModelAuditForPlainFacts() async throws {
    let (storage, store, capture) = try await AskAgentVerification.fixture("今天整理了发布文档的目录结构，没有涉及上线。")
    defer { try? FileManager.default.removeItem(at: storage.rootURL) }
    let script = ScriptedAskModel { request in
        LLMAnswer(content: #"{"answer":"整理了发布文档的目录结构 [1]","citations":[""# + capture.id.uuidString + #""]}"#, citedCaptureIDs: [])
    }
    let answer = try await MemoryAssistant(store: store).ask("发布文档", model: script)
    let purposes = await script.recorded().map(\.purpose)
    try expect(!purposes.contains(.answerVerification), "无完成/日期/数字断言时应跳过模型核对")
    try expect(answer.content.contains("目录结构"), "回答保持原文")
}

private static func completionClaimStillAudited() async throws {
    let (storage, store, capture) = try await AskAgentVerification.fixture("测试通过，等审批后再上线。")
    defer { try? FileManager.default.removeItem(at: storage.rootURL) }
    let script = ScriptedAskModel { request in
        if request.purpose == .answerVerification { return LLMAnswer(content: #"{"unsupported":[0]}"#, citedCaptureIDs: []) }
        return LLMAnswer(content: #"{"answer":"功能已上线 [1]","citations":[""# + capture.id.uuidString + #""]}"#, citedCaptureIDs: [])
    }
    let answer = try await MemoryAssistant(store: store).ask("上线了吗", model: script)
    try expect(!answer.content.contains("已上线"), "不被支持的完成断言必须被删除")
}
```

注意：现有 `AskAgentVerification` 里围绕 `answerVerification` 的断言（返回 `{"claims":[...]}` 格式）要同步改成新格式；这些断言是行为契约，改动要在本任务的提交说明中列出。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | grep -i fail | head`
Expected: 失败于上述两个场景。

- [ ] **Step 3: 实现 `localPrecheck`**

```swift
// AnswerGrounding.swift
struct PrecheckResult { var needsModelAudit: Bool; var unsupportedSentenceIndexes: [Int] }

static func sentences(_ draft: String) -> [String] {
    var result: [String] = [], current = ""
    for ch in draft {
        current.append(ch)
        if "。！？!?\n".contains(ch) {
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
            current = ""
        }
    }
    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
    return result
}

static func localPrecheck(draft: String, records: [CaptureRecord]) -> PrecheckResult {
    let corpus = records.map { $0.correctedText ?? $0.ocrText }.joined(separator: "\n")
    let stamps = records.map(recordedDateText).joined(separator: " ")
    var risky = false, unsupported: [Int] = []
    for (index, sentence) in sentences(draft).enumerated() {
        let claimsDone = sentence.range(of: #"已完成|完成了|已经完成|已上线|已发布|已部署|已经上线|already deployed|has been deployed|completed"#, options: [.regularExpression, .caseInsensitive]) != nil
        let hasNumbers = !numbers(sentence).subtracting(Set(citationNumbers(sentence))).isEmpty
        let hasDates = !dateTerms(sentence).isEmpty
        if claimsDone || hasNumbers || hasDates { risky = true }
        // 数字与日期必须在来源文本里出现；否则直接标为不被支持。
        let ownNumbers = numbers(sentence).subtracting(Set(citationNumbers(sentence)))
        if !ownNumbers.isSubset(of: numbers(corpus + " " + stamps)) || !dateTerms(sentence).isSubset(of: dateTerms(corpus + " " + stamps)) { unsupported.append(index) }
    }
    let cited = draft.range(of: #"\[\d+\]"#, options: .regularExpression) != nil
    return PrecheckResult(needsModelAudit: risky || !cited, unsupportedSentenceIndexes: unsupported)
}

private static func citationNumbers(_ sentence: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#) else { return [] }
    let ns = sentence as NSString
    return regex.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
}
```

- [ ] **Step 4: 改造 `verify`**

在 `verify` 里，`records` 构造完后：

```swift
let pre = localPrecheck(draft: draft, records: candidates)
var working = sentences(draft)
let preRemoved = Set(pre.unsupportedSentenceIndexes)
working = working.enumerated().filter { !preRemoved.contains($0.offset) }.map(\.element)
guard !working.isEmpty else { return fallback(records: candidates, reason: "precheck-empty") }
if !pre.needsModelAudit {
    return Result(content: working.joined().trimmingCharacters(in: .whitespacesAndNewlines),
                  sourceIDs: sourceIDs, rejectedCount: preRemoved.count, reason: "local-precheck")
}
```

模型核对分支：指令改为「逐句核对，只输出被原文不支持的句子编号：`{"unsupported":[编号,...]}`；编号对应下面 `sentences` 数组的下标」，payload 带 `["question":..., "sentences": working]`；解析 `unsupported`，从 `working` 删除，再合并。保留 `validate(_:records:bindings:)` 作为对外 API（`public`，其它地方和验证器在用），不删；但 `verify` 不再用它重写全文。删除句子后若为空，走 `fallback`。保持：解析失败 `audit-format`、调用失败 `audit-call`、取消向上抛出。

- [ ] **Step 5: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS。

- [ ] **Step 6: Commit**

```bash
git add -A Sources Verification
git commit -m "perf: 回答核对先做本地预检，模型只返回要删除的句子"
```

---

## Phase 4 / Task 12: 时间预算与失败时用已读材料回答

**Files:**
- Modify: `Sources/RecallKit/Chat/AskAgent.swift`（`AskLimits`、规划/回答的错误处理，约 82–86、124–128 行）
- Modify: `Sources/RecallKit/Chat/MemoryAssistant.swift:92-96`
- Modify: `Verification/AskPerformanceVerification.swift`

**Interfaces:**
- Produces:
  - `AskLimits.timeBudget: Duration = .seconds(45)`。
  - `AskAgentError.partial(AskTranscript)`：Agent 在已读到材料后失败时，携带「已读来源的本地摘录」作为兜底回答，不再抛 `.fallback` 触发整条回退流水线。
  - 兜底内容直接用 `AnswerGrounding.fallback(records: shown, reason:)`（已有；它明确声明「无法可靠核对、仅为保存原文」）。

规则：
- 规划调用失败且 `shown.isEmpty` → 仍抛 `.fallback`（没有可用材料，走原回退流水线）。
- 规划调用失败/不可解析，或最终回答调用失败，且 `shown` 非空 → 返回 `AskTranscript(content: fallback.content, citations: fallback.sourceIDs, inspectedSourceIDs: inspected)`，并 `onStep("agent-partial:<reason>")`。
- 超过 `timeBudget`：在每轮开始前和最终回答前检查，超时则跳过后续规划，直接进入最终回答（有 `shown` 时）或 `.fallback`（无材料）。

- [ ] **Step 1: 写失败验证**

```swift
private static func answerCallFailureUsesReadMaterial() async throws {
    let (storage, store, capture) = try await AskAgentVerification.fixture("AtlasScopeToken was saved")
    defer { try? FileManager.default.removeItem(at: storage.rootURL) }
    let script = ScriptedAskModel { request in
        if request.purpose == .chatPlanning, !request.question.contains("已读取的工具结果") {
            return LLMAnswer(content: #"{"calls":[{"tool":"read_records","args":{"ids":[""# + capture.id.uuidString + #""]}}]}"#, citedCaptureIDs: [])
        }
        if request.purpose == .chat { throw LLMError.serviceError("合成失败") }
        return LLMAnswer(content: #"{"claims":[]}"#, citedCaptureIDs: [])
    }
    var steps: [String] = []
    let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script, onStep: { name, _ in steps.append(name) })
    try expect(answer.content.contains("AtlasScopeToken"), "应使用已读材料给出保存原文")
    try expect(steps.contains { $0.hasPrefix("agent-partial") }, "应记录 agent-partial 而非整条回退")
    let purposes = await script.recorded().map(\.purpose)
    try expect(!purposes.contains(.chatRetrieval), "不应重跑完整回退流水线")
}
```

`.chatRetrieval` 这类 purpose 名以 `LLMRequest.Purpose` 的真实枚举值为准；用回退流水线里独有的 purpose 做断言（查看 `MemoryAssistant.swift:180-258` 使用的 purpose）。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | grep -i fail | head`
Expected: 失败（目前会走回退流水线）。

- [ ] **Step 3: 实现**

`AskLimits` 加 `public var timeBudget: Duration` 与 `init` 参数（默认 `.seconds(45)`）。`answer(...)` 开头 `let deadline = ContinuousClock().now.advanced(by: limits.timeBudget)`。

将两处 `throw AskAgentError.fallback` 改为：

```swift
func degrade(_ reason: String) async throws -> AskTranscript {
    await onStep?("agent-fallback:" + reason, 0)
    guard !shown.isEmpty else { throw AskAgentError.fallback }
    let result = AnswerGrounding.fallback(records: shown, reason: reason)
    await onStep?("agent-partial:" + reason, 0)
    return AskTranscript(content: result.content, citations: (result.sourceIDs + profileIDs).memoryUnique(), inspectedSourceIDs: (inspected + profileIDs).memoryUnique())
}
```

（局部闭包捕获 `shown/inspected` 为 `var`，Swift 6 下改成嵌套 `func` 并显式传参，或在两处直接内联。）

规划循环：`for round ... where !forceAnswer`，循环顶部 `if ContinuousClock().now >= deadline { forceAnswer = true; break }`。`MemoryAssistant.cloudAgentAnswer` 对 `.fallback` 的处理（`MemoryAssistant.swift:92-96`）不变。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS，含既有 `invalidPlanFallsBack`（无材料时仍应回退）。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "perf: 问一问加入时间预算，中途失败时用已读材料回答"
```

---

## Phase 6 / Task 13: 主题登记表数据模型与迁移

**Files:**
- Create: `Sources/RecallKit/Memory/TopicRegistry.swift`
- Modify: `Sources/RecallKit/Support/Storage.swift`（`RecallState.topicRegistry: [Topic]`，`CodingKeys`、`init(from:)`、`init`，约 107–280 行）
- Modify: `Verification/TopicRegistryVerification.swift`

**Interfaces:**
- Produces:

```swift
public struct Topic: Codable, Equatable, Identifiable, Sendable {
    public enum Lifecycle: String, Codable, Sendable { case active, dormant, done, archived }
    public var id: UUID
    public var title: String
    public var aliases: [String]          // 曾用名的 topicKey 或原始名字；归并时按 key 比较
    public var lifecycle: Lifecycle
    public var manualLifecycle: Lifecycle? // 用户手动标记优先
    public var parentID: UUID?             // 阶段 8 使用
    public var createdAt: Date
    public var lastEventAt: Date?
}

public struct TopicRegistry: Codable, Equatable, Sendable {
    public var topics: [Topic] = []
    public func topic(forName name: String) -> Topic?        // 比较 title 与 aliases 的 topicKey
    public func topic(id: UUID) -> Topic?
    public mutating func resolveOrCreate(name: String, at date: Date) -> Topic   // 找不到则新建
    public mutating func rename(id: UUID, to newTitle: String)                    // 旧 title 进 aliases
    public mutating func merge(_ sourceID: UUID, into targetID: UUID)             // 源 title/aliases 并入目标并删除源
    public mutating func remove(id: UUID)                                         // 删除主题及其别名
    public static func migrated(from state: RecallState) -> TopicRegistry         // 见下
}
```

迁移规则 `migrated(from:)`：对 `DailyKnowledgeEngine().matterFiles(in: state)`（此时 `topicAliases` 已生效）每个主题新建一个 `Topic`（`id` 用 `UUID` 由 `MatterEvidence.eventID`-风格的 SHA256 派生自 `file.id` 以保证幂等：同一存档多次迁移得到同一 UUID）；`aliases` = 该 `topicKey` 在 `topicAliases` 中作为 key 指向它的所有旧 key 对应的显示名（没有显示名则保存 key 本身）；`MemoryTopicGroup.memberIDs`、完成标记 `MatterCorrection.topicID`、`topicReviews[].id` 里引用的旧 `topic:key` 字符串保持有效——通过 `TopicRegistry.legacyID(for:)` 提供双向映射，登记表生效期间旧 ID 继续被识别（见 Task 14）。

- [ ] **Step 1: 写失败验证**

```swift
static func registry() throws {
    var registry = TopicRegistry()
    let a = registry.resolveOrCreate(name: "一键发版功能", at: .now)
    registry.rename(id: a.id, to: "一键发版上线")
    try expect(registry.topic(forName: "一键发版功能")?.id == a.id, "旧名应能解析到同一主题")
    try expect(registry.topic(forName: "一键发版上线")?.id == a.id, "新名也应解析到同一主题")
    try expect(registry.topics.count == 1, "改名不应新建主题")
    let b = registry.resolveOrCreate(name: "聊天多段回复合并", at: .now)
    registry.merge(b.id, into: a.id)
    try expect(registry.topic(forName: "聊天多段回复合并")?.id == a.id, "合并后源主题名成为别名")
    registry.remove(id: a.id)
    try expect(registry.topics.isEmpty && registry.topic(forName: "一键发版功能") == nil, "删除主题应连带删除别名")
}
```

另加迁移幂等场景：同一合成存档调用两次 `TopicRegistry.migrated(from:)`，得到相同的 `id` 集合；`state.topicRegistry` 解码旧存档（不含该键）为空数组。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 2>&1 | tail`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`topic(forName:)` 对 `title` 与每个 `alias` 用 `DailyKnowledgeEngine.topicKey` 比较。`resolveOrCreate` 查不到才新建，`id = UUID()`（迁移路径用确定性 UUID，见上）。`rename` 在 `aliases` 里加入旧 title（去重、忽略与新 title key 相同的）。`merge` 把源的 title 和 aliases 加入目标 aliases，`parentID` 指向源的子主题改指目标，然后删除源。`remove` 删除该主题，并把以它为 `parentID` 的子主题的 `parentID` 置空。

`RecallState` 加 `public var topicRegistry: TopicRegistry = TopicRegistry()`，`decodeIfPresent(...) ?? TopicRegistry()`。迁移触发：`FileMemoryStore` 启动维护阶段，若 `topicRegistry.topics.isEmpty` 且存在每日回顾，则 `topicRegistry = .migrated(from: state)` 并保存；迁移前把主存档备份写入既有 `Recovery/` 流程（沿用 `ArchiveReliability.write` 的备份行为，不新写一套）。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -10`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 新增主题登记表数据模型与旧主题迁移"
```

---

## Phase 6 / Task 14: 归并、完成标记与小结挂到稳定 ID

**Files:**
- Modify: `Sources/RecallKit/Memory/DailyKnowledge.swift:131-157`（`matterFiles` 通过登记表分桶）
- Modify: `Sources/RecallKit/Memory/MatterMemory.swift:180`（`MemoryTopicGroup.applying`）及所有读取 `topicID`/`topicReviews[].id`/`topicGroups.memberIDs` 的位置（`grep -rn "isTopicCompletion\|topicReviews\|memberIDs" Sources`）
- Modify: `Sources/RecallKit/Support/Storage.swift`（删除主题时联动，见 Task 16）
- Modify: `Verification/TopicRegistryVerification.swift`、`Verification/TopicCompletionVerification.swift`

**Interfaces:**
- `MatterFile.id` 继续是字符串（避免改动大量 UI 与持久化引用）：登记表启用后为 `"topic:" + topic.id.uuidString`。
- `TopicRegistry.legacyAliases: [String: UUID]`：旧 `topic:<key>` ID → 稳定 UUID。所有读取旧 ID 的位置（合并组 `memberIDs`、完成标记 `topicID`、`topicReviews[].id`、`ChatScope.topic(id)`）先用 `state.topicRegistry.canonicalID(_ id: String) -> String` 归一：形如 `topic:<uuid>` 原样返回；形如 `topic:<key>` 且命中 `legacyAliases` 则返回新 ID；否则原样返回。
- `matterFiles` 逻辑：对每个 entry 的 `topic` 名，`registry.topic(forName:)`；命中则归入该主题；未命中则 `resolveOrCreate`（纯函数版本：这里不修改 state，只在内存里生成临时主题；持久化由 Task 15 的「回顾写入后同步登记表」完成，避免在读路径写盘）。显示名 = `Topic.title`。

- [ ] **Step 1: 写失败验证**

场景（合成状态）：
1. 登记表里一个主题 `一键发版功能`；第二天每日回顾 topic 写成 `一键发版上线` 且登记表已把它作为 alias → `matterFiles` 单个主题，事件数 2。
2. 对该主题保存完成标记，随后重命名主题（`rename`）→ `matterFiles` 里该主题仍显示已完成（`applyingTopicCompletion` 通过 `canonicalID` 命中）。
3. 合并组 `memberIDs` 里仍是旧 `topic:key` → 归一后仍然生效。
4. `topicReviews` 里旧 ID 的小结在迁移后仍能被 `TopicReading(file:review:)` 取到（`review.id == file.id` 比较前先 `canonicalID`）。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | grep -i fail | head`
Expected: 对应场景失败。

- [ ] **Step 3: 实现**

1. `TopicRegistry` 加 `legacyAliases` 与 `canonicalID(_:)`；迁移时填充（旧 `topic:key` → 新 UUID）。
2. `matterFiles` 改造如上；`referenceFiles` 保持不变（资料类不入登记表）。
3. 把 `state.applyingTopicCompletion`、`MemoryTopicGroup.applying`、`topicReviews` 查找处统一用 `canonicalID`；`TopicReading.init` 里 `$0.id == file.id` 改为 `registry.canonicalID($0.id) == file.id`——需要把登记表传入，给 `TopicReading.init` 加参数 `registry: TopicRegistry = TopicRegistry()`（默认空表，保持旧调用点不坏）。
4. 登记表为空（尚未迁移/全新存档）时 `matterFiles` 回退到 Task 9 的别名路径，保证渐进上线。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS，含 `TopicCompletionVerification`、`MemoryKnowledgeVerification`、`KnowledgeProjectionVerification`（它们是旧 ID 兼容的回归保障）。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 合并组、完成标记与小结挂到稳定主题 ID"
```

---

## Phase 6 / Task 15: 每日回顾返回 topicID，写回登记表

**Files:**
- Modify: `Sources/RecallKit/Memory/DirectDailyReview.swift`（`prompt`、返回 JSON 解析、`DailyReviewDraft.Item`）
- Modify: `Sources/RecallKit/Memory/DailyKnowledge.swift`（`recentTopicNames` → 升级为 `recentTopics`，返回 `(id, title)`）
- Modify: `Sources/RecallKit/Support/Storage.swift`（保存每日回顾后同步登记表）
- Modify: `Verification/DirectDailyReviewVerification.swift`、`Verification/TopicRegistryVerification.swift`

**Interfaces:**
- 提示词传入 `[{"id":"<UUID>","title":"..."}]`（仅 id 与名字，最多 40 个，名字脱敏）。
- 模型每项返回 `topicID`（归入已有主题）或 `topic`（新建名字）。解析规则：`topicID` 必须是传入列表里的 id，否则忽略并按 `topic` 名字走新建/别名匹配；`topicID` 与 `topic` 同时给出且名字不同 → 视为模型的改名建议，`registry.rename(id:to:)`，旧名进 `aliases`。
- 持久化：新增 `FileMemoryStore.syncTopicRegistry(afterReviewOf day: Date)`，在每日回顾保存成功后遍历该日各条目的 `topic`，用 `resolveOrCreate` 补齐登记表（读路径不写）。

- [ ] **Step 1: 写失败验证**

1. 模型返回 `topicID` 指向已有主题且 `topic` 为新叫法 → 登记表主题数不变，旧名进 `aliases`。
2. 模型返回不存在的 `topicID` → 被忽略，按名字匹配/新建。
3. 发给模型的 prompt 含 id 与 title，不含原文。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | grep -i fail | head`
Expected: 失败。

- [ ] **Step 3: 实现**

提示词替换 Task 8 的「已有主题」段为：`已有主题（JSON，仅 id 与名称，不是当天证据）：[...]。事项属于其中某个时，在该项里写 "topicID":"<id>" 并把 topic 写成你认为合适的当前名称；确实是新事项才省略 topicID。`输出样例的 item 里增加 `"topicID":null`。解析在 `DailyReviewDraft.Item` 增加 `topicID: UUID?`，校验时对照传入列表。落库映射到 `DailyItemKnowledge.topicID: UUID?`（可选，`decodeIfPresent`），`matterFiles`（Task 14）优先用 `topicID` 归桶，其次用名字。`recentTopicNames` 保留给无登记表的降级路径。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 每日回顾按主题 ID 归入已有主题，改名保留旧名为别名"
```

---

## Phase 6 / Task 16: 生命周期、状态推断与删除联动

**Files:**
- Modify: `Sources/RecallKit/Memory/TopicRegistry.swift`
- Modify: `Sources/RecallKit/Memory/TopicListPresentation.swift`（`group` 改用生命周期）
- Modify: `Sources/RecallKit/Memory/DailyKnowledge.swift`（主题状态推断）
- Modify: `Sources/RecallKit/Support/Storage.swift`（删除主题联动，约 `removeCaptureState` 附近；`saveTopicGroup` 719 附近）
- Modify: `Sources/RecallApp/Views/MatterWorkspaceView.swift`（把「已完成与搁置」改为按生命周期）
- Modify: `Verification/TopicRegistryVerification.swift`

**Interfaces:**
- Produces:
  - `TopicRegistry.lifecycle(of file: MatterFile, topic: Topic, now: Date, calendar: Calendar) -> Topic.Lifecycle`：
    1. `topic.manualLifecycle` 优先；
    2. 最近事件 `status == .completed` 且其后没有更晚的非完成事件 → `.done`；
    3. `file.needsStatusUpdate(at:)`（14 天无动静且仍为开放状态）→ `.dormant`；
    4. 其余 `.active`。
    有新事件自动唤醒：因为每次投影重新推断，`dormant` 在出现新事件后自然回到 `.active`；`done` 之后出现新的非完成事件同样回到 `.active`（修复「完成后再记一条又被拉回」不是问题——这里完成后再有推进应当回到进行中，但仅当该事件日期晚于完成事件）。
  - 状态展示：`MatterFile` 增加计算属性 `inferredStatusLabel`？不新增存储；卡片状态点用 `lifecycle`。
  - `FileMemoryStore.deleteTopic(id: String)`：删除登记表条目（含别名）、该主题的 `topicReviews`、完成标记、合并组成员、主题会话（Task 18 之后）、`topicAliases` 中指向它的项；不删除原始截图/记录。需要用户确认的 UI 文案写明「不会删除原始记录」。

- [ ] **Step 1: 写失败验证**

1. 14 天前的开放主题 → `.dormant`；之后追加一条新事件 → `.active`。
2. 完成事件为最新 → `.done`；完成后更晚的 `.progressed` 事件 → `.active`。
3. `manualLifecycle = .done` 时即使最近事件是 `.progressed` 也为 `.done`；清除手动标记后恢复推断。
4. `deleteTopic` 后：登记表无该主题、`topicReviews`/完成标记/合并组成员/别名都不再引用它；原始 `captures` 数量不变。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | grep -i fail | head`
Expected: 失败。

- [ ] **Step 3: 实现**

按上述接口实现；`TopicListPresentation.group` 的签名保持 `(files, now, calendar)`，新增可选参数 `registry: TopicRegistry = .init()`，有登记表时以 `lifecycle` 分组（`.active` 进 active，其余进 done），无登记表保持 Task 6 的行为。`deleteTopic` 在同一次 `persist` 里完成所有联动，失败回滚 `state = before`，沿用 `addMessage` 的模式。UI 的卡片菜单加「删除主题」（带确认，说明不会删原始记录）。「标记完成」写 `manualLifecycle = .done`，「撤销完成标记」清除它，同时保留现有 `MatterCorrection.isTopicCompletion` 的写入以兼容旧逻辑，直到该字段在 Task 14 后不再被读取再清理（本计划不做清理）。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 主题生命周期推断、用户标记优先与删除联动"
```

---

## Phase 7 / Task 17: 结构化会话状态

**Files:**
- Create: `Sources/RecallKit/Chat/ConversationSession.swift`
- Modify: `Sources/RecallKit/Chat/AskAgent.swift`（`historyBlock`、候选合并、目录只在首轮发送）
- Modify: `Sources/RecallKit/Chat/MemoryAssistant.swift`（回退路径改用同一状态；删除 `ConversationContextManager` 的滚动摘要使用）
- Modify: `Sources/RecallKit/Chat/LLMClient.swift:313-440`（移除 `compact` 截断拼接摘要；类型保留其余有用部分或整体删除）
- Modify: `Sources/RecallKit/Support/Storage.swift`（`conversationSummary*` 字段保留解码但不再使用，写入置空）
- Create: `Verification/ConversationSessionVerification.swift`

**Interfaces:**
- Produces:

```swift
public struct ConversationSession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var topicID: String?               // nil 为全局会话
    public var scope: ChatScopeSnapshot        // 当前时间范围/应用范围，见下
    public var lastCitedSourceIDs: [UUID]      // 上一轮回答引用的来源
    public var recentTurns: [ConversationMessage] // 最近 N 轮（N=6 条消息）
    public var updatedAt: Date
}
public struct ChatScopeSnapshot: Codable, Equatable, Sendable { public var topicID: String?; public var from: Date?; public var to: Date? }
```

- 行为：
  1. 追问（问题含「这个/那个/它/继续/刚才/上面」，或 `recentTurns` 最近一条是助手回答且问题很短（< 12 字））时，`lastCitedSourceIDs` 对应的来源在第一次规划前先放进候选（与 Task 10 的候选合并，上一轮来源排在前）。
  2. `historyBlock` 与回退路径的历史上下文改为从同一个 `ConversationSession.recentTurns` 生成（同一函数 `ConversationSession.historyText(redactedBy:)`），消除两条路径看到的上下文不一致。
  3. 删除基于截断拼接的滚动摘要：`ConversationContextManager.compact` 不再被调用；`state.conversationSummary` 不再写入。
  4. 目录（`catalog`）只在第一轮规划发送；第二轮规划只发增量的工具结果，不再重复目录。`planningQuestion` 在 `round > 1` 时省略 `目录：` 段。

- [ ] **Step 1: 写失败验证**

```swift
// Verification/ConversationSessionVerification.swift
static func followUpReusesPreviousSources() async throws {
    let (storage, store, capture) = try await AskAgentVerification.fixture("AtlasScopeToken was saved")
    defer { try? FileManager.default.removeItem(at: storage.rootURL) }
    let first = ScriptedAskModel { _ in LLMAnswer(content: #"{"answer":"已记录 AtlasScopeToken [1]","citations":[""# + capture.id.uuidString + #""]}"#, citedCaptureIDs: []) }
    _ = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: first)
    let second = ScriptedAskModel { request in
        try expectSync(request.context.contains { $0.id == capture.id }, "追问应预置上一轮来源")
        return LLMAnswer(content: #"{"answer":"它还在 [1]","citations":[""# + capture.id.uuidString + #""]}"#, citedCaptureIDs: [])
    }
    _ = try await MemoryAssistant(store: store).ask("这个后来怎么样了", model: second)
    let calls = await second.recorded()
    try expect(calls.first?.purpose == .chatPlanning, "追问仍从规划开始")
}

static func roundTwoOmitsCatalog() async throws { /* 两轮规划，第二轮 question 不含 "目录：" */ }
static func historyIsIdenticalOnBothPaths() async throws { /* Agent 路径与回退路径的历史文本相同 */ }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 2>&1 | tail`
Expected: 编译失败或断言失败。

- [ ] **Step 3: 实现**

`ConversationSession` 持久化：存入 Task 5 的 sidecar 文件（`conversation.json` 改为 `{ "sessions": [...], "activeID": UUID }`；Task 5 时是裸 `[ConversationMessage]`，本任务的读取要同时兼容旧格式：先尝试解码新结构，失败再把旧数组包成一个全局会话）。`MemoryAssistant.ask` 在回答后更新当前会话的 `lastCitedSourceIDs = answer.citations`、`recentTurns`。保持 `state.messages` 作为「当前会话消息」的视图，UI 不用大改。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 问一问统一为结构化会话状态，追问复用上一轮来源"
```

---

## Phase 7 / Task 18: 每个主题一个会话，删除主题联动删除会话

**Files:**
- Modify: `Sources/RecallKit/Chat/ConversationSession.swift`、`Sources/RecallKit/Support/Storage.swift`（会话集合、`activateSession(topicID:)`、`clearConversation`）
- Modify: `Sources/RecallApp/RecallAppModel.swift`（`chatScope` 切换处，`continueChat(topicID)` 调用链）
- Modify: `Sources/RecallApp/Views/MatterWorkspaceView.swift:continueChat`
- Modify: `Sources/RecallKit/Support/Storage.swift` 的 `deleteTopic`（Task 16）加上删除对应会话
- Modify: `Verification/ConversationSessionVerification.swift`

**Interfaces:**
- `FileMemoryStore.activateSession(topicID: String?) throws -> ConversationSession`：存在则恢复，不存在则新建；同时把 `state.messages` 切换为该会话的消息，并更新 `conversationID`（沿用运行时身份，避免在途回答污染新会话——参考 `Storage.swift:307` 的注释）。
- `FileMemoryStore.deleteSession(topicID:)`。
- 清空会话只清空当前会话。

- [ ] **Step 1: 写失败验证**

1. 主题 A 会话里的消息，切到主题 B 后不可见，也不出现在发给模型的 `historyBlock` 里。
2. 切回 A，消息恢复。
3. `deleteTopic(A)` 后，A 的会话从 sidecar 消失；B 与全局会话不受影响。
4. 在途回答属于已切走的会话时，`addMessage(inConversation:)` 抛 `CancellationError`（现有语义，验证它对多会话仍成立）。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | grep -i fail | head`
Expected: 失败。

- [ ] **Step 3: 实现**

`RecallAppModel` 里「继续问」设置 `chatScope = .topic(id)` 的位置，同时调用 `store.activateSession(topicID: id)` 并刷新 `state.messages`；回到全局问答时 `activateSession(topicID: nil)`。会话切换必须在主线程 UI 状态更新之前完成存储层切换，避免用户在切换瞬间发送消息落入错误会话（发送时带 `conversationID` 校验，已有机制）。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS。

- [ ] **Step 5: 手动验收（需完整 Xcode）**

从主题 A「继续问」提问→返回列表→从主题 B「继续问」→确认看不到 A 的对话；删除主题 A→再次进入 A 的位置不再有历史。

- [ ] **Step 6: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 每个主题一个问一问会话，删除主题时连带删除"
```

---

## Phase 8 / Task 19: 项目层级

**Files:**
- Modify: `Sources/RecallKit/Memory/TopicRegistry.swift`（`parentID` 已在 Task 13 预留；加 `TopicRegistry.children(of:)`、`setParent(_:of:)`、防环）
- Modify: `Sources/RecallKit/Memory/DirectDailyReview.swift`（可选：提示词传入「项目」候选，仅 id+title）
- Modify: `Sources/RecallKit/Memory/TopicListPresentation.swift`（`groupedByProject`）
- Modify: `Sources/RecallApp/Views/MatterWorkspaceView.swift`（按项目分组展示、设置所属项目的菜单）
- Modify: `Verification/TopicRegistryVerification.swift`

**Interfaces:**
- Produces:
  - `Topic.isProject: Bool`（默认 `false`；项目是没有直接事件、仅作为分组的主题条目）。
  - `TopicRegistry.setParent(_ parentID: UUID?, of id: UUID) -> Bool`：拒绝自指与成环，返回是否成功。
  - `TopicListPresentation.groupedByProject(_ files: [MatterFile], registry: TopicRegistry) -> [(project: Topic?, files: [MatterFile])]`：无父项目的主题归入 `project == nil` 组放最后。
- 范围：只支持两级（项目 → 主题）。用户手动创建项目并把主题拖入/通过菜单设置所属项目；模型不自动建项目（避免新增未确认的模型行为，符合文档「产品决策」的保守做法）。

- [ ] **Step 1: 写失败验证**

1. `setParent` 自指/成环返回 `false` 且不改变数据。
2. 项目下的主题按项目分组，无项目的归入末组。
3. 删除项目：子主题的 `parentID` 置空而不被删除。
4. 项目的生命周期不参与推断（项目只是容器）。
5. 删除子主题不影响项目；项目没有子主题时默认隐藏于列表（或显示为空分组，选其一，验证与 UI 一致）。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | grep -i fail | head`
Expected: 失败。

- [ ] **Step 3: 实现**

按接口实现；UI：列表在存在至少一个项目时按项目分段显示（每段一个可折叠标题），否则保持 Task 7 的平铺；卡片右键菜单增加「设置所属项目…」子菜单（列出现有项目 + 「新建项目…」+「移出项目」）。项目的创建/重命名/删除放入「…」菜单的「管理项目」，每个动作都有确认并写入登记表（用户明确触发）。

- [ ] **Step 4: 运行验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -15`
Expected: 全部 PASS。

- [ ] **Step 5: 手动验收（需完整 Xcode）**

新建项目、移入主题、折叠、删除项目、搜索时跨项目命中、重启 App 后层级保留。

- [ ] **Step 6: Commit**

```bash
git add -A Sources Verification
git commit -m "feat: 主题按项目分组，项目层级由用户手动维护"
```

---

## Task 20: 收尾——文档与全量验证

**Files:**
- Modify: `docs/memory-topics-and-ask-review.md`（各阶段标注已完成与提交号）
- Modify: `docs/memory-architecture.md`、`docs/product-behavior.zh-Hans.md`（登记表、会话、主题列表的新行为各一小节）
- Modify: `docs/PRIVACY.md`、`docs/PRIVACY.en.md`（说明每日回顾新增传入「已有主题 id 与名称」；主题与会话的删除联动）

- [ ] **Step 1: 全量验证**

Run: `swift build --jobs 1 && swift run RecallVerifier 2>&1 | tail -30`
Expected: 全部 PASS，无新增警告。

- [ ] **Step 2: 更新文档并提交**

```bash
git add docs
git commit -m "docs: 同步主题登记表、会话与隐私说明"
```

- [ ] **Step 3: 汇报**

写明：已通过的命令输出；未做的图形/权限类手动验收（Task 7、18、19 的手动项），逐项列出，不得声称完成端到端验收。

---

## Self-Review

**Spec coverage（对照原文档）**

| 文档条目 | 任务 |
|---|---|
| §6 阶段 0 诊断耗时 | Task 1 |
| §4 优化 5：sidecar、`validate()` 修订号、主线程、去重 transcript | Task 5、2、4、3 |
| §1 优化 1、2、4、5；优化 3 状态点与分组 | Task 6、7（状态点、分组折叠、分段控件、相对时间） |
| §2 优化 1、2（传入主题名、别名） | Task 8、9 |
| §4 优化 2、3、4 | Task 10、11、12 |
| §4 优化 1（选 B） | Task 11（本地预检 + 条件性模型核对） |
| §3 / §2 优化 4（登记表、生命周期、状态推断、迁移、删除联动） | Task 13–16 |
| §5 优化 1–4 | Task 17、18 |
| §2 优化 3（项目层级） | Task 19 |
| §2 优化 5 卡片用 title | Task 6 |
| §2 优化 6 淘汰正则兜底、标「待确认」 | **未覆盖**：文档写「逐步淘汰」，不在 9 个阶段的推进表里；本计划不做，如需要另开任务 |

**Placeholder 说明（诚实记录）**：Task 4、14、15、17、18、19 中，部分步骤依赖落地时才能确定的现有符号（例如 `LLMRequest.Purpose` 的具体枚举值、`MatterEvent` 的完整初始化签名、`ScriptedAskModel`/`fixture` 的可见性），我已在对应步骤里写明「以某文件某行为准」并给出查看位置；这些不是占位，而是需要在执行时对照代码核实的名字。Task 14–19 的验证代码给出了场景清单与断言内容，但没有逐条写出完整 Swift，实现者按 Task 6、13 的写法补全。

**类型一致性**：`TopicReading.headline`（Task 6）、`TopicListPresentation.group(_:now:calendar:)`（Task 6，Task 16 加可选 `registry` 参数）、`TopicRegistry`/`Topic`（Task 13，被 14–19 使用）、`DailyKnowledgeEngine.canonicalKey`（Task 9，Task 14 之后在登记表为空时作为降级路径）、`ConversationSession`（Task 17，Task 18 扩展）。`conversation.json` 格式在 Task 5（裸数组）与 Task 17（会话结构）之间变更，Task 17 要求兼容读取旧格式。

**风险提示**
- Task 11 改变核对输出格式，会影响既有 `AskAgentVerification` 中依赖 `{"claims":[...]}` 的断言，需要同步更新。
- Task 13–16 动数据模型，迁移前依赖既有 `Recovery/` 备份；建议在 Task 13 合并后单独做一次真实存档的复制品演练（不提交任何真实数据）。
- Task 2 的 `captureContentRevision` 在 `writeState()` 内哈希全部截图文本，存档极大时会增加每次写盘的 CPU，需在 Task 1 的耗时数据里确认收益大于成本。
