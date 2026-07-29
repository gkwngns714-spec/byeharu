-- TYPED-ZONE PIRATE SHADOW (0275) — disposable real-chain proof. SELF-ROLLING-BACK.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/typed-zone-shadow-proof.sql
--
-- Drives REAL geometry through BOTH paths and demands they agree. This is the slice that would catch
-- a planner that is internally consistent but wrong about the world.
--
-- Everything runs inside ONE transaction ending in ROLLBACK. The shadow itself writes nothing; the
-- transaction exists only because the proof creates fixture zones to have geometry worth comparing.

\set ON_ERROR_STOP on
\timing off

begin;

do $proof$
declare
  v_z1     uuid;
  v_z2     uuid;
  v_out    jsonb;
  v_req    jsonb;
  v_before bigint;
  v_after  bigint;
begin
  -- ── fixtures: two overlapping squares straddling a leg from (0,0) to (100,0) ─────────────────
  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
  values ('TZS Shallow', 'pirate', 'drawn', null,
    public.st_makepolygon(public.st_makeline(array[
      public.st_makepoint(10,-5), public.st_makepoint(30,-5),
      public.st_makepoint(30, 5), public.st_makepoint(10, 5), public.st_makepoint(10,-5)])),
    'active')
  returning id into v_z1;

  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
  values ('TZS Deep', 'pirate', 'drawn', null,
    public.st_makepolygon(public.st_makeline(array[
      public.st_makepoint(40,-5), public.st_makepoint(95,-5),
      public.st_makepoint(95, 5), public.st_makepoint(40, 5), public.st_makepoint(40,-5)])),
    'active')
  returning id into v_z2;

  insert into public.zone_effect_pirate_intercept (zone_id) values (v_z1), (v_z2);

  -- ── 1. the two paths AGREE over real geometry, across a stat sweep ───────────────────────────
  -- Both zones inherit every global, so the risks must be bit-identical, and the deeper zone
  -- (TZS Deep, 55 units of the leg vs 20) must be the one selected by BOTH.
  for v_before in select * from (values (0),(60),(120),(400),(5000)) as s(stats) loop
    v_out := public.typed_zone_pirate_shadow_compare_v1(0, 0, 100, 0, v_before::double precision);
    if (v_out->>'agree') <> 'true' then
      raise exception 'TZS_FAIL_AGREE: paths disagreed at combined_stats=% -> %', v_before, v_out;
    end if;
    if (v_out->'live'->>'zone_id')::uuid is distinct from v_z2 then
      raise exception 'TZS_FAIL_AGREE: the live path did not select the deeper zone (%)', v_out;
    end if;
    if (v_out->'new'->>'zone_id')::uuid is distinct from v_z2 then
      raise exception 'TZS_FAIL_AGREE: the typed-zone plan did not select the deeper zone (%)', v_out;
    end if;
  end loop;
  raise notice 'TZS_PASS_REAL_GEOMETRY_AGREEMENT';

  -- ── 2. a leg that crosses NOTHING agrees as "no_crossing" ────────────────────────────────────
  v_out := public.typed_zone_pirate_shadow_compare_v1(0, 900, 100, 900, 120);
  if (v_out->>'agree') <> 'true' or (v_out->>'reason') <> 'no_crossing' then
    raise exception 'TZS_FAIL_NO_CROSSING: %', v_out; end if;
  raise notice 'TZS_PASS_NO_CROSSING_AGREEMENT';

  -- ── 3. an INACTIVE zone drops out of BOTH paths identically ──────────────────────────────────
  update public.danger_zones set status = 'inactive' where id = v_z2;
  v_out := public.typed_zone_pirate_shadow_compare_v1(0, 0, 100, 0, 120);
  if (v_out->>'agree') <> 'true' then
    raise exception 'TZS_FAIL_INACTIVE: paths disagreed once the deep zone went inactive -> %', v_out; end if;
  if (v_out->'live'->>'zone_id')::uuid is distinct from v_z1
     or (v_out->'new'->>'zone_id')::uuid is distinct from v_z1 then
    raise exception 'TZS_FAIL_INACTIVE: selection did not fall through to the shallow zone -> %', v_out; end if;
  update public.danger_zones set status = 'active' where id = v_z2;
  raise notice 'TZS_PASS_INACTIVE_FALLTHROUGH';

  -- ── 4. a REAL override diverges, and is reported as an override — not as a failure ───────────
  -- This is the feature working: per-zone config is supposed to change the number. The shadow must
  -- distinguish "the planner is wrong" from "the owner configured this zone differently".
  update public.zone_effect_pirate_intercept set base_risk = 0.01 where zone_id = v_z2;
  v_out := public.typed_zone_pirate_shadow_compare_v1(0, 0, 100, 0, 120);
  if (v_out->>'agree') = 'true' then
    raise exception 'TZS_FAIL_OVERRIDE: an override did not change the planned risk -> %', v_out; end if;
  if not (v_out->'mismatch' @> '["risk_diverged_by_override"]'::jsonb) then
    raise exception 'TZS_FAIL_OVERRIDE: divergence was not attributed to the override -> %', v_out; end if;
  if (v_out->'new'->>'risk')::double precision >= (v_out->'live'->>'risk')::double precision then
    raise exception 'TZS_FAIL_OVERRIDE: a lower base_risk did not lower the planned risk -> %', v_out; end if;
  -- and with the override cleared, agreement returns
  update public.zone_effect_pirate_intercept set base_risk = null where zone_id = v_z2;
  v_out := public.typed_zone_pirate_shadow_compare_v1(0, 0, 100, 0, 120);
  if (v_out->>'agree') <> 'true' then
    raise exception 'TZS_FAIL_OVERRIDE: clearing the override did not restore parity -> %', v_out; end if;
  raise notice 'TZS_PASS_OVERRIDE_ATTRIBUTED';

  -- ── 5. a zone with NO effect row is not planned, and the shadow says so ──────────────────────
  delete from public.zone_effect_pirate_intercept where zone_id = v_z2;
  v_out := public.typed_zone_pirate_shadow_compare_v1(0, 0, 100, 0, 120);
  -- the live path still selects the deep zone (it knows nothing of effects); the new path plans the
  -- shallow one, because effects — not identity, not geometry alone — decide.
  if (v_out->>'agree') = 'true' then
    raise exception 'TZS_FAIL_NO_EFFECT: removing the effect changed nothing -> %', v_out; end if;
  if (v_out->'new'->>'zone_id')::uuid is distinct from v_z1 then
    raise exception 'TZS_FAIL_NO_EFFECT: the plan did not fall through to the zone that still carries the effect -> %', v_out; end if;
  insert into public.zone_effect_pirate_intercept (zone_id) values (v_z2);
  raise notice 'TZS_PASS_EFFECT_PRESENCE_DECIDES';

  -- ── 6. THE SHADOW WRITES NOTHING — proven by counting, not by reading the source ─────────────
  select count(*) into v_before from public.pirate_intercepts;
  perform public.typed_zone_pirate_shadow_compare_v1(0, 0, 100, 0, 120);
  perform public.typed_zone_pirate_shadow_compare_v1(0, 0, 100, 0, 60);
  select count(*) into v_after from public.pirate_intercepts;
  if v_after <> v_before then
    raise exception 'TZS_FAIL_WRITES: the shadow inserted % pirate_intercepts row(s)', v_after - v_before; end if;
  raise notice 'TZS_PASS_SHADOW_WRITES_NOTHING';

  -- ── 7. DETERMINISM: the same leg twice is byte-identical ─────────────────────────────────────
  if public.typed_zone_pirate_shadow_compare_v1(0, 0, 100, 0, 120)
     is distinct from public.typed_zone_pirate_shadow_compare_v1(0, 0, 100, 0, 120) then
    raise exception 'TZS_FAIL_DETERMINISM: two identical shadow runs disagreed'; end if;
  raise notice 'TZS_PASS_SHADOW_DETERMINISTIC';

  -- ── 8. the candidate builder emits a request the dispatcher accepts ──────────────────────────
  v_req := public.typed_zone_pirate_candidates_v1(
    '00000000-0000-4000-8000-000000000000'::uuid, 0, 0, 100, 0, 120);
  if (v_req->>'contract_version') <> '1' then
    raise exception 'TZS_FAIL_CONTRACT: the builder did not stamp contract_version 1'; end if;
  if jsonb_array_length(v_req->'candidates') < 2 then
    raise exception 'TZS_FAIL_CONTRACT: expected both fixture zones as candidates -> %', v_req; end if;
  if (v_req->'candidates'->0->>'zone_revision') is null then
    raise exception 'TZS_FAIL_CONTRACT: zone_revision missing from a candidate'; end if;
  if (public.typed_zone_effect_dispatch_v1(v_req)->>'ok') <> 'true' then
    raise exception 'TZS_FAIL_CONTRACT: the dispatcher rejected a live-built request'; end if;
  raise notice 'TZS_PASS_BUILDER_CONTRACT_VALID';
end $proof$;

rollback;

select 'TZS_PASS_ROLLED_BACK' as marker;
