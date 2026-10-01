import SwiftUI

/// Displays a selected CLI session's official status-line report. Local receipt
/// times never become server sampling times, and hidden reports have no numeric
/// view or accessibility label to expose their old percentage.
struct ClaudeCodeQuotaView: View {
    let store: ClaudeCodeUsageStore

    var body: some View {
        TimelineView(.explicit(ClaudeCodeReportDisplayTimeline.entries(for: store.snapshot, from: Date()))) { _ in
            VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("claude.report.title", fallback: "Local report"))
                        .font(.system(size: AppTheme.TypeSize.cardTitle, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                    Spacer(minLength: AppTheme.Spacing.small)
                    Text(L10n.text("claude.report.beijing", fallback: "Beijing time"))
                        .font(.system(size: AppTheme.TypeSize.small))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                if let snapshot = store.snapshot, !snapshot.orderedReports.isEmpty {
                    // The schedule wakes at each cutoff; actual wall time also
                    // handles delayed rendering and system-clock changes.
                    reportRows(snapshot, at: Date())
                    Divider().overlay(AppTheme.separator.opacity(0.5))
                    reportMetadata(snapshot)
                } else {
                    waitingState
                }

                sessionSelection
            }
            .padding(AppTheme.Spacing.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCardSurface(cornerRadius: 10)
        }
    }

    private func reportRows(_ snapshot: ClaudeCodeQuotaSnapshot, at now: Date) -> some View {
        VStack(spacing: AppTheme.Spacing.small) {
            ForEach(Array(snapshot.orderedReports.enumerated()), id: \.element.kind) { index, report in
                if index > 0 {
                    Divider().overlay(AppTheme.separator.opacity(0.5))
                }
                if snapshot.displayableQuotas(at: now).contains(where: { $0.kind == report.kind }) {
                    QuotaRowView(quota: report.quota, compact: true)
                } else {
                    hiddenReportRow(report, at: now)
                }
            }
        }
    }

    private func hiddenReportRow(_ report: ClaudeCodeQuotaReport, at now: Date) -> some View {
        let message = report.isExpired(at: now)
            ? L10n.text("claude.report.reset_passed", fallback: "Reset time passed · waiting for report")
            : L10n.text("claude.report.stale", fallback: "Report too old · waiting for new report")
        return HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
            Text(report.kind.displayName)
                .font(.system(size: AppTheme.TypeSize.cardTitle, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(width: L10n.isSimplifiedChinese ? 50 : 58, alignment: .leading)
            Text(message)
                .font(.system(size: AppTheme.TypeSize.small))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(report.kind.displayName), \(message)")
    }

    private func reportMetadata(_ snapshot: ClaudeCodeQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.orderedReports.map { report in
                L10n.format("claude.report.window_received_format", fallback: "%@ received %@",
                            report.kind.shortLabel, beijingReceiptTime(report.firstObservedAt))
            }.joined(separator: " · "))
            Text(L10n.text("claude.report.source_unknown", fallback: "Source sampling time not provided"))
        }
        .font(.system(size: AppTheme.TypeSize.small))
        .foregroundStyle(AppTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var waitingState: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
            Text(store.isConnected && hasMissingSessionSelection
                ? L10n.text("claude.report.session_missing", fallback: "Fixed session report unavailable")
                : store.isConnected
                ? L10n.text("claude.report.waiting", fallback: "Waiting for Claude Code report")
                : L10n.text("claude.report.connection_needed", fallback: "Connection needs attention"))
                .font(.system(size: AppTheme.TypeSize.body, weight: .medium))
                .foregroundStyle(AppTheme.primaryText)
            Text(store.isConnected && hasMissingSessionSelection
                ? L10n.text("claude.report.session_missing_detail", fallback: "Choose another session or Automatic below. Your fixed selection stays unchanged; reports are never merged.")
                : store.isConnected
                ? L10n.text("claude.report.waiting_detail", fallback: "Normal Claude Code activity writes report JSON. Click Refresh to load local reports.")
                : store.configurationStatusMessage)
                .font(.system(size: AppTheme.TypeSize.caption))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("claude.report.source_unknown", fallback: "Source sampling time not provided"))
                .font(.system(size: AppTheme.TypeSize.small))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.vertical, AppTheme.Spacing.xSmall)
    }

    @ViewBuilder
    private var sessionSelection: some View {
        if !store.sessions.isEmpty || store.selectedSessionID != nil {
            HStack {
                Text(L10n.text("claude.report.session", fallback: "Session"))
                    .font(.system(size: AppTheme.TypeSize.small))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer(minLength: AppTheme.Spacing.small)
                Picker("", selection: Binding(
                    get: { store.selectedSessionID ?? "" },
                    set: { store.selectedSessionID = $0.isEmpty ? nil : $0 }
                )) {
                    Text(automaticSessionTitle).tag("")
                    if hasMissingSessionSelection, let pinnedID = store.selectedSessionID {
                        Text(L10n.format("claude.report.pinned_missing_format", fallback: "Fixed %@ · unavailable",
                                         String(pinnedID.prefix(8))))
                            .tag(pinnedID)
                    }
                    ForEach(store.sessions, id: \.id) { session in
                        Text(L10n.format("claude.report.pinned_format", fallback: "Fixed %@", session.label))
                            .tag(session.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 180)
                .accessibilityLabel(L10n.text("claude.report.session", fallback: "Session"))
            }
        } else {
            Text(automaticSessionTitle)
                .font(.system(size: AppTheme.TypeSize.small))
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private var hasMissingSessionSelection: Bool {
        guard let pinnedID = store.selectedSessionID else { return false }
        return !store.sessions.contains { $0.id == pinnedID }
    }

    private var automaticSessionTitle: String {
        if let snapshot = store.snapshot, store.selectedSessionID == nil {
            return L10n.format("claude.report.automatic_session_format", fallback: "Auto · %@",
                               String(snapshot.sessionFingerprint.prefix(8)))
        }
        return L10n.text("claude.report.automatic", fallback: "Auto · loaded reports")
    }

    private func beijingReceiptTime(_ date: Date, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now)
            ? "HH:mm"
            : L10n.isSimplifiedChinese ? "M月d日 HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }
}
