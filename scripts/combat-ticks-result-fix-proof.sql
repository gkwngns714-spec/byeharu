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
--       literals incl. next_wave_incoming (the six legacy + the new one). 0344 removes the WRITER, not
--       the vocabulary — rows written before that deploy still carry the literal — so (S) is untouched.
--   NWINC_PASS_NOPAUSE     (N) ██ 0344 REPLACES (C) AND (P), WHICH TESTED A BRANCH THAT IS NOW DELETED ██
--       (C) re-added the pre-0241 six-value CHECK and required the LOGGED wave-pause tick to STALL; (P)
--       required that same tick to LAND one result='next_wave_incoming' row and the encounter to
--       continue. Both are statements about `if e.next_wave_at is not null and now() < e.next_wave_at`,
--       which stood on BOTH arms of the tick and which 0344 DELETES: it paced a thing that no longer
--       happens, because enemy bodies now arrive on the site's own cadence rather than because a wave
--       was cleared. There is no arrangement of knobs or clocks that reaches a branch removed from the
--       source, so neither could be re-premised. (N) asserts what IS true — the deployed tick composes
--       combat_pressure_step and names neither next_wave_incoming nor next_wave_at — plus the one thing
--       (C)/(P) were really protecting: A FIGHT WITH AN EMPTY FIELD STILL PACES rather than stalling
--       (tick_number advances, last_resolved_at re-resolves to now()), grants no reward, moves no wave
--       counter, and is handed NO body for having been emptied.
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

  -- ── ARM BEFORE THE RETIREMENT BELOW (0333) ──────────────────────────────────────────────────
  -- Items live PER PORT now (`base_items`) and craft_module derives the port it spends from the
  -- crafting ship's VALIDATED DOCK. The retirement immediately below is exactly what stops a ship
  -- being 'at_location', so a craft after it would answer `not_docked`. Each craft therefore runs
  -- while the ships are still docked at Haven Reach and NAMES the ship it builds at — with p_total
  -- > 1 the sole-ship shim cannot resolve one and would answer `ship_not_found`. A NULL-base grant
  -- lands in the player's oldest active base (Home Base, location_id = Haven), which IS that store.
  if p_armed > 0 then
    perform public.reward_grant('combat', gen_random_uuid(), p_sub, null,
      jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('item_id','weapon_parts','quantity', 8 * p_armed),
        jsonb_build_object('item_id','pirate_alloy','quantity', 4 * p_armed),
        jsonb_build_object('item_id','scrap','quantity', 12 * p_armed))));
    for i in 1 .. p_armed loop
      r := public.craft_module('nwinc-craft-'||replace(gen_random_uuid()::text,'-',''), 'autocannon_battery', v_ships[i]);
      if (r->>'ok')::boolean is not true then raise exception 'provision FAIL craft %: %', i, r; end if;
      v_mod := (r->>'instance_id')::uuid;
      r := public.fit_module_to_ship(v_mod, v_ships[i], 'nwinc-fit-'||replace(gen_random_uuid()::text,'-',''));
      if (r->>'ok')::boolean is not true then raise exception 'provision FAIL fit %: %', i, r; end if;
    end loop;
  end if;

  -- retire each commission 'present' fleet + complete its orphaned presence (the send-readiness
  -- normalization every real first sender performs; verbatim from the sibling combat proofs).
  update public.main_ship_instances set status = 'home', updated_at = now() where main_ship_id = any(v_ships);
  update public.fleets set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null, updated_at = now()
   where main_ship_id = any(v_ships) and status = 'present';
  update public.location_presence set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets where main_ship_id = any(v_ships) and status = 'destroyed') and status = 'active';

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
-- 0300 lit combat_telegraph_enabled in the CHAIN, so a hunt arrival now QUEUES a telegraph instead
-- of opening combat inline — and this harness's send-then-settle staging found "no active
-- encounter" on every post-0300 chain (verified 2026-08-02: identical failure on main, no 0314).
-- This proof's subject is the TICK, not the telegraph — so it OWNS the inline-opening world the
-- danger-combat way: telegraph pinned dark in-txn (rolled back with everything else).
update public.game_config set value='false'::jsonb where key='combat_telegraph_enabled';

-- deterministic tuning (numeric knobs — all reverted by ROLLBACK). combat_tick_logging is ON for the
-- WHOLE proof — that is the point: the wave-pause tick must be LOGGED to exercise the next_wave_incoming
-- insert path. Pirates frozen (speed 0), long range (HOLD + fire in place), ZERO damage (players
-- immortal). enemy_hp_base is set below once the location's base_difficulty is known.
do $tune$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);   -- determinism (variance≡1)
  -- 0320 pins the SECOND spread knob too. The per-hit roll 0314 added reads
  --   coalesce(cfg_num('combat_hit_variance_pct'), v_var_pct)
  -- so it INHERITED the damage-variance pin above only while that key did not exist. 0320 seeds it
  -- (production runs it at 0.5), and the moment it exists the inheritance stops and every exact
  -- damage equality below becomes a +/-50% roll. A proof must state the precondition it owns
  -- rather than rely on a row's ABSENCE.
  perform public.set_game_config('combat_hit_variance_pct', '0'::jsonb);      -- determinism (0314 per-hit roll)
  -- 0314: the tick arms REAL weapon cooldowns and now() is txn-frozen — a positive cooldown means
  -- fire-once-per-proof, which would stall the wave-clear ticks below. This harness asserts the
  -- fire-every-tick world, so it OWNS that precondition in-txn, zeroed BEFORE anything snapshots a
  -- cooldown into weapons_json. The cooldown property itself is proven where it is owned:
  -- danger-combat-proof's RSFEEL block.
  perform public.set_game_config('enemy_synthetic_cooldown_seconds', '0'::jsonb);
  perform public.set_game_config('combat_player_fallback_weapon_cooldown_seconds', '0'::jsonb);
  update public.module_types set cooldown_seconds = 0 where cooldown_seconds is not null and cooldown_seconds > 0;
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);       -- every tick is LOGGED (the whole point)
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);
  -- ██ (0344) FIVE WRITES WERE DELETED FROM THIS BLOCK, AND THEY ARE THE DANGEROUS KIND ██
  -- enemy_hp_danger_scale=0, enemy_attack_danger_scale=0, enemy_synthetic_max_units=6 and
  -- wave_transition_seconds=3 each ESTABLISHED A PRECONDITION this file depended on: hp independent of
  -- danger, attack independent of danger, a known unit ceiling, and a 3-second wave-transition window.
  -- 0344 DELETES all four rows (and the pause the last one paced). A write to a key nothing reads does
  -- NOT error — it re-inserts a row and moves on — so every one of them would have gone on looking like
  -- staging while establishing NOTHING, and the file would have stayed green over preconditions it no
  -- longer set. They are removed rather than repointed because the properties they bought are now
  -- STRUCTURAL: an enemy body's hp and attack are locations.base_difficulty x their knob with no danger
  -- factor anywhere, and the field size is public.location_pressure.concurrent_cap.
  perform public.set_game_config('enemy_attack_base', '0'::jsonb);            -- pirates deal 0 dmg → players immortal
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);   -- pirates never move
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base', '500'::jsonb); -- >> ring → pirates HOLD & fire in place
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('spatial_formation_ring_radius', '30'::jsonb);
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

-- ════════ SECTION N (0344): THE PAUSE THIS PROOF WAS BUILT ON IS DELETED, AND THAT IS THE ASSERT ══════
-- ██ TWO BLOCKS WERE DELETED HERE, AND THE PROPERTY EACH TESTED NO LONGER EXISTS ██
--   NWINC_PASS_CONTROL   — re-added the pre-0241 six-value CHECK and required the LOGGED wave-pause
--                          tick to STALL, so that the positive assert below could not pass vacuously.
--   NWINC_PASS_PAUSE_LOGS— required the wave-pause tick to LAND exactly one result='next_wave_incoming'
--                          combat_ticks row and the encounter to continue.
-- Both are statements about `if e.next_wave_at is not null and now() < e.next_wave_at then <log a
-- next_wave_incoming tick and skip the combat step>`, which existed on BOTH arms of the tick and which
-- migration 0344 DELETES: it paced a thing that no longer happens. Enemy bodies now arrive from
-- public.combat_pressure_step on the site's own cadence, so clearing a field does not schedule the next
-- wave and there is no window to pause in. Neither block could be re-premised: there is no arrangement
-- of knobs or clocks under which the deployed tick reaches a branch that was removed from its source.
-- THEY ARE NOT REPLACED BY A WEAKER FORM — they are replaced by the assertion that the branch is gone,
-- which is the property this slice actually establishes, plus the ONE thing the deleted blocks were
-- really protecting: A FIGHT WITH AN EMPTY FIELD MUST STILL PACE RATHER THAN STALL. That was the real
-- damage of the 0241 defect (an encounter frozen forever by a swallowed check_violation), and it is
-- still reachable — it is simply reached by clearing the field and ticking again.
-- SECTION S above is UNTOUCHED and still meaningful: the CHECK must keep admitting the literal, because
-- 0344 removes the writer, not the vocabulary, and combat_ticks rows written before this deploy carry it.
do $life$
declare
  uA uuid := (select v from nw where k='uA'); gA uuid := (select v from nw where k='gA');
  v_hunt uuid := (select v from nw where k='v_hunt'); v_enc uuid;
  wc int; tk int; tk0 int; guard int;
  n_nwinc int; n_enemy0 int; n_enemy int; wc0 int;
  rewards0 jsonb; rewards1 jsonb; lr timestamptz;
  v_code text; v_live int;
begin
  -- ── (N1) THE BRANCH IS GONE FROM THE DEPLOYED TICK, read off its own source with comments stripped
  --    (the 0222 vacuity trap, in reverse: this file's own prose names the very string being asserted
  --    absent). Non-vacuity first — the probe must be able to find something.
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_code is null or length(v_code) < 40000 then
    raise exception 'N FAIL: the comment-stripped tick body is % chars — every absence assert below would be measured against nothing', coalesce(length(v_code), -1);
  end if;
  if position('combat_pressure_step' in v_code) = 0 then
    raise exception 'N FAIL: the deployed tick does not compose combat_pressure_step — this chain has not been through 0344, so asserting that the wave pause is gone would be asserting something no migration has done yet';
  end if;
  if position('next_wave_incoming' in v_code) > 0 then
    raise exception 'N FAIL: the deployed tick still writes a next_wave_incoming result — 0344 deletes the wave pause on BOTH arms, and a surviving writer means the pause (and therefore the wave-clear scheduling it paced) is still there';
  end if;
  if position('next_wave_at' in v_code) > 0 then
    raise exception 'N FAIL: the deployed tick still reads or writes next_wave_at — the column stays on the table, but nothing in the engine may consult it once pressure is a clock';
  end if;

  -- ── (N2) AND THE FIGHT STILL PACES WITH AN EMPTY FIELD. This is what the deleted blocks were really
  --    protecting: the 0241 defect froze an encounter forever because a swallowed check_violation rolled
  --    the whole tick back. Clear the field, tick again, and require the clock to move.
  v_enc := pg_temp.send_settle(uA, gA, v_hunt);
  insert into nw values ('encA', v_enc);
  raise notice 'NWINC lifecycle: encounter % active on team A', v_enc;
  guard := 0;
  loop
    perform pg_temp.tick(v_enc);
    select waves_cleared into wc from public.combat_encounters where id = v_enc;
    exit when wc >= 1;
    guard := guard + 1; if guard > 60 then raise exception 'SETUP FAIL: the field was not broken within 60 ticks'; end if;
  end loop;
  select count(*) into v_live from public.combat_units
   where encounter_id = v_enc and side = 'enemy' and alive_count > 0;
  if v_live <> 0 then
    raise exception 'SETUP FAIL: % living enemy bod(ies) remain after the clear (want 0) — the empty-field tick below would not be an empty-field tick', v_live;
  end if;
  select tick_number, waves_cleared, total_rewards_json into tk0, wc0, rewards0
    from public.combat_encounters where id = v_enc;
  select count(*) into n_enemy0 from public.combat_units where encounter_id = v_enc and side = 'enemy';

  perform pg_temp.tick(v_enc);

  select tick_number, waves_cleared, total_rewards_json, last_resolved_at
    into tk, wc, rewards1, lr from public.combat_encounters where id = v_enc;
  select count(*) into n_nwinc from public.combat_ticks where encounter_id = v_enc and result = 'next_wave_incoming';
  select count(*) into n_enemy from public.combat_units where encounter_id = v_enc and side = 'enemy';

  if n_nwinc <> 0 then
    raise exception 'N FAIL: % next_wave_incoming row(s) were logged across this fight (want 0) — the deleted pause branch is being reached by some path, and (N1) missed it', n_nwinc;
  end if;
  if tk <> tk0 + 1 then
    raise exception 'N FAIL: tick_number %->% across the empty-field tick (want +1) — the encounter STALLED, which is the 0241 damage recurring by a different route', tk0, tk;
  end if;
  if lr is distinct from now() then
    raise exception 'N FAIL: last_resolved_at was not refreshed to now() after the empty-field tick (left at %) — the tick rolled back rather than paced', lr;
  end if;
  if wc <> wc0 then
    raise exception 'N FAIL: waves_cleared changed %->% on a tick with nothing alive to break — an empty field satisfies "enemy hp <= 0" on EVERY tick, and without 0344''s v_e_before > 0 conjunct the counter runs forever', wc0, wc;
  end if;
  if rewards1 is distinct from rewards0 then
    raise exception 'N FAIL: total_rewards_json changed on a tick with no kill in it — the empty field is being paid for, every three seconds, forever';
  end if;
  if n_enemy <> n_enemy0 then
    raise exception 'N FAIL: the enemy row count changed %->% on the tick after the field was broken — a body arrived because the field was empty, which is the kill-driven arrow 0344 deletes', n_enemy0, n_enemy;
  end if;

  raise notice 'NWINC_PASS_NOPAUSE ok: the deployed tick composes combat_pressure_step and names neither next_wave_incoming nor next_wave_at (0344 deletes the wave pause on both arms, so the CONTROL and PAUSE_LOGS blocks that stood here tested a branch that no longer exists) — and the fight the pause used to hold still PACES with an empty field: tick_number %->%, last_resolved_at re-resolved to now(), no pause row, no reward, no wave counter movement and no body arriving because the field was empty', tk0, tk;
end $life$;

do $$ begin raise notice 'NEXT-WAVE-INCOMING FIX PROOF PASSED'; end $$;

-- rollback confirmation: everything above (5 dark flags flipped, ~14 config knobs, 1 user/wallet/team,
-- 1 encounter, every tick, the control experiment's CHECK re-add/drop, every combat_units/combat_events/
-- combat_ticks row) is inside this single transaction; the trailing ROLLBACK discards ALL of it — ZERO
-- persisted state, no COMMIT anywhere above, no production write, no migration, no prod flag change.
rollback;
