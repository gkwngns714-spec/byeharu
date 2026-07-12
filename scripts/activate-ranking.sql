-- RANKING ACTIVATION — the Phase-17 flip (docs/FULL_CAPACITY_PLAN.md §B rung 5 "Ranking";
-- queue slice #9 RANK-SEASON + ACT-RANKING; the ranking stack is FULLY BUILT DARK: 0127-0131 schema +
-- season writer + accrual + read surface, 0144/0145 the commit-safe counted-grants ledger fold,
-- 0147 the 5-min accrue cron — already scheduled, a dark no-op until this flip).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ───────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000147 AND every ranking migration (0127-0131, 0144, 0145, 0147)
--       is actually recorded in supabase_migrations.schema_migrations;
--     • the whole ranking surface exists via to_regprocedure — the REAL signatures:
--       ranking_season_open(text, timestamptz, timestamptz, text) · ranking_accrue_standings() ·
--       ranking_score_delta(jsonb) · the two CLIENT read RPCs get_ranking_seasons() +
--       get_ranking_leaderboard(uuid, text, int) (the exact names rankingApi.ts calls — there is NO
--       get_my_rankings/get_my_standing RPC by design; the own standing is derived client-side);
--     • the three ranking tables exist (ranking_seasons / ranking_standings / ranking_counted_grants)
--       + the one-active-per-cadence partial unique index + the (cadence, starts_at) natural key;
--     • the DEPLOYED ranking_accrue_standings body is the 0145 COMMIT-SAFE one, prosrc-pinned TWICE:
--       it must reference 'ranking_counted_grants' AND carry the exactly-once
--       'on conflict (season_id, grant_id) do nothing' ledger insert (the stale 0130 timestamp-cursor
--       body — which silently drops late-committing grants — contains neither token);
--     • the accrue cron is scheduled EXACTLY ONCE: jobname 'ranking-accrue-standings' (0147), its
--       command invoking ranking_accrue_standings;
--     • the 'ranking_enabled' game_config key exists (0127 seeds 'false'; a typo can never invent a
--       key). Its VALUE is not asserted false — a RE-RUN after success is a supported no-op;
--     • reward_grants is readable — counts per dimension are FYI ONLY, NEVER a gate: ranking can
--       light before grants flow (boards start empty and fill as activity systems activate; the
--       'trade' dimension has NO depositor yet — 0128 note — and stays 0 until one exists).
--   STAGE 1 — the switch (the ONLY write of this script): ranking_enabled → true.
--     ORDERED BEFORE THE SEASON OPENS, DELIBERATELY: ranking_season_open dark-gates on
--     cfg_bool('ranking_enabled') FIRST (0129:71) and answers {ok:false, code:'feature_disabled'}
--     while the flag is false — a season physically cannot be opened dark. Both stages live in the
--     ONE transaction, so if the season stage fails the flag write rolls back too (all-or-nothing:
--     the flag is never committed without its seasons, the plan's rung-5 prereq).
--   STAGE 2 — seasons (runtime-created, NEVER migration-seeded — the 0127 law), CONDITIONAL per
--     cadence for re-run idempotency: a cadence that already has a CURRENT active season (active AND
--     window containing now()) is skipped with a notice (re-run inside the window = no-op success);
--     an EXPIRED active season does NOT skip — the open closes it and rolls the window (0129), so a
--     later re-run of this script IS the manual season roll. Otherwise ranking_season_open is
--     called with explicit bounds
--     (the function takes them; it does not compute windows) and its jsonb envelope is asserted
--     ok:true + status:'active'.
--     WINDOW/LABEL CONVENTION [D owner-tunable], computed from now() at run time under the
--     transaction-local UTC timezone:
--       weekly  = ISO-Monday-anchored: date_trunc('week', now()) .. +7 days, label 'IYYY-"W"IW'
--                 (e.g. 2026-W28 — the ISO week of the run);
--       monthly = calendar month:      date_trunc('month', now()) .. +1 month, label 'YYYY-MM'
--                 (e.g. 2026-07).
--     Future season rolls MUST reuse this convention (same anchors, same labels) so windows tile
--     without gaps and (cadence, starts_at) replay-idempotency holds across operators.
--   STAGE 3 — smoke asserts (read-only): flag committed (raw + cfg_bool); exactly ONE active season
--     per cadence with a window containing now(); the cron row still there exactly once; standings +
--     counted-grants tables selectable; the CLIENT read surface answers lit — get_ranking_seasons()
--     {ok:true, ≥2 seasons} and get_ranking_leaderboard(active weekly, 'overall') {ok:true} (rows
--     likely [] at flip time — honest empty state).
--   Emits ACTIVATE_RANKING_PASS_* markers per stage and one final PASS line; any failed assert
--   RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): safe no-op success. The flag write is a set_game_config
-- upsert to the same value; the season stage skips any cadence that already has an active season.
-- A re-run in a LATER window (after the first seasons ended) would open the CURRENT window per
-- convention — which is exactly the manual season-roll operation (below), so that is correct too.
-- EDGE (asserted, not silently accepted): if a cadence has NO active season but a CLOSED season
-- exists at this exact starts_at (e.g. after an over-eager rollback that closed seasons),
-- ranking_season_open's (cadence, starts_at) replay returns the CLOSED row verbatim and NEVER
-- reactivates it (0129:93-103) — this script then FAILS LOUDLY rather than committing a lit flag
-- with a dead board; wait for the next window or pick a fresh starts_at deliberately.
--
-- ── OPERATIONAL ITEM — NO auto-roll exists (verified, this slice) ─────────────────────────────────
--   NOTHING closes or rolls a season when ends_at passes. The SOLE writer of ranking_seasons is
--   ranking_season_open (0129 — it closes the prior active of a cadence only when opening the next),
--   and the only ranking cron is the 5-min ACCRUAL (0147) — it never touches seasons. A season stays
--   status='active' past its ends_at; the accrual's window join (granted_at between starts_at and
--   ends_at — 0145:88-89) simply stops folding new grants, so the board silently FREEZES until a
--   human opens the next window. SEASON ROLLING IS MANUAL FOR NOW: each Monday 00:00 UTC (weekly) /
--   1st of the month (monthly), a service-role call to ranking_season_open with the next window per
--   the convention above — or just re-run this script (the conditional stage makes it the roll).
--   A future automation slice (RANK-ROLL: a cron computing the current window per cadence and
--   calling ranking_season_open — already idempotent per (cadence, starts_at)) is noted in the plan
--   queue. TWO ACCOUTING EDGES the RANK-ROLL slice MUST close (review M1/L1, 2026-07-12): (1) the
--   0145 fold joins status='active' only, so an in-window grant whose txn COMMITS AFTER the roll
--   closes the old season folds into NEITHER season — the roller must keep folding recently-closed
--   seasons for a grace tick (e.g. or (status='closed' and ends_at > now() - interval '1 hour'))
--   or run one accrual between window-end and close; (2) 0145's BETWEEN is inclusive both ends
--   while windows tile half-open — a granted_at exactly at the boundary double-counts into both
--   seasons; the accrual join should become >= starts_at AND < ends_at.
--
-- ── NO CLIENT PR IS NEEDED (verified 2026-07-12, this slice) ─────────────────────────────────────
--   The ranking surface is SERVER-LIT, not compile-gated — there is NO ranking constant in
--   osnReleaseGates.ts and no RANKING_* compile constant anywhere in src (grep-verified):
--     • RankingPanel is ALREADY MOUNTED on the CommandScreen aside rail — CommandScreen.tsx:83
--       `<RankingPanel lifecycleKey={user?.id ?? 'anon'} />` inside screenRailClass('aside'), the
--       post-R3 Mission Control home-base interior — and renders null unless isServerLit(seasons)
--       AND ≥1 season exists (RankingPanel.tsx:87). The moment this script commits, the very
--       reads it makes (get_ranking_seasons → get_ranking_leaderboard) answer lit and the board
--       appears: season + dimension selectors (overall/combat/trade/exploration/mining), ranked
--       rows, own-standing highlight.
--   WHAT PLAYERS SEE AT FLIP TIME: the Leaderboard card with the two fresh seasons and
--   "No standings yet for this board." — standings START EMPTY and fill as the 5-min cron
--   (ranking-accrue-standings) folds finalized reward_grants: combat/exploration/mining deposit
--   today (as those systems are lit); the trade dimension stays 0 until a trade activity deposits
--   grants (Trade V1 banks via the Wallet path — 0128 note).
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • ranking_seasons/ranking_standings/ranking_counted_grants rows — NEVER written directly;
--     seasons go through ranking_season_open (the SOLE writer, 0129), standings/ledger only through
--     the cron's accrual. This script's only write is the ONE set_game_config upsert.
--   • Every other window's key: exploration_enabled / mining_enabled / trade_* / captain_* /
--     team_command_enabled / station_storage_enabled / salvage_market_enabled /
--     location_investment_enabled / world_balance_enabled / phase20_polish_enabled.
--   • The cron schedule (0147 owns it). Any table other than game_config. Any DDL. Any migration.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-ranking.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / run it through the
--   management-API runner (it contains no backslash commands to strip), or:
--     bash scripts/activate-ranking.sh run ACTIVATE_RANKING      # DB_URL required
--   AFTER a green run: within ~5 minutes the cron's first lit firing folds any window-eligible
--   grants; manual smoke — open the Dashboard (CommandScreen) → the Leaderboard card shows both
--   seasons; clear a pirate wave / secure a return → after the next cron tick the combat board
--   moves and the own-standing line appears.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). FLAG-ONLY: ranking_enabled →
--   false. Standings FREEZE INTACT (the plan §B rung-5 rollback story): every ranking RPC — both
--   reads, the season writer, the cron's accrual — reject-before-reads on the flag, so boards
--   vanish client-side (RankingPanel fails closed to null) and the cron becomes a no-op again.
--   SEASONS ARE DELIBERATELY LEFT ACTIVE — do NOT close them (recommended + reasoned): closing is
--   effectively ONE-WAY for the window, because ranking_season_open's (cadence, starts_at) replay
--   returns a closed row verbatim and never reactivates it (0129) — a re-light inside the same
--   window would then have NO active season and fold nothing. Left active they are harmless while
--   dark (unreachable behind the gates) and on re-light the ledger anti-join BACKFILLS every grant
--   that landed in-window during the dark spell — no gap, no double-count.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; v_missing text; n int; fn text; v_src text;
  v_combat int; v_trade int; v_expl int; v_mining int;
begin
  -- every ranking migration deployed AND recorded (head alone is not enough).
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000147' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000147 (the ranking accrue cron) — deploy the ranking stack first', coalesce(v_head, '(none)');
  end if;
  select string_agg(mv, ', ') into v_missing
    from unnest(array['20260618000127','20260618000128','20260618000129','20260618000130',
                      '20260618000131','20260618000144','20260618000145','20260618000147']) mv
   where not exists (select 1 from supabase_migrations.schema_migrations s where s.version = mv);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: ranking migration(s) not recorded as deployed: %', v_missing;
  end if;

  -- the three ranking tables + the reward source exist.
  select string_agg(t, ', ') into v_missing
    from unnest(array['public.ranking_seasons','public.ranking_standings',
                      'public.ranking_counted_grants','public.reward_grants']) t
   where to_regclass(t) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: table(s) missing: %', v_missing;
  end if;

  -- the season invariants physically exist: one-active-per-cadence (0127) + the (cadence, starts_at)
  -- idempotency natural key (0129).
  select count(*) into n from pg_indexes
   where schemaname = 'public' and tablename = 'ranking_seasons'
     and indexname in ('ranking_seasons_one_active_per_cadence', 'ranking_seasons_cadence_start_uidx');
  if n <> 2 then
    raise exception 'PRECONDITION FAIL: ranking_seasons carries %/2 of the invariant indexes (one-active-per-cadence 0127 + cadence/starts_at natural key 0129)', n;
  end if;

  -- the whole ranking function surface exists — the REAL signatures (incl. the two client RPCs
  -- rankingApi.ts calls) + the two shared config leaves this script relies on.
  foreach fn in array array[
    'public.ranking_season_open(text, timestamptz, timestamptz, text)',
    'public.ranking_accrue_standings()',
    'public.ranking_score_delta(jsonb)',
    'public.get_ranking_seasons()',
    'public.get_ranking_leaderboard(uuid, text, int)',
    'public.cfg_bool(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  -- the DEPLOYED accrual body is the 0145 COMMIT-SAFE ledger fold (two positive prosrc pins the
  -- stale 0130 timestamp-cursor body — the silent late-commit point-dropper — carries neither of).
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.ranking_accrue_standings()')::oid;
  if position('ranking_counted_grants' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed ranking_accrue_standings body never references ranking_counted_grants — the stale commit-UNSAFE 0130 body is live; deploy 0145';
  end if;
  if position('on conflict (season_id, grant_id) do nothing' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed ranking_accrue_standings body lacks the exactly-once ledger insert guard (on conflict (season_id, grant_id) do nothing) — deploy 0145';
  end if;

  -- the accrue cron is scheduled EXACTLY once (0147), invoking the accrual.
  select count(*) into n from cron.job where jobname = 'ranking-accrue-standings';
  if n <> 1 then
    raise exception 'PRECONDITION FAIL: cron job ranking-accrue-standings scheduled % time(s) (want exactly 1 — 0147)', n;
  end if;
  select count(*) into n from cron.job
   where jobname = 'ranking-accrue-standings' and command like '%ranking_accrue_standings%';
  if n <> 1 then
    raise exception 'PRECONDITION FAIL: the ranking-accrue-standings cron command does not invoke ranking_accrue_standings';
  end if;

  -- the ONE key this script writes must already exist (refuse to invent config rows via a typo).
  -- Its VALUE is deliberately NOT asserted false: a re-run after success is a supported no-op.
  if not exists (select 1 from public.game_config where key = 'ranking_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key ranking_enabled missing (0127 seeds it false)';
  end if;

  -- reward_grants readable; per-dimension counts are FYI ONLY, NEVER a gate — ranking can light
  -- before grants flow (boards fill as activity systems activate; trade has no depositor yet).
  select count(*) filter (where source_type = 'combat'),
         count(*) filter (where source_type = 'trade'),
         count(*) filter (where source_type = 'exploration'),
         count(*) filter (where source_type = 'mining')
    into v_combat, v_trade, v_expl, v_mining
    from public.reward_grants;
  raise notice 'FYI reward_grants by dimension (not a gate): combat %, trade %, exploration %, mining %', v_combat, v_trade, v_expl, v_mining;

  raise notice 'ACTIVATE_RANKING_PASS_PRECONDITIONS ok: head %, 8 ranking migrations recorded, 3 tables + 2 invariant indexes, 7 functions present (real signatures), 0145 commit-safe accrual prosrc-pinned twice, cron scheduled exactly once, ranking_enabled key present, reward_grants readable', v_head;
end $$;

-- ══════════ STAGE 1 — the switch (the ONLY write; BEFORE the seasons: ranking_season_open
--            dark-gates on this flag, 0129:71 — a season cannot be opened while it is false) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'ranking_enabled';
  perform public.set_game_config('ranking_enabled', 'true'::jsonb);
  raise notice 'stage 1: ranking_enabled % -> true', v_before;

  raise notice 'ACTIVATE_RANKING_PASS_STAGE1 ok: ranking_enabled=true (uncommitted until the season stage passes — one all-or-nothing txn)';
end $$;

-- ══════════ STAGE 2 — the seasons (runtime-created via the SOLE writer; conditional per cadence
--            for re-run no-op idempotency; windows computed from now() under the txn-local UTC) ══════════
do $$
declare
  v_res      jsonb;
  v_wk_start timestamptz := date_trunc('week',  now());   -- ISO Monday 00:00 UTC
  v_wk_end   timestamptz := date_trunc('week',  now()) + interval '7 days';
  v_wk_label text        := to_char(date_trunc('week',  now()), 'IYYY-"W"IW');  -- e.g. 2026-W28
  v_mo_start timestamptz := date_trunc('month', now());   -- calendar month, 1st 00:00 UTC
  v_mo_end   timestamptz := date_trunc('month', now()) + interval '1 month';
  v_mo_label text        := to_char(date_trunc('month', now()), 'YYYY-MM');     -- e.g. 2026-07
begin
  -- weekly — create ONLY if no CURRENT active weekly season exists (active AND window containing
  -- now()): a re-run inside the same window = no-op; a re-run in a LATER window (the prior active
  -- season expired — no auto-roll exists) proceeds, and ranking_season_open closes the expired
  -- active season while opening the new window (0129) — i.e. the re-run IS the manual season roll.
  if exists (select 1 from public.ranking_seasons where cadence = 'weekly' and status = 'active'
               and starts_at <= now() and ends_at > now()) then
    raise notice 'stage 2: a current active weekly season already exists — skipped (re-run no-op)';
  else
    v_res := public.ranking_season_open('weekly', v_wk_start, v_wk_end, v_wk_label);
    if coalesce(v_res ->> 'ok', 'false') <> 'true' then
      raise exception 'STAGE2 FAIL: ranking_season_open(weekly) rejected: %', v_res;
    end if;
    if v_res ->> 'status' is distinct from 'active' then
      raise exception 'STAGE2 FAIL: weekly window % replayed with status % — a previously CLOSED identical window is never reactivated (0129); wait for the next window or open a fresh starts_at deliberately', v_wk_label, v_res ->> 'status';
    end if;
    raise notice 'stage 2: weekly season % opened [% .. %) season_id %', v_wk_label, v_wk_start, v_wk_end, v_res ->> 'season_id';
  end if;

  -- monthly — same conditional shape (skip only a CURRENT active season; an expired one rolls).
  if exists (select 1 from public.ranking_seasons where cadence = 'monthly' and status = 'active'
               and starts_at <= now() and ends_at > now()) then
    raise notice 'stage 2: a current active monthly season already exists — skipped (re-run no-op)';
  else
    v_res := public.ranking_season_open('monthly', v_mo_start, v_mo_end, v_mo_label);
    if coalesce(v_res ->> 'ok', 'false') <> 'true' then
      raise exception 'STAGE2 FAIL: ranking_season_open(monthly) rejected: %', v_res;
    end if;
    if v_res ->> 'status' is distinct from 'active' then
      raise exception 'STAGE2 FAIL: monthly window % replayed with status % — a previously CLOSED identical window is never reactivated (0129); wait for the next window or open a fresh starts_at deliberately', v_mo_label, v_res ->> 'status';
    end if;
    raise notice 'stage 2: monthly season % opened [% .. %) season_id %', v_mo_label, v_mo_start, v_mo_end, v_res ->> 'season_id';
  end if;

  raise notice 'ACTIVATE_RANKING_PASS_STAGE2 ok: one active weekly + one active monthly season (created or already present)';
end $$;

-- ══════════ STAGE 3 — smoke asserts (read-only) ══════════
do $$
declare
  n int; v_weekly uuid; v_res jsonb;
begin
  -- (a) the committed flag value is exactly the activation state (raw + through the reader).
  if (select value #>> '{}' from public.game_config where key = 'ranking_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: ranking_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'ranking_enabled');
  end if;
  if not public.cfg_bool('ranking_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(ranking_enabled) still false'; end if;

  -- (b) exactly ONE active season per cadence, each window containing now() (a frozen/expired
  --     window at flip time would be a dead board).
  select count(*) into n from public.ranking_seasons where cadence = 'weekly' and status = 'active'
    and starts_at <= now() and ends_at > now();
  if n <> 1 then
    raise exception 'SMOKE FAIL: % active weekly season(s) with a window containing now() (want exactly 1)', n; end if;
  select count(*) into n from public.ranking_seasons where cadence = 'monthly' and status = 'active'
    and starts_at <= now() and ends_at > now();
  if n <> 1 then
    raise exception 'SMOKE FAIL: % active monthly season(s) with a window containing now() (want exactly 1)', n; end if;

  -- (c) the accrue cron still scheduled exactly once (this script never touches it).
  select count(*) into n from cron.job where jobname = 'ranking-accrue-standings';
  if n <> 1 then
    raise exception 'SMOKE FAIL: cron job ranking-accrue-standings scheduled % time(s) after the flip (want 1)', n; end if;

  -- (d) the standings + ledger tables are selectable (counts FYI — likely 0 at flip time; they fill
  --     as the 5-min cron folds finalized reward_grants).
  select count(*) into n from public.ranking_standings;
  raise notice 'smoke: ranking_standings rows = % (likely 0 at flip time)', n;
  select count(*) into n from public.ranking_counted_grants;
  raise notice 'smoke: ranking_counted_grants rows = % (likely 0 at flip time)', n;

  -- (e) the CLIENT read surface answers lit — the exact RPCs RankingPanel rides. get_ranking_seasons
  --     must be {ok:true} with >= 2 seasons; the active weekly overall board must answer {ok:true}
  --     (rows likely [] — the honest "No standings yet" empty state).
  v_res := public.get_ranking_seasons();
  if coalesce(v_res ->> 'ok', 'false') <> 'true' then
    raise exception 'SMOKE FAIL: get_ranking_seasons() not lit: %', v_res; end if;
  if coalesce(jsonb_array_length(v_res -> 'seasons'), 0) < 2 then
    raise exception 'SMOKE FAIL: get_ranking_seasons() returned % season(s) (want >= 2)',
      coalesce(jsonb_array_length(v_res -> 'seasons'), 0); end if;
  select season_id into v_weekly from public.ranking_seasons
   where cadence = 'weekly' and status = 'active';
  v_res := public.get_ranking_leaderboard(v_weekly, 'overall', 10);
  if coalesce(v_res ->> 'ok', 'false') <> 'true' then
    raise exception 'SMOKE FAIL: get_ranking_leaderboard(weekly, overall) not lit: %', v_res; end if;
  raise notice 'smoke: get_ranking_leaderboard(weekly, overall) rows = % (empty is expected at flip time)',
    coalesce(jsonb_array_length(v_res -> 'rows'), 0);

  raise notice 'ACTIVATE_RANKING_PASS_SMOKE ok: flag committed true, one active season per cadence containing now(), cron intact, standings + ledger selectable, both client RPCs answer lit';
end $$;

select 'RANKING ACTIVATION PASS — ranking LIVE server-side (weekly + monthly seasons open; the 5-min ranking-accrue-standings cron begins folding finalized reward_grants on its next firing). NO client PR is needed: RankingPanel is already mounted server-lit on the CommandScreen aside rail (CommandScreen.tsx:83) and appears the moment these reads answer lit. Players see the Leaderboard card with both seasons and "No standings yet" — boards fill as grants flow (combat/exploration/mining deposit today; the trade dimension stays 0 until a trade activity deposits grants). OPERATIONAL: seasons do NOT auto-roll — roll manually each Monday / 1st (ranking_season_open or a re-run of this script) until a RANK-ROLL automation slice ships.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the ranking surface again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY and fully reversible (plan §B rung 5): standings FREEZE INTACT — every ranking RPC
--     (both reads, the season writer, the cron's accrual) reject-before-reads on the flag, so
--     RankingPanel fails closed to null and the cron firings become instant no-ops again.
--   • LEAVE THE SEASONS ACTIVE — deliberately NOT closed here (recommendation, reasoned): closing a
--     window is effectively one-way, because ranking_season_open's (cadence, starts_at) idempotent
--     replay returns a closed row verbatim and NEVER reactivates it (0129) — a re-light inside the
--     same window would then find no active season and fold nothing. Active-but-dark seasons are
--     harmless (unreachable behind the gates), and on re-light the 0144/0145 ledger anti-join
--     BACKFILLS every in-window grant that landed during the dark spell — no gap, no double-count.
--   • ranking_seasons/ranking_standings/ranking_counted_grants rows persist untouched (reset is BY
--     SEASON, never by deletion — the ROADMAP :92 law); no client revert exists (no compile gate).
--
-- begin;
-- select public.set_game_config('ranking_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'ranking_enabled';
-- commit;
