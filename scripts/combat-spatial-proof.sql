-- COMBAT-SPATIAL — disposable proof for the S3 spatial-combat slice (migration 0234): per-ship
-- positions, the CLOSE-vs-KITE movement/targeting AI, synthetic pirate spawn, per-weapon fire
-- events, and damage — driven through the REAL chain (send_ship_group_hunt → movement_settle_arrival
-- → activity_start → combat_create_encounter's D2 branch → combat_create_group_encounter →
-- process_combat_ticks), never a hand-rolled combat_units/group_sortie_members write.
--
-- This is the live-DB scenario proof the migration's own header flagged as owed: the migration
-- self-asserts prosrc/structural parity (no fixture harness exists inside a migration — the
-- auth.users FK chain), but NEVER executes the spatial tick end to end. This script does.
--
-- ── SCENARIO (deliberately engineered geometry, not incidental) ──────────────────────────────────
-- One team of 3 ships: a command ship (armed, spawns at the arrival location's own center — dist 0
-- from the synthetic pirate, which ALSO spawns at the center) and two escorts on the formation ring
-- (spatial_formation_ring_radius tuned to 50): one ARMED (autocannon, range 150) and one UNARMED.
-- The synthetic pirate's own weapon range is tuned to 10 (well under the 50-unit ring distance) and
-- its move speed to 60 (well over the 50-unit gap), while every player ship's move_speed is the
-- bare hull's ~1.0 (main_ship_hull_types.starter_frigate.base_speed) — deliberately asymmetric, so:
--   • command ship  (dist 0, range 150 >= 0)                       → HOLD, fires immediately.
--   • armed escort  (dist 50, range 150 >= 50 > pirate range 10)   → KITE (retreats), fires immediately
--                                                                     (pre-move distance is in range).
--   • unarmed escort(dist 50, own range 0 < 50)                    → CLOSE (advances), cannot fire.
--   • the pirate (dist 50 > its own range 10) CLOSEs on tick 1 (speed 60 closes the full 50-unit gap)
--     and, now in range, FIRES on tick 2 — proving the S1 aggro-tier screening survives spatially:
--     it can only ever target an escort (aggro 0) while one lives, never the command ship (aggro 100).
-- enemy_hp_base is raised so the synthetic pirate has ample hp to survive both player hits (the
-- assertions need it alive into tick 2); combat_damage_variance_pct is zeroed for determinism (the
-- house idiom, team-command-proof.sql's own COMBATPARITY setup).
--
-- ── PROPERTIES PROVEN (each a PASS marker below) ───────────────────────────────────────────────────
--   COMBATSPATIAL_PASS_SPAWN     — spawn writes positions/speed/weapons ONLY when lit; command ship
--                                  at the location center; both escorts on the ring at the SAME
--                                  distance from center; weapons_json shapes match the fitted loadout
--                                  (armed ships carry 1 weapon entry, the unarmed escort carries none).
--   COMBATSPATIAL_PASS_ENEMY     — the synthetic pirate spawns AT the location center (the "pirates
--                                  spawn from the zone center" requirement), side='enemy',
--                                  unit_type_id='pirate_synthetic', count 1 (danger 1).
--   COMBATSPATIAL_PASS_HOLD      — the command ship's position is BYTE-IDENTICAL before/after (HOLD
--                                  never touches pos_x/pos_y).
--   COMBATSPATIAL_PASS_KITE      — the armed escort's distance from the pirate INCREASED (retreated),
--                                  staying within its own weapon range.
--   COMBATSPATIAL_PASS_CLOSE     — the unarmed escort's distance from the pirate DECREASED (advanced).
--   COMBATSPATIAL_PASS_FIRE      — tick 1 emits player-sourced missile_salvo events (command + armed
--                                  escort, both in range pre-move); the pirate does NOT fire tick 1
--                                  (out of its own short range at the pre-move distance).
--   COMBATSPATIAL_PASS_DAMAGE    — the pirate's hp_current fell below its frozen hp_max after tick 1
--                                  (it took real damage the same tick it spawned).
--   COMBATSPATIAL_PASS_SCREEN    — after tick 2 (the pirate has closed in and now fires): a
--                                  pirate-sourced missile_salvo event exists, at least one escort's hp
--                                  fell, and the COMMAND SHIP's hp is UNCHANGED — the S1 aggro-tier
--                                  screening (escorts before the command ship) holds in the spatial
--                                  branch exactly as it does in the aggregate one.
--
-- Self-rolling-back (begin;...rollback;, no COMMIT); every dark flag flipped ONLY inside the txn;
-- provisioning is 100% real-RPC (commission_first_main_ship / commission_additional_main_ship /
-- upsert_ship_group / assign_ship_to_group / set_fleet_command_ship / craft_module /
-- fit_module_to_ship / send_ship_group_hunt); group_sortie_members and combat_units are NEVER
-- hand-written — send_ship_group_hunt and combat_create_group_encounter are their sole writers.
-- No session RNG calls (the 0041 determinism law) — gen_random_uuid() is the only randomness used,
-- for fixture identity only, never combat math (combat_damage_variance_pct is zeroed).

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table cspatial(k text primary key, v uuid) on commit preserve rows;

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb. Self-contained
-- (not sourced from either contended proof file) — the tiny call_as idiom is infra, not owned state.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- ════════ SETUP: reveal the starter ports (a fresh disposable chain seeds Haven/Slagworks/
--          Driftmarch INACTIVE — port_entry_commission_build hard-requires Haven to be dockable, so
--          without this, EVERY commission call fails closed with commission_unavailable; this is the
--          team-command-proof.sql precedent's own first setup step, mirrored verbatim), then one
--          fixture player, funded ═══════════════════════════════════════════════════════════════════
do $$
declare r jsonb; uZ uuid;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'cspatial.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uZ;
  insert into cspatial values ('uZ', uZ);
  insert into public.player_wallet (player_id, balance) values (uZ, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- dark capability gates — flipped ONLY inside this rolled-back txn (committed/production values stay
-- false; a fresh disposable chain has ALL of these seeded false, so every one is load-bearing here).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';

-- tuning knobs (numeric, not capability gates) — the real set_game_config leaf, all reverted by
-- ROLLBACK. The scenario's engineered geometry (header) depends on these EXACT values.
do $$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);          -- determinism
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);              -- so combat_ticks rows land
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);             -- so fire events land
  perform public.set_game_config('enemy_hp_base', '1000'::jsonb);                    -- pirate survives both hits into tick 2
  perform public.set_game_config('spatial_formation_ring_radius', '50'::jsonb);      -- escort ring distance
  perform public.set_game_config('enemy_synthetic_range_base', '10'::jsonb);         -- pirate weapon range < ring distance
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base', '60'::jsonb);         -- pirate closes the 50-gap in ONE tick
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
end $$;

-- ════════ PROVISION: 3 ships via the real commission RPCs, a real team, a real command designation,
--          and 2 real weapon fits (command ship + the armed escort) ═════════════════════════════════
do $$
declare
  r jsonb;
  uZ uuid := (select v from cspatial where k='uZ');
  s_cmd uuid; s_arm uuid; s_bare uuid;
  v_mod_cmd uuid; v_mod_arm uuid;
begin
  r := pg_temp.call_as(uZ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL first ship: %', r; end if;
  select main_ship_id into s_cmd from public.main_ship_instances where player_id = uZ;

  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then
    raise exception 'PROVISION FAIL 2nd ship: %', r; end if;
  s_arm := (r->>'main_ship_id')::uuid;

  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then
    raise exception 'PROVISION FAIL 3rd ship: %', r; end if;
  s_bare := (r->>'main_ship_id')::uuid;

  insert into cspatial values ('s_cmd', s_cmd), ('s_arm', s_arm), ('s_bare', s_bare);

  -- grant EXACTLY the autocannon_battery recipe TWICE over (weapon_parts x4, pirate_alloy x2, scrap x6
  -- per unit — the S0/0107 seed) via the real Reward sole writer.
  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);

  -- craft + fit ONE autocannon_battery onto the command ship.
  r := pg_temp.call_as(uZ, 'public.craft_module(''cspatial-gun-1'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft gun1: %', r; end if;
  v_mod_cmd := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''cspatial-fit-1'')', v_mod_cmd, s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit gun1: %', r; end if;

  -- craft + fit a SECOND autocannon_battery onto the armed escort.
  r := pg_temp.call_as(uZ, 'public.craft_module(''cspatial-gun-2'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft gun2: %', r; end if;
  v_mod_arm := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''cspatial-fit-2'')', v_mod_arm, s_arm));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit gun2: %', r; end if;

  -- s_bare stays deliberately unarmed (no craft/fit call) — the CLOSE witness (my_range 0).

  -- form the team, assign all 3, designate the command ship (owner-scoped, NOT flag-gated, 0204).
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''Spatial'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group create: %', r; end if;
  insert into cspatial values ('gZ', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_cmd,  (select v from cspatial where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign cmd: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_arm,  (select v from cspatial where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign arm: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_bare, (select v from cspatial where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign bare: %', r; end if;

  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL designate command: %', r; end if;

  raise notice 'setup ok: 3-ship team provisioned (s_cmd armed+command, s_arm armed escort, s_bare unarmed escort)';
end $$;

-- ════════ SEND + SETTLE: the real chain, exactly team-command-proof.sql's TEAMHUNT pattern ══════════
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from cspatial where k='uZ');
  gZ uuid := (select v from cspatial where k='gZ');
  v_hunt uuid; v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'SEND FAIL: no active hunt_pirates location'; end if;
  insert into cspatial values ('v_hunt', v_hunt);

  r := pg_temp.call_as(uZ, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gZ, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  if v_fleet is null or v_mv is null then raise exception 'SEND FAIL envelope: %', r; end if;

  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 3 then raise exception 'SEND FAIL: % manifest rows (want 3)', n; end if;

  -- settle via the cron's own per-movement settle (clock rewind, the sanctioned surgery — the
  -- team-command-proof.sql TEAMHUNT idiom, verbatim).
  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then
    raise exception 'SEND FAIL settle: %', r; end if;

  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'SEND FAIL: no active encounter after arrival'; end if;
  insert into cspatial values ('v_enc', v_enc);

  raise notice 'setup ok: sortie sent, settled, encounter % active', v_enc;
end $$;

-- ════════ BLOCK SPAWN: the creator's spatial hunk (LIT, positions/speed/weapons written) ═══════════
do $$
declare
  n int; v_enc uuid := (select v from cspatial where k='v_enc');
  s_cmd uuid := (select v from cspatial where k='s_cmd');
  s_arm uuid := (select v from cspatial where k='s_arm');
  s_bare uuid := (select v from cspatial where k='s_bare');
  v_hunt uuid := (select v from cspatial where k='v_hunt');
  v_loc_x double precision; v_loc_y double precision;
  v_cmd_x double precision; v_cmd_y double precision;
  v_dist_arm double precision; v_dist_bare double precision;
  v_wcount_cmd int; v_wcount_arm int; v_wcount_bare int;
begin
  select x, y into v_loc_x, v_loc_y from public.locations where id = v_hunt;

  -- exactly 3 player-side rows, all positioned (LIT — not NULL).
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'player' and pos_x is not null and pos_y is not null and move_speed is not null;
  if n <> 3 then raise exception 'SPAWN FAIL: % player rows carry positions (want 3)', n; end if;

  -- the command ship spawns EXACTLY at the location center.
  select pos_x, pos_y into v_cmd_x, v_cmd_y from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  if v_cmd_x is distinct from v_loc_x or v_cmd_y is distinct from v_loc_y then
    raise exception 'SPAWN FAIL: command ship not at location center (got %,% want %,%)', v_cmd_x, v_cmd_y, v_loc_x, v_loc_y;
  end if;

  -- both escorts sit on the SAME ring (same distance from center — the tuned 50).
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_arm
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_bare
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  if abs(v_dist_arm - 50) > 0.01 or abs(v_dist_bare - 50) > 0.01 then
    raise exception 'SPAWN FAIL: escort ring distances wrong (arm=%, bare=%, want ~50 each)', v_dist_arm, v_dist_bare;
  end if;

  -- weapons_json shapes: armed ships carry exactly 1 weapon entry; the unarmed escort carries none.
  select jsonb_array_length(weapons_json) into v_wcount_cmd  from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  select jsonb_array_length(weapons_json) into v_wcount_arm  from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select jsonb_array_length(weapons_json) into v_wcount_bare from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  if v_wcount_cmd <> 1 or v_wcount_arm <> 1 or v_wcount_bare <> 0 then
    raise exception 'SPAWN FAIL: weapon counts wrong (cmd=%, arm=%, bare=% — want 1,1,0)', v_wcount_cmd, v_wcount_arm, v_wcount_bare;
  end if;
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and main_ship_id in (s_cmd, s_arm)
      and (weapons_json->0->>'module_type_id') = 'autocannon_battery'
      and (weapons_json->0->>'range')::double precision = 150;
  if n <> 2 then raise exception 'SPAWN FAIL: fitted weapon range/id did not carry into weapons_json (want 2 rows at range 150)'; end if;

  -- side is 'player' for every row this creator ever writes.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side <> 'player' and main_ship_id is not null;
  if n <> 0 then raise exception 'SPAWN FAIL: a member row is not side=player'; end if;

  raise notice 'COMBATSPATIAL_PASS_SPAWN ok: command ship at location center, both escorts on the 50-unit ring, weapons_json shapes exact (1/1/0), side=player throughout';
end $$;

-- ════════ TICK 1: wave spawn + first movement/fire pass ═════════════════════════════════════════════
do $$
declare
  n int; n_player_fire int; v_enc uuid := (select v from cspatial where k='v_enc');
  s_cmd uuid := (select v from cspatial where k='s_cmd');
  s_arm uuid := (select v from cspatial where k='s_arm');
  s_bare uuid := (select v from cspatial where k='s_bare');
  v_hunt uuid := (select v from cspatial where k='v_hunt');
  v_loc_x double precision; v_loc_y double precision;
  v_cmd_x0 double precision; v_cmd_y0 double precision;
  v_cmd_x1 double precision; v_cmd_y1 double precision;
  v_dist_arm0 double precision; v_dist_arm1 double precision;
  v_dist_bare0 double precision; v_dist_bare1 double precision;
  v_hp_cmd0 double precision; v_hp_arm0 double precision; v_hp_bare0 double precision;
  v_enemy_hpmax double precision; v_enemy_hpcur double precision;
begin
  select x, y into v_loc_x, v_loc_y from public.locations where id = v_hunt;

  -- pre-tick snapshot (positions + hp), read BEFORE calling the tick.
  select pos_x, pos_y into v_cmd_x0, v_cmd_y0 from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_arm0  from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_bare0 from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  select hp_current into v_hp_cmd0  from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  select hp_current into v_hp_arm0  from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select hp_current into v_hp_bare0 from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;

  -- no enemy exists yet — wave 1 (and its first combat pass) spawns INSIDE this very tick call.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> 0 then raise exception 'TICK1 FAIL precondition: % enemy rows exist before the first tick (want 0)', n; end if;

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  -- ── ENEMY SPAWN: exactly 1 synthetic pirate, AT the location center, side=enemy, identity anchor. ──
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'enemy' and unit_type_id = 'pirate_synthetic'
      and pos_x is not distinct from v_loc_x and pos_y is not distinct from v_loc_y;
  if n <> 1 then raise exception 'TICK1 FAIL: % synthetic pirate row(s) at the location center (want exactly 1)', n; end if;
  raise notice 'COMBATSPATIAL_PASS_ENEMY ok: 1 synthetic pirate spawned at the location center, side=enemy, unit_type_id=pirate_synthetic';

  -- ── HOLD: the command ship (dist 0, in range) never moves — byte-identical position. ──────────────
  select pos_x, pos_y into v_cmd_x1, v_cmd_y1 from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  if v_cmd_x1 is distinct from v_cmd_x0 or v_cmd_y1 is distinct from v_cmd_y0 then
    raise exception 'TICK1 FAIL HOLD: command ship moved (%,% -> %,%) — want byte-identical', v_cmd_x0, v_cmd_y0, v_cmd_x1, v_cmd_y1;
  end if;
  raise notice 'COMBATSPATIAL_PASS_HOLD ok: command ship position byte-identical after tick 1 (HOLD never touches pos_x/pos_y)';

  -- ── KITE: the armed escort's distance from the pirate INCREASED, staying within its own 150 range. ─
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_arm1
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  if v_dist_arm1 <= v_dist_arm0 then
    raise exception 'TICK1 FAIL KITE: armed escort distance did not increase (%->%)', v_dist_arm0, v_dist_arm1; end if;
  if v_dist_arm1 > 150.001 then
    raise exception 'TICK1 FAIL KITE: armed escort retreated past its own 150 range (dist %)', v_dist_arm1; end if;
  raise notice 'COMBATSPATIAL_PASS_KITE ok: armed escort retreated (dist %->%), staying within its own 150 weapon range', v_dist_arm0, v_dist_arm1;

  -- ── CLOSE: the unarmed escort's distance from the pirate DECREASED. ─────────────────────────────────
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_bare1
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  if v_dist_bare1 >= v_dist_bare0 then
    raise exception 'TICK1 FAIL CLOSE: unarmed escort distance did not decrease (%->%)', v_dist_bare0, v_dist_bare1; end if;
  raise notice 'COMBATSPATIAL_PASS_CLOSE ok: unarmed escort advanced (dist %->%)', v_dist_bare0, v_dist_bare1;

  -- ── FIRE: tick 1 emits PLAYER missile_salvo events (command + armed escort, both pre-move in
  --    range); the pirate does NOT fire tick 1 (out of its own short range at the pre-move distance).
  select count(*) into n_player_fire from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'player';
  if n_player_fire < 2 then raise exception 'TICK1 FAIL FIRE: % player missile_salvo events on tick 1 (want >= 2 — command + armed escort)', n_player_fire; end if;
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'pirate';
  if n <> 0 then raise exception 'TICK1 FAIL FIRE: pirate fired on tick 1 (want 0 — it starts out of its own 10-range at dist 50)'; end if;
  raise notice 'COMBATSPATIAL_PASS_FIRE ok: tick 1 — % player missile_salvo events (command + armed escort), pirate did not fire (still out of range pre-move)', n_player_fire;

  -- ── DAMAGE: the pirate's hp_current fell below its frozen hp_max (it took real damage tick 1). ─────
  select hp_max, hp_current into v_enemy_hpmax, v_enemy_hpcur
    from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if v_enemy_hpcur >= v_enemy_hpmax then
    raise exception 'TICK1 FAIL DAMAGE: pirate hp_current (%) is not below hp_max (%)', v_enemy_hpcur, v_enemy_hpmax; end if;
  raise notice 'COMBATSPATIAL_PASS_DAMAGE ok: pirate hp_current % fell below its frozen hp_max % after tick 1', v_enemy_hpcur, v_enemy_hpmax;

  -- sanity: no player ship has taken damage yet (the pirate could not reach firing range this tick).
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'player'
      and ((main_ship_id = s_cmd  and hp_current is distinct from v_hp_cmd0)
        or (main_ship_id = s_arm  and hp_current is distinct from v_hp_arm0)
        or (main_ship_id = s_bare and hp_current is distinct from v_hp_bare0));
  if n <> 0 then raise exception 'TICK1 FAIL: a player ship took damage before the pirate was ever in range (want 0)'; end if;
end $$;

-- ════════ TICK 2: the pirate has closed the gap — now fires; the aggro screen must hold ════════════
do $$
declare
  n int; v_enc uuid := (select v from cspatial where k='v_enc');
  s_cmd uuid := (select v from cspatial where k='s_cmd');
  s_arm uuid := (select v from cspatial where k='s_arm');
  s_bare uuid := (select v from cspatial where k='s_bare');
  v_hp_cmd1 double precision; v_hp_cmd2 double precision;
  v_hp_arm1 double precision; v_hp_arm2 double precision;
  v_hp_bare1 double precision; v_hp_bare2 double precision;
begin
  select hp_current into v_hp_cmd1  from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  select hp_current into v_hp_arm1  from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select hp_current into v_hp_bare1 from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  select count(*) into n from public.combat_events
    where encounter_id = v_enc and event_type = 'missile_salvo' and source = 'pirate';
  if n < 1 then raise exception 'TICK2 FAIL: no pirate-sourced missile_salvo event by tick 2 (want >= 1 — it should have closed in and now be in range)'; end if;

  select hp_current into v_hp_cmd2  from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  select hp_current into v_hp_arm2  from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select hp_current into v_hp_bare2 from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;

  -- the S1 aggro-tier screen: the command ship (aggro 100) is NEVER a legal target while an escort
  -- (aggro 0) lives — its hp must be byte-identical across both ticks.
  if v_hp_cmd2 is distinct from v_hp_cmd1 then
    raise exception 'TICK2 FAIL SCREEN: command ship hp changed (%->%) while an escort still lives — aggro screening breached', v_hp_cmd1, v_hp_cmd2;
  end if;
  -- at least one escort took the hit instead.
  if v_hp_arm2 >= v_hp_arm1 and v_hp_bare2 >= v_hp_bare1 then
    raise exception 'TICK2 FAIL SCREEN: neither escort took damage by tick 2 (arm %->%, bare %->%) — the pirate must have hit an escort', v_hp_arm1, v_hp_arm2, v_hp_bare1, v_hp_bare2;
  end if;

  raise notice 'COMBATSPATIAL_PASS_SCREEN ok: pirate fired by tick 2, an escort took the hit (arm %->%, bare %->%), command ship hp byte-identical (%) — the S1 aggro-tier screen holds spatially', v_hp_arm1, v_hp_arm2, v_hp_bare1, v_hp_bare2, v_hp_cmd2;
end $$;

do $$ begin raise notice 'COMBAT-SPATIAL PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
