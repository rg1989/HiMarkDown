import AppKit
import QuartzCore
import SwiftUI

/// `NSTextView` wrapper so we can scroll to a line for outline navigation.
struct MarkdownEditorView: NSViewRepresentable {
    static weak var lastScrollView: NSScrollView?

    @Binding var text: String
    var font: NSFont
    var headings: [HeadingEntry] = []
    /// Fired when scroll position implies a different “current section” for outline sync.
    var onOutlineScrollHeadingChange: ((Int?) -> Void)?

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditorView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var boundsObserver: NSObjectProtocol?
        var lastReportedOutlineIndex: Int?
        var lastSyncedHeadingsCount: Int = -1
        var isUpdatingFromParent = false

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        func syncOutlineFromScrollPosition() {
            guard let scroll = scrollView else { return }
            let idx = MarkdownEditorView.topVisibleHeadingIndex(in: scroll, headings: parent.headings)
            guard idx != lastReportedOutlineIndex else { return }
            lastReportedOutlineIndex = idx
            parent.onOutlineScrollHeadingChange?(idx)
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
        context.coordinator.scrollView = scroll
        Self.lastScrollView = scroll

        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        let coord = context.coordinator
        coord.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak coord] _ in
            coord?.syncOutlineFromScrollPosition()
        }

        return scroll
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let o = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(o)
            coordinator.boundsObserver = nil
        }
        coordinator.scrollView = nil
        if lastScrollView === scrollView {
            lastScrollView = nil
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.scrollView = scrollView
        Self.lastScrollView = scrollView

        guard let tv = scrollView.documentView as? NSTextView else { return }
        let fontChanged = tv.font?.pointSize != font.pointSize
        let textChanged: Bool
        if tv.string != text {
            context.coordinator.isUpdatingFromParent = true
            tv.string = text
            context.coordinator.isUpdatingFromParent = false
            if let storage = tv.textStorage {
                MarkdownHighlighter.highlightAll(storage, baseFont: font)
            }
            textChanged = true
        } else {
            textChanged = false
        }
        tv.font = font
        if fontChanged, let storage = tv.textStorage {
            MarkdownHighlighter.highlightAll(storage, baseFont: font)
        }

        let hc = headings.count
        if textChanged || context.coordinator.lastSyncedHeadingsCount != hc {
            context.coordinator.lastSyncedHeadingsCount = hc
            context.coordinator.syncOutlineFromScrollPosition()
        } else {
            context.coordinator.lastSyncedHeadingsCount = hc
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
        // and the outline glow overlay can miss on first paint.
        if let lm = tv.layoutManager {
            lm.ensureLayout(forCharacterRange: range)
        }
        tv.scrollRangeToVisible(range)
        guard highlight else { return }
        // Defer one tick so layout matches the post-scroll viewport (same
        // timing we used for the old find-indicator).
        DispatchQueue.main.async {
            MarkdownOutlineFlashSession.present(in: scrollView, textView: tv, characterRange: range)
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

// MARK: - Outline jump glow (theme border + shadow; replaces system yellow flash)

private enum MarkdownOutlineFlashPalette {
    static let brand = NSColor(calibratedRed: 99 / 255, green: 102 / 255, blue: 241 / 255, alpha: 1)
}

private final class MarkdownOutlineGlowFlashView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let layer = self.layer else { return }
        layer.masksToBounds = false
        layer.backgroundColor = NSColor.clear.cgColor
        layer.cornerRadius = 9
        layer.borderWidth = 1.5
        layer.borderColor = MarkdownOutlineFlashPalette.brand.withAlphaComponent(0.72).cgColor
        // Indigo core + slight pink in the outer halo (matches app chrome).
        layer.shadowColor = MarkdownOutlineFlashPalette.brand.cgColor
        layer.shadowOpacity = 0.78
        layer.shadowRadius = 12
        layer.shadowOffset = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func runFadeAnimation(completion: @escaping () -> Void) {
        guard let L = layer else {
            completion()
            return
        }
        let duration: CFTimeInterval = 1.28
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.88, 0.2, 1)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 1
        opacityAnim.toValue = 0
        opacityAnim.duration = duration
        opacityAnim.timingFunction = timing

        let shadowRadiusAnim = CABasicAnimation(keyPath: "shadowRadius")
        shadowRadiusAnim.fromValue = L.shadowRadius
        shadowRadiusAnim.toValue = 28
        shadowRadiusAnim.duration = duration
        shadowRadiusAnim.timingFunction = timing

        let shadowOpacityAnim = CABasicAnimation(keyPath: "shadowOpacity")
        shadowOpacityAnim.fromValue = L.shadowOpacity
        shadowOpacityAnim.toValue = 0
        shadowOpacityAnim.duration = duration
        shadowOpacityAnim.timingFunction = timing

        let borderAnim = CABasicAnimation(keyPath: "borderColor")
        borderAnim.fromValue = L.borderColor
        borderAnim.toValue = NSColor.clear.cgColor
        borderAnim.duration = duration
        borderAnim.timingFunction = timing

        let group = CAAnimationGroup()
        group.animations = [opacityAnim, shadowRadiusAnim, shadowOpacityAnim, borderAnim]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            DispatchQueue.main.async(execute: completion)
        }
        L.add(group, forKey: "hmOutlineGlow")
        CATransaction.commit()
    }
}

private final class MarkdownOutlineFlashSession {
    private static weak var current: MarkdownOutlineFlashSession?

    private weak var clipView: NSView?
    private weak var textView: NSTextView?
    private let characterRange: NSRange
    private let flashView: MarkdownOutlineGlowFlashView
    private var boundsObserver: NSObjectProtocol?

    private init(clipView: NSView, textView: NSTextView, range: NSRange, flashView: MarkdownOutlineGlowFlashView) {
        self.clipView = clipView
        self.textView = textView
        self.characterRange = range
        self.flashView = flashView
    }

    static func present(in scrollView: NSScrollView, textView: NSTextView, characterRange: NSRange) {
        let clip = scrollView.contentView
        let rect = rectInClip(clipView: clip, textView: textView, range: characterRange)
        guard rect.width > 1, rect.height > 1 else { return }

        current?.invalidate()
        let flash = MarkdownOutlineGlowFlashView(frame: rect)
        let session = MarkdownOutlineFlashSession(clipView: clip, textView: textView, range: characterRange, flashView: flash)
        current = session
        session.start()
    }

    private static func rectInClip(clipView: NSView, textView: NSTextView, range: NSRange) -> NSRect {
        guard let lm = textView.layoutManager,
              let tc = textView.textContainer
        else { return .zero }
        lm.ensureLayout(forCharacterRange: range)
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rTV = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        if rTV.isEmpty { return .zero }
        let origin = textView.textContainerOrigin
        rTV.origin.x += origin.x
        rTV.origin.y += origin.y
        let converted = clipView.convert(rTV, from: textView)
        var padded = converted.insetBy(dx: -8, dy: -5)
        let minH: CGFloat = 22
        if padded.height < minH {
            padded = NSRect(
                x: padded.minX,
                y: padded.midY - minH / 2,
                width: padded.width,
                height: minH
            )
        }
        return padded
    }

    private func start() {
        guard let clip = clipView, let tv = textView else { return }
        flashView.frame = Self.rectInClip(clipView: clip, textView: tv, range: characterRange)
        clip.addSubview(flashView, positioned: .above, relativeTo: tv)

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.relayoutFlashFrame()
        }

        flashView.runFadeAnimation { [weak self] in
            self?.invalidate()
        }
    }

    private func relayoutFlashFrame() {
        guard let clip = clipView, let tv = textView else { return }
        let r = Self.rectInClip(clipView: clip, textView: tv, range: characterRange)
        guard r.width > 1, r.height > 1 else { return }
        flashView.frame = r
    }

    private func invalidate() {
        if let o = boundsObserver {
            NotificationCenter.default.removeObserver(o)
            boundsObserver = nil
        }
        flashView.removeFromSuperview()
        if Self.current === self {
            Self.current = nil
        }
    }
}
