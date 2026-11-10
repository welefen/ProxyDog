import AppKit
import SwiftUI

/// Placeholder root view. Replaced by the UI implementation
/// (`Sources/ProxyDog/UI/ContentView.swift`).
struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Text(AppInfo.name)
                .font(.largeTitle.weight(.semibold))
            Text("UI is under construction")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $state.isOnboardingPresented) {
            OnboardingView()
                .environmentObject(state)
        }
    }
}
