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

    public init(
        provider: QuotaProvider,
        antigravityEnabled: Bool,
        antigravityAvailable: Bool,
        selectedGroupID: String?,
        mode: MenuBarQuotaDisplayMode,
        codexSnapshot: UsageSnapshot?,
        antigravitySnapshot: AntigravityQuotaSnapshot?,
        isStayAwakeActive: Bool
    ) {
        let effectiveProvider = provider.effectiveProvider(
            antigravityEnabled: antigravityEnabled,
            antigravityAvailable: antigravityAvailable
        )
        self.provider = effectiveProvider
        self.isStayAwakeActive = isStayAwakeActive

        switch effectiveProvider {
        case .codex:
            groupID = nil
            icon = .codex
            lines = codexSnapshot?.menuBarLines(for: mode) ?? ["--"]
            detail = "\(effectiveProvider.displayName) · \(lines.joined(separator: " · "))"
        case .antigravity:
            let group = antigravitySnapshot?.group(id: selectedGroupID)
            groupID = group?.id
            switch group?.id.lowercased() {
            case "gemini": icon = .gemini
            case "3p": icon = .thirdParty
            default: icon = .antigravity
            }
            lines = group?.menuBarLines(for: mode) ?? ["--"]
            detail = [effectiveProvider.displayName, group?.localizedDisplayName,
                      lines.joined(separator: " · ")]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    public var accessibilityLabel: String {
        let base = "QuotAI · \(detail)"
        guard isStayAwakeActive else { return base }
        return "\(base) · \(L10n.text("awake.menu_bar_active", fallback: "Stay Awake on"))"
    }
}
