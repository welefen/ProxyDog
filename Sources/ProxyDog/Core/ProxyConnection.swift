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

    func snapshot(state: CaptureState, error: String? = nil) -> CapturedRequest {
        let requestBody = self.requestBody.isEmpty ? nil : self.requestBody
        let responseBody = self.responseBody.isEmpty ? nil : self.responseBody
        var captured = CapturedRequest(
            id: id,
            startedAt: startedAt,
            method: method,
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
            state: state,
            errorMessage: error,
            isPinned: false,
            clientSignature: clientSignature
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

    private var buffer = ByteBufferAllocator().buffer(capacity: 0)
    private var extraBytes: ByteBuffer?
    private var channel: Channel?
    private var finished = false

    private let maxHeadBytes = 256 * 1024

    init(sink: CaptureSink, certificateAuthority: CertificateAuthority, sslProxyingEnabled: Bool) {
        self.sink = sink
        self.certificateAuthority = certificateAuthority
        self.sslProxyingEnabled = sslProxyingEnabled
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
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
        certificateAuthority.tlsContext(forHost: host) { result in
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
                    let request = CapturedRequest(
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
                    self.sink.captureDidUpdate(request)
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
        let pipeline = channel.pipeline

        let serverHandler: NIOSSLServerHandler
        do {
            serverHandler = try NIOSSLServerHandler(context: tlsContext)
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }

        var encoderConfiguration = HTTPResponseEncoder.Configuration()
        encoderConfiguration.automaticallySetFramingHeaders = false
        let responseEncoder = HTTPResponseEncoder(configuration: encoderConfiguration)
        let requestDecoder = HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
        let decoderWrapper = ByteToMessageHandler(requestDecoder)
        let clientHandler = ClientHTTPHandler(
            sink: sink,
            connectTarget: ProxyConnectTarget(host: host, port: port),
            scheme: "https",
            intercepted: true,
            responseEncoder: responseEncoder,
            requestDecoderWrapper: decoderWrapper
        )

        return pipeline.removeHandler(self)
            .flatMap { pipeline.addHandler(serverHandler, position: .first) }
            .flatMap { pipeline.addHandler(responseEncoder) }
            .flatMap { pipeline.addHandler(decoderWrapper) }
            .flatMap { pipeline.addHandler(clientHandler) }
            .flatMap { channel.setOption(ChannelOptions.autoRead, value: true) }
            .map {
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
            requestDecoderWrapper: decoderWrapper
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

        channel.setOption(ChannelOptions.autoRead, value: false)
            .flatMap { channel.pipeline.addHandler(clientPipe) }
            .flatMap { channel.pipeline.removeHandler(frontend) }
            .flatMap { _ in
                ClientBootstrap(group: channel.eventLoop)
                    .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                    .connectTimeout(.seconds(20))
                    .connect(host: host, port: port)
            }
            .flatMap { upstream -> EventLoopFuture<Void> in
                let serverPipe = TunnelPipeHandler(allocator: upstream.allocator)
                return upstream.pipeline.addHandler(serverPipe).map {
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
                    frontend.sink.captureDidUpdate(request)
                }
            }
            .whenFailure { error in
                let request = CapturedRequest(
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
                frontend.sink.captureDidUpdate(request)
                var output = channel.allocator.buffer(capacity: 64)
                output.writeString("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                channel.writeAndFlush(output).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
    }

    // MARK: Helpers

    private func respondRaw(context: ChannelHandlerContext, head: String) {
        var output = context.channel.allocator.buffer(capacity: head.utf8.count)
        output.writeString(head)
        context.channel.writeAndFlush(output).whenComplete { _ in
            context.close(promise: nil)
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

    init(
        sink: CaptureSink,
        connectTarget: ProxyConnectTarget?,
        scheme: String,
        intercepted: Bool,
        responseEncoder: HTTPResponseEncoder,
        requestDecoderWrapper: ByteToMessageHandler<HTTPRequestDecoder>
    ) {
        self.sink = sink
        self.connectTarget = connectTarget
        self.scheme = scheme
        self.intercepted = intercepted
        self.responseEncoder = responseEncoder
        self.requestDecoderWrapper = requestDecoderWrapper
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isTunnel else { return }
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            handleHead(head)
        case .body(let body):
            handleBody(body)
        case .end(let trailers):
            handleEnd(trailers)
        }
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
        sink.captureDidUpdate(state.snapshot(state: .pending))
        channel?.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        openUpstream(state: state, head: head)
    }

    private func handleBody(_ body: ByteBuffer) {
        guard let state = exchange else { return }
        if let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
            state.appendRequestBytes(bytes)
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
        if let upstream, state.upstreamReady {
            upstream.writeAndFlush(HTTPClientRequestPart.end(trailers))
            state.pendingTrailers = nil
        }
    }

    // MARK: Upstream connection

    private func openUpstream(state: ExchangeState, head: HTTPRequestHead) {
        guard let channel else { return }
        let useTLS = state.scheme.lowercased() == "https"
        let host = state.host
        let port = state.port
        let clientWantsClose = self.clientWantsClose
        let method = head.method

        // NIO may create more than one candidate channel for a connect() (e.g. Happy
        // Eyeballs trying IPv6 then IPv4), and `ByteToMessageHandler` is single-use.
        // Therefore every channel gets a freshly built set of handlers; the winning
        // channel's relay (holding encoder + decoder references) is fetched afterwards.
        let bootstrap = ClientBootstrap(group: channel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(20))
            .channelInitializer { upstreamChannel in
                let eventLoop = upstreamChannel.eventLoop
                let requestEncoder = HTTPRequestEncoder()
                let responseDecoder = HTTPResponseDecoder(
                    leftOverBytesStrategy: .forwardBytes,
                    informationalResponseStrategy: .forward
                )
                let decoderWrapper = ByteToMessageHandler(responseDecoder)
                let relay = UpstreamHTTPRelayHandler(
                    exchange: state,
                    method: method,
                    client: channel,
                    clientWantsClose: clientWantsClose,
                    owner: self,
                    requestEncoder: requestEncoder,
                    responseDecoderWrapper: decoderWrapper
                )

                var setup: EventLoopFuture<Void>
                if useTLS {
                    guard let context = ProxyOutboundTLS.context else {
                        return eventLoop.makeFailedFuture(ProxyError.tlsUnavailable)
                    }
                    let sslHandler: NIOSSLClientHandler
                    do {
                        sslHandler = try NIOSSLClientHandler(context: context, serverHostname: host)
                    } catch {
                        return eventLoop.makeFailedFuture(error)
                    }
                    setup = upstreamChannel.pipeline.addHandler(sslHandler)
                } else {
                    setup = eventLoop.makeSucceededVoidFuture()
                }
                return setup
                    .flatMap { upstreamChannel.pipeline.addHandler(requestEncoder) }
                    .flatMap { upstreamChannel.pipeline.addHandler(decoderWrapper) }
                    .flatMap { upstreamChannel.pipeline.addHandler(relay) }
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

    private func startUpstreamRequest(state: ExchangeState, head: HTTPRequestHead, upstream: Channel) {
        var headers = HTTPHeaders()
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "proxy-connection" || lower == "proxy-authorization" { continue }
            if !state.isUpgradeRequest && (lower == "connection" || lower == "keep-alive") { continue }
            headers.add(name: name, value: value)
        }
        if headers.first(name: "Host") == nil {
            let hostValue = state.port == ProxyWire.defaultPort(forScheme: state.scheme)
                ? state.host
                : "\(state.host):\(state.port)"
            headers.add(name: "Host", value: hostValue)
        }
        if !state.isUpgradeRequest {
            // One upstream connection per exchange keeps close-delimited responses simple.
            headers.replaceOrAdd(name: "Connection", value: "close")
        }

        let outgoing = HTTPRequestHead(version: .http1_1, method: head.method, uri: state.path, headers: headers)
        upstream.writeAndFlush(HTTPClientRequestPart.head(outgoing))
        for part in state.pendingBodyParts {
            upstream.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(part)))
        }
        state.pendingBodyParts.removeAll()
        state.upstreamReady = true
        if state.requestEnded {
            upstream.writeAndFlush(HTTPClientRequestPart.end(state.pendingTrailers))
            state.pendingTrailers = nil
        }
        channel?.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
    }

    // MARK: Callbacks from the response relay

    func upstreamResponseFinished(_ state: ExchangeState, keepAlive: Bool, finalWrite: EventLoopFuture<Void>?) {
        guard exchange === state, let channel else { return }
        exchange = nil
        clientWantsClose = false
        sink.captureDidUpdate(state.snapshot(state: .completed))
        closeUpstream()
        if !keepAlive {
            let future = finalWrite ?? channel.eventLoop.makeSucceededVoidFuture()
            future.whenComplete { _ in channel.close(promise: nil) }
        } else {
            channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
        }
    }

    func upstreamFailed(_ state: ExchangeState, message: String, responseStarted: Bool) {
        guard exchange === state, let channel else { return }
        exchange = nil
        clientWantsClose = false
        sink.captureDidUpdate(state.snapshot(state: .failed, error: message))
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
        sink.captureDidUpdate(state.snapshot(state: .completed))

        guard let relay, let encoder = upstreamRequestEncoder, let decoderWrapper = upstreamResponseDecoderWrapper else {
            channel.close(promise: nil)
            upstream.close(promise: nil)
            return
        }

        let clientPipe = TunnelPipeHandler(allocator: channel.allocator)
        let serverPipe = TunnelPipeHandler(allocator: upstream.allocator)
        let clientHandler = self

        channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
            upstream.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
                channel.pipeline.addHandler(clientPipe)
                    .flatMap { channel.pipeline.removeHandler(clientHandler) }
                    .flatMap { channel.pipeline.removeHandler(clientHandler.responseEncoder) }
                    .flatMap { channel.pipeline.removeHandler(clientHandler.requestDecoderWrapper) }
                    .flatMap { upstream.pipeline.addHandler(serverPipe) }
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
                        channel.close(promise: nil)
                        upstream.close(promise: nil)
                    }
            }
        }
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

    init(
        exchange: ExchangeState,
        method: HTTPMethod,
        client: Channel,
        clientWantsClose: Bool,
        owner: ClientHTTPHandler,
        requestEncoder: HTTPRequestEncoder,
        responseDecoderWrapper: ByteToMessageHandler<HTTPResponseDecoder>
    ) {
        self.exchange = exchange
        self.method = method
        self.client = client
        self.clientWantsClose = clientWantsClose
        self.owner = owner
        self.requestEncoder = requestEncoder
        self.responseDecoderWrapper = responseDecoderWrapper
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            handleResponseHead(head)
        case .body(let body):
            guard !completed else { return }
            captureBody(body)
            forward(.body(.byteBuffer(body)))
        case .end(let trailers):
            guard !completed else { return }
            completed = true
            let finalWrite = forward(.end(trailers))
            owner?.upstreamResponseFinished(exchange, keepAlive: keepAlive, finalWrite: finalWrite)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
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
        headForwarded = true
        forward(.head(outgoing))
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
