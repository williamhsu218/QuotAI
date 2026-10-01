import AppKit
import SwiftUI

struct MenuBarPanelView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.designPreviewRendering) private var designPreviewRendering
    @AppStorage(QuotaProvider.panelDefaultsKey)
    private var quotaProvider = QuotaProvider.codex
    @AppStorage(QuotaProvider.antigravityIntegrationDefaultsKey)
    private var antigravityIntegrationEnabled = true

    let store: UsageStore
    let antigravityStore: AntigravityUsageStore
    let claudeCodeStore: ClaudeCodeUsageStore
    let stayAwakeStore: StayAwakeStore

    init(
        store: UsageStore,
        antigravityStore: AntigravityUsageStore,
        stayAwakeStore: StayAwakeStore,
        claudeCodeStore: ClaudeCodeUsageStore? = nil
    ) {
        self.store = store
        self.antigravityStore = antigravityStore
        self.claudeCodeStore = claudeCodeStore ?? .shared
        self.stayAwakeStore = stayAwakeStore
    }

    private var shouldShowAntigravity: Bool {
        antigravityIntegrationEnabled && antigravityStore.isInstalled
    }

    private var visibleProviders: [QuotaProvider] {
        QuotaProvider.visibleProviders(
            antigravityVisible: shouldShowAntigravity,
            claudeCodeVisible: shouldShowClaudeCode
        )
    }

    private var shouldShowClaudeCode: Bool {
        claudeCodeStore.isEnabled && claudeCodeStore.isInstalled
    }

    private var effectiveQuotaProvider: QuotaProvider {
        quotaProvider.effectiveProvider(
            antigravityEnabled: antigravityIntegrationEnabled,
            antigravityAvailable: shouldShowAntigravity,
            claudeCodeEnabled: claudeCodeStore.isEnabled,
            claudeCodeAvailable: claudeCodeStore.isInstalled
        )
    }

    private func providerStore(for provider: QuotaProvider) -> any QuotaProviderStore {
        switch provider {
        case .codex, .claude: store
        case .antigravity: antigravityStore
        case .claudeCode: claudeCodeStore
        }
    }

    private var selectedStore: any QuotaProviderStore {
        providerStore(for: effectiveQuotaProvider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(
                    .bottom,
                    visibleProviders.count > 1 ? AppTheme.Spacing.compact : AppTheme.Spacing.medium
                )

            if visibleProviders.count > 1 {
                quotaProviderPicker
                    .padding(.bottom, AppTheme.Spacing.medium)
            }

            quotaContent

            StayAwakeView(store: stayAwakeStore)
                .padding(.top, AppTheme.Spacing.compact)

            Divider()
                .overlay(AppTheme.separator)
                .padding(.top, AppTheme.Spacing.medium)

            footer
                .padding(.top, AppTheme.Spacing.compact)
        }
        .padding(AppTheme.Spacing.large)
        .frame(width: 340)
        .appPanelSurface()
        .task {
            store.start()
            if shouldShowAntigravity {
                antigravityStore.start()
            }
            if shouldShowClaudeCode {
                claudeCodeStore.start()
            }
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Image(nsImage: appMarkImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            Text(L10n.text("quota.title", fallback: "QuotAI"))
                .font(.system(size: AppTheme.TypeSize.panelTitle, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: AppTheme.Spacing.small)

            if effectiveQuotaProvider == .codex, let plan = store.snapshot?.subscriptionPlan {
                SubscriptionPlanBadge(plan: plan)
            } else if effectiveQuotaProvider == .antigravity, let plan = antigravityStore.snapshot?.subscriptionPlan {
                SubscriptionPlanBadge(plan: plan)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quotaProviderPicker: some View {
        HStack(spacing: 2) {
            ForEach(visibleProviders, id: \.self) { provider in
                Button {
                    quotaProvider = provider
                } label: {
                    Text(provider.displayName)
                        .font(.system(size: AppTheme.TypeSize.caption, weight: effectiveQuotaProvider == provider ? .semibold : .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.xSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    effectiveQuotaProvider == provider
                        ? AppTheme.primaryText
                        : AppTheme.secondaryText
                )
                .background {
                    if effectiveQuotaProvider == provider {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppTheme.pickerSelectedBackground)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(AppTheme.pickerSelectedBorder, lineWidth: 0.5)
                            }
                            .shadow(color: AppTheme.pickerSelectedShadow, radius: 2, y: 1)
                    }
                }
                .accessibilityLabel(provider.displayName)
                .accessibilityAddTraits(
                    effectiveQuotaProvider == provider ? .isSelected : []
                )
            }
        }
        .padding(3)
        .background(
            AppTheme.pickerTrack,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.text("quota.provider", fallback: "Quota provider")
        )
    }

    private var quotaContent: some View {
        Group {
            switch effectiveQuotaProvider {
            case .codex, .claude:
                codexQuotaContent
            case .antigravity:
                AntigravityQuotaView(store: antigravityStore)
            case .claudeCode:
                ClaudeCodeQuotaView(store: claudeCodeStore)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var codexQuotaContent: some View {
        if let snapshot = store.snapshot {
            VStack(spacing: AppTheme.Spacing.compact) {
                quotaSection(snapshot)

                ResetCreditsView(snapshot: snapshot)

                CodexTokenUsageView(snapshot: snapshot)
            }
        } else {
            emptyState
        }
    }

    private var appMarkImage: NSImage {
        if let bundledImage = NSImage(named: "AppMark") {
            return bundledImage
        }
        if
            let previewURL = Bundle.main.url(
                forResource: "AppMark-master",
                withExtension: "png"
            ),
            let previewImage = NSImage(contentsOf: previewURL)
        {
            return previewImage
        }
        return NSApplication.shared.applicationIconImage
    }

    @ViewBuilder
    private func quotaSection(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: AppTheme.Spacing.small) {
            ForEach(Array(snapshot.orderedQuotas.enumerated()), id: \.element.id) { index, quota in
                if index > 0 {
                    Divider()
                        .overlay(AppTheme.separator.opacity(0.5))
                }
                QuotaRowView(
                    quota: quota,
                    compact: true,
                    isExpired: store.expiryReferenceDate.map(quota.isExpired(at:)) ?? false
                )
            }
        }
        .padding(AppTheme.Spacing.compact)
        .appCardSurface(cornerRadius: 10)
    }

    private var emptyState: some View {
        QuotaEmptyState(
            isLoading: store.isLoading,
            title: store.isLoading
                ? L10n.text("empty.loading", fallback: "Reading Codex quota…")
                : L10n.text("empty.failed", fallback: "Quota unavailable"),
            detail: store.statusMessage
        ) {
            Task { await store.refresh() }
        }
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.medium) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Label {
                    Text(statusMessage(at: context.date))
                        .foregroundStyle(AppTheme.secondaryText)
                } icon: {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                }
                    .font(.system(size: AppTheme.TypeSize.caption))
                    .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.small)

            footerActions
        }
        .font(.system(size: AppTheme.TypeSize.caption, weight: .medium))
    }

    private var footerActions: some View {
        actionButtons
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(AppTheme.primaryText)
            .fixedSize()
    }

    private var actionButtons: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Button {
                refreshSelectedProvider()
            } label: {
                Label(
                    effectiveQuotaProvider == .claudeCode && claudeCodeStore.isLoading
                        ? L10n.text("action.cancel", fallback: "Cancel") : L10n.text("action.refresh", fallback: "Refresh"),
                    systemImage: effectiveQuotaProvider == .claudeCode && claudeCodeStore.isLoading ? "xmark" : "arrow.clockwise"
                )
                .frame(width: 28, height: 22)
            }
            .disabled(isSelectedProviderLoading && effectiveQuotaProvider != .claudeCode)
            .help(effectiveQuotaProvider == .claudeCode
                ? claudeCodeStore.isLoading ? L10n.text("action.cancel", fallback: "Cancel")
                    : L10n.text("claude.query.refresh_help", fallback: "Query Claude usage once; no model response")
                : L10n.text("action.refresh", fallback: "Refresh"))

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(
                    L10n.text("action.settings", fallback: "Settings"),
                    systemImage: "gearshape"
                )
                .frame(width: 28, height: 22)
            }
            .help(L10n.text("action.settings", fallback: "Settings"))

            moreMenu
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        if designPreviewRendering {
            moreMenuLabel
        } else {
            Menu {
                Button {
                    openLatestRelease()
                } label: {
                    Label(
                        L10n.text("action.check_updates_github", fallback: "Check on GitHub"),
                        systemImage: "arrow.up.right.square"
                    )
                }

                Divider()

                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label(
                        L10n.text("action.quit", fallback: "Quit QuotAI"),
                        systemImage: "power"
                    )
                }
            } label: {
                moreMenuLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.text("action.more", fallback: "More"))
        }
    }

    private var moreMenuLabel: some View {
        Label(
            L10n.text("action.more", fallback: "More"),
            systemImage: "ellipsis.circle"
        )
        .labelStyle(.iconOnly)
        .frame(width: 28, height: 22)
    }

    private var statusIcon: String {
        if effectiveQuotaProvider == .claudeCode, selectedStore.phase == .ready, (!hasDisplayableClaudeReport || claudeCodeStore.isHistorical(at: Date())) {
            return "clock"
        }
        return selectedStore.phase.statusSymbolName
    }

    private var statusColor: Color {
        if effectiveQuotaProvider == .claudeCode, selectedStore.phase == .ready, (!hasDisplayableClaudeReport || claudeCodeStore.isHistorical(at: Date())) {
            return AppTheme.secondaryText
        }
        return switch selectedStore.phase {
        case .ready: AppTheme.quotaHealthy.accent
        case .failed: AppTheme.quotaCritical.accent
        case .idle, .loading: AppTheme.secondaryText
        }
    }

    private var hasDisplayableClaudeReport: Bool {
        claudeCodeStore.snapshot?.displayableQuotas(at: Date()).isEmpty == false
    }

    private var isSelectedProviderLoading: Bool {
        selectedStore.isLoading
    }

    private func statusMessage(at date: Date) -> String {
        selectedStore.statusMessage(at: date)
    }

    private func refreshSelectedProvider() {
        if effectiveQuotaProvider == .claudeCode, claudeCodeStore.isLoading { claudeCodeStore.cancelRefresh(); return }
        let target = selectedStore
        Task { await target.userRefresh() }
    }

    private func openLatestRelease() {
        guard let url = URL(
            string: "https://github.com/williamhsu218/QuotAI/releases/latest"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

}

struct QuotaEmptyState: View {
    let isLoading: Bool
    let title: String
    let detail: String
    var actionTitle = L10n.text("action.retry", fallback: "Retry")
    var actionSystemImage = "arrow.clockwise"
    var isWarning = true
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "clock")
                        .font(.system(size: AppTheme.TypeSize.body, weight: .semibold))
                        .foregroundStyle(isWarning ? AppTheme.quotaCritical.accent : AppTheme.secondaryText)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                Text(title)
                    .font(.system(size: AppTheme.TypeSize.body, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)

                Text(detail)
                    .font(.system(size: AppTheme.TypeSize.caption))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if !isLoading {
                    Button(action: retry) {
                        Label(actionTitle, systemImage: actionSystemImage)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.top, AppTheme.Spacing.xSmall)
                }
            }
        }
        .padding(AppTheme.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .appCardSurface(cornerRadius: 10)
    }
}

private struct SubscriptionPlanBadge: View {
    let plan: SubscriptionPlan

    var body: some View {
        Text(plan.displayName)
            .font(.system(size: AppTheme.TypeSize.small, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.planBadgeText)
            .lineLimit(1)
            .padding(.horizontal, AppTheme.Spacing.small)
            .padding(.vertical, AppTheme.Spacing.xSmall)
            .background(AppTheme.planBadgeBackground, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(AppTheme.planBadgeBorder, lineWidth: 0.5)
            }
            .shadow(color: AppTheme.planBadgeShadow, radius: 3, y: 1)
            .accessibilityLabel(
                L10n.format(
                    "subscription.plan_accessibility_format",
                    fallback: "%@ plan",
                    plan.displayName
                )
            )
    }
}
