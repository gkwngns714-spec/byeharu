-- Byeharu — CRON-GUARD (0206): per-row exception isolation for the two hottest legacy crons.
--
-- THE LANDMINE (7-agent audit, verified below): the two hottest legacy crons process their rows in
-- ONE transaction with NO per-row exception isolation, so a single failing row aborts the WHOLE cron
-- run and re-raises every tick forever, for EVERY player:
--   • process_fleet_movements (30s; TRUE head 0151) — loops due movements, `perform
--     movement_settle_arrival(m.id)` per row with NO begin/exception. A raise inside settle (e.g. a
--     location whose activity_type is an allowed-but-undispatched value like mine_resource /
--     explore_derelict / trade_visit / rally — all in the 0002 CHECK domain — routes
--     presence_create → activity_start (0018), which raises 'unknown activity') aborts the whole 30s
--     run → the movement stays 'moving' with arrive_at in the past → it re-raises every 30s forever,
--     wedging EVERY player's arrivals.
--   • process_combat_ticks (3s; TRUE head 0195 SHIELD-1) — per-encounter loop; any raise in the body
--     (a composed writer — fleet_destroy / fleet_set_returning / presence_complete / movement_create —
--     or a degenerate per-unit divide) aborts the whole 3s tick for ALL encounters, indefinitely.
--
-- THE FIX (already the house pattern — the EV-1 0182 / SHIPYARD-2 0194 precedent): wrap each per-row
-- body in its OWN begin/exception subtransaction, EXACTLY as process_build_queue (0194) wraps each
-- order's completion. On a row error: log a WARNING (row id + sqlerrm), the subtransaction rolls that
-- row back to its pre-iteration state, and the loop CONTINUES to the next row. query_canceled is
-- RE-RAISED (never swallow a statement-timeout cancel — the 0194/0182 posture).
--   TRADE-OFF (documented; MATCHES 0194's posture exactly): a persistently-failing row is left in its
--   pre-iteration state and retries every tick — it can spin forever — but it NO LONGER WEDGES OTHERS.
--   0194 makes the same trade (a failing hull order stays 'active' and retries next tick); wedging one
--   row is strictly better than wedging the whole cron for every player. Advancing a poison row to a
--   terminal state to stop the retry is a SEPARATE behavior change (a follow-up), NOT this slice.
--
-- NO FLAG — PURE HARDENING, DEPLOY-SAFE. On the SUCCESS path (no row raises) a subtransaction around a
-- non-erroring body is transparent: the behavior is BYTE-IDENTICAL to today (the existing
-- TEAMSETTLE / COMBATPARITY / TEAMHUNT proofs run their exact-damage/exact-settle pins against THESE
-- re-created bodies and stay green — that green IS the success-path parity witness). The change
-- manifests ONLY when a row raises — where the new behavior (skip+log that row, others proceed) is
-- strictly safer than today (whole cron aborts). No gate, no data flip, no schedule change.
--
-- PARITY DISCIPLINE (ABSOLUTE — these are LIVE hot crons): each function below is re-created from its
-- grep-verified TRUE head with ONE marked `CRON-GUARD (0206)` hunk — the begin/exception wrapper
-- around the loop body (+ the WARNING). The body logic is BYTE-IDENTICAL (extract-and-diff verified:
-- the ONLY delta is the added wrapper lines; not one body line changed). Every accumulated hunk in
-- each head survives byte-identical — combat_ticks keeps the SHIELD-1 regen/absorb/pool/gated-leaf,
-- the hp+shield sync leaves, the hull-only integrity + defeat, the D1 legacy-key idiom, the whole
-- reward pipeline; movements keeps the 0151 shared-helper settle. The self-asserts below pin all of
-- it or refuse to land.
--
-- SEVERITY [D]: the log line is a WARNING (the header/charter directive), not 0194's NOTICE — a
-- swallowed error on a 3s/30s hot cron must be visible at the default log_min_messages ('warning');
-- a NOTICE would be filtered out and the spin would go unseen. The CONTROL-FLOW shape (begin /
-- exception / query_canceled re-raise / continue-to-next-row) mirrors 0194 precisely; only the
-- severity is raised.
--
-- SCOPE: ONLY the two crons' per-row isolation. NOT the audit's G3 (legacy arrival status re-check —
-- a separate behavior change, a follow-up). No touch to calculate_expedition_stats, decks/rooms, the
-- fleet-control RPCs, or any client. Server-only — zero src/ changes.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this PR): Movement's process_fleet_movements and
-- Combat's process_combat_ticks are now per-row-isolated (a failing row can no longer wedge the run).
-- Docs synced: FULL_CAPACITY_PLAN (a hardening note), SYSTEM_BOUNDARIES, DEV_LOG. Proof:
-- scripts/team-command-proof.{sql,sh} extended (TEAMCMD_PASS_CRONGUARD — the poison-row proof).
--
-- Forward-only: 0001–0205 unedited. Takes 0206 (COMMAND-BUFFS took 0205).

-- ── (a) process_fleet_movements — 0151 head VERBATIM + the ONE marked CRON-GUARD hunk ─────────────
-- Copied byte-identical from 20260618000151:100-121. The ONLY delta is the marked per-movement
-- begin/exception subtransaction wrapping the loop body (settle + count). On the success path the
-- wrapper is transparent (byte-identical to 0151); on a settle raise it logs + skips + continues.
create or replace function public.process_fleet_movements()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  m       record;
  v_count integer := 0;
begin
  for m in
    select * from fleet_movements
    where status = 'moving' and arrive_at <= now()
    for update skip locked
  loop
    -- ── CRON-GUARD (0206) HUNK: the per-movement subtransaction (the 0194 per-order guard, mirrored).
    --    A raise inside movement_settle_arrival (e.g. presence_create → activity_start 'unknown
    --    activity' for an allowed-but-undispatched location activity_type) must NOT abort the whole
    --    30s run and re-raise forever for every player. On failure THIS movement's settle rolls back
    --    (the subtransaction), a WARNING logs it, the movement is left 'moving' (pre-iteration state)
    --    to retry next tick, and the loop CONTINUES — other players' arrivals settle. query_canceled
    --    re-raised (never swallow a statement-timeout cancel — the 0194/0182 posture). v_count sits
    --    INSIDE the guard, so a failed settle is UNCOUNTED (the 0194 posture — a poison row never
    --    inflates the processed count). ─────────────────────────────────────────────────────────────
    begin
    perform movement_settle_arrival(m.id);
    v_count := v_count + 1;
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_fleet_movements: settle failed for movement % (left moving; retries next tick): %',
          m.id, sqlerrm;
    end;
    -- ── END CRON-GUARD (0206) HUNK ───────────────────────────────────────────────────────────────
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.process_fleet_movements() from public, anon, authenticated;

-- ── (b) process_combat_ticks — 0195 head VERBATIM + the ONE marked CRON-GUARD hunk ───────────────
-- Copied byte-identical from 20260618000195:227-585 (the SHIELD-1 head — every accumulated hunk
-- survives: the SHIELD-1 in-combat regen / the ONE absorb point / the persisted pool / the gated
-- ship-row shield leaf, the hp sync sibling, the hull-only integrity + defeat, the D1 legacy-key
-- idiom, the whole reward pipeline). The ONLY delta is the marked per-encounter begin/exception
-- subtransaction wrapping the loop body. On the success path the wrapper is transparent
-- (byte-identical to 0195); on any per-encounter raise it logs + skips + continues. The body's own
-- `continue` statements still target the enclosing `for e` loop (a begin block is not a loop).
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
  v_shield_regen  double precision;  -- SHIELD-1 (0195): in-combat regen fraction — read ONCE per invocation
  v_shield        double precision;  -- SHIELD-1 (0195): a row's shield pool through regen → absorb (NULL = shieldless)
  v_absorb        double precision;  -- SHIELD-1 (0195): the shield-absorbed slice of a row's damage
begin
  v_tick_secs     := coalesce(cfg_num('combat_tick_seconds'), 3);
  v_retreat_delay := coalesce(cfg_num('retreat_delay_seconds'), 8);
  v_trans_secs    := coalesce(cfg_num('wave_transition_seconds'), 3);
  v_var_pct       := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
  v_def_base      := coalesce(cfg_num('defense_curve_base'), 100);
  v_log_ticks     := cfg_bool('combat_tick_logging');
  v_log_events    := cfg_bool('combat_event_logging');
  v_log_debug     := cfg_bool('combat_debug_logging');
  -- SHIELD-1 (0195): the regen knob joins the one-read-per-invocation block above (never read
  -- inside the per-encounter/per-row loops). Committed seed '0' (0191) → the regen term is
  -- arithmetically zero on every row until the human ACT-SHIELD flip raises it.
  v_shield_regen  := coalesce(cfg_num('shield_regen_combat_pct'), 0);

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
    -- ── CRON-GUARD (0206) HUNK: the per-encounter subtransaction (the 0194 per-order guard, mirrored).
    --    Any raise in the per-encounter body (a composed writer — fleet_destroy / fleet_set_returning /
    --    presence_complete / movement_create / report_create — or a degenerate per-unit divide) must
    --    NOT abort the whole 3s tick for ALL encounters and re-raise forever. On failure THIS
    --    encounter's tick rolls back (the subtransaction), a WARNING logs it, the encounter is left in
    --    its pre-tick state to retry next tick, and the loop CONTINUES — other encounters tick.
    --    query_canceled re-raised (never swallow a statement-timeout cancel — the 0194/0182 posture).
    --    v_count sits INSIDE the guard (its last body line), so a failed tick is UNCOUNTED. ──────────
    begin
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
      -- SHIELD-1 (0195): in-combat regen at the top of the per-row loop — the D1 coalesce-NULL
      -- parity idiom (0167:12-14). The 0191 pairing CHECK guarantees shield_max/shield_current are
      -- NULL together (non-NULL only on member rows), so this least() sees either two NULLs
      -- (→ stays NULL: every legacy/catalog row and every shieldless member is UNTOUCHED) or two
      -- values (→ climb by max_shield × knob, capped at max_shield; knob '0' → byte-inert).
      v_shield    := least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen);
      v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
      -- SHIELD-1 (0195): THE ONE ABSORB POINT — the shield soaks min(pool, damage); ONLY the
      -- overflow reaches the hull. A NULL/zero pool → v_absorb = 0 → the hull expression collapses
      -- to the head's exact arithmetic (cu.hp_current - v_d_group) and a NULL pool stays NULL
      -- (NULL - 0). No second damage path exists: every downstream statement consumes v_new_hp
      -- unchanged.
      v_absorb    := least(coalesce(v_shield, 0), v_d_group);
      v_shield    := v_shield - v_absorb;
      v_new_hp    := cu.hp_current - (v_d_group - v_absorb);
      v_new_alive := greatest(0, least(cu.alive_count, ceil(v_new_hp / cu.ship_hp)::integer));
      v_destroyed := cu.alive_count - v_new_alive;
      update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive,
             shield_current = v_shield,   -- SHIELD-1 (0195): NULL stays NULL; shield_max stays FROZEN
             updated_at = now()
        where id = cu.id;
      -- SLICE D1: survivor sync splits by identity — ONLY catalog-keyed counts feed
      -- fleet_sync_quantities below; a member row syncs its damage to the ship row (hp ONLY) via the
      -- one-leaf writer. Legacy rows always take the first branch, executing the identical statement.
      if cu.unit_type_id is not null then
        v_counts := v_counts || jsonb_build_object(cu.unit_type_id, v_new_alive);
      else
        perform mainship_sync_combat_hp(cu.main_ship_id, round(greatest(0, v_new_hp))::integer);
        -- SHIELD-1 (0195): the shield sibling of the hp sync above — mainship_sync_combat_shield
        -- (0191) is the ONE ship-row shield writer, called EXACTLY as its hp sibling is (both
        -- leaves SECURITY DEFINER + service-role-only; this SECURITY DEFINER tick invokes them as
        -- owner — the 0167:559-564 ACL precedent). Gated on a non-NULL pool: a shieldless/legacy
        -- member row fires NO shield write at all, so per-tick write counts stay byte-identical
        -- to the pre-SHIELD1 tick (v_shield is never negative here — absorb ≤ pool — and the
        -- leaf's own least/greatest clamps guard the integer domain regardless).
        if v_shield is not null then
          perform mainship_sync_combat_shield(cu.main_ship_id, round(v_shield)::integer);
        end if;
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
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_combat_ticks: tick failed for encounter % (left in-place; retries next tick): %',
          e.id, sqlerrm;
    end;
    -- ── END CRON-GUARD (0206) HUNK ───────────────────────────────────────────────────────────────
  end loop;

  return v_count;
end;
$$;

-- ── (c) Execute surface ──────────────────────────────────────────────────────────────────────────
-- CREATE OR REPLACE on both EXISTING functions PRESERVES their owner + grants (process_combat_ticks:
-- the internal cron body — the 0195 posture, no re-lock emitted); process_fleet_movements re-asserts
-- its 0151 client-revoke above (belt-and-braces; create-or-replace already preserved it).

-- ── (d) SELF-ASSERTS — the migration proves its own guard + parity or refuses to land ─────────────
do $$
declare
  v_mv  text;
  v_cb  text;
  v_n   integer;
  v_tok text;
begin
  select prosrc into v_mv from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_fleet_movements';
  select prosrc into v_cb from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_mv is null or v_cb is null then
    raise exception 'CRON-GUARD self-assert FAIL: a re-created cron function is missing';
  end if;

  -- (1) THE GUARD landed on BOTH crons: the per-row subtransaction re-raises query_canceled and logs
  --     a WARNING with the row id + sqlerrm — EXACTLY once each (one loop, one guard).
  v_n := (length(v_mv) - length(replace(v_mv, 'when query_canceled then raise', ''))) / length('when query_canceled then raise');
  if v_n <> 1 then raise exception 'CRON-GUARD self-assert FAIL: process_fleet_movements has % query_canceled re-raise(s) (want exactly 1)', v_n; end if;
  v_n := (length(v_cb) - length(replace(v_cb, 'when query_canceled then raise', ''))) / length('when query_canceled then raise');
  if v_n <> 1 then raise exception 'CRON-GUARD self-assert FAIL: process_combat_ticks has % query_canceled re-raise(s) (want exactly 1)', v_n; end if;
  if strpos(v_mv, 'raise warning ''process_fleet_movements: settle failed for movement %') = 0 then
    raise exception 'CRON-GUARD self-assert FAIL: process_fleet_movements is missing its per-movement WARNING log';
  end if;
  if strpos(v_cb, 'raise warning ''process_combat_ticks: tick failed for encounter %') = 0 then
    raise exception 'CRON-GUARD self-assert FAIL: process_combat_ticks is missing its per-encounter WARNING log';
  end if;
  -- the log is a WARNING (the charter severity), not a NOTICE (would be filtered at default levels).
  if strpos(v_mv, 'raise notice') <> 0 or strpos(v_cb, 'raise notice') <> 0 then
    raise exception 'CRON-GUARD self-assert FAIL: a re-created cron logs via raise notice (want raise warning — the charter severity)';
  end if;

  -- (2) THE GUARD WRAPS THE LOOP BODY (token order): the body's first statement sits AFTER the row
  --     cursor's `for update skip locked` opener, and the `exception` handler sits AFTER the body's
  --     first statement — i.e. the whole body is inside the subtransaction, not before/around it.
  if strpos(v_mv, 'for update skip locked') = 0
     or strpos(v_mv, 'perform movement_settle_arrival(m.id)') < strpos(v_mv, 'for update skip locked') then
    raise exception 'CRON-GUARD self-assert FAIL: process_fleet_movements body is not inside the row loop';
  end if;
  if strpos(v_mv, 'exception') < strpos(v_mv, 'perform movement_settle_arrival(m.id)') then
    raise exception 'CRON-GUARD self-assert FAIL: process_fleet_movements exception handler precedes the settle body (guard misplaced)';
  end if;
  if strpos(v_cb, 'exception') < strpos(v_cb, 'v_tick := e.tick_number + 1;') then
    raise exception 'CRON-GUARD self-assert FAIL: process_combat_ticks exception handler precedes the tick body (guard misplaced)';
  end if;

  -- (3) MOVEMENTS body byte-intact (0151 head): the shared-helper settle + the exact due-row scan.
  foreach v_tok in array array[
    'perform movement_settle_arrival(m.id);',
    'v_count := v_count + 1;',
    'where status = ''moving'' and arrive_at <= now()',
    'for update skip locked'] loop
    if strpos(v_mv, v_tok) = 0 then
      raise exception 'CRON-GUARD self-assert FAIL: process_fleet_movements lost the 0151 head token ''%''', v_tok;
    end if;
  end loop;

  -- (4) COMBAT body byte-intact — EVERY accumulated hunk in the 0195 head survives the re-create:
  --     the exact due-row scan; the SHIELD-1 regen / the ONE absorb point / the persisted pool / the
  --     gated ship-row shield leaf + its hp sync sibling; the hull-only integrity aggregate + BOTH
  --     hull-only defeat predicates; the D1 legacy-key idiom; and the full reward pipeline.
  foreach v_tok in array array[
    'where status in (''active'',''retreating'')',
    'v_shield    := least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen);',
    'v_absorb    := least(coalesce(v_shield, 0), v_d_group);',
    'v_new_hp    := cu.hp_current - (v_d_group - v_absorb);',
    'shield_current = v_shield',
    'if v_shield is not null then',
    'mainship_sync_combat_shield(cu.main_ship_id, round(v_shield)::integer)',
    'mainship_sync_combat_hp(cu.main_ship_id, round(greatest(0, v_new_hp))::integer)',
    'if v_hp_total <= 0 or v_alive_total <= 0 then',
    'if v_hp_after <= 0 then',
    'coalesce(sum(cu2.hp_current), 0)',
    'select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id;',
    'player_integrity_current = greatest(0, v_hp_after)',
    'coalesce(cu.unit_type_id, cu.main_ship_id::text)',
    'v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);',
    'perform fleet_destroy(e.fleet_id);',
    'perform fleet_set_returning(e.fleet_id, v_mv);',
    'perform presence_complete(e.presence_id);',
    'perform report_create(e.id);',
    'mainship_mark_combat_destroyed(cu.main_ship_id)',
    'mainship_mark_legacy_in_flight(cu.main_ship_id, ''returning'')',
    'perform fleet_sync_quantities(e.fleet_id, v_counts);'] loop
    if strpos(v_cb, v_tok) = 0 then
      raise exception 'CRON-GUARD self-assert FAIL: process_combat_ticks lost an accumulated head hunk (token ''%'')', v_tok;
    end if;
  end loop;

  -- (5) DETERMINISM (0041): the guard added NO randomness. The combat body keeps EXACTLY the head's
  --     one variance random( call; movements has none.
  v_n := (length(v_cb) - length(replace(v_cb, 'random(', ''))) / length('random(');
  if v_n <> 1 then raise exception 'CRON-GUARD self-assert FAIL: process_combat_ticks carries % random( call(s) (want exactly the head''s 1)', v_n; end if;
  if strpos(v_mv, 'random(') <> 0 then raise exception 'CRON-GUARD self-assert FAIL: process_fleet_movements carries random( (0041 breach)'; end if;

  -- (6) ACL preserved by CREATE OR REPLACE: neither cron is client-executable.
  if has_function_privilege('authenticated', 'public.process_fleet_movements()', 'execute')
     or has_function_privilege('anon', 'public.process_fleet_movements()', 'execute')
     or has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception 'CRON-GUARD self-assert FAIL: a re-created cron is client-executable';
  end if;

  raise notice 'CRON-GUARD self-assert ok: both hot crons re-created from their TRUE heads (0151 / 0195) with ONE per-row begin/exception subtransaction each (query_canceled re-raised, WARNING logged, v_count inside the guard); the guard wraps the loop body (token order pinned); movements body byte-intact (0151 shared-helper settle + due-row scan); combat body byte-intact — every accumulated hunk survives (SHIELD-1 regen/absorb/pool/gated-leaf + hp sync, hull-only integrity + both defeat predicates, D1 legacy keys, the reward pipeline); determinism preserved (combat 1 random(, movements 0); ACLs closed to clients';
end $$;
