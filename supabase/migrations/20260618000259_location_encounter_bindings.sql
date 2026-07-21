-- Byeharu — E2: LOCATION → ENCOUNTER BINDINGS — a NET-NEW, DARK, fail-closed, ADDITIVE surface.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS IS: ONE net-new owner-authored join table — public.location_encounter_bindings — that
-- BINDS a live world location (public.locations, 0002) to a reusable E1 encounter profile
-- (public.encounter_profiles, 0258) with a per-binding weight, plus THREE owner-gated write commands
-- that author it, all behind a fail-closed feature flag. It is the THIRD slice of the enemy-content
-- program: E0 (0257) built the enemy catalog, E1 (0258) COMPOSED it into fleets + encounters, and E2
-- BINDS those encounters to the places they can occur — it does NOT spawn, resolve, or instantiate
-- anything. It reproduces the established World Editor command spine (0243/0244/0247/0250/0257/0258)
-- step for step and reuses THE ONE owner guard (public.is_owner()), THE ONE audit/idempotency ledger
-- (public.world_editor_audit incl. its 0244 before/after/source_revision columns) and THE ONE boolean
-- config accessor (public.cfg_bool) — no second authority anywhere. It STACKS on E1: encounter_profile_id
-- FKs encounter_profiles (default RESTRICT — an encounter in use may not be hard-removed); it STACKS on
-- the map: location_id FKs locations ON DELETE CASCADE (deleting a location drops its bindings).
--
-- WHY A JOIN TABLE (not a jsonb column on either side): a binding is a REFERENCE to a location + a
-- REFERENCE to an encounter profile + a per-ref numeric (weight) + an active flag. The DB, not
-- application code, is the authority on referential integrity (two FKs) and uniqueness (one binding per
-- (location, encounter_profile) pair). location_id/encounter_profile_id are the ADDRESS of the binding
-- (the UNIQUE key); only weight/notes/active mutate — the address is stable across a binding's life.
--
-- WHAT THIS IS NOT — the DARK guarantee: NO runtime combat path reads this table.
-- process_combat_ticks / combat_create_group_encounter / pirate_intercept_evaluate_leg / reward_grant
-- are BYTE-IDENTICAL after this migration; the existing pirate combat still scales off
-- locations.base_difficulty, the game_config reward_* tunables and enemy_synthetic_max_units. This
-- table carries NO runtime-instance state (hp/position/target/status/encounter_id) — that stays on
-- combat_units / combat_encounters. Every one of the three RPCs applies a TRI-FLAG gate FIRST
-- (reject-before-any-read): enemy_content_registry_enabled (E0) AND encounter_authoring_enabled (E1)
-- AND encounter_binding_authoring_enabled (E2) must ALL be true — since E2 references E1's tables which
-- reference E0's, binding authoring must not run while any upstream slice is still dark. All three flags
-- are seeded 'false' — so even deployed, the whole surface is inert until an owner flips ALL THREE, and
-- even then only an owner (is_owner()) can write. A belt-and-braces DEACTIVATION trigger (§2c)
-- additionally blocks soft-disabling an encounter_profile still referenced by an ACTIVE binding, even
-- under a future privileged/direct write.
--
-- WHY NO TRIGGER ON locations: locations is Map-owned (0002). A raising BEFORE-UPDATE trigger there
-- could break get_world_map / the 0249 location_update publish path on an unrelated status edit. So
-- orphan-on-location-status (a binding whose location was locked/hidden) is NOT guarded here — it is
-- delegated to E3's runtime resolver, which will filter bindings to status='active' locations.
-- location_id ON DELETE CASCADE cleans up hard location deletion.
--
-- DEPLOY POSTURE: UNDEPLOYED — deploy is a human gate. Fail-closed on TWO independent axes: the flag is
-- false (every RPC returns 'not_enabled' before touching a row) AND is_owner() is false for everyone
-- until an owner is seeded. No client grant is widened: the table writes happen INSIDE these SECURITY
-- DEFINER functions only; client-role write grants are explicitly REVOKED (a pure narrowing — RLS
-- already denied them). Public SELECT is granted (read is harmless catalog).
--
-- NO-SPAGHETTI: ONE owner check (is_owner()), ONE audit ledger, ONE idempotency key, ONE flag accessor
-- (cfg_bool); NO delete RPC (bindings are soft-toggled via set_active); no runtime combat path
-- re-pointed. Out of scope (later slices): the runtime resolver that reads bindings to instantiate an
-- encounter (E3), any World Editor UI (E4), activation.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if the surfaces this slice builds on are missing ────────────
do $lebdep$
begin
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: public.world_editor_audit (0243) is missing — the audit/idempotency spine must exist first';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: public.is_owner() (0243) is missing — THE ONE owner guard must exist first';
  end if;
  if to_regprocedure('public.cfg_bool(text)') is null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: public.cfg_bool(text) (0046) is missing — THE ONE boolean flag accessor must exist first';
  end if;
  if to_regclass('public.game_config') is null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: public.game_config (0003) is missing — the fail-closed flag lives here';
  end if;
  -- STACKS ON E1: encounter_profile_id FKs encounter_profiles.
  if to_regclass('public.encounter_profiles') is null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: public.encounter_profiles (0258/E1) is missing — bindings reference it; E2 must build on E1';
  end if;
  -- STACKS ON E0: E2 is gated behind E0's catalog + flag (tri-flag chain E2->E1->E0).
  if to_regclass('public.enemy_archetypes') is null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: public.enemy_archetypes (0257/E0) is missing — E2 gates on the whole E2->E1->E0 chain';
  end if;
  if to_regclass('public.reward_profiles') is null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: public.reward_profiles (0257/E0) is missing — E2 gates on the whole E2->E1->E0 chain';
  end if;
  -- STACKS ON the map: location_id FKs locations.
  if to_regclass('public.locations') is null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: public.locations (0002) is missing — bindings reference it';
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
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: a 0244 audit snapshot column (before_snapshot/after_snapshot/source_revision) is missing — the snapshot columns must exist first';
  end if;
end $lebdep$;

-- ── 1. location_encounter_bindings — one location ↔ one encounter profile + weight (owner-authored) ─
-- location_id / encounter_profile_id are the ADDRESS (the UNIQUE key). encounter_profile_id is FK
-- RESTRICT (default): an encounter profile referenced by ANY binding may not be hard-removed. location_id
-- is FK ON DELETE CASCADE: deleting a location drops its bindings (bindings have no meaning without a place).
create table if not exists public.location_encounter_bindings (
  id                   uuid primary key default gen_random_uuid(),
  location_id          uuid not null references public.locations(id) on delete cascade,
  encounter_profile_id uuid not null references public.encounter_profiles(id),
  weight               double precision not null default 1 check (weight > 0 and weight <= 1000),
  active               boolean not null default true,
  revision             integer not null default 1 check (revision >= 1),
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint location_encounter_binding_unique unique (location_id, encounter_profile_id)
);

create index if not exists location_encounter_bindings_location_idx on public.location_encounter_bindings (location_id);
create index if not exists location_encounter_bindings_profile_idx  on public.location_encounter_bindings (encounter_profile_id);

comment on table public.location_encounter_bindings is
  'LOCATION → ENCOUNTER BINDINGS (0259): owner-authored, DARK join table binding a live world location '
  '(locations, 0002) to a reusable encounter profile (encounter_profiles, 0258/E1) with a per-binding '
  'weight. (location_id, encounter_profile_id) is the UNIQUE ADDRESS; only weight/notes/active mutate. '
  'Carries NO runtime-instance state. Read by NOTHING at runtime — existing pirate combat is '
  'byte-identical; orphan-on-location-status is delegated to the E3 resolver (it filters to active '
  'locations), which is WHY no trigger is placed on the Map-owned locations table. PRECONFIGURE SEMANTICS: '
  'create requires the location to EXIST but NOT to be active (liveness is deferred to E3), so a binding '
  'may be authored ahead of publish and survives temporary unpublishing. Public SELECT; writes ONLY '
  'through the owner-gated 0259 RPCs behind the fail-closed encounter_binding_authoring_enabled flag.';

alter table public.location_encounter_bindings enable row level security;
create policy "location_encounter_bindings_public_read" on public.location_encounter_bindings for select using (true);
grant select on table public.location_encounter_bindings to anon, authenticated;
revoke insert, update, delete on table public.location_encounter_bindings from anon, authenticated;

-- ── 2c. DEACTIVATION REFERENTIAL-INTEGRITY TRIGGER — defense-in-depth even against direct/privileged
-- writes (client writes are already revoked). A soft-disable (active true→false) of an encounter_profile
-- STILL referenced by an ACTIVE binding would silently strand the binding, so a BEFORE UPDATE trigger
-- RAISEs on exactly the true→false transition when an active binding remains. It fires regardless of
-- caller (RPC, superuser, or a future privileged path). SECURITY DEFINER + set search_path='' like every
-- other function here. This trigger lives on encounter_profiles (E1's table) — an intended cross-slice
-- protection added HERE in 0259 (it did not exist in E1). NOTE: NO trigger is placed on locations (§header).
create or replace function public._guard_encounter_profile_deactivation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.location_encounter_bindings b
    where b.encounter_profile_id = old.id and b.active is true
  ) then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS: cannot deactivate encounter profile "%" — it is still referenced by an ACTIVE location encounter binding (deactivate or remove the binding first).', old.key;
  end if;
  return new;
end $$;

revoke all on function public._guard_encounter_profile_deactivation() from public;

drop trigger if exists guard_encounter_profile_deactivation on public.encounter_profiles;
create trigger guard_encounter_profile_deactivation
  before update on public.encounter_profiles
  for each row when (old.active is true and new.active is false)
  execute function public._guard_encounter_profile_deactivation();

-- ── 3. fail-closed feature flag (seeded false; do NOT overwrite if already set) ────────────────────
insert into public.game_config (key, value, description) values
  ('encounter_binding_authoring_enabled', 'false',
   'E2 dark gate for location_encounter_bindings owner-write RPCs; every RPC checks cfg_bool(this) AND '
   'cfg_bool(encounter_authoring_enabled) AND cfg_bool(enemy_content_registry_enabled) FIRST (TRI-FLAG '
   'reject-before-any-read, E2->E1->E0 chain); no runtime combat path reads this table')
on conflict (key) do nothing;

-- ── 4. the THREE owner-gated write commands ───────────────────────────────────────────────────────
-- Each (p_request_id text, p_payload jsonb) returns a typed {ok,request_id,result|error} envelope and
-- performs, IN ORDER: (1) TRI-FLAG GATE FIRST (reject-before-any-read: not_enabled); (2) authn
-- (not_authenticated); (3) authz via is_owner() (not_authorized); (4) blank request_id (invalid_request);
-- (5) idempotent replay on request_id (duplicate_request); (6) server re-validation into details[]
-- (validation_failed); (7 — update/set_active) locate + row-lock by id + optimistic revision on
-- expected_revision (not_found/source_missing; stale_revision/source_changed); (8) apply + exactly one
-- audit row in ONE sub-block (unique_violation disambiguated via GET STACKED DIAGNOSTICS:
-- world_editor_audit ⇒ idempotent replay, the binding table ⇒ typed conflict/duplicate_binding); (9)
-- typed success.

-- ── 4a. location_encounter_binding_create ───────────────────────────────────────────────────────────
create or replace function public.location_encounter_binding_create(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_details   jsonb := '[]'::jsonb;
  v_loc_txt   text;
  v_loc       uuid;
  v_ep_txt    text;
  v_ep        uuid;
  v_ep_active boolean;
  v_weight    double precision := 1;
  v_after     jsonb;
  v_result    jsonb;
  v_prior     text;
  v_id        uuid;
  v_rev       integer;
  v_tbl       text;
begin
  -- (1) TRI-FLAG GATE FIRST — reject before ANY read. E2 references E1's tables which reference E0's, so
  -- binding authoring must NOT run while any upstream slice is dark: ALL THREE flags must be true.
  if not (public.cfg_bool('enemy_content_registry_enabled')
          and public.cfg_bool('encounter_authoring_enabled')
          and public.cfg_bool('encounter_binding_authoring_enabled')) then
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
             'command_type', 'location_encounter_binding_create', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- (6) SERVER-SIDE re-validation into details[].
  -- location_id: parseable uuid, must EXIST (a real locations row). PRECONFIGURE SEMANTICS: creation does
  -- NOT require the location to be active/published — the owner must be able to preconfigure a binding on
  -- an unpublished/not-yet-active location, and a binding must survive temporary unpublishing. The
  -- three-way RUNTIME eligibility (location.status='active' AND binding.active AND encounter_profile.active)
  -- is E3's resolver filter, NOT a create-time block (§header). Only EXISTENCE is enforced here.
  v_loc_txt := btrim(coalesce(p_payload->>'location_id', ''));
  if v_loc_txt = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_location', 'field', 'location_id', 'message', 'location_id is required.'));
  else
    begin v_loc := v_loc_txt::uuid; exception when invalid_text_representation then v_loc := null; end;
    if v_loc is null then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_location', 'field', 'location_id', 'message', 'location_id is not a valid location reference.'));
    elsif not exists (select 1 from public.locations where id = v_loc) then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_location', 'field', 'location_id', 'message', 'No locations row for the referenced id.'));
    end if;
  end if;
  -- encounter_profile_id: parseable uuid, must EXIST and be active=true.
  v_ep_txt := btrim(coalesce(p_payload->>'encounter_profile_id', ''));
  if v_ep_txt = '' then
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_encounter_ref', 'field', 'encounter_profile_id', 'message', 'encounter_profile_id is required.'));
  else
    begin v_ep := v_ep_txt::uuid; exception when invalid_text_representation then v_ep := null; end;
    if v_ep is null then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_encounter_ref', 'field', 'encounter_profile_id', 'message', 'encounter_profile_id is not a valid encounter profile reference.'));
    else
      select active into v_ep_active from public.encounter_profiles where id = v_ep;
      if not found then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'invalid_encounter_ref', 'field', 'encounter_profile_id', 'message', 'No encounter_profiles row for the referenced id.'));
      elsif v_ep_active is not true then
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'code', 'encounter_inactive', 'field', 'encounter_profile_id', 'message', 'The referenced encounter profile is inactive — activate it before binding it.'));
      end if;
    end if;
  end if;
  -- weight: OPTIONAL finite number in (0,1000]. jsonb numbers cannot be NaN/Infinity ⇒ typeof number = finite.
  if p_payload ? 'weight' then
    if jsonb_typeof(p_payload->'weight') is distinct from 'number'
       or (p_payload->'weight')::numeric <= 0 or (p_payload->'weight')::numeric > 1000 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_weight', 'field', 'weight', 'message', 'weight, if present, must be a finite number in (0,1000].'));
    else
      v_weight := (p_payload->'weight')::double precision;
    end if;
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  -- (8) apply the binding + one audit row in ONE sub-block (unique_violation disambiguated by table).
  begin
    insert into public.location_encounter_bindings (location_id, encounter_profile_id, weight, notes)
      values (v_loc, v_ep, v_weight, nullif(btrim(coalesce(p_payload->>'notes', '')), ''))
      returning id, revision into v_id, v_rev;

    select jsonb_build_object(
             'id', id, 'location_id', location_id, 'encounter_profile_id', encounter_profile_id,
             'weight', weight, 'active', active, 'revision', revision, 'notes', notes,
             'created_at', created_at, 'updated_at', updated_at)
      into v_after from public.location_encounter_bindings where id = v_id;

    v_result := jsonb_build_object('created', true, 'id', v_id, 'location_id', v_loc, 'encounter_profile_id', v_ep);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'location_encounter_binding_create', 'location_encounter_binding', v_id::text, v_result::text,
         null, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'location_encounter_binding_create', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    if v_tbl = 'location_encounter_bindings' then
      return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'conflict',
               'details', jsonb_build_array(jsonb_build_object(
                 'code', 'duplicate_binding', 'field', 'encounter_profile_id',
                 'message', 'This encounter profile is already bound to this location.')));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'location_encounter_binding_create', 'result', v_result);
end $$;

-- ── 4b. location_encounter_binding_update — mutate weight/notes; the (location, encounter) address is
-- STABLE (never re-pointed), so the UNIQUE key is preserved and no binding-level conflict can arise. ──
create or replace function public.location_encounter_binding_update(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_details  jsonb := '[]'::jsonb;
  v_target   text;
  v_tid      uuid;
  v_weight   double precision := 1;
  v_live     record;
  v_before   jsonb;
  v_after    jsonb;
  v_result   jsonb;
  v_prior    text;
  v_id       uuid;
  v_rev      integer;
  v_tbl      text;
begin
  -- (1) TRI-FLAG GATE FIRST — reject before ANY read.
  if not (public.cfg_bool('enemy_content_registry_enabled')
          and public.cfg_bool('encounter_authoring_enabled')
          and public.cfg_bool('encounter_binding_authoring_enabled')) then
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
             'command_type', 'location_encounter_binding_update', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  -- target_id (the binding UUID) + a numeric expected_revision are REQUIRED.
  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;

  -- (6) re-validate the mutable weight (location/encounter are the immutable address — not re-pointed).
  if p_payload ? 'weight' then
    if jsonb_typeof(p_payload->'weight') is distinct from 'number'
       or (p_payload->'weight')::numeric <= 0 or (p_payload->'weight')::numeric > 1000 then
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'code', 'invalid_weight', 'field', 'weight', 'message', 'weight, if present, must be a finite number in (0,1000].'));
    else
      v_weight := (p_payload->'weight')::double precision;
    end if;
  end if;
  if jsonb_array_length(v_details) > 0 then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'validation_failed', 'details', v_details);
  end if;

  -- (7a) LOCATE + ROW-LOCK the live target by its binding UUID. A malformed uuid ⇒ not_found.
  begin v_tid := v_target::uuid; exception when invalid_text_representation then v_tid := null; end;
  if v_tid is not null then
    select id, location_id, encounter_profile_id, weight, active, revision, notes, created_at, updated_at
      into v_live from public.location_encounter_bindings where id = v_tid for update;
  end if;
  if v_tid is null or not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No location encounter binding with this id exists.')));
  end if;
  -- (7b) optimistic revision: compare expected_revision to the LOCKED row; mismatch ⇒ stale, write nothing.
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live binding revision changed since this draft was forked.')));
  end if;

  v_before := jsonb_build_object(
                'id', v_live.id, 'location_id', v_live.location_id, 'encounter_profile_id', v_live.encounter_profile_id,
                'weight', v_live.weight, 'active', v_live.active, 'revision', v_live.revision, 'notes', v_live.notes,
                'created_at', v_live.created_at, 'updated_at', v_live.updated_at);

  -- (8) apply: mutate weight/notes, bump revision + updated_at, + one audit row.
  begin
    update public.location_encounter_bindings
       set weight = v_weight,
           notes = nullif(btrim(coalesce(p_payload->>'notes', '')), ''),
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning id, revision into v_id, v_rev;

    select jsonb_build_object(
             'id', id, 'location_id', location_id, 'encounter_profile_id', encounter_profile_id,
             'weight', weight, 'active', active, 'revision', revision, 'notes', notes,
             'created_at', created_at, 'updated_at', updated_at)
      into v_after from public.location_encounter_bindings where id = v_id;

    v_result := jsonb_build_object('updated', true, 'id', v_id);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'location_encounter_binding_update', 'location_encounter_binding', v_live.id::text, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'location_encounter_binding_update', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;   -- the address is immutable, so a binding-level unique conflict is impossible here.
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'location_encounter_binding_update', 'result', v_result);
end $$;

-- ── 4c. location_encounter_binding_set_active — soft toggle (row survives; NO hard delete) ───────────
create or replace function public.location_encounter_binding_set_active(p_request_id text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_target   text;
  v_tid      uuid;
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
  -- (1) TRI-FLAG GATE FIRST — reject before ANY read.
  if not (public.cfg_bool('enemy_content_registry_enabled')
          and public.cfg_bool('encounter_authoring_enabled')
          and public.cfg_bool('encounter_binding_authoring_enabled')) then
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
             'command_type', 'location_encounter_binding_set_active', 'replayed', true,
             'code', 'duplicate_request', 'result', v_prior::jsonb);
  end if;

  v_target := btrim(coalesce(p_payload->>'target_id', ''));
  if v_target = '' or jsonb_typeof(p_payload->'expected_revision') is distinct from 'number'
     or jsonb_typeof(p_payload->'active') is distinct from 'boolean' then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'invalid_request');
  end if;
  v_active := (p_payload->>'active')::boolean;

  begin v_tid := v_target::uuid; exception when invalid_text_representation then v_tid := null; end;
  if v_tid is not null then
    select id, location_id, encounter_profile_id, weight, active, revision, notes, created_at, updated_at
      into v_live from public.location_encounter_bindings where id = v_tid for update;
  end if;
  if v_tid is null or not found then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'not_found',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_missing', 'field', 'target_id',
               'message', 'No location encounter binding with this id exists.')));
  end if;
  if (p_payload->>'expected_revision')::int is distinct from v_live.revision then
    return jsonb_build_object('ok', false, 'request_id', p_request_id, 'error', 'stale_revision',
             'details', jsonb_build_array(jsonb_build_object(
               'code', 'source_changed', 'field', 'revision',
               'message', 'The live binding revision changed since this draft was forked.')));
  end if;

  v_before := jsonb_build_object(
                'id', v_live.id, 'location_id', v_live.location_id, 'encounter_profile_id', v_live.encounter_profile_id,
                'weight', v_live.weight, 'active', v_live.active, 'revision', v_live.revision, 'notes', v_live.notes,
                'created_at', v_live.created_at, 'updated_at', v_live.updated_at);
  begin
    update public.location_encounter_bindings
       set active = v_active,
           revision = v_live.revision + 1,
           updated_at = now()
     where id = v_live.id
     returning id, revision into v_id, v_rev;

    select jsonb_build_object(
             'id', id, 'location_id', location_id, 'encounter_profile_id', encounter_profile_id,
             'weight', weight, 'active', active, 'revision', revision, 'notes', notes,
             'created_at', created_at, 'updated_at', updated_at)
      into v_after from public.location_encounter_bindings where id = v_id;

    v_result := jsonb_build_object('active_set', true, 'id', v_id, 'active', v_active);

    insert into public.world_editor_audit
        (actor, request_id, command_type, target_type, target_id, result,
         before_snapshot, after_snapshot, source_revision)
      values
        (v_uid, p_request_id, 'location_encounter_binding_set_active', 'location_encounter_binding', v_live.id::text, v_result::text,
         v_before, v_after, coalesce(p_payload->>'source_revision', v_rev::text));
  exception when unique_violation then
    get stacked diagnostics v_tbl = TABLE_NAME;
    if v_tbl = 'world_editor_audit' then
      select result into v_prior from public.world_editor_audit where request_id = p_request_id;
      return jsonb_build_object('ok', true, 'request_id', p_request_id,
               'command_type', 'location_encounter_binding_set_active', 'replayed', true,
               'code', 'duplicate_request', 'result', coalesce(v_prior::jsonb, v_result));
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'request_id', p_request_id, 'command_type', 'location_encounter_binding_set_active', 'result', v_result);
end $$;

comment on function public.location_encounter_binding_create(text, jsonb) is
  'LOCATION → ENCOUNTER BINDINGS (0259): owner-gated CREATE for location_encounter_bindings behind the '
  'fail-closed encounter_binding_authoring_enabled flag (checked FIRST, tri-flag with E1+E0). PRECONFIGURE '
  'SEMANTICS: the location must EXIST but need NOT be active (an owner may preconfigure a binding on an '
  'unpublished location; runtime liveness is E3''s resolver filter). The encounter profile must exist + be '
  'active (the E1-content side stays strict). authenticated-only execute; NEVER anon.';

-- ── 5. ACL — authenticated may CALL (guard is in-body); anon/public may not. No table grant widened.
revoke all on function public.location_encounter_binding_create(text, jsonb) from public;
revoke all on function public.location_encounter_binding_update(text, jsonb) from public;
revoke all on function public.location_encounter_binding_set_active(text, jsonb) from public;
grant execute on function public.location_encounter_binding_create(text, jsonb) to authenticated;       -- guard in-body; NEVER anon
grant execute on function public.location_encounter_binding_update(text, jsonb) to authenticated;       -- guard in-body; NEVER anon
grant execute on function public.location_encounter_binding_set_active(text, jsonb) to authenticated;   -- guard in-body; NEVER anon

-- ── 6. seed (INERT while the surface is dark): bind E1's seeded 'pirate_basic' encounter profile to the
-- seeded pirate-hunt location. NOTE: the 0002 waypoint 'Pirate Ambush Point' was renamed to 'Snare' by
-- migration 0148 (single-word location names); we match either name (robust to whether 0148 applied) and
-- require location_type='pirate_hunt' + status='active'. cross join + on conflict do nothing ⇒ idempotent.
insert into public.location_encounter_bindings (location_id, encounter_profile_id, weight)
  select l.id, ep.id, 1
  from (select id from public.locations
         where location_type = 'pirate_hunt' and status = 'active'
           and name in ('Snare', 'Pirate Ambush Point')
         order by name limit 1) as l
  cross join (select id from public.encounter_profiles where key = 'pirate_basic') as ep
on conflict (location_id, encounter_profile_id) do nothing;

-- ── 7. self-assert (deploy-time; any raise aborts the txn — nothing half-applies) ─────────────────
do $lebassert$
declare
  v_fn  text;
begin
  -- (a) the table exists with RLS enabled.
  if to_regclass('public.location_encounter_bindings') is null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: table location_encounter_bindings missing';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.location_encounter_bindings'::regclass) then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: RLS not enabled on location_encounter_bindings';
  end if;

  -- (b) all three RPCs exist, are SECURITY DEFINER, authenticated may execute + anon may NOT.
  foreach v_fn in array array[
      'public.location_encounter_binding_create(text,jsonb)',
      'public.location_encounter_binding_update(text,jsonb)',
      'public.location_encounter_binding_set_active(text,jsonb)']
  loop
    if to_regprocedure(v_fn) is null then
      raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: RPC % missing', v_fn;
    end if;
    if not exists (select 1 from pg_proc where oid = v_fn::regprocedure and prosecdef) then
      raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: RPC % is not SECURITY DEFINER', v_fn;
    end if;
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: authenticated cannot execute % — the in-body guard would be unreachable', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: anon CAN execute % — must be authenticated-only', v_fn;
    end if;
  end loop;

  -- (c) NO client-role write grant on the binding table — the only write path is the RPCs.
  if has_table_privilege('authenticated', 'public.location_encounter_bindings', 'INSERT')
     or has_table_privilege('authenticated', 'public.location_encounter_bindings', 'UPDATE')
     or has_table_privilege('authenticated', 'public.location_encounter_bindings', 'DELETE')
     or has_table_privilege('anon', 'public.location_encounter_bindings', 'INSERT')
     or has_table_privilege('anon', 'public.location_encounter_bindings', 'UPDATE')
     or has_table_privilege('anon', 'public.location_encounter_bindings', 'DELETE') then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: a client role holds a write grant on location_encounter_bindings — the only write path must be the SECURITY DEFINER RPCs';
  end if;

  -- (d) the fail-closed flag is present.
  if not exists (select 1 from public.game_config where key = 'encounter_binding_authoring_enabled') then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: encounter_binding_authoring_enabled flag not seeded';
  end if;

  -- (e) the 0243 idempotency key is intact (world_editor_audit.request_id single-column UNIQUE).
  if not exists (
    select 1 from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
    where c.conrelid = 'public.world_editor_audit'::regclass
      and c.contype = 'u' and array_length(c.conkey, 1) = 1 and a.attname = 'request_id'
  ) then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: world_editor_audit.request_id UNIQUE constraint missing (idempotency unenforced)';
  end if;

  -- (f) NO *_delete RPC exists for this surface — bindings are soft-toggled via set_active.
  if to_regprocedure('public.location_encounter_binding_delete(text,jsonb)') is not null then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: a *_delete RPC exists — this surface must have NO delete command';
  end if;

  -- (g) the deactivation referential-integrity trigger exists on encounter_profiles.
  if not exists (select 1 from pg_trigger where tgname = 'guard_encounter_profile_deactivation'
                   and tgrelid = 'public.encounter_profiles'::regclass and not tgisinternal) then
    raise exception 'LOCATION-ENCOUNTER-BINDINGS self-assert FAIL: guard_encounter_profile_deactivation trigger missing on encounter_profiles';
  end if;

  raise notice 'LOCATION-ENCOUNTER-BINDINGS self-assert ok: table (RLS on, no client write grant); all three RPCs SECURITY DEFINER + authenticated-only + anon-denied (TRI-FLAG gated on enemy_content_registry_enabled AND encounter_authoring_enabled AND encounter_binding_authoring_enabled); encounter_binding_authoring_enabled flag seeded; deactivation-guard trigger present on encounter_profiles; world_editor_audit request_id UNIQUE intact; NO delete RPC';
end $lebassert$;
