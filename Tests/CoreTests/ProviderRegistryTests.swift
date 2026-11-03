import Foundation
import Testing

@testable import QuotAICore

@MainActor
private final class RegistryFixtureStore: QuotaProviderStore {
    var phase: ProviderPhase = .ready
    var refreshes = 0
    var isLoading: Bool { phase == .loading }
    var expiryReferenceDate: Date? { nil }
    func statusMessage(at now: Date) -> String { "fixture" }
    func userRefresh() async { refreshes += 1 }
}

@MainActor
private final class RegistryFixturePlugin: QuotaProviderPlugin {
    let descriptor: ProviderDescriptor
    let fixture = RegistryFixtureStore()
    var store: any QuotaProviderStore { fixture }
    var isEnabled = true
    var isInstalled = true
    var starts = 0
    var stops = 0
    init(_ id: QuotaProvider) { descriptor = .init(id: id, title: id.displayName, symbol: "star") }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func snapshot(at now: Date) -> ProviderQuotaSnapshot? {
        .init(
            provider: descriptor.id, providerName: descriptor.title, fetchedAt: now,
            groups: [
                .init(
                    id: "default", name: "",
                    quotas: [.init(kind: .fiveHour, remainingPercent: 37, resetsAt: now.addingTimeInterval(60))])
            ])
    }
}

@MainActor @Suite("Provider registry")
struct ProviderRegistryTests {
    @Test("Built-in preference strings retain their single-value JSON representation")
    func identityCompatibility() throws {
        for id in QuotaProvider.allCases {
            let data = try JSONEncoder().encode(id)
            #expect(try JSONDecoder().decode(String.self, from: data) == id.rawValue)
            #expect(try JSONDecoder().decode(QuotaProvider.self, from: data) == id)
        }
        #expect(QuotaProvider(rawValue: "claude") == nil)
        #expect(QuotaProvider(rawValue: "unregistered") == nil)
    }

    @Test("A fourth adapter registers without changing coordinator switches")
    func dynamicAdapter() async throws {
        let fallback = RegistryFixturePlugin(.codex)
        let id = try #require(QuotaProvider(rawValue: "plugin.test"))
        let added = RegistryFixturePlugin(id)
        let registry = try QuotaProviderRegistry(plugins: [fallback])
        try registry.register(added)
        #expect(registry.visibleProviders == [.codex, id])
        #expect(registry.resolve(id) == id)
        await registry.store(for: id).userRefresh()
        #expect(added.fixture.refreshes == 1 && fallback.fixture.refreshes == 0)
        registry.startEnabledProviders()
        #expect(added.starts == 1)
        let value = try #require(added.snapshot(at: Date()))
        let presentation = MenuBarPresentation(
            provider: id, title: "Test", symbol: "star", snapshot: value,
            selectedGroupID: nil, mode: .both, isStayAwakeActive: false, now: nil)
        #expect(presentation.provider == id && presentation.lines == ["5h 37%"] && presentation.icon == .symbol("star"))
    }

    @Test("Disabled or uninstalled adapters fall back without rewriting the saved identifier")
    func unavailableFallback() throws {
        let id = try #require(QuotaProvider(rawValue: "plugin.test"))
        let added = RegistryFixturePlugin(id)
        let registry = try QuotaProviderRegistry(plugins: [RegistryFixturePlugin(.codex), added])
        added.isEnabled = false
        #expect(registry.resolve(id) == .codex)
        added.isEnabled = true
        added.isInstalled = false
        #expect(registry.resolve(id) == .codex)
        added.isInstalled = true
        #expect(registry.resolve(id) == id)
    }

    @Test("Failed reads remain available for display but never count as fresh; unregister stops the adapter")
    func staleProjectionAndRemoval() throws {
        let fallback = RegistryFixturePlugin(.codex)
        let id = try #require(QuotaProvider(rawValue: "plugin.test"))
        let added = RegistryFixturePlugin(id)
        let registry = try QuotaProviderRegistry(plugins: [fallback, added])
        added.fixture.phase = .failed("fixture failure")
        let now = Date()
        #expect(registry.snapshots(at: now).map(\.provider) == [.codex])
        let display = try #require(registry.displaySnapshots(at: now).first { $0.provider == id })
        #expect(display.isHistorical && display.groups.first?.quotas.first?.remainingPercent == 37)
        try registry.unregister(id)
        #expect(added.stops == 1 && registry.resolve(id) == .codex)
    }

    @Test("Duplicate identifiers and removal of the fallback are rejected")
    func invalidRegistration() throws {
        let registry = try QuotaProviderRegistry(plugins: [RegistryFixturePlugin(.codex)])
        #expect(throws: ProviderRegistryError.duplicateIdentifier("codex")) {
            try registry.register(RegistryFixturePlugin(.codex))
        }
        #expect(throws: ProviderRegistryError.cannotRemoveFallback) { try registry.unregister(.codex) }
        #expect(throws: ProviderRegistryError.missingFallback) { try QuotaProviderRegistry(plugins: []) }
    }
}
