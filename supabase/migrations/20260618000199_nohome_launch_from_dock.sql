-- Byeharu — NO-HOME (launch-from-dock), DARK behind a new flag. Migration 0199.
--
-- ── THE OWNER'S ABSOLUTE LAW ─────────────────────────────────────────────────────────────────────────
-- There is NO home base; ports are the only base; a ship acts from WHEREVER it is docked. Today SEND
-- (send_main_ship_expedition, 0169) and HUNT (send_ship_group_hunt, 0168) require ship status='home'
-- and launch the outbound fleet from the legacy invisible base at (0,0). A DOCKED ship
-- (status='stationary' + spatial_state='at_location') can MOVE (move_main_ship_to_location, 0156) but
-- cannot SEND/HUNT — that is the bug. This slice fixes it, DARK behind `launch_from_dock_enabled`
-- (seeded false) so PROD IS UNTOUCHED until the owner flips it (scripts/activate-nohome.sql).
--
-- ── DESIGN (locked with the owner) ───────────────────────────────────────────────────────────────────
-- 1. ADDITIVE dual-state launch, not removal. Send/hunt ACCEPT a docked ship as a legal launch state
--    IN ADDITION to home — mirroring the EXISTING settled-safe rule the game already uses for
--    explore/mine/fit/captain: spatial_state in ('home','at_location') (0100/0105/0114/0121). The
--    'home' enum value and every home-based launch stay intact. When a docked ship launches, the
--    outbound fleet departs FROM its docked port (the present-fleet origin) exactly the way
--    move_main_ship_to_location (0156, the working template) launches from the present fleet — NOT
--    from the (0,0) bases row.
-- 2. Player-chosen return port. Send/hunt gain a trailing `p_return_location_id uuid` (DEFAULT NULL —
--    so every existing 2-arg call, client and wrapper, keeps working). After the activity the ship
--    DOCKS at that chosen port instead of auto-re-homing. For a send-TO-a-port the destination IS the
--    dock (movement_settle_arrival already docks a dockable arrival, 0153) and the return param is
--    recorded-but-otherwise-inert. For a HUNT (a non-dockable combat site) the return param names the
--    port the team docks at after combat. The return port is recorded on the fleet
--    (fleets.return_location_id — an additive nullable column) so the reconciler
--    (process_mainship_expeditions) can dock the returning ship at it (the canonical pair
--    status='stationary'/spatial_state='at_location' via the 0153 helper mainship_mark_docked_at_location)
--    instead of re-homing.
-- 3. Flag-gate every behavior change. New flag launch_from_dock_enabled seeded false. When DARK,
--    send/hunt behave EXACTLY as today (home-only, bases origin, re-home reconciler) — byte-identical;
--    when LIT, the dual-state acceptance + docked launch + chosen-return-dock behavior. Every new
--    behavior is gated inside `if v_launch_from_dock then <NOHOME> else <original head verbatim> end`.
--    The DARK else-branch of each function is the grep-verified TRUE head body VERBATIM (extract-and-diff).
--
-- ── GROUNDING (grep-verified TRUE heads) ─────────────────────────────────────────────────────────────
--   send_main_ship_expedition       — 20260618000169 (last def; nothing later re-creates it)
--   send_ship_group_hunt            — 20260618000168 (only def)
--   send_ship_group_expedition      — 20260618000187 (loops the single send; UNTOUCHED here — it calls
--                                     send_main_ship_expedition with 2 positional args, which resolve to
--                                     the new 3-arg function via the p_return_location_id DEFAULT NULL)
--   process_mainship_expeditions    — 20260618000198 (latest head; the re-home reconciler)
--   repair_main_ship                — 20260618000081 (re-homes a repaired ship)
--   move_main_ship_to_location      — 20260618000156 (the launch-from-present template, reused here)
--   movement_settle_arrival / mainship_mark_docked_at_location — 20260618000153 (the dock helpers; UNTOUCHED)
--   settled-safe dual-state precedent — 20260618000100/0105/0114/0121
--
-- ── PARITY DISCIPLINE (ABSOLUTE — team command is LIVE on prod) ───────────────────────────────────────
-- These are LIVE hot functions. Each is re-created from its TRUE head with the ONE gate flag read once
-- at the top and the NOHOME behavior confined to `if v_launch_from_dock then … else <original> end`
-- blocks. With the flag DARK (its committed seed) v_launch_from_dock is false → every else-branch runs
-- → byte-identical behavior to the head. No random(); reject-before-read; all-or-nothing. Signature note:
-- send_main_ship_expedition and send_ship_group_hunt DROP+CREATE to add the trailing defaulted param
-- (CREATE OR REPLACE cannot widen an argument list); their ACLs are re-asserted after the create.

-- ── §1) NEW flag launch_from_dock_enabled (game_config bool, seeded FALSE) ─────────────────────────────
-- Mirrors the team_command_enabled seed idiom (0160): on conflict do nothing so a re-apply never
-- un-flips a live activation. OFF on live — dark until a human runs scripts/activate-nohome.sql.
insert into public.game_config (key, value, description) values
  ('launch_from_dock_enabled', 'false',
   'NO-HOME (0199): server gate for launch-from-dock. When true, send_main_ship_expedition / '
   'send_ship_group_hunt accept a DOCKED ship (spatial_state=at_location) as a launch state in addition '
   'to home, launch from the docked port, and dock the returning ship at the chosen return port instead '
   'of re-homing (process_mainship_expeditions / repair_main_ship). OFF on live — dark until a human flips it.')
on conflict (key) do nothing;

-- ── §2) fleets.return_location_id — the recorded return port (additive, nullable) ─────────────────────
-- Analogous to how origin is tracked (fleets.origin_base_id). Nullable → locations(id) ON DELETE SET
-- NULL: a deleted return port merely un-records it (the reconciler then falls back to re-home). NULL on
-- every existing row and every DARK-path fleet — nothing reads it while the flag is dark. The reconciler
-- reads it ONLY on the LIT path.
alter table public.fleets
  add column if not exists return_location_id uuid references public.locations (id) on delete set null;
comment on column public.fleets.return_location_id is
  'NO-HOME (0199): the player-chosen (or origin) port a launched ship docks at on return, recorded by '
  'send_main_ship_expedition / send_ship_group_hunt when launch_from_dock_enabled is lit. NULL for every '
  'home-launched / dark-path fleet; read ONLY by process_mainship_expeditions on the lit dock-at-return path.';

-- ── §3) send_main_ship_expedition — 0169 head VERBATIM (else-branch) + the marked NOHOME docked launch ─
-- New signature adds the trailing p_return_location_id (DEFAULT NULL). DROP+CREATE (widening the arg
-- list); ACL re-asserted below. The DARK path (v_launch_from_dock false) is the 0169:585-630 tail verbatim.
drop function if exists public.send_main_ship_expedition(jsonb, uuid);
create function public.send_main_ship_expedition(p_ships jsonb, p_location uuid, p_return_location_id uuid default null)
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
  -- NOHOME (0199): the gate, read ONCE. Dark seed → false → every NOHOME branch below is skipped and
  -- the 0169 head runs verbatim.
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
  v_present  record;   -- NOHOME: the docked ship's present fleet (the 0156 launch-from-present origin)
  v_cur      record;   -- NOHOME: docked-port coordinates + zone (origin A)
  v_return   uuid;     -- NOHOME: chosen (or origin) return port recorded on the fleet
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
  -- NOHOME (0199): the ONE marked availability hunk. DARK — v_launch_from_dock false → the inner guard
  -- is `if not false` → the 0169 raise fires for any non-'home' status (byte-identical). LIT — a DOCKED
  -- ship (the settled-safe pair status='stationary'/spatial_state='at_location', the 0100/0105/0114/0121
  -- SAFE set) is ALSO a legal launch state; the raise line is the 0169 line verbatim.
  if v_ship.status <> 'home' then
    if not (v_launch_from_dock and v_ship.status = 'stationary' and v_ship.spatial_state = 'at_location') then
      raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
    end if;
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

  -- ── NOHOME (0199) LAUNCH-FROM-DOCK BRANCH ───────────────────────────────────────────────────────────
  -- A docked ship already flies ONE present fleet (status='present' with an active location_presence).
  -- Re-depart THAT fleet from its docked port — never the (0,0) legacy base — exactly the way
  -- move_main_ship_to_location's present-departure origin works (0156:105-125). No new fleet, so NO
  -- fleet-limit check (0156 takes none — a re-depart consumes no new slot). Records the chosen (or the
  -- docked-origin) return port on the fleet. All of this is unreachable when the flag is dark.
  if v_launch_from_dock and v_ship.status = 'stationary' and v_ship.spatial_state = 'at_location' then
    select f.id, f.main_ship_id into v_present
      from fleets f
      where f.main_ship_id = v_ship_id and f.player_id = v_player and f.status = 'present';
    if v_present.id is null then
      raise exception 'send_main_ship_expedition: docked ship has no present fleet';
    end if;
    select lp.id as presence_id, lp.location_id, lp.zone_id, l.x, l.y
      into v_cur
      from location_presence lp join locations l on l.id = lp.location_id
      where lp.fleet_id = v_present.id and lp.status = 'active';
    if v_cur.location_id is null then
      raise exception 'send_main_ship_expedition: docked ship has no active presence';
    end if;
    if p_location = v_cur.location_id then
      raise exception 'send_main_ship_expedition: main ship is already at that location';
    end if;
    -- Send-TO-a-port docks at the destination (movement_settle_arrival, 0153); the recorded return port
    -- is otherwise-inert here but kept for symmetry/self-heal — chosen if given, else the docked origin.
    v_return := coalesce(p_return_location_id, v_cur.location_id);

    v_speed := resolve_fleet_movement_speed(v_present.id);
    v_movement := movement_create(
      v_player, v_present.id,
      'location', null, v_cur.zone_id, v_cur.location_id, v_cur.x, v_cur.y,
      'location', null, null, v_loc.id, v_loc.x, v_loc.y,
      'rally', v_speed);
    perform presence_complete(v_cur.presence_id);
    -- present→moving, guarded (the 0156 transition shape) + record the return port.
    update fleets
      set status = 'moving', location_mode = 'movement', active_movement_id = v_movement,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          return_location_id = v_return, updated_at = now()
      where id = v_present.id and active_movement_id is null and status = 'present';
    if not found then
      raise exception 'send_main_ship_expedition: docked ship % no longer present', v_ship_id;
    end if;
    -- Re-claim the ship UNDER a row lock on the docked pair (the 0169 M1 race-closure idiom, adapted to
    -- the docked launch state), then the ONE shared 0152 in-flight write.
    perform 1 from main_ship_instances
      where main_ship_id = v_ship_id and status = 'stationary' and spatial_state = 'at_location'
      for update;
    if not found then
      select * into v_ship from main_ship_instances where main_ship_id = v_ship_id;
      raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
    end if;
    perform public.mainship_mark_legacy_in_flight(v_ship_id, 'traveling');

    select arrive_at into v_arrive from fleet_movements where id = v_movement;
    return jsonb_build_object(
      'fleet_id', v_present.id, 'movement_id', v_movement,
      'main_ship_id', v_ship_id, 'arrive_at', v_arrive, 'return_location_id', v_return);
  end if;

  -- ── 0169 HEAD (DARK path — byte-identical to send_main_ship_expedition 0169:578-630) ────────────────
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
  -- immediately before the in-flight write.
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
-- ACL re-asserted after the DROP (authenticated client RPC — the 0050/0169 posture).
revoke execute on function public.send_main_ship_expedition(jsonb, uuid, uuid) from public, anon;
grant  execute on function public.send_main_ship_expedition(jsonb, uuid, uuid) to authenticated;

-- ── §4) send_ship_group_hunt — 0168 head VERBATIM (else-branches) + the marked NOHOME docked launch ───
-- New signature adds the trailing p_return_location_id (DEFAULT NULL). DROP+CREATE; ACL re-asserted below.
-- DARK path (v_launch_from_dock false) is the 0168 body verbatim: home-only readiness, base origin,
-- no return_location_id write. LIT path: docked members (all at ONE port) are ready, the ONE team fleet
-- departs from that port, and the chosen (or origin) return port is recorded on the fleet.
drop function if exists public.send_ship_group_hunt(uuid, uuid);
create function public.send_ship_group_hunt(p_group_id uuid, p_location uuid, p_return_location_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_group    uuid;
  v_members  uuid[];
  v_locked   integer;
  v_not_home integer;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_base     record;
  v_ship     uuid;
  v_stats    jsonb;
  v_ms       double precision;
  v_power    double precision;
  v_speed    double precision;
  v_fleet    uuid;
  v_movement uuid;
  v_arrive   timestamptz;
  -- NOHOME (0199): the gate + docked-launch working set. Dark seed → false → the 0168 head runs verbatim.
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
  v_docked   integer;   -- members currently docked (status='stationary'/spatial_state='at_location')
  v_dockcount integer;  -- distinct docked ports across the members (must be exactly 1)
  v_dock_loc uuid;      -- the ONE common docked port (all members) — the launch origin
  v_cur      record;    -- docked-port coordinates + zone/sector
  v_return   uuid;      -- chosen (or origin) return port recorded on the team fleet
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  if array_length(v_members, 1) is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, l.min_power_required, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' or v_loc.activity_type is distinct from 'hunt_pirates' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_location');
  end if;

  select count(*) into v_locked from (
    select main_ship_id from public.main_ship_instances
     where main_ship_id = any(v_members) and player_id = v_player
     for update
  ) locked;
  if v_locked <> array_length(v_members, 1) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- Readiness UNDER the locks. NOHOME (0199): the ONE marked readiness hunk. DARK — the 0168 check
  -- verbatim (EVERY member status='home' AND hp>0). LIT — a member is ready if home OR DOCKED
  -- (the settled-safe pair) AND hp>0; a docked team is checked for a common port in the launch branch.
  if v_launch_from_dock then
    select count(*) into v_not_home
      from public.main_ship_instances
      where main_ship_id = any(v_members)
        and (not (status = 'home' or (status = 'stationary' and spatial_state = 'at_location')) or hp <= 0);
  else
    select count(*) into v_not_home
      from public.main_ship_instances
      where main_ship_id = any(v_members) and (status <> 'home' or hp <= 0);
  end if;
  if v_not_home > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- ── NOHOME (0199) LAUNCH-FROM-DOCK BRANCH — the whole team launches as ONE fleet from its port ──────
  -- Triggers ONLY when the flag is lit AND at least one member is docked. A docked team must be gathered
  -- at ONE port (else member_not_ready — the same all-or-nothing posture the move-team gate uses, 0190).
  -- The members' own present fleets are dissolved (they leave to fly with the team); the ONE new team
  -- fleet departs from the common port; origin_base_id stays the legacy base so the escape tick's
  -- return-to-base mechanics (process_combat_ticks 0169:217-228 — UNTOUCHED) still work, and the chosen
  -- (or origin) return port is recorded so the reconciler docks the team there instead of re-homing.
  -- (N2) count docked members ONLY when lit — the DARK path never touches this (v_docked stays NULL and
  -- the short-circuit `v_launch_from_dock and …` below never evaluates it).
  if v_launch_from_dock then
    select count(*) into v_docked
      from public.main_ship_instances
      where main_ship_id = any(v_members) and status = 'stationary' and spatial_state = 'at_location';
  end if;

  if v_launch_from_dock and v_docked > 0 then
    -- EVERY member must be docked at ONE common port (a mixed home/docked team, or a split-port team,
    -- is not a coherent single-origin launch → member_not_ready).
    if v_docked <> array_length(v_members, 1) then
      return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
    end if;
    select count(distinct lp.location_id) into v_dockcount
      from public.main_ship_instances s
      join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
      where s.main_ship_id = any(v_members);
    if v_dockcount is distinct from 1 then
      return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
    end if;
    -- the ONE common port + its coordinates (distinct count proved a single location above).
    select lp.location_id, lp.zone_id, l.x, l.y, z.sector_id
      into v_cur
      from public.main_ship_instances s
      join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
      join public.locations l on l.id = lp.location_id
      join public.zones z on z.id = l.zone_id
      where s.main_ship_id = any(v_members)
      limit 1;
    v_dock_loc := v_cur.location_id;
    v_return   := coalesce(p_return_location_id, v_dock_loc);

    -- Active-fleet limit EXCLUDING the members' own present fleets (they are dissolved below; the team
    -- consumes ONE slot net — the 0168/0019 shared-budget idiom, adjusted for the dissolve).
    v_max := coalesce(cfg_num('max_active_fleets'), 3);
    select count(*) into v_active
      from fleets
      where player_id = v_player and status in ('moving','present','returning')
        and (main_ship_id is null or not (main_ship_id = any(v_members)));
    if v_active >= v_max then
      return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
    end if;

    -- Team stats over the LOCKED members (the 0168 fold verbatim; raises → stats_invalid envelope).
    v_power := 0;
    v_speed := null;
    begin
      foreach v_ship in array v_members loop
        v_stats := public.calculate_expedition_stats(v_player, v_ship, '[]'::jsonb, 'pirate_hunt');
        v_power := v_power + coalesce((v_stats->>'combat_power')::double precision, 0);
        v_ms    := (v_stats->>'speed')::double precision;
        v_speed := least(coalesce(v_speed, v_ms), v_ms);
      end loop;
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
    end;
    if v_power < coalesce(v_loc.min_power_required, 0) then
      return jsonb_build_object('ok', false, 'reason', 'power_below_required');
    end if;

    -- origin_base anchors the return-to-base mechanics (the escape tick reads origin_base_id).
    select id, x, y, sector_id into v_base
      from bases where player_id = v_player and status = 'active'
      order by created_at limit 1;
    if v_base.id is null then
      return jsonb_build_object('ok', false, 'reason', 'no_home_base');
    end if;

    -- ── WRITES (all-or-nothing) ─────────────────────────────────────────────────────────────────────
    -- Dissolve each docked member's OWN present fleet: close its active presence and complete the fleet
    -- (the ship leaves the dock to fly with the team). fleet_complete requires 'returning', so this is a
    -- direct completed-write (the dock had no movement).
    perform presence_complete(lp.id)
      from public.fleets f
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
      where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
    update public.fleets
      set status = 'completed', location_mode = 'movement', active_movement_id = null,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = now()
      where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

    -- ONE team fleet (main_ship_id NULL; members carried by the manifest) tagged with the group, origin
    -- the legacy base (return mechanics) + the recorded return port.
    insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id, return_location_id)
      values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group, v_return)
      returning id into v_fleet;

    -- Depart from the COMMON DOCKED PORT (origin_type='location', the port coordinates), mission
    -- 'hunt_pirates' — NOT from the (0,0) base.
    v_movement := movement_create(
      v_player, v_fleet,
      'location', null, v_cur.zone_id, v_dock_loc, v_cur.x, v_cur.y,
      'location', null, null, v_loc.id, v_loc.x, v_loc.y,
      'hunt_pirates', v_speed);
    perform fleet_set_moving(v_fleet, v_movement);

    update main_ship_instances
      set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
      where main_ship_id = any(v_members);

    insert into group_sortie_members (fleet_id, main_ship_id, player_id)
      select v_fleet, m, v_player from unnest(v_members) as m;

    select arrive_at into v_arrive from fleet_movements where id = v_movement;
    return jsonb_build_object(
      'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
      'arrive_at', v_arrive, 'member_count', array_length(v_members, 1), 'return_location_id', v_return);
  end if;

  -- ── 0168 HEAD (DARK path — byte-identical to send_ship_group_hunt 0168:226-312) ─────────────────────
  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
  end if;

  v_power := 0;
  v_speed := null;
  begin
    foreach v_ship in array v_members loop
      v_stats := public.calculate_expedition_stats(v_player, v_ship, '[]'::jsonb, 'pirate_hunt');
      v_power := v_power + coalesce((v_stats->>'combat_power')::double precision, 0);
      v_ms    := (v_stats->>'speed')::double precision;
      v_speed := least(coalesce(v_speed, v_ms), v_ms);
    end loop;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;

  if v_power < coalesce(v_loc.min_power_required, 0) then
    return jsonb_build_object('ok', false, 'reason', 'power_below_required');
  end if;

  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_home_base');
  end if;

  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
    returning id into v_fleet;

  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'hunt_pirates', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  update main_ship_instances
    set status = 'hunting', spatial_state = null, space_x = null, space_y = null, updated_at = now()
    where main_ship_id = any(v_members);

  insert into group_sortie_members (fleet_id, main_ship_id, player_id)
    select v_fleet, m, v_player from unnest(v_members) as m;

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
    'arrive_at', v_arrive, 'member_count', array_length(v_members, 1));
end;
$$;
-- ACL re-asserted after the DROP (authenticated; the in-body gate rejects while team_command dark — 0168).
revoke execute on function public.send_ship_group_hunt(uuid, uuid, uuid) from public, anon;
grant  execute on function public.send_ship_group_hunt(uuid, uuid, uuid) to authenticated;

-- ── §5) process_mainship_expeditions — 0198 head VERBATIM (else-branch) + NOHOME dock-at-return ────────
-- CREATE OR REPLACE (signature unchanged) preserves owner + service_role grant. The DARK path
-- (v_launch_from_dock false) is the 0198 body verbatim — the two set-based re-home UPDATEs + the SHIELD-2
-- idle-regen hunk. The LIT path re-homes NOTHING: it docks each returning/hunting ship at its fleet's
-- recorded return_location_id (the canonical pair via the 0153 helper) and re-presents the fleet at that
-- port so the roster reads it as docked; a ship with no recorded return port (a home-launched fleet, even
-- with the flag lit) falls back to the legacy re-home. The idle-regen hunk runs in BOTH paths (shared).
create or replace function public.process_mainship_expeditions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
  v_team  integer := 0;
  v_idle_raw double precision := coalesce(cfg_num('shield_regen_idle_pct'), 0);
  v_idle     double precision := greatest(0, case when v_idle_raw = 'NaN'::double precision then 0 else v_idle_raw end);
  -- NOHOME (0199): the gate, read once. Dark seed → false → the 0198 head runs verbatim.
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
  r          record;
begin
  if v_launch_from_dock then
    -- ── NOHOME (0199) DOCK-AT-RETURN reconcile — the SAME candidate sets as the 0198 head's two re-home
    --    branches, but each ship is DOCKED at its fleet's recorded return port (or re-homed if none). ──
    -- (1) main-ship fleets out (traveling/returning) with no live tagged fleet AND no live manifest fleet
    --     (the 0198 `homed` predicate + D3 member guard).
    for r in
      select s.main_ship_id
        from main_ship_instances s
        where s.status in ('traveling','returning')
          and not exists (
            select 1 from fleets f
            where f.main_ship_id = s.main_ship_id and f.status in ('moving','present','returning'))
          and not exists (
            select 1 from group_sortie_members gsm
            join fleets gf on gf.id = gsm.fleet_id
            where gsm.main_ship_id = s.main_ship_id and gf.status in ('moving','present','returning'))
    loop
      perform public.nohome_dock_returning_ship(r.main_ship_id);
      v_count := v_count + 1;
    end loop;

    -- (2) 'hunting' zombies whose manifest fleet is finished (the 0198 `team_homed` predicate).
    for r in
      select s.main_ship_id
        from main_ship_instances s
        where s.status = 'hunting'
          and not exists (
            select 1 from group_sortie_members gsm
            join fleets gf on gf.id = gsm.fleet_id
            where gsm.main_ship_id = s.main_ship_id and gf.status in ('moving','present','returning'))
    loop
      perform public.nohome_dock_returning_ship(r.main_ship_id);
      v_team := v_team + 1;
    end loop;
  else
    -- ── 0198 HEAD (DARK path — byte-identical to process_mainship_expeditions 0198:410-456) ───────────
    with homed as (
      update main_ship_instances s
        set status = 'home', updated_at = now()
        where s.status in ('traveling','returning')
          and not exists (
            select 1 from fleets f
            where f.main_ship_id = s.main_ship_id
              and f.status in ('moving','present','returning')
          )
          and not exists (
            select 1 from group_sortie_members gsm
            join fleets gf on gf.id = gsm.fleet_id
            where gsm.main_ship_id = s.main_ship_id
              and gf.status in ('moving','present','returning')
          )
        returning 1)
    select count(*) into v_count from homed;

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
  end if;

  -- ── SHIELD-2 (0197) HUNK — out-of-combat idle shield regen (runs in BOTH paths; flag 0 → skipped). ──
  if v_idle > 0 then
    update main_ship_instances s
      set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer),
          updated_at = now()
      where s.shield < s.max_shield
        and s.status <> 'destroyed'
        and not exists (
          select 1 from combat_units cu
          join combat_encounters ce on ce.id = cu.encounter_id
          where cu.main_ship_id = s.main_ship_id
            and ce.status in ('active','retreating')
        );
  end if;

  return v_count + v_team;
end;
$$;

-- ── NOHOME (0199) leaf: dock a returning ship at its fleet's recorded return port, else re-home ────────
-- Internal, service_role/definer only (called by process_mainship_expeditions on the lit path). Reads the
-- recorded return port from the ship's own main_ship_id-tagged fleet OR (for a hunt member) the shared
-- manifest fleet, then gives THE SHIP ITS OWN main_ship_id-tagged present fleet at that port (+ one active
-- presence) and docks it via the 0153 helper. A ship with no recorded/valid return port re-homes (legacy).
--
-- H1 (review): a team hunt dissolves the members' INDIVIDUAL docked fleets and flies them as ONE untagged
-- team fleet (main_ship_id NULL). If the reconciler merely re-presented that ONE shared fleet, N members
-- would share ONE main_ship_id-NULL fleet + ONE presence — and every re-launch path (send / move / re-hunt)
-- keys on a PER-SHIP main_ship_id-tagged present fleet, so the team would read "docked" but be permanently
-- wedged. So we SPLIT the return back to per-member tagged present fleets here: reuse the ship's OWN tagged
-- fleet (the member's now-dissolved docked fleet, or a single-send's tagged fleet) if it has one, else mint
-- a fresh tagged present fleet — mirroring the docked shape a single ship keeps. Each returned member then
-- owns a per-ship handle again and can launch/move/re-hunt.
create or replace function public.nohome_dock_returning_ship(p_main_ship_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid;
  v_return   uuid;
  v_fleet    uuid;   -- the ship's OWN main_ship_id-tagged fleet that will host its docked presence
  v_loc      record;
begin
  -- Return port + owner: the ship's own tagged fleet first (a single expedition), then its manifest (a
  -- team hunt member — the SHARED team fleet carries the recorded port, never the member's own fleet).
  select f.player_id, f.return_location_id into v_player, v_return
    from fleets f
    where f.main_ship_id = p_main_ship_id and f.return_location_id is not null
    order by f.updated_at desc limit 1;
  if v_return is null then
    select gf.player_id, gf.return_location_id into v_player, v_return
      from group_sortie_members gsm
      join fleets gf on gf.id = gsm.fleet_id
      where gsm.main_ship_id = p_main_ship_id and gf.return_location_id is not null
      order by gf.updated_at desc limit 1;
  end if;

  -- No recorded return port → legacy re-home (the 0198 head write shape: status only).
  if v_return is null then
    update main_ship_instances set status = 'home', updated_at = now() where main_ship_id = p_main_ship_id;
    return;
  end if;
  if v_player is null then
    select player_id into v_player from main_ship_instances where main_ship_id = p_main_ship_id;
  end if;

  -- Return port must still be an active location; else fail safe to re-home.
  select l.id, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = v_return and l.status = 'active';
  if v_loc.id is null then
    update main_ship_instances set status = 'home', updated_at = now() where main_ship_id = p_main_ship_id;
    return;
  end if;

  -- H1: give the ship its OWN main_ship_id-tagged present fleet at the return port. Reuse one already
  -- present there (idempotent), else the ship's most-recent tagged fleet (the member's dissolved docked
  -- fleet, or a single-send tagged fleet), else mint a fresh tagged present fleet.
  select id into v_fleet from fleets
    where main_ship_id = p_main_ship_id and player_id = v_player
      and status = 'present' and current_location_id = v_loc.id
    limit 1;
  if v_fleet is null then
    select id into v_fleet from fleets
      where main_ship_id = p_main_ship_id and player_id = v_player
      order by updated_at desc limit 1;
  end if;
  if v_fleet is null then
    insert into fleets (player_id, status, location_mode, current_base_id,
                        current_location_id, current_zone_id, current_sector_id, main_ship_id)
      values (v_player, 'present', 'location', null, v_loc.id, v_loc.zone_id, v_loc.sector_id, p_main_ship_id)
      returning id into v_fleet;
  else
    update fleets
      set status = 'present', location_mode = 'location', active_movement_id = null, current_base_id = null,
          current_location_id = v_loc.id, current_zone_id = v_loc.zone_id, current_sector_id = v_loc.sector_id,
          return_location_id = null, updated_at = now()
      where id = v_fleet;
  end if;
  -- exactly one active presence for THIS ship's own fleet (each returned member gets its own).
  if not exists (select 1 from location_presence where fleet_id = v_fleet and status = 'active') then
    perform public.presence_create(v_player, v_fleet, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'none');
  end if;

  -- Ship → canonical docked pair (the ONE shared 0153 helper).
  perform public.mainship_mark_docked_at_location(p_main_ship_id);
end;
$$;
revoke execute on function public.nohome_dock_returning_ship(uuid) from public, anon, authenticated;
grant  execute on function public.nohome_dock_returning_ship(uuid) to service_role;

-- ── §6) repair_main_ship — 0081 head VERBATIM (else-branch) + NOHOME dock-in-place ────────────────────
-- CREATE OR REPLACE (signature unchanged: (uuid)) preserves the 0081 authenticated grant. DARK path
-- (v_launch_from_dock false) is byte-identical to 0081:96-102 (restore to full readiness, status='home').
-- LIT path: recovery still always works (the safelock guarantee), but the revived ship comes back DOCKED
-- (status='stationary'/spatial_state='at_location') rather than home — under the NO-HOME law there is no
-- home to return to. Kept SIMPLE (documented): the docked pair only; the ship reads as docked/launch-ready
-- and the owner can move/launch it from wherever it is (a destroyed ship carries no meaningful port).
create or replace function public.repair_main_ship(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   main_ship_instances%rowtype;
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
begin
  if v_player is null then
    raise exception 'repair_main_ship: not authenticated';
  end if;

  select * into v_ship from main_ship_instances
    where main_ship_id = public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship.main_ship_id is null then
    raise exception 'repair_main_ship: no main ship found';
  end if;
  if v_ship.status <> 'destroyed' then
    raise exception 'repair_main_ship: ship is not disabled (status %) — nothing to repair', v_ship.status;
  end if;
  if v_ship.max_hp is null or v_ship.max_hp <= 0 then
    raise exception 'repair_main_ship: invalid max_hp (%)', v_ship.max_hp;
  end if;

  if v_launch_from_dock then
    -- NOHOME: revive DOCKED (no home under the owner's law). Simple pair write; no fleet/presence created.
    update main_ship_instances
      set hp = v_ship.max_hp, status = 'stationary', spatial_state = 'at_location',
          space_x = null, space_y = null, updated_at = now()
      where main_ship_id = v_ship.main_ship_id;
    return jsonb_build_object(
      'main_ship_id', v_ship.main_ship_id, 'status', 'stationary',
      'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
  end if;

  -- 0081 HEAD (DARK path — byte-identical): restore to full readiness, back home.
  update main_ship_instances
    set hp = v_ship.max_hp, status = 'home', updated_at = now()
    where main_ship_id = v_ship.main_ship_id;

  return jsonb_build_object(
    'main_ship_id', v_ship.main_ship_id, 'status', 'home',
    'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
end;
$$;
-- The signature is unchanged so CREATE OR REPLACE kept the 0081 ACL; re-assert for explicitness (recovery
-- is NEVER flag-gated — the safelock guarantee, carried from 0052/0081).
revoke execute on function public.repair_main_ship(uuid) from public, anon;
grant  execute on function public.repair_main_ship(uuid) to authenticated;

-- ── §7) SELF-ASSERTS — the flag seed is dark, the column exists, and the DARK paths are the head verbatim
do $nohome$
declare
  v_src text;
begin
  -- (a) the flag seed is committed DARK (false) — this migration never lights it.
  if coalesce((select value #>> '{}' from public.game_config where key = 'launch_from_dock_enabled'), 'false') <> 'false' then
    raise exception 'NOHOME self-assert FAIL: launch_from_dock_enabled is not seeded false';
  end if;

  -- (b) the additive column exists and is nullable.
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'fleets' and column_name = 'return_location_id'
      and is_nullable = 'YES') then
    raise exception 'NOHOME self-assert FAIL: fleets.return_location_id missing or not nullable';
  end if;

  -- (c) send_main_ship_expedition — new 3-arg signature, gate read, DARK-head tokens present, no random().
  select prosrc into v_src from pg_proc where oid = 'public.send_main_ship_expedition(jsonb, uuid, uuid)'::regprocedure;
  if v_src is null then raise exception 'NOHOME self-assert FAIL: send_main_ship_expedition(jsonb,uuid,uuid) not deployed'; end if;
  -- exactly ONE definition survives the DROP+CREATE (no lingering 2-arg overload):
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'send_main_ship_expedition') <> 1 then
    raise exception 'NOHOME self-assert FAIL: send_main_ship_expedition is not a single definition'; end if;
  if position('v_launch_from_dock boolean := public.cfg_bool(''launch_from_dock_enabled'')' in v_src) = 0 then
    raise exception 'NOHOME self-assert FAIL: send_main_ship_expedition lacks the flag read'; end if;
  -- DARK-head tokens (the 0169 tail survives verbatim in the else-branch):
  if position('send_main_ship_expedition: active fleet limit reached' in v_src) = 0
     or position('send_main_ship_expedition: no active home base' in v_src) = 0
     or position('insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)' in v_src) = 0 then
    raise exception 'NOHOME self-assert FAIL: the 0169 DARK head tokens vanished from send_main_ship_expedition'; end if;
  if position('random(' in v_src) > 0 then raise exception 'NOHOME self-assert FAIL: send_main_ship_expedition contains random()'; end if;

  -- (d) send_ship_group_hunt — new 3-arg signature, gate read, DARK-head tokens present, no random().
  select prosrc into v_src from pg_proc where oid = 'public.send_ship_group_hunt(uuid, uuid, uuid)'::regprocedure;
  if v_src is null then raise exception 'NOHOME self-assert FAIL: send_ship_group_hunt(uuid,uuid,uuid) not deployed'; end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'send_ship_group_hunt') <> 1 then
    raise exception 'NOHOME self-assert FAIL: send_ship_group_hunt is not a single definition'; end if;
  if position('v_launch_from_dock boolean := public.cfg_bool(''launch_from_dock_enabled'')' in v_src) = 0 then
    raise exception 'NOHOME self-assert FAIL: send_ship_group_hunt lacks the flag read'; end if;
  if position('and (status <> ''home'' or hp <= 0)' in v_src) = 0
     or position('insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)' in v_src) = 0 then
    raise exception 'NOHOME self-assert FAIL: the 0168 DARK head tokens vanished from send_ship_group_hunt'; end if;
  if position('random(' in v_src) > 0 then raise exception 'NOHOME self-assert FAIL: send_ship_group_hunt contains random()'; end if;

  -- (e) process_mainship_expeditions — gate read + BOTH DARK-head re-home CTEs survive verbatim in the else.
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_mainship_expeditions';
  if v_src is null then raise exception 'NOHOME self-assert FAIL: process_mainship_expeditions not deployed'; end if;
  if position('v_launch_from_dock boolean := public.cfg_bool(''launch_from_dock_enabled'')' in v_src) = 0 then
    raise exception 'NOHOME self-assert FAIL: process_mainship_expeditions lacks the flag read'; end if;
  if position('with homed as (' in v_src) = 0 or position('with team_homed as (' in v_src) = 0
     or position('return v_count + v_team;' in v_src) = 0 then
    raise exception 'NOHOME self-assert FAIL: the 0198 DARK re-home CTEs / return vanished'; end if;
  if position('nohome_dock_returning_ship' in v_src) = 0 then
    raise exception 'NOHOME self-assert FAIL: process_mainship_expeditions lacks the lit dock-at-return leaf call'; end if;
  -- the SHIELD-2 idle hunk survives (accumulated-hunk law):
  if position('set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer)' in v_src) = 0 then
    raise exception 'NOHOME self-assert FAIL: the SHIELD-2 idle-regen hunk vanished'; end if;

  -- (f) repair_main_ship — gate read + DARK-head home write survives; still authenticated (recovery).
  select prosrc into v_src from pg_proc where oid = 'public.repair_main_ship(uuid)'::regprocedure;
  if position('set hp = v_ship.max_hp, status = ''home'', updated_at = now()' in v_src) = 0 then
    raise exception 'NOHOME self-assert FAIL: repair_main_ship lost the 0081 DARK home restore'; end if;
  if not has_function_privilege('authenticated', 'public.repair_main_ship(uuid)', 'execute') then
    raise exception 'NOHOME self-assert FAIL: repair_main_ship not authenticated-executable (safelock broken)'; end if;

  raise notice 'NOHOME self-assert ok: flag seeded dark; fleets.return_location_id additive; send/hunt widened to 3-arg with the flag gate and the 0169/0168 DARK heads verbatim; the reconciler carries both 0198 re-home CTEs (dark) + the lit dock-at-return leaf + the SHIELD-2 hunk; repair keeps its dark home restore and authenticated ACL';
end $nohome$;
