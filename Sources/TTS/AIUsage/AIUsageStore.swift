import Foundation

@MainActor
final class AIUsageStore: ObservableObject {
    @Published private(set) var states: [AIUsageProviderID: AIUsageProviderViewState]
    @Published private(set) var isRefreshing = false

    private let settingsStore: AIUsageSettingsStore
    private let providerRegistry: any AIUsageProviderResolving
    private let userDefaults: UserDefaults
    private let snapshotCacheKey = "tts.aiUsage.snapshotCache.v2"
    private var refreshLoop: Task<Void, Never>?

    init(
        settingsStore: AIUsageSettingsStore,
        providerRegistry: any AIUsageProviderResolving,
        userDefaults: UserDefaults = .standard
    ) {
        self.settingsStore = settingsStore
        self.providerRegistry = providerRegistry
        self.userDefaults = userDefaults
        var cachedStates: [AIUsageProviderID: AIUsageProviderViewState] = [:]
        if let data = userDefaults.data(forKey: snapshotCacheKey),
           let snapshots = try? JSONDecoder().decode([AIUsageSnapshot].self, from: data) {
            for snapshot in snapshots.prefix(AIUsageProviderID.allCases.count) {
                cachedStates[snapshot.providerID] = AIUsageProviderViewState(
                    snapshot: snapshot,
                    failure: nil,
                    isRefreshing: false,
                    lastAttemptAt: nil
                )
            }
        }
        states = cachedStates
    }

    deinit {
        refreshLoop?.cancel()
    }

    var visibleProviderIDs: [AIUsageProviderID] {
        settingsStore.visibleProviderIDs
    }

    var latestUpdate: Date? {
        visibleProviderIDs.compactMap { states[$0]?.snapshot?.updatedAt }.max()
    }

    var normalCount: Int {
        visibleProviderIDs.filter { id in
            guard let state = states[id], let snapshot = state.snapshot else { return false }
            return state.failure == nil && !snapshot.needsAttention
        }.count
    }

    var attentionCount: Int {
        visibleProviderIDs.filter { id in
            guard let state = states[id] else { return false }
            if let failure = state.failure {
                return failure.category != .notConfigured
            }
            return state.snapshot?.needsAttention == true
        }.count
    }

    var unconfiguredCount: Int {
        visibleProviderIDs.filter { id in
            guard let state = states[id] else { return true }
            if let failure = state.failure {
                return failure.category == .notConfigured
            }
            return state.snapshot == nil
        }.count
    }

    func start() {
        guard refreshLoop == nil else { return }
        let detectedProviderIDs = providerRegistry.detectedProviderIDs()
        settingsStore.enableAntiGravityReplacementIfNeeded(
            isInstalled: detectedProviderIDs.contains(.gemini)
        )
        settingsStore.seedInitialProviderVisibility(detectedProviderIDs)
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5 * 60))
                } catch {
                    return
                }
                await self.refreshAll()
            }
        }
    }

    func refreshIfStale() {
        let needsRefresh = visibleProviderIDs.contains { id in
            guard let snapshot = states[id]?.snapshot else { return true }
            return Date.now.timeIntervalSince(snapshot.updatedAt) > 60
        }
        guard needsRefresh else { return }
        Task { await refreshAll() }
    }

    func refreshNow() {
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        let ids = visibleProviderIDs
        guard !ids.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var providers: [(AIUsageProviderID, any AIUsageProvider)] = []
        for id in ids {
            do {
                let provider = try providerRegistry.makeProvider(for: id)
                providers.append((id, provider))
                var state = states[id] ?? .empty
                state.isRefreshing = true
                state.failure = nil
                states[id] = state
            } catch let failure as AIUsageFailure {
                applyFailure(failure, to: id)
            } catch {
                applyFailure(.unavailable("暂时无法准备该服务商。"), to: id)
            }
        }

        await withTaskGroup(of: (AIUsageProviderID, Result<AIUsageSnapshot, AIUsageFailure>).self) { group in
            for (id, provider) in providers {
                group.addTask {
                    do {
                        return (id, .success(try await provider.fetchUsage()))
                    } catch let failure as AIUsageFailure {
                        return (id, .failure(failure))
                    } catch is CancellationError {
                        return (id, .failure(.unavailable("刷新已取消。")))
                    } catch {
                        return (id, .failure(.unavailable("暂时无法读取该服务商额度。")))
                    }
                }
            }

            for await (id, result) in group {
                switch result {
                case .success(let snapshot):
                    states[id] = AIUsageProviderViewState(
                        snapshot: snapshot,
                        failure: nil,
                        isRefreshing: false,
                        lastAttemptAt: .now
                    )
                case .failure(let failure):
                    applyFailure(failure, to: id)
                }
            }
        }
        persistSnapshots()
    }

    private func applyFailure(_ failure: AIUsageFailure, to id: AIUsageProviderID) {
        var state = states[id] ?? .empty
        state.failure = failure
        state.isRefreshing = false
        state.lastAttemptAt = .now
        states[id] = state
        print("ai usage refresh: provider=\(id.rawValue), category=\(failure.category.rawValue)")
    }

    private func persistSnapshots() {
        let snapshots = AIUsageProviderID.allCases.compactMap { states[$0]?.snapshot }
        if let data = try? JSONEncoder().encode(snapshots) {
            userDefaults.set(data, forKey: snapshotCacheKey)
        }
    }
}
