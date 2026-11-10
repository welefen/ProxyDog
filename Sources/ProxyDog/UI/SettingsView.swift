import SwiftUI

/// Placeholder settings pane. Replaced by the settings implementation
/// (`Sources/ProxyDog/UI/SettingsView.swift`).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Spacer()
            Text(AppInfo.versionLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
