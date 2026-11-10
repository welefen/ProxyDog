import AppKit
import Foundation

/// In-app language selection. macOS resolves the bundle localization from
/// `AppleLanguages`, so switching language is applied to the app's own defaults and
/// takes effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// Language names are always shown in their own language so the picker stays
    /// readable whatever the current localization is.
    var displayName: String {
        switch self {
        case .system:
            return String(localized: "Follow system")
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    /// Stored preference (`.system` when the user never chose a language).
    static var stored: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: Keys.language),
              let language = AppLanguage(rawValue: raw)
        else { return .system }
        return language
    }

    /// Language actually used for the interface right now.
    static var effective: AppLanguage {
        let stored = Self.stored
        if stored != .system { return stored }
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// Persists the choice and forces the app to restart with the new language.
    @MainActor
    static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: Keys.language)
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .simplifiedChinese:
            defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        case .english:
            defaults.set(["en"], forKey: "AppleLanguages")
        }
        rerunAfterLanguageChange()
    }

    /// Relaunches the app bundle; a bare executable (dev runs) simply exits.
    @MainActor
    static func rerunAfterLanguageChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let bundleURL = Bundle.main.bundleURL
            guard bundleURL.pathExtension == "app" else {
                exit(0)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundleURL.path]
            try? process.run()
            exit(0)
        }
    }

    /// Clears the language override, e.g. for `--reset-app` style dev flows.
    static func clearOverride() {
        UserDefaults.standard.removeObject(forKey: Keys.language)
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }

    private enum Keys {
        static let language = "ui.language"
    }
}
