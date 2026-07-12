-- Byeharu — EV-1 (FULL_CAPACITY_PLAN §C P8, first slice): the WORLD-EVENTS PRODUCER — `worldstate_tick`
-- NARRATES threshold happenings through the EXISTING sole writer `world_events_publish` (0140):
-- pressure crossings, field-depletion warnings, price-drift extremes — all dedup-keyed per UTC day.
-- EV-2 (event sites) and EV-3 (feed UI) are LATER slices; this migration flips NO flag and adds NO cron.
--
-- GROUNDED IN THE REAL CODE (read first, not guessed):
--   · `worldstate_tick` TRUE HEAD = 0137 (grep-verified: create sites are 0032 → 0034 → 0135 → 0136 →
--     0137 ONLY; 0138..0181 never re-create, alter, or drop it — 0172 re-created `mining_extract` and
--     `worldstate_deplete_field`, NOT the tick). Re-created below VERBATIM from the 0137 body with the
--     marked `EV-1 (0182)` hunks only (parity discipline, plan §E law 2; extract-and-diff verified).
--   · THE TICK'S GATE SHAPE (0135–0137, verified): the tick itself always runs (the pre-Phase-19
--     decay-toward-baseline + zone rollup are UNCONDITIONAL — that is the 0034 live behavior, not a
--     global no-op gate); every Phase-19 dynamic is gated per-block on `v_wb_enabled`
--     (`world_balance_enabled`, committed false). EV-1 follows exactly that shape: EVERY publication
--     sits inside `if v_wb_enabled` (the location events additionally inside the existing `v_drifted`
--     applied-tick guard), so a dark tick publishes ZERO events and stays byte-identical to 0137.
--   · DOUBLE-DARK: `world_events_publish` (0140) itself no-ops (returns NULL before any read/write)
--     while `phase20_polish_enabled=false`. So events flow ONLY when BOTH flags are true — exactly the
--     Rung-7 activation order (§B: flip `world_balance_enabled`, then `phase20_polish_enabled`
--     "together with P8's producer so the feed isn't empty" — this IS that producer).
--   · SEVERITY / TYPE / SCOPE VOCAB (0139 CHECKs, mirrored by the 0140 validation): event_type
--     'world_state' (the "highlight tied to world-state dynamics" — this slice's exact case), severity
--     info/warning/critical, scope location (pressure/drift events target the location) or global
--     (depletion — mining_fields are spatial hidden sites, NOT Map locations, so 'global' is the only
--     truthful scope; the title carries the field NAME only, never coordinates — a mild, deliberate
--     narration reveal: a depleting field is by definition being actively worked).
--   · DEDUP (0140): a non-null dedup_key is exactly-once via the partial unique index — a same-day
--     re-publish returns the EXISTING id and inserts nothing. Keys here:
--       pressure_high:<location_id>:<YYYY-MM-DD>    · pressure_eased:<location_id>:<day>
--       price_surge:<location_id>:<day>             · price_crash:<location_id>:<day>
--       field_depleting:<field_id>:<day>            (day = UTC)
--     EVERY family is STATE-detected (pressure at/above the threshold NOW; multiplier outside the band
--     NOW; reserve thin NOW) — never edge-detected. RATIONALE (hostile-review fix): an edge, once
--     consumed, has ADVANCED even when its publish failed — the event would be lost forever; a STATE
--     still holds next minute, so a failed publish genuinely retries (state persists + per-day dedup =
--     idempotent retry, true for all five families). Consequences, both intended:
--       · a location PARKED above the threshold re-announces once per UTC day — deliberate
--         pressure-nagging [D — owner-tunable via the threshold]; same for a persisting drift extreme
--         or a still-thin field.
--       · 'pressure_eased' is the EXACT complement on the threshold (new pressure < threshold),
--         NOISE-SUPPRESSED by requiring TODAY's `pressure_high:<loc>:<day>` announcement to exist —
--         a perpetually-calm location never "eases" (a bare complement would ease every calm location
--         daily). The suppression is a READ-ONLY lookup of the tick's OWN published rows in
--         `world_events` (a new DOWNWARD read of the leaf's table — acyclic, no write; documented in
--         SYSTEM_BOUNDARIES). The parked-high daily re-announce keeps the same-day pairing coherent
--         across midnight: a still-high location re-announces on the new day, so a later same-day
--         easing still narrates.
--
-- D2 CRON-SAFETY (the tick is the 60s heartbeat — 0033 cron, UNCHANGED here): a publish failure must
-- NEVER abort the tick — and must never take a SIBLING publication down with it. EVERY publication is
-- its OWN begin/exception subtransaction (pressure-high, eased, drift — each isolated per location;
-- depletion — one subtransaction PER FIELD, so one bad field cannot skip the rest of that tick's
-- warnings). `query_canceled` is re-raised (a cancel / statement-timeout is never neutered into a
-- warning); everything else logs a WARNING and the tick (including the location_state UPDATE already
-- made) proceeds. Because every family is STATE-detected, a failed condition still holds next minute →
-- the retry is genuinely idempotent (dedup bounds it to one row). `world_events_publish`'s own
-- idempotency handles the benign-conflict case; the wrappers handle everything else.
--
-- KNOB SAFETY (hostile-review MEDIUM): the four EV-1 knobs are read ONLY inside the `v_wb_enabled`
-- gate (a dark tick performs ZERO EV-1 config reads — the seeded descriptions' "only consumed when
-- world_balance_enabled=true" is literally true) and the reads are GUARDED: a mis-set value (bad cast
-- or NaN — NaN compares as the GREATEST double in Postgres and would silently flip every threshold)
-- falls back to the seeded default with a WARNING, never a raise — stricter than the C2-2 posture
-- because this function IS the live 60s decay/rollup heartbeat and an owner-tunable typo must not
-- kill it.
--
-- NARRATE-NEVER-MUTATE (SYSTEM_BOUNDARIES World-Events charter, restated in the same PR): the tick's
-- ONLY new call is the leaf's OWN sole writer `world_events_publish` — NEVER a direct insert into
-- `world_events` (pinned by self-assert below). World Events stays the downward leaf (writes only
-- `world_events`, never zone_state/location_state/fleets/rewards); World State gains one DOWNWARD CALL
-- edge into that leaf's writer + no new write targets of its own, plus ONE new DOWNWARD read-only
-- edge (the eased noise-suppression lookup of the tick's own published `world_events` rows — never a
-- write). ACYCLIC: World Events never reads or calls World State. The tick's new `locations.name`
-- read is the static-Map read it already performs (the step-4 zone rollup joins `locations`) — no new
-- system edge.
--
-- CONFIG (all NEW, all consumed this slice, all [D] owner-tunable; grounded in the shipped scales):
--   event_pressure_high_threshold='75'   — pressure runs 0..100, baseline 50, max 100 (0031/0032 scale);
--     75 = halfway from baseline to max ≈ a sustained 7-defeat/hour danger target under the 0135 term
--     (50 + 7×4 > 75) — genuinely hot, not everyday noise. Critical cut = threshold + half the
--     remaining headroom (87.5 with defaults) — derived, no extra knob.
--   event_depletion_warn_fraction='0.25' — reserve runs 1.0 → floor 0.1 in 0.1 per-extract steps
--     (0137 knobs); 0.25 ≈ 8 real extractions deep, regen ~0.02/tick — a genuinely worked field.
--   event_drift_extreme_band_low='0.6' / _high='1.4' — the 0136 clamp is [0.5, 2.0], but the DRIFT
--     TARGET is 1.0 + coeff×norm ≤ 1.5 under the shipped coeff 0.5 — so the brief's suggested 1.6 high
--     is UNREACHABLE today; 1.4 (= 80% of the max premium, needs pressure > 90 sustained ~16 ticks) is
--     the grounded "extreme". 0.6 is symmetric defensive cover near the floor (unreachable under the
--     default coeff — the target never goes below 1.0 — but meaningful the moment the owner retunes).
--
-- RETIREMENT / ACTIVATION: no new flag — EV-1 rides the two PERMANENT gates it narrates for
-- (`world_balance_enabled` × `phase20_polish_enabled`, both committed false). Lit-path verification is
-- the Rung-7 activation checklist; the disposable proof (`scripts/ev1-proof.{sql,sh}`, world-events-proof
-- workflow) exercises the lit path transiently inside one rolled-back transaction. Forward-only; edits
-- no shipped migration 0001–0181 (0181 = the merged #117 haul_read_surface — this slice is 0182).

-- ── (a) config: the EV-1 threshold knobs (NEW, consumed this slice; grounded above) ────────────────
insert into public.game_config (key, value, description) values
  ('event_pressure_high_threshold', '75',
   'EV-1 (world events): worldstate_tick publishes a ''pressure_high'' world_state event while a '
   'location''s pressure sits AT/ABOVE this (STATE-detected; 0..100 scale, baseline 50) — dedup one '
   'per (location, UTC day), so a parked-high location re-announces daily (intended pressure-nagging) '
   'and a failed publish retries next tick. ''pressure_eased'' is the exact complement (below this), '
   'suppressed unless TODAY''s pressure_high was announced. Severity: critical at threshold + half the '
   'remaining headroom to worldstate_pressure_max, else warning. Only consumed when '
   'world_balance_enabled=true; events flow only once phase20_polish_enabled is also true.'),
  ('event_depletion_warn_fraction', '0.25',
   'EV-1 (world events): worldstate_tick publishes a ''field_depleting'' warning for each mining field '
   'whose post-regen reserve_fraction sits below this (1.0=full, 0.1=the 0137 floor). Dedup one per '
   '(field, UTC day). Only consumed when world_balance_enabled=true.'),
  ('event_drift_extreme_band_low', '0.6',
   'EV-1 (world events): worldstate_tick publishes a ''price_crash'' warning when a location''s new '
   'price_multiplier is at or below this (the 0136 clamp floor is 0.5). Dedup one per (location, UTC '
   'day). Unreachable under the default drift target (>= 1.0) — defensive symmetric cover, owner-tunable. '
   'Only consumed when world_balance_enabled=true.'),
  ('event_drift_extreme_band_high', '1.4',
   'EV-1 (world events): worldstate_tick publishes a ''price_surge'' warning when a location''s new '
   'price_multiplier is at or above this. Grounded: the 0136 drift target caps at 1.0 + coeff(0.5) = '
   '1.5 under the shipped tuning, so 1.4 = 80 percent of the max premium (needs pressure > 90 sustained). '
   'Dedup one per (location, UTC day). Only consumed when world_balance_enabled=true.')
on conflict (key) do nothing;

-- ── (b) worldstate_tick: EXACTLY the 0137 body except the marked EV-1 narration hunks ──────────────
-- Every unchanged line is byte-for-byte 0137 (the grep-verified true head). Differences: the EV-1
-- declare block (uninitialized locals), the gated+guarded knob loader at the top of the body, the
-- post-UPDATE location-event hunk (pressure state + drift extremes), and the per-field
-- depletion-warning hunk — each fenced by `EV-1 (0182) BEGIN/END` markers and each entirely inside
-- the existing `v_wb_enabled` gate. While dark the tick publishes NOTHING, reads NO EV-1 config, and
-- its writes are byte-identical to 0137.
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
  -- ── EV-1 (0182) BEGIN: threshold-event locals. DELIBERATELY uninitialized: the knob reads are
  --    GATED (only when v_wb_enabled — a dark tick performs zero EV-1 config reads) and GUARDED
  --    (bad cast / NaN → seeded default + WARNING, never a raise) in the loader at the top of the
  --    body — a DECLARE-time cfg_num would run unguarded on every 60s heartbeat, dark included.
  --    world_events_publish additionally self-gates on phase20_polish_enabled → NULL while dark. ────
  v_ev_high     double precision;
  v_ev_crit     double precision;
  v_ev_warn     double precision;
  v_ev_band_lo  double precision;
  v_ev_band_hi  double precision;
  v_ev_day      text;
  v_ev_new_p    integer;
  v_ev_surge    boolean;
  v_ev_crash    boolean;
  v_ev_loc_name text;
  v_ev_dep      record;
  -- ── EV-1 (0182) END ─────────────────────────────────────────────────────────────────────────────
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
  -- ── EV-1 (0182) BEGIN: gated + guarded knob loader (hostile-review MEDIUM). Runs ONCE per tick and
  --    ONLY when world_balance_enabled (a dark tick reads no EV-1 config at all). GUARDED: a bad cast
  --    aborts the subtransaction (→ all four fall back to their seeded defaults, WARNING logged) and
  --    the NaN backstop below catches values that CAST fine but compare as the greatest double —
  --    either way a mis-set owner-tunable can never abort the live 60s heartbeat. query_canceled is
  --    re-raised (a cancel is never neutered).
  if v_wb_enabled then
    begin
      v_ev_high    := coalesce(cfg_num('event_pressure_high_threshold'), 75);
      v_ev_warn    := coalesce(cfg_num('event_depletion_warn_fraction'), 0.25);
      v_ev_band_lo := coalesce(cfg_num('event_drift_extreme_band_low'), 0.6);
      v_ev_band_hi := coalesce(cfg_num('event_drift_extreme_band_high'), 1.4);
    exception
      when query_canceled then raise;
      when others then
        raise warning 'worldstate_tick EV-1: bad event knob value (%) — using the seeded defaults', sqlerrm;
    end;
    if v_ev_high    is null or v_ev_high    = 'NaN'::double precision then v_ev_high    := 75;   end if;
    if v_ev_warn    is null or v_ev_warn    = 'NaN'::double precision then v_ev_warn    := 0.25; end if;
    if v_ev_band_lo is null or v_ev_band_lo = 'NaN'::double precision then v_ev_band_lo := 0.6;  end if;
    if v_ev_band_hi is null or v_ev_band_hi = 'NaN'::double precision then v_ev_band_hi := 1.4;  end if;
    -- critical cut = threshold + half the remaining headroom to the pressure max (derived, no knob).
    v_ev_crit := v_ev_high + (v_max - v_ev_high) / 2;
    v_ev_day  := to_char(now() at time zone 'utc', 'YYYY-MM-DD');
  end if;
  -- ── EV-1 (0182) END ───────────────────────────────────────────────────────────────────────────────
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
    -- ── EV-1 (0182) BEGIN: threshold-event narration — pressure state + drift extremes. ────────────
    --    NARRATES, never mutates (the World-Events charter): the ONLY call is the leaf's OWN sole
    --    writer world_events_publish (NEVER a direct insert), which itself no-ops (NULL) while
    --    phase20_polish_enabled=false. Entirely inside the Phase-19 gate (v_wb_enabled) AND the
    --    applied-tick guard (v_drifted) → a dark tick publishes NOTHING. STATE-detected (never edge):
    --    the condition still holds next minute, so a failed publish genuinely retries and the per-day
    --    dedup bounds every family to once/(subject, UTC day) — a parked-high location re-announces
    --    daily (intended pressure-nagging [D]). D2 cron-safety: EACH publication below is its OWN
    --    begin/exception subtransaction — one failure cannot roll back a sibling's success or abort
    --    the tick (this location's UPDATE above is already outside them); query_canceled re-raised.
    if v_wb_enabled and v_drifted then
      v_ev_new_p := round(v_pressure)::integer;
      v_ev_surge := v_new_mult >= v_ev_band_hi;
      v_ev_crash := v_new_mult <= v_ev_band_lo;
      v_ev_loc_name := null;
      if v_ev_new_p >= v_ev_high then
        -- STATE: at/above the threshold now → announce (once per (location, day) via dedup).
        begin
          select name into v_ev_loc_name from locations where id = r.location_id;
          perform public.world_events_publish(
            'world_state', 'location', null, r.location_id,
            format('Pirate activity surging at %s', v_ev_loc_name),
            format('Danger pressure stands at %s (threshold %s).', v_ev_new_p, round(v_ev_high)),
            case when v_ev_new_p >= v_ev_crit then 'critical' else 'warning' end,
            now(), now() + interval '24 hours',
            format('pressure_high:%s:%s', r.location_id, v_ev_day));
        exception
          when query_canceled then raise;
          when others then
            raise warning 'worldstate_tick EV-1: pressure_high publish failed at % (%) — tick continues',
              r.location_id, sqlerrm;
        end;
      else
        -- STATE: below the threshold now — the EXACT complement — NOISE-SUPPRESSED: narrate only if
        -- TODAY's pressure_high for this location was announced (a read-only lookup of the tick's own
        -- published rows; a perpetually-calm location never "eases").
        begin
          if exists (select 1 from world_events w
                       where w.dedup_key = format('pressure_high:%s:%s', r.location_id, v_ev_day)) then
            select name into v_ev_loc_name from locations where id = r.location_id;
            perform public.world_events_publish(
              'world_state', 'location', null, r.location_id,
              format('Pirate activity easing at %s', v_ev_loc_name),
              format('Danger pressure has fallen back to %s (threshold %s).', v_ev_new_p, round(v_ev_high)),
              'info',
              now(), now() + interval '24 hours',
              format('pressure_eased:%s:%s', r.location_id, v_ev_day));
          end if;
        exception
          when query_canceled then raise;
          when others then
            raise warning 'worldstate_tick EV-1: pressure_eased publish failed at % (%) — tick continues',
              r.location_id, sqlerrm;
        end;
      end if;
      if v_ev_surge or v_ev_crash then
        begin
          if v_ev_loc_name is null then
            select name into v_ev_loc_name from locations where id = r.location_id;
          end if;
          if v_ev_surge then
            perform public.world_events_publish(
              'world_state', 'location', null, r.location_id,
              format('Prices surging at %s', v_ev_loc_name),
              format('The local price multiplier stands at %s.', round(v_new_mult, 2)),
              'warning',
              now(), now() + interval '24 hours',
              format('price_surge:%s:%s', r.location_id, v_ev_day));
          else
            perform public.world_events_publish(
              'world_state', 'location', null, r.location_id,
              format('Prices crashing at %s', v_ev_loc_name),
              format('The local price multiplier has fallen to %s.', round(v_new_mult, 2)),
              'warning',
              now(), now() + interval '24 hours',
              format('price_crash:%s:%s', r.location_id, v_ev_day));
          end if;
        exception
          when query_canceled then raise;
          when others then
            raise warning 'worldstate_tick EV-1: drift publish failed at % (%) — tick continues',
              r.location_id, sqlerrm;
        end;
      end if;
    end if;
    -- ── EV-1 (0182) END ─────────────────────────────────────────────────────────────────────────────

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
  -- ── EV-1 (0182) BEGIN: depletion warnings — fields whose POST-regen reserve sits below the warn
  --    fraction narrate once per (field, UTC day). STATE-detected (still thin next minute → a failed
  --    publish genuinely retries; dedup bounds it to one row/day). Same publish-only / double-dark
  --    posture as the location events; inside the SAME v_wb_enabled gate as the (5) regen pass. D2:
  --    one begin/exception subtransaction PER FIELD — one bad field cannot skip the rest of that
  --    tick's warnings or abort the tick; query_canceled re-raised. Scope 'global': mining_fields are
  --    spatial hidden sites, not Map locations — the title carries the field NAME only (never
  --    coordinates); a depleting field is by definition actively worked.
  if v_wb_enabled then
    for v_ev_dep in
      select s.field_id, f.name, s.reserve_fraction
        from mining_field_state s
        join mining_fields f on f.id = s.field_id
        where s.reserve_fraction < v_ev_warn
    loop
      begin
        perform public.world_events_publish(
          'world_state', 'global', null, null,
          format('%s is running thin', v_ev_dep.name),
          format('Estimated reserves down to %s%% — yields are dropping until it recovers.',
                 round(v_ev_dep.reserve_fraction * 100)),
          'warning',
          now(), now() + interval '24 hours',
          format('field_depleting:%s:%s', v_ev_dep.field_id, v_ev_day));
      exception
        when query_canceled then raise;
        when others then
          raise warning 'worldstate_tick EV-1: depletion publish failed for field % (%) — tick continues',
            v_ev_dep.field_id, sqlerrm;
      end;
    end loop;
  end if;
  -- ── EV-1 (0182) END ───────────────────────────────────────────────────────────────────────────────

  return v_count;
end;
$$;

-- Re-assert anti-cheat lockdown for the replaced function (the 0034/0135/0136/0137 precedent).
revoke execute on function public.worldstate_tick() from public, anon, authenticated;
grant execute on function public.worldstate_tick() to service_role;

-- ── (c) self-asserts: knobs · flags dark · parity spot-pins · publish-only · dark dry-run · cron ────
do $$
declare
  v_src   text;
  v_n     integer;
  v_probe uuid;
begin
  -- 1) knobs seeded with the grounded values (all four are NEW keys — first apply must see the seeds).
  if coalesce(public.cfg_num('event_pressure_high_threshold'), -1) <> 75 then
    raise exception 'EV-1 self-assert: event_pressure_high_threshold not 75';
  end if;
  if coalesce(public.cfg_num('event_depletion_warn_fraction'), -1) <> 0.25 then
    raise exception 'EV-1 self-assert: event_depletion_warn_fraction not 0.25';
  end if;
  if coalesce(public.cfg_num('event_drift_extreme_band_low'), -1) <> 0.6
     or coalesce(public.cfg_num('event_drift_extreme_band_high'), -1) <> 1.4 then
    raise exception 'EV-1 self-assert: drift extreme band not 0.6/1.4';
  end if;

  -- 2) BOTH gates still dark (this slice must land dark; a lit-early deploy fails closed here,
  --    forcing a human decision — the 0180 precedent).
  if public.cfg_bool('world_balance_enabled') then
    raise exception 'EV-1 self-assert: world_balance_enabled is already true — deploy order violated';
  end if;
  if public.cfg_bool('phase20_polish_enabled') then
    raise exception 'EV-1 self-assert: phase20_polish_enabled is already true — deploy order violated';
  end if;

  -- 3) parity spot-pins on the shipped tick body: every head feature survived the re-create
  --    (the 0143/0146 stale-copy failure class), and the EV-1 hunks are exactly as designed.
  select prosrc into v_src from pg_proc
    where oid = 'public.worldstate_tick()'::regprocedure;
  if v_src is null then raise exception 'EV-1 self-assert: worldstate_tick missing'; end if;
  -- 0135 danger term · 0136 drift · 0137 regen · 0032 lock idiom all still present:
  if v_src not like '%world_balance_defeat_window_seconds%'
     or v_src not like '%world_balance_price_drift_rate%'
     or v_src not like '%world_balance_field_regen_rate%'
     or v_src not like '%for update skip locked%'
     or v_src not like '%zone_state%' then
    raise exception 'EV-1 self-assert: a 0135/0136/0137 head feature is missing from the tick (stale-copy?)';
  end if;
  -- EV-1 pins: exactly 5 publish call sites, all 5 dedup families, per-publication isolation (5
  -- guards: the knob loader + pressure_high + pressure_eased + drift + per-field depletion), each
  -- guard passing cancels through (5 query_canceled re-raises), fenced hunks.
  v_n := (length(v_src) - length(replace(v_src, 'world_events_publish(', ''))) / length('world_events_publish(');
  if v_n <> 5 then
    raise exception 'EV-1 self-assert: expected exactly 5 world_events_publish call sites, found %', v_n;
  end if;
  if v_src not like '%pressure_high:%'  or v_src not like '%pressure_eased:%'
     or v_src not like '%price_surge:%' or v_src not like '%price_crash:%'
     or v_src not like '%field_depleting:%' then
    raise exception 'EV-1 self-assert: a dedup-key family is missing from the tick';
  end if;
  v_n := (length(v_src) - length(replace(v_src, 'when others then', ''))) / length('when others then');
  if v_n <> 5 then
    raise exception 'EV-1 self-assert: expected exactly 5 failure guards (loader + 3 location + per-field depletion), found %', v_n;
  end if;
  v_n := (length(v_src) - length(replace(v_src, 'when query_canceled then raise;', ''))) / length('when query_canceled then raise;');
  if v_n <> 5 then
    raise exception 'EV-1 self-assert: expected every guard to re-raise query_canceled (5), found %', v_n;
  end if;
  -- NARRATE-NEVER-MUTATE pin: the tick NEVER inserts world_events directly (publish-only law).
  if v_src ~* 'insert\s+into\s+(public\.)?world_events' then
    raise exception 'EV-1 self-assert: the tick inserts world_events directly (must go through world_events_publish)';
  end if;

  -- 4) DARK DRY-RUN: with both flags false, a real tick publishes ZERO events (the tick already runs
  --    every 60s via the 0033 cron, so one in-migration run is the production steady state), and the
  --    publisher itself no-ops (NULL) — the double-dark proof.
  perform public.worldstate_tick();
  select count(*) into v_n from public.world_events
    where dedup_key ~ '^(pressure_high|pressure_eased|price_surge|price_crash|field_depleting):';
  if v_n <> 0 then
    raise exception 'EV-1 self-assert: dark tick published % event(s)', v_n;
  end if;
  v_probe := public.world_events_publish('world_state', 'global', null, null,
               'EV-1 dark probe', null, 'info', now(), null, 'ev1:selfassert:probe');
  if v_probe is not null then
    raise exception 'EV-1 self-assert: world_events_publish returned an id while phase20_polish_enabled=false';
  end if;

  -- 5) CRON UNCHANGED: this slice adds NO cron — the existing 0033 every-minute heartbeat is the sole
  --    schedule driving the tick, exactly as shipped.
  select count(*) into v_n from cron.job
    where jobname = 'process-location-state-ticks' and schedule = '* * * * *';
  if v_n <> 1 then
    raise exception 'EV-1 self-assert: expected the one 0033 process-location-state-ticks cron job, found %', v_n;
  end if;
  select count(*) into v_n from cron.job
    where command ilike '%worldstate_tick%' or command ilike '%process_location_state_ticks%';
  if v_n <> 1 then
    raise exception 'EV-1 self-assert: unexpected extra cron schedule drives the tick (%)', v_n;
  end if;

  raise notice 'EV-1 (0182) self-asserts passed: knobs seeded; both gates dark; parity spot-pins + 5 publish sites + 2 guards; dark dry-run published zero events; cron unchanged.';
end $$;

-- No flag is flipped; both gates stay false. Forward-only; edits no shipped migration 0001–0181.
