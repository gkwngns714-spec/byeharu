-- Byeharu — E0: ENEMY CONTENT REGISTRY — a NET-NEW, DARK, fail-closed, ADDITIVE authoring surface.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: two net-new owner-authored CATALOG tables — public.reward_profiles (the reusable
-- reward-formula parameterization) and public.enemy_archetypes (the reusable enemy TEMPLATE) — plus
-- SIX owner-gated write commands that author them, all behind a fail-closed feature flag. It is the
-- FIRST slice of the enemy-content program: a place to DEFINE enemy templates and reward profiles,
-- NOT to spawn or resolve them. It reproduces the established World Editor command spine
-- (0243/0244/0247/0250) step for step and reuses THE ONE owner guard (public.is_owner()), THE ONE
-- audit/idempotency ledger (public.world_editor_audit, incl. its 0244 before/after/source_revision
-- columns) and THE ONE boolean config accessor (public.cfg_bool) — no second authority anywhere.
--
-- WHAT THIS IS NOT — the DARK guarantee: NO runtime combat/reward path reads these two tables.
-- process_combat_ticks and reward_grant() are BYTE-IDENTICAL after this migration; the existing
-- pirate combat still scales off locations.base_difficulty and the game_config reward_* tunables
-- (combat_logic.sql:225-229). reward_profiles.resource_grants merely DOCUMENTS the SAME formula
-- params combat uses today ({"metal":{"base":10,"danger_coeff":0.25,"multiplier_ref":
-- "reward_multiplier"}}); it is authored data, read by nothing at runtime. enemy_archetypes carries
-- NO runtime-instance state (hp/position/target/status/encounter_id) — that stays on combat_units /
-- combat_encounters. Every one of the six RPCs checks cfg_bool('enemy_content_registry_enabled')
-- FIRST (reject-before-any-read) and the flag is seeded 'false' — so even deployed, the whole
-- surface is inert until an owner flips it, and even then only an owner (is_owner()) can write.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed on TWO independent axes: the
-- flag is false (every RPC returns 'not_enabled' before touching a row) AND is_owner() is false for
-- everyone until an owner is seeded. No client grant is widened: the table writes happen INSIDE these
-- SECURITY DEFINER functions only; client-role write grants on both tables are explicitly REVOKED
-- (a pure narrowing — RLS already denied them). Public SELECT is granted (read is harmless catalog).
--
-- NO-SPAGHETTI: ONE owner check (is_owner()), ONE audit ledger, ONE idempotency key, ONE flag
-- accessor (cfg_bool); no runtime combat path re-pointed; no reward_tier baked in (it is a
-- resolve-time LOCATION input, deferred); the audit snapshot columns are the 0244 ones (re-added by
-- NOTHING — the dependency gate asserts they exist). Out of scope (later slices): fleet/encounter/
-- zone-binding, the resolver that instantiates an archetype into combat_units, any UI, activation.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $regdep$
begin
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'ENEMY-REGISTRY: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'ENEMY-REGISTRY: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.cfg_bool(text)') is null then
    raise exception 'ENEMY-REGISTRY: public.cfg_bool(text) (0046) is missing — THE ONE boolean flag accessor must exist first';
  end if;
  if to_regclass('public.unit_types') is null then
    raise exception 'ENEMY-REGISTRY: public.unit_types (0004) is missing — enemy_archetypes.unit_type_id references it';
  end if;
  if to_regclass('public.game_config') is null then
    raise exception 'ENEMY-REGISTRY: public.game_config (0003) is missing — the fail-closed flag lives here';
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
    raise exception 'ENEMY-REGISTRY: a 0244 audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing — the snapshot columns must exist first';
  end if;
end $regdep$;

-- ── 1. reward_profiles — the reusable reward-formula parameterization (owner-authored catalog) ─────
-- resource_grants ENCAPSULATES the existing reward map: e.g.
--   {"metal":{"base":10,"danger_coeff":0.25,"multiplier_ref":"reward_multiplier"}}
-- which documents the SAME params combat_logic.sql:225-229 uses today. reward_tier is DELIBERATELY
-- absent — it is a resolve-time location input, deferred. NOTHING at runtime reads this table.
create table if not exists public.reward_profiles (
  id              uuid primary key default gen_random_uuid(),
  key             text unique not null,
  display_name    text not null,
  resource_grants jsonb not null default '{}'::jsonb,
  active          boolean not null default true,
  revision        integer not null default 1 check (revision >= 1),
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table public.reward_profiles is
  'ENEMY CONTENT REGISTRY (0257): owner-authored, DARK catalog of reusable reward-formula '
  'parameterizations. resource_grants documents the SAME reward params combat uses today (base / '
  'danger_coeff / multiplier_ref) — authored data read by NOTHING at runtime (combat still scales '
  'off game_config reward_* tunables). Public SELECT; writes ONLY through the owner-gated 0257 RPCs '
  'behind the fail-closed enemy_content_registry_enabled flag. reward_tier is NOT baked in (a '
  'resolve-time location input, deferred).';

alter table public.reward_profiles enable row level security;
create policy "reward_profiles_public_read" on public.reward_profiles for select using (true);
grant select on table public.reward_profiles to anon, authenticated;
-- belt-and-braces NARROWING: RLS already denies client writes (no write policy); revoke the Supabase
-- default table write grants so the privilege matrix is unambiguous and self-assertable.
revoke insert, update, delete on table public.reward_profiles from anon, authenticated;

-- ── 2. enemy_archetypes — the reusable enemy TEMPLATE (owner-authored catalog; NO runtime state) ───
-- base_difficulty is the SAME scalar combat uses today (locations.base_difficulty). unit_type_id
-- anchors the template to the inert 'pirate_synthetic' catalog identity (0234). NO runtime-instance
-- state (hp/position/target/status/encounter_id) — that stays on combat_units / combat_encounters.
create table if not exists public.enemy_archetypes (
  id                        uuid primary key default gen_random_uuid(),
  key                       text unique not null,
  display_name              text not null,
  faction                   text not null default 'pirate',
  unit_type_id              text not null references public.unit_types(id),
  behavior_key              text not null default 'spatial_synthetic',
  -- base_difficulty mirrors locations.base_difficulty (default 0). The upper bound 1000 is a
  -- defensible sanity cap: the seeded max is 25 (pirate_heavy), so 1000 leaves ~40x headroom while
  -- still rejecting pathological / non-finite values (a double precision column could otherwise hold
  -- NaN — which fails `<= 1000` in Postgres ordering — or +Infinity, also rejected). The server
  -- validators enforce the same [0,1000] range before any write.
  base_difficulty           double precision not null default 0 check (base_difficulty >= 0 and base_difficulty <= 1000),
  default_reward_profile_id uuid not null references public.reward_profiles(id),
  difficulty_rating         integer not null default 1 check (difficulty_rating >= 1),
  stat_overrides            jsonb not null default '{}'::jsonb,
  active                    boolean not null default true,
  revision                  integer not null default 1 check (revision >= 1),
  notes                     text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

comment on table public.enemy_archetypes is
  'ENEMY CONTENT REGISTRY (0257): owner-authored, DARK catalog of reusable enemy TEMPLATES. '
  'base_difficulty mirrors the scalar combat uses today (locations.base_difficulty); unit_type_id '
  'anchors to the inert pirate_synthetic identity (0234); default_reward_profile_id references '
  'reward_profiles. Carries NO runtime-instance state (hp/position/target/status/encounter_id lives '
  'on combat_units/combat_encounters). Read by NOTHING at runtime — existing pirate combat is '
  'byte-identical. Public SELECT; writes ONLY through the owner-gated 0257 RPCs behind the '
  'fail-closed enemy_content_registry_enabled flag.';

alter table public.enemy_archetypes enable row level security;
create policy "enemy_archetypes_public_read" on public.enemy_archetypes for select using (true);
grant select on table public.enemy_archetypes to anon, authenticated;
revoke insert, update, delete on table public.enemy_archetypes from anon, authenticated;

-- ── 3. fail-closed feature flag (seeded false; do NOT overwrite if already set) ────────────────────
insert into public.game_config (key, value, description) values
  ('enemy_content_registry_enabled', 'false',
   'E0 dark gate for enemy_archetypes/reward_profiles owner-write RPCs; OFF until owner enables; '
   'every registry RPC checks cfg_bool(this) FIRST (reject-before-any-read); no runtime combat path '
   'reads these tables; existing pirate combat byte-identical')
on conflict (key) do nothing;

-- ── 3b. _reward_grants_valid_details — THE ONE strict E0 resource_grants shape validator ───────────
-- resource_grants is authoring data, NOT arbitrary JSON: it documents the SAME reward-formula params
-- combat uses today (combat_logic.sql:225-229). E0 pins the exact shape so a malformed/expansive map
-- can never be authored: the ONLY top-level key is 'metal'; within metal the ONLY keys are base
-- (required, finite number >= 0), danger_coeff (optional, finite number >= 0) and multiplier_ref
-- (required, the LITERAL string 'reward_multiplier'). jsonb cannot encode NaN/Infinity, so
-- jsonb_typeof='number' already means "finite"; a nested object / non-scalar under a numeric key has
-- jsonb_typeof<>'number' and is rejected. Returns a details[] (empty ⇒ valid) so BOTH the create and
-- the update RPC share ONE authority (no forked copy). IMMUTABLE, pure (touches no table); called
-- only from the SECURITY DEFINER RPCs (owned by the same role — no client execute grant needed).
create or replace function public._reward_grants_valid_details(p_grants jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_details jsonb := '[]'::jsonb;
  v_metal   jsonb;
  v_k       text;
begin
  if p_grants is null or jsonb_typeof(p_grants) <> 'object' then
    return jsonb_build_array(jsonb_build_object(
      'code','invalid_resource_grants','field','resource_grants','message','resource_grants must be a JSON object.'));
  end if;
  -- ONLY 'metal' is an allowed top-level resource key — reject any other/unknown key.
  for v_k in select key from jsonb_each(p_grants) loop
    if v_k <> 'metal' then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','invalid_resource_grants','field','resource_grants',
        'message','Unknown resource key '''||v_k||''' (only ''metal'' is allowed in E0).'));
    end if;
  end loop;
  v_metal := p_grants->'metal';
  if v_metal is null or jsonb_typeof(v_metal) <> 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code','invalid_resource_grants','field','metal','message','resource_grants.metal must be a JSON object with base + multiplier_ref.'));
    return v_details;   -- nothing further to check under a missing/malformed metal.
  end if;
  -- within metal only base / danger_coeff / multiplier_ref are allowed (reject unknown/nested keys).
  for v_k in select key from jsonb_each(v_metal) loop
    if v_k not in ('base','danger_coeff','multiplier_ref') then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code','invalid_resource_grants','field','metal.'||v_k,'message','Unknown key '''||v_k||''' under metal (allowed: base, danger_coeff, multiplier_ref).'));
    end if;
  end loop;
  -- base: REQUIRED, finite number >= 0 (a nested object / non-scalar has jsonb_typeof<>'number').
  if jsonb_typeof(v_metal->'base') is distinct from 'number' or (v_metal->'base')::numeric < 0 then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code','invalid_resource_grants','field','metal.base','message','metal.base must be a finite number >= 0.'));
  end if;
  -- danger_coeff: OPTIONAL, finite number >= 0 when present.
  if v_metal ? 'danger_coeff'
     and (jsonb_typeof(v_metal->'danger_coeff') is distinct from 'number' or (v_metal->'danger_coeff')::numeric < 0) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code','invalid_resource_grants','field','metal.danger_coeff','message','metal.danger_coeff, if present, must be a finite number >= 0.'));
  end if;
  -- multiplier_ref: REQUIRED, exactly the literal string 'reward_multiplier' (no other config ref).
  if jsonb_typeof(v_metal->'multiplier_ref') is distinct from 'string'
     or (v_metal->>'multiplier_ref') is distinct from 'reward_multiplier' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code','invalid_resource_grants','field','metal.multiplier_ref','message','metal.multiplier_ref must equal the literal string ''reward_multiplier''.'));
  end if;
  return v_details;
end $$;

revoke all on function public._reward_grants_valid_details(jsonb) from public;  -- internal only; NO client grant

-- ── 4. the SIX owner-gated write commands ─────────────────────────────────────────────────────────
-- Each (p_request_id text, p_payload jsonb) returns a typed {ok,request_id,result|error} envelope
-- and performs, IN ORDER: (1) FLAG GATE FIRST (reject-before-any-read: not_enabled); (2) authn
-- (not_authenticated); (3) authz via is_owner() (not_authorized); (4) blank request_id
-- (invalid_request); (5) idempotent replay on request_id (duplicate_request); (6) server
-- re-validation (validation_failed + details[]); (7 — update/set_active) optimistic revision on
-- expected_revision (stale_revision + source_changed); (8) apply + exactly one audit row in ONE
-- sub-block (unique_violation disambiguated via GET STACKED DIAGNOSTICS: world_editor_audit ⇒
-- idempotent replay, content table ⇒ typed conflict/duplicate_key); (9) typed success.

-- ── 4a. reward_profile_create ─────────────────────────────────────────────────────────────────────
create or replace function public.reward_profile_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_details jsonb := '[]'::jsonb;
  v_key     text;
  v_name    text;
  v_grants  jsonb;
  v_after   jsonb;
  v_result  jsonb;
  v_prior   text;
  v_id      uuid;
  v_rev     integer;
  v_tbl     text;
begin
  -- (1) FLAG GATE FIRST — reject before ANY read while the registry is dark.
  if not public.cfg_bool('enemy_content_registry_enabled') then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_enabled');
  end if;
  -- (2) authn.
  if v_uid is null then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authenticated');
  end if;
  -- (3) authz — THE ONE guard.
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_authorized');
  end if;
  -- (4) request_id is the idempotency key.
  if p_request_id is null or length(btrim(p_request_id)) = 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  -- (5) idempotent replay.
  select result into v_prior from public.world_editor_audit where request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'request_id', p_request_id,
             'command_type', 'reward_profile_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (6) SERVER-SIDE re-validation (the client validator is never trusted).
  v_key  := btrim(coalesce(p_payload->>'key', ''));
  v_name := btrim(coalesce(p_payload->>'display_name', ''));
  if v_key = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'key_required', 'field', 'key', 'message', 'key is required (reward_profiles.key is UNIQUE NOT NULL).'));
  end if;
  if v_name = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'name_required', 'field', 'display_name', 'message', 'display_name is required.'));
  end if;
  -- resource_grants: THE ONE strict E0 shape validator (only metal.{base,danger_coeff,multiplier_ref}).
  v_grants := p_payload->'resource_grants';
  v_details := v_details || public._reward_grants_valid_details(v_grants);
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  -- (8) apply + audit in ONE sub-block (unique_violation disambiguated by table).
  begin
    insert into public.reward_profiles (key, display_name, resource_grants, notes)
      values (v_key, v_name, v_grants, nullif(btrim(coalesce(p_payload->>'notes', '')), ''))
      returning jsonb_build_object(
                  'id', id, 'key', key, 'display_name', display_name, 'resource_grants', resource_grants,
                  'active', active, 'revision', revision, 'notes', notes,
                  'created_at', created_at, 'updated_at', updated_at),
                id, revision
        into v_after, v_id, v_rev;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'key', v_key);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'reward_profile_create', 'reward_profile', v_key, v_result::text,
         null, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'reward_profile_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_key', 'field', 'key', 'message', 'A reward profile with this key already exists.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'reward_profile_create', 'result', v_result);
end $$;

-- ── 4b. reward_profile_update ─────────────────────────────────────────────────────────────────────
create or replace function public.reward_profile_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
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
  v_grants   jsonb;
  v_live     record;
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_rev      integer;
  v_tbl      text;
begin
  if not public.cfg_bool('enemy_content_registry_enabled') then
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
             'command_type', 'reward_profile_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- structural addressing: target_id (the key) + a numeric expected_revision, or malformed request.
  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (6) re-validate the mutable content fields (same rules as create; key is the address, not mutated).
  v_name := btrim(coalesce(p_payload->>'display_name', ''));
  if v_name = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'name_required', 'field', 'display_name', 'message', 'display_name is required.'));
  end if;
  -- resource_grants: THE ONE strict E0 shape validator (shared with reward_profile_create).
  v_grants := p_payload->'resource_grants';
  v_details := v_details || public._reward_grants_valid_details(v_grants);
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  -- (7a) LOCATE + ROW-LOCK the live target by its natural key.
  select id, key, display_name, resource_grants, active, revision, notes, created_at, updated_at
    into v_live from public.reward_profiles where key = v_target for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No reward profile with key ''' || v_target || ''' exists.')));
  end if;

  -- (7b) optimistic revision: compare expected_revision to the LOCKED row; mismatch ⇒ stale, write nothing.
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live reward profile revision changed since this draft was forked.')));
  end if;

  -- (8) apply (bump revision + updated_at) + exactly one audit row (before + after).
  v_before := jsonb_build_object(
                'id', v_live.id, 'key', v_live.key, 'display_name', v_live.display_name,
                'resource_grants', v_live.resource_grants, 'active', v_live.active,
                'revision', v_live.revision, 'notes', v_live.notes,
                'created_at', v_live.created_at, 'updated_at', v_live.updated_at);
  begin
    update public.reward_profiles
       set display_name = v_name,
           resource_grants = v_grants,
           notes = nullif(btrim(coalesce(p_payload->>'notes', '')), ''),
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'key', key, 'display_name', display_name, 'resource_grants', resource_grants,
                 'active', active, 'revision', revision, 'notes', notes,
                 'created_at', created_at, 'updated_at', updated_at),
               id, revision
       into v_after, v_id, v_rev;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'key', v_live.key);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'reward_profile_update', 'reward_profile', v_live.key, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'reward_profile_update', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;   -- no other unique key is touched by an update (key is not mutated) — surface loudly.
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'reward_profile_update', 'result', v_result);
end $$;

-- ── 4c. reward_profile_set_active ─────────────────────────────────────────────────────────────────
create or replace function public.reward_profile_set_active(p_request_id text, p_payload jsonb default '{}'::jsonb)
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
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_rev      integer;
  v_tbl      text;
begin
  if not public.cfg_bool('enemy_content_registry_enabled') then
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
             'command_type', 'reward_profile_set_active', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- structural addressing: target_id (the key) + numeric expected_revision + a boolean direction.
  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number'
     or jsonb_typeof(p_payload->'active') is distinct from 'boolean' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  v_active := (p_payload->>'active')::boolean;

  select id, key, display_name, resource_grants, active, revision, notes, created_at, updated_at
    into v_live from public.reward_profiles where key = v_target for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No reward profile with key ''' || v_target || ''' exists.')));
  end if;
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live reward profile revision changed since this draft was forked.')));
  end if;

  v_before := jsonb_build_object(
                'id', v_live.id, 'key', v_live.key, 'display_name', v_live.display_name,
                'resource_grants', v_live.resource_grants, 'active', v_live.active,
                'revision', v_live.revision, 'notes', v_live.notes,
                'created_at', v_live.created_at, 'updated_at', v_live.updated_at);
  begin
    update public.reward_profiles
       set active = v_active,
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'key', key, 'display_name', display_name, 'resource_grants', resource_grants,
                 'active', active, 'revision', revision, 'notes', notes,
                 'created_at', created_at, 'updated_at', updated_at),
               id, revision
       into v_after, v_id, v_rev;

    v_result := jsonb_build_object('active_set', true, 'id', v_id, 'key', v_live.key, 'active', v_active);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'reward_profile_set_active', 'reward_profile', v_live.key, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'reward_profile_set_active', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'reward_profile_set_active', 'result', v_result);
end $$;

-- ── 4d. enemy_archetype_create ────────────────────────────────────────────────────────────────────
create or replace function public.enemy_archetype_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_details jsonb := '[]'::jsonb;
  v_key     text;
  v_name    text;
  v_unit    text;
  v_profile uuid;
  v_diff    numeric;
  v_rating  numeric;
  v_after   jsonb;
  v_result  jsonb;
  v_prior   text;
  v_id      uuid;
  v_rev     integer;
  v_tbl     text;
begin
  if not public.cfg_bool('enemy_content_registry_enabled') then
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
             'command_type', 'enemy_archetype_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (6) SERVER-SIDE re-validation.
  v_key  := btrim(coalesce(p_payload->>'key', ''));
  v_name := btrim(coalesce(p_payload->>'display_name', ''));
  v_unit := btrim(coalesce(p_payload->>'unit_type_id', ''));
  if v_key = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'key_required', 'field', 'key', 'message', 'key is required (enemy_archetypes.key is UNIQUE NOT NULL).'));
  end if;
  if v_name = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'name_required', 'field', 'display_name', 'message', 'display_name is required.'));
  end if;
  -- base_difficulty: finite (jsonb numbers cannot be NaN/Infinity) and within [0,1000] — the same
  -- sanity range the table CHECK enforces (seeded max is 25; 1000 is generous headroom).
  if jsonb_typeof(p_payload->'base_difficulty') is distinct from 'number'
     or (p_payload->'base_difficulty')::numeric < 0
     or (p_payload->'base_difficulty')::numeric > 1000 then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'base_difficulty_invalid', 'field', 'base_difficulty', 'message', 'base_difficulty must be a finite number in [0, 1000].'));
  else
    v_diff := (p_payload->'base_difficulty')::numeric;
  end if;
  if jsonb_typeof(p_payload->'difficulty_rating') is distinct from 'number'
     or (p_payload->'difficulty_rating')::numeric < 1
     or ((p_payload->'difficulty_rating')::numeric % 1) <> 0 then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'difficulty_rating_invalid', 'field', 'difficulty_rating', 'message', 'difficulty_rating must be a positive integer.'));
  else
    v_rating := (p_payload->'difficulty_rating')::numeric;
  end if;
  -- unit_type_id: RESTRICTED to the synthetic-enemy identity anchor 'pirate_synthetic' (0234). The FK
  -- alone would accept ANY unit_types row (incl. a real player-ship type like 'frigate'); E0 enemies
  -- are only ever the synthetic anchor. unit_types has no explicit enemy-eligibility column
  -- (status='disabled' is a weak signal — it is the anchor's incidental state, not an eligibility
  -- flag), so we pin the exact id. An update re-runs this, so an archetype can never be moved onto an
  -- ineligible unit_type. The existence check is belt-and-braces (the anchor is seeded by 0234).
  if v_unit is distinct from 'pirate_synthetic'
     or not exists (select 1 from public.unit_types where id = v_unit) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_unit_type', 'field', 'unit_type_id', 'message', 'unit_type_id must be the synthetic-enemy anchor ''pirate_synthetic''.'));
  end if;
  begin
    v_profile := nullif(btrim(coalesce(p_payload->>'default_reward_profile_id', '')), '')::uuid;
  exception when invalid_text_representation then
    v_profile := null;
  end;
  if v_profile is null or not exists (select 1 from public.reward_profiles where id = v_profile) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_reward_profile', 'field', 'default_reward_profile_id', 'message', 'default_reward_profile_id must reference an existing reward_profiles row.'));
  end if;
  if p_payload ? 'stat_overrides' and jsonb_typeof(p_payload->'stat_overrides') is distinct from 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'stat_overrides_invalid', 'field', 'stat_overrides', 'message', 'stat_overrides, if present, must be a JSON object.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  -- (8) apply + audit in ONE sub-block.
  begin
    insert into public.enemy_archetypes
        (key, display_name, faction, unit_type_id, behavior_key, base_difficulty,
         default_reward_profile_id, difficulty_rating, stat_overrides, notes)
      values
        (v_key, v_name,
         coalesce(nullif(btrim(coalesce(p_payload->>'faction', '')), ''), 'pirate'),
         v_unit,
         coalesce(nullif(btrim(coalesce(p_payload->>'behavior_key', '')), ''), 'spatial_synthetic'),
         v_diff::double precision, v_profile, v_rating::integer,
         coalesce(p_payload->'stat_overrides', '{}'::jsonb),
         nullif(btrim(coalesce(p_payload->>'notes', '')), ''))
      returning jsonb_build_object(
                  'id', id, 'key', key, 'display_name', display_name, 'faction', faction,
                  'unit_type_id', unit_type_id, 'behavior_key', behavior_key, 'base_difficulty', base_difficulty,
                  'default_reward_profile_id', default_reward_profile_id, 'difficulty_rating', difficulty_rating,
                  'stat_overrides', stat_overrides, 'active', active, 'revision', revision, 'notes', notes,
                  'created_at', created_at, 'updated_at', updated_at),
                id, revision
        into v_after, v_id, v_rev;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'key', v_key);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'enemy_archetype_create', 'enemy_archetype', v_key, v_result::text,
         null, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'enemy_archetype_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'duplicate_key', 'field', 'key', 'message', 'An enemy archetype with this key already exists.')));
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'enemy_archetype_create', 'result', v_result);
end $$;

-- ── 4e. enemy_archetype_update ────────────────────────────────────────────────────────────────────
create or replace function public.enemy_archetype_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
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
  v_unit     text;
  v_profile  uuid;
  v_diff     numeric;
  v_rating   numeric;
  v_live     record;
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_rev      integer;
  v_tbl      text;
begin
  if not public.cfg_bool('enemy_content_registry_enabled') then
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
             'command_type', 'enemy_archetype_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (6) re-validate the mutable content fields (same rules as create; key is the address).
  v_name := btrim(coalesce(p_payload->>'display_name', ''));
  v_unit := btrim(coalesce(p_payload->>'unit_type_id', ''));
  if v_name = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'name_required', 'field', 'display_name', 'message', 'display_name is required.'));
  end if;
  -- base_difficulty: finite (jsonb numbers cannot be NaN/Infinity) and within [0,1000] — the same
  -- sanity range the table CHECK enforces (seeded max is 25; 1000 is generous headroom).
  if jsonb_typeof(p_payload->'base_difficulty') is distinct from 'number'
     or (p_payload->'base_difficulty')::numeric < 0
     or (p_payload->'base_difficulty')::numeric > 1000 then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'base_difficulty_invalid', 'field', 'base_difficulty', 'message', 'base_difficulty must be a finite number in [0, 1000].'));
  else
    v_diff := (p_payload->'base_difficulty')::numeric;
  end if;
  if jsonb_typeof(p_payload->'difficulty_rating') is distinct from 'number'
     or (p_payload->'difficulty_rating')::numeric < 1
     or ((p_payload->'difficulty_rating')::numeric % 1) <> 0 then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'difficulty_rating_invalid', 'field', 'difficulty_rating', 'message', 'difficulty_rating must be a positive integer.'));
  else
    v_rating := (p_payload->'difficulty_rating')::numeric;
  end if;
  -- unit_type_id: RESTRICTED to the synthetic-enemy identity anchor 'pirate_synthetic' (0234). The FK
  -- alone would accept ANY unit_types row (incl. a real player-ship type like 'frigate'); E0 enemies
  -- are only ever the synthetic anchor. unit_types has no explicit enemy-eligibility column
  -- (status='disabled' is a weak signal — it is the anchor's incidental state, not an eligibility
  -- flag), so we pin the exact id. An update re-runs this, so an archetype can never be moved onto an
  -- ineligible unit_type. The existence check is belt-and-braces (the anchor is seeded by 0234).
  if v_unit is distinct from 'pirate_synthetic'
     or not exists (select 1 from public.unit_types where id = v_unit) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_unit_type', 'field', 'unit_type_id', 'message', 'unit_type_id must be the synthetic-enemy anchor ''pirate_synthetic''.'));
  end if;
  begin
    v_profile := nullif(btrim(coalesce(p_payload->>'default_reward_profile_id', '')), '')::uuid;
  exception when invalid_text_representation then
    v_profile := null;
  end;
  if v_profile is null or not exists (select 1 from public.reward_profiles where id = v_profile) then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_reward_profile', 'field', 'default_reward_profile_id', 'message', 'default_reward_profile_id must reference an existing reward_profiles row.'));
  end if;
  if p_payload ? 'stat_overrides' and jsonb_typeof(p_payload->'stat_overrides') is distinct from 'object' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'stat_overrides_invalid', 'field', 'stat_overrides', 'message', 'stat_overrides, if present, must be a JSON object.'));
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  select id, key, display_name, faction, unit_type_id, behavior_key, base_difficulty,
         default_reward_profile_id, difficulty_rating, stat_overrides, active, revision, notes, created_at, updated_at
    into v_live from public.enemy_archetypes where key = v_target for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No enemy archetype with key ''' || v_target || ''' exists.')));
  end if;
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live enemy archetype revision changed since this draft was forked.')));
  end if;

  v_before := to_jsonb(v_live);
  begin
    update public.enemy_archetypes
       set display_name = v_name,
           faction = coalesce(nullif(btrim(coalesce(p_payload->>'faction', '')), ''), 'pirate'),
           unit_type_id = v_unit,
           behavior_key = coalesce(nullif(btrim(coalesce(p_payload->>'behavior_key', '')), ''), 'spatial_synthetic'),
           base_difficulty = v_diff::double precision,
           default_reward_profile_id = v_profile,
           difficulty_rating = v_rating::integer,
           stat_overrides = coalesce(p_payload->'stat_overrides', '{}'::jsonb),
           notes = nullif(btrim(coalesce(p_payload->>'notes', '')), ''),
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'key', key, 'display_name', display_name, 'faction', faction,
                 'unit_type_id', unit_type_id, 'behavior_key', behavior_key, 'base_difficulty', base_difficulty,
                 'default_reward_profile_id', default_reward_profile_id, 'difficulty_rating', difficulty_rating,
                 'stat_overrides', stat_overrides, 'active', active, 'revision', revision, 'notes', notes,
                 'created_at', created_at, 'updated_at', updated_at),
               id, revision
       into v_after, v_id, v_rev;

    v_result := jsonb_build_object('updated', true, 'id', v_id, 'key', v_live.key);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'enemy_archetype_update', 'enemy_archetype', v_live.key, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'enemy_archetype_update', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'enemy_archetype_update', 'result', v_result);
end $$;

-- ── 4f. enemy_archetype_set_active ────────────────────────────────────────────────────────────────
create or replace function public.enemy_archetype_set_active(p_request_id text, p_payload jsonb default '{}'::jsonb)
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
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_rev      integer;
  v_tbl      text;
begin
  if not public.cfg_bool('enemy_content_registry_enabled') then
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
             'command_type', 'enemy_archetype_set_active', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number'
     or jsonb_typeof(p_payload->'active') is distinct from 'boolean' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  v_active := (p_payload->>'active')::boolean;

  select id, key, display_name, faction, unit_type_id, behavior_key, base_difficulty,
         default_reward_profile_id, difficulty_rating, stat_overrides, active, revision, notes, created_at, updated_at
    into v_live from public.enemy_archetypes where key = v_target for update;
  if not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No enemy archetype with key ''' || v_target || ''' exists.')));
  end if;
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live enemy archetype revision changed since this draft was forked.')));
  end if;

  v_before := to_jsonb(v_live);
  begin
    update public.enemy_archetypes
       set active = v_active,
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning jsonb_build_object(
                 'id', id, 'key', key, 'display_name', display_name, 'faction', faction,
                 'unit_type_id', unit_type_id, 'behavior_key', behavior_key, 'base_difficulty', base_difficulty,
                 'default_reward_profile_id', default_reward_profile_id, 'difficulty_rating', difficulty_rating,
                 'stat_overrides', stat_overrides, 'active', active, 'revision', revision, 'notes', notes,
                 'created_at', created_at, 'updated_at', updated_at),
               id, revision
       into v_after, v_id, v_rev;

    v_result := jsonb_build_object('active_set', true, 'id', v_id, 'key', v_live.key, 'active', v_active);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'enemy_archetype_set_active', 'enemy_archetype', v_live.key, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'enemy_archetype_set_active', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'enemy_archetype_set_active', 'result', v_result);
end $$;

comment on function public.reward_profile_create(text, jsonb) is
  'ENEMY CONTENT REGISTRY (0257): owner-gated CREATE for reward_profiles behind the fail-closed '
  'enemy_content_registry_enabled flag (checked FIRST). Reproduces the 0243/0244 command spine; '
  'authenticated-only execute, guard in-body; NEVER anon.';
comment on function public.enemy_archetype_create(text, jsonb) is
  'ENEMY CONTENT REGISTRY (0257): owner-gated CREATE for enemy_archetypes behind the fail-closed '
  'enemy_content_registry_enabled flag (checked FIRST). Validates unit_type_id/default_reward_profile_id '
  'references. authenticated-only execute; NEVER anon.';

-- ── 5. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.reward_profile_create(text, jsonb) from public;
revoke all on function public.reward_profile_update(text, jsonb) from public;
revoke all on function public.reward_profile_set_active(text, jsonb) from public;
revoke all on function public.enemy_archetype_create(text, jsonb) from public;
revoke all on function public.enemy_archetype_update(text, jsonb) from public;
revoke all on function public.enemy_archetype_set_active(text, jsonb) from public;
grant execute on function public.reward_profile_create(text, jsonb) to authenticated;       -- guard in-body; NEVER anon
grant execute on function public.reward_profile_update(text, jsonb) to authenticated;       -- guard in-body; NEVER anon
grant execute on function public.reward_profile_set_active(text, jsonb) to authenticated;   -- guard in-body; NEVER anon
grant execute on function public.enemy_archetype_create(text, jsonb) to authenticated;      -- guard in-body; NEVER anon
grant execute on function public.enemy_archetype_update(text, jsonb) to authenticated;      -- guard in-body; NEVER anon
grant execute on function public.enemy_archetype_set_active(text, jsonb) to authenticated;  -- guard in-body; NEVER anon

-- ── 6. seeds (mirror today's scalars; INERT while the registry is dark) ────────────────────────────
insert into public.reward_profiles (key, display_name, resource_grants) values
  ('pirate_standard', 'Standard Pirate Bounty',
   '{"metal":{"base":10,"danger_coeff":0.25,"multiplier_ref":"reward_multiplier"}}'::jsonb)
on conflict (key) do nothing;

insert into public.enemy_archetypes
    (key, display_name, faction, unit_type_id, behavior_key, base_difficulty, default_reward_profile_id, difficulty_rating)
  select v.key, v.display_name, 'pirate', 'pirate_synthetic', 'spatial_synthetic',
         v.base_difficulty, rp.id, v.difficulty_rating
  from (values
         ('pirate_light', 'Light Pirate', 10.0::double precision, 1),
         ('pirate_heavy', 'Heavy Pirate', 25.0::double precision, 3)
       ) as v(key, display_name, base_difficulty, difficulty_rating)
  cross join (select id from public.reward_profiles where key = 'pirate_standard') as rp
on conflict (key) do nothing;

-- ── 7. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $regassert$
declare
  v_fn text;
begin
  -- (a) both tables exist with RLS enabled.
  if to_regclass('public.reward_profiles') is null then
    raise exception 'ENEMY-REGISTRY self-assert FAIL: reward_profiles table missing';
  end if;
  if to_regclass('public.enemy_archetypes') is null then
    raise exception 'ENEMY-REGISTRY self-assert FAIL: enemy_archetypes table missing';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.reward_profiles'::regclass) then
    raise exception 'ENEMY-REGISTRY self-assert FAIL: RLS not enabled on reward_profiles';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.enemy_archetypes'::regclass) then
    raise exception 'ENEMY-REGISTRY self-assert FAIL: RLS not enabled on enemy_archetypes';
  end if;

  -- (b) all six RPCs exist, are SECURITY DEFINER, authenticated may execute + anon may NOT.
  foreach v_fn in array array[
      'public.reward_profile_create(text,jsonb)', 'public.reward_profile_update(text,jsonb)',
      'public.reward_profile_set_active(text,jsonb)', 'public.enemy_archetype_create(text,jsonb)',
      'public.enemy_archetype_update(text,jsonb)', 'public.enemy_archetype_set_active(text,jsonb)']
  loop
    if to_regprocedure(v_fn) is null then
      raise exception 'ENEMY-REGISTRY self-assert FAIL: RPC % missing', v_fn;
    end if;
    if not exists (select 1 from pg_proc where oid = v_fn::regprocedure and prosecdef) then
      raise exception 'ENEMY-REGISTRY self-assert FAIL: RPC % is not SECURITY DEFINER', v_fn;
    end if;
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'ENEMY-REGISTRY self-assert FAIL: authenticated cannot execute % — the in-body guard would be unreachable', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'ENEMY-REGISTRY self-assert FAIL: anon CAN execute % — must be authenticated-only', v_fn;
    end if;
  end loop;

  -- (c) NO client-role write grant on either table — the only write path is the SECURITY DEFINER RPCs.
  if has_table_privilege('authenticated', 'public.reward_profiles', 'INSERT')
     or has_table_privilege('authenticated', 'public.reward_profiles', 'UPDATE')
     or has_table_privilege('authenticated', 'public.reward_profiles', 'DELETE')
     or has_table_privilege('anon', 'public.reward_profiles', 'INSERT')
     or has_table_privilege('anon', 'public.reward_profiles', 'UPDATE')
     or has_table_privilege('anon', 'public.reward_profiles', 'DELETE')
     or has_table_privilege('authenticated', 'public.enemy_archetypes', 'INSERT')
     or has_table_privilege('authenticated', 'public.enemy_archetypes', 'UPDATE')
     or has_table_privilege('authenticated', 'public.enemy_archetypes', 'DELETE')
     or has_table_privilege('anon', 'public.enemy_archetypes', 'INSERT')
     or has_table_privilege('anon', 'public.enemy_archetypes', 'UPDATE')
     or has_table_privilege('anon', 'public.enemy_archetypes', 'DELETE') then
    raise exception 'ENEMY-REGISTRY self-assert FAIL: a client role holds a write grant on a registry table — the only write path must be the SECURITY DEFINER RPCs';
  end if;

  -- (d) the fail-closed flag is present.
  if not exists (select 1 from public.game_config where key = 'enemy_content_registry_enabled') then
    raise exception 'ENEMY-REGISTRY self-assert FAIL: enemy_content_registry_enabled flag not seeded';
  end if;

  -- (e) the 0243 idempotency key is intact (world_editor_audit.request_id single-column UNIQUE).
  if not exists (
    select 1 from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
    where c.conrelid = 'public.world_editor_audit'::regclass
      and c.contype = 'u' and array_length(c.conkey, 1) = 1 and a.attname = 'request_id'
  ) then
    raise exception 'ENEMY-REGISTRY self-assert FAIL: world_editor_audit.request_id UNIQUE constraint missing (idempotency unenforced)';
  end if;

  raise notice 'ENEMY-REGISTRY self-assert ok: reward_profiles + enemy_archetypes (RLS on, no client write grant); all six RPCs SECURITY DEFINER + authenticated-only + anon-denied; enemy_content_registry_enabled flag seeded; world_editor_audit request_id UNIQUE intact';
end $regassert$;
