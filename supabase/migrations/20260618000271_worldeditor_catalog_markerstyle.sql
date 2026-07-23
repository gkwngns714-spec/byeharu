-- Byeharu — WORLD EDITOR: enrich world_editor_entity_catalog with the four location marker-style fields.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE GAP THIS CLOSES: the World Editor map is now sourced SOLELY from world_editor_entity_catalog (0269),
-- but that catalog row does NOT carry the four fields the client marker policy (src/features/map/markerStyle.ts)
-- reads to style a location by type — location_type / activity_type / reward_tier / base_difficulty — so every
-- active location renders as a GENERIC marker (no danger triangle, no dockable-port diamond, no importance tier).
-- This migration adds EXACTLY those four fields to the catalog rows, populated ONLY for location rows, straight
-- from the public.locations row. Nothing else about the catalog changes.
--
-- WHAT THIS IS NOT: it does NOT derive marker STYLE server-side (no shape/color/radius — that stays the client's
-- pure policy in markerStyle.ts), it does NOT add a generic style JSON blob, it does NOT modify or replace any
-- gameplay reader (get_world_map / get_active_mining_fields / get_danger_zones / get_my_exploration_discoveries
-- are left BYTE-IDENTICAL — this migration does not CREATE OR REPLACE any of them), and it modifies NO stored
-- entity row. It writes NOTHING — no table write privilege is added anywhere; the function stays READ-ONLY
-- (SECURITY DEFINER only so it can read the RLS-private domain tables, exactly as 0269 already does).
--
-- THE ONLY CHANGE vs 0269: four additive, NULLABLE keys on every returned row —
--   location_type   text|null              — from public.locations.location_type    (NULL for non-location rows)
--   activity_type   text|null              — from public.locations.activity_type    (NULL for non-location rows)
--   reward_tier     integer|null           — from public.locations.reward_tier      (integer; NULL otherwise)
--   base_difficulty double precision|null  — from public.locations.base_difficulty  (float8;  NULL otherwise)
-- Populated (for BOTH active and inactive locations) ONLY when domain='location', read DIRECTLY from the
-- location row. NULL for every mining / exploration / zone row. EVERYTHING ELSE — the existing 8 keys, the
-- coordinate authorities, the fail-closed invariants, the deterministic ordering, the status filter, the typed
-- envelope, and the full security contract — is reproduced VERBATIM from 0269.
--
-- NO-SPAGHETTI: still ONE owner guard (public.is_owner(), the 0243 spine, in-body), still ONE coordinate
-- authority per domain reused verbatim (locations → their ACTIVE space_anchor, NEVER locations.x/y). No new
-- coordinate source, no new geometry engine, no forked reader, no reward/audit/internal field leaked. The four
-- new fields are already client-visible on the same locations via get_world_map — this is not a new exposure.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Prod head is 20260618000270; this is the next migration
-- (0271), forward-only, applied AFTER 0270. Fail-closed by design: even deployed, the capability is inert until
-- an owner is seeded into app_owners (is_owner() is false for everyone on an unseeded DB). No client grant is
-- widened; execute stays authenticated-only (the guard is in-body) and explicitly revoked from PUBLIC and anon.
--
-- FAIL-CLOSED (unchanged from 0269 — raise, never silently omit or fall back):
--   • a location (active OR inactive) that lacks EXACTLY ONE active location-kind anchor — the sole coordinate
--     authority; NEVER fall back to locations.x/y;
--   • a danger_zones boundary that cannot be normalized to a closed vertex ring (>= 4 points);
--   • an entity with an unsupported/unknown lifecycle state.
--
-- NORMALIZED ROW CONTRACT (each element of result.rows) — the 0269 contract PLUS the four additive keys:
--   { domain:'location'|'mining'|'exploration'|'zone', entity_id:<uuid text>, name:text,
--     lifecycle_status:'active'|'inactive', revision:<number|null>, point:{x,y}|null,
--     geometry:{kind:'ring',ring:[[x,y]...]}|null, updated_at:timestamptz|null,
--     location_type:text|null, activity_type:text|null, reward_tier:int|null, base_difficulty:float8|null }
--   • the four new keys are non-null ONLY for domain='location'; null for mining / exploration / zone.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice reads / promises to leave intact vanished.
do $catdep$
begin
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'WE-CATALOG-MARKERSTYLE: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regclass('public.locations') is null or to_regclass('public.space_anchors') is null
     or to_regclass('public.mining_fields') is null or to_regclass('public.exploration_sites') is null
     or to_regclass('public.danger_zones') is null then
    raise exception 'WE-CATALOG-MARKERSTYLE: a source domain table (locations/space_anchors/mining_fields/exploration_sites/danger_zones) is missing';
  end if;
  -- the catalog we are redefining must already exist (this is an enrichment of 0269, not a first definition).
  if to_regprocedure('public.world_editor_entity_catalog(jsonb)') is null then
    raise exception 'WE-CATALOG-MARKERSTYLE: world_editor_entity_catalog(jsonb) (0269) is missing — this migration enriches it, it does not create it';
  end if;
  -- the gameplay readers this slice PROMISES to leave intact must exist (never be the thing that removed one).
  if to_regprocedure('public.get_world_map()') is null
     or to_regprocedure('public.get_active_mining_fields()') is null
     or to_regprocedure('public.get_danger_zones()') is null
     or to_regprocedure('public.get_my_exploration_discoveries()') is null then
    raise exception 'WE-CATALOG-MARKERSTYLE: a gameplay reader (get_world_map/get_active_mining_fields/get_danger_zones/get_my_exploration_discoveries) is missing — this slice must NOT be what removed it';
  end if;
  -- the PostGIS ring/centroid primitives the zone normalization composes (public schema, search_path='' safe).
  if to_regprocedure('public.st_exteriorring(public.geometry)') is null
     or to_regprocedure('public.st_centroid(public.geometry)') is null
     or to_regprocedure('public.st_dumppoints(public.geometry)') is null then
    raise exception 'WE-CATALOG-MARKERSTYLE: a PostGIS primitive (st_exteriorring/st_centroid/st_dumppoints) is missing — the zone geometry normalization needs them';
  end if;
end $catdep$;

-- ── 1. world_editor_entity_catalog — REDEFINED verbatim from 0269 + four additive marker-style keys ───
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
    -- 0271: the four marker-style fields are read DIRECTLY from the location row (BOTH active and inactive) —
    -- location_type / activity_type / reward_tier (integer) / base_difficulty (double precision). NEVER derived.
    select
      'location'::text  as domain,
      l.id::text        as entity_id,
      l.name            as name,
      case l.status when 'active' then 'active' else 'inactive' end as lifecycle_status,
      null::bigint      as revision,
      jsonb_build_object('x', a.space_x, 'y', a.space_y) as point,
      null::jsonb       as geometry,
      null::timestamptz as updated_at,
      l.location_type::text            as marker_location_type,
      l.activity_type::text            as marker_activity_type,
      l.reward_tier::integer           as marker_reward_tier,       -- public.locations.reward_tier     is integer (0002:60)
      l.base_difficulty::double precision as marker_base_difficulty -- public.locations.base_difficulty is double precision (0002:59)
    from public.locations l
    join public.space_anchors a
      on a.location_id = l.id and a.kind = 'location' and a.status = 'active'

    union all
    -- MINING — native canonical space_x/space_y (±10000). reward_bundle_json is NEVER exposed. geometry null.
    -- The four marker-style fields are location-only → NULL here.
    select
      'mining', f.id::text, f.name,
      case when f.is_active then 'active' else 'inactive' end,
      null::bigint,
      jsonb_build_object('x', f.space_x, 'y', f.space_y),
      null::jsonb,
      null::timestamptz,
      null::text, null::text, null::integer, null::double precision
    from public.mining_fields f

    union all
    -- EXPLORATION — native canonical space_x/space_y. reward_bundle_json is NEVER exposed. geometry null.
    -- The four marker-style fields are location-only → NULL here.
    select
      'exploration', s.id::text, s.name,
      case when s.is_active then 'active' else 'inactive' end,
      null::bigint,
      jsonb_build_object('x', s.space_x, 'y', s.space_y),
      null::jsonb,
      null::timestamptz,
      null::text, null::text, null::integer, null::double precision
    from public.exploration_sites s

    union all
    -- ZONES — geometry = the get_danger_zones vertex-ring serialization, byte-for-byte (0233:1379-1388):
    -- jsonb_agg([ST_X,ST_Y] order by dump path) over ST_DumpPoints(ST_ExteriorRing(boundary)), wrapped in the
    -- normalized union {kind:'ring',ring:[...]}. GEOMETRY is authoritative; point = the derived centroid.
    -- The four marker-style fields are location-only → NULL here.
    select
      'zone', z.id::text, z.name,
      z.status,
      null::bigint,
      jsonb_build_object('x', public.st_x(public.st_centroid(z.boundary)),
                         'y', public.st_y(public.st_centroid(z.boundary))),
      jsonb_build_object('kind', 'ring', 'ring', (
        select jsonb_agg(jsonb_build_array(public.st_x(pt.geom), public.st_y(pt.geom)) order by pt.path[1])
          from public.st_dumppoints(public.st_exteriorring(z.boundary)) as pt)),
      z.updated_at,
      null::text, null::text, null::integer, null::double precision
    from public.danger_zones z
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'domain', c.domain, 'entity_id', c.entity_id, 'name', c.name,
             'lifecycle_status', c.lifecycle_status, 'revision', c.revision,
             'point', c.point, 'geometry', c.geometry, 'updated_at', c.updated_at,
             -- 0271: the four additive marker-style keys — populated only for domain='location', null otherwise.
             'location_type', c.marker_location_type, 'activity_type', c.marker_activity_type,
             'reward_tier', c.marker_reward_tier, 'base_difficulty', c.marker_base_difficulty)
           -- deterministic ordering: domain, then normalized (lower/trim) name, then entity_id.
           order by c.domain, lower(btrim(c.name)), c.entity_id), '[]'::jsonb)
    into v_rows
    from catalog c
   where v_status = 'all' or c.lifecycle_status = v_status;

  return jsonb_build_object('ok', true, 'status', v_status, 'rows', v_rows);
end $$;

comment on function public.world_editor_entity_catalog(jsonb) is
  'WORLD EDITOR (0269 + 0271 marker-style enrichment): the owner-only normalized LIFECYCLE CATALOG read — '
  'returns BOTH active and inactive entities across all 4 world-content domains (location/mining/exploration/'
  'zone) for the editor''s search/filter/map/jump/select/lifecycle surface. READ-ONLY (no table write anywhere). '
  'Reproduces the 0243 guard spine: authn (not_authenticated) → is_owner() authz (not_authorized) → input '
  'validation (status active|inactive|all, else validation_failed) → a deterministic array of normalized rows in '
  'a typed {ok,status,rows} envelope. Coordinate authorities are reused verbatim, never forked: locations read '
  'their ACTIVE space_anchor (0263/0264) and NEVER locations.x/y; mining/exploration read native canonical '
  'space_x/space_y; zones serialize the get_danger_zones vertex ring byte-for-byte with a centroid point. '
  'Fail-closed (raises, never silently omits): a location without exactly one active anchor, a zone whose '
  'geometry cannot normalize, an unsupported lifecycle state. 0271 adds four ADDITIVE, NULLABLE keys — '
  'location_type/activity_type/reward_tier/base_difficulty — read DIRECTLY from the public.locations row for '
  'BOTH active and inactive locations, and NULL for mining/exploration/zone rows; the client marker policy '
  '(markerStyle.ts) derives shape/color/importance from them — the server derives NO style. reward_bundle_json '
  'and all server-only fields are still excluded. Does NOT modify or replace any gameplay reader '
  '(get_world_map/get_active_mining_fields/get_danger_zones/get_my_exploration_discoveries left byte-identical). '
  'Execute is authenticated-only (guard in-body); NEVER anon/public.';

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
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: is_owner() missing';
  end if;

  -- (b) the catalog exists, is SECURITY DEFINER, and pins search_path (a hijack would otherwise be possible).
  if to_regprocedure('public.world_editor_entity_catalog(jsonb)') is null then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: world_editor_entity_catalog(jsonb) missing';
  end if;
  if not exists (select 1 from pg_proc
                 where oid = 'public.world_editor_entity_catalog(jsonb)'::regprocedure and prosecdef) then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: world_editor_entity_catalog is not SECURITY DEFINER';
  end if;
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.world_editor_entity_catalog(jsonb)'::regprocedure
                   and exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')) then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: world_editor_entity_catalog does not pin search_path';
  end if;

  -- (c) ACL: authenticated MAY execute (in-body guard); anon/public MAY NOT.
  if not has_function_privilege('authenticated', 'public.world_editor_entity_catalog(jsonb)', 'execute') then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: authenticated cannot execute the catalog — the in-body guard would be unreachable';
  end if;
  if has_function_privilege('anon', 'public.world_editor_entity_catalog(jsonb)', 'execute') then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: anon CAN execute the catalog — must be authenticated-only';
  end if;

  -- (d) READ-ONLY: the body performs NO table write (no insert/update/delete into any table). A cheap, robust
  --     source-text guard — the catalog must never mutate world state.
  v_def := lower(pg_get_functiondef('public.world_editor_entity_catalog(jsonb)'::regprocedure));
  if position('insert into' in v_def) > 0
     or position('update public.' in v_def) > 0
     or position('delete from' in v_def) > 0 then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: the catalog body contains a table write — it must be read-only';
  end if;

  -- (e) the catalog reads the ACTIVE location ANCHOR and NEVER the legacy locations.x/y coordinate (the sole
  --     coordinate authority for locations is the 0263/0264 anchor).
  if position('space_anchors' in v_def) = 0 then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: the catalog does not read space_anchors — the location coordinate authority is wrong';
  end if;
  if position('l.x' in v_def) > 0 or position('l.y' in v_def) > 0 then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: the catalog references the legacy locations.x/y — the anchor is the sole coordinate authority';
  end if;

  -- (f) 0271 marker-style enrichment: the four additive keys are built into the row, and are sourced DIRECTLY
  --     from the locations row (never derived server-side). Source-text presence + provenance guard.
  if position('''location_type''' in v_def) = 0 or position('''activity_type''' in v_def) = 0
     or position('''reward_tier''' in v_def) = 0 or position('''base_difficulty''' in v_def) = 0 then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: a marker-style key (location_type/activity_type/reward_tier/base_difficulty) is not built into the catalog row';
  end if;
  if position('l.location_type' in v_def) = 0 or position('l.activity_type' in v_def) = 0
     or position('l.reward_tier' in v_def) = 0 or position('l.base_difficulty' in v_def) = 0 then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: a marker-style field is not read from the public.locations row — it must not be derived';
  end if;
  -- and NO server-side style was introduced (no shape/color/marker_style style blob leaked into the body).
  if position('marker_style' in v_def) > 0 or position('''shape''' in v_def) > 0 or position('''color''' in v_def) > 0 then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: the catalog derives a server-side marker style — style must stay the client''s pure policy';
  end if;

  -- (g) the gameplay readers are UNTOUCHED: all four still exist and keep their client execute grants (this
  --     slice must not have modified or de-granted any of them).
  if to_regprocedure('public.get_world_map()') is null
     or to_regprocedure('public.get_active_mining_fields()') is null
     or to_regprocedure('public.get_danger_zones()') is null
     or to_regprocedure('public.get_my_exploration_discoveries()') is null then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: a gameplay reader vanished — this slice must not touch the gameplay readers';
  end if;
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute')
     or not has_function_privilege('anon', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_active_mining_fields()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_my_exploration_discoveries()', 'execute') then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: a gameplay reader lost a client execute grant — this slice must leave the read surface unchanged';
  end if;

  -- (h) no client-role WRITE grant was added to any source domain table by this slice (the catalog is a pure
  --     read; it must widen nothing). This mirrors the 0250/0268 write-lockdown posture (SELECT is unrelated).
  if has_table_privilege('authenticated', 'public.mining_fields', 'INSERT')
     or has_table_privilege('authenticated', 'public.mining_fields', 'UPDATE')
     or has_table_privilege('authenticated', 'public.mining_fields', 'DELETE')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'INSERT')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'UPDATE')
     or has_table_privilege('authenticated', 'public.exploration_sites', 'DELETE')
     or has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.locations', 'DELETE')
     or has_table_privilege('authenticated', 'public.space_anchors', 'INSERT')
     or has_table_privilege('authenticated', 'public.space_anchors', 'UPDATE')
     or has_table_privilege('authenticated', 'public.space_anchors', 'DELETE') then
    raise exception 'WE-CATALOG-MARKERSTYLE self-assert FAIL: a client role holds a WRITE grant on a source domain table — this slice must add no table write';
  end if;

  raise notice 'WE-CATALOG-MARKERSTYLE self-assert ok: catalog SECURITY DEFINER + search_path pinned + authenticated-only (anon revoked); read-only (no table write); reads the active space_anchor not locations.x/y; four additive marker-style keys built from the locations row (no server-side style); all 4 gameplay readers intact with client grants; no source-table write grant added';
end $catassert$;
