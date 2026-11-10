import AppKit
import SwiftUI

// MARK: - Shared inspector pieces

enum BodySide: String, CaseIterable, Hashable {
    case request
    case response

    var label: String {
        switch self {
        case .request: return String(localized: "Request")
        case .response: return String(localized: "Response")
        }
    }
}

/// Label + value row used by the overview tab. Labels sit in a fixed column so the
/// values line up like a technical readout.
struct DetailFieldRow: View {
    let label: String
    let value: String
    var mono = true
    var color: Color = DSColor.textPrimary
    var lineLimit: Int? = 2
    var selectable = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.x3) {
            Text(label)
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(mono ? DS.Typography.mono(11.5) : DS.Typography.ui(12))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .pdSelectable(selectable)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 20)
    }
}

// MARK: - Headers

/// One card of header rows. Clicking a row copies "Name: Value".
struct HeadersSectionView: View {
    let title: String
    let headers: [HeaderField]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            PDSectionLabel(title: title, detail: "\(headers.count)")

            if headers.isEmpty {
                Text("No headers")
                    .font(DS.Typography.ui(11.5))
                    .foregroundStyle(DSColor.textMuted)
                    .padding(.horizontal, DS.Space.x2)
                    .frame(height: 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(headers) { header in
                        HeaderRowView(header: header)
                    }
                }
                .background(DSColor.raised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .strokeBorder(DSColor.border, lineWidth: DS.Metric.separator)
                )
            }
        }
    }
}

private struct HeaderRowView: View {
    let header: HeaderField

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        Button {
            PDPasteboard.copy(header.name + ": " + header.value)
            didCopy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                didCopy = false
            }
        } label: {
            HStack(spacing: DS.Space.x3) {
                Text(header.name)
                    .font(DS.Typography.mono(11.5, .medium))
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 156, alignment: .leading)
                    .help(header.name)

                Text(header.value)
                    .font(DS.Typography.mono(11.5))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(header.value)

                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(didCopy ? DSColor.green : DSColor.textMuted)
                    .opacity(didCopy || isHovering ? 1 : 0)
                    .frame(width: 14)
            }
            .padding(.horizontal, DS.Space.x3)
            .frame(height: 24)
            .background(isHovering ? DSColor.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Copy header")
        .accessibilityLabel(header.name + ": " + header.value)
    }
}

// MARK: - Body tab

/// Body tab: request body and response body as two stacked sections. Both are
/// always present; an empty side collapses to a compact row so the populated side
/// keeps the room.
struct BodyTabView: View {
    let request: CapturedRequest

    var body: some View {
        VStack(spacing: 0) {
            BodySectionView(request: request, side: .request)
            PDHairline()
            BodySectionView(request: request, side: .response)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DSColor.base)
    }
}

private struct BodySectionView: View {
    let request: CapturedRequest
    let side: BodySide

    static let displayLimit = 512 * 1024

    @State private var showsRaw = false
    @State private var didCopy = false

    private var data: Data? {
        side == .request ? request.requestBody : request.responseBody
    }

    private var hasBody: Bool {
        guard let data else { return false }
        return !data.isEmpty
    }

    private var contentType: String? {
        side == .request ? request.requestContentType : request.responseContentType
    }

    private var contentKind: ContentKind {
        ContentKind.infer(mimeType: contentType, pathOrURL: request.path)
    }

    private var isJSON: Bool { contentKind == .json }

    private var title: String {
        side == .request
            ? String(localized: "Request body")
            : String(localized: "Response body")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PDHairline()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: hasBody ? .infinity : nil, alignment: .top)
        .background(hasBody ? DSColor.raised : DSColor.base)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.x2) {
            Text(title)
                .font(DS.Typography.ui(11.5, .semibold))
                .foregroundStyle(DSColor.textSecondary)

            if let data {
                Text(PDFormat.bytes(data.count))
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
            }

            Spacer(minLength: DS.Space.x2)

            if isJSON && hasBody {
                PDSegmented(
                    items: [
                        .init(value: false, label: String(localized: "Pretty")),
                        .init(value: true, label: String(localized: "Raw")),
                    ],
                    selection: $showsRaw
                )
            }

            PDIconButton(
                symbol: didCopy ? "checkmark" : "doc.on.doc",
                help: didCopy ? String(localized: "Copied") : String(localized: "Copy body")
            ) {
                copyBody()
            }
            .disabled(!hasBody)

            PDIconButton(
                symbol: "square.and.arrow.down",
                help: String(localized: "Save body")
            ) {
                saveBody()
            }
            .disabled(!hasBody)
        }
        .padding(.horizontal, DS.Space.x4)
        .frame(height: 36)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let data, !data.isEmpty {
            VStack(spacing: 0) {
                noticeBar(for: data)
                viewer(for: data)
            }
        } else {
            emptyRow
        }
    }

    private var emptyRow: some View {
        HStack(spacing: DS.Space.x2) {
            Image(systemName: emptySymbol)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(DSColor.textMuted)
            Text(emptyTitle)
                .font(DS.Typography.ui(11.5))
                .foregroundStyle(DSColor.textMuted)
            if let emptyDetail {
                Text(emptyDetail)
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.x4)
        .frame(height: 46)
    }

    private var emptySymbol: String {
        if side == .request { return "arrow.up.doc" }
        if request.state == .pending { return "hourglass" }
        if request.state == .failed { return "exclamationmark.triangle" }
        return "arrow.down.doc"
    }

    private var emptyTitle: String {
        if side == .request { return String(localized: "No request body") }
        if request.state == .pending { return String(localized: "Waiting for response") }
        return String(localized: "No response body")
    }

    private var emptyDetail: String? {
        guard side == .response, request.state == .failed else { return nil }
        return request.errorMessage
    }

    @ViewBuilder
    private func noticeBar(for data: Data) -> some View {
        let truncatedAtLimit = data.count >= AppDefaults.maxBodyBytes
        let displayTruncated = data.count > Self.displayLimit

        if truncatedAtLimit || displayTruncated {
            VStack(spacing: 0) {
                if truncatedAtLimit {
                    noticeRow(String(localized: "Body captured up to the 2 MB limit"))
                }
                if displayTruncated {
                    noticeRow(String(
                        format: String(localized: "Showing the first 512 KB of %@"),
                        PDFormat.bytes(data.count)
                    ))
                }
                PDHairline()
            }
            .background(DSColor.sunken)
        }
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: DS.Space.x1 + 2) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(DS.Typography.ui(10.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(DSColor.textMuted)
        .padding(.horizontal, DS.Space.x3)
        .frame(height: 22)
    }

    @ViewBuilder
    private func viewer(for data: Data) -> some View {
        switch contentKind {
        case .json:
            jsonViewer(data)
        case .image:
            if NSImage(data: data) != nil {
                ImageBodyView(data: data, contentType: contentType)
            } else {
                HexDumpView(data: data)
            }
        case .javascript, .html, .xml, .css, .text, .form:
            MonoTextBodyView(text: displayText(from: data))
        case .font, .audio, .video, .binary:
            HexDumpView(data: data)
        }
    }

    @ViewBuilder
    private func jsonViewer(_ data: Data) -> some View {
        if showsRaw || data.count > Self.displayLimit {
            MonoTextBodyView(text: displayText(from: data))
        } else if let value = JSONValue.parse(data) {
            JSONTreeView(value: value)
                .id("\(request.id)-\(side.rawValue)-json")
        } else {
            MonoTextBodyView(text: displayText(from: data))
        }
    }

    private func displayText(from data: Data) -> String {
        let limited = data.count > Self.displayLimit ? data.prefix(Self.displayLimit) : data
        if let text = String(data: limited, encoding: .utf8) {
            return text
        }
        return String(decoding: limited, as: UTF8.self)
    }

    // MARK: Actions

    private func copyBody() {
        guard let data else { return }
        if let text = String(data: data.prefix(Self.displayLimit), encoding: .utf8) {
            PDPasteboard.copy(text)
        } else {
            PDPasteboard.copy(data.base64EncodedString())
        }
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopy = false
        }
    }

    private func saveBody() {
        guard let data else { return }
        PDBodySaver.presentSavePanel(
            request: request,
            side: side,
            data: data,
            contentType: contentType
        )
    }
}

// MARK: - Body renderings

/// Monospaced, selectable text with quiet padding.
struct MonoTextBodyView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(DS.Typography.mono(11.5))
                .foregroundStyle(DSColor.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.x3)
        }
    }
}

/// Image preview with a mono caption (format, pixel size, byte size).
struct ImageBodyView: View {
    let data: Data
    let contentType: String?

    private var image: NSImage? { NSImage(data: data) }

    private var caption: String {
        var parts: [String] = []
        if let contentType {
            parts.append(contentType)
        }
        if let representation = image?.representations.first, representation.pixelsWide > 0 {
            parts.append("\(representation.pixelsWide) × \(representation.pixelsHigh)")
        }
        parts.append(PDFormat.bytes(data.count))
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.x3) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 520)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .strokeBorder(DSColor.border, lineWidth: DS.Metric.separator)
                        )
                }
                Text(caption)
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
            }
            .padding(DS.Space.x4)
        }
    }
}

/// Hex + ASCII dump for binary payloads.
struct HexDumpView: View {
    let data: Data

    private let limit = 4096

    private var lines: [String] {
        let bytes = [UInt8](data.prefix(limit))
        var result: [String] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            let chunk = bytes[offset..<end]
            var hex = ""
            for (index, byte) in chunk.enumerated() {
                if index == 8 { hex += " " }
                hex += String(format: "%02x ", byte)
            }
            hex = hex.padding(toLength: 50, withPad: " ", startingAt: 0)
            let ascii = chunk.map { byte -> String in
                (32...126).contains(byte) ? String(UnicodeScalar(byte)) : "."
            }.joined()
            result.append(String(format: "%08x  ", offset) + hex + " " + ascii)
            offset += 16
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(DS.Typography.mono(10.5))
                        .foregroundStyle(DSColor.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if data.count > limit {
                    Text(String(
                        format: String(localized: "Showing the first 4 KB of %@"),
                        PDFormat.bytes(data.count)
                    ))
                        .font(DS.Typography.ui(10.5))
                        .foregroundStyle(DSColor.textMuted)
                        .padding(.top, DS.Space.x2)
                }
            }
            .padding(DS.Space.x3)
        }
    }
}

// MARK: - JSON tree

/// One row of the flattened, collapsible JSON tree.
struct JSONRow: Identifiable {
    enum Kind {
        case container(key: String?, isIndex: Bool, open: String, countLabel: String, isExpanded: Bool)
        case leaf(key: String?, isIndex: Bool, display: String, tone: Tone)
        case emptyContainer(key: String?, isIndex: Bool, text: String)
        case closing(text: String)
    }

    enum Tone {
        case string
        case number
        case bool
        case null
    }

    let id: String
    let depth: Int
    let kind: Kind

    var isContainer: Bool {
        if case .container = kind { return true }
        return false
    }

    var path: String { id }

    /// Expand the root and the first level of containers so the tree opens with
    /// structure visible without flooding the pane.
    static func defaultExpandedPaths(_ value: JSONValue) -> Set<String> {
        var paths: Set<String> = []
        func walk(_ value: JSONValue, path: String, depth: Int) {
            switch value {
            case .object(let dictionary):
                if depth <= 1 { paths.insert(path) }
                for (key, child) in dictionary {
                    walk(child, path: path + "." + key, depth: depth + 1)
                }
            case .array(let array):
                if depth <= 1 { paths.insert(path) }
                for (index, child) in array.enumerated() {
                    walk(child, path: path + "[\(index)]", depth: depth + 1)
                }
            default:
                break
            }
        }
        walk(value, path: "$", depth: 0)
        return paths
    }

    static func flatten(_ value: JSONValue, expanded: Set<String>) -> [JSONRow] {
        var rows: [JSONRow] = []

        func walk(_ value: JSONValue, key: String?, isIndex: Bool, path: String, depth: Int) {
            switch value {
            case .object(let dictionary):
                let keys = dictionary.keys.sorted()
                if keys.isEmpty {
                    rows.append(JSONRow(id: path, depth: depth, kind: .emptyContainer(key: key, isIndex: isIndex, text: "{}")))
                    return
                }
                let isExpanded = expanded.contains(path)
                rows.append(JSONRow(
                    id: path,
                    depth: depth,
                    kind: .container(
                        key: key,
                        isIndex: isIndex,
                        open: "{",
                        countLabel: containerCountLabel(keys.count, isArray: false),
                        isExpanded: isExpanded
                    )
                ))
                if isExpanded {
                    for childKey in keys {
                        guard let child = dictionary[childKey] else { continue }
                        walk(child, key: childKey, isIndex: false, path: path + "." + childKey, depth: depth + 1)
                    }
                    rows.append(JSONRow(id: path + "\u{0}close", depth: depth, kind: .closing(text: "}")))
                }
            case .array(let array):
                if array.isEmpty {
                    rows.append(JSONRow(id: path, depth: depth, kind: .emptyContainer(key: key, isIndex: isIndex, text: "[]")))
                    return
                }
                let isExpanded = expanded.contains(path)
                rows.append(JSONRow(
                    id: path,
                    depth: depth,
                    kind: .container(
                        key: key,
                        isIndex: isIndex,
                        open: "[",
                        countLabel: containerCountLabel(array.count, isArray: true),
                        isExpanded: isExpanded
                    )
                ))
                if isExpanded {
                    for (index, child) in array.enumerated() {
                        walk(child, key: "\(index)", isIndex: true, path: path + "[\(index)]", depth: depth + 1)
                    }
                    rows.append(JSONRow(id: path + "\u{0}close", depth: depth, kind: .closing(text: "]")))
                }
            case .string(let string):
                rows.append(JSONRow(id: path, depth: depth, kind: .leaf(key: key, isIndex: isIndex, display: "\"\(string)\"", tone: .string)))
            case .number(let number):
                rows.append(JSONRow(id: path, depth: depth, kind: .leaf(key: key, isIndex: isIndex, display: number, tone: .number)))
            case .bool(let boolean):
                rows.append(JSONRow(id: path, depth: depth, kind: .leaf(key: key, isIndex: isIndex, display: boolean ? "true" : "false", tone: .bool)))
            case .null:
                rows.append(JSONRow(id: path, depth: depth, kind: .leaf(key: key, isIndex: isIndex, display: "null", tone: .null)))
            }
        }

        walk(value, key: nil, isIndex: false, path: "$", depth: 0)
        return rows
    }

    /// "3 keys" / "3 items", plural-aware and localized at flatten time.
    private static func containerCountLabel(_ count: Int, isArray: Bool) -> String {
        let template: String
        if isArray {
            template = count == 1 ? "%lld item" : "%lld items"
        } else {
            template = count == 1 ? "%lld key" : "%lld keys"
        }
        return String(format: String(localized: String.LocalizationValue(template)), count)
    }
}

/// Recursive JSON value used by the tree.
enum JSONValue {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func parse(_ data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONValue(object)
    }

    init(_ any: Any) {
        switch any {
        case let dictionary as [String: Any]:
            var mapped: [String: JSONValue] = [:]
            for (key, value) in dictionary {
                mapped[key] = JSONValue(value)
            }
            self = .object(mapped)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init))
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.stringValue)
            }
        default:
            self = .null
        }
    }
}

/// Collapsible JSON tree with a restrained two-hue syntax tint.
struct JSONTreeView: View {
    let value: JSONValue

    @State private var expanded: Set<String> = []
    @State private var didInitialize = false

    private var rows: [JSONRow] { JSONRow.flatten(value, expanded: expanded) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    JSONRowView(row: row) {
                        if expanded.contains(row.id) {
                            expanded.remove(row.id)
                        } else {
                            expanded.insert(row.id)
                        }
                    }
                }
            }
            .padding(.vertical, DS.Space.x2)
            .padding(.horizontal, DS.Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            expanded = JSONRow.defaultExpandedPaths(value)
        }
    }
}

private struct JSONRowView: View {
    let row: JSONRow
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Color.clear
                .frame(width: CGFloat(row.depth) * 14)

            if row.isContainer {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(DSColor.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? String(localized: "Collapse") : String(localized: "Expand"))
                .accessibilityLabel(
                    expanded ? String(localized: "Collapse") : String(localized: "Expand")
                )
            } else {
                Color.clear.frame(width: 14, height: 16)
            }

            content
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isContainer { onToggle() }
        }
    }

    private var expanded: Bool {
        if case .container(_, _, _, _, let isExpanded) = row.kind { return isExpanded }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case let .container(key, isIndex, open, countLabel, isExpanded):
            keyText(key, isIndex: isIndex)
            Text(open + (isExpanded ? " " : "…  "))
                .font(DS.Typography.mono(11.5))
                .foregroundStyle(DSColor.textMuted)
            if !isExpanded {
                Text(countLabel)
                    .font(DS.Typography.ui(10))
                    .foregroundStyle(DSColor.textMuted)
            }
        case let .leaf(key, isIndex, display, tone):
            keyText(key, isIndex: isIndex)
            Text(display)
                .font(DS.Typography.mono(11.5))
                .foregroundStyle(tint(for: tone))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(display)
        case let .emptyContainer(key, isIndex, text):
            keyText(key, isIndex: isIndex)
            Text(text)
                .font(DS.Typography.mono(11.5))
                .foregroundStyle(DSColor.textMuted)
        case .closing(let text):
            Text(text)
                .font(DS.Typography.mono(11.5))
                .foregroundStyle(DSColor.textMuted)
        }
    }

    @ViewBuilder
    private func keyText(_ key: String?, isIndex: Bool) -> some View {
        if let key {
            Text(key)
                .font(DS.Typography.mono(11.5))
                .foregroundStyle(isIndex ? DSColor.textMuted : DSColor.syntaxKey)
                .lineLimit(1)
            Text(": ")
                .font(DS.Typography.mono(11.5))
                .foregroundStyle(DSColor.textMuted)
        }
    }

    private func tint(for tone: JSONRow.Tone) -> Color {
        switch tone {
        case .string: return DSColor.syntaxString
        case .number: return DSColor.textPrimary
        case .bool: return DSColor.textPrimary
        case .null: return DSColor.textMuted
        }
    }
}

// MARK: - Saving

@MainActor
enum PDBodySaver {
    static func presentSavePanel(request: CapturedRequest, side: BodySide, data: Data, contentType: String?) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename(for: request, side: side, contentType: contentType)
        panel.title = String(localized: "Save body")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private static func suggestedFilename(for request: CapturedRequest, side: BodySide, contentType: String?) -> String {
        let path = request.path.split(separator: "?").first.map(String.init) ?? ""
        var base = (path as NSString).lastPathComponent
        if base.isEmpty || base == "/" {
            base = side == .request ? "request" : "response"
        }
        if (base as NSString).pathExtension.isEmpty {
            base += "." + fileExtension(for: contentType, fallback: request.contentKind)
        }
        return base
    }

    private static func fileExtension(for contentType: String?, fallback: ContentKind) -> String {
        let type = contentType?.lowercased() ?? ""
        if type.contains("json") { return "json" }
        if type.contains("html") { return "html" }
        if type.contains("xml") { return "xml" }
        if type.contains("javascript") { return "js" }
        if type.contains("css") { return "css" }
        if type.contains("svg") { return "svg" }
        if type.contains("png") { return "png" }
        if type.contains("jpeg") || type.contains("jpg") { return "jpg" }
        if type.contains("gif") { return "gif" }
        if type.contains("webp") { return "webp" }
        if type.contains("pdf") { return "pdf" }
        if type.hasPrefix("text/") { return "txt" }
        switch fallback {
        case .json: return "json"
        case .html: return "html"
        case .xml: return "xml"
        case .javascript: return "js"
        case .css: return "css"
        case .image: return "png"
        case .font, .audio, .video, .binary, .text, .form: return "bin"
        }
    }
}
