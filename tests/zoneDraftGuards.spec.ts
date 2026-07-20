import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V3A PR-2/PR-3 — STRUCTURAL GUARDS (source-text proofs of the zone slice's hard
// exclusions), mirroring tests/miningDraftGuards.spec.ts:
//   1. PURITY — the zone draft model + store + validator (and the gesture/panel components) perform
//      ZERO direct network/database IO and can express no direct write. Geometry gestures write
//      ONLY through the local draft store (patchDraft).
//   2. NO LEGACY LIVE-WRITE PATH — no zone draft file imports pirateApi or references the LOCKED
//      pirate_zone_create/delete RPCs (0239: service_role only) — publishing (PR-3, migration 0254
//      zone_create) goes EXCLUSIVELY through the 0243-spine command client, and ONLY from the ONE
//      sanctioned publish surface, ZoneDraftPanel.tsx (registered in
//      tests/locationDraftGuards.spec.ts COMMAND_PATH_FILES — the same narrowing every prior
//      publish panel made). Every other zone file stays command-free.
//   3. READ-SNAPSHOT INTEGRITY — worldEditorData.ts is byte-identical on its import surface: the
//      zone draft store is a SEPARATE structure and never enters the unified read snapshot.
// Run: `npx playwright test zoneDraftGuards.spec.ts`.

const WE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'features', 'worldeditor')
const read = (name: string): string => readFileSync(join(WE_DIR, name), 'utf8')

const ZONE_DRAFT_FILES = [
  'zoneDraftTypes.ts',
  'zoneDraftModel.ts',
  'zoneValidation.ts',
  'useZoneDrafts.ts',
  'ZoneDraftPanel.tsx',
  'ZoneGeometryHandles.tsx',
]

// The ONE sanctioned zone publish surface (PR-3): it may import the command client; nothing else may.
const SANCTIONED_PUBLISH_SURFACE = 'ZoneDraftPanel.tsx'

// ── 1. purity guard (every zone file — the components included: gestures patch a LOCAL draft only) ──
test('no zone draft file contains supabase/fetch/rpc/table access or a write call', () => {
  for (const name of ZONE_DRAFT_FILES) {
    const src = read(name)
    expect(src, `${name} must not touch supabase`).not.toMatch(/supabase/i)
    expect(src, `${name} must not fetch`).not.toMatch(/\bfetch\s*\(/)
    expect(src, `${name} must not call an RPC`).not.toMatch(/\.rpc\s*\(/)
    expect(src, `${name} must not open a table query`).not.toMatch(/\.from\s*\(/)
    expect(src, `${name} must not write`).not.toMatch(/\.(insert|upsert|update|delete)\s*\(/)
  }
})

// ── 2. no legacy live-write path; publish wiring ONLY on the sanctioned surface ─────────────────────
// The locked zone RPCs (pirate_zone_create / pirate_zone_delete, 0239: service_role only) and their
// client (pirateApi) must never appear in ANY zone file — publishing does not resurrect them: the
// 0254 zone_create command is a NEW owner-gated surface through the 0243 spine. The publish
// transport (commandClient: invokeWorldEditorCommand / newRequestId / commandType) may appear ONLY
// in the sanctioned publish surface (ZoneDraftPanel.tsx — the panel locationDraftGuards'
// COMMAND_PATH_FILES also registers); every other zone file stays command-free.
test('no zone draft file references pirateApi or the locked zone RPCs; publish wiring only in the sanctioned panel', () => {
  for (const name of ZONE_DRAFT_FILES) {
    const src = read(name)
    expect(src, `${name} must not import pirateApi`).not.toContain('pirateApi')
    expect(src, `${name} must not reference the locked zone RPCs`).not.toMatch(/pirate_zone_/)
    expect(src, `${name} must not reference DangerZoneLite via pirateApi`).not.toMatch(
      /from\s+'\.\.\/map\/pirateApi'/,
    )
    if (name === SANCTIONED_PUBLISH_SURFACE) continue
    expect(src, `${name} must not import commandClient`).not.toContain("from './commandClient'")
    expect(src, `${name} must not carry publish wiring`).not.toContain('invokeWorldEditorCommand')
    expect(src, `${name} must not carry publish wiring`).not.toContain('newRequestId')
    expect(src, `${name} must not carry publish wiring`).not.toContain('commandType')
  }
})

// The sanctioned surface publishes through the ONE command path with the ONE command kind — never a
// raw RPC name string of its own, never the locked legacy RPCs (asserted above for all files).
test('ZoneDraftPanel publishes exclusively via the 0254 zone_create command through commandClient', () => {
  const src = read(SANCTIONED_PUBLISH_SURFACE)
  expect(src).toContain("from './commandClient'")
  expect(src).toContain('invokeWorldEditorCommand')
  expect(src).toContain("commandType: 'zone_create'")
  // the transport is the command client alone — no direct supabase/rpc escape hatch
  expect(src).not.toMatch(/supabase/i)
  expect(src).not.toMatch(/\.rpc\s*\(/)
})

// The gesture layer's ONLY write is the local draft patch: it receives patchGeometry (shell-bound
// store.patchDraft) and never touches any other mutation surface.
test('ZoneGeometryHandles writes exclusively through the patchGeometry prop (store.patchDraft)', () => {
  const src = read('ZoneGeometryHandles.tsx')
  expect(src).toContain('patchGeometry')
  // no store import at all — the component is handed the ONE write callback by the shell
  expect(src).not.toContain('useZoneDrafts')
  expect(src).not.toContain('localStorage')
})

// ── 3. read-snapshot integrity (draft structures never enter the unified read snapshot) ─────────────
test('worldEditorData.ts imports are unchanged — no zone draft type/module enters the read snapshot', () => {
  const src = read('worldEditorData.ts')
  expect(src).not.toMatch(/zoneDraft|ZoneDraft|useZoneDrafts|zoneValidation|ZoneGeometry/)

  // Pin the EXACT import surface of the unified read snapshot (Foundation V1 PR #228, zoneRefs
  // extension PR #246 — the create-location zone picker's slice, from the SAME get_world_map read).
  const importLines = src
    .split('\n')
    .filter((l) => l.startsWith('import '))
    .map((l) => l.trim())
  expect(importLines).toEqual([
    "import { fetchWorldMap } from '../map/mapApi'",
    "import { flattenWorldMapLocations, flattenWorldMapZones, type MapLocation, type WorldMapZoneRef } from '../map/mapTypes'",
    "import { getActiveMiningFields } from '../mining/miningApi'",
    "import type { MiningField } from '../mining/miningTypes'",
    "import { getVisibleExplorationSites, type ExplorationSiteLite } from '../exploration/explorationApi'",
    "import { fetchDangerZones, type DangerZoneLite } from '../map/pirateApi'",
    // C1: the server-authoritative overlap radii ride the snapshot — a READ of the existing
    // public game_config tunables (lib/catalog.fetchGameConfig), never a write, never a draft type.
    "import { fetchGameConfig } from '../../lib/catalog'",
  ])
})
