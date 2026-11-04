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
        guard recoveryTask == nil else { return }
        isRecovering = true
        reloadRequested = false
        recoveryFailed = false
        let bundleURL = Bundle.main.bundleURL
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRecovering = false
                self.recoveryTask = nil
            }
            let before = await WidgetConfigurationQuery.value()
            guard !Task.isCancelled else { return }
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            for attempt in 1...2 {
                guard !Task.isCancelled else { return }
                let result = await WidgetExtensionRecovery.perform(bundleURL: bundleURL)
                guard !Task.isCancelled else { return }
                // Require fresh replies from this build after the old process
                // exits, rather than previously cached timeline responses.
                let request = self.url.flatMap { try? WidgetSharedStore.beginRecovery(at: $0, build: build) }
                // Recovery is independent of shared-data access. Republish
                // without querying providers or enabling quota sharing.
                if let rows = self.requestedRows { self.publish(rows) }
                await self.writeTask?.value
                for delay in [0, 3, 12] {
                    if delay > 0 {
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    }
                    guard !Task.isCancelled else { return }
                    self.reloadTimelines()
                    self.reloadRequested = true
                    if let before, !before.isEmpty,
                        before.isSubset(of: self.respondingKinds(request))
                    {
                        break
                    }
                }
                let after = await WidgetConfigurationQuery.value()
                guard !Task.isCancelled else { return }
                let responses = self.respondingKinds(request)
                let verified =
                    result.extensionReady
                    && WidgetRecoveryPolicy.responsesConfirmRecovery(
                        before: before, after: after, responses: responses)
                self.logger.info(
                    "Widget recovery attempt=\(attempt, privacy: .public), extensionReady=\(result.extensionReady, privacy: .public), recycled=\(result.recycledProcesses, privacy: .public), configuredBefore=\((before ?? []).sorted().joined(separator: ","), privacy: .public), configuredAfter=\((after ?? []).sorted().joined(separator: ","), privacy: .public), respondingKinds=\(responses.count, privacy: .public), verified=\(verified, privacy: .public)"
                )
                if verified {
                    if let installation {
                        UserDefaults.standard.set(installation, forKey: DefaultsKey.widgetRecoveredInstallation)
                    }
                    self.recoveryFailed = false
                    return
                }
            }
            self.recoveryFailed = true
            self.logger.error("Widget recovery has no verified response; leaving installation eligible for retry")
        }
    }

    private func respondingKinds(_ request: WidgetSharedStore.RecoveryRequest?) -> Set<String> {
        guard let request, let url else { return [] }
        return WidgetSharedStore.respondingKinds(to: request, at: url)
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

/// A broken WidgetKit callback must never prevent extension recovery. The
/// timeout and late callback share a single, lock-protected continuation.
enum WidgetConfigurationQuery {
    static func value(
        timeout: TimeInterval = 2,
        request: @Sendable (@escaping @Sendable (Set<String>?) -> Void) -> Void = { completion in
            WidgetCenter.shared.getCurrentConfigurations { result in
                completion(try? Set(result.get().map(\.kind)).intersection(WidgetSharedStore.kinds))
            }
        }
    ) async -> Set<String>? {
        await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { reply.finish(nil) }
            request { reply.finish($0) }
        }
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Set<String>?, Never>?

        init(_ continuation: CheckedContinuation<Set<String>?, Never>) {
            self.continuation = continuation
        }

        func finish(_ result: Set<String>?) {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(returning: result)
        }
    }
}
