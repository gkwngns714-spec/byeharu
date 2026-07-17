-- FLEET-GO 3c-2 — DOCK-DEDUP: finish 0092's job. The last inlined copies of the dock read collapse
-- onto the ONE resolver pair (mainship_resolve_docked_location / mainship_resolve_fleet, both 0210).
--
-- Charter: docs/MOVEMENT_UNIFICATION_CHARTER.md §2 + §3 step 3c-2. Follows 0210 (the read oracle).
--
-- WHY THIS MIGRATION EXISTS. The "read the ship's present fleet's location" block was copy-pasted
-- across the tree. 0092 extracted it into mainship_resolve_docked_location and 0210 taught that helper
-- to resolve through the group's fleet — but only for ITS OWN callers (the three trade RPCs, via 0138).
-- The remaining live copies still key on `fleets.main_ship_id = <ship>`, which is NULL on a unified
-- fleet by construction, so a docked GROUP's members answer 'incoherent' / vanish from the map the
-- moment the unified mover lights. Migration 0138 exists SOLELY because 0136 rebuilt the trade RPCs
-- from a stale head and silently re-inlined the block — another copy is the default outcome unless the
-- dedup is finished and grep-enforced. This migration is that finish: FOUR host re-creates, each
-- byte-copied from its TRUE head, each carrying exactly ONE marked hunk.
--
-- LESSON — THE FIFTH COPY WAS LIVE, AND THE SLICE BUILT TO KILL IT MISSED IT. The charter's inventory
-- said four sites (0092, 0082, 0159, 0200); the first cut of this migration collapsed exactly those and
-- declared victory. Adversarial review then found `commission_first_main_ship` (0072:141-142) inlining
-- the SAME block inside the SAME 'at_location' branch — the live head of the RPC every player's entry
-- path replays. Two failures compounding: (1) I trusted the charter's site inventory instead of
-- sweeping the tree for the SHAPE; (2) my ban greps were exact substrings scanning ONLY this file, and
-- 0072's copy has no `f.` alias, so both patterns were blind to it — and a future re-inline (the real
-- 0136 failure mode: a NEW file rebuilt from a stale head) would never be scanned at all. Hence host D
-- below, and the selftest's ban is now a comment-stripped, whitespace/alias-insensitive,
-- statement-level scan of the WHOLE migrations tree with an explicit named allowlist of superseded
-- bodies. An inventory is a claim about the tree; only the tree is the tree.
--
-- ★★ TRUE-HEAD DECLARATION — READ THIS BEFORE TOUCHING ANY OF THESE FOUR FUNCTIONS AGAIN ★★
-- As of this migration the TRUE head of:
--   • get_my_current_dock_services  is THIS FILE (previously 0082:30-90);
--   • get_my_docked_store           is THIS FILE (previously 0159:28-114);
--   • get_my_fleet_positions        is THIS FILE (previously 0200:24-148);
--   • commission_first_main_ship    is THIS FILE (previously 0072:98-155).
-- Step 3c-3 (the map projecting the GROUP's fleet) MUST copy get_my_fleet_positions from HERE, not
-- from 0200. Rebuilding from a stale head is exactly how 0136 re-inlined the dock block and forced
-- 0138 to exist — do not make a 0138 for this file.
--
-- THE COPIES WERE NOT IDENTICAL — the architect's sweep said "collapse all onto the dock helper"
-- and that is WRONG for one of them (recorded so nobody "fixes" it back):
--   • 0082:64 / 0159:71 / 0072:141 run strictly under the oracle's 'at_location' state — the same
--     precondition mainship_resolve_docked_location enforces — so for them the helper call is
--     behavior-identical (the 0138 idiom exactly). Cost accepted: the helper re-runs validate_context,
--     which the host already ran for its envelope. HONESTY NOTE (a review correction — the first cut
--     claimed "one snapshot, same answer"): these hosts are VOLATILE, so under read committed each
--     statement takes a FRESH snapshot — the two calls are NOT snapshot-equal, and a concurrent commit
--     between them can change the second answer. When that happens the helper fails CLOSED (null → the
--     host's existing incoherent/null envelope), never open — it can only decline a dock the first
--     call approved, never invent one.
--   • 0200:76 had DRIFTED: no location_mode filter, `order by created_at desc`, and it is reached
--     under a WIDER guard — 'at_location' OR 'legacy_present'. Prod's live ships are legacy-shaped
--     (spatial_state NULL — 73 of 76), so collapsing it onto the at_location-only dock helper would
--     map every legacy_present ship to place='hidden': a LIVE MAP REGRESSION shipped as a "cleanup".
--     Instead it collapses onto mainship_resolve_fleet (the ship→fleet resolver) and KEEPS its own
--     status='present' read. Dark-parity: both guards (0210's at_location branch demands v_count=1;
--     its legacy_present branch likewise) pin exactly ONE active per-ship fleet before the read is
--     reached, and while dark the resolver's per-ship fallback returns exactly that fleet — the same
--     row the old inline read selected — so every envelope stays bit-equal. The `order by` dies with
--     the rekey (f.id = <one uuid> yields at most one row); no location_mode filter is ADDED.
--     Pinned at runtime by FLEETGO_PASS_DOCKDEDUP_LEGACYPRESENT.
--
-- POSTURE. Four function re-creates and NOTHING else: no table change, no drop, no signature change,
-- no flag flip, no seed, no ship write. Every body below is the previous head byte-for-byte except the
-- ONE hunk marked "FLEET-GO 3c-2". ACLs re-emitted verbatim from each head. Behavior while dark is
-- byte-identical (the parity argument above); lit behavior is 0210's group resolution, now uniform
-- across all dock/map reads instead of only the trade path.

-- ── A. get_my_current_dock_services — the 0082:30-90 body; ONE hunk: inline dock read → the helper. ──
create or replace function public.get_my_current_dock_services(p_main_ship_id uuid default null)
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
    -- FLEET-GO 3c-2 (the ONE hunk): the dock comes from the ONE shared resolver instead of the inlined
    -- `f.main_ship_id = <ship>` read (NULL on a unified fleet — a docked group's members answered
    -- 'incoherent'). Dark → the resolver's per-ship fallback returns the exact row the inline read
    -- selected → byte-identical. Null (not at_location on re-check / no matching fleet row) keeps
    -- collapsing to the same incoherent envelope below, as both inline null-paths always did.
    v_loc := public.mainship_resolve_docked_location(v_ship);
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

-- ── B. get_my_docked_store — the 0159:28-114 body; ONE hunk: inline dock read → the helper. ─────────
create or replace function public.get_my_docked_store(p_main_ship_id uuid default null)
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
    -- FLEET-GO 3c-2 (the ONE hunk): the dock comes from the ONE shared resolver instead of the inlined
    -- `f.main_ship_id = <ship>` read (NULL on a unified fleet — a docked group's hangar vanished).
    -- Dark → the resolver's per-ship fallback returns the exact row the inline read selected →
    -- byte-identical. Null keeps collapsing to the same incoherent envelope below.
    v_loc := public.mainship_resolve_docked_location(v_ship);
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

-- ── C. get_my_fleet_positions — the 0200:24-148 body; ONE hunk: the dock read rekeyed to the ONE
--      ship→fleet resolver (NOT the at_location-only dock helper — see the header: 'legacy_present'
--      reaches this read and prod's live ships are legacy-shaped; the helper would hide them all).
--      The legacy_transit branch below still keys on f.main_ship_id — that is 3c-3's problem (the
--      group's fleet has no per-ship transit row to find) and is deliberately NOT touched here. ──────
create or replace function public.get_my_fleet_positions()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_out    jsonb := '[]'::jsonb;
  s        record;
  v_ctx    jsonb;
  v_ok     boolean;
  v_state  text;
  v_place  text;
  v_loc    uuid;
  v_seg    jsonb;
  v_mv     record;
  v_lm     record;
begin
  if v_player is null then
    return v_out;
  end if;

  -- Every owned, non-destroyed ship (owner-read scope). `order by created_at` is stable enumeration only —
  -- the marker placement per ship is decided below, never by row order.
  for s in
    select main_ship_id, name, hull_type_id, status, spatial_state, space_x, space_y
      from public.main_ship_instances
     where player_id = v_player
       and status <> 'destroyed'
       and coalesce(spatial_state, '') <> 'destroyed'
     order by created_at asc
  loop
    v_place := 'hidden';
    v_loc   := null;
    v_seg   := null;

    -- Canonical coherence oracle — the SAME authority the single-ship dock/store reads trust. It fully
    -- validates fleet + presence + movement coherence and returns the ship's honest state (or ok=false).
    v_ctx   := public.mainship_space_validate_context(s.main_ship_id);
    v_ok    := coalesce((v_ctx->>'ok')::boolean, false);
    v_state := v_ctx->>'state';

    if v_ok then
      if v_state = 'in_space' then
        -- Held in open space (durable ship-owned coordinates; coords asserted present by the oracle).
        if s.space_x is not null and s.space_y is not null then
          v_place := 'in_space';
        end if;

      elsif v_state in ('at_location', 'legacy_present') then
        -- FLEET-GO 3c-2 (the ONE hunk): rekeyed from `f.main_ship_id = <ship>` (NULL on a unified
        -- fleet — the whole group vanished on arrival) to the ONE ship→fleet resolver, KEEPING this
        -- site's own status='present' read: 'legacy_present' reaches here too, and the at_location-only
        -- dock helper would return NULL for every legacy-shaped prod ship (a live map regression).
        -- Dark → both oracle guards pin exactly ONE active per-ship fleet, the resolver's fallback
        -- returns it, and f.id = <that one row> makes the old `order by created_at desc` dead weight.
        select f.current_location_id
          into v_loc
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.status = 'present'
         limit 1;
        if v_loc is not null then
          v_place := 'docked';
        end if;

      elsif v_state = 'in_transit' then
        -- Coordinate (OSN) transit — the committed movement segment for client-side interpolation.
        select origin_x, origin_y, target_x, target_y, target_kind, depart_at, arrive_at
          into v_mv
          from public.main_ship_space_movements
         where main_ship_id = s.main_ship_id and status = 'moving'
         limit 1;
        if found then
          v_place := 'transit';
          v_seg   := jsonb_build_object(
            'origin_x', v_mv.origin_x, 'origin_y', v_mv.origin_y,
            'target_x', v_mv.target_x, 'target_y', v_mv.target_y,
            'target_kind', v_mv.target_kind,
            'depart_at', v_mv.depart_at, 'arrive_at', v_mv.arrive_at);
        end if;

      elsif v_state = 'legacy_transit' then
        -- Legacy (spatial_state NULL) transit — the committed fleet_movements segment.
        select fm.origin_x, fm.origin_y, fm.target_x, fm.target_y, fm.target_type, fm.depart_at, fm.arrive_at
          into v_lm
          from public.fleet_movements fm
          join public.fleets f on f.id = fm.fleet_id
         where f.main_ship_id = s.main_ship_id and fm.status = 'moving'
         order by fm.depart_at desc
         limit 1;
        if found then
          v_place := 'transit';
          v_seg   := jsonb_build_object(
            'origin_x', v_lm.origin_x, 'origin_y', v_lm.origin_y,
            'target_x', v_lm.target_x, 'target_y', v_lm.target_y,
            'target_kind', v_lm.target_type,
            'depart_at', v_lm.depart_at, 'arrive_at', v_lm.arrive_at);
        end if;

      -- 'home' / 'legacy_home' → hidden: a ship idle at home is NOT drawn on the port map (mirrors the
      -- single-ship resolver §E/§F). Any other ok state falls through to hidden too (fail closed).
      end if;
    end if;

    -- Append as a single-element ARRAY (array || array is unambiguous concatenation).
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'main_ship_id', s.main_ship_id,
      'name',         s.name,
      'class',        s.hull_type_id,
      'status',       s.status,
      'spatial_state', s.spatial_state,
      'place',        v_place,
      'location_id',  v_loc,
      'space_x',      case when v_place = 'in_space' then s.space_x else null end,
      'space_y',      case when v_place = 'in_space' then s.space_y else null end,
      'segment',      v_seg
    ));
  end loop;

  return v_out;
end;
$$;

-- Authenticated-only owner read (strip the default PUBLIC/anon grant that a new function receives on create,
-- then grant to authenticated). SECURITY DEFINER, so the nested validate_context call runs as owner regardless
-- of its own service_role-only grant — the get_my_docked_store (0158) posture exactly.
revoke all on function public.get_my_fleet_positions() from public;
grant execute on function public.get_my_fleet_positions() to authenticated;

-- ── D. commission_first_main_ship — the 0072:98-155 body; ONE hunk: inline dock read → the helper. ──
--      THE MISSED FIFTH COPY (see the header lesson): the live head of the RPC every player's entry
--      path replays, found by adversarial review AFTER the first cut of this migration shipped three
--      hosts under a "the dedup is finished" header. Its 'at_location' classify branch read the dock
--      with the alias-free inline copy (0072:141-142); for a docked group member (per-ship fleet
--      dissolved by 0208) that read finds nothing, and — uniquely among the four hosts — this envelope
--      has NO null guard: the entry path would report {docked:true, location_id:null}. That envelope is
--      DELIBERATELY not "fixed" here: it is pre-existing shipped behavior and parity governs — only the
--      read is rekeyed. Dark → the helper's per-ship fallback returns the exact row the inline read
--      selected → byte-identical, null included. Lit → a group member's replay reports the group's
--      REAL port. Pinned by FLEETGO_PASS_DOCKDEDUP_COMMISSION (lit) + the DARKPARITY block (dark).
create or replace function public.commission_first_main_ship()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_ctx    jsonb;
  v_state  text;
  v_res    jsonb;
  v_dock   uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- (A) no ship yet → commission. The writer's insert-on-conflict is the race-safe serialization point.
  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    begin
      v_res := public.port_entry_commission_writer(v_player);
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'commission_unavailable');   -- fail-closed, txn rolled back
    end;
    if (v_res->>'created')::boolean is true then
      return jsonb_build_object('ok', true, 'created', true, 'docked', true,
                                'location_id', v_res->'location_id');
    end if;
    -- writer reported created=false → another caller created it first; re-read and classify below.
    select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
    if v_ship is null then
      return jsonb_build_object('ok', false, 'reason', 'commission_unavailable');
    end if;
  end if;

  -- existing ship → classify exactly once via the canonical state machine.
  v_ctx   := public.mainship_space_validate_context(v_ship);
  v_state := case when (v_ctx->>'ok')::boolean is true then v_ctx->>'state' else null end;

  if v_state = 'at_location' then
    -- (B retry / C any-port) already provisioned & coherent → report the ACTUAL current dock; never relocate.
    -- FLEET-GO 3c-2 (the ONE hunk): the dock comes from the ONE shared resolver instead of the inlined
    -- alias-free `main_ship_id = <ship>` read (NULL on a unified fleet — the entry replay reported
    -- docked:true with location_id:null for every docked group member). Dark → the resolver's per-ship
    -- fallback returns the exact row the inline read selected → byte-identical, null included.
    v_dock := public.mainship_resolve_docked_location(v_ship);
    return jsonb_build_object('ok', true, 'created', false, 'already_provisioned', true,
                              'docked', true, 'location_id', to_jsonb(v_dock));
  elsif v_state = 'legacy_present' then
    return jsonb_build_object('ok', false, 'created', false, 'reason', 'needs_normalization');
  elsif v_state in ('home', 'legacy_home') then
    return jsonb_build_object('ok', false, 'created', false, 'reason', 'needs_compat_route');
  else
    -- (F) destroyed / in_space / in_transit / legacy_transit / contradictory / not-found → narrow safe reason.
    return jsonb_build_object('ok', false, 'created', false, 'reason', 'not_provisionable',
                              'state', coalesce(v_state, 'noncanonical'));
  end if;
end;
$$;

revoke execute on function public.commission_first_main_ship()  from public, anon;
grant  execute on function public.commission_first_main_ship()  to authenticated;
