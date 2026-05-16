// Lazy chunk: only loaded when the document contains code blocks.
// Includes the most common languages found in technical markdown.
import { createLowlight, common } from "lowlight";

// `common` covers ~37 languages: bash, c, cpp, css, diff, go, html,
// java, javascript, json, kotlin, markdown, python, rust, shell,
// sql, swift, typescript, xml, yaml, and more.
export const lowlight = createLowlight(common);
