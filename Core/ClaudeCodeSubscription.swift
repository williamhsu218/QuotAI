import Foundation

/// Claude's plan identifiers have their own meaning, independent of Codex.
/// `max` does not identify a multiplier, so it is displayed simply as Max.
public enum ClaudeCodeSubscriptionPlan: String, Codable, Equatable, Sendable {
    case pro, max, team, enterprise

    public var displayName: String {
        switch self {
        case .pro: "Pro"
        case .max: "Max"
        case .team: "Team"
        case .enterprise: "Enterprise"
        }
    }
}

public enum ClaudeCodeSubscriptionParser {
    public static let outputLimit = 16_384

    /// The documented auth-status command owns credential access. Only its
    /// subscription type is retained; no email, account ID or raw JSON is saved.
    public static func parse(_ data: Data) throws -> ClaudeCodeSubscriptionPlan? {
        guard data.count <= outputLimit else { throw ClaudeUsageQueryError.oversizedOutput }
        struct Status: Decodable {
            let loggedIn: Bool
            let authMethod: String?
            let apiProvider: String?
            let subscriptionType: String?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else {
            throw ClaudeUsageQueryError.invalidOutput
        }
        guard status.loggedIn, status.authMethod == "claude.ai", status.apiProvider == "firstParty",
              let identifier = status.subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return nil }
        return ClaudeCodeSubscriptionPlan(rawValue: identifier)
    }
}

public enum ClaudeCodeSubscriptionCache {
    private struct Archive: Codable { let version: Int; let plan: ClaudeCodeSubscriptionPlan }
    public static var url: URL {
        ClaudeCodeStatusLineConfiguration.supportDirectory.appendingPathComponent("claude-subscription-v1.json")
    }
    public static func read(from url: URL = url) throws -> ClaudeCodeSubscriptionPlan? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let archive = try JSONDecoder().decode(Archive.self, from: ClaudeCodePrivateFile.read(url, limit: 1_024))
        guard archive.version == 1 else { throw ClaudeUsageQueryError.invalidOutput }
        return archive.plan
    }
    public static func write(_ plan: ClaudeCodeSubscriptionPlan?, to url: URL = url) throws {
        guard let plan else { try clear(at: url); return }
        try ClaudeCodePrivateFile.atomicWrite(JSONEncoder().encode(Archive(version: 1, plan: plan)), to: url, permissions: 0o600)
    }
    public static func clear(at url: URL = url) throws {
        try ClaudeCodePrivateFile.rejectSymlink(url)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
