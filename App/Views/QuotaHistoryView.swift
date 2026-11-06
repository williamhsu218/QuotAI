import AppKit
import Charts
import SwiftUI

struct QuotaHistoryView: View {
    let model: QuotAIAppModel
    @AppStorage(DefaultsKey.quotaHistory) private var recording = false
    @State private var filter = HistoryFilter()
    @State private var clearConfirmation = false
    // Cached so that only data, filter and range-aging changes refilter or resample the ledger.
    @State private var content = HistoryContent()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("history.title", fallback: "Quota History")).font(.title2.bold()).lineLimit(1)
                Spacer()
                Picker(L10n.text("history.range", fallback: "Range"), selection: $filter.days) {
                    Text(L10n.text("history.day", fallback: "24 hours")).tag(1)
                    Text(L10n.text("history.week", fallback: "7 days")).tag(7)
                    Text(L10n.text("history.month", fallback: "30 days")).tag(30)
                }.labelsHidden().frame(width: 120)
                Picker(L10n.text("quota.provider", fallback: "Quota provider"), selection: $filter.provider) {
                    Text(L10n.text("history.all", fallback: "All providers")).tag("all")
                    ForEach(model.registry.plugins, id: \.descriptor.id) { plugin in
                        Text(plugin.descriptor.title).tag(plugin.descriptor.id.rawValue)
                    }
                }.labelsHidden().frame(width: 170)
            }
            if let error = model.historyError {
                ContentUnavailableView {
                    Label(error, systemImage: "exclamationmark.triangle")
                } actions: {
                    Button(L10n.text("action.refresh", fallback: "Refresh")) { model.refreshHistory() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if content.rows.isEmpty {
                ContentUnavailableView(
                    L10n.text("history.empty", fallback: "No recorded quota yet"),
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        L10n.text(
                            "history.empty_detail",
                            fallback: "Enable recording, then refresh a provider to start a local history."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Identity follows the filter, so changing it also discards the chart selection.
                HistoryChartSection(content: content).id(content.filter)
                HistoryTableSection(content: content).id(content.filter)
            }
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack {
                    Toggle(L10n.text("history.record", fallback: "Record new quota samples"), isOn: $recording)
                        .toggleStyle(.checkbox)
                        .onChange(of: recording) { model.preferencesDidChange() }
                    Spacer()
                    Button(L10n.text("history.clear", fallback: "Clear History"), role: .destructive) {
                        clearConfirmation = true
                    }
                    .disabled(model.history.isEmpty && model.historyError == nil)
                }
                Text(
                    L10n.text(
                        "history.detail",
                        fallback:
                            "Stored only on this Mac: up to 30 days or 12,000 samples. Pausing keeps existing history. No account IDs or raw responses are recorded."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        // Constant sizing inputs keep the hosting window independent of selection, legend and table contents.
        .frame(
            minWidth: 0, idealWidth: 820, maxWidth: .infinity, minHeight: 0, idealHeight: 720, maxHeight: .infinity,
            alignment: .topLeading
        )
        .onAppear { rebuildContent() }
        .onChange(of: model.history) { rebuildContent() }
        .onChange(of: filter) { rebuildContent() }
        .task {
            model.refreshHistory()
            // The range is relative to now, so samples must age out even when no new data arrives.
            while true {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                rebuildContent()
            }
        }
        .confirmationDialog(
            L10n.text("history.clear_confirm", fallback: "Clear all locally recorded quota history?"),
            isPresented: $clearConfirmation
        ) {
            Button(L10n.text("history.clear", fallback: "Clear History"), role: .destructive) { model.clearHistory() }
        }
    }

    private func rebuildContent() {
        let next = HistoryContent(history: model.history, filter: filter, now: Date())
        if next != content { content = next }
    }
}

private struct HistoryFilter: Hashable {
    var days = 1
    var provider = "all"
}

private struct HistorySeriesStyle: Equatable {
    private static let colors: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .red, .mint, .brown, .cyan
    ]
    private static let dashes: [[CGFloat]] = [[], [5, 3], [1.5, 2.5]]

    let index: Int

    var color: Color { Self.colors[index % Self.colors.count] }
    // Series beyond the palette reuse its colors with a different dash, so they stay distinguishable.
    var stroke: StrokeStyle {
        StrokeStyle(lineWidth: 1.5, dash: Self.dashes[(index / Self.colors.count) % Self.dashes.count])
    }
}

private struct HistorySeries: Identifiable, Equatable {
    let id: String
    let name: String
    let style: HistorySeriesStyle
}

private struct HistorySample: Identifiable, Equatable {
    let id: String
    let series: HistorySeries
    let point: QuotaHistoryPoint
}

private struct HistoryContent: Equatable {
    private(set) var filter = HistoryFilter()
    private(set) var series: [HistorySeries] = []
    /// Extrema-preserving subset for drawing only, oldest first.
    private(set) var chartSamples: [HistorySample] = []
    /// Every sample matching the filter, newest first.
    private(set) var rows: [HistorySample] = []

    var isChartSampled: Bool { chartSamples.count < rows.count }

    init() {}

    init(history: [QuotaHistoryPoint], filter: HistoryFilter, now: Date) {
        self.filter = filter
        let cutoff = now.addingTimeInterval(-Double(filter.days) * 86_400)
        let filtered = history.filter {
            $0.timestamp >= cutoff && (filter.provider == "all" || $0.provider.rawValue == filter.provider)
        }
        series = Self.series(in: filtered, styledAcross: history)
        let seriesByID = Dictionary(uniqueKeysWithValues: series.map { ($0.id, $0) })
        let samples = filtered.compactMap { point in
            seriesByID[point.seriesID].map { HistorySample(id: point.id, series: $0, point: point) }
        }
        let ascending = samples.sorted(by: Self.isOlder)
        rows = samples.sorted(by: Self.isNewer)
        let grouped = Dictionary(grouping: ascending, by: \.series.id)
        let maximum = max(20, 600 / max(1, grouped.count))
        chartSamples = grouped.values.flatMap { Self.downsampled($0, maximum: maximum) }.sorted(by: Self.isOlder)
    }

    /// Styles index the whole ledger so a series keeps its look across filter changes. Names use each series'
    /// latest label, numbered if distinct groups share one, so their chart lines never merge.
    private static func series(
        in points: [QuotaHistoryPoint], styledAcross history: [QuotaHistoryPoint]
    ) -> [HistorySeries] {
        let styleIndexes = Dictionary(
            uniqueKeysWithValues: Set(history.map(\.seriesID)).sorted().enumerated().map { ($1, $0) })
        let latest = Dictionary(points.map { ($0.seriesID, $0) }) { $1.timestamp >= $0.timestamp ? $1 : $0 }
        var nameCounts: [String: Int] = [:]
        return latest.keys.sorted().compactMap { id in
            guard let label = latest[id]?.series, let index = styleIndexes[id] else { return nil }
            let count = nameCounts[label, default: 0] + 1
            nameCounts[label] = count
            return HistorySeries(
                id: id, name: count == 1 ? label : "\(label) (\(count))", style: HistorySeriesStyle(index: index))
        }
    }

    private static func downsampled(_ values: [HistorySample], maximum: Int) -> [HistorySample] {
        guard values.count > maximum else { return values }
        let step = max(1, values.count / maximum)
        // Keep each bucket's extrema, including visible reset jumps.
        return stride(from: 0, to: values.count, by: step).flatMap { index -> [HistorySample] in
            let bucket = values[index..<min(values.count, index + step)]
            let low = bucket.min { $0.point.remainingPercent < $1.point.remainingPercent }!
            let high = bucket.max { $0.point.remainingPercent < $1.point.remainingPercent }!
            return low.id == high.id ? [low] : [low, high]
        }
    }

    private static func isOlder(_ lhs: HistorySample, _ rhs: HistorySample) -> Bool {
        lhs.point.timestamp == rhs.point.timestamp ? lhs.id < rhs.id : lhs.point.timestamp < rhs.point.timestamp
    }

    private static func isNewer(_ lhs: HistorySample, _ rhs: HistorySample) -> Bool {
        lhs.point.timestamp == rhs.point.timestamp ? lhs.id < rhs.id : lhs.point.timestamp > rhs.point.timestamp
    }
}

private extension QuotaHistoryPoint {
    var seriesID: String { "\(provider.rawValue)/\(groupID)/\(window.rawValue)" }
    var quotaLabel: String { [groupName, window.displayName].filter { !$0.isEmpty }.joined(separator: " · ") }
}

private struct HistoryChartSection: View {
    let content: HistoryContent
    @State private var selectedTimestamp: Date?

    // Snaps to sample times, so the chart only redraws when the pointer reaches a different sample.
    private var selection: Binding<Date?> {
        Binding(
            get: { selectedTimestamp },
            set: { date in
                let nearest = date.flatMap { nearestTimestamp(to: $0) }
                if nearest != selectedTimestamp { selectedTimestamp = nearest }
            }
        )
    }

    var body: some View {
        let selected = content.chartSamples.filter { $0.point.timestamp == selectedTimestamp }
        VStack(alignment: .leading, spacing: 6) {
            chart(selected: selected)
            HistoryLegend(series: content.series)
            HistorySelectionDetail(samples: selected)
        }
    }

    private func chart(selected: [HistorySample]) -> some View {
        Chart {
            ForEach(content.chartSamples) { sample in
                LineMark(
                    x: .value("Time", sample.point.timestamp),
                    y: .value("Remaining", sample.point.remainingPercent),
                    series: .value("Source", sample.series.name)
                )
                .foregroundStyle(sample.series.style.color)
                .lineStyle(sample.series.style.stroke)
                PointMark(
                    x: .value("Time", sample.point.timestamp),
                    y: .value("Remaining", sample.point.remainingPercent)
                )
                .foregroundStyle(sample.series.style.color).symbolSize(12)
                .accessibilityHidden(true)
            }
            if let selectedTimestamp {
                RuleMark(x: .value("Selected", selectedTimestamp))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .accessibilityHidden(true)
            }
            ForEach(selected) { sample in
                PointMark(
                    x: .value("Time", sample.point.timestamp),
                    y: .value("Remaining", sample.point.remainingPercent)
                )
                .foregroundStyle(sample.series.style.color).symbolSize(40)
                .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) { Text(verbatim: "\(percent)%") }
                }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: selection)
        .accessibilityLabel(
            L10n.text("history.chart", fallback: "Recorded quota remaining, from zero to one hundred percent")
        )
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 220)
    }

    private func nearestTimestamp(to date: Date) -> Date? {
        content.chartSamples.min {
            abs($0.point.timestamp.timeIntervalSince(date)) < abs($1.point.timestamp.timeIntervalSince(date))
        }?.point.timestamp
    }
}

private struct HistorySeriesSwatch: View {
    let style: HistorySeriesStyle

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 4))
            path.addLine(to: CGPoint(x: 16, y: 4))
        }
        .stroke(style.color, style: style.stroke)
        .frame(width: 16, height: 8)
        .accessibilityHidden(true)
    }
}

private struct HistoryLegend: View {
    let series: [HistorySeries]

    // Legacy scrollers take layout space, while overlay scrollers report zero width.
    private var height: CGFloat {
        22 + NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(series) { item in
                    HStack(spacing: 5) {
                        HistorySeriesSwatch(style: item.style)
                        Text(item.name).lineLimit(1)
                    }
                    .help(item.name)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.name)
                }
            }
            .frame(height: 22)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("history.legend", fallback: "Chart legend"))
    }
}

private struct HistorySelectionDetail: View {
    let samples: [HistorySample]

    var body: some View {
        let descriptions = samples.map {
            "\($0.series.name) · \($0.point.remainingPercent)% · "
                + DisplayDateFormatter.compactDateTime($0.point.timestamp)
        }
        HStack(spacing: 6) {
            if let first = samples.first {
                HistorySeriesSwatch(style: first.series.style)
                Text(first.series.name).lineLimit(1).truncationMode(.middle)
                Group {
                    Text(verbatim: "· \(first.point.remainingPercent)% ·").monospacedDigit()
                    Text(DisplayDateFormatter.compactDateTime(first.point.timestamp))
                    if samples.count > 1 {
                        Text(
                            L10n.format(
                                "history.selection_more_format", fallback: "+%d more", samples.count - 1))
                    }
                }
                .lineLimit(1)
                .fixedSize()
            } else {
                Text(L10n.text("history.selection_hint", fallback: "Point at the chart to inspect a sample."))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(height: 18)
        .help(descriptions.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            samples.isEmpty
                ? L10n.text("history.selection_hint", fallback: "Point at the chart to inspect a sample.")
                : descriptions.joined(separator: "; "))
    }
}

private struct HistoryTableSection: View {
    let content: HistoryContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(
                    L10n.format(
                        "history.table_count_format", fallback: "All samples in this range: %d", content.rows.count))
                Spacer(minLength: 0)
                if content.isChartSampled {
                    let note = L10n.text(
                        "history.chart_sampled",
                        fallback: "Chart is simplified for display; the table lists every sample.")
                    Text(note).help(note)
                }
            }
            .lineLimit(1)
            .font(.caption).foregroundStyle(.secondary)
            .frame(height: 16)
            Table(content.rows) {
                TableColumn(L10n.text("history.column_recorded", fallback: "Recorded")) { row in
                    HistoryDateCell(date: row.point.timestamp)
                }
                .width(min: 96, ideal: 116)
                TableColumn(L10n.text("history.column_provider", fallback: "Provider")) { row in
                    HistoryTextCell(text: row.point.providerName)
                }
                .width(min: 72, ideal: 110)
                TableColumn(L10n.text("history.column_quota", fallback: "Model / Window")) { row in
                    HistoryTextCell(text: row.point.quotaLabel)
                }
                .width(min: 120, ideal: 210)
                TableColumn(L10n.text("history.column_remaining", fallback: "Remaining")) { row in
                    HistoryRemainingCell(percent: row.point.remainingPercent)
                }
                .width(min: 100, ideal: 110, max: 130)
                TableColumn(L10n.text("history.column_reset", fallback: "Resets")) { row in
                    HistoryDateCell(date: row.point.resetsAt)
                }
                .width(min: 96, ideal: 116)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .accessibilityLabel(L10n.text("history.table", fallback: "Recorded quota samples, newest first"))
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
        }
    }
}

private struct HistoryTextCell: View {
    let text: String
    var fullText: String?

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
            .help(fullText ?? text)
            .accessibilityLabel(fullText ?? text)
    }
}

private struct HistoryDateCell: View {
    let date: Date?

    var body: some View {
        HistoryTextCell(
            text: DisplayDateFormatter.compactDateTime(date),
            fullText: date == nil ? L10n.text("date.reset_unknown", fallback: "Reset time unknown") : nil)
    }
}

private struct HistoryRemainingCell: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(percent)%")
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 38, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.track)
                Capsule()
                    .fill(AppTheme.quotaPalette(for: percent).accent)
                    .frame(width: 44 * CGFloat(min(100, max(0, percent))) / 100)
            }
            .frame(width: 44, height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format("history.remaining_accessibility_format", fallback: "Remaining %d%%", percent)
        )
        .accessibilityValue(Text(verbatim: "\(percent)%"))
    }
}
