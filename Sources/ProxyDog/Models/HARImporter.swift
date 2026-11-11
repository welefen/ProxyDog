import Foundation

enum HARImportError: LocalizedError {
    case invalidFormat
    case noEntries

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return String(localized: "The selected file is not a valid HAR file.")
        case .noEntries:
            return String(localized: "No requests were found in the HAR file.")
        }
    }
}

/// Parses HAR 1.2 files (exported by ProxyDog, Chrome DevTools, Charles, Proxyman, …)
/// into captured exchanges so they can be inspected like live traffic.
enum HARImporter {
    /// Imported entries are grouped as this client in the sidebar.
    static let clientName = "HAR"

    static func parse(data: Data) throws -> [CapturedRequest] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let log = root["log"] as? [String: Any],
            let entries = log["entries"] as? [[String: Any]]
        else {
            throw HARImportError.invalidFormat
        }

        var imported: [CapturedRequest] = []
        for entry in entries {
            guard
                let request = entry["request"] as? [String: Any],
                let method = request["method"] as? String,
                let rawURL = request["url"] as? String,
                let components = URLComponents(string: rawURL),
                let host = components.host, !host.isEmpty
            else { continue }

            let scheme = (components.scheme ?? "https").lowercased()
            let port = components.port ?? (scheme == "https" ? 443 : 80)
            var path = components.percentEncodedPath
            if path.isEmpty { path = "/" }
            if let query = components.percentEncodedQuery, !query.isEmpty {
                path += "?" + query
            }

            let requestHeaders = headers(from: request["headers"])
            let response = entry["response"] as? [String: Any] ?? [:]
            let responseHeaders = headers(from: response["headers"])
            let statusCode = response["status"] as? Int
            let content = response["content"] as? [String: Any] ?? [:]

            let startedAt = parseDate(entry["startedDateTime"] as? String) ?? Date()
            let elapsed = (entry["time"] as? Double) ?? 0

            var captured = CapturedRequest(
                startedAt: startedAt,
                method: method.uppercased(),
                httpVersion: (request["httpVersion"] as? String) ?? "HTTP/1.1",
                scheme: scheme,
                host: host,
                port: port,
                path: path,
                intercepted: false,
                requestHeaders: requestHeaders,
                requestBody: requestBody(from: request["postData"]),
                statusCode: statusCode,
                responseHeaders: responseHeaders,
                responseBody: contentBody(from: content),
                wireResponseBytes: (content["size"] as? Int) ?? 0,
                state: .completed,
                clientSignature: requestHeaders.firstValue(forName: "User-Agent"),
                clientAppName: clientName
            )
            captured.finishedAt = startedAt.addingTimeInterval(max(0, elapsed / 1000))
            captured.isWebSocket = statusCode == 101
            imported.append(captured)
        }

        guard !imported.isEmpty else { throw HARImportError.noEntries }
        return imported
    }

    // MARK: - Helpers

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func headers(from value: Any?) -> [HeaderField] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let name = item["name"] as? String, let value = item["value"] as? String else {
                return nil
            }
            return HeaderField(name: name, value: value)
        }
    }

    private static func requestBody(from postData: Any?) -> Data? {
        guard let postData = postData as? [String: Any] else { return nil }
        if let text = postData["text"] as? String {
            return text.data(using: .utf8)
        }
        if let params = postData["params"] as? [[String: Any]] {
            let pairs = params.compactMap { item -> String? in
                guard let name = item["name"] as? String else { return nil }
                return "\(name)=\((item["value"] as? String) ?? "")"
            }
            let body = pairs.joined(separator: "&")
            return body.isEmpty ? nil : body.data(using: .utf8)
        }
        return nil
    }

    private static func contentBody(from content: [String: Any]) -> Data? {
        guard let text = content["text"] as? String else { return nil }
        if (content["encoding"] as? String)?.lowercased() == "base64" {
            return Data(base64Encoded: text, options: .ignoreUnknownCharacters)
        }
        return text.data(using: .utf8)
    }
}
