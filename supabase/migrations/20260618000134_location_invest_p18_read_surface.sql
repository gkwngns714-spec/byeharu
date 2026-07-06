-- Byeharu — LOCATION-INVEST-P18 SLICE 2: the dark, PUBLIC read surface — persistent state vs seasonal
-- score, plus the caller's own history, plus the ONE shared season-window helper. Read-only; NO write
-- anywhere; dark-gated like every Investment surface. NO new table, NO writer, NO frontend, NO cron,
-- NO flag flip this slice.
--
-- IDIOM SOURCES (reused, never reinvented):
--   · stable security definer + dark-gate FIRST + code-keyed {ok:false, code:'feature_disabled'}
--     anti-probe + limit-clamp [1,500] + row_number() ranking + anon+authenticated PUBLIC posture:
--     the Ranking read surface get_ranking_seasons / get_ranking_leaderboard (0131).
--   · own-history read (auth-scoped player_id = auth.uid(), join for display identity, newest first,
--     authenticated-only ACL): get_my_mining_extractions (0106) / get_my_module_instances (0110).
--   · config reader cfg_num (0003; returns double precision) — the window math needs no cfg_text.
--
-- PERSISTENT-vs-SEASONAL = TWO READS OVER THE ONE APPEND-ONLY LEDGER (no denormalized aggregate, ever
-- — the 0131 "derived at read time" law): persistent development = the all-time SUM per location;
-- seasonal score = the SUM within the CURRENT season window. Both are computed on the fly from
-- `location_investments`; the SECURITY DEFINER context aggregates across owners but exposes ONLY totals
-- / ranked scores — never another player's individual rows (those stay behind the 0132 owner-read RLS,
-- surfaced only by the own-history RPC below).
--
-- THE SEASON WINDOW IS CONFIG-DERIVED + DETERMINISTIC (no season table, no season-open writer — does
-- NOT duplicate Ranking's ranking_season_open machinery): a fixed-length period counted from a fixed
-- UNIX epoch anchor. The window math lives in EXACTLY ONE place — location_investment_current_window()
-- — and every read that needs "the current window" calls it (no duplicated window arithmetic anywhere).
-- Reset-by-season is honored structurally: a new window shifts the seasonal read while the ledger
-- (persistent state) is never touched.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): read-only functions — NO new writer,
-- NO new table, so the §1 matrix is UNCHANGED (the 0131/0106/0110 read-surface precedent: read
-- surfaces live in the §2 system row, not the matrix). The §2 Location Investment row gains the three
-- RPCs + the window helper and records the now-realized DOWNWARD Map read edge (reads `locations` for
-- validation/identity) alongside the existing Reference/Config (`cfg_bool`/`cfg_num`) edge. No cycle,
-- nothing calls into Investment. No flag flipped; `0001–0133` unedited; forward-only.

-- ── (a) the TWO season-window tunables this slice consumes (numeric unix-seconds; no cfg_text needed) ─
insert into public.game_config (key, value, description) values
  ('location_investment_season_seconds', '604800',
   'LOCATION-INVEST-P18: seasonal window length in seconds for the location-investment score '
   '(604800 = a 7-day weekly window, the competitive cadence aligned with the ROADMAP weekly season '
   'notion). Consumed by location_investment_current_window().'),
  ('location_investment_season_epoch_seconds', '1767225600',
   'LOCATION-INVEST-P18: fixed UNIX-seconds anchor (1767225600 = 2026-01-01T00:00:00Z) from which the '
   'fixed-length seasonal windows are counted. Consumed by location_investment_current_window().')
on conflict (key) do nothing;

-- ── (b) location_investment_current_window — THE ONE definition of "the current season window" ─────
-- Internal (client-revoked; the security definer read RPCs call it as owner). Given now_s = epoch of
-- now(), epoch_s + period_s from config: k = floor((now_s - epoch_s)/period_s), window_start =
-- to_timestamp(epoch_s + k*period_s), window_end = window_start + period_s. Every windowed read calls
-- this — the window math exists in exactly ONE place.
create or replace function public.location_investment_current_window()
returns table (window_index bigint, window_start timestamptz, window_end timestamptz)
language sql
stable
set search_path = public
as $$
  with cfg as (
    select public.cfg_num('location_investment_season_epoch_seconds') as epoch_s,
           public.cfg_num('location_investment_season_seconds')       as period_s
  ),
  w as (
    select epoch_s, period_s,
           floor((extract(epoch from now())::double precision - epoch_s) / period_s)::bigint as k
    from cfg
  )
  select k,
         to_timestamp(epoch_s + k * period_s),
         to_timestamp(epoch_s + (k + 1) * period_s)   -- = window_start + period_s
  from w;
$$;
-- Internal: no client grant. Called only from within the SECURITY DEFINER read RPCs (they run as owner).
revoke execute on function public.location_investment_current_window() from public, anon, authenticated;

-- ── (c1) get_location_development — persistent state vs seasonal score for ONE location (public) ────
create or replace function public.get_location_development(p_location_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_idx      bigint;
  v_start    timestamptz;
  v_end      timestamptz;
  v_all_time numeric;
  v_contrib  bigint;
  v_season   numeric;
begin
  -- DARK server-reject FIRST (0132 law; 0131 read idiom): before any read, identical envelope.
  if not public.cfg_bool('location_investment_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- the location must exist (Map read — the now-realized DOWNWARD edge).
  if p_location_id is null
     or not exists (select 1 from public.locations where id = p_location_id) then
    return jsonb_build_object('ok', false, 'code', 'unknown_location');
  end if;

  -- the current season window, from the ONE shared helper.
  select w.window_index, w.window_start, w.window_end
    into v_idx, v_start, v_end
    from public.location_investment_current_window() w;

  -- persistent development (all-time) + seasonal score (this window) — TWO reads over the one ledger,
  -- both DERIVED (never stored). Only totals/counts are exposed, never another player's rows.
  select coalesce(sum(li.amount), 0),
         count(distinct li.player_id),
         coalesce(sum(li.amount) filter (where li.invested_at >= v_start and li.invested_at < v_end), 0)
    into v_all_time, v_contrib, v_season
    from public.location_investments li
    where li.location_id = p_location_id;

  return jsonb_build_object('ok', true,
    'location_id', p_location_id,
    'all_time_total', v_all_time,
    'contributor_count', v_contrib,
    'season_total', v_season,
    'window_index', v_idx,
    'window_start', v_start,
    'window_end', v_end);
end;
$$;

-- ── (c2) get_location_investment_leaderboard — the seasonal score board for a location (public) ─────
create or replace function public.get_location_investment_leaderboard(
  p_location_id uuid,
  p_limit       int default 100
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int;
  v_idx   bigint;
  v_start timestamptz;
  v_end   timestamptz;
  v_rows  jsonb;
  c_empty constant jsonb := '[]'::jsonb;
begin
  -- DARK server-reject FIRST (before any read; identical envelope while dark).
  if not public.cfg_bool('location_investment_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- the location must exist (Map read).
  if p_location_id is null
     or not exists (select 1 from public.locations where id = p_location_id) then
    return jsonb_build_object('ok', false, 'code', 'unknown_location');
  end if;

  -- clamp the limit: default 100 (signature default), floor 1, hard cap 500 (the 0131 clamp).
  v_limit := least(greatest(coalesce(p_limit, 100), 1), 500);

  -- the current season window, from the ONE shared helper.
  select w.window_index, w.window_start, w.window_end
    into v_idx, v_start, v_end
    from public.location_investment_current_window() w;

  -- rank players by their SUM of contributions to this location WITHIN the window (score desc,
  -- player_id tiebreak — stable), 1-based row_number() rank. Derived at read time; no stored row.
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank',         r.rank,
           'player_id',    r.player_id,
           'season_score', r.season_score) order by r.rank),
         c_empty)
    into v_rows
    from (
      select li.player_id,
             sum(li.amount) as season_score,
             row_number() over (order by sum(li.amount) desc, li.player_id) as rank
        from public.location_investments li
        where li.location_id = p_location_id
          and li.invested_at >= v_start and li.invested_at < v_end
        group by li.player_id
        order by sum(li.amount) desc, li.player_id
        limit v_limit
    ) r;

  return jsonb_build_object('ok', true,
    'location_id', p_location_id,
    'window_index', v_idx,
    'window_start', v_start,
    'window_end', v_end,
    'rows', coalesce(v_rows, c_empty));
end;
$$;

-- ── (c3) get_my_location_investments — the caller's OWN contribution history (authenticated) ───────
create or replace function public.get_my_location_investments()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_rows   jsonb;
  c_empty  constant jsonb := '[]'::jsonb;
begin
  -- DARK server-reject FIRST (identical envelope regardless of caller state — anti-probe).
  if not public.cfg_bool('location_investment_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated');
  end if;

  -- read-only: ONLY the caller's own rows (query-scoped player_id = auth.uid(), defense in depth over
  -- the 0132 owner-read RLS), joined to locations for display identity (name). Newest first, uuid
  -- tiebreak for determinism. Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'investment_id', li.investment_id,
           'location_id',   li.location_id,
           'location_name', l.name,
           'amount',        li.amount,
           'invested_at',   li.invested_at) order by li.invested_at desc, li.investment_id),
         c_empty)
    into v_rows
    from public.location_investments li
    join public.locations l on l.id = li.location_id
    where li.player_id = v_player;

  return jsonb_build_object('ok', true, 'rows', coalesce(v_rows, c_empty));
end;
$$;

-- ── (d) ACL — the 0131 posture. Location/leaderboard reads are PUBLIC (anon + authenticated); own
--       history is authenticated-only; the window helper stays internal (revoked above). Dark today:
--       every gate rejects while location_investment_enabled = 'false'. ──────────────────────────────
revoke execute on function public.get_location_development(uuid) from public, anon;
grant  execute on function public.get_location_development(uuid) to anon, authenticated;
revoke execute on function public.get_location_investment_leaderboard(uuid, int) from public, anon;
grant  execute on function public.get_location_investment_leaderboard(uuid, int) to anon, authenticated;
revoke execute on function public.get_my_location_investments() from public, anon;
grant  execute on function public.get_my_location_investments() to authenticated;
