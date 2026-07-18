-- 0219 — S4 TIMED DOCKING (charter §2; serializes behind S3's 0218 leaves + S2's 0217 territory).
--
-- TRUE-HEAD DECLARATION: this file re-creates command_ship_group_go and is now the MOVER's TRUE
-- HEAD. The 0218 mover body is superseded — edit and copy the mover from HERE (the 0211 lesson: a
-- guard pointed at a superseded head guards nothing; scripts/fleetgo-proof.sh's MIGRATION_S4 aims
-- the mover-body pins here now). The 0218 BRAKE body (command_ship_group_stop) is NOT re-created
-- and 0218 remains the brake's true head.
--
-- THE MODEL (one line): go-to-a-DOCKABLE-port becomes go-to-its-COORDINATE — the fleet parks in
-- orbit inside the port's territory (0217 radius, 0218 fleet_in_territory) — and DOCK becomes a
-- separate verb, command_ship_group_dock, minting a NORMAL fleet_movements leg with
-- mission_type='dock' and a flat 45-second clock. The arrival settles through the BYTE-UNTOUCHED
-- movement_settle_arrival location branch (0208:112-141): present + presence + (main-ship fleets
-- only) docked. There is NO new table, NO new timer, NO new cron, NO new settle — the clock IS
-- arrive_at and the settle IS process_fleet_movements, exactly like every other leg.
--
-- DARK behind `timed_docking_enabled` (seeded false below). fleet_movement_unified_enabled is TRUE
-- in prod, so "dark" here means: the mover's ONE marked hunk is skipped (byte-identical instant
-- dock via the 0208 location branch) and the dock RPC rejects before ANY read. The CHECK widening
-- is unreachable while dark — the dock RPC is the ONLY 'dock' writer and it lands in this SAME
-- migration as the widen.
--
-- ONE AUTHORITY PER CONCEPT (the spaghetti verdict this slice is built on):
--   • dockability   — mainship_space_location_target_legal (0067), the SAME predicate the settle's
--                     dock hunk uses. The mover's translate hunk and the dock RPC both compose it;
--                     no second dockability rule exists anywhere.
--   • position      — fleet_current_position / movement_position_at (0218), composed via
--                     fleet_in_territory. No new position or distance formula.
--   • territory     — fleet_in_territory (0218), the ONE containment test (osn_distance + 0217).
--   • the clock     — fleet_movements.arrive_at, settled by the existing 30s cron. The 0149:116-134
--                     transform idiom (mint via movement_create, then overwrite arrive_at/
--                     travel_seconds under the same txn's now()) pins the EXACT flat 45s. This is
--                     the slice's one acknowledged soft spot — smaller than widening the 16-arg
--                     movement_create — kept, marked, and pinned exact-45 by the self-assert + CI.
--
-- DELIBERATELY UNTOUCHED (every dock consumer keeps answering through the same settled state):
-- get_my_current_dock_services / get_my_docked_store / commission_first_main_ship (0211),
-- get_my_fleet_positions (0216 head), mainship_resolve_docked_location / mainship_resolve_fleet /
-- mainship_space_validate_context (0210), the trade RPCs, the berth writers (0216), and
-- movement_settle_arrival itself (which never reads mission_type — pinned below). This file
-- re-creates NONE of them; CI pins that statically.
--
-- FOLDED IN (the S3-review LOW note): a CHECK on locations.territory_radius — NULL or > 0 — so a
-- future zero-radius row can never open the client/server containment divergence S3 recorded (the
-- client territoryAt skips radius <= 0; the server leaf only filtered NULL). The seeded map
-- (25/35/15/NULL, 0217) satisfies it as-is.
--
-- teamStop / the brake: NO change. classifySortieLeg('dock') = null, so a docking fleet still shows
-- Stop — the brake cancels the dock leg and parks the fleet at the interpolated point inside the
-- territory, immediately re-dockable. That is the intended undo, not a gap.

-- ── 0. dependency gate: S4 serializes behind S3 (0218), 0213's leaf, and 0067's legality rule ────
do $s4dep$
begin
  if to_regprocedure('public.fleet_in_territory(uuid, timestamptz)') is null then
    raise exception 'S4 TIMEDOCK: public.fleet_in_territory (S3/0218) is missing — S4 serializes behind S3';
  end if;
  if to_regprocedure('public.ship_group_resolve_fleet(uuid, uuid)') is null then
    raise exception 'S4 TIMEDOCK: public.ship_group_resolve_fleet (0213) is missing — the dock verb composes the ONE fleet-shape leaf';
  end if;
  if to_regprocedure('public.mainship_space_location_target_legal(uuid)') is null then
    raise exception 'S4 TIMEDOCK: public.mainship_space_location_target_legal (0067) is missing — the ONE dockability rule';
  end if;
  if to_regprocedure('public.movement_position_at(double precision, double precision, double precision, double precision, timestamptz, timestamptz, timestamptz)') is null then
    raise exception 'S4 TIMEDOCK: public.movement_position_at (S3/0218) is missing — the mover parity copy composes it';
  end if;
end $s4dep$;

-- ── 1. fleet_movements.mission_type gains 'dock' (the ONLY schema change to the spine) ───────────
-- The CHECK lives ONLY at 20260616000007:28-31 (never re-created since); widened with the 0208:56-58
-- target_type idiom. The widen and the only 'dock' writer (the dock RPC below) land in this SAME
-- migration, so there is never a chain state where a 'dock' row could exist unwritable or a writer
-- could mint an illegal row.
alter table public.fleet_movements drop constraint if exists fleet_movements_mission_type_check;
alter table public.fleet_movements add constraint fleet_movements_mission_type_check
  check (mission_type in (
    'hunt_pirates','return_home','scout','reinforce',
    'mine','explore','trade','rally','dock'));

-- ── 2. the S3-review LOW fold: territory_radius is NULL or strictly positive ─────────────────────
-- Client territoryAt skips non-positive radii; the server leaf (0218) only filters NULL. A future
-- zero-radius seed row would make the two disagree on containment. Close the divergence at the
-- schema: such a row can now never exist. The current seed (25/35/15/NULL) satisfies this as-is.
alter table public.locations drop constraint if exists locations_territory_radius_positive;
alter table public.locations add constraint locations_territory_radius_positive
  check (territory_radius is null or territory_radius > 0);

-- ── 3. the dark gate + the flat clock (0207:50-58 idiom) ─────────────────────────────────────────
insert into public.game_config (key, value, description)
values
  (
    'timed_docking_enabled',
    'false'::jsonb,
    'S4 TIMED DOCKING: go-to-a-dockable-port is translated to its coordinate (the fleet parks in '
    'orbit inside the territory) and DOCK becomes command_ship_group_dock — a normal 45s '
    'fleet_movements leg settled by the untouched movement_settle_arrival. DARK. While false the '
    'mover hunk is skipped and docking is the instant 0208 location arrival, byte-identical.'
  ),
  (
    'docking_seconds',
    '45'::jsonb,
    'S4 TIMED DOCKING: the flat dock clock in seconds — the dock leg''s arrive_at is now() + this. '
    'Read by command_ship_group_dock via cfg_num; defaults to 45 when absent.'
  )
on conflict (key) do nothing;

-- ── 4. the DOCK verb: command_ship_group_dock — proven blocks composed in the brake's order ──────
-- Every block is a byte-reuse of a proven sibling: the auth+gate posture (0208:232-239, plus the S4
-- flag FIRST), the group resolve+lock (0208:270-277), the sortie guard VERBATIM (0208:335-343 /
-- 0215:104-112 — placed BEFORE the fleet-state inspection, the brake's order, so a mid-combat
-- sortie answers group_on_sortie and never a misleading not_parked), the 0213 leaf with the 0214
-- one-scan count+capture idiom, the mover's speed fold (0208:465-478), the mover's re-launch
-- release writes (0218's else-branch), movement_create, and the 0149 transform idiom for the flat
-- clock. NO ship write anywhere below — §2 holds through the dock, for free.
create or replace function public.command_ship_group_dock(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_player    uuid := auth.uid();
  v_group     uuid;
  v_gf        public.fleets%rowtype;
  v_gf_n      integer;
  v_hunting   integer;
  v_fleet     uuid;
  v_fleet_row record;
  v_port      uuid;
  v_loc       record;
  v_stats     jsonb;
  v_speed     double precision;
  v_o_x       double precision;
  v_o_y       double precision;
  v_movement  uuid;
  v_secs      double precision;
  v_arrive    timestamptz;
  v_now       timestamptz := now();
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gates — reject before ANY read, lock, or write (the 0161/0178 reject-before-read
  --    posture): the S4 flag FIRST, then the unification gate the whole fleet layer lives behind.
  if not public.cfg_bool('timed_docking_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'timed_docking_disabled');
  end if;
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) resolve + LOCK the group (0208:270-277 verbatim): FOR UPDATE, the same first lock every
  --    group RPC takes, so a dock serializes against a concurrent go/stop/hunt on the same group.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- 4) the group must not be mid-sortie — the mover/brake guard VERBATIM (0208:335-343 /
  --    0215:104-112). LIVE-scoped join, NEVER a bare EXISTS: a retained dead manifest (0047/0169,
  --    up to 14d) must not block docking after a finished hunt. Ordered BEFORE the fleet-state
  --    inspection (the brake's order): a hunt's sortie fleet sits 'present' AT ITS SITE mid-combat
  --    and must be refused AS a sortie, never waved into the parked-guard arm below.
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');
  if v_hunting > 0 then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;

  -- 5) the group's ONE live fleet through the 0213 leaf (composed, never a fifth inline copy of
  --    the shape) — the 0214 one-scan count+capture idiom (one READ COMMITTED snapshot; never
  --    count in one statement and re-select in another). Then re-take the row FOR UPDATE by id.
  v_gf_n := 0;
  for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_group) loop
    v_gf_n := v_gf_n + 1;
  end loop;
  if v_gf_n > 1 then
    -- Two live group-shaped fleets is the broken invariant — never pick one (the mover's token).
    return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
  end if;
  if v_gf_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_fleet');
  end if;
  select * into v_fleet_row from public.fleets where id = v_gf.id for update;
  v_fleet := v_fleet_row.id;

  -- 6) PARKED guard — dock is FROM ORBIT only: the fleet must be holding in open space at its own
  --    coordinate (the exact state the translated go's settle leaves it in, and the brake's HOLD
  --    state). Everything else — docked already, in flight, at a base — is not_parked. Judged on
  --    the POST-LOCK row, so a settle/go racing this call cannot slip a stale state through.
  if not (v_fleet_row.status = 'idle'
          and v_fleet_row.location_mode = 'space'
          and v_fleet_row.space_x is not null and v_fleet_row.space_y is not null
          and v_fleet_row.active_movement_id is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_parked');
  end if;

  -- 7) TERRITORY guard — the S3 leaf IS the authority (fleet_current_position + osn_distance +
  --    territory_radius; smallest-radius/lowest-id tiebreak). NULL = open space = nothing to dock
  --    at. The 0104/0172 definer-composition precedent: the leaf is service_role-only and this
  --    SECURITY DEFINER body composes it with the definer's rights.
  v_port := public.fleet_in_territory(v_fleet);
  if v_port is null then
    return jsonb_build_object('ok', false, 'reason', 'not_in_territory');
  end if;

  -- 8) DOCKABLE guard — the SAME predicate the settle's dock hunk uses (0067's ONE legality rule:
  --    active hierarchy + city|port role + activity 'none' + one active docking service + one
  --    active in-bounds anchor). Composed, never re-derived — a port this refuses is exactly a
  --    port the settle would refuse to dock a main ship at.
  if (public.mainship_space_location_target_legal(v_port)->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', 'not_dockable');
  end if;
  select l.id, l.x, l.y, l.zone_id into v_loc from public.locations l where l.id = v_port;

  -- 9) SPEED — the mover's fold VERBATIM (0208:465-478): D0's strict group stats; raises →
  --    stats_invalid; the folds nest under 'totals'. Kept for the movement_create contract
  --    (speed_used > 0) even though the transform below overwrites the derived clock.
  begin
    v_stats := public.calculate_group_expedition_stats(v_player, v_group, 'none');
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;
  v_speed := (v_stats->'totals'->>'speed')::double precision;
  if v_speed is null or not (v_speed > 0) then
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end if;

  -- ── WRITES ─────────────────────────────────────────────────────────────────────────────────────
  -- NOTE FOR EVERY FUTURE READER: there is deliberately NO `update main_ship_instances` below.
  -- That absence is the charter's §2 — the settle's own dock hunk writes the ship, not this verb.

  -- Capture the origin FIRST (the release below clears it), then the mover's re-launch release
  -- VERBATIM (0218's else-branch): close any active presence (a no-op for a space-parked fleet —
  -- kept for shape parity with the mover), release the fleet into the idle/movement shape
  -- fleet_set_moving demands, and clear the parked coordinate — the fleet is under way.
  v_o_x := v_fleet_row.space_x; v_o_y := v_fleet_row.space_y;
  perform public.presence_complete(lp.id)
    from public.location_presence lp
   where lp.fleet_id = v_fleet and lp.status = 'active';
  update public.fleets
     set status = 'idle', location_mode = 'movement', active_movement_id = null,
         space_x = null, space_y = null,
         current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = v_now
   where id = v_fleet;

  -- ONE movement for the ONE fleet: a NORMAL location-target leg, mission 'dock' — the settle's
  -- untouched location branch (0208:112-141) is what docks it on arrival.
  v_movement := public.movement_create(
    v_player, v_fleet,
    'space', null, null, null, v_o_x, v_o_y,
    'location', null, v_loc.zone_id, v_port, v_loc.x, v_loc.y,
    'dock', v_speed);

  -- ★ THE FLAT CLOCK — the 0149:116-134 transform idiom (mint, then overwrite the SAME row's clock
  -- under this txn's constant now()): arrive_at − depart_at = EXACTLY v_secs, because
  -- movement_create's depart_at is the same txn-constant now() as v_now. The one marked soft spot
  -- of this slice (kept over widening the 16-arg movement_create); the self-assert + CI pin the
  -- exact 45. The `status = 'moving'` guard mirrors 0149: if anything settled the row between the
  -- mint and here (impossible in one txn — kept for the idiom's shape), this touches nothing. ★
  v_secs := coalesce(public.cfg_num('docking_seconds'), 45);
  update public.fleet_movements
     set arrive_at = v_now + make_interval(secs => v_secs),
         travel_seconds = v_secs
   where id = v_movement and status = 'moving';

  perform public.fleet_set_moving(v_fleet, v_movement);

  select arrive_at into v_arrive from public.fleet_movements where id = v_movement;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'fleet_id', v_fleet,
    'movement_id', v_movement,
    'port_id', v_port,
    'arrive_at', v_arrive);
end;
$function$;

comment on function public.command_ship_group_dock(uuid) is
  'S4 TIMED DOCKING: the DOCK verb. From a fleet PARKED in open space inside a dockable port''s '
  'territory (fleet_in_territory, S3) it mints a normal fleet_movements leg mission_type=''dock'' '
  'with a flat 45s clock (docking_seconds); the arrival settles through the untouched '
  'movement_settle_arrival location branch — present + presence + docked. Dockability is '
  'mainship_space_location_target_legal, the settle''s own rule. Writes NO ship state. DARK behind '
  'timed_docking_enabled.';

revoke all on function public.command_ship_group_dock(uuid) from public;
grant execute on function public.command_ship_group_dock(uuid) to authenticated;

-- ── 5. PARITY re-create: command_ship_group_go — the 0218 mover head, ONE marked hunk ────────────
-- Byte-copied from 0218 (the S3 fold body — NEVER from 0208: copying 0208 would resurrect the
-- inline lerp S3 deleted, the 0136 stale-head class). The ONE delta is the marked TRANSLATE hunk
-- inside the location branch: under timed_docking_enabled, a DOCKABLE target's leg becomes a
-- 'space' leg to the port's coordinate (v_t_x/v_t_y already carry it) — the fleet parks in orbit
-- and the DOCK verb above finishes the job. Dark → the hunk's if is skipped → byte-identical
-- instant dock. Non-dockable 'none' targets are NEVER translated: their settle presence keeps
-- feeding every reader that consumes it. The in-body fleet_movement_unified_enabled gate survives
-- untouched. Comment-on-function and grants re-emitted from the head (plus one added sentence).
create or replace function public.command_ship_group_go(
  p_group_id    uuid,
  p_location_id uuid default null,
  p_target_x    double precision default null,
  p_target_y    double precision default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_player     uuid := auth.uid();
  v_group      uuid;
  v_members    uuid[];
  v_member_n   integer;
  v_loc        record;
  v_fleet      uuid;
  v_fleet_row  record;
  v_unified_n  integer;
  v_busy       integer;
  v_hunting    integer;
  v_mv         record;
  v_old_mv     uuid;
  v_o_type     text;
  v_o_base     uuid;
  v_o_zone     uuid;
  v_o_loc      uuid;
  v_o_x        double precision;
  v_o_y        double precision;
  v_t_type     text;
  v_t_loc      uuid;
  v_t_x        double precision;
  v_t_y        double precision;
  v_stats      jsonb;
  v_speed      double precision;
  v_movement   uuid;
  v_arrive     timestamptz;
  v_redirected boolean := false;
  v_max        integer;
  v_active     integer;
  v_base       record;
  v_dock_n     integer;
  v_dock       record;
  v_now        timestamptz := now();
  -- The navigable square. COPIED from mainship_space_begin_move_core (0067:133-134) so a fleet and a
  -- ship agree on the world's edges; it is NOT a second authority. Step 4 retires 0067 — fold these
  -- into one shared bound then rather than leaving two copies.
  c_lo constant double precision := -10000;
  c_hi constant double precision :=  10000;
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gate — reject before ANY read, lock, or write (the 0161/0178 reject-before-read posture).
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) TARGET SHAPE — exactly one of {port} or {coordinate}. Validated BEFORE any read, so a
  --    malformed command never costs a lock (and never leaks whether a group exists).
  --    The 0067 rule, reused: client coordinates are NEVER accepted alongside a location target —
  --    a port's position is the server's to know, not the caller's to assert.
  if p_location_id is not null then
    if p_target_x is not null or p_target_y is not null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
    end if;
    v_t_type := 'location';
  elsif p_target_x is not null and p_target_y is not null then
    v_t_type := 'space';
    if p_target_x = 'NaN'::double precision or p_target_x = 'Infinity'::double precision or p_target_x = '-Infinity'::double precision
       or p_target_y = 'NaN'::double precision or p_target_y = 'Infinity'::double precision or p_target_y = '-Infinity'::double precision then
      return jsonb_build_object('ok', false, 'reason', 'invalid_coordinate');
    end if;
    if p_target_x < c_lo or p_target_x > c_hi or p_target_y < c_lo or p_target_y > c_hi then
      return jsonb_build_object('ok', false, 'reason', 'target_out_of_bounds');
    end if;
    -- canonicalize to the integer world grid (the 0178 rule) BEFORE anything reads it.
    v_t_x := round(p_target_x::numeric)::double precision;
    v_t_y := round(p_target_y::numeric)::double precision;
  else
    -- neither, or a half-specified coordinate.
    return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
  end if;

  -- 4) resolve + LOCK the group. FOR UPDATE (not FOR SHARE): two concurrent go's on the SAME group
  --    must serialize, or both could create a fleet / both redirect. This is the first lock taken;
  --    every other group RPC also takes ship_groups first, so the order is consistent.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- 5) members. Read-only: the members are the fleet's manifest, never movement subjects.
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  v_member_n := coalesce(array_length(v_members, 1), 0);
  if v_member_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- 6) destination: a port must exist, be active, and be NON-COMBAT.
  --    The activity_type check is the SAME rule the legacy per-ship move enforces (0156: active +
  --    non-combat) — composed, not invented. It is a TARGET-legality check, not a readiness branch (§4):
  --    it asks what the destination IS, never where the fleet is.
  --    WHY IT IS LOAD-BEARING: the settle creates a presence carrying the target's activity_type
  --    (0153/this file's location branch), and an activity='hunt_pirates' presence is what
  --    combat_create_encounter routes on. A unified fleet has NO combat_units — it is not a sortie, it
  --    has no group_sortie_members manifest — so it would snapshot zero units and the tick's defeat
  --    branch would DESTROY it on arrival. A move is not a hunt: hunts go through
  --    send_ship_group_hunt (0168/0204), which builds the manifest. Found by the step-3c/4 recon; the
  --    3a/3b proofs never flew to a hunt site so they never saw it.
  if v_t_type = 'location' then
    select l.id, l.x, l.y, l.status, l.zone_id, l.activity_type, z.sector_id
      into v_loc
      from public.locations l
      join public.zones z on z.id = l.zone_id
     where l.id = p_location_id;
    if v_loc.id is null or v_loc.status <> 'active' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_location');
    end if;
    if v_loc.activity_type is distinct from 'none' then
      return jsonb_build_object('ok', false, 'reason', 'combat_destination');
    end if;
    v_t_loc := v_loc.id; v_t_x := v_loc.x; v_t_y := v_loc.y;
    -- ── ★ THE S4 TRANSLATE HUNK (the ONLY delta vs the 0218 mover head) — TIMED DOCKING:  ★ ──
    -- ── ★ a DOCKABLE port target becomes its COORDINATE. The fleet parks in orbit inside  ★ ──
    -- ── ★ the port's territory (0217/0218) and DOCK is the separate 45s verb              ★ ──
    -- ── ★ (command_ship_group_dock, this file). Dockability is the settle's OWN rule      ★ ──
    -- ── ★ (mainship_space_location_target_legal) — never a second predicate. Dark → this  ★ ──
    -- ── ★ if is skipped → byte-identical instant dock. Non-dockable 'none' targets are    ★ ──
    -- ── ★ NEVER translated: their settle presence keeps feeding every reader.             ★ ──
    if public.cfg_bool('timed_docking_enabled')
       and (public.mainship_space_location_target_legal(v_loc.id)->>'ok')::boolean is true then
      v_t_type := 'space'; v_t_loc := null;   -- v_t_x/v_t_y already carry the port's coordinate
    end if;
    -- ── ★ END OF THE S4 TRANSLATE HUNK — the 0218 head continues verbatim from here ★ ─────────
  end if;

  -- 7) TRANSITION GUARD (delete me at step 4, not before).
  --    While the per-ship movers still exist and are flag-ON, a member could be flying its OWN
  --    per-ship fleet. If the group also flew, that ship would be in two places at once — the exact
  --    duality §2 kills. So: no member may hold a live per-ship fleet.
  --    This is NOT the "per-command readiness branch" §4 forbids: it does not gate on where the
  --    fleet IS (there is deliberately no home/docked precondition below). It rejects a state that
  --    only exists because the OLD layer is still alive, and it becomes unreachable — and must be
  --    removed — the moment step 4 retires the per-ship movers.
  select count(*) into v_busy
    from public.fleets f
   where f.player_id = v_player
     and f.main_ship_id = any(v_members)
     and f.status in ('moving', 'returning');
  if v_busy > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_busy');
  end if;

  -- 8) the group must not be mid-sortie: a hunt fleet is a group fleet already committed to combat.
  --    Redirecting it is out of scope (the escape/settle mechanics own it) — fail closed rather than
  --    quietly steer a fleet out of an encounter.
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');
  if v_hunting > 0 then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;

  -- 9) THE MOVER: the group's ONE unified fleet.
  --    Keyed group_id + main_ship_id IS NULL — NOT group_id alone: the legacy expedition send TAGS
  --    group_id onto PER-MEMBER fleets (0204:316, display-only, "routing never reads it"), so
  --    group_id alone would match N member envelopes and pick one at random.
  select count(*) into v_unified_n
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning');
  if v_unified_n > 1 then
    -- Never silently pick one. Two live unified fleets for one group is a broken invariant.
    return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
  end if;

  if v_unified_n = 1 then
    select * into v_fleet_row
      from public.fleets
     where group_id = v_group and player_id = v_player and main_ship_id is null
       and status in ('idle', 'moving', 'present', 'returning')
     for update;
    v_fleet := v_fleet_row.id;
  end if;

  -- 10) ORIGIN — "the fleet moves from wherever it is" (§2). No home/docked precondition.
  --    STRUCTURE NOTE: the `v_fleet is null` bootstrap MUST be the first branch, so the later branches
  --    only ever touch v_fleet_row once it is assigned. Do NOT rewrite this as
  --    `if v_fleet is not null and v_fleet_row.status = ...` — SQL's AND does not guarantee
  --    left-to-right short-circuit, and reading a field of an unassigned RECORD raises
  --    "record is not assigned yet" regardless of the guard. (The CI proof caught exactly that.)
  if v_fleet is null then
    -- ── BOOTSTRAP (transition-only): the group has no fleet yet, so its position must be derived
    --    ONCE from its members' per-ship state — the only place this function reads ship state as a
    --    position, and only to create the group's first fleet. After step 4 ships have no position
    --    and a group's fleet is created with the group, so this branch disappears.
    select count(distinct lp.location_id) into v_dock_n
      from public.main_ship_instances s
      join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
     where s.main_ship_id = any(v_members);

    if v_dock_n = 1 then
      select lp.location_id, lp.zone_id, l.x, l.y into v_dock
        from public.main_ship_instances s
        join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
        join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
        join public.locations l on l.id = lp.location_id
       where s.main_ship_id = any(v_members)
       limit 1;
      v_o_type := 'location'; v_o_base := null; v_o_zone := v_dock.zone_id; v_o_loc := v_dock.location_id;
      v_o_x := v_dock.x; v_o_y := v_dock.y;
    elsif v_dock_n = 0 then
      select b.id, b.x, b.y, b.sector_id into v_base
        from public.bases b where b.player_id = v_player and b.status = 'active'
        order by b.created_at limit 1;
      if v_base.id is null then
        return jsonb_build_object('ok', false, 'reason', 'no_origin');
      end if;
      v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
      v_o_x := v_base.x; v_o_y := v_base.y;
    else
      -- Members split across ports: the group has no single position to depart from. BOOTSTRAP-only
      -- (the old world let ships scatter); once the fleet exists it always has exactly one position.
      return jsonb_build_object('ok', false, 'reason', 'group_scattered');
    end if;

  elsif v_fleet_row.active_movement_id is not null then
    -- ── REDIRECT: cancel the live leg at its INTERPOLATED point, then depart from there. ─────────
    select * into v_mv
      from public.fleet_movements
     where id = v_fleet_row.active_movement_id
     for update;
    if v_mv.id is null or v_mv.status <> 'moving' then
      -- The settle cron took it between our reads; the fleet is no longer where we thought.
      -- Fail closed and let the caller re-issue against fresh state rather than guess.
      return jsonb_build_object('ok', false, 'reason', 'movement_settled_retry');
    end if;
    -- ── ★ THE S3 FOLD HUNK (2 of 2; hunk 1 deleted the v_t declare) — the inline lerp   ★ ──
    -- ── ★ (0208:420-424) is now a compose of movement_position_at, the ONE interpolation  ★ ──
    -- ── ★ authority. Output-identical by construction — same clamp/nullif/coalesce math;  ★ ──
    -- ── ★ the self-assert below re-proves it at deploy time — so NO new flag.       ★ ──
    select o_x, o_y into v_o_x, v_o_y
      from public.movement_position_at(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y,
                                       v_mv.depart_at, v_mv.arrive_at, v_now);
    -- ── ★ END OF THE S3 FOLD HUNK — the 0208 head continues verbatim from here ★ ──────────────
    v_o_type := 'space';   -- allowed by fleet_movements_origin_type_check since 0156
    v_o_base := null; v_o_zone := null; v_o_loc := null;
    v_old_mv := v_mv.id;
    v_redirected := true;

  elsif v_fleet_row.location_mode = 'space' then
    -- ── FLEET-GO 3b: the fleet is PARKED in open space at its own coordinate. Depart from there.
    --    This is the branch that makes the model closed: a coordinate arrival (the settle's new
    --    'space' branch) leaves the fleet here, and it can set off again without ever touching a port.
    v_o_type := 'space'; v_o_base := null; v_o_zone := null; v_o_loc := null;
    v_o_x := v_fleet_row.space_x; v_o_y := v_fleet_row.space_y;

  elsif v_fleet_row.status = 'present' and v_fleet_row.current_location_id is not null then
    -- Parked at a port: depart from that port.
    select l.id, l.x, l.y, l.zone_id into v_dock
      from public.locations l where l.id = v_fleet_row.current_location_id;
    if v_dock.id is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_origin');
    end if;
    v_o_type := 'location'; v_o_base := null; v_o_zone := v_dock.zone_id; v_o_loc := v_dock.id;
    v_o_x := v_dock.x; v_o_y := v_dock.y;

  else
    -- The group's fleet exists but is neither in flight, in space, nor docked (idle / returning with
    -- no leg). Its anchor is its origin base — the same anchor the hunt uses for return mechanics.
    -- Not a rejection: §2 says the fleet moves from wherever it is, and "at its anchor" is a place.
    select b.id, b.x, b.y, b.sector_id into v_base
      from public.bases b
     where b.player_id = v_player and b.status = 'active'
       and (v_fleet_row.origin_base_id is null or b.id = v_fleet_row.origin_base_id)
     order by b.created_at limit 1;
    if v_base.id is null then
      return jsonb_build_object('ok', false, 'reason', 'no_origin');
    end if;
    v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
    v_o_x := v_base.x; v_o_y := v_base.y;
  end if;

  -- 11) SPEED — D0's authoritative group stats (0166): delegates per-member to 0122, sums additive
  --     keys, takes speed = MIN over members, and raises rather than clamping. Reused, not re-folded.
  begin
    v_stats := public.calculate_group_expedition_stats(v_player, v_group, 'none');
  exception when others then
    -- 0166 is STRICT by design (refuse-don't-clamp): a member's bad stats raise and refuse the whole
    -- team context. Caught here and returned as an envelope — this RPC never raises at its boundary.
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;
  -- NOTE: 0166 nests the folds under 'totals' — `v_stats->>'speed'` is NULL at the top level and
  -- silently degrades to stats_invalid. (The CI proof caught exactly that.)
  v_speed := (v_stats->'totals'->>'speed')::double precision;
  if v_speed is null or not (v_speed > 0) then
    -- fleet_movements_speed_used_check demands > 0; reject rather than feed the spine a bad row.
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end if;

  -- 12) fleet budget — only when this call would CREATE a fleet. A redirect/re-launch of the group's
  --     existing fleet consumes no new slot.
  if v_fleet is null then
    v_max := coalesce(public.cfg_num('max_active_fleets'), 3);
    select count(*) into v_active
      from public.fleets
     where player_id = v_player and status in ('moving', 'present', 'returning');
    if v_active >= v_max then
      return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
    end if;
  end if;

  -- ── WRITES ─────────────────────────────────────────────────────────────────────────────────────
  -- NOTE FOR EVERY FUTURE READER: there is deliberately NO `update main_ship_instances` below.
  -- That absence is the charter's §2. If you are here to add one, re-read §2 and §0 first.

  -- ★ DISSOLVE THE MEMBERS' OWN DOCKS — the ships leave the port to fly with the fleet. ★
  -- This is send_ship_group_hunt's block (0204:664-676), composed verbatim rather than re-invented.
  --
  -- WHY THIS EXISTS (a real bug in 3a, found by the step-3c/4 recon): 3a copied the hunt's fleet SHAPE
  -- (one fleets row, main_ship_id NULL, group_id set) but NOT its dissolve. Its only presence write was
  -- scoped to the unified fleet, and the transition guard rejects only 'moving'/'returning' members —
  -- 'present' waved through. So every go left each member with a live 'present' fleet + active presence
  -- at the port it departed: the fleet in flight while its ships stayed docked, trading and storing at
  -- the origin. That is the EXACT duality §2 kills, re-introduced by the migration meant to kill it.
  --
  -- The NOSHIPWRITE proof could never have caught it: it diffs main_ship_instances, and this leak lives
  -- in fleets/location_presence. A proof pins the property you thought of. FLEETGO_PASS_NOGHOSTDOCK now
  -- pins this one — asserted after EVERY go, not just the first.
  --
  -- fleet_complete requires 'returning', so (like the hunt) this is a direct completed-write: the dock
  -- had no movement to settle.
  perform public.presence_complete(lp.id)
    from public.fleets f
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
   where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
  update public.fleets
     set status = 'completed', location_mode = 'movement', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = v_now
   where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

  if v_redirected then
    -- Retire the cancelled leg BEFORE the fleet is re-pointed (fleets_movement_pointers_exclusive).
    update public.fleet_movements
       set status = 'cancelled', resolved_at = v_now
     where id = v_old_mv and status = 'moving';
  end if;

  if v_fleet is null then
    -- The group's ONE fleet: the hunt's proven shape (main_ship_id NULL + group_id set).
    -- origin_base_id anchors the existing return-to-base mechanics, exactly as the hunt does.
    -- Born 'idle' — which is precisely what fleet_set_moving demands below.
    select b.id into v_base
      from public.bases b where b.player_id = v_player and b.status = 'active'
      order by b.created_at limit 1;
    insert into public.fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
      values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
      returning id into v_fleet;
  else
    -- Return the group's EXISTING fleet to 'idle' so fleet_set_moving's frozen precondition holds.
    -- fleet_set_moving only accepts an idle fleet and raises otherwise; §4 says compose the frozen
    -- primitives rather than gate around them, so the fleet is released into idle here instead of
    -- the helper being bypassed with a hand-rolled UPDATE. (The CI proof caught this: a redirect and
    -- a port departure both hand it a non-idle fleet.)
    -- Closing the dock presence is part of leaving: a fleet that is departing must not stay 'active'
    -- at the port it is leaving (the same dissolve the hunt performs for its members' fleets).
    -- 3b: space_x/space_y are cleared here too — the fleet is no longer parked anywhere, it is under
    -- way. The origin was already captured above, so this loses nothing.
    perform public.presence_complete(lp.id)
      from public.location_presence lp
     where lp.fleet_id = v_fleet and lp.status = 'active';
    update public.fleets
       set status = 'idle', location_mode = 'movement', active_movement_id = null,
           space_x = null, space_y = null,
           current_location_id = null, current_zone_id = null, current_sector_id = null,
           updated_at = v_now
     where id = v_fleet;
  end if;

  -- ONE movement for the ONE fleet. mission 'rally' = the spine's generic reposition
  -- (fleet_movements_mission_type_check). For a 'space' target the location id is NULL and the
  -- coordinate carries the destination; for a port it is the reverse (0067's target-shape rule).
  v_movement := public.movement_create(
    v_player, v_fleet,
    v_o_type, v_o_base, v_o_zone, v_o_loc, v_o_x, v_o_y,
    v_t_type, null, null, v_t_loc, v_t_x, v_t_y,
    'rally', v_speed);

  perform public.fleet_set_moving(v_fleet, v_movement);

  select arrive_at into v_arrive from public.fleet_movements where id = v_movement;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'fleet_id', v_fleet,
    'movement_id', v_movement,
    'arrive_at', v_arrive,
    'member_count', v_member_n,
    'redirected', v_redirected,
    'origin_type', v_o_type,
    'target_type', v_t_type,
    'target_x', v_t_x,
    'target_y', v_t_y);
end;
$function$;

comment on function public.command_ship_group_go(uuid, uuid, double precision, double precision) is
  'FLEET-GO (charter §2): the ONE fleet-level mover. Moves a ship_group as a single atomic fleet to a '
  'port OR a world coordinate, from wherever it is (port, open space, anchor, or mid-flight); re-issue '
  'to redirect. Writes NO per-ship movement state — that omission is the point. DARK behind '
  'fleet_movement_unified_enabled. S4 TIMED DOCKING (0219): under timed_docking_enabled a DOCKABLE '
  'port target is translated to its coordinate — the fleet parks in orbit and docks via '
  'command_ship_group_dock.';

revoke all on function public.command_ship_group_go(uuid, uuid, double precision, double precision) from public;
grant execute on function public.command_ship_group_go(uuid, uuid, double precision, double precision) to authenticated;

-- ── 6. self-assert (deploy-time, raises on failure — the 0213/0215/0218 idiom) ───────────────────
do $s4assert$
declare
  v_dock   text;
  v_mover  text;
  v_settle text;
  v_chk    text;
  v_tgate int; v_ugate int; v_lock int; v_gsm int; v_sort int; v_leaf int; v_park int;
  v_terr int; v_noterr int; v_legal int; v_nodock int; v_mkmv int; v_secs int; v_setm int;
  v_cdest int; v_hunk int; v_busy int;
begin
  -- (a) single definitions; grant posture (both verbs client-callable).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in
         ('command_ship_group_dock', 'command_ship_group_go')) <> 2 then
    raise exception 'S4 self-assert FAIL: expected exactly 2 single definitions (dock verb + mover)'; end if;
  if not has_function_privilege('authenticated', 'public.command_ship_group_dock(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.command_ship_group_go(uuid, uuid, double precision, double precision)', 'execute') then
    raise exception 'S4 self-assert FAIL: a verb lost its authenticated execute grant'; end if;

  -- (b) the CHECK widen landed: the mission_type constraint carries ''dock''.
  select pg_get_constraintdef(oid) into v_chk from pg_constraint
   where conname = 'fleet_movements_mission_type_check' and conrelid = 'public.fleet_movements'::regclass;
  if v_chk is null or position('dock' in v_chk) = 0 then
    raise exception 'S4 self-assert FAIL: fleet_movements_mission_type_check does not admit ''dock'' (%)', v_chk; end if;

  -- (c) the S3-review fold landed: territory_radius is NULL-or-positive at the schema.
  if not exists (select 1 from pg_constraint
                  where conname = 'locations_territory_radius_positive'
                    and conrelid = 'public.locations'::regclass) then
    raise exception 'S4 self-assert FAIL: locations_territory_radius_positive is missing — the S3-review containment divergence stays open'; end if;

  -- (d) the flags are seeded (values NOT asserted — a lit env must survive a re-run).
  if (select count(*) from public.game_config where key in ('timed_docking_enabled', 'docking_seconds')) <> 2 then
    raise exception 'S4 self-assert FAIL: the timed_docking_enabled / docking_seconds seeds are missing'; end if;

  -- (e) DOCK BODY ORDER (mutation-style chain, FIRST occurrences): timed gate < unified gate <
  --     group lock < gsm join < sortie reject < leaf < parked < territory < not_in_territory <
  --     dockability < not_dockable < mint < clock < set_moving. A guard arm after the mint guards
  --     nothing; the timed gate after any read leaks an existence oracle into the dark world.
  select prosrc into v_dock from pg_proc where oid = 'public.command_ship_group_dock(uuid)'::regprocedure;
  v_tgate  := position('timed_docking_disabled' in v_dock);
  v_ugate  := position('unified_movement_disabled' in v_dock);
  v_lock   := position('from public.ship_groups where group_id = v_group and player_id = v_player for update' in v_dock);
  v_gsm    := position('join public.fleets f on f.id = gsm.fleet_id' in v_dock);
  v_sort   := position('group_on_sortie' in v_dock);
  v_leaf   := position('ship_group_resolve_fleet' in v_dock);
  v_park   := position('not_parked' in v_dock);
  v_terr   := position('fleet_in_territory' in v_dock);
  v_noterr := position('not_in_territory' in v_dock);
  v_legal  := position('mainship_space_location_target_legal' in v_dock);
  v_nodock := position('not_dockable' in v_dock);
  v_mkmv   := position('movement_create(' in v_dock);
  v_secs   := position('docking_seconds' in v_dock);
  v_setm   := position('fleet_set_moving(' in v_dock);
  if not (v_tgate > 0 and v_tgate < v_ugate and v_ugate < v_lock and v_lock < v_gsm
          and v_gsm < v_sort and v_sort < v_leaf and v_leaf < v_park and v_park < v_terr
          and v_terr < v_noterr and v_noterr < v_legal and v_legal < v_nodock
          and v_nodock < v_mkmv and v_mkmv < v_secs and v_secs < v_setm) then
    raise exception 'S4 self-assert FAIL: dock body order broke (tgate=%, ugate=%, lock=%, gsm=%, sortie=%, leaf=%, parked=%, terr=%, noterr=%, legal=%, nodock=%, mint=%, clock=%, set_moving=%)',
      v_tgate, v_ugate, v_lock, v_gsm, v_sort, v_leaf, v_park, v_terr, v_noterr, v_legal, v_nodock, v_mkmv, v_secs, v_setm; end if;
  -- the sortie guard keeps its LIVE scope (the 0169/0215 law) and the clock its exact-45 shape.
  if position('f.status in (''moving'', ''present'', ''returning'')' in v_dock) = 0 then
    raise exception 'S4 self-assert FAIL: the dock verb''s sortie guard lost its LIVE scope'; end if;
  if position('make_interval(secs => v_secs)' in v_dock) = 0
     or position('where id = v_movement and status = ''moving''' in v_dock) = 0 then
    raise exception 'S4 self-assert FAIL: the 0149 transform idiom (flat-clock overwrite) lost its shape'; end if;
  -- (the banned construct is CONCATENATED here so the file-wide static ban judges CODE, never this literal)
  if position('update ' || 'main_ship_instances' in v_dock) > 0 or position('update public.' || 'main_ship_instances' in v_dock) > 0 then
    raise exception 'S4 self-assert FAIL: the dock verb writes a ship — charter §2 says a ship does not move'; end if;

  -- (f) THE MOVER PARITY + THE HUNK: the S3 fold survives (movement_position_at composed, no
  --     inline lerp), the in-body unified gate survives, and the ONE S4 hunk is present, gated,
  --     and ordered inside the location branch (after combat_destination, before guard 7).
  select prosrc into v_mover from pg_proc where oid = 'public.command_ship_group_go(uuid, uuid, double precision, double precision)'::regprocedure;
  if position('movement_position_at' in v_mover) = 0 then
    raise exception 'S4 self-assert FAIL: the mover no longer composes movement_position_at — it was rebuilt from a stale (pre-S3) head'; end if;
  if position('origin_x + (' in v_mover) > 0 then
    raise exception 'S4 self-assert FAIL: an inline lerp copy resurfaced in the mover — the 0136 stale-head class'; end if;
  if position('unified_movement_disabled' in v_mover) = 0 then
    raise exception 'S4 self-assert FAIL: the mover lost its in-body fleet_movement_unified_enabled gate'; end if;
  v_cdest := position('combat_destination' in v_mover);
  v_hunk  := position('cfg_bool(''timed_docking_enabled'')' in v_mover);
  v_busy  := position('member_busy' in v_mover);
  if not (v_cdest > 0 and v_cdest < v_hunk and v_hunk < v_busy) then
    raise exception 'S4 self-assert FAIL: the translate hunk is missing or out of place (combat_destination=%, hunk=%, member_busy=%)', v_cdest, v_hunk, v_busy; end if;
  if position('v_t_type := ''space''; v_t_loc := null' in v_mover) = 0 then
    raise exception 'S4 self-assert FAIL: the translate hunk lost its coordinate rewrite (v_t_type/v_t_loc)'; end if;
  if position('mainship_space_location_target_legal' in v_mover) = 0 then
    raise exception 'S4 self-assert FAIL: the translate hunk does not compose the ONE dockability rule'; end if;

  -- (g) THE SETTLE IS UNTOUCHED IN THE WAY THAT MATTERS: it never reads mission_type, so the dock
  --     leg settles through the exact location branch every legacy leg uses. (The static CI pin is
  --     that this FILE re-creates no settle; this deployed-state pin is that no OTHER migration
  --     sneaked a mission_type read into it either.)
  select prosrc into v_settle from pg_proc where oid = 'public.movement_settle_arrival(uuid)'::regprocedure;
  if position('mission_type' in v_settle) > 0 then
    raise exception 'S4 self-assert FAIL: movement_settle_arrival reads mission_type — the dock leg no longer settles as a plain location arrival'; end if;
end $s4assert$;
