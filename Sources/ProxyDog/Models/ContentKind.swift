import Foundation

/// Broad category of a payload, used for the icon and tint shown in the traffic list.
enum ContentKind: String, Sendable, CaseIterable {
    case json
    case javascript
    case html
    case xml
    case css
    case text
    case image
    case font
    case audio
    case video
    case form
    case binary

    static func infer(mimeType: String?, pathOrURL: String? = nil) -> ContentKind {
        if let mime = mimeType?.lowercased() {
            if mime.contains("json") { return .json }
            if mime.contains("javascript") || mime.contains("ecmascript") { return .javascript }
            if mime.contains("html") { return .html }
            if mime.contains("xml") { return .xml }
            if mime.contains("css") { return .css }
            if mime.hasPrefix("image/") { return .image }
            if mime.hasPrefix("font/") || mime.contains("woff") || mime.contains("ttf") { return .font }
            if mime.hasPrefix("audio/") { return .audio }
            if mime.hasPrefix("video/") { return .video }
            if mime.contains("x-www-form-urlencoded") { return .form }
            if mime.hasPrefix("text/") || mime.contains("graphql") { return .text }
        }
        // Fall back to the file extension of the path.
        if let path = pathOrURL {
            let trimmed = path.split(separator: "?").first.map(String.init) ?? path
            let ext = (trimmed as NSString).pathExtension.lowercased()
            switch ext {
            case "json": return .json
            case "js", "mjs": return .javascript
            case "html", "htm": return .html
            case "xml", "plist": return .xml
            case "css": return .css
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "ico": return .image
            case "woff", "woff2", "ttf", "otf": return .font
            case "mp3", "wav", "m4a", "aac": return .audio
            case "mp4", "mov", "webm": return .video
            case "": return .text
            default: return .binary
            }
        }
        return .binary
    }

    var label: String {
        switch self {
        case .json: return "JSON"
        case .javascript: return "JavaScript"
        case .html: return "HTML"
        case .xml: return "XML"
        case .css: return "CSS"
        case .text: return "Text"
        case .image: return "Image"
        case .font: return "Font"
        case .audio: return "Audio"
        case .video: return "Video"
        case .form: return "Form"
        case .binary: return "Binary"
        }
    }

    var symbolName: String {
        switch self {
        case .json: return "curlybraces"
        case .javascript: return "chevron.left.forwardslash.chevron.right"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .css: return "paintbrush"
        case .text: return "doc.text"
        case .image: return "photo"
        case .font: return "textformat"
        case .audio: return "waveform"
        case .video: return "play.rectangle"
        case .form: return "list.bullet.rectangle"
        case .binary: return "doc.zipper"
        }
    }

    var isTextual: Bool {
        switch self {
        case .json, .javascript, .html, .xml, .css, .text, .form: return true
        case .image, .font, .audio, .video, .binary: return false
        }
    }
}
