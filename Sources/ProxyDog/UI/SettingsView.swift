import AppKit
import SwiftUI

/// The Settings scene: one calm, sectioned preferences pane with a fixed version
/// footer. Everything that touches the proxy engine goes through `AppState`, so the
/// engine always sees the change.
///
/// Layout: grouped rows with left labels and right-aligned controls (the native
/// macOS preferences shape), quiet hairline borders, SF Pro for copy and SF Mono for
/// technical values. Version number lives at the bottom of the page.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings

    @State private var portText: String = ""
    @State private var portError: String?
    @FocusState private var portFocused: Bool

    @State private var analyticsKey: String = ""
    @State private var analyticsError: String?
    @FocusState private var analyticsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.x6) {
                    connectionSection
                    appearanceSection
                    certificateSection
                    analyticsSection
                }
                .padding(.horizontal, DS.Space.x5)
                .padding(.top, DS.Space.x5)
                .padding(.bottom, DS.Space.x6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            versionFooter
        }
        .frame(width: 560, height: 680)
        .onAppear {
            syncFromSettings()
            // Do not steal keyboard focus into the port field when the pane opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if NSApp.keyWindow?.firstResponder is NSTextView {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
        }
        .onChange(of: settings.port) { _, newValue in
            if !portFocused { portText = String(newValue) }
        }
        .onChange(of: settings.aptabaseAppKey) { _, newValue in
            if !analyticsFocused { analyticsKey = newValue }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        SettingsSection(title: "Connection") {
            SettingsRow(
                title: "Proxy port",
                hint: portError ?? "Changing the port restarts the proxy when it is running.",
                hintTint: portError == nil ? nil : DSColor.red
            ) {
                HStack(spacing: DS.Space.x2) {
                    TextField("8888", text: $portText)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.mono(13))
                        .foregroundStyle(DSColor.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .focused($portFocused)
                        .frame(width: 56)
                        .padding(.horizontal, DS.Space.x2)
                        .padding(.vertical, 5)
                        .background(fieldBackground(isFocused: portFocused))
                        .onSubmit(commitPort)
                        .onChange(of: portText) { _, newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(5))
                            if filtered != newValue { portText = filtered }
                            if portError != nil { portError = nil }
                        }
                        .onChange(of: portFocused) { _, focused in
                            if !focused { commitPort() }
                        }
                    SettingsIconButton(
                        systemName: "arrow.clockwise",
                        help: "Restart proxy",
                        action: { state.restartProxy() }
                    )
                }
            }
            SettingsHairline()
            SettingsRow(
                title: "SSL proxying",
                hint: "Decrypts HTTPS traffic with the ProxyDog root certificate."
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.sslProxyingEnabled },
                    set: { newValue in
                        settings.sslProxyingEnabled = newValue
                        if state.isProxyRunning { state.restartProxy() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DSColor.accent)
                .accessibilityLabel("SSL proxying")
            }
            SettingsHairline()
            SettingsRow(
                title: "System proxy",
                hint: state.isProxyRunning
                    ? "Routes this Mac's HTTP and HTTPS traffic through ProxyDog."
                    : "Start the proxy to change this."
            ) {
                Toggle("", isOn: Binding(
                    get: { state.isSystemProxyEnabled },
                    set: { state.setSystemProxy(enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DSColor.accent)
                .disabled(!state.isProxyRunning)
                .accessibilityLabel("Set as system proxy")
            }
            SettingsHairline()
            SettingsRow(title: "Proxy status", hint: proxyStatusHint) {
                HStack(spacing: DS.Space.x2) {
                    Circle()
                        .fill(proxyStatusColor)
                        .frame(width: 6, height: 6)
                    Text(proxyStatusText)
                        .font(DS.Typography.mono(12))
                        .foregroundStyle(state.proxyStatus.isRunning ? DSColor.textPrimary : DSColor.textSecondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            SettingsRow(
                title: "Theme",
                hint: "Follows the system appearance by default."
            ) {
                Picker("", selection: Binding(
                    get: { settings.appearance },
                    set: { settings.appearance = $0 }
                )) {
                    ForEach(AppSettings.Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(DSColor.accent)
                .frame(width: 250)
                .accessibilityLabel("Theme")
            }
        }
    }

    // MARK: - Certificate

    private var certificateSection: some View {
        SettingsSection(title: "Certificate") {
            SettingsRow(
                title: "Root certificate",
                hint: "Required to inspect HTTPS. Stored in your login keychain."
            ) {
                HStack(spacing: DS.Space.x3) {
                    HStack(spacing: DS.Space.x2) {
                        Circle()
                            .fill(state.isCertificateTrusted ? DSColor.accent : DSColor.textMuted)
                            .frame(width: 6, height: 6)
                        Text(state.isCertificateTrusted ? "Trusted" : "Not trusted")
                            .font(DS.Typography.ui(12))
                            .foregroundStyle(state.isCertificateTrusted ? DSColor.textPrimary : DSColor.textSecondary)
                    }
                    HStack(spacing: 2) {
                        if state.isCertificateTrusted {
                            SettingsIconButton(
                                systemName: "trash",
                                help: "Remove certificate trust",
                                action: { state.removeCertificate() }
                            )
                        } else {
                            SettingsIconButton(
                                systemName: "arrow.down.circle",
                                help: "Install root certificate",
                                tint: DSColor.accent,
                                action: { state.installCertificate() }
                            )
                        }
                        SettingsIconButton(
                            systemName: "square.and.arrow.up",
                            help: "Export root certificate",
                            action: { state.presentCertificateExportPanel() }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Analytics

    private var analyticsSection: some View {
        SettingsSection(title: "Analytics") {
            SettingsRow(
                title: "Aptabase app key",
                hint: analyticsError ?? "Optional. Anonymous usage events only; leave empty to disable.",
                hintTint: analyticsError == nil ? nil : DSColor.red
            ) {
                TextField("A-US-XXXXXXXX", text: $analyticsKey)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.mono(12))
                    .foregroundStyle(DSColor.textPrimary)
                    .focused($analyticsFocused)
                    .frame(width: 170)
                    .padding(.horizontal, DS.Space.x2)
                    .padding(.vertical, 5)
                    .background(fieldBackground(isFocused: analyticsFocused))
                    .onSubmit(commitAnalyticsKey)
                    .onChange(of: analyticsFocused) { _, focused in
                        if !focused { commitAnalyticsKey() }
                    }
                    .onChange(of: analyticsKey) { _, _ in
                        if analyticsError != nil { analyticsError = nil }
                    }
            }
        }
    }

    // MARK: - Footer

    private var versionFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DSColor.border)
                .frame(height: 1)
            Text("\(AppInfo.name) \(AppInfo.versionLabel)")
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.x3)
        }
    }

    // MARK: - Derived state

    private var proxyStatusText: String {
        switch state.proxyStatus {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running(let port):
            return "Running on 127.0.0.1:\(port)"
        case .failed:
            return "Failed"
        }
    }

    private var proxyStatusHint: String {
        switch state.proxyStatus {
        case .failed(let message):
            return message
        default:
            return "Listens on the loopback interface only."
        }
    }

    private var proxyStatusColor: Color {
        switch state.proxyStatus {
        case .running:
            return DSColor.accent
        case .starting:
            return DSColor.amber
        case .failed:
            return DSColor.red
        case .stopped:
            return DSColor.textMuted
        }
    }

    // MARK: - Actions

    private func syncFromSettings() {
        portText = String(settings.port)
        analyticsKey = settings.aptabaseAppKey
        portError = nil
        analyticsError = nil
        state.refreshCertificateStatus()
        state.refreshSystemProxyState()
    }

    private func commitPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed), (1...65535).contains(port) else {
            portText = String(settings.port)
            portError = "Enter a port between 1 and 65535."
            return
        }
        portError = nil
        portText = String(port)
        if port != settings.port {
            state.applyPort(port)
        }
    }

    private func commitAnalyticsKey() {
        let trimmed = analyticsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        analyticsKey = trimmed
        if trimmed != settings.aptabaseAppKey {
            settings.aptabaseAppKey = trimmed
            Analytics.shared.configure(appKey: trimmed)
        }
        if trimmed.isEmpty || looksLikeAppKey(trimmed) {
            analyticsError = nil
        } else {
            analyticsError = "Keys look like A-US-… or A-EU-…."
        }
    }

    private func looksLikeAppKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-")
        guard parts.count >= 2, parts[0].uppercased() == "A" else { return false }
        let region = parts[1].uppercased()
        return region == "US" || region == "EU"
    }

    private func fieldBackground(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
            .fill(DSColor.sunken)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .strokeBorder(isFocused ? DSColor.accent : DSColor.border, lineWidth: 1)
            )
    }
}

// MARK: - Local building blocks

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text(title)
                .font(DS.Typography.ui(11, .semibold))
                .foregroundStyle(DSColor.textSecondary)
                .padding(.leading, DS.Space.x3)
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
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let hint: String?
    let hintTint: Color?
    @ViewBuilder let control: () -> Control

    init(
        title: String,
        hint: String? = nil,
        hintTint: Color? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.hint = hint
        self.hintTint = hintTint
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.x4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typography.ui(13))
                    .foregroundStyle(DSColor.textPrimary)
                if let hint {
                    Text(hint)
                        .font(DS.Typography.ui(11))
                        .foregroundStyle(hintTint ?? DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.x2)
            control()
        }
        .padding(.horizontal, DS.Space.x4)
        .padding(.vertical, DS.Space.x3)
        .frame(minHeight: 44)
    }
}

private struct SettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(DSColor.border)
            .frame(height: 1)
            .padding(.leading, DS.Space.x4)
    }
}

private struct SettingsIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = DSColor.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
