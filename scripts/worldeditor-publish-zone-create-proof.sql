-- WORLD EDITOR PUBLISH-ZONE-CREATE — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0254 (20260618000254_worldeditor_publish_zone_create.sql) after the FULL chain is
-- applied by `supabase start`: the 4th/final publish domain zone_create ACCEPTS the owner for BOTH
-- geometry kinds (circle → ST_Buffer materialization attached to a live hostile site; polygon →
-- closed-ring ST_MakePolygon materialization, standalone; both rows source='drawn', status='active',
-- ST_IsValid with positive area, visible through get_danger_zones once pirate_intercept_enabled is
-- lit), REJECTS the non-owner and the anonymous caller with zero side effects, is idempotent on
-- request_id (exactly one insert, one audit row, identical replayed result), re-validates the payload
-- server-side (validation_failed + the zoneValidation detail vocabulary), rejects a self-intersecting
-- ring at the AUTHORITATIVE ST_IsValid gate (typed {invalid_geometry} — the client scan is advisory),
-- rejects a bad attach target as a TYPED {invalid_attach} (never a raw FK violation), writes the
-- audit row with after_snapshot only, and leaves the 0239 pirate-zone lockdown intact (this command
-- is a NEW owner-gated surface — the locked pirate_zone_create/delete are untouched).
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- kept flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE
-- (the real byeharu owner does not exist in a disposable DB). The pirate_intercept_enabled flip for
-- the read check is INSIDE the transaction and rolled back with everything else. NEVER point this at
-- production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER, a synthetic NON-OWNER, one HOSTILE attach target, one NON-hostile ──
create temp table pubids(k text primary key, v uuid) on commit drop;
insert into pubids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'pubzonecre.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from pubids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from pubids where k = 'owner';

-- attach fixtures: ONE active hostile site (the legal attach target — seeded ourselves so the proof
-- never depends on which chain rows survive) and ONE active NON-hostile site (the illegal target).
create temp table publoc(k text primary key, v uuid) on commit drop;
do $$
declare v_zone uuid; v_hostile uuid; v_benign uuid;
begin
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'ZONE CREATE PROOF SETUP FAIL: the seeded chain has no zones to host the attach fixtures';
  end if;
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values
      (v_zone, 'Zone Create Proof Den', 'pirate_den', 'hunt_pirates', 800, -800, 1, 1, 0, true, null, 'active')
    returning id into v_hostile;
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values
      (v_zone, 'Zone Create Proof Outpost', 'trade_outpost', 'trade_visit', -800, 800, 1, 0, 0, true, null, 'active')
    returning id into v_benign;
  insert into publoc values ('hostile', v_hostile), ('benign', v_benign);
end $$;

-- ── PROOF 1 — OWNER CIRCLE create is APPLIED: ST_Buffer materialization, attached, drawn+active ─────
do $$
declare v_owner uuid; v_hostile uuid; r jsonb; v_row record; v_id uuid;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_hostile from publoc where k = 'hostile';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_create('zonecre-owner-circle-req-1', jsonb_build_object(
         'source_revision', 'zonecre-proof-rev-1',
         'fields', jsonb_build_object(
           'name','Zone Create Proof Circle','zone_kind','pirate',
           'attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle',
             'center', jsonb_build_object('x', 800, 'y', -800), 'radius', 120))));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE CREATE PROOF FAIL: owner circle create not ok: %', r;
  end if;
  if (r->'result'->>'created') <> 'true' or (r->'result'->>'name') <> 'Zone Create Proof Circle' then
    raise exception 'ZONE CREATE PROOF FAIL: owner circle result malformed: %', r;
  end if;
  v_id := (r->'result'->>'id')::uuid;
  select * into v_row from public.danger_zones where id = v_id;
  if not found then
    raise exception 'ZONE CREATE PROOF FAIL: the circle zone row does not exist';
  end if;
  if v_row.name <> 'Zone Create Proof Circle' or v_row.zone_kind <> 'pirate'
     or v_row.source <> 'drawn' or v_row.location_id is distinct from v_hostile
     or v_row.status <> 'active' or v_row.created_by is distinct from v_owner then
    raise exception 'ZONE CREATE PROOF FAIL: a circle field did not apply (%, %, %, %, %, %)',
      v_row.name, v_row.zone_kind, v_row.source, v_row.location_id, v_row.status, v_row.created_by;
  end if;
  if not ST_IsValid(v_row.boundary) or ST_Area(v_row.boundary) <= 0 then
    raise exception 'ZONE CREATE PROOF FAIL: the circle boundary is not a valid positive-area polygon';
  end if;
  -- the materialized disc must actually be the buffered circle: it contains the center and its area
  -- approximates pi*r^2 (32-segment buffer — within a few percent).
  if not ST_Contains(v_row.boundary, ST_MakePoint(800, -800)) then
    raise exception 'ZONE CREATE PROOF FAIL: the circle boundary does not contain its own center';
  end if;
  if abs(ST_Area(v_row.boundary) - pi() * 120 * 120) > 0.05 * pi() * 120 * 120 then
    raise exception 'ZONE CREATE PROOF FAIL: circle area % is not ~pi*r^2', ST_Area(v_row.boundary);
  end if;
  raise notice 'PUBLISH_ZONE_PASS_OWNER_CREATES_CIRCLE';
end $$;

-- ── PROOF 2 — OWNER POLYGON create is APPLIED: closed-ring materialization, STANDALONE, and the
--    zone READ sees it once pirate_intercept_enabled is lit (txn-local flip, rolled back) ───────────
do $$
declare v_owner uuid; r jsonb; v_row record; v_id uuid; v_read jsonb;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_create('zonecre-owner-poly-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name','Zone Create Proof Blob','zone_kind','pirate',
           'attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 0,   'y', 0),
             jsonb_build_object('x', 200, 'y', 40),
             jsonb_build_object('x', 260, 'y', 220),
             jsonb_build_object('x', 80,  'y', 300),
             jsonb_build_object('x', -60, 'y', 160))))));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE CREATE PROOF FAIL: owner polygon create not ok: %', r;
  end if;
  v_id := (r->'result'->>'id')::uuid;
  select * into v_row from public.danger_zones where id = v_id;
  if not found then
    raise exception 'ZONE CREATE PROOF FAIL: the polygon zone row does not exist';
  end if;
  if v_row.source <> 'drawn' or v_row.location_id is not null or v_row.status <> 'active' then
    raise exception 'ZONE CREATE PROOF FAIL: standalone polygon shape wrong (%, %, %)',
      v_row.source, v_row.location_id, v_row.status;
  end if;
  if not ST_IsValid(v_row.boundary) or ST_Area(v_row.boundary) <= 0 then
    raise exception 'ZONE CREATE PROOF FAIL: the polygon boundary is not a valid positive-area polygon';
  end if;
  -- 5 open vertices → a closed 6-point exterior ring (the server appended vertex 1).
  if ST_NPoints(ST_ExteriorRing(v_row.boundary)) <> 6 then
    raise exception 'ZONE CREATE PROOF FAIL: expected a closed 6-point ring, got % points',
      ST_NPoints(ST_ExteriorRing(v_row.boundary));
  end if;
  -- READ-side dark coupling (documented env dependency): dark → invisible; lit → visible. The flip
  -- is txn-local and rolled back with everything else.
  if exists (select 1 from jsonb_array_elements(public.get_danger_zones()) z where (z->>'id')::uuid = v_id)
     and (select public.cfg_bool('pirate_intercept_enabled')) is not true then
    raise exception 'ZONE CREATE PROOF FAIL: a dark zone leaked through get_danger_zones';
  end if;
  insert into public.game_config(key, value, description)
    values ('pirate_intercept_enabled', 'true'::jsonb, 'proof-txn-local')
    on conflict (key) do update set value = 'true'::jsonb;
  v_read := public.get_danger_zones();
  if not exists (select 1 from jsonb_array_elements(v_read) z where (z->>'id')::uuid = v_id) then
    raise exception 'ZONE CREATE PROOF FAIL: the published polygon zone is missing from get_danger_zones while lit: %', v_read;
  end if;
  raise notice 'PUBLISH_ZONE_PASS_OWNER_CREATES_POLYGON';
end $$;

-- ── PROOF 3 — NON-OWNER authenticated user is REJECTED (not_authorized), zero side effects ─────────
do $$
declare v_no uuid; r jsonb; n int;
begin
  select v into v_no from pubids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.zone_create('zonecre-nonowner-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name','Hijacked Zone','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle',
             'center', jsonb_build_object('x', 0, 'y', 0), 'radius', 50))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'ZONE CREATE PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  select count(*) into n from public.danger_zones where name = 'Hijacked Zone';
  if n <> 0 then
    raise exception 'ZONE CREATE PROOF FAIL: a rejected non-owner create inserted % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zonecre-nonowner-req-1';
  if n <> 0 then
    raise exception 'ZONE CREATE PROOF FAIL: a rejected non-owner create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 4 — ANONYMOUS caller is REJECTED (not_authenticated) + anon holds NO execute grant ───────
do $$
declare r jsonb; n int;
begin
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.zone_create('zonecre-anon-req-1', jsonb_build_object(
         'fields', jsonb_build_object('name','Anon Zone')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'ZONE CREATE PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  select count(*) into n from public.danger_zones where name = 'Anon Zone';
  if n <> 0 then
    raise exception 'ZONE CREATE PROOF FAIL: an anonymous create inserted % row(s)', n;
  end if;
  if has_function_privilege('anon', 'public.zone_create(text,jsonb)', 'execute') then
    raise exception 'ZONE CREATE PROOF FAIL: anon holds EXECUTE on zone_create — must be authenticated-only';
  end if;
  raise notice 'PUBLISH_ZONE_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 5 — repeated request_id is IDEMPOTENT (one insert; one audit row; identical replay) ──────
do $$
declare v_owner uuid; r1 jsonb; r2 jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r1 := public.zone_create('zonecre-idem-req-1', jsonb_build_object(
          'fields', jsonb_build_object(
            'name','Zone Create Proof Idem','zone_kind','pirate','attach_location_id', null,
            'geometry', jsonb_build_object('kind','circle',
              'center', jsonb_build_object('x', 500, 'y', 500), 'radius', 60))));
  -- same request_id, DIFFERENT name — must NOT re-apply, must return the prior result.
  r2 := public.zone_create('zonecre-idem-req-1', jsonb_build_object(
          'fields', jsonb_build_object(
            'name','Zone Create Proof Idem SECOND','zone_kind','pirate','attach_location_id', null,
            'geometry', jsonb_build_object('kind','circle',
              'center', jsonb_build_object('x', 501, 'y', 501), 'radius', 61))));
  if (r1->>'ok')::boolean is not true then
    raise exception 'ZONE CREATE PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'ZONE CREATE PROOF FAIL: second call was not an idempotent replay: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'ZONE CREATE PROOF FAIL: replay result differs from the original (% vs %)', r2->'result', r1->'result';
  end if;
  select count(*) into n from public.danger_zones where name like 'Zone Create Proof Idem%';
  if n <> 1 then
    raise exception 'ZONE CREATE PROOF FAIL: idempotent request inserted % row(s) (expected exactly 1)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zonecre-idem-req-1';
  if n <> 1 then
    raise exception 'ZONE CREATE PROOF FAIL: idempotent request produced % audit rows (expected exactly 1)', n;
  end if;
  raise notice 'PUBLISH_ZONE_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 6 — BAD fields are REJECTED server-side (validation_failed + collected details) ──────────
do $$
declare v_owner uuid; r jsonb; n int; v_codes text[];
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- blank name + bad zone_kind + a circle whose radius is negative AND whose center is far outside
  -- the world — ALL collected into one report.
  r := public.zone_create('zonecre-badpayload-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name','   ','zone_kind','ninja','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle',
             'center', jsonb_build_object('x', 99999, 'y', 0), 'radius', -5))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'ZONE CREATE PROOF FAIL: bad fields were not rejected as validation_failed: %', r;
  end if;
  if jsonb_typeof(r->'details') <> 'array' or jsonb_array_length(r->'details') < 4 then
    raise exception 'ZONE CREATE PROOF FAIL: validation_failed details incomplete (expected >=4 issues): %', r->'details';
  end if;
  select array_agg(d->>'code') into v_codes from jsonb_array_elements(r->'details') d;
  if not (v_codes @> array['name_required','invalid_zone_kind','radius_not_positive','coord_out_of_bounds']) then
    raise exception 'ZONE CREATE PROOF FAIL: validation detail codes incomplete (codes %): %', v_codes, r->'details';
  end if;
  -- a too-few-vertices polygon is its own typed detail.
  r := public.zone_create('zonecre-fewverts-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name','Zone Create Proof TwoVerts','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 0, 'y', 0), jsonb_build_object('x', 10, 'y', 10))))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'polygon_too_few_vertices') then
    raise exception 'ZONE CREATE PROOF FAIL: a 2-vertex polygon was not a typed polygon_too_few_vertices: %', r;
  end if;
  select count(*) into n from public.danger_zones where name in ('Zone Create Proof TwoVerts') or zone_kind = 'ninja';
  if n <> 0 then
    raise exception 'ZONE CREATE PROOF FAIL: a validation-rejected create reached the table (% row(s))', n;
  end if;
  select count(*) into n from public.world_editor_audit
   where request_id in ('zonecre-badpayload-req-1','zonecre-fewverts-req-1');
  if n <> 0 then
    raise exception 'ZONE CREATE PROOF FAIL: a validation-rejected create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_PASS_VALIDATION_REJECTED';
end $$;

-- ── PROOF 7 — a SELF-INTERSECTING ring fails the AUTHORITATIVE ST_IsValid gate (invalid_geometry) ──
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- the bowtie: per-vertex checks all pass (finite, in-bounds, 4 vertices) — only the MATERIALIZED
  -- polygon is invalid. This is exactly the case the client scan is advisory for.
  r := public.zone_create('zonecre-bowtie-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name','Zone Create Proof Bowtie','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 0,   'y', 0),
             jsonb_build_object('x', 100, 'y', 100),
             jsonb_build_object('x', 100, 'y', 0),
             jsonb_build_object('x', 0,   'y', 100))))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or (r->'details'->0->>'code') <> 'invalid_geometry' then
    raise exception 'ZONE CREATE PROOF FAIL: the bowtie ring was not a typed invalid_geometry: %', r;
  end if;
  select count(*) into n from public.danger_zones where name = 'Zone Create Proof Bowtie';
  if n <> 0 then
    raise exception 'ZONE CREATE PROOF FAIL: an invalid-geometry create inserted % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zonecre-bowtie-req-1';
  if n <> 0 then
    raise exception 'ZONE CREATE PROOF FAIL: an invalid-geometry create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_PASS_INVALID_GEOMETRY_REJECTED';
end $$;

-- ── PROOF 8 — a BAD attach target is a TYPED validation_failed {invalid_attach} (never a raw FK) ───
do $$
declare v_owner uuid; v_benign uuid; r jsonb; n int; v_geom jsonb;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_benign from publoc where k = 'benign';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  v_geom := jsonb_build_object('kind','circle',
              'center', jsonb_build_object('x', 0, 'y', 0), 'radius', 40);

  -- (a) a well-formed uuid naming NO location at all.
  r := public.zone_create('zonecre-ghostattach-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name','Zone Create Proof AttachCase','zone_kind','pirate',
           'attach_location_id', gen_random_uuid()::text, 'geometry', v_geom)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'invalid_attach' and d->>'field' = 'attach_location_id') then
    raise exception 'ZONE CREATE PROOF FAIL: a ghost attach was not a typed invalid_attach: %', r;
  end if;

  -- (b) not a uuid.
  r := public.zone_create('zonecre-baduuidattach-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name','Zone Create Proof AttachCase','zone_kind','pirate',
           'attach_location_id', 'not-a-uuid', 'geometry', v_geom)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'invalid_attach') then
    raise exception 'ZONE CREATE PROOF FAIL: a non-uuid attach was not a typed invalid_attach: %', r;
  end if;

  -- (c) an EXISTING ACTIVE location of the WRONG TYPE (trade_outpost — the 0233 rule allows only
  -- active pirate_hunt/pirate_den).
  r := public.zone_create('zonecre-benignattach-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name','Zone Create Proof AttachCase','zone_kind','pirate',
           'attach_location_id', v_benign::text, 'geometry', v_geom)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'invalid_attach') then
    raise exception 'ZONE CREATE PROOF FAIL: a non-hostile attach was not a typed invalid_attach: %', r;
  end if;

  select count(*) into n from public.danger_zones where name = 'Zone Create Proof AttachCase';
  if n <> 0 then
    raise exception 'ZONE CREATE PROOF FAIL: an invalid-attach create inserted % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit
   where request_id in ('zonecre-ghostattach-req-1','zonecre-baduuidattach-req-1','zonecre-benignattach-req-1');
  if n <> 0 then
    raise exception 'ZONE CREATE PROOF FAIL: an invalid-attach create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_PASS_INVALID_ATTACH_REJECTED';
end $$;

-- ── PROOF 9 — the audit row: after_snapshot mirrors the created zone; before_snapshot is NULL ──────
do $$
declare v_before jsonb; v_after jsonb; v_rev text; v_type text; v_ttype text; v_tid text; v_hostile uuid;
begin
  select v into v_hostile from publoc where k = 'hostile';
  select before_snapshot, after_snapshot, source_revision, command_type, target_type, target_id
    into v_before, v_after, v_rev, v_type, v_ttype, v_tid
    from public.world_editor_audit where request_id = 'zonecre-owner-circle-req-1';
  if v_type is distinct from 'zone_create' or v_ttype is distinct from 'zone' then
    raise exception 'ZONE CREATE PROOF FAIL: audit command/target type wrong (got %, %)', v_type, v_ttype;
  end if;
  if v_before is not null then
    raise exception 'ZONE CREATE PROOF FAIL: before_snapshot must be NULL on a create: %', v_before;
  end if;
  if v_after is null or jsonb_typeof(v_after) <> 'object' then
    raise exception 'ZONE CREATE PROOF FAIL: after_snapshot is not a jsonb object: %', v_after;
  end if;
  if (v_after->>'name') <> 'Zone Create Proof Circle' or (v_after->>'source') <> 'drawn'
     or (v_after->>'zone_kind') <> 'pirate' or (v_after->>'status') <> 'active'
     or (v_after->>'location_id') <> v_hostile::text
     or (v_after->>'boundary_wkt') is null or (v_after->>'boundary_wkt') not like 'POLYGON%' then
    raise exception 'ZONE CREATE PROOF FAIL: after_snapshot does not mirror the created zone: %', v_after;
  end if;
  if v_tid is distinct from (v_after->>'id') then
    raise exception 'ZONE CREATE PROOF FAIL: audit target_id (%) disagrees with the created id (%)', v_tid, v_after->>'id';
  end if;
  if v_rev is distinct from 'zonecre-proof-rev-1' then
    raise exception 'ZONE CREATE PROOF FAIL: audit source_revision not recorded (got %)', v_rev;
  end if;
  raise notice 'PUBLISH_ZONE_PASS_AUDIT_SNAPSHOT';
end $$;

-- ── PROOF 10 — the 0239 pirate-zone lockdown is INTACT (zone_create is a NEW surface; the locked
--    RPCs are untouched: no client execute, service_role keeps its owner-tooling grant) ─────────────
do $$
begin
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE CREATE PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE CREATE PROOF FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path regressed';
  end if;
  -- and no client role gained a danger_zones table write (the definer body is the only write path).
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'INSERT')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'DELETE') then
    raise exception 'ZONE CREATE PROOF FAIL: a client role holds a danger_zones WRITE grant — the narrowing did not hold';
  end if;
  raise notice 'PUBLISH_ZONE_PASS_PIRATE_ZONE_LOCKDOWN_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-ZONE-CREATE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (the pirate_intercept_enabled flip included).
