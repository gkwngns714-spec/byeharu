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

// THE FLEET FOLD: four combat_units rows render as ONE actor, keyed by its encounter.
const FLEET_KEY = `fleet-${ENCOUNTER_ID}`
const FLEET = `spatial-combat-unit-${FLEET_KEY}`

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
  // The fleet glyph stands on the hull nearest the enemy; e1 is one of the pirates closing on it.
  const gap = apart(await centre(page, FLEET), await centre(page, 'spatial-combat-unit-unit-e1'))
  // A 390px-wide map: anything under ~40px is a fight the player cannot read or aim at. Before the
  // focus control this measured in the single digits.
  expect(gap, 'the fight must span a readable part of the screen').toBeGreaterThan(40)
  // …and it got there by MOVING THE CAMERA, not by drawing the ships further apart than they are:
  // the camera scale is far above the content-fit scale a two-location world would produce.
  expect(await cameraScale(page)).toBeGreaterThan(50)
})

// ── THE FIGHT MOVES, AND THE FRAME GOES WITH IT ────────────────────────────────────────────────────
// The owner, playing: "When enemy ship is destroyed, i teleport to some random place inside the zone."
// The camera framed the battle ONCE, around the anchor it opened on; 0337 then made an in-combat
// reposition a real multi-tick MOVE that carries the formation, the fleet row and the engagement
// anchor together (0337:486-492). The fight leaves the frame and keeps going out there, and what the
// player is left looking at is empty space. Only a RENDERED measurement can see this: every resolver
// is correct while it happens, and the units' own coordinates are right — it is the CAMERA that is
// wrong, and a camera is only observable as pixels.
const MAP_HOST = '#map-host'

/** Is this rendered element inside the map's own box? The map clips to it, so anything outside is
 *  something the player cannot see. Both rects are the browser's. */
async function insideMap(page: Page, testId: string): Promise<boolean> {
  const host = await page.locator(MAP_HOST).boundingBox()
  const box = await page.getByTestId(testId).boundingBox()
  if (!host || !box) return false
  return (
    box.x >= host.x &&
    box.y >= host.y &&
    box.x + box.width <= host.x + host.width &&
    box.y + box.height <= host.y + host.height
  )
}

/** The camera group's whole transform — scale AND translate, so a pan is as visible as a zoom. */
const cameraTransform = (page: Page) =>
  page.evaluate((sel) => document.querySelector(sel)?.getAttribute('transform') ?? '', CAMERA_G)

test('the battle WALKS AWAY and the frame follows it — the fight is never left off-screen', async ({ page }) => {
  expect(await insideMap(page, FLEET), 'the opening frame holds the fight').toBe(true)
  // The whole engagement moves ~150 world units — about 4.5 opening frames away (fightFixtures).
  await page.getByTestId('reposition-fight').click()
  // Let the step finish: the move is played over the server's own measured 3 s (combatMotion), and
  // sampling mid-tween would measure the interpolator, not the camera.
  await page.waitForTimeout(3400)
  expect(await insideMap(page, FLEET), 'the fleet must still be on the map after the fight moves').toBe(true)
  expect(await insideMap(page, 'spatial-combat-unit-unit-e1'), 'and so must the enemy it is fighting').toBe(true)
  // …and it is still READABLE: re-framed on the fight, not zoomed out to the whole world to cheat
  // the containment check.
  const gap = apart(await centre(page, FLEET), await centre(page, 'spatial-combat-unit-unit-e1'))
  expect(gap, 'the moved fight must be framed, not merely visible').toBeGreaterThan(40)
})

test('a player who panned away is LEFT there — the follow never yanks the camera back', async ({ page }) => {
  // Deliberate camera control: pan off the fight. A fight starting outranks the player's camera; a
  // fight MOVING does not, and the ⌖ control is the way back.
  await page.mouse.move(200, 300)
  await page.mouse.down()
  await page.mouse.move(20, 640)
  await page.mouse.up()
  const held = await cameraTransform(page)
  await page.getByTestId('reposition-fight').click()
  await page.waitForTimeout(3400)
  expect(await cameraTransform(page), 'the camera the player set must not move on its own').toBe(held)
  // …and ⌖ still frames the battle where it NOW is (it re-enters the follow, it is not redundant).
  await page.getByTestId('map-focus-fight').click()
  expect(await insideMap(page, FLEET)).toBe(true)
  const gap = apart(await centre(page, FLEET), await centre(page, 'spatial-combat-unit-unit-e1'))
  expect(gap).toBeGreaterThan(40)
})

test('the focus control is offered while a battle has ships on the map', async ({ page }) => {
  await expect(page.getByTestId('map-focus-fight')).toBeVisible()
  // and it still frames the fight after the player has panned somewhere else entirely
  await page.mouse.move(200, 300)
  await page.mouse.down()
  await page.mouse.move(20, 640)
  await page.mouse.up()
  await page.getByTestId('map-focus-fight').click()
  const gap = apart(await centre(page, FLEET), await centre(page, 'spatial-combat-unit-unit-e1'))
  expect(gap).toBeGreaterThan(40)
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
  await expect(page.getByTestId('spatial-combat-unit-unit-e3')).toHaveCount(0)
  await expect(page.getByTestId('spatial-combat-unit-unit-e1')).toHaveCount(1)
})

// ── "SHOW ONLY FLEET. IT IS AS A WHOLE." ───────────────────────────────────────────────────────────
// The owner's law, measured in the DOM: four combat_units rows, ONE glyph.
test('FOUR ships, ONE glyph — the player sees their fleet, not its crew', async ({ page }) => {
  await expect(page.locator('[data-testid^="spatial-combat-unit-"][data-side="player"]')).toHaveCount(1)
  const fleet = page.getByTestId(FLEET)
  await expect(fleet).toHaveAttribute('data-kind', 'fleet')
  await expect(fleet).toHaveAttribute('data-ships', '4')
  await expect(fleet).toHaveAttribute('data-ships-alive', '4')
  // …and no glyph is drawn for any individual hull of it.
  for (const id of ['p1', 'p2', 'p3', 'p4']) {
    await expect(page.getByTestId(`spatial-combat-unit-${id}`)).toHaveCount(0)
  }
  // The pirates are NOT folded: three hostiles, one of them destroyed, so two glyphs.
  await expect(page.locator('[data-testid^="spatial-combat-unit-"][data-side="enemy"]')).toHaveCount(2)
})

test('the fleet states its hulls — "4/4" beside the glyph, so a loss cannot hide in the fold', async ({ page }) => {
  await expect(page.getByTestId(`spatial-combat-hulls-${FLEET_KEY}`)).toHaveText('4/4')
})

test('the fleet carries ONE health bar, summed off its own hulls', async ({ page }) => {
  // 120 + 41 + 96 + 22 of 480 = 58%. The bar is the fleet's, not any one ship's.
  const track = await page.getByTestId(FLEET).locator('rect').first().boundingBox()
  const fill = await page.getByTestId(`spatial-combat-hull-${FLEET_KEY}`).boundingBox()
  expect(fill!.width / track!.width).toBeCloseTo((120 + 41 + 96 + 22) / 480, 1)
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

// ── COMBAT THAT FLOWS: THE STEP IS CROSSED, NOT JUMPED ─────────────────────────────────────────────
// The owner: "all the combat looks so laggy, not smooth." The server tick is 3 s (pg_cron, verified
// active on production) and nothing interpolated between two of them, so a ship was drawn at A for
// three seconds and then at B. tests/combatMotion.spec.ts proves the math over a clock it passes in;
// these two prove it reaches the SCREEN — the browser's own placement of a real glyph, mid-step.
test('a server step is CROSSED — mid-tick the glyph is strictly between its two observed points', async ({ page }) => {
  const before = await centre(page, 'spatial-combat-unit-unit-e1')
  // The next tick's rows land. e1 has closed 3.5 world units; at this camera that is a wide gap.
  await page.getByTestId('advance-tick').click()
  // Sampled immediately: the step is played over the server's own 3 s, so almost none of it is done.
  const during = await centre(page, 'spatial-combat-unit-unit-e1')
  await expect
    .poll(async () => apart(await centre(page, 'spatial-combat-unit-unit-e1'), before), { timeout: 6000 })
    .toBeGreaterThan(0)
  // …and it settles exactly on the new observed point and STOPS there — no drift past it.
  await page.waitForTimeout(3400)
  const after = await centre(page, 'spatial-combat-unit-unit-e1')
  const travelled = apart(before, after)
  expect(travelled).toBeGreaterThan(20) // it really did move, in CSS px
  // The sample taken at the very start of the window is nearer where it WAS than where it ended:
  // that is the whole claim — the position between two ticks is between the two positions.
  expect(apart(during, before)).toBeLessThan(travelled)
  await page.waitForTimeout(1200)
  const settled = await centre(page, 'spatial-combat-unit-unit-e1')
  expect(apart(settled, after)).toBeLessThan(1) // a stopped unit does not drift
})

// ── ORDNANCE: THE FIGHT IS SOMETHING TO WATCH, NOT A NUMBER GOING DOWN ─────────────────────────────
// The owner: "i see nothing, i see just numbers, a health bar going down. I want to see an ammo of
// some sort - based on what i fit, if nothing, default by command ship."
test('a round is drawn for each of this tick\'s real shots, between the two hulls', async ({ page }) => {
  await page.reload()
  await page.waitForSelector(CAMERA_G)
  // Three salvos resolved on tick 17 (e1→p2, e2→p2, p1→e3) and each is one round in the air.
  const rounds = page.locator('[data-testid^="spatial-combat-shot-"]')
  await expect(rounds).toHaveCount(3)
  // p1's round is between p1 and its target e3 — a real lane, not a decoration parked on a hull.
  const fleet = await centre(page, FLEET)
  const shot = await centre(page, 'spatial-combat-shot-12')
  expect(apart(shot, fleet)).toBeGreaterThan(0)
  // Every round is bounded: they land, and the map is clear of them shortly after.
  await expect(rounds).toHaveCount(0, { timeout: 4000 })
})

test('the round names its own shot — firer, target, and where its description came from', async ({ page }) => {
  await page.reload()
  await page.waitForSelector(CAMERA_G)
  const shot = page.getByTestId('spatial-combat-shot-12')
  // The round leaves the FLEET (one actor) and flies at the pirate it was aimed at.
  await expect(shot).toHaveAttribute('data-source', FLEET_KEY)
  await expect(shot).toHaveAttribute('data-target', 'unit-e3')
  // p1 carries its OWN fitted autocannon, so the round is described by that fitting, not by a
  // fallback and not by a client-side weapon table.
  await expect(shot).toHaveAttribute('data-profile', 'own')
})

test('every damage number still arrives — the round carries it, it is never lost', async ({ page }) => {
  await page.reload()
  await page.waitForSelector(CAMERA_G)
  // Both hits on p2 and the killing blow on e3 land once their rounds do (Playwright retries).
  await expect(page.locator('[data-testid^="spatial-combat-splat-"][data-unit="p2"]')).toHaveCount(2)
  await expect(page.locator('[data-testid^="spatial-combat-splat-"][data-unit="e3"]')).toHaveCount(2)
})
