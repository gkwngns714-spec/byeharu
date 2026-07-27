-- DANGER-ZONE COMBAT — disposable proof for the OWNER'S #1 chain: "send a fleet into a danger zone →
-- you get jumped by pirates WHERE you meet the zone, WHEN you get there." Drives the ACTUAL entry
-- path end to end, through the REAL RPCs:
--
--   command_ship_group_go (leg crosses a danger_zone)                    [0233/0292/0301]
--     → pirate_intercept_plan_leg (risk roll → a PENDING ambush)         [0301]
--   ... the fleet TRAVELS ...
--   process_fleet_movements (due-intercept scan)                         [0301]
--     → movement_advance → pirate_intercept_resolve_due_for_movement     [0301]
--       → manifest freeze + presence_create + activity_start('hunt_pirates')
--         → combat_create_encounter (resolves the engagement point)      [0168/0301]
--           → combat_create_group_encounter (MANDATORY point, spatial)   [0293/0301]
--   → process_combat_ticks (spatial branch: synthetic pirate spawn + fire)
--
-- ── WHAT CHANGED IN 0301, AND WHY THIS FILE CHANGED WITH IT ──────────────────────────────────────────
-- Before 0301 the ambush happened INSIDE the go call: the RPC returned intercepted=true and an
-- encounter id, and this proof asserted exactly that. That was the defect — the fleet never travelled.
-- The go call now starts a real journey and returns order_outcome='movement_started', and the ambush
-- fires later, from the movement processor, at the point where the leg first ENTERS the zone. So the
-- properties this file proves are the new ones, and several of them are proofs that the OLD behaviour
-- is gone.
--
-- ── WHY THE AMBUSH IS DETERMINISTIC HERE ─────────────────────────────────────────────────────────────
-- pirate_intercept_plan_leg draws a uniform roll in [0,1) and plans iff roll < risk. This proof sets
-- the risk knobs so pirate_intercept_compute_risk returns exactly 1.0 for ANY crossing — a [0,1) draw
-- is ALWAYS < 1.0 — so the plan is certain without the harness itself drawing an RNG value (0041 law).
--
-- ── HOW TIME IS CONTROLLED ───────────────────────────────────────────────────────────────────────────
-- No sleeping. The harness first ASSERTS that the planner's trigger_at is exactly
-- depart_at + (arrive_at - depart_at) * entry_fraction — i.e. it proves the schedule it is about to
-- manipulate — and only then TIME-TRAVELS the leg by shifting depart_at, arrive_at and trigger_at by
-- the SAME interval. That is "the fleet set off earlier", not "the ambush was moved".
--
-- ── PROPERTIES PROVEN (each a PASS marker) ───────────────────────────────────────────────────────────
--   DZCOMBAT_PASS_ORDER      — at order commit: order_outcome='movement_started', NO `intercepted` and
--                              NO `intercept_encounter_id` in the envelope, the movement is still
--                              'moving', the fleet is still 'moving' and has NOT been parked, NO
--                              encounter exists, and exactly ONE 'pending' pirate_intercepts row was
--                              written carrying an entry point ON the zone boundary and a trigger_at
--                              that is the exact interpolation of the leg's own clock.
--   DZCOMBAT_PASS_NOTYET     — a full process_fleet_movements() run BEFORE trigger_at creates NO
--                              encounter, leaves the row 'pending' and the movement 'moving'.
--   DZCOMBAT_PASS_FIRE       — with BOTH trigger_at and arrive_at in the past, ONE processor run fires
--                              the ambush INSTEAD of settling the arrival: row 'fired', movement
--                              'cancelled' (not 'arrived'), fleet parked in open space AT the recorded
--                              entry point (not at the destination), one active encounter, and the
--                              plotted route queue abandoned.
--   DZCOMBAT_PASS_ENGAGEMENT — combat_encounters.engagement_x/y EQUAL the recorded entry point, the
--                              command ship's combat_unit sits exactly on it, and the encounter row's
--                              location_id is still the linked location (identity, not position).
--   DZCOMBAT_PASS_ONCE       — a second processor run and a direct second resolve create no second
--                              encounter and cannot re-fire a terminal row.
--   DZCOMBAT_PASS_EVASION    — on a SECOND fleet: STOP before due cancels the owed ambush; a re-order
--                              before due cancels it and plans a fresh one on the new leg; STOP after
--                              it is due is REFUSED (intercepted_in_transit) and the ambush fires.
--   DZCOMBAT_PASS_SPATIAL    — the opened encounter is SPATIAL: player combat_units carry non-NULL
--                              pos_x/pos_y and the command ship carries its fitted weapon range.
--   DZCOMBAT_PASS_PIRATEFIRE — after one process_combat_ticks(): a synthetic pirate spawned, FIRED a
--                              spatial missile_salvo, and took real damage back.
--
-- Self-rolling-back (begin;…rollback;, no COMMIT); every dark flag flipped ONLY inside the txn;
-- provisioning is 100% real-RPC; group_sortie_members and combat_units are NEVER hand-written.
-- No session RNG draw in the harness (0041).

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

-- TIME TRAVEL: move a leg and everything it owes backwards by the same interval. This is the ONLY
-- clock manipulation in the file and it never changes WHERE anything happens.
create or replace function pg_temp.rewind_leg(p_mv uuid, p_by interval) returns void language plpgsql as $$
begin
  update public.fleet_movements
     set depart_at = depart_at - p_by, arrive_at = arrive_at - p_by
   where id = p_mv;
  update public.pirate_intercepts
     set trigger_at = trigger_at - p_by
   where movement_id = p_mv and lifecycle_state = 'pending';
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
-- as they are; a fresh disposable chain seeds these false, so every one is load-bearing here).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
update public.game_config set value='true'::jsonb where key='pirate_intercept_enabled';
update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
-- combat_telegraph_enabled stays FALSE → when the ambush FIRES the encounter opens in that same
-- resolution, so it is observable synchronously right after the processor run.
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
  perform public.set_game_config('enemy_hp_base',                   '1000'::jsonb);   -- pirate survives tick 1
  perform public.set_game_config('max_active_fleets',               '50'::jsonb);
end $$;

-- ════════ PROVISION: TWO command ships via the real RPCs, TWO teams ══════════════════════════════════
-- Team A carries the main scenario through to combat. Team B is kept clear for the STOP / re-order /
-- evasion scenario, which needs a fleet that is not already in a fight.
do $$
declare
  r jsonb;
  uZ uuid := (select v from dzc where k='uZ');
  s_cmd uuid; s_b uuid; v_mod uuid;
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

  -- team A
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''Danger'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group create: %', r; end if;
  insert into dzc values ('gZ', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_cmd, (select v from dzc where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_cmd));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL designate command: %', r; end if;

  -- a SECOND ship + team B for the stop/re-order/evasion scenario.
  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL second ship: %', r; end if;
  select main_ship_id into s_b from public.main_ship_instances
   where player_id = uZ and main_ship_id <> s_cmd limit 1;
  if s_b is null then raise exception 'PROVISION FAIL: no second ship materialised'; end if;
  insert into dzc values ('s_b', s_b);
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(2, ''Danger B'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group B create: %', r; end if;
  insert into dzc values ('gB', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_b, (select v from dzc where k='gB')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign B: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_b));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL designate command B: %', r; end if;

  raise notice 'setup ok: two teams provisioned, docked at Haven (team A armed)';
end $$;

-- ════════ DRAW A ZONE ON THE DEPARTURE LEG + ORDER THE FLEET THROUGH IT ══════════════════════════════
-- GEOMETRY, engineered rather than incidental: the group departs from its Haven dock (origin O) and is
-- sent to a coordinate T 1000 units away. A 200-wide square zone straddles the MIDPOINT of O→T, so the
-- leg is guaranteed to pass through its interior — and, decisively for 0301, the zone's near EDGE is
-- 100 units before its CENTRE. The entry point and the old centroid foot are therefore provably
-- different points, and the proof below pins the entry one.
do $$
declare
  r jsonb;
  uZ uuid := (select v from dzc where k='uZ');
  gZ uuid := (select v from dzc where k='gZ');
  v_hunt uuid;
  o_x double precision; o_y double precision;
  t_x double precision; t_y double precision;
  m_x double precision; m_y double precision;
  v_verts jsonb;
begin
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'SEND FAIL: no active hunt_pirates location to link the zone'; end if;
  insert into dzc values ('v_hunt', v_hunt);

  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uZ and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gZ
   limit 1;
  if o_x is null then raise exception 'SEND FAIL: could not resolve the group''s docked origin'; end if;

  t_x := case when o_x <= 0 then o_x + 1000 else o_x - 1000 end;
  t_y := o_y;
  m_x := (o_x + t_x) / 2;
  m_y := o_y;
  insert into dzn values ('o_x', o_x), ('o_y', o_y), ('t_x', round(t_x)), ('t_y', round(t_y)),
                         ('m_x', m_x), ('m_y', m_y);

  v_verts := jsonb_build_array(
    jsonb_build_array(m_x - 100, m_y - 100),
    jsonb_build_array(m_x + 100, m_y - 100),
    jsonb_build_array(m_x + 100, m_y + 100),
    jsonb_build_array(m_x - 100, m_y + 100));
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)', 'DZC Test Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: pirate_zone_create %', r; end if;
  insert into dzc values ('v_zone', (r->>'zone_id')::uuid);

  -- ★ THE OWNER'S ACTION: send the group to a coordinate whose leg crosses the danger zone. It is a
  -- ★ ROUTE, so the "an ambush abandons the rest of the plotted route" property is observable too.
  r := pg_temp.call_as(uZ, format(
        'public.command_ship_group_go_route(%L::uuid, %L::jsonb, null, %s, %s)',
        gZ,
        jsonb_build_array(jsonb_build_object('x', round(t_x), 'y', round(t_y)))::text,
        round(t_x), round(t_y) + 50));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: command_ship_group_go_route %', r; end if;
  insert into dzc values ('v_fleet', (r->>'fleet_id')::uuid), ('v_mv', (r->>'movement_id')::uuid);
  insert into dzc values ('r_order', gen_random_uuid());
  create temp table dzr(k text primary key, v jsonb) on commit preserve rows;
  insert into dzr values ('order', r);
end $$;

-- ════════ DZCOMBAT_PASS_ORDER: the order STARTS A JOURNEY. It does not start a fight. ════════════════
do $$
declare
  r jsonb := (select v from dzr where k='order');
  n int;
  v_fleet uuid := (select v from dzc where k='v_fleet');
  v_mv uuid := (select v from dzc where k='v_mv');
  pi record; mv record; fl record;
  m_x double precision := (select v from dzn where k='m_x');
  v_expect timestamptz;
begin
  -- the envelope: the new contract, and the ABSENCE of the retired one.
  if (r->>'order_outcome') is distinct from 'movement_started' then
    raise exception 'DZCOMBAT FAIL ORDER: order_outcome is % (want movement_started): %', r->>'order_outcome', r;
  end if;
  if r ? 'intercepted' or r ? 'intercept_encounter_id' then
    raise exception 'DZCOMBAT FAIL ORDER: the envelope still carries the retired intercepted / intercept_encounter_id fields: %', r;
  end if;
  if (r->>'movement_id') is null or (r->>'movement_eta') is null then
    raise exception 'DZCOMBAT FAIL ORDER: the envelope lacks movement_id / movement_eta: %', r;
  end if;

  -- THE FLEET IS TRAVELLING. This is the whole defect, inverted into an assertion.
  select * into mv from public.fleet_movements where id = v_mv;
  if mv.status <> 'moving' then
    raise exception 'DZCOMBAT FAIL ORDER: the leg is % at order commit — the order-time ambush is still cancelling it', mv.status;
  end if;
  select * into fl from public.fleets where id = v_fleet;
  if fl.status <> 'moving' or fl.location_mode <> 'movement' or fl.active_movement_id is distinct from v_mv then
    raise exception 'DZCOMBAT FAIL ORDER: the fleet is %/% (active_movement %) at order commit — it was moved by the order', fl.status, fl.location_mode, fl.active_movement_id;
  end if;
  if fl.space_x is not null or fl.space_y is not null then
    raise exception 'DZCOMBAT FAIL ORDER: the fleet was PARKED at order time (space %,%) — fleet_set_in_space still runs on the order path', fl.space_x, fl.space_y;
  end if;

  -- NO COMBAT EXISTS YET, and no manifest was frozen.
  select count(*) into n from public.combat_encounters where fleet_id = v_fleet;
  if n <> 0 then raise exception 'DZCOMBAT FAIL ORDER: % encounter(s) already exist at order commit (want 0)', n; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 0 then raise exception 'DZCOMBAT FAIL ORDER: % manifest row(s) frozen at order commit (want 0)', n; end if;

  -- EXACTLY ONE OWED AMBUSH, and it is actionable.
  select count(*) into n from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if n <> 1 then raise exception 'DZCOMBAT FAIL ORDER: % pending intercept rows for this leg (want exactly 1)', n; end if;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi.entry_x is null or pi.entry_y is null or pi.entry_fraction is null or pi.trigger_at is null then
    raise exception 'DZCOMBAT FAIL ORDER: the pending row is not actionable (entry %,% fraction % trigger %)', pi.entry_x, pi.entry_y, pi.entry_fraction, pi.trigger_at;
  end if;

  -- THE POINT IS THE ZONE'S EDGE, NOT ITS CENTRE. The square's near edge is at m_x -/+ 100; the old
  -- centroid-foot formula would have answered m_x exactly.
  if abs(pi.entry_x - m_x) < 1e-6 then
    raise exception 'DZCOMBAT FAIL ORDER: the ambush point is the zone CENTRE (%) — the retired ST_ClosestPoint(leg, centroid) formula is still in play', pi.entry_x;
  end if;
  if abs(abs(pi.entry_x - m_x) - 100) > 1e-6 then
    raise exception 'DZCOMBAT FAIL ORDER: the ambush point is % — it is not on the zone boundary 100 units from the centre (%)', pi.entry_x, m_x;
  end if;

  -- THE TIME IS THE LEG'S OWN CLOCK, INTERPOLATED. Proven before any time travel touches it.
  v_expect := mv.depart_at + (mv.arrive_at - mv.depart_at) * pi.entry_fraction;
  if abs(extract(epoch from (pi.trigger_at - v_expect))) > 1e-3 then
    raise exception 'DZCOMBAT FAIL ORDER: trigger_at % is not depart + duration*entry_fraction (%)', pi.trigger_at, v_expect;
  end if;
  if pi.trigger_at <= now() then
    raise exception 'DZCOMBAT FAIL ORDER: the ambush is already due at order commit — the leg is too short to prove the deferral';
  end if;

  raise notice 'DZCOMBAT_PASS_ORDER ok: the order started a JOURNEY (movement % moving, fleet moving, unparked, zero encounters, zero manifest rows) and scheduled exactly ONE ambush at the zone EDGE (entry %,% at fraction %, trigger % = depart + duration*fraction) — not at the zone centre, and not now',
    v_mv, pi.entry_x, pi.entry_y, pi.entry_fraction, pi.trigger_at;
end $$;

-- ════════ DZCOMBAT_PASS_NOTYET: the processor does NOT fire before trigger_at ════════════════════════
do $$
declare
  n int;
  v_mv uuid := (select v from dzc where k='v_mv');
  v_fleet uuid := (select v from dzc where k='v_fleet');
begin
  perform public.process_fleet_movements();

  select count(*) into n from public.combat_encounters where fleet_id = v_fleet;
  if n <> 0 then raise exception 'DZCOMBAT FAIL NOTYET: % encounter(s) opened before trigger_at', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if n <> 1 then raise exception 'DZCOMBAT FAIL NOTYET: the owed ambush is no longer pending (% rows) before trigger_at', n; end if;
  select count(*) into n from public.fleet_movements where id = v_mv and status = 'moving';
  if n <> 1 then raise exception 'DZCOMBAT FAIL NOTYET: the leg stopped being ''moving'' before trigger_at'; end if;

  raise notice 'DZCOMBAT_PASS_NOTYET ok: a full process_fleet_movements() run before trigger_at opened no encounter, left the ambush pending and the leg moving';
end $$;

-- ════════ DZCOMBAT_PASS_FIRE: due → the ambush fires INSTEAD of the arrival ══════════════════════════
-- The rewind puts BOTH trigger_at AND arrive_at in the past, so this single processor run has the
-- arrival and the ambush available at the same instant. Firing must win — that is "arrival settlement
-- cannot precede intercept resolution", proven by outcome rather than by reading the source.
do $$
declare
  n int;
  v_mv uuid := (select v from dzc where k='v_mv');
  v_fleet uuid := (select v from dzc where k='v_fleet');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  pi record; mv record; fl record; v_enc uuid;
begin
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');

  perform public.process_fleet_movements();

  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi.lifecycle_state <> 'fired' then
    raise exception 'DZCOMBAT FAIL FIRE: the owed ambush is % after the processor run (want fired)', pi.lifecycle_state;
  end if;
  if pi.resolved_at is null then raise exception 'DZCOMBAT FAIL FIRE: a fired row carries no resolved_at'; end if;

  select * into mv from public.fleet_movements where id = v_mv;
  if mv.status <> 'cancelled' then
    raise exception 'DZCOMBAT FAIL FIRE: the leg is % — an arrival was settled past an ambush that was already owed', mv.status;
  end if;

  select * into fl from public.fleets where id = v_fleet;
  if fl.location_mode <> 'space' or fl.status <> 'idle' then
    raise exception 'DZCOMBAT FAIL FIRE: the ambushed fleet is %/% (want idle/space)', fl.status, fl.location_mode;
  end if;
  if abs(fl.space_x - pi.entry_x) > 1e-6 or abs(fl.space_y - pi.entry_y) > 1e-6 then
    raise exception 'DZCOMBAT FAIL FIRE: the fleet is parked at (%,%) but was ambushed at (%,%)', fl.space_x, fl.space_y, pi.entry_x, pi.entry_y;
  end if;
  if fl.current_location_id is not null then
    raise exception 'DZCOMBAT FAIL FIRE: the fleet is present at a location — it TELEPORTED instead of stopping where it was ambushed';
  end if;

  select count(*) into n from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if n <> 1 then raise exception 'DZCOMBAT FAIL FIRE: % active encounter(s) for the ambushed fleet (want 1)', n; end if;
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if pi.encounter_id is distinct from v_enc then
    raise exception 'DZCOMBAT FAIL FIRE: the intercept row does not record the encounter it opened';
  end if;
  insert into dzc values ('v_enc', v_enc);

  -- the rest of the plotted route was abandoned, not silently resumed later.
  select count(*) into n from public.fleet_route_legs where fleet_id = v_fleet;
  if n <> 0 then
    raise exception 'DZCOMBAT FAIL FIRE: % route leg(s) still queued for the ambushed fleet — the route would resume from an unplanned position', n;
  end if;

  raise notice 'DZCOMBAT_PASS_FIRE ok: with the arrival AND the ambush both due, one processor run FIRED the ambush (row fired, leg cancelled not arrived), parked the fleet at the recorded entry point (%,%), opened encounter % and abandoned the remaining route',
    pi.entry_x, pi.entry_y, v_enc;
end $$;

-- ════════ DZCOMBAT_PASS_ENGAGEMENT: one point, written once, by the creator ══════════════════════════
do $$
declare
  e record; pi record; cu record;
  v_mv uuid := (select v from dzc where k='v_mv');
  v_enc uuid := (select v from dzc where k='v_enc');
  s_cmd uuid := (select v from dzc where k='s_cmd');
  v_hunt uuid := (select v from dzc where k='v_hunt');
begin
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'fired';
  select * into e  from public.combat_encounters where id = v_enc;

  if e.engagement_x is null or abs(e.engagement_x - pi.entry_x) > 1e-6
     or e.engagement_y is null or abs(e.engagement_y - pi.entry_y) > 1e-6 then
    raise exception 'DZCOMBAT FAIL ENGAGEMENT: the encounter says the fight is at (%,%) but the fleet was ambushed at (%,%)',
      e.engagement_x, e.engagement_y, pi.entry_x, pi.entry_y;
  end if;
  -- IDENTITY is still the linked location; only POSITION moved.
  if e.location_id is distinct from v_hunt then
    raise exception 'DZCOMBAT FAIL ENGAGEMENT: the encounter lost its linked location identity';
  end if;

  -- the command ship is seeded EXACTLY on the engagement point (the 0234 formation rule), which is
  -- only true if the creator was handed the point rather than being corrected afterwards.
  select * into cu from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  if cu.pos_x is null or abs(cu.pos_x - e.engagement_x) > 1e-6
     or cu.pos_y is null or abs(cu.pos_y - e.engagement_y) > 1e-6 then
    raise exception 'DZCOMBAT FAIL ENGAGEMENT: the command ship sits at (%,%), not on the engagement point (%,%)',
      cu.pos_x, cu.pos_y, e.engagement_x, e.engagement_y;
  end if;

  raise notice 'DZCOMBAT_PASS_ENGAGEMENT ok: encounter.engagement_x/y = the recorded entry point (%,%), the command ship is seeded exactly on it, and the encounter still carries its linked location as IDENTITY',
    e.engagement_x, e.engagement_y;
end $$;

-- ════════ DZCOMBAT_PASS_ONCE: it cannot fire twice ══════════════════════════════════════════════════
do $$
declare
  n int; r jsonb;
  v_mv uuid := (select v from dzc where k='v_mv');
  v_fleet uuid := (select v from dzc where k='v_fleet');
begin
  perform public.process_fleet_movements();
  r := public.pirate_intercept_resolve_due_for_movement(v_mv);
  if coalesce((r->>'fired')::boolean, false) then
    raise exception 'DZCOMBAT FAIL ONCE: a terminal intercept row fired a SECOND time: %', r;
  end if;

  select count(*) into n from public.combat_encounters where fleet_id = v_fleet;
  if n <> 1 then raise exception 'DZCOMBAT FAIL ONCE: % encounters for the ambushed fleet after re-running the resolver (want 1)', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'fired';
  if n <> 1 then raise exception 'DZCOMBAT FAIL ONCE: % fired rows for one leg (want 1)', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if n <> 0 then raise exception 'DZCOMBAT FAIL ONCE: % rows still pending for a leg that already fired', n; end if;

  raise notice 'DZCOMBAT_PASS_ONCE ok: a second processor run and a direct second resolve produced no second encounter and could not re-fire the terminal row (the conditional claim + the UNIQUE one-pending-per-movement index)';
end $$;

-- ════════ DZCOMBAT_PASS_EVASION: STOP and RE-ORDER cannot outrun an ambush ══════════════════════════
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from dzc where k='uZ');
  gB uuid := (select v from dzc where k='gB');
  t_x double precision := (select v from dzn where k='t_x');
  t_y double precision := (select v from dzn where k='t_y');
  mv1 uuid; mv2 uuid; fB uuid; pi record; mv record;
begin
  -- B1. ORDER, then STOP BEFORE the ambush is due -> the owed ambush is CANCELLED, not left dangling.
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gB, t_x, t_y));
  if (r->>'ok')::boolean is not true then raise exception 'EVASION FAIL B1 send: %', r; end if;
  fB  := (r->>'fleet_id')::uuid;
  mv1 := (r->>'movement_id')::uuid;
  select count(*) into n from public.pirate_intercepts where movement_id = mv1 and lifecycle_state = 'pending';
  if n <> 1 then raise exception 'EVASION FAIL B1: % pending rows on the first leg (want 1)', n; end if;

  r := pg_temp.call_as(uZ, format('public.command_ship_group_stop(%L::uuid)', gB));
  if coalesce((r->>'stopped')::boolean, false) is not true then raise exception 'EVASION FAIL B1 stop: %', r; end if;
  select count(*) into n from public.pirate_intercepts
   where movement_id = mv1 and lifecycle_state = 'cancelled' and cancel_reason = 'player_stop';
  if n <> 1 then raise exception 'EVASION FAIL B1: stopping before the ambush was due did not cancel it as player_stop (% rows)', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = mv1 and lifecycle_state = 'pending';
  if n <> 0 then raise exception 'EVASION FAIL B1: % rows still pending on a cancelled leg', n; end if;

  -- B2. RE-ORDER BEFORE due -> the old leg's ambush is cancelled as superseded, and the NEW leg is
  --     planned from scratch (the player really did change course, and the new course is rolled).
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gB, t_x, t_y));
  if (r->>'ok')::boolean is not true then raise exception 'EVASION FAIL B2 send: %', r; end if;
  mv1 := (r->>'movement_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gB, t_x, t_y + 10));
  if (r->>'ok')::boolean is not true then raise exception 'EVASION FAIL B2 reorder: %', r; end if;
  mv2 := (r->>'movement_id')::uuid;
  if mv2 = mv1 then raise exception 'EVASION FAIL B2: the re-order did not mint a new leg'; end if;
  select count(*) into n from public.pirate_intercepts
   where movement_id = mv1 and lifecycle_state = 'cancelled' and cancel_reason = 'movement_superseded';
  if n <> 1 then raise exception 'EVASION FAIL B2: the superseded leg''s ambush was not cancelled (% rows)', n; end if;
  select count(*) into n from public.pirate_intercepts where movement_id = mv2 and lifecycle_state = 'pending';
  if n <> 1 then raise exception 'EVASION FAIL B2: the NEW leg was not re-planned (% pending rows)', n; end if;

  -- B3. NOW LET IT BECOME DUE, AND TRY TO STOP. The brake must be REFUSED and the ambush must fire.
  select * into mv from public.fleet_movements where id = mv2;
  perform pg_temp.rewind_leg(mv2, (mv.arrive_at - now()) + interval '5 seconds');
  r := pg_temp.call_as(uZ, format('public.command_ship_group_stop(%L::uuid)', gB));
  if coalesce((r->>'ok')::boolean, true) is not false or (r->>'reason') is distinct from 'intercepted_in_transit' then
    raise exception 'EVASION FAIL B3: stopping AFTER the ambush was due returned % — the evasion window is open', r;
  end if;
  select * into pi from public.pirate_intercepts where movement_id = mv2 order by created_at desc limit 1;
  if pi.lifecycle_state <> 'fired' then
    raise exception 'EVASION FAIL B3: the brake left the due ambush % instead of firing it', pi.lifecycle_state;
  end if;
  select count(*) into n from public.combat_encounters where fleet_id = fB and status = 'active';
  if n <> 1 then raise exception 'EVASION FAIL B3: % active encounter(s) for the fleet that tried to brake out of the ambush (want 1)', n; end if;

  raise notice 'DZCOMBAT_PASS_EVASION ok: STOP before due cancelled the owed ambush (player_stop); a re-order before due cancelled it (movement_superseded) and re-planned the new leg; STOP after it was due was REFUSED (intercepted_in_transit) and the ambush fired anyway';
end $$;

-- ════════ DZCOMBAT_PASS_SPATIAL: the intercept opened a POSITIONED (S4-renderable) encounter ════════
do $$
declare
  n int; n_pos int;
  v_enc uuid := (select v from dzc where k='v_enc');
  s_cmd uuid := (select v from dzc where k='s_cmd');
begin
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'player';
  if n < 1 then raise exception 'DZCOMBAT FAIL SPATIAL: no player combat_units in the intercept encounter (want the group members)'; end if;

  select count(*) into n_pos from public.combat_units
    where encounter_id = v_enc and side = 'player' and pos_x is not null and pos_y is not null and move_speed is not null;
  if n_pos <> n then raise exception 'DZCOMBAT FAIL SPATIAL: only %/% player units carry positions — the encounter is NOT spatial (map would render nothing)', n_pos, n; end if;

  select count(*) into n from public.combat_units
    where encounter_id = v_enc and main_ship_id = s_cmd
      and (weapons_json->0->>'range')::double precision = 150;
  if n <> 1 then raise exception 'DZCOMBAT FAIL SPATIAL: command ship weapons_json did not carry the fitted range (want 1 row at range 150)'; end if;

  raise notice 'DZCOMBAT_PASS_SPATIAL ok: the intercept opened a SPATIAL encounter — % player units positioned, command ship carries its 150-range ring', n_pos;
end $$;

-- ════════ DZCOMBAT_PASS_PIRATEFIRE: one tick → a spawned + firing pirate, damage dealt back ══════════
do $$
declare
  n int; v_enc uuid := (select v from dzc where k='v_enc');
  v_e_hpmax double precision; v_e_hpcur double precision; v_e_dist double precision;
  v_eng_x double precision; v_eng_y double precision;
begin
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> 0 then raise exception 'DZCOMBAT FAIL PIRATEFIRE precondition: % enemy rows before the first tick (want 0)', n; end if;

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  select count(*) into n from public.combat_units
    where encounter_id = v_enc and side = 'enemy' and unit_type_id = 'pirate_synthetic' and pos_x is not null;
  if n < 1 then raise exception 'DZCOMBAT FAIL PIRATEFIRE: no positioned synthetic pirate spawned after tick 1'; end if;

  -- the pirate spawns at the ENGAGEMENT point (the ambush), not at the location centre.
  select engagement_x, engagement_y into v_eng_x, v_eng_y from public.combat_encounters where id = v_enc;
  select public.osn_distance(pos_x, pos_y, v_eng_x, v_eng_y) into v_e_dist
    from public.combat_units where encounter_id = v_enc and side = 'enemy' limit 1;
  if v_e_dist is null then raise exception 'DZCOMBAT FAIL PIRATEFIRE: could not measure the pirate distance'; end if;

  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'pirate'
      and payload_json ? 'unit_id' and payload_json ? 'target_id';
  if n < 1 then raise exception 'DZCOMBAT FAIL PIRATEFIRE: no pirate-sourced spatial missile_salvo (with unit_id/target_id) on tick 1'; end if;

  select hp_max, hp_current into v_e_hpmax, v_e_hpcur
    from public.combat_units where encounter_id = v_enc and side = 'enemy' limit 1;
  if v_e_hpcur >= v_e_hpmax then
    raise exception 'DZCOMBAT FAIL PIRATEFIRE: pirate hp_current (%) not below hp_max (%) — no damage exchanged', v_e_hpcur, v_e_hpmax;
  end if;

  raise notice 'DZCOMBAT_PASS_PIRATEFIRE ok: a synthetic pirate spawned near the engagement point (post-tick dist %), FIRED a spatial missile_salvo, and took real damage (hp %/%)', v_e_dist, v_e_hpcur, v_e_hpmax;
end $$;

-- ════════ DZCOMBAT_PASS_REAMBUSH: the SECOND ambush of the same fleet still opens combat ════════════
-- THE REGRESSION THIS FILE EXISTS TO CATCH FROM NOW ON (added with migration 0303, 2026-07-27).
--
-- The owner hit this in the live game: combat fires the first time a fleet enters a danger zone and
-- never again, the fleet is yanked to the ambush point, and it is then permanently refused a new
-- course with 'group_on_sortie'. Production recorded it on fleet e2151a71 — a FOUR-row manifest, and
-- two intercepts at 14:57:07Z / 14:57:48Z both hit=true, fired, encounter_id=NULL,
-- note='empty_manifest'.
--
-- Cause: the manifest freeze is idempotent (ON CONFLICT DO NOTHING) and the zero-manifest guard read
-- its size with `get diagnostics ... row_count` — the number of rows INSERTED, not the number PRESENT.
-- The second ambush of any fleet inserts nothing, reads zero, and the guard parks the fleet and opens
-- no combat. 0303 makes the guard count the manifest.
--
-- Everything above proves the FIRST ambush. This block is the second one, on the SAME fleet, and it is
-- deliberately built so it CANNOT pass vacuously: it asserts the manifest is already populated before
-- the second resolve (the precondition for the bug) and that the second freeze inserts nothing.
do $$
declare
  n int; n_before int; n_after int; v_pres uuid;
  v_fleet uuid := (select v from dzc where k='v_fleet');
  v_enc1  uuid := (select v from dzc where k='v_enc');
  uZ      uuid := (select v from dzc where k='uZ');
  gZ      uuid := (select v from dzc where k='gZ');
  v_zone  uuid := (select v from dzc where k='v_zone');
  m_x double precision; m_y double precision;
  r jsonb; pi record; mv record; fl record; v_mv2 uuid; v_enc2 uuid;
begin
  -- ── VACUITY GUARD 1: the fleet must ALREADY carry a manifest, or this proves nothing. ────────────
  select count(*) into n_before from public.group_sortie_members where fleet_id = v_fleet;
  if n_before = 0 then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the fleet carries no manifest before the second ambush — the regression cannot reproduce and this block would pass vacuously';
  end if;

  -- ── Leave the first fight through the canonical retreat arm (the one command_ship_group_go step 8
  --    calls; 0298 pins it as the sole retreat entry point), then tick until the encounter is over.
  select presence_id into v_pres from public.combat_encounters where id = v_enc1;
  if v_pres is null then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the first encounter carries no presence to retreat from';
  end if;
  -- Drain to a TERMINAL encounter, not merely out of 'active'. presence_request_leave moves the
  -- encounter to 'retreating', and a retreating encounter is still a live combat commitment: step 8
  -- classifies a re-order against it as case (b) and only UPDATES the retreat destination
  -- ('retreat_destination_updated') instead of starting a new leg. Draining to 'active' alone would
  -- therefore never free the fleet. The retreat also mints its own movement, so the movement processor
  -- is driven alongside the combat ticks to settle it.
  perform public.presence_request_leave(v_pres);
  for i in 1..60 loop
    exit when (select status from public.combat_encounters where id = v_enc1)
              not in ('active', 'retreating');
    update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute'
     where id = v_enc1;
    perform public.process_combat_ticks();
    update public.fleet_movements set depart_at = depart_at - interval '1 hour',
                                      arrive_at = arrive_at - interval '1 hour'
     where fleet_id = v_fleet and status = 'moving';
    perform public.process_fleet_movements();
  end loop;
  if (select status from public.combat_encounters where id = v_enc1) in ('active', 'retreating') then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the first encounter is still % after draining — the fleet cannot be freed',
      (select status from public.combat_encounters where id = v_enc1);
  end if;

  -- ── SECOND ORDER, back through the same zone. Real RPC, the same verb the player uses. A refusal
  --    here IS the owner's 'group_on_sortie' deadlock, so it is asserted rather than tolerated.
  select ST_X(ST_Centroid(boundary)), ST_Y(ST_Centroid(boundary)) into m_x, m_y
    from public.danger_zones where id = v_zone;
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gZ, round(m_x), round(m_y)));
  if (r->>'ok')::boolean is not true then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the fleet could NOT be re-ordered after its first fight: % — this is the group_on_sortie deadlock', r;
  end if;
  v_mv2 := (r->>'movement_id')::uuid;
  if v_mv2 is null then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the re-order started no movement: %', r;
  end if;

  select * into pi from public.pirate_intercepts where movement_id = v_mv2 order by created_at desc limit 1;
  if pi is null or pi.lifecycle_state <> 'pending' then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the second leg scheduled no pending ambush (risk is forced to 1 in this proof)';
  end if;

  -- ── Fire it.
  select * into mv from public.fleet_movements where id = v_mv2;
  perform pg_temp.rewind_leg(v_mv2, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();

  select * into pi from public.pirate_intercepts where movement_id = v_mv2 order by created_at desc limit 1;
  if pi.lifecycle_state <> 'fired' then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the second ambush is % (want fired)', pi.lifecycle_state;
  end if;

  -- ── VACUITY GUARD 2: the second freeze must have inserted NOTHING. If it inserted rows, the fleet
  --    did not really carry its manifest and the pre-0303 code would have passed here too.
  select count(*) into n_after from public.group_sortie_members where fleet_id = v_fleet;
  if n_after <> n_before then
    raise exception 'DZCOMBAT FAIL REAMBUSH: manifest went % -> % across the second ambush — the ON CONFLICT path was not exercised, so this block does not reproduce the regression',
      n_before, n_after;
  end if;

  -- ── THE ASSERTIONS THE LIVE BUG FAILED ───────────────────────────────────────────────────────────
  if pi.note is not distinct from 'empty_manifest' then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the second ambush was logged empty_manifest while % manifest rows exist — the guard is counting the INSERT, not the MANIFEST (the 0303 regression)', n_after;
  end if;
  if pi.encounter_id is null then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the second ambush fired but opened NO encounter — the player was parked without a fight';
  end if;

  select count(*) into n from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if n <> 1 then
    raise exception 'DZCOMBAT FAIL REAMBUSH: % active encounter(s) after the second ambush (want exactly 1). Encounters for this fleet: %. The intercept opened %. Fleet: %.',
      n,
      (select string_agg(format('%s=%s', ce.id, ce.status), ', ' order by ce.created_at)
         from public.combat_encounters ce where ce.fleet_id = v_fleet),
      pi.encounter_id,
      (select format('status=%s mode=%s loc=%s', f.status, f.location_mode, f.current_location_id)
         from public.fleets f where f.id = v_fleet);
  end if;
  select id into v_enc2 from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc2 = v_enc1 then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the "second" encounter is the first one — no new fight was opened';
  end if;
  if pi.encounter_id is distinct from v_enc2 then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the second intercept does not record the encounter it opened';
  end if;

  select * into fl from public.fleets where id = v_fleet;
  if fl.current_location_id is not null then
    raise exception 'DZCOMBAT FAIL REAMBUSH: the fleet is present at a location after the second ambush';
  end if;

  raise notice 'DZCOMBAT_PASS_REAMBUSH ok: the SAME fleet, re-ordered after its first fight, was ambushed a second time with its % existing manifest rows untouched (the freeze inserted 0), was NOT logged empty_manifest, and opened a NEW encounter % — the live defect (first entry fights, later entries park the fleet and deadlock it on group_on_sortie) is proven fixed BY OUTCOME',
    n_after, v_enc2;
end $$;

do $$ begin raise notice 'DANGER-ZONE COMBAT PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
