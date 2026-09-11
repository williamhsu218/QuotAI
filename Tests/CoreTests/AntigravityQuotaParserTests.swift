import Foundation
import Testing
@testable import QuotAICore

@Test("Parses Antigravity groups without merging them into Codex usage")
func parsesAntigravityQuotaGroups() throws {
    let json = #"""
    {
      "response": {
        "description": "Quota summary",
        "groups": [
          {
            "displayName": "Gemini Models",
            "description": "Gemini group",
            "buckets": [
              {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.61,"resetTime":"2026-08-25T01:00:00Z"},
              {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.82,"resetTime":"2026-08-20T13:05:00Z"}
            ]
          },
          {
            "displayName": "Claude and GPT models",
            "buckets": [
              {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.28,"resetTime":"2026-08-24T09:30:00Z"},
              {"bucketId":"3p-5h","window":"5h","remainingFraction":0.44,"resetTime":"2026-08-20T14:18:00Z"}
            ]
          }
        ]
      }
    }
    """#

    let fetchedAt = Date(timeIntervalSince1970: 1_787_190_000)
    let snapshot = try AntigravityQuotaParser.parse(
        data: try #require(json.data(using: .utf8)),
        fetchedAt: fetchedAt
    )

    #expect(snapshot.fetchedAt == fetchedAt)
    #expect(snapshot.groups.map(\.id) == ["gemini", "3p"])
    #expect(snapshot.groups[0].fiveHour?.remainingPercent == 82)
    #expect(snapshot.groups[0].sevenDay?.remainingPercent == 61)
    #expect(snapshot.groups[1].fiveHour?.remainingPercent == 44)
    #expect(snapshot.groups[1].sevenDay?.remainingPercent == 28)
    #expect(snapshot.groups[0].orderedQuotas.map(\.kind) == [.fiveHour, .sevenDay])
}

@Test("Uses the existing 5h and 7d menu bar display mode for Antigravity")
func formatsAntigravityMenuBarTitle() {
    let geminiGroup = AntigravityQuotaSnapshot.preview.groups[0]
    #expect(geminiGroup.menuBarTitle(for: .fiveHour) == "✦ 5h 76%")
    #expect(geminiGroup.menuBarTitle(for: .sevenDay) == "✦ 7d 61%")
    #expect(geminiGroup.menuBarTitle(for: .both) == "✦ 5h 76% · 7d 61%")
    #expect(geminiGroup.menuBarLines(for: .both) == ["5h 76%", "7d 61%"])
    #expect(geminiGroup.menuBarLines(for: .fiveHour) == ["5h 76%"])
    #expect(geminiGroup.menuBarLines(for: .sevenDay) == ["7d 61%"])

    let thirdPartyGroup = AntigravityQuotaSnapshot.preview.groups[1]
    #expect(thirdPartyGroup.menuBarTitle(for: .fiveHour) == "✳ 5h 44%")
    #expect(thirdPartyGroup.menuBarTitle(for: .sevenDay) == "✳ 7d 28%")
    #expect(thirdPartyGroup.menuBarTitle(for: .both) == "✳ 5h 44% · 7d 28%")
    #expect(thirdPartyGroup.menuBarLines(for: .both) == ["5h 44%", "7d 28%"])
}

@Test("Hides the 5-hour quota when Antigravity group omits it")
func antigravityOmitsMissingFiveHourWindow() {
    let group = AntigravityQuotaGroup(
        id: "gemini",
        displayName: "Gemini",
        fiveHour: nil,
        sevenDay: QuotaWindow(kind: .sevenDay, remainingPercent: 88, resetsAt: Date())
    )
    #expect(group.menuBarLines(for: .both) == ["7d 88%"])
    #expect(group.menuBarLines(for: .fiveHour) == ["5h --"])
    #expect(group.menuBarLines(for: .sevenDay) == ["7d 88%"])
    #expect(group.menuBarTitle(for: .both) == "✦ 7d 88%")
}

@Test("Antigravity quota tabs preserve separate pools and fall back for a missing selection")
func antigravityQuotaTabSelection() {
    let snapshot = AntigravityQuotaSnapshot.preview
    #expect(snapshot.panelGroup(id: "gemini")?.fiveHour?.remainingPercent == 76)
    #expect(snapshot.panelGroup(id: "3p")?.fiveHour?.remainingPercent == 44)
    #expect(snapshot.panelGroup(id: "3p")?.sevenDay?.remainingPercent == 28)
    #expect(snapshot.panelGroup(id: "removed")?.id == "gemini")
    #expect(snapshot.panelGroup(id: nil)?.id == "gemini")
    #expect(snapshot.panelGroup(id: "")?.id == "gemini")
    let single = AntigravityQuotaSnapshot(fetchedAt: snapshot.fetchedAt, groups: [snapshot.groups[1]])
    #expect(single.panelGroup(id: "gemini")?.id == "3p")
    let empty = AntigravityQuotaSnapshot(fetchedAt: snapshot.fetchedAt, groups: [])
    #expect(empty.panelGroup(id: "gemini") == nil)
}

@Test("Antigravity tabs use compact labels and a preference separate from the menu bar")
func antigravityQuotaTabPreferences() throws {
    let suite = "QuotAI.tab-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("gemini", forKey: AntigravityQuotaGroup.menuBarGroupDefaultsKey)
    defaults.set("3p", forKey: AntigravityQuotaGroup.panelGroupDefaultsKey)
    #expect(defaults.string(forKey: AntigravityQuotaGroup.menuBarGroupDefaultsKey) == "gemini")
    #expect(defaults.string(forKey: AntigravityQuotaGroup.panelGroupDefaultsKey) == "3p")
    #expect(AntigravityQuotaTab.allCases.map(\.title) == ["Gemini", "Claude / GPT"])
    #expect(AntigravityQuotaTab.allCases.map(\.rawValue) == ["gemini", "3p"])
}

@Test("The two quota tabs never substitute an unknown pool for a known model family")
func antigravityQuotaTabRejectsUnknownPool() {
    let future = AntigravityQuotaGroup(id: "future", displayName: "Future models",
                                       fiveHour: .init(kind: .fiveHour, remainingPercent: 99, resetsAt: nil), sevenDay: nil)
    let known = AntigravityQuotaSnapshot.preview
    let reordered = AntigravityQuotaSnapshot(fetchedAt: known.fetchedAt,
                                            groups: [future, known.groups[1], known.groups[0]])
    #expect(reordered.panelGroup(id: "future")?.id == "gemini")
    #expect(reordered.panelGroup(id: "3p")?.fiveHour?.remainingPercent == 44)
    let unknownOnly = AntigravityQuotaSnapshot(fetchedAt: known.fetchedAt, groups: [future])
    #expect(unknownOnly.panelGroup(id: "gemini") == nil)
    #expect(unknownOnly.group(id: "future")?.id == "future") // Menu bar behavior stays intact.
}

@Test("Accepts a direct quota response and clamps out-of-range fractions")
func parsesDirectAntigravityQuotaResponse() throws {
    let json = #"""
    {
      "groups": [
        {
          "displayName": "Future Group",
          "buckets": [
            {"bucketId":"future_5h","window":"unknown","remainingFraction":1.4,"resetTime":null},
            {"bucketId":"future-monthly","window":"monthly","remainingFraction":0.5,"resetTime":null}
          ]
        }
      ]
    }
    """#

    let snapshot = try AntigravityQuotaParser.parse(
        data: try #require(json.data(using: .utf8))
    )
    #expect(snapshot.groups.count == 1)
    #expect(snapshot.groups[0].id == "future")
    #expect(snapshot.groups[0].fiveHour?.remainingPercent == 100)
    #expect(snapshot.groups[0].sevenDay == nil)
}

@Test("Rejects responses with no recognizable Antigravity windows")
func rejectsUnrecognizedAntigravityQuotaResponse() throws {
    let json = #"{"response":{"groups":[{"displayName":"Future","buckets":[{"bucketId":"future-monthly","window":"monthly","remainingFraction":0.5}]}]}}"#

    #expect(throws: AntigravityQuotaParserError.missingRecognizableQuotas) {
        try AntigravityQuotaParser.parse(
            data: try #require(json.data(using: .utf8))
        )
    }
}

@Test("Parses Antigravity subscription plan when present in response")
func parsesAntigravitySubscriptionPlan() throws {
    let json = #"""
    {
      "response": {
        "planType": "ultra",
        "groups": [
          {
            "displayName": "Gemini Models",
            "buckets": [
              {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.82,"resetTime":"2026-08-20T13:05:00Z"}
            ]
          }
        ]
      }
    }
    """#

    let snapshot = try AntigravityQuotaParser.parse(
        data: try #require(json.data(using: .utf8))
    )
    #expect(snapshot.subscriptionPlan?.identifier == "ultra")
    #expect(snapshot.subscriptionPlan?.displayName == "Ultra")
}

@Test("Parses Antigravity user tier and plan status from GetUserStatus payload")
func parsesAntigravityUserStatusPayload() throws {
    let quotaJson = #"""
    {
      "response": {
        "groups": [
          {
            "displayName": "Gemini Models",
            "buckets": [
              {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.93,"resetTime":"2026-08-24T11:10:40Z"}
            ]
          }
        ]
      }
    }
    """#

    let userStatusJson = #"""
    {
      "userStatus": {
        "planStatus": {
          "planInfo": {
            "planName": "Pro",
            "teamsTier": "TEAMS_TIER_PRO"
          }
        },
        "userTier": {
          "id": "g1-pro-tier",
          "name": "Google AI Pro",
          "description": "Google AI Pro"
        }
      }
    }
    """#

    let snapshot = try AntigravityQuotaParser.parse(
        data: try #require(quotaJson.data(using: .utf8)),
        userStatusData: userStatusJson.data(using: .utf8)
    )

    #expect(snapshot.subscriptionPlan?.displayName == "Pro")
}
