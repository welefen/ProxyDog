import Foundation

// MARK: - Rewrite rules
//
// Static, code-free rules that rewrite traffic as it passes through the proxy. Five
// actions cover the common debugging workflows: redirecting a request, replacing or
// patching a request body, and replacing or patching a response body.

enum RewriteAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case redirect
    case replaceRequest
    case replaceResponse
    case modifyRequest
    case modifyResponse

    var id: String { rawValue }

    /// Short label used in the rules list (technical, same in every language).
    var label: String {
        switch self {
        case .redirect: return String(localized: "Redirect")
        case .replaceRequest: return String(localized: "Replace request")
        case .replaceResponse: return String(localized: "Replace response")
        case .modifyRequest: return String(localized: "Modify request")
        case .modifyResponse: return String(localized: "Modify response")
        }
    }

    /// Whether this action runs before the request is forwarded upstream.
    var isRequestPhase: Bool {
        switch self {
        case .redirect, .replaceRequest, .modifyRequest: return true
        case .replaceResponse, .modifyResponse: return false
        }
    }
}

struct RewriteRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    /// Optional HTTP method filter, e.g. "GET"; nil matches any method.
    var method: String?
    /// Regular expression matched against the full URL; plain text works as a substring.
    var urlPattern: String
    var action: RewriteAction

    /// `.redirect`: absolute URL the request is sent to instead.
    var redirectURL: String
    /// `.replaceRequest` / `.replaceResponse`: body that replaces the captured one.
    var replacementBody: String
    /// `.modifyRequest` / `.modifyResponse`: regular-expression search/replace on the body.
    var findText: String
    var replaceText: String

    /// `.replaceResponse`: synthesized status code and content type.
    var responseStatus: Int
    var responseContentType: String

    init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        method: String? = nil,
        urlPattern: String = "",
        action: RewriteAction = .modifyResponse,
        redirectURL: String = "",
        replacementBody: String = "",
        findText: String = "",
        replaceText: String = "",
        responseStatus: Int = 200,
        responseContentType: String = "application/json"
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.method = method
        self.urlPattern = urlPattern
        self.action = action
        self.redirectURL = redirectURL
        self.replacementBody = replacementBody
        self.findText = findText
        self.replaceText = replaceText
        self.responseStatus = responseStatus
        self.responseContentType = responseContentType
    }

    /// Display name fallback when the user leaves the name empty.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let pattern = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return pattern.isEmpty ? action.label : pattern
    }

    /// One-line summary for the rules list.
    var summary: String {
        let methodPrefix = method.map { "\($0.uppercased()) " } ?? ""
        return methodPrefix + urlPattern
    }

    // MARK: Matching

    /// Whether this rule applies to a request with the given method and URL.
    func matches(method requestMethod: String, url: String) -> Bool {
        guard isEnabled else { return false }
        if let method, !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard method.caseInsensitiveCompare(requestMethod) == .orderedSame else { return false }
        }
        let pattern = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(url.startIndex..<url.endIndex, in: url)
            return regex.firstMatch(in: url, options: [], range: range) != nil
        }
        // Invalid regex: fall back to a case-insensitive substring test.
        return url.range(of: pattern, options: [.caseInsensitive]) != nil
    }

    /// Applies the regex body transformation for the modify actions.
    func transform(_ body: String) -> String {
        guard !findText.isEmpty else { return body }
        guard let regex = try? NSRegularExpression(pattern: findText) else {
            return body.replacingOccurrences(of: findText, with: replaceText)
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: replaceText)
    }

    /// Compiled body transform used on raw bytes; nil when the body is not UTF-8.
    func transformData(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Data(transform(text).utf8)
    }
}

// MARK: - Effective rules for the proxy engine

/// Lock-protected snapshot the proxy engine can read from any thread. The UI store keeps
/// it in sync whenever rules change.
final class RewriteRuleSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [RewriteRule] = []

    func update(_ rules: [RewriteRule]) {
        lock.lock()
        self.rules = rules
        lock.unlock()
    }

    func current() -> [RewriteRule] {
        lock.lock()
        let copy = rules
        lock.unlock()
        return copy
    }

    /// First enabled rule matching the request, optionally restricted to a phase.
    func rule(method: String, url: String, requestPhase: Bool? = nil) -> RewriteRule? {
        current().first { rule in
            guard rule.isEnabled, rule.matches(method: method, url: url) else { return false }
            guard let requestPhase else { return true }
            return rule.action.isRequestPhase == requestPhase || rule.action == .replaceResponse
        }
    }
}

// MARK: - Persistence

/// JSON encoding helpers shared by the UI store and the headless test harness.
enum RewriteRuleCoding {
    static func decode(_ data: Data) throws -> [RewriteRule] {
        let decoder = JSONDecoder()
        return try decoder.decode([RewriteRule].self, from: data)
    }

    static func encode(_ rules: [RewriteRule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rules)
    }
}
