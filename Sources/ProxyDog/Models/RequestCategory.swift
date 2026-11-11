import Foundation

/// Chrome-DevTools-style request type filter for the traffic list.
///
/// The proxy does not know what initiated a request (XHR/fetch/document), so the
/// category is inferred from the response content type, the path and whether the
/// exchange was a WebSocket upgrade - which is what the Chrome chips show as well.
enum RequestCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case fetchXHR
    case document
    case css
    case javascript
    case font
    case image
    case media
    case manifest
    case socket
    case wasm
    case other
    /// Requests whose payload contains an uploaded file (e.g. image uploads).
    case file
    /// Not a content type: shows failed exchanges only.
    case error

    var id: String { rawValue }

    /// Short chip label. These stay in English in every language: they mirror the Chrome
    /// DevTools filter bar and are technical terms (Doc/CSS/JS/Media/…), not UI prose.
    var label: String {
        switch self {
        case .all: return "All"
        case .fetchXHR: return "Fetch/XHR"
        case .document: return "Doc"
        case .css: return "CSS"
        case .javascript: return "JS"
        case .font: return "Font"
        case .image: return "Img"
        case .media: return "Media"
        case .manifest: return "Manifest"
        case .socket: return "Socket"
        case .wasm: return "Wasm"
        case .other: return "Other"
        case .file: return "File"
        case .error: return "Error"
        }
    }

    /// The `All` chip means "no type filter".
    var isFiltering: Bool { self != .all }

    /// True when the request body carries a file upload (multipart file part or a raw
    /// image/video/binary body).
    static func hasFileUpload(_ request: CapturedRequest) -> Bool {
        guard let body = request.requestBody, !body.isEmpty,
              let mime = request.requestContentType?.lowercased() else { return false }
        if mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/")
            || mime.contains("octet-stream") || mime.contains("application/pdf")
            || mime.contains("application/zip") {
            return true
        }
        if mime.contains("multipart/form-data"),
           let form = MultipartFormData.parse(data: body, contentType: request.requestContentType) {
            return form.parts.contains { $0.filename != nil || $0.isImage }
        }
        return false
    }

    /// Maps a captured exchange onto the closest Chrome-style category.
    static func categorize(_ request: CapturedRequest) -> RequestCategory {
        if request.isWebSocket || request.statusCode == 101 {
            return .socket
        }

        let mime = (request.responseContentType ?? request.requestContentType ?? "").lowercased()
        let path = request.displayPath.lowercased()
        let fileExtension = (path.split(separator: "?").first.map(String.init) ?? path)
            .split(separator: "/").last.map(String.init) ?? ""

        if mime.contains("wasm") || fileExtension.hasSuffix(".wasm") {
            return .wasm
        }
        if mime.contains("manifest") || fileExtension.hasSuffix(".webmanifest") || fileExtension == "appcache" {
            return .manifest
        }
        if mime.contains("css") || fileExtension.hasSuffix(".css") {
            return .css
        }
        if mime.contains("javascript") || mime.contains("ecmascript") || fileExtension.hasSuffix(".js") || fileExtension.hasSuffix(".mjs") {
            return .javascript
        }
        if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "avif", "heic"].contains(fileExtension) {
            return .image
        }
        if mime.hasPrefix("audio/") || mime.hasPrefix("video/") || ["mp4", "webm", "mov", "mp3", "m4a", "wav", "ogg"].contains(fileExtension) {
            return .media
        }
        if mime.hasPrefix("font/") || mime.contains("woff") || ["woff", "woff2", "ttf", "otf", "eot"].contains(fileExtension) {
            return .font
        }
        if mime.contains("html") || fileExtension.hasSuffix(".html") || fileExtension.hasSuffix(".htm") {
            return .document
        }
        if mime.contains("json") || mime.contains("xml") || mime.contains("x-www-form-urlencoded")
            || mime.hasPrefix("text/") || mime.contains("graphql") || mime.contains("protobuf") {
            return .fetchXHR
        }
        return .other
    }
}
