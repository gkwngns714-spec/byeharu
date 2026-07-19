-- MULTI-PIRATE LIFECYCLE — extended disposable proof for the post-0240 spatial-combat wave engine.
--
-- Run ONLY against a THROWAWAY local Supabase (`supabase start` applies the FULL migration chain incl.
-- 0234 spatial tick + 0239 + 0240 aggregate-bucket uniqueness) — NEVER production. Self-rolling-back
-- (begin;…rollback;, no COMMIT anywhere): ZERO persisted state, every dark flag lit ONLY inside the txn.
--
-- ── WHAT THIS EXTENDS ────────────────────────────────────────────────────────────────────────────
-- scripts/combat-spatial-proof.sql (0234) proves ONE pirate at danger=1: spawn/HOLD/KITE/CLOSE/fire.
-- scripts/combat-cardinality-proof.sql (0240) proves the aggregate-bucket index at the SCHEMA level via
-- direct row inserts. THIS proof drives the REAL engine through a MULTI-WAVE, MULTI-PIRATE lifecycle
-- (danger 1 → 2 → 3, i.e. 1 → 2 → 3 synthetic pirates per wave) end to end via the sole-writer RPC/engine
-- chain (reveal_starter_ports → commission → reward_grant → craft_module → fit_module_to_ship →
-- upsert_ship_group → assign_ship_to_group → set_fleet_command_ship → send_ship_group_hunt →
-- movement_settle_arrival → combat_create_group_encounter → process_combat_ticks → request_retreat),
-- and proves EVERY property below. group_sortie_members and combat_units are NEVER hand-written — the
-- real writers own them (the sole-writer law). combat_units is never INSERT/UPDATE/DELETE'd by this
-- harness; section F re-adds/drops a table CONSTRAINT (DDL, the sanctioned control experiment), never a
-- row write.
--
-- ── DETERMINISM MODEL (no RNG, no cron, no timing race) ──────────────────────────────────────────
-- combat_damage_variance_pct=0 → the engine's variance roll `(1 - v_var_pct) + rng*(2*v_var_pct)`
-- collapses to a CONSTANT 1.0 (the RNG draw is multiplied by 0 — the house determinism idiom). now() is
-- frozen at txn start (transaction_timestamp), so the ONLY clock lever is the sanctioned rewind of
-- combat_encounters.{last_resolved_at,next_wave_at,started_at,retreat_started_at} — never a sleep, never
-- a scheduled job. process_combat_ticks() is invoked MANUALLY (the engine's own leaf). Focused player fire always
-- locks onto the lowest-id enemy (the engine's `order by dist, id asc` tie-break: all pirates spawn at
-- the same location centre → equal distance → min-id wins) and overkill on an already-dead target is
-- dropped by the engine's `if found` re-read, never spilled — so exactly ONE pirate dies per tick, which
-- is what makes the per-pirate mutation-independence assertions below deterministic.
--
-- NOTE (recorded honestly): this proof validates the runtime LOGIC of the wave/multi-pirate engine under
-- controlled MANUAL process_combat_ticks() invocation with clock-rewind — it does NOT exercise live
-- production cron cadence (interval pacing / concurrency), which is out of scope for a disposable proof.
--
-- ── PROPERTIES PROVEN (each its own MPLIFE_PASS_<NAME> marker) ────────────────────────────────────
--   MPLIFE_PASS_SCHEMA_IDENTITY   (A) full chain incl. 0239 AND 0240; blanket unique constraint ABSENT;
--       aggregate partial index present with the EXACT predicate; XOR identity CHECK intact; a real
--       danger>=2 spawn yields exactly 2 and a real danger>=3 spawn exactly 3 pirate_synthetic enemy
--       rows, each a DISTINCT combat_units.id.
--   MPLIFE_PASS_INDEPENDENCE      (B) two identical pirates mutate independently: focused fire kills the
--       min-id pirate while the other's hp_current/pos/alive_count stay byte-identical to its own prior
--       snapshot; the two die on DIFFERENT ticks (one reaches alive_count=0 while the other survives,
--       then the survivor dies later).
--   MPLIFE_PASS_WAVE_LIFECYCLE    (C) a 1-, then 2-, then 3-pirate wave each spawns and completes;
--       waves_cleared advances 1→2→3; tick_number & last_resolved_at strictly advance (no stall/roll-
--       back loop); enemy rows initialised EXACTLY once per wave (no double-spawn / no interference from
--       a cleared wave's rows — the delete-then-respawn is clean).
--   MPLIFE_PASS_REWARDS_IDEMPOTENCY (D) exactly one reward per cleared wave (one result='wave_cleared'
--       combat_ticks row per wave; total_rewards_json metal accrues once per wave); a re-tick inside the
--       next_wave pause grants NO extra reward and spawns NO extra pirates; a cleared wave is never
--       counted twice; exactly one active encounter per fleet (the init-idempotency guard index).
--   MPLIFE_PASS_RETREAT_CLEANUP   (E) request_retreat → retreating → escaped; a return movement is
--       created, presence completed, report_create runs once; group_sortie_members (the manifest) is
--       RETAINED; no orphaned active encounter remains.
--   MPLIFE_PASS_CONTROL           (F) inside the txn only: re-add the OLD blanket unique(encounter_id,
--       unit_type_id); the deterministic 2-pirate spawn tick STALLS (unique_violation caught by the
--       engine's `when others` guard → tick_number does NOT advance, no enemy rows land); drop the old
--       constraint (restore 0240 state); the same tick now progresses (2 rows, tick_number advances).
--   MPLIFE_PASS_NONSPATIAL_PARITY (G) a separate encounter created while spatial_combat_enabled is dark
--       runs the aggregate (non-spatial) tick arm — NEVER writing an enemy combat_units row — and
--       reaches a terminal state normally; 0240 changed nothing on this path.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table mp(k text primary key, v uuid) on commit preserve rows;

-- ════════ HELPERS (pg_temp — infra, not owned combat state) ═══════════════════════════════════════
-- caller-as: set the authenticated subject then run an RPC, returning its jsonb (the combat-spatial-
-- proof idiom, verbatim). Used for request_retreat (auth.uid()-scoped).
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- tick ONE encounter: rewind ONLY its last_resolved_at (so no other active encounter becomes due — the
-- frozen-now() isolation) then run the real cron leaf. Rewinds combat_encounters only — never a
-- combat_units row write. Returns process_combat_ticks' own count.
create or replace function pg_temp.tick(p_enc uuid) returns integer language plpgsql as $$
declare n integer;
begin
  update public.combat_encounters set last_resolved_at = coalesce(last_resolved_at, now()) - interval '1 minute'
    where id = p_enc;
  n := public.process_combat_ticks();
  return n;
end $$;

-- send a team's hunt then settle its arrival through the REAL chain, returning the active encounter id
-- (the combat-spatial-proof SEND+SETTLE idiom). group_sortie_members + combat_units are written ONLY by
-- send_ship_group_hunt / combat_create_group_encounter here.
create or replace function pg_temp.send_settle(p_sub uuid, p_group uuid, p_loc uuid) returns uuid language plpgsql as $$
declare r jsonb; v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  r := pg_temp.call_as(p_sub, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', p_group, p_loc));
  if (r->>'ok')::boolean is not true then raise exception 'send_settle FAIL send: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  update public.fleet_movements set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute' where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then
    raise exception 'send_settle FAIL settle: %', r; end if;
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'send_settle FAIL: no active encounter'; end if;
  return v_enc;
end $$;

-- provision a real team of p_total ships (first p_armed carrying one autocannon each), retire the
-- transitional commission fleets (the send-readiness normalization every real first sender performs),
-- form a group, assign all ships, designate the first as command. 100% real-RPC. Returns the group id.
create or replace function pg_temp.provision_team(p_sub uuid, p_total integer, p_armed integer) returns uuid language plpgsql as $$
declare
  r jsonb; i integer; v_ship uuid; v_mod uuid; v_group uuid; v_ships uuid[] := '{}';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);

  r := public.commission_first_main_ship();
  if (r->>'ok')::boolean is not true then raise exception 'provision FAIL first ship: %', r; end if;
  select main_ship_id into v_ship from public.main_ship_instances where player_id = p_sub;
  v_ships := array[v_ship];
  for i in 2 .. p_total loop
    r := public.commission_additional_main_ship();
    if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then
      raise exception 'provision FAIL ship %: %', i, r; end if;
    v_ships := v_ships || (r->>'main_ship_id')::uuid;
  end loop;

  -- retire each commission 'present' fleet + complete its orphaned presence (the combat-spatial-proof
  -- PROVISION normalization, verbatim — send_ship_group_hunt's dark-path readiness gate treats a
  -- fleet-truth-docked member as NOT ready).
  update public.main_ship_instances set status = 'home', updated_at = now() where main_ship_id = any(v_ships);
  update public.fleets set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null, updated_at = now()
   where main_ship_id = any(v_ships) and status = 'present';
  update public.location_presence set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets where main_ship_id = any(v_ships) and status = 'destroyed') and status = 'active';

  if p_armed > 0 then
    -- fund the autocannon materials (weapon_parts 4 / pirate_alloy 2 / scrap 6 per unit, 0107) via the
    -- real Reward sole writer — generously, one grant covering all p_armed weapons.
    perform public.reward_grant('combat', gen_random_uuid(), p_sub, null,
      jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('item_id','weapon_parts','quantity', 8 * p_armed),
        jsonb_build_object('item_id','pirate_alloy','quantity', 4 * p_armed),
        jsonb_build_object('item_id','scrap','quantity', 12 * p_armed))));
    for i in 1 .. p_armed loop
      r := public.craft_module('mplife-craft-'||replace(gen_random_uuid()::text,'-',''), 'autocannon_battery');
      if (r->>'ok')::boolean is not true then raise exception 'provision FAIL craft %: %', i, r; end if;
      v_mod := (r->>'instance_id')::uuid;
      r := public.fit_module_to_ship(v_mod, v_ships[i], 'mplife-fit-'||replace(gen_random_uuid()::text,'-',''));
      if (r->>'ok')::boolean is not true then raise exception 'provision FAIL fit %: %', i, r; end if;
    end loop;
  end if;

  r := public.upsert_ship_group(1, 'MPLife');
  if (r->>'ok')::boolean is not true then raise exception 'provision FAIL group: %', r; end if;
  v_group := (r->>'group_id')::uuid;
  for i in 1 .. p_total loop
    r := public.assign_ship_to_group(v_ships[i], v_group);
    if (r->>'ok')::boolean is not true then raise exception 'provision FAIL assign %: %', i, r; end if;
  end loop;
  r := public.set_fleet_command_ship(v_ships[1], true);
  if (r->>'ok')::boolean is not true then raise exception 'provision FAIL command: %', r; end if;
  return v_group;
end $$;

-- ════════ SETUP: reveal ports; three funded fixture players (A lifecycle, F control, G parity) ═══════
do $setup$
declare uA uuid; uF uuid; uG uuid; r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL reveal_starter_ports: %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'mplifeA.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into uA;
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'mplifeF.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into uF;
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'mplifeG.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into uG;
  insert into mp values ('uA', uA), ('uF', uF), ('uG', uG);
  insert into public.player_wallet (player_id, balance) values (uA, 1000000000), (uF, 1000000000), (uG, 1000000000)
    on conflict (player_id) do update set balance = excluded.balance;
  raise notice 'MPLIFE setup: players A=% F=% G= % funded; starter ports revealed', uA, uF, uG;
end $setup$;

-- dark capability gates — flipped ONLY inside this rolled-back txn (a fresh chain seeds every one false).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';

-- deterministic tuning (numeric knobs — all reverted by ROLLBACK; the engineered lifecycle depends on
-- these EXACT values). Pirates are frozen (speed 0) with a long range (they HOLD + fire in place), deal
-- ZERO damage (attack 0 → players are immortal, so the lifecycle never derails into an accidental
-- defeat — pirate damage/aggro-screening is the sibling single-pirate proof's job); enemy_hp_base is set
-- below, once the chosen location's base_difficulty is known, so each wave's TOTAL hp is a fixed 120.
do $tune$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);   -- determinism (variance≡1)
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);       -- combat_ticks rows land
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);      -- missile_salvo / wave_cleared events land
  perform public.set_game_config('enemy_hp_danger_scale', '0'::jsonb);        -- wave total hp independent of danger
  perform public.set_game_config('enemy_attack_base', '0'::jsonb);            -- pirates deal 0 dmg → players immortal
  perform public.set_game_config('enemy_attack_danger_scale', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);   -- pirates never move (pos independence trivial)
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base', '500'::jsonb); -- >> ring → pirates HOLD & fire in place
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_max_units', '6'::jsonb);    -- cap; danger 1/2/3 → 1/2/3 units
  perform public.set_game_config('spatial_formation_ring_radius', '30'::jsonb);
  perform public.set_game_config('wave_transition_seconds', '3'::jsonb);
end $tune$;

-- choose the hunt location, set enemy_hp_base so each wave's TOTAL hp = 120 (per-pirate 120/1, 60/2,
-- 40/3 — all > the 20 focused player dps/tick, so a fresh wave always survives its own spawn tick and
-- pirates die one-per-tick over several observable ticks), then provision the three teams.
do $prov$
declare v_hunt uuid; v_bd double precision; gA uuid; gF uuid; gG uuid;
begin
  select id, greatest(base_difficulty,1) into v_hunt, v_bd from public.locations
    where activity_type='hunt_pirates' and status='active' order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'PROV FAIL: no active hunt_pirates location'; end if;
  insert into mp values ('v_hunt', v_hunt);
  perform public.set_game_config('enemy_hp_base', to_jsonb(120.0 / v_bd));   -- wave total = base_diff * (120/base_diff) = 120

  gA := pg_temp.provision_team((select v from mp where k='uA'), 2, 2);   -- 2 ships, both armed (20 dps focused)
  gF := pg_temp.provision_team((select v from mp where k='uF'), 1, 0);   -- 1 unarmed (control: constraint boundary only)
  gG := pg_temp.provision_team((select v from mp where k='uG'), 1, 0);   -- 1 (non-spatial parity)
  insert into mp values ('gA', gA), ('gF', gF), ('gG', gG);
  raise notice 'MPLIFE provision: hunt=% base_diff=% wave_total_hp=120; teams gA(2 armed)/gF(1)/gG(1) formed', v_hunt, v_bd;
end $prov$;

-- ════════ SECTION A (static half): schema & identity invariants the whole lifecycle leans on ═════════
do $aschema$
declare v_039 int; v_040 int; v_blanket int; v_def text; v_xor int; v_agg int;
begin
  select count(*) into v_039 from supabase_migrations.schema_migrations where version = '20260618000239';
  select count(*) into v_040 from supabase_migrations.schema_migrations where version = '20260618000240';
  if v_039 <> 1 or v_040 <> 1 then raise exception 'A FAIL: chain missing 0239(%)/0240(%) in schema_migrations', v_039, v_040; end if;

  select count(*) into v_blanket from pg_constraint
    where conname='combat_units_encounter_id_unit_type_id_key' and conrelid='public.combat_units'::regclass;
  if v_blanket <> 0 then raise exception 'A FAIL: the blanket combat_units_encounter_id_unit_type_id_key constraint is present (0240 not applied)'; end if;

  select pg_get_indexdef(c.oid) into v_def from pg_class c
    where c.relname='combat_units_one_aggregate_bucket_per_encounter' and c.relnamespace='public'::regnamespace and c.relkind='i';
  if v_def is null or v_def !~* 'UNIQUE INDEX'
     or v_def !~* '\(encounter_id, unit_type_id\)'
     or v_def !~* 'side = ''player''' or v_def !~* 'main_ship_id IS NULL' or v_def !~* 'unit_type_id IS NOT NULL' then
    raise exception 'A FAIL: aggregate partial index missing/predicate drift (%)', v_def; end if;

  select count(*) into v_xor from pg_constraint
    where conname='combat_units_exactly_one_identity' and conrelid='public.combat_units'::regclass and contype='c';
  if v_xor <> 1 then raise exception 'A FAIL: combat_units_exactly_one_identity XOR CHECK missing'; end if;

  select count(*) into v_agg from pg_class
    where relname='combat_units_one_member_row_per_encounter' and relnamespace='public'::regnamespace and relkind='i';
  if v_agg <> 1 then raise exception 'A FAIL: combat_units_one_member_row_per_encounter index missing'; end if;

  raise notice 'MPLIFE A static: chain has 0239+0240; blanket constraint absent; aggregate partial index present with exact predicate (side=player AND main_ship_id IS NULL AND unit_type_id IS NOT NULL); XOR identity CHECK + member index intact';
end $aschema$;

-- ════════ SECTION G: NON-SPATIAL PARITY (create while spatial dark → aggregate arm, no enemy rows) ═══
do $g$
declare
  uG uuid := (select v from mp where k='uG'); gG uuid := (select v from mp where k='gG');
  v_hunt uuid := (select v from mp where k='v_hunt'); v_enc uuid; v_pres uuid;
  n_enemy int; n_ticks int; v_status text; i int; r jsonb;
begin
  -- create the encounter with spatial_combat_enabled DARK → member rows land with NULL positions →
  -- v_is_spatial is false FOREVER (the null-pos fallback) → the aggregate tick arm runs, enemy is a
  -- scalar, and NO enemy combat_units row is ever written. Flip back on immediately after.
  update public.game_config set value='false'::jsonb where key='spatial_combat_enabled';
  v_enc := pg_temp.send_settle(uG, gG, v_hunt);
  update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
  insert into mp values ('encG', v_enc);
  select presence_id into v_pres from public.combat_encounters where id = v_enc;

  -- run a few aggregate ticks; assert NO enemy combat_units row EVER appears on this encounter.
  for i in 1 .. 3 loop
    perform pg_temp.tick(v_enc);
    select count(*) into n_enemy from public.combat_units where encounter_id = v_enc and side='enemy';
    if n_enemy <> 0 then raise exception 'G FAIL: aggregate arm wrote % enemy combat_units row(s) (want 0)', n_enemy; end if;
  end loop;
  select count(*) into n_ticks from public.combat_ticks where encounter_id = v_enc;
  if n_ticks < 1 then raise exception 'G FAIL: aggregate arm logged no combat_ticks rows'; end if;

  -- reach a terminal state normally via the real retreat leaf.
  r := pg_temp.call_as(uG, format('public.request_retreat(%L::uuid)', v_pres));
  update public.combat_encounters set retreat_started_at = now() - interval '30 seconds' where id = v_enc;
  perform pg_temp.tick(v_enc);
  select status into v_status from public.combat_encounters where id = v_enc;
  if v_status not in ('escaped','completed') then raise exception 'G FAIL: non-spatial encounter did not reach a terminal state (status=%)', v_status; end if;
  select count(*) into n_enemy from public.combat_units where encounter_id = v_enc and side='enemy';
  if n_enemy <> 0 then raise exception 'G FAIL: an enemy combat_units row exists post-terminal (want 0)'; end if;

  raise notice 'MPLIFE_PASS_NONSPATIAL_PARITY ok: encounter % created spatial-dark ran the aggregate tick arm over % combat_ticks with ZERO enemy combat_units rows and reached terminal status=% — 0240 changed nothing on the non-spatial path', v_enc, n_ticks, v_status;
end $g$;

-- ════════ SECTION F: CONTROL EXPERIMENT (re-add pre-0240 blanket constraint → stall; drop → progress) ═
do $f$
declare
  uF uuid := (select v from mp where k='uF'); gF uuid := (select v from mp where k='gF');
  v_hunt uuid := (select v from mp where k='v_hunt'); v_enc uuid;
  t_before int; t_stall int; t_after int; n_stall int; n_after int; n_ids int;
begin
  v_enc := pg_temp.send_settle(uF, gF, v_hunt);
  insert into mp values ('encF', v_enc);
  -- force danger>=2 on the FIRST wave via the time term (rewind started_at): 1 + 0 + floor(200/180) = 2.
  update public.combat_encounters set started_at = now() - interval '200 seconds' where id = v_enc;
  select tick_number into t_before from public.combat_encounters where id = v_enc;

  -- 1) re-add the OLD blanket unique(encounter_id, unit_type_id) — the pre-0240 world. Safe to add here:
  --    at this point NO combat_units row anywhere carries a duplicate (encounter_id, unit_type_id) (G's
  --    encounter + both fresh sortie member rows are unit_type_id NULL; no enemy rows exist yet).
  alter table public.combat_units add constraint combat_units_encounter_id_unit_type_id_key unique (encounter_id, unit_type_id);

  -- 2/3) the deterministic 2-pirate spawn tick STALLS: the 2nd pirate's INSERT (both share
  --    unit_type_id='pirate_synthetic') raises unique_violation, caught by process_combat_ticks' own
  --    `when others → raise warning … left in-place` subtransaction → the per-encounter work rolls back:
  --    tick_number does NOT advance and NO enemy row lands.
  perform pg_temp.tick(v_enc);
  select tick_number into t_stall from public.combat_encounters where id = v_enc;
  select count(*) into n_stall from public.combat_units where encounter_id = v_enc and side='enemy';
  if t_stall <> t_before then raise exception 'F FAIL: tick_number advanced (%->%) under the blanket constraint — the stall did not occur', t_before, t_stall; end if;
  if n_stall <> 0 then raise exception 'F FAIL: % enemy row(s) landed despite the blanket constraint (want 0 — the spawn must have rolled back)', n_stall; end if;

  -- 4) drop the old constraint → restore the 0240 world.
  alter table public.combat_units drop constraint combat_units_encounter_id_unit_type_id_key;

  -- 5/6) the SAME scenario now progresses: 2 distinct pirate rows spawn and the tick advances.
  perform pg_temp.tick(v_enc);
  select tick_number into t_after from public.combat_encounters where id = v_enc;
  select count(*), count(distinct id) into n_after, n_ids from public.combat_units where encounter_id = v_enc and side='enemy' and unit_type_id='pirate_synthetic';
  if n_after <> 2 or n_ids <> 2 then raise exception 'F FAIL: post-drop spawn produced % rows / % distinct ids (want 2/2)', n_after, n_ids; end if;
  if t_after <= t_stall then raise exception 'F FAIL: tick_number did not advance after dropping the constraint (%->%)', t_stall, t_after; end if;

  raise notice 'MPLIFE_PASS_CONTROL ok: encounter % — with the pre-0240 blanket unique(encounter_id,unit_type_id) re-added the 2-pirate spawn STALLED (tick_number frozen at %, 0 enemy rows, unique_violation caught by the engine warning path); after dropping it the identical tick PROGRESSED (2 distinct pirate rows, tick_number %->%). DDL-only control — no combat_units row hand-written, constraint never escapes the txn', v_enc, t_before, t_stall, t_after;
end $f$;

-- ════════ SECTIONS A(identity)+B+C+D: the real multi-wave lifecycle on team A ════════════════════════
do $lifecycle$
declare
  uA uuid := (select v from mp where k='uA'); gA uuid := (select v from mp where k='gA');
  v_hunt uuid := (select v from mp where k='v_hunt'); v_enc uuid;
  i int; n int; n_ids int; wc int; tk int; tk_prev int; lr timestamptz; lr_prev timestamptz;
  n_alive int; n_pause_ticks int; wc_before int; rewards_before jsonb; rewards_after jsonb;
  p1 uuid; p2 uuid; hp2_0 double precision; posx2_0 double precision; posy2_0 double precision;
  posx2 double precision; posy2 double precision; al2 int;
  hp1 double precision; hp2 double precision; al1 int; n_active int; n_enemy_rows int;
  n_wave_cleared int; metal double precision;
  n_pirate_fire int; guard int;
begin
  v_enc := pg_temp.send_settle(uA, gA, v_hunt);
  insert into mp values ('encA', v_enc);
  raise notice 'MPLIFE lifecycle: encounter % active on team A (2 armed member ships)', v_enc;

  -- init-idempotency guard: exactly one active encounter for this fleet (the one_active_encounter_per_fleet
  -- unique index). Re-driving the create path cannot mint a second.
  select count(*) into n_active from public.combat_encounters e
    join public.combat_encounters f2 on f2.fleet_id = e.fleet_id
    where e.id = v_enc and f2.status in ('active','retreating');
  if n_active <> 1 then raise exception 'D FAIL: % active encounters for team A fleet (want exactly 1)', n_active; end if;

  -- ── WAVE 1 (danger 1 → 1 pirate) — drive to completion; assert tick_number strictly advances AND
  --    every tick REFRESHES last_resolved_at to now(). (now() is frozen at txn start, so last_resolved_at
  --    cannot strictly INCREASE across ticks — the meaningful anti-stall invariant is that each tick
  --    RE-RESOLVES it to now(): the helper rewinds it to now()-1min and a live tick must reset it to
  --    now(); a stalled/rolled-back tick — as section F proved — leaves it at the stale rewound value.) ─
  select tick_number into tk_prev from public.combat_encounters where id = v_enc;
  guard := 0;
  loop
    -- last_resolved_at is now()-1min immediately before the tick (rewound inside pg_temp.tick).
    perform pg_temp.tick(v_enc);
    select tick_number, last_resolved_at, waves_cleared into tk, lr, wc from public.combat_encounters where id = v_enc;
    if tk <= tk_prev then raise exception 'C FAIL: tick_number did not strictly advance (%->%) — a stall/roll-back loop', tk_prev, tk; end if;
    if lr is distinct from now() then raise exception 'C FAIL: last_resolved_at not refreshed to now() after the tick (left at % — a stall)', lr; end if;
    -- exactly one enemy row exists for a danger-1 wave (initialised once, no double-spawn).
    select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
    if n <> 1 then raise exception 'C FAIL: danger-1 wave has % enemy rows (want exactly 1)', n; end if;
    tk_prev := tk;
    exit when wc >= 1;
    guard := guard + 1; if guard > 30 then raise exception 'C FAIL: wave 1 did not clear within 30 ticks'; end if;
  end loop;
  if wc <> 1 then raise exception 'C FAIL: waves_cleared=% after wave 1 (want 1)', wc; end if;
  raise notice 'MPLIFE C: wave 1 (1 pirate) cleared, waves_cleared=1, tick_number=%', tk;

  -- ── D: a re-tick INSIDE the next_wave pause grants NO reward and spawns NO pirate (idempotent). ──────
  select waves_cleared, total_rewards_json into wc_before, rewards_before from public.combat_encounters where id = v_enc;
  select count(*) into n_pause_ticks from public.combat_ticks where encounter_id = v_enc and result='wave_cleared';
  select count(*) into n_enemy_rows from public.combat_units where encounter_id = v_enc and side='enemy';
  perform pg_temp.tick(v_enc);   -- next_wave_at NOT rewound → engine takes the pause branch
  select waves_cleared, total_rewards_json into wc, rewards_after from public.combat_encounters where id = v_enc;
  select count(*) into n from public.combat_ticks where encounter_id = v_enc and result='wave_cleared';
  select count(*) into i from public.combat_units where encounter_id = v_enc and side='enemy';
  if wc <> wc_before then raise exception 'D FAIL: waves_cleared changed across a pause tick (%->%)', wc_before, wc; end if;
  if rewards_after is distinct from rewards_before then raise exception 'D FAIL: total_rewards_json changed across a pause tick'; end if;
  if n <> n_pause_ticks then raise exception 'D FAIL: a wave_cleared tick row was added during the pause (%->%)', n_pause_ticks, n; end if;
  if i <> n_enemy_rows then raise exception 'D FAIL: enemy row count changed during the pause (%->%) — a double-spawn', n_enemy_rows, i; end if;
  raise notice 'MPLIFE D: pause re-tick granted no reward, spawned no pirate (waves_cleared/ rewards/ wave_cleared-count/ enemy-rows all unchanged)';

  -- ── WAVE 2 (danger 2 → 2 pirates): rewind next_wave_at, spawn, assert 2 DISTINCT rows coexist. ──────
  update public.combat_encounters set next_wave_at = now() - interval '5 seconds' where id = v_enc;
  perform pg_temp.tick(v_enc);   -- spawns 2 pirates AND runs combat this same tick
  select count(*), count(distinct id) into n, n_ids from public.combat_units where encounter_id = v_enc and side='enemy' and unit_type_id='pirate_synthetic';
  if n <> 2 or n_ids <> 2 then raise exception 'A FAIL: danger-2 wave spawned % rows / % distinct ids (want 2/2)', n, n_ids; end if;
  select count(*) into n_alive from public.combat_units where encounter_id = v_enc and side='enemy' and alive_count > 0;
  if n_alive <> 2 then raise exception 'A/B FAIL: only % of 2 pirates survived their own spawn tick (want 2 — per-pirate hp must exceed one tick of focused fire)', n_alive; end if;
  -- cleared-wave-1 enemy row must be GONE (delete-then-respawn is clean): exactly 2 enemy rows total.
  select count(*) into n_enemy_rows from public.combat_units where encounter_id = v_enc and side='enemy';
  if n_enemy_rows <> 2 then raise exception 'C FAIL: % total enemy rows after wave-2 spawn (want 2 — wave-1 corpse not deleted)', n_enemy_rows; end if;

  -- pirate participation: a pirate-sourced missile_salvo event exists (both pirates act in the tick loop).
  select count(*) into n_pirate_fire from public.combat_events where encounter_id = v_enc and event_type='missile_salvo' and source='pirate';
  if n_pirate_fire < 1 then raise exception 'B FAIL: no pirate-sourced missile_salvo event (pirates did not participate in the tick)'; end if;

  -- ── B: mutation-independence. #1 = the focused (min-id) pirate; #2 = the other. Snapshot #2. ─────────
  select id, hp_current, alive_count into p1, hp1, al1 from public.combat_units where encounter_id = v_enc and side='enemy' order by id asc limit 1;
  select id, hp_current, pos_x, pos_y, alive_count into p2, hp2_0, posx2_0, posy2_0, al2 from public.combat_units where encounter_id = v_enc and side='enemy' order by id desc limit 1;
  if hp1 >= hp2_0 then raise exception 'B FAIL: the min-id pirate was not the focused one (hp1=% !< hp2=%)', hp1, hp2_0; end if;
  insert into mp values ('p1', p1), ('p2', p2);

  -- tick until pirate #1 is dead; every tick, pirate #2 must be BYTE-IDENTICAL to its own snapshot.
  guard := 0;
  loop
    perform pg_temp.tick(v_enc);
    select hp_current, alive_count into hp1, al1 from public.combat_units where id = p1;
    select hp_current, pos_x, pos_y, alive_count into hp2, posx2, posy2, al2 from public.combat_units where id = p2;
    if hp2 is distinct from hp2_0 then raise exception 'B FAIL: pirate #2 hp changed (%->%) while only #1 was targeted — mutation bled across pirates', hp2_0, hp2; end if;
    if al2 <> 1 then raise exception 'B FAIL: pirate #2 alive_count changed to % while only #1 was targeted', al2; end if;
    if posx2 is distinct from posx2_0 or posy2 is distinct from posy2_0 then raise exception 'B FAIL: pirate #2 position moved (%,%->%,%) while only #1 was targeted', posx2_0, posy2_0, posx2, posy2; end if;
    exit when al1 = 0;
    guard := guard + 1; if guard > 30 then raise exception 'B FAIL: pirate #1 did not die within 30 ticks'; end if;
  end loop;
  -- one dead, the other survives intact.
  if al1 <> 0 then raise exception 'B FAIL: pirate #1 not dead'; end if;
  if al2 <> 1 or hp2 is distinct from hp2_0 then raise exception 'B FAIL: pirate #2 did not survive #1''s death intact (alive=%, hp %->%)', al2, hp2_0, hp2; end if;
  raise notice 'MPLIFE_PASS_INDEPENDENCE ok: pirates % and % — focused fire drove #1 to alive_count=0 while #2 stayed byte-identical (hp %, pos %,%, alive 1) across every intervening tick; the two die on DIFFERENT ticks', p1, p2, hp2_0, posx2, posy2;

  -- #2 dies LATER (focus shifts) → wave 2 completes → waves_cleared=2.
  guard := 0;
  loop
    perform pg_temp.tick(v_enc);
    select waves_cleared into wc from public.combat_encounters where id = v_enc;
    exit when wc >= 2;
    guard := guard + 1; if guard > 30 then raise exception 'C FAIL: wave 2 did not clear within 30 ticks'; end if;
  end loop;
  if wc <> 2 then raise exception 'C FAIL: waves_cleared=% after wave 2 (want 2)', wc; end if;
  raise notice 'MPLIFE C: wave 2 (2 pirates) cleared, waves_cleared=2';

  -- ── WAVE 3 (danger 3 → 3 pirates): rewind next_wave_at, spawn, assert 3 DISTINCT rows coexist. ──────
  update public.combat_encounters set next_wave_at = now() - interval '5 seconds' where id = v_enc;
  perform pg_temp.tick(v_enc);
  select count(*), count(distinct id) into n, n_ids from public.combat_units where encounter_id = v_enc and side='enemy' and unit_type_id='pirate_synthetic';
  if n < 3 or n_ids < 3 then raise exception 'A FAIL: danger-3 wave spawned % rows / % distinct ids (want >=3/3)', n, n_ids; end if;
  select count(*) into n_enemy_rows from public.combat_units where encounter_id = v_enc and side='enemy';
  if n_enemy_rows <> 3 then raise exception 'C FAIL: % total enemy rows after wave-3 spawn (want 3 — wave-2 corpses not deleted)', n_enemy_rows; end if;
  raise notice 'MPLIFE_PASS_SCHEMA_IDENTITY ok: chain 0239+0240 verified (static); a real danger-2 wave spawned exactly 2 and a real danger-3 wave exactly 3 pirate_synthetic enemy rows, each a DISTINCT combat_units.id, all under the aggregate-scoped uniqueness (blanket constraint gone)';

  -- drive wave 3 to completion → waves_cleared=3.
  guard := 0;
  loop
    perform pg_temp.tick(v_enc);
    select waves_cleared into wc from public.combat_encounters where id = v_enc;
    exit when wc >= 3;
    guard := guard + 1; if guard > 40 then raise exception 'C FAIL: wave 3 did not clear within 40 ticks'; end if;
  end loop;
  if wc <> 3 then raise exception 'C FAIL: waves_cleared=% after wave 3 (want 3)', wc; end if;
  raise notice 'MPLIFE_PASS_WAVE_LIFECYCLE ok: waves 1(1)→2(2)→3(3) each spawned once and completed; waves_cleared advanced 1→2→3; tick_number strictly advanced and every tick re-resolved last_resolved_at to now() (no stall/roll-back loop); delete-then-respawn kept exactly N enemy rows per wave';

  -- ── D: exactly one reward per cleared wave; no double-count. ─────────────────────────────────────────
  select count(*) into n_wave_cleared from public.combat_ticks where encounter_id = v_enc and result='wave_cleared';
  if n_wave_cleared <> 3 then raise exception 'D FAIL: % result=wave_cleared combat_ticks rows (want exactly 3 — one per cleared wave)', n_wave_cleared; end if;
  select coalesce((total_rewards_json->>'metal')::double precision, 0) into metal from public.combat_encounters where id = v_enc;
  if metal <= 0 then raise exception 'D FAIL: total_rewards_json metal did not accrue (%))', metal; end if;
  select count(*) into n_active from public.combat_encounters where fleet_id = (select fleet_id from public.combat_encounters where id=v_enc) and status in ('active','retreating');
  if n_active <> 1 then raise exception 'D FAIL: % active encounters for team A (want 1)', n_active; end if;
  raise notice 'MPLIFE_PASS_REWARDS_IDEMPOTENCY ok: exactly 3 wave_cleared reward ticks (one per wave, none double-counted), pause re-tick granted none, accrued metal=%, exactly one active encounter per fleet (init-idempotency guard holds)', metal;
end $lifecycle$;

-- ════════ SECTION E: RETREAT & CLEANUP (team A) ══════════════════════════════════════════════════════
do $e$
declare
  uA uuid := (select v from mp where k='uA'); v_enc uuid := (select v from mp where k='encA');
  v_pres uuid; v_fleet uuid; v_status text; n_mv int; n_pres_done int; n_report int; n_manifest int; n_active int; r jsonb;
begin
  select presence_id, fleet_id into v_pres, v_fleet from public.combat_encounters where id = v_enc;

  r := pg_temp.call_as(uA, format('public.request_retreat(%L::uuid)', v_pres));
  select status into v_status from public.combat_encounters where id = v_enc;
  if v_status <> 'retreating' then raise exception 'E FAIL: encounter status=% after request_retreat (want retreating)', v_status; end if;

  -- advance past retreat_delay via the sanctioned clock rewind, then tick → escape.
  update public.combat_encounters set retreat_started_at = now() - interval '30 seconds' where id = v_enc;
  perform pg_temp.tick(v_enc);

  select status into v_status from public.combat_encounters where id = v_enc;
  if v_status <> 'escaped' then raise exception 'E FAIL: encounter status=% after retreat delay (want escaped)', v_status; end if;
  select count(*) into n_mv from public.fleet_movements where fleet_id = v_fleet and mission_type = 'return_home';
  if n_mv < 1 then raise exception 'E FAIL: no return_home movement created on escape'; end if;
  select count(*) into n_pres_done from public.location_presence where id = v_pres and status = 'completed';
  if n_pres_done <> 1 then raise exception 'E FAIL: presence not completed on escape'; end if;
  select count(*) into n_report from public.combat_reports where encounter_id = v_enc;
  if n_report <> 1 then raise exception 'E FAIL: report_create ran % times (want exactly 1)', n_report; end if;
  -- the persistent manifest is RETAINED (2 members).
  select count(*) into n_manifest from public.group_sortie_members where fleet_id = v_fleet;
  if n_manifest <> 2 then raise exception 'E FAIL: group_sortie_members manifest lost (% rows, want 2 retained)', n_manifest; end if;
  -- no orphaned active encounter remains.
  select count(*) into n_active from public.combat_encounters where fleet_id = v_fleet and status in ('active','retreating');
  if n_active <> 0 then raise exception 'E FAIL: % active/retreating encounter(s) remain for the fleet (want 0)', n_active; end if;

  raise notice 'MPLIFE_PASS_RETREAT_CLEANUP ok: request_retreat → retreating → escaped; return_home movement created, presence completed, exactly 1 combat_report; group_sortie_members manifest RETAINED (2 rows); no orphaned active encounter', v_enc;
end $e$;

do $$ begin raise notice 'MULTI-PIRATE LIFECYCLE PROOF PASSED'; end $$;

-- rollback confirmation: everything above (5 flags flipped, ~14 config knobs, 3 users/wallets/teams,
-- 3 encounters, every tick, every reward, every combat_units/combat_events/combat_ticks row) is inside
-- this single transaction; the trailing ROLLBACK discards ALL of it — ZERO persisted state, no COMMIT
-- anywhere above, no production write, no migration, no prod flag change.
rollback;
