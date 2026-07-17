-- FLEET-GO 4b-1 — THE THIRD PRE-FLIP OBLIGATION: THE HUNT LEARNS THE FLEET. Migration 0214.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §0 (the recorded bug class), §2 (the FLEET is the
-- only mover), §4 (compose primitives, never hand-roll), and step 4b's SECOND ⚠ PRE-FLIP OBLIGATION
-- block ("hunt-vs-unified-fleet minting", recorded 2026-07-17 by the 3c-3 review) — this migration
-- IS that obligation.
--
-- ── THE DEFECT (verified at source — this charter's inventory has been wrong SEVEN times) ─────────
-- send_ship_group_hunt's readiness (TRUE head 0204:569-584; 0199:267 is the only other post-0168
-- definition, re-derived by LOOSE grep because 0199 is a drop+bare-create a `create or replace`
-- grep misses) checks only PER-SHIP signals: `home`, or `stationary`+`at_location`. The unified
-- mover writes NO ship rows — that omission IS §2 (0207/0208) — so members of a group whose unified
-- fleet is parked, docked, or in flight still carry their stale per-ship signals. Legacy-shaped
-- members read `home` → the hunt PASSES its readiness and mints a SECOND `main_ship_id NULL +
-- group_id` fleet (0204:738-740). Then mainship_resolve_fleet sees v_n = 2 → NULL (0210:90-92,
-- fail closed) → EVERY member of that group reads place='hidden' on the whole map for the sortie's
-- duration, while the oracle's non-strict select (0210:168-171) may simultaneously claim
-- at_location from an arbitrary row. 0210:162-167's "at-most-one unified-shape fleet by
-- construction" is FALSE lit. The mover's guard 8 (0208:332-343) blocks a *go* during a sortie;
-- nothing blocked a *hunt* while a unified fleet was alive. This is that guard's missing twin.
--
-- ── THE FIX: lit, the hunt CONSUMES the settled unified fleet — readiness IS the fleet ────────────
-- NOT "reject a hunt while a unified fleet exists": post-flip every group that ever moved has a
-- persistent settled unified fleet, so that rejection bans hunting forever. Instead, with the
-- group's live group-shaped fleet resolved through the 0213 leaf (ship_group_resolve_fleet — no
-- fifth inline copy of the shape):
--   >1 fleets → reject 'fleet_ambiguous' (fail closed; the mover/brake/0213 token for this exact
--               broken invariant — one broken state, one token).
--   =1, status moving/returning → reject 'group_fleet_in_flight' (the exact symmetric twin of the
--               mover's guard 8, 0208:332-343, which rejects a go during a sortie with
--               'group_on_sortie'; this rejects a hunt during a go, same posture, 0213's token).
--   =1 SETTLED (present at a port / location_mode='space' parked / idle at its anchor) → the sortie
--               ORIGIN is captured FROM THE FLEET (present@port → origin_type='location' at the
--               port's coordinates; parked → origin_type='space' at fleets.space_x/space_y; else
--               the fleet's own anchor base — the mover's three origin arms, 0208:430-461, read the
--               same way), the per-ship home/stationary readiness is SKIPPED (those signals are the
--               retired layer and read stale under §2 — the settled fleet IS readiness; the hp > 0
--               member check is KEPT: lifecycle, not movement), the fleet is CONSUMED
--               (presence_complete + a terminal completed-write — the mover's own release idiom,
--               0208:549-557, made terminal because the hunt mints a NEW fleet), and THEN the
--               existing mint runs. At-most-one is restored BY CONSTRUCTION: the old fleet is
--               terminal before the new one exists, in the same transaction.
--   =0 → fall through to the head's arms VERBATIM — the bootstrap-parity case: a pre-first-go group
--               still carries per-ship dock shapes and the 0199 lit arm (common docked port) handles
--               them; the per-ship readiness is CORRECT there because the per-ship shapes are still
--               the only truth.
-- The resolver's fail-closed NULL (0210:90-92) is UNTOUCHED — this migration re-creates ONE
-- function and loosens nothing.
--
-- ── THE LOCK (Hunk B): lit takes the group row FOR UPDATE; dark keeps the head's FOR SHARE ────────
-- The head's hunt lock is FOR SHARE (0204:527) and the mover/brake take the group FOR UPDATE
-- (0208:274, 0209:66). FOR SHARE does not conflict with FOR UPDATE's absence — a hunt and a go on
-- the same group could interleave their fleet reads and BOTH mint (the exact two-fleet state this
-- migration exists to kill, minted by a race instead of a readiness hole). Lit FOR UPDATE
-- serializes hunt-vs-go/stop/assign (0207/0208/0209 FOR UPDATE, 0213's lit arm FOR UPDATE): whoever
-- commits second re-reads the leaf under the lock and sees the other's fleet. Dark keeps FOR SHARE
-- byte-identically — THE LOCK FOOTPRINT IS PART OF DARK PARITY: a dark hunt must not start
-- conflicting with a concurrent dark send the day this deploys (the 0213 rule, verbatim).
-- HONEST LIMIT (the 0213 statement, still true): a deterministic two-session race is not testable
-- in this repo's single-session proof harness; the closure is lock-conflict reasoning plus a
-- mutation-tested static assert on the gated lock branch (scripts/fleetgo-proof.sh).
--
-- ── LOCK ORDER (the 0164 lesson) ──────────────────────────────────────────────────────────────────
-- group (B) → member ships FOR UPDATE (the head's own 0168 lock, kept — the hunt DOES write ships,
-- unlike the mover) → plain reads of fleets/locations/bases → writes. Same group→ship order as
-- every sibling; no movement lock is taken (the consume touches fleets/location_presence only, and
-- the settled fleet has no active movement by construction — fleet_set_moving is the only writer of
-- that pointer and both settle paths clear it).
--
-- ── PARITY DISCIPLINE (ABSOLUTE — the hunt is a LIVE hot function; team_command is ON in prod) ────
-- Byte-copied from the 0204:479-763 head with exactly THREE marked hunks (A: the flag read + hunk
-- declares; B: the gated lock strength; C: the gated consume-the-fleet branch). Flag OFF (the
-- committed seed): A is a side-effect-free stable read, B takes the identical FOR SHARE, C is
-- skipped entirely → behavior, envelopes, writes, AND lock footprint equal the head on EVERY input
-- — including the load-bearing REACHABLE dark state (team_command lit + a real docked-group hunt),
-- which HUNTUNI_DARKPARITY asserts specifically (the 0210 lesson: parity on states the dark world
-- can reach). Verified by independent mechanical diff against 0204:479-763, not by claim.
--
-- ── WHAT SURVIVES LIT, DELIBERATELY ───────────────────────────────────────────────────────────────
-- • The hunt's ship write (status='hunting', 0204:693-695/749-751 + Hunk C's copy) is KEPT lit: the
--   hunt is NOT the unified mover — 'hunting' is the sortie/combat layer's signal (the 0199
--   reconciler and shield-regen exclusion read it) and it RETIRES AT STEP 4c with the status-column
--   narrowing, not here. A comment in Hunk C marks that dependency.
-- • The hp > 0 member check is KEPT lit (lifecycle, not movement).
-- • group_sortie_members stays the frozen manifest (0168 law) — Hunk C writes it exactly as the
--   head does.
--
-- ── GROUNDING (grep-verified at source, 2026-07-18) ───────────────────────────────────────────────
--   send_ship_group_hunt      — TRUE head 20260618000204:479-763 (0168:132 create-or-replace,
--                               0199:267 drop+bare-create, 0204 create-or-replace: the only three
--                               definitions found by loose grep; 0204 is last)
--   ship_group_resolve_fleet  — 20260618000213 (the ONE leaf; composed, not re-inlined)
--   cfg_bool / cfg_num        — 20260618000046 (reused, via the head)
--   presence_complete         — reused via the head (the head's own dissolve block already calls it)
--   movement_create / fleet_set_moving — reused via the head
--   the fleet shape           — 0168/0204 mint it; 0207/0208/0209/0210 match it; 0213 is the leaf
--   fleet origin arms         — 0208:430-461 (the mover's port/space/anchor reads, mirrored)
--   the release idiom         — 0208:549-557 (presence_complete + pointer-clearing update), made
--                               terminal ('completed') because the hunt mints a NEW fleet

-- ── §1) send_ship_group_hunt — the 0204:479-763 head, byte-copied, + the THREE marked hunks ───────
create or replace function public.send_ship_group_hunt(p_group_id uuid, p_location uuid, p_return_location_id uuid default null)
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
  -- FLEET-CONTROL (0204): the gate, read ONCE. Dark seed → false → the command-ship hunk is skipped and the
  -- 0199 body runs verbatim.
  v_fleet_control boolean := public.cfg_bool('fleet_control_enabled');
  -- HUNT-UNI (0214) HUNK A: the unification gate, read ONCE at the top (the 0204/0213 idiom directly
  -- above, verbatim). Dark seed → false → Hunk B below keeps the head's FOR SHARE and Hunk C is
  -- skipped entirely — a side-effect-free stable read is the WHOLE dark delta of this migration.
  v_unified boolean := public.cfg_bool('fleet_movement_unified_enabled');
  v_gf_n    integer;              -- live group-shaped fleets found by the 0213 leaf
  v_gf      public.fleets%rowtype; -- the ONE such fleet, when v_gf_n = 1
  v_gfl     record;               -- the consumed fleet's port row (coords for the origin)
  v_o_type  text;                 -- sortie origin, captured FROM THE FLEET (the 0208 arm naming)
  v_o_base  uuid;
  v_o_zone  uuid;
  v_o_loc   uuid;
  v_o_x     double precision;
  v_o_y     double precision;
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

  -- HUNT-UNI (0214) HUNK B: lock STRENGTH only — the statement and the envelope are the head's
  -- either way. LIT takes FOR UPDATE so this hunt SERIALIZES against command_ship_group_go/stop's
  -- group FOR UPDATE (0208:274, 0209:66) and 0213's lit assign arm: a hunt and a go that interleave
  -- their fleet reads could BOTH mint — the exact two-fleet catastrophe this migration exists to
  -- kill, arriving by race instead of by readiness hole. Whoever commits second re-reads the leaf
  -- under the lock and sees the other's fleet. DARK keeps FOR SHARE byte-identically — the lock
  -- footprint is part of parity (the 0213 rule). AT STEP 4 (flag permanently lit): collapse to the
  -- FOR UPDATE arm.
  if v_unified then
    perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  else
    perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
  end if;
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

  -- FLEET-CONTROL (0204): the ONE marked command-ship hunk. DARK — skipped (v_fleet_control false) → 0199
  -- behavior. LIT — a fleet with zero command ships is INACTIVE and cannot hunt: reject before the
  -- destination/readiness reads (the fleet's own property).
  if v_fleet_control then
    if not exists (
      select 1 from public.main_ship_instances
       where group_id = v_group and player_id = v_player and is_command_ship
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fleet_inactive_no_command');
    end if;
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

  -- HUNT-UNI (0214) HUNK C: lit only — the hunt CONSUMES the settled unified fleet; readiness IS
  -- the fleet. Dark skips straight to the head's readiness, so the head's flow is untouched.
  -- Composes the 0213 leaf (ship_group_resolve_fleet) with ONE scan that counts and captures (one
  -- READ COMMITTED snapshot — the 0213 Finding-3 rule: never count in one statement and re-select
  -- in another). Policy over the rows:
  --   >1 → fleet_ambiguous (fail closed — the mover/brake/0213 token for this broken invariant);
  --   =1 moving/returning → group_fleet_in_flight (the mover's guard-8 twin: no hunt during a go);
  --   =1 settled → capture the origin FROM THE FLEET, consume it terminally, mint (below);
  --   =0 → fall through — the head's arms run VERBATIM (bootstrap parity: a pre-first-go group
  --        still carries per-ship dock shapes and the 0199 lit arm is the right reader for them).
  if v_unified then
    v_gf_n := 0;
    for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_group) loop
      v_gf_n := v_gf_n + 1;
    end loop;
    if v_gf_n > 1 then
      -- Two live group-shaped fleets is the broken invariant this migration exists to prevent —
      -- never mint a third on top of it. Same fail-closed token as the mover/brake/assign guard.
      return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
    end if;
    if v_gf_n = 1 then
      if v_gf.status in ('moving', 'returning') then
        -- The group's ONE fleet is under way (a go in flight, or a sortie returning). A hunt is a
        -- commitment from a settled position, not a redirect of a live leg — fail closed, the exact
        -- symmetric twin of the mover's guard 8 (0208:332-343: no go during a sortie).
        return jsonb_build_object('ok', false, 'reason', 'group_fleet_in_flight');
      end if;

      -- SETTLED. The per-ship home/stationary readiness is deliberately NOT read here: the unified
      -- mover writes no ship rows (§2), so those signals are stale echoes of the retired layer —
      -- the settled fleet IS the readiness. What survives is the hp > 0 check: lifecycle, not
      -- movement (the same split step 4c preserves when it narrows the status column).
      select count(*) into v_not_home
        from public.main_ship_instances
        where main_ship_id = any(v_members) and hp <= 0;
      if v_not_home > 0 then
        return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
      end if;

      -- Active-fleet limit EXCLUDING the fleet being consumed below AND the members' own present
      -- fleets (both are dissolved by this call — the head's launch-branch budget idiom, 0204:630-637,
      -- with the consumed unified fleet excluded on top: the sortie replaces them all, one slot net).
      v_max := coalesce(cfg_num('max_active_fleets'), 3);
      select count(*) into v_active
        from fleets
        where player_id = v_player and status in ('moving','present','returning')
          and id <> v_gf.id
          and (main_ship_id is null or not (main_ship_id = any(v_members)));
      if v_active >= v_max then
        return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
      end if;

      -- Team stats over the LOCKED members (the 0168 fold verbatim; raises → stats_invalid).
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

      -- origin_base anchors the return-to-base mechanics (the escape tick reads origin_base_id) —
      -- preferring the consumed fleet's OWN anchor (the mover's anchor idiom, 0208:451-455) so the
      -- sortie inherits the continuity of the fleet it replaces.
      select b.id, b.x, b.y, b.sector_id into v_base
        from bases b
        where b.player_id = v_player and b.status = 'active'
          and (v_gf.origin_base_id is null or b.id = v_gf.origin_base_id)
        order by b.created_at limit 1;
      if v_base.id is null then
        return jsonb_build_object('ok', false, 'reason', 'no_home_base');
      end if;

      -- ── THE ORIGIN, FROM THE FLEET (the mover's three settled arms, 0208:430-461, read the same
      --    way): present@port → the port; parked → the fleet's own coordinate; else its anchor. ──
      if v_gf.status = 'present' and v_gf.current_location_id is not null then
        select l.id, l.x, l.y, l.zone_id into v_gfl
          from locations l where l.id = v_gf.current_location_id;
        if v_gfl.id is null then
          return jsonb_build_object('ok', false, 'reason', 'invalid_origin');
        end if;
        v_o_type := 'location'; v_o_base := null; v_o_zone := v_gfl.zone_id; v_o_loc := v_gfl.id;
        v_o_x := v_gfl.x; v_o_y := v_gfl.y;
        -- the return port defaults to the port the fleet sails from (the 0199 launch-branch rule).
        v_return := coalesce(p_return_location_id, v_gf.current_location_id);
      elsif v_gf.location_mode = 'space' then
        -- Parked in open space (0208/0209) — depart the fleet's OWN coordinate. No port origin, so
        -- the return port is only what the caller chose (NULL → the reconciler's re-home path,
        -- exactly as the 0168 head's fleets carry no return_location_id).
        v_o_type := 'space'; v_o_base := null; v_o_zone := null; v_o_loc := null;
        v_o_x := v_gf.space_x; v_o_y := v_gf.space_y;
        v_return := p_return_location_id;
      else
        -- Idle at its anchor (the mover's fall-through place, 0208:447-461): depart the base.
        v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
        v_o_x := v_base.x; v_o_y := v_base.y;
        v_return := p_return_location_id;
      end if;

      -- ── WRITES (all-or-nothing) ────────────────────────────────────────────────────────────────
      -- Dissolve each member's OWN present fleet FIRST — the head's dissolve block (0204:664-676),
      -- composed verbatim, exactly as the mover composes it at every go (0208:496-520). This is NOT
      -- vestigial in the consuming path: 0213's co-location arm ALLOWS assigning a docked ship into
      -- a group whose fleet is present at the SAME port, and that assignee KEEPS its own per-ship
      -- present fleet + active presence (0213 chose guard-assignment over dissolve-at-assignment).
      -- A sortie that left that pair active would be a ship hunting AND docked at once — §0's
      -- ghost-dock duality through the hunt's own front door.
      perform presence_complete(lp.id)
        from public.fleets f
        join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
        where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
      update public.fleets
        set status = 'completed', location_mode = 'movement', active_movement_id = null,
            current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
            updated_at = now()
        where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

      -- CONSUME the settled fleet: close its dock presence and complete it — the mover's own
      -- release idiom (0208:549-557), made TERMINAL ('completed', not 'idle') because the hunt
      -- mints a NEW fleet below. The old fleet is terminal before the new one exists, in the same
      -- transaction: at-most-one live group-shaped fleet is restored BY CONSTRUCTION, and no
      -- presence is orphaned (§0's ghost-dock class — asserted by HUNTUNI_PASS_NOGHOSTDOCK).
      perform presence_complete(lp.id)
        from public.location_presence lp
        where lp.fleet_id = v_gf.id and lp.status = 'active';
      update public.fleets
        set status = 'completed', location_mode = 'movement', active_movement_id = null,
            space_x = null, space_y = null,
            current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
            updated_at = now()
        where id = v_gf.id;

      -- ONE team fleet (main_ship_id NULL; members carried by the manifest) — the head's own mint,
      -- with the origin captured from the consumed fleet instead of a per-ship dock join.
      insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id, return_location_id)
        values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group, v_return)
        returning id into v_fleet;

      v_movement := movement_create(
        v_player, v_fleet,
        v_o_type, v_o_base, v_o_zone, v_o_loc, v_o_x, v_o_y,
        'location', null, null, v_loc.id, v_loc.x, v_loc.y,
        'hunt_pirates', v_speed);
      perform fleet_set_moving(v_fleet, v_movement);

      -- The hunt's ship write, KEPT lit (the head's own statement, verbatim): 'hunting' is the
      -- sortie/combat layer's signal — the 0199 reconciler selects on it and shield regen excludes
      -- it — NOT the movement layer §2 retires. IT RETIRES AT STEP 4c with the status-column
      -- narrowing; do not delete it before the reconciler stops reading it.
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
    -- v_gf_n = 0 → fall through: the head's readiness + launch arms run VERBATIM (bootstrap parity).
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
revoke execute on function public.send_ship_group_hunt(uuid, uuid, uuid) from public, anon;
grant  execute on function public.send_ship_group_hunt(uuid, uuid, uuid) to authenticated;

-- ── §2) self-assert (deploy-time, raises on failure — the 0204:805 / 0213 idiom) ──────────────────
do $huntuni$
declare
  v_src   text;
  v_hunts int;
  v_decl int; v_lupd int; v_lshr int; v_leaf int; v_amb int; v_infl int;
  v_mlock int; v_cons int; v_mint int; v_ready int; v_launch int;
begin
  -- (a) send_ship_group_hunt: single definition, 3-arg, authenticated-executable.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'send_ship_group_hunt') <> 1 then
    raise exception 'HUNT-UNI self-assert FAIL: send_ship_group_hunt is not a single definition'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.send_ship_group_hunt(uuid, uuid, uuid)'::regprocedure;
  if not has_function_privilege('authenticated', 'public.send_ship_group_hunt(uuid, uuid, uuid)', 'execute') then
    raise exception 'HUNT-UNI self-assert FAIL: send_ship_group_hunt not authenticated-executable'; end if;

  -- (b) the 0204 head survives (parity is RETENTION of the head, hunks are ADDITIONS to it): the
  --     FLEET-CONTROL gate + token, the NOHOME gate + BOTH readiness arms, and the 0168 dark head's
  --     6-column fleet insert (the 7-column Hunk-C/launch insert does NOT satisfy this string).
  if position('v_fleet_control boolean := public.cfg_bool(''fleet_control_enabled'')' in v_src) = 0
     or position('fleet_inactive_no_command' in v_src) = 0
     or position('v_launch_from_dock boolean := public.cfg_bool(''launch_from_dock_enabled'')' in v_src) = 0
     or position('not (status = ''home'' or (status = ''stationary'' and spatial_state = ''at_location''))' in v_src) = 0
     or position('status <> ''home'' or hp <= 0' in v_src) = 0
     or position('insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)' in v_src) = 0 then
    raise exception 'HUNT-UNI self-assert FAIL: the 0204 head did not survive (fleet-control / NOHOME readiness arms / the 0168 dark insert)'; end if;

  -- (c) the three hunks exist: the gate read, BOTH lock arms, the leaf compose, both reject tokens,
  --     the lifecycle-only hp check, and the 4c retirement note on the kept ship write.
  if position('v_unified boolean := public.cfg_bool(''fleet_movement_unified_enabled'')' in v_src) = 0
     or position('player_id = v_player for update' in v_src) = 0
     or position('player_id = v_player for share' in v_src) = 0
     or position('ship_group_resolve_fleet' in v_src) = 0
     or position('fleet_ambiguous' in v_src) = 0
     or position('group_fleet_in_flight' in v_src) = 0
     or position('main_ship_id = any(v_members) and hp <= 0' in v_src) = 0
     or position('IT RETIRES AT STEP 4c' in v_src) = 0 then
    raise exception 'HUNT-UNI self-assert FAIL: a 0214 hunk is missing (gate read / gated lock arms / leaf compose / reject tokens / hp-only check / 4c note)'; end if;

  -- (d) ORDER: declare → lit lock → dark lock → member lock → leaf → ambiguous → in-flight →
  --     consume → mint → the head's readiness → the head's launch branch. Hunk C must sit BETWEEN
  --     the member lock and the head's readiness (a consume after the head's per-ship readiness
  --     would re-open the defect: stale signals rejecting a settled fleet), and the consume must
  --     precede the mint (terminal-before-new is the at-most-one construction).
  v_decl   := position('v_unified boolean := public.cfg_bool(''fleet_movement_unified_enabled'')' in v_src);
  v_lupd   := position('player_id = v_player for update' in v_src);
  v_lshr   := position('player_id = v_player for share' in v_src);
  v_mlock  := position(') locked;' in v_src);
  v_leaf   := position('ship_group_resolve_fleet' in v_src);
  v_amb    := position('fleet_ambiguous' in v_src);
  v_infl   := position('group_fleet_in_flight' in v_src);
  v_cons   := position('set status = ''completed''' in v_src);
  v_mint   := position('current_base_id, group_id, return_location_id)' in v_src);
  v_ready  := position('if v_launch_from_dock then' in v_src);
  v_launch := position('if v_launch_from_dock and v_docked > 0 then' in v_src);
  if not (v_decl > 0 and v_decl < v_lupd and v_lupd < v_lshr and v_lshr < v_mlock
          and v_mlock < v_leaf and v_leaf < v_amb and v_amb < v_infl and v_infl < v_cons
          and v_cons < v_mint and v_mint < v_ready and v_ready < v_launch) then
    raise exception 'HUNT-UNI self-assert FAIL: hunk order broken (decl=%, for-update=%, for-share=%, member-lock=%, leaf=%, ambiguous=%, in-flight=%, consume=%, mint=%, readiness=%, launch=%)',
      v_decl, v_lupd, v_lshr, v_mlock, v_leaf, v_amb, v_infl, v_cons, v_mint, v_ready, v_launch; end if;

  -- (e) the hunt's ship write survives in ALL THREE mint paths (Hunk C + the NOHOME launch branch +
  --     the 0168 dark head) — 'hunting' is the sortie layer's signal until 4c retires it; a path
  --     that silently dropped it would strand the reconciler.
  v_hunts := (length(v_src) - length(replace(v_src, 'set status = ''hunting''', ''))) / length('set status = ''hunting''');
  if v_hunts <> 3 then
    raise exception 'HUNT-UNI self-assert FAIL: expected the status=hunting write in exactly 3 mint paths, found %', v_hunts; end if;

  -- (f) the 0213 leaf is still deployed, shape-keyed, and internal-only (this migration composes
  --     it; it must not have been re-created or granted on the way).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'ship_group_resolve_fleet') <> 1 then
    raise exception 'HUNT-UNI self-assert FAIL: ship_group_resolve_fleet not deployed (or not a single definition)'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.ship_group_resolve_fleet(uuid, uuid)'::regprocedure;
  if position('main_ship_id is null' in v_src) = 0 then
    raise exception 'HUNT-UNI self-assert FAIL: the leaf lost the main_ship_id IS NULL key'; end if;
  if has_function_privilege('anon', 'public.ship_group_resolve_fleet(uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.ship_group_resolve_fleet(uuid, uuid)', 'execute') then
    raise exception 'HUNT-UNI self-assert FAIL: ship_group_resolve_fleet is client-callable (internal leaf: no grants)'; end if;

  -- (g) the resolver's fail-closed NULL is UNTOUCHED (the fix this obligation forbids: loosening
  --     0210:90-92 so two fleets "resolve" to one). Pinned here so a future edit to THIS file
  --     cannot smuggle the loosening in alongside the hunt.
  select prosrc into v_src from pg_proc where oid = 'public.mainship_resolve_fleet(uuid)'::regprocedure;
  if position('return null;  -- fail closed' in v_src) = 0 then
    raise exception 'HUNT-UNI self-assert FAIL: mainship_resolve_fleet lost its fail-closed NULL — the resolver may not be loosened'; end if;

  raise notice 'HUNT-UNI self-assert ok: 0204 head intact + hunks A/B/C in decl->lock->leaf->ambiguous->in-flight->consume->mint->readiness->launch order; hunting write in all 3 mint paths; leaf shape-keyed internal-only; resolver fail-closed NULL untouched';
end $huntuni$;
