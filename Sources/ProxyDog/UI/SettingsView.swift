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

    @State private var upstreamKind: UpstreamProxyKind = .httpConnect
    @State private var upstreamHostText: String = ""
    @State private var upstreamPortText: String = ""
    @State private var upstreamError: String?
    /// Placeholders come from the detected system proxy, so the row shows the address the
    /// app would use instead of a made-up default.
    @State private var detectedUpstreamHost: String = "127.0.0.1"
    @State private var detectedUpstreamPort: String = "8080"
    @FocusState private var upstreamHostFocused: Bool
    @FocusState private var upstreamPortFocused: Bool

    @State private var socksPortText: String = ""
    @State private var socksError: String?
    @FocusState private var socksPortFocused: Bool

    @State private var language: AppLanguage = AppLanguage.stored

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.x6) {
                    connectionSection
                    appearanceSection
                    certificateSection
                }
                .padding(.horizontal, DS.Space.x5)
                .padding(.top, DS.Space.x5)
                .padding(.bottom, DS.Space.x6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            versionFooter
        }
        .frame(width: 560, height: 880)
        .onAppear {
            // Fill the upstream address from whatever proxy is already running so the user
            // never has to type it by hand.
            state.autoFillUpstreamProxyIfEmpty()
            refreshDetectedUpstream()
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
        .onChange(of: settings.upstreamProxyHost) { _, newValue in
            if !upstreamHostFocused { upstreamHostText = newValue }
        }
        .onChange(of: settings.upstreamProxyPort) { _, newValue in
            if !upstreamPortFocused {
                upstreamPortText = newValue > 0 ? String(newValue) : ""
            }
        }
        .onChange(of: settings.upstreamProxyKind) { _, newValue in
            if upstreamKind != newValue { upstreamKind = newValue }
        }
        .onChange(of: settings.socksProxyPort) { _, newValue in
            if !socksPortFocused { socksPortText = String(newValue) }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        SettingsSection(title: "Connection") {
            SettingsRow(
                title: "Proxy port",
                hint: "Changing the port restarts the proxy when it is running.",
                errorText: portError
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
                .accessibilityLabel("Set as System Proxy")
            }
            SettingsHairline()
            SettingsRow(
                title: "Upstream proxy",
                hint: "Sends outbound traffic through an existing HTTP proxy such as a VPN client. ProxyDog still captures and decrypts."
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.upstreamProxyEnabled },
                    set: { setUpstreamEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DSColor.accent)
                .accessibilityLabel("Upstream proxy")
            }
            SettingsHairline()
            SettingsRow(
                title: "Upstream address",
                errorText: upstreamError
            ) {
                HStack(spacing: DS.Space.x2) {
                    Picker("", selection: $upstreamKind) {
                        ForEach(UpstreamProxyKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 84)
                    .onChange(of: upstreamKind) { _, newValue in
                        applyUpstreamKindChange(newValue)
                    }
                    TextField(detectedUpstreamHost, text: $upstreamHostText)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.mono(12))
                        .foregroundStyle(DSColor.textPrimary)
                        .focused($upstreamHostFocused)
                        .frame(width: 104)
                        .padding(.horizontal, DS.Space.x2)
                        .padding(.vertical, 5)
                        .background(fieldBackground(isFocused: upstreamHostFocused))
                        .onSubmit(commitUpstreamAddress)
                        .onChange(of: upstreamHostFocused) { _, focused in
                            if !focused { commitUpstreamAddress() }
                        }
                        .disabled(!upstreamAddressAvailable)
                    TextField(detectedUpstreamPort, text: $upstreamPortText)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.mono(12))
                        .foregroundStyle(DSColor.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .focused($upstreamPortFocused)
                        .frame(width: 56)
                        .padding(.horizontal, DS.Space.x2)
                        .padding(.vertical, 5)
                        .background(fieldBackground(isFocused: upstreamPortFocused))
                        .onSubmit(commitUpstreamAddress)
                        .onChange(of: upstreamPortText) { _, newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(5))
                            if filtered != newValue { upstreamPortText = filtered }
                        }
                        .onChange(of: upstreamPortFocused) { _, focused in
                            if !focused { commitUpstreamAddress() }
                        }
                        .disabled(!upstreamAddressAvailable)
                    SettingsIconButton(
                        systemName: "arrow.down.to.line",
                        help: "Fill from system proxy",
                        action: fillUpstreamFromSystem
                    )
                    .disabled(!upstreamAddressAvailable)
                }
            }
            SettingsHairline()
            SettingsRow(
                title: "SOCKS5 proxy",
                hint: "For apps that only speak SOCKS5, e.g. Telegram. ProxyDog captures and decrypts the traffic the same way."
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.socksProxyEnabled },
                    set: { setSocksEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DSColor.accent)
                .accessibilityLabel("SOCKS5 proxy")
            }
            SettingsHairline()
            SettingsRow(
                title: "SOCKS5 port",
                errorText: socksError
            ) {
                TextField("8889", text: $socksPortText)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.mono(12))
                    .foregroundStyle(DSColor.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .focused($socksPortFocused)
                    .frame(width: 56)
                    .padding(.horizontal, DS.Space.x2)
                    .padding(.vertical, 5)
                    .background(fieldBackground(isFocused: socksPortFocused))
                    .onSubmit(commitSocksPort)
                    .onChange(of: socksPortText) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(5))
                        if filtered != newValue { socksPortText = filtered }
                    }
                    .onChange(of: socksPortFocused) { _, focused in
                        if !focused { commitSocksPort() }
                    }
                    .disabled(!socksAddressAvailable)
            }
            SettingsHairline()
            SettingsRow(
                title: "Proxy status",
                hint: "Listens on the loopback interface only.",
                hintText: proxyFailureMessage
            ) {
                HStack(spacing: DS.Space.x2) {
                    Circle()
                        .fill(proxyStatusColor)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(proxyStatusText)
                            .font(DS.Typography.mono(12))
                            .foregroundStyle(state.proxyStatus.isRunning ? DSColor.textPrimary : DSColor.textSecondary)
                            .monospacedDigit()
                        if let socksPort = state.socksProxyFromSettings() {
                            Text(verbatim: "SOCKS5 127.0.0.1:\(socksPort)")
                                .font(DS.Typography.mono(11))
                                .foregroundStyle(DSColor.textSecondary)
                                .monospacedDigit()
                        }
                    }
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
            SettingsHairline()
            SettingsRow(
                title: "Language",
                hint: "The app restarts to apply the language change."
            ) {
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
                .accessibilityLabel("Language")
                .onChange(of: language) { _, newValue in
                    AppLanguage.apply(newValue)
                }
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
                        Text(certificateStatusKey)
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

    // MARK: - Footer

    private var versionFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DSColor.border)
                .frame(height: 1)
            Text(verbatim: "\(AppInfo.name) \(AppInfo.versionLabel)")
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.x3)
        }
    }

    // MARK: - Derived state

    private var certificateStatusKey: LocalizedStringKey {
        state.isCertificateTrusted ? "Trusted" : "Not trusted"
    }

    private var proxyStatusText: String {
        switch state.proxyStatus {
        case .stopped:
            return String(localized: "Stopped")
        case .starting:
            return String(localized: "Starting")
        case .running(let port):
            return String(format: String(localized: "Running on %@"), "127.0.0.1:\(port)")
        case .failed:
            return String(localized: "Failed")
        }
    }

    private var proxyFailureMessage: String? {
        if case .failed(let message) = state.proxyStatus {
            return message
        }
        return nil
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

    /// Keeps the placeholder in sync with the proxy that is currently running on this Mac.
    private func refreshDetectedUpstream() {
        guard let detected = state.detectSystemUpstreamProxy() else { return }
        detectedUpstreamHost = detected.host
        detectedUpstreamPort = String(detected.port)
    }

    private func syncFromSettings() {
        portText = String(settings.port)
        portError = nil
        upstreamKind = settings.upstreamProxyKind
        upstreamHostText = settings.upstreamProxyHost
        upstreamPortText = settings.upstreamProxyPort > 0 ? String(settings.upstreamProxyPort) : ""
        upstreamError = nil
        socksPortText = String(settings.socksProxyPort)
        socksError = nil
        language = AppLanguage.stored
        state.refreshCertificateStatus()
        state.refreshSystemProxyState()
    }

    private func commitPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed), (1...65535).contains(port) else {
            portText = String(settings.port)
            portError = String(localized: "Port must be between 1 and 65535.")
            return
        }
        portError = nil
        portText = String(port)
        if port != settings.port {
            state.applyPort(port)
        }
    }

    // MARK: - Upstream proxy

    /// The address row is editable while upstream proxying is on, and also while a
    /// validation error is on screen so the user can correct an invalid configuration.
    private var upstreamAddressAvailable: Bool {
        settings.upstreamProxyEnabled || upstreamError != nil
    }

    private var parsedUpstreamPort: Int {
        Int(upstreamPortText.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func setUpstreamEnabled(_ enabled: Bool) {
        upstreamHostFocused = false
        upstreamPortFocused = false

        if enabled {
            if let error = state.applyUpstreamProxy(
                enabled: true,
                host: upstreamHostText,
                port: parsedUpstreamPort,
                kind: upstreamKind
            ) {
                // Nothing is applied on failure, so the switch falls back to off.
                upstreamError = error
                return
            }
            upstreamError = nil
            syncUpstreamText()
        } else {
            _ = state.applyUpstreamProxy(
                enabled: false,
                host: upstreamHostText,
                port: parsedUpstreamPort,
                kind: upstreamKind
            )
            upstreamError = nil
            syncUpstreamText()
        }
    }

    private func applyUpstreamKindChange(_ kind: UpstreamProxyKind) {
        let port = parsedUpstreamPort
        if let error = state.applyUpstreamProxy(
            enabled: settings.upstreamProxyEnabled,
            host: upstreamHostText,
            port: port,
            kind: kind
        ) {
            upstreamError = error
            upstreamKind = settings.upstreamProxyKind
            if settings.upstreamProxyEnabled {
                _ = state.applyUpstreamProxy(enabled: false, host: upstreamHostText, port: port, kind: kind)
            }
            return
        }
        upstreamError = nil
        syncUpstreamText()
    }

    private func commitUpstreamAddress() {
        guard upstreamAddressAvailable else { return }
        let port = parsedUpstreamPort
        if let error = state.applyUpstreamProxy(
            enabled: true,
            host: upstreamHostText,
            port: port,
            kind: upstreamKind
        ) {
            upstreamError = error
            if settings.upstreamProxyEnabled {
                // Never leave an invalid configuration switched on.
                _ = state.applyUpstreamProxy(enabled: false, host: upstreamHostText, port: port, kind: upstreamKind)
            }
            return
        }
        upstreamError = nil
        syncUpstreamText()
    }

    private func fillUpstreamFromSystem() {
        upstreamHostFocused = false
        upstreamPortFocused = false
        guard state.detectUpstreamProxyFromSystem() else { return }

        upstreamKind = state.settings.upstreamProxyKind
        upstreamHostText = state.settings.upstreamProxyHost
        upstreamPortText = state.settings.upstreamProxyPort > 0 ? String(state.settings.upstreamProxyPort) : ""

        guard upstreamAddressAvailable else { return }
        if let error = state.applyUpstreamProxy(
            enabled: true,
            host: upstreamHostText,
            port: state.settings.upstreamProxyPort,
            kind: upstreamKind
        ) {
            upstreamError = error
            // Keep the pane consistent: an invalid detected address never stays enabled.
            _ = state.applyUpstreamProxy(enabled: false, host: upstreamHostText, port: state.settings.upstreamProxyPort, kind: upstreamKind)
        } else {
            upstreamError = nil
            syncUpstreamText()
        }
    }

    private func syncUpstreamText() {
        upstreamKind = settings.upstreamProxyKind
        upstreamHostText = settings.upstreamProxyHost
        if settings.upstreamProxyPort > 0 {
            upstreamPortText = String(settings.upstreamProxyPort)
        }
    }

    // MARK: - SOCKS5 listener

    private var socksAddressAvailable: Bool {
        settings.socksProxyEnabled || socksError != nil
    }

    private var parsedSocksPort: Int {
        Int(socksPortText.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func setSocksEnabled(_ enabled: Bool) {
        socksPortFocused = false
        if let error = state.applySocksProxy(enabled: enabled, port: parsedSocksPort) {
            socksError = error
            return
        }
        socksError = nil
        syncSocksText()
    }

    private func commitSocksPort() {
        guard socksAddressAvailable else { return }
        let port = parsedSocksPort
        if let error = state.applySocksProxy(enabled: true, port: port) {
            socksError = error
            if settings.socksProxyEnabled {
                // Never leave an invalid configuration switched on.
                _ = state.applySocksProxy(enabled: false, port: port)
            }
            return
        }
        socksError = nil
        syncSocksText()
    }

    private func syncSocksText() {
        socksPortText = String(settings.socksProxyPort)
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
    let title: LocalizedStringKey
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
    let title: LocalizedStringKey
    let hint: LocalizedStringKey?
    let hintText: String?
    let errorText: String?
    @ViewBuilder let control: () -> Control

    init(
        title: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        hintText: String? = nil,
        errorText: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.hint = hint
        self.hintText = hintText
        self.errorText = errorText
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.x4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typography.ui(13))
                    .foregroundStyle(DSColor.textPrimary)
                if let errorText {
                    Text(verbatim: errorText)
                        .font(DS.Typography.ui(11))
                        .foregroundStyle(DSColor.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let hintText {
                    Text(verbatim: hintText)
                        .font(DS.Typography.ui(11))
                        .foregroundStyle(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let hint {
                    Text(hint)
                        .font(DS.Typography.ui(11))
                        .foregroundStyle(DSColor.textSecondary)
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
    let help: LocalizedStringKey
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
