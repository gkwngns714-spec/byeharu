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

test('the History slice offers NO rollback / replay / restore / republish / rerun control', () => {
  for (const f of [...HISTORY_UI_FILES, ...AUDIT_LOGIC_FILES]) {
    expect(read(f), `${f} must not contain a mutation-verb control`).not.toMatch(/rollback|replay|restore|republish|rerun/i)
  }
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
