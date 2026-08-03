import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

// ZOOM-AT-THE-CURSOR — SOURCE-SHAPE GUARDS over the ONE camera/projection authority.
//
// WHY THIS FILE EXISTS. Cursor-anchored zoom was built for the World Editor and never for the game
// map. Nothing removed it from the game map — it was simply written twice, and only one copy grew the
// feature. galaxyCamera.spec.ts / openSpaceTransform.spec.ts pin the MATH. This file pins the SHAPE of
// the source around it: that the math has exactly one definition, and that every surface which renders
// a camera reaches it rather than re-deriving it.
//
// ── WHAT THESE GUARDS CAN AND CANNOT SEE (read this before trusting one) ─────────────────────────────
// They read TEXT. They can prove a formula is written in exactly one place and that a surface names the
// shared call. They CANNOT prove the call does the right thing at runtime — an anchor computed from the
// wrong origin, a listener that is never released, a wheel that zooms the wrong way and a +/− button
// that lands off-centre are all well-formed text. Those are proved by RENDERING, in
// tests/cameraWiring.uispec.ts, which mounts the real <GalaxyMap> and the real useWheelZoom in Chromium
// and measures where a point actually ends up on screen. Neither half is sufficient; do not add a
// runtime claim here or a source-shape claim there.
//
// ── HOW A SURFACE IS FOUND (the part an earlier version got wrong) ───────────────────────────────────
// This file used to select surfaces by what they IMPORT (`clampPan(`) and check the rest against a
// hard-coded list. Both were walkable: `import { clampPan as holdPan }` escaped the filter, a `ratio`
// renamed `g` escaped the formula guard, a literal `1000` escaped the pan-scale guard, and every guard
// but one only ever looked at the two listed files — so a third surface carrying all four defects
// passed the whole suite. Detection is now STRUCTURAL (see CAMERA_SURFACES) and every surface guard
// iterates the DETECTED set, never the ledger. To be exact about the fix: it is the SELECTION of a
// surface that no longer reads an import or a variable name. The guards themselves still name the
// shared authorities (`zoomCameraAbout`, `useWheelZoom`, `screenDeltaToViewBox`, `BUTTON_ZOOM_STEP`)
// — naming the one call every surface must make is the whole point of a one-authority guard, and it
// is safe there because a surface cannot escape those by renaming its own locals.

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = join(ROOT, 'src')
const MAP = join(SRC, 'features', 'map')
/** Repo-relative, forward-slashed — failure messages must be the same string on every machine. */
const rel = (p: string): string => relative(ROOT, p).replace(/\\/g, '/')

/** THE ONLY READER IN THIS FILE. Source with comments removed: every guard below judges CODE.
 *  Reading raw text was the second defect class — the authority modules deliberately document the
 *  formulas they retired, so a guard that reads prose forbids explaining the very defect it exists to
 *  prevent AND, worse, accepts a commented-out call as a live one (`// useWheelZoom(svgEl, zoom)` used
 *  to satisfy "the surface binds the wheel"). There is no raw-text accessor here on purpose.
 *  (`://` is spared so URLs survive.) */
const code = (p: string): string =>
  readFileSync(p, 'utf8')
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

// ── THE DETECTOR ────────────────────────────────────────────────────────────────────────────────────
// A file is a camera surface if it RENDERS a pannable/zoomable camera on the shared frame. Two things
// make that true, and a working surface cannot give up either:
//   (a) an `<svg>` whose viewBox IS the shared 1000-unit square — on any other viewBox the shared
//       world→viewBox projection does not land, so markers cannot be placed by worldToViewBox; and
//   (b) a `transform` composing `translate(…)` and `scale(…)` — the camera group itself. Without it
//       nothing pans or zooms.
// A file matching EITHER is a surface. The OR is deliberate: to escape the guards a new surface must
// abandon BOTH the shared frame and the camera group, at which point it is not this thing any more.
//
// FALSE POSITIVES: any component that draws a 1000-unit SVG or a translate+scale group would be pulled
// in even if it is not interactive. Today src has exactly two (verified: the only other viewBoxes in
// src are 10/24-unit icons, and there is no other translate+scale transform). A future decorative
// 1000-unit SVG would have to be added to the ledger or given a different viewBox — that is the cost,
// and it is the safe direction to fail.
// FALSE NEGATIVES, stated honestly: the detector reads the JSX text of ONE file. A surface that builds
// its viewBox or transform string in a helper module, or via string concatenation instead of a
// template literal, is not seen. That is a real hole; it is narrower than the previous
// "whatever imports clampPan" by the amount that matters, because closing it costs the dodger the
// readable JSX every surface in this repo is written in.
/** (a) `viewBox="0 0 1000 1000"` / `viewBox={`0 0 ${VIEW} ${VIEW}`}` — the SHARED square only. */
const SHARED_VIEWBOX =
  /viewBox\s*=\s*(?:["']|\{\s*`)\s*0\s+0\s+(?:1000|\$\{[^}]*\bVIEW(?:BOX_SIZE)?\b[^}]*\})\s+(?:1000|\$\{[^}]*\bVIEW(?:BOX_SIZE)?\b[^}]*\})/
/** (b) a transform composing translate(…) and scale(…), in either order — the camera group. */
const CAMERA_TRANSFORM =
  /transform\s*=\s*[{"'`][^\n]*(?:translate\([^\n]*\bscale\(|scale\([^\n]*\btranslate\()/

/** Every file that structurally renders a camera on the shared frame. The AUTHORITY for every
 *  per-surface guard below — they all iterate THIS, so a new surface is held to all of them the day
 *  it appears, whether or not anyone remembered the ledger. */
const CAMERA_SURFACES = ALL.filter((p) => {
  const s = code(p)
  return SHARED_VIEWBOX.test(s) || CAMERA_TRANSFORM.test(s)
}).sort()

/** The LEDGER — not a source of truth, a witness. Guard 0 checks it against the detector in BOTH
 *  directions: a file the detector finds and this list does not is an unacknowledged third surface
 *  (the exact way the game map came to lack a feature the editor had); a file this list names and the
 *  detector does not find means the surface was deleted or the detector stopped working, which would
 *  otherwise make every guard below silently vacuous. */
const DECLARED_SURFACES = [
  join(MAP, 'GalaxyMap.tsx'),
  join(SRC, 'features', 'worldeditor', 'WorldEditor.tsx'),
].sort()

// ── small text tools (used by the guards that must read a call's ARGUMENTS, not just its name) ───────
/** The paren-balanced argument text of every call matching `open` (a regex ENDING in `\(`).
 *  Character-level, so a parenthesis inside a string literal would confuse it; none of the call sites
 *  it is pointed at contain one. */
function callArgs(src: string, open: RegExp): string[] {
  const re = new RegExp(open.source, 'g')
  const out: string[] = []
  while (re.exec(src) !== null) {
    let depth = 1
    let i = re.lastIndex
    for (; i < src.length && depth > 0; i++) {
      if (src[i] === '(') depth++
      else if (src[i] === ')') depth--
    }
    out.push(src.slice(re.lastIndex, i - 1))
    re.lastIndex = i
  }
  return out
}

/** Split an argument list on TOP-LEVEL commas (so an object literal or a nested call stays one arg). */
function splitArgs(argText: string): string[] {
  if (argText.trim() === '') return []
  const out: string[] = []
  let depth = 0
  let start = 0
  for (let i = 0; i < argText.length; i++) {
    const c = argText[i]
    if (c === '(' || c === '[' || c === '{') depth++
    else if (c === ')' || c === ']' || c === '}') depth--
    else if (c === ',' && depth === 0) {
      out.push(argText.slice(start, i))
      start = i + 1
    }
  }
  out.push(argText.slice(start))
  return out
}

// ── 0. THE SURFACE SET IS DERIVED, AND THE LEDGER AGREES WITH IT ────────────────────────────────────
test('the camera-surface ledger matches the surfaces the source actually renders', () => {
  expect(CAMERA_SURFACES.map(rel)).toEqual(DECLARED_SURFACES.map(rel))
})

// ── 1. ONE ZOOM AUTHORITY ───────────────────────────────────────────────────────────────────────────
test('zoomCameraAbout is defined exactly once, in galaxyCamera', () => {
  const definers = ALL.filter((p) => /export function zoomCameraAbout\b/.test(code(p)))
  expect(definers.map(rel)).toEqual([rel(join(MAP, 'galaxyCamera.ts'))])
})

test('no src file re-implements the anchor formula or hand-rolls a zoom clamp', () => {
  for (const p of ALL) {
    if (p === join(MAP, 'galaxyCamera.ts')) continue // the authority
    const src = code(p)
    // The anchored-zoom shape `A - (A - B) * C` in ANY naming. The BACKREFERENCE is what makes this
    // structural: the anchor must appear on both sides of the subtraction, which is true of the
    // formula and of nothing else — so renaming `ratio` to `g` (which used to be enough to escape)
    // changes nothing.
    expect(src, `${rel(p)} must not re-implement the zoom anchor formula`).not.toMatch(
      /([A-Za-z_$][\w$.]*)\s*-\s*\(\s*\1\s*-\s*[A-Za-z_$][\w$.]*\s*\)\s*\*/,
    )
    // the zoom's own `k = clampK(v.k * factor)` shape
    expect(src, `${rel(p)} must not hand-roll a zoom clamp — call zoomCameraAbout`).not.toMatch(
      /clampK\s*\(\s*[\w.]+\.k\s*\*/,
    )
  }
})

test('every camera surface zooms through zoomCameraAbout and nothing else', () => {
  for (const p of CAMERA_SURFACES) {
    const src = code(p)
    expect(src, `${rel(p)} must call the shared zoom`).toMatch(/zoomCameraAbout\s*\(/)
    expect(src, `${rel(p)} must not use clampK — the zoom authority applies it`).not.toMatch(/\bclampK\b/)
  }
})

// ── 2. ONE WHEEL BINDING ────────────────────────────────────────────────────────────────────────────
test("addEventListener('wheel') appears in exactly one file — the useWheelZoom hook", () => {
  const binders = ALL.filter((p) => /addEventListener\(\s*['"]wheel['"]/.test(code(p)))
  expect(binders.map(rel)).toEqual([rel(join(MAP, 'useWheelZoom.ts'))])
})

test('every camera surface reaches the wheel through useWheelZoom', () => {
  for (const p of CAMERA_SURFACES) {
    const src = code(p)
    expect(src, `${rel(p)} must bind the wheel through the shared hook`).toMatch(/useWheelZoom\s*\(/)
    expect(src, `${rel(p)} must not register its own wheel handler`).not.toMatch(/onWheel\s*=/)
  }
})

test('the hook preventDefaults (or the page scrolls under the pointer) and anchors on the cursor', () => {
  const src = code(join(MAP, 'useWheelZoom.ts'))
  expect(src).toMatch(/passive:\s*false/)
  expect(src).toMatch(/e\.preventDefault\(\)/)
  expect(src).toMatch(/screenToViewBoxRaw/) // the cursor→anchor projection, from the ONE authority
  expect(src).toMatch(/WHEEL_ZOOM_STEP/) // the step comes from galaxyCamera, not a local literal
})

// ── 3. THE HOOK TAKES THE ELEMENT, NOT A REF ────────────────────────────────────────────────────────
test('useWheelZoom takes the mounted ELEMENT — the null-ref-never-reattaches trap is unreachable', () => {
  const src = code(join(MAP, 'useWheelZoom.ts'))
  // the parameter is the element itself…
  expect(src).toMatch(/el:\s*SVGSVGElement\s*\|\s*null/)
  // …and the effect is keyed on it, so attachment happens exactly when the SVG appears
  expect(src).toMatch(/\}, \[el, zoom\]\)/)
  // no ref anywhere in the hook: not a RefObject parameter, not a `.current` read
  expect(src).not.toMatch(/RefObject|useRef|\.current/)
  // and each surface must pass a STATE-held element, never `svgRef.current`
  for (const p of CAMERA_SURFACES)
    expect(code(p), `${rel(p)} must hand useWheelZoom the mounted element, not a ref`).not.toMatch(
      /useWheelZoom\(\s*\w*[Rr]ef\.current/,
    )
})

// ── 4. ONE PAN SCALE ────────────────────────────────────────────────────────────────────────────────
test('the width-only pan scale is gone from src, everywhere', () => {
  for (const p of ALL) {
    const src = code(p)
    expect(src, `${rel(p)} must not define a local px→viewBox pan helper`).not.toMatch(
      /(const|function)\s+toSvgUnits\b/,
    )
    // The retired shape `(dxPx * VIEW) / rect.width` — only correct on a SQUARE element. Naming-free:
    // the magnitude may be the shared constant OR the bare 1000 it stands for (writing the literal
    // used to be enough to escape), and the box may be called anything at all.
    expect(src, `${rel(p)} must not scale a px delta by VIEW/width`).not.toMatch(
      /\*\s*(?:VIEW(?:BOX_SIZE)?|1000)\s*\)?\s*\/\s*[\w?.]*\.width\b/,
    )
  }
})

test('every camera surface pans through screenDeltaToViewBox', () => {
  for (const p of CAMERA_SURFACES)
    expect(code(p), `${rel(p)} must pan through the shared scale`).toMatch(/screenDeltaToViewBox\s*\(/)
})

test('screenDeltaToViewBox is defined once and composes viewBoxDisplayRect (no new arithmetic)', () => {
  const definers = ALL.filter((p) => /export function screenDeltaToViewBox\b/.test(code(p)))
  expect(definers.map(rel)).toEqual([rel(join(MAP, 'openSpaceTransform.ts'))])
  const body = code(join(MAP, 'openSpaceTransform.ts')).match(
    /export function screenDeltaToViewBox[\s\S]*?\n\}/,
  )?.[0]
  expect(body).toBeTruthy()
  expect(body!).toMatch(/viewBoxDisplayRect\(vp\)\.scale/)
})

test('screenToViewBoxRaw is defined once and screenToViewBox COMPOSES it', () => {
  const definers = ALL.filter((p) => /export function screenToViewBoxRaw\b/.test(code(p)))
  expect(definers.map(rel)).toEqual([rel(join(MAP, 'openSpaceTransform.ts'))])
  // `screenToViewBox(` (not `…Raw(`) — the camera-aware inverse
  const body = code(join(MAP, 'openSpaceTransform.ts')).match(
    /export function screenToViewBox\([\s\S]*?\n\}/,
  )?.[0]
  expect(body).toBeTruthy()
  // the camera-aware inverse must reuse the raw one rather than re-deriving the letterbox
  expect(body!).toMatch(/screenToViewBoxRaw\(/)
  expect(body!).not.toMatch(/offsetX|\.scale/)
})

// ── 5. A POINTER POINT IS MADE ELEMENT-RELATIVE BEFORE IT IS PROJECTED ──────────────────────────────
//      The highest-consequence mutant in this area is the quietest: drop `- rect.left` / `- rect.top`
//      and every conversion is off by the element's offset in the page. In the World Editor that lands
//      zone vertices at the wrong WORLD point and PUBLISHES them; on the game map it anchors the wheel
//      on the wrong point and sets fleet-go targets that are wrong by the same offset. It typechecks,
//      it renders, and every unit test of the pure math still passes, because the math is not what
//      broke. The rule: if a projection is handed a point built from clientX/clientY, that point must
//      subtract the element origin.
//      REACH: this is the only check that covers WorldEditor.pointerToWorld — the editor renders behind
//      an owner + flag gate and two fetches, so it is not mounted by cameraWiring.uispec.ts. Its
//      LIMIT: a point assembled into a variable first, then passed in, is not seen.
test('every clientX/clientY handed to a projection is made element-relative first', () => {
  const PROJECTION = /\bscreenTo(?:ViewBoxRaw|ViewBox|World)\(/
  let checked = 0
  for (const p of ALL) {
    for (const args of callArgs(code(p), PROJECTION)) {
      const point = splitArgs(args)[0] ?? ''
      if (!/\bclient[XY]\b/.test(point)) continue // not a pointer point (a Viewport, a named var, …)
      checked++
      expect(point.replace(/\s+/g, ' '), `${rel(p)}: a projected pointer point must subtract the element's left edge`).toMatch(
        /\.left\b/,
      )
      expect(point.replace(/\s+/g, ' '), `${rel(p)}: a projected pointer point must subtract the element's top edge`).toMatch(
        /\.top\b/,
      )
    }
  }
  // …and the loop above must actually have run. A guard that silently checks nothing is the failure
  // this whole file exists to end.
  expect(checked, 'no pointer→projection call site was found — the matcher has stopped matching').toBeGreaterThanOrEqual(3)
})

// ── 6. ONE STEP PAIR, AND THE BUTTONS STAY CENTRE-ANCHORED ──────────────────────────────────────────
test('zoom magnitudes are named constants; no camera surface carries a bare zoom literal', () => {
  const cam = code(join(MAP, 'galaxyCamera.ts'))
  expect(cam).toMatch(/export const WHEEL_ZOOM_STEP = 1\.07\b/)
  expect(cam).toMatch(/export const BUTTON_ZOOM_STEP = 1\.25\b/)
  for (const p of [...CAMERA_SURFACES, join(MAP, 'useWheelZoom.ts')]) {
    const src = code(p)
    // a zoom call with a literal factor — `zoomByFactor(1.25)`, `zoom(1 / 1.15, …)`, etc.
    expect(src, `${rel(p)} must not pass a literal zoom factor`).not.toMatch(
      /zoom\w*\(\s*(1\s*\/\s*)?1\.(07|15|25)\b/,
    )
    expect(src, `${rel(p)} must not keep the retired 1.15 game-map step`).not.toMatch(/\b1\.15\b/)
  }
})

test('the +/− buttons use BUTTON_ZOOM_STEP and pass NO anchor (they stay centre-anchored)', () => {
  // A zoom call naming a *_ZOOM_STEP constant IS a button click: the wheel path never names a step in
  // a surface, it receives the factor the hook chose. Forbidding a bare literal (above) never noticed
  // the WRONG named constant — `zoomByFactor(WHEEL_ZOOM_STEP)` on the `+` button passed the whole
  // suite — and nothing at all looked at the ARGUMENT COUNT, which is what makes a button centred.
  let buttons = 0
  for (const p of CAMERA_SURFACES) {
    const src = code(p)
    for (const args of callArgs(src, /\bzoom\w*\(/)) {
      if (!/\b\w*ZOOM_STEP\b/.test(args)) continue
      buttons++
      expect(args.trim(), `${rel(p)}: a +/− button must zoom by BUTTON_ZOOM_STEP`).toMatch(
        /\bBUTTON_ZOOM_STEP\b/,
      )
      expect(args.trim(), `${rel(p)}: a +/− button must not use the wheel step`).not.toMatch(
        /\bWHEEL_ZOOM_STEP\b/,
      )
      expect(
        splitArgs(args).length,
        `${rel(p)}: a +/− button is CENTRE-anchored — it must pass no anchor argument`,
      ).toBe(1)
    }
    // both directions exist on every surface
    expect(src, `${rel(p)} must zoom IN by the button step`).toMatch(/zoom\w*\(\s*BUTTON_ZOOM_STEP\s*\)/)
    expect(src, `${rel(p)} must zoom OUT by the button step`).toMatch(
      /zoom\w*\(\s*1\s*\/\s*BUTTON_ZOOM_STEP\s*\)/,
    )
  }
  expect(buttons, 'no +/− button zoom call was found — the matcher has stopped matching').toBeGreaterThanOrEqual(4)
})
