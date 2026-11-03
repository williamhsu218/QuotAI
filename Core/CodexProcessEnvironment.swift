import CFNetwork
import Foundation

enum CodexProxySource: String, Sendable {
    case environment
    case systemHTTP
    case systemHTTPS
    case systemSOCKS
    case autoConfiguration
    case direct
}

struct CodexProcessEnvironmentResolution: Sendable {
    let environment: [String: String]
    let proxySource: CodexProxySource
    let hasCustomCertificate: Bool
}

enum CodexProcessEnvironment {
    private static let proxyVariableNames = [
        "HTTPS_PROXY", "https_proxy",
        "HTTP_PROXY", "http_proxy",
        "ALL_PROXY", "all_proxy"
    ]

    private static let certificateVariableNames = [
        "CODEX_CA_CERTIFICATE", "SSL_CERT_FILE"
    ]

    static func resolve(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        targetURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    ) -> CodexProcessEnvironmentResolution {
        if hasUsableValue(in: baseEnvironment, names: proxyVariableNames) {
            return resolution(
                environment: baseEnvironment,
                proxySource: .environment
            )
        }

        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
        else {
            return resolution(
                environment: baseEnvironment,
                proxySource: .direct
            )
        }

        let proxies = CFNetworkCopyProxiesForURL(
            targetURL as CFURL,
            settings
        ).takeRetainedValue()
        let dictionaries = (proxies as NSArray).compactMap {
            $0 as? [String: Any]
        }
        return resolve(
            baseEnvironment: baseEnvironment,
            proxyDictionaries: dictionaries
        )
    }

    static func resolve(
        baseEnvironment: [String: String],
        proxyDictionaries: [[String: Any]]
    ) -> CodexProcessEnvironmentResolution {
        if hasUsableValue(in: baseEnvironment, names: proxyVariableNames) {
            return resolution(
                environment: baseEnvironment,
                proxySource: .environment
            )
        }

        for proxy in proxyDictionaries {
            guard let type = proxy[kCFProxyTypeKey as String] as? String else {
                continue
            }

            if type == kCFProxyTypeNone as String {
                return resolution(
                    environment: baseEnvironment,
                    proxySource: .direct
                )
            }

            if type == kCFProxyTypeAutoConfigurationURL as String
                || type == kCFProxyTypeAutoConfigurationJavaScript as String
            {
                return resolution(
                    environment: baseEnvironment,
                    proxySource: .autoConfiguration
                )
            }

            if type == kCFProxyTypeSOCKS as String,
                let proxyURL = proxyURL(from: proxy, scheme: "socks5h")
            {
                var environment = baseEnvironment
                set(proxyURL, names: ["ALL_PROXY", "all_proxy"], in: &environment)
                return resolution(
                    environment: environment,
                    proxySource: .systemSOCKS
                )
            }

            if type == kCFProxyTypeHTTPS as String,
                let proxyURL = proxyURL(from: proxy, scheme: "http")
            {
                var environment = baseEnvironment
                set(proxyURL, names: ["HTTPS_PROXY", "https_proxy"], in: &environment)
                return resolution(
                    environment: environment,
                    proxySource: .systemHTTPS
                )
            }

            if type == kCFProxyTypeHTTP as String,
                let proxyURL = proxyURL(from: proxy, scheme: "http")
            {
                var environment = baseEnvironment
                set(
                    proxyURL,
                    names: [
                        "HTTP_PROXY", "http_proxy",
                        "HTTPS_PROXY", "https_proxy"
                    ],
                    in: &environment
                )
                return resolution(
                    environment: environment,
                    proxySource: .systemHTTP
                )
            }
        }

        return resolution(
            environment: baseEnvironment,
            proxySource: .direct
        )
    }

    private static func proxyURL(
        from dictionary: [String: Any],
        scheme: String
    ) -> String? {
        guard let host = dictionary[kCFProxyHostNameKey as String] as? String,
            !host.isEmpty
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = dictionary[kCFProxyPortNumberKey as String] as? NSNumber,
            port.intValue > 0
        {
            components.port = port.intValue
        }
        components.user = dictionary[kCFProxyUsernameKey as String] as? String
        components.password = dictionary[kCFProxyPasswordKey as String] as? String
        return components.string
    }

    private static func set(
        _ value: String,
        names: [String],
        in environment: inout [String: String]
    ) {
        for name in names where environment[name]?.isEmpty != false {
            environment[name] = value
        }
    }

    private static func resolution(
        environment: [String: String],
        proxySource: CodexProxySource
    ) -> CodexProcessEnvironmentResolution {
        CodexProcessEnvironmentResolution(
            environment: environment,
            proxySource: proxySource,
            hasCustomCertificate: hasUsableValue(
                in: environment,
                names: certificateVariableNames
            )
        )
    }

    private static func hasUsableValue(
        in environment: [String: String],
        names: [String]
    ) -> Bool {
        names.contains {
            !(environment[$0] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }
}
