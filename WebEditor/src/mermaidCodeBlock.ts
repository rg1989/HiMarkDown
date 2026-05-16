import { mergeAttributes, NodeViewRendererProps } from "@tiptap/core";
import CodeBlock from "@tiptap/extension-code-block";
import { createSyntaxHighlightPlugin } from "./syntaxHighlight";
import { TextSelection } from "@tiptap/pm/state";
import type { Node as PMNode } from "@tiptap/pm/model";
import type { Decoration, DecorationSource, ViewMutationRecord } from "@tiptap/pm/view";
import mermaid from "mermaid";

type HiMode = "preview" | "edit";

/** When set on a `language: mermaid` code block, the node view shows source (edit) instead of the diagram. */
const MERMAID_SOURCE_ATTR = "source";

const ICON_EDIT = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>`;

const ICON_PREVIEW = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>`;

let mermaidBoot = false;
let renderIdSeq = 0;

const themeRefreshers = new Set<() => void>();

function syncMermaidTheme() {
  const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: dark ? "dark" : "default",
    fontFamily: 'var(--md-base-font, ui-sans-serif, system-ui, sans-serif)',
  });
}

function installThemeListenerOnce() {
  if (mermaidBoot) return;
  mermaidBoot = true;
  syncMermaidTheme();
  const mq = window.matchMedia("(prefers-color-scheme: dark)");
  mq.addEventListener("change", () => {
    syncMermaidTheme();
    themeRefreshers.forEach((fn) => {
      try {
        fn();
      } catch {
        /* ignore */
      }
    });
  });
}

function createDebouncedRender(run: () => void, ms: number) {
  let t: ReturnType<typeof setTimeout> | null = null;
  return {
    schedule() {
      if (t !== null) window.clearTimeout(t);
      t = window.setTimeout(() => {
        t = null;
        run();
      }, ms);
    },
    cancel() {
      if (t !== null) {
        window.clearTimeout(t);
        t = null;
      }
    },
  };
}

function applyPreAttrs(
  pre: HTMLElement,
  extension: NodeViewRendererProps["extension"],
  HTMLAttributes: Record<string, unknown>,
) {
  const opts = extension.options as { HTMLAttributes?: Record<string, unknown> };
  const merged = mergeAttributes(opts.HTMLAttributes ?? {}, HTMLAttributes);
  for (const [k, v] of Object.entries(merged)) {
    if (v === false || v == null) pre.removeAttribute(k);
    else pre.setAttribute(k, String(v));
  }
}

function mermaidUiAttr(n: PMNode): string | null | undefined {
  return (n.attrs as { mermaidUi?: string | null }).mermaidUi ?? null;
}

function deriveMode(n: PMNode): HiMode {
  const lang = n.attrs.language as string | null | undefined;
  if (lang !== "mermaid") return "edit";
  return mermaidUiAttr(n) === MERMAID_SOURCE_ATTR ? "edit" : "preview";
}

function createMermaidNodeView(props: NodeViewRendererProps) {
  const { editor, extension, HTMLAttributes } = props;
  const getPos = props.getPos;
  let node: PMNode = props.node;

  const wrap = document.createElement("div");
  wrap.className = "hm-codeblock-wrap";

  const toolbar = document.createElement("div");
  toolbar.className = "hm-mermaid-toolbar";
  toolbar.setAttribute("role", "toolbar");

  const toggleBtn = document.createElement("button");
  toggleBtn.type = "button";
  toggleBtn.className = "hm-mermaid-toggle";

  const preview = document.createElement("div");
  preview.className = "hm-mermaid-preview";
  const chartHost = document.createElement("div");
  chartHost.className = "hm-mermaid-chart-host";
  const errEl = document.createElement("div");
  errEl.className = "hm-mermaid-error";
  errEl.hidden = true;
  preview.appendChild(chartHost);
  preview.appendChild(errEl);

  const pre = document.createElement("pre");
  const code = document.createElement("code");
  pre.appendChild(code);

  let mode: HiMode = deriveMode(node);
  let renderGen = 0;
  let destroyed = false;
  /** Last source we successfully painted (for skipping redundant renders). */
  let lastPaintedSrc = "";

  const debouncedRender = createDebouncedRender(() => {
    void renderMermaidNow();
  }, 160);

  function syncLayout() {
    mode = deriveMode(node);
    const isMer = node.attrs.language === "mermaid";

    if (!isMer) {
      debouncedRender.cancel();
      lastPaintedSrc = "";
      toolbar.hidden = true;
      preview.hidden = true;
      pre.classList.remove("hm-mermaid-source-hidden");
      wrap.classList.remove("hm-mermaid-active");
      return;
    }

    wrap.classList.add("hm-mermaid-active");
    toolbar.hidden = false;

    if (mode === "preview") {
      preview.hidden = false;
      pre.classList.add("hm-mermaid-source-hidden");
      toggleBtn.innerHTML = ICON_EDIT;
      toggleBtn.setAttribute("aria-label", "Edit Mermaid source");
      errEl.hidden = true;
    } else {
      debouncedRender.cancel();
      preview.hidden = true;
      pre.classList.remove("hm-mermaid-source-hidden");
      toggleBtn.innerHTML = ICON_PREVIEW;
      toggleBtn.setAttribute("aria-label", "Show diagram");
      errEl.hidden = true;
    }
  }

  async function renderMermaidNow() {
    if (destroyed || node.attrs.language !== "mermaid" || mode !== "preview") return;
    installThemeListenerOnce();
    const src = node.textContent ?? "";
    const trimmed = src.trim();
    if (trimmed && trimmed === lastPaintedSrc.trim() && chartHost.querySelector("svg")) {
      return;
    }

    renderGen += 1;
    const myGen = renderGen;
    errEl.hidden = true;
    errEl.textContent = "";

    if (!trimmed) {
      lastPaintedSrc = "";
      chartHost.innerHTML = `<p class="hm-mermaid-empty">Empty diagram — switch to edit to add Mermaid syntax.</p>`;
      return;
    }

    chartHost.innerHTML = `<div class="hm-mermaid-loading">Rendering…</div>`;

    try {
      const id = `hm-mer-${++renderIdSeq}`;
      const { svg, bindFunctions } = await mermaid.render(id, src);
      if (destroyed || mode !== "preview" || myGen !== renderGen) return;
      chartHost.innerHTML = svg;
      lastPaintedSrc = src;
      bindFunctions?.(chartHost);
    } catch (e) {
      if (destroyed || mode !== "preview" || myGen !== renderGen) return;
      chartHost.innerHTML = "";
      lastPaintedSrc = "";
      errEl.hidden = false;
      errEl.textContent = e instanceof Error ? e.message : String(e);
    }
  }

  /** After `pointerdown` toggles, ignore the synthetic `click` (keyboard still uses `click` only). */
  let suppressClickUntil = 0;

  function runToggleFromUser() {
    if (node.attrs.language !== "mermaid") return;
    const pos = typeof getPos === "function" ? getPos() : undefined;
    if (pos === undefined) return;
    const doc = editor.state.doc;
    const cur = doc.nodeAt(pos);
    if (!cur || cur.type.name !== "codeBlock") return;

    const atSource = mermaidUiAttr(cur) === MERMAID_SOURCE_ATTR;
    const nextAttrs = { ...cur.attrs, mermaidUi: atSource ? null : MERMAID_SOURCE_ATTR };
    editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, nextAttrs));

    if (!atSource) {
      queueMicrotask(() => {
        try {
          editor.chain().focus().run();
          const d = editor.state.doc;
          const blk = d.nodeAt(pos);
          if (!blk || blk.type.name !== "codeBlock") return;
          const from = pos + 1;
          const to = pos + blk.nodeSize - 1;
          editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(d, from, to)));
        } catch {
          /* ignore */
        }
      });
    }
  }

  function onTogglePointerDownCapture(ev: PointerEvent) {
    if (node.attrs.language !== "mermaid") return;
    if (ev.pointerType === "mouse" && ev.button !== 0) return;
    ev.preventDefault();
    ev.stopPropagation();
    suppressClickUntil = performance.now() + 800;
    runToggleFromUser();
  }

  function onToggleClickCapture(ev: MouseEvent) {
    if (node.attrs.language !== "mermaid") return;
    if (performance.now() < suppressClickUntil) {
      suppressClickUntil = 0;
      ev.preventDefault();
      ev.stopPropagation();
      return;
    }
    ev.preventDefault();
    ev.stopPropagation();
    runToggleFromUser();
  }

  toolbar.appendChild(toggleBtn);
  toggleBtn.addEventListener("pointerdown", onTogglePointerDownCapture, true);
  toggleBtn.addEventListener("click", onToggleClickCapture, true);

  wrap.appendChild(toolbar);
  wrap.appendChild(preview);
  wrap.appendChild(pre);

  applyPreAttrs(pre, extension, HTMLAttributes);

  function syncLanguageClass() {
    const lang = node.attrs.language as string | null | undefined;
    code.className = lang ? `language-${lang}` : "";
  }

  syncLanguageClass();
  syncLayout();

  if (node.attrs.language === "mermaid" && mode === "preview") {
    debouncedRender.schedule();
  }

  const refresh = () => {
    lastPaintedSrc = "";
    if (node.attrs.language === "mermaid" && mode === "preview") void renderMermaidNow();
  };
  themeRefreshers.add(refresh);

  function updateLangAndAttrs(
    next: PMNode,
    decos: readonly Decoration[],
    innerDecos: DecorationSource,
  ): boolean {
    void decos;
    void innerDecos;
    if (next.type.name !== "codeBlock") return false;

    const prevLang = node.attrs.language as string | null | undefined;
    const prevText = node.textContent;
    const prevMermaidUi = mermaidUiAttr(node);
    const nextLang = next.attrs.language as string | null | undefined;
    const nextText = next.textContent;
    const nextMermaidUi = mermaidUiAttr(next);

    node = next;

    const langChanged = prevLang !== nextLang;
    const textChanged = prevText !== nextText;
    const uiChanged = prevMermaidUi !== nextMermaidUi;
    if (!langChanged && !textChanged && !uiChanged) {
      return true;
    }

    applyPreAttrs(pre, extension, HTMLAttributes);
    syncLanguageClass();

    syncLayout();

    const isMer = nextLang === "mermaid";
    if (isMer && mode === "preview" && (textChanged || langChanged || uiChanged)) {
      debouncedRender.schedule();
    }
    return true;
  }

  return {
    dom: wrap,
    contentDOM: code,
    update(next: PMNode, decorations: readonly Decoration[], innerDecorations: DecorationSource) {
      return updateLangAndAttrs(next, decorations, innerDecorations);
    },
    ignoreMutation(record: ViewMutationRecord) {
      if (record.type === "selection") {
        const t = (record as { target?: Node }).target;
        if (t && preview.contains(t)) return true;
        return false;
      }
      const target = (record as MutationRecord).target as Node | null;
      if (!target) return true;
      if (code.contains(target)) return false;
      if (target === wrap || target === pre) return false;
      if (toolbar.contains(target) || preview.contains(target)) return true;
      return false;
    },
    stopEvent(event: Event) {
      const t = event.target as Node | null;
      if (!t) return false;
      if (event.type === "wheel") {
        return false;
      }
      if (toolbar.contains(t)) return true;
      if (preview.contains(t)) return true;
      return false;
    },
    destroy() {
      destroyed = true;
      debouncedRender.cancel();
      themeRefreshers.delete(refresh);
      toggleBtn.removeEventListener("pointerdown", onTogglePointerDownCapture, true);
      toggleBtn.removeEventListener("click", onToggleClickCapture, true);
    },
  };
}

export const HiCodeBlock = CodeBlock.extend({
  addAttributes() {
    return {
      ...(this.parent?.() ?? {}),
      mermaidUi: {
        default: null,
        rendered: false,
      },
    };
  },
  addNodeView() {
    return (props: NodeViewRendererProps) => createMermaidNodeView(props);
  },
  addProseMirrorPlugins() {
    return [createSyntaxHighlightPlugin()];
  },
});
