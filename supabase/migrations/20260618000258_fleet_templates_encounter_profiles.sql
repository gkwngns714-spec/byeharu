-- Byeharu — E1: FLEET TEMPLATES + ENCOUNTER PROFILES — a NET-NEW, DARK, fail-closed, ADDITIVE surface.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: four net-new owner-authored tables that COMPOSE the E0 catalog into reusable
-- encounter content — public.enemy_fleet_templates (a named group of archetype references) with its
-- normalized child public.enemy_fleet_template_members, and public.encounter_profiles (a difficulty/
-- cap/cooldown/reward wrapper) with its normalized child public.encounter_profile_members (fleet
-- references) — plus SIX owner-gated write commands that author them, all behind a fail-closed feature
-- flag. It is the SECOND slice of the enemy-content program: a place to COMPOSE the E0 enemy templates
-- into fleets and encounters, NOT to spawn or resolve them. It reproduces the established World Editor
-- command spine (0243/0244/0247/0250/0257) step for step and reuses THE ONE owner guard
-- (public.is_owner()), THE ONE audit/idempotency ledger (public.world_editor_audit incl. its 0244
-- before/after/source_revision columns) and THE ONE boolean config accessor (public.cfg_bool) — no
-- second authority anywhere. It STACKS on E0: fleet members FK enemy_archetypes; encounter reward
-- overrides FK reward_profiles.
--
-- WHY NORMALIZED CHILD TABLES (not a jsonb members column): a member is a REFERENCE to a row plus
-- per-ref numerics (min/max count, weight, elite_chance). E0 models "a reference + a bounded numeric"
-- as FK + CHECK, not embedded json — so the DB, not application code, is the authority on referential
-- integrity and bounds. The two child tables carry FK + CHECK for exactly that; the RPCs REPLACE-ALL
-- the child set inside the parent's revision-bumped update so the parent revision is the single
-- concurrency token and every write re-validates the whole composition atomically.
--
-- WHAT THIS IS NOT — the DARK guarantee: NO runtime combat path reads these four tables.
-- process_combat_ticks / combat_create_group_encounter / reward_grant are BYTE-IDENTICAL after this
-- migration; the existing pirate combat still scales off locations.base_difficulty, the game_config
-- reward_* tunables and enemy_synthetic_max_units. These tables carry NO runtime-instance state
-- (hp/position/target/status/encounter_id) — that stays on combat_units / combat_encounters. Every one
-- of the six RPCs applies a DUAL-FLAG gate FIRST (reject-before-any-read): BOTH
-- enemy_content_registry_enabled (E0) AND encounter_authoring_enabled (E1) must be true — since E1
-- references E0's tables, encounter authoring must not run while E0's registry is still dark. Both flags
-- are seeded 'false' — so even deployed, the whole surface is inert until an owner flips BOTH, and even
-- then only an owner (is_owner()) can write. Belt-and-braces DEACTIVATION triggers (§2c) additionally
-- block soft-disabling any entity still referenced by an ACTIVE downstream entity, even under a future
-- privileged/direct write.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed on TWO independent axes: the flag is
-- false (every RPC returns 'not_enabled' before touching a row) AND is_owner() is false for everyone
-- until an owner is seeded. No client grant is widened: the table writes happen INSIDE these SECURITY
-- DEFINER functions only; client-role write grants on all four tables are explicitly REVOKED (a pure
-- narrowing — RLS already denied them). Public SELECT is granted (read is harmless catalog).
--
-- NO-SPAGHETTI: ONE owner check (is_owner()), ONE audit ledger, ONE idempotency key, ONE flag accessor
-- (cfg_bool); NO add/remove-member RPC (members are REPLACE-ALL keyed to the parent revision — one
-- write path, one token); NO delete RPC anywhere; no runtime combat path re-pointed. Out of scope
-- (later slices): zone bindings (E2/E4), the runtime resolver that instantiates a fleet into
-- combat_units (E3), any World Editor UI, activation.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $fedep$
begin
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'FLEET-ENCOUNTER: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'FLEET-ENCOUNTER: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.cfg_bool(text)') is null then
    raise exception 'FLEET-ENCOUNTER: public.cfg_bool(text) (0046) is missing — THE ONE boolean flag accessor must exist first';
  end if;
  if to_regclass('public.game_config') is null then
    raise exception 'FLEET-ENCOUNTER: public.game_config (0003) is missing — the fail-closed flag lives here';
  end if;
  -- STACKS ON E0: fleet members FK enemy_archetypes; encounter reward overrides FK reward_profiles.
  if to_regclass('public.enemy_archetypes') is null then
    raise exception 'FLEET-ENCOUNTER: public.enemy_archetypes (0257/E0) is missing — fleet members reference it; E1 must build on E0';
  end if;
  if to_regclass('public.reward_profiles') is null then
    raise exception 'FLEET-ENCOUNTER: public.reward_profiles (0257/E0) is missing — encounter reward overrides reference it; E1 must build on E0';
  end if;
  -- the 0244 audit snapshot columns must already exist (this slice re-adds NOTHING; it USES all three).
  if not exists (select 1 from pg_attribute
                 where attrelid = 'public.world_editor_audit'::regclass
                   and attname = 'before_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'after_snapshot' and not attisdropped)
     or not exists (select 1 from pg_attribute
                    where attrelid = 'public.world_editor_audit'::regclass
                      and attname = 'source_revision' and not attisdropped) then
    raise exception 'FLEET-ENCOUNTER: a 0244 audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing — the snapshot columns must exist first';
  end if;
end $fedep$;

-- ── 1. enemy_fleet_templates — a named, reusable group of archetype references (owner-authored) ─────
create table if not exists public.enemy_fleet_templates (
  id            uuid primary key default gen_random_uuid(),
  key           text unique not null,
  display_name  text not null,
  active        boolean not null default true,
  revision      integer not null default 1 check (revision >= 1),
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.enemy_fleet_templates is
  'FLEET TEMPLATES + ENCOUNTER PROFILES (0258): owner-authored, DARK catalog of reusable enemy FLEET '
  'templates — a named group of E0 enemy_archetypes references (composition lives in the '
  'enemy_fleet_template_members child). Carries NO runtime-instance state. Read by NOTHING at runtime — '
  'existing pirate combat is byte-identical. Public SELECT; writes ONLY through the owner-gated 0258 '
  'RPCs behind the fail-closed encounter_authoring_enabled flag.';

alter table public.enemy_fleet_templates enable row level security;
create policy "enemy_fleet_templates_public_read" on public.enemy_fleet_templates for select using (true);
grant select on table public.enemy_fleet_templates to anon, authenticated;
revoke insert, update, delete on table public.enemy_fleet_templates from anon, authenticated;

-- ── 1b. enemy_fleet_template_members — one archetype reference + per-ref numerics (normalized child) ─
create table if not exists public.enemy_fleet_template_members (
  id                 uuid primary key default gen_random_uuid(),
  fleet_template_id  uuid not null references public.enemy_fleet_templates(id) on delete cascade,
  enemy_archetype_id uuid not null references public.enemy_archetypes(id),
  min_count          integer not null check (min_count >= 0 and min_count <= 100),
  max_count          integer not null check (max_count >= 0 and max_count <= 100),
  weight             double precision not null default 1 check (weight > 0 and weight <= 1000),
  elite_chance       double precision not null default 0 check (elite_chance >= 0 and elite_chance <= 1),
  constraint fleet_member_count_order check (min_count <= max_count),
  constraint fleet_member_unique unique (fleet_template_id, enemy_archetype_id)
);

comment on table public.enemy_fleet_template_members is
  'FLEET TEMPLATES + ENCOUNTER PROFILES (0258): normalized child of enemy_fleet_templates — ONE row per '
  'archetype reference plus per-ref numerics (min/max count, weight, elite_chance) with FK + CHECK as '
  'the referential/bounds authority (E0 models "reference + bounded numeric" as FK+CHECK, not jsonb). '
  'REPLACE-ALL by the owner-gated 0258 RPCs; DARK — read by nothing at runtime.';

alter table public.enemy_fleet_template_members enable row level security;
create policy "enemy_fleet_template_members_public_read" on public.enemy_fleet_template_members for select using (true);
grant select on table public.enemy_fleet_template_members to anon, authenticated;
revoke insert, update, delete on table public.enemy_fleet_template_members from anon, authenticated;

-- ── 2. encounter_profiles — a difficulty/cap/cooldown/reward wrapper over fleet references ──────────
-- reward_override_id is NULLABLE: null ⇒ fall back to the archetype's default reward profile (E0).
create table if not exists public.encounter_profiles (
  id                   uuid primary key default gen_random_uuid(),
  key                  text unique not null,
  display_name         text not null,
  difficulty           integer not null default 1 check (difficulty >= 1 and difficulty <= 1000),
  active_encounter_cap integer not null default 1 check (active_encounter_cap >= 1 and active_encounter_cap <= 100),
  cooldown_seconds     integer not null default 0 check (cooldown_seconds >= 0 and cooldown_seconds <= 86400),
  reward_override_id   uuid references public.reward_profiles(id),
  active               boolean not null default true,
  revision             integer not null default 1 check (revision >= 1),
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on table public.encounter_profiles is
  'FLEET TEMPLATES + ENCOUNTER PROFILES (0258): owner-authored, DARK catalog of reusable ENCOUNTER '
  'profiles — a difficulty/cap/cooldown/reward-override wrapper over a set of fleet-template references '
  '(composition lives in the encounter_profile_members child). reward_override_id is NULLABLE (null ⇒ '
  'fall back to the archetype default reward profile). Carries NO runtime-instance state. Read by '
  'NOTHING at runtime — existing pirate combat is byte-identical. Public SELECT; writes ONLY through '
  'the owner-gated 0258 RPCs behind the fail-closed encounter_authoring_enabled flag.';

alter table public.encounter_profiles enable row level security;
create policy "encounter_profiles_public_read" on public.encounter_profiles for select using (true);
grant select on table public.encounter_profiles to anon, authenticated;
revoke insert, update, delete on table public.encounter_profiles from anon, authenticated;

-- ── 2b. encounter_profile_members — one fleet-template reference + weight (normalized child) ────────
create table if not exists public.encounter_profile_members (
  id                   uuid primary key default gen_random_uuid(),
  encounter_profile_id uuid not null references public.encounter_profiles(id) on delete cascade,
  fleet_template_id    uuid not null references public.enemy_fleet_templates(id),
  weight               double precision not null default 1 check (weight > 0 and weight <= 1000),
  constraint encounter_member_unique unique (encounter_profile_id, fleet_template_id)
);

comment on table public.encounter_profile_members is
  'FLEET TEMPLATES + ENCOUNTER PROFILES (0258): normalized child of encounter_profiles — ONE row per '
  'fleet-template reference plus a weight, FK + CHECK as the referential/bounds authority. REPLACE-ALL '
  'by the owner-gated 0258 RPCs; DARK — read by nothing at runtime.';

alter table public.encounter_profile_members enable row level security;
create policy "encounter_profile_members_public_read" on public.encounter_profile_members for select using (true);
grant select on table public.encounter_profile_members to anon, authenticated;
revoke insert, update, delete on table public.encounter_profile_members from anon, authenticated;

-- ── 2c. DEACTIVATION REFERENTIAL-INTEGRITY TRIGGERS — defense-in-depth even against direct/privileged
-- writes (client writes are already revoked). A soft-disable (active true→false) of an entity that is
-- STILL referenced by an ACTIVE downstream entity would silently strand the composition, so BEFORE
-- UPDATE triggers RAISE on exactly the true→false transition when an active referrer remains. These
-- fire regardless of caller (RPC, superuser, or a future privileged path). They are SECURITY DEFINER +
-- set search_path='' like every other function here. NOTE (1) guards E0's enemy_archetype_set_active
-- too — an intended cross-slice protection added HERE in 0258 (it did not exist in E0).
create or replace function public._guard_archetype_deactivation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.enemy_fleet_template_members m
    join public.enemy_fleet_templates ft on ft.id = m.fleet_template_id
    where m.enemy_archetype_id = old.id and ft.active is true
  ) then
    raise exception 'FLEET-ENCOUNTER: cannot deactivate enemy archetype "%" — it is still a member of an ACTIVE fleet template (deactivate or remove the referring fleet first).', old.key;
  end if;
  return new;
end $$;

create or replace function public._guard_reward_profile_deactivation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.encounter_profiles ep
    where ep.reward_override_id = old.id and ep.active is true
  ) then
    raise exception 'FLEET-ENCOUNTER: cannot deactivate reward profile "%" — it is still the reward override of an ACTIVE encounter profile (clear the override or deactivate the encounter first).', old.key;
  end if;
  return new;
end $$;

create or replace function public._guard_fleet_template_deactivation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.encounter_profile_members m
    join public.encounter_profiles ep on ep.id = m.encounter_profile_id
    where m.fleet_template_id = old.id and ep.active is true
  ) then
    raise exception 'FLEET-ENCOUNTER: cannot deactivate fleet template "%" — it is still a member of an ACTIVE encounter profile (deactivate or remove the referring encounter first).', old.key;
  end if;
  return new;
end $$;

revoke all on function public._guard_archetype_deactivation() from public;
revoke all on function public._guard_reward_profile_deactivation() from public;
revoke all on function public._guard_fleet_template_deactivation() from public;

drop trigger if exists guard_archetype_deactivation on public.enemy_archetypes;
create trigger guard_archetype_deactivation
  before update on public.enemy_archetypes
  for each row when (old.active is true and new.active is false)
  execute function public._guard_archetype_deactivation();

drop trigger if exists guard_reward_profile_deactivation on public.reward_profiles;
create trigger guard_reward_profile_deactivation
  before update on public.reward_profiles
  for each row when (old.active is true and new.active is false)
  execute function public._guard_reward_profile_deactivation();

drop trigger if exists guard_fleet_template_deactivation on public.enemy_fleet_templates;
create trigger guard_fleet_template_deactivation
  before update on public.enemy_fleet_templates
  for each row when (old.active is true and new.active is false)
  execute function public._guard_fleet_template_deactivation();

-- ── 3. fail-closed feature flag (seeded false; do NOT overwrite if already set) ────────────────────
insert into public.game_config (key, value, description) values
  ('encounter_authoring_enabled', 'false',
   'E1 dark gate for enemy_fleet_templates/encounter_profiles owner-write RPCs; OFF until owner enables; '
   'every authoring RPC checks cfg_bool(this) AND cfg_bool(enemy_content_registry_enabled) FIRST '
   '(DUAL-FLAG reject-before-any-read: E1 references E0 tables so E0 must be live too); no runtime combat '
   'path reads these tables; existing pirate combat byte-identical')
on conflict (key) do nothing;

-- ── 3b. _fleet_members_valid_details — THE ONE strict E1 fleet-member shape validator ──────────────
-- members is authoring data, NOT arbitrary JSON. This pins the SHAPE only (IMMUTABLE, pure — touches
-- NO table): reference EXISTENCE/ELIGIBILITY is a STABLE in-body concern in the RPCs. Returns a
-- details[] (empty ⇒ shape valid) so create and update share ONE shape authority. jsonb numbers cannot
-- be NaN/Infinity, so jsonb_typeof='number' already means "finite".
create or replace function public._fleet_members_valid_details(p_members jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_details jsonb := '[]'::jsonb;
  v_elem    jsonb;
  v_k       text;
begin
  if p_members is null or jsonb_typeof(p_members) <> 'array' or jsonb_array_length(p_members) < 1 then
    return jsonb_build_array(jsonb_build_object(
      'code','members_required','field','members','message','members must be a non-empty JSON array (at least one fleet member).'));
  end if;
  for v_elem in select value from jsonb_array_elements(p_members) loop
    if jsonb_typeof(v_elem) <> 'object' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','invalid_member','field','members','message','each fleet member must be a JSON object.'));
      continue;
    end if;
    -- allowlist: ONLY enemy_archetype_id / min_count / max_count / weight / elite_chance.
    for v_k in select key from jsonb_each(v_elem) loop
      if v_k not in ('enemy_archetype_id','min_count','max_count','weight','elite_chance') then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code','invalid_member','field','members.'||v_k,
          'message','Unknown member key '''||v_k||''' (allowed: enemy_archetype_id, min_count, max_count, weight, elite_chance).'));
      end if;
    end loop;
    -- enemy_archetype_id: REQUIRED non-empty string (the reference itself is checked in-body).
    if jsonb_typeof(v_elem->'enemy_archetype_id') is distinct from 'string'
       or btrim(coalesce(v_elem->>'enemy_archetype_id','')) = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','archetype_id_required','field','enemy_archetype_id','message','each fleet member requires a non-empty enemy_archetype_id string.'));
    end if;
    -- min_count / max_count: REQUIRED finite integers in [0,100] with min <= max.
    if jsonb_typeof(v_elem->'min_count') is distinct from 'number'
       or (v_elem->'min_count')::numeric < 0 or (v_elem->'min_count')::numeric > 100
       or ((v_elem->'min_count')::numeric % 1) <> 0
       or jsonb_typeof(v_elem->'max_count') is distinct from 'number'
       or (v_elem->'max_count')::numeric < 0 or (v_elem->'max_count')::numeric > 100
       or ((v_elem->'max_count')::numeric % 1) <> 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','invalid_count_range','field','members','message','min_count and max_count must be integers in [0,100].'));
    elsif (v_elem->'min_count')::numeric > (v_elem->'max_count')::numeric then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','invalid_count_range','field','members','message','min_count must be <= max_count.'));
    end if;
    -- weight: OPTIONAL finite number in (0,1000].
    if v_elem ? 'weight'
       and (jsonb_typeof(v_elem->'weight') is distinct from 'number'
            or (v_elem->'weight')::numeric <= 0 or (v_elem->'weight')::numeric > 1000) then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','invalid_weight','field','weight','message','weight, if present, must be a finite number in (0,1000].'));
    end if;
    -- elite_chance: OPTIONAL finite number in [0,1].
    if v_elem ? 'elite_chance'
       and (jsonb_typeof(v_elem->'elite_chance') is distinct from 'number'
            or (v_elem->'elite_chance')::numeric < 0 or (v_elem->'elite_chance')::numeric > 1) then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','invalid_elite_chance','field','elite_chance','message','elite_chance, if present, must be a finite number in [0,1].'));
    end if;
  end loop;
  return v_details;
end $$;

revoke all on function public._fleet_members_valid_details(jsonb) from public;  -- internal only; NO client grant

-- ── 3c. _encounter_members_valid_details — THE ONE strict E1 encounter-member shape validator ──────
create or replace function public._encounter_members_valid_details(p_members jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_details jsonb := '[]'::jsonb;
  v_elem    jsonb;
  v_k       text;
begin
  if p_members is null or jsonb_typeof(p_members) <> 'array' or jsonb_array_length(p_members) < 1 then
    return jsonb_build_array(jsonb_build_object(
      'code','members_required','field','members','message','members must be a non-empty JSON array (at least one fleet template).'));
  end if;
  for v_elem in select value from jsonb_array_elements(p_members) loop
    if jsonb_typeof(v_elem) <> 'object' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','invalid_member','field','members','message','each encounter member must be a JSON object.'));
      continue;
    end if;
    -- allowlist: ONLY fleet_template_id / weight.
    for v_k in select key from jsonb_each(v_elem) loop
      if v_k not in ('fleet_template_id','weight') then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code','invalid_member','field','members.'||v_k,
          'message','Unknown member key '''||v_k||''' (allowed: fleet_template_id, weight).'));
      end if;
    end loop;
    if jsonb_typeof(v_elem->'fleet_template_id') is distinct from 'string'
       or btrim(coalesce(v_elem->>'fleet_template_id','')) = '' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','fleet_id_required','field','fleet_template_id','message','each encounter member requires a non-empty fleet_template_id string.'));
    end if;
    if v_elem ? 'weight'
       and (jsonb_typeof(v_elem->'weight') is distinct from 'number'
            or (v_elem->'weight')::numeric <= 0 or (v_elem->'weight')::numeric > 1000) then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','invalid_weight','field','weight','message','weight, if present, must be a finite number in (0,1000].'));
    end if;
  end loop;
  return v_details;
end $$;

revoke all on function public._encounter_members_valid_details(jsonb) from public;  -- internal only; NO client grant

-- ── 4. the SIX owner-gated write commands ─────────────────────────────────────────────────────────
-- Each (p_request_id text, p_payload jsonb) returns a typed {ok,request_id,result|error} envelope and
-- performs, IN ORDER: (1) FLAG GATE FIRST (reject-before-any-read: not_enabled); (2) authn
-- (not_authenticated); (3) authz via is_owner() (not_authorized); (4) blank request_id
-- (invalid_request); (5) idempotent replay on request_id (duplicate_request); (6) server re-validation
-- — key+display_name, the shape validator over p_payload->'members', THEN the in-body reference +
-- eligibility + duplicate loop (STABLE — each ref must EXIST and be active), encounter scalars/reward
-- override (validation_failed + details[]); (7 — update/set_active) optimistic revision on
-- expected_revision (stale_revision + source_changed); (8) apply (parent + REPLACE-ALL child) + exactly
-- one audit row in ONE sub-block (unique_violation disambiguated via GET STACKED DIAGNOSTICS:
-- world_editor_audit ⇒ idempotent replay, parent table ⇒ typed conflict/duplicate_key); (9) success.

-- ── 4a. enemy_fleet_template_create ────────────────────────────────────────────────────────────────
create or replace function public.enemy_fleet_template_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_details  jsonb := '[]'::jsonb;
  v_key      text;
  v_name     text;
  v_members  jsonb;
  v_snap     jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_rev      integer;
  v_tbl      text;
begin
  -- (1) DUAL-FLAG GATE FIRST — reject before ANY read. E1 references E0's tables, so encounter
  -- authoring must NOT run while E0's registry is still dark: BOTH flags must be true.
  if not (public.cfg_bool('enemy_content_registry_enabled') and public.cfg_bool('encounter_authoring_enabled')) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_enabled');
  end if;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'enemy_fleet_template_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (6) SERVER-SIDE re-validation.
  v_key     := btrim(coalesce(p_payload->>'key', ''));
  v_name    := btrim(coalesce(p_payload->>'display_name', ''));
  v_members := p_payload->'members';
  if v_key = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'key_required', 'field', 'key', 'message', 'key is required (enemy_fleet_templates.key is UNIQUE NOT NULL).'));
  end if;
  if v_name = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'name_required', 'field', 'display_name', 'message', 'display_name is required.'));
  end if;
  v_details := v_details || public._fleet_members_valid_details(v_members);
  -- in-body reference + eligibility + duplicate detection (STABLE — touches enemy_archetypes).
  if jsonb_typeof(v_members) = 'array' then
    declare v_m jsonb; v_aid text; v_auuid uuid; v_aactive boolean; v_seen text[] := array[]::text[];
    begin
      for v_m in select value from jsonb_array_elements(v_members) loop
        if jsonb_typeof(v_m) <> 'object' then continue; end if;
        v_aid := v_m->>'enemy_archetype_id';
        if v_aid is null or btrim(v_aid) = '' then continue; end if;   -- shape validator already flagged it
        if v_aid = any(v_seen) then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','duplicate_member','field','members','message','enemy_archetype_id '''||v_aid||''' appears more than once (fleet members must be distinct).'));
        else
          v_seen := array_append(v_seen, v_aid);
        end if;
        begin v_auuid := v_aid::uuid; exception when invalid_text_representation then v_auuid := null; end;
        if v_auuid is null then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','invalid_archetype_ref','field','enemy_archetype_id','message','enemy_archetype_id '''||v_aid||''' is not a valid archetype reference.'));
          continue;
        end if;
        select active into v_aactive from public.enemy_archetypes where id = v_auuid;
        if not found then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','invalid_archetype_ref','field','enemy_archetype_id','message','No enemy_archetypes row for the referenced id.'));
        elsif v_aactive is not true then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','archetype_inactive','field','enemy_archetype_id','message','The referenced enemy archetype is inactive — activate it before adding it to a fleet.'));
        end if;
      end loop;
    end;
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  -- (8) apply parent + members + audit in ONE sub-block (unique_violation disambiguated by table).
  begin
    insert into public.enemy_fleet_templates (key, display_name, notes)
      values (v_key, v_name, nullif(btrim(coalesce(p_payload->>'notes', '')), ''))
      returning id, revision into v_id, v_rev;

    insert into public.enemy_fleet_template_members
        (fleet_template_id, enemy_archetype_id, min_count, max_count, weight, elite_chance)
      select v_id, (elem->>'enemy_archetype_id')::uuid,
             (elem->>'min_count')::integer, (elem->>'max_count')::integer,
             coalesce((elem->>'weight')::double precision, 1),
             coalesce((elem->>'elite_chance')::double precision, 0)
      from jsonb_array_elements(v_members) as elem;

    select coalesce(jsonb_agg(jsonb_build_object(
             'enemy_archetype_id', enemy_archetype_id, 'min_count', min_count, 'max_count', max_count,
             'weight', weight, 'elite_chance', elite_chance) order by enemy_archetype_id), '[]'::jsonb)
      into v_snap from public.enemy_fleet_template_members where fleet_template_id = v_id;
    select jsonb_build_object(
             'id', id, 'key', key, 'display_name', display_name, 'active', active, 'revision', revision,
             'notes', notes, 'created_at', created_at, 'updated_at', updated_at, 'members', v_snap)
      into v_after from public.enemy_fleet_templates where id = v_id;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'key', v_key);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'enemy_fleet_template_create', 'enemy_fleet_template', v_key, v_result::text,
         null, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'enemy_fleet_template_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    if v_tbl = 'enemy_fleet_templates' then
      return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'duplicate_key', 'field', 'key', 'message', 'A fleet template with this key already exists.')));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'enemy_fleet_template_create', 'result', v_result);
end $$;

-- ── 4b. enemy_fleet_template_update — REPLACE-ALL members keyed to the parent revision ──────────────
create or replace function public.enemy_fleet_template_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_details  jsonb := '[]'::jsonb;
  v_target   text;
  v_name     text;
  v_members  jsonb;
  v_live     record;
  v_bsnap    jsonb;
  v_before   jsonb;
  v_snap     jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_rev      integer;
  v_tbl      text;
begin
  -- (1) DUAL-FLAG GATE FIRST — reject before ANY read. E1 references E0's tables, so encounter
  -- authoring must NOT run while E0's registry is still dark: BOTH flags must be true.
  if not (public.cfg_bool('enemy_content_registry_enabled') and public.cfg_bool('encounter_authoring_enabled')) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_enabled');
  end if;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'enemy_fleet_template_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (6) re-validate the mutable content fields (same rules as create; key is the address, not mutated).
  v_name    := btrim(coalesce(p_payload->>'display_name', ''));
  v_members := p_payload->'members';
  if v_name = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'name_required', 'field', 'display_name', 'message', 'display_name is required.'));
  end if;
  v_details := v_details || public._fleet_members_valid_details(v_members);
  if jsonb_typeof(v_members) = 'array' then
    declare v_m jsonb; v_aid text; v_auuid uuid; v_aactive boolean; v_seen text[] := array[]::text[];
    begin
      for v_m in select value from jsonb_array_elements(v_members) loop
        if jsonb_typeof(v_m) <> 'object' then continue; end if;
        v_aid := v_m->>'enemy_archetype_id';
        if v_aid is null or btrim(v_aid) = '' then continue; end if;
        if v_aid = any(v_seen) then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','duplicate_member','field','members','message','enemy_archetype_id '''||v_aid||''' appears more than once (fleet members must be distinct).'));
        else
          v_seen := array_append(v_seen, v_aid);
        end if;
        begin v_auuid := v_aid::uuid; exception when invalid_text_representation then v_auuid := null; end;
        if v_auuid is null then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','invalid_archetype_ref','field','enemy_archetype_id','message','enemy_archetype_id '''||v_aid||''' is not a valid archetype reference.'));
          continue;
        end if;
        select active into v_aactive from public.enemy_archetypes where id = v_auuid;
        if not found then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','invalid_archetype_ref','field','enemy_archetype_id','message','No enemy_archetypes row for the referenced id.'));
        elsif v_aactive is not true then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','archetype_inactive','field','enemy_archetype_id','message','The referenced enemy archetype is inactive — activate it before adding it to a fleet.'));
        end if;
      end loop;
    end;
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  -- (7a) LOCATE + ROW-LOCK the live target by its natural key.
  select id, key, display_name, active, revision, notes, created_at, updated_at
    into v_live from public.enemy_fleet_templates where key = v_target for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No fleet template with key ''' || v_target || ''' exists.')));
  end if;
  -- (7b) optimistic revision: compare expected_revision to the LOCKED row; mismatch ⇒ stale, write nothing.
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live fleet template revision changed since this draft was forked.')));
  end if;

  -- before_snapshot: parent + the CURRENT members (captured before the REPLACE-ALL).
  select coalesce(jsonb_agg(jsonb_build_object(
           'enemy_archetype_id', enemy_archetype_id, 'min_count', min_count, 'max_count', max_count,
           'weight', weight, 'elite_chance', elite_chance) order by enemy_archetype_id), '[]'::jsonb)
    into v_bsnap from public.enemy_fleet_template_members where fleet_template_id = v_live.id;
  v_before := jsonb_build_object(
                'id', v_live.id, 'key', v_live.key, 'display_name', v_live.display_name, 'active', v_live.active,
                'revision', v_live.revision, 'notes', v_live.notes,
                'created_at', v_live.created_at, 'updated_at', v_live.updated_at, 'members', v_bsnap);

  -- (8) apply: bump the parent (revision + updated_at), REPLACE-ALL the child, + one audit row.
  begin
    update public.enemy_fleet_templates
       set display_name = v_name,
           notes = nullif(btrim(coalesce(p_payload->>'notes', '')), ''),
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning id, revision into v_id, v_rev;

    delete from public.enemy_fleet_template_members where fleet_template_id = v_live.id;
    insert into public.enemy_fleet_template_members
        (fleet_template_id, enemy_archetype_id, min_count, max_count, weight, elite_chance)
      select v_id, (elem->>'enemy_archetype_id')::uuid,
             (elem->>'min_count')::integer, (elem->>'max_count')::integer,
             coalesce((elem->>'weight')::double precision, 1),
             coalesce((elem->>'elite_chance')::double precision, 0)
      from jsonb_array_elements(v_members) as elem;

    select coalesce(jsonb_agg(jsonb_build_object(
             'enemy_archetype_id', enemy_archetype_id, 'min_count', min_count, 'max_count', max_count,
             'weight', weight, 'elite_chance', elite_chance) order by enemy_archetype_id), '[]'::jsonb)
      into v_snap from public.enemy_fleet_template_members where fleet_template_id = v_id;
    select jsonb_build_object(
             'id', id, 'key', key, 'display_name', display_name, 'active', active, 'revision', revision,
             'notes', notes, 'created_at', created_at, 'updated_at', updated_at, 'members', v_snap)
      into v_after from public.enemy_fleet_templates where id = v_id;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'key', v_live.key);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'enemy_fleet_template_update', 'enemy_fleet_template', v_live.key, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'enemy_fleet_template_update', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;   -- key is the address, not mutated; a child unique would mean a duplicate slipped validation.
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'enemy_fleet_template_update', 'result', v_result);
end $$;

-- ── 4c. enemy_fleet_template_set_active — soft toggle (members untouched) ───────────────────────────
create or replace function public.enemy_fleet_template_set_active(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_target   text;
  v_active   boolean;
  v_live     record;
  v_snap     jsonb;
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_rev      integer;
  v_tbl      text;
begin
  -- (1) DUAL-FLAG GATE FIRST — reject before ANY read. E1 references E0's tables, so encounter
  -- authoring must NOT run while E0's registry is still dark: BOTH flags must be true.
  if not (public.cfg_bool('enemy_content_registry_enabled') and public.cfg_bool('encounter_authoring_enabled')) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_enabled');
  end if;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'enemy_fleet_template_set_active', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number'
     or jsonb_typeof(p_payload->'active') is distinct from 'boolean' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  v_active := (p_payload->>'active')::boolean;

  select id, key, display_name, active, revision, notes, created_at, updated_at
    into v_live from public.enemy_fleet_templates where key = v_target for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No fleet template with key ''' || v_target || ''' exists.')));
  end if;
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live fleet template revision changed since this draft was forked.')));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'enemy_archetype_id', enemy_archetype_id, 'min_count', min_count, 'max_count', max_count,
           'weight', weight, 'elite_chance', elite_chance) order by enemy_archetype_id), '[]'::jsonb)
    into v_snap from public.enemy_fleet_template_members where fleet_template_id = v_live.id;
  v_before := jsonb_build_object(
                'id', v_live.id, 'key', v_live.key, 'display_name', v_live.display_name, 'active', v_live.active,
                'revision', v_live.revision, 'notes', v_live.notes,
                'created_at', v_live.created_at, 'updated_at', v_live.updated_at, 'members', v_snap);
  begin
    update public.enemy_fleet_templates
       set active = v_active,
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning id, revision into v_id, v_rev;
    -- members survive untouched (soft toggle); re-read the parent for the after-snapshot.
    select jsonb_build_object(
             'id', id, 'key', key, 'display_name', display_name, 'active', active, 'revision', revision,
             'notes', notes, 'created_at', created_at, 'updated_at', updated_at, 'members', v_snap)
      into v_after from public.enemy_fleet_templates where id = v_id;

    v_result := jsonb_build_object('active_set', true, 'id', v_id, 'key', v_live.key, 'active', v_active);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'enemy_fleet_template_set_active', 'enemy_fleet_template', v_live.key, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'enemy_fleet_template_set_active', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'enemy_fleet_template_set_active', 'result', v_result);
end $$;

-- ── 4d. encounter_profile_create ───────────────────────────────────────────────────────────────────
create or replace function public.encounter_profile_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_details   jsonb := '[]'::jsonb;
  v_key       text;
  v_name      text;
  v_members   jsonb;
  v_diff      integer := 1;
  v_cap       integer := 1;
  v_cooldown  integer := 0;
  v_reward    uuid;
  v_snap      jsonb;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_rev       integer;
  v_tbl       text;
begin
  -- (1) DUAL-FLAG GATE FIRST — reject before ANY read. E1 references E0's tables, so encounter
  -- authoring must NOT run while E0's registry is still dark: BOTH flags must be true.
  if not (public.cfg_bool('enemy_content_registry_enabled') and public.cfg_bool('encounter_authoring_enabled')) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_enabled');
  end if;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'encounter_profile_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (6) SERVER-SIDE re-validation.
  v_key     := btrim(coalesce(p_payload->>'key', ''));
  v_name    := btrim(coalesce(p_payload->>'display_name', ''));
  v_members := p_payload->'members';
  if v_key = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'key_required', 'field', 'key', 'message', 'key is required (encounter_profiles.key is UNIQUE NOT NULL).'));
  end if;
  if v_name = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'name_required', 'field', 'display_name', 'message', 'display_name is required.'));
  end if;
  -- difficulty / active_encounter_cap / cooldown_seconds: OPTIONAL (default to the table default when
  -- absent) but a PRESENT value must be a finite integer inside the same [range] the CHECK enforces.
  if p_payload ? 'difficulty' then
    if jsonb_typeof(p_payload->'difficulty') is distinct from 'number'
       or (p_payload->'difficulty')::numeric < 1 or (p_payload->'difficulty')::numeric > 1000
       or ((p_payload->'difficulty')::numeric % 1) <> 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_difficulty', 'field', 'difficulty', 'message', 'difficulty must be an integer in [1,1000].'));
    else
      v_diff := (p_payload->'difficulty')::integer;
    end if;
  end if;
  if p_payload ? 'active_encounter_cap' then
    if jsonb_typeof(p_payload->'active_encounter_cap') is distinct from 'number'
       or (p_payload->'active_encounter_cap')::numeric < 1 or (p_payload->'active_encounter_cap')::numeric > 100
       or ((p_payload->'active_encounter_cap')::numeric % 1) <> 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_encounter_cap', 'field', 'active_encounter_cap', 'message', 'active_encounter_cap must be an integer in [1,100].'));
    else
      v_cap := (p_payload->'active_encounter_cap')::integer;
    end if;
  end if;
  if p_payload ? 'cooldown_seconds' then
    if jsonb_typeof(p_payload->'cooldown_seconds') is distinct from 'number'
       or (p_payload->'cooldown_seconds')::numeric < 0 or (p_payload->'cooldown_seconds')::numeric > 86400
       or ((p_payload->'cooldown_seconds')::numeric % 1) <> 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_cooldown', 'field', 'cooldown_seconds', 'message', 'cooldown_seconds must be an integer in [0,86400].'));
    else
      v_cooldown := (p_payload->'cooldown_seconds')::integer;
    end if;
  end if;
  -- reward_override_id: NULLABLE (null/absent ⇒ archetype default); if present-and-non-null it must
  -- reference an existing reward_profiles row.
  if p_payload ? 'reward_override_id' and jsonb_typeof(p_payload->'reward_override_id') <> 'null' then
    begin
      v_reward := nullif(btrim(coalesce(p_payload->>'reward_override_id', '')), '')::uuid;
    exception when invalid_text_representation then
      v_reward := null;
    end;
    if v_reward is null or not exists (select 1 from public.reward_profiles where id = v_reward) then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_reward_override', 'field', 'reward_override_id', 'message', 'reward_override_id, if present, must reference an existing reward_profiles row.'));
    end if;
  end if;
  v_details := v_details || public._encounter_members_valid_details(v_members);
  -- in-body reference + eligibility + duplicate detection (STABLE — touches enemy_fleet_templates).
  if jsonb_typeof(v_members) = 'array' then
    declare v_m jsonb; v_fid text; v_fuuid uuid; v_factive boolean; v_seen text[] := array[]::text[];
    begin
      for v_m in select value from jsonb_array_elements(v_members) loop
        if jsonb_typeof(v_m) <> 'object' then continue; end if;
        v_fid := v_m->>'fleet_template_id';
        if v_fid is null or btrim(v_fid) = '' then continue; end if;
        if v_fid = any(v_seen) then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','duplicate_member','field','members','message','fleet_template_id '''||v_fid||''' appears more than once (encounter members must be distinct).'));
        else
          v_seen := array_append(v_seen, v_fid);
        end if;
        begin v_fuuid := v_fid::uuid; exception when invalid_text_representation then v_fuuid := null; end;
        if v_fuuid is null then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','invalid_fleet_ref','field','fleet_template_id','message','fleet_template_id '''||v_fid||''' is not a valid fleet template reference.'));
          continue;
        end if;
        select active into v_factive from public.enemy_fleet_templates where id = v_fuuid;
        if not found then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','invalid_fleet_ref','field','fleet_template_id','message','No enemy_fleet_templates row for the referenced id.'));
        elsif v_factive is not true then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','fleet_inactive','field','fleet_template_id','message','The referenced fleet template is inactive — activate it before adding it to an encounter.'));
        end if;
      end loop;
    end;
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  -- (8) apply parent + members + audit in ONE sub-block.
  begin
    insert into public.encounter_profiles
        (key, display_name, difficulty, active_encounter_cap, cooldown_seconds, reward_override_id, notes)
      values (v_key, v_name, v_diff, v_cap, v_cooldown, v_reward,
              nullif(btrim(coalesce(p_payload->>'notes', '')), ''))
      returning id, revision into v_id, v_rev;

    insert into public.encounter_profile_members (encounter_profile_id, fleet_template_id, weight)
      select v_id, (elem->>'fleet_template_id')::uuid, coalesce((elem->>'weight')::double precision, 1)
      from jsonb_array_elements(v_members) as elem;

    select coalesce(jsonb_agg(jsonb_build_object(
             'fleet_template_id', fleet_template_id, 'weight', weight) order by fleet_template_id), '[]'::jsonb)
      into v_snap from public.encounter_profile_members where encounter_profile_id = v_id;
    select jsonb_build_object(
             'id', id, 'key', key, 'display_name', display_name, 'difficulty', difficulty,
             'active_encounter_cap', active_encounter_cap, 'cooldown_seconds', cooldown_seconds,
             'reward_override_id', reward_override_id, 'active', active, 'revision', revision,
             'notes', notes, 'created_at', created_at, 'updated_at', updated_at, 'members', v_snap)
      into v_after from public.encounter_profiles where id = v_id;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'key', v_key);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'encounter_profile_create', 'encounter_profile', v_key, v_result::text,
         null, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'encounter_profile_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    if v_tbl = 'encounter_profiles' then
      return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'duplicate_key', 'field', 'key', 'message', 'An encounter profile with this key already exists.')));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'encounter_profile_create', 'result', v_result);
end $$;

-- ── 4e. encounter_profile_update — REPLACE-ALL members keyed to the parent revision ─────────────────
create or replace function public.encounter_profile_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_details   jsonb := '[]'::jsonb;
  v_target    text;
  v_name      text;
  v_members   jsonb;
  v_diff      integer := 1;
  v_cap       integer := 1;
  v_cooldown  integer := 0;
  v_reward    uuid;
  v_live      record;
  v_bsnap     jsonb;
  v_before    jsonb;
  v_snap      jsonb;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_rev       integer;
  v_tbl       text;
begin
  -- (1) DUAL-FLAG GATE FIRST — reject before ANY read. E1 references E0's tables, so encounter
  -- authoring must NOT run while E0's registry is still dark: BOTH flags must be true.
  if not (public.cfg_bool('enemy_content_registry_enabled') and public.cfg_bool('encounter_authoring_enabled')) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_enabled');
  end if;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'encounter_profile_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (6) re-validate the mutable content fields (same rules as create; key is the address).
  v_name    := btrim(coalesce(p_payload->>'display_name', ''));
  v_members := p_payload->'members';
  if v_name = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'name_required', 'field', 'display_name', 'message', 'display_name is required.'));
  end if;
  if p_payload ? 'difficulty' then
    if jsonb_typeof(p_payload->'difficulty') is distinct from 'number'
       or (p_payload->'difficulty')::numeric < 1 or (p_payload->'difficulty')::numeric > 1000
       or ((p_payload->'difficulty')::numeric % 1) <> 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_difficulty', 'field', 'difficulty', 'message', 'difficulty must be an integer in [1,1000].'));
    else
      v_diff := (p_payload->'difficulty')::integer;
    end if;
  end if;
  if p_payload ? 'active_encounter_cap' then
    if jsonb_typeof(p_payload->'active_encounter_cap') is distinct from 'number'
       or (p_payload->'active_encounter_cap')::numeric < 1 or (p_payload->'active_encounter_cap')::numeric > 100
       or ((p_payload->'active_encounter_cap')::numeric % 1) <> 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_encounter_cap', 'field', 'active_encounter_cap', 'message', 'active_encounter_cap must be an integer in [1,100].'));
    else
      v_cap := (p_payload->'active_encounter_cap')::integer;
    end if;
  end if;
  if p_payload ? 'cooldown_seconds' then
    if jsonb_typeof(p_payload->'cooldown_seconds') is distinct from 'number'
       or (p_payload->'cooldown_seconds')::numeric < 0 or (p_payload->'cooldown_seconds')::numeric > 86400
       or ((p_payload->'cooldown_seconds')::numeric % 1) <> 0 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_cooldown', 'field', 'cooldown_seconds', 'message', 'cooldown_seconds must be an integer in [0,86400].'));
    else
      v_cooldown := (p_payload->'cooldown_seconds')::integer;
    end if;
  end if;
  if p_payload ? 'reward_override_id' and jsonb_typeof(p_payload->'reward_override_id') <> 'null' then
    begin
      v_reward := nullif(btrim(coalesce(p_payload->>'reward_override_id', '')), '')::uuid;
    exception when invalid_text_representation then
      v_reward := null;
    end;
    if v_reward is null or not exists (select 1 from public.reward_profiles where id = v_reward) then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_reward_override', 'field', 'reward_override_id', 'message', 'reward_override_id, if present, must reference an existing reward_profiles row.'));
    end if;
  end if;
  v_details := v_details || public._encounter_members_valid_details(v_members);
  if jsonb_typeof(v_members) = 'array' then
    declare v_m jsonb; v_fid text; v_fuuid uuid; v_factive boolean; v_seen text[] := array[]::text[];
    begin
      for v_m in select value from jsonb_array_elements(v_members) loop
        if jsonb_typeof(v_m) <> 'object' then continue; end if;
        v_fid := v_m->>'fleet_template_id';
        if v_fid is null or btrim(v_fid) = '' then continue; end if;
        if v_fid = any(v_seen) then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','duplicate_member','field','members','message','fleet_template_id '''||v_fid||''' appears more than once (encounter members must be distinct).'));
        else
          v_seen := array_append(v_seen, v_fid);
        end if;
        begin v_fuuid := v_fid::uuid; exception when invalid_text_representation then v_fuuid := null; end;
        if v_fuuid is null then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','invalid_fleet_ref','field','fleet_template_id','message','fleet_template_id '''||v_fid||''' is not a valid fleet template reference.'));
          continue;
        end if;
        select active into v_factive from public.enemy_fleet_templates where id = v_fuuid;
        if not found then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','invalid_fleet_ref','field','fleet_template_id','message','No enemy_fleet_templates row for the referenced id.'));
        elsif v_factive is not true then
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'code','fleet_inactive','field','fleet_template_id','message','The referenced fleet template is inactive — activate it before adding it to an encounter.'));
        end if;
      end loop;
    end;
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  select id, key, display_name, difficulty, active_encounter_cap, cooldown_seconds, reward_override_id,
         active, revision, notes, created_at, updated_at
    into v_live from public.encounter_profiles where key = v_target for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No encounter profile with key ''' || v_target || ''' exists.')));
  end if;
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live encounter profile revision changed since this draft was forked.')));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'fleet_template_id', fleet_template_id, 'weight', weight) order by fleet_template_id), '[]'::jsonb)
    into v_bsnap from public.encounter_profile_members where encounter_profile_id = v_live.id;
  v_before := jsonb_build_object(
                'id', v_live.id, 'key', v_live.key, 'display_name', v_live.display_name, 'difficulty', v_live.difficulty,
                'active_encounter_cap', v_live.active_encounter_cap, 'cooldown_seconds', v_live.cooldown_seconds,
                'reward_override_id', v_live.reward_override_id, 'active', v_live.active, 'revision', v_live.revision,
                'notes', v_live.notes, 'created_at', v_live.created_at, 'updated_at', v_live.updated_at, 'members', v_bsnap);

  begin
    update public.encounter_profiles
       set display_name = v_name,
           difficulty = v_diff,
           active_encounter_cap = v_cap,
           cooldown_seconds = v_cooldown,
           reward_override_id = v_reward,
           notes = nullif(btrim(coalesce(p_payload->>'notes', '')), ''),
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning id, revision into v_id, v_rev;

    delete from public.encounter_profile_members where encounter_profile_id = v_live.id;
    insert into public.encounter_profile_members (encounter_profile_id, fleet_template_id, weight)
      select v_id, (elem->>'fleet_template_id')::uuid, coalesce((elem->>'weight')::double precision, 1)
      from jsonb_array_elements(v_members) as elem;

    select coalesce(jsonb_agg(jsonb_build_object(
             'fleet_template_id', fleet_template_id, 'weight', weight) order by fleet_template_id), '[]'::jsonb)
      into v_snap from public.encounter_profile_members where encounter_profile_id = v_id;
    select jsonb_build_object(
             'id', id, 'key', key, 'display_name', display_name, 'difficulty', difficulty,
             'active_encounter_cap', active_encounter_cap, 'cooldown_seconds', cooldown_seconds,
             'reward_override_id', reward_override_id, 'active', active, 'revision', revision,
             'notes', notes, 'created_at', created_at, 'updated_at', updated_at, 'members', v_snap)
      into v_after from public.encounter_profiles where id = v_id;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'key', v_live.key);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'encounter_profile_update', 'encounter_profile', v_live.key, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'encounter_profile_update', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'encounter_profile_update', 'result', v_result);
end $$;

-- ── 4f. encounter_profile_set_active — soft toggle (members untouched) ──────────────────────────────
create or replace function public.encounter_profile_set_active(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_target   text;
  v_active   boolean;
  v_live     record;
  v_snap     jsonb;
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_rev      integer;
  v_tbl      text;
begin
  -- (1) DUAL-FLAG GATE FIRST — reject before ANY read. E1 references E0's tables, so encounter
  -- authoring must NOT run while E0's registry is still dark: BOTH flags must be true.
  if not (public.cfg_bool('enemy_content_registry_enabled') and public.cfg_bool('encounter_authoring_enabled')) then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_enabled');
  end if;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'encounter_profile_set_active', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number'
     or jsonb_typeof(p_payload->'active') is distinct from 'boolean' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  v_active := (p_payload->>'active')::boolean;

  select id, key, display_name, difficulty, active_encounter_cap, cooldown_seconds, reward_override_id,
         active, revision, notes, created_at, updated_at
    into v_live from public.encounter_profiles where key = v_target for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No encounter profile with key ''' || v_target || ''' exists.')));
  end if;
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live encounter profile revision changed since this draft was forked.')));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'fleet_template_id', fleet_template_id, 'weight', weight) order by fleet_template_id), '[]'::jsonb)
    into v_snap from public.encounter_profile_members where encounter_profile_id = v_live.id;
  v_before := jsonb_build_object(
                'id', v_live.id, 'key', v_live.key, 'display_name', v_live.display_name, 'difficulty', v_live.difficulty,
                'active_encounter_cap', v_live.active_encounter_cap, 'cooldown_seconds', v_live.cooldown_seconds,
                'reward_override_id', v_live.reward_override_id, 'active', v_live.active, 'revision', v_live.revision,
                'notes', v_live.notes, 'created_at', v_live.created_at, 'updated_at', v_live.updated_at, 'members', v_snap);
  begin
    update public.encounter_profiles
       set active = v_active,
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning id, revision into v_id, v_rev;
    select jsonb_build_object(
             'id', id, 'key', key, 'display_name', display_name, 'difficulty', difficulty,
             'active_encounter_cap', active_encounter_cap, 'cooldown_seconds', cooldown_seconds,
             'reward_override_id', reward_override_id, 'active', active, 'revision', revision,
             'notes', notes, 'created_at', created_at, 'updated_at', updated_at, 'members', v_snap)
      into v_after from public.encounter_profiles where id = v_id;

    v_result := jsonb_build_object('active_set', true, 'id', v_id, 'key', v_live.key, 'active', v_active);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'encounter_profile_set_active', 'encounter_profile', v_live.key, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'encounter_profile_set_active', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'encounter_profile_set_active', 'result', v_result);
end $$;

comment on function public.enemy_fleet_template_create(text, jsonb) is
  'FLEET TEMPLATES + ENCOUNTER PROFILES (0258): owner-gated CREATE for enemy_fleet_templates + its '
  'members behind the fail-closed encounter_authoring_enabled flag (checked FIRST). Members are '
  'REPLACE-ALL; each archetype ref must exist + be active. authenticated-only execute; NEVER anon.';
comment on function public.encounter_profile_create(text, jsonb) is
  'FLEET TEMPLATES + ENCOUNTER PROFILES (0258): owner-gated CREATE for encounter_profiles + its members '
  'behind the fail-closed encounter_authoring_enabled flag (checked FIRST). Each fleet ref must exist + '
  'be active; reward_override_id (nullable) must reference reward_profiles. authenticated-only; NEVER anon.';

-- ── 5. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.enemy_fleet_template_create(text, jsonb) from public;
revoke all on function public.enemy_fleet_template_update(text, jsonb) from public;
revoke all on function public.enemy_fleet_template_set_active(text, jsonb) from public;
revoke all on function public.encounter_profile_create(text, jsonb) from public;
revoke all on function public.encounter_profile_update(text, jsonb) from public;
revoke all on function public.encounter_profile_set_active(text, jsonb) from public;
grant execute on function public.enemy_fleet_template_create(text, jsonb) to authenticated;       -- guard in-body; NEVER anon
grant execute on function public.enemy_fleet_template_update(text, jsonb) to authenticated;       -- guard in-body; NEVER anon
grant execute on function public.enemy_fleet_template_set_active(text, jsonb) to authenticated;   -- guard in-body; NEVER anon
grant execute on function public.encounter_profile_create(text, jsonb) to authenticated;          -- guard in-body; NEVER anon
grant execute on function public.encounter_profile_update(text, jsonb) to authenticated;          -- guard in-body; NEVER anon
grant execute on function public.encounter_profile_set_active(text, jsonb) to authenticated;      -- guard in-body; NEVER anon

-- ── 6. seeds (mirror today's single-pirate wave; INERT while the surface is dark) ──────────────────
insert into public.enemy_fleet_templates (key, display_name) values
  ('pirate_light_solo', 'Solo Light Pirate')
on conflict (key) do nothing;

insert into public.enemy_fleet_template_members
    (fleet_template_id, enemy_archetype_id, min_count, max_count, weight, elite_chance)
  select ft.id, ea.id, 1, 1, 1, 0
  from (select id from public.enemy_fleet_templates where key = 'pirate_light_solo') as ft
  cross join (select id from public.enemy_archetypes where key = 'pirate_light') as ea
on conflict (fleet_template_id, enemy_archetype_id) do nothing;

insert into public.encounter_profiles (key, display_name, difficulty, active_encounter_cap, cooldown_seconds) values
  ('pirate_basic', 'Basic Pirate Encounter', 1, 1, 0)
on conflict (key) do nothing;

insert into public.encounter_profile_members (encounter_profile_id, fleet_template_id, weight)
  select ep.id, ft.id, 1
  from (select id from public.encounter_profiles where key = 'pirate_basic') as ep
  cross join (select id from public.enemy_fleet_templates where key = 'pirate_light_solo') as ft
on conflict (encounter_profile_id, fleet_template_id) do nothing;

-- ── 7. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $feassert$
declare
  v_fn  text;
  v_rel text;
begin
  -- (a) all four tables exist with RLS enabled.
  foreach v_rel in array array[
      'public.enemy_fleet_templates', 'public.enemy_fleet_template_members',
      'public.encounter_profiles', 'public.encounter_profile_members']
  loop
    if to_regclass(v_rel) is null then
      raise exception 'FLEET-ENCOUNTER self-assert FAIL: table % missing', v_rel;
    end if;
    if not (select relrowsecurity from pg_class where oid = v_rel::regclass) then
      raise exception 'FLEET-ENCOUNTER self-assert FAIL: RLS not enabled on %', v_rel;
    end if;
  end loop;

  -- (b) all six RPCs exist, are SECURITY DEFINER, authenticated may execute + anon may NOT.
  foreach v_fn in array array[
      'public.enemy_fleet_template_create(text,jsonb)', 'public.enemy_fleet_template_update(text,jsonb)',
      'public.enemy_fleet_template_set_active(text,jsonb)', 'public.encounter_profile_create(text,jsonb)',
      'public.encounter_profile_update(text,jsonb)', 'public.encounter_profile_set_active(text,jsonb)']
  loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FLEET-ENCOUNTER self-assert FAIL: RPC % missing', v_fn;
    end if;
    if not exists (select 1 from pg_proc where oid = v_fn::regprocedure and prosecdef) then
      raise exception 'FLEET-ENCOUNTER self-assert FAIL: RPC % is not SECURITY DEFINER', v_fn;
    end if;
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FLEET-ENCOUNTER self-assert FAIL: authenticated cannot execute % — the in-body guard would be unreachable', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FLEET-ENCOUNTER self-assert FAIL: anon CAN execute % — must be authenticated-only', v_fn;
    end if;
  end loop;

  -- (c) NO client-role write grant on ANY of the four tables — the only write path is the RPCs.
  foreach v_rel in array array[
      'public.enemy_fleet_templates', 'public.enemy_fleet_template_members',
      'public.encounter_profiles', 'public.encounter_profile_members']
  loop
    if has_table_privilege('authenticated', v_rel, 'INSERT')
       or has_table_privilege('authenticated', v_rel, 'UPDATE')
       or has_table_privilege('authenticated', v_rel, 'DELETE')
       or has_table_privilege('anon', v_rel, 'INSERT')
       or has_table_privilege('anon', v_rel, 'UPDATE')
       or has_table_privilege('anon', v_rel, 'DELETE') then
      raise exception 'FLEET-ENCOUNTER self-assert FAIL: a client role holds a write grant on % — the only write path must be the SECURITY DEFINER RPCs', v_rel;
    end if;
  end loop;

  -- (d) the fail-closed flag is present.
  if not exists (select 1 from public.game_config where key = 'encounter_authoring_enabled') then
    raise exception 'FLEET-ENCOUNTER self-assert FAIL: encounter_authoring_enabled flag not seeded';
  end if;

  -- (e) the 0243 idempotency key is intact (world_editor_audit.request_id single-column UNIQUE).
  if not exists (
    select 1 from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
    where c.conrelid = 'public.world_editor_audit'::regclass
      and c.contype = 'u' and array_length(c.conkey, 1) = 1 and a.attname = 'request_id'
  ) then
    raise exception 'FLEET-ENCOUNTER self-assert FAIL: world_editor_audit.request_id UNIQUE constraint missing (idempotency unenforced)';
  end if;

  -- (f) NO *_delete RPC exists anywhere in this surface — members are REPLACE-ALL, rows are soft-toggled.
  if to_regprocedure('public.enemy_fleet_template_delete(text,jsonb)') is not null
     or to_regprocedure('public.encounter_profile_delete(text,jsonb)') is not null then
    raise exception 'FLEET-ENCOUNTER self-assert FAIL: a *_delete RPC exists — this surface must have NO delete command';
  end if;

  -- (g) the three deactivation referential-integrity triggers exist (defense-in-depth on active true→false).
  if not exists (select 1 from pg_trigger where tgname = 'guard_archetype_deactivation'
                   and tgrelid = 'public.enemy_archetypes'::regclass and not tgisinternal) then
    raise exception 'FLEET-ENCOUNTER self-assert FAIL: guard_archetype_deactivation trigger missing on enemy_archetypes';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'guard_reward_profile_deactivation'
                   and tgrelid = 'public.reward_profiles'::regclass and not tgisinternal) then
    raise exception 'FLEET-ENCOUNTER self-assert FAIL: guard_reward_profile_deactivation trigger missing on reward_profiles';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'guard_fleet_template_deactivation'
                   and tgrelid = 'public.enemy_fleet_templates'::regclass and not tgisinternal) then
    raise exception 'FLEET-ENCOUNTER self-assert FAIL: guard_fleet_template_deactivation trigger missing on enemy_fleet_templates';
  end if;

  raise notice 'FLEET-ENCOUNTER self-assert ok: four tables (RLS on, no client write grant); all six RPCs SECURITY DEFINER + authenticated-only + anon-denied (DUAL-FLAG gated on enemy_content_registry_enabled AND encounter_authoring_enabled); encounter_authoring_enabled flag seeded; three deactivation-guard triggers present; world_editor_audit request_id UNIQUE intact; NO delete RPC';
end $feassert$;
