import AppKit
import SwiftUI

/// The app's own icon, used in the sidebar brand header.
struct AppBrandIcon: View {
    var size: CGFloat = 22

    private var image: NSImage? {
        NSApp.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
