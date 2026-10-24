import CFNetwork
import Foundation

/// An allowlist, not inherited process environment. Never copy account tokens or proxy credentials.
/// Rust CLI processes do not automatically use the HTTP proxy configured for macOS applications.
enum CodexSystemEnvironment {
    static func current() -> [String: String] {
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        return environment(settings: settings, home: NSHomeDirectory())
    }

    static func environment(settings: [String: Any], home: String) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin", "HOME": home, "CODEX_HOME": home + "/.codex"]
        // PAC requires URL-specific evaluation and is not approximated as a manual proxy.
        guard (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue != true else { return environment }
        for (kind, name) in [("HTTP", "HTTP_PROXY"), ("HTTPS", "HTTPS_PROXY")] {
            guard (settings[kind + "Enable"] as? NSNumber)?.boolValue == true,
                  let host = settings[kind + "Proxy"] as? String, !host.isEmpty,
                  !host.contains(where: { $0.isWhitespace || "@/?#\\".contains($0) }),
                  let number = settings[kind + "Port"] as? NSNumber,
                  number.doubleValue == Double(number.intValue), (1...65535).contains(number.intValue) else { continue }
            var components = URLComponents()
            components.scheme = "http" // HTTP CONNECT proxy for HTTPS destinations as configured by macOS.
            components.host = host; components.port = number.intValue
            guard let url = components.url, url.user == nil, url.password == nil,
                  url.host == host, let value = components.string else { continue }
            environment[name] = value
        }
        return environment
    }
}
