import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var document: DocumentModel
    @EnvironmentObject private var userSettings: UserSettings
    var webCoordinator: WebEditorCoordinator

    @State private var showFind = false
    @State private var markdownFindStart: String.Index?

    /// Whether the outline drawer is shown. We manage this ourselves instead
    /// of using NavigationSplitView so the toolbar and the OS title bar can
    /// span the full window width with the drawer sitting *below* them, like
    /// a normal app — not a translucent column that bleeds under the title.
    @State private var sidebarVisible: Bool = true

    /// Default ~½ previous ideal (260 → 140). Drag the divider to resize; max
    /// matches the old upper bound (380). Persisted per-window.
    @SceneStorage("hiOutlineColumnWidth") private var outlineColumnWidth: Double = 140
    /// Live width during an active drag. We do NOT write to @SceneStorage on
    /// every onChanged tick — that re-encodes through the scene-restoration
    /// pipeline and produces visible jitter while dragging. Instead we update
    /// this @State (cheap, in-memory) for every frame and only commit the
    /// final value to @SceneStorage in onEnded.
    @State private var liveOutlineWidth: Double?
    @State private var outlineResizeOrigin: Double?

    /// What the HStack actually renders right now. Prefers the live drag
    /// value when a drag is in progress.
    private var displayedOutlineWidth: CGFloat {
        CGFloat(liveOutlineWidth ?? outlineColumnWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar, full width. The OS title bar (filename, traffic
            // lights, sidebar toggle) sits above this; nothing in this VStack
            // is allowed to extend over it.
            toolbar
            Divider()
            HStack(spacing: 0) {
                if sidebarVisible {
                    OutlineSidebar(onSelectHeading: { idx in
                        selectHeading(idx)
                    })
                    .frame(width: displayedOutlineWidth)
                    .frame(maxHeight: .infinity)
                    .background(HiAppearance.sidebarBackground())

                    outlineResizeDivider
                }
                ZStack {
                    // Both editors stay mounted at all times so each keeps
                    // its own scroll position when the user toggles modes.
                    // If we used `if/else`, SwiftUI would tear down whichever
                    // view is hidden (rebuilding the WKWebView from scratch),
                    // and the WebView would land back at scroll 0 every time
                    // we returned to HTML.
                    WebEditorView(document: document, coordinator: webCoordinator)
                        .frame(minWidth: 200, minHeight: 200)
                        .opacity(document.editMode == .html ? 1 : 0)
                        .allowsHitTesting(document.editMode == .html)
                        .accessibilityHidden(document.editMode != .html)

                    MarkdownEditorView(
                        text: Binding(
                            get: { document.markdown },
                            set: { newValue in
                                document.userEditedMarkdown(newValue)
                            }
                        ),
                        font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        headings: document.headings,
                        onOutlineScrollHeadingChange: { document.setOutlineSyncedHeadingIndex($0) }
                    )
                    .frame(minWidth: 200, minHeight: 200)
                    .opacity(document.editMode == .markdown ? 1 : 0)
                    .allowsHitTesting(document.editMode == .markdown)
                    .accessibilityHidden(document.editMode != .markdown)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .tint(HiAppearance.brand)
        .navigationTitle(document.displayName)
        .navigationSubtitle(document.isDirty ? "Edited" : "")
        .sheet(isPresented: $showFind) {
            FindReplaceSheet(
                isPresented: $showFind,
                isHTMLMode: document.editMode == .html,
                onFindInMarkdown: { q in
                    findInMarkdown(q)
                },
                onReplaceFirst: { s, r in
                    if document.editMode == .html {
                        webCoordinator.replaceFirst(search: s, replacement: r)
                    } else {
                        document.replaceInMarkdown(search: s, replacement: r, replaceAll: false)
                    }
                },
                onReplaceAll: { s, r in
                    if document.editMode == .html {
                        webCoordinator.replaceAll(search: s, replacement: r)
                    } else {
                        document.replaceInMarkdown(search: s, replacement: r, replaceAll: true)
                    }
                },
                onFindInWeb: { query in
                    webCoordinator.findInPage(query) { _ in }
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiNewDocument)) { _ in
            attemptNew()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiOpenDocument)) { _ in
            attemptOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiSaveDocument)) { _ in
            saveDocument()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiSaveAsDocument)) { _ in
            saveAsDocument()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiFind)) { _ in
            showFind = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiOpenFiles)) { output in
            if let url = output.object as? URL {
                attemptOpenURL(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiMarkdownScrollToLine)) { output in
            if let line = output.object as? Int, let scroll = MarkdownEditorView.lastScrollView {
                MarkdownEditorView.scrollToLine(line, in: scroll)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiUndoApplied)) { _ in
            // Markdown mode picks up the change automatically through the
            // NSTextView binding. The WebView only mirrors the document on
            // explicit pushes, so re-push here when we're in HTML mode.
            if document.editMode == .html {
                webCoordinator.reloadFromDocument()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hiThemeChanged)) { _ in
            webCoordinator.setThemeJSON(
                AppTheme.load().cssVariablesJSON(includeColors: AppTheme.userHasCustomColors)
            )
        }
        .onOpenURL { url in
            attemptOpenURL(url)
        }
        .onAppear {
            webCoordinator.setThemeJSON(
                AppTheme.load().cssVariablesJSON(includeColors: AppTheme.userHasCustomColors)
            )
        }
        .onChange(of: document.fileURL) { _ in
            webCoordinator.reloadFromDocument {
                webCoordinator.refreshOutlineHeadingFromWeb()
            }
        }
        .onChange(of: document.markdown) { _ in
            if document.editMode == .markdown {
                DispatchQueue.main.async {
                    document.updateHeadingsFromMarkdown()
                }
            }
        }
        .onChange(of: document.editMode) { newMode in
            Task { @MainActor in
                await syncModeSwitch(to: newMode)
            }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        sidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .regular))
                }
                .buttonStyle(.plain)
                .help("Toggle Outline")
                .keyboardShortcut("s", modifiers: [.command, .control])

                // Bind the Picker through proxy bindings so the @Published write
                // happens on the next runloop tick, never inside a view-update
                // pass. Without this, SwiftUI's reconciliation can re-write the
                // selection synchronously and the second write triggers
                // "Publishing changes from within view updates is not allowed".
                Picker(
                    "",
                    selection: Binding(
                        get: { document.editMode },
                        set: { newValue in
                            // Capture the user's reading position in the *current*
                            // mode before flipping editMode, so syncModeSwitch can
                            // restore it in the new mode. The HTML capture is async
                            // (JS round-trip); markdown is sync.
                            captureCurrentAnchor { anchor in
                                DispatchQueue.main.async {
                                    document.preferredOutlineAnchor = anchor
                                    document.editMode = newValue
                                }
                            }
                        }
                    )
                ) {
                    Text("HTML").tag(HiEditMode.html)
                    Text("Markdown").tag(HiEditMode.markdown)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityLabel("Editor mode")

                Spacer()

                if document.isDirty {
                    Button("Save") {
                        saveDocument()
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                }

                Menu {
                    let recent = document.recentFileURLs()
                    if recent.isEmpty {
                        Text("No recent files").disabled(true)
                    } else {
                        ForEach(recent, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                attemptOpenURL(url)
                            }
                        }
                    }
                } label: {
                    Label("Recent", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(HiAppearance.brand)
                }
                .menuStyle(.borderlessButton)
                .tint(HiAppearance.brand)
                .fixedSize()
            }
            .padding(8)
            HiAppearance.toolbarAccentLine()
        }
    }

    private var outlineResizeDivider: some View {
        // We use the GLOBAL coordinate space deliberately. With the default
        // (.local) space the translation is measured against the divider's
        // own frame; because the divider moves with the layout as we resize,
        // the next frame reports a translation relative to a moved origin
        // and the column oscillates / vibrates. Global coordinates make
        // translation an absolute mouse delta and the drag stays smooth.
        ZStack {
            Rectangle()
                .fill(HiAppearance.brand.opacity(0.10))
            Rectangle()
                .fill(HiAppearance.brand.opacity(0.55))
                .frame(width: 1)
        }
        .frame(width: 6)
        .contentShape(Rectangle().inset(by: -4))
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { g in
                    if outlineResizeOrigin == nil {
                        outlineResizeOrigin = outlineColumnWidth
                    }
                    if let origin = outlineResizeOrigin {
                        let next = min(380, max(120, origin + Double(g.translation.width)))
                        if liveOutlineWidth != next {
                            liveOutlineWidth = next
                        }
                    }
                }
                .onEnded { _ in
                    if let final = liveOutlineWidth {
                        outlineColumnWidth = final
                    }
                    liveOutlineWidth = nil
                    outlineResizeOrigin = nil
                }
        )
        .accessibilityLabel("Resize outline column")
        .accessibilityHint("Drag left or right to change outline width")
    }

    @MainActor
    private func syncModeSwitch(to mode: HiEditMode) async {
        // Make sure any in-flight typing burst becomes a single undo step
        // before we flip modes; otherwise the burst would coalesce with edits
        // made in the new mode after the switch.
        document.flushPendingUndo()
        switch mode {
        case .markdown:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                webCoordinator.getMarkdown { md in
                    DispatchQueue.main.async {
                        if !md.isEmpty, md != document.markdown {
                            document.markdown = md
                        }
                        // Keep `headings` in sync before we resolve the outline anchor;
                        // assigning `markdown` alone does not always refresh headings
                        // on the same tick as `onChange(of: markdown)`.
                        document.updateHeadingsFromMarkdown()
                        cont.resume()
                    }
                }
            }
            // Wait two runloop ticks so SwiftUI has actually mounted the
            // MarkdownEditorView (and its NSScrollView is registered as
            // `lastScrollView`) before we try to scroll it.
            DispatchQueue.main.async {
                DispatchQueue.main.async { applyAnchorIfPending() }
            }
        case .html:
            // Only re-push markdown into the WebView if it actually changed
            // since the last push; calling setMarkdown rebuilds Tiptap's
            // document and resets WebView scroll to 0. When the user just
            // toggled modes without editing, the WebView's own scroll
            // position is the right thing to keep.
            if document.markdown != document.lastWebMarkdown {
                webCoordinator.reloadFromDocument {
                    applyAnchorIfPending()
                }
            } else {
                // WebView kept its scroll; drive the outline from the captured
                // semantic anchor (re-querying the viewport here races layout).
                if let anchor = document.preferredOutlineAnchor {
                    let idx = HeadingParser.headingIndex(matching: anchor, in: document.headings)
                    if let idx {
                        document.setOutlineSyncedHeadingIndex(idx)
                    } else {
                        webCoordinator.refreshOutlineHeadingFromWeb()
                    }
                } else {
                    webCoordinator.refreshOutlineHeadingFromWeb()
                }
                document.preferredOutlineAnchor = nil
            }
        }
    }

    private func captureCurrentAnchor(_ completion: @escaping (OutlineAnchor?) -> Void) {
        switch document.editMode {
        case .html:
            webCoordinator.getTopVisibleHeadingAnchor(completion)
        case .markdown:
            if let scroll = MarkdownEditorView.lastScrollView,
               let idx = MarkdownEditorView.topVisibleHeadingIndex(in: scroll, headings: document.headings),
               idx >= 0, idx < document.headings.count
            {
                let h = document.headings[idx]
                completion(OutlineAnchor(level: h.level, rawTitle: h.title))
            } else {
                completion(nil)
            }
        }
    }

    @MainActor
    private func applyAnchorIfPending() {
        guard let anchor = document.preferredOutlineAnchor else { return }
        document.preferredOutlineAnchor = nil
        guard let idx = HeadingParser.headingIndex(matching: anchor, in: document.headings) else {
            document.setOutlineSyncedHeadingIndex(nil)
            return
        }
        document.setOutlineSyncedHeadingIndex(idx)
        switch document.editMode {
        case .html:
            webCoordinator.scrollToHeading(index: idx, highlight: false)
        case .markdown:
            guard let scroll = MarkdownEditorView.lastScrollView else { return }
            guard let line = HeadingParser.lineForHeading(markdown: document.markdown, headingIndex: idx) else { return }
            MarkdownEditorView.scrollToLine(line, in: scroll, highlight: false)
        }
    }

    private func selectHeading(_ index: Int) {
        document.setOutlineSyncedHeadingIndex(index)
        NSLog(
            "HiMD-OUTLINE swift selectHeading index=%d editMode=%@",
            index,
            document.editMode == .html ? "html" : "markdown"
        )
        if document.editMode == .html {
            webCoordinator.scrollToHeading(index: index)
        } else {
            document.scrollMarkdownToHeading(headingIndex: index)
        }
    }

    private func findInMarkdown(_ query: String) {
        guard !query.isEmpty else { return }
        let md = document.markdown
        let start = markdownFindStart ?? md.startIndex
        let rangeFromStart: Range<String.Index>? = md.range(of: query, range: start..<md.endIndex)
        let chosen: Range<String.Index>?
        if let r = rangeFromStart {
            chosen = r
        } else if let r = md.range(of: query) {
            chosen = r
        } else {
            markdownFindStart = nil
            return
        }
        guard let range = chosen else { return }
        markdownFindStart = range.upperBound
        let prefix = md[..<range.lowerBound]
        let line = prefix.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        if let scroll = MarkdownEditorView.lastScrollView {
            MarkdownEditorView.scrollToLine(max(0, line), in: scroll)
        }
    }

    private func saveDocument() {
        if document.editMode == .html {
            webCoordinator.getMarkdown { md in
                Task { @MainActor in
                    document.markdown = md
                    do {
                        try document.saveIfNeededUntitled()
                    } catch {
                        /* user cancelled save panel */
                    }
                }
            }
        } else {
            do {
                try document.saveIfNeededUntitled()
            } catch {
                /* cancel */
            }
        }
    }

    private func saveAsDocument() {
        let alert = NSAlert()
        alert.messageText = "Save As"
        alert.informativeText = "Choose export format."
        alert.addButton(withTitle: "Markdown")
        alert.addButton(withTitle: "HTML")
        alert.addButton(withTitle: "Cancel")
        let r = alert.runModal()
        if r == .alertThirdButtonReturn { return }
        if r == .alertFirstButtonReturn {
            if document.editMode == .html {
                webCoordinator.getMarkdown { md in
                    Task { @MainActor in
                        document.markdown = md
                        try? document.saveAsMarkdownCopy()
                    }
                }
            } else {
                try? document.saveAsMarkdownCopy()
            }
        } else {
            webCoordinator.getHTMLSnapshot(title: document.displayName) { html in
                Task { @MainActor in
                    let data = html.data(using: .utf8) ?? Data()
                    try? document.saveAsHTML(data: data)
                }
            }
        }
    }

    private func attemptNew() {
        guardUnsaved {
            document.newDocument()
            document.editMode = userSettings.defaultEditMode
            webCoordinator.reloadFromDocument()
        }
    }

    private func attemptOpen() {
        guardUnsaved {
            guard let url = document.openPanelURL() else { return }
            try? document.loadFromURL(url)
            document.editMode = userSettings.defaultEditMode
            webCoordinator.reloadFromDocument()
        }
    }

    private func attemptOpenURL(_ url: URL) {
        guardUnsaved {
            DispatchQueue.main.async {
                try? document.loadFromURL(url)
                document.editMode = userSettings.defaultEditMode
                webCoordinator.reloadFromDocument()
            }
        }
    }

    private func guardUnsaved(_ action: @escaping () -> Void) {
        guard document.isDirty else {
            action()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes?"
        alert.informativeText = "Changes will be lost if you don’t save."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        let r = alert.runModal()
        switch r {
        case .alertFirstButtonReturn:
            if document.editMode == .html {
                webCoordinator.getMarkdown { md in
                    Task { @MainActor in
                        document.markdown = md
                        do {
                            try document.saveIfNeededUntitled()
                            action()
                        } catch { /* cancel */ }
                    }
                }
            } else {
                do {
                    try document.saveIfNeededUntitled()
                    action()
                } catch { /* cancel */ }
            }
        case .alertSecondButtonReturn:
            action()
        default:
            break
        }
    }
}
