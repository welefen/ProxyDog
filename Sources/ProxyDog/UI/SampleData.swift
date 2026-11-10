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
        default: return nil
        }
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

    static func bootstrapIfRequested(state: AppState) {
        guard DevLaunchOptions.isSampleTrafficEnabled, !didLoad else { return }
        didLoad = true
        load(into: state)
    }

    private static func load(into state: AppState) {
        // The store prepends, so insert oldest first to keep newest traffic on top.
        for request in makeRequests().reversed() {
            state.store.upsert(request)
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
            client: "Safari 17.4"
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
            client: "ProxyDog/1.0"
        ))

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
            client: "Safari 17.4"
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
            client: "Safari 17.4"
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
            client: "Safari 17.4"
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
            client: "Safari 17.4"
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
            client: "Safari 17.4"
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
            client: "Safari 17.4"
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
            client: "ProxyDog/1.0"
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
            client: "node-fetch/3.3.2"
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
            client: "ProxyDog/1.0"
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
            client: "Safari 17.4"
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
            client: "curl/8.4.0"
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
        client: String? = nil,
        error: String? = nil
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
            clientSignature: client
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
