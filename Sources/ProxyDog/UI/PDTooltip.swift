import AppKit
import SwiftUI

/// A lightweight, fast tooltip for icon-only controls.
///
/// The system help tag (`NSView.toolTip`) is driven by AppKit's tooltip timer, which
/// waits well over a second before showing anything; that makes small icon buttons feel
/// like they have no help at all. This presenter shows a small tooltip next to the mouse
/// after a short hover delay and is used by the shared icon-button components.
@MainActor
final class PDCursorTooltip {
    static let shared = PDCursorTooltip()

    private var panel: PDCursorTooltipPanel?
    private var observersInstalled = false

    private init() {}

    func show(text: String) {
        guard !text.isEmpty else { return }
        installObserversIfNeeded()
        let panel = self.panel ?? makePanel()
        panel.setText(text)
        panel.show(at: NSEvent.mouseLocation)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> PDCursorTooltipPanel {
        let panel = PDCursorTooltipPanel()
        return panel
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let names: [Notification.Name] = [
            NSApplication.didResignActiveNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hide()
                }
            }
        }
    }
}

/// Borderless, non-activating panel that renders a single tooltip line.
private final class PDCursorTooltipPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 6
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setText(_ text: String) {
        label.stringValue = text
        guard let contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let size = contentView.fittingSize
        let width = max(size.width, 24)
        let height = max(size.height, 22)
        setContentSize(NSSize(width: width, height: height))
        contentView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    func show(at mouse: NSPoint) {
        guard let contentView else { return }
        let size = contentView.fittingSize
        let width = max(size.width, 24)
        let height = max(size.height, 22)

        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - height - 16)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - width - 4)
            if origin.y < visible.minY + 4 {
                origin.y = mouse.y + 18
            }
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        orderFrontRegardless()
    }
}

/// Hover-driven fast tooltip for SwiftUI controls.
struct PDFastTooltipModifier: ViewModifier {
    let text: String
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    let caption = text
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        PDCursorTooltip.shared.show(text: caption)
                    }
                } else {
                    PDCursorTooltip.shared.hide()
                }
            }
            .onDisappear {
                hoverTask?.cancel()
                PDCursorTooltip.shared.hide()
            }
    }
}

extension View {
    /// Shows a fast cursor tooltip instead of relying on the slow AppKit help tag.
    func fastTooltip(_ text: String) -> some View {
        modifier(PDFastTooltipModifier(text: text))
    }
}
