import Foundation

/// Exports captured traffic as HAR 1.2 (the format Proxyman, Chrome DevTools and
/// Charles use for interchange).
enum HARExporter {
    static func makeHAR(requests: [CapturedRequest]) throws -> Data {
        var entries: [[String: Any]] = []
        for request in requests {
            var entry: [String: Any] = [
                "startedDateTime": ISO8601DateFormatter().string(from: request.startedAt),
                "time": (request.duration ?? 0) * 1000,
                "request": [
                    "method": request.method,
                    "url": request.urlString,
                    "httpVersion": "HTTP/1.1",
                    "headers": request.requestHeaders.map { ["name": $0.name, "value": $0.value] },
                    "queryString": [],
                    "cookies": [],
                    "headersSize": -1,
                    "bodySize": request.requestBytes,
                ],
                "response": [
                    "status": request.statusCode ?? 0,
                    "statusText": "",
                    "httpVersion": "HTTP/1.1",
                    "headers": request.responseHeaders.map { ["name": $0.name, "value": $0.value] },
                    "cookies": [],
                    "content": [
                        "size": request.responseBytes,
                        "mimeType": request.responseContentType ?? "",
                    ],
                    "redirectURL": "",
                    "headersSize": -1,
                    "bodySize": request.responseBytes,
                ],
                "cache": [:],
                "timings": ["send": 0, "wait": (request.duration ?? 0) * 1000, "receive": 0],
            ]
            if let body = request.responseBody, let text = String(data: body, encoding: .utf8) {
                var content = (entry["response"] as? [String: Any])?["content"] as? [String: Any] ?? [:]
                content["text"] = text
                var response = entry["response"] as? [String: Any] ?? [:]
                response["content"] = content
                entry["response"] = response
            }
            entries.append(entry)
        }
        let har: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": ["name": AppInfo.name, "version": AppInfo.version],
                "entries": entries,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys])
    }
}

enum CurlExporter {
    static func curlCommand(for request: CapturedRequest) -> String {
        var parts = ["curl -X \(request.method)"]
        parts.append("'\(request.urlString)'")
        for header in request.requestHeaders where !header.isSensitive {
            parts.append("-H '\(header.name): \(header.value)'")
        }
        if let body = request.requestBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            parts.append("--data-raw '\(text.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        return parts.joined(separator: " \\\n  ")
    }
}
