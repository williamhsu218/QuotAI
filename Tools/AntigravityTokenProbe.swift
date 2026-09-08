import Foundation

/// Read-only acceptance probe. Defaults to the store trigger/cancellation test.
/// --local reads at most two bounded slices from real AG metadata, with a
/// disposable private cache; it prints diagnostics, never token values or IDs.
@main
struct AntigravityTokenProbe {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--local") {
            let cacheRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("quotai-token-probe-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: cacheRoot) }
            let reader = AntigravityTokenReader(cacheURL: cacheRoot.appendingPathComponent("cache.sqlite"))
            for round in 1...2 {
                let start = ProcessInfo.processInfo.systemUptime
                let snapshot = try await reader.read()
                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                print("round=\(round) wallMs=\(Int(ms)) rowsRead=\(snapshot.rowsRead) stepRowsRead=\(snapshot.stepRowsRead) bytesRead=\(snapshot.bytesRead) files=\(snapshot.files) pending=\(snapshot.pendingFiles) unavailable=\(snapshot.unavailableFiles) excluded=\(snapshot.skippedRecords) undated=\(snapshot.undatedGenerations) datedDays=\(snapshot.dailyBuckets.count)")
            }
            return
        }
        let spy = ReadSpy()
        let store = AntigravityTokenStore(readSnapshot: { await spy.read() })
        try await Task.sleep(for: .milliseconds(100))
        let startupCount = await spy.count
        precondition(startupCount == 0, "Store initialization must not read")
        async let first: Void = store.refresh()
        async let duplicate: Void = store.refresh()
        _ = await (first, duplicate)
        let overlapCount = await spy.count
        precondition(overlapCount == 1, "Overlapping requests must coalesce")
        precondition(store.snapshot != nil)
        try await Task.sleep(for: .milliseconds(100))
        let idleCount = await spy.count
        precondition(idleCount == 1, "No polling after the request")
        let preview = AntigravityTokenStore(previewMode: true, readSnapshot: { await spy.read() })
        await preview.refresh()
        let previewCount = await spy.count
        precondition(previewCount == 1, "Preview must not touch real data")
        let cancelStore = AntigravityTokenStore(readSnapshot: { await spy.read() })
        let cancellation = Task { await cancelStore.refresh() }
        while await spy.count < 2 { await Task.yield() }
        cancellation.cancel()
        await cancellation.value
        precondition(cancelStore.snapshot == nil && !cancelStore.failed && !cancelStore.isLoading,
                     "Cancellation must not publish stale data or an error")
        let errorStore = AntigravityTokenStore(readSnapshot: { throw TokenUsageReadError.unavailable })
        await errorStore.refresh()
        precondition(errorStore.failed && errorStore.snapshot == nil && !errorStore.isLoading)
        print("PASS on-demand store: zero startup/idle reads; one overlapping read; preview isolated; cancellation and errors handled")
    }
}

private actor ReadSpy {
    private(set) var count = 0
    func read() async -> AntigravityTokenSnapshot {
        count += 1
        try? await Task.sleep(for: .milliseconds(20))
        return .preview
    }
}
