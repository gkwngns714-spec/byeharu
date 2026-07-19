-- COMBAT-TICKS RESULT FIX — disposable apply-proof for migration 0241 (next_wave_incoming admitted).
--
-- Run ONLY against a THROWAWAY local Supabase (`supabase start` applies the FULL migration chain incl.
-- 0234 spatial tick + 0240 aggregate-bucket uniqueness + 0241 result-vocabulary widening) — NEVER
-- production. Self-rolling-back (begin;…rollback;, no COMMIT anywhere): ZERO persisted state, every dark
-- flag lit ONLY inside the txn.
--
-- ── WHAT THIS PROVES ─────────────────────────────────────────────────────────────────────────────
-- The latent defect (dormant behind combat_tick_logging=false in prod): process_combat_ticks' WAVE-PAUSE
-- branch (0234 spatial :682 + aggregate :975) logs a combat_ticks row with result='next_wave_incoming'
-- when v_log_ticks (=combat_tick_logging) is on — but 0014's combat_ticks_result_check permitted only
-- six literals, so that INSERT raised check_violation, was swallowed by the per-encounter cron guard
-- (0234:1134-1137 `when others → raise warning … left in-place`), and the encounter STALLED in the
-- pause. 0241 widens the CHECK to admit 'next_wave_incoming'.
--
-- This drives a REAL spatial encounter (sole-writer RPC/engine chain — reveal_starter_ports → commission
-- → reward_grant → craft_module → fit_module_to_ship → upsert_ship_group → assign_ship_to_group →
-- set_fleet_command_ship → send_ship_group_hunt → movement_settle_arrival → combat_create_group_encounter
-- → process_combat_ticks → …) ACROSS A WAVE PAUSE with combat_tick_logging ON, and asserts, in one txn:
--   NWINC_PASS_CONSTRAINT  (S) the applied chain carries 0241; combat_ticks_result_check admits all seven
--       literals incl. next_wave_incoming (the six legacy + the new one).
--   NWINC_PASS_CONTROL     (C) CONTROL EXPERIMENT (DDL-only, the sanctioned combat-proof idiom): with the
--       PRE-0241 six-value CHECK re-added, a LOGGED wave-pause tick STALLS — the check_violation is
--       swallowed by the cron guard, tick_number does NOT advance and NO next_wave_incoming row lands.
--       Dropping it and restoring the widened CHECK (0241 state) makes the SAME tick progress. This is
--       what makes the (P) assertion non-vacuous: it would FAIL under the pre-fix constraint.
--   NWINC_PASS_PAUSE_LOGS  (P) with the shipped (widened) CHECK and combat_tick_logging=true, the
--       wave-pause tick LANDS exactly one result='next_wave_incoming' combat_ticks row, NO check_violation
--       aborts/stalls the encounter, tick_number advances and last_resolved_at re-resolves to now() — the
--       encounter CONTINUES; the pause grants no reward, spawns no pirate (a pure pacing + log tick).
--
-- ── DETERMINISM MODEL (no RNG, no cron, no timing race) ──────────────────────────────────────────
-- combat_damage_variance_pct=0 collapses the engine variance roll to a constant 1.0; now() is frozen at
-- txn start; the ONLY clock lever is the sanctioned rewind of combat_encounters.{last_resolved_at,…} —
-- never a sleep, never a scheduled job. process_combat_ticks() is invoked MANUALLY. Pirates deal 0 damage
-- (players immortal) so the lifecycle never derails into an accidental defeat. Modeled on
-- scripts/multipirate-lifecycle-proof.sql + scripts/combat-spatial-proof.sql. group_sortie_members and
-- combat_units are NEVER hand-written — the real engine owns them (the sole-writer law); the only DDL is
-- the section-C control experiment's re-add/drop of the combat_ticks CHECK (never a row write).
--
-- NOTE (recorded honestly): this validates the runtime LOGIC of the wave-pause tick under controlled
-- MANUAL process_combat_ticks() invocation with clock-rewind — NOT live production cron cadence.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table nw(k text primary key, v uuid) on commit preserve rows;

-- ════════ HELPERS (pg_temp — infra, not owned combat state; verbatim from multipirate-lifecycle-proof) ═
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- tick ONE encounter: rewind ONLY its last_resolved_at (frozen-now isolation) then run the real cron
-- leaf. Rewinds combat_encounters only — never a combat_units row write.
create or replace function pg_temp.tick(p_enc uuid) returns integer language plpgsql as $$
declare n integer;
begin
  update public.combat_encounters set last_resolved_at = coalesce(last_resolved_at, now()) - interval '1 minute'
    where id = p_enc;
  n := public.process_combat_ticks();
  return n;
end $$;

-- send a team's hunt then settle its arrival through the REAL chain, returning the active encounter id.
-- group_sortie_members + combat_units are written ONLY by send_ship_group_hunt /
-- combat_create_group_encounter here.
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

-- provision a real team of p_total ships (first p_armed carrying one autocannon each) via 100% real RPC.
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

  -- retire each commission 'present' fleet + complete its orphaned presence (the send-readiness
  -- normalization every real first sender performs; verbatim from the sibling combat proofs).
  update public.main_ship_instances set status = 'home', updated_at = now() where main_ship_id = any(v_ships);
  update public.fleets set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null, updated_at = now()
   where main_ship_id = any(v_ships) and status = 'present';
  update public.location_presence set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets where main_ship_id = any(v_ships) and status = 'destroyed') and status = 'active';

  if p_armed > 0 then
    perform public.reward_grant('combat', gen_random_uuid(), p_sub, null,
      jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('item_id','weapon_parts','quantity', 8 * p_armed),
        jsonb_build_object('item_id','pirate_alloy','quantity', 4 * p_armed),
        jsonb_build_object('item_id','scrap','quantity', 12 * p_armed))));
    for i in 1 .. p_armed loop
      r := public.craft_module('nwinc-craft-'||replace(gen_random_uuid()::text,'-',''), 'autocannon_battery');
      if (r->>'ok')::boolean is not true then raise exception 'provision FAIL craft %: %', i, r; end if;
      v_mod := (r->>'instance_id')::uuid;
      r := public.fit_module_to_ship(v_mod, v_ships[i], 'nwinc-fit-'||replace(gen_random_uuid()::text,'-',''));
      if (r->>'ok')::boolean is not true then raise exception 'provision FAIL fit %: %', i, r; end if;
    end loop;
  end if;

  r := public.upsert_ship_group(1, 'NWInc');
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

-- ════════ SETUP: reveal ports; one funded fixture player (A) ═════════════════════════════════════════
do $setup$
declare uA uuid; r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL reveal_starter_ports: %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'nwincA.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into uA;
  insert into nw values ('uA', uA);
  insert into public.player_wallet (player_id, balance) values (uA, 1000000000)
    on conflict (player_id) do update set balance = excluded.balance;
  raise notice 'NWINC setup: player A=% funded; starter ports revealed', uA;
end $setup$;

-- dark capability gates — flipped ONLY inside this rolled-back txn (a fresh chain seeds every one false).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';

-- deterministic tuning (numeric knobs — all reverted by ROLLBACK). combat_tick_logging is ON for the
-- WHOLE proof — that is the point: the wave-pause tick must be LOGGED to exercise the next_wave_incoming
-- insert path. Pirates frozen (speed 0), long range (HOLD + fire in place), ZERO damage (players
-- immortal). enemy_hp_base is set below once the location's base_difficulty is known.
do $tune$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);   -- determinism (variance≡1)
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);       -- LOG the pause tick (the whole point)
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);
  perform public.set_game_config('enemy_hp_danger_scale', '0'::jsonb);        -- wave total hp independent of danger
  perform public.set_game_config('enemy_attack_base', '0'::jsonb);            -- pirates deal 0 dmg → players immortal
  perform public.set_game_config('enemy_attack_danger_scale', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);   -- pirates never move
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base', '500'::jsonb); -- >> ring → pirates HOLD & fire in place
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_max_units', '6'::jsonb);
  perform public.set_game_config('spatial_formation_ring_radius', '30'::jsonb);
  perform public.set_game_config('wave_transition_seconds', '3'::jsonb);      -- next_wave_at = now()+3s after a clear
end $tune$;

-- choose the hunt location, set enemy_hp_base so each wave's TOTAL hp = 120, provision team A (2 armed).
do $prov$
declare v_hunt uuid; v_bd double precision; gA uuid;
begin
  select id, greatest(base_difficulty,1) into v_hunt, v_bd from public.locations
    where activity_type='hunt_pirates' and status='active' order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'PROV FAIL: no active hunt_pirates location'; end if;
  insert into nw values ('v_hunt', v_hunt);
  perform public.set_game_config('enemy_hp_base', to_jsonb(120.0 / v_bd));   -- wave total = base_diff * (120/base_diff) = 120

  gA := pg_temp.provision_team((select v from nw where k='uA'), 2, 2);       -- 2 ships, both armed
  insert into nw values ('gA', gA);
  raise notice 'NWINC provision: hunt=% base_diff=% wave_total_hp=120; team gA (2 armed) formed', v_hunt, v_bd;
end $prov$;

-- ════════ SECTION S: the applied chain carries 0241; the CHECK admits all seven result literals ═══════
do $s$
declare v_0241 int; v_def text;
begin
  select count(*) into v_0241 from supabase_migrations.schema_migrations where version = '20260618000241';
  if v_0241 <> 1 then raise exception 'S FAIL: chain missing 0241 in schema_migrations (%)', v_0241; end if;

  select pg_get_constraintdef(c.oid) into v_def from pg_constraint c
    where c.conname='combat_ticks_result_check' and c.conrelid='public.combat_ticks'::regclass and c.contype='c';
  if v_def is null then raise exception 'S FAIL: combat_ticks_result_check missing'; end if;
  if v_def !~ 'next_wave_incoming' then raise exception 'S FAIL: CHECK does not admit next_wave_incoming (%)', v_def; end if;
  if v_def !~ 'ongoing' or v_def !~ 'wave_cleared' or v_def !~ 'retreat_started'
     or v_def !~ 'escaped' or v_def !~ 'defeat' or v_def !~ 'completed' then
    raise exception 'S FAIL: a legacy result literal is missing from the CHECK (%)', v_def; end if;

  raise notice 'NWINC_PASS_CONSTRAINT ok: chain carries 0241; combat_ticks_result_check admits all seven result literals incl. next_wave_incoming (def: %)', v_def;
end $s$;

-- ════════ THE LIFECYCLE: wave 1 → pause; control (pre-fix stall) → positive (fixed lands+continues) ═══
do $life$
declare
  uA uuid := (select v from nw where k='uA'); gA uuid := (select v from nw where k='gA');
  v_hunt uuid := (select v from nw where k='v_hunt'); v_enc uuid;
  wc int; tk int; tk0 int; guard int;
  n_nwinc int; n_nwinc0 int; n_enemy0 int; n_enemy int; wc0 int;
  rewards0 jsonb; rewards1 jsonb; lr timestamptz; v_res text; v_nwtk int;
begin
  v_enc := pg_temp.send_settle(uA, gA, v_hunt);
  insert into nw values ('encA', v_enc);
  raise notice 'NWINC lifecycle: encounter % active on team A', v_enc;

  -- ── drive WAVE 1 (danger 1 → 1 pirate) to completion. Only 'ongoing'/'wave_cleared' ticks land here
  --    (both legal under BOTH the six- and seven-value CHECK), so NO next_wave_incoming row exists yet. ─
  guard := 0;
  loop
    perform pg_temp.tick(v_enc);
    select waves_cleared into wc from public.combat_encounters where id = v_enc;
    exit when wc >= 1;
    guard := guard + 1; if guard > 60 then raise exception 'SETUP FAIL: wave 1 did not clear within 60 ticks'; end if;
  end loop;
  -- now in the wave pause: enemy side wiped, next_wave_at = now()+3s (future), zero next_wave_incoming rows.
  select count(*) into n_nwinc0 from public.combat_ticks where encounter_id = v_enc and result = 'next_wave_incoming';
  if n_nwinc0 <> 0 then raise exception 'SETUP FAIL: % next_wave_incoming rows already exist before the pause tick (want 0)', n_nwinc0; end if;
  if not exists (select 1 from public.combat_encounters where id=v_enc and next_wave_at is not null and now() < next_wave_at) then
    raise exception 'SETUP FAIL: encounter is not in a future-dated wave pause after clearing wave 1'; end if;
  select tick_number into tk0 from public.combat_encounters where id = v_enc;
  raise notice 'NWINC setup: wave 1 cleared (waves_cleared=%), tick_number=%, in wave pause with 0 next_wave_incoming rows', wc, tk0;

  -- ── SECTION C: CONTROL EXPERIMENT (DDL-only) — the PRE-0241 six-value CHECK re-added → the LOGGED
  --    pause tick STALLS. Safe to re-add here: no next_wave_incoming row exists yet, so the narrow CHECK
  --    validates cleanly. combat_tick_logging is ON. ───────────────────────────────────────────────────
  alter table public.combat_ticks drop constraint combat_ticks_result_check;
  alter table public.combat_ticks add constraint combat_ticks_result_check
    check (result = any (array['ongoing','wave_cleared','retreat_started','escaped','defeat','completed']));

  select tick_number into tk0 from public.combat_encounters where id = v_enc;
  perform pg_temp.tick(v_enc);   -- pause insert raises check_violation → cron guard swallows → stall
  select tick_number into tk from public.combat_encounters where id = v_enc;
  select count(*) into n_nwinc from public.combat_ticks where encounter_id = v_enc and result = 'next_wave_incoming';
  if tk <> tk0 then raise exception 'C FAIL: tick_number advanced (%->%) under the six-value CHECK — the stall did not occur (is the guard/CHECK as expected?)', tk0, tk; end if;
  if n_nwinc <> 0 then raise exception 'C FAIL: % next_wave_incoming row(s) landed under the six-value CHECK (want 0 — the insert must have been rejected+rolled back)', n_nwinc; end if;

  -- restore the 0241 (widened) CHECK — the shipped state.
  alter table public.combat_ticks drop constraint combat_ticks_result_check;
  alter table public.combat_ticks add constraint combat_ticks_result_check
    check (result = any (array['ongoing','wave_cleared','retreat_started','escaped','defeat','completed','next_wave_incoming']));
  raise notice 'NWINC_PASS_CONTROL ok: with the pre-0241 six-value combat_ticks_result_check re-added, the LOGGED wave-pause tick STALLED (tick_number frozen at %, 0 next_wave_incoming rows — check_violation swallowed by the per-encounter cron guard); the widened CHECK was then restored', tk0;

  -- ── SECTION P: with the SHIPPED (widened) CHECK + combat_tick_logging=true, the wave-pause tick LANDS
  --    a next_wave_incoming row and the encounter CONTINUES (no stall). This is the fix, proven live. ───
  select tick_number, waves_cleared, total_rewards_json into tk0, wc0, rewards0 from public.combat_encounters where id = v_enc;
  select count(*) into n_nwinc0 from public.combat_ticks where encounter_id = v_enc and result = 'next_wave_incoming';
  select count(*) into n_enemy0 from public.combat_units where encounter_id = v_enc and side = 'enemy';

  perform pg_temp.tick(v_enc);   -- next_wave_at NOT rewound → the engine takes the pause branch, now legal

  select tick_number, waves_cleared, total_rewards_json, last_resolved_at
    into tk, wc, rewards1, lr from public.combat_encounters where id = v_enc;
  select count(*) into n_nwinc from public.combat_ticks where encounter_id = v_enc and result = 'next_wave_incoming';
  select count(*) into n_enemy from public.combat_units where encounter_id = v_enc and side = 'enemy';

  -- (1) exactly one next_wave_incoming row now exists — the logged pause tick was ACCEPTED (no violation).
  if n_nwinc <> n_nwinc0 + 1 then raise exception 'P FAIL: next_wave_incoming rows %->% (want exactly one new logged pause tick — the CHECK still rejects it?)', n_nwinc0, n_nwinc; end if;
  -- (2) that row is a well-formed pause tick at the advanced tick_number.
  select result, tick_number into v_res, v_nwtk from public.combat_ticks
    where encounter_id = v_enc and result = 'next_wave_incoming' order by tick_number desc limit 1;
  if v_res is distinct from 'next_wave_incoming' then raise exception 'P FAIL: latest pause tick result=% (want next_wave_incoming)', v_res; end if;
  -- (3) the encounter CONTINUES: tick_number advanced and last_resolved_at re-resolved to now() (no stall).
  if tk <> tk0 + 1 then raise exception 'P FAIL: tick_number %->% (want +1 — the pause tick must pace, not stall)', tk0, tk; end if;
  if v_nwtk <> tk then raise exception 'P FAIL: pause tick row tick_number=% but encounter tick_number=%', v_nwtk, tk; end if;
  if lr is distinct from now() then raise exception 'P FAIL: last_resolved_at not refreshed to now() after the pause tick (left at % — a stall)', lr; end if;
  -- (4) the pause is a pure pacing+log no-op: no reward, no wave advance, no pirate spawn.
  if wc <> wc0 then raise exception 'P FAIL: waves_cleared changed across the pause tick (%->%)', wc0, wc; end if;
  if rewards1 is distinct from rewards0 then raise exception 'P FAIL: total_rewards_json changed across the pause tick'; end if;
  if n_enemy <> n_enemy0 then raise exception 'P FAIL: enemy row count changed across the pause tick (%->%) — a spawn', n_enemy0, n_enemy; end if;

  raise notice 'NWINC_PASS_PAUSE_LOGS ok: with combat_tick_logging=true and the shipped widened CHECK, the wave-pause tick LANDED one result=next_wave_incoming row (tick_number %->%), NO check_violation stalled the encounter (last_resolved_at re-resolved to now()), and the pause granted no reward/no wave/no spawn — the encounter CONTINUES', tk0, tk;
end $life$;

do $$ begin raise notice 'NEXT-WAVE-INCOMING FIX PROOF PASSED'; end $$;

-- rollback confirmation: everything above (5 dark flags flipped, ~14 config knobs, 1 user/wallet/team,
-- 1 encounter, every tick, the control experiment's CHECK re-add/drop, every combat_units/combat_events/
-- combat_ticks row) is inside this single transaction; the trailing ROLLBACK discards ALL of it — ZERO
-- persisted state, no COMMIT anywhere above, no production write, no migration, no prod flag change.
rollback;
