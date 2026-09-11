import AppKit
import OSLog
import SwiftUI


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private lazy var store = UsageStore.shared
    private lazy var antigravityStore = AntigravityUsageStore.shared
    private lazy var stayAwakeStore = StayAwakeStore.shared
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?

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
        migrateLegacyPreferencesIfNeeded()
        restoreSystemStatusItemVisibility()
        installStatusItem()
        configurePopover()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(usageSnapshotDidChange),
            name: .codexUsageSnapshotDidChange,
            object: store
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stayAwakeStateDidChange),
            name: .stayAwakeStateDidChange,
            object: stayAwakeStore
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(antigravityUsageSnapshotDidChange),
            name: .antigravityUsageSnapshotDidChange,
            object: antigravityStore
        )
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
        stayAwakeStore.start()
        updateStatusItemAppearance()
        store.start()
        if antigravityIntegrationEnabled {
            antigravityStore.start()
        }
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
        antigravityStore.stop()
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

    private func configurePopover() {
        let hostingController = NSHostingController(
            rootView: MenuBarPanelView(
                store: store,
                antigravityStore: antigravityStore,
                stayAwakeStore: stayAwakeStore
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

    func popoverDidShow(_ notification: Notification) {
        startOutsideClickMonitor()
        antigravityStore.tokenUsage.panelIsVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
        antigravityStore.tokenUsage.panelIsVisible = false
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

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            logger.info("Closed quota popover")
        } else {
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
        switch effectiveMenuBarQuotaProvider {
        case .codex:
            Task { await store.refresh() }
        case .antigravity:
            Task { await antigravityStore.refresh() }
            Task(priority: .utility) { await antigravityStore.tokenUsage.refresh() }
        }
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

    @objc private func usageSnapshotDidChange() {
        updateStatusItemAppearance()
    }

    @objc private func antigravityUsageSnapshotDidChange() {
        updateStatusItemAppearance()
    }

    @objc private func stayAwakeStateDidChange() {
        updateStatusItemAppearance()
        logger.info(
            "Updated Stay Awake menu bar indicator; visible=\(self.stayAwakeStore.isActive, privacy: .public)"
        )
    }

    @objc private func menuBarQuotaPreferencesDidChange() {
        updateStatusItemAppearance()
        logger.info(
            "Updated menu bar quota display; provider=\(self.effectiveMenuBarQuotaProvider.rawValue, privacy: .public), mode=\(self.menuBarQuotaDisplayMode.rawValue, privacy: .public)"
        )
    }

    @objc private func antigravityIntegrationPreferenceDidChange() {
        if antigravityIntegrationEnabled {
            antigravityStore.start()
        } else {
            antigravityStore.stop()
        }
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
            forKey: MenuBarQuotaDisplayMode.defaultsKey
        )
        return rawValue.flatMap(MenuBarQuotaDisplayMode.init(rawValue:)) ?? .both
    }

    private var menuBarQuotaProvider: QuotaProvider {
        let rawValue = UserDefaults.standard.string(
            forKey: QuotaProvider.menuBarDefaultsKey
        )
        return rawValue.flatMap(QuotaProvider.init(rawValue:)) ?? .codex
    }

    private var antigravityIntegrationEnabled: Bool {
        let defaults = UserDefaults.standard
        let key = QuotaProvider.antigravityIntegrationDefaultsKey
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    private var effectiveMenuBarQuotaProvider: QuotaProvider {
        menuBarQuotaProvider.effectiveProvider(
            antigravityEnabled: antigravityIntegrationEnabled,
            antigravityAvailable: antigravityStore.isInstalled
        )
    }

    private var isEffectiveMenuBarProviderLoading: Bool {
        switch effectiveMenuBarQuotaProvider {
        case .codex:
            store.isLoading
        case .antigravity:
            antigravityStore.isLoading
        }
    }

    private var menuBarPresentation: MenuBarPresentation {
        MenuBarPresentation(
            provider: menuBarQuotaProvider,
            antigravityEnabled: antigravityIntegrationEnabled,
            antigravityAvailable: antigravityStore.isInstalled,
            selectedGroupID: UserDefaults.standard.string(forKey: AntigravityQuotaGroup.menuBarGroupDefaultsKey),
            mode: menuBarQuotaDisplayMode,
            codexSnapshot: store.snapshot,
            antigravitySnapshot: antigravityStore.snapshot,
            isStayAwakeActive: stayAwakeStore.isActive
        )
    }
}
