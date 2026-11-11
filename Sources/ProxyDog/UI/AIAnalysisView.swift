import SwiftUI

struct AIAnalysisView: View {
    let requests: [CapturedRequest]

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var config = AIConfigStore.shared

    @State private var report: AIAnalysisReport?
    @State private var summary: String?
    @State private var isAnalyzing = false
    @State private var errorText: String?
    @State private var didCopy = false
    @State private var showConfiguration = false

    private enum Phase {
        case idle
        case running
        case done
        case failed
    }

    @State private var phase: Phase = .idle

    private var providerOptions: [PDDropdownPicker.Option] {
        AIProvider.allCases.map { .init(value: $0.rawValue, label: $0.label) }
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { config.provider.rawValue },
            set: { config.provider = AIProvider(rawValue: $0) ?? .deepSeek }
        )
    }

    private var reportText: String {
        var lines: [String] = []
        if let summary { lines.append(summary) }
        if let report {
            if !lines.isEmpty { lines.append("") }
            lines.append(String(localized: "Rule checks"))
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
                    if showConfiguration || !config.configuration.isUsable {
                        configurationCard
                    } else {
                        compactConfiguration
                    }
                    results
                }
                .padding(DS.Space.x5)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 700)
        .background(DSColor.base)
        .onAppear {
            if report == nil {
                report = AIAnalyzer.report(for: requests)
            }
            if config.configuration.isUsable {
                analyze()
            } else {
                showConfiguration = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.x3) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DSColor.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "AI analysis"))
                    .font(DS.Typography.ui(13, .semibold))
                Text(String(format: String(localized: "Configure a provider, then analyze the %d requests in the current list."), requests.count))
                    .font(DS.Typography.ui(10.5))
                    .foregroundStyle(DSColor.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.x5)
        .padding(.vertical, DS.Space.x3)
    }

    // MARK: Configuration

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            field(label: String(localized: "Provider")) {
                PDDropdownPicker(options: providerOptions, selection: providerBinding, width: 240, mono: false)
            }

            field(label: String(localized: "Model")) {
                TextField(config.provider.defaultModel, text: $config.model)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typography.mono(11.5))
                    .frame(width: 320)
            }

            field(label: "API Key") {
                SecureField(String(localized: "Paste your API key"), text: $config.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typography.mono(11.5))
                    .frame(width: 360)
            }

            field(label: String(localized: "Base URL (optional)")) {
                TextField(config.provider.defaultBaseURL.isEmpty ? "https://…" : config.provider.defaultBaseURL, text: $config.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typography.mono(11.5))
                    .frame(width: 360)
            }

            HStack(spacing: DS.Space.x3) {
                Button {
                    analyze()
                } label: {
                    HStack(spacing: DS.Space.x1 + 2) {
                        if isAnalyzing {
                            ProgressView().controlSize(.small)
                        }
                        Text(isAnalyzing
                            ? String(localized: "Analyzing…")
                            : String(localized: "Start analysis"))
                    }
                    .frame(minWidth: 108)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isAnalyzing || !config.configuration.isUsable)

                if !config.apiKey.isEmpty {
                    Button(String(localized: "Clear key")) {
                        config.clearKey()
                        summary = nil
                        phase = .idle
                    }
                    .buttonStyle(.plain)
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(DSColor.textMuted)
                }

                Text(String(localized: "The API key is stored in your login keychain."))
                    .font(DS.Typography.ui(10.5))
                    .foregroundStyle(DSColor.textMuted)
                Spacer()
            }

            if let errorText {
                Text(errorText)
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(DSColor.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.raised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .strokeBorder(DSColor.border, lineWidth: 1)
        )
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: DS.Space.x3) {
            Text(label)
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 128, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: Results

    private var compactConfiguration: some View {
        HStack(spacing: DS.Space.x2) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DSColor.green)
            Text(config.provider.label)
                .font(DS.Typography.ui(11.5, .medium))
                .foregroundStyle(DSColor.textPrimary)
            Text(config.configuration.resolvedModel)
                .font(DS.Typography.mono(10.5))
                .foregroundStyle(DSColor.textMuted)
            Spacer(minLength: DS.Space.x2)
            Button(String(localized: "Re-analyze")) {
                analyze()
            }
            .buttonStyle(.plain)
            .font(DS.Typography.ui(11))
            .foregroundStyle(DSColor.accent)
            .disabled(isAnalyzing)
            Button(String(localized: "Modify configuration")) {
                showConfiguration = true
            }
            .buttonStyle(.plain)
            .font(DS.Typography.ui(11))
            .foregroundStyle(DSColor.textSecondary)
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.raised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .strokeBorder(DSColor.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var results: some View {
        if let summary {
            VStack(alignment: .leading, spacing: DS.Space.x2) {
                Text(String(localized: "AI summary"))
                    .font(DS.Typography.ui(11.5, .semibold))
                    .foregroundStyle(DSColor.textSecondary)
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
            }
        }

        if let report {
            VStack(alignment: .leading, spacing: DS.Space.x2) {
                Text(String(localized: "Rule checks"))
                    .font(DS.Typography.ui(11.5, .semibold))
                    .foregroundStyle(DSColor.textSecondary)
                if report.findings.isEmpty {
                    Text(String(localized: "No obvious anomalies found"))
                        .font(DS.Typography.ui(11.5))
                        .foregroundStyle(DSColor.textMuted)
                }
                ForEach(report.findings) { finding in
                    findingCard(finding)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.x3) {
            Button(String(localized: "Copy report")) {
                PDPasteboard.copy(reportText)
                didCopy = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    didCopy = false
                }
            }
            .disabled(report == nil)
            .buttonStyle(.plain)
            .font(DS.Typography.ui(11.5, .medium))
            .foregroundStyle(didCopy ? DSColor.green : DSColor.accent)
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

    // MARK: Analysis

    private func analyze() {
        guard let report else { return }
        guard config.configuration.isUsable else {
            errorText = AIClientError.missingConfiguration.localizedDescription
            return
        }
        isAnalyzing = true
        phase = .running
        errorText = nil
        summary = nil

        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let prompt = AIAnalyzer.prompt(for: report, requests: requests, chinese: chinese)
        let configuration = config.configuration
        Task {
            do {
                let text = try await AIClient.summarize(configuration: configuration, prompt: prompt)
                summary = text
                phase = .done
                showConfiguration = false
            } catch {
                errorText = error.localizedDescription
                phase = .failed
                showConfiguration = true
            }
            isAnalyzing = false
        }
    }
}
