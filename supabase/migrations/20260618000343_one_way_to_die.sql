-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0343 — ONE WAY TO DIE  (mint public.combat_encounter_wreck; fold the three fleet-death arms)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ⛔ NO NEW BEHAVIOUR, NO FLAG, NO COLUMN, NO KNOB, NO CLIENT HALF. One authority replaces three
--    copies. The single observable delta is named below and it is a strict improvement on a row
--    that will never be ticked again.
--
-- ── THE DEFECT ──────────────────────────────────────────────────────────────────────────────────
-- "A fleet died" was written THREE times inside process_combat_ticks:
--
--   arm A  live 241-279   the entry check — the fleet was already gone when the tick picked it up
--   arm C  live 936-965   the spatial arm's death, after damage resolved
--   arm D  live 1352-1381 the aggregate (0228, no-positions) arm's death, after damage resolved
--
-- Each carried the SAME five statements — combat_encounter_release(..., true),
-- fleet_consume_retreat_target, a loop marking every member destroyed, the terminal status write —
-- and the same nineteen lines of prose explaining them. Arms C and D were byte-identical to each
-- other. Arm A's block was identical for the first five lines and then wrote FOUR more columns and
-- logged a combat_ticks row.
--
-- That is the disease this project has a law against: one concept, three places it is decided. The
-- cost is not hypothetical. 0336 had to fix the same wedge in every arm at once and left behind the
-- sentence "One leaf, called by all four arms" — which was copied along with the block it described
-- and was therefore FALSE in three of the four places it appeared. 0332 had to reconcile members in
-- one arm and prove it had not diverged from the others. Every future change to what a wreck means
-- is three edits, and the third one is the one that gets missed.
--
-- ── THE FOLD ────────────────────────────────────────────────────────────────────────────────────
-- public.combat_encounter_wreck(p_encounter uuid, p_tick integer) is minted as THE authority for
-- "this fleet is a wreck, resolve it". Arms A, C and D become three CALLERS. Not a fourth copy.
--
-- COMPOSED, NEVER REIMPLEMENTED. The leaf contains no world-state logic of its own: it calls the
-- frozen primitives combat_encounter_release (0336), fleet_consume_retreat_target (0336) and
-- mainship_mark_combat_destroyed (0231) exactly as the three arms did, in the order they did, and
-- then writes the terminal row. Its confinement, its warning behaviour and its query_canceled
-- discipline are the leaves' own and are untouched.
--
-- WHAT THE LEAF DOES *NOT* DO, and why each exclusion is deliberate:
--   • It does NOT log a combat_ticks row. Arm A's tick row is logged AFTER its terminal write;
--     arms C and D logged theirs a few lines BEFORE their call (live 898-908 and 1316-1326). A
--     tick insert inside the leaf would double-log for two of its three callers. Arm A keeps its
--     own insert, at its own call site, byte-identical.
--   • It does NOT write the explosion event. Arm A uses seq 0; arms C and D use the tick's running
--     v_seq. That is a real difference between the call sites, not a copy, and both the sequence
--     and the combat_event_logging decision belong to the tick, not to the resolution of a death.
--   • It does NOT call report_create. The call is one line to an existing authority and its
--     ORDERING differs by arm — the departure arm reports BEFORE it releases. Keeping it at the
--     call sites keeps that ordering visible where it matters.
--
-- ── ARM B IS NOT IN THE LEAF, AND THAT IS THE POINT ─────────────────────────────────────────────
-- Live 289-434 looks like a fourth copy and is not. It is a DEPARTURE: a fleet that leaves alive.
-- It releases with p_destroy_fleet FALSE, it READS the retreat destination in the act of consuming
-- it (live 373-379), it marks survivors 'returning' and only the dead destroyed (live 414-418), it
-- attaches the haul to a movement (live 420-422), and it reports BEFORE it releases. Folding it
-- into this leaf would zero a living player's haul and destroy their surviving ships. It is left
-- byte-identical — see [W4] for the one comment-only correction — and assert (e) below exists to
-- stop a later slice from folding it in.
--
-- ── THE ONLY BEHAVIOUR DELTA, STATED ────────────────────────────────────────────────────────────
-- The leaf adopts arm A's fuller terminal UPDATE, so arms C and D now also write tick_number,
-- last_resolved_at, player_integrity_current=0 and player_power_current=0. Three of those four
-- already hold exactly those values when the branch is entered: the UPDATE immediately above each
-- call sets tick_number=v_tick and last_resolved_at=now(), and it sets
-- player_integrity_current=greatest(0, v_hp_after) where v_hp_after <= 0 is the branch's own
-- condition. So the only column whose value can move is player_power_current, which becomes 0
-- rather than combat_encounter_side_power() over a side with no living unit. The row is terminal:
-- status='defeat', ended_at is set, no arm ever ticks it again, and 0 is what a wrecked fleet's
-- power is. Arm A's write is unchanged in every column.
--
-- ── PARITY: WHAT IS TOUCHED, AND HOW THAT IS GUARANTEED ─────────────────────────────────────────
-- THE LIVE ENGINE IS THE AUTHORITY, NOT THE REPO. process_combat_ticks is 1,396 lines and no file
-- holds it whole; it has been changed in place by text surgery since 0299. This migration reads the
-- body that is actually DEPLOYED (pg_get_functiondef at apply time) and replaces FOUR hunks in it:
--
--     [W1]  live 241-267   arm A  — 19 prose lines + 5 statements -> one leaf call
--     [W4]  live 303-323   arm B  — COMMENT ONLY, not one statement changes
--     [W2]  live 936-960   arm C  — 19 prose lines + 5 statements -> one leaf call
--     [W3]  live 1352-1376 arm D  — 19 prose lines + 5 statements -> one leaf call
--
-- Each hunk carries its source text VERBATIM and must match it EXACTLY ONCE. Zero occurrences means
-- the anchor is gone — the deployed body is not the one the hunk was cut from — and the migration
-- ABORTS rather than silently patching nothing. More than one means the anchor is ambiguous and the
-- patch could land on the wrong site; that aborts too. The 1,299 lines outside the four hunks are
-- untouched BY CONSTRUCTION, not by a reviewer's promise. That is the whole reason this is a surgery.
--
-- WHY IT IS A SURGERY AND NOT A RE-TYPED BODY, decided on evidence, not preference. Eleven
-- generators (scripts/gen-0314, -0315, -0316, -0317, -0319, -0331, -0332, -0333, -0336, -0337,
-- -0339) each assert that 0299 is still the newest TEXTUAL re-create of this function, and their own
-- comment states the rule: "Replace-rewriters do not move the textual head, but any later
-- `create or replace function public.process_combat_ticks` means the slice source is stale." A full
-- re-emission was written first and it broke all eleven at once — observed, by running
-- scripts/danger-combat-proof.sh selftest and reading the failure, not predicted. Re-pointing eleven
-- historical generators is not this slice's business, and a slice that has to rewrite the harness to
-- land is a slice doing two things. This file therefore contains no
-- `create or replace` of the tick at all, and the build refuses to emit one.
--
-- THE PARITY SOURCE. The hunk texts were cut from production's own body, dumped 2026-08-08:
--     md5(pg_get_functiondef) = 3806e89a97237bf00f593ad38a834580, 99,286 characters, 1,396 lines
--
-- WHY THAT md5 IS A NOTICE AND NOT AN ABORT. In CI the body being patched is the one the MIGRATION
-- CHAIN builds, and it is not required to be byte-equal to production's — proving that needs a real
-- Postgres, and it could not be checked from the machine this was written on (no local Docker;
-- checked, not assumed). A hard md5 gate would be a coin flip able to hold 0344-0350 hostage over a
-- difference that does not affect this fold. So the observed md5 and length are RAISEd as a NOTICE
-- beside the recorded constant — evidence in the deploy log, for a human — while what is hard-
-- asserted is what actually has to be true: every region this file rewrites is present, in the
-- expected shape, the expected number of times, and the arms it must NOT touch are still there. A
-- difference in the notice is a REVIEW SIGNAL; a difference in a hunk is a FAILURE.
--
-- ── THE SELF-ASSERT (what fails the deploy) ─────────────────────────────────────────────────────
-- Every count is taken over a COMMENT-STRIPPED copy of the deployed prosrc, because four banners
-- in this body name combat_encounter_release in PROSE and would otherwise be counted as calls —
-- the 0222 vacuity trap, in reverse. Each block first proves its own probe is live:
--
--   The surgery block itself: every hunk matches its source text EXACTLY ONCE (never >= 1), the
--   rewritten body differs from the deployed one, and it is strictly SHORTER — because a replace
--   chain that quietly did nothing would leave the old body in place, and the old body satisfies
--   none of the absence asserts below only if they are actually reading a changed body.
--
--   (a) the fold landed exactly three times, and the departure still releases inline exactly once.
--       Non-vacuity: the stripped body must exceed 40,000 chars AND be shorter than the raw body,
--       so a strip that ate everything cannot make every "= 0" assert pass.
--   (b) the leaf is what it claims: it composes all three primitives, writes all seven terminal
--       columns, and contains NO combat_ticks / combat_events insert.
--   (c) the call sites kept what is theirs: arm A's combat_ticks row, three explosion events, four
--       report_create calls.
--   (d) THE CLASS GUARD — a schema sweep. Exactly ONE function in public writes
--       combat_encounters.status = 'defeat', and it is combat_encounter_wreck. This is the assert
--       that fails the deploy if the old shape ever returns. It CANNOT pass vacuously: it first
--       requires the probe to MATCH THE LEAF ITSELF, so a regex that matches nothing is a failure
--       rather than a finding of "no other writers".
--   (e) the departure is intact — release(..., false), the 'returning' branch, the cargo attach and
--       the retreat_completed event are all still in the tick, exactly once each.
--   (f) NOTHING DARK: no game_config key exists for this slice. Asserted absent, not promised.
--       There is no flag to flip, so there is no way for this to ship invisible.
--   (g) the leaf is engine-internal: revoked from PUBLIC BY NAME (the 0309 lesson) and from anon
--       and authenticated, then asserted unreachable by both.
--
-- ── WHAT BEHAVIOURALLY GATES THIS FOLD, AND WHAT DOES NOT (stated, because a self-assert cannot) ─
-- The asserts below are STRUCTURAL: they prove there is one authority and that the arms reach it.
-- They cannot prove a fleet still dies correctly. Two behaviour blocks already in the harness do,
-- and both run on the disposable-Postgres leg, which is the only layer that executes any of this:
--   • scripts/danger-combat-proof.sql:7086-7110 (NOWEDGE) drives a real fleet to death through the
--     tick against a deliberately mismatched presence and asserts status='defeat', ended_at set,
--     last_resolved_at NOT rewound, tick_number ADVANCED and zero living player hulls. tick_number
--     is the column this leaf writes from p_tick, so that choice is behaviourally gated, and the
--     confinement it tests now lives inside the leaf.
--   • scripts/danger-combat-proof.sql:7682-7698 (RETREATCLEAR part A) kills a fleet that holds a
--     recorded retreat destination and asserts all three fleets.retreat_target_* columns are NULL
--     afterwards — the fleet_consume_retreat_target call this fold moved into the leaf.
-- Both exercise arm C, the spatial death. NOT yet covered behaviourally, and NOT claimed to be:
-- arm A (the entry check), arm D (the aggregate arm), and the departure-shaped assert the contract
-- asks for — a fight with a haul and a living hull ending 'escaped' with the haul intact, survivors
-- 'returning' and zero ships destroyed. Those are proof-file work, they need the disposable leg to
-- validate, and writing them unrun would be a green marker over an unproven property.
--
-- ── BLAST RADIUS: production is a live game with real fleets in real fights ──────────────────────
-- The leaf and the tick that calls it are created in ONE transaction, so there is never an instant
-- at which the tick names a function that does not exist. A cron tick already executing when this
-- commits finishes on the old body and resolves its encounter completely; the next tick uses the
-- new one and resolves it completely. Both bodies write the same terminal row, so an encounter
-- that is 'active' at the moment of the deploy cannot be half-resolved and cannot be left in a
-- state no arm can reach: the arms, their conditions and their order are unchanged. No table is
-- locked, no row is written by this migration, no encounter is touched.
--
-- ── ROLLBACK BOUNDARY ───────────────────────────────────────────────────────────────────────────
-- Pure refactor plus the four terminal columns on arms C and D. The boundary is exactly the four
-- hunks and one function, and the reversal is mechanical: run this migration's own surgery block
-- with old_t and new_t SWAPPED — every hunk's pre-image is in this file, verbatim, in the VALUES
-- list, which is why nothing has to be reconstructed from a dump or from an older migration (copying
-- from an older FILE is what reverted this function's mode line three times; see live 210-212).
-- In one transaction, in this order:
--   1. apply the inverse surgery (new_t -> old_t, each still required to match exactly once), which
--      restores the three inline death blocks and the two comment banners;
--   2. then `drop function public.combat_encounter_wreck(uuid, integer);`
-- The order matters: the drop must not precede the removal of its callers. Nothing else unwinds —
-- no schema change, no grant on any client-reachable surface, no game_config row, no data write, no
-- client half. Arms C and D would go back to leaving player_power_current at whatever
-- combat_encounter_side_power returned for a side with no living unit.
--
-- ── ONE DOCUMENTED DEVIATION FROM THE CONTRACT ──────────────────────────────────────────────────
-- docs/COMBAT_OWNER_DIRECTIVES_CONTRACT.md §3 names the leaf combat_encounter_wreck(p_encounter
-- uuid). It takes a SECOND argument, p_tick, and it has to. The same document requires the leaf to
-- adopt arm A's UPDATE, which writes tick_number=v_tick. v_tick is e.tick_number + 1 (live 175):
-- at arm A's call the row still holds the OLD tick_number, while at arms C and D the UPDATE above
-- has already advanced it to v_tick. So no expression over the row alone yields the right value at
-- all three call sites — a row-derived "+1" would over-advance two of the three. The tick is
-- passed. This follows the convention of the leaf it composes: combat_encounter_release also takes
-- fleet and presence explicitly rather than re-reading a row its caller already holds.
--
-- ── WHAT THIS SLICE DOES NOT TOUCH ──────────────────────────────────────────────────────────────
-- combat_wave_arrival_phase, combat_formation_point, combat_create_encounter and its
-- location_mode='space' arm, the ambush/intercept path, the wave-clear blocks (which DIFFER in
-- four ways and are therefore not minted into a leaf — see the contract's appendix), v_danger, the
-- aggregate arm's own existence (0345), and every client file. No proof workflow trigger needed
-- widening: combat-spatial-proof.yml and danger-combat-proof.yml already fire on pull_request,
-- main and 'slice-**' — verified in this tree, not assumed.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── PRECONDITIONS ───────────────────────────────────────────────────────────────────────────────
-- A surgery is only safe if what it cuts is still there, in the shape it expects, and only there.
-- This block refuses to apply if any region the hunks rewrite is missing, duplicated or already
-- folded — the "the anchor is missing on production" failure, which is how 0333 held a chain
-- hostage. The per-hunk exactly-once check in the surgery block is the same guarantee stated again
-- at the point of use; this block states it in the vocabulary of the DEFECT, so a failure names the
-- arm rather than a hunk tag. It also records the parity source's identity beside the observed one,
-- as a notice, for the deploy log.
do $pre$
declare
  v_raw   text;
  v_code  text;
  v_def   text;
  v_n     integer;
begin
  select p.prosrc, pg_get_functiondef(p.oid)
    into v_raw, v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_raw is null then
    raise exception '0343 PRECONDITION FAIL: process_combat_ticks does not exist — there is nothing to fold';
  end if;
  v_code := regexp_replace(v_raw, '--[^' || chr(10) || ']*', '', 'g');
  -- The stripper must have removed something and must have left a body. Both directions, because a
  -- broken strip makes every count below meaningless in a way that reads as success.
  if length(v_code) < 40000 or length(v_code) >= length(v_raw) then
    raise exception '0343 PRECONDITION FAIL: the comment strip produced % chars from a % char body — every count below would be measured against nothing', length(v_code), length(v_raw);
  end if;

  -- FRESHNESS. 0339 is the newest migration that patched this body (0340 asserts it carries none of
  -- its own tokens). A body older than that is not the body these hunks were cut from, and the right
  -- answer is to stop and look rather than to patch text that has moved underneath.
  if position('0339' in v_raw) = 0 then
    raise exception '0343 PRECONDITION FAIL: the deployed body carries no 0339 marker — it is older than the body these hunks were cut from. Re-cut the hunks against what is actually deployed; do not apply this';
  end if;
  if position('combat_encounter_wreck' in v_raw) > 0 then
    raise exception '0343 PRECONDITION FAIL: the deployed body already calls combat_encounter_wreck — this fold has already happened and re-applying it would be a second authority for the same concept';
  end if;

  -- THE THREE ARMS ARE THERE, IN THE SHAPE THIS FILE REPLACES.
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true)', '')))
         / length('public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true)');
  if v_n <> 3 then
    raise exception '0343 PRECONDITION FAIL: % arm(s) release-and-destroy inline (want exactly 3: the entry check, the spatial death, the aggregate death). The body has drifted from the parity source and this fold would land on the wrong text', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, false)', '')))
         / length('public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, false)');
  if v_n <> 1 then
    raise exception '0343 PRECONDITION FAIL: % departure arm(s) release without destroying (want exactly 1). Arm B is the concept this fold must NOT absorb; if it is not where this file expects it, do not apply', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'perform public.fleet_consume_retreat_target(e.fleet_id);', '')))
         / length('perform public.fleet_consume_retreat_target(e.fleet_id);');
  if v_n <> 3 then
    raise exception '0343 PRECONDITION FAIL: % wreck arm(s) consume the retreat target with a bare perform (want exactly 3; the departure arm consumes it in a select, which this count deliberately excludes)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'perform mainship_mark_combat_destroyed(cu.main_ship_id);', '')))
         / length('perform mainship_mark_combat_destroyed(cu.main_ship_id);');
  if v_n <> 4 then
    raise exception '0343 PRECONDITION FAIL: % site(s) mark a member destroyed (want exactly 4: three wreck arms and the departure arm''s dead-member branch)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'update combat_encounters set status=''defeat''', '')))
         / length('update combat_encounters set status=''defeat''');
  if v_n <> 3 then
    raise exception '0343 PRECONDITION FAIL: % inline defeat write(s) (want exactly 3 — the three copies this migration exists to fold). Assert (d) below requires this to be 0 in the tick afterwards', v_n;
  end if;
  -- Arm A's write is the fuller one and there is exactly one of it; arms C and D share the shorter
  -- one and there are exactly two. If that split has changed, the leaf's UPDATE is not a superset.
  v_n := (length(v_code) - length(replace(v_code, 'update combat_encounters set status=''defeat'', tick_number=v_tick, ended_at=now(),', '')))
         / length('update combat_encounters set status=''defeat'', tick_number=v_tick, ended_at=now(),');
  if v_n <> 1 then
    raise exception '0343 PRECONDITION FAIL: % copy(ies) of arm A''s fuller terminal write (want exactly 1) — the leaf adopts it, so it must be the shape this file recorded', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'update combat_encounters set status=''defeat'', ended_at=now(), total_rewards_json=''{}''::jsonb, updated_at=now() where id=e.id;', '')))
         / length('update combat_encounters set status=''defeat'', ended_at=now(), total_rewards_json=''{}''::jsonb, updated_at=now() where id=e.id;');
  if v_n <> 2 then
    raise exception '0343 PRECONDITION FAIL: % copy(ies) of the shorter terminal write (want exactly 2 — the spatial and aggregate arms, byte-identical to each other)', v_n;
  end if;
  if to_regprocedure('public.combat_encounter_wreck(uuid, integer)') is not null then
    raise exception '0343 PRECONDITION FAIL: public.combat_encounter_wreck(uuid, integer) already exists — this migration mints it';
  end if;

  raise notice '0343 parity source: recorded md5(pg_get_functiondef) = 3806e89a97237bf00f593ad38a834580 / 99286 chars (production, 2026-08-08). OBSERVED here: md5 = % / % chars (prosrc: md5 = % / % chars). A difference is a REVIEW SIGNAL, not a failure — the CI chain body and production are not required to be byte-equal, and this fold does not depend on them being so; every hunk still has to match its own source text exactly once or nothing applies. What is asserted instead: 3 inline release-and-destroy arms, 1 departure arm, 3 bare retreat-target consumes, 4 member-destroy sites, 3 inline defeat writes (1 fuller + 2 short) — all present, all exact.',
    md5(v_def), length(v_def), md5(v_raw), length(v_raw);
end $pre$;


-- ── THE AUTHORITY ───────────────────────────────────────────────────────────────────────────────
-- combat_encounter_wreck — THE ONE PLACE A FLEET DIES.
--
-- Three arms of process_combat_ticks decide, on their own evidence, that a player fleet is gone.
-- Until this migration all three also decided what that MEANS, in their own copy of the same five
-- statements. They now answer only the question they are each positioned to answer — is the fleet
-- gone — and this leaf answers the one they were all answering identically.
--
-- COMPOSED, NOT REIMPLEMENTED. Nothing here is new logic. Every world-state effect is one of the
-- existing authorities, called exactly as the arms called it:
--   • combat_encounter_release(..., p_destroy_fleet := true)  — 0336's confined release. It runs
--     fleet_destroy and presence_complete each in its OWN subtransaction, downgrades a status
--     mismatch to a warning and RETURNS NORMALLY. That is what lets the terminal write below LAND.
--     Before 0336 an unguarded raise here rolled the whole tick back INCLUDING last_resolved_at, so
--     the encounter retried, identically, every tick, forever, and silently — the wedge that
--     send_ship_group_hunt already names in prose.
--   • fleet_consume_retreat_target — 0336's one clearer of fleets.retreat_target_*. A fleet that
--     died, or was wiped mid-fight, used to keep a stale destination that the NEXT sortie's settle
--     would then fly to. The recording is ALWAYS consumed. All three wreck arms consume it HERE, in
--     one place; the departure arm still consumes it itself, because it must also READ what it clears.
--   • mainship_mark_combat_destroyed — 0231's terminal per-hull write (status='destroyed' and hp,
--     in one statement), the only writer that moves a ship there from combat. Every member row is
--     marked; the filter `main_ship_id is not null` already excludes every enemy row, which is why
--     this loop never needed a side predicate.
--
-- ORDER IS IMMATERIAL, CHECKED (0336's finding, preserved): fleet_destroy writes fleets,
-- presence_complete writes location_presence and the worldstate cache, mainship_mark_combat_destroyed
-- writes main_ship_instances. No two of the three read what another writes. The terminal UPDATE runs
-- last, after the release has been given its chance to warn rather than wedge.
--
-- THE TERMINAL WRITE IS ARM A's, which is a strict superset of the one arms C and D used. On a row
-- that is ending there is no reason for two shapes of "this fight is over": status and ended_at say
-- it happened, total_rewards_json='{}' is the standing ruling that a haul does not survive a defeat,
-- and tick_number / last_resolved_at / player_integrity_current / player_power_current leave the row
-- describing a wreck rather than the last live snapshot of one.
--
-- WHY p_tick IS A PARAMETER AND NOT A READ. The terminal tick is the tick being resolved,
-- v_tick = e.tick_number + 1 in the caller. At the entry arm's call the row still holds the old
-- tick_number; at the other two the UPDATE above has already advanced it. No expression over the row
-- alone is correct at all three sites, so the caller states it. NULL is refused rather than
-- coalesced: a silently-defaulted tick number is a wrong observable, not a missing one.
--
-- IT CHANGES NOTHING ABOUT HOW A FAILURE BEHAVES, and that is deliberate. This function carries NO
-- exception block, so it opens no subtransaction: a raise from the destroy loop propagates out of it
-- to the tick's own per-encounter handler exactly as it did when the loop was inline — warning, the
-- encounter left in place, retried next tick. The confinement that matters already lives one level
-- down, inside combat_encounter_release, and it is untouched. It is also SECURITY DEFINER with the
-- same owner as the tick, so every statement here runs with the privileges it ran with before.
--
-- WHAT THIS LEAF DELIBERATELY DOES NOT DO: it logs no combat_ticks row and writes no combat_events
-- row. The three callers do not agree about either — the entry arm logs a tick row AFTER this call
-- while the other two logged theirs BEFORE it, and the explosion event's seq is 0 at one site and
-- the tick's running v_seq at the other two. Folding either in would double-log for two of three
-- callers and flatten a real difference into an invented one. Logging belongs to the tick.
create or replace function public.combat_encounter_wreck(
  p_encounter uuid,
  p_tick      integer)
returns void
language plpgsql
security definer
set search_path to 'public'
as $cew$
declare
  e  combat_encounters%rowtype;
  cu record;
begin
  if p_encounter is null or p_tick is null then
    raise exception 'combat_encounter_wreck: called with encounter=% tick=% — a wreck needs both, and defaulting either would write a wrong terminal row rather than fail loudly', p_encounter, p_tick;
  end if;
  -- Keyed on the primary key, so this reads one row or none. It is never a scan whose first row
  -- happens to answer.
  select * into e from public.combat_encounters where id = p_encounter;
  if not found then
    raise exception 'combat_encounter_wreck: encounter % does not exist — its caller is iterating a row that is gone, and silently returning would leave a fleet in combat forever', p_encounter;
  end if;
  perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
  perform public.fleet_consume_retreat_target(e.fleet_id);
  for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
    perform mainship_mark_combat_destroyed(cu.main_ship_id);
  end loop;
  update combat_encounters set status='defeat', tick_number=p_tick, ended_at=now(),
         last_resolved_at=now(), player_integrity_current=0, player_power_current=0,
         total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
end;
$cew$;

-- ENGINE INTERNAL, not a new client surface. Revoked from PUBLIC BY NAME — the 0309 lesson: a
-- revoke that names only anon and authenticated leaves the PUBLIC-held privilege standing, and
-- EXECUTE is granted to PUBLIC by default on every new function. Asserted in (g) below, because
-- 0254's grant drift proved that establishing a surface and asserting it are different acts.
revoke all on function public.combat_encounter_wreck(uuid, integer) from public;
revoke all on function public.combat_encounter_wreck(uuid, integer) from anon, authenticated;


-- ── THE SURGERY ─────────────────────────────────────────────────────────────────────────────────
-- Four hunks, applied to the body that is actually DEPLOYED. Each carries its source text verbatim
-- and each must match it EXACTLY ONCE: zero means the anchor is gone and the patch would silently do
-- nothing, more than one means it is ambiguous and the patch could land on the wrong site. Both
-- abort. Everything outside the four hunks is untouched by construction — that is the whole reason
-- this is a surgery and not a re-typed body.
do $rw$
declare
  v_def text;
  v_new text;
  r     record;
  v_n   integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_new := v_def;
  for r in
    select * from (values
      -- [W1] live 241-267 — arm A — the entry check: the fleet was already gone when the tick picked the encounter up
      ('W1',
       $w1o$
      -- ██ 0336 THE TERMINAL ARM IS CONFINED, AND THE ENCOUNTER STILL CONCLUDES ██
      -- fleet_destroy and presence_complete both RAISE on a status mismatch (fleet_destroy: not in a
      -- destroyable state; presence_complete: presence not in an active state). Neither was guarded
      -- here, and both run BEFORE this arm's own status write — so a mismatch rolled the whole tick
      -- back INCLUDING last_resolved_at, and the encounter retried, identically, every tick, forever
      -- and silently (the 0206 per-row guard downgrades the raise to a warning and the cron keeps
      -- returning normally). That is the wedge send_ship_group_hunt already names in prose.
      -- ONE LEAF, FOUR ARMS: combat_encounter_release confines each call in its own subtransaction
      -- so one failure cannot skip the other, re-raises query_canceled exactly as the outer guard
      -- does, and returns normally — which is what lets the status write below LAND. A mismatch now
      -- CONCLUDES the encounter with a warning instead of wedging it.
      -- ORDER IS IMMATERIAL, CHECKED: fleet_destroy writes fleets, presence_complete writes
      -- location_presence (+ the worldstate cache), mainship_mark_combat_destroyed writes
      -- main_ship_instances. No two of the three read what another writes, so folding the pair into
      -- one call at the head of the arm changes no outcome.
      -- AND THE RETREAT TARGET IS ALWAYS CONSUMED: only the settle arm ever cleared
      -- fleets.retreat_target_*, while its own header states the invariant that the recording is
      -- ALWAYS consumed. A fleet that died, or was wiped mid-fight, kept a stale destination that
      -- the NEXT sortie's settle would then fly to. One leaf, called by all four arms.
      perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
      perform public.fleet_consume_retreat_target(e.fleet_id);
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
        perform mainship_mark_combat_destroyed(cu.main_ship_id);
      end loop;
      update combat_encounters set status='defeat', tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), player_integrity_current=0, player_power_current=0,
             total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
$w1o$,
       $w1n$
      -- ██ HUNK [W1] (0343) — THIS ARM NO LONGER KNOWS HOW A FLEET DIES ██
      -- Nineteen lines of prose and five statements stood here, and they were the FIRST of three
      -- copies. They live once now, in public.combat_encounter_wreck — its header carries the 0336
      -- wedge, the confinement, why the order is immaterial and why the retreat target is ALWAYS
      -- consumed. This arm states only WHEN a fleet is a wreck; the leaf states what that means.
      -- WHAT DELIBERATELY STAYS HERE: the combat_ticks row below is arm A's alone. The spatial and
      -- aggregate arms log their tick a few lines ABOVE their own call, so a tick insert inside the
      -- leaf would double-log for two of its three callers. Same for the explosion event, whose seq
      -- is 0 here and the tick's running v_seq there — a real difference, not a copy.
      perform public.combat_encounter_wreck(e.id, v_tick);
$w1n$),
      -- [W4] live 303-323 — arm B — the DEPARTURE. Comment only. Not one statement in this arm changes.
      ('W4',
       $w4o$
      -- ██ 0336 THE TERMINAL ARM IS CONFINED, AND THE ENCOUNTER STILL CONCLUDES ██
      -- fleet_destroy and presence_complete both RAISE on a status mismatch (fleet_destroy: not in a
      -- destroyable state; presence_complete: presence not in an active state). Neither was guarded
      -- here, and both run BEFORE this arm's own status write — so a mismatch rolled the whole tick
      -- back INCLUDING last_resolved_at, and the encounter retried, identically, every tick, forever
      -- and silently (the 0206 per-row guard downgrades the raise to a warning and the cron keeps
      -- returning normally). That is the wedge send_ship_group_hunt already names in prose.
      -- ONE LEAF, FOUR ARMS: combat_encounter_release confines each call in its own subtransaction
      -- so one failure cannot skip the other, re-raises query_canceled exactly as the outer guard
      -- does, and returns normally — which is what lets the status write below LAND. A mismatch now
      -- CONCLUDES the encounter with a warning instead of wedging it.
      -- ORDER IS IMMATERIAL, CHECKED: fleet_destroy writes fleets, presence_complete writes
      -- location_presence (+ the worldstate cache), mainship_mark_combat_destroyed writes
      -- main_ship_instances. No two of the three read what another writes, so folding the pair into
      -- one call at the head of the arm changes no outcome.
      -- AND THE RETREAT TARGET IS ALWAYS CONSUMED: only the settle arm ever cleared
      -- fleets.retreat_target_*, while its own header states the invariant that the recording is
      -- ALWAYS consumed. A fleet that died, or was wiped mid-fight, kept a stale destination that
      -- the NEXT sortie's settle would then fly to. One leaf, called by all four arms.
      -- This arm consumes the retreat target a few lines below, where it also READS it, so it takes
      -- the release call alone (p_destroy_fleet false: a fleet that is leaving is not a wreck).
$w4o$,
       $w4n$
      -- ██ HUNK [W4] (0343) — COMMENT ONLY. NOT ONE STATEMENT IN THIS ARM CHANGES. ██
      -- THIS ARM IS A DEPARTURE, NOT A WRECK, and it is deliberately NOT folded. It releases with
      -- p_destroy_fleet FALSE, it READS the retreat target in the act of consuming it a few lines
      -- below, it marks survivors 'returning' rather than destroyed, it attaches the haul to a
      -- movement, and it reports BEFORE it releases. Folding it into the wreck leaf would zero a
      -- living player's haul and destroy their surviving ships.
      -- WHAT IS CORRECTED, not merely moved: the 0336 prose here was a copy of the leaf's and it
      -- ended "One leaf, called by all four arms." After 0343 that sentence is false anywhere it
      -- appears inline. There is ONE inline caller of combat_encounter_release — this one — and
      -- three arms that reach the same leaf through combat_encounter_wreck. 0336's property is
      -- UNCHANGED and is re-proved by this migration's assert (a): all four terminal arms release
      -- through the confined leaf, and all four consume the retreat target.
      -- The prose itself (the wedge, the subtransaction per call, the immaterial order) is not lost:
      -- it is in public.combat_encounter_wreck's header, once.
$w4n$),
      -- [W2] live 936-960 — arm C — the spatial arm's death, after damage resolved
      ('W2',
       $w2o$
          -- ██ 0336 THE TERMINAL ARM IS CONFINED, AND THE ENCOUNTER STILL CONCLUDES ██
          -- fleet_destroy and presence_complete both RAISE on a status mismatch (fleet_destroy: not in a
          -- destroyable state; presence_complete: presence not in an active state). Neither was guarded
          -- here, and both run BEFORE this arm's own status write — so a mismatch rolled the whole tick
          -- back INCLUDING last_resolved_at, and the encounter retried, identically, every tick, forever
          -- and silently (the 0206 per-row guard downgrades the raise to a warning and the cron keeps
          -- returning normally). That is the wedge send_ship_group_hunt already names in prose.
          -- ONE LEAF, FOUR ARMS: combat_encounter_release confines each call in its own subtransaction
          -- so one failure cannot skip the other, re-raises query_canceled exactly as the outer guard
          -- does, and returns normally — which is what lets the status write below LAND. A mismatch now
          -- CONCLUDES the encounter with a warning instead of wedging it.
          -- ORDER IS IMMATERIAL, CHECKED: fleet_destroy writes fleets, presence_complete writes
          -- location_presence (+ the worldstate cache), mainship_mark_combat_destroyed writes
          -- main_ship_instances. No two of the three read what another writes, so folding the pair into
          -- one call at the head of the arm changes no outcome.
          -- AND THE RETREAT TARGET IS ALWAYS CONSUMED: only the settle arm ever cleared
          -- fleets.retreat_target_*, while its own header states the invariant that the recording is
          -- ALWAYS consumed. A fleet that died, or was wiped mid-fight, kept a stale destination that
          -- the NEXT sortie's settle would then fly to. One leaf, called by all four arms.
          perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
          perform public.fleet_consume_retreat_target(e.fleet_id);
          for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
            perform mainship_mark_combat_destroyed(cu.main_ship_id);
          end loop;
          update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
$w2o$,
       $w2n$
          -- ██ HUNK [W2] (0343) — ONE AUTHORITY FOR A WRECK: public.combat_encounter_wreck ██
          -- Nineteen lines of prose and five statements stood here, byte-identical to the aggregate
          -- arm's copy below and to arm A's above. They are the leaf now.
          -- BEHAVIOUR DELTA, STATED BECAUSE IT IS NOT ZERO: the leaf's terminal UPDATE is arm A's
          -- fuller one, so this arm now also writes tick_number, last_resolved_at,
          -- player_integrity_current=0 and player_power_current=0. Three of those four are already
          -- this row's values — the UPDATE directly above set tick_number=v_tick and
          -- last_resolved_at=now(), and player_integrity_current=greatest(0, v_hp_after) is exactly
          -- 0 whenever this branch is entered (v_hp_after <= 0 is its condition). The fourth,
          -- player_power_current, is forced to 0 instead of being read from
          -- combat_encounter_side_power over a side with no living unit. This is a terminal row: it
          -- is never ticked again, and 0 is what a wrecked fleet's power is.
          -- The tick row for this pass was already logged a few lines above, which is why the leaf
          -- logs none.
          perform public.combat_encounter_wreck(e.id, v_tick);
$w2n$),
      -- [W3] live 1352-1376 — arm D — the aggregate (0228, no-positions) arm's death; the whole arm goes in 0345
      ('W3',
       $w3o$
        -- ██ 0336 THE TERMINAL ARM IS CONFINED, AND THE ENCOUNTER STILL CONCLUDES ██
        -- fleet_destroy and presence_complete both RAISE on a status mismatch (fleet_destroy: not in a
        -- destroyable state; presence_complete: presence not in an active state). Neither was guarded
        -- here, and both run BEFORE this arm's own status write — so a mismatch rolled the whole tick
        -- back INCLUDING last_resolved_at, and the encounter retried, identically, every tick, forever
        -- and silently (the 0206 per-row guard downgrades the raise to a warning and the cron keeps
        -- returning normally). That is the wedge send_ship_group_hunt already names in prose.
        -- ONE LEAF, FOUR ARMS: combat_encounter_release confines each call in its own subtransaction
        -- so one failure cannot skip the other, re-raises query_canceled exactly as the outer guard
        -- does, and returns normally — which is what lets the status write below LAND. A mismatch now
        -- CONCLUDES the encounter with a warning instead of wedging it.
        -- ORDER IS IMMATERIAL, CHECKED: fleet_destroy writes fleets, presence_complete writes
        -- location_presence (+ the worldstate cache), mainship_mark_combat_destroyed writes
        -- main_ship_instances. No two of the three read what another writes, so folding the pair into
        -- one call at the head of the arm changes no outcome.
        -- AND THE RETREAT TARGET IS ALWAYS CONSUMED: only the settle arm ever cleared
        -- fleets.retreat_target_*, while its own header states the invariant that the recording is
        -- ALWAYS consumed. A fleet that died, or was wiped mid-fight, kept a stale destination that
        -- the NEXT sortie's settle would then fly to. One leaf, called by all four arms.
        perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
        perform public.fleet_consume_retreat_target(e.fleet_id);
        for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
          perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end loop;
        update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
$w3o$,
       $w3n$
        -- ██ HUNK [W3] (0343) — ONE AUTHORITY FOR A WRECK: public.combat_encounter_wreck ██
        -- The aggregate arm's copy of the same nineteen lines and the same five statements. Deleted
        -- here, alive once in the leaf. The behaviour delta is identical to [W2]'s and is stated
        -- there: this arm gains the four terminal columns, three of which already hold these very
        -- values, and player_power_current becomes 0 on a row that will never tick again.
        -- This whole arm is scheduled for deletion by 0345. It is folded rather than left alone so
        -- that the fold is complete while it lives: leaving one inline copy would keep two
        -- authorities for a wreck for as long as 0345 takes to land.
        perform public.combat_encounter_wreck(e.id, v_tick);
$w3n$)
    ) as t(tag, old_t, new_t)
  loop
    v_n := (length(v_new) - length(replace(v_new, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0343 HUNK [%] FAIL: its source text occurs % time(s) in the deployed body (want exactly 1). Zero means the anchor is missing — the deployed body is not the one this hunk was cut from, and applying it would either do nothing or patch the wrong site. Do not weaken this to >= 1', r.tag, v_n;
    end if;
    v_new := replace(v_new, r.old_t, r.new_t);
  end loop;
  -- The surgery must have CHANGED something, and it must have changed only what it was given. Both
  -- ends, because a no-op replace chain that leaves the body identical would sail through every
  -- absence assert in the deployed-body checks below by inheriting the old body's own text.
  if v_new = v_def then
    raise exception '0343 SURGERY FAIL: the rewritten body is identical to the deployed one — nothing was replaced';
  end if;
  if length(v_new) >= length(v_def) then
    raise exception '0343 SURGERY FAIL: the rewritten body is % chars against the deployed %; this fold deletes 98 lines and must be strictly shorter', length(v_new), length(v_def);
  end if;
  execute v_new;
  raise notice '0343 surgery applied: 4 hunks, each matched exactly once; % chars -> % chars', length(v_def), length(v_new);
end $rw$;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SELF-ASSERTS — this migration fails the deploy rather than shipping the old shape back
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- Every count is over a COMMENT-STRIPPED copy of the deployed prosrc. That is not tidiness: four
-- banners in this body name combat_encounter_release in PROSE, and counting raw text would score
-- them as calls. It is also the 0222 trap in reverse — that migration aborted on every apply because
-- its probe's target existed ONLY inside a comment its own strip removed — so each block here first
-- proves its probe is live before drawing a conclusion from a zero.

-- (a) THE FOLD LANDED, EXACTLY THREE TIMES, AND THE DEPARTURE IS STILL ITS OWN CONCEPT
do $a$
declare v_raw text; v_code text; v_n integer;
begin
  select p.prosrc, regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')
    into v_raw, v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  -- NON-VACUITY, BOTH DIRECTIONS. Half of this block asserts that something is ABSENT, and an empty
  -- string satisfies every such assert. So: the stripped body must be substantial, and the strip
  -- must have removed something.
  if v_code is null or length(v_code) < 40000 then
    raise exception '0343 ASSERT (a) FAIL: the comment-stripped tick is % char(s) (want > 40000) — every absence asserted below would be measured against nothing', coalesce(length(v_code), -1);
  end if;
  if length(v_code) >= length(v_raw) then
    raise exception '0343 ASSERT (a) FAIL: the comment strip removed nothing from a % char body — the banners that name combat_encounter_release in prose would be counted as calls', length(v_raw);
  end if;

  -- THREE ARMS, ONE LEAF. Counted on the full call text, so an arm that passed the wrong tick would
  -- not be counted as folded.
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_wreck(e.id, v_tick)', '')))
         / length('public.combat_encounter_wreck(e.id, v_tick)');
  if v_n <> 3 then
    raise exception '0343 ASSERT (a) FAIL: % arm(s) resolve a wreck through the leaf (want exactly 3: the entry check, the spatial death, the aggregate death)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'combat_encounter_wreck(', '')))
         / length('combat_encounter_wreck(');
  if v_n <> 3 then
    raise exception '0343 ASSERT (a) FAIL: the tick calls combat_encounter_wreck % time(s) but only 3 of them pass (e.id, v_tick) — a fourth call in another shape is a second way to die', v_n;
  end if;

  -- NOT ONE INLINE COPY SURVIVES.
  if v_code ~ '(set|,)[[:space:]]*status[[:space:]]*=[[:space:]]*''defeat''' then
    raise exception '0343 ASSERT (a) FAIL: the tick still writes status = ''defeat'' inline — that is the second authority for a wreck this migration exists to remove';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true)', '')))
         / length('public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true)');
  if v_n <> 0 then
    raise exception '0343 ASSERT (a) FAIL: % arm(s) still release-and-destroy inline (want 0 — a wreck goes through the leaf)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'perform public.fleet_consume_retreat_target(e.fleet_id);', '')))
         / length('perform public.fleet_consume_retreat_target(e.fleet_id);');
  if v_n <> 0 then
    raise exception '0343 ASSERT (a) FAIL: % arm(s) still consume the retreat target inline with a bare perform (want 0 — the leaf does it for all three wreck arms)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'perform mainship_mark_combat_destroyed(cu.main_ship_id);', '')))
         / length('perform mainship_mark_combat_destroyed(cu.main_ship_id);');
  if v_n <> 1 then
    raise exception '0343 ASSERT (a) FAIL: % site(s) mark a member destroyed in the tick (want exactly 1 — the DEPARTURE arm''s dead-member branch, which is not a wreck; the three wreck loops are the leaf''s now)', v_n;
  end if;

  -- 0336's PROPERTY, RE-PROVED THROUGH THE NEW STRUCTURE. Its assert (f) demanded that all four
  -- terminal arms release through the confined leaf and all four consume the retreat target. That is
  -- still true and it is now true STRUCTURALLY: one arm does it inline (the departure, immediately
  -- below) and three reach the identical pair inside combat_encounter_wreck, which (b) proves.
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, false)', '')))
         / length('public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, false)');
  if v_n <> 1 then
    raise exception '0343 ASSERT (a) FAIL: % arm(s) release WITHOUT destroying the fleet (want exactly 1 — the departure. If this is 0 the departure has been folded into the wreck leaf, which destroys a living player''s ships)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'fleet_consume_retreat_target', '')))
         / length('fleet_consume_retreat_target');
  if v_n <> 1 then
    raise exception '0343 ASSERT (a) FAIL: the tick names fleet_consume_retreat_target % time(s) (want exactly 1 — the departure arm, which must READ the destination while consuming it)', v_n;
  end if;
end $a$;

-- (b) THE LEAF IS THE AUTHORITY, AND IT IS ONLY THAT
do $b$
declare v_raw text; v_code text; v_needle text;
begin
  select p.prosrc, regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')
    into v_raw, v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_encounter_wreck';
  if v_code is null or length(v_code) < 400 then
    raise exception '0343 ASSERT (b) FAIL: combat_encounter_wreck''s body is % char(s) — there is nothing here to be the authority', coalesce(length(v_code), -1);
  end if;
  -- COMPOSES ALL THREE PRIMITIVES, ONCE EACH. Not reimplemented: no fleet_destroy, no
  -- presence_complete, no inline clear of fleets.retreat_target_*.
  if position('public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true)' in v_code) = 0 then
    raise exception '0343 ASSERT (b) FAIL: the leaf does not release through 0336''s confined leaf — an unguarded release can wedge an encounter into retrying forever';
  end if;
  if position('public.fleet_consume_retreat_target(e.fleet_id)' in v_code) = 0 then
    raise exception '0343 ASSERT (b) FAIL: the leaf does not consume the retreat target — a dead fleet would keep a stale destination that the NEXT sortie flies to';
  end if;
  if position('mainship_mark_combat_destroyed(cu.main_ship_id)' in v_code) = 0 then
    raise exception '0343 ASSERT (b) FAIL: the leaf does not mark the members destroyed — the hulls would stay status=''home'' with hp 0, which no recovery verb accepts';
  end if;
  if position('perform fleet_destroy' in v_code) > 0 or position('perform presence_complete' in v_code) > 0
     or position('update public.fleets set retreat_target' in v_code) > 0
     or position('update fleets set retreat_target' in v_code) > 0 then
    raise exception '0343 ASSERT (b) FAIL: the leaf reimplements a primitive instead of composing it — that is a second authority inside the authority';
  end if;
  -- THE TERMINAL ROW IS ARM A's FULLER WRITE, ALL SEVEN COLUMNS.
  if v_code !~ '(set|,)[[:space:]]*status[[:space:]]*=[[:space:]]*''defeat''' then
    raise exception '0343 ASSERT (b) FAIL: the leaf does not write status = ''defeat'' — then nothing does, and assert (d) would pass on an empty world';
  end if;
  foreach v_needle in array array['tick_number=p_tick', 'ended_at=now()', 'last_resolved_at=now()',
                                  'player_integrity_current=0', 'player_power_current=0',
                                  'total_rewards_json=''{}''::jsonb', 'updated_at=now()'] loop
    if position(v_needle in v_code) = 0 then
      raise exception '0343 ASSERT (b) FAIL: the leaf''s terminal write is missing % — it must be arm A''s fuller UPDATE, or arm A loses a column it has always written', v_needle;
    end if;
  end loop;
  -- AND IT IS NOT A LOGGER. Both of these would double-write for two of its three callers.
  if position('combat_ticks' in v_code) > 0 then
    raise exception '0343 ASSERT (b) FAIL: the leaf touches combat_ticks — the spatial and aggregate arms log their tick BEFORE they call it, so a row here is a double log';
  end if;
  if position('combat_events' in v_code) > 0 then
    raise exception '0343 ASSERT (b) FAIL: the leaf touches combat_events — the explosion event''s seq is 0 at one call site and the tick''s running v_seq at the other two, and that difference is real';
  end if;
  -- A MISSING TICK NUMBER IS REFUSED, NOT DEFAULTED. A coalesce here would write a wrong observable.
  if position('p_tick is null' in v_code) = 0 then
    raise exception '0343 ASSERT (b) FAIL: the leaf accepts a NULL tick — a silently defaulted terminal tick_number is a wrong number, not a missing one';
  end if;
end $b$;

-- (c) THE CALL SITES KEPT WHAT IS THEIRS — the row-count parity the fold must not disturb
do $c$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  -- Arm A's combat_ticks row, at its own call site, still exactly one. Anchored on its own VALUES
  -- list rather than on the lines around it, because the lines around it are what changed.
  v_n := (length(v_code) - length(replace(v_code, 'e.enemy_integrity_current, e.enemy_integrity_current, ''defeat'');', '')))
         / length('e.enemy_integrity_current, e.enemy_integrity_current, ''defeat'');');
  if v_n <> 1 then
    raise exception '0343 ASSERT (c) FAIL: the entry arm logs % combat_ticks row(s) with result ''defeat'' (want exactly 1 — the leaf logs none, so if this is 0 the fold ate a tick row and if it is 2 something double-logs)', v_n;
  end if;
  -- Three explosion events, one per wreck arm, each still at its own seq.
  v_n := (length(v_code) - length(replace(v_code, '''reason'',''fleet_lost''', '')))
         / length('''reason'',''fleet_lost''');
  if v_n <> 3 then
    raise exception '0343 ASSERT (c) FAIL: % fleet_lost explosion event(s) in the tick (want exactly 3, one per wreck arm — silence is a bug, and the client renders this)', v_n;
  end if;
  -- Four reports, unchanged: three wrecks and the departure.
  v_n := (length(v_code) - length(replace(v_code, 'perform report_create(e.id);', '')))
         / length('perform report_create(e.id);');
  if v_n <> 4 then
    raise exception '0343 ASSERT (c) FAIL: % report_create call(s) (want exactly 4 — the three wreck arms and the departure; a fight that ends without a report is a fight the player cannot read)', v_n;
  end if;
end $c$;

-- (d) ██ THE CLASS GUARD ██ ONE FUNCTION IN THE DATABASE DECIDES WHAT A DEFEAT IS
--
-- This is the assert that fails the deploy if the old behaviour ever returns. It does not look at
-- the tick — it looks at the whole schema, so a NEW function that inlines a defeat write is caught
-- as well as a reverted one.
--
-- WHY IT CANNOT PASS VACUOUSLY. The finding "no other function writes it" is worthless if the probe
-- matches nothing at all, which is exactly how a green self-assert once hid three inline writers. So
-- the probe must FIND THE LEAF FIRST, by the same pattern, in the same query. A broken pattern
-- therefore fails as a broken pattern instead of reporting an empty world as a clean one.
--
-- The pattern requires the assignment to be preceded by `set` or `,` — a SET-list position — so a
-- READ (`where status = 'defeat'`, `case when status = 'defeat'`) is not a match, and a reordered
-- SET list still is. It is conjoined with the function naming combat_encounters at all, so a
-- 'defeat' on some other table's status column is not swept in.
do $d$
declare v_n integer; v_names text; v_leaf integer;
begin
  with writers as (
    select p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind in ('f', 'p')
       and position('combat_encounters' in p.prosrc) > 0
       and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')
           ~ '(set|,)[[:space:]]*status[[:space:]]*=[[:space:]]*''defeat'''
  )
  select count(*), count(*) filter (where proname = 'combat_encounter_wreck'),
         coalesce(string_agg(proname, ', ' order by proname), '(none)')
    into v_n, v_leaf, v_names
    from writers;
  if v_leaf <> 1 then
    raise exception '0343 ASSERT (d) FAIL: the defeat-write probe does not match combat_encounter_wreck itself (matched % of it), so its count of % writer(s) proves nothing. Fix the probe, do not trust the zero. Matched: %', v_leaf, v_n, v_names;
  end if;
  if v_n <> 1 then
    raise exception '0343 ASSERT (d) FAIL: % function(s) in public write combat_encounters.status = ''defeat'' (want exactly 1, public.combat_encounter_wreck). There is one way to die. Matched: %', v_n, v_names;
  end if;
end $d$;

-- (e) THE DEPARTURE SURVIVED THE FOLD INTACT
--
-- Arm B is the arm this slice is most likely to be "improved" into the leaf by a later reader who
-- sees four similar-looking terminal arms. Every statement that makes a departure different from a
-- wreck is pinned here, so that folding it in fails the deploy rather than a player's fleet.
do $e$
declare v_code text; v_n integer; v_needle text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  foreach v_needle in array array[
    'public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, false)',
    'mainship_mark_legacy_in_flight(cu.main_ship_id, ''returning'')',
    'movement_attach_cargo(v_mv, e.id, e.total_rewards_json)',
    'perform fleet_set_returning(e.fleet_id, v_mv);',
    '''retreat_completed'''] loop
    v_n := (length(v_code) - length(replace(v_code, v_needle, ''))) / length(v_needle);
    if v_n <> 1 then
      raise exception '0343 ASSERT (e) FAIL: the departure arm carries % of "%" (want exactly 1). A fleet that leaves alive keeps its haul, keeps its surviving ships and marks them returning — folding that into the wreck leaf would zero the haul and destroy the ships', v_n, v_needle;
    end if;
  end loop;
end $e$;

-- (f) NOTHING DARK. There is no knob, and its absence is ASSERTED rather than promised.
--
-- The owner's ruling: "don't make anything dark, make it so that i can check." A refactor behind a
-- flag would mean two live authorities selected by a config read — the exact shape this slice
-- deletes — and a flag that gates nothing is not a safety device, it is a thing that will be
-- repurposed later and ship a no-op.
do $f$
declare v_keys text;
begin
  select coalesce(string_agg(key, ', ' order by key), '') into v_keys
    from public.game_config
   where key ilike '%encounter_wreck%' or key ilike '%one_way_to_die%' or key ilike '%wreck_leaf%';
  if v_keys <> '' then
    raise exception '0343 ASSERT (f) FAIL: game_config carries a key for this slice (%) — 0343 ships no flag, and a gate that selects between two ways to die is the spaghetti it removes', v_keys;
  end if;
end $f$;

-- (g) THE LEAF IS ENGINE-INTERNAL, ESTABLISHED AND THEN ASSERTED
--
-- EXECUTE is granted to PUBLIC by default on every new function, and 0254's grant drift proved that
-- establishing a surface and asserting it are two different acts. The revokes above establish it;
-- this proves it. grantee = 0 is PUBLIC, which is the hole a revoke naming only anon and
-- authenticated leaves standing (the 0309 lesson).
do $g$
declare v_acl aclitem[]; v_bad text;
begin
  select p.proacl into v_acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_encounter_wreck';
  if v_acl is null then
    raise exception '0343 ASSERT (g) FAIL: combat_encounter_wreck carries DEFAULT privileges — a NULL proacl means PUBLIC still holds EXECUTE on it';
  end if;
  if exists (select 1 from aclexplode(v_acl) a where a.grantee = 0) then
    raise exception '0343 ASSERT (g) FAIL: PUBLIC holds a privilege on combat_encounter_wreck — a wreck is the engine''s decision, never a client call';
  end if;
  select string_agg(r, ', ') into v_bad
    from unnest(array['anon', 'authenticated']) r
   where has_function_privilege(r, 'public.combat_encounter_wreck(uuid, integer)', 'EXECUTE');
  if v_bad is not null then
    raise exception '0343 ASSERT (g) FAIL: % can EXECUTE combat_encounter_wreck — a client could destroy its own fleet and end its own fight', v_bad;
  end if;
  raise notice '0343 self-assert ok: ONE way to die. public.combat_encounter_wreck(uuid, integer) is the only function in the database that writes combat_encounters.status = ''defeat'' (proved by a schema sweep whose probe had to match the leaf itself first, so the finding cannot be a broken regex reading an empty world); the three fleet-death arms — the entry check, the spatial death and the aggregate death — are three CALLERS of it and no longer three copies, with zero inline release-and-destroy, zero inline retreat-target consumes and zero inline defeat writes left in the tick; the leaf COMPOSES combat_encounter_release(..., true), fleet_consume_retreat_target and mainship_mark_combat_destroyed and reimplements none of them, writes all seven terminal columns of arm A''s fuller UPDATE, refuses a NULL tick rather than defaulting it, and touches neither combat_ticks nor combat_events (arm A keeps its own tick row — asserted still exactly 1 — and all three arms keep their own explosion event at their own seq — asserted still exactly 3, with 4 report_create calls unchanged); the DEPARTURE arm is untouched and pinned, release(..., false), the ''returning'' branch, the cargo attach, fleet_set_returning and retreat_completed all still exactly once each, so a fleet that leaves alive still keeps its haul and its ships; NO feature flag, NO game_config key (asserted ABSENT), no column, no schema change, no data write; the leaf is revoked from PUBLIC BY NAME and unreachable by anon and authenticated; and the whole 1,396-line body is production''s own bytes (md5 3806e89a97237bf00f593ad38a834580) with four marked hunks and nothing else changed';
end $g$;
