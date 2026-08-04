import { test, expect, type Page } from '@playwright/test'

// PORT SHOP — THE RENDERED PROOF that a dormant stat is not advertised at point of sale.
//
// THE RULING (owner, 2026-08-04): "A dormant stat must not be represented as an effective player
// benefit," and here: "A player must not spend resources on a benefit the engine does not apply."
//
// The pure spec (portShopTruth.spec.ts) proves the model drops the chip. This proves the SCREEN
// does — that nothing downstream put "Mining yield +8" back, that the not-implemented sentence
// actually renders, that the Buy affordance is genuinely withdrawn, and that none of it clips or
// scrolls sideways at the house floors.
//
// Every offer is the real production catalog row (module_types, read with the anon key 2026-08-04).

const FLOORS = [
  { name: '288px (the house floor)', width: 288 },
  { name: '320px', width: 320 },
]

async function open(page: Page, width: number) {
  await page.setViewportSize({ width, height: 900 })
  await page.goto('/shop.html')
  await expect(page.getByTestId('shop-offers')).toBeVisible()
}

// ── THE DORMANT CLAIM IS OFF THE SCREEN ─────────────────────────────────────────────────────────

test('NO DORMANT STAT REACHES THE SCREEN — no chip anywhere says mining, scan or evasion', async ({ page }) => {
  await open(page, 390)
  const body = (await page.getByTestId('shop-offers').innerText()).toLowerCase()
  // the named violation: portShop.ts:49 rendered `mining: 'Mining yield'`
  expect(body).not.toContain('mining yield')
  // …and the whole dormant vocabulary with it. "Mining Rig Extension" is the module's NAME, so the
  // check is against the chips, which is where a claim lives.
  const chips = await page.locator('[data-testid^="shop-chip-"]').allInnerTexts()
  for (const chip of chips) {
    const t = chip.toLowerCase()
    for (const dormant of ['mining', 'scouting', 'scan', 'retreat safety', 'evasion', 'repair', 'pirate attention']) {
      expect(t, `a chip advertises the dormant stat ${dormant}`).not.toContain(dormant)
    }
  }
  expect(chips.length, 'the proof is vacuous if no chip rendered at all').toBeGreaterThan(0)
})

test('ACTIVE stats are still on the screen — the fix hid the dead ones, not the live ones', async ({ page }) => {
  await open(page, 390)
  await expect(page.getByTestId('shop-chip-shield_lattice-defense')).toHaveText(/Survival \+12/)
  await expect(page.getByTestId('shop-chip-autocannon_battery-attack')).toHaveText(/Combat Power \+10/)
  await expect(page.getByTestId('shop-chip-vector_thruster_kit-speed_mult_bonus')).toHaveText(/Speed \+10%/)
})

test('a DEPRECATED stat is shown and MARKED legacy, never as a live effect', async ({ page }) => {
  await open(page, 390)
  const chip = page.getByTestId('shop-chip-expanded_cargo_lattice-cargo')
  await expect(chip).toBeVisible()
  await expect(chip).toContainText('25')
  await expect(chip).toContainText('legacy')
})

// ── THE TWO CATALOG ROWS, EACH GETTING ITS OWN TREATMENT ────────────────────────────────────────

test('the mining rig KEEPS its live attributes and stays buyable — only the dead chip is gone', async ({ page }) => {
  await open(page, 390)
  const row = page.getByTestId('shop-offer-mining_rig_extension')
  await expect(row).toBeVisible()
  await expect(page.getByTestId('shop-chip-mining_rig_extension-range')).toHaveText('Range 120')
  await expect(page.getByTestId('shop-chip-mining_rig_extension-power')).toHaveText('Power 8')
  await expect(page.getByTestId('shop-chip-mining_rig_extension-mining')).toHaveCount(0)
  // it has a live effect (mining_extract reads max(range) over fitted mining modules, 0229:309-321,
  // and module_range_attributes_enabled is TRUE in production), so it must NOT be withdrawn.
  await expect(page.getByTestId('shop-no-effect-mining_rig_extension')).toHaveCount(0)
  await expect(page.getByTestId('shop-buy-mining_rig_extension')).toBeEnabled()
})

test('the deep-scan array — whose ONLY claimed effect is dormant — says so and cannot be bought', async ({ page }) => {
  await open(page, 390)
  await expect(page.getByTestId('shop-offer-deep_scan_sensor_array')).toBeVisible()
  // it is not deleted: the catalog row, the name, the price and the description all still render.
  await expect(page.getByTestId('shop-offer-deep_scan_sensor_array')).toContainText('Deep-Scan Sensor Array')
  await expect(page.getByTestId('shop-price-deep_scan_sensor_array')).toBeVisible()
  // its dead claim is gone…
  await expect(page.getByTestId('shop-chip-deep_scan_sensor_array-scan')).toHaveCount(0)
  // …and the row says plainly that it does nothing, in words, with no jargon.
  const note = page.getByTestId('shop-no-effect-deep_scan_sensor_array')
  await expect(note).toBeVisible()
  await expect(note).toHaveText('Not currently implemented — this does nothing in the game yet.')
  // A player must not spend resources on a benefit the engine does not apply.
  await expect(page.getByTestId('shop-buy-deep_scan_sensor_array')).toBeDisabled()
})

// ── AVAILABILITY IS THE SERVER'S, ON THE SCREEN (0342) ──────────────────────────────────────────
// THE VERDICT (owner, 2026-08-04): "A disabled React button is not purchase prevention." The gate is
// migration 0342 setting port_shop_offers.active = false; these two tests prove the SCREEN never
// contradicts it — a row the server's answer does not contain has a dead Buy and says why, and it
// gets there with no client rule that recognises a particular item id.

test('A ROW THE SERVER DID NOT OFFER CANNOT BE BOUGHT — dead Buy, and it says why', async ({ page }) => {
  await open(page, 390)
  const row = page.getByTestId('shop-offer-autocannon_battery_mk2')
  await expect(row).toBeVisible()
  // it is a full, attractive row with a LIVE effect — nothing about its content withholds it…
  await expect(page.getByTestId('shop-chip-autocannon_battery_mk2-attack')).toHaveText(/Combat Power \+18/)
  await expect(page.getByTestId('shop-no-effect-autocannon_battery_mk2')).toHaveCount(0)
  // …and it is still not for sale here, because the server's answer does not carry it.
  await expect(page.getByTestId('shop-buy-autocannon_battery_mk2')).toBeDisabled()
  await expect(page.getByTestId('shop-blocked-autocannon_battery_mk2')).toHaveText(
    'This port does not stock that.',
  )
})

test('the two refusals are INDEPENDENT — a live-effect row is withheld with no lifecycle verdict, and vice versa', async ({ page }) => {
  await open(page, 390)
  // withdrawn-by-the-server: blocked line, NO not-implemented sentence.
  await expect(page.getByTestId('shop-blocked-autocannon_battery_mk2')).toBeVisible()
  await expect(page.getByTestId('shop-no-effect-autocannon_battery_mk2')).toHaveCount(0)
  // dormant-only-but-offered: not-implemented sentence, NO blocked line. If these ever collapse into
  // one answer, one of the two purchase-prevention paths has quietly stopped existing.
  await expect(page.getByTestId('shop-no-effect-deep_scan_sensor_array')).toBeVisible()
  await expect(page.getByTestId('shop-blocked-deep_scan_sensor_array')).toHaveCount(0)
  await expect(page.getByTestId('shop-buy-deep_scan_sensor_array')).toBeDisabled()
})

test('every other offer is still buyable — nothing was withdrawn by accident', async ({ page }) => {
  await open(page, 390)
  for (const ref of [
    'mining_rig_extension',
    'vector_thruster_kit',
    'expanded_cargo_lattice',
    'shield_lattice',
    'autocannon_battery',
  ]) {
    await expect(page.getByTestId(`shop-buy-${ref}`), `${ref} lost its Buy`).toBeEnabled()
  }
})

// ── THE HOUSE FLOORS ────────────────────────────────────────────────────────────────────────────

for (const floor of FLOORS) {
  test(`fits at ${floor.name}: nothing clips, nothing scrolls sideways, Buy stays tappable`, async ({ page }) => {
    await open(page, floor.width)

    const overflow = await page.evaluate(() => ({
      doc: document.documentElement.scrollWidth,
      client: document.documentElement.clientWidth,
    }))
    expect(overflow.doc, 'the page scrolls sideways').toBeLessThanOrEqual(overflow.client)

    // The not-implemented sentence is the whole point of the change; it must be readable, not a
    // clipped stub, and it must sit inside its row.
    const note = page.getByTestId('shop-no-effect-deep_scan_sensor_array')
    await expect(note).toBeVisible()
    const noteBox = (await note.boundingBox())!
    const rowBox = (await page.getByTestId('shop-offer-deep_scan_sensor_array').boundingBox())!
    expect(noteBox.width).toBeGreaterThan(0)
    expect(noteBox.x + noteBox.width).toBeLessThanOrEqual(rowBox.x + rowBox.width + 1)
    expect(noteBox.height, 'the note collapsed to one clipped line').toBeGreaterThan(8)

    // THE WITHDRAWN BUY IS STILL A BUTTON, THE SAME SIZE AS EVERY OTHER. A disabled control that
    // also shrinks or vanishes reads as a broken row rather than an explained one, and the sentence
    // above it would then be explaining nothing the player can see.
    //
    // MEASURED, AND REPORTED RATHER THAN SILENTLY FIXED: the shop's Buy is a `size="sm"` Button and
    // renders 24px tall — BELOW the house 44px touch minimum — at every width, for every row,
    // exactly as it did before this change. Raising it is a shop-wide control change with nothing to
    // do with stat lifecycle, so this slice does not make it and does not pretend the floor is met.
    // Pinned at the measured value so the debt is visible and cannot quietly get worse.
    const buyBoxes: Record<string, { w: number; h: number }> = {}
    for (const ref of ['deep_scan_sensor_array', 'mining_rig_extension', 'shield_lattice']) {
      const box = (await page.getByTestId(`shop-buy-${ref}`).boundingBox())!
      buyBoxes[ref] = { w: Math.round(box.width), h: Math.round(box.height) }
    }
    expect(buyBoxes.deep_scan_sensor_array, 'the withdrawn Buy changed size').toEqual(
      buyBoxes.shield_lattice,
    )
    expect(buyBoxes.deep_scan_sensor_array).toEqual(buyBoxes.mining_rig_extension)
    expect(buyBoxes.shield_lattice.h, 'pre-existing: the shop Buy is 24px, under the 44px floor').toBe(24)

    // chips wrap rather than push the row wide
    for (const chip of await page.locator('[data-testid^="shop-chip-"]').all()) {
      const box = (await chip.boundingBox())!
      expect(box.x + box.width).toBeLessThanOrEqual(floor.width + 1)
    }
  })
}
