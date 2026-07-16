-- FLEET-GO COORDINATES (step 3b of the movement unification) — the fleet gets a POSITION.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §2 ("One command: 'fleet, go there.' Target is a
-- port OR a world coordinate") + §3 step 2. Follows 0207 (step 3a, the port-target mover).
--
-- WHAT THIS ACTUALLY IS. The charter framed 3b as "widen target_type + a settle branch". That was
-- the smaller half. The real blocker, found against live prod: **`fleets` has NO position column at
-- all** — not space_x, not space_y, nothing. A fleet's position today is always IMPLIED (at a base /
-- at a location / interpolated along a live movement). "Park the fleet at a coordinate" had nowhere
-- to be written down. The OSN domain stored that on main_ship_instances.space_x/space_y — i.e. on the
-- SHIP, which is exactly what §2 abolishes. So the fleet must carry its own position, and that is the
-- substance of this migration.
--
-- THE DELTA TO A LIVE, CRON-DRIVEN FUNCTION (movement_settle_arrival). Its callers are
-- process_fleet_movements (the 30s cron, 0206) and command_main_ship_settle_arrival_legacy (0151).
-- The re-create below is byte-identical to the 0153 head EXCEPT for ONE inserted `elsif m.target_type
-- = 'space'` branch placed before the final else. Every existing target type ('location', 'base') and
-- the fall-through 'failed' path are untouched, so legacy settles are byte-for-byte what they were.
-- The proof pins this with an independent parity assertion, not a promise.
--   NOTE the pre-existing fall-through: an UNKNOWN target_type is marked 'failed'. Before this
--   migration a 'space' movement could not exist (the CHECK forbade it); the CHECK widening and this
--   branch land together, so there is never a window where a 'space' row settles as 'failed'.
--
-- WHY THE COHERENCE CHECK IS AN IMPLICATION, NOT A BICONDITIONAL. The natural constraint is
-- "location_mode='space' IFF coords are present". It would be WRONG here: `fleet_complete` (frozen,
-- shared) sets location_mode='base' WITHOUT clearing space_x/space_y, so a group fleet that parked in
-- space and later completed would violate a biconditional and make that frozen helper start raising
-- for everyone. The implication form lets stale coords sit harmlessly on a non-space fleet (nothing
-- reads them unless location_mode='space'), and the mover clears them on release anyway for hygiene.
-- This is the §4 rule in practice: compose the frozen primitives; do not force them to change.
--
-- SCOPE: still DARK behind fleet_movement_unified_enabled (0207's gate — no new flag). The mover is
-- the only thing that can produce a 'space' target, so the widened CHECK is unreachable in production
-- while the gate is false.

-- ── 1. The fleet's own position ──────────────────────────────────────────────────────────────────
alter table public.fleets add column if not exists space_x double precision;
alter table public.fleets add column if not exists space_y double precision;

comment on column public.fleets.space_x is
  'FLEET-GO 3b (charter §2): the fleet''s own world position when location_mode=''space''. The fleet '
  'is the unit of movement, so the POSITION lives here — never on main_ship_instances (that is the '
  'per-ship layer §2 retires).';

-- ── 2. location_mode gains 'space' ───────────────────────────────────────────────────────────────
alter table public.fleets drop constraint if exists fleets_location_mode_check;
alter table public.fleets add constraint fleets_location_mode_check
  check (location_mode = any (array['base'::text, 'movement'::text, 'location'::text, 'destroyed'::text, 'space'::text]));

-- Coherence: a fleet IN space must know where it is. (Implication, not biconditional — see header.)
alter table public.fleets drop constraint if exists fleets_space_mode_requires_coords;
alter table public.fleets add constraint fleets_space_mode_requires_coords
  check (location_mode <> 'space' or (space_x is not null and space_y is not null));

-- ── 3. a movement may TARGET a coordinate (origin_type already allows 'space' since 0156) ────────
alter table public.fleet_movements drop constraint if exists fleet_movements_target_type_check;
alter table public.fleet_movements add constraint fleet_movements_target_type_check
  check (target_type = any (array['base'::text, 'location'::text, 'zone'::text, 'space'::text]));

-- ── 4. the leaf: park a fleet at a coordinate (the fleet_set_present sibling) ─────────────────────
create or replace function public.fleet_set_in_space(p_fleet uuid, p_x double precision, p_y double precision)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_x is null or p_y is null then
    raise exception 'fleet_set_in_space: coordinates required (fleet %)', p_fleet;
  end if;
  -- Mirrors fleet_set_present: clears the movement pointer + every "somewhere else" pointer, and
  -- writes the one place the fleet now IS. status 'idle' (not 'present'): 'present' means docked at a
  -- location and carries a location_presence row; open space has no presence to create.
  update fleets
     set status = 'idle', location_mode = 'space',
         space_x = p_x, space_y = p_y,
         active_movement_id = null, active_space_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where id = p_fleet;
  if not found then
    raise exception 'fleet_set_in_space: fleet % not found', p_fleet;
  end if;
end;
$function$;

revoke all on function public.fleet_set_in_space(uuid, double precision, double precision) from public;

-- ── 5. the settle: ONE added branch; every legacy path byte-identical to the 0153 head ───────────
create or replace function public.movement_settle_arrival(p_movement uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  m           fleet_movements%rowtype;
  v_loc       record;
  v_units     jsonb;
  v_main_ship uuid;
begin
  -- Guarded locked re-read: still moving AND due. For the cron this is a no-op re-take of a lock it
  -- already holds on a row it already proved due (now() is constant within the txn) — byte-equivalent.
  -- For the on-demand RPC it is the authoritative claim.
  select * into m from fleet_movements
    where id = p_movement and status = 'moving' and arrive_at <= now()
    for update;
  if not found then
    return jsonb_build_object('settled', false, 'reason', 'not_settleable');
  end if;

  if m.target_type = 'location' then
    select l.activity_type as activity, l.zone_id as zone_id, z.sector_id as sector_id
      into v_loc from locations l join zones z on z.id = l.zone_id where l.id = m.target_location_id;
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    perform fleet_set_present(m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id);
    perform presence_create(m.player_id, m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id, v_loc.activity);

    -- Main-ship fleets: settle the SHIP too (0153; decision doc §5 arrival rule). Dock-vs-legacy split:
    --   • DOCKABLE target — the SINGLE canonical legality rule (mainship_space_location_target_legal: active
    --     sector/zone/location + role city|port + activity 'none' + one active docking service + one active
    --     in-bounds anchor) — → the canonical docked pair via the ONE shared docked-ship helper.
    --     fleet_set_present already set the fleet present/location-mode with active_movement_id=NULL and
    --     presence_create added the matching active presence (legacy fleets never carry an
    --     active_space_movement_id), so the ship reads as a coherent at_location per
    --     mainship_space_validate_context.
    --   • otherwise — a main-ship fleet arriving at an active 'none' but NON-dockable target (REACHABLE:
    --     the seed safe-zones Safe Rally Point / Quiet Drift have no role/docking service/anchor) — write
    --     NOTHING to main_ship_instances: the ship is already in the legacy spatial_state=NULL
    --     representation from its departure write (0152's mainship_mark_legacy_in_flight), which is
    --     constraint-legal, coherent legacy_present.
    -- The v_main_ship IS NOT NULL gate keeps ordinary unit fleets (main_ship_id NULL) untouched.
    -- FLEET-GO 3b note: a UNIFIED group fleet has main_ship_id NULL by construction, so it takes the
    -- same "ordinary fleet" path here and no ship is written — §2 holds through the settle, for free.
    select main_ship_id into v_main_ship from fleets where id = m.fleet_id;
    if v_main_ship is not null
       and (public.mainship_space_location_target_legal(m.target_location_id)->>'ok')::boolean is true then
      perform public.mainship_mark_docked_at_location(v_main_ship);
    end if;

    return jsonb_build_object('settled', true, 'outcome', 'present', 'movement_id', m.id);

  elsif m.target_type = 'base' then
    select jsonb_agg(jsonb_build_object('unit_type_id', unit_type_id, 'quantity', quantity))
      into v_units from fleet_units where fleet_id = m.fleet_id and quantity > 0;
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    if v_units is not null then
      perform base_merge_units(m.target_base_id, v_units);
    end if;
    perform fleet_complete(m.fleet_id);
    -- Deposit carried rewards now that the fleet is safely home (idempotent via
    -- reward_grants unique source), under the movement's activity source type.
    if m.reward_payload_json is not null and m.reward_payload_json <> '{}'::jsonb and m.reward_grant_source is not null then
      perform reward_grant(m.reward_source_type, m.reward_grant_source, m.player_id, m.target_base_id, m.reward_payload_json);
    end if;
    return jsonb_build_object('settled', true, 'outcome', 'completed', 'movement_id', m.id);

  -- ★ THE ONLY DELTA vs the 0153 head ★ — FLEET-GO 3b: a coordinate arrival parks the fleet in open
  -- space at the target. No presence (open space has no location), no units merge (nothing to come
  -- home to), no rewards (that is the base branch's job), and — as everywhere in this charter — NO
  -- ship write. Only the unified mover can create a 'space' target, and it is dark, so this branch is
  -- unreachable in production until the gate is lit.
  elsif m.target_type = 'space' then
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    perform public.fleet_set_in_space(m.fleet_id, m.target_x, m.target_y);
    return jsonb_build_object('settled', true, 'outcome', 'in_space', 'movement_id', m.id);

  else
    update fleet_movements set status = 'failed', resolved_at = now() where id = m.id;
    return jsonb_build_object('settled', true, 'outcome', 'failed', 'movement_id', m.id);
  end if;
end;
$function$;

-- ── 6. the mover, widened to (group, {location | x,y}) ───────────────────────────────────────────
-- DROP + CREATE: adding trailing args changes the identity (the 0083/0178/0199 idiom). The 2-arg form
-- must NOT survive as an overload — one command, one signature.
drop function if exists public.command_ship_group_go(uuid, uuid);

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

  -- 6) destination: a port must exist and be active. (A coordinate was fully validated in step 3.)
  if v_t_type = 'location' then
    select l.id, l.x, l.y, l.status, l.zone_id, z.sector_id
      into v_loc
      from public.locations l
      join public.zones z on z.id = l.zone_id
     where l.id = p_location_id;
    if v_loc.id is null or v_loc.status <> 'active' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_location');
    end if;
    v_t_loc := v_loc.id; v_t_x := v_loc.x; v_t_y := v_loc.y;
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
    v_t := extract(epoch from (v_now - v_mv.depart_at))
           / nullif(extract(epoch from (v_mv.arrive_at - v_mv.depart_at)), 0);
    v_t := greatest(0::double precision, least(1::double precision, coalesce(v_t, 0)));
    v_o_x := v_mv.origin_x + (v_mv.target_x - v_mv.origin_x) * v_t;
    v_o_y := v_mv.origin_y + (v_mv.target_y - v_mv.origin_y) * v_t;
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
  'fleet_movement_unified_enabled.';

revoke all on function public.command_ship_group_go(uuid, uuid, double precision, double precision) from public;
grant execute on function public.command_ship_group_go(uuid, uuid, double precision, double precision) to authenticated;
