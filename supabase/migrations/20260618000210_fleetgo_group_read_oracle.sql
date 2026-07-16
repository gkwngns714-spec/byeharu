-- FLEET-GO 3c-1 — THE READ ORACLE LEARNS THAT A SHIP'S PLACE IS ITS FLEET'S PLACE.
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §2 + §3 step 3c (rewritten 2026-07-16 after the recon).
-- Follows 0207 (the mover), 0208 (the fleet's position + coordinate targets), 0209 (the brake).
--
-- THE GAP THIS CLOSES. §2 says a ship's location IS its fleet's location. But every read that answers
-- "where is my ship / is it docked" resolves the fleet with `fleets.main_ship_id = <ship>` — which is
-- NULL on a unified fleet by construction. So today a member of a unified group has NO per-ship fleet
-- (0208 dissolves them on departure) and mainship_space_validate_context falls to
-- `v_count = 0 and v_st = 'home'` → **'legacy_home'**, which get_my_fleet_positions maps to
-- place='hidden' (0200:120-121). THE WHOLE GROUP VANISHES FROM THE MAP ON ARRIVAL, and PortScreen's
-- port list empties. The mover works; the game just cannot SEE it. §3 never mentioned this function —
-- the 5-agent recon found it, and it is the widest blast radius in the charter: validate_context is the
-- transitive authority behind get_my_docked_store, get_my_current_dock_services,
-- mainship_resolve_docked_location (→ the three trade RPCs), get_my_fleet_positions,
-- get_osn_movement_readiness, and the settled-safe rules for mining/exploration.
--
-- (Recon note, corrected here: one sweep reported members resolving to 'contradictory_state'. Read the
-- code: `if v_count = 0 and v_st = 'home'` fires FIRST, so it is 'legacy_home' — ok:true, but hidden.
-- Same bug, different symptom; the fix is the same. Recorded so the next reader is not confused by a
-- stale claim.)
--
-- WHAT THIS DOES. Adds mainship_resolve_fleet — the ONE ship→fleet resolver — and teaches the oracle to
-- use it. Under §2 the answer is simply: the ship's fleet is its GROUP's fleet.
--
-- DARK + PARITY. The whole group branch sits behind cfg_bool('fleet_movement_unified_enabled'). Flag
-- OFF → the 0056 body runs VERBATIM and every one of those ten surfaces is byte-identical. This is
-- 0208's SETTLEPARITY pattern: a dark-first parity branch on ONE resolver, deleted at step 4 — NOT a
-- per-command readiness branch (§4). It composes; it does not gate around.

-- ── 1. THE ONE ship→fleet resolver ───────────────────────────────────────────────────────────────
create or replace function public.mainship_resolve_fleet(p_main_ship_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_player uuid;
  v_group  uuid;
  v_fleet  uuid;
  v_n      integer;
begin
  select player_id, group_id into v_player, v_group
    from public.main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then return null; end if;

  -- (1) §2: the ship's fleet IS its group's fleet. Keyed group_id + main_ship_id IS NULL — NOT group_id
  --     alone: the legacy expedition send tags group_id onto PER-MEMBER fleets (0204:316, display-only,
  --     "routing never reads it"), so group_id alone would match N member envelopes.
  if v_group is not null then
    select count(*) into v_n
      from public.fleets
     where group_id = v_group and player_id = v_player and main_ship_id is null
       and status in ('idle', 'moving', 'present', 'returning');
    if v_n > 1 then
      return null;  -- fail closed: two live unified fleets for one group is a broken invariant
    end if;
    if v_n = 1 then
      select id into v_fleet
        from public.fleets
       where group_id = v_group and player_id = v_player and main_ship_id is null
         and status in ('idle', 'moving', 'present', 'returning');
      return v_fleet;
    end if;
  end if;

  -- (2) TRANSITION FALLBACK — the ship's OWN per-ship fleet.
  --     DELETE THIS BRANCH AT STEP 4. Under §2 a ship has no fleet of its own; this exists only while
  --     the per-ship layer is still alive, so that an ungrouped ship (commission never sets group_id —
  --     0160:53) and a group with no unified fleet yet still resolve. Once 4b lands and every ship is a
  --     member of a group with a fleet, this is dead code and its presence would be a lie.
  select count(*) into v_n
    from public.fleets
   where main_ship_id = p_main_ship_id and status in ('idle', 'moving', 'present', 'returning');
  if v_n <> 1 then
    return null;  -- 0 or >1 → no single coherent fleet (the 0056 multiple_active_fleets posture)
  end if;
  select id into v_fleet
    from public.fleets
   where main_ship_id = p_main_ship_id and status in ('idle', 'moving', 'present', 'returning');
  return v_fleet;
end;
$function$;

comment on function public.mainship_resolve_fleet(uuid) is
  'FLEET-GO 3c (charter §2): the ONE ship->fleet resolver. A ship''s fleet IS its group''s unified fleet '
  '(group_id + main_ship_id IS NULL); falls back to the ship''s own per-ship fleet ONLY during the '
  'transition — that fallback is deleted at step 4. Fails closed (NULL) on any ambiguity.';

revoke all on function public.mainship_resolve_fleet(uuid) from public;

-- ── 2. the oracle: dark-branched. Flag OFF → the 0056 body, verbatim. ────────────────────────────
create or replace function public.mainship_space_validate_context(p_main_ship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ship   main_ship_instances%rowtype;
  v_fleet  fleets%rowtype;
  v_count  integer := 0;
  v_mv     main_ship_space_movements%rowtype;
  v_pres   location_presence%rowtype;
  v_ss     text;
  v_st     text;
  v_has_legacy boolean := false;
  v_coord  boolean;
  v_presact boolean;
  fail     constant text := 'contradictory_state';
  -- FLEET-GO 3c-1 additions:
  v_ufleet fleets%rowtype;
  v_upres  location_presence%rowtype;
begin
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;
  v_ss := v_ship.spatial_state; v_st := v_ship.status;

  -- ★ THE FLEET-GO 3c BRANCH — dark by default; the 0056 head below is untouched. ★
  -- §2: the ship's place IS its fleet's place. When the ship is a member of a group that HAS a unified
  -- fleet, that fleet is the entire answer and the ship's own movement signals are IGNORED — they are
  -- the retired layer, and the mover never writes them (0208). 'destroyed' is checked first because it
  -- is LIFECYCLE, not movement: it stays the ship's own truth under §2 and survives step 4c.
  if public.cfg_bool('fleet_movement_unified_enabled') and v_ship.group_id is not null then
    select * into v_ufleet
      from public.fleets
     where group_id = v_ship.group_id and player_id = v_ship.player_id and main_ship_id is null
       and status in ('idle', 'moving', 'present', 'returning');
    if found then
      if v_st = 'destroyed' or v_ss = 'destroyed' then
        return jsonb_build_object('ok', true, 'state', 'destroyed');
      end if;

      -- docked: the fleet is present at a port AND carries the matching active presence.
      if v_ufleet.status = 'present' and v_ufleet.location_mode = 'location'
         and v_ufleet.current_location_id is not null then
        select * into v_upres from public.location_presence
         where fleet_id = v_ufleet.id and status = 'active';
        if v_upres.id is null or v_upres.location_id is distinct from v_ufleet.current_location_id then
          return jsonb_build_object('ok', false, 'reason', fail);
        end if;
        return jsonb_build_object('ok', true, 'state', 'at_location');
      end if;

      -- parked in open space at the fleet's OWN coordinate (0208). Note the position is read from the
      -- FLEET, never the ship — that is §2 stated as a read.
      if v_ufleet.location_mode = 'space' then
        if v_ufleet.space_x is null or v_ufleet.space_y is null then
          return jsonb_build_object('ok', false, 'reason', fail);
        end if;
        return jsonb_build_object('ok', true, 'state', 'in_space');
      end if;

      -- under way on the legacy/fleet spine (the only spine the unified mover uses — it never creates a
      -- main_ship_space_movements row, so 'in_transit' would be a lie about which domain it is in).
      if v_ufleet.status in ('moving', 'returning') and v_ufleet.active_movement_id is not null then
        return jsonb_build_object('ok', true, 'state', 'legacy_transit');
      end if;

      -- an idle fleet at its anchor: coherent, and the mover's `else` origin branch departs from it.
      if v_ufleet.status = 'idle' then
        return jsonb_build_object('ok', true, 'state', 'legacy_home');
      end if;

      return jsonb_build_object('ok', false, 'reason', fail);
    end if;
    -- no unified fleet for this group → fall through to the 0056 head (the transition case).
  end if;

  -- ══════ 0056 HEAD — byte-identical below this line. Do not edit; parity is pinned by the proof. ══════
  select count(*) into v_count from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
  if v_count > 1 then return jsonb_build_object('ok', false, 'reason', 'multiple_active_fleets'); end if;
  if v_count = 1 then select * into v_fleet from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning'); end if;

  select * into v_mv from main_ship_space_movements where main_ship_id = p_main_ship_id and status = 'moving';
  v_coord := v_mv.id is not null;
  if v_count = 1 then
    select * into v_pres from location_presence where fleet_id = v_fleet.id and status = 'active';
    v_has_legacy := exists (select 1 from fleet_movements where fleet_id = v_fleet.id and status = 'moving');
  end if;
  v_presact := v_pres.id is not null;

  -- DESTROYED (legacy: status destroyed, ss null | new-domain: ss destroyed)
  if v_st = 'destroyed' or v_ss = 'destroyed' then
    if v_coord or v_presact or v_count > 0 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'destroyed');
  end if;

  -- NEW-DOMAIN states (non-null spatial_state)
  if v_ss = 'in_space' then
    if v_st <> 'stationary' or v_count > 0 or v_coord or v_presact then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_ship.space_x is null or v_ship.space_y is null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'in_space');
  elsif v_ss = 'at_location' then
    if v_st <> 'stationary' or v_count <> 1 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.status <> 'present' or v_fleet.location_mode <> 'location' or v_fleet.current_location_id is null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.active_movement_id is not null or v_fleet.active_space_movement_id is not null or v_coord then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if not v_presact or v_pres.location_id is distinct from v_fleet.current_location_id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'at_location');
  elsif v_ss = 'in_transit' then
    if v_st <> 'traveling' or v_count <> 1 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.status <> 'moving' or v_fleet.location_mode <> 'movement' or v_fleet.active_movement_id is not null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if not v_coord or v_fleet.active_space_movement_id is distinct from v_mv.id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_mv.fleet_id is distinct from v_fleet.id or v_mv.main_ship_id is distinct from v_ship.main_ship_id or v_mv.player_id is distinct from v_ship.player_id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_presact or v_has_legacy then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'in_transit');
  elsif v_ss = 'home' then
    if v_st <> 'home' or v_count > 0 or v_coord or v_presact then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'home');
  elsif v_ss is not null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_spatial_state');
  end if;

  -- LEGACY (spatial_state IS NULL)
  if v_count = 0 and v_st = 'home' then
    return jsonb_build_object('ok', true, 'state', 'legacy_home');
  end if;
  if v_count = 1 and v_fleet.status = 'present' and v_fleet.current_location_id is not null
     and v_presact and v_pres.location_id is not distinct from v_fleet.current_location_id then
    return jsonb_build_object('ok', true, 'state', 'legacy_present');
  end if;
  if v_count = 1 and v_fleet.status in ('moving','returning') and v_has_legacy then
    return jsonb_build_object('ok', true, 'state', 'legacy_transit');
  end if;
  -- legacy NULL but nothing coherent → not an actionable origin context
  return jsonb_build_object('ok', false, 'reason', fail);
end;
$function$;

-- ── 3. the dock resolver reads the RESOLVED fleet, not `main_ship_id = <ship>` ───────────────────
-- Its own validate_context gate already does the coherence work (composed, 0092's design). The ONE
-- delta: the location now comes from mainship_resolve_fleet's answer, so a docked GROUP resolves its
-- port. Dark → mainship_resolve_fleet's transition fallback returns the ship's own per-ship fleet, which
-- is the exact row the old query selected → byte-identical.
create or replace function public.mainship_resolve_docked_location(p_main_ship_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_ctx jsonb;
  v_loc uuid;
begin
  -- The ship must be canonically DOCKED (at_location): validate_context proves fleet + presence + movement
  -- coherence, then the dock comes STRICTLY from the validated present/location fleet's current_location_id
  -- (never the client). Returns the docked location id, or NULL if not at_location or no matching fleet row —
  -- both null paths collapse to one NULL (each caller already returned the same 'not_docked' reason for both).
  v_ctx := public.mainship_space_validate_context(p_main_ship_id);
  if (v_ctx->>'ok')::boolean is not true or (v_ctx->>'state') is distinct from 'at_location' then
    return null;
  end if;
  -- FLEET-GO 3c-1: resolve through the ONE ship→fleet resolver instead of `f.main_ship_id = <ship>`
  -- (NULL on a unified fleet). Same row as before while dark — the fallback IS the per-ship fleet.
  select f.current_location_id into v_loc
    from public.fleets f
   where f.id = public.mainship_resolve_fleet(p_main_ship_id)
     and f.status = 'present' and f.location_mode = 'location'
   limit 1;
  return v_loc;
end;
$function$;
