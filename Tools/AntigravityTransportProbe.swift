import Darwin
import Foundation

private let quota = Data(#"{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.42}]}]}"#.utf8)
private let status = Data(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[]}}}"#.utf8)

private actor RuntimeFixture {
    var discoveries = 0
    var calls = 0
    var failsCachedEndpoint = false
    func discover() -> [AntigravityQuotaClient.Runtime] {
        discoveries += 1
        return [.init(processID: getpid(), host: "127.0.0.1", port: 10000 + discoveries, scheme: "http", csrfToken: "synthetic")]
    }
    func failCached() { failsCachedEndpoint = true }
    func request(_ runtime: AntigravityQuotaClient.Runtime, path: String) throws -> Data {
        calls += 1
        if failsCachedEndpoint && runtime.port == 10001 { throw URLError(.cannotConnectToHost) }
        return path.hasSuffix("GetUserStatus") ? status : quota
    }
    func counts() -> (Int, Int) { (discoveries, calls) }
}

private actor DiscoveryCounter {
    var count = 0
    func discover(port: Int, scheme: String, host: String) -> [AntigravityQuotaClient.Runtime] {
        count += 1
        return [.init(processID: getpid(), host: host, port: port, scheme: scheme, csrfToken: "synthetic")]
    }
}

@main struct AntigravityTransportProbe {
    static func main() async throws {
        let fixture = RuntimeFixture()
        let client = AntigravityQuotaClient(discover: { await fixture.discover() }, rpc: { runtime, path, _ in try await fixture.request(runtime, path: path) })
        _ = try await client.fetch()
        _ = try await client.fetch()
        let cached = await fixture.counts()
        precondition(cached.0 == 1 && cached.1 == 4, "Successful refresh repeated process discovery")
        await fixture.failCached()
        _ = try await client.fetch()
        let recovered = await fixture.counts()
        precondition(recovered.0 == 2, "Failed cached endpoint was not rediscovered")
        let dead = AntigravityQuotaClient(discover: { await fixture.discover() }, isAlive: { _ in false }, rpc: { runtime, path, _ in try await fixture.request(runtime, path: path) })
        _ = try await dead.fetch(); _ = try await dead.fetch()
        let restarted = await fixture.counts()
        precondition(restarted.0 == 4, "Dead process reused a cached endpoint")
        print("PASS: memory cache reuse, stale endpoint recovery, dead process invalidation")

        let ports = CommandLine.arguments.dropFirst().compactMap(Int.init)
        guard ports.count == 7 else { fatalError("Expected HTTP, HTTPS, IPv6, redirect, oversized, status-failure and slow fixture ports") }
        for (index, port) in ports.enumerated() {
            print("Checking native transport case \(index)"); fflush(nil)
            let counter = DiscoveryCounter()
            let client = AntigravityQuotaClient(discover: { await counter.discover(port: port, scheme: index == 1 ? "https" : "http", host: index == 2 ? "[::1]" : "127.0.0.1") })
            if index == 3 || index == 4 {
                do { _ = try await client.fetch(); fatalError("Redirect or oversized body was accepted") }
                catch AntigravityQuotaClientError.quotaUnavailable where index == 3 { }
                catch AntigravityQuotaClientError.protocolChanged where index == 4 { }
            } else if index == 6 {
                let task = Task { try await client.fetch() }
                try await Task.sleep(for: .milliseconds(100))
                let start = ProcessInfo.processInfo.systemUptime
                task.cancel()
                do { _ = try await task.value; fatalError("Expected cancellation") } catch is CancellationError { }
                precondition(ProcessInfo.processInfo.systemUptime - start < 1, "Native request did not cancel promptly")
            } else {
                let first = try await client.fetch(), second = try await client.fetch()
                precondition(first.groups.first?.fiveHour?.remainingPercent == 42 && second.groups.first?.fiveHour?.remainingPercent == 42)
                precondition(first.thirdPartyAvailability == (index == 5 ? .unknown : .unavailable))
                let discoveries = await counter.count
                precondition(discoveries == 1)
            }
        }
        print("PASS: native HTTP, loopback self-signed HTTPS, IPv6, redirect rejection, 1 MiB limit, independent access failure, request cancellation")
    }
}
