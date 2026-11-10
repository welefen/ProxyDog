import Foundation

/// Exports captured traffic as HAR 1.2 (the format Proxyman, Chrome DevTools and
/// Charles use for interchange).
///
/// The exporter is deliberately defensive: anything the model does not know (DNS,
/// connect and TLS timings, header sizes, HTTP version) is reported as unknown
/// (`-1`) or as a neutral default instead of being invented. Custom HAR fields are
/// prefixed with `_` as allowed by the spec.
enum HARExporter {
    static func makeHAR(requests: [CapturedRequest]) throws -> Data {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let entries = requests.map { entry(for: $0, dateFormatter: dateFormatter) }
        let har: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": [
                    "name": AppInfo.name,
                    "version": AppInfo.version,
                ],
                "pages": [],
                "entries": entries,
            ],
        ]
        return try JSONSerialization.data(
            withJSONObject: har,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Entry

    private static func entry(for request: CapturedRequest, dateFormatter: ISO8601DateFormatter) -> [String: Any] {
        let elapsed = request.duration ?? 0
        let elapsedMilliseconds = elapsed.isFinite ? max(0, elapsed * 1000) : 0

        var entry: [String: Any] = [
            "startedDateTime": dateFormatter.string(from: request.startedAt),
            "time": elapsedMilliseconds,
            "request": requestObject(for: request),
            "response": responseObject(for: request),
            "cache": [String: Any](),
            "timings": [
                "blocked": -1,
                "dns": -1,
                "connect": -1,
                "send": 0,
                "wait": elapsedMilliseconds,
                "receive": 0,
                "ssl": -1,
            ],
            "_resourceType": request.contentKind.rawValue,
            "_intercepted": request.intercepted,
            "_state": request.state.rawValue,
        ]
        if let errorMessage = request.errorMessage {
            entry["_error"] = errorMessage
        }
        return entry
    }

    // MARK: - Request

    private static func requestObject(for request: CapturedRequest) -> [String: Any] {
        var object: [String: Any] = [
            "method": request.method,
            "url": request.urlString,
            "httpVersion": "HTTP/1.1",
            "cookies": requestCookies(from: request.requestHeaders),
            "headers": headerObjects(request.requestHeaders, body: request.requestBody),
            "queryString": queryItems(from: request.urlString),
            "headersSize": -1,
            "bodySize": request.requestBytes,
        ]
        if let body = request.requestBody, !body.isEmpty {
            object["postData"] = postData(for: body, contentType: request.requestContentType)
        }
        return object
    }

    private static func postData(for body: Data, contentType: String?) -> [String: Any] {
        let mimeType = contentType ?? "application/octet-stream"
        var object: [String: Any] = ["mimeType": mimeType]

        if isFormURLEncoded(mimeType), let text = String(data: body, encoding: .utf8) {
            object["text"] = text
            object["params"] = formParameters(from: text)
        } else if let text = textualBody(body) {
            object["text"] = text
        } else {
            object["text"] = body.base64EncodedString()
            object["encoding"] = "base64"
            object["comment"] = "Binary request body encoded as base64."
        }
        return object
    }

    // MARK: - Response

    private static func responseObject(for request: CapturedRequest) -> [String: Any] {
        let status = request.statusCode ?? 0
        let body = request.responseBody ?? Data()
        var content: [String: Any] = [
            "size": body.count,
            "mimeType": request.responseContentType ?? "",
        ]
        if !body.isEmpty {
            if let text = textualBody(body) {
                content["text"] = text
            } else {
                content["text"] = body.base64EncodedString()
                content["encoding"] = "base64"
            }
        }

        return [
            "status": status,
            "statusText": status == 0 ? "" : reasonPhrase(for: status),
            "httpVersion": "HTTP/1.1",
            "cookies": responseCookies(from: request.responseHeaders),
            "headers": headerObjects(request.responseHeaders, body: request.responseBody),
            "content": content,
            "redirectURL": request.responseHeaders.firstValue(forName: "Location") ?? "",
            "headersSize": -1,
            "bodySize": body.count,
        ]
    }

    // MARK: - Shared helpers

    /// HAR consumers expect `content.text`/`postData.text` to be the decoded payload, so a
    /// `Content-Encoding` header would make them double-decompress. Drop it whenever the
    /// proxy itself already inflated the captured body.
    private static func headerObjects(_ headers: [HeaderField], body: Data?) -> [[String: String]] {
        headers
            .filter { header in
                guard body != nil, !(body?.isEmpty ?? true),
                      header.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame
                else { return true }
                return !BodyDecompression.canDecode(contentEncoding: header.value)
            }
            .map { ["name": $0.name, "value": $0.value] }
    }

    private static func requestCookies(from headers: [HeaderField]) -> [[String: String]] {
        headers
            .filter { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame }
            .flatMap { cookiePairs(in: $0.value) }
    }

    private static func cookiePairs(in headerValue: String) -> [[String: String]] {
        headerValue
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { pair -> [String: String]? in
                let text = pair.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                let parts = splitOnce(text, on: "=")
                let name = parts.left.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return ["name": name, "value": parts.right.trimmingCharacters(in: .whitespaces)]
            }
    }

    private static func responseCookies(from headers: [HeaderField]) -> [[String: Any]] {
        headers
            .filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }
            .compactMap { parseSetCookie($0.value) }
    }

    private static func parseSetCookie(_ headerValue: String) -> [String: Any]? {
        let segments = headerValue.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = segments.first else { return nil }
        let pair = splitOnce(first.trimmingCharacters(in: .whitespaces), on: "=")
        let name = pair.left.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        var cookie: [String: Any] = [
            "name": name,
            "value": pair.right.trimmingCharacters(in: .whitespaces),
        ]

        for segment in segments.dropFirst() {
            let attribute = segment.trimmingCharacters(in: .whitespaces)
            guard !attribute.isEmpty else { continue }
            if attribute.caseInsensitiveCompare("HttpOnly") == .orderedSame {
                cookie["httpOnly"] = true
                continue
            }
            if attribute.caseInsensitiveCompare("Secure") == .orderedSame {
                cookie["secure"] = true
                continue
            }
            let parts = splitOnce(attribute, on: "=")
            let key = parts.left.lowercased()
            let value = parts.right
            switch key {
            case "path":
                cookie["path"] = value
            case "domain":
                cookie["domain"] = value
            case "expires":
                if let date = parseHTTPDate(value) {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    cookie["expires"] = formatter.string(from: date)
                }
            default:
                break
            }
        }
        return cookie
    }

    private static func queryItems(from urlString: String) -> [[String: String]] {
        guard let query = rawQuery(from: urlString) else { return [] }
        return query
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { pair -> [String: String] in
                let parts = splitOnce(String(pair), on: "=")
                return ["name": decodeQuery(parts.left), "value": decodeQuery(parts.right)]
            }
    }

    private static func rawQuery(from urlString: String) -> String? {
        if let components = URLComponents(string: urlString), let query = components.percentEncodedQuery {
            return query
        }
        guard let questionMark = urlString.firstIndex(of: "?") else { return nil }
        var query = String(urlString[urlString.index(after: questionMark)...])
        if let hash = query.firstIndex(of: "#") {
            query = String(query[..<hash])
        }
        return query.isEmpty ? nil : query
    }

    private static func formParameters(from text: String) -> [[String: String]] {
        text
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { pair -> [String: String] in
                let parts = splitOnce(String(pair), on: "=")
                return ["name": decodeQuery(parts.left), "value": decodeQuery(parts.right)]
            }
    }

    // MARK: - Value helpers

    /// Splits `text` on the first occurrence of `separator`, returning the two halves.
    private static func splitOnce(_ text: String, on separator: Character) -> (left: String, right: String) {
        guard let index = text.firstIndex(of: separator) else { return (text, "") }
        let left = String(text[..<index])
        let right = String(text[text.index(after: index)...])
        return (left, right)
    }

    private static func decodeQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }

    private static func isFormURLEncoded(_ mimeType: String) -> Bool {
        mimeType.lowercased().contains("application/x-www-form-urlencoded")
    }

    /// Returns the body as text when it decodes as UTF-8 and looks like text rather
    /// than a binary format. Binary payloads are base64 encoded by the caller.
    private static func textualBody(_ body: Data) -> String? {
        guard !body.isEmpty, body.count <= 8 * 1024 * 1024 else { return nil }
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        guard !text.isEmpty else { return "" }
        for scalar in text.unicodeScalars {
            if scalar.value == 0 { return nil }
            if scalar.value < 0x20,
               scalar != "\n", scalar != "\r", scalar != "\t" {
                return nil
            }
        }
        return text
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
        }
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

/// Renders a captured exchange as a paste-ready curl command.
enum CurlExporter {
    /// - Parameter includeSensitiveHeaders: when `false` (the default) credentials
    ///   and cookies are omitted so the command can be shared safely.
    static func curlCommand(for request: CapturedRequest, includeSensitiveHeaders: Bool = false) -> String {
        var lines: [String] = []
        let body = request.requestBody
        let textualBody = body.flatMap { String(data: $0, encoding: .utf8) }

        if let body, !body.isEmpty, textualBody == nil {
            lines.append("# Request body is binary (\(body.count) bytes) and was omitted.")
        }

        let indent = "  "
        var command = "curl -X \(request.method) \(singleQuoted(request.urlString))"
        for header in request.requestHeaders where includeSensitiveHeaders || !header.isSensitive {
            command += " \\\n\(indent)-H \(singleQuoted("\(header.name): \(header.value)"))"
        }
        if let textualBody, !textualBody.isEmpty {
            command += " \\\n\(indent)--data-raw \(singleQuoted(textualBody))"
        }
        lines.append(command)
        return lines.joined(separator: "\n")
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
