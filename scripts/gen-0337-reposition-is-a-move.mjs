#!/usr/bin/env node
// gen-0337-reposition-is-a-move.mjs — emit (or --check) migration 0337.
//
// WHY A GENERATOR: 0337 rewrites ONE hunk inside the live command_ship_group_go body and FOUR
// inside process_combat_ticks. Neither function's whole text lives in one place at runtime — the
// mover is 39,355 chars live and the tick 73,160, both surgery-assembled — so every `old_t` below
// is SLICED VERBATIM out of the migration that owns the deployed text of its region, and every
// `new_t` is DERIVED from that slice by edit()/concatenation. Nothing is retyped (the 0303 lesson).
//
//   command_ship_group_go — TEXTUAL head 0330 (which re-emitted the deployed body from prod's own
//                           pg_get_functiondef, before-md5 == after-md5). The reposition arm 0311
//                           inserted is 0330:470-550 verbatim; that is the slice source.
//   process_combat_ticks  — TEXTUAL head 0299; replace-surgery since: 0310, 0314, 0317, 0332, 0336.
//                           All four slices below sit in 0299-ORIGINAL text and are statically
//                           DISJOINT from every one of 0336's eighteen hunks (checked hunk by hunk
//                           by scratchpad/anchors.mjs against the live body: each of the five
//                           anchors occurs EXACTLY ONCE in production and overlaps no 0336 old_t).
//
//   node scripts/gen-0337-reposition-is-a-move.mjs          # write the migration
//   node scripts/gen-0337-reposition-is-a-move.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000337_reposition_is_a_move.sql');
const SELF = '20260618000337';

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECKS: establish that the files sliced below really own the deployed text. ─────────────
// Two detectors over comment-stripped text, the gen-0336 shape: a later TEXTUAL re-create makes the
// slice source stale outright; a later HUNK ROW — the house `(idx, 'fname',` shape — means somebody
// surgically edited the body and a new slice must not be cut without reading that migration. Later
// rewriters are exempted BY NAME rather than by widening the window, so the gate stays live for
// 0338 and everything after it.
{
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const files = readdirSync(MIGDIR).filter((f) => f.endsWith('.sql') && version(f) !== SELF);
  const stripped = new Map(
    files.map((f) => [f, readFileSync(MIG(f), 'utf8').replace(/--[^\n]*/g, '')]));

  const guard = (fname, headVer, knownRewriters) => {
    const reCreate = new RegExp(`create\\s+or\\s+replace\\s+function\\s+(?:public\\.)?${fname}\\s*\\(`, 'i');
    const newerHeads = files.filter((f) => version(f) > headVer && reCreate.test(stripped.get(f)));
    if (newerHeads.length > 0) {
      throw new Error(
        `${fname} was textually re-created AFTER ${headVer} by: ${newerHeads.join(', ')} — ` +
        're-point the slices at the new head before generating.');
    }
    const reHunkRow = new RegExp(`\\(\\s*\\d+\\s*,\\s*'${fname}'\\s*,`);
    const newerSurgery = files.filter((f) => version(f) > headVer
      && !knownRewriters.has(version(f))
      && reHunkRow.test(stripped.get(f)));
    if (newerSurgery.length > 0) {
      throw new Error(
        `${fname} was rewritten by hunk surgery AFTER ${headVer} by: ${newerSurgery.join(', ')} — ` +
        'read that migration and re-point these slices; do not regenerate blindly.');
    }
  };
  // 0336 is exempted BY NAME on the tick: its eighteen hunks were read one by one and every anchor
  // below was verified disjoint from all of them. It is not a blanket pass — a NEW surgeon on this
  // function still fails this gate.
  guard('process_combat_ticks', '20260618000299',
    new Set(['20260618000310', '20260618000314', '20260618000317', '20260618000332', '20260618000336']));
  guard('command_ship_group_go', '20260618000330', new Set());
}

const F330 = load('20260618000330_the_mover_is_in_the_repo.sql');
const F299 = load('20260618000299_combat_card_reports_true_power.sql');

/** Slice [from,to] 1-indexed inclusive, asserting fence lines so source drift fails loudly. */
function slice(lines, file, from, to, startsWith, endsWith) {
  const text = lines.slice(from - 1, to).join('\n');
  if (!lines[from - 1].includes(startsWith)) {
    throw new Error(`${file}:${from} expected to contain ${JSON.stringify(startsWith)}, got ${JSON.stringify(lines[from - 1])}`);
  }
  if (!lines[to - 1].includes(endsWith)) {
    throw new Error(`${file}:${to} expected to contain ${JSON.stringify(endsWith)}, got ${JSON.stringify(lines[to - 1])}`);
  }
  return text;
}

/** The 1-indexed line of the ONE exact-match occurrence of `needle`; throws on 0 or 2+. Locating a
 *  slice by its content rather than by a memorised line number is what keeps these anchors correct
 *  across an edit to the source migration that happens to shift them. */
function only(lines, file, needle) {
  const hits = [];
  lines.forEach((l, i) => { if (l === needle) hits.push(i + 1); });
  if (hits.length !== 1) {
    throw new Error(`${file} contains ${hits.length} exact copies of ${JSON.stringify(needle)}, want 1`);
  }
  return hits[0];
}

/** Replace `from` with `to` in `base`, demanding `from` occurs EXACTLY once — the parity guard
 *  that lets new_t be CONSTRUCTED from the slice instead of retyped. */
function edit(base, from, to) {
  const n = base.split(from).length - 1;
  if (n !== 1) throw new Error(`edit(): needle occurs ${n} time(s), want exactly 1: ${JSON.stringify(from)}`);
  return base.replace(from, to);
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// H1 — command_ship_group_go: THE ORDER STOPS MOVING ANYTHING AND RECORDS A DESTINATION
// ═════════════════════════════════════════════════════════════════════════════════════════════════
// old_t is 0311's whole reposition arm as 0330 re-emitted it from production: the banner comment,
// the fenced admission, the fleet lock, the THREE INSTANT WRITES and the envelope.
const H1_OLD = slice(F330, '0330', 470, 550, '0311: REPOSITION INSIDE', 'end if;');

// (i) the banner. 0311's header states the teleport as the design and justifies it with a weapon
//     range that 0316 then cut by five. Both sentences are deleted, not softened.
const H1_BANNER_OLD = slice(F330, '0330', 470, 482, '0311: REPOSITION INSIDE', 'fail closed.');
const H1_BANNER_NEW = `      -- ── 0337: A REPOSITION ORDERS A MOVE — THE FLEET TRAVELS, IT DOES NOT TELEPORT. ───────────
      -- The owner's report: "when in combat, and i move, i teleport." They were right, and it was
      -- this arm's design. 0311 wrote the fleet row, the WHOLE player formation and the engagement
      -- anchor straight to the destination, one statement each, in the order's own transaction —
      -- and said so: "The reposition is INSTANT (the ambush park's own primitive)." It justified
      -- that with a measurement — the live zones span at most ~79 world units against "enemy weapon
      -- range 120+", so "NO in-zone reposition on today's zones can leave anyone's weapon range".
      -- 0316 then cut every weapon range by FIVE, to 5-6. The justification died with that
      -- migration and the teleport outlived it: an instant jump now drops a fleet clean out of the
      -- fight's geometry in a single frame, which is exactly what the owner watched happen.
      --
      -- SO THE ORDER MOVES NOTHING. It RECORDS a destination and returns. The combat tick's own
      -- mover — the one that already walks every unit at its own move_speed — carries the fleet
      -- there a step at a time, firing and being fired upon the whole way. That is what makes
      -- repositioning a TACTICAL move rather than an escape button.
      --
      -- THE FLEET IS THE ACTOR AND IT MOVES AS ONE (the owner: "why are there four ships? ... no,
      -- show only fleet. it is as a whole"). The destination is ONE pair of columns on the
      -- ENCOUNTER — the row that IS this fleet's fight — never one per combat_units row. ONE
      -- writer: this arm. ONE reader: the tick's reposition step. ONE speed, ONE arrival.
      --
      -- WHY THE ENCOUNTER AND NOT THE FLEET: this repository has already run the other experiment.
      -- fleets.retreat_target_* is a destination stored on the fleet row, and it outlived its
      -- encounter so reliably that 0336 had to add fleet_consume_retreat_target and call it from
      -- FOUR arms to stop a dead fleet's NEXT sortie flying to a point it was ordered to in a fight
      -- it had already lost. A destination on the encounter cannot outlive the fight: the tick only
      -- ever selects status in ('active','retreating') and the step re-reads status = 'active', so
      -- a terminal row's value is unreachable BY CONSTRUCTION. There is nothing to remember to
      -- clear, and no fourth arm to forget.
      --
      -- WHAT HAPPENS TO A LIVE ORDER WHEN THE FIGHT CHANGES, stated rather than discovered:
      --   retreat ordered / auto-exit fires -> the encounter goes 'retreating', the step's own
      --     re-read stops matching, and the fleet holds exactly where it stands. That is already
      --     the engine's rule for a retreating side (the v_offense gate); no second notion of
      --     "stop moving" is introduced and nothing is cleared.
      --   the fleet dies / the fight ends  -> the encounter row goes terminal and is never selected
      --     again. The value dies with the fight.
      --   re-ordered mid-journey           -> this arm overwrites the pair. Last write wins, one
      --     destination, and the fleet turns toward the new point from wherever it has got to.
      --
      -- THE ADMISSION IS UNCHANGED AND STILL BINDS: reposition iff an active danger zone contains
      -- BOTH this fight's anchor and the destination. It is COMPOSED, never re-implemented, and it
      -- still QUANTIFIES over every anchor-holding zone rather than choosing one. Gated to
      -- encounter 'active' for 0311's own reason: a 'retreating' fight may only update its stored
      -- retreat destination in arm (b), and a mid-window course change would be a free escape from
      -- the damage window. False/NULL anywhere — unstamped anchor, no zone, boundary graze — falls
      -- through to the retreat arms: fail closed.`;

// (ii) the two locals that existed ONLY to compute the instant delta.
const H1_DECL_OLD = `          v_rz_mode   text;
          v_rz_eng_x  double precision;
          v_rz_eng_y  double precision;
`;
const H1_DECL_NEW = `          v_rz_mode   text;
`;

// (iii) THE DELETION: the engagement read and all three instant writes become one destination write.
const H1_WRITES_OLD = slice(F330, '0330', 506, 526, 'select ce.engagement_x', 'where id = v_enc.id;');
const H1_WRITES_NEW = `            -- THE ONE WRITE. Not three. The fleet row is NOT touched, the formation is NOT
            -- translated and the anchor is NOT restamped here — every one of those now belongs to
            -- the tick, applied a step at a time as the fleet actually covers the ground. Deleting
            -- them from this arm is the point of the slice: an instant path left beside a stepped
            -- one is two authorities for where the fleet is, which is the spaghetti this law
            -- forbids. Deliberately still NO movement_create: a leg would put the fleet back to
            -- 'moving' (a state step 7 and the tick both assume it is not in mid-fight) and would
            -- re-roll an ambush inside the zone it is already fighting in.
            update public.combat_encounters
               set reposition_x = v_t_x, reposition_y = v_t_y, updated_at = v_now
             where id = v_enc.id;`;

// (iv) the token. 'repositioned' claims an arrival the server has not performed.
const H1_TOKEN_OLD = `              'order_outcome', 'repositioned',
              'outcome', 'repositioned',
              'reason', 'repositioned',`;
const H1_TOKEN_NEW = `              -- 'repositioning', NOT 'repositioned'. The fleet has not arrived; it has been
              -- given a course. The client copy changes in the SAME slice — a success token that
              -- announces an arrival nothing has performed is the teleport surviving in the UI.
              'order_outcome', 'repositioning',
              'outcome', 'repositioning',
              'reason', 'repositioning',`;

// (v) the fall-through note names the primitive that nulls current_location_id; it moved to the tick.
const H1_TAIL_OLD = `          -- Reposition stays open-space-only because fleet_set_in_space nulls
          -- current_location_id, and its interaction with a live 'present' location_presence is
          -- UNVERIFIED.`;
const H1_TAIL_NEW = `          -- Reposition stays open-space-only because the TICK's step composes fleet_set_in_space,
          -- which nulls current_location_id, and its interaction with a live 'present'
          -- location_presence is UNVERIFIED.`;

const H1_NEW = edit(edit(edit(edit(edit(
  H1_OLD,
  H1_BANNER_OLD, H1_BANNER_NEW),
  H1_DECL_OLD, H1_DECL_NEW),
  H1_WRITES_OLD, H1_WRITES_NEW),
  H1_TOKEN_OLD, H1_TOKEN_NEW),
  H1_TAIL_OLD, H1_TAIL_NEW);

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// H2 — process_combat_ticks: the one new local joins the declare block
// ═════════════════════════════════════════════════════════════════════════════════════════════════
const L_DECL = only(F299, '0299', '  v_move_action            text;');
const H2_OLD = slice(F299, '0299', L_DECL, L_DECL, 'v_move_action', 'text;');
const H2_NEW = `${H2_OLD}
  -- ██ 0337 IS THIS FLEET UNDER A MOVE ORDER THIS TICK? ██
  -- Read ONCE per encounter, immediately below v_is_spatial, from the row already in hand. Its only
  -- job is to tell the per-unit mover to keep its hands off the player side; the AUTHORITY on
  -- whether the fleet may actually move is the reposition step's own re-read at the foot of the
  -- spatial arm, which sees a retreat armed later in this same tick and this local cannot.
  v_rp_live                boolean;`;

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// H3 — process_combat_ticks: set it, one line under the mode decision it belongs with
// ═════════════════════════════════════════════════════════════════════════════════════════════════
const ISSPAT = '    v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null);';
const L_ISSPAT = only(F299, '0299', ISSPAT);
const H3_OLD = slice(F299, '0299', L_ISSPAT, L_ISSPAT, 'v_is_spatial := exists', 'pos_x is not null);');
const H3_NEW = `${H3_OLD}

    -- 0337: a live reposition order, read off the row this iteration already holds. 'active' is
    -- part of the question, not a separate guard: a retreating fleet is leaving, not manoeuvring.
    v_rp_live := v_is_spatial and e.reposition_x is not null and e.status = 'active';`;

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// H4 — process_combat_ticks: the per-unit position write is FENCED for the player side
// ═════════════════════════════════════════════════════════════════════════════════════════════════
const UNITMOVE = '          update combat_units set pos_x = v_new_x, pos_y = v_new_y, updated_at = now() where id = v_ur.id;';
const L_UNITMOVE = only(F299, '0299', UNITMOVE);
const H4_OLD = slice(F299, '0299', L_UNITMOVE, L_UNITMOVE, 'update combat_units set pos_x = v_new_x', 'where id = v_ur.id;');
const H4_NEW = `          -- ██ 0337 THE FLEET IS THE COMBAT ACTOR — ONE ORDER, ONE BODY, ONE WRITER ██
          -- While a reposition order is live, the player side's position is decided by the FLEET
          -- step at the foot of this arm — one rigid translate at the fleet's own speed — and NOT
          -- by four hulls each chasing its own nearest pirate. Two writers of one position is
          -- precisely the spaghetti the standing law forbids, so the per-unit write stands down
          -- rather than being reconciled with the fleet's.
          -- ONLY MOVEMENT STANDS DOWN. Targeting above and fire below are untouched: the fleet
          -- shoots and is shot at for every tick of the journey, which is what makes this a
          -- tactical move instead of an escape button.
          -- THE ENEMY SIDE IS NEVER FENCED — v_ur.side names the player explicitly. Pirates close
          -- on the fleet's new position every tick through the same leaf they always did, so
          -- walking away can never make the fleet unreachable by standing still.
          if not (v_ur.side = 'player' and v_rp_live) then
${H4_OLD.replace('          update', '            update')}
          end if;`;

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// H5 — process_combat_ticks: THE REPOSITION STEP
// ═════════════════════════════════════════════════════════════════════════════════════════════════
const L_PAUSE = only(F299, '0299', '      end if; -- not v_wave_paused');
const H5_OLD = slice(F299, '0299', L_PAUSE - 1, L_PAUSE, 'v_count := v_count + 1;', 'end if; -- not v_wave_paused');
const H5_NEW = `${H5_OLD}

      -- ██ 0337 THE REPOSITION STEP — THE FLEET COVERS GROUND, ONE TICK AT A TIME ██
      -- The whole of the owner's fix lives here. command_ship_group_go now only RECORDS where the
      -- fleet was told to go; this is what takes it there, at the fleet's own speed, so the player
      -- watches their ships travel instead of blinking to the destination.
      --
      -- FOUR LEAVES, COMPOSED. Not one line of new geometry:
      --   combat_fleet_move_speed          — THE fleet's one combat speed. min(move_speed) over its
      --     living hulls, which is the SAME min-over-the-fleet rule fleet_speed and
      --     combat_fleet_return_speed already use: a formation moves at its slowest ship. One
      --     fleet, one speed — never four ships arriving at four different times.
      --   combat_unit_decide_move          — the engine's ONE step-toward-a-point primitive, asked
      --     with my_range = 0 and target_range = 0, which is exactly "walk at me, capped by my
      --     speed, stop when you get there". No second clamp, no second distance formula.
      --   combat_translate_player_formation— the ONE rigid translation of the player side. 0311
      --     called it once with the whole delta; it is called here once per tick with a step, so
      --     the formation the encounter builder laid out survives the journey by construction and
      --     the fleet moves as a BODY rather than dissolving into four independent ships.
      --   fleet_set_in_space               — the ONE writer of fleets.space_x/y, so the map marker
      --     tracks the fight instead of teleporting at the end.
      --
      -- SITED AFTER the not-v_wave_paused arm ON PURPOSE, unlike 0310's auto-exit: a fleet under
      -- orders keeps moving through the lull between waves. Freezing mid-journey for
      -- combat_transition_seconds is the kind of stutter the player reads as a bug.
      --
      -- THE STALE-DESTINATION FENCE IS THE RE-READ, and it is the whole answer to "what if the
      -- fight ended, the fleet died, or a retreat was ordered while it was moving": the select
      -- carries status = 'active', taken from the table at the instant of acting rather than from
      -- the record read at the top of this iteration. An auto-exit that fired a few lines above
      -- (0310) has ALREADY flipped the encounter to 'retreating' in this same transaction, so this
      -- select returns no row and the fleet holds — which is what the engine does with a retreating
      -- side anyway. Nothing is cleared, because a value on a row nobody reads is already gone.
      --
      -- ARRIVAL IS THE MOVER'S OWN CALL. dist <= speed means this step lands, so the fleet is put
      -- EXACTLY on the ordered point (never on the leaf's floating-point approach to it) and the
      -- order is consumed in the same statement that spends it. Every other step moves the full
      -- speed and keeps the order.
      --
      -- CONFINED, for 0310's reason: a defect in a MOVEMENT convenience must never void COMBAT
      -- itself. Its own subtransaction means a failure skips the step for this tick (warned,
      -- retried in three seconds) instead of landing in the 0206 per-encounter guard, which would
      -- roll back the entire tick — wave spawn, damage and rewards included — every three seconds,
      -- silently, forever. query_canceled re-raises exactly as the outer guard treats it.
      declare
        v_rp_x     double precision;
        v_rp_y     double precision;
        v_rp_ax    double precision;
        v_rp_ay    double precision;
        v_rp_speed double precision;
        v_rp_dist  double precision;
        v_rp_nx    double precision;
        v_rp_ny    double precision;
        v_rp_tx    double precision;
        v_rp_ty    double precision;
        v_rp_done  boolean;
      begin
        -- THE SAME TWO CONDITIONS THE ORDER ARM ADMITTED ON, ASKED AGAIN AT THE MOMENT OF MOVING.
        -- 'active' is the stale-destination fence described above. The join on location_mode='space'
        -- is the other half: the order arm refuses a fight the fleet is 'present' at its site for,
        -- because fleet_set_in_space nulls current_location_id and its interaction with a live
        -- 'present' location_presence is UNVERIFIED — and this step composes that same primitive, so
        -- it must hold the same condition. Checking it only at order time would leave a fleet that
        -- became 'present' between the order and a later tick being quietly un-docked by the mover.
        -- Fail closed: no row, no move, the order simply stands.
        select ce.reposition_x, ce.reposition_y, ce.engagement_x, ce.engagement_y
          into v_rp_x, v_rp_y, v_rp_ax, v_rp_ay
          from combat_encounters ce
          join fleets f on f.id = ce.fleet_id and f.location_mode = 'space'
         where ce.id = e.id and ce.status = 'active';
        if v_rp_x is not null and v_rp_ax is not null then
          v_rp_speed := public.combat_fleet_move_speed(e.id);
          -- NULL or non-positive speed = a fleet with nothing living left to move: hold, and leave
          -- the order standing. Fail closed, never a divide or a teleport-by-default.
          if v_rp_speed is not null and v_rp_speed > 0 then
            select m.new_x, m.new_y, m.dist into v_rp_nx, v_rp_ny, v_rp_dist
              from public.combat_unit_decide_move(v_rp_ax, v_rp_ay, 0, v_rp_speed, v_rp_x, v_rp_y, 0) m;
            v_rp_done := v_rp_dist <= v_rp_speed;
            v_rp_tx   := case when v_rp_done then v_rp_x else v_rp_nx end;
            v_rp_ty   := case when v_rp_done then v_rp_y else v_rp_ny end;
            -- ONE delta, spent on all three: the formation, the fleet marker and the anchor move by
            -- the same vector, so the ring can never drift off the point the waves spawn around.
            perform public.combat_translate_player_formation(e.id, v_rp_tx - v_rp_ax, v_rp_ty - v_rp_ay);
            perform public.fleet_set_in_space(e.fleet_id, v_rp_tx, v_rp_ty);
            update combat_encounters
               set engagement_x = v_rp_tx,
                   engagement_y = v_rp_ty,
                   reposition_x = case when v_rp_done then null else reposition_x end,
                   reposition_y = case when v_rp_done then null else reposition_y end,
                   updated_at   = now()
             where id = e.id;
            -- The anchor local means "where this fight physically is". Nothing later in THIS
            -- iteration reads it — the spatial arm ends here — so this changes no outcome today; it
            -- is set so the local never states something the table contradicts.
            v_anchor_x := v_rp_tx;
            v_anchor_y := v_rp_ty;
          end if;
        end if;
      exception
        when query_canceled then raise;
        when others then
          raise warning 'reposition step skipped for encounter % (the fight continues; retried next tick): %',
            e.id, sqlerrm;
      end;`;

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// THE MIGRATION
// ═════════════════════════════════════════════════════════════════════════════════════════════════
const SQL = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0337 — A REPOSITION IS A MOVE. THE FLEET TRAVELS; IT DOES NOT TELEPORT.
--
-- GENERATED BY scripts/gen-0337-reposition-is-a-move.mjs — DO NOT HAND-EDIT.
-- Regenerate with \`node scripts/gen-0337-reposition-is-a-move.mjs\`; the parity gate in
-- scripts/danger-combat-proof.sh runs \`--check\` and fails if this file drifted from the generator.
--
-- ── THE REPORT ───────────────────────────────────────────────────────────────────────────────────
-- The owner: "when in combat, and i move, i teleport."
--
-- They are right and it was 0311's stated design. 0311's own header says it outright — "The
-- reposition is INSTANT (the ambush park's own primitive). Enemy rows are NOT moved." — and
-- justifies the instantness with a measurement: the three live zones span at most ~79 world units
-- against "enemy weapon range 120+", so "NO in-zone reposition on today's zones can leave anyone's
-- weapon range." 0316 then cut every weapon range by FIVE, to 5-6. The justification died with that
-- migration; the teleport did not. At today's geometry an instant reposition drops the fleet clean
-- out of the fight in a single frame.
--
-- ── WHAT THIS MIGRATION DOES ─────────────────────────────────────────────────────────────────────
-- The ORDER stops moving anything and records a destination. The TICK carries the fleet there at
-- the fleet's own speed, one step per tick, firing and being fired upon the whole way.
--
--   command_ship_group_go  — the reposition arm's THREE INSTANT WRITES ARE DELETED: the
--                            fleet_set_in_space jump, the whole-delta
--                            combat_translate_player_formation, and the engagement restamp, plus
--                            the two locals that existed only to compute that delta. In their place
--                            ONE write: combat_encounters.reposition_x/reposition_y. The outcome
--                            token becomes 'repositioning' — the fleet has a course, not an
--                            arrival. The admission (an active zone holding both the anchor and the
--                            destination, quantified over every holder) is COMPOSED and unchanged.
--   process_combat_ticks   — gains the reposition step: while an order stands, the player side's
--                            per-unit close/kite write stands down and the formation translates
--                            RIGIDLY toward the destination at min(move_speed) over the fleet's
--                            living hulls. Arrival consumes the order.
--   combat_fleet_move_speed— the one new leaf: THE fleet's combat speed, by the same
--                            min-over-the-fleet rule fleet_speed and combat_fleet_return_speed
--                            already use.
--
-- ── THE FLEET IS THE ACTOR ───────────────────────────────────────────────────────────────────────
-- The owner, on seeing four ship markers: "why are there four ships? because i have 4 ships in
-- fleet? no, show only fleet. it is as a whole." The destination is therefore per FLEET — one pair
-- of columns on the ENCOUNTER, which is per-fleet by construction — never one per combat_units row.
-- ONE writer (the order arm), ONE reader (the tick step), ONE speed, ONE arrival. The per-ship rows
-- underneath keep doing what only they can do — hold hp and account losses — and are moved as a
-- rigid body by the ONE translation leaf, never steered individually.
--
-- ── WHY THE ENCOUNTER AND NOT THE FLEET ──────────────────────────────────────────────────────────
-- Because this repository has already run the other experiment. fleets.retreat_target_* is a
-- destination stored on the fleet row, and it outlived its encounter so reliably that 0336 had to
-- add fleet_consume_retreat_target and call it from FOUR arms to stop a dead fleet's next sortie
-- flying to a point it was ordered to in a fight it had already lost. A destination on the
-- ENCOUNTER cannot outlive the fight: the tick only ever selects status in ('active','retreating'),
-- and the step re-reads status = 'active' at the instant of acting. A terminal row's value is
-- unreachable by construction — nothing to clear, no fourth arm to forget.
--
-- ── THE THREE STALE CASES, DECIDED ───────────────────────────────────────────────────────────────
--   RETREAT ORDERED (or 0310's auto-exit fires) mid-move -> the encounter is 'retreating', the
--     step's re-read stops matching, the fleet HOLDS where it stands and the retreat leg departs
--     from there. This is already the engine's rule for a retreating side (the v_offense gate); no
--     second notion of "stop" is introduced. A move is never a retreat and presence_request_leave
--     remains the sole retreat authority — this slice calls it nowhere.
--   THE FLEET DIES / THE FIGHT ENDS -> the encounter goes terminal and is never selected again.
--   RE-ORDERED MID-JOURNEY -> the order arm overwrites the pair; the fleet turns toward the new
--     point from wherever it has got to. Last write wins, one destination.
--
-- ── BLAST RADIUS ON LIVE PLAYERS ─────────────────────────────────────────────────────────────────
--   - Two nullable columns and a CHECK; no backfill, no flag, no data written at deploy time. Every
--     encounter in flight has reposition_x = NULL, i.e. no order, i.e. the tick behaves exactly as
--     it does today.
--   - Which live fights change behaviour: only a fight that RECEIVES a reposition order after this
--     deploys. Every other order — retreat, destination update, site fight, no-zone destination —
--     is byte-identical to 0311+0330.
--   - The player-side per-unit movement fence is inert (v_rp_live is false) for every fight with no
--     standing order, so close/kite is unchanged everywhere else.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply 0330's command_ship_group_go body verbatim and re-emit the tick with the four hunks
-- reverted, then:
--   alter table public.combat_encounters drop constraint combat_encounters_reposition_both_or_neither;
--   alter table public.combat_encounters drop column reposition_x, drop column reposition_y;
--   drop function public.combat_fleet_move_speed(uuid);
-- Nothing else here writes state.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
--   (a) the destination columns exist, nullable, and the CHECK really refuses a half-pair
--   (b) combat_fleet_move_speed exists with the right shape, is not client-callable, and is the
--       min-over-the-living-fleet rule (fail-closed on an encounter with nothing alive)
--   (c) THE INSTANT PATH IS GONE from the order verb: no fleet_set_in_space, no
--       combat_translate_player_formation, no engagement write, no 'repositioned' token — and the
--       destination write is there exactly once
--   (d) the tick COMPOSES the four leaves, each exactly once, and carries no inline geometry
--   (e) the per-unit position write is FENCED (exactly one such write, and it is inside the gate)
--   (f) the step's stale-destination fence is a FRESH status='active' read, not the loop record
--   (g) metadata parity: both functions changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. PRECONDITIONS ─────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regprocedure('public.process_combat_ticks()') is null then
    raise exception '0337 PRECONDITION FAIL: process_combat_ticks is absent';
  end if;
  if to_regproc('public.command_ship_group_go') is null then
    raise exception '0337 PRECONDITION FAIL: command_ship_group_go is absent';
  end if;
  -- The three leaves the tick step composes must already exist; this slice creates only the fourth.
  if to_regproc('public.combat_unit_decide_move') is null
     or to_regproc('public.combat_translate_player_formation') is null
     or to_regproc('public.fleet_set_in_space') is null then
    raise exception '0337 PRECONDITION FAIL: a composed leaf is absent — this slice re-implements none of them';
  end if;
end $pre$;

-- ── 1. THE DESTINATION LIVES ON THE FIGHT ────────────────────────────────────────────────────────
-- Per FLEET, because the encounter IS per fleet. Both-or-neither is a FACT OF THE TABLE rather than
-- a convention, exactly as fleets_retreat_target_one_of makes the retreat pair's exclusivity a fact.
alter table public.combat_encounters
  add column if not exists reposition_x double precision,
  add column if not exists reposition_y double precision;

alter table public.combat_encounters
  drop constraint if exists combat_encounters_reposition_both_or_neither;
alter table public.combat_encounters
  add constraint combat_encounters_reposition_both_or_neither
  check ((reposition_x is null) = (reposition_y is null));

-- ── 1b. THE FLEET'S ONE COMBAT SPEED ─────────────────────────────────────────────────────────────
-- min() over the fleet's living hulls — the SAME rule fleet_speed (min over fleet_units) and
-- combat_fleet_return_speed (min over the encounter's hulls) already state: a formation moves at the
-- speed of its slowest ship. Expressed on combat_units.move_speed, the column the per-unit mover
-- itself reads, so no second notion of "how fast" enters the engine.
-- NULL for an encounter with nothing living: the caller holds. Fail closed.
create or replace function public.combat_fleet_move_speed(p_encounter uuid)
returns double precision
language sql
stable
security definer
set search_path to 'public'
as $cfms$
  select min(cu.move_speed)::double precision
    from public.combat_units cu
   where cu.encounter_id = p_encounter
     and cu.side = 'player'
     and cu.alive_count > 0;
$cfms$;

revoke all on function public.combat_fleet_move_speed(uuid) from public;
revoke all on function public.combat_fleet_move_speed(uuid) from anon, authenticated;
grant execute on function public.combat_fleet_move_speed(uuid) to service_role;

-- ── 2. CAPTURE METADATA BEFORE THE REWRITE (for parity check g) ──────────────────────────────────
create temp table _0337_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0337_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('process_combat_ticks', 'command_ship_group_go');

-- ── 3. REWRITE THE HUNKS (located by exact deployed text, never retyped) ─────────────────────────
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
    (1, 'command_ship_group_go',
     $h1o$${H1_OLD}$h1o$,
     $h1n$${H1_NEW}$h1n$),
    (2, 'process_combat_ticks',
     $h2o$${H2_OLD}$h2o$,
     $h2n$${H2_NEW}$h2n$),
    (3, 'process_combat_ticks',
     $h3o$${H3_OLD}$h3o$,
     $h3n$${H3_NEW}$h3n$),
    (4, 'process_combat_ticks',
     $h4o$${H4_OLD}$h4o$,
     $h4n$${H4_NEW}$h4n$),
    (5, 'process_combat_ticks',
     $h5o$${H5_OLD}$h5o$,
     $h5n$${H5_NEW}$h5n$)
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0337 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0337 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0337 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0337 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 5 then
    raise exception '0337 REWRITE FAIL: rewrote % site(s), expected 5', v_done;
  end if;
end $rewrite$;

-- ── 4. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) the destination columns, and a CHECK that really refuses a half-pair
do $a$
declare v_n integer; v_def text; v_bit boolean := false;
begin
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'combat_encounters'
     and column_name in ('reposition_x', 'reposition_y')
     and data_type = 'double precision' and is_nullable = 'YES';
  if v_n <> 2 then
    raise exception '0337 ASSERT (a) FAIL: % of 2 nullable reposition column(s) present', v_n;
  end if;
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conrelid = 'public.combat_encounters'::regclass
     and c.conname = 'combat_encounters_reposition_both_or_neither';
  if v_def is null then
    raise exception '0337 ASSERT (a) FAIL: the both-or-neither CHECK is missing';
  end if;
  -- NON-VACUOUS, AND DATA-INDEPENDENT. Proving the constraint by UPDATEing a real encounter would
  -- no-op silently on a fresh chain, which has none — a probe that passes because it touched nothing
  -- is exactly the vacuity class this repository has been bitten by. So the DEPLOYED expression is
  -- re-created verbatim (pg_get_constraintdef, never retyped) on a throwaway table and made to
  -- refuse a half-pair for real.
  execute 'create temp table _0337_chk (reposition_x double precision, reposition_y double precision, constraint half_pair ' || v_def || ') on commit drop';
  begin
    insert into _0337_chk (reposition_x, reposition_y) values (1, null);
  exception
    when check_violation then v_bit := true;   -- exactly what must happen
  end;
  if not v_bit then
    raise exception '0337 ASSERT (a) FAIL: the deployed CHECK accepted a half-pair (x set, y null) — % does not bite', v_def;
  end if;
  v_bit := false;
  begin
    insert into _0337_chk (reposition_x, reposition_y) values (null, 2);
  exception
    when check_violation then v_bit := true;
  end;
  if not v_bit then
    raise exception '0337 ASSERT (a) FAIL: the deployed CHECK accepted the OTHER half-pair (y set, x null)';
  end if;
  -- and both legal shapes are accepted, so the constraint is not simply refusing everything
  insert into _0337_chk (reposition_x, reposition_y) values (null, null), (1, 2);
  if (select count(*) from _0337_chk) <> 2 then
    raise exception '0337 ASSERT (a) FAIL: the CHECK refused a LEGAL pair — no course could ever be recorded';
  end if;
end $a$;

-- (b) the fleet-speed leaf: right shape, engine-internal, and the min-over-the-living rule
do $b$
declare v_code text;
begin
  if to_regprocedure('public.combat_fleet_move_speed(uuid)') is null then
    raise exception '0337 ASSERT (b) FAIL: combat_fleet_move_speed(uuid) was not created';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'combat_fleet_move_speed'
                    and p.provolatile = 's' and p.prosecdef
                    and coalesce(array_to_string(p.proconfig, ','), '') = 'search_path=public') then
    raise exception '0337 ASSERT (b) FAIL: combat_fleet_move_speed has the wrong volatility / security / search_path posture';
  end if;
  if has_function_privilege('anon', 'public.combat_fleet_move_speed(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.combat_fleet_move_speed(uuid)', 'EXECUTE') then
    raise exception '0337 ASSERT (b) FAIL: combat_fleet_move_speed is client-callable — it is an engine internal, not a new surface';
  end if;
  if not has_function_privilege('service_role', 'public.combat_fleet_move_speed(uuid)', 'EXECUTE') then
    raise exception '0337 ASSERT (b) FAIL: service_role cannot execute combat_fleet_move_speed';
  end if;
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_fleet_move_speed';
  if position('min(cu.move_speed)' in v_code) = 0 then
    raise exception '0337 ASSERT (b) FAIL: the leaf is not min(move_speed) — the fleet must move at its SLOWEST hull, the rule fleet_speed and combat_fleet_return_speed already state';
  end if;
  if position('alive_count > 0' in v_code) = 0 or position(chr(39) || 'player' || chr(39) in v_code) = 0 then
    raise exception '0337 ASSERT (b) FAIL: the leaf does not restrict to LIVING PLAYER hulls — a wreck or a pirate must never set the fleet''s speed';
  end if;
  -- fail-closed smoke: an encounter that does not exist has no living hull, so NULL, so the step holds.
  if public.combat_fleet_move_speed('00000000-0000-0000-0000-000000000000'::uuid) is not null then
    raise exception '0337 ASSERT (b) FAIL: the leaf answered a non-NULL speed for an encounter with no units — it must fail closed';
  end if;
end $b$;

-- (c) THE INSTANT PATH IS GONE FROM THE ORDER VERB
do $c$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('combat_translate_player_formation' in v_code) > 0 then
    raise exception '0337 ASSERT (c) FAIL: the order verb still translates the formation — the instant path survives beside the stepped one, which is two authorities for where the fleet is';
  end if;
  if position('fleet_set_in_space' in v_code) > 0 then
    raise exception '0337 ASSERT (c) FAIL: the order verb still writes the fleet position — the teleport survives';
  end if;
  if position('engagement_x' in v_code) > 0 or position('engagement_y' in v_code) > 0 then
    raise exception '0337 ASSERT (c) FAIL: the order verb still touches the engagement anchor — the anchor is the tick''s to move, a step at a time';
  end if;
  if position(chr(39) || 'repositioned' || chr(39) in v_code) > 0 then
    raise exception '0337 ASSERT (c) FAIL: the order verb still answers ''repositioned'' — a token that announces an arrival nothing performed';
  end if;
  v_n := (length(v_code) - length(replace(v_code, chr(39) || 'repositioning' || chr(39), '')))
         / length(chr(39) || 'repositioning' || chr(39));
  if v_n <> 3 then
    raise exception '0337 ASSERT (c) FAIL: % ''repositioning'' token(s) in the envelope (want exactly 3: order_outcome, outcome, reason)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'set reposition_x = v_t_x, reposition_y = v_t_y', '')))
         / length('set reposition_x = v_t_x, reposition_y = v_t_y');
  if v_n <> 1 then
    raise exception '0337 ASSERT (c) FAIL: % destination write(s) (want exactly 1 — ONE writer of where the fleet is headed)', v_n;
  end if;
  -- the admission is still COMPOSED, and still the gate in front of that write
  if position('combat_encounter_zone_admits_point' in v_code) = 0 then
    raise exception '0337 ASSERT (c) FAIL: the zone admission is gone — an in-zone order is the only thing that may reposition';
  end if;
  if position('combat_encounter_zone_admits_point' in v_code) > position('set reposition_x = v_t_x' in v_code) then
    raise exception '0337 ASSERT (c) FAIL: the destination is written BEFORE the admission is consulted';
  end if;
  -- a reposition is never a retreat: the sole retreat authority must still sit AFTER this arm
  if position('set reposition_x = v_t_x' in v_code) > position('presence_request_leave' in v_code) then
    raise exception '0337 ASSERT (c) FAIL: the reposition arm no longer precedes the retreat arm';
  end if;
end $c$;

-- (d) the tick COMPOSES the four leaves — no inline geometry, no second mover
do $d$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_fleet_move_speed(e.id)', '')))
         / length('public.combat_fleet_move_speed(e.id)');
  if v_n <> 1 then
    raise exception '0337 ASSERT (d) FAIL: % composition(s) of the fleet-speed leaf (want exactly 1)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_translate_player_formation(e.id', '')))
         / length('public.combat_translate_player_formation(e.id');
  if v_n <> 1 then
    raise exception '0337 ASSERT (d) FAIL: % rigid translate(s) in the tick (want exactly 1 — the fleet moves as ONE body, once per tick)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.fleet_set_in_space(e.fleet_id', '')))
         / length('public.fleet_set_in_space(e.fleet_id');
  if v_n <> 1 then
    raise exception '0337 ASSERT (d) FAIL: % fleet-position write(s) in the tick (want exactly 1)', v_n;
  end if;
  -- the step asks the ENGINE'S step primitive, with both ranges zero, rather than clamping by hand
  if position('public.combat_unit_decide_move(v_rp_ax, v_rp_ay, 0, v_rp_speed, v_rp_x, v_rp_y, 0)' in v_code) = 0 then
    raise exception '0337 ASSERT (d) FAIL: the reposition step does not compose combat_unit_decide_move — a second step/clamp rule has been hand-rolled';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_unit_decide_move(', '')))
         / length('public.combat_unit_decide_move(');
  if v_n <> 2 then
    raise exception '0337 ASSERT (d) FAIL: % use(s) of the movement leaf (want exactly 2: the per-unit mover and the fleet step)', v_n;
  end if;
  -- ONE delta, spent on the formation, the marker and the anchor alike
  if position('v_rp_tx - v_rp_ax, v_rp_ty - v_rp_ay' in v_code) = 0 then
    raise exception '0337 ASSERT (d) FAIL: the translate does not use the step''s own delta — the ring can drift off the anchor';
  end if;
  -- no hand-rolled distance/normalisation anywhere in the step
  if position('sqrt(' in v_code) > 0 then
    raise exception '0337 ASSERT (d) FAIL: inline geometry (sqrt) appeared in the tick — distance has exactly one authority';
  end if;
  -- arrival consumes the order, in the SAME statement that spends the step
  if position('reposition_x = case when v_rp_done then null else reposition_x end' in v_code) = 0 then
    raise exception '0337 ASSERT (d) FAIL: arrival does not consume the order';
  end if;
end $d$;

-- (e) the per-unit position write is FENCED for the player side while an order stands
do $e$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'update combat_units set pos_x = v_new_x', '')))
         / length('update combat_units set pos_x = v_new_x');
  if v_n <> 1 then
    raise exception '0337 ASSERT (e) FAIL: % per-unit position write(s) (want exactly 1 — a second one would escape the fence)', v_n;
  end if;
  if position('if not (v_ur.side = ' || chr(39) || 'player' || chr(39) || ' and v_rp_live) then' in v_code) = 0 then
    raise exception '0337 ASSERT (e) FAIL: the per-unit position write is not fenced — the fleet step and the per-unit mover would both write the player side';
  end if;
  if position('if not (v_ur.side = ' || chr(39) || 'player' || chr(39) || ' and v_rp_live) then' in v_code)
     > position('update combat_units set pos_x = v_new_x' in v_code) then
    raise exception '0337 ASSERT (e) FAIL: the fence sits AFTER the write it is meant to guard';
  end if;
  -- the fence names the player explicitly, so the enemy side can never be silenced by it
  if position('v_rp_live := v_is_spatial and e.reposition_x is not null and e.status = ' || chr(39) || 'active' || chr(39) in v_code) = 0 then
    raise exception '0337 ASSERT (e) FAIL: v_rp_live is not derived from the encounter''s own live order';
  end if;
end $e$;

-- (f) the stale-destination fence is a FRESH read, not the loop record
do $f$
declare v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('where ce.id = e.id and ce.status = ' || chr(39) || 'active' || chr(39) in v_code) = 0 then
    raise exception '0337 ASSERT (f) FAIL: the reposition step does not re-read the encounter status — a retreat armed earlier in THIS tick (0310''s auto-exit) would move the fleet anyway, which is the stale-destination defect this class always produces';
  end if;
  -- and the OTHER admission condition is asked at the moment of moving too, not only at order time
  if position('join fleets f on f.id = ce.fleet_id and f.location_mode = ' || chr(39) || 'space' || chr(39) in v_code) = 0 then
    raise exception '0337 ASSERT (f) FAIL: the step does not re-check that the fleet is in open space — it composes fleet_set_in_space, which nulls current_location_id, and a fleet that became ''present'' after the order would be silently un-docked by the mover';
  end if;
  -- and it is confined, so a movement defect can never void the fight (0310's lesson)
  if position('reposition step skipped for encounter' in regexp_replace(v_code, chr(10), ' ', 'g')) = 0 then
    raise exception '0337 ASSERT (f) FAIL: the reposition step is not confined — a raise here would roll back the whole tick every 3 seconds, silently';
  end if;
  -- a reposition is NEVER a retreat: the step must not touch the retreat authority or its state
  if position('presence_request_leave(e.presence_id)' in substr(v_code, position('v_rp_done' in v_code))) > 0 then
    raise exception '0337 ASSERT (f) FAIL: the reposition step reaches the retreat authority — presence_request_leave is the sole retreat authority and a move is not a retreat';
  end if;
end $f$;

-- (g) metadata parity: both functions changed BODY and nothing else
do $g$
declare r record;
begin
  for r in
    select b.fname, b.body_md5, b.owner, b.secdef, b.volatility, b.parallel, b.proconfig,
           b.args, b.result, b.acl,
           md5(p.prosrc) as now_md5, pg_get_userbyid(p.proowner) as now_owner, p.prosecdef as now_secdef,
           p.provolatile as now_vol, p.proparallel as now_par,
           coalesce(array_to_string(p.proconfig, ','), '') as now_cfg,
           pg_get_function_identity_arguments(p.oid) as now_args,
           pg_get_function_result(p.oid) as now_result,
           coalesce(p.proacl::text, '') as now_acl
      from _0337_before b
      join pg_proc p on p.proname = b.fname
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  loop
    if r.body_md5 = r.now_md5 then
      raise exception '0337 ASSERT (g) FAIL: public.% body is UNCHANGED — the rewrite did nothing', r.fname;
    end if;
    if r.owner is distinct from r.now_owner or r.secdef is distinct from r.now_secdef
       or r.volatility is distinct from r.now_vol or r.parallel is distinct from r.now_par
       or r.proconfig is distinct from r.now_cfg or r.args is distinct from r.now_args
       or r.result is distinct from r.now_result or r.acl is distinct from r.now_acl then
      raise exception '0337 ASSERT (g) FAIL: public.% changed more than its body (owner/secdef/volatility/parallel/search_path/signature/result/ACL)', r.fname;
    end if;
  end loop;
end $g$;
`;

const argv = process.argv.slice(2);
if (SQL.includes('\r')) throw new Error('refusing to emit a CR — the generated SQL must be LF-only');

if (argv.includes('--check')) {
  const onDisk = readFileSync(OUT, 'utf8').replace(/\r\n/g, '\n');
  if (onDisk !== SQL) {
    console.error(`${OUT} has DRIFTED from gen-0337-reposition-is-a-move.mjs. Regenerate it.`);
    process.exit(1);
  }
  console.log('gen-0337 --check: the migration on disk matches the generator exactly.');
} else {
  writeFileSync(OUT, SQL);
  console.log(`wrote ${OUT} (${SQL.length} chars)`);
}
