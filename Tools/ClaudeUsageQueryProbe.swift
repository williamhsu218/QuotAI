import Darwin
import Foundation

actor QueryCounter {
    var count = 0
    func fetch(_ snapshot: ClaudeCodeQuotaSnapshot) async -> ClaudeCodeQuotaSnapshot {
        count += 1
        try? await Task.sleep(for: .milliseconds(300)) // Deliberately ignores cancellation to test the store's generation gate.
        return snapshot
    }
}

actor SubscriptionCounter {
    var count = 0
    var plan: ClaudeCodeSubscriptionPlan? = .pro
    var shouldFail = false
    func setPlan(_ value: ClaudeCodeSubscriptionPlan?) { plan = value }
    func setFailure(_ value: Bool) { shouldFail = value }
    func fetch() async throws -> ClaudeCodeSubscriptionPlan? {
        count += 1
        let value = plan, failure = shouldFail
        try? await Task.sleep(for: .milliseconds(300)) // Also test rejection of late auth results.
        if failure { throw ClaudeUsageQueryError.timeout }
        return value
    }
}

@main struct ClaudeUsageQueryProbe {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/query-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if CommandLine.arguments.contains("--live") {
            let value = try await ClaudeUsageQueryClient.fetch()
            print("LIVE /usage parsed: " + value.menuBarLines(for: .both).joined(separator: " · "))
            print("LIVE subscription: " + (try await ClaudeUsageQueryClient.fetchSubscription()?.displayName ?? "unavailable"))
            print("No raw result, account data or session ID persisted.")
            return
        }
        if CommandLine.arguments.contains("--live-subscription") {
            print("LIVE subscription: " + (try await ClaudeUsageQueryClient.fetchSubscription()?.displayName ?? "unavailable"))
            return
        }
        let now = Date()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "MMM d 'at' h:mma"; formatter.amSymbol = "am"; formatter.pmSymbol = "pm"
        let text = "Current session: 15% used · resets \(formatter.string(from: now.addingTimeInterval(3_600))) (Asia/Shanghai)\nCurrent week (all models): 9% used · resets \(formatter.string(from: now.addingTimeInterval(86_400))) (Asia/Shanghai)"
        let data = try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false, "num_turns": 0, "total_cost_usd": 0, "modelUsage": [String: Any](), "result": text])
        let snapshot = try ClaudeUsageQueryParser.parse(data, at: now)
        func fixture(_ name: String, body: String) throws -> URL {
            let file = directory.appendingPathComponent(name)
            try ("#!/usr/bin/python3\nimport sys, time, base64\n" + body).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file
        }
        let valid = try fixture("valid", body: "assert sys.argv[1:3] == ['-p', '/usage']\nassert '--no-session-persistence' in sys.argv and '--strict-mcp-config' in sys.argv\nsys.stdout.buffer.write(base64.b64decode('\(data.base64EncodedString())'))\n")
        let actual = try await ClaudeUsageQueryClient.fetch(executable: valid)
        precondition(actual.fiveHour?.quota.remainingPercent == 85 && actual.sevenDay?.quota.remainingPercent == 91)
        let auth = try fixture("auth", body: "assert sys.argv[1:] == ['auth', 'status', '--json']\nprint('{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"pro\"}')\n")
        let actualPlan = try await ClaudeUsageQueryClient.fetchSubscription(executable: auth)
        precondition(actualPlan == .pro)
        let loggedOut = try fixture("logged-out", body: "print('{\"loggedIn\":false}')\nsys.exit(1)\n")
        let absentPlan = try await ClaudeUsageQueryClient.fetchSubscription(executable: loggedOut)
        precondition(absentPlan == nil)
        var inactiveEnvelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        inactiveEnvelope["result"] = "Current session: 0% used\nCurrent week (all models): 0% used"
        let inactiveData = try JSONSerialization.data(withJSONObject: inactiveEnvelope)
        let inactiveCLI = try fixture("inactive", body: "sys.stdout.buffer.write(base64.b64decode('\(inactiveData.base64EncodedString())'))\n")
        let inactive = try await ClaudeUsageQueryClient.fetch(executable: inactiveCLI)
        precondition(inactive.orderedReports.isEmpty && inactive.menuBarLines(for: .both) == ["--"])
        let pidFile = directory.appendingPathComponent("child-pid")
        let slow = try fixture("slow", body: "import os\nopen('\(pidFile.path)', 'w').write(str(os.getpid()))\ntime.sleep(10)\n")
        do { _ = try await ClaudeUsageQueryClient.fetch(executable: slow, timeout: 0.5); fatalError("Expected timeout") }
        catch ClaudeUsageQueryError.timeout { }
        let oversized = try fixture("oversized", body: "sys.stdout.buffer.write(b'A' * 2000000)\n")
        do { _ = try await ClaudeUsageQueryClient.fetch(executable: oversized); fatalError("Expected output bound") }
        catch ClaudeUsageQueryError.oversizedOutput { }
        try FileManager.default.removeItem(at: pidFile)
        let cancelled = Task { try await ClaudeUsageQueryClient.fetch(executable: slow) }
        let launchDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !FileManager.default.fileExists(atPath: pidFile.path) && ProcessInfo.processInfo.systemUptime < launchDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let childPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        cancelled.cancel()
        precondition(kill(childPID, 0) == -1 && errno == ESRCH, "Cancellation must stop the child synchronously, including on app exit")
        do { _ = try await cancelled.value; fatalError("Expected cancellation") } catch is CancellationError { }
        let suite = "QuotAIUsageProbe-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ClaudeCodeUsageStore.enabledDefaultsKey)
        let inactiveCache = directory.appendingPathComponent("inactive-cache.json")
        try ClaudeUsageQueryCache.write(snapshot, to: inactiveCache)
        let inactiveStore = ClaudeCodeUsageStore(defaults: defaults, cacheURL: inactiveCache, migrateBridge: false,
            subscriptionCacheURL: directory.appendingPathComponent("inactive-plan.json"), subscriptionQuery: { nil },
            query: { try await ClaudeUsageQueryClient.fetch(executable: inactiveCLI) })
        inactiveStore.start()
        precondition(inactiveStore.snapshot?.fiveHour != nil && inactiveStore.isCached)
        await inactiveStore.userRefresh()
        precondition(inactiveStore.phase == .ready && inactiveStore.snapshot?.orderedReports.isEmpty == true && !inactiveStore.isCached)
        let persistedInactive = try ClaudeUsageQueryCache.read(from: inactiveCache)
        precondition(persistedInactive?.orderedReports.isEmpty == true)
        inactiveStore.stop(); inactiveStore.start()
        precondition(inactiveStore.snapshot?.orderedReports.isEmpty == true && inactiveStore.isCached)
        inactiveStore.stop()
        let counter = QueryCounter(), cache = directory.appendingPathComponent("cache.json")
        let plans = SubscriptionCounter(), planCache = directory.appendingPathComponent("plan.json")
        let store = ClaudeCodeUsageStore(defaults: defaults, cacheURL: cache, migrateBridge: false,
            subscriptionCacheURL: planCache, subscriptionQuery: { try await plans.fetch() }, query: { await counter.fetch(snapshot) })
        store.start()
        try await Task.sleep(for: .milliseconds(400))
        let startupCount = await counter.count
        precondition(startupCount == 0 && store.snapshot == nil)
        let startupPlans = await plans.count
        precondition(startupPlans == 1 && store.subscriptionPlan == .pro && !store.isSubscriptionCached)
        let cachedPro = try ClaudeCodeSubscriptionCache.read(from: planCache)
        precondition(cachedPro == .pro)
        await plans.setPlan(.max)
        store.stop(); store.start()
        precondition(store.subscriptionPlan == .pro && store.isSubscriptionCached)
        let first = Task { await store.userRefresh() }
        try await Task.sleep(for: .milliseconds(20))
        await store.userRefresh()
        await first.value
        let refreshCount = await counter.count
        precondition(refreshCount == 1 && store.snapshot?.fiveHour?.quota.remainingPercent == 85)
        precondition(store.subscriptionPlan == .max)
        let cachedMax = try ClaudeCodeSubscriptionCache.read(from: planCache)
        precondition(cachedMax == .max)
        await plans.setFailure(true)
        store.stop(); store.start()
        await store.userRefresh()
        precondition(store.subscriptionPlan == .max && store.isSubscriptionCached && store.phase == .ready)
        await plans.setFailure(false)
        await plans.setPlan(nil)
        await store.userRefresh()
        precondition(store.subscriptionPlan == nil && !FileManager.default.fileExists(atPath: planCache.path))
        await plans.setPlan(.pro)
        let late = Task { await store.userRefresh() }
        try await Task.sleep(for: .milliseconds(20)); try store.clearReports()
        await late.value
        precondition(store.snapshot == nil && store.subscriptionPlan == nil && !FileManager.default.fileExists(atPath: cache.path)
            && !FileManager.default.fileExists(atPath: planCache.path))
        let disabling = Task { await store.userRefresh() }
        try await Task.sleep(for: .milliseconds(20)); try store.disable()
        await disabling.value
        precondition(store.snapshot == nil && store.subscriptionPlan == nil && !store.isEnabled && !FileManager.default.fileExists(atPath: cache.path))
        try ClaudeUsageQueryCache.write(snapshot, to: cache)
        precondition(store.hasQueryCache)
        try store.clearReports()
        precondition(!store.hasQueryCache)
        let firstConnectPlanCache = directory.appendingPathComponent("first-connect-plan.json")
        let firstConnect = ClaudeCodeUsageStore(defaults: defaults,
            cacheURL: directory.appendingPathComponent("first-connect-usage.json"), migrateBridge: false,
            subscriptionCacheURL: firstConnectPlanCache, subscriptionQuery: { .pro },
            query: { throw ClaudeUsageQueryError.noQuota })
        firstConnect.start()
        precondition(!firstConnect.isEnabled && firstConnect.subscriptionPlan == nil)
        try firstConnect.enable()
        await firstConnect.userRefresh()
        precondition(firstConnect.subscriptionPlan == .pro && !firstConnect.isSubscriptionCached && firstConnect.snapshot == nil)
        guard case .failed = firstConnect.phase else { fatalError("Expected independent usage failure") }
        let persistedFirstPlan = try ClaudeCodeSubscriptionCache.read(from: firstConnectPlanCache)
        precondition(persistedFirstPlan == .pro && firstConnect.hasQueryCache)
        try firstConnect.clearReports()
        precondition(!firstConnect.hasQueryCache && firstConnect.subscriptionPlan == nil)
        firstConnect.stop()
        print("PASS: actual child stdout, auth status and logged-out exit 1, first connect without usage query, cached restart/failure, plan changes/logout, plan survives usage failure, inactive windows, timeout, size limit, child cancellation, coalesced refresh, late usage/auth rejection after clear/disable")
    }
}
