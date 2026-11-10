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
        static let upstreamKind = "proxy.upstreamKind"
        static let upstreamHTTPHost = "proxy.upstreamHTTPHost"
        static let upstreamHTTPPort = "proxy.upstreamHTTPPort"
        static let upstreamSOCKSHost = "proxy.upstreamSOCKSHost"
        static let upstreamSOCKSPort = "proxy.upstreamSOCKSPort"
        // Legacy single-proxy keys, still used for migration.
        static let legacyUpstreamHost = "proxy.upstreamHost"
        static let legacyUpstreamPort = "proxy.upstreamPort"
        static let socksEnabled = "proxy.socksEnabled"
        static let socksPort = "proxy.socksPort"
        static let ignoreOwnTraffic = "capture.ignoreOwnTraffic"
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

    /// HTTP upstream address (kept separately from SOCKS5 so both can be filled in).
    @Published var upstreamHTTPHost: String {
        didSet { defaults.set(upstreamHTTPHost, forKey: Key.upstreamHTTPHost) }
    }

    @Published var upstreamHTTPPort: Int {
        didSet { defaults.set(upstreamHTTPPort, forKey: Key.upstreamHTTPPort) }
    }

    /// SOCKS5 upstream address.
    @Published var upstreamSOCKSHost: String {
        didSet { defaults.set(upstreamSOCKSHost, forKey: Key.upstreamSOCKSHost) }
    }

    @Published var upstreamSOCKSPort: Int {
        didSet { defaults.set(upstreamSOCKSPort, forKey: Key.upstreamSOCKSPort) }
    }

    /// Which upstream protocol is used for chaining.
    @Published var upstreamProxyKind: UpstreamProxyKind {
        didSet { defaults.set(upstreamProxyKind.rawValue, forKey: Key.upstreamKind) }
    }

    /// Protocol used for chaining: an HTTP address wins when present, otherwise SOCKS5.
    /// Both addresses can stay stored; the switch is implicit so there is no protocol picker.
    var effectiveUpstreamKind: UpstreamProxyKind {
        let httpHost = upstreamHTTPHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !httpHost.isEmpty, (1...65535).contains(upstreamHTTPPort) { return .httpConnect }
        let socksHost = upstreamSOCKSHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !socksHost.isEmpty, (1...65535).contains(upstreamSOCKSPort) { return .socks5 }
        return upstreamProxyKind
    }

    /// Address of the currently selected upstream protocol.
    var upstreamHost: String {
        upstreamProxyKind == .httpConnect ? upstreamHTTPHost : upstreamSOCKSHost
    }

    var upstreamPort: Int {
        upstreamProxyKind == .httpConnect ? upstreamHTTPPort : upstreamSOCKSPort
    }

    func upstreamHost(for kind: UpstreamProxyKind) -> String {
        kind == .httpConnect ? upstreamHTTPHost : upstreamSOCKSHost
    }

    func upstreamPort(for kind: UpstreamProxyKind) -> Int {
        kind == .httpConnect ? upstreamHTTPPort : upstreamSOCKSPort
    }

    func setUpstreamAddress(host: String, port: Int, kind: UpstreamProxyKind) {
        switch kind {
        case .httpConnect:
            upstreamHTTPHost = host
            upstreamHTTPPort = port
        case .socks5:
            upstreamSOCKSHost = host
            upstreamSOCKSPort = port
        }
    }

    /// Extra SOCKS5 listener so apps that only speak SOCKS5 can be inspected.
    @Published var socksProxyEnabled: Bool {
        didSet { defaults.set(socksProxyEnabled, forKey: Key.socksEnabled) }
    }

    @Published var socksProxyPort: Int {
        didSet { defaults.set(socksProxyPort, forKey: Key.socksPort) }
    }

    /// Hides traffic generated by ProxyDog itself (analytics, update checks) from the list.
    @Published var ignoreOwnTraffic: Bool {
        didSet { defaults.set(ignoreOwnTraffic, forKey: Key.ignoreOwnTraffic) }
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
        let storedKind = UpstreamProxyKind(rawValue: defaults.string(forKey: Key.upstreamKind) ?? "") ?? .httpConnect
        self.upstreamProxyKind = storedKind
        // Migrate the old single-address configuration into the matching protocol slot.
        let legacyHost = defaults.string(forKey: Key.legacyUpstreamHost) ?? ""
        let legacyPort = defaults.integer(forKey: Key.legacyUpstreamPort)
        self.upstreamHTTPHost = defaults.string(forKey: Key.upstreamHTTPHost)
            ?? (storedKind == .httpConnect ? legacyHost : "")
        let storedHTTPPort = defaults.integer(forKey: Key.upstreamHTTPPort)
        self.upstreamHTTPPort = storedHTTPPort > 0 ? storedHTTPPort : (storedKind == .httpConnect ? legacyPort : 0)
        self.upstreamSOCKSHost = defaults.string(forKey: Key.upstreamSOCKSHost)
            ?? (storedKind == .socks5 ? legacyHost : "")
        let storedSOCKSPort = defaults.integer(forKey: Key.upstreamSOCKSPort)
        self.upstreamSOCKSPort = storedSOCKSPort > 0 ? storedSOCKSPort : (storedKind == .socks5 ? legacyPort : 0)
        self.socksProxyEnabled = defaults.object(forKey: Key.socksEnabled) as? Bool ?? false
        let storedSocksPort = defaults.integer(forKey: Key.socksPort)
        self.socksProxyPort = storedSocksPort > 0 ? storedSocksPort : AppDefaults.socksPort
        self.ignoreOwnTraffic = defaults.object(forKey: Key.ignoreOwnTraffic) as? Bool ?? true
    }
}
