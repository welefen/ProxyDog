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
        didSet { AIKeychain.save(apiKey) }
    }

    private init() {
        let environment = ProcessInfo.processInfo.environment
        provider = AIProvider(rawValue: defaults.string(forKey: Key.provider) ?? "")
            ?? AIProvider(rawValue: environment["PROXYDOG_AI_PROVIDER"] ?? "")
            ?? .deepSeek
        baseURL = environment["PROXYDOG_AI_BASE_URL"] ?? defaults.string(forKey: Key.baseURL) ?? ""
        model = environment["PROXYDOG_AI_MODEL"] ?? defaults.string(forKey: Key.model) ?? ""
        apiKey = environment["PROXYDOG_AI_KEY"] ?? AIKeychain.read() ?? ""
    }

    var configuration: AIConfiguration {
        AIConfiguration(provider: provider, apiKey: apiKey, baseURL: baseURL, model: model)
    }

    func clearKey() {
        apiKey = ""
        AIKeychain.delete()
    }
}
