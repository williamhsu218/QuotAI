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
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("history.title", fallback: "Quota History")
        let hostingController = NSHostingController(rootView: QuotaHistoryView(model: model))
        // The user owns this resizable window's frame. Chart selections and
        // legend changes must not feed SwiftUI's ideal size back into AppKit.
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 720, height: 600)
        // With hosting size tracking disabled, attaching the controller can
        // replace the initial content rect with its unconstrained fitting size.
        window.setContentSize(NSSize(width: 820, height: 720))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("QuotAIQuotaHistory")
        window.center()
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
