import Foundation

/// Finite UI updates that include the exact per-window display cutoff. Periodic
/// entries alone can leave an old number visible until the next 30-second tick.
public enum ClaudeCodeReportDisplayTimeline {
    public static func entries(for snapshot: ClaudeCodeQuotaSnapshot?, from start: Date) -> [Date] {
        guard let snapshot, !snapshot.orderedReports.isEmpty else { return [start] }
        let epsilon: TimeInterval = 0.01
        if snapshot.source == .usageQuery {
            return ([start] + ([snapshot.lastCallbackAt.addingTimeInterval(ClaudeCodeQuotaReport.displayLifetime)]
                + snapshot.orderedReports.map(\.resetsAt)).map { $0.addingTimeInterval(epsilon) }.filter { $0 > start }).sorted()
        }
        let horizon = start.addingTimeInterval(ClaudeCodeQuotaReport.displayLifetime + epsilon)
        var dates = (0...60).map { start.addingTimeInterval(Double($0) * 30) }
        for report in snapshot.orderedReports {
            let cutoff = min(report.resetsAt,
                             report.firstObservedAt.addingTimeInterval(ClaudeCodeQuotaReport.displayLifetime))
            let entry = cutoff.addingTimeInterval(epsilon)
            if entry > start, entry <= horizon { dates.append(entry) }
        }
        return Array(Set(dates)).sorted()
    }
}

/// Value-only presentation shared by the status item and its previews.
/// Resolves a provider/group once so its icon, numbers and description cannot diverge.
public struct MenuBarPresentation: Equatable, Sendable {
    public enum Icon: Equatable, Sendable {
        case codex, gemini, thirdParty, antigravity, claudeCode
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
        staleAfter: [QuotaProvider: TimeInterval] = [:],
        claudeCodeSnapshot: ClaudeCodeQuotaSnapshot? = nil,
        claudeCodeEnabled: Bool = false,
        claudeCodeAvailable: Bool = false,
        claudeCodeHistorical: Bool = false
    ) {
        let effectiveProvider = provider.effectiveProvider(
            antigravityEnabled: antigravityEnabled,
            antigravityAvailable: antigravityAvailable,
            claudeCodeEnabled: claudeCodeEnabled,
            claudeCodeAvailable: claudeCodeAvailable
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
        case .claudeCode:
            groupID = nil
            icon = .claudeCode
            // Claude results have no official sampling time. Hide each window
            // at reset and identify historical queries separately below.
            let reference = now ?? Date()
            lines = claudeCodeSnapshot?.menuBarLines(for: mode, now: reference) ?? ["--"]
            detail = [effectiveProvider.displayName,
                      claudeCodeSnapshot?.source == .usageQuery
                        ? L10n.text("claude.query.title", fallback: "Claude usage")
                        : L10n.text("claude.report.title", fallback: "Local report"),
                      lines.joined(separator: " · "),
                      L10n.text("claude.report.source_unknown", fallback: "Source sampling time not provided")]
                .joined(separator: " · ")
            fetchedAt = nil
        }

        if effectiveProvider == .claudeCode, let snapshot = claudeCodeSnapshot {
            let reference = now ?? Date()
            isStale = snapshot.source == .usageQuery
                ? claudeCodeHistorical || snapshot.isHistorical(at: reference) || snapshot.orderedReports.contains { $0.isExpired(at: reference) }
                : snapshot.lastCallbackAt > reference || snapshot.orderedReports.contains { !($0.isDisplayable(at: reference)) }
        } else if let now, let fetchedAt, let limit = staleAfter[effectiveProvider],
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
