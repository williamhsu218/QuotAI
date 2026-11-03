import Foundation

public enum QuotAIPreferenceMigration {
    public static let legacyDomainNames = [
        "com.willhsu.CodexQuota",
        "com.willhsu.Codexcator",
        "com.willhsu.CodexIndicator"
    ]

    public static let migratedKeys = [
        DefaultsKey.refreshInterval,
        DefaultsKey.codexBinaryPath,
        DefaultsKey.menuBarDisplayMode,
        DefaultsKey.menuBarProvider,
        DefaultsKey.panelProvider,
        DefaultsKey.menuBarAntigravityGroup,
        DefaultsKey.antigravityIntegration,
        DefaultsKey.legacyAppLanguage,
        DefaultsKey.stayAwakeEnabled,
        DefaultsKey.stayAwakeDuration,
        DefaultsKey.stayAwakeExpiration,
        DefaultsKey.stayAwakeMode
    ]

    @discardableResult
    public static func migrate(defaults: UserDefaults = .standard) -> Bool {
        let legacyDomains = legacyDomainNames.map {
            defaults.persistentDomain(forName: $0) ?? [:]
        }
        return migrate(defaults: defaults, legacyDomains: legacyDomains)
    }

    @discardableResult
    public static func migrate(
        defaults: UserDefaults,
        legacyDomains: [[String: Any]]
    ) -> Bool {
        guard !defaults.bool(forKey: DefaultsKey.legacyPreferencesMigrated) else { return false }

        for legacy in legacyDomains {
            for key in migratedKeys where defaults.object(forKey: key) == nil {
                if let value = legacy[key] {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: DefaultsKey.legacyPreferencesMigrated)
        return true
    }
}
