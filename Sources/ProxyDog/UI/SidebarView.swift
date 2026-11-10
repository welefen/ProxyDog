import SwiftUI

// MARK: - Sidebar

/// Quiet navigation column: traffic scope, hosts, and the proxy footer.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    trafficSection
                    domainsSection
                }
                .padding(.horizontal, DS.Space.x2)
                .padding(.top, DS.Space.x1)
                .padding(.bottom, DS.Space.x4)
            }
            footer
        }
        .background(DSColor.chrome)
        .overlay(alignment: .trailing) { PDHairline(vertical: true) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.x2) {
            AppBrandIcon(size: 22)
            Text("ProxyDog")
                .font(DS.Typography.ui(13.5, .semibold))
                .foregroundStyle(DSColor.textPrimary)
            Text(AppInfo.versionLabel)
                .font(DS.Typography.ui(10))
                .foregroundStyle(DSColor.textMuted)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.x3)
        .padding(.top, DS.Space.x2)
        .padding(.bottom, DS.Space.x3)
    }

    // MARK: Sections

    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader(String(localized: "Traffic"))
            SidebarRow(
                symbol: "tray.full",
                title: String(localized: "All Requests"),
                count: state.store.requests.count,
                isSelected: state.sidebarSelection == .all
            ) {
                state.sidebarSelection = .all
            }
            SidebarRow(
                symbol: "pin",
                title: String(localized: "Pinned"),
                count: state.pinnedCount,
                isSelected: state.sidebarSelection == .pinned
            ) {
                state.sidebarSelection = .pinned
            }
        }
    }

    private var domainsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader(String(localized: "Domains"))
                .padding(.top, DS.Space.x3)

            let summaries = state.domainSummaries
            if summaries.isEmpty {
                Text("No domains yet")
                    .font(DS.Typography.ui(11.5))
                    .foregroundStyle(DSColor.textMuted)
                    .padding(.horizontal, DS.Space.x2)
                    .frame(height: DS.Metric.sidebarRowHeight)
            } else {
                ForEach(summaries) { summary in
                    SidebarRow(
                        symbol: "globe",
                        title: summary.domain,
                        count: summary.count,
                        hasFailure: summary.hasFailure,
                        isSelected: state.sidebarSelection == .domain(summary.domain),
                        monoTitle: true
                    ) {
                        state.sidebarSelection = .domain(summary.domain)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DS.Typography.ui(10.5, .semibold))
            .foregroundStyle(DSColor.textMuted)
            .padding(.horizontal, DS.Space.x2)
            .padding(.top, DS.Space.x2)
            .padding(.bottom, DS.Space.x1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            PDHairline()
            HStack(spacing: DS.Space.x2) {
                PDStatusDot(color: proxyDotColor)
                statusLabel
                Spacer(minLength: DS.Space.x1)
                if !state.isCertificateTrusted {
                    PDIconButton(
                        symbol: "exclamationmark.triangle",
                        help: String(localized: "Root certificate is not trusted. Click to install."),
                        role: .warning,
                        size: 24
                    ) {
                        state.installCertificate()
                    }
                }
                PDIconButton(
                    symbol: state.isProxyRunning ? "power.circle.fill" : "power",
                    help: state.isProxyRunning
                        ? String(localized: "Stop proxy")
                        : String(localized: "Start proxy"),
                    role: state.isProxyRunning ? .accent : .normal,
                    size: 24
                ) {
                    state.toggleProxy()
                }
                PDSettingsIconButton(size: 24)
            }
            .padding(.horizontal, DS.Space.x2)
            .frame(height: 44)
        }
        .background(DSColor.chrome)
    }

    private var statusLabel: some View {
        let isAddress = state.isProxyRunning && !state.store.isPaused
        return Text(statusText)
            .font(isAddress ? DS.Typography.mono(10.5) : DS.Typography.ui(10.5, .medium))
            .foregroundStyle(statusColor)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .help(statusHelp)
            .accessibilityLabel(statusAccessibilityLabel)
    }

    private var proxyDotColor: Color {
        if case .failed = state.proxyStatus { return DSColor.red }
        if state.isProxyRunning {
            return state.store.isPaused ? DSColor.amber : DSColor.green
        }
        if case .starting = state.proxyStatus { return DSColor.amber }
        return DSColor.textMuted
    }

    private var statusText: String {
        if case .failed = state.proxyStatus { return String(localized: "Failed") }
        if state.isProxyRunning {
            if state.store.isPaused { return String(localized: "Paused") }
            return "127.0.0.1:\(state.proxyStatus.port ?? state.settings.port)"
        }
        if case .starting = state.proxyStatus { return String(localized: "Starting") }
        return String(localized: "Stopped")
    }

    private var statusColor: Color {
        if case .failed = state.proxyStatus { return DSColor.red }
        if state.isProxyRunning {
            return state.store.isPaused ? DSColor.amber : DSColor.textSecondary
        }
        if case .starting = state.proxyStatus { return DSColor.amber }
        return DSColor.textMuted
    }

    private var statusHelp: String {
        if case .failed(let message) = state.proxyStatus { return message }
        if state.isProxyRunning {
            if state.store.isPaused {
                return String(localized: "Capture paused. Resume from the toolbar.")
            }
            return String(
                format: String(localized: "Listening on %@"),
                "127.0.0.1:\(state.proxyStatus.port ?? state.settings.port)"
            )
        }
        return String(localized: "Start the proxy to capture traffic")
    }

    private var statusAccessibilityLabel: String {
        if case .failed = state.proxyStatus {
            return String(format: String(localized: "Proxy failed. %@"), statusHelp)
        }
        if state.isProxyRunning {
            if state.store.isPaused {
                return String(localized: "Capture paused")
            }
            return String(
                format: String(localized: "Listening on %@"),
                "127.0.0.1:\(state.proxyStatus.port ?? state.settings.port)"
            )
        }
        return String(localized: "Proxy stopped")
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let symbol: String
    let title: String
    var count: Int?
    var hasFailure = false
    var isSelected = false
    var monoTitle = false
    let action: () -> Void

    @State private var isHovering = false

    private var background: Color {
        if isSelected { return DSColor.selection }
        return isHovering ? DSColor.hover : .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.x2) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isSelected ? DSColor.textSecondary : DSColor.textMuted)
                    .frame(width: 14)
                Text(title)
                    .font(monoTitle ? DS.Typography.mono(11.5) : DS.Typography.ui(12))
                    .foregroundStyle(isSelected ? DSColor.textPrimary : DSColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.x1)
                if hasFailure {
                    PDStatusDot(color: DSColor.red)
                }
                if let count {
                    Text(PDFormat.count(count))
                        .font(DS.Typography.mono(10.5))
                        .foregroundStyle(DSColor.textMuted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, DS.Space.x2)
            .frame(height: DS.Metric.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(background)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(DSColor.accent)
                        .frame(width: 2, height: 14)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityLabel: String {
        var label = title
        if let count { label += ", \(count)" }
        if hasFailure { label += String(localized: ", has errors") }
        return label
    }
}
