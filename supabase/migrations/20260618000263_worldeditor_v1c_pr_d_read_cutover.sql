-- Byeharu — WORLD-EDITOR V1C PR-D: get_world_map() READ-CUTOVER to space_anchors (authority only).
-- BYTE-IDENTICAL — the rendered world is unchanged after this migration. NO physical rescale, NO point
-- moved, NO stored coordinate touched. This slice changes ONLY the READ AUTHORITY for the map's location
-- coordinates: get_world_map() now emits each active location's (x, y) from its ACTIVE space_anchor
-- (0063) instead of from locations.x/y directly.
--
-- WHY this is a provable no-op TODAY: migration 0245 backfilled one ACTIVE kind='location' anchor for
-- EVERY location at EXACTLY its current (x, y), and 0066/0227 already pin the 3 starter ports the same
-- way. So `active anchor (space_x, space_y)` == `locations.(x, y)` for every location on the chain — the
-- self-assert below RE-PROVES that on the deployed data and ABORTS (fail-closed) if any location lacks an
-- active anchor or its anchor disagrees. When the precondition holds, swapping the read source cannot
-- change one byte of the payload. Both columns are `double precision` (0002:57-58 vs 0063:35-36) so even
-- the JSON numeric rendering is identical.
--
-- INDEPENDENT OF THE RESCALE: this is NOT the ×17 normalize (unmerged PR #245 / migration 0253). It does
-- not depend on, include, or presuppose any coordinate rescale. It only relocates the authority so that a
-- LATER, human-gated slice can move the world by editing anchors — with the map already reading them.
--
-- ── SECURITY DEFINER (required, matches the 0245 resolver) ────────────────────────────────────────────
-- space_anchors is server-private (0063: RLS on / no policy; table grants REVOKED from anon+authenticated;
-- service_role only). The 0217 head was `language sql stable` (SECURITY INVOKER), which cannot read the
-- private table for anon/authenticated callers. get_location_anchor_points (0245) solved the identical
-- problem by being SECURITY DEFINER with `set search_path = public`; get_world_map now does the same.
-- This exposes NOTHING new: the body keeps all three status='active' filters (the 0175/0217
-- hidden-invisibility pin) and the anchor coordinate it now reads EQUALS the coordinate get_world_map
-- already returned. search_path is pinned to public (SECURITY DEFINER injection-safety).
--
-- ── FAIL-SAFE JOIN (LEFT + coalesce, not INNER) ──────────────────────────────────────────────────────
-- The join is a LEFT JOIN to the active anchor with `coalesce(a.space_x, l.x)`: the anchor is authority
-- WHEN PRESENT, else the location's own (x, y). Rationale: the runtime world-editor location-create path
-- (0252) inserts a location WITHOUT an anchor (only migrations 0066/0227/0245 write anchors today). An
-- INNER join would silently DROP such a location from the map — a visibility regression. LEFT+coalesce
-- never drops a row and never yields a NULL coordinate, while remaining byte-identical today (every
-- current location is anchored at its exact coordinate, asserted below). The partial unique index
-- space_anchors_one_active_per_location (0063) guarantees at most one active anchor per location, so the
-- LEFT JOIN cannot multiply rows.
--
-- OWNERSHIP: no new write path. locations/zones/sectors/space_anchors rows and schema are UNTOUCHED; the
-- only object changed is the get_world_map() function body + its security context.

-- ── get_world_map(): PR-D re-create — 0217 head byte-copied, location coords now from the active anchor,
--    now SECURITY DEFINER so it can read the server-private space_anchors table. ────────────────────────
create or replace function public.get_world_map()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'sectors',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', se.id, 'name', se.name, 'sector_index', se.sector_index,
          'x', se.x, 'y', se.y, 'danger_tier', se.danger_tier, 'status', se.status,
          'zones', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id', z.id, 'name', z.name, 'x', z.x, 'y', z.y, 'radius', z.radius,
                'base_difficulty', z.base_difficulty,
                'max_danger_level', z.max_danger_level,
                'reward_tier', z.reward_tier, 'visibility', z.visibility,
                'status', z.status,
                'locations', coalesce((
                  select jsonb_agg(
                    jsonb_build_object(
                      'id', l.id, 'name', l.name, 'location_type', l.location_type,
                      'x', coalesce(a.space_x, l.x), 'y', coalesce(a.space_y, l.y),
                      'base_difficulty', l.base_difficulty,
                      'reward_tier', l.reward_tier, 'activity_type', l.activity_type,
                      'min_power_required', l.min_power_required,
                      'is_public', l.is_public, 'status', l.status,
                      'territory_radius', l.territory_radius
                    ) order by l.name)
                  from public.locations l
                  left join public.space_anchors a
                    on a.location_id = l.id and a.kind = 'location' and a.status = 'active'
                  where l.zone_id = z.id and l.status = 'active'
                ), '[]'::jsonb)
              ) order by z.name)
            from public.zones z
            where z.sector_id = se.id and z.status = 'active'
          ), '[]'::jsonb)
        ) order by se.sector_index)
      from public.sectors se
      where se.status = 'active'
    ), '[]'::jsonb)
  );
$$;

grant execute on function public.get_world_map() to anon, authenticated;

-- ── Self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ────────────────
do $$
declare
  v_locations int;
  v_anchors   int;
  v_n         int;
  v_src       text;
begin
  -- (a) vacuity: a world with no locations would green every byte-identity sweep while proving nothing.
  select count(*) into v_locations from public.locations;
  if v_locations = 0 then
    raise exception '0263 self-assert FAIL: no locations exist — the byte-identity precondition would be vacuous';
  end if;

  -- (b) BYTE-IDENTITY PRECONDITION #1 — every location has exactly one ACTIVE anchor (the 0245 backfill
  --     is intact): count(active location anchors) = count(locations). If any location is un-anchored the
  --     cutover would (via coalesce) still be safe, but the task contract is fail-closed: ABORT.
  select count(*) into v_anchors
    from public.space_anchors where kind = 'location' and status = 'active';
  if v_anchors <> v_locations then
    raise exception '0263 self-assert FAIL: % active location anchor(s) for % location(s) — a location lacks an active anchor (backfill not intact); refuse the cutover', v_anchors, v_locations;
  end if;
  if exists (select 1 from public.locations l
              where not exists (select 1 from public.space_anchors a
                                 where a.location_id = l.id and a.kind = 'location' and a.status = 'active')) then
    raise exception '0263 self-assert FAIL: a location has no active anchor despite matching counts — refuse the cutover';
  end if;

  -- (c) BYTE-IDENTITY PRECONDITION #2 — every active location anchor's (space_x, space_y) EXACTLY equals
  --     its location's (x, y) (the 0066/0227/0245 invariant). This is what makes the read-source swap a
  --     provable no-op. Any disagreement ⇒ the cutover would move a point ⇒ ABORT.
  select count(*) into v_n
    from public.space_anchors a
    join public.locations l on l.id = a.location_id
   where a.kind = 'location' and a.status = 'active'
     and (a.space_x is distinct from l.x or a.space_y is distinct from l.y);
  if v_n <> 0 then
    raise exception '0263 self-assert FAIL: % active location anchor(s) differ from their location''s exact (x,y) — the cutover would NOT be byte-identical; refuse', v_n;
  end if;

  -- (d) at most ONE active anchor per location (re-prove on the deployed data; the LEFT JOIN relies on it
  --     to not multiply rows).
  select count(*) into v_n
    from (select location_id from public.space_anchors
           where kind = 'location' and status = 'active'
           group by location_id having count(*) > 1) dup;
  if v_n <> 0 then
    raise exception '0263 self-assert FAIL: % location(s) with more than one active anchor — LEFT JOIN would multiply map rows', v_n;
  end if;

  -- (e) the cutover really landed: get_world_map now READS space_anchors, is SECURITY DEFINER, still
  --     carries all three status='active' filters + the 0217 territory_radius field, and still grants the
  --     client execute (exposure unchanged).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_world_map()')::oid;
  if v_src is null then
    raise exception '0263 self-assert FAIL: public.get_world_map() does not exist';
  end if;
  if position('space_anchors' in v_src) = 0 then
    raise exception '0263 self-assert FAIL: get_world_map() does not read space_anchors — the cutover did not land';
  end if;
  if position('coalesce(a.space_x, l.x)' in v_src) = 0
     or position('coalesce(a.space_y, l.y)' in v_src) = 0 then
    raise exception '0263 self-assert FAIL: get_world_map() does not emit the anchor coordinate (coalesce(a.space_x/y, l.x/y))';
  end if;
  if not (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public.get_world_map()')::oid) then
    raise exception '0263 self-assert FAIL: get_world_map() is not SECURITY DEFINER — anon/authenticated cannot read the private space_anchors';
  end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0 then
    raise exception '0263 self-assert FAIL: get_world_map() lost a status=''active'' filter — hidden ports would leak; refuse';
  end if;
  if position('''territory_radius'', l.territory_radius' in v_src) = 0 then
    raise exception '0263 self-assert FAIL: get_world_map() no longer emits territory_radius — the 0217 head was altered';
  end if;
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception '0263 self-assert FAIL: get_world_map() lost a client execute grant';
  end if;

  raise notice '0263 self-assert ok: %/% locations anchored, anchor coords == location coords world-wide (byte-identity precondition holds), get_world_map cut over to space_anchors (SECURITY DEFINER, filters + territory_radius + grants intact)',
    v_anchors, v_locations;
end $$;
