import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// ZONE KIND CHANGE (0285) — the fourth and last authoring intent, held back until every other one
// existed because it is the dangerous one: a zone converted from pirate to mining that KEEPS its
// pirate_intercept effect is a "mining" zone that still intercepts fleets. Nothing in the schema
// forbids that — effects key on zone_id, not kind, precisely so they compose.
// These tests pin the conversion rule, the refusal to delete authored config, and identity-only scope.
// Run: `npx playwright test zoneKindChange.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000285_zone_kind_change.sql'),
  'utf8',
).replace(/\r\n/g, '\n')

function body(): string {
  const start = migration.indexOf('create or replace function public.zone_kind_change(')
  expect(start).toBeGreaterThan(-1)
  const end = migration.indexOf('\nend $$;', start)
  return migration.slice(start, end)
}

// ── the conversion rule ─────────────────────────────────────────────────────────────────────────
test('a conversion is REFUSED while a non-permitted effect remains, and names each one', () => {
  const b = body()
  expect(b).toMatch(/incompatible_effects/)
  expect(b).toMatch(/array_to_string\(v_stale, ', '\)/)
  expect(b).toMatch(/they are not deleted automatically/)
  // the refusal carries the offending effects as data, not only prose
  expect(b).toMatch(/'effects', to_jsonb\(v_stale\)/)
})

test('it NEVER deletes an effect to make a conversion succeed', () => {
  expect(body()).not.toMatch(/delete from public\.zone_effect_/)
  expect(migration).toMatch(/authored config must not be destroyed to satisfy a rename/)
})

test('every one of the four effect tables is checked for staleness', () => {
  const b = body()
  for (const t of [
    'zone_effect_pirate_intercept',
    'zone_effect_combat',
    'zone_effect_mining',
    'zone_effect_exploration',
  ]) {
    expect(b, `staleness check must cover ${t}`).toContain(t)
  }
})

test('the kind/effect map is DATA, not a CASE buried in the command', () => {
  expect(migration).toMatch(/create table public\.zone_kind_permitted_effects/)
  expect(migration).toMatch(/insert into public\.zone_kind_permitted_effects/)
  // the command reads the table rather than hardcoding pairs
  expect(body()).toMatch(/from public\.zone_kind_permitted_effects p/)
  expect(body()).not.toMatch(/case\s+when\s+v_new_kind/i)
})

test('no dispatcher reads the kind/effect map — identity must never dispatch', () => {
  const v2 = readFileSync(
    join(repo, 'supabase', 'migrations', '20260618000279_typed_zone_effect_dispatch_v2.sql'),
    'utf8',
  )
  expect(v2).not.toMatch(/zone_kind_permitted_effects/)
  expect(migration).toMatch(/a dispatcher reads the kind\/effect map — identity must never dispatch/)
})

// ── identity only ───────────────────────────────────────────────────────────────────────────────
test('it changes IDENTITY and nothing else', () => {
  const b = body()
  const writes = b.match(/update public\.danger_zones set [^;]+/g) ?? []
  expect(writes).toHaveLength(1)
  expect(writes[0]).toMatch(/set zone_kind = v_new_kind, revision = revision \+ 1/)
  for (const col of ['boundary', 'status', 'location_id', 'provenance']) {
    expect(writes[0], `must not write ${col}`).not.toMatch(new RegExp(`${col}\\s*=`))
  }
})

// ── precedence, inherited from 0284 ─────────────────────────────────────────────────────────────
test('precedence follows 0284: replay, then lock, then eligibility, then concurrency', () => {
  const b = body()
  const replay = b.indexOf('from public.world_editor_audit where request_id')
  const lock = b.indexOf('for update')
  const elig = b.indexOf('incompatible_effects')
  const stale = b.indexOf("'stale_revision'")
  expect(replay).toBeGreaterThan(-1)
  expect(lock).toBeGreaterThan(replay)
  expect(elig).toBeGreaterThan(lock)
  expect(stale).toBeGreaterThan(elig)
})

test('a no-op conversion is a typed outcome, not a silent success that burns a request_id', () => {
  expect(body()).toMatch(/already_that_kind/)
})

test('an unrecognised target kind is typed, and checked before any world read', () => {
  const b = body()
  expect(b).toMatch(/unsupported_zone_kind/)
  expect(b.indexOf('unsupported_zone_kind')).toBeLessThan(b.indexOf('for update'))
})

// ── house rules ─────────────────────────────────────────────────────────────────────────────────
test('it lands dark behind the authoring flag, gated after authz', () => {
  const b = body()
  expect(b).toMatch(/typed_zone_authoring_enabled/)
  expect(b.indexOf('typed_zone_authoring_enabled')).toBeGreaterThan(b.indexOf('is_owner()'))
  expect(migration).not.toMatch(/update public\.game_config/i)
})

test('it carries the full house gate chain and is not anon-executable', () => {
  const b = body()
  for (const anchor of ['not_authenticated', 'is_owner()', 'duplicate_request', 'world_editor_audit', 'for update']) {
    expect(b, `lost ${anchor}`).toContain(anchor)
  }
  expect(migration).toMatch(/revoke execute on function public\.zone_kind_change\(text, jsonb\) from public, anon/)
  expect(migration).toMatch(/grant execute on function public\.zone_kind_change\(text, jsonb\) to authenticated/)
})

test('the permission table is fail-closed', () => {
  expect(migration).toMatch(/alter table public\.zone_kind_permitted_effects enable row level security/)
  expect(migration).toMatch(/revoke all on table public\.zone_kind_permitted_effects from anon, authenticated/)
})

test('it completes the four separate authoring intents', () => {
  // geometry (0266), behaviour (0277 set/remove), lifecycle (0255/0268), identity (this)
  expect(migration).toMatch(/the fourth and last authoring intent/i)
  expect(migration).toMatch(/Changes IDENTITY and nothing else/)
})
