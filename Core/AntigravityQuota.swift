import Foundation

public enum QuotaProvider: String, Codable, CaseIterable, Sendable {
    public static let menuBarDefaultsKey = "menuBarQuotaProvider"
    public static let panelDefaultsKey = "quotaPanelProvider"
    public static let antigravityIntegrationDefaultsKey = "antigravityIntegrationEnabled"
    public static let claudeIntegrationDefaultsKey = "claudeIntegrationEnabled"
    public static let claudeCodeIntegrationDefaultsKey = "claudeCodeUsageQueryEnabled"

    case codex
    case antigravity
    case claudeCode
    /// Kept for decoding saved preferences from versions that offered Claude
    /// snapshots. It is never presented as an available quota source.
    case claude

    public var displayName: String {
        switch self {
        case .codex:
            L10n.text("provider.codex", fallback: "Codex")
        case .antigravity:
            L10n.text("provider.antigravity", fallback: "Antigravity")
        case .claude, .claudeCode:
            L10n.text("provider.claude", fallback: "Claude Code")
        }
    }

    /// Resolve saved selections without rewriting the user's preferences.
    /// Codex is always available. Other sources require enabled installations;
    /// the retired Claude snapshot selection always falls back to Codex.
    public func effectiveProvider(
        antigravityEnabled: Bool,
        antigravityAvailable: Bool,
        claudeCodeEnabled: Bool = false,
        claudeCodeAvailable: Bool = false
    ) -> QuotaProvider {
        switch self {
        case .codex:
            return .codex
        case .antigravity:
            return antigravityEnabled && antigravityAvailable ? .antigravity : .codex
        case .claude:
            return .codex
        case .claudeCode:
            return claudeCodeEnabled && claudeCodeAvailable ? .claudeCode : .codex
        }
    }

    /// Providers that should be offered in pickers, in display order.
    public static func visibleProviders(
        antigravityVisible: Bool,
        claudeCodeVisible: Bool = false
    ) -> [QuotaProvider] {
        [.codex] + (antigravityVisible ? [.antigravity] : [])
            + (claudeCodeVisible ? [.claudeCode] : [])
    }
}

public enum AntigravityQuotaTab: String, CaseIterable, Identifiable, Sendable {
    case gemini
    case argon = "gemini-argon-wtu"
    case thirdParty = "3p"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .gemini: "Gemini"
        case .argon: "Argon"
        case .thirdParty: "Claude / GPT"
        }
    }
}

public struct AntigravityQuotaGroup: Codable, Equatable, Identifiable, Sendable {
    public static let menuBarGroupDefaultsKey = "menuBarAntigravityQuotaGroup"
    public static let panelGroupDefaultsKey = "quotaPanelAntigravityGroup"

    public let id: String
    public let displayName: String
    public let description: String?
    public let fiveHour: QuotaWindow?
    public let sevenDay: QuotaWindow?
    public let isExhausted: Bool

    public init(
        id: String,
        displayName: String,
        description: String? = nil,
        fiveHour: QuotaWindow?,
        sevenDay: QuotaWindow?,
        isExhausted: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.isExhausted = isExhausted
    }

    public var localizedDisplayName: String {
        switch id.lowercased() {
        case "gemini":
            L10n.text("antigravity.group.gemini", fallback: "Gemini Models")
        case AntigravityQuotaTab.argon.rawValue:
            "Gemini 4 Argon"
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

    public func menuBarLines(for mode: MenuBarQuotaDisplayMode, now: Date? = nil) -> [String] {
        MenuBarQuotaLines.lines(for: orderedQuotas, mode: mode, now: now)
    }

    private var menuBarPrefix: String {
        switch id.lowercased() {
        case "gemini": "✦"
        case AntigravityQuotaTab.argon.rawValue: "✦"
        case "3p": "✳"
        default: "⟁"
        }
    }
}

public struct AntigravityQuotaSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let groups: [AntigravityQuotaGroup]
    public let subscriptionPlan: SubscriptionPlan?
    public let thirdPartyAvailability: AntigravityModelAvailability
    public let argonAvailability: AntigravityModelAvailability

    public init(
        fetchedAt: Date,
        groups: [AntigravityQuotaGroup],
        subscriptionPlan: SubscriptionPlan? = nil,
        thirdPartyAvailability: AntigravityModelAvailability = .unknown,
        argonAvailability: AntigravityModelAvailability = .unknown
    ) {
        self.fetchedAt = fetchedAt
        self.groups = groups
        self.subscriptionPlan = subscriptionPlan
        self.thirdPartyAvailability = thirdPartyAvailability
        self.argonAvailability = argonAvailability
    }

    /// Only presentation-safe values may reach the panel, settings or menu bar.
    /// Unknown entitlement keeps the selection, but suppresses protected pool numbers.
    public var displayGroups: [AntigravityQuotaGroup] {
        var result = groups.compactMap { group -> AntigravityQuotaGroup? in
            if group.id == AntigravityQuotaTab.argon.rawValue {
                switch argonAvailability {
                case .unavailable: return nil
                case .available: return group
                case .unknown:
                    return .init(id: group.id, displayName: group.displayName, fiveHour: nil, sevenDay: nil)
                }
            }
            guard group.id == "3p" else { return group }
            switch thirdPartyAvailability {
            case .unavailable: return nil
            case .available: return group
            case .unknown: return Self.thirdPartyPlaceholder
            }
        }
        if thirdPartyAvailability != .unavailable,
           !result.contains(where: { $0.id == "3p" }),
           thirdPartyAvailability == .available || groups.contains(where: { $0.id == "gemini" }) {
            result.append(Self.thirdPartyPlaceholder)
        }
        return result
    }

    public var panelGroups: [AntigravityQuotaGroup] {
        let displayed = displayGroups
        return AntigravityQuotaTab.allCases.compactMap { tab in
            displayed.first { $0.id == tab.rawValue }
        }
    }

    public var thirdPartyStatusMessage: String? {
        switch thirdPartyAvailability {
        case .available: nil
        case .unavailable:
            L10n.text("antigravity.models.unavailable", fallback: "No third-party models are available for this account.")
        case .unknown:
            L10n.text("antigravity.models.unknown", fallback: "Third-party model access could not be read. Try refreshing.")
        }
    }

    public func modelAccessIsUnknown(for groupID: String) -> Bool {
        (groupID == "3p" && thirdPartyAvailability == .unknown)
            || (groupID == AntigravityQuotaTab.argon.rawValue && argonAvailability == .unknown)
    }

    public func modelStatusMessage(for groupID: String) -> String? {
        if groupID == "3p" { return thirdPartyStatusMessage }
        guard groupID == AntigravityQuotaTab.argon.rawValue else { return nil }
        switch argonAvailability {
        case .available: return nil
        case .unavailable:
            return L10n.text("antigravity.argon.unavailable", fallback: "Gemini 4 Argon is not available for this account.")
        case .unknown:
            return L10n.text("antigravity.argon.unknown", fallback: "Gemini 4 Argon access could not be read. Try refreshing.")
        }
    }

    public func group(id: String?) -> AntigravityQuotaGroup? {
        let displayed = displayGroups
        return displayed.first { $0.id == id }
            ?? displayed.first { $0.id == "gemini" }
            ?? displayed.first
    }

    /// Never label an unknown pool as Gemini or Claude.
    public func panelGroup(id: String?) -> AntigravityQuotaGroup? {
        panelGroups.first { $0.id == id } ?? panelGroups.first
    }

    /// Persist a fallback only after a successful, explicit entitlement denial.
    /// Temporary read failures must not overwrite either independent selection.
    public func reconcileUnavailableSelections(in defaults: UserDefaults) {
        guard displayGroups.contains(where: { $0.id == "gemini" }) else { return }
        let denied = [
            thirdPartyAvailability == .unavailable ? "3p" : nil,
            argonAvailability == .unavailable ? AntigravityQuotaTab.argon.rawValue : nil
        ].compactMap { $0 }
        for key in [AntigravityQuotaGroup.panelGroupDefaultsKey, AntigravityQuotaGroup.menuBarGroupDefaultsKey]
            where defaults.string(forKey: key).map(denied.contains) == true {
            defaults.set("gemini", forKey: key)
        }
    }

    private static var thirdPartyPlaceholder: AntigravityQuotaGroup {
        .init(id: "3p", displayName: "Claude and GPT Models", fiveHour: nil, sevenDay: nil)
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
                sevenDay: windows[.sevenDay],
                isExhausted: (rawGroup.buckets ?? []).contains {
                    quotaKind(window: $0.window, bucketID: $0.bucketId) != nil
                        && ($0.remainingFraction.map { $0.isFinite && $0 <= 0 } ?? false)
                }
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
            subscriptionPlan: plan,
            thirdPartyAvailability: AntigravityModelAccessParser.thirdPartyAvailability(data: userStatusData),
            argonAvailability: AntigravityModelAccessParser.argonAvailability(data: userStatusData)
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
            subscriptionPlan: SubscriptionPlan(identifier: "g1-pro-tier"),
            thirdPartyAvailability: .available
        )
    }()
}
