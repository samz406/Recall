import Foundation

public enum CaptureEventTemplate: String, CaseIterable, Codable, Identifiable, Sendable {
    case manualMoment
    case workCheckpoint
    case webResearchClip
    case meetingSession
    case taskCommitment
    case documentMilestone
    case taskTransition
    case dailyReview
    case enterKeyTrigger

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manualMoment: "手动记录此刻"
        case .workCheckpoint: "当前窗口工作节点"
        case .webResearchClip: "网页研究摘录"
        case .meetingSession: "会议开始与结束"
        case .taskCommitment: "待办或承诺创建"
        case .documentMilestone: "文件或文档里程碑"
        case .taskTransition: "任务切换复盘"
        case .dailyReview: "定时个人回顾"
        case .enterKeyTrigger: "Enter 键触发记录"
        }
    }

    public var summary: String {
        switch self {
        case .manualMoment: "通过菜单栏按钮或组合快捷键主动记录当前上下文。"
        case .workCheckpoint: "在白名单应用中，用组合快捷键保存一个工作节点。"
        case .webResearchClip: "主动保存当前网页或选区，用于后续研究检索。"
        case .meetingSession: "以用户明确的开始与结束动作为会议建立可追溯记录。"
        case .taskCommitment: "保存用户确认的待办、承诺或截止事项。"
        case .documentMilestone: "记录文档、设计稿或代码工作中的阶段性版本。"
        case .taskTransition: "在切换任务时形成简短的工作复盘。"
        case .dailyReview: "定时汇总已有的显式记录，不额外截取屏幕。"
        case .enterKeyTrigger: "由你明确启用后，在其他应用按 Enter 时记录当前窗口；默认关闭。"
        }
    }

    public var defaultShortcut: String? {
        switch self {
        case .manualMoment: "⌥↩"
        case .workCheckpoint: "⌃⌥↩"
        case .enterKeyTrigger: "↩"
        default: nil
        }
    }

    public var requiresScreenCapture: Bool {
        switch self {
        case .manualMoment, .workCheckpoint, .webResearchClip, .meetingSession, .documentMilestone, .taskTransition, .enterKeyTrigger:
            true
        case .taskCommitment, .dailyReview:
            false
        }
    }
}

public enum CaptureScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case selectedWindow
    case activeDisplay
    case textOnly

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .selectedWindow: "当前窗口"
        case .activeDisplay: "当前显示器"
        case .textOnly: "仅文本"
        }
    }
}

public enum CloudUsePolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case never
    case onDemand

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .never: "永不发送到云端"
        case .onDemand: "仅在我明确提问时"
        }
    }
}

public struct EventRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var template: CaptureEventTemplate
    public var isEnabled: Bool
    public var scope: CaptureScope
    public var shortcut: String?
    public var appAllowList: [String]
    public var retainImageDays: Int
    public var retainTextDays: Int
    public var participatesInChat: Bool
    public var participatesInReminders: Bool
    public var cloudUsePolicy: CloudUsePolicy

    public init(
        id: UUID = UUID(),
        template: CaptureEventTemplate,
        isEnabled: Bool,
        scope: CaptureScope,
        shortcut: String? = nil,
        appAllowList: [String] = [],
        retainImageDays: Int = 7,
        retainTextDays: Int = 90,
        participatesInChat: Bool = true,
        participatesInReminders: Bool = false,
        cloudUsePolicy: CloudUsePolicy = .never
    ) {
        self.id = id
        self.template = template
        self.isEnabled = isEnabled
        self.scope = scope
        self.shortcut = shortcut
        self.appAllowList = appAllowList
        self.retainImageDays = retainImageDays
        self.retainTextDays = retainTextDays
        self.participatesInChat = participatesInChat
        self.participatesInReminders = participatesInReminders
        self.cloudUsePolicy = cloudUsePolicy
    }

    public static func defaults() -> [EventRule] {
        CaptureEventTemplate.allCases.map { template in
            EventRule(
                template: template,
                isEnabled: [.manualMoment, .workCheckpoint, .taskCommitment, .dailyReview].contains(template),
                scope: template.requiresScreenCapture ? .selectedWindow : .textOnly,
                shortcut: template.defaultShortcut,
                appAllowList: template == .workCheckpoint ? ["com.apple.Notes", "notion.id"] : [],
                retainImageDays: template == .dailyReview ? 0 : 7,
                retainTextDays: 90,
                participatesInChat: true,
                participatesInReminders: [
                    .manualMoment,
                    .workCheckpoint,
                    .meetingSession,
                    .taskCommitment,
                    .documentMilestone,
                    .taskTransition
                ].contains(template),
                cloudUsePolicy: .never
            )
        }
    }
}

public struct CaptureRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var eventTemplate: CaptureEventTemplate
    public var createdAt: Date
    public var sourceAppName: String?
    public var sourceBundleIdentifier: String?
    public var windowTitle: String?
    public var imageRelativePath: String?
    public var contentHash: String
    public var isRedacted: Bool
    public var ocrText: String
    public var summary: String?
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        eventTemplate: CaptureEventTemplate,
        createdAt: Date = .now,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        imageRelativePath: String? = nil,
        contentHash: String,
        isRedacted: Bool = false,
        ocrText: String,
        summary: String? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.eventTemplate = eventTemplate
        self.createdAt = createdAt
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.windowTitle = windowTitle
        self.imageRelativePath = imageRelativePath
        self.contentHash = contentHash
        self.isRedacted = isRedacted
        self.ocrText = ocrText
        self.summary = summary
        self.tags = tags
    }
}

public struct MemoryChunk: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var captureID: UUID
    public var text: String
    public var ordinal: Int

    public init(id: UUID = UUID(), captureID: UUID, text: String, ordinal: Int) {
        self.id = id
        self.captureID = captureID
        self.text = text
        self.ordinal = ordinal
    }
}

public enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct ConversationMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var content: String
    public var createdAt: Date
    public var citations: [UUID]

    public init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = .now, citations: [UUID] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.citations = citations
    }
}

public enum ReminderStatus: String, Codable, Sendable {
    case proposed
    case scheduled
    case snoozed
    case completed
    case dismissed
    case cancelled
}

public enum ReminderOrigin: String, Codable, CaseIterable, Sendable {
    case discovered
    case manual
    case migrated

    public var title: String {
        switch self {
        case .discovered: "从记忆发现"
        case .manual: "手动创建"
        case .migrated: "历史提醒"
        }
    }
}

public enum ReminderRecurrence: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "不重复"
        case .daily: "每天"
        case .weekly: "每周"
        case .monthly: "每月"
        }
    }

    public func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .none: nil
        case .daily: calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
        }
    }
}

public struct ReminderDiscoveryCheckpoint: Codable, Hashable, Sendable {
    public var processedCaptureHashes: [String: String]
    public var lastRunAt: Date?
    public var eligibleRecordCount: Int
    public var analyzedRecordCount: Int
    public var discoveredCount: Int

    public init(
        processedCaptureHashes: [String: String] = [:],
        lastRunAt: Date? = nil,
        eligibleRecordCount: Int = 0,
        analyzedRecordCount: Int = 0,
        discoveredCount: Int = 0
    ) {
        self.processedCaptureHashes = processedCaptureHashes
        self.lastRunAt = lastRunAt
        self.eligibleRecordCount = eligibleRecordCount
        self.analyzedRecordCount = analyzedRecordCount
        self.discoveredCount = discoveredCount
    }
}

public struct ReminderFeedbackStats: Codable, Hashable, Sendable {
    public var confirmed: Int
    public var dismissed: Int
    public var completed: Int
    public var snoozed: Int
    public var updatedAt: Date

    public init(confirmed: Int = 0, dismissed: Int = 0, completed: Int = 0, snoozed: Int = 0, updatedAt: Date = .now) {
        self.confirmed = confirmed
        self.dismissed = dismissed
        self.completed = completed
        self.snoozed = snoozed
        self.updatedAt = updatedAt
    }
}

public enum ReminderFeedbackEvent: Sendable {
    case confirmed(hour: Int)
    case dismissed
    case completed
    case snoozed(hour: Int)
}

public struct ReminderLearningProfile: Codable, Hashable, Sendable {
    public var semanticFeedback: [String: ReminderFeedbackStats]
    public var preferredHourHistogram: [String: Int]

    public init(
        semanticFeedback: [String: ReminderFeedbackStats] = [:],
        preferredHourHistogram: [String: Int] = [:]
    ) {
        self.semanticFeedback = semanticFeedback
        self.preferredHourHistogram = preferredHourHistogram
    }

    public mutating func record(_ event: ReminderFeedbackEvent, semanticKey: String, now: Date = .now) {
        guard !semanticKey.isEmpty else { return }
        var stats = semanticFeedback[semanticKey] ?? ReminderFeedbackStats(updatedAt: now)
        switch event {
        case .confirmed(let hour):
            stats.confirmed += 1
            preferredHourHistogram[String(hour), default: 0] += 1
        case .dismissed:
            stats.dismissed += 1
        case .completed:
            stats.completed += 1
        case .snoozed(let hour):
            stats.snoozed += 1
            preferredHourHistogram[String(hour), default: 0] += 1
        }
        stats.updatedAt = now
        semanticFeedback[semanticKey] = stats
    }

    public func confidenceAdjustment(for semanticKey: String) -> Double {
        guard let stats = semanticFeedback[semanticKey] else { return 0 }
        return min(Double(stats.confirmed + stats.completed) * 0.04, 0.12)
            - min(Double(stats.dismissed) * 0.08, 0.24)
    }

    public var preferredHour: Int {
        preferredHourHistogram
            .compactMap { key, value in Int(key).map { ($0, value) } }
            .max { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 > rhs.0 : lhs.1 < rhs.1 }?.0 ?? 9
    }
}

public struct ReminderCandidate: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var dueAt: Date?
    public var sourceCaptureIDs: [UUID]
    public var confidence: Double
    public var status: ReminderStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var origin: ReminderOrigin
    public var recurrence: ReminderRecurrence
    public var semanticKey: String
    public var scheduledAt: Date?
    public var completedAt: Date?
    public var dismissedUntil: Date?
    public var snoozeCount: Int

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        dueAt: Date? = nil,
        sourceCaptureIDs: [UUID] = [],
        confidence: Double,
        status: ReminderStatus = .proposed,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        origin: ReminderOrigin = .discovered,
        recurrence: ReminderRecurrence = .none,
        semanticKey: String = "",
        scheduledAt: Date? = nil,
        completedAt: Date? = nil,
        dismissedUntil: Date? = nil,
        snoozeCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueAt = dueAt
        self.sourceCaptureIDs = sourceCaptureIDs
        self.confidence = confidence
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.origin = origin
        self.recurrence = recurrence
        self.semanticKey = semanticKey
        self.scheduledAt = scheduledAt
        self.completedAt = completedAt
        self.dismissedUntil = dismissedUntil
        self.snoozeCount = snoozeCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, detail, dueAt, sourceCaptureIDs, confidence, status, createdAt
        case updatedAt, origin, recurrence, semanticKey, scheduledAt, completedAt, dismissedUntil, snoozeCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        sourceCaptureIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceCaptureIDs) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.7
        status = try container.decodeIfPresent(ReminderStatus.self, forKey: .status) ?? .proposed
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        origin = try container.decodeIfPresent(ReminderOrigin.self, forKey: .origin) ?? .migrated
        recurrence = try container.decodeIfPresent(ReminderRecurrence.self, forKey: .recurrence) ?? .none
        semanticKey = try container.decodeIfPresent(String.self, forKey: .semanticKey) ?? ""
        scheduledAt = try container.decodeIfPresent(Date.self, forKey: .scheduledAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        dismissedUntil = try container.decodeIfPresent(Date.self, forKey: .dismissedUntil)
        snoozeCount = try container.decodeIfPresent(Int.self, forKey: .snoozeCount) ?? 0
    }
}

public struct PrivacySettings: Codable, Hashable, Sendable {
    public var excludedBundleIdentifiers: Set<String>
    public var cloudUseEnabled: Bool
    public var retainScreenshots: Bool
    public var screenCapturePaused: Bool

    public init(
        excludedBundleIdentifiers: Set<String> = ["com.apple.keychainaccess", "com.apple.Passwords", "com.apple.MobileSMS"],
        cloudUseEnabled: Bool = false,
        retainScreenshots: Bool = true,
        screenCapturePaused: Bool = false
    ) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.cloudUseEnabled = cloudUseEnabled
        self.retainScreenshots = retainScreenshots
        self.screenCapturePaused = screenCapturePaused
    }
}

public struct CapturePayload: Sendable {
    public var imageData: Data?
    public var sourceAppName: String?
    public var sourceBundleIdentifier: String?
    public var windowTitle: String?

    public init(imageData: Data?, sourceAppName: String?, sourceBundleIdentifier: String?, windowTitle: String?) {
        self.imageData = imageData
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.windowTitle = windowTitle
    }
}
