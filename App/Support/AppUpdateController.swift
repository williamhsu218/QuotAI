import AppKit
import OSLog
import Observation

#if canImport(Sparkle)
    import Sparkle
#endif

@MainActor @Observable
final class AppUpdateController: NSObject {
    static let shared = AppUpdateController()
    private(set) var configured = false
    private(set) var canCheck = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private let qaFeed: URL?
    #if canImport(Sparkle)
        @ObservationIgnored private var controller: SPUStandardUpdaterController?
        @ObservationIgnored private var observation: NSKeyValueObservation?
    #endif

    override init() {
        if QuotAIRuntime.isPreview, let raw = ProcessInfo.processInfo.environment["QUOTAI_QA_UPDATE_FEED"],
            let url = URL(string: raw), url.scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
        {
            qaFeed = url
        } else {
            qaFeed = nil
        }
        super.init()
        #if canImport(Sparkle)
            let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
            let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
            configured = Data(base64Encoded: key)?.count == 32 && feed?.scheme == "https"
            if configured {
                controller = SPUStandardUpdaterController(
                    startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
                observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                    [weak self] _, change in
                    let value = change.newValue ?? false
                    Task { @MainActor [weak self] in self?.canCheck = value }
                }
            }
        #endif
    }

    func start() {
        guard !started, configured else { return }
        started = true
        #if canImport(Sparkle)
            controller?.startUpdater()
        #endif
    }

    func checkForUpdates() {
        start()
        #if canImport(Sparkle)
            controller?.checkForUpdates(nil)
        #endif
    }

    func configureAutomaticChecks(_ enabled: Bool) {
        start()
        #if canImport(Sparkle)
            controller?.updater.automaticallyChecksForUpdates = enabled
        #endif
    }

    func configureAutomaticInstallation(_ enabled: Bool) {
        start()
        #if canImport(Sparkle)
            controller?.updater.automaticallyDownloadsUpdates = enabled
        #endif
    }
}

#if canImport(Sparkle)
    extension AppUpdateController: SPUUpdaterDelegate {
        func feedURLString(for updater: SPUUpdater) -> String? { qaFeed?.absoluteString }

        func updater(
            _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
            untilInvokingBlock installHandler: @escaping () -> Void
        ) -> Bool {
            Task { @MainActor in
                let result = await WidgetExtensionRecovery.perform(bundleURL: Bundle.main.bundleURL)
                Logger(subsystem: "com.willhsu.QuotAI", category: "WidgetRecovery").info(
                    "Widget update handoff completed; verified=\(result.extensionReady, privacy: .public)")
                // Never strand Sparkle if extension preparation failed. The
                // new version can still recover kernel-identified old code.
                installHandler()
            }
            return true
        }
    }
#endif
