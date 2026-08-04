#!/usr/bin/env node
// gen-0339-a-fight-you-can-move-in.mjs — emit (or --check) migration 0339.
//
// WHY A GENERATOR: 0339 rewrites hunks inside THREE live plpgsql bodies — process_combat_ticks
// (73k chars live, surgery-assembled), command_ship_group_go and combat_create_encounter. No
// migration file holds any of them whole, so every `old_t` below is SLICED VERBATIM out of the
// migration that owns the DEPLOYED text of its region, and every `new_t` is DERIVED from that slice
// by edit()/concatenation. Nothing is retyped (the 0303 lesson).
//
//   combat_create_encounter — TEXTUAL head 0301. The else-branch that stamps a site fight on the
//                             location centre is 0301:928-932 verbatim; that is the slice source.
//   process_combat_ticks    — TEXTUAL head 0299; replace-surgery since 0310, 0314, 0317, 0332,
//                             0336, 0337, 0338. Every region this file touches is text that 0336
//                             CREATED (the two spawn arms) or that 0337 CREATED (the reposition
//                             step) — and where 0338 later edited two lines INSIDE 0336's text, the
//                             deployed string is reconstructed here by applying 0338's own
//                             substitution to 0336's own emitted text. Never retyped, never guessed.
//   command_ship_group_go   — TEXTUAL head 0330; the reposition arm's deployed text is 0337's own
//                             emitted hunk, so that is the slice source.
//
//   node scripts/gen-0339-a-fight-you-can-move-in.mjs          # write the migration
//   node scripts/gen-0339-a-fight-you-can-move-in.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000339_a_fight_you_can_move_in.sql');
const SELF = '20260618000339';

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR. A `\r` baked into a
// sliced hunk can NEVER match the deployed body and the production deploy fails at apply time.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECKS: establish that the files sliced below really own the deployed text. ─────────────
// Two detectors over comment-stripped text (the gen-0336/0337 shape): a later TEXTUAL re-create
// makes the slice source stale outright; a later HUNK ROW — the house `(idx, 'fname',` shape —
// means somebody surgically edited the body and a new slice must not be cut without reading that
// migration. Later rewriters are exempted BY NAME, never by widening the version window, so the
// gate stays live for 0340 and everything after it.
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
  // Every later surgeon of the tick is named. 0336 CREATED the two spawn arms this file folds and
  // 0337 CREATED the reposition step it rewrites, so both are not merely exempted — they are the
  // slice SOURCES, and drift in either fails at the slice fences below rather than here. 0338
  // edited exactly two lines inside 0336's spawn text and this file reconstructs that edit from
  // 0338's own hunk rows, so the same is true of it. 0310/0314/0317/0332 own regions this file
  // never reads.
  guard('process_combat_ticks', '20260618000299',
    new Set(['20260618000310', '20260618000314', '20260618000317', '20260618000332', '20260618000336',
             '20260618000337', '20260618000338']));
  // 0337 owns the deployed text of the reposition arm inside the mover, and is the slice source.
  guard('command_ship_group_go', '20260618000330', new Set(['20260618000337']));
  // combat_create_encounter has had NO surgeon since its 0301 head — this slice is the first.
  guard('combat_create_encounter', '20260618000301', new Set());
}

const F301 = load('20260618000301_intercept_fires_at_zone_entry.sql');
const F336 = load('20260618000336_combat_engine_repairs.sql');
const F337 = load('20260618000337_reposition_is_a_move.sql');
const F338 = load('20260618000338_enemies_come_from_the_zones_city.sql');

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

/** Slice a hunk BODY out of a generator-style `(idx, 'fn', $hNx$…$hNx$)` row: same fences, then the
 *  dollar-quote tag is peeled off both ends. The tag is asserted, so a re-numbered hunk fails here
 *  rather than silently returning text with a `$h8n$` still glued to it. */
function hunkBody(lines, file, from, to, tag, startsWith, endsWith) {
  const text = slice(lines, file, from, to, startsWith, endsWith);
  const open = new RegExp(`^\\s*\\$${tag}\\$`);
  const close = new RegExp(`\\$${tag}\\$\\)?,?$`);
  const rows = text.split('\n');
  if (!open.test(rows[0])) throw new Error(`${file}:${from} does not open the ${tag} hunk`);
  if (!close.test(rows[rows.length - 1])) throw new Error(`${file}:${to} does not close the ${tag} hunk`);
  rows[0] = rows[0].replace(open, '');
  rows[rows.length - 1] = rows[rows.length - 1].replace(close, '');
  return rows.join('\n');
}

/** Peel a CLOSING dollar-quote tag off the last line of a slice that starts INSIDE a hunk body. The
 *  tag is asserted, so a re-numbered hunk fails here rather than gluing `$h1n$),` into a hunk. */
function stripClose(text, file, at, tag) {
  const close = new RegExp(`\\$${tag}\\$\\)?,?$`);
  const rows = text.split('\n');
  if (!close.test(rows[rows.length - 1])) throw new Error(`${file}:${at} does not close the ${tag} hunk`);
  rows[rows.length - 1] = rows[rows.length - 1].replace(close, '');
  return rows.join('\n');
}

/** Replace `from` with `to` in `base`, demanding `from` occurs EXACTLY once — the parity guard that
 *  lets a reconstructed deployed string be BUILT from slices instead of retyped. */
function edit(base, from, to) {
  const n = base.split(from).length - 1;
  if (n !== 1) throw new Error(`edit(): needle occurs ${n} time(s), want exactly 1: ${JSON.stringify(from)}`);
  return base.replace(from, to);
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// THE SLICES
// ═══════════════════════════════════════════════════════════════════════════════════════════════

// ── combat_create_encounter: the else branch that stamps a site fight on the location CENTRE ─────
const CCE_OLD = slice(F301, '0301', 928, 932,
  '    else', '    end if;');

// ── process_combat_ticks: 0336's declare additions (three of the five die with the fold) ─────────
const DECL_OLD = stripClose(
  slice(F336, '0336', 350, 354,
    'v_ring_radius            double precision;', 'v_slot_y                 double precision;'),
  '0336', 354, 'h1n');

// ── process_combat_ticks: the resolved arm's DUPLICATED extent measurement + slot init ───────────
const EXT_OLD = slice(F336, '0336', 460, 479,
  '0336 THE EXTENT THE WAVE MUST STAND CLEAR OF', 'v_spawn_slot := 0;');

// ── process_combat_ticks: the two spawn loops, AS DEPLOYED. 0336 emitted them; 0338 then replaced
// ── the two-line combat_formation_point select inside each. Both edits are reconstructed here from
// ── 0338's OWN hunk rows, so the reconstruction is exact by construction.
const H338_1O = hunkBody(F338, '0338', 252, 253, 'h1o',
  'select fp.x, fp.y into v_slot_x, v_slot_y', 'combat_formation_point(');
const H338_1N = hunkBody(F338, '0338', 254, 277, 'h1n',
  '0338 THE WAVE ARRIVES FROM THE ZONE', 'combat_wave_arrival_phase(');
const H338_2O = hunkBody(F338, '0338', 279, 280, 'h2o',
  'select fp.x, fp.y into v_slot_x, v_slot_y', 'combat_formation_point(');
const H338_2N = hunkBody(F338, '0338', 281, 304, 'h2n',
  '0338 THE WAVE ARRIVES FROM THE ZONE', 'combat_wave_arrival_phase(');

const SPAWN_RESOLVED_OLD = edit(
  hunkBody(F336, '0336', 495, 535, 'h8n',
    '0336 THE WAVE SPAWNS ON A RING', 'end loop;'),
  H338_1O, H338_1N);

const SPAWN_SYNTHETIC_OLD = edit(
  hunkBody(F336, '0336', 550, 608, 'h9n',
    '0336 THE WAVE SPAWNS ON A RING', 'end loop;'),
  H338_2O, H338_2N);

// ── command_ship_group_go: 0337's reposition arm, from the `declare` to the `end if;` that closes
// ── the admission. The surrounding `if v_enc.status = 'active' then` / `end;` / `end if;` are left
// ── in place, so the arm's position between the admission and the retreat arms cannot move.
const ORDER_OLD = slice(F337, '0337', 307, 362,
  '        declare', '          end if;');

// ── process_combat_ticks: 0337's reposition step, from its two-conditions comment to the anchor
// ── restamp. Everything above (the header comment, the declare block) and below (the anchor locals,
// ── the confinement handler) is untouched.
const STEP_OLD = slice(F337, '0337', 459, 492,
  'THE SAME TWO CONDITIONS THE ORDER ARM ADMITTED ON', 'where id = e.id;');

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// THE REPLACEMENTS
// ═══════════════════════════════════════════════════════════════════════════════════════════════

const CCE_NEW = `    else
      -- ██ 0339 A FIGHT AT A SITE STANDS OFF THE SITE, FACING IT ██
      -- The owner, playing the live game: "The enemy ships are not comming out from the location -
      -- snare." They were right, and 0338 could never have worked on a hunt. THE MEASURED CAUSE,
      -- read off the deployed bodies: a hunt arrival leaves the fleet 'present', so THIS branch
      -- stamped the engagement point on the SITE'S OWN COORDINATES; the tick then resolved
      -- v_anchor := coalesce(e.engagement_x, loc.x) (0299:477-478) with both operands the same
      -- point; and combat_wave_arrival_phase hit its equality guard and answered the neutral 0.5.
      -- Every hunt therefore laid its raiders out on a plain ring, permanently. The ambush path
      -- only ever worked because the resolver parks the fleet in open space first.
      -- THE ROOT CAUSE IS ONE DATUM DOING TWO JOBS: locations.x/y was simultaneously WHERE THE
      -- FIGHT IS and WHERE THE ENEMY COMES FROM. No work inside the arrival leaf can separate
      -- those, which is why the leaf is correct and is not touched. The ANCHOR moves instead.
      -- ONE LEAF, ONE ANSWER: combat_site_standoff_point says where a fight AT a site stands — on
      -- the edge of that site's own territory_radius (0217), the datum the world already carries
      -- for "how far out does this place reach", on a bearing hashed from the presence so two
      -- fleets hunting one site do not stack. 0301's rule survives sharper, not broken: a fight
      -- happens where its fleet is, and a fleet present at a location fights on that location's
      -- edge, facing it.
      -- FAIL CLOSED, TO TODAY'S BEHAVIOUR: a site with no territory radius has no edge to stand
      -- off, so the leaf answers the centre and the wave falls back to 0336's ring exactly as it
      -- does now; a vanished location yields no row at all and both coordinates stay NULL, which
      -- is the shape the creator has always produced in that case.
      select p.x, p.y into v_eng_x, v_eng_y
        from locations l
        cross join lateral public.combat_site_standoff_point(l.x, l.y, l.territory_radius, p_presence) p
       where l.id = pr.location_id;
    end if;`;

const DECL_NEW = `  v_ring_radius            double precision;
  v_spawn_slot             integer;`;

const EXT_NEW = `            -- ██ 0339 THE MEASUREMENT MOVED INTO THE SPAWN AUTHORITY ██
            -- 0336's extent measurement stood here AND, character for character bar its indentation,
            -- in the synthetic arm below. Two copies of one measurement is how the two arms drift.
            -- It now lives once, inside combat_spawn_wave_units, beside the radius that consumes it.
            -- v_spawn_slot survives in the TICK because it is the one piece of state the fold cannot
            -- own: the resolved arm carries it ACROSS plan archetypes, so a plan of several unit
            -- types still lays out one ring instead of restarting at slot 0 per archetype.
            v_spawn_slot := 0;`;

const SPAWN_RESOLVED_NEW = `              -- ██ 0339 ONE SPAWN AUTHORITY — THE LOOP WAS WRITTEN TWICE ██
              -- This block and the synthetic arm below were the SAME ~15 lines at two indentations:
              -- measure the formation extent, zero the slot, loop the count, ask combat_formation_point
              -- at (extent + range + 1) on combat_wave_arrival_phase's bearing, INSERT, bump the slot.
              -- Every migration since 0299 had to patch both in lockstep, and most of 0338's guard
              -- machinery existed only to police the fork (it counts the leaf composition twice and the
              -- radius twice, because there were two). Spaghetti. Folded, not written up.
              -- WHAT LEGITIMATELY DIFFERS BETWEEN THE ARMS SURVIVES, AND IT IS THE STATS: this arm
              -- takes unit_type_id, hp, power, range and speed from the AUTHORED PLAN's archetype; the
              -- synthetic arm derives them from loc.base_difficulty and the knobs. Those are arguments.
              -- The PLACEMENT never differed at all, so there is now one of it.
              -- The radius, the phase, the measured extent and 0336's clearance invariant are carried
              -- into the leaf unchanged — this fold moves no geometry, no knob and no value.
              v_spawn_slot := public.combat_spawn_wave_units(
                e.id, e.player_id, v_weapon->>'unit_type_id', v_enemy_count, v_enemy_unit_hp,
                v_enemy_speed, v_enemy_range, v_enemy_proj_speed, v_enemy_unit_power, v_enemy_cooldown,
                v_anchor_x, v_anchor_y, loc.x, loc.y, v_spawn_slot);`;

const SPAWN_SYNTHETIC_NEW = `          -- ██ 0339 ONE SPAWN AUTHORITY — THE LOOP WAS WRITTEN TWICE ██
          -- The other half of the fork. Identical to the resolved arm above bar its indentation and
          -- the STATS, which are the real difference and are passed as arguments: this arm derives
          -- them from loc.base_difficulty and the knobs, the resolved arm from the authored plan.
          -- The slot counter still starts at 0 here because a synthetic wave is one archetype.
          v_spawn_slot := 0;
          v_spawn_slot := public.combat_spawn_wave_units(
            e.id, e.player_id, 'pirate_synthetic', v_enemy_count, v_enemy_unit_hp,
            v_enemy_speed, v_enemy_range, v_enemy_proj_speed, v_enemy_unit_power, v_enemy_cooldown,
            v_anchor_x, v_anchor_y, loc.x, loc.y, v_spawn_slot);`;

const ORDER_NEW = `        declare
          v_rz_admits  boolean := false;
          v_rz_spatial boolean := false;
        begin
          -- FENCED: this RPC never raises at its boundary (the 0301 posture), and the admission
          -- puts a PostGIS read under every mid-combat order — including site fights that
          -- previously touched no geometry. A geometry failure must never break the retreat:
          -- it reads as "not an in-region move" and falls through.
          begin
            v_rz_admits := public.combat_encounter_admits_point(v_enc.id, v_t_x, v_t_y);
          exception when others then
            v_rz_admits := false;
          end;
          if v_rz_admits then
            -- ██ 0339 THE OWNER: "when fighting, i am not able to move my fleet." ██
            -- They were right, and a HUNT fight could never reposition — by construction, and the
            -- same button silently RETREATED instead. The arm demanded THREE things: an active
            -- encounter, a zone holding both anchor and destination, and fleets.location_mode =
            -- 'space'. A hunt fight is 'present' at its site and its site need not sit inside any
            -- drawn zone, so the last two both failed, control fell through to the retreat arms
            -- below, and the player who asked to MOVE got ok:true / retreat_started. They broke off
            -- a fight they were trying to manoeuvre in.
            --
            -- THE ZONE CONDITION IS NOT DROPPED, IT IS GENERALISED. The owner's law is that only an
            -- order OUT of the region breaks combat. A hunt site is not in a zone but it carries the
            -- same shape of boundary already — its territory_radius — so the admission is now ONE
            -- authority over both region kinds: combat_encounter_admits_point composes 0311's zone
            -- answer UNCHANGED (still quantified over every anchor-holding zone, never choosing one)
            -- and adds the encounter's own site as the second region. A fight at Snare can be moved
            -- anywhere inside Snare's territory; an order outside it still breaks off, as before.
            --
            -- THE location_mode CONDITION IS GONE BECAUSE ITS REASON IS GONE. 0337 kept reposition
            -- open-space-only because the TICK's step composed fleet_set_in_space — which writes
            -- status='idle' and current_location_id=null (0231:1146-1170) — and its interaction with
            -- a live 'present' location_presence was UNVERIFIED. Verified now, from that deployed
            -- body: it WOULD strand the presence against an idle, placeless fleet while the tick ran
            -- on. So the step no longer calls it on a present fleet at all: the marker is written
            -- through combat_fleet_track_position, which composes fleet_set_in_space only while the
            -- fleet's position is EXPRESSED in space. Un-docking is impossible by construction, so
            -- the gate that existed to prevent it is deleted rather than carried as a superstition.
            select exists (select 1 from public.combat_units cu
                            where cu.encounter_id = v_enc.id and cu.pos_x is not null)
              into v_rz_spatial;
            if not v_rz_spatial then
              -- ██ 0339 THE PHANTOM MOVE, REFUSED HONESTLY RATHER THAN RECLASSIFIED ██
              -- The order arm never checked the fight had GEOMETRY, but the tick's reposition step
              -- lives inside the v_is_spatial arm. On a non-spatial encounter the columns were
              -- written, 'repositioning' was returned, the client printed "Moving to (x,y)" — and
              -- nothing ever moved and the order was never consumed.
              -- WHY A REFUSAL AND NOT AN ADMISSION FAILURE: "move here" has exactly three honest
              -- answers — it repositions; the destination is outside the fight's region so it IS a
              -- break-off order; or the engine cannot move this fight at all. Folding spatiality
              -- into the admission would give answer two to situation three, which is the silent
              -- reclassification this slice exists to end. Nothing is written on this path.
              -- Unreachable in production today (spatial_combat_enabled is on and mode is sticky per
              -- encounter at creation), so this takes no live capability from anyone.
              return jsonb_build_object(
                'ok', false,
                'order_outcome', 'reposition_needs_positions',
                'outcome', 'reposition_needs_positions',
                'reason', 'reposition_needs_positions',
                'group_id', v_group,
                'fleet_id', v_enc.fleet_id,
                'encounter_id', v_enc.id,
                'presence_id', v_enc.presence_id,
                'member_count', v_member_n,
                'destination_location_id', p_location_id,
                'destination_x', v_t_x,
                'destination_y', v_t_y);
            end if;
            -- THE ONE WRITE. Not three. The fleet row is NOT touched, the formation is NOT
            -- translated and the anchor is NOT restamped here — every one of those belongs to the
            -- tick, applied a step at a time as the fleet actually covers the ground (0337).
            -- Deliberately still NO movement_create: a leg would put the fleet back to 'moving' (a
            -- state step 7 and the tick both assume it is not in mid-fight) and would re-roll an
            -- ambush inside the region it is already fighting in.
            update public.combat_encounters
               set reposition_x = v_t_x, reposition_y = v_t_y, updated_at = v_now
             where id = v_enc.id;
            return jsonb_build_object(
              'ok', true,
              -- 'repositioning', NOT 'repositioned'. The fleet has not arrived; it has been
              -- given a course. A success token that announces an arrival nothing has performed
              -- is the teleport surviving in the UI.
              'order_outcome', 'repositioning',
              'outcome', 'repositioning',
              'reason', 'repositioning',
              'group_id', v_group,
              'fleet_id', v_enc.fleet_id,
              'encounter_id', v_enc.id,
              'presence_id', v_enc.presence_id,
              'member_count', v_member_n,
              'destination_location_id', p_location_id,
              'destination_x', v_t_x,
              'destination_y', v_t_y);
          end if;`;

const STEP_NEW = `        -- THE SAME CONDITIONS THE ORDER ARM ADMITTED ON, ASKED AGAIN AT THE MOMENT OF MOVING.
        -- 'active' is the stale-destination fence described above: a retreat armed a few lines up
        -- (0310's auto-exit) has ALREADY flipped this row, so the select returns nothing and the
        -- fleet holds. Fail closed: no row, no move, the order simply stands.
        -- ██ 0339 THE location_mode = 'space' JOIN CONDITION IS GONE ██ It existed for exactly one
        -- reason: this step composed fleet_set_in_space, which writes status='idle' and
        -- current_location_id=null (0231:1146-1170), so a fleet that became 'present' would have
        -- been silently un-docked by the mover — 0337 said so and called the interaction UNVERIFIED.
        -- It is verified, and it would indeed have stranded the presence. So the step no longer
        -- calls that primitive directly: combat_encounter_move composes combat_fleet_track_position,
        -- which writes the marker only while the fleet's position is EXPRESSED in space. The hazard
        -- is impossible by construction, and a HUNT fight — 'present' at its site, which is every
        -- fight the owner opens deliberately — can finally be manoeuvred in. That is the ask.
        select ce.reposition_x, ce.reposition_y, ce.engagement_x, ce.engagement_y
          into v_rp_x, v_rp_y, v_rp_ax, v_rp_ay
          from combat_encounters ce
          join fleets f on f.id = ce.fleet_id
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
            -- ██ 0339 ONE AUTHORITY FOR "WHERE THIS FIGHT STANDS" ██
            -- 0301:820 declared the creator's INSERT "the only write of engagement_x/engagement_y in
            -- the database" and shipped a schema sweep to enforce it (0301:2556-2566). 0337 then put
            -- exactly that write HERE — and the 0301 assert does not re-run, so the drift landed
            -- silently. A stated invariant with no live check is not an invariant.
            -- combat_encounter_move is that authority: ONE delta spent on the formation, the fleet
            -- marker and the anchor together, so the three can never disagree about where the fight
            -- is, and the sweep is re-armed (0339 assert (b) + DZCOMBAT_PASS_ONEANCHOR) demanding
            -- that this leaf is the only function in the schema that sets the column.
            perform public.combat_encounter_move(e.id, e.fleet_id, v_rp_tx, v_rp_ty, v_rp_ax, v_rp_ay);
            -- ARRIVAL CONSUMES THE ORDER, in the statement that spends the step. Separate from the
            -- move above on purpose: where the fight STANDS and what it has been ORDERED to do are
            -- two concepts, and the leaf owns exactly one of them.
            update combat_encounters
               set reposition_x = case when v_rp_done then null else reposition_x end,
                   reposition_y = case when v_rp_done then null else reposition_y end,
                   updated_at   = now()
             where id = e.id;`;

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// THE MIGRATION
// ═══════════════════════════════════════════════════════════════════════════════════════════════

// ── HUNK ORDER IS LOAD-BEARING, AND CI PROVED IT ────────────────────────────────────────────────
// Each row is applied with its own CREATE OR REPLACE, so EVERY INTERMEDIATE BODY must compile —
// plpgsql validates variable references at creation time. The first cut of this file removed the
// three dead locals (v_formation_extent, v_slot_x, v_slot_y) FIRST, while the spawn arms below still
// referenced them, and the disposable apply-proof rejected the whole chain with
// `"v_formation_extent" is not a known variable (SQLSTATE 42601)`. Nothing static could have caught
// that: the FINAL body is perfectly valid, and every self-assert in this migration inspects the
// final body. It is the apply-proof, and only the apply-proof, that runs the intermediate ones.
// So the DECLARE removal is LAST, after the two spawn folds have deleted the last use of all three.
const HUNKS = [
  ['h1', 'combat_create_encounter', CCE_OLD, CCE_NEW],
  ['h2', 'process_combat_ticks', EXT_OLD, EXT_NEW],
  ['h3', 'process_combat_ticks', SPAWN_RESOLVED_OLD, SPAWN_RESOLVED_NEW],
  ['h4', 'process_combat_ticks', SPAWN_SYNTHETIC_OLD, SPAWN_SYNTHETIC_NEW],
  ['h5', 'process_combat_ticks', DECL_OLD, DECL_NEW],
  ['h6', 'command_ship_group_go', ORDER_OLD, ORDER_NEW],
  ['h7', 'process_combat_ticks', STEP_OLD, STEP_NEW],
];

const hunkRows = HUNKS.map(([tag, fn, oldT, newT], i) =>
  `    (${i + 1}, '${fn}',\n     $${tag}o$${oldT}$${tag}o$,\n     $${tag}n$${newT}$${tag}n$)`).join(',\n');

const SQL = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0339 — A FIGHT YOU CAN MOVE IN
--        the enemy comes out of the city on a HUNT too, the fleet can manoeuvre at a site, and it
--        does so fast enough to see — plus the two pieces of spaghetti that made all three hard
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- GENERATED BY scripts/gen-0339-a-fight-you-can-move-in.mjs — DO NOT HAND-EDIT.
-- Regenerate with \`node scripts/gen-0339-a-fight-you-can-move-in.mjs\`; the parity gate in
-- scripts/danger-combat-proof.sh runs \`--check\` and fails if this file drifted from the generator.
-- The full composition decision record is docs/SLICE_0339_A_FIGHT_YOU_CAN_MOVE_IN.md.
--
-- ── THE TWO REPORTS, VERBATIM ────────────────────────────────────────────────────────────────────
--   "The enemy ships are not comming out from the location - snare."
--   "when fighting, i am not able to move my fleet"
-- Both correct. Both traced to a cause MEASURED off the deployed bodies rather than guessed.
--
-- ── (1) SPAGHETTI: TWO WRITERS OF ONE COLUMN, AND THE GUARD WAS SPENT ────────────────────────────
-- 0301:820 declares the creator's INSERT "the only write of engagement_x/engagement_y in the
-- database" and 0301:2556-2566 sweeps every function in the schema for \`set engagement_x\`, raising
-- if it finds one. 0337:486-492 then added exactly that write inside process_combat_ticks. THE 0301
-- ASSERT DOES NOT RE-RUN, so the drift landed silently and has been live ever since.
-- RESOLVED: combat_encounter_move is the ONE authority for "where this fight stands" — it spends one
-- delta on the player formation, the fleet marker and the anchor together, because a fight that
-- moves one without the others is three positions disagreeing. The creator's INSERT still
-- ESTABLISHES an anchor; this leaf is the only thing that ever CHANGES one.
-- AND THE GUARD IS RE-ARMED WHERE IT ACTUALLY RE-RUNS: assert (b) below re-runs on every apply of
-- the chain (which in this repo is every CI \`supabase start\`), and DZCOMBAT_PASS_ONEANCHOR re-runs
-- the same sweep against the fully-applied chain on every pull_request and every push to main.
-- Stated honestly: this is a CI-time guard, not a runtime one. A BEFORE UPDATE trigger on
-- combat_encounters would enforce it on production forever and was REJECTED for this slice — a
-- raise inside it fires on every encounter update of a live 30-player game, which is a worse blast
-- radius than the drift it prevents.
--
-- ── (2) SPAGHETTI: THE ENEMY-SPAWN LOOP WAS WRITTEN TWICE ────────────────────────────────────────
-- 0338:252-253 (resolved-plan arm) and 0338:279-280 (synthetic arm) are the same ~15 lines at two
-- indentations. Every migration since 0299 has had to patch both in lockstep, and most of 0338's
-- guard machinery exists only to police the fork — its assert (b) counts the arrival leaf twice and
-- the radius expression twice because there are two of each.
-- RESOLVED: combat_spawn_wave_units owns the placement — the measured extent, 0336's radius, the
-- formation point, 0338's arrival phase, the INSERT and the slot walk. Each arm is now ONE call.
-- WHAT LEGITIMATELY DIFFERS SURVIVES: the STATS. The resolved arm's come from the authored plan's
-- archetype, the synthetic arm's from loc.base_difficulty and the knobs. Those are the arguments.
-- The placement never differed at all. v_spawn_slot stays in the tick because the resolved arm
-- carries it ACROSS archetypes, which is the one piece of state the fold cannot own.
--
-- ── (3) THE ENEMY DOES NOT COME OUT OF SNARE — AND 0338 COULD NEVER HAVE MADE IT ─────────────────
-- MEASURED CAUSE: a hunt arrival leaves the fleet 'present', so 0301:924-933 takes the else branch
-- and stamps engagement_x/y on THE SITE'S OWN COORDINATES; the tick then resolves
-- v_anchor := coalesce(e.engagement_x, loc.x) (0299:477-478) with both operands the same point;
-- combat_wave_arrival_phase hits its equality guard (0338:199) and returns the neutral 0.5. Every
-- hunt therefore lays its raiders out on a plain 225-degree ring instead of a 112.5-degree arc from
-- the city. Permanently. The ambush path works only because the resolver parks the fleet in space.
-- ROOT CAUSE: ONE DATUM DOING TWO JOBS — locations.x/y is at once WHERE THE FIGHT IS and WHERE THE
-- ENEMY COMES FROM. The leaf is correct; the ANCHOR is what is wrong.
-- RESOLVED: combat_site_standoff_point is the ONE answer to "where does a fight AT a site stand" —
-- on the edge of that site's own territory_radius (0217), on a bearing hashed from the presence so
-- two fleets hunting one site do not stack. Composed by combat_create_encounter's else branch and
-- by nothing else: no inline branch in the tick, no second spawn path.
-- AND THE EXACT FLOAT EQUALITY AT 0338:199 IS FIXED. A fight one ulp off the site computed a REAL
-- bearing from a sub-unit displacement — an arbitrary direction that flips with the last bit of a
-- subtraction. It is now a separation test against HALF A WORLD UNIT: ordered coordinates are
-- canonicalized onto the integer world grid before anything reads them, so below half a cell the
-- fight and the site are the same place at the resolution the world stores, and any bearing taken
-- from less than that is float noise rather than a direction.
--
-- ── (4) YOU COULD NOT MOVE YOUR FLEET, AND THE BUTTON RETREATED INSTEAD ──────────────────────────
-- The reposition arm required an ACTIVE encounter, a zone holding both anchor and destination, and
-- fleets.location_mode='space'. A hunt fight is 'present' and its site need not be inside any drawn
-- zone, so the last two both failed and control fell through to the 0298 retreat arms, which
-- answered ok:true / retreat_started. The player asked to move and broke off the fight.
-- RESOLVED, NOT REFUSED. combat_encounter_admits_point is ONE admission over BOTH region kinds: it
-- composes 0311's zone answer unchanged (still quantified over every anchor-holding zone) and adds
-- the encounter's own site territory. The owner's law is untouched — only an order OUT of the region
-- breaks combat — it is now stated once for a zone and a site alike.
-- The location_mode gate is DELETED because its reason is gone: 0337 kept reposition open-space-only
-- because the step composed fleet_set_in_space, which writes status='idle' and
-- current_location_id=null (0231:1146-1170) and would have stranded a live presence. VERIFIED, and
-- true. So the step no longer calls it on a present fleet: combat_fleet_track_position writes the
-- marker only while the fleet's position is EXPRESSED in space. The hazard is impossible by
-- construction, so the superstition it left behind is removed rather than carried.
-- AND THE LATENT PHANTOM IS CLOSED: an admitted order on a NON-SPATIAL encounter used to write the
-- columns, answer 'repositioning' and never move anything, because the tick's step lives inside
-- \`if v_is_spatial then\`. It is now an explicit typed refusal that writes nothing —
-- 'reposition_needs_positions' — never a silent reclassification into a retreat.
--
-- ── (5) THE MOVE IS PERCEPTIBLE, AND docs/DEV_LOG.md NAMES THE WRONG KNOB ────────────────────────
-- Player reposition was 0.16-0.26 world units per 3s tick — about 1/16 px at playable zoom, ~6
-- minutes to cross 20 units, against pirates moving 1.0-1.6 (4-10x faster).
-- DEV_LOG:259-262 says the fix is "ONE knob: combat_player_speed_scale". IT IS NOT, and this slice
-- does not follow it: 0316:761-765 (invariant f7) requires enemy_slowest >= 2 * max(base_speed) *
-- that scale, which caps it at ~0.38 — under 2x — and raising it also speeds every per-unit CLOSE
-- and KITE decision, which is exactly how a player kites a pirate out of the fight. Wrong lever
-- twice. The DEV_LOG line is corrected in this slice.
-- THE RIGHT LEVER ALREADY EXISTED: combat_fleet_move_speed (0337:133-145) is a dedicated leaf with
-- EXACTLY ONE reader — the tick's reposition step — asserted unique at 0337:674-678. The new knob
-- combat_reposition_speed_scale (default 8.0) scales ONLY that leaf, so ordered repositions get
-- faster and the per-unit close/kite economy f7 protects is untouched.
-- THE NUMBERS: an ordered fleet now covers 1.28-2.08 per tick, so a 20-unit reposition takes 10-16
-- ticks = 30-48 SECONDS, against 77-125 ticks = 4-6 minutes today.
-- THE BALANCE CONSEQUENCE, STATED RATHER THAN SMUGGLED: pirates move 1.0-1.6, so the fastest fleets
-- can slightly OUT-PACE the slowest raiders while an order stands. Three things bound it and none is
-- a hope: the destination must be inside the fight's own region, so a reposition can never leave the
-- fight (an order outside it is a retreat, with the retreat's damage window); the enemy side is
-- NEVER fenced, so pirates close on the fleet's new position every tick through the same leaf they
-- always did; and the order is consumed on arrival, after which the fleet reverts to its per-unit
-- speed. A negative or missing knob folds to hold-still or the shipped default. Fail closed.
--
-- ── BLAST RADIUS ON THE LIVE GAME ────────────────────────────────────────────────────────────────
--   * CREATE OR REPLACE of four functions plus FIVE new leaves and ONE game_config row, in one
--     transaction: an atomic catalog swap. The tick body is read fresh every 3 seconds, so the next
--     tick of every running fight runs the new body. No per-fight opt-in and no drain.
--   * FIGHTS ALREADY IN FLIGHT keep their stamped anchor — nothing rewrites it — so (3) changes only
--     fights created after this deploys. (2) changes where the NEXT wave of any fight lays out: same
--     radius, same count, same stats, same bearing rule; only the code path is folded.
--   * WHAT A PLAYER CAN SEE CHANGE TODAY: a site fight's in-region order answers 'repositioning'
--     instead of 'retreat_started' — that IS the fix — and every reposition ordered after this
--     deploys is ~8x faster. A reposition already in flight picks up the new speed next tick.
--   * NO schema change. NO grant widening: every new leaf is revoked from public, anon and
--     authenticated by ESTABLISHMENT, never by assertion (the 0254 lesson — CI has no project
--     defaults and is structurally blind to a Supabase GRANT ALL).
--   * NO reward, drop, threshold, range, difficulty or enemy-speed value moved. This migration
--     writes exactly ONE game_config row and no other config value anywhere.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed bodies with the seven hunks reverted (0301/0336/0337/0338 text), restore
-- combat_fleet_move_speed to its 0337 body and combat_wave_arrival_phase to its 0338 body, then:
--   drop function public.combat_spawn_wave_units(uuid, uuid, text, integer, double precision,
--     double precision, double precision, double precision, double precision, double precision,
--     double precision, double precision, double precision, double precision, integer);
--   drop function public.combat_encounter_move(uuid, uuid, double precision, double precision, double precision, double precision);
--   drop function public.combat_fleet_track_position(uuid, double precision, double precision);
--   drop function public.combat_encounter_admits_point(uuid, double precision, double precision);
--   drop function public.combat_site_standoff_point(double precision, double precision, numeric, uuid);
--   delete from public.game_config where key = 'combat_reposition_speed_scale';
-- Nothing else to unwind: no combat row, no player state, no other config.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
-- WHAT THESE PROVE: (a) and (b) prove POSTURE and AUTHORITY over the emitted catalog. (c)-(g)
-- EXECUTE the new leaves and prove their behaviour. That the real tick then behaves this way is
-- proven by exactly one layer: the disposable apply-proof driving the REAL tick.
--   (a) the five leaves exist with the right volatility / security / search_path, and NO client role
--       can execute any of them
--   (b) ONE ANCHOR AUTHORITY, RE-ARMED: the 0301 sweep, restored and sharpened — the ONLY function
--       in the schema that sets engagement_x is combat_encounter_move, and the tick composes it
--   (c) ONE SPAWN AUTHORITY: the fork is gone — the tick carries no formation-point call, no INSERT
--       into combat_units on the enemy side and no extent measurement of its own, and it composes
--       the spawn leaf exactly twice (once per arm, which is what a legitimate stat difference costs)
--   (d) THE STANDOFF, EXECUTED: a fight at a site stands exactly territory_radius from it, at a
--       bearing that is stable for one presence and different for another; and it falls back to the
--       site itself — today's behaviour — when there is no radius to stand off
--   (e) THE EPSILON, EXECUTED: a bearing taken from a sub-half-unit displacement falls back to
--       0336's ring, while a real displacement still produces the real bearing
--   (f) THE ADMISSION, EXECUTED: it is a pure RELAXATION of 0311 — every point 0311 admitted is
--       still admitted — and it additionally admits inside the fight's own site territory
--   (g) THE KNOB: the fleet-move leaf scales by it, still reads the living player hulls, still fails
--       closed on an empty encounter, and a 20-unit reposition now takes tens of seconds
--   (h) metadata parity: the four rewritten functions changed BODY and nothing else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
declare
  v_tick text;
  v_go   text;
  v_cce  text;
begin
  if to_regprocedure('public.process_combat_ticks()') is null then
    raise exception '0339 PRECONDITION FAIL: process_combat_ticks is absent';
  end if;
  if to_regproc('public.command_ship_group_go') is null then
    raise exception '0339 PRECONDITION FAIL: command_ship_group_go is absent';
  end if;
  if to_regprocedure('public.combat_create_encounter(uuid)') is null then
    raise exception '0339 PRECONDITION FAIL: combat_create_encounter is absent';
  end if;
  -- the leaves this slice COMPOSES must already exist; it re-implements none of them.
  if to_regprocedure('public.combat_formation_point(double precision, double precision, double precision, integer, double precision)') is null
     or to_regprocedure('public.combat_wave_arrival_phase(double precision, double precision, double precision, double precision, integer)') is null
     or to_regprocedure('public.combat_encounter_zone_admits_point(uuid, double precision, double precision)') is null
     or to_regproc('public.combat_translate_player_formation') is null
     or to_regproc('public.fleet_set_in_space') is null
     or to_regproc('public.combat_fleet_move_speed') is null
     or to_regproc('public.osn_distance') is null then
    raise exception '0339 PRECONDITION FAIL: a composed leaf is absent — this slice re-implements none of them';
  end if;
  -- none of the five new leaves may pre-exist: this slice is the only thing that creates them.
  if to_regproc('public.combat_site_standoff_point') is not null
     or to_regproc('public.combat_encounter_admits_point') is not null
     or to_regproc('public.combat_fleet_track_position') is not null
     or to_regproc('public.combat_encounter_move') is not null
     or to_regproc('public.combat_spawn_wave_units') is not null then
    raise exception '0339 PRECONDITION FAIL: one of this slice''s leaves already exists — 0339 is the only thing that creates them';
  end if;

  select prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_go from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  select prosrc into v_cce from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_encounter';

  -- THE DEFECTS MUST STILL BE THERE. If any of these is already gone, somebody else edited these
  -- bodies and this slice must be re-derived rather than applied blind.
  if position('v_formation_extent + v_enemy_range + 1' in v_tick) = 0 then
    raise exception '0339 PRECONDITION FAIL: the deployed tick does not carry 0336''s measured-extent wave radius — the spawn fold is derived from that exact text';
  end if;
  if position('set engagement_x = v_rp_tx' in v_tick) = 0 then
    raise exception '0339 PRECONDITION FAIL: the deployed tick does not carry 0337''s anchor restamp — the second writer this slice retires is not where it was';
  end if;
  if position('f.location_mode = ''space''' in v_tick) = 0 then
    raise exception '0339 PRECONDITION FAIL: the deployed tick''s reposition step does not carry the open-space-only join — the condition this slice retires is not where it was';
  end if;
  if position('if v_rz_mode = ''space'' then' in v_go) = 0 then
    raise exception '0339 PRECONDITION FAIL: the deployed mover does not carry the open-space-only reposition gate — the defect this slice fixes is not where it was';
  end if;
  if position('select l.x, l.y into v_eng_x, v_eng_y from locations l' in v_cce) = 0 then
    raise exception '0339 PRECONDITION FAIL: combat_create_encounter no longer stamps a site fight on the location centre — the anchor defect is not where it was';
  end if;
end $pre$;

-- ── 1. THE FIVE LEAVES ───────────────────────────────────────────────────────────────────────────
-- Created BEFORE the rewrite so no rewritten body ever references a missing function, and each
-- revoked from every client role in the same step: these are engine internals, not a new surface.
-- The lockdown ESTABLISHES the posture by revoking rather than asserting it — the 0254 lesson, in
-- which a Supabase project-default GRANT ALL to anon aborted a publish migration on its own assert
-- and CI, which has no project defaults, was structurally blind to it.

-- ── 1a. combat_site_standoff_point — THE ONE ANSWER to "where does a fight AT a site stand" ───────
-- On the EDGE of the site's own territory, so the site is a DIRECTION rather than the place you are
-- standing. That is the whole of the owner's "the enemy ships are not comming out from the location":
-- an anchor ON the site leaves combat_wave_arrival_phase nothing to point at.
-- THE BEARING IS HASHED FROM THE PRESENCE, not rolled: the world must be reproducible (the 0041
-- determinism law), two fleets hunting one site must not stack on one point, and the same fight must
-- answer the same way if this is ever recomputed. md5 is IMMUTABLE, so this whole leaf is.
-- FAIL CLOSED TO TODAY'S BEHAVIOUR: no radius, a non-positive radius or a NULL seed means there is no
-- edge to stand off, so it answers the site itself and the wave falls back to 0336's plain ring —
-- exactly what every fight does today. NULL site coordinates stay NULL, which is the shape the
-- creator has always produced for a vanished location.
create or replace function public.combat_site_standoff_point(
  p_site_x  double precision,
  p_site_y  double precision,
  p_radius  numeric,
  p_seed    uuid)
returns table(x double precision, y double precision)
language sql
immutable
set search_path to 'public'
as $fssp$
  select case
           when p_site_x is null or p_site_y is null then p_site_x
           when p_radius is null or p_radius <= 0 or p_seed is null then p_site_x
           else p_site_x + p_radius::double precision * cos(b.theta)
         end,
         case
           when p_site_x is null or p_site_y is null then p_site_y
           when p_radius is null or p_radius <= 0 or p_seed is null then p_site_y
           else p_site_y + p_radius::double precision * sin(b.theta)
         end
    from (select 2 * pi()
                 * (('x' || substr(md5(coalesce(p_seed::text, '')), 1, 8))::bit(32)::bigint)::double precision
                 / 4294967296.0 as theta) b;
$fssp$;

comment on function public.combat_site_standoff_point(double precision, double precision, numeric, uuid) is
  'THE ONE AUTHORITY for "where does a fight AT a site stand" (0339). A fleet present at a location '
  'fights on the EDGE of that location''s territory_radius (0217), at a bearing hashed from the '
  'presence id — deterministic, stable, and different for two fleets at one site. That is what gives '
  'combat_wave_arrival_phase a direction to point at on a HUNT: before it, a hunt anchored on the '
  'site itself, the bearing was undefined and every wave fell back to the plain ring. Answers the '
  'SITE ITSELF (today''s behaviour) when there is no radius to stand off, and NULL for a vanished '
  'site. Composed by combat_create_encounter and by nothing else.';

revoke all on function public.combat_site_standoff_point(double precision, double precision, numeric, uuid) from public;
revoke all on function public.combat_site_standoff_point(double precision, double precision, numeric, uuid) from anon, authenticated;

-- ── 1b. combat_encounter_admits_point — ONE ADMISSION over BOTH kinds of region ──────────────────
-- The owner's law is that only an order OUT of the region breaks combat. 0311 answered that for a
-- DRAWN ZONE and nothing else, which is why a hunt fight — whose site need not sit inside any zone —
-- could never reposition and silently retreated instead. A site carries the same shape of boundary
-- already: its territory_radius. So this composes 0311's answer UNCHANGED (still quantified over
-- every anchor-holding zone, never choosing one) and adds the fight's own site as a second region.
-- A PURE RELAXATION: every point 0311 admitted is still admitted, asserted in (f).
-- INCLUSIVE ON THE SITE ARM, deliberately: after this slice a site fight anchors EXACTLY on
-- territory_radius, and a strict test would refuse the fight its own standing point.
create or replace function public.combat_encounter_admits_point(
  p_encounter uuid,
  p_x         double precision,
  p_y         double precision
) returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fcap$
  select exists (
    select 1
      from public.combat_encounters ce
     where ce.id = p_encounter
       and p_x is not null and p_y is not null
       and ce.engagement_x is not null and ce.engagement_y is not null
       and (
         public.combat_encounter_zone_admits_point(ce.id, p_x, p_y)
         or exists (
           select 1
             from public.locations l
            where l.id = ce.location_id
              and l.status = 'active'
              and l.territory_radius is not null
              and public.osn_distance(l.x, l.y, ce.engagement_x, ce.engagement_y) <= l.territory_radius
              and public.osn_distance(l.x, l.y, p_x, p_y) <= l.territory_radius)));
$fcap$;

comment on function public.combat_encounter_admits_point(uuid, double precision, double precision) is
  'THE one answer to "is this destination an in-REGION move for this fight?" (0339). TRUE iff '
  'combat_encounter_zone_admits_point says so (0311, composed unchanged) OR the encounter''s own '
  'site holds BOTH the fight''s anchor and the destination inside locations.territory_radius. A pure '
  'RELAXATION of 0311: it takes nothing away and it is what lets a HUNT fight — whose site need not '
  'be inside any drawn zone — manoeuvre instead of silently retreating. Inclusive on the site arm '
  'because a site fight anchors exactly ON that radius. FALSE on an unstamped anchor, a NULL point '
  'or no qualifying region — the mover then falls through to the retreat arms: fail closed.';

revoke all on function public.combat_encounter_admits_point(uuid, double precision, double precision) from public;
revoke all on function public.combat_encounter_admits_point(uuid, double precision, double precision) from anon, authenticated;
grant execute on function public.combat_encounter_admits_point(uuid, double precision, double precision) to service_role;

-- ── 1c. combat_fleet_track_position — the map marker follows the fight, WHEN it may ──────────────
-- fleets.space_x/y only MEANS anything while location_mode = 'space' (0301:892-895 states exactly
-- that: fleet_set_present does not clear them, so a docked fleet carries stale coordinates and
-- location_mode is the authoritative discriminator). A fleet PRESENT at a site has its position
-- authored by the presence, and combat does not own it.
-- THIS IS WHAT MAKES A SITE FIGHT MOVABLE. 0337 kept reposition open-space-only because the step
-- composed fleet_set_in_space, which writes status='idle' and current_location_id=null
-- (0231:1146-1170) — it would have left a live location_presence dangling against an idle, placeless
-- fleet while the tick ran the fight on and later called presence_complete against it. 0337 called
-- that interaction UNVERIFIED; it is verified, and it is real. So it is never entered: the marker is
-- written only when the fleet's position is EXPRESSED in space, and fleet_set_in_space remains the
-- ONE writer of fleets.space_x/y.
create or replace function public.combat_fleet_track_position(
  p_fleet uuid,
  p_x     double precision,
  p_y     double precision)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fftp$
begin
  if p_fleet is null or p_x is null or p_y is null then
    return;
  end if;
  if exists (select 1 from public.fleets f where f.id = p_fleet and f.location_mode = 'space') then
    perform public.fleet_set_in_space(p_fleet, p_x, p_y);
  end if;
end;
$fftp$;

comment on function public.combat_fleet_track_position(uuid, double precision, double precision) is
  'THE one answer to "should the fleet marker follow this fight?" (0339): it composes '
  'fleet_set_in_space — still the ONE writer of fleets.space_x/y — if and only if the fleet''s '
  'position is EXPRESSED in space. A fleet PRESENT at a site has its position authored by its '
  'presence, and fleet_set_in_space would clear current_location_id and strand that presence, so '
  'this no-ops instead. That is what lets a hunt fight reposition at all.';

revoke all on function public.combat_fleet_track_position(uuid, double precision, double precision) from public;
revoke all on function public.combat_fleet_track_position(uuid, double precision, double precision) from anon, authenticated;
grant execute on function public.combat_fleet_track_position(uuid, double precision, double precision) to service_role;

-- ── 1d. combat_encounter_move — THE ONE AUTHORITY for "where this fight stands" ──────────────────
-- 0301 declared the creator's INSERT the only write of engagement_x/engagement_y and shipped a
-- schema sweep to enforce it. 0337 added a second writer inside the tick and the sweep did not
-- re-run, so it landed silently. This leaf ends that: the creator ESTABLISHES an anchor, and this is
-- the only thing that ever CHANGES one.
-- ALL THREE, OR NONE. The formation, the marker and the anchor take ONE delta together, because a
-- fight that moves one without the others is three positions disagreeing about where it is — and
-- 0311 already proved that is not hypothetical: it wrote all three by hand, inline, and 0337 had to
-- delete every one of them.
create or replace function public.combat_encounter_move(
  p_encounter uuid,
  p_fleet     uuid,
  p_to_x      double precision,
  p_to_y      double precision,
  p_from_x    double precision,
  p_from_y    double precision)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fcem$
begin
  if p_encounter is null or p_to_x is null or p_to_y is null or p_from_x is null or p_from_y is null then
    return;   -- fail closed: an unstamped fight does not move
  end if;
  -- 1. the formation TRANSLATES rigidly through the ONE translation leaf — never re-seeded, so the
  --    ring the encounter builder laid out survives the journey by construction.
  perform public.combat_translate_player_formation(p_encounter, p_to_x - p_from_x, p_to_y - p_from_y);
  -- 2. the map marker follows, if and only if it may (see combat_fleet_track_position).
  perform public.combat_fleet_track_position(p_fleet, p_to_x, p_to_y);
  -- 3. the anchor restamps. Mandatory: the tick reads it fresh each pass (0299:477-478) and uses it
  --    for every later wave spawn and both retreat-leg origins — without this, wave 2 spawns at the
  --    abandoned point and a later retreat departs from where the fleet is not.
  update public.combat_encounters
     set engagement_x = p_to_x, engagement_y = p_to_y, updated_at = now()
   where id = p_encounter;
end;
$fcem$;

comment on function public.combat_encounter_move(uuid, uuid, double precision, double precision, double precision, double precision) is
  'THE ONE AUTHORITY for "where this fight stands" (0339). Spends ONE delta on the player formation, '
  'the fleet marker and combat_encounters.engagement_x/y together, so the three can never disagree. '
  'It is the ONLY function in the schema that sets engagement_x — 0301 said that of the creator''s '
  'INSERT and shipped a sweep to prove it, 0337 added a second writer, and the sweep did not re-run. '
  'The creator still ESTABLISHES an anchor on INSERT; this leaf is the only thing that changes one. '
  'Composed by the tick''s reposition step and by nothing else. Fail-closed on any NULL.';

revoke all on function public.combat_encounter_move(uuid, uuid, double precision, double precision, double precision, double precision) from public;
revoke all on function public.combat_encounter_move(uuid, uuid, double precision, double precision, double precision, double precision) from anon, authenticated;
grant execute on function public.combat_encounter_move(uuid, uuid, double precision, double precision, double precision, double precision) to service_role;

-- ── 1e. combat_spawn_wave_units — THE ONE PLACEMENT LOOP, which used to be two ───────────────────
-- 0336 wrote it twice (its hunks 8 and 9) and 0338 had to patch both in lockstep. Everything about
-- WHERE a wave stands is here now, once: the MEASURED formation extent, 0336's structural clearance
-- radius (extent + this wave's own range + 1), 0338's arrival bearing from the site, the INSERT and
-- the slot walk. The two callers differ only in the STATS they pass, which is the difference that
-- was always real.
-- NOT ONE VALUE MOVES. This is a fold, not a retune: the radius expression, the phase call, the
-- weapons_json shape and the slot rule are the deployed text, relocated.
create or replace function public.combat_spawn_wave_units(
  p_encounter        uuid,
  p_player           uuid,
  p_unit_type_id     text,
  p_count            integer,
  p_unit_hp          double precision,
  p_speed            double precision,
  p_range            double precision,
  p_projectile_speed double precision,
  p_unit_power       double precision,
  p_cooldown         double precision,
  p_anchor_x         double precision,
  p_anchor_y         double precision,
  p_site_x           double precision,
  p_site_y           double precision,
  p_slot_from        integer)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fsw$
declare
  v_extent double precision;
  v_slot   integer := coalesce(p_slot_from, 0);
  v_i      integer;
  v_x      double precision;
  v_y      double precision;
begin
  if p_count is null or p_count <= 0 then
    return v_slot;   -- a 0-count plan unit spawns nothing (0299 FIX 4), preserved
  end if;
  -- THE EXTENT THE WAVE MUST STAND CLEAR OF, MEASURED — never assumed from the ring knob (0336).
  -- Max over the LIVING player rows of their distance from the anchor: the lead sits ON it (0),
  -- escorts sit out on the escort ring, and a lone hull IS its own lead, so its extent is 0. Every
  -- player ship is therefore within v_extent of the anchor, which is exactly what makes the
  -- clearance structural: the minimum separation between any player ship and any enemy is
  -- (extent + range + 1) - extent = range + 1, whatever the formation's shape.
  select coalesce(max(public.osn_distance(p_anchor_x, p_anchor_y, u.pos_x, u.pos_y)), 0)
    into v_extent
    from public.combat_units u
   where u.encounter_id = p_encounter and u.side = 'player' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null;
  for v_i in 1 .. p_count loop
    select fp.x, fp.y into v_x, v_y
      from public.combat_formation_point(p_anchor_x, p_anchor_y, v_extent + p_range + 1, v_slot,
             public.combat_wave_arrival_phase(p_anchor_x, p_anchor_y, p_site_x, p_site_y, v_slot)) fp;
    insert into public.combat_units (
      encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
      hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
    values (
      p_encounter, p_player, p_unit_type_id, 'enemy', p_unit_hp, 1, 1,
      p_unit_hp, p_unit_hp, v_x, v_y, p_speed,
      jsonb_build_array(jsonb_build_object(
        'module_type_id', 'pirate_synthetic_weapon', 'range', p_range,
        'projectile_speed', p_projectile_speed, 'power', p_unit_power,
        'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', p_cooldown,
        'next_ready_at', null, 'ammo_remaining', null)));
    v_slot := v_slot + 1;
  end loop;
  return v_slot;
end;
$fsw$;

comment on function public.combat_spawn_wave_units(uuid, uuid, text, integer, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, integer) is
  'THE ONE AUTHORITY for placing an enemy wave (0339). It owns the MEASURED formation extent, '
  '0336''s structural clearance radius (extent + this wave''s own range + 1), 0338''s arrival bearing '
  'from the zone''s own city, the INSERT and the slot walk. It exists because that loop was written '
  'TWICE — once per spawn arm, differing only in indentation — and every migration since 0299 had to '
  'patch both in lockstep. What legitimately differs between the arms is the STATS, and those are '
  'the arguments. Returns the next free slot so a resolved plan of several archetypes still lays out '
  'ONE ring. Moves no value: the geometry is the deployed text, relocated.';

revoke all on function public.combat_spawn_wave_units(uuid, uuid, text, integer, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, integer) from public;
revoke all on function public.combat_spawn_wave_units(uuid, uuid, text, integer, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, integer) from anon, authenticated;
grant execute on function public.combat_spawn_wave_units(uuid, uuid, text, integer, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, integer) to service_role;

-- ── 2. THE EPSILON — a bearing is not read off the last bit of a subtraction ─────────────────────
-- 0338:199 asked \`p_site_x = p_anchor_x and p_site_y = p_anchor_y\`. Exact float equality: a fight
-- ONE ULP off the site therefore computed a REAL bearing from a sub-unit displacement, i.e. an
-- arbitrary direction that flips with rounding. Replaced with a separation test against HALF A WORLD
-- UNIT. Why 0.5 and not 1e-9: every ordered coordinate is canonicalized onto the INTEGER world grid
-- before anything reads it (command_ship_group_go step 3), so half a cell is the resolution below
-- which the fight and the site are the same place as far as the world can express — and a bearing
-- taken from less than that is float noise, not a direction. The standoff of this same slice puts a
-- real site fight a whole territory_radius out, so this arm never fires on the path it protects.
-- EVERYTHING ELSE IS 0338's TEXT, VALUE FOR VALUE: the fan, the fallback constant, the NaN guard.
create or replace function public.combat_wave_arrival_phase(
  p_anchor_x double precision,
  p_anchor_y double precision,
  p_site_x   double precision,
  p_site_y   double precision,
  p_slot     integer)
returns double precision
language sql
immutable
set search_path to 'public'
as $fwa$
  select case
           when b.bearing_slots is null then 0.5
           else b.bearing_slots
                + (case when p_slot % 2 = 0 then  p_slot::double precision / 4.0
                                            else -((p_slot + 1)::double precision / 4.0) end)
                - p_slot::double precision
         end
    from (
      select case
               when p_slot is null or p_slot < 0
                 or p_anchor_x is null or p_anchor_y is null
                 or p_site_x is null or p_site_y is null
                 or (abs(p_site_x - p_anchor_x) < 0.5 and abs(p_site_y - p_anchor_y) < 0.5)
                 or 4.0 * atan2(p_site_y - p_anchor_y, p_site_x - p_anchor_x) / pi()
                    = 'NaN'::double precision
               then null::double precision
               else 4.0 * atan2(p_site_y - p_anchor_y, p_site_x - p_anchor_x) / pi()
             end as bearing_slots
    ) b;
$fwa$;

revoke all on function public.combat_wave_arrival_phase(double precision, double precision, double precision, double precision, integer) from public;
revoke all on function public.combat_wave_arrival_phase(double precision, double precision, double precision, double precision, integer) from anon, authenticated;

-- ── 3. THE KNOB — and it is the ONLY game_config row this migration writes ───────────────────────
-- docs/DEV_LOG.md named combat_player_speed_scale as "ONE knob" for this. It is the wrong one:
-- 0316's invariant f7 caps it at ~0.38 (under 2x) and raising it also speeds every per-unit CLOSE
-- and KITE decision, which is how a player kites a pirate out of the fight. This scales ONLY
-- combat_fleet_move_speed, the dedicated leaf with exactly one reader.
insert into public.game_config (key, value, description) values
  ('combat_reposition_speed_scale', '8.0',
   'multiplier on combat_fleet_move_speed ONLY (0339): how fast a fleet under an ORDERED reposition covers ground, in world units per combat tick, relative to its slowest living hull. Does NOT touch per-unit close/kite speed (that is combat_player_speed_scale, which 0316 invariant f7 caps at ~0.38). 8.0 makes a 20-unit reposition 30-48s instead of 4-6 minutes.')
on conflict (key) do nothing;

-- ── 4. THE FLEET-MOVE LEAF SCALES BY IT ──────────────────────────────────────────────────────────
-- Still min() over the fleet's LIVING hulls — a formation moves at the speed of its slowest ship,
-- the same rule fleet_speed and combat_fleet_return_speed already state — and still NULL for an
-- encounter with nothing living, so the caller holds. Fail closed. The scale is applied HERE, inside
-- the one leaf with one reader, so no second notion of "how fast under orders" can enter the engine.
-- greatest(..., 0): a negative knob means hold still, never a move backwards.
create or replace function public.combat_fleet_move_speed(p_encounter uuid)
returns double precision
language sql
stable
security definer
set search_path to 'public'
as $cfms$
  select (min(cu.move_speed)
          * greatest(coalesce(public.cfg_num('combat_reposition_speed_scale'), 8.0), 0))::double precision
    from public.combat_units cu
   where cu.encounter_id = p_encounter
     and cu.side = 'player'
     and cu.alive_count > 0;
$cfms$;

revoke all on function public.combat_fleet_move_speed(uuid) from public;
revoke all on function public.combat_fleet_move_speed(uuid) from anon, authenticated;
grant execute on function public.combat_fleet_move_speed(uuid) to service_role;

-- ── 5. CAPTURE METADATA BEFORE THE REWRITE (for parity check h) ──────────────────────────────────
create temp table _0339_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0339_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('process_combat_ticks', 'command_ship_group_go', 'combat_create_encounter');

-- ── 6. REWRITE THE HUNKS (located by exact deployed text, never retyped) ─────────────────────────
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
${hunkRows}
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0339 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0339 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0339 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0339 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 7 then
    raise exception '0339 REWRITE FAIL: rewrote % site(s), expected 7', v_done;
  end if;
end $rewrite$;

-- ── 7. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) the five leaves exist with the right posture, and NO client role can execute any of them
do $a$
declare
  r record;
  v_oid oid;
begin
  for r in
    select * from (values
      ('combat_site_standoff_point',   'public.combat_site_standoff_point(double precision, double precision, numeric, uuid)', 'i', false),
      ('combat_encounter_admits_point','public.combat_encounter_admits_point(uuid, double precision, double precision)',        's', true),
      ('combat_fleet_track_position',  'public.combat_fleet_track_position(uuid, double precision, double precision)',          'v', true),
      ('combat_encounter_move',        'public.combat_encounter_move(uuid, uuid, double precision, double precision, double precision, double precision)', 'v', true),
      ('combat_spawn_wave_units',      'public.combat_spawn_wave_units(uuid, uuid, text, integer, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, integer)', 'v', true)
    ) as t(fname, sig, vol, secdef)
  loop
    v_oid := to_regprocedure(r.sig);
    if v_oid is null then
      raise exception '0339 ASSERT (a) FAIL: leaf % was not created at the signature this slice composes', r.sig;
    end if;
    if not exists (select 1 from pg_proc p where p.oid = v_oid
                    and p.provolatile = r.vol::"char" and p.prosecdef = r.secdef
                    and coalesce(array_to_string(p.proconfig, ','), '') = 'search_path=public') then
      raise exception '0339 ASSERT (a) FAIL: % has the wrong volatility / security / search_path posture (want % / secdef %)', r.fname, r.vol, r.secdef;
    end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE')
       or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      raise exception '0339 ASSERT (a) FAIL: % is EXECUTE-able by a client role — these are engine internals, not a new surface', r.fname;
    end if;
  end loop;
  -- and the two REPLACED functions keep their own locked-down posture
  if has_function_privilege('anon', 'public.combat_fleet_move_speed(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.combat_fleet_move_speed(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.combat_wave_arrival_phase(double precision, double precision, double precision, double precision, integer)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.combat_wave_arrival_phase(double precision, double precision, double precision, double precision, integer)', 'EXECUTE') then
    raise exception '0339 ASSERT (a) FAIL: a re-created leaf came back client-callable — CREATE OR REPLACE keeps the old ACL, so this is a project-default GRANT (the 0254 class)';
  end if;
  if not has_function_privilege('service_role', 'public.combat_fleet_move_speed(uuid)', 'EXECUTE') then
    raise exception '0339 ASSERT (a) FAIL: service_role cannot execute combat_fleet_move_speed';
  end if;
end $a$;

-- (b) ██ ONE ANCHOR AUTHORITY — 0301'S SWEEP, RESTORED AND SHARPENED ██
-- This is the guard 0301 shipped and that did not re-run when 0337 drifted past it. It runs on every
-- apply of this chain, and DZCOMBAT_PASS_ONEANCHOR runs it again against the fully-applied chain on
-- every pull_request and every push to main.
do $b$
declare v_other text; v_code text; v_n integer;
begin
  select string_agg(p.proname, ', ')
    into v_other
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.prokind = 'f'
     and p.proname <> 'combat_encounter_move'
     and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~* 'set[[:space:]]+engagement_x';
  if v_other is not null then
    raise exception '0339 ASSERT (b) FAIL: % writes engagement_x by UPDATE — combat_encounter_move is the ONE authority for where a fight stands, and this is exactly the drift 0301''s spent assert missed when 0337 added its restamp', v_other;
  end if;
  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.proname = 'combat_encounter_move'
         and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') ~* 'set[[:space:]]+engagement_x') <> 1 then
    raise exception '0339 ASSERT (b) FAIL: combat_encounter_move does not itself set engagement_x — the sweep above would then be passing over an empty set, which is a guard that proves nothing';
  end if;
  -- the tick composes it, exactly once, and no longer moves the fleet or the formation by hand
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_move(e.id, e.fleet_id', '')))
         / length('public.combat_encounter_move(e.id, e.fleet_id');
  if v_n <> 1 then
    raise exception '0339 ASSERT (b) FAIL: % composition(s) of the move authority in the tick (want exactly 1)', v_n;
  end if;
  if position('public.combat_translate_player_formation(' in v_code) > 0 then
    raise exception '0339 ASSERT (b) FAIL: the tick still translates the formation directly — the three writes move together or not at all';
  end if;
  if position('public.fleet_set_in_space(' in v_code) > 0 then
    raise exception '0339 ASSERT (b) FAIL: the tick still writes the fleet position directly — that is how a PRESENT fleet gets silently un-docked, which is why a site fight could never reposition';
  end if;
  -- and the ORDER verb still writes only the course (0337's property, carried through)
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('engagement_x' in v_code) > 0 or position('fleet_set_in_space' in v_code) > 0
     or position('combat_translate_player_formation' in v_code) > 0 then
    raise exception '0339 ASSERT (b) FAIL: the order verb touches the fight''s position again — the teleport 0337 deleted is back';
  end if;
  if position('v_rz_mode' in v_code) > 0 then
    raise exception '0339 ASSERT (b) FAIL: the order verb still reads location_mode — the open-space-only gate is what stopped a hunt fight from ever repositioning, and its reason is gone';
  end if;
  if position('public.combat_encounter_admits_point(' in v_code) = 0 then
    raise exception '0339 ASSERT (b) FAIL: the order verb does not compose the ONE admission authority';
  end if;
end $b$;

-- (c) ONE SPAWN AUTHORITY: the fork is gone from the tick
do $c$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_spawn_wave_units(', '')))
         / length('public.combat_spawn_wave_units(');
  if v_n <> 2 then
    raise exception '0339 ASSERT (c) FAIL: % composition(s) of the spawn authority (want exactly 2 — the resolved arm and the synthetic arm, which differ only in the STATS they pass)', v_n;
  end if;
  if position('public.combat_formation_point(' in v_code) > 0 then
    raise exception '0339 ASSERT (c) FAIL: the tick still places a unit itself — placement has exactly one authority now';
  end if;
  if position('public.combat_wave_arrival_phase(' in v_code) > 0 then
    raise exception '0339 ASSERT (c) FAIL: the tick still computes an arrival bearing itself';
  end if;
  if position('v_formation_extent' in v_code) > 0 then
    raise exception '0339 ASSERT (c) FAIL: the tick still measures the formation extent — that measurement was the duplicated half of the fork and belongs to the spawn leaf';
  end if;
  if position('insert into combat_units' in v_code) > 0 then
    raise exception '0339 ASSERT (c) FAIL: the tick still inserts a combat unit — the wave INSERT was the body of the loop that existed twice';
  end if;
  -- the slot counter STAYS in the tick, and both arms still hand it over: the resolved arm carries
  -- it ACROSS archetypes, which is the one piece of state the fold cannot own.
  v_n := (length(v_code) - length(replace(v_code, 'v_spawn_slot := public.combat_spawn_wave_units(', '')))
         / length('v_spawn_slot := public.combat_spawn_wave_units(');
  if v_n <> 2 then
    raise exception '0339 ASSERT (c) FAIL: the spawn leaf''s returned slot is captured % time(s) (want 2) — a resolved plan of several archetypes would restart at slot 0 and stack its wave', v_n;
  end if;
end $c$;

-- (d) THE STANDOFF, EXECUTED — not asserted from the source text
do $d$
declare
  ax double precision; ay double precision;
  v_bx double precision; v_by double precision;
  s1 uuid := '11111111-1111-4111-8111-111111111111'::uuid;
  s2 uuid := '22222222-2222-4222-8222-222222222222'::uuid;
  d1 double precision;
begin
  select p.x, p.y into ax, ay from public.combat_site_standoff_point(-45, 120, 12, s1) p;
  if ax is null or ay is null then
    raise exception '0339 ASSERT (d) FAIL: the standoff answered NULL for a real site with a real radius';
  end if;
  d1 := public.osn_distance(-45, 120, ax, ay);
  if abs(d1 - 12) > 1e-9 then
    raise exception '0339 ASSERT (d) FAIL: a fight at Snare (-45,120) with territory_radius 12 stands % from it, want exactly 12 — the whole point is that the site becomes a DIRECTION rather than the place you are standing', d1;
  end if;
  -- STABLE for one presence: the same seed must answer the same point, or a fight would wander.
  select p.x, p.y into v_bx, v_by from public.combat_site_standoff_point(-45, 120, 12, s1) p;
  if v_bx is distinct from ax or v_by is distinct from ay then
    raise exception '0339 ASSERT (d) FAIL: the standoff is not deterministic for one presence';
  end if;
  -- DIFFERENT for another presence: two fleets hunting one site must not stack on one point.
  select p.x, p.y into v_bx, v_by from public.combat_site_standoff_point(-45, 120, 12, s2) p;
  if abs(v_bx - ax) < 1e-9 and abs(v_by - ay) < 1e-9 then
    raise exception '0339 ASSERT (d) FAIL: two different presences got the same standoff point — two fleets hunting one site would stack';
  end if;
  if abs(public.osn_distance(-45, 120, v_bx, v_by) - 12) > 1e-9 then
    raise exception '0339 ASSERT (d) FAIL: the second presence does not stand on the same radius';
  end if;
  -- FAIL CLOSED to today's behaviour: no radius, no edge, so the fight anchors ON the site.
  select p.x, p.y into v_bx, v_by from public.combat_site_standoff_point(-45, 120, null, s1) p;
  if v_bx is distinct from -45::double precision or v_by is distinct from 120::double precision then
    raise exception '0339 ASSERT (d) FAIL: a site with NO territory radius must answer the site itself (today''s behaviour), got (%,%)', v_bx, v_by;
  end if;
  select p.x, p.y into v_bx, v_by from public.combat_site_standoff_point(-45, 120, 0, s1) p;
  if v_bx is distinct from -45::double precision or v_by is distinct from 120::double precision then
    raise exception '0339 ASSERT (d) FAIL: a ZERO territory radius must answer the site itself, got (%,%)', v_bx, v_by;
  end if;
  select p.x, p.y into v_bx, v_by from public.combat_site_standoff_point(null, null, 12, s1) p;
  if v_bx is not null or v_by is not null then
    raise exception '0339 ASSERT (d) FAIL: a vanished site must answer NULL — the shape the creator has always produced';
  end if;
end $d$;

-- (e) THE EPSILON, EXECUTED — a sub-half-unit displacement is not a bearing
do $e$
declare k integer;
begin
  for k in 0 .. 7 loop
    -- one ulp off the site: on the 0338 body this computed a REAL bearing from float noise
    if public.combat_wave_arrival_phase(10, -20, 10 + 1e-12, -20, k) is distinct from 0.5 then
      raise exception '0339 ASSERT (e) FAIL: a site one ulp from the anchor still produced a bearing at slot % — that direction is the last bit of a subtraction, not a direction', k;
    end if;
    if public.combat_wave_arrival_phase(10, -20, 10.4, -19.6, k) is distinct from 0.5 then
      raise exception '0339 ASSERT (e) FAIL: a sub-half-unit displacement still produced a bearing at slot % — below half a world grid cell the fight and the site are the same place', k;
    end if;
    -- and a REAL displacement still answers the real bearing: the fix must not eat the feature
    if public.combat_wave_arrival_phase(10, -20, 10, -8, k) is not distinct from 0.5 then
      raise exception '0339 ASSERT (e) FAIL: a 12-unit displacement (the Snare standoff itself) fell back to the ring at slot % — the epsilon has eaten the bearing this whole slice exists to produce', k;
    end if;
  end loop;
  -- 0338's own fallbacks survive value-for-value
  if public.combat_wave_arrival_phase(10, -20, null, null, 0) is distinct from 0.5
     or public.combat_wave_arrival_phase(null, null, 10, -20, 0) is distinct from 0.5
     or public.combat_wave_arrival_phase(10, -20, 40, 60, -1) is distinct from 0.5
     or public.combat_wave_arrival_phase(10, -20, 'NaN'::double precision, 60, 0) is distinct from 0.5 then
    raise exception '0339 ASSERT (e) FAIL: one of 0338''s own fallbacks stopped answering its constant';
  end if;
end $e$;

-- (f) THE ADMISSION IS A PURE RELAXATION OF 0311, EXECUTED against the live catalog
do $f$
declare
  n_bad integer;
begin
  -- Quantified over EVERY live encounter and its own anchor: anything 0311 admits, this admits.
  -- On a fresh chain this set may be empty, which is why (f) also proves the composition below.
  select count(*) into n_bad
    from public.combat_encounters ce
   where ce.engagement_x is not null and ce.engagement_y is not null
     and public.combat_encounter_zone_admits_point(ce.id, ce.engagement_x, ce.engagement_y)
     and not public.combat_encounter_admits_point(ce.id, ce.engagement_x, ce.engagement_y);
  if n_bad <> 0 then
    raise exception '0339 ASSERT (f) FAIL: % encounter(s) whose own anchor 0311 admits are REFUSED by the new admission — it must be a pure relaxation, never a narrowing', n_bad;
  end if;
  -- fail closed on garbage, exactly as 0311 does
  if public.combat_encounter_admits_point('00000000-0000-0000-0000-000000000000'::uuid, 0, 0) then
    raise exception '0339 ASSERT (f) FAIL: a non-existent encounter was admitted';
  end if;
  if public.combat_encounter_admits_point('00000000-0000-0000-0000-000000000000'::uuid, null, null) then
    raise exception '0339 ASSERT (f) FAIL: a NULL destination was admitted';
  end if;
  -- and it COMPOSES 0311 rather than re-implementing containment
  if position('combat_encounter_zone_admits_point'
              in (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'combat_encounter_admits_point')) = 0 then
    raise exception '0339 ASSERT (f) FAIL: the admission does not compose 0311 — a second containment rule is a second law';
  end if;
end $f$;

-- (g) THE KNOB, EXECUTED
do $g$
declare
  v_scale double precision;
  v_code  text;
  v_ticks integer;
begin
  v_scale := public.cfg_num('combat_reposition_speed_scale');
  if v_scale is null or v_scale <= 1 then
    raise exception '0339 ASSERT (g) FAIL: combat_reposition_speed_scale is % — the whole point is that an ordered reposition is FASTER than a per-unit step', v_scale;
  end if;
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_fleet_move_speed';
  if position('combat_reposition_speed_scale' in v_code) = 0 then
    raise exception '0339 ASSERT (g) FAIL: the fleet-move leaf does not read the knob';
  end if;
  if position('min(cu.move_speed)' in v_code) = 0 or position('alive_count > 0' in v_code) = 0 then
    raise exception '0339 ASSERT (g) FAIL: the leaf stopped being min(move_speed) over the LIVING player hulls — a formation moves at its slowest ship, and a wreck must never set its speed';
  end if;
  -- and NOTHING ELSE reads it: one knob, one leaf, so the per-unit close/kite economy 0316's f7
  -- protects cannot be moved by this lever.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') like '%combat_reposition_speed_scale%') <> 1 then
    raise exception '0339 ASSERT (g) FAIL: more than one function reads combat_reposition_speed_scale — a second reader is a second speed authority';
  end if;
  -- fail closed: an encounter with nothing living has no speed at all
  if public.combat_fleet_move_speed('00000000-0000-0000-0000-000000000000'::uuid) is not null then
    raise exception '0339 ASSERT (g) FAIL: the leaf answered a speed for an encounter with no units — it must fail closed';
  end if;
  -- THE PLAYER-FACING NUMBER, stated as a bound rather than a hope: production''s SLOWEST hull is
  -- 0.16 in combat, so a 20-unit reposition must complete inside 20 ticks (60 seconds) at this knob.
  v_ticks := ceil(20.0 / (0.16 * v_scale))::integer;
  if v_ticks > 20 then
    raise exception '0339 ASSERT (g) FAIL: at scale % the SLOWEST production fleet needs % ticks (% seconds) to cross 20 world units — the owner''s report was that this takes minutes, and tens of seconds is the bar', v_scale, v_ticks, v_ticks * 3;
  end if;
  -- and 0316's f7 lever is untouched by this slice
  if public.cfg_num('combat_player_speed_scale') is distinct from 0.2 then
    raise notice '0339 note: combat_player_speed_scale is % (this slice does not write it; 0316 f7 still owns it)', public.cfg_num('combat_player_speed_scale');
  end if;
end $g$;

-- (h) metadata parity: the rewritten functions changed BODY and nothing else
do $h$
declare r record;
begin
  for r in
    select b.fname, b.body_md5 as old_md5, md5(p.prosrc) as new_md5,
           b.owner as old_owner, pg_get_userbyid(p.proowner) as new_owner,
           b.secdef as old_secdef, p.prosecdef as new_secdef,
           b.volatility as old_vol, p.provolatile as new_vol,
           b.parallel as old_par, p.proparallel as new_par,
           b.proconfig as old_cfg, coalesce(array_to_string(p.proconfig, ','), '') as new_cfg,
           b.args as old_args, pg_get_function_identity_arguments(p.oid) as new_args,
           b.result as old_result, pg_get_function_result(p.oid) as new_result,
           b.acl as old_acl, coalesce(p.proacl::text, '') as new_acl
      from _0339_before b
      join pg_proc p on p.proname = b.fname
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  loop
    if r.old_md5 = r.new_md5 then
      raise exception '0339 ASSERT (h) FAIL: public.% is byte-identical to before the rewrite — its hunks did not land', r.fname;
    end if;
    if r.old_owner is distinct from r.new_owner or r.old_secdef is distinct from r.new_secdef
       or r.old_vol is distinct from r.new_vol or r.old_par is distinct from r.new_par
       or r.old_cfg is distinct from r.new_cfg or r.old_args is distinct from r.new_args
       or r.old_result is distinct from r.new_result or r.old_acl is distinct from r.new_acl then
      raise exception '0339 ASSERT (h) FAIL: public.% changed more than its body (owner %/%, secdef %/%, volatility %/%, parallel %/%, config %/%, args %/%, result %/%, acl %/%)',
        r.fname, r.old_owner, r.new_owner, r.old_secdef, r.new_secdef, r.old_vol, r.new_vol,
        r.old_par, r.new_par, r.old_cfg, r.new_cfg, r.old_args, r.new_args,
        r.old_result, r.new_result, r.old_acl, r.new_acl;
    end if;
  end loop;
end $h$;

commit;
`;

if (SQL.includes('\r')) {
  throw new Error('gen-0339: a CR reached the emitted SQL — a \\r baked into a sliced hunk can never match pg_get_functiondef (LF) and the production deploy would fail at apply time');
}

const check = process.argv.includes('--check');
if (check) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8').replace(/\r\n/g, '\n');
  } catch {
    console.error('gen-0339 --check FAILED: the migration file is missing. Run the generator.');
    process.exit(1);
  }
  if (onDisk !== SQL) {
    console.error('gen-0339 --check FAILED: supabase/migrations/20260618000339_a_fight_you_can_move_in.sql '
      + 'no longer matches what the generator derives from its slice sources. Either it was hand-edited '
      + '(regenerate) or a source migration (0301/0336/0337/0338) drifted (read the diff FIRST — a slice '
      + 'that no longer matches may mean the head moved under you).');
    process.exit(1);
  }
  console.log('gen-0339 --check ok');
} else {
  writeFileSync(OUT, SQL, 'utf8');
  console.log(`gen-0339 wrote ${OUT} (${SQL.length} chars, ${HUNKS.length} hunks)`);
}
