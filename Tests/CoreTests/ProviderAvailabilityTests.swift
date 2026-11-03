import Foundation
import Testing

@testable import QuotAICore

private let allAvailabilities: [ProviderAvailability] = {
    let flags = [false, true]
    return flags.flatMap { agEnabled in
        flags.flatMap { agInstalled in
            flags.flatMap { ccEnabled in
                flags.map { ccInstalled in
                    ProviderAvailability(
                        antigravityEnabled: agEnabled, antigravityInstalled: agInstalled,
                        claudeCodeEnabled: ccEnabled, claudeCodeInstalled: ccInstalled)
                }
            }
        }
    }
}()

@Test("A saved source always resolves to one that is offered", arguments: allAvailabilities)
func resolvedProviderIsVisible(availability: ProviderAvailability) {
    #expect(availability.visibleProviders.first == .codex)
    for saved in QuotaProvider.allCases {
        let resolved = availability.resolve(saved)
        #expect(availability.visibleProviders.contains(resolved))
        // A visible source is never replaced; a hidden one falls back to Codex.
        #expect(resolved == (availability.visibleProviders.contains(saved) ? saved : .codex))
    }
}

@Test("Sources are offered only when enabled and installed")
func visibilityRequiresBoth() {
    let none = ProviderAvailability(
        antigravityEnabled: false, antigravityInstalled: true,
        claudeCodeEnabled: true, claudeCodeInstalled: false)
    #expect(none.visibleProviders == [.codex])
    let all = ProviderAvailability(
        antigravityEnabled: true, antigravityInstalled: true,
        claudeCodeEnabled: true, claudeCodeInstalled: true)
    #expect(all.visibleProviders == [.codex, .antigravity, .claudeCode])
    #expect(all.showsAntigravity && all.showsClaudeCode)
}

@Test("The Antigravity integration is on until it is turned off")
func antigravityIntegrationDefault() throws {
    let defaults = try IsolatedDefaults()
    defer { defaults.remove() }
    #expect(ProviderAvailability.antigravityIntegrationEnabled(in: defaults.defaults))
    defaults.defaults.set(false, forKey: DefaultsKey.antigravityIntegration)
    #expect(!ProviderAvailability.antigravityIntegrationEnabled(in: defaults.defaults))
    defaults.defaults.set(true, forKey: DefaultsKey.antigravityIntegration)
    #expect(ProviderAvailability.antigravityIntegrationEnabled(in: defaults.defaults))
}

@Test("The availability initializer matches the explicit menu bar presentation", arguments: allAvailabilities)
func presentationFromAvailability(availability: ProviderAvailability) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for provider in QuotaProvider.allCases {
        let shared = MenuBarPresentation(
            provider: provider, availability: availability, selectedGroupID: "3p", mode: .both,
            codexSnapshot: .preview, antigravitySnapshot: .preview, claudeCodeSnapshot: nil,
            claudeCodeHistorical: false, isStayAwakeActive: false, now: now)
        let explicit = MenuBarPresentation(
            provider: provider, antigravityEnabled: availability.antigravityEnabled,
            antigravityAvailable: availability.antigravityInstalled, selectedGroupID: "3p", mode: .both,
            codexSnapshot: .preview, antigravitySnapshot: .preview, isStayAwakeActive: false, now: now,
            claudeCodeSnapshot: nil, claudeCodeEnabled: availability.claudeCodeEnabled,
            claudeCodeAvailable: availability.claudeCodeInstalled)
        #expect(shared == explicit)
        #expect(shared.provider == availability.resolve(provider))
    }
}
