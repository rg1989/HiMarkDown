import AppKit
import OSLog
import SwiftUI

extension Notification.Name {
    static let hiThemeChanged = Notification.Name("hiThemeChanged")
}

/// Always-on logger so the smoke harness can grep `HiMD-*` markers regardless
/// of unified-log default filtering for sandboxed apps. Writes to subsystem
/// "dev.himarkdown.HiMarkDown" with category "smoke" at .default level.
let hiLog = Logger(subsystem: "dev.himarkdown.HiMarkDown", category: "smoke")

@MainActor
final class HiAppDelegate: NSObject, NSApplicationDelegate {
    static weak var document: DocumentModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hiLog.notice("HiMD-LIFE applicationDidFinishLaunching args=\(ProcessInfo.processInfo.arguments, privacy: .public)")
        NSLog("HiMD-LIFE applicationDidFinishLaunching args=\(ProcessInfo.processInfo.arguments)")
        // Smoke-test affordance: when launched with `--himd-smoke[=N]` we log
        // dirty state after N seconds (default 4) and exit cleanly. A
        // companion `--himd-smoke-file=PATH` arg loads a fixture without
        // depending on AppleEvents-based openFiles delivery (which `open
        // --args` swallows). Lets a test harness assert real app state
        // without Accessibility / AppleEvents permission.
        let args = ProcessInfo.processInfo.arguments
        guard let raw = args.first(where: { $0.hasPrefix("--himd-smoke") && !$0.hasPrefix("--himd-smoke-file") }) else { return }
        let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
        let delay = Double(parts.count > 1 ? parts[1] : "4") ?? 4
        hiLog.notice("HiMD-SMOKE armed delay=\(delay, privacy: .public)s")
        NSLog("HiMD-SMOKE armed delay=\(delay)s")

        if let fileArg = args.first(where: { $0.hasPrefix("--himd-smoke-file=") }) {
            let path = String(fileArg.dropFirst("--himd-smoke-file=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let url = URL(fileURLWithPath: path)
                NotificationCenter.default.post(name: .hiOpenFiles, object: url)
            }
        }

        // Optional scenario hooks. Drive the UndoManager round-trip from
        // Swift directly (no UI events needed) so the harness can assert
        // deterministic before/after snapshots. Wait for the fixture to
        // finish loading (headings parsed, web view rendered) before
        // running so the scenarios see real document state.
        let scenarios = args.filter { $0.hasPrefix("--himd-smoke-scenario=") }
            .map { String($0.dropFirst("--himd-smoke-scenario=".count)) }
        if !scenarios.isEmpty {
            Self.waitForDocLoaded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Self.runScenarios(scenarios)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let dirty = HiAppDelegate.document?.isDirty ?? false
            let title = HiAppDelegate.document?.displayName ?? "?"
            let mdLen = HiAppDelegate.document?.markdown.count ?? -1
            hiLog.notice("HiMD-SMOKE-RESULT title=\(title, privacy: .public) isDirty=\(dirty, privacy: .public) markdownLen=\(mdLen, privacy: .public)")
            NSLog("HiMD-SMOKE-RESULT title=\(title) isDirty=\(dirty) markdownLen=\(mdLen)")
            exit(dirty ? 99 : 0)
        }
    }

    private static func waitForDocLoaded(timeout: TimeInterval = 8, _ done: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func tick() {
            if let doc = HiAppDelegate.document,
               !doc.markdown.isEmpty,
               !doc.headings.isEmpty {
                done()
                return
            }
            if Date() > deadline {
                hiLog.notice("HiMD-SMOKE waitForDocLoaded TIMEOUT mdLen=\(HiAppDelegate.document?.markdown.count ?? -1, privacy: .public) headings=\(HiAppDelegate.document?.headings.count ?? -1, privacy: .public)")
                done()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: tick)
        }
        tick()
    }

    private static func runScenarios(_ scenarios: [String]) {
        guard HiAppDelegate.document != nil else {
            hiLog.notice("HiMD-SMOKE-SCENARIO no-document")
            return
        }
        runNextScenario(scenarios, index: 0)
    }

    private static func runNextScenario(_ scenarios: [String], index: Int) {
        guard index < scenarios.count else {
            hiLog.notice("HiMD-SMOKE-SCENARIO all-done count=\(scenarios.count, privacy: .public)")
            return
        }
        guard let doc = HiAppDelegate.document else { return }
        let s = scenarios[index]
        let next = { runNextScenario(scenarios, index: index + 1) }
        switch s {
        case "undo-roundtrip":
            let original = doc.markdown
            hiLog.notice("HiMD-SMOKE-SCENARIO undo-roundtrip step=before len=\(original.count, privacy: .public)")
            doc.userEditedMarkdown(original + "\n\nINJECTED EDIT.\n")
            doc.flushPendingUndo()
            let afterEdit = doc.markdown
            hiLog.notice("HiMD-SMOKE-SCENARIO undo-roundtrip step=edited len=\(afterEdit.count, privacy: .public) dirty=\(doc.isDirty, privacy: .public) canUndo=\(doc.undoManager.canUndo, privacy: .public)")
            doc.performUndo()
            let restoredOK = doc.markdown == original
            hiLog.notice("HiMD-SMOKE-SCENARIO undo-roundtrip step=undone len=\(doc.markdown.count, privacy: .public) dirty=\(doc.isDirty, privacy: .public) restoredOK=\(restoredOK, privacy: .public)")
            doc.performRedo()
            let redoOK = doc.markdown == afterEdit
            hiLog.notice("HiMD-SMOKE-SCENARIO undo-roundtrip step=redone len=\(doc.markdown.count, privacy: .public) redoOK=\(redoOK, privacy: .public)")
            doc.performUndo()
            hiLog.notice("HiMD-SMOKE-SCENARIO undo-roundtrip step=final len=\(doc.markdown.count, privacy: .public) dirty=\(doc.isDirty, privacy: .public)")
            next()

        case "outline-scroll":
            guard let coord = WebEditorCoordinator.shared else {
                hiLog.notice("HiMD-SMOKE-SCENARIO outline-scroll no-coordinator")
                next()
                return
            }
            doc.setMarkdownProgrammatically(Self.syntheticTallMarkdown())
            coord.reloadFromDocument {
                let target = min(3, max(0, doc.headings.count - 1))
                hiLog.notice("HiMD-SMOKE-SCENARIO outline-scroll target=\(target, privacy: .public) headings=\(doc.headings.count, privacy: .public)")
                coord.scrollToHeading(index: target, highlight: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    coord.getTopVisibleHeadingIndex { observed in
                        let ok = observed == target
                        hiLog.notice("HiMD-SMOKE-SCENARIO outline-scroll observed=\(observed ?? -1, privacy: .public) target=\(target, privacy: .public) anchorOK=\(ok, privacy: .public)")
                        next()
                    }
                }
            }

        case "scroll-parity":
            guard let coord = WebEditorCoordinator.shared else {
                hiLog.notice("HiMD-SMOKE-SCENARIO scroll-parity no-coordinator")
                next()
                return
            }
            doc.setMarkdownProgrammatically(Self.syntheticTallMarkdown())
            // Make sure we start in HTML mode so the parity test is
            // meaningful (HTML scroll → switch → markdown anchor).
            doc.editMode = .html
            coord.reloadFromDocument {
                let target = min(5, max(0, doc.headings.count - 1))
                coord.scrollToHeading(index: target, highlight: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    coord.getTopVisibleHeadingIndex { htmlObserved in
                        hiLog.notice("HiMD-SMOKE-SCENARIO scroll-parity html-anchor=\(htmlObserved ?? -1, privacy: .public) target=\(target, privacy: .public)")
                        // Same handoff the toolbar Picker uses: stash
                        // anchor on the document, flip mode, ContentView's
                        // syncModeSwitch picks it up and scrolls.
                        doc.preferredAnchorHeadingIndex = htmlObserved
                        doc.editMode = .markdown
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            guard let scroll = MarkdownEditorView.lastScrollView else {
                                hiLog.notice("HiMD-SMOKE-SCENARIO scroll-parity no-md-scrollview parityOK=false")
                                next()
                                return
                            }
                            let md = MarkdownEditorView.topVisibleHeadingIndex(in: scroll, headings: doc.headings)
                            // Off-by-one tolerance: the markdown editor and
                            // the rendered HTML anchor at slightly
                            // different points within the same section.
                            let ok = (md ?? -1) >= max(0, target - 1) && (md ?? -1) <= target + 1
                            hiLog.notice("HiMD-SMOKE-SCENARIO scroll-parity md-anchor=\(md ?? -1, privacy: .public) target=\(target, privacy: .public) parityOK=\(ok, privacy: .public)")
                            next()
                        }
                    }
                }
            }

        default:
            hiLog.notice("HiMD-SMOKE-SCENARIO unknown=\(s, privacy: .public)")
            next()
        }
    }

    private static func syntheticTallMarkdown() -> String {
        let body = (1...8).map { i in
            "## Section \(i)\n\n" + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n\n", count: 8)
        }.joined()
        return "# Tall Demo\n\n" + body
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.compactMap { URL(fileURLWithPath: $0) }
        guard let first = urls.first else { return }
        NotificationCenter.default.post(name: .hiOpenFiles, object: first)
        NSApp.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSLog("HiMD-TERMINATE applicationShouldTerminate isDirty=\(HiAppDelegate.document?.isDirty ?? false)")
        guard let doc = HiAppDelegate.document, doc.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to “\(doc.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            do {
                try doc.saveIfNeededUntitled()
                return .terminateNow
            } catch is CancellationError {
                return .terminateCancel
            } catch {
                return .terminateCancel
            }
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

@main
struct HiMarkDownApp: App {
    @NSApplicationDelegateAdaptor(HiAppDelegate.self) private var appDelegate
    @StateObject private var document = DocumentModel()
    @StateObject private var userSettings = UserSettings()
    @StateObject private var webCoordinator = WebEditorCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(webCoordinator: webCoordinator)
                .environmentObject(document)
                .environmentObject(userSettings)
                .preferredColorScheme(userSettings.preferredColorScheme)
                .onAppear {
                    HiAppDelegate.document = document
                    DispatchQueue.main.async {
                        document.applyDefaultModeFromSettings(userSettings)
                        document.updateHeadingsFromMarkdown()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { NotificationCenter.default.post(name: .hiNewDocument, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("Open…") { NotificationCenter.default.post(name: .hiOpenDocument, object: nil) }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { NotificationCenter.default.post(name: .hiSaveDocument, object: nil) }
                    .keyboardShortcut("s", modifiers: [.command])
            }
            CommandGroup(after: .saveItem) {
                Button("Save As…") { NotificationCenter.default.post(name: .hiSaveAsDocument, object: nil) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { document.performUndo() }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("Redo") { document.performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .undoRedo) {
                Button("Find…") { NotificationCenter.default.post(name: .hiFind, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command])
            }
        }
        Settings {
            SettingsView()
                .environmentObject(userSettings)
        }
    }
}

extension Notification.Name {
    static let hiNewDocument = Notification.Name("hiNewDocument")
    static let hiOpenDocument = Notification.Name("hiOpenDocument")
    static let hiSaveDocument = Notification.Name("hiSaveDocument")
    static let hiSaveAsDocument = Notification.Name("hiSaveAsDocument")
    static let hiFind = Notification.Name("hiFind")
}
