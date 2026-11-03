import Foundation
import Observation
import OSLog

extension Notification.Name {
    static let stayAwakeStateDidChange = Notification.Name(
        "com.willhsu.QuotAI.stayAwakeStateDidChange"
    )
}

@MainActor
@Observable
final class StayAwakeStore {
    static let shared = StayAwakeStore()

    private enum DefaultsKey {
        static let enabled = "stayAwakeEnabled"
        static let duration = "stayAwakeDuration"
        static let expiration = "stayAwakeExpiration"
        static let mode = "stayAwakeMode"
    }

    private(set) var isActive = false
    private(set) var expiresAt: Date?
    private(set) var selectedDuration: StayAwakeDuration
    private(set) var selectedMode: StayAwakeMode

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let processInfo: ProcessInfo
    @ObservationIgnored private let previewMode: Bool
    @ObservationIgnored private var activityToken: NSObjectProtocol?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI",
        category: "StayAwake"
    )

    init(
        defaults: UserDefaults = .standard,
        processInfo: ProcessInfo = .processInfo,
        previewMode: Bool = false
    ) {
        self.defaults = defaults
        self.processInfo = processInfo
        self.previewMode = previewMode
        selectedDuration = defaults.string(forKey: DefaultsKey.duration)
            .flatMap(StayAwakeDuration.init(rawValue:))
            ?? .oneHour
        selectedMode = defaults.string(forKey: DefaultsKey.mode)
            .flatMap(StayAwakeMode.init(rawValue:))
            ?? .allowDisplaySleep

        if previewMode {
            selectedDuration = .oneHour
            selectedMode = .allowDisplaySleep
            isActive = true
            expiresAt = Date().addingTimeInterval(60 * 60)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard !previewMode, defaults.bool(forKey: DefaultsKey.enabled) else { return }

        if selectedDuration == .indefinitely {
            activate(duration: selectedDuration, expiration: nil)
            return
        }

        guard
            let savedExpiration = defaults.object(forKey: DefaultsKey.expiration) as? Date,
            savedExpiration > Date()
        else {
            stop()
            return
        }
        activate(duration: selectedDuration, expiration: savedExpiration)
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? activate(duration: selectedDuration) : stop()
    }

    func selectDuration(_ duration: StayAwakeDuration) {
        guard selectedDuration != duration else { return }
        selectedDuration = duration
        defaults.set(duration.rawValue, forKey: DefaultsKey.duration)
        if isActive {
            activate(duration: duration)
        }
    }

    func selectMode(_ mode: StayAwakeMode) {
        guard selectedMode != mode else { return }
        selectedMode = mode
        defaults.set(mode.rawValue, forKey: DefaultsKey.mode)
        if isActive {
            activate(duration: selectedDuration, expiration: expiresAt)
        }
    }

    func stop() {
        releaseActivity()
        isActive = false
        expiresAt = nil
        defaults.set(false, forKey: DefaultsKey.enabled)
        defaults.removeObject(forKey: DefaultsKey.expiration)
        postStateChange()
        logger.info("Stay Awake stopped")
    }

    func shutdown() {
        releaseActivity()
        logger.info("Stay Awake activity released for application shutdown")
    }

    private func activate(
        duration: StayAwakeDuration,
        expiration preservedExpiration: Date? = nil
    ) {
        releaseActivity()

        let expiration = preservedExpiration ?? duration.expirationDate(startingAt: Date())
        if let expiration, expiration <= Date() {
            stop()
            return
        }

        selectedDuration = duration
        isActive = true
        expiresAt = expiration
        defaults.set(true, forKey: DefaultsKey.enabled)
        defaults.set(duration.rawValue, forKey: DefaultsKey.duration)
        defaults.set(selectedMode.rawValue, forKey: DefaultsKey.mode)
        if let expiration {
            defaults.set(expiration, forKey: DefaultsKey.expiration)
        } else {
            defaults.removeObject(forKey: DefaultsKey.expiration)
        }

        if !previewMode {
            var options: ProcessInfo.ActivityOptions = [.idleSystemSleepDisabled]
            if selectedMode.preventsDisplaySleep {
                options.insert(.idleDisplaySleepDisabled)
            }
            activityToken = processInfo.beginActivity(
                options: options,
                reason: "QuotAI Stay Awake"
            )
        }
        scheduleExpiration(expiration)
        postStateChange()
        logger.info(
            "Stay Awake started; duration=\(duration.rawValue, privacy: .public), mode=\(self.selectedMode.rawValue, privacy: .public), finite=\(expiration != nil, privacy: .public)"
        )
    }

    private func scheduleExpiration(_ expiration: Date?) {
        guard let expiration else { return }
        expirationTask = Task { [weak self] in
            let delay = max(0, expiration.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.expiresAt == expiration else { return }
            self.stop()
        }
    }

    private func releaseActivity() {
        expirationTask?.cancel()
        expirationTask = nil
        if let activityToken {
            processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    private func postStateChange() {
        NotificationCenter.default.post(name: .stayAwakeStateDidChange, object: self)
    }
}
