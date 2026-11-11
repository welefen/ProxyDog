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
                }
                Spacer(minLength: 0)
            }

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
