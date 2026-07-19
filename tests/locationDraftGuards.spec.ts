import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V1B-1 — STRUCTURAL GUARDS (source-text proofs of the slice's hard exclusions):
//   1. PURITY — the draft model + store perform ZERO network/database IO and can express no write.
//   2. ONE COMMAND PATH — the command client (commandClient.ts + its pure contract) and the
//      sanctioned publish surfaces (ExplorationDraftPanel.tsx, the 0244 exploration_site_create
//      slice; MiningDraftPanel.tsx, the 0246 mining_field_create slice) are the ONLY places a
//      world-editor command may be referenced; every other module in src/features/worldeditor
//      stays command-free (location publish remains unwired).
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

// ── 2. one-command-path guard ───────────────────────────────────────────────────────────────────────
// commandClient.ts (the transport binding) + commandContract.ts (its pure contract) are the ONE
// legitimate definition site, and ExplorationDraftPanel.tsx (0244 exploration_site_create) +
// MiningDraftPanel.tsx (0246 mining_field_create) are the sanctioned publish surfaces (owner-gated
// SERVER-side; the client grants nothing). The guard's law is that no OTHER world-editor module
// references the command client, so the location publish path stays structurally unwired until its
// own slice lands.
const COMMAND_PATH_FILES = [
  'commandClient.ts',
  'commandContract.ts',
  'ExplorationDraftPanel.tsx',
  'MiningDraftPanel.tsx',
]
test('no file in src/features/worldeditor outside the sanctioned command path references a command client', () => {
  for (const name of readdirSync(WE_DIR)) {
    if (COMMAND_PATH_FILES.includes(name)) continue
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
