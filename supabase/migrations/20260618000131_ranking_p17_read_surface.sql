-- Byeharu — RANKING-P17 SLICE 4: the dark read surface — get_ranking_seasons() +
-- get_ranking_leaderboard(season, dimension, limit). Read-only; no write anywhere; dark-gated like
-- every Ranking surface. Mirrors the 0123/0116 read-surface idiom: jsonb envelope · stable ·
-- security definer · dark gate on `ranking_enabled` BEFORE any row read (the identical
-- {ok:false, code:'feature_disabled'} for every caller — anti-probe: nothing renders until
-- activation) · SELECTs from Ranking's OWN public tables only. NO new table, NO writer, NO frontend,
-- NO cron, NO flag flip this slice.
--
-- Divergence from the captain read surface (0123) — DELIBERATE, grounded:
--   · PUBLIC leaderboards. `ranking_seasons` (0127) and `ranking_standings` (0128) carry public-read
--     policies granted to anon + authenticated (leaderboards/season info are public reads, not
--     per-player own-data). So these RPCs are granted to anon + authenticated (not authenticated-only
--     like the captain own-roster surface), and carry NO auth.uid() check / NO per-player scoping —
--     the data they expose is already public.
--   · Envelope key `code` (not `reason`) — consistent with the Ranking writers (0129/0130), which all
--     answer `{ok, code?}`.
--
-- OVERALL is DERIVED AT READ TIME (the slice-1 Must-NOT — never a stored denormalized row):
-- get_ranking_leaderboard('…','overall',…) sums a player's per-dimension scores across the season on
-- the fly. No write, no second source of truth.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): read-only functions — NO new writer,
-- NO new table, so the §1 matrix is UNCHANGED (the 0101/0106/0110/0116/0123 precedent: read surfaces
-- live in the §2 system row, not the matrix). The §2 Ranking row gains both functions. No new
-- cross-system edge: they read only Ranking's own tables + `cfg_bool` (Reference/Config) — the graph
-- stays acyclic, nothing calls into Ranking. No flag flipped; `0001–0130` unedited; forward-only.

-- ── 1) get_ranking_seasons — the browsable season list (public; dark-gated) ───────────────────────
create or replace function public.get_ranking_seasons()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_seasons jsonb;
  c_empty   constant jsonb := '[]'::jsonb;
begin
  -- DARK server-reject FIRST (0127 law; the 0123/0116 read idiom): before any row read, and the
  -- identical envelope for every caller — no probing while dark.
  if not public.cfg_bool('ranking_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- read-only: the public season list (no per-player scoping — leaderboard/season info is public).
  -- Ordered by cadence then newest window first (active naturally sorts to the top within a cadence).
  select coalesce(jsonb_agg(jsonb_build_object(
           'season_id', s.season_id,
           'cadence',   s.cadence,
           'label',     s.label,
           'starts_at', s.starts_at,
           'ends_at',   s.ends_at,
           'status',    s.status) order by s.cadence, s.starts_at desc),
         c_empty)
    into v_seasons
    from public.ranking_seasons s;

  return jsonb_build_object('ok', true, 'seasons', coalesce(v_seasons, c_empty));
end;
$$;

-- ── 2) get_ranking_leaderboard — one season's ranked board for a dimension (public; dark-gated) ───
create or replace function public.get_ranking_leaderboard(
  p_season_id uuid,
  p_dimension text,
  p_limit     int default 100
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int;
  v_rows  jsonb;
  c_empty constant jsonb := '[]'::jsonb;
begin
  -- DARK server-reject FIRST (before any read; identical envelope while dark).
  if not public.cfg_bool('ranking_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- pure input validation (reject before the season read). 'overall' is derived at read time; the
  -- four concrete dimensions are the slice-1 1:1 reward_grants.source_type domain.
  if p_dimension is null
     or p_dimension not in ('combat', 'trade', 'exploration', 'mining', 'overall') then
    return jsonb_build_object('ok', false, 'code', 'invalid_dimension');
  end if;

  -- the season must exist (a foreign/missing season answers one truthful reason).
  if p_season_id is null
     or not exists (select 1 from public.ranking_seasons where season_id = p_season_id) then
    return jsonb_build_object('ok', false, 'code', 'unknown_season');
  end if;

  -- clamp the limit into a sane range: default 100 (the signature default), floor 1, hard cap 500.
  v_limit := least(greatest(coalesce(p_limit, 100), 1), 500);

  if p_dimension = 'overall' then
    -- OVERALL derived at read time: sum a player's per-dimension scores across the season. NEVER a
    -- stored row (slice-1 Must-NOT). rank by summed score desc, player_id tiebreak (stable).
    select coalesce(jsonb_agg(jsonb_build_object(
             'rank',           r.rank,
             'player_id',      r.player_id,
             'score',          r.score,
             'events_counted', r.events_counted) order by r.rank),
           c_empty)
      into v_rows
      from (
        select player_id,
               sum(score)          as score,
               sum(events_counted) as events_counted,
               row_number() over (order by sum(score) desc, player_id) as rank
          from public.ranking_standings
          where season_id = p_season_id
          group by player_id
          order by sum(score) desc, player_id
          limit v_limit
      ) r;
  else
    -- a concrete dimension board: the standings rows for that (season, dimension), ranked.
    select coalesce(jsonb_agg(jsonb_build_object(
             'rank',           r.rank,
             'player_id',      r.player_id,
             'score',          r.score,
             'events_counted', r.events_counted) order by r.rank),
           c_empty)
      into v_rows
      from (
        select player_id, score, events_counted,
               row_number() over (order by score desc, player_id) as rank
          from public.ranking_standings
          where season_id = p_season_id and dimension = p_dimension
          order by score desc, player_id
          limit v_limit
      ) r;
  end if;

  return jsonb_build_object('ok', true,
    'season_id', p_season_id, 'dimension', p_dimension,
    'rows', coalesce(v_rows, c_empty));
end;
$$;

-- ── 3) ACL (the 0123 read-surface idiom, adjusted for PUBLIC leaderboards): strip the default
--       PUBLIC grant, then grant anon + authenticated (leaderboards are public — the ranking_seasons
--       /ranking_standings public-read posture, 0127/0128). Dark today: the gates above reject every
--       call while ranking_enabled = 'false'.
revoke execute on function public.get_ranking_seasons() from public, anon;
grant  execute on function public.get_ranking_seasons() to anon, authenticated;
revoke execute on function public.get_ranking_leaderboard(uuid, text, int) from public, anon;
grant  execute on function public.get_ranking_leaderboard(uuid, text, int) to anon, authenticated;
