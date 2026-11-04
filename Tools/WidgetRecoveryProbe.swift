import Foundation

@main
struct WidgetRecoveryProbe {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("blocked")
        try Data().write(to: parent)
        let url = parent.appendingPathComponent("snapshot.json")
        let controller = QuotaWidgetController(url: url)
        let now = Date()
        let sample = ProviderQuotaSnapshot(
            provider: .codex, providerName: "Codex", fetchedAt: now,
            groups: [
                .init(id: "default", name: "", quotas: [.init(kind: .fiveHour, remainingPercent: 42, resetsAt: nil)])
            ],
            isHistorical: false)
        controller.update(snapshots: [sample], preferred: .codex, groupID: nil, enabled: true)
        try await wait { controller.writeFailed }
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Same rows as the failed attempt must not be deduplicated away.
        controller.update(snapshots: [sample], preferred: .codex, groupID: nil, enabled: true)
        try await wait { FileManager.default.fileExists(atPath: url.path) && !controller.writeFailed }
        guard try WidgetSharedStore.read(from: url).rows.first?.remainingPercent == 42 else {
            fatalError("Failed widget write did not recover")
        }
        controller.update(snapshots: [sample], preferred: .codex, groupID: nil, enabled: false)
        try await wait { (try? WidgetSharedStore.read(from: url).rows.isEmpty) == true }
        let unusedURL = directory.appendingPathComponent("unused/snapshot.json")
        let disabled = QuotaWidgetController(url: unusedURL)
        disabled.update(snapshots: [sample], preferred: .codex, groupID: nil, enabled: false)
        try await Task.sleep(for: .milliseconds(100))
        guard !FileManager.default.fileExists(atPath: unusedURL.path) else {
            fatalError("Sharing was enabled implicitly")
        }
        let antigravity = ProviderQuotaSnapshot(
            provider: .antigravity, providerName: "Antigravity", fetchedAt: now,
            groups: [
                .init(
                    id: "gemini", name: "Gemini", quotas: [.init(kind: .sevenDay, remainingPercent: 75, resetsAt: nil)]),
                .init(id: "argon", name: "Argon", quotas: [.init(kind: .sevenDay, remainingPercent: 25, resetsAt: nil)])
            ])
        controller.update(snapshots: [sample, antigravity], preferred: .codex, groupID: "argon", enabled: true)
        try await wait { (try? WidgetSharedStore.read(from: url).quotaChoices.count) == 3 }
        let shared = try WidgetSharedStore.read(from: url)
        guard shared.providerQuotas.map(\.id) == ["codex/default", "antigravity/argon"] else {
            fatalError("Automatic overview lost the preferred group")
        }
        let query = WidgetQuotaQuery(snapshotURL: url)
        let entities = try await query.suggestedEntities()
        guard
            entities.map(\.id) == [
                WidgetQuotaEntity.automaticID, "codex/default", "antigravity/argon", "antigravity/gemini"
            ]
        else {
            fatalError("Widget editor did not discover every quota")
        }
        let configuration = QuotaWidgetConfiguration()
        configuration.quota = entities.last
        guard configuration.selectionID == "antigravity/gemini",
            shared.quotas(selectionID: configuration.selectionID).first?.sevenDay?.remainingPercent == 75
        else {
            fatalError("Widget selected another group's quota")
        }
        controller.update(snapshots: [], preferred: .codex, groupID: nil, enabled: false)
        try await wait { (try? WidgetSharedStore.read(from: url).rows.isEmpty) == true }
        let restored = try await query.entities(for: ["antigravity/gemini"])
        guard restored.first?.id == "antigravity/gemini",
            try await query.suggestedEntities().map(\.id) == [WidgetQuotaEntity.automaticID],
            await query.defaultResult()?.id == WidgetQuotaEntity.automaticID
        else {
            fatalError("Empty shared data changed a saved choice or exposed stale choices")
        }
        print(
            "Widget probe passed: write recovery, opt-out, all model groups, intent discovery, selection and restoration"
        )
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        fatalError("Timed out waiting for widget persistence")
    }
}
