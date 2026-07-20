import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V2C — STRUCTURAL GUARDS (source-text proofs of the exploration slice's hard
// exclusions), mirroring tests/miningDraftGuards.spec.ts:
//   1. PURITY — the exploration draft model + store + validator perform ZERO network/database IO
//      and can express no write.
//   2. NO GAMEPLAY-RPC PATH — no exploration draft file imports explorationApi or references the
//      exploration gameplay RPCs (command_exploration_scan / the exploration_scan writer /
//      process_exploration_securing / get_my_exploration_discoveries): the scan/secure runtime is
//      NOT a mutation path for the editor, ever.
//   3. READ-SNAPSHOT INTEGRITY — worldEditorData.ts is byte-identical on its import surface: the
//      exploration draft store is a SEPARATE structure and never enters the unified read snapshot
//      (the locations/mining-domains-unchanged shared proof, pinned here AND in
//      locationDraftGuards + miningDraftGuards).
// Run: `npx playwright test explorationDraftGuards.spec.ts`.

const WE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'features', 'worldeditor')
const read = (name: string): string => readFileSync(join(WE_DIR, name), 'utf8')

const EXPLORATION_DRAFT_FILES = [
  'explorationDraftTypes.ts',
  'explorationDraftModel.ts',
  'explorationValidation.ts',
  'useExplorationDrafts.ts',
  'ExplorationDraftPanel.tsx',
]

// ── 1. purity guard ─────────────────────────────────────────────────────────────────────────────────
test('explorationDraftModel.ts, useExplorationDrafts.ts and explorationValidation.ts contain no supabase/fetch/rpc/table access and no write call', () => {
  for (const name of ['explorationDraftModel.ts', 'useExplorationDrafts.ts', 'explorationValidation.ts']) {
    const src = read(name)
    expect(src, `${name} must not touch supabase`).not.toMatch(/supabase/i)
    expect(src, `${name} must not fetch`).not.toMatch(/\bfetch\s*\(/)
    expect(src, `${name} must not call an RPC`).not.toMatch(/\.rpc\s*\(/)
    expect(src, `${name} must not open a table query`).not.toMatch(/\.from\s*\(/)
    expect(src, `${name} must not write`).not.toMatch(/\.(insert|upsert|update|delete)\s*\(/)
  }
})

// ── 2. no gameplay-RPC / explorationApi path ────────────────────────────────────────────────────────
// The ONLY sanctioned exploration import is the read-contract TYPE module (explorationTypes — where
// ExplorationSiteLite lives) plus the shared pending-bundle shape (lib/rewardBundle). explorationApi
// (the supabase.rpc client) and the gameplay RPC names must never appear. `exploration_scan_radius`
// (the game_config tunable the overlap rule mirrors) is explicitly allowed — the negative lookahead
// excludes exactly that suffix.
test('no exploration draft file imports explorationApi or references an exploration gameplay RPC', () => {
  for (const name of EXPLORATION_DRAFT_FILES) {
    const src = read(name)
    expect(src, `${name} must not import explorationApi`).not.toContain('explorationApi')
    expect(src, `${name} must not reference command_exploration_scan`).not.toMatch(
      /command_exploration_/,
    )
    expect(src, `${name} must not reference the exploration_scan writer`).not.toMatch(
      /exploration_scan(?!_radius)/,
    )
    expect(src, `${name} must not reference process_exploration_securing`).not.toContain(
      'process_exploration_securing',
    )
    expect(src, `${name} must not reference get_my_exploration_discoveries`).not.toContain(
      'get_my_exploration_discoveries',
    )
    expect(src, `${name} must not reference getVisibleExplorationSites (read path stays in the shell)`).not.toContain(
      'getVisibleExplorationSites',
    )
  }
})

// ── 3. read-snapshot integrity (locations/mining-unchanged shared proof) ────────────────────────────
test('worldEditorData.ts imports are unchanged — no draft type/module enters the read snapshot', () => {
  const src = read('worldEditorData.ts')
  expect(src).not.toMatch(
    /explorationDraft|ExplorationDraft|useExplorationDrafts|miningDraft|MiningDraft|useMiningDrafts|locationDraft|LocationDraft/,
  )

  // Pin the EXACT import surface of the unified read snapshot (Foundation V1, PR #228).
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
  ])
})
