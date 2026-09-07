import Foundation

public enum WorkEpisodeStatus: String, Codable, Sendable {
    case explored
    case progressed
    case completed
    case pending
    case blocked
}

public struct WorkEpisode: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var day: Date
    public var startedAt: Date
    public var endedAt: Date
    public var projectKey: String
    public var projectName: String
    public var title: String
    public var intent: String
    public var action: String
    public var outcome: String?
    public var nextAction: String?
    public var status: WorkEpisodeStatus
    public var importance: Double
    public var confidence: Double
    public var sourceApps: [String]
    public var evidenceIDs: [UUID]

    public init(
        id: UUID = UUID(),
        day: Date,
        startedAt: Date,
        endedAt: Date,
        projectKey: String,
        projectName: String,
        title: String,
        intent: String,
        action: String,
        outcome: String? = nil,
        nextAction: String? = nil,
        status: WorkEpisodeStatus,
        importance: Double,
        confidence: Double,
        sourceApps: [String],
        evidenceIDs: [UUID]
    ) {
        self.id = id
        self.day = Calendar.current.startOfDay(for: day)
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.projectKey = projectKey
        self.projectName = projectName
        self.title = title
        self.intent = intent
        self.action = action
        self.outcome = outcome
        self.nextAction = nextAction
        self.status = status
        self.importance = min(max(importance, 0), 1)
        self.confidence = min(max(confidence, 0), 1)
        self.sourceApps = sourceApps
        self.evidenceIDs = evidenceIDs
    }
}

public struct ProjectState: Identifiable, Codable, Hashable, Sendable {
    public var id: String { projectKey }
    public var projectKey: String
    public var displayName: String
    public var goal: String?
    public var currentState: String
    public var nextAction: String?
    public var blockers: [String]
    public var evidenceIDs: [UUID]
    public var confidence: Double
    public var lastActiveAt: Date
    public var updatedAt: Date

    public init(
        projectKey: String,
        displayName: String,
        goal: String? = nil,
        currentState: String,
        nextAction: String? = nil,
        blockers: [String] = [],
        evidenceIDs: [UUID] = [],
        confidence: Double,
        lastActiveAt: Date,
        updatedAt: Date = .now
    ) {
        self.projectKey = projectKey
        self.displayName = displayName
        self.goal = goal
        self.currentState = currentState
        self.nextAction = nextAction
        self.blockers = blockers
        self.evidenceIDs = evidenceIDs
        self.confidence = min(max(confidence, 0), 1)
        self.lastActiveAt = lastActiveAt
        self.updatedAt = updatedAt
    }
}

public enum UserMemoryKind: String, Codable, CaseIterable, Sendable {
    case preference
    case goal
    case constraint
    case habit
    case workflowLesson

    public var title: String {
        switch self {
        case .preference: "偏好"
        case .goal: "目标"
        case .constraint: "约束"
        case .habit: "习惯"
        case .workflowLesson: "工作方式"
        }
    }
}

public enum MemoryReviewStatus: String, Codable, Sendable {
    case proposed
    case confirmed
    case rejected
    case conflicted
}

public struct UserMemory: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var key: String
    public var kind: UserMemoryKind
    public var content: String
    public var confidence: Double
    public var status: MemoryReviewStatus
    public var evidenceIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        key: String,
        kind: UserMemoryKind,
        content: String,
        confidence: Double,
        status: MemoryReviewStatus = .proposed,
        evidenceIDs: [UUID],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.content = content
        self.confidence = min(max(confidence, 0), 1)
        self.status = status
        self.evidenceIDs = evidenceIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PersonalInsightKind: String, Codable, CaseIterable, Sendable {
    case focus
    case contextSwitching
    case completion
    case stalledWork
    case repeatedPattern

    public var title: String {
        switch self {
        case .focus: "今日主线"
        case .contextSwitching: "上下文切换"
        case .completion: "完成模式"
        case .stalledWork: "停滞风险"
        case .repeatedPattern: "重复模式"
        }
    }
}

public enum InsightFeedbackRating: String, Codable, Sendable {
    case accurate
    case partiallyAccurate
    case inaccurate
    case acted
    case dismissed
}

public struct PersonalInsight: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var day: Date
    public var kind: PersonalInsightKind
    public var title: String
    public var detail: String
    public var recommendation: String?
    public var confidence: Double
    public var impact: Double
    public var novelty: Double
    public var evidenceIDs: [UUID]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        day: Date,
        kind: PersonalInsightKind,
        title: String,
        detail: String,
        recommendation: String? = nil,
        confidence: Double,
        impact: Double,
        novelty: Double,
        evidenceIDs: [UUID],
        createdAt: Date = .now
    ) {
        self.id = id
        self.day = Calendar.current.startOfDay(for: day)
        self.kind = kind
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
        self.confidence = min(max(confidence, 0), 1)
        self.impact = min(max(impact, 0), 1)
        self.novelty = min(max(novelty, 0), 1)
        self.evidenceIDs = evidenceIDs
        self.createdAt = createdAt
    }

    public var interventionScore: Double {
        confidence * impact * novelty
    }
}

public struct InsightFeedback: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var insightID: UUID
    public var insightKind: PersonalInsightKind
    public var rating: InsightFeedbackRating
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        insightID: UUID,
        insightKind: PersonalInsightKind,
        rating: InsightFeedbackRating,
        createdAt: Date = .now
    ) {
        self.id = id
        self.insightID = insightID
        self.insightKind = insightKind
        self.rating = rating
        self.createdAt = createdAt
    }
}

public enum LearnedRoutineStatus: String, Codable, Sendable {
    case proposed
    case enabled
    case dismissed
}

public struct LearnedRoutine: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var key: String
    public var title: String
    public var trigger: String
    public var suggestedAction: String
    public var confidence: Double
    public var evidenceCount: Int
    public var status: LearnedRoutineStatus
    public var evidenceIDs: [UUID]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        key: String,
        title: String,
        trigger: String,
        suggestedAction: String,
        confidence: Double,
        evidenceCount: Int,
        status: LearnedRoutineStatus = .proposed,
        evidenceIDs: [UUID],
        updatedAt: Date = .now
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.trigger = trigger
        self.suggestedAction = suggestedAction
        self.confidence = min(max(confidence, 0), 1)
        self.evidenceCount = evidenceCount
        self.status = status
        self.evidenceIDs = evidenceIDs
        self.updatedAt = updatedAt
    }
}

public struct BriefingItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var confidence: Double
    public var evidenceIDs: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        confidence: Double,
        evidenceIDs: [UUID]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.confidence = min(max(confidence, 0), 1)
        self.evidenceIDs = evidenceIDs
    }
}

public struct DailyBriefing: Codable, Hashable, Sendable {
    public var headline: String
    public var progress: [BriefingItem]
    public var openLoops: [BriefingItem]
    public var insights: [PersonalInsight]
    public var nextActions: [BriefingItem]
    public var memoryCandidates: [UserMemory]
    public var routineCandidates: [LearnedRoutine]
    public var episodeIDs: [UUID]

    public init(
        headline: String,
        progress: [BriefingItem],
        openLoops: [BriefingItem],
        insights: [PersonalInsight],
        nextActions: [BriefingItem],
        memoryCandidates: [UserMemory],
        routineCandidates: [LearnedRoutine],
        episodeIDs: [UUID]
    ) {
        self.headline = headline
        self.progress = progress
        self.openLoops = openLoops
        self.insights = insights
        self.nextActions = nextActions
        self.memoryCandidates = memoryCandidates
        self.routineCandidates = routineCandidates
        self.episodeIDs = episodeIDs
    }
}

public struct IntelligenceConsolidation: Sendable {
    public var episodes: [WorkEpisode]
    public var projectStates: [ProjectState]
    public var memories: [UserMemory]
    public var insights: [PersonalInsight]
    public var routines: [LearnedRoutine]
    public var briefing: DailyBriefing

    public init(
        episodes: [WorkEpisode],
        projectStates: [ProjectState],
        memories: [UserMemory],
        insights: [PersonalInsight],
        routines: [LearnedRoutine],
        briefing: DailyBriefing
    ) {
        self.episodes = episodes
        self.projectStates = projectStates
        self.memories = memories
        self.insights = insights
        self.routines = routines
        self.briefing = briefing
    }
}
