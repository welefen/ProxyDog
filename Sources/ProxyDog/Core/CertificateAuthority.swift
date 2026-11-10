import Darwin
import Foundation
import NIOSSL

/// Generates and stores the ProxyDog root CA plus per-host leaf certificates used
/// for TLS interception, and knows whether the root is trusted by the system.
///
/// Owned by the proxy core (`Sources/ProxyDog/Core/`). This declaration documents the
/// contract consumed by `AppState` and the settings UI.
final class CertificateAuthority: @unchecked Sendable {
    static let shared = CertificateAuthority()

    /// Common name of the generated root certificate.
    static let rootCommonName = "ProxyDog Root CA"

    /// Directory holding `ca.crt`, `ca.key` and cached leaf certificates.
    let storageDirectory: URL

    /// Public certificate that has to be trusted/installed by the user.
    var rootCertificateURL: URL { storageDirectory.appendingPathComponent("ca.crt") }

    /// Private key of the root certificate. Never leaves the machine.
    var rootKeyURL: URL { storageDirectory.appendingPathComponent("ca.key") }

    private var hostsDirectory: URL { storageDirectory.appendingPathComponent("Hosts", isDirectory: true) }

    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "com.proxydog.certificate-authority", qos: .userInitiated)
    private var contextCache: [String: NIOSSLContext] = [:]
    private var prepared = false

    init(storageDirectory: URL? = nil) {
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else if let override = ProcessInfo.processInfo.environment["PROXYDOG_CERT_DIR"], !override.isEmpty {
            // Test/CI hook: lets sandboxed harnesses point the CA at a writable directory.
            self.storageDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let preferred = base.appendingPathComponent("ProxyDog/Certificates", isDirectory: true)
            // Sandboxed test runs cannot write to ~/Library/Application Support; fall back to a
            // writable temporary directory instead of making TLS interception impossible.
            if Self.directoryIsWritable(preferred) {
                self.storageDirectory = preferred
            } else {
                self.storageDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ProxyDog/Certificates", isDirectory: true)
            }
        }
    }

    /// Creates `url` if needed and verifies a probe file can be written there.
    private static func directoryIsWritable(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let probe = url.appendingPathComponent(".probe")
        do {
            try Data("ok".utf8).write(to: probe)
            try? fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// True when the CA key/cert pair exists on disk.
    var isPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        if prepared { return true }
        return FileManager.default.fileExists(atPath: rootCertificateURL.path)
            && FileManager.default.fileExists(atPath: rootKeyURL.path)
    }

    /// Creates the root CA on first launch. Safe to call repeatedly.
    func prepareIfNeeded() throws {
        lock.lock()
        let alreadyPrepared = prepared
        lock.unlock()
        if alreadyPrepared { return }

        try workQueue.sync {
            try prepareLocked()
        }
    }

    // MARK: - Keychain trust

    /// Whether the root certificate is installed as a trusted root in the system keychain.
    func isTrustedInKeychain() -> Bool {
        guard let probe = probeLeafCertificatePath() else { return false }

        // Cheap first pass: is our CA installed in a keychain at all?
        var installed = false
        let keychains = [
            "/Library/Keychains/System.keychain",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Keychains/login.keychain-db"),
        ]
        for keychain in keychains {
            guard let result = try? ProcessRunner.run(
                "/usr/bin/security",
                ["find-certificate", "-c", Self.rootCommonName, "-a", keychain]
            ) else { continue }
            if result.succeeded, result.combinedOutput.contains(Self.rootCommonName) {
                installed = true
                break
            }
        }
        guard installed else { return false }

        // Verify a leaf signed by our CA using the keychain trust settings.
        guard let verify = try? ProcessRunner.run(
            "/usr/bin/security",
            ["verify-cert", "-c", probe.path, "-p", "ssl"]
        ) else { return false }
        return verify.succeeded
    }

    /// Adds the root certificate to the system keychain as a trusted root (asks for admin rights).
    func requestInstallTrust() throws {
        try prepareIfNeeded()
        let cert = ProcessRunner.shellQuote(rootCertificateURL.path)
        let command = [
            "set -e",
            "/usr/bin/security remove-trusted-cert -d \(cert) 2>/dev/null || true",
            "/usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \(cert)",
        ].joined(separator: "; ")
        try ProcessRunner.runAdminShell(command)
    }

    /// Removes the trust setting again.
    func removeTrust() throws {
        try prepareIfNeeded()
        let cert = ProcessRunner.shellQuote(rootCertificateURL.path)
        let name = ProcessRunner.shellQuote(Self.rootCommonName)
        let command = [
            "/usr/bin/security remove-trusted-cert -d \(cert) 2>/dev/null || true",
            "/usr/bin/security delete-certificate -c \(name) /Library/Keychains/System.keychain 2>/dev/null || true",
            "true",
        ].joined(separator: "; ")
        try ProcessRunner.runAdminShell(command)
    }

    /// Exports the root certificate for manual installation (e.g. on another machine).
    func exportRootCertificate(to url: URL) throws {
        try prepareIfNeeded()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: rootCertificateURL, to: url)
    }

    // MARK: - TLS contexts

    /// TLS server context with a freshly minted (and cached) certificate for `host`.
    ///
    /// - Warning: this blocks while `openssl` runs on first use of a host. Prefer
    ///   `tlsContext(forHost:completion:)` from event-loop code.
    func serverTLSContext(forHost host: String) throws -> NIOSSLContext {
        lock.lock()
        let cached = contextCache[host]
        lock.unlock()
        if let cached { return cached }

        let context = try workQueue.sync { try makeContextLocked(host: host) }
        lock.lock()
        contextCache[host] = context
        lock.unlock()
        return context
    }

    /// Asynchronous variant that never blocks the caller's thread (leaf generation runs
    /// on the CA's serial queue and shells out to `openssl`).
    func tlsContext(forHost host: String, completion: @escaping @Sendable (Result<NIOSSLContext, Error>) -> Void) {
        lock.lock()
        let cached = contextCache[host]
        lock.unlock()
        if let cached {
            completion(.success(cached))
            return
        }

        workQueue.async {
            let result: Result<NIOSSLContext, Error>
            do {
                let context = try self.makeContextLocked(host: host)
                self.lock.lock()
                self.contextCache[host] = context
                self.lock.unlock()
                result = .success(context)
            } catch {
                result = .failure(error)
            }
            completion(result)
        }
    }

    // MARK: - Private implementation

    private func prepareLocked() throws {
        if prepared { return }
        if FileManager.default.fileExists(atPath: rootCertificateURL.path),
           FileManager.default.fileExists(atPath: rootKeyURL.path) {
            try FileManager.default.createDirectory(at: hostsDirectory, withIntermediateDirectories: true)
            prepared = true
            return
        }

        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hostsDirectory, withIntermediateDirectories: true)
            try generateRootCertificateLocked()
            prepared = true
        } catch let error as ProxyError {
            throw error
        } catch {
            throw ProxyError.certificateCreationFailed("Could not create the ProxyDog root certificate: \(error.localizedDescription)")
        }
    }

    private func generateRootCertificateLocked() throws {
        // A dedicated OpenSSL config so the result is deterministic across OpenSSL builds.
        let configURL = storageDirectory.appendingPathComponent("ca.cnf")
        let configuration = """
        [req]
        distinguished_name = dn
        x509_extensions = v3_ca
        prompt = no

        [dn]
        CN = \(Self.rootCommonName)
        O = ProxyDog

        [v3_ca]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash
        """
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                "/usr/bin/openssl",
                [
                    "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
                    "-keyout", rootKeyURL.path,
                    "-out", rootCertificateURL.path,
                    "-config", configURL.path,
                ],
                currentDirectory: storageDirectory
            )
        } catch {
            throw ProxyError.certificateCreationFailed("Could not launch openssl: \(error.localizedDescription)")
        }

        guard result.succeeded,
              FileManager.default.fileExists(atPath: rootCertificateURL.path),
              FileManager.default.fileExists(atPath: rootKeyURL.path)
        else {
            try? FileManager.default.removeItem(at: rootCertificateURL)
            try? FileManager.default.removeItem(at: rootKeyURL)
            throw ProxyError.certificateCreationFailed("openssl could not create the root certificate: \(result.combinedOutput)")
        }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rootKeyURL.path)
    }

    private func makeContextLocked(host: String) throws -> NIOSSLContext {
        try prepareLocked()

        let paths = leafPaths(for: host)
        if !FileManager.default.fileExists(atPath: paths.certificate.path)
            || !FileManager.default.fileExists(atPath: paths.key.path) {
            try generateLeafCertificateLocked(host: host, paths: paths)
        }

        let chainAndKey: (chain: [NIOSSLCertificate], key: NIOSSLPrivateKey)
        do {
            chainAndKey = try loadLeafLocked(paths: paths)
        } catch {
            // Cached leaf is unreadable (e.g. truncated write): regenerate once.
            try? FileManager.default.removeItem(at: paths.directory)
            try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
            try generateLeafCertificateLocked(host: host, paths: paths)
            chainAndKey = try loadLeafLocked(paths: paths)
        }
        let chain = chainAndKey.chain
        let key = chainAndKey.key

        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: chain.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        // We only ever speak HTTP/1.1 over the decrypted channel.
        configuration.applicationProtocols = ["http/1.1"]
        return try NIOSSLContext(configuration: configuration)
    }

    private func loadLeafLocked(paths: LeafPaths) throws -> (chain: [NIOSSLCertificate], key: NIOSSLPrivateKey) {
        let chain = try NIOSSLCertificate.fromPEMFile(paths.certificate.path)
        let key = try NIOSSLPrivateKey(file: paths.key.path, format: .pem)
        return (chain, key)
    }

    private struct LeafPaths {
        let directory: URL
        let certificate: URL
        let key: URL
        let csr: URL
        let extensions: URL
    }

    private func leafPaths(for host: String) -> LeafPaths {
        let directory = hostsDirectory.appendingPathComponent(Self.fileSystemName(for: host), isDirectory: true)
        return LeafPaths(
            directory: directory,
            certificate: directory.appendingPathComponent("leaf.crt"),
            key: directory.appendingPathComponent("leaf.key"),
            csr: directory.appendingPathComponent("leaf.csr"),
            extensions: directory.appendingPathComponent("leaf.ext.cnf")
        )
    }

    private func generateLeafCertificateLocked(host: String, paths: LeafPaths) throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)

        let subjectAlternativeName: String
        if Self.isIPAddress(host) {
            subjectAlternativeName = "IP:\(host)"
        } else {
            subjectAlternativeName = "DNS:\(host),DNS:*.\(host)"
        }
        let extensions = """
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(subjectAlternativeName)
        """
        try extensions.write(to: paths.extensions, atomically: true, encoding: .utf8)

        let request = try ProcessRunner.run(
            "/usr/bin/openssl",
            [
                "req", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-keyout", paths.key.path,
                "-out", paths.csr.path,
                "-subj", "/CN=\(host)",
            ],
            currentDirectory: paths.directory
        )
        guard request.succeeded else {
            throw ProxyError.certificateCreationFailed("openssl could not create a certificate request for \(host): \(request.combinedOutput)")
        }

        let signing = try ProcessRunner.run(
            "/usr/bin/openssl",
            [
                "x509", "-req",
                "-in", paths.csr.path,
                "-CA", rootCertificateURL.path,
                "-CAkey", rootKeyURL.path,
                "-CAcreateserial",
                "-days", "825",
                "-sha256",
                "-extfile", paths.extensions.path,
                "-out", paths.certificate.path,
            ],
            currentDirectory: storageDirectory
        )
        try? FileManager.default.removeItem(at: paths.csr)
        try? FileManager.default.removeItem(at: paths.extensions)

        guard signing.succeeded,
              FileManager.default.fileExists(atPath: paths.certificate.path),
              FileManager.default.fileExists(atPath: paths.key.path)
        else {
            throw ProxyError.certificateCreationFailed("openssl could not sign a certificate for \(host): \(signing.combinedOutput)")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.key.path)
    }

    /// Generates (once) a leaf certificate signed by our CA that is only used to check
    /// whether the CA is trusted: `security verify-cert` succeeds only when the CA is a
    /// trusted root in a keychain.
    private func probeLeafCertificatePath() -> URL? {
        let probeHost = "proxydog-probe.local"
        return try? workQueue.sync { () -> URL in
            try prepareLocked()
            let paths = leafPaths(for: probeHost)
            if !FileManager.default.fileExists(atPath: paths.certificate.path)
                || !FileManager.default.fileExists(atPath: paths.key.path) {
                try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
                try generateLeafCertificateLocked(host: probeHost, paths: paths)
            }
            return paths.certificate
        }
    }

    private static func fileSystemName(for host: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var sanitized = ""
        for scalar in host.unicodeScalars {
            if allowed.contains(scalar) {
                sanitized.unicodeScalars.append(scalar)
            } else {
                sanitized.append("_")
            }
        }
        if sanitized.count > 80 { sanitized = String(sanitized.prefix(80)) }
        // Short stable hash so differently-escaped host names cannot collide.
        var hash: UInt32 = 2166136261
        for byte in host.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return "\(sanitized)-\(String(hash, radix: 16))"
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4) == 1 || inet_pton(AF_INET6, pointer, &ipv6) == 1
        }
    }
}

enum ProxyError: LocalizedError {
    case certificateUnavailable
    case notImplemented
    case bindFailed(String)
    case certificateCreationFailed(String)
    case authorizationFailed(String)
    case systemProxyFailed(String)
    case tlsUnavailable

    var errorDescription: String? {
        switch self {
        case .certificateUnavailable:
            return "Could not create a certificate for the intercepted host."
        case .notImplemented:
            return "Not implemented yet."
        case .bindFailed(let detail):
            return detail
        case .certificateCreationFailed(let detail):
            return detail
        case .authorizationFailed(let detail):
            return detail
        case .systemProxyFailed(let detail):
            return detail
        case .tlsUnavailable:
            return "Could not create the outbound TLS configuration."
        }
    }
}
