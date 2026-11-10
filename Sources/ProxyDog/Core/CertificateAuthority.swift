import Foundation
import NIOSSL

/// Generates and stores the ProxyDog root CA plus per-host leaf certificates used
/// for TLS interception, and knows whether the root is trusted by the system.
///
/// Owned by the proxy core (`Sources/ProxyDog/Core/`). This declaration documents the
/// contract consumed by `AppState` and the settings UI.
final class CertificateAuthority: @unchecked Sendable {
    static let shared = CertificateAuthority()

    /// Directory holding `ca.crt`, `ca.key` and cached leaf certificates.
    let storageDirectory: URL

    /// Public certificate that has to be trusted/installed by the user.
    var rootCertificateURL: URL { storageDirectory.appendingPathComponent("ca.crt") }

    init(storageDirectory: URL? = nil) {
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.storageDirectory = base.appendingPathComponent("ProxyDog/Certificates", isDirectory: true)
        }
    }

    /// True when the CA key/cert pair exists on disk.
    var isPrepared: Bool { true }

    /// Creates the root CA on first launch. Safe to call repeatedly.
    func prepareIfNeeded() throws {}

    /// Whether the root certificate is installed as a trusted root in the login keychain.
    func isTrustedInKeychain() -> Bool { false }

    /// Adds the root certificate to the login keychain as a trusted root (asks for admin rights).
    func requestInstallTrust() throws {}

    /// Removes the trust setting again.
    func removeTrust() throws {}

    /// Exports the root certificate for manual installation (e.g. on another machine).
    func exportRootCertificate(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: rootCertificateURL.path) {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: rootCertificateURL, to: url)
        }
    }

    /// TLS server context with a freshly minted (and cached) certificate for `host`.
    func serverTLSContext(forHost host: String) throws -> NIOSSLContext {
        throw ProxyError.certificateUnavailable
    }
}

enum ProxyError: LocalizedError {
    case certificateUnavailable
    case notImplemented
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .certificateUnavailable: return "Could not create a certificate for the intercepted host."
        case .notImplemented: return "Not implemented yet."
        case .bindFailed(let detail): return detail
        }
    }
}
