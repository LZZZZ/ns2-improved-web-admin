import { defineConfig } from "vite";

// JSX comes from tsconfig.json ("jsx": "react-jsx", "jsxImportSource":
// "preact"), which Vite's transform reads directly.

// Source lives in panel/, the build lands in web/ -- which is the mod's web
// root verbatim, so assembling the workshop item is a directory copy.
//
// Hashed asset names are not a nicety here: a path that is not a file on disk
// returns 200 with the server-state JSON rather than 404, so a stale or wrong
// asset reference fails as a parse error with no clue attached. Everything is
// emitted with a content hash and referenced from the one index.html.
export default defineConfig({
  build: {
    outDir: "../web",
    emptyOutDir: true,
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
});
