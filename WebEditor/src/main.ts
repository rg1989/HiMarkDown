import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { Markdown } from "@tiptap/markdown";
import { HiCodeBlock } from "./mermaidCodeBlock";
import { TableKit } from "@tiptap/extension-table";

type NativePayload = { type?: string; payload?: unknown };

let editor: Editor | null = null;

/** Last markdown we told native about; suppresses spurious `dirty` when PM docChanged but serialization is unchanged. */
let lastSerializedMarkdown: string | null = null;
/** True while Swift is pushing markdown into the editor (avoid echo `dirty`). */
let suppressDirtyEcho = false;

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

/** ProseMirror positions of heading nodes, in document order (same index as `collectHeadings`). */
function headingNodePositionsInDoc(): number[] {
  if (!editor) return [];
  const positions: number[] = [];
  editor.state.doc.descendants((node, pos) => {
    if (node.type.name === "heading") {
      positions.push(pos);
      return false;
    }
    return true;
  });
  return positions;
}

function domElForHeadingPos(pos: number): HTMLElement | null {
  if (!editor) return null;
  const d = editor.view.nodeDOM(pos);
  if (d instanceof HTMLElement) return d;
  if (d && (d as Node).nodeType === Node.TEXT_NODE) return (d as Text).parentElement;
  return null;
}

function domHeadingAtOutlineIndex(index: number): HTMLElement | null {
  const positions = headingNodePositionsInDoc();
  if (index < 0 || index >= positions.length) return null;
  return domElForHeadingPos(positions[index]!);
}

function notifyHeadings() {
  post("headings", collectHeadings());
  scheduleScrollHeadingReport();
}

let scrollHeadingRaf = 0;
/** Last outline index posted to native; avoids hammering SwiftUI on every scroll tick. */
let lastPostedScrollHeadingIndex = -9999;
function scheduleScrollHeadingReport() {
  if (scrollHeadingRaf !== 0) return;
  scrollHeadingRaf = requestAnimationFrame(() => {
    scrollHeadingRaf = 0;
    const idx = getTopVisibleHeadingIndex();
    if (idx === lastPostedScrollHeadingIndex) return;
    lastPostedScrollHeadingIndex = idx;
    post("scrollHeading", { index: idx });
  });
}

let scrollHeadingInstalled = false;
function installScrollHeadingReporter() {
  if (scrollHeadingInstalled) return;
  scrollHeadingInstalled = true;
  window.addEventListener("scroll", scheduleScrollHeadingReport, { passive: true });
  window.addEventListener("resize", scheduleScrollHeadingReport, { passive: true });
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
 * Premium outline-jump pulse: fixed overlay (ProseMirror strips ad-hoc DOM).
 * Styling lives in index.html (`.hm-outline-glow` + keyframes using theme vars).
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
  flash.className = "hm-outline-glow";
  flash.setAttribute("aria-hidden", "true");
  flash.style.position = "fixed";
  flash.style.left = `${r.left - pad}px`;
  flash.style.top = `${r.top - pad}px`;
  flash.style.width = `${r.width + pad * 2}px`;
  flash.style.height = `${Math.max(r.height, 12) + pad * 2}px`;
  flash.style.pointerEvents = "none";
  flash.style.zIndex = "2147483647";
  document.body.appendChild(flash);
  traceOutline({
    step: "flash-appended",
    left: r.left - pad,
    top: r.top - pad,
    w: r.width + pad * 2,
    h: Math.max(r.height, 12) + pad * 2,
    bodyChildCount: document.body.children.length,
  });
  window.setTimeout(removeOutlineFlash, 1450);
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
    headingCount: headingNodePositionsInDoc().length,
  });
  const root = document.getElementById("editor");
  if (!root) {
    traceOutline({ step: "abort-no-editor-root" });
    return "no-root";
  }
  let el = domHeadingAtOutlineIndex(index);
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
  // Re-resolve by outline index after rAF before flashing.
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      let fresh = domHeadingAtOutlineIndex(index);
      if (!fresh) {
        traceOutline({ step: "raf2-no-el-after-remount", index });
        return;
      }
      let r2 = fresh.getBoundingClientRect();
      if (r2.width <= 0 && r2.height <= 0) {
        traceOutline({ step: "raf2-zero-rect-scrollIntoView", index });
        fresh.scrollIntoView({ block: "start", behavior: "auto" });
        requestAnimationFrame(() => {
          fresh = domHeadingAtOutlineIndex(index);
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
  if (!editor) return -1;
  const positions = headingNodePositionsInDoc();
  if (positions.length === 0) return -1;
  const threshold = 80;
  let best = -1;
  for (let i = 0; i < positions.length; i++) {
    const el = domElForHeadingPos(positions[i]!);
    if (!el) continue;
    const r = el.getBoundingClientRect();
    if (r.top <= threshold) {
      best = i;
    } else {
      break;
    }
  }
  return best;
}

/** Level + plain text for native to match against `HeadingParser` after canonical markdown. */
function getTopVisibleHeadingAnchor(): { level: number; text: string } | null {
  const idx = getTopVisibleHeadingIndex();
  if (!editor || idx < 0) return null;
  const list = collectHeadings();
  const row = list[idx];
  if (!row) return null;
  return { level: row.level, text: row.text };
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
    extensions: [
      StarterKit.configure({ history: false, codeBlock: false } as any),
      Markdown,
      HiCodeBlock,
      TableKit,
    ],
    content: "",
    contentType: "markdown",
    autofocus: false,
    editorProps: {
      attributes: {
        class: "tiptap ProseMirror",
        spellcheck: "false",
      },
    },
    onUpdate({ transaction }) {
      if (suppressDirtyEcho) return;
      // Selection-only: no native sync.
      if (!transaction.docChanged) return;
      // ProseMirror can report docChanged after benign DOM work; only notify
      // native when serialized markdown actually changed.
      const md = editor!.getMarkdown();
      if (md === lastSerializedMarkdown) return;
      lastSerializedMarkdown = md;
      post("dirty");
      notifyHeadings();
    },
    onCreate() {
      lastSerializedMarkdown = editor?.getMarkdown() ?? "";
      notifyHeadings();
    },
  });

  installScrollHeadingReporter();
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
    suppressDirtyEcho = true;
    try {
      editor.commands.setContent(md, { contentType: "markdown" });
    } finally {
      lastSerializedMarkdown = editor.getMarkdown();
      suppressDirtyEcho = false;
    }
    lastPostedScrollHeadingIndex = -9999;
  } catch (err) {
    reportError("setMarkdown.setContent", err);
    return;
  }
  // Tiptap's History extension is disabled (see initEditor) because undo is
  // owned by Swift's document UndoManager, so there's no per-WebView undo
  // stack that could cross a file-load boundary. Nothing to clear here.
  try {
    notifyHeadings();
  } catch (err) {
    reportError("setMarkdown.notifyHeadings", err);
  }
  syncWelcomeVisibility(md);
  requestAnimationFrame(() => scheduleScrollHeadingReport());
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
}

function replaceInMarkdownFirst(search: string, replacement: string) {
  if (!editor || !search) return;
  const md = editor.getMarkdown();
  const idx = md.indexOf(search);
  if (idx < 0) return;
  const next = md.slice(0, idx) + replacement + md.slice(idx + search.length);
  editor.commands.setContent(next, { contentType: "markdown" });
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
  getTopVisibleHeadingAnchor,
  replaceInMarkdownFirst,
  replaceInMarkdownAll,
};

document.addEventListener("DOMContentLoaded", () => {
  initWelcomePanel();
  initEditor();
  syncWelcomeVisibility(getMarkdown());
});
