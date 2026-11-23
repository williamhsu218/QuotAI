import Foundation
import OSLog
import Observation

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
    @ObservationIgnored private let fetchCLISubscriptionPlan: @Sendable () async throws -> SubscriptionPlan?
    @ObservationIgnored private let cliPlanRefreshInterval: TimeInterval
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private lazy var refreshScheduler = QuotaRefreshScheduler(
        interval: { [defaults] in RefreshInterval.seconds(in: defaults) },
        tick: { [weak self] in Task { await self?.refresh() } }
    )
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var cliSubscriptionPlan: SubscriptionPlan?
    @ObservationIgnored private var nextCLIPlanRefresh: Date?
    @ObservationIgnored private var cliPlanTask: Task<Void, Never>?
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
        fetchCLISubscriptionPlan: @escaping @Sendable () async throws -> SubscriptionPlan? = {
            try await AntigravityCLI.fetchSubscriptionPlan()
        },
        cliPlanRefreshInterval: TimeInterval = 1_800,
        installationDetector: @escaping @Sendable () -> Bool = {
            ProviderInstallationDetector.antigravity(cache: .shared)
        }
    ) {
        self.previewMode = previewMode
        self.defaults = defaults
        self.fetchSnapshot = fetchSnapshot
        self.fetchCLISubscriptionPlan = fetchCLISubscriptionPlan
        self.cliPlanRefreshInterval = cliPlanRefreshInterval
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
        await refresh(forcePlanRefresh: true)
    }

    func reloadInstallation() {
        guard !previewMode else { return }
        let detected = detectInstallation()
        guard detected != isInstalled else { return }
        generation &+= 1
        resetCLIPlanState()
        isInstalled = detected
        snapshot = nil
        phase = .idle
    }

    var statusMessage: String {
        statusMessage(at: Date())
    }

    func statusMessage(at now: Date) -> String {
        if previewMode {
            if case .failed(let message) = phase { return message }
            return L10n.text("date.updated_just_now", fallback: "Updated just now")
        }
        switch phase {
        case .idle:
            return L10n.text("status.waiting", fallback: "Waiting to refresh")
        case .loading:
            return L10n.text("status.refreshing", fallback: "Refreshing")
        case .ready:
            guard let snapshot else { return L10n.text("status.waiting", fallback: "Waiting to refresh") }
            let updated = DisplayDateFormatter.updatedText(for: snapshot.fetchedAt, now: now)
            return snapshot.source == .cli
                ? L10n.format("status.antigravity.cli", fallback: "CLI · %@", updated) : updated
        case .failed(let message):
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
        resetCLIPlanState()
        snapshot = nil
        phase = .idle
        logger.info("Stopped Antigravity quota refresh loop")
    }

    func refresh() async {
        await refresh(forcePlanRefresh: false)
    }

    private func refresh(forcePlanRefresh: Bool) async {
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
            if refreshedSnapshot.source == .cli && refreshedSnapshot.subscriptionPlan == nil {
                snapshot = refreshedSnapshot.withSubscriptionPlan(cliSubscriptionPlan)
                scheduleCLIPlanRefreshIfNeeded(force: forcePlanRefresh, expectedGeneration: expectedGeneration)
            } else {
                resetCLIPlanState()
                snapshot = refreshedSnapshot
            }
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

    private func scheduleCLIPlanRefreshIfNeeded(force: Bool, expectedGeneration: UInt64) {
        guard cliPlanTask == nil, force || Date() >= (nextCLIPlanRefresh ?? .distantPast) else { return }
        let fetchPlan = fetchCLISubscriptionPlan
        cliPlanTask = Task { [weak self] in
            defer {
                if !Task.isCancelled, let self, self.generation == expectedGeneration {
                    self.cliPlanTask = nil
                }
            }
            do {
                let plan = try await fetchPlan()
                guard !Task.isCancelled, let self, self.isEnabled, self.isInstalled,
                    self.generation == expectedGeneration
                else { return }
                self.cliSubscriptionPlan = plan
                self.nextCLIPlanRefresh = Date().addingTimeInterval(self.cliPlanRefreshInterval)
                if let current = self.snapshot, current.source == .cli, current.subscriptionPlan != plan {
                    self.snapshot = current.withSubscriptionPlan(plan)
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                // Keep the last known plan and retry independently of the fast quota refresh loop.
                self.nextCLIPlanRefresh = Date().addingTimeInterval(min(300, self.cliPlanRefreshInterval))
            }
        }
    }

    private func resetCLIPlanState() {
        cliPlanTask?.cancel()
        cliPlanTask = nil
        cliSubscriptionPlan = nil
        nextCLIPlanRefresh = nil
    }
}
