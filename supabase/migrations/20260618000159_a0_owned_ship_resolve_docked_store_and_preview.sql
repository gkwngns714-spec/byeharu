-- Byeharu — A0 FOUNDATION FIXUP: owned-ship resolution for two unguarded reads (multi-ship safety).
--
-- Pre-team-command audit blocker. Two SECURITY DEFINER reads still derive the ship with the sole-ship
-- shortcut `... from main_ship_instances where player_id = auth.uid()` and NO uniqueness guard. That is a
-- REAL latent bug: the moment a player owns more than one main ship (Slice A flips the add-ship gate), the
-- unqualified select returns an ARBITRARY row (get_my_docked_store) or errors/ghosts (any caller assuming
-- one) — the hangar / preview would silently describe the wrong ship. Masked today only because multi-ship
-- is dark (every player has exactly one ship).
--
-- Fix = the ESTABLISHED §2.5 pattern already applied to the seven main-ship command RPCs (migrations
-- 0081/0082): a TRAILING `p_main_ship_id uuid default null`, resolved through the shared owned-ship resolver
-- `mainship_resolve_owned_ship(auth.uid(), p_main_ship_id)`:
--   • explicit p_main_ship_id → ownership asserted server-side (UI selection is NEVER trusted);
--   • null (legacy/shim) → the sole ship ONLY when the player has EXACTLY one; zero or >1 (ambiguous) → null
--     → the caller fails closed. Never selects an arbitrary owned ship.
-- BACKWARD COMPATIBLE at runtime: existing zero-/two-arg callers pass no id → default null → sole-ship shim,
-- so nothing breaks while multi-ship stays dark. DARK: explicit selection is inert until add-ship exists.
--
-- Touches NO flag, NO data, NO combat/movement path, NO frozen migration file. It DOES change two RPC
-- identities (`fn()`/`fn(jsonb,text)` → `fn(uuid)`/`fn(jsonb,text,uuid)`); the single signature-resolving
-- verifier pin this invalidates (get_my_expedition_preview in the PORT-ENTRY D2 inventory) is recorded in
-- docs/TRADE_FLEET_0C_VERIFIER_REPOINT.md for the deploy-time gate. get_my_docked_store's only reference is a
-- zero-arg call → still resolves via the default → not invalidated.

-- ── A. get_my_docked_store — resolver swap. The ONLY body delta vs 0158 is the ship-resolution line; the
--    dark gate, auth handling, validated-context authority, and every return envelope are byte-identical.
drop function if exists public.get_my_docked_store();
create function public.get_my_docked_store(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player    uuid := auth.uid();
  v_ship      uuid;
  v_ctx       jsonb;
  v_ok        boolean;
  v_vstate    text;
  v_loc       uuid;
  v_name      text;
  v_store     uuid;
  v_resources jsonb;
  v_units     jsonb;
  c_empty     constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty);
  end if;

  -- DARK gate: feature off → inert empty surface (panel hidden), production byte-unchanged.
  if not cfg_bool('station_storage_enabled') then
    return jsonb_build_object('state','disabled','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty);
  end if;

  -- §2.5: resolve the SELECTED owned ship (explicit p_main_ship_id, ownership asserted server-side) or the
  -- sole ship (shim); UI selection is never trusted. Null (no ship / unowned / zero / ambiguous >1) → the
  -- existing no_main_ship projection, verbatim (was: `where player_id = v_player`, arbitrary at N>1).
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty);
  end if;

  -- Canonical validated ship context (coherence-checked: fleet + presence + movement). SAME authority the
  -- dock-services read uses; never invents a dock from stale fields.
  v_ctx    := public.mainship_space_validate_context(v_ship);
  v_ok     := (v_ctx->>'ok')::boolean;
  v_vstate := v_ctx->>'state';

  if v_ok is true and v_vstate = 'at_location' then
    select f.current_location_id into v_loc
      from public.fleets f
      where f.main_ship_id = v_ship and f.status = 'present' and f.location_mode = 'location'
      limit 1;
    if v_loc is null then
      return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty);
    end if;

    select l.name into v_name from public.locations l where l.id = v_loc;

    -- Only a real dockable port carries a store (canonical 6-part predicate, reused). A docked-but-not-storable
    -- location returns docked=true with an empty, storeless surface (defensive — Dock-0 only docks eligible ports).
    if not public.is_home_port_eligible(v_loc) then
      return jsonb_build_object('state','at_location','docked',true,'location_id',v_loc,'location_name',v_name,'store_id',null,'resources',c_empty,'units',c_empty);
    end if;

    v_store := public.get_or_create_store(v_player, v_loc);

    select coalesce(jsonb_agg(jsonb_build_object('resource_code', r.resource_code, 'amount', r.amount)
                              order by r.resource_code), c_empty)
      into v_resources
      from public.base_resources r where r.base_id = v_store;

    select coalesce(jsonb_agg(jsonb_build_object('unit_type_id', u.unit_type_id, 'quantity', u.quantity)
                              order by u.unit_type_id), c_empty)
      into v_units
      from public.base_units u where u.base_id = v_store and u.quantity > 0;

    return jsonb_build_object(
      'state','at_location','docked',true,
      'location_id',v_loc,'location_name',v_name,'store_id',v_store,
      'resources',coalesce(v_resources, c_empty),'units',coalesce(v_units, c_empty));

  elsif v_ok is true and v_vstate in ('in_transit','in_space','destroyed') then
    return jsonb_build_object('state',v_vstate,'docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty);
  else
    -- home / legacy_home / legacy_present / contradictory / unknown → no hangar surface.
    return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty);
  end if;
end;
$$;

revoke all    on function public.get_my_docked_store(uuid) from public;
grant  execute on function public.get_my_docked_store(uuid) to authenticated;

-- ── B. get_my_expedition_preview — resolver swap. The zero-ship starter-hull teaser is PRESERVED for genuine
--    no-ship players; a resolver-null WITH ships (ambiguous/unowned once multi-ship exists) fails closed to a
--    ship_selection_required envelope rather than previewing an arbitrary ship (was: `where player_id =
--    v_player`, arbitrary at N>1). Also tightens the execute surface to authenticated (drops the default
--    PUBLIC/anon grant), matching the get_my_current_dock_services hardening.
drop function if exists public.get_my_expedition_preview(jsonb, text);
create function public.get_my_expedition_preview(
  p_loadout jsonb default '[]'::jsonb,
  p_activity_type text default 'pirate_hunt',
  p_main_ship_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_ship_id uuid;
  v_ship    public.main_ship_instances%rowtype;
  v_hull    public.main_ship_hull_types%rowtype;
  v_ship_json jsonb;
  v_stats   jsonb;
begin
  if v_player is null then
    raise exception 'get_my_expedition_preview: not authenticated';
  end if;

  -- §2.5: resolve the SELECTED owned ship (ownership asserted) or the sole ship (shim). Never arbitrary.
  v_ship_id := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);

  if v_ship_id is null then
    -- Resolver null = the player owns no ship OR (once multi-ship is live) the selection is ambiguous/unowned.
    -- Distinguish, so a real multi-ship player is NEVER shown a fabricated arbitrary preview.
    if exists (select 1 from main_ship_instances where player_id = v_player) then
      -- Has ship(s) but none unambiguously resolved → fail closed; force explicit selection.
      return jsonb_build_object('has_ship', true, 'valid', false, 'error', 'ship_selection_required');
    end if;
    -- Genuine no-ship → read-only starter-hull teaser (NO write, NO ensure); behavior unchanged from 0049.
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

  -- Load the RESOLVED owned ship (existence + ownership already asserted by the resolver).
  select * into v_ship from main_ship_instances where main_ship_id = v_ship_id;

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

revoke execute on function public.get_my_expedition_preview(jsonb, text, uuid) from public, anon;
grant  execute on function public.get_my_expedition_preview(jsonb, text, uuid) to authenticated;
