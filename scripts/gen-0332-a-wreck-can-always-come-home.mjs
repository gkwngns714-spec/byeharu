#!/usr/bin/env node
// gen-0332-a-wreck-can-always-come-home.mjs — emit (or --check) migration 0332.
//
// WHY A GENERATOR: 0332 rewrites ONE hunk inside the live process_combat_ticks body. The true
// TEXTUAL head of the tick is still 0299:308 — verified below, programmatically: no migration after
// 0299 carries a `create or replace function … process_combat_ticks`. THREE later migrations DID
// edit the body, all by replace-surgery over pg_get_functiondef rather than by re-creating it:
//   0310 — ONE hunk sliced from 0299:1026-1030 (the auto-exit arm),
//   0314 — FIVE hunks sliced from 0299:323 / :431 / :897-901 / :921-928 / :946-947, and
//   0317 — ONE hunk sliced from 0299:822-826 (the actor-liveness guard).
// Every one of those sites is statically DISJOINT from the hunk below (0299:622-624, the settle
// arm's member-repatriation loop), so 0299's text is still the correct slice source for this
// migration — and the deployed prosrc was checked to contain that slice EXACTLY ONCE before this
// file was written. The 0303 lesson — "never retype a live function body" — holds: `old_t` is
// SLICED verbatim out of 0299 and `new_t` is CONSTRUCTED from that slice by exactly-once string
// edits, so every deployed word inside the replaced hunk is a byte-copy. The migration then proves
// the slice is still what is deployed (occurs EXACTLY once in pg_get_functiondef), replaces it, and
// proves the length moved by exactly the hunk delta.
//
//   node scripts/gen-0332-a-wreck-can-always-come-home.mjs          # write the migration
//   node scripts/gen-0332-a-wreck-can-always-come-home.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000332_a_wreck_can_always_come_home.sql');
const SELF = '20260618000332';

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECKS: establish that 0299 really is the deployed text this hunk is cut from. ──────────
// (1) No later TEXTUAL re-create. Any `create or replace function … process_combat_ticks` after
//     0299 would make the slice stale. 0301 names the create in a comment, deliberately, so `--`
//     line comments are stripped before the test (the 0314/0317 idiom, same reason).
// (2) No UNKNOWN later REPLACE-REWRITER. A migration after 0299 that carries this function name in
//     a hunk row — the house `(idx, 'fname',` shape used by 0310, 0314 and 0317 — has surgically
//     edited the body, and a NEW slice must not be cut without reading it. Those three are exempt
//     BY NAME rather than by widening the window (the gen-0315/gen-0317 idiom): their sites are
//     disjoint from this one, checked by hand at the line numbers listed in the header above, and
//     naming them keeps the gate live for 0333 and everything after it. A migration that merely
//     NAMES the function in a read-only probe or a comment is not drift and must not fail this gate.
{
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const files = readdirSync(MIGDIR)
    .filter((f) => f.endsWith('.sql') && version(f) !== SELF);
  const stripped = new Map(
    files.map((f) => [f, readFileSync(MIG(f), 'utf8').replace(/--[^\n]*/g, '')]));

  const reCreate = /create\s+or\s+replace\s+function\s+(?:public\.)?process_combat_ticks\s*\(/i;
  const newerHeads = files.filter((f) => version(f) > '20260618000299' && reCreate.test(stripped.get(f)));
  if (newerHeads.length > 0) {
    throw new Error(
      `process_combat_ticks was textually re-created AFTER 0299 by: ${newerHeads.join(', ')} — ` +
      're-point the slice at the new head before generating.');
  }

  // 0337 JOINS, by name rather than by widening the window. It makes a reposition a MOVE instead of
  // a teleport; its four tick hunks are the declare block, the v_is_spatial line, the per-unit
  // position write and the foot of the spatial arm — all in the SPATIAL branch, while this file's
  // slice is the settle arm's member-repatriation loop in branch (B), hundreds of lines above it.
  // Statically disjoint, checked site by site.
  // 0338 JOINS THE EXEMPTION — by name, never by widening the window. It rewrites exactly TWO lines:
  // the PHASE argument handed to combat_formation_point at each of the two wave-spawn arms, so an
  // enemy wave arrives on the bearing to the zone's own settlement instead of on a bare constant.
  // Those two call sites did not exist before 0336 CREATED them, so no slice this file takes from a
  // pre-0336 head can overlap them: the disjointness is structural, not a judgement. 0338 moves no
  // radius, no knob, no guard and no branch. Naming it here keeps this gate live for 0339 and after.
  const KNOWN_LATER_REWRITERS = new Set(['20260618000310', '20260618000314', '20260618000317', '20260618000336',
                                         '20260618000337', '20260618000338']);
  const reHunkRow = /\(\s*\d+\s*,\s*'process_combat_ticks'\s*,/;
  const newerSurgery = files.filter((f) => version(f) > '20260618000299'
    && !KNOWN_LATER_REWRITERS.has(version(f))
    && reHunkRow.test(stripped.get(f)));
  if (newerSurgery.length > 0) {
    throw new Error(
      `process_combat_ticks was rewritten by hunk surgery AFTER 0299 by: ${newerSurgery.join(', ')} — ` +
      'read that migration and re-point this slice; do not regenerate blindly.');
  }
}

const F299 = load('20260618000299_combat_card_reports_true_power.sql');

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

/** Replace `find` with `repl` in `src`, asserting it occurs EXACTLY once (never a blind replace). */
function editOnce(src, find, repl, what) {
  const n = (src.length - src.split(find).join('').length) / find.length;
  if (n !== 1) {
    throw new Error(`${what}: expected exactly 1 occurrence of ${JSON.stringify(find)}, found ${n}`);
  }
  return src.split(find).join(repl);
}

// ── THE ONE HUNK ─────────────────────────────────────────────────────────────────────────────────
// The settle arm's member-repatriation loop, sliced whole. Two exactly-once edits turn it from a
// FILTER (which silently drops the wrecks) into a BRANCH (which gives them their terminal write):
//   1. the loop stops filtering  — `and alive_count > 0 loop` becomes ` loop`
//   2. the body gains the else   — the surviving members' line is wrapped in the same predicate,
//                                  and the dead members reach mainship_mark_combat_destroyed.
// The `perform mainship_mark_legacy_in_flight(...)` line and the loop's SELECT are byte-copies.
const H1_OLD = slice(F299, '0299', 622, 624,
  'for cu in select * from combat_units where encounter_id = e.id',
  'end loop;');

const H1_NEW = editOnce(
  editOnce(H1_OLD,
    ' and alive_count > 0 loop',
    ' loop',
    'hunk 1 edit 1 (stop filtering the settle loop)'),
  `        perform mainship_mark_legacy_in_flight(cu.main_ship_id, 'returning');`,
  `        -- 0332 THE SETTLE ARM RECONCILES. Until this branch the loop FILTERED on liveness and
        -- the complement was dropped on the floor: a member whose hull reached 0 while its
        -- fleetmates survived got its hp synced (mainship_sync_combat_hp, 0167:134-145 — hp ONLY,
        -- never status) and then NOTHING. Its instance row kept status='home' with hp=0, and every
        -- recovery verb refuses that pair: repair_main_ship and mainship_emergency_tow both gate on
        -- status='destroyed' (0297 §2/§3), so the wreck could be neither repaired nor towed. The
        -- defeat branch has always reconciled its members; this is the OTHER exit, and it never did.
        -- ONE AUTHORITY, NOT TWO: the terminal write is mainship_mark_combat_destroyed — the same
        -- leaf the defeat branch composes three lines up, unchanged, and the only writer that moves
        -- a ship to status='destroyed' from combat. No new leaf, no new column, no new predicate.
        -- ONE SPELLING OF LIVENESS: the filter did not go away, it became the branch. The predicate
        -- is still combat_units.alive_count > 0 — 0317's ONE authority for "is this unit alive right
        -- now", asked here exactly as it was asked before. Deliberately NOT written as a second,
        -- NEGATED pass over the same column: that would be a second spelling of the same question,
        -- which 0317 assert (d) forbids. The site count is therefore UNCHANGED at 7 — one moves out
        -- of the loop header and into the branch; none is added.
        -- WHY NOT hp: 0312:16-30 proves hp=0 on a LIVING ship is real — the tick keeps a unit alive
        -- on any fractional hull while the instance row rounds to 0 — so an hp predicate would wreck
        -- a merely damaged ship. This branch reads the unit's liveness, never the hull number.
        -- MID-FIGHT IS UNTOUCHED: this runs only where the encounter has ALREADY ended (the status
        -- write and report_create are above). While a fight is running hp and status may still
        -- disagree, exactly as 0312 requires; what can no longer happen is that they disagree AFTER
        -- the fight is over.
        if cu.alive_count > 0 then
          perform mainship_mark_legacy_in_flight(cu.main_ship_id, 'returning');
        else
          perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end if;`,
  'hunk 1 edit 2 (branch the loop body)');

const HUNKS = [
  [1, 'process_combat_ticks', H1_OLD, H1_NEW],
];

// Dollar-quote tags must not collide with anything inside the hunk text.
const rows = HUNKS.map(([idx, fname, oldT, newT]) => {
  const o = `$h${idx}o$`;
  const n = `$h${idx}n$`;
  for (const [tag, body] of [[o, oldT], [n, newT]]) {
    if (body.includes(tag)) throw new Error(`dollar-quote tag ${tag} collides with hunk ${idx}`);
    if (body.includes('$')) throw new Error(`hunk ${idx} contains '$' — dollar-quoting is unsafe`);
    // the elite-stat proof greps the RAW tick body, comments included, on every chain.
    if (/elite/i.test(body)) throw new Error(`hunk ${idx} contains 'elite' — the elite-stat proof greps the RAW tick body`);
    if (/[^_]random\(/.test(body)) throw new Error(`hunk ${idx} adds a random( call — the tick's RNG-site count is pinned`);
    if (!body.trim()) throw new Error(`hunk ${idx} sliced empty — a line range is wrong`);
  }
  // ONE SPELLING: the new text must not introduce a second way to ask "is this unit alive" —
  // 0317 assert (d) forbids exactly these, and this catches it before the migration is written.
  for (const bad of ['alive_count = 0', 'alive_count <= 0', 'is_destroyed']) {
    if (newT.includes(bad)) throw new Error(`hunk ${idx} introduces a second liveness spelling (${bad}) — one authority, one predicate`);
  }
  // PLPGSQL VARIABLE CAPTURE (the 0310 rev.2 lesson, kept for the next author): process_combat_ticks
  // declares record variables cu / e / pr / loc and a uuid v_mv, and plpgsql resolves table-alias-
  // qualified references against variables too — an alias shadowing one of them raises "ambiguous"
  // at FIRST EXECUTION only. Applied to the NEW text only — the old text is the deployed head.
  {
    const m = newT.match(/\b(?:from|join)\s+[a-z_][a-z0-9_]*\s+(cu|e|pr|loc|mv)\b/i);
    if (m) throw new Error(`hunk ${idx} aliases a table as '${m[1]}' — that name is a plpgsql record variable in process_combat_ticks and the reference would be ambiguous at first execution`);
  }
  return `    (${idx}, '${fname}',\n     ${o}${oldT}${o},\n     ${n}${newT}${n})`;
}).join(',\n');

// Comment-stripping idiom proven by 0305/0306/0308/0310/0314/0317 against this database's settings.
const STRIP = `regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')`;

// THE BACKFILL PREDICATE — written once here and reused by the write and by its own post-assert, so
// the thing that is fixed and the thing that is proven fixed can never drift apart.
const SPLIT_ROWS = `select msi.main_ship_id
      from public.main_ship_instances msi
     where msi.hp <= 0
       and msi.status <> 'destroyed'
       and not exists (
             select 1
               from public.combat_units cu
               join public.combat_encounters ce on ce.id = cu.encounter_id
              where cu.main_ship_id = msi.main_ship_id
                and ce.status in ('active', 'retreating'))`;

const sql = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0332 — A WRECK CAN ALWAYS COME HOME
--        the settle arm gives a dead member its terminal write, so hp and status cannot end a
--        fight disagreeing — and the two ships that already ended one that way are reconciled
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- THE OWNER'S BUG REPORT, VERBATIM: "hull integrity ships right now have nothing to do, i don't
-- think it is fixable either." They were right. It was not fixable.
--
-- ── THE DEFECT, READ OFF THE DEPLOYED BODY AND CONFIRMED AGAINST PRODUCTION ──────────────────────
-- A fight ends through exactly one of two arms of process_combat_ticks:
--   (A) DEFEAT — every player unit is gone. fleet_destroy, then mainship_mark_combat_destroyed over
--       every member row (0299:516-518, and the two wave-arm copies at :1017 and :1196). Members
--       are RECONCILED: status='destroyed', hp=0, together, in one statement.
--   (B) ESCAPED / COMPLETED — the retreat delay elapsed or the presence window was forced. The
--       member loop (0299:622-624) is FILTERED \`and alive_count > 0\` and marks the survivors
--       'returning'. The complement — the members that died while their fleetmates lived — is
--       DROPPED ON THE FLOOR. Nothing in this arm has ever called the terminal leaf.
-- So a ship that died in a fight the fleet SURVIVED never became 'destroyed'. Its hull number was
-- written, because mainship_sync_combat_hp (0167:134-145) writes hp ONLY and never status; its
-- lifecycle was not. The row ends the fight at hp=0, status='home'.
--
-- THAT PAIR IS ACCEPTED BY NO RECOVERY VERB:
--   * repair_main_ship raises 'ship is not disabled (status home)' — it gates on status='destroyed'
--     (0297 §2, the 0231 head's guard, untouched by this file);
--   * mainship_emergency_tow answers 'ship_not_disabled' for the same reason (0297 §3:288-290);
--   * get_my_disabled_ships (0297 §4) selects \`status = 'destroyed'\`, so the wreck is not even
--     LISTED — the client cannot offer a button it never hears about;
--   * send_ship_group_hunt refuses the whole fleet (member_not_ready — its arms refuse any member
--     at hp<=0);
--   * and 0312's mover guard reads status, so the fleet is NOT dead and the 0-hp hull can still be
--     flown around the map.
-- Unrepairable, untowable, invisible to the recovery UI, unable to hunt, still able to sail. That is
-- "nothing to do", exactly as reported.
--
-- WHY IT IS COMMON NOW RATHER THAN RARE: 0310 gave every fleet an HP auto-exit, on by default at
-- 30%. Its whole purpose is to END FIGHTS BY RETREATING instead of by dying — which is to say, it
-- routes fights that used to finish in arm (A) into arm (B), the arm that does not reconcile. The
-- safety feature and the unreconciled arm compose into a wreck the player cannot recover.
--
-- PRODUCTION EVIDENCE (read-only, 2026-08-03, before this file was written). Encounter
-- 178308d7-513c-4482-ad8e-36d67bfbef5b ended 'escaped'. Its four player rows:
--     Sparrow      alive_count 1   hp_current  88.7
--     Sparrow III  alive_count 1   hp_current 500
--     Sparrow IV   alive_count 0   hp_current   0
--     Sparrow V    alive_count 0   hp_current   0
-- Two survivors, so arm (A) could not fire; the fleet auto-exited, so arm (B) did. Sparrow IV and
-- Sparrow V are, today, hp 0 / max_hp 500 / status 'home' / berth NULL — the exact stranded pair.
-- Game-wide the split existed on exactly those two rows, on one player.
--
-- ── THE FIX, AND WHY IT MAKES THE STATE UNREACHABLE RATHER THAN MERELY DETECTED ──────────────────
-- ONE hunk: arm (B)'s loop stops FILTERING on liveness and starts BRANCHING on it. Survivors take
-- the line they always took; the dead reach mainship_mark_combat_destroyed — the same leaf arm (A)
-- composes, unchanged.
--
-- That closes the hole COMPLETELY, and the reason is a closed census of writers rather than an
-- argument. \`main_ship_instances.hp\` has exactly five writers in the deployed database:
--     mainship_sync_combat_hp        hp only, can LOWER to 0     ← the only one that can split the pair
--     mainship_mark_combat_destroyed hp=0 AND status='destroyed' in one statement
--     repair_main_ship               hp=max_hp AND status='home' in one statement
--     repair_ship_hull_at_port       hp only, RAISES (a paid repair)
--     soul_roll_traits_for_ship      hp only, greatest(hp, …) — can never lower
-- Only mainship_sync_combat_hp can produce hp<=0 without a status, and it is called from exactly one
-- place: inside process_combat_ticks. Every encounter it can touch terminates through arm (A) or arm
-- (B). After this migration BOTH arms reconcile, so the split cannot outlive the fight that made it.
--
-- ── THE THREE THINGS THIS DELIBERATELY DOES NOT DO ───────────────────────────────────────────────
--   1. NOT A CHECK CONSTRAINT. \`check (hp > 0 or status = 'destroyed')\` looks like the airtight
--      answer and is the one option that would BREAK THE LIVE GAME. 0312:16-30 establishes, from
--      source, that hp=0 on a LIVING ship is a real in-combat state: the tick keeps a unit alive on
--      any fractional hull (alive_count = ceil(hp/ship_hp)) while mainship_sync_combat_hp rounds the
--      instance row to 0. A CHECK would make that legal state illegal and abort the combat tick for
--      every player in the fight. The bad state is not "hp and status disagree" — it is "hp and
--      status STILL disagree once the fight is over", and a table constraint cannot say "once".
--      The writer can, because the writer is the thing that knows the fight ended.
--   2. NOT AN hp-SHAPED RECOVERY GUARD. Re-pointing repair/tow at hp<=0 instead of status is the
--      "damaged-is-dead" mistake 0312's header exists to forbid, and it would give the game a SECOND
--      predicate for out-of-action alongside the one 0312 established at the fleet level. This file
--      changes no recovery guard at all — self-assert (f) pins that.
--   3. NOT A RECONCILER, CRON OR SWEEPER. A periodic "find split rows and fix them" job would be a
--      second authority for a ship's terminal state, running behind the tick's back, and the disease
--      the NO-SPAGHETTI law names. The one writer that creates the state is the one that closes it.
--
-- ── SECTION 2: THE BACKFILL — the two ships that are already stranded ────────────────────────────
-- The hunk fixes the future; it cannot reach a fight that ended yesterday. Section 2 reconciles the
-- rows the old arm (B) left behind, through THE SAME LEAF the fixed arm now uses — never a
-- hand-written UPDATE, so there is still exactly one writer of this transition.
--
-- THE GUARD, and the one hazard it exists for:
--     hp <= 0  AND  status <> 'destroyed'  AND  the ship is in NO 'active'/'retreating' encounter
-- The third clause is load-bearing and is the whole blast-radius story. A ship in a RUNNING fight is
-- ALLOWED to read hp 0 while alive (point 1 above). Without that clause this migration would mark a
-- living, fighting hull as destroyed the instant it deployed — turning a fix into exactly the defect
-- 0312 forbids. With it, a mid-fight ship is left entirely alone and its own settle reconciles it
-- correctly minutes later, through the code this same migration installs.
--
-- WHAT THE ROWS BECOME — precisely, and it is a small write:
--   * status 'home' -> 'destroyed'; hp 0 -> 0 (the leaf writes hp=0 and they are already 0);
--     updated_at moves. NOTHING ELSE. max_hp is NOT touched (they stay 500, the value the owner
--     paid for), group_id is NOT touched, berth_location_id is NOT touched, no row is deleted, no
--     cargo/module/wallet/fleet/movement row is read or written.
--   * On production that is EXACTLY TWO ROWS: Sparrow IV (f1d2d27b…) and Sparrow V (41c804a6…),
--     both owned by 218500ff-9cf6-408f-b3cd-5e92b4562168, both verified read-only as being in no
--     live encounter. Every other ship in the game is outside the predicate.
--   * WHAT THE OWNER CAN THEN DO, which is the point: the wrecks appear in get_my_disabled_ships,
--     so the recovery UI 0297 already shipped lights up. Neither resolves a fleet or a berth today,
--     so both answer at_port=false -> "Tow to port" berths them at the nearest active port ->
--     Repair restores hp to max_hp 500 and status to 'home'. Two taps each, no cost, no cooldown.
--     They go from unrecoverable to fully recovered through the game's own verbs.
--
-- ── WHAT IS EXPLICITLY LEFT ALONE ────────────────────────────────────────────────────────────────
--   * THE 3 SHIPS ALREADY AT status='destroyed' WITH A BERTH (three different players). They fail
--     the backfill's \`status <> 'destroyed'\` clause, so not one of them is read for update. Their
--     repair path is untouched: repair_main_ship, mainship_emergency_tow, mainship_port_of_ship and
--     get_my_disabled_ships are not re-created by this file. Self-assert (f) pins that.
--   * THE 4 HEALTHY BERTHLESS SHIPS. A NULL berth is NOT a second defect — it is the 0216 XOR
--     working: \`(group_id is null) = (berth_location_id is not null)\`, so every ship that is IN A
--     FLEET has a NULL berth by construction. All four were verified read-only to resolve a fleet
--     AND a port through mainship_port_of_ship (three at Haven, one at Slagworks). They are simply
--     ships that are out with their fleets, and they fail the hp<=0 clause anyway.
--   * MID-FIGHT SHIPS, by the guard's third clause, as above.
--
-- ── BLAST RADIUS ON THE LIVE GAME ────────────────────────────────────────────────────────────────
--   * DDL is one CREATE OR REPLACE of one function — an ATOMIC CATALOG SWAP. No table lock, no
--     schema change, no grant change, no game_config write, no flag. The tick body is read fresh on
--     every invocation, so the very next settle of every running fight runs the new arm.
--   * The ONLY behavioural change is at the moment an encounter ends through the escape/completed
--     arm, and ONLY for member rows at alive_count=0 — rows that until now received no write at
--     all. Survivors take the identical line. Arm (A) is untouched. The combat step, targeting,
--     damage, waves, rewards, cargo, the return leg and the auto-exit are all untouched.
--   * A fleet that ends a fight with some members wrecked will now correctly answer 0312's
--     no_living_ships only when EVERY member is wrecked — which is 0312 working as written, on
--     data that is finally honest. A fleet with one survivor still moves.
--   * Data written at deploy time: the backfill's two rows. Nothing else.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed tick with the hunk reverted (0299's text at :622-624). The backfill is not
-- automatically reversible and should not be: the rows it writes are the state the game's own rules
-- always implied. To undo it by hand, set status='home' on the two main_ship_id values named above.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
-- WHAT THESE PROVE, HONESTLY: that the emitted TEXT is what this migration intended, and that the
-- backfill's own post-condition holds. They do NOT prove the tick EXECUTES correctly (plpgsql
-- resolves nothing until first execution). Behaviour is proven by exactly one layer: the disposable
-- apply-proof driving the REAL tick (danger-combat-proof's WRECKHOME block).
--   (a) the settle arm no longer filters, and carries BOTH arms exactly once
--   (b) the reconciling write composes the ONE terminal leaf, and only inside the settle arm
--   (c) ONE spelling of liveness survives: the predicate count is unchanged and no second spelling
--   (d) arm (A) and the hp writer are untouched (this slice adds an exit, it does not move death)
--   (e) the backfill left NO split row outside a live fight, and touched nothing but status
--   (f) the recovery surface is untouched: repair/tow/port/list still gate on status='destroyed'
--   (g) every carried-through 0299/0310/0314/0317 invariant survives the re-emission
--   (h) metadata parity: the tick changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
declare
  v_tick text;
begin
  if to_regprocedure('public.process_combat_ticks()') is null then
    raise exception '0332 PRECONDITION FAIL: process_combat_ticks is absent';
  end if;
  select prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  -- the base must be the post-0310 body (the auto-exit arm — the thing that makes arm (B) common):
  if position('presence_request_leave(e.presence_id)' in v_tick) = 0 then
    raise exception '0332 PRECONDITION FAIL: the deployed tick lacks the 0310 auto-exit arm — this is not the chain 0332 was generated against';
  end if;
  -- …the post-0314 body (the per-hit roll):
  if position('v_hit_roll' in v_tick) = 0 then
    raise exception '0332 PRECONDITION FAIL: the deployed tick lacks the 0314 per-hit roll — this is not the chain 0332 was generated against';
  end if;
  -- …and the post-0317 body (the actor-liveness guard):
  if position('perform 1 from combat_units where id = v_ur.id and alive_count > 0;' in v_tick) = 0 then
    raise exception '0332 PRECONDITION FAIL: the deployed tick lacks the 0317 actor-liveness guard — this is not the chain 0332 was generated against';
  end if;
  if position('public.combat_encounter_side_power(e.id, ''player'')' in v_tick) = 0 then
    raise exception '0332 PRECONDITION FAIL: the deployed tick is not the 0299 lineage (the snapshot-power authority is absent)';
  end if;
  -- the terminal leaf this slice composes must exist, or the new arm would raise at first execution.
  if to_regprocedure('public.mainship_mark_combat_destroyed(uuid)') is null then
    raise exception '0332 PRECONDITION FAIL: mainship_mark_combat_destroyed(uuid) is absent — the reconciling arm has no leaf to compose';
  end if;
  -- the defect must still be there: the settle arm still filters the dead out and never marks them.
  if position('for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null and alive_count > 0 loop' in v_tick) = 0 then
    raise exception '0332 PRECONDITION FAIL: the deployed settle arm is not the filtered 0299 loop — refusing to re-emit over an unknown edit';
  end if;
end $pre$;

-- ── 1. CAPTURE METADATA BEFORE THE REWRITE (for parity check h) ──────────────────────────────────
create temp table _0332_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0332_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'process_combat_ticks';

-- ── 2. REWRITE THE ONE HUNK (located by exact deployed text, never retyped) ──────────────────────
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
      raise exception '0332 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0332 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0332 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0332 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 1 then
    raise exception '0332 REWRITE FAIL: rewrote % site(s), expected 1', v_done;
  end if;
  raise notice '0332: the settle arm now gives a dead member its terminal write — hp and status cannot end a fight disagreeing';
end $rewrite$;

-- ── 2b. THE BACKFILL — reconcile the rows the OLD settle arm already stranded ────────────────────
-- Through the SAME leaf the fixed arm composes, one ship at a time, so this migration introduces no
-- second writer of the destroyed transition. The guard's third clause (no live encounter) is what
-- keeps a ship that is legitimately at hp 0 IN A RUNNING FIGHT out of this — see the header.
do $backfill$
declare
  s record;
  v_n integer := 0;
begin
  for s in
    ${SPLIT_ROWS}
     order by msi.main_ship_id
  loop
    perform public.mainship_mark_combat_destroyed(s.main_ship_id);
    v_n := v_n + 1;
  end loop;
  raise notice '0332 BACKFILL: reconciled % ship(s) that ended a fight at hp<=0 without a status (status -> destroyed; max_hp, group_id, berth_location_id and every other column untouched)', v_n;
end $backfill$;

-- ── 3. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) the settle arm no longer filters, and carries BOTH arms exactly once
do $a$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null and alive_count > 0 loop' in v_code) > 0 then
    raise exception '0332 ASSERT (a) FAIL: the settle arm still FILTERS the dead members out — the complement is still dropped on the floor';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop', '')))
         / length('for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop');
  if v_n <> 4 then
    raise exception '0332 ASSERT (a) FAIL: % unfiltered member loop(s) (want 4: arm (A) and its two wave-arm copies, which have always been unfiltered, plus the settle arm now joining them)', v_n;
  end if;
  if position('if cu.alive_count > 0 then
          perform mainship_mark_legacy_in_flight(cu.main_ship_id, ''returning'');
        else
          perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end if;' in v_code) = 0 then
    raise exception '0332 ASSERT (a) FAIL: the settle arm does not branch survivors -> returning / dead -> destroyed — a loop that reads liveness and acts on only one side is the defect';
  end if;
end $a$;

-- (b) the reconciling write composes the ONE terminal leaf, and the survivors' write is unchanged
do $b$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'mainship_mark_combat_destroyed(', '')))
         / length('mainship_mark_combat_destroyed(');
  if v_n <> 4 then
    raise exception '0332 ASSERT (b) FAIL: % composition(s) of the terminal leaf (want 4: the head''s 3 defeat sites plus this slice''s settle site)', v_n;
  end if;
  -- the survivors' repatriation is untouched: still exactly one, still 'returning'.
  v_n := (length(v_code) - length(replace(v_code, 'mainship_mark_legacy_in_flight(cu.main_ship_id, ''returning'')', '')))
         / length('mainship_mark_legacy_in_flight(cu.main_ship_id, ''returning'')');
  if v_n <> 1 then
    raise exception '0332 ASSERT (b) FAIL: % survivor repatriation(s) (want the head''s exactly 1 — this slice adds an else, it does not touch the then)', v_n;
  end if;
  -- NO NEW LEAF: the reconciliation must not have invented a second name for the transition.
  if position('mainship_mark_wreck' in v_code) > 0 or position('mainship_reconcile' in v_code) > 0 then
    raise exception '0332 ASSERT (b) FAIL: a second terminal writer was introduced — one authority for "this hull is out of action"';
  end if;
end $b$;

-- (c) ONE spelling of liveness survives: the predicate count is UNCHANGED and no second spelling
do $c$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  -- 0317 pinned this at 7 and this slice MOVES one site (out of the loop header, into the branch)
  -- rather than adding or removing one. A different number means somebody changed the vocabulary.
  v_n := (length(v_code) - length(replace(v_code, 'alive_count > 0', ''))) / length('alive_count > 0');
  if v_n <> 7 then
    raise exception '0332 ASSERT (c) FAIL: the tick carries % site(s) of the alive_count > 0 predicate (want 0317''s 7, unchanged — this slice moves one site, it does not add one)', v_n;
  end if;
  if position('is_destroyed' in v_code) > 0 or position('alive_count <= 0' in v_code) > 0
     or position('alive_count = 0' in v_code) > 0 then
    raise exception '0332 ASSERT (c) FAIL: a second spelling of "is this unit alive" is in the tick — one authority, one predicate';
  end if;
  -- and the reconciliation is NOT hp-shaped: 0312's damaged-is-not-dead law, pinned in the tick.
  if position('hp <= 0 then
          perform mainship_mark_combat_destroyed' in v_code) > 0 then
    raise exception '0332 ASSERT (c) FAIL: the settle arm reconciles on an hp predicate — a merely damaged ship (0312:16-30) would be wrecked';
  end if;
end $c$;

-- (d) arm (A) and the hp writer are untouched — this slice adds an exit, it does not move death
do $d$
declare v_code text; v_hp text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'perform fleet_destroy(e.fleet_id);', '')))
         / length('perform fleet_destroy(e.fleet_id);');
  if v_n <> 3 then
    raise exception '0332 ASSERT (d) FAIL: % defeat-arm fleet_destroy call(s) (want the head''s 3 — the settle arm must NOT have gained one: a retreat that survived is not a defeat)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'mainship_sync_combat_hp(', '')))
         / length('mainship_sync_combat_hp(');
  if v_n <> 2 then
    raise exception '0332 ASSERT (d) FAIL: % hp-sync site(s) (want the head''s 2 — the hp writer is not this slice''s business)', v_n;
  end if;
  -- the hp writer itself still writes hp ONLY. If it ever also wrote status, the disagreement this
  -- migration reconciles could not arise mid-fight either — and 0312's fractional-hull law would
  -- silently die. This pins that the FIX did not migrate into the wrong function.
  select ${STRIP} into v_hp
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'mainship_sync_combat_hp';
  if v_hp is null then
    raise exception '0332 ASSERT (d) FAIL: mainship_sync_combat_hp is absent';
  end if;
  if position('status' in v_hp) > 0 then
    raise exception '0332 ASSERT (d) FAIL: mainship_sync_combat_hp now writes status — the mid-fight hp=0-while-alive state 0312 depends on would be gone';
  end if;
end $d$;

-- (e) the backfill's POST-CONDITION: no split row survives outside a live fight, and it moved
--     nothing but status. Both halves hold on a completely EMPTY database (zero rows -> zero rows).
do $e$
declare v_n integer;
begin
  select count(*) into v_n from (
    ${SPLIT_ROWS}
  ) q;
  if v_n <> 0 then
    raise exception '0332 ASSERT (e) FAIL: % ship(s) still end a concluded fight at hp<=0 without status=destroyed — the backfill did not close its own predicate', v_n;
  end if;
  -- IT NEVER ZEROES A HULL CAPACITY. A wreck keeps the max_hp its owner paid for, so repair
  -- restores it to the same ship. A destroyed ship at max_hp<=0 would be unrepairable forever
  -- (repair_main_ship raises 'invalid max_hp'), which is the softlock 0052 exists to prevent.
  select count(*) into v_n from public.main_ship_instances
   where status = 'destroyed' and (max_hp is null or max_hp <= 0);
  if v_n <> 0 then
    raise exception '0332 ASSERT (e) FAIL: % destroyed ship(s) carry max_hp <= 0 — repair_main_ship would raise invalid max_hp and the wreck could never come back', v_n;
  end if;
end $e$;

-- (f) THE RECOVERY SURFACE IS UNTOUCHED. This file re-creates none of it; these probes prove the
--     recovery path a wreck now reaches is still exactly 0297's, gating on status, for every ship
--     — including the ones that were already destroyed before this migration ran.
do $f$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.repair_main_ship(uuid)')::oid;
  if v_src is null then
    raise exception '0332 ASSERT (f) FAIL: repair_main_ship(uuid) is absent';
  end if;
  if position('v_ship.status <> ''destroyed''' in v_src) = 0 or position('ship is not disabled' in v_src) = 0 then
    raise exception '0332 ASSERT (f) FAIL: repair_main_ship no longer gates on status=destroyed — this slice must not have touched the recovery surface';
  end if;
  if position('mainship_port_of_ship' in v_src) = 0 or position('ship_not_at_port' in v_src) = 0 then
    raise exception '0332 ASSERT (f) FAIL: repair_main_ship lost 0297''s position gate';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.mainship_emergency_tow(uuid)')::oid;
  if v_src is null then
    raise exception '0332 ASSERT (f) FAIL: mainship_emergency_tow(uuid) is absent — the escape hatch a reconciled wreck depends on';
  end if;
  if position('v_ship.status <> ''destroyed''' in v_src) = 0 or position('ship_not_disabled' in v_src) = 0 then
    raise exception '0332 ASSERT (f) FAIL: mainship_emergency_tow no longer gates on status=destroyed';
  end if;
  if position('berth_location_id' in v_src) = 0 or position('group_id = null' in v_src) = 0 then
    raise exception '0332 ASSERT (f) FAIL: the tow no longer writes both 0216 XOR columns';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_my_disabled_ships()')::oid;
  if v_src is null or position('status = ''destroyed''' in v_src) = 0 then
    raise exception '0332 ASSERT (f) FAIL: get_my_disabled_ships no longer lists by status=destroyed — a reconciled wreck would be invisible to the client that must offer the tow';
  end if;
end $f$;

-- (g) every carried-through 0299/0310/0314/0317 invariant survives the re-emission
do $g$
declare v_code text; v_n integer; v_tok text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('fleet_get_power' in v_code) > 0 then
    raise exception '0332 ASSERT (g) FAIL: fleet_get_power is back in the tick (0299 reverted)';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_side_power(e.id, ''player'')', '')))
         / length('public.combat_encounter_side_power(e.id, ''player'')');
  if v_n <> 2 then
    raise exception '0332 ASSERT (g) FAIL: % of 2 power writes read the 0299 authority', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 8 then
    raise exception '0332 ASSERT (g) FAIL: the tick carries % cfg_bool call(s) (want the head''s 8 — this slice adds no gate)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'random(', ''))) / length('random(');
  if v_n <> 3 then
    raise exception '0332 ASSERT (g) FAIL: the tick carries % random( call(s) (want the post-0314 3: two wave seeds + the per-hit roll)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'movement_create(', ''))) / length('movement_create(');
  if v_n <> 2 then
    raise exception '0332 ASSERT (g) FAIL: the tick mints % movement leg(s) (want the head''s 2 — a reconciled wreck must not gain a leg of its own)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'presence_request_leave(e.presence_id)', '')))
         / length('presence_request_leave(e.presence_id)');
  if v_n <> 1 then
    raise exception '0332 ASSERT (g) FAIL: the 0310 auto-exit arm composes presence_request_leave % time(s) (want exactly 1)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'when query_canceled then raise;', '')))
         / length('when query_canceled then raise;');
  if v_n <> 2 then
    raise exception '0332 ASSERT (g) FAIL: % query_canceled re-raise line(s) (want exactly 2 — the 0206 guard''s and the 0310 arm''s)', v_n;
  end if;
  if position('select sum(msi.max_hp) into v_ae_cap' in v_code) = 0 then
    raise exception '0332 ASSERT (g) FAIL: the 0310 capacity denominator is gone — a stale-base re-emission';
  end if;
  foreach v_tok in array array[
      'perform 1 from combat_units where id = v_ur.id and alive_count > 0;',
      'v_hit_roll double precision := greatest(0, (1 - v_hit_var_pct) + random() * (2 * v_hit_var_pct));',
      'v_dmg := v_w_power * v_hit_roll;',
      'from combat_units where id = v_target_id and alive_count > 0;',
      'select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y',
      'v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)',
      'v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null',
      'perform fleet_set_returning(e.fleet_id, v_mv);',
      'perform report_create(e.id);'
    ] loop
    if position(v_tok in v_code) = 0 then
      raise exception '0332 ASSERT (g) FAIL: the tick lost a pinned head guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
end $g$;

-- (h) metadata parity: the tick changed body and NOTHING else
do $h$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0332_before loop
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
      raise exception '0332 ASSERT (h) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0332 ASSERT (h) FAIL: public.% body is byte-identical — the hunk did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0332 ASSERT (h) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0332 SELF-ASSERT PASS: the escape/completed settle arm now gives every alive_count=0 member the SAME terminal write the defeat arm always gave it (one leaf, one liveness predicate, count unchanged at 7); arm (A), the hp writer and the whole 0297 recovery surface are untouched; and no ship remains at hp<=0 without status=destroyed outside a running fight';
end $h$;

commit;
`;

if (sql.includes('\r')) {
  throw new Error('generated 0332 carries a CR — the rewrite hunk would never match the deployed body');
}

const check = process.argv.includes('--check');
if (check) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8');
  } catch {
    console.error('0332 CHECK FAIL: migration file is missing — run the generator');
    process.exit(1);
  }
  if (onDisk.replace(/\r\n/g, '\n') !== sql) {
    console.error('0332 CHECK FAIL: the migration on disk is not what the slices generate.');
    console.error('Either the 0299 source drifted or the file was hand-edited. Re-run the generator.');
    process.exit(1);
  }
  console.log('0332 CHECK OK: migration matches the slice taken from 0299.');
} else {
  writeFileSync(OUT, sql);
  console.log(`0332 written: ${OUT}`);
  console.log(`  ${HUNKS.length} hunk sliced from 0299:622-624 (nothing retyped; the filter became a branch by two exactly-once edits)`);
}
