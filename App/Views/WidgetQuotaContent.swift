import SwiftUI

struct WidgetQuotaContent: View {
    let snapshot: SharedWidgetSnapshot
    let date: Date
    let compact: Bool

    private var rows: [WidgetQuotaRow] {
        Array(snapshot.rows.prefix(compact ? 2 : 6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 5) {
            HStack {
                Label("QuotAI", systemImage: "chart.bar.fill").font(.caption.bold())
                Spacer()
                if snapshot.generatedAt != .distantPast {
                    Text(snapshot.generatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Spacer()
                Text(L10n.text("widget.empty", fallback: "Open QuotAI and enable widget sharing."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(rows) { row in
                    if compact {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(row.title) · \(row.window)").font(.caption2).lineLimit(1)
                                Spacer(minLength: 2)
                                value(row, large: true)
                            }
                            bar(row)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("\(row.title) · \(row.window)").font(.caption2).lineLimit(1).frame(
                                maxWidth: .infinity, alignment: .leading)
                            bar(row).frame(width: 60)
                            value(row, large: false).frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }

    }

    @ViewBuilder
    private func value(_ row: WidgetQuotaRow, large: Bool) -> some View {
        Text(row.displayable(at: date) ? "\(row.remainingPercent)%" : "--")
            .font(large ? .system(.body, design: .rounded).bold() : .caption.bold())
            .monospacedDigit()
            .foregroundStyle(color(row))
            .accessibilityLabel(
                row.displayable(at: date)
                    ? "\(row.title) \(row.window) \(row.remainingPercent)%"
                    : L10n.text("widget.expired", fallback: "Reset time passed; refresh QuotAI"))
    }

    private func bar(_ row: WidgetQuotaRow) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.16))
                if row.displayable(at: date) && row.remainingPercent > 0 {
                    Capsule().fill(color(row)).frame(width: geometry.size.width * Double(row.remainingPercent) / 100)
                }
            }
        }.frame(height: 5)
    }

    private func color(_ row: WidgetQuotaRow) -> Color {
        if !row.displayable(at: date) || row.isStale(at: date) { return .secondary }
        return row.remainingPercent < 20 ? .red : row.remainingPercent < 50 ? .orange : .green
    }
}
