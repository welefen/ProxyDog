import Foundation
import NIOCore

// MARK: - App naming

extension ClientProcess {
    /// Name shown as the capture's "client app".
    ///
    /// `ClientProcess.displayName` resolves helper processes to their enclosing app (e.g.
    /// WebKit networking -> "Safari"), which is what the UI wants. For plain command-line
    /// tools (curl, python, ...) the parent's .app bundle would be misleading ("Terminal"),
    /// so those keep their own executable name unless the executable itself is an app
    /// binary or an XPC/helper process.
    var attributedAppName: String {
        let path = executablePath ?? ""
        let loweredName = name.lowercased()
        let isHelper = loweredName.contains("helper")
            || loweredName.hasPrefix("com.apple.")
            || path.contains(".xpc/")
            || path.contains("XPCServices/")
        if isHelper {
            return displayName
        }
        if path.contains(".app/"), !displayName.isEmpty {
            return displayName
        }
        if !name.isEmpty {
            return name
        }
        return displayName
    }
}

// MARK: - CapturedRequest helper

extension CapturedRequest {
    /// Fills the client process attribution fields; no-op when attribution failed.
    mutating func applyClientProcess(_ process: ClientProcess?) {
        guard let process else { return }
        clientPID = process.pid
        clientAppName = process.attributedAppName
        clientAppPath = process.executablePath
    }
}

// MARK: - Per-connection identity

/// Thread-safe holder for the (asynchronously looked up) process that owns a client
/// connection. Observers are always called on the event loop they registered with, so
/// capture-state mutations stay on the connection's own loop.
///
/// libproc only sees processes of the same user; root-owned helpers are simply not
/// attributed (all fields stay nil). See `ClientProcessProbe`.
final class ClientIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var process: ClientProcess?
    private var resolved = false
    private var observers: [(eventLoop: EventLoop, callback: @Sendable (ClientProcess?) -> Void)] = []

    init() {}

    /// The process, when the probe already finished (nil while pending or when failed).
    var current: ClientProcess? {
        lock.lock()
        defer { lock.unlock() }
        return process
    }

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    /// Completes the attribution. Only the first call wins.
    func resolve(_ process: ClientProcess?) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        self.process = process
        let observers = self.observers
        self.observers.removeAll()
        lock.unlock()

        for observer in observers {
            observer.eventLoop.execute {
                observer.callback(process)
            }
        }
    }

    /// Calls `callback` once attribution completes (immediately, on `eventLoop`, when it
    /// already completed).
    func observe(on eventLoop: EventLoop, _ callback: @escaping @Sendable (ClientProcess?) -> Void) {
        lock.lock()
        if resolved {
            let process = self.process
            lock.unlock()
            eventLoop.execute {
                callback(process)
            }
        } else {
            observers.append((eventLoop, callback))
            lock.unlock()
        }
    }
}

// MARK: - Attributor

/// Resolves which local process opened a proxied TCP connection.
///
/// The proxy only sees a TCP connection, so attribution means: take the client's
/// ephemeral (peer) port, then ask libproc which process owns the socket bound to it.
/// That lookup costs ~1-3 ms, so it always runs on a private serial queue and results
/// are delivered back on the caller's event loop. A short-lived cache keeps reconnects /
/// repeated lookups from re-scanning the process list.
///
/// Limitations: only same-user processes are visible; connections proxied by another
/// daemon or root-owned helpers produce nil and simply leave the capture unattributed.
final class ClientProcessAttributor: @unchecked Sendable {
    static let shared = ClientProcessAttributor()

    private struct CacheEntry {
        let process: ClientProcess?
        let timestamp: Date
    }

    /// Serial queue: the libproc scan is never run on an event loop.
    private let queue = DispatchQueue(label: "com.proxydog.client-process-attribution", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [UInt16: CacheEntry] = [:]
    private var lastPrune = Date()

    /// Positive results are stable for a few seconds; negative ones are retried sooner
    /// (e.g. a short-lived process may not be visible yet).
    private let positiveTTL: TimeInterval = 5
    private let negativeTTL: TimeInterval = 1

    private init() {}

    /// Attributes the connection whose client-side (peer) port is `peerPort`.
    ///
    /// - Parameters:
    ///   - peerPort: the client app's ephemeral port (`channel.remoteAddress?.port`).
    ///   - listenPort: the proxy listener port (diagnostics/cache partitioning).
    ///   - eventLoop: where `completion` is delivered.
    ///   - completion: receives the resolved process (or nil when not attributable).
    func attribute(
        peerPort: UInt16,
        listenPort: UInt16,
        eventLoop: EventLoop,
        completion: @escaping @Sendable (ClientProcess?) -> Void
    ) {
        _ = listenPort
        let now = Date()

        lock.lock()
        if let entry = cache[peerPort] {
            let age = now.timeIntervalSince(entry.timestamp)
            let ttl = entry.process == nil ? negativeTTL : positiveTTL
            if age <= ttl {
                let process = entry.process
                lock.unlock()
                deliver(process, on: eventLoop, completion: completion)
                return
            }
        }
        lock.unlock()

        queue.async {
            let process = ClientProcessProbe.process(forLocalPort: peerPort)
            let resolvedAt = Date()
            self.lock.lock()
            self.cache[peerPort] = CacheEntry(process: process, timestamp: resolvedAt)
            self.pruneLocked(now: resolvedAt)
            self.lock.unlock()
            self.deliver(process, on: eventLoop, completion: completion)
        }
    }

    private func deliver(
        _ process: ClientProcess?,
        on eventLoop: EventLoop,
        completion: @escaping @Sendable (ClientProcess?) -> Void
    ) {
        if eventLoop.inEventLoop {
            completion(process)
        } else {
            eventLoop.execute {
                completion(process)
            }
        }
    }

    private func pruneLocked(now: Date) {
        guard now.timeIntervalSince(lastPrune) > 5 else { return }
        lastPrune = now
        cache = cache.filter { now.timeIntervalSince($0.value.timestamp) < 10 }
    }
}
