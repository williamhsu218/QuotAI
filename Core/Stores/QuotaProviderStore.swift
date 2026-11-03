import Foundation

/// Refresh state shared by every quota provider store.
enum ProviderPhase: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

/// The surface the panel, menu bar and quick menu need from a provider.
/// Resolve a store with an exhaustive `switch` over `QuotaProvider` so a new
/// provider is a compile error until it is wired up, never a silent fallback
/// to another provider's state.
@MainActor
protocol QuotaProviderStore: AnyObject, Sendable {
    var phase: ProviderPhase { get }
    var isLoading: Bool { get }
    /// Reference time for marking windows whose reset has passed. Nil in
    /// preview mode, where fixture dates are intentionally in the past.
    var expiryReferenceDate: Date? { get }
    func statusMessage(at now: Date) -> String
    /// Refresh requested explicitly by the user (panel button, quick menu).
    func userRefresh() async
}

extension ProviderPhase {
    var statusSymbolName: String {
        switch self {
        case .ready: "checkmark.circle"
        case .loading: "arrow.triangle.2.circlepath"
        case .idle: "clock"
        case .failed: "exclamationmark.circle.fill"
        }
    }
}

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
