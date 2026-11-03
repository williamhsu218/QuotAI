import Foundation
import Testing
@testable import QuotAICore

@Test("Migrates the actual CodexQuota preferences into QuotAI")
func migratesActualLegacyPreferences() throws {
    let suiteName = "QuotAIPreferenceMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let migrated = QuotAIPreferenceMigration.migrate(
        defaults: defaults,
        legacyDomains: [[
            DefaultsKey.menuBarDisplayMode: MenuBarQuotaDisplayMode.sevenDay.rawValue,
            DefaultsKey.menuBarProvider: QuotaProvider.antigravity.rawValue,
            DefaultsKey.panelProvider: QuotaProvider.codex.rawValue,
            DefaultsKey.menuBarAntigravityGroup: "gemini",
            "stayAwakeDuration": "indefinitely"
        ]]
    )

    #expect(migrated)
    #expect(defaults.string(forKey: DefaultsKey.menuBarDisplayMode) == "sevenDay")
    #expect(defaults.string(forKey: DefaultsKey.menuBarProvider) == "antigravity")
    #expect(defaults.string(forKey: DefaultsKey.panelProvider) == "codex")
    #expect(defaults.string(forKey: DefaultsKey.menuBarAntigravityGroup) == "gemini")
    #expect(defaults.string(forKey: "stayAwakeDuration") == "indefinitely")
    #expect(defaults.bool(forKey: DefaultsKey.legacyPreferencesMigrated))
}

@Test("Migration preserves existing QuotAI choices and only runs once")
func preservesExistingQuotAIPreferences() throws {
    let suiteName = "QuotAIPreferenceMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(MenuBarQuotaDisplayMode.fiveHour.rawValue, forKey: DefaultsKey.menuBarDisplayMode)

    #expect(QuotAIPreferenceMigration.migrate(
        defaults: defaults,
        legacyDomains: [[DefaultsKey.menuBarDisplayMode: MenuBarQuotaDisplayMode.sevenDay.rawValue]]
    ))
    #expect(defaults.string(forKey: DefaultsKey.menuBarDisplayMode) == "fiveHour")
    #expect(!QuotAIPreferenceMigration.migrate(
        defaults: defaults,
        legacyDomains: [[DefaultsKey.menuBarDisplayMode: MenuBarQuotaDisplayMode.both.rawValue]]
    ))
    #expect(defaults.string(forKey: DefaultsKey.menuBarDisplayMode) == "fiveHour")
}

@Test("Disabled or unavailable Antigravity falls back to Codex")
func resolvesEffectiveQuotaProvider() {
    #expect(
        QuotaProvider.antigravity.effectiveProvider(
            antigravityEnabled: false,
            antigravityAvailable: true
        ) == .codex
    )
    #expect(
        QuotaProvider.antigravity.effectiveProvider(
            antigravityEnabled: true,
            antigravityAvailable: false
        ) == .codex
    )
    #expect(
        QuotaProvider.antigravity.effectiveProvider(
            antigravityEnabled: true,
            antigravityAvailable: true
        ) == .antigravity
    )
}
