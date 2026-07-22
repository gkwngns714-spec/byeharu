-- WORLD-EDITOR V1C PR-D READ-CUTOVER — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0263 (20260618000263_worldeditor_v1c_pr_d_read_cutover.sql) after the FULL chain is
-- applied by `supabase start`:
--   * FUNCTION SHAPE — get_world_map() is now SECURITY DEFINER, reads public.space_anchors, keeps all three
--     status='active' filters + the 0217 territory_radius field, and still grants anon+authenticated execute.
--   * BYTE-IDENTITY — the live (anchor-backed) get_world_map() payload is BYTE-IDENTICAL, both as jsonb and
--     as text, to a legacy payload built the OLD way (straight from locations.x/y). Because 0245 pinned every
--     active anchor at its location's exact (x,y), the read-source swap is a provable no-op on current data.
--   * READS ANCHORS — get_world_map() provably reads the ANCHOR, not locations.x/y: perturbing one location's
--     active anchor (retire + re-insert at an offset, the legit relocation path) moves EXACTLY that location's
--     coordinate in get_world_map() output by the offset, while locations.x/y is untouched.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no world row
-- committed (the anchor perturbation in Proof 3 is rolled back with the txn). NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── PROOF 1 — FUNCTION SHAPE: SECURITY DEFINER, reads space_anchors, filters + field + grants intact ──
do $$
declare v_src text;
begin
  if to_regprocedure('public.get_world_map()') is null then
    raise exception 'PR-D PROOF FAIL: public.get_world_map() does not exist';
  end if;
  select p.prosrc into v_src
    from pg_proc p where p.oid = to_regprocedure('public.get_world_map()')::oid;

  -- signature unchanged: zero args, returns jsonb, language sql, stable.
  if (select pg_get_function_identity_arguments(to_regprocedure('public.get_world_map()')::oid)) <> '' then
    raise exception 'PR-D PROOF FAIL: get_world_map() signature gained arguments';
  end if;
  if (select t.typname from pg_proc p join pg_type t on t.oid = p.prorettype
       where p.oid = to_regprocedure('public.get_world_map()')::oid) <> 'jsonb' then
    raise exception 'PR-D PROOF FAIL: get_world_map() no longer returns jsonb';
  end if;
  if (select l.lanname from pg_proc p join pg_language l on l.oid = p.prolang
       where p.oid = to_regprocedure('public.get_world_map()')::oid) <> 'sql'
     or (select p.provolatile from pg_proc p
          where p.oid = to_regprocedure('public.get_world_map()')::oid) <> 's' then
    raise exception 'PR-D PROOF FAIL: get_world_map() language/volatility changed';
  end if;

  -- the cutover: NOW SECURITY DEFINER (was invoker) so it can read the server-private space_anchors.
  if not (select p.prosecdef from pg_proc p
           where p.oid = to_regprocedure('public.get_world_map()')::oid) then
    raise exception 'PR-D PROOF FAIL: get_world_map() is not SECURITY DEFINER — anon/authenticated cannot read space_anchors';
  end if;

  -- body: reads the anchor coordinate, and keeps the 0217 hidden-invisibility pins + field.
  -- After the V1C write-authority slice (0264) the read is FAIL-CLOSED: the anchor coord is emitted
  -- DIRECTLY via an active-anchor INNER JOIN, with NO coalesce fallback to locations.x/y.
  if position('space_anchors' in v_src) = 0
     or position('''x'', a.space_x' in v_src) = 0
     or position('''y'', a.space_y' in v_src) = 0
     or position('join public.space_anchors a' in v_src) = 0 then
    raise exception 'PR-D PROOF FAIL: get_world_map() does not read the active anchor coordinate directly (fail-closed INNER JOIN)';
  end if;
  if position('coalesce(a.space_x' in v_src) <> 0 or position('coalesce(a.space_y' in v_src) <> 0 then
    raise exception 'PR-D PROOF FAIL: get_world_map() still has a coalesce anchor fallback — 0264 must have made it fail-closed';
  end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0
     or position('''territory_radius'', l.territory_radius' in v_src) = 0 then
    raise exception 'PR-D PROOF FAIL: get_world_map() lost a status=active filter or the territory_radius field';
  end if;

  -- exposure unchanged: client execute grants intact.
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception 'PR-D PROOF FAIL: get_world_map() lost a client execute grant';
  end if;
  raise notice 'PRD_PASS_FUNCTION_SHAPE';
end $$;

-- ── PROOF 2 — BYTE-IDENTITY: live anchor-backed payload == legacy locations.x/y payload (jsonb AND text) ─
-- Build the OLD payload with a temp function that is a byte-copy of the 0217 head (coords straight from
-- locations.x/y, no anchor join), then assert equality with the live cut-over get_world_map().
create function pg_temp.get_world_map_legacy_xy()
returns jsonb
language sql
stable
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
                      'x', l.x, 'y', l.y, 'base_difficulty', l.base_difficulty,
                      'reward_tier', l.reward_tier, 'activity_type', l.activity_type,
                      'min_power_required', l.min_power_required,
                      'is_public', l.is_public, 'status', l.status,
                      'territory_radius', l.territory_radius
                    ) order by l.name)
                  from public.locations l
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

do $$
declare v_live jsonb; v_legacy jsonb; v_loc_count int;
begin
  v_live   := public.get_world_map();
  v_legacy := pg_temp.get_world_map_legacy_xy();

  -- non-vacuity: the payload must actually carry a world (locations across the active hierarchy).
  select count(*) into v_loc_count
    from jsonb_array_elements(v_live->'sectors') se,
         jsonb_array_elements(se->'zones')       z,
         jsonb_array_elements(z->'locations')    loc;
  if v_loc_count <= 3 then
    raise exception 'PR-D PROOF FAIL: get_world_map() emitted only % location(s) — byte-identity check would be near-vacuous', v_loc_count;
  end if;

  -- jsonb equality (semantic) AND text equality (byte-for-byte) — both must hold.
  if v_live is distinct from v_legacy then
    raise exception 'PR-D PROOF FAIL: anchor-backed payload differs (jsonb) from the legacy locations.x/y payload — NOT byte-identical';
  end if;
  if v_live::text <> v_legacy::text then
    raise exception 'PR-D PROOF FAIL: anchor-backed payload differs (text) from the legacy locations.x/y payload — NOT byte-identical';
  end if;
  raise notice 'PRD_PASS_BYTE_IDENTICAL (% locations, jsonb + text identical)', v_loc_count;
end $$;

-- ── PROOF 3 — get_world_map() PROVABLY READS THE ANCHOR (not locations.x/y) ──────────────────────────
-- Perturb ONE location's active anchor via the legit relocation path (retire active + insert new active at
-- an offset). get_world_map() must move exactly that location's coordinate by the offset, while
-- locations.x/y stays put. The whole txn rolls back afterwards, so nothing persists.
do $$
declare
  v_loc_id  uuid;
  v_loc_x   double precision;
  v_loc_y   double precision;
  v_map_before_x double precision;
  v_map_before_y double precision;
  v_map_after_x  double precision;
  v_map_after_y  double precision;
  v_dx double precision;
  v_dy double precision;
begin
  -- pick an active-hierarchy location that has an active anchor.
  select l.id, l.x, l.y into v_loc_id, v_loc_x, v_loc_y
    from public.locations l
    join public.zones   z  on z.id  = l.zone_id
    join public.sectors se on se.id = z.sector_id
    join public.space_anchors a
      on a.location_id = l.id and a.kind = 'location' and a.status = 'active'
   where l.status = 'active' and z.status = 'active' and se.status = 'active'
   order by l.id
   limit 1;
  if v_loc_id is null then
    raise exception 'PR-D PROOF FAIL: no active anchored location to perturb — proof would be vacuous';
  end if;

  -- Offsets move TOWARD the origin so the perturbed anchor always stays inside the 0063 bounds CHECK
  -- ([-10000,10000]^2) regardless of where the chosen location sits — a nonzero shift, so the new
  -- coordinate is guaranteed different from locations.x/y.
  v_dx := case when v_loc_x >= 0 then -1234.5 else 1234.5 end;
  v_dy := case when v_loc_y >= 0 then -678.25 else 678.25 end;

  -- BEFORE: read the coordinate straight out of get_world_map() output for this location.
  select (loc->>'x')::double precision, (loc->>'y')::double precision
    into v_map_before_x, v_map_before_y
    from jsonb_array_elements(public.get_world_map()->'sectors') se,
         jsonb_array_elements(se->'zones')       z,
         jsonb_array_elements(z->'locations')    loc
   where (loc->>'id')::uuid = v_loc_id;
  if v_map_before_x is distinct from v_loc_x or v_map_before_y is distinct from v_loc_y then
    raise exception 'PR-D PROOF FAIL: pre-perturb get_world_map coord (%,%) != locations (%,%)', v_map_before_x, v_map_before_y, v_loc_x, v_loc_y;
  end if;

  -- Perturb: retire the active anchor (active->retired, allowed) then insert a new active one at an offset.
  update public.space_anchors
     set status = 'retired'
   where location_id = v_loc_id and kind = 'location' and status = 'active';
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
  values ('location', v_loc_id, v_loc_x + v_dx, v_loc_y + v_dy, 'active');

  -- AFTER: get_world_map() must now show the ANCHOR's new coordinate.
  select (loc->>'x')::double precision, (loc->>'y')::double precision
    into v_map_after_x, v_map_after_y
    from jsonb_array_elements(public.get_world_map()->'sectors') se,
         jsonb_array_elements(se->'zones')       z,
         jsonb_array_elements(z->'locations')    loc
   where (loc->>'id')::uuid = v_loc_id;

  if v_map_after_x is distinct from (v_loc_x + v_dx) or v_map_after_y is distinct from (v_loc_y + v_dy) then
    raise exception 'PR-D PROOF FAIL: after moving the anchor, get_world_map shows (%,%), expected the anchor (%,%) — it is NOT reading the anchor', v_map_after_x, v_map_after_y, v_loc_x + v_dx, v_loc_y + v_dy;
  end if;
  -- and it is DEFINITELY not reading locations.x/y (which never changed).
  if v_map_after_x is not distinct from v_loc_x and v_map_after_y is not distinct from v_loc_y then
    raise exception 'PR-D PROOF FAIL: get_world_map still shows locations.x/y after the anchor moved — it is reading the wrong source';
  end if;
  if (select l.x from public.locations l where l.id = v_loc_id) is distinct from v_loc_x then
    raise exception 'PR-D PROOF FAIL: locations.x mutated during the perturb — test contaminated';
  end if;
  raise notice 'PRD_PASS_READS_ANCHORS (moved anchor by (%,%), get_world_map followed)', v_dx, v_dy;
end $$;

do $$ begin raise notice 'WORLD-EDITOR V1C PR-D READ-CUTOVER PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
