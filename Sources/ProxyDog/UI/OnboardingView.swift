import SwiftUI

/// Placeholder first-run setup. Replaced by the onboarding implementation
/// (`Sources/ProxyDog/UI/OnboardingView.swift`).
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Set up ProxyDog")
                .font(.title2.weight(.semibold))
            Button("Done") {
                state.dismissOnboarding()
                dismiss()
            }
        }
        .padding(32)
        .frame(width: 460, height: 320)
    }
}
