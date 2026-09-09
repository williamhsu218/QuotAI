import SwiftUI

struct AntigravityTokenUsageView: View {
    let store: AntigravityTokenStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(L10n.text("ag_tokens.title", fallback: "Local tokens"))
                    .font(.system(size: AppTheme.TypeSize.cardTitle, weight: .semibold))
                Text(L10n.text("ag_tokens.all_models", fallback: "All models"))
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.secondaryText)
                    .help(L10n.text("ag_tokens.scope", fallback: "Total = recorded input + output + cache hits. Output includes thinking. Local retained sessions only, not account-wide or billed usage."))
                if store.failed || store.snapshot?.isCalendarPartial == true {
                    Text(L10n.text(store.failed ? "ag_tokens.stale_badge" : "ag_tokens.partial_badge",
                                   fallback: store.failed ? "Not updated" : "Partial"))
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help(status)
                }
                Spacer(minLength: 4)
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel(L10n.text("ag_tokens.loading", fallback: "Reading local token metadata…"))
                } else {
                    Button {
                        Task(priority: .utility) { await store.refresh() }
                    } label: {
                        Label(L10n.text(store.snapshot?.pendingFiles ?? 0 > 0 ? "ag_tokens.continue" : "action.refresh",
                            fallback: "Read usage"), systemImage: "arrow.clockwise")
                            .font(.system(size: AppTheme.TypeSize.small))
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("antigravity.tokenUsage.refresh")
                    .foregroundStyle(AppTheme.cyan)
                    .help(status + "\n" + L10n.text("ag_tokens.on_demand", fallback: "Reads a bounded batch only on demand. No background polling."))
                }
            }
            .lineLimit(1)

            if let snapshot = store.snapshot, snapshot.generations > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(AntigravityTokenFormat.millions(snapshot.total))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityIdentifier("antigravity.tokenUsage.total")
                    Text(L10n.text("ag_tokens.includes_cache", fallback: "incl. cache"))
                        .font(.system(size: AppTheme.TypeSize.small))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize()
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
                            Text(AntigravityTokenFormat.millions(model.total))
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

            if let snapshot = store.snapshot, snapshot.files > 0 {
                AntigravityTokenCalendarView(snapshot: snapshot, stale: store.failed)
                    .padding(.top, 3)
            }

            if store.snapshot == nil || store.snapshot?.files == 0 {
                Text(status)
                    .font(.system(size: AppTheme.TypeSize.small))
                    .foregroundStyle(store.failed ? Color.orange : AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(AppTheme.primaryText)
        .padding(AppTheme.Spacing.compact)
        .appCardSurface(cornerRadius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("antigravity.tokenUsage")
    }

    private func tokenMetric(_ key: String, fallback: String, tokens: Int64, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(key, fallback: fallback))
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.secondaryText)
            Text(AntigravityTokenFormat.millions(tokens))
                .font(.system(size: AppTheme.TypeSize.small, weight: .medium))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("antigravity.tokenUsage.\(id)")
    }

    private var status: String {
        let summary = readStatus
        guard let snapshot = store.snapshot, snapshot.undatedGenerations > 0 else { return summary }
        return summary + " · " + L10n.format("ag_tokens.undated_format", fallback: "%d undated calls", snapshot.undatedGenerations)
    }

    private var readStatus: String {
        if store.failed {
            return L10n.text("ag_tokens.unavailable", fallback: "Local data unavailable. Previous counts have not been refreshed.")
        }
        guard let snapshot = store.snapshot else {
            return L10n.text(store.isLoading ? "ag_tokens.loading" : "ag_tokens.on_demand", fallback: "Read on demand")
        }
        if snapshot.files == 0 {
            return L10n.text("ag_tokens.empty", fallback: "No supported local conversation databases.")
        }
        if snapshot.isPartial {
            if snapshot.limited && snapshot.pendingFiles == 0 {
                return L10n.text("ag_tokens.limited", fallback: "Only part of the local history fits within the safety limit.")
            }
            return L10n.format("ag_tokens.partial_format", fallback: "%d calls recorded · %d sessions pending · %d records excluded",
                               snapshot.generations, snapshot.pendingFiles, snapshot.skippedRecords)
        }
        return L10n.format("ag_tokens.complete_format", fallback: "%d calls recorded · updated on demand",
                           snapshot.generations)
    }
}

/// Native 18 × 7 grid. Hover and selection use only the in-memory snapshot.
private struct AntigravityTokenCalendarView: View {
    let snapshot: AntigravityTokenSnapshot
    let stale: Bool
    private let weeks: [AntigravityTokenWeek]
    private let peak: Int64
    @State private var hoveredID: String?
    @State private var selectedID: String?
    private let cellSize: CGFloat = 11
    private let gap: CGFloat = 2.8

    init(snapshot: AntigravityTokenSnapshot, stale: Bool) {
        self.snapshot = snapshot; self.stale = stale
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
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(AppTheme.secondaryText.opacity(0.7), style: StrokeStyle(lineWidth: 0.6, dash: [1.5, 1]))
                    .frame(width: 8, height: 8)
                Text(L10n.text("ag_tokens.calendar_unknown", fallback: "Unknown"))
                Spacer(minLength: 2)
                Text("0 M")
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 1.5).fill(color(level)).frame(width: 8, height: 8)
                }
                Text(L10n.text("usage.legend_more", fallback: "More"))
            }
            .font(.system(size: 9))
            .foregroundStyle(AppTheme.secondaryText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("ag_tokens.calendar_legend", fallback: "Darker means more tokens. Dashed cells are incomplete, not zero."))
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
                RoundedRectangle(cornerRadius: 2.2)
                    .fill(day.tokens == nil ? Color.clear : color(level(day.tokens ?? 0)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2.2)
                            .strokeBorder(active ? AppTheme.primaryText : (day.isToday ? AppTheme.cyan : AppTheme.secondaryText.opacity(0.5)),
                                style: StrokeStyle(lineWidth: active || day.isToday ? 1 : 0.5,
                                                   dash: day.isPartial || stale ? [1.5, 1] : []))
                    }
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
        let value = AntigravityTokenFormat.millions(tokens)
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

    private func color(_ level: Int) -> Color {
        switch level {
        case 1: return AppTheme.cyan.opacity(0.32)
        case 2: return AppTheme.cyan.opacity(0.55)
        case 3: return AppTheme.cyan.opacity(0.78)
        case 4: return AppTheme.cyan
        default: return AppTheme.track
        }
    }
}
