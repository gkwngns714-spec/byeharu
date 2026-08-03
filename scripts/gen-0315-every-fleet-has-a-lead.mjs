#!/usr/bin/env node
// gen-0315-every-fleet-has-a-lead.mjs — emit (or --check) migration 0315.
//
// WHY A GENERATOR: 0315 rewrites FIVE hunks inside the live combat_create_group_encounter body.
// The function's TRUE state is 0301's text (the last `create or replace` — 0168/0195/0228/0234/0262/
// 0293 precede it and 0302..0314 re-create it never) with 0308's TWO replace-surgery hunks applied
// on top. So the slice source is per-hunk, not per-file: four hunks come from 0301 (the declaration
// block, the formation anchor, the aggro line and the spawn branch — none of which 0308 touched) and
// one comes from the EMITTED 0308 file (the roster projection, which 0308 rewrote and therefore owns
// the deployed text of). The 0303 lesson — "never retype a live function body" — holds: every
// `old_t` below is SLICED verbatim, and every `new_t` is CONSTRUCTED from that slice by exactly-once
// string edits, so even the unchanged words inside a replaced hunk are byte-copies. The migration
// then proves each slice is still what is deployed (occurs EXACTLY once in pg_get_functiondef),
// replaces it, and proves the length moved by exactly the hunk delta.
//
//   node scripts/gen-0315-every-fleet-has-a-lead.mjs          # write the migration
//   node scripts/gen-0315-every-fleet-has-a-lead.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000315_every_fleet_has_a_lead.sql');

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECKS: establish that 0301 + 0308 really are the deployed text of this function. ───────
// (1) No later TEXTUAL re-create. A `create or replace function … combat_create_group_encounter`
//     after 0301 would make every 0301 slice stale. 0313 names the function in a comment only, so
//     `--` line comments are stripped before the test (the 0314 idiom, same reason).
// (2) No later REPLACE-REWRITER. A migration after 0308 that carries this function name in a hunk
//     row — the house `(idx, 'fname',` shape used by 0308 and 0314 — has surgically edited the body
//     since 0308, and the 0301/0308 slices can no longer be assumed intact. This is deliberately
//     narrow: a later migration that merely NAMES the function in a read-only probe or a comment is
//     not drift and must not fail the gate.
{
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const files = readdirSync(MIGDIR).filter((f) => f.endsWith('.sql') && version(f) !== '20260618000315');
  const stripped = new Map(
    files.map((f) => [f, readFileSync(MIG(f), 'utf8').replace(/--[^\n]*/g, '')]));

  const reCreate = /create\s+or\s+replace\s+function\s+(?:public\.)?combat_create_group_encounter\s*\(/i;
  const newerHeads = files.filter((f) => version(f) > '20260618000301' && reCreate.test(stripped.get(f)));
  if (newerHeads.length > 0) {
    throw new Error(
      `combat_create_group_encounter was textually re-created AFTER 0301 by: ${newerHeads.join(', ')} — ` +
      're-point the slices at the new head before generating.');
  }

  // 0316 IS EXEMPT BY NAME, not by widening the window. It rewrites this function AFTER 0315 (the
  // world-travel -> combat-space speed conversion), which is exactly what this gate is built to
  // notice — but 0315's slices come from 0301 and 0308, both FROZEN history, and the file 0315
  // emits is frozen too. What the gate protects is "never cut a NEW slice from a head that has
  // moved", and 0315 cuts nothing new. Naming the one known later rewriter keeps the protection
  // live for 0317 and everything after it; raising the version floor would not.
  // 0317 IS EXEMPT ON EXACTLY THE SAME TERMS, and it is named for the same reason rather than the
  // floor being moved: it rewrites this function after 0315 (the weapon-power normalisation, the
  // hp_max seed, max_hp in the roster projection), but 0315 still cuts nothing new — its slices are
  // 0301 and 0308, both frozen. NOTE the one real coupling: 0317 slices two lines out of the file
  // 0315 EMITS (its declaration tail and its roster projection), so an edit to gen-0315 that changes
  // either of those emitted lines will break gen-0317's --check, loudly, in the same CI run.
  const KNOWN_LATER_REWRITERS = new Set(['20260618000316', '20260618000317']);
  const reHunkRow = /\(\s*\d+\s*,\s*'combat_create_group_encounter'\s*,/;
  const newerSurgery = files.filter((f) => version(f) > '20260618000308'
    && !KNOWN_LATER_REWRITERS.has(version(f))
    && reHunkRow.test(stripped.get(f)));
  if (newerSurgery.length > 0) {
    throw new Error(
      `combat_create_group_encounter was rewritten by hunk surgery AFTER 0308 by: ${newerSurgery.join(', ')} — ` +
      'read that migration and re-point these slices; do not regenerate blindly.');
  }
}

const F301 = load('20260618000301_intercept_fires_at_zone_entry.sql');
const F308 = load('20260618000308_combat_roster_is_live_membership.sql');

/** Slice [from,to] 1-indexed inclusive, asserting fence lines so source drift fails loudly. */
function slice(lines, file, from, to, startsWith, endsWith) {
  const text = lines.slice(from - 1, to).join('\n');
  const first = lines[from - 1];
  const last = lines[to - 1];
  if (!first.includes(startsWith)) {
    throw new Error(`${file}:${from} expected to contain ${JSON.stringify(startsWith)}, got ${JSON.stringify(first)}`);
  }
  if (!last.includes(endsWith)) {
    throw new Error(`${file}:${to} expected to contain ${JSON.stringify(endsWith)}, got ${JSON.stringify(last)}`);
  }
  return text;
}

/** Replace `from` with `to` in `base`, demanding `from` occurs EXACTLY once — the parity guard
 *  that lets new_t be CONSTRUCTED from the slice instead of retyped. */
function edit(base, from, to) {
  const n = base.split(from).length - 1;
  if (n !== 1) throw new Error(`edit(): needle occurs ${n} time(s), want exactly 1: ${JSON.stringify(from)}`);
  return base.replace(from, to);
}

// ── THE FIVE HUNKS ────────────────────────────────────────────────────────────────────────────────

// [H1] two new declarations, appended after the last local (0301:703).
const H1_OLD = slice(F301, '0301', 703, 703, 'v_weapons_json    jsonb;', 'v_weapons_json    jsonb;');
const H1_NEW = H1_OLD + '\n' +
`  -- 0315 THE LEAD: one derivation, one variable, read by BOTH the anchor spawn and the aggro
  -- screen. v_lead_ship_id is resolved ONCE before the member loop (never per member, never per
  -- branch); v_is_lead is that one decision applied to the member in hand.
  v_lead_ship_id    uuid;
  v_is_lead         boolean;`;

// [H2] the lead derivation, appended after the formation-anchor block (0301:720-724). The whole
//      five-line block is the slice because `if v_spatial_enabled then` occurs twice in the body.
const H2_OLD = slice(F301, '0301', 720, 724, 'if v_spatial_enabled then', 'end if;');
const H2_NEW = H2_OLD + '\n' +
`
  -- 0315 EVERY FLEET ENTERING COMBAT HAS A LEAD ==================================================
  -- The head asked main_ship_instances.is_command_ship directly, in two places, and assumed the
  -- answer was true for exactly one member of every sortie. On production it is true for ONE ship
  -- out of 74. The flag is only ever written by set_fleet_command_ship (0204); the unified mover
  -- command_ship_group_go never required it (only the legacy hunt/expedition senders answer
  -- fleet_inactive_no_command), and an AMBUSH is precisely the entry that does not pass through
  -- those senders. So real fleets have always been able to reach this builder with no flagged ship
  -- at all, and the formation that produced was broken in two ways at once:
  --   NOBODY AT THE ANCHOR. Every hull took an escort ring slot at spatial_formation_ring_radius
  --   (30) while the wave spawns AT the anchor (0299:765-774) — and since 0313 cut the player gun
  --   to 25, every hull opened the fight outside its own range and the first tick fired nothing.
  --   NO AGGRO SCREEN. Every row carried priority 0, so the tick's min(aggro_priority) tier
  --   (0299:840-844) admitted the whole fleet and every enemy converged on whichever hull happened
  --   to be nearest, instead of the escorts screening a protected lead.
  -- THE ONE RULE, resolved once, here, for every sortie:
  --   a real command ship first   the flag STILL WINS. This derivation is a FALLBACK, never an
  --                               override, and set_fleet_command_ship remains the only writer of
  --                               it — this migration writes no player data whatsoever. Two
  --                               flagged ships resolve deterministically by the keys below.
  --   then the greatest max_hp    the lead stands ON the enemy spawn point and is the hull the
  --                               screen holds back until every escort is gone, so the toughest
  --                               hull is the one that can hold that spot. max_hp, not hp:
  --                               capacity is a stable property of the hull — the very denominator
  --                               0310's auto-exit already calls a fleet's capacity — so a fleet's
  --                               lead does not shuffle from fight to fight as damage accumulates,
  --                               and the player can learn who leads.
  --   then main_ship_id ascending a total order over uuids: two hulls of equal capacity always
  --                               resolve the same way. It is the tie-break the member loop below
  --                               (order by gsm.main_ship_id), the tick's targeting
  --                               (order by dist asc, id asc) and 0228's screen already use.
  -- LIVING HULLS ONLY. A wreck cannot anchor a formation (the hp>0 branch below never gives it a
  -- position) and cannot screen anyone (the tick freezes its targeting snapshot over alive_count>0
  -- only, so a dead row's priority is never read), and electing one would reproduce exactly the
  -- defect this fixes. If a fleet has no living hull at all the select finds nothing,
  -- v_lead_ship_id stays NULL, and v_is_lead is false for every member — the head's own shape on
  -- the one input where there is no formation to anchor anyway.
  select gsm.main_ship_id into v_lead_ship_id
    from public.group_sortie_live_members(pr.fleet_id) gsm
    join main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
   where msi.hp > 0
   order by msi.is_command_ship desc, msi.max_hp desc, gsm.main_ship_id asc
   limit 1;`;

// [H3] the roster projection stops carrying the flag (0308:345 — 0308 owns this line's deployed
//      text). Nothing in the loop reads it once H4/H5 land, and a second place to read the flag
//      from is how it came to be read twice in the first place.
const H3_OLD = slice(F308, '0308', 345, 345, 'select gsm.main_ship_id, gsm.player_id', 'msi.is_command_ship');
const H3_NEW =
`    -- 0315: is_command_ship is GONE from this projection. The flag is consulted EXACTLY ONCE in
    -- this function — in the lead derivation above — and the per-member question is v_is_lead.
` + edit(H3_OLD, ', msi.is_command_ship', '');

// [H4] the aggro screen asks the lead, not the flag (0301:735).
const H4_OLD = slice(F301, '0301', 735, 735,
  'v_aggro_priority := case when m.is_command_ship then 100 else 0 end;',
  'v_aggro_priority := case when m.is_command_ship then 100 else 0 end;');
const H4_NEW =
`    -- 0315: ONE authority for "who leads this formation" — the same v_is_lead decides the anchor
    -- spawn below. Reading the concept twice is what let the two halves disagree.
    v_is_lead := m.main_ship_id is not distinct from v_lead_ship_id;
` + edit(H4_OLD, 'case when m.is_command_ship then', 'case when v_is_lead then');

// [H5] the anchor spawn asks the SAME lead (0301:755-762).
const H5_OLD = slice(F301, '0301', 755, 762, 'if m.is_command_ship then', 'end if;');
const H5_NEW =
`          -- 0315: the anchor spawn asks the SAME v_is_lead the aggro screen asked. The pairing is
          -- the point: the hull standing on the enemy spawn point is exactly the hull the screen
          -- holds back, so a fleet can never place a ship at distance 0 without protecting it, and
          -- can never protect a ship that is not there. Escort ring slots are unchanged; with a
          -- lead now always elected, the remaining hulls take slots 0..n-2 instead of 0..n-1.
` + edit(H5_OLD, 'if m.is_command_ship then', 'if v_is_lead then');

const HUNKS = [
  [1, 'combat_create_group_encounter', H1_OLD, H1_NEW],
  [2, 'combat_create_group_encounter', H2_OLD, H2_NEW],
  [3, 'combat_create_group_encounter', H3_OLD, H3_NEW],
  [4, 'combat_create_group_encounter', H4_OLD, H4_NEW],
  [5, 'combat_create_group_encounter', H5_OLD, H5_NEW],
];

// Dollar-quote tags must not collide with anything inside the hunk text.
const rows = HUNKS.map(([idx, fname, oldT, newT]) => {
  const o = `$h${idx}o$`;
  const n = `$h${idx}n$`;
  for (const [tag, body] of [[o, oldT], [n, newT]]) {
    if (body.includes(tag)) throw new Error(`dollar-quote tag ${tag} collides with hunk ${idx}`);
    if (body.includes('$')) throw new Error(`hunk ${idx} contains '$' — dollar-quoting is unsafe`);
    if (!body.trim()) throw new Error(`hunk ${idx} sliced empty — a line range is wrong`);
  }
  // PLPGSQL VARIABLE CAPTURE (the 0310 rev.2 / 0314 lesson): combat_create_group_encounter declares
  // record variables `pr` and `m`, and plpgsql resolves table-alias-qualified references against
  // variables too — an alias shadowing one of them raises "ambiguous" at FIRST EXECUTION only.
  // Applied to the NEW text only; the old text is the deployed head.
  {
    const mm = newT.match(/\b(?:from|join)\s+[a-z_][a-z0-9_.]*\s+(pr|m)\b/i);
    if (mm) throw new Error(`hunk ${idx} aliases a table as '${mm[1]}' — that name is a plpgsql record variable in combat_create_group_encounter and the reference would be ambiguous at first execution`);
  }
  return `    (${idx}, '${fname}',\n     ${o}${oldT}${o},\n     ${n}${newT}${n})`;
}).join(',\n');

// the hunks must be PAIRWISE DISJOINT as text (a later replace must never hit an earlier result).
for (let i = 0; i < HUNKS.length; i++) {
  for (let j = 0; j < HUNKS.length; j++) {
    if (i !== j && (HUNKS[j][3].includes(HUNKS[i][2]) || HUNKS[j][2].includes(HUNKS[i][2]))) {
      throw new Error(`hunk ${HUNKS[i][0]}'s old text occurs inside hunk ${HUNKS[j][0]} — the sequential rewrite would double-apply`);
    }
  }
}

// Comment-stripping idiom proven by 0305/0306/0308/0310/0314 against this database's settings.
const STRIP = `regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')`;

const sql = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0315 — EVERY FLEET ENTERING COMBAT HAS A LEAD
--        (the encounter builder stops assuming a command ship exists, and derives one when it does not)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE DEFECT, MEASURED ON LIVE PRODUCTION ──────────────────────────────────────────────────────
-- Of 74 live ships, exactly ONE carries main_ship_instances.is_command_ship = true, and it is an
-- expendable test ship. The owner's own fleets (4 ships and 1 ship) carry none. The flag is written
-- only by set_fleet_command_ship (0204); the four legacy group verbs refuse an unflagged group with
-- fleet_inactive_no_command, but the unified mover command_ship_group_go — the verb every fleet
-- actually moves with, and the one an AMBUSH interrupts — has never asked for it. So the builder's
-- assumption has been false for effectively every real fight:
--
--   1. NOBODY SPAWNS AT THE ENGAGEMENT ANCHOR. 0301:755-761 put the command ship at distance 0 and
--      every other hull on the spatial_formation_ring_radius (30) ring. With no flagged ship, every
--      hull took a ring slot. Enemies spawn AT the anchor (0299:765-774), and 0313 cut the player
--      gun to 25 (mk2 30) — so the whole fleet opened the fight 30 units out, OUTSIDE its own
--      range, and tick 1 fired nothing. 0313's own header states the opposite as fact ("the COMMAND
--      ship spawns at distance 0 … so a fight always starts firing on tick 1", :54-56); that
--      sentence was true only for a fleet that had a command ship.
--   2. NO AGGRO SCREEN. 0301:735 gave priority 100 to the command ship and 0 to everyone else. With
--      no flagged ship every row is 0, so the tick's tier filter (min(aggro_priority),
--      0299:840-844) admits the entire fleet and every enemy takes the nearest hull
--      (0299:845 order by dist asc, id asc limit 1) — they converge on one arbitrary ship and hold
--      there. The escorts-before-the-command-ship screen 0228 built simply does not run.
--   3. Measured live on the owner's 4-hull fleet: hulls at 15.7 / 21.6 / 26.0 / 27.5 from the enemy
--      stack — the last two outside a 25 gun — while player in-combat speed is the hull base
--      floored at 0.2 (0301:754, 0122:259) against an enemy 3 + 0.2·difficulty. Trailing hulls
--      spend seconds to tens of seconds being shot at with no shot of their own.
--
-- ── WHAT THIS MIGRATION DOES ─────────────────────────────────────────────────────────────────────
-- ONE authority for "who leads this formation", resolved once per encounter, before the member
-- loop, and read by BOTH the anchor spawn and the aggro screen (they were two independent reads of
-- the same concept, which is why they could ever disagree):
--
--   select gsm.main_ship_id into v_lead_ship_id
--     from public.group_sortie_live_members(pr.fleet_id) gsm
--     join main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
--    where msi.hp > 0
--    order by msi.is_command_ship desc, msi.max_hp desc, gsm.main_ship_id asc
--    limit 1;
--
--   • is_command_ship FIRST — a real command ship still wins, always. The derivation is a FALLBACK,
--     never an override; a fleet that has designated one gets byte-identical placement and
--     priorities to today. If two ships somehow carry the flag, the next two keys decide: the
--     greater max_hp, then the lower main_ship_id. Deterministic, never "whichever row came back".
--   • max_hp SECOND — the lead stands ON the enemy spawn point and is the hull the screen protects
--     until every escort is gone, so the toughest hull is the one that can hold that spot. max_hp
--     rather than current hp because capacity is a STABLE property of the hull (it is the same
--     denominator 0310's auto-exit already calls a fleet's capacity), so the lead does not shuffle
--     between fights as damage accumulates. hp would make the lead an artefact of the last fight.
--   • main_ship_id THIRD — a total order over uuids, so equal-capacity hulls always resolve the
--     same way. It is the tie-break this very loop (order by gsm.main_ship_id), the tick's
--     targeting and 0228's screen already use. Never random, never array order.
--   • LIVING HULLS ONLY (msi.hp > 0) — a wreck cannot anchor a formation (it never reaches the
--     hp>0 branch that assigns a position) and cannot screen anyone (the tick's targeting snapshot
--     reads alive_count > 0 only, so a dead row's priority is never seen). Electing one would
--     reproduce the very defect this fixes. THE ONE DELIBERATE DIFFERENCE FROM TODAY on a flagged
--     fleet: a DESTROYED command ship no longer takes priority 100 — it takes 0 like every other
--     wreck. That value was never read (dead rows are excluded from the snapshot before any
--     targeting decision), so nothing observable changes; it is stated here rather than hidden.
--   • Single-ship fleets: that one hull is the lead, at distance 0, priority 100 — the rule needs
--     no special case for them, and 0204 already calls a one-ship fleet valid ("that ship can be
--     its own command ship").
--
-- The flag is now read EXACTLY ONCE in this function — in the ORDER BY above. It is also dropped
-- from the member loop's projection, because after this slice nothing in the loop reads it and an
-- unread projection of the flag is a standing invitation to consult it per-member again.
--
-- ── WHAT THIS MIGRATION DOES NOT DO ──────────────────────────────────────────────────────────────
-- IT WRITES NO PLAYER DATA. No main_ship_instances row is touched; is_command_ship is not set on
-- anyone's ship, not backfilled, not defaulted. Designating a command ship stays the owner's act
-- through set_fleet_command_ship, which remains its sole writer. A migration that mutated 74 live
-- rows to satisfy a code assumption would be fixing the wrong thing — the builder is what was
-- wrong. No schema change, no game_config write, no grant change, no client change.
--
-- ── EVERY CONSUMER CHECKED (the never-ship-half-a-slice ledger) ──────────────────────────────────
--   combat_units.pos_x/pos_y      — written ONCE, by this builder (0301: "these positions are
--     FINAL"). Readers: the tick's movement/fire snapshot (0299:802-813) and the client's spatial
--     layer. Shape unchanged — one hull's coordinates differ, the column does not.
--   combat_units.aggro_priority   — written ONCE, by this builder. Readers: the spatial tier filter
--     (0299:840-844) and the aggregate/per-ship arm's lowest-aggro pick (0299:1093-1094). Both read
--     the VALUE and neither assumes who holds it, so both keep working — and both now get the
--     screen they were written for on flagless fleets, for the first time.
--   main_ship_instances.is_command_ship — still read here (the first ORDER BY key) and still
--     written only by set_fleet_command_ship. 0204's fleet_inactive_no_command gates on the legacy
--     senders are UNTOUCHED: this slice does not make the flag optional anywhere it is required, it
--     makes the BUILDER survive its absence on the paths that never required it.
--   group_sortie_live_members     — composed, not copied: the derivation reads the same 0308
--     liveness authority the member loop reads, so lead and roster can never disagree about
--     membership.
--   0310 auto-exit capacity       — reads sum(main_ship_instances.max_hp) over the encounter's
--     member units; untouched, and now shares max_hp as the notion of "how much hull a ship is".
--   0311 reposition               — translates every unit by an exact delta; the lead moves with
--     the formation like any other unit. Untouched.
--   client                        — reads pos_x/pos_y and weapons_json range only; no client code
--     reads aggro_priority or is_command_ship for the battle view. No client change is needed, so
--     none ships here.
--
-- ── BLAST RADIUS ON THE LIVE ~30-PLAYER GAME ─────────────────────────────────────────────────────
--   - CREATE OR REPLACE of ONE function, by text surgery over pg_get_functiondef: an atomic catalog
--     swap. No table is locked, no row is written, nothing is backfilled at deploy.
--   - FIGHTS ALREADY IN FLIGHT ARE FROZEN AT THEIR CREATION FORMATION AND STAY THAT WAY. pos_x/
--     pos_y and aggro_priority are written by this builder at encounter creation and never
--     recomputed afterwards (the tick MOVES units and 0311 TRANSLATES them, but neither re-anchors
--     nor re-stamps priority). So an encounter open at the moment of deploy keeps exactly the
--     formation and the priorities it was created with, including the broken flat-ring one — it is
--     not repaired mid-fight and it is not disturbed mid-fight. Later WAVES of such a fight spawn
--     at the encounter's stored engagement anchor, which this slice does not touch, so their
--     geometry is unchanged too. The new behaviour appears at the NEXT encounter creation: the next
--     ambush, the next hunt arrival.
--   - Fleets WITH a designated command ship: byte-identical placement and priorities.
--   - Fleets WITHOUT one (effectively all of them): one hull now spawns at the anchor with priority
--     100 and fires from tick 1; the remaining hulls take ring slots 0..n-2 instead of 0..n-1, so
--     their ring angles shift by one slot; enemies now screen onto those ring hulls instead of
--     converging on one arbitrary ship. Nothing about damage, hp, rewards or wave scaling changes.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed builder with the five hunks reverted (0301's text at :703, :720-724, :735,
-- :755-762 and 0308's roster projection at 0308:345). No state to unwind: this migration writes no
-- rows, no schema, no grants, no config.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
-- WHAT THESE PROVE, HONESTLY: that the emitted TEXT is what this migration intended — never that it
-- EXECUTES (plpgsql resolves nothing until first execution). Behaviour is proven by exactly one
-- layer: the disposable apply-proof driving the REAL ambush chain
-- (scripts/danger-combat-proof.sql, block DZCOMBAT_PASS_LEAD).
--   (a) the lead is derived exactly once, over live members, with the exact three-key order
--   (b) ONE authority: the flag is read exactly once (the ORDER BY) and v_is_lead assigned exactly
--       once; no per-member read of is_command_ship survives anywhere
--   (c) both consumers ask the lead: the aggro screen and the anchor spawn
--   (d) no player data is written by the function, and none was written by this migration
--   (e) every carried-through 0301/0308/0262 invariant survives the re-emission
--   (f) metadata parity: the builder changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
declare
  v_src text;
begin
  if to_regprocedure('public.combat_create_group_encounter(uuid,double precision,double precision)') is null then
    raise exception '0315 PRECONDITION FAIL: combat_create_group_encounter(uuid,double precision,double precision) is absent';
  end if;
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  -- the 0301 lineage (mandatory engagement point) …
  if position('p_engagement_x' in v_src) = 0 then
    raise exception '0315 PRECONDITION FAIL: the deployed builder does not carry the 0301 mandatory engagement point — the slices were taken against a different head';
  end if;
  -- … with 0308's two hunks already applied (the roster projection this slice edits is 0308's text)
  if position('group_sortie_live_members(pr.fleet_id)' in v_src) = 0
     or position('module_is_firing_weapon(t)' in v_src) = 0 then
    raise exception '0315 PRECONDITION FAIL: the deployed builder lacks the 0308 authorities — this is not the chain 0315 was generated against';
  end if;
  if position('v_lead_ship_id' in v_src) > 0 or position('v_is_lead' in v_src) > 0 then
    raise exception '0315 PRECONDITION FAIL: the deployed builder already carries the lead derivation — refusing to re-emit over an unknown edit';
  end if;
  -- the liveness authority the derivation composes must actually exist (0308).
  if to_regprocedure('public.group_sortie_live_members(uuid)') is null then
    raise exception '0315 PRECONDITION FAIL: public.group_sortie_live_members(uuid) is absent — the derivation would compose nothing';
  end if;
  -- the capacity column the second key sorts on (0043:54).
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name = 'max_hp' and data_type = 'integer') then
    raise exception '0315 PRECONDITION FAIL: main_ship_instances.max_hp is not the integer capacity column (0043) — the lead rule has no second key';
  end if;
end $pre$;

-- ── 1. CAPTURE BEFORE THE REWRITE (parity check f, and the no-player-write check d) ──────────────
create temp table _0315_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0315_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';

create temp table _0315_ships (ships bigint, commanders bigint) on commit drop;
insert into _0315_ships
select count(*), count(*) filter (where is_command_ship) from public.main_ship_instances;

-- ── 2. REWRITE THE FIVE HUNKS (located by exact deployed text, never retyped) ────────────────────
do $rewrite$
declare
  r record;
  v_oid oid;
  v_src text;
  v_new text;
  v_n integer;
  v_done integer := 0;
begin
  for r in
    select * from (values
${rows}
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0315 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0315 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0315 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0315 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 5 then
    raise exception '0315 REWRITE FAIL: rewrote % site(s), expected 5', v_done;
  end if;
  raise notice '0315: every fleet entering combat now has a lead — anchored at the engagement point and screened';
end $rewrite$;

-- ── 3. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) the lead is derived exactly once, over LIVE members, with the exact three-key order
do $a$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  v_n := (length(v_code) - length(replace(v_code, 'select gsm.main_ship_id into v_lead_ship_id', '')))
         / length('select gsm.main_ship_id into v_lead_ship_id');
  if v_n <> 1 then
    raise exception '0315 ASSERT (a) FAIL: % lead derivation(s) (want exactly 1 — one authority for who leads)', v_n;
  end if;
  if position('order by msi.is_command_ship desc, msi.max_hp desc, gsm.main_ship_id asc' in v_code) = 0 then
    raise exception '0315 ASSERT (a) FAIL: the three-key lead order is gone — a real command ship must win, then capacity, then a stable uuid tie-break';
  end if;
  if position('from public.group_sortie_live_members(pr.fleet_id) gsm' in v_code) = 0 then
    raise exception '0315 ASSERT (a) FAIL: the derivation does not read the 0308 liveness authority — lead and roster could disagree about membership';
  end if;
  if position('where msi.hp > 0' in v_code) = 0 then
    raise exception '0315 ASSERT (a) FAIL: the derivation can elect a wreck — a hull with no position anchors nothing and screens nobody';
  end if;
  if position('limit 1' in v_code) = 0 then
    raise exception '0315 ASSERT (a) FAIL: the derivation is unbounded — exactly one lead, or the rule is not a rule';
  end if;
end $a$;

-- (b) ONE authority: the flag is read exactly once, v_is_lead assigned exactly once, and no
--     per-member read of is_command_ship survives
do $b$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  v_n := (length(v_code) - length(replace(v_code, 'is_command_ship', ''))) / length('is_command_ship');
  if v_n <> 1 then
    raise exception '0315 ASSERT (b) FAIL: the builder reads is_command_ship % time(s) (want exactly 1 — the lead ORDER BY, and nowhere else)', v_n;
  end if;
  if position('m.is_command_ship' in v_code) > 0 then
    raise exception '0315 ASSERT (b) FAIL: a per-member read of the flag survives — that is the assumption this slice removes';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'v_is_lead := ', ''))) / length('v_is_lead := ');
  if v_n <> 1 then
    raise exception '0315 ASSERT (b) FAIL: v_is_lead is assigned % time(s) (want exactly 1 — one decision per member)', v_n;
  end if;
  if position('v_is_lead := m.main_ship_id is not distinct from v_lead_ship_id;' in v_code) = 0 then
    raise exception '0315 ASSERT (b) FAIL: the lead test is not the NULL-safe one — a fleet with no living hull would compare against NULL';
  end if;
end $b$;

-- (c) both consumers ask the lead: the aggro screen and the anchor spawn
do $c$
declare v_code text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('v_aggro_priority := case when v_is_lead then 100 else 0 end;' in v_code) = 0 then
    raise exception '0315 ASSERT (c) FAIL: the aggro screen does not read the lead — priority 100 would go to nobody again';
  end if;
  if position('if v_is_lead then' in v_code) = 0 then
    raise exception '0315 ASSERT (c) FAIL: the anchor spawn does not read the lead — every hull would take a ring slot again';
  end if;
  -- the spawn branch's two arms, unchanged apart from the condition (0301's ring formula intact).
  if position('v_pos_x := v_loc_x + v_ring_radius * cos(2 * pi() * v_escort_idx / 8);' in v_code) = 0
     or position('v_escort_idx := v_escort_idx + 1;' in v_code) = 0 then
    raise exception '0315 ASSERT (c) FAIL: the 0234 escort ring formula changed — this slice moves ONE hull to the anchor, it does not retune the formation';
  end if;
end $c$;

-- (d) no player data is written — not by the function, and not by this migration
do $d$
declare v_code text; b record; v_ships bigint; v_cmd bigint;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('update main_ship_instances' in v_code) > 0
     or position('update public.main_ship_instances' in v_code) > 0 then
    raise exception '0315 ASSERT (d) FAIL: the builder writes main_ship_instances — designating a command ship is the owner''s act, through set_fleet_command_ship alone';
  end if;
  select * into b from _0315_ships;
  select count(*), count(*) filter (where is_command_ship) into v_ships, v_cmd
    from public.main_ship_instances;
  if v_ships is distinct from b.ships or v_cmd is distinct from b.commanders then
    raise exception '0315 ASSERT (d) FAIL: main_ship_instances moved across this migration (% ships / % commanders -> % / %) — 0315 must write no player data',
      b.ships, b.commanders, v_ships, v_cmd;
  end if;
end $d$;

-- (e) every carried-through 0301/0308/0262 invariant survives the re-emission
do $e$
declare v_code text; v_n integer; v_tok text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  -- 0308: the roster is live membership, and a rig is not a gun.
  if position('from group_sortie_members' in v_code) > 0
     or position('join group_sortie_members' in v_code) > 0
     or position('from public.group_sortie_members' in v_code) > 0 then
    raise exception '0315 ASSERT (e) FAIL: the raw roster read is back (0308 reverted)';
  end if;
  if position('t.range is not null' in v_code) > 0 then
    raise exception '0315 ASSERT (e) FAIL: "has a range" is treated as "is a weapon" again (0308 reverted)';
  end if;
  -- 0262: the empty-array fallback weapon.
  if position('jsonb_array_length(v_weapons_json) = 0' in v_code) = 0
     or position('basic_player_weapon' in v_code) = 0
     or position('combat_player_fallback_weapon_power_from_attack' in v_code) = 0 then
    raise exception '0315 ASSERT (e) FAIL: the 0262 fallback guard lost a piece';
  end if;
  -- 0301: the point is the caller's, written exactly once, and never re-derived here.
  if position('from locations' in v_code) > 0 then
    raise exception '0315 ASSERT (e) FAIL: the builder reads locations again — 0301 deleted that derivation and this slice must not restore it';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'insert into combat_encounters', ''))) / length('insert into combat_encounters');
  if v_n <> 1 then
    raise exception '0315 ASSERT (e) FAIL: % writes of combat_encounters (want the head''s 1 — the only write of engagement_x/y in the database)', v_n;
  end if;
  -- 'aggro_priority,' is deliberately the trailing-COMMA form: the combat_units column list is the
  -- only place the bare identifier is followed by a comma (the roster key and the jsonb cast both
  -- put a quote there), and the 'aggro_priority)' form an earlier draft used lives ONLY inside a
  -- comment that this very probe strips — a pin that could never have matched.
  foreach v_tok in array array[
      'v_eng_x := p_engagement_x;',
      'v_ring_radius := coalesce(public.cfg_num(''spatial_formation_ring_radius''), 30);',
      'v_spatial_enabled boolean := public.cfg_bool(''spatial_combat_enabled'');',
      'order by gsm.main_ship_id',
      'aggro_priority,',
      '''wave_spawned'', ''pirate'', ''player'''
    ] loop
    if position(v_tok in v_code) = 0 then
      raise exception '0315 ASSERT (e) FAIL: the builder lost a pinned head guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
  -- no RNG is introduced: the lead is DERIVED, never rolled.
  v_n := (length(v_code) - length(replace(v_code, 'random(', ''))) / length('random(');
  if v_n <> 0 then
    raise exception '0315 ASSERT (e) FAIL: the builder carries % random( call(s) — the lead must be deterministic (0041)', v_n;
  end if;
end $e$;

-- (f) metadata parity: the builder changed body and NOTHING else
do $f$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0315_before loop
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
      raise exception '0315 ASSERT (f) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0315 ASSERT (f) FAIL: public.% body is byte-identical — the hunks did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0315 ASSERT (f) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0315 SELF-ASSERT PASS: one authority for who leads a formation (a real command ship first, then the greatest max_hp, then the lowest main_ship_id, over living hulls only), read by both the anchor spawn and the aggro screen; no player data written';
end $f$;

commit;
`;

if (sql.includes('\r')) {
  throw new Error('generated 0315 carries a CR — the rewrite hunks would never match the deployed body');
}

const check = process.argv.includes('--check');
if (check) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8');
  } catch {
    console.error('0315 CHECK FAIL: migration file is missing — run the generator');
    process.exit(1);
  }
  if (onDisk.replace(/\r\n/g, '\n') !== sql) {
    console.error('0315 CHECK FAIL: the migration on disk is not what the slices generate.');
    console.error('Either the 0301/0308 source drifted or the file was hand-edited. Re-run the generator.');
    process.exit(1);
  }
  console.log('0315 CHECK OK: migration matches the slices taken from 0301/0308.');
} else {
  writeFileSync(OUT, sql);
  console.log(`0315 written: ${OUT}`);
  console.log(`  ${HUNKS.length} hunks sliced from 0301/0308 (nothing retyped; new text constructed from the slices)`);
}
