import Foundation
import NIOHTTP1

/// Applies the user's static rewrite rules to proxied exchanges.
///
/// Request-phase actions (`replaceResponse`, `redirect`, `replaceRequest`, `modifyRequest`)
/// run before any upstream connection is opened; the response-phase action
/// (`modifyResponse`) runs once the upstream body has been received. Matching is done
/// against the *original*, client-visible URL, and every rule application is recorded on the
/// capture (`rewriteRuleName` / `rewriteAction`).
enum RewriteEngine {
    static let requestPhaseActions: Set<RewriteAction> = [
        .replaceResponse, .redirect, .replaceRequest, .modifyRequest,
    ]

    /// Client-visible URL in the same shape as `CapturedRequest.urlString`.
    static func urlString(scheme: String, host: String, port: Int, path: String) -> String {
        let defaultPort = scheme.lowercased() == "https" ? 443 : 80
        let portPart = port == defaultPort ? "" : ":\(port)"
        let normalizedPath = path.isEmpty ? "/" : path
        return "\(scheme)://\(host)\(portPart)\(normalizedPath)"
    }

    static func requestPhaseRule(_ rules: [RewriteRule], method: String, url: String) -> RewriteRule? {
        rules.first { rule in
            rule.isEnabled && requestPhaseActions.contains(rule.action) && rule.matches(method: method, url: url)
        }
    }

    static func responsePhaseRule(_ rules: [RewriteRule], method: String, url: String) -> RewriteRule? {
        rules.first { rule in
            rule.isEnabled && rule.action == .modifyResponse && rule.matches(method: method, url: url)
        }
    }

    struct RedirectTarget {
        let scheme: String
        let host: String
        let port: Int
        let path: String
    }

    /// Parses the absolute URL used by `.redirect`; nil when it is not a usable http(s) URL
    /// (the rule is then ignored instead of failing the exchange).
    static func redirectTarget(_ raw: String) -> RedirectTarget? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let schemeRange = value.range(of: "://") else { return nil }
        let scheme = String(value[..<schemeRange.lowerBound]).lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let rest = value[schemeRange.upperBound...]
        guard !rest.isEmpty else { return nil }

        let defaultPort = scheme == "https" ? 443 : 80
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
        let authority = authorityEnd.map { String(rest[..<$0]) } ?? String(rest)
        guard let (host, port) = ProxyWire.splitAuthority(authority, defaultPort: defaultPort) else {
            return nil
        }
        let path: String
        if let authorityEnd {
            let tail = String(rest[authorityEnd...])
            path = tail.hasPrefix("?") ? "/" + tail : tail
        } else {
            path = "/"
        }
        return RedirectTarget(scheme: scheme, host: host, port: port, path: path.isEmpty ? "/" : path)
    }

    static func responseStatus(_ raw: Int) -> HTTPResponseStatus {
        guard (100...599).contains(raw) else { return .ok }
        return HTTPResponseStatus(statusCode: raw)
    }

    /// Content-Type used for a synthesized `.replaceResponse` body.
    static func contentType(_ rule: RewriteRule) -> String {
        let value = rule.responseContentType.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "application/json" : value
    }

    /// Default-port aware `Host` header value for a redirect target.
    static func hostHeader(scheme: String, host: String, port: Int) -> String {
        let defaultPort = scheme.lowercased() == "https" ? 443 : 80
        return port == defaultPort ? host : "\(host):\(port)"
    }
}
