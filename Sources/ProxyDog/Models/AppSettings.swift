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
            case .system: return String(localized: "Follow system")
            case .light: return String(localized: "Light")
            case .dark: return String(localized: "Dark")
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
        static let onboarding = "app.onboardingCompleted"
        static let sslEnabled = "proxy.sslProxyingEnabled"
        static let systemProxy = "proxy.systemProxyEnabled"
        static let capacity = "capture.capacity"
        static let upstreamEnabled = "proxy.upstreamEnabled"
        static let upstreamHost = "proxy.upstreamHost"
        static let upstreamPort = "proxy.upstreamPort"
    }

    private let defaults: UserDefaults

    @Published var port: Int {
        didSet { defaults.set(port, forKey: Key.port) }
    }

    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
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

    /// Chain outbound traffic through an existing HTTP proxy (VPN client).
    @Published var upstreamProxyEnabled: Bool {
        didSet { defaults.set(upstreamProxyEnabled, forKey: Key.upstreamEnabled) }
    }

    @Published var upstreamProxyHost: String {
        didSet { defaults.set(upstreamProxyHost, forKey: Key.upstreamHost) }
    }

    @Published var upstreamProxyPort: Int {
        didSet { defaults.set(upstreamProxyPort, forKey: Key.upstreamPort) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedPort = defaults.integer(forKey: Key.port)
        self.port = storedPort > 0 ? storedPort : AppDefaults.proxyPort
        self.appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.onboarding)
        self.sslProxyingEnabled = defaults.object(forKey: Key.sslEnabled) as? Bool ?? true
        self.systemProxyEnabled = defaults.bool(forKey: Key.systemProxy)
        self.upstreamProxyEnabled = defaults.bool(forKey: Key.upstreamEnabled)
        self.upstreamProxyHost = defaults.string(forKey: Key.upstreamHost) ?? ""
        self.upstreamProxyPort = defaults.integer(forKey: Key.upstreamPort)
    }
}
