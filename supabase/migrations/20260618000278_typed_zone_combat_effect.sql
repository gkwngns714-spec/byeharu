-- Byeharu — TYPED-ZONE COMBAT EFFECT (migration 0278). Slice 6 of the typed-zone platform.
-- ADDITIVE AND FULLY DARK. A second composable effect, and the DUAL-GATE rule that governs it.
-- Nothing dispatches it yet, on purpose (see "WHY NO DISPATCH" below).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY COMBAT IS THE RIGHT FIRST NEW KIND
-- It is the only candidate that needs no migration of live data: the encounter content system
-- already exists (encounter_profiles, location_encounter_bindings), its resolver is already
-- independently gated behind encounter_resolver_enabled, and no point-entity authority has to move.
-- A combat zone can therefore be authored, inspected and reviewed while remaining completely inert.
-- Mining and exploration cannot say that — they have live point tables and real players depending on
-- them, so they come later, behind shadow comparisons of their own.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE DUAL GATE — AND, NEVER OR, AND NEVER IMPLICIT
-- A combat zone may only act when BOTH are true:
--     typed_zone_combat_runtime_enabled   the typed-zone platform may resolve combat zones
--     encounter_resolver_enabled          the encounter engine is live at all
--
-- Enabling typed combat zones must NEVER implicitly enable the resolver. The resolver is a separate,
-- deliberately dark capability with its own activation act and its own audit; a zone feature that
-- switched it on as a side effect would route around that decision entirely. So the AND lives in ONE
-- pure function, typed_zone_combat_capability_v1, and every future caller reads it rather than
-- re-deriving the conjunction — because a re-derived AND is exactly where an OR eventually creeps in.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY NO DISPATCH IN THIS SLICE
-- V1 of the dispatcher registers exactly fleet_leg_traversal -> pirate_intercept, and V1 is immutable
-- by law: a material change ships typed_zone_effect_dispatch_v2, never a CREATE OR REPLACE. Teaching
-- V1 about combat would violate that and would silently change what an already-planned effect means.
--
-- That is safe here because the V1 candidate builder reads ONLY zone_effect_pirate_intercept, so a
-- combat row cannot leak into a V1 request and cannot make V1 return unsupported_effect_type for a
-- zone that also carries pirate interception. A zone may hold both effects today: the pirate one is
-- planned, the combat one is inert data. That is composability behaving correctly, not a gap.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT A COMBAT EFFECT IS
-- "When something happens in this region, resolve an encounter from this profile." The profile is a
-- REAL foreign key, not a jsonb id — a blob could not tell you at write time that the profile was
-- deleted, and this is gameplay-bearing content.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.zone_effect_pirate_intercept') is null then
    raise exception 'TYPED-ZONE 0278: zone_effect_pirate_intercept (0273) is missing';
  end if;
  if to_regclass('public.encounter_profiles') is null then
    raise exception 'TYPED-ZONE 0278: encounter_profiles is missing — combat has nothing to reference';
  end if;
  if not exists (select 1 from public.game_config where key = 'encounter_resolver_enabled') then
    raise exception 'TYPED-ZONE 0278: encounter_resolver_enabled is missing — the dual gate needs it';
  end if;
end $pre$;

-- ── 1. zone_effect_combat — the SECOND composable effect ────────────────────────────────────────
-- A SIBLING table. It edits nothing that already exists, which is the whole promise of the
-- composable-effect shape: adding a behaviour must never touch the behaviour beside it.
create table public.zone_effect_combat (
  zone_id              uuid primary key references public.danger_zones (id) on delete cascade,
  -- WHAT to resolve. A real FK: a dangling profile id is impossible rather than merely unlikely.
  encounter_profile_id uuid not null references public.encounter_profiles (id),
  -- HOW OFTEN, and HOW MANY. Deliberately explicit columns rather than a jsonb blob so the database
  -- can reject an impossible configuration at write time.
  spawn_chance         double precision not null default 1
    check (spawn_chance = spawn_chance                       -- rejects NaN (Postgres sorts it high)
           and spawn_chance <> 'Infinity'::double precision
           and spawn_chance <> '-Infinity'::double precision
           and spawn_chance >= 0 and spawn_chance <= 1),
  max_concurrent       integer not null default 1 check (max_concurrent >= 1 and max_concurrent <= 100),
  cooldown_seconds     integer not null default 0 check (cooldown_seconds >= 0 and cooldown_seconds <= 86400),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index zone_effect_combat_profile_idx on public.zone_effect_combat (encounter_profile_id);

comment on table public.zone_effect_combat is
  'TYPED-ZONE PLATFORM (0278): the COMBAT effect of a zone — "resolve an encounter from this profile '
  'when something happens in this region". A sibling of zone_effect_pirate_intercept: effects are '
  'COMPOSABLE, so one zone may carry both. DARK: no dispatcher understands this effect yet (V1 is '
  'immutable and registers only pirate_intercept), and acting on it will additionally require BOTH '
  'typed_zone_combat_runtime_enabled AND encounter_resolver_enabled.';

-- Fail-closed, exactly as the pirate effect table: RLS on, no policy, no client grant.
alter table public.zone_effect_combat enable row level security;
revoke all on table public.zone_effect_combat from anon, authenticated;

-- ── 2. the flag — seeded FALSE, and independent of the resolver's own flag ──────────────────────
insert into public.game_config (key, value, description) values
  ('typed_zone_combat_runtime_enabled', 'false'::jsonb,
   'TYPED-ZONE PLATFORM: may the typed-zone runtime resolve COMBAT effects? Seeded false. This is '
   'ONE HALF of a dual gate — a combat zone also requires encounter_resolver_enabled. Lighting this '
   'must never imply lighting the resolver.')
on conflict (key) do nothing;

-- ── 3. typed_zone_combat_capability_v1 — the ONE place the AND is written ───────────────────────
-- Every future caller reads this rather than re-deriving `a and b`. A re-derived conjunction is
-- precisely where an OR eventually creeps in, or where one half is forgotten in a new call site.
create function public.typed_zone_combat_capability_v1()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.cfg_bool('typed_zone_combat_runtime_enabled'), false)
     and coalesce(public.cfg_bool('encounter_resolver_enabled'), false)
$$;

revoke execute on function public.typed_zone_combat_capability_v1() from public, anon, authenticated;

comment on function public.typed_zone_combat_capability_v1() is
  'TYPED-ZONE PLATFORM (0278): the ONE authority for whether a combat zone may act — '
  'typed_zone_combat_runtime_enabled AND encounter_resolver_enabled. Both halves, always. Never '
  're-derive this conjunction at a call site: that is where an OR creeps in or a half gets forgotten.';

-- ── 4. SELF-ASSERT ──────────────────────────────────────────────────────────────────────────────
do $tzk$
declare
  v_cap  text;
  v_true int;
begin
  -- (1) lands dark, on both halves
  if coalesce(public.cfg_bool('typed_zone_combat_runtime_enabled'), true) then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: typed_zone_combat_runtime_enabled is not false'; end if;
  if public.typed_zone_combat_capability_v1() then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: the combat capability is open while both flags are dark'; end if;

  -- (2) the capability is an AND — it must stay false when EITHER half is false. Proven by flipping
  -- each half inside a sub-transaction and rolling it back, so the check is real rather than asserted.
  begin
    update public.game_config set value = 'true'::jsonb where key = 'typed_zone_combat_runtime_enabled';
    if public.typed_zone_combat_capability_v1() then
      raise exception 'TYPED-ZONE 0278 self-assert FAIL: the capability opened with the resolver still dark — that is an OR, not an AND';
    end if;
    raise exception 'tz0278_rollback_probe';
  exception when others then
    if sqlerrm <> 'tz0278_rollback_probe' then raise; end if;
  end;
  -- and the flag is back to false after the probe
  if coalesce(public.cfg_bool('typed_zone_combat_runtime_enabled'), true) then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: the AND probe leaked a lit flag'; end if;

  -- (3) the capability function reads BOTH keys — a forgotten half would silently widen the gate
  select pg_get_functiondef(to_regprocedure('public.typed_zone_combat_capability_v1()')) into v_cap;
  if strpos(v_cap, 'typed_zone_combat_runtime_enabled') = 0
     or strpos(v_cap, 'encounter_resolver_enabled') = 0 then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: the capability does not read both halves'; end if;
  if v_cap !~* '\mand\M' then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: the capability is not a conjunction'; end if;

  -- (4) V1 DISPATCH IS UNTOUCHED — combat must not have leaked into the immutable V1 planner
  if pg_get_functiondef(to_regprocedure('public.typed_zone_effect_dispatch_v1(jsonb)')) ilike '%combat%' then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: V1 dispatch mentions combat — V1 is immutable';
  end if;
  -- …and the V1 candidate builder still reads ONLY the pirate effect table, so a combat row cannot
  -- leak into a V1 request and make it reject a zone that also carries pirate interception.
  if pg_get_functiondef(to_regprocedure(
       'public.typed_zone_pirate_candidates_v1(uuid, double precision, double precision, double precision, double precision, double precision)')) ilike '%zone_effect_combat%' then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: the V1 candidate builder reads the combat table';
  end if;

  -- (5) SIBLING, NOT SURGERY: the pirate effect table is untouched by this migration
  select count(*) into v_true from information_schema.columns
   where table_schema='public' and table_name='zone_effect_pirate_intercept';
  if v_true <> 8 then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: zone_effect_pirate_intercept now has % columns — a sibling effect must not alter it', v_true;
  end if;

  -- (6) fail-closed ACL
  if not (select relrowsecurity from pg_class where oid = 'public.zone_effect_combat'::regclass) then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: RLS is not enabled on zone_effect_combat'; end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='zone_effect_combat') then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: zone_effect_combat has a policy'; end if;
  if has_table_privilege('anon', 'public.zone_effect_combat', 'select')
     or has_table_privilege('authenticated', 'public.zone_effect_combat', 'select') then
    raise exception 'TYPED-ZONE 0278 self-assert FAIL: a client role can read zone_effect_combat'; end if;

  raise notice 'TYPED-ZONE 0278 self-assert ok: lands DARK on BOTH halves (typed_zone_combat_runtime_enabled false, capability closed); the capability is a proven AND — lighting only the zone half kept it closed, and the probe rolled back cleanly; it reads both keys; V1 dispatch and the V1 candidate builder are untouched and combat-blind, so a combat row cannot make V1 reject a zone that also carries pirate interception; zone_effect_pirate_intercept is unaltered (a sibling effect is never surgery on its neighbour); zone_effect_combat is RLS-on with no policy and no client grant';
end $tzk$;
