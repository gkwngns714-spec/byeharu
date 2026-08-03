import { test, expect, type Page } from '@playwright/test'
import { BUTTON_ZOOM_STEP, VIEW, WHEEL_ZOOM_STEP } from '../src/features/map/galaxyCamera'

// CAMERA WIRING — the RENDERED half of the zoom proof. Mounts the REAL <GalaxyMap> and the REAL
// useWheelZoom in Chromium (tests/harness/camera.html) and measures where a point actually LANDS.
//
// WHY IT EXISTS. galaxyCamera.spec.ts pins the pure math and mapZoomAuthority.spec.ts pins the source
// shape. Between them sits everything the DOM touches — the element's box, the listener, the wheel's
// sign, the anchor's origin — and that layer had NO coverage: the anchor could drop `rect.left/top`,
// the cleanup could be deleted, the scroll direction could be flipped, a surface could stop forwarding
// its anchor, and a +/− button could zoom by the wheel constant, all with `tsc -b` clean and every one
// of the ~1600 frontend specs green. None of those are visible in the math and none are visible in the
// text; they are only visible in the pixels.
//
// EVERY MEASUREMENT HERE IS THE BROWSER'S OWN ANSWER. `getScreenCTM()` on the camera group is the
// rendered mapping from camera space to viewport pixels — it already contains the camera transform,
// the `xMidYMid meet` letterbox and the element's position — so nothing below re-derives any geometry
// the code under test also derives. The harness box is offset from the origin and non-square on
// purpose (see camera.html).
//
// Run: `npx playwright test --config playwright.osnui.config.ts cameraWiring.uispec.ts`

const MAP_SVG = '#map-host > div > svg'
const CAMERA_G = `${MAP_SVG} > g[transform]`

/** An axis-aligned 2D affine map, as the browser reports it. screen = (a·x + e, d·y + f). */
interface Mat {
  a: number
  d: number
  e: number
  f: number
}

interface RenderedCamera {
  left: number
  top: number
  width: number
  height: number
  /** CAMERA-space → screen: the camera group's own CTM, which already contains translate+scale. */
  cam: Mat
  /** OUTER-viewBox space → screen: the `<svg>`'s CTM, i.e. the letterbox alone. This is the space the
   *  camera's own `tx`/`ty` — and therefore a zoom ANCHOR — live in; the two spaces are NOT the same,
   *  and the centre-anchored button is only meaningful in this one. */
  box: Mat
  /** the raw transform attribute — a cheap "has the camera moved yet?" token */
  transform: string
}

async function rendered(page: Page): Promise<RenderedCamera> {
  return page.evaluate((sel) => {
    const svg = document.querySelector(sel) as SVGSVGElement | null
    if (!svg) throw new Error(`no map svg at ${sel}`)
    const g = svg.querySelector(':scope > g[transform]') as SVGGElement | null
    if (!g) throw new Error('no camera group under the map svg')
    const gm = g.getScreenCTM()
    const sm = svg.getScreenCTM()
    if (!gm || !sm) throw new Error('the map has no screen CTM')
    const r = svg.getBoundingClientRect()
    return {
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      cam: { a: gm.a, d: gm.d, e: gm.e, f: gm.f },
      box: { a: sm.a, d: sm.d, e: sm.e, f: sm.f },
      transform: g.getAttribute('transform') ?? '',
    }
  }, MAP_SVG)
}

/** Where point `v` lands on screen under `m`, per the browser. */
const at = (m: Mat, v: { x: number; y: number }) => ({ x: m.a * v.x + m.e, y: m.d * v.y + m.f })
/** Which point is under screen point `s` under `m`, per the browser. */
const under = (m: Mat, s: { x: number; y: number }) => ({ x: (s.x - m.e) / m.a, y: (s.y - m.f) / m.d })
const apart = (p: { x: number; y: number }, q: { x: number; y: number }) => Math.hypot(p.x - q.x, p.y - q.y)
const CENTRE = { x: VIEW / 2, y: VIEW / 2 }
/** Sub-pixel. Any real anchoring defect — a dropped `rect.left`, a centre anchor where the cursor
 *  belongs, the wrong step — moves the held point by whole pixels at these scales, so this budget is
 *  orders of magnitude tighter than what it has to separate. */
const DRIFT_PX = 0.1

async function afterCameraMoves(page: Page, before: RenderedCamera): Promise<RenderedCamera> {
  await expect.poll(async () => (await rendered(page)).transform).not.toBe(before.transform)
  return rendered(page)
}

/** A pointer position on WHOLE pixels. Chromium delivers a synthesized wheel event's clientX/clientY
 *  rounded to integers, so a fractional target would put the real anchor up to half a pixel away from
 *  the point this file measured — which then amplifies with the zoom and looks like anchor drift. It
 *  is not: it is the harness lying about where the cursor was. Round once, here. */
const px = (left: number, size: number, fraction: number) => Math.round(left + size * fraction)

async function wheelAt(page: Page, x: number, y: number, deltaY: number): Promise<void> {
  await page.mouse.move(x, y)
  await page.mouse.wheel(0, deltaY)
}

test.beforeEach(async ({ page }) => {
  await page.goto('/camera.html')
  await page.waitForSelector(CAMERA_G)
})

// ── the anchor: is the point under the pointer really the fixed point? ──────────────────────────────
test('one wheel notch keeps the point under the cursor exactly where it was', async ({ page }) => {
  const before = await rendered(page)
  // OFF-CENTRE on both axes on purpose: a centre-anchored zoom (a surface that forgets to forward its
  // anchor) and a wrong-origin anchor (one that forgets rect.left/top) are both invisible at the centre.
  const cursor = { x: px(before.left, before.width, 0.72), y: px(before.top, before.height, 0.28) }
  const anchored = under(before.cam, cursor)

  await wheelAt(page, cursor.x, cursor.y, -100)
  const after = await afterCameraMoves(page, before)

  // it zoomed IN by exactly one notch — a flipped `deltaY < 0` yields 1/step and fails right here
  expect(after.cam.a / before.cam.a).toBeCloseTo(WHEEL_ZOOM_STEP, 6)
  // …and the anchored point has not moved on screen
  expect(apart(at(after.cam, anchored), cursor)).toBeLessThan(DRIFT_PX)
})

test('the anchored point survives a whole 13-notch scroll gesture', async ({ page }) => {
  const start = await rendered(page)
  const cursor = { x: px(start.left, start.width, 0.34), y: px(start.top, start.height, 0.77) }
  const anchored = under(start.cam, cursor)

  let prev = start
  for (let i = 0; i < 13; i++) {
    await wheelAt(page, cursor.x, cursor.y, -100)
    prev = await afterCameraMoves(page, prev)
  }

  expect(prev.cam.a / start.cam.a).toBeCloseTo(WHEEL_ZOOM_STEP ** 13, 4)
  expect(apart(at(prev.cam, anchored), cursor)).toBeLessThan(DRIFT_PX)
})

test('scrolling the other way zooms OUT, still anchored on the cursor', async ({ page }) => {
  const before = await rendered(page)
  const cursor = { x: px(before.left, before.width, 0.61), y: px(before.top, before.height, 0.43) }
  const anchored = under(before.cam, cursor)

  await wheelAt(page, cursor.x, cursor.y, 100)
  const after = await afterCameraMoves(page, before)

  expect(after.cam.a / before.cam.a).toBeCloseTo(1 / WHEEL_ZOOM_STEP, 6)
  expect(apart(at(after.cam, anchored), cursor)).toBeLessThan(DRIFT_PX)
})

// ── the drag: the pan scale is the letterbox scale, not the width ──────────────────────────────────
test('dragging the map carries the grabbed point 1:1 with the pointer', async ({ page }) => {
  const before = await rendered(page)
  const from = { x: px(before.left, before.width, 0.4), y: px(before.top, before.height, 0.5) }
  const to = { x: from.x + 120, y: from.y - 70 }
  const grabbed = under(before.cam, from)

  await page.mouse.move(from.x, from.y)
  await page.mouse.down()
  await page.mouse.move(to.x, to.y)
  await page.mouse.up()
  const after = await afterCameraMoves(page, before)

  expect(after.cam.a).toBeCloseTo(before.cam.a, 6) // a drag pans; it must not zoom
  // The harness box is 760×430. The retired `dxPx * VIEW / rect.width` scale is 1000/760 where the
  // truth under `xMidYMid meet` is 1000/430 — so a re-inlined width-only pan drags this point only
  // ~57% of the way and it slides out from under the pointer by tens of pixels.
  expect(apart(at(after.cam, grabbed), to)).toBeLessThan(DRIFT_PX)
})

// ── the +/− buttons: the OTHER zoom entry point, with the OTHER constant and the CENTRE anchor ──────
// A button has no cursor to anchor on, so `zoomCameraAbout` falls back to the OUTER-viewBox centre
// (VIEW/2, VIEW/2) — the middle of the letterboxed square on screen. The fixed point is therefore
// whatever the camera currently puts there; an anchor of any other kind moves it.
async function buttonZoom(page: Page, label: string, expectedRatio: number): Promise<void> {
  const before = await rendered(page)
  const held = at(before.box, CENTRE) // where the viewBox centre is on screen — this must not move
  const content = under(before.cam, held) // the camera-space point sitting there right now

  await page.getByRole('button', { name: label }).click()
  const after = await afterCameraMoves(page, before)

  // the wrong named constant reads identically in source; here it is a 1.07 that should be 1.25
  expect(after.cam.a / before.cam.a).toBeCloseTo(expectedRatio, 6)
  expect(apart(at(after.cam, content), held)).toBeLessThan(DRIFT_PX)
}

test('the + button zooms IN by BUTTON_ZOOM_STEP about the viewBox centre', async ({ page }) => {
  await buttonZoom(page, 'Zoom in', BUTTON_ZOOM_STEP)
})

test('the − button zooms OUT by BUTTON_ZOOM_STEP about the viewBox centre', async ({ page }) => {
  await buttonZoom(page, 'Zoom out', 1 / BUTTON_ZOOM_STEP)
})

// ── the listener: bound once, released once ────────────────────────────────────────────────────────
test('one notch is applied ONCE however many times the hook re-bound on the same element', async ({ page }) => {
  const notches = page.getByTestId('probe-notches')
  await expect(notches).toHaveText('0')
  // five extra renders → five re-binds on the SAME element. Without the removeEventListener cleanup
  // there are now six listeners, and the single notch below arrives six times.
  for (let i = 0; i < 5; i++) await page.getByTestId('probe-rerender').click()

  const box = await page.locator('#probe-svg').boundingBox()
  expect(box).toBeTruthy()
  await wheelAt(page, box!.x + box!.width / 2, box!.y + box!.height / 2, -100)

  await expect.poll(async () => await notches.textContent()).not.toBe('0')
  await expect(notches).toHaveText('1')
})

test('unmounting and remounting the map leaves exactly one wheel binding', async ({ page }) => {
  const toggle = page.getByTestId('toggle-map')
  for (let i = 0; i < 3; i++) {
    await toggle.click()
    await expect(page.locator(MAP_SVG)).toHaveCount(0)
    await toggle.click()
    await expect(page.locator(MAP_SVG)).toHaveCount(1)
  }
  await page.waitForSelector(CAMERA_G)

  const before = await rendered(page)
  await wheelAt(page, px(before.left, before.width, 0.5), px(before.top, before.height, 0.5), -100)
  const after = await afterCameraMoves(page, before)

  // exactly ONE notch, not one per mount
  expect(after.cam.a / before.cam.a).toBeCloseTo(WHEEL_ZOOM_STEP, 6)
})

// ── the listener is NON-PASSIVE: the page must not scroll out from under the map ────────────────────
// This is a "must NOT happen" proof, which needs two things a naive version does not have. First a
// POSITIVE CONTROL: on a page that cannot scroll, "it did not scroll" is vacuous. Second a wait long
// enough to be meaningful — Chromium commits a wheel scroll ASYNCHRONOUSLY (measured here: `scrollY`
// still reads 0 immediately after the gesture and 400 a few hundred ms later), so reading it straight
// away reports "no scroll" for a page that is about to scroll. The control measures that latency on
// this machine instead of guessing it.
const SCROLL_PAGE_BACKGROUND = { x: 1220, y: 640 } // empty body: not the map, not the controls

test('a wheel over the map zooms it and never scrolls the page', async ({ page }) => {
  const scrollY = () => page.evaluate(() => window.scrollY)
  expect(await scrollY()).toBe(0)

  // CONTROL — the identical gesture on the page background DOES scroll, and this is how long it takes.
  const t0 = Date.now()
  await wheelAt(page, SCROLL_PAGE_BACKGROUND.x, SCROLL_PAGE_BACKGROUND.y, 400)
  await expect.poll(scrollY).toBeGreaterThan(0)
  const settleMs = Math.max(600, (Date.now() - t0) * 4)
  await page.evaluate(() => window.scrollTo(0, 0))
  expect(await scrollY()).toBe(0)

  // THE CLAIM — the same gesture over the map zooms it and the page stays exactly where it was.
  const before = await rendered(page)
  await wheelAt(page, px(before.left, before.width, 0.5), px(before.top, before.height, 0.5), 400)
  await afterCameraMoves(page, before)
  await page.waitForTimeout(settleMs)
  expect(await scrollY()).toBe(0)
})
