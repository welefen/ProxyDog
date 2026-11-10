import Foundation

/// Minimal Aptabase client. Implemented without a third-party SDK so the app stays
/// dependency free on the analytics side.
///
/// Endpoint: POST https://{region}.aptabase.com/api/v0/event
/// The region is the second segment of the app key, e.g. `A-US-1234` -> `us`.
final class Analytics: @unchecked Sendable {
    static let shared = Analytics()

    private let queue = DispatchQueue(label: "com.proxydog.analytics")
    private var appKey: String = ""
    private var regionHost: String = ""
    private var sessionID = UUID().uuidString
    private var isFlushing = false
    private var pending: [[String: Any]] = []

    private init() {}

    /// Enables analytics for the given key. Pass an empty string to disable.
    func configure(appKey: String) {
        queue.async {
            let key = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.appKey = key
            self.regionHost = Analytics.host(forAppKey: key)
        }
    }

    var isEnabled: Bool {
        queue.sync { !appKey.isEmpty }
    }

    func track(_ eventName: String, properties: [String: String] = [:]) {
        queue.async {
            guard !self.appKey.isEmpty, !self.regionHost.isEmpty else { return }
            var payload: [String: Any] = [
                "timestamp": Analytics.timestampFormatter.string(from: Date()),
                "sessionId": self.sessionID,
                "eventName": eventName,
                "systemProps": Analytics.systemProperties(),
                "props": properties,
            ]
            if properties.isEmpty { payload["props"] = [String: Any]() }
            self.pending.append(payload)
            self.flushIfNeeded()
        }
    }

    private func flushIfNeeded() {
        guard !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        let events = pending
        pending.removeAll()
        let urlString = "https://\(regionHost)/api/v0/event"
        guard let url = URL(string: urlString) else {
            isFlushing = false
            return
        }
        let key = appKey
        queue.async {
            for event in events {
                guard let body = try? JSONSerialization.data(withJSONObject: event) else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(key, forHTTPHeaderField: "App-Key")
                request.timeoutInterval = 10
                URLSession.shared.dataTask(with: request) { _, _, _ in
                    self.queue.async {
                        if self.pending.isEmpty {
                            self.isFlushing = false
                        } else {
                            self.isFlushing = false
                            self.flushIfNeeded()
                        }
                    }
                }.resume()
            }
        }
    }

    private static func host(forAppKey key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count >= 2 else { return "" }
        let region = String(parts[1]).lowercased()
        guard !region.isEmpty else { return "" }
        return "\(region).aptabase.com"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func systemProperties() -> [String: Any] {
        let processInfo = ProcessInfo.processInfo
        let locale = Locale.current.identifier
        return [
            "locale": locale,
            "osName": "macOS",
            "osVersion": processInfo.operatingSystemVersionString,
            "deviceModel": "\(hostModel())",
            "appVersion": AppInfo.version,
            "sdkVersion": "proxydog-1.0.0",
        ]
    }

    private static func hostModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
