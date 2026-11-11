import AppKit
import Foundation

struct AIAnomaly: Identifiable {
    enum Severity {
        case error
        case warning
        case info
    }

    let id = UUID()
    let severity: Severity
    let title: String
    let detail: String
    let examples: [String]
}

struct AIAnalysisReport {
    let total: Int
    let findings: [AIAnomaly]
    let fallbackSummary: String
}

enum AIAnalyzer {
    static func report(for requests: [CapturedRequest]) -> AIAnalysisReport {
        var findings: [AIAnomaly] = []

        let failures = requests.filter(\.isFailure)
        if !failures.isEmpty {
            var counts: [String: Int] = [:]
            for request in failures {
                let key = request.errorMessage == nil ? request.statusText : String(localized: "Connection failed")
                counts[key, default: 0] += 1
            }
            let detail = counts.sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key) × \($0.value)" }
                .joined(separator: ", ")
            findings.append(AIAnomaly(
                severity: .error,
                title: String(format: String(localized: "%d failed requests"), failures.count),
                detail: detail,
                examples: examples(from: failures)
            ))
        }

        let slow = requests.compactMap { request -> (CapturedRequest, TimeInterval)? in
            guard let duration = request.duration, duration >= 1 else { return nil }
            return (request, duration)
        }
        .sorted { $0.1 > $1.1 }
        if !slow.isEmpty {
            findings.append(AIAnomaly(
                severity: .warning,
                title: String(format: String(localized: "%d slow requests (>1 s)"), slow.count),
                detail: String(localized: "The slowest responses are listed below."),
                examples: slow.prefix(3).map {
                    String(format: "%.2f s  %@ %@", $0.1, $0.0.method, $0.0.urlString)
                }
            ))
        }

        let large = requests.filter { $0.responseBytes >= 512 * 1024 }
        if !large.isEmpty {
            findings.append(AIAnomaly(
                severity: .warning,
                title: String(format: String(localized: "%d large responses (>512 KB)"), large.count),
                detail: String(localized: "Large bodies slow down capture and inspection."),
                examples: large.prefix(3).map {
                    "\(PDFormat.bytes($0.responseBytes))  \($0.method) \($0.urlString)"
                }
            ))
        }

        let plain = requests.filter { !$0.isSecure }
        if !plain.isEmpty {
            findings.append(AIAnomaly(
                severity: .info,
                title: String(format: String(localized: "%d plaintext HTTP requests"), plain.count),
                detail: String(localized: "These requests are not encrypted; data is visible on the wire."),
                examples: examples(from: plain)
            ))
        }

        var repeated: [String: [CapturedRequest]] = [:]
        for request in requests {
            let path = request.displayPath.split(separator: "?").first.map(String.init) ?? request.displayPath
            repeated["\(request.method) \(request.host)\(path)", default: []].append(request)
        }
        let busy = repeated.filter { $0.value.count >= 20 }
            .sorted { $0.value.count > $1.value.count }
        if !busy.isEmpty {
            findings.append(AIAnomaly(
                severity: .info,
                title: String(format: String(localized: "%d frequently repeated endpoints"), busy.count),
                detail: String(localized: "Possible polling loops or duplicated client calls."),
                examples: busy.prefix(3).map { "× \($0.value.count)  \($0.key)" }
            ))
        }

        let header = String(
            format: String(localized: "Analyzed %d requests across %d hosts, %d failed."),
            requests.count,
            Set(requests.map(\.host)).count,
            failures.count
        )
        let detailLines = findings.map { "• \($0.title)：\($0.detail)" }
        let fallback = ([header] + detailLines).joined(separator: "\n")
        return AIAnalysisReport(total: requests.count, findings: findings, fallbackSummary: fallback)
    }

    private static func examples(from requests: [CapturedRequest]) -> [String] {
        requests.prefix(3).map { "\($0.method) \($0.urlString) → \($0.statusText)" }
    }

    struct Options {
        var requestLimit = 80
        var includeImages = false
        var includeFormValues = false
    }

    static func prompt(
        for report: AIAnalysisReport,
        requests: [CapturedRequest],
        chinese: Bool,
        focus: String,
        options: Options,
        attachedImageCount: Int
    ) -> String {
        var lines: [String] = []
        let limited = options.requestLimit > 0 ? Array(requests.prefix(options.requestLimit)) : requests
        for request in limited {
            let duration = request.duration.map { String(format: "%.0fms", $0 * 1000) } ?? "-"
            lines.append("\(request.method) \(request.urlString) -> \(request.statusText) \(duration) \(PDFormat.bytes(request.responseBytes))")
        }
        let findings = report.findings.map { "- \($0.title): \($0.detail)" }.joined(separator: "\n")
        if options.includeFormValues {
            let forms = formValues(from: limited)
            if !forms.isEmpty {
                lines.append("")
                lines.append("Form values (truncated):")
                lines.append(contentsOf: forms)
            }
        }
        if attachedImageCount > 0 {
            let note = chinese
                ? "已附带 \(attachedImageCount) 张抓包上传的图片，请检查其中是否包含截图、证件、人脸或其它隐私信息。"
                : "\(attachedImageCount) uploaded image(s) from the capture are attached; check them for screenshots, IDs, faces or other private information."
            lines.insert(note, at: 0)
        }
        let instruction = chinese
            ? "你是网络抓包分析助手。请用简体中文分析下面的抓包请求与本地统计，指出可能的异常（失败原因、性能问题、可优化点），给出 3-5 条简短要点，不要重复原始请求列表，不要编造未出现的数据。"
            : "You are a network trace assistant. Analyze the captured requests and local stats below. Point out likely anomalies (failure causes, performance issues, optimizations) in 3-5 short bullet points. Do not repeat the raw list or invent data."
        let focusLine = chinese ? "分析重点：\(focus)" : "Focus: \(focus)"
        return """
        \(instruction)

        \(focusLine)

        Local findings:
        \(findings)

        Requests:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Text values from multipart or urlencoded form bodies (truncated for privacy/cost).
    static func formValues(from requests: [CapturedRequest]) -> [String] {
        var results: [String] = []
        for request in requests where results.count < 40 {
            guard let body = request.requestBody, !body.isEmpty else { continue }
            let mime = request.requestContentType?.lowercased() ?? ""
            var pairs: [String] = []
            if mime.contains("multipart/form-data"),
               let multipart = MultipartFormData.parse(data: body, contentType: request.requestContentType) {
                for part in multipart.parts where part.filename == nil {
                    guard let value = String(data: part.data, encoding: .utf8) else { continue }
                    pairs.append("\(part.name)=\(String(value.prefix(120)))")
                }
            } else if mime.contains("x-www-form-urlencoded"),
                      let text = String(data: body, encoding: .utf8) {
                pairs = text.split(separator: "&").prefix(20).map { pair in
                    String(pair.prefix(160))
                }
            }
            guard !pairs.isEmpty else { continue }
            results.append("\(request.method) \(request.host)\(request.displayPath): " + pairs.joined(separator: ", "))
        }
        return results
    }

    /// Extracts uploaded images (multipart parts or raw image bodies), downscaling large ones.
    static func images(from requests: [CapturedRequest], maxCount: Int = 3) -> [AIInputImage] {
        var images: [AIInputImage] = []
        for request in requests where images.count < maxCount {
            guard let body = request.requestBody, !body.isEmpty else { continue }
            let mime = request.requestContentType?.lowercased() ?? ""
            if mime.contains("multipart/form-data"),
               let multipart = MultipartFormData.parse(data: body, contentType: request.requestContentType) {
                for part in multipart.parts where images.count < maxCount {
                    guard part.isImage else { continue }
                    if let image = preparedImage(part.data) { images.append(image) }
                }
            } else if mime.hasPrefix("image/"), let image = preparedImage(body) {
                images.append(image)
            }
        }
        return images
    }

    private static func preparedImage(_ data: Data) -> AIInputImage? {
        guard data.count >= 64, let image = NSImage(data: data) else { return nil }
        var size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let maxDimension: CGFloat = 1280
        let scale = min(1, maxDimension / max(size.width, size.height))
        size = NSSize(width: size.width * scale, height: size.height * scale)
        let target = NSImage(size: size)
        target.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            return nil
        }
        return AIInputImage(data: jpeg, mimeType: "image/jpeg")
    }
}
