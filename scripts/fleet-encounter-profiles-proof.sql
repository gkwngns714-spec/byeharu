-- FLEET TEMPLATES + ENCOUNTER PROFILES — disposable apply-proof (run against a THROWAWAY local Supabase).
--
-- Proves migration 0258 (20260618000258_fleet_templates_encounter_profiles.sql) after the FULL chain is
-- applied by `supabase start`: the six owner-gated write commands (enemy_fleet_template_create/update/
-- set_active + encounter_profile_create/update/set_active) author the four net-new DARK tables ONLY when
-- BOTH fail-closed flags are ON (enemy_content_registry_enabled AND encounter_authoring_enabled) and the
-- caller is the owner; members are REPLACE-ALL keyed to the parent revision; they are idempotent on
-- request_id, enforce optimistic revision, reject invalid/inactive references + out-of-range numerics +
-- empty/duplicate members, write exactly one world_editor_audit row per applied command, and NEVER expose
-- a client table-write path. Also proves the DEACTIVATION referential-integrity triggers and the DARK
-- guarantee: existing combat/reward config is unchanged and NO combat function body reads the new tables.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag left
-- flipped, no row kept. The owner it "seeds" is a synthetic auth.users row created HERE. NEVER point this
-- at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER + a synthetic NON-OWNER ────────────────────────────────────────────
create temp table feids(k text primary key, v uuid) on commit drop;
insert into feids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'feact.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from feids;

insert into public.app_owners(user_id) select v from feids where k = 'owner';

-- ── PROOF 1 — DUAL-FLAG OFF: owner denied under EACH single-flag-off combo (reject-before-any-read) ──
-- both flags seeded false → owner denied.
do $$
declare v_owner uuid; v_light uuid; r jsonb; n int;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.enemy_fleet_template_create('fe-flagoff-1', jsonb_build_object(
         'key','proof_flagoff','display_name','Nope',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text, 'min_count',1,'max_count',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_enabled' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: owner not rejected not_enabled while BOTH flags off: %', r;
  end if;
  if exists (select 1 from public.enemy_fleet_templates where key = 'proof_flagoff') then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: a both-flags-off call wrote a row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'fe-flagoff-1';
  if n <> 0 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: a both-flags-off call wrote an audit row'; end if;
end $$;

-- E1 flag ON, E0 flag OFF → owner still denied (E1 references E0's dark tables).
update public.game_config set value = 'true'::jsonb where key = 'encounter_authoring_enabled';
do $$
declare v_owner uuid; v_light uuid; r jsonb;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.enemy_fleet_template_create('fe-flagoff-2', jsonb_build_object(
         'key','proof_flagoff','display_name','Nope',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text, 'min_count',1,'max_count',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_enabled' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: owner not rejected not_enabled with E1 on but E0 off: %', r;
  end if;
end $$;

-- E1 flag OFF, E0 flag ON → owner still denied (E1 authoring gate itself is off).
update public.game_config set value = 'false'::jsonb where key = 'encounter_authoring_enabled';
update public.game_config set value = 'true'::jsonb  where key = 'enemy_content_registry_enabled';
do $$
declare v_owner uuid; v_light uuid; r jsonb;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.enemy_fleet_template_create('fe-flagoff-3', jsonb_build_object(
         'key','proof_flagoff','display_name','Nope',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text, 'min_count',1,'max_count',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_enabled' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: owner not rejected not_enabled with E0 on but E1 off: %', r;
  end if;
  raise notice 'FLEET_ENCOUNTER_PASS_FLAG_OFF_DENIED';
end $$;

-- ── flip BOTH flags ON inside the txn (owner succeeds ONLY when both true) ───────────────────────────
update public.game_config set value = 'true'::jsonb where key = 'encounter_authoring_enabled';
update public.game_config set value = 'true'::jsonb where key = 'enemy_content_registry_enabled';

-- ── PROOF 2 — ANONYMOUS caller rejected not_authenticated (both flags now on), zero side effects ─────
do $$
declare v_light uuid; r jsonb; n int;
begin
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.enemy_fleet_template_create('fe-anon-1', jsonb_build_object(
         'key','proof_anon','display_name','Nope',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text, 'min_count',1,'max_count',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: anon not rejected not_authenticated: %', r;
  end if;
  if exists (select 1 from public.enemy_fleet_templates where key = 'proof_anon') then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: an anon call wrote a row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'fe-anon-1';
  if n <> 0 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: an anon call wrote an audit row'; end if;
  raise notice 'FLEET_ENCOUNTER_PASS_ANON_DENIED';
end $$;

-- ── PROOF 3 — NON-OWNER authenticated caller rejected not_authorized, zero side effects ─────────────
do $$
declare v_no uuid; v_light uuid; r jsonb; n int;
begin
  select v into v_no from feids where k = 'nonowner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.enemy_fleet_template_create('fe-nonowner-1', jsonb_build_object(
         'key','proof_nonowner','display_name','Nope',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text, 'min_count',1,'max_count',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: non-owner not rejected not_authorized: %', r;
  end if;
  if exists (select 1 from public.enemy_fleet_templates where key = 'proof_nonowner') then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: a non-owner call wrote a row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'fe-nonowner-1';
  if n <> 0 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: a non-owner call wrote an audit row'; end if;
  raise notice 'FLEET_ENCOUNTER_PASS_NONOWNER_DENIED';
end $$;

-- ── PROOF 4 — OWNER CREATE: fleet (parent + 1 member) then encounter; each one audit + after.members ─
do $$
declare v_owner uuid; v_light uuid; v_fleet uuid; r jsonb; v_row record; v_after jsonb; n int;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.enemy_fleet_template_create('fe-create-ft-1', jsonb_build_object(
         'key','proof_fleet','display_name','Proof Fleet','source_revision','fe-rev-ft',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text, 'min_count',1,'max_count',1,'weight',1,'elite_chance',0))));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' or (r->'result'->>'key') <> 'proof_fleet' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: owner fleet create not ok: %', r;
  end if;
  select * into v_row from public.enemy_fleet_templates where key = 'proof_fleet';
  if v_row.revision <> 1 or v_row.active is not true then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: created fleet has wrong revision/active (% / %)', v_row.revision, v_row.active;
  end if;
  select count(*) into n from public.enemy_fleet_template_members where fleet_template_id = v_row.id;
  if n <> 1 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: fleet create wrote % member rows (expected 1)', n; end if;
  select after_snapshot into v_after from public.world_editor_audit where request_id = 'fe-create-ft-1';
  if v_after is null or (v_after->>'key') <> 'proof_fleet'
     or jsonb_typeof(v_after->'members') <> 'array' or jsonb_array_length(v_after->'members') <> 1 then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: fleet create audit after_snapshot.members malformed: %', v_after;
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'fe-create-ft-1';
  if n <> 1 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: fleet create wrote % audit rows (expected 1)', n; end if;

  select id into v_fleet from public.enemy_fleet_templates where key = 'proof_fleet';
  r := public.encounter_profile_create('fe-create-ep-1', jsonb_build_object(
         'key','proof_encounter','display_name','Proof Encounter',
         'difficulty',1,'active_encounter_cap',1,'cooldown_seconds',0,
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', v_fleet::text, 'weight',1))));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' or (r->'result'->>'key') <> 'proof_encounter' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: owner encounter create not ok: %', r;
  end if;
  select * into v_row from public.encounter_profiles where key = 'proof_encounter';
  if v_row.revision <> 1 or v_row.difficulty <> 1 or v_row.active_encounter_cap <> 1 or v_row.reward_override_id is not null then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: created encounter row malformed';
  end if;
  select count(*) into n from public.encounter_profile_members where encounter_profile_id = v_row.id;
  if n <> 1 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: encounter create wrote % member rows (expected 1)', n; end if;
  select after_snapshot into v_after from public.world_editor_audit where request_id = 'fe-create-ep-1';
  if v_after is null or (v_after->>'key') <> 'proof_encounter'
     or jsonb_typeof(v_after->'members') <> 'array' or jsonb_array_length(v_after->'members') <> 1 then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: encounter create audit after_snapshot.members malformed: %', v_after;
  end if;
  raise notice 'FLEET_ENCOUNTER_PASS_OWNER_CREATE';
end $$;

-- ── PROOF 5 — OWNER UPDATE: REPLACE-ALL 1 member → 2, revision bump, before.members=1/after.members=2 ─
do $$
declare v_owner uuid; v_light uuid; v_heavy uuid; r jsonb; v_row record; v_before jsonb; v_after jsonb; n int;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  select id into v_heavy from public.enemy_archetypes where key = 'pirate_heavy';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.enemy_fleet_template_update('fe-update-ft-1', jsonb_build_object(
         'target_id','proof_fleet','expected_revision',1,'display_name','Proof Fleet v2',
         'members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',2),
           jsonb_build_object('enemy_archetype_id', v_heavy::text,'min_count',1,'max_count',1))));
  if (r->>'ok')::boolean is not true or (r->'result'->>'updated') <> 'true' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: owner fleet update not ok: %', r;
  end if;
  select * into v_row from public.enemy_fleet_templates where key = 'proof_fleet';
  if v_row.revision <> 2 or v_row.display_name <> 'Proof Fleet v2' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: update did not bump revision to 2 / apply fields (rev %, name %)', v_row.revision, v_row.display_name;
  end if;
  select count(*) into n from public.enemy_fleet_template_members where fleet_template_id = v_row.id;
  if n <> 2 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: REPLACE-ALL did not land 2 members (got %)', n; end if;
  select before_snapshot, after_snapshot into v_before, v_after from public.world_editor_audit where request_id = 'fe-update-ft-1';
  if jsonb_array_length(v_before->'members') <> 1 or jsonb_array_length(v_after->'members') <> 2
     or (v_before->>'revision') <> '1' or (v_after->>'revision') <> '2' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: update audit before/after members or revision wrong (b.members %, a.members %)',
      jsonb_array_length(v_before->'members'), jsonb_array_length(v_after->'members');
  end if;
  raise notice 'FLEET_ENCOUNTER_PASS_OWNER_UPDATE';
end $$;

-- ── PROOF 6 — OWNER SET_ACTIVE false on the encounter: soft-disable; rows SURVIVE (no hard delete) ───
do $$
declare v_owner uuid; r jsonb; v_row record; n int;
begin
  select v into v_owner from feids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.encounter_profile_set_active('fe-setactive-ep-1', jsonb_build_object(
         'target_id','proof_encounter','expected_revision',1,'active', false));
  if (r->>'ok')::boolean is not true or (r->'result'->>'active_set') <> 'true' or (r->'result'->>'active') <> 'false' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: owner encounter set_active(false) not ok: %', r;
  end if;
  select * into v_row from public.encounter_profiles where key = 'proof_encounter';
  if v_row.active is not false or v_row.revision <> 2 then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: set_active did not soft-disable + bump (active %, rev %)', v_row.active, v_row.revision;
  end if;
  select count(*) into n from public.encounter_profile_members where encounter_profile_id = v_row.id;
  if n <> 1 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: set_active removed member rows (got %, expected 1)', n; end if;
  raise notice 'FLEET_ENCOUNTER_PASS_OWNER_SET_ACTIVE';
end $$;

-- ── PROOF 7 — repeated request_id is IDEMPOTENT (one apply; one audit; members NOT duplicated) ───────
do $$
declare v_owner uuid; v_light uuid; v_heavy uuid; r1 jsonb; r2 jsonb; n int; v_id uuid;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  select id into v_heavy from public.enemy_archetypes where key = 'pirate_heavy';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r1 := public.enemy_fleet_template_create('fe-idem-1', jsonb_build_object(
          'key','proof_idem','display_name','Idem A',
          'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',1))));
  -- replay the SAME request_id with a DIFFERENT payload (2 members) — must NOT re-apply.
  r2 := public.enemy_fleet_template_create('fe-idem-1', jsonb_build_object(
          'key','proof_idem_DIFFERENT','display_name','Idem B',
          'members', jsonb_build_array(
            jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',1),
            jsonb_build_object('enemy_archetype_id', v_heavy::text,'min_count',1,'max_count',1))));
  if (r1->>'ok')::boolean is not true then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: replay was not an idempotent duplicate_request: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: replay result differs (% vs %)', r2->'result', r1->'result';
  end if;
  if exists (select 1 from public.enemy_fleet_templates where key = 'proof_idem_DIFFERENT') then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: the replayed (different) payload created a second row';
  end if;
  select id into v_id from public.enemy_fleet_templates where key = 'proof_idem';
  select count(*) into n from public.enemy_fleet_template_members where fleet_template_id = v_id;
  if n <> 1 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: idempotent replay duplicated members (got %, expected 1)', n; end if;
  select count(*) into n from public.world_editor_audit where request_id = 'fe-idem-1';
  if n <> 1 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: idempotent create produced % audit rows (expected 1)', n; end if;
  raise notice 'FLEET_ENCOUNTER_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 8 — STALE revision is rejected (stale_revision), nothing written ──────────────────────────
do $$
declare v_owner uuid; v_light uuid; r jsonb; v_row record;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- proof_fleet is at revision 2 (create → update); pass a WRONG expected_revision.
  r := public.enemy_fleet_template_update('fe-stale-1', jsonb_build_object(
         'target_id','proof_fleet','expected_revision',99,'display_name','Should Not Apply',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or (r->'details'->0->>'code') <> 'source_changed' or (r->'details'->0->>'field') <> 'revision' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: stale expected_revision not rejected precisely: %', r;
  end if;
  select * into v_row from public.enemy_fleet_templates where key = 'proof_fleet';
  if v_row.revision <> 2 or v_row.display_name <> 'Proof Fleet v2' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: a stale-rejected update WROTE (rev %, name %)', v_row.revision, v_row.display_name;
  end if;
  if exists (select 1 from public.world_editor_audit where request_id = 'fe-stale-1') then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: a stale-rejected update wrote an audit row';
  end if;
  raise notice 'FLEET_ENCOUNTER_PASS_STALE_REVISION_REJECTED';
end $$;

-- ── PROOF 9 — INVALID references are rejected (all five codes), nothing written ──────────────────────
do $$
declare v_owner uuid; v_light uuid; v_fleet uuid; v_arch_off uuid; v_fleet_off uuid; r jsonb; n int;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  select id into v_fleet from public.enemy_fleet_templates where key = 'proof_fleet';  -- active, valid ref
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- (a) invalid_archetype_ref: a well-formed uuid referencing nothing.
  r := public.enemy_fleet_template_create('fe-badarch-1', jsonb_build_object(
         'key','proof_badarch','display_name','Bad Arch',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', gen_random_uuid()::text,'min_count',1,'max_count',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_archetype_ref')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: bogus archetype ref not rejected invalid_archetype_ref: %', r;
  end if;

  -- (b) archetype_inactive: an EXISTING but inactive archetype (direct-inserted inactive; no active referrer).
  insert into public.enemy_archetypes
      (key, display_name, faction, unit_type_id, behavior_key, base_difficulty, default_reward_profile_id, difficulty_rating, active)
    select 'proof_arch_off','Proof Arch Off','pirate','pirate_synthetic','spatial_synthetic',10, rp.id, 1, false
    from (select id from public.reward_profiles where key = 'pirate_standard') rp
    returning id into v_arch_off;
  r := public.enemy_fleet_template_create('fe-archoff-1', jsonb_build_object(
         'key','proof_archoff','display_name','Arch Off',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_arch_off::text,'min_count',1,'max_count',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','archetype_inactive')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: inactive archetype not rejected archetype_inactive: %', r;
  end if;

  -- (c) invalid_fleet_ref: a well-formed uuid referencing no fleet.
  r := public.encounter_profile_create('fe-badfleet-1', jsonb_build_object(
         'key','proof_badfleet','display_name','Bad Fleet',
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', gen_random_uuid()::text,'weight',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_fleet_ref')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: bogus fleet ref not rejected invalid_fleet_ref: %', r;
  end if;

  -- (d) fleet_inactive: an EXISTING but inactive fleet (direct-inserted inactive).
  insert into public.enemy_fleet_templates (key, display_name, active)
    values ('proof_fleet_off','Proof Fleet Off', false) returning id into v_fleet_off;
  r := public.encounter_profile_create('fe-fleetoff-1', jsonb_build_object(
         'key','proof_fleetoff','display_name','Fleet Off',
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', v_fleet_off::text,'weight',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','fleet_inactive')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: inactive fleet not rejected fleet_inactive: %', r;
  end if;

  -- (e) invalid_reward_override: a well-formed uuid referencing no reward profile (with a VALID fleet member).
  r := public.encounter_profile_create('fe-badreward-1', jsonb_build_object(
         'key','proof_badreward','display_name','Bad Reward','reward_override_id', gen_random_uuid()::text,
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', v_fleet::text,'weight',1))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_reward_override')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: bogus reward override not rejected invalid_reward_override: %', r;
  end if;

  -- none of the rejected calls wrote a parent row or an audit row.
  if exists (select 1 from public.enemy_fleet_templates where key in ('proof_badarch','proof_archoff'))
     or exists (select 1 from public.encounter_profiles where key in ('proof_badfleet','proof_fleetoff','proof_badreward')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: an invalid-reference create wrote a row';
  end if;
  select count(*) into n from public.world_editor_audit
    where request_id in ('fe-badarch-1','fe-archoff-1','fe-badfleet-1','fe-fleetoff-1','fe-badreward-1');
  if n <> 0 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: an invalid-reference create wrote % audit row(s)', n; end if;
  raise notice 'FLEET_ENCOUNTER_PASS_INVALID_REFERENCE_REJECTED';
end $$;

-- ── PROOF 10 — BOUNDED numerics are rejected (member + encounter scalar ranges), nothing written ─────
do $$
declare v_owner uuid; v_light uuid; v_fleet uuid; r jsonb; n int;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  select id into v_fleet from public.enemy_fleet_templates where key = 'proof_fleet';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  -- min > max ⇒ invalid_count_range.
  r := public.enemy_fleet_template_create('fe-b1', jsonb_build_object('key','proof_b1','display_name','x',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',2,'max_count',1))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_count_range')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: min>max not rejected invalid_count_range: %', r;
  end if;
  -- max = 101 ⇒ invalid_count_range.
  r := public.enemy_fleet_template_create('fe-b2', jsonb_build_object('key','proof_b2','display_name','x',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',101))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_count_range')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: max=101 not rejected invalid_count_range: %', r;
  end if;
  -- weight 0 ⇒ invalid_weight.
  r := public.enemy_fleet_template_create('fe-b3', jsonb_build_object('key','proof_b3','display_name','x',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',1,'weight',0))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_weight')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: weight 0 not rejected invalid_weight: %', r;
  end if;
  -- weight 2000 ⇒ invalid_weight.
  r := public.enemy_fleet_template_create('fe-b4', jsonb_build_object('key','proof_b4','display_name','x',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',1,'weight',2000))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_weight')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: weight 2000 not rejected invalid_weight: %', r;
  end if;
  -- elite_chance 1.5 ⇒ invalid_elite_chance.
  r := public.enemy_fleet_template_create('fe-b5', jsonb_build_object('key','proof_b5','display_name','x',
         'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',1,'elite_chance',1.5))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_elite_chance')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: elite_chance 1.5 not rejected invalid_elite_chance: %', r;
  end if;

  -- encounter difficulty 0 / 1001 ⇒ invalid_difficulty.
  r := public.encounter_profile_create('fe-b6', jsonb_build_object('key','proof_b6','display_name','x','difficulty',0,
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', v_fleet::text,'weight',1))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_difficulty')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: difficulty 0 not rejected invalid_difficulty: %', r;
  end if;
  r := public.encounter_profile_create('fe-b7', jsonb_build_object('key','proof_b7','display_name','x','difficulty',1001,
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', v_fleet::text,'weight',1))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_difficulty')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: difficulty 1001 not rejected invalid_difficulty: %', r;
  end if;
  -- encounter cap 0 / 101 ⇒ invalid_encounter_cap.
  r := public.encounter_profile_create('fe-b8', jsonb_build_object('key','proof_b8','display_name','x','active_encounter_cap',0,
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', v_fleet::text,'weight',1))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_encounter_cap')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: cap 0 not rejected invalid_encounter_cap: %', r;
  end if;
  r := public.encounter_profile_create('fe-b9', jsonb_build_object('key','proof_b9','display_name','x','active_encounter_cap',101,
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', v_fleet::text,'weight',1))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_encounter_cap')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: cap 101 not rejected invalid_encounter_cap: %', r;
  end if;
  -- encounter cooldown -1 / 90000 ⇒ invalid_cooldown.
  r := public.encounter_profile_create('fe-b10', jsonb_build_object('key','proof_b10','display_name','x','cooldown_seconds',-1,
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', v_fleet::text,'weight',1))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_cooldown')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: cooldown -1 not rejected invalid_cooldown: %', r;
  end if;
  r := public.encounter_profile_create('fe-b11', jsonb_build_object('key','proof_b11','display_name','x','cooldown_seconds',90000,
         'members', jsonb_build_array(jsonb_build_object('fleet_template_id', v_fleet::text,'weight',1))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_cooldown')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: cooldown 90000 not rejected invalid_cooldown: %', r;
  end if;

  if exists (select 1 from public.enemy_fleet_templates where key like 'proof_b%')
     or exists (select 1 from public.encounter_profiles where key like 'proof_b%') then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: a bounded-reject create wrote a row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id like 'fe-b%';
  if n <> 0 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: a bounded-reject create wrote % audit row(s)', n; end if;
  raise notice 'FLEET_ENCOUNTER_PASS_BOUNDED_NUMERIC_REJECTED';
end $$;

-- ── PROOF 11 — MEMBERS: empty ⇒ members_required; duplicate ref ⇒ duplicate_member; nothing written ─
do $$
declare v_owner uuid; v_light uuid; r jsonb; n int;
begin
  select v into v_owner from feids where k = 'owner';
  select id into v_light from public.enemy_archetypes where key = 'pirate_light';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.enemy_fleet_template_create('fe-empty-1', jsonb_build_object('key','proof_empty','display_name','x',
         'members', '[]'::jsonb));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','members_required')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: empty members not rejected members_required: %', r;
  end if;

  r := public.enemy_fleet_template_create('fe-dup-1', jsonb_build_object('key','proof_dup','display_name','x',
         'members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',1),
           jsonb_build_object('enemy_archetype_id', v_light::text,'min_count',1,'max_count',1))));
  if (r->>'error') <> 'validation_failed' or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','duplicate_member')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: duplicate member not rejected duplicate_member: %', r;
  end if;

  if exists (select 1 from public.enemy_fleet_templates where key in ('proof_empty','proof_dup')) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: a members-rejected create wrote a row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('fe-empty-1','fe-dup-1');
  if n <> 0 then raise exception 'FLEET-ENCOUNTER PROOF FAIL: a members-rejected create wrote % audit row(s)', n; end if;
  raise notice 'FLEET_ENCOUNTER_PASS_MEMBERS_REQUIRED';
end $$;

-- ── PROOF 12 — audit exposure is INTENTIONAL: owner sees after.members; actor redacted, is_owner true ─
do $$
declare v_owner uuid; r jsonb; v_item jsonb;
begin
  select v into v_owner from feids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.world_editor_audit_list(jsonb_build_object('request_id','fe-create-ft-1'));
  if (r->>'ok')::boolean is not true or jsonb_typeof(r->'items') <> 'array' or jsonb_array_length(r->'items') <> 1 then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: audit reader did not return the fleet create row: %', r;
  end if;
  v_item := r->'items'->0;
  -- INTENDED: members ARE returned to the owner (authoring data the owner wrote).
  if not (v_item->'after' ? 'members') or jsonb_typeof(v_item->'after'->'members') <> 'array' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: after.members is NOT owner-visible (intended exposure regressed): %', v_item;
  end if;
  -- REDACTED: never the raw actor UUID; actor_is_owner reported; redactions lists the actor withholding.
  if (v_item ? 'actor') then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: the raw actor UUID was shipped by the audit reader: %', v_item;
  end if;
  if (v_item->>'actor_is_owner') <> 'true' or not (v_item->'redactions') @> jsonb_build_array('actor') then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: reader did not report actor_is_owner + the actor redaction: %', v_item;
  end if;
  raise notice 'FLEET_ENCOUNTER_PASS_AUDIT_EXPOSURE_INTENTIONAL';
end $$;

-- ── PROOF 13 — DIRECT client writes DENIED on all four tables; public SELECT present ────────────────
do $$
declare v_rel text;
begin
  foreach v_rel in array array[
      'public.enemy_fleet_templates','public.enemy_fleet_template_members',
      'public.encounter_profiles','public.encounter_profile_members']
  loop
    if has_table_privilege('authenticated', v_rel, 'INSERT')
       or has_table_privilege('authenticated', v_rel, 'UPDATE')
       or has_table_privilege('authenticated', v_rel, 'DELETE')
       or has_table_privilege('anon', v_rel, 'INSERT')
       or has_table_privilege('anon', v_rel, 'UPDATE')
       or has_table_privilege('anon', v_rel, 'DELETE') then
      raise exception 'FLEET-ENCOUNTER PROOF FAIL: a client role holds a direct write grant on %', v_rel;
    end if;
    if not has_table_privilege('authenticated', v_rel, 'SELECT') or not has_table_privilege('anon', v_rel, 'SELECT') then
      raise exception 'FLEET-ENCOUNTER PROOF FAIL: public SELECT on % was lost', v_rel;
    end if;
  end loop;
  raise notice 'FLEET_ENCOUNTER_PASS_DIRECT_WRITE_DENIED';
end $$;

-- ── PROOF 14 — each APPLIED op wrote one audit row w/ the right command_type/target_type/target_id ───
do $$
declare v_ct text; v_tt text; v_tid text;
begin
  select command_type, target_type, target_id into v_ct, v_tt, v_tid
    from public.world_editor_audit where request_id = 'fe-create-ft-1';
  if v_ct <> 'enemy_fleet_template_create' or v_tt <> 'enemy_fleet_template' or v_tid <> 'proof_fleet' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: fleet create audit fields wrong (% / % / %)', v_ct, v_tt, v_tid;
  end if;
  select command_type, target_type, target_id into v_ct, v_tt, v_tid
    from public.world_editor_audit where request_id = 'fe-create-ep-1';
  if v_ct <> 'encounter_profile_create' or v_tt <> 'encounter_profile' or v_tid <> 'proof_encounter' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: encounter create audit fields wrong (% / % / %)', v_ct, v_tt, v_tid;
  end if;
  select command_type, target_type into v_ct, v_tt from public.world_editor_audit where request_id = 'fe-update-ft-1';
  if v_ct <> 'enemy_fleet_template_update' or v_tt <> 'enemy_fleet_template' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: fleet update audit fields wrong (% / %)', v_ct, v_tt;
  end if;
  select command_type, target_type into v_ct, v_tt from public.world_editor_audit where request_id = 'fe-setactive-ep-1';
  if v_ct <> 'encounter_profile_set_active' or v_tt <> 'encounter_profile' then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: encounter set_active audit fields wrong (% / %)', v_ct, v_tt;
  end if;
  raise notice 'FLEET_ENCOUNTER_PASS_AUDIT_FIELDS';
end $$;

-- ── PROOF 15 — DEACTIVATION referential-integrity triggers: BLOCK while referenced; SUCCEED after ────
do $$
declare v_rp uuid; v_gr uuid; v_ga uuid; v_gf uuid; v_ge uuid; blocked boolean;
begin
  select id into v_rp from public.reward_profiles where key = 'pirate_standard';
  -- build an isolated ACTIVE chain: reward_override + archetype ← fleet ← encounter (all direct inserts).
  insert into public.reward_profiles (key, display_name, resource_grants, active)
    values ('guard_reward','Guard Reward','{"metal":{"base":10,"multiplier_ref":"reward_multiplier"}}'::jsonb, true)
    returning id into v_gr;
  insert into public.enemy_archetypes
      (key, display_name, faction, unit_type_id, behavior_key, base_difficulty, default_reward_profile_id, difficulty_rating, active)
    values ('guard_arch','Guard Arch','pirate','pirate_synthetic','spatial_synthetic',10, v_rp, 1, true)
    returning id into v_ga;
  insert into public.enemy_fleet_templates (key, display_name, active) values ('guard_fleet','Guard Fleet', true) returning id into v_gf;
  insert into public.enemy_fleet_template_members (fleet_template_id, enemy_archetype_id, min_count, max_count) values (v_gf, v_ga, 1, 1);
  insert into public.encounter_profiles (key, display_name, difficulty, active_encounter_cap, cooldown_seconds, reward_override_id, active)
    values ('guard_enc','Guard Enc', 1, 1, 0, v_gr, true) returning id into v_ge;
  insert into public.encounter_profile_members (encounter_profile_id, fleet_template_id, weight) values (v_ge, v_gf, 1);

  -- (1) archetype deactivation BLOCKED while an ACTIVE fleet references it.
  blocked := false;
  begin update public.enemy_archetypes set active = false where id = v_ga; exception when others then blocked := true; end;
  if not blocked then raise exception 'FLEET-ENCOUNTER PROOF FAIL: archetype deactivation was NOT blocked while referenced by an active fleet'; end if;

  -- (2) fleet deactivation BLOCKED while an ACTIVE encounter references it.
  blocked := false;
  begin update public.enemy_fleet_templates set active = false where id = v_gf; exception when others then blocked := true; end;
  if not blocked then raise exception 'FLEET-ENCOUNTER PROOF FAIL: fleet deactivation was NOT blocked while referenced by an active encounter'; end if;

  -- (3) reward profile deactivation BLOCKED while it is an ACTIVE encounter's reward override.
  blocked := false;
  begin update public.reward_profiles set active = false where id = v_gr; exception when others then blocked := true; end;
  if not blocked then raise exception 'FLEET-ENCOUNTER PROOF FAIL: reward profile deactivation was NOT blocked while an active override'; end if;

  -- now remove the referrers top-down; each deactivation then SUCCEEDS.
  update public.encounter_profiles set active = false where id = v_ge;      -- encounter is top of chain (no referrer)
  update public.enemy_fleet_templates set active = false where id = v_gf;   -- now unreferenced by an active encounter
  update public.reward_profiles set active = false where id = v_gr;         -- now not an active override
  update public.enemy_archetypes set active = false where id = v_ga;        -- now unreferenced by an active fleet
  if (select active from public.enemy_archetypes where id = v_ga) is not false
     or (select active from public.enemy_fleet_templates where id = v_gf) is not false
     or (select active from public.reward_profiles where id = v_gr) is not false then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: a deactivation did not succeed after its referrer was removed';
  end if;
  raise notice 'FLEET_ENCOUNTER_PASS_DEACTIVATION_GUARD';
end $$;

-- ── PROOF 16 — DARK guarantee: no combat body reads the four tables; combat tunables unchanged ──────
do $$
declare v_rec record;
begin
  if not exists (select 1 from pg_proc where proname = 'process_combat_ticks' and pronamespace = 'public'::regnamespace)
     or not exists (select 1 from pg_proc where proname = 'combat_create_group_encounter' and pronamespace = 'public'::regnamespace)
     or not exists (select 1 from pg_proc where proname = 'reward_grant' and pronamespace = 'public'::regnamespace) then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: a combat/reward function is missing — surface disturbed';
  end if;
  -- the combat/reward tunables are unchanged.
  if public.cfg_num('enemy_synthetic_max_units') is distinct from 6 then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: enemy_synthetic_max_units is % (expected 6)', public.cfg_num('enemy_synthetic_max_units');
  end if;
  if public.cfg_num('reward_multiplier') is distinct from 1.0 then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: reward_multiplier is % (expected 1.0)', public.cfg_num('reward_multiplier');
  end if;
  -- NO combat/reward function body references ANY of the four new tables.
  for v_rec in
    select oid, proname from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in ('process_combat_ticks','combat_create_group_encounter','reward_grant')
  loop
    if pg_get_functiondef(v_rec.oid) ilike '%enemy_fleet_templates%'
       or pg_get_functiondef(v_rec.oid) ilike '%enemy_fleet_template_members%'
       or pg_get_functiondef(v_rec.oid) ilike '%encounter_profiles%'
       or pg_get_functiondef(v_rec.oid) ilike '%encounter_profile_members%' then
      raise exception 'FLEET-ENCOUNTER PROOF FAIL: % references a 0258 table — the DARK guarantee is broken', v_rec.proname;
    end if;
  end loop;
  raise notice 'FLEET_ENCOUNTER_PASS_DARK_GUARANTEE';
end $$;

-- ── PROOF 17 — NO delete RPC exists anywhere in this surface ────────────────────────────────────────
do $$
begin
  if to_regprocedure('public.enemy_fleet_template_delete(text,jsonb)') is not null
     or to_regprocedure('public.encounter_profile_delete(text,jsonb)') is not null
     or to_regprocedure('public.enemy_fleet_template_member_delete(text,jsonb)') is not null
     or to_regprocedure('public.encounter_profile_member_delete(text,jsonb)') is not null then
    raise exception 'FLEET-ENCOUNTER PROOF FAIL: a *_delete RPC exists — this surface must have NO delete command';
  end if;
  raise notice 'FLEET_ENCOUNTER_PASS_NO_DELETE_RPC';
end $$;

do $$ begin raise notice 'FLEET TEMPLATES + ENCOUNTER PROFILES PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (both flag flips included).
