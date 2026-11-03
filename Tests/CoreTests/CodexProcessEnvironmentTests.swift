import CFNetwork
import Testing

@testable import QuotAICore

@Test("Maps the macOS HTTPS proxy into the Codex child environment")
func mapsSystemHTTPSProxy() throws {
    let proxy: [String: Any] = [
        kCFProxyTypeKey as String: kCFProxyTypeHTTPS as String,
        kCFProxyHostNameKey as String: "127.0.0.1",
        kCFProxyPortNumberKey as String: 7890
    ]

    let resolution = CodexProcessEnvironment.resolve(
        baseEnvironment: ["PATH": "/usr/bin"],
        proxyDictionaries: [proxy]
    )

    #expect(resolution.proxySource == .systemHTTPS)
    #expect(resolution.environment["HTTPS_PROXY"] == "http://127.0.0.1:7890")
    #expect(resolution.environment["https_proxy"] == "http://127.0.0.1:7890")
    #expect(resolution.environment["PATH"] == "/usr/bin")
}

@Test("Keeps an explicit proxy environment ahead of macOS settings")
func preservesExplicitProxyEnvironment() {
    let existingProxy = "http://localhost:6152"
    let proxy: [String: Any] = [
        kCFProxyTypeKey as String: kCFProxyTypeHTTPS as String,
        kCFProxyHostNameKey as String: "127.0.0.1",
        kCFProxyPortNumberKey as String: 7890
    ]

    let resolution = CodexProcessEnvironment.resolve(
        baseEnvironment: ["HTTPS_PROXY": existingProxy],
        proxyDictionaries: [proxy]
    )

    #expect(resolution.proxySource == .environment)
    #expect(resolution.environment["HTTPS_PROXY"] == existingProxy)
}

@Test("Maps the macOS SOCKS proxy into the Codex child environment")
func mapsSystemSOCKSProxy() {
    let proxy: [String: Any] = [
        kCFProxyTypeKey as String: kCFProxyTypeSOCKS as String,
        kCFProxyHostNameKey as String: "localhost",
        kCFProxyPortNumberKey as String: 1080
    ]

    let resolution = CodexProcessEnvironment.resolve(
        baseEnvironment: [:],
        proxyDictionaries: [proxy]
    )

    #expect(resolution.proxySource == .systemSOCKS)
    #expect(resolution.environment["ALL_PROXY"] == "socks5h://localhost:1080")
    #expect(resolution.environment["all_proxy"] == "socks5h://localhost:1080")
}
