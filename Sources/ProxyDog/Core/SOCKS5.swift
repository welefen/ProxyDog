import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

// MARK: - SOCKS5 protocol helpers

enum SOCKS5 {
    static let version: UInt8 = 0x05

    /// Human readable description of a SOCKS5 reply code (RFC 1928 section 6).
    static func replyDescription(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "succeeded"
        case 0x01: return "general SOCKS server failure"
        case 0x02: return "connection not allowed by ruleset"
        case 0x03: return "network unreachable"
        case 0x04: return "host unreachable"
        case 0x05: return "connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported"
        case 0x08: return "address type not supported"
        default: return "unknown error"
        }
    }

    static func hex(_ byte: UInt8) -> String {
        String(format: "0x%02x", byte)
    }

    static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        let ok = host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
        guard ok else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let ok = host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        guard ok else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func formatIPv4(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 4 else { return nil }
        var address = in_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    static func formatIPv6(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// Conservative HTTP/1.x request detection: request lines start with an uppercase method token.
    static func looksLikeHTTPFirstByte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte)
    }

    /// Maps a connection error to the closest SOCKS5 reply code.
    static func replyCode(for error: Error) -> UInt8 {
        if let proxyError = error as? ProxyError, case .upstreamProxyFailed(let message) = proxyError {
            let lowered = message.lowercased()
            if lowered.contains("refused") || lowered.contains("connection refused") { return 0x05 }
            if lowered.contains("timed out") || lowered.contains("timeout") { return 0x06 }
            if lowered.contains("unreachable") || lowered.contains("resolve") { return 0x04 }
            return 0x01
        }
        if let connectionError = error as? NIOConnectionError {
            if connectionError.dnsAError != nil || connectionError.dnsAAAAError != nil { return 0x04 }
            return 0x05
        }
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNREFUSED: return 0x05
            case ENETUNREACH: return 0x03
            case EHOSTUNREACH: return 0x04
            case ETIMEDOUT: return 0x06
            default: return 0x01
            }
        }
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return 0x06
        }
        if let proxyError = error as? ProxyError, case .tlsUnavailable = proxyError {
            return 0x01
        }
        return 0x01
    }
}

// MARK: - Upstream SOCKS5 handshake (ProxyDog -> upstream SOCKS5 proxy)

/// Performs the client side of a SOCKS5 no-auth handshake and a CONNECT request against an
/// upstream SOCKS5 proxy. `future` completes with the bytes the target sent directly after
/// the success reply (they must be re-injected into the tunnel pipeline).
final class UpstreamSOCKS5HandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, UpstreamTunnelHandshakeHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private enum Phase {
        case greetingReply
        case connectReply
    }

    private let proxy: UpstreamProxy
    private let targetHost: String
    private let targetPort: Int
    private let promise: EventLoopPromise<ByteBuffer>
    private let timeout: TimeAmount

    private var buffer = ByteBufferAllocator().buffer(capacity: 0)
    private var leftover: ByteBuffer?
    private var channel: Channel?
    private var phase: Phase = .greetingReply
    private var started = false
    private var completed = false
    private var timeoutTask: Scheduled<Void>?

    private var proxyName: String { "\(proxy.host):\(proxy.port)" }

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
        process(context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        fail("Upstream SOCKS5 proxy \(proxyName) closed the connection while establishing a tunnel to \(targetHost):\(targetPort).", closeChannel: false)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        fail("Upstream SOCKS5 proxy \(proxyName) connection failed while establishing a tunnel to \(targetHost):\(targetPort): \(ProxyWire.readableError(error))")
    }

    // MARK: Implementation

    private func start(_ context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        var greeting = context.channel.allocator.buffer(capacity: 3)
        greeting.writeBytes([0x05, 0x01, 0x00])
        context.channel.writeAndFlush(greeting).whenFailure { [weak self] error in
            guard let self else { return }
            self.fail("Upstream SOCKS5 proxy \(self.proxyName) could not be reached: \(ProxyWire.readableError(error))")
        }
        timeoutTask = context.eventLoop.scheduleTask(in: timeout) { [weak self] in
            guard let self else { return }
            self.fail("Upstream SOCKS5 proxy \(self.proxyName) timed out while establishing a tunnel to \(self.targetHost):\(self.targetPort).")
        }
    }

    private func process(context: ChannelHandlerContext) {
        while !completed {
            switch phase {
            case .greetingReply:
                guard buffer.readableBytes >= 2 else { return }
                let version = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) ?? 0
                let method = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) ?? 0xff
                buffer.moveReaderIndex(forwardBy: 2)
                guard version == 0x05 else {
                    fail("Upstream SOCKS5 proxy \(proxyName) sent an invalid greeting (version \(SOCKS5.hex(version))).")
                    return
                }
                if method == 0xff {
                    fail("Upstream SOCKS5 proxy \(proxyName) rejected no-auth authentication (no acceptable methods).")
                    return
                }
                guard method == 0x00 else {
                    fail("Upstream SOCKS5 proxy \(proxyName) selected unsupported authentication method \(SOCKS5.hex(method)).")
                    return
                }
                guard sendConnectRequest(context: context) else { return }
                phase = .connectReply

            case .connectReply:
                guard buffer.readableBytes >= 4 else { return }
                let version = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) ?? 0
                let reply = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) ?? 0
                let addressType = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self) ?? 0
                guard version == 0x05 else {
                    fail("Upstream SOCKS5 proxy \(proxyName) sent an invalid CONNECT reply (version \(SOCKS5.hex(version))).")
                    return
                }

                let addressLength: Int
                switch addressType {
                case 0x01:
                    addressLength = 4
                case 0x04:
                    addressLength = 16
                case 0x03:
                    guard buffer.readableBytes >= 5 else { return }
                    let length = buffer.getInteger(at: buffer.readerIndex + 4, as: UInt8.self) ?? 0
                    addressLength = 1 + Int(length)
                default:
                    fail("Upstream SOCKS5 proxy \(proxyName) sent an unsupported address type \(SOCKS5.hex(addressType)) in its CONNECT reply.")
                    return
                }

                let totalLength = 4 + addressLength + 2
                guard buffer.readableBytes >= totalLength else { return }
                buffer.moveReaderIndex(forwardBy: totalLength)

                guard reply == 0x00 else {
                    fail("Upstream SOCKS5 proxy \(proxyName) refused CONNECT to \(targetHost):\(targetPort) (reply \(SOCKS5.hex(reply)): \(SOCKS5.replyDescription(reply))).")
                    return
                }
                completeSuccess(context: context)
                return
            }
        }
    }

    /// Sends the SOCKS5 CONNECT request; returns false when the target address is invalid.
    private func sendConnectRequest(context: ChannelHandlerContext) -> Bool {
        var request = context.channel.allocator.buffer(capacity: 16)
        request.writeBytes([0x05, 0x01, 0x00])

        if let ipv4 = SOCKS5.ipv4Bytes(targetHost) {
            request.writeBytes([0x01])
            request.writeBytes(ipv4)
        } else if let ipv6 = SOCKS5.ipv6Bytes(targetHost) {
            request.writeBytes([0x04])
            request.writeBytes(ipv6)
        } else {
            let nameBytes = Array(targetHost.utf8)
            guard !nameBytes.isEmpty, nameBytes.count <= 255 else {
                fail("Upstream SOCKS5 proxy \(proxyName) cannot CONNECT to \"\(targetHost)\": invalid or too long target host name.")
                return false
            }
            request.writeBytes([0x03, UInt8(nameBytes.count)])
            request.writeBytes(nameBytes)
        }
        request.writeInteger(UInt16(targetPort), endianness: .big, as: UInt16.self)
        context.channel.writeAndFlush(request).whenFailure { [weak self] error in
            guard let self else { return }
            self.fail("Upstream SOCKS5 proxy \(self.proxyName) could not be reached: \(ProxyWire.readableError(error))")
        }
        return true
    }

    private func completeSuccess(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if buffer.readableBytes > 0 {
            var remaining = ByteBufferAllocator().buffer(capacity: 0)
            remaining.writeBuffer(&buffer)
            if var existing = leftover {
                existing.writeBuffer(&remaining)
                leftover = existing
            } else {
                leftover = remaining
            }
        }
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

// MARK: - SOCKS5 listener (client -> ProxyDog)

/// Handles one accepted SOCKS5 client connection:
/// greeting (no-auth) -> CONNECT -> preflight connection to the target (respecting the
/// configured upstream proxy) -> success reply -> sniff the first payload byte:
/// TLS (0x16) gets MITM + HTTP capture, HTTP request bytes get plain HTTP capture, anything
/// else becomes a raw byte tunnel without capture.
final class SOCKS5ListenerHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private enum Phase {
        case greeting
        case request
        case connecting
        case sniffing
        case tunneling
    }

    private let sink: CaptureSink
    private let certificateAuthority: CertificateAuthority
    private let upstreamProxyProvider: @Sendable () -> UpstreamProxy?
    /// Local app that owns this SOCKS5 client connection (attributed once per connection).
    private let clientIdentity = ClientIdentity()

    private var channel: Channel?
    private var context: ChannelHandlerContext?
    private var buffer = ByteBufferAllocator().buffer(capacity: 0)
    private var phase: Phase = .greeting
    private var target: ProxyConnectTarget?
    private var preflight: Channel?
    private var targetLeftover: ByteBuffer?
    private var timeoutTask: Scheduled<Void>?
    private var finished = false

    private let handshakeTimeout: TimeAmount = .seconds(10)
    private let maxBufferedBytes = 4 * 1024 * 1024

    init(
        sink: CaptureSink,
        certificateAuthority: CertificateAuthority,
        upstreamProxyProvider: @Sendable @escaping () -> UpstreamProxy?
    ) {
        self.sink = sink
        self.certificateAuthority = certificateAuthority
        self.upstreamProxyProvider = upstreamProxyProvider
    }

    // MARK: Channel lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        self.channel = context.channel
        self.context = context
        timeoutTask = context.eventLoop.scheduleTask(in: handshakeTimeout) { [weak self] in
            self?.abortForTimeout()
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        attributeClientProcess(context: context)
        context.fireChannelActive()
    }

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
        buffer.writeBuffer(&incoming)
        guard !finished else { return }
        if buffer.readableBytes > maxBufferedBytes, phase != .sniffing, phase != .connecting {
            context.close(promise: nil)
            return
        }
        process(context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelTimeout()
        preflight?.close(promise: nil)
        preflight = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        cancelTimeout()
        preflight?.close(promise: nil)
        preflight = nil
        context.close(promise: nil)
    }

    // MARK: Protocol

    private func process(context: ChannelHandlerContext) {
        while !finished {
            switch phase {
            case .greeting:
                guard buffer.readableBytes >= 2 else { return }
                let version = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) ?? 0
                let methodCount = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) ?? 0
                guard version == 0x05, methodCount > 0 else {
                    context.close(promise: nil)
                    return
                }
                let methodsLength = 2 + Int(methodCount)
                guard buffer.readableBytes >= methodsLength else { return }
                let methods = buffer.getBytes(at: buffer.readerIndex + 2, length: Int(methodCount)) ?? []
                buffer.moveReaderIndex(forwardBy: methodsLength)
                guard methods.contains(0x00) else {
                    sendRaw([0x05, 0xff], closeAfter: true)
                    return
                }
                sendRaw([0x05, 0x00], closeAfter: false)
                phase = .request

            case .request:
                guard buffer.readableBytes >= 4 else { return }
                let version = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) ?? 0
                let command = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) ?? 0
                let addressType = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self) ?? 0
                guard version == 0x05 else {
                    context.close(promise: nil)
                    return
                }
                guard command == 0x01 else {
                    // BIND / UDP ASSOCIATE are not supported.
                    sendSOCKSReply(0x07, closeAfter: true)
                    return
                }

                let addressLength: Int
                switch addressType {
                case 0x01:
                    addressLength = 4
                case 0x04:
                    addressLength = 16
                case 0x03:
                    guard buffer.readableBytes >= 5 else { return }
                    let length = buffer.getInteger(at: buffer.readerIndex + 4, as: UInt8.self) ?? 0
                    addressLength = 1 + Int(length)
                default:
                    sendSOCKSReply(0x08, closeAfter: true)
                    return
                }
                let totalLength = 4 + addressLength + 2
                guard buffer.readableBytes >= totalLength else { return }
                guard let requestBytes = buffer.getBytes(at: buffer.readerIndex, length: totalLength) else {
                    context.close(promise: nil)
                    return
                }
                buffer.moveReaderIndex(forwardBy: totalLength)

                guard let parsed = parseConnectRequest(requestBytes, addressType: addressType, addressLength: addressLength) else {
                    sendSOCKSReply(0x08, closeAfter: true)
                    return
                }
                let connectTarget = ProxyConnectTarget(host: parsed.host, port: parsed.port)
                target = connectTarget
                phase = .connecting
                startPreflight(context: context, target: connectTarget)
                return

            case .sniffing:
                if let target {
                    maybeSniff(context: context, target: target)
                }
                return

            case .connecting, .tunneling:
                return
            }
        }
    }

    private func parseConnectRequest(
        _ bytes: [UInt8],
        addressType: UInt8,
        addressLength: Int
    ) -> (host: String, port: Int)? {
        let addressStart = 4
        let addressBytes = Array(bytes[addressStart..<(addressStart + addressLength)])
        let portStart = addressStart + addressLength
        guard bytes.count >= portStart + 2 else { return nil }
        let port = Int(bytes[portStart]) << 8 | Int(bytes[portStart + 1])
        guard port > 0 else { return nil }

        switch addressType {
        case 0x01:
            guard let host = SOCKS5.formatIPv4(addressBytes) else { return nil }
            return (host, port)
        case 0x04:
            guard let host = SOCKS5.formatIPv6(addressBytes) else { return nil }
            return (host, port)
        case 0x03:
            guard addressBytes.count >= 1 else { return nil }
            let length = Int(addressBytes[0])
            guard addressBytes.count == length + 1 else { return nil }
            let nameBytes = Array(addressBytes[1...])
            guard let host = String(bytes: nameBytes, encoding: .utf8), !host.isEmpty else { return nil }
            return (host, port)
        default:
            return nil
        }
    }

    // MARK: Target connection

    private func startPreflight(context: ChannelHandlerContext, target: ProxyConnectTarget) {
        let proxy = upstreamProxyProvider()
        ProxyOutboundConnector.connect(
            eventLoop: context.eventLoop,
            host: target.host,
            port: target.port,
            proxy: proxy
        ).whenComplete { [weak self] result in
            guard let self, !self.finished else {
                if case .success(let (channel, _)) = result { channel.close(promise: nil) }
                return
            }
            switch result {
            case .success(let (upstreamChannel, leftover)):
                self.preflight = upstreamChannel
                self.targetLeftover = leftover
                self.cancelTimeout()
                self.sendSOCKSReply(0x00, closeAfter: false)
                if leftover.readableBytes > 0 {
                    // The target spoke first: this is not TLS/HTTP from the client's side.
                    self.installRawTunnel(context: context, target: target)
                } else {
                    self.phase = .sniffing
                    self.maybeSniff(context: context, target: target)
                }
            case .failure(let error):
                self.cancelTimeout()
                // Surface the failure in the capture list as well; the protocol was not sniffed
                // yet, so report it as a failed CONNECT.
                let message: String
                if let proxy {
                    message = ProxyOutboundConnector.connectionFailureMessage(error, proxy: proxy)
                } else {
                    message = ProxyWire.readableError(error)
                }
                let request = CapturedRequest(
                    method: "CONNECT",
                    scheme: (target.port == 443 ? "https" : "http"),
                    host: target.host,
                    port: target.port,
                    path: "",
                    intercepted: false,
                    state: .failed,
                    errorMessage: message
                )
                self.emitCapture(request, eventLoop: context.eventLoop)
                self.sendSOCKSReply(SOCKS5.replyCode(for: error), closeAfter: true)
            }
        }
    }

    private func maybeSniff(context: ChannelHandlerContext, target: ProxyConnectTarget) {
        guard !finished, phase == .sniffing else { return }
        guard let firstByte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else { return }
        finished = true
        phase = .tunneling

        if firstByte == 0x16 {
            installTLSMITM(context: context, target: target)
        } else if SOCKS5.looksLikeHTTPFirstByte(firstByte) {
            installPlainHTTP(context: context, target: target)
        } else {
            installRawTunnel(context: context, target: target)
        }
    }

    // MARK: Tunnel / pipeline installation

    private func installTLSMITM(context: ChannelHandlerContext, target: ProxyConnectTarget) {
        let channel = context.channel
        closePreflight()

        let promise = channel.eventLoop.makePromise(of: NIOSSLContext.self)
        certificateAuthority.tlsContext(forHost: target.host) { result in
            promise.completeWith(result)
        }

        channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
            promise.futureResult
                .flatMap { tlsContext -> EventLoopFuture<Void> in
                    var encoderConfiguration = HTTPResponseEncoder.Configuration()
                    encoderConfiguration.automaticallySetFramingHeaders = false
                    let responseEncoder = HTTPResponseEncoder(configuration: encoderConfiguration)
                    let decoderWrapper = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                    let clientHandler = ClientHTTPHandler(
                        sink: self.sink,
                        connectTarget: target,
                        scheme: "https",
                        intercepted: true,
                        responseEncoder: responseEncoder,
                        requestDecoderWrapper: decoderWrapper,
                        upstreamProxyProvider: self.upstreamProxyProvider,
                        clientIdentity: self.clientIdentity
                    )
                    let serverHandler = NIOSSLServerHandler(context: tlsContext)
                    return channel.pipeline.removeHandler(self)
                        .flatMap { channel.pipeline.addHandler(serverHandler, position: .first) }
                        .flatMap { channel.pipeline.addHandler(responseEncoder) }
                        .flatMap { channel.pipeline.addHandler(decoderWrapper) }
                        .flatMap { channel.pipeline.addHandler(clientHandler) }
                        .map {
                            let initialBytes = self.takeBufferedBytes()
                            if initialBytes.readableBytes > 0 {
                                channel.pipeline.fireChannelRead(initialBytes)
                            }
                            channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
                        }
                }
                .whenFailure { _ in
                    channel.close(promise: nil)
                }
        }
    }

    private func installPlainHTTP(context: ChannelHandlerContext, target: ProxyConnectTarget) {
        let channel = context.channel
        closePreflight()

        var encoderConfiguration = HTTPResponseEncoder.Configuration()
        encoderConfiguration.automaticallySetFramingHeaders = false
        let responseEncoder = HTTPResponseEncoder(configuration: encoderConfiguration)
        let decoderWrapper = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let clientHandler = ClientHTTPHandler(
            sink: sink,
            connectTarget: target,
            scheme: "http",
            intercepted: false,
            responseEncoder: responseEncoder,
            requestDecoderWrapper: decoderWrapper,
            upstreamProxyProvider: upstreamProxyProvider,
            clientIdentity: clientIdentity
        )

        channel.setOption(ChannelOptions.autoRead, value: false)
            .flatMap { channel.pipeline.removeHandler(self) }
            .flatMap { channel.pipeline.addHandler(responseEncoder) }
            .flatMap { channel.pipeline.addHandler(decoderWrapper) }
            .flatMap { channel.pipeline.addHandler(clientHandler) }
            .map {
                let initialBytes = self.takeBufferedBytes()
                if initialBytes.readableBytes > 0 {
                    channel.pipeline.fireChannelRead(initialBytes)
                }
                channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            }
            .whenFailure { _ in
                channel.close(promise: nil)
            }
    }

    private func installRawTunnel(context: ChannelHandlerContext, target: ProxyConnectTarget) {
        guard let upstream = preflight else {
            context.close(promise: nil)
            return
        }
        preflight = nil
        let channel = context.channel
        let clientPipe = TunnelPipeHandler(allocator: channel.allocator)
        let serverPipe = TunnelPipeHandler(allocator: upstream.allocator)
        let leftover = targetLeftover
        targetLeftover = nil

        channel.setOption(ChannelOptions.autoRead, value: false)
            .flatMap { channel.pipeline.addHandler(clientPipe) }
            .flatMap { channel.pipeline.removeHandler(self) }
            .flatMap { upstream.pipeline.addHandler(serverPipe) }
            .map {
                let initialBytes = self.takeBufferedBytes()
                if let leftover, leftover.readableBytes > 0 {
                    channel.writeAndFlush(leftover)
                }
                if initialBytes.readableBytes > 0 {
                    upstream.writeAndFlush(initialBytes)
                }
                clientPipe.attach(upstream)
                serverPipe.attach(channel)
                channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
                upstream.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            }
            .whenFailure { _ in
                channel.close(promise: nil)
                upstream.close(promise: nil)
            }
    }

    // MARK: Helpers

    /// Emits a capture with client-process attribution, re-emitting a patched snapshot if
    /// the libproc probe finishes later.
    private func emitCapture(_ request: CapturedRequest, eventLoop: EventLoop) {
        var attributed = request
        attributed.applyClientProcess(clientIdentity.current)
        sink.captureDidUpdate(attributed)

        guard clientIdentity.current == nil else { return }
        clientIdentity.observe(on: eventLoop) { [weak self] process in
            guard let self, let process else { return }
            var patched = request
            patched.applyClientProcess(process)
            self.sink.captureDidUpdate(patched)
        }
    }

    private func sendSOCKSReply(_ reply: UInt8, closeAfter: Bool) {
        sendRaw([0x05, reply, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], closeAfter: closeAfter)
    }

    private func sendRaw(_ bytes: [UInt8], closeAfter: Bool) {
        guard let channel, channel.isActive else { return }
        var output = channel.allocator.buffer(capacity: bytes.count)
        output.writeBytes(bytes)
        channel.writeAndFlush(output).whenComplete { _ in
            if closeAfter {
                channel.close(promise: nil)
            }
        }
    }

    private func takeBufferedBytes() -> ByteBuffer {
        var bytes = ByteBufferAllocator().buffer(capacity: 0)
        if buffer.readableBytes > 0 {
            bytes.writeBuffer(&buffer)
        }
        return bytes
    }

    private func closePreflight() {
        preflight?.close(promise: nil)
        preflight = nil
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func abortForTimeout() {
        guard !finished else { return }
        finished = true
        closePreflight()
        if phase == .greeting || phase == .request {
            sendSOCKSReply(0x06, closeAfter: true)
        } else {
            channel?.close(promise: nil)
        }
    }
}
