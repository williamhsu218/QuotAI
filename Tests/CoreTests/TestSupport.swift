import Foundation
import Testing

/// A temporary directory without symbolic links in its path. Private cache
/// writes reject symlinked ancestors such as macOS's /var → /private/var.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(resolved) }
        url = URL(fileURLWithPath: String(cString: resolved))
            .appendingPathComponent("QuotAI-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// A private UserDefaults suite, so tests never read or write real preferences.
struct IsolatedDefaults {
    let suiteName = "QuotAI.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw CocoaError(.featureUnsupported) }
        self.defaults = defaults
    }

    func remove() { defaults.removePersistentDomain(forName: suiteName) }
}

/// Polls for an awaited state instead of assuming a fixed delay.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while true {
        if await condition() { return }
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting until \(description)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Holds injected work until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Records the values injected work was called with.
actor CallLog<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

/// A thread-safe value that injected synchronous closures can read.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
