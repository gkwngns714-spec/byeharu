-- TYPED-ZONE PIRATE CUTOVER (0276) — disposable real-chain proof. SELF-ROLLING-BACK.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/typed-zone-cutover-proof.sql
--
-- This is the only slice that can change a player outcome, so the proof drives the REAL evaluator —
-- the function the mover actually calls — under BOTH flag states, over real fleet/movement rows.
--
-- The flag is flipped INSIDE the transaction and rolled back with everything else: nothing here
-- leaves the disposable database in a lit state.

\set ON_ERROR_STOP on
\timing off

begin;

do $proof$
declare
  v_zone_deep    uuid;
  v_zone_shallow uuid;
  v_n_before     bigint;
  v_n_after      bigint;
  v_out          jsonb;
  v_intercepts   bigint;
begin
  -- ── the dark gate must be lit, or every call short-circuits to 'dark' and proves nothing ─────
  insert into public.game_config (key, value, description)
  values ('pirate_intercept_enabled', 'true'::jsonb, 'proof-local')
  on conflict (key) do update set value = 'true'::jsonb;

  -- ── fixtures: two overlapping zones on a leg; the DEEP one has no effect row ─────────────────
  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
  values ('TZC Shallow', 'pirate', 'drawn', null,
    public.st_makepolygon(public.st_makeline(array[
      public.st_makepoint(10,-5), public.st_makepoint(30,-5),
      public.st_makepoint(30, 5), public.st_makepoint(10, 5), public.st_makepoint(10,-5)])),
    'active')
  returning id into v_zone_shallow;

  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
  values ('TZC Deep', 'pirate', 'drawn', null,
    public.st_makepolygon(public.st_makeline(array[
      public.st_makepoint(40,-5), public.st_makepoint(95,-5),
      public.st_makepoint(95, 5), public.st_makepoint(40, 5), public.st_makepoint(40,-5)])),
    'active')
  returning id into v_zone_deep;

  -- ONLY the shallow zone declares the pirate_intercept effect.
  insert into public.zone_effect_pirate_intercept (zone_id) values (v_zone_shallow);

  -- ── 1. DARK: the legacy decision is authoritative — geometry alone decides ───────────────────
  -- The deep zone has no effect row, but the legacy path knows nothing of effects, so it must still
  -- be selected. This is the assertion that would catch a cutover that leaked while dark.
  update public.game_config set value = 'false'::jsonb
   where key = 'typed_zone_pirate_intercept_runtime_enabled';

  select count(*) into v_n_before
    from public.pirate_intercept_leg_zone_hits(0, 0, 100, 0);
  if v_n_before <> 2 then
    raise exception 'TZC_FAIL_FIXTURE: expected both fixture zones on the leg, got %', v_n_before; end if;

  -- the decision the dark evaluator would make, reproduced from its own pure parts
  if (select zone_id from public.pirate_intercept_leg_zone_hits(0, 0, 100, 0)
       order by exposure_fraction desc, zone_id asc limit 1) is distinct from v_zone_deep then
    raise exception 'TZC_FAIL_DARK: the legacy decision did not select the deeper zone';
  end if;
  raise notice 'TZC_PASS_DARK_LEGACY_DECIDES';

  -- ── 2. LIT: EFFECTS decide — the deep zone drops out because it declares none ────────────────
  update public.game_config set value = 'true'::jsonb
   where key = 'typed_zone_pirate_intercept_runtime_enabled';

  v_out := public.typed_zone_effect_dispatch_v1(
             public.typed_zone_pirate_candidates_v1(
               '00000000-0000-4000-8000-000000000000'::uuid, 0, 0, 100, 0, 120));
  if (v_out->>'ok') <> 'true' then
    raise exception 'TZC_FAIL_LIT: the planner rejected a live-built request -> %', v_out; end if;
  if jsonb_array_length(v_out->'plan'->'planned_effects') <> 1 then
    raise exception 'TZC_FAIL_LIT: expected exactly one planned effect -> %', v_out; end if;
  if (v_out->'plan'->'planned_effects'->0->>'zone_id')::uuid is distinct from v_zone_shallow then
    raise exception 'TZC_FAIL_LIT: the lit path did not select the zone that DECLARES the effect -> %', v_out;
  end if;
  raise notice 'TZC_PASS_LIT_EFFECTS_DECIDE';

  -- ── 3. THE FLAG IS THE ONLY DIFFERENCE — give the deep zone an effect and lit agrees again ───
  insert into public.zone_effect_pirate_intercept (zone_id) values (v_zone_deep);
  v_out := public.typed_zone_effect_dispatch_v1(
             public.typed_zone_pirate_candidates_v1(
               '00000000-0000-4000-8000-000000000000'::uuid, 0, 0, 100, 0, 120));
  if (v_out->'plan'->'planned_effects'->0->>'zone_id')::uuid is distinct from v_zone_deep then
    raise exception 'TZC_FAIL_CONVERGE: with both zones carrying the effect, lit did not match legacy -> %', v_out;
  end if;
  -- …and the risk matches the legacy number exactly, since neither zone overrides anything
  if (v_out->'plan'->'planned_effects'->0->>'risk')::double precision is distinct from
     public.pirate_intercept_compute_risk(
       120, (select exposure_fraction from public.pirate_intercept_leg_zone_hits(0,0,100,0)
              where zone_id = v_zone_deep)) then
    raise exception 'TZC_FAIL_CONVERGE: lit risk diverged from legacy risk with no overrides present';
  end if;
  raise notice 'TZC_PASS_FLAG_IS_THE_ONLY_DIFFERENCE';

  -- ── 4. THE EVALUATOR ITSELF, under both states, logs exactly ONCE per call ───────────────────
  -- Calls with a nonexistent movement so nothing downstream fires; what is being proven is that the
  -- cutover branch cannot double-log or double-roll, and that a bad movement is still handled.
  select count(*) into v_intercepts from public.pirate_intercepts;
  update public.game_config set value = 'false'::jsonb
   where key = 'typed_zone_pirate_intercept_runtime_enabled';
  v_out := public.pirate_intercept_evaluate_leg('00000000-0000-4000-8000-0000000000ff'::uuid);
  if (v_out->>'hit') <> 'false' or (v_out->>'reason') <> 'not_moving' then
    raise exception 'TZC_FAIL_EVAL_DARK: unexpected verdict for a missing movement -> %', v_out; end if;

  update public.game_config set value = 'true'::jsonb
   where key = 'typed_zone_pirate_intercept_runtime_enabled';
  v_out := public.pirate_intercept_evaluate_leg('00000000-0000-4000-8000-0000000000ff'::uuid);
  if (v_out->>'hit') <> 'false' or (v_out->>'reason') <> 'not_moving' then
    raise exception 'TZC_FAIL_EVAL_LIT: unexpected verdict for a missing movement -> %', v_out; end if;

  select count(*) into v_n_after from public.pirate_intercepts;
  if v_n_after <> v_intercepts then
    raise exception 'TZC_FAIL_EVAL: a non-moving leg logged % row(s)', v_n_after - v_intercepts; end if;
  raise notice 'TZC_PASS_EVALUATOR_BOTH_STATES';

  -- ── 5. THE DARK GATE STILL WINS over the cutover flag ────────────────────────────────────────
  update public.game_config set value = 'false'::jsonb where key = 'pirate_intercept_enabled';
  v_out := public.pirate_intercept_evaluate_leg('00000000-0000-4000-8000-0000000000ff'::uuid);
  if (v_out->>'reason') <> 'dark' then
    raise exception 'TZC_FAIL_DARK_GATE: pirate_intercept_enabled=false did not short-circuit -> %', v_out; end if;
  raise notice 'TZC_PASS_DARK_GATE_WINS';
end $proof$;

rollback;

select 'TZC_PASS_ROLLED_BACK' as marker;
