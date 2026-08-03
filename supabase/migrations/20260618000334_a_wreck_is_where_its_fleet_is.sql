-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0334 — A WRECK IS WHERE ITS FLEET IS
--        a ship whose GROUP is tied up at a port is AT that port, whatever its own lifecycle
--        status — so a wreck in a docked fleet repairs on the spot, with no tow
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- THE OWNER, VERBATIM: "you don't need to tow to a nearest port. As a fleet we have arrived at a
-- dock already." They are right, and the tow was never the point — it was the only thing that
-- worked, because the game had lost the wrecks' position.
--
-- ── ⚠ THE STATED HYPOTHESIS IS WRONG, AND THE REAL CAUSE IS ONE LINE AWAY ────────────────────────
-- The follow-up that ordered this work said "the resolver loses a ship's location the moment it is
-- marked destroyed". IT DOES NOT. `mainship_resolve_fleet` reads exactly two columns off the ship —
-- `select player_id, group_id into v_player, v_group` — and never reads `status` at all; the only
-- status it filters is `fleets.status`. Marking a ship destroyed cannot change its answer.
--
-- PROVEN, not argued: these same two hulls were read live on production EARLIER THE SAME DAY, while
-- both were still `status='home'`, and `mainship_resolve_fleet` ALREADY returned NULL for both. The
-- NULL predates 0332's status flip entirely. Anything built on "the destroy path clears something"
-- would have been a fix for a defect that does not exist.
--
-- ── WHAT ACTUALLY HAPPENS, AT THE LINE ───────────────────────────────────────────────────────────
-- `mainship_resolve_fleet` (TRUE head 0210; deployed body read live) answers in two branches:
--   (1) THE GROUP'S UNIFIED FLEET — gated on `fleet_movement_unified_enabled` (true in production)
--       and keyed `group_id = v_group and player_id = v_player and MAIN_SHIP_ID IS NULL`. That
--       `is null` is deliberate and correct: the legacy expedition send tags `group_id` onto
--       PER-MEMBER fleets (0204:316), so group_id alone would match N member envelopes and the
--       branch would have no single fleet IDENTITY to return.
--   (2) TRANSITION FALLBACK — the ship's OWN `main_ship_id`-tagged fleet, requiring exactly one:
--         `if v_n <> 1 then return null;`   ← ★ THIS IS THE LINE THE LOCATION IS LOST AT ★
--
-- Production, group df4649fc (all four hulls are members of it):
--   fleets alive for that player:  e0533a30  present @ Haven  group=df4649fc  main_ship=Sparrow
--                                  9fa1f01d  present @ Haven  group=NULL      main_ship=Sparrow III
--                                  8be593f8  present @ Slagworks (a different group)
-- Branch (1) finds ZERO fleets for df4649fc with `main_ship_id is null` — this group has no unified
-- fleet at all, only per-member ones — so it falls through. Branch (2) then answers per SHIP:
--   Sparrow      -> e0533a30 -> Haven          Sparrow III -> 9fa1f01d -> Haven
--   Sparrow IV   -> v_n = 0  -> NULL           Sparrow V   -> v_n = 0  -> NULL
-- The two wrecks own no per-ship fleet row, so they resolve nothing and `mainship_port_of_ship`
-- (0297 §1) has nothing to answer from: ARM 1 needs a resolved fleet, and ARM 2's berth is NULL for
-- them by the 0216 XOR (`(group_id is null) = (berth_location_id is not null)` — a grouped ship
-- CANNOT hold a berth). Port NULL.
--
-- WHY THOSE TWO AND NOT THE OTHER TWO: a per-ship fleet is minted for a ship that comes back from a
-- fight. Sparrow and Sparrow III came back; Sparrow IV and Sparrow V were the CASUALTIES, and the
-- pre-0332 settle arm skipped every casualty (`and alive_count > 0`). 0332 fixed what that omission
-- did to their STATUS. This file fixes what it did to their POSITION. Same defect, one layer down.
--
-- ── WHAT `repair_main_ship` DOES TODAY, END TO END, FOR SPARROW IV ───────────────────────────────
--   authenticated                                    -> passes
--   mainship_resolve_owned_ship                      -> passes (the owner owns it)
--   status <> 'destroyed'                            -> passes (0332 made it 'destroyed')
--   max_hp is null or max_hp <= 0                    -> passes (max_hp 500)
--   v_port := mainship_port_of_ship(...); v_port is null
--     -> ★ RAISES 'repair_main_ship: ship_not_at_port — this ship is adrift; tow it to a port
--        before repairing' (0297:207-210). THIS is the guard that rejects it, and it is the ONLY
--        one. Not the destroyed-guard, not max_hp. Verified by reading the live gate inputs:
--        mainship_port_of_ship is STABLE and returns NULL for both hulls on production right now.
-- So the position authority is both the cause and the whole fix. Nothing else needs to move.
--
-- ── THE FIX: ONE NEW ARM INSIDE THE ONE POSITION AUTHORITY ───────────────────────────────────────
-- `mainship_port_of_ship` is already declared (0297 §1) as "the ONE authority for which port is this
-- ship physically at, REGARDLESS OF ITS LIFECYCLE STATUS". It asks "which fleet is MINE, and is that
-- fleet docked". For a ship in a group that is the wrong first question — the owner's own law is
-- that THE FLEET IS THE UNIT OF MOVEMENT AND A SHIP DOES NOT MOVE; a ship's location IS its fleet's.
-- So the new arm asks the question that was missing: IS MY GROUP TIED UP AT A PORT?
--
--   ARM 1  the ship's own resolved fleet's dock                    — unchanged, still answers first
--   ARM 2  NEW: the ONE port the ship's GROUP is docked at         — this file
--   ARM 3  the berth                                               — unchanged
--
-- IT NAMES NO STATUS. There is no `case when status = 'destroyed'`, no wreck branch, no special
-- case — self-assert (c) mechanically pins that the word never appears in the body. It answers
-- identically for a living grouped ship that owns no per-ship fleet, which is the same hole; the
-- wrecks were merely the first players to fall in it.
--
-- ONE AUTHORITY, AND ONE FEWER THAN BEFORE. The group's dock is derived through
-- `fleet_docked_location(fleets)` — "THE docked authority" (0306:63) — and ARM 1's hand-inlined copy
-- of that same predicate (`f.status = 'present' and f.location_mode = 'location'`, written into 0297
-- before 0306 existed) is REPLACED by a call to it. So this migration removes a duplicated spelling
-- of "is this fleet docked" while adding a use of the real one: two copies become one.
--
-- MEMBERS CAN NO LONGER DISAGREE. The arm counts the DISTINCT docked locations across every live
-- fleet belonging to the group — both the group-tagged ones and the per-member ones owned by the
-- group's ships — and answers only when there is EXACTLY ONE. Two members docked at different ports
-- is a broken invariant, and it fails closed (no port, the tow remains the route) instead of
-- inventing an answer. Consequence, stated plainly: a wreck can never name a DIFFERENT port from its
-- fleetmates; the worst it can do is decline to name one.
--
-- ── WHAT IS DELIBERATELY NOT DONE ────────────────────────────────────────────────────────────────
--   1. `mainship_resolve_fleet` IS NOT TOUCHED. It answers "which fleet is this ship's", and for
--      Sparrow IV the honest answer is still "none" — it owns no fleet row. Making it return a
--      FLEETMATE'S fleet would be a lie told to all of its callers, not just this one. Position is
--      not identity, and the fix belongs in the position authority.
--   2. NO SECOND RESOLVER, NO NEW FUNCTION. The arm lives inside the existing one-position-authority
--      body. A `ship_group_docked_location(...)` leaf would be a second place to ask "where is this
--      ship", which is the disease.
--   3. THE WRECKS ARE NOT GIVEN PER-SHIP FLEET ROWS. That would "restore" the position by growing
--      the very per-ship layer both branches of `mainship_resolve_fleet` document as transitional
--      and slated for deletion, and it would put a `fleets` INSERT in the combat settle path.
--   4. NO DATA BACKFILL AT ALL. Nothing about these ships' rows is wrong — `group_id` is right,
--      `berth_location_id` is correctly NULL under the XOR, `status` is correctly 'destroyed'. Only
--      the READ was incomplete. There is nothing to repair in the data, and this migration writes
--      not one row.
--   5. THE TOW STAYS, UNCHANGED. `mainship_emergency_tow` is not re-created here. Read 0297 §3: it
--      exists so the position gate can never strand a ship, and it is still the ONLY route for the
--      case it was built for — a wreck whose fleet was destroyed and whose group holds no docked
--      fleet at all. That ship still resolves no port, still gets 'Tow to port', and still works.
--      What changes is that a wreck in a DOCKED fleet no longer NEEDS it: it repairs where it is,
--      and it keeps its place in the fleet instead of being un-grouped by a haul it never required.
--
-- ── THE CLIENT HALF (so this is not half a slice) ────────────────────────────────────────────────
-- No client change is needed, and that is verified rather than assumed. `get_my_disabled_ships`
-- (0297 §4) reports `at_port := mainship_port_of_ship(...) is not null`, and the client is a pure
-- function of that one field: `repairGate` in src/features/ship/shipRecovery.ts:78-90 returns
-- `at_port` when the row says at_port and `adrift` otherwise; `canRepair` (:106-108) admits exactly
-- `at_port`/`unknown` and `canTow` (:111-113) exactly `adrift`. So the moment the server answers
-- Haven for these hulls, the Ships tab stops offering "Tow to the nearest port" and offers
-- "Repair ship", with the note flipping from the adrift line to "This ship is disabled. Repair it
-- to get moving again." The player sees and presses the thing; nothing in src/ has to change.
--
-- ── BLAST RADIUS ON THE LIVE GAME ────────────────────────────────────────────────────────────────
--   * DDL is one CREATE OR REPLACE of one STABLE, SECURITY DEFINER function — an atomic catalog
--     swap. No table lock, no schema change, no grant change, no game_config write, no flag, and
--     NOT ONE ROW WRITTEN by this migration.
--   * `mainship_port_of_ship` has exactly THREE callers in the database, all of them the recovery
--     surface: repair_main_ship, mainship_emergency_tow, get_my_disabled_ships. Nothing else in the
--     game reads it, so the reachable change is exactly: a grouped ship whose group is docked now
--     resolves that port. Movement, combat, mining, trade and every map read are untouched.
--   * WHO CHANGES BEHAVIOUR: only a DESTROYED ship (the three callers' shared precondition) that is
--     in a group holding exactly one docked fleet. For those, repair starts succeeding in place and
--     the tow starts answering 'already_at_port' — which is the correct answer and which the client
--     already handles by clearing its adrift override (ShipScreen.tsx:205-206).
--   * A destroyed ship with a BERTH and no group — the shape three real production wrecks carry —
--     skips the new arm entirely (it is gated on `group_id is not null`) and still answers from its
--     berth, byte-identically. Their day does not change.
--   * ARM 1's rewrite is semantically identical: `fleet_docked_location` returns the location only
--     when `status='present' and location_mode='location' and current_location_id is not null`,
--     which is the inlined test it replaces plus a NULL check that the old code applied one line
--     later anyway.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply 0297 §1's body verbatim (20260618000297:104-144). This migration writes no rows, no
-- schema, no grants and no game_config, so there is nothing else to unwind.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
-- WHAT THESE PROVE, HONESTLY: that the emitted body is what this migration intended, plus two
-- zero-write probes that hold on an EMPTY database. Behaviour is proven by exactly one layer: the
-- disposable apply-proof driving the real recovery path (danger-combat-proof's DOCKWRECK block).
--   (a) the function is still the same KIND of function (stable, secdef, pinned search_path) and
--       still not client-callable
--   (b) it composes the 0306 docked authority, and the hand-inlined copy of that predicate is gone
--   (c) the group arm exists, and the body names NO lifecycle status — no wreck special case
--   (d) ARM ORDER: the own-fleet arm still answers before the group arm, which answers before the
--       berth
--   (e) the recovery surface is untouched: repair and the tow still gate on status='destroyed', and
--       the tow still writes both 0216 XOR columns
--   (f) zero-write probes, valid on an empty dataset
--   (g) metadata parity: the function changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not copy from ────────────────
do $pre$
declare
  v_src text;
begin
  if to_regprocedure('public.mainship_port_of_ship(uuid)') is null then
    raise exception '0334 PRECONDITION FAIL: mainship_port_of_ship(uuid) is absent';
  end if;
  if to_regprocedure('public.fleet_docked_location(public.fleets)') is null then
    raise exception '0334 PRECONDITION FAIL: fleet_docked_location(fleets) is absent — the 0306 docked authority this file composes';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.mainship_port_of_ship(uuid)')::oid;
  -- the base must be the 0297 body: its two documented arms, and NOT already carrying this fix.
  if position('mainship_resolve_fleet' in v_src) = 0 or position('berth_location_id' in v_src) = 0 then
    raise exception '0334 PRECONDITION FAIL: the deployed mainship_port_of_ship is not the 0297 two-arm body — refusing to overwrite an unknown edit';
  end if;
  if position('fleet_docked_location' in v_src) > 0 then
    raise exception '0334 PRECONDITION FAIL: the deployed body already composes the docked authority — refusing to re-emit over an unknown edit';
  end if;
  -- and the thing that made this necessary must still be true: the resolver reads no lifecycle
  -- status, so nobody can later claim the destroy path was the cause.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.mainship_resolve_fleet(uuid)')::oid;
  if v_src is null then
    raise exception '0334 PRECONDITION FAIL: mainship_resolve_fleet(uuid) is absent';
  end if;
  if position('destroyed' in v_src) > 0 then
    raise exception '0334 PRECONDITION FAIL: mainship_resolve_fleet now names a lifecycle status — the diagnosis in this header (it is status-blind, so the destroy flip cannot be the cause) no longer holds and must be re-derived before this fix is trusted';
  end if;
end $pre$;

-- ── 1. CAPTURE METADATA BEFORE THE REWRITE (for parity check g) ──────────────────────────────────
create temp table _0334_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0334_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'mainship_port_of_ship';

-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- §1. mainship_port_of_ship — the 20260618000297:104-144 body, BYTE-COPIED, with two marked hunks.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════
-- PARITY: the deployed prosrc was verified byte-identical to 0297:111-143 before this file was
-- written. Signature, return type, language, STABLE, SECURITY DEFINER, `set search_path to 'public'`,
-- the ship read, the not-found return, the resolve_fleet call, ARM 1's precedence and its "a resolved
-- fleet that is NOT docked owns the answer" return, and the closing berth return are all unchanged.
-- The ONLY deltas are the two marked hunks.
create or replace function public.mainship_port_of_ship(p_main_ship_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_ship  public.main_ship_instances%rowtype;
  v_fleet uuid;
  v_loc   uuid;
  -- ★ 0334 HUNK (declare): how many DISTINCT ports the ship's group is tied up at. ★
  v_n     integer;
begin
  select * into v_ship from public.main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then
    return null;
  end if;

  v_fleet := public.mainship_resolve_fleet(p_main_ship_id);

  -- ARM 1 — the ship's FLEET is tied up at a port (get_my_fleet_positions' 'docked' arm, 0231:1069-1076).
  if v_fleet is not null then
    -- ██ 0334 HUNK A — COMPOSE THE DOCKED AUTHORITY INSTEAD OF RE-STATING IT. ████████████████████████
    -- 0297 wrote `f.status = 'present' and f.location_mode = 'location'` inline because it was authored
    -- BEFORE 0306 created public.fleet_docked_location(fleets) and named it "THE docked authority"
    -- (0306:63). Keeping the inline copy while ARM 2 below needs the same test would leave two
    -- spellings of one question in one function. Semantically identical: the leaf returns the location
    -- only for present + location_mode 'location' + a non-null location, which is exactly this test
    -- plus the NULL check the next line already performed.
    select public.fleet_docked_location(f)
      into v_loc
      from public.fleets f
     where f.id = v_fleet
     limit 1;
    -- ██ END 0334 HUNK A ████████████████████████████████████████████████████████████████████████████
    if v_loc is not null then
      return v_loc;
    end if;
    -- A resolved fleet that is NOT docked owns the answer: the ship is with that fleet, wherever it
    -- is, and its berth (NULL under the XOR) has nothing to add.
    return null;
  end if;

  -- ██ 0334 HUNK B — ARM 2: THE SHIP'S GROUP IS TIED UP AT A PORT, SO THE SHIP IS. ████████████████████
  -- THE OWNER'S BUG: "you don't need to tow to a nearest port. As a fleet we have arrived at a dock
  -- already." A ship that owns no per-ship fleet row resolved NOTHING above and, being grouped, can
  -- hold no berth (the 0216 XOR), so it had no position at all — even while its own fleetmates were
  -- reading "Docked at Haven" from their per-ship fleets. This arm asks the question the function was
  -- missing: not "which fleet is mine" but "where is my GROUP".
  --
  -- IT NAMES NO STATUS. This is not a wreck branch — a LIVING grouped ship with no per-ship fleet
  -- falls in the identical hole and is answered identically. Self-assert (c) pins that no lifecycle
  -- status appears anywhere in this body.
  --
  -- THE SET: every live fleet of this player that is DOCKED (by the one authority) and belongs to the
  -- group — either tagged with it, or owned by one of its member ships. Both shapes are real: the
  -- unified fleet carries group_id with main_ship_id NULL, while the legacy per-member envelopes
  -- carry main_ship_id (and may or may not carry group_id — 0204:316).
  --
  -- EXACTLY ONE, OR NOTHING. Two members docked at different ports is a broken invariant; answering
  -- from either one would let a wreck name a port its fleetmates are not at. Fail closed instead: the
  -- ship reads as at no port and mainship_emergency_tow remains its route, exactly as before.
  if v_ship.group_id is not null then
    select count(*), (array_agg(d.loc))[1]
      into v_n, v_loc
      from (select distinct f.current_location_id as loc
              from public.fleets f
             where f.player_id = v_ship.player_id
               and public.fleet_docked_location(f) is not null
               and (f.group_id = v_ship.group_id
                    or exists (select 1
                                 from public.main_ship_instances m
                                where m.main_ship_id = f.main_ship_id
                                  and m.group_id = v_ship.group_id))) d;
    if v_n = 1 then
      return v_loc;
    end if;
  end if;
  -- ██ END 0334 HUNK B — the 0297 body continues verbatim from here ██████████████████████████████████

  -- ARM 2 — the BERTH (get_my_fleet_positions' 'berthed' arm, 0231:1107-1110). No fleet + a berth =
  -- the ship is sitting at that port.
  return v_ship.berth_location_id;
end;
$function$;

comment on function public.mainship_port_of_ship(uuid) is
  'POSITION, not lifecycle (0297, extended 0334): the port this ship is physically at — its fleet''s '
  'dock if it has a resolved fleet, else the ONE port its GROUP is docked at, else its berth — or '
  'NULL if it is at no port. The group arm (0334) exists because a ship that owns no per-ship fleet '
  'row resolves no fleet and, being grouped, can hold no berth under the 0216 XOR, so it had no '
  'position at all while its own fleetmates were docked. It names no status: a living grouped ship '
  'with no per-ship fleet is answered identically. It requires the group''s live docked fleets to '
  'agree on exactly one location, so a ship can never name a port its fleetmates are not at.';

revoke execute on function public.mainship_port_of_ship(uuid) from public, anon, authenticated;
grant  execute on function public.mainship_port_of_ship(uuid) to service_role;

-- ── 2. SELF-ASSERTS — one DO block per check ─────────────────────────────────────────────────────

-- (a) still the same KIND of function, and still not client-callable
do $a$
declare v_vol "char"; v_sec boolean; v_cfg text;
begin
  select p.provolatile, p.prosecdef, coalesce(array_to_string(p.proconfig, ','), '')
    into v_vol, v_sec, v_cfg
    from pg_proc p where p.oid = to_regprocedure('public.mainship_port_of_ship(uuid)')::oid;
  if v_vol <> 's' or not v_sec or v_cfg not like '%search_path=public%' then
    raise exception '0334 ASSERT (a) FAIL: volatility/%, secdef/%, proconfig/% — the position leaf must stay STABLE, SECURITY DEFINER and search_path-pinned', v_vol, v_sec, v_cfg;
  end if;
  if has_function_privilege('authenticated', 'public.mainship_port_of_ship(uuid)', 'execute')
     or has_function_privilege('anon', 'public.mainship_port_of_ship(uuid)', 'execute') then
    raise exception '0334 ASSERT (a) FAIL: the internal position leaf became client-callable';
  end if;
end $a$;

-- (b) it composes the 0306 docked authority, and the hand-inlined copy of that predicate is GONE
-- COMMENTS ARE STRIPPED FIRST — and that is not a formality. This file's own hunk-A comment QUOTES
-- the predicate it deletes ("0297 wrote f.status = 'present' and f.location_mode = 'location'
-- inline…"), and pg_proc.prosrc carries comments, so a raw probe would find the words it is trying
-- to prove absent and fail on a correct body. Same idiom the generated migrations use.
do $b$
declare v_src text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_src
    from pg_proc p where p.oid = to_regprocedure('public.mainship_port_of_ship(uuid)')::oid;
  v_n := (length(v_src) - length(replace(v_src, 'public.fleet_docked_location(f)', '')))
         / length('public.fleet_docked_location(f)');
  if v_n <> 2 then
    raise exception '0334 ASSERT (b) FAIL: % composition(s) of the 0306 docked authority (want exactly 2 — ARM 1''s and the group arm''s)', v_n;
  end if;
  if position('location_mode' in v_src) > 0 then
    raise exception '0334 ASSERT (b) FAIL: the hand-inlined docked predicate is still in the body — two spellings of "is this fleet docked" in one function is the duplication this hunk removes';
  end if;
end $b$;

-- (c) the group arm exists, and the body names NO lifecycle status — there is no wreck special case
do $c$
declare v_src text;
begin
  -- comments stripped: the header and the hunks discuss wrecks and lifecycle in prose, and this
  -- check is about the CODE naming a status, not about the file explaining why it must not.
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_src
    from pg_proc p where p.oid = to_regprocedure('public.mainship_port_of_ship(uuid)')::oid;
  if position('v_ship.group_id is not null' in v_src) = 0 then
    raise exception '0334 ASSERT (c) FAIL: the group arm is absent — a wreck in a docked fleet would still have no position';
  end if;
  if position('count(*), (array_agg(d.loc))[1]' in v_src) = 0 then
    raise exception '0334 ASSERT (c) FAIL: the group arm does not COUNT the distinct docked locations — without the count it could answer from one of several disagreeing members';
  end if;
  if position('destroyed' in v_src) > 0 or position('v_ship.status' in v_src) > 0 then
    raise exception '0334 ASSERT (c) FAIL: the position authority now names a lifecycle status — position must be answered the same way for a wreck and for a living ship, or the two can drift apart again';
  end if;
end $c$;

-- (d) ARM ORDER: own fleet, then the group, then the berth
do $d$
declare v_src text; v_own integer; v_grp integer; v_berth integer;
begin
  -- comments stripped: an arm named in a comment ahead of where it is written would skew the order.
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_src
    from pg_proc p where p.oid = to_regprocedure('public.mainship_port_of_ship(uuid)')::oid;
  v_own   := position('if v_fleet is not null then' in v_src);
  v_grp   := position('if v_ship.group_id is not null then' in v_src);
  v_berth := position('return v_ship.berth_location_id;' in v_src);
  if v_own = 0 or v_grp = 0 or v_berth = 0 then
    raise exception '0334 ASSERT (d) FAIL: own-fleet/group/berth arm not all present (% / % / %) — absence is failure, not a pass', v_own, v_grp, v_berth;
  end if;
  if not (v_own < v_grp and v_grp < v_berth) then
    raise exception '0334 ASSERT (d) FAIL: arm order is % / % / % — a ship whose OWN fleet is in flight must be answered by that fleet (NULL) before the group''s stale dock is ever consulted', v_own, v_grp, v_berth;
  end if;
end $d$;

-- (e) the recovery surface is untouched by this file: repair and the tow still gate on status
do $e$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.repair_main_ship(uuid)')::oid;
  if v_src is null or position('v_ship.status <> ''destroyed''' in v_src) = 0
     or position('ship_not_at_port' in v_src) = 0 or position('mainship_port_of_ship' in v_src) = 0 then
    raise exception '0334 ASSERT (e) FAIL: repair_main_ship is not the 0297 position-gated body — this file must not have touched the recovery surface';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.mainship_emergency_tow(uuid)')::oid;
  if v_src is null or position('v_ship.status <> ''destroyed''' in v_src) = 0
     or position('berth_location_id' in v_src) = 0 or position('group_id = null' in v_src) = 0 then
    raise exception '0334 ASSERT (e) FAIL: mainship_emergency_tow is not the 0297 body — the escape hatch for a wreck that is genuinely nowhere must survive this slice intact';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_my_disabled_ships()')::oid;
  if v_src is null or position('mainship_port_of_ship' in v_src) = 0 then
    raise exception '0334 ASSERT (e) FAIL: get_my_disabled_ships no longer answers from the position authority — the client would stop seeing what the server decides';
  end if;
end $e$;

-- (f) ZERO-WRITE PROBES — valid on a completely EMPTY dataset, and they write nothing
do $f$
begin
  if public.mainship_port_of_ship(gen_random_uuid()) is not null then
    raise exception '0334 ASSERT (f) FAIL: the leaf invented a port for a nonexistent ship';
  end if;
end $f$;

-- (g) metadata parity: the function changed body and NOTHING else
do $g$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0334_before loop
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
      raise exception '0334 ASSERT (g) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0334 ASSERT (g) FAIL: public.% body is byte-identical — the hunks did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0334 ASSERT (g) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0334 SELF-ASSERT PASS: a ship whose GROUP holds exactly one docked fleet now resolves that port through the ONE position authority — status is named nowhere in it, the 0306 docked authority is composed twice and inlined zero times, the own-fleet arm still answers first, and repair/tow/list are untouched';
end $g$;

commit;
