import AppKit
import Combine
import SwiftUI

/// Root state of the app: settings, captured traffic, the proxy engine and all the
/// user intents the UI can trigger.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings: AppSettings
    let store: CaptureStore
    let rewriteRules: RewriteRuleStore
    let breakpoints: BreakpointRuleStore
    /// Breakpoint sessions waiting for the user's decision (shown as a sheet).
    @Published var pendingBreakpoints: [BreakpointPayload] = []
    /// True while an intentional restart is in flight; transient status changes are hidden.
    private var isRestartingProxy = false
    /// Pre-filled rule drafts opened from the traffic list context menu.
    @Published var rewriteRuleDraft: RewriteRule?
    @Published var breakpointRuleDraft: BreakpointRule?

    /// Set when another window wants the settings pane on a specific page.
    @Published var settingsDestinationRequest: SettingsDestination?
    /// Set when another window wants the rule editor for the given kind opened.
    @Published var requestedRuleEditor: RuleEditorTarget?
    let proxy: ProxyServer

    @Published private(set) var proxyStatus: ProxyServer.Status = .stopped
    @Published var sidebarSelection: SidebarSelection = .all
    @Published var searchText: String = ""
    /// Chrome-style type filter for the traffic list; `.all` means no filter.
    @Published var typeFilter: RequestCategory = .all
    @Published var selectionID: CapturedRequest.ID?
    @Published private(set) var isCertificateTrusted = false
    @Published var isOnboardingPresented = false
    @Published var errorMessage: String?

    private let sink: MainActorCaptureSink
    private var hasBootstrapped = false
    private var storeCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var ignoreOwnTrafficCancellable: AnyCancellable?

    convenience init() {
        self.init(
            settings: AppSettings(),
            store: CaptureStore(),
            rewriteRules: RewriteRuleStore(),
            breakpoints: BreakpointRuleStore()
        )
    }

    init(
        settings: AppSettings,
        store: CaptureStore,
        rewriteRules: RewriteRuleStore,
        breakpoints: BreakpointRuleStore
    ) {
        self.settings = settings
        self.store = store
        self.rewriteRules = rewriteRules
        self.breakpoints = breakpoints
        let sink = MainActorCaptureSink(store: store)
        self.sink = sink
        let proxy = ProxyServer(
            port: settings.port,
            sslProxyingEnabled: settings.sslProxyingEnabled,
            sink: sink,
            certificateAuthority: .shared
        )
        self.proxy = proxy
        proxy.rewriteRulesProvider = { [rewriteRules] in rewriteRules.snapshot.current() }
        proxy.breakpointRulesProvider = { [breakpoints] in breakpoints.snapshot.current() }
        proxy.breakpointGate.onPendingChanged = { [weak self] payloads in
            Task { @MainActor in
                self?.pendingBreakpoints = payloads
            }
        }
        proxy.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                // A restart briefly reports .stopped/.starting; swallow those transitions so
                // the UI does not flash (e.g. the HTTP proxy switch disabling itself).
                if self.isRestartingProxy {
                    switch status {
                    case .stopped, .starting:
                        return
                    default:
                        self.isRestartingProxy = false
                    }
                }
                self.proxyStatus = status
            }
        }

        // AppState is the single object the views observe, so changes published by
        // the store (new captures) and settings (port, appearance) have to be
        // forwarded or the window would never repaint live traffic.
        storeCancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
        settingsCancellable = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
            Task { @MainActor in
                self?.syncFaviconRoute()
            }
        }
        store.ignoresOwnTraffic = settings.ignoreOwnTraffic
        syncFaviconRoute()
        ignoreOwnTrafficCancellable = settings.$ignoreOwnTraffic.sink { [weak self] value in
            Task { @MainActor in
                self?.store.ignoresOwnTraffic = value
            }
        }
    }

    /// Asks the settings window to show `destination`; the caller opens the window via
    /// SwiftUI's `openSettings` environment action.
    func requestSettings(destination: SettingsDestination) {
        settingsDestinationRequest = destination
    }

    /// Asks the settings window to open the rules page and the "new rule" editor.
    func requestRuleEditor(_ target: RuleEditorTarget) {
        settingsDestinationRequest = .rules
        requestedRuleEditor = target
    }

    // MARK: - Rule drafts

    /// Opens the rewrite editor pre-filled for `request`, matching its exact URL.
    func beginRewriteRule(for request: CapturedRequest) {
        var rule = RewriteRule()
        rule.name = RuleDraft.suggestedName(for: request)
        rule.method = request.method
        rule.urlPattern = RuleDraft.literalPattern(for: request.urlString)
        rule.action = .modifyResponse
        rewriteRuleDraft = rule
    }

    /// Opens the breakpoint editor pre-filled for `request`, pausing on its request phase.
    func beginBreakpointRule(for request: CapturedRequest) {
        var rule = BreakpointRule()
        rule.name = RuleDraft.suggestedName(for: request)
        rule.method = request.method
        rule.urlPattern = RuleDraft.literalPattern(for: request.urlString)
        rule.breakOnRequest = true
        rule.breakOnResponse = false
        breakpointRuleDraft = rule
    }

    // MARK: - Breakpoints

    /// Resume or drop a paused exchange from the breakpoint editor.
    func resolveBreakpoint(id: UUID, decision: BreakpointDecision) {
        proxy.breakpointGate.resolve(id: id, decision: decision)
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        Analytics.shared.configure(appKey: AppConfig.aptabaseAppKey)
        if AppConfig.isAnalyticsEnabled {
            Analytics.shared.track("app_launched", properties: [
                "appearance": settings.appearance.rawValue,
                "ssl_enabled": String(settings.sslProxyingEnabled),
            ])
        }
        if !settings.hasCompletedOnboarding {
            isOnboardingPresented = true
        }
        do {
            try CertificateAuthority.shared.prepareIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshCertificateStatus()
        if settings.systemProxyEnabled {
            setSystemProxy(enabled: true)
        }
        // LAN access is gated by the system proxy; stale persistence must not re-expose it.
        if settings.allowLANDevices, !settings.systemProxyEnabled {
            settings.allowLANDevices = false
            proxy.bindHost = "127.0.0.1"
        }
        startProxy()
    }

    func shutdown() {
        proxy.stop()
        if settings.systemProxyEnabled {
            try? SystemProxy.disable()
        }
    }

    // MARK: - Proxy control

    var isProxyRunning: Bool { proxyStatus.isRunning }

    func startProxy() {
        // Ask the engine itself, not the published copy: status callbacks are async.
        guard !proxy.status.isRunning else { return }
        proxy.port = settings.port
        proxy.sslProxyingEnabled = settings.sslProxyingEnabled
        proxy.bindHost = (settings.allowLANDevices && settings.systemProxyEnabled) ? "0.0.0.0" : "127.0.0.1"
        proxy.socksUpstreamFallbackToHTTP = false
        proxy.upstreamProxy = upstreamProxyFromSettings()
        proxy.socksUpstreamProxy = socksUpstreamProxyFromSettings()
        proxy.socksPort = socksProxyFromSettings()
        proxyStatus = .starting
        proxy.start()
        Analytics.shared.track("proxy_started", properties: ["port": String(settings.port)])
    }

    func stopProxy() {
        isRestartingProxy = false
        proxyStatus = .stopped
        proxy.stop()
        Analytics.shared.track("proxy_stopped")
    }

    func toggleProxy() {
        if proxyStatus.isRunning {
            stopProxy()
        } else {
            startProxy()
        }
    }

    func restartProxy() {
        let shouldRestart = proxy.status.isRunning || proxyStatus.isRunning
        isRestartingProxy = shouldRestart
        proxy.stop()
        guard shouldRestart else {
            proxyStatus = .stopped
            return
        }
        proxy.port = settings.port
        proxy.sslProxyingEnabled = settings.sslProxyingEnabled
        proxy.bindHost = (settings.allowLANDevices && settings.systemProxyEnabled) ? "0.0.0.0" : "127.0.0.1"
        proxy.socksUpstreamFallbackToHTTP = false
        proxy.upstreamProxy = upstreamProxyFromSettings()
        proxy.socksUpstreamProxy = socksUpstreamProxyFromSettings()
        proxy.socksPort = socksProxyFromSettings()
        // Keep the previous .running status while restarting: flipping to .starting here
        // made the HTTP proxy switch (disabled unless the proxy runs) flash.
        proxy.start()
    }

    func applyPort(_ port: Int) {
        guard port > 0, port < 65_536 else {
            errorMessage = String(localized: "Port must be between 1 and 65535.")
            return
        }
        let wasRunning = proxy.status.isRunning || proxyStatus.isRunning
        settings.port = port
        if wasRunning {
            restartProxy()
        }
    }

    // MARK: - LAN devices

    /// LAN IPv4 of this Mac, when available.
    var lanAddress: String? { NetworkAddress.lanIPv4() }

    /// "ip:port" that other devices should use as their HTTP proxy.
    var lanProxyAddress: String? {
        guard settings.allowLANDevices, let host = lanAddress else { return nil }
        return "\(host):\(settings.port)"
    }

    /// Exposes or hides the HTTP proxy on the local network.
    func applyLANAccess(_ enabled: Bool) {
        // LAN access is only meaningful while this Mac's system proxy is on.
        if enabled, !settings.systemProxyEnabled {
            guard settings.allowLANDevices else { return }
            settings.allowLANDevices = false
            proxy.bindHost = "127.0.0.1"
            if proxy.status.isRunning || proxyStatus.isRunning {
                restartProxy()
            }
            return
        }
        guard settings.allowLANDevices != enabled else { return }
        settings.allowLANDevices = enabled
        proxy.bindHost = (enabled && settings.systemProxyEnabled) ? "0.0.0.0" : "127.0.0.1"
        if proxy.status.isRunning || proxyStatus.isRunning {
            restartProxy()
        }
    }

    // MARK: - Upstream proxy (proxy chaining)

    /// Applies the upstream proxy configuration. Returns a localized error message when
    /// the configuration is invalid (nothing is applied in that case).
    @discardableResult
    func applyUpstreamProxy(enabled: Bool, host: String, port: Int) -> String? {
        applyUpstreamProxy(enabled: enabled, host: host, port: port, kind: settings.effectiveUpstreamKind)
    }

    @discardableResult
    func applyUpstreamProxy(enabled: Bool, host: String, port: Int, kind requestedKind: UpstreamProxyKind) -> String? {
        var host = host
        var port = port
        var kind = requestedKind
        // Enable first, fill later: an empty or incomplete address just means "no upstream".
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousHost = settings.upstreamHost(for: kind)
        let previousPort = settings.upstreamPort(for: kind)
        let previousEnabled = settings.upstreamEnabled(for: kind)

        settings.setUpstreamAddress(host: trimmedHost, port: port, kind: kind)
        func rollback() {
            settings.setUpstreamAddress(host: previousHost, port: previousPort, kind: kind)
        }

        // An empty or incomplete address is not an error: the upstream is simply ignored
        // until both host and port are valid. Only a proxy loop is rejected.
        if enabled, !trimmedHost.isEmpty, (1...65535).contains(port) {
            let candidate = UpstreamProxy(kind: kind, host: trimmedHost, port: port)
            let isOwnPort = candidate.isLoopback && candidate.port == settings.port
            let isOwnSocksPort = candidate.isLoopback && settings.socksProxyEnabled
                && candidate.port == settings.socksProxyPort
            if isOwnPort || isOwnSocksPort {
                rollback()
                return String(localized: "The upstream proxy cannot be ProxyDog itself.")
            }
        }

        let changed = previousEnabled != enabled
            || previousHost != trimmedHost
            || previousPort != port

        settings.setUpstreamEnabled(enabled, for: kind)
        settings.upstreamProxyKind = settings.upstreamHost(for: .httpConnect).isEmpty ? .socks5 : .httpConnect
        proxy.upstreamProxy = upstreamProxyFromSettings()
        proxy.socksUpstreamProxy = socksUpstreamProxyFromSettings()

        if changed, proxy.status.isRunning || proxyStatus.isRunning {
            restartProxy()
        }
        return nil
    }

    // MARK: - SOCKS5 listener

    /// Enables/disables the extra SOCKS5 listener. Returns a localized error message when
    /// the port is invalid or would collide with another ProxyDog listener.
    @discardableResult
    func applySocksProxy(enabled: Bool, port: Int) -> String? {
        if enabled {
            guard (1...65535).contains(port) else {
                return String(localized: "Port must be between 1 and 65535.")
            }
            if port == settings.port {
                return String(localized: "The SOCKS5 port must differ from the HTTP proxy port.")
            }
            if [UpstreamProxyKind.httpConnect, .socks5].contains(where: { kind in
                settings.upstreamEnabled(for: kind)
                    && settings.upstreamHost(for: kind).hasPrefix("127.")
                    && port == settings.upstreamPort(for: kind)
            }) {
                return String(localized: "The SOCKS5 port must differ from the upstream proxy port.")
            }
        }

        let changed = settings.socksProxyEnabled != enabled || settings.socksProxyPort != port
        settings.socksProxyEnabled = enabled
        settings.socksProxyPort = port
        proxy.socksPort = socksProxyFromSettings()

        if changed, proxy.status.isRunning || proxyStatus.isRunning {
            restartProxy()
        }
        return nil
    }

    /// Port of the SOCKS5 listener derived from settings, nil when disabled.
    func socksProxyFromSettings() -> Int? {
        guard settings.socksProxyEnabled else { return nil }
        guard (1...65535).contains(settings.socksProxyPort) else { return nil }
        return settings.socksProxyPort
    }

    /// The system proxy as an upstream candidate, or nil when none is configured or it
    /// points at ProxyDog itself (that would be a proxy loop).
    func detectSystemUpstreamProxy() -> (host: String, port: Int)? {
        guard let detected = Self.systemHTTPProxy() else { return nil }
        let candidate = UpstreamProxy(kind: .httpConnect, host: detected.host, port: detected.port)
        if candidate.isLoopback {
            if candidate.port == settings.port { return nil }
            if settings.socksProxyEnabled, candidate.port == settings.socksProxyPort { return nil }
        }
        return detected
    }

    /// Fills the upstream fields from the system proxy when they are still empty. Called
    /// when the settings pane opens so it shows the detected proxy instead of empty fields.
    @discardableResult
    func autoFillUpstreamProxyIfEmpty() -> Bool {
        let httpEmpty = settings.upstreamHTTPHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || settings.upstreamHTTPPort <= 0
        let socksEmpty = settings.upstreamSOCKSHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || settings.upstreamSOCKSPort <= 0
        guard httpEmpty, socksEmpty, let detected = detectSystemUpstreamProxy() else { return false }
        settings.setUpstreamAddress(host: detected.host, port: detected.port, kind: .httpConnect)
        settings.upstreamProxyKind = settings.effectiveUpstreamKind
        return true
    }

    /// Reads the current macOS system proxy and fills in the upstream fields. This is the
    /// "reuse the proxy/VPN that is already running" shortcut.
    @discardableResult
    func detectUpstreamProxyFromSystem() -> Bool {
        guard let detected = detectSystemUpstreamProxy() else { return false }
        settings.setUpstreamAddress(host: detected.host, port: detected.port, kind: .httpConnect)
        settings.upstreamProxyKind = settings.effectiveUpstreamKind
        return true
    }

    /// Valid upstream for one protocol, nil when disabled or the address is incomplete.
    func upstreamProxy(for kind: UpstreamProxyKind) -> UpstreamProxy? {
        guard settings.upstreamEnabled(for: kind) else { return nil }
        let host = settings.upstreamHost(for: kind).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = settings.upstreamPort(for: kind)
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        return UpstreamProxy(kind: kind, host: host, port: port)
    }

    /// Upstream for traffic arriving through the HTTP proxy.
    func upstreamProxyFromSettings() -> UpstreamProxy? {
        upstreamProxy(for: .httpConnect)
    }

    /// Upstream for traffic arriving through the SOCKS5 listener.
    func socksUpstreamProxyFromSettings() -> UpstreamProxy? {
        upstreamProxy(for: .socks5)
    }

    /// Reads the SOCKS proxy of the first active network service and fills the SOCKS5
    /// upstream address. Used by the fill button in the SOCKS5 card.
    @discardableResult
    func detectSocksUpstreamProxyFromSystem() -> Bool {
        guard let detected = Self.systemSOCKSProxy() else { return false }
        settings.setUpstreamAddress(host: detected.host, port: detected.port, kind: .socks5)
        if settings.upstreamSOCKSEnabled {
            _ = applyUpstreamProxy(enabled: true, host: detected.host, port: detected.port, kind: .socks5)
        }
        return true
    }

    /// The macOS SOCKS proxy as an upstream candidate, for placeholder hints.
    func detectSystemSocksUpstreamProxy() -> (host: String, port: Int)? {
        Self.systemSOCKSProxy()
    }

    /// Reads the system SOCKS proxy of the first network service that has one enabled.
    private static func systemSOCKSProxy() -> (host: String, port: Int)? {
        guard let services = try? ProcessRunner.run("/usr/sbin/networksetup", ["-listallnetworkservices"]) else {
            return nil
        }
        let candidates = services.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
        for service in candidates {
            guard let result = try? ProcessRunner.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service]) else {
                continue
            }
            var enabled = false
            var host = ""
            var port = 0
            for line in result.stdout.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "Enabled": enabled = parts[1].lowercased() == "yes"
                case "Server": host = parts[1]
                case "Port": port = Int(parts[1]) ?? 0
                default: break
                }
            }
            if enabled, !host.isEmpty, (1...65535).contains(port) {
                return (host, port)
            }
        }
        return nil
    }

    /// Reads the web proxy of the first active network service via `networksetup`.
    private static func systemHTTPProxy() -> (host: String, port: Int)? {
        guard let services = try? ProcessRunner.run("/usr/sbin/networksetup", ["-listallnetworkservices"]) else {
            return nil
        }
        let candidates = services.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
        for service in candidates {
            guard let result = try? ProcessRunner.run("/usr/sbin/networksetup", ["-getwebproxy", service]) else {
                continue
            }
            var enabled = false
            var host = ""
            var port = 0
            for line in result.stdout.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "Enabled": enabled = parts[1].lowercased() == "yes"
                case "Server": host = parts[1]
                case "Port": port = Int(parts[1]) ?? 0
                default: break
                }
            }
            if enabled, !host.isEmpty, (1...65535).contains(port) {
                return (host, port)
            }
        }
        return nil
    }

    func applySSLProxying(_ enabled: Bool) {
        settings.sslProxyingEnabled = enabled
        if proxy.status.isRunning || proxyStatus.isRunning {
            restartProxy()
        }
    }

    // MARK: - System proxy

    @Published private(set) var isSystemProxyEnabled = false

    func setSystemProxy(enabled: Bool) {
        do {
            if enabled {
                try SystemProxy.enable(port: settings.port)
                settings.systemProxyEnabled = true
                isSystemProxyEnabled = true
                Analytics.shared.track("system_proxy_enabled")
            } else {
                try SystemProxy.disable()
                settings.systemProxyEnabled = false
                isSystemProxyEnabled = false
                Analytics.shared.track("system_proxy_disabled")
            }
        } catch {
            settings.systemProxyEnabled = false
            isSystemProxyEnabled = false
            errorMessage = error.localizedDescription
        }
        syncFaviconRoute()
        // LAN access depends on the Mac's system proxy being on; close it when that is off.
        if !enabled, settings.allowLANDevices {
            applyLANAccess(false)
        }
    }

    /// Favicons are fetched by the app itself; route them the same way the proxy reaches
    /// the internet (upstream proxy, then system proxy, then direct) so icons for sites
    /// that need the VPN are reachable without looping through ProxyDog.
    private func syncFaviconRoute() {
        FaviconStore.shared.updateRoute(
            upstream: upstreamProxyFromSettings() ?? socksUpstreamProxyFromSettings(),
            ownPort: settings.port
        )
    }

    func refreshSystemProxyState() {
        isSystemProxyEnabled = SystemProxy.isEnabled(port: settings.port)
    }

    // MARK: - Certificate

    func refreshCertificateStatus() {
        Task { @MainActor in
            let trusted = await Task.detached { CertificateAuthority.shared.isTrustedInKeychain() }.value
            isCertificateTrusted = trusted
            enforceCertificateRequirement()
        }
    }

    /// HTTPS decryption cannot work without a trusted root certificate, so it is switched
    /// off (and the proxy restarted) when the certificate is missing or untrusted.
    private func enforceCertificateRequirement() {
        guard !isCertificateTrusted, settings.sslProxyingEnabled else { return }
        settings.sslProxyingEnabled = false
        proxy.sslProxyingEnabled = false
        if proxy.status.isRunning || proxyStatus.isRunning {
            restartProxy()
        }
    }

    func installCertificate() {
        // The install can block on a system authentication dialog, so it runs off the
        // main actor and only hops back for the UI update / error alert.
        Task {
            do {
                try await Task.detached { try CertificateAuthority.shared.requestInstallTrust() }.value
                refreshCertificateStatus()
                Analytics.shared.track("certificate_installed")
            } catch {
                errorMessage = error.localizedDescription
                presentCertificateInstallFailure(error)
            }
        }
    }

    /// Certificate installation goes through several macOS security layers, so when it
    /// fails the reason has to be visible instead of silently leaving the UI untrusted.
    private func presentCertificateInstallFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not install the root certificate")
        alert.informativeText = [
            error.localizedDescription,
            String(localized: "You can also double-click the certificate, open it in Keychain Access and set it to Always Trust."),
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Reveal certificate"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([rootCertificateURL])
        }
    }

    func removeCertificate() {
        Task {
            do {
                try await Task.detached { try CertificateAuthority.shared.removeTrust() }.value
                refreshCertificateStatus()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var rootCertificateURL: URL { CertificateAuthority.shared.rootCertificateURL }

    func exportCertificate(to url: URL) {
        do {
            try CertificateAuthority.shared.exportRootCertificate(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Captured traffic

    var filteredRequests: [CapturedRequest] {
        var items = store.requests
        switch sidebarSelection {
        case .all:
            break
        case .pinned:
            items = items.filter(\.isPinned)
        case .client(let name):
            items = items.filter { $0.clientGroupKey == name }
        case .domain(let domain):
            items = items.filter { $0.host == domain }
        }

        if typeFilter == .error {
            items = items.filter { $0.isFailure }
        } else if typeFilter.isFiltering {
            items = items.filter { RequestCategory.categorize($0) == typeFilter }
        }

        // Search supports a `method:GET` token (double-clicking a row's method badge
        // inserts it), mixed with plain text terms.
        let raw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return items }
        var methodFilter: String?
        var textTerms: [String] = []
        for token in raw.split(separator: " ").map(String.init) {
            if token.lowercased().hasPrefix("method:") {
                let value = token.dropFirst("method:".count).uppercased()
                if !value.isEmpty { methodFilter = value }
            } else {
                textTerms.append(token)
            }
        }
        let query = textTerms.joined(separator: " ").lowercased()
        return items.filter { request in
            if let methodFilter, request.method.uppercased() != methodFilter {
                return false
            }
            guard !query.isEmpty else { return true }
            return request.urlString.lowercased().contains(query)
                || request.method.lowercased().contains(query)
                || request.statusText.lowercased() == query
        }
    }

    var selectedRequest: CapturedRequest? {
        guard let selectionID else { return nil }
        return store.request(id: selectionID)
    }

    /// Captured traffic grouped by the app that originated it, busiest first. Requests whose
    /// process could not be attributed are not listed here.
    var clientSummaries: [ClientSummary] {
        var counts: [String: (count: Int, failed: Bool, iconPath: String?, remote: String?)] = [:]
        for request in store.requests {
            if request.clientRemoteAddress == nil {
                guard let name = request.clientAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
            }
            let key = request.clientGroupKey
            let current = counts[key] ?? (0, false, nil, request.clientRemoteAddress)
            counts[key] = (
                current.count + 1,
                current.failed || request.isFailure,
                current.iconPath ?? request.clientAppPath,
                current.remote
            )
        }
        return counts
            .map {
                ClientSummary(
                    name: $0.key,
                    count: $0.value.count,
                    hasFailure: $0.value.failed,
                    iconPath: $0.value.iconPath,
                    remoteAddress: $0.value.remote
                )
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs.name < rhs.name }
                return lhs.count > rhs.count
            }
    }

    var domainSummaries: [DomainSummary] {
        var counts: [String: (count: Int, failed: Bool)] = [:]
        for request in store.requests {
            let current = counts[request.host] ?? (0, false)
            counts[request.host] = (current.count + 1, current.failed || request.isFailure)
        }
        return counts
            .map { DomainSummary(domain: $0.key, count: $0.value.count, hasFailure: $0.value.failed) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs.domain < rhs.domain }
                return lhs.count > rhs.count
            }
    }

    var pinnedCount: Int { store.requests.lazy.filter(\.isPinned).count }

    func clearRequests() {
        store.clear()
        selectionID = nil
        Analytics.shared.track("traffic_cleared")
    }

    func togglePin(_ id: CapturedRequest.ID) {
        store.togglePin(id: id)
    }

    func removeRequest(_ id: CapturedRequest.ID) {
        store.remove(id: id)
        if selectionID == id {
            selectionID = nil
        }
    }

    var allRequests: [CapturedRequest] {
        store.requests
    }

    func togglePause() {
        store.setPaused(!store.isPaused)
    }

    func exportHAR(to url: URL) {
        do {
            let data = try HARExporter.makeHAR(requests: filteredRequests)
            try data.write(to: url)
            Analytics.shared.track("har_exported", properties: ["count": String(filteredRequests.count)])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentHARExportPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ProxyDog.har"
        panel.canCreateDirectories = true
        panel.title = String(localized: "Export HAR")
        if panel.runModal() == .OK, let url = panel.url {
            exportHAR(to: url)
        }
    }

    func presentCertificateExportPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxydog-ca.crt"
        panel.canCreateDirectories = true
        panel.title = String(localized: "Export Root Certificate")
        if panel.runModal() == .OK, let url = panel.url {
            exportCertificate(to: url)
        }
    }

    func copyCurl(for request: CapturedRequest) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(CurlExporter.curlCommand(for: request), forType: .string)
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        isOnboardingPresented = false
        refreshCertificateStatus()
    }

    func dismissOnboarding() {
        settings.hasCompletedOnboarding = true
        isOnboardingPresented = false
    }

    func resetOnboarding() {
        settings.hasCompletedOnboarding = false
        isOnboardingPresented = true
    }
}
