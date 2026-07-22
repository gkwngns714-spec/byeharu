import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gotoCamera } from '../src/features/worldeditor/worldEditorGoto'
import { fitCameraToWorldPoints } from '../src/features/map/galaxyCamera'
import { WORLD_MAX, WORLD_MIN } from '../src/features/map/openSpaceTransform'

// WORLD EDITOR V5 — pure proofs for COORDINATE JUMP (worldEditorGoto.gotoCamera). No browser/DB:
// gotoCamera is pure (x,y in → a typed camera / rejection out). Reuse is PROVEN structurally too — the
// module frames through the shared galaxyCamera fit and gates on the shared open-space bounds authority,
// inventing NO camera engine and NO second bounds rule.
// Run: `npx playwright test worldEditorGoto.spec.ts`.

// ── a valid in-bounds point yields EXACTLY the shared single-point camera ─────────────────────────────
test('a valid in-bounds coordinate frames through fitCameraToWorldPoints (single point)', () => {
  const r = gotoCamera(120, -90)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  // the camera is BYTE-FOR-BYTE the shared fit over the one typed point — no bespoke camera math
  expect(r.camera).toEqual(fitCameraToWorldPoints([{ x: 120, y: -90 }]))
  // and it is a valid presentation camera (finite, positive zoom)
  expect(Number.isFinite(r.camera.k) && r.camera.k > 0).toBe(true)
  expect(Number.isFinite(r.camera.tx) && Number.isFinite(r.camera.ty)).toBe(true)
})

test('the origin (0,0) is valid and frames like any single point', () => {
  const r = gotoCamera(0, 0)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.camera).toEqual(fitCameraToWorldPoints([{ x: 0, y: 0 }]))
})

// ── boundary inclusivity matches the world bounds exactly (±10000 inclusive) ──────────────────────────
test('the ±10000 bounds are INCLUSIVE on both axes; one unit past is rejected', () => {
  for (const p of [
    { x: WORLD_MIN, y: WORLD_MIN },
    { x: WORLD_MAX, y: WORLD_MAX },
    { x: WORLD_MIN, y: WORLD_MAX },
    { x: WORLD_MAX, y: WORLD_MIN },
  ]) {
    const r = gotoCamera(p.x, p.y)
    expect(r.ok, `${p.x},${p.y} on-boundary is valid`).toBe(true)
  }
  // just outside on either axis → out-of-bounds
  for (const p of [
    { x: WORLD_MIN - 1, y: 0 },
    { x: WORLD_MAX + 1, y: 0 },
    { x: 0, y: WORLD_MIN - 1 },
    { x: 0, y: WORLD_MAX + 1 },
  ]) {
    const r = gotoCamera(p.x, p.y)
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error('unreachable')
    expect(r.reason).toBe('out-of-bounds')
  }
})

// ── non-finite inputs are a DISTINCT typed rejection (drives a different hint) ────────────────────────
test('NaN / ±Infinity on either axis → not-finite rejection (never a camera)', () => {
  for (const [x, y] of [
    [Number.NaN, 0],
    [0, Number.NaN],
    [Number.POSITIVE_INFINITY, 0],
    [0, Number.NEGATIVE_INFINITY],
    [Number.NaN, Number.NaN],
  ] as const) {
    const r = gotoCamera(x, y)
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error('unreachable')
    expect(r.reason).toBe('not-finite')
    expect(r).not.toHaveProperty('camera')
  }
})

test('a far out-of-bounds finite point is out-of-bounds, not not-finite', () => {
  const r = gotoCamera(99999, -99999)
  expect(r.ok).toBe(false)
  if (r.ok) throw new Error('unreachable')
  expect(r.reason).toBe('out-of-bounds')
})

// ── STRUCTURAL: pure navigation only — reuses the shared camera fit + the shared bounds authority ─────
test('worldEditorGoto is pure navigation: no IO, no write, reuses the shared camera + bounds authorities', () => {
  const here = dirname(fileURLToPath(import.meta.url))
  const src = readFileSync(join(here, '..', 'src', 'features', 'worldeditor', 'worldEditorGoto.ts'), 'utf8')
  // reuses the ONE camera authority + the ONE bounds authority
  expect(src).toMatch(/from '\.\.\/map\/galaxyCamera'/)
  expect(src).toContain('fitCameraToWorldPoints')
  expect(src).toContain('isWithinOpenSpaceBounds')
  // no IO / no write / no second projection or bounds math
  expect(src).not.toMatch(/supabase|\.rpc\(|fetch\(|from '@?supabase/)
  expect(src).not.toMatch(/insert|update|upsert|delete/i)
  expect(src).not.toMatch(/worldToViewBox|viewBoxToWorld/) // framing goes through galaxyCamera
  expect(src).not.toMatch(/WORLD_MIN|WORLD_MAX/) // bounds gate goes through isWithinOpenSpaceBounds, not a re-derived compare
})
