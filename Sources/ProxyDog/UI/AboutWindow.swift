import AppKit
import SwiftUI

/// Custom About window: icon, name, version and the author link (the standard panel
/// cannot place a clickable link between the version and the copyright line).
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: AboutView())
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 320)

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)
            AppBrandIcon(size: 76)
            Text(AppInfo.name)
                .font(DS.Typography.ui(21, .semibold))
                .foregroundStyle(DSColor.textPrimary)
                .padding(.top, 14)
            Text(String(format: String(localized: "Version %@"), AppInfo.version))
                .font(DS.Typography.ui(12))
                .foregroundStyle(DSColor.textSecondary)
                .padding(.top, 5)
            Link("@welefen", destination: URL(string: "https://github.com/welefen")!)
                .font(DS.Typography.ui(12, .medium))
                .padding(.top, 6)
                .accessibilityLabel("Author welefen on GitHub")
            Spacer(minLength: 0)
            Text(verbatim: "Copyright © 2026 ProxyDog")
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textMuted)
                .padding(.bottom, 18)
        }
        .frame(width: 420, height: 320)
        .background(DSColor.chrome)
    }
}
