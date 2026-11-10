import AppKit
import SwiftUI

/// Read-only, selectable monospaced text view backed by AppKit.
///
/// SwiftUI's `Text` lays out the entire string on the main thread; a large HTML/JS body
/// (hundreds of KB) takes tens of seconds and freezes the window. NSTextView lays the
/// same content out in well under a second and keeps selection/copy working.
struct SelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byCharWrapping
        }
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.scrollToBeginningOfDocument(nil)
        }
        textView.textColor = .labelColor
    }
}

/// Monospaced, selectable text with quiet padding (AppKit backed so large bodies stay
/// responsive).
struct MonoTextBodyView: View {
    let text: String

    var body: some View {
        SelectableTextView(text: text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
