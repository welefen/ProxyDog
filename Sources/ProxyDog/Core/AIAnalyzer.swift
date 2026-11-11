import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

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

    static func prompt(for report: AIAnalysisReport, requests: [CapturedRequest], chinese: Bool) -> String {
        var lines: [String] = []
        for request in requests.prefix(80) {
            let duration = request.duration.map { String(format: "%.0fms", $0 * 1000) } ?? "-"
            lines.append("\(request.method) \(request.urlString) -> \(request.statusText) \(duration) \(PDFormat.bytes(request.responseBytes))")
        }
        let findings = report.findings.map { "- \($0.title): \($0.detail)" }.joined(separator: "\n")
        let instruction = chinese
            ? "你是网络抓包分析助手。请用简体中文分析下面的抓包请求与本地统计，指出可能的异常（失败原因、性能问题、可优化点），给出 3-5 条简短要点，不要重复原始请求列表，不要编造未出现的数据。"
            : "You are a network trace assistant. Analyze the captured requests and local stats below. Point out likely anomalies (failure causes, performance issues, optimizations) in 3-5 short bullet points. Do not repeat the raw list or invent data."
        return """
        \(instruction)

        Local findings:
        \(findings)

        Requests:
        \(lines.joined(separator: "\n"))
        """
    }

    @available(macOS 26.0, *)
    static func onDeviceSummary(prompt: String) async -> String? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(
            instructions: "You summarize network capture analysis concisely."
        )
        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
