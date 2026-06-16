-- Byeharu — M4 cleanup:
--  1) Extract remaining hard-coded combat constants into game_config.
--  2) Shift combat reward deposit from escape → return-home arrival (rewards stay
--     pending/locked while the fleet travels; deposited once on arrival; idempotent;
--     none on defeat). Implemented via a payload carried on the return movement and
--     deposited by the Movement processor's return branch.
--  3) Drop the dead fleet_apply_losses() (superseded by combat_units + fleet_sync).

-- 1) Config knobs --------------------------------------------------------------
insert into public.game_config (key, value, description) values
  ('reward_danger_scale',         '0.25', 'reward growth per danger level'),
  ('danger_time_divisor_seconds', '180',  'seconds in combat per +1 danger from time'),
  ('combat_damage_variance_pct',  '0.10', 'combat damage ± variance fraction'),
  ('defense_curve_base',          '100',  'base in mitigation 100/(base+defense)')
on conflict (key) do nothing;

-- 2a) Return movement carries the pending reward payload home -------------------
alter table public.fleet_movements
  add column if not exists reward_grant_source uuid,
  add column if not exists reward_payload_json jsonb not null default '{}'::jsonb;

-- Movement-owned setter so Combat doesn't write fleet_movements directly.
create or replace function public.movement_attach_cargo(p_movement uuid, p_source_id uuid, p_rewards jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update fleet_movements set reward_grant_source = p_source_id, reward_payload_json = coalesce(p_rewards, '{}'::jsonb)
    where id = p_movement;
end;
$$;

-- 2b) Movement processor: deposit carried rewards once on home arrival ----------
create or replace function public.process_fleet_movements()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  m         record;
  v_loc     record;
  v_units   jsonb;
  v_count   integer := 0;
begin
  for m in
    select * from fleet_movements
    where status = 'moving' and arrive_at <= now()
    for update skip locked
  loop
    if m.target_type = 'location' then
      select l.activity_type as activity, l.zone_id as zone_id, z.sector_id as sector_id
        into v_loc from locations l join zones z on z.id = l.zone_id where l.id = m.target_location_id;
      update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
      perform fleet_set_present(m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id);
      perform presence_create(m.player_id, m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id, v_loc.activity);

    elsif m.target_type = 'base' then
      select jsonb_agg(jsonb_build_object('unit_type_id', unit_type_id, 'quantity', quantity))
        into v_units from fleet_units where fleet_id = m.fleet_id and quantity > 0;
      update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
      if v_units is not null then
        perform base_merge_units(m.target_base_id, v_units);
      end if;
      perform fleet_complete(m.fleet_id);
      -- Deposit combat rewards now that the fleet is safely home (idempotent via
      -- reward_grants unique source). Nothing happens for non-combat returns.
      if m.reward_payload_json is not null and m.reward_payload_json <> '{}'::jsonb and m.reward_grant_source is not null then
        perform reward_grant('combat', m.reward_grant_source, m.player_id, m.target_base_id, m.reward_payload_json);
      end if;

    else
      update fleet_movements set status = 'failed', resolved_at = now() where id = m.id;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- 2c) Combat tick: attach rewards to the return movement instead of granting now -
--     + use config constants for variance / danger-time / reward-scale / defense.
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
                      * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
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
                    * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
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

-- 3) Drop the dead function (nothing live calls it) ----------------------------
drop function if exists public.fleet_apply_losses(uuid, double precision);

-- Re-lock: a new function (movement_attach_cargo) was added.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
