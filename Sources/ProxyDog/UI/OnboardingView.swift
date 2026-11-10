import AppKit
import SwiftUI

/// First-run onboarding: a single composed page that shows the welcome highlights,
/// the root-certificate setup and the ready-to-use details at once. Closing the sheet
/// marks onboarding as dismissed, the primary button completes the setup.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            chrome
            VStack(alignment: .leading, spacing: 0) {
                Text("Welcome to ProxyDog")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DSColor.textPrimary)

                VStack(alignment: .leading, spacing: DS.Space.x3) {
                    factRow(symbol: "lock.shield", text: "Local HTTPS interception through a root certificate")
                    factRow(symbol: "internaldrive", text: "Captured traffic stays on this Mac")
                    factRow(symbol: "square.and.arrow.up", text: "Copy as curl or export as HAR")
                }
                .padding(.top, DS.Space.x4)

            sectionDivider
            certificateBlock
            sectionDivider
            readyBlock
        }
        .padding(.horizontal, DS.Space.x6)
        .padding(.top, DS.Space.x3)
        .padding(.bottom, DS.Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)

        footer
        }
        .frame(width: 560)
        .background(DSColor.chrome)
        .onAppear {
            state.refreshCertificateStatus()
            state.refreshSystemProxyState()
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack {
            Spacer(minLength: 0)
            OnboardingIconButton(systemName: "xmark", help: "Close setup") {
                skipSetup()
            }
        }
        .padding(.horizontal, DS.Space.x5)
        .padding(.top, DS.Space.x4)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(DSColor.border)
            .frame(height: 1)
            .padding(.vertical, DS.Space.x4)
    }

    // MARK: - Certificate

    private var certificateBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trust the root certificate")
                .font(DS.Typography.ui(13, .semibold))
                .foregroundStyle(DSColor.textPrimary)
            Text("ProxyDog decrypts HTTPS with a local root certificate. macOS has to trust it before encrypted traffic can be inspected.")
                .font(DS.Typography.ui(12))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.x1)

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
                        OnboardingIconButton(systemName: "arrow.clockwise", help: "Refresh certificate") {
                            state.refreshCertificateStatus()
                        }
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
            .padding(.top, DS.Space.x3)

            Text("You can remove the certificate at any time in Settings.")
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textMuted)
                .padding(.top, DS.Space.x2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ready to use

    private var readyBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Get started")
                .font(DS.Typography.ui(13, .semibold))
                .foregroundStyle(DSColor.textPrimary)

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
                    .padding(.vertical, DS.Space.x3)

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
            .padding(.top, DS.Space.x3)

            if !state.isCertificateTrusted {
                Text("HTTPS traffic stays encrypted until the root certificate is trusted.")
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(DSColor.textMuted)
                    .padding(.top, DS.Space.x2)
            } else if !state.isProxyRunning {
                Text("The proxy starts automatically when ProxyDog launches.")
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(DSColor.textMuted)
                    .padding(.top, DS.Space.x2)
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
                Spacer(minLength: 0)
                Button(action: finish) {
                    Text("Done")
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


    // MARK: - Derived state

    private var certificateStatusKey: LocalizedStringKey {
        state.isCertificateTrusted ? "Trusted" : "Not trusted"
    }

    private var proxyAddress: String {
        "127.0.0.1:\(state.settings.port)"
    }

    // MARK: - Actions

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
