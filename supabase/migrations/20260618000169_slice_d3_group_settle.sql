-- Byeharu — TEAM-COMMAND Slice D3: team sortie SETTLE semantics — members come home (DARK).
--
-- ── WHAT THIS IS ────────────────────────────────────────────────────────────────────────────────────
-- D2's sortie can fight and its FLEET already returns/dies correctly (D1's member branches), but the
-- member SHIPS never leave 'hunting' after an escape and nothing ever re-homes them. D3 closes the
-- loop with three re-creates, each from its TRUE head (grep-verified over ALL migrations):
--   (1) process_combat_ticks  ← 0167 (the D1 re-create IS the head; nothing later touches it):
--       ONE new hunk — at combat end (escape/forced-extract, the single branch that creates the
--       'return_home' movement) surviving member ships (alive_count > 0) are marked 'returning' via
--       the ONE 0152 legacy in-flight leaf. The DEFEAT branches already settle members via D1's
--       mainship_mark_combat_destroyed — verified, untouched.
--   (2) process_mainship_expeditions ← 0050:234 (its ONLY create site; 0051+ carry grants only):
--       the reconciler learns to bring sortie members home once their MANIFEST fleet is finished,
--       and gains the member-only guard that keeps its legacy branch off a member who is still
--       flying home with the team.
--   (3) send_main_ship_expedition ← 0152:65 (created 0050, re-created 0051, re-created 0152 —
--       nothing later): the M1 ACTIVATION-BLOCKER fix (docs/TEAM_COMMAND.md) — the live single
--       send's ship write becomes race-proof (row lock + status='home' re-check in the CALLER;
--       the shared 0152 leaf is NOT widened).
--
-- ── THE PARITY LAW (the D1/D2 discipline, absolute) ─────────────────────────────────────────────────
-- Every delta is one of exactly two provably-inert shapes:
--   (a) MEMBER-ROW-ONLY — reachable only via combat_units.main_ship_id IS NOT NULL rows or
--       group_sortie_members rows, which have NO writer while team_command_enabled=false (D2's send
--       is the sole writer of both and rejects at its gate) → every legacy encounter/ship takes the
--       byte-identical head path; or
--   (b) RACE-CLOSURE-ONLY — the M1 fix: a ship that passed the send's existing status='home' check
--       and is NOT concurrently modified locks instantly and performs the exact same write; only a
--       true concurrent interleaving (previously a silent lost update) now takes the function's own
--       pre-existing not-available raise. No legal caller can observe any difference.
-- Each delta carries a `-- SLICE D3:` marker; each re-create is diff-verified against its head
-- (exactly the marked hunks, nothing else).
--
-- ── MEMBER LIFECYCLE AFTER D3 (the full loop) ───────────────────────────────────────────────────────
--   send (D2)          → status='hunting'                 (manifest frozen; fleet moving)
--   combat end, alive  → status='returning'               (this tick hunk; fleet returning)
--   combat end, dead-but-team-escaped (alive_count=0)     → stays 'hunting' hp=0 — deliberately NOT
--                        'returning' (it is not flying anything) and NOT 'destroyed' (only a fleet
--                        wipe destroys); the reconciler re-homes it with hp=0 when the fleet
--                        completes — exactly the "zero-hp 'home' ship" D2's send guard anticipates.
--   fleet completed    → reconciler → status='home'       (spatial_state stays NULL — the clean
--                        legacy_home, the EXACT write shape the head reconciler has always used for
--                        'traveling'/'returning'; deliberately NOT spatial_state='home', which no
--                        reconciler path has ever written)
--   defeat             → status='destroyed' hp=0 (D1, unchanged) → repair_main_ship (0081) revives.
--
-- ── MANIFEST RETENTION DECISION (documented per plan) ───────────────────────────────────────────────
-- group_sortie_members rows for a finished sortie are RETAINED, not deleted by the reconciler:
--   • fleets rows are NOT immortal — the 0047 retention cron deletes terminal (completed/destroyed)
--     fleets after >14d, and the manifest's ON DELETE CASCADE (0168) removes its rows with the fleet,
--     so manifests are garbage-collected by the EXISTING lifecycle with ZERO new writers.
--   • deleting here would make the reconciler a SECOND writer of a table whose sole-writer law
--     (send_ship_group_hunt, 0168) is grep-enforced by the proof selftest.
--   • a completed fleet is never reused (the 0006 state machine has no completed→idle/moving edge;
--     every send inserts a fresh fleets row), so a retained manifest can never re-route an encounter —
--     routing keys on the ARRIVING fleet's fleet_id.
--   • until retention collects it, the manifest is the sortie's audit trail (who flew), matching the
--     combat_reports retention posture.
-- CONSEQUENCE: every D3 predicate over the manifest is LIVE-SCOPED (join fleets on status in
-- ('moving','present','returning')), never a bare EXISTS — a retained dead manifest must never pin or
-- free a ship.
--
-- ── RETREAT (verified, NO change) ───────────────────────────────────────────────────────────────────
-- request_retreat (head 0019:80 — its only create site) is presence-addressed and owner-checked
-- (presence.player_id = auth.uid()), then delegates to presence_request_leave, whose combat branch
-- (0018) arms the encounter's retreat timer keyed on the presence's OWN active encounter. Nothing in
-- that path reads fleet composition, fleet_units, or membership — a team sortie's presence is created
-- by the same presence_create the legacy chain uses, so retreat works for a team encounter VERBATIM.
-- Exercised live in the proof's TEAMSETTLE escape path; no function change.
--
-- ── 0152 LEAF NOTE ──────────────────────────────────────────────────────────────────────────────────
-- mainship_mark_legacy_in_flight gains a FIFTH caller (the tick's escape hunk): 'returning' is inside
-- the leaf's hard status domain (0152:55, traveling|returning) and the team return IS a legacy
-- fleet_movements return trip, so the leaf's semantics ("legacy movement family → ship in the NULL
-- spatial representation") fit exactly — reused, never widened, never copied (D2 could NOT reuse it
-- for 'hunting' because 'hunting' is outside that domain). Its 0152 retirement condition extends to
-- this caller: retire them together with the legacy movement family.
--
-- ── OUT OF SCOPE ────────────────────────────────────────────────────────────────────────────────────
-- NO flag flip, NO frontend (D4), NO backfill, NO edit to any shipped migration, NO cron change
-- (both cron jobs — 'process-combat-ticks' 0026 and 'process-mainship-expeditions' 0050 — keep their
-- schedules; CREATE OR REPLACE swaps the bodies under them).

-- ── 1) process_combat_ticks: 0167:181 body VERBATIM + the ONE marked SLICE D3 hunk ──────────────────
-- Copied from the true head (0167 — the D1 re-create; nothing later re-creates it; verified by grep
-- over ALL migrations). The single delta: in the end branch (B) — the ONE site that creates the
-- 'return_home' movement, covering BOTH v_end shapes ('escaped' and forced 'completed') — surviving
-- members (alive_count > 0) are marked 'returning' through the ONE 0152 legacy in-flight leaf.
-- alive_count is the survival predicate (NOT hp_current): the tick's own kill math floors alive_count
-- to 0 exactly when a member's hull is gone, and a D2-degraded row is BORN alive_count=0 — neither may
-- ever be marked 'returning' (a dead member stays 'hunting' hp=0 until the reconciler re-homes it; see
-- header). Legacy encounters have no member rows → zero iterations (the D1 parity law, shape (a)).
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
  v_log_ticks     boolean;   -- PHASE A: per-tick combat_ticks logging
  v_log_events    boolean;   -- PHASE A: meaningful combat_events logging
  v_log_debug     boolean;   -- PHASE A: verbose per-unit hull_damage events
begin
  v_tick_secs     := coalesce(cfg_num('combat_tick_seconds'), 3);
  v_retreat_delay := coalesce(cfg_num('retreat_delay_seconds'), 8);
  v_trans_secs    := coalesce(cfg_num('wave_transition_seconds'), 3);
  v_var_pct       := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
  v_def_base      := coalesce(cfg_num('defense_curve_base'), 100);
  v_log_ticks     := cfg_bool('combat_tick_logging');
  v_log_events    := cfg_bool('combat_event_logging');
  v_log_debug     := cfg_bool('combat_debug_logging');

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
    v_tick := e.tick_number + 1;
    select * into pr from location_presence where id = e.presence_id;
    select base_difficulty, reward_tier, max_presence_seconds into loc from locations where id = e.location_id;

    -- SLICE D1: member rows have no unit_types match → LEFT JOIN + snapshot-first stat reads. Every
    -- legacy row matches (FK) and has NULL snapshots, so coalesce resolves to the same catalog stats.
    select coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0),
           coalesce(sum(coalesce(cu2.defense_snapshot, ut.defense) * cu2.alive_count), 0),
           coalesce(sum(cu2.hp_current), 0),
           coalesce(sum(cu2.alive_count), 0)
      into v_attack, v_defense, v_hp_total, v_alive_total
      from combat_units cu2 left join unit_types ut on ut.id = cu2.unit_type_id
      where cu2.encounter_id = e.id;

    -- (A) Already destroyed → defeat, NO rewards.
    if v_hp_total <= 0 or v_alive_total <= 0 then
      perform fleet_destroy(e.fleet_id);
      -- SLICE D1: member ships share the destroyed fleet's fate (the 0059 terminal shape, via the
      -- one-leaf writer). No member rows exist until D2 → zero iterations for every legacy encounter.
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

    -- (B) End: retreat delay elapsed or forced auto-extract.
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
      -- SLICE D1: a member fleet has no fleet_units → fleet_speed is NULL; fall back to the member
      -- hull return speed. Legacy fleets always carry units → fleet_speed non-null → coalesce no-op.
      v_speed := coalesce(fleet_speed(e.fleet_id), combat_fleet_return_speed(e.fleet_id));
      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform presence_complete(e.presence_id);
      v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
                              'base', v_base_id, null, null, v_base_x, v_base_y, 'return_home', v_speed);
      perform fleet_set_returning(e.fleet_id, v_mv);
      -- SLICE D3: surviving member ships head home WITH their fleet — 'returning' via the ONE 0152
      -- legacy in-flight leaf ('returning' is inside its hard domain; pair-write status +
      -- spatial_state NULL + coords NULL). alive_count > 0 is the survival predicate: a member the
      -- tick killed (alive_count floored to 0) or a D2-degraded member (born alive_count=0) is NOT
      -- flying anything — it stays 'hunting' hp=0 until the reconciler re-homes it at fleet
      -- completion. Mirrors the defeat branches' member loop after fleet_destroy. No member rows
      -- exist for a legacy encounter → zero iterations (the D1 parity law).
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

    v_losses := '{}'::jsonb; v_counts := '{}'::jsonb; v_snapshot := '{}'::jsonb;
    for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 loop
      v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
      v_new_hp    := cu.hp_current - v_d_group;
      v_new_alive := greatest(0, least(cu.alive_count, ceil(v_new_hp / cu.ship_hp)::integer));
      v_destroyed := cu.alive_count - v_new_alive;
      update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive, updated_at = now()
        where id = cu.id;
      -- SLICE D1: survivor sync splits by identity — ONLY catalog-keyed counts feed
      -- fleet_sync_quantities below; a member row syncs its damage to the ship row (hp ONLY) via the
      -- one-leaf writer. Legacy rows always take the first branch, executing the identical statement.
      if cu.unit_type_id is not null then
        v_counts := v_counts || jsonb_build_object(cu.unit_type_id, v_new_alive);
      else
        perform mainship_sync_combat_hp(cu.main_ship_id, round(greatest(0, v_new_hp))::integer);
      end if;
      -- SLICE D1: jsonb keys/payloads use coalesce(unit_type_id, main_ship_id::text) — jsonb_build_object
      -- raises on a NULL key; legacy rows keep their exact unit_type_id keys byte-identically.
      v_snapshot := v_snapshot || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text),
                       jsonb_build_object('alive', v_new_alive, 'hp', round(greatest(0, v_new_hp))));
      -- Verbose per-unit damage event: debug-only (the worst per-tick volume driver).
      if v_log_debug then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, v_seq, 'hull_damage', 'pirate', 'player',
                  jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'damage', round(v_d_group)));  -- SLICE D1: NULL-safe key
      end if;
      v_seq := v_seq + 1;
      if v_destroyed > 0 then
        v_losses := v_losses || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text), v_destroyed);  -- SLICE D1: NULL-safe key
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed', 'pirate', 'player',
                    jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'count', v_destroyed));  -- SLICE D1: NULL-safe key
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
      -- SLICE D1: member ships share the destroyed fleet's fate (the 0059 terminal shape, via the
      -- one-leaf writer). No member rows exist until D2 → zero iterations for every legacy encounter.
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
  end loop;

  return v_count;
end;
$$;

-- ── 2) process_mainship_expeditions: 0050:234 body VERBATIM + the marked SLICE D3 deltas ────────────
-- Copied from the true head (0050 — its only create site; every later mention is a grant carry;
-- verified by grep over ALL migrations). Two deltas, both member-only (parity shape (a)):
--   • the EXISTING legacy branch gains ONE guard predicate: skip a ship whose MANIFEST fleet is still
--     live. Without it, a member marked 'returning' by the D3 tick hunk — whose team fleet is NOT
--     main_ship_id-tagged, so the head's not-exists is vacuously true — would be yanked 'home' while
--     the sortie is still flying home (and could then join a SECOND sortie, breaking D2's
--     one-live-sortie-per-ship law). No legacy ship has manifest rows → the guard is provably false
--     on every row the head branch has ever touched (behavioral byte-parity).
--   • a NEW team CTE re-homes 'hunting' ships whose manifest fleet is finished. 'hunting' has exactly
--     ONE writer (send_ship_group_hunt, D2), so the CTE can never touch a legacy ship. It covers:
--       - the normal completion (fleet 'completed' back home → dead members, hp=0, come home);
--       - SELF-HEALING (belt-and-braces against partial states): a 'hunting' ship whose manifest
--         fleet was destroyed but which the D1 defeat loop somehow missed, or whose fleet row was
--         deleted entirely (manifest CASCADEd away → the not-exists is vacuously true) — re-home it;
--         the reconciler NEVER destroys a ship (destruction is combat's verdict alone; a wrongly
--         destroyed ship is unrecoverable-but-repairable, a wrongly homed one is self-correcting).
--     Members marked 'returning' by the tick hunk need no new arm: once their manifest fleet
--     finishes, the guard opens and the EXISTING legacy branch re-homes them with its own write
--     (status='home', spatial_state untouched → stays NULL, the clean legacy_home — the exact
--     terminal every legacy expedition ship has always reconciled to).
-- RACE PIN (the exact complement): NEITHER branch may touch a ship whose manifest fleet is
-- 'moving' (outbound), 'present' (MID-COMBAT), or 'returning' (flying home) — both predicates test
-- fleets.status against that exact live set, so the reconciler's reach is precisely "manifest fleet
-- finished or gone", never a live sortie.
create or replace function public.process_mainship_expeditions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_team  integer;   -- SLICE D3: team-sortie reconcile count (0 on every run until the flag ever flips)
begin
  -- A ship that is out (traveling/returning) but has no in-flight tagged fleet has come
  -- home (fleet completed) or lost its fleet → set it home. Idempotent.
  with homed as (
    update main_ship_instances s
      set status = 'home', updated_at = now()
      where s.status in ('traveling','returning')
        and not exists (
          select 1 from fleets f
          where f.main_ship_id = s.main_ship_id
            and f.status in ('moving','present','returning')
        )
        -- SLICE D3: member-only guard — a sortie member marked 'returning' by the tick has NO
        -- main_ship_id-tagged fleet (a team flies ONE untagged fleet), so the head's not-exists is
        -- vacuously true for it; without this guard the branch would yank it 'home' while its
        -- MANIFEST fleet is still flying home. Once that fleet finishes, the guard opens and this
        -- branch re-homes the member with its unchanged legacy write. No legacy ship has manifest
        -- rows → provably false-impact on every row this branch has ever touched (parity law).
        and not exists (
          select 1 from group_sortie_members gsm
          join fleets gf on gf.id = gsm.fleet_id
          where gsm.main_ship_id = s.main_ship_id
            and gf.status in ('moving','present','returning')
        )
      returning 1)
  select count(*) into v_count from homed;

  -- SLICE D3: the team-sortie branch — re-home 'hunting' ships whose MANIFEST fleet is finished
  -- (completed back home / destroyed / deleted). 'hunting' has exactly ONE writer
  -- (send_ship_group_hunt, 0168), so this can never touch a legacy ship. The predicate is the EXACT
  -- COMPLEMENT of "live sortie": a manifest fleet in ('moving','present','returning') — outbound,
  -- MID-COMBAT, or flying home — pins its members untouched. Self-healing by design (belt and
  -- braces against partial states): a 'hunting' ship whose fleet was destroyed but which the D1
  -- defeat loop somehow missed, or whose fleet row was deleted (manifest CASCADEd away → not-exists
  -- vacuously true), comes home rather than staying wedged — the reconciler NEVER destroys a ship
  -- (destruction is combat's verdict alone; a wrongly homed ship is self-correcting, a wrongly
  -- destroyed one is not). Write shape: the head branch's own (status only; spatial_state stays
  -- NULL — the clean legacy_home). Idempotent.
  with team_homed as (
    update main_ship_instances s
      set status = 'home', updated_at = now()
      where s.status = 'hunting'
        and not exists (
          select 1 from group_sortie_members gsm
          join fleets gf on gf.id = gsm.fleet_id
          where gsm.main_ship_id = s.main_ship_id
            and gf.status in ('moving','present','returning')
        )
      returning 1)
  select count(*) into v_team from team_homed;

  return v_count + v_team;
end;
$$;

-- ── 3) send_main_ship_expedition: 0152:65 body VERBATIM + the marked SLICE D3 (M1) hunk ─────────────
-- Copied from the true head (0152 — created 0050, re-created 0051, re-created 0152; nothing later;
-- verified by grep over ALL migrations). The single delta is the M1 ACTIVATION-BLOCKER fix
-- (docs/TEAM_COMMAND.md): the head's ship write is a plain unlocked read (0152:100-107) followed by
-- an unconditional leaf call (0152:150), so a single send that read 'home' concurrently with a
-- committing team hunt-send could overwrite 'hunting' → 'traveling' (a lost update desyncing the ship
-- from its live sortie). The fix is RACE-CLOSURE-ONLY (parity shape (b)) and lives in the CALLER —
-- the shared 0152 leaf is deliberately NOT widened (its one-leaf law): re-claim the ship row UNDER A
-- FOR UPDATE lock re-verifying status='home' immediately before the leaf call, and reject a miss with
-- the function's own pre-existing not-available raise (same message shape as 0152:106). Lock-order
-- safety: this function holds no other existing-row lock (the fleets/movement rows above are freshly
-- inserted this txn), and the team send locks group-then-ships without ever locking a movement row —
-- no cycle with either the team send or the settle cron (movement → fleet/ship).
create or replace function public.send_main_ship_expedition(p_ships jsonb, p_location uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship_id  uuid;
  v_ship     record;
  v_base     record;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_speed    double precision;
  v_fleet    uuid;
  v_movement uuid;
  v_arrive   timestamptz;
begin
  if v_player is null then
    raise exception 'send_main_ship_expedition: not authenticated';
  end if;

  if not cfg_bool('mainship_send_enabled') then
    raise exception 'send_main_ship_expedition: feature disabled';
  end if;

  if p_ships is null or jsonb_typeof(p_ships) <> 'array' or jsonb_array_length(p_ships) <> 1 then
    raise exception 'send_main_ship_expedition: exactly one ship required';
  end if;
  v_ship_id := (p_ships->>0)::uuid;
  if v_ship_id is null then
    raise exception 'send_main_ship_expedition: invalid ship id';
  end if;

  select * into v_ship from main_ship_instances
    where main_ship_id = v_ship_id and player_id = v_player;
  if v_ship.main_ship_id is null then
    raise exception 'send_main_ship_expedition: ship not found or not owned';
  end if;
  if v_ship.status <> 'home' then
    raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
  end if;

  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' then
    raise exception 'send_main_ship_expedition: location not found or inactive';
  end if;
  if v_loc.activity_type <> 'none' then
    raise exception 'send_main_ship_expedition: only non-combat locations supported in Phase 10C (got %)', v_loc.activity_type;
  end if;

  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    raise exception 'send_main_ship_expedition: active fleet limit reached (%/%)', v_active, v_max;
  end if;

  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    raise exception 'send_main_ship_expedition: no active home base';
  end if;

  -- Insert the fleets row DIRECTLY (no fleet_units), tagged with main_ship_id.
  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_ship_id)
    returning id into v_fleet;

  -- Canonical speed resolver (main-ship branch → hull base_speed).
  v_speed := resolve_fleet_movement_speed(v_fleet);

  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'rally', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  -- Ship → legacy in-flight (status + spatial_state=NULL pair-write; the ONE shared 0152 helper).
  -- SLICE D3 (M1 race closure): re-claim the ship UNDER A ROW LOCK, re-verifying status='home',
  -- immediately before the in-flight write. The availability read at the top of this function takes
  -- no lock, so a team hunt-send committing 'hunting' between that read and this write used to be
  -- silently overwritten ('hunting' → 'traveling' — the M1 lost update, docs/TEAM_COMMAND.md). Under
  -- the lock the leaf's UPDATE below is race-proof: a concurrent writer either committed first (this
  -- re-check sees its status and rejects with the function's own not-available raise) or blocks on
  -- this lock until we commit (and then observes the ship not-'home' itself). The 0152 one-leaf law
  -- is respected — the conditional lives HERE in the caller; the write below is still the ONE shared
  -- helper. Invisible to every non-racing caller: a ship that passed the status='home' check above
  -- and is not concurrently modified locks instantly and updates exactly as before.
  perform 1 from main_ship_instances
    where main_ship_id = v_ship_id and status = 'home'
    for update;
  if not found then
    select * into v_ship from main_ship_instances where main_ship_id = v_ship_id;
    raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
  end if;
  perform public.mainship_mark_legacy_in_flight(v_ship_id, 'traveling');

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'fleet_id', v_fleet, 'movement_id', v_movement,
    'main_ship_id', v_ship_id, 'arrive_at', v_arrive);
end;
$$;

-- ── 4) Execute surface ──────────────────────────────────────────────────────────────────────────────
-- All three re-creates are CREATE OR REPLACE on EXISTING functions, which PRESERVES owner and grants
-- (process_combat_ticks / process_mainship_expeditions: internal cron bodies, service_role only;
-- send_main_ship_expedition: authenticated client RPC — all carried unchanged). NO new function is
-- created in this migration, so no grant/revoke is emitted (the D1 §7 rationale verbatim: the blanket
-- re-lock idiom belongs to migrations adding NEW client RPCs).
