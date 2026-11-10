import Foundation

/// Thread-safe line oriented capture sink used by the headless mode and by tests.
final class JSONLineCaptureSink: CaptureSink, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(path: String?) {
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path) ?? FileHandle.standardOutput
        } else {
            handle = FileHandle.standardOutput
        }
    }

    func captureDidUpdate(_ request: CapturedRequest) {
        var payload: [String: Any] = [
            "type": "capture",
            "id": request.id.uuidString,
            "state": request.state.rawValue,
            "method": request.method,
            "url": request.urlString,
            "host": request.host,
            "intercepted": request.intercepted,
            "request_bytes": request.requestBytes,
            "response_bytes": request.responseBytes,
        ]
        if let status = request.statusCode { payload["status"] = status }
        if let duration = request.duration { payload["duration_ms"] = Int(duration * 1000) }
        if let error = request.errorMessage { payload["error"] = error }
        if let contentType = request.responseContentType { payload["content_type"] = contentType }

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else { return }
        write(line + "\n")
    }

    private func write(_ string: String) {
        lock.lock()
        defer { lock.unlock() }
        handle.write(Data(string.utf8))
    }
}

/// `ProxyDog --headless [--port 8899] [--out captures.jsonl] [--exit-after 10]`
enum HeadlessRunner {
    static func run() {
        setbuf(stdout, nil)
        let arguments = CommandLine.arguments

        func flagValue(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let port = Int(flagValue("--port") ?? "") ?? AppDefaults.proxyPort
        let outputPath = flagValue("--out")
        let sslEnabled = !arguments.contains("--no-ssl")
        let exitAfter = Double(flagValue("--exit-after") ?? "")

        let ca = CertificateAuthority.shared
        do {
            try ca.prepareIfNeeded()
        } catch {
            let message = "{\"type\":\"error\",\"message\":\"\(error.localizedDescription)\"}\n"
            FileHandle.standardError.write(Data(message.utf8))
        }

        let sink = JSONLineCaptureSink(path: outputPath)
        let server = ProxyServer(
            port: port,
            sslProxyingEnabled: sslEnabled,
            sink: sink,
            certificateAuthority: ca
        )
        server.onStatusChange = { status in
            let value: String
            switch status {
            case .stopped: value = "stopped"
            case .starting: value = "starting"
            case .running(let port): value = "running:\(port)"
            case .failed(let message): value = "failed:\(message)"
            }
            print("{\"type\":\"status\",\"status\":\"\(value)\"}")
        }
        server.start()

        print("{\"type\":\"ready\",\"port\":\(port)}")

        if let exitAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + exitAfter) {
                server.stop()
                exit(0)
            }
        }
        dispatchMain()
    }
}
