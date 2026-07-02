-- Byeharu — TRADE-FLEET-0C §2.5: per-ship command conversion — normalize_main_ship_dock (#7, LAST active site).
--
-- Final §2.5 active-path conversion: normalize_main_ship_dock (#7) gains a TRAILING
-- `p_main_ship_id uuid default null`, resolving its ship via the shared mainship_resolve_owned_ship helper
-- (created in 0081). Backward compatible (zero-arg call → default null → sole-ship shim) — no commit is
-- broken, no src/ change until TRADE-UI-1. This COMPLETES the §2.5 command-signature conversion: the six
-- active sites (#2–#7) are converted; #1 command_main_ship_space_move stays DEFERRED/dark (its coordinate
-- gate rejects before any ship read).
--
-- ── DESIGN DECISION (planner authority — implements §2.5) ─────────────────────────────────────────
-- Resolve via mainship_resolve_owned_ship(auth.uid(), p_main_ship_id): explicit selection → ownership
-- asserted server-side (UI never trusted); null → sole ship only when the player has exactly one; zero/>1
-- → null → the EXISTING {ok:false, reason:'no_ship'} shape, verbatim. The distinct not_authenticated
-- early-return and the entire lock/normalization/coherence-gate flow are preserved byte-for-byte; the
-- per-ship lock (mainship_space_lock_context) now locks the SELECTED ship, never a derived one.
--
-- ── FROZEN VERIFIERS + md5 PIN REPOINT (deploy-time human gate; out of this loop's scope) ─────────
-- normalize_main_ship_dock is one of the THREE PORT-ENTRY prosrc md5-pinned bodies. Changing its body
-- invalidates its md5 pin against a 0C-applied DB — like port_entry_commission_writer's (changed in 0077).
-- Both md5 pins are RE-DERIVED at the deploy-time human gate; commission_first_main_ship's body was NOT
-- changed by 0C, so its md5 pin remains valid. The PORT-ENTRY-1 production gate and the dispatch-only
-- OSN3/PORT-LAUNCH realchain-perm/postenable verifiers stay FROZEN (they describe deployed 0072); every pin
-- these §2.5 conversions invalidate is recorded in docs/TRADE_FLEET_0C_VERIFIER_REPOINT.md. This migration
-- touches NO verifier file. Abstract columns, flags, and src/ are untouched. DARK: explicit selection is
-- inert while every player has ≤ 1 ship.

drop function if exists public.normalize_main_ship_dock();
create function public.normalize_main_ship_dock(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_lock   jsonb;
  v_ctx    jsonb;
  v_state  text;
  v_fleet  uuid;
  v_loc    uuid;
  v_zone   uuid;
  v_sector uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- §2.5: resolve the SELECTED owned ship (explicit p_main_ship_id, ownership asserted server-side) or the
  -- sole ship (shim); UI selection is never trusted. Null (unowned / zero / ambiguous >1) → no_ship, verbatim.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'no_ship');
  end if;

  -- Phase A: acquire the canonical OSN context locks (ship → relevant fleet → space movement → presence;
  -- legacy movement is an existence check only) BEFORE classifying, so a concurrent legacy-arrival serializes.
  v_lock := public.mainship_space_lock_context(v_ship);
  v_ctx  := public.mainship_space_validate_context(v_ship);
  v_state := case when (v_ctx->>'ok')::boolean is true then v_ctx->>'state' else null end;

  -- idempotent replay: already canonical → no write.
  if v_state = 'at_location' then
    return jsonb_build_object('ok', true, 'normalized', false);
  end if;

  -- ONLY a coherent legacy_present ship may normalize; everything else fails closed with no write.
  if v_state is distinct from 'legacy_present' then
    return jsonb_build_object('ok', false, 'normalized', false, 'reason', 'not_normalizable',
                              'state', coalesce(v_state, 'noncanonical'));
  end if;

  -- The current location comes ONLY from the coherent existing legacy-present fleet (locked above) — never the
  -- client. Read it from the single relevant fleet the lock-context resolved.
  v_fleet := (v_lock->>'relevant_fleet_id')::uuid;
  if v_fleet is null then
    return jsonb_build_object('ok', false, 'normalized', false, 'reason', 'not_normalizable');
  end if;
  select current_location_id, current_zone_id, current_sector_id into v_loc, v_zone, v_sector
    from public.fleets where id = v_fleet;
  if v_loc is null then
    return jsonb_build_object('ok', false, 'normalized', false, 'reason', 'not_normalizable');
  end if;

  -- Phase B: lock the CURRENT location's hierarchy (same canonical order) and REVALIDATE it is still a legal
  -- dockable port AFTER the locks are held, immediately before mutation. Ineligible/inactive/hidden/non-port →
  -- fail closed, no write. (No resolve_origin: a normalizer asserts the at_location invariant, not depart-origin.)
  perform 1 from public.sectors           where id = v_sector for share;
  perform 1 from public.zones             where id = v_zone   for share;
  perform 1 from public.locations         where id = v_loc    for share;
  perform 1 from public.space_anchors     where location_id = v_loc and kind = 'location' and status = 'active' for share;
  perform 1 from public.location_services where location_id = v_loc and service = 'docking' and status = 'active' for share;
  if (public.mainship_space_location_target_legal(v_loc)->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'normalized', false, 'reason', 'ineligible_port');
  end if;

  -- Convert ONLY the required ship state into canonical at_location form; REUSE the existing fleet + presence
  -- (no new fleet, presence, movement, receipt, or coordinate). Defensively clear movement pointers.
  update public.main_ship_instances
    set status = 'stationary', spatial_state = 'at_location', space_x = null, space_y = null, updated_at = now()
    where main_ship_id = v_ship;
  update public.fleets
    set status = 'present', location_mode = 'location', active_movement_id = null, active_space_movement_id = null,
        current_base_id = null, updated_at = now()
    where id = v_fleet;

  if (public.mainship_space_validate_context(v_ship)->>'state') is distinct from 'at_location' then
    raise exception 'normalize_main_ship_dock: post-write state is not canonical at_location';
  end if;

  return jsonb_build_object('ok', true, 'normalized', true, 'location_id', to_jsonb(v_loc));
end;
$$;

revoke execute on function public.normalize_main_ship_dock(uuid) from public, anon;
grant  execute on function public.normalize_main_ship_dock(uuid) to authenticated;
