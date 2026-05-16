import Foundation

/// Stable handoff for “which section was I reading?” across HTML ↔ Markdown.
/// Integer indices into `headings` are not reliable when TipTap round-trip
/// changes heading count or order; we match by level + normalized title instead.
struct OutlineAnchor: Equatable {
    let level: Int
    /// Normalized plain-text key (see `HeadingParser.normalizedOutlineTitleKey`).
    let titleKey: String

    init(level: Int, rawTitle: String) {
        self.level = level
        self.titleKey = HeadingParser.normalizedOutlineTitleKey(rawTitle)
    }

    /// Parse payload from `window.__HiMD.getTopVisibleHeadingAnchor()` (WKWebView → NSDictionary).
    init?(webPayload: [String: Any]) {
        let lv = (webPayload["level"] as? NSNumber)?.intValue ?? webPayload["level"] as? Int
        let text = (webPayload["text"] as? String) ?? ""
        guard let lv, (1...6).contains(lv), !text.isEmpty else { return nil }
        self.level = lv
        self.titleKey = HeadingParser.normalizedOutlineTitleKey(text)
    }
}

/// ATX heading line parsed from canonical Markdown (depth-first index matches TipTap heading order).
struct HeadingEntry: Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    let level: Int
    let title: String
    let line: Int
}

/// One top-level outline row plus nested headings at deeper levels (same
/// grouping as `OutlineSidebar` and TipTap’s heading tree).
struct HeadingOutlineGroup: Hashable {
    let root: HeadingEntry
    let children: [HeadingEntry]
}

/// Recursive tree node for the outline sidebar (replaces the flat two-level
/// `HeadingOutlineGroup` grouping with true nesting by heading level).
struct OutlineNode: Identifiable {
    let entry: HeadingEntry
    var children: [OutlineNode]
    var id: Int { entry.index }
}

enum HeadingParser {
    /// Decode common XML entities so Markdown source (`&amp;`) lines up with
    /// TipTap `textContent` and outline labels.
    private static func decodeBasicEntities(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    /// Single comparable key for `OutlineAnchor` / cross-editor heading match.
    static func normalizedOutlineTitleKey(_ raw: String) -> String {
        let decoded = decodeBasicEntities(raw)
        let norm = decoded.precomposedStringWithCanonicalMapping
        let parts = norm.split { $0.isNewline || $0.isWhitespace }
        return parts.joined(separator: " ").localizedLowercase
    }

    /// Map a semantic anchor onto the current flat `headings` list (after any markdown refresh).
    static func headingIndex(matching anchor: OutlineAnchor, in headings: [HeadingEntry]) -> Int? {
        guard !headings.isEmpty else { return nil }
        let pairs: [(HeadingEntry, String)] = headings.map { ($0, normalizedOutlineTitleKey($0.title)) }
        if let hit = pairs.first(where: { $0.0.level == anchor.level && $0.1 == anchor.titleKey }) {
            return hit.0.index
        }
        let titleMatches = pairs.filter { $0.1 == anchor.titleKey }.map { $0.0 }
        guard !titleMatches.isEmpty else { return nil }
        if titleMatches.count == 1 { return titleMatches[0].index }
        let best = titleMatches.min { a, b in
            let da = abs(a.level - anchor.level)
            let db = abs(b.level - anchor.level)
            if da != db { return da < db }
            return a.index < b.index
        }
        return best?.index
    }

    /// Lines that look like ATX headings inside fenced code blocks are not
    /// document headings in TipTap — skipping fences keeps the outline index
    /// space aligned with the HTML editor and `scrollToHeadingIndex`.
    static func parse(_ markdown: String) -> [HeadingEntry] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [HeadingEntry] = []
        var index = 0
        var inFence = false
        for (lineNumber, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFence {
                if isClosingCodeFenceLine(trimmed) {
                    inFence = false
                }
                continue
            }
            if isOpeningCodeFenceLine(trimmed) {
                inFence = true
                continue
            }

            guard trimmed.hasPrefix("#") else { continue }
            var level = 0
            var i = trimmed.startIndex
            while i < trimmed.endIndex, trimmed[i] == "#" {
                level += 1
                i = trimmed.index(after: i)
                if level > 6 { break }
            }
            guard level >= 1, level <= 6 else { continue }
            guard i < trimmed.endIndex, trimmed[i].isWhitespace else { continue }
            let titleStart = trimmed.index(after: i)
            let title = String(trimmed[titleStart...]).trimmingCharacters(in: .whitespaces)
            result.append(HeadingEntry(index: index, level: level, title: title, line: lineNumber))
            index += 1
        }
        return result
    }

    /// Builds a recursive tree from a flat heading list based on heading level.
    /// H2 items become children of the preceding H1, H3 items become children
    /// of the preceding H2, etc. — matching the visual nesting of the document.
    static func outlineTree(_ flat: [HeadingEntry]) -> [OutlineNode] {
        guard !flat.isEmpty else { return [] }
        var i = 0
        func collect(parentLevel: Int) -> [OutlineNode] {
            var nodes: [OutlineNode] = []
            while i < flat.count, flat[i].level > parentLevel {
                let entry = flat[i]; i += 1
                nodes.append(OutlineNode(entry: entry, children: collect(parentLevel: entry.level)))
            }
            return nodes
        }
        return collect(parentLevel: 0)
    }

    /// Groups flat `HeadingEntry` list into outline sections: each root at
    /// the first heading’s level, with following deeper headings as children
    /// until the next root-level heading.
    static func outlineGroups(_ flat: [HeadingEntry]) -> [HeadingOutlineGroup] {
        guard !flat.isEmpty else { return [] }
        let rootLevel = flat.first?.level ?? 1
        var groups: [HeadingOutlineGroup] = []
        var i = 0
        while i < flat.count {
            let h = flat[i]
            if h.level == rootLevel {
                var children: [HeadingEntry] = []
                i += 1
                while i < flat.count, flat[i].level > rootLevel {
                    children.append(flat[i])
                    i += 1
                }
                groups.append(HeadingOutlineGroup(root: h, children: children))
            } else {
                groups.append(HeadingOutlineGroup(root: h, children: []))
                i += 1
            }
        }
        return groups
    }

    /// `trimmed` is the full line trimmed of leading/trailing ASCII whitespace.
    private static func isOpeningCodeFenceLine(_ trimmed: String) -> Bool {
        fenceDelimiterLength(trimmed, char: "`") >= 3 || fenceDelimiterLength(trimmed, char: "~") >= 3
    }

    private static func isClosingCodeFenceLine(_ trimmed: String) -> Bool {
        isOpeningCodeFenceLine(trimmed)
    }

    /// Counts a run of `char` at the start of `trimmed` (after trim, so fence is line-leading).
    private static func fenceDelimiterLength(_ trimmed: String, char: Character) -> Int {
        var n = 0
        for c in trimmed {
            if c == char { n += 1 } else { break }
        }
        return n
    }

    /// Line of first occurrence of `title` at `level` (0-based), or nil.
    static func lineForHeading(markdown: String, headingIndex: Int) -> Int? {
        let h = parse(markdown)
        guard headingIndex >= 0, headingIndex < h.count else { return nil }
        return h[headingIndex].line
    }
}
