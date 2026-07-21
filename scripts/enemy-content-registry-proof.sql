-- ENEMY CONTENT REGISTRY — disposable apply-proof (run against a THROWAWAY local Supabase ONLY).
--
-- Proves migration 0257 (20260618000257_enemy_content_registry.sql) after the FULL chain is applied
-- by `supabase start`: the six owner-gated write commands (reward_profile_create/update/set_active +
-- enemy_archetype_create/update/set_active) author the two net-new DARK catalog tables ONLY when the
-- fail-closed enemy_content_registry_enabled flag is ON and the caller is the owner; they are
-- idempotent on request_id, enforce optimistic revision, reject invalid references, write exactly one
-- world_editor_audit row per applied command, and NEVER expose a client table-write path. Also proves
-- the DARK guarantee: existing combat/reward config is unchanged and NO combat function body reads the
-- new tables.
--
-- Self-rolling-back: everything runs inside one begin;...rollback; — ZERO persisted state, no flag
-- left flipped, no row kept. The owner it "seeds" is a synthetic auth.users row created HERE. NEVER
-- point this at production.

\set ON_ERROR_STOP on

begin;

-- ── fixtures: a synthetic OWNER + a synthetic NON-OWNER ────────────────────────────────────────────
create temp table regids(k text primary key, v uuid) on commit drop;
insert into regids values ('owner', gen_random_uuid()), ('nonowner', gen_random_uuid());

insert into auth.users
  (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
   confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
       'regact.'||k||'.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','',''
from regids;

-- seed ONLY the owner into the allow-list (deny-all table has no client write path).
insert into public.app_owners(user_id) select v from regids where k = 'owner';

-- ── PROOF 1 — FLAG OFF: even the OWNER is rejected not_enabled, zero rows/audit (reject-before-read) ─
do $$
declare v_owner uuid; r jsonb; n int;
begin
  select v into v_owner from regids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.reward_profile_create('reg-flagoff-1', jsonb_build_object(
         'key','proof_flagoff','display_name','Should Not Exist',
         'resource_grants', jsonb_build_object('metal', jsonb_build_object('base',10))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_enabled' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: owner was not rejected not_enabled while flag off: %', r;
  end if;
  r := public.enemy_archetype_create('reg-flagoff-2', jsonb_build_object(
         'key','proof_flagoff_e','display_name','Nope','unit_type_id','pirate_synthetic',
         'base_difficulty',10,'difficulty_rating',1,'default_reward_profile_id', gen_random_uuid()));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_enabled' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: owner archetype not rejected not_enabled while flag off: %', r;
  end if;
  if exists (select 1 from public.reward_profiles where key = 'proof_flagoff')
     or exists (select 1 from public.enemy_archetypes where key = 'proof_flagoff_e') then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: a flag-off call wrote a registry row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('reg-flagoff-1','reg-flagoff-2');
  if n <> 0 then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: a flag-off call wrote % audit row(s)', n;
  end if;
  raise notice 'ENEMY_REGISTRY_PASS_FLAG_OFF_DENIED';
end $$;

-- ── flip the flag ON inside the txn (superuser direct write; rolled back at the end) ────────────────
update public.game_config set value = 'true'::jsonb where key = 'enemy_content_registry_enabled';

-- ── PROOF 2 — ANONYMOUS caller is rejected not_authenticated (flag now on), zero side effects ───────
do $$
declare r jsonb; n int;
begin
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  r := public.reward_profile_create('reg-anon-1', jsonb_build_object(
         'key','proof_anon','display_name','Nope','resource_grants', jsonb_build_object('metal', jsonb_build_object('base',10))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authenticated' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: anon not rejected not_authenticated: %', r;
  end if;
  if exists (select 1 from public.reward_profiles where key = 'proof_anon') then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: an anon call wrote a row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'reg-anon-1';
  if n <> 0 then raise exception 'ENEMY-REGISTRY PROOF FAIL: an anon call wrote an audit row'; end if;
  raise notice 'ENEMY_REGISTRY_PASS_ANON_DENIED';
end $$;

-- ── PROOF 3 — NON-OWNER authenticated caller is rejected not_authorized, zero side effects ──────────
do $$
declare v_no uuid; r jsonb; n int;
begin
  select v into v_no from regids where k = 'nonowner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_no::text, 'role','authenticated')::text, true);
  r := public.reward_profile_create('reg-nonowner-1', jsonb_build_object(
         'key','proof_nonowner','display_name','Nope','resource_grants', jsonb_build_object('metal', jsonb_build_object('base',10))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'not_authorized' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: non-owner not rejected not_authorized: %', r;
  end if;
  if exists (select 1 from public.reward_profiles where key = 'proof_nonowner') then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: a non-owner call wrote a row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'reg-nonowner-1';
  if n <> 0 then raise exception 'ENEMY-REGISTRY PROOF FAIL: a non-owner call wrote an audit row'; end if;
  raise notice 'ENEMY_REGISTRY_PASS_NONOWNER_DENIED';
end $$;

-- ── PROOF 4 — OWNER CREATE: reward_profile then archetype; row + one audit (after_snapshot + rev) ───
do $$
declare v_owner uuid; r jsonb; v_pid uuid; v_row record; v_after jsonb; v_rev text; n int;
begin
  select v into v_owner from regids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);

  r := public.reward_profile_create('reg-create-rp-1', jsonb_build_object(
         'key','proof_reward','display_name','Proof Reward',
         'source_revision','reg-rev-rp',
         'resource_grants', jsonb_build_object('metal', jsonb_build_object('base',12,'danger_coeff',0.5,'multiplier_ref','reward_multiplier'))));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' or (r->'result'->>'key') <> 'proof_reward' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: owner reward_profile create not ok: %', r;
  end if;
  select * into v_row from public.reward_profiles where key = 'proof_reward';
  if v_row.revision <> 1 or v_row.active is not true then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: created reward_profile has wrong revision/active (% / %)', v_row.revision, v_row.active;
  end if;
  select after_snapshot, source_revision into v_after, v_rev from public.world_editor_audit where request_id = 'reg-create-rp-1';
  if v_after is null or jsonb_typeof(v_after) <> 'object' or (v_after->>'key') <> 'proof_reward' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: reward_profile create audit after_snapshot malformed: %', v_after;
  end if;
  if v_rev is null then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: reward_profile create audit source_revision not recorded';
  end if;
  select count(*) into n from public.world_editor_audit where request_id = 'reg-create-rp-1';
  if n <> 1 then raise exception 'ENEMY-REGISTRY PROOF FAIL: reward_profile create wrote % audit rows (expected 1)', n; end if;

  select id into v_pid from public.reward_profiles where key = 'proof_reward';
  r := public.enemy_archetype_create('reg-create-ea-1', jsonb_build_object(
         'key','proof_enemy','display_name','Proof Enemy','unit_type_id','pirate_synthetic',
         'source_revision','reg-rev-ea',
         'base_difficulty',15,'difficulty_rating',2,'default_reward_profile_id', v_pid,
         'stat_overrides', jsonb_build_object('shield',5)));
  if (r->>'ok')::boolean is not true or (r->'result'->>'created') <> 'true' or (r->'result'->>'key') <> 'proof_enemy' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: owner enemy_archetype create not ok: %', r;
  end if;
  select * into v_row from public.enemy_archetypes where key = 'proof_enemy';
  if v_row.revision <> 1 or v_row.base_difficulty <> 15 or v_row.difficulty_rating <> 2
     or v_row.unit_type_id <> 'pirate_synthetic' or v_row.default_reward_profile_id <> v_pid then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: created enemy_archetype row malformed';
  end if;
  select after_snapshot into v_after from public.world_editor_audit where request_id = 'reg-create-ea-1';
  if v_after is null or (v_after->>'key') <> 'proof_enemy' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: enemy_archetype create audit after_snapshot malformed: %', v_after;
  end if;
  raise notice 'ENEMY_REGISTRY_PASS_OWNER_CREATE';
end $$;

-- ── PROOF 5 — OWNER UPDATE: correct expected_revision → revision incremented, audit before + after ──
do $$
declare v_owner uuid; r jsonb; v_row record; v_before jsonb; v_after jsonb;
begin
  select v into v_owner from regids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.reward_profile_update('reg-update-rp-1', jsonb_build_object(
         'target_id','proof_reward','expected_revision',1,
         'display_name','Proof Reward v2',
         'resource_grants', jsonb_build_object('metal', jsonb_build_object('base',20))));
  if (r->>'ok')::boolean is not true or (r->'result'->>'updated') <> 'true' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: owner reward_profile update not ok: %', r;
  end if;
  select * into v_row from public.reward_profiles where key = 'proof_reward';
  if v_row.revision <> 2 or v_row.display_name <> 'Proof Reward v2' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: update did not bump revision to 2 / apply fields (rev %, name %)', v_row.revision, v_row.display_name;
  end if;
  select before_snapshot, after_snapshot into v_before, v_after from public.world_editor_audit where request_id = 'reg-update-rp-1';
  if v_before is null or jsonb_typeof(v_before) <> 'object' or (v_before->>'revision') <> '1'
     or v_after is null or (v_after->>'revision') <> '2' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: update audit before/after revisions wrong (% / %)', v_before->>'revision', v_after->>'revision';
  end if;
  raise notice 'ENEMY_REGISTRY_PASS_OWNER_UPDATE';
end $$;

-- ── PROOF 6 — OWNER SET_ACTIVE false: active=false (soft), row SURVIVES (no hard delete) ────────────
do $$
declare v_owner uuid; r jsonb; v_row record;
begin
  select v into v_owner from regids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r := public.reward_profile_set_active('reg-setactive-rp-1', jsonb_build_object(
         'target_id','proof_reward','expected_revision',2,'active', false));
  if (r->>'ok')::boolean is not true or (r->'result'->>'active_set') <> 'true' or (r->'result'->>'active') <> 'false' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: owner set_active(false) not ok: %', r;
  end if;
  select * into v_row from public.reward_profiles where key = 'proof_reward';
  if v_row.active is not false then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: set_active did not soft-disable (active = %)', v_row.active;
  end if;
  if v_row.revision <> 3 or v_row.display_name <> 'Proof Reward v2' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: set_active changed more than active/revision, or removed the row';
  end if;
  raise notice 'ENEMY_REGISTRY_PASS_OWNER_SET_ACTIVE';
end $$;

-- ── PROOF 7 — repeated request_id is IDEMPOTENT (one apply; one audit row; identical replay) ────────
do $$
declare v_owner uuid; r1 jsonb; r2 jsonb; n int; v_row record;
begin
  select v into v_owner from regids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  r1 := public.reward_profile_create('reg-idem-1', jsonb_build_object(
          'key','proof_idem','display_name','Idem A','resource_grants', jsonb_build_object('metal', jsonb_build_object('base',10))));
  -- replay the SAME request_id with a DIFFERENT payload — must NOT re-apply; must return prior result.
  r2 := public.reward_profile_create('reg-idem-1', jsonb_build_object(
          'key','proof_idem_DIFFERENT','display_name','Idem B','resource_grants', jsonb_build_object('metal', jsonb_build_object('base',99))));
  if (r1->>'ok')::boolean is not true then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: first idempotent call not ok: %', r1;
  end if;
  if (r2->>'ok')::boolean is not true or (r2->>'replayed')::boolean is not true or (r2->>'code') <> 'duplicate_request' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: replay was not an idempotent duplicate_request: %', r2;
  end if;
  if (r2->'result') <> (r1->'result') then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: replay result differs (% vs %)', r2->'result', r1->'result';
  end if;
  if exists (select 1 from public.reward_profiles where key = 'proof_idem_DIFFERENT') then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: the replayed (different) payload created a second row';
  end if;
  select count(*) into n from public.reward_profiles where key = 'proof_idem';
  if n <> 1 then raise exception 'ENEMY-REGISTRY PROOF FAIL: idempotent create produced % rows (expected 1)', n; end if;
  select count(*) into n from public.world_editor_audit where request_id = 'reg-idem-1';
  if n <> 1 then raise exception 'ENEMY-REGISTRY PROOF FAIL: idempotent create produced % audit rows (expected 1)', n; end if;
  raise notice 'ENEMY_REGISTRY_PASS_IDEMPOTENT';
end $$;

-- ── PROOF 8 — STALE revision is rejected (stale_revision), nothing written ──────────────────────────
do $$
declare v_owner uuid; r jsonb; v_row record;
begin
  select v into v_owner from regids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  -- proof_reward is at revision 3 (create→update→set_active); pass a WRONG expected_revision.
  r := public.reward_profile_update('reg-stale-1', jsonb_build_object(
         'target_id','proof_reward','expected_revision',99,
         'display_name','Should Not Apply','resource_grants', jsonb_build_object('metal', jsonb_build_object('base',10))));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'stale_revision'
     or (r->'details'->0->>'code') <> 'source_changed' or (r->'details'->0->>'field') <> 'revision' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: stale expected_revision not rejected precisely: %', r;
  end if;
  select * into v_row from public.reward_profiles where key = 'proof_reward';
  if v_row.revision <> 3 or v_row.display_name <> 'Proof Reward v2' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: a stale-rejected update WROTE (rev %, name %)', v_row.revision, v_row.display_name;
  end if;
  if exists (select 1 from public.world_editor_audit where request_id = 'reg-stale-1') then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: a stale-rejected update wrote an audit row';
  end if;
  raise notice 'ENEMY_REGISTRY_PASS_STALE_REVISION_REJECTED';
end $$;

-- ── PROOF 9 — INVALID references are rejected (invalid_unit_type / invalid_reward_profile), no write ─
do $$
declare v_owner uuid; r jsonb; v_pid uuid; n int;
begin
  select v into v_owner from regids where k = 'owner';
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  select id into v_pid from public.reward_profiles where key = 'proof_reward';

  -- bogus unit_type_id.
  r := public.enemy_archetype_create('reg-badunit-1', jsonb_build_object(
         'key','proof_badunit','display_name','Bad Unit','unit_type_id','no_such_unit',
         'base_difficulty',10,'difficulty_rating',1,'default_reward_profile_id', v_pid));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_unit_type')) then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: bogus unit_type_id not rejected invalid_unit_type: %', r;
  end if;

  -- bogus default_reward_profile_id (well-formed uuid that references nothing).
  r := public.enemy_archetype_create('reg-badprofile-1', jsonb_build_object(
         'key','proof_badprofile','display_name','Bad Profile','unit_type_id','pirate_synthetic',
         'base_difficulty',10,'difficulty_rating',1,'default_reward_profile_id', gen_random_uuid()));
  if (r->>'ok')::boolean is not false or (r->>'error') <> 'validation_failed'
     or not (r->'details') @> jsonb_build_array(jsonb_build_object('code','invalid_reward_profile')) then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: bogus default_reward_profile_id not rejected invalid_reward_profile: %', r;
  end if;

  if exists (select 1 from public.enemy_archetypes where key in ('proof_badunit','proof_badprofile')) then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: an invalid-reference create wrote a row';
  end if;
  select count(*) into n from public.world_editor_audit where request_id in ('reg-badunit-1','reg-badprofile-1');
  if n <> 0 then raise exception 'ENEMY-REGISTRY PROOF FAIL: an invalid-reference create wrote % audit row(s)', n; end if;
  raise notice 'ENEMY_REGISTRY_PASS_INVALID_REFERENCE_REJECTED';
end $$;

-- ── PROOF 10 — DIRECT client writes are DENIED (no INSERT/UPDATE/DELETE grant on either table) ──────
do $$
begin
  if has_table_privilege('authenticated','public.reward_profiles','INSERT')
     or has_table_privilege('authenticated','public.reward_profiles','UPDATE')
     or has_table_privilege('authenticated','public.reward_profiles','DELETE')
     or has_table_privilege('anon','public.reward_profiles','INSERT')
     or has_table_privilege('anon','public.reward_profiles','UPDATE')
     or has_table_privilege('anon','public.reward_profiles','DELETE')
     or has_table_privilege('authenticated','public.enemy_archetypes','INSERT')
     or has_table_privilege('authenticated','public.enemy_archetypes','UPDATE')
     or has_table_privilege('authenticated','public.enemy_archetypes','DELETE')
     or has_table_privilege('anon','public.enemy_archetypes','INSERT')
     or has_table_privilege('anon','public.enemy_archetypes','UPDATE')
     or has_table_privilege('anon','public.enemy_archetypes','DELETE') then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: a client role holds a direct write grant on a registry table';
  end if;
  -- public READ is allowed (harmless catalog) — assert it is present so read stays open.
  if not has_table_privilege('authenticated','public.reward_profiles','SELECT')
     or not has_table_privilege('anon','public.enemy_archetypes','SELECT') then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: public SELECT on a registry table was lost';
  end if;
  raise notice 'ENEMY_REGISTRY_PASS_DIRECT_WRITE_DENIED';
end $$;

-- ── PROOF 11 — each APPLIED op wrote exactly one audit row w/ the right command_type/target_type ────
do $$
declare v_ct text; v_tt text; v_tid text;
begin
  select command_type, target_type, target_id into v_ct, v_tt, v_tid
    from public.world_editor_audit where request_id = 'reg-create-rp-1';
  if v_ct <> 'reward_profile_create' or v_tt <> 'reward_profile' or v_tid <> 'proof_reward' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: reward_profile_create audit fields wrong (% / % / %)', v_ct, v_tt, v_tid;
  end if;
  select command_type, target_type, target_id into v_ct, v_tt, v_tid
    from public.world_editor_audit where request_id = 'reg-create-ea-1';
  if v_ct <> 'enemy_archetype_create' or v_tt <> 'enemy_archetype' or v_tid <> 'proof_enemy' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: enemy_archetype_create audit fields wrong (% / % / %)', v_ct, v_tt, v_tid;
  end if;
  select command_type, target_type into v_ct, v_tt from public.world_editor_audit where request_id = 'reg-update-rp-1';
  if v_ct <> 'reward_profile_update' or v_tt <> 'reward_profile' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: reward_profile_update audit fields wrong (% / %)', v_ct, v_tt;
  end if;
  select command_type, target_type into v_ct, v_tt from public.world_editor_audit where request_id = 'reg-setactive-rp-1';
  if v_ct <> 'reward_profile_set_active' or v_tt <> 'reward_profile' then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: reward_profile_set_active audit fields wrong (% / %)', v_ct, v_tt;
  end if;
  raise notice 'ENEMY_REGISTRY_PASS_AUDIT_FIELDS';
end $$;

-- ── PROOF 12 — DARK guarantee: existing combat/reward config unchanged; NO combat body reads the tables
do $$
declare v_rec record;
begin
  -- (a) the reward/combat surface still exists.
  if not exists (select 1 from pg_proc where proname = 'process_combat_ticks' and pronamespace = 'public'::regnamespace) then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: process_combat_ticks missing — combat surface disturbed';
  end if;
  if not exists (select 1 from pg_proc where proname = 'reward_grant' and pronamespace = 'public'::regnamespace) then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: reward_grant missing — reward surface disturbed';
  end if;

  -- (b) the reward tunables combat scales off are unchanged.
  if public.cfg_num('reward_metal_base') is distinct from 10 then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: reward_metal_base is % (expected 10)', public.cfg_num('reward_metal_base');
  end if;
  if public.cfg_num('reward_multiplier') is distinct from 1.0 then
    raise exception 'ENEMY-REGISTRY PROOF FAIL: reward_multiplier is % (expected 1.0)', public.cfg_num('reward_multiplier');
  end if;

  -- (c) NO combat/reward function body references the new registry tables (they read NOTHING from here).
  for v_rec in
    select oid, proname from pg_proc
    where pronamespace = 'public'::regnamespace and proname in ('process_combat_ticks','reward_grant')
  loop
    if pg_get_functiondef(v_rec.oid) ilike '%enemy_archetypes%'
       or pg_get_functiondef(v_rec.oid) ilike '%reward_profiles%' then
      raise exception 'ENEMY-REGISTRY PROOF FAIL: % references a registry table — the DARK guarantee is broken', v_rec.proname;
    end if;
  end loop;
  raise notice 'ENEMY_REGISTRY_PASS_COMBAT_UNCHANGED';
end $$;

do $$ begin raise notice 'ENEMY CONTENT REGISTRY PROOF PASSED'; end $$;

rollback;   -- leave ZERO persisted state (flag flip included).
