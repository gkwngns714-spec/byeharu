-- WORLD EDITOR ENTITY-DETAIL — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0270 (20260618000270_worldeditor_entity_detail.sql) after the FULL chain is applied by
-- `supabase start`: the owner-only INACTIVE-DETAIL / REACTIVATION reader world_editor_entity_detail(jsonb),
-- which given {domain in {zone,location}, entity_id} for an INACTIVE entity returns an OPAQUE
-- reactivation_expected snapshot matching that domain's reactivation command's `expected` EXACTLY — so an entity
-- SELECTED from the 0269 catalog can be reactivated WITHOUT fabricating fields or reading the audit ledger. It
-- drives the whole contract end to end:
--   (authz)  a non-owner, an anonymous caller, mining/exploration (unsupported_domain), an unknown domain
--            (invalid_domain), a missing/malformed id (invalid_entity_id), and a missing entity (not_found) are
--            each rejected with the correct typed code; anon holds NO execute grant;
--   (active) an ACTIVE zone and an ACTIVE location are rejected (validation_failed / already_active);
--   ZONE     detail(inactive) returns EXACTLY {name,source,location_id}; passed verbatim as `expected` to
--            zone_set_active it is ACCEPTED and flips the zone active;
--   LOCATION detail(inactive) returns EXACTLY the 11 location_update draft fields with x/y == locations.x/y;
--            passed verbatim as `expected` (and reused as `fields` with status='active') to location_update it
--            is ACCEPTED and flips the location active;
--   (catalog-sufficient) MINING + EXPLORATION reactivate from the CATALOG row WITHOUT this reader — their
--            set_active accepts {name, space_x, space_y, reward_bundle_json:null}; and the detail reader
--            REJECTS those domains as unsupported_domain;
--   (stale)  a STALE detail (fetch detail, then a concurrent mutation of a compared field, then reactivate with
--            the stale reactivation_expected) fails SAFELY with stale_revision and NO lifecycle change;
--   (fail-closed) a location with no active anchor makes detail RAISE (never a silent x/y fallback);
--   (read-only) the gameplay readers, the 0269 catalog payload, the audit rows, and every stored entity are
--            UNCHANGED across a battery of detail calls.
-- The migration's OWN in-migration self-assert ran during `supabase start` — any regression aborts the apply RED.
--
-- Self-rolling-back: everything runs inside one begin;…rollback; — ZERO persisted state. NEVER point at production.

\set ON_ERROR_STOP on

begin;

-- ══ FIXTURES ═══════════════════════════════════════════════════════════════════════════════════════
create temp table detuids(k text primary key, v uuid) on commit drop;
insert into detuids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'wedet.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from detuids;

insert into public.app_owners(user_id) select v from detuids where k = 'owner';

create temp table detfx(k text primary key, v uuid) on commit drop;
do $setup$
declare
  v_zone uuid; v_owner uuid; v_mi uuid; v_ei uuid; r jsonb;
begin
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'ENTITY-DETAIL PROOF SETUP FAIL: the seeded chain has no zones to host the location fixtures';
  end if;
  select v into v_owner from detuids where k = 'owner';

  -- ── MINING + EXPLORATION: one INACTIVE each (reward_bundle present in DB — must NEVER be exposed). Used for
  --    the "reactivate from the catalog WITHOUT the detail reader" proof. ──
  insert into public.mining_fields (name, space_x, space_y, reward_bundle_json, is_active)
    values ('DET-Mine-Inactive', -2000, -2000, '{"items":[{"item_id":"ore","quantity":1}]}'::jsonb, false)
    returning id into v_mi;
  insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json, is_active)
    values ('DET-Expl-Inactive', -3000, 3000, '{"metal":10,"items":[{"item_id":"scan_data","quantity":1}]}'::jsonb, false)
    returning id into v_ei;
  insert into detfx values ('mi', v_mi), ('ei', v_ei);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- ── ZONES via the real 0254 zone_create (authentic geometry/source). ──
  -- ZA: ACTIVE (active-reject representative).
  r := public.zone_create('det-za-req', jsonb_build_object('source_revision','det-za-rev',
         'fields', jsonb_build_object('name','DET-Zone-Active','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center',jsonb_build_object('x',1500,'y',-1500),'radius',120))));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZA create: %', r; end if;
  insert into detfx values ('za', (r->'result'->>'id')::uuid);

  -- ZR: create + unpublish → inactive (detail + reactivate round-trip).
  r := public.zone_create('det-zr-req', jsonb_build_object('source_revision','det-zr-rev',
         'fields', jsonb_build_object('name','DET-Zone-RoundTrip','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center',jsonb_build_object('x',2500,'y',2500),'radius',120))));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZR create: %', r; end if;
  insert into detfx values ('zr', (r->'result'->>'id')::uuid);
  r := public.zone_unpublish('det-zr-unpub', jsonb_build_object('target_id',(select v from detfx where k='zr')::text,
         'expected', jsonb_build_object('name','DET-Zone-RoundTrip','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZR unpublish: %', r; end if;

  -- ZS: create + unpublish → inactive (STALE test target).
  r := public.zone_create('det-zs-req', jsonb_build_object('source_revision','det-zs-rev',
         'fields', jsonb_build_object('name','DET-Zone-Stale','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center',jsonb_build_object('x',-2500,'y',-2500),'radius',120))));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZS create: %', r; end if;
  insert into detfx values ('zs', (r->'result'->>'id')::uuid);
  r := public.zone_unpublish('det-zs-unpub', jsonb_build_object('target_id',(select v from detfx where k='zs')::text,
         'expected', jsonb_build_object('name','DET-Zone-Stale','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: ZS unpublish: %', r; end if;

  -- ── LOCATIONS via the real 0264 location_create (writes the ACTIVE anchor atomically at the SAME (x,y) as
  --    locations.x/y — the invariant the reactivate + fail-closed guard rely on). ──
  -- LA: ACTIVE (active-reject representative).
  r := public.location_create('det-la-req', jsonb_build_object('source_revision','det-la-rev',
         'fields', jsonb_build_object('zone_id',v_zone::text,'name','DET-Loc-Active','location_type','safe_zone',
           'activity_type','none','x',100,'y',200,'reward_tier',1,'base_difficulty',1,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','active')));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: LA create: %', r; end if;
  insert into detfx values ('la', (r->'result'->>'id')::uuid);

  -- LRT: INACTIVE (locked) — detail + reactivate round-trip.
  r := public.location_create('det-lrt-req', jsonb_build_object('source_revision','det-lrt-rev',
         'fields', jsonb_build_object('zone_id',v_zone::text,'name','DET-Loc-RoundTrip','location_type','safe_zone',
           'activity_type','none','x',777,'y',-777,'reward_tier',3,'base_difficulty',1,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','locked')));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: LRT create: %', r; end if;
  insert into detfx values ('lrt', (r->'result'->>'id')::uuid);

  -- LS: INACTIVE (locked) — STALE test target.
  r := public.location_create('det-ls-req', jsonb_build_object('source_revision','det-ls-rev',
         'fields', jsonb_build_object('zone_id',v_zone::text,'name','DET-Loc-Stale','location_type','safe_zone',
           'activity_type','none','x',555,'y',-555,'reward_tier',4,'base_difficulty',1,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','locked')));
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: LS create: %', r; end if;
  insert into detfx values ('ls', (r->'result'->>'id')::uuid);

  raise notice 'DET_SETUP_OK';
end $setup$;

-- ══ AUTHZ ═══════════════════════════════════════════════════════════════════════════════════════════
do $$
declare v_no uuid; v_owner uuid; r jsonb;
begin
  select v into v_no from detuids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_detail(jsonb_build_object('domain','zone','entity_id',(select v from detfx where k='zr')::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'FAIL: non-owner not not_authorized: %', r; end if;

  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.world_editor_entity_detail(jsonb_build_object('domain','zone','entity_id',(select v from detfx where k='zr')::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'FAIL: anon not not_authenticated: %', r; end if;
  if has_function_privilege('anon', 'public.world_editor_entity_detail(jsonb)', 'execute') then
    raise exception 'FAIL: anon holds EXECUTE on world_editor_entity_detail'; end if;

  select v into v_owner from detuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- mining/exploration → unsupported_domain
  r := public.world_editor_entity_detail(jsonb_build_object('domain','mining','entity_id',(select v from detfx where k='mi')::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or (r->'details'->0->>'code') <> 'unsupported_domain' then
    raise exception 'FAIL: mining domain not unsupported_domain: %', r; end if;
  r := public.world_editor_entity_detail(jsonb_build_object('domain','exploration','entity_id',(select v from detfx where k='ei')::text));
  if (r->>'ok')::boolean is not false or (r->'details'->0->>'code') <> 'unsupported_domain' then
    raise exception 'FAIL: exploration domain not unsupported_domain: %', r; end if;
  -- unknown domain → invalid_domain
  r := public.world_editor_entity_detail(jsonb_build_object('domain','bogus','entity_id',(select v from detfx where k='zr')::text));
  if (r->>'ok')::boolean is not false or (r->'details'->0->>'code') <> 'invalid_domain' then
    raise exception 'FAIL: unknown domain not invalid_domain: %', r; end if;
  -- missing / malformed id → invalid_entity_id
  r := public.world_editor_entity_detail(jsonb_build_object('domain','zone'));
  if (r->>'ok')::boolean is not false or (r->'details'->0->>'code') <> 'invalid_entity_id' then
    raise exception 'FAIL: missing entity_id not invalid_entity_id: %', r; end if;
  r := public.world_editor_entity_detail(jsonb_build_object('domain','zone','entity_id','not-a-uuid'));
  if (r->>'ok')::boolean is not false or (r->'details'->0->>'code') <> 'invalid_entity_id' then
    raise exception 'FAIL: non-uuid entity_id not invalid_entity_id: %', r; end if;
  -- missing entity → not_found
  r := public.world_editor_entity_detail(jsonb_build_object('domain','location','entity_id', gen_random_uuid()::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_found'
     or (r->'details'->0->>'code') <> 'source_missing' then
    raise exception 'FAIL: missing entity not not_found/source_missing: %', r; end if;
  raise notice 'DET_PASS_AUTHZ';
end $$;

-- ══ ACTIVE REJECTED — an active zone and an active location are rejected (already_active) ════════════
do $$
declare v_owner uuid; r jsonb;
begin
  select v into v_owner from detuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_entity_detail(jsonb_build_object('domain','zone','entity_id',(select v from detfx where k='za')::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or (r->'details'->0->>'code') <> 'already_active' then
    raise exception 'FAIL: active zone not already_active: %', r; end if;
  r := public.world_editor_entity_detail(jsonb_build_object('domain','location','entity_id',(select v from detfx where k='la')::text));
  if (r->>'ok')::boolean is not false or (r->'details'->0->>'code') <> 'already_active' then
    raise exception 'FAIL: active location not already_active: %', r; end if;
  raise notice 'DET_PASS_ACTIVE_REJECTED';
end $$;

-- ══ ZONE DETAIL + REACTIVATE ════════════════════════════════════════════════════════════════════════
do $$
declare v_owner uuid; v_zr uuid; det jsonb; r jsonb; keys text[];
begin
  select v into v_owner from detuids where k = 'owner';
  select v into v_zr from detfx where k = 'zr';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  det := public.world_editor_entity_detail(jsonb_build_object('domain','zone','entity_id', v_zr::text));
  if (det->>'ok')::boolean is not true or (det->>'domain') <> 'zone'
     or (det->>'lifecycle_status') <> 'inactive' or (det->>'name') <> 'DET-Zone-RoundTrip' then
    raise exception 'FAIL: zone detail envelope: %', det; end if;
  keys := array(select jsonb_object_keys(det->'reactivation_expected') order by 1);
  if keys <> array['location_id','name','source'] then
    raise exception 'FAIL: zone reactivation_expected keys are % (want location_id,name,source)', keys; end if;
  if (det->'reactivation_expected'->>'source') <> 'drawn' then
    raise exception 'FAIL: zone reactivation_expected.source wrong: %', det->'reactivation_expected'; end if;

  -- reactivate with the OPAQUE reactivation_expected passed VERBATIM.
  r := public.zone_set_active('det-zone-react', jsonb_build_object(
         'target_id', v_zr::text, 'expected', det->'reactivation_expected'));
  if (r->>'ok')::boolean is not true then
    raise exception 'FAIL: zone reactivation_expected REJECTED by zone_set_active: %', r; end if;
  if (select status from public.danger_zones where id = v_zr) <> 'active' then
    raise exception 'FAIL: zone not active after detail→zone_set_active'; end if;
  raise notice 'DET_PASS_ZONE_DETAIL_AND_REACTIVATE';
end $$;

-- ══ LOCATION DETAIL + REACTIVATE ════════════════════════════════════════════════════════════════════
do $$
declare v_owner uuid; v_lrt uuid; det jsonb; r jsonb; keys text[]; lx float; ly float;
begin
  select v into v_owner from detuids where k = 'owner';
  select v into v_lrt from detfx where k = 'lrt';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  det := public.world_editor_entity_detail(jsonb_build_object('domain','location','entity_id', v_lrt::text));
  if (det->>'ok')::boolean is not true or (det->>'domain') <> 'location'
     or (det->>'lifecycle_status') <> 'inactive' or (det->>'name') <> 'DET-Loc-RoundTrip' then
    raise exception 'FAIL: location detail envelope: %', det; end if;
  keys := array(select jsonb_object_keys(det->'reactivation_expected') order by 1);
  if keys <> array['activity_type','base_difficulty','is_public','location_type','min_power_required',
                   'name','reward_tier','status','territory_radius','x','y'] then
    raise exception 'FAIL: location reactivation_expected keys are % (want the 11 draft fields)', keys; end if;
  -- x/y are locations.x/y (== the create coords 777,-777).
  select x, y into lx, ly from public.locations where id = v_lrt;
  if (det->'reactivation_expected'->>'x')::float <> lx or (det->'reactivation_expected'->>'y')::float <> ly then
    raise exception 'FAIL: location reactivation_expected x/y (%,%) != locations.x/y (%,%)',
      det->'reactivation_expected'->>'x', det->'reactivation_expected'->>'y', lx, ly; end if;
  if (det->'reactivation_expected'->>'status') <> 'locked' then
    raise exception 'FAIL: location reactivation_expected.status should be the CURRENT status (locked): %', det->'reactivation_expected'; end if;

  -- reactivate: reactivation_expected VERBATIM as `expected`, and reused as `fields` with status='active'.
  r := public.location_update('det-loc-react', jsonb_build_object(
         'target_id', v_lrt::text,
         'expected', det->'reactivation_expected',
         'fields', (det->'reactivation_expected') || jsonb_build_object('status','active')));
  if (r->>'ok')::boolean is not true then
    raise exception 'FAIL: location reactivation_expected REJECTED by location_update: %', r; end if;
  if (select status from public.locations where id = v_lrt) <> 'active' then
    raise exception 'FAIL: location not active after detail→location_update'; end if;
  raise notice 'DET_PASS_LOCATION_DETAIL_AND_REACTIVATE';
end $$;

-- ══ MINING + EXPLORATION reactivate FROM THE CATALOG (no detail reader needed) ══════════════════════
do $$
declare v_owner uuid; cat jsonb; e jsonb; exp jsonb; r jsonb;
begin
  select v into v_owner from detuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- MINING: build set_active.expected from the CATALOG row (name + point) + reward_bundle_json:null.
  cat := public.world_editor_entity_catalog(jsonb_build_object('status','inactive'));
  select el into e from jsonb_array_elements(cat->'rows') el where (el->>'entity_id')=(select v from detfx where k='mi')::text;
  if e is null then raise exception 'FAIL: inactive mining not in catalog'; end if;
  exp := jsonb_build_object('name', e->>'name', 'space_x', e->'point'->'x', 'space_y', e->'point'->'y',
                            'reward_bundle_json', null);
  r := public.mining_field_set_active('det-mine-cat-react', jsonb_build_object(
         'target_id', e->>'name', 'expected', exp, 'is_active', true));
  if (r->>'ok')::boolean is not true then
    raise exception 'FAIL: mining catalog {name,space_x,space_y,reward_bundle_json:null} REJECTED: %', r; end if;

  -- EXPLORATION: same.
  select el into e from jsonb_array_elements(cat->'rows') el where (el->>'entity_id')=(select v from detfx where k='ei')::text;
  if e is null then raise exception 'FAIL: inactive exploration not in catalog'; end if;
  exp := jsonb_build_object('name', e->>'name', 'space_x', e->'point'->'x', 'space_y', e->'point'->'y',
                            'reward_bundle_json', null);
  r := public.exploration_site_set_active('det-expl-cat-react', jsonb_build_object(
         'target_id', e->>'name', 'expected', exp, 'is_active', true));
  if (r->>'ok')::boolean is not true then
    raise exception 'FAIL: exploration catalog {name,space_x,space_y,reward_bundle_json:null} REJECTED: %', r; end if;
  raise notice 'DET_PASS_MINING_EXPLORATION_FROM_CATALOG';
end $$;

-- ══ STALE-SAFE — fetch detail, mutate a compared field concurrently, reactivate with the STALE snapshot ══
do $$
declare v_owner uuid; v_zs uuid; v_ls uuid; det_z jsonb; det_l jsonb; r jsonb;
begin
  select v into v_owner from detuids where k = 'owner';
  select v into v_zs from detfx where k = 'zs';
  select v into v_ls from detfx where k = 'ls';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- ZONE: fetch detail, then a concurrent rename (a compared field), then reactivate with the stale expected.
  det_z := public.world_editor_entity_detail(jsonb_build_object('domain','zone','entity_id', v_zs::text));
  update public.danger_zones set name = 'DET-Zone-Stale-RENAMED' where id = v_zs;
  r := public.zone_set_active('det-zone-stale-react', jsonb_build_object(
         'target_id', v_zs::text, 'expected', det_z->'reactivation_expected'));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision' then
    raise exception 'FAIL: stale zone reactivate was not stale_revision: %', r; end if;
  if (select status from public.danger_zones where id = v_zs) <> 'inactive' then
    raise exception 'FAIL: stale zone lifecycle changed despite stale_revision'; end if;

  -- LOCATION: fetch detail, then a concurrent reward_tier bump (a compared field), then reactivate stale.
  det_l := public.world_editor_entity_detail(jsonb_build_object('domain','location','entity_id', v_ls::text));
  update public.locations set reward_tier = reward_tier + 5 where id = v_ls;
  r := public.location_update('det-loc-stale-react', jsonb_build_object(
         'target_id', v_ls::text,
         'expected', det_l->'reactivation_expected',
         'fields', (det_l->'reactivation_expected') || jsonb_build_object('status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision' then
    raise exception 'FAIL: stale location reactivate was not stale_revision: %', r; end if;
  if (select status from public.locations where id = v_ls) <> 'locked' then
    raise exception 'FAIL: stale location lifecycle changed despite stale_revision'; end if;
  raise notice 'DET_PASS_STALE_SAFE';
end $$;

-- ══ FAIL-CLOSED — a location with NO active anchor makes detail RAISE (never an x/y fallback) ═══════
do $$
declare v_owner uuid; v_zone uuid; v_bad uuid; r jsonb; v_raised boolean := false;
begin
  select v into v_owner from detuids where k = 'owner';
  select id into v_zone from public.zones order by name limit 1;
  -- inserted DIRECTLY (bypassing location_create) so it has NO anchor; locked so it never enters get_world_map.
  insert into public.locations (zone_id, name, location_type, activity_type, x, y, reward_tier,
                                base_difficulty, min_power_required, is_public, territory_radius, status)
    values (v_zone, 'DET-Loc-NoAnchor', 'safe_zone', 'none', 900, 900, 1, 1, 0, true, null, 'locked')
    returning id into v_bad;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  begin
    r := public.world_editor_entity_detail(jsonb_build_object('domain','location','entity_id', v_bad::text));
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'FAIL: detail did NOT fail closed on a location with no active anchor (got %)', r; end if;
  delete from public.locations where id = v_bad;   -- restore the global anchor invariant for the catalog below.
  raise notice 'DET_PASS_FAILCLOSED_MISSING_ANCHOR';
end $$;

-- ══ READ-ONLY — gameplay readers + 0269 catalog payload + audit rows + stored entities UNCHANGED ════
do $$
declare v_owner uuid;
  wm1 jsonb; wm2 jsonb; mf1 jsonb; mf2 jsonb; dz1 jsonb; dz2 jsonb; c1 jsonb; c2 jsonb;
  a1 int; a2 int; an1 int; an2 int; dzc1 int; dzc2 int; lc1 int; lc2 int; mfc1 int; mfc2 int; esc1 int; esc2 int;
begin
  select v into v_owner from detuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  wm1 := public.get_world_map(); mf1 := public.get_active_mining_fields(); dz1 := public.get_danger_zones();
  c1  := public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  select count(*) into a1  from public.world_editor_audit;
  select count(*) into an1 from public.space_anchors;
  select count(*) into dzc1 from public.danger_zones;
  select count(*) into lc1 from public.locations;
  select count(*) into mfc1 from public.mining_fields;
  select count(*) into esc1 from public.exploration_sites;

  -- a battery of detail calls (all read-only).
  perform public.world_editor_entity_detail(jsonb_build_object('domain','zone','entity_id',(select v from detfx where k='zs')::text));
  perform public.world_editor_entity_detail(jsonb_build_object('domain','location','entity_id',(select v from detfx where k='ls')::text));
  perform public.world_editor_entity_detail(jsonb_build_object('domain','zone','entity_id',(select v from detfx where k='za')::text));   -- active → typed reject, still a read
  perform public.world_editor_entity_detail(jsonb_build_object('domain','location','entity_id',(select v from detfx where k='la')::text));

  wm2 := public.get_world_map(); mf2 := public.get_active_mining_fields(); dz2 := public.get_danger_zones();
  c2  := public.world_editor_entity_catalog(jsonb_build_object('status','all'));
  select count(*) into a2  from public.world_editor_audit;
  select count(*) into an2 from public.space_anchors;
  select count(*) into dzc2 from public.danger_zones;
  select count(*) into lc2 from public.locations;
  select count(*) into mfc2 from public.mining_fields;
  select count(*) into esc2 from public.exploration_sites;

  if wm1 is distinct from wm2 then raise exception 'FAIL: get_world_map changed across a detail call'; end if;
  if mf1 is distinct from mf2 then raise exception 'FAIL: get_active_mining_fields changed across a detail call'; end if;
  if dz1 is distinct from dz2 then raise exception 'FAIL: get_danger_zones changed across a detail call'; end if;
  if c1  is distinct from c2  then raise exception 'FAIL: world_editor_entity_catalog payload changed across a detail call'; end if;
  if a1<>a2 or an1<>an2 or dzc1<>dzc2 or lc1<>lc2 or mfc1<>mfc2 or esc1<>esc2 then
    raise exception 'FAIL: a detail call mutated a row count (audit %->%, anchors %->%, zones %->%, loc %->%, mining %->%, expl %->%)',
      a1,a2, an1,an2, dzc1,dzc2, lc1,lc2, mfc1,mfc2, esc1,esc2; end if;
  -- the detail reader does not redefine any gameplay reader or the catalog.
  if position('world_editor_entity_detail' in pg_get_functiondef('public.get_world_map()'::regprocedure)) > 0
     or position('world_editor_entity_detail' in pg_get_functiondef('public.get_danger_zones()'::regprocedure)) > 0
     or position('world_editor_entity_detail' in pg_get_functiondef('public.world_editor_entity_catalog(jsonb)'::regprocedure)) > 0 then
    raise exception 'FAIL: a gameplay reader / the catalog references the detail reader — they must be untouched'; end if;
  raise notice 'DET_PASS_READONLY_UNCHANGED';
end $$;

do $$ begin raise notice 'WORLD-EDITOR ENTITY-DETAIL PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
