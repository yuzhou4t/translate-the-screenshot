import KeyboardShortcuts
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case shortcuts
    case translationService
    case privacy

    var title: String {
        switch self {
        case .general:
            "通用"
        case .shortcuts:
            "快捷键"
        case .translationService:
            "翻译服务"
        case .privacy:
            "权限与隐私"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .shortcuts:
            "keyboard"
        case .translationService:
            "network"
        case .privacy:
            "lock.shield"
        }
    }
}

struct SettingsView: View {
    @StateObject var viewModel: SettingsViewModel

    var body: some View {
        ZStack {
            TTSWindowBackground()

            HStack(spacing: 12) {
                settingsSidebar
                    .frame(width: 172)
                    .ttsGlassSurface(cornerRadius: 18)

                Group {
                    switch viewModel.selectedTab {
                    case .general:
                        generalSettings
                    case .shortcuts:
                        shortcutSettings
                    case .translationService:
                        translationServiceSettings
                    case .privacy:
                        permissionPrivacySettings
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ttsGlassSurface(cornerRadius: 18, elevated: true)
            }
            .padding(14)
        }
        .frame(minWidth: 900, idealWidth: 980, minHeight: 620, idealHeight: 680)
        .tint(TTSVisualStyle.accent)
        .onAppear {
            viewModel.reload()
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "character.textbox")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(
                        LinearGradient(
                            colors: [TTSVisualStyle.accent, TTSVisualStyle.accentStrong],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("TTS 设置")
                        .font(.headline)
                    Text("轻量翻译工具")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Text("设置")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)

            ForEach(
                [SettingsTab.general, .shortcuts, .translationService, .privacy],
                id: \.self
            ) { tab in
                Button {
                    viewModel.selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.systemImage)
                            .frame(width: 18)
                        Text(tab.title)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: viewModel.selectedTab == tab ? .semibold : .medium))
                    .foregroundStyle(viewModel.selectedTab == tab ? TTSVisualStyle.accentStrong : Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(
                        viewModel.selectedTab == tab
                            ? TTSVisualStyle.accent.opacity(0.13)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("菜单栏服务运行中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .background(TTSVisualStyle.raisedSurface.opacity(0.58))
    }

    private var generalSettings: some View {
        SettingsPage(
            title: "通用",
            subtitle: "管理默认翻译方向、模式与核心工作流",
            systemImage: "gearshape"
        ) {
            SettingsSectionCard(title: "基础设置", systemImage: "slider.horizontal.3") {
                SettingsValueRow(title: "默认翻译服务", value: viewModel.defaultProviderID.displayName)
                settingsDivider

                HStack(spacing: 10) {
                    Text("翻译方向")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("翻译方向", selection: $viewModel.translationDirection) {
                        ForEach(TranslationDirection.allCases) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                    Button("保存") { viewModel.saveTranslationDirection() }
                        .buttonStyle(TTSPrimaryButtonStyle())
                }
                settingsDivider

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("默认翻译模式")
                            .font(.subheadline.weight(.medium))
                        Text(viewModel.defaultTranslationMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("默认翻译模式", selection: $viewModel.defaultTranslationMode) {
                        ForEach(TranslationMode.userSelectableCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    Button("保存") { viewModel.saveDefaultTranslationMode() }
                        .buttonStyle(TTSPrimaryButtonStyle())
                }

                statusMessage
            }

            SettingsSectionCard(title: "核心工作流", systemImage: "point.3.connected.trianglepath.dotted") {
                SettingsInfoRow(
                    title: "划词翻译",
                    message: "读取选中文字后直接使用默认服务翻译。",
                    systemImage: "text.cursor"
                )
                SettingsInfoRow(
                    title: "Apple 本地坐标翻译",
                    message: "Option + W 在本机完成 OCR 和坐标分析；macOS 15 及以上使用 Apple 系统翻译，macOS 13–14 使用默认服务兼容翻译。",
                    systemImage: "apple.logo"
                )
                SettingsInfoRow(
                    title: "API 高质量坐标翻译",
                    message: "可单独录制快捷键；坐标留在本机，只把分段文字交给默认翻译服务。",
                    systemImage: "sparkles"
                )
                SettingsInfoRow(
                    title: "服务 fallback",
                    message: "主翻译服务失败时，最多尝试一次全局备用服务，不做场景路由。",
                    systemImage: "arrow.triangle.branch"
                )
            }
        }
    }

    private var translationServiceSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("翻译服务", systemImage: "network")
                    .font(.title3.weight(.semibold))

                Text("\(viewModel.enabledProviderCount) 个已启用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(TTSVisualStyle.accent.opacity(0.11), in: Capsule())

                Spacer()

                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 14) {
                providerList
                    .frame(width: 292)

                providerDetails
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("服务商")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(viewModel.providerConfigs.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    providerGroupTitle("AI 大模型")
                    ForEach(viewModel.aiProviderConfigs) { config in
                        providerRow(config)
                    }
                    providerGroupTitle("传统翻译")
                        .padding(.top, 8)
                    ForEach(viewModel.traditionalProviderConfigs) { config in
                        providerRow(config)
                    }
                }
                .padding(8)
            }
            .background(TTSVisualStyle.raisedSurface.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func providerGroupTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.top, 4)
    }

    private func providerRow(_ config: ProviderConfig) -> some View {
        ProviderConfigRow(
            config: config,
            isDefault: config.id == viewModel.defaultProviderID,
            isImplemented: viewModel.isImplemented(config.id),
            isSelected: config.id == viewModel.selectedProviderID,
            onSelect: {
                viewModel.selectProvider(config.id)
            },
            onToggleEnabled: { isEnabled in
                viewModel.setEnabled(isEnabled, for: config.id)
            }
        )
    }

    @ViewBuilder
    private var providerDetails: some View {
        if let config = viewModel.selectedProviderConfig {
            ScrollView {
                VStack(spacing: 14) {
                    fallbackCard
                    providerConfigurationCard(config)
                    statusMessage
                }
                .padding(.trailing, 4)
            }
        } else {
            Text("请选择一个服务商")
                .foregroundStyle(.secondary)
        }
    }

    private var fallbackCard: some View {
        SettingsSectionCard(title: "备用服务", systemImage: "arrow.triangle.branch") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动 fallback")
                        .font(.subheadline.weight(.medium))
                    Text("主服务失败后最多切换一次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("自动 fallback", isOn: $viewModel.fallbackEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if viewModel.fallbackEnabled {
                settingsDivider

                SettingsControlRow(title: "备用服务商") {
                    Picker("备用服务商", selection: $viewModel.fallbackProviderID) {
                        Text("不使用备用服务")
                            .tag(Optional<TranslationProviderID>.none)
                        ForEach(viewModel.availableFallbackProviderConfigs) { fallbackConfig in
                            Text(fallbackConfig.displayName)
                                .tag(Optional(fallbackConfig.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 190)
                }

                if let fallbackProviderID = viewModel.fallbackProviderID {
                    SettingsField(
                        title: "备用模型",
                        placeholder: "例如 deepseek-ai/DeepSeek-V3.2",
                        text: $viewModel.fallbackModel
                    )
                    ModelSuggestionPicker(
                        title: "备用模型建议",
                        providerID: fallbackProviderID,
                        modelName: $viewModel.fallbackModel
                    )
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Text("不做场景路由或多级重试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存备用设置") {
                    viewModel.saveFallbackSettings()
                }
                .buttonStyle(TTSSecondaryButtonStyle())
            }
        }
    }

    private func providerConfigurationCard(_ config: ProviderConfig) -> some View {
        SettingsSectionCard(title: "当前服务商", systemImage: "server.rack") {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(config.displayName)
                        .font(.headline)
                    HStack(spacing: 6) {
                        StatusPill(
                            text: config.type.displayName,
                            systemImage: "square.stack.3d.up",
                            tint: .secondary
                        )
                        StatusPill(
                            text: viewModel.isImplemented(config.id) ? "已接入" : "待接入",
                            systemImage: viewModel.isImplemented(config.id) ? "checkmark.circle.fill" : "clock",
                            tint: viewModel.isImplemented(config.id) ? .green : .secondary
                        )
                    }
                }
                Spacer()
                if config.id == viewModel.defaultProviderID {
                    StatusPill(text: "默认服务", systemImage: "checkmark.seal.fill", tint: TTSVisualStyle.accent)
                } else {
                    Button("设为默认") {
                        viewModel.setDefaultProvider(config.id)
                    }
                    .buttonStyle(TTSSecondaryButtonStyle())
                }
            }

            settingsDivider

            SettingsField(title: "Endpoint", placeholder: "https://...", text: $viewModel.endpoint)
            SettingsField(
                title: config.id == .volcengine ? "Region" : "模型 / 区域",
                placeholder: config.id == .volcengine ? "cn-north-1" : "模型名称",
                text: $viewModel.model
            )

            ModelSuggestionPicker(
                title: "常用模型",
                providerID: config.id,
                modelName: $viewModel.model
            )

            SettingsField(
                title: config.id == .volcengine ? "AccessKey ID" : "App ID / SecretId / AccessKeyId",
                placeholder: "可选",
                text: $viewModel.appID
            )

            if config.id != .volcengine {
                SettingsSecureField(title: "API Key", placeholder: "保存在 macOS Keychain", text: $viewModel.apiKey)
            }

            SettingsSecureField(
                title: config.id == .volcengine ? "Secret Access Key" : "Secret Key",
                placeholder: "保存在 macOS Keychain",
                text: $viewModel.secretKey
            )

            SettingsControlRow(title: "请求超时") {
                HStack(spacing: 6) {
                    TextField("秒", value: $viewModel.timeout, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 10)
                        .frame(width: 74, height: 32)
                        .ttsTintedControl()
                    Text("秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if config.id == .volcengine {
                settingsDivider
                Text("火山整图翻译只在你从菜单或独立快捷键主动启动时上传完整截图，并固定使用官方接口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsValueRow(title: "图片翻译 Beta 安全计数", value: viewModel.volcengineImageUsageText)
                if viewModel.hasVolcengineUploadConsent {
                    Button("撤销整图自动上传同意") {
                        viewModel.revokeVolcengineUploadConsent()
                    }
                    .buttonStyle(TTSSecondaryButtonStyle())
                }
            }

            HStack {
                Spacer()
                Button("保存当前服务商") {
                    viewModel.saveSelectedProvider()
                }
                .buttonStyle(TTSPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if !viewModel.statusMessage.isEmpty {
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(viewModel.statusIsError ? Color.red : TTSVisualStyle.accentStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(TTSVisualStyle.subtleBorder)
            .frame(height: 1)
    }

    private var shortcutSettings: some View {
        SettingsPage(
            title: "快捷键",
            subtitle: "每条流程保持独立，按你的使用习惯自由调整",
            systemImage: "keyboard"
        ) {
            SettingsSectionCard(title: "全局快捷键", systemImage: "command") {
                KeyboardShortcuts.Recorder("截图到剪贴板", name: .screenshotClipboard)
                settingsDivider
                KeyboardShortcuts.Recorder("划词翻译", name: .translateSelection)
                settingsDivider
                KeyboardShortcuts.Recorder("输入翻译", name: .inputTranslate)
                settingsDivider
                KeyboardShortcuts.Recorder("截图翻译", name: .screenshotTranslate)
                settingsDivider
                KeyboardShortcuts.Recorder("Apple 本地坐标翻译", name: .screenshotTranslateOverlay)
                settingsDivider
                KeyboardShortcuts.Recorder("API 高质量坐标翻译", name: .screenshotTranslateOverlayAPI)
                settingsDivider
                KeyboardShortcuts.Recorder("火山图片翻译 Beta", name: .volcengineImageTranslation)
                settingsDivider
                KeyboardShortcuts.Recorder("截图 OCR", name: .screenshotOCR)
                settingsDivider
                KeyboardShortcuts.Recorder("静默截图 OCR", name: .silentScreenshotOCR)
            }

            SettingsSectionCard(title: "使用说明", systemImage: "info.circle") {
                SettingsInfoRow(
                    title: "全局快捷键",
                    message: "这些快捷键由系统监听，TTS 在菜单栏常驻时即可触发对应操作。",
                    systemImage: "keyboard"
                )
                SettingsInfoRow(
                    title: "截图相关快捷键",
                    message: "默认 Control + A 只在内存中截图、标注并复制；Option + S 显示文字译文；Option + W 使用 Apple 本地坐标翻译。API 高质量和火山图片翻译可分别录制快捷键。",
                    systemImage: "viewfinder"
                )
                SettingsInfoRow(
                    title: "图片文件 OCR",
                    message: "可从菜单栏选择本地图片文件做 OCR，结果同样支持复制、AI 修复和继续翻译。",
                    systemImage: "photo"
                )
            }
        }
    }

    private var permissionPrivacySettings: some View {
        SettingsPage(
            title: "权限与隐私",
            subtitle: "清楚查看本机权限与每条流程的数据边界",
            systemImage: "lock.shield"
        ) {
            SettingsSectionCard(title: "权限状态", systemImage: "checkmark.shield") {
                SettingsPermissionRow(
                    title: "辅助功能",
                    status: viewModel.accessibilityStatus,
                    isGranted: viewModel.isAccessibilityTrusted
                )
                settingsDivider
                SettingsPermissionRow(
                    title: "屏幕录制",
                    status: viewModel.screenRecordingStatus,
                    isGranted: viewModel.isScreenRecordingTrusted
                )
                settingsDivider

                HStack(spacing: 8) {
                    Button("请求辅助功能权限") {
                        viewModel.requestAccessibility()
                    }
                    .buttonStyle(TTSSecondaryButtonStyle())

                    Button("请求屏幕录制权限") {
                        viewModel.requestScreenRecording()
                    }
                    .buttonStyle(TTSSecondaryButtonStyle())

                    Button("刷新状态") {
                        viewModel.refreshPermissions()
                    }
                    .buttonStyle(TTSPrimaryButtonStyle())
                }
            }

            SettingsSectionCard(title: "隐私说明", systemImage: "hand.raised") {
                SettingsInfoRow(
                    title: "截图 OCR",
                    message: "截图 OCR 与 Option + S 先在本机使用 Apple Vision；Option + S 再把识别文字交给启用的翻译服务。",
                    systemImage: "viewfinder"
                )
                SettingsInfoRow(
                    title: "Apple 本地坐标翻译",
                    message: "Option + W 在 macOS 15 及以上使用 Apple 系统翻译，不把 OCR 文字发送给已配置的第三方服务；系统可能按需下载语言包。macOS 13–14 使用默认服务兼容翻译。",
                    systemImage: "apple.logo"
                )
                SettingsInfoRow(
                    title: "API 高质量坐标翻译",
                    message: "截图像素与坐标留在本机，只向默认翻译服务发送 OCR 分段文字和必要的段落结构信息。",
                    systemImage: "sparkles"
                )
                SettingsInfoRow(
                    title: "火山图片翻译 Beta",
                    message: "从菜单或已配置的独立快捷键主动启动时会上传完整框选截图；首次使用会询问一次。",
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
        .onAppear {
            viewModel.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
    }
}

private struct SettingsPage<Content: View>: View {
    var title: String
    var subtitle: String
    var systemImage: String
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(TTSVisualStyle.accentStrong)
                        .frame(width: 36, height: 36)
                        .background(TTSVisualStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)

                content
            }
            .padding(20)
        }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TTSVisualStyle.accentStrong)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TTSVisualStyle.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
        }
    }
}

private struct SettingsValueRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsControlRow<Control: View>: View {
    var title: String
    @ViewBuilder var control: Control

    init(title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            control
        }
    }
}

private struct SettingsField: View {
    var title: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .ttsTintedControl()
        }
    }
}

private struct SettingsSecureField: View {
    var title: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .ttsTintedControl()
        }
    }
}

private struct SettingsPermissionRow: View {
    var title: String
    var status: String
    var isGranted: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Label(status, systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isGranted ? Color.green : Color.orange)
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
                .foregroundStyle(TTSVisualStyle.accentStrong)
                .frame(width: 28, height: 28)
                .background(TTSVisualStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
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
            SettingsControlRow(title: title) {
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
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
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
    var isSelected: Bool
    var onSelect: () -> Void
    var onToggleEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: providerSystemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? TTSVisualStyle.accentStrong : Color.secondary)
                .frame(width: 30, height: 30)
                .background(
                    isSelected ? TTSVisualStyle.accent.opacity(0.14) : TTSVisualStyle.controlSurface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(config.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(isImplemented ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(isImplemented ? "已接入" : "待接入")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if isDefault {
                        Text("默认")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TTSVisualStyle.accentStrong)
                    }
                }
            }

            Spacer()

            if isDefault {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(TTSVisualStyle.accent)
                    .help("默认服务保持启用")
            } else {
                Toggle("启用", isOn: Binding(
                    get: { config.isEnabled },
                    set: { onToggleEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(.horizontal, 9)
        .frame(height: 56)
        .background(
            isSelected ? TTSVisualStyle.accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isSelected ? TTSVisualStyle.accent.opacity(0.46) : Color.clear, lineWidth: 1)
        )
    }

    private var providerSystemImage: String {
        switch config.type {
        case .openAICompatible, .glm4Flash, .siliconFlow, .deepSeek, .gemini:
            "sparkles"
        default:
            "globe.asia.australia"
        }
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
    private let permissionManager: PermissionManager
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
        policyStore: VolcengineImageTranslationPolicyStore,
        permissionManager: PermissionManager
    ) {
        self.configurationStore = configurationStore
        self.keychainService = keychainService
        self.providerRegistry = providerRegistry
        self.policyStore = policyStore
        self.permissionManager = permissionManager
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
        guard !fallbackEnabled || fallbackProviderID != nil else {
            status("请先选择备用服务商。", isError: true)
            return
        }
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

    func revokeVolcengineUploadConsent() {
        policyStore.revokeUploadConsent()
        reload()
        status("已撤销自动上传同意；下次从菜单或快捷键启动火山图片翻译时会重新询问。", isError: false)
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
