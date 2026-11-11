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
                Image(systemName: part.filename == nil ? "text.cursor" : "doc")
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
                PDIconButton(
                    symbol: "square.and.arrow.down",
                    help: String(localized: "Save file")
                ) {
                    save(part)
                }
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
        } else if let text = readableText(part.data) {
            MonoTextBodyView(text: text)
                .frame(height: 120)
                .background(DSColor.raised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
        } else {
            Text(String(format: String(localized: "Binary content (%@)"), PDFormat.bytes(part.data.count)))
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textMuted)
        }
    }

    private func readableText(_ data: Data) -> String? {
        guard data.count <= 256 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let control = text.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }.count
        guard control * 20 < max(1, text.unicodeScalars.count) else { return nil }
        return text
    }

    private func save(_ part: MultipartFormData.Part) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = part.filename?.isEmpty == false ? part.filename! : part.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? part.data.write(to: url)
    }
}
