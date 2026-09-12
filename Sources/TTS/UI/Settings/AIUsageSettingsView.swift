import SwiftUI

struct AIUsageSettingsView: View {
    @ObservedObject var viewModel: AIUsageSettingsViewModel

    var body: some View {
        SettingsPage(
            title: "订阅监控",
            subtitle: "选择菜单栏弹窗中的订阅额度与快捷操作，并管理安全凭据",
            systemImage: "gauge"
        ) {
            SettingsSectionCard(title: "订阅额度", systemImage: "chart.bar.xaxis") {
                Text("拖动行可调整弹窗顺序；关闭后不会在后台读取该服务商。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    ForEach(viewModel.providerPreferences) { preference in
                        AIUsageProviderPreferenceRow(
                            preference: preference,
                            status: viewModel.configurationStatus(for: preference.id),
                            onToggle: { viewModel.setProviderVisible($0, id: preference.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .onMove(perform: viewModel.moveProviders)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: 286)

                HStack {
                    Text("后台每 5 分钟刷新；打开弹窗且数据超过 1 分钟时会按需刷新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即刷新") {
                        viewModel.refreshNow()
                    }
                    .buttonStyle(TTSSecondaryButtonStyle())
                }
            }

            SettingsSectionCard(title: "快捷操作", systemImage: "bolt.fill") {
                Text("拖动调整顺序；设置与退出固定在弹窗底部，不会被隐藏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    ForEach(viewModel.quickActionPreferences) { preference in
                        MenuQuickActionPreferenceRow(
                            preference: preference,
                            onToggle: { viewModel.setQuickActionVisible($0, id: preference.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .onMove(perform: viewModel.moveQuickActions)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: 526)
            }

            SettingsSectionCard(title: "凭据与来源", systemImage: "key.fill") {
                SettingsInfoRow(
                    title: "ChatGPT / Codex",
                    message: "\(viewModel.configurationStatus(for: .codex))。只读取 Codex 的 5 小时、周额度与 Credits，不代表全部 ChatGPT 网页聊天用量。",
                    systemImage: AIUsageProviderID.codex.systemImage
                )

                settingsDivider

                SettingsInfoRow(
                    title: "Grok 共享额度",
                    message: "\(viewModel.configurationStatus(for: .grok))。优先通过 Grok CLI 读取 Billing；旧版 CLI 不支持时复用同一份本机登录态读取官方共享周额度，不读取浏览器 Cookie。",
                    systemImage: AIUsageProviderID.grok.systemImage
                )

                settingsDivider

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("DeepSeek API 余额")
                                .font(.subheadline.weight(.semibold))
                            Text(viewModel.configurationStatus(for: .deepSeek))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("复用翻译 Key", isOn: $viewModel.deepSeekUsesTranslationKey)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsSecureField(
                        title: "监控专用 API Key（可选，优先于翻译 Key）",
                        placeholder: "保存在 macOS Keychain",
                        text: $viewModel.deepSeekUsageAPIKey
                    )
                }

                settingsDivider

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("MiniMax Coding Plan")
                                .font(.subheadline.weight(.semibold))
                            Text(viewModel.configurationStatus(for: .miniMax))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("区域", selection: $viewModel.miniMaxRegion) {
                            ForEach(MiniMaxUsageRegion.allCases) { region in
                                Text(region.displayName).tag(region)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 112)
                    }
                    SettingsSecureField(
                        title: "Coding Plan API Key",
                        placeholder: "保存在 macOS Keychain",
                        text: $viewModel.miniMaxUsageAPIKey
                    )
                }

                HStack {
                    if !viewModel.statusMessage.isEmpty {
                        Text(viewModel.statusMessage)
                            .font(.caption)
                            .foregroundStyle(viewModel.statusIsError ? Color.red : TTSVisualStyle.accentStrong)
                    }
                    Spacer()
                    Button("保存监控凭据") {
                        viewModel.saveCredentialSettings()
                    }
                    .buttonStyle(TTSPrimaryButtonStyle())
                }

                settingsDivider

                SettingsInfoRow(
                    title: "AntiGravity",
                    message: "\(viewModel.configurationStatus(for: .gemini))。只连接 127.0.0.1 上的本机额度服务，不复制 OAuth 凭据，也不抓取网页 Cookie。",
                    systemImage: AIUsageProviderID.gemini.systemImage
                )
            }

            SettingsSectionCard(title: "数据边界", systemImage: "hand.raised.fill") {
                SettingsInfoRow(
                    title: "不合并不同单位",
                    message: "5 小时、周额度、Token 与货币余额分别展示；顶部只汇总正常、需关注和未配置状态。",
                    systemImage: "rectangle.3.group"
                )
                SettingsInfoRow(
                    title: "有限本地缓存",
                    message: "只保留每家最近一次非敏感快照，不保存历史曲线、邮箱、Key、Token、Cookie 或原始响应。",
                    systemImage: "internaldrive"
                )
            }
        }
        .onAppear {
            viewModel.reload()
        }
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(TTSVisualStyle.subtleBorder)
            .frame(height: 1)
    }
}

private struct AIUsageProviderPreferenceRow: View {
    var preference: AIUsageProviderPreference
    var status: String
    var onToggle: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .help("拖动调整顺序")
            AIUsageProviderBrandIcon(providerID: preference.id, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(preference.id.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("显示", isOn: Binding(
                get: { preference.isVisible },
                set: { value in onToggle(value) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(TTSVisualStyle.controlSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
        }
    }
}

private struct MenuQuickActionPreferenceRow: View {
    var preference: MenuQuickActionPreference
    var onToggle: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .help("拖动调整顺序")
            Image(systemName: preference.id.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TTSVisualStyle.accentStrong)
                .frame(width: 30, height: 30)
                .background(TTSVisualStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(preference.id.displayName)
                .font(.subheadline.weight(.medium))
            Spacer()
            Toggle("显示", isOn: Binding(
                get: { preference.isVisible },
                set: { value in onToggle(value) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(TTSVisualStyle.controlSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
        }
    }
}

@MainActor
final class AIUsageSettingsViewModel: ObservableObject {
    @Published var providerPreferences: [AIUsageProviderPreference] = []
    @Published var quickActionPreferences: [MenuQuickActionPreference] = []
    @Published var deepSeekUsageAPIKey = ""
    @Published var miniMaxUsageAPIKey = ""
    @Published var deepSeekUsesTranslationKey = true
    @Published var miniMaxRegion: MiniMaxUsageRegion = .chinaMainland
    @Published var statusMessage = ""
    @Published var statusIsError = false

    private let settingsStore: AIUsageSettingsStore
    private let providerRegistry: AIUsageProviderRegistry
    private let keychainService: KeychainService
    private let usageStore: AIUsageStore

    init(
        settingsStore: AIUsageSettingsStore,
        providerRegistry: AIUsageProviderRegistry,
        keychainService: KeychainService,
        usageStore: AIUsageStore
    ) {
        self.settingsStore = settingsStore
        self.providerRegistry = providerRegistry
        self.keychainService = keychainService
        self.usageStore = usageStore
        reload()
    }

    func reload() {
        providerPreferences = settingsStore.providerPreferences
        quickActionPreferences = settingsStore.quickActionPreferences
        deepSeekUsesTranslationKey = settingsStore.settings.deepSeekUsesTranslationKey
        miniMaxRegion = settingsStore.settings.miniMaxRegion
        deepSeekUsageAPIKey = (try? keychainService.loadAPIKey(
            account: AIUsageProviderRegistry.deepSeekUsageKeyAccount
        )) ?? ""
        miniMaxUsageAPIKey = (try? keychainService.loadAPIKey(
            account: AIUsageProviderRegistry.miniMaxUsageKeyAccount
        )) ?? ""
    }

    func configurationStatus(for id: AIUsageProviderID) -> String {
        providerRegistry.configurationStatus(for: id)
    }

    func setProviderVisible(_ isVisible: Bool, id: AIUsageProviderID) {
        settingsStore.setProviderVisible(isVisible, id: id)
        reloadPreferences()
        if isVisible {
            usageStore.refreshNow()
        }
    }

    func moveProviders(fromOffsets: IndexSet, toOffset: Int) {
        settingsStore.moveProviders(fromOffsets: fromOffsets, toOffset: toOffset)
        reloadPreferences()
    }

    func setQuickActionVisible(_ isVisible: Bool, id: MenuQuickActionID) {
        settingsStore.setQuickActionVisible(isVisible, id: id)
        reloadPreferences()
    }

    func moveQuickActions(fromOffsets: IndexSet, toOffset: Int) {
        settingsStore.moveQuickActions(fromOffsets: fromOffsets, toOffset: toOffset)
        reloadPreferences()
    }

    func saveCredentialSettings() {
        settingsStore.setDeepSeekUsesTranslationKey(deepSeekUsesTranslationKey)
        settingsStore.setMiniMaxRegion(miniMaxRegion)
        do {
            try saveKey(
                deepSeekUsageAPIKey,
                account: AIUsageProviderRegistry.deepSeekUsageKeyAccount
            )
            try saveKey(
                miniMaxUsageAPIKey,
                account: AIUsageProviderRegistry.miniMaxUsageKeyAccount
            )
            statusMessage = "订阅监控凭据已保存。"
            statusIsError = false
            reloadPreferences()
            usageStore.refreshNow()
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    func refreshNow() {
        usageStore.refreshNow()
    }

    private func saveKey(_ value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychainService.deleteAPIKey(account: account)
        } else {
            try keychainService.saveAPIKey(trimmed, account: account)
        }
    }

    private func reloadPreferences() {
        providerPreferences = settingsStore.providerPreferences
        quickActionPreferences = settingsStore.quickActionPreferences
    }
}
