-- Byeharu — RANKING-P17 SLICE 2: the season-management writer — `ranking_season_open`, the SOLE
-- writer of `ranking_seasons` (0127). PRIVATE, SECURITY DEFINER, service-role-only, DARK behind
-- `ranking_enabled=false` (0127). NO standings scoring, NO read RPC, NO player wrapper, NO frontend
-- this slice.
--
-- Phase 17 "Ranking / competition … reset by season, not deletion" (ROADMAP :92). This is the
-- lifecycle writer that OPENS a season window (and closes the prior active one of the same cadence
-- to uphold the one-active-per-cadence invariant). Season management is a server/cron/admin
-- operation — NOT a player command — so unlike 0126's recruit_captain there is NO authenticated
-- public wrapper: the function stays service-role-only and dark. It answers a jsonb envelope
-- (`{ok, code?, …}`) directly (no reason→code translation layer needed without a client wrapper).
--
-- IDIOM SOURCES (inherited from 0126 production_recruit_captain — the dark SECURITY DEFINER writer):
--   · DARK GATE FIRST — `cfg_bool('ranking_enabled')` false → reject before any read/write
--     (0126:114–116 / the 0097/0102 reject-before-any-read + anti-probe law: a dark feature answers
--     identically regardless of input).
--   · pg_advisory_xact_lock(hashtext(<domain>), hashtext(<scope>)) before the read/write so concurrent
--     opens of the SAME cadence serialize (0126:129 idiom, scope = cadence not player).
--   · idempotent replay from a NATURAL KEY (here (cadence, starts_at), added below as a unique index)
--     instead of a receipts table — season windows ARE their own idempotency key, so no per-request
--     receipt ledger is needed (0126 used (player, request_id); a season lifecycle op is keyed by its
--     window, not a client request).
--   · service-role-only ACL — revoke execute from public/anon/authenticated; grant to service_role
--     (0126:273–274 private-writer block).
--   · `cfg_bool(p_key text) returns boolean` (0046; coalesces a missing key to false) — the shared
--     Reference/Config flag-read leaf, read DOWNWARD (the only cross-system edge this writer adds).
--
-- LOCKED-DECISION ENFORCEMENT (Phase-17 design; DEV_LOG 2026-07-04 SLICES 0–1):
--   · SOLE WRITER of ranking_seasons. This is the concrete function the 0127 §1/§2 "future season fn"
--     note promised — no second write path to the table, ever.
--   · RESET BY SEASON, NEVER BY DELETION. Opening a new active window CLOSES the prior active one
--     (status 'active' → 'closed') — it NEVER deletes it, and the standings rows accrued under the
--     closed season_id remain intact (a closed season is queryable history; a "reset" is the NEW
--     active season scoping a fresh standings set). No DELETE of any season or event data anywhere.
--   · ONE ACTIVE PER CADENCE. The close-prior step makes room for the new active row before the
--     partial unique index `ranking_seasons_one_active_per_cadence` (0127) is checked; the advisory
--     lock serializes same-cadence opens so the close→insert window cannot be raced. If a race still
--     trips a unique index, the insert is guarded and surfaces a clean `{ok:false, code:'conflict'}`
--     rather than a raw exception.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): ranking_seasons' sole writer is now
-- the CONCRETE `ranking_season_open` (was "future season fn"). NEW edge, DOWNWARD: Ranking →
-- Reference/Config (`cfg_bool` read) — acyclic, nothing calls into Ranking. Standings scoring and the
-- read RPC remain later slices. No flag flipped; `0001–0128` unedited; forward-only.

-- ── 1) idempotency natural key — a season window is unique per (cadence, starts_at) ───────────────
-- NEW index in a NEW migration (0127 is never edited). Full unique (not partial): a given cadence can
-- have at most one season starting at a given instant — the natural key that lets season-open be
-- idempotent WITHOUT a receipts table.
create unique index ranking_seasons_cadence_start_uidx
  on public.ranking_seasons (cadence, starts_at);

-- ── 2) ranking_season_open — PRIVATE, SECURITY DEFINER; THE SOLE writer of ranking_seasons ────────
create or replace function public.ranking_season_open(
  p_cadence   text,
  p_starts_at timestamptz,
  p_ends_at   timestamptz,
  p_label     text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row     ranking_seasons%rowtype;
  v_id      uuid;
  v_created timestamptz;
begin
  -- 1) DARK GATE FIRST (0127 law / 0126:114–116 idiom): while ranking_enabled is false, reject
  --    deterministically BEFORE any read or write — no season read, no close, no insert.
  if not public.cfg_bool('ranking_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- 2) pure input validation (no reads yet). Codes are returned directly — no client wrapper exists.
  if p_cadence is null or p_cadence not in ('weekly', 'monthly') then
    return jsonb_build_object('ok', false, 'code', 'invalid_cadence');
  end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    return jsonb_build_object('ok', false, 'code', 'invalid_window');
  end if;
  -- non-empty label; sanity length cap (the 0126:121 text-bound hygiene — a label is a display
  -- string, never an unbounded payload).
  if p_label is null or btrim(p_label) = '' or length(p_label) > 200 then
    return jsonb_build_object('ok', false, 'code', 'invalid_label');
  end if;

  -- 3) per-cadence serialization BEFORE the read/write (0126:129 advisory-lock idiom, scope =
  --    cadence): concurrent opens of the SAME cadence queue here, so the replay check and the
  --    close-prior → insert-new window below cannot be raced by another open of this cadence.
  perform pg_advisory_xact_lock(hashtext('ranking_season_open'), hashtext(p_cadence));

  -- 4) IDEMPOTENT REPLAY from the natural key (cadence, starts_at): if this window already exists,
  --    return it VERBATIM — NO second insert, NO status churn (a re-open of an already-closed window
  --    does NOT reactivate it; the window's identity and its accrued standings are preserved).
  select * into v_row from ranking_seasons
    where cadence = p_cadence and starts_at = p_starts_at;
  if found then
    return jsonb_build_object('ok', true, 'idempotent', true,
      'season_id', v_row.season_id, 'cadence', v_row.cadence, 'label', v_row.label,
      'starts_at', v_row.starts_at, 'ends_at', v_row.ends_at, 'status', v_row.status,
      'created_at', v_row.created_at);
  end if;

  -- 5) open a NEW active window. Close the prior active season of this cadence FIRST (reset by
  --    season, NOT deletion — its standings rows remain under the closed season_id), making room for
  --    the partial unique active index, then insert the new active row. A unique-index race is
  --    guarded into a clean 'conflict' envelope rather than a raw exception.
  begin
    update ranking_seasons
      set status = 'closed'
      where cadence = p_cadence and status = 'active';

    insert into ranking_seasons (cadence, label, starts_at, ends_at, status)
      values (p_cadence, p_label, p_starts_at, p_ends_at, 'active')
      returning season_id, created_at into v_id, v_created;
  exception
    when unique_violation then
      return jsonb_build_object('ok', false, 'code', 'conflict');
  end;

  return jsonb_build_object('ok', true, 'idempotent', false,
    'season_id', v_id, 'cadence', p_cadence, 'label', p_label,
    'starts_at', p_starts_at, 'ends_at', p_ends_at, 'status', 'active',
    'created_at', v_created);
end;
$$;

-- ── 3) ACL (anti-cheat; the 0126:273–274 private-writer block — the 0064-era default-privileges
--       revoke already denies new functions, this re-asserts explicitly). No public wrapper this
--       slice: season management is a server/cron/admin operation, not a player command, so the
--       writer stays OFF the client surface entirely.
revoke execute on function public.ranking_season_open(text, timestamptz, timestamptz, text) from public, anon, authenticated;
grant  execute on function public.ranking_season_open(text, timestamptz, timestamptz, text) to service_role;
