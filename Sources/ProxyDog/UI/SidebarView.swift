import SwiftUI

// MARK: - Sidebar

/// Quiet navigation column: traffic scope and host filtering.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    trafficSection
                    clientsSection
                    domainsSection
                }
                .padding(.horizontal, DS.Space.x2)
                .padding(.top, DS.Space.x1)
                .padding(.bottom, DS.Space.x4)
            }
        }
        .background(DSColor.chrome)
        .overlay(alignment: .trailing) { PDHairline(vertical: true) }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        )
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

    /// Traffic grouped by the app that sent it; hidden until at least one request was
    /// attributed to a local process.
    private var clientsSection: some View {
        let summaries = state.clientSummaries
        return VStack(alignment: .leading, spacing: 1) {
            if !summaries.isEmpty {
                sectionHeader(String(localized: "Clients"))
                    .padding(.top, DS.Space.x3)
                ForEach(summaries) { summary in
                    SidebarRow(
                        symbol: "app",
                        title: summary.name,
                        appIconPath: summary.iconPath,
                        count: summary.count,
                        hasFailure: summary.hasFailure,
                        isSelected: state.sidebarSelection == .client(summary.name)
                    ) {
                        state.sidebarSelection = .client(summary.name)
                    }
                }
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
                        faviconDomain: summary.domain,
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
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let symbol: String
    let title: String
    var faviconDomain: String? = nil
    var appIconPath: String? = nil
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
                if let appIconPath, let appIcon = AppIconProvider.icon(for: appIconPath) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else if let faviconDomain {
                    DomainFavicon(domain: faviconDomain)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isSelected ? DSColor.textSecondary : DSColor.textMuted)
                        .frame(width: 14)
                }
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
