import AppKit
import SwiftUI

enum ArtMetrics {
    static let editorFontSize: CGFloat = 12
    static let inspectorWidth: CGFloat = 236
    static let listWidth: CGFloat = 252
    static let canvasPadding: CGFloat = 16
    static let splitHandle: CGFloat = 1
    static let minEditorHeight: CGFloat = 140
    static let captionHeight: CGFloat = 32
    static let minWindowWidth: CGFloat = 1020
    static let minWindowHeight: CGFloat = 700
    static let defaultWindowWidth: CGFloat = 1200
    static let defaultWindowHeight: CGFloat = 840

    static func font() -> NSFont {
        OmacyFont.makeFont(size: editorFontSize)
    }

    static func grid(of art: String) -> (cols: Int, rows: Int) {
        let lines = art.split(separator: "\n", omittingEmptySubsequences: false)
        let rows = max(lines.count, 1)
        let cols = max(lines.map(\.count).max() ?? 1, 1)
        return (cols, rows)
    }

    static func canvasSize(for art: String) -> CGSize {
        let cell = OmacyLayout.cellSize(font: font())
        let grid = grid(of: art)
        return CGSize(
            width: CGFloat(grid.cols) * cell.width,
            height: CGFloat(grid.rows) * cell.height
        )
    }

    static func defaultWindowSize(for art: String) -> CGSize {
        _ = art
        return capToVisibleFrame(CGSize(width: defaultWindowWidth, height: defaultWindowHeight))
    }

    static func capToVisibleFrame(_ size: CGSize) -> CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        return CGSize(
            width: min(max(size.width, minWindowWidth), visible.width * 0.9),
            height: min(max(size.height, minWindowHeight), visible.height * 0.9)
        )
    }

    static func growWindow(_ window: NSWindow, for art: String) {
        let needed = defaultWindowSize(for: art)
        let content = window.contentLayoutRect.size
        let width = max(content.width, needed.width)
        let height = max(content.height, needed.height)
        if width > content.width + 1 || height > content.height + 1 {
            window.setContentSize(NSSize(width: width, height: height))
        }
        window.minSize = NSSize(width: minWindowWidth, height: minWindowHeight)
    }
}

struct ArtEditor: NSViewRepresentable {
    @Binding var text: String
    var background: NSColor
    var foreground: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NonWrappingTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(
            width: ArtMetrics.canvasPadding,
            height: ArtMetrics.canvasPadding
        )
        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            container.lineFragmentPadding = 0
        }
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.textView = textView
        applyChrome(to: textView)
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        scroll.backgroundColor = background
        scroll.drawsBackground = true
        if textView.string != text {
            context.coordinator.isEditing = false
            context.coordinator.isApplying = true
            textView.string = text
            applyChrome(to: textView)
            context.coordinator.isApplying = false
            return
        }
        if context.coordinator.isEditing {
            textView.backgroundColor = background
            textView.insertionPointColor = foreground
            return
        }
        applyChrome(to: textView)
    }

    private func applyChrome(to textView: NSTextView) {
        let font = ArtMetrics.font()
        let cell = OmacyLayout.cellSize(font: font)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = cell.height
        paragraph.maximumLineHeight = cell.height
        paragraph.lineSpacing = 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
            .paragraphStyle: paragraph,
            .kern: 0
        ]
        textView.backgroundColor = background
        textView.insertionPointColor = foreground
        textView.selectedTextAttributes = [
            .backgroundColor: foreground.withAlphaComponent(0.25),
            .foregroundColor: foreground
        ]
        textView.font = font
        textView.textColor = foreground
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = attributes
        let length = (textView.string as NSString).length
        if length > 0 {
            textView.textStorage?.addAttributes(attributes, range: NSRange(location: 0, length: length))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var isEditing = false
        var isApplying = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

private final class NonWrappingTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        keepUnbounded()
    }

    override func layout() {
        super.layout()
        keepUnbounded()
    }

    private func keepUnbounded() {
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        isHorizontallyResizable = true
        isVerticallyResizable = true
    }
}
