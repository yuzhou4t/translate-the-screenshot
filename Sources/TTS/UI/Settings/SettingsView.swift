import KeyboardShortcuts
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case shortcuts
    case translationService
    case scenarios
    case aiMode
    case privacy
}

struct SettingsView: View {
    @StateObject var viewModel: SettingsViewModel

    var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            generalSettings
                .tag(SettingsTab.general)
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            shortcutSettings
                .tag(SettingsTab.shortcuts)
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }

            translationServiceSettings
                .tag(SettingsTab.translationService)
                .tabItem {
                    Label("翻译服务", systemImage: "network")
                }

            scenarioTranslationSettings
                .tag(SettingsTab.scenarios)
                .tabItem {
                    Label("场景配置", systemImage: "square.grid.2x2")
                }

            aiModeSettings
                .tag(SettingsTab.aiMode)
                .tabItem {
                    Label("AI 模式", systemImage: "sparkles")
                }

            permissionPrivacySettings
                .tag(SettingsTab.privacy)
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
                    title: "火山图片翻译 Beta",
                    message: "Option + W 截图后直接上传整张图片给火山翻译并返回译图；本地坐标翻译保留为手动备用。",
                    systemImage: "cloud"
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

                    TextField(
                        config.id == .volcengine ? "Region（默认 cn-north-1）" : "模型 / 区域",
                        text: $viewModel.model
                    )
                        .textFieldStyle(.roundedBorder)

                    ModelSuggestionPicker(
                        title: "常用模型",
                        providerID: config.id,
                        modelName: $viewModel.model
                    )

                    TextField(
                        config.id == .volcengine ? "AccessKey ID" : "App ID / SecretId / AccessKeyId",
                        text: $viewModel.appID
                    )
                        .textFieldStyle(.roundedBorder)

                    if config.id != .volcengine {
                        SecureField("API Key", text: $viewModel.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    SecureField(
                        config.id == .volcengine ? "Secret Access Key" : "Secret Key",
                        text: $viewModel.secretKey
                    )
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("超时")
                        TextField("秒", value: $viewModel.timeout, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }

                    if config.id == .volcengine {
                        Divider()

                        Text("安全说明：上面的 Endpoint 只用于火山文字翻译；Option + W 的完整截图固定发送到 https://translate.volcengineapi.com，不能改为其他域名。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        LabeledContent("图片翻译 Beta 安全计数") {
                            Text(viewModel.volcengineImageUsageText)
                                .monospacedDigit()
                        }

                        Text("Option + W 会直接上传完整截图到火山图片翻译。提交前会查询火山账号当月图片用量，并与本机计数取较大值；达到免费 100 张后阻止。请求一旦发出，即使失败或超时也不会返还本机计数。用量查询失败时会停止，不冒险继续提交。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if viewModel.hasVolcengineUploadConsent {
                            Button("撤销 Option + W 自动上传同意") {
                                viewModel.revokeVolcengineUploadConsent()
                            }
                        } else {
                            Text("首次按 Option + W 时会说明上传范围，并只询问一次。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                KeyboardShortcuts.Recorder("火山图片翻译 Beta", name: .screenshotTranslateOverlay)
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
                    message: "Option + S 截图翻译会在文字悬浮窗中显示译文；Option + W 会直接上传整张截图并显示火山返回的译图。本地坐标覆盖可从菜单或结果窗口手动使用。",
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

    private var scenarioTranslationSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Label("场景翻译配置", systemImage: "square.grid.2x2")
                        .font(.headline)

                    Spacer()

                    Button("保存场景配置") {
                        viewModel.saveScenarioTranslationConfigs()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text("为不同文字功能指定主要翻译服务和可选备用服务。Option + W 的火山整图翻译固定使用火山 AK/SK；本地坐标备用仍使用本地 OCR 与本地语义分块。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                }

                VStack(spacing: 14) {
                    ForEach($viewModel.scenarioTranslationConfigs) { $config in
                        ScenarioTranslationConfigCard(
                            config: $config,
                            availableProviders: viewModel.availableScenarioProviderConfigs
                        )
                    }
                }
            }
            .padding()
        }
        .background(.background)
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
                    message: "截图 OCR 与 Option + S 先在本机使用 Apple Vision；Option + S 再把识别文字交给启用的翻译服务。",
                    systemImage: "viewfinder"
                )
                SettingsInfoRow(
                    title: "火山图片翻译 Beta",
                    message: "Option + W 会把完整框选截图上传到火山引擎。首次只询问一次；云端失败不会静默切换本地。",
                    systemImage: "cloud"
                )
                SettingsInfoRow(
                    title: "图片文件 OCR",
                    message: "从本地图片文件读取内容做 OCR，不需要屏幕录制权限。",
                    systemImage: "photo"
                )
                SettingsInfoRow(
                    title: "API Key",
                    message: "API Key、AccessKey Secret 等凭据只保存在 macOS Keychain；旧版 UserDefaults 明文缓存会在首次读取时迁移并删除。",
                    systemImage: "key"
                )

                Text("如果已经授权但这里仍显示未授权，请完全退出并重新打开 /Applications/TTS.app。macOS 会按 app 路径、Bundle ID 和签名身份记录权限。")
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

private struct ScenarioTranslationConfigCard: View {
    @Binding var config: SimpleScenarioTranslationConfig
    var availableProviders: [ProviderConfig]

    private var scenario: TranslationScenario {
        config.scenario
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: {
                if config.providerID.isEmpty {
                    return availableProviders.first?.id.rawValue ?? ""
                }
                return config.providerID
            },
            set: { config.providerID = $0 }
        )
    }

    private var fallbackProviderSelection: Binding<String> {
        Binding(
            get: { config.fallbackProviderID },
            set: { config.fallbackProviderID = $0 }
        )
    }

    private var selectedPrimaryProviderID: TranslationProviderID? {
        TranslationProviderID(rawValue: config.providerID)
    }

    private var selectedFallbackProviderID: TranslationProviderID? {
        TranslationProviderID(rawValue: config.fallbackProviderID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(scenario.displayName)
                    .font(.headline)

                Text(scenario.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("使用全局默认配置", isOn: $config.useGlobalDefault)

            if config.useGlobalDefault {
                Text("此场景将使用翻译服务页中的默认配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("主要服务商", selection: providerSelection) {
                        ForEach(availableProviders) { provider in
                            Text(provider.displayName)
                                .tag(provider.id.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("主要模型", text: $config.modelName)
                        .textFieldStyle(.roundedBorder)

                    if let selectedPrimaryProviderID {
                        ModelSuggestionPicker(
                            title: "主要模型建议",
                            providerID: selectedPrimaryProviderID,
                            modelName: $config.modelName
                        )
                    }

                    Toggle("启用备用服务", isOn: $config.fallbackEnabled)

                    if config.fallbackEnabled {
                        Picker("备用服务商", selection: fallbackProviderSelection) {
                            Text("未选择")
                                .tag("")

                            ForEach(availableProviders) { provider in
                                Text(provider.displayName)
                                    .tag(provider.id.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        TextField("备用模型", text: $config.fallbackModelName)
                            .textFieldStyle(.roundedBorder)

                        if let selectedFallbackProviderID {
                            ModelSuggestionPicker(
                                title: "备用模型建议",
                                providerID: selectedFallbackProviderID,
                                modelName: $config.fallbackModelName
                            )
                        }
                    }
                }
            }

            if scenario == .ocrCleanup {
                hintRow(
                    "该场景需要支持 Prompt 的 AI 模型，不适合传统翻译 API。",
                    systemImage: "sparkles.rectangle.stack"
                )
            }

            if scenario == .imageOverlay {
                hintRow(
                    "建议选择输出稳定、译文简洁的 AI 模型。",
                    systemImage: "text.below.photo"
                )
            }

            Text("默认翻译模式：\(scenario.defaultTranslationMode.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func hintRow(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 1)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    @Published var selectedTab: SettingsTab = .general
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
    @Published var enableVisionSegmentation = false
    @Published var visionSegmentationProviderID: TranslationProviderID
    @Published var visionSegmentationEndpoint = ""
    @Published var visionSegmentationModel = ""
    @Published var visionSegmentationAPIKey = ""
    @Published var scenarioTranslationConfigs: [SimpleScenarioTranslationConfig] = []
    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var isAccessibilityTrusted = false
    @Published var isScreenRecordingTrusted = false
    @Published var volcengineImageUsageText = ""
    @Published var hasVolcengineUploadConsent = false

    private let configurationStore: AppConfigurationStore
    private let keychainService: KeychainService
    private let providerRegistry: ProviderRegistry
    private let policyStore: VolcengineImageTranslationPolicyStore
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
        providerRegistry: ProviderRegistry,
        policyStore: VolcengineImageTranslationPolicyStore
    ) {
        self.configurationStore = configurationStore
        self.keychainService = keychainService
        self.providerRegistry = providerRegistry
        self.policyStore = policyStore
        defaultProviderID = configurationStore.defaultProviderID
        targetLanguage = configurationStore.targetLanguage
        translationDirection = configurationStore.translationDirection
        defaultTranslationMode = configurationStore.defaultTranslationMode
        enableVisionSegmentation = configurationStore.enableVisionSegmentation
        visionSegmentationProviderID = configurationStore.visionSegmentationConfig.providerID
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

    var availableScenarioProviderConfigs: [ProviderConfig] {
        providerConfigs.filter {
            $0.id.isTranslationProvider &&
            isImplemented($0.id)
        }
    }

    var visionSegmentationProviderIDs: [TranslationProviderID] {
        [.openAICompatible, .gemini]
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
        enableVisionSegmentation = configurationStore.enableVisionSegmentation
        let visionConfig = configurationStore.visionSegmentationConfig
        visionSegmentationProviderID = visionConfig.providerID
        visionSegmentationEndpoint = visionConfig.endpoint?.absoluteString ?? ""
        visionSegmentationModel = visionConfig.model
        visionSegmentationAPIKey = loadVisionSegmentationAPIKey(for: visionConfig.providerID)
        scenarioTranslationConfigs = configurationStore.scenarioTranslationConfigs
        let volcengineUsage = policyStore.snapshot
        volcengineImageUsageText = "\(volcengineUsage.submittedCount)/\(volcengineUsage.limit)"
        hasVolcengineUploadConsent = policyStore.hasUploadConsent

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

    func saveScenarioTranslationConfigs() {
        configurationStore.setEnableVisionSegmentation(false)
        configurationStore.setScenarioTranslationConfigs(
            scenarioTranslationConfigs.map { config in
                var next = config
                if next.useGlobalDefault {
                    next.fallbackEnabled = false
                    next.fallbackProviderID = ""
                    next.fallbackModelName = ""
                } else if !next.fallbackEnabled {
                    next.fallbackProviderID = ""
                    next.fallbackModelName = ""
                }
                return next
            }
        )
        reload()
        status("场景配置已保存。", isError: false)
    }

    func selectVisionSegmentationProvider(_ id: TranslationProviderID) {
        let currentDefaults = VisionSegmentationConfig.defaultConfig(for: visionSegmentationProviderID)
        let nextDefaults = VisionSegmentationConfig.defaultConfig(for: id)
        let currentEndpoint = visionSegmentationEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentModel = visionSegmentationModel.trimmingCharacters(in: .whitespacesAndNewlines)

        visionSegmentationProviderID = id

        if currentEndpoint.isEmpty || currentEndpoint == currentDefaults.endpoint?.absoluteString ?? "" {
            visionSegmentationEndpoint = nextDefaults.endpoint?.absoluteString ?? ""
        }

        if currentModel.isEmpty || currentModel == currentDefaults.model {
            visionSegmentationModel = nextDefaults.model
        }

        visionSegmentationAPIKey = loadVisionSegmentationAPIKey(for: id)
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

    func revokeVolcengineUploadConsent() {
        policyStore.revokeUploadConsent()
        reload()
        status("已撤销自动上传同意；下次 Option + W 会重新询问。", isError: false)
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

    private func visionSegmentationAPIKeyAccount(for id: TranslationProviderID) -> String {
        "vision-segmentation.\(id.rawValue).apiKey"
    }

    private func loadVisionSegmentationAPIKey(for id: TranslationProviderID) -> String {
        (try? keychainService.loadAPIKey(account: visionSegmentationAPIKeyAccount(for: id))) ?? ""
    }
}
