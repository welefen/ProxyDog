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
        let upstream = flagValue("--upstream").flatMap { UpstreamProxy(string: $0) }
        let exitAfter = Double(flagValue("--exit-after") ?? "")

        if arguments.contains("--selftest") {
            exit(Self.runSelfTest(port: port) ? 0 : 1)
        }

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
        server.upstreamProxy = upstream
        if let upstream {
            print("{\"type\":\"upstream\",\"proxy\":\"\(upstream.displayName)\"}")
        }
        server.onStatusChange = { status in
            let value: String
            switch status {
            case .stopped: value = "stopped"
            case .starting: value = "starting"
            case .running(let port): value = "running:\(port)"
            case .failed(let message): value = "failed:\(message)"
            }
            print("{\"type\":\"status\",\"status\":\"\(value)\"}")
            switch status {
            case .running(let boundPort):
                print("{\"type\":\"ready\",\"port\":\(boundPort)}")
            case .failed:
                exit(1)
            default:
                break
            }
        }
        server.start()

        if let exitAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + exitAfter) {
                server.stop()
                exit(0)
            }
        }
        dispatchMain()
    }
}

extension HeadlessRunner {
    /// Verifies the pieces of the app that cannot be exercised through the GUI in a
    /// headless environment: certificate generation, HAR export and system proxy
    /// state detection. Prints one JSON line per check and returns overall success.
    static func runSelfTest(port: Int) -> Bool {
        var failures = 0

        func check(_ name: String, _ body: () throws -> String) {
            do {
                let detail = try body()
                print("{\"type\":\"selftest\",\"check\":\"\(name)\",\"ok\":true,\"detail\":\"\(detail)\"}")
            } catch {
                failures += 1
                print("{\"type\":\"selftest\",\"check\":\"\(name)\",\"ok\":false,\"detail\":\"\(error.localizedDescription)\"}")
            }
        }

        let ca = CertificateAuthority.shared

        check("certificate-authority") {
            try ca.prepareIfNeeded()
            _ = try ca.serverTLSContext(forHost: "example.com")
            let exists = FileManager.default.fileExists(atPath: ca.rootCertificateURL.path)
            guard exists else { throw ProxyError.certificateUnavailable }
            return "root=ca.crt leaf=example.com"
        }

        check("har-export") {
            let requests: [CapturedRequest] = [
                CapturedRequest(
                    method: "GET",
                    scheme: "https",
                    host: "api.example.com",
                    port: 443,
                    path: "/v1/users?page=2",
                    intercepted: true,
                    requestHeaders: [HeaderField(name: "Accept", value: "application/json")],
                    statusCode: 200,
                    responseHeaders: [HeaderField(name: "Content-Type", value: "application/json")],
                    responseBody: Data("{\"ok\":true}".utf8),
                    state: .completed
                ),
                CapturedRequest(
                    method: "POST",
                    scheme: "http",
                    host: "localhost",
                    port: 3000,
                    path: "/v1/session",
                    requestHeaders: [HeaderField(name: "Content-Type", value: "application/x-www-form-urlencoded")],
                    requestBody: Data("user=dev&token=abc".utf8),
                    statusCode: 401,
                    responseHeaders: [HeaderField(name: "Content-Type", value: "text/plain")],
                    responseBody: Data("unauthorized".utf8),
                    state: .completed
                ),
            ]
            let data = try HARExporter.makeHAR(requests: requests)
            guard let har = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let log = har["log"] as? [String: Any],
                  let entries = log["entries"] as? [[String: Any]],
                  entries.count == 2
            else {
                throw ProxyError.notImplemented
            }
            return "entries=\(entries.count) bytes=\(data.count)"
        }

        check("curl-export") {
            let request = CapturedRequest(
                method: "POST",
                scheme: "https",
                host: "httpbin.org",
                port: 443,
                path: "/post",
                requestHeaders: [HeaderField(name: "Authorization", value: "Bearer secret")],
                requestBody: Data("{\"a\":1}".utf8)
            )
            let command = CurlExporter.curlCommand(for: request)
            guard command.contains("curl"), !command.contains("Bearer secret") else {
                throw ProxyError.notImplemented
            }
            return "sensitive headers excluded"
        }

        check("proxy-restart-in-process") {
            let sink = NoopCaptureSink()
            let firstPort = try Self.freePort()
            let secondPort = try Self.freePort()
            let server = ProxyServer(port: firstPort, sslProxyingEnabled: true, sink: sink)
            server.start()
            guard case .running(let boundFirst) = Self.waitForStatus(server) { $0.isRunning }, boundFirst == firstPort else {
                throw ProxyError.bindFailed("first start did not reach running on \(firstPort)")
            }
            // Same sequence AppState.restartProxy uses: stop then start on a new port.
            server.port = secondPort
            server.stop()
            server.start()
            guard case .running(let boundSecond) = Self.waitForStatus(server) { $0.isRunning }, boundSecond == secondPort else {
                throw ProxyError.bindFailed("restart did not reach running on \(secondPort)")
            }
            server.stop()
            _ = Self.waitForStatus(server) { $0.isStopped }
            return "listened on \(firstPort) then \(secondPort)"
        }

        check("port-in-use") {
            let busyPort = try Self.freePort()
            let descriptor = try Self.bindSocket(port: busyPort)
            defer { close(descriptor) }
            let server = ProxyServer(port: busyPort, sslProxyingEnabled: false, sink: NoopCaptureSink())
            server.start()
            let status = Self.waitForStatus(server) { $0.isFailed }
            server.stop()
            guard case .failed(let message) = status else {
                throw ProxyError.bindFailed("expected a failed status for an occupied port")
            }
            return message
        }

        check("system-proxy-state") {
            let enabled = SystemProxy.isEnabled(port: port)
            return "enabled=\(enabled)"
        }

        check("settings-persistence") {
            try MainActor.assumeIsolated {
                let suite = "com.proxydog.selftest.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                let settings = AppSettings(defaults: defaults)
                settings.port = 9123
                settings.appearance = .dark
                let reloaded = AppSettings(defaults: defaults)
                defaults.removePersistentDomain(forName: suite)
                guard reloaded.port == 9123, reloaded.appearance == .dark else {
                    throw ProxyError.notImplemented
                }
                return "port=\(reloaded.port) appearance=\(reloaded.appearance.rawValue)"
            }
        }

        print("{\"type\":\"selftest\",\"done\":true,\"failures\":\(failures)}")
        return failures == 0
    }
}

/// Capture sink for self-test proxy instances.
final class NoopCaptureSink: CaptureSink, @unchecked Sendable {
    func captureDidUpdate(_ request: CapturedRequest) {}
}

extension HeadlessRunner {
    /// Spins the main run loop until the proxy reaches a matching status or times out.
    static func waitForStatus(
        _ server: ProxyServer,
        timeout: TimeInterval = 5,
        matching predicate: (ProxyServer.Status) -> Bool
    ) -> ProxyServer.Status {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if predicate(server.status) {
                return server.status
            }
        }
        return server.status
    }

    /// Returns a currently free loopback TCP port.
    static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProxyError.bindFailed("socket() failed") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ProxyError.bindFailed("bind() failed while looking for a free port") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else { throw ProxyError.bindFailed("getsockname() failed") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Binds and listens on the given port so another bind fails with EADDRINUSE.
    static func bindSocket(port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProxyError.bindFailed("socket() failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw ProxyError.bindFailed("could not occupy port \(port)")
        }
        return descriptor
    }
}
