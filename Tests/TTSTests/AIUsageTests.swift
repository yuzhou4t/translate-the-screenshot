#if canImport(Testing)
@testable import TTS
import AppKit
import Foundation
import SwiftUI
import Testing

@Suite("AI subscription usage")
struct AIUsageTests {
    @Test("Codex app-server starts with stable read-only arguments")
    func codexAppServerArguments() {
        #expect(CodexUsageProvider.appServerArguments == [
            "-s", "read-only",
            "-c", "features.context_management=false",
            "app-server",
        ])
    }

    @Test("RPC process teardown stays bounded when graceful termination is ignored")
    func rpcProcessStopIsBounded() throws {
        let session = try AIUsageRPCProcessSession(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; exec sleep 60"]
        )
        Thread.sleep(forTimeInterval: 0.05)

        let startedAt = Date()
        session.stop()

        #expect(Date().timeIntervalSince(startedAt) < 1.5)
    }

    @Test("Codex reauthorization forces a fresh account login")
    func codexReauthorizationRequiresLogin() throws {
        let original = try #require(URL(string:
            "https://auth.openai.com/oauth/authorize?client_id=codex&state=opaque&prompt=none"
        ))

        let result = CodexAccountIdentityReader.loginURLRequiringAccountChoice(original)
        let components = try #require(URLComponents(url: result, resolvingAgainstBaseURL: false))
        let promptItems = (components.queryItems ?? []).filter { $0.name == "prompt" }

        #expect(promptItems.map(\.value) == ["login"])
        #expect(components.queryItems?.first(where: { $0.name == "state" })?.value == "opaque")
        #expect(components.queryItems?.first(where: { $0.name == "client_id" })?.value == "codex")
    }

    @Test("Codex prefers the current bundled CLI over a stale PATH copy")
    func codexBundledBinaryPreference() {
        let binary = AIUsageBinaryLocator.codexBinary(
            environment: ["PATH": "/Users/example/.local/bin"],
            bundledCandidates: ["/bin/sh"]
        )

        #expect(binary == "/bin/sh")
    }

    @Test("Codex parses standard, Spark, and credits buckets")
    func codexParsing() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "planType": "plus",
                "primary": [
                    "usedPercent": 25,
                    "windowDurationMins": 300,
                    "resetsAt": 1_700_003_600,
                ],
                "secondary": [
                    "usedPercent": 60,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_700_604_800,
                ],
                "credits": [
                    "hasCredits": true,
                    "unlimited": false,
                    "balance": "0",
                ],
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "planType": "plus",
                    "primary": [
                        "usedPercent": 25,
                        "windowDurationMins": 300,
                        "resetsAt": 1_700_003_600,
                    ],
                    "secondary": [
                        "usedPercent": 60,
                        "windowDurationMins": 10_080,
                        "resetsAt": 1_700_604_800,
                    ],
                ],
                "codex_bengalfox": [
                    "limitId": "codex_bengalfox",
                    "limitName": "GPT-5.3-Codex-Spark",
                    "primary": [
                        "usedPercent": 10,
                        "windowDurationMins": 300,
                        "resetsAt": 1_700_003_600,
                    ],
                    "secondary": [
                        "usedPercent": 35,
                        "windowDurationMins": 10_080,
                        "resetsAt": 1_700_604_800,
                    ],
                ],
            ],
        ]

        let snapshot = try CodexUsageProvider.parse(result: result, now: now)

        #expect(snapshot.providerID == .codex)
        #expect(snapshot.planName == "plus")
        #expect(snapshot.metrics.count == 5)
        #expect(snapshot.metrics[0].remainingFraction == 0.75)
        #expect(snapshot.metrics[1].remainingFraction == 0.40)
        #expect(snapshot.metrics[2].label == "5.3 Spark · 5 小时")
        #expect(snapshot.metrics[2].remainingFraction == 0.90)
        #expect(snapshot.metrics[3].label == "5.3 Spark · 周")
        #expect(snapshot.metrics[3].remainingFraction == 0.65)
        #expect(!snapshot.needsAttention)
    }

    @Test("Grok parses billing cycle without exposing account data")
    func grokParsing() throws {
        let json = #"""
        {
          "billingCycle": {
            "billingPeriodStart": "2026-05-01T00:00:00Z",
            "billingPeriodEnd": "2026-06-01T00:00:00Z"
          },
          "monthlyLimit": { "val": 10000 },
          "usage": { "totalUsed": { "val": 2500 } }
        }
        """#

        let snapshot = try GrokUsageProvider.parse(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(snapshot.providerID == .grok)
        #expect(snapshot.metrics.count == 1)
        #expect(snapshot.metrics[0].remainingFraction == 0.75)
    }

    @Test("Grok parses unified weekly quota and product breakdown")
    func grokUnifiedWeeklyParsing() throws {
        let json = #"""
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-17T00:00:00Z",
              "end": "2026-08-24T00:00:00Z"
            },
            "creditUsagePercent": 24.5,
            "prepaidBalance": { "val": 1250 },
            "productUsage": [
              { "product": "PRODUCT_GROK_BUILD", "usagePercent": 18.5 },
              { "product": "PRODUCT_GROK_CHAT", "usagePercent": 6.0 }
            ]
          },
          "subscriptionTier": "SuperGrok Heavy"
        }
        """#

        let snapshot = try GrokUsageProvider.parse(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(snapshot.planName == "SuperGrok Heavy")
        #expect(snapshot.metrics.count == 2)
        #expect(snapshot.metrics[0].label == "共享周额度")
        #expect(snapshot.metrics[0].remainingFraction == 0.755)
        #expect(snapshot.usageBreakdown?.map(\.label) == ["Build", "Chat"])
        #expect(snapshot.usageBreakdown?[0].usedFraction == 0.185)
    }

    @Test("Grok treats an omitted proto3 zero percentage as unused unified quota")
    func grokUnifiedZeroUsageParsing() throws {
        let json = #"""
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-09-07T00:00:00Z",
              "end": "2026-09-14T00:00:00Z"
            },
            "isUnifiedBillingUser": true,
            "onDemandCap": { "val": 0 },
            "onDemandUsed": { "val": 0 },
            "prepaidBalance": { "val": 0 }
          }
        }
        """#

        let snapshot = try GrokUsageProvider.parse(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(snapshot.metrics.count == 1)
        #expect(snapshot.metrics[0].label == "共享周额度")
        #expect(snapshot.metrics[0].remainingFraction == 1)
        if case .quotaWindow(_, _, let resetsAt) = snapshot.metrics[0] {
            #expect(resetsAt == ISO8601DateFormatter().date(from: "2026-09-14T00:00:00Z"))
        } else {
            Issue.record("Expected a Grok quota window")
        }
    }

    @Test("Codex local token reader uses the final cumulative count")
    func codexLocalTokenParsing() throws {
        let jsonl = #"""
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":25,"output_tokens":10,"reasoning_output_tokens":4}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":240,"cached_input_tokens":80,"output_tokens":60,"reasoning_output_tokens":18}}}}
        """#

        let counts = try #require(AIUsageLocalTokenReader.parseCodexSessionTail(Data(jsonl.utf8)))

        #expect(counts.input == 240)
        #expect(counts.cachedInput == 80)
        #expect(counts.output == 60)
        #expect(counts.reasoning == 18)
    }

    @Test("Grok local token reader filters by period and counts cached input")
    func grokLocalTokenParsing() {
        let jsonl = #"""
        {"ts":"2026-08-18T10:00:00.000Z","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":100,"cached_prompt_tokens":40,"completion_tokens":20,"reasoning_tokens":8}}
        {"ts":"2026-08-20T10:00:00.000Z","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":300,"cached_prompt_tokens":120,"completion_tokens":50,"reasoning_tokens":15}}
        """#

        let counts = AIUsageLocalTokenReader.parseGrokUnifiedLog(
            Data(jsonl.utf8),
            since: ISO8601DateFormatter().date(from: "2026-08-20T00:00:00Z")!
        )

        #expect(counts.input == 300)
        #expect(counts.cachedInput == 120)
        #expect(counts.output == 50)
        #expect(counts.reasoning == 15)
    }

    @Test("Grok live acceptance uses the installed CLI login when explicitly enabled")
    func grokLiveAcceptance() async throws {
        guard ProcessInfo.processInfo.environment["TTS_GROK_LIVE"] == "1",
              let binary = AIUsageBinaryLocator.grokBinary() else {
            return
        }

        let snapshot = try await GrokUsageProvider(binaryPath: binary).fetchUsage()

        #expect(snapshot.providerID == .grok)
        #expect(snapshot.metrics.isEmpty == false)
        #expect(snapshot.metrics.allSatisfy { metric in
            guard let remaining = metric.remainingFraction else { return true }
            return (0...1).contains(remaining)
        })
    }

    @Test("Codex live acceptance includes the installed Spark quota when explicitly enabled")
    func codexLiveAcceptance() async throws {
        guard ProcessInfo.processInfo.environment["TTS_CODEX_LIVE"] == "1",
              let binary = AIUsageBinaryLocator.codexBinary() else {
            return
        }

        let snapshot = try await CodexUsageProvider(binaryPath: binary).fetchUsage()

        #expect(snapshot.providerID == .codex)
        #expect(snapshot.metrics.contains { $0.label.contains("Spark") })
        #expect(snapshot.metrics.allSatisfy { metric in
            guard let remaining = metric.remainingFraction else { return true }
            return (0...1).contains(remaining)
        })
    }

    @Test("Compact popover renders the complete provider overview")
    @MainActor
    func compactPopoverVisualFixture() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TTS_UI_QA_OUTPUT"] else {
            return
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        AIUsageProviderBrandAssets.overrideDirectoryURL = sourceRoot
            .appendingPathComponent("App/Resources", isDirectory: true)
        defer { AIUsageProviderBrandAssets.overrideDirectoryURL = nil }

        let suiteName = "TTSTests.AIUsageVisual.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = AIUsageSettings.default
        settings.visibleProviderIDs = Set(AIUsageProviderID.allCases)
        settings.didSeedProviderVisibility = true
        defaults.set(try JSONEncoder().encode(settings), forKey: "tts.aiUsage.settings.v1")

        let now = Date()
        let snapshots = [
            AIUsageSnapshot(
                providerID: .codex,
                metrics: [
                    .quotaWindow(label: "5 小时额度", remainingFraction: 0.96, resetsAt: now.addingTimeInterval(9_000)),
                    .quotaWindow(label: "周额度", remainingFraction: 0.78, resetsAt: now.addingTimeInterval(320_000)),
                    .quotaWindow(label: "5.3 Spark · 5 小时", remainingFraction: 1, resetsAt: now.addingTimeInterval(9_000)),
                    .quotaWindow(label: "5.3 Spark · 周", remainingFraction: 0.84, resetsAt: now.addingTimeInterval(320_000)),
                ],
                planName: "Plus",
                source: "Codex CLI",
                updatedAt: now
            ),
            AIUsageSnapshot(
                providerID: .grok,
                metrics: [.quotaWindow(label: "共享周额度", remainingFraction: 0.64, resetsAt: now.addingTimeInterval(210_000))],
                planName: "SuperGrok",
                source: "Grok CLI 登录态",
                updatedAt: now,
                usageBreakdown: [
                    .init(label: "Build", usedFraction: 0.24),
                    .init(label: "Chat", usedFraction: 0.12),
                ]
            ),
            AIUsageSnapshot(
                providerID: .deepSeek,
                metrics: [.balance(label: "API 余额", total: 12.50, currency: "USD", paid: 10, granted: 2.5)],
                planName: "API",
                source: "DeepSeek API",
                updatedAt: now
            ),
            AIUsageSnapshot(
                providerID: .miniMax,
                metrics: [
                    .quotaWindow(label: "5 小时额度", remainingFraction: 1, resetsAt: now.addingTimeInterval(12_000)),
                    .quotaWindow(label: "周额度", remainingFraction: 0.81, resetsAt: now.addingTimeInterval(260_000)),
                ],
                planName: "Coding Plan",
                source: "MiniMax API",
                updatedAt: now
            ),
            AIUsageSnapshot(
                providerID: .gemini,
                metrics: [
                    .quotaWindow(label: "Gemini · 周", remainingFraction: 0.97, resetsAt: now.addingTimeInterval(300_000)),
                    .quotaWindow(label: "Gemini · 5 小时", remainingFraction: 1, resetsAt: now.addingTimeInterval(11_000)),
                    .quotaWindow(label: "Claude / GPT · 周", remainingFraction: 0.76, resetsAt: now.addingTimeInterval(250_000)),
                    .quotaWindow(label: "Claude / GPT · 5 小时", remainingFraction: 1, resetsAt: now.addingTimeInterval(11_000)),
                ],
                planName: "Google AI Pro",
                source: "AntiGravity",
                updatedAt: now
            ),
        ]
        defaults.set(try JSONEncoder().encode(snapshots), forKey: "tts.aiUsage.snapshotCache.v2")

        let settingsStore = AIUsageSettingsStore(userDefaults: defaults)
        let usageStore = AIUsageStore(
            settingsStore: settingsStore,
            providerRegistry: FakeAIUsageProviderResolver(providers: [:]),
            userDefaults: defaults
        )
        let rootView = AIUsagePopoverView(
            usageStore: usageStore,
            tokenStore: AIUsageTokenStore(),
            settingsStore: settingsStore,
            codexAccountSwitcherStore: CodexAccountSwitcherStore(),
            screenRecordingController: ScreenRecordingController(
                permissionManager: PermissionManager(),
                toastPanel: ToastPanel()
            ),
            onQuickAction: { _ in },
            onOpenSettings: {},
            onQuit: {},
            forceReduceTransparency: nil
        )
        let representation = try renderVisualFixture(rootView, to: outputPath)

        #expect(representation.pixelsWide >= 420)
        #expect(representation.pixelsHigh >= 540)

        if let darkOutputPath = ProcessInfo.processInfo.environment["TTS_UI_QA_DARK_OUTPUT"] {
            _ = try renderVisualFixture(
                rootView,
                to: darkOutputPath,
                appearanceName: .darkAqua
            )
        }

        if let reducedTransparencyOutputPath = ProcessInfo.processInfo.environment["TTS_UI_QA_REDUCED_OUTPUT"] {
            var reducedTransparencyView = rootView
            reducedTransparencyView.forceReduceTransparency = true
            _ = try renderVisualFixture(
                reducedTransparencyView,
                to: reducedTransparencyOutputPath
            )
        }

        if let detailOutputPath = ProcessInfo.processInfo.environment["TTS_UI_QA_DETAIL_OUTPUT"],
           let grokState = usageStore.states[.grok] {
            let detailView = ZStack {
                TTSWindowBackground()
                AIUsageProviderDetailView(
                    providerID: .grok,
                    state: grokState,
                    tokenStore: AIUsageTokenStore(),
                    codexAccountSwitcherStore: CodexAccountSwitcherStore(),
                    onBack: {},
                    onRefresh: {}
                )
            }
            _ = try renderVisualFixture(detailView, to: detailOutputPath)
        }
    }

    @MainActor
    private func renderVisualFixture<Content: View>(
        _ view: Content,
        to outputPath: String,
        appearanceName: NSAppearance.Name? = nil
    ) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: view)
        if let appearanceName {
            hostingView.appearance = NSAppearance(named: appearanceName)
        }
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 540)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try #require(
            representation.representation(using: .png, properties: [:])
        )
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        return representation
    }

    @Test("DeepSeek selects USD and preserves paid versus granted balance")
    func deepSeekParsing() throws {
        let json = #"""
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "30.00",
              "granted_balance": "10.00",
              "topped_up_balance": "20.00"
            },
            {
              "currency": "USD",
              "total_balance": "12.50",
              "granted_balance": "2.50",
              "topped_up_balance": "10.00"
            }
          ]
        }
        """#

        let snapshot = try DeepSeekUsageProvider.parse(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case let .balance(_, total, currency, paid, granted) = snapshot.metrics[0] else {
            Issue.record("Expected a balance metric")
            return
        }
        #expect(total == 12.5)
        #expect(currency == "USD")
        #expect(paid == 10)
        #expect(granted == 2.5)
    }

    @Test("MiniMax parses nested current token-plan response")
    func miniMaxParsing() throws {
        let json = #"""
        {
          "base_resp": { "status_code": "0" },
          "data": {
            "current_subscribe_title": "Token Plan Plus",
            "model_remains": [
              {
                "model_name": "general",
                "current_interval_status": 1,
                "current_interval_remaining_percent": "96",
                "end_time": 1780297200000,
                "current_weekly_status": 1,
                "current_weekly_remaining_percent": "70",
                "weekly_end_time": 1780848000000
              }
            ]
          }
        }
        """#

        let snapshot = try MiniMaxUsageProvider.parse(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_780_282_340)
        )

        #expect(snapshot.planName == "Token Plan Plus")
        #expect(snapshot.metrics.count == 2)
        #expect(snapshot.metrics[0].remainingFraction == 0.96)
        #expect(snapshot.metrics[1].remainingFraction == 0.70)
    }

    @Test("AntiGravity parses all five-hour and weekly quota buckets")
    func antiGravityParsing() throws {
        let json = #"""
        {
          "code": 0,
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  { "bucketId": "gemini-session", "displayName": "Five-hour limit", "remainingFraction": 0.64, "resetTime": "2026-09-01T00:00:00Z" },
                  { "bucketId": "gemini-week", "displayName": "Weekly limit", "remaining": { "case": "remainingFraction", "value": 0.42 }, "resetTime": "2026-09-07T00:00:00Z" }
                ]
              },
              {
                "displayName": "Claude and GPT models",
                "buckets": [
                  { "bucketId": "other-session", "displayName": "Five-hour limit", "remainingFraction": 0.81 },
                  { "bucketId": "other-week", "displayName": "Weekly limit", "remainingFraction": 0.73 }
                ]
              }
            ]
          }
        }
        """#

        let snapshot = try AntiGravityUsageProvider.parseQuotaSummary(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(snapshot.providerID == .gemini)
        #expect(snapshot.source == "AntiGravity 本地服务")
        #expect(snapshot.metrics.count == 4)
        #expect(snapshot.metrics[0].remainingFraction == 0.64)
        #expect(snapshot.metrics[1].remainingFraction == 0.42)
        #expect(snapshot.metrics[2].remainingFraction == 0.81)
        #expect(snapshot.metrics[3].remainingFraction == 0.73)
    }

    @Test("AntiGravity process parser keeps tokens in memory without logging them")
    func antiGravityProcessParsing() {
        let output = """
        321 /Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos --csrf_token secret-value --extension_server_port 4567 --extension_server_csrf_token extension-secret
        654 /usr/bin/unrelated --csrf_token ignore-me
        """

        let processes = AntiGravityUsageProvider.processes(from: output)

        #expect(processes.count == 1)
        #expect(processes[0].pid == 321)
        #expect(processes[0].extensionPort == 4567)
    }

    @Test("AntiGravity live acceptance uses the running local service when explicitly enabled")
    func antiGravityLiveAcceptance() async throws {
        guard ProcessInfo.processInfo.environment["TTS_ANTIGRAVITY_LIVE"] == "1" else {
            return
        }

        let snapshot = try await AntiGravityUsageProvider().fetchUsage()

        #expect(snapshot.providerID == .gemini)
        #expect(snapshot.metrics.isEmpty == false)
        #expect(snapshot.metrics.allSatisfy { metric in
            guard let remaining = metric.remainingFraction else { return true }
            return (0...1).contains(remaining)
        })
    }

    @Test("Settings preserve order and keep newly registered providers hidden")
    @MainActor
    func settingsOrdering() {
        let suiteName = "TTSTests.AIUsageSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIUsageSettingsStore(userDefaults: defaults)

        store.seedInitialProviderVisibility([.codex, .grok])
        store.moveProviders(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        store.setProviderVisible(false, id: .grok)

        #expect(store.settings.providerOrder.prefix(3) == [.grok, .deepSeek, .codex])
        #expect(store.visibleProviderIDs == [.codex])
        #expect(!store.settings.visibleProviderIDs.contains(.gemini))
    }

    @Test("AntiGravity replacement is enabled once without changing later user choice")
    @MainActor
    func antiGravityReplacementMigration() {
        let suiteName = "TTSTests.AIUsageAntiGravityMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIUsageSettingsStore(userDefaults: defaults)

        store.enableAntiGravityReplacementIfNeeded(isInstalled: true)
        #expect(store.settings.visibleProviderIDs.contains(.gemini))

        store.setProviderVisible(false, id: .gemini)
        store.enableAntiGravityReplacementIfNeeded(isInstalled: true)
        #expect(!store.settings.visibleProviderIDs.contains(.gemini))
    }

    @Test("DeepSeek monitor key overrides translation key")
    @MainActor
    func deepSeekCredentialPrecedence() throws {
        let suiteName = "TTSTests.AIUsageCredentials.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AIUsageSettingsStore(userDefaults: defaults)
        let configurationStore = AppConfigurationStore(userDefaults: defaults)
        let secrets = FakeAIUsageSecretReader(values: [
            AIUsageProviderRegistry.deepSeekUsageKeyAccount: "monitor-key",
            TranslationProviderID.deepSeek.rawValue: "translation-key",
        ])
        let registry = AIUsageProviderRegistry(
            settingsStore: settingsStore,
            keychainService: secrets,
            configurationStore: configurationStore
        )

        #expect(registry.configurationStatus(for: .deepSeek) == "已保存监控专用 Key")
        #expect(secrets.loadCount == 0)

        let first = try registry.makeProvider(for: .deepSeek) as? DeepSeekUsageProvider
        #expect(first?.apiKey == "monitor-key")

        secrets.values.removeValue(forKey: AIUsageProviderRegistry.deepSeekUsageKeyAccount)
        let fallback = try registry.makeProvider(for: .deepSeek) as? DeepSeekUsageProvider
        #expect(fallback?.apiKey == "translation-key")
    }

    @Test("Hidden providers do not refresh and provider failures stay isolated")
    @MainActor
    func refreshIsolation() async {
        let suiteName = "TTSTests.AIUsageRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AIUsageSettingsStore(userDefaults: defaults)
        settingsStore.seedInitialProviderVisibility([.codex, .grok])
        let counter = AIUsageTestCounter()
        let resolver = FakeAIUsageProviderResolver(providers: [
            .codex: FakeAIUsageProvider(id: .codex) {
                await counter.increment(.codex)
                return AIUsageSnapshot(
                    providerID: .codex,
                    metrics: [.quotaWindow(label: "5 小时额度", remainingFraction: 0.8, resetsAt: nil)],
                    planName: "Plus",
                    source: "fixture",
                    updatedAt: .now
                )
            },
            .grok: FakeAIUsageProvider(id: .grok) {
                await counter.increment(.grok)
                throw AIUsageFailure.authentication("请登录。")
            },
        ])
        let store = AIUsageStore(
            settingsStore: settingsStore,
            providerRegistry: resolver,
            userDefaults: defaults
        )

        await store.refreshAll()

        #expect(store.states[.codex]?.snapshot != nil)
        #expect(store.states[.grok]?.failure?.category == .authentication)
        #expect(await counter.value(.codex) == 1)
        #expect(await counter.value(.grok) == 1)

        settingsStore.setProviderVisible(false, id: .grok)
        await store.refreshAll()
        #expect(await counter.value(.codex) == 2)
        #expect(await counter.value(.grok) == 1)
    }

    @Test("Codex account store atomically preserves current auth and activates target")
    func codexAccountCredentialStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-codex-accounts-\(UUID().uuidString)", isDirectory: true)
        let base = root.appendingPathComponent("switcher", isDirectory: true)
        let accounts = base.appendingPathComponent("accounts", isDirectory: true)
        let activeHome = root.appendingPathComponent("active", isDirectory: true)
        let firstID = UUID()
        let secondID = UUID()
        let firstHome = accounts.appendingPathComponent(firstID.uuidString, isDirectory: true)
        let secondHome = accounts.appendingPathComponent(secondID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: firstHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = CodexAccountProfile(
            id: firstID,
            displayName: "Plus",
            email: nil,
            accountID: "first",
            createdAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: nil
        )
        let second = CodexAccountProfile(
            id: secondID,
            displayName: "Pro",
            email: nil,
            accountID: "second",
            createdAt: Date(timeIntervalSince1970: 2),
            lastUsedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CodexAccountRegistry(activeAccountID: firstID, accounts: [first, second]))
            .write(to: base.appendingPathComponent("accounts.json"))
        try Data("saved-first".utf8).write(to: firstHome.appendingPathComponent("auth.json"))
        try Data("saved-second".utf8).write(to: secondHome.appendingPathComponent("auth.json"))
        try Data("fresh-first".utf8).write(to: activeHome.appendingPathComponent("auth.json"))

        let store = CodexAccountCredentialStore(baseURL: base, activeHomeURL: activeHome)
        try await store.saveCurrentCredential()
        #expect(try Data(contentsOf: firstHome.appendingPathComponent("auth.json")) == Data("fresh-first".utf8))

        try await store.activateCredential(id: secondID)
        #expect(try Data(contentsOf: activeHome.appendingPathComponent("auth.json")) == Data("saved-second".utf8))

        try await store.commitActiveAccountID(secondID)
        #expect(try await store.loadRegistry().activeAccountID == secondID)
    }

    @Test("Codex account store rejects a symlinked target credential")
    func codexAccountSymlinkRejection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-codex-symlink-\(UUID().uuidString)", isDirectory: true)
        let base = root.appendingPathComponent("switcher", isDirectory: true)
        let id = UUID()
        let accountHome = base
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let activeHome = root.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: accountHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = CodexAccountProfile(
            id: id,
            displayName: "Account",
            email: nil,
            accountID: "account",
            createdAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CodexAccountRegistry(activeAccountID: id, accounts: [profile]))
            .write(to: base.appendingPathComponent("accounts.json"))
        let outside = root.appendingPathComponent("outside-auth.json")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: accountHome.appendingPathComponent("auth.json"),
            withDestinationURL: outside
        )

        let store = CodexAccountCredentialStore(baseURL: base, activeHomeURL: activeHome)
        do {
            try await store.activateCredential(id: id)
            Issue.record("Expected a symlinked credential to be rejected")
        } catch let error as CodexAccountSwitchError {
            #expect(error == .unsafeStoragePath)
        }
        #expect(!FileManager.default.fileExists(atPath: activeHome.appendingPathComponent("auth.json").path))
    }

    @Test("Codex account switch verifies, commits, and reopens Desktop")
    @MainActor
    func codexAccountSwitchSequence() async throws {
        let first = CodexAccountProfile(
            id: UUID(), displayName: "Plus", email: nil, accountID: "first",
            createdAt: Date(timeIntervalSince1970: 1), lastUsedAt: nil
        )
        let second = CodexAccountProfile(
            id: UUID(), displayName: "Pro", email: nil, accountID: "second",
            createdAt: Date(timeIntervalSince1970: 2), lastUsedAt: nil
        )
        let backend = FakeCodexAccountBackend(accounts: [first, second], activeID: first.id)
        let desktop = FakeCodexDesktop()
        let service = CodexAccountSwitchService(
            store: backend,
            identityReader: backend,
            desktop: desktop
        )

        try await service.switchAccount(to: second.id)

        #expect(await backend.installedAccountID() == second.id)
        #expect(await backend.loadRegistry().activeAccountID == second.id)
        #expect(await backend.savedCurrentCredentialCount() == 1)
        #expect(desktop.closeCount == 1)
        #expect(desktop.reopenCount == 1)
    }

    @Test("Expired Codex target is reauthorized before switching")
    @MainActor
    func codexAccountSwitchReauthorizesExpiredTarget() async throws {
        let first = CodexAccountProfile(
            id: UUID(), displayName: "Current", email: nil, accountID: "current",
            createdAt: Date(timeIntervalSince1970: 1), lastUsedAt: nil
        )
        let second = CodexAccountProfile(
            id: UUID(), displayName: "Target", email: nil, accountID: "target",
            createdAt: Date(timeIntervalSince1970: 2), lastUsedAt: nil
        )
        let backend = FakeCodexAccountBackend(
            accounts: [first, second],
            activeID: first.id,
            expiredSessionIDs: [second.id],
            authorizationID: second.id
        )
        let desktop = FakeCodexDesktop()
        let service = CodexAccountSwitchService(
            store: backend,
            identityReader: backend,
            desktop: desktop
        )

        try await service.switchAccount(to: second.id)

        #expect(await backend.authorizationRequestCount() == 1)
        #expect(await backend.credentialInstallIDs() == [second.id])
        #expect(await backend.installedAccountID() == second.id)
        #expect(await backend.loadRegistry().activeAccountID == second.id)
        #expect(desktop.closeCount == 1)
        #expect(desktop.reopenCount == 1)
    }

    @Test("Wrong browser login never overwrites the selected Codex profile")
    @MainActor
    func codexAccountSwitchRejectsWrongAuthorization() async throws {
        let first = CodexAccountProfile(
            id: UUID(), displayName: "Current", email: nil, accountID: "current",
            createdAt: Date(timeIntervalSince1970: 1), lastUsedAt: nil
        )
        let second = CodexAccountProfile(
            id: UUID(), displayName: "Target", email: nil, accountID: "target",
            createdAt: Date(timeIntervalSince1970: 2), lastUsedAt: nil
        )
        let backend = FakeCodexAccountBackend(
            accounts: [first, second],
            activeID: first.id,
            expiredSessionIDs: [second.id],
            authorizationID: first.id
        )
        let desktop = FakeCodexDesktop()
        let service = CodexAccountSwitchService(
            store: backend,
            identityReader: backend,
            desktop: desktop
        )

        do {
            try await service.switchAccount(to: second.id)
            Issue.record("Expected the mismatched browser login to be rejected")
        } catch let error as CodexAccountSwitchError {
            #expect(error == .authorizationAccountMismatch("Target"))
        }

        #expect(await backend.authorizationRequestCount() == 1)
        #expect(await backend.credentialInstallIDs().isEmpty)
        #expect(await backend.installedAccountID() == first.id)
        #expect(await backend.loadRegistry().activeAccountID == first.id)
        #expect(desktop.closeCount == 0)
        #expect(desktop.reopenCount == 0)
    }

    @Test("Codex account list derives current marker from installed identity")
    @MainActor
    func codexAccountListUsesInstalledIdentity() async throws {
        let first = CodexAccountProfile(
            id: UUID(), displayName: "Stored", email: nil, accountID: "stored",
            createdAt: Date(timeIntervalSince1970: 1), lastUsedAt: nil
        )
        let second = CodexAccountProfile(
            id: UUID(), displayName: "Installed", email: nil, accountID: "installed",
            createdAt: Date(timeIntervalSince1970: 2), lastUsedAt: nil
        )
        let backend = FakeCodexAccountBackend(
            accounts: [first, second],
            activeID: first.id,
            installedID: second.id
        )
        let service = CodexAccountSwitchService(
            store: backend,
            identityReader: backend,
            desktop: FakeCodexDesktop()
        )

        let presentedRegistry = try await service.loadRegistry()

        #expect(presentedRegistry.activeAccountID == second.id)
        #expect(await backend.loadRegistry().activeAccountID == first.id)
    }

    @Test("Codex account switch repairs a stale current marker before saving")
    @MainActor
    func codexAccountSwitchRepairsStaleMarker() async throws {
        let first = CodexAccountProfile(
            id: UUID(), displayName: "Target", email: nil, accountID: "target",
            createdAt: Date(timeIntervalSince1970: 1), lastUsedAt: nil
        )
        let second = CodexAccountProfile(
            id: UUID(), displayName: "Installed", email: nil, accountID: "installed",
            createdAt: Date(timeIntervalSince1970: 2), lastUsedAt: nil
        )
        let backend = FakeCodexAccountBackend(
            accounts: [first, second],
            activeID: first.id,
            installedID: second.id
        )
        let service = CodexAccountSwitchService(
            store: backend,
            identityReader: backend,
            desktop: FakeCodexDesktop()
        )

        try await service.switchAccount(to: first.id)

        #expect(await backend.savedAccountIDs() == [second.id])
        #expect(await backend.installedAccountID() == first.id)
        #expect(await backend.loadRegistry().activeAccountID == first.id)
    }

    @Test("Codex Desktop reopens at the Codex entry point")
    @MainActor
    func codexDesktopReopenRoute() {
        #expect(
            CodexDesktopController.codexEntryURL.absoluteString
                == "codex://threads/new?mode=local"
        )
    }

    @Test("Codex account switch restores previous auth when target verification fails")
    @MainActor
    func codexAccountSwitchRollback() async throws {
        let first = CodexAccountProfile(
            id: UUID(), displayName: "Plus", email: nil, accountID: "first",
            createdAt: Date(timeIntervalSince1970: 1), lastUsedAt: nil
        )
        let second = CodexAccountProfile(
            id: UUID(), displayName: "Pro", email: nil, accountID: "second",
            createdAt: Date(timeIntervalSince1970: 2), lastUsedAt: nil
        )
        let backend = FakeCodexAccountBackend(
            accounts: [first, second],
            activeID: first.id,
            identityFailureID: second.id
        )
        let desktop = FakeCodexDesktop()
        let service = CodexAccountSwitchService(
            store: backend,
            identityReader: backend,
            desktop: desktop
        )

        do {
            try await service.switchAccount(to: second.id)
            Issue.record("Expected target identity verification to fail")
        } catch let error as CodexAccountSwitchError {
            #expect(error == .identityUnavailable)
        }

        #expect(await backend.installedAccountID() == first.id)
        #expect(await backend.loadRegistry().activeAccountID == first.id)
        #expect(desktop.closeCount == 1)
        #expect(desktop.reopenCount == 1)
    }
}

private actor FakeCodexAccountBackend: CodexAccountCredentialStoring, CodexAccountIdentityReading {
    private var registry: CodexAccountRegistry
    private var installedID: UUID
    private let identityFailureID: UUID?
    private var expiredSessionIDs: Set<UUID>
    private let authorizationID: UUID?
    private var saveCount = 0
    private var savedIDs: [UUID] = []
    private var installedCredentialIDs: [UUID] = []
    private var authorizationCount = 0

    init(
        accounts: [CodexAccountProfile],
        activeID: UUID,
        installedID: UUID? = nil,
        identityFailureID: UUID? = nil,
        expiredSessionIDs: Set<UUID> = [],
        authorizationID: UUID? = nil
    ) {
        registry = CodexAccountRegistry(activeAccountID: activeID, accounts: accounts)
        self.installedID = installedID ?? activeID
        self.identityFailureID = identityFailureID
        self.expiredSessionIDs = expiredSessionIDs
        self.authorizationID = authorizationID
    }

    func loadRegistry() -> CodexAccountRegistry { registry }

    func profile(id: UUID) throws -> CodexAccountProfile {
        guard let profile = registry.accounts.first(where: { $0.id == id }) else {
            throw CodexAccountSwitchError.profileNotFound
        }
        return profile
    }

    func activeHome() -> URL { URL(fileURLWithPath: "/private/tmp/fake-codex-home") }
    func profileHome(id: UUID) -> URL {
        URL(fileURLWithPath: "/private/tmp/fake-codex-profile-\(id.uuidString)")
    }
    func saveCurrentCredential() {
        saveCount += 1
        if let activeID = registry.activeAccountID {
            savedIDs.append(activeID)
        }
    }
    func installCredential(_ data: Data, id: UUID) {
        _ = data
        installedCredentialIDs.append(id)
        expiredSessionIDs.remove(id)
    }
    func activateCredential(id: UUID) { installedID = id }
    func restoreCredential(id: UUID) { installedID = id }

    func commitActiveAccountID(_ id: UUID) {
        registry.activeAccountID = id
    }

    func readIdentity(
        profileHome: URL,
        validateSession: Bool
    ) throws -> CodexAccountIdentity {
        let isActiveHome = profileHome.path == "/private/tmp/fake-codex-home"
        let profileID = registry.accounts.first(where: {
            profileHome.lastPathComponent == "fake-codex-profile-\($0.id.uuidString)"
        })?.id ?? installedID
        guard !(isActiveHome && profileID == identityFailureID),
              let profile = registry.accounts.first(where: { $0.id == profileID }) else {
            throw CodexAccountSwitchError.identityUnavailable
        }
        if validateSession, expiredSessionIDs.contains(profileID) {
            throw CodexAccountSwitchError.credentialExpired
        }
        return CodexAccountIdentity(accountID: profile.accountID, email: profile.email)
    }

    func authorize() throws -> CodexAccountAuthorization {
        authorizationCount += 1
        guard let authorizationID,
              let profile = registry.accounts.first(where: { $0.id == authorizationID }) else {
            throw CodexAccountSwitchError.operationFailed("Authorization was not configured.")
        }
        return CodexAccountAuthorization(
            identity: CodexAccountIdentity(accountID: profile.accountID, email: profile.email),
            credential: Data("refreshed-credential".utf8)
        )
    }

    func installedAccountID() -> UUID { installedID }
    func savedCurrentCredentialCount() -> Int { saveCount }
    func savedAccountIDs() -> [UUID] { savedIDs }
    func credentialInstallIDs() -> [UUID] { installedCredentialIDs }
    func authorizationRequestCount() -> Int { authorizationCount }
}

@MainActor
private final class FakeCodexDesktop: CodexDesktopControlling {
    private(set) var closeCount = 0
    private(set) var reopenCount = 0

    func closeDesktop() async throws { closeCount += 1 }
    func reopenDesktop() async throws { reopenCount += 1 }
}

private final class FakeAIUsageSecretReader: AIUsageSecretReading {
    var values: [String: String]
    private(set) var loadCount = 0

    init(values: [String: String]) {
        self.values = values
    }

    func containsAPIKey(account: String) -> Bool {
        values[account]?.isEmpty == false
    }

    func loadAPIKey(account: String) throws -> String? {
        loadCount += 1
        return values[account]
    }
}

private actor AIUsageTestCounter {
    private var counts: [AIUsageProviderID: Int] = [:]

    func increment(_ id: AIUsageProviderID) {
        counts[id, default: 0] += 1
    }

    func value(_ id: AIUsageProviderID) -> Int {
        counts[id, default: 0]
    }
}

private struct FakeAIUsageProvider: AIUsageProvider {
    var id: AIUsageProviderID
    var fetch: @Sendable () async throws -> AIUsageSnapshot

    func fetchUsage() async throws -> AIUsageSnapshot {
        try await fetch()
    }
}

@MainActor
private final class FakeAIUsageProviderResolver: AIUsageProviderResolving {
    let descriptors: [AIUsageProviderDescriptor] = []
    var providers: [AIUsageProviderID: any AIUsageProvider]

    init(providers: [AIUsageProviderID: any AIUsageProvider]) {
        self.providers = providers
    }

    func detectedProviderIDs() -> Set<AIUsageProviderID> {
        Set(providers.keys)
    }

    func configurationStatus(for id: AIUsageProviderID) -> String {
        providers[id] == nil ? "未配置" : "已配置"
    }

    func makeProvider(for id: AIUsageProviderID) throws -> any AIUsageProvider {
        guard let provider = providers[id] else {
            throw AIUsageFailure.notConfigured("未配置")
        }
        return provider
    }
}
#endif
