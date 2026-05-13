import AppKit

/// Lightweight regex-based syntax highlighter for the plain `NSTextView`
/// markdown editor. We deliberately roll our own (no external library) so
/// the colors match the HTML rendering exactly via `HiAppearance.brand` and
/// adapt to dark / light app appearance through `NSColor` semantic colors
/// and dynamic providers.
///
/// Highlighter is stateless — call `highlight(_:baseFont:in:)` from the
/// text storage delegate after each edit. We re-style only the affected
/// paragraph(s) plus enough context for code-fence balance, so typing in a
/// long file stays cheap.
enum MarkdownHighlighter {
    // MARK: Pattern compilation (one-time)
    private struct Pattern {
        let regex: NSRegularExpression
        let attributes: (NSTextCheckingResult, NSFont) -> [NSAttributedString.Key: Any]
    }

    private static let brand: NSColor = NSColor(
        red: 99 / 255, green: 102 / 255, blue: 241 / 255, alpha: 1
    )
    private static let brandSoft: NSColor = NSColor(
        red: 99 / 255, green: 102 / 255, blue: 241 / 255, alpha: 0.18
    )
    private static let inlineCodeFG: NSColor = NSColor(
        red: 165 / 255, green: 180 / 255, blue: 252 / 255, alpha: 1
    )
    private static let dim: NSColor = NSColor.tertiaryLabelColor

    private static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
    private static func mono(_ font: NSFont) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
    }
    private static func headingFont(_ font: NSFont, level: Int) -> NSFont {
        // h1 ~1.55x, h2 ~1.35x, h3 ~1.18x, then taper to 1.0
        let scale: CGFloat = {
            switch level {
            case 1: return 1.55
            case 2: return 1.35
            case 3: return 1.18
            case 4: return 1.10
            default: return 1.05
            }
        }()
        let bigger = NSFont.systemFont(ofSize: font.pointSize * scale, weight: .bold)
        return bigger
    }

    private static let patterns: [Pattern] = {
        func re(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        return [
            // ATX heading: leading #'s capture in group 1, hash count drives
            // size. Anchored to line start.
            Pattern(
                regex: re(#"^(#{1,6})\s+.*$"#, options: [.anchorsMatchLines]),
                attributes: { match, font in
                    let level = max(1, min(6, match.range(at: 1).length))
                    return [
                        .font: headingFont(font, level: level),
                        .foregroundColor: brand,
                    ]
                }
            ),
            // Bold: **text** or __text__
            Pattern(
                regex: re(#"(\*\*|__)(?=\S)([^*_\n]+?)(?<=\S)\1"#),
                attributes: { _, font in
                    [.font: bold(font)]
                }
            ),
            // Italic: *text* or _text_ (avoid matching inside ** or __)
            Pattern(
                regex: re(#"(?<![\*_\w])([\*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![\*_\w])"#),
                attributes: { _, font in
                    [.font: italic(font)]
                }
            ),
            // Inline code `text`
            Pattern(
                regex: re(#"`([^`\n]+)`"#),
                attributes: { _, font in
                    [
                        .font: mono(font),
                        .foregroundColor: inlineCodeFG,
                        .backgroundColor: brandSoft,
                    ]
                }
            ),
            // Link [text](url)
            Pattern(
                regex: re(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#),
                attributes: { _, _ in
                    [
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                }
            ),
            // Blockquote line: "> something"
            Pattern(
                regex: re(#"^\s*>\s.*$"#, options: [.anchorsMatchLines]),
                attributes: { _, font in
                    [
                        .font: italic(font),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                }
            ),
            // List bullet (-, *, +, or "1.") at line start — only the marker.
            Pattern(
                regex: re(#"^\s*([-*+]|\d+\.)\s"#, options: [.anchorsMatchLines]),
                attributes: { _, font in
                    [
                        .font: bold(font),
                        .foregroundColor: brand,
                    ]
                }
            ),
            // Horizontal rule
            Pattern(
                regex: re(#"^\s*(-{3,}|\*{3,}|_{3,})\s*$"#, options: [.anchorsMatchLines]),
                attributes: { _, _ in
                    [.foregroundColor: brand]
                }
            ),
        ]
    }()

    // MARK: - Public entry point

    /// Re-styles `range` of `storage` according to markdown syntax. Caller
    /// should pass a base font (the user's chosen monospace face) so we can
    /// derive bold/italic variants without losing point size.
    static func highlight(_ storage: NSTextStorage, baseFont: NSFont, in range: NSRange) {
        // Reset everything in `range` to base attributes first so previously
        // applied syntax styling doesn't bleed across edits.
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.clear,
            .underlineStyle: 0,
        ]
        storage.setAttributes(baseAttrs, range: range)

        let nsString = storage.string as NSString
        // Code fences first — they win over inline patterns inside them.
        applyCodeFenceHighlighting(storage, nsString: nsString, baseFont: baseFont, in: range)

        for p in patterns {
            p.regex.enumerateMatches(in: storage.string, options: [], range: range) { match, _, _ in
                guard let match = match else { return }
                // Don't paint over a code fence span (we already styled it).
                if isInsideCodeFence(match.range, storage: storage) { return }
                storage.addAttributes(p.attributes(match, baseFont), range: match.range)
            }
        }
    }

    /// Public helper for callers that want to force a full re-style (e.g.
    /// after the base font changes).
    static func highlightAll(_ storage: NSTextStorage, baseFont: NSFont) {
        highlight(storage, baseFont: baseFont, in: NSRange(location: 0, length: storage.length))
    }

    // MARK: - Code fence handling

    private static let codeFenceMarker: NSAttributedString.Key = .init(rawValue: "HiMDCodeFence")

    private static func isInsideCodeFence(_ range: NSRange, storage: NSTextStorage) -> Bool {
        guard range.location < storage.length else { return false }
        return storage.attribute(codeFenceMarker, at: range.location, effectiveRange: nil) != nil
    }

    private static func applyCodeFenceHighlighting(
        _ storage: NSTextStorage,
        nsString: NSString,
        baseFont: NSFont,
        in range: NSRange
    ) {
        // Walk the entire document line by line collecting fenced-code
        // ranges. Cheap (single linear scan of the string) and avoids the
        // edge cases of regex-multiline. We always re-scan the whole
        // document because a fence opened earlier can affect later lines.
        let full = NSRange(location: 0, length: storage.length)
        let codeFont = mono(baseFont)
        var inFence = false
        var fenceStart = 0
        var line = 0
        let len = nsString.length
        while line < len {
            let lineRange = nsString.lineRange(for: NSRange(location: line, length: 0))
            let trimmed = nsString.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inFence {
                    let codeRange = NSRange(location: fenceStart, length: NSMaxRange(lineRange) - fenceStart)
                    let clipped = NSIntersectionRange(codeRange, full)
                    if clipped.length > 0 {
                        storage.addAttributes([
                            .font: codeFont,
                            .foregroundColor: inlineCodeFG,
                            .backgroundColor: brandSoft,
                            codeFenceMarker: true,
                        ], range: clipped)
                    }
                    inFence = false
                } else {
                    fenceStart = lineRange.location
                    inFence = true
                }
            }
            line = NSMaxRange(lineRange)
            if line == 0 { break }
        }
        // Unterminated fence (user is mid-typing): style from start to end.
        if inFence {
            let codeRange = NSRange(location: fenceStart, length: len - fenceStart)
            let clipped = NSIntersectionRange(codeRange, full)
            if clipped.length > 0 {
                storage.addAttributes([
                    .font: codeFont,
                    .foregroundColor: inlineCodeFG,
                    .backgroundColor: brandSoft,
                    codeFenceMarker: true,
                ], range: clipped)
            }
        }
        _ = range
    }
}
