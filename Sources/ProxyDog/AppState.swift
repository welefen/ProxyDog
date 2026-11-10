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
    let proxy: ProxyServer

    @Published private(set) var proxyStatus: ProxyServer.Status = .stopped
    @Published var sidebarSelection: SidebarSelection = .all
    @Published var searchText: String = ""
    @Published var selectionID: CapturedRequest.ID?
    @Published private(set) var isCertificateTrusted = false
    @Published var isOnboardingPresented = false
    @Published var errorMessage: String?

    private let sink: MainActorCaptureSink
    private var hasBootstrapped = false
    private var storeCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?

    convenience init() {
        self.init(settings: AppSettings(), store: CaptureStore())
    }

    init(settings: AppSettings, store: CaptureStore) {
        self.settings = settings
        self.store = store
        let sink = MainActorCaptureSink(store: store)
        self.sink = sink
        let proxy = ProxyServer(
            port: settings.port,
            sslProxyingEnabled: settings.sslProxyingEnabled,
            sink: sink,
            certificateAuthority: .shared
        )
        self.proxy = proxy
        proxy.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.proxyStatus = status
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
        }
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        Analytics.shared.configure(appKey: settings.aptabaseAppKey)
        if settings.analyticsEnabled {
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
        proxyStatus = .starting
        proxy.start()
        Analytics.shared.track("proxy_started", properties: ["port": String(settings.port)])
    }

    func stopProxy() {
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
        proxy.stop()
        guard shouldRestart else {
            proxyStatus = .stopped
            return
        }
        proxy.port = settings.port
        proxy.sslProxyingEnabled = settings.sslProxyingEnabled
        proxyStatus = .starting
        proxy.start()
    }

    func applyPort(_ port: Int) {
        guard port > 0, port < 65_536 else {
            errorMessage = "Port must be between 1 and 65535."
            return
        }
        let wasRunning = proxy.status.isRunning || proxyStatus.isRunning
        settings.port = port
        if wasRunning {
            restartProxy()
        }
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
    }

    func refreshSystemProxyState() {
        isSystemProxyEnabled = SystemProxy.isEnabled(port: settings.port)
    }

    // MARK: - Certificate

    func refreshCertificateStatus() {
        Task { @MainActor in
            let trusted = await Task.detached { CertificateAuthority.shared.isTrustedInKeychain() }.value
            isCertificateTrusted = trusted
        }
    }

    func installCertificate() {
        do {
            try CertificateAuthority.shared.requestInstallTrust()
            refreshCertificateStatus()
            Analytics.shared.track("certificate_installed")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeCertificate() {
        do {
            try CertificateAuthority.shared.removeTrust()
            refreshCertificateStatus()
        } catch {
            errorMessage = error.localizedDescription
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
        case .domain(let domain):
            items = items.filter { $0.host == domain }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { request in
            request.urlString.lowercased().contains(query)
                || request.method.lowercased().contains(query)
                || request.statusText.lowercased() == query
        }
    }

    var selectedRequest: CapturedRequest? {
        guard let selectionID else { return nil }
        return store.request(id: selectionID)
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
        panel.title = "Export HAR"
        if panel.runModal() == .OK, let url = panel.url {
            exportHAR(to: url)
        }
    }

    func presentCertificateExportPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxydog-ca.crt"
        panel.canCreateDirectories = true
        panel.title = "Export Root Certificate"
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

    func completeOnboarding(appKey: String) {
        settings.aptabaseAppKey = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.hasCompletedOnboarding = true
        isOnboardingPresented = false
        Analytics.shared.configure(appKey: settings.aptabaseAppKey)
        if settings.analyticsEnabled {
            Analytics.shared.track("app_launched")
        }
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
