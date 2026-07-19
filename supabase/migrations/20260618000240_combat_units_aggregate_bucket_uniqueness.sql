-- Byeharu — COMBAT CARDINALITY FIX: scope combat_units uniqueness to the aggregate player bucket.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE BUG: migration 0023 (20260617000023_combat_per_unit_and_pacing.sql) created combat_units with a
-- BLANKET table constraint `unique (encounter_id, unit_type_id)` — auto-named
-- `combat_units_encounter_id_unit_type_id_key`. At the time (0023) EVERY combat_units row was a legacy
-- aggregate: one row per (encounter, player unit type), unit_type_id NOT NULL, and no other row shape
-- existed. So (encounter_id, unit_type_id) was a legitimate identity there.
--
-- Since then the row model has grown THREE classes that share one table (all audited + prod-verified):
--   • AGGREGATE player  = (side='player', main_ship_id IS NULL, unit_type_id IS NOT NULL)
--       the legacy per-unit-type bucket 0023 minted — combat_create_encounter's non-spatial branch
--       (0023/0168) inserts one row per distinct fleet unit type. Genuinely one bucket per
--       (encounter, unit_type). THIS is the only class the uniqueness ever meant to constrain.
--   • MEMBER player     = (side='player', main_ship_id IS NOT NULL, unit_type_id IS NULL)
--       a per-main-ship row (slice D1, 0167). unit_type_id is NULL here → NULLs never collide in a
--       unique key, so the blanket constraint never actually constrained members anyway; their
--       cardinality is owned by the partial index `combat_units_one_member_row_per_encounter` (0167:95,
--       predicate `where main_ship_id is not null`). This migration does NOT touch that index.
--   • SYNTHETIC enemy   = (side='enemy', unit_type_id='pirate_synthetic', main_ship_id IS NULL)
--       a per-pirate row (COMBAT-S3, 0234) — the spatial wave spawns N INDIVIDUAL pirates, N =
--       min(enemy_synthetic_max_units, danger_level), EACH its own combat_units row, ALL sharing the
--       single identity-anchor unit_type_id='pirate_synthetic' (0234:707-719). Under the blanket
--       constraint, the SECOND pirate of a wave is a unique-key collision on
--       (encounter_id, 'pirate_synthetic') → the INSERT raises → process_combat_ticks' wave-spawn hunk
--       aborts → the encounter STALLS. This is the multi-pirate stall: at danger_level >= 2 (the FIRST
--       point N reaches 2), every spatial danger-zone wave with more than one pirate is unspawnable.
--
-- The `combat_units_exactly_one_identity` CHECK (0167:77, `(unit_type_id is null) <> (main_ship_id is
-- null)`) makes `main_ship_id IS NULL` the authoritative discriminator of an aggregate row: a player
-- row is aggregate IFF main_ship_id IS NULL (and then, by the XOR, unit_type_id IS NOT NULL).
--
-- THE FIX (owner-approved invariant — do NOT redesign): drop the blanket constraint; replace it with a
-- PARTIAL unique index covering ONLY the legacy aggregate player class. Enemy rows (side='enemy') and
-- member rows (main_ship_id IS NOT NULL) fall outside the predicate and are freely multi-row; aggregate
-- rows keep their exact one-bucket-per-(encounter, unit_type) guarantee.
--
-- WHY ZERO FUNCTION CHANGES ARE NEEDED (audit-proven): no reader relies on the blanket uniqueness for
-- correctness, and NO writer targets `(encounter_id, unit_type_id)` in an ON CONFLICT clause — the
-- combat writers (combat_create_encounter/combat_create_group_encounter/process_combat_ticks/
-- report_create) all INSERT plain rows and address existing rows by their `id` PK. So the constraint's
-- ONLY runtime effect was to REJECT the 2nd+ synthetic-enemy INSERT. Removing that rejection (while
-- preserving aggregate-bucket uniqueness) is a pure widening — every previously-legal write stays legal,
-- and the previously-ILLEGAL multi-pirate write becomes legal, which is the entire point.
--
-- ATOMIC + TRANSACTIONAL: DROP CONSTRAINT + CREATE UNIQUE INDEX (NOT concurrently — the table is tiny;
-- concurrently would forbid running inside the migration txn) run in this migration's single implicit
-- transaction. If the new index cannot build (a violating aggregate duplicate already exists), the
-- CREATE fails and the whole migration rolls back cleanly — nothing half-applies, the blanket
-- constraint is NOT left dropped-without-replacement.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1. drop the blanket constraint (invalid for the synthetic-enemy + member row classes) ─────────
alter table public.combat_units
  drop constraint combat_units_encounter_id_unit_type_id_key;

-- ── 2. re-scope uniqueness to the aggregate player bucket ONLY ────────────────────────────────────
-- Predicate = the exact aggregate-row discriminator: a player row with no main ship and a real unit
-- type. Members (main_ship_id NOT NULL) and enemies (side='enemy') are outside it → freely multi-row.
create unique index combat_units_one_aggregate_bucket_per_encounter
  on public.combat_units (encounter_id, unit_type_id)
  where side = 'player' and main_ship_id is null and unit_type_id is not null;

comment on index public.combat_units_one_aggregate_bucket_per_encounter is
  'COMBAT CARDINALITY (0240): one aggregate player bucket per (encounter, unit_type). Replaces 0023''s '
  'blanket unique (encounter_id, unit_type_id), which wrongly rejected the 2nd+ synthetic pirate of a '
  'spatial wave (all share unit_type_id=''pirate_synthetic'') and stalled multi-pirate waves at '
  'danger_level>=2. Scoped to side=''player'' AND main_ship_id IS NULL AND unit_type_id IS NOT NULL — '
  'the legacy aggregate class only. Member cardinality stays with combat_units_one_member_row_per_'
  'encounter (0167); enemy rows are intentionally unconstrained here.';

-- ── 3. self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ─────────
-- The disposable-DB apply-proof (`supabase start`) runs this against real Postgres: if the blanket
-- constraint ever survives, or the new partial index is absent / its predicate drifts, or either of the
-- two invariants this fix leans on (the XOR identity CHECK, the member partial index) goes missing, this
-- RAISES and the chain goes RED loudly. Catalog checks (this migration changes structure, not grants),
-- mirroring the 0233/0239 deploy-time self-assert idiom.
do $cardassert$
declare
  v_def text;
begin
  -- (a) the blanket constraint 0023 minted must be GONE.
  if exists (
    select 1 from pg_constraint
    where conname = 'combat_units_encounter_id_unit_type_id_key'
      and conrelid = 'public.combat_units'::regclass
  ) then
    raise exception 'COMBAT CARDINALITY self-assert FAIL: the blanket combat_units_encounter_id_unit_type_id_key constraint still exists — the multi-pirate stall is NOT fixed';
  end if;

  -- (b) the new partial unique index must exist with the EXACT aggregate predicate + columns.
  select pg_get_indexdef(c.oid) into v_def
  from pg_class c
  where c.relname = 'combat_units_one_aggregate_bucket_per_encounter'
    and c.relnamespace = 'public'::regnamespace
    and c.relkind = 'i';
  if v_def is null then
    raise exception 'COMBAT CARDINALITY self-assert FAIL: combat_units_one_aggregate_bucket_per_encounter is missing';
  end if;
  if v_def !~* 'UNIQUE INDEX' then
    raise exception 'COMBAT CARDINALITY self-assert FAIL: combat_units_one_aggregate_bucket_per_encounter is not UNIQUE (%)', v_def;
  end if;
  if v_def !~* '\(encounter_id, unit_type_id\)' then
    raise exception 'COMBAT CARDINALITY self-assert FAIL: aggregate index is not keyed on (encounter_id, unit_type_id) (%)', v_def;
  end if;
  if v_def !~* 'side = ''player'''
     or v_def !~* 'main_ship_id IS NULL'
     or v_def !~* 'unit_type_id IS NOT NULL' then
    raise exception 'COMBAT CARDINALITY self-assert FAIL: aggregate index predicate drifted from (side=player AND main_ship_id IS NULL AND unit_type_id IS NOT NULL) (%)', v_def;
  end if;

  -- (c) the XOR identity CHECK this fix's discriminator leans on must still exist.
  if not exists (
    select 1 from pg_constraint
    where conname = 'combat_units_exactly_one_identity'
      and conrelid = 'public.combat_units'::regclass
      and contype = 'c'
  ) then
    raise exception 'COMBAT CARDINALITY self-assert FAIL: combat_units_exactly_one_identity CHECK is missing — the aggregate discriminator is unsound';
  end if;

  -- (d) member cardinality must still be owned by its own partial index (this fix does NOT touch it).
  if not exists (
    select 1 from pg_class
    where relname = 'combat_units_one_member_row_per_encounter'
      and relnamespace = 'public'::regnamespace
      and relkind = 'i'
  ) then
    raise exception 'COMBAT CARDINALITY self-assert FAIL: combat_units_one_member_row_per_encounter index is missing — member cardinality is unguarded';
  end if;

  raise notice 'COMBAT CARDINALITY self-assert ok: blanket combat_units_encounter_id_unit_type_id_key dropped; combat_units_one_aggregate_bucket_per_encounter present with the exact aggregate predicate; combat_units_exactly_one_identity CHECK + combat_units_one_member_row_per_encounter index intact — multi-pirate spatial waves can now spawn N>=2 synthetic enemies';
end $cardassert$;
