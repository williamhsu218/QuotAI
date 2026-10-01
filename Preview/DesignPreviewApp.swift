import AppKit
import SwiftUI

@MainActor
private final class NativeSettingsPreviewWindow {
    static let shared = NativeSettingsPreviewWindow()

    private var window: NSWindow?

    func show(tab: SettingsTab, claudeScenario: String = "recent") {
        guard window == nil else { return }

        let content = SettingsView(
            store: UsageStore(previewMode: true),
            antigravityStore: AntigravityUsageStore(previewMode: true),
            stayAwakeStore: StayAwakeStore(previewMode: true),
            initialTab: tab,
            claudeCodeStore: ClaudeCodeUsageStore(previewMode: true, previewScenario: claudeScenario)
        )
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuotAI Settings QA"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

@main
struct DesignPreviewApp: App {
    @State private var store = UsageStore(previewMode: true)
    @State private var antigravityStore = AntigravityUsageStore(previewMode: true)
    @State private var stayAwakeStore = StayAwakeStore(previewMode: true)
    @State private var claudeCodeStore: ClaudeCodeUsageStore

    private var rendersSettings: Bool {
        CommandLine.arguments.contains("--settings")
    }

    private var requestedSettingsTab: SettingsTab {
        guard
            let optionIndex = CommandLine.arguments.firstIndex(of: "--settings-tab"),
            CommandLine.arguments.indices.contains(optionIndex + 1),
            let tab = SettingsTab(rawValue: CommandLine.arguments[optionIndex + 1])
        else {
            return .general
        }
        return tab
    }

    init() {
        let arguments = CommandLine.arguments
        let claudeScenario = arguments.first { $0.hasPrefix("--claude-state=") }
            .map { String($0.dropFirst("--claude-state=".count)) } ?? "recent"
        _claudeCodeStore = State(initialValue: ClaudeCodeUsageStore(
            previewMode: true, previewScenario: claudeScenario
        ))
        if arguments.contains("--claude") {
            UserDefaults.standard.set(QuotaProvider.claudeCode.rawValue, forKey: QuotaProvider.panelDefaultsKey)
            UserDefaults.standard.set(QuotaProvider.claudeCode.rawValue, forKey: QuotaProvider.menuBarDefaultsKey)
        }
        let shouldRenderSettings = arguments.contains("--settings")
        let tab: SettingsTab = {
            guard
                let optionIndex = arguments.firstIndex(of: "--settings-tab"),
                arguments.indices.contains(optionIndex + 1),
                let tab = SettingsTab(rawValue: arguments[optionIndex + 1])
            else {
                return .general
            }
            return tab
        }()
        let requestedAppearance = arguments.firstIndex(of: "--appearance").flatMap { optionIndex in
            arguments.indices.contains(optionIndex + 1) ? arguments[optionIndex + 1] : nil
        }

        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            if requestedAppearance == "light" {
                NSApplication.shared.appearance = NSAppearance(named: .aqua)
            } else if requestedAppearance == "dark" {
                NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            if shouldRenderSettings {
                NativeSettingsPreviewWindow.shared.show(tab: tab, claudeScenario: claudeScenario)
            }
        }
    }

    var body: some Scene {
        WindowGroup("QuotAI Design Preview") {
            Group {
                if rendersSettings {
                    SettingsView(
                        store: store,
                        antigravityStore: antigravityStore,
                        stayAwakeStore: stayAwakeStore,
                        initialTab: requestedSettingsTab,
                        claudeCodeStore: claudeCodeStore
                    )
                } else {
                    DesignPreviewView(
                        store: store,
                        antigravityStore: antigravityStore,
                        stayAwakeStore: stayAwakeStore,
                        claudeCodeStore: claudeCodeStore
                    )
                }
            }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(store: store, antigravityStore: antigravityStore,
                         stayAwakeStore: stayAwakeStore, claudeCodeStore: claudeCodeStore)
        }
    }
}
