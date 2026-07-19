-- Byeharu - COMBAT: STICKY SPATIAL ENCOUNTER MODE. Migration 0242. Fixes mid-fight de-spatialization.
--
-- -- THE DEFECT (pre-0242, live head 0234 process_combat_ticks) -----------------------------------------
-- process_combat_ticks re-read the global flag EVERY 3s tick:
--     v_spatial_combat_enabled := cfg_bool('spatial_combat_enabled');   -- once per invocation
--     v_is_spatial := v_spatial_combat_enabled
--                     and exists(select 1 from combat_units where encounter_id=e.id and pos_x is not null);
-- So DARKENING spatial_combat_enabled during an in-flight SPATIAL battle flipped that encounter onto the
-- AGGREGATE arm mid-fight. The aggregate stat SELECT sums EVERY combat_units row of the encounter with NO
-- side filter, so the still-present side='enemy' rows (pirate units) were folded into the PLAYER attack/
-- defense/hp aggregate - data corruption - and no new spatial wave could ever spawn. The 0234 source
-- COMMENT already intended stickiness ("an in-flight battle is never spatialized mid-fight"), but the
-- code broke stickiness in the DARKEN direction because it AND-ed the live per-tick flag read.
--
-- -- THE FIX (this migration - the minimal, sole change) -----------------------------------------------
-- The encounter's mode is decided ONCE, at CREATION, and PERSISTED as the presence of positioned
-- combat_units rows. combat_create_group_encounter (0234, UNCHANGED here) reads spatial_combat_enabled
-- ONCE at creation and writes pos_x on the player rows IFF it was lit; a dark-created encounter never
-- gets a positioned row. Audit (see PR) proved nothing in the whole lifecycle NULLs or deletes a
-- positioned player row while the encounter is active/retreating (the only pos_x writer is creation +
-- the spatial tick's own move; the only combat_units delete is side='enemy' wave respawn; retention
-- cascades only on TERMINAL encounters). So positioned player rows are a RELIABLE, IMMUTABLE mode
-- discriminator, and the tick can derive the mode SOLELY from them:
--     v_is_spatial := exists(select 1 from combat_units where encounter_id=e.id and pos_x is not null);
-- The tick NO LONGER reads spatial_combat_enabled at all (the now-dead read + declaration are removed).
-- INTENDED semantics, now enforced: created-dark => non-spatial forever; created-lit => spatial until
-- terminal; darkening blocks only NEW spatial encounters; enabling never retro-spatializes an existing
-- aggregate encounter. Emergency darkening is now safe: it stops new spatial battles without corrupting
-- or stalling any active one.
--
-- -- BYTE-PARITY --------------------------------------------------------------------------------------
-- This re-creates process_combat_ticks ONLY. The body is the 0234 process_combat_ticks VERBATIM except
-- three hunks: (1) the dead `v_spatial_combat_enabled boolean;` declaration removed; (2) the dead
-- `v_spatial_combat_enabled := cfg_bool('spatial_combat_enabled');` read removed; (3) the v_is_spatial
-- assignment simplified to drop the per-tick flag conjunct. The 0228 aggregate SELECT, the shared (A)
-- defeat / (B) escape blocks, and the ENTIRE 0234 spatial (C) branch are byte-identical (extract-and-
-- diff evidence in the PR: comment-stripped executable diff of 0234 vs 0242 shows only those 3 hunks).
-- combat_create_group_encounter, report_create, combat_unit_decide_move, the flag, the columns, and all
-- balance/tuning config are UNTOUCHED. No feature-flag change, no schema change, no balance change.
--
-- -- GROUNDING (grep-verified) ------------------------------------------------------------------------
-- process_combat_ticks TRUE head is 20260618000234 (0235-0241 re-create OTHER functions; 0236 only
-- references the flag). combat_create_group_encounter TRUE head is also 0234 and is NOT re-created here.
-- Next free migration id after 0241 is 0242 (no collision).

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
  v_loot_items    jsonb;
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
  v_log_ticks     boolean;
  v_log_events    boolean;
  v_log_debug     boolean;
  v_shield_regen  double precision;
  v_shield        double precision;
  v_absorb        double precision;
  v_per_ship_targeting boolean;
  v_target_unit        uuid;
  -- ██ COMBAT-S3 (0234) — the spatial working set ██
  v_is_spatial             boolean;  -- read ONCE per encounter per tick (the null-pos fallback decision)
  v_wave_paused            boolean;
  v_units                  jsonb;    -- frozen pre-move snapshot: id/side/pos/my_range/move_speed/aggro/main_ship_id
  v_ur                     record;   -- the acting unit, looped from v_units
  v_target_id              uuid;
  v_target_x               double precision;
  v_target_y               double precision;
  v_target_range           double precision;
  v_target_dist            double precision;
  v_move_action            text;
  v_new_x                  double precision;
  v_new_y                  double precision;
  v_weapons_json           jsonb;
  v_weapons_out            jsonb;
  v_widx                   integer;
  v_weapon                 jsonb;
  v_w_range                double precision;
  v_w_pspeed               double precision;
  v_w_power                double precision;
  v_w_ammo_type            text;
  v_w_ammo_per_shot        integer;
  v_w_next_ready           timestamptz;
  v_new_ammo               integer;
  v_t_hp                   double precision;
  v_t_shield               double precision;
  v_t_shieldmax            double precision;
  v_t_alive                integer;
  v_t_shiphp               double precision;
  v_t_side                 text;
  v_t_defense              double precision;
  v_t_mainship             uuid;
  v_dmg                    double precision;
  v_shield_new             double precision;
  v_enemy_count            integer;
  v_enemy_range            double precision;
  v_enemy_speed            double precision;
  v_enemy_proj_speed       double precision;
  v_enemy_cooldown         double precision;
  v_enemy_unit_hp          double precision;
  v_enemy_unit_power       double precision;
  v_spawn_i                integer;
  v_dmg_player_total       double precision;
  v_dmg_enemy_total        double precision;
begin
  v_tick_secs     := coalesce(cfg_num('combat_tick_seconds'), 3);
  v_retreat_delay := coalesce(cfg_num('retreat_delay_seconds'), 8);
  v_trans_secs    := coalesce(cfg_num('wave_transition_seconds'), 3);
  v_var_pct       := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
  v_def_base      := coalesce(cfg_num('defense_curve_base'), 100);
  v_log_ticks     := cfg_bool('combat_tick_logging');
  v_log_events    := cfg_bool('combat_event_logging');
  v_log_debug     := cfg_bool('combat_debug_logging');
  v_shield_regen  := coalesce(cfg_num('shield_regen_combat_pct'), 0);
  v_per_ship_targeting := cfg_bool('per_ship_targeting_enabled');

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
    begin
    v_tick := e.tick_number + 1;
    select * into pr from location_presence where id = e.presence_id;
    select base_difficulty, reward_tier, max_presence_seconds into loc from locations where id = e.location_id;

    -- COMBAT-0242: STICKY MODE. The encounter's mode is decided at CREATION and persisted as the
    -- presence of positioned combat_units rows: combat_create_group_encounter writes pos_x on the
    -- player rows IFF spatial_combat_enabled was lit at creation, and NOTHING in the lifecycle ever
    -- NULLs or deletes a positioned player row while the encounter is active/retreating. So the mode
    -- is derived SOLELY from the persisted rows here — the tick NEVER re-reads the global flag.
    -- Darkening the flag mid-fight therefore CANNOT flip an already-spatial encounter onto the
    -- aggregate arm (the pre-0242 defect: it re-read the flag every tick and, on darken, folded
    -- side='enemy' rows into the player aggregate). Created-dark => non-spatial forever; created-lit
    -- => spatial until terminal; darkening blocks only NEW spatial encounters; enabling never
    -- retro-spatializes an existing aggregate encounter.
    v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null);

    -- COMBAT-S3 (0234): THE ONE MARKED AGGREGATE-SELECT HUNK. Dark/no-positions arm is the 0228 head
    -- SELECT, byte-identical (extract-and-diff: the else-arm below is untouched).
    if v_is_spatial then
      select coalesce(sum(hp_current), 0), coalesce(sum(alive_count), 0)
        into v_hp_total, v_alive_total
        from combat_units where encounter_id = e.id and side = 'player';
      v_attack := 0; v_defense := 0;
    else
      -- SLICE D1: member rows have no unit_types match → LEFT JOIN + snapshot-first stat reads. Every
      -- legacy row matches (FK) and has NULL snapshots, so coalesce resolves to the same catalog stats.
      select coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0),
             coalesce(sum(coalesce(cu2.defense_snapshot, ut.defense) * cu2.alive_count), 0),
             coalesce(sum(cu2.hp_current), 0),
             coalesce(sum(cu2.alive_count), 0)
        into v_attack, v_defense, v_hp_total, v_alive_total
        from combat_units cu2 left join unit_types ut on ut.id = cu2.unit_type_id
        where cu2.encounter_id = e.id;
    end if;

    -- (A) Already destroyed → defeat, NO rewards. [SHARED — 0228 head, unmodified: its only combat_units
    --     read filters `main_ship_id is not null`, which already excludes every enemy row.]
    if v_hp_total <= 0 or v_alive_total <= 0 then
      perform fleet_destroy(e.fleet_id);
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
        perform mainship_mark_combat_destroyed(cu.main_ship_id);
      end loop;
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), player_integrity_current=0, player_power_current=0,
             total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
          values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, 0, 0,
                  e.enemy_integrity_current, e.enemy_integrity_current, 'defeat');
      end if;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, 0, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      end if;
      perform report_create(e.id);
      v_count := v_count + 1; continue;
    end if;

    -- (B) End: retreat delay elapsed or forced auto-extract. [SHARED — 0228 head, unmodified: its
    --     member-repatriation read also filters `main_ship_id is not null`.]
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
      v_speed := coalesce(fleet_speed(e.fleet_id), combat_fleet_return_speed(e.fleet_id));
      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform presence_complete(e.presence_id);
      v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
                              'base', v_base_id, null, null, v_base_x, v_base_y, 'return_home', v_speed);
      perform fleet_set_returning(e.fleet_id, v_mv);
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null and alive_count > 0 loop
        perform mainship_mark_legacy_in_flight(cu.main_ship_id, 'returning');
      end loop;
      if e.total_rewards_json is not null and e.total_rewards_json <> '{}'::jsonb then
        perform movement_attach_cargo(v_mv, e.id, e.total_rewards_json);
      end if;
      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, reward_delta_json, result)
          values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, v_hp_total, v_hp_total,
                  e.enemy_integrity_current, e.enemy_integrity_current, e.total_rewards_json, v_end);
      end if;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, 0, 'retreat_completed', 'player', 'player', jsonb_build_object('forced', v_forced));
      end if;
      v_count := v_count + 1; continue;
    end if;

    -- (C) Combat step.
    if v_is_spatial then
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      -- COMBAT-S3 (0234) SPATIAL COMBAT STEP — replaces the aggregate-damage step for any encounter
      -- whose combat_units carry positions. See the migration header for the full design walkthrough.
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      v_danger   := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
      v_variance := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_offense  := (e.status = 'active');
      v_wave_num := e.wave_number;
      v_seq      := 0;
      v_wave_paused := false;

      select coalesce(sum(hp_current), 0) into v_e_before from combat_units where encounter_id = e.id and side = 'enemy';

      -- Wave lifecycle: spawn a fresh synthetic pirate wave when the enemy side is wiped — the exact
      -- mirror of the aggregate arm's `enemy_integrity_current <= 0` branch, now materialized as
      -- combat_units rows split across N units instead of a lone scalar.
      if v_e_before <= 0 then
        if e.next_wave_at is not null and now() < e.next_wave_at then
          v_wave_paused := true;
          if v_log_ticks then
            insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                   player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
              values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
          end if;
          update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
          v_count := v_count + 1;
        else
          v_wave_num     := e.waves_cleared + 1;
          -- SAME wave-hp/wave-attack formulas the aggregate arm has always used — UNCHANGED config
          -- keys — so a spatial wave's total hp/dps matches what the aggregate arm would have rolled.
          v_enemy_hp     := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                            * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
          v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                            * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
          v_enemy_count  := least(coalesce(cfg_num('enemy_synthetic_max_units'),6)::integer, greatest(1, v_danger));
          select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
          v_enemy_range      := coalesce(cfg_num('enemy_synthetic_range_base'),120)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5);
          v_enemy_speed      := coalesce(cfg_num('enemy_synthetic_speed_base'),3)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2);
          v_enemy_proj_speed := coalesce(cfg_num('enemy_synthetic_projectile_speed'),250);
          v_enemy_cooldown   := coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2);
          v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;
          v_enemy_unit_power := v_enemy_attack / v_enemy_count;

          -- Pirates spawn from the ZONE/LOCATION CENTER — every synthetic unit lands at the same point.
          delete from combat_units where encounter_id = e.id and side = 'enemy';
          for v_spawn_i in 1 .. v_enemy_count loop
            insert into combat_units (
              encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
              hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
            values (
              e.id, e.player_id, 'pirate_synthetic', 'enemy', v_enemy_unit_hp, 1, 1,
              v_enemy_unit_hp, v_enemy_unit_hp, v_loc_x, v_loc_y, v_enemy_speed,
              jsonb_build_array(jsonb_build_object(
                'module_type_id', 'pirate_synthetic_weapon', 'range', v_enemy_range,
                'projectile_speed', v_enemy_proj_speed, 'power', v_enemy_unit_power,
                'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', v_enemy_cooldown,
                'next_ready_at', null, 'ammo_remaining', null)));
          end loop;
          v_e_before := v_enemy_hp;  -- the fresh wave's starting total (mirrors the aggregate arm's v_e_before)
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                      jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp), 'units', v_enemy_count));
          end if;
          v_seq := v_seq + 1;
        end if;
      else
        v_enemy_hp := e.enemy_integrity_max;  -- ongoing wave: the ceiling carries over, unchanged
      end if;

      if not v_wave_paused then
        -- Shield regen — once per unit per tick, BEFORE any fire this tick (the SHIELD-1 pattern,
        -- reused: a NULL shield_max row is untouched, exactly the shieldless-unit no-op).
        for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 and shield_max is not null loop
          update combat_units set shield_current = least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen)
            where id = cu.id;
        end loop;

        -- Freeze this tick's population BEFORE any movement is applied — every targeting decision
        -- below reads THIS snapshot, never the live table, so a unit processed earlier in the loop
        -- can never contaminate a later unit's pre-move distance.
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', cu2.id, 'side', cu2.side, 'pos_x', cu2.pos_x, 'pos_y', cu2.pos_y,
                 'my_range', (select max((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'move_speed', coalesce(cu2.move_speed, 0),
                 'aggro_priority', cu2.aggro_priority,
                 'main_ship_id', cu2.main_ship_id)), '[]'::jsonb)
          into v_units
          from combat_units cu2
          where cu2.encounter_id = e.id and cu2.alive_count > 0;

        v_dmg_player_total := 0; v_dmg_enemy_total := 0;

        for v_ur in
          select * from jsonb_to_recordset(v_units) as x(
            id uuid, side text, pos_x double precision, pos_y double precision,
            my_range double precision, move_speed double precision, aggro_priority integer, main_ship_id uuid)
        loop
          -- Retreating player ships hold position and cease fire (the v_offense gate, mirrored — the
          -- enemy side is NEVER gated by this, exactly matching the aggregate arm's asymmetry).
          if v_ur.side = 'player' and not v_offense then
            continue;
          end if;

          -- TARGETING: nearest alive opposite-side unit, aggro-tier-filtered (S1's screening, reused
          -- verbatim in spirit — while any escort, aggro 0, is alive, only escorts are targetable; the
          -- player side has no aggro filter since every enemy row's aggro_priority is NULL).
          v_target_id := null; v_target_x := null; v_target_y := null; v_target_range := null; v_target_dist := null;
          with candidates as (
            select x.id, x.pos_x, x.pos_y, x.my_range, x.aggro_priority,
                   public.osn_distance(v_ur.pos_x, v_ur.pos_y, x.pos_x, x.pos_y) as dist
            from jsonb_to_recordset(v_units) as x(
              id uuid, side text, pos_x double precision, pos_y double precision,
              my_range double precision, move_speed double precision, aggro_priority integer, main_ship_id uuid)
            where x.side is distinct from v_ur.side
          ),
          tier as (select min(aggro_priority) as m from candidates)
          select c.id, c.pos_x, c.pos_y, c.my_range, c.dist
            into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
          from candidates c, tier
          where tier.m is null or c.aggro_priority = tier.m
          order by c.dist asc, c.id asc
          limit 1;

          if v_target_id is null then
            continue;
          end if;

          -- MOVEMENT — combat_unit_decide_move, the pure leaf.
          select action, new_x, new_y into v_move_action, v_new_x, v_new_y
            from public.combat_unit_decide_move(
              v_ur.pos_x, v_ur.pos_y, coalesce(v_ur.my_range,0), coalesce(v_ur.move_speed,0),
              v_target_x, v_target_y, coalesce(v_target_range,0));
          update combat_units set pos_x = v_new_x, pos_y = v_new_y, updated_at = now() where id = v_ur.id;

          -- FIRE — this unit's own weapons_json. Safe to read live: only the unit itself ever writes
          -- its own weapons_json (no other unit's processing this tick can have touched it).
          select weapons_json into v_weapons_json from combat_units where id = v_ur.id;
          v_weapons_out := v_weapons_json;
          for v_widx in 0 .. jsonb_array_length(v_weapons_json) - 1 loop
            v_weapon      := v_weapons_json -> v_widx;
            v_w_range     := (v_weapon->>'range')::double precision;
            v_w_pspeed    := coalesce((v_weapon->>'projectile_speed')::double precision, 300);
            v_w_power     := coalesce((v_weapon->>'power')::double precision, 0);
            v_w_ammo_type := v_weapon->>'ammo_type';
            v_w_ammo_per_shot := coalesce((v_weapon->>'ammo_per_shot')::integer, 0);
            v_w_next_ready := nullif(v_weapon->>'next_ready_at','')::timestamptz;

            if v_w_range is not null and v_target_dist <= v_w_range
               and (v_w_next_ready is null or now() >= v_w_next_ready) then
              if v_log_events then
                insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target,
                      projectile_type, projectile_count, impact_delay_ms, payload_json)
                  values (e.id, e.player_id, v_tick, v_seq,
                          'missile_salvo',
                          case when v_ur.side = 'enemy' then 'pirate' else 'player' end,
                          case when v_ur.side = 'enemy' then 'player' else 'pirate' end,
                          coalesce(v_weapon->>'module_type_id', 'weapon'), 1,
                          round(1000 * v_target_dist / nullif(v_w_pspeed,0))::integer,
                          jsonb_build_object('unit_id', v_ur.id, 'target_id', v_target_id));
              end if;
              v_seq := v_seq + 1;

              -- DAMAGE — re-read the target fresh (it may already have taken an earlier shot THIS
              -- tick from a different firer); a target that died to an earlier shot simply takes no
              -- further damage from this one (`if found` guards it) — no error, no double-kill.
              select hp_current, shield_current, shield_max, alive_count, ship_hp, side, defense_snapshot, main_ship_id
                into v_t_hp, v_t_shield, v_t_shieldmax, v_t_alive, v_t_shiphp, v_t_side, v_t_defense, v_t_mainship
                from combat_units where id = v_target_id and alive_count > 0;
              if found then
                -- The aggregate arm's own asymmetry, reused: player fire on enemies is NEVER
                -- defense-mitigated (enemies carry no defense_snapshot); enemy fire on players IS,
                -- via the same def_base curve.
                if v_t_side = 'enemy' then
                  v_dmg := v_w_power * v_variance;
                else
                  v_dmg := v_w_power * v_def_base / (v_def_base + coalesce(v_t_defense,0)) * v_variance;
                end if;
                -- SHIELD-1 (0195) absorb pattern, reused verbatim: shield soaks min(pool,damage); only
                -- the overflow reaches hp.
                v_absorb     := least(coalesce(v_t_shield,0), v_dmg);
                v_shield_new := case when v_t_shieldmax is not null then v_t_shield - v_absorb else null end;
                v_new_hp     := v_t_hp - (v_dmg - v_absorb);
                v_new_alive  := greatest(0, least(v_t_alive, ceil(v_new_hp / v_t_shiphp)::integer));
                v_destroyed  := v_t_alive - v_new_alive;
                update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive,
                       shield_current = v_shield_new, updated_at = now()
                  where id = v_target_id;
                if v_t_side = 'player' then
                  perform mainship_sync_combat_hp(v_t_mainship, round(greatest(0, v_new_hp))::integer);
                  if v_shield_new is not null then
                    perform mainship_sync_combat_shield(v_t_mainship, round(v_shield_new)::integer);
                  end if;
                  v_dmg_enemy_total := v_dmg_enemy_total + v_dmg;
                else
                  v_dmg_player_total := v_dmg_player_total + v_dmg;
                end if;
                if v_log_debug then
                  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
                    values (e.id, e.player_id, v_tick, v_seq, 'hull_damage',
                            case when v_ur.side='enemy' then 'pirate' else 'player' end,
                            case when v_ur.side='enemy' then 'player' else 'pirate' end,
                            jsonb_build_object('unit_id', v_target_id, 'damage', round(v_dmg)));
                  v_seq := v_seq + 1;
                end if;
                if v_destroyed > 0 and v_log_events then
                  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
                    values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed',
                            case when v_ur.side='enemy' then 'pirate' else 'player' end,
                            case when v_ur.side='enemy' then 'player' else 'pirate' end,
                            jsonb_build_object('unit_id', v_target_id, 'count', v_destroyed));
                  v_seq := v_seq + 1;
                end if;
              end if;

              -- Ammo decrement (per the charter) — documented-inert scaffolding: no module seeds
              -- ammo_type yet (S0's own deferral), so this never actually consumes anything today,
              -- and fire eligibility above is NOT gated on ammo_remaining (no inventory source is
              -- wired to initialize it — a future slice's decision).
              v_new_ammo := case when v_w_ammo_type is not null
                                 then greatest(0, coalesce((v_weapon->>'ammo_remaining')::integer, 0) - v_w_ammo_per_shot)
                                 else null end;
              v_weapons_out := jsonb_set(v_weapons_out, array[v_widx::text],
                                  v_weapon || jsonb_build_object('next_ready_at', now(), 'ammo_remaining', v_new_ammo));
            end if;
          end loop;
          update combat_units set weapons_json = v_weapons_out where id = v_ur.id;
        end loop;

        -- Wave-clear + per-tick bookkeeping — the aggregate arm's shape, computed over per-unit sums.
        select coalesce(sum(hp_current), 0) into v_e_after from combat_units where encounter_id = e.id and side = 'enemy';
        v_cleared := v_offense and v_e_after <= 0;
        select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id and side = 'player';

        v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
        if v_cleared then
          v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                  * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
          v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);
          v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                      jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
            v_seq := v_seq + 1;
          end if;
        end if;

        if v_log_ticks then
          insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                 player_power_before, enemy_power, player_damage, enemy_damage,
                 player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after,
                 player_losses_json, reward_delta_json, unit_snapshot_json, result)
            values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
                    v_hp_total, v_e_before, v_dmg_player_total, v_dmg_enemy_total,
                    v_hp_total, greatest(0, v_hp_after), v_e_before, greatest(0, v_e_after),
                    '{}'::jsonb, v_reward_delta, '{}'::jsonb,
                    case when v_cleared then 'wave_cleared' else 'ongoing' end);
        end if;

        update combat_encounters set
          tick_number              = v_tick,
          danger_level             = v_danger,
          wave_number              = v_wave_num,
          waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),
          player_integrity_current = greatest(0, v_hp_after),
          enemy_integrity_max      = v_enemy_hp,
          enemy_integrity_current  = greatest(0, v_e_after),
          enemy_power_current      = greatest(0, v_e_after),
          next_wave_at             = case when v_cleared then now() + make_interval(secs => v_trans_secs) else e.next_wave_at end,
          player_power_current     = fleet_get_power(e.fleet_id),
          total_rewards_json       = case when v_cleared
                                       then total_rewards_json
                                            || jsonb_build_object('metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                            || jsonb_build_object('items', loot_merge_items(total_rewards_json->'items', v_loot_items))
                                       else total_rewards_json end,
          last_resolved_at         = now(),
          updated_at               = now()
        where id = e.id;

        if v_hp_after <= 0 then
          perform fleet_destroy(e.fleet_id);
          for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
            perform mainship_mark_combat_destroyed(cu.main_ship_id);
          end loop;
          perform presence_complete(e.presence_id);
          update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
          end if;
          perform report_create(e.id);
        end if;

        v_count := v_count + 1;
      end if; -- not v_wave_paused
    else
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      -- 0228 HEAD — (C) Combat step, VERBATIM (the dark / no-positions byte-parity arm).
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      v_danger       := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
      v_variance     := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                        * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
      v_seq          := 0;
      v_offense      := (e.status = 'active');
      v_wave_num     := e.wave_number;

      if e.enemy_integrity_current <= 0 then
        if e.next_wave_at is not null and now() < e.next_wave_at then
          if v_log_ticks then
            insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                   player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
              values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
          end if;
          update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
          v_count := v_count + 1; continue;
        end if;
        v_wave_num := e.waves_cleared + 1;
        v_enemy_hp := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                      * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
        v_e_before := v_enemy_hp;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                    jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp)));
        end if;
        v_seq := v_seq + 1;
      else
        v_enemy_hp := e.enemy_integrity_max;
        v_e_before := e.enemy_integrity_current;
      end if;

      if v_offense then
        v_player_damage := v_attack * v_variance;
        v_e_after := v_e_before - v_player_damage;
        v_cleared := v_e_after <= 0;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'missile_salvo', 'player', 'pirate', 'missile', greatest(1, round(v_attack/50)::integer), 400,
                    jsonb_build_object('damage', round(v_player_damage), 'wave', v_wave_num));
        end if;
        v_seq := v_seq + 1;
      else
        v_player_damage := 0; v_e_after := v_e_before; v_cleared := false;
      end if;

      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms)
          values (e.id, e.player_id, v_tick, v_seq, 'laser_burst', 'pirate', 'player', 'laser', greatest(1, v_danger), 600);
      end if;
      v_seq := v_seq + 1;
      v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;

      v_target_unit := null;
      if v_per_ship_targeting then
        select id into v_target_unit
          from combat_units
         where encounter_id = e.id and alive_count > 0 and aggro_priority is not null
         order by aggro_priority asc, id asc
         limit 1;
      end if;

      v_losses := '{}'::jsonb; v_counts := '{}'::jsonb; v_snapshot := '{}'::jsonb;
      for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 loop
        v_shield    := least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen);
        if v_target_unit is not null then
          v_d_group := case when cu.id = v_target_unit then v_final_player else 0 end;
        else
          v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
        end if;
        v_absorb    := least(coalesce(v_shield, 0), v_d_group);
        v_shield    := v_shield - v_absorb;
        v_new_hp    := cu.hp_current - (v_d_group - v_absorb);
        v_new_alive := greatest(0, least(cu.alive_count, ceil(v_new_hp / cu.ship_hp)::integer));
        v_destroyed := cu.alive_count - v_new_alive;
        update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive,
               shield_current = v_shield,
               updated_at = now()
          where id = cu.id;
        if cu.unit_type_id is not null then
          v_counts := v_counts || jsonb_build_object(cu.unit_type_id, v_new_alive);
        else
          perform mainship_sync_combat_hp(cu.main_ship_id, round(greatest(0, v_new_hp))::integer);
          if v_shield is not null then
            perform mainship_sync_combat_shield(cu.main_ship_id, round(v_shield)::integer);
          end if;
        end if;
        v_snapshot := v_snapshot || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text),
                         jsonb_build_object('alive', v_new_alive, 'hp', round(greatest(0, v_new_hp))));
        if v_log_debug then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'hull_damage', 'pirate', 'player',
                    jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'damage', round(v_d_group)));
        end if;
        v_seq := v_seq + 1;
        if v_destroyed > 0 then
          v_losses := v_losses || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text), v_destroyed);
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed', 'pirate', 'player',
                      jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'count', v_destroyed));
          end if;
          v_seq := v_seq + 1;
        end if;
      end loop;

      perform fleet_sync_quantities(e.fleet_id, v_counts);
      select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id;

      v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
      if v_cleared and v_offense then
        v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
        v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);
        v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                    jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
        end if;
        v_seq := v_seq + 1;
      end if;

      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_power_before, enemy_power, player_damage, enemy_damage,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after,
               player_losses_json, reward_delta_json, unit_snapshot_json, result)
          values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
                  v_hp_total, v_e_before, v_player_damage, v_final_player,
                  v_hp_total, greatest(0, v_hp_after), v_e_before, greatest(0, v_e_after),
                  v_losses, v_reward_delta, v_snapshot,
                  case when v_cleared then 'wave_cleared' else 'ongoing' end);
      end if;

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
                                     then total_rewards_json
                                          || jsonb_build_object('metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                          || jsonb_build_object('items', loot_merge_items(total_rewards_json->'items', v_loot_items))
                                     else total_rewards_json end,
        last_resolved_at         = now(),
        updated_at               = now()
      where id = e.id;

      if v_hp_after <= 0 then
        perform fleet_destroy(e.fleet_id);
        for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
          perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end loop;
        perform presence_complete(e.presence_id);
        update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
        end if;
        perform report_create(e.id);
      end if;

      v_count := v_count + 1;
    end if;
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_combat_ticks: tick failed for encounter % (left in-place; retries next tick): %',
          e.id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;


-- -- SELF-ASSERTS - deploy-time; the migration proves its own grounding or refuses to land -------------
do $$
declare
  v_tick    text;
  v_creator text;
  v_tok     text;
  v_n       integer;
begin
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_creator from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if v_tick is null or v_creator is null then
    raise exception 'COMBAT-0242 self-assert FAIL: process_combat_ticks or combat_create_group_encounter is missing';
  end if;

  -- PROSRC-ASSERT COUPLING (the house lesson): strip line comments before probing.
  v_tick    := regexp_replace(v_tick,    '--[^' || chr(10) || ']*', '', 'g');
  v_creator := regexp_replace(v_creator, '--[^' || chr(10) || ']*', '', 'g');

  -- (1) THE FIX: the tick derives mode SOLELY from persisted positioned rows.
  if strpos(v_tick, 'v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)') = 0 then
    raise exception 'COMBAT-0242 self-assert FAIL: the sticky (position-only) v_is_spatial form is absent';
  end if;
  -- the OLD flag-conjoined form is GONE.
  if strpos(v_tick, 'v_is_spatial := v_spatial_combat_enabled') <> 0 then
    raise exception 'COMBAT-0242 self-assert FAIL: the old flag-conjoined v_is_spatial form is still present';
  end if;
  -- the tick NO LONGER reads the global flag AT ALL (the core of the fix).
  v_n := (length(v_tick) - length(replace(v_tick, 'cfg_bool(''spatial_combat_enabled'')', '')))
         / length('cfg_bool(''spatial_combat_enabled'')');
  if v_n <> 0 then
    raise exception 'COMBAT-0242 self-assert FAIL: process_combat_ticks still reads spatial_combat_enabled % time(s) (want 0)', v_n;
  end if;
  -- the dead local is gone (no orphaned declaration/reference remains).
  if strpos(v_tick, 'v_spatial_combat_enabled') <> 0 then
    raise exception 'COMBAT-0242 self-assert FAIL: the dead v_spatial_combat_enabled local is still referenced in the tick';
  end if;

  -- (2) CREATION GATE INTACT: the mode is still DECIDED at creation from the flag (combat_create_group_
  --     encounter, unchanged, keeps reading the flag once) - so darkening still blocks NEW spatial.
  if strpos(v_creator, 'v_spatial_enabled boolean := public.cfg_bool(''spatial_combat_enabled'');') = 0 then
    raise exception 'COMBAT-0242 self-assert FAIL: combat_create_group_encounter lost its creation-time flag gate';
  end if;

  -- (3) BYTE-PARITY PINS - the 0234/0228 branches survive verbatim (single-line strpos pins). The 0228
  --     aggregate SELECT (the dark/aggregate arm):
  if strpos(v_tick, 'coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0)') = 0 then
    raise exception 'COMBAT-0242 self-assert FAIL: the 0228 aggregate SELECT is gone (byte-parity breach)';
  end if;
  -- the spatial-arm player aggregate keeps its side=player scoping (no enemy fold, ever):
  if strpos(v_tick, 'from combat_units where encounter_id = e.id and side = ''player''') = 0 then
    raise exception 'COMBAT-0242 self-assert FAIL: the spatial-arm side=player aggregate scoping is gone';
  end if;
  -- shared (A) defeat + (B) escape member-scoped loops:
  if strpos(v_tick, 'for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop') = 0 then
    raise exception 'COMBAT-0242 self-assert FAIL: the shared (A) defeat member-mark loop is gone';
  end if;
  if strpos(v_tick, 'for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null and alive_count > 0 loop') = 0 then
    raise exception 'COMBAT-0242 self-assert FAIL: the shared (B) escape repatriation loop is gone';
  end if;
  -- the 0234 spatial branch (targeting / move / synthetic wave spawn) + the 0228 (C) else-arm tokens:
  foreach v_tok in array array[
      'combat_unit_decide_move(',
      'where x.side is distinct from v_ur.side',
      'tier as (select min(aggro_priority) as m from candidates)',
      'delete from combat_units where encounter_id = e.id and side = ''enemy'';',
      'encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,',
      'v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;',
      'v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);'
    ] loop
    if strpos(v_tick, v_tok) = 0 then
      raise exception 'COMBAT-0242 self-assert FAIL: process_combat_ticks lost a byte-parity token (%)', v_tok;
    end if;
  end loop;

  -- (4) DETERMINISM (0041): still exactly two random() calls (one per (C) arm variance roll) - unchanged.
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception 'COMBAT-0242 self-assert FAIL: process_combat_ticks carries % random( call(s) (want exactly 2)', v_n;
  end if;

  -- (5) ACL: the re-created engine function stays non-client-executable (unchanged posture).
  if has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception 'COMBAT-0242 self-assert FAIL: process_combat_ticks is client-executable';
  end if;

  raise notice 'COMBAT-0242 self-assert ok: process_combat_ticks derives spatial mode SOLELY from persisted positioned combat_units rows (v_is_spatial := exists(pos_x is not null)); it reads spatial_combat_enabled ZERO times and the dead local is fully removed; the creation-time flag gate in combat_create_group_encounter is intact (darkening still blocks NEW spatial encounters); the 0228 aggregate SELECT, the spatial-arm side=player scoping, the shared (A)/(B) member loops, the whole 0234 spatial branch and the 0228 (C) else-arm all survive byte-identical; determinism unchanged (exactly 2 random() rolls); ACL non-client-executable';
end $$;
