import SwiftUI

struct AntigravityTokenUsageView: View {
    let store: AntigravityTokenStore
    @AppStorage(TokenActivityTheme.defaultsKey) private var storedTheme = TokenActivityTheme.defaultTheme.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var palette: TokenActivityPalette {
        TokenActivityPalette(theme: TokenActivityTheme(storedValue: storedTheme),
                             colorScheme: colorScheme, increasedContrast: contrast == .increased)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow
                .lineLimit(1)

            if let snapshot = store.snapshot, snapshot.generations > 0 {
                tokenSummarySection(snapshot)
            }

            if let snapshot = store.snapshot, snapshot.files > 0 {
                AntigravityTokenCalendarView(snapshot: snapshot, stale: store.failed, palette: palette)
                    .padding(.top, 3)
            }

            statusSection
        }
        .foregroundStyle(AppTheme.primaryText)
        .padding(AppTheme.Spacing.compact)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .appCardSurface(cornerRadius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("antigravity.tokenUsage")
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(L10n.text("ag_tokens.title", fallback: "Local tokens"))
                .font(.system(size: AppTheme.TypeSize.cardTitle, weight: .semibold))
            Text(L10n.text("ag_tokens.all_models", fallback: "All models"))
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.secondaryText)
                .help(L10n.text("ag_tokens.scope", fallback: "Total = recorded input + output + cache hits. Output includes thinking. Local retained sessions only, not account-wide or billed usage."))

            headerBadge

            Spacer(minLength: 4)

            if store.isLoading {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel(L10n.text("ag_tokens.loading", fallback: "Reading local token metadata…"))
            } else {
                Button {
                    Task(priority: .utility) { await store.refresh() }
                } label: {
                    Label(L10n.text("action.refresh", fallback: "Refresh"), systemImage: "arrow.clockwise")
                        .font(.system(size: AppTheme.TypeSize.small))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("antigravity.tokenUsage.refresh")
                .foregroundStyle(AppTheme.cyan)
                .help(headerRefreshTooltip)
            }
        }
    }

    @ViewBuilder
    private var headerBadge: some View {
        if store.failed {
            Text(L10n.text("ag_tokens.stale_badge", fallback: "Not updated"))
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .help(L10n.text("ag_tokens.unavailable", fallback: "Local data unavailable. Previous counts have not been refreshed."))
                .accessibilityIdentifier("antigravity.tokenUsage.badge.failed")
        } else if let snapshot = store.snapshot {
            if snapshot.isPartial {
                Text(L10n.text("ag_tokens.partial_badge", fallback: "Partial"))
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help(partialBadgeHelp(snapshot))
                    .accessibilityIdentifier("antigravity.tokenUsage.badge.partial")
            } else if snapshot.undatedGenerations > 0 {
                Text(L10n.text("ag_tokens.dates_missing_badge", fallback: "Dates missing"))
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help(L10n.format("ag_tokens.undated_format", fallback: "%d undated calls", snapshot.undatedGenerations))
                    .accessibilityIdentifier("antigravity.tokenUsage.badge.datesMissing")
            }
        }
    }

    private func tokenSummarySection(_ snapshot: AntigravityTokenSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(AntigravityTokenFormat.compact(snapshot.total))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityIdentifier("antigravity.tokenUsage.total")
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("ag_tokens.recorded_local", fallback: "Recorded local usage"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                    Text(L10n.text("ag_tokens.includes_cache", fallback: "incl. cache"))
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .help(L10n.text("ag_tokens.scope", fallback: "Total = recorded input + output + cache hits. Output includes thinking. Local retained sessions only, not account-wide or billed usage."))
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                tokenMetric("ag_tokens.input", fallback: "Input", tokens: snapshot.input, id: "input")
                tokenMetric("ag_tokens.output", fallback: "Output", tokens: snapshot.output, id: "output")
                tokenMetric("ag_tokens.cache_hits", fallback: "Cache hits", tokens: snapshot.cacheRead, id: "cache")
            }
            .padding(.vertical, 2)

            Divider().overlay(AppTheme.separator.opacity(0.5))

            LazyVGrid(columns: [.init(.flexible(), alignment: .leading), .init(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 3) {
                ForEach(snapshot.models) { model in
                    HStack(spacing: 4) {
                        Text(model.id == "Other" ? L10n.text("ag_tokens.other", fallback: "Other") : model.id)
                            .foregroundStyle(AppTheme.secondaryText)
                        Spacer(minLength: 0)
                        Text(AntigravityTokenFormat.compact(model.total))
                            .fontWeight(.medium).monospacedDigit()
                    }
                    .font(.system(size: AppTheme.TypeSize.small))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("antigravity.tokenUsage.model.\(model.id)")
                }
            }
        }
    }

    private func tokenMetric(_ key: String, fallback: String, tokens: Int64, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(key, fallback: fallback))
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.secondaryText)
            Text(AntigravityTokenFormat.compact(tokens))
                .font(.system(size: AppTheme.TypeSize.small, weight: .medium))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("antigravity.tokenUsage.\(id)")
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if store.failed {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(L10n.text("ag_tokens.unavailable", fallback: "Local data unavailable. Previous counts have not been refreshed."))
                        .font(.system(size: AppTheme.TypeSize.small))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("antigravity.tokenUsage.staleNotice")
            }

            if let snapshot = store.snapshot {
                if snapshot.files == 0 {
                    Text(L10n.text("ag_tokens.empty", fallback: "No supported local conversation databases."))
                        .font(.system(size: AppTheme.TypeSize.small))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .center, spacing: 6) {
                        if snapshot.pendingFiles > 0 {
                            let totalFiles = max(0, snapshot.files)
                            let pending = max(0, snapshot.pendingFiles)
                            let processed = max(0, min(totalFiles, totalFiles - pending))
                            Text(L10n.format("ag_tokens.progress_format",
                                             fallback: "%d/%d sessions · %d calls",
                                             processed, totalFiles, snapshot.generations))
                                .font(.system(size: AppTheme.TypeSize.small))
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .accessibilityIdentifier("antigravity.tokenUsage.progress")

                            Spacer(minLength: 4)

                            Button {
                                Task(priority: .userInitiated) {
                                    await store.continueHistory()
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    if store.isLoading {
                                        ProgressView().controlSize(.mini)
                                    }
                                    Text(L10n.text("ag_tokens.continue", fallback: "Read more"))
                                        .font(.system(size: AppTheme.TypeSize.small, weight: .medium))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(AppTheme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(AppTheme.cyan.opacity(0.3), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isLoading)
                            .accessibilityLabel(L10n.text("ag_tokens.continue", fallback: "Read more"))
                            .accessibilityIdentifier("antigravity.tokenUsage.continueHistory")
                        } else {
                            Text(L10n.format("ag_tokens.complete_format",
                                             fallback: "%d calls recorded · updated on demand",
                                             snapshot.generations))
                                .font(.system(size: AppTheme.TypeSize.small))
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .accessibilityIdentifier("antigravity.tokenUsage.statusComplete")
                            Spacer(minLength: 0)
                        }
                    }

                    let aux = auxiliaryNotes(for: snapshot)
                    if !aux.isEmpty {
                        Text(aux.joined(separator: " · "))
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("antigravity.tokenUsage.auxiliary")
                    }
                }
            } else if !store.failed {
                Text(L10n.text(store.isLoading ? "ag_tokens.loading" : "ag_tokens.on_demand",
                               fallback: store.isLoading ? "Reading local token metadata…" : "Read on demand"))
                    .font(.system(size: AppTheme.TypeSize.small))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func auxiliaryNotes(for snapshot: AntigravityTokenSnapshot) -> [String] {
        var items: [String] = []
        if snapshot.skippedRecords > 0 {
            items.append(L10n.format("ag_tokens.aux_skipped", fallback: "%d excluded", snapshot.skippedRecords))
        }
        if snapshot.unavailableFiles > 0 {
            items.append(L10n.format("ag_tokens.aux_unavailable", fallback: "%d unreadable", snapshot.unavailableFiles))
        }
        // A pending slice can set `limited` after its normal per-read budget.
        // Only a finished scan with this flag proves a history cap was hit.
        if snapshot.limited && snapshot.pendingFiles == 0 {
            items.append(L10n.text("ag_tokens.aux_limited", fallback: "History capped"))
        }
        if snapshot.undatedGenerations > 0 {
            items.append(L10n.format("ag_tokens.aux_undated", fallback: "%d dates missing", snapshot.undatedGenerations))
        }
        return items
    }

    private func partialBadgeHelp(_ snapshot: AntigravityTokenSnapshot) -> String {
        if snapshot.limited && snapshot.pendingFiles == 0 {
            return L10n.text("ag_tokens.limited", fallback: "Only part of the local history fits within the safety limit.")
        }
        return L10n.format("ag_tokens.partial_format", fallback: "%d calls recorded · %d sessions pending · %d records excluded",
                           snapshot.generations, snapshot.pendingFiles, snapshot.skippedRecords)
    }

    private var headerRefreshTooltip: String {
        let base = L10n.text("ag_tokens.on_demand", fallback: "Reads a bounded batch only on demand. No background polling.")
        if store.failed {
            return L10n.text("ag_tokens.unavailable", fallback: "Local data unavailable. Previous counts have not been refreshed.") + "\n" + base
        }
        guard let snapshot = store.snapshot else { return base }
        return L10n.format("ag_tokens.complete_format", fallback: "%d calls recorded · updated on demand", snapshot.generations) + "\n" + base
    }
}

/// Native 18 × 7 grid. Hover and selection use only the in-memory snapshot.
private struct AntigravityTokenCalendarView: View {
    let snapshot: AntigravityTokenSnapshot
    let stale: Bool
    let palette: TokenActivityPalette
    private let weeks: [AntigravityTokenWeek]
    private let peak: Int64
    @State private var hoveredID: String?
    @State private var selectedID: String?
    private let cellSize: CGFloat = 11
    private let gap: CGFloat = 2.8

    init(snapshot: AntigravityTokenSnapshot, stale: Bool, palette: TokenActivityPalette) {
        self.snapshot = snapshot; self.stale = stale
        self.palette = palette
        let weeks = snapshot.activityWeeks()
        self.weeks = weeks
        self.peak = max(1, weeks.flatMap(\.days).compactMap(\.tokens).max() ?? 0)
    }

    private var activeDay: AntigravityTokenDay? {
        let id = hoveredID ?? selectedID
        return weeks.lazy.flatMap(\.days).first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let day = activeDay {
                    Text(day.id).monospacedDigit()
                    Spacer(minLength: 0)
                    Text(valueText(day)).monospacedDigit()
                } else {
                    Text(L10n.text("ag_tokens.calendar_title", fallback: "Daily total · 18 weeks"))
                    Spacer(minLength: 0)
                    Text(L10n.text("ag_tokens.calendar_hint", fallback: "Hover or click"))
                }
            }
            .font(.system(size: AppTheme.TypeSize.small))
            .foregroundStyle(AppTheme.secondaryText)
            .lineLimit(1)
            .frame(height: 16)
            .accessibilityIdentifier("antigravity.tokenUsage.dayDetail")

            HStack(alignment: .top, spacing: 5) {
                VStack(spacing: gap) {
                    ForEach(0..<7) { index in
                        Text(weekday(index))
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 12, height: cellSize)
                    }
                }
                .accessibilityHidden(true)
                HStack(spacing: gap) {
                    ForEach(weeks) { week in
                        VStack(spacing: gap) {
                            ForEach(week.days) { day in dayCell(day) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("ag_tokens.calendar_title", fallback: "Daily total · 18 weeks"))

            HStack(spacing: 3) {
                TokenActivitySwatch(level: 0, palette: palette, cornerRadius: 1.5, unknown: true)
                    .frame(width: 8, height: 8)
                Text(L10n.text("ag_tokens.calendar_unknown", fallback: "Unknown"))
                Spacer(minLength: 2)
                Text("0 M")
                ForEach(0..<5) { level in
                    TokenActivitySwatch(level: level, palette: palette, cornerRadius: 1.5)
                        .frame(width: 8, height: 8)
                }
                Text(L10n.text("usage.legend_more", fallback: "More"))
            }
            .font(.system(size: 9))
            .foregroundStyle(AppTheme.secondaryText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("ag_tokens.calendar_legend", fallback: "Color intensity indicates token usage. Dashed cells are incomplete, not zero."))
            .help(calendarScope)
        }
    }

    @ViewBuilder
    private func dayCell(_ day: AntigravityTokenDay) -> some View {
        if day.isFuture {
            Color.clear.frame(width: cellSize, height: cellSize).accessibilityHidden(true)
        } else {
            let active = (hoveredID ?? selectedID) == day.id
            Button { selectedID = selectedID == day.id ? nil : day.id } label: {
                TokenActivitySwatch(level: level(day.tokens ?? 0), palette: palette,
                                    emphasized: active || day.isToday,
                                    partial: day.isPartial || stale, unknown: day.tokens == nil)
                    .frame(width: cellSize, height: cellSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { hoveredID = day.id }
                else if hoveredID == day.id { hoveredID = nil }
            }
            .help("\(day.id): \(valueText(day))")
            .accessibilityLabel("\(day.id): \(valueText(day))")
            .accessibilityIdentifier("antigravity.tokenUsage.day.\(day.id)")
            .accessibilityAddTraits(selectedID == day.id ? .isSelected : [])
        }
    }

    private var calendarScope: String {
        let scope = L10n.text("ag_tokens.calendar_scope", fallback: "First generated step date · local time")
        if snapshot.undatedGenerations > 0 {
            return scope + " · " + L10n.format("ag_tokens.undated_format", fallback: "%d undated calls", snapshot.undatedGenerations)
        }
        return scope
    }

    private func valueText(_ day: AntigravityTokenDay) -> String {
        guard let tokens = day.tokens else { return L10n.text("ag_tokens.calendar_unknown", fallback: "Unknown") }
        let value = AntigravityTokenFormat.compact(tokens)
        if stale { return L10n.format("ag_tokens.calendar_stale_format", fallback: "%@ · previous", value) }
        if day.isPartial { return L10n.format("ag_tokens.calendar_partial_format", fallback: "%@ · partial", value) }
        return value
    }

    private func weekday(_ index: Int) -> String {
        switch index {
        case 0: return L10n.text("usage.weekday_mon", fallback: "M")
        case 2: return L10n.text("usage.weekday_wed", fallback: "W")
        case 4: return L10n.text("usage.weekday_fri", fallback: "F")
        default: return ""
        }
    }

    private func level(_ tokens: Int64) -> Int {
        guard tokens > 0 else { return 0 }
        let ratio = Double(tokens) / Double(peak)
        return ratio > 0.70 ? 4 : (ratio > 0.40 ? 3 : (ratio > 0.15 ? 2 : 1))
    }

}
