import Foundation

/// Refresh state shared by every quota provider store.
public enum ProviderPhase: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

/// The surface the panel, menu bar and quick menu need from a provider.
/// The registry owns provider resolution. A registered adapter always uses its
/// own store; unavailable saved selections resolve to the declared fallback.
@MainActor
public protocol QuotaProviderStore: AnyObject, Sendable {
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
