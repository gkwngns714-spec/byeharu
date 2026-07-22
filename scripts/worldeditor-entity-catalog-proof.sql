-- WORLD EDITOR ENTITY-CATALOG — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0269 (20260618000269_worldeditor_entity_catalog.sql) after the FULL chain is applied by
-- `supabase start`: the owner-only normalized lifecycle catalog world_editor_entity_catalog(jsonb), which
-- returns BOTH active and inactive entities across all 4 world-content domains (location/mining/exploration/
-- zone) for the editor — WITHOUT touching any gameplay reader. It drives the whole contract end to end:
--   (1)  status='active' returns ACTIVE rows from all 4 domains;
--   (2)  status='inactive' returns INACTIVE rows from all 4 domains;
--   (3)  status='all' returns the exact union with NO duplicate entity_id;
--   (4)  unpublish moves a zone from the active → inactive results;
--   (5)  reactivate moves it back with the SAME entity_id;
--   (6)  location coords come from the ACTIVE space_anchor (relocate the anchor → catalog point follows), NEVER locations.x/y;
--   (7)  mining/exploration coords are their native space_x/space_y, unchanged;
--   (8)  zone geometry round-trips in the client union shape (byte-identical to get_danger_zones' ring);
--   (9)  a MISSING location anchor fails CLOSED (raise), never a silent drop or an x/y fallback;
--   (10) an unauthorized (non-owner) user AND an anonymous caller are rejected (not_authorized / not_authenticated);
--   (11) the gameplay reader payloads (get_world_map / get_active_mining_fields / get_danger_zones) stay BYTE-IDENTICAL across a catalog call;
--   (12) no coordinate / audit / world-content rows are mutated by a catalog call (it is read-only).
-- The migration's OWN in-migration self-assert (SECURITY DEFINER, search_path pinned, authenticated-only,
-- anon revoked, read-only, anchor-not-x/y, all 4 gameplay readers intact, no source-table write grant) ran
-- during `supabase start` — any regression there aborts the apply RED before this proof even runs.
--
-- Self-rolling-back: everything runs inside one begin;…rollback; — ZERO persisted state, no flag kept
-- flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE (the real
-- byeharu owner does not exist in a disposable DB). NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ══ FIXTURES ═══════════════════════════════════════════════════════════════════════════════════════
-- synthetic OWNER + NON-OWNER; one active + one inactive fixture in EACH of the 4 domains, plus a
-- round-trip zone for the unpublish→reactivate lifecycle checks. Location anchors are seeded at coords
-- DELIBERATELY DIFFERENT from locations.x/y so proof (6) can prove the anchor is the sole authority.
create temp table catuids(k text primary key, v uuid) on commit drop;
insert into catuids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'wecat.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from catuids;

insert into public.app_owners(user_id) select v from catuids where k = 'owner';

create temp table catfx(k text primary key, v uuid) on commit drop;
do $setup$
declare
  v_zone uuid; v_owner uuid;
  v_la uuid; v_li uuid; v_ma uuid; v_mi uuid; v_ea uuid; v_ei uuid;
  r jsonb;
begin
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'ENTITY-CATALOG PROOF SETUP FAIL: the seeded chain has no zones to host the location fixtures';
  end if;

  -- ── LOCATIONS: active + inactive; each with its own ACTIVE location anchor at coords ≠ locations.x/y ──
  insert into public.locations (zone_id, name, location_type, activity_type, x, y, is_public, status)
    values (v_zone, 'CAT-Loc-Active', 'safe_zone', 'none', 111, 222, true, 'active')
    returning id into v_la;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_la, 1234, -1234, 'active');

  insert into public.locations (zone_id, name, location_type, activity_type, x, y, is_public, status)
    values (v_zone, 'CAT-Loc-Inactive', 'safe_zone', 'none', 333, 444, true, 'locked')
    returning id into v_li;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_li, 4321, -4321, 'active');

  -- ── MINING: active + inactive (native space_x/space_y) ──
  insert into public.mining_fields (name, space_x, space_y, reward_bundle_json, is_active)
    values ('CAT-Mine-Active', 2000, 2000, '{"items":[{"item_id":"ore","quantity":1}]}'::jsonb, true)
    returning id into v_ma;
  insert into public.mining_fields (name, space_x, space_y, reward_bundle_json, is_active)
    values ('CAT-Mine-Inactive', -2000, -2000, '{"items":[{"item_id":"ore","quantity":1}]}'::jsonb, false)
    returning id into v_mi;

  -- ── EXPLORATION: active + inactive (native space_x/space_y) ──
  insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json, is_active)
    values ('CAT-Expl-Active', 3000, -3000, '{"metal":10,"items":[{"item_id":"scan_data","quantity":1}]}'::jsonb, true)
    returning id into v_ea;
  insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json, is_active)
    values ('CAT-Expl-Inactive', -3000, 3000, '{"metal":10,"items":[{"item_id":"scan_data","quantity":1}]}'::jsonb, false)
    returning id into v_ei;

  insert into catfx values
    ('la', v_la), ('li', v_li), ('ma', v_ma), ('mi', v_mi), ('ea', v_ea), ('ei', v_ei);

  -- ── ZONES: created through the real 0254 zone_create (owner JWT) so geometry is authentic. ──
  select v into v_owner from catuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- ZA: an ACTIVE drawn zone (the active-zone representative + geometry round-trip target).
  r := public.zone_create('cat-zone-active-req', jsonb_build_object(
         'source_revision','cat-za-rev',
         'fields', jsonb_build_object('name','CAT-Zone-Active','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center',jsonb_build_object('x',1500,'y',-1500),'radius',120))));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZA create not ok: %', r; end if;
  insert into catfx values ('za', (r->'result'->>'id')::uuid);

  -- ZI: created then UNPUBLISHED → the inactive-zone representative.
  r := public.zone_create('cat-zone-inactive-req', jsonb_build_object(
         'source_revision','cat-zi-rev',
         'fields', jsonb_build_object('name','CAT-Zone-Inactive','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center',jsonb_build_object('x',-1500,'y',1500),'radius',120))));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZI create not ok: %', r; end if;
  insert into catfx values ('zi', (r->'result'->>'id')::uuid);
  r := public.zone_unpublish('cat-zone-inactive-unpub-req', jsonb_build_object(
         'target_id', (select v from catfx where k='zi')::text,
         'expected', jsonb_build_object('name','CAT-Zone-Inactive','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZI unpublish not ok: %', r; end if;

  -- ZR: an ACTIVE drawn zone reserved for the unpublish→reactivate round-trip (proofs 4 & 5).
  r := public.zone_create('cat-zone-rt-req', jsonb_build_object(
         'source_revision','cat-zr-rev',
         'fields', jsonb_build_object('name','CAT-Zone-RoundTrip','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center',jsonb_build_object('x',2500,'y',2500),'radius',120))));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZR create not ok: %', r; end if;
  insert into catfx values ('zr', (r->'result'->>'id')::uuid);

  raise notice 'WE_CATALOG_SETUP_OK';
end $setup$;

-- ══ PROOF 10 (run first, before any flag flip) — UNAUTHORIZED + ANON are rejected ══════════════════
do $$
declare v_no uuid; r jsonb;
begin
  -- non-owner authenticated → not_authorized
  select v into v_no from catuids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog('{}'::jsonb);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'ENTITY-CATALOG PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  -- anonymous → not_authenticated, and anon holds NO execute grant.
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.world_editor_entity_catalog('{}'::jsonb);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'ENTITY-CATALOG PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  if has_function_privilege('anon', 'public.world_editor_entity_catalog(jsonb)', 'execute') then
    raise exception 'ENTITY-CATALOG PROOF FAIL: anon holds EXECUTE on world_editor_entity_catalog — must be authenticated-only';
  end if;
  -- also confirm an invalid status is validation_failed (owner JWT).
  perform set_config('request.jwt.claims', json_build_object('sub', (select v from catuids where k='owner')::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','bogus'));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or (r->'details'->0->>'code') <> 'invalid_status' then
    raise exception 'ENTITY-CATALOG PROOF FAIL: an unknown status was not validation_failed/invalid_status: %', r;
  end if;
  raise notice 'WE_CATALOG_PASS_UNAUTHORIZED_AND_ANON_REJECTED';
end $$;

-- ══ PROOF 1 — status='active' returns ACTIVE rows from ALL 4 domains (and excludes the inactives) ══
do $$
declare v_owner uuid; r jsonb; rows jsonb;
begin
  select v into v_owner from catuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','active'));
  if (r->>'ok')::boolean is not true or (r->>'status') <> 'active' then
    raise exception 'ENTITY-CATALOG PROOF FAIL: active call not ok: %', r;
  end if;
  rows := r->'rows';
  -- each active fixture present with lifecycle_status='active' and correct domain.
  if not exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id')=(select v from catfx where k='la')::text and e->>'domain'='location'    and e->>'lifecycle_status'='active') then raise exception 'FAIL: active location missing from status=active'; end if;
  if not exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id')=(select v from catfx where k='ma')::text and e->>'domain'='mining'      and e->>'lifecycle_status'='active') then raise exception 'FAIL: active mining missing from status=active'; end if;
  if not exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id')=(select v from catfx where k='ea')::text and e->>'domain'='exploration' and e->>'lifecycle_status'='active') then raise exception 'FAIL: active exploration missing from status=active'; end if;
  if not exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id')=(select v from catfx where k='za')::text and e->>'domain'='zone'        and e->>'lifecycle_status'='active') then raise exception 'FAIL: active zone missing from status=active'; end if;
  -- and NONE of the inactive fixtures leaked in.
  if exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id') in (
        (select v from catfx where k='li')::text,(select v from catfx where k='mi')::text,
        (select v from catfx where k='ei')::text,(select v from catfx where k='zi')::text)) then
    raise exception 'FAIL: an INACTIVE fixture leaked into status=active';
  end if;
  -- every returned row is active (the filter is exact).
  if exists (select 1 from jsonb_array_elements(rows) e where e->>'lifecycle_status' <> 'active') then
    raise exception 'FAIL: status=active returned a non-active row';
  end if;
  raise notice 'WE_CATALOG_PASS_ACTIVE_ALL_DOMAINS';
end $$;

-- ══ PROOF 2 — status='inactive' returns INACTIVE rows from ALL 4 domains (and excludes the actives) ══
do $$
declare v_owner uuid; r jsonb; rows jsonb;
begin
  select v into v_owner from catuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','inactive'));
  if (r->>'ok')::boolean is not true or (r->>'status') <> 'inactive' then
    raise exception 'ENTITY-CATALOG PROOF FAIL: inactive call not ok: %', r;
  end if;
  rows := r->'rows';
  if not exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id')=(select v from catfx where k='li')::text and e->>'domain'='location'    and e->>'lifecycle_status'='inactive') then raise exception 'FAIL: inactive location missing from status=inactive'; end if;
  if not exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id')=(select v from catfx where k='mi')::text and e->>'domain'='mining'      and e->>'lifecycle_status'='inactive') then raise exception 'FAIL: inactive mining missing from status=inactive'; end if;
  if not exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id')=(select v from catfx where k='ei')::text and e->>'domain'='exploration' and e->>'lifecycle_status'='inactive') then raise exception 'FAIL: inactive exploration missing from status=inactive'; end if;
  if not exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id')=(select v from catfx where k='zi')::text and e->>'domain'='zone'        and e->>'lifecycle_status'='inactive') then raise exception 'FAIL: inactive zone missing from status=inactive'; end if;
  if exists (select 1 from jsonb_array_elements(rows) e where (e->>'entity_id') in (
        (select v from catfx where k='la')::text,(select v from catfx where k='ma')::text,
        (select v from catfx where k='ea')::text,(select v from catfx where k='za')::text)) then
    raise exception 'FAIL: an ACTIVE fixture leaked into status=inactive';
  end if;
  if exists (select 1 from jsonb_array_elements(rows) e where e->>'lifecycle_status' <> 'inactive') then
    raise exception 'FAIL: status=inactive returned a non-inactive row';
  end if;
  raise notice 'WE_CATALOG_PASS_INACTIVE_ALL_DOMAINS';
end $$;

-- ══ PROOF 3 — status='all' (default) is the EXACT union with NO duplicate entity_id, deterministic order ══
do $$
declare v_owner uuid; r jsonb; r_def jsonb; rows jsonb; n_all int; n_dup int; n_act int; n_ina int;
begin
  select v into v_owner from catuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r     := public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  r_def := public.world_editor_entity_catalog('{}'::jsonb);        -- default is 'all'
  if r->'rows' is distinct from r_def->'rows' then
    raise exception 'ENTITY-CATALOG PROOF FAIL: default status differs from explicit all';
  end if;
  rows := r->'rows';
  -- all 8 named fixtures present exactly once.
  select count(*) into n_all from jsonb_array_elements(rows) e where (e->>'entity_id') in (
    (select v from catfx where k='la')::text,(select v from catfx where k='li')::text,
    (select v from catfx where k='ma')::text,(select v from catfx where k='mi')::text,
    (select v from catfx where k='ea')::text,(select v from catfx where k='ei')::text,
    (select v from catfx where k='za')::text,(select v from catfx where k='zi')::text);
  if n_all <> 8 then raise exception 'FAIL: status=all did not contain all 8 fixtures exactly once (got %)', n_all; end if;
  -- NO duplicate entity_id anywhere in the union.
  select count(*) into n_dup from (
    select e->>'entity_id' eid from jsonb_array_elements(rows) e group by 1 having count(*) > 1) d;
  if n_dup <> 0 then raise exception 'FAIL: status=all contained % duplicated entity_id(s)', n_dup; end if;
  -- all = active ∪ inactive, exactly (over our fixtures).
  select count(*) into n_act from jsonb_array_elements(rows) e where e->>'lifecycle_status'='active';
  select count(*) into n_ina from jsonb_array_elements(rows) e where e->>'lifecycle_status'='inactive';
  if n_act + n_ina <> jsonb_array_length(rows) then
    raise exception 'FAIL: status=all has rows that are neither active nor inactive';
  end if;
  -- deterministic ordering: domain asc, then lower(trim(name)), then entity_id — the array is already sorted.
  if exists (
    select 1
    from jsonb_array_elements(rows) with ordinality as a(e, ord)
    join jsonb_array_elements(rows) with ordinality as b(e, ord) on b.ord = a.ord + 1
    where (a.e->>'domain', lower(btrim(a.e->>'name')), a.e->>'entity_id')
        > (b.e->>'domain', lower(btrim(b.e->>'name')), b.e->>'entity_id')) then
    raise exception 'FAIL: status=all rows are not in the deterministic (domain, lower(name), entity_id) order';
  end if;
  raise notice 'WE_CATALOG_PASS_ALL_UNION_NO_DUP';
end $$;

-- ══ PROOF 6 — a location's point is the ACTIVE ANCHOR coord (not locations.x/y); relocate → point follows ══
do $$
declare v_owner uuid; v_la uuid; r jsonb; e jsonb; px float; py float;
begin
  select v into v_owner from catuids where k = 'owner';
  select v into v_la from catfx where k = 'la';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','active'));
  select el into e from jsonb_array_elements(r->'rows') el where (el->>'entity_id') =v_la::text;
  px := (e->'point'->>'x')::float; py := (e->'point'->>'y')::float;
  -- the anchor coord (1234,-1234), NOT locations.x/y (111,222).
  if px <> 1234 or py <> -1234 then
    raise exception 'ENTITY-CATALOG PROOF FAIL: location point is % , % — expected the anchor coord (1234,-1234), not locations.x/y', px, py;
  end if;
  -- RELOCATE the anchor the lawful way (retire the active anchor + insert a new active one at new coords).
  update public.space_anchors set status = 'retired'
    where location_id = v_la and kind = 'location' and status = 'active';
  insert into public.space_anchors (kind, location_id, space_x, space_y, status)
    values ('location', v_la, 5678, -5678, 'active');
  -- the catalog point now FOLLOWS the new active anchor.
  r := public.world_editor_entity_catalog(jsonb_build_object('status','active'));
  select el into e from jsonb_array_elements(r->'rows') el where (el->>'entity_id') =v_la::text;
  if (e->'point'->>'x')::float <> 5678 or (e->'point'->>'y')::float <> -5678 then
    raise exception 'ENTITY-CATALOG PROOF FAIL: after relocating the anchor the catalog point did not follow (got %,%)', (e->'point'->>'x'), (e->'point'->>'y');
  end if;
  raise notice 'WE_CATALOG_PASS_LOCATION_POINT_FROM_ANCHOR';
end $$;

-- ══ PROOF 7 — mining & exploration points are their NATIVE space_x/space_y, unchanged ══════════════
do $$
declare v_owner uuid; r jsonb; e jsonb;
begin
  select v into v_owner from catuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  -- mining active (2000,2000)
  select el into e from jsonb_array_elements(r->'rows') el where (el->>'entity_id') =(select v from catfx where k='ma')::text;
  if (e->'point'->>'x')::float <> 2000 or (e->'point'->>'y')::float <> 2000 or e->'geometry' <> 'null'::jsonb then
    raise exception 'ENTITY-CATALOG PROOF FAIL: mining active point/geometry wrong: %', e;
  end if;
  -- exploration active (3000,-3000)
  select el into e from jsonb_array_elements(r->'rows') el where (el->>'entity_id') =(select v from catfx where k='ea')::text;
  if (e->'point'->>'x')::float <> 3000 or (e->'point'->>'y')::float <> -3000 or e->'geometry' <> 'null'::jsonb then
    raise exception 'ENTITY-CATALOG PROOF FAIL: exploration active point/geometry wrong: %', e;
  end if;
  -- reward_bundle_json is NEVER exposed (no key anywhere in the catalog output).
  if position('reward_bundle' in r::text) > 0 or position('pending_bundle' in r::text) > 0 then
    raise exception 'ENTITY-CATALOG PROOF FAIL: a reward/pending bundle leaked into the catalog output';
  end if;
  raise notice 'WE_CATALOG_PASS_MINING_EXPLORATION_NATIVE_COORDS';
end $$;

-- ══ PROOF 8 — zone geometry round-trips: the catalog union ring == get_danger_zones' ring (byte-identical) ══
do $$
declare v_owner uuid; v_za uuid; r jsonb; e jsonb; ring_cat jsonb; ring_dz jsonb; dz jsonb;
begin
  select v into v_owner from catuids where k = 'owner';
  select v into v_za from catfx where k = 'za';
  -- light the intercept flag so get_danger_zones serves the active zone (rolled back at the end).
  insert into public.game_config(key, value, description)
    values ('pirate_intercept_enabled', 'true'::jsonb, 'proof-txn-local')
    on conflict (key) do update set value = 'true'::jsonb;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_catalog(jsonb_build_object('status','active'));
  select el into e from jsonb_array_elements(r->'rows') el where (el->>'entity_id') =v_za::text;
  if e->'geometry'->>'kind' <> 'ring' then
    raise exception 'ENTITY-CATALOG PROOF FAIL: zone geometry union is not a {kind:ring,...}: %', e->'geometry';
  end if;
  ring_cat := e->'geometry'->'ring';
  if e->'point' = 'null'::jsonb then
    raise exception 'ENTITY-CATALOG PROOF FAIL: zone point (centroid) is null';
  end if;
  -- get_danger_zones' ring for the SAME zone.
  dz := public.get_danger_zones();
  select el->'ring' into ring_dz from jsonb_array_elements(dz) el where (el->>'id') = v_za::text;
  if ring_dz is null then
    raise exception 'ENTITY-CATALOG PROOF FAIL: the active zone is not present in get_danger_zones (cannot round-trip)';
  end if;
  if ring_cat is distinct from ring_dz then
    raise exception 'ENTITY-CATALOG PROOF FAIL: the catalog zone ring is NOT byte-identical to get_danger_zones'' ring';
  end if;
  raise notice 'WE_CATALOG_PASS_ZONE_GEOMETRY_ROUNDTRIP';
end $$;

-- ══ PROOF 4 — UNPUBLISH moves the round-trip zone from active → inactive results ═══════════════════
do $$
declare v_owner uuid; v_zr uuid; r jsonb; cat jsonb;
begin
  select v into v_owner from catuids where k = 'owner';
  select v into v_zr from catfx where k = 'zr';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- before: ZR is in the ACTIVE results.
  cat := public.world_editor_entity_catalog(jsonb_build_object('status','active'));
  if not exists (select 1 from jsonb_array_elements(cat->'rows') e where (e->>'entity_id')=v_zr::text) then
    raise exception 'ENTITY-CATALOG PROOF FAIL: ZR not in active results before unpublish';
  end if;
  -- unpublish (0255) → inactive.
  r := public.zone_unpublish('cat-zr-unpub-req', jsonb_build_object(
         'target_id', v_zr::text,
         'expected', jsonb_build_object('name','CAT-Zone-RoundTrip','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true then raise exception 'FAIL: ZR unpublish not ok: %', r; end if;
  -- after: gone from ACTIVE, present in INACTIVE.
  cat := public.world_editor_entity_catalog(jsonb_build_object('status','active'));
  if exists (select 1 from jsonb_array_elements(cat->'rows') e where (e->>'entity_id')=v_zr::text) then
    raise exception 'ENTITY-CATALOG PROOF FAIL: ZR still in active results after unpublish';
  end if;
  cat := public.world_editor_entity_catalog(jsonb_build_object('status','inactive'));
  if not exists (select 1 from jsonb_array_elements(cat->'rows') e where (e->>'entity_id')=v_zr::text and e->>'lifecycle_status'='inactive') then
    raise exception 'ENTITY-CATALOG PROOF FAIL: ZR not in inactive results after unpublish';
  end if;
  raise notice 'WE_CATALOG_PASS_UNPUBLISH_MOVES_ACTIVE_TO_INACTIVE';
end $$;

-- ══ PROOF 5 — REACTIVATE moves it back to active results with the SAME entity_id ═══════════════════
do $$
declare v_owner uuid; v_zr uuid; r jsonb; cat jsonb; e jsonb; ring_before jsonb; ring_after jsonb;
begin
  select v into v_owner from catuids where k = 'owner';
  select v into v_zr from catfx where k = 'zr';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- capture the inactive catalog geometry before reactivate.
  cat := public.world_editor_entity_catalog(jsonb_build_object('status','inactive'));
  select el into e from jsonb_array_elements(cat->'rows') el where (el->>'entity_id')=v_zr::text;
  ring_before := e->'geometry'->'ring';
  -- reactivate (0268) → active.
  r := public.zone_set_active('cat-zr-react-req', jsonb_build_object(
         'target_id', v_zr::text,
         'expected', jsonb_build_object('name','CAT-Zone-RoundTrip','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true then raise exception 'FAIL: ZR reactivate not ok: %', r; end if;
  -- back in ACTIVE with the SAME id and byte-identical geometry; gone from INACTIVE.
  cat := public.world_editor_entity_catalog(jsonb_build_object('status','active'));
  select el into e from jsonb_array_elements(cat->'rows') el where (el->>'entity_id')=v_zr::text;
  if e is null then raise exception 'ENTITY-CATALOG PROOF FAIL: ZR not back in active results after reactivate (same entity_id expected)'; end if;
  ring_after := e->'geometry'->'ring';
  if ring_after is distinct from ring_before then
    raise exception 'ENTITY-CATALOG PROOF FAIL: ZR geometry changed across the unpublish/reactivate cycle';
  end if;
  cat := public.world_editor_entity_catalog(jsonb_build_object('status','inactive'));
  if exists (select 1 from jsonb_array_elements(cat->'rows') e2 where (e2->>'entity_id')=v_zr::text) then
    raise exception 'ENTITY-CATALOG PROOF FAIL: ZR still in inactive results after reactivate';
  end if;
  raise notice 'WE_CATALOG_PASS_REACTIVATE_MOVES_BACK_SAME_ID';
end $$;

-- ══ PROOF 9 — a MISSING location anchor FAILS CLOSED (raise), never a silent drop or an x/y fallback ══
do $$
declare v_owner uuid; v_zone uuid; v_bad uuid; r jsonb; v_raised boolean := false;
begin
  select v into v_owner from catuids where k = 'owner';
  select id into v_zone from public.zones order by name limit 1;
  -- a location with NO active anchor (the reachable fail-closed case; a DUPLICATE active anchor is structurally
  -- impossible thanks to the partial unique index space_anchors_one_active_per_location).
  insert into public.locations (zone_id, name, location_type, activity_type, x, y, is_public, status)
    values (v_zone, 'CAT-Loc-NoAnchor', 'safe_zone', 'none', 900, 900, true, 'active')
    returning id into v_bad;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  begin
    r := public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'ENTITY-CATALOG PROOF FAIL: the catalog did NOT fail closed on a location with no active anchor';
  end if;
  -- clean up so the remaining proofs run against a healthy world.
  delete from public.locations where id = v_bad;
  -- and confirm the catalog is healthy again after the offending row is gone.
  r := public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  if (r->>'ok')::boolean is not true then
    raise exception 'ENTITY-CATALOG PROOF FAIL: the catalog did not recover after the bad location was removed: %', r;
  end if;
  raise notice 'WE_CATALOG_PASS_FAILCLOSED_MISSING_ANCHOR';
end $$;

-- ══ PROOF 11 — the gameplay readers are BYTE-IDENTICAL across a catalog call (this slice does not touch them) ══
do $$
declare v_owner uuid; wm1 jsonb; wm2 jsonb; mf1 jsonb; mf2 jsonb; dz1 jsonb; dz2 jsonb;
begin
  select v into v_owner from catuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  wm1 := public.get_world_map(); mf1 := public.get_active_mining_fields(); dz1 := public.get_danger_zones();
  perform public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  wm2 := public.get_world_map(); mf2 := public.get_active_mining_fields(); dz2 := public.get_danger_zones();
  if wm1 is distinct from wm2 then raise exception 'ENTITY-CATALOG PROOF FAIL: get_world_map changed across a catalog call'; end if;
  if mf1 is distinct from mf2 then raise exception 'ENTITY-CATALOG PROOF FAIL: get_active_mining_fields changed across a catalog call'; end if;
  if dz1 is distinct from dz2 then raise exception 'ENTITY-CATALOG PROOF FAIL: get_danger_zones changed across a catalog call'; end if;
  -- and the catalog does NOT redefine any reader: none of the 4 reader bodies mention world_editor_entity_catalog.
  if position('world_editor_entity_catalog' in pg_get_functiondef('public.get_world_map()'::regprocedure)) > 0
     or position('world_editor_entity_catalog' in pg_get_functiondef('public.get_active_mining_fields()'::regprocedure)) > 0
     or position('world_editor_entity_catalog' in pg_get_functiondef('public.get_danger_zones()'::regprocedure)) > 0 then
    raise exception 'ENTITY-CATALOG PROOF FAIL: a gameplay reader body references the catalog — the readers must be untouched';
  end if;
  raise notice 'WE_CATALOG_PASS_GAMEPLAY_READERS_BYTE_IDENTICAL';
end $$;

-- ══ PROOF 12 — a catalog call MUTATES NOTHING: coordinate / audit / world-content row counts are stable ══
do $$
declare v_owner uuid;
  a1 int; a2 int; an1 int; an2 int; dz1 int; dz2 int; mf1 int; mf2 int; es1 int; es2 int; loc1 int; loc2 int;
begin
  select v into v_owner from catuids where k = 'owner';
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
    raise exception 'ENTITY-CATALOG PROOF FAIL: a catalog call mutated a row count (audit % ->%, anchors %->%, zones %->%, mining %->%, expl %->%, loc %->%)',
      a1,a2, an1,an2, dz1,dz2, mf1,mf2, es1,es2, loc1,loc2;
  end if;
  -- the catalog writes NO audit row of its own (it is a read, not a command).
  if a2 <> a1 then raise exception 'ENTITY-CATALOG PROOF FAIL: the catalog wrote a world_editor_audit row'; end if;
  raise notice 'WE_CATALOG_PASS_NO_ROWS_MUTATED';
end $$;

do $$ begin raise notice 'WORLD-EDITOR ENTITY-CATALOG PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (the pirate_intercept_enabled flip included).
