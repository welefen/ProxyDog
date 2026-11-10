import Foundation
import ProcessProbe

/// The local process a proxy connection came from.
struct ClientProcess: Equatable, Sendable {
    var pid: Int32
    /// Short process name, e.g. "Safari" or "curl".
    var name: String
    /// Full executable path when known.
    var executablePath: String?
    /// App bundle name when the process (or one of its parents) lives inside an .app,
    /// otherwise the process name.
    var displayName: String

    var pidText: String { String(pid) }
}

/// Bridges the libproc based C probe (`Sources/ProcessProbe`) to Swift.
///
/// The proxy only sees a TCP connection, so identifying the originating app means
/// looking up which local process owns the client's ephemeral port. libproc lets us do
/// that for processes of the current user without extra permissions; root-owned helpers
/// are invisible and simply produce no attribution.
enum ClientProcessProbe {
    /// Looks up the process owning a TCP socket bound to `port`. Cheap (a few ms) and
    /// safe to call from a background queue.
    static func process(forLocalPort port: UInt16) -> ClientProcess? {
        var pid: Int32 = 0
        var nameBuffer = [CChar](repeating: 0, count: 128)
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let result = proxydog_process_for_local_port(
            port,
            &pid,
            &nameBuffer,
            Int32(nameBuffer.count),
            &pathBuffer,
            Int32(pathBuffer.count)
        )
        guard result == 0, pid > 0 else { return nil }

        let name = String(cString: nameBuffer)
        let path = String(cString: pathBuffer)
        return ClientProcess(
            pid: pid,
            name: name,
            executablePath: path.isEmpty ? nil : path,
            displayName: displayName(processName: name, executablePath: path, pid: pid)
        )
    }

    /// Prefers the enclosing app bundle ("Safari.app/Contents/MacOS/…" -> "Safari"),
    /// walking up a few parents so helper processes (e.g. WebKit networking) resolve to
    /// the app the user actually recognises.
    private static func displayName(processName: String, executablePath: String, pid: Int32) -> String {
        if let bundleName = appBundleName(inPath: executablePath) {
            return bundleName
        }

        var current = pid
        for _ in 0..<4 {
            let parent = proxydog_parent_pid(current)
            guard parent > 1 else { break }
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(parent, &pathBuffer, 4096) > 0 {
                if let bundleName = appBundleName(inPath: String(cString: pathBuffer)) {
                    return bundleName
                }
            }
            current = parent
        }
        return processName.isEmpty ? "Unknown" : processName
    }

    /// Extracts "Safari" from "…/Safari.app/Contents/MacOS/Safari".
    private static func appBundleName(inPath path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        let bundlePath = String(path[path.startIndex..<range.lowerBound])
        let name = (bundlePath as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
