import SwiftUI

struct AIUsagePopoverView: View {
    @ObservedObject var usageStore: AIUsageStore
    @ObservedObject var tokenStore: AIUsageTokenStore
    @ObservedObject var settingsStore: AIUsageSettingsStore
    @ObservedObject var codexAccountSwitcherStore: CodexAccountSwitcherStore
    @ObservedObject var screenRecordingController: ScreenRecordingController
    var onQuickAction: (MenuQuickActionID) -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    var forceReduceTransparency: Bool? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selectedProviderID: AIUsageProviderID?

    var body: some View {
        ZStack {
            glassBackground

            if let selectedProviderID {
                AIUsageProviderDetailView(
                    providerID: selectedProviderID,
                    state: usageStore.states[selectedProviderID] ?? .empty,
                    tokenStore: tokenStore,
                    codexAccountSwitcherStore: codexAccountSwitcherStore,
                    onBack: { navigate(to: nil) },
                    onRefresh: { usageStore.refreshNow() }
                )
                .transition(detailTransition)
            } else {
                overview
                    .transition(detailTransition)
            }
        }
        .frame(width: 420, height: 540)
        .clipped()
        .tint(TTSVisualStyle.accent)
    }

    @ViewBuilder
    private var glassBackground: some View {
        if forceReduceTransparency ?? reduceTransparency {
            TTSWindowBackground()
        } else {
            TTSVisualEffectBackground()
                .ignoresSafeArea()
            TTSWindowBackground()
                .opacity(0.24)
            LinearGradient(
                colors: [TTSVisualStyle.glassHighlight.opacity(0.42), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            overviewHeader

            if screenRecordingController.isBlockingOtherCapture {
                recordingStatusCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            VStack(alignment: .leading, spacing: 7) {
                sectionTitle("订阅额度", systemImage: "chart.bar.xaxis")

                if settingsStore.visibleProviderIDs.isEmpty {
                    emptyProviderState
                } else {
                    VStack(spacing: 6) {
                        ForEach(settingsStore.visibleProviderIDs) { providerID in
                            AIUsageProviderRow(
                                providerID: providerID,
                                state: usageStore.states[providerID] ?? .empty,
                                action: { navigate(to: providerID) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 7)

            quickActions
            footer
        }
    }

    private var recordingStatusCard: some View {
        HStack(spacing: 10) {
            Image(systemName: recordingStatusIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(recordingStatusColor)
                .frame(width: 32, height: 32)
                .background(recordingStatusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(screenRecordingController.statusTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if screenRecordingController.state.elapsed > 0 {
                    Text(screenRecordingController.formattedElapsed)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            switch screenRecordingController.state {
            case .recording:
                recordingButton("暂停", image: "pause.fill") {
                    screenRecordingController.pause()
                }
                recordingButton("停止", image: "stop.fill", tint: .red) {
                    screenRecordingController.stopAndSave()
                }
            case .paused:
                recordingButton("继续", image: "play.fill") {
                    screenRecordingController.resume()
                }
                recordingButton("停止", image: "stop.fill", tint: .red) {
                    screenRecordingController.stopAndSave()
                }
            case .selecting, .countdown:
                recordingButton("取消", image: "xmark") {
                    screenRecordingController.cancelSelectionOrCountdown()
                }
            case .finalizing:
                ProgressView().controlSize(.small)
            case .idle, .completed, .failed:
                EmptyView()
            }

            if screenRecordingController.state.isRecordingSession,
               screenRecordingController.state != .finalizing {
                recordingButton("取消录制", image: "trash", tint: .secondary) {
                    screenRecordingController.cancelRecording()
                }
            }
        }
        .padding(10)
        .background(TTSVisualStyle.controlSurface.opacity(0.76), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(recordingStatusColor.opacity(0.25), lineWidth: 1)
        }
        .disabled(screenRecordingController.isTransitioning)
    }

    private var recordingStatusIcon: String {
        switch screenRecordingController.state {
        case .paused: "pause.circle.fill"
        case .finalizing: "arrow.down.circle.fill"
        case .selecting, .countdown: "viewfinder.circle"
        case .recording: "record.circle.fill"
        case .idle, .completed, .failed: "record.circle"
        }
    }

    private var recordingStatusColor: Color {
        switch screenRecordingController.state {
        case .paused: .orange
        case .recording: .red
        case .idle, .selecting, .countdown, .finalizing, .completed, .failed: TTSVisualStyle.accentStrong
        }
    }

    private func recordingButton(
        _ title: String,
        image: String,
        tint: Color = TTSVisualStyle.accentStrong,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .foregroundStyle(tint)
                .frame(width: 27, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .help(title)
        .accessibilityLabel(title)
    }

    private var overviewHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "gauge")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(
                        LinearGradient(
                            colors: [TTSVisualStyle.accent, TTSVisualStyle.accentStrong],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("AI 额度")
                        .font(.system(size: 16, weight: .semibold))
                    Text(updateText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    usageStore.refreshNow()
                } label: {
                    Group {
                        if usageStore.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ttsTintedControl(cornerRadius: 10)
                .help("立即刷新订阅额度")
                .accessibilityLabel("立即刷新订阅额度")
                .disabled(usageStore.isRefreshing)
            }

            HStack(spacing: 6) {
                AIUsageSummaryPill(
                    title: "正常 \(usageStore.normalCount)",
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
                AIUsageSummaryPill(
                    title: "需关注 \(usageStore.attentionCount)",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
                AIUsageSummaryPill(
                    title: "未配置 \(usageStore.unconfiguredCount)",
                    systemImage: "gearshape.fill",
                    tint: .secondary
                )
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var emptyProviderState: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 9) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(TTSVisualStyle.accentStrong)
                VStack(alignment: .leading, spacing: 1) {
                    Text("选择要显示的服务商")
                        .font(.subheadline.weight(.semibold))
                    Text("在设置中启用并调整顺序")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(11)
            .frame(maxWidth: .infinity)
            .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("快捷操作", systemImage: "bolt.fill")

            if settingsStore.visibleQuickActionIDs.isEmpty {
                Text("可在设置中选择翻译与 OCR 操作。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(settingsStore.visibleQuickActionIDs.prefix(4))) { action in
                        compactActionButton(action)
                    }

                    if settingsStore.visibleQuickActionIDs.count > 4 {
                        Menu {
                            ForEach(Array(settingsStore.visibleQuickActionIDs.dropFirst(4))) { action in
                                Button {
                                    onQuickAction(action)
                                } label: {
                                    Label(action.displayName, systemImage: action.systemImage)
                                }
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("更多")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(TTSVisualStyle.accentStrong)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .frame(maxWidth: .infinity)
                        .background(TTSVisualStyle.controlSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func compactActionButton(_ action: MenuQuickActionID) -> some View {
        Button {
            onQuickAction(action)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(action.shortDisplayName)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(TTSVisualStyle.accentStrong)
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(TTSVisualStyle.controlSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
        }
        .help(action.displayName)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onOpenSettings) {
                Label("设置", systemImage: "gearshape")
                    .frame(minHeight: 30)
            }
            .buttonStyle(TTSSecondaryButtonStyle())

            Spacer()

            Button(action: onQuit) {
                Label("退出 TTS", systemImage: "power")
                    .frame(minHeight: 30)
            }
            .buttonStyle(TTSSecondaryButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TTSVisualStyle.glassOverlay.opacity(0.84))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TTSVisualStyle.subtleBorder)
                .frame(height: 1)
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }

    private var updateText: String {
        guard let latestUpdate = usageStore.latestUpdate else {
            return usageStore.isRefreshing ? "正在读取额度…" : "尚未刷新"
        }
        return "更新于 \(latestUpdate.formatted(date: .omitted, time: .shortened))"
    }

    private var detailTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: selectedProviderID == nil ? .leading : .trailing).combined(with: .opacity),
            removal: .opacity
        )
    }

    private func navigate(to providerID: AIUsageProviderID?) {
        if reduceMotion {
            selectedProviderID = providerID
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedProviderID = providerID
            }
        }
    }
}

private struct AIUsageSummaryPill: View {
    var title: String
    var systemImage: String
    var tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.11), in: Capsule())
    }
}

private struct AIUsageProviderRow: View {
    var providerID: AIUsageProviderID
    var state: AIUsageProviderViewState
    var action: () -> Void

    private let metricColumns = [
        GridItem(.flexible(), spacing: 5, alignment: .leading),
        GridItem(.flexible(), spacing: 5, alignment: .leading),
    ]

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AIUsageProviderBrandIcon(providerID: providerID, size: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(providerID.displayName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        AIUsageCompactStateLabel(state: state)
                        if let plan = state.snapshot?.planName, !plan.isEmpty {
                            Text(plan)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(width: 122, alignment: .leading)

                Spacer(minLength: 0)

                if let snapshot = state.snapshot {
                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 4) {
                        ForEach(Array(snapshot.metrics.enumerated()), id: \.offset) { _, metric in
                            AIUsageMetricChip(metric: metric)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } else if state.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(state.failure?.message ?? "等待刷新")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.68))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(Rectangle())
            .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [TTSVisualStyle.glassHighlight, TTSVisualStyle.subtleBorder],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开额度和本地 Token 详情")
    }
}

private struct AIUsageMetricChip: View {
    var metric: AIUsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.label)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(metric.primaryText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(metric.needsAttention ? Color.orange : TTSVisualStyle.accentStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let fraction = metric.remainingFraction {
                AIUsageRemainingBar(fraction: fraction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct AIUsageRemainingBar: View {
    var fraction: Double
    var height: CGFloat = 3

    private var clampedFraction: Double {
        min(max(fraction, 0), 1)
    }

    private var tint: Color {
        if clampedFraction <= 0.05 { return .red }
        if clampedFraction <= 0.20 { return .orange }
        return TTSVisualStyle.accentStrong
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.76), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * clampedFraction)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct AIUsageCompactStateLabel: View {
    var state: AIUsageProviderViewState

    var body: some View {
        let presentation = state.presentation
        Label(presentation.text, systemImage: presentation.systemImage)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(presentation.tint)
            .lineLimit(1)
    }
}

struct AIUsageProviderDetailView: View {
    var providerID: AIUsageProviderID
    var state: AIUsageProviderViewState
    @ObservedObject var tokenStore: AIUsageTokenStore
    @ObservedObject var codexAccountSwitcherStore: CodexAccountSwitcherStore
    var onBack: () -> Void
    var onRefresh: () -> Void

    @State private var selectedPeriod: AIUsageTokenPeriod = .day
    @State private var pendingAccount: CodexAccountProfile?

    var body: some View {
        VStack(spacing: 0) {
            detailHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if providerID == .codex {
                        codexAccountSection
                    }
                    quotaSection
                    tokenSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
        .confirmationDialog(
            pendingAccount.map { "切换到 \($0.displayName)？" } ?? "切换 Codex 账号",
            isPresented: Binding(
                get: { pendingAccount != nil },
                set: { if !$0 { pendingAccount = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let account = pendingAccount {
                Button("切换并重新打开 Codex") {
                    pendingAccount = nil
                    codexAccountSwitcherStore.switchAccount(to: account.id)
                }
                Button("取消", role: .cancel) {
                    pendingAccount = nil
                }
            }
        } message: {
            Text("TTS 会先在线校验并切换 Codex 登录，然后打开本地 Codex。如果保存的登录已失效，浏览器会打开，请选择这里显示的同名账号完成登录。ChatGPT / 工作的桌面账号是独立登录，不会随之切换；TTS 会继续运行。")
        }
    }

    private var codexAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Codex 账号", systemImage: "person.2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if codexAccountSwitcherStore.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("共用任务与项目")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }

            if codexAccountSwitcherStore.accounts.isEmpty {
                Text(codexAccountSwitcherStore.statusMessage ?? "尚未找到已登记的 Codex 账号。")
                    .font(.caption2)
                    .foregroundStyle(codexAccountSwitcherStore.statusIsError ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(codexAccountSwitcherStore.accounts.enumerated()), id: \.element.id) { index, account in
                        codexAccountRow(account)
                        if index < codexAccountSwitcherStore.accounts.count - 1 {
                            Divider().opacity(0.55)
                        }
                    }
                }
                .padding(.horizontal, 11)
                .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
                }
            }

            if let message = codexAccountSwitcherStore.statusMessage,
               !codexAccountSwitcherStore.accounts.isEmpty {
                Label(
                    message,
                    systemImage: codexAccountSwitcherStore.statusIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption2)
                .foregroundStyle(codexAccountSwitcherStore.statusIsError ? Color.orange : .green)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func codexAccountRow(_ account: CodexAccountProfile) -> some View {
        let isActive = account.id == codexAccountSwitcherStore.activeAccountID
        let isTarget = account.id == codexAccountSwitcherStore.switchingAccountID

        return Button {
            guard !isActive else { return }
            pendingAccount = account
        } label: {
            HStack(spacing: 10) {
                Text(account.initials)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .frame(width: 30, height: 30)
                    .background(
                        (isActive ? TTSVisualStyle.accentStrong.opacity(0.14) : Color.primary.opacity(0.08)),
                        in: Circle()
                    )
                Text(account.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if isTarget {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Label("当前", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Text("切换")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(TTSVisualStyle.accentStrong)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(codexAccountSwitcherStore.isSwitching)
        .accessibilityLabel(isActive ? "\(account.displayName)，当前账号" : "切换到 \(account.displayName)")
    }

    private var detailHeader: some View {
        HStack(spacing: 9) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ttsTintedControl(cornerRadius: 9)
            .accessibilityLabel("返回额度概览")

            AIUsageProviderBrandIcon(providerID: providerID, size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(providerID.displayName)
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    AIUsageCompactStateLabel(state: state)
                    if let plan = state.snapshot?.planName, !plan.isEmpty {
                        Text("· \(plan)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button(action: onRefresh) {
                Group {
                    if state.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ttsTintedControl(cornerRadius: 9)
            .disabled(state.isRefreshing)
            .accessibilityLabel("立即刷新订阅额度")
        }
        .padding(12)
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("额度详情", systemImage: "chart.bar.xaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let snapshot = state.snapshot {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.metrics.enumerated()), id: \.offset) { index, metric in
                        AIUsageMetricDetailRow(metric: metric)
                        if index < snapshot.metrics.count - 1 {
                            Divider()
                                .opacity(0.55)
                        }
                    }
                }
                .padding(.horizontal, 11)
                .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
                }

                if let breakdown = snapshot.usageBreakdown, !breakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Grok 产品占用")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(breakdown) { item in
                            HStack {
                                Text(item.label)
                                Spacer()
                                Text("已用 \(Int((item.usedFraction * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption2)
                        }
                    }
                    .padding(11)
                    .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let failure = state.failure {
                    Label("显示上次成功结果：\(failure.message)", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("数据源：\(snapshot.source) · \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    state.failure?.message ?? "等待首次刷新",
                    systemImage: state.failure?.category == .notConfigured ? "gearshape" : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var tokenSection: some View {
        let tokenState = tokenStore.state(providerID: providerID, period: selectedPeriod)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("本地 Token", systemImage: "sum")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("按需读取，不后台扫描")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Picker("统计周期", selection: $selectedPeriod) {
                ForEach(AIUsageTokenPeriod.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: selectedPeriod) { _ in }

            if let summary = tokenState.summary {
                AIUsageTokenSummaryView(summary: summary)
            } else if tokenState.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取本地记录…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tokenState.message ?? "只读取本机已有的 Codex 或 Grok 日志，不上传内容，也不影响额度刷新。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        tokenStore.load(providerID: providerID, period: selectedPeriod)
                    } label: {
                        Label("读取本地统计", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(TTSSecondaryButtonStyle())
                }
                .padding(11)
                .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
                }
            }
        }
    }
}

private struct AIUsageMetricDetailRow: View {
    var metric: AIUsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(metric.label)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text(metric.primaryText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(metric.needsAttention ? Color.orange : TTSVisualStyle.accentStrong)
            }

            if let fraction = metric.remainingFraction {
                AIUsageRemainingBar(fraction: fraction, height: 5)
            }

            if let detail = metric.detailText {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct AIUsageTokenSummaryView: View {
    var summary: AIUsageTokenSummary

    private let columns = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.totalTokens.compactTokenText)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("总 Token")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(summary.cacheHitFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(TTSVisualStyle.accentStrong)
                    Text("缓存命中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: columns, spacing: 7) {
                tokenValue("输入", value: summary.inputTokens)
                tokenValue("缓存输入", value: summary.cachedInputTokens)
                tokenValue("输出", value: summary.outputTokens)
                tokenValue("推理", value: summary.reasoningTokens)
            }

            Text("\(summary.source) · \(summary.updatedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(TTSVisualStyle.glassOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TTSVisualStyle.subtleBorder, lineWidth: 1)
        }
    }

    private func tokenValue(_ label: String, value: Int) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.compactTokenText)
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(TTSVisualStyle.controlSurface.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension AIUsageProviderViewState {
    var presentation: (text: String, systemImage: String, tint: Color) {
        if isRefreshing {
            return ("刷新中", "arrow.clockwise", TTSVisualStyle.accentStrong)
        }
        if failure?.category == .notConfigured {
            return ("未配置", "gearshape", .secondary)
        }
        if snapshot != nil && (failure != nil || isStale()) {
            return ("数据陈旧", "clock.fill", .orange)
        }
        if failure != nil {
            return ("读取失败", "exclamationmark.circle.fill", .red)
        }
        if snapshot?.needsAttention == true {
            return ("需关注", "exclamationmark.triangle.fill", .orange)
        }
        if snapshot != nil {
            return ("正常", "checkmark.circle.fill", .green)
        }
        return ("待刷新", "clock", .secondary)
    }
}

private extension AIUsageMetric {
    var primaryText: String {
        switch self {
        case .quotaWindow(_, let remainingFraction, _):
            return "剩余 \(Int((min(max(remainingFraction, 0), 1) * 100).rounded()))%"
        case .balance(_, let total, let currency, _, _):
            return "\(currency.uppercased()) \(total.formatted(.number.precision(.fractionLength(2))))"
        case .amount(_, let remaining, let limit, let unit, _, let isUnlimited, _):
            if isUnlimited { return "无限" }
            if let remaining, let limit {
                return "\(remaining.formatted(.number.precision(.fractionLength(0...2)))) / \(limit.formatted(.number.precision(.fractionLength(0...2)))) \(unit)"
            }
            if let remaining {
                return "\(remaining.formatted(.number.precision(.fractionLength(0...2)))) \(unit)"
            }
            return "—"
        }
    }

    var detailText: String? {
        switch self {
        case .quotaWindow(_, _, let resetsAt), .amount(_, _, _, _, let resetsAt, _, _):
            guard let resetsAt else { return nil }
            return "重置：\(resetsAt.formatted(date: .numeric, time: .shortened))"
        case .balance(_, _, let currency, let paid, let granted):
            guard let paid, let granted else { return nil }
            return "充值 \(currency.uppercased()) \(paid.formatted(.number.precision(.fractionLength(2)))) · 赠送 \(currency.uppercased()) \(granted.formatted(.number.precision(.fractionLength(2))))"
        }
    }
}

private extension Int {
    var compactTokenText: String {
        let value = Double(self)
        if self >= 1_000_000 {
            return "\((value / 1_000_000).formatted(.number.precision(.fractionLength(0...2))))M"
        }
        if self >= 1_000 {
            return "\((value / 1_000).formatted(.number.precision(.fractionLength(0...1))))K"
        }
        return formatted()
    }
}
