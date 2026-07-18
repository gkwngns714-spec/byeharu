import { defineConfig, devices } from '@playwright/test'

// Dedicated config for the RENDERED UI proofs. It matches ONLY *.uispec.ts files (so the default
// playwright.config.ts, which matches *.spec.ts, never picks them up) and serves the test harness via
// Vite. Dummy Supabase env keeps the supabase client constructible at import (the panels use INJECTED
// deps, so nothing connects). No production access. 4A-POST: the PortNav + galaxy-coordinate harnesses
// were deleted with the per-ship movement client — the dock-services harness is the remaining entry,
// so readiness polls /dock.html (the harness root has no index.html anymore).
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
