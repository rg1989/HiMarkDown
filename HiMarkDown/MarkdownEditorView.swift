import AppKit
import SwiftUI

/// `NSTextView` wrapper so we can scroll to a line for outline navigation.
struct MarkdownEditorView: NSViewRepresentable {
    static weak var lastScrollView: NSScrollView?

    @Binding var text: String
    var font: NSFont

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditorView
        weak var textView: NSTextView?
        var isUpdatingFromParent = false

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if isUpdatingFromParent { return }
            parent.text = tv.string
        }

        // MARK: NSTextStorageDelegate — re-highlight after each edit.
        // We only style the paragraph that changed (cheap) plus rerun the
        // global code-fence pass inside the highlighter so multi-line
        // ``` blocks stay coherent.
        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            guard let tv = textView else { return }
            let nsString = textStorage.string as NSString
            let safeRange = NSIntersectionRange(editedRange, NSRange(location: 0, length: nsString.length))
            let paragraph = nsString.paragraphRange(for: safeRange)
            MarkdownHighlighter.highlight(textStorage, baseFont: tv.font ?? parent.font, in: paragraph)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true

        let tv = NSTextView()
        tv.isRichText = false
        tv.font = font
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        // We own undo at the document level; if NSTextView were also handling
        // undo, Cmd-Z would be intercepted here and never reach the menu
        // command that drives the document UndoManager. Disabling local undo
        // lets the keystroke fall through to the responder chain.
        tv.allowsUndo = false
        tv.delegate = context.coordinator
        tv.string = text
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true

        // Markdown syntax coloring: register the same Coordinator as the
        // NSTextStorageDelegate so we re-highlight after every edit.
        tv.textStorage?.delegate = context.coordinator
        if let storage = tv.textStorage {
            MarkdownHighlighter.highlightAll(storage, baseFont: font)
        }

        scroll.documentView = tv
        context.coordinator.textView = tv
        Self.lastScrollView = scroll
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        let fontChanged = tv.font?.pointSize != font.pointSize
        if tv.string != text {
            context.coordinator.isUpdatingFromParent = true
            tv.string = text
            context.coordinator.isUpdatingFromParent = false
            if let storage = tv.textStorage {
                MarkdownHighlighter.highlightAll(storage, baseFont: font)
            }
        }
        tv.font = font
        if fontChanged, let storage = tv.textStorage {
            MarkdownHighlighter.highlightAll(storage, baseFont: font)
        }
    }

    static func scrollToLine(_ line: Int, in scrollView: NSScrollView, highlight: Bool = true) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        let ns = tv.string as NSString
        var idx = 0
        var start = 0
        while idx < line, start < ns.length {
            let r = ns.lineRange(for: NSRange(location: start, length: 0))
            start = NSMaxRange(r)
            idx += 1
        }
        guard start < ns.length else { return }
        let range = ns.lineRange(for: NSRange(location: start, length: 0))
        // Force layout for the target glyph range *before* scrolling. Without
        // this, NSTextView may not have computed bounds for the destination
        // and `showFindIndicator` becomes a no-op for ranges that aren't yet
        // displayed — that's why the yellow blink only appeared when the
        // heading was already on screen.
        if let lm = tv.layoutManager {
            lm.ensureLayout(forCharacterRange: range)
        }
        tv.scrollRangeToVisible(range)
        guard highlight else { return }
        // Defer the find-indicator one runloop tick so the scroll has
        // committed and the visible rect contains the range. AppKit will
        // then position the yellow blink correctly even on long jumps.
        DispatchQueue.main.async {
            tv.showFindIndicator(for: range)
        }
    }

    /// Index (into `headings`) of the topmost heading whose source line is
    /// at-or-above the top of the current visible rect. Used to keep scroll
    /// position roughly aligned when the user toggles between modes.
    static func topVisibleHeadingIndex(in scrollView: NSScrollView, headings: [HeadingEntry]) -> Int? {
        guard !headings.isEmpty,
              let tv = scrollView.documentView as? NSTextView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer
        else { return nil }
        let visible = tv.visibleRect
        // Probe a point a couple of pixels into the visible rect so we land
        // on the line that the user actually sees at the top.
        let probe = NSPoint(x: 0, y: visible.origin.y + 2)
        let glyphIdx = lm.glyphIndex(for: probe, in: tc, fractionOfDistanceThroughGlyph: nil)
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        let ns = tv.string as NSString
        // Count newlines up to charIdx to derive the source line number.
        let upTo = min(charIdx, ns.length)
        var line = 0
        var i = 0
        while i < upTo {
            if ns.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        var best: Int?
        for h in headings {
            if h.line <= line { best = h.index } else { break }
        }
        return best
    }
}
