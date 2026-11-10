import Foundation

/// Which settings page should be shown when another window asks for it.
enum SettingsDestination: String, Identifiable {
    case connection
    case rules
    case appearance

    var id: String { rawValue }
}
