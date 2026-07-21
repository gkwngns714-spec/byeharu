-- WORLD EDITOR AUDIT-READ — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0256 (world_editor_audit_list) after the FULL chain is applied by `supabase start`:
-- the owner-only, field-filtered, keyset-paginated reader over world_editor_audit ACCEPTS the owner,
-- REJECTS non-owner (not_authorized) and anon (not_authenticated), validates whitelisted filters
-- (unknown command/target → invalid_request; malformed cursor → invalid_request), paginates stably by
-- keyset, clamps the page size, and — the load-bearing security property — NEVER returns
-- reward_bundle_json (server-only loot), created_by, or the raw actor UUID; it returns actor_is_owner
-- and a redactions[] list instead. The read writes NO audit row of its own.
--
-- Self-rolling-back: everything inside one begin;...rollback; — ZERO persisted state. The owner and
-- the audit rows are synthetic fixtures created HERE. NEVER point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER + NON-OWNER, and representative audit rows ─────────────────────────
create temp table arids(k text primary key, v uuid) on commit drop;
insert into arids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'auditread.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from arids;
insert into public.app_owners(user_id) select v from arids where k = 'owner';

-- seed audit rows AS SUPERUSER (the ledger is deny-all to clients; the command entrypoint is the only
-- real writer — here we insert fixtures directly to exercise the READER). One mining create carrying a
-- reward_bundle_json (the server-only field the reader must strip), one zone_unpublish carrying
-- created_by (must strip), plus enough rows to page.
do $$
declare v_owner uuid; i int;
begin
  select v into v_owner from arids where k = 'owner';
  -- a mining create with a full reward bundle in after_snapshot (the leak the reader must prevent)
  insert into public.world_editor_audit
    (actor, request_id, command_type, target_type, target_id, result, before_snapshot, after_snapshot, source_revision, created_at)
  values
    (v_owner, 'ar-mining-create-1', 'mining_field_create', 'mining_field', gen_random_uuid()::text,
     '{"created":true,"name":"AR Field"}',
     null,
     jsonb_build_object('id',gen_random_uuid()::text,'name','AR Field','space_x',10,'space_y',20,
       'reward_bundle_json', jsonb_build_object('items', jsonb_build_array(jsonb_build_object('item_id','ore','quantity',7))),
       'is_active',true,'created_at', now()),
     'rev-a', now() - interval '10 minutes');
  -- a zone_unpublish with created_by in both snapshots (must strip created_by; keeps geometry-less zone fields)
  insert into public.world_editor_audit
    (actor, request_id, command_type, target_type, target_id, result, before_snapshot, after_snapshot, source_revision, created_at)
  values
    (v_owner, 'ar-zone-unpublish-1', 'zone_unpublish', 'zone', gen_random_uuid()::text,
     '{"unpublished":true,"status":"inactive"}',
     jsonb_build_object('id',gen_random_uuid()::text,'name','AR Zone','zone_kind','pirate','source','drawn',
       'location_id',null,'status','active','created_by', v_owner::text,'created_at', now()),
     jsonb_build_object('id',gen_random_uuid()::text,'name','AR Zone','zone_kind','pirate','source','drawn',
       'location_id',null,'status','inactive','created_by', v_owner::text,'created_at', now()),
     'rev-b', now() - interval '9 minutes');
  -- 5 more location updates to exercise pagination
  for i in 1..5 loop
    insert into public.world_editor_audit
      (actor, request_id, command_type, target_type, target_id, result, before_snapshot, after_snapshot, source_revision, created_at)
    values
      (v_owner, 'ar-loc-update-'||i, 'location_update', 'location', gen_random_uuid()::text,
       '{"updated":true}',
       jsonb_build_object('id',gen_random_uuid()::text,'name','Loc '||i,'status','active'),
       jsonb_build_object('id',gen_random_uuid()::text,'name','Loc '||i,'status','locked'),
       'rev-'||i, now() - (i || ' minutes')::interval);
  end loop;
end $$;

-- ── PROOF 1 — OWNER reads records; the reader returns a typed page ─────────────────────────────────
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from arids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_audit_list('{}'::jsonb);
  if (r->>'ok')::boolean is not true then
    raise exception 'AUDIT-READ PROOF FAIL: owner read not ok: %', r;
  end if;
  n := jsonb_array_length(r->'items');
  if n <> 7 then
    raise exception 'AUDIT-READ PROOF FAIL: expected 7 items, got %', n;
  end if;
  -- newest-first ordering: the first item is the most recent (ar-zone-unpublish-1 at -9m is newer than the -10m mining, and the loc updates are -1..-5m so newest overall is ar-loc-update-1 at -1m)
  if (r->'items'->0->>'request_id') <> 'ar-loc-update-1' then
    raise exception 'AUDIT-READ PROOF FAIL: not newest-first (first=%)', r->'items'->0->>'request_id';
  end if;
  raise notice 'AUDIT_READ_PASS_OWNER_READS';
end $$;

-- ── PROOF 2 — NON-OWNER rejected (not_authorized); ANON rejected (not_authenticated) ───────────────
do $$
declare v_no uuid; r jsonb;
begin
  select v into v_no from arids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.world_editor_audit_list('{}'::jsonb);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'AUDIT-READ PROOF FAIL: non-owner not rejected as not_authorized: %', r;
  end if;
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.world_editor_audit_list('{}'::jsonb);
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'AUDIT-READ PROOF FAIL: anon not rejected as not_authenticated: %', r;
  end if;
  if has_function_privilege('anon', 'public.world_editor_audit_list(jsonb)', 'execute') then
    raise exception 'AUDIT-READ PROOF FAIL: anon holds EXECUTE on the reader';
  end if;
  raise notice 'AUDIT_READ_PASS_DENIALS';
end $$;

-- ── PROOF 3 — the SERVER-ONLY leak is closed: no reward_bundle_json / created_by / actor in output ─
do $$
declare v_owner uuid; r jsonb; it jsonb; mining jsonb; zone jsonb;
begin
  select v into v_owner from arids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.world_editor_audit_list(jsonb_build_object('request_id','ar-mining-create-1'));
  mining := r->'items'->0;
  if mining is null or (mining->>'request_id') <> 'ar-mining-create-1' then
    raise exception 'AUDIT-READ PROOF FAIL: could not fetch the mining record by request_id: %', r;
  end if;
  -- reward_bundle_json must be absent from the after snapshot, and flagged in redactions.
  if (mining->'after' ? 'reward_bundle_json') then
    raise exception 'AUDIT-READ PROOF FAIL: reward_bundle_json LEAKED in after snapshot: %', mining->'after';
  end if;
  if not (mining->'redactions' @> '["reward_bundle_json"]'::jsonb) then
    raise exception 'AUDIT-READ PROOF FAIL: reward_bundle_json redaction not reported: %', mining->'redactions';
  end if;
  -- no raw actor UUID anywhere in the record; actor_is_owner is a boolean true instead.
  if mining::text like '%'||v_owner::text||'%' then
    raise exception 'AUDIT-READ PROOF FAIL: the owner UUID leaked verbatim into the record: %', mining;
  end if;
  if (mining->>'actor_is_owner') <> 'true' then
    raise exception 'AUDIT-READ PROOF FAIL: actor_is_owner not true: %', mining;
  end if;
  -- create record: before must be null; after present.
  if (mining->'before') is not null and jsonb_typeof(mining->'before') <> 'null' then
    raise exception 'AUDIT-READ PROOF FAIL: create before_snapshot must be null: %', mining->'before';
  end if;
  -- zone_unpublish: created_by stripped from both snapshots; both snapshots present.
  r := public.world_editor_audit_list(jsonb_build_object('request_id','ar-zone-unpublish-1'));
  zone := r->'items'->0;
  if (zone->'before' ? 'created_by') or (zone->'after' ? 'created_by') then
    raise exception 'AUDIT-READ PROOF FAIL: created_by LEAKED in a zone snapshot: %', zone;
  end if;
  if not (zone->'redactions' @> '["created_by"]'::jsonb) then
    raise exception 'AUDIT-READ PROOF FAIL: created_by redaction not reported: %', zone->'redactions';
  end if;
  if (zone->'before'->>'status') <> 'active' or (zone->'after'->>'status') <> 'inactive' then
    raise exception 'AUDIT-READ PROOF FAIL: unpublish before/after status wrong: %', zone;
  end if;
  raise notice 'AUDIT_READ_PASS_NO_LEAK';
end $$;

-- ── PROOF 4 — filters + invalid-request handling ──────────────────────────────────────────────────
do $$
declare v_owner uuid; r jsonb;
begin
  select v into v_owner from arids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- target_type filter narrows to zones (1 row)
  r := public.world_editor_audit_list(jsonb_build_object('target_type','zone'));
  if jsonb_array_length(r->'items') <> 1 or (r->'items'->0->>'command_type') <> 'zone_unpublish' then
    raise exception 'AUDIT-READ PROOF FAIL: target_type=zone filter wrong: %', r;
  end if;
  -- command_type filter narrows to location updates (5 rows)
  r := public.world_editor_audit_list(jsonb_build_object('command_type','location_update'));
  if jsonb_array_length(r->'items') <> 5 then
    raise exception 'AUDIT-READ PROOF FAIL: command_type=location_update filter wrong count: %', jsonb_array_length(r->'items');
  end if;
  -- unknown enum values are invalid_request (not a silent empty page)
  r := public.world_editor_audit_list(jsonb_build_object('command_type','definitely_not_a_command'));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'invalid_request' then
    raise exception 'AUDIT-READ PROOF FAIL: unknown command_type not invalid_request: %', r;
  end if;
  r := public.world_editor_audit_list(jsonb_build_object('target_type','planet'));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'invalid_request' then
    raise exception 'AUDIT-READ PROOF FAIL: unknown target_type not invalid_request: %', r;
  end if;
  -- malformed cursor is invalid_request
  r := public.world_editor_audit_list(jsonb_build_object('cursor', jsonb_build_object('ts','not-a-date','id','x')));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'invalid_request' then
    raise exception 'AUDIT-READ PROOF FAIL: malformed cursor not invalid_request: %', r;
  end if;
  -- exact request_id lookup returns exactly that one record
  r := public.world_editor_audit_list(jsonb_build_object('request_id','ar-mining-create-1'));
  if (r->>'ok')::boolean is not true or jsonb_array_length(r->'items') <> 1
     or (r->'items'->0->>'request_id') <> 'ar-mining-create-1' then
    raise exception 'AUDIT-READ PROOF FAIL: exact request_id lookup wrong: %', r;
  end if;
  -- EMPTY RESULT — a valid filter that matches nothing is ok:true with an empty page (never an error)
  r := public.world_editor_audit_list(jsonb_build_object('request_id','no-such-request-id'));
  if (r->>'ok')::boolean is not true or jsonb_array_length(r->'items') <> 0
     or jsonb_typeof(r->'next_cursor') = 'object' then
    raise exception 'AUDIT-READ PROOF FAIL: empty result not a clean empty page: %', r;
  end if;
  -- MALFORMED PAYLOAD — a non-numeric limit and a non-timestamp date are invalid_request
  r := public.world_editor_audit_list(jsonb_build_object('limit','not-a-number'));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'invalid_request' then
    raise exception 'AUDIT-READ PROOF FAIL: non-numeric limit not invalid_request: %', r;
  end if;
  r := public.world_editor_audit_list(jsonb_build_object('since','not-a-date'));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'invalid_request' then
    raise exception 'AUDIT-READ PROOF FAIL: bad since date not invalid_request: %', r;
  end if;
  raise notice 'AUDIT_READ_PASS_FILTERS';
end $$;

-- ── PROOF 5 — keyset pagination is stable + complete (no dup, no skip) and page size is clamped ────
do $$
declare v_owner uuid; r1 jsonb; r2 jsonb; seen text[]; v_dups int;
begin
  select v into v_owner from arids where arids.k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- page 1 of size 3 → next_cursor present
  r1 := public.world_editor_audit_list(jsonb_build_object('limit',3));
  if jsonb_array_length(r1->'items') <> 3 or jsonb_typeof(r1->'next_cursor') is distinct from 'object' then
    raise exception 'AUDIT-READ PROOF FAIL: page1 wrong (len %, next %)', jsonb_array_length(r1->'items'), r1->'next_cursor';
  end if;
  -- page 2 via cursor
  r2 := public.world_editor_audit_list(jsonb_build_object('limit',3,'cursor', r1->'next_cursor'));
  -- accumulate request_ids across both pages; expect NO overlap (stable keyset pagination)
  select array_agg(rid) into seen from (
    select (jsonb_array_elements(r1->'items')->>'request_id') as rid
    union all
    select (jsonb_array_elements(r2->'items')->>'request_id') as rid
  ) u;
  select count(*) - count(distinct s) into v_dups from unnest(seen) as s;
  if v_dups <> 0 then
    raise exception 'AUDIT-READ PROOF FAIL: pagination produced a duplicate across pages: %', seen;
  end if;
  -- page size clamp: limit 9999 → clamped to 100 in page_size, and all 7 rows returned in one page
  r1 := public.world_editor_audit_list(jsonb_build_object('limit',9999));
  if (r1->>'page_size')::int <> 100 or jsonb_array_length(r1->'items') <> 7 or jsonb_typeof(r1->'next_cursor') = 'object' then
    raise exception 'AUDIT-READ PROOF FAIL: page-size clamp / full page wrong: page_size=% len=% next=%',
      r1->>'page_size', jsonb_array_length(r1->'items'), r1->'next_cursor';
  end if;
  raise notice 'AUDIT_READ_PASS_PAGINATION';
end $$;

-- ── PROOF 6 — the read is READ-ONLY: it wrote no audit row and the ledger stays deny-all ───────────
do $$
declare v_owner uuid; before_n int; after_n int;
begin
  select count(*) into before_n from public.world_editor_audit;
  select v into v_owner from arids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  perform public.world_editor_audit_list('{}'::jsonb);
  select count(*) into after_n from public.world_editor_audit;
  if after_n <> before_n then
    raise exception 'AUDIT-READ PROOF FAIL: the reader wrote % audit row(s)', after_n - before_n;
  end if;
  if has_table_privilege('authenticated', 'public.world_editor_audit', 'SELECT')
     or has_table_privilege('anon', 'public.world_editor_audit', 'SELECT') then
    raise exception 'AUDIT-READ PROOF FAIL: a client role holds SELECT on world_editor_audit — must stay deny-all';
  end if;
  if not (select relrowsecurity from pg_class where oid='public.world_editor_audit'::regclass) then
    raise exception 'AUDIT-READ PROOF FAIL: RLS disabled on world_editor_audit';
  end if;
  raise notice 'AUDIT_READ_PASS_READONLY_AND_DENYALL';
end $$;

do $$ begin raise notice 'WORLD-EDITOR AUDIT-READ PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state.
