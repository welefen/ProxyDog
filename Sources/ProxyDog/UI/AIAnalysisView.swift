import SwiftUI

@MainActor
final class AIAnalysisModel: ObservableObject {
    @Published private(set) var report: AIAnalysisReport?
    @Published private(set) var summary: String?
    @Published private(set) var isAnalyzing = true
    @Published private(set) var usedOnDeviceModel = false

    func start(requests: [CapturedRequest]) {
        guard report == nil else { return }
        let report = AIAnalyzer.report(for: requests)
        self.report = report
        guard !requests.isEmpty else {
            summary = report.fallbackSummary
            isAnalyzing = false
            return
        }

        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let prompt = AIAnalyzer.prompt(for: report, requests: requests, chinese: chinese)
        Task {
            if #available(macOS 26.0, *) {
                if let text = await AIAnalyzer.onDeviceSummary(prompt: prompt) {
                    summary = text
                    usedOnDeviceModel = true
                    isAnalyzing = false
                    return
                }
            }
            summary = report.fallbackSummary
            isAnalyzing = false
        }
    }
}

struct AIAnalysisView: View {
    let requests: [CapturedRequest]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AIAnalysisModel()
    @State private var didCopy = false

    private var reportText: String {
        var lines: [String] = []
        if let summary = model.summary {
            lines.append(summary)
        }
        if let report = model.report {
            lines.append("")
            for finding in report.findings {
                lines.append("\(finding.title): \(finding.detail)")
                lines.append(contentsOf: finding.examples.map { "  \($0)" })
            }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.x5) {
                    if let report = model.report {
                        if report.findings.isEmpty {
                            Text(String(localized: "No obvious anomalies found"))
                                .font(DS.Typography.ui(12))
                                .foregroundStyle(DSColor.textSecondary)
                        }
                        ForEach(report.findings) { finding in
                            findingCard(finding)
                        }
                    }

                    VStack(alignment: .leading, spacing: DS.Space.x2) {
                        HStack(spacing: DS.Space.x2) {
                            Text(String(localized: "AI summary"))
                                .font(DS.Typography.ui(11.5, .semibold))
                                .foregroundStyle(DSColor.textSecondary)
                            if model.isAnalyzing {
                                ProgressView().controlSize(.small)
                            } else if !model.usedOnDeviceModel {
                                Text(String(localized: "On-device model unavailable; showing rule-based findings."))
                                    .font(DS.Typography.ui(10.5))
                                    .foregroundStyle(DSColor.textMuted)
                            }
                        }
                        if let summary = model.summary {
                            Text(summary)
                                .font(DS.Typography.ui(12))
                                .foregroundStyle(DSColor.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(DS.Space.x3)
                                .background(DSColor.raised)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                        .strokeBorder(DSColor.border, lineWidth: 1)
                                )
                        } else if model.isAnalyzing {
                            Text(String(localized: "Running on-device analysis…"))
                                .font(DS.Typography.ui(11.5))
                                .foregroundStyle(DSColor.textMuted)
                        }
                    }
                }
                .padding(DS.Space.x5)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 620)
        .background(DSColor.base)
        .task {
            model.start(requests: requests)
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.x3) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DSColor.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "AI analysis"))
                    .font(DS.Typography.ui(13, .semibold))
                Text(String(format: String(localized: "Analyzing %d requests"), requests.count))
                    .font(DS.Typography.ui(10.5))
                    .foregroundStyle(DSColor.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.x5)
        .padding(.vertical, DS.Space.x3)
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Copy report")) {
                PDPasteboard.copy(reportText)
                didCopy = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    didCopy = false
                }
            }
            .disabled(model.report == nil)
            .buttonStyle(.plain)
            .font(DS.Typography.ui(11.5, .medium))
            .foregroundStyle(DSColor.accent)
            Spacer()
            Button(String(localized: "Close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DS.Space.x5)
        .frame(height: 48)
    }

    private func findingCard(_ finding: AIAnomaly) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x1 + 2) {
                Image(systemName: icon(for: finding.severity))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(color(for: finding.severity))
                Text(finding.title)
                    .font(DS.Typography.ui(12, .semibold))
                    .foregroundStyle(DSColor.textPrimary)
            }
            Text(finding.detail)
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
            ForEach(finding.examples, id: \.self) { example in
                Text(example)
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.x3)
        .background(DSColor.raised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .strokeBorder(DSColor.border, lineWidth: 1)
        )
    }

    private func icon(for severity: AIAnomaly.Severity) -> String {
        switch severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for severity: AIAnomaly.Severity) -> Color {
        switch severity {
        case .error: return DSColor.red
        case .warning: return DSColor.amber
        case .info: return DSColor.accent
        }
    }
}
