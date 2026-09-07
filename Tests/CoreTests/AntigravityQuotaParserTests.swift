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

    let thirdPartyGroup = AntigravityQuotaSnapshot.preview.groups[1]
    #expect(thirdPartyGroup.menuBarTitle(for: .fiveHour) == "✳ 5h 44%")
    #expect(thirdPartyGroup.menuBarTitle(for: .sevenDay) == "✳ 7d 28%")
    #expect(thirdPartyGroup.menuBarTitle(for: .both) == "✳ 5h 44% · 7d 28%")
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
