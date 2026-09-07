import Foundation

public struct SubscriptionPlan: Codable, Equatable, Sendable {
    public let identifier: String

    public init?(identifier: String?) {
        guard let identifier else { return nil }
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty, normalized != "unknown" else { return nil }
        self.identifier = normalized
    }

    public var displayName: String {
        switch identifier {
        case "free":
            "Free"
        case "go":
            "Go"
        case "plus":
            "Plus"
        case "pro":
            "Pro20x"
        case "prolite":
            "Pro 5x"
        case "g1-pro-tier", "google_ai_pro", "google ai pro", "ai_pro", "ai pro", "teams_tier_pro":
            "Pro"
        case "ultra", "ai_ultra", "ai ultra", "g1-ultra-tier", "google_ai_ultra", "google ai ultra", "teams_tier_pro_ultimate", "teams_tier_ultra":
            "Ultra"
        case "team", "teams_tier_teams":
            "Team"
        case "self_serve_business_usage_based", "business":
            "Business"
        case "enterprise_cbp_usage_based", "enterprise", "teams_tier_enterprise_self_hosted", "teams_tier_enterprise_saas":
            "Enterprise"
        case "edu":
            "Edu"
        default:
            identifier
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

public enum QuotaKind: String, Codable, CaseIterable, Sendable {
    case fiveHour
    case sevenDay

    public var shortLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        }
    }

    public var displayName: String {
        switch self {
        case .fiveHour:
            L10n.text("quota.five_hour", fallback: "5 hours")
        case .sevenDay:
            L10n.text("quota.seven_day", fallback: "7 days")
        }
    }
}

public enum MenuBarQuotaDisplayMode: String, Codable, CaseIterable, Sendable {
    public static let defaultsKey = "menuBarQuotaDisplayMode"

    case fiveHour
    case sevenDay
    case both

    public var selectedKinds: [QuotaKind] {
        switch self {
        case .fiveHour:
            [.fiveHour]
        case .sevenDay:
            [.sevenDay]
        case .both:
            [.fiveHour, .sevenDay]
        }
    }
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public let kind: QuotaKind
    public let remainingPercent: Int
    public let resetsAt: Date?

    public var id: QuotaKind { kind }

    public init(kind: QuotaKind, remainingPercent: Int, resetsAt: Date?) {
        self.kind = kind
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
    }
}

public struct ResetCredit: Codable, Equatable, Identifiable, Sendable {
    public let grantedAt: Date
    public let expiresAt: Date?
    public let status: String

    public var id: String {
        "\(Int(grantedAt.timeIntervalSince1970))-\(Int(expiresAt?.timeIntervalSince1970 ?? 0))"
    }

    public init(grantedAt: Date, expiresAt: Date?, status: String) {
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.status = status
    }
}

public struct DailyUsageBucket: Codable, Equatable, Identifiable, Sendable {
    public let startDate: String
    public let tokens: Int64

    public var id: String { startDate }

    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate
        self.tokens = max(0, tokens)
    }

    public var formattedTokens: String {
        Self.formatTokens(tokens)
    }

    public static func formatTokens(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            let b = Double(count) / 1_000_000_000.0
            return String(format: "%.1f B", b)
        } else if count >= 1_000_000 {
            let m = Double(count) / 1_000_000.0
            return String(format: "%.1f M", m)
        } else if count >= 1_000 {
            let k = Double(count) / 1_000.0
            return String(format: "%.1f K", k)
        } else {
            return "\(count)"
        }
    }
}

public struct ActivityDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public let dateString: String
    public let tokens: Int64
    public let isFuture: Bool
    public let isToday: Bool

    public var id: String { dateString }

    public init(
        date: Date,
        dateString: String,
        tokens: Int64,
        isFuture: Bool = false,
        isToday: Bool = false
    ) {
        self.date = date
        self.dateString = dateString
        self.tokens = max(0, tokens)
        self.isFuture = isFuture
        self.isToday = isToday
    }

    public var formattedTokens: String {
        DailyUsageBucket.formatTokens(tokens)
    }
}

public struct ActivityWeek: Identifiable, Equatable, Sendable {
    public let id: Int
    public let days: [ActivityDay]

    public init(id: Int, days: [ActivityDay]) {
        self.id = id
        self.days = days
    }
}

public struct AccountTokenUsageSummary: Codable, Equatable, Sendable {
    public let lifetimeTokens: Int64?
    public let currentStreakDays: Int?
    public let longestStreakDays: Int?
    public let peakDailyTokens: Int64?
    public let longestRunningTurnSec: Int64?

    public init(
        lifetimeTokens: Int64? = nil,
        currentStreakDays: Int? = nil,
        longestStreakDays: Int? = nil,
        peakDailyTokens: Int64? = nil,
        longestRunningTurnSec: Int64? = nil
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSec = longestRunningTurnSec
    }

    public var formattedLifetimeTokens: String? {
        guard let lifetimeTokens else { return nil }
        return DailyUsageBucket.formatTokens(lifetimeTokens)
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let fiveHour: QuotaWindow?
    public let sevenDay: QuotaWindow?
    public let subscriptionPlan: SubscriptionPlan?
    public let availableResetCount: Int
    public let resetCredits: [ResetCredit]
    public let hasCurrentResetCreditData: Bool
    public let dailyUsageBuckets: [DailyUsageBucket]
    public let tokenUsageSummary: AccountTokenUsageSummary?
    public let hasCurrentTokenUsageData: Bool

    public init(
        fetchedAt: Date,
        fiveHour: QuotaWindow?,
        sevenDay: QuotaWindow?,
        subscriptionPlan: SubscriptionPlan? = nil,
        availableResetCount: Int,
        resetCredits: [ResetCredit],
        hasCurrentResetCreditData: Bool = true,
        dailyUsageBuckets: [DailyUsageBucket] = [],
        tokenUsageSummary: AccountTokenUsageSummary? = nil,
        hasCurrentTokenUsageData: Bool? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.subscriptionPlan = subscriptionPlan
        self.availableResetCount = max(0, availableResetCount)
        self.resetCredits = resetCredits
        self.hasCurrentResetCreditData = hasCurrentResetCreditData
        self.dailyUsageBuckets = dailyUsageBuckets
        self.tokenUsageSummary = tokenUsageSummary
        self.hasCurrentTokenUsageData = hasCurrentTokenUsageData ?? (!dailyUsageBuckets.isEmpty || tokenUsageSummary != nil)
    }

    private enum CodingKeys: String, CodingKey {
        case fetchedAt
        case fiveHour
        case sevenDay
        case subscriptionPlan
        case availableResetCount
        case resetCredits
        case hasCurrentResetCreditData
        case dailyUsageBuckets
        case tokenUsageSummary
        case hasCurrentTokenUsageData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        fiveHour = try container.decodeIfPresent(QuotaWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(QuotaWindow.self, forKey: .sevenDay)
        subscriptionPlan = try container.decodeIfPresent(
            SubscriptionPlan.self,
            forKey: .subscriptionPlan
        )
        availableResetCount = max(
            0,
            try container.decode(Int.self, forKey: .availableResetCount)
        )
        resetCredits = try container.decode([ResetCredit].self, forKey: .resetCredits)
        hasCurrentResetCreditData = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCurrentResetCreditData
        ) ?? true
        dailyUsageBuckets = try container.decodeIfPresent(
            [DailyUsageBucket].self,
            forKey: .dailyUsageBuckets
        ) ?? []
        tokenUsageSummary = try container.decodeIfPresent(
            AccountTokenUsageSummary.self,
            forKey: .tokenUsageSummary
        )
        hasCurrentTokenUsageData = try container.decodeIfPresent(Bool.self, forKey: .hasCurrentTokenUsageData)
            ?? (!dailyUsageBuckets.isEmpty || tokenUsageSummary != nil)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try container.encodeIfPresent(sevenDay, forKey: .sevenDay)
        try container.encodeIfPresent(subscriptionPlan, forKey: .subscriptionPlan)
        try container.encode(availableResetCount, forKey: .availableResetCount)
        try container.encode(resetCredits, forKey: .resetCredits)
        try container.encode(hasCurrentResetCreditData, forKey: .hasCurrentResetCreditData)
        try container.encode(dailyUsageBuckets, forKey: .dailyUsageBuckets)
        try container.encodeIfPresent(tokenUsageSummary, forKey: .tokenUsageSummary)
        try container.encode(hasCurrentTokenUsageData, forKey: .hasCurrentTokenUsageData)
    }

    public func preservingResetCredits(from previous: UsageSnapshot?) -> UsageSnapshot {
        guard let previous else { return self }

        let resetCount = hasCurrentResetCreditData ? availableResetCount : previous.availableResetCount
        let credits = hasCurrentResetCreditData ? resetCredits : previous.resetCredits
        let hasResetData = hasCurrentResetCreditData

        let buckets = hasCurrentTokenUsageData ? dailyUsageBuckets : previous.dailyUsageBuckets
        let summary = hasCurrentTokenUsageData ? tokenUsageSummary : previous.tokenUsageSummary

        return UsageSnapshot(
            fetchedAt: fetchedAt,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            subscriptionPlan: subscriptionPlan,
            availableResetCount: resetCount,
            resetCredits: credits,
            hasCurrentResetCreditData: hasResetData,
            dailyUsageBuckets: buckets,
            tokenUsageSummary: summary,
            hasCurrentTokenUsageData: hasCurrentTokenUsageData
        )
    }

    public var orderedQuotas: [QuotaWindow] {
        [fiveHour, sevenDay].compactMap { $0 }
    }

    public var menuBarTitle: String {
        menuBarTitle(for: .both)
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
        return parts.isEmpty ? "Codex --" : parts.joined(separator: " · ")
    }

    public var todayBucket: DailyUsageBucket? {
        bucket(for: Date())
    }

    public func bucket(for date: Date, calendar: Calendar = .current) -> DailyUsageBucket? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        let localDateStr = formatter.string(from: date)
        return dailyUsageBuckets.first(where: { $0.startDate == localDateStr })
    }

    public func sevenDayBuckets(endingOn date: Date = Date(), calendar: Calendar = .current) -> [DailyUsageBucket] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone

        let bucketMap = Dictionary(
            dailyUsageBuckets.map { ($0.startDate, $0.tokens) },
            uniquingKeysWith: { _, new in new }
        )

        var result: [DailyUsageBucket] = []
        for dayOffset in (0..<7).reversed() {
            guard let targetDate = calendar.date(byAdding: .day, value: -dayOffset, to: date) else { continue }
            let dateStr = formatter.string(from: targetDate)
            let tokens = bucketMap[dateStr] ?? 0
            result.append(DailyUsageBucket(startDate: dateStr, tokens: tokens))
        }
        return result
    }

    public func activityWeeks(count: Int = 18, endingOn date: Date = Date(), calendar: Calendar = .current) -> [ActivityWeek] {
        guard count > 0 else { return [] }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        cal.firstWeekday = 2 // Monday

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone

        let bucketMap = Dictionary(
            dailyUsageBuckets.map { ($0.startDate, $0.tokens) },
            uniquingKeysWith: { _, new in new }
        )

        let todayDateStr = formatter.string(from: date)
        guard let startOfCurrentWeek = cal.dateInterval(of: .weekOfYear, for: date)?.start,
              let startMonday = cal.date(byAdding: .weekOfYear, value: -(count - 1), to: startOfCurrentWeek) else {
            return []
        }

        var weeks: [ActivityWeek] = []
        weeks.reserveCapacity(count)

        for weekIndex in 0..<count {
            guard let weekStart = cal.date(byAdding: .weekOfYear, value: weekIndex, to: startMonday) else {
                continue
            }
            var days: [ActivityDay] = []
            days.reserveCapacity(7)
            for dayOffset in 0..<7 {
                guard let dayDate = cal.date(byAdding: .day, value: dayOffset, to: weekStart) else {
                    continue
                }
                let dayStr = formatter.string(from: dayDate)
                let isToday = (dayStr == todayDateStr)
                let isFuture = (dayStr > todayDateStr)
                let tokens = isFuture ? 0 : (bucketMap[dayStr] ?? 0)
                days.append(
                    ActivityDay(
                        date: dayDate,
                        dateString: dayStr,
                        tokens: tokens,
                        isFuture: isFuture,
                        isToday: isToday
                    )
                )
            }
            weeks.append(ActivityWeek(id: weekIndex, days: days))
        }
        return weeks
    }
}

public extension UsageSnapshot {
    static let preview: UsageSnapshot = {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            return components.date!
        }

        return UsageSnapshot(
            fetchedAt: date(2026, 7, 15, 20, 33),
            fiveHour: QuotaWindow(
                kind: .fiveHour,
                remainingPercent: 82,
                resetsAt: date(2026, 7, 15, 21, 40)
            ),
            sevenDay: QuotaWindow(
                kind: .sevenDay,
                remainingPercent: 93,
                resetsAt: date(2026, 7, 22, 9, 2)
            ),
            subscriptionPlan: SubscriptionPlan(identifier: "prolite"),
            availableResetCount: 4,
            resetCredits: [
                ResetCredit(grantedAt: date(2026, 6, 18, 8, 31), expiresAt: date(2026, 7, 18, 8, 31), status: "available"),
                ResetCredit(grantedAt: date(2026, 6, 27, 8, 0), expiresAt: date(2026, 7, 27, 8, 0), status: "available"),
                ResetCredit(grantedAt: date(2026, 7, 2, 4, 17), expiresAt: date(2026, 8, 1, 4, 17), status: "available"),
                ResetCredit(grantedAt: date(2026, 7, 14, 2, 0), expiresAt: date(2026, 8, 13, 2, 0), status: "available")
            ],
            dailyUsageBuckets: [
                DailyUsageBucket(startDate: "2026-07-09", tokens: 1_301_020),
                DailyUsageBucket(startDate: "2026-07-10", tokens: 189_329_559),
                DailyUsageBucket(startDate: "2026-07-11", tokens: 246_583_404),
                DailyUsageBucket(startDate: "2026-07-12", tokens: 103_332_559),
                DailyUsageBucket(startDate: "2026-07-13", tokens: 249_162_911),
                DailyUsageBucket(startDate: "2026-07-14", tokens: 164_594_651),
                DailyUsageBucket(startDate: "2026-07-15", tokens: 75_991_070)
            ],
            tokenUsageSummary: AccountTokenUsageSummary(
                lifetimeTokens: 11_601_258_469,
                currentStreakDays: 76,
                longestStreakDays: 76,
                peakDailyTokens: 361_809_076,
                longestRunningTurnSec: 20_701
            )
        )
    }()
}
