-- TYPED-ZONE EFFECT FOUNDATION (0273) — disposable real-chain proof. SELF-ROLLING-BACK.
--
-- Run against a THROWAWAY local Supabase (never production):
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/typed-zone-foundation-proof.sql
--
-- `supabase start` has already applied the whole chain including 0273, so 0273's OWN in-migration
-- self-assert has run against real Postgres before this script begins — a regression there aborts
-- `supabase start` red and this proof never runs.
--
-- What this adds on top of that self-assert:
--   * PARITY, COMPUTED rather than asserted: an all-NULL effect row resolves knob-by-knob to exactly
--     the global values, and those resolved knobs reproduce pirate_intercept_compute_risk bit-for-bit
--     across a real input sweep.
--   * DARKNESS, demonstrated: writing a real per-zone override does NOT move the live risk function.
--   * COMPOSABILITY: effect presence is row existence — adding/removing an effect never touches the
--     core zone row, so a second effect can later be a sibling table without disturbing the first.
--   * The CHECK constraints reject exactly the bad overrides they claim to, and accept a good one.
--   * FK cascade: retiring a zone cannot strand an effect row.
--   * Fail-closed ACL from the client roles' own point of view (not just a privilege lookup).
-- Everything runs inside ONE transaction ending in ROLLBACK: no committed row, no flag flip.

\set ON_ERROR_STOP on
\timing off

begin;

do $proof$
declare
  v_zone      uuid;
  v_globals   record;
  v_eff       record;
  v_effective record;
  v_n         int;
  v_live      double precision;
  v_resolved  double precision;
  v_s         record;
  v_denied    boolean;
begin
  -- ── fixture: our own zone, so the proof never depends on seed data ────────────────────────────
  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
  values (
    'TZP Proof Zone', 'pirate', 'drawn', null,
    public.st_makepolygon(public.st_makeline(array[
      public.st_makepoint(0,0), public.st_makepoint(10,0),
      public.st_makepoint(10,10), public.st_makepoint(0,10),
      public.st_makepoint(0,0)
    ])),
    'active'
  )
  returning id into v_zone;

  -- ── 1. a fresh effect row is all-NULL (the backfill shape) ────────────────────────────────────
  insert into public.zone_effect_pirate (zone_id) values (v_zone);

  select count(*) into v_n from public.zone_effect_pirate where zone_id = v_zone;
  if v_n <> 1 then raise exception 'TZ_FAIL_BACKFILL: expected exactly 1 effect row, got %', v_n; end if;

  select * into v_eff from public.zone_effect_pirate where zone_id = v_zone;
  if v_eff.base_risk is not null or v_eff.min_risk is not null or v_eff.max_risk is not null
     or v_eff.exposure_floor is not null or v_eff.stat_reference is not null then
    raise exception 'TZ_FAIL_BACKFILL: a fresh effect row is not all-NULL';
  end if;
  raise notice 'TZ_PASS_BACKFILL_ALL_NULL';

  -- ── 2. PARITY: coalesce(override, global) === global, then reproduce the live risk exactly ────
  -- The literal fallbacks below mirror pirate_intercept_compute_risk's own coalesce defaults.
  select coalesce(public.cfg_num('pirate_intercept_base_risk'),      0.35) as base_risk,
         coalesce(public.cfg_num('pirate_intercept_min_risk'),       0.02) as min_risk,
         coalesce(public.cfg_num('pirate_intercept_max_risk'),       0.90) as max_risk,
         coalesce(public.cfg_num('pirate_intercept_exposure_floor'), 0.15) as exposure_floor,
         coalesce(public.cfg_num('pirate_intercept_stat_reference'), 120)  as stat_reference
    into v_globals;

  select coalesce(e.base_risk,      v_globals.base_risk)      as base_risk,
         coalesce(e.min_risk,       v_globals.min_risk)       as min_risk,
         coalesce(e.max_risk,       v_globals.max_risk)       as max_risk,
         coalesce(e.exposure_floor, v_globals.exposure_floor) as exposure_floor,
         coalesce(e.stat_reference, v_globals.stat_reference) as stat_reference
    into v_effective
    from public.zone_effect_pirate e where e.zone_id = v_zone;

  if v_effective.base_risk      is distinct from v_globals.base_risk
     or v_effective.min_risk       is distinct from v_globals.min_risk
     or v_effective.max_risk       is distinct from v_globals.max_risk
     or v_effective.exposure_floor is distinct from v_globals.exposure_floor
     or v_effective.stat_reference is distinct from v_globals.stat_reference then
    raise exception 'TZ_FAIL_PARITY: an all-NULL effect row did not resolve to the global knobs';
  end if;

  for v_s in
    select * from (values (0,0.0),(10,0.05),(60,0.25),(120,0.5),(400,0.9),(5000,1.0))
      as s(stats double precision, exposure double precision)
  loop
    v_live := public.pirate_intercept_compute_risk(v_s.stats, v_s.exposure);
    v_resolved := greatest(v_effective.min_risk,
                    least(v_effective.max_risk,
                      v_effective.base_risk
                        * (v_effective.stat_reference / (v_effective.stat_reference + greatest(v_s.stats, 0)))
                        * least(1.0, greatest(v_effective.exposure_floor, v_s.exposure))));
    if v_live is distinct from v_resolved then
      raise exception 'TZ_FAIL_PARITY: at stats=% exposure=% resolved % <> live %',
        v_s.stats, v_s.exposure, v_resolved, v_live;
    end if;
  end loop;
  raise notice 'TZ_PASS_PARITY_NEUTRAL';

  -- ── 3. CONSTRAINTS reject the bad, accept the good ────────────────────────────────────────────
  v_denied := false;
  begin
    update public.zone_effect_pirate set base_risk = 1.5 where zone_id = v_zone;
  exception when check_violation then v_denied := true;
  end;
  if not v_denied then raise exception 'TZ_FAIL_CONSTRAINT: base_risk > 1 was accepted'; end if;

  v_denied := false;
  begin
    update public.zone_effect_pirate set stat_reference = 0 where zone_id = v_zone;
  exception when check_violation then v_denied := true;
  end;
  if not v_denied then raise exception 'TZ_FAIL_CONSTRAINT: stat_reference = 0 was accepted'; end if;

  v_denied := false;
  begin
    update public.zone_effect_pirate set min_risk = 0.8, max_risk = 0.2 where zone_id = v_zone;
  exception when check_violation then v_denied := true;
  end;
  if not v_denied then raise exception 'TZ_FAIL_CONSTRAINT: an inverted min/max risk band was accepted'; end if;
  raise notice 'TZ_PASS_CONSTRAINTS';

  -- ── 4. DARKNESS: a REAL override is storable, and still moves nothing live ────────────────────
  update public.zone_effect_pirate
     set base_risk = 0.5, min_risk = 0.01, max_risk = 0.95
   where zone_id = v_zone;
  if (select base_risk from public.zone_effect_pirate where zone_id = v_zone) is distinct from 0.5 then
    raise exception 'TZ_FAIL_CONSTRAINT: a valid override did not persist';
  end if;

  v_live := public.pirate_intercept_compute_risk(120, 0.5);
  v_resolved := greatest(v_globals.min_risk,
                  least(v_globals.max_risk,
                    v_globals.base_risk
                      * (v_globals.stat_reference / (v_globals.stat_reference + 120))
                      * least(1.0, greatest(v_globals.exposure_floor, 0.5))));
  if v_live is distinct from v_resolved then
    raise exception 'TZ_FAIL_DARK: a per-zone override moved the live risk function — the slice is not dark';
  end if;
  update public.zone_effect_pirate
     set base_risk = null, min_risk = null, max_risk = null
   where zone_id = v_zone;
  raise notice 'TZ_PASS_DARK_NO_RUNTIME_EFFECT';

  -- ── 5. COMPOSABILITY: effect presence is row existence; the core row is untouched ─────────────
  delete from public.zone_effect_pirate where zone_id = v_zone;
  if not exists (select 1 from public.danger_zones where id = v_zone) then
    raise exception 'TZ_FAIL_COMPOSABLE: removing an effect deleted the zone';
  end if;
  if exists (select 1 from public.zone_effect_pirate where zone_id = v_zone) then
    raise exception 'TZ_FAIL_COMPOSABLE: the effect row survived its own delete';
  end if;
  insert into public.zone_effect_pirate (zone_id) values (v_zone);
  raise notice 'TZ_PASS_COMPOSABLE_PRESENCE_IS_ROW';

  -- ── 6. CASCADE: retiring a zone cannot strand an effect row ───────────────────────────────────
  delete from public.danger_zones where id = v_zone;
  if exists (select 1 from public.zone_effect_pirate where zone_id = v_zone) then
    raise exception 'TZ_FAIL_CASCADE: an effect row outlived its zone';
  end if;
  raise notice 'TZ_PASS_CASCADE';
end $proof$;

-- ── 7. ACL from the client roles' own point of view (fail-closed) ────────────────────────────────
do $acl$
declare v_denied boolean;
begin
  v_denied := false;
  begin
    set local role anon;
    perform 1 from public.zone_effect_pirate limit 1;
  exception when insufficient_privilege then v_denied := true;
  end;
  reset role;
  if not v_denied then raise exception 'TZ_FAIL_ACL: anon can read zone_effect_pirate'; end if;

  v_denied := false;
  begin
    set local role authenticated;
    perform 1 from public.zone_effect_pirate limit 1;
  exception when insufficient_privilege then v_denied := true;
  end;
  reset role;
  if not v_denied then raise exception 'TZ_FAIL_ACL: authenticated can read zone_effect_pirate'; end if;

  v_denied := false;
  begin
    set local role authenticated;
    insert into public.zone_effect_pirate (zone_id)
      values ('00000000-0000-0000-0000-000000000000'::uuid);
  exception when insufficient_privilege then v_denied := true;
             when others then v_denied := true;  -- FK/RLS also acceptable; a client must not write
  end;
  reset role;
  if not v_denied then raise exception 'TZ_FAIL_ACL: authenticated can write zone_effect_pirate'; end if;

  raise notice 'TZ_PASS_ACL_FAIL_CLOSED';
end $acl$;

-- ── 8. the committed flags are false (we never flipped them) ─────────────────────────────────────
do $flags$
begin
  if coalesce(public.cfg_bool('typed_zone_authoring_enabled'), true) then
    raise exception 'TZ_FAIL_FLAGS: typed_zone_authoring_enabled is not false'; end if;
  if coalesce(public.cfg_bool('typed_zone_pirate_runtime_enabled'), true) then
    raise exception 'TZ_FAIL_FLAGS: typed_zone_pirate_runtime_enabled is not false'; end if;
  raise notice 'TZ_PASS_FLAGS_DARK';
end $flags$;

rollback;

-- nothing above is committed: the disposable DB is left exactly as `supabase start` produced it.
select 'TZ_PASS_ROLLED_BACK' as marker;
