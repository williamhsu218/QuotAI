import Darwin
import OSLog
import SwiftUI

@main
enum QuotAIMain {
    @MainActor private static var instanceLock: Int32 = -1

    @MainActor
    static func main() {
        // Codex, curl and the previous Claude status line are fed through
        // pipes. If a child exits before reading, a write must fail with
        // EPIPE (already handled) instead of terminating QuotAI.
        signal(SIGPIPE, SIG_IGN)

        if CommandLine.arguments.contains(ClaudeStatusLineBridge.argument) {
            exit(ClaudeStatusLineBridge.run())
        }
        // Sparkle and Launch Services can relaunch a login item concurrently.
        // Acquire before creating stores, migrating settings or repairing the
        // widget so two processes cannot invalidate each other's registration.
        if !QuotAIRuntime.isPreview, !acquireInstanceLock() { return }
        if !QuotAIRuntime.isPreview {
            do {
                try ClaudeStatusLineRetirement.retireIfNeeded()
            } catch {
                Logger(subsystem: "com.willhsu.QuotAI", category: "Migration")
                    .error("Could not restore the retired Claude status line; settings were preserved.")
            }
        }
        QuotAIApp.main()
    }

    @MainActor private static func acquireInstanceLock() -> Bool {
        let logger = Logger(subsystem: "com.willhsu.QuotAI", category: "Lifecycle")
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = open(
                root.appendingPathComponent("instance.lock").path,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                logger.notice("Another QuotAI instance owns this installation; duplicate launch ignored")
                return false
            }
            instanceLock = descriptor
            return true
        } catch {
            logger.error(
                "Could not acquire the QuotAI instance lock; code=\((error as NSError).code, privacy: .public)")
            return false
        }
    }
}

struct QuotAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = QuotAIAppModel.shared

    var body: some Scene {
        Settings {
            SettingsView(
                store: model.codex,
                antigravityStore: model.antigravity,
                claudeCodeStore: model.claudeCode,
                model: model
            )
        }
    }
}
