import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// TYPED-ZONE DISPATCH V2 (slice 6b) — structural guards. The behaviour is proven inside the
// migration's own self-assert against real Postgres; what is asserted here are the version-safety
// properties a type-checker cannot see:
//   * V1 is untouched and stays combat-blind — a frozen version must remain re-derivable;
//   * V2 is pure on the same terms as V1, and does NOT read the combat capability itself;
//   * combat is gated by an INPUT, so a pure planner never consults a flag;
//   * effect types resolve independently, but each still selects ONE zone (no duplicate spawns);
//   * the two versions do not silently accept each other's requests.
// Run: `npx playwright test zoneDispatchV2.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const v2 = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000279_typed_zone_effect_dispatch_v2.sql'),
  'utf8',
)
const v1 = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000274_typed_zone_effect_dispatch_v1.sql'),
  'utf8',
)

function v2Body(): string {
  const start = v2.indexOf('create function public.typed_zone_effect_dispatch_v2(')
  expect(start).toBeGreaterThan(-1)
  const end = v2.indexOf('revoke execute on function public.typed_zone_effect_dispatch_v2', start)
  expect(end).toBeGreaterThan(start)
  return v2.slice(start, end)
}

// ── version safety ──────────────────────────────────────────────────────────────────────────────
test('V2 is a NEW function — V1 is never replaced', () => {
  expect(v2).toMatch(/create function public\.typed_zone_effect_dispatch_v2\(/)
  expect(v2).not.toMatch(/create or replace function/i)
  expect(v2).not.toMatch(/drop function/i)
  // and the migration refuses to run if a V2 already exists
  expect(v2).toMatch(/versions are immutable; ship a _v3 sibling/)
})

test('V1 remains combat-blind, so a plan recorded under version 1 stays re-derivable', () => {
  expect(v1).not.toMatch(/combat/i)
  expect(v2).toMatch(/V1 learned about combat — V1 is immutable/)
})

test('the versions do not silently accept each other requests', () => {
  const body = v2Body()
  expect(body).toMatch(/only contract_version 2 is supported/)
  expect(v2).toMatch(/V2 accepted a contract_version 1 request/)
})

test('behavior_version 2 rides in every plan entry AND its idempotency identity', () => {
  const body = v2Body()
  expect((body.match(/'behavior_version', 2/g) ?? []).length).toBeGreaterThanOrEqual(4)
})

// ── purity ──────────────────────────────────────────────────────────────────────────────────────
test('V2 is pure on the same terms as V1', () => {
  const body = v2Body()
  for (const forbidden of [
    /\binsert\s+into\b/i,
    /\bupdate\s+public\./i,
    /\bdelete\s+from\b/i,
    /\bdanger_zones\b/i,
    /\bzone_effect_pirate_intercept\b/i,
    /\bzone_effect_combat\b/i,
    /\bgame_config\b/i,
    /\bcfg_bool\(/i,
    /\bcfg_num\(/i,
    /\brandom\(/i,
    /\bnow\(\)/i,
    /\bst_intersects\b/i,
  ]) {
    expect(body, `V2 must not contain ${forbidden}`).not.toMatch(forbidden)
  }
  expect(body).toMatch(/\bimmutable\b/)
  expect(body).toMatch(/\bparallel safe\b/)
})

test('the combat capability is an INPUT — a pure planner never reads a flag', () => {
  const body = v2Body()
  expect(body).not.toMatch(/typed_zone_combat_capability_v1/)
  expect(body).not.toMatch(/typed_zone_combat_runtime_enabled/)
  expect(body).not.toMatch(/encounter_resolver_enabled/)
  expect(body).toMatch(/combat_enabled/)
  // absent ⇒ false ⇒ combat plans nothing (fail-closed)
  expect(body).toMatch(/coalesce\(\(v_cfg->>'combat_enabled'\)::boolean, false\)/)
})

// ── composability + duplicate-spawn safety ──────────────────────────────────────────────────────
test('effect types resolve INDEPENDENTLY — one winner is tracked per type', () => {
  const body = v2Body()
  expect(body).toMatch(/v_best_p/)
  expect(body).toMatch(/v_best_c/)
  // a single shared winner would make the effects compete for one slot
  expect(body).not.toMatch(/v_best\b\s*:=/)
})

test('each effect type still selects ONE zone — overlap changes WHICH, never HOW MANY', () => {
  const body = v2Body()
  const policies = body.match(/'policy', 'max_exposure_then_zone_id_asc'/g) ?? []
  expect(policies).toHaveLength(2) // one per effect type
  expect(v2).toMatch(/overlap changes WHICH zone acts, never HOW MANY/)
})

test('a closed gate is a legitimate world state, not a malformed request', () => {
  const body = v2Body()
  // combat still VALIDATES when the gate is closed; it simply plans nothing
  expect(body).toMatch(/encounter_profile_id must be a uuid/)
  expect(body).toMatch(/if v_combat_ok and \(v_c->>'zone_status'\) = 'active' then/)
  expect(v2).toMatch(/combat planned while the gate was closed/)
})

test('combat config is validated even when it will not be planned', () => {
  const body = v2Body()
  expect(body).toMatch(/spawn_chance must be finite and within \[0,1\]/)
  expect(body).toMatch(/max_concurrent must be an integer >= 1/)
  // the validation sits BEFORE the gate check, so a bad config is caught either way
  expect(body.indexOf('spawn_chance must be finite')).toBeLessThan(
    body.indexOf('if v_combat_ok and'),
  )
})

// ── parity ──────────────────────────────────────────────────────────────────────────────────────
test('the self-assert PROVES pirate parity with V1 rather than assuming it', () => {
  expect(v2).toMatch(/V2 pirate risk diverges from V1/)
  expect(v2).toMatch(/typed_zone_effect_dispatch_v1\(v_req\)/)
})

test('an unknown effect type is still typed, never silently ignored', () => {
  expect(v2Body()).toMatch(/V2 registers pirate_intercept and combat, got/)
})

// ── the class of bug this slice actually hit ────────────────────────────────────────────────────
test('no typed-zone function body NAMES a token its own self-assert forbids, even in a comment', () => {
  // pg_get_functiondef returns the body INCLUDING comments, so a self-assert that greps for a
  // forbidden token will match a comment that merely mentions it — and the migration aborts at
  // deploy. V2 shipped that way for one commit: an in-body comment named the capability function it
  // is forbidden to read. Cheap to guard, invisible until a deploy fails.
  const cases: { file: string; fn: string; forbidden: RegExp[] }[] = [
    {
      file: '20260618000274_typed_zone_effect_dispatch_v1.sql',
      fn: 'typed_zone_effect_dispatch_v1',
      forbidden: [/danger_zones/, /zone_effect_pirate_intercept/, /game_config/, /cfg_num\(/, /cfg_bool\(/, /random\(/, /clock_timestamp/],
    },
    {
      file: '20260618000279_typed_zone_effect_dispatch_v2.sql',
      fn: 'typed_zone_effect_dispatch_v2',
      // exact table names, not the 'zone_effect_' prefix — that prefix is inside the function's OWN
      // name, which is precisely the trap this case exists to document
      forbidden: [/danger_zones/, /zone_effect_pirate_intercept/, /zone_effect_combat/, /game_config/, /cfg_num\(/, /cfg_bool\(/, /random\(/, /typed_zone_combat_capability_v1/],
    },
    {
      file: '20260618000275_typed_zone_pirate_shadow_v1.sql',
      fn: 'typed_zone_pirate_shadow_compare_v1',
      forbidden: [/pirate_intercept_evaluate_leg/, /\binsert\s/i, /\btruncate\b/i],
    },
  ]
  for (const { file, fn, forbidden } of cases) {
    const sql = readFileSync(join(repo, 'supabase', 'migrations', file), 'utf8')
    const start = sql.indexOf(`create function public.${fn}(`)
    expect(start, `${fn} must exist in ${file}`).toBeGreaterThan(-1)
    const end = sql.indexOf(`revoke execute on function public.${fn}`, start)
    const body = sql.slice(start, end)
    for (const token of forbidden) {
      expect(body, `${fn} body (comments included) must not contain ${token}`).not.toMatch(token)
    }
  }
})

test('V2 is engine-only', () => {
  expect(v2).toMatch(
    /revoke execute on function public\.typed_zone_effect_dispatch_v2\(jsonb\) from public, anon, authenticated/,
  )
  expect(v2).not.toMatch(/grant execute on function public\.typed_zone_effect_dispatch_v2/)
})
