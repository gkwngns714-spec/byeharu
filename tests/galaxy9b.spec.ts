import { test, expect, type Page } from '@playwright/test'
import { createClient } from '@supabase/supabase-js'

// Phase 9B — map-based expedition send, against the live app. A throwaway user (email
// contains "test" so cleanup_test_runtime removes its rows afterwards) signs in, opens
// /galaxy, picks a loadout for a dispatchable destination, confirms, and sends through the
// EXISTING verified RPC. Asserts: send disabled before a loadout, success feedback, EXACTLY
// one fleet/movement via the backend read path, a movement line on the map, no duplicate from
// double-submit, and no serious console errors.

const URL_ = process.env.VITE_SUPABASE_URL!
const ANON = process.env.VITE_SUPABASE_ANON_KEY!
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY!
const BASE = process.env.PLAYWRIGHT_BASE_URL || 'https://gkwngns714-spec.github.io/byeharu/'

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })
const shot = (page: Page, name: string) => page.screenshot({ path: `test-results/galaxy9b-${name}.png`, fullPage: true })
const BENIGN = [/favicon/i, /manifest/i, /\.png/i, /service worker/i, /Failed to load resource/i, /net::ERR/i]

test('Phase 9B — map-based expedition send', async ({ page }) => {
  const errors: string[] = []
  page.on('console', (m) => { if (m.type() === 'error' && !BENIGN.some((b) => b.test(m.text()))) errors.push(`console: ${m.text()}`) })
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`))

  // ── setup: throwaway user (starting units seeded on base creation) ────────────
  const email = `galaxytest9b.${Date.now()}@example.com`
  const password = 'Test123456!'
  const anonC = createClient(URL_, ANON, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error: suErr } = await anonC.auth.signUp({ email, password })
  expect(suErr, suErr?.message).toBeFalsy()
  const userId = su.user!.id
  expect(((await admin.from('fleets').select('id').eq('player_id', userId)).data ?? []).length).toBe(0)

  // ── sign in + open the galaxy map ─────────────────────────────────────────────
  await page.goto(BASE)
  await page.getByPlaceholder('Email').fill(email)
  await page.getByPlaceholder('Password').fill(password)
  await page.getByRole('button', { name: 'Sign in' }).click()
  // 9C reframe: Command Center points to the map and has NO duplicate send control.
  await expect(page.getByTestId('dashboard-expedition-launcher')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Send a fleet' })).toHaveCount(0)
  await page.getByRole('link', { name: /Galaxy map/i }).first().click()
  await expect(page.getByTestId('galaxy-map-screen')).toBeVisible()
  await expect(page.getByTestId('galaxy-location-marker').first()).toBeVisible({ timeout: 30_000 })

  // ── select a dispatchable safe-zone marker (activity "none" → no power/combat gate) ──
  const safe = page.locator('[data-testid="galaxy-location-marker"][data-activity="none"]').first()
  await expect(safe).toBeVisible()
  await safe.click()
  await expect(page.getByTestId('galaxy-expedition-command')).toBeVisible()

  // 14. send is DISABLED before any units are chosen
  const sendBtn = page.getByTestId('galaxy-send-expedition')
  await expect(sendBtn).toBeDisabled()
  await expect(page.getByTestId('galaxy-send-disabled-reason')).toContainText(/select ships/i)
  await shot(page, '01-selected')

  // ── pick a loadout → send becomes enabled ─────────────────────────────────────
  await page.getByTestId('galaxy-unit-scout').fill('3')
  await expect(sendBtn).toBeEnabled()
  await sendBtn.click()

  // confirmation step appears; double-click Confirm to probe double-submit
  const confirmBtn = page.getByTestId('galaxy-send-confirm')
  await expect(confirmBtn).toBeVisible()
  await confirmBtn.dblclick()

  // 10. success feedback
  await expect(page.getByTestId('galaxy-send-success')).toBeVisible({ timeout: 20_000 })
  await shot(page, '02-sent')

  // 11/13. EXACTLY one fleet + one movement via the backend read path (no duplicate send)
  await expect
    .poll(async () => ((await admin.from('fleets').select('id').eq('player_id', userId)).data ?? []).length, { timeout: 15_000 })
    .toBe(1)
  expect(((await admin.from('fleet_movements').select('id').eq('player_id', userId)).data ?? []).length).toBe(1)

  // 12. a movement line appears on the map (from refetched data, not optimistic state)
  await expect(page.getByTestId('galaxy-movement-line').first()).toBeVisible({ timeout: 10_000 })

  // 15. no serious console/page errors
  expect(errors, errors.join('\n')).toEqual([])
})
