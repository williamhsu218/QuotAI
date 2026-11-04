import AppIntents
import Foundation

struct QuotaWidgetConfiguration: WidgetConfigurationIntent {
    static let title = LocalizedStringResource("widget.configuration_title", defaultValue: "Choose Quota")
    static let description = IntentDescription(
        LocalizedStringResource(
            "widget.configuration_detail",
            defaultValue: "Choose a quota for this widget, or follow the app automatically."))

    @Parameter(title: LocalizedStringResource("widget.selection", defaultValue: "Quota"))
    var quota: WidgetQuotaEntity?

    static var parameterSummary: some ParameterSummary { Summary { \.$quota } }

    var selectionID: String? {
        guard let quota, quota.id != WidgetQuotaEntity.automaticID else { return nil }
        return quota.id
    }
}

struct WidgetQuotaEntity: AppEntity {
    static let automaticID = "__automatic__"
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("widget.selection", defaultValue: "Quota"))
    static let defaultQuery = WidgetQuotaQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var automatic: Self {
        .init(id: automaticID, name: L10n.text("widget.automatic", fallback: "Automatic overview"))
    }
}

struct WidgetQuotaQuery: EntityQuery {
    private let snapshotURL: URL?

    init() { snapshotURL = WidgetSharedStore.snapshotURL() }

    init(snapshotURL: URL?) { self.snapshotURL = snapshotURL }

    func entities(for identifiers: [String]) async throws -> [WidgetQuotaEntity] {
        let choices = availableChoices()
        // Preserve the saved selection through an empty cache, opt-out or a
        // temporarily missing model. Never silently select another quota.
        return identifiers.map { id in
            choices.first { $0.id == id }
                ?? .init(id: id, name: L10n.text("widget.unavailable_quota", fallback: "Unavailable quota"))
        }
    }

    func suggestedEntities() async throws -> [WidgetQuotaEntity] { availableChoices() }

    func defaultResult() async -> WidgetQuotaEntity? { .automatic }

    private func availableChoices() -> [WidgetQuotaEntity] {
        let snapshot = (try? WidgetSharedStore.read(from: snapshotURL)) ?? .empty
        return [.automatic]
            + snapshot.quotaChoices.map { quota in
                .init(id: quota.id, name: [quota.name, quota.detail].compactMap { $0 }.joined(separator: " · "))
            }
    }
}
