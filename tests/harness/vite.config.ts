import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Test-only Vite server that renders the real <PortNavPanel> from src/ for the OSN-ENABLEMENT-1B UI proof.
// Root is this harness dir; fs.allow is widened to the repo root so `../../src/...` imports resolve.
// cacheDir is forced into the OS temp dir so Vite's dep-optimizer cache never lands on a OneDrive-synced
// path (whose locked rmdir breaks the dev server locally — harmless in CI).
export default defineConfig({
  root: fileURLToPath(new URL('.', import.meta.url)),
  cacheDir: join(tmpdir(), 'osn-ui-harness-vite'),
  plugins: [react()],
  server: {
    port: 5199,
    strictPort: true,
    fs: { allow: [fileURLToPath(new URL('../..', import.meta.url))] },
  },
})
