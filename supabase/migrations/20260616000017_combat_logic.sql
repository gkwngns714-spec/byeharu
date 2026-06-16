-- Byeharu — M4: Combat logic (Combat system).
--
-- combat_create_encounter() is invoked by Presence.activity_start (hunt_pirates).
-- process_combat_ticks() is the 2s server-authoritative step. It hands off ONLY via
-- approved functions: Fleet (stats/losses/state), Reward (grant→Base), Report,
-- Presence (complete), Movement (return). It never writes Map/Movement/Fleet/Base
-- tables directly. Idempotent + FOR UPDATE SKIP LOCKED.

create or replace function public.combat_create_encounter(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pr      location_presence%rowtype;
  v_power double precision;
  v_enc   uuid;
begin
  select * into pr from location_presence where id = p_presence;
  if not found then
    raise exception 'combat_create_encounter: presence % not found', p_presence;
  end if;

  v_power := fleet_get_power(pr.fleet_id);

  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current, last_resolved_at)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, now())
  returning id into v_enc;

  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (v_enc, pr.player_id, 0, 0, 'wave_spawned', 'pirate', 'player', jsonb_build_object('danger', 1));

  return v_enc;
end;
$$;

create or replace function public.combat_set_retreating(p_encounter uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  e combat_encounters%rowtype;
begin
  update combat_encounters set status = 'retreating', updated_at = now()
    where id = p_encounter and status = 'active'
    returning * into e;
  if not found then
    raise exception 'combat_set_retreating: encounter % not active', p_encounter;
  end if;
  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (p_encounter, e.player_id, e.tick_number, 0, 'retreat_started', 'player', 'player', '{}'::jsonb);
end;
$$;

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
  v_tick          integer;
  v_tick_secs     double precision;
  v_retreat_delay double precision;
  v_secs_inside   double precision;
  v_max_secs      double precision;
  v_forced        boolean;
  v_retreat_done  boolean;
  v_power         double precision;
  v_stats         jsonb;
  v_attack        double precision;
  v_defense       double precision;
  v_hull          double precision;
  v_variance      double precision;
  v_danger        integer;
  v_enemy_before  double precision;
  v_enemy_after   double precision;
  v_player_damage double precision;
  v_final_player  double precision;
  v_loss_ratio    double precision;
  v_losses        jsonb;
  v_cleared       boolean;
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
  v_tick_secs     := coalesce(cfg_num('combat_tick_seconds'), 2);
  v_retreat_delay := coalesce(cfg_num('retreat_delay_seconds'), 20);

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
    v_tick := e.tick_number + 1;
    select * into pr from location_presence where id = e.presence_id;
    select base_difficulty, reward_tier, max_presence_seconds into loc
      from locations where id = e.location_id;
    v_power := fleet_get_power(e.fleet_id);

    -- (A) Defeat — no surviving power.
    if v_power <= 0 then
      perform fleet_destroy(e.fleet_id);
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), player_power_current=0, updated_at=now() where id=e.id;
      insert into combat_ticks (encounter_id, player_id, tick_number, danger_level,
             player_power_before, enemy_power, result)
        values (e.id, e.player_id, v_tick, e.danger_level, 0, e.enemy_power_current, 'defeat');
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, 0, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      perform report_create(e.id);
      v_count := v_count + 1;
      continue;
    end if;

    -- (B) End: retreat delay elapsed, or forced auto-extract (safety cap).
    v_secs_inside  := extract(epoch from (now() - e.started_at));
    v_max_secs     := coalesce(loc.max_presence_seconds, cfg_num('max_presence_seconds_default'), 1800);
    v_forced       := v_secs_inside >= v_max_secs;
    v_retreat_done := e.status = 'retreating'
                      and pr.retreat_requested_at is not null
                      and now() - pr.retreat_requested_at >= make_interval(secs => v_retreat_delay);

    if v_retreat_done or v_forced then
      v_end := case when v_forced and e.status <> 'retreating' then 'completed' else 'escaped' end;
      select origin_base_id into v_base_id from fleets where id = e.fleet_id;
      select x, y into v_base_x, v_base_y from bases where id = v_base_id;
      select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
      v_speed := fleet_speed(e.fleet_id);

      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform reward_grant('combat', e.id, e.player_id, v_base_id, e.total_rewards_json);
      perform presence_complete(e.presence_id);
      v_mv := movement_create(
        e.player_id, e.fleet_id,
        'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
        'base', v_base_id, null, null, v_base_x, v_base_y,
        'return_home', v_speed);
      perform fleet_set_returning(e.fleet_id, v_mv);

      insert into combat_ticks (encounter_id, player_id, tick_number, danger_level,
             player_power_before, enemy_power, reward_delta_json, result)
        values (e.id, e.player_id, v_tick, e.danger_level, v_power, e.enemy_power_current,
                e.total_rewards_json, v_end);
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, 0, 'retreat_completed', 'player', 'player',
                jsonb_build_object('forced', v_forced));
      v_count := v_count + 1;
      continue;
    end if;

    -- (C) Normal combat step (one wave exchange).
    v_danger   := 1 + e.waves_cleared + floor(v_secs_inside / 180)::integer;
    v_stats    := fleet_combat_stats(e.fleet_id);
    v_attack   := (v_stats->>'attack')::double precision;
    v_defense  := (v_stats->>'defense')::double precision;
    v_hull     := greatest((v_stats->>'hull')::double precision, 1);
    v_variance := 0.9 + random() * 0.2;
    v_seq      := 0;

    if e.enemy_power_current <= 0 then
      v_enemy_before := loc.base_difficulty * (1 + v_danger * 0.3) * v_variance;
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                jsonb_build_object('danger', v_danger, 'strength', round(v_enemy_before)));
      v_seq := v_seq + 1;
    else
      v_enemy_before := e.enemy_power_current;
    end if;

    -- player fire (cosmetic)
    insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms)
      values (e.id, e.player_id, v_tick, v_seq, 'missile_salvo', 'player', 'pirate', 'missile', greatest(1, round(v_attack/50)::integer), 400);
    v_seq := v_seq + 1;

    v_player_damage := v_attack * v_variance;
    v_enemy_after   := v_enemy_before - v_player_damage;
    v_cleared       := v_enemy_after <= 0;

    -- pirate fire (cosmetic) + losses to player
    insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms)
      values (e.id, e.player_id, v_tick, v_seq, 'laser_burst', 'pirate', 'player', 'laser', greatest(1, v_danger), 600);
    v_seq := v_seq + 1;

    v_final_player := v_enemy_before * 100.0 / (100.0 + v_defense);
    v_loss_ratio   := least(1.0, v_final_player / v_hull);
    v_losses       := fleet_apply_losses(e.fleet_id, v_loss_ratio);

    insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
      values (e.id, e.player_id, v_tick, v_seq, 'hull_damage', 'pirate', 'player',
              jsonb_build_object('loss_ratio', round(v_loss_ratio::numeric, 3)));
    v_seq := v_seq + 1;
    if v_losses <> '{}'::jsonb then
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed', 'pirate', 'player', v_losses);
      v_seq := v_seq + 1;
    end if;

    v_reward_metal := 0;
    v_reward_delta := '{}'::jsonb;
    if v_cleared then
      v_reward_metal := round(
        coalesce(cfg_num('reward_metal_base'), 10)
        * greatest(loc.reward_tier, 1)
        * (1 + 0.25 * v_danger)
        * coalesce(cfg_num('reward_multiplier'), 1.0));
      v_reward_delta := jsonb_build_object('metal', v_reward_metal);
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate', jsonb_build_object('wave_cleared', true));
      v_seq := v_seq + 1;
    end if;

    insert into combat_ticks (encounter_id, player_id, tick_number, danger_level,
           player_power_before, enemy_power, player_damage, enemy_damage,
           player_losses_json, reward_delta_json, result)
      values (e.id, e.player_id, v_tick, v_danger, v_power, v_enemy_before,
              v_player_damage, v_final_player, v_losses, v_reward_delta,
              case when v_cleared then 'wave_cleared' else 'ongoing' end);

    update combat_encounters set
      tick_number          = v_tick,
      danger_level         = v_danger,
      waves_cleared        = waves_cleared + (case when v_cleared then 1 else 0 end),
      enemy_power_current  = case when v_cleared then 0 else v_enemy_after end,
      player_power_current = fleet_get_power(e.fleet_id),
      total_rewards_json   = case when v_cleared
                               then total_rewards_json || jsonb_build_object(
                                      'metal', coalesce((total_rewards_json->>'metal')::double precision, 0) + v_reward_metal)
                               else total_rewards_json end,
      last_resolved_at     = now(),
      updated_at           = now()
    where id = e.id;

    -- Wiped this tick → defeat now.
    if fleet_get_power(e.fleet_id) <= 0 then
      perform fleet_destroy(e.fleet_id);
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', ended_at=now(), updated_at=now() where id=e.id;
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      perform report_create(e.id);
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
