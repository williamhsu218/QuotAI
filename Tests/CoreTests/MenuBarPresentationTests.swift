import Foundation
import Testing
@testable import QuotAICore

private func presentation(
    provider: QuotaProvider = .antigravity,
    groupID: String? = "gemini",
    mode: MenuBarQuotaDisplayMode = .both,
    codex: UsageSnapshot? = .preview,
    antigravity: AntigravityQuotaSnapshot? = .preview,
    enabled: Bool = true,
    available: Bool = true,
    awake: Bool = false
) -> MenuBarPresentation {
    MenuBarPresentation(
        provider: provider, antigravityEnabled: enabled, antigravityAvailable: available,
        selectedGroupID: groupID, mode: mode, codexSnapshot: codex,
        antigravitySnapshot: antigravity, isStayAwakeActive: awake
    )
}

@Test("Menu bar resolves each selected group without crossing provider data")
func menuBarSelectedGroup() {
    let gemini = presentation()
    #expect(gemini.icon == .gemini)
    #expect(gemini.lines == ["5h 76%", "7d 61%"])
    let thirdParty = presentation(groupID: "3p")
    #expect(thirdParty.icon == .thirdParty)
    #expect(thirdParty.groupID == "3p")
    #expect(thirdParty.lines == ["5h 44%", "7d 28%"])
    #expect(thirdParty.detail.contains("44%"))
    #expect(!thirdParty.detail.contains("76%"))
    let codex = presentation(provider: .codex, groupID: "3p")
    #expect(codex.icon == .codex)
    #expect(codex.groupID == nil)
    #expect(codex.lines == UsageSnapshot.preview.menuBarLines(for: .both))
}

@Test("Missing selection resolves icon, group, numbers and description together")
func menuBarMissingSelection() {
    let snapshot = AntigravityQuotaSnapshot.preview
    for group in snapshot.groups {
        let onlyGroup = AntigravityQuotaSnapshot(fetchedAt: snapshot.fetchedAt, groups: [group])
        for savedID: String? in [nil, "", "removed", group.id == "gemini" ? "3p" : "gemini"] {
            let value = presentation(groupID: savedID, antigravity: onlyGroup)
            #expect(value.groupID == group.id)
            #expect(value.icon == (group.id == "gemini" ? .gemini : .thirdParty))
            #expect(value.lines == group.menuBarLines(for: .both))
            #expect(value.detail.contains(group.localizedDisplayName))
        }
    }
}

@Test("Unknown pools never borrow a Gemini or Claude icon")
func menuBarUnknownPool() {
    let group = AntigravityQuotaGroup(id: "future", displayName: "Future pool",
        fiveHour: .init(kind: .fiveHour, remainingPercent: 21, resetsAt: nil), sevenDay: nil)
    let snapshot = AntigravityQuotaSnapshot(fetchedAt: Date(), groups: [group])
    let value = presentation(groupID: "3p", antigravity: snapshot)
    #expect(value.groupID == "future")
    #expect(value.icon == .antigravity)
    #expect(value.lines == ["5h 21%"])
    #expect(value.detail.contains("Future pool"))
}

@Test("No snapshots never create quota percentages", arguments: MenuBarQuotaDisplayMode.allCases)
func menuBarNoData(mode: MenuBarQuotaDisplayMode) {
    for provider in QuotaProvider.allCases {
        let value = presentation(provider: provider, mode: mode, codex: nil, antigravity: nil)
        #expect(value.lines == ["--"])
        #expect(!value.detail.contains("%"))
        #expect(value.groupID == nil)
        let expectedIcon: MenuBarPresentation.Icon = switch provider {
        case .codex, .claude, .claudeCode: .codex // Unenabled / retired Claude falls back.
        case .antigravity: .antigravity
        }
        #expect(value.icon == expectedIcon)
    }
    let empty = AntigravityQuotaSnapshot(fetchedAt: Date(), groups: [])
    #expect(presentation(mode: mode, antigravity: empty).lines == ["--"])
}

@Test("Unavailable or disabled Antigravity falls back consistently to Codex")
func menuBarProviderFallback() {
    for (enabled, available) in [(false, true), (true, false), (false, false)] {
        let value = presentation(enabled: enabled, available: available)
        #expect(value.provider == .codex)
        #expect(value.icon == .codex)
        #expect(value.groupID == nil)
        #expect(value.lines == UsageSnapshot.preview.menuBarLines(for: .both))
        #expect(!value.detail.contains("Antigravity"))
    }
}

@Test("All available quotas omit missing windows; explicit selection keeps its placeholder")
func menuBarSparseWindows() {
    let weekly = QuotaWindow(kind: .sevenDay, remainingPercent: 100, resetsAt: nil)
    let codex = UsageSnapshot(fetchedAt: Date(), fiveHour: nil, sevenDay: weekly,
                             availableResetCount: 0, resetCredits: [])
    let group = AntigravityQuotaGroup(id: "3p", displayName: "Claude", fiveHour: nil, sevenDay: weekly)
    let ag = AntigravityQuotaSnapshot(fetchedAt: Date(), groups: [group])
    for provider in QuotaProvider.allCases {
        #expect(presentation(provider: provider, codex: codex, antigravity: ag).lines == ["7d 100%"])
        #expect(presentation(provider: provider, mode: .fiveHour, codex: codex, antigravity: ag).lines == ["5h --"])
        #expect(presentation(provider: provider, mode: .sevenDay, codex: codex, antigravity: ag).lines == ["7d 100%"])
    }
}

@Test("Stay Awake affects accessibility and rendering state without changing quotas")
func menuBarStayAwakeState() {
    let off = presentation()
    let on = presentation(awake: true)
    #expect(on.lines == off.lines)
    #expect(on.icon == off.icon)
    #expect(on.isStayAwakeActive)
    #expect(!off.isStayAwakeActive)
    #expect(on.accessibilityLabel.hasPrefix(off.accessibilityLabel))
    #expect(on.accessibilityLabel != off.accessibilityLabel)
}

@Test("Legacy Claude selections fall back without rewriting saved preferences")
func menuBarRetiredClaudeProvider() throws {
    let suite = "QuotAI.tests.retired-Claude.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("claude", forKey: QuotaProvider.menuBarDefaultsKey)
    defaults.set("claude", forKey: QuotaProvider.panelDefaultsKey)
    defaults.set(true, forKey: QuotaProvider.claudeIntegrationDefaultsKey)

    let decoded = try JSONDecoder().decode(QuotaProvider.self, from: Data("\"claude\"".utf8))
    #expect(decoded == .claude)
    for key in [QuotaProvider.menuBarDefaultsKey, QuotaProvider.panelDefaultsKey] {
        let saved = try #require(defaults.string(forKey: key).flatMap(QuotaProvider.init(rawValue:)))
        for (enabled, available) in [(true, true), (false, true), (true, false), (false, false)] {
            let value = presentation(provider: saved, groupID: "3p", enabled: enabled, available: available)
            #expect(value.provider == .codex)
            #expect(value.icon == .codex)
            #expect(value.groupID == nil)
            #expect(value.lines == UsageSnapshot.preview.menuBarLines(for: .both))
            #expect(value.detail.hasPrefix(QuotaProvider.codex.displayName))
        }
        #expect(defaults.string(forKey: key) == "claude")
    }
    #expect(defaults.bool(forKey: QuotaProvider.claudeIntegrationDefaultsKey))
}

@Test("Only Codex and installed, enabled Antigravity are offered as quota sources")
func menuBarAvailableQuotaSources() {
    #expect(QuotaProvider.visibleProviders(antigravityVisible: false) == [.codex])
    #expect(QuotaProvider.visibleProviders(antigravityVisible: true) == [.codex, .antigravity])
    let liveQuota = presentation(provider: .antigravity, groupID: "3p")
    #expect(liveQuota.provider == .antigravity)
    #expect(liveQuota.icon == .thirdParty)
    #expect(liveQuota.lines == ["5h 44%", "7d 28%"])
}

@Test("Windows past their reset time never show their old percentage")
func menuBarExpiredWindows() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let expired = QuotaWindow(kind: .fiveHour, remainingPercent: 3, resetsAt: now.addingTimeInterval(-1))
    let current = QuotaWindow(kind: .sevenDay, remainingPercent: 40, resetsAt: now.addingTimeInterval(3_600))
    let codex = UsageSnapshot(fetchedAt: now, fiveHour: expired, sevenDay: current,
                              availableResetCount: 0, resetCredits: [])
    let value = presentation(provider: .codex, codex: codex)
    #expect(value.lines == ["5h 3%", "7d 40%"]) // No reference time: fixtures unchanged.
    let live = MenuBarPresentation(
        provider: .codex, antigravityEnabled: false, antigravityAvailable: false,
        selectedGroupID: nil, mode: .both, codexSnapshot: codex, antigravitySnapshot: nil,
        isStayAwakeActive: false, now: now
    )
    #expect(live.lines == ["5h --", "7d 40%"])
    #expect(!live.detail.contains("3%"))
    #expect(expired.isExpired(at: now))
    #expect(!current.isExpired(at: now))
    #expect(!QuotaWindow(kind: .fiveHour, remainingPercent: 1, resetsAt: nil).isExpired(at: now))
}

@Test("Snapshots older than the provider's budget are marked stale")
func menuBarStaleSnapshots() {
    let fetched = UsageSnapshot.preview.fetchedAt
    func codex(age: TimeInterval, budget: [QuotaProvider: TimeInterval]) -> MenuBarPresentation {
        MenuBarPresentation(
            provider: .codex, antigravityEnabled: false, antigravityAvailable: false,
            selectedGroupID: nil, mode: .both, codexSnapshot: .preview, antigravitySnapshot: nil,
            isStayAwakeActive: false, now: fetched.addingTimeInterval(age), staleAfter: budget
        )
    }
    #expect(!codex(age: 60, budget: [.codex: 600]).isStale)
    #expect(codex(age: 601, budget: [.codex: 600]).isStale)
    #expect(!codex(age: 601, budget: [:]).isStale)
    #expect(codex(age: 601, budget: [.codex: 600]).accessibilityLabel != codex(age: 60, budget: [.codex: 600]).accessibilityLabel)
    let noData = MenuBarPresentation(
        provider: .codex, antigravityEnabled: false, antigravityAvailable: false,
        selectedGroupID: nil, mode: .both, codexSnapshot: nil, antigravitySnapshot: nil,
        isStayAwakeActive: false, now: Date(), staleAfter: [.codex: 1]
    )
    #expect(!noData.isStale)
}
