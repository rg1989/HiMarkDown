# Supported Markdown (HiMarkDown)

The **HTML** editor uses [TipTap](https://tiptap.dev/) with the official [`@tiptap/markdown`](https://github.com/ueberdosis/tiptap) integration (CommonMark-oriented parsing and serialization via the StarterKit schema).

## Generally well-supported

- ATX headings `#` … `######`
- Paragraphs and line breaks
- **Bold**, *italic*, `inline code`
- Fenced code blocks
- Bullet and ordered lists (basic nesting)
- Blockquotes
- Links `[text](url)`

## Known limitations

- GitHub-only extensions (tables, task lists, autolinks) depend on TipTap extensions you add later.
- Raw HTML embedded in Markdown may not round-trip cleanly through the visual editor.
- Very large documents are not performance-tuned yet.

For full fidelity, use **Markdown** mode for source editing.
