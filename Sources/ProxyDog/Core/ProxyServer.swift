import Foundation

/// The HTTP/HTTPS proxy listener that captures traffic.
///
/// Owned by the proxy core (`Sources/ProxyDog/Core/`). This declaration documents the
/// contract consumed by `AppState`. Implementation rules:
/// - `start()` and `stop()` are called from the main actor and must not block it.
/// - `onStatusChange` is always invoked on the main queue.
/// - Every capture event is reported through the `CaptureSink` passed at init.
final class ProxyServer: @unchecked Sendable {
    enum Status: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        var port: Int? {
            if case .running(let port) = self { return port }
            return nil
        }
    }

    /// Called on the main queue whenever the listener status changes.
    var onStatusChange: ((Status) -> Void)?

    var port: Int
    var sslProxyingEnabled: Bool

    private(set) var status: Status = .stopped

    init(port: Int, sslProxyingEnabled: Bool, sink: CaptureSink, certificateAuthority: CertificateAuthority = .shared) {
        self.port = port
        self.sslProxyingEnabled = sslProxyingEnabled
    }

    func start() {
        // TODO: proxy core implements the listener.
        status = .failed("Proxy engine not implemented yet.")
        onStatusChange?(status)
    }

    func stop() {
        status = .stopped
        onStatusChange?(status)
    }
}
