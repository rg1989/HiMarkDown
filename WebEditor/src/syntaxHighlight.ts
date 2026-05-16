import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { Node as PMNode } from "@tiptap/pm/model";
import type { Element, Text } from "hast";
import { lowlight } from "./highlightLangs";

const key = new PluginKey<DecorationSet>("syntaxHighlight");

function hastDecos(
  nodes: any[],
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
  const decos: Decoration[] = [];
  doc.descendants((node, pos) => {
    if (node.type.name !== "codeBlock") return;
    const lang = node.attrs.language as string | null;
    if (lang === "mermaid") return;
    const code = node.textContent;
    if (!code.trim()) return;
    try {
      const langKey = lang?.toLowerCase() ?? null;
      const tree = langKey && lowlight.registered(langKey)
        ? lowlight.highlight(langKey, code)
        : lowlight.highlightAuto(code);
      hastDecos(tree.children as any, pos + 1, 0, decos);
    } catch { /* skip */ }
  });
  return DecorationSet.create(doc, decos);
}

export function createSyntaxHighlightPlugin(): Plugin {
  return new Plugin<DecorationSet>({
    key,
    state: {
      init(_, { doc }) { return buildDecos(doc); },
      apply(tr, deco) {
        if (!tr.docChanged) return deco.map(tr.mapping, tr.doc);
        return buildDecos(tr.doc);
      },
    },
    props: {
      decorations(state) { return key.getState(state); },
    },
  });
}
