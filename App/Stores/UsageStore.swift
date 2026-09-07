import Foundation
import Observation
import OSLog

extension Notification.Name {
    static let codexUsageSnapshotDidChange = Notification.Name(
        "com.willhsu.QuotAI.usageSnapshotDidChange"
    )
}

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var snapshot: UsageSnapshot?
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let client = CodexAppServerClient()
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private let previewMode: Bool
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI",
        category: "Sync"
    )

    init(
        previewMode: Bool = false,
        previewSnapshot: UsageSnapshot? = nil
    ) {
        self.previewMode = previewMode
        if previewMode {
            snapshot = previewSnapshot ?? .preview
            phase = .ready
        } else {
            snapshot = try? LocalSnapshotStore.load()
            phase = snapshot == nil ? .idle : .ready
        }
    }

    var isLoading: Bool { phase == .loading }

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
        case let .failed(message):
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
        guard !previewMode, refreshLoop == nil else { return }
        logger.info("Starting quota refresh loop")
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

    func refresh() async {
        guard !previewMode, !isLoading else { return }
        logger.info("Refreshing Codex quota snapshot")
        phase = .loading
        do {
            let customPath = UserDefaults.standard.string(forKey: "codexBinaryPath")
            let fetched = try await client.fetch(customPath: customPath)
            let latest = fetched.preservingResetCredits(from: snapshot)
            snapshot = latest
            phase = .ready
            NotificationCenter.default.post(
                name: .codexUsageSnapshotDidChange,
                object: self
            )
            try await Task.detached(priority: .utility) {
                try LocalSnapshotStore.save(latest)
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
