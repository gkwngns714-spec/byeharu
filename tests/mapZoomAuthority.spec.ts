import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// ZOOM-AT-THE-CURSOR — STRUCTURAL GUARDS (source-text proofs that there is ONE camera/projection
// authority and that BOTH SVG map surfaces actually adopt it).
//
// WHY THIS FILE EXISTS. Cursor-anchored zoom was built for the World Editor and never for the game
// map. Nothing removed it from the game map — it was simply written twice, and only one copy grew the
// feature. The unit proofs in galaxyCamera.spec.ts pin the MATH; they cannot notice a surface that
// quietly stops calling it. These guards are the half that can: if a third map surface appears, or
// either existing one re-inlines the zoom / the wheel listener / the pan scale, this suite goes red.
//
// Guarded:
//   1. ONE ZOOM AUTHORITY   — no src file re-implements the anchor formula or clamps k for a zoom;
//                             zoomCameraAbout is defined once, in galaxyCamera.
//   2. ONE WHEEL BINDING    — `addEventListener('wheel', …)` exists in exactly one file, useWheelZoom,
//                             and every SVG map surface reaches the wheel through that hook.
//   3. ONE PAN SCALE        — the `dxPx * VIEW / rect.width` shape is gone; panning goes through
//                             screenDeltaToViewBox, which is min(w,h)-correct under xMidYMid meet.
//   4. ONE STEP PAIR        — the zoom magnitudes are named constants read from galaxyCamera; no map
//                             surface carries a bare 1.07 / 1.15 / 1.25 zoom literal.
//   5. THE HOOK TAKES THE ELEMENT — not a ref, so the "effect ran once while the ref was null and
//                             never re-attached" trap is structurally unreachable.
// Run: `npx playwright test mapZoomAuthority.spec.ts`.

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = join(ROOT, 'src')
const MAP = join(SRC, 'features', 'map')
const read = (p: string): string => readFileSync(p, 'utf8')

/** Source with comments removed. The shape guards below must judge CODE: the authority modules
 *  deliberately document the formulas they retired, and a guard that reads prose would forbid
 *  explaining the very defect it exists to prevent. (`://` is spared so URLs survive.) */
const code = (p: string): string =>
  read(p)
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/(^|[^:])\/\/.*$/gm, '$1')

function sourceFiles(dir: string): string[] {
  const out: string[] = []
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) out.push(...sourceFiles(p))
    else if (/\.(ts|tsx)$/.test(e.name)) out.push(p)
  }
  return out
}
const ALL = sourceFiles(SRC)

/** Every component that renders its own pannable/zoomable `<svg viewBox="0 0 VIEW VIEW">` camera. */
const SURFACES = [
  join(MAP, 'GalaxyMap.tsx'),
  join(SRC, 'features', 'worldeditor', 'WorldEditor.tsx'),
]

// ── 0. THE SURFACE LIST IS COMPLETE ─────────────────────────────────────────────────────────────────
//      Owning a pannable camera means calling clampPan. Any file that does and is not listed above is
//      a THIRD map surface that has not been held to the guards below — which is precisely how the
//      game map came to lack a feature the editor had. Add it to SURFACES (and make it comply).
test('SURFACES lists every file that owns a pannable camera', () => {
  const cameraOwners = ALL.filter(
    (p) => p !== join(MAP, 'galaxyCamera.ts') && /\bclampPan\s*\(/.test(code(p)),
  )
  expect(cameraOwners.sort()).toEqual([...SURFACES].sort())
})

// ── 1. ONE ZOOM AUTHORITY ───────────────────────────────────────────────────────────────────────────
test('zoomCameraAbout is defined exactly once, in galaxyCamera', () => {
  const definers = ALL.filter((p) => /export function zoomCameraAbout\b/.test(read(p)))
  expect(definers).toEqual([join(MAP, 'galaxyCamera.ts')])
})

test('no src file re-implements the anchor formula or hand-rolls a zoom clamp', () => {
  for (const p of ALL) {
    if (p === join(MAP, 'galaxyCamera.ts')) continue // the authority
    const src = code(p)
    // the anchored-zoom shape: `ax - (ax - v.tx) * ratio` in any naming
    expect(src, `${p} must not re-implement the zoom anchor formula`).not.toMatch(
      /\w+\s*-\s*\(\s*\w+\s*-\s*[\w.]+\s*\)\s*\*\s*ratio/,
    )
    // the zoom's own `k = clampK(v.k * factor)` shape
    expect(src, `${p} must not hand-roll a zoom clamp — call zoomCameraAbout`).not.toMatch(
      /clampK\s*\(\s*[\w.]+\.k\s*\*/,
    )
  }
})

test('both map surfaces zoom through zoomCameraAbout and nothing else', () => {
  for (const p of SURFACES) {
    const src = read(p)
    expect(src, `${p} must import the shared zoom`).toMatch(/zoomCameraAbout/)
    expect(src, `${p} must not import clampK — the zoom authority applies it`).not.toMatch(/\bclampK\b/)
  }
})

// ── 2. ONE WHEEL BINDING ────────────────────────────────────────────────────────────────────────────
test("addEventListener('wheel') appears in exactly one file — the useWheelZoom hook", () => {
  const binders = ALL.filter((p) => /addEventListener\(\s*['"]wheel['"]/.test(read(p)))
  expect(binders).toEqual([join(MAP, 'useWheelZoom.ts')])
})

test('every SVG map surface reaches the wheel through useWheelZoom', () => {
  for (const p of SURFACES) {
    const src = read(p)
    expect(src, `${p} must bind the wheel through the shared hook`).toMatch(/useWheelZoom\(/)
    expect(src, `${p} must not register its own wheel handler`).not.toMatch(/onWheel=/)
  }
})

test('the hook preventDefaults (or the page scrolls under the pointer) and anchors on the cursor', () => {
  const src = read(join(MAP, 'useWheelZoom.ts'))
  expect(src).toMatch(/passive:\s*false/)
  expect(src).toMatch(/e\.preventDefault\(\)/)
  expect(src).toMatch(/screenToViewBoxRaw/) // the cursor→anchor projection, from the ONE authority
  expect(src).toMatch(/WHEEL_ZOOM_STEP/) // the step comes from galaxyCamera, not a local literal
})

// ── 5. THE HOOK TAKES THE ELEMENT, NOT A REF ────────────────────────────────────────────────────────
test('useWheelZoom takes the mounted ELEMENT — the null-ref-never-reattaches trap is unreachable', () => {
  const src = code(join(MAP, 'useWheelZoom.ts'))
  // the parameter is the element itself…
  expect(src).toMatch(/el:\s*SVGSVGElement\s*\|\s*null/)
  // …and the effect is keyed on it, so attachment happens exactly when the SVG appears
  expect(src).toMatch(/\}, \[el, zoom\]\)/)
  // no ref anywhere in the hook: not a RefObject parameter, not a `.current` read
  expect(src).not.toMatch(/RefObject|useRef|\.current/)
  // and each surface must pass a STATE-held element, never `svgRef.current`
  for (const p of SURFACES) expect(code(p), `${p}`).not.toMatch(/useWheelZoom\(\s*\w*[Rr]ef\.current/)
})

// ── 3. ONE PAN SCALE ────────────────────────────────────────────────────────────────────────────────
test('the width-only pan scale is gone from src, everywhere', () => {
  for (const p of ALL) {
    const src = code(p)
    expect(src, `${p} must not define a local px→viewBox pan helper`).not.toMatch(
      /(const|function)\s+toSvgUnits\b/,
    )
    // the exact retired shape: `(dxPx * VIEW) / rect.width` — only correct on a square element
    expect(src, `${p} must not scale a px delta by VIEW/width`).not.toMatch(
      /\*\s*VIEW(BOX_SIZE)?\s*\)?\s*\/\s*[\w?.]*\b(rect|r)\??\.width/,
    )
  }
})

test('both map surfaces pan through screenDeltaToViewBox', () => {
  for (const p of SURFACES) expect(read(p), `${p}`).toMatch(/screenDeltaToViewBox/)
})

test('screenDeltaToViewBox is defined once and composes viewBoxDisplayRect (no new arithmetic)', () => {
  const definers = ALL.filter((p) => /export function screenDeltaToViewBox\b/.test(read(p)))
  expect(definers).toEqual([join(MAP, 'openSpaceTransform.ts')])
  const body = read(join(MAP, 'openSpaceTransform.ts')).match(
    /export function screenDeltaToViewBox[\s\S]*?\n\}/,
  )?.[0]
  expect(body).toBeTruthy()
  expect(body!).toMatch(/viewBoxDisplayRect\(vp\)\.scale/)
})

test('screenToViewBoxRaw is defined once and screenToViewBox COMPOSES it', () => {
  const definers = ALL.filter((p) => /export function screenToViewBoxRaw\b/.test(read(p)))
  expect(definers).toEqual([join(MAP, 'openSpaceTransform.ts')])
  // `screenToViewBox(` (not `…Raw(`) — the camera-aware inverse
  const body = read(join(MAP, 'openSpaceTransform.ts')).match(
    /export function screenToViewBox\([\s\S]*?\n\}/,
  )?.[0]
  expect(body).toBeTruthy()
  // the camera-aware inverse must reuse the raw one rather than re-deriving the letterbox
  expect(body!).toMatch(/screenToViewBoxRaw\(/)
  expect(body!).not.toMatch(/offsetX|\.scale/)
})

// ── 4. ONE STEP PAIR ────────────────────────────────────────────────────────────────────────────────
test('zoom magnitudes are named constants; no map surface carries a bare zoom literal', () => {
  const cam = read(join(MAP, 'galaxyCamera.ts'))
  expect(cam).toMatch(/export const WHEEL_ZOOM_STEP = 1\.07\b/)
  expect(cam).toMatch(/export const BUTTON_ZOOM_STEP = 1\.25\b/)
  for (const p of [...SURFACES, join(MAP, 'useWheelZoom.ts')]) {
    const src = code(p)
    // a zoom call with a literal factor — `zoomByFactor(1.25)`, `zoom(1 / 1.15, …)`, etc.
    expect(src, `${p} must not pass a literal zoom factor`).not.toMatch(
      /zoom\w*\(\s*(1\s*\/\s*)?1\.(07|15|25)\b/,
    )
    expect(src, `${p} must not keep the retired 1.15 game-map step`).not.toMatch(/\b1\.15\b/)
  }
  // the surfaces read the button step from the authority rather than redeclaring it
  for (const p of SURFACES) expect(read(p), `${p}`).toMatch(/BUTTON_ZOOM_STEP/)
})
