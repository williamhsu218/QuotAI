import AppKit
import SwiftUI
import WidgetKit

struct WidgetQuotaContent: View {
    let snapshot: SharedWidgetSnapshot
    let date: Date
    let compact: Bool
    var selectionID: String? = nil

    private var providers: [WidgetProviderQuota] {
        Array(snapshot.quotas(selectionID: selectionID).prefix(compact ? 1 : 3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("QuotAI").font(.caption.weight(.semibold))
                Spacer()
                if snapshot.generatedAt != .distantPast {
                    Text(snapshot.generatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if providers.isEmpty {
                Spacer()
                Text(
                    selectionID == nil
                        ? L10n.text("widget.empty", fallback: "Open QuotAI and enable widget sharing.")
                        : L10n.text(
                            "widget.selection_unavailable",
                            fallback: "Selected quota unavailable. Refresh QuotAI or edit this widget.")
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                GeometryReader { geometry in
                    let diameter = max(
                        40,
                        min(
                            compact ? 88 : 76, geometry.size.height - 40,
                            (geometry.size.width - Double(providers.count - 1) * 8) / Double(providers.count) - 8))
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(providers) { provider in
                            WidgetProviderRings(provider: provider, date: date, diameter: diameter)
                                .frame(maxWidth: .infinity)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }
}

private struct WidgetProviderRings: View {
    let provider: WidgetProviderQuota
    let date: Date
    let diameter: Double

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                ring(provider.sevenDay, width: 5).frame(width: diameter, height: diameter)
                ring(provider.fiveHour, width: 4).frame(width: diameter * 0.71, height: diameter * 0.71)
                logo.frame(width: diameter * 0.29, height: diameter * 0.29).accessibilityHidden(true)
            }.frame(width: diameter, height: diameter)
            VStack(spacing: 2) {
                Text(provider.name).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(provider.detail ?? " ").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    metric("7d", provider.sevenDay)
                    metric("5h", provider.fiveHour)
                }.font(.system(size: 9, weight: .medium, design: .rounded)).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [provider.name, provider.detail, spoken("7d", provider.sevenDay), spoken("5h", provider.fiveHour)]
                .compactMap { $0 }.joined(separator: ", "))
    }

    private func ring(_ row: WidgetQuotaRow?, width: Double) -> some View {
        let available = row?.displayable(at: date) == true
        return ZStack {
            Circle().stroke(
                .secondary.opacity(available ? 0.16 : 0.12),
                style: StrokeStyle(lineWidth: width, dash: available ? [] : [2, 3]))
            if let row, available, row.remainingPercent > 0 {
                Circle().trim(from: 0, to: Double(row.remainingPercent) / 100)
                    .stroke(color(row), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let image = WidgetProviderMarks.image(for: provider.providerID) {
            let mark = Image(nsImage: image).renderingMode(provider.providerID == "codex" ? .template : .original)
                .resizable().interpolation(.high)
            if #available(macOS 15.0, *) {
                mark.widgetAccentedRenderingMode(provider.providerID == "codex" ? nil : .fullColor)
                    .scaledToFit().foregroundStyle(.primary)
            } else {
                mark.scaledToFit().foregroundStyle(.primary)
            }
        } else {
            Image(systemName: "sparkles").resizable().scaledToFit().foregroundStyle(.primary)
        }
    }

    private func metric(_ window: String, _ row: WidgetQuotaRow?) -> some View {
        HStack(spacing: 2) {
            Text(window).foregroundStyle(.secondary)
            Text(value(row)).foregroundStyle(color(row))
        }
    }

    private func value(_ row: WidgetQuotaRow?) -> String {
        guard let row, row.displayable(at: date) else { return "--" }
        return "\(row.remainingPercent)%"
    }

    private func spoken(_ window: String, _ row: WidgetQuotaRow?) -> String {
        let historical =
            row?.isStale(at: date) == true
            ? L10n.text("widget.historical", fallback: "Previous query") : ""
        return [window, value(row), historical].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func color(_ row: WidgetQuotaRow?) -> Color {
        guard let row, row.displayable(at: date), !row.isStale(at: date) else { return .secondary }
        return row.remainingPercent < 20 ? .red : row.remainingPercent < 50 ? .orange : .green
    }
}

@MainActor
private enum WidgetProviderMarks {
    static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for (id, name) in [
            ("codex", "CodexProviderMark"), ("antigravity", "AntigravityProviderMark"),
            ("claudeCode", "ClaudeProviderMark")
        ] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url)
            {
                result[id] = image
            }
        }
        return result
    }()

    static func image(for provider: String) -> NSImage? { images[provider] }
}
