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
                    message: "当前服务失败时，可按设置尝试一个备用服务，不做复杂路由。",
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
            }
        )
        .tag(config.id)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var providerDetails: some View {
        if let config = viewModel.selectedProviderConfig {
            Form {
                Section("Fallback") {
                    Toggle("自动 fallback", isOn: $viewModel.fallbackEnabled)

                    Picker("备用服务商", selection: $viewModel.fallbackProviderID) {
                        Text("不使用备用服务")
                            .tag(Optional<TranslationProviderID>.none)

                        ForEach(viewModel.availableFallbackProviderConfigs) { fallbackConfig in
                            Text(fallbackConfig.displayName)
                                .tag(Optional(fallbackConfig.id))
                        }
                    }
                    .disabled(!viewModel.fallbackEnabled)

                    if let fallbackProviderID = viewModel.fallbackProviderID {
                        TextField("备用模型", text: $viewModel.fallbackModel)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!viewModel.fallbackEnabled)

                        ModelSuggestionPicker(
                            title: "备用模型建议",
                            providerID: fallbackProviderID,
                            modelName: $viewModel.fallbackModel
                        )
                    }

                    Button("保存 fallback 设置") {
                        viewModel.saveFallbackSettings()
                    }
                    .disabled(!viewModel.fallbackEnabled && viewModel.fallbackProviderID == nil && viewModel.fallbackModel.isEmpty)

                    Text("默认先使用当前服务和模型；请求失败后最多重试 3 次，其中超时可重试一次，再尝试备用服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("当前服务商") {
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

                    ModelSuggestionPicker(
                        title: "常用模型",
                        providerID: config.id,
                        modelName: $viewModel.model
                    )

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

                    Button("保存当前服务商配置") {
                        viewModel.saveSelectedProvider()
                    }
                    .keyboardShortcut(.defaultAction)
                }
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
                KeyboardShortcuts.Recorder("截图翻译覆盖", name: .screenshotTranslateOverlay)
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
                    message: "截图翻译会先 OCR 再翻译；截图翻译覆盖会生成覆盖预览图；截图 OCR 只显示识别文本；静默截图 OCR 会直接复制识别结果。",
                    systemImage: "viewfinder"
                )
                SettingsInfoRow(
                    title: "图片文件 OCR",
                    message: "可从菜单栏选择本地图片文件做 OCR，结果同样支持复制、AI 修复和继续翻译。",
                    systemImage: "photo"
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
                    title: "图片文件 OCR",
                    message: "从本地图片文件读取内容做 OCR，不需要屏幕录制权限。",
                    systemImage: "photo"
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

private struct ModelSuggestionPicker: View {
    var title: String
    var providerID: TranslationProviderID
    @Binding var modelName: String

    private var suggestions: [ModelSuggestion] {
        providerID.suggestedModels
    }

    var body: some View {
        if !suggestions.isEmpty {
            Picker(title, selection: selection) {
                if isCustomModel {
                    Text("自定义：\(modelName)")
                        .tag(modelName)
                }

                ForEach(suggestions) { model in
                    Text(model.label)
                        .tag(model.value)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                if suggestions.contains(where: { $0.value == modelName }) {
                    return modelName
                }
                return modelName.isEmpty ? suggestions[0].value : modelName
            },
            set: { nextModel in
                modelName = nextModel
            }
        )
    }

    private var isCustomModel: Bool {
        !modelName.isEmpty && !suggestions.contains(where: { $0.value == modelName })
    }
}

private struct ProviderConfigRow: View {
    var config: ProviderConfig
    var isDefault: Bool
    var isImplemented: Bool
    var onSelect: () -> Void
    var onToggleEnabled: (Bool) -> Void
    var onSetDefault: () -> Void

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
                Button("设为默认") {
                    onSetDefault()
                }
                .disabled(isDefault)

                Spacer()
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
    @Published var fallbackEnabled = false
    @Published var fallbackProviderID: TranslationProviderID?
    @Published var fallbackModel = ""
    @Published var targetLanguage: String
    @Published var translationDirection: TranslationDirection
    @Published var defaultTranslationMode: TranslationMode
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
        .siliconFlow,
        .deepSeek,
        .gemini
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

    var enabledProviderCount: Int {
        providerConfigs.filter(\.isEnabled).count
    }

    var availableFallbackProviderConfigs: [ProviderConfig] {
        providerConfigs.filter {
            $0.id != defaultProviderID &&
            $0.id.isTranslationProvider &&
            isImplemented($0.id)
        }
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
        fallbackEnabled = configurationStore.fallbackEnabled
        fallbackProviderID = configurationStore.fallbackProviderID
        fallbackModel = configurationStore.fallbackModel ?? ""
        targetLanguage = configurationStore.targetLanguage
        translationDirection = configurationStore.translationDirection
        defaultTranslationMode = configurationStore.defaultTranslationMode

        if fallbackProviderID == defaultProviderID {
            fallbackProviderID = nil
        }

        if selectedProviderID == nil || selectedProviderConfig == nil {
            selectedProviderID = defaultProviderID
        }

        loadSelectedProviderFields()
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

    func saveFallbackSettings() {
        let providerID = fallbackEnabled ? fallbackProviderID : nil
        configurationStore.setFallbackConfiguration(
            enabled: fallbackEnabled,
            providerID: providerID,
            model: fallbackEnabled ? fallbackModel : nil
        )
        reload()
        status("fallback 设置已保存。", isError: false)
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
            return
        }

        endpoint = config.endpoint?.absoluteString ?? ""
        model = config.model ?? ""
        appID = config.appID ?? ""
        let secretKeyAccount = "\(config.id.rawValue).secretKey"
        secretKey = (try? keychainService.loadAPIKey(account: secretKeyAccount)) ?? config.secretKey ?? ""
        timeout = config.timeout

        if let apiKeyRef = config.apiKeyRef {
            apiKey = (try? keychainService.loadAPIKey(account: apiKeyRef)) ?? ""
        } else {
            apiKey = ""
        }
    }

    private func status(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
