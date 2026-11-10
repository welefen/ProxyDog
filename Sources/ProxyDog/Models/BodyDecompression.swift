import Foundation
import ZlibShim

/// Decodes compressed HTTP payloads so captured bodies are readable in the inspector.
///
/// Supports gzip and zlib/deflate (what macOS can inflate natively). Brotli/Zstandard are
/// not supported by the system frameworks; the proxy avoids them by requesting only
/// gzip/deflate from upstream servers when it intercepts a request.
enum BodyDecompression {
    /// Largest decoded body we are willing to produce (protects against zip bombs).
    static let maxDecodedBytes = 16 * 1024 * 1024

    /// Decompresses a payload according to a `Content-Encoding` header value.
    /// Returns nil when the encoding is missing, unsupported, or decoding fails.
    static func decode(_ data: Data, contentEncoding: String?) -> Data? {
        guard !data.isEmpty, let encoding = normalizedEncoding(contentEncoding) else { return nil }
        switch encoding {
        case "gzip", "x-gzip", "deflate", "zlib":
            return inflate(data)
        default:
            return nil
        }
    }

    /// True when we can decode this `Content-Encoding` ourselves.
    static func canDecode(contentEncoding: String?) -> Bool {
        guard let encoding = normalizedEncoding(contentEncoding) else { return false }
        return ["gzip", "x-gzip", "deflate", "zlib"].contains(encoding)
    }

    /// True when the payload is compressed with an encoding we cannot decode, which means
    /// the raw bytes would render as garbage in the body viewer.
    static func isUndecodable(contentEncoding: String?) -> Bool {
        guard let encoding = normalizedEncoding(contentEncoding) else { return false }
        return encoding != "identity" && !canDecode(contentEncoding: contentEncoding)
    }

    /// Upstream `Accept-Encoding` value that keeps responses decodable for the inspector,
    /// restricted to what the client itself is willing to accept.
    static func upstreamAcceptEncoding(clientValue: String?) -> String {
        let allowed = Set(
            (clientValue ?? "")
                .lowercased()
                .split(separator: ",")
                .map { $0.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "" }
                .filter { !$0.isEmpty }
        )
        if allowed.contains("gzip") { return "gzip" }
        if allowed.contains("deflate") { return "deflate" }
        // The client did not advertise anything we can decode; ask for identity.
        return "identity"
    }

    private static func normalizedEncoding(_ value: String?) -> String? {
        guard var encoding = value?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !encoding.isEmpty else { return nil }
        if let comma = encoding.firstIndex(of: ",") {
            encoding = String(encoding[encoding.startIndex..<comma])
        }
        return encoding.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inflate(_ data: Data) -> Data? {
        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        let status = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int32 in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return proxydog_inflate(
                base,
                buffer.count,
                &output,
                &outputLength,
                maxDecodedBytes
            )
        }
        guard status == 0, let output else { return nil }
        defer { proxydog_free(output) }
        return Data(bytes: output, count: outputLength)
    }
}
