import { defineConfig } from "vite";
import { resolve } from "node:path";

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, "src/main.ts"),
      name: "HiMDEditor",
      formats: ["iife"],
      fileName: () => "editor.js",
    },
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
    outDir: resolve(__dirname, "../HiMarkDown/Web"),
    emptyOutDir: false,
    sourcemap: false,
  },
});
