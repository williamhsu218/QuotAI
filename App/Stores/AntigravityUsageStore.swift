import Foundation
import Observation
import OSLog

extension Notification.Name {
    static let antigravityUsageSnapshotDidChange = Notification.Name(
        "com.willhsu.QuotAI.antigravityUsageSnapshotDidChange"
    )
    static let menuBarQuotaPreferencesDidChange = Notification.Name(
        "com.willhsu.QuotAI.menuBarQuotaPreferencesDidChange"
    )
    static let antigravityIntegrationPreferenceDidChange = Notification.Name(
        "com.willhsu.QuotAI.antigravityIntegrationPreferenceDidChange"
    )
}

@MainActor
@Observable
final class AntigravityUsageStore {
    static let shared = AntigravityUsageStore()

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var snapshot: AntigravityQuotaSnapshot?
    private(set) var phase: Phase = .idle
    private(set) var isEnabled = false
    let tokenUsage: AntigravityTokenStore

    @ObservationIgnored private let client = AntigravityQuotaClient()
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private let previewMode: Bool
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI",
        category: "AntigravitySync"
    )

    init(previewMode: Bool = false, tokenUsage: AntigravityTokenStore? = nil) {
        self.previewMode = previewMode
        self.tokenUsage = tokenUsage ?? AntigravityTokenStore(previewMode: previewMode)
        if previewMode {
            snapshot = .preview
            phase = .ready
            isEnabled = true
        }
    }

    var isLoading: Bool { phase == .loading }
    var isAvailable: Bool { snapshot != nil }

    var isInstalled: Bool {
        if previewMode { return true }
        let fm = FileManager.default
        let paths = [
            "/Applications/Antigravity.app",
            "/Applications/Antigravity IDE.app",
            NSString(string: "~/Applications/Antigravity.app").expandingTildeInPath,
            NSString(string: "~/Applications/Antigravity IDE.app").expandingTildeInPath
        ]
        return paths.contains(where: { fm.fileExists(atPath: $0) }) || snapshot != nil
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
            } ?? L10n.text("status.waiting", fallback: "Waiting to refresh")
        case let .failed(message):
            return message
        }
    }

    func start() {
        guard !previewMode else { return }
        isEnabled = true
        guard refreshLoop == nil else { return }
        logger.info("Starting Antigravity quota refresh loop")
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                let configured = UserDefaults.standard.double(forKey: "refreshIntervalSeconds")
                let interval = configured > 0 ? configured : 300
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    func stop() {
        guard !previewMode else { return }
        let shouldNotify = snapshot != nil || phase != .idle
        isEnabled = false
        refreshLoop?.cancel()
        refreshLoop = nil
        snapshot = nil
        phase = .idle
        if shouldNotify {
            NotificationCenter.default.post(
                name: .antigravityUsageSnapshotDidChange,
                object: self
            )
        }
        logger.info("Stopped Antigravity quota refresh loop")
    }

    func refresh() async {
        guard !previewMode, isEnabled, !isLoading else { return }
        logger.info("Refreshing Antigravity quota snapshot")
        phase = .loading
        do {
            let refreshedSnapshot = try await client.fetch()
            guard isEnabled else { return }
            snapshot = refreshedSnapshot
            phase = .ready
            NotificationCenter.default.post(
                name: .antigravityUsageSnapshotDidChange,
                object: self
            )
        } catch {
            guard isEnabled else { return }
            // Antigravity quota is deliberately not cached or retained on a
            // failed refresh. Unavailable must never look like a zero balance.
            snapshot = nil
            phase = .failed(error.localizedDescription)
            NotificationCenter.default.post(
                name: .antigravityUsageSnapshotDidChange,
                object: self
            )
            logger.error(
                "Antigravity quota refresh failed: \(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }
}
