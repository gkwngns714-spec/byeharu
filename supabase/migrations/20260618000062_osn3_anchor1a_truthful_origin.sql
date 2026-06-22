-- Byeharu — OSN-ANCHOR-1A: truthful-origin guard. Replaces ONLY the private origin resolver's legacy-origin
-- success branches. flag-dark.
--
-- PROVEN DEFECT (OSN-ANCHOR-0): public.mainship_space_resolve_origin copied LEGACY map coordinates into OSN
-- movement origins — bases.x/y for home/legacy_home, locations.x/y for at_location/legacy_present — which
-- then drove movement distance, travel time, and the client in-transit interpolation. Legacy coordinates are
-- NOT canonical OSN positions. This migration makes the resolver TRUTHFUL: until an authoritative canonical
-- anchor exists (future ANCHOR work), those origins are rejected with reason 'origin_not_anchored'. in_space
-- remains the ONLY valid origin (its space_x/space_y are authoritative canonical OSN coordinates set by a
-- prior arrival).
--
-- SCOPE (narrow, dark):
--   • CREATE OR REPLACE of the EXISTING private resolver ONLY — same signature, SECURITY DEFINER,
--     search_path=public. Per Postgres semantics, CREATE OR REPLACE FUNCTION preserves the function's
--     OWNERSHIP and EXECUTE privileges; this is the existing service_role-only grant. No new function is
--     created, so nothing default-grants to PUBLIC → NO revoke/regrant block is required and NO grant is
--     widened. (The disposable real-chain proof captures the resolver's owner/SECDEF/search_path/ACL/
--     signature and asserts parity — we do not merely assume CREATE OR REPLACE is safe.)
--   • NO anchor table, NO columns on bases/locations, NO coordinate seed/backfill, NO legacy fallback.
--   • target_kind, the writer (mainship_space_begin_move), the arrival processor, and DOCK-0 are UNCHANGED.
--   • Dark: mainship_space_begin_move checks the feature flag (step 6) BEFORE calling the resolver (step 9),
--     and mainship_space_movement_enabled stays FALSE in production → the resolver is unreached there.
--
-- RESULT TABLE (by mainship_space_validate_context state):
--   home / legacy_home / at_location / legacy_present → {ok:false, reason:'origin_not_anchored'}   (was: base/location coords)
--   in_space                                          → {ok:true, origin_kind:'space', origin_x/y = ship.space_x/y}  (UNCHANGED)
--   in_transit / legacy_transit                       → {ok:false, reason:'in_transit_must_stop'}                    (UNCHANGED)
--   destroyed                                         → {ok:false, reason:'destroyed'}                              (UNCHANGED)
--   any contradictory/invalid state                   → reason forwarded from validate / 'contradictory_state'      (UNCHANGED)

create or replace function public.mainship_space_resolve_origin(p_main_ship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_val   jsonb;
  v_state text;
  v_ship  main_ship_instances%rowtype;
begin
  -- Single source of coherent-state truth (the S2 validator). Unchanged.
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;
  v_state := v_val->>'state';

  -- OSN-ANCHOR-1A: legacy map coordinates are NOT canonical OSN positions and must never become a movement
  -- origin. Reject home / at_location (and their legacy aliases) as origin_not_anchored. NO legacy fallback,
  -- NO anchor seed. This replaces the former base/location success branches (which read the legacy x/y).
  if v_state in ('home', 'legacy_home', 'at_location', 'legacy_present') then
    return jsonb_build_object('ok', false, 'reason', 'origin_not_anchored');
  end if;

  -- in_space: authoritative canonical origin from the ship's OWN coordinates (UNCHANGED behavior).
  if v_state = 'in_space' then
    select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;
    if v_ship.space_x is null or v_ship.space_y is null then
      return jsonb_build_object('ok', false, 'reason', 'contradictory_state');
    end if;
    return jsonb_build_object('ok', true, 'origin_kind', 'space', 'origin_x', v_ship.space_x, 'origin_y', v_ship.space_y);
  elsif v_state in ('in_transit', 'legacy_transit') then
    return jsonb_build_object('ok', false, 'reason', 'in_transit_must_stop');
  elsif v_state = 'destroyed' then
    return jsonb_build_object('ok', false, 'reason', 'destroyed');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'contradictory_state');
end;
$$;
