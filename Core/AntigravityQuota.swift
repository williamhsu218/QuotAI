import Foundation

public enum QuotaProvider: String, Codable, CaseIterable, Sendable {
    public static let menuBarDefaultsKey = "menuBarQuotaProvider"
    public static let panelDefaultsKey = "quotaPanelProvider"
    public static let antigravityIntegrationDefaultsKey = "antigravityIntegrationEnabled"

    case codex
    case antigravity

    public var displayName: String {
        switch self {
        case .codex:
            L10n.text("provider.codex", fallback: "Codex")
        case .antigravity:
            L10n.text("provider.antigravity", fallback: "Antigravity")
        }
    }

    public func effectiveProvider(
        antigravityEnabled: Bool,
        antigravityAvailable: Bool
    ) -> QuotaProvider {
        guard self == .antigravity,
              antigravityEnabled,
              antigravityAvailable else {
            return .codex
        }
        return .antigravity
    }
}

public struct AntigravityQuotaGroup: Codable, Equatable, Identifiable, Sendable {
    public static let menuBarGroupDefaultsKey = "menuBarAntigravityQuotaGroup"

    public let id: String
    public let displayName: String
    public let description: String?
    public let fiveHour: QuotaWindow?
    public let sevenDay: QuotaWindow?

    public init(
        id: String,
        displayName: String,
        description: String? = nil,
        fiveHour: QuotaWindow?,
        sevenDay: QuotaWindow?
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public var localizedDisplayName: String {
        switch id.lowercased() {
        case "gemini":
            L10n.text("antigravity.group.gemini", fallback: "Gemini Models")
        case "3p":
            L10n.text(
                "antigravity.group.third_party",
                fallback: "Claude and GPT Models"
            )
        default:
            displayName
        }
    }

    public var orderedQuotas: [QuotaWindow] {
        [fiveHour, sevenDay].compactMap { $0 }
    }

    public func menuBarTitle(for mode: MenuBarQuotaDisplayMode) -> String {
        let quotasByKind = Dictionary(
            uniqueKeysWithValues: orderedQuotas.map { ($0.kind, $0) }
        )
        let parts = mode.selectedKinds.compactMap { kind -> String? in
            if let quota = quotasByKind[kind] {
                return "\(kind.shortLabel) \(quota.remainingPercent)%"
            }
            return mode == .both ? nil : "\(kind.shortLabel) --"
        }
        return parts.isEmpty
            ? "\(menuBarPrefix) --"
            : "\(menuBarPrefix) \(parts.joined(separator: " · "))"
    }

    private var menuBarPrefix: String {
        switch id.lowercased() {
        case "gemini": "✦"
        case "3p": "✳"
        default: "⟁"
        }
    }
}

public struct AntigravityQuotaSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let groups: [AntigravityQuotaGroup]
    public let subscriptionPlan: SubscriptionPlan?

    public init(
        fetchedAt: Date,
        groups: [AntigravityQuotaGroup],
        subscriptionPlan: SubscriptionPlan? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.groups = groups
        self.subscriptionPlan = subscriptionPlan
    }

    public func group(id: String?) -> AntigravityQuotaGroup? {
        guard let id, !id.isEmpty else { return groups.first }
        return groups.first { $0.id == id } ?? groups.first
    }
}

public enum AntigravityQuotaParserError: LocalizedError, Equatable {
    case missingResponse
    case missingGroups
    case missingRecognizableQuotas

    public var errorDescription: String? {
        switch self {
        case .missingResponse:
            L10n.text(
                "error.antigravity.missing_response",
                fallback: "Antigravity returned unrecognized quota data."
            )
        case .missingGroups:
            L10n.text(
                "error.antigravity.missing_groups",
                fallback: "Antigravity returned no quota groups."
            )
        case .missingRecognizableQuotas:
            L10n.text(
                "error.antigravity.missing_limits",
                fallback: "Antigravity returned no recognizable quota windows."
            )
        }
    }
}

public enum AntigravityQuotaParser {
    public static func parse(
        data: Data,
        userStatusData: Data? = nil,
        fetchedAt: Date = Date()
    ) throws -> AntigravityQuotaSnapshot {
        let envelope: AntigravityQuotaEnvelope
        do {
            envelope = try JSONDecoder().decode(AntigravityQuotaEnvelope.self, from: data)
        } catch {
            throw AntigravityQuotaParserError.missingResponse
        }

        guard let rawGroups = envelope.response?.groups ?? envelope.groups else {
            throw AntigravityQuotaParserError.missingResponse
        }
        guard !rawGroups.isEmpty else {
            throw AntigravityQuotaParserError.missingGroups
        }

        var usedIdentifiers: Set<String> = []
        let groups = rawGroups.compactMap { rawGroup -> AntigravityQuotaGroup? in
            let recognizedBuckets = (rawGroup.buckets ?? []).compactMap { bucket -> (QuotaKind, QuotaWindow)? in
                guard let kind = quotaKind(window: bucket.window, bucketID: bucket.bucketId),
                      let remainingFraction = bucket.remainingFraction,
                      remainingFraction.isFinite else {
                    return nil
                }
                let percentage = Int((remainingFraction * 100).rounded())
                return (
                    kind,
                    QuotaWindow(
                        kind: kind,
                        remainingPercent: percentage,
                        resetsAt: parseDate(bucket.resetTime)
                    )
                )
            }

            guard !recognizedBuckets.isEmpty else { return nil }
            let baseIdentifier = groupIdentifier(
                displayName: rawGroup.displayName,
                bucketIDs: (rawGroup.buckets ?? []).compactMap { bucket in
                    quotaKind(window: bucket.window, bucketID: bucket.bucketId) == nil
                        ? nil
                        : bucket.bucketId
                }
            )
            let identifier = uniqueIdentifier(baseIdentifier, used: &usedIdentifiers)
            let windows = Dictionary(recognizedBuckets, uniquingKeysWith: { _, latest in latest })
            let displayName = rawGroup.displayName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return AntigravityQuotaGroup(
                id: identifier,
                displayName: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? identifier,
                description: rawGroup.description,
                fiveHour: windows[.fiveHour],
                sevenDay: windows[.sevenDay]
            )
        }

        guard !groups.isEmpty else {
            throw AntigravityQuotaParserError.missingRecognizableQuotas
        }

        var rawPlanType = envelope.response?.planType ?? envelope.planType
        if (rawPlanType == nil || rawPlanType?.isEmpty == true), let userStatusData {
            if let userStatusEnvelope = try? JSONDecoder().decode(AntigravityUserStatusEnvelope.self, from: userStatusData) {
                let statusBody = userStatusEnvelope.userStatus ?? userStatusEnvelope.response?.userStatus
                let tier = statusBody?.userTier ?? userStatusEnvelope.userTier ?? userStatusEnvelope.response?.userTier
                let planInfo = statusBody?.planStatus?.planInfo
                rawPlanType = tier?.name ?? tier?.id ?? planInfo?.planName ?? planInfo?.teamsTier
            }
        }
        let plan = SubscriptionPlan(identifier: rawPlanType)

        return AntigravityQuotaSnapshot(
            fetchedAt: fetchedAt,
            groups: groups,
            subscriptionPlan: plan
        )
    }

    private static func quotaKind(window: String?, bucketID: String?) -> QuotaKind? {
        let normalizedWindow = window?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedWindow {
        case "5h", "five_hour", "five-hour", "fivehour":
            return .fiveHour
        case "weekly", "week", "7d", "seven_day", "seven-day":
            return .sevenDay
        default:
            break
        }

        let normalizedID = bucketID?.lowercased() ?? ""
        if normalizedID.hasSuffix("-5h") || normalizedID.hasSuffix("_5h") {
            return .fiveHour
        }
        if normalizedID.hasSuffix("-weekly") || normalizedID.hasSuffix("_weekly") {
            return .sevenDay
        }
        return nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func groupIdentifier(
        displayName: String?,
        bucketIDs: [String]
    ) -> String {
        let stems = Set(bucketIDs.compactMap { bucketID -> String? in
            let normalized = bucketID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return nil }
            for suffix in ["-weekly", "_weekly", "-5h", "_5h"]
                where normalized.hasSuffix(suffix) {
                return String(normalized.dropLast(suffix.count))
            }
            return normalized
        })
        if stems.count == 1, let identifier = stems.first, !identifier.isEmpty {
            return identifier
        }

        let slug = (displayName ?? "")
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { result, character in
                if character != "-" || result.last != "-" {
                    result.append(character)
                }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "antigravity" : slug
    }

    private static func uniqueIdentifier(
        _ base: String,
        used: inout Set<String>
    ) -> String {
        if used.insert(base).inserted { return base }
        var suffix = 2
        while !used.insert("\(base)-\(suffix)").inserted {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }
}

private struct AntigravityQuotaEnvelope: Decodable {
    let response: AntigravityQuotaResponse?
    let groups: [AntigravityQuotaGroupDTO]?
    let planType: String?
}

private struct AntigravityQuotaResponse: Decodable {
    let groups: [AntigravityQuotaGroupDTO]?
    let planType: String?
}

private struct AntigravityQuotaGroupDTO: Decodable {
    let displayName: String?
    let description: String?
    let buckets: [AntigravityQuotaBucketDTO]?
}

private struct AntigravityQuotaBucketDTO: Decodable {
    let bucketId: String?
    let window: String?
    let remainingFraction: Double?
    let resetTime: String?
}

private struct AntigravityUserStatusEnvelope: Decodable {
    let response: AntigravityUserStatusResponseDTO?
    let userStatus: AntigravityUserStatusBodyDTO?
    let userTier: AntigravityUserTierDTO?
}

private struct AntigravityUserStatusResponseDTO: Decodable {
    let userStatus: AntigravityUserStatusBodyDTO?
    let userTier: AntigravityUserTierDTO?
}

private struct AntigravityUserStatusBodyDTO: Decodable {
    let userTier: AntigravityUserTierDTO?
    let planStatus: AntigravityPlanStatusDTO?
    let name: String?
    let email: String?
}

private struct AntigravityPlanStatusDTO: Decodable {
    let planInfo: AntigravityPlanInfoDTO?
}

private struct AntigravityPlanInfoDTO: Decodable {
    let planName: String?
    let teamsTier: String?
}

private struct AntigravityUserTierDTO: Decodable {
    let id: String?
    let name: String?
    let description: String?
}

public extension AntigravityQuotaSnapshot {
    static let preview: AntigravityQuotaSnapshot = {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = timeZone
            components.year = 2026
            components.month = 8
            components.day = day
            components.hour = hour
            components.minute = minute
            return components.date!
        }

        return AntigravityQuotaSnapshot(
            fetchedAt: date(20, 18, 12),
            groups: [
                AntigravityQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini Models",
                    description: nil,
                    fiveHour: QuotaWindow(
                        kind: .fiveHour,
                        remainingPercent: 76,
                        resetsAt: date(20, 21, 5)
                    ),
                    sevenDay: QuotaWindow(
                        kind: .sevenDay,
                        remainingPercent: 61,
                        resetsAt: date(25, 9, 0)
                    )
                ),
                AntigravityQuotaGroup(
                    id: "3p",
                    displayName: "Claude and GPT models",
                    description: nil,
                    fiveHour: QuotaWindow(
                        kind: .fiveHour,
                        remainingPercent: 44,
                        resetsAt: date(20, 22, 18)
                    ),
                    sevenDay: QuotaWindow(
                        kind: .sevenDay,
                        remainingPercent: 28,
                        resetsAt: date(24, 17, 30)
                    )
                )
            ],
            subscriptionPlan: SubscriptionPlan(identifier: "g1-pro-tier")
        )
    }()
}
