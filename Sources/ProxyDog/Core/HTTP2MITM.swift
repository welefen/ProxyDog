import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL

/// Configuration shared by every HTTP/2 stream of one MITM connection.
struct HTTP2MITMConfig: @unchecked Sendable {
    let sink: CaptureSink
    let connectTarget: ProxyConnectTarget
    let upstreamProxyProvider: @Sendable () -> UpstreamProxy?
    let clientIdentity: ClientIdentity
}

/// Client-side HTTP/2 MITM support.
///
/// Design (Charles-style downgrade):
/// * The MITM TLS context advertises `["h2", "http/1.1"]`. After the TLS handshake we route
///   on the negotiated ALPN token: `h2` gets `NIOHTTP2Handler` + an `HTTP2StreamMultiplexer`
///   (server mode); anything else keeps the existing HTTP/1.1 pipeline byte-for-byte.
/// * Every h2 stream is translated to a normal HTTP/1.1 request and forwarded upstream over a
///   *fresh* HTTP/1.1 connection (one connection per stream, no pooling). This keeps the
///   upstream side simple and matches what capture tools do, at the cost of connection
///   setup overhead per stream.
/// * Limitations: no h2 end-to-end (upstream is always HTTP/1.1), no HTTP/2 WebSocket /
///   extended CONNECT, no server push to the client. HTTP/2 trailers are ignored.
enum HTTP2MITM {
    /// Installs the client-facing TLS handler and ALPN routing. Must be called on the
    /// channel's event loop (it is, from `ProxyFrontendHandler`).
    static func install(
        channel: Channel,
        removing frontend: RemovableChannelHandler,
        tlsContext: NIOSSLContext,
        config: HTTP2MITMConfig
    ) -> EventLoopFuture<Void> {
        let pipeline = channel.pipeline
        let sslHandler = NIOSSLServerHandler(context: tlsContext)

        let http1Configurator: NIOChannelInitializer = { channel in
            // Exactly the pre-h2 HTTP/1.1 MITM pipeline.
            var encoderConfiguration = HTTPResponseEncoder.Configuration()
            encoderConfiguration.automaticallySetFramingHeaders = false
            let responseEncoder = HTTPResponseEncoder(configuration: encoderConfiguration)
            let decoderWrapper = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
            let clientHandler = ClientHTTPHandler(
                sink: config.sink,
                connectTarget: config.connectTarget,
                scheme: "https",
                intercepted: true,
                responseEncoder: responseEncoder,
                requestDecoderWrapper: decoderWrapper,
                upstreamProxyProvider: config.upstreamProxyProvider,
                clientIdentity: config.clientIdentity
            )
            return channel.pipeline.addHandler(responseEncoder)
                .flatMap { channel.pipeline.addHandler(decoderWrapper) }
                .flatMap { channel.pipeline.addHandler(clientHandler) }
        }

        let http2Configurator: NIOChannelInitializer = { channel in
            channel.configureHTTP2Pipeline(
                mode: .server,
                targetWindowSize: 65_535
            ) { streamChannel -> EventLoopFuture<Void> in
                let codec = HTTP2FramePayloadToHTTP1ServerCodec()
                let handler = HTTP2StreamProxyHandler(config: config)
                return streamChannel.pipeline.addHandler(codec)
                    .flatMap { streamChannel.pipeline.addHandler(handler) }
            }.map { _ in () }
        }

        return pipeline.removeHandler(frontend)
            .flatMap { pipeline.addHandler(sslHandler, position: .first) }
            .flatMap {
                channel.configureHTTP2SecureUpgrade(
                    h2ChannelConfigurator: http2Configurator,
                    http1ChannelConfigurator: http1Configurator
                )
            }
    }
}

// MARK: - Per-stream proxy

/// Handles one HTTP/2 stream (HTTP/1-style parts in and out via `HTTP2FramePayloadToHTTP1ServerCodec`).
final class HTTP2StreamProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let config: HTTP2MITMConfig

    private var channel: Channel?
    private var exchange: ExchangeState?
    private var upstream: Channel?
    private var relay: HTTP2UpstreamRelayHandler?
    private var lastCompletedCapture: CapturedRequest?
    private var responseStarted = false
    private var finished = false
    private var pendingRequestBytes = 0
    private let maxPendingRequestBytes = 16 * 1024 * 1024

    init(config: HTTP2MITMConfig) {
        self.config = config
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        config.clientIdentity.observe(on: context.eventLoop) { [weak self] process in
            self?.applyClientProcess(process)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            handleHead(head)
        case .body(let body):
            handleBody(body)
        case .end:
            handleEnd()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let state = exchange {
            exchange = nil
            config.sink.captureDidUpdate(
                state.snapshot(state: .failed, error: "The client cancelled the HTTP/2 stream.")
            )
        }
        closeUpstream()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let state = exchange {
            exchange = nil
            config.sink.captureDidUpdate(
                state.snapshot(state: .failed, error: ProxyWire.readableError(error))
            )
        }
        closeUpstream()
        context.close(promise: nil)
    }

    /// Called by the upstream relay once the full response has been forwarded.
    func streamResponseFinished(_ state: ExchangeState) {
        guard exchange === state else { return }
        exchange = nil
        state.decodeCapturedBodies()
        let completed = state.snapshot(state: .completed)
        lastCompletedCapture = completed
        config.sink.captureDidUpdate(completed)
        closeUpstream()
    }

    /// Called by the upstream relay / upstream setup on failure.
    func streamResponseFailed(_ state: ExchangeState, message: String, responseStarted: Bool) {
        guard exchange === state else { return }
        exchange = nil
        finished = true
        config.sink.captureDidUpdate(state.snapshot(state: .failed, error: message))
        closeUpstream()
        if responseStarted {
            // The response head already went out; abort the stream so the client sees a failure
            // instead of a truncated but seemingly valid body.
            channel?.close(promise: nil)
        } else {
            self.responseStarted = true
            sendSimpleResponse(status: .badGateway, message: message)
        }
    }

    // MARK: Request handling

    private func handleHead(_ head: HTTPRequestHead) {
        guard exchange == nil, !finished else { return }

        // HTTP/2 WebSocket / extended CONNECT: refuse with a readable capture instead of crashing.
        if head.method == .CONNECT {
            refuseUnsupported(
                head,
                reason: "HTTP/2 extended CONNECT (WebSocket over HTTP/2) is not supported by ProxyDog."
            )
            return
        }
        if head.headers.first(name: "upgrade") != nil {
            refuseUnsupported(
                head,
                reason: "HTTP/2 WebSocket upgrades are not supported by ProxyDog."
            )
            return
        }

        let target = resolveTarget(head)
        let state = ExchangeState(
            method: head.method.rawValue,
            scheme: "https",
            host: target.host,
            port: target.port,
            path: head.uri.isEmpty ? "/" : head.uri,
            intercepted: true,
            requestHeaders: ProxyWire.headerFields(head.headers),
            clientSignature: ProxyWire.clientSignature(from: head.headers),
            isUpgradeRequest: false
        )
        state.httpVersion = "HTTP/2"
        state.clientProcess = config.clientIdentity.current
        exchange = state
        config.sink.captureDidUpdate(state.snapshot(state: .pending))
        openUpstream(state: state, head: head, target: target)
    }

    private func handleBody(_ body: ByteBuffer) {
        guard let state = exchange else { return }
        if let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
            state.appendRequestBytes(bytes)
        }
        if let upstream, state.upstreamReady {
            upstream.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(body)))
        } else {
            pendingRequestBytes += body.readableBytes
            if pendingRequestBytes > maxPendingRequestBytes {
                failExchange(message: "The HTTP/2 request body is too large to buffer while connecting upstream.")
                return
            }
            state.pendingBodyParts.append(body)
        }
    }

    private func handleEnd() {
        guard let state = exchange else { return }
        state.requestEnded = true
        // HTTP/2 trailers are deliberately ignored.
        state.pendingTrailers = nil
        if let upstream, state.upstreamReady {
            upstream.writeAndFlush(HTTPClientRequestPart.end(nil))
        }
    }

    // MARK: Upstream connection

    private func resolveTarget(_ head: HTTPRequestHead) -> (host: String, port: Int) {
        let authority = head.headers.first(name: "host")
            ?? "\(config.connectTarget.host):\(config.connectTarget.port)"
        return ProxyWire.splitAuthority(authority, defaultPort: config.connectTarget.port)
            ?? (config.connectTarget.host, config.connectTarget.port)
    }

    private func openUpstream(state: ExchangeState, head: HTTPRequestHead, target: (host: String, port: Int)) {
        guard let channel else { return }
        let proxy = config.upstreamProxyProvider()

        ProxyOutboundConnector.connect(
            eventLoop: channel.eventLoop,
            host: target.host,
            port: target.port,
            proxy: proxy
        )
        .flatMap { (upstreamChannel: Channel, leftover: ByteBuffer) -> EventLoopFuture<(Channel, HTTP2UpstreamRelayHandler)> in
            let eventLoop = upstreamChannel.eventLoop
            guard let tlsContext = ProxyOutboundTLS.context else {
                upstreamChannel.close(promise: nil)
                return eventLoop.makeFailedFuture(ProxyError.tlsUnavailable)
            }
            let sslHandler: NIOSSLClientHandler
            do {
                // Upstream is always HTTP/1.1, even when the client spoke HTTP/2.
                let serverHostname = ProxyWire.isIPAddress(target.host) ? nil : target.host
                sslHandler = try NIOSSLClientHandler(context: tlsContext, serverHostname: serverHostname)
            } catch {
                upstreamChannel.close(promise: nil)
                return eventLoop.makeFailedFuture(error)
            }
            let requestEncoder = HTTPRequestEncoder()
            let responseDecoder = ByteToMessageHandler(
                HTTPResponseDecoder(
                    leftOverBytesStrategy: .forwardBytes,
                    informationalResponseStrategy: .forward
                )
            )
            let relay = HTTP2UpstreamRelayHandler(
                exchange: state,
                method: head.method,
                clientChannel: channel,
                owner: self
            )
            return upstreamChannel.pipeline.addHandler(sslHandler)
                .flatMap { upstreamChannel.pipeline.addHandler(requestEncoder) }
                .flatMap { upstreamChannel.pipeline.addHandler(responseDecoder) }
                .flatMap { upstreamChannel.pipeline.addHandler(relay) }
                .map {
                    if leftover.readableBytes > 0 {
                        upstreamChannel.pipeline.fireChannelRead(leftover)
                    }
                    return (upstreamChannel, relay)
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
                self.startUpstreamRequest(state: state, head: head, target: target, upstream: upstreamChannel)
            case .failure(let error):
                self.failExchange(message: ProxyWire.readableError(error))
            }
        }
    }

    private func startUpstreamRequest(
        state: ExchangeState,
        head: HTTPRequestHead,
        target: (host: String, port: Int),
        upstream: Channel
    ) {
        var headers = HTTPHeaders()
        let authority = head.headers.first(name: "host") ?? "\(target.host):\(target.port)"
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "host"
                || lower == "connection"
                || lower == "keep-alive"
                || lower == "proxy-connection"
                || lower == "transfer-encoding"
                || lower == "upgrade"
                || lower == "te" {
                continue
            }
            headers.add(name: name, value: value)
        }
        headers.add(name: "Host", value: authority)
        // Same decodable-encoding policy as the HTTP/1.1 path.
        if let clientAcceptEncoding = head.headers.first(name: "accept-encoding") {
            headers.replaceOrAdd(
                name: "Accept-Encoding",
                value: BodyDecompression.upstreamAcceptEncoding(clientValue: clientAcceptEncoding)
            )
        }
        headers.replaceOrAdd(name: "Connection", value: "close")

        let outgoing = HTTPRequestHead(version: .http1_1, method: head.method, uri: state.path, headers: headers)
        upstream.writeAndFlush(HTTPClientRequestPart.head(outgoing))
        for part in state.pendingBodyParts {
            upstream.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(part)))
        }
        state.pendingBodyParts.removeAll()
        pendingRequestBytes = 0
        state.upstreamReady = true
        if state.requestEnded {
            upstream.writeAndFlush(HTTPClientRequestPart.end(nil))
        }
    }

    // MARK: Failures / refusals

    private func refuseUnsupported(_ head: HTTPRequestHead, reason: String) {
        finished = true
        let target = resolveTarget(head)
        var capture = CapturedRequest(
            method: head.method.rawValue,
            httpVersion: "HTTP/2",
            scheme: "https",
            host: target.host,
            port: target.port,
            path: head.uri.isEmpty ? "/" : head.uri,
            intercepted: true,
            requestHeaders: ProxyWire.headerFields(head.headers),
            state: .failed,
            errorMessage: reason,
            clientSignature: ProxyWire.clientSignature(from: head.headers)
        )
        capture.applyClientProcess(config.clientIdentity.current)
        config.sink.captureDidUpdate(capture)
        responseStarted = true
        sendSimpleResponse(status: .notImplemented, message: reason)
    }

    private func failExchange(message: String) {
        guard let state = exchange else { return }
        exchange = nil
        finished = true
        config.sink.captureDidUpdate(state.snapshot(state: .failed, error: message))
        closeUpstream()
        responseStarted = true
        sendSimpleResponse(status: .badGateway, message: message)
    }

    private func sendSimpleResponse(status: HTTPResponseStatus, message: String) {
        guard let channel, channel.isActive else { return }
        let body = Data("ProxyDog: \(message)\n".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/plain; charset=utf-8")
        headers.add(name: "content-length", value: String(body.count))
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head))
        if !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes([UInt8](body))
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    // MARK: Attribution

    private func applyClientProcess(_ process: ClientProcess?) {
        guard let process else { return }
        if let state = exchange {
            state.clientProcess = process
            config.sink.captureDidUpdate(state.snapshot(state: .pending))
        }
        if var last = lastCompletedCapture {
            last.applyClientProcess(process)
            lastCompletedCapture = last
            config.sink.captureDidUpdate(last)
        }
    }

    private func closeUpstream() {
        relay = nil
        if let upstream {
            self.upstream = nil
            upstream.close(promise: nil)
        }
    }
}

// MARK: - Upstream HTTP/1.1 response relay for one h2 stream

/// Reads the HTTP/1.1 response from the per-stream upstream connection and writes equivalent
/// HTTP/1-style parts onto the h2 stream channel (the codec turns them into HEADERS/DATA).
final class HTTP2UpstreamRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let exchange: ExchangeState
    private let method: HTTPMethod
    private let clientChannel: Channel
    private weak var owner: HTTP2StreamProxyHandler?

    private var headForwarded = false
    private var completed = false
    private var closeDelimited = false

    init(
        exchange: ExchangeState,
        method: HTTPMethod,
        clientChannel: Channel,
        owner: HTTP2StreamProxyHandler
    ) {
        self.exchange = exchange
        self.method = method
        self.clientChannel = clientChannel
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            handleResponseHead(head)
        case .body(let body):
            guard !completed else { return }
            if let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
                exchange.appendResponseBytes(bytes)
            }
            forward(.body(.byteBuffer(body)))
        case .end:
            guard !completed else { return }
            completed = true
            // Finish the capture *before* writing END_STREAM: the stream channel may become
            // inactive synchronously when the end frame is written, and that must not be
            // mistaken for a client cancellation.
            owner?.streamResponseFinished(exchange)
            forward(.end(nil))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        if headForwarded, closeDelimited {
            owner?.streamResponseFinished(exchange)
            forward(.end(nil))
        } else {
            owner?.streamResponseFailed(
                exchange,
                message: headForwarded
                    ? "The upstream server closed the connection before the response completed."
                    : "The upstream server closed the connection without sending a response.",
                responseStarted: headForwarded
            )
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        owner?.streamResponseFailed(
            exchange,
            message: ProxyWire.readableError(error),
            responseStarted: headForwarded
        )
    }

    private func handleResponseHead(_ head: HTTPResponseHead) {
        guard !completed, !headForwarded else { return }
        let code = head.status.code
        // Informational responses are not forwarded to the h2 client.
        if (100..<200).contains(code) { return }
        exchange.responseStatusCode = Int(code)
        exchange.responseHeaders = ProxyWire.headerFields(head.headers)

        let noBody = method == .HEAD || code == 204 || code == 304
        let transferEncoding = (head.headers.first(name: "transfer-encoding") ?? "").lowercased()
        let hasContentLength = head.headers.first(name: "content-length") != nil
        closeDelimited = !noBody && !transferEncoding.contains("chunked") && !hasContentLength

        var headers = HTTPHeaders()
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "connection"
                || lower == "keep-alive"
                || lower == "proxy-connection"
                || lower == "transfer-encoding"
                || lower == "upgrade" {
                continue
            }
            headers.add(name: name, value: value)
        }
        // HTTP/2 forbids Content-Length on 204 responses.
        if code == 204 {
            headers.remove(name: "content-length")
        }

        let outgoing = HTTPResponseHead(version: .http1_1, status: head.status, headers: headers)
        headForwarded = true
        forward(.head(outgoing))
    }

    private func forward(_ part: HTTPServerResponsePart) {
        guard clientChannel.isActive else { return }
        clientChannel.writeAndFlush(part)
    }
}
