import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AntigravityUsageStore: QuotaProviderStore {
    static let shared = AntigravityUsageStore()

    typealias Phase = ProviderPhase

    private(set) var snapshot: AntigravityQuotaSnapshot?
    private(set) var phase: Phase = .idle
    private(set) var isEnabled = false
    private(set) var isInstalled: Bool

    @ObservationIgnored private let fetchSnapshot: @Sendable () async throws -> AntigravityQuotaSnapshot
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private lazy var refreshScheduler = QuotaRefreshScheduler(
        interval: { [defaults] in RefreshInterval.seconds(in: defaults) },
        tick: { [weak self] in Task { await self?.refresh() } }
    )
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let previewMode: Bool
    @ObservationIgnored private let detectInstallation: @Sendable () -> Bool
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI",
        category: "AntigravitySync"
    )

    init(
        previewMode: Bool = false,
        previewSnapshot: AntigravityQuotaSnapshot? = nil,
        previewFailure: String? = nil,
        defaults: UserDefaults = .standard,
        fetchSnapshot: @escaping @Sendable () async throws -> AntigravityQuotaSnapshot = {
            try await AntigravityQuotaClient.shared.fetch()
        },
        installationDetector: @escaping @Sendable () -> Bool = {
            ProviderInstallationDetector.antigravity(cache: .shared)
        }
    ) {
        self.previewMode = previewMode
        self.defaults = defaults
        self.fetchSnapshot = fetchSnapshot
        self.detectInstallation = installationDetector
        self.isInstalled = previewMode || installationDetector()
        if previewMode {
            snapshot = previewFailure == nil ? previewSnapshot ?? .preview : nil
            phase = previewFailure.map(Phase.failed) ?? .ready
            snapshot?.reconcileUnavailableSelections(in: defaults)
            isEnabled = true
        }
    }

    var isLoading: Bool { phase == .loading }
    var isAvailable: Bool { snapshot != nil }
    var expiryReferenceDate: Date? { previewMode ? nil : Date() }

    /// Manual and periodic refreshes use the same live quota source.
    func userRefresh() async {
        reloadInstallation()
        guard isInstalled else { return }
        await refresh()
    }

    func reloadInstallation() {
        guard !previewMode else { return }
        let detected = detectInstallation()
        guard detected != isInstalled else { return }
        generation &+= 1
        isInstalled = detected
        snapshot = nil
        phase = .idle
    }

    var statusMessage: String {
        statusMessage(at: Date())
    }

    func statusMessage(at now: Date) -> String {
        if previewMode {
            if case let .failed(message) = phase { return message }
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
            } ?? L10n.text("status.waiting", fallback: "Waiting to refresh")
        case let .failed(message):
            return message
        }
    }

    func start() {
        guard !previewMode else { return }
        reloadInstallation()
        isEnabled = true
        guard !refreshScheduler.isRunning else { return }
        logger.info("Starting Antigravity quota refresh loop")
        Task { [weak self] in await self?.refresh() }
        refreshScheduler.start()
    }

    func rescheduleRefresh() {
        guard !previewMode, isEnabled else { return }
        refreshScheduler.reschedule()
    }

    func stop() {
        guard !previewMode else { return }
        generation &+= 1
        isEnabled = false
        refreshScheduler.stop()
        snapshot = nil
        phase = .idle
        logger.info("Stopped Antigravity quota refresh loop")
    }

    func refresh() async {
        guard !previewMode else { return }
        reloadInstallation()
        guard isEnabled, isInstalled, !isLoading else { return }
        logger.info("Refreshing Antigravity quota snapshot")
        phase = .loading
        let expectedGeneration = generation
        do {
            let refreshedSnapshot = try await fetchSnapshot()
            reloadInstallation()
            guard isEnabled, isInstalled, generation == expectedGeneration else { return }
            snapshot = refreshedSnapshot
            refreshedSnapshot.reconcileUnavailableSelections(in: defaults)
            phase = .ready
        } catch {
            reloadInstallation()
            guard isEnabled, isInstalled, generation == expectedGeneration else { return }
            // Antigravity quota is deliberately not cached or retained on a
            // failed refresh. Unavailable must never look like a zero balance.
            snapshot = nil
            phase = .failed(error.localizedDescription)
            logger.error(
                "Antigravity quota refresh failed: \(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }
}
