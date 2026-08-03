import { test, expect, type Page } from '@playwright/test'

// ██ WHERE ARE MY FLEETS — the RENDERED proof. ██
//
// The owner: "in map, tell me where my fleets are too." Read off the LIVE game on 2026-08-04: the map
// carried exactly ONE `fleet-marker` for TWO fleets. Fleet 1 — four ships, one of them docked at
// Haven — had none. Four badge resolvers each answered "does this fleet get a marker?" for itself,
// and Fleet 1 matched none of them: the dock fold demanded a COMPLETE n/n rollup, and three of its
// ships carry the abolished `legacy_home` state, which the server projects as 'hidden'.
//
// tests/fleetPresence.spec.ts owns the RULE. This spec owns the thing a pure spec cannot see: that
// the badge reaches the DOM, that two fleets at one port do not write over each other, and that a
// fleet with no coordinate anywhere is still reported instead of quietly dropped. The harness mounts
// the REAL <GalaxyMap> over the owner's real production fleet shape; nothing connects.
//
// Run: `npx playwright test --config playwright.osnui.config.ts fleetMarkers`

const F1 = 'fleet-marker-g-fleet-1'
const F2 = 'fleet-marker-g-fleet-2'
const F3 = 'fleet-marker-g-fleet-3'

const boot = (page: Page, scenario?: 'unplaced') =>
  page.goto(scenario ? `/fleet.html?s=${scenario}` : '/fleet.html')

test('THE OWNER’S MAP: every fleet carries a marker — including the one that had none', async ({ page }) => {
  await boot(page)
  // The headline. Before this slice the count here was 1, and the missing one was the four-ship fleet.
  await expect(page.locator('[data-testid^="fleet-marker-"]')).toHaveCount(2)
  await expect(page.getByTestId(F1)).toHaveCount(1)
  await expect(page.getByTestId(F2)).toHaveCount(1)
})

test('the badge says HOW MUCH of the fleet is really placed — never a round number it cannot back', async ({ page }) => {
  await boot(page)
  // 1 of 4: Sparrow is at Haven; Sparrow III/IV/V are somewhere the server itself cannot name. The
  // fleet is on the map anyway, and the count is the honest part.
  await expect(page.getByTestId(F1)).toHaveText('Fleet 1 1/4')
  await expect(page.getByTestId(F2)).toHaveText('Fleet 2 1/1')
})

test('a fleet named "Fleet 1" is not announced as "Fleet Fleet 1"', async ({ page }) => {
  await boot(page)
  await expect(page.locator('#map-host svg').first()).not.toContainText('Fleet Fleet')
})

test('each fleet badge is drawn at ITS OWN port — the two never land on one another', async ({ page }) => {
  await boot(page)
  const a = await page.getByTestId(F1).boundingBox()
  const b = await page.getByTestId(F2).boundingBox()
  expect(a).not.toBeNull()
  expect(b).not.toBeNull()
  // Both on screen with real area (a badge collapsed to 0×0, or pushed off-canvas by a NaN in the
  // transform, is invisible while still "rendering").
  for (const box of [a!, b!]) {
    expect(box.width).toBeGreaterThan(0)
    expect(box.height).toBeGreaterThan(0)
  }
  // Haven sits left of and ABOVE Slagworks in world space (x -1200 y 900 vs x 1400 y -800), and the
  // map's projection flips the y axis (world y grows upward, screen y downward) — so Haven's badge is
  // left of and HIGHER ON SCREEN. Asserting both axes is what catches a badge placed from the right
  // numbers in the wrong space.
  expect(a!.x).toBeLessThan(b!.x)
  expect(a!.y).toBeLessThan(b!.y)
  // …and they do not overlap, which is what "not cluttered" means when it is measured.
  const overlaps =
    a!.x < b!.x + b!.width && b!.x < a!.x + a!.width && a!.y < b!.y + b!.height && b!.y < a!.y + a!.height
  expect(overlaps).toBe(false)
})

test('the badge is READABLE — it clears the port glyph instead of lying across it', async ({ page }) => {
  await boot(page)
  // Live on the owner's map, 2026-08-04: "Fleet 2 1/1" rendered ON TOP of the Slagworks diamond,
  // struck through by the glyph and its halo. It was on the map and it could not be read, which
  // answers "where are my fleets" with nothing. The clearance now comes from markerStyle, which is
  // the only module that knows how big a marker actually is.
  const badge = (await page.getByTestId(F2).boundingBox())!
  // The widest thing the marker actually DRAWS — measured, never assumed. The invisible hit disc is
  // excluded on purpose: it is a touch target, not ink, and nothing reads across it.
  const glyph = await page.evaluate(() => {
    const g = document.querySelector('g[data-testid="galaxy-location-marker"][data-location-id="b1a00002-0066-4a00-8a00-000000000002"]')!
    const boxes = [...g.querySelectorAll('circle')]
      .filter((c) => c.getAttribute('fill') !== 'transparent')
      .map((c) => c.getBoundingClientRect())
    return boxes.reduce((a, b) => (b.height > a.height ? b : a))
  })
  expect(badge.y).toBeGreaterThanOrEqual(glyph.bottom)
})

test('a fleet badge never steals the map’s tap target', async ({ page }) => {
  await boot(page)
  await expect(page.getByTestId(F1)).toHaveCSS('pointer-events', 'none')
})

test('a fleet the world cannot place is still ON the map — reported, never silently dropped', async ({ page }) => {
  await boot(page, 'unplaced')
  // Fleet 3's every ship is 'hidden': no port, no coordinate, nothing committed anywhere. There is no
  // honest world point for it, so it is not given one — it is listed instead, under the same testid
  // every placed badge uses, so "one marker per fleet" stays one query.
  await expect(page.locator('[data-testid^="fleet-marker-"]')).toHaveCount(3)
  await expect(page.getByTestId(F3)).toHaveText('Fleet 3 0/1 · location unknown')
  await expect(page.getByTestId('fleet-unplaced-rail')).toHaveCount(1)
  // …and it is NOT in the SVG: an unplaceable fleet must never acquire a coordinate on the way to
  // the screen. This is the assertion that fails if someone "fixes" the rail by drawing it at (0,0).
  await expect(page.locator('#map-host svg').first().getByTestId(F3)).toHaveCount(0)
  // The placed fleets are untouched by its presence.
  await expect(page.locator('#map-host svg').first().getByTestId(F1)).toHaveCount(1)
  await expect(page.locator('#map-host svg').first().getByTestId(F2)).toHaveCount(1)
})

test('with nothing unplaced the rail does not exist at all — a clean map stays clean', async ({ page }) => {
  await boot(page)
  await expect(page.getByTestId('fleet-unplaced-rail')).toHaveCount(0)
})
