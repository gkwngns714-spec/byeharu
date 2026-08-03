import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Test-only Vite server that renders REAL components from src/ for the *.uispec.ts proofs. Entries:
//   dock.html   — the real docked-port surface (useDockServices → <DockedPortCard>)
//   camera.html — the real <GalaxyMap> + useWheelZoom, driven by a real pointer
//   fold.html   — the real <ReportsSection> (the Collapsible primitive through its consumer)
//   repair.html — the real <RepairPanel> (THE ONE repair surface) with an injected server API
//   fight.html  — the real <GalaxyMap> + <CombatMapCard> over a live battle, at a 390px phone width
//   hunt.html   — the real <ZoneInfoPanel> + <NearMissSection>: the signpost out of the pirate-zone
//                 dead end, and the near miss that used to be silence
// The tailwind plugin is here for fight.html alone: that proof MEASURES the rendered readout, so it
// has to load the app design system rather than approximate it. The CSS-free harnesses are
// unaffected — none of them imports a stylesheet.
// (4A-POST deleted the PortNav + galaxy-coordinate harnesses with the per-ship movement client.)
// Root is this harness dir; fs.allow is widened to the repo root so `../../src/...` imports resolve.
// cacheDir is forced into the OS temp dir so Vite's dep-optimizer cache never lands on a OneDrive-synced
// path (whose locked rmdir breaks the dev server locally — harmless in CI).
export default defineConfig({
  root: fileURLToPath(new URL('.', import.meta.url)),
  cacheDir: join(tmpdir(), 'osn-ui-harness-vite'),
  plugins: [react(), tailwindcss()],
  server: {
    port: 5199,
    strictPort: true,
    fs: { allow: [fileURLToPath(new URL('../..', import.meta.url))] },
  },
})
