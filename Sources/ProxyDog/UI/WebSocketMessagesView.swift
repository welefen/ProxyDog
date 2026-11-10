import AppKit
import SwiftUI

// MARK: - WebSocket messages tab

/// Messages tab for a decrypted WebSocket exchange: a live message list on top and
/// a resizable payload inspector at the bottom.
struct WebSocketMessagesTabView: View {
    let request: CapturedRequest

    @State private var selectedMessageID: WebSocketMessage.ID?
    @State private var payloadHeight: CGFloat = 240
    @State private var isAtBottom = true
    @State private var showsPretty = true
    @State private var didInitialize = false
    @State private var copiedMessageID: WebSocketMessage.ID?

    private var messages: [WebSocketMessage] { request.webSocketMessages }

    private var selectedMessage: WebSocketMessage? {
        guard let selectedMessageID else { return nil }
        return messages.first { $0.id == selectedMessageID }
    }

    private var isConnected: Bool {
        request.finishedAt == nil && request.state != .failed
    }

    private var connectionDuration: TimeInterval {
        if let finishedAt = request.finishedAt {
            return max(0, finishedAt.timeIntervalSince(request.startedAt))
        }
        return max(0, Date().timeIntervalSince(request.startedAt))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                PDHairline()

                if messages.isEmpty {
                    PDPlaceholder(
                        symbol: "bubble.left.and.bubble.right",
                        title: String(localized: "No WebSocket messages yet")
                    )
                } else {
                    messageList
                        .frame(maxHeight: .infinity)

                    WebSocketPayloadResizeHandle(
                        value: $payloadHeight,
                        minValue: 120,
                        maxValue: max(160, geometry.size.height - 150)
                    )

                    payloadPane
                        .frame(height: clampedPayloadHeight(maxHeight: geometry.size.height))
                }
            }
        }
        .background(DSColor.base)
        .onAppear { resetSelectionState() }
    }

    private func clampedPayloadHeight(maxHeight: CGFloat) -> CGFloat {
        min(max(payloadHeight, 120), max(160, maxHeight - 150))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.x3) {
            Text(String(format: String(localized: "%lld messages"), messages.count))
                .font(DS.Typography.ui(11.5, .medium))
                .foregroundStyle(DSColor.textSecondary)
                .monospacedDigit()

            Text(PDFormat.duration(connectionDuration))
                .font(DS.Typography.mono(10.5))
                .foregroundStyle(DSColor.textMuted)
                .monospacedDigit()

            if isConnected {
                HStack(spacing: DS.Space.x1) {
                    PDLiveDot(active: true)
                    Text(String(localized: "Connected"))
                        .font(DS.Typography.ui(10.5))
                        .foregroundStyle(DSColor.textMuted)
                }
            }

            if request.intercepted {
                PDPropertyBadge(
                    text: String(localized: "Decrypted"),
                    symbol: "lock.open",
                    tint: DSColor.green
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.x4)
        .frame(height: 36)
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { message in
                            WebSocketMessageRow(
                                message: message,
                                isSelected: message.id == selectedMessageID
                            ) {
                                selectedMessageID = message.id
                            }
                            .id(message.id)
                        }
                    }

                    // Permanent (non-lazy) probe so scroll position stays observable
                    // even when the list is long.
                    WebSocketScrollPositionProbe { atBottom in
                        if isAtBottom != atBottom { isAtBottom = atBottom }
                    }
                    .frame(width: 0, height: 0)
                }
                .padding(.bottom, DS.Space.x2)
            }
            .onAppear { initializeSelection(proxy: proxy) }
            .onChange(of: messages.count) { _, _ in
                // A connection that just opened has no selection yet: adopt the
                // newest message so the payload pane is never empty while streaming.
                if selectedMessageID == nil, let last = messages.last {
                    selectedMessageID = last.id
                }
                if isAtBottom {
                    scrollToLast(proxy: proxy)
                }
            }
        }
    }

    private func initializeSelection(proxy: ScrollViewProxy) {
        guard !didInitialize else { return }
        didInitialize = true
        guard !messages.isEmpty else { return }

        if let index = DevLaunchOptions.sampleMessageIndex, messages.indices.contains(index) {
            selectedMessageID = messages[index].id
            DispatchQueue.main.async {
                proxy.scrollTo(messages[index].id, anchor: .center)
            }
        } else if let last = messages.last {
            selectedMessageID = last.id
            DispatchQueue.main.async {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func scrollToLast(proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    /// Called when the selected request changes so a stale selection is not reused.
    private func resetSelectionState() {
        guard !messageIDsMatchRequest else { return }
        selectedMessageID = nil
        didInitialize = false
    }

    private var messageIDsMatchRequest: Bool {
        guard let selectedMessageID else { return false }
        return messages.contains { $0.id == selectedMessageID }
    }

    // MARK: Payload pane

    @ViewBuilder
    private var payloadPane: some View {
        VStack(spacing: 0) {
            if let message = selectedMessage {
                payloadHeader(message)
                PDHairline()
                payloadContent(message)
            } else {
                PDPlaceholder(
                    symbol: "cursorarrow",
                    title: String(localized: "Select a message")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColor.raised)
    }

    private func payloadHeader(_ message: WebSocketMessage) -> some View {
        HStack(spacing: DS.Space.x2 + 2) {
            Image(systemName: message.kind.symbolName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DSColor.textMuted)

            Text(directionLabel(message.direction))
                .font(DS.Typography.ui(11, .medium))
                .foregroundStyle(DSColor.textSecondary)

            Text(message.kind.label)
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textSecondary)

            Text(PDFormat.clockTime(message.timestamp))
                .font(DS.Typography.mono(10.5))
                .foregroundStyle(DSColor.textMuted)
                .monospacedDigit()

            Text(PDFormat.bytes(message.byteCount))
                .font(DS.Typography.mono(10.5))
                .foregroundStyle(DSColor.textMuted)
                .monospacedDigit()

            if message.truncated {
                PDPropertyBadge(
                    text: String(localized: "Truncated"),
                    symbol: "scissors",
                    tint: DSColor.amber
                )
            }

            Spacer(minLength: DS.Space.x2)

            if isJSON(message), message.kind != .binary {
                PDSegmented(
                    items: [
                        .init(value: false, label: String(localized: "Pretty")),
                        .init(value: true, label: String(localized: "Raw")),
                    ],
                    selection: prettyBinding
                )
            }

            PDIconButton(
                symbol: copiedMessageID == message.id ? "checkmark" : "doc.on.doc",
                help: copiedMessageID == message.id
                    ? String(localized: "Copied")
                    : String(localized: "Copy payload")
            ) {
                copy(message)
            }
        }
        .padding(.horizontal, DS.Space.x4)
        .frame(height: 34)
    }

    /// `showsPretty` is inverted so the segmented control reads "Pretty | Raw".
    private var prettyBinding: Binding<Bool> {
        Binding(
            get: { !showsPretty },
            set: { showsPretty = !$0 }
        )
    }

    @ViewBuilder
    private func payloadContent(_ message: WebSocketMessage) -> some View {
        VStack(spacing: 0) {
            if message.truncated {
                truncationNotice
            }

            switch message.kind {
            case .text:
                textPayload(message)
            case .binary:
                if let data = message.payload, !data.isEmpty {
                    HexDumpView(data: data)
                } else {
                    emptyPayload
                }
            case .ping, .pong, .close:
                controlPayload(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func textPayload(_ message: WebSocketMessage) -> some View {
        if let data = message.payload {
            if showsPretty, let value = JSONValue.parse(data) {
                JSONTreeView(value: value)
                    .id(message.id)
            } else if let text = message.text {
                MonoTextBodyView(text: text)
            } else {
                MonoTextBodyView(text: String(decoding: data, as: UTF8.self))
            }
        } else {
            emptyPayload
        }
    }

    @ViewBuilder
    private func controlPayload(_ message: WebSocketMessage) -> some View {
        ScrollView {
            HStack(spacing: DS.Space.x2) {
                Image(systemName: message.kind.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DSColor.textMuted)
                Text(message.kind.label)
                    .font(DS.Typography.ui(11, .medium))
                    .foregroundStyle(DSColor.textSecondary)
                Text(PDHex.preview(message.payload, maxBytes: 32))
                    .font(DS.Typography.mono(11))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(DS.Space.x3)
        }
    }

    private var emptyPayload: some View {
        PDPlaceholder(symbol: "doc", title: String(localized: "No payload"))
    }

    private var truncationNotice: some View {
        HStack(spacing: DS.Space.x1 + 2) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .medium))
            Text(String(localized: "Payload truncated at the 512 KB capture limit"))
                .font(DS.Typography.ui(10.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(DSColor.amber)
        .padding(.horizontal, DS.Space.x3)
        .frame(height: 22)
        .background(DSColor.sunken)
    }

    // MARK: Actions

    private func copy(_ message: WebSocketMessage) {
        if let text = message.text {
            PDPasteboard.copy(text)
        } else if let data = message.payload, !data.isEmpty {
            PDPasteboard.copy(PDHex.full(data))
        } else {
            PDPasteboard.copy("")
        }
        copiedMessageID = message.id
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedMessageID == message.id { copiedMessageID = nil }
        }
    }

    private func isJSON(_ message: WebSocketMessage) -> Bool {
        guard message.isTextual, let data = message.payload else { return false }
        return JSONValue.parse(data) != nil
    }

    private func directionLabel(_ direction: WebSocketDirection) -> String {
        switch direction {
        case .sent: return String(localized: "Sent")
        case .received: return String(localized: "Received")
        }
    }
}

// MARK: - Message row

private struct WebSocketMessageRow: View {
    let message: WebSocketMessage
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    private var background: Color {
        if isSelected { return DSColor.selection }
        return isHovering ? DSColor.hover : .clear
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Image(systemName: message.direction == .sent ? "arrow.up.right" : "arrow.down.left")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DSColor.textMuted)
                    .frame(width: 18, alignment: .leading)

                Text(message.kind.label)
                    .font(DS.Typography.ui(11))
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                    .frame(width: 56, alignment: .leading)

                Text(PDFormat.clockTime(message.timestamp))
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 88, alignment: .leading)

                Text(PDFormat.bytes(message.byteCount))
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 58, alignment: .trailing)

                Text(PDHex.preview(message.payload, maxBytes: 8, text: message.text))
                    .font(DS.Typography.mono(11))
                    .foregroundStyle(message.isTextual ? DSColor.textPrimary : DSColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, DS.Space.x3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if message.truncated {
                    Image(systemName: "scissors")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(DSColor.amber)
                        .help(String(localized: "Payload truncated at the 512 KB capture limit"))
                }
            }
            .padding(.horizontal, DS.Space.x3)
            .frame(height: 26)
            .background(background)
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(DSColor.accent)
                        .frame(width: 2, height: 14)
                        .padding(.leading, 2)
                }
            }
            .overlay(alignment: .bottom) { PDHairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityLabel: String {
        let direction = message.direction == .sent
            ? String(localized: "Sent")
            : String(localized: "Received")
        return "\(direction), \(message.kind.label), \(PDFormat.clockTime(message.timestamp)), \(PDFormat.bytes(message.byteCount))"
    }
}

// MARK: - Resizable payload split

private struct WebSocketPayloadResizeHandle: View {
    @Binding var value: CGFloat
    let minValue: CGFloat
    let maxValue: CGFloat

    @State private var dragStart: CGFloat?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isHovering ? DSColor.borderStrong : DSColor.border)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 7)
        .background(DSColor.base)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    let start = dragStart ?? value
                    if dragStart == nil { dragStart = start }
                    let proposed = start - gesture.translation.height
                    value = min(max(proposed, minValue), max(maxValue, minValue))
                }
                .onEnded { _ in dragStart = nil }
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Scroll position probing

/// Zero-size AppKit probe placed inside the scroll content: reports whether the
/// message list is scrolled to the bottom so the view only auto-follows when the
/// user has not scrolled up.
private struct WebSocketScrollPositionProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = onChange
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var lastValue: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.attach()
            }
        }

        private func attach() {
            var candidate: NSView? = superview
            while let view = candidate, !(view is NSScrollView) {
                candidate = view.superview
            }
            guard let scrollView = candidate as? NSScrollView else { return }
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.evaluate()
            }
            evaluate()
        }

        private func evaluate() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            let atBottom = visible.maxY >= documentView.frame.height - 12
            guard atBottom != lastValue else { return }
            lastValue = atBottom
            onChange?(atBottom)
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// MARK: - Hex formatting

enum PDHex {
    /// Uppercase hex preview such as "DE AD BE EF …", or the given text when present.
    static func preview(_ data: Data?, maxBytes: Int, text: String? = nil) -> String {
        if let text, !text.isEmpty {
            let singleLine = text
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            return singleLine
        }
        guard let data, !data.isEmpty else { return "—" }
        let prefix = data.prefix(maxBytes)
        var preview = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        if data.count > maxBytes {
            preview += " …"
        }
        return preview
    }

    /// Space-separated uppercase hex for copy actions.
    static func full(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
