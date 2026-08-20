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
        }
    }

    public var defaultShortcut: String? {
        switch self {
        case .manualMoment: "⌥↩"
        case .workCheckpoint: "⌃⌥↩"
        default: nil
        }
    }

    public var requiresScreenCapture: Bool {
        switch self {
        case .manualMoment, .workCheckpoint, .webResearchClip, .meetingSession, .documentMilestone, .taskTransition:
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
                participatesInReminders: [.taskCommitment, .dailyReview].contains(template),
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
    case completed
    case dismissed
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

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        dueAt: Date? = nil,
        sourceCaptureIDs: [UUID] = [],
        confidence: Double,
        status: ReminderStatus = .proposed,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueAt = dueAt
        self.sourceCaptureIDs = sourceCaptureIDs
        self.confidence = confidence
        self.status = status
        self.createdAt = createdAt
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
