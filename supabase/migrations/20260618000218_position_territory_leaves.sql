-- 0218 — S3 POSITION + TERRITORY LEAVES (charter §2; serializes behind S2's 0217 territory_radius).
--
-- TRUE-HEAD DECLARATION: this file re-creates command_ship_group_go AND command_ship_group_stop and
-- is now the TRUE HEAD of BOTH. The 0208 mover body and the 0215 brake body are superseded — edit
-- and copy from HERE (the 0211 lesson: a guard pointed at a superseded head guards nothing;
-- scripts/fleetgo-proof.sh's MIGRATION_STOP and MIGRATION_S3 point here now).
--
-- WHAT: three new leaves + two PARITY re-creates.
--   1. movement_position_at(...)  — the ONE movement-interpolation authority (sql IMMUTABLE STRICT,
--      reads NO table). Mirrors the client's interpolateMovementPoint
--      (src/features/map/movementInterpolation.ts:39-49) EXACTLY:
--      t = clamp01((at - depart) / (arrive - depart)); p = origin + t * (target - origin).
--   2. fleet_current_position(p_fleet_id, p_at) — the state DISPATCH (plpgsql STABLE SECURITY
--      DEFINER): in flight → the leaf; parked in space → space_x/y; present → the port's x/y;
--      at a base → the base's x/y; anything else → NULL/NULL, fail closed. A READ leaf: no lock —
--      writers keep their own FOR UPDATE and compose the pure math leaf themselves.
--   3. fleet_in_territory(p_fleet_id, p_at) returns uuid — composes fleet_current_position +
--      public.osn_distance (0099 — NEVER a third distance formula) + locations.territory_radius
--      (0217). Tiebreak mirrors the client territoryAt (src/features/map/territoryAt.ts): smallest
--      containing radius wins, equal radii tie-break to the lowest id; containment is INCLUSIVE
--      (<=). New + uncalled = dark by construction; its consumer (S4) carries the flag — the leaf
--      itself is deliberately NOT pre-gated.
--
-- THE FOLD (the census — "3x inline interpolation" is really 2 live copies, both folded here):
--   • mover redirect, TRUE HEAD 0208:420-424 (lvalues v_o_x/v_o_y)   → folded into leaf 1.
--   • brake,          TRUE HEAD 0215:155-159 (lvalues v_x/v_y)       → folded into leaf 1.
--   The two were verified byte-identical expressions (same (arrive-depart) denominator, same
--   nullif, same clamp, same coalesce(v_t, 0)), so the fold is OUTPUT-IDENTICAL and needs NO new
--   flag: both hosts keep their existing in-body fleet_movement_unified_enabled gate untouched
--   (0208:237 / 0215:73) and dark envs stay inert.
--
-- DELIBERATELY NOT FOLDED (named so nobody "finishes the job" by accident):
--   • the legacy per-ship stop family — 0149:109-111, 0152:390-392, 0155:116-118 — divides by
--     `travel_seconds`, NOT (arrive_at - depart_at): a DIFFERENT formula, dark post-flip, and the
--     whole family retires at step 4. Folding it would change its output; retiring it is the fix.
--   • the OSN space-stop family — 0064:303-306, 0067:790-793 — a different spine with an
--     unguarded one-line clamp; same step-4 retirement.
--   • superseded ancestors 0207:251-255 and 0209:111-115 — shipped history; frozen files are
--     never edited.
--
-- PARITY RE-CREATES (byte-copy discipline; a reviewer diffs each body against its head):
--   • command_ship_group_go: the 0208:180-586 head byte-for-byte with EXACTLY TWO marked hunks —
--     (hunk 1) the `v_t          double precision;` declare line (0208:213) is deleted;
--     (hunk 2) the inline lerp 0208:420-424 becomes a movement_position_at compose.
--   • command_ship_group_stop: the 0215:44-193 head byte-for-byte with EXACTLY TWO marked hunks —
--     (hunk 1) the `v_t        double precision;` declare line (0215:58) is deleted;
--     (hunk 2) the inline lerp 0215:155-159 becomes the SAME compose. The 0215 sortie-guard hunk,
--     its LIVE scope (f.status in ('moving','present','returning')) and its ORDER (gate → group
--     lock → gsm guard → fleet count → movement lock → cancel) survive VERBATIM — the in-file
--     self-assert below re-pins all of it on the deployed body.
--   Both comment-on-function texts and grants are re-emitted verbatim from their heads.
--
-- CLIENT PARITY (reviewer's diff; NO client code changes in S3):
--   src/features/map/movementInterpolation.ts:39-49 ≡ movement_position_at. Recorded edge notes
--   (harmless, deliberately not "fixed"): the client returns null when arrive <= depart — a state
--   the server cannot mint (fleet_movements CHECK arrive_at > depart_at, 0007) — and fails closed
--   on non-finite input; the server leaf's nullif/coalesce answers the origin for the degenerate
--   case instead. territoryAt.ts additionally skips non-positive radii; the seeded radius map
--   (25/35/15/NULL, 0217) contains none, so the `territory_radius is not null` filter below is
--   behavior-identical on every real row.
--
-- Purely additive posture: no table altered, no function dropped, no flag touched or seeded, and
-- (the §2 law) NOTHING written to main_ship_instances.

-- ── 0. dependency gate: S3 serializes behind S2 (0217) and composes 0099 ─────────────────────────
do $s3dep$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'locations'
                    and column_name = 'territory_radius') then
    raise exception 'S3 POSLEAF: locations.territory_radius (S2/0217) is missing — S3 serializes behind S2';
  end if;
  if to_regprocedure('public.osn_distance(double precision, double precision, double precision, double precision)') is null then
    raise exception 'S3 POSLEAF: public.osn_distance (0099) is missing — the territory leaf composes it, never a third formula';
  end if;
end $s3dep$;

-- ── 1. movement_position_at — the ONE interpolation authority (pure math, owns no table) ─────────
-- The exact former inline math, verbatim in spirit and output: t is the epoch ratio, nullif guards
-- the zero denominator, coalesce answers 0 for the degenerate case, clamp01 via greatest/least,
-- then origin + (target - origin) * t. Scalar args, not a row type: the callers hold `v_mv record`
-- (a locked row), and a record type cannot cross an IMMUTABLE boundary cleanly.
create or replace function public.movement_position_at(
  p_origin_x double precision, p_origin_y double precision,
  p_target_x double precision, p_target_y double precision,
  p_depart timestamptz, p_arrive timestamptz, p_at timestamptz,
  out o_x double precision, out o_y double precision)
language sql
immutable
strict
set search_path = public
as $$
  select p_origin_x + (p_target_x - p_origin_x) * t.v,
         p_origin_y + (p_target_y - p_origin_y) * t.v
    from (select greatest(0::double precision, least(1::double precision, coalesce(
                   extract(epoch from (p_at - p_depart))
                   / nullif(extract(epoch from (p_arrive - p_depart)), 0), 0))) as v) t
$$;

comment on function public.movement_position_at(double precision, double precision, double precision, double precision, timestamptz, timestamptz, timestamptz) is
  'S3 POSLEAF: the ONE movement-interpolation authority. t = clamp01((at-depart)/(arrive-depart)); '
  'p = origin + t*(target-origin). Mirrors the client interpolateMovementPoint exactly. IMMUTABLE '
  'STRICT pure math — it must NEVER read a table; state dispatch lives in fleet_current_position.';

-- ── 2. fleet_current_position — the state dispatch (mirrors the mover's origin chain 0208:409-461) ──
create or replace function public.fleet_current_position(
  p_fleet_id uuid,
  p_at timestamptz default now(),
  out o_x double precision,
  out o_y double precision)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_fleet record;
  v_mv    record;
  v_pos   record;
begin
  -- A READ leaf: no lock anywhere below. Writers (the mover, the brake) keep their own FOR UPDATE
  -- and compose the pure math leaf directly; readers compose THIS. Both NULL = fail closed.
  select f.status, f.location_mode, f.active_movement_id, f.space_x, f.space_y,
         f.current_location_id, f.current_base_id
    into v_fleet
    from public.fleets f
   where f.id = p_fleet_id;
  if not found then
    return;  -- unknown fleet → NULL/NULL, fail closed
  end if;

  if v_fleet.active_movement_id is not null then
    -- (1) IN FLIGHT: interpolate the live leg via the ONE leaf.
    select m.origin_x, m.origin_y, m.target_x, m.target_y, m.depart_at, m.arrive_at
      into v_mv
      from public.fleet_movements m
     where m.id = v_fleet.active_movement_id and m.status = 'moving';
    if found then
      select * into v_pos from public.movement_position_at(
        v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y,
        v_mv.depart_at, v_mv.arrive_at, p_at);
      o_x := v_pos.o_x; o_y := v_pos.o_y;
    end if;
    -- pointer set but the leg is not 'moving': the settle took it between reads — fail closed
    -- (NULL/NULL), exactly the mover's movement_settled_retry posture, never a guessed position.
    return;
  elsif v_fleet.location_mode = 'space' then
    -- (2) PARKED IN OPEN SPACE at the fleet's own coordinate (0208's 3b column).
    o_x := v_fleet.space_x; o_y := v_fleet.space_y;
  elsif v_fleet.status = 'present' and v_fleet.current_location_id is not null then
    -- (3) DOCKED at a port: the port's position is the fleet's position.
    select l.x, l.y into o_x, o_y from public.locations l where l.id = v_fleet.current_location_id;
  elsif v_fleet.current_base_id is not null then
    -- (4) AT A BASE (location_mode 'base'): the base's position.
    select b.x, b.y into o_x, o_y from public.bases b where b.id = v_fleet.current_base_id;
  end if;
  -- (5) anything else → NULL/NULL, fail closed.
end;
$$;

comment on function public.fleet_current_position(uuid, timestamptz) is
  'S3 POSLEAF: WHERE IS THIS FLEET, at p_at. Dispatch mirrors the mover''s origin chain: in flight '
  '→ movement_position_at; in space → space_x/y; present → the port; base → the base; else NULL '
  'fail-closed. Read-only, no locks — writers keep their own FOR UPDATE and compose the math leaf.';

-- ── 3. fleet_in_territory — position + osn_distance + territory_radius, the S4 authority ─────────
create or replace function public.fleet_in_territory(
  p_fleet_id uuid,
  p_at timestamptz default now())
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  -- SECURITY DEFINER is load-bearing: osn_distance is service_role-only (0099:305-306), so this
  -- composition runs with the definer's rights (the 0104/0172 definer-composition precedent).
  -- Tiebreak MUST mirror the client territoryAt: smallest containing radius first, then lowest id.
  select l.id
    from public.fleet_current_position(p_fleet_id, p_at) pos,
         public.locations l
   where pos.o_x is not null
     and public.osn_distance(pos.o_x, pos.o_y, l.x, l.y) <= l.territory_radius
     and l.status = 'active'
     and l.territory_radius is not null
   order by l.territory_radius asc, l.id asc
   limit 1
$$;

comment on function public.fleet_in_territory(uuid, timestamptz) is
  'S3 POSLEAF: the territory containing the fleet at p_at (a location id), or NULL for open space. '
  'Composes fleet_current_position + osn_distance + locations.territory_radius; inclusive '
  'containment; smallest-radius-then-lowest-id tiebreak mirroring the client territoryAt. New and '
  'uncalled = dark by construction — its S4 consumer carries the flag, the leaf is not pre-gated.';

-- ── leaf grants: the osn_distance idiom (0099:305-306) — off the client surface entirely ─────────
revoke execute on function public.movement_position_at(double precision, double precision, double precision, double precision, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function public.movement_position_at(double precision, double precision, double precision, double precision, timestamptz, timestamptz, timestamptz) to service_role;
revoke execute on function public.fleet_current_position(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function public.fleet_current_position(uuid, timestamptz) to service_role;
revoke execute on function public.fleet_in_territory(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function public.fleet_in_territory(uuid, timestamptz) to service_role;

-- ── 4. PARITY re-create: command_ship_group_go — the 0208:180-586 head, TWO marked hunks ─────────
-- Hunk 1: the v_t declare is deleted (the lerp's scratch var moved into the leaf).
-- Hunk 2: 0208:420-424 (the inline lerp) → the movement_position_at compose, marked in-body.
-- EVERYTHING else — the dark gate, target shape, guards 7/8, the bootstrap/redirect/space/port/
-- anchor origin chain, the dissolve, movement_create, fleet_set_moving — is the head, verbatim.

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
  'fleet_movement_unified_enabled.';

revoke all on function public.command_ship_group_go(uuid, uuid, double precision, double precision) from public;
grant execute on function public.command_ship_group_go(uuid, uuid, double precision, double precision) to authenticated;

-- ── 5. PARITY re-create: command_ship_group_stop — the 0215:44-193 head, TWO marked hunks ────────
-- Hunk 1: the v_t declare is deleted. Hunk 2: 0215:155-159 (the inline lerp) → the SAME
-- movement_position_at compose the mover's redirect now uses — brake and redirect agree on "here"
-- by construction, not by parallel copies. The 0215 SORTIE-GUARD hunk, its LIVE scope and its
-- ORDER survive verbatim (re-pinned by the self-assert below on the DEPLOYED body).

create or replace function public.command_ship_group_stop(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_player   uuid := auth.uid();
  v_group    uuid;
  v_fleet    uuid;
  v_fleet_row record;
  v_unified_n integer;
  v_hunting   integer;
  v_mv       record;
  v_x        double precision;
  v_y        double precision;
  v_now      timestamptz := now();
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gate — reject before ANY read, lock, or write.
  --    NOTE the deliberate divergence from the OSN stop (0083), which has NO boundary gate so that a flag
  --    flip can never strand an in-flight ship. That reasoning does not transfer: this brake can only ever
  --    stop a fleet that the SAME dark mover launched, so while the gate is false there is nothing here to
  --    strand. If that ever stops being true, this gate must go — not the other way around.
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) resolve + LOCK the group. FOR UPDATE, the same first lock the mover takes — a stop and a go on the
  --    same group must serialize, or a go could relaunch a fleet this stop is parking.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- ── ★ THE 0215 HUNK — the ONLY addition to the 0209 head (plus its declare line and one     ★ ──
  -- ── ★ sentence of comment-on-function text; everything else below is the head, verbatim)    ★ ──
  -- 3b) the group must not be mid-sortie — the mover's guard 8 (0208:332-343), mirrored VERBATIM.
  --    WHY: a hunt's sortie fleet is group-shaped (0168: group_id set + main_ship_id NULL) and
  --    matches the resolve below, so without this guard the brake cancels the encounter's leg and
  --    parks the fleet IDLE in open space WITH its manifest still attached. An idle fleet is
  --    IMMORTAL (0047's retention collects only terminal fleets), the manifest is therefore never
  --    cleared, it is invisible to every LIVE-scoped guard, and the next go relaunches it
  --    manifest-attached — from then on every guard answers the sortie reject FOREVER, the fleet
  --    never goes terminal, and it permanently eats a max_active_fleets slot. It BRICKS THE GROUP.
  --    A hunt is a commitment of a frozen roster: the player aborts it with the existing Retreat
  --    button (request_retreat, 0019/0169) or the forced auto-extract at max_presence_seconds —
  --    rejecting here removes ZERO capability.
  --    LIVE-scoped join, NEVER a bare EXISTS: a finished sortie's manifest is RETAINED up to 14d
  --    (0047/0169's retention decision), and a retained dead manifest must not block stopping a
  --    NEW go. REJECT, not idempotent-skip: an open sortie is "refuse", not "nothing to do".
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');
  if v_hunting > 0 then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;
  -- ── ★ END OF THE 0215 HUNK — the head continues verbatim from here ★ ──────────────────────────

  -- 4) the group's ONE unified fleet (group_id + main_ship_id IS NULL — NOT group_id alone; the legacy
  --    expedition send tags group_id onto PER-MEMBER fleets, 0204:316, display-only).
  select count(*) into v_unified_n
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning');
  if v_unified_n > 1 then
    return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
  end if;
  if v_unified_n = 0 then
    -- The group has no unified fleet at all: nothing to stop. Idempotent, not an error.
    return jsonb_build_object('ok', true, 'group_id', v_group, 'stopped', false, 'reason_code', 'no_fleet');
  end if;

  select * into v_fleet_row
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning')
   for update;
  v_fleet := v_fleet_row.id;

  -- 5) not in flight → nothing to halt. Idempotent (0164's best-effort posture): pressing the brake on a
  --    parked fleet reports "already stopped", it does not raise.
  if v_fleet_row.active_movement_id is null then
    return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_fleet,
                              'stopped', false, 'reason_code', 'not_moving');
  end if;

  select * into v_mv
    from public.fleet_movements
   where id = v_fleet_row.active_movement_id
   for update;
  if v_mv.id is null or v_mv.status <> 'moving' then
    -- The settle cron took it between our reads. Nothing to stop; the arrival is the authority.
    return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_fleet,
                              'stopped', false, 'reason_code', 'already_settled');
  end if;

  -- 6) WHERE IT ACTUALLY IS. Byte-identical to the mover's redirect interpolation (0207/0208) — a redirect
  --    is "stop here, then go there", so both must agree on "here". The proof pins the agreement.
  -- ── ★ THE S3 FOLD HUNK (2 of 2; hunk 1 deleted the v_t declare) — the inline lerp     ★ ──
  -- ── ★ (0215:155-159) is now the SAME movement_position_at compose the mover redirect      ★ ──
  -- ── ★ uses, so brake and redirect agree on "here" by construction, not by parallel     ★ ──
  -- ── ★ copies. Output-identical — NO new flag.                                          ★ ──
  select o_x, o_y into v_x, v_y
    from public.movement_position_at(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y,
                                     v_mv.depart_at, v_mv.arrive_at, v_now);
  -- ── ★ END OF THE S3 FOLD HUNK — the 0215 head continues verbatim from here ★ ────────────────

  -- ── WRITES ─────────────────────────────────────────────────────────────────────────────────────
  -- NOTE FOR EVERY FUTURE READER: there is deliberately NO `update main_ship_instances` below. The legacy
  -- stop (0155) parks the SHIP; this parks the FLEET. That difference is the charter's §2.

  update public.fleet_movements
     set status = 'cancelled', resolved_at = v_now
   where id = v_mv.id and status = 'moving';

  -- STOP = HOLD (the 0155 semantic, kept): the fleet holds position in open space at the turn point. It
  -- does NOT return home, and it is immediately re-commandable — command_ship_group_go's location_mode
  -- ='space' branch departs straight from here. Composes 0208's leaf; no second parking mechanism.
  perform public.fleet_set_in_space(v_fleet, v_x, v_y);

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'fleet_id', v_fleet,
    'stopped', true,
    'cancelled_movement_id', v_mv.id,
    'space_x', v_x,
    'space_y', v_y);
end;
$function$;

comment on function public.command_ship_group_stop(uuid) is
  'FLEET-STOP (charter §2): the ONE fleet-level brake. Halts the group''s fleet and HOLDS it in open space '
  'at the interpolated turn point (0208''s fleet_set_in_space), immediately re-commandable. Idempotent. '
  'Refuses an OPEN SORTIE (group_on_sortie, live-scoped manifest join) — abort a hunt via Retreat, never the brake. '
  'Writes NO per-ship movement state — the legacy stop_ship_group_transit (0164) loops the PER-SHIP stop; '
  'this replaces that composed model. DARK behind fleet_movement_unified_enabled.';

revoke all on function public.command_ship_group_stop(uuid) from public;
grant execute on function public.command_ship_group_stop(uuid) to authenticated;

-- ── 6. self-assert (deploy-time, raises on failure — the 0213/0214/0215 idiom) ───────────────────
do $s3assert$
declare
  v_leaf  text;
  v_mover text;
  v_brake text;
  v_pos   record;
  v_t     double precision;
  v_ex    double precision;
  v_ey    double precision;
  c_dep   constant timestamptz := timestamptz '2026-01-01 00:00:00+00';
  c_arr   constant timestamptz := timestamptz '2026-01-01 00:01:00+00';
  v_gate int; v_lock int; v_busy int; v_gsm int; v_sort int; v_amb int;
  v_diss int; v_mkmv int; v_setm int; v_mvlock int; v_cancel int;
begin
  -- (a) single definitions; grant posture (mover/brake stay authenticated; leaves stay internal).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in
         ('movement_position_at', 'fleet_current_position', 'fleet_in_territory',
          'command_ship_group_go', 'command_ship_group_stop')) <> 5 then
    raise exception 'S3 self-assert FAIL: expected exactly 5 single definitions (3 leaves + mover + brake)'; end if;
  if not has_function_privilege('authenticated', 'public.command_ship_group_go(uuid, uuid, double precision, double precision)', 'execute')
     or not has_function_privilege('authenticated', 'public.command_ship_group_stop(uuid)', 'execute') then
    raise exception 'S3 self-assert FAIL: mover/brake lost their authenticated execute grant'; end if;
  if has_function_privilege('authenticated', 'public.movement_position_at(double precision, double precision, double precision, double precision, timestamptz, timestamptz, timestamptz)', 'execute')
     or has_function_privilege('authenticated', 'public.fleet_current_position(uuid, timestamptz)', 'execute')
     or has_function_privilege('authenticated', 'public.fleet_in_territory(uuid, timestamptz)', 'execute')
     or not has_function_privilege('service_role', 'public.movement_position_at(double precision, double precision, double precision, double precision, timestamptz, timestamptz, timestamptz)', 'execute') then
    raise exception 'S3 self-assert FAIL: a leaf leaked onto the client surface (osn_distance grant idiom broken)'; end if;

  -- (b) the interpolation leaf is IMMUTABLE STRICT pure math: it must never read a table.
  select prosrc into v_leaf from pg_proc
   where oid = 'public.movement_position_at(double precision, double precision, double precision, double precision, timestamptz, timestamptz, timestamptz)'::regprocedure;
  if (select provolatile from pg_proc
       where oid = 'public.movement_position_at(double precision, double precision, double precision, double precision, timestamptz, timestamptz, timestamptz)'::regprocedure) <> 'i'
     or not (select proisstrict from pg_proc
       where oid = 'public.movement_position_at(double precision, double precision, double precision, double precision, timestamptz, timestamptz, timestamptz)'::regprocedure) then
    raise exception 'S3 self-assert FAIL: movement_position_at is not IMMUTABLE STRICT'; end if;
  if position('public.' in v_leaf) > 0 then
    raise exception 'S3 self-assert FAIL: movement_position_at references a schema object — the pure leaf must not read tables'; end if;

  -- (c) the leaf's math ≡ the exact former inline math, re-derived HERE from first principles
  --     (midpoint / clamp-low / clamp-high / degenerate / strict-null), exact `is distinct from`.
  select * into v_pos from public.movement_position_at(-50, -30, 80, -10, c_dep, c_arr, c_dep + interval '45 seconds');
  v_t := extract(epoch from ((c_dep + interval '45 seconds') - c_dep))
         / nullif(extract(epoch from (c_arr - c_dep)), 0);
  v_t := greatest(0::double precision, least(1::double precision, coalesce(v_t, 0)));
  v_ex := -50 + (80 - (-50)) * v_t;
  v_ey := -30 + (-10 - (-30)) * v_t;
  if v_pos.o_x is distinct from v_ex or v_pos.o_y is distinct from v_ey then
    raise exception 'S3 self-assert FAIL: leaf(t=0.75) = (%, %) <> the inline math (%, %)', v_pos.o_x, v_pos.o_y, v_ex, v_ey; end if;
  select * into v_pos from public.movement_position_at(0, 0, 10, 20, c_dep, c_arr, c_dep + interval '30 seconds');
  if v_pos.o_x is distinct from 5::double precision or v_pos.o_y is distinct from 10::double precision then
    raise exception 'S3 self-assert FAIL: leaf midpoint = (%, %) <> (5, 10)', v_pos.o_x, v_pos.o_y; end if;
  select * into v_pos from public.movement_position_at(0, 0, 10, 20, c_dep, c_arr, c_dep - interval '100 seconds');
  if v_pos.o_x is distinct from 0::double precision or v_pos.o_y is distinct from 0::double precision then
    raise exception 'S3 self-assert FAIL: leaf does not clamp t<0 to the origin'; end if;
  select * into v_pos from public.movement_position_at(0, 0, 10, 20, c_dep, c_arr, c_arr + interval '100 seconds');
  if v_pos.o_x is distinct from 10::double precision or v_pos.o_y is distinct from 20::double precision then
    raise exception 'S3 self-assert FAIL: leaf does not clamp t>1 to the target'; end if;
  select * into v_pos from public.movement_position_at(3, 4, 10, 20, c_dep, c_dep, c_dep + interval '10 seconds');
  if v_pos.o_x is distinct from 3::double precision or v_pos.o_y is distinct from 4::double precision then
    raise exception 'S3 self-assert FAIL: the degenerate arrive=depart case must answer the origin (nullif/coalesce)'; end if;
  select * into v_pos from public.movement_position_at(0, 0, 10, 20, c_dep, c_arr, null);
  if v_pos.o_x is not null or v_pos.o_y is not null then
    raise exception 'S3 self-assert FAIL: STRICT must answer NULL on a NULL input'; end if;

  -- (d) THE FOLD LANDED: both hosts compose the leaf; the inline lerp is GONE from both bodies.
  select prosrc into v_mover from pg_proc where oid = 'public.command_ship_group_go(uuid, uuid, double precision, double precision)'::regprocedure;
  select prosrc into v_brake from pg_proc where oid = 'public.command_ship_group_stop(uuid)'::regprocedure;
  if position('movement_position_at' in v_mover) = 0 or position('movement_position_at' in v_brake) = 0 then
    raise exception 'S3 self-assert FAIL: a host does not compose movement_position_at (mover=%, brake=%)',
      position('movement_position_at' in v_mover), position('movement_position_at' in v_brake); end if;
  if position('origin_x + (' in v_mover) > 0 or position('origin_x + (' in v_brake) > 0 then
    raise exception 'S3 self-assert FAIL: an inline interpolation copy survives in a host body — the fold did not land'; end if;

  -- (e) the 0208 head survives in the mover (parity is RETENTION; the hunks are the ONLY change):
  --     tokens + the load-bearing order gate < group lock < guard7 < guard8 < fleet count <
  --     dissolve < movement_create < fleet_set_moving.
  if position('invalid_target_shape' in v_mover) = 0
     or position('combat_destination' in v_mover) = 0
     or position('group_scattered' in v_mover) = 0
     or position('movement_settled_retry' in v_mover) = 0
     or position('no_origin' in v_mover) = 0
     or position('fleet_limit_reached' in v_mover) = 0 then
    raise exception 'S3 self-assert FAIL: a 0208 head token vanished from the mover — parity broke'; end if;
  v_gate := position('cfg_bool(''fleet_movement_unified_enabled'')' in v_mover);
  v_lock := position('from public.ship_groups where group_id = v_group and player_id = v_player for update' in v_mover);
  v_busy := position('member_busy' in v_mover);
  v_gsm  := position('join public.fleets f on f.id = gsm.fleet_id' in v_mover);
  v_amb  := position('fleet_ambiguous' in v_mover);
  v_diss := position('main_ship_id = any(v_members) and status = ''present''' in v_mover);
  v_mkmv := position('movement_create(' in v_mover);
  v_setm := position('fleet_set_moving(' in v_mover);
  if not (v_gate > 0 and v_gate < v_lock and v_lock < v_busy and v_busy < v_gsm and v_gsm < v_amb
          and v_amb < v_diss and v_diss < v_mkmv and v_mkmv < v_setm) then
    raise exception 'S3 self-assert FAIL: mover order broken (gate=%, lock=%, busy=%, gsm=%, amb=%, dissolve=%, create=%, set_moving=%)',
      v_gate, v_lock, v_busy, v_gsm, v_amb, v_diss, v_mkmv, v_setm; end if;

  -- (f) the 0215 head survives in the brake: the group-shaped resolve, the parking leaf, the head
  --     tokens (the interpolation-pair pins of 0215's own assert are REPLACED by (d) above).
  if position('main_ship_id is null' in v_brake) = 0
     or position('status in (''idle'', ''moving'', ''present'', ''returning'')' in v_brake) = 0
     or position('fleet_set_in_space' in v_brake) = 0
     or position('not_moving' in v_brake) = 0
     or position('already_settled' in v_brake) = 0
     or position('fleet_ambiguous' in v_brake) = 0
     or position('no_fleet' in v_brake) = 0 then
    raise exception 'S3 self-assert FAIL: the 0215 head did not survive in the brake (resolve shape / parking leaf / a head token)'; end if;

  -- (g) the sortie guard survives: the gsm join, LIVE-scoped, + the reject token (0215's (c)).
  if position('join public.fleets f on f.id = gsm.fleet_id' in v_brake) = 0
     or position('group_on_sortie' in v_brake) = 0
     or position('f.status in (''moving'', ''present'', ''returning'')' in v_brake) = 0 then
    raise exception 'S3 self-assert FAIL: the brake''s sortie-guard hunk is missing or lost its LIVE scope'; end if;

  -- (h) brake ORDER (0215's (d), retargeted at THIS body): gate < group lock < sortie guard <
  --     fleet count < movement lock < cancel write.
  v_gate   := position('cfg_bool(''fleet_movement_unified_enabled'')' in v_brake);
  v_lock   := position('from public.ship_groups where group_id = v_group and player_id = v_player for update' in v_brake);
  v_gsm    := position('join public.fleets f on f.id = gsm.fleet_id' in v_brake);
  v_sort   := position('group_on_sortie' in v_brake);
  v_amb    := position('fleet_ambiguous' in v_brake);
  v_mvlock := position('where id = v_fleet_row.active_movement_id' in v_brake);
  v_cancel := position('set status = ''cancelled''' in v_brake);
  if not (v_gate > 0 and v_gate < v_lock and v_lock < v_gsm and v_gsm < v_sort
          and v_sort < v_amb and v_amb < v_mvlock and v_mvlock < v_cancel) then
    raise exception 'S3 self-assert FAIL: brake order broken (gate=%, lock=%, gsm=%, sortie=%, count=%, mvlock=%, cancel=%)',
      v_gate, v_lock, v_gsm, v_sort, v_amb, v_mvlock, v_cancel; end if;

  -- (i) the in-body dark gates survive in BOTH hosts (the fold is output-identical → no new flag).
  if position('unified_movement_disabled' in v_mover) = 0 or position('unified_movement_disabled' in v_brake) = 0 then
    raise exception 'S3 self-assert FAIL: a host lost its in-body fleet_movement_unified_enabled gate'; end if;
end $s3assert$;
