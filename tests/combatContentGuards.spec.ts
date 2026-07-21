import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// E4 — COMBAT CONTENT: STRUCTURAL GUARDS (source-text proofs of the slice's hard exclusions), copying the
// locationDraftGuards.spec.ts idiom:
//   1. PURITY — the pure logic + every presentation sub-panel reference NO command client (no
//      commandClient import, no invokeWorldEditorCommand): they build payloads / render, they do not write.
//   2. ONE COMMAND PATH — useCombatAuthoring.ts is the SOLE new E4 module that talks to the command client.
//   3. READ-ONLY SNAPSHOT — combatContentData.ts only calls the three read adapters; no supabase, no .rpc,
//      no .from, no .insert/.update/.delete.
// The dir-wide "no other world-editor module references a command client" law lives in
// locationDraftGuards.spec.ts, whose COMMAND_PATH_FILES this slice extends with useCombatAuthoring.ts.
// Run: `npx playwright test combatContentGuards.spec.ts`.

const WE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'features', 'worldeditor')
const read = (name: string): string => readFileSync(join(WE_DIR, name), 'utf8')

// The pure logic + presentation files that must stay command-free (never touch the command client).
const COMMAND_FREE_FILES = [
  'combatPayloads.ts',
  'combatMemberValidation.ts',
  'combatErrorMap.ts',
  'combatContentData.ts',
  'RewardProfileAuthoring.tsx',
  'EnemyArchetypeAuthoring.tsx',
  'FleetTemplateAuthoring.tsx',
  'EncounterProfileAuthoring.tsx',
  'LocationBindingAuthoring.tsx',
  'MemberSetEditor.tsx',
  'CombatContentPanel.tsx',
  'CombatFormField.tsx',
  'CombatErrorNotices.tsx',
]

// ── 1. purity guard ─────────────────────────────────────────────────────────────────────────────────
test('every pure/presentation E4 file references NO command client and no invokeWorldEditorCommand', () => {
  for (const name of COMMAND_FREE_FILES) {
    const src = read(name)
    expect(src, `${name} must not import commandClient`).not.toContain('commandClient')
    expect(src, `${name} must not invoke a world-editor command`).not.toContain('invokeWorldEditorCommand')
  }
})

// ── 2. one-command-path guard ───────────────────────────────────────────────────────────────────────
test('useCombatAuthoring.ts is the SOLE new E4 module that references the command client', () => {
  const hook = read('useCombatAuthoring.ts')
  expect(hook).toContain("from './commandClient'")
  expect(hook).toContain('invokeWorldEditorCommand')
  for (const name of COMMAND_FREE_FILES) {
    expect(read(name), `${name} must not reference invokeWorldEditorCommand`).not.toContain('invokeWorldEditorCommand')
  }
})

// ── 3. read-only snapshot guard ─────────────────────────────────────────────────────────────────────
test('combatContentData.ts only calls the three read adapters — no supabase/rpc/table/write', () => {
  const src = read('combatContentData.ts')
  // It composes exactly the three already-built read adapters.
  expect(src).toContain('fetchEnemyRegistryData')
  expect(src).toContain('fetchFleetEncounterData')
  expect(src).toContain('fetchLocationEncounterBindingData')
  // It never opens its own IO surface.
  expect(src, 'must not touch supabase directly').not.toMatch(/supabase/i)
  expect(src, 'must not call an RPC').not.toMatch(/\.rpc\s*\(/)
  expect(src, 'must not open a table query').not.toMatch(/\.from\s*\(/)
  expect(src, 'must not write').not.toMatch(/\.(insert|upsert|update|delete)\s*\(/)
})
