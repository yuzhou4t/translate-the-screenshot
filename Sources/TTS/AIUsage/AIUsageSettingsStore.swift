import Foundation

struct AIUsageSettings: Codable, Equatable, Sendable {
    var providerOrder: [AIUsageProviderID]
    var visibleProviderIDs: Set<AIUsageProviderID>
    var quickActionOrder: [MenuQuickActionID]
    var visibleQuickActionIDs: Set<MenuQuickActionID>
    var miniMaxRegion: MiniMaxUsageRegion
    var deepSeekUsesTranslationKey: Bool
    var didSeedProviderVisibility: Bool

    static let `default` = AIUsageSettings(
        providerOrder: AIUsageProviderID.allCases,
        visibleProviderIDs: [],
        quickActionOrder: MenuQuickActionID.allCases,
        visibleQuickActionIDs: Set(MenuQuickActionID.allCases),
        miniMaxRegion: .chinaMainland,
        deepSeekUsesTranslationKey: true,
        didSeedProviderVisibility: false
    )

    func normalized() -> AIUsageSettings {
        var next = self
        next.providerOrder = Self.normalizedOrder(providerOrder, allCases: AIUsageProviderID.allCases)
        next.visibleProviderIDs.formIntersection(Set(AIUsageProviderID.allCases))
        next.quickActionOrder = Self.normalizedOrder(quickActionOrder, allCases: MenuQuickActionID.allCases)
        next.visibleQuickActionIDs.formIntersection(Set(MenuQuickActionID.allCases))
        return next
    }

    private static func normalizedOrder<Value: Hashable>(
        _ order: [Value],
        allCases: [Value]
    ) -> [Value] {
        var seen = Set<Value>()
        var normalized = order.filter { seen.insert($0).inserted && allCases.contains($0) }
        normalized.append(contentsOf: allCases.filter { seen.insert($0).inserted })
        return normalized
    }
}

struct AIUsageProviderPreference: Identifiable, Equatable, Sendable {
    var id: AIUsageProviderID
    var isVisible: Bool
}

struct MenuQuickActionPreference: Identifiable, Equatable, Sendable {
    var id: MenuQuickActionID
    var isVisible: Bool
}

@MainActor
final class AIUsageSettingsStore: ObservableObject {
    @Published private(set) var settings: AIUsageSettings

    private let userDefaults: UserDefaults
    private let key = "tts.aiUsage.settings.v1"
    private let antiGravityMigrationKey = "tts.aiUsage.didEnableAntiGravityReplacement.v1"
    private let screenRecordingActionMigrationKey = "tts.aiUsage.didEnableScreenRecordingAction.v1"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AIUsageSettings.self, from: data) {
            settings = decoded.normalized()
        } else {
            settings = .default
        }
        if !userDefaults.bool(forKey: screenRecordingActionMigrationKey) {
            settings.quickActionOrder.removeAll { $0 == .screenRecording }
            settings.quickActionOrder.insert(.screenRecording, at: 0)
            settings.visibleQuickActionIDs.insert(.screenRecording)
            userDefaults.set(true, forKey: screenRecordingActionMigrationKey)
        }
        persist()
    }

    var providerPreferences: [AIUsageProviderPreference] {
        settings.providerOrder.map {
            AIUsageProviderPreference(id: $0, isVisible: settings.visibleProviderIDs.contains($0))
        }
    }

    var quickActionPreferences: [MenuQuickActionPreference] {
        settings.quickActionOrder.map {
            MenuQuickActionPreference(id: $0, isVisible: settings.visibleQuickActionIDs.contains($0))
        }
    }

    var visibleProviderIDs: [AIUsageProviderID] {
        settings.providerOrder.filter(settings.visibleProviderIDs.contains)
    }

    var visibleQuickActionIDs: [MenuQuickActionID] {
        settings.quickActionOrder.filter(settings.visibleQuickActionIDs.contains)
    }

    func seedInitialProviderVisibility(_ ids: Set<AIUsageProviderID>) {
        guard !settings.didSeedProviderVisibility else { return }
        update { settings in
            settings.visibleProviderIDs = ids
            settings.didSeedProviderVisibility = true
        }
    }

    func enableAntiGravityReplacementIfNeeded(isInstalled: Bool) {
        guard isInstalled,
              !userDefaults.bool(forKey: antiGravityMigrationKey) else { return }
        userDefaults.set(true, forKey: antiGravityMigrationKey)
        update { $0.visibleProviderIDs.insert(.gemini) }
    }

    func setProviderVisible(_ isVisible: Bool, id: AIUsageProviderID) {
        update { settings in
            if isVisible {
                settings.visibleProviderIDs.insert(id)
            } else {
                settings.visibleProviderIDs.remove(id)
            }
        }
    }

    func moveProviders(fromOffsets: IndexSet, toOffset: Int) {
        update { settings in
            settings.providerOrder = Self.moving(
                settings.providerOrder,
                fromOffsets: fromOffsets,
                toOffset: toOffset
            )
        }
    }

    func setQuickActionVisible(_ isVisible: Bool, id: MenuQuickActionID) {
        update { settings in
            if isVisible {
                settings.visibleQuickActionIDs.insert(id)
            } else {
                settings.visibleQuickActionIDs.remove(id)
            }
        }
    }

    func moveQuickActions(fromOffsets: IndexSet, toOffset: Int) {
        update { settings in
            settings.quickActionOrder = Self.moving(
                settings.quickActionOrder,
                fromOffsets: fromOffsets,
                toOffset: toOffset
            )
        }
    }

    func setMiniMaxRegion(_ region: MiniMaxUsageRegion) {
        update { $0.miniMaxRegion = region }
    }

    func setDeepSeekUsesTranslationKey(_ enabled: Bool) {
        update { $0.deepSeekUsesTranslationKey = enabled }
    }

    private func update(_ mutate: (inout AIUsageSettings) -> Void) {
        var next = settings
        mutate(&next)
        settings = next.normalized()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: key)
        }
    }

    private static func moving<Value>(
        _ values: [Value],
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> [Value] {
        guard !fromOffsets.isEmpty else { return values }
        let movingValues = fromOffsets.sorted().map { values[$0] }
        var remaining = values
        for index in fromOffsets.sorted(by: >) {
            remaining.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let destination = min(max(toOffset - removedBeforeDestination, 0), remaining.count)
        remaining.insert(contentsOf: movingValues, at: destination)
        return remaining
    }
}
