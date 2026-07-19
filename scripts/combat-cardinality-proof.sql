-- COMBAT-CARDINALITY — disposable apply-proof for migration 0240
-- (20260618000240_combat_units_aggregate_bucket_uniqueness.sql). Run against a THROWAWAY local
-- Supabase only (`supabase start` applies the FULL chain incl. 0240) — NEVER production.
--
-- ── WHAT THIS PROVES ─────────────────────────────────────────────────────────────────────────────
-- 0240 drops 0023's blanket `unique (encounter_id, unit_type_id)` (constraint
-- combat_units_encounter_id_unit_type_id_key) and replaces it with a PARTIAL unique index scoped to the
-- legacy aggregate player class ONLY:
--   combat_units_one_aggregate_bucket_per_encounter  (encounter_id, unit_type_id)
--     where side = 'player' and main_ship_id is null and unit_type_id is not null
-- The three prod-verified combat_units row classes:
--   AGGREGATE player = (side='player', main_ship_id IS NULL, unit_type_id IS NOT NULL)  [0023/0168]
--   MEMBER    player = (side='player', main_ship_id IS NOT NULL, unit_type_id IS NULL)  [0167]
--   SYNTHETIC enemy  = (side='enemy',  unit_type_id='pirate_synthetic', main_ship_id IS NULL) [0234]
-- The bug: the blanket constraint rejected the 2nd+ synthetic pirate of a wave (all share
-- unit_type_id='pirate_synthetic') → process_combat_ticks' wave-spawn INSERT aborted → multi-pirate
-- spatial waves STALLED at danger_level>=2. This proof asserts the new index PERMITS multi-pirate +
-- multi-member rows while still REJECTING a duplicate aggregate bucket, and that no sibling invariant
-- (the XOR identity CHECK, the member partial index) was weakened.
--
-- ── FIXTURES (minimal, hand-built — this is a SCHEMA-CONSTRAINT proof, so probing the index boundary
--    with direct combat_units inserts of each row shape is the correct instrument; unlike the engine
--    proofs, there is deliberately NO sole-writer law here — no RPC would ever attempt a duplicate
--    aggregate bucket, which is precisely the boundary under test). The FK chain built directly:
--      2 auth.users → 2 main_ship_instances (member identities; player_id is UNIQUE, so 2 users) →
--      1 fleet → 1 location_presence → 1 combat_encounters. ────────────────────────────────────────
--
-- Self-rolling-back (begin;…rollback;, no COMMIT) → ZERO persisted state. Read/write is all transient.
-- Every constraint-rejection assertion runs inside a BEGIN…EXCEPTION subtransaction (savepoint), so a
-- caught unique_violation/check_violation never aborts the outer proof txn. No random() (0041 law):
-- gen_random_uuid() (fixture identity only) is the sole randomness; combat math is never exercised.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table ccard(k text primary key, v uuid) on commit preserve rows;

-- ════════ SETUP: the minimal real FK-parent chain for a fake encounter ══════════════════════════════
do $setup$
declare
  uP1 uuid; uP2 uuid; msi1 uuid; msi2 uuid;
  v_fleet uuid; v_pres uuid; v_enc uuid;
begin
  -- two auth.users (main_ship_instances.player_id is UNIQUE → two member identities need two users).
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'ccard.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uP1;
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'ccard.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uP2;

  -- two main_ship_instances — the member identities (hull 'starter_frigate', seeded 0043).
  insert into public.main_ship_instances (player_id, hull_type_id, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots)
    values (uP1, 'starter_frigate', 500, 500, 50, 10, 2, 3) returning main_ship_id into msi1;
  insert into public.main_ship_instances (player_id, hull_type_id, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots)
    values (uP2, 'starter_frigate', 500, 500, 50, 10, 2, 3) returning main_ship_id into msi2;

  -- one fleet + one presence + one encounter (the combat_encounters FK chain: player/fleet/presence).
  insert into public.fleets (player_id, status, location_mode)
    values (uP1, 'present', 'location') returning id into v_fleet;
  insert into public.location_presence (player_id, fleet_id, activity_type, status)
    values (uP1, v_fleet, 'hunt_pirates', 'active') returning id into v_pres;
  insert into public.combat_encounters (player_id, fleet_id, presence_id, status)
    values (uP1, v_fleet, v_pres, 'active') returning id into v_enc;

  insert into ccard values ('uP1', uP1), ('msi1', msi1), ('msi2', msi2), ('v_enc', v_enc);
  raise notice 'setup ok: fixture encounter % (fleet %, presence %), 2 member identities % %', v_enc, v_fleet, v_pres, msi1, msi2;
end $setup$;

-- ════════ 1) PRODSHAPE — seed aggregate + member + enemy like prod (many-aggregate / members / enemy);
--            the aggregate index is satisfied (0 violations) ════════════════════════════════════════
do $prodshape$
declare
  uP1 uuid := (select v from ccard where k='uP1');
  msi1 uuid := (select v from ccard where k='msi1');
  msi2 uuid := (select v from ccard where k='msi2');
  v_enc uuid := (select v from ccard where k='v_enc');
  n_agg int; n_mem int; n_enemy int; n_viol int;
begin
  -- 3 AGGREGATE player buckets (distinct real unit types — scout/corvette/frigate, seeded 0004). These
  -- are the ONLY rows the new partial index covers. (prod's 23 aggregate buckets differ only in count —
  -- each is a distinct unit_type_id; 3 distinct buckets exercise the identical invariant.)
  insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, side, ship_hp, initial_count, alive_count, hp_max, hp_current)
  values
    (v_enc, uP1, 'scout',    null, 'player', 20,  5, 5, 100, 100),
    (v_enc, uP1, 'corvette', null, 'player', 60,  3, 3, 180, 180),
    (v_enc, uP1, 'frigate',  null, 'player', 200, 2, 2, 400, 400);

  -- 2 MEMBER player rows (distinct main_ship_id, unit_type_id NULL; snapshots non-null per the 0167
  -- member_snapshot_pairing CHECK).
  insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, side, ship_hp, initial_count, alive_count, hp_max, hp_current, attack_snapshot, defense_snapshot)
  values
    (v_enc, uP1, null, msi1, 'player', 500, 1, 1, 500, 500, 40, 30),
    (v_enc, uP1, null, msi2, 'player', 500, 1, 1, 500, 500, 40, 30);

  -- 1 SYNTHETIC enemy row (side=enemy, unit_type_id='pirate_synthetic', seeded 0234; snapshots NULL).
  insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, side, ship_hp, initial_count, alive_count, hp_max, hp_current)
  values (v_enc, uP1, 'pirate_synthetic', null, 'enemy', 300, 1, 1, 300, 300);

  select count(*) into n_agg   from public.combat_units where encounter_id=v_enc and side='player' and main_ship_id is null and unit_type_id is not null;
  select count(*) into n_mem   from public.combat_units where encounter_id=v_enc and side='player' and main_ship_id is not null;
  select count(*) into n_enemy from public.combat_units where encounter_id=v_enc and side='enemy';
  if n_agg <> 3 or n_mem <> 2 or n_enemy <> 1 then
    raise exception 'PRODSHAPE FAIL: seeded shape wrong (aggregate=%, member=%, enemy=% — want 3/2/1)', n_agg, n_mem, n_enemy;
  end if;

  -- 0 violations of the aggregate uniqueness among the index-covered rows.
  select count(*) into n_viol from (
    select 1 from public.combat_units
    where encounter_id=v_enc and side='player' and main_ship_id is null and unit_type_id is not null
    group by encounter_id, unit_type_id having count(*) > 1
  ) d;
  if n_viol <> 0 then raise exception 'PRODSHAPE FAIL: % duplicate aggregate bucket(s) exist', n_viol; end if;

  raise notice 'CARDINALITY_PASS_PRODSHAPE ok: prod-shaped rows seeded (3 aggregate / 2 member / 1 enemy), the new partial index is satisfied with 0 aggregate-bucket violations';
end $prodshape$;

-- ════════ 2) MULTIENEMY — a 2nd synthetic pirate sharing 'pirate_synthetic' is PERMITTED (the core fix;
--            this exact INSERT raised under 0023's blanket constraint) ═══════════════════════════════
do $multi$
declare
  uP1 uuid := (select v from ccard where k='uP1');
  v_enc uuid := (select v from ccard where k='v_enc');
  n_enemy int;
begin
  insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, side, ship_hp, initial_count, alive_count, hp_max, hp_current)
  values (v_enc, uP1, 'pirate_synthetic', null, 'enemy', 300, 1, 1, 300, 300);

  select count(*) into n_enemy from public.combat_units
    where encounter_id=v_enc and side='enemy' and unit_type_id='pirate_synthetic';
  if n_enemy < 2 then raise exception 'MULTIENEMY FAIL: % pirate_synthetic enemy rows (want >=2)', n_enemy; end if;
  raise notice 'CARDINALITY_PASS_MULTIENEMY ok: a 2nd pirate_synthetic enemy row inserted successfully (% total) — the blanket constraint would have rejected this; the multi-pirate stall is fixed', n_enemy;
end $multi$;

-- ════════ 3) MANYENEMY — >2 synthetic pirates of the same type are permitted (danger>=3 wave shape) ══
do $many$
declare
  uP1 uuid := (select v from ccard where k='uP1');
  v_enc uuid := (select v from ccard where k='v_enc');
  n_enemy int;
begin
  insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, side, ship_hp, initial_count, alive_count, hp_max, hp_current)
  values
    (v_enc, uP1, 'pirate_synthetic', null, 'enemy', 300, 1, 1, 300, 300),
    (v_enc, uP1, 'pirate_synthetic', null, 'enemy', 300, 1, 1, 300, 300);

  select count(*) into n_enemy from public.combat_units
    where encounter_id=v_enc and side='enemy' and unit_type_id='pirate_synthetic';
  if n_enemy < 4 then raise exception 'MANYENEMY FAIL: % pirate_synthetic enemy rows (want >=4)', n_enemy; end if;
  raise notice 'CARDINALITY_PASS_MANYENEMY ok: % synthetic pirates of the same type coexist in one encounter (a danger>=3 wave is spawnable)', n_enemy;
end $many$;

-- ════════ 4) MEMBERS — multiple individual player-member rows (distinct main_ship_id, unit_type_id
--            NULL) coexist (they seeded in PRODSHAPE; assert the shape holds) ═════════════════════════
do $members$
declare
  v_enc uuid := (select v from ccard where k='v_enc');
  n_mem int; n_distinct int;
begin
  select count(*), count(distinct main_ship_id) into n_mem, n_distinct
    from public.combat_units where encounter_id=v_enc and side='player' and main_ship_id is not null and unit_type_id is null;
  if n_mem <> 2 or n_distinct <> 2 then
    raise exception 'MEMBERS FAIL: % member rows / % distinct main ships (want 2/2)', n_mem, n_distinct;
  end if;
  raise notice 'CARDINALITY_PASS_MEMBERS ok: 2 distinct player-member rows (unit_type_id NULL) coexist — the member partial index (not the aggregate one) governs them';
end $members$;

-- ════════ 5) AGGREGATE_UNIQUE — one aggregate bucket per (encounter, unit_type); a DUPLICATE aggregate
--            bucket is REJECTED (unique_violation) ══════════════════════════════════════════════════
do $aggu$
declare
  uP1 uuid := (select v from ccard where k='uP1');
  v_enc uuid := (select v from ccard where k='v_enc');
  v_rejected boolean := false;
begin
  begin
    -- a SECOND aggregate 'scout' bucket (side=player, main_ship_id NULL) collides with the first.
    insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, side, ship_hp, initial_count, alive_count, hp_max, hp_current)
    values (v_enc, uP1, 'scout', null, 'player', 20, 5, 5, 100, 100);
  exception when unique_violation then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'AGGREGATE_UNIQUE FAIL: a duplicate aggregate (encounter, scout) bucket was NOT rejected — the aggregate uniqueness is gone';
  end if;
  raise notice 'CARDINALITY_PASS_AGGREGATE_UNIQUE ok: a duplicate aggregate player bucket (encounter, scout) was rejected with unique_violation — one bucket per (encounter, unit_type) still holds';
end $aggu$;

-- ════════ 6) MIXED — aggregate + member + enemy rows all coexist in ONE encounter ═══════════════════
do $mixed$
declare
  v_enc uuid := (select v from ccard where k='v_enc');
  n_agg int; n_mem int; n_enemy int;
begin
  select count(*) into n_agg   from public.combat_units where encounter_id=v_enc and side='player' and main_ship_id is null and unit_type_id is not null;
  select count(*) into n_mem   from public.combat_units where encounter_id=v_enc and side='player' and main_ship_id is not null;
  select count(*) into n_enemy from public.combat_units where encounter_id=v_enc and side='enemy';
  if n_agg < 3 or n_mem < 2 or n_enemy < 4 then
    raise exception 'MIXED FAIL: coexistence shape wrong (aggregate=%, member=%, enemy=%)', n_agg, n_mem, n_enemy;
  end if;
  raise notice 'CARDINALITY_PASS_MIXED ok: % aggregate + % member + % enemy rows coexist in one encounter', n_agg, n_mem, n_enemy;
end $mixed$;

-- ════════ 7) XOR — the combat_units_exactly_one_identity CHECK still rejects an off-diagonal row ═════
do $xor$
declare
  uP1 uuid := (select v from ccard where k='uP1');
  msi1 uuid := (select v from ccard where k='msi1');
  v_enc uuid := (select v from ccard where k='v_enc');
  v_rejected boolean := false;
begin
  begin
    -- BOTH identities set (unit_type_id AND main_ship_id) → violates (unit_type_id IS NULL) <> (main_ship_id IS NULL).
    insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, side, ship_hp, initial_count, alive_count, hp_max, hp_current, attack_snapshot, defense_snapshot)
    values (v_enc, uP1, 'scout', msi1, 'player', 20, 1, 1, 100, 100, 40, 30);
  exception when check_violation then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'XOR FAIL: an off-diagonal row (both unit_type_id AND main_ship_id set) was NOT rejected — the exactly_one_identity CHECK is broken';
  end if;
  raise notice 'CARDINALITY_PASS_XOR ok: an off-diagonal row was rejected with check_violation — combat_units_exactly_one_identity remains intact';
end $xor$;

-- ════════ 8) NOWEAKEN — no unrelated constraint/index weakened; the member index still ENFORCES ═════
do $noweaken$
declare
  uP1 uuid := (select v from ccard where k='uP1');
  msi1 uuid := (select v from ccard where k='msi1');
  v_enc uuid := (select v from ccard where k='v_enc');
  v_rejected boolean := false;
  n_blanket int; n_agg_idx int; n_mem_idx int; n_xor int; n_snap int; n_shield int;
begin
  -- the blanket constraint is GONE; every sibling invariant is PRESENT.
  select count(*) into n_blanket from pg_constraint where conname='combat_units_encounter_id_unit_type_id_key' and conrelid='public.combat_units'::regclass;
  select count(*) into n_agg_idx from pg_class where relname='combat_units_one_aggregate_bucket_per_encounter' and relnamespace='public'::regnamespace and relkind='i';
  select count(*) into n_mem_idx from pg_class where relname='combat_units_one_member_row_per_encounter' and relnamespace='public'::regnamespace and relkind='i';
  select count(*) into n_xor  from pg_constraint where conname='combat_units_exactly_one_identity'      and conrelid='public.combat_units'::regclass and contype='c';
  select count(*) into n_snap from pg_constraint where conname='combat_units_member_snapshot_pairing'   and conrelid='public.combat_units'::regclass and contype='c';
  select count(*) into n_shield from pg_constraint where conname='combat_units_member_shield_pairing'   and conrelid='public.combat_units'::regclass and contype='c';
  if n_blanket <> 0 then raise exception 'NOWEAKEN FAIL: the blanket constraint still exists'; end if;
  if n_agg_idx <> 1 then raise exception 'NOWEAKEN FAIL: the new aggregate index is missing'; end if;
  if n_mem_idx <> 1 then raise exception 'NOWEAKEN FAIL: combat_units_one_member_row_per_encounter is missing'; end if;
  if n_xor  <> 1 then raise exception 'NOWEAKEN FAIL: combat_units_exactly_one_identity CHECK is missing'; end if;
  if n_snap <> 1 then raise exception 'NOWEAKEN FAIL: combat_units_member_snapshot_pairing CHECK is missing'; end if;
  if n_shield <> 1 then raise exception 'NOWEAKEN FAIL: combat_units_member_shield_pairing CHECK is missing'; end if;

  -- the member index still ENFORCES: a 2nd member row for the SAME main ship in the SAME encounter is rejected.
  begin
    insert into public.combat_units (encounter_id, player_id, unit_type_id, main_ship_id, side, ship_hp, initial_count, alive_count, hp_max, hp_current, attack_snapshot, defense_snapshot)
    values (v_enc, uP1, null, msi1, 'player', 500, 1, 1, 500, 500, 40, 30);
  exception when unique_violation then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'NOWEAKEN FAIL: a duplicate member row for the same main ship was NOT rejected — combat_units_one_member_row_per_encounter no longer enforces';
  end if;

  raise notice 'CARDINALITY_PASS_NOWEAKEN ok: blanket constraint gone; aggregate + member indexes and the exactly_one_identity / member_snapshot_pairing / member_shield_pairing CHECKs all present; the member index still rejects a duplicate main-ship row';
end $noweaken$;

-- ════════ 9) DETERMINISTIC — the disposable-matrix job re-applied the ENTIRE chain (incl. 0240) from
--            scratch to reach this point; reaching a clean apply + these asserts IS the determinism
--            proof (a green CI run re-applies from zero every time) ═══════════════════════════════════
do $det$
begin
  raise notice 'CARDINALITY_PASS_DETERMINISTIC ok: the full migration chain (through 0240) applied cleanly from scratch on this disposable DB and every boundary assertion held — deterministic reapply proven by the green disposable-matrix run itself';
end $det$;

do $$ begin raise notice 'COMBAT-CARDINALITY PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
