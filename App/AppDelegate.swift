import AppKit
import OSLog
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private lazy var model = QuotAIAppModel.shared
    private lazy var store = model.codex
    private lazy var antigravityStore = model.antigravity
    private lazy var claudeCodeStore = model.claudeCode
    private lazy var stayAwakeStore = StayAwakeStore.shared
    private var registry: QuotaProviderRegistry { model.registry }
    private let popover = NSPopover()
    private let panelVisibility = QuotaPanelVisibility()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?
    /// Re-renders the status item so reset windows and stale snapshots are
    /// reflected even when no store value changes.
    private var statusItemClock: Timer?

    private lazy var quickMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let stayAwakeItem = NSMenuItem(
            title: L10n.text("awake.title", fallback: "Stay Awake"),
            action: #selector(toggleStayAwakeFromQuickMenu),
            keyEquivalent: ""
        )
        stayAwakeItem.target = self
        stayAwakeItem.image = quickMenuImage(
            systemName: "cup.and.saucer",
            accessibilityDescription: L10n.text("awake.title", fallback: "Stay Awake")
        )
        menu.addItem(stayAwakeItem)

        let refreshItem = NSMenuItem(
            title: L10n.text("action.refresh_now", fallback: "Refresh Now"),
            action: #selector(refreshFromQuickMenu),
            keyEquivalent: ""
        )
        refreshItem.target = self
        refreshItem.image = quickMenuImage(
            systemName: "arrow.clockwise",
            accessibilityDescription: L10n.text("action.refresh_now", fallback: "Refresh Now")
        )
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: L10n.text("action.settings", fallback: "Settings"),
            action: #selector(openSettingsFromQuickMenu),
            keyEquivalent: ""
        )
        settingsItem.target = self
        settingsItem.image = quickMenuImage(
            systemName: "gearshape",
            accessibilityDescription: L10n.text("action.settings", fallback: "Settings")
        )
        menu.addItem(settingsItem)

        return menu
    }()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI",
        category: "Lifecycle"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !model.previewMode { migrateLegacyPreferencesIfNeeded() }
        restoreSystemStatusItemVisibility()
        installStatusItem()
        configurePopover()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuBarQuotaPreferencesDidChange),
            name: .menuBarQuotaPreferencesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(antigravityIntegrationPreferenceDidChange),
            name: .antigravityIntegrationPreferenceDidChange,
            object: nil
        )
        if !model.previewMode { stayAwakeStore.start() }
        observeMenuBarState()
        model.onOpenPanel = { [weak self] provider in self?.revealPanel(provider: provider) }
        model.start()
        AppUpdateController.shared.start()
        startStatusItemClock()
        logger.info("Application did finish launching with AppKit status item")
    }

    private func migrateLegacyPreferencesIfNeeded() {
        if QuotAIPreferenceMigration.migrate() {
            logger.info("Migrated legacy preferences into QuotAI")
        }
    }

    private func restoreSystemStatusItemVisibility() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "NSStatusItem VisibleCC QuotAIQuotaStatus")
        defaults.set(true, forKey: "NSStatusItem Visible QuotAIQuotaStatus")
        defaults.set(true, forKey: "NSStatusItem VisibleCC CodexQuotaStatus")
        defaults.set(true, forKey: "NSStatusItem Visible CodexQuotaStatus")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        stopOutsideClickMonitor()
        statusItemClock?.invalidate()
        statusItemClock = nil
        model.stop()
        stayAwakeStore.shutdown()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            logger.error("Unable to create the AppKit status item button")
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "QuotAI"
        button.setAccessibilityLabel("QuotAI")
        item.autosaveName = "QuotAIQuotaStatus"
        item.isVisible = true
        statusItem = item
        updateStatusItemAppearance()
        perform(#selector(logStatusItemGeometry), with: nil, afterDelay: 1)
        logger.info("Installed AppKit status item")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening a running menu-bar app should reveal its existing panel.
        // This does not run during login startup and never toggles an open panel closed.
        if !popover.isShown {
            togglePopover()
        }
        return true
    }

    private func configurePopover() {
        let hostingController = NSHostingController(
            rootView: QuotaPopoverContent(
                visibility: panelVisibility,
                panel: MenuBarPanelView(
                    store: store,
                    antigravityStore: antigravityStore,
                    stayAwakeStore: stayAwakeStore,
                    claudeCodeStore: claudeCodeStore,
                    model: model
                )
            )
            .environment(\.usesSystemPopoverSurface, true)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hostingController
    }

    func popoverWillShow(_ notification: Notification) {
        panelVisibility.isVisible = true
    }

    func popoverDidShow(_ notification: Notification) {
        startOutsideClickMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        panelVisibility.isVisible = false
        stopOutsideClickMonitor()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === quickMenu else { return }
        let items = menu.items
        items[0].state = stayAwakeStore.isActive ? .on : .off
        items[1].isEnabled = !isEffectiveMenuBarProviderLoading
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === quickMenu else { return }
        statusItem?.menu = nil
    }

    @objc private func handleStatusItemClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    private func revealPanel(provider: QuotaProvider?) {
        if let provider, registry.plugin(for: provider) != nil {
            UserDefaults.standard.set(provider.rawValue, forKey: DefaultsKey.panelProvider)
        }
        if !popover.isShown {
            togglePopover()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            makePopoverKeyWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "QuotAIURLScheme") as? String ?? "quotai"
        for url in urls where url.scheme == scheme {
            if url.host == "history" {
                model.historyWindow.show()
            } else if url.host == "panel" {
                let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
                    $0.name == "provider"
                }?.value
                revealPanel(provider: raw.flatMap(QuotaProvider.init(rawValue:)))
            }
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            logger.info("Closed quota popover")
        } else {
            reloadProviderInstallations()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // An accessory app has no activatable window until the popover is
            // shown. Activate immediately afterwards, before AppKit commits the
            // first frame, so Liquid Glass starts in its active appearance.
            NSApp.activate(ignoringOtherApps: true)
            makePopoverKeyWindow()
        }
    }

    private func showQuickMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        reloadProviderInstallations()
        if popover.isShown {
            popover.performClose(nil)
        }
        statusItem.menu = quickMenu
        button.performClick(nil)
        logger.info("Opened status item quick menu")
    }

    @objc private func toggleStayAwakeFromQuickMenu() {
        stayAwakeStore.setEnabled(!stayAwakeStore.isActive)
        logger.info(
            "Toggled Stay Awake from quick menu; active=\(self.stayAwakeStore.isActive, privacy: .public)"
        )
    }

    @objc private func refreshFromQuickMenu() {
        let target = registry.store(for: effectiveMenuBarQuotaProvider)
        Task { await target.userRefresh() }
        logger.info(
            "Requested quota refresh from quick menu; provider=\(self.effectiveMenuBarQuotaProvider.rawValue, privacy: .public)"
        )
    }

    @objc private func openSettingsFromQuickMenu() {
        // Opening a SwiftUI Settings scene while NSMenu is still tracking can
        // acknowledge the selector without presenting a window. Defer the
        // request to the next main-loop turn, after tracking has unwound.
        DispatchQueue.main.async { [weak self] in
            self?.showSettingsWindow()
        }
    }

    private func showSettingsWindow() {
        guard let settingsMenuItem = nativeSettingsMenuItem else {
            logger.error("Unable to find the native Settings menu command")
            return
        }
        guard let settingsMenu = settingsMenuItem.menu else {
            logger.error("Native Settings command is not attached to a menu")
            return
        }
        settingsMenu.performActionForItem(at: settingsMenu.index(of: settingsMenuItem))
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Invoked native Settings menu command from quick menu")
    }

    private var nativeSettingsMenuItem: NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        for topLevelItem in mainMenu.items {
            if let settingsItem = topLevelItem.submenu?.items.first(where: {
                $0.keyEquivalent == ","
                    && $0.keyEquivalentModifierMask.contains(.command)
            }) {
                return settingsItem
            }
        }
        return nil
    }

    private func quickMenuImage(
        systemName: String,
        accessibilityDescription: String
    ) -> NSImage? {
        let image = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: accessibilityDescription
        )
        image?.isTemplate = true
        return image
    }

    private func makePopoverKeyWindow() {
        guard let window = popover.contentViewController?.view.window else {
            logger.error("Popover was shown without a backing window")
            return
        }
        window.makeKey()
        logger.info(
            "Opened active quota popover; appActive=\(NSApp.isActive, privacy: .public), windowKey=\(window.isKeyWindow, privacy: .public)"
        )
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissPopoverAfterOutsideClick()
            }
        }
        logger.info("Started outside-click monitoring")
    }

    private func stopOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
        logger.info("Stopped outside-click monitoring")
    }

    private func dismissPopoverAfterOutsideClick() {
        guard outsideClickMonitor != nil, popover.isShown else { return }
        stopOutsideClickMonitor()
        popover.performClose(nil)
        logger.info("Closed quota popover after outside click")
    }

    /// Renders the status item and renders it again whenever a store value it
    /// read changes, so no store has to announce its changes. Preference
    /// changes arrive through their notifications, and the clock covers time
    /// passing; a Claude display deadline advances `displayRevision`.
    private func observeMenuBarState() {
        withObservationTracking {
            updateStatusItemAppearance()
            _ = claudeCodeStore.displayRevision
        } onChange: { [weak self] in
            // onChange runs before the new value is stored; render afterwards.
            Task { @MainActor [weak self] in
                self?.observeMenuBarState()
            }
        }
    }

    private func reloadProviderInstallations() {
        antigravityStore.reloadInstallation()
        claudeCodeStore.reloadInstallation()
    }

    private func startStatusItemClock() {
        guard statusItemClock == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadProviderInstallations()
                self?.updateStatusItemAppearance()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        statusItemClock = timer
    }

    @objc private func menuBarQuotaPreferencesDidChange() {
        model.preferencesDidChange()
        updateStatusItemAppearance()
        logger.info(
            "Updated menu bar quota display; provider=\(self.effectiveMenuBarQuotaProvider.rawValue, privacy: .public), mode=\(self.menuBarQuotaDisplayMode.rawValue, privacy: .public)"
        )
    }

    @objc private func antigravityIntegrationPreferenceDidChange() {
        model.preferencesDidChange()
        updateStatusItemAppearance()
        logger.info(
            "Updated Antigravity integration; enabled=\(self.antigravityIntegrationEnabled, privacy: .public)"
        )
    }

    @objc private func logStatusItemGeometry() {
        guard let statusItem, let button = statusItem.button else { return }
        let window = button.window
        let windowFrame = window?.frame ?? .zero
        let screenName = window?.screen?.localizedName ?? "none"
        let screenFrame = window?.screen?.frame ?? .zero
        let windowLevel = window?.level.rawValue ?? 0
        let occlusionState = window?.occlusionState.rawValue ?? 0
        logger.info(
            "Status item ready; visible=\(statusItem.isVisible, privacy: .public), titleCharacterCount=\(button.title.count, privacy: .public), hasImage=\(button.image != nil, privacy: .public), buttonWidth=\(button.frame.width, privacy: .public), windowVisible=\(window?.isVisible ?? false, privacy: .public), windowAlpha=\(window?.alphaValue ?? 0, privacy: .public), windowLevel=\(windowLevel, privacy: .public), occlusionState=\(occlusionState, privacy: .public), screen=\(screenName, privacy: .public), windowFrame=\(NSStringFromRect(windowFrame), privacy: .public), screenFrame=\(NSStringFromRect(screenFrame), privacy: .public)"
        )
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }

        let presentation = menuBarPresentation
        let composite = MenuBarStatusRenderer.image(for: presentation)

        button.image = composite
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.title = ""

        let toolTip = presentation.accessibilityLabel
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        button.setAccessibilityTitle(toolTip)
    }

    private var menuBarQuotaDisplayMode: MenuBarQuotaDisplayMode {
        let rawValue = UserDefaults.standard.string(
            forKey: DefaultsKey.menuBarDisplayMode
        )
        return rawValue.flatMap(MenuBarQuotaDisplayMode.init(rawValue:)) ?? .both
    }

    private var menuBarQuotaProvider: QuotaProvider {
        let rawValue = UserDefaults.standard.string(
            forKey: DefaultsKey.menuBarProvider
        )
        return rawValue.flatMap(QuotaProvider.init(rawValue:)) ?? .codex
    }

    private var antigravityIntegrationEnabled: Bool {
        ProviderAvailability.antigravityIntegrationEnabled()
    }

    private var effectiveMenuBarQuotaProvider: QuotaProvider {
        registry.resolve(menuBarQuotaProvider)
    }

    private var isEffectiveMenuBarProviderLoading: Bool {
        registry.store(for: effectiveMenuBarQuotaProvider).isLoading
    }

    private var menuBarPresentation: MenuBarPresentation {
        let provider = effectiveMenuBarQuotaProvider
        let plugin = registry.plugin(for: provider)!
        return MenuBarPresentation(
            provider: provider, title: plugin.descriptor.title, symbol: plugin.descriptor.symbol,
            snapshot: registry.displaySnapshots(at: Date()).first { $0.provider == provider },
            selectedGroupID: UserDefaults.standard.string(forKey: DefaultsKey.menuBarAntigravityGroup),
            mode: menuBarQuotaDisplayMode, isStayAwakeActive: stayAwakeStore.isActive,
            now: plugin.store.expiryReferenceDate)
    }
}
