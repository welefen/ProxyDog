import AppKit
import SwiftUI

// MARK: - Detail inspector

enum DetailTab: String, CaseIterable, Identifiable {
    case overview
    case headers
    case body
    case messages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return String(localized: "Overview")
        case .headers: return String(localized: "Headers")
        case .body: return String(localized: "Body")
        case .messages: return String(localized: "Messages")
        }
    }

    /// WebSocket exchanges show Messages instead of Body (a 101 has no body).
    static func tabs(for request: CapturedRequest) -> [DetailTab] {
        request.isWebSocket ? [.overview, .headers, .messages] : [.overview, .headers, .body]
    }
}

/// Right column: request line, tab bar, and the overview / headers / body inspectors.
struct RequestDetailView: View {
    @EnvironmentObject private var state: AppState

    @State private var tab: DetailTab = DevLaunchOptions.isSampleTrafficEnabled
        ? (DevLaunchOptions.initialTab ?? .overview)
        : .overview

    var body: some View {
        Group {
            if let request = state.selectedRequest {
                VStack(spacing: 0) {
                    header(for: request)
                    tabBar(for: request)
                    tabContent(for: request)
                }
            } else {
                DetailEmptyStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColor.base)
        .onChange(of: state.selectionID) { _, _ in normalizeTab() }
    }

    /// Keep the selected tab valid when switching between HTTP and WebSocket rows.
    private func normalizeTab() {
        guard let request = state.selectedRequest else { return }
        if !DetailTab.tabs(for: request).contains(tab) {
            tab = .overview
        }
    }

    // MARK: Header

    private func header(for request: CapturedRequest) -> some View {
        HStack(spacing: DS.Space.x3) {
            MethodBadge(method: request.method)

            Text(PDStatus.fullLabel(for: request))
                .font(DS.Typography.mono(11.5, .semibold))
                .foregroundStyle(PDStatus.color(for: request))
                .monospacedDigit()

            Text(request.urlString)
                .font(DS.Typography.mono(12.5, .medium))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(request.urlString)

            Spacer(minLength: DS.Space.x2)

            PDIconButton(
                symbol: request.isPinned ? "pin.fill" : "pin",
                help: request.isPinned
                    ? String(localized: "Unpin request")
                    : String(localized: "Pin request"),
                isOn: request.isPinned
            ) {
                state.togglePin(request.id)
            }

            PDIconButton(symbol: "doc.on.doc", help: String(localized: "Copy URL")) {
                PDPasteboard.copy(request.urlString)
            }
        }
        .padding(.horizontal, DS.Space.x4)
        .frame(minHeight: DS.Metric.detailHeaderHeight)
        .background(DSColor.base)
        .overlay(alignment: .bottom) { PDHairline() }
    }

    // MARK: Tabs

    private func tabBar(for request: CapturedRequest) -> some View {
        HStack(spacing: DS.Space.x5) {
            ForEach(DetailTab.tabs(for: request)) { item in
                DetailTabButton(title: item.title, isSelected: tab == item) {
                    tab = item
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.x4)
        .frame(height: DS.Metric.tabBarHeight)
        .overlay(alignment: .bottom) { PDHairline() }
    }

    @ViewBuilder
    private func tabContent(for request: CapturedRequest) -> some View {
        switch tab {
        case .overview:
            OverviewTab(request: request)
        case .headers:
            HeadersTab(request: request)
        case .body:
            BodyTabView(request: request)
        case .messages:
            WebSocketMessagesTabView(request: request)
                .id(request.id)
        }
    }
}

// MARK: - Tab button

private struct DetailTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.ui(12, isSelected ? .medium : .regular))
                .foregroundStyle(
                    isSelected
                        ? DSColor.textPrimary
                        : (isHovering ? DSColor.textSecondary : DSColor.textMuted)
                )
                .padding(.bottom, DS.Metric.Tabs.textBottomInset)
                .frame(height: DS.Metric.tabBarHeight, alignment: .bottom)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? DSColor.accent : Color.clear)
                        .frame(height: DS.Metric.Tabs.indicatorHeight)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Overview

/// URL row that starts clamped to three lines and expands to the full value on click.
/// Keeping the clamped and expanded layouts as real layout (instead of selecting an
/// over-long selectable Text) avoids the text painting over the rows below it.
private struct URLFieldRow: View {
    let url: String

    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.x3) {
            Text("URL")
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 104, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x1 + 2) {
                Text(url)
                    .font(DS.Typography.mono(11.5))
                    .foregroundStyle(DSColor.textPrimary)
                    .monospacedDigit()
                    .lineLimit(isExpanded ? nil : 3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DSColor.textMuted)
                        .frame(width: 12, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? String(localized: "Collapse") : String(localized: "Expand"))
                .accessibilityLabel(isExpanded ? String(localized: "Collapse") : String(localized: "Expand"))
            }
        }
        .frame(minHeight: 20)
    }
}

private struct OverviewTab: View {
    let request: CapturedRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x6) {
                section(String(localized: "Request")) {
                    DetailFieldRow(label: String(localized: "Method"), value: request.method)
                    URLFieldRow(url: request.urlString)
                    DetailFieldRow(label: String(localized: "Protocol"), value: request.httpVersion)
                    if let rewrite = request.rewriteRuleName {
                        DetailFieldRow(
                            label: String(localized: "Rewrite"),
                            value: request.rewriteAction.map { "\(rewrite) · \($0)" } ?? rewrite,
                            color: DSColor.textSecondary
                        )
                    }
                    if let breakpoint = request.breakpointRuleName {
                        let phase = request.breakpointPhase == "response"
                            ? String(localized: "Response")
                            : String(localized: "Request")
                        DetailFieldRow(
                            label: String(localized: "Breakpoint"),
                            value: "\(phase) · \(breakpoint)",
                            color: DSColor.textSecondary
                        )
                    }
                    if let client = request.clientAppName {
                        DetailFieldRow(label: String(localized: "Client"), value: client)
                    }
                    if let pid = request.clientPID {
                        processRow(pid: pid)
                    }
                    if let userAgent = request.userAgent {
                        DetailFieldRow(
                            label: String(localized: "User-Agent"),
                            value: userAgent,
                            lineLimit: 3
                        )
                    }
                    if !request.isWebSocket {
                        DetailFieldRow(
                            label: String(localized: "Body size"),
                            value: PDFormat.bytes(request.requestBytes)
                        )
                    }
                    decryptedRow
                }

                section(String(localized: "Response")) {
                    statusRow
                    if request.advertisesHTTP3 {
                        DetailFieldRow(
                            label: "HTTP/3",
                            value: String(localized: "Advertised by Alt-Svc · QUIC bypasses the proxy and cannot be captured"),
                            color: DSColor.textSecondary
                        )
                    }
                    DetailFieldRow(label: String(localized: "Content type"), value: request.responseContentType ?? "—")
                    if !request.isWebSocket {
                        DetailFieldRow(
                            label: String(localized: "Body size"),
                            value: PDFormat.bytes(request.responseBytes)
                        )
                    }
                    DetailFieldRow(
                        label: String(localized: "Duration"),
                        value: PDFormat.duration(request.duration),
                        color: DSColor.textSecondary
                    )
                }

                if request.isWebSocket {
                    section(String(localized: "WebSocket")) {
                        webSocketStateRow
                        DetailFieldRow(
                            label: String(localized: "Messages"),
                            value: PDFormat.count(request.webSocketMessages.count)
                        )
                        DetailFieldRow(
                            label: String(localized: "Duration"),
                            value: PDFormat.duration(webSocketDuration),
                            color: DSColor.textSecondary
                        )
                    }
                }

                section(String(localized: "Timing")) {
                    DetailFieldRow(label: String(localized: "Started"), value: PDFormat.clockTime(request.startedAt))
                    DetailFieldRow(
                        label: String(localized: "Completed"),
                        value: request.finishedAt.map(PDFormat.clockTime) ?? "—"
                    )
                    DetailFieldRow(
                        label: String(localized: "Total"),
                        value: PDFormat.duration(request.duration),
                        color: DSColor.textSecondary
                    )
                }

                if request.state == .failed {
                    errorNote
                }
            }
            .padding(DS.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            PDSectionLabel(title: title)
            VStack(alignment: .leading, spacing: DS.Space.x1 + 2) {
                content()
            }
        }
    }

    /// Local process that opened the connection; hovering reveals the executable path.
    @ViewBuilder
    private func processRow(pid: Int32) -> some View {
        if let path = request.clientAppPath, !path.isEmpty {
            processRowContent(pid: pid)
                .help(path)
        } else {
            processRowContent(pid: pid)
        }
    }

    private func processRowContent(pid: Int32) -> some View {
        HStack(alignment: .center, spacing: DS.Space.x3) {
            Text(String(localized: "Process"))
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 104, alignment: .leading)
            Text(String(format: "pid %lld", Int64(pid)))
                .font(DS.Typography.mono(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
    }

    private var webSocketConnected: Bool {
        request.finishedAt == nil && request.state != .failed
    }

    private var webSocketDuration: TimeInterval {
        if let finishedAt = request.finishedAt {
            return max(0, finishedAt.timeIntervalSince(request.startedAt))
        }
        return max(0, Date().timeIntervalSince(request.startedAt))
    }

    private var webSocketStateRow: some View {
        HStack(alignment: .center, spacing: DS.Space.x3) {
            Text("Status")
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 104, alignment: .leading)
            Text(webSocketConnected ? String(localized: "Connected") : String(localized: "Closed"))
                .font(DS.Typography.mono(11.5, .semibold))
                .foregroundStyle(webSocketConnected ? DSColor.green : DSColor.textMuted)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
    }

    private var decryptedRow: some View {
        HStack(alignment: .center, spacing: DS.Space.x3) {
            Text("Decrypted")
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 104, alignment: .leading)
            if request.intercepted {
                PDPropertyBadge(text: String(localized: "Decrypted"), symbol: "lock.open", tint: DSColor.green)
            } else if request.state == .tunneled {
                PDPropertyBadge(text: String(localized: "Tunneled"), symbol: "lock", tint: DSColor.textMuted)
            } else {
                PDPropertyBadge(text: String(localized: "Not intercepted"), symbol: "lock", tint: DSColor.textMuted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
    }

    private var statusRow: some View {
        HStack(alignment: .center, spacing: DS.Space.x3) {
            Text("Status")
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 104, alignment: .leading)
            Text(PDStatus.fullLabel(for: request))
                .font(DS.Typography.mono(11.5, .semibold))
                .foregroundStyle(PDStatus.color(for: request))
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
    }

    private var errorNote: some View {
        HStack(alignment: .top, spacing: DS.Space.x2) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DSColor.red)
                .padding(.top, 2)
            Text(request.errorMessage ?? String(localized: "The exchange failed."))
                .font(DS.Typography.mono(11.5))
                .foregroundStyle(DSColor.red)
                .textSelection(.enabled)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.x3)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DSColor.red.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .strokeBorder(DSColor.red.opacity(0.20), lineWidth: DS.Metric.separator)
        )
    }
}

// MARK: - Headers

private struct HeadersTab: View {
    let request: CapturedRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x6) {
                HeadersSectionView(
                    title: String(localized: "Request headers"),
                    headers: request.requestHeaders
                )
                HeadersSectionView(
                    title: String(localized: "Response headers"),
                    headers: request.responseHeaders
                )
            }
            .padding(DS.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
