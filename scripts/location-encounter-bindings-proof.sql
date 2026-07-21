-- LOCATION → ENCOUNTER BINDINGS — disposable apply-proof (run against a THROWAWAY local Supabase).
--
-- Proves migration 0259 (20260618000259_location_encounter_bindings.sql) after the FULL chain is applied
-- by `supabase start`: the three owner-gated write commands (location_encounter_binding_create/update/
-- set_active) author the ONE net-new DARK join table ONLY when ALL THREE fail-closed flags are ON
-- (enemy_content_registry_enabled AND encounter_authoring_enabled AND encounter_binding_authoring_enabled)
-- and the caller is the owner; they are idempotent on request_id, enforce optimistic revision, reject
-- invalid/inactive location + encounter references + out-of-range weight + duplicate bindings, write
-- exactly one world_editor_audit row per applied command, and NEVER expose a client table-write path. Also
-- proves the DEACTIVATION referential-integrity trigger on encounter_profiles and the DARK guarantee: the
-- combat/reward config is unchanged and NO combat function body reads the new table.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag left
-- flipped, no row kept. The owner it "seeds" is a synthetic auth.users row created HERE. NEVER point this
-- at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER + NON-OWNER, active/locked locations, active/inactive encounter profiles ─
create temp table lebids(k text primary key, v uuid) on commit drop;
insert into lebids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'lebact.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from lebids;

insert into public.app_owners(user_id) select v from lebids where k = 'owner';

-- direct-inserted fixtures (superuser; bypasses RLS/grants) — an isolated world sandbox for the proof.
create temp table lebfx(k text primary key, v uuid) on commit drop;
do $$
declare v_zone uuid; v_la uuid; v_la2 uuid; v_ll uuid; v_ep uuid; v_epoff uuid;
begin
  select id into v_zone from public.zones limit 1;
  if v_zone is null then raise exception 'LEB PROOF FAIL: no seeded zone to anchor proof locations'; end if;

  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'LEB Proof Loc Active', 'pirate_hunt', 900, 900, 10, 'active') returning id into v_la;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'LEB Proof Loc Active 2', 'pirate_hunt', 901, 901, 10, 'active') returning id into v_la2;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'LEB Proof Loc Locked', 'pirate_hunt', 902, 902, 10, 'locked') returning id into v_ll;

  insert into public.encounter_profiles (key, display_name) values ('leb_proof_ep','LEB Proof EP') returning id into v_ep;
  insert into public.encounter_profiles (key, display_name, active) values ('leb_proof_ep_off','LEB Proof EP Off', false) returning id into v_epoff;

  insert into lebfx values ('loc_active', v_la), ('loc_active2', v_la2), ('loc_locked', v_ll),
                          ('ep', v_ep), ('ep_off', v_epoff);
end $$;

-- ── PROOF 1 — TRI-FLAG: owner denied under EACH off-combo (reject-before-any-read) ──────────────────
-- (a) all three flags seeded false → owner denied.
do $$
declare v_owner uuid; v_la uuid; v_ep uuid; r jsonb; n int;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_encounter_binding_create('leb-flagoff-1', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', v_ep::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_enabled' then
    raise exception 'LEB PROOF FAIL: owner not rejected not_enabled while ALL flags off: %', r;
  end if;
  select count(*) into n from public.location_encounter_bindings where location_id = v_la and encounter_profile_id = v_ep;
  if n <> 0 then raise exception 'LEB PROOF FAIL: an all-flags-off call wrote a binding row'; end if;
  select count(*) into n from public.world_editor_audit where request_id = 'leb-flagoff-1';
  if n <> 0 then raise exception 'LEB PROOF FAIL: an all-flags-off call wrote an audit row'; end if;
end $$;

-- (b) E2 on, E1 off, E0 off → denied (upstream E1 dark).
update public.game_config set value = 'true'::jsonb where key = 'encounter_binding_authoring_enabled';
do $$
declare v_owner uuid; v_la uuid; v_ep uuid; r jsonb;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_encounter_binding_create('leb-flagoff-2', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', v_ep::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_enabled' then
    raise exception 'LEB PROOF FAIL: owner not rejected not_enabled with E2 on but E1 off: %', r;
  end if;
end $$;

-- (c) E2 on, E1 on, E0 off → denied (upstream E0 dark).
update public.game_config set value = 'true'::jsonb where key = 'encounter_authoring_enabled';
do $$
declare v_owner uuid; v_la uuid; v_ep uuid; r jsonb;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_encounter_binding_create('leb-flagoff-3', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', v_ep::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_enabled' then
    raise exception 'LEB PROOF FAIL: owner not rejected not_enabled with E2+E1 on but E0 off: %', r;
  end if;
end $$;

-- (d) E0 on, E1 on, E2 off → denied (this slice's own gate off).
update public.game_config set value = 'true'::jsonb  where key = 'enemy_content_registry_enabled';
update public.game_config set value = 'false'::jsonb where key = 'encounter_binding_authoring_enabled';
do $$
declare v_owner uuid; v_la uuid; v_ep uuid; r jsonb;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_encounter_binding_create('leb-flagoff-4', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', v_ep::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_enabled' then
    raise exception 'LEB PROOF FAIL: owner not rejected not_enabled with E0+E1 on but E2 off: %', r;
  end if;
  raise notice 'LEB_PASS_FLAG_OFF_DENIED';
end $$;

-- ── flip ALL THREE flags ON inside the txn (owner succeeds ONLY when all true) ───────────────────────
update public.game_config set value = 'true'::jsonb where key = 'enemy_content_registry_enabled';
update public.game_config set value = 'true'::jsonb where key = 'encounter_authoring_enabled';
update public.game_config set value = 'true'::jsonb where key = 'encounter_binding_authoring_enabled';

-- ── PROOF 2 — ANONYMOUS caller rejected not_authenticated, zero side effects ─────────────────────────
do $$
declare v_la uuid; v_ep uuid; r jsonb; n int;
begin
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.location_encounter_binding_create('leb-anon-1', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', v_ep::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'LEB PROOF FAIL: anon not rejected not_authenticated: %', r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'leb-anon-1';
  if n <> 0 then raise exception 'LEB PROOF FAIL: an anon call wrote an audit row'; end if;
  raise notice 'LEB_PASS_ANON_DENIED';
end $$;

-- ── PROOF 3 — NON-OWNER authenticated caller rejected not_authorized, zero side effects ─────────────
do $$
declare v_no uuid; v_la uuid; v_ep uuid; r jsonb; n int;
begin
  select v into v_no from lebids where k = 'nonowner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.location_encounter_binding_create('leb-nonowner-1', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', v_ep::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'LEB PROOF FAIL: non-owner not rejected not_authorized: %', r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'leb-nonowner-1';
  if n <> 0 then raise exception 'LEB PROOF FAIL: a non-owner call wrote an audit row'; end if;
  raise notice 'LEB_PASS_NONOWNER_DENIED';
end $$;

-- ── PROOF 4 — OWNER CREATE: row at revision 1, active; exactly one audit row with after_snapshot ─────
do $$
declare v_owner uuid; v_la uuid; v_ep uuid; r jsonb; v_row record; v_after jsonb; n int;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_encounter_binding_create('leb-create-1', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', v_ep::text, 'weight', 1, 'source_revision','leb-rev-1'));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' then
    raise exception 'LEB PROOF FAIL: owner create not ok: %', r;
  end if;
  select * into v_row from public.location_encounter_bindings where location_id = v_la and encounter_profile_id = v_ep;
  if v_row.revision <> 1 or v_row.active is not true or v_row.weight <> 1 then
    raise exception 'LEB PROOF FAIL: created binding wrong (rev %, active %, weight %)', v_row.revision, v_row.active, v_row.weight;
  end if;
  if (r->'result'->>'id') <> v_row.id::text then
    raise exception 'LEB PROOF FAIL: create result id does not match the row id';
  end if;
  select after_snapshot into v_after from public.world_editor_audit where request_id = 'leb-create-1';
  if v_after is null or (v_after->>'location_id') <> v_la::text or (v_after->>'encounter_profile_id') <> v_ep::text
     or not (v_after ? 'weight') then
    raise exception 'LEB PROOF FAIL: create audit after_snapshot malformed: %', v_after;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'leb-create-1';
  if n <> 1 then raise exception 'LEB PROOF FAIL: create wrote % audit rows (expected 1)', n; end if;
  raise notice 'LEB_PASS_OWNER_CREATE';
end $$;

-- ── PROOF 5 — OWNER UPDATE: weight 1 → 5, revision bump, before.weight=1 / after.weight=5 ────────────
do $$
declare v_owner uuid; v_la uuid; v_ep uuid; v_bid uuid; r jsonb; v_row record; v_before jsonb; v_after jsonb;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  select id into v_bid from public.location_encounter_bindings where location_id = v_la and encounter_profile_id = v_ep;
  r := public.location_encounter_binding_update('leb-update-1', jsonb_build_object(
         'target_id', v_bid::text, 'expected_revision', 1, 'weight', 5, 'notes', 'bumped'));
  if (r->>'ok')::boolean is not true or (r->'result'->>'updated') <> 'true' then
    raise exception 'LEB PROOF FAIL: owner update not ok: %', r;
  end if;
  select * into v_row from public.location_encounter_bindings where id = v_bid;
  if v_row.revision <> 2 or v_row.weight <> 5 or v_row.notes <> 'bumped' then
    raise exception 'LEB PROOF FAIL: update did not apply (rev %, weight %, notes %)', v_row.revision, v_row.weight, v_row.notes;
  end if;
  select before_snapshot, after_snapshot into v_before, v_after from public.world_editor_audit where request_id = 'leb-update-1';
  if (v_before->>'weight') <> '1' or (v_after->>'weight') <> '5'
     or (v_before->>'revision') <> '1' or (v_after->>'revision') <> '2' then
    raise exception 'LEB PROOF FAIL: update audit before/after weight or revision wrong (b.weight %, a.weight %)',
      v_before->>'weight', v_after->>'weight';
  end if;
  raise notice 'LEB_PASS_OWNER_UPDATE';
end $$;

-- ── PROOF 6 — OWNER SET_ACTIVE false: soft-disable; the binding row SURVIVES (no hard delete) ────────
do $$
declare v_owner uuid; v_la uuid; v_ep uuid; v_bid uuid; r jsonb; v_row record; n int;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  select id into v_bid from public.location_encounter_bindings where location_id = v_la and encounter_profile_id = v_ep;
  r := public.location_encounter_binding_set_active('leb-setactive-1', jsonb_build_object(
         'target_id', v_bid::text, 'expected_revision', 2, 'active', false));
  if (r->>'ok')::boolean is not true or (r->'result'->>'active_set') <> 'true' or (r->'result'->>'active') <> 'false' then
    raise exception 'LEB PROOF FAIL: owner set_active(false) not ok: %', r;
  end if;
  select * into v_row from public.location_encounter_bindings where id = v_bid;
  if v_row.active is not false or v_row.revision <> 3 then
    raise exception 'LEB PROOF FAIL: set_active did not soft-disable + bump (active %, rev %)', v_row.active, v_row.revision;
  end if;
  select count(*) into n from public.location_encounter_bindings where id = v_bid;
  if n <> 1 then raise exception 'LEB PROOF FAIL: set_active removed the row (got %, expected 1)', n; end if;
  raise notice 'LEB_PASS_OWNER_SET_ACTIVE';
end $$;

-- ── PROOF 7 — repeated request_id is IDEMPOTENT (one apply; one audit; no second row) ────────────────
do $$
declare v_owner uuid; v_la2 uuid; v_ep uuid; r1 jsonb; r2 jsonb; n int;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la2 from lebfx where k = 'loc_active2';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r1 := public.location_encounter_binding_create('leb-idem-1', jsonb_build_object(
          'location_id', v_la2::text, 'encounter_profile_id', v_ep::text, 'weight', 3));
  -- replay the SAME request_id with a DIFFERENT payload (weight 9) — must NOT re-apply.
  r2 := public.location_encounter_binding_create('leb-idem-1', jsonb_build_object(
          'location_id', v_la2::text, 'encounter_profile_id', v_ep::text, 'weight', 9));
  if (r1->>'ok')::boolean is not true then
    raise exception 'LEB PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'LEB PROOF FAIL: replay was not an idempotent duplicate_request: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'LEB PROOF FAIL: replay result differs (% vs %)', r2->'result', r1->'result';
  end if;
  select weight into n from public.location_encounter_bindings where location_id = v_la2 and encounter_profile_id = v_ep;
  if n <> 3 then raise exception 'LEB PROOF FAIL: idempotent replay changed the weight (got %, expected 3)', n; end if;
  select count(*) into n from public.world_editor_audit where request_id = 'leb-idem-1';
  if n <> 1 then raise exception 'LEB PROOF FAIL: idempotent create produced % audit rows (expected 1)', n; end if;
  raise notice 'LEB_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 8 — STALE revision is rejected (stale_revision), nothing written ──────────────────────────
do $$
declare v_owner uuid; v_la uuid; v_ep uuid; v_bid uuid; r jsonb; v_row record;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  select id into v_bid from public.location_encounter_bindings where location_id = v_la and encounter_profile_id = v_ep;
  -- the binding is at revision 3 (create → update → set_active); pass a WRONG expected_revision.
  r := public.location_encounter_binding_update('leb-stale-1', jsonb_build_object(
         'target_id', v_bid::text, 'expected_revision', 99, 'weight', 7));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or (r->'details'->0->>'code') <> 'source_changed' or (r->'details'->0->>'field') <> 'revision' then
    raise exception 'LEB PROOF FAIL: stale expected_revision not rejected precisely: %', r;
  end if;
  select * into v_row from public.location_encounter_bindings where id = v_bid;
  if v_row.revision <> 3 or v_row.weight <> 5 then
    raise exception 'LEB PROOF FAIL: a stale-rejected update WROTE (rev %, weight %)', v_row.revision, v_row.weight;
  end if;
  if exists (select 1 from public.world_editor_audit where request_id = 'leb-stale-1') then
    raise exception 'LEB PROOF FAIL: a stale-rejected update wrote an audit row';
  end if;
  raise notice 'LEB_PASS_STALE_REVISION_REJECTED';
end $$;

-- ── PROOF 9 — INVALID/INELIGIBLE references rejected (all four codes), nothing written ───────────────
do $$
declare v_owner uuid; v_la uuid; v_ll uuid; v_ep uuid; v_epoff uuid; r jsonb; n int;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ll from lebfx where k = 'loc_locked';
  select v into v_ep from lebfx where k = 'ep';
  select v into v_epoff from lebfx where k = 'ep_off';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- (a) invalid_location: a well-formed uuid referencing no location.
  r := public.location_encounter_binding_create('leb-badloc-1', jsonb_build_object(
         'location_id', gen_random_uuid()::text, 'encounter_profile_id', v_ep::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_location')) then
    raise exception 'LEB PROOF FAIL: bogus location not rejected invalid_location: %', r;
  end if;

  -- (b) location_inactive: an EXISTING location whose status <> 'active' (locked).
  r := public.location_encounter_binding_create('leb-locinactive-1', jsonb_build_object(
         'location_id', v_ll::text, 'encounter_profile_id', v_ep::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','location_inactive')) then
    raise exception 'LEB PROOF FAIL: locked location not rejected location_inactive: %', r;
  end if;

  -- (c) invalid_encounter_ref: a well-formed uuid referencing no encounter profile.
  r := public.location_encounter_binding_create('leb-badenc-1', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', gen_random_uuid()::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_encounter_ref')) then
    raise exception 'LEB PROOF FAIL: bogus encounter ref not rejected invalid_encounter_ref: %', r;
  end if;

  -- (d) encounter_inactive: an EXISTING but inactive encounter profile (no active referrer).
  r := public.location_encounter_binding_create('leb-encinactive-1', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', v_epoff::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','encounter_inactive')) then
    raise exception 'LEB PROOF FAIL: inactive encounter not rejected encounter_inactive: %', r;
  end if;

  select count(*) into n from public.world_editor_audit
    where request_id in ('leb-badloc-1','leb-locinactive-1','leb-badenc-1','leb-encinactive-1');
  if n <> 0 then raise exception 'LEB PROOF FAIL: an invalid-reference create wrote % audit row(s)', n; end if;
  raise notice 'LEB_PASS_INVALID_REFERENCE_REJECTED';
end $$;

-- ── PROOF 10 — BOUNDED weight rejected (0 and 2000 ⇒ invalid_weight), nothing written ───────────────
do $$
declare v_owner uuid; v_la2 uuid; v_ep uuid; r jsonb; n int;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la2 from lebfx where k = 'loc_active2';   -- pair not yet valid-created below the bound reject
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- weight 0 ⇒ invalid_weight (loc_active is the valid location; only weight is out of range).
  r := public.location_encounter_binding_create('leb-w0', jsonb_build_object(
         'location_id', (select v from lebfx where k='loc_active')::text, 'encounter_profile_id', v_ep::text, 'weight', 0));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_weight')) then
    raise exception 'LEB PROOF FAIL: weight 0 not rejected invalid_weight: %', r;
  end if;
  -- weight 2000 ⇒ invalid_weight.
  r := public.location_encounter_binding_create('leb-w2000', jsonb_build_object(
         'location_id', (select v from lebfx where k='loc_active')::text, 'encounter_profile_id', v_ep::text, 'weight', 2000));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_weight')) then
    raise exception 'LEB PROOF FAIL: weight 2000 not rejected invalid_weight: %', r;
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('leb-w0','leb-w2000');
  if n <> 0 then raise exception 'LEB PROOF FAIL: a bounded-weight reject wrote % audit row(s)', n; end if;
  raise notice 'LEB_PASS_BOUNDED_NUMERIC_REJECTED';
end $$;

-- ── PROOF 11 — DUPLICATE binding rejected (conflict / duplicate_binding) ─────────────────────────────
-- loc_active ↔ ep already exists (PROOF 4, now soft-disabled). Re-creating the SAME pair ⇒ unique
-- violation surfaced as a typed conflict/duplicate_binding (the unique key ignores active).
do $$
declare v_owner uuid; v_la uuid; v_ep uuid; r jsonb; n int;
begin
  select v into v_owner from lebids where k = 'owner';
  select v into v_la from lebfx where k = 'loc_active';
  select v into v_ep from lebfx where k = 'ep';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.location_encounter_binding_create('leb-dup-1', jsonb_build_object(
         'location_id', v_la::text, 'encounter_profile_id', v_ep::text));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'conflict'
     or (r->'details'->0->>'code') <> 'duplicate_binding' or (r->'details'->0->>'field') <> 'encounter_profile_id' then
    raise exception 'LEB PROOF FAIL: duplicate binding not rejected conflict/duplicate_binding: %', r;
  end if;
  select count(*) into n from public.location_encounter_bindings where location_id = v_la and encounter_profile_id = v_ep;
  if n <> 1 then raise exception 'LEB PROOF FAIL: a duplicate create produced a second binding row (got %)', n; end if;
  if exists (select 1 from public.world_editor_audit where request_id = 'leb-dup-1') then
    raise exception 'LEB PROOF FAIL: a duplicate-rejected create wrote an audit row';
  end if;
  raise notice 'LEB_PASS_DUPLICATE_BINDING_REJECTED';
end $$;

-- ── PROOF 12 — DEACTIVATION trigger: BLOCK deactivating an encounter profile with an ACTIVE binding;
-- SUCCEED after the binding is deactivated/removed ──────────────────────────────────────────────────
do $$
declare v_zone uuid; v_gl uuid; v_ge uuid; blocked boolean;
begin
  select id into v_zone from public.zones limit 1;
  -- an isolated ACTIVE chain: a fresh location + a fresh active encounter profile + an ACTIVE binding.
  insert into public.locations (zone_id, name, location_type, x, y, status)
    values (v_zone, 'LEB Guard Loc', 'pirate_hunt', 903, 903, 'active') returning id into v_gl;
  insert into public.encounter_profiles (key, display_name, active) values ('leb_guard_ep','LEB Guard EP', true) returning id into v_ge;
  insert into public.location_encounter_bindings (location_id, encounter_profile_id, weight, active)
    values (v_gl, v_ge, 1, true);

  -- (1) encounter-profile deactivation BLOCKED while an ACTIVE binding references it.
  blocked := false;
  begin update public.encounter_profiles set active = false where id = v_ge; exception when others then blocked := true; end;
  if not blocked then raise exception 'LEB PROOF FAIL: encounter deactivation was NOT blocked while referenced by an active binding'; end if;

  -- (2) deactivate the binding, then encounter deactivation SUCCEEDS.
  update public.location_encounter_bindings set active = false where location_id = v_gl and encounter_profile_id = v_ge;
  update public.encounter_profiles set active = false where id = v_ge;
  if (select active from public.encounter_profiles where id = v_ge) is not false then
    raise exception 'LEB PROOF FAIL: encounter deactivation did not succeed after the binding was deactivated';
  end if;
  raise notice 'LEB_PASS_DEACTIVATION_GUARD';
end $$;

-- ── PROOF 13 — audit exposure is INTENTIONAL: owner sees after; actor redacted, is_owner true ───────
do $$
declare v_owner uuid; r jsonb; v_item jsonb;
begin
  select v into v_owner from lebids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.world_editor_audit_list(jsonb_build_object('request_id','leb-create-1'));
  if (r->>'ok')::boolean is not true or jsonb_typeof(r->'items') <> 'array' or jsonb_array_length(r->'items') <> 1 then
    raise exception 'LEB PROOF FAIL: audit reader did not return the create row: %', r;
  end if;
  v_item := r->'items'->0;
  -- INTENDED: the after snapshot IS returned to the owner (authoring data the owner wrote).
  if not (v_item->'after' ? 'weight') or (v_item->'after'->>'encounter_profile_id') is null then
    raise exception 'LEB PROOF FAIL: after snapshot is NOT owner-visible (intended exposure regressed): %', v_item;
  end if;
  -- REDACTED: never the raw actor UUID; actor_is_owner reported; redactions lists the actor withholding.
  if (v_item ? 'actor') then
    raise exception 'LEB PROOF FAIL: the raw actor UUID was shipped by the audit reader: %', v_item;
  end if;
  if (v_item->>'actor_is_owner') <> 'true' or not (v_item->'redactions') @> jsonb_build_array('actor') then
    raise exception 'LEB PROOF FAIL: reader did not report actor_is_owner + the actor redaction: %', v_item;
  end if;
  raise notice 'LEB_PASS_AUDIT_EXPOSURE_INTENTIONAL';
end $$;

-- ── PROOF 14 — DIRECT client writes DENIED on the binding table; public SELECT present ──────────────
do $$
begin
  if has_table_privilege('authenticated', 'public.location_encounter_bindings', 'INSERT')
     or has_table_privilege('authenticated', 'public.location_encounter_bindings', 'UPDATE')
     or has_table_privilege('authenticated', 'public.location_encounter_bindings', 'DELETE')
     or has_table_privilege('anon', 'public.location_encounter_bindings', 'INSERT')
     or has_table_privilege('anon', 'public.location_encounter_bindings', 'UPDATE')
     or has_table_privilege('anon', 'public.location_encounter_bindings', 'DELETE') then
    raise exception 'LEB PROOF FAIL: a client role holds a direct write grant on location_encounter_bindings';
  end if;
  if not has_table_privilege('authenticated', 'public.location_encounter_bindings', 'SELECT')
     or not has_table_privilege('anon', 'public.location_encounter_bindings', 'SELECT') then
    raise exception 'LEB PROOF FAIL: public SELECT on location_encounter_bindings was lost';
  end if;
  raise notice 'LEB_PASS_DIRECT_WRITE_DENIED';
end $$;

-- ── PROOF 15 — DARK guarantee: no combat body reads the binding table; combat tunables unchanged ────
do $$
declare v_rec record;
begin
  if not exists (select 1 from pg_proc where proname = 'process_combat_ticks' and pronamespace = 'public'::regnamespace)
     or not exists (select 1 from pg_proc where proname = 'combat_create_group_encounter' and pronamespace = 'public'::regnamespace)
     or not exists (select 1 from pg_proc where proname = 'pirate_intercept_evaluate_leg' and pronamespace = 'public'::regnamespace)
     or not exists (select 1 from pg_proc where proname = 'reward_grant' and pronamespace = 'public'::regnamespace) then
    raise exception 'LEB PROOF FAIL: a combat/reward function is missing — surface disturbed';
  end if;
  if public.cfg_num('enemy_synthetic_max_units') is distinct from 6 then
    raise exception 'LEB PROOF FAIL: enemy_synthetic_max_units is % (expected 6)', public.cfg_num('enemy_synthetic_max_units');
  end if;
  if public.cfg_num('reward_multiplier') is distinct from 1.0 then
    raise exception 'LEB PROOF FAIL: reward_multiplier is % (expected 1.0)', public.cfg_num('reward_multiplier');
  end if;
  for v_rec in
    select oid, proname from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in ('process_combat_ticks','combat_create_group_encounter','pirate_intercept_evaluate_leg','reward_grant')
  loop
    if pg_get_functiondef(v_rec.oid) ilike '%location_encounter_bindings%' then
      raise exception 'LEB PROOF FAIL: % references location_encounter_bindings — the DARK guarantee is broken', v_rec.proname;
    end if;
  end loop;
  raise notice 'LEB_PASS_DARK_GUARANTEE';
end $$;

-- ── PROOF 16 — NO delete RPC exists for this surface ────────────────────────────────────────────────
do $$
begin
  if to_regprocedure('public.location_encounter_binding_delete(text,jsonb)') is not null then
    raise exception 'LEB PROOF FAIL: a *_delete RPC exists — this surface must have NO delete command';
  end if;
  raise notice 'LEB_PASS_NO_DELETE_RPC';
end $$;

do $$ begin raise notice 'LOCATION → ENCOUNTER BINDINGS PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (all three flag flips included).
