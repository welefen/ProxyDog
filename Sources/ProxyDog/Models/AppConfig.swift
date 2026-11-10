import Foundation

/// Build-time configuration, supplied by whoever builds the app.
///
/// The Aptabase app key is intentionally not user-configurable: it is injected into
/// `Info.plist` from the gitignored `Support/AppConfig.plist` by `scripts/build_app.sh`
/// when the app is built. For local debugging the key can also come from the
/// `PROXYDOG_APTABASE_KEY` environment variable or a `--aptabase-key` launch argument.
/// When nothing is configured analytics stays completely disabled.
enum AppConfig {
    /// Aptabase project key, e.g. `A-US-XXXXXXXXXX`.
    static var aptabaseAppKey: String {
        if let value = launchArgumentValue("--aptabase-key"), !value.isEmpty {
            return value
        }
        if let value = ProcessInfo.processInfo.environment["PROXYDOG_APTABASE_KEY"], !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: InfoKey.aptabaseAppKey) as? String {
            return value
        }
        return ""
    }

    static var isAnalyticsEnabled: Bool {
        !aptabaseAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func launchArgumentValue(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        for argument in arguments where argument.hasPrefix(flag + "=") {
            return String(argument.dropFirst(flag.count + 1))
        }
        return nil
    }

    private enum InfoKey {
        static let aptabaseAppKey = "ProxyDogAptabaseAppKey"
    }
}
