import Foundation

enum TranslationScenario: String, Codable, CaseIterable, Identifiable, Equatable {
    case selection
    case input
    case screenshot
    case ocrCleanup
    case technical
    case academic

    var id: String { rawValue }
}

struct TranslationRouter {
    func recommendedProfile(
        for scenario: TranslationScenario,
        modelProfiles: [ModelProfile],
        translationMode: TranslationMode? = nil
    ) -> ModelProfile? {
        let enabledProfiles = modelProfiles.filter(\.isEnabled)
        guard !enabledProfiles.isEmpty else {
            return nil
        }

        for purpose in purposeOrder(for: scenario, translationMode: translationMode) {
            if let profile = bestProfile(for: purpose, in: enabledProfiles) {
                return profile
            }
        }

        return nil
    }

    private func purposeOrder(
        for scenario: TranslationScenario,
        translationMode: TranslationMode?
    ) -> [ModelPurpose] {
        var purposes: [ModelPurpose]

        switch scenario {
        case .selection:
            purposes = [.fast]
        case .input:
            purposes = [.quality]
        case .screenshot:
            purposes = [.ocrCleanup, .quality]
        case .ocrCleanup:
            purposes = [.ocrCleanup]
        case .technical:
            purposes = [.technical, .quality]
        case .academic:
            purposes = [.academic, .quality]
        }

        if let modePurpose = purpose(for: translationMode), !purposes.contains(modePurpose) {
            purposes.append(modePurpose)
        }

        if !purposes.contains(.fallback) {
            purposes.append(.fallback)
        }

        return purposes
    }

    private func purpose(for translationMode: TranslationMode?) -> ModelPurpose? {
        switch translationMode {
        case .fast:
            .fast
        case .accurate, .natural, .bilingual, .polished:
            .quality
        case .academic:
            .academic
        case .technical:
            .technical
        case .ocrCleanup:
            .ocrCleanup
        case nil:
            nil
        }
    }

    private func bestProfile(for purpose: ModelPurpose, in profiles: [ModelProfile]) -> ModelProfile? {
        profiles
            .filter { $0.purpose == purpose }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }

                let lhsScore = capabilityScore(for: purpose, profile: lhs)
                let rhsScore = capabilityScore(for: purpose, profile: rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .first
    }

    private func capabilityScore(for purpose: ModelPurpose, profile: ModelProfile) -> Int {
        switch purpose {
        case .fast:
            profile.capabilityScore.speed
        case .quality:
            profile.capabilityScore.quality
        case .academic:
            profile.capabilityScore.academic
        case .technical:
            profile.capabilityScore.technical
        case .ocrCleanup:
            profile.capabilityScore.ocrCleanup
        case .fallback:
            profile.capabilityScore.costEfficiency
        }
    }
}

enum TranslationRouterRuleChecks {
    static func runBasicRoutingChecks() -> Bool {
        let router = TranslationRouter()

        let selection = router.recommendedProfile(
            for: .selection,
            modelProfiles: [
                profile(name: "Quality", purpose: .quality, priority: 10),
                profile(name: "Fast", purpose: .fast, priority: 20),
                profile(name: "Fallback", purpose: .fallback, priority: 999)
            ]
        )

        let academicFallback = router.recommendedProfile(
            for: .academic,
            modelProfiles: [
                profile(name: "Quality", purpose: .quality, priority: 10),
                profile(name: "Fallback", purpose: .fallback, priority: 999)
            ]
        )

        let disabledSkipped = router.recommendedProfile(
            for: .academic,
            modelProfiles: [
                profile(name: "Disabled Academic", purpose: .academic, priority: 1, isEnabled: false),
                profile(name: "Quality", purpose: .quality, priority: 10)
            ]
        )

        let priorityWinner = router.recommendedProfile(
            for: .technical,
            modelProfiles: [
                profile(name: "Technical B", purpose: .technical, priority: 20),
                profile(name: "Technical A", purpose: .technical, priority: 5)
            ]
        )

        return selection?.purpose == .fast &&
            selection?.name == "Fast" &&
            academicFallback?.purpose == .quality &&
            academicFallback?.name == "Quality" &&
            disabledSkipped?.purpose == .quality &&
            disabledSkipped?.name == "Quality" &&
            priorityWinner?.name == "Technical A"
    }

    private static func profile(
        name: String,
        purpose: ModelPurpose,
        priority: Int,
        isEnabled: Bool = true,
        score: Int = 3
    ) -> ModelProfile {
        ModelProfile(
            name: name,
            providerID: .openAICompatible,
            modelName: name.lowercased().replacingOccurrences(of: " ", with: "-"),
            purpose: purpose,
            priority: priority,
            isEnabled: isEnabled,
            capabilityScore: ModelCapabilityScore(
                speed: score,
                quality: score,
                academic: score,
                technical: score,
                ocrCleanup: score,
                formatFollowing: score,
                costEfficiency: score
            )
        )
    }
}
