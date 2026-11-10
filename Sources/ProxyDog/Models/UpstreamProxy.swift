import Foundation

/// An HTTP CONNECT proxy that ProxyDog chains its outbound connections through, e.g.
/// a local VPN client that already provides the system proxy.
struct UpstreamProxy: Equatable, Sendable {
    var host: String
    var port: Int

    var displayName: String { "\(host):\(port)" }

    /// Parses "host:port" (also tolerates a scheme prefix, e.g. "http://127.0.0.1:1235").
    init?(string: String) {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        if value.hasSuffix("/") { value.removeLast() }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let host = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let portText = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = Int(portText), (1...65535).contains(port) else { return nil }
        self.host = host
        self.port = port
    }

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// True when the host resolves to this machine (used to refuse self-chaining loops).
    var isLoopback: Bool {
        let lowered = host.lowercased()
        return lowered == "127.0.0.1" || lowered == "localhost" || lowered == "::1" || lowered == "0.0.0.0"
    }
}
