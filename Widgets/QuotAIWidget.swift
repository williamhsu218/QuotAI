import OSLog
import SwiftUI
import WidgetKit

struct QuotaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedWidgetSnapshot
}

struct QuotaWidgetTimeline: TimelineProvider {
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

    func getSnapshot(in context: Context, completion: @escaping (QuotaWidgetEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(.init(date: Date(), snapshot: read()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = read()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        logger.info(
            "Providing widget timeline; build=\(build, privacy: .public), rows=\(snapshot.rows.count, privacy: .public)"
        )
        let deadlines = snapshot.rows.flatMap { row in
            [row.resetsAt, row.fetchedAt.addingTimeInterval(1_800)].compactMap { $0 }
        }.filter { $0 > now && $0 < now.addingTimeInterval(7 * 86_400) }
        let dates = Array(Set([now] + deadlines.map { $0.addingTimeInterval(0.1) })).sorted()
        completion(
            Timeline(
                entries: dates.map { .init(date: $0, snapshot: snapshot) }, policy: .after(now.addingTimeInterval(900)))
        )
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
        WidgetQuotaContent(snapshot: entry.snapshot, date: entry.date, compact: family == .systemSmall)
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
        StaticConfiguration(kind: WidgetSharedStore.kind, provider: QuotaWidgetTimeline()) { entry in
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
