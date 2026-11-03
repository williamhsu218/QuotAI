import Foundation
import Observation
import WidgetKit

@MainActor @Observable
final class QuotaWidgetController {
    private(set) var isAvailable = false
    private(set) var writeFailed = false
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var requestedRows: [WidgetQuotaRow]?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0

    init(url: URL? = WidgetSharedStore.snapshotURL()) {
        self.url = url
        isAvailable = url != nil
    }

    func update(snapshots: [ProviderQuotaSnapshot], preferred: QuotaProvider, groupID: String?, enabled: Bool) {
        guard let url else { return }
        let sorted = snapshots.sorted { ($0.provider == preferred ? 0 : 1) < ($1.provider == preferred ? 0 : 1) }
        let rows =
            enabled
            ? sorted.flatMap { snapshot -> [WidgetQuotaRow] in
                guard let group = snapshot.group(id: snapshot.provider == .antigravity ? groupID : nil) else {
                    return []
                }
                return group.quotas.map {
                    WidgetQuotaRow(
                        id: "\(snapshot.provider.rawValue)/\(group.id)/\($0.kind.rawValue)",
                        providerID: snapshot.provider.rawValue,
                        title: [snapshot.providerName, group.name].filter { !$0.isEmpty }.joined(separator: " · "),
                        window: $0.kind.shortLabel, remainingPercent: $0.remainingPercent,
                        resetsAt: $0.resetsAt, fetchedAt: snapshot.fetchedAt, historical: snapshot.isHistorical)
                }
            } : []
        guard requestedRows != rows else { return }
        requestedRows = rows
        revision &+= 1
        let current = revision
        let previous = writeTask
        writeTask = Task { [weak self] in
            await previous?.value
            guard let self, current == self.revision else { return }
            do {
                try await Task.detached(priority: .utility) {
                    // Disabling sharing clears an existing snapshot, but does
                    // not create one when the feature has never been enabled.
                    if rows.isEmpty && !FileManager.default.fileExists(atPath: url.path) { return }
                    try WidgetSharedStore.write(
                        .init(version: 1, generatedAt: Date(), rows: Array(rows.prefix(64))), to: url)
                }.value
                guard current == self.revision else { return }
                self.writeFailed = false
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.kind)
            } catch { self.writeFailed = true }
        }
    }
}
