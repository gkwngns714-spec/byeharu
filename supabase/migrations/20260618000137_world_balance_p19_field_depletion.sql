-- Byeharu — WORLD-BALANCE-P19 SLICE 3: RESOURCE-FIELD DEPLETION (dark-gated; producer+consumer slice).
--
-- Phase 19 third (final) mechanic. Worked mining fields visibly THIN OUT and slowly RECOVER — but
-- `mining_fields` stays static server-only Reference/Config (NO runtime writer). Depletion is NEW
-- World-State-owned state, composed with the field's yield at extraction time and REGENERATED over time
-- by the tick. Producer (the tick regen + the deplete writer) and consumer (mining_extract scales its
-- bundle by the reserve and depletes once per real extraction) ship together in this ONE revertible
-- commit, so nothing is dead.
--
-- GROUNDED IN THE REAL CODE (read first, not guessed):
--   · `mining_extract` (0104): resolves the NEAREST active field, snapshots the field's deterministic
--     `reward_bundle_json` verbatim into `mining_extractions.pending_bundle_json`. IDEMPOTENCY: a replay
--     of (ship, request_id) RETURNS at the receipt lookup (step 6) BEFORE the extraction-row insert
--     (step 12) and the receipt insert (step 13) — so a replay writes NO row and NO receipt. The REAL
--     extraction is steps 12–13 in one transaction; depletion is placed there so it fires exactly once
--     per real extraction and NEVER on replay.
--   · `mining_fields` (0103): items-only bundle `{"items":[{"item_id","quantity"}]}`, jsonb object.
--   · post-0136 `worldstate_tick()`: decays pressure + drives `price_multiplier`, gated on
--     `world_balance_enabled`. This slice adds a gated field-regen pass in the same idiom.
--
-- DESIGN (self-approved; "world-state owns world-state" + no-second-writer / no-cycle / NO-SOFTLOCK):
--   1. NO runtime writer to `mining_fields` — it stays static server-only Reference/Config, the SOLE
--      source of the BASE yield. Depletion is composed on top at extraction time.
--   2. NEW World-State-OWNED table `mining_field_state` (field_id PK → mining_fields, reserve_fraction
--      numeric default 1.0 CHECK [0,1]). Rows are created LAZILY on first depletion (upsert) — no
--      seeding, no dead rows; an un-mined field has NO row and reads as full (1.0). World State is the
--      SOLE writer (the tick regen + `worldstate_deplete_field`).
--   3. Two World State functions (internal/service-role), BOTH FAIL-CLOSED on `world_balance_enabled`
--      (defense in depth — a stray caller cannot deplete while dark):
--      · `worldstate_field_remaining(field)` → 1.0 while dark OR when no state row; else reserve_fraction.
--      · `worldstate_deplete_field(field)`   → no-op while dark; else upserts reserve_fraction down by
--        `world_balance_field_depletion_per_extract`, hard-floored at `world_balance_field_reserve_min`
--        (a depleted field NEVER fully dies — NO-SOFTLOCK). THE sole reserve write on extraction.
--   4. REGEN in `worldstate_tick()`, gated on `world_balance_enabled`: nudge every
--      `mining_field_state.reserve_fraction` toward 1.0 by `world_balance_field_regen_rate` per tick,
--      clamped ≤ 1.0 (the STEP-1/2 bounded-target idiom). While dark the tick does NOT touch these rows
--      (the whole block is gated), so the tick stays byte-identical to 0136.
--   5. EFFECT wired into `mining_extract`, entirely inside `if cfg_bool('world_balance_enabled')` so
--      mining is byte-identical while dark: after the field + its bundle are resolved, read
--      `worldstate_field_remaining(field)` and scale each item qty by it with a per-item floor of 1 —
--      `greatest(1, round(qty * reserve))` — BEFORE writing `pending_bundle_json` (diminishing returns);
--      then `worldstate_deplete_field(field)` EXACTLY ONCE, in the success path right after the
--      extraction-row insert (unreachable on replay → no double-deplete). While dark reserve = 1.0 →
--      `greatest(1, round(qty*1.0)) = qty` → the stored bundle is verbatim today's, and deplete is
--      never called.
--
-- OWNERSHIP / ACYCLICITY (docs/SYSTEM_BOUNDARIES.md, synced SAME step):
--   · World State stays the SOLE writer of `mining_field_state` (tick regen + `worldstate_deplete_field`).
--     NEW edges: Mining → World State — READ `worldstate_field_remaining` and CALL the writer-function
--     `worldstate_deplete_field` — both DOWNWARD (an activity depending on the world-state leaf).
--     ACYCLIC: World State never reads or calls Mining. NO new edge into `mining_fields` (still static,
--     no runtime writer, no second writer). Mining still deposits ONLY via `Reward.grant('mining', …)`
--     (slice-D processor, unchanged) and NEVER writes `mining_fields`.
--
-- CONFIG (all consumed this slice; reuse `world_balance_enabled`, do NOT re-seed):
--   world_balance_field_depletion_per_extract='0.1'  (−10% per extraction)
--   world_balance_field_regen_rate='0.02'            (slow recovery, ~full in ~45 ticks)
--   world_balance_field_reserve_min='0.1'            (floor — a worked field always yields something)
--
-- RETIREMENT / ACTIVATION: same as 0135/0136 — `world_balance_enabled` is the permanent Phase-19 gate.
-- Lit-path verification (flag on a DEV DB → extract repeatedly → bundle thins toward the floor,
-- reserve upserts down; idle ticks regen it back toward 1.0; a replay never double-depletes) is deferred
-- to the human's activation checklist. This migration flips NO flag; 0001–0136 unedited (forward-only).

-- ── (a) config: the depletion tunables (all NEW, all consumed this slice) ─────────────────────────
insert into public.game_config (key, value, description) values
  ('world_balance_field_depletion_per_extract', '0.1',
   'WORLD-BALANCE-P19 (field depletion): fraction subtracted from a mining field''s reserve_fraction '
   'per real extraction (worldstate_deplete_field), hard-floored at world_balance_field_reserve_min. '
   'Only used when world_balance_enabled=true.'),
  ('world_balance_field_regen_rate', '0.02',
   'WORLD-BALANCE-P19 (field depletion): fraction of the gap to 1.0 a field''s reserve_fraction '
   'recovers each tick (worldstate_tick regen; ~full in ~45 ticks). Only used when world_balance_enabled=true.'),
  ('world_balance_field_reserve_min', '0.1',
   'WORLD-BALANCE-P19 (field depletion): hard floor on reserve_fraction — a depleted field never fully '
   'dies (NO-SOFTLOCK: always some yield via the greatest(1,…) per-item floor). Only used when '
   'world_balance_enabled=true.')
on conflict (key) do nothing;

-- ── (b) mining_field_state — the World-State-owned reserve (lazy rows; server-only; sole writer=WS) ─
-- No row = full (1.0). Created lazily on first depletion. World State is the SOLE writer (the tick
-- regen + worldstate_deplete_field). Server-only, exactly the mining_fields posture (RLS on, NO client
-- policy/grant): reserve state is internal world-state, never a client read path.
create table if not exists public.mining_field_state (
  field_id         uuid primary key references public.mining_fields (id) on delete cascade,
  reserve_fraction numeric not null default 1.0 check (reserve_fraction >= 0 and reserve_fraction <= 1.0),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table public.mining_field_state enable row level security;  -- server-only: no client policy/grant.

comment on table public.mining_field_state is
  'WORLD-BALANCE-P19: World-State-owned per-field mining reserve (SOLE writer = World State: the '
  'worldstate_tick regen + worldstate_deplete_field). Rows created LAZILY on first depletion; no row = '
  'full (reserve_fraction 1.0). Composed with the static mining_fields yield at extraction time via '
  'worldstate_field_remaining. Server-only (RLS on, no client policy/grant). DARK/no-op while '
  'world_balance_enabled=false (the tick never touches it; worldstate_field_remaining returns 1.0).';

-- ── (c) worldstate_field_remaining — the flag-gated reserve read (internal/service-role) ───────────
-- 1.0 while dark REGARDLESS of any stored row (the provable dark guarantee), else the field's
-- reserve_fraction (1.0 if no row). World State reads its OWN mining_field_state — no cross-system read.
create or replace function public.worldstate_field_remaining(p_field uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
           when not coalesce(public.cfg_bool('world_balance_enabled'), false) then 1.0::numeric
           else coalesce(
             (select s.reserve_fraction from public.mining_field_state s where s.field_id = p_field),
             1.0::numeric)
         end;
$$;
revoke execute on function public.worldstate_field_remaining(uuid) from public, anon, authenticated;
grant  execute on function public.worldstate_field_remaining(uuid) to service_role;

-- ── (d) worldstate_deplete_field — THE sole reserve write on extraction (flag-gated; internal) ─────
-- No-op while dark (defense in depth — a stray caller cannot deplete while dark). Else upserts the
-- reserve DOWN by the per-extract fraction, hard-floored at the reserve_min (NO-SOFTLOCK — never 0).
create or replace function public.worldstate_deplete_field(p_field uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_per   numeric := coalesce(cfg_num('world_balance_field_depletion_per_extract'), 0.1);
  v_floor numeric := coalesce(cfg_num('world_balance_field_reserve_min'), 0.1);
begin
  if not coalesce(public.cfg_bool('world_balance_enabled'), false) then
    return;  -- DARK: no-op.
  end if;
  insert into public.mining_field_state (field_id, reserve_fraction)
    values (p_field, greatest(v_floor, 1.0 - v_per))
  on conflict (field_id) do update
    set reserve_fraction = greatest(v_floor, public.mining_field_state.reserve_fraction - v_per),
        updated_at = now();
end;
$$;
revoke execute on function public.worldstate_deplete_field(uuid) from public, anon, authenticated;
grant  execute on function public.worldstate_deplete_field(uuid) to service_role;

-- ── (e) worldstate_tick: EXACTLY the 0136 body except a flag-gated field-regen pass ────────────────
-- Every unchanged line is byte-for-byte 0136. Differences: the v_field_regen config local + the gated
-- mining_field_state regen UPDATE (step 5). While dark the regen block is skipped → mining_field_state
-- is untouched and the location_state logic is identical to 0136, so a dark tick is byte-identical.
create or replace function public.worldstate_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_min        double precision := coalesce(cfg_num('worldstate_pressure_min'), 0);
  v_max        double precision := coalesce(cfg_num('worldstate_pressure_max'), 100);
  v_baseline   double precision := coalesce(cfg_num('worldstate_pressure_baseline'), 50);
  v_decay_rate double precision := coalesce(cfg_num('worldstate_pressure_decay_rate'), 0.1);
  v_relief     double precision := coalesce(cfg_num('worldstate_pressure_relief_per_active_fleet'), 3);
  v_min_mod    double precision := coalesce(cfg_num('worldstate_danger_min_modifier'), 0.95);
  v_max_mod    double precision := coalesce(cfg_num('worldstate_danger_max_modifier'), 1.20);
  v_min_secs   double precision := coalesce(cfg_num('worldstate_min_tick_seconds'), 30);
  -- Phase-19 pirate pressure (dark unless world_balance_enabled). Resolved once per tick. (0135)
  v_wb_enabled    boolean          := coalesce(cfg_bool('world_balance_enabled'), false);
  v_defeat_inc    double precision := coalesce(cfg_num('worldstate_pressure_defeat_increase'), 4);      -- reused 0032 key
  v_defeat_window double precision := coalesce(cfg_num('world_balance_defeat_window_seconds'), 3600);   -- 0135 tunable
  -- Phase-19 price drift (dark unless world_balance_enabled). Reuses baseline/max above. (0136)
  v_price_coeff   double precision := coalesce(cfg_num('world_balance_price_pressure_coeff'), 0.5);
  v_price_rate    double precision := coalesce(cfg_num('world_balance_price_drift_rate'), 0.1);
  v_mult_min      double precision := coalesce(cfg_num('world_balance_price_multiplier_min'), 0.5);
  v_mult_max      double precision := coalesce(cfg_num('world_balance_price_multiplier_max'), 2.0);
  -- Phase-19 field depletion regen (dark unless world_balance_enabled). (0137)
  v_field_regen   double precision := coalesce(cfg_num('world_balance_field_regen_rate'), 0.02);
  r            location_state%rowtype;
  v_real       integer;
  v_elapsed    double precision;
  v_drifted    boolean;
  v_pressure   double precision;
  v_decay      double precision;
  v_defeats    integer;
  v_danger_term double precision;
  v_target     double precision;
  v_norm       double precision;
  v_mult_target double precision;
  v_new_mult   numeric;
  v_mod        double precision;
  v_count      integer := 0;
begin
  for r in select * from location_state for update skip locked loop
    -- (1) Reconcile active_fleets from the source of truth (active presences).
    select count(*) into v_real
      from location_presence
      where location_id = r.location_id and status in ('active','retreating','leaving');

    v_elapsed  := extract(epoch from (now() - r.last_tick_at));
    v_pressure := r.pressure;
    v_drifted  := v_elapsed >= v_min_secs;
    v_new_mult := r.price_multiplier;   -- unchanged unless the gated branch below recomputes it

    -- (2) Apply the passive change only when enough time has passed → double-call is a no-op
    --     (idempotent). Pressure decays toward a TARGET: `baseline + danger_term`. The danger term is
    --     0 (target = baseline, the exact 0034 behavior) UNLESS world_balance_enabled — then it rises
    --     with recent DEFEATS at this location (read DOWNWARD from combat_reports history, read-only).
    --     Being a target (not an accumulator) it is self-correcting and stays bounded by the cap below.
    if v_drifted then
      v_danger_term := 0;
      if v_wb_enabled then
        select count(*) into v_defeats
          from combat_reports
          where location_id = r.location_id
            and result = 'defeat'
            and created_at >= now() - make_interval(secs => v_defeat_window);
        v_danger_term := coalesce(v_defeats, 0) * v_defeat_inc;
      end if;
      v_target   := v_baseline + v_danger_term;
      -- Decay a fraction of the gap to target, so it asymptotes and NEVER overshoots
      -- (decay_rate in (0,1]). Active fleets still relieve pressure (can push below target).
      v_decay    := (v_target - v_pressure) * v_decay_rate;
      v_pressure := v_pressure + v_decay - (v_real * v_relief);
      v_pressure := least(v_max, greatest(v_min, v_pressure));

      -- (2b) PRICE DRIFT (0136): the market price multiplier breathes toward a bounded danger premium.
      --      ALL of this runs ONLY when world_balance_enabled — while dark, v_new_mult stays the row's
      --      current value and the column is left untouched (see the UPDATE case), so the tick's output
      --      is byte-identical to pre-slice. Same target-based / self-correcting / clamped philosophy
      --      as pressure. normalized_pressure reuses the SAME baseline/max (no duplicated config).
      if v_wb_enabled then
        v_norm        := least(1, greatest(0, (v_pressure - v_baseline) / nullif(v_max - v_baseline, 0)));
        v_mult_target := 1.0 + v_price_coeff * coalesce(v_norm, 0);
        v_new_mult    := r.price_multiplier + (v_mult_target - r.price_multiplier) * v_price_rate;
        v_new_mult    := least(v_mult_max, greatest(v_mult_min, v_new_mult));
      end if;
    end if;

    -- (3) Danger modifier from pressure — piecewise so baseline maps to exactly
    --     1.0. Bounded both ends. (Unchanged from 0032/0034/0135/0136.)
    if v_pressure >= v_baseline then
      v_mod := 1.0 + ((v_pressure - v_baseline) / nullif(v_max - v_baseline, 0)) * (v_max_mod - 1.0);
    else
      v_mod := v_min_mod + ((v_pressure - v_min) / nullif(v_baseline - v_min, 0)) * (1.0 - v_min_mod);
    end if;
    v_mod := least(v_max_mod, greatest(v_min_mod, coalesce(v_mod, 1.0)));

    update location_state set
      active_fleets    = v_real,
      pressure         = round(v_pressure)::integer,
      danger_modifier  = v_mod,
      -- DARK guarantee: while world_balance_enabled=false the column is left exactly as-is (the 0135
      -- `last_tick_at` self-assign idiom) — no drift math ran, so the multiplier stays 1.0.
      price_multiplier = case when v_wb_enabled then v_new_mult else price_multiplier end,
      last_tick_at     = case when v_drifted then now() else last_tick_at end,
      updated_at       = now()
    where location_id = r.location_id;

    v_count := v_count + 1;
  end loop;

  -- (4) Roll up zone_state from its member locations. (Unchanged from 0032/0034/0135/0136.)
  update zone_state z set
    avg_pressure        = sub.avg_p,
    avg_danger_modifier = sub.avg_d,
    active_fleets       = sub.sum_f,
    last_tick_at        = now(),
    updated_at          = now()
  from (
    select l.zone_id,
           avg(ls.pressure)        as avg_p,
           avg(ls.danger_modifier) as avg_d,
           coalesce(sum(ls.active_fleets), 0) as sum_f
    from location_state ls
    join locations l on l.id = ls.location_id
    group by l.zone_id
  ) sub
  where z.zone_id = sub.zone_id;

  -- (5) FIELD DEPLETION REGEN (0137): worked mining fields slowly recover toward full. DARK/no-op while
  --     world_balance_enabled=false (the whole block is gated — mining_field_state is untouched, so the
  --     tick stays byte-identical to 0136 while dark). Same bounded-target idiom (target = 1.0); only
  --     not-yet-full rows are touched.
  if v_wb_enabled then
    update public.mining_field_state
      set reserve_fraction = least(1.0, reserve_fraction + v_field_regen),
          updated_at = now()
      where reserve_fraction < 1.0;
  end if;

  return v_count;
end;
$$;

-- Re-assert anti-cheat lockdown for the replaced function (the 0034/0135/0136 precedent).
revoke execute on function public.worldstate_tick() from public, anon, authenticated;
grant execute on function public.worldstate_tick() to service_role;

-- ── (f) mining_extract: scale the bundle by the reserve + deplete once per real extraction ─────────
-- EXACTLY the 0104 body EXCEPT one gated block (steps 11.5 + the deplete call), entirely inside
-- `if world_balance_enabled` so mining is byte-identical while dark. The bundle is snapshotted from a
-- new local v_bundle (= the field bundle verbatim, scaled only when enabled), used in BOTH the row
-- insert and the result envelope so the returned pending_bundle matches what is stored.
create or replace function public.mining_extract(
  p_player       uuid,
  p_main_ship_id uuid,
  p_request_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_cmd      constant text := 'mining_extract';
  v_lock     jsonb;
  v_status   text;
  v_owner    uuid;
  v_hash     text;
  v_rcpt     main_ship_space_command_receipts%rowtype;
  v_val      jsonb;
  v_state    text;
  v_excl     jsonb;
  v_x        double precision;
  v_y        double precision;
  v_radius   double precision;
  v_field    mining_fields%rowtype;
  v_cooldown double precision;
  v_last     timestamptz;
  v_retry    integer;
  v_now      timestamptz;
  v_ext_id   uuid;
  v_result   jsonb;
  -- WORLD-BALANCE-P19 (field depletion) locals — used ONLY inside the flag-gated block.
  v_wb       boolean;
  v_reserve  numeric;
  v_bundle   jsonb;
  v_items    jsonb;
begin
  -- 1) DARK GATE FIRST (0097 law / 0070 idiom): while mining_enabled is false, reject
  --    deterministically BEFORE any other read, lock, or write — no ship read, no receipt read,
  --    no field read, no extraction row.
  if not public.cfg_bool('mining_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) S2 canonical lock context (blocking; ship → fleet → coordinate movement → presence)
  v_lock := public.mainship_space_lock_context(p_main_ship_id, false);
  v_status := v_lock->>'status';
  if v_status = 'not_found' then
    return jsonb_build_object('ok', false, 'reason', 'missing_ship');
  elsif v_status <> 'locked' then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_status, 'lock_failed'));
  end if;

  -- 4) ownership from the LOCKED snapshot (never from the client)
  v_owner := (v_lock->'ship'->>'player_id')::uuid;
  if v_owner is distinct from p_player then
    return jsonb_build_object('ok', false, 'reason', 'not_owned');
  end if;

  -- 5) canonical immutable command payload + hash (extract carries NO coordinate body — 0064 stop
  --    idiom, via 0099)
  v_hash := md5(jsonb_build_object('command_type', c_cmd)::text);

  -- 6) idempotency receipt lookup AFTER the ship lock + ownership check (0064 order; reused
  --    mechanism — replay returns the FIRST committed result verbatim). A replay RETURNS HERE, before
  --    any extraction-row insert or depletion below — so a replay never re-scales or double-depletes.
  select * into v_rcpt from main_ship_space_command_receipts
    where main_ship_id = p_main_ship_id and request_id = p_request_id;
  if found then
    if v_rcpt.command_type = c_cmd and v_rcpt.canonical_payload_hash = v_hash then
      return v_rcpt.result_json;
    else
      return jsonb_build_object('ok', false, 'reason', 'request_id_payload_conflict');
    end if;
  end if;

  -- 7) coherent-state validation under the locks; extracting requires a SETTLED in-space ship
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;
  v_state := v_val->>'state';
  if v_state = 'destroyed' then
    return jsonb_build_object('ok', false, 'reason', 'destroyed');
  elsif v_state <> 'in_space' then
    -- in_transit / at_location / home / legacy_* — one truthful reason: not settled in open space
    return jsonb_build_object('ok', false, 'reason', 'not_in_space');
  end if;

  -- 8) cross-domain exclusion (0064 arrival-processor posture, reused): the ship must not be
  --    claimed by a legacy movement / pointer conflict / location presence.
  v_excl := public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id);
  if (v_excl->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_excl->>'reason', 'cross_domain_conflict'));
  end if;

  -- 9) ship position under lock (state = in_space ⇒ coordinates non-null, 0054 invariant)
  select space_x, space_y into v_x, v_y
    from main_ship_instances where main_ship_id = p_main_ship_id;

  -- 10) nearest ACTIVE field within the tunable radius; deterministic tie-break: distance, then
  --     name (0099 rule; NO discovered-filter — extraction is repeatable). Inactive fields are
  --     treated as nonexistent (0103 is_active law).
  v_radius := coalesce(public.cfg_num('mining_extract_radius'), 750);
  select f.* into v_field
    from mining_fields f
    where f.is_active
      and public.osn_distance(v_x, v_y, f.space_x, f.space_y) <= v_radius
    order by public.osn_distance(v_x, v_y, f.space_x, f.space_y) asc, f.name asc
    limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_field_in_range');
  end if;

  -- 11) COOLDOWN (the slice-C deviation; recon decision 2): the latest extraction by this player
  --     from this field must be older than the tunable cooldown. Served by the 0103
  --     (player_id, field_id, created_at desc) index. Failure writes NO receipt (0064 posture),
  --     so retrying the same request_id after the cooldown succeeds.
  v_now := clock_timestamp();
  v_cooldown := coalesce(public.cfg_num('mining_extract_cooldown_seconds'), 300);
  select e.created_at into v_last
    from mining_extractions e
    where e.player_id = p_player and e.field_id = v_field.id
    order by e.created_at desc
    limit 1;
  if found and v_last + make_interval(secs => v_cooldown) > v_now then
    v_retry := ceil(extract(epoch from (v_last + make_interval(secs => v_cooldown) - v_now)))::integer;
    return jsonb_build_object('ok', false, 'reason', 'cooldown',
                              'retry_after_seconds', greatest(v_retry, 1));
  end if;

  -- 11.5) WORLD-BALANCE-P19 FIELD DEPLETION (dark unless world_balance_enabled). ENTIRELY gated so
  --       mining is byte-identical while dark: v_bundle defaults to the field bundle VERBATIM; only
  --       when the flag is on do we scale each item qty by the current reserve (diminishing returns,
  --       per-item floor of 1). reserve is READ (DOWNWARD) BEFORE this extraction's depletion, so the
  --       bundle reflects the pre-extraction reserve. worldstate_field_remaining is itself flag-gated
  --       (returns 1.0 while dark) — defense in depth.
  v_bundle := v_field.reward_bundle_json;
  v_wb := coalesce(public.cfg_bool('world_balance_enabled'), false);
  if v_wb then
    v_reserve := public.worldstate_field_remaining(v_field.id);
    select coalesce(jsonb_agg(
             jsonb_build_object('item_id',  it->>'item_id',
                                'quantity', greatest(1, round((it->>'quantity')::numeric * v_reserve)))
             order by ord), '[]'::jsonb)
      into v_items
      from jsonb_array_elements(v_field.reward_bundle_json->'items') with ordinality as t(it, ord);
    v_bundle := v_field.reward_bundle_json || jsonb_build_object('items', v_items);
  end if;

  -- 12) ACCRUE (never deposit): ONE extraction row per extraction (repeatable — no unique pair,
  --     no ON CONFLICT), snapshotting the (depletion-scaled) bundle onto the activity's own state.
  --     secured_at stays NULL — the slice-D securing processor alone sets it.
  insert into mining_extractions (player_id, field_id, main_ship_id, pending_bundle_json, created_at)
    values (p_player, v_field.id, p_main_ship_id, v_bundle, v_now)
    returning id into v_ext_id;

  -- 12.5) WORLD-BALANCE-P19: deplete the field EXACTLY ONCE per REAL extraction. Placed in the success
  --        path right after the row insert (unreachable on replay — a replay returned at step 6), so no
  --        double-deplete. worldstate_deplete_field is flag-gated (no-op while dark), and this call is
  --        additionally inside `if v_wb` so mining is byte-identical while dark.
  if v_wb then
    perform public.worldstate_deplete_field(v_field.id);
  end if;

  v_result := jsonb_build_object('ok', true,
    'extraction_id', v_ext_id,
    'field_id', v_field.id, 'name', v_field.name,
    'space_x', v_field.space_x, 'space_y', v_field.space_y,
    'pending_bundle', v_bundle,
    'extracted_at', v_now, 'request_id', p_request_id);

  -- 13) finalise the idempotency receipt atomically with the extraction (0064 idiom; extract
  --     creates no movement, so movement_id stays null)
  insert into main_ship_space_command_receipts (
    main_ship_id, player_id, request_id, command_type, canonical_payload_hash,
    outcome_status, result_json, completed_at)
  values (p_main_ship_id, p_player, p_request_id, c_cmd, v_hash, 'success', v_result, v_now);

  return v_result;
end;
$$;

-- Re-assert the private writer ACL (CREATE OR REPLACE keeps it; restated per the 0104 precedent).
revoke execute on function public.mining_extract(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.mining_extract(uuid, uuid, uuid) to service_role;
