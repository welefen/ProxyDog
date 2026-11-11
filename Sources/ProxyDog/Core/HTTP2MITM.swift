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
    let rewriteRulesProvider: @Sendable () -> [RewriteRule]
    let breakpointRulesProvider: @Sendable () -> [BreakpointRule]
    let breakpointGate: BreakpointGate
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
                clientIdentity: config.clientIdentity,
                rewriteRulesProvider: config.rewriteRulesProvider,
                breakpointRulesProvider: config.breakpointRulesProvider,
                breakpointGate: config.breakpointGate
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

    // Rewrite-rule state for the stream's request.
    private var currentRequestHead: HTTPRequestHead?
    private var pendingRequestRule: RewriteRule?
    private var bufferingRuleBody = false
    private var ruleBodyBuffer = Data()
    private var forwardTargetOverride: (host: String, port: Int)?
    private var forwardURIOverride: String?
    private var forwardHostHeaderOverride: String?
    private var forwardBodyOverride: ByteBuffer?
    private var forwardContentLengthOverride: Int?
    private var dropForwardEncodingHeaders = false
    private var responsePhaseRule: RewriteRule?
    private static let maxRewriteBodyBytes = 32 * 1024 * 1024

    // Breakpoint state.
    private var requestBreakpointRule: BreakpointRule?
    private var responseBreakpointRule: BreakpointRule?
    private var bufferingBreakpointBody = false
    private var breakpointBodyBuffer = Data()
    private var requestBreakpointPaused = false

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
        resetRewriteState(head)

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
        state.clientRemoteAddress = config.clientIdentity.remoteAddress
        exchange = state

        let url = RewriteEngine.urlString(scheme: "https", host: target.host, port: target.port, path: state.path)
        let breakpointRules = config.breakpointRulesProvider()
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
        let rules = config.rewriteRulesProvider()
        let rule = requestBreakpointRule == nil
            ? RewriteEngine.requestPhaseRule(rules, method: head.method.rawValue, url: url)
            : nil
        responsePhaseRule = RewriteEngine.responsePhaseRule(rules, method: head.method.rawValue, url: url)
        if let rule {
            state.rewriteRuleName = rule.displayName
            state.rewriteAction = rule.action.label
        }
        config.sink.captureDidUpdate(state.snapshot(state: .pending))

        if requestBreakpointRule != nil {
            // Buffer the request body first; the pause happens when the stream's END_STREAM
            // (or immediately for bodyless requests) arrives.
            bufferingBreakpointBody = true
            breakpointBodyBuffer = Data()
            return
        }

        if let rule {
            switch rule.action {
            case .replaceResponse:
                sendSyntheticResponse(state: state, rule: rule)
                return

            case .redirect:
                if let redirect = RewriteEngine.redirectTarget(rule.redirectURL) {
                    forwardTargetOverride = (redirect.host, redirect.port)
                    forwardURIOverride = redirect.path
                    forwardHostHeaderOverride = RewriteEngine.hostHeader(
                        scheme: redirect.scheme,
                        host: redirect.host,
                        port: redirect.port
                    )
                } else {
                    // Invalid redirect target: ignore the rule instead of failing the stream.
                    state.rewriteRuleName = nil
                    state.rewriteAction = nil
                }

            case .replaceRequest, .modifyRequest:
                pendingRequestRule = rule
                bufferingRuleBody = true
                ruleBodyBuffer = Data()
                return

            case .modifyResponse:
                break
            }
        }

        openUpstream(state: state, head: head, target: forwardTargetOverride ?? target)
    }

    private func handleBody(_ body: ByteBuffer) {
        guard let state = exchange else { return }
        if let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
            state.appendRequestBytes(bytes)
        }
        if bufferingBreakpointBody {
            if breakpointBodyBuffer.count + body.readableBytes > Self.maxRewriteBodyBytes {
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
                // Too large: abandon the rule and forward the buffered bytes followed by this one.
                bufferingRuleBody = false
                pendingRequestRule = nil
                state.rewriteRuleName = nil
                state.rewriteAction = nil
                var buffered = ByteBufferAllocator().buffer(capacity: ruleBodyBuffer.count)
                buffered.writeBytes(ruleBodyBuffer)
                ruleBodyBuffer = Data()
                state.pendingBodyParts.append(buffered)
                if let head = currentRequestHead {
                    openUpstream(state: state, head: head, target: forwardTargetOverride ?? resolveTarget(head))
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

        if bufferingBreakpointBody {
            bufferingBreakpointBody = false
            if requestBreakpointRule != nil {
                presentRequestBreakpoint()
                return
            }
            if !breakpointBodyBuffer.isEmpty {
                forwardBodyOverride = ByteBuffer(bytes: breakpointBodyBuffer)
            }
            breakpointBodyBuffer = Data()
            if let head = currentRequestHead {
                openUpstream(state: state, head: head, target: forwardTargetOverride ?? resolveTarget(head))
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
                state.replaceCapturedRequestBody(forwardedBody)
                forwardBodyOverride = ByteBuffer(bytes: forwardedBody)
                forwardContentLengthOverride = forwardedBody.count
                dropForwardEncodingHeaders = true
            } else if !original.isEmpty {
                forwardBodyOverride = ByteBuffer(bytes: original)
                forwardContentLengthOverride = original.count
            }
            openUpstream(state: state, head: head, target: forwardTargetOverride ?? resolveTarget(head))
            return
        }

        if let upstream, state.upstreamReady {
            upstream.writeAndFlush(HTTPClientRequestPart.end(nil))
        }
    }

    private func resetRewriteState(_ head: HTTPRequestHead) {
        currentRequestHead = head
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

    /// Completes a stream locally with a rule-synthesized response (`.replaceResponse`).
    private func sendSyntheticResponse(state: ExchangeState, rule: RewriteRule) {
        exchange = nil
        finished = true
        let status = RewriteEngine.responseStatus(rule.responseStatus)
        let body = Data(rule.replacementBody.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: RewriteEngine.contentType(rule))
        headers.add(name: "content-length", value: String(body.count))

        state.responseStatusCode = Int(status.code)
        state.responseHeaders = ProxyWire.headerFields(headers)
        state.replaceCapturedResponseBody(body, wireBytes: body.count)

        let completed = state.snapshot(state: .completed)
        lastCompletedCapture = completed
        config.sink.captureDidUpdate(completed)

        guard let channel, channel.isActive else { return }
        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(responseHead))
        if !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes([UInt8](body))
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil))
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
        let connectTarget = forwardTargetOverride ?? target

        ProxyOutboundConnector.connect(
            eventLoop: channel.eventLoop,
            host: connectTarget.host,
            port: connectTarget.port,
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
                let serverHostname = ProxyWire.isIPAddress(connectTarget.host) ? nil : connectTarget.host
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
                owner: self,
                responseRule: self.responsePhaseRule,
                responseBreakpointRule: self.responseBreakpointRule,
                breakpointGate: self.config.breakpointGate
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
        let authority = forwardHostHeaderOverride
            ?? head.headers.first(name: "host")
            ?? "\(target.host):\(target.port)"
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
            if dropForwardEncodingHeaders && lower == "content-encoding" {
                continue
            }
            headers.add(name: name, value: value)
        }
        headers.add(name: "Host", value: authority)
        if let contentLength = forwardContentLengthOverride {
            headers.replaceOrAdd(name: "Content-Length", value: String(contentLength))
        }
        // Same decodable-encoding policy as the HTTP/1.1 path.
        if let clientAcceptEncoding = head.headers.first(name: "accept-encoding") {
            headers.replaceOrAdd(
                name: "Accept-Encoding",
                value: BodyDecompression.upstreamAcceptEncoding(clientValue: clientAcceptEncoding)
            )
        }
        headers.replaceOrAdd(name: "Connection", value: "close")

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
        pendingRequestBytes = 0
        state.upstreamReady = true
        if state.requestEnded {
            upstream.writeAndFlush(HTTPClientRequestPart.end(nil))
        }
        forwardBodyOverride = nil
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
            contentType: head.headers.first(name: "content-type"),
            bodyText: bodyText,
            headers: state.requestHeaders,
            createdAt: Date()
        )
        requestBreakpointPaused = true
        config.breakpointGate.wait(payload: payload, on: channel.eventLoop) { [weak self] decision in
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
            openUpstream(state: state, head: head, target: forwardTargetOverride ?? resolveTarget(head))
        }
    }

    private func finishBreakpointDrop(state: ExchangeState) {
        exchange = nil
        finished = true
        let body = Data("ProxyDog: dropped at breakpoint\n".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/plain; charset=utf-8")
        headers.add(name: "content-length", value: String(body.count))
        state.responseStatusCode = 403
        state.responseHeaders = ProxyWire.headerFields(headers)
        state.replaceCapturedResponseBody(body, wireBytes: body.count)
        let completed = state.snapshot(state: .completed)
        lastCompletedCapture = completed
        config.sink.captureDidUpdate(completed)

        guard let channel, channel.isActive else { return }
        let responseHead = HTTPResponseHead(version: .http1_1, status: .forbidden, headers: headers)
        channel.write(HTTPServerResponsePart.head(responseHead))
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes([UInt8](body))
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        channel.writeAndFlush(HTTPServerResponsePart.end(nil))
    }

    /// `.drop` at a response breakpoint: fail the capture and abort the stream.
    func breakpointDroppedForResponse(_ state: ExchangeState, message: String) {
        guard exchange === state else { return }
        exchange = nil
        finished = true
        config.sink.captureDidUpdate(state.snapshot(state: .failed, error: message))
        closeUpstream()
        channel?.close(promise: nil)
    }

    func breakpointPendingSnapshot(_ state: ExchangeState) {
        guard exchange === state else { return }
        config.sink.captureDidUpdate(state.snapshot(state: .pending))
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
        capture.clientRemoteAddress = config.clientIdentity.remoteAddress
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

    // `.modifyResponse` / response-breakpoint buffering state (identity encoding + exact
    // Content-Length on the wire).
    private let responseRule: RewriteRule?
    private let responseBreakpointRule: BreakpointRule?
    private let breakpointGate: BreakpointGate
    private var buffering = false
    private var bufferedHead: HTTPResponseHead?
    private var bufferedOutgoingHead: HTTPResponseHead?
    private var bufferedBody = Data()
    private var waitingBreakpoint: (original: HTTPResponseHead, outgoing: HTTPResponseHead, rawBody: Data, decodedBody: Data)?
    private static let maxRewriteBodyBytes = 16 * 1024 * 1024

    init(
        exchange: ExchangeState,
        method: HTTPMethod,
        clientChannel: Channel,
        owner: HTTP2StreamProxyHandler,
        responseRule: RewriteRule?,
        responseBreakpointRule: BreakpointRule?,
        breakpointGate: BreakpointGate
    ) {
        self.exchange = exchange
        self.method = method
        self.clientChannel = clientChannel
        self.owner = owner
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
            if let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
                exchange.appendResponseBytes(bytes)
            }
            if buffering {
                appendBufferedBody(body)
                return
            }
            forward(.body(.byteBuffer(body)))
        case .end:
            guard !completed else { return }
            if buffering {
                completed = true
                finalizeBufferedResponse()
                return
            }
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
        if buffering, bufferedHead != nil {
            finalizeBufferedResponse()
            return
        }
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
        if (responseRule != nil || responseBreakpointRule != nil), !noBody {
            // Withhold the head until the body is buffered (rewrite) or the user decides
            // (breakpoint).
            bufferedHead = head
            bufferedOutgoingHead = outgoing
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
            flushBufferedPassthrough()
            forward(.body(.byteBuffer(body)))
            return
        }
        bufferedBody.append(contentsOf: bytes)
    }

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
            breakpointGate.wait(payload: payload, on: clientChannel.eventLoop) { [weak self] decision in
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
            exchange.replaceCapturedResponseBody(breakpointBody, wireBytes: breakpointBody.count)
            sendIdentityResponse(original: original, body: breakpointBody)
            return
        }

        if let rule = responseRule, let decoded, let transformed = rule.transformData(decoded) {
            exchange.rewriteRuleName = rule.displayName
            exchange.rewriteAction = rule.action.label
            exchange.replaceCapturedResponseBody(transformed, wireBytes: transformed.count)
            sendIdentityResponse(original: original, body: transformed)
            return
        }

        // Passthrough: send exactly what the upstream sent.
        headForwarded = true
        forward(.head(outgoing))
        if !rawBody.isEmpty {
            var buffer = clientChannel.allocator.buffer(capacity: rawBody.count)
            buffer.writeBytes([UInt8](rawBody))
            forward(.body(.byteBuffer(buffer)))
        }
        owner?.streamResponseFinished(exchange)
        forward(.end(nil))
    }

    /// Resolves a response breakpoint when the user decides (or the gate times out).
    private func resolveResponseBreakpoint(_ decision: BreakpointDecision) {
        guard let waiting = waitingBreakpoint else { return }
        waitingBreakpoint = nil
        guard clientChannel.isActive else {
            owner?.breakpointDroppedForResponse(exchange, message: "Client closed while paused at a breakpoint.")
            return
        }
        switch decision {
        case .drop:
            owner?.breakpointDroppedForResponse(exchange, message: "Dropped at breakpoint")
        case .resume(let body):
            applyBufferedResponse(
                original: waiting.original,
                outgoing: waiting.outgoing,
                rawBody: waiting.rawBody,
                decoded: waiting.decodedBody,
                breakpointBody: body.map { Data($0.utf8) }
            )
        }
    }

    private func sendIdentityResponse(original: HTTPResponseHead, body: Data) {
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
        headers.replaceOrAdd(name: "content-length", value: String(body.count))
        let responseHead = HTTPResponseHead(version: .http1_1, status: original.status, headers: headers)
        headForwarded = true
        forward(.head(responseHead))
        if !body.isEmpty {
            var buffer = clientChannel.allocator.buffer(capacity: body.count)
            buffer.writeBytes([UInt8](body))
            forward(.body(.byteBuffer(buffer)))
        }
        owner?.streamResponseFinished(exchange)
        forward(.end(nil))
    }

    private func flushBufferedPassthrough() {
        guard buffering, let outgoing = bufferedOutgoingHead else { return }
        buffering = false
        bufferedHead = nil
        bufferedOutgoingHead = nil
        headForwarded = true
        forward(.head(outgoing))
        if !bufferedBody.isEmpty {
            var buffer = clientChannel.allocator.buffer(capacity: bufferedBody.count)
            buffer.writeBytes([UInt8](bufferedBody))
            bufferedBody = Data()
            forward(.body(.byteBuffer(buffer)))
        }
    }

    private func forward(_ part: HTTPServerResponsePart) {
        guard clientChannel.isActive else { return }
        clientChannel.writeAndFlush(part)
    }
}
