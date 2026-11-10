import Foundation
import SwiftUI

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "Follow system"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    private enum Key {
        static let port = "proxy.port"
        static let appearance = "ui.appearance"
        static let aptabaseKey = "analytics.aptabaseKey"
        static let onboarding = "app.onboardingCompleted"
        static let sslEnabled = "proxy.sslProxyingEnabled"
        static let systemProxy = "proxy.systemProxyEnabled"
        static let capacity = "capture.capacity"
    }

    private let defaults: UserDefaults

    @Published var port: Int {
        didSet { defaults.set(port, forKey: Key.port) }
    }

    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    @Published var aptabaseAppKey: String {
        didSet { defaults.set(aptabaseAppKey, forKey: Key.aptabaseKey) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarding) }
    }

    @Published var sslProxyingEnabled: Bool {
        didSet { defaults.set(sslProxyingEnabled, forKey: Key.sslEnabled) }
    }

    @Published var systemProxyEnabled: Bool {
        didSet { defaults.set(systemProxyEnabled, forKey: Key.systemProxy) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedPort = defaults.integer(forKey: Key.port)
        self.port = storedPort > 0 ? storedPort : AppDefaults.proxyPort
        self.appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        self.aptabaseAppKey = defaults.string(forKey: Key.aptabaseKey) ?? ""
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.onboarding)
        self.sslProxyingEnabled = defaults.object(forKey: Key.sslEnabled) as? Bool ?? true
        self.systemProxyEnabled = defaults.bool(forKey: Key.systemProxy)
    }

    var analyticsEnabled: Bool {
        !aptabaseAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
