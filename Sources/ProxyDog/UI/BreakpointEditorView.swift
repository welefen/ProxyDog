import AppKit
import SwiftUI

// MARK: - Breakpoint editor

/// Sheet shown while the engine is paused on a breakpoint. The exchange stays blocked
/// until the user drops it or resumes it (optionally with an edited body), so the sheet
/// cannot be dismissed without one of those decisions.
struct BreakpointEditorView: View {
    @EnvironmentObject private var state: AppState

    let payload: BreakpointPayload

    @State private var bodyText: String

    init(payload: BreakpointPayload) {
        self.payload = payload
        _bodyText = State(initialValue: payload.bodyText)
    }

    private var waitingCount: Int {
        max(0, state.pendingBreakpoints.count - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PDHairline()
            bodySection
            PDHairline()
            footer
        }
        .frame(width: 640, height: 560)
        .background(DSColor.base)
        .interactiveDismissDisabled(true)
        .onChange(of: payload.id) { _, _ in
            bodyText = payload.bodyText
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2 + 2) {
            HStack(spacing: DS.Space.x2) {
                Text("Breakpoint")
                    .font(DS.Typography.ui(14, .semibold))
                    .foregroundStyle(DSColor.textPrimary)

                PDPropertyBadge(
                    text: payload.phase.label,
                    symbol: payload.phase == .request ? "arrow.up.right" : "arrow.down.left",
                    tint: payload.phase == .request ? DSColor.blue : DSColor.green
                )

                Text(payload.ruleName)
                    .font(DS.Typography.ui(11.5))
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DS.Space.x2)
            }

            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x2) {
                MethodBadge(method: payload.method)

                Text(payload.url)
                    .font(DS.Typography.mono(12))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(payload.url)

                Spacer(minLength: DS.Space.x2)

                if let statusCode = payload.statusCode {
                    Text(PDStatus.fullLabel(forCode: statusCode))
                        .font(DS.Typography.mono(11.5, .semibold))
                        .foregroundStyle(PDStatus.color(forCode: statusCode))
                        .monospacedDigit()
                }
            }

            if let contentType = payload.contentType, !contentType.isEmpty {
                Text(contentType)
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, DS.Space.x4)
        .padding(.top, DS.Space.x4)
        .padding(.bottom, DS.Space.x3)
    }

    // MARK: Body

    private var bodySection: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.x2) {
                Text("Body")
                    .font(DS.Typography.ui(11.5, .semibold))
                    .foregroundStyle(DSColor.textSecondary)
                if payload.bodyText.isEmpty {
                    Text("No body")
                        .font(DS.Typography.ui(10.5))
                        .foregroundStyle(DSColor.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.x4)
            .frame(height: 32)
            .background(DSColor.base)

            BreakpointBodyEditor(text: $bodyText)
                .background(DSColor.raised)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.Space.x3) {
            if waitingCount > 0 {
                Text(String(format: String(localized: "%lld more waiting"), waitingCount))
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
            }

            Spacer(minLength: DS.Space.x2)

            Button(action: drop) {
                Text("Drop")
                    .font(DS.Typography.ui(12, .medium))
                    .foregroundStyle(DSColor.red)
                    .padding(.horizontal, DS.Space.x3)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(DSColor.red.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .strokeBorder(DSColor.red.opacity(0.22), lineWidth: DS.Metric.separator)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Drop")
            .accessibilityLabel("Drop")

            Button(action: resume) {
                Text("Resume")
                    .font(DS.Typography.ui(12, .semibold))
                    .foregroundStyle(DSColor.base)
                    .padding(.horizontal, DS.Space.x4)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(DSColor.accent)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .help("Resume")
            .accessibilityLabel("Resume")
        }
        .padding(.horizontal, DS.Space.x4)
        .frame(height: 56)
    }

    // MARK: Actions

    private func resume() {
        state.resolveBreakpoint(id: payload.id, decision: .resume(body: bodyText))
        removeDevPayloadIfNeeded()
    }

    private func drop() {
        state.resolveBreakpoint(id: payload.id, decision: .drop)
        removeDevPayloadIfNeeded()
    }

    /// Dev-only samples are not registered with the engine's gate, so clear them here to
    /// keep the sheet usable in QA runs. Real payloads are removed by the engine callback.
    private func removeDevPayloadIfNeeded() {
        guard DevLaunchOptions.sampleBreakpointMode != nil else { return }
        state.pendingBreakpoints.removeAll { $0.id == payload.id }
    }
}

// MARK: - Editable body

/// Monospaced NSTextView editor so breakpoint bodies stay responsive even when large.
private struct BreakpointBodyEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byCharWrapping
        }
        textView.delegate = context.coordinator
        textView.string = text
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
        textView.textColor = .labelColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BreakpointBodyEditor

        init(_ parent: BreakpointBodyEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
