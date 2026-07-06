-- Byeharu — TRADE-FLEET-0C §2.5: per-ship command conversion — the two READ projections (#4, #5).
--
-- Second §2.5 commit: convert the two READ-ONLY projections get_my_current_dock_services (#4) and
-- get_osn_movement_readiness (#5). They have no locks/idempotency, share the identical mechanic, and
-- reuse the shared mainship_resolve_owned_ship helper (created in 0081). Each gains a TRAILING
-- `p_main_ship_id uuid default null`, so existing zero-arg callers keep working (default null →
-- sole-ship shim) — no commit is broken, no src/ change until TRADE-UI-1.
--
-- ── DESIGN DECISION (planner authority — implements §2.5; carries the reviewer caveat) ────────────
-- Each command resolves its ship via mainship_resolve_owned_ship(auth.uid(), p_main_ship_id):
--   • explicit p_main_ship_id → ownership asserted server-side (UI selection never trusted);
--   • null → sole ship ONLY when the player has exactly one; zero/>1 → null → fail closed.
-- For these two reads, a null resolution (no JWT OR no ship OR ambiguous) returns each site's EXISTING
-- no-ship projection VERBATIM — collapsing the former separate no-auth and no-ship early-returns (which
-- returned the IDENTICAL projection) into one resolver-null check. The no-JWT contract is preserved:
-- auth.uid() null → resolver null → the same no-ship projection (readiness still yields
-- coordinate_travel_available=false, so the frozen PORT-ENTRY RDN_COORD_NOAUTH=false probe is unaffected).
--
-- FROZEN VERIFIERS (out of this loop's scope; repointed at the DEPLOY-TIME human gate): the PORT-ENTRY-1
-- production gate AND the dispatch-only OSN3/PORT-LAUNCH realchain-perm / postenable verifiers that pin
-- pre-0C main-ship RPC signatures via ::regprocedure / to_regprocedure / has_function_privilege('…()')
-- truthfully describe DEPLOYED production (0072) and are NOT edited here. Every pin these §2.5
-- conversions invalidate against a 0C-applied DB is recorded in docs/TRADE_FLEET_0C_VERIFIER_REPOINT.md
-- so nothing is lost; the post-0C surface is proven by the forthcoming TRADE-FLEET verifier. This
-- migration touches NO verifier file. Abstract columns, flags, and src/ are untouched. DARK: explicit
-- selection is inert while every player has ≤ 1 ship.

-- ── A. get_my_current_dock_services (#4) — resolver swap; existing no_main_ship projection preserved.
drop function if exists public.get_my_current_dock_services();
create function public.get_my_current_dock_services(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     uuid;
  v_ctx      jsonb;
  v_ok       boolean;
  v_vstate   text;
  v_loc      uuid;
  v_name     text;
  v_services jsonb;
  c_empty    constant jsonb := '[]'::jsonb;
begin
  -- (1) §2.5: resolve the SELECTED owned ship (explicit p_main_ship_id, ownership asserted server-side) or
  -- the sole ship (shim); UI selection is never trusted. Null (no JWT / unowned / zero / ambiguous >1) →
  -- the existing no_main_ship projection, verbatim.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'services',c_empty);
  end if;

  -- (2) the canonical validated ship context (coherence-checked: fleet + presence + movement).
  v_ctx    := public.mainship_space_validate_context(v_ship);
  v_ok     := (v_ctx->>'ok')::boolean;
  v_vstate := v_ctx->>'state';

  -- (3) docked ONLY for the new-domain 'at_location' state.
  if v_ok is true and v_vstate = 'at_location' then
    -- derive the dock STRICTLY from the validated fleet.current_location_id (validate_context already proved
    -- the fleet is present/location with an active presence at this location).
    select f.current_location_id into v_loc
      from public.fleets f
      where f.main_ship_id = v_ship and f.status = 'present' and f.location_mode = 'location'
      limit 1;
    if v_loc is null then
      return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'services',c_empty);
    end if;
    select l.name into v_name from public.locations l where l.id = v_loc;
    select coalesce(jsonb_agg(s.service order by s.service), c_empty)
      into v_services
      from public.location_services s
      where s.location_id = v_loc and s.status = 'active';   -- ACTIVE services only
    return jsonb_build_object(
      'state','at_location','docked',true,
      'location_id',v_loc,'location_name',v_name,
      'services',coalesce(v_services, c_empty));
  elsif v_ok is true and v_vstate in ('in_transit','in_space','destroyed') then
    return jsonb_build_object('state',v_vstate,'docked',false,'location_id',null,'location_name',null,'services',c_empty);
  else
    -- home / legacy_home / legacy_present / contradictory_state / unknown / ship_not_found → no port surface.
    return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'services',c_empty);
  end if;
end;
$$;

revoke execute on function public.get_my_current_dock_services(uuid) from public, anon;
grant  execute on function public.get_my_current_dock_services(uuid) to authenticated;

-- ── B. get_osn_movement_readiness (#5) — resolver swap; existing no_ship projection preserved (incl. no-JWT).
drop function if exists public.get_osn_movement_readiness();
create function public.get_osn_movement_readiness(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_origin jsonb;
  v_cat    text;
  v_cur    uuid;           -- current docked location (excluded from destinations); NULL unless docked
  v_flag   boolean;
  v_avail  boolean := false;
  v_coord_flag  boolean;   -- OSN-COORD-ENABLE-1B: server-owned coordinate gate (migration 0070; false on live)
  v_coord_avail boolean := false;  -- additive readiness capability; never true unless osn_available is true
  v_reason text;
  v_dests  uuid[] := '{}';
begin
  -- §2.5: resolve the SELECTED owned ship or the sole ship (shim); UI selection is never trusted. Null
  -- (no JWT / unowned / zero / ambiguous >1) → the existing no_ship projection, verbatim — so the no-JWT
  -- contract (coordinate_travel_available=false) is preserved for the frozen PORT-ENTRY probe.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('origin_category', 'no_ship', 'osn_available', false,
                              'reason', 'no_ship', 'eligible_destination_ids', '[]'::jsonb,
                              'coordinate_travel_available', false);
  end if;

  -- Single authoritative source of origin truth (service_role-only; callable here via SECURITY DEFINER).
  v_origin := public.mainship_space_resolve_origin(v_ship);
  if (v_origin->>'ok')::boolean is true then
    v_cat := 'anchored';
    if v_origin->>'origin_kind' = 'location' then
      v_cur := (v_origin->>'origin_location_id')::uuid;   -- exclude the port we are docked at
    end if;
  else
    v_cat := case v_origin->>'reason'
               when 'origin_not_anchored'  then 'not_anchored'
               when 'in_transit_must_stop' then 'in_transit'
               when 'destroyed'            then 'destroyed'
               else 'not_anchored'   -- contradictory_state / any other → safe generic (cannot move)
             end;
  end if;

  v_flag  := coalesce(public.cfg_bool('mainship_space_movement_enabled'), false);
  v_avail := (v_flag and v_cat = 'anchored');

  -- OSN-COORD-ENABLE-1B: the additive coordinate-travel readiness capability. Derived from the EXISTING OSN
  -- readiness decision (v_avail) AND the server-owned coordinate gate, so it inherits the anchored-origin and
  -- movement-domain checks exactly and fails closed for any non-actionable origin. Read-only; writes nothing.
  v_coord_flag  := coalesce(public.cfg_bool('mainship_coordinate_travel_enabled'), false);
  v_coord_avail := (v_avail and v_coord_flag);

  v_reason := case
                when v_cat = 'destroyed'                  then 'destroyed'
                when v_cat = 'in_transit'                 then 'in_transit'
                when v_cat = 'not_anchored'               then 'travel_to_port'
                when v_cat = 'anchored' and not v_flag     then 'feature_disabled'
                else 'none'
              end;

  -- Eligible visible destinations ONLY when anchored. mainship_space_location_target_legal requires the
  -- target to be an ACTIVE city|port with activity 'none' + one active docking service + one active anchor,
  -- so hidden ports (status<>'active') and ordinary non-port locations are excluded by construction — no
  -- hidden-port id, anchor, or coordinate is ever returned.
  if v_cat = 'anchored' then
    select coalesce(array_agg(l.id), '{}')
      into v_dests
      from public.locations l
      where l.status = 'active'
        and l.id is distinct from v_cur
        and (public.mainship_space_location_target_legal(l.id)->>'ok')::boolean is true;
  end if;

  return jsonb_build_object(
    'origin_category', v_cat,
    'osn_available', v_avail,
    'reason', v_reason,
    'eligible_destination_ids', to_jsonb(v_dests),
    'coordinate_travel_available', v_coord_avail);
end;
$$;

revoke execute on function public.get_osn_movement_readiness(uuid) from public, anon;
grant  execute on function public.get_osn_movement_readiness(uuid) to authenticated;
