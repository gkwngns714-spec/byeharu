import { defineConfig, devices } from '@playwright/test'

// Dedicated config for the RENDERED UI proofs. It matches ONLY *.uispec.ts files (so the default
// playwright.config.ts, which matches *.spec.ts, never picks them up) and serves the test harness via
// Vite. Dummy Supabase env keeps the supabase client constructible at import (the panels use INJECTED
// deps, so nothing connects). No production access. Run in CI by the `rendered-ui` job in
// .github/workflows/frontend-tests.yml, on every PR and slice push.
//
// Harness entries (the root has no index.html): /dock.html — the real docked-port surface;
// /camera.html — the real <GalaxyMap> + useWheelZoom under a real pointer; /fold.html — the real
// <ReportsSection> (the Collapsible fold contract); /repair.html — the real <RepairPanel>, THE ONE
// repair surface, driven across every server state (wreck / dent / adrift / dark flag / failed
// reads); /hunt.html — the signpost out of the pirate-zone dead end; /fight.html — the rendered
// battle readout at a phone width; /nav.html — the bottom bar MEASURED at the 320px floor;
// /assets.html — the asset ledger across every price-coverage state, proving a missing price
// reaches the screen as words and never as a zero; /ships.html — the real Ships tab (<ShipsView> +
// the real <FittingDetail>), MEASURED side by side at 1280px and stacked-but-unclipped at 320px;
// /fleetinfo.html — the real <FleetStatusPanel> in the real map rail: where each fleet is, what it
// is doing, WHY it cannot fight, and the one action slot (hunt the site under its feet, or retreat
// from the fight it is in), MEASURED at the 320px floor and 10% under it; /shop.html — the real
// <ShopRow> over the real production module catalog, proving a DORMANT stat is not advertised at
// point of sale: the dead chip is off the SCREEN, the live ones are not, a legacy one is marked,
// and the one offer whose every claimed effect is dormant says so in words and cannot be bought.
// Only a render can show that nothing downstream put the claim back.
// Readiness polls /dock.html because ONE entry is enough to prove the server is up; all are served
// by it.
export default defineConfig({
  testDir: './tests',
  testMatch: '**/*.uispec.ts',
  timeout: 30000,
  reporter: [['list']],
  use: { baseURL: 'http://localhost:5199', trace: 'off' },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: 'npx vite --config tests/harness/vite.config.ts',
    url: 'http://localhost:5199/dock.html',
    reuseExistingServer: false,
    timeout: 120000,
    env: {
      VITE_SUPABASE_URL: 'http://localhost:54321',
      VITE_SUPABASE_ANON_KEY: 'dummy-anon-key-for-harness-only',
    },
  },
})
