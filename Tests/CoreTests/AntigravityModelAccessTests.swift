import Foundation
import Testing
@testable import QuotAICore

private func status(_ models: String, tier: String? = "TEAMS_TIER_PRO", wrapper: String = "userStatus") -> Data {
    let plan = tier.map { #", "planStatus":{"planInfo":{"teamsTier":"\#($0)"}}"# } ?? ""
    let body = #"{"cascadeModelConfigData":{"clientModelConfigs":\#(models)}\#(plan)}"#
    let json = wrapper == "direct" ? body : wrapper == "response"
        ? #"{"response":{"userStatus":\#(body)}}"# : #"{"userStatus":\#(body)}"#
    return Data(json.utf8)
}

@Test("Account model configurations determine access, independent of quota and model version",
      arguments: ["claude-opus-5-5", "claude-sonnet-4-6", "gpt-oss-120b-medium"])
func thirdPartyModelAccess(model: String) {
    let data = status(#"[{"modelId":"\#(model)","allowedTiers":["TEAMS_TIER_PRO"],"quotaInfo":{"remainingFraction":0}}]"#)
    #expect(AntigravityModelAccessParser.thirdPartyAvailability(data: data) == .available)
}

@Test("Empty, Gemini-only, disabled and disallowed configurations explicitly deny third-party access",
      arguments: ["[]", #"[{"modelId":"gemini-3-8-flash"}]"#,
                  #"[{"modelId":"claude-opus-5-5","disabled":true}]"#,
                  #"[{"modelId":"claude-opus-5-5","allowedTiers":["TEAMS_TIER_PRO_ULTIMATE"]}]"#])
func thirdPartyUnavailable(models: String) {
    #expect(AntigravityModelAccessParser.thirdPartyAvailability(data: status(models)) == .unavailable)
}

@Test("Missing, malformed and unfamiliar schemas remain unknown rather than denying access")
func thirdPartyReadFailure() {
    for data: Data? in [nil, Data("invalid".utf8), Data(#"{"userStatus":{}}"#.utf8),
                       Data(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":null}}}"#.utf8),
                       status(#"[{"modelId":"future-family"}]"#),
                       status(#"[{"modelId":"claude","allowedTiers":[]}]"#),
                       status(#"[{"modelId":"claude","allowedTiers":["PRO"]}]"#, tier: nil),
                       status(#"[{"modelId":"claude","disabled":"false"}]"#)] {
        #expect(AntigravityModelAccessParser.thirdPartyAvailability(data: data) == .unknown)
    }
}

@Test("Wrapped and direct status responses and aliases are supported", arguments: ["direct", "response", "userStatus"])
func thirdPartyStatusEnvelopes(wrapper: String) {
    let data = status(#"[{"modelOrAlias":{"model":"MODEL_CLAUDE"},"label":"Claude Sonnet 5.5"}]"#, wrapper: wrapper)
    #expect(AntigravityModelAccessParser.thirdPartyAvailability(data: data) == .available)
}

@Test("A denied pool is hidden despite returned quota, and both selections fall back independently")
func deniedPoolAndSelectionFallback() throws {
    let base = AntigravityQuotaSnapshot.preview
    let denied = AntigravityQuotaSnapshot(fetchedAt: base.fetchedAt, groups: base.groups, thirdPartyAvailability: .unavailable)
    #expect(denied.panelGroups.map(\.id) == ["gemini"])
    #expect(denied.panelGroup(id: "3p")?.id == "gemini")
    #expect(denied.group(id: "3p")?.id == "gemini")
    let suite = "QuotAI.access-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let keys = [AntigravityQuotaGroup.menuBarGroupDefaultsKey, AntigravityQuotaGroup.panelGroupDefaultsKey]
    for key in keys { defaults.set("3p", forKey: key) }
    let unknown = AntigravityQuotaSnapshot(fetchedAt: base.fetchedAt, groups: base.groups)
    unknown.reconcileUnavailableSelections(in: defaults)
    #expect(keys.allSatisfy { defaults.string(forKey: $0) == "3p" })
    #expect(unknown.group(id: "3p")?.orderedQuotas.isEmpty == true)
    #expect(unknown.panelGroups.count == 2)
    denied.reconcileUnavailableSelections(in: defaults)
    #expect(keys.allSatisfy { defaults.string(forKey: $0) == "gemini" })
    #expect(base.panelGroups.count == 2) // Access restoration brings the tab back.
}

@Test("Model access failures suppress third-party menu numbers without a permission fallback")
func unknownAccessMenuBar() {
    let base = AntigravityQuotaSnapshot.preview
    let unknown = AntigravityQuotaSnapshot(fetchedAt: base.fetchedAt, groups: base.groups)
    let menu = MenuBarPresentation(provider: .antigravity, antigravityEnabled: true, antigravityAvailable: true,
        selectedGroupID: "3p", mode: .both, codexSnapshot: .preview, antigravitySnapshot: unknown, isStayAwakeActive: false)
    #expect(menu.groupID == "3p")
    #expect(menu.lines == ["--"])
    #expect(menu.detail.contains(unknown.thirdPartyStatusMessage!))
    #expect(!menu.detail.contains("44%"))
    #expect(unknown.group(id: "gemini")?.fiveHour?.remainingPercent == 76)
}

@Test("A missing third-party quota is a read failure even when model access is granted")
func availableModelsWithoutQuota() {
    let base = AntigravityQuotaSnapshot.preview
    let missing = AntigravityQuotaSnapshot(fetchedAt: base.fetchedAt, groups: [base.groups[0]], thirdPartyAvailability: .available)
    #expect(missing.panelGroups.map(\.id) == ["gemini", "3p"])
    #expect(missing.group(id: "3p")?.orderedQuotas.isEmpty == true)
}

@Test("Only a real zero fraction means exhausted; small positive fractions do not deny access")
func exhaustedQuotaDoesNotHideTab() throws {
    for fraction in [0.0, 0.001] {
        let quota = Data(#"{"groups":[{"displayName":"Claude","buckets":[{"bucketId":"3p-5h","window":"5h","remainingFraction":\#(fraction)}]}]}"#.utf8)
        let snapshot = try AntigravityQuotaParser.parse(data: quota, userStatusData: status(#"[{"modelId":"claude-opus-5-5"}]"#))
        #expect(snapshot.thirdPartyAvailability == .available)
        #expect(snapshot.panelGroups.map(\.id) == ["3p"])
        #expect(snapshot.panelGroup(id: "3p")?.fiveHour?.remainingPercent == 0)
        #expect(snapshot.panelGroup(id: "3p")?.isExhausted == (fraction == 0))
    }
}
