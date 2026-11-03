import AppKit
import SwiftUI

@MainActor
final class QuotaHistoryWindowController: NSObject, NSWindowDelegate {
    private weak var model: QuotAIAppModel?
    private var window: NSWindow?

    init(model: QuotAIAppModel) { self.model = model }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let model else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 510),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("history.title", fallback: "Quota History")
        window.contentViewController = NSHostingController(rootView: QuotaHistoryView(model: model))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("QuotAIQuotaHistory")
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
