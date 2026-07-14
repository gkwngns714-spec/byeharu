-- DECKS-3 ACTIVATION — the station-affinity bonus flip (docs/ACTIVATION_GUIDE.md → ACT-DECKS3; the
-- DECKS packet's human activation step). The station-affinity fold is FULLY BUILT DARK: 0196 adds
-- the knob-gated affinity multiplier to calculate_expedition_stats (a captain whose specialization
-- matches their held station's affinity gets that captain's stats scaled by 1 + station_affinity_bonus),
-- seeded '0' → ×1.0 byte-inert. This script raises the ONE knob.
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips
-- at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • ██ THE HARD CAPTAINS GATE (decided: hard, not a warning — exactly as ACT-HAUL hard-gates on
--       trade) ██: captain_assignment_enabled must be COMMITTED true (raw value + cfg_bool). WHY:
--       the affinity bonus scales a CAPTAIN's contribution, and captains only staff stations while
--       assignment is lit — a station-affinity bonus with captains dark is a 100% dead knob (no
--       captain occupies a station to match). FLIP ORDER: captains FIRST (scripts/activate-captains),
--       then this;
--     • migration head >= 20260618000196 AND 0196 recorded as deployed;
--     • the adapter exists via to_regprocedure and its DEPLOYED body is the 0196 head, prosrc-pinned:
--       the once-at-entry knob read, the LEFT station join, and the no-match affinity multiplier CASE;
--     • the 0189 station catalog is intact (6 rows) — the mapping the match rides on;
--     • the knob station_affinity_bonus currently reads '0' (this is a FIRST-FLIP tool — see RE-RUN).
--   STAGE 1 — the switch (the ONE knob write, via the owned set_game_config writer):
--     station_affinity_bonus → 0.15. [D — OWNER-TUNABLE: the bonus step for a matched captain; the
--     charter proposal. Edit before running.] The adapter reads it ONCE per stat computation.
--   SMOKE (read-only): the knob committed (raw + cfg_num > 0); the adapter still carries the affinity
--     fold (prosrc-pinned) — so a matched captain's contribution now scales by 1 + the knob; the 0189
--     station catalog still intact.
--   Emits ACTIVATE_DECKS3_PASS_* markers per stage and one final PASS line; any failed assert RAISES
--   → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): FIRST-FLIP tool. STAGE 1 hard-preconditions the knob reads
-- '0', so a verbatim re-run after success RAISES at the precondition BY DESIGN — it refuses to
-- silently re-clobber a later deliberate retune (a retune is a separate set_game_config write).
--
-- ── NO CLIENT PR IS NEEDED ───────────────────────────────────────────────────────────────────────
--   The bonus is SERVER-side inside the adapter — the moment the knob commits, every stat surface
--   (solo preview, D0 team totals, combat snapshots) applies the matched-station bonus. There is no
--   compile constant to flip.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn>" -X -v ON_ERROR_STOP=1 -f scripts/activate-decks3.sql
--   Or paste into the Supabase Dashboard SQL editor / management-API runner, or:
--     bash scripts/activate-decks3.sh run ACTIVATE_DECKS3      # DB_URL required
--   AFTER a green run: manual smoke — station a matching captain (e.g. a combat captain in Gunnery)
--   and watch that captain's stat contribution rise by the bonus in the preview.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section (commented). KNOB-back-to-0 returns every affinity multiplier to
--   ×1.0 exactly (byte-inert) on the next stat read. No data to revert.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare v_head text; v_src text; n int;
begin
  -- ██ THE HARD CAPTAINS GATE ██ — captains must be COMMITTED lit (raw + cfg_bool), else the bonus
  -- is a dead knob (no captain staffs a station to match). The ACT-HAUL hard-gate posture.
  if (select value #>> '{}' from public.game_config where key = 'captain_assignment_enabled') is distinct from 'true'
     or not public.cfg_bool('captain_assignment_enabled') then
    raise exception 'PRECONDITION FAIL: captain_assignment_enabled is not committed true — run ACT-CAPTAINS (scripts/activate-captains.sql) FIRST. The station-affinity bonus scales a CAPTAIN''s contribution and is meaningless while captains are dark (no captain staffs a station to match)';
  end if;

  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000196' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000196 (DECKS-3) — deploy the affinity fold first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations s where s.version = '20260618000196') then
    raise exception 'PRECONDITION FAIL: migration 20260618000196 not recorded as deployed';
  end if;

  -- the adapter exists + config leaves.
  if to_regprocedure('public.calculate_expedition_stats(uuid, uuid, jsonb, text)') is null then
    raise exception 'PRECONDITION FAIL: calculate_expedition_stats missing'; end if;
  if to_regprocedure('public.cfg_num(text)') is null or to_regprocedure('public.set_game_config(text, jsonb)') is null then
    raise exception 'PRECONDITION FAIL: cfg_num / set_game_config missing'; end if;

  -- the DEPLOYED adapter is the 0196 head: the once-at-entry knob read + the LEFT station join +
  -- the no-match affinity CASE.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.calculate_expedition_stats(uuid, uuid, jsonb, text)')::oid;
  if position('cfg_num(''station_affinity_bonus'')' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed calculate_expedition_stats does not read station_affinity_bonus (deploy 0196)';
  end if;
  if position('left join ship_stations st on st.station_id = a.station' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed adapter lacks the LEFT station join (deploy 0196)';
  end if;
  if position('v_aff_mult := case when c.affinity_specialization = c.specialization then 1 + v_aff_bonus else 1 end' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed adapter lacks the affinity-match multiplier CASE (deploy 0196)';
  end if;

  -- the 0189 station catalog the match rides on (6 rows).
  select count(*) into n from public.ship_stations;
  if n <> 6 then
    raise exception 'PRECONDITION FAIL: ship_stations holds % rows (want the frozen 6 — the 0189 seed)', n;
  end if;

  -- the knob exists and reads '0' (FIRST-FLIP guard — see RE-RUN SEMANTICS).
  if not exists (select 1 from public.game_config where key = 'station_affinity_bonus') then
    raise exception 'PRECONDITION FAIL: game_config key station_affinity_bonus missing (0196 seeds it 0)';
  end if;
  if (select value #>> '{}' from public.game_config where key = 'station_affinity_bonus') is distinct from '0' then
    raise exception 'PRECONDITION FAIL: station_affinity_bonus is not the dark seed ''0'' — this is a FIRST-FLIP tool; a retune is a separate set_game_config write';
  end if;

  raise notice 'ACTIVATE_DECKS3_PASS_PRECONDITIONS ok: head %, 0196 recorded, captains committed lit (the hard gate), adapter affinity fold prosrc-pinned, 6-station catalog intact, knob at the dark seed 0', v_head;
end $$;

-- ══════════ STAGE 1 — the switch (the ONE knob write, via the owned set_game_config writer) ══════════
--   [D — OWNER-TUNABLE] the bonus step for a matched captain's contribution. Charter proposal: 0.15.
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'station_affinity_bonus';
  perform public.set_game_config('station_affinity_bonus', '0.15'::jsonb);   -- [D] OWNER-TUNABLE
  raise notice 'stage 1: station_affinity_bonus % -> 0.15', v_before;
  raise notice 'ACTIVATE_DECKS3_PASS_STAGE1 ok: station_affinity_bonus=0.15 (uncommitted until smoke passes)';
end $$;

-- ══════════ SMOKE — read-only ══════════
do $$
declare v_src text;
begin
  -- (a) the committed knob value (raw + through the reader the adapter uses).
  if (select value #>> '{}' from public.game_config where key = 'station_affinity_bonus') is distinct from '0.15' then
    raise exception 'SMOKE FAIL: station_affinity_bonus is % (want 0.15)',
      (select value #>> '{}' from public.game_config where key = 'station_affinity_bonus');
  end if;
  if public.cfg_num('station_affinity_bonus') is null or public.cfg_num('station_affinity_bonus') <= 0 then
    raise exception 'SMOKE FAIL: station_affinity_bonus does not read > 0 through cfg_num'; end if;

  -- (b) the adapter still carries the affinity fold — so a MATCHED captain's contribution now scales
  --     by (1 + the knob); the fold is live because the adapter reads the knob at entry.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.calculate_expedition_stats(uuid, uuid, jsonb, text)')::oid;
  if position('v_aff_mult := case when c.affinity_specialization = c.specialization then 1 + v_aff_bonus else 1 end' in v_src) = 0 then
    raise exception 'SMOKE FAIL: the adapter lost its affinity-match multiplier'; end if;
  if position('* v_aff_mult' in v_src) = 0 then
    raise exception 'SMOKE FAIL: the adapter no longer composes the affinity multiplier into the fold'; end if;

  -- (c) the station catalog still intact (the match target).
  if (select count(*) from public.ship_stations) <> 6 then
    raise exception 'SMOKE FAIL: ship_stations no longer holds 6 rows'; end if;

  raise notice 'ACTIVATE_DECKS3_PASS_SMOKE ok: knob committed 0.15 (cfg_num > 0), adapter affinity fold live (a matched captain now scales by 1 + the knob), 6-station catalog intact';
end $$;

select 'DECKS-3 ACTIVATION PASS — station-affinity bonuses are LIVE. station_affinity_bonus is 0.15 [D], so a captain whose specialization matches their held station (a combat captain in Gunnery, a mining captain in Engineering, …) now contributes stats scaled by 1.15, composed with any captain-level multiplier — while an unstationed captain, the Bridge, or a mismatch stay exactly ×1.0. NO client PR is needed: the bonus is server-side inside the adapter and applies on the next stat read. Requires captains lit (the hard precondition).' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the affinity bonus again, run the reverse write below (uncomment, run once). KNOB-back-to-0
-- returns every v_aff_mult to ×1.0 exactly (byte-inert) on the next stat read. No data to revert.
--
-- begin;
-- select public.set_game_config('station_affinity_bonus', '0'::jsonb);
-- select key, value from public.game_config where key = 'station_affinity_bonus';
-- commit;
