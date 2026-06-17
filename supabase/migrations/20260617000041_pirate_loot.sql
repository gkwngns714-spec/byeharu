-- Byeharu — Phase 5: Multi-Item Pirate Loot.
--
-- Pirate combat now accrues ITEM drops alongside metal. This is a controlled combat
-- reward DATA change, not an engine rewrite: the bundle, carry-home, secured-deposit,
-- idempotency, and forfeit-on-defeat are all unchanged (Phase 4). We only:
--   1) add two isolated, server-only helpers (the loot table + an items merger), and
--   2) inject their output into the existing wave-clear reward step of
--      process_combat_ticks, merging items[] into total_rewards_json next to metal.
--
-- Reward timing law UNCHANGED: drops are pending while travelling, secured ONCE on
-- home arrival (metal → base_resources, items → player_inventory via reward_grant),
-- forfeited on defeat (total_rewards_json='{}'), never secured on retreat alone.
--
-- DESIGN: loot is computed SERVER-SIDE ONLY. Deterministic (no RNG) so tests are
-- stable. Quantities are small, clamped, positive integers; only Phase-3-seeded item
-- ids are ever produced (no unknown ids, no NaN). Conservative v1 — not final balance.

-- ── pirate_loot_for_wave: the loot table (deterministic, clamped) ───────────────
-- Returns a jsonb items[] for clearing a given wave. p_danger is accepted for future
-- scaling but v1 keeps quantities flat (=1) so survival can't make loot explode.
--   wave >= 1  → scrap         (guaranteed, small)
--   wave >= 3  → + pirate_alloy
--   wave >= 5  → + weapon_parts
--   wave >= 8  → + engine_parts
--   wave >= 10 → + repair_parts
create or replace function public.pirate_loot_for_wave(p_wave integer, p_danger numeric default 0)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_items jsonb := '[]'::jsonb;
begin
  if p_wave is null or p_wave < 1 then
    return '[]'::jsonb;
  end if;
  -- guaranteed small scrap each cleared wave
  v_items := v_items || jsonb_build_object('item_id', 'scrap', 'quantity', 1);
  if p_wave >= 3  then v_items := v_items || jsonb_build_object('item_id', 'pirate_alloy', 'quantity', 1); end if;
  if p_wave >= 5  then v_items := v_items || jsonb_build_object('item_id', 'weapon_parts', 'quantity', 1); end if;
  if p_wave >= 8  then v_items := v_items || jsonb_build_object('item_id', 'engine_parts', 'quantity', 1); end if;
  if p_wave >= 10 then v_items := v_items || jsonb_build_object('item_id', 'repair_parts', 'quantity', 1); end if;
  return v_items;
end;
$$;

-- ── loot_merge_items: combine two items[] by item_id (summed quantities) ─────────
-- Keeps the accumulated bundle tidy across waves. (reward_grant also de-dups on
-- deposit, so this is belt-and-suspenders — the deposit is correct either way.)
create or replace function public.loot_merge_items(p_a jsonb, p_b jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('item_id', item_id, 'quantity', qty) order by item_id),
    '[]'::jsonb)
  from (
    select el->>'item_id' as item_id, sum((el->>'quantity')::integer) as qty
    from jsonb_array_elements(coalesce(p_a, '[]'::jsonb) || coalesce(p_b, '[]'::jsonb)) el
    where coalesce(el->>'item_id', '') <> ''
    group by el->>'item_id'
  ) s;
$$;

-- ── process_combat_ticks: inject loot into the wave-clear reward step ───────────
-- Copied verbatim from 0030 with THREE additions, all marked "PHASE 5":
--   · declare v_loot_items
--   · compute drops on wave clear and put them in v_reward_delta
--   · merge items[] into total_rewards_json alongside the accumulated metal
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
  v_loot_items    jsonb;   -- PHASE 5: this wave's item drops
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

    v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;  -- PHASE 5
    if v_cleared and v_offense then
      v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                              * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
      v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);                   -- PHASE 5: server-side loot
      v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
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
      -- PHASE 5: accumulate metal AND merge item drops into the pending bundle.
      total_rewards_json       = case when v_cleared and v_offense
                                   then total_rewards_json
                                        || jsonb_build_object('metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                        || jsonb_build_object('items', loot_merge_items(total_rewards_json->'items', v_loot_items))
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

-- ── Re-lock (anti-cheat). New functions default-grant to PUBLIC on create; revoke
--    and re-grant only the client RPCs. service_role grants (reward_grant, inventory_*,
--    process_build_queue) are untouched by a public/anon/authenticated revoke. The new
--    loot helpers are server-only; also exposed to service_role for CI verification.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
grant execute on function public.train_units(uuid, text, integer)          to authenticated;
grant execute on function public.cancel_build_order(uuid)                  to authenticated;
-- CI / server only (service_role); NEVER clients:
grant execute on function public.pirate_loot_for_wave(integer, numeric)    to service_role;
grant execute on function public.loot_merge_items(jsonb, jsonb)            to service_role;
