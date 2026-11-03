import Charts
import SwiftUI

struct QuotaHistoryView: View {
    let model: QuotAIAppModel
    @AppStorage(DefaultsKey.quotaHistory) private var recording = false
    @State private var days = 1
    @State private var selectedProvider = "all"
    @State private var clearConfirmation = false
    @State private var selectedDate: Date?

    private var points: [QuotaHistoryPoint] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let filtered = model.history.filter {
            $0.timestamp >= cutoff && (selectedProvider == "all" || $0.provider.rawValue == selectedProvider)
        }
        let series = Dictionary(grouping: filtered) { "\($0.provider.rawValue)/\($0.groupID)/\($0.window.rawValue)" }
        let maximum = max(20, 600 / max(1, series.count))
        return series.values.flatMap { values -> [QuotaHistoryPoint] in
            guard values.count > maximum else { return values }
            let step = max(1, values.count / maximum)
            // Keep each bucket's extrema, including visible reset jumps.
            return stride(from: 0, to: values.count, by: step).flatMap { index -> [QuotaHistoryPoint] in
                let bucket = values[index..<min(values.count, index + step)]
                let low = bucket.min { $0.remainingPercent < $1.remainingPercent }!
                let high = bucket.max { $0.remainingPercent < $1.remainingPercent }!
                return low.id == high.id ? [low] : [low, high].sorted { $0.timestamp < $1.timestamp }
            }
        }.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("history.title", fallback: "Quota History")).font(.title2.bold())
                Spacer()
                Picker(L10n.text("history.range", fallback: "Range"), selection: $days) {
                    Text(L10n.text("history.day", fallback: "24 hours")).tag(1)
                    Text(L10n.text("history.week", fallback: "7 days")).tag(7)
                    Text(L10n.text("history.month", fallback: "30 days")).tag(30)
                }.labelsHidden().frame(width: 120)
                Picker(L10n.text("quota.provider", fallback: "Quota provider"), selection: $selectedProvider) {
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
            } else if points.isEmpty {
                ContentUnavailableView(
                    L10n.text("history.empty", fallback: "No recorded quota yet"),
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        L10n.text(
                            "history.empty_detail",
                            fallback: "Enable recording, then refresh a provider to start a local history.")))
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Time", point.timestamp), y: .value("Remaining", point.remainingPercent))
                        .foregroundStyle(by: .value("Source", point.series))
                    PointMark(x: .value("Time", point.timestamp), y: .value("Remaining", point.remainingPercent))
                        .foregroundStyle(by: .value("Source", point.series)).symbolSize(12)
                }
                .chartYScale(domain: 0...100)
                .chartXSelection(value: $selectedDate)
                .chartLegend(position: .bottom, alignment: .leading)
                .accessibilityLabel(
                    L10n.text("history.chart", fallback: "Recorded quota remaining, from zero to one hundred percent")
                )
                .frame(minHeight: 260)
                if let selectedDate,
                    let point = points.min(by: {
                        abs($0.timestamp.timeIntervalSince(selectedDate))
                            < abs($1.timestamp.timeIntervalSince(selectedDate))
                    })
                {
                    Text(
                        "\(point.series) · \(point.remainingPercent)% · \(DisplayDateFormatter.compactDateTime(point.timestamp))"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
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
        }
        .padding(22)
        .frame(minWidth: 640, minHeight: 430)
        .task { model.refreshHistory() }
        .confirmationDialog(
            L10n.text("history.clear_confirm", fallback: "Clear all locally recorded quota history?"),
            isPresented: $clearConfirmation
        ) {
            Button(L10n.text("history.clear", fallback: "Clear History"), role: .destructive) { model.clearHistory() }
        }
    }
}
