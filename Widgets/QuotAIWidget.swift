import AppIntents
import OSLog
import SwiftUI
import WidgetKit

struct QuotaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedWidgetSnapshot
    var selectionID: String? = nil
}

struct QuotaWidgetTimeline: AppIntentTimelineProvider {
    private let logger = Logger(subsystem: "com.willhsu.QuotAI", category: "WidgetTimeline")
    func placeholder(in context: Context) -> QuotaWidgetEntry {
        let now = Date()
        return .init(
            date: now,
            snapshot: .init(
                version: 1, generatedAt: now,
                rows: [
                    .init(
                        id: "placeholder/5h", providerID: "codex", title: "Codex", window: "5h", remainingPercent: 82,
                        resetsAt: now.addingTimeInterval(3_600), fetchedAt: now, historical: false),
                    .init(
                        id: "placeholder/7d", providerID: "codex", title: "Codex", window: "7d", remainingPercent: 93,
                        resetsAt: now.addingTimeInterval(86_400), fetchedAt: now, historical: false)
                ]))
    }

    func snapshot(for configuration: QuotaWidgetConfiguration, in context: Context) async -> QuotaWidgetEntry {
        let snapshot = read()
        if context.isPreview && snapshot.rows.isEmpty && configuration.selectionID == nil {
            return placeholder(in: context)
        }
        return .init(date: Date(), snapshot: snapshot, selectionID: configuration.selectionID)
    }

    func timeline(for configuration: QuotaWidgetConfiguration, in context: Context) async -> Timeline<QuotaWidgetEntry>
    {
        let now = Date()
        let snapshot = read()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        logger.info(
            "Providing widget timeline; build=\(build, privacy: .public), rows=\(snapshot.rows.count, privacy: .public)"
        )
        let displayed = snapshot.quotas(selectionID: configuration.selectionID)
            .prefix(context.family == .systemSmall ? 1 : 3)
            .flatMap { [$0.fiveHour, $0.sevenDay].compactMap { $0 } }
        let deadlines = displayed.flatMap { row in
            [row.resetsAt, row.fetchedAt.addingTimeInterval(1_800)].compactMap { $0 }
        }.filter { $0 > now && $0 < now.addingTimeInterval(7 * 86_400) }
        let dates = Array(Set([now] + deadlines.map { $0.addingTimeInterval(0.1) })).sorted()
        return Timeline(
            entries: dates.map { .init(date: $0, snapshot: snapshot, selectionID: configuration.selectionID) },
            policy: .after(now.addingTimeInterval(900)))
    }

    private func read() -> SharedWidgetSnapshot {
        do {
            guard let url = WidgetSharedStore.snapshotURL() else {
                logger.error("Widget shared container is unavailable")
                return .empty
            }
            return try WidgetSharedStore.read(from: url)
        } catch {
            logger.error("Widget snapshot read failed; code=\((error as NSError).code, privacy: .public)")
            return .empty
        }
    }
}

struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaWidgetEntry

    var body: some View {
        WidgetQuotaContent(
            snapshot: entry.snapshot, date: entry.date, compact: family == .systemSmall,
            selectionID: entry.selectionID
        )
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(
            URL(
                string:
                    "\(Bundle.main.object(forInfoDictionaryKey: "QuotAIURLScheme") as? String ?? "quotai")://panel")
        )
    }
}

struct QuotAIQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: WidgetSharedStore.kind, intent: QuotaWidgetConfiguration.self,
            provider: QuotaWidgetTimeline()
        ) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(L10n.text("widget.gallery_title", fallback: "QuotAI Quota")))
        .description(
            Text(
                L10n.text(
                    "widget.gallery_detail", fallback: "Last queried quotas from QuotAI. Open the app to refresh."))
        )
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct QuotAIWidgets: WidgetBundle {
    var body: some Widget { QuotAIQuotaWidget() }
}
