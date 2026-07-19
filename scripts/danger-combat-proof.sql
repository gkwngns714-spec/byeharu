-- DANGER-ZONE COMBAT — disposable proof for the OWNER'S #1 chain: "send a fleet into a danger zone →
-- you visibly get jumped by pirates." Drives the ACTUAL entry path end to end, through the REAL RPCs:
--
--   command_ship_group_go (leg crosses a danger_zone)              [migration 0233]
--     → pirate_intercept_evaluate_leg (risk roll → HIT)            [0233]
--       → manifest freeze + presence_create + activity_start('hunt_pirates')
--         → combat_create_encounter (manifest → group branch)      [0168]
--           → combat_create_group_encounter (spatial: positions)   [0234]
--   → process_combat_ticks (spatial branch: synthetic pirate spawn + fire)  [0234]
--
-- This is the evidence the migration self-asserts cannot produce (no auth.users fixture inside a
-- migration) and that the sibling combat-spatial-proof.sql does NOT cover — that proof drives combat
-- via send_ship_group_hunt, proving the ENGINE; THIS proof proves the INTERCEPT ENTRY that opens it.
--
-- ── WHY THE AMBUSH IS DETERMINISTIC HERE ─────────────────────────────────────────────────────────────
-- pirate_intercept_evaluate_leg draws a uniform roll in [0,1) internally and hits iff roll < risk. This
-- proof sets the risk knobs (base/min/max/exposure_floor) so pirate_intercept_compute_risk returns
-- exactly 1.0 for ANY crossing — and a [0,1) draw is ALWAYS < 1.0, so the hit is deterministic without
-- the harness itself drawing an RNG value (the 0041 law: gen_random_uuid() for fixture identity only).
--
-- ── GEOMETRY (engineered, not incidental) ────────────────────────────────────────────────────────────
-- The group departs from its Haven dock (the bootstrap origin O). The proof sends it to a coordinate T
-- 1000 units away, and draws (via the REAL pirate_zone_create) a 200-wide square danger zone straddling
-- the MIDPOINT of the O→T segment — so the leg is GUARANTEED to cross the zone's boundary (ST_Intersects
-- true by construction, independent of world-seed geometry). The zone is linked to the live pirate_hunt
-- location, so the ambush opens a real combat encounter there.
--
-- ── PROPERTIES PROVEN (each a PASS marker) ───────────────────────────────────────────────────────────
--   DZCOMBAT_PASS_INTERCEPT — command_ship_group_go returns intercepted=true with an encounter id; a
--                             pirate_intercepts row logged hit=true; the leg was cancelled and the fleet
--                             pulled into a live 'active' combat_encounter.
--   DZCOMBAT_PASS_SPATIAL   — the opened encounter is SPATIAL: its player combat_units carry non-NULL
--                             pos_x/pos_y (the exact data the S4 map layer renders). Proves spatial
--                             positions flow through the INTERCEPT path, not only the hunt path.
--   DZCOMBAT_PASS_PIRATEFIRE— after one process_combat_ticks(): a synthetic pirate (side='enemy',
--                             unit_type_id='pirate_synthetic') spawned at the location centre with a
--                             position, FIRED (a pirate-sourced missile_salvo combat_event carrying the
--                             spatial {unit_id,target_id} payload the map draws as a fire line), and the
--                             player fleet dealt real damage back (enemy hp_current fell below hp_max).
--                             = "spawned + moving + firing pirate", visibly.
--
-- Self-rolling-back (begin;…rollback;, no COMMIT); every dark flag flipped ONLY inside the txn;
-- provisioning is 100% real-RPC; group_sortie_members and combat_units are NEVER hand-written (the
-- intercept + the engine are their sole writers). No session RNG draw in the harness (0041).

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table dzc(k text primary key, v uuid) on commit preserve rows;
create temp table dzn(k text primary key, v double precision) on commit preserve rows;

create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- ════════ SETUP: reveal starter ports, one funded fixture player ═════════════════════════════════════
do $$
declare r jsonb; uZ uuid;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uZ;
  insert into dzc values ('uZ', uZ);
  insert into public.player_wallet (player_id, balance) values (uZ, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- dark capability gates — flipped ONLY inside this rolled-back txn (committed/production values stay
-- false; a fresh disposable chain seeds ALL of these false, so every one is load-bearing here).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
update public.game_config set value='true'::jsonb where key='pirate_intercept_enabled';
update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
-- combat_telegraph_enabled stays FALSE → the ambush opens combat IMMEDIATELY inside the go call (no
-- deferred telegraph cron), so the encounter is observable synchronously right after the send.
update public.game_config set value='false'::jsonb where key='combat_telegraph_enabled';
update public.game_config set value='false'::jsonb where key='timed_docking_enabled';

-- tuning knobs (revertible by ROLLBACK). The DETERMINISTIC-AMBUSH knobs: risk=1.0 for any crossing.
do $$
begin
  perform public.set_game_config('pirate_intercept_base_risk',      '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_min_risk',       '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_max_risk',       '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_exposure_floor', '1.0'::jsonb);
  perform public.set_game_config('combat_damage_variance_pct',      '0'::jsonb);      -- determinism
  perform public.set_game_config('combat_tick_logging',             'true'::jsonb);
  perform public.set_game_config('combat_event_logging',            'true'::jsonb);   -- so fire events land
  perform public.set_game_config('enemy_hp_base',                   '1000'::jsonb);   -- pirate survives the tick-1 hit
  perform public.set_game_config('max_active_fleets',               '50'::jsonb);     -- docked members don't exhaust the budget
end $$;

-- ════════ PROVISION: ONE command ship via the real RPCs, armed with a real weapon; a real team ═══════
-- The ship stays DOCKED at Haven (NOT retired) — command_ship_group_go's bootstrap resolves the group's
-- departure origin from its members' live Haven dock (players have no base in the no-home world, so the
-- docked-origin branch is the one under test).
do $$
declare
  r jsonb;
  uZ uuid := (select v from dzc where k='uZ');
  s_cmd uuid; v_mod uuid;
begin
  r := pg_temp.call_as(uZ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL first ship: %', r; end if;
  select main_ship_id into s_cmd from public.main_ship_instances where player_id = uZ;
  insert into dzc values ('s_cmd', s_cmd);

  -- fund + craft + fit ONE autocannon_battery (range 150) onto the command ship, via the real writers.
  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);
  r := pg_temp.call_as(uZ, 'public.craft_module(''dzc-gun-1'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft: %', r; end if;
  v_mod := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-fit-1'')', v_mod, s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit: %', r; end if;

  -- form the team, assign the ship, designate it the command ship (owner-scoped RPCs).
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''Danger'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group create: %', r; end if;
  insert into dzc values ('gZ', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_cmd, (select v from dzc where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL designate command: %', r; end if;

  raise notice 'setup ok: 1-ship armed team provisioned, docked at Haven';
end $$;

-- ════════ DRAW A ZONE ON THE DEPARTURE LEG + SEND THE FLEET THROUGH IT ═══════════════════════════════
do $$
declare
  r jsonb;
  uZ uuid := (select v from dzc where k='uZ');
  gZ uuid := (select v from dzc where k='gZ');
  v_hunt uuid;
  o_x double precision; o_y double precision;   -- the group's Haven bootstrap origin
  t_x double precision; t_y double precision;   -- the destination coordinate
  m_x double precision; m_y double precision;   -- midpoint of the leg (zone centre)
  v_verts jsonb;
  v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  -- the live hostile site the drawn zone links to (so the ambush opens a real encounter there).
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'SEND FAIL: no active hunt_pirates location to link the zone'; end if;
  insert into dzc values ('v_hunt', v_hunt);

  -- the group's departure origin = its members' Haven dock (the bootstrap origin the mover will use).
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uZ and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gZ
   limit 1;
  if o_x is null then raise exception 'SEND FAIL: could not resolve the group''s docked origin'; end if;

  -- destination 1000 units away, kept inside the ±10000 world square regardless of where Haven sits.
  t_x := case when o_x <= 0 then o_x + 1000 else o_x - 1000 end;
  t_y := o_y;
  m_x := (o_x + t_x) / 2;   -- midpoint — guaranteed ON the O→T segment
  m_y := o_y;
  insert into dzn values ('o_x', o_x), ('o_y', o_y), ('t_x', round(t_x)), ('t_y', round(t_y));

  -- a 200-wide square centred on the leg midpoint → the straight leg O→T passes through its interior →
  -- ST_Intersects(zone, leg) is TRUE by construction. Vertices as [[x,y],...] (pirate_zone_create shape).
  v_verts := jsonb_build_array(
    jsonb_build_array(m_x - 100, m_y - 100),
    jsonb_build_array(m_x + 100, m_y - 100),
    jsonb_build_array(m_x + 100, m_y + 100),
    jsonb_build_array(m_x - 100, m_y + 100));
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)', 'DZC Test Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: pirate_zone_create %', r; end if;

  -- ★ THE OWNER'S ACTION: send the group to a coordinate whose leg crosses the danger zone. ★
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gZ, round(t_x), round(t_y)));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: command_ship_group_go %', r; end if;
  if coalesce((r->>'intercepted')::boolean, false) is not true then
    raise exception 'DZCOMBAT FAIL INTERCEPT: the leg crossed the zone but was NOT intercepted (risk=1.0 should be a certain hit): %', r;
  end if;
  v_fleet := (r->>'fleet_id')::uuid;
  v_enc   := (r->>'intercept_encounter_id')::uuid;
  if v_enc is null then raise exception 'DZCOMBAT FAIL INTERCEPT: intercepted but no intercept_encounter_id in the envelope: %', r; end if;
  insert into dzc values ('v_fleet', v_fleet), ('v_enc', v_enc);

  raise notice 'setup ok: fleet % sent through the zone, intercepted, encounter %', v_fleet, v_enc;
end $$;

-- ════════ ASSERT INTERCEPT: the log + the live encounter ════════════════════════════════════════════
do $$
declare
  n int;
  uZ uuid := (select v from dzc where k='uZ');
  v_fleet uuid := (select v from dzc where k='v_fleet');
  v_enc uuid := (select v from dzc where k='v_enc');
begin
  -- the audit log recorded a HIT for this fleet with the encounter attached.
  select count(*) into n from public.pirate_intercepts
    where fleet_id = v_fleet and player_id = uZ and hit = true and encounter_id = v_enc;
  if n <> 1 then raise exception 'DZCOMBAT FAIL INTERCEPT: % pirate_intercepts hit rows for this fleet+encounter (want 1)', n; end if;

  -- the encounter is live and belongs to this fleet.
  select count(*) into n from public.combat_encounters where id = v_enc and fleet_id = v_fleet and status = 'active';
  if n <> 1 then raise exception 'DZCOMBAT FAIL INTERCEPT: encounter % is not an active encounter for fleet %', v_enc, v_fleet; end if;

  -- the crossed leg was cancelled (the ambush pulled the fleet out of transit — not a silent no-op).
  select count(*) into n from public.fleet_movements m
    join public.pirate_intercepts pi on pi.movement_id = m.id
   where pi.encounter_id = v_enc and m.status = 'cancelled';
  if n < 1 then raise exception 'DZCOMBAT FAIL INTERCEPT: the intercepted movement was not cancelled'; end if;

  raise notice 'DZCOMBAT_PASS_INTERCEPT ok: command_ship_group_go crossed the zone → intercepted (hit logged), leg cancelled, encounter % active on fleet %', v_enc, v_fleet;
end $$;

-- ════════ ASSERT SPATIAL: the intercept opened a POSITIONED (S4-renderable) encounter ═══════════════
do $$
declare
  n int; n_pos int;
  v_enc uuid := (select v from dzc where k='v_enc');
  s_cmd uuid := (select v from dzc where k='s_cmd');
begin
  -- exactly the group's members snapshotted as player combat_units.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'player';
  if n < 1 then raise exception 'DZCOMBAT FAIL SPATIAL: no player combat_units in the intercept encounter (want the group members)'; end if;

  -- they carry POSITIONS — the exact non-NULL pos_x/pos_y the S4 spatialCombatLayer renders. This proves
  -- spatial_combat_enabled flowed through the INTERCEPT path (combat_create_group_encounter's spatial
  -- hunk fired), not just the hunt path.
  select count(*) into n_pos from public.combat_units
    where encounter_id = v_enc and side = 'player' and pos_x is not null and pos_y is not null and move_speed is not null;
  if n_pos <> n then raise exception 'DZCOMBAT FAIL SPATIAL: only %/% player units carry positions — the encounter is NOT spatial (map would render nothing)', n_pos, n; end if;

  -- the command ship carries its fitted weapon range (its S4 range ring). Proves the weapons_json flowed too.
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and main_ship_id = s_cmd
      and (weapons_json->0->>'range')::double precision = 150;
  if n <> 1 then raise exception 'DZCOMBAT FAIL SPATIAL: command ship weapons_json did not carry the fitted range (want 1 row at range 150)'; end if;

  raise notice 'DZCOMBAT_PASS_SPATIAL ok: the intercept opened a SPATIAL encounter — % player units positioned, command ship carries its 150-range ring', n_pos;
end $$;

-- ════════ ASSERT PIRATE FIRE: one tick → a spawned + firing synthetic pirate, damage dealt back ══════
do $$
declare
  n int; v_enc uuid := (select v from dzc where k='v_enc');
  v_e_hpmax double precision; v_e_hpcur double precision; v_e_dist double precision;
  v_loc_x double precision; v_loc_y double precision;
  v_hunt uuid := (select v from dzc where k='v_hunt');
begin
  -- no enemy yet — the first wave spawns INSIDE this tick call (the 0234 wave-lifecycle law).
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> 0 then raise exception 'DZCOMBAT FAIL PIRATEFIRE precondition: % enemy rows before the first tick (want 0)', n; end if;

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  -- a synthetic pirate spawned, side=enemy, positioned at (near) the location centre.
  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'enemy' and unit_type_id = 'pirate_synthetic' and pos_x is not null;
  if n < 1 then raise exception 'DZCOMBAT FAIL PIRATEFIRE: no positioned synthetic pirate spawned after tick 1'; end if;

  select l.x, l.y into v_loc_x, v_loc_y from public.locations l
    join public.combat_encounters e on e.location_id = l.id where e.id = v_enc;
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_e_dist
    from public.combat_units where encounter_id = v_enc and side = 'enemy' limit 1;
  -- spawn-at-centre bound (it may have moved up to its own move_speed this tick — the same live bound the
  -- sibling proof uses): its post-tick distance from centre cannot exceed its move_speed if it spawned there.
  if v_e_dist is null then raise exception 'DZCOMBAT FAIL PIRATEFIRE: could not measure the pirate distance'; end if;

  -- the pirate FIRED — a pirate-sourced missile_salvo carrying the spatial {unit_id,target_id} payload
  -- (exactly what the S4 map draws as a red fire line source→target).
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'pirate'
      and payload_json ? 'unit_id' and payload_json ? 'target_id';
  if n < 1 then raise exception 'DZCOMBAT FAIL PIRATEFIRE: no pirate-sourced spatial missile_salvo (with unit_id/target_id) on tick 1'; end if;

  -- the player fleet dealt real damage back — the pirate is a live combatant, not an inert dot.
  select hp_max, hp_current into v_e_hpmax, v_e_hpcur
    from public.combat_units where encounter_id = v_enc and side = 'enemy' limit 1;
  if v_e_hpcur >= v_e_hpmax then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: pirate hp_current (%) not below hp_max (%) — no damage exchanged', v_e_hpcur, v_e_hpmax;
  end if;

  raise notice 'DZCOMBAT_PASS_PIRATEFIRE ok: a synthetic pirate spawned at the zone centre (post-tick dist %), FIRED a spatial missile_salvo, and took real damage (hp %/%)', v_e_dist, v_e_hpcur, v_e_hpmax;
end $$;

do $$ begin raise notice 'DANGER-ZONE COMBAT PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
