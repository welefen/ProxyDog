import Foundation

/// AI provider configuration, persisted locally. The API key lives in the keychain;
/// provider/base URL/model live in UserDefaults.
@MainActor
final class AIConfigStore: ObservableObject {
    static let shared = AIConfigStore()

    private enum Key {
        static let provider = "ai.provider"
        static let baseURL = "ai.baseURL"
        static let model = "ai.model"
    }

    private let defaults = UserDefaults.standard

    @Published var provider: AIProvider {
        didSet { defaults.set(provider.rawValue, forKey: Key.provider) }
    }
    @Published var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Key.baseURL) }
    }
    @Published var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }
    @Published var apiKey: String {
        didSet {
            guard !isLoadingKey else { return }
            AIKeychain.save(apiKey)
            if !apiKey.isEmpty { hasStoredKey = true }
        }
    }
    @Published private(set) var hasStoredKey: Bool
    private var isLoadingKey = false

    private init() {
        let environment = ProcessInfo.processInfo.environment
        provider = AIProvider(rawValue: defaults.string(forKey: Key.provider) ?? "")
            ?? AIProvider(rawValue: environment["PROXYDOG_AI_PROVIDER"] ?? "")
            ?? .deepSeek
        baseURL = environment["PROXYDOG_AI_BASE_URL"] ?? defaults.string(forKey: Key.baseURL) ?? ""
        model = environment["PROXYDOG_AI_MODEL"] ?? defaults.string(forKey: Key.model) ?? ""
        // Never touch the keychain during launch: reading the secret can prompt for
        // keychain approval. Load it lazily when the AI feature is actually used.
        if let environmentKey = environment["PROXYDOG_AI_KEY"], !environmentKey.isEmpty {
            apiKey = environmentKey
            hasStoredKey = true
        } else {
            apiKey = ""
            hasStoredKey = AIKeychain.exists()
        }
    }

    var isConfigured: Bool {
        let hasKey = hasStoredKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasModel = !provider.defaultModel.isEmpty || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBase = !provider.defaultBaseURL.isEmpty || !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasKey && hasModel && hasBase
    }

    var displayModel: String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.defaultModel : value
    }

    var storedKeyPlaceholder: String {
        hasStoredKey && apiKey.isEmpty
            ? String(localized: "API key is saved (leave blank to keep it)")
            : String(localized: "Paste your API key")
    }

    /// Builds the request configuration, reading a stored keychain key on demand.
    func makeConfiguration() -> AIConfiguration {
        if apiKey.isEmpty, hasStoredKey {
            isLoadingKey = true
            apiKey = AIKeychain.read() ?? ""
            isLoadingKey = false
        }
        return AIConfiguration(provider: provider, apiKey: apiKey, baseURL: baseURL, model: model)
    }

    func clearKey() {
        isLoadingKey = true
        apiKey = ""
        isLoadingKey = false
        hasStoredKey = false
        AIKeychain.delete()
    }
}
