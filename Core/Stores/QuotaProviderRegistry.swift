import Foundation
import Observation

public enum ProviderViewKind: Sendable {
    case codex, antigravity, claudeCode, standard
}

public struct ProviderDescriptor: Sendable {
    public let id: QuotaProvider
    public let title: String
    public let symbol: String
    public let viewKind: ProviderViewKind

    public init(id: QuotaProvider, title: String, symbol: String, viewKind: ProviderViewKind = .standard) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.viewKind = viewKind
    }
}

/// Implement one adapter and register it; coordinators and common views do not
/// need another provider-specific branch. Adapters own their authentication policy.
@MainActor
public protocol QuotaProviderPlugin: AnyObject {
    var descriptor: ProviderDescriptor { get }
    var store: any QuotaProviderStore { get }
    var isEnabled: Bool { get }
    var isInstalled: Bool { get }
    func snapshot(at now: Date) -> ProviderQuotaSnapshot?
    func start()
    func stop()
}

public enum ProviderRegistryError: Error, Equatable {
    case duplicateIdentifier(String)
    case missingFallback
    case cannotRemoveFallback
}

@MainActor @Observable
public final class QuotaProviderRegistry {
    public private(set) var plugins: [any QuotaProviderPlugin]
    public let fallback: QuotaProvider
    private var preferenceRevision = 0

    public init(plugins: [any QuotaProviderPlugin], fallback: QuotaProvider = .codex) throws {
        var identifiers = Set<QuotaProvider>()
        for plugin in plugins {
            guard identifiers.insert(plugin.descriptor.id).inserted else {
                throw ProviderRegistryError.duplicateIdentifier(plugin.descriptor.id.rawValue)
            }
        }
        guard identifiers.contains(fallback) else { throw ProviderRegistryError.missingFallback }
        self.plugins = plugins
        self.fallback = fallback
    }

    public func register(_ plugin: any QuotaProviderPlugin) throws {
        guard self.plugin(for: plugin.descriptor.id) == nil else {
            throw ProviderRegistryError.duplicateIdentifier(plugin.descriptor.id.rawValue)
        }
        plugins.append(plugin)
    }

    public func unregister(_ id: QuotaProvider) throws {
        guard id != fallback else { throw ProviderRegistryError.cannotRemoveFallback }
        plugin(for: id)?.stop()
        plugins.removeAll { $0.descriptor.id == id }
    }

    public func plugin(for id: QuotaProvider) -> (any QuotaProviderPlugin)? {
        plugins.first { $0.descriptor.id == id }
    }

    public var visibleProviders: [QuotaProvider] {
        _ = preferenceRevision
        return plugins.filter { $0.descriptor.id == fallback || ($0.isEnabled && $0.isInstalled) }
            .map { $0.descriptor.id }
    }

    public func resolve(_ saved: QuotaProvider) -> QuotaProvider {
        visibleProviders.contains(saved) ? saved : fallback
    }

    public func store(for saved: QuotaProvider) -> any QuotaProviderStore {
        // The fallback is present by construction and cannot be unregistered.
        plugin(for: resolve(saved))!.store
    }

    public func invalidatePreferences() { preferenceRevision &+= 1 }

    public func startEnabledProviders() {
        for plugin in plugins where visibleProviders.contains(plugin.descriptor.id) { plugin.start() }
    }

    public func stop() { plugins.forEach { $0.stop() } }

    public func snapshots(at now: Date) -> [ProviderQuotaSnapshot] {
        plugins.filter { visibleProviders.contains($0.descriptor.id) && $0.store.phase == .ready }
            .compactMap { $0.snapshot(at: now) }
    }

    public func displaySnapshots(at now: Date) -> [ProviderQuotaSnapshot] {
        plugins.filter { visibleProviders.contains($0.descriptor.id) }.compactMap { plugin in
            guard let value = plugin.snapshot(at: now) else { return nil }
            if case .failed = plugin.store.phase {
                return .init(
                    provider: value.provider, providerName: value.providerName, fetchedAt: value.fetchedAt,
                    groups: value.groups, planName: value.planName, isHistorical: true,
                    isQuerySnapshot: value.isQuerySnapshot)
            }
            return value
        }
    }
}

@MainActor
private final class BuiltInQuotaPlugin: QuotaProviderPlugin {
    let descriptor: ProviderDescriptor
    let store: any QuotaProviderStore
    private let enabled: () -> Bool
    private let installed: () -> Bool
    private let read: (Date) -> ProviderQuotaSnapshot?
    private let begin: () -> Void
    private let end: () -> Void
    var isEnabled: Bool { enabled() }
    var isInstalled: Bool { installed() }

    init(
        descriptor: ProviderDescriptor, store: any QuotaProviderStore,
        enabled: @escaping () -> Bool, installed: @escaping () -> Bool,
        read: @escaping (Date) -> ProviderQuotaSnapshot?,
        start: @escaping () -> Void, stop: @escaping () -> Void
    ) {
        self.descriptor = descriptor
        self.store = store
        self.enabled = enabled
        self.installed = installed
        self.read = read
        self.begin = start
        self.end = stop
    }

    func snapshot(at now: Date) -> ProviderQuotaSnapshot? { read(now) }
    func start() { begin() }
    func stop() { end() }
}

extension QuotaProviderRegistry {
    static func builtIn(
        codex: UsageStore, antigravity: AntigravityUsageStore,
        claudeCode: ClaudeCodeUsageStore, defaults: UserDefaults = .standard
    ) -> QuotaProviderRegistry {
        let codexPlugin = BuiltInQuotaPlugin(
            descriptor: .init(id: .codex, title: QuotaProvider.codex.displayName, symbol: "terminal", viewKind: .codex),
            store: codex, enabled: { true }, installed: { true },
            read: { now in
                codex.snapshot.map {
                    ProviderQuotaSnapshot(
                        provider: .codex, providerName: QuotaProvider.codex.displayName,
                        fetchedAt: $0.fetchedAt, groups: [.init(id: "default", name: "", quotas: $0.orderedQuotas)],
                        planName: $0.subscriptionPlan?.displayName,
                        isHistorical: codex.isCached
                            || (codex.expiryReferenceDate != nil
                                && now.timeIntervalSince($0.fetchedAt)
                                    > max(600, RefreshInterval.seconds(in: defaults) * 2))
                    )
                }
            }, start: { codex.start() }, stop: { codex.stop() })
        let agPlugin = BuiltInQuotaPlugin(
            descriptor: .init(
                id: .antigravity, title: QuotaProvider.antigravity.displayName, symbol: "sparkles",
                viewKind: .antigravity),
            store: antigravity, enabled: { ProviderAvailability.antigravityIntegrationEnabled(in: defaults) },
            installed: { antigravity.isInstalled },
            read: { now in
                antigravity.snapshot.map { snapshot in
                    ProviderQuotaSnapshot(
                        provider: .antigravity, providerName: QuotaProvider.antigravity.displayName,
                        fetchedAt: snapshot.fetchedAt,
                        groups: snapshot.displayGroups.map { group in
                            .init(
                                id: group.id, name: group.localizedDisplayName, quotas: group.orderedQuotas,
                                statusMessage: snapshot.modelStatusMessage(for: group.id))
                        },
                        planName: snapshot.subscriptionPlan?.displayName,
                        isHistorical: antigravity.expiryReferenceDate != nil
                            && now.timeIntervalSince(snapshot.fetchedAt)
                                > max(600, RefreshInterval.seconds(in: defaults) * 2)
                    )
                }
            }, start: { antigravity.start() }, stop: { antigravity.stop() })
        let claudePlugin = BuiltInQuotaPlugin(
            descriptor: .init(
                id: .claudeCode, title: QuotaProvider.claudeCode.displayName, symbol: "asterisk", viewKind: .claudeCode),
            store: claudeCode, enabled: { claudeCode.isEnabled }, installed: { claudeCode.isInstalled },
            read: { now in
                claudeCode.snapshot.map {
                    ProviderQuotaSnapshot(
                        provider: .claudeCode, providerName: QuotaProvider.claudeCode.displayName,
                        fetchedAt: $0.lastCallbackAt,
                        groups: [.init(id: "default", name: "", quotas: $0.displayableQuotas(at: now))],
                        planName: claudeCode.subscriptionPlan?.displayName,
                        isHistorical: claudeCode.isHistorical(at: now)
                            || $0.orderedReports.contains { $0.isExpired(at: now) },
                        isQuerySnapshot: true)
                }
            }, start: { claudeCode.start() }, stop: { claudeCode.stop() })
        return try! QuotaProviderRegistry(plugins: [codexPlugin, agPlugin, claudePlugin])
    }
}
