import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum HiEditMode: String, CaseIterable, Identifiable {
    case html
    case markdown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .html: return "HTML"
        case .markdown: return "Markdown"
        }
    }
}

@MainActor
final class DocumentModel: ObservableObject {
    @Published var markdown: String = ""
    @Published var fileURL: URL?
    @Published var isDirty: Bool = false
    @Published var editMode: HiEditMode = .html
    @Published var headings: [HeadingEntry] = []
    @Published var outlineExpanded: Set<String> = []
    /// Heading index for the section at (or nearest above) the top of the
    /// editor viewport — updated while scrolling so the outline stays in sync.
    @Published private(set) var outlineSyncedHeadingIndex: Int?

    /// Ignore next web dirty notifications while pushing from Swift.
    private var suppressWebDirty = false
    private var securityScopedURL: URL?

    /// Snapshot of the markdown that's currently persisted on disk (or empty
    /// for a fresh untitled doc). Used to compute `isDirty` by comparison so
    /// reverting an edit also clears the Save state.
    private var savedMarkdown: String = ""

    /// Document-level undo. Both editor modes feed into and consume from this
    /// single stack so an edit made in HTML mode can be undone from Markdown
    /// mode and vice versa — semantically there is one document, so there is
    /// one undo history.
    let undoManager = UndoManager()
    /// Last value the WebView told us about. Used to discriminate "this
    /// markdown change came from the WebView so we shouldn't push it back" vs
    /// "this came from undo / markdown editor / load and the WebView needs to
    /// be refreshed".
    private(set) var lastWebMarkdown: String = ""

    /// Transient hint set right before a mode switch: semantic anchor for the
    /// section the user was viewing. Indices into `headings` are unsafe across
    /// TipTap round-trip vs source markdown; level + normalized title survives.
    /// Not @Published — purely a handoff between capture and `applyAnchorIfPending`.
    var preferredOutlineAnchor: OutlineAnchor?
    /// Snapshot of the markdown when the current edit burst started; used to
    /// register a single coalesced undo step instead of one per keystroke.
    private var coalesceBaseline: String?
    private var coalesceWorkItem: DispatchWorkItem?
    private static let coalesceWindow: TimeInterval = 0.6
    private var inUndoRedo = false

    private let recentStore = RecentFilesStore()

    private static func canonical(_ s: String) -> String {
        // Tiptap round-trips strip trailing whitespace and may add or remove
        // a trailing newline. Normalize aggressively so we don't false-flag
        // such non-edits as the document being dirty.
        let trimChars = CharacterSet(charactersIn: " \t")
        let normalised = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: trimChars) }
            .joined(separator: "\n")
        var t = normalised
        while t.hasSuffix("\n") { t.removeLast() }
        return t
    }

    private func recomputeDirty() {
        let cur = Self.canonical(markdown)
        let saved = Self.canonical(savedMarkdown)
        let next = cur != saved
        if isDirty != next {
            if next {
                NSLog("HiMD-DIRTY became true; saved.len=\(saved.count) cur.len=\(cur.count) diff=\(Self.firstDiffSummary(a: saved, b: cur))")
            }
            isDirty = next
        }
    }

    private static func firstDiffSummary(a: String, b: String) -> String {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = min(aChars.count, bChars.count)
        var i = 0
        while i < n, aChars[i] == bChars[i] { i += 1 }
        let aTail = String(aChars[i..<min(aChars.count, i + 60)])
        let bTail = String(bChars[i..<min(bChars.count, i + 60)])
        return "@\(i) saved=<\(aTail)> cur=<\(bTail)>"
    }

    private func resetUndoBaseline(to text: String) {
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        coalesceBaseline = nil
        undoManager.removeAllActions()
        lastWebMarkdown = text
    }

    /// Record a user-driven change so it becomes part of the undo history.
    /// Coalesces rapid successive changes (typing) into one step.
    private func recordEdit(newMarkdown: String) {
        guard !inUndoRedo else { return }
        // Capture the baseline (state before the burst started) once and
        // start (or reset) the debounce timer that flushes a single undo
        // step containing the latest text.
        if coalesceBaseline == nil {
            coalesceBaseline = markdown
        }
        coalesceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushUndoCoalesce()
        }
        coalesceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow, execute: item)
        _ = newMarkdown
    }

    /// Force any pending coalesced undo step to be registered immediately.
    /// Called before mode switches and saves so a partial typing burst is not
    /// lost in the history.
    func flushPendingUndo() {
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        flushUndoCoalesce()
    }

    private func flushUndoCoalesce() {
        guard let baseline = coalesceBaseline else { return }
        coalesceBaseline = nil
        let next = markdown
        guard baseline != next else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.applyUndoRedo(restoring: baseline)
        }
    }

    private func applyUndoRedo(restoring text: String) {
        let current = markdown
        inUndoRedo = true
        // Register the inverse so redo (and chained undos) work.
        undoManager.registerUndo(withTarget: self) { target in
            target.applyUndoRedo(restoring: current)
        }
        suppressWebDirty = true
        markdown = text
        suppressWebDirty = false
        updateHeadingsFromMarkdown()
        recomputeDirty()
        inUndoRedo = false
        // Tell observers to refresh the WebView with the restored content.
        // Markdown-mode NSTextView refreshes automatically via its binding.
        NotificationCenter.default.post(name: .hiUndoApplied, object: nil)
    }

    func performUndo() {
        flushPendingUndo()
        undoManager.undo()
    }

    func performRedo() {
        undoManager.redo()
    }

    /// Called by the WebView coordinator after every native -> JS push so we
    /// can tell apart "WebView told us about its own edit" from "document
    /// markdown changed for some other reason and the WebView needs a
    /// refresh".
    func noteMarkdownPushedToWeb() {
        lastWebMarkdown = markdown
    }

    var displayName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    func applyDefaultModeFromSettings(_ userSettings: UserSettings) {
        if markdown.isEmpty, fileURL == nil {
            editMode = userSettings.defaultEditMode
        }
    }

    func updateHeadingsFromMarkdown() {
        headings = HeadingParser.parse(markdown)
        if headings.isEmpty {
            outlineSyncedHeadingIndex = nil
        } else if let cur = outlineSyncedHeadingIndex, cur >= headings.count {
            outlineSyncedHeadingIndex = headings.count - 1
        }
    }

    /// Updates the outline “you are here” marker without expanding/collapsing
    /// disclosure groups (user may have folded sections on purpose).
    func setOutlineSyncedHeadingIndex(_ index: Int?) {
        let next: Int?
        if let i = index, !headings.isEmpty, i >= 0, i < headings.count {
            next = i
        } else {
            next = nil
        }
        if outlineSyncedHeadingIndex != next {
            outlineSyncedHeadingIndex = next
        }
    }

    func markDirtyFromUserSourceEdit() {
        // Legacy entry point — assumes `markdown` is already the new value.
        // Use `userEditedMarkdown(_:)` instead for new code.
        recordEdit(newMarkdown: markdown)
        recomputeDirty()
        updateHeadingsFromMarkdown()
    }

    /// Apply a user-driven edit to `markdown` while also registering the
    /// previous state with the document undo manager. Call this *with the
    /// proposed new text* — it captures the current `markdown` as the undo
    /// baseline before assigning.
    func userEditedMarkdown(_ newValue: String) {
        if newValue != markdown {
            recordEdit(newMarkdown: newValue)
        }
        markdown = newValue
        recomputeDirty()
        updateHeadingsFromMarkdown()
    }

    func markDirtyFromWeb() {
        guard !suppressWebDirty else { return }
        recordEdit(newMarkdown: markdown)
        recomputeDirty()
        updateHeadingsFromMarkdown()
    }

    func newDocument() {
        markdown = ""
        savedMarkdown = ""
        fileURL = nil
        isDirty = false
        outlineExpanded.removeAll()
        outlineSyncedHeadingIndex = nil
        stopAccessingSecurityScopedResource()
        updateHeadingsFromMarkdown()
        resetUndoBaseline(to: "")
    }

    func loadFromURL(_ url: URL) throws {
        stopAccessingSecurityScopedResource()
        let didStart = url.startAccessingSecurityScopedResource()
        securityScopedURL = didStart ? url : nil
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        // Compute headings off the published storage so we publish at most
        // twice (markdown+headings, then fileURL last so any onChange(fileURL)
        // observers see a fully-populated document).
        let parsedHeadings = HeadingParser.parse(text)
        suppressWebDirty = true
        markdown = text
        savedMarkdown = text
        headings = parsedHeadings
        outlineSyncedHeadingIndex = nil
        isDirty = false
        suppressWebDirty = false
        fileURL = url
        recentStore.noteOpened(url)
        resetUndoBaseline(to: text)
    }

    func stopAccessingSecurityScopedResource() {
        if let u = securityScopedURL {
            u.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = nil
    }

    func saveMarkdownToCurrentURL() throws {
        let data = markdown.data(using: .utf8) ?? Data()
        guard let url = fileURL else {
            throw NSError(domain: "HiMarkDown", code: 1, userInfo: [NSLocalizedDescriptionKey: "No file URL."])
        }
        try data.write(to: url, options: .atomic)
        savedMarkdown = markdown
        isDirty = false
        recentStore.noteOpened(url)
    }

    func savePanelForNewMarkdown() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    func saveIfNeededUntitled() throws {
        if fileURL == nil {
            guard let url = savePanelForNewMarkdown() else {
                throw CancellationError()
            }
            fileURL = url
        }
        try saveMarkdownToCurrentURL()
    }

    func saveAsMarkdownCopy() throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = markdown.data(using: .utf8) ?? Data()
        try data.write(to: url, options: .atomic)
        savedMarkdown = markdown
        fileURL = url
        isDirty = false
        stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        securityScopedURL = url
        recentStore.noteOpened(url)
    }

    func saveAsHTML(data: Data) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        let base = (fileURL?.deletingPathExtension().lastPathComponent) ?? "Export"
        panel.nameFieldStringValue = base + ".html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    func absorbWebMarkdown(_ text: String) {
        guard !inUndoRedo else {
            applyMarkdownFromWeb(text)
            return
        }
        if text != markdown {
            recordEdit(newMarkdown: text)
        }
        applyMarkdownFromWeb(text)
        lastWebMarkdown = text
        recomputeDirty()
    }

    func applyMarkdownFromWeb(_ text: String) {
        suppressWebDirty = true
        markdown = text
        suppressWebDirty = false
        updateHeadingsFromMarkdown()
    }

    /// After TipTap runs `setMarkdown`, its serialized markdown can differ from
    /// the on-disk buffer (normalization, heading levels). Pulling it into
    /// `markdown` keeps `HeadingParser` / the outline aligned with the editor
    /// on first HTML paint — same outcome as toggling Markdown and back.
    /// Does not push an undo step; `recomputeDirty()` uses canonical comparison.
    func adoptCanonicalMarkdownFromTipTap(_ text: String) {
        guard !inUndoRedo else { return }
        if text.isEmpty, !markdown.isEmpty { return }
        let cNew = Self.canonical(text)
        let cOld = Self.canonical(markdown)
        guard cNew != cOld else {
            lastWebMarkdown = text
            return
        }
        suppressWebDirty = true
        markdown = text
        suppressWebDirty = false
        updateHeadingsFromMarkdown()
        lastWebMarkdown = text
        pruneOutlineExpandedToBranchGroups()
        expandAllBranchOutlineGroups()
        recomputeDirty()
    }

    private func expandAllBranchOutlineGroups() {
        for g in HeadingParser.outlineGroups(headings) where !g.children.isEmpty {
            outlineExpanded.insert("\(g.root.index)")
        }
    }

    private func pruneOutlineExpandedToBranchGroups() {
        let validKeys = Set(
            HeadingParser.outlineGroups(headings)
                .filter { !$0.children.isEmpty }
                .map { "\($0.root.index)" }
        )
        outlineExpanded = outlineExpanded.intersection(validKeys)
    }

    func setMarkdownProgrammatically(_ text: String) {
        suppressWebDirty = true
        markdown = text
        savedMarkdown = text
        suppressWebDirty = false
        isDirty = false
        updateHeadingsFromMarkdown()
    }

    func openPanelURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "md")!,
            .init(filenameExtension: "markdown")!,
            .init(filenameExtension: "mdown")!,
        ]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    func recentFileURLs() -> [URL] {
        recentStore.resolvedURLs()
    }

    func openRecent(_ url: URL) throws {
        try loadFromURL(url)
    }

    func replaceInMarkdown(search: String, replacement: String, replaceAll: Bool) {
        guard !search.isEmpty else { return }
        if replaceAll {
            markdown = markdown.replacingOccurrences(of: search, with: replacement)
        } else if let r = markdown.range(of: search) {
            markdown.replaceSubrange(r, with: replacement)
        }
        recomputeDirty()
        updateHeadingsFromMarkdown()
    }

    func scrollMarkdownToHeading(headingIndex: Int) {
        guard let line = HeadingParser.lineForHeading(markdown: markdown, headingIndex: headingIndex) else { return }
        NotificationCenter.default.post(name: .hiMarkdownScrollToLine, object: line)
    }
}

extension Notification.Name {
    static let hiMarkdownScrollToLine = Notification.Name("hiMarkdownScrollToLine")
    static let hiOpenFiles = Notification.Name("hiOpenFiles")
    /// Fired after the document UndoManager applies an undo or redo so the
    /// active editor can refresh its rendering of `document.markdown`.
    static let hiUndoApplied = Notification.Name("hiUndoApplied")
}

final class RecentFilesStore {
    private let key = "recentMarkdownBookmarks"
    private let max = 10

    func noteOpened(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var items = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
            items.removeAll { $0 == data }
            items.insert(data, at: 0)
            if items.count > max { items = Array(items.prefix(max)) }
            UserDefaults.standard.set(items, forKey: key)
        } catch {
            /* ignore */
        }
    }

    func resolvedURLs() -> [URL] {
        let items = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        var urls: [URL] = []
        for data in items {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale {
                urls.append(url)
            }
        }
        return urls
    }
}
