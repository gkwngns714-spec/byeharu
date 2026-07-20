-- WORLD EDITOR PUBLISH-ZONE-UNPUBLISH — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0255 (20260618000255_worldeditor_publish_zone_unpublish.sql) after the FULL chain
-- is applied by `supabase start`: the zone UNPUBLISH command (twin of 0254 zone_create). It drives the
-- WHOLE lifecycle end to end — owner CREATE a marked canary zone (0254), verify it is player-active
-- (get_danger_zones while lit) and interception-relevant (the exact leaf predicate status='active' AND
-- ST_Intersects), REJECT the non-owner (not_authorized) and anonymous (not_authenticated) unpublish
-- with zero side effects, REJECT a seeded source='circle' zone as not_unpublishable/protected_zone,
-- REJECT a vanished target (not_found/source_missing) and a drifted draft (stale_revision/
-- source_changed), then owner UNPUBLISH the canary → the row is PRESERVED with status='inactive', it
-- disappears from get_danger_zones AND from the interception predicate at once, exactly one create
-- audit + one unpublish audit exist (with before/after snapshots), an idempotent replay adds no
-- second audit, a NEW request on the now-inactive zone is not_unpublishable/already_inactive, existing
-- active zones are untouched, and the danger_zones client-write lockdown + the 0239 pirate-zone
-- lockdown are intact.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- kept flipped, no world row kept. The owner it "seeds" is a synthetic auth.users row created HERE
-- (the real byeharu owner does not exist in a disposable DB). The pirate_intercept_enabled flip for
-- the read check is INSIDE the transaction and rolled back with everything else. NEVER point this at
-- production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER + NON-OWNER; one active hostile location; one seeded 'circle' zone ──
create temp table pubuids(k text primary key, v uuid) on commit drop;
insert into pubuids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'pubzoneunpub.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from pubuids;

-- seed ONLY the owner into the allow-list (as superuser — the deny-all table has no client write path).
insert into public.app_owners(user_id) select v from pubuids where k = 'owner';

-- a live hostile location (a legal zone attach target + the anchor for the seeded circle zone) and a
-- directly-inserted source='circle' zone (the PROTECTED target — zone_create only ever writes 'drawn',
-- so a 'circle' zone must be seeded here to prove the protected guard).
create temp table pubz(k text primary key, v uuid) on commit drop;
do $$
declare v_zone uuid; v_hostile uuid; v_circle uuid;
begin
  select id into v_zone from public.zones order by name limit 1;
  if v_zone is null then
    raise exception 'ZONE UNPUBLISH PROOF SETUP FAIL: the seeded chain has no zones to host the fixtures';
  end if;
  insert into public.locations
      (zone_id, name, location_type, activity_type, x, y, reward_tier, base_difficulty,
       min_power_required, is_public, territory_radius, status)
    values
      (v_zone, 'Zone Unpub Proof Den', 'pirate_den', 'hunt_pirates', 800, -800, 1, 1, 0, true, null, 'active')
    returning id into v_hostile;
  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
    values ('Zone Unpub Proof Seed Circle', 'pirate', 'circle', v_hostile,
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
  r := public.zone_create('zoneunpub-create-canary-req-1', jsonb_build_object(
         'source_revision', 'zoneunpub-create-rev-1',
         'fields', jsonb_build_object(
           'name','CANARY-Zone-Unpub-Proof','zone_kind','pirate','attach_location_id', null,
           'geometry', jsonb_build_object('kind','circle',
             'center', jsonb_build_object('x', 800, 'y', -800), 'radius', 120))));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: owner canary create not ok: %', r;
  end if;
  v_id := (r->'result'->>'id')::uuid;
  select * into v_row from public.danger_zones where id = v_id;
  if v_row.source <> 'drawn' or v_row.status <> 'active' or v_row.location_id is not null then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: canary shape wrong (%, %, %)', v_row.source, v_row.status, v_row.location_id;
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_OWNER_CREATES_CANARY';
end $$;

-- ── PROOF 2 — while ACTIVE (+ intercept lit) the canary is player-visible AND interception-relevant ─
do $$
declare v_id uuid; v_read jsonb; v_hit boolean;
begin
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-Unpub-Proof';
  -- txn-local flag flip for the read check (rolled back with everything).
  insert into public.game_config(key, value, description)
    values ('pirate_intercept_enabled', 'true'::jsonb, 'proof-txn-local')
    on conflict (key) do update set value = 'true'::jsonb;
  v_read := public.get_danger_zones();
  if not exists (select 1 from jsonb_array_elements(v_read) z where (z->>'id')::uuid = v_id) then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: the active canary is missing from get_danger_zones while lit: %', v_read;
  end if;
  -- interception relevance = the EXACT leaf predicate of pirate_intercept_leg_zone_hits (0233):
  -- status='active' AND ST_Intersects(boundary, leg). A leg through the canary centre must hit it.
  select exists (
    select 1 from public.danger_zones z
     where z.id = v_id and z.status = 'active'
       and ST_Intersects(z.boundary, ST_MakeLine(ST_MakePoint(700, -800), ST_MakePoint(900, -800)))
  ) into v_hit;
  if not v_hit then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: the active canary is not interception-relevant for a crossing leg';
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_ACTIVE_VISIBLE';
end $$;

-- ── PROOF 3 — NON-OWNER unpublish is REJECTED (not_authorized), zero side effects ──────────────────
do $$
declare v_no uuid; v_id uuid; r jsonb; v_status text; n int;
begin
  select v into v_no from pubuids where k = 'nonowner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-Unpub-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.zone_unpublish('zoneunpub-nonowner-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-Unpub-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: non-owner was not rejected as not_authorized: %', r;
  end if;
  select status into v_status from public.danger_zones where id = v_id;
  if v_status <> 'active' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a rejected non-owner unpublish changed status to %', v_status;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneunpub-nonowner-req-1';
  if n <> 0 then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a rejected non-owner unpublish wrote % audit row(s)', n;
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_NONOWNER_REJECTED';
end $$;

-- ── PROOF 4 — ANONYMOUS unpublish is REJECTED (not_authenticated) + anon holds NO execute grant ────
do $$
declare v_id uuid; r jsonb; v_status text;
begin
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-Unpub-Proof';
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.zone_unpublish('zoneunpub-anon-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-Unpub-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: anonymous caller was not rejected as not_authenticated: %', r;
  end if;
  select status into v_status from public.danger_zones where id = v_id;
  if v_status <> 'active' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a rejected anon unpublish changed status to %', v_status;
  end if;
  if has_function_privilege('anon', 'public.zone_unpublish(text,jsonb)', 'execute') then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: anon holds EXECUTE on zone_unpublish — must be authenticated-only';
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_ANON_REJECTED';
end $$;

-- ── PROOF 5 — a SEEDED source='circle' zone is PROTECTED (not_unpublishable/protected_zone) ─────────
do $$
declare v_owner uuid; v_circle uuid; r jsonb; v_status text;
begin
  select v into v_owner from pubuids where k = 'owner';
  select v into v_circle from pubz where k = 'circle';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_unpublish('zoneunpub-protected-req-1', jsonb_build_object(
         'target_id', v_circle::text,
         'expected', jsonb_build_object('name','Zone Unpub Proof Seed Circle','source','circle',
                       'location_id', (select location_id from public.danger_zones where id = v_circle))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_unpublishable'
     or (r->'details'->0->>'code') <> 'protected_zone' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a seeded circle zone was not rejected as not_unpublishable/protected_zone: %', r;
  end if;
  select status into v_status from public.danger_zones where id = v_circle;
  if v_status <> 'active' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: the protected circle zone was mutated to %', v_status;
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_PROTECTED_ZONE_REJECTED';
end $$;

-- ── PROOF 6 — a VANISHED target is not_found/source_missing; a DRIFTED draft is stale_revision ──────
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-Unpub-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- (a) not_found — a well-formed uuid naming no zone.
  r := public.zone_unpublish('zoneunpub-notfound-req-1', jsonb_build_object(
         'target_id', gen_random_uuid()::text,
         'expected', jsonb_build_object('name','ghost','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_found'
     or (r->'details'->0->>'code') <> 'source_missing' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a ghost target was not not_found/source_missing: %', r;
  end if;
  -- (b) stale_revision — the expected snapshot's name no longer matches the live canary.
  r := public.zone_unpublish('zoneunpub-stale-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','WRONG NAME','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or not exists (select 1 from jsonb_array_elements(r->'details') d
                    where d->>'code' = 'source_changed' and d->>'field' = 'name') then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a drifted draft was not stale_revision/source_changed: %', r;
  end if;
  -- neither wrote an audit row nor changed the live status.
  select count(*) into n from public.world_editor_audit
   where request_id in ('zoneunpub-notfound-req-1','zoneunpub-stale-req-1');
  if n <> 0 then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a rejected unpublish wrote % audit row(s)', n;
  end if;
  if (select status from public.danger_zones where id = v_id) <> 'active' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a rejected unpublish changed the canary status';
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_NOT_FOUND_AND_STALE';
end $$;

-- ── PROOF 7 — OWNER UNPUBLISHES the canary: ok, row PRESERVED with status='inactive' ────────────────
do $$
declare v_owner uuid; v_id uuid; r jsonb; v_row record;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-Unpub-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_unpublish('zoneunpub-owner-req-1', jsonb_build_object(
         'source_revision', 'zoneunpub-rev-1',
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-Unpub-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: owner unpublish not ok: %', r;
  end if;
  if (r->'result'->>'unpublished') <> 'true' or (r->'result'->>'status') <> 'inactive'
     or (r->'result'->>'id') <> v_id::text then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: owner unpublish result malformed: %', r;
  end if;
  -- the row is PRESERVED (not deleted); only status/updated_at changed; geometry+name+source kept.
  select * into v_row from public.danger_zones where id = v_id;
  if not found then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: the unpublished zone row was DELETED — must be soft (status only)';
  end if;
  if v_row.status <> 'inactive' or v_row.name <> 'CANARY-Zone-Unpub-Proof' or v_row.source <> 'drawn'
     or v_row.boundary is null then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: the unpublish did not preserve the row (%, %, %)',
      v_row.status, v_row.name, v_row.source;
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_OWNER_UNPUBLISHES';
end $$;

-- ── PROOF 8 — the unpublished canary is GONE from the player read AND from interception at once ─────
do $$
declare v_id uuid; v_read jsonb; v_hit boolean;
begin
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-Unpub-Proof';
  -- pirate_intercept_enabled is still lit (PROOF 2). The canary must NOT be returned now.
  v_read := public.get_danger_zones();
  if exists (select 1 from jsonb_array_elements(v_read) z where (z->>'id')::uuid = v_id) then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: an unpublished zone still appears in get_danger_zones: %', v_read;
  end if;
  -- interception no longer considers it (the same status='active' AND ST_Intersects leaf predicate).
  select exists (
    select 1 from public.danger_zones z
     where z.id = v_id and z.status = 'active'
       and ST_Intersects(z.boundary, ST_MakeLine(ST_MakePoint(700, -800), ST_MakePoint(900, -800)))
  ) into v_hit;
  if v_hit then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: an unpublished zone is still interception-relevant';
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_GONE_FROM_READS';
end $$;

-- ── PROOF 9 — the audit ledger: one create audit + one unpublish audit; unpublish carries BOTH snaps ─
do $$
declare v_id uuid; v_before jsonb; v_after jsonb; v_type text; v_ttype text; v_tid text; v_rev text; n int;
begin
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-Unpub-Proof';
  select count(*) into n from public.world_editor_audit where request_id = 'zoneunpub-create-canary-req-1';
  if n <> 1 then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: expected exactly one create audit, got %', n;
  end if;
  select before_snapshot, after_snapshot, command_type, target_type, target_id, source_revision
    into v_before, v_after, v_type, v_ttype, v_tid, v_rev
    from public.world_editor_audit where request_id = 'zoneunpub-owner-req-1';
  if v_type is distinct from 'zone_unpublish' or v_ttype is distinct from 'zone' or v_tid is distinct from v_id::text then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: unpublish audit command/target wrong (%, %, %)', v_type, v_ttype, v_tid;
  end if;
  if v_before is null or (v_before->>'status') <> 'active' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: unpublish before_snapshot must capture the active row: %', v_before;
  end if;
  if v_after is null or (v_after->>'status') <> 'inactive' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: unpublish after_snapshot must capture the inactive row: %', v_after;
  end if;
  if v_rev is distinct from 'zoneunpub-rev-1' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: unpublish audit source_revision not recorded (got %)', v_rev;
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_AUDIT';
end $$;

-- ── PROOF 10 — replaying the unpublish request_id is IDEMPOTENT (no second audit; same result) ──────
do $$
declare v_owner uuid; v_id uuid; r jsonb; n int;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-Unpub-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_unpublish('zoneunpub-owner-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-Unpub-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not true or (r->>'replayed')::boolean is not true or (r->>'code') <> 'duplicate_request' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: the unpublish replay was not idempotent: %', r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'zoneunpub-owner-req-1';
  if n <> 1 then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: the unpublish replay produced % audit rows (expected exactly 1)', n;
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 11 — a NEW request on the now-inactive canary is not_unpublishable/already_inactive ───────
do $$
declare v_owner uuid; v_id uuid; r jsonb;
begin
  select v into v_owner from pubuids where k = 'owner';
  select id into v_id from public.danger_zones where name = 'CANARY-Zone-Unpub-Proof';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.zone_unpublish('zoneunpub-already-req-1', jsonb_build_object(
         'target_id', v_id::text,
         'expected', jsonb_build_object('name','CANARY-Zone-Unpub-Proof','source','drawn','location_id', null)));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_unpublishable'
     or (r->'details'->0->>'code') <> 'already_inactive' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a re-unpublish of an inactive zone was not not_unpublishable/already_inactive: %', r;
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_ALREADY_INACTIVE';
end $$;

-- ── PROOF 12 — existing OTHER zones are untouched; the danger_zones + 0239 lockdowns are intact ─────
do $$
declare v_circle uuid; v_status text;
begin
  select v into v_circle from pubz where k = 'circle';
  -- the seeded circle zone (never a legal target) is still active/unchanged.
  select status into v_status from public.danger_zones where id = v_circle;
  if v_status <> 'active' then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: an unrelated existing zone changed status to %', v_status;
  end if;
  -- no client role gained a danger_zones write (the definer body is the only write path).
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'INSERT')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('anon', 'public.danger_zones', 'DELETE') then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a client role holds a danger_zones WRITE grant — the lockdown did not hold';
  end if;
  -- SELECT survives (the flag-gated read depends on it).
  if not has_table_privilege('anon', 'public.danger_zones', 'SELECT')
     or not has_table_privilege('authenticated', 'public.danger_zones', 'SELECT') then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a client role LOST SELECT on danger_zones';
  end if;
  -- the 0239 pirate-zone lockdown is intact (no client execute; service_role keeps owner-tooling).
  if has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_zone_delete(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: a client role regained EXECUTE on a pirate_zone write RPC — 0239 lockdown regressed';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.pirate_zone_delete(uuid)', 'execute') then
    raise exception 'ZONE UNPUBLISH PROOF FAIL: service_role LOST execute on a pirate_zone RPC — the 0239 owner-tooling path regressed';
  end if;
  raise notice 'PUBLISH_ZONE_UNPUB_PASS_EXISTING_UNCHANGED_AND_LOCKDOWN_INTACT';
end $$;

do $$ begin raise notice 'WORLD-EDITOR PUBLISH-ZONE-UNPUBLISH PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (the pirate_intercept_enabled flip included).
