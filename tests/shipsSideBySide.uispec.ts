import { test, expect, type Page } from '@playwright/test'

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// SIDE BY SIDE — THE SHIPS TAB, MEASURED.
//
// Owner order, 2026-08-04: "i want the ships of fleet info, and ship as individual info side by
// side on ships tab". Both surfaces already lived on that tab — but in the SAME rail, one under the
// other, so picking a ship pushed its panel below the whole fleet list and the two facts could not
// be read together at any width.
//
// The fix is a layout claim, and a layout claim is a statement about where two boxes ARE. Prose
// cannot fail when a class changes underneath it — that is how a stale numeric justification
// survived in navTabs.ts until navFits.uispec.ts measured the bar. So every claim below is read
// back out of the DOM, on the REAL <ShipsView> with the REAL design system loaded:
//
//   · at 1280px — the fleet panel and the ship panel are side by side: their horizontal ranges are
//     disjoint and their vertical ranges overlap. Both are visible at once;
//   · at 320px (the phone floor the nav is also measured at) — they STACK, the page does not scroll
//     sideways, and neither panel clips its own content;
//   · every roster row clears the 44px touch floor, at both widths;
//   · with nothing selected the ship column is not an empty gap — the rail self-collapses and the
//     fleet panel takes the full row;
//   · a DESTROYED ship is still in the list. The owner has wrecks at Haven; a wreck filtered out of
//     the roster is a ship they cannot reach the repair surface for.
//
// PRECONDITIONS ARE FIXTURES THIS FILE OWNS: the viewport and the selection are set here, never
// inherited. The harness (tests/harness/shipsHarness.tsx) carries the owner's live fleet shape.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

/** The narrowest phone the game supports — the same floor navFits.uispec.ts measures the bar at. */
const PHONE_FLOOR = 320
/** The touch-target floor the design system commits to. */
const TOUCH_FLOOR = 44
/** A desktop width comfortably past Tailwind's lg (1024px) breakpoint, where the split goes 2-up. */
const WIDE = 1280

/** Sparrow — Fleet 1's docked ship, and the row every selection test clicks. */
const SPARROW = 's-sparrow'
/** Sparrow IV — DESTROYED. It must never be filtered out of the roster. */
const WRECK = 's-sparrow-iv'
/** Kestrel — in no fleet at all (group_id NULL ⇔ berthed). */
const LONER = 's-kestrel'

// THE HARNESS TALKS TO NOTHING. <FittingDetail> fires its own per-ship reads on mount; with no
// server there they never SETTLE, and the panel would sit in its loading skeleton forever — so a
// proof that measured it would be measuring a skeleton and calling it the ship panel. Every call to
// the dummy Supabase origin is answered here with an empty 200, which is what the wrappers already
// treat as "nothing to show": the detail then renders its REAL markup over the harness's injected
// facts (identity, location, hull meter, equipped modules, cargo hold). Nothing is stubbed inside
// the component, and nothing leaves the machine.
test.beforeEach(async ({ page }) => {
  await page.route('http://localhost:54321/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: '[]' }),
  )
})

interface Box {
  x: number
  y: number
  width: number
  height: number
}

/** Open the harness and wait until what is on screen is STABLE enough to measure: the fleet panel
 *  rendered, and the web font settled. A box read while the fallback font is still in place is a
 *  box that will move — measuring it would make this file's own numbers a race. */
async function open(page: Page, url = '/ships.html') {
  await page.goto(url)
  await expect(page.getByTestId('fitting-roster')).toBeVisible()
  await page.evaluate(() => document.fonts.ready.then(() => undefined))
}

async function boxOf(page: Page, testId: string): Promise<Box> {
  const box = await page.getByTestId(testId).boundingBox()
  expect(box, `${testId} has no rendered box`).not.toBeNull()
  return box as Box
}

/** Click a roster row and wait for the ship panel it opens. */
async function selectShip(page: Page, shipId: string) {
  await page.getByTestId(`fitting-row-${shipId}`).click()
  await expect(page.getByTestId('fitting-detail')).toBeVisible()
}

/** Does the document scroll sideways? The house rule is that it never may. */
async function scrollsSideways(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const b = document.body
    const d = document.documentElement
    return b.scrollWidth > b.clientWidth || d.scrollWidth > d.clientWidth
  })
}

test('WIDE — the fleet panel and the ship panel are SIDE BY SIDE, both on screen at once', async ({
  page,
}) => {
  await page.setViewportSize({ width: WIDE, height: 900 })
  await open(page)
  await selectShip(page, SPARROW)

  const fleet = await boxOf(page, 'fitting-roster')
  const ship = await boxOf(page, 'fitting-detail')

  // SIDE BY SIDE = disjoint horizontally (1px tolerance for sub-pixel layout) …
  expect(
    fleet.x + fleet.width,
    'the fleet panel must end before the ship panel begins',
  ).toBeLessThanOrEqual(ship.x + 1)
  // … and overlapping vertically. Two boxes that merely sit in different columns but at different
  // heights are not "at the same time" for a reader.
  const overlap = Math.min(fleet.y + fleet.height, ship.y + ship.height) - Math.max(fleet.y, ship.y)
  expect(overlap, 'the two panels must share vertical space').toBeGreaterThan(0)
  // Both start at the top of the split — neither is pushed below the fold by the other.
  expect(Math.abs(fleet.y - ship.y), 'the two columns are top-aligned').toBeLessThan(80)
  expect(await scrollsSideways(page)).toBe(false)
})

test('WIDE — the ship column is the WIDE track and the fleet index the narrow one', async ({
  page,
}) => {
  await page.setViewportSize({ width: WIDE, height: 900 })
  await open(page)
  await selectShip(page, SPARROW)
  const fleet = await boxOf(page, 'fitting-roster')
  const ship = await boxOf(page, 'fitting-detail')
  // The roster is the index; the ship panel is the content. The 1fr track it sits in is ~the same
  // width as the phone floor this file also renders the roster at, so the list is never squeezed
  // into a width it has not been proven at.
  expect(ship.width, 'the ship panel takes the wider track').toBeGreaterThan(fleet.width)
  expect(fleet.width, 'the fleet index is at least as wide as the phone floor it renders at').toBeGreaterThanOrEqual(
    PHONE_FLOOR - 60,
  )
})

test('320px — the two panels STACK, and the page never scrolls sideways', async ({ page }) => {
  await page.setViewportSize({ width: PHONE_FLOOR, height: 720 })
  await open(page)
  await selectShip(page, SPARROW)

  const fleet = await boxOf(page, 'fitting-roster')
  const ship = await boxOf(page, 'fitting-detail')
  // Stacked: the ship panel starts below the fleet panel, and they share the same left edge.
  expect(ship.y, 'the ship panel sits below the fleet panel on a phone').toBeGreaterThanOrEqual(
    fleet.y + fleet.height - 1,
  )
  expect(Math.abs(ship.x - fleet.x), 'both panels use the full column').toBeLessThan(2)
  expect(await scrollsSideways(page)).toBe(false)
})

/** Every container the tab lays out. A `truncate`d leaf is deliberately allowed to overflow its own
 *  box — that is what truncation IS — so the check is on the boxes that would push the PAGE. */
async function panelOverflow(page: Page) {
  return page.evaluate(() => {
    const ids = ['ships-split', 'ships-fleet-rail', 'ships-ship-rail', 'fitting-roster', 'fitting-detail']
    return ids.map((id) => {
      const el = document.querySelector(`[data-testid="${id}"]`) as HTMLElement
      return { id, scroll: el.scrollWidth, client: el.clientWidth }
    })
  })
}

test('320px — nothing clips: no panel overflows its own box', async ({ page }) => {
  await page.setViewportSize({ width: PHONE_FLOOR, height: 720 })
  await open(page)
  await selectShip(page, SPARROW)
  for (const o of await panelOverflow(page)) {
    expect(o.scroll, `${o.id} overflows its own width`).toBeLessThanOrEqual(o.client)
  }
})

// ── THE MARGIN TEST, and why it exists ──────────────────────────────────────────────────────────
// The version of this file that first went to CI checked the line above at exactly 320px and passed
// on the author's Windows machine with NINE pixels to spare. CI's Linux Chromium failed it twice:
// `ships-split` wanted 291px inside 288px. Nothing was flaky and nothing was different about the
// code — the tab's tightest row (a CardHeader: a title beside a `shrink-0` badge) had a minimum
// width made of GLYPH WIDTHS, and glyph widths are not a constant across platforms. A 9px margin is
// not a margin; it is a coin toss that this machine happened to win.
//
// So the floor is no longer measured only AT the floor. This runs the same check 10% narrower, at
// 288px, which is 32px of proven headroom at 320 — an order of magnitude more than the ~3% the
// platforms disagreed by. The fix that made this pass was CardHeader gaining `flex-wrap`, so a badge
// that will not fit beside a title drops below it instead of adding its width to the row's minimum.
// Run this against the unwrapped header and it fails, which is the whole point of keeping it.
test('288px — the 320px floor has REAL margin, not a font-metric coin toss', async ({ page }) => {
  await page.setViewportSize({ width: 288, height: 720 })
  await open(page)
  await selectShip(page, SPARROW)
  for (const o of await panelOverflow(page)) {
    expect(o.scroll, `${o.id} has no margin below the phone floor`).toBeLessThanOrEqual(o.client)
  }
  expect(await scrollsSideways(page)).toBe(false)
})

test('EVERY ROSTER ROW CLEARS THE 44px TOUCH FLOOR — at 320px and at 1280px', async ({ page }) => {
  for (const width of [PHONE_FLOOR, WIDE]) {
    await page.setViewportSize({ width, height: 900 })
    await open(page)
    await expect(page.getByTestId('fitting-roster')).toBeVisible()
    const rows = await page.evaluate(() =>
      [...document.querySelectorAll('[data-testid^="fitting-row-"]')]
        .filter((el) => (el as HTMLElement).getAttribute('role') === 'button')
        .map((el) => {
          const r = el.getBoundingClientRect()
          return { id: el.getAttribute('data-testid') ?? '', width: r.width, height: r.height }
        }),
    )
    expect(rows.length, `rows rendered at ${width}px`).toBeGreaterThan(0)
    for (const r of rows) {
      expect(r.height, `${r.id} height at ${width}px`).toBeGreaterThanOrEqual(TOUCH_FLOOR)
      expect(r.width, `${r.id} width at ${width}px`).toBeGreaterThanOrEqual(TOUCH_FLOOR)
    }
    // The fold header is a touch target too — it is how the list is dismissed on a phone.
    const fold = await boxOf(page, 'fitting-roster-fold-toggle')
    expect(fold.height, `the fold toggle at ${width}px`).toBeGreaterThanOrEqual(TOUCH_FLOOR)
  }
})

test('NOTHING SELECTED — no empty column: the fleet panel takes the whole row', async ({ page }) => {
  await page.setViewportSize({ width: WIDE, height: 900 })
  await open(page)
  await expect(page.getByTestId('fitting-detail')).toHaveCount(0)

  const split = await boxOf(page, 'ships-split')
  const fleet = await boxOf(page, 'fitting-roster')
  // The ship rail self-collapses (`empty:hidden`), so the roster is not left as a third of the page
  // beside a hole.
  expect(fleet.width, 'the fleet panel fills the split when nothing is selected').toBeGreaterThan(
    split.width * 0.9,
  )
  // …and the moment a ship IS picked, the second column appears.
  await selectShip(page, SPARROW)
  const after = await boxOf(page, 'fitting-detail')
  expect(after.width).toBeGreaterThan(0)
})

test('THE SHIP COLUMN NAMES ITS FLEET — the link that survives the phone stack', async ({ page }) => {
  await page.setViewportSize({ width: PHONE_FLOOR, height: 720 })
  await open(page)
  await selectShip(page, SPARROW)
  await expect(page.getByTestId('ships-selected-fleet')).toHaveText('Fleet 1')
  // A ship in NO fleet says so — the 0216 berth XOR makes that a fact, not a guess.
  await selectShip(page, LONER)
  await expect(page.getByTestId('ships-selected-fleet')).toHaveText('Not in a fleet')
})

test('A WRECK IS STILL IN THE LIST — a destroyed hull is state, not a row to hide', async ({
  page,
}) => {
  await page.setViewportSize({ width: PHONE_FLOOR, height: 720 })
  await open(page)
  await expect(page.getByTestId(`fitting-row-${WRECK}`)).toBeVisible()
  // And it is reachable: selecting it opens the one surface that repairs it.
  await selectShip(page, WRECK)
  await expect(page.getByTestId('fitting-detail')).toBeVisible()
})

test('THE SMALLEST ROSTER — one fleet, one ship — renders side by side too', async ({ page }) => {
  await page.setViewportSize({ width: WIDE, height: 900 })
  await open(page, '/ships.html?s=solo')
  await expect(page.getByTestId('fitting-berthed-empty')).toBeVisible()
  await selectShip(page, SPARROW)
  const fleet = await boxOf(page, 'fitting-roster')
  const ship = await boxOf(page, 'fitting-detail')
  expect(fleet.x + fleet.width).toBeLessThanOrEqual(ship.x + 1)
  expect(await scrollsSideways(page)).toBe(false)
})

test('THE LIST FOLDS AWAY — the phone escape hatch from a long roster', async ({ page }) => {
  await page.setViewportSize({ width: PHONE_FLOOR, height: 720 })
  await open(page)
  await selectShip(page, SPARROW)
  const openTop = (await boxOf(page, 'fitting-detail')).y
  await page.getByTestId('fitting-roster-fold-toggle').click()
  await expect(page.getByTestId(`fitting-row-${SPARROW}`)).toHaveCount(0)
  // Folding the index lifts the selected ship up the page — that is the whole point of the fold.
  const foldedTop = (await boxOf(page, 'fitting-detail')).y
  expect(foldedTop).toBeLessThan(openTop)
  expect(await scrollsSideways(page)).toBe(false)
})
