import Foundation
import Testing
@testable import QuotAICore

@Test("Parses 5-hour and 7-day windows by duration, not field position")
func parsesBothQuotaWindows() throws {
    let payload = """
    {"id":1,"result":{"userAgent":"test"}}
    {"id":2,"result":{"rateLimits":{"planType":"free","primary":{"usedPercent":18,"windowDurationMins":300,"resetsAt":1784122800},"secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784682166}},"rateLimitsByLimitId":{"codex":{"planType":"plus","primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784682166},"secondary":{"usedPercent":18,"windowDurationMins":300,"resetsAt":1784122800}}},"rateLimitResetCredits":{"availableCount":4,"credits":[{"grantedAt":1781742705,"expiresAt":1784334705,"status":"available"}]}}}
    """

    let snapshot = try CodexRateLimitParser.parse(jsonLines: payload)

    #expect(snapshot.fiveHour?.remainingPercent == 82)
    #expect(snapshot.sevenDay?.remainingPercent == 93)
    #expect(snapshot.menuBarTitle == "5h 82% · 7d 93%")
    #expect(snapshot.menuBarTitle(for: .fiveHour) == "5h 82%")
    #expect(snapshot.menuBarTitle(for: .sevenDay) == "7d 93%")
    #expect(snapshot.menuBarTitle(for: .both) == "5h 82% · 7d 93%")
    #expect(snapshot.subscriptionPlan?.displayName == "Plus")
    #expect(snapshot.availableResetCount == 4)
    #expect(snapshot.resetCredits.count == 1)
    #expect(snapshot.hasCurrentResetCreditData)
}

@Test("Hides the 5-hour quota when Codex omits it")
func omitsMissingFiveHourWindow() throws {
    let payload = """
    {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784682166},"secondary":null},"rateLimitResetCredits":{"availableCount":4,"credits":null}}}
    """

    let snapshot = try CodexRateLimitParser.parse(jsonLines: payload)

    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.sevenDay?.remainingPercent == 93)
    #expect(snapshot.menuBarTitle == "7d 93%")
    #expect(snapshot.menuBarTitle(for: .fiveHour) == "5h --")
    #expect(snapshot.menuBarTitle(for: .sevenDay) == "7d 93%")
    #expect(snapshot.menuBarTitle(for: .both) == "7d 93%")
    #expect(snapshot.availableResetCount == 4)
    #expect(snapshot.resetCredits.isEmpty)
    #expect(snapshot.hasCurrentResetCreditData)
}

@Test("Uses available reset detail rows when the summary count lags")
func derivesResetCountFromAvailableRows() throws {
    let payload = """
    {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784682166},"secondary":null},"rateLimitResetCredits":{"availableCount":0,"credits":[{"grantedAt":1781742705,"expiresAt":1784334705,"status":"available"},{"grantedAt":1781742706,"expiresAt":1784334706,"status":"available"},{"grantedAt":1781742707,"expiresAt":1784334707,"status":"redeemed"}]}}}
    """

    let snapshot = try CodexRateLimitParser.parse(jsonLines: payload)

    #expect(snapshot.availableResetCount == 2)
    #expect(snapshot.resetCredits.count == 2)
}

@Test("Distinguishes unavailable reset details from a confirmed zero count")
func distinguishesUnavailableResetDetails() throws {
    let unavailablePayload = """
    {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784682166}},"rateLimitResetCredits":null}}
    """
    let zeroPayload = """
    {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784682166}},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}
    """

    let unavailable = try CodexRateLimitParser.parse(jsonLines: unavailablePayload)
    let zero = try CodexRateLimitParser.parse(jsonLines: zeroPayload)

    #expect(!unavailable.hasCurrentResetCreditData)
    #expect(zero.hasCurrentResetCreditData)
    #expect(zero.availableResetCount == 0)
}

@Test("Preserves the last valid reset details when the backend temporarily omits them")
func preservesLastValidResetDetails() {
    let previous = UsageSnapshot.preview
    let unavailable = UsageSnapshot(
        fetchedAt: previous.fetchedAt.addingTimeInterval(300),
        fiveHour: nil,
        sevenDay: QuotaWindow(kind: .sevenDay, remainingPercent: 88, resetsAt: nil),
        subscriptionPlan: SubscriptionPlan(identifier: "prolite"),
        availableResetCount: 0,
        resetCredits: [],
        hasCurrentResetCreditData: false
    )

    let merged = unavailable.preservingResetCredits(from: previous)

    #expect(merged.fetchedAt == unavailable.fetchedAt)
    #expect(merged.sevenDay?.remainingPercent == 88)
    #expect(merged.availableResetCount == previous.availableResetCount)
    #expect(merged.resetCredits == previous.resetCredits)
    #expect(!merged.hasCurrentResetCreditData)
}

@Test("Does not preserve stale resets when the backend confirms zero")
func acceptsConfirmedZeroResetCount() {
    let current = UsageSnapshot(
        fetchedAt: UsageSnapshot.preview.fetchedAt.addingTimeInterval(300),
        fiveHour: nil,
        sevenDay: UsageSnapshot.preview.sevenDay,
        availableResetCount: 0,
        resetCredits: [],
        hasCurrentResetCreditData: true,
        dailyUsageBuckets: UsageSnapshot.preview.dailyUsageBuckets,
        tokenUsageSummary: UsageSnapshot.preview.tokenUsageSummary
    )

    let merged = current.preservingResetCredits(from: .preview)
    #expect(merged.availableResetCount == 0)
    #expect(merged.resetCredits.isEmpty)
    #expect(merged.hasCurrentResetCreditData)
    #expect(merged == current)
}

@Test("Preserves cached token usage when a new snapshot omits usage data")
func preservesCachedTokenUsageWhenNewSnapshotOmitsUsage() {
    let previous = UsageSnapshot.preview
    let newWithoutUsage = UsageSnapshot(
        fetchedAt: previous.fetchedAt.addingTimeInterval(300),
        fiveHour: previous.fiveHour,
        sevenDay: previous.sevenDay,
        subscriptionPlan: previous.subscriptionPlan,
        availableResetCount: 3,
        resetCredits: previous.resetCredits,
        hasCurrentResetCreditData: true,
        dailyUsageBuckets: [],
        tokenUsageSummary: nil
    )

    let merged = newWithoutUsage.preservingResetCredits(from: previous)

    #expect(merged.dailyUsageBuckets == previous.dailyUsageBuckets)
    #expect(merged.tokenUsageSummary == previous.tokenUsageSummary)
}

@Test("Updates token usage data when a new snapshot provides usage data")
func updatesTokenUsageWhenNewSnapshotProvidesUsage() {
    let previous = UsageSnapshot.preview
    let newBuckets = [DailyUsageBucket(startDate: "2026-09-07", tokens: 50_000)]
    let newSummary = AccountTokenUsageSummary(lifetimeTokens: 12_000_000_000, currentStreakDays: 78)
    let newWithUsage = UsageSnapshot(
        fetchedAt: previous.fetchedAt.addingTimeInterval(300),
        fiveHour: previous.fiveHour,
        sevenDay: previous.sevenDay,
        subscriptionPlan: previous.subscriptionPlan,
        availableResetCount: 3,
        resetCredits: previous.resetCredits,
        hasCurrentResetCreditData: true,
        dailyUsageBuckets: newBuckets,
        tokenUsageSummary: newSummary
    )

    let merged = newWithUsage.preservingResetCredits(from: previous)

    #expect(merged.dailyUsageBuckets == newBuckets)
    #expect(merged.tokenUsageSummary == newSummary)
}

@Test("Decodes caches written before reset freshness was added")
func decodesLegacySnapshotCache() throws {
    let encoded = try JSONEncoder().encode(UsageSnapshot.preview)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "hasCurrentResetCreditData")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: legacyData)

    #expect(decoded.hasCurrentResetCreditData)
    #expect(decoded.availableResetCount == UsageSnapshot.preview.availableResetCount)
}

@Test("Clamps malformed percentages into a display-safe range")
func clampsRemainingPercentage() throws {
    let payload = """
    {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":130,"windowDurationMins":300,"resetsAt":null},"secondary":null},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}
    """

    let snapshot = try CodexRateLimitParser.parse(jsonLines: payload)

    #expect(snapshot.fiveHour?.remainingPercent == 0)
}

@Test("Preserves JSON-RPC error codes and messages")
func preservesServerErrorDetails() throws {
    let payload = #"{"id":2,"error":{"code":-32601,"message":"Method not found"}}"#

    do {
        _ = try CodexRateLimitParser.parse(jsonLines: payload)
        Issue.record("Expected the parser to surface the server error")
    } catch let error as CodexRateLimitParserError {
        #expect(error == .serverError(code: -32_601, message: "Method not found"))
    }
}

@Test("Reads ChatGPT, API key, and signed-out account modes")
func readsAccountAuthModes() {
    let chatGPT = #"{"id":2,"result":{"account":{"type":"chatgpt","planType":"pro"}}}"#
    let apiKey = #"{"id":2,"result":{"account":{"type":"apiKey"}}}"#
    let signedOut = #"{"id":2,"result":{"account":null}}"#

    #expect(CodexAccountParser.authMode(jsonLines: chatGPT) == .chatGPT)
    #expect(CodexAccountParser.authMode(jsonLines: apiKey) == .apiKey)
    #expect(CodexAccountParser.authMode(jsonLines: signedOut) == .signedOut)
    #expect(CodexAccountParser.subscriptionPlanIdentifier(jsonLines: chatGPT) == "pro")
    #expect(CodexAccountParser.subscriptionPlanIdentifier(jsonLines: apiKey) == nil)
}

@Test("Falls back to the account plan when quota data omits it")
func readsPlanFromAccountFallback() throws {
    let payload = """
    {"id":2,"result":{"account":{"type":"chatgpt","planType":"business"}}}
    {"id":3,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784682166},"secondary":null},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}
    """

    let snapshot = try CodexRateLimitParser.parse(jsonLines: payload, requestID: 3)

    #expect(snapshot.subscriptionPlan?.displayName == "Business")
}

@Test("Normalizes known plan variants and hides unknown plan values")
func formatsSubscriptionPlans() {
    #expect(SubscriptionPlan(identifier: "pro")?.displayName == "Pro20x")
    #expect(SubscriptionPlan(identifier: "prolite")?.displayName == "Pro 5x")
    #expect(SubscriptionPlan(identifier: "self_serve_business_usage_based")?.displayName == "Business")
    #expect(SubscriptionPlan(identifier: "enterprise_cbp_usage_based")?.displayName == "Enterprise")
    #expect(SubscriptionPlan(identifier: "unknown") == nil)
}

@Test("Parses account token usage and daily buckets when present")
func parsesAccountTokenUsage() throws {
    let payload = """
    {"id":3,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":18,"windowDurationMins":300,"resetsAt":1784122800},"secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784682166}},"rateLimitResetCredits":{"availableCount":1,"credits":[]}}}
    {"id":4,"result":{"summary":{"currentStreakDays":76,"lifetimeTokens":11601258469,"longestRunningTurnSec":20701,"longestStreakDays":76,"peakDailyTokens":361809076},"dailyUsageBuckets":[{"startDate":"2026-09-04","tokens":154358560},{"startDate":"2026-09-05","tokens":60975604}]}}
    """

    let snapshot = try CodexRateLimitParser.parse(
        jsonLines: payload,
        requestID: 3,
        usageRequestID: 4
    )

    #expect(snapshot.dailyUsageBuckets.count == 2)
    #expect(snapshot.dailyUsageBuckets[0].startDate == "2026-09-04")
    #expect(snapshot.dailyUsageBuckets[0].tokens == 154_358_560)
    #expect(snapshot.dailyUsageBuckets[0].formattedTokens == "154.4 M")
    #expect(snapshot.dailyUsageBuckets[1].startDate == "2026-09-05")
    #expect(snapshot.dailyUsageBuckets[1].tokens == 60_975_604)
    #expect(snapshot.dailyUsageBuckets[1].formattedTokens == "61.0 M")

    #expect(snapshot.tokenUsageSummary?.lifetimeTokens == 11_601_258_469)
    #expect(snapshot.tokenUsageSummary?.formattedLifetimeTokens == "11.6 B")
    #expect(snapshot.tokenUsageSummary?.currentStreakDays == 76)
    #expect(snapshot.tokenUsageSummary?.peakDailyTokens == 361_809_076)
}

@Test("Explicit empty usage clears cached data; unsupported usage preserves it")
func emptyAndUnavailableUsageAreDistinct() throws {
    let quota = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":18,"windowDurationMins":300,"resetsAt":1784122800}}}}"#
    for (response, isCurrent) in [
        (#"{"id":4,"result":{"dailyUsageBuckets":[]}}"#, true),
        (#"{"id":4,"error":{"code":-32601,"message":"Method not found"}}"#, false),
        ("", false)
    ] {
        let parsed = try CodexRateLimitParser.parse(jsonLines: quota + "\n" + response, requestID: 3, usageRequestID: 4)
        #expect(parsed.hasCurrentTokenUsageData == isCurrent)
        let merged = parsed.preservingResetCredits(from: .preview)
        #expect(merged.dailyUsageBuckets == (isCurrent ? [] : UsageSnapshot.preview.dailyUsageBuckets))
        #expect(merged.tokenUsageSummary == (isCurrent ? nil : UsageSnapshot.preview.tokenUsageSummary))
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(merged))
        #expect(decoded == merged)
    }
}

@Test("Daily usage does not substitute the previous UTC date for a missing local day")
func dailyUsageDateBoundaries() throws {
    var calendar = Calendar(identifier: .buddhist)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let date = ISO8601DateFormatter().date(from: "2026-09-07T01:00:00+08:00")!
    let snapshot = UsageSnapshot(fetchedAt: date, fiveHour: nil, sevenDay: nil,
        availableResetCount: 0, resetCredits: [], dailyUsageBuckets: [
            DailyUsageBucket(startDate: "2026-09-06", tokens: 100)
        ])
    #expect(snapshot.bucket(for: date, calendar: calendar) == nil)
    let days = snapshot.activityWeeks(count: 1, endingOn: date, calendar: calendar).flatMap(\.days)
    #expect(days.first?.dateString == "2026-09-07")
}

@Test("Formats token counts with appropriate scale suffix")
func formatsTokenCounts() {
    #expect(DailyUsageBucket.formatTokens(0) == "0")
    #expect(DailyUsageBucket.formatTokens(850) == "850")
    #expect(DailyUsageBucket.formatTokens(1_500) == "1.5 K")
    #expect(DailyUsageBucket.formatTokens(60_975_604) == "61.0 M")
    #expect(DailyUsageBucket.formatTokens(11_601_258_469) == "11.6 B")
}

@Test("Generates 7-day buckets ending on the specified date with zero padding")
func generatesSevenDayBuckets() {
    let calendar = Calendar(identifier: .gregorian)
    var components = DateComponents()
    components.calendar = calendar
    components.year = 2026
    components.month = 9
    components.day = 6
    let date = components.date!

    let snapshot = UsageSnapshot(
        fetchedAt: date,
        fiveHour: nil,
        sevenDay: nil,
        availableResetCount: 0,
        resetCredits: [],
        dailyUsageBuckets: [
            DailyUsageBucket(startDate: "2026-09-04", tokens: 100),
            DailyUsageBucket(startDate: "2026-09-05", tokens: 200)
        ]
    )

    let sevenDays = snapshot.sevenDayBuckets(endingOn: date, calendar: calendar)
    #expect(sevenDays.count == 7)
    #expect(sevenDays.last?.startDate == "2026-09-06")
    #expect(sevenDays.last?.tokens == 0)
    #expect(sevenDays[5].startDate == "2026-09-05")
    #expect(sevenDays[5].tokens == 200)
    #expect(sevenDays[4].startDate == "2026-09-04")
    #expect(sevenDays[4].tokens == 100)
    #expect(sevenDays[0].startDate == "2026-08-31")
    #expect(sevenDays[0].tokens == 0)
}

@Test("Generates multi-week activity grid with correct weekday slicing and today/future flags")
func generatesActivityWeeks() {
    let calendar = Calendar(identifier: .gregorian)
    var components = DateComponents()
    components.calendar = calendar
    components.year = 2026
    components.month = 9
    components.day = 2 // Wednesday
    let date = components.date!

    let snapshot = UsageSnapshot(
        fetchedAt: date,
        fiveHour: nil,
        sevenDay: nil,
        availableResetCount: 0,
        resetCredits: [],
        dailyUsageBuckets: [
            DailyUsageBucket(startDate: "2026-08-31", tokens: 50),
            DailyUsageBucket(startDate: "2026-09-01", tokens: 100),
            DailyUsageBucket(startDate: "2026-09-02", tokens: 150)
        ]
    )

    let weeks = snapshot.activityWeeks(count: 18, endingOn: date, calendar: calendar)
    #expect(weeks.count == 18)

    // Verify first week
    let firstWeek = weeks[0]
    #expect(firstWeek.days.count == 7)

    // Verify last week (ending around 2026-09-02)
    let lastWeek = weeks[17]
    #expect(lastWeek.days.count == 7)

    // Mon 2026-08-31
    #expect(lastWeek.days[0].dateString == "2026-08-31")
    #expect(lastWeek.days[0].tokens == 50)
    #expect(!lastWeek.days[0].isToday)
    #expect(!lastWeek.days[0].isFuture)

    // Tue 2026-09-01
    #expect(lastWeek.days[1].dateString == "2026-09-01")
    #expect(lastWeek.days[1].tokens == 100)
    #expect(!lastWeek.days[1].isToday)
    #expect(!lastWeek.days[1].isFuture)

    // Wed 2026-09-02 (Today)
    #expect(lastWeek.days[2].dateString == "2026-09-02")
    #expect(lastWeek.days[2].tokens == 150)
    #expect(lastWeek.days[2].isToday)
    #expect(!lastWeek.days[2].isFuture)

    // Thu 2026-09-03 (Future)
    #expect(lastWeek.days[3].dateString == "2026-09-03")
    #expect(lastWeek.days[3].tokens == 0)
    #expect(!lastWeek.days[3].isToday)
    #expect(lastWeek.days[3].isFuture)

    // Sun 2026-09-06 (Future)
    #expect(lastWeek.days[6].dateString == "2026-09-06")
    #expect(!lastWeek.days[6].isToday)
    #expect(lastWeek.days[6].isFuture)
}
