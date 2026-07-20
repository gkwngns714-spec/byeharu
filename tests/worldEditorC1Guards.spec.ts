import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR C1 — STRUCTURAL GUARDS (source-text proofs of the coordinate contract's hard rules):
//   1. ZONEEDITOR RETIRED — src/features/dev/ZoneEditor.tsx is gone; NO file under src/ imports it,
//      no file references its bespoke `makeFit` transform, and App.tsx carries no /dev/zones route.
//   2. ONE TRANSFORM AUTHORITY — the C1 modules (worldEditorCoordinates / worldEditorFocus) never
//      reimplement world↔viewBox: the contract RE-EXPORTS openSpaceTransform; the focus framer
//      reuses galaxyCamera's fit; neither contains projection math.
//   3. STORED COORDINATES UNCHANGED — the C1 modules can express no write: no supabase, no rpc, no
//      table access, no insert/update, no assignment to any coordinate field.
//   4. RADIUS FROM CONTEXT — the pure validators take the overlap radius from the validation
//      context (server-authoritative, threaded by the snapshot) and stay network-free; the 750
//      constants are demoted to clearly-labeled NON-AUTHORITATIVE fallbacks.
// Run: `npx playwright test worldEditorC1Guards.spec.ts`.

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = join(ROOT, 'src')
const WE = join(SRC, 'features', 'worldeditor')
const read = (p: string): string => readFileSync(p, 'utf8')

/** Every .ts/.tsx source file under src/, recursively. */
function sourceFiles(dir: string): string[] {
  const out: string[] = []
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) out.push(...sourceFiles(p))
    else if (/\.(ts|tsx)$/.test(e.name)) out.push(p)
  }
  return out
}

// ── 1. the legacy ZoneEditor is RETIRED ─────────────────────────────────────────────────────────────
test('ZoneEditor.tsx is deleted; no src file imports dev/ZoneEditor or references makeFit', () => {
  expect(existsSync(join(SRC, 'features', 'dev', 'ZoneEditor.tsx'))).toBe(false)
  for (const p of sourceFiles(SRC)) {
    const src = read(p)
    expect(src, `${p} must not import the retired dev/ZoneEditor`).not.toMatch(/dev\/ZoneEditor/)
    expect(src, `${p} must not reference the retired makeFit transform`).not.toMatch(/\bmakeFit\b/)
  }
})

test('App.tsx has no /dev/zones route — /dev/world (WorldEditor) is the one authoring surface', () => {
  const app = read(join(SRC, 'app', 'App.tsx'))
  expect(app).not.toContain('/dev/zones')
  expect(app).not.toMatch(/<ZoneEditor/)
  expect(app).toContain('/dev/world')
  expect(app).toContain('<WorldEditor')
})

// ── 2. no second world↔viewBox authority ────────────────────────────────────────────────────────────
test('worldEditorCoordinates re-exports the ONE projection (openSpaceTransform) and defines no transform math', () => {
  const src = read(join(WE, 'worldEditorCoordinates.ts'))
  // the projection is a RE-EXPORTED REFERENCE to the single authority…
  expect(src).toMatch(/export \{[^}]*worldToViewBox[\s\S]*?\} from '\.\.\/map\/openSpaceTransform'/)
  // …never a local reimplementation (no function/const definition, no projection arithmetic)
  expect(src).not.toMatch(/function worldToViewBox|const worldToViewBox\s*=/)
  expect(src).not.toMatch(/function viewBoxToWorld|const viewBoxToWorld\s*=/)
  expect(src).not.toMatch(/WORLD_MIN|WORLD_MAX|WORLD_SPAN|VIEWBOX_SIZE/)
})

test('worldEditorFocus reuses galaxyCamera fit + representationWorldPoints — zero projection math of its own', () => {
  const src = read(join(WE, 'worldEditorFocus.ts'))
  expect(src).toMatch(/import \{[^}]*fitCameraToWorldPoints[^}]*\} from '\.\.\/map\/galaxyCamera'/)
  expect(src).toMatch(/representationWorldPoints/)
  // no direct projection call and no projection-math ingredients — the fit owns the conversion
  expect(src).not.toMatch(/worldToViewBox|viewBoxToWorld|screenToWorld/)
  expect(src).not.toMatch(/WORLD_MIN|WORLD_MAX|WORLD_SPAN|VIEWBOX_SIZE|WORLD_TO_VIEWBOX_SCALE/)
})

// ── 3. stored coordinates unchanged: the C1 modules can express NO write ────────────────────────────
test('worldEditorCoordinates + worldEditorFocus contain no IO and no coordinate assignment', () => {
  for (const name of ['worldEditorCoordinates.ts', 'worldEditorFocus.ts']) {
    const src = read(join(WE, name))
    expect(src, `${name} must not touch supabase`).not.toMatch(/supabase/i)
    expect(src, `${name} must not fetch`).not.toMatch(/\bfetch\s*\(/)
    expect(src, `${name} must not call an RPC`).not.toMatch(/\.rpc\s*\(/)
    expect(src, `${name} must not open a table query`).not.toMatch(/\.from\s*\(/)
    expect(src, `${name} must not write`).not.toMatch(/\.(insert|upsert|update|delete)\s*\(/)
    // no assignment to any coordinate field — display/camera code READS coordinates only
    expect(src, `${name} must not assign a coordinate`).not.toMatch(
      /\.(x|y|space_x|space_y)\s*=[^=]/,
    )
  }
})

// ── 4. the overlap radius arrives FROM CONTEXT; validators stay pure; 750 is a labeled fallback ─────
test('mining/exploration validators read ctx.overlapRadius, never the network; 750 demoted to a labeled fallback', () => {
  for (const name of ['miningValidation.ts', 'explorationValidation.ts']) {
    const src = read(join(WE, name))
    expect(src, `${name} must take the radius from the validation context`).toMatch(
      /ctx\.overlapRadius/,
    )
    expect(src, `${name} must label 750 as a non-authoritative fallback`).toMatch(
      /OVERLAP_RADIUS_FALLBACK = 750/,
    )
    // purity unchanged — no live network in the pure validators
    expect(src, `${name} must not touch supabase`).not.toMatch(/supabase/i)
    expect(src, `${name} must not fetch`).not.toMatch(/\bfetch\s*\(/)
    expect(src, `${name} must not call an RPC`).not.toMatch(/\.rpc\s*\(/)
    expect(src, `${name} must not open a table query`).not.toMatch(/\.from\s*\(/)
  }
  // the generic env carries the radius as DATA (context), assembled by the store from the snapshot
  expect(read(join(WE, 'draftTypes.ts'))).toMatch(/overlapRadius\?:\s*number \| null/)
})

// ── the shell consumes the contract: focus is camera-only ───────────────────────────────────────────
test('WorldEditor uses cameraForDomain for the Focus control (camera-only framing, shared fit)', () => {
  const src = read(join(WE, 'WorldEditor.tsx'))
  expect(src).toMatch(/cameraForDomain/)
  expect(src).toMatch(/focusPointsForDomain/)
})
