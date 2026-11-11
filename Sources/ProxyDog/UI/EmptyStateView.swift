import SwiftUI

// MARK: - Empty traffic

/// Quiet onboarding panel shown when nothing has been captured yet: the listen
/// address, a copy button, and the three steps needed to route traffic through it.
struct TrafficEmptyStateView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var didCopy = false

    private var listenAddress: String {
        "127.0.0.1:\(state.proxyStatus.port ?? state.settings.port)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "network")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DSColor.textMuted)

            Text("No traffic captured")
                .font(DS.Typography.ui(13, .medium))
                .foregroundStyle(DSColor.textPrimary)
                .padding(.top, DS.Space.x3)

            portChip
                .padding(.top, DS.Space.x3)

            steps
                .padding(.top, DS.Space.x6)

            proxyRow
                .padding(.top, DS.Space.x4)

            Button {
                state.requestSettings(destination: .connection)
                openSettings()
            } label: {
                Text(String(localized: "Open Settings"))
                    .font(DS.Typography.ui(11.5, .medium))
                    .foregroundStyle(DSColor.accent)
                    .padding(.horizontal, DS.Space.x3)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(DSColor.raised)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                    .strokeBorder(DSColor.border, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Space.x3)
        }
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.x6)
    }

    private var portChip: some View {
        HStack(spacing: DS.Space.x2) {
            Text(listenAddress)
                .font(DS.Typography.mono(12, .medium))
                .foregroundStyle(DSColor.textSecondary)
                .monospacedDigit()
                .textSelection(.enabled)
            Button {
                PDPasteboard.copy(listenAddress)
                didCopy = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(didCopy ? DSColor.green : DSColor.textMuted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(didCopy ? String(localized: "Copied") : String(localized: "Copy proxy address"))
            .accessibilityLabel(String(localized: "Copy proxy address"))
        }
        .padding(.horizontal, DS.Space.x2 + 2)
        .frame(height: DS.Metric.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DSColor.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .strokeBorder(DSColor.border, lineWidth: DS.Metric.separator)
        )
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            step("1", String(localized: "Turn on the system proxy"))
            step("2", String(localized: "Trust the root certificate for HTTPS"))
            step("3", String(localized: "Reload the app you want to inspect"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: String, _ title: String) -> some View {
        HStack(spacing: DS.Space.x2) {
            Text(number)
                .font(DS.Typography.mono(10, .medium))
                .foregroundStyle(DSColor.textMuted)
                .frame(width: 16, height: 16)
                .background(Circle().fill(DSColor.sunken))
            Text(title)
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var proxyRow: some View {
        if state.isProxyRunning {
            EmptyView()
        } else {
            HStack(spacing: DS.Space.x2) {
                PDStatusDot(color: proxyFailed ? DSColor.red : DSColor.textMuted)
                Text(proxyFailed
                    ? String(localized: "The proxy could not start")
                    : String(localized: "The proxy is off"))
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(proxyFailed ? DSColor.red : DSColor.textMuted)
                    .help(proxyError)
                Spacer(minLength: 0)
                PDIconButton(
                    symbol: "power",
                    help: String(localized: "Start proxy"),
                    role: .accent
                ) {
                    state.toggleProxy()
                }
            }
            .padding(.top, DS.Space.x2)
        }
    }

    private var proxyFailed: Bool {
        if case .failed = state.proxyStatus { return true }
        return false
    }

    private var proxyError: String {
        if case .failed(let message) = state.proxyStatus { return message }
        return ""
    }
}

// MARK: - Empty search/filter results

struct TrafficNoMatchesView: View {
    enum Reason {
        case search
        case typeFilter
    }

    var reason: Reason = .search

    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: DS.Space.x3) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(DSColor.textMuted)
            Text(title)
                .font(DS.Typography.ui(12.5, .medium))
                .foregroundStyle(DSColor.textSecondary)
            action
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch reason {
        case .search: return "magnifyingglass"
        case .typeFilter: return "line.3.horizontal.decrease.circle"
        }
    }

    private var title: String {
        switch reason {
        case .search: return String(localized: "No matching requests")
        case .typeFilter: return String(localized: "No requests match this filter")
        }
    }

    @ViewBuilder
    private var action: some View {
        switch reason {
        case .search:
            PDIconButton(symbol: "xmark", help: String(localized: "Clear search")) {
                state.searchText = ""
            }
        case .typeFilter:
            Button {
                state.typeFilter = .all
            } label: {
                Text(String(localized: "Clear filter"))
                    .font(DS.Typography.ui(12, .medium))
                    .foregroundStyle(DSColor.accent)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Clear filter"))
            .accessibilityLabel(String(localized: "Clear filter"))
        }
    }
}

// MARK: - Empty inspector

struct DetailEmptyStateView: View {
    var body: some View {
        PDPlaceholder(symbol: "cursorarrow", title: String(localized: "Select a request"))
    }
}
