import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// TYPED-ZONE CUTOVER (slice 4) — structural guards on the ONE live gameplay function this platform
// modifies. The behaviour under each flag state is proven against real Postgres in
// scripts/typed-zone-cutover-proof.sql; what is asserted here are the properties that make the
// cutover safe to deploy dark:
//   * it lands dark, and the legacy decision survives intact;
//   * exactly one path decides — one flag read, one roll, one log insert;
//   * the typed branch fails CLOSED and never silently falls back;
//   * the shared downstream (log/cancel/race/stub/presence/encounter) is untouched.
// Run: `npx playwright test zoneCutoverStructure.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000276_typed_zone_pirate_cutover.sql'),
  'utf8',
)
const original = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000233_pirate_intercept_danger_zones.sql'),
  'utf8',
)

/** The re-created function body only — not the header comments or the self-assert. */
function evaluatorBody(sql: string): string {
  const start = sql.indexOf('create or replace function public.pirate_intercept_evaluate_leg(')
  expect(start).toBeGreaterThan(-1)
  const end = sql.indexOf('\n$$;', start)
  expect(end).toBeGreaterThan(start)
  return sql.slice(start, end)
}

const body = evaluatorBody(migration)

test('it lands DARK: no flag is flipped and none is created', () => {
  expect(migration).not.toMatch(/update public\.game_config/i)
  expect(migration).not.toMatch(/insert into public\.game_config/i)
})

test('the cutover flag is read EXACTLY ONCE, into a local', () => {
  const reads = body.match(/cfg_bool\('typed_zone_pirate_intercept_runtime_enabled'\)/g) ?? []
  expect(reads).toHaveLength(1)
  expect(body).toMatch(/v_typed\s*:=\s*coalesce\(public\.cfg_bool\('typed_zone_pirate_intercept_runtime_enabled'\), false\)/)
  // every later branch reads the LOCAL, so a mid-execution flip cannot split one decision
  expect(body).toMatch(/if not v_typed then/)
  expect(body).toMatch(/if v_typed then/)
})

test('the pirate_intercept_enabled dark gate still runs BEFORE the cutover flag', () => {
  const darkGate = body.indexOf("cfg_bool('pirate_intercept_enabled')")
  const cutover = body.indexOf("cfg_bool('typed_zone_pirate_intercept_runtime_enabled')")
  expect(darkGate).toBeGreaterThan(-1)
  expect(cutover).toBeGreaterThan(darkGate)
})

test('BOTH deciders exist and the legacy one is intact', () => {
  expect(body).toMatch(/order by exposure_fraction desc, zone_id asc/)
  expect(body).toMatch(/pirate_intercept_compute_risk\(v_combined, v_hit\.exposure_fraction\)/)
  expect(body).toMatch(/typed_zone_pirate_candidates_v1/)
  expect(body).toMatch(/typed_zone_effect_dispatch_v1/)
})

test('exactly ONE roll and ONE log insert — a second of either would double-trigger', () => {
  expect(body.match(/random\(\)/g) ?? []).toHaveLength(1)
  expect(body.match(/insert into public\.pirate_intercepts/g) ?? []).toHaveLength(1)
})

test('the typed branch fails CLOSED and never silently falls back to legacy', () => {
  expect(body).toMatch(/typed_zone_dispatch_error/)
  // a dispatcher rejection must RETURN, not drop through into the legacy selection
  const rejection = body.slice(body.indexOf("if (v_res->>'ok') <> 'true' then"))
  expect(rejection.slice(0, 400)).toMatch(/return jsonb_build_object\('hit', false, 'reason', 'typed_zone_dispatch_error'\)/)
  // and the legacy selection must sit in the OTHER branch, not after the typed one
  expect(body).toMatch(/if not v_typed then[\s\S]*order by exposure_fraction desc[\s\S]*else[\s\S]*typed_zone_effect_dispatch_v1/)
})

test('every shared downstream anchor from 0233 survives the re-creation', () => {
  for (const anchor of [
    'insert into public.pirate_intercepts',
    'calculate_group_expedition_stats',
    'race_lost',
    'standalone_zone_stub_forced_stop',
    'location_missing',
    'public.fleet_set_in_space',
    'public.fleet_set_present',
    'group_sortie_members',
    'public.presence_create',
    'internal_error',
  ]) {
    expect(body, `lost 0233 anchor: ${anchor}`).toContain(anchor)
  }
})

test('the non-decision parts are copied VERBATIM from 0233, not retyped', () => {
  const originalBody = evaluatorBody(original)
  // sample distinctive lines that slice 4 has no business changing
  for (const line of [
    "return jsonb_build_object('hit', false, 'reason', 'not_group_fleet');",
    "return jsonb_build_object('hit', false, 'reason', 'not_moving');",
    "update public.pirate_intercepts set hit = false, note = 'race_lost' where id = v_log_id;",
    "update public.fleet_movements set status = 'cancelled', resolved_at = v_now where id = p_movement_id;",
  ]) {
    expect(originalBody, `precondition: 0233 should contain ${line}`).toContain(line)
    expect(body, `0276 must preserve verbatim: ${line}`).toContain(line)
  }
})

test('the signature and ACL are unchanged — engine-only', () => {
  expect(body).toMatch(/create or replace function public\.pirate_intercept_evaluate_leg\(p_movement_id uuid\)/)
  expect(migration).toMatch(
    /revoke execute on function public\.pirate_intercept_evaluate_leg\(uuid\) from public, anon, authenticated/,
  )
  expect(migration).toMatch(
    /grant execute on function public\.pirate_intercept_evaluate_leg\(uuid\) to service_role/,
  )
})

test('this slice adds no table, no column and no flag', () => {
  expect(migration).not.toMatch(/create table/i)
  expect(migration).not.toMatch(/alter table/i)
})
