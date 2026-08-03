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
// reads). Readiness polls /dock.html because ONE entry is enough to prove the server is up; all
// are served by it.
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
