-- Byeharu — Phase 10B: read-only main-ship expedition stats PREVIEW.
--
-- A client-callable, auth.uid()-scoped wrapper over calculate_expedition_stats (Phase 8 —
-- the SINGLE stat source). It is **read/compute only**: it never writes, never sends, never
-- touches combat/fleets/rewards, and never commissions a ship. It simply lets a player see
-- what their main ship + a support-craft loadout WOULD bring on an expedition.
--
-- STRICT PREVIEW: STABLE (read-only). If the player has no commissioned main ship yet, it
-- returns a read-only starter-hull teaser (it does NOT create the ship). Validation errors
-- from the stat adapter (over-capacity, unknown craft, bad quantity) are caught and surfaced
-- as `valid:false` + message — a preview, not a hard failure.
--
-- calculate_expedition_stats stays service_role-only/internal; this SECURITY DEFINER wrapper
-- calls it as the function owner, so only the preview wrapper is exposed to clients.

create or replace function public.get_my_expedition_preview(
  p_loadout jsonb default '[]'::jsonb,
  p_activity_type text default 'pirate_hunt')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   public.main_ship_instances%rowtype;
  v_hull   public.main_ship_hull_types%rowtype;
  v_ship_json jsonb;
  v_stats  jsonb;
begin
  if v_player is null then
    raise exception 'get_my_expedition_preview: not authenticated';
  end if;

  select * into v_ship from main_ship_instances where player_id = v_player;

  -- No commissioned ship yet → read-only starter-hull teaser (NO write, NO ensure).
  if not found then
    select * into v_hull from main_ship_hull_types where hull_type_id = 'starter_frigate';
    return jsonb_build_object(
      'has_ship', false,
      'hull', jsonb_build_object(
        'hull_type_id',          v_hull.hull_type_id,
        'name',                  v_hull.name,
        'base_hp',               v_hull.base_hp,
        'base_speed',            v_hull.base_speed,
        'base_cargo_capacity',   v_hull.base_cargo_capacity,
        'base_support_capacity', v_hull.base_support_capacity,
        'base_captain_slots',    v_hull.base_captain_slots,
        'base_module_slots',     v_hull.base_module_slots));
  end if;

  v_ship_json := jsonb_build_object(
    'main_ship_id',     v_ship.main_ship_id,
    'name',             v_ship.name,
    'status',           v_ship.status,
    'hp',               v_ship.hp,
    'max_hp',           v_ship.max_hp,
    'support_capacity', v_ship.support_capacity,
    'cargo_capacity',   v_ship.cargo_capacity,
    'captain_slots',    v_ship.captain_slots,
    'module_slots',     v_ship.module_slots);

  -- Reuse the single stat source. Catch its validation errors → preview warning, not failure.
  begin
    v_stats := calculate_expedition_stats(
      v_player, v_ship.main_ship_id, coalesce(p_loadout, '[]'::jsonb), coalesce(p_activity_type, 'pirate_hunt'));
    return jsonb_build_object('has_ship', true, 'valid', true, 'ship', v_ship_json, 'stats', v_stats);
  exception when others then
    return jsonb_build_object('has_ship', true, 'valid', false, 'ship', v_ship_json, 'error', sqlerrm);
  end;
end;
$$;

-- ── Re-lock execute surface (anti-cheat). The preview wrapper is a NEW client RPC; the
--    stat adapter (calculate_expedition_stats) stays server-only. Re-grant the existing
--    client RPCs + the new preview; prior service_role grants survive a public/anon/
--    authenticated revoke.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
grant execute on function public.train_units(uuid, text, integer)          to authenticated;
grant execute on function public.cancel_build_order(uuid)                  to authenticated;
grant execute on function public.get_my_expedition_preview(jsonb, text)    to authenticated;
