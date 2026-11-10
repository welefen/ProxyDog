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

    @State private var upstreamHTTPHostText: String = ""
    @State private var upstreamHTTPPortText: String = ""
    @State private var upstreamSOCKSHostText: String = ""
    @State private var upstreamSOCKSPortText: String = ""
    @State private var upstreamError: String?
    /// Placeholders come from the detected system proxy, so the HTTP row shows the address
    /// the app would use instead of a made-up default.
    @State private var detectedUpstreamHost: String = "127.0.0.1"
    @State private var detectedUpstreamPort: String = "8080"
    @FocusState private var upstreamHTTPHostFocused: Bool
    @FocusState private var upstreamHTTPPortFocused: Bool
    @FocusState private var upstreamSOCKSHostFocused: Bool
    @FocusState private var upstreamSOCKSPortFocused: Bool

    @State private var socksPortText: String = ""
    @State private var socksError: String?
    @FocusState private var socksPortFocused: Bool

    @State private var language: AppLanguage = AppLanguage.stored
    @State private var selectedTab: SettingsTab = .connection

    /// Left-hand navigation categories of the settings window.
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case connection
        case rules
        case appearance
        case certificates

        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .connection: return "Connection"
            case .rules: return "Rules"
            case .appearance: return "Appearance"
            case .certificates: return "Certificate"
            }
        }

        var symbol: String {
            switch self {
            case .connection: return "network"
            case .rules: return "slider.horizontal.3"
            case .appearance: return "circle.lefthalf.filled"
            case .certificates: return "checkmark.shield"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            PDHairline(vertical: true)
            ScrollView {
                Group {
                    switch selectedTab {
                    case .connection:
                        connectionSection
                    case .rules:
                        VStack(alignment: .leading, spacing: DS.Space.x6) {
                            rewriteSection
                            breakpointSection
                        }
                    case .appearance:
                        appearanceSection
                    case .certificates:
                        certificateSection
                    }
                }
                .padding(.horizontal, DS.Space.x5)
                .padding(.top, DS.Space.x5)
                .padding(.bottom, DS.Space.x6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 620)
        .onAppear {
            // The settings scene restores its previous frame, which can be narrower than the
            // sidebar + content split; pin the size when the pane appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let target = NSApp.windows.first { window in
                    window.isVisible && (window.title.contains("设置") || window.title.localizedCaseInsensitiveContains("settings"))
                }
                target?.styleMask.remove(.resizable)
                target?.setContentSize(NSSize(width: 760, height: 620))
            }
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
        .onChange(of: settings.upstreamHTTPHost) { _, newValue in
            if !upstreamHTTPHostFocused { upstreamHTTPHostText = newValue }
        }
        .onChange(of: settings.upstreamHTTPPort) { _, newValue in
            if !upstreamHTTPPortFocused {
                upstreamHTTPPortText = newValue > 0 ? String(newValue) : ""
            }
        }
        .onChange(of: settings.upstreamSOCKSHost) { _, newValue in
            if !upstreamSOCKSHostFocused { upstreamSOCKSHostText = newValue }
        }
        .onChange(of: settings.upstreamSOCKSPort) { _, newValue in
            if !upstreamSOCKSPortFocused {
                upstreamSOCKSPortText = newValue > 0 ? String(newValue) : ""
            }
        }
        .onChange(of: settings.socksProxyPort) { _, newValue in
            if !socksPortFocused { socksPortText = String(newValue) }
        }
    }

    // MARK: - Connection

    // MARK: - Tabs

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                sidebarRow(tab)
            }
            Spacer(minLength: 0)
            versionFooter
        }
        .padding(.horizontal, DS.Space.x2)
        .padding(.top, DS.Space.x3)
        .padding(.bottom, DS.Space.x2)
        .frame(width: 196)
        .background(DSColor.chrome)
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: DS.Space.x2 + 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? DSColor.textSecondary : DSColor.textMuted)
                    .frame(width: 16)
                Text(tab.label)
                    .font(DS.Typography.ui(12, isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? DSColor.textPrimary : DSColor.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.x2)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(isSelected ? DSColor.selection : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.x6) {
            SettingsSection(title: "HTTP / HTTPS") {
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
                            help: String(localized: "Restart proxy"),
                            action: { state.restartProxy() }
                        )
                    }
                }
                SettingsHairline()
                SettingsRow(
                    title: "SSL proxying",
                    hint: "Decrypts HTTPS traffic with the ProxyDog root certificate, for both the HTTP and SOCKS5 listeners."
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
                    title: "Ignore own requests",
                    hint: "Keeps ProxyDog's own analytics and update traffic out of the request list."
                ) {
                    Toggle("", isOn: Binding(
                        get: { settings.ignoreOwnTraffic },
                        set: { settings.ignoreOwnTraffic = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSColor.accent)
                    .accessibilityLabel("Ignore own requests")
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
                    title: "Upstream protocol",
                    hint: "Both addresses are stored; the selected protocol is used."
                ) {
                    PDSegmented(
                        items: UpstreamProxyKind.allCases.map { kind in
                            PDSegmented<UpstreamProxyKind>.Item(value: kind, label: kind.label)
                        },
                        selection: Binding(
                            get: { settings.upstreamProxyKind },
                            set: { applyUpstreamKindChange($0) }
                        )
                    )
                    .disabled(!settings.upstreamProxyEnabled)
                }
                SettingsHairline()
                SettingsRow(
                    title: "HTTP upstream",
                    errorText: settings.upstreamProxyKind == .httpConnect ? upstreamError : nil
                ) {
                    HStack(spacing: DS.Space.x2) {
                        TextField(detectedUpstreamHost, text: $upstreamHTTPHostText)
                            .textFieldStyle(.plain)
                            .font(DS.Typography.mono(12))
                            .foregroundStyle(DSColor.textPrimary)
                            .focused($upstreamHTTPHostFocused)
                            .frame(width: 112)
                            .padding(.horizontal, DS.Space.x2)
                            .padding(.vertical, 5)
                            .background(fieldBackground(isFocused: upstreamHTTPHostFocused, isEnabled: settings.upstreamProxyEnabled))
                            .onSubmit { commitUpstreamAddress(.httpConnect) }
                            .onChange(of: upstreamHTTPHostFocused) { _, focused in
                                if !focused { commitUpstreamAddress(.httpConnect) }
                            }
                            .disabled(!settings.upstreamProxyEnabled)
                        TextField(detectedUpstreamPort, text: $upstreamHTTPPortText)
                            .textFieldStyle(.plain)
                            .font(DS.Typography.mono(12))
                            .foregroundStyle(DSColor.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .focused($upstreamHTTPPortFocused)
                            .frame(width: 56)
                            .padding(.horizontal, DS.Space.x2)
                            .padding(.vertical, 5)
                            .background(fieldBackground(isFocused: upstreamHTTPPortFocused, isEnabled: settings.upstreamProxyEnabled))
                            .onSubmit { commitUpstreamAddress(.httpConnect) }
                            .onChange(of: upstreamHTTPPortText) { _, newValue in
                                let filtered = String(newValue.filter(\.isNumber).prefix(5))
                                if filtered != newValue { upstreamHTTPPortText = filtered }
                            }
                            .onChange(of: upstreamHTTPPortFocused) { _, focused in
                                if !focused { commitUpstreamAddress(.httpConnect) }
                            }
                            .disabled(!settings.upstreamProxyEnabled)
                        SettingsIconButton(
                            systemName: "arrow.down.to.line",
                            help: String(localized: "Fill from system proxy"),
                            action: fillUpstreamFromSystem
                        )
                        .disabled(!settings.upstreamProxyEnabled)
                    }
                }
            }
            SettingsSection(title: "SOCKS5") {
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
                        .background(fieldBackground(isFocused: socksPortFocused, isEnabled: socksAddressAvailable))
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
                    title: "SOCKS5 upstream",
                    errorText: settings.upstreamProxyKind == .socks5 ? upstreamError : nil
                ) {
                    HStack(spacing: DS.Space.x2) {
                        TextField("127.0.0.1", text: $upstreamSOCKSHostText)
                            .textFieldStyle(.plain)
                            .font(DS.Typography.mono(12))
                            .foregroundStyle(DSColor.textPrimary)
                            .focused($upstreamSOCKSHostFocused)
                            .frame(width: 112)
                            .padding(.horizontal, DS.Space.x2)
                            .padding(.vertical, 5)
                            .background(fieldBackground(isFocused: upstreamSOCKSHostFocused, isEnabled: settings.upstreamProxyEnabled))
                            .onSubmit { commitUpstreamAddress(.socks5) }
                            .onChange(of: upstreamSOCKSHostFocused) { _, focused in
                                if !focused { commitUpstreamAddress(.socks5) }
                            }
                            .disabled(!settings.upstreamProxyEnabled)
                        TextField("1080", text: $upstreamSOCKSPortText)
                            .textFieldStyle(.plain)
                            .font(DS.Typography.mono(12))
                            .foregroundStyle(DSColor.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .focused($upstreamSOCKSPortFocused)
                            .frame(width: 56)
                            .padding(.horizontal, DS.Space.x2)
                            .padding(.vertical, 5)
                            .background(fieldBackground(isFocused: upstreamSOCKSPortFocused, isEnabled: settings.upstreamProxyEnabled))
                            .onSubmit { commitUpstreamAddress(.socks5) }
                            .onChange(of: upstreamSOCKSPortText) { _, newValue in
                                let filtered = String(newValue.filter(\.isNumber).prefix(5))
                                if filtered != newValue { upstreamSOCKSPortText = filtered }
                            }
                            .onChange(of: upstreamSOCKSPortFocused) { _, focused in
                                if !focused { commitUpstreamAddress(.socks5) }
                            }
                            .disabled(!settings.upstreamProxyEnabled)
                    }
                }
            }
            SettingsSection(title: "Status") {
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
    }
    // MARK: - Rewrite

    private var rewriteSection: some View {
        SettingsSection(title: "Rewrite rules") {
            RewriteRulesSectionView(store: state.rewriteRules)
        }
    }

    // MARK: - Breakpoints

    private var breakpointSection: some View {
        SettingsSection(title: "Breakpoints") {
            BreakpointsSectionView(store: state.breakpoints)
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            SettingsRow(
                title: "Theme",
                hint: "Follows the system appearance by default."
            ) {
                PDSegmented(
                    items: AppSettings.Appearance.allCases.map {
                        .init(value: $0, label: $0.label)
                    },
                    selection: Binding(
                        get: { settings.appearance },
                        set: { settings.appearance = $0 }
                    )
                )
                .accessibilityLabel("Theme")
            }
            SettingsHairline()
            SettingsRow(
                title: "Language",
                hint: "The app restarts to apply the language change."
            ) {
                PDSegmented(
                    items: AppLanguage.allCases.map {
                        .init(value: $0, label: $0.displayName)
                    },
                    selection: $language
                )
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
                                help: String(localized: "Remove certificate trust"),
                                action: { state.removeCertificate() }
                            )
                        } else {
                            SettingsIconButton(
                                systemName: "arrow.down.circle",
                                help: String(localized: "Install root certificate"),
                                tint: DSColor.accent,
                                action: { state.installCertificate() }
                            )
                        }
                        SettingsIconButton(
                            systemName: "square.and.arrow.up",
                            help: String(localized: "Export root certificate"),
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
        syncUpstreamFields()
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

    private func hostText(for kind: UpstreamProxyKind) -> String {
        kind == .httpConnect ? upstreamHTTPHostText : upstreamSOCKSHostText
    }

    private func parsedPort(for kind: UpstreamProxyKind) -> Int {
        let text = kind == .httpConnect ? upstreamHTTPPortText : upstreamSOCKSPortText
        return Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func setUpstreamEnabled(_ enabled: Bool) {
        upstreamHTTPHostFocused = false
        upstreamHTTPPortFocused = false
        upstreamSOCKSHostFocused = false
        upstreamSOCKSPortFocused = false
        let kind = settings.upstreamProxyKind
        if let error = state.applyUpstreamProxy(
            enabled: enabled,
            host: settings.upstreamHost(for: kind),
            port: settings.upstreamPort(for: kind),
            kind: kind
        ) {
            // Nothing is applied on failure, so the switch falls back to off.
            upstreamError = error
            return
        }
        upstreamError = nil
        syncUpstreamFields()
    }

    private func applyUpstreamKindChange(_ kind: UpstreamProxyKind) {
        guard kind != settings.upstreamProxyKind else { return }
        if let error = state.applyUpstreamProxy(
            enabled: settings.upstreamProxyEnabled,
            host: settings.upstreamHost(for: kind),
            port: settings.upstreamPort(for: kind),
            kind: kind
        ) {
            // Nothing is applied on failure; the segmented control falls back to the
            // protocol that is still selected in settings.
            upstreamError = error
            return
        }
        upstreamError = nil
        syncUpstreamFields()
    }

    private func commitUpstreamAddress(_ kind: UpstreamProxyKind) {
        guard settings.upstreamProxyEnabled else { return }
        let host = hostText(for: kind)
        let port = parsedPort(for: kind)
        if settings.upstreamProxyKind == kind {
            if let error = state.applyUpstreamProxy(enabled: true, host: host, port: port, kind: kind) {
                upstreamError = error
                syncUpstreamFields(for: kind)
                return
            }
            upstreamError = nil
            syncUpstreamFields(for: kind)
        } else {
            // Pre-fill the address of the protocol that is not in use yet.
            settings.setUpstreamAddress(host: host, port: port, kind: kind)
            upstreamError = nil
            syncUpstreamFields(for: kind)
        }
    }

    private func fillUpstreamFromSystem() {
        upstreamHTTPHostFocused = false
        upstreamHTTPPortFocused = false
        guard state.detectUpstreamProxyFromSystem() else { return }
        refreshDetectedUpstream()
        syncUpstreamFields()

        guard settings.upstreamProxyEnabled else { return }
        let host = settings.upstreamHost(for: .httpConnect)
        let port = settings.upstreamPort(for: .httpConnect)
        if let error = state.applyUpstreamProxy(enabled: true, host: host, port: port, kind: .httpConnect) {
            upstreamError = error
            // Keep the pane consistent: an invalid detected address never stays enabled.
            _ = state.applyUpstreamProxy(enabled: false, host: host, port: port, kind: .httpConnect)
        } else {
            upstreamError = nil
            syncUpstreamFields()
        }
    }

    private func syncUpstreamFields(for kind: UpstreamProxyKind? = nil) {
        if kind == nil || kind == .httpConnect {
            upstreamHTTPHostText = settings.upstreamHTTPHost
            upstreamHTTPPortText = settings.upstreamHTTPPort > 0 ? String(settings.upstreamHTTPPort) : ""
        }
        if kind == nil || kind == .socks5 {
            upstreamSOCKSHostText = settings.upstreamSOCKSHost
            upstreamSOCKSPortText = settings.upstreamSOCKSPort > 0 ? String(settings.upstreamSOCKSPort) : ""
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

    /// Editable inputs are white with a hairline border (a grey fill reads as disabled);
    /// truly disabled fields keep the sunken fill.
    private func fieldBackground(isFocused: Bool, isEnabled: Bool = true) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
            .fill(isEnabled ? DSColor.raised : DSColor.sunken)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .strokeBorder(
                        isFocused ? DSColor.accent : DSColor.border,
                        lineWidth: isFocused ? 1.5 : 1
                    )
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
        .fastTooltip(help)
        .accessibilityLabel(help)
    }
}
