-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0352 — A SORTIE KNOWS WHERE HOME IS
--        the return destination is decided ONCE, by one leaf, and a fleet that never chose one
--        still has one — because its anchor was never a choice, it was always a fact
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE DEFECT, MEASURED ON PRODUCTION (read-only, 2026-08-09, prod head 20260618000349) ─────────
--
-- A sortie can be created with no return port, and the code that discovers this AT THE END silently
-- drops the whole fleet into nowhere. It happened to the owner twice today, ninety minutes apart,
-- and the second time was measured WHILE THIS FILE WAS BEING WRITTEN.
--
-- THE FIRST RUN, from the rows themselves (player 218500ff…, group df4649fc…):
--   12:37:49  command_ship_group_go minted group fleet 972e97c1 and movement a69da1e1
--             (mission 'rally', origin_type 'location' = Haven b1a00001, target 'space' (-50,101)).
--             A *go* fleet carries no return_location_id — command_ship_group_go does not mention
--             the column at all; the ONLY functions in the deployed schema that do are
--             fleet_return_port (new, below), nohome_dock_returning_ship and send_ship_group_hunt.
--   12:38:19  pirate_intercept_resolve_due_for_movement fired. It cancelled the leg, parked the
--             fleet with fleet_set_in_space, and FROZE group_sortie_members on that same fleet —
--             its own comment says the INSERT is "byte-identical to send_ship_group_hunt's
--             sole-writer freeze" (0301:150-168). It never sets return_location_id. So the ambush
--             converts a travel leg into a manifest-carrying SORTIE with no return port BY
--             CONSTRUCTION. That is the cause of the first incident.
--   13:08:30  the fight ended; process_combat_ticks minted movement b37f33cc — mission
--             'return_home', target_type 'base', target_base_id e0d7f142, which is the fleet's own
--             origin_base_id and the owner's Haven base.
--   13:08:52  arrival → movement_settle_arrival's 'base' arm → fleet_complete → status 'completed',
--             location_mode 'base', current_location_id NULL.
--   13:09:47  process_mainship_expeditions ran nohome_dock_returning_ship per ship. Step [R1] found
--             no tagged fleet with a non-null return_location_id; step [R2] found the manifest fleet
--             972e97c1 but its `return_location_id is not null` filter EXCLUDED it. v_return stayed
--             NULL and the arm at 0349's :45-48 wrote `status='home'` and RETURNED — no fleet, no
--             presence, no port.
--
-- THE SECOND RUN, three minutes before this paragraph was written:
--   14:04:55  encounter 93116cd0 opened on group fleet 6f7665a9 — again manifest-carrying, again
--             return_location_id NULL, again anchored at Haven.
--   14:25:30  four of the five ships destroyed.
--   14:26:21  the survivor Sparrow (8f59d19c) → status='home'. Measured at 14:28:06:
--             mainship_resolve_fleet returns NULL for all five ships, the player owns ZERO live
--             fleets, and the client therefore renders "Location unknown · Nothing reported".
--
-- ── WHY IT IS A ONE-AUTHORITY DEFECT AND NOT A MISSING WRITE ─────────────────────────────────────
-- The reflex fix is "make the ambush set return_location_id too". That would make FIVE places that
-- decide where a fleet comes home to. In the deployed send_ship_group_hunt there are already FOUR,
-- and one of them admits in its own comment that it may decide NOTHING:
--   :247  consuming arm, present@port   v_return := coalesce(p_return_location_id, v_gf.current_location_id);
--   :254  consuming arm, in space       v_return := p_return_location_id;
--         …"the return port is only what the caller chose (NULL → the reconciler's re-home path)"
--   :259  consuming arm, idle at anchor v_return := p_return_location_id;
--   :434  launch-from-dock arm          v_return := coalesce(p_return_location_id, v_dock_loc);
--   plus the 0168 dark tail (:547), which mints a fleet and sets no v_return at all.
-- Four deciders, three answers, one of them NULL — and a fifth site (the ambush) that never knew it
-- was deciding anything. So the column is not the authority; nothing is. This file gives the
-- question ONE answerer and stops every site from answering it.
--
-- ── THE FALLBACK, AND THE NUMBERS THAT CHOSE IT (all measured on production 2026-08-09) ──────────
-- Four candidates were compared over all 91 production fleets:
--
--   candidate                                                       resolves to an ACTIVE port
--   A  fleets.origin_base_id → bases.location_id                    91 / 91
--   B  the departure port (fleet_movements.origin_type='location'
--      → origin_location_id, first leg)                             63 / 91  (28 fleets have no
--                                                                    such leg AT ALL)
--   C  the player's oldest active base's port                       91 / 91  — and IDENTICAL to A
--                                                                    on 91 of 91 (origin_base_id =
--                                                                    the oldest active base on
--                                                                    every fleet; 0 exceptions)
--   D  the group's last dock                                        not a stored fact; would have
--                                                                    to be re-derived from B
--
--   bases: 471 rows, ALL status='active', ALL location_id non-null, ALL naming an ACTIVE location.
--   Zero exceptions. 73 distinct players own ships and ZERO of them lack an active base with a port.
--
-- A IS CHOSEN, and the deciding argument is not totality — C is equally total — it is that A IS
-- WHERE THE FLEET PHYSICALLY LANDS:
--   * ALL THREE functions that mint a 'return_home' leg fly to `bases` joined on the fleet's own
--     origin_base_id: process_combat_ticks (the fight's terminal arm), presence_request_leave and
--     combat_flee_pending. Three of three, no exceptions.
--   * 49 of 49 return_home legs with target_type='base' in the whole movement history targeted
--     exactly fleets.origin_base_id.
--   * bases.x/y equals its port's locations.x/y on 471 of 471 rows, so the coordinate the leg flies
--     to IS the port A names. Docking the ships anywhere else would be a teleport away from their
--     own fleet — the class of bug 0349 was written to end.
--   * fleet_complete then writes `current_base_id = origin_base_id`, so after a base-arm arrival the
--     fleet's own recorded place is already that base.
-- B was rejected on both counts: it is partial (28 fleets), and it DISAGREES with A on 49 of the 63
-- fleets where both resolve — i.e. using it would dock ships at a port their fleet did not fly to.
-- C was rejected because it is A re-derived: reading the fleet's own column is one authority,
-- re-deriving "the oldest active base" beside it is two, and 0214's review already recorded what
-- happens when a resolver prefers a differently-derived base.
--
-- WHEN A ITSELF RESOLVES TO NOTHING: only if the fleet has no origin_base_id, or its base names a
-- location that is no longer active. §2 makes the first impossible for the only fleet shape that can
-- become a sortie; the second is a world edit, and the answer is then NULL and the reconciler makes
-- NO WRITE AT ALL — see the fail-closed discussion below. It is 0 rows today.
--
-- ── IS "HOME WITH NO PORT" EVER LEGITIMATE? NO. ──────────────────────────────────────────────────
-- main_ship_instances.status='home' is not by itself the abstract-base state: it is also what
-- mainship_mark_docked_at_location writes for a DOCKED ship. What distinguishes the two is whether
-- the ship has a fleet that says where it is. 'home' PLUS no fleet is the state the NO-HOME law
-- deleted, and it is unreadable by the game: mainship_resolve_fleet returns NULL, so no verb can
-- act on the ship and the client has nothing to draw. Production carries 5 ships in exactly that
-- pair right now, 4 of them the owner's.
--
-- 0349 made that arm deliberately fail-closed and wrote down why: "a ship with only stale records is
-- left where it is, never sent to a stranger's port." THAT REASONING IS KEPT, IN FULL — and this
-- file is the first time the statement under it actually implements it. The write it guarded was
-- `update main_ship_instances set status='home'`, which does not leave the ship where it is; it
-- moves it to the abstract home and strands it. Two things are separated so both can be honoured:
--   * WHOSE PORT — 0349's real concern. The anchor is fleets.origin_base_id, and the leaf requires
--     bases.player_id = fleets.player_id, so it is the ship owner's own base BY CONSTRUCTION. A
--     stranger's port is not reachable through this path at all.
--   * WHICH SORTIE — 0349's TTL. A CHOSEN port belongs to one sortie and goes stale (the 17-day
--     corpse that sent one ship to Slagworks and four to Haven), so the leaf keeps 0349's
--     fleet_sortie_still_speaks fence on it, unchanged. The ANCHOR does not go stale: it is the
--     same value on every one of the owner's 44 fleets and equals the oldest active base on 91 of
--     91 game-wide. Ageing out a fact that cannot drift buys nothing and costs the ship its home.
-- So the terminal arm is now a genuine NO-OP with a NOTICE: nothing is written, and the ship keeps
-- whatever state it had. It can no longer CREATE the location-less pair. It is unreachable for any
-- ship that has a fleet of any kind (measured: 0 ships mid-sortie without one).
--
-- ── THE ONE LEAF, AND EVERY SITE THAT COMPOSES IT ────────────────────────────────────────────────
--
-- §1  public.fleet_return_port(p_fleet uuid)  — THE authority for "where does this fleet come home
--     to". Precedence, decided here and nowhere else:
--       1. the sortie's OWN recorded choice (fleets.return_location_id), while that sortie still
--          speaks (0349's public.fleet_sortie_still_speaks, composed, not re-spelled) and while the
--          port is still an active location;
--       2. the fleet's ANCHOR — the active port of its own origin_base_id, owned by its own player.
--     Nothing else. No third rule, no per-caller variation.
--
--     WHO COMPOSES IT, and who deliberately does not:
--       * nohome_dock_returning_ship (§4) — the only reader. It picks the ONE fleet that speaks for
--         a ship and asks the leaf. It no longer touches `bases`; assert (c) pins that.
--       * command_ship_group_go — UNCHANGED in this respect, and that is the whole point of the
--         design. The fleet it mints already carries origin_base_id, so the leaf answers for it
--         without the mover learning a new concept. Its only edit here (§3 [S3]) is a guard.
--       * pirate_intercept_resolve_due_for_movement — UNTOUCHED, same reason. The ambush that
--         caused this incident needs no line: the fleet it freezes a manifest onto can already
--         answer. Assert (g) pins that it was not re-created.
--       * send_ship_group_hunt (§3 [S1]/[S2]) — its FOUR deciders collapse to ONE rule:
--             v_return := coalesce(p_return_location_id, v_o_loc);
--         the caller's explicit choice, else the port THIS ARM already decided it sails from. It is
--         behaviour-identical to all four sites it replaces — in the two space/anchor arms v_o_loc is
--         NULL, which is exactly what they wrote — so this is a pure de-duplication with no
--         behavioural risk, and the NULL it can still record is now SAFE because the leaf supplies
--         the anchor. It appears TWICE, in two mutually exclusive arms of one function, byte for
--         byte identical; assert (d) pins that there is no third spelling and no other v_return
--         assignment anywhere in the body. Collapsing the two into one textual site would mean
--         restructuring the function's arm layout, which is a larger edit than this slice earns; the
--         property that matters — NO ARM DECIDES ITS OWN FALLBACK — holds, and is enforced.
--
-- §2  THE STRUCTURE, so the leaf can always answer.
--       * bases.location_id → NOT NULL. A base IS a port. 471/471 already comply; both writers
--         (initialize_new_player, get_or_create_store) already supply it; no function in the schema
--         UPDATEs it and none DELETEs from bases (all measured from the catalog).
--       * a new CHECK, fleets_group_fleet_has_anchor:
--             not (group_id is not null and main_ship_id is null) or origin_base_id is not null
--         "a GROUP fleet — the only shape that can become a sortie — must have an anchor." That
--         shape is not chosen for convenience: it is the exact predicate
--         pirate_intercept_resolve_due_for_movement uses to decide a fleet is still ambushable
--         (0301:76-77 cancels when `group_id is null or main_ship_id is not null`). 0 of 24 live
--         group fleets violate it; 0 of 91 fleets overall.
--
--     WHY NOT `fleets.origin_base_id NOT NULL`, WHICH WOULD BE STRONGER — because it would break the
--     first action a new player ever takes. port_entry_commission_build's own comment says
--     "origin_base_id = the player's base if one exists, else NULL", and it mints the commissioning
--     fleet. A blanket NOT NULL turns a tolerated NULL into a hard failure of first-ship
--     commissioning on a LIVE game. The CHECK is scoped to the shape that actually needs the
--     guarantee and leaves the per-ship commissioning fleet alone.
--
--     EVERY WRITER THAT COULD VIOLATE THE NEW CHECK IS FIXED IN THIS FILE, or it would trade a
--     silent bug for a raw 23514 in a live RPC (the half-slice trap):
--       * send_ship_group_hunt — all THREE of its inserts already guard with `no_home_base`. No edit.
--       * command_ship_group_go — its mint at 0330's :670-675 selects the base and inserts with NO
--         null check, while the SAME function already returns 'no_origin' for that condition sixty
--         lines earlier. [S3] adds the guard, reusing that existing reason code. This is also the
--         literal answer to "a sortie can still be created without a resolvable return": before this
--         hunk, it could.
--       * assign_ship_to_group — its heal-mint has no guard either, and its own comment insists the
--         branch must "no-op rather than fail a roster operation over a world-data change". [S4]
--         makes it skip the mint instead of raising, which is that comment's own posture.
--       * fleet_create / port_entry_commission_build / nohome_dock_returning_ship's H1 mint — all
--         main_ship_id-tagged or group-less, so the CHECK exempts them. nohome's mint gains the
--         anchor anyway (§4): it was the ONE fleet-creating path in the schema that set no
--         origin_base_id, which meant a returning ship's new fleet could not itself come home.
--
-- §3  the hunk surgery — send_ship_group_hunt (31,925 chars deployed), command_ship_group_go
--     (44,575) and assign_ship_to_group. Read from the catalog at apply time, every hunk proved to
--     occur EXACTLY ONCE, accumulated in memory and executed ONCE PER FUNCTION (the 0346 shape —
--     never per hunk, so no intermediate body is ever created). Verified read-only against
--     PRODUCTION before this file was finalised: each old_t occurs exactly once in the deployed
--     definition.
--
-- §4  nohome_dock_returning_ship — RE-EMITTED WHOLE, from 0349's own text (5,660 chars; small
--     enough that surgery would be less legible than the body). 0349 left it asking one question
--     twice — the ship's own tagged fleet, then its manifest — with the same ordering spelled out in
--     both, which is why 0349's own fix says "three changes, IDENTICAL IN BOTH STEPS". Two spellings
--     of one question is the disease. The two reads become ONE union with ONE ordering that
--     reproduces 0349's precedence exactly and adds nothing:
--       1. a fleet the leaf can answer for beats one it cannot;
--       2. a fleet whose RECORDED choice still speaks beats one contributing only its anchor
--          (0349's `return_location_id is not null` + the TTL fence, hoisted from an EXCLUSION into
--          a PREFERENCE — which is precisely the change that stops the fall-through into nowhere);
--       3. the ship's OWN tagged fleet beats a manifest fleet (0349 step (a) before step (b));
--       4. a live fleet beats a corpse (0349 [R1]/[R2]);
--       5. updated_at desc, id desc — the TOTAL tie-break, for the reason 0349 gives.
--     0349's [R3] H1 reuse fence is carried through unchanged.
--
-- ── NO FEATURE FLAG, AND NO NEW NUMBER ───────────────────────────────────────────────────────────
-- This file ships LIT (the standing order). It introduces NO game_config key and no literal
-- threshold: the one threshold it depends on is 0349's existing sortie_manifest_ttl_seconds, read
-- through 0349's own predicate. Assert (h) pins that game_config gained nothing.
--
-- ── WHAT HAPPENS TO SORTIES IN FLIGHT AT APPLY TIME ──────────────────────────────────────────────
-- Blast radius is a LIVE ~30-player game. Measured at 14:27:35 UTC, minutes before this file was
-- finalised: 0 fleet_movements with status='moving', 0 combat_encounters in 'active'/'retreating',
-- 0 ships in any status other than 'home'/'destroyed', 8 active location presences, and exactly ONE
-- manifest-carrying fleet (6f7665a9, 5 rows, return_location_id NULL, anchor → Haven). Re-measure
-- immediately before deploying; the numbers move by the minute and one of them moved twice while
-- this file was written.
--
-- The general statement, which does not depend on those counts:
--   * A FLEET MID-LEG. Untouched. No movement row, no fleet row and no ship row is written by this
--     file. Its leg settles exactly as it would have.
--   * A FLEET MID-FIGHT. Untouched. process_combat_ticks is not re-created (assert (g)) and its
--     terminal arm still flies to origin_base_id. The only difference is at the END: when its ships
--     reach nohome_dock_returning_ship they now dock at the port the fleet actually landed at,
--     instead of being written 'home' with no fleet. The single in-flight sortie measured above
--     gains a resolvable return port THE INSTANT THIS COMMITS, with no write to it — the leaf
--     derives it from a column that was already there.
--   * A SHIP ALREADY STRANDED. Not repaired. Those ships are status='home', which the reconciler's
--     candidate set does not include, so nothing here reaches them. Repairing the owner's five is a
--     separate, rehearsed operation (scripts/repair-owner-fleet-0349.sql is the precedent) and it
--     must not be smuggled into a behaviour fix — especially not while that same group has just
--     started another sortie. THIS FILE STOPS NEW STRANDINGS; IT DOES NOT UNDO THE OLD ONE.
--   * AN ORDER IN FLIGHT AT THE INSTANT OF APPLY. The two DDL statements in §2 take a brief
--     ACCESS EXCLUSIVE lock on `bases` (471 rows) and `fleets` (91 rows); a concurrent RPC or cron
--     tick blocks for that scan and then runs against the new bodies. Both validations pass on the
--     current data (0 violations, measured), so neither can abort the deploy on live rows.
--   * A CONCURRENT RECONCILER PASS. process_mainship_expeditions runs every 30 seconds. It either
--     completes before this transaction takes its locks (old behaviour, one more pass of the
--     defect) or after it (new behaviour). There is no interleaved state: the whole file is one
--     transaction.
--
-- ── ROLLBACK BOUNDARY ────────────────────────────────────────────────────────────────────────────
-- The whole file is ONE transaction. Any self-assert failure rolls back everything — the leaf, both
-- constraints and all four function bodies — and leaves the deployed 0349/0330/0337-era bodies
-- exactly as they are; the chain head does not move.
--
-- After a COMMITTED apply the manual undo is, in this order:
--   1. `alter table public.fleets drop constraint fleets_group_fleet_has_anchor;`
--   2. `alter table public.bases alter column location_id drop not null;`
--   3. restore the four function bodies. Three of them (send_ship_group_hunt,
--      command_ship_group_go, assign_ship_to_group) are restored by applying each hunk in REVERSE —
--      the new_t and old_t texts are both in §3 of this file, verbatim, and each is proved to occur
--      exactly once at apply time in the forward direction. nohome_dock_returning_ship is restored
--      by re-running migration 20260618000349's §4 block verbatim.
--   4. `drop function public.fleet_return_port(uuid);` — LAST, because step 3 must remove its only
--      caller first.
-- No column is added or dropped, NO ROW OF PLAYER DATA IS WRITTEN, READ-MODIFIED OR DELETED by this
-- file, and no game_config value changes. A rollback therefore restores the exact prior behaviour
-- with no data reconciliation of any kind.
--
-- ── EXPLICIT NON-GOALS, AND ONE KNOWN OPEN INSTANCE NAMED BUT NOT FIXED HERE ─────────────────────
-- NOT the repair of the five stranded ships (above). NOT the retirement of the 0198 dark head in
-- process_mainship_expeditions (0349 named it; still its own slice). NOT the anon/authenticated
-- INSERT/UPDATE/DELETE grants that production still carries on public.fleets — the 2026-07-20
-- danger_zones drift class, measured again today, real and out of scope for a behaviour fix.
--
-- NAMED, NOT FIXED — THE SAME DISEASE, ONE FUNCTION AWAY: `0299:608-618` resolves a chosen
-- destination to raw coordinates and mints a 'space' leg with them, discarding the fact that a PORT
-- was chosen. A decided destination that nothing owns is exactly what this file is about, and that
-- one is still open. It belongs to the retreat/settle slice, not to this one, because fixing it
-- means changing which settle arm a chosen-port retreat lands in — a behaviour change to the exit
-- the owner's design makes the goal.
--
-- A SECOND OPEN INSTANCE, FOUND WHILE MEASURING THIS ONE AND NOT FIXED: a recorded return port can
-- name a DIFFERENT port from the anchor the return leg physically flies to (production carries one
-- such fleet: 2dcd22b0 recorded Slagworks, anchored Haven). Today the leg wins and the ships follow
-- the recorded choice — a divergence that predates this file and that this file deliberately does
-- not change, because closing it means deciding whether the leg or the choice is authoritative.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;

-- ── §0 PRE-IMAGE for the metadata-parity assert (g) — the 0332/0349 capture idiom, verbatim ──────
create temp table _0352_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0352_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('nohome_dock_returning_ship', 'send_ship_group_hunt',
                     'command_ship_group_go', 'assign_ship_to_group');

-- game_config must gain NOTHING (assert (h)). Captured as a count AND as a checksum of the key set,
-- so a swap (one key added, one removed) cannot pass as "unchanged".
create temp table _0352_cfg_before (n integer, keys_md5 text) on commit drop;
insert into _0352_cfg_before
select count(*), md5(coalesce(string_agg(key, ',' order by key), '')) from public.game_config;

-- ═══ §1 THE LEAF — the ONE thing that decides where a fleet comes home to ════════════════════════
create or replace function public.fleet_return_port(p_fleet uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
           -- (1) THE SORTIE'S OWN RECORDED CHOICE. Fenced by 0349's TTL predicate, composed rather
           --     than re-spelled: a chosen port belongs to ONE sortie, and the seventeen-day corpse
           --     that sent one of the owner's ships to Slagworks is exactly what that fence is for.
           (select l.id
              from public.locations l
             where l.id = f.return_location_id
               and l.status = 'active'
               and public.fleet_sortie_still_speaks(f.status, f.updated_at)),
           -- (2) THE FLEET'S ANCHOR. Not a choice — a fact, and the one the game already acts on:
           --     every 'return_home' leg in the schema (process_combat_ticks, presence_request_leave,
           --     combat_flee_pending) flies to `bases` joined on this same origin_base_id, and
           --     bases.x/y equals its port's coordinate on every row in production. So this is the
           --     port the fleet PHYSICALLY arrives at, not a second opinion about where it should be.
           --     b.player_id = f.player_id is what makes "never a stranger's port" structural rather
           --     than argued: the anchor can only ever be a base of the fleet's own owner.
           (select l.id
              from public.bases b
              join public.locations l on l.id = b.location_id
             where b.id = f.origin_base_id
               and b.player_id = f.player_id
               and b.status = 'active'
               and l.status = 'active')
         )
    from public.fleets f
   where f.id = p_fleet;
$$;
comment on function public.fleet_return_port(uuid) is
  '0352: THE ONE authority for "which port does this fleet come home to". The sortie''s own recorded '
  'return_location_id while that sortie still speaks (0349''s fleet_sortie_still_speaks), else the '
  'active port of its own origin_base_id — the anchor every return_home leg in the schema already '
  'flies to. Composed by nohome_dock_returning_ship and by nothing else; a caller that needs the '
  'answer composes this, it does not re-derive it. Returns NULL only for a fleet that does not '
  'exist or whose anchor names a location that is no longer active.';
revoke execute on function public.fleet_return_port(uuid) from public, anon;
grant  execute on function public.fleet_return_port(uuid) to authenticated, service_role;

-- ═══ §2 THE STRUCTURE — so the leaf can always answer for a sortie ═══════════════════════════════

-- A BASE IS A PORT. 471 of 471 production rows already comply; both writers already supply it; no
-- function UPDATEs the column and none DELETEs from the table (measured from the catalog).
alter table public.bases alter column location_id set not null;

-- A GROUP FLEET — the only shape that can become a sortie — MUST HAVE AN ANCHOR.
-- The shape is not invented here: `group_id is not null and main_ship_id is null` is the exact
-- predicate pirate_intercept_resolve_due_for_movement uses to decide a fleet is still the unified
-- group shape it ambushed (0301:76-77). A per-ship fleet (main_ship_id set) and a group-less fleet
-- are both exempt, which is what keeps first-ship commissioning working — see the header.
alter table public.fleets
  add constraint fleets_group_fleet_has_anchor
  check (not (group_id is not null and main_ship_id is null) or origin_base_id is not null);
comment on constraint fleets_group_fleet_has_anchor on public.fleets is
  '0352: a fleet that can become a SORTIE (the unified group shape: group_id set, main_ship_id NULL) '
  'must carry an anchor, because public.fleet_return_port falls back to that anchor and a sortie with '
  'no resolvable return is how five of the owner''s ships ended up with no location at all. Every '
  'writer of this shape guards it: send_ship_group_hunt returns no_home_base, command_ship_group_go '
  'returns no_origin, assign_ship_to_group skips its heal-mint.';

-- ═══ §3 THE SURGERY — three deployed bodies, read from the catalog, one CREATE each ══════════════
-- The 0346 shape exactly: every body is read ONCE, every hunk is applied to an IN-MEMORY text with
-- an exactly-once probe, and the catalog is written ONCE PER FUNCTION at the end. Nothing executes
-- inside the hunk loop, so no intermediate body is ever created and hunk order is not load-bearing.
do $rewrite$
declare
  r record;
  v_oid oid;
  v_src text;
  v_new text;
  v_n integer;
  v_done integer := 0;
  v_exec integer := 0;
  v_fn   text;
  v_fns  text[] := array['send_ship_group_hunt', 'command_ship_group_go', 'assign_ship_to_group'];
  v_orig jsonb  := '{}'::jsonb;
  v_texts jsonb := '{}'::jsonb;
begin
  foreach v_fn in array v_fns loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_oid is null then
      raise exception '0352 REWRITE FAIL: function public.% not found', v_fn;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = v_fn) <> 1 then
      raise exception '0352 REWRITE FAIL: public.% is overloaded — refusing to guess', v_fn;
    end if;
    v_src   := pg_get_functiondef(v_oid);
    v_orig  := jsonb_set(v_orig,  array[v_fn], to_jsonb(v_src));
    v_texts := jsonb_set(v_texts, array[v_fn], to_jsonb(v_src));
  end loop;

  for r in
    select * from (values

    -- ── [S1] send_ship_group_hunt, the CONSUMING arm — three deciders become none ───────────────
    -- The whole origin if/elsif/else chain is sliced as one hunk because `v_return :=
    -- p_return_location_id;` occurs twice inside it and neither line is addressable alone. The
    -- origin decision itself is untouched, byte for byte; only the three return-port assignments
    -- leave, replaced by ONE line after the chain that reads the origin the chain just chose.
    (1, 'send_ship_group_hunt',
     $s1o$        v_o_type := 'location'; v_o_base := null; v_o_zone := v_gfl.zone_id; v_o_loc := v_gfl.id;
        v_o_x := v_gfl.x; v_o_y := v_gfl.y;
        -- the return port defaults to the port the fleet sails from (the 0199 launch-branch rule).
        v_return := coalesce(p_return_location_id, v_gf.current_location_id);
      elsif v_gf.location_mode = 'space' then
        -- Parked in open space (0208/0209) — depart the fleet's OWN coordinate. No port origin, so
        -- the return port is only what the caller chose (NULL → the reconciler's re-home path,
        -- exactly as the 0168 head's fleets carry no return_location_id).
        v_o_type := 'space'; v_o_base := null; v_o_zone := null; v_o_loc := null;
        v_o_x := v_gf.space_x; v_o_y := v_gf.space_y;
        v_return := p_return_location_id;
      else
        -- Idle at its anchor (the mover's fall-through place, 0208:447-461): depart the base.
        v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
        v_o_x := v_base.x; v_o_y := v_base.y;
        v_return := p_return_location_id;
      end if;$s1o$,
     $s1n$        v_o_type := 'location'; v_o_base := null; v_o_zone := v_gfl.zone_id; v_o_loc := v_gfl.id;
        v_o_x := v_gfl.x; v_o_y := v_gfl.y;
      elsif v_gf.location_mode = 'space' then
        -- Parked in open space (0208/0209) — depart the fleet's OWN coordinate. No port origin.
        v_o_type := 'space'; v_o_base := null; v_o_zone := null; v_o_loc := null;
        v_o_x := v_gf.space_x; v_o_y := v_gf.space_y;
      else
        -- Idle at its anchor (the mover's fall-through place, 0208:447-461): depart the base.
        v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
        v_o_x := v_base.x; v_o_y := v_base.y;
      end if;
      -- ★ 0352: THE RETURN PORT IS DECIDED ONCE, HERE, FOR ALL THREE ARMS ABOVE. The head decided it
      -- ★ three times — coalesce(chosen, current_location_id) in the port arm and a bare `chosen` in
      -- ★ the other two — and one of those comments admitted the result could be NULL and said so as
      -- ★ if it were a design ("NULL → the reconciler's re-home path"). It was not: a sortie with no
      -- ★ recorded port and no owner of the question is how the owner's five ships lost their
      -- ★ location twice in one day. This line is BEHAVIOUR-IDENTICAL to all three it replaces —
      -- ★ v_o_loc is the port arm's own current_location_id and is NULL in the other two — so this
      -- ★ hunk changes nothing about what is recorded. What changed is that a NULL is now SAFE:
      -- ★ public.fleet_return_port answers from the fleet's anchor when nothing was recorded.
      -- ★ The record is the OVERRIDE; the leaf is the ANSWER.
      v_return := coalesce(p_return_location_id, v_o_loc);$s1n$),

    -- ── [S2] send_ship_group_hunt, the LAUNCH-FROM-DOCK arm — the same one rule ─────────────────
    -- v_o_loc is set here so the rule is spelled IDENTICALLY in both arms; this arm previously
    -- carried its origin only in v_dock_loc and passed it straight to movement_create.
    (2, 'send_ship_group_hunt',
     $s2o$    v_dock_loc := v_cur.location_id;
    v_return   := coalesce(p_return_location_id, v_dock_loc);$s2o$,
     $s2n$    v_dock_loc := v_cur.location_id;
    -- ★ 0352: the SAME one rule as the consuming arm, byte for byte. v_o_loc is this arm's origin
    -- ★ port, which it already had under another name; naming it the same thing is what lets the
    -- ★ rule be one rule instead of two that happen to agree. Assert (d) pins that the body carries
    -- ★ exactly two `v_return :=` and that both are this text.
    v_o_loc    := v_dock_loc;
    v_return := coalesce(p_return_location_id, v_o_loc);$s2n$),

    -- ── [S3] command_ship_group_go — a sortie cannot be minted without an anchor ────────────────
    -- This is the literal answer to "a sortie can still be created without a resolvable return":
    -- before this hunk it could. The mover selects the player's first active base and inserts it as
    -- origin_base_id with no null check, while the SAME function already returns 'no_origin' for
    -- exactly that condition in its other origin arm (0330:605-608). The reason code is reused, not
    -- invented, so no client copy changes.
    (3, 'command_ship_group_go',
     $s3o$    select b.id into v_base
      from public.bases b where b.player_id = v_player and b.status = 'active'
      order by b.created_at limit 1;
    insert into public.fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
      values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
      returning id into v_fleet;$s3o$,
     $s3n$    select b.id into v_base
      from public.bases b where b.player_id = v_player and b.status = 'active'
      order by b.created_at limit 1;
    -- ★ 0352: REFUSE RATHER THAN MINT AN ANCHORLESS SORTIE. origin_base_id is what
    -- ★ public.fleet_return_port falls back to, and what all three return_home legs in the schema
    -- ★ physically fly to; a group fleet without one is a sortie that cannot come home. The guard is
    -- ★ the one the other origin arm of this same function already uses, with its reason code, so
    -- ★ the envelope the client receives is one it already renders. It is also what keeps
    -- ★ fleets_group_fleet_has_anchor from surfacing as a raw CHECK violation in a live RPC.
    if v_base.id is null then
      return jsonb_build_object('ok', false, 'reason', 'no_origin');
    end if;
    insert into public.fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
      values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
      returning id into v_fleet;$s3n$),

    -- ── [S4] assign_ship_to_group — skip the heal-mint rather than raise ────────────────────────
    -- This branch's own comment (0330-era) says it must "no-op rather than fail a roster operation
    -- over a world-data change" when the berth is not dockable. A player with no active base is the
    -- same class of world state, and the same posture is the right one: mint nothing, leave the
    -- group fleetless-non-empty, and let the first go/hunt heal it — both of which now refuse
    -- cleanly rather than minting an anchorless fleet.
    (4, 'assign_ship_to_group',
     $s4o$    insert into public.fleets
      (player_id, origin_base_id, status, location_mode, current_base_id,
       current_location_id, current_zone_id, current_sector_id, group_id)
    values (v_player, v_base, 'present', 'location', null,
            v_ship_berth, v_zone, v_sector, v_group)
    returning id into v_mint;
    perform public.presence_create(v_player, v_mint, v_sector, v_zone, v_ship_berth, 'none');$s4o$,
     $s4n$    -- ★ 0352: no anchor, no mint. A group fleet without origin_base_id cannot answer
    -- ★ public.fleet_return_port and is refused by fleets_group_fleet_has_anchor; this branch's own
    -- ★ documented posture for un-mintable world state is to skip, not to fail the roster op.
    if v_base is not null then
      insert into public.fleets
        (player_id, origin_base_id, status, location_mode, current_base_id,
         current_location_id, current_zone_id, current_sector_id, group_id)
      values (v_player, v_base, 'present', 'location', null,
              v_ship_berth, v_zone, v_sector, v_group)
      returning id into v_mint;
      perform public.presence_create(v_player, v_mint, v_sector, v_zone, v_ship_berth, 'none');
    end if;$s4n$)

    ) as t(idx, fname, old_t, new_t)
    order by 1
  loop
    if not v_texts ? r.fname then
      raise exception '0352 REWRITE FAIL [%]: public.% was not read into the working set', r.idx, r.fname;
    end if;
    v_src := v_texts ->> r.fname;
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0352 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was sliced against',
        r.idx, v_n, r.fname;
    end if;
    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0352 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    if v_new = v_src then
      raise exception '0352 REWRITE FAIL [%]: the rewrite of public.% produced a byte-identical body — the hunk did not land', r.idx, r.fname;
    end if;
    v_texts := jsonb_set(v_texts, array[r.fname], to_jsonb(v_new));
    v_done := v_done + 1;
  end loop;

  -- The number of rows in this block's own VALUES list. Nothing in the world can move it.
  if v_done <> 4 then
    raise exception '0352 REWRITE FAIL: applied % hunk(s), expected 4', v_done;
  end if;

  foreach v_fn in array v_fns loop
    if (v_texts ->> v_fn) = (v_orig ->> v_fn) then
      raise exception '0352 REWRITE FAIL: public.% is byte-identical to the body that was read — no hunk landed on it', v_fn;
    end if;
    execute v_texts ->> v_fn;
    v_exec := v_exec + 1;
  end loop;
  if v_exec <> 3 then
    raise exception '0352 REWRITE FAIL: re-created % function(s), expected 3', v_exec;
  end if;
end $rewrite$;

-- ═══ §4 nohome_dock_returning_ship — one question, asked once, answered by the leaf ══════════════
-- Re-emitted from 0349's own §4 text (the pre-image; parity assert (g) pins that only the body
-- changed). CHANGED, and nothing else:
--   [R1+R2] the two near-identical candidate reads become ONE union with ONE ordering
--   [R4]    the port comes from public.fleet_return_port — this function no longer touches `bases`
--   [R5]    the no-port arm makes NO WRITE (it was writing the location-less 'home' pair)
--   [R6]    the H1 mint carries the anchor of the fleet the ship is returning from
create or replace function public.nohome_dock_returning_ship(p_main_ship_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid;
  v_src      uuid;   -- the ONE fleet that speaks for this ship
  v_anchor   uuid;   -- that fleet's origin base, inherited by the tagged fleet minted below
  v_return   uuid;
  v_fleet    uuid;   -- the ship's OWN main_ship_id-tagged fleet that will host its docked presence
  v_loc      record;
begin
  -- ★ 0352 [R1+R2]: 0349 asked one question twice — the ship's own tagged fleet, then its manifest —
  -- ★ with the same ordering spelled out in both, which is why 0349's own fix reads "three changes,
  -- ★ IDENTICAL IN BOTH STEPS". Two spellings of one question is the disease this repo is named
  -- ★ after. ONE candidate set, ONE ordering, and the port itself from the ONE leaf.
  -- ★ The ordering reproduces 0349's precedence exactly and adds nothing:
  -- ★   1. a fleet the leaf can answer for beats one it cannot;
  -- ★   2. a fleet whose RECORDED choice still speaks beats one contributing only its anchor. This
  -- ★      is 0349's `return_location_id is not null` + fleet_sortie_still_speaks — hoisted from a
  -- ★      WHERE clause into the ORDER BY, i.e. from an EXCLUSION into a PREFERENCE. That one move
  -- ★      is the fix: under 0349 a fleet with no recorded port was invisible, and a manifest fleet
  -- ★      created by an ambush NEVER has one, so the resolver fell through to nowhere;
  -- ★   3. the ship's OWN tagged fleet beats a manifest fleet — 0349 step (a) before step (b), for
  -- ★      the reason 0349 gives (a single expedition records its port on the ship's own fleet; a
  -- ★      team hunt records it on the SHARED fleet, never on the member's);
  -- ★   4. a live fleet beats a corpse (0349 [R1]/[R2]);
  -- ★   5. updated_at desc, id desc — TOTAL, because `select … into` takes the first row silently.
  select f.id, f.player_id, f.origin_base_id
    into v_src, v_player, v_anchor
    from fleets f
   where f.id in (select f2.id from fleets f2 where f2.main_ship_id = p_main_ship_id
                  union
                  select gsm.fleet_id from group_sortie_members gsm where gsm.main_ship_id = p_main_ship_id)
   order by (public.fleet_return_port(f.id) is not null) desc,
            (f.return_location_id is not null
             and public.fleet_sortie_still_speaks(f.status, f.updated_at)) desc,
            (f.main_ship_id is not distinct from p_main_ship_id) desc,
            public.fleet_is_live(f.status) desc,
            f.updated_at desc, f.id desc
   limit 1;

  -- ★ 0352 [R4]: THE PORT IS NOT DECIDED HERE. public.fleet_return_port owns the precedence —
  -- ★ recorded choice while the sortie speaks, else the fleet's own anchor — and this function
  -- ★ composes it. It reads no `bases` row and no locations row of its own for that purpose;
  -- ★ assert (c) pins that the word does not appear in this body.
  v_return := public.fleet_return_port(v_src);

  if v_return is null then
    -- ★ 0352 [R5]: NO WRITE. 0349's comment here read "a ship with only stale records is left where
    -- ★ it is, never sent to a stranger's port" — and the statement under it wrote status='home',
    -- ★ which is not leaving it where it is. Paired with no fleet, that is the exact
    -- ★ "Location unknown · Ships 0 of 5" the owner saw twice today: mainship_resolve_fleet returns
    -- ★ NULL for such a ship and nothing in the game can act on it. 0349's INTENT is kept and is
    -- ★ now what the code does. The "stranger's port" concern is answered structurally instead of
    -- ★ by refusal: the leaf's anchor branch requires bases.player_id = fleets.player_id, so the
    -- ★ port can only ever be one of this ship owner's own.
    -- ★ Reachable only for a ship that belongs to NO fleet of any kind — 0 in production, and not a
    -- ★ sortie by any definition. The NOTICE makes that visible instead of silent.
    raise notice 'nohome_dock_returning_ship: ship % has no fleet that resolves a return port — left untouched', p_main_ship_id;
    return;
  end if;

  -- The port's zone/sector, for the presence. Not a guard any more (the leaf already required an
  -- active location); if it somehow misses, make no write rather than a partial one.
  select l.id, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = v_return and l.status = 'active';
  if v_loc.id is null then
    raise notice 'nohome_dock_returning_ship: port % vanished between resolution and read — ship % left untouched', v_return, p_main_ship_id;
    return;
  end if;

  -- H1: give the ship its OWN main_ship_id-tagged present fleet at the return port. Reuse one already
  -- present there (idempotent), else the ship's most-recent LIVE tagged fleet, else mint a fresh one.
  select id into v_fleet from fleets
    where main_ship_id = p_main_ship_id and player_id = v_player
      and status = 'present' and current_location_id = v_loc.id
    limit 1;
  if v_fleet is null then
    -- 0349 [R3], carried through unchanged: this read had no status filter, so the "most-recent
    -- tagged fleet" it reused could be a DESTROYED one, resurrecting a fleet its owner had lost.
    -- Production carries FOUR main_ship_id-tagged fleets at status='destroyed'.
    select id into v_fleet from fleets
      where main_ship_id = p_main_ship_id and player_id = v_player
        and public.fleet_is_live(status)
      order by updated_at desc, id desc limit 1;
  end if;
  if v_fleet is null then
    -- ★ 0352 [R6]: origin_base_id. This was the ONE fleet-creating path in the whole schema that set
    -- ★ no anchor, so a returning ship's brand-new fleet could not itself answer where it comes home
    -- ★ to — the same hole, one level down. It inherits the anchor of the fleet it is returning
    -- ★ from, which is a value already resolved above rather than a second derivation.
    insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id,
                        current_location_id, current_zone_id, current_sector_id, main_ship_id)
      values (v_player, v_anchor, 'present', 'location', null, v_loc.id, v_loc.zone_id, v_loc.sector_id, p_main_ship_id)
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

-- ═══ SELF-ASSERTS — the whole file rolls back if any of these fails ══════════════════════════════

-- (a) THE LEAF ANSWERS, AND IT IS NOT A CONSTANT.
--     Non-vacuity in both directions, neither of which needs a single row:
--       * a fleet id that does not exist must answer NULL — so the function cannot be a constant
--         that returns some port for everything;
--       * a POSITIVE control on the probe itself (the count of fleets it answers for equals the
--         count of fleets) so an empty or broken query cannot satisfy the "zero unresolved" half.
do $a$
declare
  v_total integer; v_answered integer; v_null integer; v_probe uuid;
begin
  if to_regprocedure('public.fleet_return_port(uuid)') is null then
    raise exception '0352 ASSERT (a) FAIL: public.fleet_return_port(uuid) is not deployed';
  end if;
  -- NOT A CONSTANT. gen_random_uuid() cannot collide with a real fleet id in any meaningful sense.
  v_probe := public.fleet_return_port(gen_random_uuid());
  if v_probe is not null then
    raise exception '0352 ASSERT (a) FAIL: the leaf answered % for a fleet that does not exist — it is not reading the fleet at all, so every non-null answer below would be meaningless', v_probe;
  end if;
  select count(*) into v_total from public.fleets;
  select count(*) into v_answered from public.fleets where public.fleet_return_port(id) is not null;
  select count(*) into v_null     from public.fleets where public.fleet_return_port(id) is null;
  if v_answered + v_null <> v_total then
    raise exception '0352 ASSERT (a) FAIL: the probe accounts for % of % fleets — it is broken', v_answered + v_null, v_total;
  end if;
  if v_null <> 0 then
    raise exception '0352 ASSERT (a) FAIL: % of % fleet(s) cannot resolve a return port. Every one of them is a fleet that, if it ever ends a sortie, drops its ships into nowhere.', v_null, v_total;
  end if;
  raise notice '0352 (a): the leaf answers for all % fleet(s), and NULL for a fleet that does not exist', v_total;
end $a$;

-- (b) ⭐ A SORTIE CANNOT BE CREATED WITHOUT A RESOLVABLE RETURN — the assert that fails the deploy.
--     It does NOT read a row, so it is exactly as strong on an empty CI database as on production.
--     It takes the CHECK constraint's expression OUT OF THE CATALOG (never a copy typed here — a
--     copy would prove that this file's own string is correct, which is worth nothing) and
--     EVALUATES IT over the full 2x2x2 truth table of (group_id, main_ship_id, origin_base_id).
--     Exactly one of the eight combinations must be REFUSED, and it must be the sortie shape with no
--     anchor. Both halves are load-bearing: "at least one refused" kills a constant-true expression,
--     "exactly one, and it is that one" kills an expression that refuses the wrong thing.
do $b$
declare
  v_def text; v_expr text; v_g text; v_m text; v_o text; v_res boolean;
  v_false integer := 0; v_true integer := 0; v_checked integer := 0; v_sortie_refused boolean := false;
  v_u constant text := 'a0000000-0000-4000-8000-000000000001';
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conrelid = 'public.fleets'::regclass and conname = 'fleets_group_fleet_has_anchor';
  if v_def is null then
    raise exception '0352 ASSERT (b) FAIL: fleets_group_fleet_has_anchor is absent — a group fleet can still be minted with no anchor, which is a sortie with no resolvable return';
  end if;
  if left(v_def, 6) <> 'CHECK ' then
    raise exception '0352 ASSERT (b) FAIL: unexpected constraint definition shape: %', v_def;
  end if;
  v_expr := substring(v_def from 7);
  foreach v_g in array array[v_u, null] loop
    foreach v_m in array array[v_u, null] loop
      foreach v_o in array array[v_u, null] loop
        execute format(
          'select (%s) from (values (%L::uuid, %L::uuid, %L::uuid)) as t(group_id, main_ship_id, origin_base_id)',
          v_expr, v_g, v_m, v_o)
          into v_res;
        if v_res is null then
          raise exception '0352 ASSERT (b) FAIL: the deployed CHECK evaluates to NULL for (group=%, main_ship=%, anchor=%) — a NULL CHECK ADMITS the row, so the constraint would not refuse anything', v_g, v_m, v_o;
        end if;
        if v_res then v_true := v_true + 1; else v_false := v_false + 1; end if;
        -- THE SORTIE SHAPE: a group fleet (group_id set) that is not a per-ship fleet
        -- (main_ship_id NULL) with no anchor (origin_base_id NULL). This must be the refused one.
        if v_g is not null and v_m is null and v_o is null then
          v_sortie_refused := not v_res;
        end if;
        v_checked := v_checked + 1;
      end loop;
    end loop;
  end loop;
  if v_checked <> 8 then
    raise exception '0352 ASSERT (b) FAIL: the truth table evaluated % case(s), want 8 — the loop did not run and every conclusion below is vacuous', v_checked;
  end if;
  if v_false = 0 then
    raise exception '0352 ASSERT (b) FAIL: the deployed CHECK admits ALL EIGHT shapes — it refuses nothing, so a sortie with no anchor is still insertable';
  end if;
  if not v_sortie_refused then
    raise exception '0352 ASSERT (b) FAIL: the deployed CHECK ADMITS a group fleet with main_ship_id NULL and origin_base_id NULL. That is the shape command_ship_group_go mints and the shape the ambush freezes a manifest onto — i.e. a sortie can still be created without a resolvable return.';
  end if;
  if v_false <> 1 or v_true <> 7 then
    raise exception '0352 ASSERT (b) FAIL: the CHECK refuses % of 8 shapes (want exactly 1 — the sortie-with-no-anchor). Refusing more means it is rejecting fleet shapes this file did not intend to touch, including the per-ship commissioning fleet.', v_false;
  end if;
  -- and the second structural half: a base is a port.
  if not exists (select 1 from pg_attribute
                  where attrelid = 'public.bases'::regclass and attname = 'location_id' and attnotnull) then
    raise exception '0352 ASSERT (b) FAIL: bases.location_id is still nullable — a base that names no port breaks the leaf''s anchor branch';
  end if;
  -- POSITIVE CONTROL on that probe: a column that MUST still be nullable. Without this, an attnotnull
  -- read that always returned true would pass the line above and prove nothing.
  if exists (select 1 from pg_attribute
              where attrelid = 'public.fleets'::regclass and attname = 'return_location_id' and attnotnull) then
    raise exception '0352 ASSERT (b) FAIL: fleets.return_location_id became NOT NULL — the recorded choice is an OVERRIDE and must stay optional (and this file''s attnotnull probe is evidently reading the wrong thing)';
  end if;
end $b$;

-- (c) THE LEAF IS THE ONLY ANSWERER. Every zero-count is paired with a positive control on the same
--     body, and the counting expression is proved on a control string first — the 0349 (b) shape.
do $c$
declare
  v_ctl  text := 'select public.fleet_return_port(f.id) from bases b where f.return_location_id is null';
  v_code text; v_n integer; v_tok text;
begin
  foreach v_tok in array array['public.fleet_return_port(', 'bases', 'return_location_id'] loop
    v_n := (length(v_ctl) - length(replace(v_ctl, v_tok, ''))) / length(v_tok);
    if v_n < 1 then
      raise exception '0352 ASSERT (c) FAIL: the occurrence probe found 0 x % in a control string that demonstrably contains it — every zero-count below would be meaningless', v_tok;
    end if;
  end loop;

  -- THE RESOLVER composes the leaf and derives nothing itself.
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'nohome_dock_returning_ship';
  if v_code is null or length(v_code) < 500 then
    raise exception '0352 ASSERT (c) FAIL: nohome_dock_returning_ship is absent or implausibly short (% chars)', coalesce(length(v_code), -1);
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.fleet_return_port(', ''))) / length('public.fleet_return_port(');
  if v_n <> 2 then
    raise exception '0352 ASSERT (c) FAIL: nohome_dock_returning_ship composes the leaf % time(s) (want 2 — once to prefer a fleet that can answer, once to take the answer)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'bases', ''))) / length('bases');
  if v_n <> 0 then
    raise exception '0352 ASSERT (c) FAIL: nohome_dock_returning_ship reads `bases` % time(s) — the anchor lives in public.fleet_return_port and nowhere else', v_n;
  end if;
  -- POSITIVE CONTROL on the same body: 0349's TTL predicate and its H1 reuse fence are still there,
  -- so the two zero/exact counts above cannot be satisfied by a body that lost its logic.
  if position('public.fleet_sortie_still_speaks(' in v_code) = 0
     or position('public.fleet_is_live(' in v_code) = 0 then
    raise exception '0352 ASSERT (c) FAIL: nohome_dock_returning_ship lost 0349''s predicates — this is a stale-base re-emission, not an edit';
  end if;
  -- and the no-port arm no longer writes the location-less pair.
  if position('status = ''home''' in v_code) > 0 then
    raise exception '0352 ASSERT (c) FAIL: nohome_dock_returning_ship still writes status=''home'' directly. That write IS the "Location unknown" state; docking goes through mainship_mark_docked_at_location and the no-port arm must write nothing at all.';
  end if;
  if position('mainship_mark_docked_at_location' in v_code) = 0 then
    raise exception '0352 ASSERT (c) FAIL: the docked-pair helper is gone — the previous check would then pass vacuously';
  end if;

  -- NOBODY ELSE ANSWERS THE QUESTION. Exactly three function bodies may mention the column: the leaf
  -- (which decides), the hunt (which records the override) and the resolver (which clears it on dock).
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') like '%return_location_id%'
     and p.proname not in ('fleet_return_port', 'send_ship_group_hunt', 'nohome_dock_returning_ship');
  if v_n <> 0 then
    raise exception '0352 ASSERT (c) FAIL: % function(s) outside the declared three read or write fleets.return_location_id — the answer has grown a second owner', v_n;
  end if;
  -- positive control for that catalog probe: the three declared ones ARE found by it.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') like '%return_location_id%';
  if v_n <> 3 then
    raise exception '0352 ASSERT (c) FAIL: the catalog probe finds % function(s) mentioning return_location_id (want exactly the 3 declared) — the zero-count above is measuring nothing', v_n;
  end if;
end $c$;

-- (d) ONE RULE IN THE HUNT. Four deciders became one rule, spelled identically in the two arms that
--     survive, and nothing else in that body assigns v_return.
do $d$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_ship_group_hunt';
  if v_code is null or length(v_code) < 10000 then
    raise exception '0352 ASSERT (d) FAIL: send_ship_group_hunt is absent or implausibly short (% chars)', coalesce(length(v_code), -1);
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'v_return :=', ''))) / length('v_return :=');
  if v_n <> 2 then
    raise exception '0352 ASSERT (d) FAIL: send_ship_group_hunt assigns v_return % time(s) (want exactly 2 — one per surviving arm; the head had 4)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'v_return := coalesce(p_return_location_id, v_o_loc);', '')))
         / length('v_return := coalesce(p_return_location_id, v_o_loc);');
  if v_n <> 2 then
    raise exception '0352 ASSERT (d) FAIL: % of the 2 assignments are the ONE rule — an arm is deciding the return port for itself again', v_n;
  end if;
  -- the three head expressions are gone, named individually so a partial landing cannot pass.
  if position('coalesce(p_return_location_id, v_gf.current_location_id)' in v_code) > 0
     or position('coalesce(p_return_location_id, v_dock_loc)' in v_code) > 0
     or position('v_return   :=' in v_code) > 0 then
    raise exception '0352 ASSERT (d) FAIL: one of the head''s own return-port expressions survives in send_ship_group_hunt';
  end if;
  -- POSITIVE CONTROL: the body still records the value it computes, on all the mints that did.
  v_n := (length(v_code) - length(replace(v_code, 'group_id, return_location_id)', ''))) / length('group_id, return_location_id)');
  if v_n <> 2 then
    raise exception '0352 ASSERT (d) FAIL: % of the head''s 2 return-port-recording inserts survive — the rewrite removed a write it was not meant to touch', v_n;
  end if;
  -- and the anchor guard that keeps every one of its three mints CHECK-legal is untouched.
  if position('''no_home_base''' in v_code) = 0 then
    raise exception '0352 ASSERT (d) FAIL: send_ship_group_hunt lost its no_home_base guard — its mints could then violate fleets_group_fleet_has_anchor';
  end if;
end $d$;

-- (e) THE TWO MINTERS REFUSE RATHER THAN VIOLATE. Text probes with positive controls, because the
--     behavioural version needs a real player and cannot run on a fresh CI database — that half
--     lives in scripts/team-command-proof.sql (BLOCK NOHOME, the ANCHOR pins), which has fixtures.
do $e$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if v_code is null or length(v_code) < 10000 then
    raise exception '0352 ASSERT (e) FAIL: command_ship_group_go is absent or implausibly short (% chars)', coalesce(length(v_code), -1);
  end if;
  v_n := (length(v_code) - length(replace(v_code, '''no_origin''', ''))) / length('''no_origin''');
  if v_n <> 3 then
    raise exception '0352 ASSERT (e) FAIL: command_ship_group_go returns no_origin % time(s) (want 3 — the head''s TWO origin arms, measured on production, plus this file''s mint guard)', v_n;
  end if;
  if position('if v_base.id is null then
      return jsonb_build_object(''ok'', false, ''reason'', ''no_origin'');
    end if;
    insert into public.fleets (player_id, origin_base_id' in v_code) = 0 then
    raise exception '0352 ASSERT (e) FAIL: the mint guard is not immediately before the fleet insert in command_ship_group_go — a guard that is not adjacent to the write it protects is not a guard';
  end if;

  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'assign_ship_to_group';
  if v_code is null or length(v_code) < 5000 then
    raise exception '0352 ASSERT (e) FAIL: assign_ship_to_group is absent or implausibly short (% chars)', coalesce(length(v_code), -1);
  end if;
  if position('if v_base is not null then
      insert into public.fleets' in v_code) = 0 then
    raise exception '0352 ASSERT (e) FAIL: assign_ship_to_group can still mint a group fleet with no anchor';
  end if;
  -- POSITIVE CONTROL: the mint it guards is still there (a body that had lost the insert entirely
  -- would satisfy nothing above, but would satisfy a naive "no unguarded insert" phrasing).
  if position('presence_create(v_player, v_mint' in v_code) = 0 then
    raise exception '0352 ASSERT (e) FAIL: assign_ship_to_group lost its heal-mint presence — the guard above is guarding nothing';
  end if;
end $e$;

-- (f) THE FALLBACK AGREES WITH THE PHYSICS. The port the anchor branch names is the point the return
--     leg flies to — proved as an invariant over the data (vacuous on an empty database, and said so)
--     AND as a fact about the code (never vacuous).
do $f$
declare v_n integer; v_fn text; v_src text;
begin
  select count(*) into v_n
    from public.bases b join public.locations l on l.id = b.location_id
   where b.x is distinct from l.x or b.y is distinct from l.y;
  if v_n <> 0 then
    raise exception '0352 ASSERT (f) FAIL: % base(s) sit at a coordinate that is not their own port''s. The return leg flies to bases.x/y and this file docks the ships at bases.location_id; if those disagree the ships teleport away from their own fleet.', v_n;
  end if;
  -- THE CODE HALF: all three return_home leg minters read the anchor, and none of them was
  -- re-created by this file.
  foreach v_fn in array array['process_combat_ticks', 'presence_request_leave', 'combat_flee_pending'] loop
    select coalesce(string_agg(p.prosrc, chr(10)), '') into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_src = '' then
      raise exception '0352 ASSERT (f) FAIL: public.% is absent', v_fn;
    end if;
    if position('origin_base_id' in v_src) = 0 then
      raise exception '0352 ASSERT (f) FAIL: public.% no longer reads origin_base_id — the anchor this file falls back to is no longer where the fleet flies', v_fn;
    end if;
    if position('fleet_return_port' in v_src) > 0 then
      raise exception '0352 ASSERT (f) FAIL: public.% composes the leaf — it was re-created by this slice and the declared blast radius is four functions', v_fn;
    end if;
  end loop;
end $f$;

-- (g) BLAST RADIUS AND METADATA PARITY. Exactly four bodies changed, each changed BODY and nothing
--     else, and the functions this slice deliberately leaves alone are untouched.
do $g$
declare b record; a record; v_n integer := 0; v_fn text; v_src text; v_over integer;
begin
  for b in select * from _0352_before loop
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
      raise exception '0352 ASSERT (g) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0352 ASSERT (g) FAIL: public.% body is byte-identical — its hunks did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 4 then
    raise exception '0352 ASSERT (g) FAIL: parity-checked % function(s), expected 4', v_n;
  end if;
  -- THE AMBUSH IS UNTOUCHED, AND THAT IS THE DESIGN. The function that caused the incident needs no
  -- line of its own: the fleet it freezes a manifest onto can already answer.
  foreach v_fn in array array['pirate_intercept_resolve_due_for_movement', 'movement_settle_arrival',
                              'fleet_complete', 'fleet_set_in_space', 'process_mainship_expeditions',
                              'group_sortie_release', 'mainship_resolve_fleet', 'fleet_create',
                              'port_entry_commission_build', 'get_or_create_store',
                              'initialize_new_player'] loop
    select count(*), coalesce(string_agg(p.prosrc, chr(10)), '') into v_over, v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_over = 0 then
      raise exception '0352 ASSERT (g) FAIL: public.% is absent — this slice must not have removed it', v_fn;
    end if;
    if position('fleet_return_port' in v_src) > 0 then
      raise exception '0352 ASSERT (g) FAIL: public.% composes the leaf — it was re-created by this slice and the declared blast radius is four functions', v_fn;
    end if;
  end loop;
  -- the manifest's two writers still write it: this file must not have given the roster a beginning
  -- it no longer has (0349 assert (g), carried forward).
  select coalesce(string_agg(p.prosrc, chr(10)), '') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('send_ship_group_hunt', 'pirate_intercept_resolve_due_for_movement');
  if position('insert into group_sortie_members' in v_src) = 0
     or position('insert into public.group_sortie_members' in v_src) = 0 then
    raise exception '0352 ASSERT (g) FAIL: a manifest writer stopped writing the manifest';
  end if;
end $g$;

-- (h) NO NEW NUMBER, NO NEW FLAG, NO ROW OF PLAYER DATA TOUCHED.
do $h$
declare v_before record; v_n integer; v_md5 text;
begin
  select * into v_before from _0352_cfg_before;
  select count(*), md5(coalesce(string_agg(key, ',' order by key), '')) into v_n, v_md5 from public.game_config;
  if v_n <> v_before.n or v_md5 is distinct from v_before.keys_md5 then
    raise exception '0352 ASSERT (h) FAIL: game_config changed across this file (% keys -> %). This slice introduces no knob and no flag; the one threshold it depends on is 0349''s sortie_manifest_ttl_seconds, composed through 0349''s own predicate.', v_before.n, v_n;
  end if;
  -- and that threshold is still there and still the leaf's, reached through the predicate rather
  -- than re-read here.
  if not exists (select 1 from public.game_config where key = 'sortie_manifest_ttl_seconds') then
    raise exception '0352 ASSERT (h) FAIL: sortie_manifest_ttl_seconds is absent — 0349''s knob is what fences the recorded choice inside the leaf';
  end if;
  if position('public.fleet_sortie_still_speaks(' in (
       select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'fleet_return_port')) = 0 then
    raise exception '0352 ASSERT (h) FAIL: the leaf does not compose 0349''s TTL predicate — it would then trust a seventeen-day-old chosen port';
  end if;
  raise notice '0352 SELF-ASSERT PASS: the return destination is decided ONCE, by public.fleet_return_port — the sortie''s own recorded choice while that sortie still speaks, else the fleet''s anchor, which is the port every return_home leg in the schema already flies to and the coordinate bases.x/y already carries. send_ship_group_hunt''s FOUR deciders are ONE rule; command_ship_group_go and assign_ship_to_group refuse rather than mint an anchorless sortie, and fleets_group_fleet_has_anchor makes that refusal structural; the ambush that caused the incident needed no line at all, because the fleet it freezes a manifest onto could always answer — nothing was asking. nohome_dock_returning_ship asks ONE question once, composes the leaf, mints its tagged fleet WITH an anchor, and its no-port arm now writes nothing instead of stranding a ship at a home that has no port.';
end $h$;

commit;
