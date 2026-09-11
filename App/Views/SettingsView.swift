import AppKit
import OSLog
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case providers
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return L10n.text("settings.tab.general", fallback: "General")
        case .menuBar:
            return L10n.text("settings.tab.menu_bar", fallback: "Menu Bar")
        case .providers:
            return L10n.text("settings.tab.providers", fallback: "Providers")
        case .about:
            return L10n.text("settings.tab.about", fallback: "About")
        }
    }

    var icon: String {
        switch self {
        case .general:
            return "gearshape"
        case .menuBar:
            return "menubar.rectangle"
        case .providers:
            return "server.rack"
        case .about:
            return "info.circle"
        }
    }
}

struct SettingsView: View {
    private static let latestReleaseURL = URL(
        string: "https://github.com/williamhsu218/QuotAI/releases/latest"
    )!
    private static let repoURL = URL(
        string: "https://github.com/williamhsu218/QuotAI"
    )!

    let store: UsageStore
    let antigravityStore: AntigravityUsageStore
    let stayAwakeStore: StayAwakeStore
    var initialTab: SettingsTab = .general

    @State private var selectedTab: SettingsTab

    init(
        store: UsageStore,
        antigravityStore: AntigravityUsageStore,
        stayAwakeStore: StayAwakeStore? = nil,
        initialTab: SettingsTab = .general
    ) {
        self.store = store
        self.antigravityStore = antigravityStore
        self.stayAwakeStore = stayAwakeStore ?? .shared
        self.initialTab = initialTab
        _selectedTab = State(initialValue: initialTab)
    }

    @AppStorage("refreshIntervalSeconds") private var refreshInterval = 300.0
    @AppStorage("codexBinaryPath") private var codexBinaryPath = ""
    @AppStorage(QuotaProvider.menuBarDefaultsKey)
    private var menuBarQuotaProvider = QuotaProvider.codex
    @AppStorage(AntigravityQuotaGroup.menuBarGroupDefaultsKey)
    private var menuBarAntigravityGroupID = ""
    @AppStorage(MenuBarQuotaDisplayMode.defaultsKey)
    private var menuBarQuotaDisplayMode = MenuBarQuotaDisplayMode.both
    @AppStorage(QuotaProvider.antigravityIntegrationDefaultsKey)
    private var antigravityIntegrationEnabled = true

    @State private var launchAtLogin = false

    private var isAntigravitySupported: Bool {
        antigravityStore.isInstalled || antigravityStore.isAvailable
    }

    private var shouldShowAntigravity: Bool {
        antigravityIntegrationEnabled && isAntigravitySupported
    }

    var body: some View {
        VStack(spacing: 0) {
            tabSelector
                .padding(.horizontal, AppTheme.Spacing.large)
                .padding(.top, AppTheme.Spacing.large)
                .padding(.bottom, AppTheme.Spacing.compact)

            Divider()
                .overlay(AppTheme.separator)

            Group {
                switch selectedTab {
                case .general:
                    generalPane
                case .menuBar:
                    menuBarPane
                case .providers:
                    providersPane
                case .about:
                    aboutPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            normalizeAntigravityGroupSelection()
            refreshLaunchAtLogin()
        }
        .onChange(of: antigravityGroupIDs) {
            normalizeAntigravityGroupSelection()
        }
    }

    private var tabSelector: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element.id) { index, tab in
                Button {
                    withAnimation(.easeInOut(duration: AppTheme.Motion.quick)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: AppTheme.Spacing.xSmall) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: selectedTab == tab ? .semibold : .regular))
                        Text(tab.title)
                            .font(.system(size: AppTheme.TypeSize.small, weight: selectedTab == tab ? .medium : .regular))
                    }
                    .foregroundStyle(selectedTab == tab ? AppTheme.primaryText : AppTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppTheme.Spacing.small)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(
                    KeyEquivalent(Character(String(index + 1))),
                    modifiers: .command
                )
                .background {
                    if selectedTab == tab {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(AppTheme.pickerSelectedBackground)
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(AppTheme.pickerSelectedBorder, lineWidth: 0.5)
                            }
                            .shadow(color: AppTheme.pickerSelectedShadow, radius: 2, y: 1)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.xSmall)
        .background(
            AppTheme.pickerTrack,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    // MARK: - Panes

    private var generalPane: some View {
        VStack(spacing: AppTheme.Spacing.medium) {
            SettingsSection(title: L10n.text("settings.section.startup", fallback: "Startup")) {
                Toggle(
                    L10n.text("settings.launch_at_login", fallback: "Launch at login"),
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    )
                )
                .help(L10n.text("settings.launch_at_login_help", fallback: "Automatically start QuotAI when you log in."))
            }

            SettingsSection(title: L10n.text("settings.section.refresh", fallback: "Refresh & Sync")) {
                HStack {
                    Text(L10n.text("settings.auto_refresh", fallback: "Auto-refresh"))
                    Spacer()
                    Picker("", selection: $refreshInterval) {
                        Text(L10n.text("settings.every_1_minute", fallback: "Every 1 minute")).tag(60.0)
                        Text(L10n.text("settings.every_5_minutes", fallback: "Every 5 minutes")).tag(300.0)
                        Text(L10n.text("settings.every_10_minutes", fallback: "Every 10 minutes")).tag(600.0)
                        Text(L10n.text("settings.every_15_minutes", fallback: "Every 15 minutes")).tag(900.0)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                Divider().overlay(AppTheme.separator.opacity(0.5))

                HStack {
                    Text(L10n.text("action.refresh", fallback: "Refresh"))
                    Spacer()
                    Button {
                        refreshAllProviders()
                    } label: {
                        if store.isLoading || antigravityStore.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L10n.text("action.refresh_now", fallback: "Refresh Now"))
                        }
                    }
                    .disabled(store.isLoading || antigravityStore.isLoading)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var menuBarPane: some View {
        VStack(spacing: AppTheme.Spacing.medium) {
            SettingsSection(title: L10n.text("settings.section.menu_bar_preview", fallback: "Preview")) {
                HStack {
                    Text(L10n.text("settings.menu_bar_preview_label", fallback: "Live menu bar appearance:"))
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondaryText)
                    Spacer()
                    menuBarPreviewBadge
                }
            }

            SettingsSection(title: L10n.text("settings.section.menu_bar_source", fallback: "Source & Display")) {
                if shouldShowAntigravity {
                    HStack {
                        Text(L10n.text("settings.menu_bar_source", fallback: "Menu bar source"))
                        Spacer()
                        Picker("", selection: $menuBarQuotaProvider) {
                            ForEach(QuotaProvider.allCases, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(L10n.text("settings.menu_bar_source", fallback: "Menu bar source"))
                        .frame(width: 160)
                        .onChange(of: menuBarQuotaProvider) {
                            postMenuBarPreferenceChange()
                        }
                    }

                    if menuBarQuotaProvider == .antigravity {
                        Divider().overlay(AppTheme.separator.opacity(0.5))

                        HStack {
                            Text(L10n.text("settings.antigravity_group", fallback: "Antigravity group"))
                            Spacer()
                            Picker("", selection: $menuBarAntigravityGroupID) {
                                if antigravityGroups.isEmpty {
                                    Text(L10n.text("settings.antigravity_unavailable", fallback: "Unavailable"))
                                        .tag(menuBarAntigravityGroupID)
                                } else {
                                    ForEach(antigravityGroups) { group in
                                        Text(AntigravityQuotaTab(rawValue: group.id)?.title ?? group.localizedDisplayName)
                                            .tag(group.id)
                                    }
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel(L10n.text("settings.antigravity_group", fallback: "Antigravity group"))
                            .frame(width: 160)
                            .disabled(antigravityGroups.isEmpty)
                            .onChange(of: menuBarAntigravityGroupID) {
                                postMenuBarPreferenceChange()
                            }
                        }
                    }

                    Divider().overlay(AppTheme.separator.opacity(0.5))
                }

                HStack {
                    Text(L10n.text("settings.menu_bar_windows", fallback: "Menu bar windows"))
                    Spacer()
                    Picker("", selection: $menuBarQuotaDisplayMode) {
                        Text(L10n.text("settings.menu_bar_quota_5h", fallback: "5h only")).tag(MenuBarQuotaDisplayMode.fiveHour)
                        Text(L10n.text("settings.menu_bar_quota_7d", fallback: "7d only")).tag(MenuBarQuotaDisplayMode.sevenDay)
                        Text(L10n.text("settings.menu_bar_quota_both", fallback: "All available quotas")).tag(MenuBarQuotaDisplayMode.both)
                    }
                    .labelsHidden()
                    .accessibilityLabel(L10n.text("settings.menu_bar_windows", fallback: "Menu bar windows"))
                    .frame(width: 160)
                    .onChange(of: menuBarQuotaDisplayMode) {
                        postMenuBarPreferenceChange()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var providersPane: some View {
        VStack(spacing: AppTheme.Spacing.medium) {
            SettingsSection(title: L10n.text("settings.section.codex_client", fallback: "Codex CLI / Client")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(
                            L10n.text("settings.codex_path", fallback: "Codex path"),
                            text: $codexBinaryPath,
                            prompt: Text("/Applications/ChatGPT.app/Contents/Resources/codex")
                        )
                        .textFieldStyle(.roundedBorder)

                        Button(L10n.text("settings.browse", fallback: "Browse…")) {
                            selectCodexBinary()
                        }

                        if !codexBinaryPath.isEmpty {
                            Button(L10n.text("settings.reset_default", fallback: "Reset")) {
                                codexBinaryPath = ""
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(
                                codexPathIsValid
                                    ? AppTheme.quotaHealthy.accent
                                    : AppTheme.quotaCritical.accent
                            )
                            .frame(width: 7, height: 7)

                        Text(codexStatusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }

            SettingsSection(title: L10n.text("settings.section.antigravity_service", fallback: "Antigravity Service")) {
                if isAntigravitySupported {
                    Toggle(
                        L10n.text("settings.enable_antigravity", fallback: "Enable Antigravity integration"),
                        isOn: $antigravityIntegrationEnabled
                    )
                    .help(L10n.text("settings.enable_antigravity_help", fallback: "Show Antigravity model quota alongside Codex when Antigravity is running."))
                    .onChange(of: antigravityIntegrationEnabled) {
                        NotificationCenter.default.post(
                            name: .antigravityIntegrationPreferenceDidChange,
                            object: nil
                        )
                    }

                    if antigravityIntegrationEnabled {
                        Divider().overlay(AppTheme.separator.opacity(0.5))

                        HStack(spacing: 6) {
                            Circle()
                                .fill(
                                    antigravityIsConnected
                                        ? AppTheme.quotaHealthy.accent
                                        : AppTheme.secondaryText.opacity(0.7)
                                )
                                .frame(width: 7, height: 7)

                            Text(
                                antigravityIsConnected
                                    ? L10n.text("settings.antigravity_status_connected", fallback: "Connected & Active")
                                    : L10n.text("settings.antigravity_status_idle", fallback: "Idle / Not Running")
                            )
                            .font(.system(size: 12, weight: .medium))

                            Spacer()

                            if antigravityIsConnected {
                                Text(
                                    L10n.format(
                                        "settings.antigravity_group_count_format",
                                        fallback: "%d groups",
                                        antigravityGroups.count
                                    )
                                )
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppTheme.secondaryText.opacity(0.6))
                            .frame(width: 7, height: 7)

                        Text(L10n.text("settings.antigravity_not_installed", fallback: "Not installed on this Mac"))
                            .font(.system(size: AppTheme.TypeSize.caption))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }

            Text(
                L10n.text(
                    "settings.privacy_note",
                    fallback: "Codex cache stays on this Mac; Antigravity quota and local authentication are never saved."
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.horizontal, 4)

            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var aboutPane: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(nsImage: appMarkImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .shadow(color: Color.black.opacity(0.15), radius: 6, y: 3)

            VStack(spacing: 4) {
                Text("QuotAI")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)

                Text(L10n.text("settings.app_subtitle", fallback: "ChatGPT & Antigravity Quota Monitor"))
                    .font(.system(size: AppTheme.TypeSize.cardTitle, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)

                Text(versionText)
                    .font(.system(size: AppTheme.TypeSize.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.8))
                    .padding(.top, 2)
            }

            HStack(spacing: 12) {
                Link(destination: Self.latestReleaseURL) {
                    Label(
                        L10n.text("settings.check_updates", fallback: "Check for Updates"),
                        systemImage: "arrow.up.right.square"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Link(destination: Self.repoURL) {
                    Label(
                        L10n.text("settings.github_repo", fallback: "GitHub Repository"),
                        systemImage: "link"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 4)

            Text(L10n.text("settings.acknowledgements", fallback: "Created with pair programming on macOS."))
                .font(.system(size: AppTheme.TypeSize.small))
                .foregroundStyle(AppTheme.secondaryText.opacity(0.7))

            Spacer()

            Divider()
                .padding(.horizontal, 20)

            HStack {
                Spacer()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Text(L10n.text("action.quit", fallback: "Quit QuotAI"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var appMarkImage: NSImage {
        if let bundledImage = NSImage(named: "AppMark") {
            return bundledImage
        }
        if let previewURL = Bundle.main.url(forResource: "AppMark-master", withExtension: "png"),
           let previewImage = NSImage(contentsOf: previewURL) {
            return previewImage
        }
        return NSApplication.shared.applicationIconImage
    }

    private var menuBarPreviewBadge: some View {
        MenuBarStatusLabel(presentation: menuBarPreviewPresentation)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }

    private var menuBarPreviewPresentation: MenuBarPresentation {
        MenuBarPresentation(
            provider: menuBarQuotaProvider,
            antigravityEnabled: antigravityIntegrationEnabled,
            antigravityAvailable: antigravityStore.isInstalled,
            selectedGroupID: menuBarAntigravityGroupID,
            mode: menuBarQuotaDisplayMode,
            codexSnapshot: store.snapshot,
            antigravitySnapshot: antigravityStore.snapshot,
            isStayAwakeActive: stayAwakeStore.isActive
        )
    }

    private var codexPathIsValid: Bool {
        (try? CodexBinaryLocator.locate(customPath: codexBinaryPath.isEmpty ? nil : codexBinaryPath)) != nil
    }

    private var codexStatusMessage: String {
        if let resolved = try? CodexBinaryLocator.locate(customPath: codexBinaryPath.isEmpty ? nil : codexBinaryPath) {
            return codexBinaryPath.isEmpty
                ? "\(L10n.text("settings.codex_status_auto", fallback: "Auto-detected")): \(resolved.path)"
                : "\(L10n.text("settings.codex_status_verified", fallback: "Executable verified")): \(resolved.path)"
        }
        return L10n.text("settings.codex_status_not_found", fallback: "Executable not found")
    }

    private var antigravityIsConnected: Bool {
        antigravityStore.snapshot != nil
    }

    private var antigravityGroups: [AntigravityQuotaGroup] {
        antigravityStore.snapshot?.groups ?? []
    }

    private var antigravityGroupIDs: [String] {
        antigravityGroups.map(\.id)
    }

    private func normalizeAntigravityGroupSelection() {
        guard let firstID = antigravityGroupIDs.first,
              !antigravityGroupIDs.contains(menuBarAntigravityGroupID) else {
            return
        }
        menuBarAntigravityGroupID = firstID
        postMenuBarPreferenceChange()
    }

    private func postMenuBarPreferenceChange() {
        NotificationCenter.default.post(
            name: .menuBarQuotaPreferencesDidChange,
            object: nil
        )
    }

    private func refreshAllProviders() {
        Task { await store.refresh() }
        if antigravityIntegrationEnabled {
            Task { await antigravityStore.refresh() }
        }
    }

    private func refreshLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLogin = enabled
            } catch {
                refreshLaunchAtLogin()
            }
        }
    }

    private func selectCodexBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("settings.browse", fallback: "Select")
        if panel.runModal() == .OK, let url = panel.url {
            codexBinaryPath = url.path
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"

        return L10n.format(
            "settings.version_format",
            fallback: "Version %@ (%@)",
            version,
            build
        )
    }
}
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            Text(title)
                .font(.system(size: AppTheme.TypeSize.caption, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                content()
            }
            .padding(AppTheme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCardSurface(cornerRadius: 10)
        }
    }
}
