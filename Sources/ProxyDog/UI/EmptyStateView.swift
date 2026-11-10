import SwiftUI

// MARK: - Empty traffic

/// Quiet onboarding panel shown when nothing has been captured yet: the listen
/// address, a copy button, and the three steps needed to route traffic through it.
struct TrafficEmptyStateView: View {
    @EnvironmentObject private var state: AppState
    @State private var didCopy = false

    private var listenAddress: String { "127.0.0.1:\(state.settings.port)" }

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
            .help(didCopy ? "Copied" : "Copy proxy address")
            .accessibilityLabel("Copy proxy address")
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
            step("1", "Turn on the system proxy")
            step("2", "Trust the root certificate for HTTPS")
            step("3", "Reload the app you want to inspect")
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
                Text(proxyFailed ? "The proxy could not start" : "The proxy is off")
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(proxyFailed ? DSColor.red : DSColor.textMuted)
                    .help(proxyError)
                Spacer(minLength: 0)
                PDIconButton(
                    symbol: "power",
                    help: "Start proxy",
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

// MARK: - Empty search results

struct TrafficNoMatchesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: DS.Space.x3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(DSColor.textMuted)
            Text("No matching requests")
                .font(DS.Typography.ui(12.5, .medium))
                .foregroundStyle(DSColor.textSecondary)
            PDIconButton(symbol: "xmark", help: "Clear search") {
                state.searchText = ""
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty inspector

struct DetailEmptyStateView: View {
    var body: some View {
        PDPlaceholder(symbol: "cursorarrow", title: "Select a request")
    }
}
