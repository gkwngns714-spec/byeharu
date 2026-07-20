-- WORLD EDITOR PUBLISH-SETACTIVE — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0250 (20260618000250_worldeditor_publish_setactive.sql) after the FULL chain is
-- applied by `supabase start`: the UNPUBLISH/RESTORE commands exploration_site_set_active and
-- mining_field_set_active toggle ONE row's is_active flag for the owner against a matching
-- `expected` snapshot (audited with BOTH before_snapshot AND after_snapshot; NOTHING else changes —
-- a restore brings back the identical row: there is NO hard delete), REJECT the non-owner and the
-- anonymous caller with zero side effects, are idempotent on request_id (exactly one apply, one
-- audit row, identical replayed result), REJECT a stale `expected` (OPTIMISTIC CONCURRENCY →
-- stale_revision + source_changed per drifted field, nothing written), return a typed
-- not_found/source_missing for a vanished target, and leave the 0239 pirate-zone lockdown intact.
-- Every behavior is proven on BOTH the exploration and the mining twin.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE (the
-- real byeharu owner does not exist in a disposable DB). NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER, a synthetic NON-OWNER, ONE live site + ONE live field to toggle ───
create temp table pubids(k text primary key, v uuid) on commit drop;
insert into pubids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'pubact.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from pubids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from pubids where k = 'owner';

-- the live rows an edit draft "forked from" (seeded as superuser — neither table has a client write
-- path; the migration seeds are unrelated rows and untouched by every assertion below).
insert into public.exploration_sites (name, space_x, space_y, reward_bundle_json) values
  ('SetActive Proof Site', 1000, -2000,
   '{"metal": 25, "items": [{"item_id": "scan_data", "quantity": 2}]}'::jsonb);
insert into public.mining_fields (name, space_x, space_y, reward_bundle_json) values
  ('SetActive Proof Field', 3000, 4000,
   '{"items": [{"item_id": "ore_iron", "quantity": 5}]}'::jsonb);

-- ── PROOF 1 — OWNER DISABLES both twins: is_active flips to false, EVERYTHING ELSE untouched ───────
do $$
declare v_owner uuid; r jsonb; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- exploration twin: unpublish (is_active=false).
  r := public.exploration_site_set_active('act-owner-expl-off-1', jsonb_build_object(
         'target_id', 'SetActive Proof Site',
         'source_revision', 'act-proof-rev-1',
         'expected', jsonb_build_object(
           'name', 'SetActive Proof Site', 'space_x', 1000, 'space_y', -2000,
           'reward_bundle_json', null),
         'is_active', false));
  if (r->>'ok')::boolean is not true then
    raise exception 'SETACTIVE PROOF FAIL: owner exploration disable not ok: %', r;
  end if;
  if (r->'result'->>'set_active') <> 'true' or (r->'result'->>'is_active') <> 'false'
     or (r->'result'->>'name') <> 'SetActive Proof Site' then
    raise exception 'SETACTIVE PROOF FAIL: exploration disable result malformed: %', r;
  end if;
  select * into v_row from public.exploration_sites where name = 'SetActive Proof Site';
  if v_row.is_active is not false then
    raise exception 'SETACTIVE PROOF FAIL: exploration is_active not false after disable';
  end if;
  if v_row.space_x <> 1000 or v_row.space_y <> -2000
     or v_row.reward_bundle_json is distinct from '{"metal": 25, "items": [{"item_id": "scan_data", "quantity": 2}]}'::jsonb then
    raise exception 'SETACTIVE PROOF FAIL: a disable changed MORE than is_active on the exploration row';
  end if;

  -- mining twin: unpublish (is_active=false).
  r := public.mining_field_set_active('act-owner-mine-off-1', jsonb_build_object(
         'target_id', 'SetActive Proof Field',
         'source_revision', 'act-proof-rev-m1',
         'expected', jsonb_build_object(
           'name', 'SetActive Proof Field', 'space_x', 3000, 'space_y', 4000,
           'reward_bundle_json', null),
         'is_active', false));
  if (r->>'ok')::boolean is not true or (r->'result'->>'is_active') <> 'false' then
    raise exception 'SETACTIVE PROOF FAIL: owner mining disable not ok: %', r;
  end if;
  select * into v_row from public.mining_fields where name = 'SetActive Proof Field';
  if v_row.is_active is not false then
    raise exception 'SETACTIVE PROOF FAIL: mining is_active not false after disable';
  end if;
  if v_row.space_x <> 3000 or v_row.space_y <> 4000
     or v_row.reward_bundle_json is distinct from '{"items": [{"item_id": "ore_iron", "quantity": 5}]}'::jsonb then
    raise exception 'SETACTIVE PROOF FAIL: a disable changed MORE than is_active on the mining row';
  end if;
  raise notice 'PUBLISH_SETACTIVE_PASS_OWNER_DISABLES';
end $$;

-- ── PROOF 2 — OWNER RE-ENABLES both twins: the SAME rows come back bit-for-bit (no hard delete) ────
do $$
declare v_owner uuid; r jsonb; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.exploration_site_set_active('act-owner-expl-on-1', jsonb_build_object(
         'target_id', 'SetActive Proof Site',
         'expected', jsonb_build_object(
           'name', 'SetActive Proof Site', 'space_x', 1000, 'space_y', -2000,
           'reward_bundle_json', null),
         'is_active', true));
  if (r->>'ok')::boolean is not true or (r->'result'->>'is_active') <> 'true' then
    raise exception 'SETACTIVE PROOF FAIL: owner exploration re-enable not ok: %', r;
  end if;
  select * into v_row from public.exploration_sites where name = 'SetActive Proof Site';
  if v_row.is_active is not true or v_row.space_x <> 1000 or v_row.space_y <> -2000
     or v_row.reward_bundle_json is distinct from '{"metal": 25, "items": [{"item_id": "scan_data", "quantity": 2}]}'::jsonb then
    raise exception 'SETACTIVE PROOF FAIL: exploration restore did not bring back the identical row';
  end if;

  r := public.mining_field_set_active('act-owner-mine-on-1', jsonb_build_object(
         'target_id', 'SetActive Proof Field',
         'expected', jsonb_build_object(
           'name', 'SetActive Proof Field', 'space_x', 3000, 'space_y', 4000,
           'reward_bundle_json', null),
         'is_active', true));
  if (r->>'ok')::boolean is not true or (r->'result'->>'is_active') <> 'true' then
    raise exception 'SETACTIVE PROOF FAIL: owner mining re-enable not ok: %', r;
  end if;
  select * into v_row from public.mining_fields where name = 'SetActive Proof Field';
  if v_row.is_active is not true or v_row.space_x <> 3000 or v_row.space_y <> 4000
     or v_row.reward_bundle_json is distinct from '{"items": [{"item_id": "ore_iron", "quantity": 5}]}'::jsonb then
    raise exception 'SETACTIVE PROOF FAIL: mining restore did not bring back the identical row';
  end if;
  raise notice 'PUBLISH_SETACTIVE_PASS_OWNER_REENABLES';
end $$;

-- ── PROOF 3 — NON-OWNER authenticated user is REJECTED (not_authorized), zero side effects ─────────
do $$
declare v_no uuid; r jsonb; n int;
begin
  select v into v_no from pubids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.exploration_site_set_active('act-nonowner-req-1', jsonb_build_object(
         'target_id', 'SetActive Proof Site',
         'expected', jsonb_build_object('name','SetActive Proof Site','space_x',1000,'space_y',-2000,'reward_bundle_json',null),
         'is_active', false));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'SETACTIVE PROOF FAIL: non-owner exploration toggle was not rejected as not_authorized: %', r;
  end if;
  r := public.mining_field_set_active('act-nonowner-req-2', jsonb_build_object(
         'target_id', 'SetActive Proof Field',
         'expected', jsonb_build_object('name','SetActive Proof Field','space_x',3000,'space_y',4000,'reward_bundle_json',null),
         'is_active', false));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'SETACTIVE PROOF FAIL: non-owner mining toggle was not rejected as not_authorized: %', r;
  end if;
  if exists (select 1 from public.exploration_sites where name = 'SetActive Proof Site' and is_active is not true)
     or exists (select 1 from public.mining_fields where name = 'SetActive Proof Field' and is_active is not true) then
    raise exception 'SETACTIVE PROOF FAIL: a rejected non-owner toggle flipped a flag';
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('act-nonowner-req-1','act-nonowner-req-2');
  if n <> 0 then
    raise exception 'SETACTIVE PROOF FAIL: a rejected non-owner toggle wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_SETACTIVE_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 4 — ANONYMOUS caller is REJECTED (not_authenticated), zero side effects ──────────────────
do $$
declare r jsonb; n int;
begin
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.exploration_site_set_active('act-anon-req-1', jsonb_build_object(
         'target_id', 'SetActive Proof Site',
         'expected', jsonb_build_object('name','SetActive Proof Site','space_x',1000,'space_y',-2000,'reward_bundle_json',null),
         'is_active', false));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'SETACTIVE PROOF FAIL: anonymous exploration toggle was not rejected as not_authenticated: %', r;
  end if;
  r := public.mining_field_set_active('act-anon-req-2', jsonb_build_object(
         'target_id', 'SetActive Proof Field',
         'expected', jsonb_build_object('name','SetActive Proof Field','space_x',3000,'space_y',4000,'reward_bundle_json',null),
         'is_active', false));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'SETACTIVE PROOF FAIL: anonymous mining toggle was not rejected as not_authenticated: %', r;
  end if;
  if exists (select 1 from public.exploration_sites where name = 'SetActive Proof Site' and is_active is not true)
     or exists (select 1 from public.mining_fields where name = 'SetActive Proof Field' and is_active is not true) then
    raise exception 'SETACTIVE PROOF FAIL: an anonymous toggle flipped a flag';
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('act-anon-req-1','act-anon-req-2');
  if n <> 0 then
    raise exception 'SETACTIVE PROOF FAIL: an anonymous toggle wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_SETACTIVE_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 5 — repeated request_id is IDEMPOTENT (one apply; one audit row; identical replay) ───────
do $$
declare v_owner uuid; r1 jsonb; r2 jsonb; n int; v_row record;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- exploration twin: disable once, then replay the SAME request_id with the OPPOSITE direction —
  -- must NOT re-apply, must return the prior result.
  r1 := public.exploration_site_set_active('act-idem-expl-1', jsonb_build_object(
          'target_id', 'SetActive Proof Site',
          'expected', jsonb_build_object('name','SetActive Proof Site','space_x',1000,'space_y',-2000,'reward_bundle_json',null),
          'is_active', false));
  r2 := public.exploration_site_set_active('act-idem-expl-1', jsonb_build_object(
          'target_id', 'SetActive Proof Site',
          'expected', jsonb_build_object('name','SetActive Proof Site','space_x',1000,'space_y',-2000,'reward_bundle_json',null),
          'is_active', true));
  if (r1->>'ok')::boolean is not true then
    raise exception 'SETACTIVE PROOF FAIL: first idempotent exploration call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'SETACTIVE PROOF FAIL: second exploration call was not an idempotent replay: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'SETACTIVE PROOF FAIL: exploration replay result differs (% vs %)', r2->'result', r1->'result';
  end if;
  select * into v_row from public.exploration_sites where name = 'SetActive Proof Site';
  if v_row.is_active is not false then
    raise exception 'SETACTIVE PROOF FAIL: exploration replay re-applied (is_active = %, expected the FIRST apply''s false)', v_row.is_active;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'act-idem-expl-1';
  if n <> 1 then
    raise exception 'SETACTIVE PROOF FAIL: idempotent exploration request produced % audit rows (expected exactly 1)', n;
  end if;

  -- mining twin: same law.
  r1 := public.mining_field_set_active('act-idem-mine-1', jsonb_build_object(
          'target_id', 'SetActive Proof Field',
          'expected', jsonb_build_object('name','SetActive Proof Field','space_x',3000,'space_y',4000,'reward_bundle_json',null),
          'is_active', false));
  r2 := public.mining_field_set_active('act-idem-mine-1', jsonb_build_object(
          'target_id', 'SetActive Proof Field',
          'expected', jsonb_build_object('name','SetActive Proof Field','space_x',3000,'space_y',4000,'reward_bundle_json',null),
          'is_active', true));
  if (r1->>'ok')::boolean is not true
     or (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true
     or (r2->'result') <> (r1->'result') then
    raise exception 'SETACTIVE PROOF FAIL: mining idempotency broken (r1 %, r2 %)', r1, r2;
  end if;
  select * into v_row from public.mining_fields where name = 'SetActive Proof Field';
  if v_row.is_active is not false then
    raise exception 'SETACTIVE PROOF FAIL: mining replay re-applied (is_active = %)', v_row.is_active;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'act-idem-mine-1';
  if n <> 1 then
    raise exception 'SETACTIVE PROOF FAIL: idempotent mining request produced % audit rows (expected exactly 1)', n;
  end if;

  -- restore both to active for the remaining proofs (fresh request_ids — a real re-publish).
  r1 := public.exploration_site_set_active('act-idem-expl-restore', jsonb_build_object(
          'target_id', 'SetActive Proof Site',
          'expected', jsonb_build_object('name','SetActive Proof Site','space_x',1000,'space_y',-2000,'reward_bundle_json',null),
          'is_active', true));
  r2 := public.mining_field_set_active('act-idem-mine-restore', jsonb_build_object(
          'target_id', 'SetActive Proof Field',
          'expected', jsonb_build_object('name','SetActive Proof Field','space_x',3000,'space_y',4000,'reward_bundle_json',null),
          'is_active', true));
  if (r1->>'ok')::boolean is not true or (r2->>'ok')::boolean is not true then
    raise exception 'SETACTIVE PROOF FAIL: post-idempotency restore failed (% / %)', r1, r2;
  end if;
  raise notice 'PUBLISH_SETACTIVE_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 6 — OPTIMISTIC CONCURRENCY: a stale `expected` is REJECTED (stale_revision), no write ────
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- exploration twin: `expected` carries a WRONG space_x — the fork is stale, field named precisely.
  r := public.exploration_site_set_active('act-stale-expl-1', jsonb_build_object(
         'target_id', 'SetActive Proof Site',
         'expected', jsonb_build_object('name','SetActive Proof Site','space_x',1111,'space_y',-2000,'reward_bundle_json',null),
         'is_active', false));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or (r->'details'->0->>'code') <> 'source_changed' or (r->'details'->0->>'field') <> 'space_x' then
    raise exception 'SETACTIVE PROOF FAIL: stale exploration expected was not rejected field-precisely: %', r;
  end if;
  -- mining twin: `expected` carries a WRONG name-adjacent coord — same law.
  r := public.mining_field_set_active('act-stale-mine-1', jsonb_build_object(
         'target_id', 'SetActive Proof Field',
         'expected', jsonb_build_object('name','SetActive Proof Field','space_x',3000,'space_y',9999,'reward_bundle_json',null),
         'is_active', false));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or (r->'details'->0->>'field') <> 'space_y' then
    raise exception 'SETACTIVE PROOF FAIL: stale mining expected was not rejected field-precisely: %', r;
  end if;
  if exists (select 1 from public.exploration_sites where name = 'SetActive Proof Site' and is_active is not true)
     or exists (select 1 from public.mining_fields where name = 'SetActive Proof Field' and is_active is not true) then
    raise exception 'SETACTIVE PROOF FAIL: a stale-rejected toggle WROTE a flag';
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('act-stale-expl-1','act-stale-mine-1');
  if n <> 0 then
    raise exception 'SETACTIVE PROOF FAIL: a stale-rejected toggle wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_SETACTIVE_PASS_STALE_REVISION_REJECTED';
end $$;

-- ── PROOF 7 — a VANISHED target is a typed not_found (source_missing), zero side effects ───────────
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from pubids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.exploration_site_set_active('act-notfound-expl-1', jsonb_build_object(
         'target_id', 'SetActive No Such Site',
         'expected', jsonb_build_object('name','SetActive No Such Site','space_x',0,'space_y',0,'reward_bundle_json',null),
         'is_active', false));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_found'
     or (r->'details'->0->>'code') <> 'source_missing' then
    raise exception 'SETACTIVE PROOF FAIL: vanished exploration target was not not_found/source_missing: %', r;
  end if;
  r := public.mining_field_set_active('act-notfound-mine-1', jsonb_build_object(
         'target_id', 'SetActive No Such Field',
         'expected', jsonb_build_object('name','SetActive No Such Field','space_x',0,'space_y',0,'reward_bundle_json',null),
         'is_active', false));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_found'
     or (r->'details'->0->>'code') <> 'source_missing' then
    raise exception 'SETACTIVE PROOF FAIL: vanished mining target was not not_found/source_missing: %', r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('act-notfound-expl-1','act-notfound-mine-1');
  if n <> 0 then
    raise exception 'SETACTIVE PROOF FAIL: a not_found toggle wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_SETACTIVE_PASS_NOT_FOUND';
end $$;

-- ── PROOF 8 — the audit rows carry BOTH snapshots and the flag flip is the ONLY delta ──────────────
do $$
declare v_before jsonb; v_after jsonb; v_rev text;
begin
  -- exploration disable ledger row (PROOF 1's 'act-owner-expl-off-1').
  select before_snapshot, after_snapshot, source_revision into v_before, v_after, v_rev
    from public.world_editor_audit where request_id = 'act-owner-expl-off-1';
  if v_before is null or jsonb_typeof(v_before) <> 'object'
     or v_after is null or jsonb_typeof(v_after) <> 'object' then
    raise exception 'SETACTIVE PROOF FAIL: exploration audit snapshots are not jsonb objects (% / %)', v_before, v_after;
  end if;
  if (v_before->>'is_active')::boolean is not true or (v_after->>'is_active')::boolean is not false then
    raise exception 'SETACTIVE PROOF FAIL: exploration audit does not record the true→false flip (% → %)', v_before->>'is_active', v_after->>'is_active';
  end if;
  if (v_before->>'id') <> (v_after->>'id')
     or (v_before->>'name') is distinct from (v_after->>'name')
     or v_before->'space_x' is distinct from v_after->'space_x'
     or v_before->'space_y' is distinct from v_after->'space_y'
     or v_before->'reward_bundle_json' is distinct from v_after->'reward_bundle_json' then
    raise exception 'SETACTIVE PROOF FAIL: exploration audit shows a delta beyond is_active (% vs %)', v_before, v_after;
  end if;
  if v_rev is distinct from 'act-proof-rev-1' then
    raise exception 'SETACTIVE PROOF FAIL: exploration audit source_revision not recorded (got %)', v_rev;
  end if;

  -- mining disable ledger row (PROOF 1's 'act-owner-mine-off-1').
  select before_snapshot, after_snapshot, source_revision into v_before, v_after, v_rev
    from public.world_editor_audit where request_id = 'act-owner-mine-off-1';
  if (v_before->>'is_active')::boolean is not true or (v_after->>'is_active')::boolean is not false then
    raise exception 'SETACTIVE PROOF FAIL: mining audit does not record the true→false flip (% → %)', v_before->>'is_active', v_after->>'is_active';
  end if;
  if (v_before->>'id') <> (v_after->>'id')
     or (v_before->>'name') is distinct from (v_after->>'name')
     or v_before->'space_x' is distinct from v_after->'space_x'
     or v_before->'space_y' is distinct from v_after->'space_y'
     or v_before->'reward_bundle_json' is distinct from v_after->'reward_bundle_json' then
    raise exception 'SETACTIVE PROOF FAIL: mining audit shows a delta beyond is_active (% vs %)', v_before, v_after;
  end if;
  if v_rev is distinct from 'act-proof-rev-m1' then
    raise exception 'SETACTIVE PROOF FAIL: mining audit source_revision not recorded (got %)', v_rev;
  end if;

  -- the RESTORE rows record the false→true flip (the ledger shows the round trip).
  select before_snapshot, after_snapshot into v_before, v_after
    from public.world_editor_audit where request_id = 'act-owner-expl-on-1';
  if (v_before->>'is_active')::boolean is not false or (v_after->>'is_active')::boolean is not true then
    raise exception 'SETACTIVE PROOF FAIL: exploration restore audit does not record the false→true flip';
  end if;
  select before_snapshot, after_snapshot into v_before, v_after
    from public.world_editor_audit where request_id = 'act-owner-mine-on-1';
  if (v_before->>'is_active')::boolean is not false or (v_after->>'is_active')::boolean is not true then
    raise exception 'SETACTIVE PROOF FAIL: mining restore audit does not record the false→true flip';
  end if;
  raise notice 'PUBLISH_SETACTIVE_PASS_AUDIT_BEFORE_AFTER';
end $$;

-- ── PROOF 9 — the 0239 pirate-zone lockdown is INTACT (this slice restored NO write privilege) ─────
do $$
begin
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'SETACTIVE PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  raise notice 'PUBLISH_SETACTIVE_PASS_ZONE_LOCKDOWN_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-SETACTIVE PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
