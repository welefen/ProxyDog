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

    var state: CaptureState
    var errorMessage: String?
    var isPinned: Bool
    var clientSignature: String?

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        method: String,
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
        state: CaptureState = .pending,
        errorMessage: String? = nil,
        isPinned: Bool = false,
        clientSignature: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.method = method
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
        self.state = state
        self.errorMessage = errorMessage
        self.isPinned = isPinned
        self.clientSignature = clientSignature
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

    var isFailure: Bool {
        state == .failed || (statusCode.map { $0 >= 400 } ?? false)
    }

    var clientAppName: String? {
        guard let clientSignature, !clientSignature.isEmpty else { return nil }
        return clientSignature
    }
}
