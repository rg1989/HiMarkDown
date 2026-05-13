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
    static func parse(_ markdown: String) -> [HeadingEntry] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [HeadingEntry] = []
        var index = 0
        for (lineNumber, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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

    /// Line of first occurrence of `title` at `level` (0-based), or nil.
    static func lineForHeading(markdown: String, headingIndex: Int) -> Int? {
        let h = parse(markdown)
        guard headingIndex >= 0, headingIndex < h.count else { return nil }
        return h[headingIndex].line
    }
}
