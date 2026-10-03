import Darwin
import Foundation
import Testing
@testable import QuotAICore

@Suite struct ClaudeCodeSubscriptionTests {
    private func status(_ changes: [String: Any] = [:]) throws -> Data {
        var fields: [String: Any] = ["loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "pro",
            "email": "fixture@example.invalid", "orgId": "fixture-private-id"]
        fields.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: fields)
    }

    @Test func claudePlansKeepTheirProviderMeaning() throws {
        let reportedPro = try ClaudeCodeSubscriptionParser.parse(status())
        let pro = try #require(reportedPro)
        #expect(pro.displayName == "Pro")
        #expect(pro.displayName != SubscriptionPlan(identifier: "pro")?.displayName)
        let reportedMax = try ClaudeCodeSubscriptionParser.parse(status(["subscriptionType": "max"]))
        let max = try #require(reportedMax)
        #expect(max.displayName == "Max") // auth status does not report a 5x/20x tier.
        #expect(try ClaudeCodeSubscriptionParser.parse(status(["subscriptionType": " enterprise "])) == .enterprise)
        #expect(try ClaudeCodeSubscriptionParser.parse(status(["subscriptionType": "team"])) == .team)
    }

    @Test func absentAndNonSubscriptionLoginsClearThePlan() throws {
        let statuses: [[String: Any]] = [
            ["loggedIn": false], ["subscriptionType": NSNull()], ["subscriptionType": "unknown"],
            ["subscriptionType": "new-unverified-plan"], ["authMethod": "api_key"],
            ["authMethod": "oauth_token"], ["authMethod": "third_party"], ["apiProvider": "bedrock"],
            ["apiProvider": NSNull()]
        ]
        for changes in statuses {
            #expect(try ClaudeCodeSubscriptionParser.parse(status(changes)) == nil)
        }
        #expect(try ClaudeCodeSubscriptionParser.parse(Data(#"{"loggedIn":false}"#.utf8)) == nil)
    }

    @Test func invalidAuthOutputIsNotAPlan() throws {
        for value in ["not JSON", #"{"subscriptionType":"pro"}"#, #"{"loggedIn":"true","subscriptionType":"pro"}"#] {
            #expect(throws: ClaudeUsageQueryError.invalidOutput) {
                try ClaudeCodeSubscriptionParser.parse(Data(value.utf8))
            }
        }
        #expect(throws: ClaudeUsageQueryError.oversizedOutput) {
            try ClaudeCodeSubscriptionParser.parse(Data(repeating: 65, count: ClaudeCodeSubscriptionParser.outputLimit + 1))
        }
    }

    @Test func cachePersistsOnlyThePlanAndRejectsSymlinks() throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        let directory = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(UUID().uuidString)
        free(resolved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plan.json")
        try ClaudeCodeSubscriptionCache.write(ClaudeCodeSubscriptionParser.parse(status()), to: url)
        #expect(try ClaudeCodeSubscriptionCache.read(from: url) == .pro)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "plan"])
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { try ClaudeCodeSubscriptionCache.write(.max, to: link) }
        #expect(throws: (any Error).self) { try ClaudeCodeSubscriptionCache.clear(at: link) }
        #expect(try ClaudeCodeSubscriptionCache.read(from: url) == .pro)
        try ClaudeCodeSubscriptionCache.write(.max, to: url)
        #expect(try ClaudeCodeSubscriptionCache.read(from: url) == .max)
        try ClaudeCodeSubscriptionCache.write(nil, to: url)
        #expect(try ClaudeCodeSubscriptionCache.read(from: url) == nil)
    }
}
