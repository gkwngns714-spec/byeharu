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
-- validation_failed {invalid_geometry}); gates seeded (provenance='seeded') zones on
-- `seeded_zone_edit_enabled` — DARK protects with a typed validation_failed {protected_zone}, LIT accepts
-- the edit while provenance stays 'seeded' so the gate remains a genuine toggle (PROOF 7 proves BOTH
-- postures, txn-locally, and restores whatever posture the deployed chain ships); CLAIMS a reshaped row
-- for the AUTHORED writer by setting source='drawn' (0319), so an owner-drawn boundary survives a later
-- edit of its location BYTE-IDENTICAL while a genuinely seeded source='circle' zone still TRACKS its
-- location — PROOF 12 drives both directions through the real zone_update and location_update RPCs;
-- returns a typed not_found/source_missing for a vanished target and
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
         -- 0287: source_revision is the SERVER's danger_zones.revision, not an arbitrary client
         -- string. Read it the way the client does — off the live row it forked.
         'source_revision', (select revision::text from public.danger_zones where id = v_id),
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
          'source_revision', (select revision::text from public.danger_zones where id = v_id),
          'expected', jsonb_build_object('name','ZUpd Idem Origin','zone_kind','pirate','attach_location_id', null,
            'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
              jsonb_build_object('x', -100, 'y', -100),
              jsonb_build_object('x',  100, 'y', -100),
              jsonb_build_object('x',  100, 'y',  100),
              jsonb_build_object('x', -100, 'y',  100)))),
          'fields', jsonb_build_object('name','ZUpd Idem First','attach_location_id', null,
            'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',500,'y',500),'radius',80))));
  -- same request_id, DIFFERENT fields — must NOT re-apply, must return the prior result.
  -- The replay carries a DIFFERENT (now-current) revision as well as different fields: the request_id
  -- short-circuit must fire BEFORE any concurrency reasoning, or idempotency would be revision-fragile.
  r2 := public.zone_update('zoneupd-idem-1', jsonb_build_object(
          'target_id', v_id::text,
          'source_revision', (select revision::text from public.danger_zones where id = v_id),
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

-- ── PROOF 5 — OPTIMISTIC CONCURRENCY: a stale REVISION is REJECTED (stale_revision), no write ───────
-- 0287: the authority is danger_zones.revision, not a value-by-value compare of `expected`. Drift is
-- simulated by a direct superuser UPDATE that also advances the revision — which is what every zone
-- command does — while the caller still holds the fork-time token. Both a name drift and a geometry
-- drift are proven, PLUS the converse: an UNMOVED revision publishes even when the boundary is a
-- buffer arc whose coordinates could never survive an exact round-trip.
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int; v_row record; v_expected jsonb; v_fields jsonb;
        v_fork_rev text;
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
  -- the token the draft pinned at fork time, exactly as the client carries it
  select revision::text into v_fork_rev from public.danger_zones where id = v_id;

  -- 0287: the REVISION is the concurrency authority, so a concurrent write must advance it — which is
  -- exactly what every zone command now does. These fixtures therefore bump revision alongside the
  -- field change, reproducing a real concurrent editor rather than a hand-edited column.
  --
  -- (a) NAME drift: a concurrent editor renamed the zone; the boundary is untouched. The draft still
  -- holds the PRE-drift revision, so it is stale.
  update public.danger_zones
     set name = 'Concurrently Renamed', revision = revision + 1
   where id = v_id;
  r := public.zone_update('zoneupd-stale-name-1', jsonb_build_object(
         'target_id', v_id::text, 'source_revision', v_fork_rev,
         'expected', v_expected, 'fields', v_fields));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision' then
    raise exception 'ZONE UPDATE PROOF FAIL: a name drift was not rejected as stale_revision: %', r;
  end if;
  if not exists (select 1 from jsonb_array_elements(r->'details') d
                 where d->>'code' = 'source_changed' and d->>'field' = 'name') then
    raise exception 'ZONE UPDATE PROOF FAIL: name-drift stale_revision did not name the field: %', r->'details';
  end if;

  -- (b) GEOMETRY drift: restore the name, then reshape the boundary to a DIFFERENT triangle, again
  -- advancing the revision as a real editor would. The draft's stale token is what rejects it.
  --
  -- The rejection is NO LONGER field-attributed for geometry, and that is the point of 0287: the
  -- boundary cannot be compared for equality at all, because the ring only ever reaches a client at 15
  -- significant digits. Attributing drift to 'geometry' required exactly the ST_Equals compare that
  -- made every buffer-derived zone permanently unpublishable. What survives is an honest, unattributed
  -- statement that the row moved — which is all the revision can truthfully say.
  update public.danger_zones set name = 'ZUpd Stale Origin' where id = v_id;
  update public.danger_zones
     set boundary = ST_MakePolygon(ST_MakeLine(ARRAY[
       ST_MakePoint(-500,-500), ST_MakePoint(-300,-500), ST_MakePoint(-400,-300), ST_MakePoint(-500,-500)])),
         revision = revision + 1
   where id = v_id;
  r := public.zone_update('zoneupd-stale-geom-1', jsonb_build_object(
         'target_id', v_id::text, 'source_revision', v_fork_rev,
         'expected', v_expected, 'fields', v_fields));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision' then
    raise exception 'ZONE UPDATE PROOF FAIL: a geometry drift was not rejected as stale_revision: %', r;
  end if;
  if not exists (select 1 from jsonb_array_elements(r->'details') d
                 where d->>'code' = 'source_changed') then
    raise exception 'ZONE UPDATE PROOF FAIL: geometry-drift stale_revision carried no source_changed detail: %', r->'details';
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

  -- (c) THE CONVERSE — run LAST because it deliberately succeeds and writes. A row whose revision has
  -- NOT moved publishes, even though its boundary is a buffer arc whose coordinates could never
  -- survive an exact round-trip. Without this case the suite would still pass with the old lossy
  -- ST_Equals compare in place, which is precisely how the defect shipped.
  update public.danger_zones
     set boundary = ST_Buffer(ST_MakePoint(2000.1234, 3000.5678), 149.9753, 8)
   where id = v_id;   -- revision deliberately NOT bumped
  r := public.zone_update('zoneupd-fresh-rev-1', jsonb_build_object(
         'target_id', v_id::text,
         'source_revision', (select revision::text from public.danger_zones where id = v_id),
         'expected', v_expected, 'fields', v_fields));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE UPDATE PROOF FAIL: a CURRENT revision was rejected — the gate is not the revision: %', r;
  end if;
  -- and the applied edit ADVANCED the token, or a second publish off the same fork could slip through.
  select revision into n from public.danger_zones where id = v_id;
  if n::text = (select revision::text from public.danger_zones where id = v_id and revision::text = v_fork_rev) then
    raise exception 'ZONE UPDATE PROOF FAIL: revision did not advance on an applied edit';
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
         'source_revision', (select revision::text from public.danger_zones where id = v_id),
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

-- ── PROOF 7 — SEEDED-ZONE PROTECTION IS FLAG-GATED, AND THE GATE SWINGS BOTH WAYS ────────────────────
-- Insert a seeded zone (superuser — zone_create only writes provenance='owner'); it must be
-- location-backed per the coherence CHECK (0233:195: source='circle' ⇒ location_id not null).
--
-- provenance IS THE AUTHORITY, NOT source (0282). This fixture used to set only source='circle' and rely
-- on the pre-0282 rule "seeded == source='circle'". 0282 split the two: `source` is the geometry kind,
-- `provenance` is the creation/protection class — and its column DEFAULT is 'owner', with the one-time
-- backfill classifying only the rows that already existed. So a freshly inserted source='circle' row is
-- provenance='owner', the guard correctly declines to protect it, and this proof failed while the guard
-- was working exactly as specified. Set provenance explicitly (INSERT is allowed; 0282's immutability
-- trigger only blocks UPDATE) so the proof tests the rule that actually exists.
--
-- ── WHY THIS CASE IS NOW FLAG-AWARE (2026-07-27) ────────────────────────────────────────────────────
-- Protection is not unconditional: 0287:173-179 (the zone_update head) protects only when
--     provenance = 'seeded' AND NOT cfg_bool('seeded_zone_edit_enabled')
-- and 0283 SEEDS that key 'false'. This case used to assert the DARK answer as if it were the only
-- answer, which was true only for as long as the key stayed dark.
--
-- 0300 (`lights_on`) then set 44 capability keys true, `seeded_zone_edit_enabled` among them
-- (0300:85-86) — a deliberate owner order, not a mistake. On that chain the protection branch no longer
-- fires, control falls through to the OPTIMISTIC-CONCURRENCY gate at 0287:198-226, and because this
-- fixture never carried a `source_revision` the fail-closed rule there answered
--     {ok:false, error:'stale_revision', details:[{code:'source_changed', field:null}]}
-- The old assertion read that as "protection is broken". It was not: a DIFFERENT gate answered, for a
-- reason that had nothing to do with provenance. Asserting one posture as universal is what broke.
--
-- So this case now proves the INVARIANT rather than one of its two shadows: **the flag is the gate.**
-- It pins the key txn-locally in BOTH positions (the same idiom this script already uses for
-- `pirate_intercept_enabled` at PROOF 1 / PROOF 11, and that every sibling proof uses for its own flag
-- set), asserts the correct answer under each, and restores whatever posture the deployed chain ships.
-- The ambient value is read FIRST and named in every failure message, so a red log says immediately
-- which posture production is in — and pinning means neither assertion can ever go dead, which a plain
-- ambient branch could not promise once 0300 landed.
--
--   (a) DARK  → typed validation_failed {protected_zone}; the row is untouched; no audit row.
--   (b) LIT   → the edit is ACCEPTED on a CURRENT revision and applied to the SAME id, and
--               `provenance` STAYS 'seeded'. That last clause is the whole reversibility claim of
--               0283's header ("Because provenance cannot move, flipping a flag off restores protection
--               exactly") and of 0282's immutability trigger — lighting the key unlocks editing, it
--               does NOT launder a seeded row into owner content. Also proven here: with the key lit a
--               draft carrying NO revision token is STILL rejected `stale_revision` — i.e. exactly the
--               answer the red run saw, now asserted as the concurrency gate it actually is.
--   (c) DARK again → the SAME row, now owner-reshaped, is protected again. Not a repeat of (a): (a)
--               proves an untouched seed is protected, (c) proves an EDITED seed re-protects, which is
--               the one-way-door risk 0282 exists to prevent.
--
-- THE SEAM THAT USED TO BE NAMED HERE IS CLOSED (0319). This block used to end with a paragraph saying
-- zone_update preserved `source` bit-for-bit (0287:397-399), so a seeded 'circle' row reshaped while the
-- key is lit stayed source='circle' and 0296's rematerialize-on-location-edit writer would regenerate
-- over the owner's shape — and it deliberately did NOT pin `source` after the lit edit, because
-- "pinning it would cement the defect". 0319 sets source='drawn' when zone_update materializes an owner
-- ring, which is the fix 0296:66-68 wrote down. So pinning `source` now cements the FIX, and case (b)
-- below does exactly that. The end-to-end property — the drawn shape SURVIVING a later location edit,
-- and a genuinely seeded zone still tracking its own — is PROOF 12.
do $$
declare v_owner uuid; v_hostile uuid; v_id uuid; r jsonb; n int; v_row record;
        v_ambient boolean; v_posture text; v_rev text;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_hostile from publoc where k = 'hostile';

  -- THE AMBIENT POSTURE — read before anything is pinned, so the log names what production ships.
  if not exists (select 1 from public.game_config where key = 'seeded_zone_edit_enabled') then
    raise exception 'ZONE UPDATE PROOF FAIL: game_config has no seeded_zone_edit_enabled key — 0283 did not seed the gate this case exercises';
  end if;
  v_ambient := coalesce(public.cfg_bool('seeded_zone_edit_enabled'), false);
  v_posture := case when v_ambient then 'LIT' else 'DARK' end;
  raise notice 'PUBLISH_ZONE_UPD_SEEDED_GATE_AMBIENT=% (seeded_zone_edit_enabled as the deployed chain leaves it)', v_posture;

  insert into public.danger_zones (name, zone_kind, source, provenance, location_id, boundary, status, created_by)
    values ('ZUpd Seeded Circle', 'pirate', 'circle', 'seeded', v_hostile,
            ST_Buffer(ST_MakePoint(1000, 1000), 100, 32), 'active', v_owner)
    returning id into v_id;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- ── (a) DARK: the seeded zone is PROTECTED ────────────────────────────────────────────────────────
  insert into public.game_config(key, value, description)
    values ('seeded_zone_edit_enabled', 'false'::jsonb, 'proof-txn-local')
    on conflict (key) do update set value = 'false'::jsonb;

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
    raise exception 'ZONE UPDATE PROOF FAIL [posture DARK, seeded_zone_edit_enabled pinned false; chain ambient = %]: a seeded circle zone was not protected with a typed protected_zone: %', v_posture, r;
  end if;
  select * into v_row from public.danger_zones where id = v_id;
  if v_row.name <> 'ZUpd Seeded Circle' or v_row.source <> 'circle' then
    raise exception 'ZONE UPDATE PROOF FAIL [posture DARK; chain ambient = %]: a protected-zone rejection changed the seeded row (%, %)', v_posture, v_row.name, v_row.source;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneupd-protected-1';
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL [posture DARK; chain ambient = %]: a protected-zone rejection wrote % audit row(s)', v_posture, n;
  end if;

  -- ── (b) LIT: the edit is ACCEPTED, and the row stays SEEDED ───────────────────────────────────────
  insert into public.game_config(key, value, description)
    values ('seeded_zone_edit_enabled', 'true'::jsonb, 'proof-txn-local')
    on conflict (key) do update set value = 'true'::jsonb;

  -- fork a CURRENT revision, the way the client does off the live row (0287:198-205). Without it the
  -- fail-closed concurrency rule answers stale_revision and the EDIT path is never reached — which is
  -- precisely the artifact that made a lit chain look like broken protection.
  select revision::text into v_rev from public.danger_zones where id = v_id;
  r := public.zone_update('zoneupd-seeded-lit-1', jsonb_build_object(
         'target_id', v_id::text,
         'source_revision', v_rev,
         'expected', jsonb_build_object('name','ZUpd Seeded Circle','zone_kind','pirate',
           'attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',100)),
         'fields', jsonb_build_object('name','Hijacked Seed','attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',150))));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT, seeded_zone_edit_enabled pinned true; chain ambient = %]: seeded-zone editing is enabled, so a CURRENT-revision edit of a seeded zone must be ACCEPTED: %', v_posture, r;
  end if;
  if (r->'result'->>'updated') <> 'true' or (r->'result'->>'id') <> v_id::text
     or (r->'result'->>'name') <> 'Hijacked Seed' then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT; chain ambient = %]: the accepted seeded edit returned a malformed result: %', v_posture, r;
  end if;
  select * into v_row from public.danger_zones where id = v_id;
  if v_row.name <> 'Hijacked Seed' or v_row.location_id is distinct from v_hostile
     or v_row.status <> 'active' then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT; chain ambient = %]: the accepted seeded edit did not apply (%, %, %)', v_posture, v_row.name, v_row.location_id, v_row.status;
  end if;
  -- the boundary was re-materialized to the NEW radius (150, not the seeded 100).
  if not ST_IsValid(v_row.boundary) or not ST_Contains(v_row.boundary, ST_MakePoint(1000, 1000)) then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT; chain ambient = %]: the re-materialized seeded boundary is not a valid polygon containing its own center', v_posture;
  end if;
  if abs(ST_Area(v_row.boundary) - pi() * 150 * 150) > 0.05 * pi() * 150 * 150 then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT; chain ambient = %]: the edited seeded boundary area % is not ~pi*150^2 — the new radius did not take', v_posture, ST_Area(v_row.boundary);
  end if;
  -- THE REVERSIBILITY CLAIM: editing a seeded zone must NOT reclassify it. provenance is immutable
  -- (0282's trigger) and zone_update never writes it, so the row is still protectable material.
  if v_row.provenance <> 'seeded' then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT; chain ambient = %]: an accepted edit moved provenance to ''%'' — lighting the key would be a ONE-WAY DOOR, not a toggle', v_posture, v_row.provenance;
  end if;
  -- …and the GEOMETRY question is answered the other way (0319): the row now carries an owner-authored
  -- ring, so it must say so and leave the derived writer's source='circle' selection for good. These
  -- two assertions together ARE 0282's split: `provenance` did not move, `source` did.
  if v_row.source <> 'drawn' then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT; chain ambient = %]: an accepted edit left source=''%'' — an owner-drawn ring stays inside 0296''s regenerator selection and the next location edit destroys it (0319)', v_posture, v_row.source;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneupd-seeded-lit-1';
  if n <> 1 then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT; chain ambient = %]: an accepted seeded edit wrote % audit row(s) (expected exactly 1)', v_posture, n;
  end if;

  -- …and with the key LIT the concurrency gate is still the one that fails closed: a draft carrying NO
  -- revision token is rejected stale_revision. This is the exact answer a lit chain gave the old
  -- assertion; it is asserted here as what it really is, so it can never again be read as lost protection.
  r := public.zone_update('zoneupd-seeded-lit-norev-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','Hijacked Seed','zone_kind','pirate',
           'attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',150)),
         'fields', jsonb_build_object('name','Hijacked Seed II','attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',160))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or not exists (select 1 from jsonb_array_elements(r->'details') d where d->>'code' = 'source_changed') then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT; chain ambient = %]: a token-less draft must still fail closed as stale_revision even when seeded editing is enabled: %', v_posture, r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneupd-seeded-lit-norev-1';
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL [posture LIT; chain ambient = %]: a stale-rejected seeded edit wrote % audit row(s)', v_posture, n;
  end if;

  -- ── (c) DARK again: the EDITED seeded row re-protects exactly ─────────────────────────────────────
  insert into public.game_config(key, value, description)
    values ('seeded_zone_edit_enabled', 'false'::jsonb, 'proof-txn-local')
    on conflict (key) do update set value = 'false'::jsonb;

  r := public.zone_update('zoneupd-protected-again-1', jsonb_build_object(
         'target_id', v_id::text,
         'source_revision', (select revision::text from public.danger_zones where id = v_id),
         'expected', jsonb_build_object('name','Hijacked Seed','zone_kind','pirate',
           'attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',150)),
         'fields', jsonb_build_object('name','Hijacked Seed III','attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','circle','center', jsonb_build_object('x',1000,'y',1000),'radius',170))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'protected_zone' and d->>'field' = 'source') then
    raise exception 'ZONE UPDATE PROOF FAIL [posture DARK-after-edit; chain ambient = %]: turning seeded_zone_edit_enabled back off did not RE-PROTECT an already-edited seeded zone — the flag is a one-way door: %', v_posture, r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneupd-protected-again-1';
  if n <> 0 then
    raise exception 'ZONE UPDATE PROOF FAIL [posture DARK-after-edit; chain ambient = %]: a re-protection rejection wrote % audit row(s)', v_posture, n;
  end if;

  -- ── restore the posture the deployed chain ships (the whole txn rolls back anyway; this keeps every
  -- later case reading the REAL chain value rather than this case's last pin). ───────────────────────
  insert into public.game_config(key, value, description)
    values ('seeded_zone_edit_enabled', to_jsonb(v_ambient), 'proof-txn-local')
    on conflict (key) do update set value = to_jsonb(v_ambient);
  if coalesce(public.cfg_bool('seeded_zone_edit_enabled'), false) is distinct from v_ambient then
    raise exception 'ZONE UPDATE PROOF FAIL: this case did not restore seeded_zone_edit_enabled to the chain''s ambient % posture', v_posture;
  end if;

  raise notice 'PUBLISH_ZONE_UPD_PASS_PROTECTED_ZONE (gate proven in BOTH postures; chain ambient = %)', v_posture;
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
  -- 0287: the audit records the SERVER token the caller forked at, not an arbitrary client string.
  -- PROOF 1 edits a zone freshly made by zone_create, so its fork-time revision is 0 — the ledger must
  -- carry that verbatim (a numeric token), never null and never a fabricated label.
  if v_rev is null or v_rev !~ '^[0-9]+$' then
    raise exception 'ZONE UPDATE PROOF FAIL: audit source_revision not recorded as the server token (got %)', v_rev;
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

-- ── PROOF 11 — THE ROUND-TRIP: a boundary the client can only READ THROUGH get_danger_zones must
-- still satisfy the optimistic-concurrency compare when NOTHING has changed. ───────────────────────
-- This is the exact production failure: editing a seeded zone returns stale_revision {geometry} while
-- the live row is provably unchanged. Every earlier proof here builds its fixture from LITERAL integer
-- coordinates (0, 300 …) created through zone_create, so the client's `expected` re-materializes to a
-- bit-identical boundary and ST_Equals passes trivially. Real seeded zones are ST_Buffer arcs whose
-- coordinates are irrational-ish doubles — and the ONLY channel the client has is get_danger_zones,
-- which emits them through jsonb_build_array(ST_X(...), ST_Y(...)).
--
-- The proof therefore does exactly what the app does, with NO privileged shortcut:
--   1. create a buffer-derived boundary (the seeded-zone shape),
--   2. read the ring back THROUGH get_danger_zones (the client's only view),
--   3. feed that ring back verbatim as `expected` to zone_update, changing ONLY the name.
-- If the transported ring cannot reconstitute a boundary ST_Equals accepts, the edit is impossible for
-- every zone of this shape — permanently, because re-forking re-reads the same lossy channel.
do $$
declare
  v_owner uuid; v_hostile uuid; v_id uuid; r jsonb; v_ring jsonb; v_verts jsonb := '[]'::jsonb;
  v_i int; v_read jsonb; v_n int; v_exact boolean;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_hostile from publoc where k = 'hostile';

  -- (1) a DRAWN zone whose boundary is a BUFFER ARC — the seeded-zone geometry class. provenance is
  -- left at its 'owner' default on purpose: this proof is about the geometry round-trip, NOT about the
  -- seeded guard (PROOF 7 owns that), so nothing here can be confused with protection.
  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status, created_by)
    values ('ZUpd RoundTrip', 'pirate', 'drawn', v_hostile,
            ST_Buffer(ST_MakePoint(1234.5678, -987.6543), 321.0987, 8), 'active', v_owner)
    returning id into v_id;

  -- (2) read the ring back through the CLIENT'S ONLY CHANNEL.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  insert into public.game_config(key, value, description)
    values ('pirate_intercept_enabled', 'true'::jsonb, 'proof-local')
    on conflict (key) do update set value = 'true'::jsonb;
  v_read := public.get_danger_zones();
  select (e->'ring') into v_ring from jsonb_array_elements(v_read) e where (e->>'id') = v_id::text;
  if v_ring is null then
    raise exception 'ZONE UPDATE ROUND-TRIP FAIL: the zone is not visible through get_danger_zones';
  end if;

  -- drop the closing duplicate exactly as zoneDraftModel.openRingFromLive does, and rebuild the
  -- {x,y} vertex objects the draft carries as its fork-time snapshot.
  v_n := jsonb_array_length(v_ring);
  select coalesce(jsonb_agg(jsonb_build_object(
           'x', (elem->>0)::double precision,
           'y', (elem->>1)::double precision) order by ord), '[]'::jsonb)
    into v_verts
    from jsonb_array_elements(v_ring) with ordinality as t(elem, ord)
   where ord <= v_n - 1;   -- drop the closing duplicate (openRingFromLive)
  if jsonb_array_length(v_verts) <> v_n - 1 then
    raise exception 'ZONE UPDATE ROUND-TRIP FAIL: rebuilt % vertices from a %-point ring',
      jsonb_array_length(v_verts), v_n;
  end if;

  -- (3) publish an edit that changes ONLY the name. `expected` is the transported ring verbatim.
  r := public.zone_update('zoneupd-roundtrip-1', jsonb_build_object(
         'target_id', v_id::text,
         'source_revision', (select revision::text from public.danger_zones where id = v_id),
         'expected', jsonb_build_object(
           'name','ZUpd RoundTrip','zone_kind','pirate','attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','polygon','vertices', v_verts)),
         'fields', jsonb_build_object(
           'name','ZUpd RoundTrip Renamed','attach_location_id', v_hostile::text,
           'geometry', jsonb_build_object('kind','polygon','vertices', v_verts))));

  if (r->>'ok')::boolean is not true then
    raise exception E'ZONE UPDATE ROUND-TRIP FAIL: an UNCHANGED zone was rejected as drifted.\n'
      '  ring points read back: %\n'
      '  server said: %\n'
      '  MEANING: the client cannot round-trip this boundary through get_danger_zones, so every zone '
      'of this geometry class is permanently unpublishable via edit.', v_n, r;
  end if;

  raise notice 'PUBLISH_ZONE_UPD_PASS_GEOMETRY_ROUND_TRIP';
end $$;

-- ── PROOF 12 (0319) — A ZONE THE OWNER DREW SURVIVES THE NEXT EDIT OF ITS LOCATION ─────────────────
-- THE DEFECT THIS IS RED FOR. danger_zones.boundary has two writers:
--   * zone_update — materializes the ring the OWNER drew;
--   * danger_zone_rematerialize_for_location (0296:141) — regenerates a DERIVED polygon from the
--     location's (x, y, territory_radius) with 0237's random() generator. It selects
--     `where dz.source = 'circle'` (0296:169), and location_update fires it on every edit that moves
--     one of those three inputs (0296:569-573).
-- Before 0319, zone_update preserved `source` bit-for-bit, so an owner-reshaped SEEDED zone kept
-- source='circle' and stayed inside the derived writer's selection. The next location edit replaced
-- the owner's shape with a random blob — and random() has no inverse, so nothing brings it back.
-- 0296:62-68 named this exact seam, wrote down this exact fix, and deferred it on the premise that
-- "the flag being dark means no such row can exist today". seeded_zone_edit_enabled was lit by
-- 0300:85-86, and on production such a row existed.
--
-- WHY THIS IS RED BY CONSTRUCTION ON THE PRE-0319 BODY, in two independent places:
--   (b) `source` is still 'circle' after the owner's reshape — the classification never moved;
--   (d) the boundary is NOT byte-identical after the location edit — the blob already landed.
-- Neither can pass by accident: (d) compares ST_AsBinary, not an area or a vertex count.
--
-- AND THE CONVERSE, so the fix can never be "disable the regenerator" (case e): a genuinely seeded
-- source='circle' zone the owner NEVER touched must STILL track its location. If 0319 had been
-- implemented by weakening danger_zone_rematerialize_for_location instead of by making the two
-- writers disjoint at the row, case (e) goes red.
--
-- Fixtures are built here and owned here: two hostile sites, two seeded zones, one edited and one not.
-- The seeded_zone_edit_enabled pin is txn-local and restored, exactly as PROOF 7 does it.
do $$
declare
  v_owner uuid; v_zone uuid;
  v_locA uuid; v_locB uuid; v_zA uuid; v_zB uuid;
  r jsonb; v_ambient boolean; v_lrow jsonb; v_exp jsonb; v_fields jsonb;
  v_wkb_a bytea; v_wkb_b bytea; v_rev_a bigint; v_upd_a timestamptz; v_src_a text;
begin
  select v into v_owner from pubids where k = 'owner';
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'ZONE UPDATE PROOF SETUP FAIL [PROOF 12]: the seeded chain has no zones to host the fixtures';
  end if;

  -- ── fixtures: two ACTIVE hostile sites, each carrying a territory the generator can derive from ──
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values (v_zone, 'ZUpd Drawn Stays A', 'pirate_hunt', 'hunt_pirates', 3000, 3000, 1, 1, 0, true, 100, 'active')
    returning id into v_locA;
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values (v_zone, 'ZUpd Drawn Stays B', 'pirate_hunt', 'hunt_pirates', 4000, 4000, 1, 1, 0, true, 100, 'active')
    returning id into v_locB;

  -- two SEEDED derived zones — the exact class 0233:215-221 creates and 0296's writer owns.
  insert into public.danger_zones (name, zone_kind, source, provenance, location_id, boundary, status)
    values ('ZUpd Drawn Stays Zone A', 'pirate', 'circle', 'seeded', v_locA,
            ST_Buffer(ST_MakePoint(3000, 3000), 100, 32), 'active')
    returning id into v_zA;
  insert into public.danger_zones (name, zone_kind, source, provenance, location_id, boundary, status)
    values ('ZUpd Drawn Stays Zone B', 'pirate', 'circle', 'seeded', v_locB,
            ST_Buffer(ST_MakePoint(4000, 4000), 100, 32), 'active')
    returning id into v_zB;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- ── (a) the owner reshapes zone A by hand (seeded editing pinned LIT, txn-locally) ───────────────
  v_ambient := coalesce(public.cfg_bool('seeded_zone_edit_enabled'), false);
  insert into public.game_config(key, value, description)
    values ('seeded_zone_edit_enabled', 'true'::jsonb, 'proof-txn-local')
    on conflict (key) do update set value = 'true'::jsonb;

  r := public.zone_update('zoneupd-drawnstays-edit-1', jsonb_build_object(
         'target_id', v_zA::text,
         'source_revision', (select revision::text from public.danger_zones where id = v_zA),
         'expected', jsonb_build_object('name','ZUpd Drawn Stays Zone A','zone_kind','pirate',
           'attach_location_id', v_locA::text),
         'fields', jsonb_build_object('name','ZUpd Drawn Stays Zone A','attach_location_id', v_locA::text,
           'geometry', jsonb_build_object('kind','polygon','vertices', jsonb_build_array(
             jsonb_build_object('x', 2900, 'y', 2900),
             jsonb_build_object('x', 3140, 'y', 2905),
             jsonb_build_object('x', 3120, 'y', 3130),
             jsonb_build_object('x', 2960, 'y', 3160),
             jsonb_build_object('x', 2870, 'y', 3020))))));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE UPDATE PROOF FAIL [PROOF 12(a)]: the owner reshape of a seeded zone was rejected: %', r;
  end if;

  -- ── (b) THE FIX ITSELF: materializing an owner ring CLAIMS the row for the authored writer ───────
  select source into v_src_a from public.danger_zones where id = v_zA;
  if v_src_a <> 'drawn' then
    raise exception E'ZONE UPDATE PROOF FAIL [PROOF 12(b)]: zone_update materialized an OWNER-DRAWN ring but left source=''%''.\n'
      '  MEANING: the row is still inside danger_zone_rematerialize_for_location''s selection\n'
      '  (0296:169, where dz.source = ''circle''), so the next edit of its location will replace the\n'
      '  owner''s shape with a random blob that cannot be recovered. 0296:66-68 names this exact fix.', v_src_a;
  end if;
  -- and the reshape did NOT launder the row's protection class (0282's immutable trigger, 0283's toggle)
  if (select provenance from public.danger_zones where id = v_zA) <> 'seeded' then
    raise exception 'ZONE UPDATE PROOF FAIL [PROOF 12(b)]: claiming the geometry moved provenance — source answers the GEOMETRY question only, never protection';
  end if;

  -- ── (c) move zone A's LOCATION through the real RPC — the writer that destroys the shape ─────────
  select ST_AsBinary(boundary), revision, updated_at into v_wkb_a, v_rev_a, v_upd_a
    from public.danger_zones where id = v_zA;
  select ST_AsBinary(boundary) into v_wkb_b from public.danger_zones where id = v_zB;

  -- `expected` and `fields` are derived from the LIVE row via to_jsonb — the exact representation
  -- location_update compares against (0296:364-399) — so this case can never fail on a formatting
  -- mismatch and mask the property it exists to prove.
  select to_jsonb(l) into v_lrow from public.locations l where l.id = v_locA;
  v_exp := jsonb_build_object(
    'name', v_lrow->>'name', 'location_type', v_lrow->>'location_type',
    'activity_type', v_lrow->>'activity_type', 'x', v_lrow->'x', 'y', v_lrow->'y',
    'reward_tier', v_lrow->'reward_tier', 'base_difficulty', v_lrow->'base_difficulty',
    'min_power_required', v_lrow->'min_power_required', 'is_public', v_lrow->'is_public',
    'territory_radius', v_lrow->'territory_radius', 'status', v_lrow->>'status');
  v_fields := v_exp || jsonb_build_object('x', to_jsonb(3300::double precision),
                                          'y', to_jsonb(3300::double precision));

  r := public.location_update('zoneupd-drawnstays-locmove-a', jsonb_build_object(
         'target_id', v_locA::text, 'expected', v_exp, 'fields', v_fields));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE UPDATE PROOF FAIL [PROOF 12(c)]: the location move was rejected, so the property below was never exercised: %', r;
  end if;
  if (select x from public.locations where id = v_locA) <> 3300 then
    raise exception 'ZONE UPDATE PROOF FAIL [PROOF 12(c)]: the location did not actually move — the regenerator''s trigger condition (0296:569-573) was never met';
  end if;

  -- ── (d) THE PROPERTY: the owner's boundary survived BYTE-IDENTICAL ───────────────────────────────
  if (select ST_AsBinary(boundary) from public.danger_zones where id = v_zA) is distinct from v_wkb_a then
    raise exception E'ZONE UPDATE PROOF FAIL [PROOF 12(d)]: the owner''s hand-drawn boundary was REGENERATED by the location edit.\n'
      '  This is the irrecoverable case: 0237''s generator is random(), so the shape the owner drew is gone for good.\n'
      '  The row must leave the derived writer''s source=circle selection the moment zone_update materializes an owner ring.';
  end if;
  -- nothing else about the row moved either: a re-derivation would have bumped both (0296:202-206)
  if (select revision from public.danger_zones where id = v_zA) is distinct from v_rev_a
     or (select updated_at from public.danger_zones where id = v_zA) is distinct from v_upd_a then
    raise exception 'ZONE UPDATE PROOF FAIL [PROOF 12(d)]: the drawn zone''s revision/updated_at moved on a location edit — the derived writer still touched it';
  end if;

  -- ── (e) THE CONVERSE: an untouched SEEDED zone STILL tracks its location ─────────────────────────
  -- Without this, "make the drawn zone survive" could be satisfied by disabling the regenerator, which
  -- would silently re-open the 0289 split-brain 0296 exists to close.
  select to_jsonb(l) into v_lrow from public.locations l where l.id = v_locB;
  v_exp := jsonb_build_object(
    'name', v_lrow->>'name', 'location_type', v_lrow->>'location_type',
    'activity_type', v_lrow->>'activity_type', 'x', v_lrow->'x', 'y', v_lrow->'y',
    'reward_tier', v_lrow->'reward_tier', 'base_difficulty', v_lrow->'base_difficulty',
    'min_power_required', v_lrow->'min_power_required', 'is_public', v_lrow->'is_public',
    'territory_radius', v_lrow->'territory_radius', 'status', v_lrow->>'status');
  v_fields := v_exp || jsonb_build_object('x', to_jsonb(4400::double precision),
                                          'y', to_jsonb(4400::double precision));

  r := public.location_update('zoneupd-drawnstays-locmove-b', jsonb_build_object(
         'target_id', v_locB::text, 'expected', v_exp, 'fields', v_fields));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE UPDATE PROOF FAIL [PROOF 12(e)]: the control location move was rejected: %', r;
  end if;
  if (select ST_AsBinary(boundary) from public.danger_zones where id = v_zB) is not distinct from v_wkb_b then
    raise exception 'ZONE UPDATE PROOF FAIL [PROOF 12(e)]: a genuinely seeded source=circle zone did NOT follow its location — the derived writer has been disabled instead of made disjoint, re-opening the 0289 split-brain 0296 closed';
  end if;
  if (select source from public.danger_zones where id = v_zB) <> 'circle' then
    raise exception 'ZONE UPDATE PROOF FAIL [PROOF 12(e)]: a re-derivation changed source — only zone_update may claim a row for the authored writer';
  end if;
  -- it followed the location it actually has now: every vertex within 0237's band of the NEW centre.
  if exists (
        select 1
          from public.danger_zones dz
          join public.locations l on l.id = dz.location_id
          cross join lateral ST_DumpPoints(dz.boundary) p
         where dz.id = v_zB
           and ST_Distance(p.geom, ST_MakePoint(l.x, l.y)) > l.territory_radius::double precision * 1.5 * 1.18 + 1e-6) then
    raise exception 'ZONE UPDATE PROOF FAIL [PROOF 12(e)]: the re-derived seeded zone is not centred on its location''s NEW coordinate';
  end if;

  -- restore the posture the deployed chain ships (the txn rolls back anyway; this keeps any future
  -- case reading the REAL chain value rather than this case's pin).
  insert into public.game_config(key, value, description)
    values ('seeded_zone_edit_enabled', to_jsonb(v_ambient), 'proof-txn-local')
    on conflict (key) do update set value = to_jsonb(v_ambient);

  raise notice 'PUBLISH_ZONE_UPD_PASS_DRAWN_STAYS_DRAWN';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-ZONE-UPDATE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (the pirate_intercept_enabled flip included).
