import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// DANGER-ZONE PROVENANCE (0282). `source` has been answering two unrelated questions — geometry
// representation AND protection provenance. While they coincide the guards work; the moment anything
// legitimately changes a zone's geometry representation, its protection changes with it, and a
// capability flag that caused such a change could never be rolled back.
// These tests pin the split, the one-time classification, and the immutability that makes the new
// column worth more than the old one.
// Run: `npx playwright test dangerZoneProvenance.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const m = (f: string) => readFileSync(join(repo, 'supabase', 'migrations', f), 'utf8')
const migration = m('20260618000282_danger_zone_provenance.sql')

test('provenance is a constrained column defaulting to owner', () => {
  expect(migration).toMatch(/add column provenance text not null default 'owner'/)
  expect(migration).toMatch(/check \(provenance in \('seeded', 'owner'\)\)/)
  // anything created from now on is owner content unless deliberately stated otherwise
})

test('the classification happens ONCE and is never an ongoing gate', () => {
  const updates = migration.match(/update public\.danger_zones set provenance[^;]*/g) ?? []
  expect(updates).toHaveLength(1)
  expect(updates[0]).toMatch(/where source = 'circle'/)
  expect(migration).toMatch(/this is a one-time classification/)
})

test('it refuses to re-run — a second classification would reclassify owner content', () => {
  expect(migration).toMatch(/provenance already exists — this is a one-time classification/)
})

test('IMMUTABILITY IS ENFORCED, not documented — without it the column buys nothing', () => {
  expect(migration).toMatch(/create trigger danger_zones_provenance_immutable/)
  expect(migration).toMatch(/before update on public\.danger_zones/)
  expect(migration).toMatch(/danger_zones\.provenance is immutable/)
  expect(migration).toMatch(/errcode = 'check_violation'/)
  expect(migration).toMatch(/buys nothing over `source`/)
})

test('the self-assert PROVES the trigger fires, and that ordinary updates still work', () => {
  expect(migration).toMatch(/provenance was mutable/)
  expect(migration).toMatch(/the immutability trigger did not fire/)
  // a trigger that accidentally blocked every update would be worse than none
  expect(migration).toMatch(/made the table read-only by accident/)
})

test('behaviour neutrality is PROVEN by comparing both classifications, not asserted', () => {
  expect(migration).toMatch(/where \(source = 'circle'\) <> \(provenance = 'seeded'\)/)
  expect(migration).toMatch(/row\(s\) disagree between source and provenance/)
})

test('no live guard is re-pointed in this slice', () => {
  // switching zone_update / zone_unpublish / zone_set_active is its own reviewable change
  expect(migration).not.toMatch(/create or replace function public\.zone_update/)
  expect(migration).not.toMatch(/create or replace function public\.zone_unpublish/)
  expect(migration).not.toMatch(/create or replace function public\.zone_set_active/)
  expect(migration).toMatch(/zone_update was re-pointed — that is a separate slice/)
})

test('it adds no flag and writes no column other than provenance', () => {
  expect(migration).not.toMatch(/insert into public\.game_config/i)
  expect(migration).not.toMatch(/update public\.game_config/i)
  const zoneWrites = migration.match(/update public\.danger_zones set [a-z_]+/g) ?? []
  for (const w of zoneWrites) {
    expect(w, `only provenance and the no-op updated_at probe may be written: ${w}`).toMatch(
      /provenance|updated_at/,
    )
  }
})

test('the migration explains the one-way-door failure it prevents', () => {
  expect(migration).toMatch(/one-way door wearing the costume of a toggle/)
  expect(migration).toMatch(/source\s+= geometry representation, and ONLY that/)
})
