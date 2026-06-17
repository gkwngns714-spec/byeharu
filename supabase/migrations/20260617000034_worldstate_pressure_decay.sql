-- Byeharu — M5 balance correction (follow-up #3, Option A): pressure DECAY toward
-- baseline.
--
-- Problem: the original worldstate_tick drifted pressure UP +drift/tick unconditionally,
-- so with no players every pirate_hunt location climbed to 100 / Severe and punished
-- new players. Fix: passive pressure now DECAYS toward baseline (unattended → returns
-- to NORMAL, danger_modifier 1.0). Active fleets still relieve pressure (can push below
-- baseline = hunting clears the area); future defeat/event pressure can still raise it
-- above baseline (defeat_pressure remains a TODO, unwired here).
--
-- SCOPE: World State only. No new columns/tables, no newbie-zones, no combat/reward/
-- fleet/presence changes. World State stays sole writer of location_state/zone_state;
-- combat still only READS danger_modifier; presence stays the source of truth;
-- active_fleets stays a reconciled cache; cron stays process_location_state_ticks →
-- worldstate_tick. danger_modifier mapping is unchanged (baseline 50 → exactly 1.0).

-- ── Config: decay rate (fraction of the gap to baseline closed each tick) ─────
insert into public.game_config (key, value, description) values
  ('worldstate_pressure_decay_rate', '0.1', 'fraction of the gap to baseline that pressure decays each tick (Option A; 0<rate<=1, no overshoot)')
on conflict (key) do nothing;

-- ── worldstate_tick: same as 0032 except passive drift-up → decay-toward-baseline ─
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
  r            location_state%rowtype;
  v_real       integer;
  v_elapsed    double precision;
  v_drifted    boolean;
  v_pressure   double precision;
  v_decay      double precision;
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

    -- (2) Apply the passive change only when enough time has passed → double-call
    --     is a no-op (idempotent).
    if v_drifted then
      -- Pressure DECAYS toward baseline: step is a fraction of the gap, so it
      -- asymptotes to baseline and NEVER overshoots (decay_rate in (0,1]). Active
      -- fleets still relieve pressure (can push below baseline). Future
      -- defeat_pressure (TODO) would add a +term to raise pressure above baseline.
      v_decay    := (v_baseline - v_pressure) * v_decay_rate;
      v_pressure := v_pressure + v_decay - (v_real * v_relief);
      v_pressure := least(v_max, greatest(v_min, v_pressure));
    end if;

    -- (3) Danger modifier from pressure — piecewise so baseline maps to exactly
    --     1.0. Bounded both ends. (Unchanged from 0032.)
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

  -- (4) Roll up zone_state from its member locations. (Unchanged from 0032.)
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

-- Re-assert anti-cheat lockdown for the replaced function (CREATE OR REPLACE keeps
-- the prior ACL, but we re-state it explicitly to be safe). Server/cron + the
-- service-role test runner only; never clients.
revoke execute on function public.worldstate_tick() from public, anon, authenticated;
grant execute on function public.worldstate_tick() to service_role;
