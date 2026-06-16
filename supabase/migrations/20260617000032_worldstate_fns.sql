-- Byeharu — M5: World State functions + integration edges.
--
-- Adds the three World State writers (register/unregister/tick), a service-role-only
-- dev helper for the integration test, and wires the two presence lifecycle edges
-- (presence_create → register, presence_complete → unregister). Finally it gives
-- Combat a READ-ONLY danger_modifier multiplier — Combat never writes World State.
--
-- BOUNDARY NOTES:
--  · Only worldstate_* functions write location_state/zone_state.
--  · presence_* do NOT touch those tables directly — they call the worldstate edges.
--  · process_combat_ticks only READS location_state.danger_modifier (Rule B).
--  · All balance numbers come from game_config (Rule D) — no magic numbers.

-- ── 1) Config keys (no hardcoded balance in functions) ───────────────────────
insert into public.game_config (key, value, description) values
  ('worldstate_tick_seconds',                  '60',   'cron cadence for process_location_state_ticks()'),
  ('worldstate_min_tick_seconds',              '30',   'min elapsed before a tick re-applies drift (idempotency guard)'),
  ('worldstate_pressure_min',                  '0',    'pressure floor (calm)'),
  ('worldstate_pressure_max',                  '100',  'pressure ceiling (severe)'),
  ('worldstate_pressure_baseline',             '50',   'normal pressure; danger_modifier = 1.0 here'),
  ('worldstate_pressure_drift_per_tick',       '2',    'passive pressure rise per applied tick'),
  ('worldstate_pressure_relief_per_active_fleet','3',  'pressure relieved per active fleet hunting here'),
  ('worldstate_pressure_defeat_increase',      '4',    'pressure per recent defeat (TODO: not yet wired in M5)'),
  ('worldstate_danger_min_modifier',           '0.95', 'danger_modifier at pressure_min'),
  ('worldstate_danger_max_modifier',           '1.20', 'danger_modifier at pressure_max')
on conflict (key) do nothing;

-- ── 2) worldstate_register_presence: cache increment on a new presence ───────
create or replace function public.worldstate_register_presence(p_location uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_location is null then return; end if;
  insert into location_state (location_id, active_fleets)
    values (p_location, 1)
  on conflict (location_id) do update
    set active_fleets = location_state.active_fleets + 1,
        updated_at = now();
end;
$$;

-- ── 3) worldstate_unregister_presence: cache decrement, floored at 0 ──────────
create or replace function public.worldstate_unregister_presence(p_location uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_location is null then return; end if;
  update location_state
    set active_fleets = greatest(0, active_fleets - 1),
        updated_at = now()
  where location_id = p_location;
end;
$$;

-- ── 4) worldstate_tick: the 60s living-world heartbeat ───────────────────────
-- Per location_state row: reconcile active_fleets from the REAL presence rows
-- (cache may have drifted), apply pressure drift/relief if enough time elapsed,
-- recompute the bounded danger_modifier, write back. Then roll up zone_state.
-- Pure World State: never moves fleets, spawns combat, grants rewards, or writes
-- any other system's tables.
create or replace function public.worldstate_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_min        double precision := coalesce(cfg_num('worldstate_pressure_min'), 0);
  v_max        double precision := coalesce(cfg_num('worldstate_pressure_max'), 100);
  v_baseline   double precision := coalesce(cfg_num('worldstate_pressure_baseline'), 50);
  v_drift      double precision := coalesce(cfg_num('worldstate_pressure_drift_per_tick'), 2);
  v_relief     double precision := coalesce(cfg_num('worldstate_pressure_relief_per_active_fleet'), 3);
  v_min_mod    double precision := coalesce(cfg_num('worldstate_danger_min_modifier'), 0.95);
  v_max_mod    double precision := coalesce(cfg_num('worldstate_danger_max_modifier'), 1.20);
  v_min_secs   double precision := coalesce(cfg_num('worldstate_min_tick_seconds'), 30);
  r            location_state%rowtype;
  v_real       integer;
  v_elapsed    double precision;
  v_drifted    boolean;
  v_pressure   double precision;
  v_mod        double precision;
  v_count      integer := 0;
begin
  for r in select * from location_state for update skip locked loop
    -- (1) Reconcile active_fleets from the source of truth (active presences).
    select count(*) into v_real
      from location_presence
      where location_id = r.location_id and status in ('active','retreating','leaving');

    v_elapsed  := extract(epoch from (now() - r.last_tick_at));
    v_pressure := r.pressure;
    v_drifted  := v_elapsed >= v_min_secs;

    -- (2) Apply drift only when enough time has passed → double-call is a no-op.
    if v_drifted then
      -- passive drift up; relief down from fleets actively hunting here.
      -- defeat_pressure TODO (M5+): add recent-defeat reads from combat_reports.
      v_pressure := v_pressure + v_drift - (v_real * v_relief);
      v_pressure := least(v_max, greatest(v_min, v_pressure));
    end if;

    -- (3) Danger modifier from pressure — piecewise so baseline maps to exactly
    --     1.0 (keeps M4 balance until pressure actually moves). Bounded both ends.
    if v_pressure >= v_baseline then
      v_mod := 1.0 + ((v_pressure - v_baseline) / nullif(v_max - v_baseline, 0)) * (v_max_mod - 1.0);
    else
      v_mod := v_min_mod + ((v_pressure - v_min) / nullif(v_baseline - v_min, 0)) * (1.0 - v_min_mod);
    end if;
    v_mod := least(v_max_mod, greatest(v_min_mod, coalesce(v_mod, 1.0)));

    update location_state set
      active_fleets   = v_real,
      pressure        = round(v_pressure)::integer,
      danger_modifier = v_mod,
      last_tick_at    = case when v_drifted then now() else last_tick_at end,
      updated_at      = now()
    where location_id = r.location_id;

    v_count := v_count + 1;
  end loop;

  -- (4) Roll up zone_state from its member locations.
  update zone_state z set
    avg_pressure        = sub.avg_p,
    avg_danger_modifier = sub.avg_d,
    active_fleets       = sub.sum_f,
    last_tick_at        = now(),
    updated_at          = now()
  from (
    select l.zone_id,
           avg(ls.pressure)        as avg_p,
           avg(ls.danger_modifier) as avg_d,
           coalesce(sum(ls.active_fleets), 0) as sum_f
    from location_state ls
    join locations l on l.id = ls.location_id
    group by l.zone_id
  ) sub
  where z.zone_id = sub.zone_id;

  return v_count;
end;
$$;

-- ── 5) Dev/test helper: prime a location_state row for the integration test ──
-- SERVICE-ROLE ONLY (mirrors dev_reset_player). Lets verify-m5 set active_fleets,
-- backdate last_tick_at, and optionally force pressure — without granting any
-- client the ability to mutate world state.
create or replace function public.dev_worldstate_prime(
  p_location uuid, p_active_fleets integer, p_age_seconds double precision, p_pressure integer default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update location_state set
    active_fleets = greatest(0, coalesce(p_active_fleets, active_fleets)),
    pressure      = greatest(0, coalesce(p_pressure, pressure)),
    last_tick_at  = now() - make_interval(secs => coalesce(p_age_seconds, 0)),
    updated_at    = now()
  where location_id = p_location;
end;
$$;

-- ── 6) Presence edge: register on create ─────────────────────────────────────
-- Re-create presence_create (owner: Presence) adding the World State edge. Body is
-- otherwise identical to 0008. Presence does NOT write location_state itself — it
-- calls the worldstate writer (the only allowed cross-system path).
create or replace function public.presence_create(
  p_player uuid, p_fleet uuid, p_sector uuid, p_zone uuid, p_location uuid, p_activity text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into location_presence
    (player_id, fleet_id, sector_id, zone_id, location_id, activity_type, status, last_tick_at)
    values (p_player, p_fleet, p_sector, p_zone, p_location, p_activity, 'active', now())
    returning id into v_id;

  -- World State edge: a fleet is now present here (cache++, reconciled by tick).
  perform worldstate_register_presence(p_location);

  perform activity_start(v_id, p_activity);
  return v_id;
end;
$$;

-- ── 7) Presence edge: unregister on complete ─────────────────────────────────
-- Re-create presence_complete (owner: Presence). EVERY terminal presence path
-- (safe-leave, combat escape, combat defeat) funnels through here, so this is the
-- single authoritative unregister point.
create or replace function public.presence_complete(p_presence uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loc uuid;
begin
  update location_presence
    set status = 'completed', updated_at = now()
    where id = p_presence and status in ('active','retreating','leaving')
    returning location_id into v_loc;
  if not found then
    raise exception 'presence_complete: presence % not in an active state', p_presence;
  end if;

  -- World State edge: fleet no longer present (cache--, reconciled by tick).
  perform worldstate_unregister_presence(v_loc);
end;
$$;

-- ── 8) Combat READ integration: scale pirate HP + attack by danger_modifier ──
-- Re-create process_combat_ticks (owner: Combat) — identical to 0030 EXCEPT it
-- now reads location_state.danger_modifier once per encounter and multiplies the
-- spawned wave's HP and attack by it. Combat NEVER writes location_state. Missing
-- / invalid modifier falls back to 1.0 so combat can never break (M4 stays green).
create or replace function public.process_combat_ticks()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  e               combat_encounters%rowtype;
  pr              location_presence%rowtype;
  loc             record;
  cu              record;
  v_tick          integer;
  v_tick_secs     double precision;
  v_retreat_delay double precision;
  v_trans_secs    double precision;
  v_var_pct       double precision;
  v_def_base      double precision;
  v_danger_mod    double precision;
  v_secs_inside   double precision;
  v_max_secs      double precision;
  v_forced        boolean;
  v_retreat_done  boolean;
  v_danger        integer;
  v_variance      double precision;
  v_attack        double precision;
  v_defense       double precision;
  v_hp_total      double precision;
  v_alive_total   integer;
  v_wave_num      integer;
  v_enemy_hp      double precision;
  v_e_before      double precision;
  v_e_after       double precision;
  v_enemy_attack  double precision;
  v_player_damage double precision;
  v_final_player  double precision;
  v_cleared       boolean;
  v_offense       boolean;
  v_d_group       double precision;
  v_new_hp        double precision;
  v_new_alive     integer;
  v_destroyed     integer;
  v_losses        jsonb;
  v_counts        jsonb;
  v_snapshot      jsonb;
  v_hp_after      double precision;
  v_reward_metal  double precision;
  v_reward_delta  jsonb;
  v_seq           integer;
  v_end           text;
  v_base_id       uuid;
  v_base_x        double precision;
  v_base_y        double precision;
  v_loc_x         double precision;
  v_loc_y         double precision;
  v_speed         double precision;
  v_mv            uuid;
  v_count         integer := 0;
begin
  v_tick_secs     := coalesce(cfg_num('combat_tick_seconds'), 3);
  v_retreat_delay := coalesce(cfg_num('retreat_delay_seconds'), 8);
  v_trans_secs    := coalesce(cfg_num('wave_transition_seconds'), 3);
  v_var_pct       := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
  v_def_base      := coalesce(cfg_num('defense_curve_base'), 100);

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
    v_tick := e.tick_number + 1;
    select * into pr from location_presence where id = e.presence_id;
    select base_difficulty, reward_tier, max_presence_seconds into loc from locations where id = e.location_id;

    -- World State READ (never write): high-pressure locations field tougher
    -- pirates. Fall back to 1.0 on missing/invalid so combat can never break.
    select danger_modifier into v_danger_mod from location_state where location_id = e.location_id;
    if v_danger_mod is null or v_danger_mod <= 0 then
      v_danger_mod := 1.0;
    end if;

    select coalesce(sum(ut.attack * cu2.alive_count), 0),
           coalesce(sum(ut.defense * cu2.alive_count), 0),
           coalesce(sum(cu2.hp_current), 0),
           coalesce(sum(cu2.alive_count), 0)
      into v_attack, v_defense, v_hp_total, v_alive_total
      from combat_units cu2 join unit_types ut on ut.id = cu2.unit_type_id
      where cu2.encounter_id = e.id;

    -- (A) Already destroyed → defeat, NO rewards.
    if v_hp_total <= 0 or v_alive_total <= 0 then
      perform fleet_destroy(e.fleet_id);
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), player_integrity_current=0, player_power_current=0,
             total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
      insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
             player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
        values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, 0, 0,
                e.enemy_integrity_current, e.enemy_integrity_current, 'defeat');
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, 0, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      perform report_create(e.id);
      v_count := v_count + 1; continue;
    end if;

    -- (B) End: retreat delay elapsed or forced auto-extract. Rewards are NOT
    --     deposited here — they ride the return movement and deposit on arrival.
    v_secs_inside  := extract(epoch from (now() - e.started_at));
    v_max_secs     := coalesce(loc.max_presence_seconds, cfg_num('max_presence_seconds_default'), 1800);
    v_forced       := v_secs_inside >= v_max_secs;
    v_retreat_done := e.status='retreating' and e.retreat_started_at is not null
                      and now() - e.retreat_started_at >= make_interval(secs => v_retreat_delay);
    if v_retreat_done or v_forced then
      v_end := case when v_forced and e.status <> 'retreating' then 'completed' else 'escaped' end;
      select origin_base_id into v_base_id from fleets where id = e.fleet_id;
      select x, y into v_base_x, v_base_y from bases where id = v_base_id;
      select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
      v_speed := fleet_speed(e.fleet_id);
      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform presence_complete(e.presence_id);
      v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
                              'base', v_base_id, null, null, v_base_x, v_base_y, 'return_home', v_speed);
      perform fleet_set_returning(e.fleet_id, v_mv);
      -- Carry pending rewards home (deposited on arrival by process_fleet_movements).
      if e.total_rewards_json is not null and e.total_rewards_json <> '{}'::jsonb then
        perform movement_attach_cargo(v_mv, e.id, e.total_rewards_json);
      end if;
      insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
             player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, reward_delta_json, result)
        values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, v_hp_total, v_hp_total,
                e.enemy_integrity_current, e.enemy_integrity_current, e.total_rewards_json, v_end);
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, 0, 'retreat_completed', 'player', 'player', jsonb_build_object('forced', v_forced));
      v_count := v_count + 1; continue;
    end if;

    -- (C) Combat step.
    v_danger       := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
    v_variance     := (1 - v_var_pct) + random() * (2 * v_var_pct);
    v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                      * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25)) * v_danger_mod;
    v_seq          := 0;
    v_offense      := (e.status = 'active');
    v_wave_num     := e.wave_number;

    if e.enemy_integrity_current <= 0 then
      if e.next_wave_at is not null and now() < e.next_wave_at then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
          values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
        update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
        v_count := v_count + 1; continue;
      end if;
      v_wave_num := e.waves_cleared + 1;
      v_enemy_hp := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                    * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance * v_danger_mod;
      v_e_before := v_enemy_hp;
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp)));
      v_seq := v_seq + 1;
    else
      v_enemy_hp := e.enemy_integrity_max;
      v_e_before := e.enemy_integrity_current;
    end if;

    if v_offense then
      v_player_damage := v_attack * v_variance;
      v_e_after := v_e_before - v_player_damage;
      v_cleared := v_e_after <= 0;
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'missile_salvo', 'player', 'pirate', 'missile', greatest(1, round(v_attack/50)::integer), 400,
                jsonb_build_object('damage', round(v_player_damage), 'wave', v_wave_num));
      v_seq := v_seq + 1;
    else
      v_player_damage := 0; v_e_after := v_e_before; v_cleared := false;
    end if;

    insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms)
      values (e.id, e.player_id, v_tick, v_seq, 'laser_burst', 'pirate', 'player', 'laser', greatest(1, v_danger), 600);
    v_seq := v_seq + 1;
    v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;

    v_losses := '{}'::jsonb; v_counts := '{}'::jsonb; v_snapshot := '{}'::jsonb;
    for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 loop
      v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
      v_new_hp    := cu.hp_current - v_d_group;
      v_new_alive := greatest(0, least(cu.alive_count, ceil(v_new_hp / cu.ship_hp)::integer));
      v_destroyed := cu.alive_count - v_new_alive;
      update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive, updated_at = now()
        where id = cu.id;
      v_counts   := v_counts   || jsonb_build_object(cu.unit_type_id, v_new_alive);
      v_snapshot := v_snapshot || jsonb_build_object(cu.unit_type_id,
                       jsonb_build_object('alive', v_new_alive, 'hp', round(greatest(0, v_new_hp))));
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'hull_damage', 'pirate', 'player',
                jsonb_build_object('group', cu.unit_type_id, 'damage', round(v_d_group)));
      v_seq := v_seq + 1;
      if v_destroyed > 0 then
        v_losses := v_losses || jsonb_build_object(cu.unit_type_id, v_destroyed);
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed', 'pirate', 'player',
                  jsonb_build_object('group', cu.unit_type_id, 'count', v_destroyed));
        v_seq := v_seq + 1;
      end if;
    end loop;

    perform fleet_sync_quantities(e.fleet_id, v_counts);
    select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id;

    v_reward_metal := 0; v_reward_delta := '{}'::jsonb;
    if v_cleared and v_offense then
      v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                              * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
      v_reward_delta := jsonb_build_object('metal', v_reward_metal);
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal));
      v_seq := v_seq + 1;
    end if;

    insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
           player_power_before, enemy_power, player_damage, enemy_damage,
           player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after,
           player_losses_json, reward_delta_json, unit_snapshot_json, result)
      values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
              v_hp_total, v_e_before, v_player_damage, v_final_player,
              v_hp_total, greatest(0, v_hp_after), v_e_before, greatest(0, v_e_after),
              v_losses, v_reward_delta, v_snapshot,
              case when v_cleared then 'wave_cleared' else 'ongoing' end);

    update combat_encounters set
      tick_number              = v_tick,
      danger_level             = v_danger,
      wave_number              = v_wave_num,
      waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),
      player_integrity_current = greatest(0, v_hp_after),
      enemy_integrity_max      = v_enemy_hp,
      enemy_integrity_current  = case when v_cleared then 0 else greatest(0, v_e_after) end,
      enemy_power_current      = case when v_cleared then 0 else greatest(0, v_e_after) end,
      next_wave_at             = case when v_cleared then now() + make_interval(secs => v_trans_secs) else e.next_wave_at end,
      player_power_current     = fleet_get_power(e.fleet_id),
      total_rewards_json       = case when v_cleared and v_offense
                                   then total_rewards_json || jsonb_build_object(
                                          'metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                   else total_rewards_json end,
      last_resolved_at         = now(),
      updated_at               = now()
    where id = e.id;

    if v_hp_after <= 0 then
      perform fleet_destroy(e.fleet_id);
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      perform report_create(e.id);
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ── 9) Re-lock execute surface (anti-cheat). New functions were added. ───────
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;

-- World State internals: server/cron only. Granted to service_role so the
-- integration test runner (server-side secret key) can drive them. NEVER granted
-- to anon/authenticated → browser clients cannot mutate world state.
grant execute on function public.worldstate_tick()                                     to service_role;
grant execute on function public.dev_worldstate_prime(uuid, integer, double precision, integer) to service_role;
