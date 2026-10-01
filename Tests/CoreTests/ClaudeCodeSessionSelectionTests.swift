import Foundation
import Testing
@testable import QuotAICore

struct ClaudeCodeSessionSelectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Automatic mode follows the latest displayable callback and never pins itself")
    func automaticLatest() {
        let first = snapshot(id: "a", callbackOffset: -100, observedOffset: -300)
        let second = snapshot(id: "b", callbackOffset: -20, observedOffset: -400)
        #expect(resolve([first, second]) == second)
        #expect(resolve([second, first]) == second)
        let newerFirst = snapshot(id: "a", callbackOffset: -1, observedOffset: -300)
        #expect(resolve([newerFirst, second]) == newerFirst)
        // New callback activity changes the selected session, not the receipt
        // time or 30-minute display lifetime of its unchanged report.
        #expect(resolve([newerFirst, second])?.fiveHour?.firstObservedAt == first.fiveHour?.firstObservedAt)
    }

    @Test("Automatic mode excludes empty, stale, expired, and future-clock callbacks")
    func inactiveCandidates() {
        let valid = snapshot(id: "a", callbackOffset: -100, observedOffset: -300)
        let stale = snapshot(id: "stale", callbackOffset: -1, observedOffset: -1_800)
        let empty = ClaudeCodeQuotaSnapshot(fiveHour: nil, sevenDay: nil, sessionFingerprint: "empty", lastCallbackAt: now)
        let expired = snapshot(id: "expired", callbackOffset: -1, observedOffset: -10, resetOffset: 0)
        let futureCallback = snapshot(id: "future-callback", callbackOffset: 1, observedOffset: -10)
        let futureReceipt = snapshot(id: "future-receipt", callbackOffset: -1, observedOffset: 1)
        #expect(resolve([stale, empty, expired, futureCallback, futureReceipt, valid]) == valid)
        #expect(ClaudeCodeSessionSelection.automaticCandidates(in: [stale, empty, expired, futureCallback, futureReceipt], at: now).isEmpty)
        #expect(resolve([stale, empty, expired, futureCallback, futureReceipt]) == empty)
        #expect(resolve([futureCallback]) == nil)
        #expect(resolve([]) == nil)
    }

    @Test("When all reports are hidden Auto keeps a whole latest safe snapshot for its waiting state")
    func hiddenFallback() {
        let stale = snapshot(id: "stale", callbackOffset: -10, observedOffset: -1_800)
        let expired = snapshot(id: "expired", callbackOffset: -1, observedOffset: -10, resetOffset: 0)
        #expect(resolve([stale, expired]) == expired)
        #expect(resolve([stale, expired])?.displayableQuotas(at: now).isEmpty == true)
        #expect(resolve([stale, expired])?.menuBarLines(for: .both, now: now).joined().contains("%") == false)
        let future = snapshot(id: "future", callbackOffset: 1, observedOffset: -10)
        #expect(resolve([expired, future]) == expired)
        let state = ClaudeCodeSessionSelection()
        #expect(state.resolve(in: [expired], at: now) == expired)
        #expect(state.selectedSessionID == nil)
    }

    @Test("Manual mode stays pinned even when another session is newer or the selected report is stale")
    func manualPinned() {
        let pinned = snapshot(id: "a", callbackOffset: -100, observedOffset: -300)
        let newer = snapshot(id: "b", callbackOffset: -1, observedOffset: -10)
        #expect(resolve([newer, pinned], selected: "a") == pinned)
        #expect(resolve([newer], selected: "a") == nil)
        let stalePinned = snapshot(id: "a", callbackOffset: -1, observedOffset: -1_801)
        #expect(resolve([newer, stalePinned], selected: "a") == stalePinned)
        #expect(resolve([newer, stalePinned], selected: "a")?.displayableQuotas(at: now).isEmpty == true)
        #expect(resolve([newer, pinned], selected: nil) == newer)
    }

    @Test("Equal callback times choose a deterministic source independent of archive order")
    func stableTie() {
        let a = snapshot(id: "a", callbackOffset: -10, observedOffset: -30)
        let b = snapshot(id: "b", callbackOffset: -10, observedOffset: -40)
        #expect(resolve([a, b]) == a)
        #expect(resolve([b, a]) == a)
    }

    @Test("A chosen report remains a single whole snapshot, even when another session provides the missing window")
    func noCrossSessionMerge() {
        let fiveOnly = snapshot(id: "five", callbackOffset: -1, observedOffset: -10)
        let sevenReport = ClaudeCodeQuotaReport(kind: .sevenDay, usedPercentage: 80, resetsAt: now.addingTimeInterval(86_400), firstObservedAt: now.addingTimeInterval(-20))
        let sevenOnly = ClaudeCodeQuotaSnapshot(fiveHour: nil, sevenDay: sevenReport, sessionFingerprint: "seven", lastCallbackAt: now.addingTimeInterval(-2))
        let selected = resolve([fiveOnly, sevenOnly])
        #expect(selected == fiveOnly)
        #expect(selected?.sevenDay == nil)
        #expect(selected?.menuBarLines(for: .both, now: now) == ["5h ~80%"])
        // A partially expired report remains eligible if its other actual
        // window is still displayable; its expired percentage stays hidden.
        let partiallyExpired = ClaudeCodeQuotaSnapshot(fiveHour: ClaudeCodeQuotaReport(kind: .fiveHour, usedPercentage: 20, resetsAt: now, firstObservedAt: now.addingTimeInterval(-20)), sevenDay: sevenReport, sessionFingerprint: "partial", lastCallbackAt: now)
        #expect(resolve([fiveOnly, partiallyExpired]) == partiallyExpired)
        #expect(resolve([fiveOnly, partiallyExpired])?.menuBarLines(for: .both, now: now) == ["5h --", "7d ~20%"])
    }

    @Test("Unique-session policy waits for an explicit choice when multiple displayable sessions exist")
    func onlyUnambiguousSession() {
        let a = snapshot(id: "a", callbackOffset: -10, observedOffset: -30)
        let b = snapshot(id: "b", callbackOffset: -1, observedOffset: -10)
        let stale = snapshot(id: "stale", callbackOffset: 0, observedOffset: -1_800)
        #expect(resolve([a], policy: .onlyDisplayableSession) == a)
        #expect(resolve([a, stale], policy: .onlyDisplayableSession) == a)
        #expect(resolve([a, b], policy: .onlyDisplayableSession) == nil)
        #expect(resolve([], policy: .onlyDisplayableSession) == nil)
        #expect(resolve([a, b], selected: "a", policy: .onlyDisplayableSession) == a)
    }

    private func snapshot(id: String, callbackOffset: TimeInterval, observedOffset: TimeInterval, resetOffset: TimeInterval = 3_600) -> ClaudeCodeQuotaSnapshot {
        ClaudeCodeQuotaSnapshot(fiveHour: ClaudeCodeQuotaReport(kind: .fiveHour, usedPercentage: 20,
            resetsAt: now.addingTimeInterval(resetOffset), firstObservedAt: now.addingTimeInterval(observedOffset)), sevenDay: nil,
            sessionFingerprint: id, lastCallbackAt: now.addingTimeInterval(callbackOffset))
    }

    private func resolve(_ snapshots: [ClaudeCodeQuotaSnapshot], selected: String? = nil, policy: ClaudeCodeSessionSelection.AutoPolicy = .latestDisplayableReport) -> ClaudeCodeQuotaSnapshot? {
        ClaudeCodeSessionSelection.resolve(in: snapshots, selectedSessionID: selected, autoPolicy: policy, at: now)
    }
}
