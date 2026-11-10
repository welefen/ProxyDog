import AppKit
import SwiftUI

// MARK: - Design tokens
//
// One cool-tinted graphite neutral ramp for every surface, border and text role,
// exactly one accent (blue) used for selection and the primary action, and a
// toned-down semantic palette (green / amber / red / blue) used for status only.
// Everything on a 4pt grid. Light mode is the primary design, dark mode is a
// first-class peer (all colors are appearance adaptive).

enum DS {
    /// 4pt spacing grid. All padding / gaps must use these values.
    enum Space {
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x5: CGFloat = 20
        static let x6: CGFloat = 24
        static let x8: CGFloat = 32
        static let x10: CGFloat = 40
    }

    enum Radius {
        static let xs: CGFloat = 3
        static let sm: CGFloat = 5
        static let md: CGFloat = 7
        static let lg: CGFloat = 9
    }

    enum Metric {
        // Window columns
        static let sidebarMin: CGFloat = 220
        static let sidebarIdeal: CGFloat = 232
        static let sidebarMax: CGFloat = 248
        static let listMin: CGFloat = 360
        static let listIdeal: CGFloat = 560
        static let detailMin: CGFloat = 340
        static let detailIdeal: CGFloat = 520

        // Rhythm
        static let rowHeight: CGFloat = 30
        static let sidebarRowHeight: CGFloat = 28
        static let columnHeaderHeight: CGFloat = 24
        static let statusBarHeight: CGFloat = 26
        static let detailHeaderHeight: CGFloat = 44
        static let tabBarHeight: CGFloat = 34

        /// Detail tab strip geometry: the label keeps a small gap above the indicator
        /// line instead of sitting flush on it.
        enum Tabs {
            static let textBottomInset: CGFloat = 7
            static let indicatorHeight: CGFloat = 2
        }
        static let controlHeight: CGFloat = 26
        static let iconButtonSize: CGFloat = 26
        static let separator: CGFloat = 0.5
        static let horizontalPadding: CGFloat = 12

        // Traffic list columns (trailing columns are fixed width so numbers align)
        static let iconColumnWidth: CGFloat = 20
        static let methodColumnWidth: CGFloat = 46
        static let statusColumnWidth: CGFloat = 44
        static let sizeColumnWidth: CGFloat = 58
        static let durationColumnWidth: CGFloat = 58
        static let pinColumnWidth: CGFloat = 14
    }

    /// SF Pro for UI, SF Mono for anything technical (URLs, headers, numbers).
    enum Typography {
        static func ui(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }

        static func mono(_ size: CGFloat = 11.5, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        static func tabular(_ font: Font) -> Font { font.monospacedDigit() }
    }
}

// MARK: - Colors

private func pdColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private func pdAdaptive(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

enum DSColor {
    // Surfaces, from chrome (window furniture) to raised (fields, selected segments).
    static let chrome = pdAdaptive(pdColor(0xF2F4F7), pdColor(0x17191D))
    static let base = pdAdaptive(pdColor(0xFAFAFC), pdColor(0x1B1E23))
    static let raised = pdAdaptive(pdColor(0xFFFFFF), pdColor(0x22262C))
    static let sunken = pdAdaptive(pdColor(0xECEEF2), pdColor(0x131519))
    static let hover = pdAdaptive(pdColor(0xEEF1F5), pdColor(0x23282F))
    static let selection = pdAdaptive(pdColor(0xE3E9F2), pdColor(0x2A313A))

    // Hairlines and dithered borders.
    static let border = pdAdaptive(pdColor(0xE1E5EB), pdColor(0x2C3139))
    static let borderStrong = pdAdaptive(pdColor(0xD2D8E0), pdColor(0x3D444F))

    // Exactly three text roles.
    static let textPrimary = pdAdaptive(pdColor(0x1A1E25), pdColor(0xE7EAEF))
    static let textSecondary = pdAdaptive(pdColor(0x4A5260), pdColor(0xA9B1BD))
    static let textMuted = pdAdaptive(pdColor(0x6D7582), pdColor(0x79818D))

    // The single accent: selection and the primary action. 4.9:1 on light surfaces.
    static let accent = pdAdaptive(pdColor(0x2563EB), pdColor(0x6E9BFF))

    // Semantic colors for meaning only.
    static let green = pdAdaptive(pdColor(0x1C7A4B), pdColor(0x58C58D))
    static let amber = pdAdaptive(pdColor(0x8F6200), pdColor(0xD9A64A))
    static let red = pdAdaptive(pdColor(0xBE3529), pdColor(0xF07A70))
    static let blue = pdAdaptive(pdColor(0x2F62B8), pdColor(0x7FA8F0))

    // Restrained syntax tint for the body viewer: two hues, keys and strings.
    static let syntaxKey = pdAdaptive(pdColor(0x3F5BA9), pdColor(0x9DB4FF))
    static let syntaxString = pdAdaptive(pdColor(0x2E6B4F), pdColor(0x86C6A0))
}

// MARK: - Formatting

enum PDFormat {
    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Grouped integer, e.g. 1,204.
    static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Byte count on the 1024 scale, e.g. 834 B / 1.2 KB / 2.10 MB.
    static func bytes(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB"]
        var scaled = Double(value)
        var unit = 0
        while scaled >= 1024 && unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        if unit == 0 { return "\(value) B" }
        if scaled >= 100 { return String(format: "%.0f %@", scaled, units[unit]) }
        if scaled >= 10 { return String(format: "%.1f %@", scaled, units[unit]) }
        return String(format: "%.2f %@", scaled, units[unit])
    }

    /// Compact duration, e.g. 0.4 ms / 128 ms / 1.24 s.
    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval else { return "—" }
        let ms = max(0, interval * 1000)
        if ms < 10 { return String(format: "%.1f ms", ms) }
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        if interval < 10 { return String(format: "%.2f s", interval) }
        if interval < 60 { return String(format: "%.1f s", interval) }
        return String(format: "%.0f s", interval)
    }

    static func clockTime(_ date: Date) -> String { clockFormatter.string(from: date) }

}

// MARK: - Status helpers

enum PDStatus {
    static func color(forCode code: Int?) -> Color {
        guard let code else { return DSColor.textMuted }
        switch code {
        case 100..<200: return DSColor.blue
        case 200..<300: return DSColor.green
        case 300..<400: return DSColor.blue
        case 400..<500: return DSColor.amber
        default: return DSColor.red
        }
    }

    static func color(for request: CapturedRequest) -> Color {
        switch request.state {
        case .failed: return DSColor.red
        case .pending: return DSColor.textMuted
        case .tunneled: return DSColor.textMuted
        case .completed: return color(forCode: request.statusCode)
        }
    }

    /// Label used in the traffic list status column.
    static func compactLabel(for request: CapturedRequest) -> String {
        if request.state == .failed { return String(localized: "Error") }
        if request.state == .pending { return "…" }
        if request.state == .tunneled { return String(localized: "Tunnel") }
        return request.statusCode.map(String.init) ?? "—"
    }

    private static let reasons: [Int: String] = [
        101: "Switching Protocols",
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
        206: "Partial Content", 301: "Moved Permanently", 302: "Found",
        304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict",
        410: "Gone", 422: "Unprocessable Entity", 429: "Too Many Requests",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
        503: "Service Unavailable", 504: "Gateway Timeout",
    ]

    static func reason(_ code: Int) -> String? { reasons[code] }

    /// "200 OK" when the reason is known, "418" otherwise.
    static func fullLabel(forCode code: Int) -> String {
        if let reason = reasons[code] { return "\(code) \(reason)" }
        return String(code)
    }

    static func fullLabel(for request: CapturedRequest) -> String {
        switch request.state {
        case .pending:
            return String(localized: "Pending")
        case .failed:
            if let code = request.statusCode {
                return String(format: String(localized: "%lld Failed"), code)
            }
            return String(localized: "Failed")
        case .tunneled:
            return String(localized: "Tunneled")
        case .completed:
            if let code = request.statusCode { return fullLabel(forCode: code) }
            return String(localized: "No response")
        }
    }

    static func stateLabel(for request: CapturedRequest) -> String {
        switch request.state {
        case .pending: return String(localized: "Pending")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .tunneled: return String(localized: "Tunneled")
        }
    }

    /// Quiet per-method tint. Semantic only: safe reads, writes, destructive.
    static func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET", "HEAD": return DSColor.green
        case "POST": return DSColor.blue
        case "PUT", "PATCH": return DSColor.amber
        case "DELETE": return DSColor.red
        default: return DSColor.textSecondary
        }
    }

    static func methodTintBackground(_ method: String) -> Color {
        methodColor(method).opacity(0.10)
    }
}

// MARK: - Pasteboard

@MainActor
enum PDPasteboard {
    @discardableResult
    static func copy(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }
}

// MARK: - Primitives

/// 1px hairline, horizontal by default.
struct PDHairline: View {
    var vertical = false
    var color: Color = DSColor.border

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: vertical ? DS.Metric.separator : nil,
                   height: vertical ? nil : DS.Metric.separator)
    }
}

/// Applies a help tooltip only when there is text, so components with an optional
/// tooltip never show an empty bubble on hover.
private struct OptionalHelpModifier: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

extension View {
    func helpIfPresent(_ text: String?) -> some View {
        modifier(OptionalHelpModifier(text: text))
    }
}

/// Icon-only button used for all common actions. Quiet hover, help tooltip,
/// accessible label, 26pt hit target, SF Symbol at 12.5pt.
struct PDIconButton: View {
    enum Role {
        case normal
        case accent
        case warning
        case danger
    }

    let symbol: String
    let help: String
    var role: Role = .normal
    var isOn = false
    var size: CGFloat = DS.Metric.iconButtonSize
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var tint: Color {
        switch role {
        case .normal: return isOn ? DSColor.textPrimary : DSColor.textSecondary
        case .accent: return DSColor.accent
        case .warning: return DSColor.amber
        case .danger: return DSColor.red
        }
    }

    var body: some View {
        Button {
            PDCursorTooltip.shared.hide()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isEnabled ? tint : DSColor.textMuted.opacity(0.55))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(isHovering && isEnabled ? DSColor.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .fastTooltip(help)
        .accessibilityLabel(help)
    }
}

/// Gear that opens the Settings scene (SettingsLink keeps the native Settings menu in sync).
struct PDSettingsIconButton: View {
    var size: CGFloat = DS.Metric.iconButtonSize
    @State private var isHovering = false

    var body: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(isHovering ? DSColor.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .fastTooltip(String(localized: "Settings"))
        .accessibilityLabel("Settings")
    }
}

/// Small section overline (sentence case, no subtitle semantics).
struct PDSectionLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: DS.Space.x1 + 2) {
            Text(title)
                .font(DS.Typography.ui(11.5, .semibold))
                .foregroundStyle(DSColor.textSecondary)
            if let detail {
                Text(detail)
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }
}

/// Custom segmented control: sunken track, raised selected segment + hairline.
struct PDSegmented<Option: Hashable>: View {
    struct Item {
        let value: Option
        let label: String
    }

    let items: [Item]
    @Binding var selection: Option
    var help: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Text(item.label)
                        .font(DS.Typography.ui(11.5, selected ? .medium : .regular))
                        .foregroundStyle(selected ? DSColor.textPrimary : DSColor.textSecondary)
                        .padding(.horizontal, DS.Space.x2 + 2)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.xs + 1, style: .continuous)
                                .fill(selected ? DSColor.raised : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.xs + 1, style: .continuous)
                                .strokeBorder(selected ? DSColor.border : Color.clear, lineWidth: DS.Metric.separator)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DSColor.sunken)
        )
        .help(help ?? "")
    }
}

/// 6pt status dot. Pulses only while traffic is being captured — the one animated
/// detail in the window.
struct PDLiveDot: View {
    var active: Bool
    var color: Color = DSColor.green
    var idleColor: Color = DSColor.textMuted
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(active ? color : idleColor)
            .frame(width: 6, height: 6)
            .opacity(active ? (pulsing ? 0.35 : 1) : 0.8)
            .animation(
                active ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .none,
                value: pulsing
            )
            .onAppear { pulsing = active }
            .onChange(of: active) { _, isActive in pulsing = isActive }
            .accessibilityHidden(true)
    }
}

/// Static state dot used in quieter locations.
struct PDStatusDot: View {
    var color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .accessibilityHidden(true)
    }
}

/// Search field: sunken well, magnifier, inline clear button, accent hairline while
/// focused. The field itself is the only place a focus ring appears.
struct PDSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var placeholder = String(localized: "Search")
    var width: CGFloat = 200

    private var focused: Bool { isFocused.wrappedValue }

    var body: some View {
        HStack(spacing: DS.Space.x1 + 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(focused ? DSColor.textSecondary : DSColor.textMuted)

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(DS.Typography.ui(12))
                .foregroundStyle(DSColor.textPrimary)
                .focused(isFocused)
                .overlay(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(DS.Typography.ui(12))
                            .foregroundStyle(DSColor.textMuted)
                            .allowsHitTesting(false)
                    }
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.x2)
        .frame(width: width, height: DS.Metric.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DSColor.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .strokeBorder(
                    focused ? DSColor.accent.opacity(0.85) : DSColor.border,
                    lineWidth: focused ? 1 : DS.Metric.separator
                )
        )
        .onTapGesture { isFocused.wrappedValue = true }
        .accessibilityLabel(placeholder)
    }
}

/// Compact method chip: tinted text on a very quiet tinted surface.
struct MethodBadge: View {
    let method: String

    var body: some View {
        Text(method.uppercased())
            .font(DS.Typography.mono(10, .semibold))
            .foregroundStyle(PDStatus.methodColor(method))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, DS.Space.x1)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                    .fill(PDStatus.methodTintBackground(method))
            )
    }
}

/// Quiet property chip (e.g. "Decrypted") for the inspector overview.
struct PDPropertyBadge: View {
    let text: String
    let symbol: String?
    var tint: Color = DSColor.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .medium))
            }
            Text(text)
                .font(DS.Typography.ui(10.5, .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, DS.Space.x1 + 2)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: DS.Metric.separator)
        )
    }
}

/// Empty body / empty selection placeholder.
struct PDPlaceholder: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: DS.Space.x2) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(DSColor.textMuted)
            Text(title)
                .font(DS.Typography.ui(12.5, .medium))
                .foregroundStyle(DSColor.textSecondary)
            if let detail {
                Text(detail)
                    .font(DS.Typography.mono(11))
                    .foregroundStyle(DSColor.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.x6)
    }
}

// MARK: - Row hover helper

extension View {
    /// Conditional text selection (the two TextSelectability types cannot be used
    /// in a ternary).
    @ViewBuilder
    func pdSelectable(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}
