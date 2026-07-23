import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V1.5 — STRUCTURAL SECURITY/SCOPE GUARDS for the read-only History slice (source-text
// proofs, in the pure-Node frontend-tests convention). They prove the slice can express NO write and NO
// direct ledger read: the ONLY audit read path is the deployed world_editor_audit_list RPC; there is no
// supabase/table/rpc/service-role/mutation surface in the UI or logic modules; the detail view offers no
// rollback/replay/restore control; and the WorldEditor integration preserves the live selection + the
// existing gates while reusing the ONE camera authority.

const WE = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'features', 'worldeditor')
const read = (f: string): string => readFileSync(join(WE, f), 'utf8')

const HISTORY_UI_FILES = [
  'WorldEditorHistoryPanel.tsx',
  'WorldEditorHistoryFilters.tsx',
  'WorldEditorHistoryList.tsx',
  'WorldEditorHistoryDetail.tsx',
]
const AUDIT_LOGIC_FILES = [
  'worldEditorAuditTypes.ts',
  'worldEditorAuditNormalize.ts',
  'worldEditorAuditDiff.ts',
  'worldEditorAuditFocus.ts',
  'worldEditorAuditView.ts',
  'worldEditorAuditRequestState.ts',
]

test('transport: the ONE audit read path calls only world_editor_audit_list — no table read, no mutation', () => {
  const data = read('worldEditorAuditData.ts')
  expect(data).toContain("supabase.rpc('world_editor_audit_list'")
  expect(data).not.toMatch(/\.from\s*\(/) // no direct table SELECT
  expect(data).not.toMatch(/\.(insert|update|delete|upsert)\s*\(/) // no mutation
  expect(data).not.toMatch(/service_role/i)
  expect(data).not.toMatch(/from\s*\(\s*['"]world_editor_audit['"]/) // never queries the ledger directly
})

test('no History UI / audit-logic module touches supabase, a table, an rpc, or a mutation client directly', () => {
  for (const f of [...HISTORY_UI_FILES, ...AUDIT_LOGIC_FILES]) {
    const src = read(f)
    expect(src, `${f} must not import supabase`).not.toMatch(/import\b[^\n]*supabase/)
    expect(src, `${f} must not use supabase.<x>`).not.toMatch(/\bsupabase\s*\./)
    expect(src, `${f} must not open a table query`).not.toMatch(/\bfrom\s*\(\s*['"]/)
    expect(src, `${f} must not call an rpc directly`).not.toMatch(/\.rpc\s*\(/)
    expect(src, `${f} must not use a command/mutation client`).not.toMatch(/invokeWorldEditorCommand|commandClient/)
    expect(src, `${f} must not reference service_role`).not.toMatch(/service_role/i)
  }
})

test('the History slice offers NO in-place rollback / replay / republish / rerun control', () => {
  // V1.5 was inspect-only. V4 adds ONE composed control — "Revert to this version" (WorldEditorHistoryDetail)
  // — delegated to the shell's onRevert prop, which invokes the ONE server-authoritative revert
  // (world_editor_revert, 0267). The History UI/logic files must still carry NO transport of their own and
  // must not name any in-place re-execution mechanism (rollback/replay/republish/rerun) — the server RPC is
  // the sole authority (the no-supabase/no-rpc/no-command-client guard above proves the files carry no
  // direct write surface; "revert" is the composed control, not a raw re-run of the audited command).
  for (const f of [...HISTORY_UI_FILES, ...AUDIT_LOGIC_FILES]) {
    expect(read(f), `${f} must not contain an in-place re-run control`).not.toMatch(/rollback|replay|republish|rerun/i)
  }
})

test('V4 revert is a single world_editor_revert command through the shell prop — the detail carries no transport', () => {
  const detail = read('WorldEditorHistoryDetail.tsx')
  // the action is delegated to the shell via a prop callback (mirrors onFocusMap), never done inline
  expect(detail).toContain('onRevert')
  // and the detail itself opens no command/rpc/supabase path (defence in depth beside the guard above)
  expect(detail, 'the detail must not invoke the command directly').not.toMatch(/invokeWorldEditorCommand|commandClient|\.rpc\s*\(/)
  // NO leftover client-side field reconstruction (retired PR #269): the detail neither seeds a draft nor
  // rebuilds the historical payload — a revert is the single server command, nothing else.
  expect(detail, 'the detail must not reconstruct the revert payload client-side').not.toMatch(
    /forkEditWithPayload|resolveLocationRevert|revertSeedFromEntry/,
  )
})

test('ONE revert authority: the shell routes revert through world_editor_revert; NO client-side reconstruction survives', () => {
  const we = read('WorldEditor.tsx')
  // the shell invokes the ONE server revert command (built by the pure envelope helper) and re-reads the map
  expect(we, 'the shell must invoke the command transport for revert').toContain('invokeWorldEditorCommand')
  expect(we, 'the shell must build the revert envelope from the audit entry').toContain('revertCommandEnvelope')
  expect(we, 'a successful revert must re-read the map snapshot').toContain('reloadData')
  // the retired PR #269 client-only reconstruction is GONE from the shell (one revert path, no dead code)
  expect(we, 'the shell must not fork a revert draft').not.toContain('resolveLocationRevert')
  expect(we, 'the shell must not seed a revert draft').not.toContain('revertSeedFromEntry')

  // and the reconstruction functions themselves no longer exist in the decision module
  const revert = read('worldEditorHistoryRevert.ts')
  expect(revert, 'resolveLocationRevert must be retired').not.toContain('resolveLocationRevert')
  expect(revert, 'revertSeedFromEntry must be retired').not.toContain('revertSeedFromEntry')
  // the module now only decides visibility + builds the server command envelope
  expect(revert).toContain('canRevertEntry')
  expect(revert).toContain('revertCommandEnvelope')
  expect(revert).toContain("commandType: 'world_editor_revert'")
})

test('the Panel drives the pure request coordinator and keeps NO duplicate sequencing of its own', () => {
  const panel = read('WorldEditorHistoryPanel.tsx')
  // consumes the extracted pure coordinator
  expect(panel).toMatch(/from '\.\/worldEditorAuditRequestState'/)
  expect(panel).toContain('beginInitial')
  expect(panel).toContain('applyInitialSuccess')
  expect(panel).toContain('applyNextPageSuccess')
  expect(panel).toContain('beginNextPage')
  // does NOT reimplement the merge/generation logic inline
  expect(panel, 'panel must not re-run its own page merge').not.toMatch(/mergePageDedup\s*\(/)
  expect(panel, 'panel must not track a raw generation ref').not.toContain('genRef')
})

test('only the Panel + the data module reference the audit fetch; presentation children never fetch', () => {
  expect(read('WorldEditorHistoryPanel.tsx')).toContain('fetchWorldEditorAudit')
  for (const f of ['WorldEditorHistoryFilters.tsx', 'WorldEditorHistoryList.tsx', 'WorldEditorHistoryDetail.tsx']) {
    expect(read(f), `${f} must not fetch independently`).not.toContain('fetchWorldEditorAudit')
  }
})

test('WorldEditor integration: historical focus preserves the live selection + reuses the ONE camera authority', () => {
  const we = read('WorldEditor.tsx')
  const m = /const focusHistorical = \(focus: HistoricalFocus\) => \{([\s\S]*?)\n {2}\}/.exec(we)
  expect(m, 'focusHistorical must exist').toBeTruthy()
  const body = m![1]
  expect(body).toContain('fitCameraToWorldPoints') // the ONE camera authority
  expect(body).toContain('setHistoricalFocus')
  expect(body).toContain('userMovedRef')
  expect(body, 'historical focus must NEVER write the live selection').not.toContain('setSelected')
  // no second camera-fit authority introduced in the shell
  expect(we).not.toMatch(/function fitCamera|const fitCamera\s*=/)
})

test('the History panel is mounted inside the gated WorldEditor shell; gates remain intact', () => {
  const we = read('WorldEditor.tsx')
  expect(we).toContain('<WorldEditorHistoryPanel')
  expect(we).toContain('onFocusHistorical={focusHistorical}')
  expect(we).toContain('onClearHistorical={clearHistorical}')
  // the owner/flag/auth gates are unchanged (dark until the dev flag is lit)
  expect(we).toContain('fetchDevZoneEditorEnabled')
  expect(we).toContain('enabled !== true')
})
