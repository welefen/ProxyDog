import AppKit
import SwiftUI

/// Standalone window for AI analysis so the standard macOS close control is available.
@MainActor
final class AIAnalysisWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AIAnalysisWindowController?

    static func present(requests: [CapturedRequest]) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = AIAnalysisWindowController(requests: requests)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let hostingController: NSHostingController<AIAnalysisView>

    init(requests: [CapturedRequest]) {
        var hosting: NSHostingController<AIAnalysisView>!
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "AI analysis")
        window.isReleasedWhenClosed = false
        window.center()

        let root = AIAnalysisView(requests: requests) { [weak window] in
            Self.resize(window)
        }
        hosting = NSHostingController(rootView: root)
        hostingController = hosting
        window.contentViewController = hosting
        super.init(window: window)
        window.delegate = self
        Self.resize(window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        AIAnalysisWindowController.shared = nil
    }

    private static func resize(_ window: NSWindow?) {
        guard let window, let hosting = window.contentViewController as? NSHostingController<AIAnalysisView> else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        guard size.height > 80 else { return }
        let height = min(max(size.height, 220), 900)
        var frame = window.frame
        let delta = height - (window.contentView?.frame.height ?? 0)
        frame.size.height += delta
        frame.size.width = 660
        window.setFrame(frame, display: true, animate: true)
    }
}
