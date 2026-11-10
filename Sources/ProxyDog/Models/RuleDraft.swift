import Foundation

/// Helpers for creating pre-filled rewrite / breakpoint rules from a captured request
/// (used by the traffic list context menu).
enum RuleDraft {
    /// A regex that matches exactly the given URL (all regex metacharacters escaped).
    static func literalPattern(for url: String) -> String {
        NSRegularExpression.escapedPattern(for: url)
    }

    /// Readable default name: host + path without query string, truncated.
    static func suggestedName(for request: CapturedRequest) -> String {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let name = request.host + (path == "/" ? "" : path)
        return String(name.prefix(80))
    }
}
