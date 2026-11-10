import Foundation

/// Which settings page should be shown when another window asks for it.
enum SettingsDestination: String, Identifiable {
    case connection
    case rules
    case appearance

    var id: String { rawValue }
}

/// Which rule editor should open from an external entry point.
enum RuleEditorTarget: String, Identifiable {
    case rewrite
    case breakpoint

    var id: String { rawValue }
}
