import Foundation
import Testing

@testable import QuotAICore

@Test("Persisted preference keys keep their stored names and stay unique")
func persistedPreferenceKeys() {
    // Renaming any value would silently drop the user's saved setting.
    let keys: [(String, String)] = [
        (DefaultsKey.refreshInterval, "refreshIntervalSeconds"),
        (DefaultsKey.codexBinaryPath, "codexBinaryPath"),
        (DefaultsKey.menuBarProvider, "menuBarQuotaProvider"),
        (DefaultsKey.menuBarDisplayMode, "menuBarQuotaDisplayMode"),
        (DefaultsKey.menuBarAntigravityGroup, "menuBarAntigravityQuotaGroup"),
        (DefaultsKey.panelProvider, "quotaPanelProvider"),
        (DefaultsKey.panelAntigravityGroup, "quotaPanelAntigravityGroup"),
        (DefaultsKey.tokenActivityTheme, "tokenActivityTheme"),
        (DefaultsKey.antigravityIntegration, "antigravityIntegrationEnabled"),
        (DefaultsKey.claudeCodeUsageQuery, "claudeCodeUsageQueryEnabled"),
        (DefaultsKey.legacyClaudeStatusLineBridge, "claudeCodeRateLimitBridgeEnabled"),
        (DefaultsKey.stayAwakeEnabled, "stayAwakeEnabled"),
        (DefaultsKey.stayAwakeDuration, "stayAwakeDuration"),
        (DefaultsKey.stayAwakeExpiration, "stayAwakeExpiration"),
        (DefaultsKey.stayAwakeMode, "stayAwakeMode"),
        (DefaultsKey.legacyAppLanguage, "appLanguage"),
        (DefaultsKey.legacyPreferencesMigrated, "didMigrateLegacyQuotAIPreferencesV2"),
        (DefaultsKey.quotaNotifications, "quotaNotificationsEnabled"),
        (DefaultsKey.lowQuotaThreshold, "lowQuotaThresholdPercent"),
        (DefaultsKey.resetNotifications, "quotaResetNotificationsEnabled"),
        (DefaultsKey.notificationSound, "quotaNotificationSoundEnabled"),
        (DefaultsKey.quotaHistory, "quotaHistoryRecordingEnabled"),
        (DefaultsKey.quotaWidgets, "quotaWidgetSharingEnabled"),
        (DefaultsKey.globalShortcut, "globalPanelShortcutEnabled"),
        (DefaultsKey.claudeAutoRefresh, "claudeAutomaticRefreshSeconds"),
        (DefaultsKey.automaticUpdateChecks, "SUEnableAutomaticChecks"),
        (DefaultsKey.automaticUpdateInstallation, "SUAutomaticallyUpdate")
    ]
    for (key, stored) in keys {
        #expect(key == stored)
    }
    #expect(Set(keys.map(\.0)).count == keys.count)
}

@Test("Refresh interval falls back to five minutes for unset or invalid values")
func refreshIntervalNormalization() throws {
    #expect(RefreshInterval.defaultSeconds == 300)
    for invalid in [0, -60, .infinity, -.infinity, .nan] as [TimeInterval] {
        #expect(RefreshInterval.normalized(invalid) == 300)
    }
    #expect(RefreshInterval.normalized(60) == 60)

    let suite = "QuotAI.tests.refresh-interval.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(RefreshInterval.seconds(in: defaults) == 300)
    defaults.set(900.0, forKey: DefaultsKey.refreshInterval)
    #expect(RefreshInterval.seconds(in: defaults) == 900)
    defaults.set(-1.0, forKey: DefaultsKey.refreshInterval)
    #expect(RefreshInterval.seconds(in: defaults) == 300)
}
