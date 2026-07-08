-- Byeharu — STATION-STORAGE P2: docked-port storage READ surface (dark, read-only for the player's own UI).
--
-- get_my_docked_store() exposes the per-port hangar for the authenticated player's own UI, following the EVE
-- model chosen for this feature: "the store is whichever port you are CURRENTLY docked at" — resolved live
-- from the ship's validated dock, NOT from a fixed origin/home. It mirrors get_my_current_dock_services
-- (PHASE 9 / 0069) exactly: no args, derives player = auth.uid() + the player's one main ship + the canonical
-- validated ship context (mainship_space_validate_context), and treats ONLY the 'at_location' state as docked.
--
-- DARK: gated on station_storage_enabled (default false, 0157). While dark it returns docked=false / empty, so
-- the hangar panel renders nothing and production is unchanged. Additionally, in production the starter ports
-- are still hidden and OSN docking is dark, so `at_location` at a storable port is itself unreachable yet.
--
-- READ-ONLY intent: the only write it can cause is get_or_create_store lazily materializing an EMPTY store row
-- for a port on first dock (idempotent, race-safe via bases_one_per_player_location). It never moves an asset.

create or replace function public.get_my_docked_store()
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
  -- Uniform not-docked / empty envelope helper is inlined per-branch (plpgsql has no closures); keep the shape
  -- byte-identical across every return so the client parser has ONE contract.
  if v_player is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty);
  end if;

  -- DARK gate: feature off → inert empty surface (panel hidden), production byte-unchanged.
  if not cfg_bool('station_storage_enabled') then
    return jsonb_build_object('state','disabled','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty);
  end if;

  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
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

-- Authenticated-only: strip the default PUBLIC (incl. anon) grant, then grant to authenticated. (The function
-- is SECURITY DEFINER, so it invokes get_or_create_store / is_home_port_eligible as owner regardless of their
-- own service_role-only grants.)
revoke all on function public.get_my_docked_store() from public;
grant execute on function public.get_my_docked_store() to authenticated;
