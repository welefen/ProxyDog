import SwiftUI

// MARK: - Status bar

/// Quiet instrument strip at the bottom of the window: capture counts, pause state,
/// certificate state and the listen address.
struct StatusBarView: View {
    @EnvironmentObject private var state: AppState
    /// Sidebar width, so counts line up with the traffic list instead of the sidebar.
    var leadingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: DS.Space.x4) {
            countItem(PDFormat.count(state.filteredRequests.count), label: requestLabel)
            countItem(
                PDFormat.count(errorCount),
                label: errorLabel,
                color: errorCount > 0 ? DSColor.red : DSColor.textMuted,
                onDoubleTap: errorCount > 0 ? toggleErrorFilter : nil
            )

            sizeItem

            if state.store.isPaused {
                pausedChip
            }

            if let message = state.errorMessage {
                errorChip(message)
            }

            Spacer(minLength: 0)

            certificateStatus
            addressButton
        }
        .padding(.leading, leadingInset + DS.Space.x3)
        .padding(.trailing, DS.Space.x3)
        .frame(height: DS.Metric.statusBarHeight)
        .background(DSColor.chrome)
        // The sidebar visually runs to the bottom of the window: the strip's leading
        // segment blends into it, so only the content part gets a top divider, and the
        // column separator continues through the strip. Both are drawn explicitly with a
        // GeometryReader so their positions do not depend on stack alignment.
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(DSColor.border)
                        .frame(
                            width: max(0, proxy.size.width - leadingInset),
                            height: DS.Metric.separator
                        )
                        .offset(x: leadingInset)
                    if leadingInset > 0 {
                        Rectangle()
                            .fill(DSColor.border)
                            .frame(width: DS.Metric.separator, height: proxy.size.height)
                            .offset(x: leadingInset)
                    }
                }
            }
        }
    }

    /// Counts follow the visible list (sidebar scope, type filter and search), not the
    /// whole capture buffer.
    private var errorCount: Int {
        state.filteredRequests.lazy.filter(\.isFailure).count
    }

    /// Response body size as received on the wire (compressed) for the visible requests.
    private var totalWireBytes: Int {
        state.filteredRequests.reduce(0) { $0 + $1.responseWireBytes }
    }

    /// Response body size after decompression for the visible requests.
    private var totalResponseBytes: Int {
        state.filteredRequests.reduce(0) { $0 + $1.responseBytes }
    }

    /// "Wire / decoded" pair, e.g. "线上 96 KB / 解压后 183 KB".
    private var sizeItem: some View {
        HStack(spacing: DS.Space.x1) {
            Text(String(localized: "Wire"))
                .font(DS.Typography.ui(10.5))
                .foregroundStyle(DSColor.textMuted)
            Text(PDFormat.bytes(totalWireBytes))
                .font(DS.Typography.mono(10.5, .medium))
                .foregroundStyle(DSColor.textSecondary)
                .monospacedDigit()
            Text("/")
                .font(DS.Typography.ui(10.5))
                .foregroundStyle(DSColor.textMuted)
            Text(String(localized: "Decoded"))
                .font(DS.Typography.ui(10.5))
                .foregroundStyle(DSColor.textMuted)
            Text(PDFormat.bytes(totalResponseBytes))
                .font(DS.Typography.mono(10.5, .medium))
                .foregroundStyle(DSColor.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .help(String(localized: "Response body size of the visible requests: on the wire (compressed) / after decompression"))
    }

    private var requestLabel: String {
        state.filteredRequests.count == 1
            ? String(localized: "request")
            : String(localized: "requests")
    }

    private var errorLabel: String {
        errorCount == 1
            ? String(localized: "error")
            : String(localized: "errors")
    }

    // MARK: Items

    private func countItem(
        _ value: String,
        label: String,
        color: Color = DSColor.textSecondary,
        onDoubleTap: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: DS.Space.x1) {
            Text(value)
                .font(DS.Typography.mono(10.5, .medium))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(DS.Typography.ui(10.5))
                .foregroundStyle(DSColor.textMuted)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleTap?()
        }
        .help(onDoubleTap == nil ? "" : String(localized: "Double-click to show failed requests"))
        .accessibilityElement(children: .combine)
        .accessibilityHint(onDoubleTap == nil ? "" : String(localized: "Double-click to show failed requests"))
    }

    /// Status-bar error count doubles as a shortcut for the Error type filter.
    private func toggleErrorFilter() {
        state.typeFilter = state.typeFilter == .error ? .all : .error
    }

    private var pausedChip: some View {
        HStack(spacing: DS.Space.x1) {
            Image(systemName: "pause.fill")
                .font(.system(size: 8.5, weight: .semibold))
            Text("Paused")
                .font(DS.Typography.ui(10.5, .medium))
        }
        .foregroundStyle(DSColor.amber)
        .padding(.horizontal, DS.Space.x1 + 2)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                .fill(DSColor.amber.opacity(0.10))
        )
        .help("Capture paused")
        .accessibilityLabel("Capture paused")
    }

    private func errorChip(_ message: String) -> some View {
        HStack(spacing: DS.Space.x1) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 8.5, weight: .semibold))
            Text(message)
                .font(DS.Typography.ui(10.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                state.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss error")
        }
        .foregroundStyle(DSColor.red)
        .padding(.horizontal, DS.Space.x1 + 2)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                .fill(DSColor.red.opacity(0.08))
        )
        .help(message)
    }

    private var certificateStatus: some View {
        HStack(spacing: DS.Space.x1 + 2) {
            Image(systemName: state.isCertificateTrusted ? "lock" : "lock.open")
                .font(.system(size: 9.5, weight: .medium))
            Text(certificateLabel)
                .font(DS.Typography.ui(10.5))
        }
        .foregroundStyle(state.isCertificateTrusted ? DSColor.textMuted : DSColor.amber)
        .help(certificateHelp)
        .accessibilityLabel(certificateLabel)
    }

    private var certificateLabel: String {
        state.isCertificateTrusted
            ? String(localized: "Certificate trusted")
            : String(localized: "Certificate not trusted")
    }

    private var certificateHelp: String {
        state.isCertificateTrusted
            ? String(localized: "The ProxyDog root certificate is trusted")
            : String(localized: "The ProxyDog root certificate is not trusted")
    }

    private var addressButton: some View {
        // Show the port the listener actually bound (the engine may fall back when
        // the configured port is busy), not just the configured preference.
        StatusBarAddressButton(port: state.proxyStatus.port ?? state.settings.port)
    }
}

private struct StatusBarAddressButton: View {
    let port: Int
    @State private var isHovering = false
    @State private var didCopy = false

    private var address: String { "127.0.0.1:\(port)" }

    var body: some View {
        Button {
            PDPasteboard.copy(address)
            didCopy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                didCopy = false
            }
        } label: {
            HStack(spacing: DS.Space.x1 + 2) {
                Image(systemName: didCopy ? "checkmark" : "network")
                    .font(.system(size: 9.5, weight: .medium))
                Text(address)
                    .font(DS.Typography.mono(10.5))
                    .monospacedDigit()
            }
            .foregroundStyle(didCopy ? DSColor.green : (isHovering ? DSColor.textSecondary : DSColor.textMuted))
            .padding(.horizontal, DS.Space.x1 + 2)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                    .fill(isHovering ? DSColor.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(didCopy ? String(localized: "Copied") : String(localized: "Copy proxy address"))
        .accessibilityLabel(String(
            format: String(localized: "Copy proxy address %@"),
            address
        ))
    }
}
