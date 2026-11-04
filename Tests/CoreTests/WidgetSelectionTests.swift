import Foundation
import Testing

@testable import QuotAICore

@Suite("Widget quota selection")
struct WidgetSelectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ group: String, _ window: String, _ percent: Int, primary: Bool) -> WidgetQuotaRow {
        .init(
            id: "antigravity/\(group)/\(window)", providerID: "antigravity", title: "Antigravity · \(group)",
            window: window, remainingPercent: percent, resetsAt: now.addingTimeInterval(3_600),
            fetchedAt: now, historical: false, groupID: group, isPrimary: primary)
    }

    @Test("Selected model windows never mix with another model or automatic overview")
    func modelIsolation() {
        let snapshot = SharedWidgetSnapshot(
            version: 1, generatedAt: now,
            rows: [
                row("gemini", "5h", 80, primary: true), row("gemini", "7d", 60, primary: true),
                row("argon", "7d", 2, primary: false)
            ])
        #expect(snapshot.providerQuotas.map(\.id) == ["antigravity/gemini"])
        #expect(snapshot.quotaChoices.map(\.id) == ["antigravity/gemini", "antigravity/argon"])
        let chosen = snapshot.quotas(selectionID: "antigravity/argon")
        #expect(chosen.count == 1)
        #expect(chosen.first?.providerID == "antigravity")
        #expect(chosen.first?.fiveHour == nil)
        #expect(chosen.first?.sevenDay?.remainingPercent == 2)
    }

    @Test("Pinned widgets keep their selection after the app changes its preferred model")
    func independentSelection() {
        let first = SharedWidgetSnapshot(
            version: 1, generatedAt: now,
            rows: [row("gemini", "7d", 60, primary: true), row("argon", "7d", 2, primary: false)])
        let second = SharedWidgetSnapshot(
            version: 1, generatedAt: now,
            rows: [row("argon", "7d", 2, primary: true), row("gemini", "7d", 60, primary: false)])
        #expect(first.quotas(selectionID: nil).first?.id == "antigravity/gemini")
        #expect(second.quotas(selectionID: nil).first?.id == "antigravity/argon")
        let before = first.quotas(selectionID: "antigravity/gemini").first
        let after = second.quotas(selectionID: "antigravity/gemini").first
        #expect(before?.id == after?.id)
        #expect(before?.sevenDay?.remainingPercent == after?.sevenDay?.remainingPercent)
        #expect(after?.id == "antigravity/gemini")
    }

    @Test("Unavailable selected quotas never silently fall back to unrelated data")
    func unavailableSelection() {
        let snapshot = SharedWidgetSnapshot(
            version: 1, generatedAt: now,
            rows: [row("gemini", "7d", 60, primary: true)])
        #expect(snapshot.quotas(selectionID: "antigravity/removed").isEmpty)
        #expect(SharedWidgetSnapshot.empty.quotas(selectionID: "antigravity/gemini").isEmpty)
    }

    @Test("Snapshots from static widgets remain readable without new optional fields")
    func oldSnapshotCompatibility() throws {
        let legacy = WidgetQuotaRow(
            id: "codex/default/7d", providerID: "codex", title: "Codex", window: "7d",
            remainingPercent: 42, resetsAt: nil, fetchedAt: now, historical: false)
        let encoded = try JSONEncoder().encode(SharedWidgetSnapshot(version: 1, generatedAt: now, rows: [legacy]))
        let decoded = try JSONDecoder().decode(SharedWidgetSnapshot.self, from: encoded)
        #expect(decoded.quotaChoices.first?.id == "codex")
        #expect(decoded.providerQuotas.first?.sevenDay?.remainingPercent == 42)
        #expect(decoded.rows.first?.groupID == nil)
    }
}
