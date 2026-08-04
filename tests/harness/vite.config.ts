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
//   nav.html    — the real <NavBar>: the bottom bar MEASURED at the 320px floor (cell ≥ 44px, no
//                 label clipping), which is what replaced navTabs.ts's unrendered width estimate
//   assets.html — the real <AssetsLedgerView>: that an item no port buys reaches the screen as
//                 "No price here" and never as a 0, across every price-coverage state
//   ships.html  — the real Ships tab (<ShipsView> with the real <FittingDetail> in its ship
//                 column): the fleet panel and the ship panel MEASURED side by side at 1280px, and
//                 stacked without clipping or sideways scroll at the 320px phone floor
//   fleetinfo.html — the real <FleetStatusPanel> inside the real top-left <OverlayRail>: where each
//                 fleet is, what it is doing, WHY it cannot fight, and the one action slot (into the
//                 fight under its feet, or out of the one it is in), MEASURED at 320px and at 288px
// The tailwind plugin serves the harnesses that MEASURE rendered pixels — fight.html, nav.html,
// assets.html, ships.html, fleet.html and fleetinfo.html — which have to load the app design system
// rather than approximate it. Each of those
// imports ./harness.css (NOT src/index.css directly): with `root: tests/harness`, Tailwind v4's
// source auto-detection sees only tests/harness/**, so harness.css's explicit `@source '../../src'`
// is what makes the app's own utilities exist at all. Importing src/index.css directly yields a
// stylesheet with none of the app's classes in it, and a measurement taken against that is
// measuring nothing. The CSS-free harnesses are unaffected — none of them imports a stylesheet.
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
