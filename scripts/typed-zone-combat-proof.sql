-- TYPED-ZONE COMBAT EFFECT (0278) — disposable real-chain proof. SELF-ROLLING-BACK.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/typed-zone-combat-proof.sql
--
-- The claim under test is COMPOSABILITY: adding a second effect must not disturb the first. The way
-- that claim fails in practice is subtle — a zone carrying both effects starts being rejected, or
-- silently skipped, by the V1 pirate planner. So this proof puts both effects on ONE zone and shows
-- the pirate path is byte-identical to a zone that carries only pirate.
--
-- It also proves the dual gate is a real AND against the running database, by lighting each half in
-- turn inside the transaction and rolling everything back.

\set ON_ERROR_STOP on
\timing off

begin;

do $proof$
declare
  v_zone_both uuid;
  v_zone_only uuid;
  v_profile   uuid;
  v_out_both  jsonb;
  v_out_only  jsonb;
  v_risk_both double precision;
  v_risk_only double precision;
  v_n         int;
begin
  -- A real encounter profile to point at — the FK is not decorative. The proof MINTS its own rather
  -- than depending on seed data: a "skip when absent" branch would emit PASS markers for tests that
  -- never ran, which is worse than no proof at all. Rolled back with everything else.
  insert into public.encounter_profiles (key, display_name, difficulty)
  values ('tzk_proof_profile', 'TZK Proof Profile', 1)
  on conflict (key) do update set display_name = excluded.display_name
  returning id into v_profile;
  if v_profile is null then
    raise exception 'TZK_FAIL_FIXTURE: could not mint an encounter profile';
  end if;

  -- ── fixtures: two IDENTICAL zones, one of which also carries a combat effect ─────────────────
  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
  values ('TZK Both', 'pirate', 'drawn', null,
    public.st_makepolygon(public.st_makeline(array[
      public.st_makepoint(10,-5), public.st_makepoint(60,-5),
      public.st_makepoint(60, 5), public.st_makepoint(10, 5), public.st_makepoint(10,-5)])),
    'active')
  returning id into v_zone_both;

  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
  values ('TZK Only', 'pirate', 'drawn', null,
    public.st_makepolygon(public.st_makeline(array[
      public.st_makepoint(10, 95), public.st_makepoint(60, 95),
      public.st_makepoint(60,105), public.st_makepoint(10,105), public.st_makepoint(10, 95)])),
    'active')
  returning id into v_zone_only;

  insert into public.zone_effect_pirate_intercept (zone_id) values (v_zone_both), (v_zone_only);
  -- ONLY the first also carries combat
  insert into public.zone_effect_combat (zone_id, encounter_profile_id) values (v_zone_both, v_profile);

  -- ── 1. COMPOSABILITY: the pirate path is unaffected by the presence of a combat effect ───────
  -- identical legs through each zone; the planned risk must be identical
  v_out_both := public.typed_zone_effect_dispatch_v1(
    public.typed_zone_pirate_candidates_v1(
      '00000000-0000-4000-8000-000000000001'::uuid, 0, 0, 100, 0, 120));
  v_out_only := public.typed_zone_effect_dispatch_v1(
    public.typed_zone_pirate_candidates_v1(
      '00000000-0000-4000-8000-000000000002'::uuid, 0, 100, 100, 100, 120));

  if (v_out_both->>'ok') <> 'true' then
    raise exception 'TZK_FAIL_COMPOSABLE: the planner REJECTED a zone carrying two effects -> %', v_out_both;
  end if;
  if (v_out_only->>'ok') <> 'true' then
    raise exception 'TZK_FAIL_COMPOSABLE: the single-effect control was rejected -> %', v_out_only; end if;
  if jsonb_array_length(v_out_both->'plan'->'planned_effects') <> 1 then
    raise exception 'TZK_FAIL_COMPOSABLE: the two-effect zone did not plan exactly one pirate effect -> %', v_out_both;
  end if;
  if (v_out_both->'plan'->'planned_effects'->0->>'effect_type') <> 'pirate_intercept' then
    raise exception 'TZK_FAIL_COMPOSABLE: a non-pirate effect leaked into a V1 plan -> %', v_out_both;
  end if;

  v_risk_both := (v_out_both->'plan'->'planned_effects'->0->>'risk')::double precision;
  v_risk_only := (v_out_only->'plan'->'planned_effects'->0->>'risk')::double precision;
  if v_risk_both is distinct from v_risk_only then
    raise exception 'TZK_FAIL_COMPOSABLE: carrying a combat effect changed the pirate risk (% vs %)',
      v_risk_both, v_risk_only;
  end if;
  raise notice 'TZK_PASS_COMPOSABLE_PIRATE_UNAFFECTED';

  -- ── 2. the combat row is INERT — nothing dispatches it, and its presence is just a row ───────
  select count(*) into v_n from public.zone_effect_combat where zone_id = v_zone_both;
  if v_n <> 1 then raise exception 'TZK_FAIL_PRESENCE: expected one combat row, got %', v_n; end if;
  -- removing it must not touch the zone or its pirate effect
  delete from public.zone_effect_combat where zone_id = v_zone_both;
  if not exists (select 1 from public.danger_zones where id = v_zone_both) then
    raise exception 'TZK_FAIL_PRESENCE: removing a combat effect deleted the zone'; end if;
  if not exists (select 1 from public.zone_effect_pirate_intercept where zone_id = v_zone_both) then
    raise exception 'TZK_FAIL_PRESENCE: removing a combat effect removed the pirate effect'; end if;
  insert into public.zone_effect_combat (zone_id, encounter_profile_id) values (v_zone_both, v_profile);
  raise notice 'TZK_PASS_EFFECTS_INDEPENDENT';

  -- ── 3. THE DUAL GATE IS A REAL AND — proven by lighting each half in turn ────────────────────
  update public.game_config set value = 'false'::jsonb where key = 'typed_zone_combat_runtime_enabled';
  update public.game_config set value = 'false'::jsonb where key = 'encounter_resolver_enabled';
  if public.typed_zone_combat_capability_v1() then
    raise exception 'TZK_FAIL_GATE: capability open with BOTH halves dark'; end if;

  update public.game_config set value = 'true'::jsonb where key = 'typed_zone_combat_runtime_enabled';
  if public.typed_zone_combat_capability_v1() then
    raise exception 'TZK_FAIL_GATE: capability opened with only the ZONE half lit — that is an OR'; end if;

  update public.game_config set value = 'false'::jsonb where key = 'typed_zone_combat_runtime_enabled';
  update public.game_config set value = 'true'::jsonb  where key = 'encounter_resolver_enabled';
  if public.typed_zone_combat_capability_v1() then
    raise exception 'TZK_FAIL_GATE: capability opened with only the RESOLVER half lit — that is an OR'; end if;

  update public.game_config set value = 'true'::jsonb where key = 'typed_zone_combat_runtime_enabled';
  if not public.typed_zone_combat_capability_v1() then
    raise exception 'TZK_FAIL_GATE: capability stayed closed with BOTH halves lit — that is not an AND'; end if;
  raise notice 'TZK_PASS_DUAL_GATE_IS_AND';

  -- ── 4. CONSTRAINTS reject what they claim to ─────────────────────────────────────────────────
  declare v_denied boolean;
  begin
    v_denied := false;
    begin
      update public.zone_effect_combat set spawn_chance = 'NaN'::double precision where zone_id = v_zone_both;
    exception when check_violation then v_denied := true; end;
    if not v_denied then raise exception 'TZK_FAIL_CONSTRAINT: spawn_chance accepted NaN'; end if;

    v_denied := false;
    begin
      update public.zone_effect_combat set spawn_chance = 'Infinity'::double precision where zone_id = v_zone_both;
    exception when check_violation then v_denied := true; end;
    if not v_denied then raise exception 'TZK_FAIL_CONSTRAINT: spawn_chance accepted Infinity'; end if;

    v_denied := false;
    begin
      update public.zone_effect_combat set max_concurrent = 0 where zone_id = v_zone_both;
    exception when check_violation then v_denied := true; end;
    if not v_denied then raise exception 'TZK_FAIL_CONSTRAINT: max_concurrent accepted 0'; end if;

    v_denied := false;
    begin
      insert into public.zone_effect_combat (zone_id, encounter_profile_id)
      values (v_zone_only, '00000000-0000-4000-8000-0000000000ff'::uuid);
    exception when foreign_key_violation then v_denied := true; end;
    if not v_denied then raise exception 'TZK_FAIL_CONSTRAINT: a dangling encounter profile was accepted'; end if;
  end;
  raise notice 'TZK_PASS_CONSTRAINTS';

  -- ── 5. CASCADE: retiring a zone cannot strand a combat row ───────────────────────────────────
  delete from public.danger_zones where id = v_zone_both;
  if exists (select 1 from public.zone_effect_combat where zone_id = v_zone_both) then
    raise exception 'TZK_FAIL_CASCADE: a combat row outlived its zone'; end if;
  raise notice 'TZK_PASS_CASCADE';
end $proof$;

rollback;

select 'TZK_PASS_ROLLED_BACK' as marker;
