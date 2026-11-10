import Foundation

/// Wire protocol spoken by an upstream proxy.
enum UpstreamProxyKind: String, CaseIterable, Identifiable, Sendable {
    /// HTTP CONNECT tunnel (classic HTTP proxy, e.g. a VPN client's HTTP port).
    case httpConnect = "http"
    /// SOCKS5 CONNECT (e.g. a VPN client's SOCKS port).
    case socks5 = "socks5"

    var id: String { rawValue }

    /// Protocol names are technical and stay the same in every language.
    var label: String {
        switch self {
        case .httpConnect: return "HTTP"
        case .socks5: return "SOCKS5"
        }
    }
}

/// A proxy that ProxyDog chains its outbound connections through, e.g. a local VPN
/// client that already provides a system proxy (HTTP) or a SOCKS5 port.
struct UpstreamProxy: Equatable, Sendable {
    var kind: UpstreamProxyKind
    var host: String
    var port: Int

    var displayName: String { "\(kind.label) \(host):\(port)" }

    init(kind: UpstreamProxyKind = .httpConnect, host: String, port: Int) {
        self.kind = kind
        self.host = host
        self.port = port
    }

    /// Parses "host:port", also tolerating a scheme prefix:
    /// "socks5://127.0.0.1:1234", "socks://…", "http://127.0.0.1:1235", "127.0.0.1:1235".
    init?(string: String) {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind = UpstreamProxyKind.httpConnect
        if let schemeRange = value.range(of: "://") {
            let scheme = value[value.startIndex..<schemeRange.lowerBound].lowercased()
            if scheme.hasPrefix("socks") { kind = .socks5 }
            value = String(value[schemeRange.upperBound...])
        }
        if value.hasSuffix("/") { value.removeLast() }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let host = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let portText = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = Int(portText), (1...65535).contains(port) else { return nil }
        self.kind = kind
        self.host = host
        self.port = port
    }

    /// True when the host resolves to this machine (used to refuse self-chaining loops).
    var isLoopback: Bool {
        let lowered = host.lowercased()
        return lowered == "127.0.0.1" || lowered == "localhost" || lowered == "::1" || lowered == "0.0.0.0"
    }
}
