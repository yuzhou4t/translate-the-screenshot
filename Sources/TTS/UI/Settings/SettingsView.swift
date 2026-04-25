import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @StateObject var viewModel: SettingsViewModel

    var body: some View {
        TabView {
            providerSettings
                .tabItem {
                    Label("服务", systemImage: "network")
                }

            shortcutSettings
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }

            permissionSettings
                .tabItem {
                    Label("权限", systemImage: "lock.shield")
                }
        }
        .frame(minWidth: 900, idealWidth: 940, minHeight: 620, idealHeight: 660)
        .background(.background)
    }

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("翻译服务", systemImage: "network")
                    .font(.headline)

                TextField("目标语言", text: $viewModel.targetLanguage)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Button("保存目标语言") {
                    viewModel.saveTargetLanguage()
                }

                Spacer()

                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
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
        .onAppear {
            viewModel.reload()
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
                ForEach(viewModel.providerConfigs) { config in
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
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
        .background(.background)
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
            KeyboardShortcuts.Recorder("划词翻译", name: .translateSelection)
            KeyboardShortcuts.Recorder("截图翻译", name: .screenshotTranslate)
            KeyboardShortcuts.Recorder("输入翻译", name: .inputTranslate)
            KeyboardShortcuts.Recorder("截图 OCR", name: .screenshotOCR)
            KeyboardShortcuts.Recorder("静默截图 OCR", name: .silentScreenshotOCR)
        }
        .padding()
    }

    private var permissionSettings: some View {
        Form {
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

            Text("如果已经授权但这里仍显示未授权，请完全退出并重新打开 /Applications/TTS.app。macOS 会按具体 app 路径记录权限。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .onAppear {
            viewModel.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
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
    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var isAccessibilityTrusted = false
    @Published var isScreenRecordingTrusted = false

    private let configurationStore: AppConfigurationStore
    private let keychainService: KeychainService
    private let providerRegistry: ProviderRegistry
    private let permissionManager = AppServices.shared.permissionManager

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
        reload()
        refreshPermissions()
    }

    var selectedProviderConfig: ProviderConfig? {
        guard let selectedProviderID else {
            return nil
        }
        return providerConfigs.first { $0.id == selectedProviderID }
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

    func setPriority(_ priority: Int, for id: TranslationProviderID) {
        guard var config = providerConfigs.first(where: { $0.id == id }) else {
            return
        }
        config.priority = priority
        configurationStore.updateProviderConfig(config)
        reload()
    }

    func saveTargetLanguage() {
        configurationStore.update { configuration in
            configuration.targetLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        status("目标语言已保存。", isError: false)
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

    private func status(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
