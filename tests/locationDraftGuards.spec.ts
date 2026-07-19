import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V1B-1 — STRUCTURAL GUARDS (source-text proofs of the slice's hard exclusions):
//   1. PURITY — the draft model + store perform ZERO network/database IO and can express no write.
//   2. NO COMMAND PATH — nothing in src/features/worldeditor imports a command client (publish is
//      unwired; that module lives in an UNMERGED slice and does not exist on main).
//   3. READ-SNAPSHOT INTEGRITY — worldEditorData.ts is byte-identical on its import surface: the
//      draft store is a SEPARATE structure and never enters the unified read snapshot.
// Run: `npx playwright test locationDraftGuards.spec.ts`.

const WE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'features', 'worldeditor')
const read = (name: string): string => readFileSync(join(WE_DIR, name), 'utf8')

// ── 1. purity guard ─────────────────────────────────────────────────────────────────────────────────
test('locationDraftModel.ts and useLocationDrafts.ts contain no supabase/fetch/rpc/table access and no write call', () => {
  for (const name of ['locationDraftModel.ts', 'useLocationDrafts.ts']) {
    const src = read(name)
    expect(src, `${name} must not touch supabase`).not.toMatch(/supabase/i)
    expect(src, `${name} must not fetch`).not.toMatch(/\bfetch\s*\(/)
    expect(src, `${name} must not call an RPC`).not.toMatch(/\.rpc\s*\(/)
    expect(src, `${name} must not open a table query`).not.toMatch(/\.from\s*\(/)
    expect(src, `${name} must not write`).not.toMatch(/\.(insert|upsert|update|delete)\s*\(/)
  }
})

// ── 2. no-command guard ─────────────────────────────────────────────────────────────────────────────
test('no file in src/features/worldeditor references a command client (publish stays unwired)', () => {
  for (const name of readdirSync(WE_DIR)) {
    const src = read(name)
    expect(src, `${name} must not import commandClient`).not.toContain('commandClient')
    expect(src, `${name} must not invoke a world-editor command`).not.toContain('invokeWorldEditorCommand')
  }
})

// ── 3. read-snapshot integrity ──────────────────────────────────────────────────────────────────────
test('worldEditorData.ts imports are unchanged — no draft type/module enters the read snapshot', () => {
  const src = read('worldEditorData.ts')
  expect(src).not.toMatch(/locationDraft|LocationDraft|useLocationDrafts/)

  // Pin the EXACT import surface of the unified read snapshot (Foundation V1, PR #228).
  const importLines = src
    .split('\n')
    .filter((l) => l.startsWith('import '))
    .map((l) => l.trim())
  expect(importLines).toEqual([
    "import { fetchWorldMap } from '../map/mapApi'",
    "import { flattenWorldMapLocations, type MapLocation } from '../map/mapTypes'",
    "import { getActiveMiningFields } from '../mining/miningApi'",
    "import type { MiningField } from '../mining/miningTypes'",
    "import { getVisibleExplorationSites, type ExplorationSiteLite } from '../exploration/explorationApi'",
    "import { fetchDangerZones, type DangerZoneLite } from '../map/pirateApi'",
  ])
})
