import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// TYPED-ZONE COMBAT EFFECT (slice 6) — structural guards. The behaviour runs against real Postgres in
// scripts/typed-zone-combat-proof.sql; what is asserted here are the properties that make a SECOND
// effect safe to add at all:
//   * it is a SIBLING — adding a behaviour must not touch the behaviour beside it;
//   * the dual gate is an AND, written in ONE place, and never implies the resolver;
//   * V1 dispatch and the V1 candidate builder stay combat-blind, so a combat row cannot make V1
//     reject a zone that also carries pirate interception;
//   * the table is fail-closed and its content is relational, not a blob.
// Run: `npx playwright test zoneCombatEffect.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000278_typed_zone_combat_effect.sql'),
  'utf8',
)
const dispatchV1 = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000274_typed_zone_effect_dispatch_v1.sql'),
  'utf8',
)
const shadow = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000275_typed_zone_pirate_shadow_v1.sql'),
  'utf8',
)
const foundation = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000273_typed_zone_effect_foundation.sql'),
  'utf8',
)

// ── sibling, not surgery ────────────────────────────────────────────────────────────────────────
test('a second effect is a SIBLING TABLE — it alters nothing that already exists', () => {
  expect(migration).toMatch(/create table public\.zone_effect_combat/)
  expect(migration).not.toMatch(/alter table public\.zone_effect_pirate_intercept/i)
  expect(migration).not.toMatch(/alter table public\.danger_zones/i)
  expect(migration).not.toMatch(/drop /i)
  // and it re-creates no existing function
  expect(migration).not.toMatch(/create or replace function/i)
})

test('it keys on zone_id exactly as the pirate effect does — presence IS the row', () => {
  expect(migration).toMatch(
    /zone_id\s+uuid primary key references public\.danger_zones \(id\) on delete cascade/,
  )
  expect(foundation).toMatch(
    /zone_id\s+uuid primary key references public\.danger_zones \(id\) on delete cascade/,
  )
})

// ── relational content, not a blob ──────────────────────────────────────────────────────────────
test('the encounter profile is a REAL foreign key, never a jsonb id', () => {
  expect(migration).toMatch(/encounter_profile_id\s+uuid not null references public\.encounter_profiles \(id\)/)
  expect(migration).not.toMatch(/config\s+jsonb|payload\s+jsonb|settings\s+jsonb/i)
})

test('every numeric knob is bounded, and NaN / infinity are rejected explicitly', () => {
  // Postgres orders NaN above every real, so a bare range check is not enough
  expect(migration).toMatch(/spawn_chance = spawn_chance/)
  expect(migration).toMatch(/spawn_chance <> 'Infinity'::double precision/)
  expect(migration).toMatch(/spawn_chance <> '-Infinity'::double precision/)
  expect(migration).toMatch(/spawn_chance >= 0 and spawn_chance <= 1/)
  expect(migration).toMatch(/max_concurrent >= 1 and max_concurrent <= 100/)
  expect(migration).toMatch(/cooldown_seconds >= 0/)
})

// ── the dual gate ───────────────────────────────────────────────────────────────────────────────
test('the capability is an AND of BOTH flags, written in exactly ONE place', () => {
  const start = migration.indexOf('create function public.typed_zone_combat_capability_v1')
  expect(start).toBeGreaterThan(-1)
  const body = migration.slice(start, migration.indexOf('$$;', start))
  expect(body).toMatch(/typed_zone_combat_runtime_enabled/)
  expect(body).toMatch(/encounter_resolver_enabled/)
  expect(body).toMatch(/\band\b/)
  expect(body).not.toMatch(/\bor\b/)
})

test('the flag lands false and the resolver flag is never touched', () => {
  expect(migration).toMatch(/'typed_zone_combat_runtime_enabled',\s*'false'::jsonb/)
  // lighting typed combat zones must NEVER imply lighting the resolver
  expect(migration).not.toMatch(/update public\.game_config[\s\S]{0,200}encounter_resolver_enabled/i)
  expect(migration).not.toMatch(/insert into public\.game_config[\s\S]{0,200}encounter_resolver_enabled/i)
})

test('the self-assert PROVES the AND by lighting one half, not by asserting it', () => {
  expect(migration).toMatch(/that is an OR, not an AND/)
  // and the probe must roll back, leaving the flag false
  expect(migration).toMatch(/tz0278_rollback_probe/)
  expect(migration).toMatch(/the AND probe leaked a lit flag/)
})

// ── V1 must stay combat-blind ───────────────────────────────────────────────────────────────────
test('V1 dispatch is immutable and knows nothing of combat', () => {
  expect(dispatchV1).not.toMatch(/combat/i)
  expect(migration).toMatch(/V1 dispatch mentions combat — V1 is immutable/)
})

test('the V1 candidate builder reads ONLY the pirate effect table', () => {
  const start = shadow.indexOf('create function public.typed_zone_pirate_candidates_v1')
  const end = shadow.indexOf('revoke execute on function public.typed_zone_pirate_candidates_v1', start)
  const body = shadow.slice(start, end)
  expect(body).toMatch(/zone_effect_pirate_intercept/)
  expect(body).not.toMatch(/zone_effect_combat/)
  // …and 0278 asserts that at deploy time too
  expect(migration).toMatch(/the V1 candidate builder reads the combat table/)
})

test('a zone may carry BOTH effects without breaking the pirate path', () => {
  // this is the composability claim, and it holds only because the V1 builder is pirate-only
  expect(migration).toMatch(/composab/i)
  expect(migration).toMatch(/cannot leak into a V1 request/)
})

// ── fail-closed ─────────────────────────────────────────────────────────────────────────────────
test('the table is fail-closed: RLS on, no policy, no client grant', () => {
  expect(migration).toMatch(/alter table public\.zone_effect_combat enable row level security/)
  expect(migration).toMatch(/revoke all on table public\.zone_effect_combat from anon, authenticated/)
  expect(migration).not.toMatch(/create policy .* on public\.zone_effect_combat/)
  expect(migration).not.toMatch(/grant (select|insert|update|delete).* on (table )?public\.zone_effect_combat/i)
})

// ── the proof must not be able to fake a pass ───────────────────────────────────────────────────
test('the proof mints its own fixture instead of skipping when seed data is absent', () => {
  const proof = readFileSync(join(repo, 'scripts', 'typed-zone-combat-proof.sql'), 'utf8')
  expect(proof).toMatch(/insert into public\.encounter_profiles/)
  // No skip branch may emit a PASS marker for a test that never ran. Checked against the emitted
  // NOTICEs, not against prose — the header legitimately discusses skipping in order to reject it.
  const notices = proof.match(/raise notice '[^']*'/g) ?? []
  for (const n of notices) {
    expect(n, `a marker must not be conditional on skipping: ${n}`).not.toMatch(/skip/i)
  }
  expect(proof).not.toMatch(/raise exception 'tzk_skip'/)
  expect(proof).toMatch(/worse than no proof at all/)
})

test('the proof tests the claim that actually matters: a two-effect zone plans the SAME pirate risk', () => {
  const proof = readFileSync(join(repo, 'scripts', 'typed-zone-combat-proof.sql'), 'utf8')
  expect(proof).toMatch(/carrying a combat effect changed the pirate risk/)
  expect(proof).toMatch(/TZK_PASS_COMPOSABLE_PIRATE_UNAFFECTED/)
  // and the dual gate is exercised across all four combinations, not just the closed one
  expect(proof).toMatch(/only the ZONE half lit/)
  expect(proof).toMatch(/only the RESOLVER half lit/)
  expect(proof).toMatch(/BOTH halves lit/)
})

test('the capability function is engine-only', () => {
  expect(migration).toMatch(
    /revoke execute on function public\.typed_zone_combat_capability_v1\(\) from public, anon, authenticated/,
  )
  expect(migration).not.toMatch(/grant execute on function public\.typed_zone_combat_capability_v1/)
})
