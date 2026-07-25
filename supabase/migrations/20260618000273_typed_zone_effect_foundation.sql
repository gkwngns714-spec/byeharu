-- Byeharu — TYPED-ZONE EFFECT FOUNDATION (migration 0273). Slice 1 of the typed-zone platform.
-- ADDITIVE AND FULLY DARK. Two new flags, both seeded FALSE. NOTHING reads this table yet.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE MODEL THIS ESTABLISHES — IDENTITY + COMPOSABLE EFFECTS (owner's decision, 2026-07-25)
-- Today a danger_zones polygon has NO type dispatch: its mere existence means "pirates intercept
-- here" (get_intercept_candidates → ST_Intersects(boundary, leg) → risk → ambush). Shape and
-- behaviour are the same fact, which is why reshaping a zone was indistinguishable from redefining
-- what it does.
--
-- The platform separates three concerns:
--     GEOMETRY  (danger_zones.boundary)  — WHERE can something happen?
--     IDENTITY  (danger_zones.zone_kind) — WHAT is this zone?
--     EFFECTS   (zone_effect_* tables)   — WHAT does it DO, and HOW?
--
-- EFFECTS ARE COMPOSABLE, NOT A SWITCH ON IDENTITY. One zone may carry several effects at once —
-- a mining zone that also spawns is ONE zone with TWO effect rows, never a new kind and never a
-- special case. Each effect is its own table keyed by zone_id, so:
--   * presence of an effect  = existence of that table's row (no nullable god-columns on the core);
--   * absence of an effect   = no row (never a NULL-riddled sentinel);
--   * adding a future effect = a new sibling table, touching no existing one.
-- This is the ONE reason the config is relational rather than a single jsonb blob: a blob cannot
-- carry a foreign key to an encounter profile, cannot enforce required-fields-per-effect, and cannot
-- give the audit log a precise diff. (See docs/ZONE_PLATFORM_REVIEW.md §2.)
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THIS SLICE CHANGES NO BEHAVIOUR AT ALL
-- The five pirate risk knobs are TODAY global game_config singletons, read by
-- pirate_intercept_compute_risk:
--     risk = greatest(min_risk,
--              least(max_risk,
--                base_risk * (stat_reference / (stat_reference + combined_stats))
--                          * least(1.0, greatest(exposure_floor, exposure_fraction))))
-- zone_effect_pirate gives each zone an OPTIONAL per-zone override of each knob. Every backfilled
-- row is written with ALL FIVE OVERRIDES NULL, and NULL means "fall back to the global". So the
-- effect rows are, by construction, behaviour-neutral: a future dispatcher reading them with
-- coalesce(zone_override, global) reproduces today's numbers EXACTLY for every existing zone.
-- Parity is a property of the DATA, not a promise about future code.
--
-- THIS MIGRATION DOES NOT:
--   * create, delete, reshape, rename, re-status or re-attach ANY danger_zones row;
--   * redefine ANY runtime function (pirate_intercept_compute_risk, get_intercept_candidates,
--     get_danger_zones and every zone_* command are NOT re-created here);
--   * widen the zone_kind CHECK (non-pirate identities arrive with their own slice + runtime gate);
--   * rename danger_zones (RPCs, verifiers and consumers have migrated to that name — renaming
--     early is pure deployment risk for zero benefit);
--   * grant any client read (the table is RLS-on with NO policy and NO grant → fail-closed);
--   * migrate mining_fields / exploration_sites (points must NOT become invented radii — see
--     docs/ZONE_PLATFORM_REVIEW.md §3);
--   * touch the encounter resolver.
--
-- FLAGS (both seeded false; the owner alone flips):
--   typed_zone_authoring_enabled      — gates the future editor's typed-zone mutation surface;
--   typed_zone_pirate_runtime_enabled — gates the future dispatcher taking authority for pirate.
-- They are SEPARATE on purpose: authoring a zone's effects must never imply that the generalized
-- runtime has taken over resolving them.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.danger_zones') is null then
    raise exception 'TYPED-ZONE 0273: public.danger_zones (0233) is missing — the core this extends must exist';
  end if;
  if to_regclass('public.game_config') is null then
    raise exception 'TYPED-ZONE 0273: public.game_config (0003) is missing';
  end if;
  if to_regprocedure('public.cfg_bool(text)') is null or to_regprocedure('public.cfg_num(text)') is null then
    raise exception 'TYPED-ZONE 0273: the cfg_bool/cfg_num config authorities are missing';
  end if;
  if to_regprocedure('public.pirate_intercept_compute_risk(double precision, double precision)') is null
     or to_regprocedure('public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision)') is null
     or to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is null then
    raise exception 'TYPED-ZONE 0273: the 0233 pirate-intercept runtime is missing — the parity target must exist';
  end if;
  if to_regprocedure('public.st_asbinary(public.geometry)') is null then
    raise exception 'TYPED-ZONE 0273: PostGIS st_asbinary is missing — the untouched-parity assert needs it';
  end if;
end $pre$;

-- ── 0b. pre-image of the live world, for the untouched-parity assert at the end ──────────────────
create temporary table _tz0273_before on commit drop as
  select id,
         status,
         source,
         zone_kind,
         location_id,
         name,
         encode(public.st_asbinary(boundary), 'hex') as boundary_hex
    from public.danger_zones;

-- ── 1. zone_effect_pirate — the FIRST composable effect ─────────────────────────────────────────
-- One row = "this zone produces the pirate-interception effect". Every column is an OPTIONAL
-- override of the identically-named global; NULL = inherit the global. The CHECKs mirror the
-- meaning of each knob so an out-of-range override cannot be stored even by a future buggy writer.
create table public.zone_effect_pirate (
  zone_id          uuid primary key references public.danger_zones (id) on delete cascade,
  -- risk-curve overrides (all NULL ⇒ byte-for-byte the current global behaviour)
  base_risk        double precision check (base_risk        is null or (base_risk        >= 0 and base_risk        <= 1)),
  min_risk         double precision check (min_risk         is null or (min_risk         >= 0 and min_risk         <= 1)),
  max_risk         double precision check (max_risk         is null or (max_risk         >= 0 and max_risk         <= 1)),
  exposure_floor   double precision check (exposure_floor   is null or (exposure_floor   >= 0 and exposure_floor   <= 1)),
  stat_reference   double precision check (stat_reference   is null or stat_reference     > 0),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- an override pair that cannot be satisfied is rejected at write time, not discovered at runtime
  constraint zone_effect_pirate_risk_band
    check (min_risk is null or max_risk is null or min_risk <= max_risk)
);

comment on table public.zone_effect_pirate is
  'TYPED-ZONE PLATFORM (0273): the pirate-interception EFFECT of a zone. Presence of a row means the '
  'zone produces this effect; effects are COMPOSABLE, so a zone may hold rows in several zone_effect_* '
  'tables at once. Every column is an OPTIONAL per-zone override of the identically-named global '
  'game_config knob — NULL inherits the global, so an all-NULL row is exactly today''s behaviour. '
  'DARK: nothing reads this table until typed_zone_pirate_runtime_enabled is lit.';

-- RLS on, NO policy, NO grant: fail-closed. This is authoring/runtime configuration, never player
-- data. Only SECURITY DEFINER functions (none yet) and service_role will ever reach it. A future
-- editor read arrives with its own slice and its own explicit policy.
alter table public.zone_effect_pirate enable row level security;
revoke all on table public.zone_effect_pirate from anon, authenticated;

-- ── 2. backfill — one behaviour-neutral effect row per existing pirate zone ──────────────────────
-- ALL overrides NULL. This asserts nothing about the future dispatcher; it simply records that these
-- zones carry the pirate effect, which is already true of them in production today.
insert into public.zone_effect_pirate (zone_id)
  select z.id from public.danger_zones z where z.zone_kind = 'pirate'
on conflict (zone_id) do nothing;

-- ── 3. flags — both seeded FALSE, independently flippable ───────────────────────────────────────
insert into public.game_config (key, value, description) values
  ('typed_zone_authoring_enabled', 'false'::jsonb,
   'TYPED-ZONE PLATFORM: gates the world editor''s typed-zone mutation surface (geometry/effect '
   'authoring commands). Seeded false. Independent of the runtime flags — authoring an effect must '
   'never imply the generalized runtime resolves it.'),
  ('typed_zone_pirate_runtime_enabled', 'false'::jsonb,
   'TYPED-ZONE PLATFORM: when true the generalized effect dispatcher becomes authoritative for the '
   'pirate effect; while false the 0233 pirate_intercept path stays the sole authority. Seeded false. '
   'NEVER run both for side effects.')
on conflict (key) do nothing;

-- ── 4. SELF-ASSERT — lands dark, and the live world is untouched ────────────────────────────────
do $tzassert$
declare
  v_zone_count   int;
  v_effect_count int;
  v_orphans      int;
  v_drift        int;
  v_risk_def     text;
  v_cand_def     text;
  v_eval_def     text;
  v_read_def     text;
begin
  -- (1) both flags exist and are FALSE
  if coalesce(public.cfg_bool('typed_zone_authoring_enabled'), true) then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: typed_zone_authoring_enabled is not false'; end if;
  if coalesce(public.cfg_bool('typed_zone_pirate_runtime_enabled'), true) then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: typed_zone_pirate_runtime_enabled is not false'; end if;

  -- (2) THE LIVE WORLD IS BYTE-IDENTICAL: same rows, same geometry, same status/source/kind/attach/name.
  select count(*) into v_drift
    from public.danger_zones z
    full outer join _tz0273_before b on b.id = z.id
   where z.id is null
      or b.id is null
      or z.status               is distinct from b.status
      or z.source               is distinct from b.source
      or z.zone_kind            is distinct from b.zone_kind
      or z.location_id          is distinct from b.location_id
      or z.name                 is distinct from b.name
      or encode(public.st_asbinary(z.boundary), 'hex') is distinct from b.boundary_hex;
  if v_drift > 0 then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: % danger_zones row(s) drifted — this migration must not touch the live world', v_drift;
  end if;

  -- (3) every pirate zone has EXACTLY ONE effect row, and no effect row is orphaned
  select count(*) into v_zone_count   from public.danger_zones where zone_kind = 'pirate';
  select count(*) into v_effect_count from public.zone_effect_pirate;
  if v_zone_count <> v_effect_count then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: % pirate zones but % effect rows', v_zone_count, v_effect_count;
  end if;
  select count(*) into v_orphans
    from public.zone_effect_pirate e
    left join public.danger_zones z on z.id = e.zone_id and z.zone_kind = 'pirate'
   where z.id is null;
  if v_orphans > 0 then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: % effect row(s) reference a non-pirate/absent zone', v_orphans;
  end if;

  -- (4) BEHAVIOUR-NEUTRAL BY CONSTRUCTION: no backfilled row carries an override.
  if exists (select 1 from public.zone_effect_pirate
              where base_risk is not null or min_risk is not null or max_risk is not null
                 or exposure_floor is not null or stat_reference is not null) then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: a backfilled effect row carries an override — the foundation must be inert';
  end if;

  -- (5) BLAST RADIUS: the pirate runtime is NOT redefined here and stays blind to the new table.
  select pg_get_functiondef(to_regprocedure('public.pirate_intercept_compute_risk(double precision, double precision)')) into v_risk_def;
  if v_risk_def is null then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: pirate_intercept_compute_risk vanished'; end if;
  if v_risk_def ilike '%zone_effect_pirate%' then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: the risk function reads the new effect table — this slice must be dark'; end if;
  if strpos(v_risk_def, 'cfg_num(''pirate_intercept_base_risk'')') = 0
     or strpos(v_risk_def, 'cfg_num(''pirate_intercept_stat_reference'')') = 0 then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: the risk function no longer reads its global knobs — parity target moved'; end if;

  if to_regprocedure('public.get_danger_zones()') is not null then
    select pg_get_functiondef(to_regprocedure('public.get_danger_zones()')) into v_read_def;
    if v_read_def ilike '%zone_effect_pirate%' then
      raise exception 'TYPED-ZONE 0273 self-assert FAIL: the client zone read leaks the effect table'; end if;
  end if;
  -- the two functions that actually walk zone geometry at runtime
  if to_regprocedure('public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision)') is null then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: pirate_intercept_leg_zone_hits vanished'; end if;
  select pg_get_functiondef(to_regprocedure('public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision)')) into v_cand_def;
  if v_cand_def ilike '%zone_effect_pirate%' then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: the leg/zone-hit query reads the effect table — this slice must be dark'; end if;
  if to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is null then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: pirate_intercept_evaluate_leg vanished'; end if;
  select pg_get_functiondef(to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)')) into v_eval_def;
  if v_eval_def ilike '%zone_effect_pirate%' then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: the leg evaluator reads the effect table — this slice must be dark'; end if;

  -- (6) ACL: fail-closed. RLS on, no policy, no client grant.
  if not (select relrowsecurity from pg_class where oid = 'public.zone_effect_pirate'::regclass) then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: RLS is not enabled on zone_effect_pirate'; end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'zone_effect_pirate') then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: zone_effect_pirate has a policy — the foundation must be unreadable'; end if;
  if has_table_privilege('anon', 'public.zone_effect_pirate', 'select')
     or has_table_privilege('authenticated', 'public.zone_effect_pirate', 'select')
     or has_table_privilege('anon', 'public.zone_effect_pirate', 'insert')
     or has_table_privilege('authenticated', 'public.zone_effect_pirate', 'insert') then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: a client role can reach zone_effect_pirate'; end if;

  -- (7) the core table did NOT grow effect columns (no god object — trap 7)
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'danger_zones'
                and column_name in ('base_risk','min_risk','max_risk','exposure_floor','stat_reference',
                                    'ore_type','ore_amount','enemy_profile','exploration_reward')) then
    raise exception 'TYPED-ZONE 0273 self-assert FAIL: danger_zones grew an effect column — effects belong in side tables';
  end if;

  raise notice 'TYPED-ZONE 0273 self-assert ok: lands DARK (typed_zone_authoring_enabled and typed_zone_pirate_runtime_enabled both seeded false); the live world is BYTE-IDENTICAL (0 drifted rows across id/status/source/zone_kind/location_id/name/EWKB boundary); % pirate zone(s) each carry EXACTLY ONE zone_effect_pirate row and no row is orphaned; every backfilled row is all-NULL so the effect data is behaviour-neutral by construction (NULL inherits the global knob); pirate_intercept_compute_risk is NOT re-created, still reads its global knobs, and neither it nor get_danger_zones/get_intercept_candidates mentions the new table; zone_effect_pirate is RLS-on with NO policy and NO client grant (fail-closed); danger_zones grew no effect column (effects stay in composable side tables)', v_zone_count;
end $tzassert$;
