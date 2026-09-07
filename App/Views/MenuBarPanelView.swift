import AppKit
import SwiftUI

struct MenuBarPanelView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.nativeGlassRenderingEnabled) private var nativeGlassRenderingEnabled
    @Environment(\.designPreviewRendering) private var designPreviewRendering
    @AppStorage(QuotaProvider.panelDefaultsKey)
    private var quotaProvider = QuotaProvider.codex
    @AppStorage(QuotaProvider.antigravityIntegrationDefaultsKey)
    private var antigravityIntegrationEnabled = true

    let store: UsageStore
    let antigravityStore: AntigravityUsageStore
    let stayAwakeStore: StayAwakeStore

    private var shouldShowAntigravity: Bool {
        antigravityIntegrationEnabled && (antigravityStore.isInstalled || antigravityStore.isAvailable)
    }

    private var effectiveQuotaProvider: QuotaProvider {
        quotaProvider.effectiveProvider(
            antigravityEnabled: antigravityIntegrationEnabled,
            antigravityAvailable: shouldShowAntigravity
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(
                    .bottom,
                    shouldShowAntigravity ? AppTheme.Spacing.compact : AppTheme.Spacing.medium
                )

            if shouldShowAntigravity {
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
            ForEach(QuotaProvider.allCases, id: \.self) { provider in
                Button {
                    quotaProvider = provider
                } label: {
                    Text(provider.displayName)
                        .font(.system(size: AppTheme.TypeSize.caption, weight: quotaProvider == provider ? .semibold : .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.xSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    quotaProvider == provider
                        ? AppTheme.primaryText
                        : AppTheme.secondaryText
                )
                .background {
                    if quotaProvider == provider {
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
                    quotaProvider == provider ? .isSelected : []
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
            if effectiveQuotaProvider == .codex {
                codexQuotaContent
            } else {
                AntigravityQuotaView(store: antigravityStore)
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
                QuotaRowView(quota: quota, compact: true)
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

    @ViewBuilder
    private var footerActions: some View {
        if #available(macOS 26.0, *), nativeGlassRenderingEnabled {
            GlassEffectContainer(spacing: AppTheme.Spacing.small) {
                actionButtons
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .foregroundStyle(AppTheme.primaryText)
            }
        } else {
            actionButtons
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize()
        }
    }

    private var actionButtons: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Button {
                refreshSelectedProvider()
            } label: {
                Label(
                    L10n.text("action.refresh", fallback: "Refresh"),
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(isSelectedProviderLoading)
            .help(L10n.text("action.refresh", fallback: "Refresh"))

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(
                    L10n.text("action.settings", fallback: "Settings"),
                    systemImage: "gearshape"
                )
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
    }

    private var statusIcon: String {
        switch effectiveQuotaProvider {
        case .codex:
            switch store.phase {
            case .ready: "checkmark.circle"
            case .loading: "arrow.triangle.2.circlepath"
            case .idle: "clock"
            case .failed: "exclamationmark.circle.fill"
            }
        case .antigravity:
            switch antigravityStore.phase {
            case .ready: "checkmark.circle"
            case .loading: "arrow.triangle.2.circlepath"
            case .idle: "clock"
            case .failed: "exclamationmark.circle.fill"
            }
        }
    }

    private var statusColor: Color {
        switch effectiveQuotaProvider {
        case .codex:
            switch store.phase {
            case .ready: AppTheme.quotaHealthy.accent
            case .failed: AppTheme.quotaCritical.accent
            case .idle, .loading: AppTheme.secondaryText
            }
        case .antigravity:
            switch antigravityStore.phase {
            case .ready: AppTheme.quotaHealthy.accent
            case .failed: AppTheme.quotaCritical.accent
            case .idle, .loading: AppTheme.secondaryText
            }
        }
    }

    private var isSelectedProviderLoading: Bool {
        effectiveQuotaProvider == .codex ? store.isLoading : antigravityStore.isLoading
    }

    private func statusMessage(at date: Date) -> String {
        effectiveQuotaProvider == .codex
            ? store.statusMessage(at: date)
            : antigravityStore.statusMessage(at: date)
    }

    private func refreshSelectedProvider() {
        switch effectiveQuotaProvider {
        case .codex:
            Task { await store.refresh() }
        case .antigravity:
            Task { await antigravityStore.refresh() }
        }
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
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: AppTheme.TypeSize.body, weight: .semibold))
                        .foregroundStyle(AppTheme.quotaCritical.accent)
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
                        Label(
                            L10n.text("action.retry", fallback: "Retry"),
                            systemImage: "arrow.clockwise"
                        )
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
