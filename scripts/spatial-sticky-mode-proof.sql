-- STICKY SPATIAL MODE — disposable proof for migration 0242 (fix mid-fight de-spatialization).
--
-- Run ONLY against a THROWAWAY local Supabase (`supabase start` applies the FULL migration chain incl.
-- 0234 spatial tick + 0242 sticky-mode fix) — NEVER production. Self-rolling-back (begin;…rollback;, no
-- COMMIT anywhere): ZERO persisted state; spatial_combat_enabled is toggled ONLY inside the txn and the
-- trailing ROLLBACK restores the committed dark value.
--
-- ── WHAT THIS PROVES (each its own SSPASS marker) ────────────────────────────────────────────────────
-- The 0242 fix makes an encounter's spatial-vs-aggregate mode STICKY: decided ONCE at creation (from the
-- flag, via the persisted presence of positioned combat_units rows) and immutable through the lifecycle.
-- process_combat_ticks NEVER re-reads spatial_combat_enabled; it derives the mode from
-- `exists(combat_units.pos_x is not null)`. Four scenarios, four distinct PASS markers:
--   1. SSPASS_1_SPATIAL_STAYS_SPATIAL_AFTER_DARK — a spatial encounter, once created, keeps running the
--      spatial arm even after the global flag is darkened mid-fight: enemy combat_units rows are still
--      spawned/managed, side='enemy' rows are NOT folded into the player aggregate (player_integrity_current
--      stays == sum of side='player' hp), a fresh wave spawns AFTER the darken, rewards accrue, and
--      retreat→escape→cleanup all work.
--   2. SSPASS_2_AGGREGATE_STAYS_AGGREGATE_AFTER_ENABLE — an encounter created while the flag is dark stays
--      aggregate even after the flag is ENABLED mid-fight: no pos_x ever appears, no enemy combat_units row
--      is ever written, and it reaches a terminal state normally (enabling never retro-spatializes).
--   3. SSPASS_3_NEW_ENCOUNTER_AFTER_DARK — a spatial encounter created while lit stays spatial after the
--      flag is darkened; a NEW encounter created AFTER the darken is non-spatial. Darkening blocks only NEW
--      spatial encounters, never the in-flight one.
--   4. SSPASS_4_SAFE_EMERGENCY_DARKENING — darkening during an active spatial encounter: blocks NEW spatial
--      creation, does NOT switch the active encounter's mode, does NOT stall (tick_number strictly advances,
--      last_resolved_at re-resolves to now()), grants no duplicate rewards (exactly one wave_cleared reward
--      tick per cleared wave), corrupts no enemy/player rows (player row count unchanged; player_integrity
--      uncorrupted), and retreat+cleanup stay intact.
--
-- ── DETERMINISM MODEL (no RNG, no cron, no timing race) ──────────────────────────────────────────────
-- combat_damage_variance_pct=0 → the engine's variance roll collapses to a CONSTANT 1.0. now() is frozen
-- at txn start; the ONLY clock lever is the sanctioned rewind of combat_encounters timestamps. Pirates are
-- frozen (speed 0) with a long range (they HOLD + fire in place) and deal ZERO damage (attack 0 → players
-- immortal, so a scenario never derails into an accidental defeat). Player fire locks onto the lowest-id
-- enemy (the engine's `order by dist,id` tie-break: all pirates spawn at the same location centre).
-- group_sortie_members and combat_units are NEVER hand-written — the real engine writers own them (the
-- sole-writer law); this harness only rewinds combat_encounters timestamps and toggles config.
--
-- NOTE (recorded honestly): this validates the runtime LOGIC of the sticky-mode decision under controlled
-- MANUAL process_combat_ticks() invocation with clock-rewind — it does NOT exercise live production cron
-- cadence (interval pacing / concurrency), which is out of scope for a disposable proof.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table ss(k text primary key, v uuid) on commit preserve rows;

-- ════════ HELPERS (pg_temp — infra, not owned combat state; verbatim from multipirate-lifecycle-proof) ═
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- tick ONE encounter: rewind ONLY its last_resolved_at (frozen-now() isolation → no other active encounter
-- becomes due) then run the real cron leaf. Rewinds combat_encounters only — never a combat_units row write.
create or replace function pg_temp.tick(p_enc uuid) returns integer language plpgsql as $$
declare n integer;
begin
  update public.combat_encounters set last_resolved_at = coalesce(last_resolved_at, now()) - interval '1 minute'
    where id = p_enc;
  n := public.process_combat_ticks();
  return n;
end $$;

-- send a team's hunt then settle its arrival through the REAL chain, returning the active encounter id.
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
-- transitional commission fleets, form a group, assign all ships, designate the first as command. 100%
-- real-RPC. Returns the group id. (Verbatim from multipirate-lifecycle-proof.)
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
      r := public.craft_module('sstick-craft-'||replace(gen_random_uuid()::text,'-',''), 'autocannon_battery');
      if (r->>'ok')::boolean is not true then raise exception 'provision FAIL craft %: %', i, r; end if;
      v_mod := (r->>'instance_id')::uuid;
      r := public.fit_module_to_ship(v_mod, v_ships[i], 'sstick-fit-'||replace(gen_random_uuid()::text,'-',''));
      if (r->>'ok')::boolean is not true then raise exception 'provision FAIL fit %: %', i, r; end if;
    end loop;
  end if;

  r := public.upsert_ship_group(1, 'SSTick');
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

-- ════════ SETUP: reveal ports; six funded fixture players ════════════════════════════════════════════
do $setup$
declare uid uuid; k text; r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL reveal_starter_ports: %', r; end if;
  foreach k in array array['uS1','uS2','uS3a','uS3b','uS4','uS4b'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'sstick.'||k||'.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into uid;
    insert into ss values (k, uid);
    insert into public.player_wallet (player_id, balance) values (uid, 1000000000)
      on conflict (player_id) do update set balance = excluded.balance;
  end loop;
  raise notice 'SSTICK setup: 6 players funded; starter ports revealed';
end $setup$;

-- capability gates the real send/craft/fit chain needs — flipped ONLY inside this rolled-back txn.
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';

-- deterministic tuning (all reverted by ROLLBACK).
do $tune$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);   -- determinism (variance≡1)
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);       -- combat_ticks rows land
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);      -- missile_salvo / wave_cleared events land
  perform public.set_game_config('enemy_hp_danger_scale', '0'::jsonb);        -- wave total hp independent of danger
  perform public.set_game_config('enemy_attack_base', '0'::jsonb);            -- pirates deal 0 dmg → players immortal
  perform public.set_game_config('enemy_attack_danger_scale', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);   -- pirates never move
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base', '500'::jsonb); -- >> ring → pirates HOLD & fire in place
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_max_units', '6'::jsonb);
  perform public.set_game_config('spatial_formation_ring_radius', '30'::jsonb);
  perform public.set_game_config('wave_transition_seconds', '3'::jsonb);
end $tune$;

-- choose the hunt location; set enemy_hp_base so each wave's TOTAL hp = 60 (per-pirate 60/danger — always
-- > the ≤20 focused player dps/tick, so a fresh wave survives its own spawn tick and is observable), then
-- provision the six teams.
do $prov$
declare v_hunt uuid; v_bd double precision;
begin
  select id, greatest(base_difficulty,1) into v_hunt, v_bd from public.locations
    where activity_type='hunt_pirates' and status='active' order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'PROV FAIL: no active hunt_pirates location'; end if;
  insert into ss values ('v_hunt', v_hunt);
  perform public.set_game_config('enemy_hp_base', to_jsonb(60.0 / v_bd));   -- wave total = base_diff * (60/base_diff) = 60

  insert into ss values
    ('gS1',  pg_temp.provision_team((select v from ss where k='uS1'),  2, 2)),   -- armed: full lifecycle
    ('gS2',  pg_temp.provision_team((select v from ss where k='uS2'),  1, 0)),   -- aggregate-stays
    ('gS3a', pg_temp.provision_team((select v from ss where k='uS3a'), 1, 0)),   -- spatial-stays (integrity check)
    ('gS3b', pg_temp.provision_team((select v from ss where k='uS3b'), 1, 0)),   -- created-after-dark
    ('gS4',  pg_temp.provision_team((select v from ss where k='uS4'),  2, 2)),   -- armed: emergency-darken
    ('gS4b', pg_temp.provision_team((select v from ss where k='uS4b'), 1, 0));   -- dark probe
  raise notice 'SSTICK provision: hunt=% base_diff=% wave_total_hp=60; six teams formed', v_hunt, v_bd;
end $prov$;

-- ════════ SCENARIO 1: SPATIAL STAYS SPATIAL AFTER DARK ═══════════════════════════════════════════════
do $s1$
declare
  uS1 uuid := (select v from ss where k='uS1'); gS1 uuid := (select v from ss where k='gS1');
  v_hunt uuid := (select v from ss where k='v_hunt'); v_enc uuid; v_pres uuid;
  n_enemy int; n_pos int; v_pic double precision; v_psum double precision; wc int; wc0 int;
  tk int; tk_prev int; lr timestamptz; guard int; n_reward int; v_status text; r jsonb;
begin
  -- CREATE WHILE LIT → positioned player rows → spatial.
  update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
  v_enc := pg_temp.send_settle(uS1, gS1, v_hunt);
  insert into ss values ('encS1', v_enc);
  select presence_id into v_pres from public.combat_encounters where id = v_enc;

  -- first spatial tick: wave 1 enemy rows spawn; player rows carry positions.
  perform pg_temp.tick(v_enc);
  select count(*) into n_enemy from public.combat_units where encounter_id=v_enc and side='enemy';
  select count(*) into n_pos   from public.combat_units where encounter_id=v_enc and side='player' and pos_x is not null;
  if n_enemy < 1 then raise exception 'S1 FAIL: no enemy combat_units row on the first spatial tick (want >=1)'; end if;
  if n_pos   < 1 then raise exception 'S1 FAIL: no positioned player row (want >=1) — encounter is not spatial'; end if;

  -- ██ DARKEN THE GLOBAL FLAG MID-FIGHT ██ — the emergency the fix must survive.
  update public.game_config set value='false'::jsonb where key='spatial_combat_enabled';
  select waves_cleared into wc0 from public.combat_encounters where id=v_enc;

  -- keep ticking; the encounter MUST stay spatial. Discriminators, every tick:
  --   (a) player_integrity_current == sum(hp where side='player') — NO enemy fold (the corruption the
  --       aggregate arm would cause: it sums ALL rows incl. side='enemy' into player integrity).
  --   (b) enemy combat_units rows remain present/managed (the aggregate arm never touches them).
  -- Drive until wave 1 clears AND a fresh wave 2 spawns AFTER the darken (spatial-only behaviour: only the
  -- spatial arm inserts enemy combat_units rows on wave respawn).
  guard := 0;
  loop
    perform pg_temp.tick(v_enc);
    select player_integrity_current into v_pic from public.combat_encounters where id=v_enc;
    select coalesce(sum(hp_current),0) into v_psum from public.combat_units where encounter_id=v_enc and side='player';
    if v_pic is distinct from v_psum then
      raise exception 'S1 FAIL: player_integrity_current (%) != sum(side=player hp) (%) after darken — enemy rows folded into the player aggregate (mode flipped to aggregate)', v_pic, v_psum; end if;
    select count(*) into n_enemy from public.combat_units where encounter_id=v_enc and side='enemy';
    if n_enemy < 1 then raise exception 'S1 FAIL: enemy combat_units rows vanished after darken — the spatial arm stopped managing them'; end if;
    select waves_cleared into wc from public.combat_encounters where id=v_enc;
    -- once wave 1 is cleared, release the next-wave pause and let wave 2 spawn.
    if wc >= wc0 + 1 then
      update public.combat_encounters set next_wave_at = now() - interval '5 seconds' where id=v_enc;
    end if;
    exit when wc >= wc0 + 1;
    guard := guard + 1; if guard > 40 then raise exception 'S1 FAIL: wave did not clear within 40 post-darken ticks'; end if;
  end loop;

  -- rewards accrued for the wave cleared AFTER the darken (spatial reward path still runs).
  select count(*) into n_reward from public.combat_ticks where encounter_id=v_enc and result='wave_cleared';
  if n_reward < 1 then raise exception 'S1 FAIL: no wave_cleared reward tick after darken'; end if;

  -- spawn wave 2 AFTER the darken and assert FRESH enemy rows appear (aggregate arm never inserts them).
  perform pg_temp.tick(v_enc);
  select count(*) into n_enemy from public.combat_units where encounter_id=v_enc and side='enemy' and unit_type_id='pirate_synthetic';
  if n_enemy < 1 then raise exception 'S1 FAIL: no fresh pirate_synthetic wave spawned after darken (want >=1) — the aggregate arm would spawn none'; end if;
  -- re-confirm no enemy fold on the fresh-wave tick.
  select player_integrity_current into v_pic from public.combat_encounters where id=v_enc;
  select coalesce(sum(hp_current),0) into v_psum from public.combat_units where encounter_id=v_enc and side='player';
  if v_pic is distinct from v_psum then raise exception 'S1 FAIL: enemy fold on the fresh-wave tick (%!=%)', v_pic, v_psum; end if;

  -- retreat → escape → cleanup all still work on a spatial encounter after the darken.
  r := pg_temp.call_as(uS1, format('public.request_retreat(%L::uuid)', v_pres));
  select status into v_status from public.combat_encounters where id=v_enc;
  if v_status <> 'retreating' then raise exception 'S1 FAIL: status=% after request_retreat (want retreating)', v_status; end if;
  update public.combat_encounters set retreat_started_at = now() - interval '30 seconds' where id=v_enc;
  perform pg_temp.tick(v_enc);
  select status into v_status from public.combat_encounters where id=v_enc;
  if v_status <> 'escaped' then raise exception 'S1 FAIL: status=% after retreat delay (want escaped)', v_status; end if;
  select count(*) into guard from public.combat_reports where encounter_id=v_enc;
  if guard <> 1 then raise exception 'S1 FAIL: report_create ran % times (want 1)', guard; end if;

  raise notice 'SSPASS_1_SPATIAL_STAYS_SPATIAL_AFTER_DARK ok: encounter % created lit, ran spatial (enemy rows + positioned players); after darkening the flag mid-fight it STAYED spatial across every tick (player_integrity_current == sum(side=player hp) — no enemy fold), cleared a wave and accrued a reward POST-darken, spawned a FRESH pirate_synthetic wave POST-darken (aggregate arm spawns none), and retreat→escaped with exactly one report', v_enc;
end $s1$;

-- ════════ SCENARIO 2: AGGREGATE STAYS AGGREGATE AFTER ENABLE ═════════════════════════════════════════
do $s2$
declare
  uS2 uuid := (select v from ss where k='uS2'); gS2 uuid := (select v from ss where k='gS2');
  v_hunt uuid := (select v from ss where k='v_hunt'); v_enc uuid; v_pres uuid;
  n_pos int; n_enemy int; v_status text; i int; r jsonb;
begin
  -- CREATE WHILE DARK → no positioned rows → aggregate forever.
  update public.game_config set value='false'::jsonb where key='spatial_combat_enabled';
  v_enc := pg_temp.send_settle(uS2, gS2, v_hunt);
  insert into ss values ('encS2', v_enc);
  select presence_id into v_pres from public.combat_encounters where id=v_enc;

  -- ██ ENABLE THE FLAG MID-FIGHT ██ — must NOT retro-spatialize.
  update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
  for i in 1 .. 5 loop
    perform pg_temp.tick(v_enc);
    select count(*) into n_pos   from public.combat_units where encounter_id=v_enc and pos_x is not null;
    select count(*) into n_enemy from public.combat_units where encounter_id=v_enc and side='enemy';
    if n_pos   <> 0 then raise exception 'S2 FAIL: % positioned rows appeared after enabling — encounter was retro-spatialized (want 0)', n_pos; end if;
    if n_enemy <> 0 then raise exception 'S2 FAIL: % enemy combat_units rows written after enabling — the spatial arm ran (want 0)', n_enemy; end if;
  end loop;

  -- reaches a terminal state normally on the aggregate path.
  r := pg_temp.call_as(uS2, format('public.request_retreat(%L::uuid)', v_pres));
  update public.combat_encounters set retreat_started_at = now() - interval '30 seconds' where id=v_enc;
  perform pg_temp.tick(v_enc);
  select status into v_status from public.combat_encounters where id=v_enc;
  if v_status not in ('escaped','completed') then raise exception 'S2 FAIL: aggregate encounter did not reach terminal (status=%)', v_status; end if;
  select count(*) into n_enemy from public.combat_units where encounter_id=v_enc and side='enemy';
  if n_enemy <> 0 then raise exception 'S2 FAIL: an enemy combat_units row exists post-terminal (want 0)'; end if;

  raise notice 'SSPASS_2_AGGREGATE_STAYS_AGGREGATE_AFTER_ENABLE ok: encounter % created dark ran the aggregate arm; ENABLING the flag mid-fight NEVER retro-spatialized it (0 positioned rows, 0 enemy combat_units rows across 5 ticks) and it reached terminal status=%', v_enc, v_status;
end $s2$;

-- ════════ SCENARIO 3: NEW ENCOUNTER AFTER DARK ══════════════════════════════════════════════════════
do $s3$
declare
  uS3a uuid := (select v from ss where k='uS3a'); gS3a uuid := (select v from ss where k='gS3a');
  uS3b uuid := (select v from ss where k='uS3b'); gS3b uuid := (select v from ss where k='gS3b');
  v_hunt uuid := (select v from ss where k='v_hunt'); enc_a uuid; enc_b uuid;
  n_enemy int; n_pos int; v_pic double precision; v_psum double precision; i int;
begin
  -- enc_a: created LIT → spatial.
  update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
  enc_a := pg_temp.send_settle(uS3a, gS3a, v_hunt);
  insert into ss values ('encS3a', enc_a);
  perform pg_temp.tick(enc_a);
  select count(*) into n_enemy from public.combat_units where encounter_id=enc_a and side='enemy';
  select count(*) into n_pos   from public.combat_units where encounter_id=enc_a and side='player' and pos_x is not null;
  if n_enemy < 1 or n_pos < 1 then raise exception 'S3 FAIL: enc_a not spatial at creation (enemy=% pos=%)', n_enemy, n_pos; end if;

  -- ██ DARKEN ██, then confirm enc_a STAYS spatial.
  update public.game_config set value='false'::jsonb where key='spatial_combat_enabled';
  perform pg_temp.tick(enc_a);
  select player_integrity_current into v_pic from public.combat_encounters where id=enc_a;
  select coalesce(sum(hp_current),0) into v_psum from public.combat_units where encounter_id=enc_a and side='player';
  select count(*) into n_enemy from public.combat_units where encounter_id=enc_a and side='enemy';
  if v_pic is distinct from v_psum or n_enemy < 1 then
    raise exception 'S3 FAIL: enc_a lost spatial mode after darken (integrity %!=% or enemy=%)', v_pic, v_psum, n_enemy; end if;

  -- enc_b: created AFTER the darken → must be non-spatial.
  enc_b := pg_temp.send_settle(uS3b, gS3b, v_hunt);
  insert into ss values ('encS3b', enc_b);
  for i in 1 .. 3 loop
    perform pg_temp.tick(enc_b);
    select count(*) into n_pos   from public.combat_units where encounter_id=enc_b and pos_x is not null;
    select count(*) into n_enemy from public.combat_units where encounter_id=enc_b and side='enemy';
    if n_pos <> 0 or n_enemy <> 0 then
      raise exception 'S3 FAIL: enc_b (created after darken) is spatial (pos=% enemy=%) — darkening did not block the NEW encounter', n_pos, n_enemy; end if;
  end loop;

  -- enc_a is STILL spatial after enc_b's creation (creating a dark encounter did not disturb it).
  perform pg_temp.tick(enc_a);
  select player_integrity_current into v_pic from public.combat_encounters where id=enc_a;
  select coalesce(sum(hp_current),0) into v_psum from public.combat_units where encounter_id=enc_a and side='player';
  select count(*) into n_pos   from public.combat_units where encounter_id=enc_a and side='player' and pos_x is not null;
  select count(*) into n_enemy from public.combat_units where encounter_id=enc_a and side='enemy';
  if v_pic is distinct from v_psum or n_pos < 1 or n_enemy < 1 then
    raise exception 'S3 FAIL: enc_a stopped being spatial (integrity %!=%, pos=%, enemy=%)', v_pic, v_psum, n_pos, n_enemy; end if;

  raise notice 'SSPASS_3_NEW_ENCOUNTER_AFTER_DARK ok: enc_a % created lit stayed spatial after the flag darkened AND after a new encounter was created; enc_b % created AFTER the darken is non-spatial (0 positioned rows, 0 enemy combat_units rows) — darkening blocks only NEW spatial encounters', enc_a, enc_b;
end $s3$;

-- ════════ SCENARIO 4: SAFE EMERGENCY DARKENING ══════════════════════════════════════════════════════
do $s4$
declare
  uS4 uuid := (select v from ss where k='uS4'); gS4 uuid := (select v from ss where k='gS4');
  uS4b uuid := (select v from ss where k='uS4b'); gS4b uuid := (select v from ss where k='gS4b');
  v_hunt uuid := (select v from ss where k='v_hunt'); v_enc uuid; v_pres uuid; enc_probe uuid;
  n_member int; n_member0 int; n_enemy int; n_pos int; v_pic double precision; v_psum double precision;
  tk int; tk_prev int; lr timestamptz; wc int; n_reward int; guard int; v_status text; i int; r jsonb;
begin
  -- create an active SPATIAL encounter and establish wave 1.
  update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
  v_enc := pg_temp.send_settle(uS4, gS4, v_hunt);
  insert into ss values ('encS4', v_enc);
  select presence_id into v_pres from public.combat_encounters where id=v_enc;
  perform pg_temp.tick(v_enc);
  select count(*) into n_member0 from public.combat_units where encounter_id=v_enc and side='player';
  if n_member0 <> 2 then raise exception 'S4 FAIL: expected 2 player member rows, got %', n_member0; end if;

  -- ██ EMERGENCY DARKEN during the active spatial encounter ██
  update public.game_config set value='false'::jsonb where key='spatial_combat_enabled';

  -- (a) blocks NEW spatial creation: a probe encounter created now is non-spatial.
  enc_probe := pg_temp.send_settle(uS4b, gS4b, v_hunt);
  perform pg_temp.tick(enc_probe);
  select count(*) into n_pos   from public.combat_units where encounter_id=enc_probe and pos_x is not null;
  select count(*) into n_enemy from public.combat_units where encounter_id=enc_probe and side='enemy';
  if n_pos <> 0 or n_enemy <> 0 then raise exception 'S4 FAIL: emergency darken did NOT block a new spatial encounter (pos=% enemy=%)', n_pos, n_enemy; end if;

  -- (b/c/d/e) the active encounter: mode unchanged, no stall, one reward per wave, no corruption. Drive
  --   through a wave clear post-darken.
  select waves_cleared into wc from public.combat_encounters where id=v_enc;
  select tick_number into tk_prev from public.combat_encounters where id=v_enc;
  guard := 0;
  loop
    perform pg_temp.tick(v_enc);
    -- no stall: tick_number strictly advances and last_resolved_at re-resolves to now().
    select tick_number, last_resolved_at into tk, lr from public.combat_encounters where id=v_enc;
    if tk <= tk_prev then raise exception 'S4 FAIL: tick_number did not advance (%->%) after darken — a stall', tk_prev, tk; end if;
    if lr is distinct from now() then raise exception 'S4 FAIL: last_resolved_at not refreshed to now() (%) — a stall', lr; end if;
    tk_prev := tk;
    -- mode unchanged: still spatial (enemy rows present, no fold), member count intact.
    select player_integrity_current into v_pic from public.combat_encounters where id=v_enc;
    select coalesce(sum(hp_current),0) into v_psum from public.combat_units where encounter_id=v_enc and side='player';
    select count(*) into n_member from public.combat_units where encounter_id=v_enc and side='player';
    select count(*) into n_enemy  from public.combat_units where encounter_id=v_enc and side='enemy';
    if v_pic is distinct from v_psum then raise exception 'S4 FAIL: player integrity corrupted by enemy fold (%!=%)', v_pic, v_psum; end if;
    if n_member <> n_member0 then raise exception 'S4 FAIL: player member row count changed (%->%) — row corruption', n_member0, n_member; end if;
    if n_enemy < 1 then raise exception 'S4 FAIL: enemy rows vanished — mode switched to aggregate'; end if;
    select waves_cleared into wc from public.combat_encounters where id=v_enc;
    if wc >= 1 then update public.combat_encounters set next_wave_at = now() - interval '5 seconds' where id=v_enc; end if;
    exit when wc >= 1;
    guard := guard + 1; if guard > 40 then raise exception 'S4 FAIL: wave did not clear within 40 ticks post-darken'; end if;
  end loop;

  -- exactly one reward tick per cleared wave (no duplicate rewards).
  select count(*) into n_reward from public.combat_ticks where encounter_id=v_enc and result='wave_cleared';
  if n_reward <> wc then raise exception 'S4 FAIL: % wave_cleared reward ticks for % cleared waves (want equal — no duplicates)', n_reward, wc; end if;

  -- (f) retreat + cleanup intact.
  r := pg_temp.call_as(uS4, format('public.request_retreat(%L::uuid)', v_pres));
  update public.combat_encounters set retreat_started_at = now() - interval '30 seconds' where id=v_enc;
  perform pg_temp.tick(v_enc);
  select status into v_status from public.combat_encounters where id=v_enc;
  if v_status <> 'escaped' then raise exception 'S4 FAIL: status=% after retreat (want escaped)', v_status; end if;
  select count(*) into guard from public.combat_reports where encounter_id=v_enc;
  if guard <> 1 then raise exception 'S4 FAIL: report_create ran % times (want 1)', guard; end if;

  raise notice 'SSPASS_4_SAFE_EMERGENCY_DARKENING ok: encounter % — emergency darkening blocked a NEW spatial encounter (probe % non-spatial), did NOT switch the active encounter''s mode (still spatial, enemy rows present, player integrity uncorrupted, 2 member rows intact), did NOT stall (tick_number strictly advanced, last_resolved_at re-resolved every tick), granted exactly % reward tick(s) for % cleared wave(s) (no duplicates), and retreat→escaped with exactly one report', v_enc, enc_probe, n_reward, wc;
end $s4$;

do $$ begin raise notice 'STICKY SPATIAL MODE PROOF PASSED'; end $$;

-- rollback confirmation: everything above (5 flags flipped, ~14 config knobs, 6 users/wallets/teams, 8
-- encounters, every tick/reward/row) is inside this single transaction; the trailing ROLLBACK discards ALL
-- of it — ZERO persisted state, no COMMIT anywhere above, no production write, no migration, no prod flag
-- change.
rollback;
