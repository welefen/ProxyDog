import Combine
import Foundation

/// User-facing store for static rewrite rules. Persisted as JSON in UserDefaults and
/// mirrored into a lock-protected snapshot the proxy engine can read off the main actor.
@MainActor
final class RewriteRuleStore: ObservableObject {
    static let defaultsKey = "rewrite.rules"

    @Published var rules: [RewriteRule] {
        didSet { persist() }
    }

    let snapshot = RewriteRuleSnapshot()

    private let defaults: UserDefaults
    private var isLoading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded: [RewriteRule]
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? RewriteRuleCoding.decode(data) {
            loaded = decoded
        } else {
            loaded = []
        }
        self.rules = loaded
        snapshot.update(loaded)
    }

    // MARK: Mutations

    func add(_ rule: RewriteRule) {
        rules.append(rule)
    }

    func update(_ rule: RewriteRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func remove(id: RewriteRule.ID) {
        rules.removeAll { $0.id == id }
    }

    func setEnabled(_ enabled: Bool, id: RewriteRule.ID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
    }

    // MARK: Persistence

    private func persist() {
        guard !isLoading else { return }
        snapshot.update(rules)
        guard let data = try? RewriteRuleCoding.encode(rules) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
