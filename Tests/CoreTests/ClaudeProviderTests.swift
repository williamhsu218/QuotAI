import Foundation
import Testing
@testable import QuotAICore

private let claudeProviderReference = Date(timeIntervalSince1970: 2_000_000_000)

private func claudeProviderPresentation(
    snapshot: ClaudeCodeQuotaSnapshot?,
    now: Date = claudeProviderReference,
    enabled: Bool = true,
    installed: Bool = true
) -> MenuBarPresentation {
    MenuBarPresentation(
        provider: .claudeCode,
        antigravityEnabled: true,
        antigravityAvailable: true,
        selectedGroupID: "3p",
        mode: .both,
        codexSnapshot: .preview,
        antigravitySnapshot: .preview,
        isStayAwakeActive: false,
        now: now,
        claudeCodeSnapshot: snapshot,
        claudeCodeEnabled: enabled,
        claudeCodeAvailable: installed
    )
}

@Test("Claude Code sources require a new enabled bridge and an installed CLI")
func claudeProviderVisibility() {
    #expect(QuotaProvider.visibleProviders(antigravityVisible: false, claudeCodeVisible: true) == [.codex, .claudeCode])
    #expect(QuotaProvider.visibleProviders(antigravityVisible: true, claudeCodeVisible: true) == [.codex, .antigravity, .claudeCode])
    #expect(QuotaProvider.claudeCode.rawValue != QuotaProvider.claude.rawValue)
    #expect(QuotaProvider.claudeCodeIntegrationDefaultsKey != QuotaProvider.claudeIntegrationDefaultsKey)
    for (enabled, installed) in [(false, true), (true, false), (false, false)] {
        let value = claudeProviderPresentation(snapshot: nil, enabled: enabled, installed: installed)
        #expect(value.provider == .codex)
        #expect(value.icon == .codex)
    }
    #expect(QuotaProvider.claude.effectiveProvider(
        antigravityEnabled: true, antigravityAvailable: true,
        claudeCodeEnabled: true, claudeCodeAvailable: true
    ) == .codex)
}

@Test("An enabled Claude source without reports never borrows Codex or Antigravity numbers")
func claudeProviderNoReport() {
    let value = claudeProviderPresentation(snapshot: nil)
    #expect(value.provider == .claudeCode)
    #expect(value.icon == .claudeCode)
    #expect(value.icon != .thirdParty)
    #expect(value.lines == ["--"])
    #expect(!value.detail.contains("%"))
    #expect(value.groupID == nil)
}

@Test("Claude menu bar reports are marked and invalid windows never expose percentages")
func claudeProviderReportPresentation() {
    let now = claudeProviderReference
    let recent = ClaudeCodeQuotaReport(kind: .sevenDay, usedPercentage: 35,
        resetsAt: now.addingTimeInterval(86_400), firstObservedAt: now.addingTimeInterval(-60))
    let stale = ClaudeCodeQuotaReport(kind: .fiveHour, usedPercentage: 91,
        resetsAt: now.addingTimeInterval(3_600), firstObservedAt: now.addingTimeInterval(-1_801))
    let snapshot = ClaudeCodeQuotaSnapshot(fiveHour: stale, sevenDay: recent,
        sessionFingerprint: "synthetic-session", lastCallbackAt: now)
    let value = claudeProviderPresentation(snapshot: snapshot)
    #expect(value.lines == ["5h --", "7d ~65%"])
    #expect(value.isStale)
    #expect(!value.accessibilityLabel.contains("9%"))
    #expect(!value.accessibilityLabel.contains("91%"))
    #expect(value.detail.contains(L10n.text("claude.report.title", fallback: "Local report")))
    #expect(value.detail.contains(L10n.text("claude.report.source_unknown", fallback: "Source sampling time not provided")))

    let afterReset = claudeProviderPresentation(snapshot: snapshot, now: recent.resetsAt)
    #expect(afterReset.lines == ["5h --", "7d --"])
    #expect(!afterReset.accessibilityLabel.contains("%"))
    #expect(!afterReset.detail.contains("65"))
    #expect(!afterReset.detail.contains("100"))

    let futureCallback = ClaudeCodeQuotaSnapshot(fiveHour: nil, sevenDay: recent,
        sessionFingerprint: "synthetic-session", lastCallbackAt: now.addingTimeInterval(1))
    let clockRollback = claudeProviderPresentation(snapshot: futureCallback)
    #expect(clockRollback.lines == ["7d --"])
    #expect(clockRollback.isStale)
    #expect(!clockRollback.accessibilityLabel.contains("%"))
}

@Test("Claude UI refreshes at both independent cutoffs instead of the next periodic tick")
func claudeProviderExactDisplayCutoffs() throws {
    let now = claudeProviderReference
    let five = ClaudeCodeQuotaReport(kind: .fiveHour, usedPercentage: 91,
        resetsAt: now.addingTimeInterval(0.5), firstObservedAt: now.addingTimeInterval(-60))
    let seven = ClaudeCodeQuotaReport(kind: .sevenDay, usedPercentage: 35,
        resetsAt: now.addingTimeInterval(86_400), firstObservedAt: now.addingTimeInterval(-1_799.25))
    let snapshot = ClaudeCodeQuotaSnapshot(fiveHour: five, sevenDay: seven,
        sessionFingerprint: "synthetic-session", lastCallbackAt: now)
    let entries = ClaudeCodeReportDisplayTimeline.entries(for: snapshot, from: now)
    let afterFive = try #require(entries.first { $0 >= five.resetsAt })
    let sevenCutoff = seven.firstObservedAt.addingTimeInterval(1_800)
    let afterSeven = try #require(entries.first { $0 >= sevenCutoff })
    #expect(afterFive.timeIntervalSince(five.resetsAt) < 0.02)
    #expect(afterSeven.timeIntervalSince(sevenCutoff) < 0.02)
    #expect(snapshot.menuBarLines(for: .both, now: afterFive) == ["5h --", "7d ~65%"])
    #expect(!snapshot.menuBarLines(for: .both, now: afterSeven).joined().contains("%"))
    #expect(entries.count <= 63)
    #expect(entries == entries.sorted())
    #expect(ClaudeCodeReportDisplayTimeline.entries(for: nil, from: now) == [now])
}
