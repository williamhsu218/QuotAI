import Foundation
import Observation

extension Notification.Name {
    static let claudeCodeUsageSnapshotDidChange = Notification.Name("com.willhsu.QuotAI.claudeCodeUsageSnapshotDidChange")
}

@MainActor @Observable
final class ClaudeCodeUsageStore: QuotaProviderStore {
    static let shared = ClaudeCodeUsageStore()
    static let enabledDefaultsKey = "claudeCodeUsageQueryEnabled"
    typealias Phase = ProviderPhase
    private(set) var snapshot: ClaudeCodeQuotaSnapshot?
    private(set) var phase: Phase = .idle
    private(set) var isInstalled = false
    private(set) var isEnabled = false
    private(set) var executable: URL?
    private(set) var migrationWarning = ""
    private(set) var isCached = false
    @ObservationIgnored private let previewMode: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let query: @Sendable () async throws -> ClaudeCodeQuotaSnapshot
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var queryTask: Task<ClaudeCodeQuotaSnapshot, Error>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var displayDeadlineTask: Task<Void, Never>?

    init(previewMode: Bool = false, previewScenario: String? = nil, defaults: UserDefaults = .standard,
         cacheURL: URL = ClaudeUsageQueryCache.url, migrateBridge: Bool = true,
         query: @escaping @Sendable () async throws -> ClaudeCodeQuotaSnapshot = { try await ClaudeUsageQueryClient.fetch() }) {
        self.previewMode = previewMode
        self.defaults = defaults; self.cacheURL = cacheURL; self.query = query
        if previewMode { configurePreview(previewScenario ?? "recent"); return }
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
            defaults.set(defaults.bool(forKey: ClaudeCodeStatusLineConfiguration.enabledDefaultsKey), forKey: Self.enabledDefaultsKey)
        }
        // Only the bridge we own is retired. A conflicting user command is
        // preserved; recording stops before restoration is attempted.
        if migrateBridge, let state = try? ClaudeCodeStatusLineConfiguration.readState(), state.enabled {
            do { try ClaudeCodeStatusLineConfiguration.disable() }
            catch { migrationWarning = error.localizedDescription }
        }
        defaults.set(false, forKey: ClaudeCodeStatusLineConfiguration.enabledDefaultsKey)
        reloadInstallation()
    }

    var isConnected: Bool { isEnabled && isInstalled }
    var isLoading: Bool { phase == .loading }
    var hasQueryCache: Bool { previewMode ? snapshot != nil : FileManager.default.fileExists(atPath: cacheURL.path) }
    var expiryReferenceDate: Date? { Date() }
    var configurationStatusMessage: String {
        if !isInstalled { return ClaudeUsageQueryError.cliMissing.localizedDescription }
        return L10n.text("claude.query.cli_ready", fallback: "Claude CLI detected; login is checked when you refresh.")
    }
    func isHistorical(at now: Date) -> Bool {
        if case .failed = phase { return true }
        return isCached || snapshot?.isHistorical(at: now) == true
    }
    func statusMessage(at now: Date) -> String {
        switch phase {
        case .loading: return L10n.text("claude.query.loading", fallback: "Querying Claude usage…")
        case let .failed(message): return message
        case .idle, .ready: break
        }
        guard let snapshot else { return L10n.text("claude.query.waiting", fallback: "Click Refresh to query Claude usage") }
        if snapshot.displayableQuotas(at: now).isEmpty { return L10n.text("claude.query.reset_passed", fallback: "Reset time passed · refresh usage") }
        return isHistorical(at: now)
            ? L10n.text("claude.query.historical", fallback: "Previous query · refresh to update")
            : L10n.text("claude.query.completed", fallback: "Claude usage updated")
    }
    func reloadInstallation() {
        guard !previewMode else { return }
        executable = ClaudeUsageBinaryLocator.locate()
        isInstalled = executable != nil
        isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        notify()
    }
    func start() {
        guard !previewMode, !didStart else { return }
        didStart = true
        reloadInstallation()
        do { snapshot = try ClaudeUsageQueryCache.read(from: cacheURL); isCached = snapshot != nil; phase = snapshot == nil ? .idle : .ready }
        catch { phase = .failed(L10n.text("claude.query.cache_unreadable", fallback: "Local query cache could not be read. Refresh to query again.")) }
        scheduleDisplayDeadline(); notify()
    }
    func stop() {
        cancelRefresh()
        didStart = false
        displayDeadlineTask?.cancel(); displayDeadlineTask = nil
        snapshot = nil; phase = .idle; isCached = false
        notify()
    }
    func userRefresh() async {
        guard !previewMode else { notify(); return }
        guard !isLoading else { return }
        reloadInstallation()
        guard isEnabled else { return }
        guard executable != nil else { phase = .failed(ClaudeUsageQueryError.cliMissing.localizedDescription); notify(); return }
        let id = UUID(); requestID = id
        phase = .loading; notify()
        let task = Task { try await query() }
        queryTask = task
        do {
            let result = try await task.value
            guard requestID == id, isEnabled else { return }
            snapshot = result; isCached = false; phase = .ready
            do { try ClaudeUsageQueryCache.write(result, to: cacheURL) }
            catch { phase = .failed(L10n.text("claude.query.cache_write_failed", fallback: "Usage queried, but the local cache could not be saved.")) }
        } catch {
            guard requestID == id, isEnabled else { return }
            if error is CancellationError { phase = snapshot == nil ? .idle : .ready }
            else { phase = .failed(error.localizedDescription) }
        }
        guard requestID == id else { return }
        queryTask = nil
        scheduleDisplayDeadline(); notify()
    }
    func cancelRefresh() {
        guard queryTask != nil else { return }
        requestID = UUID(); queryTask?.cancel(); queryTask = nil
        phase = snapshot == nil ? .idle : .ready
        notify()
    }
    func enable() throws {
        guard !previewMode else { return }
        defaults.set(true, forKey: Self.enabledDefaultsKey)
        reloadInstallation(); start()
    }
    func disable() throws {
        guard !previewMode else { return }
        defaults.set(false, forKey: Self.enabledDefaultsKey)
        stop(); reloadInstallation()
    }
    func clearReports() throws {
        guard !previewMode else { return }
        cancelRefresh()
        try ClaudeUsageQueryCache.clear(at: cacheURL)
        snapshot = nil; isCached = false; phase = .idle
        scheduleDisplayDeadline(); notify()
    }
    private func scheduleDisplayDeadline() {
        displayDeadlineTask?.cancel(); displayDeadlineTask = nil
        guard let deadline = snapshot?.nextDisplayDeadline(after: Date()) else { return }
        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else { return }
        displayDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.notify(); self.scheduleDisplayDeadline()
        }
    }
    private func notify() { NotificationCenter.default.post(name: .claudeCodeUsageSnapshotDidChange, object: self) }
    private func configurePreview(_ scenario: String) {
        isInstalled = true; isEnabled = true; phase = .ready
        guard scenario != "waiting" else { phase = .idle; return }
        let now = Date(), received = scenario == "stale" ? Date().addingTimeInterval(-1_801) : Date().addingTimeInterval(-60)
        let five = ClaudeCodeQuotaReport(kind: .fiveHour, usedPercentage: 15, resetsAt: scenario == "expired" ? now.addingTimeInterval(-60) : now.addingTimeInterval(3_600), firstObservedAt: received)
        let seven = ClaudeCodeQuotaReport(kind: .sevenDay, usedPercentage: 9, resetsAt: scenario == "expired" ? now.addingTimeInterval(-60) : now.addingTimeInterval(3 * 86_400), firstObservedAt: received)
        snapshot = ClaudeCodeQuotaSnapshot(fiveHour: five, sevenDay: scenario == "single" ? nil : seven, sessionFingerprint: "usage-query", lastCallbackAt: received, source: .usageQuery)
        if scenario == "conflict" { phase = .failed(ClaudeUsageQueryError.timeout.localizedDescription) }
    }
}
