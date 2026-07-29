import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// SEEDED-ZONE UNLOCK (0283). This is what finally answers "I want to edit the three seeded zones",
// and it is only safe because 0282 made provenance immutable: flipping a flag off restores
// protection exactly, instead of leaving an adopted zone permanently indistinguishable from owner
// content. These tests pin that reversibility, the behaviour-neutral landing, and the fact that three
// live owner commands were re-created without losing anything around the one line that changed.
// Run: `npx playwright test seededZoneUnlock.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const m = (f: string) => readFileSync(join(repo, 'supabase', 'migrations', f), 'utf8')
const unlock = m('20260618000283_seeded_zone_unlock.sql')

const COMMANDS = ['zone_update', 'zone_unpublish', 'zone_set_active'] as const

function bodyOf(fn: string): string {
  const start = unlock.indexOf(`create or replace function public.${fn}(`)
  expect(start, `${fn} must be re-created`).toBeGreaterThan(-1)
  const end = unlock.indexOf('\nend $$;', start)
  expect(end).toBeGreaterThan(start)
  return unlock.slice(start, end)
}

// ── reversibility, which is the whole point ─────────────────────────────────────────────────────
test('every guard now reads the IMMUTABLE provenance, and none still gates protection on source', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fn)
    expect(body, `${fn} must gate on provenance`).toMatch(/v_live\.provenance = 'seeded'/)
    expect(body, `${fn} must not gate protection on source`).not.toMatch(/v_live\.source <> 'drawn'/)
    expect(body).toMatch(/protected_zone/)
  }
})

test('it refuses to run without the immutability trigger — otherwise the flags are one-way doors', () => {
  expect(unlock).toMatch(/pg_trigger where tgname = 'danger_zones_provenance_immutable'/)
  expect(unlock).toMatch(/without it these flags are one-way doors/)
})

// ── behaviour-neutral landing ───────────────────────────────────────────────────────────────────
test('both flags land FALSE, so protection is unchanged on deploy day', () => {
  expect(unlock).toMatch(/'seeded_zone_edit_enabled',\s*'false'::jsonb/)
  expect(unlock).toMatch(/'seeded_zone_lifecycle_enabled',\s*'false'::jsonb/)
  expect(unlock).toMatch(/seeded_zone_edit_enabled is not false/)
  expect(unlock).toMatch(/seeded_zone_lifecycle_enabled is not false/)
})

test('neutrality is RE-PROVEN here rather than inherited from 0282', () => {
  expect(unlock).toMatch(/where \(source <> 'drawn'\) <> \(provenance = 'seeded'\)/)
  expect(unlock).toMatch(/row\(s\) would change protection status/)
})

// ── two flags, genuinely separate ───────────────────────────────────────────────────────────────
test('editing and lifecycle are separate capabilities, not one flag', () => {
  expect(bodyOf('zone_update')).toMatch(/seeded_zone_edit_enabled/)
  expect(bodyOf('zone_update')).not.toMatch(/seeded_zone_lifecycle_enabled/)
  for (const fn of ['zone_unpublish', 'zone_set_active'] as const) {
    expect(bodyOf(fn)).toMatch(/seeded_zone_lifecycle_enabled/)
    expect(bodyOf(fn)).not.toMatch(/seeded_zone_edit_enabled/)
  }
  expect(unlock).toMatch(/a lifecycle command reads the EDIT flag/)
  expect(unlock).toMatch(/zone_update reads the LIFECYCLE flag/)
})

// ── the re-creation kept everything else ────────────────────────────────────────────────────────
test('each re-created command keeps its full house gate chain', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fn)
    for (const anchor of ['not_authenticated', 'is_owner()', 'world_editor_audit', 'for update', 'duplicate_request']) {
      expect(body, `${fn} lost ${anchor}`).toContain(anchor)
    }
  }
})

test('the non-guard parts are copied VERBATIM from the originals, not retyped', () => {
  const original = m('20260618000266_worldeditor_publish_zone_update.sql')
  const body = bodyOf('zone_update')
  for (const line of [
    "return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');",
    "select result into v_prior from public.world_editor_audit where request_id = p_request_id;",
  ]) {
    expect(original, `precondition: 0266 should contain ${line}`).toContain(line)
    expect(body, `0283 must preserve verbatim: ${line}`).toContain(line)
  }
})

test('the guard message no longer claims the old source-based rule', () => {
  for (const fn of COMMANDS) {
    expect(bodyOf(fn)).not.toMatch(/Only editor-created \(source=''drawn''\)/)
  }
  expect(unlock).toMatch(/This is a seeded zone\./)
})

// ── honest about what it does NOT fix ───────────────────────────────────────────────────────────
test('it states plainly that the misleading error PRECEDENCE is still unfixed', () => {
  // editing a seeded zone still reports stale_revision before protected_zone — the original
  // complaint in this thread. Reordering moves code inside a live command; separate slice.
  expect(unlock).toMatch(/NOT CHANGED HERE: the misleading error PRECEDENCE/)
  expect(unlock).toMatch(/deserves its own slice/)
})
