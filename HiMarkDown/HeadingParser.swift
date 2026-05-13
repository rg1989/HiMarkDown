import Foundation

/// ATX heading line parsed from canonical Markdown (depth-first index matches TipTap heading order).
struct HeadingEntry: Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    let level: Int
    let title: String
    let line: Int
}

enum HeadingParser {
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
