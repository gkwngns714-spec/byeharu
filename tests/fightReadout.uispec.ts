import { test, expect, type Page } from '@playwright/test'
import { ENCOUNTER_ID } from './harness/fightFixtures'

// FIGHT READOUT — the RENDERED proof that a battle can be READ. Mounts the REAL <GalaxyMap> and the
// REAL <CombatMapCard> over a production-shaped fight in Chromium at a 390px phone width
// (tests/harness/fight.html) and measures what a player actually sees.
//
// WHY IT EXISTS. spatialCombatLayer.spec.ts pins the resolvers and combatMapCard.spec.ts pins the
// card's source shape. Every defect this file guards sits BETWEEN them, in the pixels:
//   · the whole engagement rendering smaller than the damage number drawn over it — a distance, in
//     CSS px, between two glyphs the browser placed;
//   · two hits on one hull collapsing into one number, and the killing blow rendering nothing — DOM
//     element counts under a real camera;
//   · a second, higher-tick battle blanking the newer one — one array, two encounters;
//   · there being no way to leave the fight from the screen that draws it — a button, or not.
// All of them typecheck, and all ~1682 pure specs stay green while they are true.
//
// EVERY MEASUREMENT IS THE BROWSER'S OWN ANSWER: `getBoundingClientRect()` on the rendered elements
// already contains the camera transform, the `xMidYMid meet` letterbox and the element's position,
// so nothing below re-derives geometry the code under test also derives.
//
// Run: `npx playwright test --config playwright.osnui.config.ts fightReadout.uispec.ts`

const MAP_SVG = '#map-host svg'
const CAMERA_G = `${MAP_SVG} > g[transform]`

/** The centre of a rendered element, in CSS px — the browser's own placement. */
async function centre(page: Page, testId: string): Promise<{ x: number; y: number }> {
  const box = await page.getByTestId(testId).boundingBox()
  if (!box) throw new Error(`no rendered box for ${testId}`)
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 }
}

const apart = (a: { x: number; y: number }, b: { x: number; y: number }) => Math.hypot(a.x - b.x, a.y - b.y)

/** The camera's current scale factor, straight off the transform attribute. */
async function cameraScale(page: Page): Promise<number> {
  return page.evaluate((sel) => {
    const g = document.querySelector(sel) as SVGGElement | null
    if (!g) throw new Error('no camera group')
    const m = /scale\(([-0-9.eE]+)\)/.exec(g.getAttribute('transform') ?? '')
    return m ? Number(m[1]) : NaN
  }, CAMERA_G)
}

test.beforeEach(async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 760 }) // the MAP box is 390px; see fight.html
  await page.goto('/fight.html')
  await page.waitForSelector(CAMERA_G)
})

// ── THE FIGHT IS VISIBLE AT ALL ────────────────────────────────────────────────────────────────────
// The formation is a 6-world-unit ring (0316). Against a 20000-unit world in a 1000-unit viewBox,
// the map's own content-fit camera renders that ring at single-digit pixels — narrower than the
// hitsplat disc drawn over it. This is the measurement, not the assertion of a belief about it.
test('the battle is FRAMED, not left as a few pixels of the default camera', async ({ page }) => {
  // p1 and p3 are on opposite sides of the formation ring: 12 world units apart.
  const gap = apart(await centre(page, 'spatial-combat-unit-p1'), await centre(page, 'spatial-combat-unit-p3'))
  // A 390px-wide map: anything under ~40px is a fight the player cannot read or aim at. Before the
  // focus control this measured in the single digits.
  expect(gap, 'the formation must span a readable part of the screen').toBeGreaterThan(80)
  // …and it got there by MOVING THE CAMERA, not by drawing the ships further apart than they are:
  // the camera scale is far above the content-fit scale a two-location world would produce.
  expect(await cameraScale(page)).toBeGreaterThan(50)
})

test('the focus control is offered while a battle has ships on the map', async ({ page }) => {
  await expect(page.getByTestId('map-focus-fight')).toBeVisible()
  // and it still frames the fight after the player has panned somewhere else entirely
  await page.mouse.move(200, 300)
  await page.mouse.down()
  await page.mouse.move(20, 640)
  await page.mouse.up()
  await page.getByTestId('map-focus-fight').click()
  const gap = apart(await centre(page, 'spatial-combat-unit-p1'), await centre(page, 'spatial-combat-unit-p3'))
  expect(gap).toBeGreaterThan(80)
})

// ── EVERY HIT SHOWS ITS OWN NUMBER ─────────────────────────────────────────────────────────────────
test('two hits on one hull in one tick render TWO numbers, not the last one', async ({ page }) => {
  const splats = page.locator('[data-testid^="spatial-combat-splat-"][data-unit="p2"]')
  await expect(splats).toHaveCount(2)
  const texts = (await splats.locator('text').allTextContents()).sort()
  // production tick 17: 4.136 and 4.286 — displayed rounded, but as TWO hits totalling what was
  // actually taken. The old resolver overwrote per unit and printed a single "4" for 8.4.
  expect(texts).toEqual(['4', '4'])
  // …and they do not sit on the same pixel
  const boxes = await splats.all()
  const a = await boxes[0].boundingBox()
  const b = await boxes[1].boundingBox()
  expect(Math.abs((a?.x ?? 0) - (b?.x ?? 0))).toBeGreaterThan(4)
})

test('the KILLING BLOW renders — both its damage and its kill mark', async ({ page }) => {
  // e3 took 9.4 and was destroyed in the same tick; its alive_count is already 0 in the row the
  // client reads, which is exactly why both used to vanish.
  const splats = page.locator('[data-testid^="spatial-combat-splat-"][data-unit="e3"]')
  await expect(splats).toHaveCount(2)
  await expect(page.locator('[data-testid^="spatial-combat-splat-"][data-unit="e3"][data-kill="true"]')).toHaveCount(1)
  const texts = await splats.locator('text').allTextContents()
  expect(texts).toContain('9')
  expect(texts).toContain('✕')
})

test('a destroyed unit still draws NO glyph — it is gone, only its last blow shows', async ({ page }) => {
  await expect(page.getByTestId('spatial-combat-unit-e3')).toHaveCount(0)
  await expect(page.getByTestId('spatial-combat-unit-e1')).toHaveCount(1)
})

test('every living hull carries its own health, as a bar and not a shade', async ({ page }) => {
  // p2 is at 41/120 and p1 at 120/120 — the pip widths must differ in the same proportion.
  const hurt = await page.getByTestId('spatial-combat-hull-p2').boundingBox()
  const whole = await page.getByTestId('spatial-combat-hull-p1').boundingBox()
  expect(hurt!.width).toBeLessThan(whole!.width * 0.5)
})

// ── TWO FIGHTS AT ONCE ─────────────────────────────────────────────────────────────────────────────
test('a second battle on a higher tick does not blank this one', async ({ page }) => {
  await expect(page.locator('[data-testid^="spatial-combat-splat-"][data-unit="p2"]')).toHaveCount(2)
  await page.getByTestId('toggle-second-fight').click()
  // the other encounter is at tick 80 against this one's 17; a global "latest tick" scan wiped
  // every splat and every fire line off THIS fight.
  await expect(page.locator('[data-testid^="spatial-combat-splat-"][data-unit="p2"]')).toHaveCount(2)
  await expect(page.getByTestId('spatial-combat-fire')).toHaveCount(1)
  // …and the older fight draws its own, too
  await expect(page.locator('[data-testid^="spatial-combat-splat-"][data-unit="o1"]')).toHaveCount(1)
})

// ── AM I WINNING? ──────────────────────────────────────────────────────────────────────────────────
test('the card shows two HULL bars and never calls the enemy number "power"', async ({ page }) => {
  const card = page.getByTestId(`combat-map-card-${ENCOUNTER_ID}`)
  await expect(card).toBeVisible()
  await expect(card.getByTestId(`combat-map-side-player-${ENCOUNTER_ID}`)).toBeVisible()
  await expect(card.getByTestId(`combat-map-side-enemy-${ENCOUNTER_ID}`)).toBeVisible()
  // `enemy_power_current` is the enemy's remaining INTEGRITY (0299:150-156). The card used to print
  // it as "Power 116" beside the player's real attack power of 15 — the same word for two unrelated
  // quantities, pointing the player the wrong way.
  await expect(card).not.toContainText('Power')
  await expect(card).toContainText('279')
  await expect(card).toContainText('116')
})

test('the card shows the LAST EXCHANGE both ways — the rate a static bar cannot show', async ({ page }) => {
  const line = page.getByTestId(`combat-map-exchange-${ENCOUNTER_ID}`)
  await expect(line).toBeVisible()
  await expect(line).toContainText('15') // dealt
  await expect(line).toContainText('8') // taken (7.5, rounded)
})

test('the auto-retreat line is stated AND marked on the bar', async ({ page }) => {
  await expect(page.getByTestId(`combat-map-auto-exit-${ENCOUNTER_ID}`)).toContainText('30%')
  const mark = page.getByTestId(`combat-map-side-player-${ENCOUNTER_ID}-auto-exit-mark`)
  await expect(mark).toBeVisible()
  // the mark sits at 30% of the track, not at the fill's edge
  const track = await page.getByTestId(`combat-map-side-player-${ENCOUNTER_ID}`).locator('div.relative').boundingBox()
  const markBox = await mark.boundingBox()
  expect((markBox!.x - track!.x) / track!.width).toBeCloseTo(0.3, 1)
})

// ── LEAVING IS ONE CLICK, ON THE SCREEN THAT DRAWS THE FIGHT ───────────────────────────────────────
test('Retreat is on the MAP, next to the battle it ends', async ({ page }) => {
  const retreat = page.getByTestId(`combat-map-retreat-${ENCOUNTER_ID}`)
  await expect(retreat).toBeVisible()
  expect(await retreat.evaluate((el) => el.tagName)).toBe('BUTTON')
  await expect(retreat).toHaveText('Retreat')
  await expect(retreat).toBeEnabled()
})
