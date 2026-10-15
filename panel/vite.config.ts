import { rmSync } from "node:fs";
import { defineConfig } from "vite";

// JSX comes from tsconfig.json ("jsx": "react-jsx", "jsxImportSource":
// "preact"), which Vite's transform reads directly.

// The web root. In the game repo it is ns2/web, which also holds client_game/,
// so a build replaces only the panel's own files.
const out = "../web";

// Hashed asset names are not a nicety here: a path that is not a file on disk
// still returns 200 (a "not found" page), so a stale or wrong asset reference
// fails with no clue attached. Everything is emitted with a content hash and
// referenced from the one index.html.
export default defineConfig(({ command }) => {
  if (command === "build") {
    for (const f of ["index.html", "assets", "THIRD-PARTY-LICENSES.txt"])
      rmSync(`${out}/${f}`, { recursive: true, force: true });
  }
  return {
    build: {
      outDir: out,
      emptyOutDir: false,
      target: "es2022",
      assetsInlineLimit: 0,
      reportCompressedSize: false,
      rollupOptions: {
        output: {
          // One chunk. The panel is small, the server is plain HTTP on a
          // possibly distant box, and every reply is Cache-Control: no-store.
          manualChunks: undefined,
        },
      },
    },
  };
});
