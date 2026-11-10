import AppKit
import SwiftUI

// MARK: - Detail inspector

enum DetailTab: String, CaseIterable, Identifiable {
    case overview
    case headers
    case body

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .headers: return "Headers"
        case .body: return "Body"
        }
    }
}

/// Right column: request line, tab bar, and the overview / headers / body inspectors.
struct RequestDetailView: View {
    @EnvironmentObject private var state: AppState

    @State private var tab: DetailTab = DevLaunchOptions.initialTab ?? .overview

    var body: some View {
        Group {
            if let request = state.selectedRequest {
                VStack(spacing: 0) {
                    header(for: request)
                    tabBar
                    tabContent(for: request)
                }
            } else {
                DetailEmptyStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColor.base)
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
                help: request.isPinned ? "Unpin request" : "Pin request",
                isOn: request.isPinned
            ) {
                state.togglePin(request.id)
            }

            PDIconButton(symbol: "doc.on.doc", help: "Copy URL") {
                PDPasteboard.copy(request.urlString)
            }
        }
        .padding(.horizontal, DS.Space.x4)
        .frame(minHeight: DS.Metric.detailHeaderHeight)
        .background(DSColor.base)
        .overlay(alignment: .bottom) { PDHairline() }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: DS.Space.x5) {
            ForEach(DetailTab.allCases) { item in
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
                .frame(height: DS.Metric.tabBarHeight, alignment: .bottom)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? DSColor.accent : Color.clear)
                        .frame(height: 2)
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

private struct OverviewTab: View {
    let request: CapturedRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x6) {
                section("Request") {
                    DetailFieldRow(label: "Method", value: request.method)
                    DetailFieldRow(label: "URL", value: request.urlString, lineLimit: 3)
                    DetailFieldRow(label: "Protocol", value: "HTTP/1.1")
                    if let client = request.clientAppName {
                        DetailFieldRow(label: "Client", value: client)
                    }
                    DetailFieldRow(label: "Body size", value: PDFormat.bytes(request.requestBytes))
                    decryptedRow
                }

                section("Response") {
                    statusRow
                    DetailFieldRow(label: "Content type", value: request.responseContentType ?? "—")
                    DetailFieldRow(label: "Body size", value: PDFormat.bytes(request.responseBytes))
                    DetailFieldRow(
                        label: "Duration",
                        value: PDFormat.duration(request.duration),
                        color: DSColor.textSecondary
                    )
                }

                section("Timing") {
                    DetailFieldRow(label: "Started", value: PDFormat.clockTime(request.startedAt))
                    DetailFieldRow(
                        label: "Completed",
                        value: request.finishedAt.map(PDFormat.clockTime) ?? "—"
                    )
                    DetailFieldRow(
                        label: "Total",
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

    private var decryptedRow: some View {
        HStack(alignment: .center, spacing: DS.Space.x3) {
            Text("Decrypted")
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 104, alignment: .leading)
            if request.intercepted {
                PDPropertyBadge(text: "Decrypted", symbol: "lock.open", tint: DSColor.green)
            } else if request.state == .tunneled {
                PDPropertyBadge(text: "Tunneled", symbol: "lock", tint: DSColor.textMuted)
            } else {
                PDPropertyBadge(text: "Not intercepted", symbol: "lock", tint: DSColor.textMuted)
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
            Text(request.errorMessage ?? "The exchange failed.")
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
                HeadersSectionView(title: "Request headers", headers: request.requestHeaders)
                HeadersSectionView(title: "Response headers", headers: request.responseHeaders)
            }
            .padding(DS.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
