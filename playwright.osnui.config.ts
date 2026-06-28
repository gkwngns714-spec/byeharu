import { defineConfig, devices } from '@playwright/test'

// Dedicated config for the OSN-ENABLEMENT-1B RENDERED UI proof. It matches ONLY the *.uispec.ts file (so the
// default playwright.config.ts, which matches *.spec.ts, never picks it up) and serves the test harness via
// Vite. Dummy Supabase env keeps the supabase client constructible at import (the panel uses INJECTED deps,
// so nothing connects). No production access.
export default defineConfig({
  testDir: './tests',
  testMatch: '**/*.uispec.ts',
  timeout: 30000,
  reporter: [['list']],
  use: { baseURL: 'http://localhost:5199', trace: 'off' },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: 'npx vite --config tests/harness/vite.config.ts',
    url: 'http://localhost:5199',
    reuseExistingServer: false,
    timeout: 120000,
    env: {
      VITE_SUPABASE_URL: 'http://localhost:54321',
      VITE_SUPABASE_ANON_KEY: 'dummy-anon-key-for-harness-only',
    },
  },
})
