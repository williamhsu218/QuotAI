import Foundation

/// Synthetic UI fixtures only. This file is excluded from the production target.
enum AntigravityQuotaFixtures {
    static func snapshot(_ scenario: String) -> AntigravityQuotaSnapshot {
        let now = Date()
        let base = AntigravityQuotaSnapshot.preview
        let groups = base.groups.compactMap { group -> AntigravityQuotaGroup? in
            if scenario == "missing", group.id == "3p" { return nil }
            let exhausted = scenario == "exhausted" && group.id == "3p"
            return AntigravityQuotaGroup(id: group.id, displayName: group.displayName,
                fiveHour: .init(kind: .fiveHour, remainingPercent: exhausted ? 0 : scenario == "low" ? 1 : group.fiveHour!.remainingPercent,
                                 resetsAt: now.addingTimeInterval(3_600)),
                sevenDay: .init(kind: .sevenDay, remainingPercent: exhausted ? 0 : scenario == "low" ? 4 : group.sevenDay!.remainingPercent,
                                 resetsAt: now.addingTimeInterval(86_400 * 3)),
                isExhausted: exhausted)
        }
        return AntigravityQuotaSnapshot(fetchedAt: now, groups: groups, subscriptionPlan: base.subscriptionPlan,
            thirdPartyAvailability: scenario == "denied" ? .unavailable : scenario == "unknown" ? .unknown : .available)
    }

    static func failure(_ scenario: String) -> String? {
        scenario == "failed"
            ? L10n.text("error.antigravity.quota_unavailable", fallback: "Antigravity quota is temporarily unavailable.")
            : nil
    }
}
