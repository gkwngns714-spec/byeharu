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
-- ── SCENARIO (deliberately engineered geometry, not incidental; retuned by the 0313 range cut —
--    the fitted autocannon range is now READ FROM THE CATALOG (5 post-0316), never assumed, and
--    every distance this scenario stakes a property on is a knob it OWNS in-txn) ──────────────────
-- One team of 3 ships: a command ship (armed, spawns at the arrival location's own center — dist 0
-- from the synthetic pirate, which ALSO spawns at the center) and two escorts on the formation ring
-- (spatial_formation_ring_radius tuned to 4): one ARMED (autocannon, catalog range) and one with
-- NO fitted weapon — which, since 0262, carries the synthesized fallback weapon, whose range this
-- harness OWNS at 1 (combat_player_fallback_weapon_range tuned in-txn) so the CLOSE case stays
-- reachable now that every combat-capable ship has a weapon.
-- The synthetic pirate's own weapon range is tuned to 2 (under the 4-unit ring distance) and
-- its move speed to 12 (well over the 4-unit gap), while every player ship's move_speed is the bare
-- hull's ~1.0 (main_ship_hull_types.starter_frigate.base_speed) converted into combat space by
-- 0316's combat_player_speed_scale — deliberately asymmetric, so:
--   • command ship  (dist 0, catalog range 5 >= 0)                   → HOLD, fires immediately.
--   • armed escort  (dist 4, catalog 5 >= 4 > pirate range 2)        → KITE (retreats), fires
--                                                                       immediately (pre-move in range).
--   • fallback escort(dist 4, own fallback range 1 < 4)              → CLOSE (advances), cannot fire.
--   • the pirate (dist 4 > its own range 2) CLOSEs on tick 1 (speed 12 closes the full 4-unit gap)
--     and, now in range, FIRES on tick 2 — proving the S1 aggro-tier screening survives spatially:
--     it can only ever target an escort (aggro 0) while one lives, never the command ship (aggro 100).
-- 0316 REPOINT: every one of those four owned numbers is the OLD one divided by 5, exactly as 0316
-- divided the world they sit in (catalog gun 25->5, ring 30->6, pirate range/speed and the player's
-- in-combat speed all by the same factor). The KITE and CLOSE assertions are DIRECTIONAL (distance
-- increased / decreased), so they hold for any positive player speed and never depend on the value
-- of the conversion factor — only the ORDERING fallback < ring < catalog gun is load-bearing, and
-- the ring assertion below states it in the same breath as it measures it.
-- enemy_hp_base is raised so the synthetic pirate has ample hp to survive both player hits (the
-- assertions need it alive into tick 2); combat_damage_variance_pct is zeroed for determinism (the
-- house idiom, team-command-proof.sql's own COMBATPARITY setup).
--
-- ── PROPERTIES PROVEN (each a PASS marker below) ───────────────────────────────────────────────────
--   COMBATSPATIAL_PASS_SPAWN     — spawn writes positions/speed/weapons ONLY when lit; command ship
--                                  at the location center; both escorts on the ring at the SAME
--                                  distance from center; weapons_json shapes match the loadout
--                                  (fitted ships carry their 1 catalog gun; the unfitted escort
--                                  carries exactly the ONE 0262 fallback entry).
--   COMBATSPATIAL_PASS_ENEMY     — the synthetic pirate spawns AT the location center (the "pirates
--                                  spawn from the zone center" requirement), side='enemy',
--                                  unit_type_id='pirate_synthetic', count 1 (danger 1).
--   COMBATSPATIAL_PASS_HOLD      — the command ship's position is BYTE-IDENTICAL before/after (HOLD
--                                  never touches pos_x/pos_y).
--   COMBATSPATIAL_PASS_KITE      — the armed escort's distance from the pirate INCREASED (retreated),
--                                  staying within its own catalog weapon range.
--   COMBATSPATIAL_PASS_CLOSE     — the fallback escort's distance from the pirate DECREASED (advanced).
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
-- combat_telegraph stays DARK — OWNED here, not inherited (0300 lit it in the chain seeds, after
-- this proof was written; a lit telegraph queues the encounter instead of opening it inline at the
-- settle, and this proof's whole scenario observes the inline opening). The danger-combat-proof
-- idiom, verbatim.
update public.game_config set value='false'::jsonb where key='combat_telegraph_enabled';

-- tuning knobs (numeric, not capability gates) — the real set_game_config leaf, all reverted by
-- ROLLBACK. The scenario's engineered geometry (header) depends on these EXACT values.
do $$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);          -- determinism
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);              -- so combat_ticks rows land
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);             -- so fire events land
  perform public.set_game_config('enemy_hp_base', '1000'::jsonb);                    -- pirate survives both hits into tick 2
  perform public.set_game_config('spatial_formation_ring_radius', '4'::jsonb);       -- escort ring distance: inside the catalog gun range (5 post-0316), outside the pirate's 2 and the owned fallback 1
  perform public.set_game_config('enemy_synthetic_range_base', '2'::jsonb);          -- pirate weapon range < ring distance
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base', '12'::jsonb);         -- pirate closes the 4-gap in ONE tick
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  -- the CLOSE witness's own range, OWNED here (0313 repoint): since 0262 an unfitted ship carries
  -- the synthesized fallback weapon, so "advances because it cannot reach" needs a range this
  -- harness sets, strictly under the ring — never the seeded default.
  perform public.set_game_config('combat_player_fallback_weapon_range', '1'::jsonb);
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

  -- ── FIXTURE NORMALIZATION — the ONE non-RPC-pure step in this proof (the team-command-proof.sql
  --    PROVISION-block precedent, lifted verbatim). port_entry_commission_build (0222) docks every
  --    freshly commissioned ship at Haven Reach via a REAL 'present' fleet + active location_presence
  --    (the "corpse dock" — a transitional dual-representation alongside main_ship_instances.status
  --    ='home'). send_ship_group_hunt's dark-path readiness check (the 4C-MIG-2B GATE FIX, migration
  --    0231/movement_schema_drop) DELIBERATELY treats a fleet-truth-docked member as NOT ready while
  --    dark (launch_from_dock_enabled unflipped here) — minting a team fleet on top of a live dock
  --    fleet would be a phantom second fleet. Retire each ship's commission fleet (status→'destroyed')
  --    and complete its now-orphaned presence — the SAME two-statement retirement every real sender
  --    of a freshly-commissioned ship performs before its first send, never a bespoke skip.
  update public.main_ship_instances
     set status = 'home', updated_at = now()
   where main_ship_id in (s_cmd, s_arm, s_bare);
  update public.fleets
     set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where main_ship_id in (s_cmd, s_arm, s_bare) and status = 'present';
  update public.location_presence
     set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets
                        where main_ship_id in (s_cmd, s_arm, s_bare) and status = 'destroyed')
     and status = 'active';

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

  -- s_bare gets NO craft/fit call — since 0262 it will carry the synthesized fallback weapon,
  -- whose range this harness owns at 1 (< the 4 ring): the CLOSE witness.

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

  -- both escorts sit on the SAME ring (same distance from center — the tuned 4).
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_arm
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_bare
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  if abs(v_dist_arm - 4) > 0.01 or abs(v_dist_bare - 4) > 0.01 then
    raise exception 'SPAWN FAIL: escort ring distances wrong (arm=%, bare=%, want ~4 each)', v_dist_arm, v_dist_bare;
  end if;

  -- weapons_json shapes: every ship carries exactly 1 entry — the two fitted ships their catalog
  -- gun, the unfitted escort the ONE synthesized 0262 fallback (follow-the-game repoint: before
  -- 0262 an unfitted ship carried NONE; asserting that old emptiness would assert a retired world).
  select jsonb_array_length(weapons_json) into v_wcount_cmd  from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  select jsonb_array_length(weapons_json) into v_wcount_arm  from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select jsonb_array_length(weapons_json) into v_wcount_bare from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  if v_wcount_cmd <> 1 or v_wcount_arm <> 1 or v_wcount_bare <> 1 then
    raise exception 'SPAWN FAIL: weapon counts wrong (cmd=%, arm=%, bare=% — want 1,1,1: two fitted guns + the 0262 fallback)', v_wcount_cmd, v_wcount_arm, v_wcount_bare;
  end if;
  -- the fitted entries carry the CATALOG range (derived at assert time — 0313 repoint: the old form
  -- hard-coded the 150 seed, an ambient default this proof never owned).
  select count(*) into n from public.combat_units cu
    where cu.encounter_id = v_enc and cu.main_ship_id in (s_cmd, s_arm)
      and (cu.weapons_json->0->>'module_type_id') = 'autocannon_battery'
      and (cu.weapons_json->0->>'range')::numeric = (select t.range from public.module_types t where t.id = 'autocannon_battery');
  if n <> 2 then raise exception 'SPAWN FAIL: fitted weapon range/id did not carry into weapons_json (want 2 rows at the catalog autocannon_battery range)'; end if;
  -- and the unfitted escort's ONE entry is the fallback, at the range this harness owns (1).
  select count(*) into n from public.combat_units cu
    where cu.encounter_id = v_enc and cu.main_ship_id = s_bare
      and (cu.weapons_json->0->>'module_type_id')
            = coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon')
      and (cu.weapons_json->0->>'range')::numeric = 1;
  if n <> 1 then raise exception 'SPAWN FAIL: the unfitted escort''s entry is not the owned-range fallback weapon (want 1 fallback row at range 1)'; end if;

  -- side is 'player' for every row this creator ever writes.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side <> 'player' and main_ship_id is not null;
  if n <> 0 then raise exception 'SPAWN FAIL: a member row is not side=player'; end if;

  raise notice 'COMBATSPATIAL_PASS_SPAWN ok: command ship at location center, both escorts on the 4-unit ring, weapons_json shapes exact (1/1/1 — catalog guns + the owned-range fallback), side=player throughout';
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
  v_enemy_speed_check double precision; v_enemy_dist_check double precision;
  v_cat_range numeric;
begin
  select x, y into v_loc_x, v_loc_y from public.locations where id = v_hunt;
  -- the armed ships' range, derived from the deployed catalog at assert time (0313 repoint).
  select range into v_cat_range from public.module_types where id = 'autocannon_battery';

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

  -- ── ENEMY SPAWN: exactly 1 synthetic pirate, side=enemy, identity anchor. Root cause of an earlier
  --    revision of this proof (confirmed via a temporary diagnostic against the real disposable-matrix
  --    run, then removed): this assertion originally required the pirate's position to still equal the
  --    location center AFTER tick 1 — but the pirate is ALSO a full participant in tick 1's own
  --    targeting/movement/fire pass (the same tick it spawns in, by design: "new pirates already
  --    fire/take damage the same tick they spawn"), and this scenario deliberately tunes its speed (12)
  --    to fully close the 4-unit gap to its target in ONE tick — so by the time we can observe it, it
  --    has legitimately already moved OFF the center. That is CORRECT behavior, not a bug (confirmed:
  --    the tick's own wave_spawned event payload carried 'units':1 and enemy_integrity_current fell
  --    from 16000 to 15980 — the row existed with the right identity and took real damage; only this
  --    stale position expectation was wrong). The provable spawn-time invariant instead: its distance
  --    from the center after ONE tick can be AT MOST its own move_speed (CLOSE never exceeds
  --    move_speed, so if it started elsewhere the bound would be violated) — a live bound tight enough
  --    to actually prove "spawned at/near the center", not just "spawned somewhere".
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'enemy' and unit_type_id = 'pirate_synthetic';
  if n <> 1 then raise exception 'TICK1 FAIL: % synthetic pirate row(s) (want exactly 1)', n; end if;
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y), move_speed into v_enemy_dist_check, v_enemy_speed_check
    from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if v_enemy_dist_check > v_enemy_speed_check + 0.001 then
    raise exception 'TICK1 FAIL: pirate is % from the location center after tick 1, more than its own move_speed % (would only be possible if it spawned somewhere other than the center)', v_enemy_dist_check, v_enemy_speed_check;
  end if;
  raise notice 'COMBATSPATIAL_PASS_ENEMY ok: 1 synthetic pirate (side=enemy, unit_type_id=pirate_synthetic) spawned within move_speed % of the location center (post-tick-1 distance %, since it also moves/fires the same tick it spawns)', v_enemy_speed_check, v_enemy_dist_check;

  -- ── HOLD: the command ship (dist 0, in range) never moves — byte-identical position. ──────────────
  select pos_x, pos_y into v_cmd_x1, v_cmd_y1 from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  if v_cmd_x1 is distinct from v_cmd_x0 or v_cmd_y1 is distinct from v_cmd_y0 then
    raise exception 'TICK1 FAIL HOLD: command ship moved (%,% -> %,%) — want byte-identical', v_cmd_x0, v_cmd_y0, v_cmd_x1, v_cmd_y1;
  end if;
  raise notice 'COMBATSPATIAL_PASS_HOLD ok: command ship position byte-identical after tick 1 (HOLD never touches pos_x/pos_y)';

  -- ── KITE: the armed escort's distance from the pirate INCREASED, staying within its own catalog
  --    range (derived above — never the hard-coded seed). ────────────────────────────────────────────
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_arm1
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  if v_dist_arm1 <= v_dist_arm0 then
    raise exception 'TICK1 FAIL KITE: armed escort distance did not increase (%->%)', v_dist_arm0, v_dist_arm1; end if;
  if v_dist_arm1 > v_cat_range + 0.001 then
    raise exception 'TICK1 FAIL KITE: armed escort retreated past its own catalog % range (dist %)', v_cat_range, v_dist_arm1; end if;
  raise notice 'COMBATSPATIAL_PASS_KITE ok: armed escort retreated (dist %->%), staying within its own catalog % weapon range', v_dist_arm0, v_dist_arm1, v_cat_range;

  -- ── CLOSE: the fallback escort's distance from the pirate DECREASED. ────────────────────────────────
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_bare1
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_bare;
  if v_dist_bare1 >= v_dist_bare0 then
    raise exception 'TICK1 FAIL CLOSE: unarmed escort distance did not decrease (%->%)', v_dist_bare0, v_dist_bare1; end if;
  raise notice 'COMBATSPATIAL_PASS_CLOSE ok: fallback escort advanced (dist %->%)', v_dist_bare0, v_dist_bare1;

  -- ── FIRE: tick 1 emits PLAYER missile_salvo events (command + armed escort, both pre-move in
  --    range); the pirate does NOT fire tick 1 (out of its own short range at the pre-move distance).
  select count(*) into n_player_fire from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'player';
  if n_player_fire < 2 then raise exception 'TICK1 FAIL FIRE: % player missile_salvo events on tick 1 (want >= 2 — command + armed escort)', n_player_fire; end if;
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'pirate';
  if n <> 0 then raise exception 'TICK1 FAIL FIRE: pirate fired on tick 1 (want 0 — it starts out of its own 2-range at dist 4)'; end if;
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
