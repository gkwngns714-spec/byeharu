-- WORLD EDITOR PUBLISH-ZONE-UPDATE — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0266 (20260618000266_worldeditor_publish_zone_update.sql) after the FULL chain is
-- applied by `supabase start`: the zone EDIT command zone_update re-materializes an edit draft's new
-- geometry onto the SAME danger_zones.id (source/zone_kind/created_by preserved), writes ONE audit row
-- with BOTH before_snapshot AND after_snapshot, returns ok:true; REJECTS the non-owner and the anonymous
-- caller with zero side effects; is idempotent on request_id (exactly one apply, one audit row, identical
-- replay); REJECTS a stale `expected` via OPTIMISTIC CONCURRENCY (stale_revision + source_changed for
-- BOTH a name drift AND a geometry drift — the geometry compared spatially via ST_Equals, nothing
-- written); REJECTS a self-intersecting polygon at the AUTHORITATIVE ST_IsValid gate (typed
-- validation_failed {invalid_geometry}); PROTECTS seeded source='circle' zones from edit (typed
-- validation_failed {protected_zone}); returns a typed not_found/source_missing for a vanished target and
-- invalid_request for a non-uuid target; touches ONLY danger_zones and leaves the 0239 pirate-zone
-- lockdown intact.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag kept
-- flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE (the real
-- byeharu owner does not exist in a disposable DB). The pirate_intercept_enabled flip for the read check
-- is INSIDE the transaction and rolled back with everything else. NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER, a synthetic NON-OWNER, one active HOSTILE attach target ────────────
create temp table pubids(k text primary key, v uuid) on commit drop;
insert into pubids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'pubzoneupd.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from pubids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from pubids where k = 'owner';

-- one active HOSTILE site (the legal attach target for the edit's location_id change — seeded ourselves
-- so the proof never depends on which chain rows survive).
create temp table publoc(k text primary key, v uuid) on commit drop;
do $$
declare v_zone uuid; v_hostile uuid;
begin
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'ZONE UPDATE PROOF SETUP FAIL: the seeded chain has no zones to host the attach fixture';
  end if;
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values
      (v_zone, 'Zone Update Proof Den', 'pirate_den', 'hunt_pirates', 1000, 1000, 1, 1, 0, true, null, 'active')
    returning id into v_hostile;
  insert into publoc values ('hostile', v_hostile);
end $$;

-- ── PROOF 1 — OWNER EDIT is APPLIED onto the SAME id: geometry re-materialized, name + attach written ─
-- Create a standalone DRAWN zone (a square), fork it, then edit to a NEW circle geometry + rename +
-- attach to the hostile site. The circle boundary must land on the SAME danger_zones.id; source stays
-- 'drawn'; the edited zone reads back through get_danger_zones once lit.
do $$
declare v_owner uuid; v_hostile uuid; r jsonb; v_id uuid; v_row record; v_read jsonb;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_hostile from publoc where k = 'hostile';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- create the DRAWN square to edit (open ring [(0,0),(300,0),(300,300),(0,300)]).
  r := public.zone_create('zoneupd-seed-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name','ZUpd Origin','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 0,   'y', 0),
             jsonb_build_object('x', 300, 'y', 0),
             jsonb_build_object('x', 300, 'y', 300),
             jsonb_build_object('x', 0,   'y', 300))))));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE UPDATE PROOF FAIL: seed zone_create not ok: %', r;
  end if;
  v_id := (r->'result'->>'id')::uuid;

  -- EDIT: expected mirrors the fork-time projection ({name, zone_kind, attach null, polygon open ring});
  -- fields carry a NEW circle geometry + a rename + an attach to the hostile site.
  r := public.zone_update('zoneupd-owner-1', jsonb_build_object(
         'target_id', v_id::text,
         'source_revision', 'zoneupd-proof-rev-1',
         'expected', jsonb_build_object(
           'name','ZUpd Origin','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 0,   'y', 0),
             jsonb_build_object('x', 300, 'y', 0),
             jsonb_build_object('x', 300, 'y', 300),
             jsonb_build_object('x', 0,   'y', 300)))),
         'fields', jsonb_build_object(
           'name','ZUpd Renamed','attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle',
             'center', jsonb_build_object('x', 1000, 'y', 1000), 'radius', 200))));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE UPDATE PROOF FAIL: owner update not ok: %', r;
  end if;
  if (r->'result'->>'updated') <> 'true' or (r->'result'->>'name') <> 'ZUpd Renamed'
     or (r->'result'->>'id') <> v_id::text then
    raise exception 'ZONE UPDATE PROOF FAIL: owner update result malformed: %', r;
  end if;

  select * into v_row from public.danger_zones where id = v_id;
  if v_row.name <> 'ZUpd Renamed' or v_row.source <> 'drawn' or v_row.zone_kind <> 'pirate'
     or v_row.location_id is distinct from v_hostile or v_row.status <> 'active' then
    raise exception 'ZONE UPDATE PROOF FAIL: an edited field did not apply (%, %, %, %, %)',
      v_row.name, v_row.source, v_row.zone_kind, v_row.location_id, v_row.status;
  end if;
  -- the NEW boundary is the re-materialized circle: it contains its center and has ~pi*r^2 area.
  if not ST_IsValid(v_row.boundary) or ST_Area(v_row.boundary) <= 0 then
    raise exception 'ZONE UPDATE PROOF FAIL: the edited boundary is not a valid positive-area polygon';
  end if;
  if not ST_Contains(v_row.boundary, ST_MakePoint(1000, 1000)) then
    raise exception 'ZONE UPDATE PROOF FAIL: the edited circle boundary does not contain its own center';
  end if;
  if abs(ST_Area(v_row.boundary) - pi() * 200 * 200) > 0.05 * pi() * 200 * 200 then
    raise exception 'ZONE UPDATE PROOF FAIL: edited circle area % is not ~pi*r^2', ST_Area(v_row.boundary);
  end if;
  -- exactly ONE audit row for this apply.
  if (select count(*) from public.world_editor_audit where request_id = 'zoneupd-owner-1') <> 1 then
    raise exception 'ZONE UPDATE PROOF FAIL: owner update did not write exactly one audit row';
  end if;

  -- READ-side dark coupling: lit → the edited zone is visible through get_danger_zones (txn-local flip).
  insert into public.game_config(key, value, description)
    values ('pirate_intercept_enabled', 'true'::jsonb, 'proof-txn-local')
    on conflict (key) do update set value = 'true'::jsonb;
  v_read := public.get_danger_zones();
  if not exists (select 1 from jsonb_array_elements(v_read) z where (z->>'id')::uuid = v_id) then
    raise exception 'ZONE UPDATE PROOF FAIL: the edited zone is missing from get_danger_zones while lit: %', v_read;
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_OWNER_UPDATES';
end $$;

-- ── PROOF 2 — NON-OWNER authenticated user is REJECTED (not_authorized), zero side effects ──────────
do $$
declare v_no uuid; v_id uuid; r jsonb; n int;
begin
  select v into v_no from pubids where k = 'nonowner';
  select id into v_id from public.danger_zones where name = 'ZUpd Renamed';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.zone_update('zoneupd-nonowner-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','ZUpd Renamed','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',200)),
         'fields', jsonb_build_object('name','Hijacked Zone','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',0,'y',0),'radius',50))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'ZONE UPDATE PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  select count(*) into n from public.danger_zones where name = 'Hijacked Zone';
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL: a rejected non-owner update changed % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneupd-nonowner-1';
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL: a rejected non-owner update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 3 — ANONYMOUS caller is REJECTED (not_authenticated) + anon holds NO execute grant ────────
do $$
declare v_id uuid; r jsonb; n int;
begin
  select id into v_id from public.danger_zones where name = 'ZUpd Renamed';
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.zone_update('zoneupd-anon-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','ZUpd Renamed'),
         'fields', jsonb_build_object('name','Anon Zone','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',0,'y',0),'radius',50))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'ZONE UPDATE PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  select count(*) into n from public.danger_zones where name = 'Anon Zone';
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL: an anonymous update changed % row(s)', n;
  end if;
  if has_function_privilege('anon', 'public.zone_update(text,jsonb)', 'execute') then
    raise exception 'ZONE UPDATE PROOF FAIL: anon holds EXECUTE on zone_update — must be authenticated-only';
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 4 — repeated request_id is IDEMPOTENT (one apply; one audit row; identical replay) ────────
do $$
declare v_owner uuid; v_id uuid; r1 jsonb; r2 jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- a fresh DRAWN zone to edit idempotently.
  r1 := public.zone_create('zoneupd-idem-seed-1', jsonb_build_object(
          'fields', jsonb_build_object('name','ZUpd Idem Origin','zone_kind','pirate','attach_location_id', null,
            'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
              jsonb_build_object('x', -100, 'y', -100),
              jsonb_build_object('x',  100, 'y', -100),
              jsonb_build_object('x',  100, 'y',  100),
              jsonb_build_object('x', -100, 'y',  100))))));
  v_id := (r1->'result'->>'id')::uuid;

  r1 := public.zone_update('zoneupd-idem-1', jsonb_build_object(
          'target_id', v_id::text,
          'expected', jsonb_build_object('name','ZUpd Idem Origin','zone_kind','pirate','attach_location_id', null,
            'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
              jsonb_build_object('x', -100, 'y', -100),
              jsonb_build_object('x',  100, 'y', -100),
              jsonb_build_object('x',  100, 'y',  100),
              jsonb_build_object('x', -100, 'y',  100)))),
          'fields', jsonb_build_object('name','ZUpd Idem First','attach_location_id', null,
            'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',500,'y',500),'radius',80))));
  -- same request_id, DIFFERENT fields — must NOT re-apply, must return the prior result.
  r2 := public.zone_update('zoneupd-idem-1', jsonb_build_object(
          'target_id', v_id::text,
          'expected', jsonb_build_object('name','ZUpd Idem First','zone_kind','pirate','attach_location_id', null,
            'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',500,'y',500),'radius',80)),
          'fields', jsonb_build_object('name','ZUpd Idem SECOND','attach_location_id', null,
            'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',600,'y',600),'radius',90))));
  if (r1->>'ok')::boolean is not true then
    raise exception 'ZONE UPDATE PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'ZONE UPDATE PROOF FAIL: second call was not an idempotent replay: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'ZONE UPDATE PROOF FAIL: replay result differs from the original (% vs %)', r2->'result', r1->'result';
  end if;
  select * into v_row from public.danger_zones where id = v_id;
  if v_row.name <> 'ZUpd Idem First' then
    raise exception 'ZONE UPDATE PROOF FAIL: replay re-applied (name = %, expected the FIRST apply''s value)', v_row.name;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneupd-idem-1';
  if n <> 1 then
    raise exception 'ZONE UPDATE PROOF FAIL: idempotent request produced % audit rows (expected exactly 1)', n;
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 5 — OPTIMISTIC CONCURRENCY: a stale `expected` is REJECTED (stale_revision), no write ─────
-- Both a NAME drift and a GEOMETRY drift (the ST_Equals compare) are proven. The drift is simulated by
-- a direct superuser UPDATE (a concurrent editor); the caller still holds the OLD `expected`.
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int; v_row record; v_expected jsonb; v_fields jsonb;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- a fresh DRAWN square Z_stale.
  r := public.zone_create('zoneupd-stale-seed-1', jsonb_build_object(
         'fields', jsonb_build_object('name','ZUpd Stale Origin','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 0,   'y', 0),
             jsonb_build_object('x', 400, 'y', 0),
             jsonb_build_object('x', 400, 'y', 400),
             jsonb_build_object('x', 0,   'y', 400))))));
  v_id := (r->'result'->>'id')::uuid;

  v_expected := jsonb_build_object('name','ZUpd Stale Origin','zone_kind','pirate','attach_location_id', null,
                  'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
                    jsonb_build_object('x', 0,   'y', 0),
                    jsonb_build_object('x', 400, 'y', 0),
                    jsonb_build_object('x', 400, 'y', 400),
                    jsonb_build_object('x', 0,   'y', 400))));
  v_fields := jsonb_build_object('name','ZUpd Stale Attempt','attach_location_id', null,
                'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',0,'y',0),'radius',120));

  -- (a) NAME drift: a concurrent editor renamed the zone; the boundary is untouched.
  update public.danger_zones set name = 'Concurrently Renamed' where id = v_id;
  r := public.zone_update('zoneupd-stale-name-1', jsonb_build_object(
         'target_id', v_id::text, 'expected', v_expected, 'fields', v_fields));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision' then
    raise exception 'ZONE UPDATE PROOF FAIL: a name drift was not rejected as stale_revision: %', r;
  end if;
  if not exists (select 1 from jsonb_array_elements(r->'details') d
                 where d->>'code' = 'source_changed' and d->>'field' = 'name') then
    raise exception 'ZONE UPDATE PROOF FAIL: name-drift stale_revision did not name the field: %', r->'details';
  end if;

  -- (b) GEOMETRY drift: restore the name, then reshape the boundary to a DIFFERENT triangle. The
  -- expected still carries the ORIGINAL square ring → ST_Equals is false → geometry drift.
  update public.danger_zones set name = 'ZUpd Stale Origin' where id = v_id;
  update public.danger_zones
     set boundary = ST_MakePolygon(ST_MakeLine(ARRAY[
       ST_MakePoint(-500,-500), ST_MakePoint(-300,-500), ST_MakePoint(-400,-300), ST_MakePoint(-500,-500)]))
   where id = v_id;
  r := public.zone_update('zoneupd-stale-geom-1', jsonb_build_object(
         'target_id', v_id::text, 'expected', v_expected, 'fields', v_fields));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision' then
    raise exception 'ZONE UPDATE PROOF FAIL: a geometry drift was not rejected as stale_revision: %', r;
  end if;
  if not exists (select 1 from jsonb_array_elements(r->'details') d
                 where d->>'code' = 'source_changed' and d->>'field' = 'geometry') then
    raise exception 'ZONE UPDATE PROOF FAIL: geometry-drift stale_revision did not name the field: %', r->'details';
  end if;

  -- nothing the caller attempted was written; no audit rows for the stale requests.
  select * into v_row from public.danger_zones where id = v_id;
  if v_row.name = 'ZUpd Stale Attempt' then
    raise exception 'ZONE UPDATE PROOF FAIL: a stale-rejected update WROTE the name';
  end if;
  select count(*) into n from public.world_editor_audit
   where request_id in ('zoneupd-stale-name-1','zoneupd-stale-geom-1');
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL: a stale-rejected update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_STALE_REVISION_REJECTED';
end $$;

-- ── PROOF 6 — a SELF-INTERSECTING new ring fails the AUTHORITATIVE ST_IsValid gate (invalid_geometry) ─
-- The expected MATCHES the live row (so concurrency passes); only the NEW fields.geometry is a bowtie.
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_create('zoneupd-bowtie-seed-1', jsonb_build_object(
         'fields', jsonb_build_object('name','ZUpd Bowtie Origin','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 700, 'y', 700),
             jsonb_build_object('x', 900, 'y', 700),
             jsonb_build_object('x', 900, 'y', 900),
             jsonb_build_object('x', 700, 'y', 900))))));
  v_id := (r->'result'->>'id')::uuid;

  r := public.zone_update('zoneupd-bowtie-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','ZUpd Bowtie Origin','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 700, 'y', 700),
             jsonb_build_object('x', 900, 'y', 700),
             jsonb_build_object('x', 900, 'y', 900),
             jsonb_build_object('x', 700, 'y', 900)))),
         'fields', jsonb_build_object('name','ZUpd Bowtie Origin','attach_location_id', null,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 0,   'y', 0),
             jsonb_build_object('x', 100, 'y', 100),
             jsonb_build_object('x', 100, 'y', 0),
             jsonb_build_object('x', 0,   'y', 100))))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or (r->'details'->0->>'code') <> 'invalid_geometry' then
    raise exception 'ZONE UPDATE PROOF FAIL: the bowtie new ring was not a typed invalid_geometry: %', r;
  end if;
  -- nothing written: the boundary is still the original square (contains its own center 800,800).
  select * into v_row from public.danger_zones where id = v_id;
  if not ST_Contains(v_row.boundary, ST_MakePoint(800, 800)) then
    raise exception 'ZONE UPDATE PROOF FAIL: an invalid-geometry update overwrote the boundary';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneupd-bowtie-1';
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL: an invalid-geometry update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_INVALID_GEOMETRY_REJECTED';
end $$;

-- ── PROOF 7 — a SEEDED source='circle' zone is PROTECTED from edit (validation_failed {protected_zone}) ─
-- Insert a source='circle' zone (superuser — zone_create only writes 'drawn'); it must be location-backed
-- per the coherence CHECK. The expected MATCHES it (circle geometry → ST_Equals passes), so we reach the
-- protection guard rather than a stale rejection.
do $$
declare v_owner uuid; v_hostile uuid; v_id uuid; r jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_hostile from publoc where k = 'hostile';
  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status, created_by)
    values ('ZUpd Seeded Circle', 'pirate', 'circle', v_hostile,
            ST_Buffer(ST_MakePoint(1000, 1000), 100, 32), 'active', v_owner)
    returning id into v_id;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_update('zoneupd-protected-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','ZUpd Seeded Circle','zone_kind','pirate',
           'attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',100)),
         'fields', jsonb_build_object('name','Hijacked Seed','attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',150))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'protected_zone' and d->>'field' = 'source') then
    raise exception 'ZONE UPDATE PROOF FAIL: a seeded circle zone was not protected with a typed protected_zone: %', r;
  end if;
  select * into v_row from public.danger_zones where id = v_id;
  if v_row.name <> 'ZUpd Seeded Circle' or v_row.source <> 'circle' then
    raise exception 'ZONE UPDATE PROOF FAIL: a protected-zone rejection changed the seeded row (%, %)', v_row.name, v_row.source;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneupd-protected-1';
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL: a protected-zone rejection wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_PROTECTED_ZONE';
end $$;

-- ── PROOF 8 — the audit row carries BOTH before_snapshot AND after_snapshot (an update, not a create) ─
do $$
declare v_before jsonb; v_after jsonb; v_rev text; v_type text; v_ttype text; v_tid text;
begin
  select before_snapshot, after_snapshot, source_revision, command_type, target_type, target_id
    into v_before, v_after, v_rev, v_type, v_ttype, v_tid
    from public.world_editor_audit where request_id = 'zoneupd-owner-1';
  if v_type is distinct from 'zone_update' or v_ttype is distinct from 'zone' then
    raise exception 'ZONE UPDATE PROOF FAIL: audit command/target type wrong (got %, %)', v_type, v_ttype;
  end if;
  if v_before is null or jsonb_typeof(v_before) <> 'object' then
    raise exception 'ZONE UPDATE PROOF FAIL: before_snapshot is not a jsonb object: %', v_before;
  end if;
  if v_after is null or jsonb_typeof(v_after) <> 'object' then
    raise exception 'ZONE UPDATE PROOF FAIL: after_snapshot is not a jsonb object: %', v_after;
  end if;
  -- before mirrors the pre-edit square (the drawn origin); after mirrors the edited circle.
  if (v_before->>'name') <> 'ZUpd Origin' or (v_before->>'source') <> 'drawn'
     or (v_before->>'boundary_wkt') not like 'POLYGON%' then
    raise exception 'ZONE UPDATE PROOF FAIL: before_snapshot does not mirror the pre-edit row: %', v_before;
  end if;
  if (v_after->>'name') <> 'ZUpd Renamed' or (v_after->>'source') <> 'drawn'
     or (v_after->>'boundary_wkt') not like 'POLYGON%' then
    raise exception 'ZONE UPDATE PROOF FAIL: after_snapshot does not mirror the post-edit row: %', v_after;
  end if;
  if (v_before->>'id') <> (v_after->>'id') then
    raise exception 'ZONE UPDATE PROOF FAIL: before/after snapshots disagree on the row id (% vs %)', v_before->>'id', v_after->>'id';
  end if;
  if v_tid is distinct from (v_after->>'id') then
    raise exception 'ZONE UPDATE PROOF FAIL: audit target_id (%) disagrees with the edited id (%)', v_tid, v_after->>'id';
  end if;
  -- the boundary actually CHANGED (edit re-materialized geometry) while the id stayed the same.
  if (v_before->>'boundary_wkt') = (v_after->>'boundary_wkt') then
    raise exception 'ZONE UPDATE PROOF FAIL: the edit did not change the boundary snapshot';
  end if;
  if v_rev is distinct from 'zoneupd-proof-rev-1' then
    raise exception 'ZONE UPDATE PROOF FAIL: audit source_revision not recorded (got %)', v_rev;
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_AUDIT_BEFORE_AFTER';
end $$;

-- ── PROOF 9 — a VANISHED target is a typed not_found (source_missing); a NON-uuid target is a typed
--    invalid_request. Zero side effects either way. ──────────────────────────────────────────────────
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_update('zoneupd-notfound-1', jsonb_build_object(
         'target_id', gen_random_uuid()::text,
         'expected', jsonb_build_object('name','No Such Zone'),
         'fields', jsonb_build_object('name','Whatever','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',0,'y',0),'radius',50))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_found'
     or (r->'details'->0->>'code') <> 'source_missing' then
    raise exception 'ZONE UPDATE PROOF FAIL: vanished target was not a typed not_found/source_missing: %', r;
  end if;
  r := public.zone_update('zoneupd-badtarget-1', jsonb_build_object(
         'target_id', 'not-a-uuid',
         'expected', jsonb_build_object('name','X'),
         'fields', jsonb_build_object('name','X')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'invalid_request' then
    raise exception 'ZONE UPDATE PROOF FAIL: non-uuid target was not rejected as invalid_request: %', r;
  end if;
  select count(*) into n from public.world_editor_audit
   where request_id in ('zoneupd-notfound-1','zoneupd-badtarget-1');
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL: a not_found/invalid_request call wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_NOT_FOUND';
end $$;

-- ── PROOF 10 — the 0239 pirate-zone lockdown is INTACT + danger_zones is the ONLY write path ───────────
do $$
begin
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE UPDATE PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE UPDATE PROOF FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path regressed';
  end if;
  -- no client role holds a danger_zones table write (the definer body is the only write path).
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'INSERT')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'DELETE') then
    raise exception 'ZONE UPDATE PROOF FAIL: a client role holds a danger_zones WRITE grant — the narrowing did not hold';
  end if;
  -- SELECT survives (the flag-gated zone read depends on it).
  if not has_table_privilege('anon', 'public.danger_zones', 'SELECT')
     or not has_table_privilege('authenticated', 'public.danger_zones', 'SELECT') then
    raise exception 'ZONE UPDATE PROOF FAIL: a client role lost SELECT on danger_zones — the zone read would break';
  end if;
  raise notice 'PUBLISH_ZONE_UPD_PASS_PIRATE_ZONE_LOCKDOWN_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-ZONE-UPDATE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (the pirate_intercept_enabled flip included).
