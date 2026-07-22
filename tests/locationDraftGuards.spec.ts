import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V1B-1 — STRUCTURAL GUARDS (source-text proofs of the slice's hard exclusions):
//   1. PURITY — the draft model + store perform ZERO network/database IO and can express no write.
//   2. ONE COMMAND PATH — the command client (commandClient.ts + its pure contract) and the
//      sanctioned publish surfaces (ExplorationDraftPanel.tsx, the 0244/0247 exploration slices;
//      MiningDraftPanel.tsx, the 0246/0248 mining slices; LocationDraftPanel.tsx, the 0249
//      location_update slice) are the ONLY places a world-editor command may be referenced; every
//      other module in src/features/worldeditor stays command-free.
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
// legitimate definition site, and ExplorationDraftPanel.tsx (0244/0247) + MiningDraftPanel.tsx
// (0246/0248) + LocationDraftPanel.tsx (0249/0252) + ZoneDraftPanel.tsx (0254 zone_create — the
// 4th/final publish domain, the same narrowing every prior panel made when its publish slice
// landed) are the sanctioned publish surfaces, and ZoneInspectorActions.tsx (0255 zone_unpublish —
// the LIVE-zone unpublish action, the first command that acts on a selected live row rather than a
// draft panel) is the sanctioned unpublish surface (all owner-gated SERVER-side; the client grants
// nothing). The guard's law is that no OTHER world-editor module references the command client.
const COMMAND_PATH_FILES = [
  'commandClient.ts',
  'commandContract.ts',
  'ExplorationDraftPanel.tsx',
  'MiningDraftPanel.tsx',
  'LocationDraftPanel.tsx',
  'ZoneDraftPanel.tsx',
  'ZoneInspectorActions.tsx',
  // E4 combat-authoring: useCombatAuthoring.ts is the SOLE new module that talks to the command client;
  // every other E4 file (combatPayloads/combatErrorMap/combatMemberValidation/combatContentData + the
  // *Authoring.tsx sub-panels + MemberSetEditor + CombatContentPanel) stays command-free.
  'useCombatAuthoring.ts',
  // V4 revert cutover (0267 world_editor_revert): WorldEditor.tsx (the shell) is the sanctioned surface
  // that invokes the ONE cross-domain revert command on behalf of the read-only History panel — the
  // History UI files themselves stay transport-free (proven by worldEditorAuditGuards.spec.ts). The pure
  // command envelope is built in worldEditorHistoryRevert.ts (contract only, no command client).
  'WorldEditor.tsx',
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

  // Pin the EXACT import surface of the unified read snapshot (Foundation V1, PR #228; the 0252
  // create slice added the zone-ref flatten — STILL the same mapTypes read module, no new source).
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
