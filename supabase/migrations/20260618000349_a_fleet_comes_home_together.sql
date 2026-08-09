-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0349 — A FLEET COMES HOME TOGETHER
--        a parked fleet is a fleet; a concluded sortie stops speaking; and the manifest that had
--        a beginning and no end now has one
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- THE OWNER'S BUG REPORT, VERBATIM: "when i retreated after my hp was set during combat, 5 ships,
-- 4 of them went to haven and 1 to slagwork. WTF?" — and, on the class: "Everything is messed up
-- when we make or change one thing, spaghetti. What is the point of having law and rules?"
--
-- ── THE CHAIN, MEASURED AGAINST PRODUCTION (read-only, 2026-08-09) ───────────────────────────────
-- 1. A retreat, an ambush park, or a stop leaves the group fleet `status='idle'` in open space.
--    fleet_set_in_space writes exactly that, and its own comment says why: "status 'idle' (not
--    'present'): 'present' means docked at a location and carries a location_presence row; open
--    space has no presence to create."  (0231:1146; deployed body confirmed byte-identical.)
-- 2. The retreat marks the surviving members `main_ship_instances.status='returning'` (0299:623).
-- 3. process_mainship_expeditions — cron jobid 7, EVERY 30 SECONDS — asks "does this ship still
--    have a fleet?" with two hand-written IN-lists, both `('moving','present','returning')`
--    (0199:566-580). **'idle' is in NEITHER.** So a fleet parked in open space reads as NO FLEET
--    AT ALL and every one of its members is declared an orphan.
-- 4. Each orphan goes to nohome_dock_returning_ship, PER SHIP. That function resolved a return port
--    from (a) the ship's own main_ship_id-tagged fleet with a non-null return_location_id, else
--    (b) its group_sortie_members manifest → that fleet's return_location_id. BOTH ended in
--    `order by updated_at desc limit 1`, with NO status filter and NO recency filter at all.
-- 5. group_sortie_members was NEVER pruned. Measured on production this morning: 77 rows over 23
--    distinct fleets, and **ZERO of the 77 point at a live fleet** — 46 rows on 'completed' fleets,
--    31 on 'destroyed' ones. group_sortie_release, the only deleter, is called from exactly two
--    places in the whole schema (command_ship_group_stop 0330:1248, and the ambush re-freeze
--    0308:381) and from neither of them when a sortie simply ENDS.
--
-- THE OWNER'S 4-AND-1, REPRODUCED BY RUNNING THE DEPLOYED FUNCTION'S OWN TWO QUERIES PER SHIP:
--     ship          step (a)   step (b) → port     source fleet   source last written
--     Sparrow       NULL       Haven               destroyed      2026-07-22 03:51
--     Sparrow II    NULL       SLAGWORKS           destroyed      2026-07-22 06:07
--     Sparrow III   NULL       Haven               destroyed      2026-07-22 03:51
--     Sparrow IV    NULL       Haven               destroyed      2026-07-22 03:51
-- On 2026-07-22 Sparrow II happened to be on a DIFFERENT sortie, whose fleet recorded Slagworks;
-- the other four were on one that recorded Haven. Both fleets were destroyed that day and their
-- roster rows were never deleted. SEVENTEEN DAYS LATER those two corpses decided where the owner's
-- ships docked — one of them somewhere else. The reconciler also fired MID-FIGHT at 23:11:26,
-- docking four ships twenty-one seconds into a forty-wave battle.
--
-- ── WHY THIS IS THE SPAGHETTI THE OWNER IS NAMING, AND WHERE THE ONE AUTHORITY GOES ──────────────
-- The un-ended roster has already been paid for TWICE, at the READ sites, by migrations whose own
-- comments say so:
--   * 0305, in send_ship_group_hunt: "This copy was a bare EXISTS over group_sortie_members — no
--     join, no scope — i.e. 'has this fleet EVER been on a sortie'. It is gone."
--   * 0308, in combat_create_group_encounter: "The raw join read EVERY group_sortie_members row for
--     the fleet — no msi.group_id filter, no liveness of any kind — so rows left over from a
--     CONCLUDED sortie …"
-- Two readers each grew their own defence against the same rot, and a third reader
-- (nohome_dock_returning_ship) never grew one — so it is the one that scattered the fleet. That is
-- the disease exactly: N readers defending against a fact nobody owns. This file does not add a
-- fourth defence. It gives the fact ONE owner, and one END.
--
-- ── WHAT THIS FILE DOES — TWO PREDICATES, ONE KNOB, TWO RE-EMITTED FUNCTIONS, ONE BACKFILL ───────
--
-- §1  public.fleet_is_live(status)                — "is this still a fleet ships belong to?"
--     public.fleet_sortie_still_speaks(status, updated_at)
--                                                 — "is this fleet's recorded return port still the
--                                                    one a returning ship should believe?"
--     ONE named predicate each, composed by every call site. No caller re-spells the vocabulary.
--
--     fleet_is_live IS DEFINED AS THE COMPLEMENT OF THE TERMINAL SET, NOT AS AN ALLOW-LIST, AND
--     THAT DIRECTION IS THE WHOLE POINT. An allow-list that missed one value is this entire bug. A
--     complement means a status added tomorrow reads as LIVE by default, so the worst a future
--     omission can do is decline to reconcile a ship — never scatter a fleet. Self-assert (a) pins
--     the classification against the fleets_status_check CHECK's own enumeration, read out of the
--     catalog rather than typed here, so a seventh status cannot land unnoticed.
--
-- §2  sortie_manifest_ttl_seconds — the threshold as DATA (3600). ONE number governs BOTH halves:
--     how long a concluded sortie's recorded return port still speaks, AND how long its manifest
--     rows are kept. That identity is deliberate and is pinned by self-assert (f): a row that could
--     still be read is never deleted, and a row that is deleted could no longer have been read.
--     There is no window in which the two disagree, so there is no seam between them.
--
-- §3  process_mainship_expeditions — re-emitted. All SIX hand-written IN-lists (three in the lit
--     NOHOME path, three in the retained 0198 dark head) become public.fleet_is_live(...). The dark
--     head is NOT deleted here: retiring a superseded path is its own slice by the no-spaghetti
--     law, and doing it inside a live-bug fix would smuggle a second change past the same review.
--     It is left composing the SAME one predicate so it cannot drift on its own. Named as the
--     follow-up: retire the 0198 re-home head and the launch_from_dock_enabled read with it.
--     The function also gains the ROSTER REAP — the manifest's missing END — which composes
--     group_sortie_release rather than writing its own DELETE, so that leaf remains the sole
--     deleter of group_sortie_members and the harnesses' sole-writer grep keeps its meaning.
--
-- §4  nohome_dock_returning_ship — re-emitted. Steps (a) and (b) now require
--     fleet_sortie_still_speaks and order by public.fleet_is_live(...) desc, updated_at desc, id
--     desc: a LIVE source is preferred over any corpse, a corpse is heard only inside the TTL, and
--     the tie-break is TOTAL so `select … into` cannot silently take a different first row on a
--     different day. A ship whose only records are stale re-homes — it never fabricates a port.
--     The H1 fleet-reuse read is also fenced with fleet_is_live: production carries FOUR
--     main_ship_id-tagged fleets at status='destroyed', and the unfenced read could re-present one
--     of them, resurrecting a fleet its owner had already lost.
--
-- §5  the backfill — snapshot into public.group_sortie_members_retired_0349, THEN release. All 77
--     production rows qualify (every one of them is on a terminal fleet last written between
--     2026-07-18 and 2026-08-08, i.e. hours-to-weeks past the TTL). The snapshot is a literal undo;
--     the table comment carries the exact INSERT that restores it.
--
-- ── WHY THE MANIFEST IS RELEASED ON A TTL RATHER THAN AT THE INSTANT THE FLEET GOES TERMINAL ─────
-- Because the repo's own proof suite says the instant is wrong, and it says so twice:
--   * scripts/team-command-proof.sql:2412 — a completed sortie's manifest rows must still be there
--     after the reconciler runs;
--   * scripts/team-command-proof.sql:2584 — BLOCK CAPXP's precondition is "…its sortie manifest is
--     exactly {c1, c2}" for a sortie whose fleet is ALREADY 'completed'. captain_xp_accrue
--     (cron jobid 13, every 5 minutes) reaches the ships that earned a combat reward through
--     `join group_sortie_members gsm on gsm.fleet_id = ce.fleet_id`; for a TEAM sortie that join is
--     the only branch that matches, because a group fleet carries main_ship_id NULL.
-- Deleting at the transition would therefore silently drop captain XP for any group fight whose
-- fleet went terminal inside the accrual window. Production is inert to that today (0 captain
-- instances, 0 assignments, 0 credited grants — measured), but shipping a latent silent loss to fix
-- a visible one is not a fix. The TTL is the smallest change that ends the roster without opening
-- that hole: 3600s is 12× the 300s accrual period and 120× the 30s reconciler period, so a
-- concluded sortie always outlives every reader that legitimately wants it — and it is 408× tighter
-- than the seventeen-day corpse that produced the owner's bug.
--
-- ── WHAT HAPPENS TO A SHIP THAT IS MID-FLIGHT, MID-FIGHT OR MID-RETREAT WHEN THIS APPLIES ────────
-- Nothing, and each for its own reason.
--   * MID-FLIGHT: its fleet is 'moving' — live before this file and live after; the orphan
--     predicate excluded it then and excludes it now.
--   * MID-FIGHT: its fleet is 'present' (docked hunt) or 'idle' in open space (an ambush park).
--     'present' was already live. 'idle' was NOT, and that is the defect: mid-fight docking is
--     precisely what production recorded at 23:11:26. After this file the fight is left alone.
--     THE CHANGE CAN ONLY EVER REMOVE SHIPS FROM THE ORPHAN SET, NEVER ADD ANY — fleet_is_live is a
--     strict superset of the list it replaces — so no ship that the cron leaves alone today can
--     start being moved by it tomorrow.
--   * MID-RETREAT: the fleet is 'returning' (a leg home) or 'idle' (parked at the chosen
--     destination). Both live.
--   * A ship whose fleet genuinely ended: still reconciled, on the next 30-second pass, exactly as
--     before — but now to the port of the sortie it is actually returning from, or, if no record is
--     recent enough to be that sortie, re-homed rather than sent to a stranger's port.
-- The first cron pass after apply also releases 77 dead manifest rows. Nothing live reads them:
-- they are, measured, 0-for-77 on pointing at a live fleet, and this file has already deleted them
-- in §5 before the cron ever sees them.
--
-- ── ROLLBACK BOUNDARY ────────────────────────────────────────────────────────────────────────────
-- The whole file is ONE transaction. Any self-assert failure rolls back everything — both
-- predicates, the knob, both function bodies, the snapshot table and the backfill — and leaves the
-- deployed 0199 bodies exactly as they are; the chain head does not move. After a COMMITTED apply,
-- the manual undo is: restore the two 0199 bodies (this file changes only the marked hunks in each,
-- and the pre-image is verified byte-identical to migration 0199's own text — md5 9b10a6eb… and
-- 37bb39cf… for process_mainship_expeditions and nohome_dock_returning_ship respectively), then
-- `insert into public.group_sortie_members select fleet_id, main_ship_id, player_id, created_at
--  from public.group_sortie_members_retired_0349 on conflict do nothing;`, then drop the two
-- predicates and the knob row. No column is added, no column is dropped, no constraint changes and
-- no player-owned row is deleted — the only rows this file removes are manifest rows whose fleet
-- has been over for hours, and every one of them is copied out first.
--
-- ── EXPLICIT NON-GOALS ───────────────────────────────────────────────────────────────────────────
-- Not the location fold (one ship_presence authority retiring ~10 answerers) — mainship_port_of_ship,
-- mainship_resolve_docked_location, get_my_fleet_positions, assign_ship_to_group, the economy
-- consumers and the client are all untouched, and self-assert (g) pins that. Not a backfill of the
-- owner's currently-scattered ships — that is a separate, rehearsed operation. This file stops NEW
-- scatterings; it does not undo the old one.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;

-- ── §0 PRE-IMAGE for the metadata-parity assert (h) — the 0332 capture idiom, verbatim ───────────
create temp table _0349_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0349_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('process_mainship_expeditions', 'nohome_dock_returning_ship');

-- ═══ §1 THE TWO PREDICATES — one authority each ══════════════════════════════════════════════════

-- "Is this still a fleet that ships belong to?"  THE COMPLEMENT OF THE TERMINAL SET, on purpose:
-- a status added after this file reads as LIVE, so a future omission can only decline to reconcile
-- a ship, never scatter a fleet. NOT STRICT — a NULL status must answer false, not NULL, so that a
-- `not exists (… where fleet_is_live(status))` orphan probe stays fail-safe rather than fail-open.
create or replace function public.fleet_is_live(p_status text)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  select coalesce(p_status <> all (array['completed', 'destroyed']), false);
$$;
comment on function public.fleet_is_live(text) is
  '0349: THE ONE predicate for "this fleet still exists as a thing ships belong to". Composed by the '
  'reconciler''s orphan probes, by nohome_dock_returning_ship''s return-port resolution and fleet '
  'reuse, and by fleet_sortie_still_speaks. Defined as the complement of the terminal set so a new '
  'fleets.status defaults to LIVE — an allow-list that missed ''idle'' is the bug this file fixes.';
revoke execute on function public.fleet_is_live(text) from public, anon;
grant  execute on function public.fleet_is_live(text) to authenticated, service_role;

-- "Is this fleet's recorded return port still the one a returning ship should believe?"
-- A LIVE fleet always speaks — it IS the current sortie, however long the player has parked it. A
-- concluded one speaks only while it is recent enough to be the sortie the ship is coming back
-- from. The NaN guard is the 0198 idiom (a jsonb "NaN" knob must floor to the default, never
-- poison an interval).
create or replace function public.fleet_sortie_still_speaks(p_status text, p_updated_at timestamptz)
returns boolean
language sql
stable
parallel safe
set search_path = public
as $$
  select public.fleet_is_live(p_status)
      or (p_updated_at is not null
          and p_updated_at >= now() - make_interval(secs => greatest(0,
                coalesce(nullif(public.cfg_num('sortie_manifest_ttl_seconds'),
                                'NaN'::double precision), 3600))));
$$;
comment on function public.fleet_sortie_still_speaks(text, timestamptz) is
  '0349: THE ONE predicate for "this concluded sortie still has something to say". Governs BOTH the '
  'return-port resolution in nohome_dock_returning_ship AND the manifest reap in '
  'process_mainship_expeditions, off the same sortie_manifest_ttl_seconds knob — so a manifest row '
  'that can still be read is never deleted, and a deleted one could no longer have been read.';
revoke execute on function public.fleet_sortie_still_speaks(text, timestamptz) from public, anon;
grant  execute on function public.fleet_sortie_still_speaks(text, timestamptz) to authenticated, service_role;

-- ═══ §2 THE THRESHOLD, AS DATA ═══════════════════════════════════════════════════════════════════
insert into public.game_config (key, value, description)
values ('sortie_manifest_ttl_seconds', '3600'::jsonb,
        '0349: how long after a sortie fleet goes terminal its group_sortie_members manifest and its '
        'recorded return_location_id still speak. ONE number for both, so the reap can never delete a '
        'row a reader could still use. 3600 = 12x the 300s captain-XP accrual cron (jobid 13, the last '
        'reader of a concluded sortie''s manifest) and 120x the 30s reconciler cron (jobid 7); the '
        'corpse that misfiled the owner''s fleet was 17 DAYS old, so this is 408x tighter than the '
        'failure and still generous to every legitimate caller.')
on conflict (key) do update
  set value = excluded.value, description = excluded.description, updated_at = now();

-- ═══ §3 process_mainship_expeditions — the liveness omission, and the roster's missing END ═══════
-- Re-emitted from the 0199 head. That head's text was verified byte-identical to the DEPLOYED body
-- before this file was written (md5(prosrc) = 9b10a6ebd2595b62e5ee9a9b5c254d73 on production and on
-- the repo's own migration text), so "the repo" and "the engine" are the same pre-image here and
-- this is a true parity edit. CHANGED HUNKS, and nothing else:
--   [S1] the LIT NOHOME branch's two orphan probes            → public.fleet_is_live(...)
--   [S2] the retained 0198 dark head's two orphan probes      → public.fleet_is_live(...)
--   [S3] NEW: the roster reap, composing group_sortie_release
create or replace function public.process_mainship_expeditions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
  v_team  integer := 0;
  v_idle_raw double precision := coalesce(cfg_num('shield_regen_idle_pct'), 0);
  v_idle     double precision := greatest(0, case when v_idle_raw = 'NaN'::double precision then 0 else v_idle_raw end);
  -- NOHOME (0199): the gate, read once. Dark seed → false → the 0198 head runs verbatim.
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
  r          record;
  -- 0349 [S3]: the reap's cursor. Kept separate from r so neither loop can inherit the other's shape.
  rr         record;
begin
  if v_launch_from_dock then
    -- ── NOHOME (0199) DOCK-AT-RETURN reconcile — the SAME candidate sets as the 0198 head's two re-home
    --    branches, but each ship is DOCKED at its fleet's recorded return port (or re-homed if none). ──
    -- (1) main-ship fleets out (traveling/returning) with no live tagged fleet AND no live manifest fleet
    --     (the 0198 `homed` predicate + D3 member guard).
    -- ★ 0349 [S1]: the two liveness tests were hand-written `status in ('moving','present','returning')`.
    -- ★ 'idle' — the status fleet_set_in_space writes for a fleet PARKED IN OPEN SPACE after a retreat,
    -- ★ an ambush or a stop — was in neither list, so a parked fleet read as no fleet at all and every
    -- ★ member of it was declared an orphan and docked, mid-fight, at whatever port an old corpse named.
    -- ★ Both tests now compose the ONE predicate; neither spells the vocabulary again.
    for r in
      select s.main_ship_id
        from main_ship_instances s
        where s.status in ('traveling','returning')
          and not exists (
            select 1 from fleets f
            where f.main_ship_id = s.main_ship_id and public.fleet_is_live(f.status))
          and not exists (
            select 1 from group_sortie_members gsm
            join fleets gf on gf.id = gsm.fleet_id
            where gsm.main_ship_id = s.main_ship_id and public.fleet_is_live(gf.status))
    loop
      perform public.nohome_dock_returning_ship(r.main_ship_id);
      v_count := v_count + 1;
    end loop;

    -- (2) 'hunting' zombies whose manifest fleet is finished (the 0198 `team_homed` predicate).
    for r in
      select s.main_ship_id
        from main_ship_instances s
        where s.status = 'hunting'
          and not exists (
            select 1 from group_sortie_members gsm
            join fleets gf on gf.id = gsm.fleet_id
            where gsm.main_ship_id = s.main_ship_id and public.fleet_is_live(gf.status))
    loop
      perform public.nohome_dock_returning_ship(r.main_ship_id);
      v_team := v_team + 1;
    end loop;
  else
    -- ── 0198 HEAD (DARK path — the 0198 body, with 0349's [S2] hunk applied to its two orphan probes
    --    for the same reason as [S1]: a superseded path that keeps its own copy of the vocabulary is a
    --    second authority, and the next person to widen the list would widen only one of them. The
    --    RETIREMENT of this branch is a separate slice; sharing the predicate is not. ────────────────
    with homed as (
      update main_ship_instances s
        set status = 'home', updated_at = now()
        where s.status in ('traveling','returning')
          and not exists (
            select 1 from fleets f
            where f.main_ship_id = s.main_ship_id
              and public.fleet_is_live(f.status)
          )
          and not exists (
            select 1 from group_sortie_members gsm
            join fleets gf on gf.id = gsm.fleet_id
            where gsm.main_ship_id = s.main_ship_id
              and public.fleet_is_live(gf.status)
          )
        returning 1)
    select count(*) into v_count from homed;

    with team_homed as (
      update main_ship_instances s
        set status = 'home', updated_at = now()
        where s.status = 'hunting'
          and not exists (
            select 1 from group_sortie_members gsm
            join fleets gf on gf.id = gsm.fleet_id
            where gsm.main_ship_id = s.main_ship_id
              and public.fleet_is_live(gf.status)
          )
        returning 1)
    select count(*) into v_team from team_homed;
  end if;

  -- ── 0349 [S3] THE ROSTER REAP — the END group_sortie_members never had ──────────────────────────
  -- send_ship_group_hunt (and the ambush re-freeze) WRITE the manifest; until now nothing removed a
  -- row when the sortie it describes was over, so production accumulated 77 rows across 23 fleets,
  -- none of them pointing at a live fleet, and one of them decided where the owner's ship docked
  -- seventeen days later.
  -- The condition is the EXACT NEGATION of what nohome_dock_returning_ship is willing to read, off
  -- the same knob and the same predicate — so this can only ever delete a row that no reader could
  -- have used, and can never delete one that a reader could. Self-assert (f) pins that identity.
  -- It COMPOSES group_sortie_release rather than writing its own delete: that leaf stays the sole
  -- deleter of the manifest, which is what makes the harnesses' sole-writer grep mean anything.
  -- Placement is order-independent: every row it removes is already invisible to both loops above
  -- (their probes require fleet_is_live, which this predicate excludes), and now() is frozen for the
  -- whole transaction, so no row can be inside the window for one and outside it for the other.
  for rr in
    select distinct gsm.player_id as player_id, gsm.fleet_id as fleet_id
      from group_sortie_members gsm
      join fleets f on f.id = gsm.fleet_id
     where not public.fleet_sortie_still_speaks(f.status, f.updated_at)
  loop
    perform public.group_sortie_release(rr.player_id, rr.fleet_id);
  end loop;

  -- ── SHIELD-2 (0197) HUNK — out-of-combat idle shield regen (runs in BOTH paths; flag 0 → skipped). ──
  if v_idle > 0 then
    update main_ship_instances s
      set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer),
          updated_at = now()
      where s.shield < s.max_shield
        and s.status <> 'destroyed'
        and not exists (
          select 1 from combat_units cu
          join combat_encounters ce on ce.id = cu.encounter_id
          where cu.main_ship_id = s.main_ship_id
            and ce.status in ('active','retreating')
        );
  end if;

  -- Unchanged on purpose: the return value counts SHIPS RECONCILED. The reap is housekeeping, not a
  -- reconciliation, and folding it in would change a number other callers read.
  return v_count + v_team;
end;
$$;

-- ═══ §4 nohome_dock_returning_ship — the resolver stops reading corpses ══════════════════════════
-- Re-emitted from the 0199 head, verified byte-identical to the deployed body before this file was
-- written (md5(prosrc) = 37bb39cfd2673f7aa37c6989ddc5ae41 on production and on the repo's own
-- migration text). CHANGED HUNKS, and nothing else:
--   [R1] step (a) — the ship's own tagged fleet:  TTL fence + total ordering
--   [R2] step (b) — the sortie manifest:          TTL fence + total ordering
--   [R3] H1 fleet reuse:                          never reuse a terminal fleet
create or replace function public.nohome_dock_returning_ship(p_main_ship_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid;
  v_return   uuid;
  v_fleet    uuid;   -- the ship's OWN main_ship_id-tagged fleet that will host its docked presence
  v_loc      record;
begin
  -- Return port + owner: the ship's own tagged fleet first (a single expedition), then its manifest (a
  -- team hunt member — the SHARED team fleet carries the recorded port, never the member's own fleet).
  --
  -- ★ 0349 [R1]/[R2]. BOTH reads were `order by updated_at desc limit 1` with no status filter and no
  -- ★ recency filter, so the newest record WITH a return port won — even a fleet destroyed seventeen
  -- ★ days earlier, on a sortie this ship is not returning from. That is how four ships went to Haven
  -- ★ and the fifth to Slagworks: two different corpses, from two different old sorties, both still
  -- ★ on the roster. Three changes, identical in both steps:
  -- ★   • fleet_sortie_still_speaks — a LIVE fleet always speaks; a concluded one only inside the TTL;
  -- ★   • fleet_is_live FIRST in the ordering — a live source is preferred over any corpse, so the
  -- ★     resolver reads a dead fleet only when there is no live one to read;
  -- ★   • a TOTAL tie-break (…, f.id desc) — `select … into` takes the first row SILENTLY, and two
  -- ★     rows sharing a timestamp must not be able to answer differently on different days.
  -- ★ If nothing is recent enough, v_return stays NULL and the ship RE-HOMES below. Fail-closed: a
  -- ★ ship with only stale records is left where it is, never sent to a stranger's port.
  select f.player_id, f.return_location_id into v_player, v_return
    from fleets f
    where f.main_ship_id = p_main_ship_id and f.return_location_id is not null
      and public.fleet_sortie_still_speaks(f.status, f.updated_at)
    order by public.fleet_is_live(f.status) desc, f.updated_at desc, f.id desc
    limit 1;
  if v_return is null then
    select gf.player_id, gf.return_location_id into v_player, v_return
      from group_sortie_members gsm
      join fleets gf on gf.id = gsm.fleet_id
      where gsm.main_ship_id = p_main_ship_id and gf.return_location_id is not null
        and public.fleet_sortie_still_speaks(gf.status, gf.updated_at)
      order by public.fleet_is_live(gf.status) desc, gf.updated_at desc, gf.id desc
      limit 1;
  end if;

  -- No recorded return port → legacy re-home (the 0198 head write shape: status only).
  if v_return is null then
    update main_ship_instances set status = 'home', updated_at = now() where main_ship_id = p_main_ship_id;
    return;
  end if;
  if v_player is null then
    select player_id into v_player from main_ship_instances where main_ship_id = p_main_ship_id;
  end if;

  -- Return port must still be an active location; else fail safe to re-home.
  select l.id, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = v_return and l.status = 'active';
  if v_loc.id is null then
    update main_ship_instances set status = 'home', updated_at = now() where main_ship_id = p_main_ship_id;
    return;
  end if;

  -- H1: give the ship its OWN main_ship_id-tagged present fleet at the return port. Reuse one already
  -- present there (idempotent), else the ship's most-recent tagged fleet (the member's dissolved docked
  -- fleet, or a single-send tagged fleet), else mint a fresh tagged present fleet.
  select id into v_fleet from fleets
    where main_ship_id = p_main_ship_id and player_id = v_player
      and status = 'present' and current_location_id = v_loc.id
    limit 1;
  if v_fleet is null then
    -- ★ 0349 [R3]: this read had no status filter, so the "most-recent tagged fleet" it reused could be
    -- ★ a DESTROYED one — and the update below would re-present it, bringing back a fleet its owner had
    -- ★ already lost. Production carries FOUR main_ship_id-tagged fleets at status='destroyed', so this
    -- ★ was reachable, not theoretical. Reuse is now restricted to a live fleet; when there is none the
    -- ★ mint branch below (which already existed for exactly this case) runs instead. The tie-break is
    -- ★ made total for the same reason as [R1]/[R2].
    select id into v_fleet from fleets
      where main_ship_id = p_main_ship_id and player_id = v_player
        and public.fleet_is_live(status)
      order by updated_at desc, id desc limit 1;
  end if;
  if v_fleet is null then
    insert into fleets (player_id, status, location_mode, current_base_id,
                        current_location_id, current_zone_id, current_sector_id, main_ship_id)
      values (v_player, 'present', 'location', null, v_loc.id, v_loc.zone_id, v_loc.sector_id, p_main_ship_id)
      returning id into v_fleet;
  else
    update fleets
      set status = 'present', location_mode = 'location', active_movement_id = null, current_base_id = null,
          current_location_id = v_loc.id, current_zone_id = v_loc.zone_id, current_sector_id = v_loc.sector_id,
          return_location_id = null, updated_at = now()
      where id = v_fleet;
  end if;
  -- exactly one active presence for THIS ship's own fleet (each returned member gets its own).
  if not exists (select 1 from location_presence where fleet_id = v_fleet and status = 'active') then
    perform public.presence_create(v_player, v_fleet, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'none');
  end if;

  -- Ship → canonical docked pair (the ONE shared 0153 helper).
  perform public.mainship_mark_docked_at_location(p_main_ship_id);
end;
$$;

-- ═══ §5 THE BACKFILL — snapshot first, then release through the sole deleter ═════════════════════
create table if not exists public.group_sortie_members_retired_0349 (
  fleet_id             uuid        not null,
  main_ship_id         uuid        not null,
  player_id            uuid        not null,
  created_at           timestamptz not null,
  fleet_status_at_reap text        not null,
  fleet_updated_at     timestamptz,
  reaped_at            timestamptz not null default now(),
  primary key (fleet_id, main_ship_id)
);
comment on table public.group_sortie_members_retired_0349 is
  '0349 UNDO ARTIFACT — every group_sortie_members row this migration released, with the state of the '
  'fleet that made it releasable. Deliberately NOT foreign-keyed: its whole job is to outlive its '
  'referents. RESTORE WITH: insert into public.group_sortie_members (fleet_id, main_ship_id, player_id, '
  'created_at) select fleet_id, main_ship_id, player_id, created_at from '
  'public.group_sortie_members_retired_0349 on conflict do nothing;  This table is a one-shot record of '
  'the 0349 apply; the ongoing reap in process_mainship_expeditions does NOT write to it.';
-- Supabase project defaults GRANT ALL to anon/authenticated on every new public table (the 0254
-- lesson): ESTABLISH the lockdown by revoking, never merely assert it. RLS on with no policy at all,
-- so even a future grant cannot make a row readable.
alter table public.group_sortie_members_retired_0349 enable row level security;
revoke all on table public.group_sortie_members_retired_0349 from anon, authenticated;

insert into public.group_sortie_members_retired_0349
       (fleet_id, main_ship_id, player_id, created_at, fleet_status_at_reap, fleet_updated_at)
select gsm.fleet_id, gsm.main_ship_id, gsm.player_id, gsm.created_at, f.status, f.updated_at
  from public.group_sortie_members gsm
  join public.fleets f on f.id = gsm.fleet_id
 where not public.fleet_sortie_still_speaks(f.status, f.updated_at)
on conflict (fleet_id, main_ship_id) do nothing;

do $backfill$
declare rr record;
begin
  for rr in
    select distinct gsm.player_id as player_id, gsm.fleet_id as fleet_id
      from public.group_sortie_members gsm
      join public.fleets f on f.id = gsm.fleet_id
     where not public.fleet_sortie_still_speaks(f.status, f.updated_at)
  loop
    perform public.group_sortie_release(rr.player_id, rr.fleet_id);
  end loop;
end $backfill$;

-- ═══ SELF-ASSERTS — the whole file rolls back if any of these fails ══════════════════════════════

-- (a) THE PREDICATE CLASSIFIES THE WHOLE VOCABULARY, and the vocabulary is read out of the CHECK
--     rather than typed here. If a seventh fleets.status ever lands, this fails on the next apply
--     of any migration that carries this block — which is the only way a hand-maintained list stops
--     being able to rot silently.
do $a$
declare
  v_def  text;
  v_vals text[];
  v_v    text;
  v_live int := 0;
  v_dead int := 0;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint where conrelid = 'public.fleets'::regclass and conname = 'fleets_status_check';
  if v_def is null then
    raise exception '0349 ASSERT (a) FAIL: fleets_status_check is absent — the status vocabulary has no authority to check against';
  end if;
  select array_agg(m.parts[1] order by m.parts[1]) into v_vals
    from regexp_matches(v_def, '''([a-z_]+)''::text', 'g') as m(parts);
  if v_vals is null or array_length(v_vals, 1) <> 6 then
    raise exception '0349 ASSERT (a) FAIL: fleets_status_check admits % value(s) (want the 6 this file classifies: %). A status was added or removed and public.fleet_is_live was not revisited.',
      coalesce(array_length(v_vals, 1), 0), coalesce(array_to_string(v_vals, ','), '<none>');
  end if;
  foreach v_v in array v_vals loop
    if public.fleet_is_live(v_v) then v_live := v_live + 1; else v_dead := v_dead + 1; end if;
  end loop;
  if v_live <> 4 or v_dead <> 2 then
    raise exception '0349 ASSERT (a) FAIL: the predicate splits the vocabulary % live / % terminal (want 4 / 2)', v_live, v_dead;
  end if;
  -- named, both ways — a count alone would pass a predicate that classified the wrong four.
  if not (public.fleet_is_live('idle') and public.fleet_is_live('moving')
          and public.fleet_is_live('present') and public.fleet_is_live('returning')) then
    raise exception '0349 ASSERT (a) FAIL: a live status is classified terminal — ''idle'' being on the wrong side of this line IS the owner''s bug';
  end if;
  if public.fleet_is_live('completed') or public.fleet_is_live('destroyed') then
    raise exception '0349 ASSERT (a) FAIL: a terminal status is classified live';
  end if;
  -- fail-safe on the two shapes a caller can hand it that are not in the vocabulary at all
  if public.fleet_is_live(null) then
    raise exception '0349 ASSERT (a) FAIL: fleet_is_live(NULL) is true — an orphan probe would read a NULL-status fleet as live';
  end if;
  if not public.fleet_is_live('a_status_invented_after_0349') then
    raise exception '0349 ASSERT (a) FAIL: an unknown status reads as TERMINAL. The predicate must be the complement of the terminal set, so that a future omission declines to reconcile rather than scattering a fleet.';
  end if;
end $a$;

-- (b) NO HAND-WRITTEN FLEET-STATUS MEMBERSHIP SURVIVES IN THE TOUCHED FUNCTIONS.
--     This is the assert the brief asks for, and it is written so it CANNOT pass vacuously:
--       * a CONTROL string carrying the banned shape is counted first, and the block raises if the
--         counting expression fails to find it — so a zero on the real bodies means "absent", never
--         "the probe is broken";
--       * every zero-count is paired with a POSITIVE count on the same body (the ship-status
--         vocabulary, which legitimately remains, and the predicate itself), so an empty or missing
--         body cannot satisfy it either.
--     Scope note: it bans the four FLEET-ONLY literals. 'returning' and 'destroyed' are shared with
--     main_ship_instances.status, whose own IN-list ('traveling','returning') is correct and stays.
do $b$
declare
  v_ctl   text := 'where f.status in (''moving'',''present'',''returning'') and x = ''idle''';
  v_code  text;
  v_fn    text;
  v_tok   text;
  v_n     integer;
  v_pos   integer;
begin
  -- non-vacuity of the counting expression itself, on a control that MUST match
  foreach v_tok in array array['''moving''', '''present''', '''idle'''] loop
    v_n := (length(v_ctl) - length(replace(v_ctl, v_tok, ''))) / length(v_tok);
    if v_n < 1 then
      raise exception '0349 ASSERT (b) FAIL: the occurrence probe found 0 x % in a control string that demonstrably contains it — the probe is broken, so every zero-count below would be meaningless', v_tok;
    end if;
  end loop;

  foreach v_fn in array array['process_mainship_expeditions', 'nohome_dock_returning_ship'] loop
    select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_code is null or length(v_code) < 500 then
      raise exception '0349 ASSERT (b) FAIL: public.% is absent or implausibly short (% chars) — the zero-counts below would be vacuous', v_fn, coalesce(length(v_code), -1);
    end if;
    -- POSITIVE control on the real body: the ONE predicate is actually composed here.
    v_pos := (length(v_code) - length(replace(v_code, 'public.fleet_is_live(', ''))) / length('public.fleet_is_live(');
    if v_pos < 1 then
      raise exception '0349 ASSERT (b) FAIL: public.% composes public.fleet_is_live 0 times — the hunks did not land', v_fn;
    end if;
    foreach v_tok in array array['''moving''', '''completed''', '''idle'''] loop
      v_n := (length(v_code) - length(replace(v_code, v_tok, ''))) / length(v_tok);
      if v_n <> 0 then
        raise exception '0349 ASSERT (b) FAIL: public.% still spells the fleet status % , % time(s) — one authority means the vocabulary lives in public.fleet_is_live and nowhere else', v_fn, v_tok, v_n;
      end if;
    end loop;
  end loop;

  -- process_mainship_expeditions must carry NO fleet-status literal at all, including 'present'…
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_mainship_expeditions';
  v_n := (length(v_code) - length(replace(v_code, '''present''', ''))) / length('''present''');
  if v_n <> 0 then
    raise exception '0349 ASSERT (b) FAIL: process_mainship_expeditions still spells ''present'' % time(s)', v_n;
  end if;
  -- …while its SHIP-status list, a different vocabulary and a correct one, is still there. Without
  -- this the four zero-counts above could be satisfied by a body that had lost its predicates too.
  if position('s.status in (''traveling'',''returning'')' in v_code) = 0 then
    raise exception '0349 ASSERT (b) FAIL: process_mainship_expeditions lost the main_ship_instances status list — a stale-base re-emission';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.fleet_is_live(', ''))) / length('public.fleet_is_live(');
  if v_n <> 6 then
    raise exception '0349 ASSERT (b) FAIL: process_mainship_expeditions composes the predicate % time(s) (want exactly 6 — the lit branch''s three orphan probes and the retained 0198 head''s three; anything less means a list was left hand-written, which is the defect)', v_n;
  end if;

  -- nohome_dock_returning_ship: 'present' survives ONLY as the docked state it writes (3 sites), never
  -- as a membership test; and both port resolutions plus the reuse read are fenced.
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'nohome_dock_returning_ship';
  v_n := (length(v_code) - length(replace(v_code, '''present''', ''))) / length('''present''');
  if v_n <> 3 then
    raise exception '0349 ASSERT (b) FAIL: nohome_dock_returning_ship spells ''present'' % time(s) (want the head''s 3 write/lookup sites — a 4th would be a new membership test)', v_n;
  end if;
  if position('status in (' in v_code) > 0 or position('status = any (' in v_code) > 0 then
    raise exception '0349 ASSERT (b) FAIL: nohome_dock_returning_ship carries a status membership list — it must compose the predicate instead';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.fleet_sortie_still_speaks(', ''))) / length('public.fleet_sortie_still_speaks(');
  if v_n <> 2 then
    raise exception '0349 ASSERT (b) FAIL: % of the 2 return-port resolutions are TTL-fenced — an unfenced one still reads a seventeen-day-old corpse', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.fleet_is_live(', ''))) / length('public.fleet_is_live(');
  if v_n <> 3 then
    raise exception '0349 ASSERT (b) FAIL: nohome_dock_returning_ship composes fleet_is_live % time(s) (want 3 — the live-first ordering on each of the two resolutions, and the H1 reuse fence)', v_n;
  end if;
end $b$;

-- (c) THE ORDERING IS TOTAL, AND LIVE-FIRST. `select … into` takes the first row silently; two rows
--     sharing updated_at must not be able to answer differently on different days.
do $c$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'nohome_dock_returning_ship';
  v_n := (length(v_code) - length(replace(v_code, 'limit 1', ''))) / length('limit 1');
  if v_n <> 4 then
    raise exception '0349 ASSERT (c) FAIL: % `limit 1` read(s) in nohome_dock_returning_ship (want the head''s 4)', v_n;
  end if;
  if position('order by public.fleet_is_live(f.status) desc, f.updated_at desc, f.id desc' in v_code) = 0
     or position('order by public.fleet_is_live(gf.status) desc, gf.updated_at desc, gf.id desc' in v_code) = 0 then
    raise exception '0349 ASSERT (c) FAIL: a return-port resolution is not ordered live-first with a total tie-break';
  end if;
  if position('order by updated_at desc, id desc limit 1' in v_code) = 0 then
    raise exception '0349 ASSERT (c) FAIL: the H1 reuse read has no total tie-break';
  end if;
  -- and no bare `order by updated_at desc limit 1` survives anywhere in it.
  if position('order by f.updated_at desc limit 1' in v_code) > 0
     or position('order by gf.updated_at desc limit 1' in v_code) > 0
     or position('order by updated_at desc limit 1' in v_code) > 0 then
    raise exception '0349 ASSERT (c) FAIL: a bare `order by updated_at desc limit 1` survives — that read IS the bug';
  end if;
end $c$;

-- (d) THE ROSTER HAS AN END, AND ONLY ONE DELETER. The reap composes group_sortie_release; it does
--     not write its own DELETE, and group_sortie_release itself is untouched.
do $d$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_mainship_expeditions';
  if position('public.group_sortie_release(rr.player_id, rr.fleet_id)' in v_code) = 0 then
    raise exception '0349 ASSERT (d) FAIL: the reap is not in process_mainship_expeditions — the manifest still has no end';
  end if;
  if position('delete from group_sortie_members' in v_code) > 0
     or position('delete from public.group_sortie_members' in v_code) > 0 then
    raise exception '0349 ASSERT (d) FAIL: the reap writes its own DELETE — group_sortie_release must remain the sole deleter of the manifest';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.fleet_sortie_still_speaks(', ''))) / length('public.fleet_sortie_still_speaks(');
  if v_n <> 1 then
    raise exception '0349 ASSERT (d) FAIL: the reap tests the TTL % time(s) (want exactly 1)', v_n;
  end if;
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'group_sortie_release';
  if v_code is null or position('delete from public.group_sortie_members' in v_code) = 0 then
    raise exception '0349 ASSERT (d) FAIL: group_sortie_release is missing or no longer deletes — the sole deleter must still be the sole deleter';
  end if;
end $d$;

-- (e) THE BACKFILL'S POST-CONDITION, and its undo. Both halves hold on a completely EMPTY database
--     (zero rows → zero rows → zero rows), so this is a property, never a count of the world.
do $e$
declare v_left integer; v_saved integer;
begin
  select count(*) into v_left
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where not public.fleet_sortie_still_speaks(f.status, f.updated_at);
  if v_left <> 0 then
    raise exception '0349 ASSERT (e) FAIL: % manifest row(s) still describe a sortie that no longer speaks — the backfill did not close its own predicate', v_left;
  end if;
  -- nothing was deleted without being copied out first: every saved row is genuinely gone, and every
  -- gone row is genuinely saved (the second half is what the count above proves).
  select count(*) into v_saved
    from public.group_sortie_members_retired_0349 s
   where exists (select 1 from public.group_sortie_members g
                  where g.fleet_id = s.fleet_id and g.main_ship_id = s.main_ship_id);
  if v_saved <> 0 then
    raise exception '0349 ASSERT (e) FAIL: % snapshot row(s) are still live in group_sortie_members — the snapshot and the release disagree', v_saved;
  end if;
  -- and the manifest that STILL speaks was not touched: any surviving row must point at a fleet that
  -- speaks. (Vacuous on an empty database, which is why (f) below proves the predicate, not the rows.)
  select count(*) into v_left
    from public.group_sortie_members gsm
    left join public.fleets f on f.id = gsm.fleet_id
   where f.id is null;
  if v_left <> 0 then
    raise exception '0349 ASSERT (e) FAIL: % manifest row(s) point at no fleet at all', v_left;
  end if;
end $e$;

-- (f) THE IDENTITY THAT REMOVES THE SEAM: what the reap deletes is EXACTLY what the resolver refuses
--     to read. Proven over the whole cross-product of the status vocabulary × the ages that matter,
--     with no rows involved at all — so it holds on an empty database and on production alike, and
--     it cannot be satisfied by luck.
do $f$
declare
  v_ttl double precision := coalesce(nullif(public.cfg_num('sortie_manifest_ttl_seconds'), 'NaN'::double precision), -1);
  v_st  text;
  v_age interval;
  v_speaks boolean;
  v_checked integer := 0;
begin
  if v_ttl <> 3600 then
    raise exception '0349 ASSERT (f) FAIL: sortie_manifest_ttl_seconds reads % (want 3600 — the knob is the authority both halves compose)', v_ttl;
  end if;
  foreach v_st in array array['idle','moving','present','returning','completed','destroyed'] loop
    foreach v_age in array array[interval '0', interval '5 minutes', interval '59 minutes',
                                 interval '61 minutes', interval '17 days'] loop
      v_speaks := public.fleet_sortie_still_speaks(v_st, now() - v_age);
      -- a LIVE fleet speaks at ANY age — a fleet parked idle in open space for a day is still the
      -- current sortie, and ageing it out would resurrect the bug in the other direction.
      if public.fleet_is_live(v_st) and not v_speaks then
        raise exception '0349 ASSERT (f) FAIL: a live fleet (status %, age %) stopped speaking — a parked fleet is still a fleet', v_st, v_age;
      end if;
      -- a TERMINAL fleet speaks iff it is inside the TTL — which is precisely the reap's negation.
      -- The expectation mirrors the leaf's own `updated_at >= now() - ttl` exactly (age <= ttl), and
      -- none of the five ages sits ON the boundary, so this can never pass or fail by a float edge.
      if not public.fleet_is_live(v_st) and v_speaks <> (v_age <= make_interval(secs => v_ttl)) then
        raise exception '0349 ASSERT (f) FAIL: terminal status % at age % speaks=% — the resolver and the reap disagree, which is the seam this design exists to remove', v_st, v_age, v_speaks;
      end if;
      v_checked := v_checked + 1;
    end loop;
  end loop;
  if v_checked <> 30 then
    raise exception '0349 ASSERT (f) FAIL: the cross-product checked % case(s) (want 6 statuses x 5 ages = 30) — the loop did not run', v_checked;
  end if;
  -- the seventeen-day corpse that misfiled the owner's fleet is DUMB in every terminal state, and
  -- the fresh corpse a legitimate return depends on is not. Both directions, named.
  if public.fleet_sortie_still_speaks('destroyed', now() - interval '17 days')
     or public.fleet_sortie_still_speaks('completed', now() - interval '17 days') then
    raise exception '0349 ASSERT (f) FAIL: a seventeen-day-old corpse still names a return port';
  end if;
  if not public.fleet_sortie_still_speaks('destroyed', now() - interval '30 seconds')
     or not public.fleet_sortie_still_speaks('completed', now() - interval '30 seconds') then
    raise exception '0349 ASSERT (f) FAIL: a sortie that ended one cron tick ago no longer names its return port — every legitimate return would re-home instead of docking';
  end if;
end $f$;

-- (g) THE BLAST RADIUS IS THE ONE DECLARED. Nothing outside these two functions was re-created, the
--     location-fold answerers this slice deliberately does not touch are byte-untouched, and the
--     manifest's writers are unchanged.
do $g$
declare v_src text; v_fn text; v_over integer;
begin
  foreach v_fn in array array['mainship_port_of_ship', 'mainship_resolve_docked_location',
                              'get_my_fleet_positions', 'assign_ship_to_group',
                              'send_ship_group_hunt', 'command_ship_group_go',
                              'combat_create_group_encounter', 'captain_xp_accrue',
                              'fleet_complete', 'fleet_destroy', 'group_fleet_retire',
                              'fleet_set_in_space', 'process_combat_ticks'] loop
    -- EVERY overload, folded — `select … into` would silently inspect only the first one.
    select count(*), coalesce(string_agg(p.prosrc, chr(10)), '') into v_over, v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_over = 0 then
      raise exception '0349 ASSERT (g) FAIL: public.% is absent — this slice must not have removed it', v_fn;
    end if;
    if position('public.fleet_is_live(' in v_src) > 0
       or position('public.fleet_sortie_still_speaks(' in v_src) > 0 then
      raise exception '0349 ASSERT (g) FAIL: public.% composes a 0349 predicate — it was re-created by this slice, and the declared blast radius is two functions', v_fn;
    end if;
  end loop;
  -- the manifest still has exactly the writers it had: the hunt send and the ambush re-freeze.
  select coalesce(string_agg(p.prosrc, chr(10)), '') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_ship_group_hunt';
  if position('insert into group_sortie_members' in v_src) = 0 then
    raise exception '0349 ASSERT (g) FAIL: send_ship_group_hunt no longer writes the manifest — the roster would now have an end and no beginning';
  end if;
end $g$;

-- (h) METADATA PARITY: the two functions changed BODY and nothing else, and both actually changed.
do $h$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0349_before loop
    select md5(p.prosrc) as body_md5, pg_get_userbyid(p.proowner) as owner, p.prosecdef as secdef,
           p.provolatile as volatility, p.proparallel as parallel,
           coalesce(array_to_string(p.proconfig, ','), '') as proconfig,
           pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as result,
           coalesce(p.proacl::text, '') as acl
      into a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = b.fname;
    if a.owner is distinct from b.owner or a.secdef is distinct from b.secdef
       or a.volatility is distinct from b.volatility or a.parallel is distinct from b.parallel
       or a.proconfig is distinct from b.proconfig or a.args is distinct from b.args
       or a.result is distinct from b.result or a.acl is distinct from b.acl then
      raise exception '0349 ASSERT (h) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0349 ASSERT (h) FAIL: public.% body is byte-identical — its hunks did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 2 then
    raise exception '0349 ASSERT (h) FAIL: parity-checked % function(s), expected 2', v_n;
  end if;
  raise notice '0349 SELF-ASSERT PASS: ''idle'' is a LIVE fleet again — a fleet parked in open space after a retreat, an ambush or a stop is no longer read as no fleet at all, and the vocabulary now lives in ONE predicate that all four orphan probes compose; the return-port resolver hears a live fleet first, a concluded one only inside sortie_manifest_ttl_seconds, and never a corpse it cannot have come home from, with a total tie-break so the answer cannot drift; the H1 reuse can no longer resurrect a destroyed fleet; and the sortie manifest finally has an END, released through its sole deleter on exactly the negation of what the resolver will read, with every backfilled row copied into group_sortie_members_retired_0349 first';
end $h$;

commit;
