import SwiftUI

struct AntigravityQuotaView: View {
    @AppStorage(AntigravityQuotaGroup.panelGroupDefaultsKey)
    private var selectedGroupID = "gemini"
    let store: AntigravityUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            if let snapshot = store.snapshot, let group = snapshot.panelGroup(id: selectedGroupID) {
                quotaGroup(group, in: snapshot)
            } else {
                emptyState
            }
            AntigravityTokenUsageView(store: store.tokenUsage)
        }
    }

    private func quotaGroup(_ group: AntigravityQuotaGroup, in snapshot: AntigravityQuotaSnapshot) -> some View {
        let accent = groupAccent(for: group.id)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            Picker(L10n.text("antigravity.quota_group", fallback: "Quota group"), selection: Binding(
                get: { snapshot.panelGroup(id: selectedGroupID)?.id ?? group.id },
                set: { selectedGroupID = $0 }
            )) {
                ForEach(AntigravityQuotaTab.allCases) { tab in
                    Text(tab.title).tag(tab.rawValue)
                        .disabled(!snapshot.groups.contains { $0.id == tab.rawValue })
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityIdentifier("antigravity.quotaGroupPicker")

            VStack(spacing: AppTheme.Spacing.small) {
                ForEach(Array(group.orderedQuotas.enumerated()), id: \.element.id) { index, quota in
                    if index > 0 {
                        Divider()
                            .overlay(AppTheme.separator.opacity(0.5))
                    }
                    QuotaRowView(quota: quota, compact: true)
                }
            }
            .id(group.id) // Replace quota rows immediately; don't animate from another pool.
        }
        .padding(AppTheme.Spacing.compact)
        .appCardSurface(cornerRadius: 10)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(accent)
                .frame(width: 2)
                .padding(.vertical, AppTheme.Spacing.compact)
                .padding(.leading, 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("antigravity.quotaGroup.\(group.id)")
    }

    private func groupAccent(for groupID: String) -> Color {
        switch groupID {
        case "gemini":
            return AppTheme.cyan
        default:
            return AppTheme.lime
        }
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
