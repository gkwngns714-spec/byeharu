-- WORLD EDITOR CATALOG MARKER-STYLE — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0271 (20260618000271_worldeditor_catalog_markerstyle.sql) after the FULL chain is applied by
-- `supabase start`: world_editor_entity_catalog(jsonb) is REDEFINED to add four additive, NULLABLE marker-style
-- keys — location_type / activity_type / reward_tier / base_difficulty — populated ONLY for location rows,
-- straight from public.locations, and NULL for mining/exploration/zone rows, while EVERYTHING ELSE about the
-- catalog stays byte-identical to 0269. It drives the whole contract end to end:
--   (1) active location rows carry all four fields with the CORRECT values read from public.locations;
--   (2) inactive location rows carry all four fields with the CORRECT values (BOTH lifecycles enriched);
--   (3) mining / exploration / zone rows carry all four keys PRESENT and equal to JSON null;
--   (4) BYTE-IDENTITY: with the four new keys stripped, the 0271 catalog output is byte-identical to the
--       pre-0271 (0269) output — captured here via a verbatim 0269 SHADOW function — for status active/inactive/all
--       (every existing field: domain/entity_id/name/lifecycle_status/revision/point/geometry/updated_at, plus
--       the {ok,status} envelope, is unchanged; ONLY the four keys are added);
--   (5) the gameplay readers (get_world_map/get_active_mining_fields/get_danger_zones) stay BYTE-IDENTICAL across
--       a catalog call and none reference the catalog;
--   (6) a catalog call MUTATES NOTHING (audit/anchor/zone/mining/exploration/location row counts stable);
--   (7) the security contract is intact: SECURITY DEFINER, search_path pinned, authenticated-only, anon revoked,
--       and a non-owner / anonymous caller are rejected (not_authorized / not_authenticated).
-- The migration's OWN in-migration self-assert (SECURITY DEFINER, search_path pinned, authenticated-only, anon
-- revoked, read-only, anchor-not-x/y, the four keys built from the locations row with NO server-side style, all
-- 4 gameplay readers intact, no source-table write grant) ran during `supabase start` — any regression there
-- aborts the apply RED before this proof even runs.
--
-- Self-rolling-back: everything runs inside one begin;…rollback; — ZERO persisted state. The owner it "seeds" is
-- a synthetic auth.users row created HERE. NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ══ SHADOW 0269 — the pre-0271 catalog, reproduced VERBATIM so proof (4) can diff against a real capture ══════
-- This is byte-for-byte the 0269 body under a different name; it is the "capture 0269 output" leg of the diff.
create or replace function public.we_cat_shadow_0269(p_payload jsonb default '{}'::jsonb)
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
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;
  v_status := lower(btrim(coalesce(p_payload->>'status', 'all')));
  if v_status not in ('active', 'inactive', 'all') then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'invalid_status', 'field', 'status',
               'message', 'status must be one of active | inactive | all.')));
  end if;
  select string_agg(id::text, ', ') into v_bad
    from (
      select l.id from public.locations l where l.status not in ('active', 'locked', 'hidden')
      union all
      select z.id from public.danger_zones z where z.status not in ('active', 'inactive')
    ) bad;
  if v_bad is not null then
    raise exception 'shadow: unsupported lifecycle state: %', v_bad;
  end if;
  select string_agg(l.id::text, ', ') into v_bad
    from public.locations l
   where (select count(*) from public.space_anchors a
           where a.location_id = l.id and a.kind = 'location' and a.status = 'active') <> 1;
  if v_bad is not null then
    raise exception 'shadow: location(s) without exactly one active anchor: %', v_bad;
  end if;
  select string_agg(z.id::text, ', ') into v_bad
    from public.danger_zones z
   where coalesce((select count(*) from public.st_dumppoints(public.st_exteriorring(z.boundary))), 0) < 4;
  if v_bad is not null then
    raise exception 'shadow: zone(s) whose geometry cannot normalize: %', v_bad;
  end if;
  with catalog as (
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
    select
      'mining', f.id::text, f.name,
      case when f.is_active then 'active' else 'inactive' end,
      null::bigint,
      jsonb_build_object('x', f.space_x, 'y', f.space_y),
      null::jsonb,
      null::timestamptz
    from public.mining_fields f
    union all
    select
      'exploration', s.id::text, s.name,
      case when s.is_active then 'active' else 'inactive' end,
      null::bigint,
      jsonb_build_object('x', s.space_x, 'y', s.space_y),
      null::jsonb,
      null::timestamptz
    from public.exploration_sites s
    union all
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
           order by c.domain, lower(btrim(c.name)), c.entity_id), '[]'::jsonb)
    into v_rows
    from catalog c
   where v_status = 'all' or c.lifecycle_status = v_status;
  return jsonb_build_object('ok', true, 'status', v_status, 'rows', v_rows);
end $$;

-- ══ FIXTURES ═══════════════════════════════════════════════════════════════════════════════════════
-- synthetic OWNER + NON-OWNER; one active + one inactive LOCATION (each with EXPLICIT, distinct marker-style
-- fields + its own active anchor at coords ≠ locations.x/y), plus active+inactive mining/exploration and an
-- active + an unpublished zone so the marker-null + byte-identity diffs cover all 4 domains.
create temp table msuids(k text primary key, v uuid) on commit drop;
insert into msuids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'wems.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from msuids;

insert into public.app_owners(user_id) select v from msuids where k = 'owner';

create temp table msfx(k text primary key, v uuid) on commit drop;
do $setup$
declare
  v_zone uuid; v_owner uuid;
  v_la uuid; v_li uuid; v_ma uuid; v_mi uuid; v_ea uuid; v_ei uuid;
  r jsonb;
begin
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'MARKERSTYLE PROOF SETUP FAIL: the seeded chain has no zones to host the location fixtures';
  end if;

  -- ACTIVE location: EXPLICIT non-default marker fields (pirate_hunt / hunt_pirates / tier 4 / difficulty 27.5).
  insert into public.locations (zone_id, name, location_type, activity_type, reward_tier, base_difficulty, x, y, is_public, status)
    values (v_zone, 'MS-Loc-Active', 'pirate_hunt', 'hunt_pirates', 4, 27.5, 111, 222, true, 'active')
    returning id into v_la;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_la, 1234, -1234, 'active');

  -- INACTIVE location: a DIFFERENT explicit combination (trade_outpost / trade_visit / tier 2 / difficulty 13).
  insert into public.locations (zone_id, name, location_type, activity_type, reward_tier, base_difficulty, x, y, is_public, status)
    values (v_zone, 'MS-Loc-Inactive', 'trade_outpost', 'trade_visit', 2, 13, 333, 444, true, 'locked')
    returning id into v_li;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_li, 4321, -4321, 'active');

  insert into public.mining_fields (name, space_x, space_y, reward_bundle_json, is_active)
    values ('MS-Mine-Active', 2000, 2000, '{"items":[{"item_id":"ore","quantity":1}]}'::jsonb, true)
    returning id into v_ma;
  insert into public.mining_fields (name, space_x, space_y, reward_bundle_json, is_active)
    values ('MS-Mine-Inactive', -2000, -2000, '{"items":[{"item_id":"ore","quantity":1}]}'::jsonb, false)
    returning id into v_mi;

  insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json, is_active)
    values ('MS-Expl-Active', 3000, -3000, '{"metal":10,"items":[{"item_id":"scan_data","quantity":1}]}'::jsonb, true)
    returning id into v_ea;
  insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json, is_active)
    values ('MS-Expl-Inactive', -3000, 3000, '{"metal":10,"items":[{"item_id":"scan_data","quantity":1}]}'::jsonb, false)
    returning id into v_ei;

  insert into msfx values
    ('la', v_la), ('li', v_li), ('ma', v_ma), ('mi', v_mi), ('ea', v_ea), ('ei', v_ei);

  -- ZONES created through the real 0254 zone_create (owner JWT) so geometry is authentic.
  select v into v_owner from msuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.zone_create('ms-zone-active-req', jsonb_build_object(
         'source_revision','ms-za-rev',
         'fields', jsonb_build_object('name','MS-Zone-Active','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center',jsonb_build_object('x',1500,'y',-1500),'radius',120))));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZA create not ok: %', r; end if;
  insert into msfx values ('za', (r->'result'->>'id')::uuid);

  r := public.zone_create('ms-zone-inactive-req', jsonb_build_object(
         'source_revision','ms-zi-rev',
         'fields', jsonb_build_object('name','MS-Zone-Inactive','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center',jsonb_build_object('x',-1500,'y',1500),'radius',120))));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZI create not ok: %', r; end if;
  insert into msfx values ('zi', (r->'result'->>'id')::uuid);
  r := public.zone_unpublish('ms-zone-inactive-unpub-req', jsonb_build_object(
         'target_id', (select v from msfx where k='zi')::text,
         'expected', jsonb_build_object('name','MS-Zone-Inactive','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZI unpublish not ok: %', r; end if;

  raise notice 'WE_MS_SETUP_OK';
end $setup$;

-- ══ PROOF 7a — UNAUTHORIZED + ANON are rejected; invalid status is validation_failed ═══════════════
do $$
declare v_no uuid; r jsonb;
begin
  select v into v_no from msuids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog('{}'::jsonb);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'MARKERSTYLE PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.world_editor_entity_catalog('{}'::jsonb);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'MARKERSTYLE PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  if has_function_privilege('anon', 'public.world_editor_entity_catalog(jsonb)', 'execute') then
    raise exception 'MARKERSTYLE PROOF FAIL: anon holds EXECUTE on the catalog — must be authenticated-only';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', (select v from msuids where k='owner')::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','bogus'));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or (r->'details'->0->>'code') <> 'invalid_status' then
    raise exception 'MARKERSTYLE PROOF FAIL: an unknown status was not validation_failed/invalid_status: %', r;
  end if;
  raise notice 'WE_MS_PASS_AUTHZ';
end $$;

-- ══ PROOF 1 — ACTIVE location row carries all four marker fields with CORRECT values from public.locations ══
do $$
declare v_owner uuid; v_la uuid; r jsonb; e jsonb;
begin
  select v into v_owner from msuids where k = 'owner';
  select v into v_la from msfx where k = 'la';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','active'));
  select el into e from jsonb_array_elements(r->'rows') el where (el->>'entity_id') = v_la::text;
  if e is null then raise exception 'MARKERSTYLE PROOF FAIL: active location row missing'; end if;
  -- all four keys PRESENT.
  if not (e ? 'location_type' and e ? 'activity_type' and e ? 'reward_tier' and e ? 'base_difficulty') then
    raise exception 'MARKERSTYLE PROOF FAIL: active location row is missing one of the four marker keys: %', e;
  end if;
  -- and each equal to the public.locations value.
  if e->>'location_type' <> 'pirate_hunt' or e->>'activity_type' <> 'hunt_pirates'
     or (e->>'reward_tier')::int <> 4 or (e->>'base_difficulty')::float <> 27.5 then
    raise exception 'MARKERSTYLE PROOF FAIL: active location marker fields wrong (expected pirate_hunt/hunt_pirates/4/27.5): %', e;
  end if;
  -- cross-check DIRECTLY against the locations row (provenance: read from the row, not derived).
  if exists (select 1 from public.locations l where l.id = v_la
             and (l.location_type <> e->>'location_type' or l.activity_type <> e->>'activity_type'
                  or l.reward_tier <> (e->>'reward_tier')::int or l.base_difficulty <> (e->>'base_difficulty')::float)) then
    raise exception 'MARKERSTYLE PROOF FAIL: active location marker fields do not match the locations row';
  end if;
  raise notice 'WE_MS_PASS_ACTIVE_LOCATION_FIELDS';
end $$;

-- ══ PROOF 2 — INACTIVE location row ALSO carries all four fields with correct values (both lifecycles) ══
do $$
declare v_owner uuid; v_li uuid; r jsonb; e jsonb;
begin
  select v into v_owner from msuids where k = 'owner';
  select v into v_li from msfx where k = 'li';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','inactive'));
  select el into e from jsonb_array_elements(r->'rows') el where (el->>'entity_id') = v_li::text;
  if e is null then raise exception 'MARKERSTYLE PROOF FAIL: inactive location row missing'; end if;
  if not (e ? 'location_type' and e ? 'activity_type' and e ? 'reward_tier' and e ? 'base_difficulty') then
    raise exception 'MARKERSTYLE PROOF FAIL: inactive location row is missing one of the four marker keys: %', e;
  end if;
  if e->>'location_type' <> 'trade_outpost' or e->>'activity_type' <> 'trade_visit'
     or (e->>'reward_tier')::int <> 2 or (e->>'base_difficulty')::float <> 13 then
    raise exception 'MARKERSTYLE PROOF FAIL: inactive location marker fields wrong (expected trade_outpost/trade_visit/2/13): %', e;
  end if;
  if e->>'lifecycle_status' <> 'inactive' then raise exception 'MARKERSTYLE PROOF FAIL: inactive row not lifecycle inactive'; end if;
  raise notice 'WE_MS_PASS_INACTIVE_LOCATION_FIELDS';
end $$;

-- ══ PROOF 3 — mining / exploration / zone rows carry all four keys PRESENT and equal to JSON null ══════
do $$
declare v_owner uuid; r jsonb; e jsonb; k text; dom text;
begin
  select v into v_owner from msuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  foreach k in array array['ma','mi','ea','ei','za','zi'] loop
    select el into e from jsonb_array_elements(r->'rows') el where (el->>'entity_id') = (select v from msfx where msfx.k = k)::text;
    if e is null then raise exception 'MARKERSTYLE PROOF FAIL: non-location fixture % missing from status=all', k; end if;
    dom := e->>'domain';
    if dom = 'location' then raise exception 'MARKERSTYLE PROOF FAIL: fixture % unexpectedly a location', k; end if;
    -- all four keys PRESENT ...
    if not (e ? 'location_type' and e ? 'activity_type' and e ? 'reward_tier' and e ? 'base_difficulty') then
      raise exception 'MARKERSTYLE PROOF FAIL: fixture % (domain %) is missing one of the four marker keys: %', k, dom, e;
    end if;
    -- ... and every one is JSON null.
    if e->'location_type' <> 'null'::jsonb or e->'activity_type' <> 'null'::jsonb
       or e->'reward_tier' <> 'null'::jsonb or e->'base_difficulty' <> 'null'::jsonb then
      raise exception 'MARKERSTYLE PROOF FAIL: fixture % (domain %) has a non-null marker field (must be null for non-location): %', k, dom, e;
    end if;
  end loop;
  raise notice 'WE_MS_PASS_NONLOCATION_NULL';
end $$;

-- ══ PROOF 4 — BYTE-IDENTITY: strip the four new keys from the 0271 output ⇒ byte-identical to 0269 (shadow) ══
do $$
declare v_owner uuid; st text; r0271 jsonb; r0269 jsonb; stripped jsonb;
begin
  select v into v_owner from msuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  foreach st in array array['active','inactive','all'] loop
    r0271 := public.world_editor_entity_catalog(jsonb_build_object('status', st));
    r0269 := public.we_cat_shadow_0269(jsonb_build_object('status', st));
    -- envelope (ok,status) unchanged.
    if (r0271 - 'rows') is distinct from (r0269 - 'rows') then
      raise exception 'MARKERSTYLE PROOF FAIL: envelope changed for status=% (0271 %, 0269 %)', st, (r0271 - 'rows'), (r0269 - 'rows');
    end if;
    -- strip the four additive keys from every 0271 row, preserving order, and diff against the 0269 rows.
    select coalesce(jsonb_agg(
             (t.e - 'location_type' - 'activity_type' - 'reward_tier' - 'base_difficulty') order by t.ord), '[]'::jsonb)
      into stripped
      from jsonb_array_elements(r0271->'rows') with ordinality as t(e, ord);
    if stripped is distinct from (r0269->'rows') then
      raise exception 'MARKERSTYLE PROOF FAIL: for status=%, the 0271 catalog MINUS the four keys is NOT byte-identical to 0269', st;
    end if;
    -- and confirm the ONLY added keys are exactly the four (no other key crept in).
    if exists (
      select 1 from jsonb_array_elements(r0271->'rows') el, jsonb_object_keys(el) key
      where key not in ('domain','entity_id','name','lifecycle_status','revision','point','geometry','updated_at',
                        'location_type','activity_type','reward_tier','base_difficulty')) then
      raise exception 'MARKERSTYLE PROOF FAIL: a 0271 row has a key beyond the 8 original + 4 new keys (status=%)', st;
    end if;
  end loop;
  raise notice 'WE_MS_PASS_BYTE_IDENTICAL_EXCEPT_FOUR_KEYS';
end $$;

-- ══ PROOF 5 — the gameplay readers stay BYTE-IDENTICAL across a catalog call and none reference the catalog ══
do $$
declare v_owner uuid; wm1 jsonb; wm2 jsonb; mf1 jsonb; mf2 jsonb; dz1 jsonb; dz2 jsonb;
begin
  select v into v_owner from msuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  wm1 := public.get_world_map(); mf1 := public.get_active_mining_fields(); dz1 := public.get_danger_zones();
  perform public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  wm2 := public.get_world_map(); mf2 := public.get_active_mining_fields(); dz2 := public.get_danger_zones();
  if wm1 is distinct from wm2 then raise exception 'MARKERSTYLE PROOF FAIL: get_world_map changed across a catalog call'; end if;
  if mf1 is distinct from mf2 then raise exception 'MARKERSTYLE PROOF FAIL: get_active_mining_fields changed across a catalog call'; end if;
  if dz1 is distinct from dz2 then raise exception 'MARKERSTYLE PROOF FAIL: get_danger_zones changed across a catalog call'; end if;
  if position('world_editor_entity_catalog' in pg_get_functiondef('public.get_world_map()'::regprocedure)) > 0
     or position('world_editor_entity_catalog' in pg_get_functiondef('public.get_active_mining_fields()'::regprocedure)) > 0
     or position('world_editor_entity_catalog' in pg_get_functiondef('public.get_danger_zones()'::regprocedure)) > 0 then
    raise exception 'MARKERSTYLE PROOF FAIL: a gameplay reader body references the catalog — the readers must be untouched';
  end if;
  raise notice 'WE_MS_PASS_GAMEPLAY_READERS_BYTE_IDENTICAL';
end $$;

-- ══ PROOF 6 — a catalog call MUTATES NOTHING (coordinate/audit/world-content row counts stable) ══════
do $$
declare v_owner uuid;
  a1 int; a2 int; an1 int; an2 int; dz1 int; dz2 int; mf1 int; mf2 int; es1 int; es2 int; loc1 int; loc2 int;
begin
  select v into v_owner from msuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  select count(*) into a1  from public.world_editor_audit;
  select count(*) into an1 from public.space_anchors;
  select count(*) into dz1 from public.danger_zones;
  select count(*) into mf1 from public.mining_fields;
  select count(*) into es1 from public.exploration_sites;
  select count(*) into loc1 from public.locations;
  perform public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  perform public.world_editor_entity_catalog(jsonb_build_object('status','active'));
  perform public.world_editor_entity_catalog(jsonb_build_object('status','inactive'));
  select count(*) into a2  from public.world_editor_audit;
  select count(*) into an2 from public.space_anchors;
  select count(*) into dz2 from public.danger_zones;
  select count(*) into mf2 from public.mining_fields;
  select count(*) into es2 from public.exploration_sites;
  select count(*) into loc2 from public.locations;
  if a1<>a2 or an1<>an2 or dz1<>dz2 or mf1<>mf2 or es1<>es2 or loc1<>loc2 then
    raise exception 'MARKERSTYLE PROOF FAIL: a catalog call mutated a row count (audit %->%, anchors %->%, zones %->%, mining %->%, expl %->%, loc %->%)',
      a1,a2, an1,an2, dz1,dz2, mf1,mf2, es1,es2, loc1,loc2;
  end if;
  raise notice 'WE_MS_PASS_NO_ROWS_MUTATED';
end $$;

-- ══ PROOF 7b — the security contract on the catalog is intact (metadata) ═══════════════════════════
do $$
declare v_secdef boolean; v_sp boolean;
begin
  select prosecdef into v_secdef from pg_proc where oid = 'public.world_editor_entity_catalog(jsonb)'::regprocedure;
  if not v_secdef then raise exception 'MARKERSTYLE PROOF FAIL: catalog is not SECURITY DEFINER'; end if;
  select exists (select 1 from pg_proc p where p.oid = 'public.world_editor_entity_catalog(jsonb)'::regprocedure
                 and exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')) into v_sp;
  if not v_sp then raise exception 'MARKERSTYLE PROOF FAIL: catalog does not pin search_path'; end if;
  if not has_function_privilege('authenticated', 'public.world_editor_entity_catalog(jsonb)', 'execute') then
    raise exception 'MARKERSTYLE PROOF FAIL: authenticated cannot execute the catalog';
  end if;
  if has_function_privilege('anon', 'public.world_editor_entity_catalog(jsonb)', 'execute') then
    raise exception 'MARKERSTYLE PROOF FAIL: anon can execute the catalog — must be authenticated-only';
  end if;
  raise notice 'WE_MS_PASS_SECURITY_CONTRACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR CATALOG MARKER-STYLE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (the shadow function + all fixtures included).
