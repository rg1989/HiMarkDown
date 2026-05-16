import { defineConfig } from "vite";
import { resolve } from "node:path";

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, "src/main.ts"),
      formats: ["es"],
      fileName: () => "editor.js",
    },
    rollupOptions: {
      output: {
        entryFileNames: "editor.js",
        chunkFileNames: "editor-[name].js",
      },
    },
    outDir: resolve(__dirname, "../HiMarkDown/Web"),
    emptyOutDir: false,
    sourcemap: false,
  },
});
