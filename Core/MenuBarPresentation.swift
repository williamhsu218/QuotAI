import Foundation

/// Value-only presentation shared by the status item and its previews.
/// Resolves a provider/group once so its icon, numbers and description cannot diverge.
public struct MenuBarPresentation: Equatable, Sendable {
    public enum Icon: Equatable, Sendable {
        case codex, gemini, thirdParty, antigravity
    }

    public let provider: QuotaProvider
    public let groupID: String?
    public let icon: Icon
    public let lines: [String]
    public let detail: String
    public let isStayAwakeActive: Bool
    /// The numbers come from a snapshot older than the provider's freshness
    /// budget. The accessibility label / tooltip reports this without dimming.
    public let isStale: Bool

    /// - Parameters:
    ///   - now: Reference time for expiry and staleness. Nil (previews and
    ///     fixtures) shows stored values as they are.
    ///   - staleAfter: Maximum snapshot age per provider before the menu bar
    ///     reports stale data. Providers without an entry are not marked stale.
    public init(
        provider: QuotaProvider,
        antigravityEnabled: Bool,
        antigravityAvailable: Bool,
        selectedGroupID: String?,
        mode: MenuBarQuotaDisplayMode,
        codexSnapshot: UsageSnapshot?,
        antigravitySnapshot: AntigravityQuotaSnapshot?,
        isStayAwakeActive: Bool,
        now: Date? = nil,
        staleAfter: [QuotaProvider: TimeInterval] = [:]
    ) {
        let effectiveProvider = provider.effectiveProvider(
            antigravityEnabled: antigravityEnabled,
            antigravityAvailable: antigravityAvailable
        )
        self.provider = effectiveProvider
        self.isStayAwakeActive = isStayAwakeActive

        let fetchedAt: Date?
        switch effectiveProvider {
        case .codex, .claude:
            groupID = nil
            icon = .codex
            lines = codexSnapshot?.menuBarLines(for: mode, now: now) ?? ["--"]
            detail = "\(effectiveProvider.displayName) · \(lines.joined(separator: " · "))"
            fetchedAt = codexSnapshot?.fetchedAt
        case .antigravity:
            let group = antigravitySnapshot?.group(id: selectedGroupID)
            groupID = group?.id
            switch group?.id.lowercased() {
            case "gemini": icon = .gemini
            case "3p": icon = .thirdParty
            default: icon = .antigravity
            }
            lines = group?.menuBarLines(for: mode, now: now) ?? ["--"]
            detail = [effectiveProvider.displayName, group?.localizedDisplayName,
                      lines.joined(separator: " · ")]
                .compactMap { $0 }.joined(separator: " · ")
            fetchedAt = antigravitySnapshot?.fetchedAt
        }

        if let now, let fetchedAt, let limit = staleAfter[effectiveProvider],
           lines != ["--"] {
            isStale = now.timeIntervalSince(fetchedAt) > limit
        } else {
            isStale = false
        }
    }

    public var accessibilityLabel: String {
        var base = "QuotAI · \(detail)"
        if isStale {
            base += " · \(L10n.text("status.stale", fallback: "Not recently updated"))"
        }
        guard isStayAwakeActive else { return base }
        return "\(base) · \(L10n.text("awake.menu_bar_active", fallback: "Stay Awake on"))"
    }
}
