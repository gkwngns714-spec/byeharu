import { defineConfig } from 'vite'

// Standalone tool app. Deliberately rooted here so it shares nothing with the
// game's root vite/tsconfig build — see tools/projectmap/README.md.
export default defineConfig({
  base: './',
  server: { port: 5183, open: true },
  // esnext: the viewer loads graph.json/live.json with top-level await.
  build: { outDir: 'dist', target: 'esnext' },
  esbuild: { target: 'esnext' },
  optimizeDeps: { esbuildOptions: { target: 'esnext' } },
})
