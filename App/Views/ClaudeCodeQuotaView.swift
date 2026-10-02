import SwiftUI

struct ClaudeCodeQuotaView: View {
    let store: ClaudeCodeUsageStore
    var body: some View {
        TimelineView(.explicit(ClaudeCodeReportDisplayTimeline.entries(for: store.snapshot, from: Date()))) { _ in
            VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("claude.query.title", fallback: "Claude usage"))
                        .font(.system(size: AppTheme.TypeSize.cardTitle, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                    Spacer(minLength: AppTheme.Spacing.small)
                    Text(L10n.text("claude.report.beijing", fallback: "Beijing time"))
                        .font(.system(size: AppTheme.TypeSize.small)).foregroundStyle(AppTheme.secondaryText)
                }
                if let snapshot = store.snapshot {
                    let historical = store.isHistorical(at: Date())
                    ForEach([QuotaKind.fiveHour, .sevenDay], id: \.self) { kind in
                        if let report = snapshot.orderedReports.first(where: { $0.kind == kind }) {
                            if snapshot.displayableQuotas(at: Date()).contains(where: { $0.kind == report.kind }) {
                                QuotaRowView(quota: report.quota, compact: true)
                                    .saturation(historical ? 0 : 1).opacity(historical ? 0.65 : 1)
                            } else {
                                Text(Date() < snapshot.lastCallbackAt
                                    ? L10n.text("claude.query.clock_changed", fallback: "System time changed; refresh usage")
                                    : L10n.format("claude.query.window_reset_format", fallback: "%@ · reset time passed, refresh usage", report.kind.displayName))
                                    .font(.system(size: AppTheme.TypeSize.small)).foregroundStyle(AppTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(L10n.format("claude.query.window_unavailable_format", fallback: "%@ · no active reset time returned", kind.displayName))
                                .font(.system(size: AppTheme.TypeSize.small)).foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(AppTheme.separator.opacity(0.5))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.format("claude.query.queried_format", fallback: "Queried %@ · local Claude /usage", receiptTime(snapshot.lastCallbackAt)))
                        if historical { Text(L10n.text("claude.query.historical_detail", fallback: "Previous query result · refresh to update")) }
                        Text(L10n.text("claude.query.source_detail", fallback: "Query snapshot; source sampling time and account ID not provided"))
                    }
                    .font(.system(size: AppTheme.TypeSize.small)).foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.text("claude.query.waiting", fallback: "Click Refresh to query Claude usage"))
                        .font(.system(size: AppTheme.TypeSize.body, weight: .medium)).foregroundStyle(AppTheme.primaryText)
                    Text(L10n.text("claude.query.waiting_detail", fallback: "Runs the built-in /usage command once. No model response is generated."))
                        .font(.system(size: AppTheme.TypeSize.caption)).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case let .failed(message) = store.phase {
                    Text(message).font(.system(size: AppTheme.TypeSize.small)).foregroundStyle(AppTheme.quotaCritical.accent)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.isLoading {
                    Label(L10n.text("claude.query.loading", fallback: "Querying Claude usage…"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: AppTheme.TypeSize.small)).foregroundStyle(AppTheme.secondaryText)
                }
            }
            .padding(AppTheme.Spacing.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCardSurface(cornerRadius: 10)
        }
    }
    private func receiptTime(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = L10n.isSimplifiedChinese ? "M月d日 HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }
}
