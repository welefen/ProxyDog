import Foundation

/// Minimal Aptabase client. Implemented without a third-party SDK so the app stays
/// dependency free on the analytics side.
///
/// Ingest format: `POST https://{region}.aptabase.com/api/v0/event` with the
/// `App-Key` header and one JSON event per request. The region is the second
/// segment of the app key (`A-US-…` -> `us.aptabase.com`).
///
/// Design rules:
/// - an empty or malformed key means analytics is completely inert;
/// - every failure is silent, nothing is ever logged or surfaced to the UI;
/// - events are queued and sent by at most two concurrent requests, so the app is
///   never blocked and a slow network cannot pile up connections.
final class Analytics: @unchecked Sendable {
    static let shared = Analytics()

    private static let maxInFlight = 2
    private static let maxPendingEvents = 256
    private static let flushDelay: TimeInterval = 0.6

    private let stateQueue = DispatchQueue(label: "com.proxydog.analytics.state")
    private let urlSession: URLSession
    private let sessionID = UUID().uuidString.lowercased()

    // Mutated only on `stateQueue`.
    private var appKey = ""
    private var regionHost = ""
    private var pending: [[String: Any]] = []
    private var inFlight = 0
    private var flushScheduled = false

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "ProxyDog/\(AppInfo.version)"]
        urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Configuration

    /// Enables analytics for the given key. Pass an empty string to disable it.
    /// Events captured while disabled are dropped, and any queued events are
    /// discarded when the key changes to an invalid/empty value.
    func configure(appKey: String) {
        let key = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        stateQueue.async {
            let host = Analytics.regionHost(forAppKey: key)
            self.appKey = key
            self.regionHost = host
            if key.isEmpty || host.isEmpty {
                self.pending.removeAll()
            }
        }
    }

    var isEnabled: Bool {
        stateQueue.sync { !appKey.isEmpty && !regionHost.isEmpty }
    }

    // MARK: - Events

    func track(_ eventName: String, properties: [String: String] = [:]) {
        let name = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        stateQueue.async {
            guard !self.appKey.isEmpty, !self.regionHost.isEmpty else { return }
            let event: [String: Any] = [
                "timestamp": Analytics.timestamp(),
                "sessionId": self.sessionID,
                "eventName": name,
                "systemProps": Analytics.systemProperties(),
                "props": properties,
            ]
            self.pending.append(event)
            if self.pending.count > Analytics.maxPendingEvents {
                self.pending.removeFirst(self.pending.count - Analytics.maxPendingEvents)
            }
            self.scheduleFlushLocked()
        }
    }

    // MARK: - Delivery (runs on stateQueue)

    private func scheduleFlushLocked() {
        guard !flushScheduled, !pending.isEmpty else { return }
        flushScheduled = true
        stateQueue.asyncAfter(deadline: .now() + Analytics.flushDelay) {
            self.flushScheduled = false
            self.flushLocked()
        }
    }

    private func flushLocked() {
        guard !appKey.isEmpty, !regionHost.isEmpty else {
            pending.removeAll()
            return
        }
        guard let url = URL(string: "https://\(regionHost)/api/v0/event") else {
            pending.removeAll()
            return
        }

        while inFlight < Analytics.maxInFlight, !pending.isEmpty {
            let event = pending.removeFirst()
            guard let body = try? JSONSerialization.data(withJSONObject: event) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(appKey, forHTTPHeaderField: "App-Key")
            request.timeoutInterval = 5

            inFlight += 1
            urlSession.dataTask(with: request) { [weak self] _, _, _ in
                guard let self else { return }
                self.stateQueue.async {
                    self.inFlight = max(0, self.inFlight - 1)
                    if !self.pending.isEmpty {
                        self.flushLocked()
                    }
                }
            }.resume()
        }
    }

    // MARK: - Payload helpers

    private static func regionHost(forAppKey key: String) -> String {
        let parts = key.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0].uppercased() == "A" else { return "" }
        switch parts[1].uppercased() {
        case "US": return "us.aptabase.com"
        case "EU": return "eu.aptabase.com"
        default: return ""
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    private static func systemProperties() -> [String: String] {
        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        return [
            "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            "osName": "macOS",
            "osVersion": "\(version.majorVersion).\(version.minorVersion)",
            "deviceModel": hardwareModel(),
            "appVersion": AppInfo.version,
            "sdkVersion": "proxydog-1.0.0",
        ]
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }
}
