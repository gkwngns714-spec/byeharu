import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// SEEDED-ZONE ERROR PRECEDENCE (0284). The bug that started the whole thread: editing a seeded zone
// reported "the live row changed since this draft was forked" when nothing had changed and the draft
// was fine. The zone was simply not editable — but the concurrency compare ran first and answered
// before the honest protected_zone check in the very next block could.
//
// An owner told "the live row changed" goes looking for a concurrent edit that does not exist. These
// tests pin the new order AND the two things that must NOT have moved with it.
// Run: `npx playwright test seededZoneErrorPrecedence.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
// Normalise line endings: git checks these files out with CRLF on Windows while a freshly generated
// one is LF, so a multi-line pattern would match one and miss the other for no semantic reason.
const m = (f: string) =>
  readFileSync(join(repo, 'supabase', 'migrations', f), 'utf8').replace(/\r\n/g, '\n')
const fixed = m('20260618000284_seeded_zone_error_precedence.sql')
const before = m('20260618000283_seeded_zone_unlock.sql')

const COMMANDS = ['zone_update', 'zone_unpublish', 'zone_set_active'] as const

function bodyOf(sql: string, fn: string): string {
  const start = sql.indexOf(`create or replace function public.${fn}(`)
  expect(start, `${fn} must exist`).toBeGreaterThan(-1)
  const end = sql.indexOf('\nend $$;', start)
  expect(end).toBeGreaterThan(start)
  return sql.slice(start, end)
}

// ── the regression, stated as the order it produced ─────────────────────────────────────────────
test('REGRESSION: 0283 really did answer stale_revision before protected_zone', () => {
  // the precondition for this slice existing — if this ever stops being true, so should 0284
  for (const fn of COMMANDS) {
    const body = bodyOf(before, fn)
    expect(
      body.indexOf("'stale_revision'"),
      `${fn} in 0283 should have reported stale first`,
    ).toBeLessThan(body.indexOf("v_live.provenance = 'seeded'"))
  }
})

test('eligibility now decides BEFORE the concurrency compare, in all three commands', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fixed, fn)
    expect(
      body.indexOf("v_live.provenance = 'seeded'"),
      `${fn} must decide eligibility first`,
    ).toBeLessThan(body.indexOf("'stale_revision'"))
  }
})

// ── the two things that must NOT have moved ─────────────────────────────────────────────────────
test('idempotent replay STILL precedes eligibility — a lost-response retry is never re-judged', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fixed, fn)
    expect(
      body.indexOf('from public.world_editor_audit where request_id'),
      `${fn} must replay before it judges`,
    ).toBeLessThan(body.indexOf("v_live.provenance = 'seeded'"))
  }
})

test('the ROW LOCK still precedes eligibility, so both checks read the same committed state', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fixed, fn)
    expect(body.indexOf('for update')).toBeLessThan(body.indexOf("v_live.provenance = 'seeded'"))
  }
})

// ── nothing about WHICH zones are protected changed ─────────────────────────────────────────────
test('protection itself is untouched: same provenance test, same flags, same zones', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fixed, fn)
    expect(body).toMatch(/v_live\.provenance = 'seeded'/)
    expect(body).not.toMatch(/v_live\.source <> 'drawn'/)
    expect(body).toMatch(/protected_zone/)
  }
  expect(fixed).toMatch(/seeded_zone_edit_enabled/)
  expect(fixed).toMatch(/seeded_zone_lifecycle_enabled/)
  // this slice must not flip or create a flag
  expect(fixed).not.toMatch(/insert into public\.game_config/i)
  expect(fixed).not.toMatch(/update public\.game_config/i)
  expect(fixed).toMatch(/a seeded-zone flag was disturbed/)
})

test('each command keeps its full house gate chain after the move', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fixed, fn)
    for (const anchor of ['not_authenticated', 'is_owner()', 'duplicate_request', 'world_editor_audit']) {
      expect(body, `${fn} lost ${anchor}`).toContain(anchor)
    }
  }
})

test('the block was MOVED, not rewritten — the guard text is identical to 0283', () => {
  for (const fn of COMMANDS) {
    const oldBody = bodyOf(before, fn)
    const newBody = bodyOf(fixed, fn)
    const guard = /if v_live\.provenance = 'seeded'\n\s+and not coalesce\(public\.cfg_bool\('[a-z_]+'\), false\) then/
    const a = oldBody.match(guard)
    const b = newBody.match(guard)
    expect(a, `${fn}: guard not found in 0283`).not.toBeNull()
    expect(b, `${fn}: guard not found in 0284`).not.toBeNull()
    expect(b![0], `${fn}: the guard was rewritten rather than moved`).toBe(a![0])
  }
})

test('it explains the cost of the old behaviour, not just the mechanics', () => {
  expect(fixed).toMatch(/goes looking for a concurrent edit that does not exist/)
  expect(fixed).toMatch(/A stale revision only MATTERS if the operation is otherwise permitted/)
})
