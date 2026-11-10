import Foundation
import NIOCore
import NIOPosix

/// A channel handler that performs an upstream-proxy tunnel handshake and exposes the
/// resulting leftover bytes (bytes the target sent directly after the proxy's success reply).
protocol UpstreamTunnelHandshakeHandler: ChannelHandler {
    var future: EventLoopFuture<ByteBuffer> { get }
}

/// Establishes outbound TCP connections, either directly or through a configured
/// upstream proxy (HTTP CONNECT or SOCKS5).
enum ProxyOutboundConnector {
    /// Connects to `host:port` directly, or connects to `proxy` and opens a CONNECT tunnel.
    ///
    /// - Returns: the established channel and any bytes the target sent right after the
    ///   proxy's success reply. Those bytes must be re-injected into the pipeline that is
    ///   installed on top of the tunnel.
    static func connect(
        eventLoop: EventLoop,
        host: String,
        port: Int,
        proxy: UpstreamProxy?
    ) -> EventLoopFuture<(Channel, ByteBuffer)> {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(20))

        guard let proxy else {
            return bootstrap.connect(host: host, port: port).map { channel in
                (channel, ByteBufferAllocator().buffer(capacity: 0))
            }
        }

        return bootstrap.connect(host: proxy.host, port: proxy.port)
            .flatMap { (proxyChannel: Channel) -> EventLoopFuture<(Channel, ByteBuffer)> in
                switch proxy.kind {
                case .httpConnect:
                    let handshake = UpstreamConnectHandshakeHandler(
                        proxy: proxy,
                        targetHost: host,
                        targetPort: port,
                        eventLoop: proxyChannel.eventLoop
                    )
                    return awaitHandshake(on: proxyChannel, handler: handshake)
                case .socks5:
                    let handshake = UpstreamSOCKS5HandshakeHandler(
                        proxy: proxy,
                        targetHost: host,
                        targetPort: port,
                        eventLoop: proxyChannel.eventLoop
                    )
                    return awaitHandshake(on: proxyChannel, handler: handshake)
                }
            }
    }

    /// Human readable proxy name for error messages, e.g. "SOCKS5 proxy 127.0.0.1:1234".
    static func description(for proxy: UpstreamProxy) -> String {
        "\(proxy.kind.label) proxy \(proxy.host):\(proxy.port)"
    }

    /// Error prefix for failures that happened before the tunnel existed.
    static func connectionFailureMessage(_ error: Error, proxy: UpstreamProxy) -> String {
        if let proxyError = error as? ProxyError {
            switch proxyError {
            case .upstreamProxyFailed(let message):
                return message
            default:
                return proxyError.localizedDescription
            }
        }
        return "Upstream \(description(for: proxy)) could not be reached: \(ProxyWire.readableError(error))"
    }

    private static func awaitHandshake<H>(
        on channel: Channel,
        handler: H
    ) -> EventLoopFuture<(Channel, ByteBuffer)>
    where H: ChannelHandler & Sendable, H: UpstreamTunnelHandshakeHandler {
        channel.pipeline.addHandler(handler).flatMap {
            handler.future.map { leftover in (channel, leftover) }
        }
    }
}
