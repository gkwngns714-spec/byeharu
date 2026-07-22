-- WORLD EDITOR PUBLISH-ZONE-SETACTIVE — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0268 (20260618000268_worldeditor_zone_setactive.sql) after the FULL chain is applied
-- by `supabase start`: the zone RE-ACTIVATE command zone_set_active (inactive → active only), the
-- restore-half that COMPLEMENTS the one-way 0255 zone_unpublish. It drives the WHOLE lifecycle end to end
-- — owner CREATE a marked drawn canary (0254), owner UNPUBLISH it (0255 zone_unpublish STILL WORKS →
-- status='inactive' and it leaves get_danger_zones), then across the reactivate surface: REJECT the
-- non-owner (not_authorized) and anonymous (not_authenticated) with zero side effects, REJECT a malformed
-- payload (invalid_request), a vanished target (not_found/source_missing), a drifted draft (stale_revision/
-- source_changed) and a seeded source='circle' zone (validation_failed/protected_zone) — all with NOTHING
-- written; then owner REACTIVATE the canary → the SAME row flips to status='active' with its boundary
-- BYTE-IDENTICAL and id/zone_kind/source/location_id/created_by/created_at preserved, it reappears in
-- get_danger_zones AND the interception predicate at once, exactly ONE zone_set_active audit row exists
-- (before status='inactive', after status='active'), an idempotent replay adds NO second audit and does
-- NOT re-mutate, a NEW request on the now-active zone is validation_failed/already_active, existing zones
-- are untouched, and the danger_zones client-write lockdown + the 0239 pirate-zone lockdown are intact.
--
-- NOTE ON "revision increments exactly once": danger_zones has NO revision column, and now() is constant
-- across a single transaction (transaction_timestamp), so updated_at cannot be observed to advance WITHIN
-- this self-rolling-back proof. The ONE-mutation invariant is therefore proven the observable way: the
-- status flips inactive→active exactly once, exactly ONE zone_set_active audit row records that flip
-- (before/after snapshots), and an idempotent replay produces neither a second audit row nor a second
-- mutation (status stays active; boundary stays byte-identical).
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag kept
-- flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE (the real
-- byeharu owner does not exist in a disposable DB). The pirate_intercept_enabled flip for the read checks
-- is INSIDE the transaction and rolled back with everything else. NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER + NON-OWNER; one active hostile location; one seeded 'circle' zone ──
create temp table pubuids(k text primary key, v uuid) on commit drop;
insert into pubuids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'pubzonereact.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from pubuids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from pubuids where k = 'owner';

-- a live hostile location (a legal zone attach target + the anchor for the seeded circle zone) and a
-- directly-inserted source='circle' zone (the PROTECTED target — zone_create only ever writes 'drawn').
create temp table pubz(k text primary key, v uuid) on commit drop;
do $$
declare v_zone uuid; v_hostile uuid; v_circle uuid;
begin
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'ZONE REACTIVATE PROOF SETUP FAIL: the seeded chain has no zones to host the fixtures';
  end if;
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values
      (v_zone, 'Zone React Proof Den', 'pirate_den', 'hunt_pirates', 800, -800, 1, 1, 0, true, null, 'active')
    returning id into v_hostile;
  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
    values ('Zone React Proof Seed Circle', 'pirate', 'circle', v_hostile,
            ST_Buffer(ST_MakePoint(800, -800), 90, 32), 'active')
    returning id into v_circle;
  insert into pubz values ('hostile', v_hostile), ('circle', v_circle);
end $$;

-- ── PROOF 1 — OWNER CREATES the canary (0254 zone_create): a marked drawn+active standalone zone ────
do $$
declare v_owner uuid; r jsonb; v_row record; v_id uuid;
begin
  select v into v_owner from pubuids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_create('zonereact-create-canary-req-1', jsonb_build_object(
         'source_revision', 'zonereact-create-rev-1',
         'fields', jsonb_build_object(
           'name','CANARY-Zone-React-Proof','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle',
             'center', jsonb_build_object('x', 800, 'y', -800), 'radius', 120))));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: owner canary create not ok: %', r;
  end if;
  v_id := (r->'result'->>'id')::uuid;
  select * into v_row from public.danger_zones where id = v_id;
  if v_row.source <> 'drawn' or v_row.status <> 'active' or v_row.location_id is not null then
    raise exception 'ZONE REACTIVATE PROOF FAIL: canary shape wrong (%, %, %)', v_row.source, v_row.status, v_row.location_id;
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_OWNER_CREATES_CANARY';
end $$;

-- ── PROOF 2 — zone_unpublish STILL WORKS (the unchanged deactivate half): canary → inactive, gone ───
do $$
declare v_owner uuid; v_id uuid; r jsonb; v_status text; v_read jsonb;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-React-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_unpublish('zonereact-unpublish-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-React-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true or (r->'result'->>'status') <> 'inactive' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: zone_unpublish (the deactivate half) did not work: %', r;
  end if;
  select status into v_status from public.danger_zones where id = v_id;
  if v_status <> 'inactive' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: canary is not inactive after unpublish (got %)', v_status;
  end if;
  -- with intercept lit, the inactive canary is ABSENT from the player read (the precondition to reactivate).
  insert into public.game_config(key, value, description)
    values ('pirate_intercept_enabled', 'true'::jsonb, 'proof-txn-local')
    on conflict (key) do update set value = 'true'::jsonb;
  v_read := public.get_danger_zones();
  if exists (select 1 from jsonb_array_elements(v_read) z where (z->>'id')::uuid = v_id) then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the inactive canary still appears in get_danger_zones';
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_UNPUBLISH_WORKS';
end $$;

-- ── PROOF 3 — NON-OWNER reactivate is REJECTED (not_authorized), zero side effects ─────────────────
do $$
declare v_no uuid; v_id uuid; r jsonb; v_status text; n int;
begin
  select v into v_no from pubuids where k = 'nonowner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-React-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.zone_set_active('zonereact-nonowner-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-React-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  select status into v_status from public.danger_zones where id = v_id;
  if v_status <> 'inactive' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a rejected non-owner reactivate changed status to %', v_status;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zonereact-nonowner-req-1';
  if n <> 0 then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a rejected non-owner reactivate wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 4 — ANONYMOUS reactivate is REJECTED (not_authenticated) + anon holds NO execute grant ───
do $$
declare v_id uuid; r jsonb; v_status text;
begin
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-React-Proof';
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.zone_set_active('zonereact-anon-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-React-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  select status into v_status from public.danger_zones where id = v_id;
  if v_status <> 'inactive' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a rejected anon reactivate changed status to %', v_status;
  end if;
  if has_function_privilege('anon', 'public.zone_set_active(text,jsonb)', 'execute') then
    raise exception 'ZONE REACTIVATE PROOF FAIL: anon holds EXECUTE on zone_set_active — must be authenticated-only';
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 5 — MALFORMED payloads fail closed (invalid_request), zero side effects ──────────────────
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-React-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- (a) missing target_id
  r := public.zone_set_active('zonereact-malformed-a', jsonb_build_object(
         'expected', jsonb_build_object('name','CANARY-Zone-React-Proof','source','drawn','location_id', null)));
  if (r->>'error') <> 'invalid_request' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a missing target_id was not invalid_request: %', r;
  end if;
  -- (b) target_id not a uuid
  r := public.zone_set_active('zonereact-malformed-b', jsonb_build_object(
         'target_id', 'not-a-uuid',
         'expected', jsonb_build_object('name','CANARY-Zone-React-Proof','source','drawn','location_id', null)));
  if (r->>'error') <> 'invalid_request' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a non-uuid target_id was not invalid_request: %', r;
  end if;
  -- (c) missing expected snapshot
  r := public.zone_set_active('zonereact-malformed-c', jsonb_build_object('target_id', v_id::text));
  if (r->>'error') <> 'invalid_request' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a missing expected was not invalid_request: %', r;
  end if;
  select count(*) into n from public.world_editor_audit
   where request_id in ('zonereact-malformed-a','zonereact-malformed-b','zonereact-malformed-c');
  if n <> 0 then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a malformed reactivate wrote % audit row(s)', n;
  end if;
  if (select status from public.danger_zones where id = v_id) <> 'inactive' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a malformed reactivate changed the canary status';
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_MALFORMED_REJECTED';
end $$;

-- ── PROOF 6 — a VANISHED target is not_found/source_missing; a DRIFTED draft is stale_revision ──────
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-React-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- (a) not_found — a well-formed uuid naming no zone.
  r := public.zone_set_active('zonereact-notfound-req-1', jsonb_build_object(
         'target_id', gen_random_uuid()::text,
         'expected', jsonb_build_object('name','ghost','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_found'
     or (r->'details'->0->>'code') <> 'source_missing' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a ghost target was not not_found/source_missing: %', r;
  end if;
  -- (b) stale_revision — the expected snapshot's name no longer matches the live canary.
  r := public.zone_set_active('zonereact-stale-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','WRONG NAME','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'source_changed' and d->>'field' = 'name') then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a drifted draft was not stale_revision/source_changed: %', r;
  end if;
  select count(*) into n from public.world_editor_audit
   where request_id in ('zonereact-notfound-req-1','zonereact-stale-req-1');
  if n <> 0 then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a rejected reactivate wrote % audit row(s)', n;
  end if;
  if (select status from public.danger_zones where id = v_id) <> 'inactive' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a rejected reactivate changed the canary status';
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_NOT_FOUND_AND_STALE';
end $$;

-- ── PROOF 7 — a SEEDED source='circle' zone is PROTECTED (validation_failed/protected_zone) ─────────
do $$
declare v_owner uuid; v_circle uuid; r jsonb; v_status text;
begin
  select v into v_owner from pubuids where k = 'owner';
  select v into v_circle from pubz where k = 'circle';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_set_active('zonereact-protected-req-1', jsonb_build_object(
         'target_id', v_circle::text,
         'expected', jsonb_build_object('name','Zone React Proof Seed Circle','source','circle',
                       'location_id', (select location_id from public.danger_zones where id = v_circle))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or (r->'details'->0->>'code') <> 'protected_zone' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a seeded circle zone was not rejected as validation_failed/protected_zone: %', r;
  end if;
  select status into v_status from public.danger_zones where id = v_circle;
  if v_status <> 'active' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the protected circle zone was mutated to %', v_status;
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_PROTECTED_ZONE_REJECTED';
end $$;

-- ── PROOF 8 — OWNER REACTIVATES the canary: ok, SAME id, boundary byte-identical, geometry preserved ─
do $$
declare v_owner uuid; v_id uuid; r jsonb; v_row record;
        v_ewkb_before bytea; v_ewkb_after bytea;
        v_kind_before text; v_source_before text; v_loc_before uuid; v_cby_before uuid; v_cat_before timestamptz;
        v_read jsonb; v_hit boolean;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-React-Proof';
  -- capture the FULL preserved-invariant set of the INACTIVE canary before the reactivate.
  select ST_AsEWKB(boundary), zone_kind, source, location_id, created_by, created_at
    into v_ewkb_before, v_kind_before, v_source_before, v_loc_before, v_cby_before, v_cat_before
    from public.danger_zones where id = v_id;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_set_active('zonereact-owner-req-1', jsonb_build_object(
         'source_revision', 'zonereact-rev-1',
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-React-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE REACTIVATE PROOF FAIL: owner reactivate not ok: %', r;
  end if;
  if (r->'result'->>'set_active') <> 'true' or (r->'result'->>'status') <> 'active'
     or (r->'result'->>'id') <> v_id::text then
    raise exception 'ZONE REACTIVATE PROOF FAIL: owner reactivate result malformed: %', r;
  end if;
  -- the SAME row is now active; boundary BYTE-IDENTICAL; id/kind/source/attach/creator/created_at preserved.
  select ST_AsEWKB(boundary) into v_ewkb_after from public.danger_zones where id = v_id;
  select * into v_row from public.danger_zones where id = v_id;
  if v_row.status <> 'active' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the reactivated canary is not active (got %)', v_row.status;
  end if;
  if v_ewkb_after is distinct from v_ewkb_before then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the reactivate changed the boundary — geometry must be byte-identical';
  end if;
  if v_row.zone_kind is distinct from v_kind_before or v_row.source is distinct from v_source_before
     or v_row.location_id is distinct from v_loc_before or v_row.created_by is distinct from v_cby_before
     or v_row.created_at is distinct from v_cat_before then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the reactivate mutated a preserved invariant (kind/source/attach/creator/created_at)';
  end if;
  -- it REAPPEARS in the player read AND the interception predicate (still lit from PROOF 2).
  v_read := public.get_danger_zones();
  if not exists (select 1 from jsonb_array_elements(v_read) z where (z->>'id')::uuid = v_id) then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the reactivated canary is missing from get_danger_zones';
  end if;
  select exists (
    select 1 from public.danger_zones z
     where z.id = v_id and z.status = 'active'
       and ST_Intersects(z.boundary, ST_MakeLine(ST_MakePoint(700, -800), ST_MakePoint(900, -800)))
  ) into v_hit;
  if not v_hit then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the reactivated canary is not interception-relevant again';
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_OWNER_REACTIVATES';
end $$;

-- ── PROOF 9 — the audit ledger: exactly ONE zone_set_active row; before inactive / after active ─────
do $$
declare v_id uuid; v_before jsonb; v_after jsonb; v_type text; v_ttype text; v_tid text; v_rev text; n int;
begin
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-React-Proof';
  select count(*) into n from public.world_editor_audit where command_type = 'zone_set_active';
  if n <> 1 then
    raise exception 'ZONE REACTIVATE PROOF FAIL: expected exactly one zone_set_active audit row, got %', n;
  end if;
  select before_snapshot, after_snapshot, command_type, target_type, target_id, source_revision
    into v_before, v_after, v_type, v_ttype, v_tid, v_rev
    from public.world_editor_audit where request_id = 'zonereact-owner-req-1';
  if v_type is distinct from 'zone_set_active' or v_ttype is distinct from 'zone' or v_tid is distinct from v_id::text then
    raise exception 'ZONE REACTIVATE PROOF FAIL: reactivate audit command/target wrong (%, %, %)', v_type, v_ttype, v_tid;
  end if;
  if v_before is null or (v_before->>'status') <> 'inactive' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: reactivate before_snapshot must capture the inactive row: %', v_before;
  end if;
  if v_after is null or (v_after->>'status') <> 'active' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: reactivate after_snapshot must capture the active row: %', v_after;
  end if;
  if v_rev is distinct from 'zonereact-rev-1' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: reactivate audit source_revision not recorded (got %)', v_rev;
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_AUDIT';
end $$;

-- ── PROOF 10 — replaying the reactivate request_id is IDEMPOTENT (no second audit; no re-mutation) ──
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int; v_ewkb_before bytea; v_ewkb_after bytea;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-React-Proof';
  select ST_AsEWKB(boundary) into v_ewkb_before from public.danger_zones where id = v_id;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_set_active('zonereact-owner-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-React-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true or (r->>'replayed')::boolean is not true or (r->>'code') <> 'duplicate_request' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the reactivate replay was not idempotent: %', r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zonereact-owner-req-1';
  if n <> 1 then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the reactivate replay produced % audit rows (expected exactly 1)', n;
  end if;
  select ST_AsEWKB(boundary) into v_ewkb_after from public.danger_zones where id = v_id;
  if (select status from public.danger_zones where id = v_id) <> 'active' or v_ewkb_after is distinct from v_ewkb_before then
    raise exception 'ZONE REACTIVATE PROOF FAIL: the reactivate replay re-mutated the row';
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 11 — a NEW request on the now-ACTIVE canary is validation_failed/already_active ───────────
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-React-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_set_active('zonereact-already-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-React-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or (r->'details'->0->>'code') <> 'already_active' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a reactivate of an already-active zone was not validation_failed/already_active: %', r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zonereact-already-req-1';
  if n <> 0 then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a rejected already-active reactivate wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_ALREADY_ACTIVE';
end $$;

-- ── PROOF 12 — existing OTHER zones untouched; danger_zones + 0239 lockdowns intact ────────────────
do $$
declare v_circle uuid; v_status text;
begin
  select v into v_circle from pubz where k = 'circle';
  -- the seeded circle zone (never a legal target) is still active/unchanged.
  select status into v_status from public.danger_zones where id = v_circle;
  if v_status <> 'active' then
    raise exception 'ZONE REACTIVATE PROOF FAIL: an unrelated existing zone changed status to %', v_status;
  end if;
  -- no client role holds a danger_zones write (the definer body is the only write path).
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'INSERT')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'DELETE') then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a client role holds a danger_zones WRITE grant — the lockdown did not hold';
  end if;
  -- SELECT survives (the flag-gated read depends on it).
  if not has_table_privilege('anon', 'public.danger_zones', 'SELECT')
     or not has_table_privilege('authenticated', 'public.danger_zones', 'SELECT') then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a client role LOST SELECT on danger_zones';
  end if;
  -- the 0239 pirate-zone lockdown is intact (no client execute; service_role keeps owner-tooling).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE REACTIVATE PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE REACTIVATE PROOF FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path regressed';
  end if;
  raise notice 'PUBLISH_ZONE_REACT_PASS_EXISTING_UNCHANGED_AND_LOCKDOWN_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-ZONE-SETACTIVE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (the pirate_intercept_enabled flip included).
