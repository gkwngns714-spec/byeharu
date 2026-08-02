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
--   DZCOMBAT_PASS_ROSTERAUTH — (0308) a ship UNASSIGNED after a concluded fight is NOT seeded into
--                              the fleet's next ambush — it keeps its berth, status, hp — while the
--                              ship still on the roster IS seeded; the re-ambush freeze REPLACED the
--                              fleet's snapshot (stale row released, live membership frozen).
--   DZCOMBAT_PASS_RIGFALLBACK — (0308) a ship whose ONLY fitted module is a mining rig gets the 0262
--                              fallback weapon derived from its own attack (power = attack x knob),
--                              never the rig's power-8 entry: a rig is not a gun.
--   DZCOMBAT_PASS_FITTEDEXACT — (0308) a ship with a REAL weapon fitted carries exactly its catalog
--                              weapon entry — alone, field-for-field — and no fallback entry.
--   DZCOMBAT_PASS_AUTOEXIT   — (0310) the HP auto-exit, staged on the REAL ambush chain and driven
--                              by the REAL tick: a fleet whose group sets a 50% threshold fights
--                              (real ambush → real encounter → real enemy fire) and, the first tick
--                              its hull is at or below 50% of its FULL CAPACITY (sum of
--                              main_ship_instances.max_hp — the threshold's real denominator,
--                              equal to the entry integrity here ONLY because the fleet is
--                              factory-fresh, and asserted so), AUTO-REQUESTS the canonical
--                              retreat (presence 'retreating', encounter 'retreating',
--                              retreat_started_at stamped, exactly ONE retreat_started event) —
--                              never a tick earlier (every tick observed above the threshold left
--                              it fighting, and at least one such tick is REQUIRED or the block
--                              fails vacuous); a second tick does NOT re-request; rewinding the
--                              retreat clock completes it EXACTLY like a human press (encounter
--                              'escaped', fleet 'returning'); THEN THE DAMAGED RE-ENTRY, the
--                              regression the capacity denominator exists for: the SAME fleet,
--                              un-repaired, re-enters a fight ALREADY below its (raised)
--                              threshold — its entry integrity asserted STRICTLY LESS than its
--                              capacity, or the scenario proves nothing — and auto-exits on the
--                              FIRST tick. An entry-hull denominator reads that first tick as
--                              ~94% of "max" and fights on, so this scenario is RED on any body
--                              measuring the entry hull (the cb10020 defect); a group with the
--                              toggle OFF fights on far below the default threshold (the control
--                              proving the flip assert is not vacuously green — and exactly what
--                              the pre-0310 tick does, so the block is RED on the pre-fix body by
--                              construction); set_group_auto_exit enforces its bounds ([5,95],
--                              NaN refused, null toggle refused, cross-player refused) and the
--                              table CHECK refuses NaN / out-of-range even on a direct write.
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

-- DRAIN an encounter to a terminal state. A pirate-hunt combat never ends on its own — clearing a wave
-- spawns the next — so the ONLY way out is the canonical retreat, which the caller arms first (that is
-- what command_ship_group_go step 8 does against a live encounter). This drives the real engine plus the
-- movement processor, because the retreat mints its own leg that has to settle before the fleet is
-- commandable. Deliberately the single process_combat_ticks() site outside PIRATEFIRE, so the harness's
-- "one combat engine, known call sites" pin stays meaningful.
create or replace function pg_temp.drain_encounter(p_enc uuid, p_fleet uuid) returns text language plpgsql as $$
declare v_status text;
begin
  for i in 1..60 loop
    select status into v_status from public.combat_encounters where id = p_enc;
    exit when v_status not in ('active', 'retreating');
    -- Two clocks have to move, and only clocks: the tick cadence (last_resolved_at) and the retreat
    -- delay, which the engine measures as now() - retreat_started_at >= combat_retreat_delay_seconds
    -- (0299:541-543). Rewinding only the tick cadence leaves the encounter 'retreating' forever, which
    -- is exactly how an earlier draft stalled. No status, no outcome, no geometry is written here.
    update public.combat_encounters
       set last_resolved_at  = last_resolved_at - interval '1 minute',
           retreat_started_at = case when retreat_started_at is not null
                                     then retreat_started_at - interval '1 hour' end
     where id = p_enc;
    perform public.process_combat_ticks();
    update public.fleet_movements set depart_at = depart_at - interval '1 hour',
                                      arrive_at = arrive_at - interval '1 hour'
     where fleet_id = p_fleet and status = 'moving';
    perform public.process_fleet_movements();
  end loop;
  select status into v_status from public.combat_encounters where id = p_enc;
  return v_status;
end $$;

-- ONE tick of the REAL engine against ONE encounter (0310 AUTOEXIT). now() is frozen for the whole
-- txn, so the cadence gate (now() - last_resolved_at >= combat_tick_seconds) never re-opens on its
-- own — this rewinds the ONE encounter's tick clock and runs the engine. Every OTHER encounter's
-- last_resolved_at is untouched, so the same run skips them (their cadence reads zero elapsed):
-- the loop drives exactly one fight. Clock-only, same law as rewind_leg/drain_encounter: no status,
-- no outcome, no geometry, no hp is written here.
create or replace function pg_temp.ae_tick(p_enc uuid) returns void language plpgsql as $$
begin
  update public.combat_encounters
     set last_resolved_at = last_resolved_at - interval '1 minute'
   where id = p_enc;
  perform public.process_combat_ticks();
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

-- ════════ DZCOMBAT_PASS_MANIFESTHELD: an ambush on a fleet holding a RETAINED manifest ══════════════
-- THE REGRESSION THIS FILE EXISTS TO CATCH FROM NOW ON (added with migration 0303, 2026-07-27).
--
-- The owner hit this in the live game: combat fires the first time and never again, the fleet is
-- yanked to the ambush point, and it is then permanently refused a new course with 'group_on_sortie'.
--
-- Cause: the ambush resolver's manifest freeze is idempotent (ON CONFLICT DO NOTHING) and the
-- zero-manifest guard measured it with `get diagnostics ... row_count` — rows INSERTED, not rows
-- PRESENT. Any ambush of a fleet that ALREADY carries sortie-manifest rows therefore inserts nothing,
-- reads zero, and the guard parks the fleet and opens no combat. 0303 makes the guard count.
--
-- ── THE FIXTURE IS PRODUCTION'S ACTUAL SEQUENCE ─────────────────────────────────────────────────────
-- Reconstructed from the live rows rather than imagined, and from what actually plans an ambush:
-- send_ship_group_hunt does NOT plan one (0301 asserts only command_ship_group_go and
-- process_pirate_route_legs plan the legs they mint). So on fleet e2151a71 the order was:
--   1. a HUNT SEND froze a 4-row manifest at 14:54:33Z (send_ship_group_hunt is its sole writer);
--   2. that sortie ENDED, and the manifest rows were RETAINED (0047 keeps a finished sortie's
--      manifest for up to 14 days) — which is the whole trap;
--   3. a later course change crossed the Snare zone, and THAT leg's ambush hit a fleet already
--      holding manifest rows: 14:57:07Z and 14:57:48Z, both empty_manifest, both no encounter.
-- This block reproduces exactly that: hunt → finish the sortie → re-order through a zone → ambush.
--
-- The fight in step 2 is made trivial and harmless on purpose, with the knobs set BEFORE the wave
-- spawns: an enemy is snapshotted with its weapons at spawn time, so zeroing damage afterwards
-- disarms nothing (an earlier draft learned that by killing its own fleet). enemy_hp_base=1 makes the
-- wave die to the first shot; enemy_attack_base=0 means it never fires back. Both restored after.
--
-- Two vacuity guards make a false green impossible:
--   1. the manifest must be non-empty BEFORE the ambush resolves;
--   2. the freeze must insert ZERO rows across the resolve — otherwise the pre-0303 code passes too.
do $$
declare
  r jsonb; n int; n_before int; n_after int;
  uZ uuid := (select v from dzc where k='uZ');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  s_r uuid; gR uuid; v_fleet uuid; v_mv uuid; v_enc uuid; v_enc2 uuid;
  f_x double precision; f_y double precision; t_x double precision; t_y double precision;
  v_verts jsonb; v_hp_before double precision; v_atk_before double precision;
  pi record; mv record; fl record;
begin
  -- ── A third ship + team, provisioned exactly like the others (real RPCs only). ───────────────────
  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: commission: %', r; end if;
  select main_ship_id into s_r from public.main_ship_instances
   where player_id = uZ
     and main_ship_id not in ((select v from dzc where k='s_cmd'), (select v from dzc where k='s_b'))
   limit 1;
  if s_r is null then raise exception 'MANIFESTHELD FAIL: no third ship materialised'; end if;

  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(3, ''Danger R'')');
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: group: %', r; end if;
  gR := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_r, gR));
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_r));
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: designate command: %', r; end if;

  -- ── Make this fleet's hunt wave harmless BEFORE it spawns (see header). ──────────────────────────
  select coalesce(public.cfg_num('enemy_hp_base'), 0)     into v_hp_before;
  select coalesce(public.cfg_num('enemy_attack_base'), 0) into v_atk_before;
  perform public.set_game_config('enemy_hp_base',     '1'::jsonb);
  perform public.set_game_config('enemy_attack_base', '0'::jsonb);

  -- ── 1. THE HUNT SEND — the manifest's sole writer. ───────────────────────────────────────────────
  r := pg_temp.call_as(uZ, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gR, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: hunt send: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid;
  v_mv    := (r->>'movement_id')::uuid;

  select count(*) into n_before from public.group_sortie_members where fleet_id = v_fleet;
  if n_before = 0 then
    raise exception 'MANIFESTHELD FAIL: the hunt send froze no manifest';
  end if;

  -- ── 2. ARRIVE, FIGHT, FINISH. The sortie must END so the fleet is commandable again. ─────────────
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();

  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then
    raise exception 'MANIFESTHELD FAIL: the hunt arrival opened no encounter';
  end if;
  -- A hunt combat spawns ENDLESS waves — clearing one spawns the next — so it cannot be waited out.
  -- The only exit is the canonical retreat, and the way a player arms it is by giving the fleet a new
  -- course: step 8 classifies that against the live encounter and returns 'retreat_started'. So the
  -- first course change here is the RETREAT, not the ambushed leg.
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gR, round(coalesce((select space_x from public.fleets where id = v_fleet), 0)) + 10,
                                  round(coalesce((select space_y from public.fleets where id = v_fleet), 0))));
  if (r->>'ok')::boolean is not true then
    raise exception 'MANIFESTHELD FAIL: could not arm the retreat out of the hunt: %', r;
  end if;
  if (r->>'reason') not in ('retreat_started', 'retreat_destination_updated', 'movement_started') then
    raise exception 'MANIFESTHELD FAIL: unexpected outcome arming the retreat: %', r;
  end if;

  if pg_temp.drain_encounter(v_enc, v_fleet) in ('active', 'retreating') then
    raise exception 'MANIFESTHELD FAIL: the hunt encounter is still % after draining — the sortie never ended',
      (select status from public.combat_encounters where id = v_enc);
  end if;

  perform public.set_game_config('enemy_hp_base',     to_jsonb(v_hp_before));
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_atk_before));

  select * into fl from public.fleets where id = v_fleet;
  if fl.status = 'destroyed' then
    raise exception 'MANIFESTHELD FAIL: the fleet died in its own hunt despite a 1-hp, 0-damage wave';
  end if;

  -- ── 3. THE MANIFEST IS RETAINED. This is the trap, asserted rather than assumed. ─────────────────
  select count(*) into n_before from public.group_sortie_members where fleet_id = v_fleet;
  if n_before = 0 then
    raise exception 'MANIFESTHELD FAIL: the finished sortie released its manifest — 0047 retention no longer holds, so the regression cannot reproduce and this block would pass vacuously';
  end if;

  -- ── 4. A ZONE ON THE NEXT LEG, drawn with the real verb (0304 gives it its effect row). ──────────
  select coalesce(f.space_x, 0), coalesce(f.space_y, 0) into f_x, f_y
    from public.fleets f where f.id = v_fleet;
  t_x := f_x + 400; t_y := f_y;
  v_verts := jsonb_build_array(
    jsonb_build_array(f_x + 100, f_y - 150),
    jsonb_build_array(f_x + 300, f_y - 150),
    jsonb_build_array(f_x + 300, f_y + 150),
    jsonb_build_array(f_x + 100, f_y + 150));
  -- Attached to a REAL location: the resolver opens the fight AT the zone's linked location, and a
  -- zone with a null location makes it bail early with note='location_missing' and no encounter.
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Retained Manifest Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'MANIFESTHELD FAIL: zone: %', r; end if;

  -- ── 5. THE COURSE CHANGE. This is the owner's action, and the leg that gets ambushed. ────────────
  r := pg_temp.call_as(uZ, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gR, round(t_x), round(t_y)));
  if (r->>'ok')::boolean is not true then
    raise exception 'MANIFESTHELD FAIL: the fleet could not be re-ordered after its sortie: %', r;
  end if;
  v_mv := (r->>'movement_id')::uuid;
  if v_mv is null then raise exception 'MANIFESTHELD FAIL: the course change started no movement: %', r; end if;

  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi is null or pi.lifecycle_state <> 'pending' then
    raise exception 'MANIFESTHELD FAIL: the new leg scheduled no pending ambush (risk knobs are 1.0, and 0304 gives the new zone its effect row)';
  end if;

  -- ── 6. FIRE IT, through the REAL movement processor. ─────────────────────────────────────────────
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();

  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi.lifecycle_state <> 'fired' then
    raise exception 'MANIFESTHELD FAIL: the ambush is % (want fired)', pi.lifecycle_state;
  end if;

  -- ── VACUITY GUARD: the freeze must have inserted NOTHING (the ON CONFLICT path). ─────────────────
  select count(*) into n_after from public.group_sortie_members where fleet_id = v_fleet;
  if n_after <> n_before then
    raise exception 'MANIFESTHELD FAIL: manifest went % -> % across the ambush — the ON CONFLICT path was not exercised, so this block does not reproduce the regression',
      n_before, n_after;
  end if;

  -- ── THE ASSERTIONS THE LIVE BUG FAILED ───────────────────────────────────────────────────────────
  if pi.note is not distinct from 'empty_manifest' then
    raise exception 'MANIFESTHELD FAIL: the ambush was logged empty_manifest while % manifest rows exist — the guard is counting the INSERT, not the MANIFEST (the 0303 regression)', n_after;
  end if;
  -- Any note at all means the resolver took one of its fail-open exits (location_missing and the
  -- like) instead of opening combat. Naming it beats inferring it from a null encounter_id.
  if pi.note is not null then
    raise exception 'MANIFESTHELD FAIL: the ambush bailed out with note=% instead of opening combat', pi.note;
  end if;
  if pi.encounter_id is null then
    raise exception 'MANIFESTHELD FAIL: the ambush fired but opened NO encounter — the player was parked without a fight';
  end if;

  select count(*) into n from public.combat_encounters
   where fleet_id = v_fleet and status = 'active' and id <> v_enc;
  if n <> 1 then
    raise exception 'MANIFESTHELD FAIL: % new active encounter(s) after the ambush (want exactly 1). Encounters: %. Intercept opened %. Fleet: %.',
      n,
      (select string_agg(format('%s=%s', ce.id, ce.status), ', ' order by ce.created_at)
         from public.combat_encounters ce where ce.fleet_id = v_fleet),
      pi.encounter_id,
      (select format('status=%s mode=%s loc=%s', f.status, f.location_mode, f.current_location_id)
         from public.fleets f where f.id = v_fleet);
  end if;
  select id into v_enc2 from public.combat_encounters
   where fleet_id = v_fleet and status = 'active' and id <> v_enc;
  if pi.encounter_id is distinct from v_enc2 then
    raise exception 'MANIFESTHELD FAIL: the intercept does not record the encounter it opened';
  end if;

  raise notice 'DZCOMBAT_PASS_MANIFESTHELD ok: a fleet still holding % retained manifest rows from a finished hunt was ambushed on a later course change, the freeze inserted 0 rows (the ON CONFLICT path), it was NOT logged empty_manifest, and it opened encounter % — production''s exact sequence, and the live defect (parked with no fight, then deadlocked on group_on_sortie) is proven fixed BY OUTCOME',
    n_after, v_enc2;
end $$;


-- ════════ DZCOMBAT_PASS_ROSTERAUTH (0308): THE COMBAT ROSTER IS LIVE MEMBERSHIP ══════════════════════
-- Production's destruction sequence, staged for real and inverted into assertions: a fleet fights,
-- the fight CONCLUDES, the player unassigns one ship (legal — the sortie is closed), and the fleet
-- is ambushed again. Pre-0308 the idempotent freeze inserted nothing, the unfiltered roster kept the
-- departed ship, and the builder seeded it into combat_units — a ship berthed at a port, dragged
-- into someone else's fight and destroyed on defeat. Post-0308 the re-ambush freeze REPLACES the
-- fleet's snapshot (the one release idiom) and the builder seeds live membership only.
--
-- A SECOND fixture player: uZ's three team slots are all spent (group_index <= 3), and an isolated
-- world makes the "untouched bystander ship" assertion airtight. Provisioning is 100% real-RPC.
-- STAGING LEGS FLY UNDER risk 0 (the proof owns its preconditions): the trip back to port must not
-- roll an ambush of its own; the knobs return to 1.0 for the leg under test.
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from dzc where k='uZ');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  uL uuid; s_l uuid; s_d uuid; gL uuid; v_port uuid;
  v_fleet uuid; v_mv uuid; v_enc uuid; v_enc2 uuid;
  f_x double precision; f_y double precision; t_x double precision; t_y double precision;
  v_verts jsonb;
  v_hp_before double precision; v_atk_before double precision;
  d_status text; d_hp integer;
  pi record; mv record;
begin
  -- ── a second fixture player, funded like the first ───────────────────────────────────────────────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzl.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uL;
  insert into dzc values ('uL', uL);
  insert into public.player_wallet (player_id, balance) values (uL, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;

  -- ── two ships, one team, command designated — the real RPCs only ─────────────────────────────────
  r := pg_temp.call_as(uL, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: first ship: %', r; end if;
  select main_ship_id into s_l from public.main_ship_instances where player_id = uL;
  select berth_location_id into v_port from public.main_ship_instances where main_ship_id = s_l;
  if v_port is null then raise exception 'ROSTERAUTH FAIL: the commissioned ship has no berth port'; end if;
  -- arm the survivor with a REAL autocannon (real writers): its unit in the final, never-ticked
  -- encounter below is what FITTEDEXACT pins field-for-field against the catalog.
  perform public.reward_grant('combat', gen_random_uuid(), uL, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);
  r := pg_temp.call_as(uL, 'public.craft_module(''ral-gun-1'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: craft gun: %', r; end if;
  r := pg_temp.call_as(uL, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''ral-fit-1'')', (r->>'instance_id')::uuid, s_l));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: fit gun: %', r; end if;
  r := pg_temp.call_as(uL, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: second ship: %', r; end if;
  select main_ship_id into s_d from public.main_ship_instances
   where player_id = uL and main_ship_id <> s_l limit 1;
  if s_d is null then raise exception 'ROSTERAUTH FAIL: no second ship materialised'; end if;
  insert into dzc values ('uL_s_l', s_l), ('uL_s_d', s_d);

  r := pg_temp.call_as(uL, 'public.upsert_ship_group(1, ''Roster L'')');
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: group: %', r; end if;
  gL := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_l, gL));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: assign s_l: %', r; end if;
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_d, gL));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: assign s_d: %', r; end if;
  r := pg_temp.call_as(uL, format('public.set_fleet_command_ship(%L::uuid, true)', s_l));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: designate command: %', r; end if;

  -- ── 1. A FIGHT, CONCLUDED. Harmless wave (knobs set BEFORE it spawns; restored after). ───────────
  select coalesce(public.cfg_num('enemy_hp_base'), 0)     into v_hp_before;
  select coalesce(public.cfg_num('enemy_attack_base'), 0) into v_atk_before;
  perform public.set_game_config('enemy_hp_base',     '1'::jsonb);
  perform public.set_game_config('enemy_attack_base', '0'::jsonb);

  r := pg_temp.call_as(uL, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gL, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: hunt send: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'ROSTERAUTH FAIL: the hunt arrival opened no encounter'; end if;
  -- the retreat is armed the way a player arms it: a new course against the live encounter.
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gL, round(coalesce((select space_x from public.fleets where id = v_fleet), 0)) + 10,
                                  round(coalesce((select space_y from public.fleets where id = v_fleet), 0))));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: could not arm the retreat: %', r; end if;
  if pg_temp.drain_encounter(v_enc, v_fleet) in ('active', 'retreating') then
    raise exception 'ROSTERAUTH FAIL: the fight never concluded'; end if;
  perform public.set_game_config('enemy_hp_base',     to_jsonb(v_hp_before));
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_atk_before));
  select count(*) into n from public.fleets where id = v_fleet and status = 'destroyed';
  if n <> 0 then raise exception 'ROSTERAUTH FAIL: the fleet died in a 1-hp, 0-damage fight'; end if;

  -- vacuity: the concluded sortie RETAINED its 2-row roster — the trap state exists.
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 2 then raise exception 'ROSTERAUTH FAIL: % roster rows after the concluded fight (want 2 retained — the trap)', n; end if;

  -- ── 2. HOME TO PORT under risk 0 (a staging leg must not roll its own ambush), then UNASSIGN. ────
  perform public.set_game_config('pirate_intercept_base_risk',      '0'::jsonb);
  perform public.set_game_config('pirate_intercept_min_risk',       '0'::jsonb);
  perform public.set_game_config('pirate_intercept_max_risk',       '0'::jsonb);
  perform public.set_game_config('pirate_intercept_exposure_floor', '0'::jsonb);
  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, %L::uuid, null, null)', gL, v_port));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: go to port: %', r; end if;
  -- vacuity: the production defect lives on a PERSISTENT group fleet — the go must reuse it, or the
  -- stale rows would sit on a different fleet and this block would prove nothing.
  if (r->>'fleet_id')::uuid is distinct from v_fleet then
    raise exception 'ROSTERAUTH FAIL: the go minted a different fleet (% vs %) — the persistent-fleet trap shape did not build', r->>'fleet_id', v_fleet; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select count(*) into n from public.fleets
   where id = (select f.id from public.fleets f where f.group_id = gL and f.player_id = uL
                 and f.status = 'present' and f.location_mode = 'location' and f.current_location_id = v_port limit 1);
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the fleet did not settle present at its port'; end if;

  -- THE PLAYER'S LEGAL ACT: the sortie is closed, so the unassign must succeed (0305).
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, null)', s_d));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: post-sortie unassign refused: %', r; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = s_d and group_id is null and berth_location_id = v_port;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the unassigned ship is not berthed at the port, out of the group'; end if;
  -- vacuity: the STALE row for the departed ship is STILL on the roster — the trap is armed.
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet and main_ship_id = s_d;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the departed ship''s stale roster row is already gone — the regression cannot reproduce and this block would pass vacuously'; end if;
  select status, hp into d_status, d_hp from public.main_ship_instances where main_ship_id = s_d;

  -- ── 3. THE RE-AMBUSH: risk back to 1.0, a fresh zone on a fresh leg, fired by the real processor. ─
  perform public.set_game_config('pirate_intercept_base_risk',      '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_min_risk',       '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_max_risk',       '1.0'::jsonb);
  perform public.set_game_config('pirate_intercept_exposure_floor', '1.0'::jsonb);
  select l.x, l.y into f_x, f_y from public.locations l where l.id = v_port;
  t_x := f_x; t_y := f_y + 700;
  v_verts := jsonb_build_array(
    jsonb_build_array(f_x - 150, f_y + 200),
    jsonb_build_array(f_x + 150, f_y + 200),
    jsonb_build_array(f_x + 150, f_y + 500),
    jsonb_build_array(f_x - 150, f_y + 500));
  r := pg_temp.call_as(uZ, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Roster Authority Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: zone: %', r; end if;

  r := pg_temp.call_as(uL, format('public.command_ship_group_go(%L::uuid, null, %s, %s)', gL, round(t_x), round(t_y)));
  if (r->>'ok')::boolean is not true then raise exception 'ROSTERAUTH FAIL: the re-order: %', r; end if;
  if (r->>'fleet_id')::uuid is distinct from v_fleet then
    raise exception 'ROSTERAUTH FAIL: the re-order minted a different fleet (% vs %) — the stale roster would not even be in play', r->>'fleet_id', v_fleet; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi is null or pi.lifecycle_state <> 'pending' then
    raise exception 'ROSTERAUTH FAIL: the leg under test scheduled no pending ambush'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select * into pi from public.pirate_intercepts where movement_id = v_mv order by created_at desc limit 1;
  if pi.lifecycle_state <> 'fired' then
    raise exception 'ROSTERAUTH FAIL: the ambush is % (want fired)', pi.lifecycle_state; end if;
  if pi.note is not null then
    raise exception 'ROSTERAUTH FAIL: the ambush bailed out with note=% instead of opening combat — one live member must be a fight', pi.note; end if;
  if pi.encounter_id is null then
    raise exception 'ROSTERAUTH FAIL: the ambush fired but opened NO encounter'; end if;
  v_enc2 := pi.encounter_id;

  -- ── THE ASSERTIONS THE LIVE DEFECT WOULD FAIL ────────────────────────────────────────────────────
  -- (i) the fight is fielded by LIVE MEMBERSHIP: exactly one player unit, and it is the member.
  select count(*) into n from public.combat_units where encounter_id = v_enc2 and side = 'player';
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: % player unit(s) seeded (want exactly 1 — live membership only)', n; end if;
  select count(*) into n from public.combat_units
   where encounter_id = v_enc2 and side = 'player' and main_ship_id = s_l;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the remaining member was NOT seeded — the roster rule is too aggressive'; end if;
  -- (ii) the DEPARTED ship was not dragged in — this line IS the production defect, inverted.
  select count(*) into n from public.combat_units where encounter_id = v_enc2 and main_ship_id = s_d;
  if n <> 0 then raise exception 'ROSTERAUTH FAIL: the ship that LEFT the fleet was seeded into its next fight (the 0308 defect)'; end if;
  -- (iii) the bystander is untouched: same berth, same status, same hp, still ungrouped.
  select count(*) into n from public.main_ship_instances
   where main_ship_id = s_d and group_id is null and berth_location_id = v_port
     and status = d_status and hp = d_hp;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the departed ship''s row changed across a fight it was never in'; end if;
  -- (iv) the freeze REPLACED the snapshot: the stale row is released, the live member is frozen.
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: % roster rows after the re-ambush (want exactly 1 — the snapshot was replaced)', n; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet and main_ship_id = s_l;
  if n <> 1 then raise exception 'ROSTERAUTH FAIL: the fresh snapshot does not carry the live member'; end if;
  -- hand the NEVER-TICKED armed encounter to FITTEDEXACT (the tick legitimately rewrites
  -- next_ready_at after a shot, so the frozen-at-creation shape can only be pinned pre-tick).
  insert into dzc values ('ra_enc2', v_enc2);

  raise notice 'DZCOMBAT_PASS_ROSTERAUTH ok: a fleet whose fight had concluded lost a ship to a legal unassign, was ambushed again, and the fight fielded ONLY the live member (1 unit = %); the departed ship kept its berth/status/hp and was never seeded; the re-ambush freeze replaced the 2-row stale snapshot with the 1-row live one', s_l;
end $$;

-- ════════ DZCOMBAT_PASS_RIGFALLBACK (0308): A MINING RIG IS NOT A GUN ════════════════════════════════
-- The catalog seeds mining_rig_extension with range 120 / power 8 (0229), and the creator's old
-- weapon test was `range is not null` — so a fitted rig fired power 8 AND suppressed the 0262
-- fallback. Post-0308 a rig-only ship's fitted-WEAPON join is empty and the fallback fires,
-- deriving power from the ship's own attack. Expected values are DERIVED from the knobs and the
-- unit's own snapshot at assert time — nothing ambient is hard-coded.
do $$
declare
  r jsonb; n int;
  uL uuid := (select v from dzc where k='uL');
  v_hunt uuid := (select v from dzc where k='v_hunt');
  s_m uuid; gM uuid; v_modinst uuid; v_fleet uuid; v_mv uuid; v_enc uuid;
  mv record; w jsonb;
  v_attack double precision; v_wc int;
  v_fb_id text; v_paf double precision; v_frange double precision;
begin
  -- ── a third ship for the second player, rigged (not armed), its own team ─────────────────────────
  r := pg_temp.call_as(uL, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: commission: %', r; end if;
  select main_ship_id into s_m from public.main_ship_instances
   where player_id = uL
     and main_ship_id not in ((select v from dzc where k='uL_s_l'), (select v from dzc where k='uL_s_d'))
   limit 1;
  if s_m is null then raise exception 'RIGFALLBACK FAIL: no third ship materialised'; end if;

  -- fund + craft + fit ONE mining rig via the real writers (recipe: crystal/ore/scrap, 0183).
  perform public.reward_grant('combat', gen_random_uuid(), uL, null,
    '{"items": [{"item_id": "crystal", "quantity": 4}, {"item_id": "ore", "quantity": 8}, {"item_id": "scrap", "quantity": 8}]}'::jsonb);
  r := pg_temp.call_as(uL, 'public.craft_module(''dzc-rig-1'', ''mining_rig_extension'')');
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: craft rig: %', r; end if;
  v_modinst := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uL, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''dzc-fit-rig'')', v_modinst, s_m));
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: fit rig: %', r; end if;

  -- vacuity guards: the rig really is the trap-carrier (a range-bearing NON-weapon), and it is the
  -- ship's ONLY range-bearing fitted module — the exact pre-0308 poisoned input.
  select count(*) into n from public.module_types t
   where t.id = 'mining_rig_extension' and t.slot_type = 'mining' and t.range is not null;
  if n <> 1 then raise exception 'RIGFALLBACK FAIL: mining_rig_extension is no longer a range-bearing mining module — the trap input does not exist and this block would pass vacuously'; end if;
  select count(*) into n
    from public.ship_module_fittings f
    join public.module_instances i on i.id = f.module_instance_id
    join public.module_types t     on t.id = i.module_type_id
   where f.main_ship_id = s_m and t.range is not null;
  if n <> 1 then raise exception 'RIGFALLBACK FAIL: % range-bearing fitted module(s) on the rig ship (want exactly the rig)', n; end if;

  r := pg_temp.call_as(uL, 'public.upsert_ship_group(2, ''Roster M'')');
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: group: %', r; end if;
  gM := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uL, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_m, gM));
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: assign: %', r; end if;
  r := pg_temp.call_as(uL, format('public.set_fleet_command_ship(%L::uuid, true)', s_m));
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: designate command: %', r; end if;

  -- ── a real sortie opens a real encounter (no ticks are run; creation state is the assertion). ────
  r := pg_temp.call_as(uL, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gM, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'RIGFALLBACK FAIL: hunt send: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'RIGFALLBACK FAIL: the hunt arrival opened no encounter'; end if;

  -- ── THE ASSERTIONS: the rig never fires; the ship fires ITS OWN attack through the fallback. ─────
  select attack_snapshot, jsonb_array_length(weapons_json) into v_attack, v_wc
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_m;
  if v_attack is null or v_attack <= 0 then
    raise exception 'RIGFALLBACK FAIL: attack_snapshot is % — the fallback trigger (attack > 0) would be vacuous', v_attack; end if;
  if v_wc <> 1 then
    raise exception 'RIGFALLBACK FAIL: weapons_json has % entries (want exactly 1 — the synthesized fallback)', v_wc; end if;
  select weapons_json->0 into w from public.combat_units where encounter_id = v_enc and main_ship_id = s_m;
  select count(*) into n from public.combat_units cu, jsonb_array_elements(cu.weapons_json) e
   where cu.encounter_id = v_enc and cu.main_ship_id = s_m and e->>'module_type_id' = 'mining_rig_extension';
  if n <> 0 then
    raise exception 'RIGFALLBACK FAIL: the mining rig is in weapons_json — a rig still counts as a gun (the 0308 defect)'; end if;
  v_fb_id  := coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon');
  v_paf    := coalesce(public.cfg_num('combat_player_fallback_weapon_power_from_attack'), 1);
  v_frange := coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 150);
  if (w->>'module_type_id') is distinct from v_fb_id then
    raise exception 'RIGFALLBACK FAIL: the one weapon is % (want the fallback %) — the 0262 fallback did not fire', w->>'module_type_id', v_fb_id; end if;
  if (w->>'power')::double precision is distinct from v_attack * v_paf then
    raise exception 'RIGFALLBACK FAIL: fallback power % <> attack_snapshot % x knob % — the ship does not fire its own attack', w->>'power', v_attack, v_paf; end if;
  if (w->>'range')::double precision is distinct from v_frange then
    raise exception 'RIGFALLBACK FAIL: fallback range % <> the knob-derived %', w->>'range', v_frange; end if;

  raise notice 'DZCOMBAT_PASS_RIGFALLBACK ok: a rig-only ship (the exact pre-0308 poisoned input: one range-bearing non-weapon fitted) was seeded with exactly ONE weapon — the % fallback at power %*% = %, range % — and the rig entry is gone: a mining rig is not a gun',
    v_fb_id, v_attack, v_paf, v_attack * v_paf, v_frange;
end $$;

-- ════════ DZCOMBAT_PASS_FITTEDEXACT (0308): A REAL WEAPON RIDES THROUGH EXACTLY, AND ALONE ═══════════
-- The control arm: the ROSTERAUTH survivor fitted a real autocannon_battery at provision time, and
-- the block's FINAL encounter has NEVER TICKED — deliberately: the tick legitimately rewrites
-- next_ready_at after a weapon fires (team A's PIRATEFIRE encounter proved that the hard way), so
-- the frozen-at-creation shape can only be pinned on a pre-tick encounter. Its weapons_json must be
-- exactly its CATALOG entry — every field equal to the deployed module_types row, no fallback entry
-- beside it. Field values are DERIVED from the catalog at assert time, never hard-coded.
do $$
declare
  n int;
  s_cmd uuid := (select v from dzc where k='uL_s_l');
  v_enc uuid := (select v from dzc where k='ra_enc2');
  w jsonb; t record; v_wc int;
  v_fb_id text;
begin
  if v_enc is null then raise exception 'FITTEDEXACT FAIL: the ROSTERAUTH encounter was not handed over'; end if;

  select jsonb_array_length(weapons_json), weapons_json->0 into v_wc, w
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_cmd;
  if v_wc is null then raise exception 'FITTEDEXACT FAIL: no combat unit for the armed command ship'; end if;
  if v_wc <> 1 then
    raise exception 'FITTEDEXACT FAIL: the armed ship carries % weapon entries (want exactly its one fitted gun)', v_wc; end if;

  select * into t from public.module_types where id = 'autocannon_battery';
  if t.id is null then raise exception 'FITTEDEXACT FAIL: autocannon_battery is not in the catalog'; end if;
  if (w->>'module_type_id') is distinct from t.id
     or (w->>'range')::numeric            is distinct from t.range
     or (w->>'power')::numeric            is distinct from t.power
     or (w->>'projectile_speed')::numeric is distinct from t.projectile_speed
     or (w->>'cooldown_seconds')::numeric is distinct from t.cooldown_seconds
     or (w->>'ammo_type')                 is distinct from t.ammo_type
     or (w->>'ammo_per_shot')::integer    is distinct from t.ammo_per_shot then
    raise exception 'FITTEDEXACT FAIL: the fitted weapon entry drifted from its catalog row: % vs (%, %, %, %, %, %, %)',
      w, t.id, t.range, t.power, t.projectile_speed, t.cooldown_seconds, t.ammo_type, t.ammo_per_shot; end if;
  if w->>'next_ready_at' is not null or w->>'ammo_remaining' is not null then
    raise exception 'FITTEDEXACT FAIL: the fitted entry lost its frozen next_ready_at/ammo_remaining NULLs'; end if;
  -- and NO fallback entry beside it: a real gun must keep suppressing the synthesized weapon.
  v_fb_id := coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon');
  select count(*) into n from public.combat_units cu, jsonb_array_elements(cu.weapons_json) e
   where cu.encounter_id = v_enc and cu.main_ship_id = s_cmd and e->>'module_type_id' = v_fb_id;
  if n <> 0 then
    raise exception 'FITTEDEXACT FAIL: a fallback entry sits beside the real gun — the empty-array guard broke'; end if;

  raise notice 'DZCOMBAT_PASS_FITTEDEXACT ok: the armed command ship''s weapons_json is exactly its catalog autocannon_battery entry (field-for-field, alone, frozen NULL clocks) and carries no fallback beside it';
end $$;

-- ════════ DZCOMBAT_PASS_AUTOEXIT (0310): THE HP AUTO-EXIT, ON THE REAL CHAIN ═════════════════════════
-- The owner's core combat law, staged end to end: waves are endless by design, so the ONLY good
-- outcome of a fight is leaving it at the right moment — and until 0310 nothing left automatically.
--
-- A FRESH fixture player (its own auth row → the signup trigger mints its Home Base, so the
-- auto-exit's no-destination completion has its 'base' fallback exactly as every live player does),
-- two single-ship groups:
--   group A — threshold set to 50 through the REAL RPC (proving the percentage is the player's);
--   group B — toggle turned OFF through the REAL RPC (proving OFF means the pre-0310 world), pct
--             left at the default 30 so the control fights BELOW the very number that would have
--             fired it.
-- Both fleets take a REAL ambush (drawn zone → command_ship_group_go → pending intercept →
-- process_fleet_movements fires it → encounter), and the REAL tick does all the damage: the enemy
-- attack knob is DERIVED from the encounter's own at-entry integrity and the defender's own
-- defense snapshot so each tick erodes ~6% of the fleet's hull — small enough that ticks are
-- OBSERVED above the threshold (asserted non-vacuous), large enough to cross it inside the loop.
--
-- WHY THIS BLOCK IS RED ON THE PRE-0310 BODY, BY CONSTRUCTION: the flip assertion demands that the
-- first tick ending at-or-below the threshold leaves the encounter 'retreating'. The pre-0310 tick
-- has no auto-exit arm, so that tick ends 'active' and the loop raises "never auto-requested
-- leave". Group B is the in-file control proving the assert machinery distinguishes the two
-- worlds: with the toggle OFF the SAME staging, SAME knobs, SAME loop ends 'active' — pre-0310
-- behaviour reproduced and asserted, so a green flip assert can never be vacuous.
do $$
declare
  r jsonb; n int; i int;
  uZ uuid := (select v from dzc where k='uZ');
  uA uuid;
  v_hunt uuid := (select v from dzc where k='v_hunt');
  sA uuid; sB uuid; gA uuid; gB2 uuid;
  o_x double precision; o_y double precision;
  v_verts jsonb;
  v_fleet uuid; v_mv uuid; v_enc uuid;
  mv record; pi record; enc record; prs record;
  v_imax double precision; v_def double precision; v_bd double precision;
  v_eab_before double precision; v_eab numeric;
  v_srg_before double precision;
  v_thresh double precision; v_hp double precision;
  v_hp_a double precision; v_imax_a double precision;
  v_cap double precision; v_cap3 double precision; v_imax3 double precision;
  v_enc2 uuid; v_enc3 uuid; v_txt text;
  n_above int := 0;
  v_flipped boolean := false;
  v_started timestamptz;
begin
  -- ── A fresh, funded fixture player. The auth insert fires the signup trigger → Home Base exists,
  --    which is what the completion's origin-base fallback resolves for every real player. ─────────
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'dzc.ae.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uA;
  insert into public.player_wallet (player_id, balance) values (uA, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  if not exists (select 1 from public.bases where player_id = uA) then
    raise exception 'AUTOEXIT FAIL: the signup trigger minted no base — the completion''s origin-base fallback would be untestable here and broken for a real player';
  end if;

  -- ── Two ships, two groups, both command-designated — 100% real RPCs. ────────────────────────────
  r := pg_temp.call_as(uA, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: commission A: %', r; end if;
  select main_ship_id into sA from public.main_ship_instances where player_id = uA;
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(1, ''Auto Exit A'')');
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: group A: %', r; end if;
  gA := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sA, gA));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: assign A: %', r; end if;
  r := pg_temp.call_as(uA, format('public.set_fleet_command_ship(%L::uuid, true)', sA));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: command A: %', r; end if;

  r := pg_temp.call_as(uA, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: commission B: %', r; end if;
  select main_ship_id into sB from public.main_ship_instances where player_id = uA and main_ship_id <> sA limit 1;
  if sB is null then raise exception 'AUTOEXIT FAIL: no second ship materialised'; end if;
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(2, ''Auto Exit B'')');
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: group B: %', r; end if;
  gB2 := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', sB, gB2));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: assign B: %', r; end if;
  r := pg_temp.call_as(uA, format('public.set_fleet_command_ship(%L::uuid, true)', sB));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: command B: %', r; end if;

  -- ── The columns landed defaulted: ON at 30 for a brand-new group (the 0310 headline). ──────────
  select count(*) into n from public.ship_groups
   where group_id in (gA, gB2) and auto_exit_enabled and auto_exit_hp_pct = 30;
  if n <> 2 then
    raise exception 'AUTOEXIT FAIL: % of 2 fresh groups defaulted to enabled/30 — the protective default is not what 0310 states', n;
  end if;

  -- ── The player adjusts: group A to 50%; group B toggled OFF — through the ONE writer. ──────────
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, 50)', gA));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: set 50 on A: %', r; end if;
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, false, 30)', gB2));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: toggle OFF on B: %', r; end if;

  -- ── The writer's own boundary, exercised not assumed. ──────────────────────────────────────────
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, 150)', gA));
  if (r->>'reason') is distinct from 'invalid_auto_exit_pct' then
    raise exception 'AUTOEXIT FAIL: pct 150 answered % — the server-side bounds are not the authority', r; end if;
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, 4)', gA));
  if (r->>'reason') is distinct from 'invalid_auto_exit_pct' then
    raise exception 'AUTOEXIT FAIL: pct 4 answered % — the lower bound is not enforced', r; end if;
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, ''NaN''::numeric)', gA));
  if (r->>'reason') is distinct from 'invalid_auto_exit_pct' then
    raise exception 'AUTOEXIT FAIL: NaN answered % — numeric NaN sorts above every value and a one-sided bound would accept it', r; end if;
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, null, 30)', gA));
  if (r->>'reason') is distinct from 'invalid_auto_exit_toggle' then
    raise exception 'AUTOEXIT FAIL: a null toggle answered %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_group_auto_exit(%L::uuid, true, 50)', gA));
  if (r->>'reason') is distinct from 'group_not_found' then
    raise exception 'AUTOEXIT FAIL: another player''s write answered % (want group_not_found — owner-scoped, fail closed)', r; end if;
  -- and the TABLE's own CHECK, on a direct write (the layer beneath the RPC): NaN and out-of-range
  -- must be unstorable even if a future writer forgets to validate.
  begin
    update public.ship_groups set auto_exit_hp_pct = 'NaN'::numeric where group_id = gA;
    raise exception 'AUTOEXIT FAIL: the CHECK accepted NaN on a direct write';
  exception when check_violation then null;
  end;
  begin
    update public.ship_groups set auto_exit_hp_pct = 150 where group_id = gA;
    raise exception 'AUTOEXIT FAIL: the CHECK accepted 150 on a direct write';
  exception when check_violation then null;
  end;
  select auto_exit_hp_pct::double precision into v_hp from public.ship_groups where group_id = gA;
  if v_hp <> 50 then
    raise exception 'AUTOEXIT FAIL: group A''s threshold is % after the refused writes (want 50 intact)', v_hp;
  end if;

  -- ── Group A: a REAL ambush. Zone drawn perpendicular to the earlier scenarios' corridors so no
  --    other zone is crossed; attached to the hunt location (identity), like every zone here. ─────
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uA and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gA
   limit 1;
  if o_x is null then raise exception 'AUTOEXIT FAIL: could not resolve group A''s docked origin'; end if;
  v_verts := jsonb_build_array(
    jsonb_build_array(o_x - 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 400),
    jsonb_build_array(o_x + 100, o_y + 600),
    jsonb_build_array(o_x - 100, o_y + 600));
  r := pg_temp.call_as(uA, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Auto Exit Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: zone: %', r; end if;

  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gA, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: go A: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'AUTOEXIT FAIL: no pending ambush on group A''s leg (risk knobs are 1.0)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, fleet_id into v_enc, v_fleet from public.combat_encounters
   where player_id = uA and status = 'active';
  if v_enc is null then raise exception 'AUTOEXIT FAIL: the ambush opened no encounter for group A'; end if;

  -- ── Derive the enemy attack from the fight's OWN numbers (never an ambient assumption): ~6% of
  --    the at-entry integrity per tick after the defender's own mitigation curve. Set BEFORE the
  --    first tick — the wave snapshots its weapons at spawn. ───────────────────────────────────────
  select player_integrity_max into v_imax from public.combat_encounters where id = v_enc;
  if v_imax is null or v_imax <= 0 then
    raise exception 'AUTOEXIT FAIL: at-entry integrity is % — the threshold would have no denominator', v_imax;
  end if;
  select coalesce(max(defense_snapshot), 0) into v_def from public.combat_units
   where encounter_id = v_enc and side = 'player';
  -- bd from the ENCOUNTER's OWN location (its identity), never an assumed one — the wave formulas
  -- read exactly this row, so the derived knob tracks whatever location the ambush resolved.
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  if v_bd is null or v_bd <= 0 then raise exception 'AUTOEXIT FAIL: the encounter''s location has base_difficulty %', v_bd; end if;
  select coalesce(public.cfg_num('enemy_attack_base'), 0) into v_eab_before;
  v_eab := round(((0.06 * v_imax) * ((100 + v_def) / 100.0) / (v_bd * 1.25))::numeric, 6);
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab));
  -- erosion must be monotone; captured and restored at the end like every knob this block touches.
  select coalesce(public.cfg_num('shield_regen_combat_pct'), 0) into v_srg_before;
  perform public.set_game_config('shield_regen_combat_pct', '0'::jsonb);

  -- THE THRESHOLD'S REAL DENOMINATOR: the fleet's full capacity (sum of max_hp over the
  -- encounter's member units) — exactly what the 0310 arm computes. For THIS factory-fresh fleet
  -- it must equal the entry integrity, and that identity is asserted so the fresh-fleet loop below
  -- is knowingly testing both denominators at once; the damaged re-entry afterwards is where they
  -- part ways and the capacity one is proven to be the one in charge.
  -- alias u, mirroring the 0310 arm: cu is exactly the alias that was ambiguous inside the tick
  -- (a declared record variable there), and the one alias worth removing on sight everywhere.
  select sum(msi.max_hp)::double precision into v_cap
    from public.combat_units u
    join public.main_ship_instances msi on msi.main_ship_id = u.main_ship_id
   where u.encounter_id = v_enc and u.side = 'player' and u.main_ship_id is not null;
  if v_cap is null or v_cap <= 0 then
    raise exception 'AUTOEXIT FAIL: no capacity resolved for group A''s encounter (member units missing?)';
  end if;
  if abs(v_cap - v_imax) > 1e-6 then
    raise exception 'AUTOEXIT FAIL: a factory-fresh fleet''s capacity (%) differs from its entry integrity (%) — the fresh-fleet staging premise is broken', v_cap, v_imax;
  end if;
  v_thresh := v_cap * 0.50;

  -- ── THE LOOP: the REAL tick does the damage; every tick is judged BOTH ways. A tick that ends
  --    'active' at-or-below the threshold is the pre-0310 defect — fail. A tick that ends
  --    'retreating' ABOVE the threshold fired early — fail. ────────────────────────────────────────
  for i in 1..60 loop
    perform pg_temp.ae_tick(v_enc);
    select * into enc from public.combat_encounters where id = v_enc;
    v_hp := enc.player_integrity_current;
    if enc.status = 'active' then
      if v_hp <= v_thresh then
        raise exception 'AUTOEXIT FAIL: tick % ended active at hull %/% (threshold %) — the fleet never auto-requested leave (the pre-0310 world)',
          i, v_hp, v_imax, v_thresh;
      end if;
      n_above := n_above + 1;
    elsif enc.status = 'retreating' then
      if v_hp > v_thresh + 1e-6 then
        raise exception 'AUTOEXIT FAIL: the fleet auto-exited ABOVE its threshold (hull %/% > %)', v_hp, v_imax, v_thresh;
      end if;
      v_flipped := true;
      exit;
    else
      raise exception 'AUTOEXIT FAIL: encounter reached % mid-loop (hull %/%) — the staging died before the threshold', enc.status, v_hp, v_imax;
    end if;
  end loop;
  if not v_flipped then
    raise exception 'AUTOEXIT FAIL: 60 ticks never crossed the 50%% threshold (hull still %/%) — the derived attack knob is wrong, not the feature', v_hp, v_imax;
  end if;
  if n_above < 1 then
    raise exception 'AUTOEXIT FAIL: never observed above threshold — the first tick already crossed it, so "does not fire early" was not exercised (vacuous)';
  end if;
  if v_hp <= 0 then
    raise exception 'AUTOEXIT FAIL: the fleet is at 0 hull — it died instead of leaving; the safety line failed its one job';
  end if;
  v_hp_a := v_hp; v_imax_a := v_imax;  -- group A's flip numbers, before the control reuses the locals

  -- ── The flip is the CANONICAL retreat, not a lookalike: presence + encounter + timer + the ONE
  --    event, all stamped by the composed authority. ───────────────────────────────────────────────
  select * into prs from public.location_presence where id = enc.presence_id;
  if prs.status is distinct from 'retreating' or prs.retreat_requested_at is null then
    raise exception 'AUTOEXIT FAIL: presence is %/% — presence_request_leave did not arm the retreat', prs.status, prs.retreat_requested_at;
  end if;
  if enc.retreat_started_at is null then
    raise exception 'AUTOEXIT FAIL: retreat_started_at is unset — combat_set_retreating never ran, the completion branch could never finish this';
  end if;
  select count(*) into n from public.combat_events where encounter_id = v_enc and event_type = 'retreat_started';
  if n <> 1 then
    raise exception 'AUTOEXIT FAIL: % retreat_started event(s) (want exactly 1 — the one author is combat_set_retreating)', n;
  end if;
  v_started := enc.retreat_started_at;

  -- ── A second tick must NOT re-request (the encounter is 'retreating'; the arm is unreachable). ──
  perform pg_temp.ae_tick(v_enc);
  select * into enc from public.combat_encounters where id = v_enc;
  if enc.status is distinct from 'retreating' or enc.retreat_started_at is distinct from v_started then
    raise exception 'AUTOEXIT FAIL: a second tick re-requested the retreat (status %, timer % -> %)', enc.status, v_started, enc.retreat_started_at;
  end if;
  select count(*) into n from public.combat_events where encounter_id = v_enc and event_type = 'retreat_started';
  if n <> 1 then
    raise exception 'AUTOEXIT FAIL: a second tick re-requested the retreat (% retreat_started events)', n;
  end if;

  -- ── And it COMPLETES like a human press: rewind the retreat clock past the delay window (the
  --    drain_encounter idiom — now() is frozen in-txn), one tick, and the completion branch ends
  --    the fight and turns the fleet home (no destination was ordered → the origin-base arm). ─────
  update public.combat_encounters set retreat_started_at = retreat_started_at - interval '1 hour' where id = v_enc;
  perform pg_temp.ae_tick(v_enc);
  select * into enc from public.combat_encounters where id = v_enc;
  if enc.status is distinct from 'escaped' then
    raise exception 'AUTOEXIT FAIL: the auto-requested retreat did not complete like a human press (encounter % after the delay window)', enc.status;
  end if;
  select status into v_txt from public.fleets where id = v_fleet;
  if v_txt is distinct from 'returning' then
    raise exception 'AUTOEXIT FAIL: the fleet is % after completion (want returning — fleet_set_returning is the completion''s own verb)', v_txt;
  end if;

  -- ── THE DAMAGED RE-ENTRY — the regression the capacity denominator exists for. ─────────────────
  -- The same fleet, UN-REPAIRED (repair needs a port; it retreated to open coordinates), goes out
  -- again and is ambushed again. Its entry hull is now well under its capacity, so the encounter's
  -- own player_integrity_max (seeded from the CURRENT hull) and the real capacity DIVERGE — and
  -- that divergence is asserted, or this scenario proves nothing. With the player's threshold
  -- raised to 60%, the fleet enters ALREADY below the line and must auto-exit on the FIRST tick.
  -- A body measuring the entry hull reads that tick as ~94% of "max" and fights on — this exact
  -- assert is what fails on the cb10020 denominator, and what stops the compounding spiral
  -- (capacity 1000 -> exit 300 -> next "max" 300 -> exit 90 -> 27 -> dead before the arm runs).
  --
  -- First, land the return leg so the group is commandable again (the MANIFESTHELD idiom: clocks
  -- only, the settle itself is the real processor).
  for i in 1..10 loop
    exit when not exists (select 1 from public.fleet_movements where fleet_id = v_fleet and status = 'moving');
    update public.fleet_movements set depart_at = depart_at - interval '1 hour',
                                      arrive_at = arrive_at - interval '1 hour'
     where fleet_id = v_fleet and status = 'moving';
    perform public.process_fleet_movements();
  end loop;
  if exists (select 1 from public.fleet_movements where fleet_id = v_fleet and status = 'moving') then
    raise exception 'AUTOEXIT FAIL: group A''s return leg never settled — the re-entry cannot be staged';
  end if;

  -- The un-repaired hull, from the ship's own row (the tick synced it all fight long).
  select msi.hp::double precision, msi.max_hp::double precision into v_hp, v_cap
    from public.main_ship_instances msi where msi.main_ship_id = sA;
  if v_hp is null or v_hp <= 0 then
    raise exception 'AUTOEXIT FAIL: group A''s ship reads hull % after its fight — the re-entry needs a damaged, living ship', v_hp;
  end if;
  if v_hp >= v_cap * 0.60 then
    raise exception 'AUTOEXIT FAIL: group A''s ship still holds %/% hull — not below the 60%% re-entry threshold, so the first-tick exit could not be attributed to the capacity denominator (staging, not feature)', v_hp, v_cap;
  end if;

  -- The player raises the line to 60 — through the ONE writer, like every adjustment here.
  r := pg_temp.call_as(uA, format('public.set_group_auto_exit(%L::uuid, true, 60)', gA));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: set 60 on A: %', r; end if;

  -- Out again, through the SAME standing zone corridor (the fleet completed at its Home Base,
  -- whose coordinate is the starter port's anchor — the same origin the first leg flew from).
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gA, round(o_x), round(o_y + 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: re-entry go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into pi from public.pirate_intercepts where movement_id = v_mv and lifecycle_state = 'pending';
  if pi is null then raise exception 'AUTOEXIT FAIL: the re-entry leg scheduled no ambush (the standing zone should cover it)'; end if;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id into v_enc3 from public.combat_encounters where player_id = uA and status = 'active';
  if v_enc3 is null then raise exception 'AUTOEXIT FAIL: the re-entry ambush opened no encounter'; end if;

  -- THE DIVERGENCE, ASSERTED: entry integrity (seeded from the damaged hull) strictly under
  -- capacity. Equal values would mean this scenario cannot tell the two denominators apart.
  select player_integrity_max into v_imax3 from public.combat_encounters where id = v_enc3;
  select sum(msi.max_hp)::double precision into v_cap3
    from public.combat_units u
    join public.main_ship_instances msi on msi.main_ship_id = u.main_ship_id
   where u.encounter_id = v_enc3 and u.side = 'player' and u.main_ship_id is not null;
  if v_cap3 is null or v_imax3 is null or v_imax3 >= v_cap3 then
    raise exception 'AUTOEXIT FAIL: entry integrity % is not strictly below capacity % — the two denominators do not differ and the re-entry proves nothing', v_imax3, v_cap3;
  end if;
  if v_imax3 >= v_cap3 * 0.60 then
    raise exception 'AUTOEXIT FAIL: the fleet re-entered at %/% — not below its 60%% line; the first-tick exit would be ambiguous', v_imax3, v_cap3;
  end if;

  -- ONE tick. Below the capacity line from the first evaluation → the canonical retreat, now.
  perform pg_temp.ae_tick(v_enc3);
  select * into enc from public.combat_encounters where id = v_enc3;
  if enc.status is distinct from 'retreating' then
    raise exception 'AUTOEXIT FAIL: the un-repaired fleet (%/% of capacity, threshold 60%%) did not auto-exit on entry (the compounding-denominator defect: the arm is measuring the damaged entry hull, not real capacity)',
      enc.player_integrity_current, v_cap3;
  end if;
  if enc.player_integrity_current <= 0 then
    raise exception 'AUTOEXIT FAIL: the re-entered fleet is at 0 hull — it died on the entry tick instead of leaving';
  end if;
  select count(*) into n from public.combat_events where encounter_id = v_enc3 and event_type = 'retreat_started';
  if n <> 1 then
    raise exception 'AUTOEXIT FAIL: the re-entry exit armed % retreat_started event(s) (want exactly 1)', n;
  end if;

  -- ── GROUP B, THE CONTROL: toggle OFF → the pre-0310 world, far below the default threshold. ────
  select l.x, l.y into o_x, o_y
    from public.main_ship_instances s
    join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = uA and f.status = 'present'
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
    join public.locations l on l.id = lp.location_id
   where s.group_id = gB2
   limit 1;
  if o_x is null then raise exception 'AUTOEXIT FAIL: could not resolve group B''s docked origin'; end if;
  v_verts := jsonb_build_array(
    jsonb_build_array(o_x - 100, o_y - 600),
    jsonb_build_array(o_x + 100, o_y - 600),
    jsonb_build_array(o_x + 100, o_y - 400),
    jsonb_build_array(o_x - 100, o_y - 400));
  r := pg_temp.call_as(uA, format('public.pirate_zone_create(%L, %L::jsonb, %L::uuid)',
                                  'DZC Auto Exit Control Zone', v_verts::text, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: control zone: %', r; end if;
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, %s, %s)',
                                  gB2, round(o_x), round(o_y - 1000)));
  if (r->>'ok')::boolean is not true then raise exception 'AUTOEXIT FAIL: go B: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  select * into mv from public.fleet_movements where id = v_mv;
  perform pg_temp.rewind_leg(v_mv, (mv.arrive_at - now()) + interval '5 seconds');
  perform public.process_fleet_movements();
  select id, fleet_id into v_enc2, v_fleet from public.combat_encounters
   where player_id = uA and status = 'active';
  if v_enc2 is null then raise exception 'AUTOEXIT FAIL: the control ambush opened no encounter for group B'; end if;
  if v_enc2 = v_enc then raise exception 'AUTOEXIT FAIL: the control resolved onto group A''s (escaped) encounter — staging is tangled'; end if;

  select player_integrity_max into v_imax from public.combat_encounters where id = v_enc2;
  -- re-derive the knob from THIS fight's own numbers (its wave snapshots at ITS first tick).
  select coalesce(max(defense_snapshot), 0) into v_def from public.combat_units
   where encounter_id = v_enc2 and side = 'player';
  select l.base_difficulty into v_bd
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc2;
  if v_bd is null or v_bd <= 0 then raise exception 'AUTOEXIT FAIL: the control encounter''s location has base_difficulty %', v_bd; end if;
  v_eab := round(((0.06 * v_imax) * ((100 + v_def) / 100.0) / (v_bd * 1.25))::numeric, 6);
  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab));
  for i in 1..60 loop
    perform pg_temp.ae_tick(v_enc2);
    select * into enc from public.combat_encounters where id = v_enc2;
    v_hp := enc.player_integrity_current;
    if enc.status is distinct from 'active' then
      raise exception 'AUTOEXIT FAIL: the control fleet auto-exited with the toggle OFF (encounter % at hull %/%)', enc.status, v_hp, v_imax;
    end if;
    exit when v_hp <= v_imax * 0.20;
  end loop;
  if v_hp > v_imax * 0.30 then
    raise exception 'AUTOEXIT FAIL: the control never sank below the default 30%% threshold (hull %/%) — "toggle OFF keeps fighting" was not exercised (vacuous)', v_hp, v_imax;
  end if;
  select count(*) into n from public.combat_events where encounter_id = v_enc2 and event_type = 'retreat_started';
  if n <> 0 then
    raise exception 'AUTOEXIT FAIL: the control fleet auto-exited with the toggle OFF (% retreat_started events)', n;
  end if;

  perform public.set_game_config('enemy_attack_base', to_jsonb(v_eab_before));
  perform public.set_game_config('shield_regen_combat_pct', to_jsonb(v_srg_before));

  raise notice 'DZCOMBAT_PASS_AUTOEXIT ok: default ON at 30 for fresh groups; the player set 50%% / toggled OFF through the one writer (bad pct, NaN, null toggle, cross-player all refused; the table CHECK refuses NaN/150 beneath it); group A fought % tick(s) above its CAPACITY-based threshold untouched, then auto-requested the canonical retreat the tick its hull hit %/% of capacity (presence retreating, retreat_started_at stamped, exactly 1 retreat_started event), a second tick did not re-request, and the retreat COMPLETED like a human press (escaped, fleet returning, origin-base arm); the DAMAGED RE-ENTRY (entry integrity % strictly under capacity %, threshold 60) auto-exited on its FIRST tick — the compounding-denominator regression, closed; group B — toggle OFF — fought on to %/% with zero retreat events: the pre-0310 world, reproduced as the control',
    n_above, round(v_hp_a::numeric), round(v_imax_a::numeric), round(v_imax3::numeric), round(v_cap3::numeric), round(v_hp::numeric), round(v_imax::numeric);
end $$;

do $$ begin raise notice 'DANGER-ZONE COMBAT PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
