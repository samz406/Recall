import Foundation

/// Behavioral dimensions inferred only from a day's already-generated, already-sanitized daily
/// review text — never from raw captures. Values describe observed tendencies, not clinical or
/// diagnostic traits; the taxonomy deliberately avoids disorder/illness framing.
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
        }
    }

    /// The only values the model may choose for this dimension. Anything else is discarded locally.
    public var allowedValues: [String] {
        switch self {
        case .communicationStyle: ["direct_concise", "gentle_detailed", "formal", "casual"]
        case .decisionStyle: ["cautious_verifying", "decisive_fast", "data_driven", "intuition_driven"]
        case .workPace: ["deep_focus", "multitask_switching", "sprint_to_deadline", "steady_pace"]
        case .emotionalTone: ["upbeat_positive", "calm_pragmatic", "reflective_cautious"]
        case .socialMode: ["independent", "collaborative", "influencing_others", "supportive_listener"]
        case .motivation: ["achievement", "curiosity_exploration", "relationship_meaning", "stability_security"]
        case .learningStyle: ["trial_and_error", "systematic_research", "imitation_reference"]
        case .stressResponse: ["breakdown_planning", "seek_help", "face_head_on", "temporary_avoidance"]
        case .valueFocus: ["efficiency", "quality", "innovation", "harmony", "autonomy"]
        }
    }

    /// A short, non-clinical Chinese description of one value, for display next to its evidence.
    public func valueTitle(_ value: String) -> String {
        switch (self, value) {
        case (.communicationStyle, "direct_concise"): "表达直接、偏简洁"
        case (.communicationStyle, "gentle_detailed"): "表达委婉、愿意展开细节"
        case (.communicationStyle, "formal"): "措辞偏正式"
        case (.communicationStyle, "casual"): "语气随性自然"
        case (.decisionStyle, "cautious_verifying"): "做决定前习惯反复求证"
        case (.decisionStyle, "decisive_fast"): "决策果断、行动快"
        case (.decisionStyle, "data_driven"): "依赖数据和事实做判断"
        case (.decisionStyle, "intuition_driven"): "更依赖直觉和经验做判断"
        case (.workPace, "deep_focus"): "习惯长时间专注单个任务"
        case (.workPace, "multitask_switching"): "习惯在多个任务间切换"
        case (.workPace, "sprint_to_deadline"): "临近截止时冲刺收尾"
        case (.workPace, "steady_pace"): "保持稳定匀速的节奏"
        case (.emotionalTone, "upbeat_positive"): "整体基调积极乐观"
        case (.emotionalTone, "calm_pragmatic"): "整体基调务实冷静"
        case (.emotionalTone, "reflective_cautious"): "遇事偏谨慎、爱反思"
        case (.socialMode, "independent"): "更习惯独立完成事情"
        case (.socialMode, "collaborative"): "更习惯协作完成事情"
        case (.socialMode, "influencing_others"): "倾向主动影响或推动他人"
        case (.socialMode, "supportive_listener"): "倾向倾听和支持他人"
        case (.motivation, "achievement"): "由成就和结果驱动"
        case (.motivation, "curiosity_exploration"): "由好奇和探索驱动"
        case (.motivation, "relationship_meaning"): "由关系和意义驱动"
        case (.motivation, "stability_security"): "由稳定和安全感驱动"
        case (.learningStyle, "trial_and_error"): "靠实践试错来学习"
        case (.learningStyle, "systematic_research"): "靠系统研究来学习"
        case (.learningStyle, "imitation_reference"): "靠模仿参考来学习"
        case (.stressResponse, "breakdown_planning"): "压力下会拆解制定计划"
        case (.stressResponse, "seek_help"): "压力下会主动寻求帮助"
        case (.stressResponse, "face_head_on"): "压力下会正面迎击"
        case (.stressResponse, "temporary_avoidance"): "压力下会先暂时回避"
        case (.valueFocus, "efficiency"): "更看重效率"
        case (.valueFocus, "quality"): "更看重质量"
        case (.valueFocus, "innovation"): "更看重创新"
        case (.valueFocus, "harmony"): "更看重人际和谐"
        case (.valueFocus, "autonomy"): "更看重自主权"
        default: title
        }
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
/// `observationDays` must cross a threshold before the trait is confident enough to surface.
public struct PersonaTraitState: Identifiable, Codable, Hashable, Sendable {
    public static let minimumObservationDaysToSurface = 3

    public var id: PersonaDimension { dimension }
    public var dimension: PersonaDimension
    public var value: String
    public var strength: Double
    public var observationDays: Int
    public var evidenceIDs: [UUID]
    public var updatedAt: Date

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

    public var isConfirmed: Bool { observationDays >= Self.minimumObservationDaysToSurface }
}

/// A named archetype the trait state can be matched against. Purely local, hand-authored and
/// extensible — not something the model proposes.
public struct PersonaArchetype: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tagline: String
    public var signatureDimensions: [PersonaDimension: String]

    public init(id: String, name: String, tagline: String, signatureDimensions: [PersonaDimension: String]) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.signatureDimensions = signatureDimensions
    }

    public static let catalog: [PersonaArchetype] = [
        PersonaArchetype(
            id: "meticulous-planner", name: "严谨规划师",
            tagline: "做决定前习惯把证据摆齐，按步骤稳步推进。",
            signatureDimensions: [.decisionStyle: "cautious_verifying", .learningStyle: "systematic_research", .stressResponse: "breakdown_planning", .valueFocus: "quality"]
        ),
        PersonaArchetype(
            id: "agile-explorer", name: "敏捷探索者",
            tagline: "靠直觉快速试，边做边调整方向。",
            signatureDimensions: [.decisionStyle: "intuition_driven", .workPace: "multitask_switching", .learningStyle: "trial_and_error", .valueFocus: "innovation"]
        ),
        PersonaArchetype(
            id: "deep-diver", name: "专注深潜者",
            tagline: "一旦投入就长时间沉浸在一件事里。",
            signatureDimensions: [.workPace: "deep_focus", .learningStyle: "systematic_research", .socialMode: "independent"]
        ),
        PersonaArchetype(
            id: "steady-executor", name: "稳健执行者",
            tagline: "节奏稳定、靠数据说话，不追求戏剧性的冲刺。",
            signatureDimensions: [.workPace: "steady_pace", .decisionStyle: "data_driven", .motivation: "stability_security"]
        ),
        PersonaArchetype(
            id: "warm-collaborator", name: "温暖协作者",
            tagline: "更在意和别人一起把事情做好。",
            signatureDimensions: [.socialMode: "collaborative", .emotionalTone: "upbeat_positive", .valueFocus: "harmony"]
        ),
        PersonaArchetype(
            id: "deadline-sprinter", name: "目标冲刺者",
            tagline: "越临近截止越专注，正面迎击压力。",
            signatureDimensions: [.workPace: "sprint_to_deadline", .motivation: "achievement", .stressResponse: "face_head_on"]
        ),
        PersonaArchetype(
            id: "curious-generalist", name: "好奇杂学家",
            tagline: "对新鲜事物好奇，喜欢在多个话题间切换。",
            signatureDimensions: [.motivation: "curiosity_exploration", .learningStyle: "imitation_reference", .workPace: "multitask_switching"]
        )
    ]
}

/// A computed match, recomputed locally every time the trait state changes. Never sent to a model.
public struct PersonaMatch: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var archetypeID: String
    public var name: String
    public var tagline: String
    public var score: Double
    public var supportingDimensions: [PersonaDimension]
    public var alternateArchetypeID: String?
    public var matchedAt: Date

    public init(
        id: UUID = UUID(),
        archetypeID: String,
        name: String,
        tagline: String,
        score: Double,
        supportingDimensions: [PersonaDimension],
        alternateArchetypeID: String? = nil,
        matchedAt: Date = .now
    ) {
        self.id = id
        self.archetypeID = archetypeID
        self.name = name
        self.tagline = tagline
        self.score = min(max(score, 0), 1)
        self.supportingDimensions = supportingDimensions
        self.alternateArchetypeID = alternateArchetypeID
        self.matchedAt = matchedAt
    }
}
