import Darwin
import SwiftUI
import OSLog

@main
enum QuotAIMain {
    @MainActor
    static func main() {
        // Codex, curl and the previous Claude status line are fed through
        // pipes. If a child exits before reading, a write must fail with
        // EPIPE (already handled) instead of terminating QuotAI.
        signal(SIGPIPE, SIG_IGN)

        if CommandLine.arguments.contains(ClaudeStatusLineBridge.argument) {
            exit(ClaudeStatusLineBridge.run())
        }
        do {
            try ClaudeStatusLineRetirement.retireIfNeeded()
        } catch {
            Logger(subsystem: "com.willhsu.QuotAI", category: "Migration")
                .error("Could not restore the retired Claude status line; settings were preserved.")
        }
        QuotAIApp.main()
    }
}

struct QuotAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = UsageStore.shared
    @State private var antigravityStore = AntigravityUsageStore.shared
    @State private var claudeCodeStore = ClaudeCodeUsageStore.shared

    var body: some Scene {
        Settings {
            SettingsView(
                store: store,
                antigravityStore: antigravityStore,
                claudeCodeStore: claudeCodeStore
            )
        }
    }
}
