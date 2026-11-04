import Foundation
import Testing

@testable import QuotAICore

struct WidgetUpgradeRecoveryTests {
    @Test("Deleted executables still require a kernel-validated own signature")
    func deletedExecutableIdentity() {
        let policy = WidgetRecoveryPolicy(
            executablePath: "/Applications/QuotAI.app/Contents/PlugIns/QuotAIWidget.appex/Contents/MacOS/QuotAIWidget",
            containerIdentifier: "com.willhsu.QuotAI", identifier: "com.willhsu.QuotAI.QuotaWidget",
            team: "ABCDEFGHIJ", userID: 501)
        for category: UInt32 in [2, 3, 4, 6] {
            #expect(
                policy.allowsKernelIdentity(
                    identifier: policy.identifier, team: policy.team, userID: 501,
                    flags: 0x2000_0001, category: category))
        }
        for category: UInt32 in [0, 1, 5, 7, 8, 9, 10, 99] {
            #expect(
                !policy.allowsKernelIdentity(
                    identifier: policy.identifier, team: policy.team, userID: 501,
                    flags: 0x2000_0001, category: category))
        }
        for flags: UInt32 in [0, 1, 0x2000_0000, 0x2000_0003] {
            #expect(
                !policy.allowsKernelIdentity(
                    identifier: policy.identifier, team: policy.team, userID: 501, flags: flags, category: 3))
        }
        #expect(
            !policy.allowsKernelIdentity(
                identifier: "com.other.Widget", team: policy.team, userID: 501, flags: 0x2000_0001, category: 3))
        #expect(
            !policy.allowsKernelIdentity(
                identifier: policy.identifier, team: "OTHERTEAM1", userID: 501, flags: 0x2000_0001, category: 3))
        #expect(
            !policy.allowsKernelIdentity(
                identifier: policy.identifier, team: policy.team, userID: 502, flags: 0x2000_0001, category: 3))
    }

    @Test("An old build or previous recovery receipt cannot confirm a new upgrade")
    func responsesAreBoundToBuildAndAttempt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let request = try WidgetSharedStore.beginRecovery(at: url, build: "61")
        try WidgetSharedStore.recordTimelineResponse(kind: WidgetSharedStore.kind, build: "60", at: url)
        #expect(WidgetSharedStore.respondingKinds(to: request, at: url).isEmpty)
        try WidgetSharedStore.recordTimelineResponse(kind: WidgetSharedStore.kind, build: "61", at: url)
        #expect(WidgetSharedStore.respondingKinds(to: request, at: url) == [WidgetSharedStore.kind])
        try WidgetSharedStore.recordTimelineResponse(kind: WidgetSharedStore.selectableKind, build: "61", at: url)
        #expect(WidgetSharedStore.respondingKinds(to: request, at: url) == Set(WidgetSharedStore.kinds))
        let next = try WidgetSharedStore.beginRecovery(at: url, build: "61")
        #expect(WidgetSharedStore.respondingKinds(to: next, at: url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
        }
    }

    @Test("Registration or a missing configuration callback alone is not recovery")
    func everyConfiguredKindMustRespond() {
        let both = Set(WidgetSharedStore.kinds)
        let legacy: Set = [WidgetSharedStore.kind]
        #expect(!WidgetRecoveryPolicy.responsesConfirmRecovery(before: both, after: both, responses: legacy))
        #expect(WidgetRecoveryPolicy.responsesConfirmRecovery(before: both, after: both, responses: both))
        #expect(!WidgetRecoveryPolicy.responsesConfirmRecovery(before: legacy, after: [], responses: []))
        #expect(!WidgetRecoveryPolicy.responsesConfirmRecovery(before: nil, after: nil, responses: both))
        #expect(!WidgetRecoveryPolicy.responsesConfirmRecovery(before: [], after: nil, responses: []))
        #expect(WidgetRecoveryPolicy.responsesConfirmRecovery(before: [], after: [], responses: []))
        #expect(!WidgetRecoveryPolicy.responsesConfirmRecovery(before: legacy, after: both, responses: legacy))
    }
}
