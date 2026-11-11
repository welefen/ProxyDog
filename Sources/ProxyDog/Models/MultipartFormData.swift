import AppKit
import Foundation
import ImageIO

/// Parsed `multipart/form-data` body: each field/file as a named part.
struct MultipartFormData {
    struct Part: Identifiable {
        let id = UUID()
        let name: String
        let filename: String?
        let contentType: String?
        let data: Data

        /// True for image MIME types, common image filenames, or bytes ImageIO can decode
        /// (some clients send `application/octet-stream` for a JPEG upload).
        var isImage: Bool {
            if let contentType, contentType.lowercased().hasPrefix("image/") { return true }
            if let filename {
                let ext = (filename as NSString).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "avif"].contains(ext) {
                    return true
                }
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
            return CGImageSourceGetCount(source) > 0
        }
    }

    let parts: [Part]

    static func isMultipart(contentType: String?) -> Bool {
        contentType?.lowercased().contains("multipart/form-data") == true
    }

    /// Returns nil when the body is not multipart or the boundary is missing.
    static func parse(data: Data, contentType: String?) -> MultipartFormData? {
        guard let contentType,
              let boundary = boundary(from: contentType),
              !boundary.isEmpty else { return nil }

        let delimiter = Data("--\(boundary)".utf8)
        guard let first = data.range(of: delimiter) else { return nil }

        var parts: [Part] = []
        var index = first.upperBound
        let separator = Data("\r\n--\(boundary)".utf8)

        while index < data.endIndex, parts.count < 100 {
            // Closing delimiter: --boundary--
            if data[index...].starts(with: Data("--".utf8)) { break }
            if data[index...].starts(with: Data("\r\n".utf8)) {
                index = data.index(index, offsetBy: 2)
            }

            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8), in: index..<data.endIndex) else {
                break
            }
            let headerText = String(decoding: data[index..<headerEnd.lowerBound], as: UTF8.self)
            let bodyStart = headerEnd.upperBound

            let next = data.range(of: separator, in: bodyStart..<data.endIndex)
            let bodyEnd = next?.lowerBound ?? data.endIndex
            let body = Data(data[bodyStart..<bodyEnd])

            parts.append(part(headers: headerText, data: body, index: parts.count))
            guard let next else { break }
            index = next.upperBound
        }

        return parts.isEmpty ? nil : MultipartFormData(parts: parts)
    }

    private static func boundary(from contentType: String) -> String? {
        for component in contentType.split(separator: ";") {
            let piece = component.trimmingCharacters(in: .whitespaces)
            guard piece.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(piece.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func part(headers: String, data: Data, index: Int) -> Part {
        var name = "field \(index + 1)"
        var filename: String?
        var contentType: String?

        for line in headers.components(separatedBy: "\r\n") {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            if key == "content-type" {
                contentType = value
            } else if key == "content-disposition" {
                for parameter in value.split(separator: ";").dropFirst() {
                    let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else { continue }
                    let parameterName = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                    var parameterValue = pair[1].trimmingCharacters(in: .whitespaces)
                    if parameterValue.hasPrefix("\""), parameterValue.hasSuffix("\""), parameterValue.count >= 2 {
                        parameterValue = String(parameterValue.dropFirst().dropLast())
                    }
                    if parameterName == "name", !parameterValue.isEmpty {
                        name = parameterValue
                    } else if parameterName == "filename" {
                        filename = parameterValue
                    }
                }
            }
        }
        return Part(name: name, filename: filename, contentType: contentType, data: data)
    }
}
