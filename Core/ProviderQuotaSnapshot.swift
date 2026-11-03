import Foundation

/// Presentation-safe values shared by registered providers and optional features.
/// No account identifiers, credentials, conversations or raw responses are stored.
public struct ProviderQuotaGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let quotas: [QuotaWindow]
    public let statusMessage: String?

    public init(id: String, name: String, quotas: [QuotaWindow], statusMessage: String? = nil) {
        self.id = id
        self.name = name
        self.quotas = quotas
        self.statusMessage = statusMessage
    }
}

public struct ProviderQuotaSnapshot: Codable, Equatable, Sendable {
    public let provider: QuotaProvider
    public let providerName: String
    public let fetchedAt: Date
    public let groups: [ProviderQuotaGroup]
    public let planName: String?
    public let isHistorical: Bool
    public let isQuerySnapshot: Bool

    public init(
        provider: QuotaProvider, providerName: String, fetchedAt: Date,
        groups: [ProviderQuotaGroup], planName: String? = nil,
        isHistorical: Bool = false, isQuerySnapshot: Bool = false
    ) {
        self.provider = provider
        self.providerName = providerName
        self.fetchedAt = fetchedAt
        self.groups = groups
        self.planName = planName
        self.isHistorical = isHistorical
        self.isQuerySnapshot = isQuerySnapshot
    }

    public func group(id: String?) -> ProviderQuotaGroup? {
        groups.first { $0.id == id } ?? groups.first { $0.id == "gemini" } ?? groups.first
    }
}
