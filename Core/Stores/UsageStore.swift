import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class UsageStore: QuotaProviderStore {
    static let shared = UsageStore()

    typealias Phase = ProviderPhase

    private(set) var snapshot: UsageSnapshot?
    private(set) var phase: Phase = .idle
    private(set) var isCached = false

    typealias Fetch = @Sendable (_ customPath: String?, _ confirmsEmptyResetCredits: Bool) async throws -> UsageSnapshot

    @ObservationIgnored private let fetchSnapshot: Fetch
    @ObservationIgnored private let defaults: UserDefaults
    /// Nil uses the shared Application Support cache.
    @ObservationIgnored private let snapshotURL: URL?
    @ObservationIgnored private lazy var refreshScheduler = QuotaRefreshScheduler(
        interval: { [defaults] in RefreshInterval.seconds(in: defaults) },
        tick: { [weak self] in Task { await self?.refresh() } }
    )
    @ObservationIgnored private let previewMode: Bool
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI",
        category: "Sync"
    )

    init(
        previewMode: Bool = false,
        previewSnapshot: UsageSnapshot? = nil,
        defaults: UserDefaults = .standard,
        snapshotURL: URL? = nil,
        fetchSnapshot: Fetch? = nil
    ) {
        self.previewMode = previewMode
        self.defaults = defaults
        self.snapshotURL = snapshotURL
        if let fetchSnapshot {
            self.fetchSnapshot = fetchSnapshot
        } else {
            let client = CodexAppServerClient()
            self.fetchSnapshot = { customPath, confirmsEmptyResetCredits in
                try await client.fetch(
                    customPath: customPath,
                    confirmsEmptyResetCredits: confirmsEmptyResetCredits
                )
            }
        }
        if previewMode {
            snapshot = previewSnapshot ?? .preview
            phase = .ready
        } else {
            if let snapshotURL {
                snapshot = try? LocalSnapshotStore.load(from: snapshotURL)
            } else {
                snapshot = try? LocalSnapshotStore.load()
            }
            phase = snapshot == nil ? .idle : .ready
            isCached = snapshot != nil
        }
    }

    var isLoading: Bool { phase == .loading }

    var expiryReferenceDate: Date? { previewMode ? nil : Date() }

    func userRefresh() async {
        await refresh()
    }

    var statusMessage: String {
        statusMessage(at: Date())
    }

    func statusMessage(at now: Date) -> String {
        if previewMode {
            return L10n.text("date.updated_just_now", fallback: "Updated just now")
        }
        switch phase {
        case .idle:
            return L10n.text("status.waiting", fallback: "Waiting to refresh")
        case .loading:
            return L10n.text("status.refreshing", fallback: "Refreshing")
        case .ready:
            return snapshot.map {
                DisplayDateFormatter.updatedText(for: $0.fetchedAt, now: now)
            }
                ?? L10n.text("status.waiting", fallback: "Waiting to refresh")
        case .failed(let message):
            return snapshot == nil
                ? message
                : L10n.format(
                    "status.cached_format",
                    fallback: "Using cache · %@",
                    message
                )
        }
    }

    func start() {
        guard !previewMode, !refreshScheduler.isRunning else { return }
        logger.info("Starting quota refresh loop")
        Task { [weak self] in await self?.refresh() }
        refreshScheduler.start()
    }

    func stop() {
        refreshScheduler.stop()
    }

    func rescheduleRefresh() {
        guard !previewMode else { return }
        refreshScheduler.reschedule()
    }

    func refresh() async {
        guard !previewMode, !isLoading else { return }
        logger.info("Refreshing Codex quota snapshot")
        phase = .loading
        do {
            let customPath = defaults.string(forKey: DefaultsKey.codexBinaryPath)
            let hadResetCredits =
                (snapshot?.availableResetCount ?? 0) > 0
                || snapshot?.resetCredits.isEmpty == false
            let fetched = try await fetchSnapshot(customPath, hadResetCredits)
            let latest = fetched.preservingResetCredits(from: snapshot)
            snapshot = latest
            isCached = false
            phase = .ready
            let snapshotURL = self.snapshotURL
            try await Task.detached(priority: .utility) {
                if let snapshotURL {
                    try LocalSnapshotStore.save(latest, to: snapshotURL)
                } else {
                    try LocalSnapshotStore.save(latest)
                }
            }.value
            logger.info(
                "Quota refresh succeeded; fiveHourPresent=\(latest.fiveHour != nil, privacy: .public), resetCount=\(latest.availableResetCount, privacy: .public), resetDataCurrent=\(latest.hasCurrentResetCreditData, privacy: .public), tokenBuckets=\(latest.dailyUsageBuckets.count, privacy: .public)"
            )
        } catch {
            phase = .failed(error.localizedDescription)
            logger.error("Quota refresh failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
