-- Byeharu — WORLD EDITOR SLICE 1.5: world_editor_entity_catalog — the owner-only LIFECYCLE CATALOG read.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE GAP THIS CLOSES: every existing World Editor read is ACTIVE-ONLY — get_world_map (0264) filters
-- l.status='active', get_active_mining_fields (0226) filters is_active, get_danger_zones (0233) filters
-- status='active', get_my_exploration_discoveries (0101) is reveal-after-discovery. So the editor CANNOT
-- see or select an INACTIVE entity, which is exactly what a lifecycle filter + a reactivate flow need. This
-- migration adds ONE normalized, owner-only catalog RPC that returns BOTH active and inactive entities
-- across all 4 world-content domains (location / mining / exploration / zone), for the editor's
-- search / filter / map / jump / select / lifecycle surface ONLY.
--
-- WHAT THIS IS NOT: it does NOT modify, replace, or repoint any gameplay reader. get_world_map,
-- get_active_mining_fields, get_danger_zones and get_my_exploration_discoveries are LEFT BYTE-IDENTICAL
-- (this migration does not CREATE OR REPLACE any of them). It writes NOTHING — no table write privilege is
-- added anywhere; the function is READ-ONLY (SECURITY DEFINER only so it can read the RLS-private domain
-- tables the same way get_world_map / get_active_mining_fields already do). It is a PARALLEL owner read,
-- never a second authority over any coordinate, geometry, or lifecycle column.
--
-- NO-SPAGHETTI: ONE owner guard (public.is_owner(), the 0243 spine — consulted IN-BODY), ONE coordinate
-- authority per domain reused verbatim (locations → their ACTIVE space_anchor, the 0263/0264 authority,
-- NEVER locations.x/y; mining/exploration → their native canonical space_x/space_y; zones → the get_danger_zones
-- vertex-ring serialization, byte-for-byte). No new coordinate source, no new geometry engine, no forked
-- reader, no reward/audit/internal field leaked.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed by design: even deployed, the capability
-- is inert until an owner is seeded into app_owners (is_owner() is false for everyone on an unseeded DB).
-- No client grant is widened; execute is authenticated-only (the guard is in-body) and explicitly revoked
-- from PUBLIC and anon.
--
-- FAIL-CLOSED (raise, never silently omit or fall back):
--   • a location (active OR inactive) that lacks EXACTLY ONE active location-kind anchor — the sole
--     coordinate authority; NEVER fall back to locations.x/y (a duplicate is structurally impossible thanks
--     to the partial unique index space_anchors_one_active_per_location (0063), so the reachable failure is a
--     MISSING anchor, but the guard checks <> 1 in both directions);
--   • a danger_zones boundary that cannot be normalized to a closed vertex ring (>= 4 points);
--   • an entity with an unsupported/unknown lifecycle state (a location.status outside the 0002 enum, or a
--     danger_zones.status outside its 0233 CHECK).
--
-- NORMALIZED ROW CONTRACT (each element of result.rows):
--   { domain:'location'|'mining'|'exploration'|'zone', entity_id:<uuid text>, name:text,
--     lifecycle_status:'active'|'inactive', revision:<number|null>, point:{x,y}|null,
--     geometry:{kind:'ring',ring:[[x,y]...]}|null, updated_at:timestamptz|null }
--   • revision is NULL for every domain: no domain table carries a per-entity revision column (the only
--     "revision" in this subsystem is world_editor_audit.source_revision — a per-COMMAND client draft
--     fingerprint, deliberately NOT re-derived here). The key is kept (null) for a stable client contract.
--   • updated_at is the domain table's update timestamp where one exists (danger_zones.updated_at); it is
--     NULL for location / mining / exploration (those tables carry only created_at — no update timestamp).
--
-- TYPED ENVELOPE (the 0243/0250 WE vocabulary — a bare array cannot express not_authorized, so success is
-- wrapped identically to the WE family, carrying the deterministic array in result.rows):
--   success : {ok:true,  status:<resolved>, rows:[ <normalized row> ... ]}
--   failure : {ok:false, error:<code> [, details:[{code,field,message}...]]}  where code ∈
--             { 'not_authenticated'  -- no JWT subject (anonymous)
--             , 'not_authorized'     -- authenticated but not in app_owners
--             , 'validation_failed'  -- p_payload.status is not one of active|inactive|all (details: invalid_status)
--             }
-- INPUT: p_payload = { status: 'active'|'inactive'|'all' }  (default 'all')
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice reads / promises to leave intact vanished.
do $catdep$
begin
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'WE-ENTITY-CATALOG: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regclass('public.locations') is null or to_regclass('public.space_anchors') is null
     or to_regclass('public.mining_fields') is null or to_regclass('public.exploration_sites') is null
     or to_regclass('public.danger_zones') is null then
    raise exception 'WE-ENTITY-CATALOG: a source domain table (locations/space_anchors/mining_fields/exploration_sites/danger_zones) is missing';
  end if;
  -- the gameplay readers this slice PROMISES to leave intact must exist (never be the thing that removed one).
  if to_regprocedure('public.get_world_map()') is null
     or to_regprocedure('public.get_active_mining_fields()') is null
     or to_regprocedure('public.get_danger_zones()') is null
     or to_regprocedure('public.get_my_exploration_discoveries()') is null then
    raise exception 'WE-ENTITY-CATALOG: a gameplay reader (get_world_map/get_active_mining_fields/get_danger_zones/get_my_exploration_discoveries) is missing — this slice must NOT be what removed it';
  end if;
  -- the PostGIS ring/centroid primitives the zone normalization composes (public schema, search_path='' safe).
  if to_regprocedure('public.st_exteriorring(public.geometry)') is null
     or to_regprocedure('public.st_centroid(public.geometry)') is null
     or to_regprocedure('public.st_dumppoints(public.geometry)') is null then
    raise exception 'WE-ENTITY-CATALOG: a PostGIS primitive (st_exteriorring/st_centroid/st_dumppoints) is missing — the zone geometry normalization needs them';
  end if;
end $catdep$;

-- ── 1. world_editor_entity_catalog — the owner-only normalized lifecycle catalog (READ-ONLY) ──────
create or replace function public.world_editor_entity_catalog(p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_status text;
  v_bad    text;
  v_rows   jsonb;
begin
  -- (1) authn — reject the anonymous caller with a typed code (no read at all). [0243 idiom]
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  -- (2) authz — THE ONE guard, in-body on auth.uid(). Non-owner authenticated caller is rejected. [0243]
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  -- (3) input validation — status ∈ {active,inactive,all}, default 'all'. Unknown ⇒ typed validation_failed
  --     (the 0250/0266 details idiom), no read performed.
  v_status := lower(btrim(coalesce(p_payload->>'status', 'all')));
  if v_status not in ('active', 'inactive', 'all') then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'invalid_status', 'field', 'status',
               'message', 'status must be one of active | inactive | all.')));
  end if;

  -- (4) FAIL-CLOSED lifecycle-state invariant: refuse to serve a fail-open catalog if any entity carries an
  --     unsupported lifecycle state. locations.status is the 0002 enum (active|locked|hidden); danger_zones.status
  --     is the 0233 CHECK (active|inactive). mining/exploration use an is_active boolean (never unknown).
  select string_agg(id::text, ', ') into v_bad
    from (
      select l.id from public.locations l where l.status not in ('active', 'locked', 'hidden')
      union all
      select z.id from public.danger_zones z where z.status not in ('active', 'inactive')
    ) bad;
  if v_bad is not null then
    raise exception 'world_editor_entity_catalog: entity with an unsupported lifecycle state (refusing a fail-open catalog): %', v_bad;
  end if;

  -- (5) FAIL-CLOSED location coordinate-authority invariant: EVERY location (active OR inactive) must have
  --     EXACTLY ONE active location-kind anchor (the 0263/0264 sole coordinate authority). NEVER fall back to
  --     locations.x/y. A missing (or, defensively, duplicated) anchor is a broken invariant → raise.
  select string_agg(l.id::text, ', ') into v_bad
    from public.locations l
   where (select count(*) from public.space_anchors a
           where a.location_id = l.id and a.kind = 'location' and a.status = 'active') <> 1;
  if v_bad is not null then
    raise exception 'world_editor_entity_catalog: location(s) without exactly one active anchor (the coordinate authority) — refusing to fall back to locations.x/y: %', v_bad;
  end if;

  -- (6) FAIL-CLOSED zone geometry invariant: every danger_zones boundary must normalize to a closed vertex
  --     ring (>= 4 points). A degenerate/unnormalizable geometry is refused, never emitted as a null ring.
  select string_agg(z.id::text, ', ') into v_bad
    from public.danger_zones z
   where coalesce((select count(*) from public.st_dumppoints(public.st_exteriorring(z.boundary))), 0) < 4;
  if v_bad is not null then
    raise exception 'world_editor_entity_catalog: zone(s) whose geometry cannot be normalized to a closed ring: %', v_bad;
  end if;

  -- (7) build the deterministic normalized union across all 4 domains, then filter by lifecycle_status.
  with catalog as (
    -- LOCATIONS — coord from the ACTIVE location anchor (0263/0264), NEVER locations.x/y. Points (geometry null).
    -- INNER JOIN the active anchor: the fail-closed guard (5) has already proven exactly one exists per location.
    select
      'location'::text  as domain,
      l.id::text        as entity_id,
      l.name            as name,
      case l.status when 'active' then 'active' else 'inactive' end as lifecycle_status,
      null::bigint      as revision,
      jsonb_build_object('x', a.space_x, 'y', a.space_y) as point,
      null::jsonb       as geometry,
      null::timestamptz as updated_at
    from public.locations l
    join public.space_anchors a
      on a.location_id = l.id and a.kind = 'location' and a.status = 'active'

    union all
    -- MINING — native canonical space_x/space_y (±10000). reward_bundle_json is NEVER exposed. geometry null.
    select
      'mining', f.id::text, f.name,
      case when f.is_active then 'active' else 'inactive' end,
      null::bigint,
      jsonb_build_object('x', f.space_x, 'y', f.space_y),
      null::jsonb,
      null::timestamptz
    from public.mining_fields f

    union all
    -- EXPLORATION — native canonical space_x/space_y. reward_bundle_json is NEVER exposed. geometry null.
    select
      'exploration', s.id::text, s.name,
      case when s.is_active then 'active' else 'inactive' end,
      null::bigint,
      jsonb_build_object('x', s.space_x, 'y', s.space_y),
      null::jsonb,
      null::timestamptz
    from public.exploration_sites s

    union all
    -- ZONES — geometry = the get_danger_zones vertex-ring serialization, byte-for-byte (0233:1379-1388):
    -- jsonb_agg([ST_X,ST_Y] order by dump path) over ST_DumpPoints(ST_ExteriorRing(boundary)), wrapped in the
    -- normalized union {kind:'ring',ring:[...]}. GEOMETRY is authoritative; point = the derived centroid.
    select
      'zone', z.id::text, z.name,
      z.status,
      null::bigint,
      jsonb_build_object('x', public.st_x(public.st_centroid(z.boundary)),
                         'y', public.st_y(public.st_centroid(z.boundary))),
      jsonb_build_object('kind', 'ring', 'ring', (
        select jsonb_agg(jsonb_build_array(public.st_x(pt.geom), public.st_y(pt.geom)) order by pt.path[1])
          from public.st_dumppoints(public.st_exteriorring(z.boundary)) as pt)),
      z.updated_at
    from public.danger_zones z
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'domain', c.domain, 'entity_id', c.entity_id, 'name', c.name,
             'lifecycle_status', c.lifecycle_status, 'revision', c.revision,
             'point', c.point, 'geometry', c.geometry, 'updated_at', c.updated_at)
           -- deterministic ordering: domain, then normalized (lower/trim) name, then entity_id.
           order by c.domain, lower(btrim(c.name)), c.entity_id), '[]'::jsonb)
    into v_rows
    from catalog c
   where v_status = 'all' or c.lifecycle_status = v_status;

  return jsonb_build_object('ok', true, 'status', v_status, 'rows', v_rows);
end $$;

comment on function public.world_editor_entity_catalog(jsonb) is
  'WORLD EDITOR SLICE 1.5 (0269): the owner-only normalized LIFECYCLE CATALOG read — returns BOTH active and '
  'inactive entities across all 4 world-content domains (location/mining/exploration/zone) for the editor''s '
  'search/filter/map/jump/select/lifecycle surface. READ-ONLY (no table write anywhere). Reproduces the 0243 '
  'guard spine: authn (not_authenticated) → is_owner() authz (not_authorized) → input validation '
  '(status active|inactive|all, else validation_failed) → a deterministic array of normalized rows in a typed '
  '{ok,status,rows} envelope. Coordinate authorities are reused verbatim, never forked: locations read their '
  'ACTIVE space_anchor (0263/0264) and NEVER locations.x/y; mining/exploration read native canonical '
  'space_x/space_y; zones serialize the get_danger_zones vertex ring byte-for-byte with a centroid point. '
  'Fail-closed (raises, never silently omits): a location without exactly one active anchor, a zone whose '
  'geometry cannot normalize, an unsupported lifecycle state. reward_bundle_json and all server-only fields are '
  'excluded. Does NOT modify or replace any gameplay reader (get_world_map/get_active_mining_fields/'
  'get_danger_zones/get_my_exploration_discoveries left byte-identical). Execute is authenticated-only (guard '
  'in-body); NEVER anon/public.';

-- ── 2. ACL — authenticated may CALL (the guard is in-body); PUBLIC + anon may NOT. No table grant widened.
revoke all on function public.world_editor_entity_catalog(jsonb) from public;
revoke execute on function public.world_editor_entity_catalog(jsonb) from anon;
grant execute on function public.world_editor_entity_catalog(jsonb) to authenticated;  -- guard is in-body; NEVER anon

-- ── 3. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $catassert$
declare
  v_def text;
begin
  -- (a) the 0243 owner spine this read stands on exists.
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: is_owner() missing';
  end if;

  -- (b) the catalog exists, is SECURITY DEFINER, and pins search_path (a hijack would otherwise be possible).
  if to_regprocedure('public.world_editor_entity_catalog(jsonb)') is null then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: world_editor_entity_catalog(jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.world_editor_entity_catalog(jsonb)'::regprocedure and prosecdef) then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: world_editor_entity_catalog is not SECURITY DEFINER';
  end if;
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.world_editor_entity_catalog(jsonb)'::regprocedure
                   and exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')) then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: world_editor_entity_catalog does not pin search_path';
  end if;

  -- (c) ACL: authenticated MAY execute (in-body guard); anon/public MAY NOT.
  if not has_function_privilege('authenticated', 'public.world_editor_entity_catalog(jsonb)', 'execute') then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: authenticated cannot execute the catalog — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.world_editor_entity_catalog(jsonb)', 'execute') then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: anon CAN execute the catalog — must be authenticated-only';
  end if;

  -- (d) READ-ONLY: the body performs NO table write (no insert/update/delete into any table). A cheap, robust
  --     source-text guard — the catalog must never mutate world state.
  v_def := lower(pg_get_functiondef('public.world_editor_entity_catalog(jsonb)'::regprocedure));
  if position('insert into' in v_def) > 0
     or position('update public.' in v_def) > 0
     or position('delete from' in v_def) > 0 then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: the catalog body contains a table write — it must be read-only';
  end if;

  -- (e) the catalog reads the ACTIVE location ANCHOR and NEVER the legacy locations.x/y coordinate (the sole
  --     coordinate authority for locations is the 0263/0264 anchor).
  if position('space_anchors' in v_def) = 0 then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: the catalog does not read space_anchors — the location coordinate authority is wrong';
  end if;
  if position('l.x' in v_def) > 0 or position('l.y' in v_def) > 0 then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: the catalog references the legacy locations.x/y — the anchor is the sole coordinate authority';
  end if;

  -- (f) the gameplay readers are UNTOUCHED: all four still exist and keep their client execute grants (this
  --     slice must not have modified or de-granted any of them).
  if to_regprocedure('public.get_world_map()') is null
     or to_regprocedure('public.get_active_mining_fields()') is null
     or to_regprocedure('public.get_danger_zones()') is null
     or to_regprocedure('public.get_my_exploration_discoveries()') is null then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: a gameplay reader vanished — this slice must not touch the gameplay readers';
  end if;
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute')
     or not has_function_privilege('anon', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_active_mining_fields()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_my_exploration_discoveries()', 'execute') then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: a gameplay reader lost a client execute grant — this slice must leave the read surface unchanged';
  end if;

  -- (g) no client-role WRITE grant was added to any source domain table by this slice (the catalog is a pure
  --     read; it must widen nothing). This mirrors the 0250/0268 write-lockdown posture (SELECT is unrelated).
  if has_table_privilege('authenticated', 'public.mining_fields', 'INSERT')
     or has_table_privilege('authenticated', 'public.mining_fields', 'UPDATE')
     or has_table_privilege('authenticated', 'public.mining_fields', 'DELETE')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'INSERT')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'UPDATE')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'DELETE')
     or has_table_privilege('authenticated', 'public.space_anchors', 'INSERT')
     or has_table_privilege('authenticated', 'public.space_anchors', 'UPDATE')
     or has_table_privilege('authenticated', 'public.space_anchors', 'DELETE') then
    raise exception 'WE-ENTITY-CATALOG self-assert FAIL: a client role holds a WRITE grant on a source domain table — this slice must add no table write';
  end if;

  raise notice 'WE-ENTITY-CATALOG self-assert ok: catalog SECURITY DEFINER + search_path pinned + authenticated-only (anon revoked); read-only (no table write); reads the active space_anchor not locations.x/y; all 4 gameplay readers intact with client grants; no source-table write grant added';
end $catassert$;
