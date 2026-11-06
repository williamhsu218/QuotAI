import Foundation
import Observation

enum QuotAIRuntime {
    static var isPreview: Bool {
        CommandLine.arguments.contains("--qa-preview") || Bundle.main.bundleIdentifier == "com.willhsu.QuotAI.qa"
    }
}

/// App-wide ownership of providers and optional features. Preview instances
/// inject synthetic stores and never request OS permissions or read history.
@MainActor @Observable
final class QuotAIAppModel {
    static let shared: QuotAIAppModel = {
        if QuotAIRuntime.isPreview { return preview() }
        return .init(codex: .shared, antigravity: .shared, claudeCode: .shared)
    }()

    let codex: UsageStore
    let antigravity: AntigravityUsageStore
    let claudeCode: ClaudeCodeUsageStore
    let registry: QuotaProviderRegistry
    let previewMode: Bool
    private(set) var history: [QuotaHistoryPoint] = []
    private(set) var historyError: String?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var onOpenPanel: ((QuotaProvider?) -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var activeProviders = Set<QuotaProvider>()
    @ObservationIgnored private var policy = QuotaNotificationPolicy()
    @ObservationIgnored private let ledger: QuotaHistoryLedger
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var previewHistory: [QuotaHistoryPoint]?
    @ObservationIgnored private var automaticClaudeTask: Task<Void, Never>?
    @ObservationIgnored private var automaticClaudeKey = ""
    @ObservationIgnored private var automaticClaudeOwnsQuery = false
    @ObservationIgnored lazy var notifications = QuotaNotificationController(preview: previewMode) {
        [weak self] provider in
        self?.onOpenPanel?(provider)
    }
    @ObservationIgnored lazy var widget = QuotaWidgetController()
    @ObservationIgnored lazy var shortcut = GlobalPanelShortcut { [weak self] in self?.onOpenPanel?(nil) }
    @ObservationIgnored lazy var historyWindow = QuotaHistoryWindowController(model: self)

    init(
        codex: UsageStore, antigravity: AntigravityUsageStore, claudeCode: ClaudeCodeUsageStore,
        defaults: UserDefaults = .standard, previewMode: Bool = false
    ) {
        self.codex = codex
        self.antigravity = antigravity
        self.claudeCode = claudeCode
        self.defaults = defaults
        self.previewMode = previewMode
        registry = .builtIn(codex: codex, antigravity: antigravity, claudeCode: claudeCode, defaults: defaults)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        ledger = QuotaHistoryLedger(url: root.appendingPathComponent("QuotAI/Insights/quota-history-v1.json"))
    }

    static func preview(
        codex: UsageStore? = nil, antigravity: AntigravityUsageStore? = nil,
        claudeCode: ClaudeCodeUsageStore? = nil, history: [QuotaHistoryPoint]? = nil
    ) -> QuotAIAppModel {
        let now = Date()
        let base = UsageSnapshot.preview
        let sample = UsageSnapshot(
            fetchedAt: now,
            fiveHour: .init(kind: .fiveHour, remainingPercent: 82, resetsAt: now.addingTimeInterval(3_600)),
            sevenDay: .init(kind: .sevenDay, remainingPercent: 93, resetsAt: now.addingTimeInterval(3 * 86_400)),
            subscriptionPlan: base.subscriptionPlan, availableResetCount: base.availableResetCount,
            resetCredits: base.resetCredits, dailyUsageBuckets: base.dailyUsageBuckets,
            tokenUsageSummary: base.tokenUsageSummary)
        let model = QuotAIAppModel(
            codex: codex ?? UsageStore(previewMode: true, previewSnapshot: sample),
            antigravity: antigravity ?? AntigravityUsageStore(previewMode: true),
            claudeCode: claudeCode ?? ClaudeCodeUsageStore(previewMode: true), previewMode: true)
        model.previewHistory = history
        return model
    }

    func start() {
        guard !started else { return }
        started = true
        updateProviderLifecycles()
        if !previewMode || CommandLine.arguments.contains("--qa-shortcut") {
            shortcut.configure(
                enabled: defaults.bool(forKey: DefaultsKey.globalShortcut)
                    || CommandLine.arguments.contains("--qa-shortcut"))
        }
        observeProviders()
        if !previewMode { widget.recoverAfterUpgradeIfNeeded() }
        if !previewMode { Task { await notifications.refreshAuthorization() } }
    }

    func stop() {
        started = false
        automaticClaudeTask?.cancel()
        automaticClaudeTask = nil
        automaticClaudeKey = ""
        automaticClaudeOwnsQuery = false
        shortcut.configure(enabled: false)
        widget.stop()
        registry.stop()
        activeProviders.removeAll()
    }

    func preferencesDidChange() {
        registry.invalidatePreferences()
        if started { updateProviderLifecycles() }
        configureAutomaticClaude()
        if !previewMode || CommandLine.arguments.contains("--qa-shortcut") {
            shortcut.configure(
                enabled: defaults.bool(forKey: DefaultsKey.globalShortcut)
                    || CommandLine.arguments.contains("--qa-shortcut"))
        }
        if !started { process(registry.snapshots(at: Date()), display: registry.displaySnapshots(at: Date())) }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        let allowed = enabled ? await notifications.requestPermission() : false
        defaults.set(allowed, forKey: DefaultsKey.quotaNotifications)
        policy.reset()
        preferencesDidChange()
    }

    func resetNotificationBaseline() {
        policy.reset()
        preferencesDidChange()
    }

    func refreshHistory() {
        if previewMode {
            if let previewHistory {
                history = previewHistory
                return
            }
            let now = Date()
            history = (0..<24).map { offset in
                QuotaHistoryPoint(
                    provider: .codex, providerName: "Codex", groupID: "default", groupName: "",
                    window: .fiveHour, timestamp: now.addingTimeInterval(Double(offset - 23) * 900),
                    remainingPercent: max(0, 95 - offset * 3), resetsAt: now.addingTimeInterval(3_600))
            }
            return
        }
        let previous = historyTask
        historyTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                self.history = try await self.ledger.load()
                self.historyError = nil
            } catch {
                self.historyError = L10n.text("history.read_failed", fallback: "Local history could not be read.")
            }
        }
    }

    func clearHistory() {
        if previewMode {
            history = []
            return
        }
        let previous = historyTask
        historyTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.ledger.clear()
                self.history = []
                self.historyError = nil
            } catch {
                self.historyError = L10n.text("history.clear_failed", fallback: "Local history could not be cleared.")
            }
        }
    }

    private func observeProviders() {
        guard started else { return }
        let snapshots = withObservationTracking {
            return (registry.snapshots(at: Date()), registry.displaySnapshots(at: Date()))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeProviders() }
        }
        process(snapshots.0, display: snapshots.1)
        updateProviderLifecycles()
        configureAutomaticClaude()
    }

    private func process(_ snapshots: [ProviderQuotaSnapshot], display: [ProviderQuotaSnapshot]) {
        if !previewMode && defaults.bool(forKey: DefaultsKey.quotaNotifications) {
            policy.threshold =
                defaults.object(forKey: DefaultsKey.lowQuotaThreshold) == nil
                ? 20 : defaults.integer(forKey: DefaultsKey.lowQuotaThreshold)
            let resetEnabled =
                defaults.object(forKey: DefaultsKey.resetNotifications) == nil
                || defaults.bool(forKey: DefaultsKey.resetNotifications)
            let events = policy.evaluate(snapshots, at: Date()).filter { resetEnabled || $0.kind != .reset }
            if !events.isEmpty {
                Task {
                    await notifications.deliver(events, sound: defaults.bool(forKey: DefaultsKey.notificationSound))
                }
            }
        }
        if !previewMode && defaults.bool(forKey: DefaultsKey.quotaHistory) {
            let previous = historyTask
            historyTask = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                do {
                    self.history = try await self.ledger.record(snapshots)
                    self.historyError = nil
                } catch {
                    self.historyError = L10n.text("history.write_failed", fallback: "Local history could not be saved.")
                }
            }
        }
        if !previewMode || CommandLine.arguments.contains("--qa-widget") {
            let saved =
                defaults.string(forKey: DefaultsKey.menuBarProvider).flatMap(QuotaProvider.init(rawValue:)) ?? .codex
            widget.update(
                snapshots: display, preferred: registry.resolve(saved),
                groupID: defaults.string(forKey: DefaultsKey.menuBarAntigravityGroup),
                enabled: defaults.bool(forKey: DefaultsKey.quotaWidgets)
                    || CommandLine.arguments.contains("--qa-widget"))
        }
    }

    private func updateProviderLifecycles() {
        let visible = Set(registry.visibleProviders)
        for plugin in registry.plugins {
            let id = plugin.descriptor.id
            if visible.contains(id), !activeProviders.contains(id) {
                plugin.start()
            } else if !visible.contains(id), activeProviders.contains(id) {
                plugin.stop()
            }
        }
        activeProviders = visible
    }

    private func configureAutomaticClaude() {
        guard !previewMode, started else { return }
        let configured = defaults.integer(forKey: DefaultsKey.claudeAutoRefresh)
        let seconds = [900, 1_800, 3_600].contains(configured) ? configured : 0
        let key = "\(seconds):\(claudeCode.isConnected)"
        guard key != automaticClaudeKey else { return }
        automaticClaudeKey = key
        automaticClaudeTask?.cancel()
        if automaticClaudeOwnsQuery {
            claudeCode.cancelRefresh()
            automaticClaudeOwnsQuery = false
        }
        guard seconds > 0, claudeCode.isConnected else { return }
        automaticClaudeTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard let self, self.started, self.claudeCode.isConnected, !self.claudeCode.isLoading else { continue }
                self.automaticClaudeOwnsQuery = true
                await self.claudeCode.userRefresh()
                self.automaticClaudeOwnsQuery = false
            }
        }
    }
}
