import { defineConfig, devices } from '@playwright/test'

// M4.5 browser acceptance — runs against the deployed Pages site by default (or a
// local URL via PLAYWRIGHT_BASE_URL). Test infrastructure only.
const BASE = process.env.PLAYWRIGHT_BASE_URL || 'https://gkwngns714-spec.github.io/byeharu/'

export default defineConfig({
  testDir: './tests',
  timeout: 180_000,
  expect: { timeout: 20_000 },
  retries: 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: BASE,
    screenshot: 'on',
    trace: 'on',
    video: 'retain-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
})
