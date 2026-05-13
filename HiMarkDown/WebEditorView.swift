import SwiftUI
import WebKit

@MainActor
final class WebEditorCoordinator: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Last-seen instance, exposed for the smoke-test scenario runner. Real
    /// view code accesses the coordinator via `@StateObject`.
    static weak var shared: WebEditorCoordinator?

    weak var document: DocumentModel?
    weak var webView: WKWebView?
    private var themeJSON: String = AppTheme.default.cssVariablesJSON(includeColors: AppTheme.userHasCustomColors)

    override init() {
        super.init()
        Self.shared = self
    }

    /// Tiptap's `onUpdate` fires whenever content changes, *including* our own
    /// programmatic `setContent` calls. To avoid those echo "dirty" messages
    /// flipping `document.isDirty` to true (and prompting the user to save a
    /// document they never edited), we ignore any `dirty` arriving inside this
    /// short window after a native push.
    private var suppressEchoUntil: Date = .distantPast
    private static let echoSuppressionWindow: TimeInterval = 1.5

    func setThemeJSON(_ json: String) {
        themeJSON = json
        injectTheme()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }
        switch type {
        case "ready":
            pushFullState()
        case "dirty":
            if Date() < suppressEchoUntil { return }
            pullMarkdownFromWeb()
        case "undo":
            document?.performUndo()
        case "redo":
            document?.performRedo()
        case "openMarkdown":
            NotificationCenter.default.post(name: .hiOpenDocument, object: nil)
        case "jsError":
            // Forward web-editor JS errors into Swift's logging so the smoke
            // harness can fail the run when the WebView is silently broken.
            let payload = (body["payload"] as? [String: Any]) ?? [:]
            let where_ = payload["where"] as? String ?? "?"
            let msg = payload["message"] as? String ?? "?"
            NSLog("HiMD-JS-ERROR [\(where_)] \(msg)")
        case "outlineTrace":
            // Debug: outline click → scroll/highlight path in the WebView.
            // Filter Console.app with: HiMD-OUTLINE
            let p = (body["payload"] as? [String: Any]) ?? [:]
            NSLog("HiMD-OUTLINE js %@", (p as NSDictionary).description)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        injectTheme()
        pushFullState()
    }

    private func pushFullState() {
        reloadFromDocument()
    }

    func reloadFromDocument(completion: (() -> Void)? = nil) {
        guard let webView, let document else { completion?(); return }
        suppressEchoUntil = Date().addingTimeInterval(Self.echoSuppressionWindow)
        document.noteMarkdownPushedToWeb()
        let md = document.markdown.jsEscaped
        webView.evaluateJavaScript("window.__HiMD?.setMarkdown(\"\(md)\")") { _, _ in
            // setMarkdown finished evaluating; the editor has the new content
            // and `notifyHeadings` has fired. Hop back to the main actor for
            // any post-load work (e.g. anchor restore on mode switch).
            DispatchQueue.main.async { completion?() }
        }
    }

    private func injectTheme() {
        guard let webView else { return }
        let t = themeJSON.jsEscaped
        webView.evaluateJavaScript("window.__HiMD?.applyTheme(\"\(t)\")", completionHandler: nil)
    }

    func pullMarkdownFromWeb() {
        guard let webView, let document else { return }
        webView.evaluateJavaScript("window.__HiMD.getMarkdown()", completionHandler: { result, _ in
            guard let text = result as? String else { return }
            Task { @MainActor in
                document.absorbWebMarkdown(text)
            }
        })
    }

    func getMarkdown(completion: @escaping (String) -> Void) {
        guard let webView else {
            completion("")
            return
        }
        webView.evaluateJavaScript("window.__HiMD.getMarkdown()", completionHandler: { result, _ in
            Task { @MainActor in
                completion((result as? String) ?? "")
            }
        })
    }

    func getHTMLSnapshot(title: String, completion: @escaping (String) -> Void) {
        guard let webView else {
            completion("")
            return
        }
        let t = title.jsEscaped
        webView.evaluateJavaScript("window.__HiMD.getHTMLSnapshot(\"\(t)\")", completionHandler: { result, _ in
            Task { @MainActor in
                completion((result as? String) ?? "")
            }
        })
    }

    func scrollToHeading(index: Int, highlight: Bool = true) {
        NSLog(
            "HiMD-OUTLINE swift scrollToHeading index=%d highlight=%@ webView=%@",
            index,
            highlight ? "true" : "false",
            webView != nil ? "yes" : "nil"
        )
        guard let webView else {
            NSLog("HiMD-OUTLINE swift scrollToHeading aborted (no webView)")
            return
        }
        let opts = "{ highlight: \(highlight ? "true" : "false") }"
        let js = "window.__HiMD.scrollToHeadingIndex(\(index), \(opts))"
        webView.evaluateJavaScript(js) { result, error in
            if let error {
                NSLog("HiMD-OUTLINE swift evaluateJavaScript error: %@", String(describing: error))
            } else {
                NSLog("HiMD-OUTLINE swift evaluateJavaScript return: %@", String(describing: result ?? "nil"))
            }
        }
    }

    /// Async query for the heading index closest to the top of the WebView's
    /// viewport. Used to capture the user's reading position before a mode
    /// switch so the markdown editor can restore it.
    func getTopVisibleHeadingIndex(_ completion: @escaping (Int?) -> Void) {
        guard let webView else { completion(nil); return }
        webView.evaluateJavaScript("window.__HiMD?.getTopVisibleHeadingIndex?.() ?? -1") { result, _ in
            let idx = (result as? Int) ?? -1
            DispatchQueue.main.async { completion(idx >= 0 ? idx : nil) }
        }
    }

    func replaceFirst(search: String, replacement: String) {
        guard let webView else { return }
        let s = search.jsEscaped
        let r = replacement.jsEscaped
        webView.evaluateJavaScript(
            "window.__HiMD.replaceInMarkdownFirst(\"\(s)\", \"\(r)\")",
            completionHandler: nil
        )
    }

    func replaceAll(search: String, replacement: String) {
        guard let webView else { return }
        let s = search.jsEscaped
        let r = replacement.jsEscaped
        webView.evaluateJavaScript(
            "window.__HiMD.replaceInMarkdownAll(\"\(s)\", \"\(r)\")",
            completionHandler: nil
        )
    }

    func findInPage(_ query: String, completion: @escaping (Bool) -> Void) {
        guard let webView, !query.isEmpty else {
            completion(false)
            return
        }
        let config = WKFindConfiguration()
        config.wraps = true
        webView.find(query, configuration: config) { result in
            Task { @MainActor in
                completion(result.matchFound)
            }
        }
    }
}

private extension String {
    var jsEscaped: String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

struct WebEditorView: NSViewRepresentable {
    @ObservedObject var document: DocumentModel
    var coordinator: WebEditorCoordinator

    init(document: DocumentModel, coordinator: WebEditorCoordinator) {
        self.document = document
        self.coordinator = coordinator
    }

    func makeCoordinator() -> WebEditorCoordinator {
        coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "native")

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView
        context.coordinator.document = document

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.document = document
        context.coordinator.webView = webView
    }
}
