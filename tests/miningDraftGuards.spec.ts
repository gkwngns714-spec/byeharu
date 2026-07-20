import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V2A PR-2 — STRUCTURAL GUARDS (source-text proofs of the mining slice's hard
// exclusions), mirroring tests/locationDraftGuards.spec.ts:
//   1. PURITY — the mining draft model + store + validator perform ZERO network/database IO and can
//      express no write.
//   2. NO GAMEPLAY-RPC PATH — no mining draft file imports miningApi or references the mining
//      gameplay RPCs (command_mining_extract / process_mining_securing / the mining_extract RPC
//      family): the extract/secure runtime is NOT a mutation path for the editor, ever.
//   3. READ-SNAPSHOT INTEGRITY — worldEditorData.ts is byte-identical on its import surface: the
//      mining draft store is a SEPARATE structure and never enters the unified read snapshot
//      (the locations-domain-unchanged shared proof, pinned here AND in locationDraftGuards).
// Run: `npx playwright test miningDraftGuards.spec.ts`.

const WE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'features', 'worldeditor')
const read = (name: string): string => readFileSync(join(WE_DIR, name), 'utf8')

const MINING_DRAFT_FILES = [
  'miningDraftTypes.ts',
  'miningDraftModel.ts',
  'miningValidation.ts',
  'useMiningDrafts.ts',
  'MiningDraftPanel.tsx',
]

// ── 1. purity guard ─────────────────────────────────────────────────────────────────────────────────
test('miningDraftModel.ts, useMiningDrafts.ts and miningValidation.ts contain no supabase/fetch/rpc/table access and no write call', () => {
  for (const name of ['miningDraftModel.ts', 'useMiningDrafts.ts', 'miningValidation.ts']) {
    const src = read(name)
    expect(src, `${name} must not touch supabase`).not.toMatch(/supabase/i)
    expect(src, `${name} must not fetch`).not.toMatch(/\bfetch\s*\(/)
    expect(src, `${name} must not call an RPC`).not.toMatch(/\.rpc\s*\(/)
    expect(src, `${name} must not open a table query`).not.toMatch(/\.from\s*\(/)
    expect(src, `${name} must not write`).not.toMatch(/\.(insert|upsert|update|delete)\s*\(/)
  }
})

// ── 2. no gameplay-RPC / miningApi path ─────────────────────────────────────────────────────────────
// The ONLY sanctioned mining imports are the read-contract TYPES (miningTypes) and the shared
// pending-bundle shape (lib/rewardBundle). miningApi (the supabase.rpc client) and the gameplay RPC
// names must never appear. `mining_extract_radius` (the game_config tunable the overlap rule
// mirrors) is explicitly allowed — the negative lookahead excludes exactly that suffix.
test('no mining draft file imports miningApi or references a mining gameplay RPC', () => {
  for (const name of MINING_DRAFT_FILES) {
    const src = read(name)
    expect(src, `${name} must not import miningApi`).not.toContain('miningApi')
    expect(src, `${name} must not reference command_mining_extract`).not.toMatch(/command_mining_/)
    expect(src, `${name} must not reference process_mining_securing`).not.toContain(
      'process_mining_securing',
    )
    expect(src, `${name} must not reference the mining_extract RPC family`).not.toMatch(
      /mining_extract(?!_radius)/,
    )
    expect(src, `${name} must not reference get_my_mining_extractions`).not.toContain(
      'get_my_mining_extractions',
    )
  }
})

// ── 3. read-snapshot integrity (locations-unchanged shared proof) ───────────────────────────────────
test('worldEditorData.ts imports are unchanged — no draft type/module enters the read snapshot', () => {
  const src = read('worldEditorData.ts')
  expect(src).not.toMatch(/miningDraft|MiningDraft|useMiningDrafts|locationDraft|LocationDraft/)

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
