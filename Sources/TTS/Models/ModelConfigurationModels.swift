import Foundation

enum ModelPurpose: String, Codable, CaseIterable, Identifiable, Equatable {
    case fast
    case quality
    case academic
    case technical
    case ocrCleanup
    case fallback

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast:
            "快速"
        case .quality:
            "高质量"
        case .academic:
            "学术"
        case .technical:
            "技术"
        case .ocrCleanup:
            "OCR 修复"
        case .fallback:
            "备用"
        }
    }

    var description: String {
        switch self {
        case .fast:
            "优先响应速度，适合快速理解屏幕内容。"
        case .quality:
            "优先整体翻译质量，适合作为默认高质量模型。"
        case .academic:
            "优先正式、严谨、术语一致的学术表达。"
        case .technical:
            "优先代码、Markdown、API 名称和技术格式保留。"
        case .ocrCleanup:
            "优先修复 OCR 噪声、恢复段落和保持原意。"
        case .fallback:
            "主模型失败时的备用模型。"
        }
    }
}

struct ModelCapabilityScore: Codable, Equatable {
    var speed: Int
    var quality: Int
    var academic: Int
    var technical: Int
    var ocrCleanup: Int
    var formatFollowing: Int
    var costEfficiency: Int

    init(
        speed: Int,
        quality: Int,
        academic: Int,
        technical: Int,
        ocrCleanup: Int,
        formatFollowing: Int,
        costEfficiency: Int
    ) {
        self.speed = Self.clamped(speed)
        self.quality = Self.clamped(quality)
        self.academic = Self.clamped(academic)
        self.technical = Self.clamped(technical)
        self.ocrCleanup = Self.clamped(ocrCleanup)
        self.formatFollowing = Self.clamped(formatFollowing)
        self.costEfficiency = Self.clamped(costEfficiency)
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, 1), 5)
    }
}

struct ModelProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var providerID: TranslationProviderID
    var modelName: String
    var purpose: ModelPurpose
    var priority: Int
    var isEnabled: Bool
    var capabilityScore: ModelCapabilityScore

    init(
        id: UUID = UUID(),
        name: String,
        providerID: TranslationProviderID,
        modelName: String,
        purpose: ModelPurpose,
        priority: Int,
        isEnabled: Bool,
        capabilityScore: ModelCapabilityScore
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.modelName = modelName
        self.purpose = purpose
        self.priority = priority
        self.isEnabled = isEnabled
        self.capabilityScore = capabilityScore
    }

    static var defaultProfiles: [ModelProfile] {
        [
            ModelProfile(
                name: "Fast Model",
                providerID: .glm4Flash,
                modelName: "glm-4-flash-250414",
                purpose: .fast,
                priority: 10,
                isEnabled: true,
                capabilityScore: ModelCapabilityScore(
                    speed: 5,
                    quality: 3,
                    academic: 3,
                    technical: 3,
                    ocrCleanup: 3,
                    formatFollowing: 3,
                    costEfficiency: 5
                )
            ),
            ModelProfile(
                name: "Quality Model",
                providerID: .openAICompatible,
                modelName: "gpt-4o-mini",
                purpose: .quality,
                priority: 20,
                isEnabled: true,
                capabilityScore: ModelCapabilityScore(
                    speed: 4,
                    quality: 4,
                    academic: 4,
                    technical: 4,
                    ocrCleanup: 4,
                    formatFollowing: 4,
                    costEfficiency: 4
                )
            ),
            ModelProfile(
                name: "Academic Model",
                providerID: .openAICompatible,
                modelName: "gpt-4o",
                purpose: .academic,
                priority: 30,
                isEnabled: true,
                capabilityScore: ModelCapabilityScore(
                    speed: 3,
                    quality: 5,
                    academic: 5,
                    technical: 4,
                    ocrCleanup: 4,
                    formatFollowing: 5,
                    costEfficiency: 3
                )
            ),
            ModelProfile(
                name: "Technical Model",
                providerID: .siliconFlow,
                modelName: "Qwen/Qwen2.5-7B-Instruct",
                purpose: .technical,
                priority: 40,
                isEnabled: true,
                capabilityScore: ModelCapabilityScore(
                    speed: 4,
                    quality: 4,
                    academic: 3,
                    technical: 5,
                    ocrCleanup: 4,
                    formatFollowing: 5,
                    costEfficiency: 4
                )
            ),
            ModelProfile(
                name: "OCR Cleanup Model",
                providerID: .glm4Flash,
                modelName: "glm-4-flash-250414",
                purpose: .ocrCleanup,
                priority: 50,
                isEnabled: true,
                capabilityScore: ModelCapabilityScore(
                    speed: 4,
                    quality: 4,
                    academic: 3,
                    technical: 4,
                    ocrCleanup: 5,
                    formatFollowing: 4,
                    costEfficiency: 5
                )
            ),
            ModelProfile(
                name: "Fallback Model",
                providerID: .myMemory,
                modelName: "",
                purpose: .fallback,
                priority: 999,
                isEnabled: true,
                capabilityScore: ModelCapabilityScore(
                    speed: 4,
                    quality: 2,
                    academic: 1,
                    technical: 1,
                    ocrCleanup: 1,
                    formatFollowing: 2,
                    costEfficiency: 5
                )
            )
        ]
    }
}
