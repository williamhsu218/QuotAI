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
        print("Widget recovery probe passed: identical-data retry, opt-out clearing, no implicit sharing")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        fatalError("Timed out waiting for widget persistence")
    }
}
