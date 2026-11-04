import Foundation
import RecallKit

enum MemoryReminderActionsVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func run() async throws {
        try dismissalIdentity()
        try await dismissalPersistence()
        try await reminderPersistence()
        print("PASS: 3 memory/reminder action suites (cross-topic dismissal, durable preferences, manual save/cache/rollback)")
    }
    private static func event(_ text: String) -> MatterEvent {
        MatterEvent(id: UUID(), title: "Atlas 合成验收", detail: text, recordedAt: .now.addingTimeInterval(-86_400),
            status: .completed, evidenceIDs: [UUID()])
    }
    private static func dismissalIdentity() throws {
        let past = event("Atlas 合成验收通过，保留完整结果。")
        let a = ExperienceHint(currentID: "topic:a", past: past, matchingTerms: ["Atlas", "验收"])
        let b = ExperienceHint(currentID: "topic:b", past: past, matchingTerms: ["Atlas", "验收"])
        let regenerated = ExperienceHint(currentID: "topic:c", past: event("Atlas 合成验收通过，保留完整结果。"), matchingTerms: ["验收"])
        try expect(a.id == b.id && regenerated.id == a.id, "相同历史经验换主题或重新整理后仍会重复提示")
        try expect(b.isDismissed(using: [a.id]), "关闭操作只影响一个主题")
        try expect(a.isDismissed(using: ["legacy-topic:" + past.id.uuidString]), "旧版本的关闭记录不再生效")
        let other = ExperienceHint(currentID: "topic:a", past: event("Nova 新的独立验收结果。"), matchingTerms: [])
        try expect(!other.isDismissed(using: [a.id]), "关闭一条经验误隐藏了其他结果")
    }
    private static func dismissalPersistence() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        try await store.dismissExperience(id: "experience:synthetic")
        try await store.dismissExperience(id: "experience:synthetic")
        try await store.setExperienceHints(enabled: false)
        let reopened = try verificationStore(storage: storage), snapshot = await reopened.snapshot()
        try expect(snapshot.dismissedExperienceIDs == ["experience:synthetic"] && !snapshot.experienceHintsEnabled,
            "重启丢失了关闭记录或重复追加了相同 ID")
        let backup = storage.stateURL.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: storage.stateURL, withIntermediateDirectories: false)
        do { try await store.dismissExperience(id: "experience:must-fail"); throw Failure(message: "不可写路径被当作保存成功") }
        catch is Failure { throw Failure(message: "不可写路径被当作保存成功") } catch {}
        do { try await store.setExperienceHints(enabled: true); throw Failure(message: "设置写入失败没有上报") }
        catch is Failure { throw Failure(message: "设置写入失败没有上报") } catch {}
        let failed = await store.snapshot()
        try expect(failed.dismissedExperienceIDs == snapshot.dismissedExperienceIDs && !failed.experienceHintsEnabled, "写入失败留下了虚假的内存状态")
    }
    private static func reminderPersistence() async throws {
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        _ = await store.preparedForChat()
        var row = ReminderCandidate(title: "核对手动合成提醒", detail: "保留全部手动说明", dueAt: now.addingTimeInterval(86_400),
            confidence: 1, status: .proposed, createdAt: now, updatedAt: now, origin: .manual, recurrence: .weekly)
        try await store.updateReminder(row)
        let prepared = await store.preparedForChat()
        try expect(prepared.reminders.first?.id == row.id, "手动提醒保存后问一问仍使用旧缓存")
        row.status = .scheduled; row.scheduledAt = now
        try await store.updateReminder(row)
        let reopened = try verificationStore(storage: storage), saved = await reopened.snapshot()
        try expect(saved.reminders == [row] && row.sourceCaptureIDs.isEmpty, "手动提醒因没有截图来源而丢失或状态未保存")
        let backup = storage.stateURL.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: storage.stateURL, withIntermediateDirectories: false)
        var changed = row; changed.status = .completed
        do { try await store.updateReminder(changed); throw Failure(message: "写入失败被当作完成成功") }
        catch is Failure { throw Failure(message: "写入失败被当作完成成功") } catch {}
        var profile = saved.reminderLearningProfile; profile.preferredHourHistogram["9"] = 99
        do { try await store.updateReminder(changed, learningProfile: profile); throw Failure(message: "反馈写入失败被忽略") }
        catch is Failure { throw Failure(message: "反馈写入失败被忽略") } catch {}
        let failed = await store.snapshot()
        try expect(failed.reminders == saved.reminders && failed.reminderLearningProfile == saved.reminderLearningProfile,
            "提醒或学习偏好没有随失败写入回滚")
    }
}
