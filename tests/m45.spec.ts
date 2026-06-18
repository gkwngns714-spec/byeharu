import { test, expect, type Page } from '@playwright/test'
import { createClient } from '@supabase/supabase-js'

// M4.5 browser acceptance against the live app. Setup uses the SERVICE-ROLE key to
// create a throwaway user's metal + a completed fleet (server-side test path — NOT a
// client cheat). The browser then drives the real UI.

const URL_ = process.env.VITE_SUPABASE_URL!
const ANON = process.env.VITE_SUPABASE_ANON_KEY!
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY!
const BASE = process.env.PLAYWRIGHT_BASE_URL || 'https://gkwngns714-spec.github.io/byeharu/'

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })
const getMetal = async (baseId: string) =>
  (await admin.from('base_resources').select('amount').eq('base_id', baseId).eq('resource_code', 'metal').maybeSingle())
    .data?.amount ?? 0
const shot = (page: Page, name: string) => page.screenshot({ path: `test-results/m45-${name}.png`, fullPage: true })

test('M4.5 production queue browser acceptance', async ({ page }) => {
  // ── setup: throwaway user + metal + a completed fleet (service-role) ─────────
  const email = `m45testbrowser.${Date.now()}@example.com`
  const password = 'Test123456!'
  const anonC = createClient(URL_, ANON, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error: suErr } = await anonC.auth.signUp({ email, password })
  expect(suErr, suErr?.message).toBeFalsy()
  const userId = su.user!.id
  const { data: base } = await anonC.from('bases').select('id').limit(1).maybeSingle()
  const baseId = base!.id as string
  await admin.from('base_resources').update({ amount: 5000 }).eq('base_id', baseId).eq('resource_code', 'metal')
  await admin.from('fleets').insert({ player_id: userId, origin_base_id: baseId, status: 'completed' })

  // ── sign in via the UI ──────────────────────────────────────────────────────
  await page.goto(BASE)
  await page.getByPlaceholder('Email').fill(email)
  await page.getByPlaceholder('Password').fill(password)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page.getByRole('heading', { name: 'Train Ships' })).toBeVisible()
  await shot(page, '01-command-center')

  // ── item 17: friendly coordinates, no raw "0, 0" ────────────────────────────
  await expect(page.getByText('Sector 0:0')).toBeVisible()
  await expect(page.getByText('coords 0, 0')).toHaveCount(0)

  const trainSection = page.locator('section').filter({ has: page.getByRole('heading', { name: 'Train Ships' }) })
  const queue = page.locator('section').filter({ has: page.getByRole('heading', { name: 'Training Queue' }) })

  async function train(unit: string, qty: number) {
    await trainSection.locator('select').selectOption(unit)
    await trainSection.locator('input[type="number"]').fill(String(qty))
    await trainSection.getByRole('button', { name: 'Train', exact: true }).click()
  }

  // ── items 3-4: Train Scout ×5, active row content ───────────────────────────
  await train('scout', 5)
  const scoutRow = queue.locator('li').filter({ hasText: 'Scout' })
  await expect(scoutRow).toContainText('Per ship:')
  await expect(scoutRow).toContainText('Total order:')
  await expect(scoutRow).toContainText('Ship 1 of 5')
  await expect(scoutRow).toContainText('Remaining:')
  await expect(scoutRow).toContainText('Ships delivered when the full order completes')
  await shot(page, '02-active-scout')

  // active row actually ticks (remaining / ship progress changes over time)
  const t1 = (await scoutRow.textContent()) ?? ''
  await page.waitForTimeout(3500)
  const t2 = (await scoutRow.textContent()) ?? ''
  expect(t1, 'active row should tick').not.toEqual(t2)

  // ── items 5-6: queue Corvette ×2 — waiting row, no countdown / no Ship N ─────
  await train('corvette', 2)
  const corvetteRow = queue.locator('li').filter({ hasText: 'Corvette' })
  await expect(corvetteRow).toContainText('Per ship:')
  await expect(corvetteRow).toContainText('Total order:')
  await expect(corvetteRow).toContainText('Waiting')
  await expect(corvetteRow).not.toContainText('Remaining:')
  await expect(corvetteRow).not.toContainText('Ship 1 of')
  await shot(page, '03-waiting-corvette')

  // ── items 7-8: cancel active → inline confirm (refund + penalty) ────────────
  await scoutRow.getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(scoutRow).toContainText('Refund:')
  await expect(scoutRow).toContainText('Penalty')
  await expect(scoutRow.getByRole('button', { name: 'Keep Building' })).toBeVisible()
  await expect(scoutRow.getByRole('button', { name: 'Confirm Cancel' })).toBeVisible()
  await shot(page, '04-cancel-confirm')

  // ── items 9-10: Keep Building does NOT cancel ───────────────────────────────
  await scoutRow.getByRole('button', { name: 'Keep Building' }).click()
  await expect(scoutRow.getByRole('button', { name: 'Confirm Cancel' })).toHaveCount(0)
  await expect(scoutRow).toContainText('Remaining:') // still active

  // ── items 11-13: cancel + confirm → refund once (+125 = 50% of 250), next starts ─
  const metalBefore = await getMetal(baseId)
  await scoutRow.getByRole('button', { name: 'Cancel', exact: true }).click()
  await scoutRow.getByRole('button', { name: 'Confirm Cancel' }).click()
  await expect.poll(() => getMetal(baseId), { timeout: 20_000 }).toBe(metalBefore + 125)
  await expect(queue).not.toContainText('Scout')
  await expect(corvetteRow).toContainText('Remaining:')
  await shot(page, '05-after-cancel')

  // ── items 14-15: refresh → no duplicate refund, cancelled stays gone ────────
  await page.reload()
  await expect(page.getByRole('heading', { name: 'Training Queue' })).toBeVisible()
  expect(await getMetal(baseId), 'no duplicate refund after refresh').toBe(metalBefore + 125)
  await expect(
    page.locator('section').filter({ has: page.getByRole('heading', { name: 'Training Queue' }) }),
  ).not.toContainText('Scout')

  // ── item 16: completed history folds/unfolds ────────────────────────────────
  const fleets = page.locator('section').filter({ has: page.getByRole('heading', { name: 'Fleets', exact: true }) })
  const toggle = fleets.getByRole('button', { name: /previous run/ })
  await expect(toggle).toContainText('Show')
  await toggle.click()
  await expect(fleets.getByRole('button', { name: /previous run/ })).toContainText('Hide')
  await shot(page, '06-history-expanded')
  await fleets.getByRole('button', { name: /previous run/ }).click()
  await expect(fleets.getByRole('button', { name: /previous run/ })).toContainText('Show')
  await shot(page, '07-done')
})
