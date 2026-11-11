import Foundation
import Security

/// AI provider configuration, persisted locally. The API key lives in the keychain;
/// provider/base URL/model live in UserDefaults.
@MainActor
final class AIConfigStore: ObservableObject {
    static let shared = AIConfigStore()

    private enum Key {
        static let provider = "ai.provider"
        static let baseURL = "ai.baseURL"
        static let model = "ai.model"
        static let apiKey = "ai.apiKey"
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
    /// Stored locally in UserDefaults; never in the keychain.
    @Published var apiKey: String {
        didSet {
            if apiKey.isEmpty {
                defaults.removeObject(forKey: Key.apiKey)
            } else {
                defaults.set(apiKey, forKey: Key.apiKey)
            }
        }
    }

    private init() {
        let environment = ProcessInfo.processInfo.environment
        provider = AIProvider(rawValue: defaults.string(forKey: Key.provider) ?? "")
            ?? AIProvider(rawValue: environment["PROXYDOG_AI_PROVIDER"] ?? "")
            ?? .deepSeek
        baseURL = environment["PROXYDOG_AI_BASE_URL"] ?? defaults.string(forKey: Key.baseURL) ?? ""
        model = environment["PROXYDOG_AI_MODEL"] ?? defaults.string(forKey: Key.model) ?? ""
        apiKey = environment["PROXYDOG_AI_KEY"] ?? defaults.string(forKey: Key.apiKey) ?? ""

        // Older builds stored the key in the login keychain; remove that legacy item
        // best-effort. The key is now kept in preferences only.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.proxydog.app.ai",
            kSecAttrAccount as String: "apiKey",
        ] as CFDictionary)
    }

    var configuration: AIConfiguration {
        AIConfiguration(provider: provider, apiKey: apiKey, baseURL: baseURL, model: model)
    }

    var isConfigured: Bool {
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasModel = !provider.defaultModel.isEmpty || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBase = !provider.defaultBaseURL.isEmpty || !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasKey && hasModel && hasBase
    }

    var displayModel: String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.defaultModel : value
    }

    func clearKey() {
        apiKey = ""
    }
}
