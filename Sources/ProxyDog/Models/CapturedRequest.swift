import Foundation

/// Lifecycle of a captured exchange.
enum CaptureState: String, Sendable {
    /// Request received, response has not landed yet.
    case pending
    /// Response fully received.
    case completed
    /// Something failed (upstream refused, TLS error, timeout, ...).
    case failed
    /// Plain CONNECT tunnel that is not decrypted (SSL proxying disabled for the host).
    case tunneled
}

/// A single HTTP request/response exchange observed by the proxy.
///
/// The proxy core owns the lifecycle: it emits the value once when the request is
/// received (`state == .pending`) and again as it completes (`state == .completed`
/// or `.failed`). Every emission carries the full snapshot so the store can simply
/// upsert by `id`.
struct CapturedRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    var startedAt: Date
    var finishedAt: Date?

    var method: String
    /// Wire protocol of the exchange, e.g. "HTTP/1.1" or "HTTP/2".
    var httpVersion: String
    var scheme: String
    var host: String
    var port: Int
    var path: String

    /// True when the connection was decrypted with the ProxyDog CA.
    var intercepted: Bool

    var requestHeaders: [HeaderField]
    var requestBody: Data?

    var statusCode: Int?
    var responseHeaders: [HeaderField]
    var responseBody: Data?
    /// Response body bytes as received on the wire (before gzip/deflate decoding and without
    /// the 2 MB capture cap). Zero when unknown, e.g. for hand-made captures.
    var wireResponseBytes: Int

    var state: CaptureState
    var errorMessage: String?
    /// Name of the rewrite rule that modified this exchange, when any.
    var rewriteRuleName: String?
    /// Action of the applied rewrite rule (e.g. "Modify response").
    var rewriteAction: String?
    /// Name of the breakpoint rule that paused this exchange, when any.
    var breakpointRuleName: String?
    /// Phase the breakpoint paused ("request" / "response"), when any.
    var breakpointPhase: String?
    var isPinned: Bool
    /// User-Agent-derived client signature (e.g. "Safari/605.1.15"), when present.
    var clientSignature: String?
    /// PID of the local process that opened the connection, when attribution succeeded.
    var clientPID: Int32?
    /// Display name of the local app, e.g. "Safari" (resolved through libproc).
    var clientAppName: String?
    /// Executable path of the local app, when known.
    var clientAppPath: String?
    /// IPv4 of a LAN device when the connection did not come from this Mac.
    var clientRemoteAddress: String?

    /// Captured WebSocket messages, in arrival order (empty for non-WebSocket exchanges).
    var webSocketMessages: [WebSocketMessage]

    /// True once the WebSocket connection has been upgraded (HTTP 101).
    var isWebSocket: Bool

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        method: String,
        httpVersion: String = "HTTP/1.1",
        scheme: String = "https",
        host: String,
        port: Int = 443,
        path: String = "/",
        intercepted: Bool = false,
        requestHeaders: [HeaderField] = [],
        requestBody: Data? = nil,
        statusCode: Int? = nil,
        responseHeaders: [HeaderField] = [],
        responseBody: Data? = nil,
        wireResponseBytes: Int = 0,
        state: CaptureState = .pending,
        errorMessage: String? = nil,
        rewriteRuleName: String? = nil,
        rewriteAction: String? = nil,
        breakpointRuleName: String? = nil,
        breakpointPhase: String? = nil,
        isPinned: Bool = false,
        clientSignature: String? = nil,
        clientPID: Int32? = nil,
        clientAppName: String? = nil,
        clientAppPath: String? = nil,
        clientRemoteAddress: String? = nil,
        webSocketMessages: [WebSocketMessage] = [],
        isWebSocket: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.method = method
        self.httpVersion = httpVersion
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.intercepted = intercepted
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.wireResponseBytes = wireResponseBytes
        self.state = state
        self.errorMessage = errorMessage
        self.rewriteRuleName = rewriteRuleName
        self.rewriteAction = rewriteAction
        self.breakpointRuleName = breakpointRuleName
        self.breakpointPhase = breakpointPhase
        self.isPinned = isPinned
        self.clientSignature = clientSignature
        self.clientPID = clientPID
        self.clientAppName = clientAppName
        self.clientAppPath = clientAppPath
        self.clientRemoteAddress = clientRemoteAddress
        self.webSocketMessages = webSocketMessages
        self.isWebSocket = isWebSocket
    }
}

// MARK: - Derived values used across the UI and exporters

extension CapturedRequest {
    var isSecure: Bool { scheme.lowercased() == "https" }

    var isDefaultPort: Bool {
        (isSecure && port == 443) || (!isSecure && port == 80)
    }

    var urlString: String {
        "\(scheme)://\(host)\(isDefaultPort ? "" : ":\(port)")\(displayPath)"
    }

    var displayPath: String {
        guard !path.isEmpty else { return "/" }
        return path
    }

    var hostLabel: String {
        isDefaultPort ? host : "\(host):\(port)"
    }

    var statusText: String {
        if let statusCode { return String(statusCode) }
        switch state {
        case .pending: return "…"
        case .failed: return String(localized: "Error")
        case .tunneled: return String(localized: "Tunnel")
        case .completed: return "—"
        }
    }

    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }

    var requestContentType: String? {
        requestHeaders.firstValue(forName: "Content-Type")
    }

    var responseContentType: String? {
        responseHeaders.firstValue(forName: "Content-Type")
    }

    var contentKind: ContentKind {
        ContentKind.infer(mimeType: responseContentType ?? requestContentType, pathOrURL: path)
    }

    var requestBytes: Int {
        requestBody?.count ?? 0
    }

    var responseBytes: Int {
        responseBody?.count ?? 0
    }

    /// Wire size of the response body; falls back to the decoded size when unknown.
    var responseWireBytes: Int {
        wireResponseBytes > 0 ? wireResponseBytes : responseBytes
    }

    var isFailure: Bool {
        state == .failed || (statusCode.map { $0 >= 400 } ?? false)
    }

    /// True when the request came from another device on the LAN.
    var isFromLANDevice: Bool { clientRemoteAddress != nil }

    /// Display name for the client column / inspector: the local app or the LAN device.
    var clientDisplayName: String {
        if let ip = clientRemoteAddress {
            return String(format: String(localized: "LAN device (%@)"), ip)
        }
        if let name = clientAppName, !name.isEmpty { return name }
        return String(localized: "Unknown")
    }

    /// Stable grouping key for the sidebar client section.
    var clientGroupKey: String {
        clientRemoteAddress ?? clientAppName ?? String(localized: "Unknown")
    }

    /// True when this exchange was opened by ProxyDog itself (e.g. its analytics or update
    /// check going through the system proxy). Those are noise and never shown in the list.
    var isFromThisProcess: Bool {
        if let pid = clientPID, pid == ProcessInfo.processInfo.processIdentifier {
            return true
        }
        if let name = clientAppName, name == AppInfo.name {
            return true
        }
        if let path = clientAppPath, path.hasPrefix(Bundle.main.bundlePath + "/") {
            return true
        }
        return false
    }

    /// The response advertised HTTP/3 via `Alt-Svc`. QUIC traffic bypasses the system HTTP
    /// proxy, so this is an informational hint — those flows cannot be captured here.
    var advertisesHTTP3: Bool {
        guard let altSvc = responseHeaders.firstValue(forName: "Alt-Svc") else { return false }
        return altSvc.lowercased().contains("h3")
    }

    /// User-Agent signature shown as a separate "User-Agent" row in the inspector.
    var userAgent: String? {
        guard let clientSignature, !clientSignature.isEmpty else { return nil }
        return clientSignature
    }
}
