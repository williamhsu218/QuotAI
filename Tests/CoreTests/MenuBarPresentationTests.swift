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
        #expect(value.icon == (provider == .codex ? .codex : .antigravity))
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
