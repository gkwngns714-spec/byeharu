-- WORLD EDITOR PUBLISH-LOCATION-CREATE — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0252 (20260618000252_worldeditor_publish_location_create.sql) after the FULL
-- chain is applied by `supabase start`: the LAST-gap CREATE command location_create ACCEPTS the
-- owner (row inserted into the chosen zone across all 12 fields incl. a null territory_radius +
-- audited with after_snapshot and a NULL before_snapshot), REJECTS the non-owner and the anonymous
-- caller with zero side effects, is idempotent on request_id (exactly one insert, one audit row,
-- identical replayed result), re-validates the fields server-side (validation_failed with the
-- locationValidation error vocabulary; a bad enum is a TYPED detail, never a raw check_violation),
-- rejects a missing / non-uuid / nonexistent zone_id as a TYPED validation_failed {invalid_zone}
-- (never a raw not-null or foreign_key violation), surfaces a (zone_id,name) collision as a typed
-- conflict/duplicate_name via the unique(zone_id,name) authority, leaves get_world_map + the
-- locations SELECT posture intact, and leaves the 0239 pirate-zone lockdown intact.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE (the
-- real byeharu owner does not exist in a disposable DB). NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER, a synthetic NON-OWNER, and ONE existing zone to create into ───────
create temp table pubids(k text primary key, v uuid) on commit drop;
insert into pubids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'publoccre.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from pubids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from pubids where k = 'owner';

-- the EXISTING zone the create targets (the seeded chain provides zones; a create needs a real
-- zone_id — the very thing this command validates). One pre-existing neighbor row proves the
-- (zone_id,name) conflict. Seeded chain rows are untouched.
create temp table pubzone(k text primary key, v uuid) on commit drop;

do $$
declare v_zone uuid;
begin
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'LOC CREATE PROOF SETUP FAIL: the seeded chain has no zones to create a location in';
  end if;
  insert into pubzone values ('zone', v_zone);
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values
      (v_zone, 'Loc Create Proof Neighbor', 'safe_zone', 'none', 900, -1900, 1, 0, 0, true, null, 'active');
end $$;

-- ── PROOF 1 — OWNER CREATE is APPLIED: row inserted into the chosen zone, all fields written ───────
do $$
declare v_owner uuid; v_zone uuid; r jsonb; v_row record; v_id uuid;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_zone from pubzone where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_create('loccre-owner-req-1', jsonb_build_object(
         'source_revision', 'loccre-proof-rev-1',
         'fields', jsonb_build_object(
           'zone_id', v_zone::text,
           'name','Loc Create Proof Alpha','location_type','rally_point','activity_type','rally',
           'x',1234,'y',-4321,'reward_tier',2,'base_difficulty',1.5,'min_power_required',7,
           'is_public',false,'territory_radius',33,'status','active')));
  if (r->>'ok')::boolean is not true then
    raise exception 'LOC CREATE PROOF FAIL: owner create not ok: %', r;
  end if;
  if (r->'result'->>'created') <> 'true' or (r->'result'->>'name') <> 'Loc Create Proof Alpha' then
    raise exception 'LOC CREATE PROOF FAIL: owner create result malformed: %', r;
  end if;
  v_id := (r->'result'->>'id')::uuid;
  select * into v_row from public.locations where id = v_id;
  if not found then
    raise exception 'LOC CREATE PROOF FAIL: the created row does not exist';
  end if;
  if v_row.zone_id <> v_zone or v_row.name <> 'Loc Create Proof Alpha'
     or v_row.location_type <> 'rally_point' or v_row.activity_type <> 'rally'
     or v_row.x <> 1234 or v_row.y <> -4321 or v_row.reward_tier <> 2
     or v_row.base_difficulty <> 1.5 or v_row.min_power_required <> 7
     or v_row.is_public is not false or v_row.territory_radius is distinct from 33
     or v_row.status <> 'active' then
    raise exception 'LOC CREATE PROOF FAIL: a field did not apply (row: %, %, %, %, %, %, %, %, %, %, %, %)',
      v_row.zone_id, v_row.name, v_row.location_type, v_row.activity_type, v_row.x, v_row.y,
      v_row.reward_tier, v_row.base_difficulty, v_row.min_power_required, v_row.is_public,
      v_row.territory_radius, v_row.status;
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_OWNER_CREATES';
end $$;

-- ── PROOF 2 — NON-OWNER authenticated user is REJECTED (not_authorized), zero side effects ─────────
do $$
declare v_no uuid; v_zone uuid; r jsonb; n int;
begin
  select v into v_no from pubids where k = 'nonowner';
  select v into v_zone from pubzone where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.location_create('loccre-nonowner-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'zone_id', v_zone::text,
           'name','Hijacked Create','location_type','safe_zone','activity_type','none',
           'x',0,'y',0,'reward_tier',0,'base_difficulty',0,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'LOC CREATE PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  select count(*) into n from public.locations where name = 'Hijacked Create';
  if n <> 0 then
    raise exception 'LOC CREATE PROOF FAIL: a rejected non-owner create inserted % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'loccre-nonowner-req-1';
  if n <> 0 then
    raise exception 'LOC CREATE PROOF FAIL: a rejected non-owner create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 3 — ANONYMOUS caller is REJECTED (not_authenticated), zero side effects ──────────────────
do $$
declare r jsonb; n int;
begin
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.location_create('loccre-anon-req-1', jsonb_build_object(
         'fields', jsonb_build_object('name','Anon Create')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'LOC CREATE PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  select count(*) into n from public.locations where name = 'Anon Create';
  if n <> 0 then
    raise exception 'LOC CREATE PROOF FAIL: an anonymous create inserted % row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 4 — repeated request_id is IDEMPOTENT (one insert; one audit row; identical replay) ──────
do $$
declare v_owner uuid; v_zone uuid; r1 jsonb; r2 jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_zone from pubzone where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r1 := public.location_create('loccre-idem-req-1', jsonb_build_object(
          'fields', jsonb_build_object(
            'zone_id', v_zone::text,
            'name','Loc Create Proof Idem','location_type','safe_zone','activity_type','none',
            'x',10,'y',20,'reward_tier',0,'base_difficulty',0,'min_power_required',0,
            'is_public',true,'territory_radius',null,'status','active')));
  -- same request_id, DIFFERENT name — must NOT re-apply, must return the prior result.
  r2 := public.location_create('loccre-idem-req-1', jsonb_build_object(
          'fields', jsonb_build_object(
            'zone_id', v_zone::text,
            'name','Loc Create Proof Idem SECOND','location_type','safe_zone','activity_type','none',
            'x',11,'y',21,'reward_tier',0,'base_difficulty',0,'min_power_required',0,
            'is_public',true,'territory_radius',null,'status','active')));
  if (r1->>'ok')::boolean is not true then
    raise exception 'LOC CREATE PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'LOC CREATE PROOF FAIL: second call was not an idempotent replay: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'LOC CREATE PROOF FAIL: replay result differs from the original (% vs %)', r2->'result', r1->'result';
  end if;
  select count(*) into n from public.locations where name like 'Loc Create Proof Idem%';
  if n <> 1 then
    raise exception 'LOC CREATE PROOF FAIL: idempotent request inserted % row(s) (expected exactly 1)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'loccre-idem-req-1';
  if n <> 1 then
    raise exception 'LOC CREATE PROOF FAIL: idempotent request produced % audit rows (expected exactly 1)', n;
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 5 — BAD fields are REJECTED server-side (validation_failed + details; bad enum is a
--    TYPED detail, never a raw check_violation; no row inserted) ────────────────────────────────────
do $$
declare v_owner uuid; v_zone uuid; r jsonb; n int; v_codes text[];
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_zone from pubzone where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- blank name + bad enums + out-of-envelope x + non-numeric y + fractional reward_tier + negative
  -- difficulty + negative min power + zero territory radius + non-boolean is_public — ALL collected.
  r := public.location_create('loccre-badpayload-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'zone_id', v_zone::text,
           'name','   ','location_type','volcano_lair','activity_type','interpretive_dance',
           'x',99999,'y','not-a-number','reward_tier',2.5,'base_difficulty',-1,
           'min_power_required',-5,'is_public','yes','territory_radius',0,'status','vaporized')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'LOC CREATE PROOF FAIL: bad fields were not rejected as validation_failed: %', r;
  end if;
  if jsonb_typeof(r->'details') <> 'array' or jsonb_array_length(r->'details') < 9 then
    raise exception 'LOC CREATE PROOF FAIL: validation_failed details incomplete (expected >=9 issues): %', r->'details';
  end if;
  select array_agg(d->>'code') into v_codes from jsonb_array_elements(r->'details') d;
  if not (v_codes @> array['name_required','invalid_location_type','invalid_activity_type','invalid_status']) then
    raise exception 'LOC CREATE PROOF FAIL: enum/name rejection details incomplete (codes %): %', v_codes, r->'details';
  end if;
  select count(*) into n from public.locations where location_type = 'volcano_lair' or status = 'vaporized';
  if n <> 0 then
    raise exception 'LOC CREATE PROOF FAIL: a bad enum reached the table (% row(s))', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'loccre-badpayload-req-1';
  if n <> 0 then
    raise exception 'LOC CREATE PROOF FAIL: a validation-rejected create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_VALIDATION_REJECTED';
end $$;

-- ── PROOF 6 — a MISSING / NON-UUID / NONEXISTENT zone_id is a TYPED validation_failed
--    {invalid_zone} (never a raw not-null or foreign_key violation); no row inserted ───────────────
do $$
declare v_owner uuid; r jsonb; n int; v_good jsonb;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  v_good := jsonb_build_object(
    'name','Loc Create Proof ZoneCase','location_type','safe_zone','activity_type','none',
    'x',5,'y',5,'reward_tier',0,'base_difficulty',0,'min_power_required',0,
    'is_public',true,'territory_radius',null,'status','active');

  -- (a) zone_id MISSING entirely.
  r := public.location_create('loccre-nozone-req-1', jsonb_build_object('fields', v_good));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'invalid_zone' and d->>'field' = 'zone_id') then
    raise exception 'LOC CREATE PROOF FAIL: missing zone_id was not a typed invalid_zone: %', r;
  end if;

  -- (b) zone_id NOT a uuid.
  r := public.location_create('loccre-baduuid-req-1', jsonb_build_object(
         'fields', v_good || jsonb_build_object('zone_id', 'not-a-uuid')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'invalid_zone') then
    raise exception 'LOC CREATE PROOF FAIL: non-uuid zone_id was not a typed invalid_zone: %', r;
  end if;

  -- (c) zone_id a well-formed uuid naming NO existing zone.
  r := public.location_create('loccre-ghostzone-req-1', jsonb_build_object(
         'fields', v_good || jsonb_build_object('zone_id', gen_random_uuid()::text)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'invalid_zone') then
    raise exception 'LOC CREATE PROOF FAIL: nonexistent zone_id was not a typed invalid_zone: %', r;
  end if;

  select count(*) into n from public.locations where name = 'Loc Create Proof ZoneCase';
  if n <> 0 then
    raise exception 'LOC CREATE PROOF FAIL: an invalid-zone create inserted % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit
   where request_id in ('loccre-nozone-req-1','loccre-baduuid-req-1','loccre-ghostzone-req-1');
  if n <> 0 then
    raise exception 'LOC CREATE PROOF FAIL: an invalid-zone create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_INVALID_ZONE_REJECTED';
end $$;

-- ── PROOF 7 — a (zone_id,name) collision is a typed conflict (unique(zone_id,name) authority) ──────
do $$
declare v_owner uuid; v_zone uuid; r jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_zone from pubzone where k = 'zone';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- create with the pre-existing neighbor's name in the SAME zone: the table constraint must decide
  -- (the server never pre-checks — a pre-check would be a racy second copy).
  r := public.location_create('loccre-conflict-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'zone_id', v_zone::text,
           'name','Loc Create Proof Neighbor','location_type','safe_zone','activity_type','none',
           'x',1,'y',2,'reward_tier',0,'base_difficulty',0,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'conflict' then
    raise exception 'LOC CREATE PROOF FAIL: zone-scoped name collision was not a typed conflict: %', r;
  end if;
  if (r->'details'->0->>'code') <> 'duplicate_name' or (r->'details'->0->>'field') <> 'name' then
    raise exception 'LOC CREATE PROOF FAIL: conflict details malformed: %', r->'details';
  end if;
  select count(*) into n from public.locations where name = 'Loc Create Proof Neighbor';
  if n <> 1 then
    raise exception 'LOC CREATE PROOF FAIL: the conflict left % row(s) named Neighbor (expected the 1 fixture)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'loccre-conflict-req-1';
  if n <> 0 then
    raise exception 'LOC CREATE PROOF FAIL: a conflict-rejected create wrote % audit row(s) — the sub-block did not roll back atomically', n;
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_CONFLICT';
end $$;

-- ── PROOF 8 — the audit row: after_snapshot mirrors the created row; before_snapshot is NULL ───────
do $$
declare v_before jsonb; v_after jsonb; v_rev text; v_zone uuid; v_type text; v_tid text;
begin
  select v into v_zone from pubzone where k = 'zone';
  select before_snapshot, after_snapshot, source_revision, command_type, target_id
    into v_before, v_after, v_rev, v_type, v_tid
    from public.world_editor_audit where request_id = 'loccre-owner-req-1';
  if v_type is distinct from 'location_create' then
    raise exception 'LOC CREATE PROOF FAIL: audit command_type wrong (got %)', v_type;
  end if;
  if v_before is not null then
    raise exception 'LOC CREATE PROOF FAIL: before_snapshot must be NULL on a create: %', v_before;
  end if;
  if v_after is null or jsonb_typeof(v_after) <> 'object' then
    raise exception 'LOC CREATE PROOF FAIL: after_snapshot is not a jsonb object: %', v_after;
  end if;
  if (v_after->>'name') <> 'Loc Create Proof Alpha' or (v_after->>'zone_id') <> v_zone::text
     or (v_after->>'x')::numeric <> 1234 or (v_after->>'territory_radius')::numeric <> 33
     or (v_after->>'location_type') <> 'rally_point' then
    raise exception 'LOC CREATE PROOF FAIL: after_snapshot does not mirror the created row: %', v_after;
  end if;
  if v_tid is distinct from (v_after->>'id') then
    raise exception 'LOC CREATE PROOF FAIL: audit target_id (%) disagrees with the created id (%)', v_tid, v_after->>'id';
  end if;
  if v_rev is distinct from 'loccre-proof-rev-1' then
    raise exception 'LOC CREATE PROOF FAIL: audit source_revision not recorded (got %)', v_rev;
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_AUDIT_SNAPSHOT';
end $$;

-- ── PROOF 9 — the 0239 pirate-zone lockdown is INTACT (this slice restored NO write privilege) ─────
do $$
begin
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'LOC CREATE PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_ZONE_LOCKDOWN_INTACT';
end $$;

-- ── PROOF 10 — the world READ is intact: get_world_map callable, locations SELECT posture kept ─────
do $$
declare r jsonb;
begin
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception 'LOC CREATE PROOF FAIL: a client role lost EXECUTE on get_world_map()';
  end if;
  if not has_table_privilege('anon', 'public.locations', 'SELECT')
     or not has_table_privilege('authenticated', 'public.locations', 'SELECT') then
    raise exception 'LOC CREATE PROOF FAIL: a client role lost SELECT on locations — the 0252 re-assert over-reached';
  end if;
  if has_table_privilege('anon', 'public.locations', 'INSERT')
     or has_table_privilege('anon', 'public.locations', 'UPDATE')
     or has_table_privilege('anon', 'public.locations', 'DELETE')
     or has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.locations', 'DELETE') then
    raise exception 'LOC CREATE PROOF FAIL: a client role holds a locations WRITE grant — the narrowing did not hold';
  end if;
  r := public.get_world_map();
  if jsonb_typeof(r) <> 'object' or jsonb_typeof(r->'sectors') <> 'array' then
    raise exception 'LOC CREATE PROOF FAIL: get_world_map() no longer returns the sectors envelope: %', r;
  end if;
  raise notice 'PUBLISH_LOC_CREATE_PASS_GET_WORLD_MAP_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-LOCATION-CREATE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
