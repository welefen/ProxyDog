import Darwin
import Foundation
import NIOCore
import NIOPosix

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

        var isStarting: Bool {
            if case .starting = self { return true }
            return false
        }

        var isStopped: Bool {
            if case .stopped = self { return true }
            return false
        }

        var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
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

    let sink: CaptureSink
    let certificateAuthority: CertificateAuthority

    /// Serializes listener start/stop so the server can be restarted (also on a
    /// different port) without racing the event loop group teardown.
    private let lifecycleQueue = DispatchQueue(label: "com.proxydog.proxy.lifecycle", qos: .userInitiated)
    private let stateLock = NSLock()
    private var generation: Int = 0
    private var loopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?

    init(port: Int, sslProxyingEnabled: Bool, sink: CaptureSink, certificateAuthority: CertificateAuthority = .shared) {
        self.port = port
        self.sslProxyingEnabled = sslProxyingEnabled
        self.sink = sink
        self.certificateAuthority = certificateAuthority
    }

    // MARK: - Lifecycle

    func start() {
        stateLock.lock()
        generation += 1
        let requestGeneration = generation
        stateLock.unlock()

        let bindPort = port
        let sslEnabled = sslProxyingEnabled
        postStatus(.starting)

        lifecycleQueue.async { [weak self] in
            self?.performStart(generation: requestGeneration, port: bindPort, sslEnabled: sslEnabled)
        }
    }

    func stop() {
        stateLock.lock()
        generation += 1
        let requestGeneration = generation
        stateLock.unlock()

        postStatus(.stopped)
        lifecycleQueue.async { [weak self] in
            self?.performStop(generation: requestGeneration)
        }
    }

    // MARK: - Lifecycle implementation (runs on `lifecycleQueue`)

    private func performStart(generation requestGeneration: Int, port bindPort: Int, sslEnabled: Bool) {
        guard isCurrent(generation: requestGeneration) else { return }

        // Tear down any previous listener first (restart support, including port changes).
        tearDownLocked()

        guard isCurrent(generation: requestGeneration) else { return }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let sink = self.sink
        let certificateAuthority = certificateAuthority
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .childChannelInitializer { channel in
                let handler = ProxyFrontendHandler(
                    sink: sink,
                    certificateAuthority: certificateAuthority,
                    sslProxyingEnabled: sslEnabled
                )
                return channel.pipeline.addHandler(handler)
            }

        do {
            let channel = try bootstrap.bind(host: "127.0.0.1", port: bindPort).wait()

            guard isCurrent(generation: requestGeneration) else {
                // A newer start/stop request superseded us while binding.
                try? channel.close().wait()
                try? group.syncShutdownGracefully()
                return
            }

            serverChannel = channel
            loopGroup = group
            postStatus(.running(port: bindPort))
        } catch {
            try? group.syncShutdownGracefully()
            guard isCurrent(generation: requestGeneration) else { return }
            postStatus(.failed(Self.describe(bindError: error, port: bindPort)))
        }
    }

    private func performStop(generation requestGeneration: Int) {
        guard isCurrent(generation: requestGeneration) else { return }
        tearDownLocked()
    }

    private func tearDownLocked() {
        if let channel = serverChannel {
            serverChannel = nil
            try? channel.close().wait()
        }
        if let group = loopGroup {
            loopGroup = nil
            try? group.syncShutdownGracefully()
        }
    }

    private func isCurrent(generation requestGeneration: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == requestGeneration
    }

    // MARK: - Status reporting

    private func postStatus(_ newStatus: Status) {
        DispatchQueue.main.async {
            self.status = newStatus
            self.onStatusChange?(newStatus)
        }
    }

    private static func describe(bindError error: Error, port: Int) -> String {
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case EADDRINUSE:
                return "Port \(port) is already in use. Choose a different port."
            case EACCES:
                return "No permission to listen on port \(port)."
            default:
                return "Could not start the proxy on 127.0.0.1:\(port) (errno \(ioError.errnoCode))."
            }
        }
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return "Timed out while starting the proxy on 127.0.0.1:\(port)."
        }
        return "Could not start the proxy on 127.0.0.1:\(port): \(error)"
    }
}
