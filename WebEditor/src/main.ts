import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { Markdown } from "@tiptap/markdown";

type NativePayload = { type?: string; payload?: unknown };

let editor: Editor | null = null;

function native() {
  return (window as any).webkit?.messageHandlers?.native;
}

function post(type: string, payload?: unknown) {
  try {
    native()?.postMessage({ type, payload } satisfies NativePayload);
  } catch {
    /* ignore */
  }
}

/** Forward to native so you can filter Console for `HiMD-OUTLINE`. */
function traceOutline(fields: Record<string, string | number | boolean | undefined | null>) {
  post("outlineTrace", fields);
}

function syncWelcomeVisibility(md: string) {
  const empty = !md || md.trim().length === 0;
  document.body.classList.toggle("hm-welcome-visible", empty);
}

function initWelcomePanel() {
  document.getElementById("hm-open-md")?.addEventListener("click", () => {
    post("openMarkdown");
  });
}

// Forward JS errors / console.error to native so the smoke harness can grep
// the unified log for them. Without this, WKWebView's JS console is invisible
// to anyone running the app outside an attached Web Inspector.
function reportError(where: string, err: unknown) {
  const msg = err instanceof Error ? `${err.name}: ${err.message}\n${err.stack ?? ""}` : String(err);
  post("jsError", { where, message: msg });
  try {
    (console as any)._origError?.(`[HiMD ${where}]`, err);
  } catch {
    /* ignore */
  }
}
try {
  const orig = console.error.bind(console);
  (console as any)._origError = orig;
  console.error = ((...args: unknown[]) => {
    try { post("jsError", { where: "console.error", message: args.map(String).join(" ") }); } catch { /* ignore */ }
    orig(...args);
  }) as typeof console.error;
  window.addEventListener("error", (e) => reportError("window.error", e.error ?? e.message));
  window.addEventListener("unhandledrejection", (e) => reportError("unhandledrejection", e.reason));
} catch {
  /* ignore */
}

function collectHeadings(): { index: number; level: number; text: string }[] {
  if (!editor) return [];
  const headings: { index: number; level: number; text: string }[] = [];
  let idx = 0;
  editor.state.doc.descendants((node) => {
    if (node.type.name === "heading") {
      headings.push({
        index: idx++,
        level: node.attrs.level as number,
        text: node.textContent,
      });
    }
  });
  return headings;
}

function assignHeadingDomIds() {
  const root = document.getElementById("editor");
  if (!root) return;
  const hs = root.querySelectorAll("h1,h2,h3,h4,h5,h6");
  hs.forEach((h, i) => {
    h.id = `hm-h-${i}`;
  });
}

function notifyHeadings() {
  post("headings", collectHeadings());
  requestAnimationFrame(() => assignHeadingDomIds());
}

function applyTheme(json: string) {
  try {
    const t = JSON.parse(json) as Record<string, string>;
    const root = document.documentElement;
    for (const [k, v] of Object.entries(t)) {
      root.style.setProperty(k, v);
    }
  } catch {
    /* ignore */
  }
}

function removeOutlineFlash() {
  document.getElementById("hm-outline-flash")?.remove();
}

/**
 * Yellow pulse like the Markdown `showFindIndicator` flash. Must not attach
 * `hm-blink` directly to a ProseMirror heading node — the next DOM reconcile
 * strips arbitrary classes/attributes from managed nodes, so the animation
 * never appeared in WKWebView. A fixed overlay on `document.body` is immune.
 */
function flashHeadingHighlight(target: HTMLElement) {
  removeOutlineFlash();
  const r = target.getBoundingClientRect();
  if (r.width <= 0 && r.height <= 0) {
    traceOutline({ step: "flash-skip-zero-rect", w: r.width, h: r.height });
    return;
  }
  const pad = 4;
  const flash = document.createElement("div");
  flash.id = "hm-outline-flash";
  flash.setAttribute("aria-hidden", "true");
  flash.style.position = "fixed";
  flash.style.left = `${r.left - pad}px`;
  flash.style.top = `${r.top - pad}px`;
  flash.style.width = `${r.width + pad * 2}px`;
  flash.style.height = `${Math.max(r.height, 12) + pad * 2}px`;
  flash.style.pointerEvents = "none";
  flash.style.zIndex = "2147483647";
  flash.style.boxSizing = "border-box";
  flash.style.borderRadius = "8px";
  flash.style.animation = "hm-blink-keyframes 1.4s ease-out 1 forwards";
  document.body.appendChild(flash);
  traceOutline({
    step: "flash-appended",
    left: r.left - pad,
    top: r.top - pad,
    w: r.width + pad * 2,
    h: Math.max(r.height, 12) + pad * 2,
    anim: flash.style.animation,
    bodyChildCount: document.body.children.length,
  });
  window.setTimeout(removeOutlineFlash, 1600);
}

/** Re-assign ids and look up the Nth heading by stable outline index. */
function headingElForIndex(index: number): HTMLElement | null {
  assignHeadingDomIds();
  const root = document.getElementById("editor");
  return root?.querySelector(`#hm-h-${index}`) as HTMLElement | null;
}

/** Returns a short sync summary string for Swift `evaluateJavaScript` completion. */
function scrollToHeadingIndex(index: number, opts?: { highlight?: boolean }): string {
  const highlight = opts?.highlight !== false;
  const hi = (window as any).__HiMD;
  traceOutline({
    step: "enter",
    index,
    highlight,
    hasNative: !!native(),
    hasHiMD: !!hi,
    hasScrollToHeadingIndex: typeof hi?.scrollToHeadingIndex === "function",
    scrollY: window.scrollY,
    innerH: window.innerHeight,
    headingCount: document.getElementById("editor")?.querySelectorAll("h1,h2,h3,h4,h5,h6").length ?? -1,
  });
  const root = document.getElementById("editor");
  if (!root) {
    traceOutline({ step: "abort-no-editor-root" });
    return "no-root";
  }
  let el = headingElForIndex(index);
  if (!el) {
    traceOutline({ step: "abort-no-heading-el", index });
    return "no-el";
  }
  // Instant scroll (not "smooth") so the blink animation is synchronized
  // with the moment the heading lands at the top — otherwise a long scroll
  // can outlast the 1.4s blink and the user never sees the highlight.
  const rect = el.getBoundingClientRect();
  const targetY = window.scrollY + rect.top - 60;
  window.scrollTo({ top: Math.max(0, targetY), behavior: "auto" });
  traceOutline({
    step: "after-scroll",
    targetY,
    rectT: rect.top,
    rectL: rect.left,
    rectW: rect.width,
    rectH: rect.height,
    scrollYAfter: window.scrollY,
  });
  if (!highlight) {
    traceOutline({ step: "highlight-skipped" });
    return "ok-no-highlight";
  }
  // ProseMirror often replaces heading DOM nodes after a scroll/layout pass.
  // Holding a stale `Element` reference yields getBoundingClientRect() = 0
  // (detached node). Always re-resolve by id after rAF before flashing.
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      let fresh = headingElForIndex(index);
      if (!fresh) {
        traceOutline({ step: "raf2-no-el-after-remount", index });
        return;
      }
      let r2 = fresh.getBoundingClientRect();
      if (r2.width <= 0 && r2.height <= 0) {
        traceOutline({ step: "raf2-zero-rect-scrollIntoView", index });
        fresh.scrollIntoView({ block: "start", behavior: "auto" });
        requestAnimationFrame(() => {
          fresh = headingElForIndex(index);
          if (!fresh) {
            traceOutline({ step: "raf3-no-el", index });
            return;
          }
          r2 = fresh.getBoundingClientRect();
          traceOutline({
            step: "raf3-before-flash",
            rectT: r2.top,
            rectL: r2.left,
            rectW: r2.width,
            rectH: r2.height,
            scrollY: window.scrollY,
          });
          flashHeadingHighlight(fresh);
        });
        return;
      }
      traceOutline({
        step: "raf2-before-flash",
        rectT: r2.top,
        rectL: r2.left,
        rectW: r2.width,
        rectH: r2.height,
        scrollY: window.scrollY,
      });
      flashHeadingHighlight(fresh);
    });
  });
  return "ok-scheduled-flash";
}

/// Returns the heading index whose rendered position is at-or-above the top
/// of the current viewport. Used to keep scroll position roughly synced when
/// the user toggles between HTML and Markdown modes.
function getTopVisibleHeadingIndex(): number {
  const root = document.getElementById("editor");
  if (!root) return -1;
  assignHeadingDomIds();
  const hs = Array.from(root.querySelectorAll("h1,h2,h3,h4,h5,h6"));
  if (hs.length === 0) return -1;
  // 80px slop so a heading that is *just* above the top still counts as the
  // anchor — matches the visual "I was reading this section" intuition.
  const threshold = 80;
  let best = -1;
  for (let i = 0; i < hs.length; i++) {
    const r = hs[i].getBoundingClientRect();
    if (r.top <= threshold) {
      best = i;
    } else {
      break;
    }
  }
  return best;
}

function getResolvedCss(): string {
  const el = document.getElementById("editor-styles");
  return el?.textContent ?? "";
}

function buildHtmlDocument(title: string, bodyInner: string): string {
  const css = getResolvedCss();
  const rootCss = document.documentElement.style.cssText;
  return `<!DOCTYPE html>
<html lang="en" style="${escapeHtml(rootCss)}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(title)}</title>
<style>
${css}
body { margin: 0; padding: 24px; box-sizing: border-box; }
</style>
</head>
<body>
<div class="tiptap ProseMirror hm-export-root">
${bodyInner}
</div>
</body>
</html>`;
}

function escapeHtml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function initEditor() {
  if (editor) return;
  const el = document.getElementById("editor");
  if (!el) return;

  editor = new Editor({
    element: el,
    // Disable Tiptap's per-WebView History extension. Undo/redo is owned by
    // Swift's document-level UndoManager so that an HTML-mode edit and a
    // Markdown-mode edit live on the same stack. Cmd-Z is intercepted in the
    // keydown listener below and forwarded to native.
    extensions: [StarterKit.configure({ history: false } as any), Markdown],
    content: "",
    contentType: "markdown",
    autofocus: false,
    editorProps: {
      attributes: {
        class: "tiptap ProseMirror",
        spellcheck: "false",
      },
    },
    onUpdate() {
      post("dirty");
      notifyHeadings();
    },
    onCreate() {
      notifyHeadings();
    },
  });

  post("ready");
}

// Forward Cmd-Z / Cmd-Shift-Z / Cmd-Y to native so the document-level
// UndoManager runs. preventDefault stops ProseMirror from doing anything,
// which it otherwise would even with History disabled (ProseMirror's
// keymapBaseKeymap binds these by default for some platforms).
document.addEventListener("keydown", (e) => {
  if (!e.metaKey) return;
  const key = e.key.toLowerCase();
  if (key === "z" && !e.shiftKey) {
    e.preventDefault();
    e.stopPropagation();
    post("undo");
  } else if ((key === "z" && e.shiftKey) || key === "y") {
    e.preventDefault();
    e.stopPropagation();
    post("redo");
  }
}, true);

function setMarkdown(md: string) {
  try {
    initEditor();
    if (!editor) return;
    editor.commands.setContent(md, { contentType: "markdown" });
  } catch (err) {
    reportError("setMarkdown.setContent", err);
    return;
  }
  // Tiptap's History extension is disabled (see initEditor) because undo is
  // owned by Swift's document UndoManager, so there's no per-WebView undo
  // stack that could cross a file-load boundary. Nothing to clear here.
  try {
    assignHeadingDomIds();
    notifyHeadings();
  } catch (err) {
    reportError("setMarkdown.notifyHeadings", err);
  }
  syncWelcomeVisibility(md);
}

function getMarkdown(): string {
  return editor?.getMarkdown() ?? "";
}

function getHTMLBody(): string {
  return editor?.getHTML() ?? "";
}

function getHTMLSnapshot(title: string): string {
  return buildHtmlDocument(title || "Document", getHTMLBody());
}

function replaceInMarkdownAll(search: string, replacement: string) {
  if (!editor || !search) return;
  const md = editor.getMarkdown();
  const next = md.split(search).join(replacement);
  editor.commands.setContent(next, { contentType: "markdown" });
  post("dirty");
  notifyHeadings();
}

function replaceInMarkdownFirst(search: string, replacement: string) {
  if (!editor || !search) return;
  const md = editor.getMarkdown();
  const idx = md.indexOf(search);
  if (idx < 0) return;
  const next = md.slice(0, idx) + replacement + md.slice(idx + search.length);
  editor.commands.setContent(next, { contentType: "markdown" });
  post("dirty");
  notifyHeadings();
}

(window as any).__HiMD = {
  init: initEditor,
  setMarkdown,
  getMarkdown,
  getHTMLBody,
  getHTMLSnapshot,
  applyTheme,
  scrollToHeadingIndex,
  getTopVisibleHeadingIndex,
  replaceInMarkdownFirst,
  replaceInMarkdownAll,
};

document.addEventListener("DOMContentLoaded", () => {
  initWelcomePanel();
  initEditor();
  syncWelcomeVisibility(getMarkdown());
});
