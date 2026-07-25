import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// TYPED-ZONE EFFECT AUTHORING (slice 5a) — structural guards on the two owner-gated BEHAVIOUR
// commands. The end-to-end behaviour belongs in a disposable-Postgres proof; what is asserted here
// are the properties that make these safe to deploy dark:
//   * separate intents — a behaviour command can NEVER move geometry, change kind or flip status;
//   * the aggregate revision moves with the effect, so no plan can claim a stale revision;
//   * the full house gate chain is present in both (authn → owner → capability → idempotency →
//     lock → optimistic concurrency);
//   * unknown effect types and already-absent effects are TYPED, never silent.
// Run: `npx playwright test zoneEffectAuthoring.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const migration = readFileSync(
  join(here, '..', 'supabase', 'migrations', '20260618000277_typed_zone_effect_authoring.sql'),
  'utf8',
)

const COMMANDS = ['zone_effect_set', 'zone_effect_remove'] as const

function bodyOf(fn: string): string {
  const start = migration.indexOf(`create or replace function public.${fn}(`)
  expect(start, `${fn} must exist`).toBeGreaterThan(-1)
  const end = migration.indexOf('\n$$;', start)
  expect(end).toBeGreaterThan(start)
  return migration.slice(start, end)
}

test('SEPARATE INTENTS: a behaviour command can never write geometry, identity or lifecycle', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fn)
    for (const forbidden of ['boundary', 'zone_kind', 'status', 'name', 'location_id']) {
      expect(
        body,
        `${fn} must not write danger_zones.${forbidden}`,
      ).not.toMatch(new RegExp(`update public\\.danger_zones set [^;]*${forbidden}\\s*=`, 'i'))
    }
    // the ONLY danger_zones write permitted is the revision bump
    const writes = body.match(/update public\.danger_zones set [^;]+/gi) ?? []
    expect(writes.length, `${fn} should write danger_zones exactly once`).toBe(1)
    expect(writes[0]).toMatch(/revision = revision \+ 1/)
  }
})

test('the aggregate revision moves with every effect change', () => {
  for (const fn of COMMANDS) {
    expect(bodyOf(fn), `${fn} must bump revision`).toMatch(/update public\.danger_zones set revision = revision \+ 1/)
  }
})

test('both commands carry the full house gate chain, in order', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fn)
    const authn = body.indexOf('not_authenticated')
    const authz = body.indexOf('is_owner()')
    const gate = body.indexOf('typed_zone_authoring_enabled')
    const replay = body.indexOf('from public.world_editor_audit where request_id')
    const lock = body.indexOf('for update')
    expect(authn, `${fn} authn`).toBeGreaterThan(-1)
    expect(authz, `${fn} authz`).toBeGreaterThan(authn)
    expect(gate, `${fn} capability gate after authz`).toBeGreaterThan(authz)
    expect(replay, `${fn} idempotent replay after the gate`).toBeGreaterThan(gate)
    expect(lock, `${fn} row lock`).toBeGreaterThan(replay)
  }
})

test('the capability gate sits AFTER authz so a non-owner cannot probe for it', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fn)
    expect(body.indexOf('typed_zone_authoring_enabled')).toBeGreaterThan(body.indexOf('is_owner()'))
  }
})

test('optimistic concurrency is enforced against an expected snapshot', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fn)
    expect(body).toMatch(/stale_revision/)
    expect(body).toMatch(/source_changed/)
  }
})

test('geometry is deliberately NOT part of the concurrency compare', () => {
  // a concurrent reshape is not a conflict for a behaviour-only command
  for (const fn of COMMANDS) {
    expect(bodyOf(fn)).not.toMatch(/st_equals|boundary/i)
  }
})

test('an unknown effect type is TYPED, never a silent no-op', () => {
  for (const fn of COMMANDS) {
    expect(bodyOf(fn)).toMatch(/unsupported_effect_type/)
  }
})

test('removing an absent effect is a typed outcome, not a silent success', () => {
  expect(bodyOf('zone_effect_remove')).toMatch(/effect_absent/)
})

test('NaN and the infinities are rejected in the command, not left to the constraint', () => {
  const body = bodyOf('zone_effect_set')
  expect(body).toMatch(/v_num <> v_num/)
  expect(body).toMatch(/'Infinity'::double precision/)
  expect(body).toMatch(/'-Infinity'::double precision/)
})

test('the RESOLVED band is validated, not just the supplied values', () => {
  expect(bodyOf('zone_effect_set')).toMatch(/invalid_resolved_effect_config/)
})

test('both commands are idempotent by request_id and audited', () => {
  for (const fn of COMMANDS) {
    const body = bodyOf(fn)
    expect(body).toMatch(/duplicate_request/)
    expect(body).toMatch(/insert into public\.world_editor_audit/)
    expect(body).toMatch(/before_snapshot, after_snapshot/)
    // a racing duplicate is caught and replayed rather than surfacing a raw unique violation
    expect(body).toMatch(/exception when unique_violation/)
  }
})

test('it lands dark and flips no flag', () => {
  expect(migration).not.toMatch(/update public\.game_config/i)
  expect(migration).not.toMatch(/insert into public\.game_config/i)
})

test('anon cannot execute either command; the owner check is server-side', () => {
  for (const fn of COMMANDS) {
    expect(migration).toMatch(new RegExp(`revoke execute on function public\\.${fn}\\(text, jsonb\\) from public, anon`))
    expect(migration).toMatch(new RegExp(`grant execute on function public\\.${fn}\\(text, jsonb\\) to authenticated`))
  }
})

test('kind conversion is deliberately NOT in this slice', () => {
  // converting a kind while stale effect config remains is a real hazard — it needs its own rules
  expect(migration).not.toMatch(/create or replace function public\.zone_kind_change/)
  expect(migration).toMatch(/deliberately NOT here/)
})
