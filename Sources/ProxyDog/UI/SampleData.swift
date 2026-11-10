import AppKit
import SwiftUI

// MARK: - Development launch options
//
// Everything in this file is inert unless the app is launched with an explicit
// development flag (e.g. `./scripts/run_app.sh --sample-traffic`). The default
// launch never touches it, so it is safe to keep around for QA and screenshots.

enum DevLaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isSampleTrafficEnabled: Bool {
        arguments.contains("--sample-traffic")
            || ProcessInfo.processInfo.environment["PROXYDOG_SAMPLE_TRAFFIC"] == "1"
    }

    static var sampleRequestIndex: Int? {
        value(for: "--sample-request").flatMap(Int.init)
    }

    static var initialTab: DetailTab? {
        switch value(for: "--sample-tab") {
        case "overview": return .overview
        case "headers": return .headers
        case "body": return .body
        case "messages": return .messages
        default: return nil
        }
    }

    /// Preselects a WebSocket message (0-based) for screenshot/QA runs.
    static var sampleMessageIndex: Int? {
        value(for: "--sample-message").flatMap(Int.init)
    }

    /// Preselects a request type filter (RequestCategory raw value) for screenshots.
    static var initialTypeFilter: RequestCategory? {
        value(for: "--sample-filter").flatMap(RequestCategory.init(rawValue:))
    }

    /// QA probe: sends one analytics event a few seconds after launch so the
    /// self-request filter can be tested while the system proxy points at ProxyDog.
    static var analyticsProbeEnabled: Bool {
        arguments.contains("--analytics-probe")
    }

    /// Stress-test mode: number of synthetic captures to load (e.g. `--sample-stress 10000`).
    static var stressCount: Int? {
        value(for: "--sample-stress").flatMap(Int.init)
    }

    /// Accepts both `--flag=value` and the `open --args --flag value` spelling.
    private static func value(for flag: String) -> String? {
        let prefix = flag + "="
        if let argument = arguments.first(where: { $0.hasPrefix(prefix) }) {
            return String(argument.dropFirst(prefix.count))
        }
        if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        return nil
    }
}

// MARK: - Sample traffic
//
// Mock rows used only with `--sample-traffic` so the main window can be designed
// and screenshotted before the proxy engine produces real captures. The rows are
// injected through CaptureStore's public API, never through a UI-only code path.

@MainActor
enum SampleTraffic {
    private static var didLoad = false

    /// Dev-only probes that need the app running (currently just the self-request filter
    /// check). Inert unless an explicit flag is passed.
    static func runDevProbesIfNeeded() {
        guard DevLaunchOptions.analyticsProbeEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            Analytics.shared.track("probe_self_request")
            FileHandle.standardError.write(Data("[probe] sent analytics probe event\n".utf8))
        }
    }

    static func bootstrapIfRequested(state: AppState) {
        guard DevLaunchOptions.isSampleTrafficEnabled, !didLoad else { return }
        didLoad = true
        load(into: state)
    }

    private static func load(into state: AppState) {
        var stress = false
        let started = Date()
        if let count = DevLaunchOptions.stressCount {
            stress = true
            // QA mode: bypass the default 2 000-entry ring so large-traffic behaviour can be
            // measured. The store prepends, so insert oldest first.
            state.store.capacity = max(count, state.store.capacity)
            let buildStart = Date()
            let generated = makeStressRequests(count: count)
            let buildMs = Int(Date().timeIntervalSince(buildStart) * 1000)
            let upsertStart = Date()
            state.store.loadBatch(generated)
            let upsertMs = Int(Date().timeIntervalSince(upsertStart) * 1000)
            let line = "[stress] generated \(generated.count) rows in \(buildMs) ms; "
                + "loaded in \(upsertMs) ms\n"
            FileHandle.standardError.write(Data(line.utf8))
        } else {
            // The store prepends, so insert oldest first to keep newest traffic on top.
            for request in makeRequests().reversed() {
                state.store.upsert(request)
            }
        }
        if stress {
            let loadMs = Int(Date().timeIntervalSince(started) * 1000)

            let filterStart = Date()
            let filtered = state.filteredRequests
            let filterMs = Int(Date().timeIntervalSince(filterStart) * 1000)

            let summaryStart = Date()
            let clients = state.clientSummaries.count
            let domains = state.domainSummaries.count
            let summaryMs = Int(Date().timeIntervalSince(summaryStart) * 1000)

            stressProbe(state: state)
            let line = "[stress] loaded \(state.store.requests.count) rows in \(loadMs) ms; "
                + "filteredRequests \(filtered.count) in \(filterMs) ms; "
                + "summaries (\(clients) clients, \(domains) domains) in \(summaryMs) ms\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        if let filter = DevLaunchOptions.initialTypeFilter {
            state.typeFilter = filter
        }
        let items = state.filteredRequests
        guard !items.isEmpty else { return }
        if let index = DevLaunchOptions.sampleRequestIndex, items.indices.contains(index) {
            state.selectionID = items[index].id
        } else {
            state.selectionID = items.first?.id
        }
    }

    // MARK: Requests

    /// Measures the main-thread cost of the operations a user triggers while a large
    /// capture buffer is loaded (layout passes, filtering, selection).
    private static func stressProbe(state: AppState) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first, let content = window.contentView else {
            return
        }

        func measure(_ label: String, _ body: () -> Void) -> Int {
            let started = Date()
            body()
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            return Int(Date().timeIntervalSince(started) * 1000)
        }

        var report: [String] = []
        report.append("initial layout \(measure("initial") {}) ms")
        report.append("filter 'github' \(measure("filter") { state.searchText = "github" }) ms")
        report.append("clear filter \(measure("clear") { state.searchText = "" }) ms")

        let items = state.filteredRequests
        if let target = items.dropFirst(items.count / 2).first {
            report.append("select middle row \(measure("select") { state.selectionID = target.id }) ms")
        }
        report.append("deselect \(measure("deselect") { state.selectionID = nil }) ms")
        report.append("counts \(measure("counts") { _ = state.filteredRequests.count; _ = state.allRequests.count }) ms")

        report.append("footprint \(currentFootprintMB()) MB")
        FileHandle.standardError.write(Data("[stress-probe] \(report.joined(separator: " | "))\n".utf8))
    }

    /// Physical memory footprint of the app, in MB.
    private static func currentFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(Double(info.phys_footprint) / 1_048_576)
    }

    private static func makeStressRequests(count: Int) -> [CapturedRequest] {
        let domains = [
            "api.github.com", "api.stripe.com", "cdn.jsdelivr.net", "www.apple.com",
            "cdn.example.com", "api.example.com", "fonts.gstatic.com", "analytics.example.com",
            "api.segment.io", "app.example.com", "www.google.com", "chat.openai.com",
            "mcs.doubao.com", "www.baidu.com", "play.google.com", "api.linear.app",
        ]
        let clients: [(String, Int32, String)] = [
            ("Safari", 1201, "/Applications/Safari.app/Contents/MacOS/Safari"),
            ("Google Chrome", 1202, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            ("curl", 1203, "/usr/bin/curl"),
            ("Slack", 1204, "/Applications/Slack.app/Contents/MacOS/Slack"),
        ]
        let kinds: [(String, String)] = [
            ("GET", "application/json"),
            ("POST", "application/json"),
            ("GET", "text/html; charset=utf-8"),
            ("GET", "text/css"),
            ("GET", "application/javascript"),
            ("GET", "image/png"),
            ("GET", "font/woff2"),
            ("GET", "application/wasm"),
        ]
        let statuses = [200, 200, 200, 200, 304, 404, 500, 201]

        var requests: [CapturedRequest] = []
        requests.reserveCapacity(count)
        for index in 0..<count {
            let domain = domains[index % domains.count]
            let client = clients[index % clients.count]
            let kind = kinds[index % kinds.count]
            let status = statuses[index % statuses.count]
            let isJSON = kind.1.contains("json")
            let body: Data? = isJSON && index % 3 == 0
                ? Data("[{\"index\": \(index), \"ok\": true, \"name\": \"row-\(index)\"}]".utf8)
                : nil
            let request = self.request(
                kind.0,
                "https://\(domain)/v1/resource/\(index)?page=\(index / 50)&client=\(client.0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "app")",
                status: status,
                duration: Double(index % 900) / 1000,
                secondsAgo: Double(count - index),
                requestHeaders: headers([
                    ("Host", domain),
                    ("User-Agent", "\(client.0)/\(index % 100)"),
                    ("Accept", "*/*"),
                ]),
                responseHeaders: headers([
                    ("Server", "nginx"),
                    ("Content-Type", kind.1),
                    ("Content-Length", "\(body?.count ?? (index % 2048))"),
                ]),
                responseBody: body,
                client: client.0,
                clientPID: client.1,
                clientAppName: client.0,
                clientAppPath: client.2,
                isWebSocket: false
            )
            requests.append(request)
        }
        return requests
    }

    private static func makeRequests() -> [CapturedRequest] {
        let image = previewImageData()

        var requests: [CapturedRequest] = []

        // Newest first once inserted into the store (which prepends).
        requests.append(request(
            "GET",
            "https://api.github.com/repos/proxydog/proxydog/releases/latest",
            status: 200,
            duration: 0.186,
            secondsAgo: 2,
            requestHeaders: headers([
                ("Host", "api.github.com"),
                ("User-Agent", "ProxyDog/1.0 (macOS 14.4)"),
                ("Accept", "application/vnd.github+json"),
                ("Accept-Encoding", "gzip, deflate, br"),
                ("Authorization", "Bearer ghp_x9K4mQ2rT7vB1nL8sW3cY6pD5fH0jA2e"),
                ("X-GitHub-Api-Version", "2022-11-28"),
            ]),
            responseHeaders: headers([
                ("Server", "GitHub.com"),
                ("Content-Type", "application/json; charset=utf-8"),
                ("Cache-Control", "public, max-age=60, s-maxage=60"),
                ("ETag", "W/\"7d3f9c2b8e1a4f6d0c5e9a2b7f1d8c3e\""),
                ("X-RateLimit-Limit", "5000"),
                ("X-RateLimit-Remaining", "4987"),
                ("X-GitHub-Request-Id", "E8F2:1A3C:2B7D9:4C1E6"),
            ]),
            responseBody: jsonData([
                "id": 48219311,
                "name": "proxydog",
                "full_name": "proxydog/proxydog",
                "private": false,
                "owner": [
                    "login": "welefen",
                    "id": 918233,
                    "type": "User",
                    "site_admin": false,
                ],
                "html_url": "https://github.com/proxydog/proxydog",
                "description": "Native macOS HTTP and HTTPS debugging proxy",
                "topics": ["http", "https", "proxy", "developer-tools", "macos"],
                "stargazers_count": 1284,
                "watchers_count": 1284,
                "language": "Swift",
                "default_branch": "main",
                "pushed_at": "2026-11-10T02:14:07Z",
                "latest_release": [
                    "tag_name": "v1.2.0",
                    "published_at": "2026-11-08T09:12:00Z",
                    "assets": [
                        [
                            "name": "ProxyDog-1.2.0.dmg",
                            "size": 14832104,
                            "download_count": 4210,
                        ]
                    ],
                ],
                "permissions": ["admin": false, "push": true, "pull": true],
            ]),
            pinned: true,
            httpVersion: "HTTP/2",
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "POST",
            "https://api.stripe.com/v1/charges",
            status: 201,
            duration: 0.412,
            secondsAgo: 7,
            requestHeaders: headers([
                ("Host", "api.stripe.com"),
                ("User-Agent", "ProxyDog/1.0 (macOS 14.4)"),
                ("Accept", "application/json"),
                ("Content-Type", "application/json"),
                ("Content-Length", "182"),
                ("Authorization", "Bearer sk_live_51Nx8kL2eZvKYlo2C1qR7"),
            ]),
            requestBody: jsonData([
                "amount": 2499,
                "currency": "usd",
                "description": "ProxyDog Pro, annual",
                "customer": "cus_Q2f8sK1nT4wL",
                "metadata": ["source": "mac-app", "version": "1.2.0"],
            ]),
            responseHeaders: headers([
                ("Server", "nginx"),
                ("Content-Type", "application/json"),
                ("Content-Length", "412"),
                ("Cache-Control", "no-cache, no-store"),
                ("Request-Id", "req_9pQ2mX4vT7bL1nS8"),
                ("Stripe-Version", "2024-06-20"),
            ]),
            responseBody: jsonData([
                "id": "ch_3P8kL2eZvKYlo2C1",
                "object": "charge",
                "amount": 2499,
                "currency": "usd",
                "status": "succeeded",
                "paid": true,
                "captured": true,
                "receipt_url": "https://pay.stripe.com/receipts/ch_3P8kL2eZvKYlo2C1",
                "payment_method_details": [
                    "type": "card",
                    "card": [
                        "brand": "visa",
                        "last4": "4242",
                        "exp_month": 11,
                        "exp_year": 2029,
                        "network": "visa",
                    ],
                ],
            ]),
            client: "ProxyDog/1.0",
            clientPID: 5678,
            clientAppName: "ProxyDog",
            clientAppPath: proxyDogExecutablePath
        ))

        // WebSocket exchange (101 + live message stream); index 2 in the sample list.
        var socket = request(
            "GET",
            "https://api.example.com/v1/socket",
            status: 101,
            duration: 4.82,
            secondsAgo: 9,
            requestHeaders: headers([
                ("Host", "api.example.com"),
                ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"),
                ("Origin", "https://app.example.com"),
                ("Upgrade", "websocket"),
                ("Connection", "Upgrade"),
                ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
                ("Sec-WebSocket-Version", "13"),
                ("Sec-WebSocket-Protocol", "graphql-ws"),
                ("Sec-WebSocket-Extensions", "permessage-deflate; client_max_window_bits"),
            ]),
            responseHeaders: headers([
                ("Server", "envoy"),
                ("Upgrade", "websocket"),
                ("Connection", "Upgrade"),
                ("Sec-WebSocket-Accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
                ("Sec-WebSocket-Protocol", "graphql-ws"),
                ("Date", "Mon, 10 Nov 2026 05:00:00 GMT"),
                ("X-Request-Id", "req_7c3d9f12"),
            ]),
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari",
            isWebSocket: true
        )
        socket.webSocketMessages = webSocketMessages(startedAt: socket.startedAt)
        requests.append(socket)

        requests.append(request(
            "GET",
            "https://api.github.com/user",
            status: 401,
            duration: 0.094,
            secondsAgo: 12,
            requestHeaders: headers([
                ("Host", "api.github.com"),
                ("User-Agent", "ProxyDog/1.0 (macOS 14.4)"),
                ("Accept", "application/vnd.github+json"),
                ("Authorization", "Bearer ghp_expired_7d2a1f"),
            ]),
            responseHeaders: headers([
                ("Server", "GitHub.com"),
                ("Content-Type", "application/json; charset=utf-8"),
                ("Cache-Control", "no-cache"),
                ("X-GitHub-Request-Id", "C4A1:2F8B:7D2E6:9A1C3"),
            ]),
            responseBody: jsonData([
                "message": "Requires authentication",
                "documentation_url": "https://docs.github.com/rest/users/users",
                "status": "401",
            ]),
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "GET",
            "https://api.example.com/v1/users?page=2&limit=25",
            status: 404,
            duration: 0.128,
            secondsAgo: 18,
            requestHeaders: headers([
                ("Host", "api.example.com"),
                ("User-Agent", "ProxyDog/1.0 (macOS 14.4)"),
                ("Accept", "application/json"),
                ("Authorization", "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI0MiJ9"),
            ]),
            responseHeaders: headers([
                ("Server", "envoy"),
                ("Content-Type", "application/json"),
                ("Cache-Control", "no-store"),
                ("X-Request-Id", "req_8f21c4a9e7b3"),
            ]),
            responseBody: jsonData([
                "error": [
                    "code": "not_found",
                    "message": "User not found",
                    "request_id": "req_8f21c4a9e7b3",
                ]
            ]),
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "GET",
            "https://cdn.jsdelivr.net/npm/react@18.2.0/index.js",
            status: 200,
            duration: 0.061,
            secondsAgo: 25,
            requestHeaders: headers([
                ("Host", "cdn.jsdelivr.net"),
                ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"),
                ("Accept", "*/*"),
                ("Accept-Encoding", "gzip, deflate, br"),
                ("Referer", "https://example.com/"),
            ]),
            responseHeaders: headers([
                ("Server", "cloudflare"),
                ("Content-Type", "application/javascript; charset=utf-8"),
                ("Content-Length", "736"),
                ("Cache-Control", "public, max-age=31536000, immutable"),
                ("Access-Control-Allow-Origin", "*"),
                ("X-Content-Type-Options", "nosniff"),
                ("CF-Cache-Status", "HIT"),
            ]),
            responseBody: Data("""
            'use strict';
            Object.defineProperty(exports, '__esModule', { value: true });
            var ReactVersion = '18.2.0';
            const INTERNAL_ACTIONS = Symbol.for('react.element');
            function createElement(type, config, children) {
              const props = {};
              if (config != null) {
                for (const key in config) {
                  props[key] = config[key];
                }
              }
              const childrenLength = arguments.length - 2;
              if (childrenLength === 1) props.children = children;
              if (childrenLength > 1) {
                const childArray = Array(childrenLength);
                for (let i = 0; i < childrenLength; i++) childArray[i] = arguments[i + 2];
                props.children = childArray;
              }
              return { $$typeof: INTERNAL_ACTIONS, type, key, ref, props };
            }
            exports.createElement = createElement;
            //# sourceMappingURL=index.js.map
            """.utf8),
            httpVersion: "HTTP/2",
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "GET",
            "https://www.apple.com/",
            status: 200,
            duration: 0.238,
            secondsAgo: 34,
            requestHeaders: headers([
                ("Host", "www.apple.com"),
                ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"),
                ("Accept", "text/html,application/xhtml+xml"),
                ("Accept-Language", "en-US,en;q=0.9"),
                ("Accept-Encoding", "gzip, deflate, br"),
            ]),
            responseHeaders: headers([
                ("Server", "Apple"),
                ("Content-Type", "text/html; charset=utf-8"),
                ("Content-Length", "512"),
                ("Cache-Control", "max-age=315, public"),
                ("Strict-Transport-Security", "max-age=31536000"),
                ("X-Content-Type-Options", "nosniff"),
                ("Alt-Svc", "h3=\":443\"; ma=86400"),
            ]),
            responseBody: Data("""
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>Apple</title>
              <link rel="stylesheet" href="/wss/fonts/fonts.css">
            </head>
            <body>
              <main class="homepage">
                <section class="hero">
                  <h1>MacBook Pro</h1>
                  <p>Mind blowing. Supercharged by M4.</p>
                  <a href="/shop/buy-mac/macbook-pro">Buy</a>
                </section>
              </main>
            </body>
            </html>
            """.utf8),
            httpVersion: "HTTP/2",
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "GET",
            "https://cdn.example.com/assets/dashboard.png",
            status: 200,
            duration: 0.073,
            secondsAgo: 41,
            requestHeaders: headers([
                ("Host", "cdn.example.com"),
                ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"),
                ("Accept", "image/avif,image/webp,image/png,image/*"),
                ("Referer", "https://example.com/dashboard"),
            ]),
            responseHeaders: headers([
                ("Server", "cloudfront"),
                ("Content-Type", "image/png"),
                ("Content-Length", "\(image.count)"),
                ("Cache-Control", "public, max-age=86400"),
                ("ETag", "\"a41f2c9d7b3e\""),
                ("X-Amz-Cf-Id", "F7h2Ks9Lm4Qp8Rt1Vw6Yz3Nb5Xc0Dg"),
            ]),
            responseBody: image,
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "GET",
            "https://cdn.example.com/media/launch-trailer.mp4",
            status: 200,
            duration: 0.412,
            secondsAgo: 45,
            requestHeaders: headers([
                ("Host", "cdn.example.com"),
                ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"),
                ("Accept", "video/mp4,video/webm,*/*"),
                ("Range", "bytes=0-1048575"),
            ]),
            responseHeaders: headers([
                ("Server", "cloudfront"),
                ("Content-Type", "video/mp4"),
                ("Content-Range", "bytes 0-1048575/12582912"),
                ("Accept-Ranges", "bytes"),
                ("Cache-Control", "public, max-age=3600"),
            ]),
            responseBody: mediaBody,
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "GET",
            "https://app.example.com/static/engine.wasm",
            status: 200,
            duration: 0.038,
            secondsAgo: 52,
            requestHeaders: headers([
                ("Host", "app.example.com"),
                ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"),
                ("Accept", "application/wasm"),
                ("Accept-Encoding", "gzip, deflate, br"),
            ]),
            responseHeaders: headers([
                ("Server", "nginx"),
                ("Content-Type", "application/wasm"),
                ("Content-Length", "\(wasmBody.count)"),
                ("Cache-Control", "public, max-age=31536000, immutable"),
            ]),
            responseBody: wasmBody,
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "GET",
            "https://fonts.gstatic.com/s/inter/v13/UcC73FwrK3iLTeHuS_fvQtMwCp50KnMa1ZL7.woff2",
            status: 200,
            duration: 0.044,
            secondsAgo: 49,
            requestHeaders: headers([
                ("Host", "fonts.gstatic.com"),
                ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"),
                ("Accept", "font/woff2,*/*"),
                ("Referer", "https://www.apple.com/"),
            ]),
            responseHeaders: headers([
                ("Server", "gws"),
                ("Content-Type", "font/woff2"),
                ("Content-Length", "\(binaryBody.count)"),
                ("Cache-Control", "public, max-age=31536000"),
                ("Access-Control-Allow-Origin", "*"),
            ]),
            responseBody: binaryBody,
            httpVersion: "HTTP/2",
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "GET",
            "https://api.example.com/health",
            status: 200,
            duration: 0.021,
            secondsAgo: 58,
            requestHeaders: headers([
                ("Host", "api.example.com"),
                ("User-Agent", "healthcheck/1.4"),
                ("Accept", "text/plain"),
            ]),
            responseHeaders: headers([
                ("Server", "envoy"),
                ("Content-Type", "text/plain; charset=utf-8"),
                ("Content-Length", "38"),
                ("Cache-Control", "no-store"),
            ]),
            responseBody: Data("status: ok\nuptime: 184h22m\nregion: us-east-1\n".utf8),
            client: "healthcheck/1.4"
        ))

        requests.append(request(
            "GET",
            "https://api.segment.io/v1/track",
            state: .pending,
            secondsAgo: 1.2,
            requestHeaders: headers([
                ("Host", "api.segment.io"),
                ("User-Agent", "ProxyDog/1.0 (macOS 14.4)"),
                ("Content-Type", "application/json"),
            ]),
            requestBody: jsonData([
                "event": "app_launched",
                "properties": ["appearance": "system", "ssl_enabled": true],
            ]),
            client: "ProxyDog/1.0",
            clientPID: 5678,
            clientAppName: "ProxyDog",
            clientAppPath: proxyDogExecutablePath
        ))

        requests.append(request(
            "GET",
            "http://localhost:3000/api/session",
            status: 200,
            state: .tunneled,
            secondsAgo: 66,
            requestHeaders: headers([
                ("Host", "localhost:3000"),
                ("User-Agent", "node-fetch/3.3.2"),
                ("Accept", "application/json"),
            ]),
            intercepted: false,
            client: "node-fetch/3.3.2",
            clientPID: 8891,
            clientAppName: "node",
            clientAppPath: nodeExecutablePath
        ))

        requests.append(request(
            "POST",
            "https://analytics.example.com/v1/collect",
            status: 204,
            duration: 0.037,
            secondsAgo: 74,
            requestHeaders: headers([
                ("Host", "analytics.example.com"),
                ("User-Agent", "ProxyDog/1.0 (macOS 14.4)"),
                ("Content-Type", "application/json"),
                ("Content-Length", "64"),
            ]),
            requestBody: jsonData(["event": "traffic_cleared", "count": 0]),
            responseHeaders: headers([
                ("Server", "envoy"),
                ("Cache-Control", "no-store"),
                ("X-Request-Id", "req_1d8c4b2a"),
            ]),
            client: "ProxyDog/1.0",
            clientPID: 5678,
            clientAppName: "ProxyDog",
            clientAppPath: proxyDogExecutablePath
        ))

        requests.append(request(
            "GET",
            "https://api.example.com/v1/sync",
            status: 500,
            duration: 2.36,
            secondsAgo: 82,
            requestHeaders: headers([
                ("Host", "api.example.com"),
                ("User-Agent", "ProxyDog/1.0 (macOS 14.4)"),
                ("Accept", "application/json"),
                ("Authorization", "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI0MiJ9"),
            ]),
            responseHeaders: headers([
                ("Server", "envoy"),
                ("Content-Type", "application/json"),
                ("Cache-Control", "no-store"),
                ("X-Request-Id", "req_5b9a1f7c"),
            ]),
            responseBody: jsonData([
                "error": [
                    "code": "internal_error",
                    "message": "Upstream timed out while syncing record",
                    "retry_after": 30,
                ]
            ]),
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))

        requests.append(request(
            "GET",
            "http://example.com/",
            status: 301,
            duration: 0.052,
            secondsAgo: 95,
            requestHeaders: headers([
                ("Host", "example.com"),
                ("User-Agent", "curl/8.4.0"),
                ("Accept", "*/*"),
            ]),
            responseHeaders: headers([
                ("Server", "cloudflare"),
                ("Content-Type", "text/html"),
                ("Location", "https://example.com/"),
                ("Cache-Control", "max-age=3600"),
            ]),
            client: "curl/8.4.0",
            clientPID: 4412,
            clientAppName: "curl",
            clientAppPath: "/usr/bin/curl"
        ))

        requests.append(request(
            "GET",
            "https://proxy-dog-unreachable.invalid/api/health",
            state: .failed,
            secondsAgo: 108,
            requestHeaders: headers([
                ("Host", "proxy-dog-unreachable.invalid"),
                ("User-Agent", "ProxyDog/1.0 (macOS 14.4)"),
                ("Accept", "application/json"),
            ]),
            client: "Safari 17.4",
            clientPID: 1234,
            clientAppName: "Safari",
            clientAppPath: "/Applications/Safari.app/Contents/MacOS/Safari",
            error: "Could not resolve host: nodename nor servname provided, or not known"
        ))

        return requests
    }

    // MARK: Helpers

    private static func request(
        _ method: String,
        _ urlString: String,
        status: Int? = nil,
        state: CaptureState = .completed,
        duration: TimeInterval? = nil,
        secondsAgo: TimeInterval,
        requestHeaders: [HeaderField] = [],
        requestBody: Data? = nil,
        responseHeaders: [HeaderField] = [],
        responseBody: Data? = nil,
        intercepted: Bool = true,
        pinned: Bool = false,
        httpVersion: String = "HTTP/1.1",
        client: String? = nil,
        clientPID: Int32? = nil,
        clientAppName: String? = nil,
        clientAppPath: String? = nil,
        error: String? = nil,
        isWebSocket: Bool = false,
        webSocketMessages: [WebSocketMessage] = []
    ) -> CapturedRequest {
        let components = URLComponents(string: urlString)
        let scheme = components?.scheme ?? "https"
        let host = components?.host ?? "example.com"
        let isSecure = scheme == "https"
        let port = components?.port ?? (isSecure ? 443 : 80)
        var path = components?.path ?? "/"
        if let query = components?.query, !query.isEmpty {
            path += "?" + query
        }
        let started = Date().addingTimeInterval(-secondsAgo)
        let finished = duration.map { started.addingTimeInterval($0) }

        var captured = CapturedRequest(
            startedAt: started,
            method: method,
            httpVersion: httpVersion,
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            intercepted: intercepted,
            requestHeaders: requestHeaders,
            requestBody: requestBody,
            statusCode: status,
            responseHeaders: responseHeaders,
            responseBody: responseBody,
            state: state,
            errorMessage: error,
            isPinned: pinned,
            clientSignature: client,
            clientPID: clientPID,
            clientAppName: clientAppName,
            clientAppPath: clientAppPath,
            webSocketMessages: webSocketMessages,
            isWebSocket: isWebSocket
        )
        captured.finishedAt = finished
        return captured
    }

    private static func headers(_ pairs: [(String, String)]) -> [HeaderField] {
        pairs.map { HeaderField(name: $0.0, value: $0.1) }
    }

    private static func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Sample WebSocket frames: JSON text both ways, a binary frame, ping/pong and
    /// close control frames, plus one 600 KB binary frame captured truncated.
    private static func webSocketMessages(startedAt: Date) -> [WebSocketMessage] {
        func message(
            _ direction: WebSocketDirection,
            _ kind: WebSocketMessageKind,
            _ offset: TimeInterval,
            _ payload: Data?,
            byteCount: Int? = nil,
            truncated: Bool = false
        ) -> WebSocketMessage {
            WebSocketMessage(
                direction: direction,
                kind: kind,
                timestamp: startedAt.addingTimeInterval(offset),
                payload: payload,
                byteCount: byteCount ?? payload?.count ?? 0,
                truncated: truncated
            )
        }

        let connectionInit = jsonData([
            "type": "connection_init",
            "payload": [
                "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiJ9",
                "client": "Safari 17.4",
                "locale": "en-US",
            ],
        ])
        let connectionAck = jsonData([
            "type": "connection_ack",
            "payload": [
                "session_id": "sess_9f31c2",
                "heartbeat_interval": 15000,
            ],
        ])
        let subscriptionStart = jsonData([
            "id": "1",
            "type": "start",
            "payload": [
                "query": "subscription OnOrderEvent { orderEvents { id type amount currency ts } }",
                "variables": ["channel": "orders", "region": "us-east-1"],
            ],
        ])
        let firstEvent = jsonData([
            "id": "1",
            "type": "data",
            "payload": [
                "data": [
                    "orderEvents": [
                        [
                            "id": "evt_8241",
                            "type": "order.created",
                            "amount": 2499,
                            "currency": "usd",
                            "ts": "2026-11-10T05:00:00.412Z",
                        ]
                    ]
                ]
            ],
        ])
        let secondEvent = jsonData([
            "id": "1",
            "type": "data",
            "payload": [
                "data": [
                    "orderEvents": [
                        [
                            "id": "evt_8242",
                            "type": "order.paid",
                            "amount": 2499,
                            "currency": "usd",
                            "ts": "2026-11-10T05:00:00.901Z",
                        ]
                    ]
                ]
            ],
        ])

        var binaryFrame = Data()
        for index in 0..<28 {
            binaryFrame.append(UInt8((index &* 43 &+ 7) % 256))
        }

        let truncatedBytes = 4096
        let truncatedPayload = Data((0..<truncatedBytes).map { UInt8(($0 &* 29 &+ 5) % 256) })
        let closePayload = Data([0x03, 0xE8])

        return [
            message(.sent, .text, 0.02, connectionInit),
            message(.received, .text, 0.08, connectionAck),
            message(.sent, .text, 0.11, subscriptionStart),
            message(.received, .text, 0.44, firstEvent),
            message(.received, .binary, 0.68, binaryFrame),
            message(.sent, .ping, 1.22, nil),
            message(.received, .pong, 1.26, nil),
            message(.received, .text, 1.94, secondEvent),
            message(.received, .binary, 2.18, truncatedPayload, byteCount: 614_400, truncated: true),
            message(.sent, .close, 4.66, closePayload),
            message(.received, .close, 4.80, closePayload),
        ]
    }

    /// Executable path of the running ProxyDog bundle, so the sample resolves a logo.
    private static var proxyDogExecutablePath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/ProxyDog"
    }

    /// First Node.js binary that exists on this machine (homebrew vs system installs).
    private static var nodeExecutablePath: String {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    /// Deterministic binary payload that stands in for a video frame.
    private static var mediaBody: Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(2048)
        for index in 0..<2048 {
            bytes.append(UInt8((index &* 17 &+ 3) % 256))
        }
        return Data(bytes)
    }

    /// Deterministic binary payload that stands in for a wasm module.
    private static var wasmBody: Data {
        var bytes: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
        for index in 0..<504 {
            bytes.append(UInt8((index &* 31 &+ 13) % 256))
        }
        return Data(bytes)
    }

    /// Deterministic binary payload that stands in for a font file.
    private static var binaryBody: Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(1536)
        for index in 0..<1536 {
            bytes.append(UInt8((index &* 37 &+ 11) % 256))
        }
        return Data(bytes)
    }

    /// Renders a small, abstract dashboard image for the image body preview.
    private static func previewImageData() -> Data {
        let size = NSSize(width: 720, height: 420)
        let image = NSImage(size: size)
        image.lockFocus()

        let background = NSColor(srgbRed: 0.09, green: 0.11, blue: 0.14, alpha: 1)
        background.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let chrome = NSColor(srgbRed: 0.13, green: 0.16, blue: 0.20, alpha: 1)
        chrome.setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 364, width: 672, height: 32), xRadius: 7, yRadius: 7).fill()

        NSColor(srgbRed: 0.18, green: 0.21, blue: 0.26, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 40, y: 374, width: 12, height: 12)).fill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 374, width: 12, height: 12)).fill()
        NSBezierPath(ovalIn: NSRect(x: 80, y: 374, width: 12, height: 12)).fill()

        let card = NSColor(srgbRed: 0.15, green: 0.18, blue: 0.23, alpha: 1)
        let accent = NSColor(srgbRed: 0.14, green: 0.39, blue: 0.92, alpha: 1)
        let muted = NSColor(srgbRed: 0.36, green: 0.41, blue: 0.49, alpha: 1)
        let grid = NSColor(srgbRed: 0.20, green: 0.24, blue: 0.30, alpha: 1)

        for index in 0..<3 {
            let x = CGFloat(24 + index * 232)
            card.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 244, width: 208, height: 96), xRadius: 7, yRadius: 7).fill()
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 16, y: 300, width: 48, height: 6), xRadius: 3, yRadius: 3).fill()
            muted.setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 16, y: 268, width: 120, height: 8), xRadius: 4, yRadius: 4).fill()
            NSBezierPath(roundedRect: NSRect(x: x + 16, y: 252, width: 76, height: 6), xRadius: 3, yRadius: 3).fill()
        }

        // Grid
        grid.setStroke()
        for step in 0..<5 {
            let y = CGFloat(40 + step * 44)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 24, y: y))
            line.line(to: NSPoint(x: 696, y: y))
            line.lineWidth = 1
            line.stroke()
        }

        // Chart line
        accent.setStroke()
        let chart = NSBezierPath()
        chart.lineWidth = 2
        let points: [NSPoint] = [
            NSPoint(x: 24, y: 70),
            NSPoint(x: 136, y: 128),
            NSPoint(x: 248, y: 96),
            NSPoint(x: 360, y: 168),
            NSPoint(x: 472, y: 142),
            NSPoint(x: 584, y: 196),
            NSPoint(x: 696, y: 176),
        ]
        chart.move(to: points[0])
        for point in points.dropFirst() {
            chart.line(to: point)
        }
        chart.stroke()

        accent.withAlphaComponent(0.85).setFill()
        for point in points {
            NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        }

        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
}
