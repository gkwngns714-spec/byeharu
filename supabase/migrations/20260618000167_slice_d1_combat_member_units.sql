-- Byeharu — TEAM-COMMAND Slice D1: combat_units member widening + tick/report parity re-create (DARK).
--
-- ── WHAT THIS IS ────────────────────────────────────────────────────────────────────────────────────
-- The riskiest team-command phase: the LIVE combat cron body (process_combat_ticks, head 0046) and the
-- LIVE report writer (report_create, head 0026) are re-created here so combat_units can later carry
-- MEMBER MAIN SHIPS (main_ship_id) alongside legacy catalog units (unit_type_id). Slice D1 adds the
-- storage + the engine branches ONLY — there is NO writer of member combat_units rows until D2's
-- flag-gated RPC, so every member branch below is UNREACHABLE today.
--
-- ── THE PARITY LAW (absolute requirement) ───────────────────────────────────────────────────────────
-- Every delta to the two live bodies is either
--   (a) a `coalesce(member_value, legacy_value)` where member_value is NULL on every existing row, or
--   (b) a branch reachable ONLY when a combat_units row has main_ship_id IS NOT NULL — and no such row
--       can exist before D2 (no writer; existing rows all carry unit_type_id).
-- So live pirate-hunt combat behavior is provably byte-identical. Both bodies are copied VERBATIM from
-- their true heads (verified by grepping every migration for each function name and taking the latest:
-- process_combat_ticks ← 0046:56, report_create ← 0026:13); each delta carries a `-- SLICE D1:` marker.
-- Nothing else in either body changes — same variable names, same statement order, same everything.
--
-- ── SCHEMA: combat_units widening (Combat system stays the sole writer) ─────────────────────────────
--   • main_ship_id uuid NULL → main_ship_instances(main_ship_id): the member identity. ON DELETE
--     CASCADE: a member combat row is meaningless without its ship, and combat_units already cascades
--     away with its encounter — cascade also keeps a whole-account deletion (auth.users → cascade into
--     BOTH main_ship_instances and combat_encounters) order-independent, where NO ACTION could trip on
--     whichever parent row the cascade reaches first.
--   • attack_snapshot / defense_snapshot double precision NULL: the member's D0-authority stats frozen
--     at encounter creation (D2 writes them). double precision matches unit_types.attack/defense (0004).
--   • unit_type_id relaxed to NULL (was NOT NULL since 0023) + CHECK exactly-one-identity. Every
--     existing row has unit_type_id NOT NULL and the new columns NULL → the CHECK is trivially
--     satisfied; NO backfill, NO writer of the new columns in this slice.
--   • snapshot-pairing CHECK (snapshots exist IFF member row — guards the coalesce-first stat read
--     from a stray catalog-row snapshot / a silent-zero member) and a partial unique index (one
--     member row per encounter+ship — the member mirror of the legacy unique (encounter_id,
--     unit_type_id), whose NULLs never collide). Both trivially satisfied by every existing row.
--
-- ── NEW LEAVES (internal cron/engine only; the 0153 one-leaf idiom + ACL posture) ───────────────────
--   • combat_fleet_return_speed(p_fleet)          — min member HULL base_speed over the fleet's active
--                                                    encounter's member rows (the EXACT hull-speed
--                                                    source request_main_ship_return uses, 0050:205-211);
--                                                    NULL when the fleet has no member rows → the
--                                                    coalesce in the tick is a no-op for legacy fleets.
--   • mainship_sync_combat_hp(p_main_ship_id, p_hp integer)
--                                                  — writes main_ship_instances.hp ONLY (hp is integer,
--                                                    0043). The member mirror of fleet_sync_quantities.
--   • mainship_mark_combat_destroyed(p_main_ship_id)
--                                                  — the combat-side ship-terminal write. Mirrors the
--                                                    EXACT terminal state dev_set_main_ship_destroyed
--                                                    (0059) writes: status='destroyed', hp=0,
--                                                    spatial_state=NULL + coords NULL. spatial_state
--                                                    CANNOT be left untouched: the 0055 lifecycle CHECKs
--                                                    (ss_at_location/ss_in_space → status='stationary',
--                                                    ss_home → 'home') reject status='destroyed' under
--                                                    any non-NULL spatial_state, and 0059's frozen D-1
--                                                    decision (destroyed ⇒ spatial_state NULL, keeping
--                                                    repair_main_ship valid) is the proven shape.
--                                                    NOTE: this becomes the SECOND trusted destruction
--                                                    writer — 0059's "unique trusted destruction writer"
--                                                    claim is superseded; both write the same terminal.
--   All three: SECURITY DEFINER, set search_path=public, revoked from public/anon/authenticated,
--   service_role only (NO client grant) — the mainship_mark_docked_at_location posture (0153).
--
-- ── OUT OF SCOPE ────────────────────────────────────────────────────────────────────────────────────
-- NO member-row writer (D2), NO flag flip, NO frontend, NO backfill, NO edit to any shipped migration.
-- Cron schedule untouched: 'process-combat-ticks' (0026) stays the ONE combat engine job.

-- ── 1) combat_units widening ────────────────────────────────────────────────────────────────────────
alter table public.combat_units
  add column main_ship_id     uuid references public.main_ship_instances (main_ship_id) on delete cascade,
  add column attack_snapshot  double precision,
  add column defense_snapshot double precision;

alter table public.combat_units alter column unit_type_id drop not null;

-- Exactly ONE identity per combat row: catalog unit XOR member main ship. All existing rows have
-- unit_type_id NOT NULL (it was NOT NULL until this migration) and main_ship_id NULL → trivially valid.
alter table public.combat_units
  add constraint combat_units_exactly_one_identity
  check ((unit_type_id is null) <> (main_ship_id is null));

-- Snapshots exist IFF the row is a member row — the schema half of the parity law. The tick's
-- snapshot-first read `coalesce(attack_snapshot, ut.attack)` TRUSTS that a catalog row never carries
-- a stray snapshot (which would silently override live catalog stats) and that a member row always
-- carries both (a NULL member snapshot would contribute silent-zero attack/defense through the left
-- join). Trivially satisfied by every existing row (catalog identity, both snapshots NULL).
alter table public.combat_units
  add constraint combat_units_member_snapshot_pairing
  check ((main_ship_id is null and attack_snapshot is null and defense_snapshot is null)
      or (main_ship_id is not null and attack_snapshot is not null and defense_snapshot is not null));

-- One member row per (encounter, main ship) — the member mirror of the legacy
-- unique (encounter_id, unit_type_id) (0023), which cannot cover member rows because its unit_type_id
-- is NULL there and NULLs never collide in a unique constraint. Without this, the same main ship
-- inserted twice into one encounter would double its attack contribution and double-drive the hp
-- sync. Partial index → zero effect on legacy rows.
create unique index combat_units_one_member_row_per_encounter
  on public.combat_units (encounter_id, main_ship_id) where main_ship_id is not null;

comment on column public.combat_units.main_ship_id is
  'Slice D1: member main-ship identity (XOR unit_type_id). NO writer until D2''s flag-gated RPC.';
comment on column public.combat_units.attack_snapshot is
  'Slice D1: member attack frozen at encounter creation (D2 writes it); NULL on every catalog-unit row.';
comment on column public.combat_units.defense_snapshot is
  'Slice D1: member defense frozen at encounter creation (D2 writes it); NULL on every catalog-unit row.';

-- ── 2) combat_fleet_return_speed: member-fleet return speed (NULL for legacy fleets) ────────────────
-- The member analogue of fleet_speed (min over the marching column). Source of truth for a member
-- ship's speed is its HULL's base_speed — the EXACT source request_main_ship_return derives its
-- return speed from (0050:205-211: main_ship_instances → main_ship_hull_types.base_speed, cast to
-- double precision). Scoped to the fleet's active/retreating encounter's member rows: the tick's (B)
-- escape branch computes the return speed BEFORE it settles the encounter row, so the encounter is
-- still active/retreating at the call site (0046:176 ordering), and one_active_encounter_per_fleet
-- (0014) pins it unique. Returns NULL when the fleet has no member combat rows (every fleet today) →
-- the tick's coalesce is a provable no-op for legacy fleets.
create or replace function public.combat_fleet_return_speed(p_fleet uuid)
returns double precision
language sql
stable
security definer
set search_path = public
as $$
  select min(h.base_speed)::double precision
  from combat_encounters ce
  join combat_units cu on cu.encounter_id = ce.id and cu.main_ship_id is not null
  join main_ship_instances msi on msi.main_ship_id = cu.main_ship_id
  join main_ship_hull_types h on h.hull_type_id = msi.hull_type_id
  where ce.fleet_id = p_fleet and ce.status in ('active','retreating');
$$;

-- ── 3) mainship_sync_combat_hp: the ONE member survivor-sync write (hp ONLY) ────────────────────────
-- The member mirror of fleet_sync_quantities: after each combat step the tick syncs member damage back
-- to the ship row. Writes main_ship_instances.hp ONLY (integer, 0043) — never status, never spatial
-- state, never fleets. Unknown p_main_ship_id updates zero rows (the 0153 helper's missing-row
-- semantics). Unreachable until D2 creates member combat rows.
create or replace function public.mainship_sync_combat_hp(p_main_ship_id uuid, p_hp integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.main_ship_instances
    set hp = greatest(0, p_hp), updated_at = now()
    where main_ship_id = p_main_ship_id;
end;
$$;

-- ── 4) mainship_mark_combat_destroyed: the combat-side ship terminal ────────────────────────────────
-- Called by the tick after fleet_destroy when an encounter with member rows is wiped. Writes the EXACT
-- ship-terminal state dev_set_main_ship_destroyed (0059, its step (3)) writes: status='destroyed',
-- hp=0, spatial_state=NULL, coords NULL. 0059's frozen D-1 holds here too: destroyed keeps
-- spatial_state NULL (never 'destroyed') so repair_main_ship — which sets status='home' but never
-- resets spatial_state — recovers to a clean legacy_home. Leaving spatial_state untouched instead
-- would violate the 0055 lifecycle CHECKs for any docked/held ship (at_location/in_space require
-- status='stationary'; home requires 'home').
--   The surrounding fleet/movement/presence cleanup 0059 performs is NOT duplicated here: at this call
-- site the tick has ALREADY destroyed the fleet (fleet_destroy) and completed the presence — this leaf
-- only settles the ship row. With this function, 0059 stops being the UNIQUE trusted destruction
-- writer (its audit note); it becomes one of exactly two, both writing the same terminal shape.
-- Unreachable until D2 creates member combat rows.
create or replace function public.mainship_mark_combat_destroyed(p_main_ship_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.main_ship_instances
    set status = 'destroyed', hp = 0, spatial_state = null, space_x = null, space_y = null, updated_at = now()
    where main_ship_id = p_main_ship_id;
end;
$$;

-- ── 5) process_combat_ticks: 0046:56 body VERBATIM + the marked SLICE D1 member deltas ──────────────
-- Copied from the true head (0046 — nothing later re-creates it; verified by grep over ALL migrations).
-- Deltas (each marked in-body): (a) stat aggregation left-joins unit_types and reads
-- coalesce(snapshot, catalog); (b) every per-row jsonb key/payload uses
-- coalesce(unit_type_id, main_ship_id::text); (c) fleet_sync_quantities receives ONLY catalog-keyed
-- counts — member rows sync via mainship_sync_combat_hp; (d) return speed falls back to
-- combat_fleet_return_speed for unit-less member fleets; (e) after each fleet_destroy, member ships
-- are marked combat-destroyed. Every delta is coalesce-NULL or member-row-gated → legacy byte-parity.
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

-- ── 6) report_create: 0026:13 body VERBATIM + the marked SLICE D1 member delta ──────────────────────
-- Copied from the true head (0026 — nothing later re-creates it; verified by grep over ALL migrations).
-- ONE delta: jsonb_object_agg raises on a NULL key, so survivors/losses key by
-- coalesce(unit_type_id, main_ship_id::text). Every legacy row has unit_type_id NOT NULL → the legacy
-- report output is byte-identical.
create or replace function public.report_create(p_encounter uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  e          combat_encounters%rowtype;
  v_id       uuid;
  v_survivors jsonb;
  v_losses    jsonb;
  v_dur      integer;
begin
  select * into e from combat_encounters where id = p_encounter;
  if not found then
    raise exception 'report_create: encounter % not found', p_encounter;
  end if;
  if exists (select 1 from combat_reports where encounter_id = p_encounter) then
    return null;
  end if;

  -- SLICE D1: jsonb_object_agg raises on a NULL key → member rows key by main_ship_id::text. Every
  -- legacy row has unit_type_id NOT NULL, so legacy reports keep their exact unit_type keys.
  select
    coalesce(jsonb_object_agg(coalesce(unit_type_id, main_ship_id::text), alive_count) filter (where alive_count > 0), '{}'::jsonb),
    coalesce(jsonb_object_agg(coalesce(unit_type_id, main_ship_id::text), initial_count - alive_count) filter (where initial_count - alive_count > 0), '{}'::jsonb)
    into v_survivors, v_losses
    from combat_units where encounter_id = p_encounter;

  v_dur := greatest(0, extract(epoch from (coalesce(e.ended_at, now()) - e.started_at))::integer);

  insert into combat_reports (
    encounter_id, player_id, fleet_id, location_id, result, waves_cleared,
    duration_seconds, total_losses_json, total_rewards_json, survivors_json, summary_text)
  values (
    e.id, e.player_id, e.fleet_id, e.location_id, e.status, e.waves_cleared,
    v_dur, coalesce(v_losses, '{}'::jsonb), e.total_rewards_json, coalesce(v_survivors, '{}'::jsonb),
    format('%s after %s wave(s) over %ss', e.status, e.waves_cleared, v_dur))
  on conflict (encounter_id) do nothing
  returning id into v_id;

  update combat_encounters set report_created_at = now() where id = p_encounter;
  return v_id;
end;
$$;

-- ── 7) Execute surface ──────────────────────────────────────────────────────────────────────────────
-- CREATE OR REPLACE on the two EXISTING functions PRESERVES their owner and grants (both are internal
-- cron/engine functions with no client grant), so no blanket re-lock is emitted (the 0153 precedent:
-- that idiom belongs to migrations adding NEW client RPCs). The three NEW leaves do NOT default-grant
-- to PUBLIC on create — the `alter default privileges … revoke execute on functions` standing since
-- the early relocks (0046/0055/0059 et al.) already covers newly-created functions — but the explicit
-- revoke is kept anyway: the 0152/0153 helper idiom's belt-and-braces posture, correct regardless of
-- the default-privilege state of whichever role runs this migration. The SECURITY DEFINER tick
-- invokes them as owner; service_role keeps CI/inspection access; NO client role can execute them.
revoke execute on function public.combat_fleet_return_speed(uuid)            from public, anon, authenticated;
grant  execute on function public.combat_fleet_return_speed(uuid)            to service_role;
revoke execute on function public.mainship_sync_combat_hp(uuid, integer)     from public, anon, authenticated;
grant  execute on function public.mainship_sync_combat_hp(uuid, integer)     to service_role;
revoke execute on function public.mainship_mark_combat_destroyed(uuid)       from public, anon, authenticated;
grant  execute on function public.mainship_mark_combat_destroyed(uuid)       to service_role;
