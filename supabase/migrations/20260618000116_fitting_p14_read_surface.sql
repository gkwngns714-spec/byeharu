-- Byeharu — FITTING-P14 SLICE E: the dark read surface — get_my_ship_fittings().
-- Read-only; no write anywhere; dark-gated like every module-fitting surface.
-- Mirrors the modules read surface 0110 (the 0101/0106 family) exactly, except where stated.
--
-- (1) ONE gated RPC for the PLAYER-STATE data only. get_my_ship_fittings() returns the caller's
--     OWN ship_module_fittings rows joined DOWNWARD (via module_instances) to their module_types
--     catalog identity — per row: module_instance_id, main_ship_id, fitted_at, module_type_id,
--     plus the catalog display fields the future panel needs (name, slot_type, slot_cost) —
--     ordered fitted_at desc then module_instance_id for determinism (the 0110 ordering idiom,
--     with the uuid tiebreak since several fittings can share a timestamp). Rows are scoped by
--     player_id = auth.uid() IN THE QUERY itself — defense in depth over the table's own-row RLS,
--     as 0110 does.
-- (2) NO CATALOG RPC — the 0110 stance restated and followed: module_types (incl. the 0111
--     slot_cost/stats_json columns) and module_recipe_ingredients are public-read Reference/Config
--     catalogs exactly like item_types/support_craft_types/trade_goods, which the client reads by
--     DIRECT table select (the shipped convention). A get-catalog RPC would duplicate an
--     already-public surface — NOT added.
-- (3) NO ship module_slots in this RPC — a DELIBERATE omission, recorded so it is never read as
--     forgotten: the slot LIMIT belongs to the ship, not the fitting rows. The client reads its
--     own main_ship_instances rows (the 0043 own-row select grant covers module_slots) or the
--     get_my_expedition_preview RPC (whose stats now carry module_slots_used/module_slots_limit,
--     0115) for limits. This surface stays dumb — fitting rows only, no cross-shape join.
-- (4) GATE ORDER — one deliberate divergence from 0110, per the slice spec: the dark gate runs
--     FIRST, then auth resolution (0110 checks auth first). While dark the answer is identical for
--     EVERY caller — even an authenticated one learns nothing about the feature — and anon has no
--     execute grant on this function anyway, so nothing about the caller can be probed either way.
--
-- Note (the 0106/0110 header nuance, mirrored): while ship_module_fittings also carries an own-row
-- select policy (0112), the CLIENT CONVENTION for player activity/progression state is this ONE
-- gated RPC — while module_fitting_enabled='false' it rejects identically regardless of caller
-- state, so nothing about a player's fittings can be probed while dark; the frontend gets its
-- server-driven visibility signal from the 'module_fitting_disabled' reason (the twins' posture).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): read-only function — NO new
-- writer, NO new table, so the §1 matrix is unchanged (the 0101/0106/0110 precedent: read surfaces
-- are recorded in the §2 system row, not the matrix). The §2 Fitting row gains this function. No
-- flag flipped; 0001–0115 unedited.

create or replace function public.get_my_ship_fittings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player   uuid;
  v_fittings jsonb;
  c_empty    constant jsonb := '[]'::jsonb;
begin
  -- DARK server-reject FIRST (0111 law; the 0087/0101/0106/0110 read idiom, gate-before-auth per
  -- the slice spec — see header (4)): before any row read, and the identical envelope regardless
  -- of the caller — no probing while dark.
  if not public.cfg_bool('module_fitting_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'module_fitting_disabled');
  end if;

  v_player := auth.uid();
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- read-only: ONLY the caller's own fittings (query-scoped — defense in depth over RLS), joined
  -- downward to their public catalog identity. Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'module_instance_id', f.module_instance_id,
           'main_ship_id',       f.main_ship_id,
           'fitted_at',          f.fitted_at,
           'module_type_id',     i.module_type_id,
           'name',               t.name,
           'slot_type',          t.slot_type,
           'slot_cost',          t.slot_cost) order by f.fitted_at desc, f.module_instance_id),
         c_empty)
    into v_fittings
    from public.ship_module_fittings f
    join public.module_instances i on i.id = f.module_instance_id
    join public.module_types t     on t.id = i.module_type_id
    where f.player_id = v_player;

  return jsonb_build_object('ok', true, 'fittings', coalesce(v_fittings, c_empty));
end;
$$;

-- ACL (0110:72–75 idiom verbatim): revoke the default PUBLIC grant, then authenticated only. Dark
-- today: the gate above rejects every call while module_fitting_enabled = 'false'.
revoke execute on function public.get_my_ship_fittings() from public, anon;
grant  execute on function public.get_my_ship_fittings() to authenticated;
