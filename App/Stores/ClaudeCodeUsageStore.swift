import Foundation
import Observation

extension Notification.Name {
    static let claudeCodeUsageSnapshotDidChange = Notification.Name("com.willhsu.QuotAI.claudeCodeUsageSnapshotDidChange")
}

@MainActor
@Observable
final class ClaudeCodeUsageStore: QuotaProviderStore {
    static let shared = ClaudeCodeUsageStore()
    typealias Phase = ProviderPhase

    private(set) var snapshot: ClaudeCodeQuotaSnapshot?
    private(set) var phase: Phase = .idle
    private(set) var isInstalled = false
    private(set) var isEnabled = false
    private(set) var isConnected = false
    private(set) var configurationStatusMessage = ""
    private(set) var sessions: [ClaudeCodeUsageSession] = []
    var selectedSessionID: String? {
        didSet {
            if !previewMode { UserDefaults.standard.set(selectedSessionID, forKey: Self.selectionDefaultsKey) }
            selectSnapshot()
        }
    }

    @ObservationIgnored private let previewMode: Bool
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var displayDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var reports: [ClaudeCodeQuotaSnapshot] = []
    private static let selectionDefaultsKey = "claudeCodeSelectedReportSession"
    private static let configurationDefaultsKey = "claudeCodeReportConfigurationFingerprint"

    init(previewMode: Bool = false, previewScenario: String? = nil) {
        self.previewMode = previewMode
        if previewMode { configurePreview(previewScenario ?? "recent") }
        else {
            selectedSessionID = UserDefaults.standard.string(forKey: Self.selectionDefaultsKey)
            reloadInstallation()
        }
    }

    var isLoading: Bool { phase == .loading }
    var expiryReferenceDate: Date? { Date() }
    var configurationPath: String { ClaudeCodeStatusLineConfiguration.settingsURL.path }
    var helperCommand: String { ClaudeCodeStatusLineConfiguration.command(helperURL: ClaudeCodeStatusLineConfiguration.defaultHelperURL) }

    func statusMessage(at now: Date) -> String {
        if case let .failed(message) = phase { return message }
        guard isConnected else { return configurationStatusMessage }
        guard let snapshot, !snapshot.orderedReports.isEmpty else {
            return L10n.text("claude.status.waiting_report", fallback: "Waiting for a Claude Code status-line report")
        }
        if snapshot.displayableQuotas(at: now).isEmpty {
            return L10n.text("claude.status.stale_report", fallback: "Waiting for a new report; previous values are hidden")
        }
        return L10n.text("claude.status.recent_report", fallback: "Recent report; source sampling time is not provided")
    }

    func start() {
        guard !previewMode, !didStart else { return }
        didStart = true
        reloadInstallation()
        readReports()
    }

    func stop() {
        guard !previewMode else { return }
        didStart = false
        displayDeadlineTask?.cancel()
        displayDeadlineTask = nil
        reports = []
        sessions = []
        snapshot = nil
        phase = .idle
        notify()
    }

    func userRefresh() async {
        guard !previewMode else { notify(); return }
        reloadInstallation()
        readReports()
    }

    func reloadInstallation() {
        guard !previewMode else { return }
        isInstalled = Self.detectCLI()
        let status = ClaudeCodeStatusLineConfiguration.check(helperURL: ClaudeCodeStatusLineConfiguration.defaultHelperURL)
        let state = try? ClaudeCodeStatusLineConfiguration.readState()
        if let state, state.configurationFingerprint != UserDefaults.standard.string(forKey: Self.configurationDefaultsKey) {
            // A configuration recheck may invalidate loaded data, but never
            // replaces it with new JSON until an explicit load is requested.
            reports = []
            sessions = []
            snapshot = nil
            phase = .idle
            selectedSessionID = nil
            UserDefaults.standard.set(state.configurationFingerprint, forKey: Self.configurationDefaultsKey)
        }
        isEnabled = UserDefaults.standard.bool(forKey: ClaudeCodeStatusLineConfiguration.enabledDefaultsKey) && state?.enabled == true
        isConnected = isEnabled && status == .connected && isInstalled
        switch status {
        case .notConfigured:
            configurationStatusMessage = L10n.text("claude.configuration.not_connected", fallback: "Claude Code status-line reports are not connected")
        case .connected:
            configurationStatusMessage = L10n.text("claude.configuration.connected", fallback: "Claude Code status-line reports are connected")
        case .disabled:
            configurationStatusMessage = L10n.text("claude.configuration.disabled", fallback: "Claude Code status-line reports are disabled")
        case .helperMoved:
            configurationStatusMessage = L10n.text("claude.configuration.helper_moved", fallback: "The QuotAI helper location changed; settings were left unchanged")
        case let .conflict(message): configurationStatusMessage = message
        }
        if !isInstalled {
            configurationStatusMessage = L10n.text("claude.configuration.cli_missing", fallback: "Claude Code CLI is not installed")
        }
        if !isConnected {
            reports = []; sessions = []; snapshot = nil; phase = .idle
            scheduleDisplayDeadline()
        }
        notify()
    }

    func enable(helperURL: URL? = nil) throws {
        guard !previewMode else { return }
        // Explicit user action only: start/reload never changes global settings.
        _ = try ClaudeCodeStatusLineConfiguration.enable(helperURL: helperURL ?? ClaudeCodeStatusLineConfiguration.defaultHelperURL)
        UserDefaults.standard.set(true, forKey: ClaudeCodeStatusLineConfiguration.enabledDefaultsKey)
        reloadInstallation()
        start()
    }

    func disable() throws {
        guard !previewMode else { return }
        UserDefaults.standard.set(false, forKey: ClaudeCodeStatusLineConfiguration.enabledDefaultsKey)
        stop()
        defer { reloadInstallation() }
        try ClaudeCodeStatusLineConfiguration.disable()
    }

    func clearReports() throws {
        guard !previewMode else { return }
        try ClaudeCodeReportRepository.clear()
        reports = []
        sessions = []
        selectedSessionID = nil
        snapshot = nil
        phase = .idle
        notify()
    }

    private func readReports() {
        guard isConnected else { return }
        do {
            guard let state = try ClaudeCodeStatusLineConfiguration.readState(), state.enabled else { return }
            let archive = try ClaudeCodeReportRepository.read(configurationFingerprint: state.configurationFingerprint)
            reports = archive.retained(at: Date())
            sessions = reports.map { ClaudeCodeUsageSession(id: $0.sessionFingerprint) }
            selectSnapshot()
        } catch {
            reports = []; sessions = []; snapshot = nil
            phase = .failed(error.localizedDescription)
        }
        notify()
    }

    private func selectSnapshot() {
        snapshot = ClaudeCodeSessionSelection.resolve(in: reports, selectedSessionID: selectedSessionID, at: Date())
        phase = snapshot == nil || snapshot?.orderedReports.isEmpty == true ? .idle : .ready
        scheduleDisplayDeadline()
        notify()
    }

    /// Hide a report at its actual reset/receipt deadline, without waiting for
    /// the periodic disk read. A second window gets its own subsequent timer.
    private func scheduleDisplayDeadline() {
        displayDeadlineTask?.cancel()
        displayDeadlineTask = nil
        let now = Date()
        guard let deadline = snapshot?.nextDisplayDeadline(after: now) else { return }
        let delay = deadline.timeIntervalSince(now)
        guard delay > 0 else { return }
        displayDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.displayDeadlineTask = nil
            // This only hides the already-loaded report. Selecting another
            // session or reading newer JSON remains an explicit user action.
            self.notify()
            self.scheduleDisplayDeadline()
        }
    }

    private func notify() { NotificationCenter.default.post(name: .claudeCodeUsageSnapshotDidChange, object: self) }

    /// An executable installation is required. A settings directory or Claude
    /// Desktop bundle is never treated as evidence of Claude Code CLI.
    static func detectCLI(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> Bool {
        let known = [homeDirectory.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let paths = known + path.split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/claude" }
        return paths.contains {
            let resolved = URL(fileURLWithPath: $0).resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return false }
            return FileManager.default.isExecutableFile(atPath: resolved.path)
        }
    }

    private func configurePreview(_ scenario: String) {
        isInstalled = true; isEnabled = true; isConnected = true
        configurationStatusMessage = L10n.text("claude.configuration.synthetic_preview", fallback: "Synthetic Claude Code preview")
        let now = Date()
        let first = scenario == "stale" ? now.addingTimeInterval(-1_801) : now.addingTimeInterval(-90)
        let fiveReset = scenario == "expired" ? now.addingTimeInterval(-60) : now.addingTimeInterval(3_600)
        let five = ClaudeCodeQuotaReport(kind: .fiveHour, usedPercentage: 36, resetsAt: fiveReset, firstObservedAt: first)
        let seven = ClaudeCodeQuotaReport(kind: .sevenDay, usedPercentage: 62, resetsAt: scenario == "expired" ? now.addingTimeInterval(-60) : now.addingTimeInterval(3 * 86_400), firstObservedAt: first)
        if scenario == "conflict" {
            isConnected = false
            configurationStatusMessage = ClaudeCodeConfigurationError.settingsChanged.localizedDescription
            phase = .failed(configurationStatusMessage)
            return
        }
        if scenario == "waiting" { phase = .idle; return }
        let item = ClaudeCodeQuotaSnapshot(fiveHour: five, sevenDay: scenario == "single" ? nil : seven,
            sessionFingerprint: String(repeating: "a", count: 64), lastCallbackAt: now.addingTimeInterval(-15))
        reports = [item]
        if scenario == "multi" || scenario == "multiAuto" || scenario == "missingSelection" {
            reports.append(ClaudeCodeQuotaSnapshot(fiveHour: ClaudeCodeQuotaReport(kind: .fiveHour, usedPercentage: 81,
                resetsAt: now.addingTimeInterval(7_200), firstObservedAt: now.addingTimeInterval(-40)), sevenDay: nil,
                sessionFingerprint: String(repeating: "b", count: 64), lastCallbackAt: now.addingTimeInterval(-10)))
        }
        if scenario == "missingSelection" { reports.removeFirst() }
        sessions = reports.map { ClaudeCodeUsageSession(id: $0.sessionFingerprint) }
        selectedSessionID = scenario == "multi" || scenario == "missingSelection" ? item.sessionFingerprint : nil
        selectSnapshot()
    }
}
