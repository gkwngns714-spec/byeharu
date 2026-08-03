import { test, expect, type Page } from '@playwright/test'
import { NO_PRICE_HERE } from '../src/features/assets/assetLedger'

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// ASSETS-TAB — THE RENDERED PROOF THAT A MISSING PRICE NEVER BECOMES A ZERO.
//
// The pure specs (tests/assetLedger.spec.ts) prove the model answers `null` for an item no port
// buys. This proves that the null survives the trip to the SCREEN — because that is exactly where
// it would be lost: a `?? 0` in a formatter, a `toLocaleString()` on a null, a template literal
// that renders "0 cr" for a falsy value. The owner would then be looking at a fabricated valuation
// with no way to tell it from a real one, on a screen whose entire job is telling them the truth
// about what they own. That is the worst defect this slice can ship, so it is proven in the DOM.
//
// Harness: tests/harness/assets.html?state=… — the REAL <AssetsLedgerView> with an injected
// ledger. Every fixture is built by tests/harness/assetsFixtures.ts; nothing here asserts a seeded
// catalogue, a live price, or any ambient default.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

/** Every rendered value cell, as the player reads it. */
async function valueCells(page: Page): Promise<Record<string, string>> {
  return page.evaluate(() => {
    const out: Record<string, string> = {}
    for (const el of document.querySelectorAll('[data-testid^="asset-stack-value-"]')) {
      const id = el.getAttribute('data-testid')!.replace('asset-stack-value-', '')
      out[id] = (el.textContent ?? '').trim()
    }
    return out
  })
}

// ── THE LOAD-BEARING PROOF ──────────────────────────────────────────────────────────────────────

test('AN ITEM NO PORT BUYS RENDERS AS "No price here" — never 0, and never any digit at all', async ({
  page,
}) => {
  await page.goto('/assets.html?state=mixed')
  await expect(page.getByTestId('assets-places')).toBeVisible()

  for (const itemId of ['crystal', 'ore']) {
    const cell = page.getByTestId(`asset-stack-value-${itemId}`)
    await expect(cell).toHaveText(NO_PRICE_HERE)
    // The rule stated the way it can actually fail: no numeral reaches the screen for this stack.
    await expect(cell).not.toContainText('0')
    expect(await cell.textContent()).not.toMatch(/\d/)
    // …and it is MARKED unpriced, so nothing downstream can treat it as a number either.
    await expect(page.getByTestId(`asset-stack-${itemId}`)).toHaveAttribute('data-unpriced', 'true')
    // An unpriced stack shows no unit-price line at all — there is no unit price to show.
    await expect(page.getByTestId(`asset-stack-unit-${itemId}`)).toHaveCount(0)
  }
})

test('A PORT THAT GENUINELY PAYS ZERO SHOWS "0 cr" — zero is a price, and it stays one', async ({
  page,
}) => {
  await page.goto('/assets.html?state=mixed')
  const cell = page.getByTestId('asset-stack-value-scan_data')
  await expect(cell).toHaveText('0 cr')
  await expect(cell).not.toHaveText(NO_PRICE_HERE)
  // The distinction that matters: this row is NOT flagged unpriced, the crystal row is.
  await expect(page.getByTestId('asset-stack-scan_data')).toHaveAttribute('data-unpriced', 'false')
  await expect(page.getByTestId('asset-stack-crystal')).toHaveAttribute('data-unpriced', 'true')
  // …and it does carry a unit price, because it has one.
  await expect(page.getByTestId('asset-stack-unit-scan_data')).toHaveText('0 cr each')
})

test('A TOTAL NEVER SILENTLY SWALLOWS AN UNPRICED STACK — the caveat is on screen', async ({ page }) => {
  await page.goto('/assets.html?state=mixed')
  // Haven Reach: scrap 126×5 = 630, weapon_parts 31×13 = 403, scan_data 40×0 = 0 → 1,033 priced,
  // with crystal and ore left out. Plus the fleet hold parked there: scrap 20×5 = 100.
  await expect(page.getByTestId('asset-place-total-loc-haven')).toHaveText('1,133 cr')
  // The caveat is on screen beside it — the number is never shown alone.
  await expect(page.getByTestId('asset-place-caveat-loc-haven')).toHaveText('2 kinds not priced here')
  // …and the pile it came from carries the same caveat in its own one-line total.
  await expect(page.getByTestId('asset-holding-total-storage-haven')).toContainText(
    '2 kinds not priced here',
  )

  // The grand total carries the same caveat — a sum of sums cannot launder a missing price.
  const grand = page.getByTestId('assets-grand-total')
  await expect(grand).toContainText('not priced here')

  // And the screen SAYS why, once, in plain words.
  await expect(page.getByTestId('assets-price-caveat')).toBeVisible()
  await expect(page.getByTestId('assets-price-caveat')).toContainText('it is unknown')
})

test('THE SAME ITEM IN TWO CITIES IS VALUED AT EACH CITY’S OWN PRICE, ON ONE SCREEN', async ({
  page,
}) => {
  await page.goto('/assets.html?state=mixed')
  // scrap is 5 cr at Haven Reach and 8 cr at Slagworks. Both cities are rendered at once, so the
  // two answers stand side by side — which is what "prices are per port" looks like to a player.
  const haven = page.getByTestId('asset-place-loc-haven')
  const slag = page.getByTestId('asset-place-loc-slag')
  await expect(haven.getByTestId('asset-stack-unit-scrap').first()).toHaveText('5 cr each')
  await expect(slag.getByTestId('asset-stack-unit-scrap')).toHaveText('8 cr each')
  // 200 × 8 = 1,600 at Slagworks — this city's own number, not Haven's.
  await expect(slag.getByTestId('asset-stack-value-scrap')).toHaveText('1,600 cr')
})

test('A PILE WHERE NOTHING IS PRICED SAYS SO — it does not report itself as worth 0 cr', async ({
  page,
}) => {
  await page.goto('/assets.html?state=unpriced')
  const total = page.getByTestId('asset-place-total-loc-slag')
  await expect(total).toHaveText('No prices here')
  await expect(total).not.toContainText('0 cr')
  await expect(page.getByTestId('asset-place-caveat-loc-slag')).toHaveText('2 kinds')
  const grand = page.getByTestId('assets-grand-total')
  await expect(grand).toHaveText('No prices here · 2 kinds')
  await expect(grand).not.toContainText('0 cr')
  // Every value cell on the page is the honest line, and not one of them shows a digit.
  const cells = await valueCells(page)
  expect(Object.values(cells).length).toBeGreaterThan(0)
  for (const [id, text] of Object.entries(cells)) {
    expect(text, `${id} value cell`).toBe(NO_PRICE_HERE)
  }
})

test('A FULLY PRICED LEDGER CARRIES NO CAVEAT — the warning means something because it is not always there', async ({
  page,
}) => {
  await page.goto('/assets.html?state=priced')
  await expect(page.getByTestId('assets-grand-total')).toHaveText('500 cr')
  await expect(page.getByTestId('assets-price-caveat')).toHaveCount(0)
  await expect(page.getByTestId('asset-place-total-loc-haven')).toHaveText('500 cr')
  // No caveat element at all — not an empty one, not a hidden one.
  await expect(page.getByTestId('asset-place-caveat-loc-haven')).toHaveCount(0)
})

// ── WHERE IT IS, AND WHOSE IT IS ────────────────────────────────────────────────────────────────

test('THE LEDGER IS GROUPED BY CITY, and the group that has no city sorts LAST', async ({ page }) => {
  await page.goto('/assets.html?state=mixed')
  const names = await page.evaluate(() =>
    [...document.querySelectorAll('[data-testid^="asset-place-"]:not([data-testid*="total"]) h2')].map(
      (h) => (h.textContent ?? '').trim(),
    ),
  )
  // Slagworks (1,600) leads Haven Reach (1,133); "Not at a port" is last, always — a group nothing
  // can be valued in must never head a ledger and make it look like the player owns nothing.
  expect(names).toEqual(['Slagworks', 'Haven Reach', 'Not at a port'])
})

test('"WHERE IS MY CARGO" IS ANSWERED: a fleet’s hold is on this screen, under the city it is parked in', async ({
  page,
}) => {
  await page.goto('/assets.html?state=mixed')
  const haven = page.getByTestId('asset-place-loc-haven')
  // The hold sits in the Haven Reach card, beside the port storage it loads from — no ship had to
  // be selected to get here, which is the whole point of the destination.
  await expect(haven.getByTestId('asset-holding-hold-fleet1')).toBeVisible()
  await expect(haven.getByTestId('asset-holding-hold-fleet1')).toContainText('Fleet 1 — carrying')
})

test('A HOLD SHOWS ITS CAP — a volume limit the player cannot see is a trap', async ({ page }) => {
  await page.goto('/assets.html?state=mixed')
  await expect(page.getByTestId('asset-holding-capacity-hold-fleet1')).toContainText('10 / 250 m³')
  // Port storage has no cap and therefore no meter — the two piles are not the same kind of thing.
  await expect(page.getByTestId('asset-holding-capacity-storage-haven')).toHaveCount(0)
})

test('AN OVER-CAPACITY HOLD SAYS SO, and says what to do about it', async ({ page }) => {
  await page.goto('/assets.html?state=mixed')
  const over = page.getByTestId('asset-holding-over-hold-fleet9')
  await expect(over).toBeVisible()
  await expect(over).toContainText('Over capacity')
})

test('A FLEET IN DEEP SPACE IS PRICED AT NOTHING, and the screen explains why', async ({ page }) => {
  await page.goto('/assets.html?state=mixed')
  const nowhere = page.getByTestId('asset-place-nowhere')
  await expect(nowhere).toContainText('Not at a port')
  await expect(nowhere).toContainText('a port has to be under you before anything has a price')
  await expect(page.getByTestId('asset-place-total-nowhere')).toHaveText('No prices here')
  await expect(page.getByTestId('asset-place-caveat-nowhere')).toHaveText('1 kind')
})

// ── HONEST FAILURE STATES ───────────────────────────────────────────────────────────────────────

test('AN UNREADABLE LEDGER IS NOT AN EMPTY ONE — they say different things', async ({ page }) => {
  await page.goto('/assets.html?state=unavailable')
  await expect(page.getByTestId('assets-unavailable')).toContainText(
    'read failure, not an empty ledger',
  )
  await expect(page.getByTestId('assets-empty')).toHaveCount(0)
  await expect(page.getByTestId('assets-places')).toHaveCount(0)
})

test('AN EMPTY LEDGER SAYS WHERE THINGS WOULD APPEAR, instead of a bare zero', async ({ page }) => {
  await page.goto('/assets.html?state=empty')
  await expect(page.getByTestId('assets-empty')).toContainText('not holding anything yet')
  await expect(page.getByTestId('assets-empty')).toContainText('storage of the port')
  await expect(page.getByTestId('assets-unavailable')).toHaveCount(0)
})

test('UNREADABLE PRICES ARE ANNOUNCED AS UNKNOWN, NOT AS ZERO', async ({ page }) => {
  await page.goto('/assets.html?state=noprices')
  const notice = page.getByTestId('assets-prices-unavailable')
  await expect(notice).toBeVisible()
  await expect(notice).toContainText('unknown, not zero')
  // …and every stack under it still renders the honest line rather than a fabricated 0.
  const cells = await valueCells(page)
  for (const [id, text] of Object.entries(cells)) {
    expect(text, `${id} value cell`).toBe(NO_PRICE_HERE)
  }
})

test('THE FIRST LOAD CLAIMS NOTHING — no ledger, no total, no zero', async ({ page }) => {
  await page.goto('/assets.html?state=loading')
  await expect(page.getByTestId('assets-grand-total')).toHaveCount(0)
  await expect(page.getByTestId('assets-places')).toHaveCount(0)
  await expect(page.getByTestId('assets-empty')).toHaveCount(0)
})

// ── NO SECOND COPIES ────────────────────────────────────────────────────────────────────────────

test('SHIPS AND FLEETS ARE LINKS TO THEIR OWN HOMES, not a second roster rendered here', async ({
  page,
}) => {
  await page.goto('/assets.html?state=mixed')
  await expect(page.getByTestId('assets-ships-link')).toHaveAttribute('href', '/ship')
  await expect(page.getByTestId('assets-fleets-link')).toHaveAttribute('href', '/fleet')
  await expect(page.getByTestId('assets-credits')).toHaveText('1,250')
})

test('THE FOOTNOTE NAMES THE RULE, so "No price here" never reads as a bug', async ({ page }) => {
  await page.goto('/assets.html?state=mixed')
  const note = page.getByTestId('assets-footnote')
  await expect(note).toContainText('Prices are per city')
  await expect(note).toContainText('does not mean it is worthless')
})

// ── IT HAS TO WORK ON THE PHONE THE OWNER PLAYS ON ──────────────────────────────────────────────

test('AT 320px THE LEDGER STILL READS — no sideways scroll, every value cell on screen', async ({
  page,
}) => {
  await page.setViewportSize({ width: 320, height: 720 })
  await page.goto('/assets.html?state=mixed')
  await expect(page.getByTestId('assets-places')).toBeVisible()
  const overflows = await page.evaluate(
    () => document.body.scrollWidth > document.body.clientWidth,
  )
  expect(overflows).toBe(false)
  // The no-price wording must not be the thing that gets truncated away.
  await expect(page.getByTestId('asset-stack-value-crystal')).toHaveText(NO_PRICE_HERE)
})
