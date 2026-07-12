-- EV-1 WORLD-EVENTS — disposable REAL-CHAIN proof (runs on the actual chain 0001..0182 in a throwaway
-- Supabase). Proves the 0182 producer: the dark posture (dark tick → ZERO events; the publisher no-ops),
-- STATE-detected pressure events (warning + critical severities; eased = the exact complement,
-- noise-suppressed unless TODAY's high was announced — a never-high location never "eases"), depletion
-- warnings (via the REAL writer worldstate_deplete_field, never a direct reserve write), drift extremes
-- (surge + crash), the per-(subject, UTC day) dedup pin (a same-day still-high re-tick inserts
-- NOTHING), the D2 publish-failure law (an injected world_events insert failure is swallowed — the
-- tick completes, its location_state write survives, and because detection is STATE-based the very
-- next tick genuinely RETRIES and lands the event), the gated+guarded knob loader (an uncastable OR
-- NaN owner-tunable falls back to the seeded default with the tick alive), and NARRATE-NEVER-MUTATE
-- (publication changes no location_state / mining_field_state byte).
-- The ENTIRE proof runs inside ONE transaction that ROLLBACKs — it persists NO event, state row, config
-- value, or flag flip. No production access. No COMMIT anywhere.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness enables world_balance_enabled + phase20_polish_enabled ONLY inside this rolled-back
-- transaction (AFTER proving the dark posture); the ROLLBACK reverts them, so the committed/production
-- flags stay false. It transiently tunes the WORLD-STATE-OWNED knobs the tick already consumes
-- (worldstate_pressure_baseline / worldstate_pressure_decay_rate) to drive the REAL decay math onto the
-- crossings deterministically, and writes fixture pressure/multiplier values onto location_state rows
-- (the tm1/sv1 direct-fixture precedent — transient, rolled back). Depletion state is driven ONLY via
-- the real sole writer worldstate_deplete_field; world_events is written ONLY via the tick /
-- world_events_publish — this harness NEVER inserts into world_events directly.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table ev1(k text primary key, v uuid) on commit preserve rows;

-- seven fixture locations (deterministic pick over the seeded location_state rows) + one mining field.
insert into ev1
  select 'loc' || chr(64 + rn::int), location_id
  from (select location_id, row_number() over (order by location_id) rn from public.location_state) s
  where rn <= 7;
insert into ev1 select 'field', id from public.mining_fields order by name limit 1;
do $$
begin
  if (select count(*) from ev1) <> 8 then
    raise exception 'SETUP FAIL: expected 7 location_state fixtures + 1 mining field, got %', (select count(*) from ev1);
  end if;
end $$;

-- the same UTC-day token the tick uses in every dedup key.
create or replace function pg_temp.ev1_day() returns text language sql stable
  as $$ select to_char(now() at time zone 'utc', 'YYYY-MM-DD') $$;

-- freeze helper: park EVERY location_state row at last_tick_at=now() so v_drifted is false everywhere;
-- each phase then ages ONLY its fixture rows (elapsed >= worldstate_min_tick_seconds) — deterministic,
-- single-subject ticks with zero bystander noise.
create or replace function pg_temp.ev1_freeze() returns void language sql
  as $$ update public.location_state set last_tick_at = now() $$;

-- ════════ P0 — DARK: both flags false → a real tick publishes NOTHING; the publisher no-ops. ════════
do $$
declare v_n int; v_probe uuid; v_a uuid := (select v from ev1 where k='locA');
begin
  -- knobs landed with the 0182 grounded seeds.
  if coalesce(public.cfg_num('event_pressure_high_threshold'), -1) <> 75
     or coalesce(public.cfg_num('event_depletion_warn_fraction'), -1) <> 0.25
     or coalesce(public.cfg_num('event_drift_extreme_band_low'), -1) <> 0.6
     or coalesce(public.cfg_num('event_drift_extreme_band_high'), -1) <> 1.4 then
    raise exception 'P0 FAIL: EV-1 knobs not at the 0182 seeds';
  end if;
  if public.cfg_bool('world_balance_enabled') or public.cfg_bool('phase20_polish_enabled') then
    raise exception 'P0 FAIL: a gate flag is committed true on the disposable chain';
  end if;

  -- age one location with an above-threshold-worthy fixture; dark tick must still publish zero.
  perform pg_temp.ev1_freeze();
  update public.location_state set pressure = 74, last_tick_at = now() - interval '10 minutes'
    where location_id = v_a;
  perform public.worldstate_tick();
  select count(*) into v_n from public.world_events;
  if v_n <> 0 then raise exception 'P0 FAIL: dark tick left % world_events row(s)', v_n; end if;

  -- the publisher itself no-ops (NULL) while phase20_polish_enabled=false — the double-dark arm.
  v_probe := public.world_events_publish('world_state','global',null,null,'ev1 dark probe',null,
                                         'info', now(), null, 'ev1:proof:darkprobe');
  if v_probe is not null then raise exception 'P0 FAIL: publish returned an id while dark'; end if;
  select count(*) into v_n from public.world_events;
  if v_n <> 0 then raise exception 'P0 FAIL: dark publish wrote a row'; end if;

  raise notice 'EV1_PASS_DARK ok: dark tick + dark publish -> zero world_events rows (double-dark posture)';
end $$;

-- enable the two dark gates ONLY inside this rolled-back txn (production flags stay false after ROLLBACK).
update public.game_config set value='true'::jsonb where key='world_balance_enabled';
update public.game_config set value='true'::jsonb where key='phase20_polish_enabled';
-- deterministic decay for the fixtures: one applied tick lands pressure exactly ON the decay target.
update public.game_config set value='1.0'::jsonb where key='worldstate_pressure_decay_rate';

-- ════════ P1 — PRESSURE HIGH (STATE-detected): at/above the threshold -> warning; deep -> critical. ════════
do $$
declare v_a uuid := (select v from ev1 where k='locA'); v_b uuid := (select v from ev1 where k='locB');
        v_n int; v_p int;
begin
  -- (a) WARNING: locA 60 -> decay target 80 (transient baseline; the REAL 0135 target math) >= 75 NOW.
  update public.game_config set value='80'::jsonb where key='worldstate_pressure_baseline';
  perform pg_temp.ev1_freeze();
  update public.location_state set pressure = 60, last_tick_at = now() - interval '10 minutes'
    where location_id = v_a;
  perform public.worldstate_tick();
  select pressure into v_p from public.location_state where location_id = v_a;
  if v_p <> 80 then raise exception 'P1 FAIL: locA pressure % (want 80)', v_p; end if;
  select count(*) into v_n from public.world_events
    where dedup_key = format('pressure_high:%s:%s', v_a, pg_temp.ev1_day())
      and event_type='world_state' and scope='location' and location_id=v_a and zone_id is null
      and severity='warning' and is_active and ends_at is not null;
  if v_n <> 1 then raise exception 'P1 FAIL: pressure_high warning event for locA not published exactly once (%)', v_n; end if;

  -- (b) CRITICAL: locB 60 -> target 92 >= 75 + (100-75)/2 = 87.5 -> severity critical.
  update public.game_config set value='92'::jsonb where key='worldstate_pressure_baseline';
  perform pg_temp.ev1_freeze();
  update public.location_state set pressure = 60, last_tick_at = now() - interval '10 minutes'
    where location_id = v_b;
  perform public.worldstate_tick();
  select count(*) into v_n from public.world_events
    where dedup_key = format('pressure_high:%s:%s', v_b, pg_temp.ev1_day())
      and severity='critical' and scope='location' and location_id=v_b;
  if v_n <> 1 then raise exception 'P1 FAIL: pressure_high critical event for locB not published (%)', v_n; end if;

  -- exactly the two pressure events exist — no bystander location narrated (the freeze held).
  select count(*) into v_n from public.world_events;
  if v_n <> 2 then raise exception 'P1 FAIL: expected exactly 2 events after P1, got %', v_n; end if;
  raise notice 'EV1_PASS_PRESSURE_HIGH ok: state 80 >= 75 warning; 92 critical (>= 87.5 cut); no bystander events';
end $$;

-- ════════ P2 — EASED (exact complement + suppression): locA falls below -> ONE info event; a
-- ════════        never-high location below the threshold publishes NOTHING (noise suppression).
do $$
declare v_a uuid := (select v from ev1 where k='locA'); v_c uuid := (select v from ev1 where k='locC');
        v_n int; v_p int;
begin
  update public.game_config set value='50'::jsonb where key='worldstate_pressure_baseline';  -- restore
  perform pg_temp.ev1_freeze();
  update public.location_state set last_tick_at = now() - interval '10 minutes' where location_id = v_a;
  -- locC never announced high today: below the threshold it must stay SILENT (suppressed).
  update public.location_state set last_tick_at = now() - interval '10 minutes' where location_id = v_c;
  perform public.worldstate_tick();
  select pressure into v_p from public.location_state where location_id = v_a;
  if v_p <> 50 then raise exception 'P2 FAIL: locA pressure % (want 50)', v_p; end if;
  select count(*) into v_n from public.world_events
    where dedup_key = format('pressure_eased:%s:%s', v_a, pg_temp.ev1_day())
      and event_type='world_state' and scope='location' and location_id=v_a and severity='info';
  if v_n <> 1 then raise exception 'P2 FAIL: pressure_eased event not published exactly once (%)', v_n; end if;
  select count(*) into v_n from public.world_events
    where dedup_key = format('pressure_eased:%s:%s', v_c, pg_temp.ev1_day());
  if v_n <> 0 then raise exception 'P2 FAIL: a never-high location eased (suppression broken)'; end if;
  raise notice 'EV1_PASS_PRESSURE_EASED ok: 80->50 with today''s high announced -> one info event; never-high locC below threshold -> suppressed, zero events';
end $$;

-- ════════ P3 — DEDUP PIN: a SAME-DAY still/again-high tick publishes NOTHING new (exactly-once). ════════
do $$
declare v_a uuid := (select v from ev1 where k='locA'); v_n int; v_total0 int; v_total1 int;
begin
  select count(*) into v_total0 from public.world_events;
  update public.game_config set value='80'::jsonb where key='worldstate_pressure_baseline';
  perform pg_temp.ev1_freeze();
  update public.location_state set last_tick_at = now() - interval '10 minutes' where location_id = v_a;
  perform public.worldstate_tick();  -- locA 50 -> 80: at/above 75 AGAIN, same UTC day -> dedup holds
  update public.game_config set value='50'::jsonb where key='worldstate_pressure_baseline';  -- restore
  select count(*) into v_n from public.world_events
    where dedup_key = format('pressure_high:%s:%s', v_a, pg_temp.ev1_day());
  if v_n <> 1 then raise exception 'P3 FAIL: same-day re-announce duplicated the pressure_high event (%)', v_n; end if;
  select count(*) into v_total1 from public.world_events;
  if v_total1 <> v_total0 then raise exception 'P3 FAIL: same-day re-announce grew world_events % -> %', v_total0, v_total1; end if;
  raise notice 'EV1_PASS_DEDUP ok: same-day still-high re-tick -> zero new rows (state-detected + dedup_key exactly-once; next-day re-announce is the intended pressure-nagging)';
end $$;

-- ════════ P4 — DEPLETION: the REAL writer draws the reserve down; the tick warns once per day. ════════
do $$
declare v_f uuid := (select v from ev1 where k='field'); v_r numeric; v_n int; v_total0 int; i int;
begin
  -- 8 real extractions' worth of depletion via the SOLE reserve writer (flag is on inside this txn).
  for i in 1..8 loop
    perform public.worldstate_deplete_field(v_f);
  end loop;
  select reserve_fraction into v_r from public.mining_field_state where field_id = v_f;
  if v_r is null or v_r > 0.25 or v_r < 0.15 then
    raise exception 'P4 FAIL: reserve after 8 depletes = % (want ~0.2)', v_r;
  end if;

  perform pg_temp.ev1_freeze();     -- no location drifts; this tick only regens + narrates depletion
  perform public.worldstate_tick();
  select reserve_fraction into v_r from public.mining_field_state where field_id = v_f;
  if v_r > 0.25 then raise exception 'P4 FAIL: post-regen reserve % not below the warn fraction', v_r; end if;
  select count(*) into v_n from public.world_events
    where dedup_key = format('field_depleting:%s:%s', v_f, pg_temp.ev1_day())
      and event_type='world_state' and scope='global' and zone_id is null and location_id is null
      and severity='warning'
      and title like '%' || (select name from public.mining_fields where id = v_f) || '%';
  if v_n <> 1 then raise exception 'P4 FAIL: field_depleting event not published exactly once (%)', v_n; end if;

  -- a second same-day tick regens again but must NOT duplicate the warning (dedup, state-detected).
  select count(*) into v_total0 from public.world_events;
  perform pg_temp.ev1_freeze();
  perform public.worldstate_tick();
  if (select count(*) from public.world_events) <> v_total0 then
    raise exception 'P4 FAIL: second same-day tick duplicated the depletion warning';
  end if;
  raise notice 'EV1_PASS_DEPLETION ok: reserve drawn to % via worldstate_deplete_field; one global warning named the field; same-day re-tick deduped', v_r;
end $$;

-- ════════ P5 — DRIFT EXTREMES: multiplier outside the 0.6/1.4 band -> surge / crash warnings. ════════
do $$
declare v_c uuid := (select v from ev1 where k='locC'); v_d uuid := (select v from ev1 where k='locD');
        v_n int; v_m numeric;
begin
  perform pg_temp.ev1_freeze();
  -- fixture extremes (transient World-State-owned rows): the tick's OWN drift math then recomputes
  -- them toward target 1.0 — locC 1.45 -> 1.405 (still >= 1.4), locD 0.52 -> ~0.568 (still <= 0.6).
  update public.location_state set pressure = 60, price_multiplier = 1.45,
         last_tick_at = now() - interval '10 minutes' where location_id = v_c;
  update public.location_state set pressure = 50, price_multiplier = 0.52,
         last_tick_at = now() - interval '10 minutes' where location_id = v_d;
  perform public.worldstate_tick();

  select price_multiplier into v_m from public.location_state where location_id = v_c;
  if v_m < 1.4 then raise exception 'P5 FAIL: locC multiplier % fell below the band', v_m; end if;
  select count(*) into v_n from public.world_events
    where dedup_key = format('price_surge:%s:%s', v_c, pg_temp.ev1_day())
      and event_type='world_state' and scope='location' and location_id=v_c and severity='warning';
  if v_n <> 1 then raise exception 'P5 FAIL: price_surge event not published exactly once (%)', v_n; end if;

  select price_multiplier into v_m from public.location_state where location_id = v_d;
  if v_m > 0.6 then raise exception 'P5 FAIL: locD multiplier % rose above the band', v_m; end if;
  select count(*) into v_n from public.world_events
    where dedup_key = format('price_crash:%s:%s', v_d, pg_temp.ev1_day())
      and scope='location' and location_id=v_d and severity='warning';
  if v_n <> 1 then raise exception 'P5 FAIL: price_crash event not published exactly once (%)', v_n; end if;
  raise notice 'EV1_PASS_DRIFT ok: multiplier 1.405 >= 1.4 -> price_surge; 0.568 <= 0.6 -> price_crash (one each)';
end $$;

-- ════════ P6 — D2 PUBLISH-FAILURE LAW: an injected world_events insert failure NEVER aborts the tick. ════════
create or replace function public.ev1_proof_publish_fail() returns trigger language plpgsql as $$
begin
  raise exception 'ev1 proof: injected world_events insert failure';
end $$;
create trigger ev1_proof_publish_fail before insert on public.world_events
  for each row execute function public.ev1_proof_publish_fail();
do $$
declare v_e uuid := (select v from ev1 where k='locE'); v_n int; v_total0 int; v_p int; v_ret int;
begin
  select count(*) into v_total0 from public.world_events;
  update public.game_config set value='80'::jsonb where key='worldstate_pressure_baseline';
  perform pg_temp.ev1_freeze();
  update public.location_state set pressure = 60, last_tick_at = now() - interval '10 minutes'
    where location_id = v_e;
  -- locE crosses 75 -> the tick TRIES to publish -> the trigger blows up the insert -> the 0182
  -- exception guard must swallow it (WARNING) and the tick must complete with its writes intact.
  select public.worldstate_tick() into v_ret;
  if v_ret is null then raise exception 'P6 FAIL: tick returned null under publish failure'; end if;
  select pressure into v_p from public.location_state where location_id = v_e;
  if v_p <> 80 then raise exception 'P6 FAIL: locE update lost under publish failure (pressure %)', v_p; end if;
  select count(*) into v_n from public.world_events;
  if v_n <> v_total0 then raise exception 'P6 FAIL: a row landed despite the injected failure'; end if;
  raise notice 'EV1_PASS_PUBLISH_FAILSAFE ok: injected insert failure swallowed; tick completed and its location_state write survived (D2 cron-safety)';
end $$;
drop trigger ev1_proof_publish_fail on public.world_events;
drop function public.ev1_proof_publish_fail();

-- ════════ P6b — GENUINE RETRY (the state-detection payoff): with the failure gone, the very next
-- ════════        tick finds locE STILL at/above the threshold and lands the lost event.
do $$
declare v_e uuid := (select v from ev1 where k='locE'); v_n int;
begin
  perform pg_temp.ev1_freeze();
  update public.location_state set last_tick_at = now() - interval '10 minutes' where location_id = v_e;
  perform public.worldstate_tick();  -- locE 80 -> 80 (baseline still 80): state holds -> publish lands
  update public.game_config set value='50'::jsonb where key='worldstate_pressure_baseline';  -- restore
  select count(*) into v_n from public.world_events
    where dedup_key = format('pressure_high:%s:%s', v_e, pg_temp.ev1_day()) and severity='warning';
  if v_n <> 1 then raise exception 'P6b FAIL: retry after the failure did not land the event (%)', v_n; end if;
  raise notice 'EV1_PASS_RETRY ok: state still held next tick -> the failed publish genuinely retried and landed (edge semantics would have lost it forever)';
end $$;

-- ════════ P7 — KNOB GUARD: a mis-set owner-tunable (uncastable OR NaN) never kills the heartbeat;
-- ════════        the tick falls back to the seeded default and still narrates correctly.
do $$
declare v_f uuid := (select v from ev1 where k='locF'); v_g uuid := (select v from ev1 where k='locG');
        v_n int;
begin
  update public.game_config set value='80'::jsonb where key='worldstate_pressure_baseline';

  -- (a) uncastable knob: the guarded loader must WARN and fall back to the default 75.
  update public.game_config set value='"not-a-number"'::jsonb where key='event_pressure_high_threshold';
  perform pg_temp.ev1_freeze();
  update public.location_state set pressure = 60, last_tick_at = now() - interval '10 minutes'
    where location_id = v_f;
  perform public.worldstate_tick();   -- must NOT raise; default 75 -> 80 >= 75 -> locF announces
  select count(*) into v_n from public.world_events
    where dedup_key = format('pressure_high:%s:%s', v_f, pg_temp.ev1_day()) and severity='warning';
  if v_n <> 1 then raise exception 'P7 FAIL: uncastable knob did not fall back to the default (%)', v_n; end if;

  -- (b) NaN knob (casts fine but compares as the GREATEST double — would silently disable highs):
  --     the NaN backstop must fall back to the default 75.
  update public.game_config set value='"NaN"'::jsonb where key='event_pressure_high_threshold';
  perform pg_temp.ev1_freeze();
  update public.location_state set pressure = 60, last_tick_at = now() - interval '10 minutes'
    where location_id = v_g;
  perform public.worldstate_tick();   -- must NOT raise; NaN backstop -> 75 -> locG announces
  select count(*) into v_n from public.world_events
    where dedup_key = format('pressure_high:%s:%s', v_g, pg_temp.ev1_day()) and severity='warning';
  if v_n <> 1 then raise exception 'P7 FAIL: NaN knob did not fall back to the default (%)', v_n; end if;

  -- restore the knob + baseline (all rolled back anyway; explicit for readability).
  update public.game_config set value='75'::jsonb where key='event_pressure_high_threshold';
  update public.game_config set value='50'::jsonb where key='worldstate_pressure_baseline';
  raise notice 'EV1_PASS_KNOB_GUARD ok: uncastable and NaN threshold values both fell back to the seeded default with the tick alive (the live-heartbeat safety)';
end $$;

-- ════════ P8 — NARRATE-NEVER-MUTATE: publication changes no game-state byte. ════════
do $$
declare v_a uuid := (select v from ev1 where k='locA'); v_id uuid;
        v_ls0 text; v_ls1 text; v_fs0 text; v_fs1 text;
begin
  select md5(string_agg(t::text, '|' order by location_id)) into v_ls0 from public.location_state t;
  select coalesce(md5(string_agg(t::text, '|' order by field_id)), 'none') into v_fs0 from public.mining_field_state t;

  -- a keyed location-scoped publish + an ad-hoc global publish, straight through the sole writer.
  v_id := public.world_events_publish('world_state','location',null,v_a,'ev1 narrate-only probe',
                                      'body', 'info', now(), null, 'ev1:proof:narrateonly');
  if v_id is null then raise exception 'P8 FAIL: lit keyed publish returned null'; end if;
  v_id := public.world_events_publish('notice','global',null,null,'ev1 ad-hoc probe', null,
                                      'info', now(), null, null);
  if v_id is null then raise exception 'P8 FAIL: lit ad-hoc publish returned null'; end if;

  select md5(string_agg(t::text, '|' order by location_id)) into v_ls1 from public.location_state t;
  select coalesce(md5(string_agg(t::text, '|' order by field_id)), 'none') into v_fs1 from public.mining_field_state t;
  if v_ls0 <> v_ls1 then raise exception 'P8 FAIL: publication mutated location_state'; end if;
  if v_fs0 <> v_fs1 then raise exception 'P8 FAIL: publication mutated mining_field_state'; end if;
  raise notice 'EV1_PASS_NARRATE_ONLY ok: world_events_publish changed no location_state / mining_field_state byte (the downward-leaf charter)';
end $$;

select 'EV-1 WORLD-EVENTS PROOF PASSED (double-dark zero events; state-detected pressure warning/critical + suppressed eased; depletion via the real writer; drift surge/crash; per-day dedup; injected publish failure never aborts the tick AND genuinely retries; knob guard survives uncastable/NaN; narrate-never-mutate)' as result;

rollback;   -- leave ZERO persisted state: no event, state row, config value, flag flip, or trigger.
