import Foundation

/// Behavioral dimensions inferred only from a day's already-reviewed, user-owned items — never
/// from raw captures. Values describe observed tendencies, not clinical or diagnostic traits.
/// Retired cases stay decodable so older archives load; they are never inferred or shown.
public enum PersonaDimension: String, Codable, CaseIterable, Hashable, Sendable {
    case communicationStyle
    case decisionStyle
    case workPace
    case emotionalTone
    case socialMode
    case motivation
    case learningStyle
    case stressResponse
    case valueFocus
    case planningStyle
    case priorityStyle
    case informationStyle
    case collaborationStyle
    case toolPreference

    /// Only dimensions that change how an answer is organized are inferred.
    public static let inferred: [PersonaDimension] = [.communicationStyle, .decisionStyle, .learningStyle, .stressResponse, .workPace,
                                                  .planningStyle, .priorityStyle, .informationStyle, .collaborationStyle, .toolPreference]
    public var isRetired: Bool { !Self.inferred.contains(self) }

    public var title: String {
        switch self {
        case .communicationStyle: "沟通风格"
        case .decisionStyle: "决策风格"
        case .workPace: "工作节奏"
        case .emotionalTone: "情绪基调"
        case .socialMode: "社交模式"
        case .motivation: "目标驱动力"
        case .learningStyle: "学习方式"
        case .stressResponse: "压力应对"
        case .valueFocus: "价值观关注点"
        case .planningStyle: "计划方式"
        case .priorityStyle: "优先级取舍"
        case .informationStyle: "信息处理"
        case .collaborationStyle: "协作方式"
        case .toolPreference: "工具与技术偏好"
        }
    }

    /// The only values the model may choose for this dimension. Anything else is discarded locally.
    public var allowedValues: [String] {
        switch self {
        case .communicationStyle: ["direct_concise", "gentle_detailed", "formal", "casual"]
        case .decisionStyle: ["cautious_verifying", "decisive_fast", "data_driven", "intuition_driven"]
        case .workPace: ["deep_focus", "multitask_switching", "sprint_to_deadline", "steady_pace"]
        // Free-form only: the model describes the habit, validated locally by `sanitizedLabel`.
        case .emotionalTone, .socialMode, .motivation, .valueFocus, .planningStyle, .priorityStyle, .informationStyle, .collaborationStyle, .toolPreference: []
        case .learningStyle: ["trial_and_error", "systematic_research", "imitation_reference"]
        case .stressResponse: ["breakdown_planning", "seek_help", "face_head_on", "temporary_avoidance"]
        }
    }

    /// A short, non-clinical Chinese description of one value, for display next to its evidence.
    public func valueTitle(_ value: String) -> String {
        switch (self, value) {
        case (.communicationStyle, "direct_concise"): "你表达直接、偏简洁"
        case (.communicationStyle, "gentle_detailed"): "你表达委婉、愿意展开细节"
        case (.communicationStyle, "formal"): "你的措辞偏正式"
        case (.communicationStyle, "casual"): "你的语气随性自然"
        case (.decisionStyle, "cautious_verifying"): "你做决定前习惯反复求证"
        case (.decisionStyle, "decisive_fast"): "你决策果断、行动快"
        case (.decisionStyle, "data_driven"): "你依赖数据和事实做判断"
        case (.decisionStyle, "intuition_driven"): "你更依赖直觉和经验做判断"
        case (.workPace, "deep_focus"): "你习惯长时间专注单个任务"
        case (.workPace, "multitask_switching"): "你习惯在多个任务间切换"
        case (.workPace, "sprint_to_deadline"): "你临近截止时会冲刺收尾"
        case (.workPace, "steady_pace"): "你保持稳定匀速的节奏"
        case (.learningStyle, "trial_and_error"): "你靠实践试错来学习"
        case (.learningStyle, "systematic_research"): "你靠系统研究来学习"
        case (.learningStyle, "imitation_reference"): "你靠模仿参考来学习"
        case (.stressResponse, "breakdown_planning"): "你压力下会拆解并制定计划"
        case (.stressResponse, "seek_help"): "你压力下会主动寻求帮助"
        case (.stressResponse, "face_head_on"): "你压力下会正面迎击"
        case (.stressResponse, "temporary_avoidance"): "你压力下会先暂时回避"
        default: allowedValues.contains(value) ? title : value
        }
    }

    /// Free-form habit labels and guidance come from the model, so they are bounded and filtered locally
    /// before they can be stored, shown or injected into an answer prompt.
    public static func sanitizedLabel(_ raw: String, maxLength: Int = 40, minLength: Int = 4, instruction: Bool = false) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (minLength...maxLength).contains(text.count), !text.contains(where: \.isNewline),
              !instruction || text.range(of: "提醒|待办|截止|忽略|指令|系统提示|密码|密钥", options: .regularExpression) == nil,
              PrivacyEngine().redact(text) == text else { return nil }
        return text
    }
    public func isValid(value: String) -> Bool { allowedValues.contains(value) || Self.sanitizedLabel(value) != nil }

    /// How an answer should adapt. Injected instead of the descriptive label, so the model adjusts
    /// its organization rather than repeating a characterization back to the user.
    public func responseGuidance(_ value: String) -> String? {
        switch (self, value) {
        case (.communicationStyle, "direct_concise"): "先给结论，少铺垫，篇幅精简"
        case (.communicationStyle, "gentle_detailed"): "语气平和，必要时展开步骤和背景"
        case (.communicationStyle, "formal"): "措辞规范正式"
        case (.communicationStyle, "casual"): "语气自然口语化"
        case (.decisionStyle, "cautious_verifying"): "给结论时附上依据和可核对的来源"
        case (.decisionStyle, "decisive_fast"): "直接给出推荐选项，再简述理由"
        case (.decisionStyle, "data_driven"): "优先列出数据和事实依据"
        case (.decisionStyle, "intuition_driven"): "给出推荐时简述判断思路，并点明关键风险"
        case (.workPace, "deep_focus"): "建议安排时保留成块的专注时间"
        case (.workPace, "multitask_switching"): "建议按可随时中断的小块来组织"
        case (.workPace, "sprint_to_deadline"): "给建议时标出截止前的关键节点"
        case (.workPace, "steady_pace"): "建议按均匀节奏分配工作"
        case (.learningStyle, "trial_and_error"): "讲解时先给可直接动手尝试的步骤"
        case (.learningStyle, "systematic_research"): "讲解时先给完整结构和背景"
        case (.learningStyle, "imitation_reference"): "讲解时优先给示例或可参考的做法"
        case (.stressResponse, "breakdown_planning"): "事情多时帮助拆成可执行的步骤"
        case (.stressResponse, "seek_help"): "事情多时指出可以求助或协作的对象"
        case (.stressResponse, "face_head_on"): "事情多时直接点出最关键的一步"
        case (.stressResponse, "temporary_avoidance"): "事情多时先给一个最小的起步动作，不施压"
        default: nil
        }
    }

    /// Explicit preference slots that already decide this dimension. See `MemoryPersonalization.preferenceSlot`.
    public var preferenceSlots: Set<String> {
        self == .communicationStyle ? ["response-length", "response-tone"] : []
    }
}

/// One day's raw signal for a dimension, always grounded in a verbatim quote from that day's
/// daily review text. Kept so the UI can show "why" behind a trait and so a day can be re-checked.
public struct PersonaTraitObservation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var dimension: PersonaDimension
    public var value: String
    public var evidenceQuote: String
    public var confidence: Double
    public var day: Date
    public var sourceDailySummaryID: UUID
    public var createdAt: Date
    public var sourceVersion: String? = nil
    public var evidenceID: String? = nil
    /// Local only. Lets a repeated source count as one independent day.
    public var sourceIDs: [UUID]? = nil
    /// How answers should adapt for a free-form habit. Preset values use `responseGuidance` instead.
    public var guidance: String? = nil

    public init(
        id: UUID = UUID(),
        dimension: PersonaDimension,
        value: String,
        evidenceQuote: String,
        confidence: Double,
        day: Date,
        sourceDailySummaryID: UUID,
        createdAt: Date = .now
    ) {
        self.id = id
        self.dimension = dimension
        self.value = value
        self.evidenceQuote = evidenceQuote
        self.confidence = min(max(confidence, 0), 1)
        self.day = Calendar.current.startOfDay(for: day)
        self.sourceDailySummaryID = sourceDailySummaryID
        self.createdAt = createdAt
    }
}

/// The rolling, decayed belief about one dimension. A single day never flips this on its own;
/// `observationDays` must cross a threshold, and the value must clearly dominate competing values.
public struct PersonaTraitState: Identifiable, Codable, Hashable, Sendable {
    public static let minimumObservationDaysToSurface = 3

    public var id: PersonaDimension { dimension }
    public var dimension: PersonaDimension
    public var value: String
    public var strength: Double
    public var observationDays: Int
    public var evidenceIDs: [UUID]
    public var updatedAt: Date
    /// Share of the dimension's decayed weight held by `value`. Nil in older archives.
    public var dominance: Double? = nil
    /// Independent days observed for this dimension across all values.
    public var dimensionDays: Int? = nil
    /// Answer guidance of the newest supporting observation, for habits outside the preset list.
    public var guidance: String? = nil
    public var responseGuidance: String? { dimension.responseGuidance(value) ?? guidance }

    public init(
        dimension: PersonaDimension,
        value: String,
        strength: Double,
        observationDays: Int,
        evidenceIDs: [UUID],
        updatedAt: Date = .now
    ) {
        self.dimension = dimension
        self.value = value
        self.strength = min(max(strength, 0), 1)
        self.observationDays = max(observationDays, 0)
        self.evidenceIDs = evidenceIDs
        self.updatedAt = updatedAt
    }

    public static let minimumDominance = 0.7
    public var isConfirmed: Bool {
        observationDays >= Self.minimumObservationDaysToSurface && strength >= 0.7 && (dominance ?? 1) >= Self.minimumDominance
    }
    /// Enough independent days, but they point in different directions.
    public var isMixed: Bool {
        (dimensionDays ?? 0) >= Self.minimumObservationDaysToSurface && (dominance ?? 1) < Self.minimumDominance
    }
}

public struct PersonaProfileSettings: Codable, Hashable, Sendable {
    /// Off for new installs: being described by a model is opt-in. Recall asks once after the first
    /// saved review. Archives that already stored a value keep it. Still requires cloud permission and a model.
    public var enabled = false
    public var personalizesResponses = true
    /// Set once the one-time question was answered or dismissed, so it is never repeated.
    public var askedAt: Date? = nil
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled, personalizesResponses, askedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Archives written before the default changed stored `enabled` explicitly; keep the user's value.
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        personalizesResponses = try c.decodeIfPresent(Bool.self, forKey: .personalizesResponses) ?? true
        askedAt = try c.decodeIfPresent(Date.self, forKey: .askedAt)
    }
}

public enum PersonaRefreshStatus: String, Codable, Sendable {
    case queued, running, completed, insufficientEvidence, failed
}

/// One checkpoint per current review revision. Failures contain only a safe category, never model text.
public struct PersonaRefreshJob: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { summaryID }
    public var summaryID: UUID
    public var sourceVersion: String
    public var status: PersonaRefreshStatus = .queued
    public var attempts = 0
    public var retryAt: Date? = nil
    public var failure: String? = nil
    public init(summaryID: UUID, sourceVersion: String) {
        self.summaryID = summaryID; self.sourceVersion = sourceVersion
    }
}
