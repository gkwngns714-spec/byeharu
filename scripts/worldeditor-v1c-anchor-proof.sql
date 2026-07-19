-- WORLD-EDITOR V1C ANCHOR-SCAFFOLD — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0245 (20260618000245_worldeditor_v1c_anchor_scaffold.sql) after the FULL chain is
-- applied by `supabase start`:
--   * EVERY public.locations row has exactly one ACTIVE kind='location' space_anchor (backfill complete);
--   * every active location anchor's (space_x, space_y) EXACTLY equals its location's (x, y) — the
--     0066/0227 invariant, now world-wide;
--   * no location carries more than one active anchor;
--   * get_world_map() is UNCHANGED (signature jsonb/no-args, sql+stable, all three status='active'
--     filters + territory_radius intact, no space_anchors read, anon/authenticated grants intact);
--   * the backfill is IDEMPOTENT — re-running it inserts zero rows;
--   * the new resolver exists, is exposed exactly like get_world_map, and agrees row-for-row with the
--     active-world coordinates get_world_map already emits (leak-parity: nothing new is exposed).
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no world row
-- touched. NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── PROOF 1 — ALL LOCATIONS ANCHORED: count(active location anchors) = count(locations) > 3 ─────────
-- The > 3 floor makes the proof non-vacuous: 0066 seeded exactly 3 port anchors, so equality at a count
-- above 3 proves the 0245 backfill really anchored the rest of the world (8 locations on today's chain).
do $$
declare v_locations int; v_anchors int;
begin
  select count(*) into v_locations from public.locations;
  select count(*) into v_anchors
    from public.space_anchors where kind = 'location' and status = 'active';
  if v_locations <= 3 then
    raise exception 'V1C PROOF FAIL: only % location(s) on the chain — the backfill sweep would be vacuous', v_locations;
  end if;
  if v_anchors <> v_locations then
    raise exception 'V1C PROOF FAIL: % active location anchor(s) for % location(s) — backfill incomplete or orphan anchor', v_anchors, v_locations;
  end if;
  -- and the mapping is a bijection, not just a count coincidence: every location has its OWN anchor.
  if exists (select 1 from public.locations l
              where not exists (select 1 from public.space_anchors a
                                 where a.location_id = l.id and a.kind = 'location' and a.status = 'active')) then
    raise exception 'V1C PROOF FAIL: a location exists with no active anchor despite matching counts';
  end if;
  raise notice 'V1C_PASS_ALL_LOCATIONS_ANCHORED';
end $$;

-- ── PROOF 2 — ANCHOR = LOCATION, exactly, world-wide (the 0066/0227 invariant) ──────────────────────
do $$
declare v_n int;
begin
  select count(*) into v_n
    from public.space_anchors a
    join public.locations l on l.id = a.location_id
   where a.kind = 'location' and a.status = 'active'
     and (a.space_x is distinct from l.x or a.space_y is distinct from l.y);
  if v_n <> 0 then
    raise exception 'V1C PROOF FAIL: % active location anchor(s) differ from their location''s exact (x,y)', v_n;
  end if;
  raise notice 'V1C_PASS_ANCHOR_EQUALS_LOCATION';
end $$;

-- ── PROOF 3 — at most ONE active anchor per location (deployed data, not just the catalog) ──────────
do $$
declare v_n int;
begin
  select count(*) into v_n
    from (select location_id from public.space_anchors
           where kind = 'location' and status = 'active'
           group by location_id having count(*) > 1) dup;
  if v_n <> 0 then
    raise exception 'V1C PROOF FAIL: % location(s) with more than one active anchor', v_n;
  end if;
  -- the partial unique index that enforces this at write time must still exist too.
  if to_regclass('public.space_anchors_one_active_per_location') is null then
    raise exception 'V1C PROOF FAIL: partial unique index space_anchors_one_active_per_location is gone';
  end if;
  raise notice 'V1C_PASS_ONE_ACTIVE_PER_LOCATION';
end $$;

-- ── PROOF 4 — get_world_map() UNCHANGED: signature, body pins, grants ───────────────────────────────
do $$
declare v_src text;
begin
  if to_regprocedure('public.get_world_map()') is null then
    raise exception 'V1C PROOF FAIL: public.get_world_map() does not exist';
  end if;
  select p.prosrc into v_src
    from pg_proc p where p.oid = to_regprocedure('public.get_world_map()')::oid;
  -- signature: zero args, returns jsonb, language sql, stable, NOT security definer (the 0217 head).
  if (select pg_get_function_identity_arguments(to_regprocedure('public.get_world_map()')::oid)) <> '' then
    raise exception 'V1C PROOF FAIL: get_world_map() signature gained arguments';
  end if;
  if (select t.typname from pg_proc p join pg_type t on t.oid = p.prorettype
       where p.oid = to_regprocedure('public.get_world_map()')::oid) <> 'jsonb' then
    raise exception 'V1C PROOF FAIL: get_world_map() no longer returns jsonb';
  end if;
  if (select l.lanname from pg_proc p join pg_language l on l.oid = p.prolang
       where p.oid = to_regprocedure('public.get_world_map()')::oid) <> 'sql'
     or (select p.provolatile from pg_proc p
          where p.oid = to_regprocedure('public.get_world_map()')::oid) <> 's'
     or (select p.prosecdef from pg_proc p
          where p.oid = to_regprocedure('public.get_world_map()')::oid) then
    raise exception 'V1C PROOF FAIL: get_world_map() language/volatility/security changed';
  end if;
  -- body pins: the three hidden-invisibility filters + the 0217 field, and NO anchor read.
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0
     or position('''territory_radius'', l.territory_radius' in v_src) = 0 then
    raise exception 'V1C PROOF FAIL: get_world_map() body drifted from the 0217 head';
  end if;
  if position('space_anchors' in v_src) > 0 then
    raise exception 'V1C PROOF FAIL: get_world_map() reads space_anchors — the cutover must be a later slice';
  end if;
  -- exposure unchanged.
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception 'V1C PROOF FAIL: get_world_map() lost a client execute grant';
  end if;
  raise notice 'V1C_PASS_GET_WORLD_MAP_UNCHANGED';
end $$;

-- ── PROOF 5 — the 0245 backfill is IDEMPOTENT: re-running it inserts NOTHING ────────────────────────
-- (Runs the exact backfill statement again inside this rolled-back txn.)
do $$
declare v_inserted int;
begin
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
  select 'location', l.id, l.x, l.y, 'active'
    from public.locations l
   where not exists (
           select 1 from public.space_anchors a
            where a.location_id = l.id and a.kind = 'location' and a.status = 'active')
   order by l.id;
  get diagnostics v_inserted = row_count;
  if v_inserted <> 0 then
    raise exception 'V1C PROOF FAIL: backfill re-run inserted % new row(s) — not idempotent', v_inserted;
  end if;
  raise notice 'V1C_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 6 — resolver present, exposed like get_world_map, and in LEAK-PARITY with it ──────────────
-- Row-for-row: the resolver returns exactly the active-hierarchy locations get_world_map emits, at
-- exactly the coordinates get_world_map already shows (anchor == location by Proof 2). Nothing more.
do $$
declare v_n int; v_resolver int; v_active int;
begin
  if to_regprocedure('public.get_location_anchor_points()') is null then
    raise exception 'V1C PROOF FAIL: public.get_location_anchor_points() does not exist';
  end if;
  if not has_function_privilege('anon', 'public.get_location_anchor_points()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_location_anchor_points()', 'execute')
     or not has_function_privilege('service_role', 'public.get_location_anchor_points()', 'execute') then
    raise exception 'V1C PROOF FAIL: get_location_anchor_points() grants do not match the get_world_map exposure';
  end if;
  select count(*) into v_resolver from public.get_location_anchor_points();
  select count(*) into v_active
    from public.locations l
    join public.zones    z  on z.id  = l.zone_id
    join public.sectors  se on se.id = z.sector_id
   where l.status = 'active' and z.status = 'active' and se.status = 'active';
  if v_resolver <> v_active then
    raise exception 'V1C PROOF FAIL: resolver returns % row(s), active world has % — exposure mismatch', v_resolver, v_active;
  end if;
  select count(*) into v_n
    from public.get_location_anchor_points() p
    join public.locations l on l.id = p.location_id
   where p.space_x is distinct from l.x or p.space_y is distinct from l.y;
  if v_n <> 0 then
    raise exception 'V1C PROOF FAIL: % resolver row(s) disagree with the coordinate get_world_map shows', v_n;
  end if;
  raise notice 'V1C_PASS_RESOLVER_LEAK_PARITY';
end $$;

do $$ begin raise notice 'WORLD-EDITOR V1C ANCHOR-SCAFFOLD PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
