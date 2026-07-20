-- WORLD EDITOR PUBLISH-EXPLORATION — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0244 (20260618000244_worldeditor_publish_exploration_create.sql) after the FULL
-- chain is applied by `supabase start`: the FIRST live-world-write command exploration_site_create
-- ACCEPTS the owner (row inserted + audited with after_snapshot), REJECTS the non-owner and the
-- anonymous caller with zero side effects, is idempotent on request_id (exactly one row, one audit
-- row, identical replayed result), re-validates the payload server-side (validation_failed, no row),
-- surfaces the unique natural key as a typed conflict, and leaves the 0239 pirate-zone lockdown
-- intact.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE (the
-- real byeharu owner does not exist in a disposable DB, so 0243's own seed is a 0-row no-op, as
-- intended). NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER and a synthetic NON-OWNER (real auth.users rows for the FK) ────────
create temp table pubids(k text primary key, v uuid) on commit drop;
insert into pubids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'pub.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from pubids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from pubids where k = 'owner';

-- ── PROOF 1 — OWNER CREATE is APPLIED: row inserted, ok:true, audit row with after_snapshot ────────
do $$
declare v_owner uuid; r jsonb; v_id uuid; v_after jsonb; v_rev text;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.exploration_site_create('pub-owner-req-1', jsonb_build_object(
         'source_revision', 'proof-rev-1',
         'fields', jsonb_build_object(
           'name', 'Proof Publish Site Alpha',
           'space_x', 1234, 'space_y', -2345,
           'reward_bundle_json', jsonb_build_object(
             'metal', 25,
             'items', jsonb_build_array(jsonb_build_object('item_id','scan_data','quantity',2))))));
  if (r->>'ok')::boolean is not true then
    raise exception 'PUBLISH PROOF FAIL: owner create not ok: %', r;
  end if;
  if (r->'result'->>'created') <> 'true' or (r->'result'->>'name') <> 'Proof Publish Site Alpha' then
    raise exception 'PUBLISH PROOF FAIL: owner create result malformed: %', r;
  end if;
  select id into v_id from public.exploration_sites where name = 'Proof Publish Site Alpha';
  if v_id is null then
    raise exception 'PUBLISH PROOF FAIL: owner create inserted no exploration_sites row';
  end if;
  if v_id::text <> (r->'result'->>'id') then
    raise exception 'PUBLISH PROOF FAIL: result.id does not match the inserted row (% vs %)', r->'result'->>'id', v_id;
  end if;
  select after_snapshot, source_revision into v_after, v_rev
    from public.world_editor_audit where request_id = 'pub-owner-req-1';
  if v_after is null then
    raise exception 'PUBLISH PROOF FAIL: owner create wrote no audit row / no after_snapshot';
  end if;
  if v_rev is distinct from 'proof-rev-1' then
    raise exception 'PUBLISH PROOF FAIL: audit source_revision not recorded (got %)', v_rev;
  end if;
  raise notice 'PUBLISH_PASS_OWNER_CREATES';
end $$;

-- ── PROOF 2 — NON-OWNER authenticated user is REJECTED (not_authorized), zero side effects ─────────
do $$
declare v_no uuid; r jsonb; n int;
begin
  select v into v_no from pubids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.exploration_site_create('pub-nonowner-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name', 'Intruder Site', 'space_x', 0, 'space_y', 0,
           'reward_bundle_json', jsonb_build_object(
             'items', jsonb_build_array(jsonb_build_object('item_id','scan_data','quantity',1))))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'PUBLISH PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  select count(*) into n from public.exploration_sites where name = 'Intruder Site';
  if n <> 0 then
    raise exception 'PUBLISH PROOF FAIL: a rejected non-owner create inserted % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'pub-nonowner-req-1';
  if n <> 0 then
    raise exception 'PUBLISH PROOF FAIL: a rejected non-owner create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 3 — ANONYMOUS caller is REJECTED (not_authenticated), zero side effects ──────────────────
do $$
declare r jsonb; n int;
begin
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.exploration_site_create('pub-anon-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name', 'Anon Site', 'space_x', 0, 'space_y', 0,
           'reward_bundle_json', jsonb_build_object(
             'items', jsonb_build_array(jsonb_build_object('item_id','scan_data','quantity',1))))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'PUBLISH PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  select count(*) into n from public.exploration_sites where name = 'Anon Site';
  if n <> 0 then
    raise exception 'PUBLISH PROOF FAIL: an anonymous create inserted % row(s)', n;
  end if;
  raise notice 'PUBLISH_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 4 — repeated request_id is IDEMPOTENT (identical result; one row; one audit row) ─────────
do $$
declare v_owner uuid; r1 jsonb; r2 jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r1 := public.exploration_site_create('pub-idem-req-1', jsonb_build_object(
          'fields', jsonb_build_object(
            'name', 'Proof Idempotent Site', 'space_x', 500, 'space_y', 500,
            'reward_bundle_json', jsonb_build_object(
              'items', jsonb_build_array(jsonb_build_object('item_id','anomaly_shard','quantity',1))))));
  -- same request_id, DIFFERENT name — must NOT create a second site, must return the prior result.
  r2 := public.exploration_site_create('pub-idem-req-1', jsonb_build_object(
          'fields', jsonb_build_object(
            'name', 'Proof Idempotent Site B', 'space_x', 600, 'space_y', 600,
            'reward_bundle_json', jsonb_build_object(
              'items', jsonb_build_array(jsonb_build_object('item_id','anomaly_shard','quantity',1))))));
  if (r1->>'ok')::boolean is not true then
    raise exception 'PUBLISH PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'PUBLISH PROOF FAIL: second call was not an idempotent replay: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'PUBLISH PROOF FAIL: replay result differs from the original (% vs %)', r2->'result', r1->'result';
  end if;
  select count(*) into n from public.exploration_sites where name like 'Proof Idempotent Site%';
  if n <> 1 then
    raise exception 'PUBLISH PROOF FAIL: idempotent request produced % site rows (expected exactly 1)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'pub-idem-req-1';
  if n <> 1 then
    raise exception 'PUBLISH PROOF FAIL: idempotent request produced % audit rows (expected exactly 1)', n;
  end if;
  raise notice 'PUBLISH_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 5 — a BAD payload is REJECTED server-side (validation_failed + details; no row) ──────────
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- blank name + out-of-envelope x + non-numeric y + empty items[]: every rule must fire.
  r := public.exploration_site_create('pub-badpayload-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name', '   ',
           'space_x', 99999,
           'space_y', 'not-a-number',
           'reward_bundle_json', jsonb_build_object('items', jsonb_build_array()))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'PUBLISH PROOF FAIL: bad payload was not rejected as validation_failed: %', r;
  end if;
  if jsonb_typeof(r->'details') <> 'array' or jsonb_array_length(r->'details') < 4 then
    raise exception 'PUBLISH PROOF FAIL: validation_failed details incomplete (expected >=4 issues): %', r->'details';
  end if;
  -- a positive-integer-quantity violation must also be caught.
  r := public.exploration_site_create('pub-badqty-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name', 'Proof Bad Quantity Site', 'space_x', 0, 'space_y', 0,
           'reward_bundle_json', jsonb_build_object(
             'items', jsonb_build_array(jsonb_build_object('item_id','scan_data','quantity',0.5))))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'PUBLISH PROOF FAIL: fractional quantity was not rejected: %', r;
  end if;
  select count(*) into n from public.exploration_sites where name in ('Proof Bad Quantity Site');
  if n <> 0 then
    raise exception 'PUBLISH PROOF FAIL: a validation-rejected create inserted % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit
    where request_id in ('pub-badpayload-req-1','pub-badqty-req-1');
  if n <> 0 then
    raise exception 'PUBLISH PROOF FAIL: a validation-rejected create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_PASS_VALIDATION_REJECTED';
end $$;

-- ── PROOF 6 — a DUPLICATE NAME is a typed conflict (unique key is the one authority; no 2nd row) ───
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- 'Proof Publish Site Alpha' already exists from PROOF 1; a FRESH request_id must hit the unique key.
  r := public.exploration_site_create('pub-conflict-req-1', jsonb_build_object(
         'fields', jsonb_build_object(
           'name', 'Proof Publish Site Alpha', 'space_x', 900, 'space_y', 900,
           'reward_bundle_json', jsonb_build_object(
             'items', jsonb_build_array(jsonb_build_object('item_id','scan_data','quantity',1))))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'conflict' then
    raise exception 'PUBLISH PROOF FAIL: duplicate name was not rejected as conflict: %', r;
  end if;
  if (r->'details'->0->>'code') <> 'duplicate_name' or (r->'details'->0->>'field') <> 'name' then
    raise exception 'PUBLISH PROOF FAIL: conflict details malformed: %', r->'details';
  end if;
  select count(*) into n from public.exploration_sites where name = 'Proof Publish Site Alpha';
  if n <> 1 then
    raise exception 'PUBLISH PROOF FAIL: conflict left % rows named Proof Publish Site Alpha (expected 1)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'pub-conflict-req-1';
  if n <> 0 then
    raise exception 'PUBLISH PROOF FAIL: a conflict-rejected create wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_PASS_CONFLICT';
end $$;

-- ── PROOF 7 — the audit ledger carries the jsonb after_snapshot for the applied create ─────────────
do $$
declare v_after jsonb; v_site record;
begin
  select after_snapshot into v_after from public.world_editor_audit where request_id = 'pub-owner-req-1';
  if v_after is null or jsonb_typeof(v_after) <> 'object' then
    raise exception 'PUBLISH PROOF FAIL: after_snapshot is not a jsonb object: %', v_after;
  end if;
  select * into v_site from public.exploration_sites where name = 'Proof Publish Site Alpha';
  if (v_after->>'id') <> v_site.id::text
     or (v_after->>'name') <> v_site.name
     or (v_after->>'is_active')::boolean is not true
     or v_after->'reward_bundle_json' is null then
    raise exception 'PUBLISH PROOF FAIL: after_snapshot does not mirror the created row: %', v_after;
  end if;
  raise notice 'PUBLISH_PASS_AUDIT_SNAPSHOT';
end $$;

-- ── PROOF 8 — the 0239 pirate-zone lockdown is INTACT (this slice restored NO write privilege) ─────
do $$
begin
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'PUBLISH PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  raise notice 'PUBLISH_PASS_ZONE_LOCKDOWN_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-EXPLORATION PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
