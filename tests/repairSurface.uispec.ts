import { test, expect, type Page } from '@playwright/test'

// ██ ONE REPAIR SURFACE — the RENDERED proof. ██
//
// The owner: "remove the command ship repair section in ships". There were TWO repair blocks in the
// Fitting detail — the priced <RepairPanel> and a separate free Repair/Tow block below it — plus a
// THIRD copy of the action on every destroyed roster row, so a selected wreck put two repair buttons
// on screen for one ship. Migration 0335 had already collapsed the SERVER to one verb whose only
// wreck/dent difference is the POLICY it applies; the client never followed.
//
// These specs pin the thing a pure spec cannot see: that the composed DOM carries EXACTLY ONE repair
// action for every state, that a wreck's recovery survives every read failure and every dark flag
// (NO-SOFTLOCK), that the tow still exists for a genuinely adrift wreck, and that the price is
// honest at the knob's live production value of 0. tests/harness/repair.html mounts the REAL
// component with an injected server API — nothing connects.
//
// Run: `npx playwright test --config playwright.osnui.config.ts repairSurface`

type Place = 'transit' | 'in_space' | 'docked' | 'berthed' | 'hidden'
interface Patch {
  shipStatus?: string
  disabledShips?: Array<{ main_ship_id: string; name: string; at_port: boolean; location_id: string | null }> | null
  place?: Place | null
  configRows?: Array<{ key: string; value: unknown }>
  hull?: { hp: number; maxHp: number; status: string } | null
  wallet?: number | null | 'error'
  repairResult?: unknown
  towResult?: unknown
}

const SHIP = 'ship-1'
const AT_PORT = { main_ship_id: SHIP, name: 'Kestrel', at_port: true, location_id: 'haven' }
const ADRIFT = { main_ship_id: SHIP, name: 'Kestrel', at_port: false, location_id: null }

/** Boot the surface with the world already staged — the panel's FIRST read sees it (see the
 *  harness note on repairStickyLit: a "dark all along" flag cannot be staged after mount). */
async function boot(page: Page, patch: Patch = {}) {
  const q = Object.keys(patch).length > 0 ? `?s=${encodeURIComponent(JSON.stringify(patch))}` : ''
  await page.goto(`/repair.html${q}`)
}

const calls = (page: Page) =>
  page.evaluate(() => (window as unknown as { __calls: { repair: unknown[]; tow: unknown[] } }).__calls)

/** Flip the already-booted surface to a wreck sitting at a port, without re-booting the page. */
const wreckAtPort = (page: Page) =>
  page.evaluate(
    (row) =>
      (window as unknown as { __set: (x: unknown) => void }).__set({
        shipStatus: 'destroyed',
        disabledShips: [row],
        place: null,
      }),
    AT_PORT,
  )

// ── THE HEADLINE: one action, whatever the hull's state ──────────────────────────────────────────
test('a DENT renders EXACTLY ONE repair action — and no second repair surface anywhere', async ({ page }) => {
  await boot(page)
  await expect(page.getByTestId('repair-panel')).toBeVisible()
  // ONE panel, ONE submit. Before this slice a second block could mount below with its own button.
  await expect(page.getByTestId('repair-panel')).toHaveCount(1)
  await expect(page.getByTestId('repair-submit')).toHaveCount(1)
  await expect(page.getByTestId('repair-tow')).toHaveCount(0)
  // The priced desk's own controls are present for a dent (the amount IS honoured for a dent).
  await expect(page.getByTestId('repair-amount')).toHaveValue('120')
})

test('a WRECK renders EXACTLY ONE repair action, in the SAME one panel — not a second section', async ({ page }) => {
  await boot(page, { shipStatus: 'destroyed', disabledShips: [AT_PORT], place: null })
  await expect(page.getByTestId('repair-panel')).toHaveCount(1)
  await expect(page.getByTestId('repair-submit')).toHaveCount(1)
  await expect(page.getByTestId('repair-submit')).toHaveText(/Repair ship/)
  await expect(page.getByTestId('repair-tow')).toHaveCount(0)
  // A WRECK RESTORES WHOLE (0335's amount policy ignores the requested amount), so the surface
  // offers no stepper it could not honour.
  await expect(page.getByTestId('repair-amount')).toHaveCount(0)
  await expect(page.getByTestId('repair-position-note')).toContainText('wrecked')
})

test('a FULL-HULL ship shows NOTHING — no card, no action, no explanation of the obvious', async ({ page }) => {
  await boot(page, { hull: { hp: 500, maxHp: 500, status: 'stationary' } })
  await expect(page.getByTestId('repair-panel')).toHaveCount(0)
})

// ── the tow survives, and only where the server would refuse the repair ──────────────────────────
test('a genuinely ADRIFT wreck is offered the TOW — and the Repair action is not shown beside it', async ({ page }) => {
  await boot(page, { shipStatus: 'destroyed', disabledShips: [ADRIFT], place: null })
  await expect(page.getByTestId('repair-tow')).toHaveCount(1)
  await expect(page.getByTestId('repair-tow')).toHaveText(/Tow to the nearest port/)
  // EXACTLY ONE action: the tow REPLACES the repair rather than sitting next to it.
  await expect(page.getByTestId('repair-submit')).toHaveCount(0)
  await expect(page.getByTestId('repair-position-note')).toContainText('adrift')
})

test('the tow commands mainship_emergency_tow for THIS ship and reports the port it reached', async ({ page }) => {
  await boot(page, { shipStatus: 'destroyed', disabledShips: [ADRIFT], place: null })
  await page.getByTestId('repair-tow').click()
  await expect(page.getByTestId('repair-tow-note')).toContainText('Towed to Haven Reach')
  expect(await calls(page)).toMatchObject({ tow: [{ shipId: SHIP }] })
})

test('a failed tow speaks player words, never a raw server code', async ({ page }) => {
  await boot(page, {
    shipStatus: 'destroyed',
    disabledShips: [ADRIFT],
    place: null,
    towResult: { ok: false, reason: 'no_port_available' },
  })
  await page.getByTestId('repair-tow').click()
  const note = page.getByTestId('repair-tow-note')
  await expect(note).toContainText('No port can take this ship right now.')
  await expect(note).not.toContainText('_')
})

// ── NO-SOFTLOCK: a wreck's recovery outlives every failure the dent path stays silent for ────────
test("NO-SOFTLOCK: a DARK repair_economy_enabled silences the dent but NEVER the wreck's recovery", async ({ page }) => {
  // Dark flag + a dent → the surface renders nothing at all (fail closed, and quiet).
  await boot(page, { configRows: [{ key: 'repair_economy_enabled', value: false }] })
  await expect(page.getByTestId('repair-panel')).toHaveCount(0)
  // The SAME dark flag with a wreck → the recovery action is still there. Wreck recovery is free and
  // ungated on the server (0335's cost policy), so a client that hid it would be hiding a repair the
  // server would happily perform.
  await wreckAtPort(page)
  await expect(page.getByTestId('repair-submit')).toHaveCount(1)
})

test("NO-SOFTLOCK: a FAILED hull read silences the dent's desk but never the wreck's recovery", async ({ page }) => {
  await boot(page, { shipStatus: 'destroyed', disabledShips: [AT_PORT], place: null, hull: null })
  await expect(page.getByTestId('repair-submit')).toHaveCount(1)
  await expect(page.getByTestId('repair-unavailable')).toHaveCount(0)
})

test('NO-SOFTLOCK: an UNAVAILABLE readiness read fails OPEN — Repair is offered, not the tow', async ({ page }) => {
  // disabledShips null = the 0297 read failed / the client is ahead of the migration. The server is
  // the enforcer; the UI must never hide a recovery it cannot rule out.
  await boot(page, { shipStatus: 'destroyed', disabledShips: null, place: null })
  await expect(page.getByTestId('repair-submit')).toHaveCount(1)
  await expect(page.getByTestId('repair-tow')).toHaveCount(0)
})

// ── the four behaviours that must not be lost ────────────────────────────────────────────────────
test('a wreck IN A DOCKED FLEET repairs in place (0334) — one call, whole hull, no amount', async ({ page }) => {
  await boot(page, {
    shipStatus: 'destroyed',
    disabledShips: [AT_PORT],
    place: null,
    // the 0335 recovery envelope: free, whole-hull, and the status flipped back off 'destroyed'.
    repairResult: {
      ok: true,
      recovered: true,
      status: 'home',
      receipt_id: 'r1',
      main_ship_id: SHIP,
      hp_before: 0,
      hp_after: 500,
      hp_restored: 500,
      credits_per_hp: 0,
      total_price: 0,
      location_id: 'haven',
    },
  })
  await page.getByTestId('repair-submit').click()
  await expect(page.getByTestId('repair-note')).toContainText('Recovered')
  // `hp: null` IS the whole-hull request; the server restores a wreck whole regardless.
  expect(await calls(page)).toMatchObject({ repair: [{ shipId: SHIP, hp: null }] })
})

test('a DENT mends for the amount asked, through the same one verb', async ({ page }) => {
  await boot(page)
  await page.getByTestId('repair-dec').click() // 120 → 119
  await page.getByTestId('repair-submit').click()
  await expect(page.getByTestId('repair-note')).toContainText('Repaired +120 hull')
  expect(await calls(page)).toMatchObject({ repair: [{ shipId: SHIP, hp: 119 }] })
})

test("a STRANGER'S ship is refused — the server's reject reaches the player as words", async ({ page }) => {
  await boot(page, { repairResult: { ok: false, reason: 'ship_not_found' } })
  await page.getByTestId('repair-submit').click()
  const note = page.getByTestId('repair-note')
  await expect(note).toHaveText('No ship available.')
  await expect(note).not.toContainText('_')
})

test("the server's not_at_port reject replaces the button that just failed with the TOW", async ({ page }) => {
  // The readiness read still claims this wreck is in port; the repair says otherwise. The server's
  // verdict outranks the stale read, on the one surface that issued the command.
  await boot(page, {
    shipStatus: 'destroyed',
    disabledShips: [AT_PORT],
    place: null,
    repairResult: { ok: false, reason: 'not_at_port' },
  })
  await page.getByTestId('repair-submit').click()
  await expect(page.getByTestId('repair-tow')).toHaveCount(1)
  await expect(page.getByTestId('repair-submit')).toHaveCount(0)
  // ONE reason vocabulary, with the ONE override: a wreck is told to TOW, not to "take it to a port".
  await expect(page.getByTestId('repair-note')).toContainText('Tow it to a port')
})

test('a DENT away from a port states the one honest reason and offers no button that would fail', async ({ page }) => {
  await boot(page, { place: 'in_space' })
  await expect(page.getByTestId('repair-position-note')).toHaveText('Take this ship to a port to repair it.')
  await expect(page.getByTestId('repair-submit')).toHaveCount(0)
  await expect(page.getByTestId('repair-tow')).toHaveCount(0) // the tow is a WRECK's route, never a dent's
})

test('a BERTHED dent is mendable where it lies (0335 collapsed docked/berthed into one position)', async ({ page }) => {
  await boot(page, { place: 'berthed' })
  await expect(page.getByTestId('repair-submit')).toBeEnabled()
  await expect(page.getByTestId('repair-position-note')).toHaveCount(0)
})

test('an UNKNOWN position makes no claim either way — the dent surface stays silent', async ({ page }) => {
  await boot(page, { place: 'hidden' })
  await expect(page.getByTestId('repair-panel')).toHaveCount(0)
})

// ── price honesty, at the knob's live value and at a real one ────────────────────────────────────
test('PRICE HONESTY: the live knob of 0 reads "Free" — for a dent and for a wreck alike', async ({ page }) => {
  await boot(page)
  await expect(page.getByTestId('repair-cost')).toHaveText('Free')
  await wreckAtPort(page)
  // A wreck is free BY LAW (0335 sets its rate to 0, ungated by the knob) — same one label.
  await expect(page.getByTestId('repair-cost')).toHaveText('Free')
})

test('PRICE HONESTY: a NON-ZERO knob prices the mend, and the total tracks the amount', async ({ page }) => {
  await boot(page, {
    configRows: [
      { key: 'repair_economy_enabled', value: true },
      { key: 'repair_credits_per_hp', value: 2.5 },
      { key: 'starting_credits', value: 500 },
    ],
    wallet: 1000,
  })
  await expect(page.getByTestId('repair-cost')).toHaveText('300 cr') // 120 hp × 2.5
  await page.getByTestId('repair-dec').click()
  await expect(page.getByTestId('repair-cost')).toHaveText('297.5 cr') // 119 hp × 2.5
})

test('PRICE HONESTY: an unreadable knob claims nothing — "—", never a free-repair promise', async ({ page }) => {
  await boot(page, {
    configRows: [
      { key: 'repair_economy_enabled', value: true },
      { key: 'repair_credits_per_hp', value: 'nonsense' },
      { key: 'starting_credits', value: 500 },
    ],
  })
  await expect(page.getByTestId('repair-cost')).toHaveText('—')
})
