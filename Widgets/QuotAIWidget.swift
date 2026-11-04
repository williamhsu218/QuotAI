import AppIntents
import OSLog
import SwiftUI
import WidgetKit

struct QuotaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedWidgetSnapshot
    var selectionID: String? = nil
}

// WidgetKit inspects provider conformance at runtime. A static provider must
// never also conform to AppIntentTimelineProvider: the static configuration
// has no intent and can otherwise be routed through the intent bridge (1103).
struct QuotaWidgetTimeline: TimelineProvider {
    func placeholder(in context: Context) -> QuotaWidgetEntry {
        QuotaWidgetTimelineContent().placeholder(in: context)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (QuotaWidgetEntry) -> Void) {
        let content = QuotaWidgetTimelineContent()
        completion(context.isPreview ? content.placeholder(in: context) : .init(date: Date(), snapshot: content.read()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<QuotaWidgetEntry>) -> Void) {
        completion(
            QuotaWidgetTimelineContent().makeTimeline(kind: WidgetSharedStore.kind, selectionID: nil, in: context))
    }
}

struct SelectableQuotaWidgetTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaWidgetEntry {
        QuotaWidgetTimelineContent().placeholder(in: context)
    }

    func snapshot(for configuration: QuotaWidgetConfiguration, in context: Context) async -> QuotaWidgetEntry {
        let content = QuotaWidgetTimelineContent()
        let snapshot = content.read()
        if context.isPreview && snapshot.rows.isEmpty && configuration.selectionID == nil {
            return content.placeholder(in: context)
        }
        return .init(date: Date(), snapshot: snapshot, selectionID: configuration.selectionID)
    }

    func timeline(for configuration: QuotaWidgetConfiguration, in context: Context) async -> Timeline<QuotaWidgetEntry>
    {
        QuotaWidgetTimelineContent().makeTimeline(
            kind: WidgetSharedStore.selectableKind, selectionID: configuration.selectionID, in: context)
    }
}

private struct QuotaWidgetTimelineContent {
    private let logger = Logger(subsystem: "com.willhsu.QuotAI", category: "WidgetTimeline")
    func placeholder(in context: TimelineProviderContext) -> QuotaWidgetEntry {
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

    func makeTimeline(
        kind: String, selectionID: String?, in context: TimelineProviderContext
    ) -> Timeline<QuotaWidgetEntry> {
        let now = Date()
        let snapshot = read()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        logger.info(
            "Providing widget timeline; build=\(build, privacy: .public), kind=\(kind, privacy: .public), rows=\(snapshot.rows.count, privacy: .public)"
        )
        if !context.isPreview, let url = WidgetSharedStore.snapshotURL() {
            do {
                try WidgetSharedStore.recordTimelineResponse(kind: kind, build: build, at: url)
            } catch {
                logger.error(
                    "Widget response metadata could not be written; code=\((error as NSError).code, privacy: .public)")
            }
        }
        let displayed = snapshot.quotas(selectionID: selectionID)
            .prefix(context.family == .systemSmall ? 1 : 3)
            .flatMap { [$0.fiveHour, $0.sevenDay].compactMap { $0 } }
        let deadlines = displayed.flatMap { row in
            [row.resetsAt, row.fetchedAt.addingTimeInterval(1_800)].compactMap { $0 }
        }.filter { $0 > now && $0 < now.addingTimeInterval(7 * 86_400) }
        let dates = Array(Set([now] + deadlines.map { $0.addingTimeInterval(0.1) })).sorted()
        return Timeline(
            entries: dates.map { .init(date: $0, snapshot: snapshot, selectionID: selectionID) },
            policy: .after(now.addingTimeInterval(900)))
    }

    func read() -> SharedWidgetSnapshot {
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
    // Keep the existing kind static: installed widgets have no intent and
    // cannot be reinterpreted as AppIntentConfiguration (CHSErrorDomain 1103).
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSharedStore.kind, provider: QuotaWidgetTimeline()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(L10n.text("widget.automatic_title", fallback: "QuotAI · Automatic Overview")))
        .description(
            Text(
                L10n.text(
                    "widget.automatic_detail",
                    fallback: "Follows the app. For independent quota selection, add Choose Quota instead."))
        )
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuotAISelectableQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: WidgetSharedStore.selectableKind, intent: QuotaWidgetConfiguration.self,
            provider: SelectableQuotaWidgetTimeline()
        ) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(L10n.text("widget.selectable_title", fallback: "QuotAI · Choose Quota")))
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
    var body: some Widget {
        QuotAISelectableQuotaWidget()
        QuotAIQuotaWidget()
    }
}
