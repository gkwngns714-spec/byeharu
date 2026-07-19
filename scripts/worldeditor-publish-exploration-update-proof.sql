-- WORLD EDITOR PUBLISH-EXPL-UPDATE — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0247 (20260618000247_worldeditor_publish_exploration_update.sql) after the FULL
-- chain is applied by `supabase start`: the FIRST live-world-UPDATE command exploration_site_update
-- ACCEPTS the owner against a matching `expected` snapshot (row updated + audited with BOTH
-- before_snapshot AND after_snapshot; a null fields.reward_bundle_json KEEPS the live bundle),
-- REJECTS the non-owner and the anonymous caller with zero side effects, is idempotent on
-- request_id (exactly one apply, one audit row, identical replayed result), REJECTS a stale
-- `expected` (OPTIMISTIC CONCURRENCY → stale_revision + source_changed per drifted field, nothing
-- written), re-validates the new fields server-side (validation_failed, nothing written), returns a
-- typed not_found/source_missing for a vanished target, and leaves the 0239 pirate-zone lockdown
-- intact.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE (the
-- real byeharu owner does not exist in a disposable DB). NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER, a synthetic NON-OWNER, and ONE live site to update ────────────────
create temp table pubids(k text primary key, v uuid) on commit drop;
insert into pubids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'pubupd.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from pubids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from pubids where k = 'owner';

-- the live row an edit draft "forked from" (seeded as superuser — exploration_sites has no client
-- write path; the migration seeds are unrelated rows and untouched by every assertion below).
insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json) values
  ('Upd Proof Site Origin', 1000, -2000,
   '{"metal": 25, "items": [{"item_id": "scan_data", "quantity": 2}]}'::jsonb);

-- ── PROOF 1 — OWNER UPDATE is APPLIED: coords+name changed, NULL bundle KEPT, audited both ways ────
do $$
declare v_owner uuid; r jsonb; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- `expected` is the honest client fork shape: name+coords observed, bundle null (never readable).
  r := public.exploration_site_update('upd-owner-req-1', jsonb_build_object(
         'target_id', 'Upd Proof Site Origin',
         'source_revision', 'upd-proof-rev-1',
         'expected', jsonb_build_object(
           'name', 'Upd Proof Site Origin', 'space_x', 1000, 'space_y', -2000,
           'reward_bundle_json', null),
         'fields', jsonb_build_object(
           'name', 'Upd Proof Site Renamed', 'space_x', 1111, 'space_y', -2222,
           'reward_bundle_json', null)));
  if (r->>'ok')::boolean is not true then
    raise exception 'UPD PROOF FAIL: owner update not ok: %', r;
  end if;
  if (r->'result'->>'updated') <> 'true' or (r->'result'->>'name') <> 'Upd Proof Site Renamed' then
    raise exception 'UPD PROOF FAIL: owner update result malformed: %', r;
  end if;
  select * into v_row from public.exploration_sites where name = 'Upd Proof Site Renamed';
  if v_row.id is null then
    raise exception 'UPD PROOF FAIL: renamed row not found — update did not apply';
  end if;
  if v_row.id::text <> (r->'result'->>'id') then
    raise exception 'UPD PROOF FAIL: result.id does not match the updated row (% vs %)', r->'result'->>'id', v_row.id;
  end if;
  if v_row.space_x <> 1111 or v_row.space_y <> -2222 then
    raise exception 'UPD PROOF FAIL: coordinates not updated (got %, %)', v_row.space_x, v_row.space_y;
  end if;
  -- the null fields bundle must KEEP the live bundle (never write null into the NOT NULL column).
  if v_row.reward_bundle_json is distinct from '{"metal": 25, "items": [{"item_id": "scan_data", "quantity": 2}]}'::jsonb then
    raise exception 'UPD PROOF FAIL: null fields.reward_bundle_json did not keep the live bundle: %', v_row.reward_bundle_json;
  end if;
  if exists (select 1 from public.exploration_sites where name = 'Upd Proof Site Origin') then
    raise exception 'UPD PROOF FAIL: the pre-rename row still exists — update inserted instead of updating';
  end if;
  raise notice 'PUBLISH_EXPL_UPD_PASS_OWNER_UPDATES';
end $$;

-- ── PROOF 2 — NON-OWNER authenticated user is REJECTED (not_authorized), zero side effects ─────────
do $$
declare v_no uuid; r jsonb; n int;
begin
  select v into v_no from pubids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.exploration_site_update('upd-nonowner-req-1', jsonb_build_object(
         'target_id', 'Upd Proof Site Renamed',
         'expected', jsonb_build_object('name','Upd Proof Site Renamed','space_x',1111,'space_y',-2222,'reward_bundle_json',null),
         'fields',   jsonb_build_object('name','Hijacked Site','space_x',0,'space_y',0,'reward_bundle_json',null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'UPD PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  select count(*) into n from public.exploration_sites where name in ('Hijacked Site');
  if n <> 0 then
    raise exception 'UPD PROOF FAIL: a rejected non-owner update changed % row(s)', n;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'upd-nonowner-req-1';
  if n <> 0 then
    raise exception 'UPD PROOF FAIL: a rejected non-owner update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_EXPL_UPD_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 3 — ANONYMOUS caller is REJECTED (not_authenticated), zero side effects ──────────────────
do $$
declare r jsonb; n int;
begin
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.exploration_site_update('upd-anon-req-1', jsonb_build_object(
         'target_id', 'Upd Proof Site Renamed',
         'expected', jsonb_build_object('name','Upd Proof Site Renamed','space_x',1111,'space_y',-2222,'reward_bundle_json',null),
         'fields',   jsonb_build_object('name','Anon Site','space_x',0,'space_y',0,'reward_bundle_json',null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'UPD PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  select count(*) into n from public.exploration_sites where name = 'Anon Site';
  if n <> 0 then
    raise exception 'UPD PROOF FAIL: an anonymous update changed % row(s)', n;
  end if;
  raise notice 'PUBLISH_EXPL_UPD_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 4 — repeated request_id is IDEMPOTENT (one apply; one audit row; identical replay).
--    The first call also SETS a non-null bundle, proving the bundle write path. ────────────────────
do $$
declare v_owner uuid; r1 jsonb; r2 jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r1 := public.exploration_site_update('upd-idem-req-1', jsonb_build_object(
          'target_id', 'Upd Proof Site Renamed',
          'expected', jsonb_build_object('name','Upd Proof Site Renamed','space_x',1111,'space_y',-2222,'reward_bundle_json',null),
          'fields',   jsonb_build_object('name','Upd Proof Site Renamed','space_x',1500,'space_y',-2222,
                        'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(
                          jsonb_build_object('item_id','anomaly_shard','quantity',1))))));
  -- same request_id, DIFFERENT fields — must NOT re-apply, must return the prior result.
  r2 := public.exploration_site_update('upd-idem-req-1', jsonb_build_object(
          'target_id', 'Upd Proof Site Renamed',
          'expected', jsonb_build_object('name','Upd Proof Site Renamed','space_x',1500,'space_y',-2222,'reward_bundle_json',null),
          'fields',   jsonb_build_object('name','Upd Proof Site Renamed','space_x',1600,'space_y',-2222,'reward_bundle_json',null)));
  if (r1->>'ok')::boolean is not true then
    raise exception 'UPD PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'UPD PROOF FAIL: second call was not an idempotent replay: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'UPD PROOF FAIL: replay result differs from the original (% vs %)', r2->'result', r1->'result';
  end if;
  select * into v_row from public.exploration_sites where name = 'Upd Proof Site Renamed';
  if v_row.space_x <> 1500 then
    raise exception 'UPD PROOF FAIL: replay re-applied (space_x = %, expected the FIRST apply''s 1500)', v_row.space_x;
  end if;
  if v_row.reward_bundle_json is distinct from '{"items": [{"item_id": "anomaly_shard", "quantity": 1}]}'::jsonb then
    raise exception 'UPD PROOF FAIL: non-null fields.reward_bundle_json was not applied: %', v_row.reward_bundle_json;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'upd-idem-req-1';
  if n <> 1 then
    raise exception 'UPD PROOF FAIL: idempotent request produced % audit rows (expected exactly 1)', n;
  end if;
  raise notice 'PUBLISH_EXPL_UPD_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 5 — OPTIMISTIC CONCURRENCY: a stale `expected` is REJECTED (stale_revision), no write ────
do $$
declare v_owner uuid; r jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- live row is now (name 'Upd Proof Site Renamed', x 1500, y -2222): an `expected` carrying the
  -- OLD x (1111) no longer matches — the fork is stale and must be rejected field-precisely.
  r := public.exploration_site_update('upd-stale-req-1', jsonb_build_object(
         'target_id', 'Upd Proof Site Renamed',
         'expected', jsonb_build_object('name','Upd Proof Site Renamed','space_x',1111,'space_y',-2222,'reward_bundle_json',null),
         'fields',   jsonb_build_object('name','Upd Proof Site Renamed','space_x',1700,'space_y',-2222,'reward_bundle_json',null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision' then
    raise exception 'UPD PROOF FAIL: stale expected was not rejected as stale_revision: %', r;
  end if;
  if (r->'details'->0->>'code') <> 'source_changed' or (r->'details'->0->>'field') <> 'space_x' then
    raise exception 'UPD PROOF FAIL: stale_revision details did not name the drifted field: %', r->'details';
  end if;
  -- a NON-null expected bundle that mismatches the live bundle must also read as drift.
  r := public.exploration_site_update('upd-stale-req-2', jsonb_build_object(
         'target_id', 'Upd Proof Site Renamed',
         'expected', jsonb_build_object('name','Upd Proof Site Renamed','space_x',1500,'space_y',-2222,
                       'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(
                         jsonb_build_object('item_id','scan_data','quantity',9)))),
         'fields',   jsonb_build_object('name','Upd Proof Site Renamed','space_x',1700,'space_y',-2222,'reward_bundle_json',null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or (r->'details'->0->>'field') <> 'reward_bundle_json' then
    raise exception 'UPD PROOF FAIL: mismatched non-null expected bundle was not stale_revision/reward_bundle_json: %', r;
  end if;
  select * into v_row from public.exploration_sites where name = 'Upd Proof Site Renamed';
  if v_row.space_x <> 1500 then
    raise exception 'UPD PROOF FAIL: a stale-rejected update WROTE (space_x = %)', v_row.space_x;
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('upd-stale-req-1','upd-stale-req-2');
  if n <> 0 then
    raise exception 'UPD PROOF FAIL: a stale-rejected update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_EXPL_UPD_PASS_STALE_REVISION_REJECTED';
end $$;

-- ── PROOF 6 — BAD new fields are REJECTED server-side (validation_failed + details; no write) ──────
do $$
declare v_owner uuid; r jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- `expected` MATCHES the live row (so this reaches validation); the NEW fields are all bad:
  -- blank name + out-of-envelope x + non-numeric y + non-null bundle with empty items[].
  r := public.exploration_site_update('upd-badpayload-req-1', jsonb_build_object(
         'target_id', 'Upd Proof Site Renamed',
         'expected', jsonb_build_object('name','Upd Proof Site Renamed','space_x',1500,'space_y',-2222,'reward_bundle_json',null),
         'fields',   jsonb_build_object(
           'name', '   ', 'space_x', 99999, 'space_y', 'not-a-number',
           'reward_bundle_json', jsonb_build_object('items', jsonb_build_array()))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed' then
    raise exception 'UPD PROOF FAIL: bad fields were not rejected as validation_failed: %', r;
  end if;
  if jsonb_typeof(r->'details') <> 'array' or jsonb_array_length(r->'details') < 4 then
    raise exception 'UPD PROOF FAIL: validation_failed details incomplete (expected >=4 issues): %', r->'details';
  end if;
  select * into v_row from public.exploration_sites where name = 'Upd Proof Site Renamed';
  if v_row.id is null or v_row.space_x <> 1500 then
    raise exception 'UPD PROOF FAIL: a validation-rejected update changed the row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'upd-badpayload-req-1';
  if n <> 0 then
    raise exception 'UPD PROOF FAIL: a validation-rejected update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_EXPL_UPD_PASS_VALIDATION_REJECTED';
end $$;

-- ── PROOF 7 — a VANISHED target is a typed not_found (source_missing), zero side effects ───────────
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.exploration_site_update('upd-notfound-req-1', jsonb_build_object(
         'target_id', 'Upd Proof No Such Site',
         'expected', jsonb_build_object('name','Upd Proof No Such Site','space_x',0,'space_y',0,'reward_bundle_json',null),
         'fields',   jsonb_build_object('name','Whatever','space_x',0,'space_y',0,'reward_bundle_json',null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_found' then
    raise exception 'UPD PROOF FAIL: vanished target was not rejected as not_found: %', r;
  end if;
  if (r->'details'->0->>'code') <> 'source_missing' then
    raise exception 'UPD PROOF FAIL: not_found details malformed: %', r->'details';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'upd-notfound-req-1';
  if n <> 0 then
    raise exception 'UPD PROOF FAIL: a not_found update wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_EXPL_UPD_PASS_NOT_FOUND';
end $$;

-- ── PROOF 8 — the audit row carries BOTH before_snapshot AND after_snapshot (an update, not a create)
do $$
declare v_before jsonb; v_after jsonb; v_rev text;
begin
  select before_snapshot, after_snapshot, source_revision into v_before, v_after, v_rev
    from public.world_editor_audit where request_id = 'upd-owner-req-1';
  if v_before is null or jsonb_typeof(v_before) <> 'object' then
    raise exception 'UPD PROOF FAIL: before_snapshot is not a jsonb object: %', v_before;
  end if;
  if v_after is null or jsonb_typeof(v_after) <> 'object' then
    raise exception 'UPD PROOF FAIL: after_snapshot is not a jsonb object: %', v_after;
  end if;
  if (v_before->>'name') <> 'Upd Proof Site Origin' or (v_before->>'space_x')::numeric <> 1000 then
    raise exception 'UPD PROOF FAIL: before_snapshot does not mirror the pre-update row: %', v_before;
  end if;
  if (v_after->>'name') <> 'Upd Proof Site Renamed' or (v_after->>'space_x')::numeric <> 1111 then
    raise exception 'UPD PROOF FAIL: after_snapshot does not mirror the post-update row: %', v_after;
  end if;
  if (v_before->>'id') <> (v_after->>'id') then
    raise exception 'UPD PROOF FAIL: before/after snapshots disagree on the row id (% vs %)', v_before->>'id', v_after->>'id';
  end if;
  -- the kept-bundle law, visible in the ledger: both snapshots carry the SAME (kept) live bundle.
  if v_before->'reward_bundle_json' is distinct from v_after->'reward_bundle_json' then
    raise exception 'UPD PROOF FAIL: a null fields bundle changed the audited bundle (% vs %)', v_before->'reward_bundle_json', v_after->'reward_bundle_json';
  end if;
  if v_rev is distinct from 'upd-proof-rev-1' then
    raise exception 'UPD PROOF FAIL: audit source_revision not recorded (got %)', v_rev;
  end if;
  raise notice 'PUBLISH_EXPL_UPD_PASS_AUDIT_BEFORE_AFTER';
end $$;

-- ── PROOF 9 — the 0239 pirate-zone lockdown is INTACT (this slice restored NO write privilege) ─────
do $$
begin
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'UPD PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  raise notice 'PUBLISH_EXPL_UPD_PASS_ZONE_LOCKDOWN_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-EXPL-UPDATE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
