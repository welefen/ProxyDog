import AppKit
import SwiftUI

/// First-run onboarding sheet: a short three step wizard (welcome, certificate,
/// ready). Every step has one primary action and a quiet way to skip it; closing the
/// sheet skips the whole setup.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case certificate
        case ready

        var id: Int { rawValue }
    }

    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .padding(.horizontal, DS.Space.x6)
                .padding(.top, DS.Space.x4)
                .padding(.bottom, DS.Space.x4)
            footer
        }
        .frame(width: 520, height: 430)
        .background(DSColor.chrome)
        .onAppear {
            state.refreshCertificateStatus()
            state.refreshSystemProxyState()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        ZStack {
            stepIndicator
            HStack {
                if step == .welcome {
                    Color.clear.frame(width: 24, height: 24)
                } else {
                    OnboardingIconButton(systemName: "chevron.left", help: "Back") {
                        goBack()
                    }
                }
                Spacer(minLength: 0)
                OnboardingIconButton(systemName: "xmark", help: "Close setup") {
                    skipSetup()
                }
            }
        }
        .padding(.horizontal, DS.Space.x5)
        .padding(.top, DS.Space.x4)
    }

    private var stepIndicator: some View {
        HStack(spacing: DS.Space.x1) {
            ForEach(Step.allCases) { candidate in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(indicatorColor(for: candidate))
                    .frame(width: 16, height: 3)
            }
        }
        .accessibilityLabel(String(
            format: String(localized: "Step %lld of %lld"),
            step.rawValue + 1,
            Step.allCases.count
        ))
    }

    private func indicatorColor(for candidate: Step) -> Color {
        if candidate == step { return DSColor.accent }
        if candidate.rawValue < step.rawValue { return DSColor.textMuted.opacity(0.5) }
        return DSColor.border
    }

    // MARK: - Content

    private var content: some View {
        ZStack {
            stepContent
                .id(step)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: step)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .certificate:
            certificateStep
        case .ready:
            readyStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to ProxyDog")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DSColor.textPrimary)
            Text("Inspect the HTTP and HTTPS traffic flowing through your Mac and the apps running on it.")
                .font(DS.Typography.ui(13))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.x2)
            VStack(alignment: .leading, spacing: DS.Space.x3) {
                factRow(symbol: "lock.shield", text: "Local HTTPS interception through a root certificate")
                factRow(symbol: "internaldrive", text: "Captured traffic stays on this Mac")
                factRow(symbol: "square.and.arrow.up", text: "Copy as curl or export as HAR")
            }
            .padding(.top, DS.Space.x6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var certificateStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trust the root certificate")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DSColor.textPrimary)
            Text("ProxyDog decrypts HTTPS with a local root certificate. macOS has to trust it before encrypted traffic can be inspected.")
                .font(DS.Typography.ui(13))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.x2)

            OnboardingCard {
                HStack(spacing: DS.Space.x2) {
                    Text("Root certificate")
                        .font(DS.Typography.ui(12))
                        .foregroundStyle(DSColor.textPrimary)
                    Spacer(minLength: DS.Space.x2)
                    Circle()
                        .fill(state.isCertificateTrusted ? DSColor.accent : DSColor.textMuted)
                        .frame(width: 6, height: 6)
                    Text(certificateStatusKey)
                        .font(DS.Typography.ui(12))
                        .foregroundStyle(state.isCertificateTrusted ? DSColor.textPrimary : DSColor.textSecondary)
                    if state.isCertificateTrusted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DSColor.accent)
                    } else {
                        OnboardingIconButton(
                            systemName: "arrow.down.circle",
                            help: "Install root certificate",
                            tint: DSColor.accent
                        ) {
                            state.installCertificate()
                        }
                    }
                }
                .padding(.horizontal, DS.Space.x3)
                .padding(.vertical, DS.Space.x3)
            }
            .padding(.top, DS.Space.x5)

            Text("You can remove the certificate at any time in Settings.")
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textMuted)
                .padding(.top, DS.Space.x3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("You are all set")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DSColor.textPrimary)
            Text("Point an app or device at the address below, or route this Mac through the system proxy.")
                .font(DS.Typography.ui(13))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.x2)

            OnboardingCard {
                VStack(spacing: 0) {
                    HStack(spacing: DS.Space.x2) {
                        Text("Proxy address")
                            .font(DS.Typography.ui(12))
                            .foregroundStyle(DSColor.textPrimary)
                        Spacer(minLength: DS.Space.x2)
                        Text(verbatim: proxyAddress)
                            .font(DS.Typography.mono(12))
                            .foregroundStyle(DSColor.textPrimary)
                        OnboardingIconButton(systemName: "doc.on.doc", help: "Copy proxy address") {
                            copyProxyAddress()
                        }
                    }
                    .padding(.horizontal, DS.Space.x3)
                    .padding(.vertical, DS.Space.x2)

                    OnboardingHairline()

                    HStack(spacing: DS.Space.x2) {
                        Text("System proxy")
                            .font(DS.Typography.ui(12))
                            .foregroundStyle(DSColor.textPrimary)
                        Spacer(minLength: DS.Space.x2)
                        Toggle("", isOn: Binding(
                            get: { state.isSystemProxyEnabled },
                            set: { state.setSystemProxy(enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(DSColor.accent)
                        .disabled(!state.isProxyRunning)
                        .accessibilityLabel("Set as System Proxy")
                    }
                    .padding(.horizontal, DS.Space.x3)
                    .padding(.vertical, DS.Space.x2)
                }
            }
            .padding(.top, DS.Space.x5)

            if !state.isCertificateTrusted {
                Text("HTTPS traffic stays encrypted until the root certificate is trusted.")
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(DSColor.textMuted)
                    .padding(.top, DS.Space.x3)
            } else if !state.isProxyRunning {
                Text("The proxy starts automatically when ProxyDog launches.")
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(DSColor.textMuted)
                    .padding(.top, DS.Space.x3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func factRow(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: DS.Space.x2) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 16)
            Text(text)
                .font(DS.Typography.ui(12))
                .foregroundStyle(DSColor.textSecondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DSColor.border)
                .frame(height: 1)
            HStack(spacing: DS.Space.x3) {
                secondaryAction
                Spacer(minLength: 0)
                Button(action: primaryAction) {
                    Text(primaryTitle)
                        .font(DS.Typography.ui(12, .medium))
                        .foregroundStyle(.white)
                        .frame(minWidth: 56)
                        .padding(.horizontal, DS.Space.x4)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                .fill(DSColor.accent)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Space.x5)
            .padding(.vertical, DS.Space.x4)
        }
    }

    @ViewBuilder
    private var secondaryAction: some View {
        if step == .welcome {
            quietButton("Skip setup", action: skipSetup)
        } else if step != .ready {
            quietButton("Skip", action: advance)
        }
    }

    private func quietButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.ui(12))
                .foregroundStyle(DSColor.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .welcome, .certificate:
            return "Continue"
        case .ready:
            return "Done"
        }
    }

    // MARK: - Derived state

    private var certificateStatusKey: LocalizedStringKey {
        state.isCertificateTrusted ? "Trusted" : "Not trusted"
    }

    private var proxyAddress: String {
        "127.0.0.1:\(state.settings.port)"
    }

    // MARK: - Actions

    private func primaryAction() {
        switch step {
        case .welcome, .certificate:
            advance()
        case .ready:
            finish()
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            step = next
        }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            step = previous
        }
    }

    private func finish() {
        state.completeOnboarding()
        dismiss()
    }

    private func skipSetup() {
        state.dismissOnboarding()
        dismiss()
    }

    private func copyProxyAddress() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(proxyAddress, forType: .string)
    }
}

// MARK: - Local building blocks

private struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .fill(DSColor.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(DSColor.border, lineWidth: 1)
        )
    }
}

private struct OnboardingHairline: View {
    var body: some View {
        Rectangle()
            .fill(DSColor.border)
            .frame(height: 1)
            .padding(.leading, DS.Space.x3)
    }
}

private struct OnboardingIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var tint: Color = DSColor.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
