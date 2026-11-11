import Foundation

/// One `Cookie:` pair from a request.
struct RequestCookie: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let value: String
}

/// One `Set-Cookie:` entry from a response, with its attributes flattened for display.
struct ResponseCookie: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let value: String
    var domain: String?
    var path: String?
    var expires: String?
    var flags: String?
}

enum CookieParser {
    static func requestCookies(from headers: [HeaderField]) -> [RequestCookie] {
        var cookies: [RequestCookie] = []
        for header in headers where header.name.lowercased() == "cookie" {
            for pair in header.value.split(separator: ";") {
                let pieces = pair.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard let name = pieces.first, !name.isEmpty else { continue }
                cookies.append(RequestCookie(name: name, value: pieces.count == 2 ? pieces[1] : ""))
            }
        }
        return cookies
    }

    static func responseCookies(from headers: [HeaderField]) -> [ResponseCookie] {
        headers
            .filter { $0.name.lowercased() == "set-cookie" }
            .compactMap { cookie(from: $0.value) }
    }

    private static func cookie(from value: String) -> ResponseCookie? {
        var pieces = value.components(separatedBy: ";")
        guard let head = pieces.first else { return nil }
        let pair = head.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let name = pair.first, !name.isEmpty else { return nil }
        var cookie = ResponseCookie(name: name, value: pair.count == 2 ? pair[1] : "")
        pieces.removeFirst()

        var flagParts: [String] = []
        for piece in pieces {
            let attribute = piece.trimmingCharacters(in: .whitespaces)
            guard !attribute.isEmpty else { continue }
            let parts = attribute.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let key = parts[0].lowercased()
            let attributeValue = parts.count == 2 ? parts[1] : ""
            switch key {
            case "domain": cookie.domain = attributeValue
            case "path": cookie.path = attributeValue
            case "expires": cookie.expires = attributeValue
            case "max-age": cookie.expires = cookie.expires ?? "Max-Age=\(attributeValue)"
            case "secure", "httponly":
                flagParts.append(parts[0])
            case "samesite":
                flagParts.append("SameSite=\(attributeValue)")
            default:
                break
            }
        }
        if !flagParts.isEmpty { cookie.flags = flagParts.joined(separator: " · ") }
        return cookie
    }
}
