-- WORLD EDITOR PUBLISH-LOCATION-UPDATE — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0249 (20260618000249_worldeditor_publish_location_update.sql) after the FULL
-- chain is applied by `supabase start`: the THIRD-domain UPDATE command location_update ACCEPTS the
-- owner against a matching `expected` snapshot (row updated across all 11 draft fields incl. a
-- null→value territory_radius write + audited with BOTH before_snapshot AND after_snapshot),
-- REJECTS the non-owner and the anonymous caller with zero side effects, is idempotent on
-- request_id (exactly one apply, one audit row, identical replayed result), REJECTS a stale
-- `expected` (OPTIMISTIC CONCURRENCY → stale_revision + source_changed per drifted field, nothing
-- written), re-validates the new fields server-side (validation_failed with the locationValidation
-- error vocabulary; a bad enum is a TYPED detail, never a raw check_violation), returns a typed
-- not_found/source_missing for a vanished target (and invalid_request for a non-uuid target),
-- surfaces a zone-scoped rename collision as a typed conflict/duplicate_name via the
-- unique(zone_id,name) authority, leaves get_world_map + the locations SELECT posture intact, and
-- leaves the 0239 pirate-zone lockdown intact.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE (the
-- real byeharu owner does not exist in a disposable DB). NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER, a synthetic NON-OWNER, and TWO live locations in ONE seeded zone ──
create temp table pubids(k text primary key, v uuid) on commit drop;
insert into pubids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'publocupd.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from pubids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from pubids where k = 'owner';

-- the live rows an edit draft "forked from", inserted as superuser into an EXISTING seeded zone
-- (locations has no client write path; unique(zone_id,name) needs a real zone_id). The neighbor row
-- exists only to prove the zone-scoped rename conflict. Seeded chain rows are untouched.
create temp table publoc(k text primary key, v uuid) on commit drop;

do $$
declare v_zone uuid; v_a uuid; v_b uuid;
begin
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'LOC UPD PROOF SETUP FAIL: the seeded chain has no zones to attach a location to';
  end if;
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values
      (v_zone, 'Loc Upd Proof Origin', 'safe_zone', 'none', 1000, -2000, 1, 0, 0, true, null, 'active')
    returning id into v_a;
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values
      (v_zone, 'Loc Upd Proof Neighbor', 'safe_zone', 'none', 900, -1900, 1, 0, 0, true, null, 'active')
    returning id into v_b;
  insert into publoc values ('target', v_a), ('neighbor', v_b);
end $$;

-- ── PROOF 1 — OWNER UPDATE is APPLIED: all 11 fields written (incl. territory null→42), audited ────
do $$
declare v_owner uuid; v_id uuid; r jsonb; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_id from publoc where k = 'target';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_update('locupd-owner-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'source_revision', 'locupd-proof-rev-1',
         'expected', jsonb_build_object(
           'name','Loc Upd Proof Origin','location_type','safe_zone','activity_type','none',
           'x',1000,'y',-2000,'reward_tier',1,'base_difficulty',0,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','active'),
         'fields', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
           'x',1111,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',42,'status','active')));
  if (r->>'ok')::boolean is not true then
    raise exception 'LOC UPD PROOF FAIL: owner update not ok: %', r;
  end if;
  if (r->'result'->>'updated') <> 'true' or (r->'result'->>'name') <> 'Loc Upd Proof Renamed'
     or (r->'result'->>'id') <> v_id::text then
    raise exception 'LOC UPD PROOF FAIL: owner update result malformed: %', r;
  end if;
  select * into v_row from public.locations where id = v_id;
  if v_row.name <> 'Loc Upd Proof Renamed' or v_row.location_type <> 'rally_point'
     or v_row.activity_type <> 'rally' or v_row.x <> 1111 or v_row.y <> -2222
     or v_row.reward_tier <> 3 or v_row.base_difficulty <> 2.5 or v_row.min_power_required <> 10
     or v_row.is_public is not false or v_row.territory_radius is distinct from 42
     or v_row.status <> 'active' then
    raise exception 'LOC UPD PROOF FAIL: a field did not apply (row now: %, %, %, %, %, %, %, %, %, %, %)',
      v_row.name, v_row.location_type, v_row.activity_type, v_row.x, v_row.y, v_row.reward_tier,
      v_row.base_difficulty, v_row.min_power_required, v_row.is_public, v_row.territory_radius, v_row.status;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_OWNER_UPDATES';
end $$;

-- ── PROOF 2 — NON-OWNER authenticated user is REJECTED (not_authorized), zero side effects ─────────
do $$
declare v_no uuid; v_id uuid; r jsonb; n int;
begin
  select v into v_no from pubids where k = 'nonowner';
  select v into v_id from publoc where k = 'target';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.location_update('locupd-nonowner-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
           'x',1111,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',42,'status','active'),
         'fields', jsonb_build_object(
           'name','Hijacked Location','location_type','safe_zone','activity_type','none',
           'x',0,'y',0,'reward_tier',0,'base_difficulty',0,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'LOC UPD PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  select count(*) into n from public.locations where name = 'Hijacked Location';
  if n <> 0 then
    raise exception 'LOC UPD PROOF FAIL: a rejected non-owner update changed % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'locupd-nonowner-req-1';
  if n <> 0 then
    raise exception 'LOC UPD PROOF FAIL: a rejected non-owner update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 3 — ANONYMOUS caller is REJECTED (not_authenticated), zero side effects ──────────────────
do $$
declare v_id uuid; r jsonb; n int;
begin
  select v into v_id from publoc where k = 'target';
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.location_update('locupd-anon-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','Loc Upd Proof Renamed'),
         'fields',   jsonb_build_object('name','Anon Location')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'LOC UPD PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  select count(*) into n from public.locations where name = 'Anon Location';
  if n <> 0 then
    raise exception 'LOC UPD PROOF FAIL: an anonymous update changed % row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 4 — repeated request_id is IDEMPOTENT (one apply; one audit row; identical replay) ───────
do $$
declare v_owner uuid; v_id uuid; r1 jsonb; r2 jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_id from publoc where k = 'target';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r1 := public.location_update('locupd-idem-req-1', jsonb_build_object(
          'target_id', v_id::text,
          'expected', jsonb_build_object(
            'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
            'x',1111,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
            'is_public',false,'territory_radius',42,'status','active'),
          'fields', jsonb_build_object(
            'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
            'x',1500,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
            'is_public',false,'territory_radius',42,'status','active')));
  -- same request_id, DIFFERENT fields — must NOT re-apply, must return the prior result.
  r2 := public.location_update('locupd-idem-req-1', jsonb_build_object(
          'target_id', v_id::text,
          'expected', jsonb_build_object(
            'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
            'x',1500,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
            'is_public',false,'territory_radius',42,'status','active'),
          'fields', jsonb_build_object(
            'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
            'x',1600,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
            'is_public',false,'territory_radius',42,'status','active')));
  if (r1->>'ok')::boolean is not true then
    raise exception 'LOC UPD PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'LOC UPD PROOF FAIL: second call was not an idempotent replay: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'LOC UPD PROOF FAIL: replay result differs from the original (% vs %)', r2->'result', r1->'result';
  end if;
  select * into v_row from public.locations where id = v_id;
  if v_row.x <> 1500 then
    raise exception 'LOC UPD PROOF FAIL: replay re-applied (x = %, expected the FIRST apply''s 1500)', v_row.x;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'locupd-idem-req-1';
  if n <> 1 then
    raise exception 'LOC UPD PROOF FAIL: idempotent request produced % audit rows (expected exactly 1)', n;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 5 — OPTIMISTIC CONCURRENCY: a stale `expected` is REJECTED (stale_revision), no write ────
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_id from publoc where k = 'target';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- live row is now (x 1500, territory_radius 42): an `expected` carrying the OLD x (1111) no
  -- longer matches — the fork is stale and must be rejected field-precisely.
  r := public.location_update('locupd-stale-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
           'x',1111,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',42,'status','active'),
         'fields', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
           'x',1700,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',42,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision' then
    raise exception 'LOC UPD PROOF FAIL: stale expected was not rejected as stale_revision: %', r;
  end if;
  if (r->'details'->0->>'code') <> 'source_changed' or (r->'details'->0->>'field') <> 'x' then
    raise exception 'LOC UPD PROOF FAIL: stale_revision details did not name the drifted field: %', r->'details';
  end if;
  -- the null-safe territory compare: an expected NULL radius against the live 42 is ALSO drift.
  r := public.location_update('locupd-stale-req-2', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
           'x',1500,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',null,'status','active'),
         'fields', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
           'x',1700,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',null,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or (r->'details'->0->>'field') <> 'territory_radius' then
    raise exception 'LOC UPD PROOF FAIL: null-vs-42 territory_radius was not stale_revision/territory_radius: %', r;
  end if;
  select * into v_row from public.locations where id = v_id;
  if v_row.x <> 1500 then
    raise exception 'LOC UPD PROOF FAIL: a stale-rejected update WROTE (x = %)', v_row.x;
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('locupd-stale-req-1','locupd-stale-req-2');
  if n <> 0 then
    raise exception 'LOC UPD PROOF FAIL: a stale-rejected update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_STALE_REVISION_REJECTED';
end $$;

-- ── PROOF 6 — BAD new fields are REJECTED server-side (validation_failed + details; no write) ──────
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_id from publoc where k = 'target';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- `expected` MATCHES the live row (so this reaches validation); the NEW fields are all bad:
  -- blank name + out-of-envelope x + non-numeric y + fractional reward_tier + negative difficulty
  -- + negative min power + zero territory radius + non-boolean is_public (enums stay valid — the
  -- typed-enum rejection is PROOF 7's job).
  r := public.location_update('locupd-badpayload-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
           'x',1500,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',42,'status','active'),
         'fields', jsonb_build_object(
           'name','   ','location_type','rally_point','activity_type','rally',
           'x',99999,'y','not-a-number','reward_tier',2.5,'base_difficulty',-1,
           'min_power_required',-5,'is_public','yes','territory_radius',0,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'LOC UPD PROOF FAIL: bad fields were not rejected as validation_failed: %', r;
  end if;
  if jsonb_typeof(r->'details') <> 'array' or jsonb_array_length(r->'details') < 7 then
    raise exception 'LOC UPD PROOF FAIL: validation_failed details incomplete (expected >=7 issues): %', r->'details';
  end if;
  select * into v_row from public.locations where id = v_id;
  if v_row.name <> 'Loc Upd Proof Renamed' or v_row.x <> 1500 then
    raise exception 'LOC UPD PROOF FAIL: a validation-rejected update changed the row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'locupd-badpayload-req-1';
  if n <> 0 then
    raise exception 'LOC UPD PROOF FAIL: a validation-rejected update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_VALIDATION_REJECTED';
end $$;

-- ── PROOF 7 — a BAD ENUM is a TYPED validation detail (never a raw check_violation), no write ──────
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int; v_codes text[];
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_id from publoc where k = 'target';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_update('locupd-badenum-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
           'x',1500,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',42,'status','active'),
         'fields', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','volcano_lair','activity_type','interpretive_dance',
           'x',1500,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',42,'status','vaporized')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'LOC UPD PROOF FAIL: bad enums were not rejected as validation_failed: %', r;
  end if;
  select array_agg(d->>'code') into v_codes from jsonb_array_elements(r->'details') d;
  if not (v_codes @> array['invalid_location_type','invalid_activity_type','invalid_status']) then
    raise exception 'LOC UPD PROOF FAIL: enum rejection details incomplete (codes %): %', v_codes, r->'details';
  end if;
  select count(*) into n from public.locations where location_type = 'volcano_lair' or status = 'vaporized';
  if n <> 0 then
    raise exception 'LOC UPD PROOF FAIL: a bad enum reached the table (% row(s))', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'locupd-badenum-req-1';
  if n <> 0 then
    raise exception 'LOC UPD PROOF FAIL: an enum-rejected update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_INVALID_ENUM_REJECTED';
end $$;

-- ── PROOF 8 — a VANISHED target is a typed not_found (source_missing); a NON-uuid target is a
--    typed invalid_request. Zero side effects either way. ───────────────────────────────────────────
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_update('locupd-notfound-req-1', jsonb_build_object(
         'target_id', gen_random_uuid()::text,
         'expected', jsonb_build_object('name','No Such Location'),
         'fields',   jsonb_build_object(
           'name','Whatever','location_type','safe_zone','activity_type','none',
           'x',0,'y',0,'reward_tier',0,'base_difficulty',0,'min_power_required',0,
           'is_public',true,'territory_radius',null,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_found' then
    raise exception 'LOC UPD PROOF FAIL: vanished target was not rejected as not_found: %', r;
  end if;
  if (r->'details'->0->>'code') <> 'source_missing' then
    raise exception 'LOC UPD PROOF FAIL: not_found details malformed: %', r->'details';
  end if;
  r := public.location_update('locupd-badtarget-req-1', jsonb_build_object(
         'target_id', 'not-a-uuid',
         'expected', jsonb_build_object('name','X'),
         'fields',   jsonb_build_object('name','X')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'invalid_request' then
    raise exception 'LOC UPD PROOF FAIL: non-uuid target was not rejected as invalid_request: %', r;
  end if;
  select count(*) into n from public.world_editor_audit
   where request_id in ('locupd-notfound-req-1','locupd-badtarget-req-1');
  if n <> 0 then
    raise exception 'LOC UPD PROOF FAIL: a not_found/invalid_request call wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_NOT_FOUND';
end $$;

-- ── PROOF 9 — a zone-scoped RENAME collision is a typed conflict (unique(zone_id,name) authority) ──
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  select v into v_id from publoc where k = 'target';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- rename the target to its same-zone neighbor's name: the table constraint must decide (the
  -- server never pre-checks — the client cannot even see zone_id).
  r := public.location_update('locupd-conflict-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object(
           'name','Loc Upd Proof Renamed','location_type','rally_point','activity_type','rally',
           'x',1500,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',42,'status','active'),
         'fields', jsonb_build_object(
           'name','Loc Upd Proof Neighbor','location_type','rally_point','activity_type','rally',
           'x',1500,'y',-2222,'reward_tier',3,'base_difficulty',2.5,'min_power_required',10,
           'is_public',false,'territory_radius',42,'status','active')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'conflict' then
    raise exception 'LOC UPD PROOF FAIL: zone-scoped rename collision was not a typed conflict: %', r;
  end if;
  if (r->'details'->0->>'code') <> 'duplicate_name' or (r->'details'->0->>'field') <> 'name' then
    raise exception 'LOC UPD PROOF FAIL: conflict details malformed: %', r->'details';
  end if;
  select * into v_row from public.locations where id = v_id;
  if v_row.name <> 'Loc Upd Proof Renamed' then
    raise exception 'LOC UPD PROOF FAIL: a conflict-rejected rename left the row renamed (%)', v_row.name;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'locupd-conflict-req-1';
  if n <> 0 then
    raise exception 'LOC UPD PROOF FAIL: a conflict-rejected update wrote % audit row(s) — the sub-block did not roll back atomically', n;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_CONFLICT_DUPLICATE_NAME';
end $$;

-- ── PROOF 10 — the audit row carries BOTH before_snapshot AND after_snapshot (an update, not a create)
do $$
declare v_before jsonb; v_after jsonb; v_rev text;
begin
  select before_snapshot, after_snapshot, source_revision into v_before, v_after, v_rev
    from public.world_editor_audit where request_id = 'locupd-owner-req-1';
  if v_before is null or jsonb_typeof(v_before) <> 'object' then
    raise exception 'LOC UPD PROOF FAIL: before_snapshot is not a jsonb object: %', v_before;
  end if;
  if v_after is null or jsonb_typeof(v_after) <> 'object' then
    raise exception 'LOC UPD PROOF FAIL: after_snapshot is not a jsonb object: %', v_after;
  end if;
  if (v_before->>'name') <> 'Loc Upd Proof Origin' or (v_before->>'x')::numeric <> 1000
     or jsonb_typeof(v_before->'territory_radius') <> 'null' then
    raise exception 'LOC UPD PROOF FAIL: before_snapshot does not mirror the pre-update row: %', v_before;
  end if;
  if (v_after->>'name') <> 'Loc Upd Proof Renamed' or (v_after->>'x')::numeric <> 1111
     or (v_after->>'territory_radius')::numeric <> 42 or (v_after->>'location_type') <> 'rally_point' then
    raise exception 'LOC UPD PROOF FAIL: after_snapshot does not mirror the post-update row: %', v_after;
  end if;
  if (v_before->>'id') <> (v_after->>'id') then
    raise exception 'LOC UPD PROOF FAIL: before/after snapshots disagree on the row id (% vs %)', v_before->>'id', v_after->>'id';
  end if;
  -- zone_id is snapshotted but NEVER changed by an update (not a draft field).
  if (v_before->>'zone_id') <> (v_after->>'zone_id') then
    raise exception 'LOC UPD PROOF FAIL: the update MOVED the location between zones (% vs %)', v_before->>'zone_id', v_after->>'zone_id';
  end if;
  if v_rev is distinct from 'locupd-proof-rev-1' then
    raise exception 'LOC UPD PROOF FAIL: audit source_revision not recorded (got %)', v_rev;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_AUDIT_BEFORE_AFTER';
end $$;

-- ── PROOF 11 — the 0239 pirate-zone lockdown is INTACT (this slice restored NO write privilege) ────
do $$
begin
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'LOC UPD PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_ZONE_LOCKDOWN_INTACT';
end $$;

-- ── PROOF 12 — the world READ is intact: get_world_map callable, locations SELECT posture kept ─────
do $$
declare r jsonb;
begin
  if not has_function_privilege('anon', 'public.get_world_map()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_world_map()', 'execute') then
    raise exception 'LOC UPD PROOF FAIL: a client role lost EXECUTE on get_world_map()';
  end if;
  if not has_table_privilege('anon', 'public.locations', 'SELECT')
     or not has_table_privilege('authenticated', 'public.locations', 'SELECT') then
    raise exception 'LOC UPD PROOF FAIL: a client role lost SELECT on locations — the 0249 narrowing over-reached';
  end if;
  if has_table_privilege('anon', 'public.locations', 'INSERT')
     or has_table_privilege('anon', 'public.locations', 'UPDATE')
     or has_table_privilege('anon', 'public.locations', 'DELETE')
     or has_table_privilege('authenticated', 'public.locations', 'INSERT')
     or has_table_privilege('authenticated', 'public.locations', 'UPDATE')
     or has_table_privilege('authenticated', 'public.locations', 'DELETE') then
    raise exception 'LOC UPD PROOF FAIL: a client role holds a locations WRITE grant — the 0249 narrowing did not hold';
  end if;
  r := public.get_world_map();
  if jsonb_typeof(r) <> 'object' or jsonb_typeof(r->'sectors') <> 'array' then
    raise exception 'LOC UPD PROOF FAIL: get_world_map() no longer returns the sectors envelope: %', r;
  end if;
  raise notice 'PUBLISH_LOC_UPD_PASS_GET_WORLD_MAP_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-LOCATION-UPDATE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
