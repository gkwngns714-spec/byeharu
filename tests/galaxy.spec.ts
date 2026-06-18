import { test, expect, type Page } from '@playwright/test'
import { createClient } from '@supabase/supabase-js'

// Phase 9A — read-only Galaxy Map smoke test against the live app. Setup creates a
// throwaway user (anon signUp); the browser signs in via the UI, opens /galaxy, and
// confirms the map renders, a location is selectable, the detail panel opens, and the
// Send Expedition button is disabled. It also asserts NO fleet/expedition was created.

const URL_ = process.env.VITE_SUPABASE_URL!
const ANON = process.env.VITE_SUPABASE_ANON_KEY!
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY!
const BASE = process.env.PLAYWRIGHT_BASE_URL || 'https://gkwngns714-spec.github.io/byeharu/'

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })
const shot = (page: Page, name: string) => page.screenshot({ path: `test-results/galaxy-${name}.png`, fullPage: true })
// Benign console noise we don't fail on (favicon/manifest 404s, etc.).
const BENIGN = [/favicon/i, /manifest/i, /\.png/i, /service worker/i, /Failed to load resource/i, /net::ERR/i]

test('Phase 9A — read-only galaxy map smoke', async ({ page }) => {
  // collect serious console + page errors
  const errors: string[] = []
  page.on('console', (m) => { if (m.type() === 'error' && !BENIGN.some((b) => b.test(m.text()))) errors.push(`console: ${m.text()}`) })
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`))

  // ── setup: throwaway user (no fleets — proves nothing gets sent) ──────────────
  const email = `galaxybrowser.${Date.now()}@example.com`
  const password = 'Test123456!'
  const anonC = createClient(URL_, ANON, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error: suErr } = await anonC.auth.signUp({ email, password })
  expect(suErr, suErr?.message).toBeFalsy()
  const userId = su.user!.id
  const fleetsBefore = ((await admin.from('fleets').select('id').eq('player_id', userId)).data ?? []).length
  expect(fleetsBefore).toBe(0)

  // ── sign in via the UI ───────────────────────────────────────────────────────
  await page.goto(BASE)
  await page.getByPlaceholder('Email').fill(email)
  await page.getByPlaceholder('Password').fill(password)
  await page.getByRole('button', { name: 'Sign in' }).click()
  // land on the Command Center, then click the Galaxy map nav link (client-side route)
  await page.getByRole('link', { name: /Galaxy map/i }).first().click()

  // 3. galaxy screen + header visible
  await expect(page.getByTestId('galaxy-map-screen')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Galaxy Map' })).toBeVisible()

  // 4. at least one location marker renders (after loading resolves)
  const markers = page.getByTestId('galaxy-location-marker')
  await expect(markers.first()).toBeVisible({ timeout: 30_000 })
  expect(await markers.count()).toBeGreaterThan(0)
  await shot(page, '01-map')

  // 5. select one marker
  await markers.first().click()

  // 6. read-only detail panel opens
  const panel = page.getByTestId('galaxy-location-detail-panel')
  await expect(panel).toBeVisible()
  await expect(panel.getByText(/coming in Phase 9B/i)).toBeVisible()

  // 7. Send Expedition button is present, disabled, and marked Phase 9B
  const sendBtn = page.getByTestId('galaxy-send-expedition-disabled')
  await expect(sendBtn).toBeVisible()
  await expect(sendBtn).toBeDisabled()
  await expect(sendBtn).toContainText(/Phase 9B/i)
  await shot(page, '02-detail-panel')

  // 8. no write / no expedition: clicking the disabled button does nothing, and no fleet
  //    was created for this user by anything on the screen.
  await sendBtn.click({ force: true }).catch(() => {}) // disabled → no-op
  await page.waitForTimeout(1500)
  const fleetsAfter = ((await admin.from('fleets').select('id').eq('player_id', userId)).data ?? []).length
  expect(fleetsAfter, 'no expedition/fleet should be created from the read-only map').toBe(0)
  const movesAfter = ((await admin.from('fleet_movements').select('id').eq('player_id', userId)).data ?? []).length
  expect(movesAfter, 'no movement should be created').toBe(0)

  // 9. no serious console/page errors
  expect(errors, errors.join('\n')).toEqual([])
})
