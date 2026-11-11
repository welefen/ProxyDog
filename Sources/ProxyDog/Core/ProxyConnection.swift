import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

// MARK: - Wire helpers

struct ProxyConnectTarget: Sendable {
    let host: String
    let port: Int
}

enum ProxyWire {
    static var maxBodyBytes: Int { AppDefaults.maxBodyBytes }

    static func headerFields(_ headers: HTTPHeaders) -> [HeaderField] {
        var fields: [HeaderField] = []
        fields.reserveCapacity(16)
        for (name, value) in headers {
            fields.append(HeaderField(name: name, value: value))
        }
        return fields
    }

    static func defaultPort(forScheme scheme: String) -> Int {
        scheme.lowercased() == "https" ? 443 : 80
    }

    /// Splits `host`, `host:port`, `[::1]:port` into a host/port pair.
    static func splitAuthority(_ authority: String, defaultPort: Int) -> (host: String, port: Int)? {
        var value = authority
        if let at = value.lastIndex(of: "@") {
            value = String(value[value.index(after: at)...])
        }
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) {
                return (host, port)
            }
            return host.isEmpty ? nil : (host, defaultPort)
        }

        if let colon = value.lastIndex(of: ":"),
           !value[value.startIndex..<colon].contains(":"),
           let port = Int(value[value.index(after: colon)...]),
           (1...65535).contains(port) {
            let host = String(value[..<colon])
            return host.isEmpty ? nil : (host, port)
        }

        return (value, defaultPort)
    }

    /// Converts an absolute-form request target into an origin-form path.
    static func originPath(from uri: String) -> String {
        guard let schemeRange = uri.range(of: "://") else {
            if uri.hasPrefix("/") || uri == "*" { return uri }
            return "/" + uri
        }
        let rest = uri[schemeRange.upperBound...]
        guard let index = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) else {
            return "/"
        }
        let tail = String(rest[index...])
        if tail.hasPrefix("?") { return "/" + tail }
        return tail
    }

    struct ResolvedTarget {
        let scheme: String
        let host: String
        let port: Int
        let path: String
    }

    static func resolve(head: HTTPRequestHead, connectTarget: ProxyConnectTarget?, defaultScheme: String) -> ResolvedTarget? {
        let uri = head.uri

        // Inside a CONNECT tunnel the target is fixed and requests are origin-form.
        if let connectTarget {
            return ResolvedTarget(
                scheme: defaultScheme,
                host: connectTarget.host,
                port: connectTarget.port,
                path: originPath(from: uri)
            )
        }

        // Plain HTTP proxy request in absolute-form: http://host:port/path
        if let schemeRange = uri.range(of: "://") {
            let scheme = String(uri[..<schemeRange.lowerBound]).lowercased()
            let rest = uri[schemeRange.upperBound...]
            let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            let authority = authorityEnd.map { String(rest[..<$0]) } ?? String(rest)
            guard let (host, port) = splitAuthority(authority, defaultPort: defaultPort(forScheme: scheme)) else {
                return nil
            }
            return ResolvedTarget(scheme: scheme, host: host, port: port, path: originPath(from: uri))
        }

        // Origin-form through a plain proxy (some clients do this): use the Host header.
        guard let hostHeader = head.headers.first(name: "Host"),
              let (host, port) = splitAuthority(hostHeader, defaultPort: defaultPort(forScheme: defaultScheme))
        else { return nil }
        let path = (uri.hasPrefix("/") || uri == "*") ? uri : "/" + uri
        return ResolvedTarget(scheme: defaultScheme, host: host, port: port, path: path)
    }

    /// True for IPv4/IPv6 literal hosts (which must not be used as TLS SNI names).
    static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4) == 1 || inet_pton(AF_INET6, pointer, &ipv6) == 1
        }
    }

    static func clientSignature(from headers: HTTPHeaders) -> String? {
        guard let userAgent = headers.first(name: "User-Agent")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userAgent.isEmpty
        else { return nil }
        let token = userAgent.split(separator: " ").first(where: { $0.contains("/") })
            ?? userAgent.split(separator: " ").first
        guard let token else { return nil }
        return String(token.split(separator: "/").first ?? token).trimmingCharacters(in: .whitespaces)
    }

    /// Human readable error message for capture records / 502 bodies.
    static func readableError(_ error: Error) -> String {
        if let proxyError = error as? ProxyError {
            return proxyError.localizedDescription
        }
        if let connectionError = error as? NIOConnectionError {
            if connectionError.dnsAError != nil || connectionError.dnsAAAAError != nil {
                return "Could not resolve host \"\(connectionError.host)\"."
            }
            return "Could not connect to \(connectionError.host):\(connectionError.port)."
        }
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNREFUSED: return "Connection refused by the upstream server."
            case ETIMEDOUT: return "The upstream connection timed out."
            case EHOSTUNREACH, ENETUNREACH: return "The upstream server is unreachable."
            case ECONNRESET, EPIPE: return "The upstream connection was reset."
            default: return "Upstream connection failed (errno \(ioError.errnoCode))."
            }
        }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .connectTimeout: return "The upstream connection timed out."
            case .eof: return "The upstream server closed the connection."
            case .ioOnClosedChannel, .alreadyClosed, .outputClosed: return "The connection was already closed."
            default: return "Upstream channel error: \(channelError)."
            }
        }
        if let sslError = error as? NIOSSLError {
            return "TLS handshake with the upstream server failed: \(sslError)."
        }
        let description = String(describing: error)
        return description.isEmpty ? error.localizedDescription : description
    }
}

/// Outbound (proxy -> origin server) TLS configuration.
///
/// ProxyDog is a debugging proxy, so upstream certificate problems (self-signed dev
/// servers, expired test certificates, ...) must not make a request impossible to
/// inspect. Flip `certificateVerification` to `.fullVerification` to be strict.
enum ProxyOutboundTLS {
    static let context: NIOSSLContext? = {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.applicationProtocols = ["http/1.1"]
        configuration.certificateVerification = .none
        return try? NIOSSLContext(configuration: configuration)
    }()
}

// MARK: - Per-exchange capture state

final class ExchangeState {
    private static let bodyCap = AppDefaults.maxBodyBytes

    let id = UUID()
    let startedAt: Date
    let method: String
    let scheme: String
    let host: String
    let port: Int
    let path: String
    let intercepted: Bool
    let requestHeaders: [HeaderField]
    let clientSignature: String?
    let isUpgradeRequest: Bool
    /// Wire protocol the client used ("HTTP/1.1" or "HTTP/2").
    var httpVersion: String = "HTTP/1.1"

    /// Local app that opened the client connection, once attribution resolved.
    var clientProcess: ClientProcess?
    /// LAN device address when the client is not this Mac.
    var clientRemoteAddress: String?
    /// Static rewrite rule applied to this exchange, when any.
    var rewriteRuleName: String?
    var rewriteAction: String?
    /// Breakpoint rule that paused this exchange, when any.
    var breakpointRuleName: String?
    var breakpointPhase: String?

    var requestBody = Data()
    private(set) var requestBytesReceived = 0
    var requestEnded = false
    var pendingBodyParts: [ByteBuffer] = []
    var pendingTrailers: HTTPHeaders?
    var upstreamReady = false

    var responseStatusCode: Int?
    var responseHeaders: [HeaderField] = []
    var responseBody = Data()
    private(set) var responseBytesReceived = 0

    init(
        startedAt: Date = Date(),
        method: String,
        scheme: String,
        host: String,
        port: Int,
        path: String,
        intercepted: Bool,
        requestHeaders: [HeaderField],
        clientSignature: String?,
        isUpgradeRequest: Bool
    ) {
        self.startedAt = startedAt
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.intercepted = intercepted
        self.requestHeaders = requestHeaders
        self.clientSignature = clientSignature
        self.isUpgradeRequest = isUpgradeRequest
    }

    func appendRequestBytes(_ bytes: [UInt8]) {
        requestBytesReceived += bytes.count
        guard requestBody.count < Self.bodyCap else { return }
        requestBody.append(contentsOf: bytes.prefix(Self.bodyCap - requestBody.count))
    }

    func appendResponseBytes(_ bytes: [UInt8]) {
        responseBytesReceived += bytes.count
        guard responseBody.count < Self.bodyCap else { return }
        responseBody.append(contentsOf: bytes.prefix(Self.bodyCap - responseBody.count))
    }

    /// Inflates the *captured* copies of request/response bodies when their headers
    /// advertise a decodable `Content-Encoding`. The bytes relayed on the wire are never
    /// touched; only the copies stored for the inspector are decoded. Decoding failures
    /// (truncated capture, unsupported encoding, 16 MB output cap) keep the raw bytes.
    func decodeCapturedBodies() {
        if !responseBody.isEmpty,
           let encoding = responseHeaders.firstValue(forName: "Content-Encoding"),
           BodyDecompression.canDecode(contentEncoding: encoding),
           let decoded = BodyDecompression.decode(responseBody, contentEncoding: encoding) {
            responseBody = decoded
        }
        if !requestBody.isEmpty,
           let encoding = requestHeaders.firstValue(forName: "Content-Encoding"),
           BodyDecompression.canDecode(contentEncoding: encoding),
           let decoded = BodyDecompression.decode(requestBody, contentEncoding: encoding) {
            requestBody = decoded
        }
    }

    /// Client-visible URL used for rewrite-rule matching.
    var originalURLString: String {
        RewriteEngine.urlString(scheme: scheme, host: host, port: port, path: path)
    }

    /// Replaces the captured request body (used after a request-body rewrite). The wire bytes
    /// may be larger than the capture cap; only the prefix is kept.
    func replaceCapturedRequestBody(_ data: Data) {
        requestBytesReceived = data.count
        requestBody = Data(data.prefix(Self.bodyCap))
    }

    /// Replaces the captured response body (used after a `.modifyResponse` rewrite) and records
    /// the number of bytes actually put on the wire.
    func replaceCapturedResponseBody(_ data: Data, wireBytes: Int) {
        responseBody = Data(data.prefix(Self.bodyCap))
        responseBytesReceived = wireBytes
    }

    func snapshot(state: CaptureState, error: String? = nil) -> CapturedRequest {
        let requestBody = self.requestBody.isEmpty ? nil : self.requestBody
        let responseBody = self.responseBody.isEmpty ? nil : self.responseBody
        var captured = CapturedRequest(
            id: id,
            startedAt: startedAt,
            method: method,
            httpVersion: httpVersion,
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            intercepted: intercepted,
            requestHeaders: requestHeaders,
            requestBody: requestBody,
            statusCode: responseStatusCode,
            responseHeaders: responseHeaders,
            responseBody: responseBody,
            wireResponseBytes: responseBytesReceived,
            state: state,
            errorMessage: error,
            rewriteRuleName: rewriteRuleName,
            rewriteAction: rewriteAction,
            breakpointRuleName: breakpointRuleName,
            breakpointPhase: breakpointPhase,
            isPinned: false,
            clientSignature: clientSignature,
            clientPID: clientProcess?.pid,
            clientAppName: clientProcess?.attributedAppName,
            clientAppPath: clientProcess?.executablePath,
            clientRemoteAddress: clientRemoteAddress
        )
        if state == .completed || state == .failed {
            captured.finishedAt = Date()
        }
        return captured
    }
}

// MARK: - Inbound connection front end (CONNECT detection + pipeline install)

/// First handler on every accepted client connection.
///
/// It reads only as far as the first HTTP request head to decide between:
/// * `CONNECT`: answer `200 Connection established`, then either upgrade to TLS (MITM)
///   or switch to a raw byte tunnel.
/// * anything else: install the HTTP pipeline and replay the buffered bytes.
final class ProxyFrontendHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let sink: CaptureSink
    private let certificateAuthority: CertificateAuthority
    private let sslProxyingEnabled: Bool
    /// Resolved per connection so a running server picks up a newly configured upstream proxy.
    private let upstreamProxyProvider: @Sendable () -> UpstreamProxy?
    /// Static rewrite rules, evaluated per exchange by the HTTP handlers.
    let rewriteRulesProvider: @Sendable () -> [RewriteRule]
    let breakpointRulesProvider: @Sendable () -> [BreakpointRule]
    let breakpointGate: BreakpointGate

    private var buffer = ByteBufferAllocator().buffer(capacity: 0)
    private var extraBytes: ByteBuffer?
    private var channel: Channel?
    private var finished = false
    /// Process that owns this client connection (attributed once per connection).
    private let clientIdentity = ClientIdentity()

    private let maxHeadBytes = 256 * 1024

    init(
        sink: CaptureSink,
        certificateAuthority: CertificateAuthority,
        sslProxyingEnabled: Bool,
        upstreamProxyProvider: @Sendable @escaping () -> UpstreamProxy? = { nil },
        rewriteRulesProvider: @Sendable @escaping () -> [RewriteRule] = { [] },
        breakpointRulesProvider: @Sendable @escaping () -> [BreakpointRule] = { [] },
        breakpointGate: BreakpointGate = BreakpointGate()
    ) {
        self.rewriteRulesProvider = rewriteRulesProvider
        self.breakpointRulesProvider = breakpointRulesProvider
        self.breakpointGate = breakpointGate
        self.sink = sink
        self.certificateAuthority = certificateAuthority
        self.sslProxyingEnabled = sslProxyingEnabled
        self.upstreamProxyProvider = upstreamProxyProvider
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
    }

    func channelActive(context: ChannelHandlerContext) {
        if let remote = context.channel.remoteAddress,
           let host = Self.hostString(remote),
           !Self.isLoopback(host) {
            clientIdentity.setRemoteAddress(host)
        }
        attributeClientProcess(context: context)
        context.fireChannelActive()
    }

    private static func hostString(_ address: SocketAddress) -> String? {
        switch address {
        case .v4(let ip): return ip.host
        case .v6(let ip):
            let host = ip.host
            return host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
        default: return nil
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.")
    }

    /// Resolves the local app from the client's ephemeral port (one libproc scan per
    /// connection, off the event loop). Late results are patched onto existing captures.
    private func attributeClientProcess(context: ChannelHandlerContext) {
        guard let peerPort = context.channel.remoteAddress?.port else { return }
        let listenPort = context.channel.localAddress?.port ?? 0
        let identity = clientIdentity
        let eventLoop = context.eventLoop
        ClientProcessAttributor.shared.attribute(
            peerPort: UInt16(clamping: peerPort),
            listenPort: UInt16(clamping: listenPort),
            eventLoop: eventLoop
        ) { process in
            identity.resolve(process)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = Self.unwrapInboundIn(data)
        if finished {
            // Bytes that raced the pipeline switch are replayed once the new pipeline exists.
            if var extra = extraBytes {
                extra.writeBuffer(&incoming)
                extraBytes = extra
            } else {
                extraBytes = incoming
            }
            return
        }

        buffer.writeBuffer(&incoming)
        process(context: context)
    }

    private func process(context: ChannelHandlerContext) {
        guard let headerEnd = buffer.indexOfCRLFCRLF() else {
            if buffer.readableBytes > maxHeadBytes {
                finished = true
                respondRaw(
                    context: context,
                    head: "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
            }
            return
        }

        let headLength = headerEnd - buffer.readerIndex
        guard let headBytes = buffer.getBytes(at: buffer.readerIndex, length: headLength) else {
            finished = true
            context.close(promise: nil)
            return
        }
        let headText = String(decoding: headBytes, as: UTF8.self)
        guard let requestLine = headText.components(separatedBy: "\r\n").first, !requestLine.isEmpty else {
            finished = true
            respondRaw(context: context, head: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let tokens = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else {
            finished = true
            respondRaw(context: context, head: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }

        let method = tokens[0].uppercased()
        let target = tokens[1]
        buffer.moveReaderIndex(forwardBy: headLength)

        var remainder = ByteBufferAllocator().buffer(capacity: 0)
        if buffer.readableBytes > 0 {
            remainder.writeBuffer(&buffer)
        }

        if method == "GET", ["/ca", "/ca/", "/certificate"].contains(target) {
            finished = true
            serveSmartCertificate(context: context, requestHead: headText)
            return
        }

        if method == "GET", ["/ca.mobileconfig", "/proxydog-ca.mobileconfig"].contains(target) {
            finished = true
            serveRootProfile(context: context)
            return
        }

        if method == "GET", ["/ca.cer", "/ca.crt", "/proxydog-ca.cer"].contains(target) {
            finished = true
            serveRootCertificate(context: context, binaryDER: true)
            return
        }

        if method == "GET", ["/ca.pem", "/proxydog-ca.pem"].contains(target) {
            finished = true
            serveRootCertificate(context: context, binaryDER: false)
            return
        }

        if method == "CONNECT" {
            guard let (host, port) = ProxyWire.splitAuthority(target, defaultPort: 443) else {
                finished = true
                respondRaw(context: context, head: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            finished = true
            handleConnect(context: context, host: host, port: port, leftover: remainder, startedAt: Date())
        } else {
            // Plain HTTP: hand the whole buffered byte stream to the HTTP pipeline.
            var initialBytes = ByteBufferAllocator().buffer(capacity: 0)
            initialBytes.writeBytes(headBytes)
            initialBytes.writeBuffer(&remainder)
            finished = true
            _ = installHTTPPipeline(context: context, initialBytes: initialBytes)
        }
    }

    /// Serves the root CA over plain HTTP so LAN devices can download and install it.
    /// `/ca.cer` returns binary DER (what Android/HarmonyOS installers expect),
    /// `/ca.pem` returns the PEM text for manual/desktop use.
    private func serveRootCertificate(context: ChannelHandlerContext, binaryDER: Bool) {
        guard let pem = try? String(contentsOf: certificateAuthority.rootCertificateURL, encoding: .utf8) else {
            respondRaw(context: context, head: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let data: Data
        let filename: String
        if binaryDER {
            let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
            guard let der = Data(base64Encoded: base64), !der.isEmpty else {
                respondRaw(context: context, head: "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            data = der
            filename = "ProxyDog-CA.cer"
        } else {
            data = Data(pem.utf8)
            filename = "ProxyDog-CA.pem"
        }
        var output = context.channel.allocator.buffer(capacity: data.count + 256)
        output.writeString("HTTP/1.1 200 OK\r\n")
        output.writeString("Content-Type: application/x-x509-ca-cert\r\n")
        output.writeString("Content-Disposition: attachment; filename=\"\(filename)\"\r\n")
        output.writeString("Content-Length: \(data.count)\r\n")
        output.writeString("Connection: close\r\n\r\n")
        output.writeBytes(data)
        context.channel.writeAndFlush(output).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    /// Single "scan this" endpoint: picks the right certificate format from the UA.
    /// iOS gets the installable profile, Android/HarmonyOS get the DER file, everything
    /// else gets a small landing page with both links.
    private func serveSmartCertificate(context: ChannelHandlerContext, requestHead: String) {
        let ua = Self.userAgent(from: requestHead).lowercased()
        if ua.contains("iphone") || ua.contains("ipad") || ua.contains("ipod") {
            serveRootProfile(context: context)
            return
        }
        if ua.contains("harmony") || ua.contains("openharmony") {
            serveHarmonyLandingPage(context: context)
            return
        }
        if ua.contains("android") {
            serveRootCertificate(context: context, binaryDER: true)
            return
        }
        serveCertificateLandingPage(context: context)
    }

    private static func userAgent(from requestHead: String) -> String {
        for line in requestHead.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "user-agent" else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// HarmonyOS does not install a CA when the downloaded file is tapped in the file
    /// manager; the user has to go through Settings. Show those steps explicitly and
    /// offer the DER / CRT / PEM variants.
    private func serveHarmonyLandingPage(context: ChannelHandlerContext) {
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ProxyDog 根证书安装</title>
        <style>body{font:16px -apple-system,Helvetica,sans-serif;margin:28px 20px;color:#222;line-height:1.55}a.btn{display:block;text-align:center;background:#0a66ff;color:#fff;text-decoration:none;padding:12px;border-radius:10px;margin:12px 0}ol{padding-left:22px}code{background:#f2f2f7;padding:2px 5px;border-radius:4px}.muted{color:#666;font-size:13px}</style>
        </head><body>
        <h2>ProxyDog 根证书</h2>
        <p><b>重要：</b>下载后直接在「文件管理」里点开证书不会安装，请按下面的系统设置步骤操作。</p>
        <ol>
        <li>点击下面的按钮下载证书（任选一种格式，推荐 DER）</li>
        <li>打开 <b>设置 → 隐私和安全 → 更多安全设置 → 加密和凭据 → 安装数字证书</b></li>
        <li>选择 <b>CA 证书</b>，从「下载」中选择 <code>ProxyDog-CA.cer</code></li>
        <li>按提示确认（可能需要锁屏密码）</li>
        <li>之后在 Wi-Fi 设置里把 HTTP 代理设为这台 Mac 的地址和端口</li>
        </ol>
        <a class="btn" href="/ca.cer">下载证书 (.cer / DER)</a>
        <a class="btn" href="/ca.crt">下载证书 (.crt / DER)</a>
        <a class="btn" href="/ca.pem">下载证书 (.pem)</a>
        <p class="muted">Root certificate for ProxyDog. After downloading, install it from Settings → Privacy & security → More security settings → Encryption and credentials → Install a certificate → CA certificate. Tapping the file in Files does not install it.</p>
        </body></html>
        """
        let data = Data(html.utf8)
        var output = context.channel.allocator.buffer(capacity: data.count + 256)
        output.writeString("HTTP/1.1 200 OK\r\n")
        output.writeString("Content-Type: text/html; charset=utf-8\r\n")
        output.writeString("Content-Length: \(data.count)\r\n")
        output.writeString("Connection: close\r\n\r\n")
        output.writeBytes(data)
        context.channel.writeAndFlush(output).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private func serveCertificateLandingPage(context: ChannelHandlerContext) {
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ProxyDog Certificate</title>
        <style>body{font:15px -apple-system,Helvetica,sans-serif;margin:40px auto;max-width:640px;padding:0 20px;color:#222}a{color:#0a66ff}code{background:#f2f2f7;padding:2px 5px;border-radius:4px}</style>
        </head><body>
        <h2>ProxyDog root certificate / 根证书</h2>
        <p>Open this same address on the device that will use the proxy — the right format is picked automatically:
        iPhone/iPad gets an installable profile, Android/HarmonyOS gets the DER certificate.</p>
        <p>在需要抓包的设备上打开同一地址即可：iPhone/iPad 会下载可安装的描述文件，Android / 鸿蒙会下载 DER 证书。</p>
        <ul>
        <li><a href="/ca.mobileconfig">iOS profile (.mobileconfig)</a></li>
        <li><a href="/ca.cer">Android / HarmonyOS certificate (.cer, DER)</a></li>
        <li><a href="/ca.pem">PEM certificate</a></li>
        </ul>
        <p>Install the certificate, then enable full trust for it in the system settings.</p>
        <p>安装证书后，请在系统设置中将其设为完全信任。</p>
        </body></html>
        """
        let data = Data(html.utf8)
        var output = context.channel.allocator.buffer(capacity: data.count + 256)
        output.writeString("HTTP/1.1 200 OK\r\n")
        output.writeString("Content-Type: text/html; charset=utf-8\r\n")
        output.writeString("Content-Length: \(data.count)\r\n")
        output.writeString("Connection: close\r\n\r\n")
        output.writeBytes(data)
        context.channel.writeAndFlush(output).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    /// Serves an unsigned `.mobileconfig` profile containing the root CA so iOS devices
    /// get the standard "Profile Downloaded → install" flow instead of a raw file.
    private func serveRootProfile(context: ChannelHandlerContext) {
        guard let pem = try? String(contentsOf: certificateAuthority.rootCertificateURL, encoding: .utf8) else {
            respondRaw(context: context, head: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let base64 = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: base64), !der.isEmpty else {
            respondRaw(context: context, head: "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let derBase64 = der.base64EncodedString(options: [.lineLength64Characters])
        let profile = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>PayloadCertificateFileName</key>
                    <string>ProxyDog-CA.cer</string>
                    <key>PayloadContent</key>
                    <data>
        \(derBase64)
                    </data>
                    <key>PayloadDescription</key>
                    <string>Adds the ProxyDog root certificate for HTTPS debugging.</string>
                    <key>PayloadDisplayName</key>
                    <string>ProxyDog Root CA</string>
                    <key>PayloadIdentifier</key>
                    <string>com.proxydog.ca.root</string>
                    <key>PayloadType</key>
                    <string>com.apple.security.root</string>
                    <key>PayloadUUID</key>
                    <string>8F1D2C64-7B5A-4E71-9F3C-2A6B8D4E1F09</string>
                    <key>PayloadVersion</key>
                    <integer>1</integer>
                </dict>
            </array>
            <key>PayloadDisplayName</key>
            <string>ProxyDog CA</string>
            <key>PayloadIdentifier</key>
            <string>com.proxydog.ca.profile</string>
            <key>PayloadOrganization</key>
            <string>ProxyDog</string>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadUUID</key>
            <string>5B7E9A13-2C48-4D6F-8A1B-3E5C7D9F0A21</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
        let data = Data(profile.utf8)
        var output = context.channel.allocator.buffer(capacity: data.count + 256)
        output.writeString("HTTP/1.1 200 OK\r\n")
        output.writeString("Content-Type: application/x-apple-aspen-config\r\n")
        output.writeString("Content-Disposition: attachment; filename=\"ProxyDog-CA.mobileconfig\"\r\n")
        output.writeString("Content-Length: \(data.count)\r\n")
        output.writeString("Connection: close\r\n\r\n")
        output.writeBytes(data)
        context.channel.writeAndFlush(output).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    // MARK: CONNECT

    private func handleConnect(
        context: ChannelHandlerContext,
        host: String,
        port: Int,
        leftover: ByteBuffer,
        startedAt: Date
    ) {
        let channel = context.channel
        // 200 Connection established; keep the connection open for TLS / tunneling.
        var established = channel.allocator.buffer(capacity: 39)
        established.writeString("HTTP/1.1 200 Connection established\r\n\r\n")
        channel.writeAndFlush(established).whenFailure { _ in
            channel.close(promise: nil)
        }

        guard sslProxyingEnabled else {
            installTunnel(context: context, host: host, port: port, leftover: leftover, startedAt: startedAt)
            return
        }

        // Establish the leaf certificate without blocking the event loop.
        let promise = channel.eventLoop.makePromise(of: NIOSSLContext.self)
        // HTTP-proxy MITM negotiates h2 or http/1.1 with the client; the SOCKS5 listener keeps
        // its HTTP/1.1-only context for now.
        certificateAuthority.tlsContext(forHost: host, applicationProtocols: ["h2", "http/1.1"]) { result in
            promise.completeWith(result)
        }

        channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
            promise.futureResult
                .flatMap { tlsContext in
                    self.installMITM(
                        context: context,
                        tlsContext: tlsContext,
                        host: host,
                        port: port,
                        leftover: leftover
                    )
                }
                .whenFailure { error in
                    var request = CapturedRequest(
                        startedAt: startedAt,
                        method: "CONNECT",
                        scheme: "https",
                        host: host,
                        port: port,
                        path: "",
                        intercepted: false,
                        state: .failed,
                        errorMessage: ProxyWire.readableError(error)
                    )
                    self.emitCapture(request)
                    channel.close(promise: nil)
                }
        }
    }

    private func installMITM(
        context: ChannelHandlerContext,
        tlsContext: NIOSSLContext,
        host: String,
        port: Int,
        leftover: ByteBuffer
    ) -> EventLoopFuture<Void> {
        let channel = context.channel
        let config = HTTP2MITMConfig(
            sink: sink,
            connectTarget: ProxyConnectTarget(host: host, port: port),
            upstreamProxyProvider: upstreamProxyProvider,
            clientIdentity: clientIdentity,
            rewriteRulesProvider: rewriteRulesProvider,
            breakpointRulesProvider: breakpointRulesProvider,
            breakpointGate: breakpointGate
        )

        // The TLS handler negotiates ALPN; HTTP2MITM waits for the handshake result and then
        // installs either the HTTP/2 or the (unchanged) HTTP/1.1 pipeline.
        return HTTP2MITM.install(
            channel: channel,
            removing: self,
            tlsContext: tlsContext,
            config: config
        )
        .flatMap { channel.setOption(ChannelOptions.autoRead, value: true) }
        .map {
            // TLS records read together with the CONNECT head (e.g. a pipelined ClientHello)
            // are replayed only after the SSL handler exists.
            if leftover.readableBytes > 0 {
                channel.pipeline.fireChannelRead(leftover)
            }
            if var extra = self.extraBytes, extra.readableBytes > 0 {
                self.extraBytes = nil
                channel.pipeline.fireChannelRead(extra)
            }
        }
    }

    private func installHTTPPipeline(context: ChannelHandlerContext, initialBytes: ByteBuffer) -> EventLoopFuture<Void> {
        let channel = context.channel
        let pipeline = channel.pipeline

        var encoderConfiguration = HTTPResponseEncoder.Configuration()
        encoderConfiguration.automaticallySetFramingHeaders = false
        let responseEncoder = HTTPResponseEncoder(configuration: encoderConfiguration)
        let requestDecoder = HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
        let decoderWrapper = ByteToMessageHandler(requestDecoder)
        let clientHandler = ClientHTTPHandler(
            sink: sink,
            connectTarget: nil,
            scheme: "http",
            intercepted: false,
            responseEncoder: responseEncoder,
            requestDecoderWrapper: decoderWrapper,
            upstreamProxyProvider: upstreamProxyProvider,
            clientIdentity: clientIdentity,
            rewriteRulesProvider: rewriteRulesProvider,
            breakpointRulesProvider: breakpointRulesProvider,
            breakpointGate: breakpointGate
        )

        return channel.setOption(ChannelOptions.autoRead, value: false)
            .flatMap { pipeline.removeHandler(self) }
            .flatMap { pipeline.addHandler(responseEncoder) }
            .flatMap { pipeline.addHandler(decoderWrapper) }
            .flatMap { pipeline.addHandler(clientHandler) }
            .map {
                if var extra = self.extraBytes, extra.readableBytes > 0 {
                    self.extraBytes = nil
                    channel.pipeline.fireChannelRead(extra)
                }
                if initialBytes.readableBytes > 0 {
                    channel.pipeline.fireChannelRead(initialBytes)
                }
                channel.pipeline.fireChannelReadComplete()
                channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            }
    }

    // MARK: Raw tunnel

    private func installTunnel(
        context: ChannelHandlerContext,
        host: String,
        port: Int,
        leftover: ByteBuffer,
        startedAt: Date
    ) {
        let channel = context.channel
        let clientPipe = TunnelPipeHandler(allocator: channel.allocator)
        let frontend = self
        let proxy = upstreamProxyProvider()

        channel.setOption(ChannelOptions.autoRead, value: false)
            .flatMap { channel.pipeline.addHandler(clientPipe) }
            .flatMap { channel.pipeline.removeHandler(frontend) }
            .flatMap { _ in
                ProxyOutboundConnector.connect(eventLoop: channel.eventLoop, host: host, port: port, proxy: proxy)
            }
            .flatMap { (upstream: Channel, targetLeftover: ByteBuffer) -> EventLoopFuture<Void> in
                let serverPipe = TunnelPipeHandler(allocator: upstream.allocator)
                return upstream.pipeline.addHandler(serverPipe).map {
                    // Bytes the target sent right after the upstream proxy's CONNECT reply
                    // belong to the client.
                    if targetLeftover.readableBytes > 0 {
                        channel.writeAndFlush(targetLeftover)
                    }
                    // Bytes that arrived right after the CONNECT head (e.g. TLS ClientHello)
                    // must go to the upstream before the relay starts.
                    if leftover.readableBytes > 0 {
                        upstream.writeAndFlush(leftover)
                    }
                    if var extra = frontend.extraBytes, extra.readableBytes > 0 {
                        frontend.extraBytes = nil
                        upstream.writeAndFlush(extra)
                    }
                    clientPipe.attach(upstream)
                    serverPipe.attach(channel)
                    channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
                    upstream.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }

                    let request = CapturedRequest(
                        startedAt: startedAt,
                        method: "CONNECT",
                        scheme: "https",
                        host: host,
                        port: port,
                        path: "",
                        intercepted: false,
                        state: .tunneled
                    )
                    frontend.emitCapture(request)
                }
            }
            .whenFailure { error in
                let message: String
                if let proxy {
                    message = ProxyOutboundConnector.connectionFailureMessage(error, proxy: proxy)
                } else {
                    message = ProxyWire.readableError(error)
                }
                let request = CapturedRequest(
                    startedAt: startedAt,
                    method: "CONNECT",
                    scheme: "https",
                    host: host,
                    port: port,
                    path: "",
                    intercepted: false,
                    state: .failed,
                    errorMessage: message
                )
                frontend.emitCapture(request)
                var output = channel.allocator.buffer(capacity: 64)
                output.writeString("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                channel.writeAndFlush(output).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
    }

    // MARK: Helpers

    /// Emits a capture with client-process attribution, re-emitting a patched snapshot if
    /// the libproc probe finishes later.
    private func emitCapture(_ request: CapturedRequest) {
        var attributed = request
        attributed.clientRemoteAddress = clientIdentity.remoteAddress
        attributed.applyClientProcess(clientIdentity.current)
        sink.captureDidUpdate(attributed)

        guard clientIdentity.current == nil, let eventLoop = channel?.eventLoop else { return }
        clientIdentity.observe(on: eventLoop) { [weak self] process in
            guard let self, let process else { return }
            var patched = request
            patched.applyClientProcess(process)
            self.sink.captureDidUpdate(patched)
        }
    }

    private func respondRaw(context: ChannelHandlerContext, head: String) {
        var output = context.channel.allocator.buffer(capacity: head.utf8.count)
        output.writeString(head)
        context.channel.writeAndFlush(output).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

// MARK: - Upstream proxy CONNECT handshake

/// Sends `CONNECT target:port` to an upstream HTTP proxy and waits for its response head.
///
/// The handler is installed on a fresh TCP connection to the proxy, writes the CONNECT
/// request once that channel is active, and completes `future` with any bytes the target
/// sent directly after the response head (they must be re-injected into the newly built
/// TLS/HTTP pipeline). Failures carry a readable message naming the proxy and the target.
///
/// `ByteToMessageHandler`/`HTTPDecoder` instances are single-use, so this class (and every
/// handler added afterwards) is created per candidate channel, never shared.
final class UpstreamConnectHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, UpstreamTunnelHandshakeHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let proxy: UpstreamProxy
    let targetHost: String
    let targetPort: Int

    private let promise: EventLoopPromise<ByteBuffer>
    private var buffer = ByteBufferAllocator().buffer(capacity: 0)
    private var leftover: ByteBuffer?
    private var channel: Channel?
    private var completed = false
    private var started = false
    private var timeoutTask: Scheduled<Void>?
    private let timeout: TimeAmount

    init(
        proxy: UpstreamProxy,
        targetHost: String,
        targetPort: Int,
        eventLoop: EventLoop,
        timeout: TimeAmount = .seconds(15)
    ) {
        self.proxy = proxy
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.promise = eventLoop.makePromise(of: ByteBuffer.self)
        self.timeout = timeout
    }

    /// Fires with the bytes that followed the proxy's response head.
    var future: EventLoopFuture<ByteBuffer> { promise.futureResult }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        if context.channel.isActive {
            start(context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else {
            // Bytes that raced the handshake completion: keep them for re-injection.
            var extra = Self.unwrapInboundIn(data)
            if var buffered = leftover {
                buffered.writeBuffer(&extra)
                leftover = buffered
            } else {
                leftover = extra
            }
            return
        }

        var incoming = Self.unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard let headerEnd = buffer.indexOfCRLFCRLF() else {
            if buffer.readableBytes > 64 * 1024 {
                fail("Upstream proxy \(proxy.displayName) sent an oversized response to CONNECT \(targetHost):\(targetPort).")
            }
            return
        }

        let headLength = headerEnd - buffer.readerIndex
        guard let headBytes = buffer.getBytes(at: buffer.readerIndex, length: headLength) else {
            fail("Upstream proxy \(proxy.displayName) sent an unreadable response to CONNECT \(targetHost):\(targetPort).")
            return
        }
        buffer.moveReaderIndex(forwardBy: headLength)
        var remaining = ByteBufferAllocator().buffer(capacity: 0)
        if buffer.readableBytes > 0 {
            remaining.writeBuffer(&buffer)
        }

        let headText = String(decoding: headBytes, as: UTF8.self)
        guard let statusLine = headText.components(separatedBy: "\r\n").first else {
            fail("Upstream proxy \(proxy.displayName) sent an empty response to CONNECT \(targetHost):\(targetPort).")
            return
        }
        let statusTokens = statusLine.split(separator: " ")
        guard statusTokens.count >= 2, let statusCode = Int(statusTokens[1]) else {
            fail("Upstream proxy \(proxy.displayName) sent a malformed response to CONNECT \(targetHost):\(targetPort).")
            return
        }
        guard (200..<300).contains(statusCode) else {
            fail("Upstream proxy \(proxy.displayName) refused CONNECT to \(targetHost):\(targetPort) (\(statusCode)).")
            return
        }
        completeSuccess(context: context, remaining: remaining)
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        fail(
            "Upstream proxy \(proxy.displayName) closed the connection while opening a CONNECT tunnel to \(targetHost):\(targetPort).",
            closeChannel: false
        )
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        fail("Upstream proxy \(proxy.displayName) connection failed while opening a CONNECT tunnel to \(targetHost):\(targetPort): \(ProxyWire.readableError(error))")
    }

    private func start(_ context: ChannelHandlerContext) {
        guard !started else { return }
        started = true

        var request = context.channel.allocator.buffer(capacity: 128)
        request.writeString("CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\n")
        request.writeString("Host: \(targetHost):\(targetPort)\r\n")
        request.writeString("Proxy-Connection: Keep-Alive\r\n\r\n")
        context.channel.writeAndFlush(request).whenFailure { [weak self] error in
            guard let self else { return }
            self.fail("Upstream proxy \(self.proxy.displayName) could not be reached: \(ProxyWire.readableError(error))")
        }

        timeoutTask = context.eventLoop.scheduleTask(in: timeout) { [weak self] in
            guard let self else { return }
            self.fail("Upstream proxy \(self.proxy.displayName) timed out while opening a CONNECT tunnel to \(self.targetHost):\(self.targetPort).")
        }
    }

    private func completeSuccess(context: ChannelHandlerContext, remaining: ByteBuffer) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        leftover = remaining
        let promise = self.promise
        context.pipeline.removeHandler(self).whenComplete { _ in
            promise.succeed(self.leftover ?? ByteBufferAllocator().buffer(capacity: 0))
        }
    }

    private func fail(_ message: String, closeChannel: Bool = true) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        promise.fail(ProxyError.upstreamProxyFailed(message))
        if closeChannel {
            channel?.close(promise: nil)
        }
    }
}

// MARK: - HTTP handling (plain HTTP and decrypted HTTPS)

final class ClientHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let sink: CaptureSink
    private let connectTarget: ProxyConnectTarget?
    private let scheme: String
    private let intercepted: Bool
    /// Resolved per exchange so a running server picks up a changed upstream proxy.
    private let upstreamProxyProvider: @Sendable () -> UpstreamProxy?
    /// Local app that owns this client connection (attributed once per connection).
    private let clientIdentity: ClientIdentity
    /// Static rewrite rules evaluated for every exchange (read on the event loop).
    let rewriteRulesProvider: @Sendable () -> [RewriteRule]
    let breakpointRulesProvider: @Sendable () -> [BreakpointRule]
    let breakpointGate: BreakpointGate

    let responseEncoder: HTTPResponseEncoder
    let requestDecoderWrapper: ByteToMessageHandler<HTTPRequestDecoder>

    private var channel: Channel?
    private var exchange: ExchangeState?
    private var upstream: Channel?
    private var relay: UpstreamHTTPRelayHandler?
    private var upstreamRequestEncoder: HTTPRequestEncoder?
    private var upstreamResponseDecoderWrapper: ByteToMessageHandler<HTTPResponseDecoder>?
    private var clientWantsClose = false
    private var isTunnel = false

    // Rewrite-rule state for the request currently being processed.
    private var currentRequestHead: HTTPRequestHead?
    private var pendingRequestRule: RewriteRule?
    private var bufferingRuleBody = false
    private var ruleBodyBuffer = Data()
    private var forwardTargetOverride: ProxyWire.ResolvedTarget?
    private var forwardURIOverride: String?
    private var forwardHostHeaderOverride: String?
    private var forwardBodyOverride: ByteBuffer?
    private var forwardContentLengthOverride: Int?
    private var dropForwardEncodingHeaders = false
    private var responsePhaseRule: RewriteRule?

    // Breakpoint state.
    private var requestBreakpointRule: BreakpointRule?
    private var responseBreakpointRule: BreakpointRule?
    private var bufferingBreakpointBody = false
    private var breakpointBodyBuffer = Data()
    private var requestBreakpointPaused = false

    /// Most recent finished capture of this connection, kept so a late process probe can
    /// still patch (and re-emit) it.
    private var lastCompletedCapture: CapturedRequest?
    /// WebSocket capture session, when the connection was upgraded to WebSocket.
    private var webSocketSession: WebSocketCaptureSession?

    /// HTTP/1.1 pipelining: requests received while another exchange is still in flight are
    /// buffered (bounded) and replayed once the previous response completes. Sequential
    /// keep-alive requests do not take this path.
    private var bufferingPipelinedRequest = false
    private var pendingPipelinedParts: [HTTPServerRequestPart] = []
    private var pendingPipelinedBytes = 0
    private let maxPipelinedBytes = 4 * 1024 * 1024
    /// Upper bound for buffering a request body to apply replace/modify rules.
    private static let maxRewriteBodyBytes = 32 * 1024 * 1024

    init(
        sink: CaptureSink,
        connectTarget: ProxyConnectTarget?,
        scheme: String,
        intercepted: Bool,
        responseEncoder: HTTPResponseEncoder,
        requestDecoderWrapper: ByteToMessageHandler<HTTPRequestDecoder>,
        upstreamProxyProvider: @Sendable @escaping () -> UpstreamProxy? = { nil },
        clientIdentity: ClientIdentity = ClientIdentity(),
        rewriteRulesProvider: @Sendable @escaping () -> [RewriteRule] = { [] },
        breakpointRulesProvider: @Sendable @escaping () -> [BreakpointRule] = { [] },
        breakpointGate: BreakpointGate = BreakpointGate()
    ) {
        self.rewriteRulesProvider = rewriteRulesProvider
        self.breakpointRulesProvider = breakpointRulesProvider
        self.breakpointGate = breakpointGate
        self.sink = sink
        self.connectTarget = connectTarget
        self.scheme = scheme
        self.intercepted = intercepted
        self.responseEncoder = responseEncoder
        self.requestDecoderWrapper = requestDecoderWrapper
        self.upstreamProxyProvider = upstreamProxyProvider
        self.clientIdentity = clientIdentity
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        clientIdentity.observe(on: context.eventLoop) { [weak self] process in
            self?.applyClientProcess(process)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isTunnel else { return }
        route(Self.unwrapInboundIn(data))
    }

    private func route(_ part: HTTPServerRequestPart) {
        if bufferingPipelinedRequest {
            bufferPipelined(part)
            return
        }
        if let state = exchange {
            if state.requestEnded {
                // A new request head arrived while the previous response is still in flight.
                bufferingPipelinedRequest = true
                bufferPipelined(part)
            } else {
                process(part)
            }
            return
        }
        process(part)
    }

    private func process(_ part: HTTPServerRequestPart) {
        switch part {
        case .head(let head):
            handleHead(head)
        case .body(let body):
            handleBody(body)
        case .end(let trailers):
            handleEnd(trailers)
        }
    }

    private func bufferPipelined(_ part: HTTPServerRequestPart) {
        switch part {
        case .head(let head):
            pendingPipelinedBytes += head.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 }
        case .body(let body):
            pendingPipelinedBytes += body.readableBytes
        case .end:
            break
        }
        pendingPipelinedParts.append(part)
        if pendingPipelinedBytes > maxPipelinedBytes {
            pendingPipelinedParts.removeAll()
            pendingPipelinedBytes = 0
            bufferingPipelinedRequest = false
            channel?.close(promise: nil)
        }
    }

    /// Replays the next complete pipelined request once the previous response has been sent.
    private func drainPipelinedRequests() {
        guard exchange == nil, !pendingPipelinedParts.isEmpty else {
            bufferingPipelinedRequest = false
            return
        }
        var completeCount = pendingPipelinedParts.count
        for (index, part) in pendingPipelinedParts.enumerated() {
            if case .end = part {
                completeCount = index + 1
                break
            }
        }
        let parts = Array(pendingPipelinedParts.prefix(completeCount))
        pendingPipelinedParts.removeFirst(completeCount)
        pendingPipelinedBytes = pendingPipelinedParts.reduce(0) { total, part in
            switch part {
            case .head(let head):
                return total + head.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 }
            case .body(let body):
                return total + body.readableBytes
            case .end:
                return total
            }
        }
        bufferingPipelinedRequest = !pendingPipelinedParts.isEmpty
        for part in parts {
            process(part)
        }
    }

    private func clearPipelinedRequests() {
        pendingPipelinedParts.removeAll()
        pendingPipelinedBytes = 0
        bufferingPipelinedRequest = false
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let state = exchange {
            exchange = nil
            sink.captureDidUpdate(state.snapshot(
                state: .failed,
                error: "The client closed the connection before the response completed."
            ))
        }
        closeUpstream()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let state = exchange {
            exchange = nil
            sink.captureDidUpdate(state.snapshot(state: .failed, error: ProxyWire.readableError(error)))
        }
        closeUpstream()
        context.close(promise: nil)
    }

    // MARK: Request handling

    private func handleHead(_ head: HTTPRequestHead) {
        if exchange != nil {
            // HTTP pipelining is not supported; close so the client retries.
            channel?.close(promise: nil)
            return
        }
        guard let target = ProxyWire.resolve(head: head, connectTarget: connectTarget, defaultScheme: scheme) else {
            respondError(status: .badRequest, message: "The request URL could not be parsed.")
            return
        }

        resetRewriteState()
        currentRequestHead = head

        let connection = (head.headers.first(name: "Connection") ?? "").lowercased()
        clientWantsClose = connection.contains("close")
            || (head.version == .http1_0 && !connection.contains("keep-alive"))
        let isUpgrade = head.headers.first(name: "Upgrade") != nil && connection.contains("upgrade")

        let state = ExchangeState(
            method: head.method.rawValue,
            scheme: target.scheme,
            host: target.host,
            port: target.port,
            path: target.path,
            intercepted: intercepted,
            requestHeaders: ProxyWire.headerFields(head.headers),
            clientSignature: ProxyWire.clientSignature(from: head.headers),
            isUpgradeRequest: isUpgrade
        )
        exchange = state
        state.clientProcess = clientIdentity.current
        state.clientRemoteAddress = clientIdentity.remoteAddress

        // Rules match the original, client-visible URL. WebSocket upgrade requests are left
        // alone so we never break a protocol upgrade in flight.
        let url = RewriteEngine.urlString(scheme: target.scheme, host: target.host, port: target.port, path: target.path)
        let breakpointRules = isUpgrade ? [] : breakpointRulesProvider()
        requestBreakpointRule = breakpointRules.first {
            $0.isEnabled && $0.breakOnRequest && $0.matches(method: head.method.rawValue, url: url)
        }
        responseBreakpointRule = breakpointRules.first {
            $0.isEnabled && $0.breakOnResponse && $0.matches(method: head.method.rawValue, url: url)
        }
        if let breakpoint = requestBreakpointRule {
            state.breakpointRuleName = breakpoint.displayName
            state.breakpointPhase = BreakpointPhase.request.rawValue
        }
        let rules = rewriteRulesProvider()
        // A request breakpoint takes precedence: the request-phase rewrite rule is skipped for
        // exchanges that will pause before going upstream.
        let rule = (isUpgrade || requestBreakpointRule != nil)
            ? nil
            : RewriteEngine.requestPhaseRule(rules, method: head.method.rawValue, url: url)
        responsePhaseRule = isUpgrade ? nil : RewriteEngine.responsePhaseRule(rules, method: head.method.rawValue, url: url)
        if let rule {
            state.rewriteRuleName = rule.displayName
            state.rewriteAction = rule.action.label
        }
        sink.captureDidUpdate(state.snapshot(state: .pending))

        if let rule {
            switch rule.action {
            case .replaceResponse:
                sendSyntheticResponse(state: state, rule: rule)
                return

            case .redirect:
                if let redirect = RewriteEngine.redirectTarget(rule.redirectURL) {
                    forwardTargetOverride = ProxyWire.ResolvedTarget(
                        scheme: redirect.scheme,
                        host: redirect.host,
                        port: redirect.port,
                        path: redirect.path
                    )
                    forwardURIOverride = redirect.path
                    forwardHostHeaderOverride = RewriteEngine.hostHeader(
                        scheme: redirect.scheme,
                        host: redirect.host,
                        port: redirect.port
                    )
                } else {
                    // Invalid redirect target: ignore the rule instead of failing the exchange.
                    state.rewriteRuleName = nil
                    state.rewriteAction = nil
                }

            case .replaceRequest, .modifyRequest:
                // Buffer the request body, rewrite it, then open the upstream connection.
                pendingRequestRule = rule
                bufferingRuleBody = true
                ruleBodyBuffer = Data()
                channel?.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
                return

            case .modifyResponse:
                break
            }
        }

        if requestBreakpointRule != nil {
            // Pause before opening upstream. Requests with a body are buffered first.
            let contentLength = head.headers.first(name: "Content-Length").flatMap(Int.init) ?? 0
            let chunked = (head.headers.first(name: "Transfer-Encoding") ?? "").lowercased().contains("chunked")
            if contentLength > 0 || chunked {
                bufferingBreakpointBody = true
                breakpointBodyBuffer = Data()
                channel?.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            } else {
                presentRequestBreakpoint()
            }
            return
        }

        channel?.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        openUpstream(state: state, head: head)
    }

    private func handleBody(_ body: ByteBuffer) {
        guard let state = exchange else { return }
        if let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
            state.appendRequestBytes(bytes)
        }
        if bufferingBreakpointBody {
            if breakpointBodyBuffer.count + body.readableBytes > Self.maxRewriteBodyBytes {
                // Too large to show in the editor: abandon the pause and continue unchanged.
                requestBreakpointRule = nil
                state.breakpointRuleName = nil
                state.breakpointPhase = nil
            } else if let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
                breakpointBodyBuffer.append(contentsOf: bytes)
            }
            return
        }
        if bufferingRuleBody {
            if ruleBodyBuffer.count + body.readableBytes > Self.maxRewriteBodyBytes {
                // Too large to buffer: abandon the rule and stream the original body.
                bufferingRuleBody = false
                pendingRequestRule = nil
                state.rewriteRuleName = nil
                state.rewriteAction = nil
                var buffered = ByteBufferAllocator().buffer(capacity: ruleBodyBuffer.count)
                buffered.writeBytes(ruleBodyBuffer)
                ruleBodyBuffer = Data()
                state.pendingBodyParts.append(buffered)
                if let head = currentRequestHead {
                    channel?.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
                    openUpstream(state: state, head: head)
                }
            } else {
                if let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
                    ruleBodyBuffer.append(contentsOf: bytes)
                }
                return
            }
        }
        if let upstream, state.upstreamReady {
            upstream.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(body)))
        } else {
            state.pendingBodyParts.append(body)
        }
    }

    private func handleEnd(_ trailers: HTTPHeaders?) {
        guard let state = exchange else { return }
        state.requestEnded = true
        state.pendingTrailers = trailers

        if bufferingBreakpointBody {
            bufferingBreakpointBody = false
            if requestBreakpointRule != nil {
                presentRequestBreakpoint()
                return
            }
            // Overflowed / abandoned: forward the buffered body and open upstream normally.
            if !breakpointBodyBuffer.isEmpty {
                forwardBodyOverride = ByteBuffer(bytes: breakpointBodyBuffer)
            }
            breakpointBodyBuffer = Data()
            if let head = currentRequestHead {
                channel?.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
                openUpstream(state: state, head: head)
            }
            return
        }

        if bufferingRuleBody, let rule = pendingRequestRule, let head = currentRequestHead {
            bufferingRuleBody = false
            pendingRequestRule = nil
            let original = ruleBodyBuffer
            ruleBodyBuffer = Data()

            var forwardedBody: Data?
            switch rule.action {
            case .replaceRequest:
                forwardedBody = Data(rule.replacementBody.utf8)
            case .modifyRequest:
                forwardedBody = rule.transformData(original)
            default:
                forwardedBody = nil
            }

            if let forwardedBody {
                // Capture what the upstream actually receives (documented choice).
                state.replaceCapturedRequestBody(forwardedBody)
                forwardBodyOverride = ByteBuffer(bytes: forwardedBody)
                forwardContentLengthOverride = forwardedBody.count
                dropForwardEncodingHeaders = true
            } else if !original.isEmpty {
                // Could not apply (e.g. non-UTF8 body): forward the original bytes untouched.
                forwardBodyOverride = ByteBuffer(bytes: original)
                forwardContentLengthOverride = original.count
            }

            openUpstream(state: state, head: head)
            return
        }

        if let upstream, state.upstreamReady {
            upstream.writeAndFlush(HTTPClientRequestPart.end(trailers))
            state.pendingTrailers = nil
        }
    }

    // MARK: Request breakpoints

    private func presentRequestBreakpoint() {
        guard let channel,
              let state = exchange,
              let head = currentRequestHead,
              let rule = requestBreakpointRule
        else { return }
        let bodyText = String(data: breakpointBodyBuffer, encoding: .utf8) ?? ""
        let payload = BreakpointPayload(
            id: UUID(),
            phase: .request,
            ruleName: rule.displayName,
            method: head.method.rawValue,
            url: state.originalURLString,
            statusCode: nil,
            contentType: head.headers.first(name: "Content-Type"),
            bodyText: bodyText,
            headers: state.requestHeaders,
            createdAt: Date()
        )
        requestBreakpointPaused = true
        channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        breakpointGate.wait(payload: payload, on: channel.eventLoop) { [weak self] decision in
            self?.resolveRequestBreakpoint(decision)
        }
    }

    private func resolveRequestBreakpoint(_ decision: BreakpointDecision) {
        guard let channel,
              let state = exchange,
              let head = currentRequestHead,
              requestBreakpointPaused
        else { return }
        requestBreakpointPaused = false
        guard channel.isActive else {
            exchange = nil
            return
        }

        let original = breakpointBodyBuffer
        breakpointBodyBuffer = Data()

        switch decision {
        case .drop:
            finishBreakpointDrop(state: state)

        case .resume(let body):
            if let body {
                let data = Data(body.utf8)
                state.replaceCapturedRequestBody(data)
                forwardBodyOverride = ByteBuffer(bytes: data)
                forwardContentLengthOverride = data.count
                dropForwardEncodingHeaders = true
            } else if !original.isEmpty {
                forwardBodyOverride = ByteBuffer(bytes: original)
            }
            channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            openUpstream(state: state, head: head)
        }
    }

    /// `.drop` at a request breakpoint: never contact upstream; answer 403 and complete the
    /// capture with the breakpoint fields set.
    private func finishBreakpointDrop(state: ExchangeState) {
        exchange = nil
        let body = Data("ProxyDog: dropped at breakpoint\n".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.count))
        let keepAlive = !clientWantsClose
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        state.responseStatusCode = 403
        state.responseHeaders = ProxyWire.headerFields(headers)
        state.replaceCapturedResponseBody(body, wireBytes: body.count)
        let completed = state.snapshot(state: .completed)
        lastCompletedCapture = completed
        sink.captureDidUpdate(completed)

        guard let channel, channel.isActive else { return }
        let responseHead = HTTPResponseHead(version: .http1_1, status: .forbidden, headers: headers)
        channel.write(HTTPServerResponsePart.head(responseHead))
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes([UInt8](body))
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            if keepAlive {
                channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            } else {
                channel.close(promise: nil)
            }
        }
    }

    private func resetRewriteState() {
        currentRequestHead = nil
        pendingRequestRule = nil
        bufferingRuleBody = false
        ruleBodyBuffer = Data()
        forwardTargetOverride = nil
        forwardURIOverride = nil
        forwardHostHeaderOverride = nil
        forwardBodyOverride = nil
        forwardContentLengthOverride = nil
        dropForwardEncodingHeaders = false
        responsePhaseRule = nil
        requestBreakpointRule = nil
        responseBreakpointRule = nil
        bufferingBreakpointBody = false
        breakpointBodyBuffer = Data()
        requestBreakpointPaused = false
    }

    /// Completes an exchange locally with a rule-synthesized response (`.replaceResponse`).
    private func sendSyntheticResponse(state: ExchangeState, rule: RewriteRule) {
        exchange = nil
        let body = Data(rule.replacementBody.utf8)
        let status = RewriteEngine.responseStatus(rule.responseStatus)
        let keepAlive = !clientWantsClose

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: RewriteEngine.contentType(rule))
        headers.add(name: "Content-Length", value: String(body.count))
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        state.responseStatusCode = Int(status.code)
        state.responseHeaders = ProxyWire.headerFields(headers)
        state.replaceCapturedResponseBody(body, wireBytes: body.count)

        let completed = state.snapshot(state: .completed)
        lastCompletedCapture = completed
        sink.captureDidUpdate(completed)

        guard let channel, channel.isActive else { return }
        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(responseHead))
        if !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes([UInt8](body))
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            if keepAlive {
                channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            } else {
                channel.close(promise: nil)
            }
        }
    }

    // MARK: Upstream connection

    private struct UpstreamHandles {
        let requestEncoder: HTTPRequestEncoder
        let responseDecoderWrapper: ByteToMessageHandler<HTTPResponseDecoder>
        let relay: UpstreamHTTPRelayHandler
    }

    /// Builds a fresh handler set for one upstream channel. `HTTPDecoder`/`ByteToMessageHandler`
    /// instances are single-use and a single `connect()` may create several candidate channels
    /// (Happy Eyeballs), so this must be called once per candidate channel.
    private func makeUpstreamHandles(
        state: ExchangeState,
        head: HTTPRequestHead,
        clientChannel: Channel,
        responseRule: RewriteRule?,
        responseBreakpointRule: BreakpointRule?,
        breakpointGate: BreakpointGate
    ) -> UpstreamHandles {
        let requestEncoder = HTTPRequestEncoder()
        let responseDecoder = HTTPResponseDecoder(
            leftOverBytesStrategy: .forwardBytes,
            informationalResponseStrategy: .forward
        )
        let decoderWrapper = ByteToMessageHandler(responseDecoder)
        let relay = UpstreamHTTPRelayHandler(
            exchange: state,
            method: head.method,
            client: clientChannel,
            clientWantsClose: clientWantsClose,
            owner: self,
            requestEncoder: requestEncoder,
            responseDecoderWrapper: decoderWrapper,
            responseRule: responseRule,
            responseBreakpointRule: responseBreakpointRule,
            breakpointGate: breakpointGate
        )
        return UpstreamHandles(
            requestEncoder: requestEncoder,
            responseDecoderWrapper: decoderWrapper,
            relay: relay
        )
    }

    private func openUpstream(state: ExchangeState, head: HTTPRequestHead) {
        if let proxy = upstreamProxyProvider() {
            openUpstreamThroughProxy(state: state, head: head, proxy: proxy)
        } else {
            openUpstreamDirect(state: state, head: head)
        }
    }

    private func openUpstreamDirect(state: ExchangeState, head: HTTPRequestHead) {
        guard let channel else { return }
        let target = forwardTargetOverride ?? ProxyWire.ResolvedTarget(
            scheme: state.scheme, host: state.host, port: state.port, path: state.path
        )
        let useTLS = target.scheme.lowercased() == "https"
        let host = target.host
        let port = target.port

        let bootstrap = ClientBootstrap(group: channel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(20))
            .channelInitializer { upstreamChannel in
                let eventLoop = upstreamChannel.eventLoop
                let handles = self.makeUpstreamHandles(state: state, head: head, clientChannel: channel, responseRule: self.responsePhaseRule, responseBreakpointRule: self.responseBreakpointRule, breakpointGate: self.breakpointGate)

                var setup: EventLoopFuture<Void>
                if useTLS {
                    guard let context = ProxyOutboundTLS.context else {
                        return eventLoop.makeFailedFuture(ProxyError.tlsUnavailable)
                    }
                    let sslHandler: NIOSSLClientHandler
                    do {
                        // IP literals must not be sent as SNI (NIOSSL throws for them).
                        let serverHostname = ProxyWire.isIPAddress(host) ? nil : host
                        sslHandler = try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
                    } catch {
                        return eventLoop.makeFailedFuture(error)
                    }
                    setup = upstreamChannel.pipeline.addHandler(sslHandler)
                } else {
                    setup = eventLoop.makeSucceededVoidFuture()
                }
                return setup
                    .flatMap { upstreamChannel.pipeline.addHandler(handles.requestEncoder) }
                    .flatMap { upstreamChannel.pipeline.addHandler(handles.responseDecoderWrapper) }
                    .flatMap { upstreamChannel.pipeline.addHandler(handles.relay) }
            }

        bootstrap.connect(host: host, port: port)
            .flatMap { (upstreamChannel: Channel) -> EventLoopFuture<(Channel, UpstreamHTTPRelayHandler)> in
                upstreamChannel.pipeline.handler(type: UpstreamHTTPRelayHandler.self)
                    .map { relay in (upstreamChannel, relay) }
            }
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let (upstreamChannel, relay)):
                    guard self.exchange === state else {
                        upstreamChannel.close(promise: nil)
                        return
                    }
                    self.upstream = upstreamChannel
                    self.relay = relay
                    self.upstreamRequestEncoder = relay.requestEncoder
                    self.upstreamResponseDecoderWrapper = relay.responseDecoderWrapper
                    self.startUpstreamRequest(state: state, head: head, upstream: upstreamChannel)
                case .failure(let error):
                    self.upstreamFailed(state, message: ProxyWire.readableError(error), responseStarted: false)
                }
            }
    }

    /// Opens the target through an upstream HTTP CONNECT proxy: TCP to the proxy, CONNECT
    /// handshake, then TLS (https) or plain HTTP (http) inside the tunnel.
    private func openUpstreamThroughProxy(state: ExchangeState, head: HTTPRequestHead, proxy: UpstreamProxy) {
        guard let channel else { return }
        let target = forwardTargetOverride ?? ProxyWire.ResolvedTarget(
            scheme: state.scheme, host: state.host, port: state.port, path: state.path
        )
        let useTLS = target.scheme.lowercased() == "https"
        let host = target.host
        let port = target.port

        ProxyOutboundConnector.connect(
            eventLoop: channel.eventLoop,
            host: host,
            port: port,
            proxy: proxy
        )
            .flatMap { (proxyChannel: Channel, leftover: ByteBuffer) -> EventLoopFuture<(Channel, UpstreamHTTPRelayHandler)> in
                let handles = self.makeUpstreamHandles(state: state, head: head, clientChannel: channel, responseRule: self.responsePhaseRule, responseBreakpointRule: self.responseBreakpointRule, breakpointGate: self.breakpointGate)

                var setup: EventLoopFuture<Void>
                if useTLS {
                    guard let context = ProxyOutboundTLS.context else {
                        return proxyChannel.eventLoop.makeFailedFuture(ProxyError.tlsUnavailable)
                    }
                    let sslHandler: NIOSSLClientHandler
                    do {
                        let serverHostname = ProxyWire.isIPAddress(host) ? nil : host
                        sslHandler = try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
                    } catch {
                        return proxyChannel.eventLoop.makeFailedFuture(error)
                    }
                    // TLS runs inside the CONNECT tunnel, so its handler must be first.
                    setup = proxyChannel.pipeline.addHandler(sslHandler, position: .first)
                } else {
                    setup = proxyChannel.eventLoop.makeSucceededVoidFuture()
                }

                return setup
                    .flatMap { proxyChannel.pipeline.addHandler(handles.requestEncoder) }
                    .flatMap { proxyChannel.pipeline.addHandler(handles.responseDecoderWrapper) }
                    .flatMap { proxyChannel.pipeline.addHandler(handles.relay) }
                    .map {
                        // Bytes the target sent right after the proxy's CONNECT response.
                        if leftover.readableBytes > 0 {
                            proxyChannel.pipeline.fireChannelRead(leftover)
                        }
                        return (proxyChannel, handles.relay)
                    }
            }
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let (upstreamChannel, relay)):
                    guard self.exchange === state else {
                        upstreamChannel.close(promise: nil)
                        return
                    }
                    self.upstream = upstreamChannel
                    self.relay = relay
                    self.upstreamRequestEncoder = relay.requestEncoder
                    self.upstreamResponseDecoderWrapper = relay.responseDecoderWrapper
                    self.startUpstreamRequest(state: state, head: head, upstream: upstreamChannel)
                case .failure(let error):
                    self.upstreamFailed(
                        state,
                        message: Self.describeUpstreamProxyFailure(error, proxy: proxy),
                        responseStarted: false
                    )
                }
            }
    }

    private static func describeUpstreamProxyFailure(_ error: Error, proxy: UpstreamProxy) -> String {
        ProxyOutboundConnector.connectionFailureMessage(error, proxy: proxy)
    }

    private func startUpstreamRequest(state: ExchangeState, head: HTTPRequestHead, upstream: Channel) {
        var headers = HTTPHeaders()
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "proxy-connection" || lower == "proxy-authorization" { continue }
            if !state.isUpgradeRequest && (lower == "connection" || lower == "keep-alive") { continue }
            if dropForwardEncodingHeaders
                && (lower == "content-encoding" || lower == "transfer-encoding") {
                continue
            }
            headers.add(name: name, value: value)
        }
        // The proxy needs readable bodies for the inspector, but macOS cannot inflate
        // Brotli/Zstandard. When the client already sent Accept-Encoding, rewrite it to the
        // best encoding we can decode (and that the client claims to accept). Requests
        // without the header stay without it, so upstream falls back to identity.
        if !state.isUpgradeRequest,
           let clientAcceptEncoding = head.headers.first(name: "Accept-Encoding") {
            headers.replaceOrAdd(
                name: "Accept-Encoding",
                value: BodyDecompression.upstreamAcceptEncoding(clientValue: clientAcceptEncoding)
            )
        }
        if let hostOverride = forwardHostHeaderOverride {
            headers.replaceOrAdd(name: "Host", value: hostOverride)
        } else if headers.first(name: "Host") == nil {
            let hostValue = state.port == ProxyWire.defaultPort(forScheme: state.scheme)
                ? state.host
                : "\(state.host):\(state.port)"
            headers.add(name: "Host", value: hostValue)
        }
        if let contentLength = forwardContentLengthOverride {
            headers.replaceOrAdd(name: "Content-Length", value: String(contentLength))
        }
        if !state.isUpgradeRequest {
            // One upstream connection per exchange keeps close-delimited responses simple.
            headers.replaceOrAdd(name: "Connection", value: "close")
        }

        let uri = forwardURIOverride ?? state.path
        let outgoing = HTTPRequestHead(version: .http1_1, method: head.method, uri: uri, headers: headers)
        upstream.writeAndFlush(HTTPClientRequestPart.head(outgoing))
        if let forwardBodyOverride {
            if forwardBodyOverride.readableBytes > 0 {
                upstream.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(forwardBodyOverride)))
            }
        } else {
            for part in state.pendingBodyParts {
                upstream.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(part)))
            }
        }
        state.pendingBodyParts.removeAll()
        state.upstreamReady = true
        if state.requestEnded {
            upstream.writeAndFlush(HTTPClientRequestPart.end(state.pendingTrailers))
            state.pendingTrailers = nil
        }
        // Request-body rewrites are one-shot per exchange.
        forwardBodyOverride = nil
        channel?.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
    }

    // MARK: Callbacks from the response relay

    func upstreamResponseFinished(_ state: ExchangeState, keepAlive: Bool, finalWrite: EventLoopFuture<Void>?) {
        guard exchange === state, let channel else { return }
        exchange = nil
        clientWantsClose = false
        state.decodeCapturedBodies()
        let completed = state.snapshot(state: .completed)
        lastCompletedCapture = completed
        sink.captureDidUpdate(completed)
        closeUpstream()
        if !keepAlive {
            clearPipelinedRequests()
            let future = finalWrite ?? channel.eventLoop.makeSucceededVoidFuture()
            future.whenComplete { _ in channel.close(promise: nil) }
        } else {
            channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            drainPipelinedRequests()
        }
    }

    func upstreamFailed(_ state: ExchangeState, message: String, responseStarted: Bool) {
        guard exchange === state, let channel else { return }
        exchange = nil
        clientWantsClose = false
        clearPipelinedRequests()
        let failed = state.snapshot(state: .failed, error: message)
        lastCompletedCapture = failed
        sink.captureDidUpdate(failed)
        closeUpstream()
        if responseStarted {
            channel.close(promise: nil)
        } else {
            respondError(status: .badGateway, message: message)
        }
    }

    func upgradeToTunnel(_ state: ExchangeState, responseHead: HTTPResponseHead) {
        guard exchange === state, let channel, let upstream else { return }
        exchange = nil
        isTunnel = true
        state.responseStatusCode = Int(responseHead.status.code)
        state.responseHeaders = ProxyWire.headerFields(responseHead.headers)

        let webSocket = Self.isWebSocketUpgrade(state: state, responseHead: responseHead)
        var completed = state.snapshot(state: .completed)
        completed.isWebSocket = webSocket
        lastCompletedCapture = completed
        sink.captureDidUpdate(completed)

        // For WebSocket upgrades both tunnel directions get a frame parser that reports
        // messages back on this exchange while forwarding the original bytes untouched.
        let session: WebSocketCaptureSession?
        if webSocket {
            session = WebSocketCaptureSession(
                request: completed,
                sink: sink,
                eventLoop: channel.eventLoop
            )
        } else {
            session = nil
        }
        webSocketSession = session

        guard let relay, let encoder = upstreamRequestEncoder, let decoderWrapper = upstreamResponseDecoderWrapper else {
            session?.flushFinal()
            channel.close(promise: nil)
            upstream.close(promise: nil)
            return
        }

        let clientPipe = TunnelPipeHandler(allocator: channel.allocator)
        let serverPipe = TunnelPipeHandler(allocator: upstream.allocator)
        let clientHandler = self
        let clientParser: WebSocketFrameCaptureHandler? = session.map {
            WebSocketFrameCaptureHandler(direction: .sent, session: $0)
        }
        let serverParser: WebSocketFrameCaptureHandler? = session.map {
            WebSocketFrameCaptureHandler(direction: .received, session: $0)
        }

        channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
            upstream.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
                var clientSetup = channel.pipeline.addHandler(clientPipe)
                if let clientParser {
                    clientSetup = clientSetup.flatMap {
                        channel.pipeline.addHandler(clientParser, position: .before(clientPipe))
                    }
                }

                clientSetup
                    .flatMap { channel.pipeline.removeHandler(clientHandler) }
                    .flatMap { channel.pipeline.removeHandler(clientHandler.responseEncoder) }
                    .flatMap { channel.pipeline.removeHandler(clientHandler.requestDecoderWrapper) }
                    .flatMap { upstream.pipeline.addHandler(serverPipe) }
                    .flatMap { () -> EventLoopFuture<Void> in
                        guard let serverParser else {
                            return upstream.eventLoop.makeSucceededVoidFuture()
                        }
                        return upstream.pipeline.addHandler(serverParser, position: .after(decoderWrapper))
                    }
                    .flatMap { upstream.pipeline.removeHandler(relay) }
                    .flatMap { upstream.pipeline.removeHandler(decoderWrapper) }
                    .flatMap { upstream.pipeline.removeHandler(encoder) }
                    .map {
                        serverPipe.attach(channel)
                        clientPipe.attach(upstream)
                        channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
                        upstream.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
                    }
                    .whenFailure { _ in
                        session?.flushFinal()
                        channel.close(promise: nil)
                        upstream.close(promise: nil)
                    }
            }
        }
    }

    /// True when a 101 response upgraded to the WebSocket protocol.
    private static func isWebSocketUpgrade(state: ExchangeState, responseHead: HTTPResponseHead) -> Bool {
        let responseUpgrade = (responseHead.headers.first(name: "Upgrade") ?? "").lowercased()
        if responseUpgrade.contains("websocket") { return true }
        if responseHead.headers.first(name: "Sec-WebSocket-Accept") != nil { return true }
        let requestUpgrade = state.requestHeaders
            .first { $0.name.caseInsensitiveCompare("Upgrade") == .orderedSame }?
            .value.lowercased() ?? ""
        return requestUpgrade.contains("websocket")
    }

    // MARK: Client attribution

    /// Applies a (possibly late) process attribution to the live exchange, the last finished
    /// capture and any WebSocket capture session.
    private func applyClientProcess(_ process: ClientProcess?) {
        guard let process else { return }
        if let state = exchange {
            state.clientProcess = process
            sink.captureDidUpdate(state.snapshot(state: .pending))
        }
        if var last = lastCompletedCapture {
            last.applyClientProcess(process)
            lastCompletedCapture = last
            sink.captureDidUpdate(last)
        }
        webSocketSession?.applyClientProcess(process)
    }

    // MARK: Breakpoint owner hooks

    func breakpointPendingSnapshot(_ state: ExchangeState) {
        guard exchange === state else { return }
        sink.captureDidUpdate(state.snapshot(state: .pending))
    }

    /// `.drop` at a response breakpoint: fail the capture, close upstream and the client
    /// connection so the client sees a failure rather than a valid response.
    func breakpointDropped(_ state: ExchangeState, message: String) {
        guard exchange === state else { return }
        exchange = nil
        sink.captureDidUpdate(state.snapshot(state: .failed, error: message))
        closeUpstream()
        channel?.close(promise: nil)
    }

    // MARK: Helpers

    private func closeUpstream() {
        relay = nil
        upstreamRequestEncoder = nil
        upstreamResponseDecoderWrapper = nil
        if let upstream {
            self.upstream = nil
            upstream.close(promise: nil)
        }
    }

    private func respondError(status: HTTPResponseStatus, message: String) {
        guard let channel, channel.isActive else {
            channel?.close(promise: nil)
            return
        }
        let body = Data("ProxyDog: \(message)\n".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.count))
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head))
        if !body.isEmpty {
            var output = channel.allocator.buffer(capacity: body.count)
            output.writeBytes([UInt8](body))
            channel.write(HTTPServerResponsePart.body(.byteBuffer(output)))
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

// MARK: - Upstream response relay (HTTP parts -> client)

final class UpstreamHTTPRelayHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let exchange: ExchangeState
    private let method: HTTPMethod
    private let client: Channel
    private let clientWantsClose: Bool
    private weak var owner: ClientHTTPHandler?

    /// Handlers that belong to this relay's own upstream channel; used when switching the
    /// connection to a raw tunnel after a `101 Switching Protocols` response.
    let requestEncoder: HTTPRequestEncoder
    let responseDecoderWrapper: ByteToMessageHandler<HTTPResponseDecoder>

    private var headForwarded = false
    private var completed = false
    private var closeDelimited = false
    private var keepAlive = false

    // `.modifyResponse` buffering state. The response head is withheld until the body is
    // complete so it can be sent as identity-encoded bytes with an exact Content-Length.
    private let responseRule: RewriteRule?
    private let responseBreakpointRule: BreakpointRule?
    private let breakpointGate: BreakpointGate
    private var buffering = false
    private var bufferedHead: HTTPResponseHead?
    private var bufferedOutgoingHead: HTTPResponseHead?
    private var bufferedBody = Data()
    private var bufferedNoBody = false
    private var waitingBreakpoint: (original: HTTPResponseHead, outgoing: HTTPResponseHead, rawBody: Data, decodedBody: Data)?
    private static let maxRewriteBodyBytes = 16 * 1024 * 1024

    init(
        exchange: ExchangeState,
        method: HTTPMethod,
        client: Channel,
        clientWantsClose: Bool,
        owner: ClientHTTPHandler,
        requestEncoder: HTTPRequestEncoder,
        responseDecoderWrapper: ByteToMessageHandler<HTTPResponseDecoder>,
        responseRule: RewriteRule?,
        responseBreakpointRule: BreakpointRule?,
        breakpointGate: BreakpointGate
    ) {
        self.exchange = exchange
        self.method = method
        self.client = client
        self.clientWantsClose = clientWantsClose
        self.owner = owner
        self.requestEncoder = requestEncoder
        self.responseDecoderWrapper = responseDecoderWrapper
        self.responseRule = responseRule
        self.responseBreakpointRule = responseBreakpointRule
        self.breakpointGate = breakpointGate
        self.buffering = false
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            handleResponseHead(head)
        case .body(let body):
            guard !completed else { return }
            captureBody(body)
            if buffering {
                appendBufferedBody(body)
                return
            }
            forward(.body(.byteBuffer(body)))
        case .end(let trailers):
            guard !completed else { return }
            if buffering {
                completed = true
                finalizeBufferedResponse()
                return
            }
            completed = true
            let finalWrite = forward(.end(trailers))
            owner?.upstreamResponseFinished(exchange, keepAlive: keepAlive, finalWrite: finalWrite)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        if buffering, bufferedHead != nil {
            // Close-delimited response that was being buffered for a rewrite: EOF ends the body.
            finalizeBufferedResponse()
            return
        }
        if headForwarded, closeDelimited {
            // End of a close-delimited body: normal completion at EOF.
            let finalWrite = forward(.end(nil))
            owner?.upstreamResponseFinished(exchange, keepAlive: false, finalWrite: finalWrite)
        } else if !headForwarded {
            owner?.upstreamFailed(
                exchange,
                message: "The upstream server closed the connection without sending a response.",
                responseStarted: false
            )
        } else {
            owner?.upstreamFailed(
                exchange,
                message: "The upstream server closed the connection before the response completed.",
                responseStarted: true
            )
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        owner?.upstreamFailed(exchange, message: ProxyWire.readableError(error), responseStarted: headForwarded)
    }

    private func handleResponseHead(_ head: HTTPResponseHead) {
        guard !completed else { return }
        let code = head.status.code

        // 100 Continue and friends: forward to the client and keep waiting for the final head.
        if (100..<200).contains(code), code != 101 {
            var informational = head
            informational.version = .http1_1
            forward(.head(informational))
            return
        }

        exchange.responseStatusCode = Int(code)
        exchange.responseHeaders = ProxyWire.headerFields(head.headers)

        if code == 101 {
            var upgradeHead = head
            upgradeHead.version = .http1_1
            forward(.head(upgradeHead))
            completed = true
            owner?.upgradeToTunnel(exchange, responseHead: head)
            return
        }

        let noBody = method == .HEAD || code == 204 || code == 304
        let transferEncoding = (head.headers.first(name: "transfer-encoding") ?? "").lowercased()
        let isChunked = transferEncoding.contains("chunked")
        let hasContentLength = head.headers.first(name: "content-length") != nil
        closeDelimited = !noBody && !isChunked && !hasContentLength
        keepAlive = !clientWantsClose && !closeDelimited

        var headers = HTTPHeaders()
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "connection" || lower == "keep-alive" || lower == "proxy-connection" || lower == "upgrade" {
                continue
            }
            if noBody && lower == "transfer-encoding" { continue }
            headers.add(name: name, value: value)
        }
        headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        let outgoing = HTTPResponseHead(version: .http1_1, status: head.status, headers: headers)
        if (responseRule != nil || responseBreakpointRule != nil), !noBody {
            // Withhold the head until the body is fully buffered (rewrite) or the user decides
            // (breakpoint).
            bufferedHead = head
            bufferedOutgoingHead = outgoing
            bufferedNoBody = noBody
            buffering = true
            return
        }
        buffering = false
        headForwarded = true
        forward(.head(outgoing))
    }

    // MARK: `.modifyResponse` buffering

    private func appendBufferedBody(_ body: ByteBuffer) {
        guard let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) else { return }
        if bufferedBody.count + bytes.count > Self.maxRewriteBodyBytes {
            // Too large to rewrite: flush what we buffered and pass the rest through untouched.
            flushBufferedPassthrough()
            forward(.body(.byteBuffer(body)))
            return
        }
        bufferedBody.append(contentsOf: bytes)
    }

    /// Turns the buffered response into the modified response (identity encoding, exact
    /// Content-Length). Falls back to passing the original bytes through when the body is not
    /// decodable/UTF-8 or the rule cannot be applied. When a response breakpoint matches and the
    /// body is editable text, the exchange pauses before anything is written to the client.
    private func finalizeBufferedResponse() {
        guard let original = bufferedHead, let outgoing = bufferedOutgoingHead else { return }
        let body = bufferedBody
        bufferedBody = Data()

        var decoded: Data? = body
        if let encoding = original.headers.first(name: "content-encoding") {
            decoded = BodyDecompression.canDecode(contentEncoding: encoding)
                ? BodyDecompression.decode(body, contentEncoding: encoding)
                : nil
        }

        // Response breakpoint: only pause for editable (UTF-8) or empty bodies.
        if let breakpoint = responseBreakpointRule,
           let decodedBody = decoded,
           let bodyText = String(data: decodedBody, encoding: .utf8) {
            buffering = false
            exchange.breakpointRuleName = breakpoint.displayName
            exchange.breakpointPhase = BreakpointPhase.response.rawValue
            owner?.breakpointPendingSnapshot(exchange)
            waitingBreakpoint = (original, outgoing, body, decodedBody)

            var headers: [HeaderField] = []
            for (name, value) in original.headers {
                headers.append(HeaderField(name: name, value: value))
            }
            let payload = BreakpointPayload(
                id: UUID(),
                phase: .response,
                ruleName: breakpoint.displayName,
                method: exchange.method,
                url: exchange.originalURLString,
                statusCode: exchange.responseStatusCode,
                contentType: original.headers.first(name: "content-type"),
                bodyText: bodyText,
                headers: headers,
                createdAt: Date()
            )
            breakpointGate.wait(payload: payload, on: client.eventLoop) { [weak self] decision in
                self?.resolveResponseBreakpoint(decision)
            }
            return
        }

        applyBufferedResponse(original: original, outgoing: outgoing, rawBody: body, decoded: decoded, breakpointBody: nil)
    }

    /// Sends the buffered response (rewrite rule applied when present, otherwise passthrough).
    private func applyBufferedResponse(
        original: HTTPResponseHead,
        outgoing: HTTPResponseHead,
        rawBody: Data,
        decoded: Data?,
        breakpointBody: Data?
    ) {
        bufferedHead = nil
        bufferedOutgoingHead = nil

        if let breakpointBody {
            // `.resume` with an edited body: identity encoding + exact Content-Length.
            exchange.replaceCapturedResponseBody(breakpointBody, wireBytes: breakpointBody.count)
            let keepClientAlive = !clientWantsClose
            sendIdentityResponse(original: original, body: breakpointBody, keepAlive: keepClientAlive)
            return
        }

        if let rule = responseRule, let decoded {
            if let transformed = rule.transformData(decoded) {
                exchange.rewriteRuleName = rule.displayName
                exchange.rewriteAction = rule.action.label
                exchange.replaceCapturedResponseBody(transformed, wireBytes: transformed.count)
                sendIdentityResponse(original: original, body: transformed, keepAlive: !clientWantsClose)
                return
            }
        }

        // Passthrough: send exactly what the upstream sent (with its original framing headers).
        headForwarded = true
        forward(.head(outgoing))
        if !rawBody.isEmpty {
            var buffer = client.allocator.buffer(capacity: rawBody.count)
            buffer.writeBytes([UInt8](rawBody))
            forward(.body(.byteBuffer(buffer)))
        }
        let finalWrite = forward(.end(nil))
        owner?.upstreamResponseFinished(exchange, keepAlive: keepAlive, finalWrite: finalWrite)
    }

    /// Resolves a response breakpoint when the user decides (or the gate times out).
    private func resolveResponseBreakpoint(_ decision: BreakpointDecision) {
        guard let waiting = waitingBreakpoint else { return }
        waitingBreakpoint = nil
        guard client.isActive else {
            owner?.breakpointDropped(exchange, message: "Client closed while paused at a breakpoint.")
            return
        }
        switch decision {
        case .drop:
            owner?.breakpointDropped(exchange, message: "Dropped at breakpoint")
        case .resume(let body):
            if let body {
                applyBufferedResponse(
                    original: waiting.original,
                    outgoing: waiting.outgoing,
                    rawBody: waiting.rawBody,
                    decoded: waiting.decodedBody,
                    breakpointBody: Data(body.utf8)
                )
            } else {
                applyBufferedResponse(
                    original: waiting.original,
                    outgoing: waiting.outgoing,
                    rawBody: waiting.rawBody,
                    decoded: waiting.decodedBody,
                    breakpointBody: nil
                )
            }
        }
    }

    private func sendIdentityResponse(original: HTTPResponseHead, body: Data, keepAlive: Bool) {
        var headers = HTTPHeaders()
        for (name, value) in original.headers {
            let lower = name.lowercased()
            if lower == "connection"
                || lower == "keep-alive"
                || lower == "proxy-connection"
                || lower == "transfer-encoding"
                || lower == "upgrade"
                || lower == "content-encoding"
                || lower == "content-length" {
                continue
            }
            headers.add(name: name, value: value)
        }
        headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
        headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        let responseHead = HTTPResponseHead(version: .http1_1, status: original.status, headers: headers)
        headForwarded = true
        forward(.head(responseHead))
        if !body.isEmpty {
            var buffer = client.allocator.buffer(capacity: body.count)
            buffer.writeBytes([UInt8](body))
            forward(.body(.byteBuffer(buffer)))
        }
        let finalWrite = forward(.end(nil))
        owner?.upstreamResponseFinished(exchange, keepAlive: keepAlive, finalWrite: finalWrite)
    }

    /// Flushes the withheld head and buffered body as-is, then switches to streaming.
    private func flushBufferedPassthrough() {
        guard buffering, let outgoing = bufferedOutgoingHead else { return }
        buffering = false
        bufferedHead = nil
        bufferedOutgoingHead = nil
        headForwarded = true
        forward(.head(outgoing))
        if !bufferedBody.isEmpty {
            var buffer = client.allocator.buffer(capacity: bufferedBody.count)
            buffer.writeBytes([UInt8](bufferedBody))
            bufferedBody = Data()
            forward(.body(.byteBuffer(buffer)))
        }
    }

    private func captureBody(_ body: ByteBuffer) {
        guard let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) else { return }
        exchange.appendResponseBytes(bytes)
    }

    @discardableResult
    private func forward(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        guard client.isActive else {
            return client.eventLoop.makeSucceededVoidFuture()
        }
        return client.writeAndFlush(part)
    }
}

// MARK: - Raw byte relay used for CONNECT tunnels and upgraded (101) connections

final class TunnelPipeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var peer: Channel?
    private var pending: ByteBuffer
    private var finished = false

    init(allocator: ByteBufferAllocator) {
        pending = allocator.buffer(capacity: 0)
    }

    /// Connects the pipe to the other side; any bytes buffered before the peer existed are
    /// flushed in order.
    func attach(_ channel: Channel) {
        peer = channel
        if pending.readableBytes > 0 {
            let buffered = pending
            pending.clear()
            channel.writeAndFlush(buffered)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = Self.unwrapInboundIn(data)
        if let peer, peer.isActive {
            peer.writeAndFlush(buffer)
        } else {
            pending.writeBuffer(&buffer)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !finished else { return }
        finished = true
        peer?.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !finished else { return }
        finished = true
        peer?.close(promise: nil)
        context.close(promise: nil)
    }
}

// MARK: - ByteBuffer helpers

extension ByteBuffer {
    /// Returns the index just past the first `\r\n\r\n`, or nil when the header is incomplete.
    func indexOfCRLFCRLF() -> Int? {
        guard readableBytes >= 4 else { return nil }
        guard let bytes = getBytes(at: readerIndex, length: readableBytes) else { return nil }
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
                return readerIndex + index + 4
            }
            index += 1
        }
        return nil
    }
}
