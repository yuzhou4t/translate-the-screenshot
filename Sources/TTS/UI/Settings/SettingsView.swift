import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @StateObject var viewModel: SettingsViewModel

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            shortcutSettings
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }

            translationServiceSettings
                .tabItem {
                    Label("翻译服务", systemImage: "network")
                }

            aiModeSettings
                .tabItem {
                    Label("AI 模式", systemImage: "sparkles")
                }

            modelConfigurationSettings
                .tabItem {
                    Label("模型配置", systemImage: "slider.horizontal.3")
                }

            permissionPrivacySettings
                .tabItem {
                    Label("权限与隐私", systemImage: "lock.shield")
                }
        }
        .frame(minWidth: 960, idealWidth: 1000, minHeight: 680, idealHeight: 720)
        .background(.background)
        .onAppear {
            viewModel.reload()
        }
    }

    private var generalSettings: some View {
        Form {
            Section("基础设置") {
                LabeledContent("产品定位") {
                    Text("轻量化 AI 截图翻译")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("默认翻译服务") {
                    Text(viewModel.defaultProviderID.displayName)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Picker("翻译方向", selection: $viewModel.translationDirection) {
                        ForEach(TranslationDirection.allCases) { direction in
                            Text(direction.displayName)
                                .tag(direction)
                        }
                    }
                    .pickerStyle(.menu)
                    .buttonStyle(.bordered)
                    .frame(width: 280)

                    Button("保存") {
                        viewModel.saveTranslationDirection()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }

                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                }
            }

            Section("核心工作流") {
                SettingsInfoRow(
                    title: "划词翻译",
                    message: "读取选中文字后直接使用默认服务翻译。",
                    systemImage: "text.cursor"
                )
                SettingsInfoRow(
                    title: "截图翻译",
                    message: "先通过本地 OCR 识别截图文本，再交给翻译服务处理。",
                    systemImage: "viewfinder"
                )
                SettingsInfoRow(
                    title: "服务 fallback",
                    message: "已启用的服务会按默认服务和优先级进行尝试。",
                    systemImage: "arrow.triangle.branch"
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var translationServiceSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("翻译服务", systemImage: "network")
                    .font(.headline)

                Text("\(viewModel.enabledProviderCount) 个已启用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())

                Spacer()

                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                providerList
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 360)

                Divider()

                providerDetails
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("服务商")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.providerConfigs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            List(selection: $viewModel.selectedProviderID) {
                Section("AI 大模型") {
                    ForEach(viewModel.aiProviderConfigs) { config in
                        providerRow(config)
                    }
                }

                Section("传统翻译") {
                    ForEach(viewModel.traditionalProviderConfigs) { config in
                        providerRow(config)
                    }
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
        .background(.background)
    }

    private func providerRow(_ config: ProviderConfig) -> some View {
        ProviderConfigRow(
            config: config,
            isDefault: config.id == viewModel.defaultProviderID,
            isImplemented: viewModel.isImplemented(config.id),
            onSelect: {
                viewModel.selectProvider(config.id)
            },
            onToggleEnabled: { isEnabled in
                viewModel.setEnabled(isEnabled, for: config.id)
            },
            onSetDefault: {
                viewModel.setDefaultProvider(config.id)
            },
            onPriorityChange: { priority in
                viewModel.setPriority(priority, for: config.id)
            }
        )
        .tag(config.id)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var providerDetails: some View {
        if let config = viewModel.selectedProviderConfig {
            Form {
                Text(config.displayName)
                    .font(.headline)

                LabeledContent("类型") {
                    Text(config.type.displayName)
                }

                LabeledContent("接入状态") {
                    Text(viewModel.isImplemented(config.id) ? "已接入" : "待接入")
                        .foregroundStyle(viewModel.isImplemented(config.id) ? Color.green : Color.secondary)
                }

                TextField("Endpoint", text: $viewModel.endpoint)
                    .textFieldStyle(.roundedBorder)

                TextField("模型 / 区域", text: $viewModel.model)
                    .textFieldStyle(.roundedBorder)

                TextField("App ID / SecretId / AccessKeyId", text: $viewModel.appID)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Key", text: $viewModel.apiKey)
                    .textFieldStyle(.roundedBorder)

                SecureField("Secret Key", text: $viewModel.secretKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("超时")
                    TextField("秒", value: $viewModel.timeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("秒")
                        .foregroundStyle(.secondary)
                }

                Toggle("认证失败时继续切换备用服务", isOn: $viewModel.shouldFallbackOnAuthFailure)

                Button("保存当前服务商配置") {
                    viewModel.saveSelectedProvider()
                }
                .keyboardShortcut(.defaultAction)
            }
            .formStyle(.grouped)
        } else {
            Text("请选择一个服务商")
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutSettings: some View {
        Form {
            Section("快捷键") {
                KeyboardShortcuts.Recorder("划词翻译", name: .translateSelection)
                KeyboardShortcuts.Recorder("输入翻译", name: .inputTranslate)
                KeyboardShortcuts.Recorder("截图翻译", name: .screenshotTranslate)
                KeyboardShortcuts.Recorder("截图 OCR", name: .screenshotOCR)
                KeyboardShortcuts.Recorder("静默截图 OCR", name: .silentScreenshotOCR)
            }

            Section("说明") {
                SettingsInfoRow(
                    title: "全局快捷键",
                    message: "这些快捷键由系统监听，TTS 在菜单栏常驻时即可触发对应操作。",
                    systemImage: "keyboard"
                )
                SettingsInfoRow(
                    title: "截图相关快捷键",
                    message: "截图翻译会先 OCR 再翻译；截图 OCR 只显示识别文本；静默截图 OCR 会直接复制识别结果。",
                    systemImage: "viewfinder"
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var aiModeSettings: some View {
        Form {
            Section("默认 AI 翻译模式") {
                Picker("默认模式", selection: $viewModel.defaultTranslationMode) {
                    ForEach(TranslationMode.allCases) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                    }
                }

                Text(viewModel.defaultTranslationMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("保存默认 AI 模式") {
                    viewModel.saveDefaultTranslationMode()
                }
            }

            Section("模式说明") {
                ForEach(TranslationMode.allCases) { mode in
                    SettingsInfoRow(
                        title: mode.displayName,
                        message: mode.description,
                        systemImage: mode.systemImage
                    )
                }
            }

            Section("提示词预留") {
                Text("大模型类服务会使用所选模式的 prompt；传统翻译服务会保持原有请求方式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var modelConfigurationSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("模型配置", systemImage: "slider.horizontal.3")
                    .font(.headline)

                Text("\(viewModel.modelProfiles.count) 个 Profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())

                Spacer()

                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                modelProfileList
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 360)

                Divider()

                modelProfileDetails
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var modelProfileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("用途 Profile")
                    .font(.headline)
                Spacer()
                Text("暂不参与路由")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            List(selection: $viewModel.selectedModelProfileID) {
                ForEach(viewModel.modelProfiles) { profile in
                    ModelProfileRow(
                        profile: profile,
                        providerName: profile.providerID.displayName,
                        isSelected: profile.id == viewModel.selectedModelProfileID,
                        onSelect: {
                            viewModel.selectModelProfile(profile.id)
                        }
                    )
                    .tag(profile.id)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
        .background(.background)
    }

    @ViewBuilder
    private var modelProfileDetails: some View {
        if viewModel.selectedModelProfile != nil {
            Form {
                Section("基础信息") {
                    TextField("名称", text: $viewModel.modelProfileName)
                        .textFieldStyle(.roundedBorder)

                    Picker("Provider", selection: $viewModel.modelProfileProviderID) {
                        ForEach(viewModel.translationProviderIDs) { providerID in
                            Text(providerID.displayName)
                                .tag(providerID)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("Model Name", text: $viewModel.modelProfileModelName)
                        .textFieldStyle(.roundedBorder)

                    Picker("用途", selection: $viewModel.modelProfilePurpose) {
                        ForEach(ModelPurpose.allCases) { purpose in
                            Text(purpose.displayName)
                                .tag(purpose)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(viewModel.modelProfilePurpose.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("调度设置") {
                    Toggle("启用", isOn: $viewModel.modelProfileIsEnabled)

                    Stepper("优先级 \(viewModel.modelProfilePriority)", value: $viewModel.modelProfilePriority, in: 1...999)
                }

                if let profile = viewModel.selectedModelProfile {
                    Section("能力评分") {
                        ModelCapabilityScoreView(score: profile.capabilityScore)
                    }
                }

                Section {
                    Button("保存模型 Profile") {
                        viewModel.saveSelectedModelProfile()
                    }
                    .keyboardShortcut(.defaultAction)
                } footer: {
                    Text("当前仅保存精细化模型配置，为后续模型路由和 fallback 做准备，暂不影响真实翻译调用。")
                }
            }
            .formStyle(.grouped)
        } else {
            Text("请选择一个模型 Profile")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionPrivacySettings: some View {
        Form {
            Section("权限状态") {
                LabeledContent("辅助功能") {
                    Text(viewModel.accessibilityStatus)
                        .foregroundStyle(viewModel.isAccessibilityTrusted ? Color.green : Color.red)
                }

                LabeledContent("屏幕录制") {
                    Text(viewModel.screenRecordingStatus)
                        .foregroundStyle(viewModel.isScreenRecordingTrusted ? Color.green : Color.red)
                }

                HStack {
                    Button("请求辅助功能权限") {
                        viewModel.requestAccessibility()
                    }

                    Button("请求屏幕录制权限") {
                        viewModel.requestScreenRecording()
                    }

                    Button("刷新状态") {
                        viewModel.refreshPermissions()
                    }
                }
            }

            Section("隐私说明") {
                SettingsInfoRow(
                    title: "截图 OCR",
                    message: "截图内容用于本机 Apple Vision OCR；截图翻译会把识别后的文本交给你启用的翻译服务。",
                    systemImage: "viewfinder"
                )
                SettingsInfoRow(
                    title: "API Key",
                    message: "API Key 继续使用 Keychain 保存，不写入仓库、构建产物或本地明文配置。",
                    systemImage: "key"
                )

                Text("如果已经授权但这里仍显示未授权，请完全退出并重新打开 /Applications/TTS.app。macOS 会按具体 app 路径记录权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            viewModel.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
    }
}

private struct SettingsInfoRow: View {
    var title: String
    var message: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ModelProfileRow: View {
    var profile: ModelProfile
    var providerName: String
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                    Text(providerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusPill(
                    text: profile.purpose.displayName,
                    systemImage: "target",
                    tint: isSelected ? .accentColor : .secondary
                )
            }

            HStack(spacing: 6) {
                StatusPill(
                    text: profile.isEnabled ? "启用" : "停用",
                    systemImage: profile.isEnabled ? "bolt.fill" : "pause.circle",
                    tint: profile.isEnabled ? .green : .secondary
                )

                StatusPill(
                    text: "优先级 \(profile.priority)",
                    systemImage: "arrow.up.arrow.down",
                    tint: .secondary
                )

                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
        )
        .padding(.vertical, 3)
    }
}

private struct ModelCapabilityScoreView: View {
    var score: ModelCapabilityScore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            scoreRow("速度", score.speed)
            scoreRow("质量", score.quality)
            scoreRow("学术", score.academic)
            scoreRow("技术", score.technical)
            scoreRow("OCR 修复", score.ocrCleanup)
            scoreRow("格式遵循", score.formatFollowing)
            scoreRow("成本效率", score.costEfficiency)
        }
    }

    private func scoreRow(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(.secondary)

            ForEach(1...5, id: \.self) { index in
                Circle()
                    .fill(index <= value ? Color.accentColor : Color(NSColor.separatorColor).opacity(0.45))
                    .frame(width: 8, height: 8)
            }

            Text("\(value)/5")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .font(.caption)
    }
}

private struct ProviderConfigRow: View {
    var config: ProviderConfig
    var isDefault: Bool
    var isImplemented: Bool
    var onSelect: () -> Void
    var onToggleEnabled: (Bool) -> Void
    var onSetDefault: () -> Void
    var onPriorityChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.displayName)
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 6) {
                        StatusPill(
                            text: isImplemented ? "已接入" : "待接入",
                            systemImage: isImplemented ? "checkmark.circle.fill" : "clock",
                            tint: isImplemented ? .green : .secondary
                        )
                        if config.isEnabled {
                            StatusPill(text: "启用", systemImage: "bolt.fill", tint: .accentColor)
                        }
                    }
                }

                Spacer()

                if isDefault {
                    StatusPill(text: "默认", systemImage: "checkmark.seal.fill", tint: .accentColor)
                }
            }

            Toggle("启用", isOn: Binding(
                get: { config.isEnabled },
                set: { onToggleEnabled($0) }
            ))
            .disabled(isDefault)

            HStack {
                Stepper("优先级 \(config.priority)", value: Binding(
                    get: { config.priority },
                    set: { onPriorityChange($0) }
                ), in: 1...999)

                Spacer()

                Button("设为默认") {
                    onSetDefault()
                }
                .disabled(isDefault)
            }
            .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .padding(.vertical, 3)
    }
}

private struct StatusPill: View {
    var text: String
    var systemImage: String
    var tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var providerConfigs: [ProviderConfig] = []
    @Published var defaultProviderID: TranslationProviderID
    @Published var selectedProviderID: TranslationProviderID?
    @Published var endpoint = ""
    @Published var model = ""
    @Published var appID = ""
    @Published var apiKey = ""
    @Published var secretKey = ""
    @Published var timeout: Double = 30
    @Published var shouldFallbackOnAuthFailure = true
    @Published var targetLanguage: String
    @Published var translationDirection: TranslationDirection
    @Published var defaultTranslationMode: TranslationMode
    @Published var modelProfiles: [ModelProfile] = []
    @Published var selectedModelProfileID: UUID?
    @Published var modelProfileName = ""
    @Published var modelProfileProviderID: TranslationProviderID = .openAICompatible
    @Published var modelProfileModelName = ""
    @Published var modelProfilePurpose: ModelPurpose = .quality
    @Published var modelProfilePriority = 10
    @Published var modelProfileIsEnabled = true
    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var isAccessibilityTrusted = false
    @Published var isScreenRecordingTrusted = false

    private let configurationStore: AppConfigurationStore
    private let keychainService: KeychainService
    private let providerRegistry: ProviderRegistry
    private let permissionManager = AppServices.shared.permissionManager
    private let aiProviderIDs: Set<TranslationProviderID> = [
        .openAICompatible,
        .glm4Flash,
        .siliconFlow
    ]

    init(
        configurationStore: AppConfigurationStore,
        keychainService: KeychainService,
        providerRegistry: ProviderRegistry
    ) {
        self.configurationStore = configurationStore
        self.keychainService = keychainService
        self.providerRegistry = providerRegistry
        defaultProviderID = configurationStore.defaultProviderID
        targetLanguage = configurationStore.targetLanguage
        translationDirection = configurationStore.translationDirection
        defaultTranslationMode = configurationStore.defaultTranslationMode
        reload()
        refreshPermissions()
    }

    var selectedProviderConfig: ProviderConfig? {
        guard let selectedProviderID else {
            return nil
        }
        return providerConfigs.first { $0.id == selectedProviderID }
    }

    var selectedModelProfile: ModelProfile? {
        guard let selectedModelProfileID else {
            return nil
        }
        return modelProfiles.first { $0.id == selectedModelProfileID }
    }

    var translationProviderIDs: [TranslationProviderID] {
        TranslationProviderID.allCases.filter(\.isTranslationProvider)
    }

    var enabledProviderCount: Int {
        providerConfigs.filter(\.isEnabled).count
    }

    var aiProviderConfigs: [ProviderConfig] {
        providerConfigs.filter { aiProviderIDs.contains($0.id) }
    }

    var traditionalProviderConfigs: [ProviderConfig] {
        providerConfigs.filter { !aiProviderIDs.contains($0.id) }
    }

    var accessibilityStatus: String {
        isAccessibilityTrusted ? "已授权" : "未授权"
    }

    var screenRecordingStatus: String {
        isScreenRecordingTrusted ? "已授权" : "未授权"
    }

    func reload() {
        providerConfigs = configurationStore.providerConfigs
        defaultProviderID = configurationStore.defaultProviderID
        targetLanguage = configurationStore.targetLanguage
        translationDirection = configurationStore.translationDirection
        defaultTranslationMode = configurationStore.defaultTranslationMode
        modelProfiles = configurationStore.modelProfiles

        if selectedProviderID == nil || selectedProviderConfig == nil {
            selectedProviderID = defaultProviderID
        }

        if selectedModelProfileID == nil || selectedModelProfile == nil {
            selectedModelProfileID = modelProfiles.first?.id
        }

        loadSelectedProviderFields()
        loadSelectedModelProfileFields()
    }

    func isImplemented(_ id: TranslationProviderID) -> Bool {
        providerRegistry.descriptor(for: id)?.isImplemented == true
    }

    func selectProvider(_ id: TranslationProviderID) {
        selectedProviderID = id
        loadSelectedProviderFields()
    }

    func setEnabled(_ isEnabled: Bool, for id: TranslationProviderID) {
        guard var config = providerConfigs.first(where: { $0.id == id }) else {
            return
        }
        config.isEnabled = isEnabled
        configurationStore.updateProviderConfig(config)
        reload()
    }

    func setDefaultProvider(_ id: TranslationProviderID) {
        configurationStore.setDefaultProvider(id)
        reload()
        status("默认服务商已更新。", isError: false)
    }

    func setPriority(_ priority: Int, for id: TranslationProviderID) {
        guard var config = providerConfigs.first(where: { $0.id == id }) else {
            return
        }
        config.priority = priority
        configurationStore.updateProviderConfig(config)
        reload()
    }

    func saveTranslationDirection() {
        configurationStore.setTranslationDirection(translationDirection)
        reload()
        status("翻译方向已保存。", isError: false)
    }

    func saveDefaultTranslationMode() {
        configurationStore.setDefaultTranslationMode(defaultTranslationMode)
        reload()
        status("默认 AI 模式已保存。", isError: false)
    }

    func selectModelProfile(_ id: UUID) {
        selectedModelProfileID = id
        loadSelectedModelProfileFields()
    }

    func saveSelectedModelProfile() {
        guard var profile = selectedModelProfile else {
            return
        }

        let trimmedName = modelProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = trimmedName.isEmpty ? profile.name : trimmedName
        profile.providerID = modelProfileProviderID
        profile.modelName = modelProfileModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.purpose = modelProfilePurpose
        profile.priority = modelProfilePriority
        profile.isEnabled = modelProfileIsEnabled

        configurationStore.updateModelProfile(profile)
        reload()
        selectedModelProfileID = profile.id
        loadSelectedModelProfileFields()
        status("模型 Profile 已保存。", isError: false)
    }

    func saveSelectedProvider() {
        guard var config = selectedProviderConfig else {
            return
        }

        config.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : appID.trimmingCharacters(in: .whitespacesAndNewlines)
        config.secretKey = nil
        config.timeout = timeout
        config.shouldFallbackOnAuthFailure = shouldFallbackOnAuthFailure

        do {
            if let apiKeyRef = config.apiKeyRef {
                if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try keychainService.deleteAPIKey(account: apiKeyRef)
                } else {
                    try keychainService.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: apiKeyRef)
                }
            }

            let secretKeyAccount = "\(config.id.rawValue).secretKey"
            if secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychainService.deleteAPIKey(account: secretKeyAccount)
            } else {
                try keychainService.saveAPIKey(
                    secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    account: secretKeyAccount
                )
            }

            configurationStore.updateProviderConfig(config)
            reload()
            status("服务商配置已保存。", isError: false)
        } catch {
            status(error.localizedDescription, isError: true)
        }
    }

    func refreshPermissions() {
        isAccessibilityTrusted = permissionManager.isAccessibilityTrusted
        isScreenRecordingTrusted = permissionManager.isScreenRecordingTrusted
    }

    func requestAccessibility() {
        permissionManager.requestAccessibilityAndOpenSettingsIfNeeded()
        refreshPermissions()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            refreshPermissions()
        }
    }

    func requestScreenRecording() {
        permissionManager.requestScreenRecordingIfNeeded()
        permissionManager.openScreenRecordingSettings()
        refreshPermissions()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            refreshPermissions()
        }
    }

    private func loadSelectedProviderFields() {
        guard let config = selectedProviderConfig else {
            endpoint = ""
            model = ""
            appID = ""
            apiKey = ""
            secretKey = ""
            timeout = 30
            shouldFallbackOnAuthFailure = true
            return
        }

        endpoint = config.endpoint?.absoluteString ?? ""
        model = config.model ?? ""
        appID = config.appID ?? ""
        let secretKeyAccount = "\(config.id.rawValue).secretKey"
        secretKey = (try? keychainService.loadAPIKey(account: secretKeyAccount)) ?? config.secretKey ?? ""
        timeout = config.timeout
        shouldFallbackOnAuthFailure = config.shouldFallbackOnAuthFailure

        if let apiKeyRef = config.apiKeyRef {
            apiKey = (try? keychainService.loadAPIKey(account: apiKeyRef)) ?? ""
        } else {
            apiKey = ""
        }
    }

    private func loadSelectedModelProfileFields() {
        guard let profile = selectedModelProfile else {
            modelProfileName = ""
            modelProfileProviderID = .openAICompatible
            modelProfileModelName = ""
            modelProfilePurpose = .quality
            modelProfilePriority = 10
            modelProfileIsEnabled = true
            return
        }

        modelProfileName = profile.name
        modelProfileProviderID = profile.providerID
        modelProfileModelName = profile.modelName
        modelProfilePurpose = profile.purpose
        modelProfilePriority = profile.priority
        modelProfileIsEnabled = profile.isEnabled
    }

    private func status(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
