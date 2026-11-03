import SwiftUI

/// The default presentation for any future registered adapter.
struct ProviderQuotaView: View {
    let plugin: any QuotaProviderPlugin

    var body: some View {
        if let snapshot = plugin.snapshot(at: Date()) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                ForEach(snapshot.groups) { group in
                    if !group.name.isEmpty { Text(group.name).font(.headline) }
                    ForEach(group.quotas, id: \.kind) { quota in
                        QuotaRowView(quota: quota, compact: true, isExpired: quota.isExpired(at: Date()))
                    }
                    if let message = group.statusMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(AppTheme.Spacing.compact)
            .appCardSurface(cornerRadius: 10)
        } else {
            QuotaEmptyState(
                isLoading: plugin.store.isLoading,
                title: L10n.text("empty.failed", fallback: "Quota unavailable"),
                detail: plugin.store.statusMessage(at: Date())
            ) {
                Task { await plugin.store.userRefresh() }
            }
        }
    }
}
