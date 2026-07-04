-- Byeharu — WORLD-BALANCE-P19 SLICE 1: PIRATE PRESSURE (dark-gated; wires the defeat_pressure seam).
--
-- Phase 19 "World balance / living economy (pirate pressure, price drift, field depletion) —
-- world-state owns world-state" (ROADMAP :94). First mechanic: PIRATE PRESSURE. It is NOT a new
-- system and NOT a new pressure column — it is a LIVING reaction on the EXISTING `location_state`
-- pressure field, delivered by EXTENDING the one World State writer `worldstate_tick()`. This finally
-- WIRES the long-standing `-- defeat_pressure TODO (M5+): add recent-defeat reads from combat_reports`
-- seam left in the tick since 0032, reusing that migration's already-seeded (currently-unwired)
-- `worldstate_pressure_defeat_increase` key rather than inventing a parallel dynamic.
--
-- DARK POSTURE (the 0097/0102/0107/0117/0124/0127/0132 slice-0 flag idiom):
--   · ONE new master flag `world_balance_enabled` seeded 'false' — the Phase-19 gate. It is CONSUMED
--     THIS slice by the tick (not a dead flag): the danger term is gated on it.
--   · BYTE-IDENTICAL WHILE DARK. The existing decay-toward-baseline is preserved EXACTLY as the
--     unconditional path; the new dynamic is purely ADDITIVE and flag-gated. Concretely the tick's
--     decay TARGET becomes `baseline + danger_term`, where `danger_term = 0` unless
--     `cfg_bool('world_balance_enabled')` is true. With the flag false: `danger_term = 0` → target
--     reduces to `baseline` → the decay expression `(baseline - pressure) * decay_rate` is the exact
--     0034 body, and `combat_reports` is NOT read at all (the read is inside the enabled branch). So a
--     dark tick's output is identical to today's: self-correcting toward baseline, no accumulation,
--     bounded by the SAME `least(v_max, greatest(v_min, …))` cap (pressure can never exceed the max).
--
-- THE DANGER TERM (only when the flag is on):
--   danger_term(loc) = defeats_in_window(loc) * worldstate_pressure_defeat_increase
--   defeats_in_window(loc) = count of `combat_reports` for THIS location with result = 'defeat' and
--     created_at within `world_balance_defeat_window_seconds` (NEW tunable, seeded '3600' = a one-hour
--     danger memory, consumed this slice). Attribution key: `combat_reports.location_id` — VERIFIED
--     from the real schema (0016:11, `location_id uuid references public.locations (id)`), so a defeat
--     joins directly to its `location_state` row (`combat_reports.location_id = location_state.location_id`).
--     Only DEFEATS raise pressure — `result = 'defeat'` (0032 sets `status='defeat'` on fleet loss;
--     `report_create` copies status → `combat_reports.result`, 0016:66). Victories/escapes/completions
--     are NOT counted. Because it is a decay TARGET (not an accumulator) it is self-correcting: once the
--     defeats age out of the window the target falls back to baseline and pressure decays back down —
--     no runaway, and the existing cap still bounds it.
--
-- OWNERSHIP / BOUNDARIES (docs/SYSTEM_BOUNDARIES.md, synced SAME step):
--   · World State stays the SOLE writer of `location_state`/`zone_state`; it still NEVER writes
--     fleets/combat/rewards. The ONLY new cross-system access is a DOWNWARD READ-ONLY edge
--     World State → Report (`worldstate_tick()` reads `combat_reports`, history only). ACYCLIC: Report
--     writes only `combat_reports` and calls nothing (0016), so it cannot call back into World State —
--     no cycle, no two-way dependency. This is the exact posture as Combat's pre-existing downward READ
--     of `location_state.danger_modifier` (0032), just in the other direction into history.
--   · No new table, no new column, no new cron (the existing 60s `process_location_state_ticks()` →
--     `worldstate_tick()` path is reused verbatim). No shipped migration edited (forward-only, 0135).
--   · The whole dynamic is DARK/no-op while `world_balance_enabled='false'`; the cron still fires but
--     the tick behaves exactly as it does pre-slice. This migration does NOT flip the flag true.
--
-- RETIREMENT / ACTIVATION: `world_balance_enabled` is a permanent capability gate (the Phase-19
-- master flag), not a transitional shim — it retires only when the human owner activates Phase 19.
-- Lit-path verification (flag on a DEV DB → seed a defeat report → tick → pressure rises toward
-- baseline+term, bounded; age it out → decays back) is deferred to the human's activation checklist;
-- nothing here runs a lit/production path.

-- ── (a) config: the dark master flag (NEW) + the defeat-window tunable (NEW, consumed this slice) ──
-- `worldstate_pressure_defeat_increase` is REUSED from 0032 and deliberately NOT re-seeded here.
insert into public.game_config (key, value, description) values
  ('world_balance_enabled', 'false',
   'WORLD-BALANCE-P19: server-authoritative dark master gate for the Phase-19 living-economy dynamics '
   '(pirate pressure now; price drift / field depletion later). OFF until the owner activates. While '
   'false, worldstate_tick() adds a ZERO danger term, so pressure behaves exactly as the pre-Phase-19 '
   'decay-toward-baseline (no accumulation, bounded by the existing cap); combat_reports is not even '
   'read. Every future Phase-19 dynamic must gate on this FIRST and no-op while false.'),
  ('world_balance_defeat_window_seconds', '3600',
   'WORLD-BALANCE-P19 (pirate pressure): the rolling danger-memory window. worldstate_tick() counts '
   'combat_reports with result=''defeat'' at a location within this many seconds and raises that '
   'location''s decay target by count * worldstate_pressure_defeat_increase (the 0032 key, reused). '
   'One hour of memory; self-correcting as defeats age out. Only consumed when world_balance_enabled=true.')
on conflict (key) do nothing;

-- ── (b) worldstate_tick: EXACTLY 0034 except the decay TARGET gains a flag-gated danger term ───────
-- Every unchanged line below is byte-for-byte the 0034 body. The ONLY differences: three new locals
-- (v_wb_enabled, v_defeat_inc, v_defeat_window, v_defeats, v_danger_term, v_target) and the drift
-- branch computing a gated `v_target = baseline + danger_term` in place of a hardcoded baseline.
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
  -- Phase-19 pirate pressure (dark unless world_balance_enabled). Resolved once per tick.
  v_wb_enabled    boolean          := coalesce(cfg_bool('world_balance_enabled'), false);
  v_defeat_inc    double precision := coalesce(cfg_num('worldstate_pressure_defeat_increase'), 4);      -- reused 0032 key
  v_defeat_window double precision := coalesce(cfg_num('world_balance_defeat_window_seconds'), 3600);   -- new tunable
  r            location_state%rowtype;
  v_real       integer;
  v_elapsed    double precision;
  v_drifted    boolean;
  v_pressure   double precision;
  v_decay      double precision;
  v_defeats    integer;
  v_danger_term double precision;
  v_target     double precision;
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
    end if;

    -- (3) Danger modifier from pressure — piecewise so baseline maps to exactly
    --     1.0. Bounded both ends. (Unchanged from 0032/0034.)
    if v_pressure >= v_baseline then
      v_mod := 1.0 + ((v_pressure - v_baseline) / nullif(v_max - v_baseline, 0)) * (v_max_mod - 1.0);
    else
      v_mod := v_min_mod + ((v_pressure - v_min) / nullif(v_baseline - v_min, 0)) * (1.0 - v_min_mod);
    end if;
    v_mod := least(v_max_mod, greatest(v_min_mod, coalesce(v_mod, 1.0)));

    update location_state set
      active_fleets   = v_real,
      pressure        = round(v_pressure)::integer,
      danger_modifier = v_mod,
      last_tick_at    = case when v_drifted then now() else last_tick_at end,
      updated_at      = now()
    where location_id = r.location_id;

    v_count := v_count + 1;
  end loop;

  -- (4) Roll up zone_state from its member locations. (Unchanged from 0032/0034.)
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

  return v_count;
end;
$$;

-- Re-assert anti-cheat lockdown for the replaced function (CREATE OR REPLACE keeps the prior ACL, but
-- we re-state it to be safe — the 0034 precedent). Server/cron + the service-role test runner only;
-- never clients. No new grant surface (the new combat_reports read is internal to the tick).
revoke execute on function public.worldstate_tick() from public, anon, authenticated;
grant execute on function public.worldstate_tick() to service_role;
