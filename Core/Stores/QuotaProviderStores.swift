import Foundation

/// The provider stores the menu bar, the panel and the settings window share.
@MainActor
struct QuotaProviderStores {
    let codex: UsageStore
    let antigravity: AntigravityUsageStore
    let claudeCode: ClaudeCodeUsageStore

    static var shared: QuotaProviderStores {
        QuotaProviderStores(codex: .shared, antigravity: .shared, claudeCode: .shared)
    }

    /// Exhaustive, so a new provider is a compile error until it is wired up.
    func store(for provider: QuotaProvider) -> any QuotaProviderStore {
        switch provider {
        case .codex: codex
        case .antigravity: antigravity
        case .claudeCode: claudeCode
        }
    }

    /// Reads installation and enablement from the stores. The Antigravity
    /// switch is a preference, passed in so SwiftUI views can supply their
    /// own @AppStorage value.
    func availability(antigravityEnabled: Bool) -> ProviderAvailability {
        ProviderAvailability(
            antigravityEnabled: antigravityEnabled,
            antigravityInstalled: antigravity.isInstalled,
            claudeCodeEnabled: claudeCode.isEnabled,
            claudeCodeInstalled: claudeCode.isInstalled
        )
    }
}
