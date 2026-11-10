import Foundation

/// Toggles the macOS system HTTP/HTTPS proxy to point at ProxyDog.
///
/// Owned by the proxy core (`Sources/ProxyDog/Core/`). Requires admin rights, which
/// are requested through the standard macOS authorization prompt.
enum SystemProxy {
    /// Name of the active network service, e.g. "Wi-Fi".
    static func activeNetworkService() -> String? { nil }

    /// Whether the system proxy is currently pointed at `port` on localhost.
    static func isEnabled(port: Int) -> Bool { false }

    /// Enables the HTTP and HTTPS system proxy for every active network service.
    static func enable(port: Int) throws {}

    /// Disables the HTTP and HTTPS system proxy for every active network service.
    static func disable() throws {}
}
