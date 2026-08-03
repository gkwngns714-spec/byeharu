import { test, expect, type Page } from '@playwright/test'
import { NAV_TABS } from '../src/app/navTabs'

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// ASSETS-TAB — THE NAV FIT MEASUREMENT.
//
// navTabs.ts used to justify its five-destination ceiling with a paragraph of arithmetic that had
// never been rendered: "Six would drop cells to 53px and start clipping labels; five is the
// ceiling." The owner then asked for a sixth destination. Rather than trust or overrule that
// number, this proof MEASURES the real bar.
//
// Why a proof and not a better comment: a stale numeric justification is precisely how the
// reposition-teleport bug survived — migration 0311 justified an instant teleport with "weapon
// range 120+", migration 0316 cut every weapon range to 5-6, and the comment was never revisited.
// A number that lives only in prose cannot fail when reality moves. This one can, and it runs on
// every push.
//
// WHAT IT MEASURES, at the 320px floor, on the REAL <NavBar> with the REAL design system loaded:
//   · every cell is at least 44 × 44 CSS px (the touch floor);
//   · no label clips (scrollWidth ≤ clientWidth on the label element — which is why NavBar's label
//     span carries `whitespace-nowrap` and deliberately NOT `truncate`: truncation would hide a
//     clip instead of failing this assertion);
//   · the bar does not scroll horizontally (nothing has been pushed out of the viewport);
//   · the live-battle dot, which is the widest state the bar ever renders, changes none of it.
//
// PRECONDITIONS ARE SET HERE: the viewport, the route and the combat count are all fixtures this
// file owns. Nothing asserts an ambient default.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

/** The narrowest phone the game supports. Everything below is measured at exactly this width. */
const PHONE_FLOOR = 320
/** The touch-target floor the design system commits to. */
const TOUCH_FLOOR = 44

interface CellBox {
  label: string
  width: number
  height: number
  labelScrollWidth: number
  labelClientWidth: number
}

async function measureCells(page: Page): Promise<CellBox[]> {
  return page.evaluate(() => {
    const cells = [...document.querySelectorAll('[data-testid^="nav-"][href]')]
    return cells.map((cell) => {
      const rect = cell.getBoundingClientRect()
      const label = cell.querySelector('[data-testid^="nav-label-"]') as HTMLElement
      return {
        label: label.textContent ?? '',
        width: rect.width,
        height: rect.height,
        labelScrollWidth: label.scrollWidth,
        labelClientWidth: label.clientWidth,
      }
    })
  })
}

test.beforeEach(async ({ page }) => {
  await page.setViewportSize({ width: PHONE_FLOOR, height: 720 })
})

test('THE BAR CARRIES EVERY DESTINATION THE TABLE DECLARES — including Assets', async ({ page }) => {
  await page.goto('/nav.html')
  await expect(page.getByTestId('app-nav')).toBeVisible()
  const cells = await measureCells(page)
  expect(cells.map((c) => c.label)).toEqual(NAV_TABS.map((t) => t.label))
  // The owner asked for this one by name; it is the reason the ceiling was re-measured.
  expect(cells.map((c) => c.label)).toContain('Assets')
})

test('EVERY CELL CLEARS THE 44px TOUCH FLOOR AT 320px — measured, not estimated', async ({ page }) => {
  await page.goto('/nav.html')
  await expect(page.getByTestId('app-nav')).toBeVisible()
  const cells = await measureCells(page)
  for (const c of cells) {
    expect(c.width, `${c.label} cell width`).toBeGreaterThanOrEqual(TOUCH_FLOOR)
    expect(c.height, `${c.label} cell height`).toBeGreaterThanOrEqual(TOUCH_FLOOR)
  }
  // The readout the navTabs.ts comment quotes. Pinned so the comment cannot go stale silently:
  // if the table grows and the cells shrink, this fails and the comment must be rewritten with it.
  const widest = Math.max(...cells.map((c) => c.width))
  const narrowest = Math.min(...cells.map((c) => c.width))
  expect(narrowest).toBeGreaterThan(53)
  expect(widest).toBeLessThan(54)
})

test('NO LABEL CLIPS AT 320px — the claim that six would clip was wrong, and this is why', async ({ page }) => {
  await page.goto('/nav.html')
  await expect(page.getByTestId('app-nav')).toBeVisible()
  const cells = await measureCells(page)
  for (const c of cells) {
    // scrollWidth > clientWidth is the definition of "this text does not fit its box".
    expect(c.labelScrollWidth, `${c.label} label overflows its cell`).toBeLessThanOrEqual(
      c.labelClientWidth,
    )
  }
})

test('THE BAR DOES NOT SCROLL SIDEWAYS — nothing is pushed off the 320px viewport', async ({ page }) => {
  await page.goto('/nav.html')
  await expect(page.getByTestId('app-nav')).toBeVisible()
  const overflow = await page.evaluate(() => {
    const nav = document.querySelector('[data-testid="app-nav"]') as HTMLElement
    return {
      navScroll: nav.scrollWidth,
      navClient: nav.clientWidth,
      bodyScroll: document.body.scrollWidth,
      bodyClient: document.body.clientWidth,
    }
  })
  expect(overflow.navScroll).toBeLessThanOrEqual(overflow.navClient)
  expect(overflow.bodyScroll).toBeLessThanOrEqual(overflow.bodyClient)
})

test('THE LIVE-BATTLE DOT — the widest state the bar renders — breaks none of it', async ({ page }) => {
  await page.goto('/nav.html?combat=2')
  await expect(page.getByTestId('nav-combat-alert')).toBeVisible()
  const cells = await measureCells(page)
  for (const c of cells) {
    expect(c.width, `${c.label} cell width with the alert dot`).toBeGreaterThanOrEqual(TOUCH_FLOOR)
    expect(c.labelScrollWidth, `${c.label} label clips with the alert dot`).toBeLessThanOrEqual(
      c.labelClientWidth,
    )
  }
  const overflow = await page.evaluate(() => {
    const nav = document.querySelector('[data-testid="app-nav"]') as HTMLElement
    return nav.scrollWidth <= nav.clientWidth
  })
  expect(overflow).toBe(true)
})

test('IT STILL FITS ON A REAL PHONE (390px), with room to spare', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/nav.html')
  await expect(page.getByTestId('app-nav')).toBeVisible()
  const cells = await measureCells(page)
  for (const c of cells) {
    expect(c.width).toBeGreaterThanOrEqual(TOUCH_FLOOR)
    expect(c.labelScrollWidth).toBeLessThanOrEqual(c.labelClientWidth)
  }
})
