-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0309 — THE CLIENT-CALLABLE SURFACE HOLDS ONLY WHAT THE CLIENT CALLS
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- Five functions are granted to `authenticated` and are called by NOTHING in `src/`. Verified by
-- grepping the whole client tree for each name: the only hits are prose comments recording that the
-- client reference was retired. Each one is a live entry point on a ~30-player production game, and
-- three of them are actively harmful:
--
--   1. command_main_ship_settle_arrival_legacy(uuid) — A RESURRECTED CORPSE.
--      0232:250 DROPPED it as one of the twenty per-ship movement functions, with a pre-drop guard
--      (0232:168-169) asserting it existed and a post-drop pin (0232:283) listing it as retired.
--      0301:1356 RE-CREATED it and 0301:1445 re-granted EXECUTE, on the written premise (0301:1349-
--      1355) that it was "the second — and last — production consumer that settled a movement
--      independently". That premise was FALSE: it had not existed for 69 migrations. Its only gate is
--      cfg_bool('mainship_send_enabled') at 0301:1375, and 0300:70 lit that flag. So a second,
--      independent arrival-settlement verb from the retired per-ship era is open to every player.
--      I swept every one of 0232's twenty drops against 0233-0306: this is the ONLY resurrection.
--
--   2. command_main_ship_stop_transit(uuid) — CANNOT SUCCEED, EVER.
--      Its live head (0155:102-103, :150-156) reads and writes main_ship_instances.spatial_state,
--      space_x and space_y. 0231:1558-1562 DROPPED all three columns. Every call past the gate raises
--      `column "spatial_state" does not exist`. 0232:65-70 left the "STOP TRIO" untouched
--      DELIBERATELY, for one stated reason: FleetCommandPanel.tsx still carried a dark ternary
--      `unifiedEnabled ? commandShipGroupStop : stopShipGroup` whose legacy branch referenced it,
--      "pending client PR #189". THAT BRANCH IS GONE — FleetCommandPanel.tsx:7,210 now reference only
--      commandShipGroupStop, and teamStop.ts:114-118 records the legacy parser and its stopShipGroup
--      wrapper as retired. The deferral's own condition has been satisfied and nobody closed it.
--
--   3. stop_ship_group_transit(uuid) — the trio's other half; 0164:119 is the sole caller of (2), so
--      it inherits the same guaranteed raise. No client caller (teamStop.ts:116 says so).
--
--   4. group_sortie_is_open(uuid, uuid) — TAKES THE ACTING PLAYER AS AN ARGUMENT.
--      0305:104-141 is `security definer` and `auth.uid()` appears NOWHERE in its body; 0305:151
--      grants it to `authenticated`. Being definer it bypasses combat_encounters / fleets /
--      location_presence RLS, so the grant is the only gate on a boolean that reports whether an
--      ARBITRARY player is in an open fight or committed to a sortie. This is the sole violation of
--      "derive the actor from auth.uid(), never from an argument" on the live surface — every sibling
--      internal leaf is correctly revoked (mainship_resolve_owned_group 0161:155, and 0306:153-155
--      revokes its three leaves and ASSERTS the revoke at 0306:454-466). Victim player_ids are
--      trivially enumerable: get_ranking_leaderboard is granted to anon (0131:153) and returns up to
--      500 raw uuids (the cap is 0131:97-98). Only the non-enumerable group uuid stands between this
--      and live exploitation.
--      0305:102-103 states the fix itself — "all seven call sites are themselves security-definer
--      RPCs" — so no in-database caller needs the grant.
--
--   5. pirate_intercept_preview_route(uuid, jsonb, uuid, float8, float8) — UNBOUNDED POSTGIS LOOP.
--      0233:1313-1317 reads jsonb_array_length(p_waypoints) with NO cap and 0233:1320 loops it,
--      running pirate_intercept_leg_zone_hits — ST_Intersects/ST_Intersection/ST_Length over every
--      active danger_zones row — once per element, accumulating jsonb O(n²) (0233:1345,:1350). No
--      function in this schema sets statement_timeout. Its own WRITE-PATH sibling caps the identical
--      argument: command_ship_group_go_route clamps to cfg_num('pirate_route_max_waypoints') at
--      0301:2271-2275 (live value 3). The read path simply omits the cap. pirateApi.ts:41 records
--      that this RPC "still exists but has no client caller".
--
-- WHAT THIS MIGRATION DOES: revokes EXECUTE from anon and authenticated on all five. Nothing else.
-- No body is re-created, no behaviour changes for any reachable path, no flag moves. Because none of
-- the five has a client caller, the player-visible change is exactly zero.
--
-- WHY REVOKE AND NOT DROP. (1), (2) and (3) are dead code and the standing anti-spaghetti law says
-- retire, do not leave a dead parallel path — so the DROP is owed. It is NOT in this slice for one
-- concrete reason, stated rather than silently skipped: their names are pinned by
-- scripts/fleetgo-proof.{sql,sh} and scripts/team-command-proof.{sql,sh}, and fleetgo-proof.sql is
-- being edited by a concurrent slice. Dropping them without moving those pins in the same change
-- would redden the one proof suite that is currently green (FLEET-GO), which is worse than waiting
-- one slice. The drop is the immediate follow-up, blocked only by file contention, not by design.
--
-- THE FULL PIN INVENTORY, re-derived by adversarial review after a first draft named only the two
-- proof suites (a header's inventory is a CLAIM — this project has been burned by exactly that: a
-- doc said four copy sites, there were five, and only the reviewer counted). Two more scripts call
-- these through an AUTHENTICATED user client and so break on the revoke, not merely on the drop:
--   scripts/verify-mainship-move.mjs:173,189,206,211        → command_main_ship_stop_transit
--   scripts/verify-mainship-legacy-dock-travel.mjs:85       → command_main_ship_settle_arrival_legacy
--     (and its NOT_DEPLOYED tolerance at :86 will not match 'permission denied for function', so it
--      die()s rather than skipping)
-- Both are already broken against the current schema for other reasons — verify-mainship-move.mjs
-- drives a function that raises on every call because 0231:1560 removed the column it reads — and
-- neither runs on push: verify-mainship-move.yml:8-9 is workflow_dispatch-only and
-- verify-mainship-legacy-dock-travel.mjs is in no workflow at all. They are named here so the
-- follow-up slice retires them WITH the functions instead of rediscovering them.
--
-- (4) and (5) are LIVE code that is simply granted too widely — for them, revoke IS the whole fix.
--
-- ESTABLISH, NEVER MERELY ASSERT. This file REVOKEs and then asserts the end state. That ordering is
-- the lesson of the 0254 production abort: prod danger_zones carried a Supabase project-default
-- GRANT ALL that no migration created, an assert-only migration aborted the deploy on it, and a
-- local `supabase start` could not reproduce it — so an assert that has never REVOKEd is a vacuous
-- assert.
--
-- NOT RE-RUNNABLE BY HAND, deliberately. The `revoke` statements are individually idempotent, but
-- precondition 2 raises on a second application (by then no target carries a client grant, so v_n is
-- 0). That is the correct trade: the alternative is a migration that can silently become a no-op and
-- still report success. Under `db push` / `db reset` each migration applies once, so this costs
-- nothing; do not hand-run it twice and read the abort as a defect.
--
-- ROLLBACK: the commented block at the bottom. Note it is NOT a byte-exact restoration — it re-grants
-- `authenticated` only, while this migration also revokes `public` and `anon`. For 0305's and 0233's
-- functions that is a deliberate net tightening (their original grants named `authenticated` alone),
-- so a rollback returns the posture to "as intended", not "as it may have drifted".

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 1. PRECONDITIONS — every target must exist with the exact signature (read-only) ──────────────
do $pre$
declare
  v_missing text;
begin
  select string_agg(f, ', ' order by f) into v_missing
    from unnest(array[
      'public.command_main_ship_settle_arrival_legacy(uuid)',
      'public.command_main_ship_stop_transit(uuid)',
      'public.stop_ship_group_transit(uuid)',
      'public.group_sortie_is_open(uuid, uuid)',
      'public.pirate_intercept_preview_route(uuid, jsonb, uuid, double precision, double precision)'
    ]) f
   where to_regprocedure(f) is null;
  if v_missing is not null then
    raise exception '0309 PRECONDITION FAIL: signature drift — not found: %', v_missing;
  end if;
end $pre$;

-- ── 2. PRECONDITION — the revoke must not be vacuous ─────────────────────────────────────────────
-- If NONE of the five currently carries a client EXECUTE, this migration would be a no-op that still
-- reports success — the exact shape of a proof that certifies nothing. Fail loudly instead.
do $pre2$
declare
  v_n integer;
begin
  select count(*) into v_n
    from unnest(array[
      'public.command_main_ship_settle_arrival_legacy(uuid)',
      'public.command_main_ship_stop_transit(uuid)',
      'public.stop_ship_group_transit(uuid)',
      'public.group_sortie_is_open(uuid, uuid)',
      'public.pirate_intercept_preview_route(uuid, jsonb, uuid, double precision, double precision)'
    ]) f
   where has_function_privilege('authenticated', to_regprocedure(f), 'EXECUTE')
      or has_function_privilege('anon',          to_regprocedure(f), 'EXECUTE');
  if v_n = 0 then
    raise exception '0309 PRECONDITION FAIL: none of the 5 targets carries a client EXECUTE — this migration would be vacuous';
  end if;
  raise notice '0309: % of 5 target(s) carry a client EXECUTE before the revoke', v_n;
end $pre2$;

-- ── 3. THE REVOKES ───────────────────────────────────────────────────────────────────────────────
-- `public` IS IN THIS LIST DELIBERATELY. has_function_privilege() counts a privilege held via the
-- PUBLIC pseudo-role, so if PUBLIC carried EXECUTE on any of the five, revoking only from anon and
-- authenticated would remove NOTHING while assert (a) below still saw the privilege — and the
-- migration would ABORT THE DEPLOY instead of fixing anything. That is the 0254 production abort
-- reproduced inside the file that cites 0254 as its lesson. On a clean replay PUBLIC is already
-- empty (0151:212/0301:1444, 0149:161/0155:166, 0164:151, 0305:150, 0233:1362 each revoke it), so
-- this word only matters against production drift — which is precisely the class CI cannot see.
revoke execute on function public.command_main_ship_settle_arrival_legacy(uuid) from public, anon, authenticated;
revoke execute on function public.command_main_ship_stop_transit(uuid)          from public, anon, authenticated;
revoke execute on function public.stop_ship_group_transit(uuid)                 from public, anon, authenticated;
revoke execute on function public.group_sortie_is_open(uuid, uuid)              from public, anon, authenticated;
revoke execute on function public.pirate_intercept_preview_route(uuid, jsonb, uuid, double precision, double precision)
  from public, anon, authenticated;

-- ── 4. SELF-ASSERT (a) — no client role can execute any of the five ──────────────────────────────
do $a$
declare
  v_bad text;
begin
  select string_agg(f || ' [' || r || ']', ', ' order by f, r) into v_bad
    from unnest(array[
      'public.command_main_ship_settle_arrival_legacy(uuid)',
      'public.command_main_ship_stop_transit(uuid)',
      'public.stop_ship_group_transit(uuid)',
      'public.group_sortie_is_open(uuid, uuid)',
      'public.pirate_intercept_preview_route(uuid, jsonb, uuid, double precision, double precision)'
    ]) f
    cross join unnest(array['anon', 'authenticated', 'public']) r
   where has_function_privilege(r, to_regprocedure(f), 'EXECUTE');
  if v_bad is not null then
    raise exception '0309 ASSERT (a) FAIL: client EXECUTE survives on: %', v_bad;
  end if;
end $a$;

-- ── 5. WHY THERE IS NO service_role ASSERT HERE (this space intentionally left empty) ────────────
-- A draft of this file asserted that `service_role` retained EXECUTE on the two functions that are
-- still live, to "prove the definer callers are unharmed". An adversarial review killed it and was
-- right twice over:
--   FACTUALLY — service_role was NEVER granted EXECUTE on either. 0305:150-151 and 0233:1362-1363
--   both do `revoke all … from public` + `grant execute … to authenticated`, and a chain-wide sweep
--   for `to service_role` on either name returns nothing. Every one of the ~18 service_role asserts
--   that already exist in this chain has a matching explicit grant; mine would have been the first
--   without one. On the hosted project an ambient project-level default may supply it, but on the
--   disposable `supabase start` stack it does not exist — so the assert would have raised, aborted
--   the transaction, and reddened the apply-proof for this PR and every later one. That is the same
--   prod-vs-local asymmetry that aborted the 0254 deploy.
--   CONCEPTUALLY — it proved the wrong thing anyway. A SECURITY DEFINER function executes as its
--   OWNER (postgres), not as the invoking role and not as service_role, so the definer call sites
--   were never reachable through a service_role privilege in the first place.
-- An assert that asserts an ambient default it does not itself establish is not rigour; it is the
-- vacuous-or-fatal pattern this project has been burned by. Nothing replaced it: the property that
-- matters (no client role can execute) is assert (a), and the property that the definer callers keep
-- working needs no assert because the revoke cannot touch the owner's own privilege.
--
-- The dropped draft-assert (b) went with it: it checked that the five functions still EXIST after a
-- REVOKE. `revoke` cannot drop a function. It was a byte-duplicate of precondition 1 guarding an
-- impossible event — rigour theatre, which is worse than no assert because it pads the file with
-- something that can never fail and makes the real checks harder to find.

-- ── 6. SELF-ASSERT (d) — the surrounding client surface is untouched ─────────────────────────────
-- A revoke typo naming the wrong function would be invisible above. Pin that the verbs the client
-- actually calls still carry their grant. These five are the live commanded verbs
-- (FleetCommandPanel.tsx and teamApi.ts call every one of them).
--
-- NOTE THE `is null` ARM. Writing this as `where to_regprocedure(f) is not null and not
-- has_function_privilege(...)` would make a MISTYPED signature resolve to NULL, drop out of the
-- WHERE, and let the assert pass green while checking nothing — a vacuous guard, the precise defect
-- class this migration's own header cites from the 0254 abort. An unresolvable name is a FAILURE
-- here, not a skip.
do $d$
declare
  v_lost text;
begin
  select string_agg(f || case when to_regprocedure(f) is null then ' [UNRESOLVABLE SIGNATURE]' else ' [GRANT LOST]' end,
                    ', ' order by f)
    into v_lost
    from unnest(array[
      'public.command_ship_group_go(uuid, uuid, double precision, double precision)',
      'public.command_ship_group_stop(uuid)',
      'public.assign_ship_to_group(uuid, uuid)',
      'public.delete_ship_group(uuid)',
      'public.upsert_ship_group(integer, text)'
    ]) f
   where to_regprocedure(f) is null
      or not has_function_privilege('authenticated', to_regprocedure(f), 'EXECUTE');
  if v_lost is not null then
    raise exception '0309 ASSERT (d) FAIL: %', v_lost;
  end if;
end $d$;

-- 0305:143-148's definition is PRESERVED VERBATIM below and the ACL note is APPENDED. A draft
-- replaced it outright, which would have destroyed the only record of what this function MEANS —
-- and nothing would have caught it, because no proof in this repo reads pg_description.
comment on function public.group_sortie_is_open(uuid, uuid) is
  'THE one answer to "is this group on a sortie?" (0305). TRUE while a combat encounter is open '
  '(active/retreating) or a sortie leg (hunt_pirates/return_home) is in the air. Reads facts that '
  'END BY THEMSELVES — never group_sortie_members, whose frozen roster is never released and so '
  'said "was in a fight once" forever. Ordinary travel is mission ''rally'' and is not a sortie. '
  'Sole definition: the mover, the brake, dock, assign/unassign, delete and hunt all call THIS. '
  'ACL (0309): SERVER-INTERNAL ONLY. It takes the acting player as an ARGUMENT and never reads '
  'auth.uid(), so with SECURITY DEFINER the grant was the only gate on a boolean reporting an '
  'ARBITRARY player''s live-combat state. EXECUTE is revoked from public, anon and authenticated. '
  'All seven call sites are themselves SECURITY DEFINER RPCs that resolve the player from auth.uid() '
  'first, so none of them needs a client grant. Do NOT re-grant it to a client role.';

commit;

-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- ROLLBACK — re-grants `authenticated` only, which is what every original grant site named
-- (0301:1445, 0155:167, 0164:152, 0305:151, 0233:1363). It does NOT restore any `public`/`anon`
-- privilege this migration may have removed as production drift; that omission is intentional.
-- Running this re-opens a resurrected settle path, two functions that can only raise, a cross-player
-- combat-state probe, and an uncapped PostGIS loop:
--
--   grant execute on function public.command_main_ship_settle_arrival_legacy(uuid) to authenticated;
--   grant execute on function public.command_main_ship_stop_transit(uuid)          to authenticated;
--   grant execute on function public.stop_ship_group_transit(uuid)                 to authenticated;
--   grant execute on function public.group_sortie_is_open(uuid, uuid)              to authenticated;
--   grant execute on function public.pirate_intercept_preview_route(uuid, jsonb, uuid, double precision, double precision) to authenticated;
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
