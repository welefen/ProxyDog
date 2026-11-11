import SwiftUI

/// Cookie table under the request/response header cards.
struct CookieSectionView: View {
    enum Kind {
        case request
        case response
    }

    let kind: Kind
    let requestCookies: [RequestCookie]
    let responseCookies: [ResponseCookie]
    var totalBytes: Int = 0

    @State private var isHovering = false
    @State private var didCopyAll = false

    private var title: String {
        kind == .request
            ? String(localized: "Request Cookie")
            : String(localized: "Response Cookie")
    }

    private var count: Int {
        kind == .request ? requestCookies.count : responseCookies.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x1 + 2) {
                Text(title)
                    .font(DS.Typography.ui(11.5, .semibold))
                    .foregroundStyle(DSColor.textSecondary)
                Text(String(count))
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
                if count > 0 {
                    Text(PDFormat.bytes(totalBytes))
                        .font(DS.Typography.mono(10.5))
                        .foregroundStyle(DSColor.textMuted)
                        .monospacedDigit()

                    Button {
                        copyAll()
                        didCopyAll = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            didCopyAll = false
                        }
                    } label: {
                        Image(systemName: didCopyAll ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(didCopyAll ? DSColor.green : DSColor.textMuted)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering || didCopyAll ? 1 : 0)
                    .fastTooltip(String(localized: "Copy all cookies"))
                    .accessibilityLabel(String(localized: "Copy all cookies"))
                }
                Spacer(minLength: 0)
            }
            .onHover { isHovering = $0 }

            if count == 0 {
                Text("No cookies")
                    .font(DS.Typography.ui(11.5))
                    .foregroundStyle(DSColor.textMuted)
                    .padding(.horizontal, DS.Space.x2)
                    .frame(height: 24)
            } else if kind == .request {
                table {
                    row(header: true, cells: [("Name", 160), ("Value", nil)])
                    ForEach(requestCookies) { cookie in
                        Divider().overlay(DSColor.border)
                        row(header: false, cells: [("Name", 160), ("Value", nil)], values: [cookie.name, cookie.value])
                    }
                }
            } else {
                table {
                    row(header: true, cells: [("Name", 120), ("Value", 150), ("Domain", 110), ("Path", 50), ("Expires", 140), ("Flags", 220)])
                    ForEach(responseCookies) { cookie in
                        Divider().overlay(DSColor.border)
                        row(
                            header: false,
                            cells: [("Name", 120), ("Value", 150), ("Domain", 110), ("Path", 50), ("Expires", 140), ("Flags", 220)],
                            values: [
                                cookie.name,
                                cookie.value,
                                cookie.domain ?? "",
                                cookie.path ?? "",
                                cookie.expires ?? "",
                                cookie.flags ?? "",
                            ]
                        )
                    }
                }
            }
        }
    }

    private func copyAll() {
        let text: String
        if kind == .request {
            text = requestCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
        } else {
            text = responseCookies.map { cookie in
                var pieces = ["\(cookie.name)=\(cookie.value)"]
                if let domain = cookie.domain { pieces.append("Domain=\(domain)") }
                if let path = cookie.path { pieces.append("Path=\(path)") }
                if let expires = cookie.expires { pieces.append("Expires=\(expires)") }
                if let flags = cookie.flags { pieces.append(flags.replacingOccurrences(of: " · ", with: "; ")) }
                return pieces.joined(separator: "; ")
            }
            .joined(separator: "\n")
        }
        PDPasteboard.copy(text)
    }

    private func table<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(DSColor.raised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .strokeBorder(DSColor.border, lineWidth: DS.Metric.separator)
            )
    }

    @ViewBuilder
    private func row(header: Bool, cells: [(String, CGFloat?)], values: [String] = []) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let text = header ? cell.0 : (index < values.count ? values[index] : "")
                Text(text)
                    .help(text)
                    .font(header ? DS.Typography.ui(10.5, .medium) : DS.Typography.mono(11))
                    .foregroundStyle(header ? DSColor.textMuted : DSColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(width: cell.1, alignment: .leading)
                    .frame(maxWidth: cell.1 == nil ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, index == 0 ? DS.Space.x2 : 6)
                    .padding(.vertical, 5)
            }
        }
        .background(header ? DSColor.sunken : Color.clear)
    }
}
