import SwiftUI

struct AntigravityQuotaView: View {
    @AppStorage(AntigravityQuotaGroup.panelGroupDefaultsKey)
    private var selectedGroupID = "gemini"
    let store: AntigravityUsageStore

    var body: some View {
        if let snapshot = store.snapshot, let group = snapshot.panelGroup(id: selectedGroupID) {
            quotaGroup(group, in: snapshot)
        } else {
            emptyState
        }
    }

    private func quotaGroup(_ group: AntigravityQuotaGroup, in snapshot: AntigravityQuotaSnapshot) -> some View {
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            if snapshot.panelGroups.count > 1 {
                Picker(
                    L10n.text("antigravity.quota_group", fallback: "Quota group"),
                    selection: Binding(
                        get: { group.id },
                        set: { selectedGroupID = $0 }
                    )
                ) {
                    ForEach(snapshot.panelGroups) { option in
                        Text(AntigravityQuotaTab(rawValue: option.id)?.title ?? option.localizedDisplayName)
                            .tag(option.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("antigravity.quotaGroupPicker")
            } else {
                Text(L10n.format("antigravity.group.quota_title", fallback: "%@ quota",
                                 AntigravityQuotaTab(rawValue: group.id)?.title ?? group.localizedDisplayName))
                    .font(.system(size: AppTheme.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("antigravity.singleGroupTitle")
            }

            if group.orderedQuotas.isEmpty {
                QuotaEmptyState(
                    isLoading: store.isLoading,
                    title: group.id == "3p" && snapshot.thirdPartyAvailability == .unknown
                        ? L10n.text("antigravity.models.read_failed", fallback: "Model access unavailable")
                        : L10n.text("empty.antigravity_failed", fallback: "Antigravity quota unavailable"),
                    detail: snapshot.thirdPartyStatusMessage
                        ?? L10n.text("antigravity.quota.missing", fallback: "No quota was returned for this group. Try refreshing.")
                ) { Task { await store.userRefresh() } }
                .accessibilityIdentifier("antigravity.groupReadFailure")
            } else {
                if group.isExhausted {
                    Label(L10n.text("antigravity.quota.exhausted", fallback: "Quota exhausted · waiting for reset"),
                          systemImage: "hourglass")
                        .font(.system(size: AppTheme.TypeSize.small))
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("antigravity.quotaExhausted")
                }
                VStack(spacing: AppTheme.Spacing.small) {
                    ForEach(Array(group.orderedQuotas.enumerated()), id: \.element.id) { index, quota in
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
                .id(group.id) // Replace quota rows immediately; don't animate from another pool.
            }
        }
        .padding(AppTheme.Spacing.compact)
        .appCardSurface(cornerRadius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("antigravity.quotaGroup.\(group.id)")
    }

    private var emptyState: some View {
        QuotaEmptyState(
            isLoading: store.isLoading,
            title: store.isLoading
                ? L10n.text(
                    "empty.antigravity_loading",
                    fallback: "Reading Antigravity quota…"
                )
                : L10n.text(
                    "empty.antigravity_failed",
                    fallback: "Antigravity quota unavailable"
                ),
            detail: store.statusMessage
        ) {
            Task { await store.refresh() }
        }
    }
}
