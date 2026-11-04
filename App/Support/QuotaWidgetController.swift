import Foundation
import OSLog
import Observation
import WidgetKit

@MainActor @Observable
final class QuotaWidgetController {
    private(set) var isAvailable = false
    private(set) var writeFailed = false
    private(set) var isRecovering = false
    private(set) var reloadRequested = false
    private(set) var recoveryFailed = false
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var requestedRows: [WidgetQuotaRow]?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.willhsu.QuotAI", category: "WidgetRecovery")

    init(url: URL? = WidgetSharedStore.snapshotURL()) {
        self.url = url
        isAvailable = url != nil
    }

    func recoverAfterUpgradeIfNeeded() {
        let installation =
            "\(Bundle.main.bundleURL.resolvingSymlinksInPath().path):\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")"
        guard UserDefaults.standard.string(forKey: DefaultsKey.widgetRecoveredInstallation) != installation else {
            return
        }
        repair(installation: installation)
    }

    func repair(installation: String? = nil) {
        guard isAvailable, recoveryTask == nil else { return }
        isRecovering = true
        reloadRequested = false
        recoveryFailed = false
        let bundleURL = Bundle.main.bundleURL
        recoveryTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                WidgetExtensionRecovery.perform(bundleURL: bundleURL)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.recoveryFailed = !result.registered
            if result.registered, let installation {
                UserDefaults.standard.set(installation, forKey: DefaultsKey.widgetRecoveredInstallation)
            }
            // Republish the latest intent, including an empty snapshot when
            // sharing is off. Never query providers or turn sharing on here.
            if let rows = self.requestedRows { self.publish(rows) }
            await self.writeTask?.value
            for delay in [0, 3, 12] {
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                }
                guard !Task.isCancelled else { break }
                self.reloadTimelines()
                self.logger.info(
                    "Requested post-upgrade widget timeline; recycled=\(result.recycledProcesses, privacy: .public)")
                self.reloadRequested = true
            }
            self.isRecovering = false
            self.recoveryTask = nil
        }
    }

    func stop() {
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
    }

    func update(snapshots: [ProviderQuotaSnapshot], preferred: QuotaProvider, groupID: String?, enabled: Bool) {
        guard isAvailable else { return }
        let sorted = snapshots.sorted { ($0.provider == preferred ? 0 : 1) < ($1.provider == preferred ? 0 : 1) }
        let rows =
            enabled
            ? sorted.flatMap { snapshot -> [WidgetQuotaRow] in
                let primary = snapshot.group(id: snapshot.provider == .antigravity ? groupID : nil)?.id
                let groups = snapshot.groups.sorted { ($0.id == primary ? 0 : 1) < ($1.id == primary ? 0 : 1) }
                return groups.flatMap { group in
                    group.quotas.map {
                        WidgetQuotaRow(
                            id: "\(snapshot.provider.rawValue)/\(group.id)/\($0.kind.rawValue)",
                            providerID: snapshot.provider.rawValue,
                            title: [snapshot.providerName, group.name].filter { !$0.isEmpty }.joined(separator: " · "),
                            window: $0.kind.shortLabel, remainingPercent: $0.remainingPercent,
                            resetsAt: $0.resetsAt, fetchedAt: snapshot.fetchedAt, historical: snapshot.isHistorical,
                            groupID: group.id, isPrimary: group.id == primary)
                    }
                }
            } : []
        guard requestedRows != rows || writeFailed else { return }
        requestedRows = rows
        publish(rows)
    }

    private func publish(_ rows: [WidgetQuotaRow]) {
        guard let url else { return }
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
                self.reloadTimelines()
            } catch {
                guard current == self.revision else { return }
                self.writeFailed = true
            }
        }
    }

    private func reloadTimelines() {
        for kind in WidgetSharedStore.kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }
}
