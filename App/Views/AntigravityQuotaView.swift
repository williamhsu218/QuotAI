import SwiftUI

struct AntigravityQuotaView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var groupNamespace
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
                HStack(spacing: 2) {
                    ForEach(snapshot.panelGroups) { option in
                        Button { selectedGroupID = option.id } label: {
                            Text(AntigravityQuotaTab(rawValue: option.id)?.title ?? option.localizedDisplayName)
                                .font(.system(size: AppTheme.TypeSize.caption, weight: group.id == option.id ? .semibold : .medium))
                                .foregroundStyle(group.id == option.id ? AppTheme.primaryText : AppTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppTheme.Spacing.xSmall)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background {
                            if group.id == option.id {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(AppTheme.pickerSelectedBackground)
                                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(AppTheme.pickerSelectedBorder, lineWidth: 0.5) }
                                    .matchedGeometryEffect(id: "group", in: groupNamespace)
                            }
                        }
                        .accessibilityAddTraits(group.id == option.id ? .isSelected : [])
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: group.id)
                .padding(3)
                .background(AppTheme.pickerTrack, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.text("antigravity.quota_group", fallback: "Quota group"))
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
