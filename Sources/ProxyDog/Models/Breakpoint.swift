import Combine
import Foundation
import NIOCore

// MARK: - Breakpoint rules
//
// A breakpoint pauses matching traffic so the user can edit it by hand, then resume or
// drop it. Unlike rewrite rules it only fires while the app is running and waiting.

enum BreakpointPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case request
    case response

    var id: String { rawValue }

    var label: String {
        switch self {
        case .request: return String(localized: "Request")
        case .response: return String(localized: "Response")
        }
    }
}

struct BreakpointRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    /// Optional HTTP method filter; nil matches any method.
    var method: String?
    /// Regular expression matched against the full URL; plain text works as a substring.
    var urlPattern: String
    var breakOnRequest: Bool
    var breakOnResponse: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        method: String? = nil,
        urlPattern: String = "",
        breakOnRequest: Bool = true,
        breakOnResponse: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.method = method
        self.urlPattern = urlPattern
        self.breakOnRequest = breakOnRequest
        self.breakOnResponse = breakOnResponse
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let pattern = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return pattern.isEmpty ? "Breakpoint" : pattern
    }

    var summary: String {
        let methodPrefix = method.map { "\($0.uppercased()) " } ?? ""
        return methodPrefix + urlPattern
    }

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
        return url.range(of: pattern, options: [.caseInsensitive]) != nil
    }
}

final class BreakpointRuleSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [BreakpointRule] = []

    func update(_ rules: [BreakpointRule]) {
        lock.lock()
        self.rules = rules
        lock.unlock()
    }

    func current() -> [BreakpointRule] {
        lock.lock()
        let copy = rules
        lock.unlock()
        return copy
    }

    /// First enabled rule matching the exchange and pausing in the given phase.
    func rule(method: String, url: String, phase: BreakpointPhase) -> BreakpointRule? {
        current().first { rule in
            guard rule.isEnabled, rule.matches(method: method, url: url) else { return false }
            switch phase {
            case .request: return rule.breakOnRequest
            case .response: return rule.breakOnResponse
            }
        }
    }
}

// MARK: - A paused exchange waiting for the user

struct BreakpointPayload: Identifiable, Equatable, Sendable {
    let id: UUID
    let phase: BreakpointPhase
    let ruleName: String
    let method: String
    let url: String
    let statusCode: Int?
    let contentType: String?
    /// Editable body (UTF-8 text; empty for bodies that are not text).
    let bodyText: String
    let headers: [HeaderField]
    let createdAt: Date

    var isResponse: Bool { phase == .response }
}

enum BreakpointDecision: Sendable {
    /// Continue the exchange; when `body` is non-nil it replaces the body.
    case resume(body: String?)
    case drop
}

// MARK: - Gate between the proxy engine and the UI

/// Thread-safe rendezvous between NIO event loops (which must not block) and the main
/// actor UI. Paused exchanges are kept in a FIFO queue; resolving one continues it on its
/// event loop. A timeout resumes an exchange unchanged so a forgotten sheet cannot wedge
/// the proxy forever.
final class BreakpointGate: @unchecked Sendable {
    private struct Waiting {
        let payload: BreakpointPayload
        let eventLoop: EventLoop
        let completion: (BreakpointDecision) -> Void
    }

    private let lock = NSLock()
    private var waiting: [Waiting] = []
    /// UI hook, called on the main queue with the current queue.
    var onPendingChanged: (@Sendable ([BreakpointPayload]) -> Void)?
    /// Headless/testing hook: when set, pending breakpoints are resolved automatically.
    var autoResolver: (@Sendable (BreakpointPayload) -> BreakpointDecision?)?

    private let timeoutSeconds: TimeInterval = 120

    func pending() -> [BreakpointPayload] {
        lock.lock()
        let copy = waiting.map(\.payload)
        lock.unlock()
        return copy
    }

    /// Called from an event loop. Registers the pause and returns immediately; the
    /// completion runs back on the same event loop when the user decides or times out.
    func wait(
        payload: BreakpointPayload,
        on eventLoop: EventLoop,
        completion: @escaping (BreakpointDecision) -> Void
    ) {
        let waiting = Waiting(payload: payload, eventLoop: eventLoop, completion: completion)
        lock.lock()
        self.waiting.append(waiting)
        let snapshot = self.waiting.map(\.payload)
        let resolver = autoResolver
        lock.unlock()

        if let resolver, let decision = resolver(payload) {
            resolve(id: payload.id, decision: decision)
            return
        }
        onPendingChanged?(snapshot)
        eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) { [weak self] in
            self?.resolve(id: payload.id, decision: .resume(body: nil))
        }
    }

    /// Called from the UI (or the headless auto resolver) to continue or drop an exchange.
    func resolve(id: UUID, decision: BreakpointDecision) {
        lock.lock()
        guard let index = waiting.firstIndex(where: { $0.payload.id == id }) else {
            lock.unlock()
            return
        }
        let item = waiting.remove(at: index)
        let snapshot = waiting.map(\.payload)
        lock.unlock()

        item.eventLoop.execute {
            item.completion(decision)
        }
        onPendingChanged?(snapshot)
    }

    /// Convenience used by the UI to release everything (e.g. app quits).
    func resumeAll() {
        let ids = pending().map(\.id)
        for id in ids {
            resolve(id: id, decision: .resume(body: nil))
        }
    }
}

// MARK: - Persistence

@MainActor
final class BreakpointRuleStore: ObservableObject {
    static let defaultsKey = "breakpoint.rules"

    @Published var rules: [BreakpointRule] {
        didSet { persist() }
    }

    let snapshot = BreakpointRuleSnapshot()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([BreakpointRule].self, from: data) {
            self.rules = decoded
        } else {
            self.rules = []
        }
        snapshot.update(rules)
    }

    func add(_ rule: BreakpointRule) { rules.append(rule) }

    func update(_ rule: BreakpointRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func remove(id: BreakpointRule.ID) { rules.removeAll { $0.id == id } }

    func setEnabled(_ enabled: Bool, id: BreakpointRule.ID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
    }

    private func persist() {
        snapshot.update(rules)
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
