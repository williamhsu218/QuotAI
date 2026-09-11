import AppKit
import SwiftUI

struct DesignPreviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(QuotaProvider.menuBarDefaultsKey)
    private var menuBarQuotaProvider = QuotaProvider.codex
    @AppStorage(AntigravityQuotaGroup.menuBarGroupDefaultsKey)
    private var menuBarAntigravityGroupID = ""
    @AppStorage(MenuBarQuotaDisplayMode.defaultsKey)
    private var menuBarQuotaDisplayMode = MenuBarQuotaDisplayMode.both
    @AppStorage(QuotaProvider.antigravityIntegrationDefaultsKey)
    private var antigravityIntegrationEnabled = true
    let store: UsageStore
    let antigravityStore: AntigravityUsageStore
    let stayAwakeStore: StayAwakeStore

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            MenuBarStatusLabel(presentation: menuBarPresentation)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))

            MenuBarPanelView(
                store: store,
                antigravityStore: antigravityStore,
                stayAwakeStore: stayAwakeStore
            )
                .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
        }
        .padding(44)
        .foregroundStyle(AppTheme.primaryText)
        .background { previewBackdrop }
    }

    private var menuBarPresentation: MenuBarPresentation {
        MenuBarPresentation(
            provider: menuBarQuotaProvider,
            antigravityEnabled: antigravityIntegrationEnabled,
            antigravityAvailable: antigravityStore.isInstalled,
            selectedGroupID: menuBarAntigravityGroupID,
            mode: menuBarQuotaDisplayMode,
            codexSnapshot: store.snapshot,
            antigravitySnapshot: antigravityStore.snapshot,
            isStayAwakeActive: stayAwakeStore.isActive
        )
    }

    private var previewBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [
                    AppTheme.cyan.opacity(colorScheme == .dark ? 0.22 : 0.18),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 430
            )
            RadialGradient(
                colors: [
                    AppTheme.lime.opacity(colorScheme == .dark ? 0.15 : 0.12),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 390
            )
        }
    }
}
