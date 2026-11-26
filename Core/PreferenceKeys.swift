import Foundation

/// Every UserDefaults key QuotAI reads or writes. The values are persisted
/// user preferences: never change one; add a migration instead.
public enum DefaultsKey {
    // Refresh
    public static let refreshInterval = "refreshIntervalSeconds"
    public static let antigravityRefreshInterval = "antigravityRefreshIntervalSeconds"
    public static let codexBinaryPath = "codexBinaryPath"

    // Menu bar and panel
    public static let menuBarProvider = "menuBarQuotaProvider"
    public static let menuBarDisplayMode = "menuBarQuotaDisplayMode"
    public static let menuBarAntigravityGroup = "menuBarAntigravityQuotaGroup"
    public static let panelProvider = "quotaPanelProvider"
    public static let panelAntigravityGroup = "quotaPanelAntigravityGroup"
    public static let tokenActivityTheme = "tokenActivityTheme"

    // Providers
    public static let antigravityIntegration = "antigravityIntegrationEnabled"
    public static let claudeCodeUsageQuery = "claudeCodeUsageQueryEnabled"
    /// Set by versions that installed the Claude Code status-line bridge.
    public static let legacyClaudeStatusLineBridge = "claudeCodeRateLimitBridgeEnabled"

    // Optional 3.0 features; unset values keep all automatic behavior off.
    public static let quotaNotifications = "quotaNotificationsEnabled"
    public static let lowQuotaThreshold = "lowQuotaThresholdPercent"
    public static let resetNotifications = "quotaResetNotificationsEnabled"
    public static let notificationSound = "quotaNotificationSoundEnabled"
    public static let quotaHistory = "quotaHistoryRecordingEnabled"
    public static let quotaWidgets = "quotaWidgetSharingEnabled"
    public static let widgetRecoveredInstallation = "widgetRecoveredInstallation"
    public static let globalShortcut = "globalPanelShortcutEnabled"
    public static let claudeAutoRefresh = "claudeAutomaticRefreshSeconds"
    public static let automaticUpdateChecks = "SUEnableAutomaticChecks"
    public static let automaticUpdateInstallation = "SUAutomaticallyUpdate"

    // Stay Awake
    public static let stayAwakeEnabled = "stayAwakeEnabled"
    public static let stayAwakeDuration = "stayAwakeDuration"
    public static let stayAwakeExpiration = "stayAwakeExpiration"
    public static let stayAwakeMode = "stayAwakeMode"

    // Migration from Codexcator / CodexIndicator
    public static let legacyAppLanguage = "appLanguage"
    public static let legacyPreferencesMigrated = "didMigrateLegacyQuotAIPreferencesV2"
}

/// Automatic refresh intervals for Codex and Antigravity.
public enum RefreshInterval {
    public static let defaultSeconds: TimeInterval = 300
    public static let antigravityDefaultSeconds: TimeInterval = 900

    /// The configured interval; unset, zero, negative or non-finite values
    /// use the default.
    public static func seconds(in defaults: UserDefaults = .standard) -> TimeInterval {
        normalized(defaults.double(forKey: DefaultsKey.refreshInterval))
    }

    public static func antigravitySeconds(in defaults: UserDefaults = .standard) -> TimeInterval {
        normalizedAntigravity(defaults.double(forKey: DefaultsKey.antigravityRefreshInterval))
    }

    public static func normalizedAntigravity(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return antigravityDefaultSeconds }
        return max(antigravityDefaultSeconds, seconds)
    }

    public static func normalized(_ seconds: TimeInterval) -> TimeInterval {
        seconds > 0 && seconds.isFinite ? seconds : defaultSeconds
    }
}

extension Notification.Name {
    /// Posted by the settings window after it changes a menu bar preference.
    static let menuBarQuotaPreferencesDidChange = Notification.Name(
        "com.willhsu.QuotAI.menuBarQuotaPreferencesDidChange"
    )
    /// Posted by the settings window after it turns Antigravity on or off.
    static let antigravityIntegrationPreferenceDidChange = Notification.Name(
        "com.willhsu.QuotAI.antigravityIntegrationPreferenceDidChange"
    )
}
