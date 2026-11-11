import AppKit
import SwiftUI

/// Renders a multipart/form-data body as a list of fields and files, with inline image
/// previews and a save button for file parts.
struct MultipartFormView: View {
    let parts: [MultipartFormData.Part]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.x3) {
                ForEach(parts) { part in
                    partView(part)
                }
            }
            .padding(DS.Space.x4)
        }
    }

    private func partView(_ part: MultipartFormData.Part) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                Image(systemName: part.filename == nil ? "text.alignleft" : "doc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DSColor.textMuted)
                Text(part.name)
                    .font(DS.Typography.ui(12, .semibold))
                    .foregroundStyle(DSColor.textPrimary)
                if let filename = part.filename, !filename.isEmpty {
                    Text(filename)
                        .font(DS.Typography.mono(10.5))
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DS.Space.x2)
                Text(PDFormat.bytes(part.data.count))
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
            }

            if let contentType = part.contentType, !contentType.isEmpty {
                Text(contentType)
                    .font(DS.Typography.mono(10))
                    .foregroundStyle(DSColor.textMuted)
            }

            preview(part)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Space.x3)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DSColor.base)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .strokeBorder(DSColor.border, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func preview(_ part: MultipartFormData.Part) -> some View {
        if part.isImage, let image = NSImage(data: part.data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .white))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
        } else if let value = jsonValue(part) {
            JSONTreeView(value: value)
                .frame(height: 180)
                .background(DSColor.raised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
        } else if let text = readableText(part.data) {
            if text.count <= 20_000 {
                Text(text)
                    .font(DS.Typography.mono(11.5))
                    .foregroundStyle(DSColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.x2)
                    .background(DSColor.raised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
            } else {
                MonoTextBodyView(text: text)
                    .frame(height: 220)
                    .background(DSColor.raised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
            }
        } else {
            Text(String(format: String(localized: "Binary content (%@)"), PDFormat.bytes(part.data.count)))
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textMuted)
        }
    }

    private func jsonValue(_ part: MultipartFormData.Part) -> JSONValue? {
        let mime = part.contentType?.lowercased() ?? ""
        let extensionName = part.filename.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        guard mime.contains("json") || extensionName == "json" else { return nil }
        return JSONValue.parse(part.data)
    }

    private func readableText(_ data: Data) -> String? {
        guard data.count <= 256 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let control = text.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }.count
        guard control * 20 < max(1, text.unicodeScalars.count) else { return nil }
        return text
    }
}
