-- FLEET-GO (step 3a of the movement unification) — THE ONE FLEET-LEVEL MOVER.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §2 (the model) + §3 (rewritten 2026-07-16 on the
-- owner's decision "§2 wins, rewrite §3").
--
-- §2: THE FLEET IS THE ONLY UNIT OF MOVEMENT. A SHIP DOES NOT MOVE. One moving thing, one position,
-- one command, from wherever it is, re-issuable mid-flight. The per-ship movement layer is RETIRED,
-- not composed.
--
-- WHAT MAKES THIS §2-FAITHFUL — the omission IS the feature:
--   • It creates ONE fleet for the group and ONE fleet_movements row for that fleet.
--   • It writes NOTHING to main_ship_instances. No status, no spatial_state, no space_x/space_y.
--     Every existing mover writes ship-level movement state (move_main_ship_to_location →
--     'traveling'; mainship_space_begin_move_core → 'in_transit'; send_ship_group_hunt → 'hunting').
--     This one does not. That single omission is the whole point: a ship stops being a thing that
--     moves and becomes a member of a thing that moves.
--   • It composes ONLY fleet-level primitives (movement_create, fleet_set_moving) + D0's
--     calculate_group_expedition_stats. It calls NO per-ship mover. The old §3 said to loop
--     command_main_ship_space_move per member; that is the duality §2's CORRECTION repudiates and
--     is deliberately NOT done here.
--
-- SHAPE REUSE (not invention): send_ship_group_hunt (0168 → 0204) already proves one-fleet-per-group
-- — ONE fleets row with main_ship_id NULL + group_id set, members' own fleets dissolved. This copies
-- that proven shape and drops the ship writes. No second fleet spine, no new table.
--
-- REDIRECT IS THE SAME CALL, not a separate step. The old §3 made CHANGE-COURSE its own step because
-- with N per-member movers you must stop N ships and relaunch them. With ONE mover, re-issuing is
-- just: cancel the live leg at its interpolated point, depart a new leg from there. Change-course is
-- a property of having one mover, not a feature bolted on.
--
-- LOCKING — the deadlock class disappears rather than being dodged. ship_groups FOR UPDATE (serializes
-- same-group go-vs-go; FOR SHARE would not) → the group's fleet FOR UPDATE. NO member-ship locks:
-- this writes no ship rows, so there is nothing to lock. 0164 had to deliberately OMIT a ship lock to
-- avoid inverting the settle's movement→ship order and deadlocking the arrival cron; 0204's senders
-- take ship locks first and escape only because movement_create INSERTs rather than locks. Under §2
-- that whole hazard is structural dead weight. Lock order here is groups → fleets → (insert), which
-- shares no resource with the settle's movements → ships.
--
-- DARK: gated on the NEW fleet_movement_unified_enabled (seeded false). Rejects before any read.
-- Nothing existing is modified — no function re-created, no table altered, no flag flipped. The live
-- paths are byte-for-byte untouched, so this migration cannot change production behavior at all.
--
-- SCOPE (§3 step 3a): PORT targets only. fleet_movements.target_type CHECK allows only
-- base|location|zone — the spine literally cannot express a coordinate target today (origin_type DOES
-- allow 'space' since 0156, which is why departing FROM open space works below). §2's coordinate
-- target is step 3b: widen the CHECK + add the settle branch. Split because they are different
-- changes, per the charter's one-migration-per-step rule.

-- ── The dark gate ────────────────────────────────────────────────────────────────────────────────
insert into public.game_config (key, value, description)
values (
  'fleet_movement_unified_enabled',
  'false'::jsonb,
  'FLEET-GO (charter §2): the unified fleet-level mover command_ship_group_go. DARK. When lit, the '
  'ship_group is the atomic mover: one fleet, one movement, no per-ship movement state. Activation '
  'is gated on step 4 retiring the per-ship movers — do NOT flip while both paths are live.'
)
on conflict (key) do nothing;

-- ── The mover ────────────────────────────────────────────────────────────────────────────────────
create or replace function public.command_ship_group_go(
  p_group_id   uuid,
  p_location_id uuid
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
  v_t          double precision;
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
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gate — reject before ANY read, lock, or write (the 0161/0178 reject-before-read posture).
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) resolve + LOCK the group. FOR UPDATE (not FOR SHARE): two concurrent go's on the SAME group
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

  -- 4) members. Read-only: the members are the fleet's manifest, never movement subjects.
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  v_member_n := coalesce(array_length(v_members, 1), 0);
  if v_member_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- 5) destination (port). Step 3b adds the coordinate target; the spine's target_type CHECK
  --    (base|location|zone) cannot express one today.
  select l.id, l.x, l.y, l.status, l.zone_id, z.sector_id
    into v_loc
    from public.locations l
    join public.zones z on z.id = l.zone_id
   where l.id = p_location_id;
  if v_loc.id is null or v_loc.status <> 'active' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_location');
  end if;

  -- 6) TRANSITION GUARD (delete me at step 4, not before).
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

  -- 7) the group must not be mid-sortie: a hunt fleet is a group fleet already committed to combat.
  --    Redirecting it is out of scope for 3a (the escape/settle mechanics own it) — fail closed
  --    rather than quietly steer a fleet out of an encounter.
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');
  if v_hunting > 0 then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;

  -- 8) THE MOVER: the group's ONE unified fleet.
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

  -- 9) ORIGIN — "the fleet moves from wherever it is" (§2). No home/docked precondition.
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
    --    A coherent single origin is required: all members docked at ONE port, or all at base.
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
      -- Members split across ports: the group has no single position to depart from. This is a
      -- BOOTSTRAP-only rejection (the old world let ships scatter); it is not a readiness gate on
      -- the fleet — once the fleet exists it always has exactly one position.
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
    v_t := extract(epoch from (v_now - v_mv.depart_at))
           / nullif(extract(epoch from (v_mv.arrive_at - v_mv.depart_at)), 0);
    v_t := greatest(0::double precision, least(1::double precision, coalesce(v_t, 0)));
    v_o_x := v_mv.origin_x + (v_mv.target_x - v_mv.origin_x) * v_t;
    v_o_y := v_mv.origin_y + (v_mv.target_y - v_mv.origin_y) * v_t;
    v_o_type := 'space';   -- allowed by fleet_movements_origin_type_check since 0156
    v_o_base := null; v_o_zone := null; v_o_loc := null;
    v_old_mv := v_mv.id;
    v_redirected := true;

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
    -- The group's fleet exists but is neither in flight nor docked (idle / returning-with-no-leg /
    -- a completed leg the settle has retired). Its anchor is its origin base — the same anchor the
    -- hunt uses for the return mechanics. Not a rejection: §2 says the fleet moves from wherever it
    -- is, and "at its anchor" is a place.
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

  -- 10) SPEED — D0's authoritative group stats (0166): delegates per-member to 0122, sums additive
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

  -- 11) fleet budget — only when this call would CREATE a fleet. A redirect/re-launch of the group's
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
    perform public.presence_complete(lp.id)
      from public.location_presence lp
     where lp.fleet_id = v_fleet and lp.status = 'active';
    update public.fleets
       set status = 'idle', location_mode = 'movement', active_movement_id = null,
           current_location_id = null, current_zone_id = null, current_sector_id = null,
           updated_at = v_now
     where id = v_fleet;
  end if;

  -- ONE movement for the ONE fleet. mission 'rally' = the spine's generic reposition
  -- (fleet_movements_mission_type_check).
  v_movement := public.movement_create(
    v_player, v_fleet,
    v_o_type, v_o_base, v_o_zone, v_o_loc, v_o_x, v_o_y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
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
    'origin_type', v_o_type);
end;
$function$;

comment on function public.command_ship_group_go(uuid, uuid) is
  'FLEET-GO (charter §2): the ONE fleet-level mover. Moves a ship_group as a single atomic fleet to a '
  'port from wherever it is; re-issue to redirect mid-flight. Writes NO per-ship movement state — that '
  'omission is the point. DARK behind fleet_movement_unified_enabled.';

revoke all on function public.command_ship_group_go(uuid, uuid) from public;
grant execute on function public.command_ship_group_go(uuid, uuid) to authenticated;
