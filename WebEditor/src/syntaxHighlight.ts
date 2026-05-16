import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { Node as PMNode } from "@tiptap/pm/model";
import type { Root, Element, Text } from "hast";

type LowlightInstance = Awaited<typeof import("./highlightLangs")>["lowlight"];

const key = new PluginKey<DecorationSet>("syntaxHighlight");

let ll: LowlightInstance | null = null;
let loadState: "idle" | "loading" | "ready" | "failed" = "idle";

function loadLangs(cb: () => void): void {
  if (loadState === "ready") { cb(); return; }
  if (loadState === "loading") return;
  loadState = "loading";
  import("./highlightLangs")
    .then(({ lowlight }) => { ll = lowlight; loadState = "ready"; cb(); })
    .catch(() => { loadState = "failed"; });
}

function hasCodeBlock(doc: PMNode): boolean {
  let found = false;
  doc.descendants((node) => {
    if (found) return false;
    if (node.type.name === "codeBlock" && node.attrs.language !== "mermaid")
      found = true;
  });
  return found;
}

function hastDecos(
  nodes: (Element | Text | Root["children"][number])[],
  basePos: number,
  offset: number,
  out: Decoration[]
): number {
  for (const n of nodes) {
    if (n.type === "text") {
      offset += (n as Text).value.length;
    } else if (n.type === "element") {
      const el = n as Element;
      const start = offset;
      offset = hastDecos(el.children as any, basePos, offset, out);
      const cls = ((el.properties?.className ?? []) as string[]).join(" ");
      if (cls && offset > start)
        out.push(Decoration.inline(basePos + start, basePos + offset, { class: cls }));
    }
  }
  return offset;
}

function buildDecos(doc: PMNode): DecorationSet {
  if (!ll) return DecorationSet.empty;
  const decos: Decoration[] = [];
  doc.descendants((node, pos) => {
    if (node.type.name !== "codeBlock") return;
    const lang = node.attrs.language as string | null;
    if (lang === "mermaid") return;
    const code = node.textContent;
    if (!code.trim()) return;
    try {
      const tree =
        lang && ll!.hasLanguage(lang)
          ? ll!.highlight(lang, code)
          : ll!.highlightAuto(code);
      hastDecos(tree.children as any, pos + 1, 0, decos);
    } catch { /* skip */ }
  });
  return DecorationSet.create(doc, decos);
}

export function createSyntaxHighlightPlugin(): Plugin {
  return new Plugin<DecorationSet>({
    key,
    state: {
      init() { return DecorationSet.empty; },
      apply(tr, deco) {
        if (!tr.docChanged && !tr.getMeta(key)) return deco.map(tr.mapping, tr.doc);
        return buildDecos(tr.doc);
      },
    },
    props: {
      decorations(state) { return key.getState(state); },
    },
    view() {
      return {
        update(view, prev) {
          if (loadState === "ready" || loadState === "failed") return;
          if (view.state.doc.eq(prev.doc) && loadState !== "idle") return;
          if (!hasCodeBlock(view.state.doc)) return;
          loadLangs(() => {
            const tr = view.state.tr.setMeta(key, true);
            view.dispatch(tr);
          });
        },
      };
    },
  });
}
