#!/usr/bin/env node
// gen-0336-combat-engine-repairs.mjs — emit (or --check) migration 0336.
//
// WHY A GENERATOR: 0336 rewrites FIFTEEN hunks inside the live process_combat_ticks body and ONE
// inside combat_create_group_encounter. Neither function's whole text lives in any migration file —
// the tick is 73,160 chars live and is surgery-assembled — so every `old_t` below is SLICED VERBATIM
// out of the migration that owns the deployed text of its region, and every `new_t` is DERIVED from
// that slice by edit()/concatenation. Nothing is retyped (the 0303 lesson).
//
//   process_combat_ticks           — TEXTUAL head 0299:308; replace-surgery since: 0310, 0314, 0317,
//                                    0332. Every hunk below sits in 0299-original text, statically
//                                    disjoint from all four (checked site by site: 0310 owns the
//                                    auto-exit arm, 0314 the per-hit roll / hitsplat / cooldown /
//                                    variance declare+read, 0317 the actor-liveness guard prepended
//                                    to the retreat gate, 0332 the settle arm's member loop).
//   combat_create_group_encounter  — TEXTUAL head 0301; replace-surgery since: 0308, 0315, 0316,
//                                    0331. The escort-ring lines are 0315's OWN new text, so that
//                                    hunk is sliced from 0315's emitted migration (the gen-0331
//                                    idiom: slice from whichever migration owns the deployed text).
//
//   node scripts/gen-0336-combat-engine-repairs.mjs          # write the migration
//   node scripts/gen-0336-combat-engine-repairs.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000336_combat_engine_repairs.sql');
const SELF = '20260618000336';

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECKS: establish that the files sliced below really own the deployed text. ─────────────
// Two detectors, both over comment-stripped text: a later TEXTUAL re-create makes the slice source
// stale outright; a later HUNK ROW — the house `(idx, 'fname',` shape — means somebody surgically
// edited the body and a new slice must not be cut without reading that migration. Later rewriters
// are exempted BY NAME (the gen-0315/0317 idiom) rather than by widening the version window, so the
// gate stays live for 0337 and everything after it.
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
  guard('process_combat_ticks', '20260618000299',
    new Set(['20260618000310', '20260618000314', '20260618000317', '20260618000332']));
  guard('combat_create_group_encounter', '20260618000301',
    new Set(['20260618000308', '20260618000315', '20260618000316', '20260618000331']));
}

const F299 = load('20260618000299_combat_card_reports_true_power.sql');
const F315 = load('20260618000315_every_fleet_has_a_lead.sql');

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

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// THE HUNKS
// ═════════════════════════════════════════════════════════════════════════════════════════════════

// ── H1: the formation working set joins the declare block ───────────────────────────────────────
const H1_OLD = slice(F299, '0299', 420, 420, 'v_spawn_i                integer;', 'v_spawn_i                integer;');
const H1_NEW = H1_OLD + `
  -- ██ 0336 THE FORMATION WORKING SET ██
  -- v_ring_radius is read ONCE per invocation from the SAME game_config key the encounter creator
  -- reads for the player escort ring, so both formations are laid out by one knob and one leaf.
  -- v_spawn_slot is the wave's running 0-based slot, carried ACROSS plan units so a resolved wave
  -- of several archetypes still lands on one ring rather than restarting at slot 0 per archetype.
  v_ring_radius            double precision;
  v_spawn_slot             integer;
  v_slot_x                 double precision;
  v_slot_y                 double precision;`;

// ── H2: the ring radius joins the one-read-per-invocation block ─────────────────────────────────
const H2_OLD = slice(F299, '0299', 437, 437,
  "v_per_ship_targeting := cfg_bool('per_ship_targeting_enabled');",
  "v_per_ship_targeting := cfg_bool('per_ship_targeting_enabled');");
const H2_NEW = H2_OLD + `
  -- 0336: the formation ring radius joins the one-read block, never re-read inside the loop. It is
  -- the same key, with the same fallback, that combat_create_group_encounter reads to place the
  -- player escort ring — ONE knob decides how far apart a formation stands, on both sides.
  v_ring_radius   := coalesce(cfg_num('spatial_formation_ring_radius'), 30);`;

// ── The shared prose for a terminal arm's confined release. ─────────────────────────────────────
const RELEASE_NOTE = (indent) => `${indent}-- ██ 0336 THE TERMINAL ARM IS CONFINED, AND THE ENCOUNTER STILL CONCLUDES ██
${indent}-- fleet_destroy and presence_complete both RAISE on a status mismatch (fleet_destroy: not in a
${indent}-- destroyable state; presence_complete: presence not in an active state). Neither was guarded
${indent}-- here, and both run BEFORE this arm's own status write — so a mismatch rolled the whole tick
${indent}-- back INCLUDING last_resolved_at, and the encounter retried, identically, every tick, forever
${indent}-- and silently (the 0206 per-row guard downgrades the raise to a warning and the cron keeps
${indent}-- returning normally). That is the wedge send_ship_group_hunt already names in prose.
${indent}-- ONE LEAF, FOUR ARMS: combat_encounter_release confines each call in its own subtransaction
${indent}-- so one failure cannot skip the other, re-raises query_canceled exactly as the outer guard
${indent}-- does, and returns normally — which is what lets the status write below LAND. A mismatch now
${indent}-- CONCLUDES the encounter with a warning instead of wedging it.
${indent}-- ORDER IS IMMATERIAL, CHECKED: fleet_destroy writes fleets, presence_complete writes
${indent}-- location_presence (+ the worldstate cache), mainship_mark_combat_destroyed writes
${indent}-- main_ship_instances. No two of the three read what another writes, so folding the pair into
${indent}-- one call at the head of the arm changes no outcome.
${indent}-- AND THE RETREAT TARGET IS ALWAYS CONSUMED: only the settle arm ever cleared
${indent}-- fleets.retreat_target_*, while its own header states the invariant that the recording is
${indent}-- ALWAYS consumed. A fleet that died, or was wiped mid-fight, kept a stale destination that
${indent}-- the NEXT sortie's settle would then fly to. One leaf, called by all four arms.`;

// ── H3: terminal arm (A) — already destroyed on entry ───────────────────────────────────────────
const H3_OLD = slice(F299, '0299', 514, 519,
  'if v_hp_total <= 0 or v_alive_total <= 0 then',
  'perform presence_complete(e.presence_id);');
const H3_NEW = edit(
  edit(H3_OLD,
    '      perform fleet_destroy(e.fleet_id);\n',
    RELEASE_NOTE('      ') + `
      perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
      perform public.fleet_consume_retreat_target(e.fleet_id);
`),
  '\n      perform presence_complete(e.presence_id);', '');

// ── H4: terminal arm (B) — the settle arm. Two disjoint sites. ──────────────────────────────────
const H4A_OLD = slice(F299, '0299', 557, 558,
  'perform report_create(e.id);', 'perform presence_complete(e.presence_id);');
const H4A_NEW = edit(H4A_OLD,
  '      perform presence_complete(e.presence_id);',
  RELEASE_NOTE('      ') + `
      -- This arm consumes the retreat target a few lines below, where it also READS it, so it takes
      -- the release call alone (p_destroy_fleet false: a fleet that is leaving is not a wreck).
      perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, false);`);

const H4B_OLD = slice(F299, '0299', 602, 607,
  'select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y', 'end if;');
const H4B_NEW = `        -- 0336 ONE RETREAT-TARGET CLEARER, COMPOSED HERE. The read-then-clear pair moves into
        -- fleet_consume_retreat_target so the OTHER three terminal arms can consume the recording
        -- without re-implementing it. The leaf returns what it cleared, so this arm loses nothing:
        -- the exactly-one-of CHECK, the location re-validation below, the coordinate-as-stored rule
        -- and the origin_base_id fallback are all unchanged and all still live in this branch.
        select t.target_location_id, t.target_x, t.target_y
          into v_ret_loc, v_dest_x, v_dest_y
          from public.fleet_consume_retreat_target(e.fleet_id) t;`;

// ── H5: a retreating fleet is never sent a fresh wave ───────────────────────────────────────────
const H5_OLD = slice(F299, '0299', 659, 660,
  'if v_e_before <= 0 then', 'if e.next_wave_at is not null and now() < e.next_wave_at then');
const H5_NEW = edit(H5_OLD,
  '        if e.next_wave_at is not null and now() < e.next_wave_at then',
  `        -- ██ 0336 A RETREATING FLEET IS NEVER SENT A FRESH WAVE ██
        -- The offense gate below silences the PLAYER while retreating; the enemy side is never
        -- gated, by design (the aggregate arm's asymmetry, mirrored). But this block had NO status
        -- guard at all, so clearing a wave during the retreat window spawned a LARGER one — danger
        -- rises with waves_cleared — that then shot at a fleet which could not shoot back for the
        -- remaining seconds of the window. Production carries four encounters that died exactly
        -- that way, 3.4 to 5.8 seconds into an 8-second window, and a death is a 'defeat', which
        -- zeroes total_rewards_json: the whole haul, destroyed by pressing Retreat.
        -- ONE CONDITION, AND NO NEW PATH: a retreating encounter with a cleared enemy side simply
        -- carries its ceiling over, exactly as an ONGOING wave does in the else arm below, and
        -- falls through to the normal per-tick bookkeeping. Nothing is spawned, no new tick label
        -- is invented, and branch (B) above still completes the retreat when the delay elapses.
        if e.status = 'retreating' then
          v_enemy_hp := e.enemy_integrity_max;
        elsif e.next_wave_at is not null and now() < e.next_wave_at then`);

// ── H6/H7: the wave spawns on a RING, not on one point ──────────────────────────────────────────
const RING_NOTE = (indent) => `${indent}-- ██ 0336 THE WAVE SPAWNS ON A RING, NOT ON ONE POINT ██
${indent}-- Every unit of a wave was inserted at the identical anchor. Production proves the effect:
${indent}-- every encounter that ever held enemies holds them at exactly ONE distinct position. Three
${indent}-- consequences, all bad: distance from any actor to every enemy is the same constant, so the
${indent}-- id-ascending tiebreak in targeting became absolute and EVERY gun of EVERY ship converged on
${indent}-- one row; the fight rendered as a single pixel; and the whole wave sat inside the enemy's own
${indent}-- range from tick zero, which is the basin the standoff lives in.
${indent}-- MIRRORS THE PLAYER FORMATION, THROUGH THE SAME LEAF: combat_formation_point is the ONE
${indent}-- authority for "where does slot k of a formation ring sit", composed here and by the encounter
${indent}-- creator's escort ring. Slots 0..7 at phase 0 reproduce the creator's own cos/sin expression
${indent}-- value-for-value, so no player formation moves; the wave takes phase 0.5 — half a slot — so
${indent}-- an enemy never lands exactly on an escort, and the radius steps out every 8 slots so a wave
${indent}-- larger than the ring still has distinct points.`;

const H6A_OLD = slice(F299, '0299', 696, 698,
  "delete from combat_units where encounter_id = e.id and side = 'enemy';",
  "for v_weapon in select value from jsonb_array_elements(v_plan->'units') loop");
const H6A_NEW = edit(H6A_OLD,
  "            for v_weapon in select value from jsonb_array_elements(v_plan->'units') loop",
  `            -- 0336: the slot counter is initialised for the WHOLE resolved wave, outside the
            -- per-archetype loop, so a plan of several unit types still lays out one ring.
            v_spawn_slot := 0;
            for v_weapon in select value from jsonb_array_elements(v_plan->'units') loop`);

const H6B_OLD = slice(F299, '0299', 711, 723,
  'for v_spawn_i in 1 .. v_enemy_count loop', 'end loop;');
const H6B_NEW = edit(
  edit(
    edit(RING_NOTE('              ') + '\n' + H6B_OLD,
      '                insert into combat_units (',
      `                select fp.x, fp.y into v_slot_x, v_slot_y
                  from public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring_radius, v_spawn_slot, 0.5) fp;
                insert into combat_units (`),
    'v_enemy_unit_hp, v_enemy_unit_hp, v_anchor_x, v_anchor_y, v_enemy_speed,',
    'v_enemy_unit_hp, v_enemy_unit_hp, v_slot_x, v_slot_y, v_enemy_speed,'),
  "                    'next_ready_at', null, 'ammo_remaining', null)));\n              end loop;",
  "                    'next_ready_at', null, 'ammo_remaining', null)));\n                v_spawn_slot := v_spawn_slot + 1;\n              end loop;");

const H7_OLD = slice(F299, '0299', 768, 780,
  'for v_spawn_i in 1 .. v_enemy_count loop', 'end loop;');
const H7_NEW = edit(
  edit(
    edit(RING_NOTE('          ') + '\n          v_spawn_slot := 0;\n' + H7_OLD,
      '            insert into combat_units (',
      `            select fp.x, fp.y into v_slot_x, v_slot_y
              from public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring_radius, v_spawn_slot, 0.5) fp;
            insert into combat_units (`),
    'v_enemy_unit_hp, v_enemy_unit_hp, v_anchor_x, v_anchor_y, v_enemy_speed,',
    'v_enemy_unit_hp, v_enemy_unit_hp, v_slot_x, v_slot_y, v_enemy_speed,'),
  "                'next_ready_at', null, 'ammo_remaining', null)));\n          end loop;",
  "                'next_ready_at', null, 'ammo_remaining', null)));\n            v_spawn_slot := v_spawn_slot + 1;\n          end loop;");

// ── H8: the freeze carries the SHORTEST gun too, and it is ORDERED ──────────────────────────────
const H8_OLD = slice(F299, '0299', 805, 813,
  'select coalesce(jsonb_agg(jsonb_build_object(',
  'where cu2.encounter_id = e.id and cu2.alive_count > 0;');
const H8_NEW = edit(
  edit(H8_OLD,
    "                 'move_speed', coalesce(cu2.move_speed, 0),",
    `                 'my_min_range', (select min((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'move_speed', coalesce(cu2.move_speed, 0),`),
  "                 'main_ship_id', cu2.main_ship_id)), '[]'::jsonb)",
  `                 'main_ship_id', cu2.main_ship_id) order by cu2.id), '[]'::jsonb)`);

// ── H9: the actor loop's record shape learns my_min_range ───────────────────────────────────────
const H9_OLD = slice(F299, '0299', 817, 821, 'for v_ur in', 'loop');
const H9_NEW = edit(H9_OLD,
  '            my_range double precision, move_speed double precision, aggro_priority integer, main_ship_id uuid)',
  `            my_range double precision, my_min_range double precision,
            move_speed double precision, aggro_priority integer, main_ship_id uuid)`);

// ── H10: targeting moves into ONE leaf (the CTE, verbatim, plus a liveness predicate) ───────────
const H10_OLD = slice(F299, '0299', 831, 846,
  'v_target_id := null; v_target_x := null', 'limit 1;');
const H10_NEW = `          -- ██ 0336 ONE TARGETING AUTHORITY, COMPOSED — NEVER A SECOND ONE ██
          -- The candidates/tier CTE moved WHOLE into combat_acquire_target: same projection, same
          -- osn_distance, same aggro-tier screen, same dist-then-id ordering, same limit 1. It is
          -- lifted rather than copied precisely so the per-weapon RE-ACQUISITION below can ask the
          -- identical question instead of growing a second targeting rule.
          -- ONE LIVENESS PREDICATE: the leaf adds combat_units.alive_count > 0 on the LIVE row — the
          -- same column comparison the actor guard and the damage read already use, in a third role.
          -- A corpse is no longer a target, and a dead escort no longer screens the hull behind it.
          v_target_id := null; v_target_x := null; v_target_y := null; v_target_range := null; v_target_dist := null;
          select t.id, t.pos_x, t.pos_y, t.my_range, t.dist
            into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
            from public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side) t;`;

// ── H11: never retreat past your SHORTEST gun ───────────────────────────────────────────────────
const H11_OLD = slice(F299, '0299', 852, 856,
  'MOVEMENT — combat_unit_decide_move', 'v_target_x, v_target_y, coalesce(v_target_range,0));');
const H11_NEW = edit(H11_OLD,
  '              v_ur.pos_x, v_ur.pos_y, coalesce(v_ur.my_range,0), coalesce(v_ur.move_speed,0),',
  `              -- 0336 NEVER RETREAT PAST YOUR SHORTEST GUN. The mover uses this argument for BOTH
              -- the close decision and the kite cap, so passing the LONGEST gun made a ship hold at
              -- its longest reach and silently disable every shorter one: the fire gate below is
              -- per weapon, so an Mk-II (range 6) fitted beside an autocannon (range 5) parks the
              -- hull at ~6 and the autocannon never fires — a better gun buying LESS damage, which
              -- is the very defect 0331 was written to end, recreated through geometry.
              -- my_min_range is MY engagement range; the target's my_range stays the LONGEST, because
              -- what I must respect about the enemy is its full reach. Two questions, two values.
              -- Single-weapon ships have min = max, so their movement is byte-identical to the head.
              v_ur.pos_x, v_ur.pos_y, coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),`);

// ── H12: a kill does not disarm the rest of the volley ──────────────────────────────────────────
const H12_OLD = slice(F299, '0299', 872, 873,
  'if v_w_range is not null and v_target_dist <= v_w_range',
  'and (v_w_next_ready is null or now() >= v_w_next_ready) then');
const H12_NEW = `            -- ██ 0336 A KILL DOES NOT DISARM THE REST OF THE VOLLEY ██
            -- The target was resolved ONCE, above, before this per-weapon loop. Every gun on the
            -- ship fired at that one row, and when gun 1 destroyed it the damage step's `+"`"+`if found`+"`"+`
            -- simply DROPPED guns 2 and 3 — their shots vanished rather than being re-aimed. On a
            -- ship carrying three autocannons (production has one) that is two thirds of its damage
            -- gone on every kill tick, and 0331 had just split its combat_power three ways to feed
            -- those three barrels. Compounded by the single-point wave spawn, which made every gun
            -- converge on the same row in the first place.
            -- THE SAME AUTHORITY, ASKED AGAIN: re-acquire through combat_acquire_target — no second
            -- targeting rule, no live-table scan of its own. The actor's frozen pre-move position is
            -- still what distance is measured from, exactly as at first acquisition, so the freeze
            -- and its simultaneity are untouched. With nothing left alive to shoot, the volley ends.
            if not exists (select 1 from combat_units cu3 where cu3.id = v_target_id and cu3.alive_count > 0) then
              select t.id, t.pos_x, t.pos_y, t.my_range, t.dist
                into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
                from public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side) t;
              if v_target_id is null then
                exit;
              end if;
            end if;
` + H12_OLD;

// ── H13/H14: terminal arms (C) spatial death and (D) aggregate death ────────────────────────────
const H13_OLD = slice(F299, '0299', 1015, 1020,
  'if v_hp_after <= 0 then', 'perform presence_complete(e.presence_id);');
const H13_NEW = edit(
  edit(H13_OLD,
    '          perform fleet_destroy(e.fleet_id);\n',
    RELEASE_NOTE('          ') + `
          perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
          perform public.fleet_consume_retreat_target(e.fleet_id);
`),
  '\n          perform presence_complete(e.presence_id);', '');

const H14_OLD = slice(F299, '0299', 1194, 1199,
  'if v_hp_after <= 0 then', 'perform presence_complete(e.presence_id);');
const H14_NEW = edit(
  edit(H14_OLD,
    '        perform fleet_destroy(e.fleet_id);\n',
    RELEASE_NOTE('        ') + `
        perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
        perform public.fleet_consume_retreat_target(e.fleet_id);
`),
  '\n        perform presence_complete(e.presence_id);', '');

// ── H15: the encounter creator's escort ring composes the same leaf ─────────────────────────────
const H15_OLD = slice(F315, '0315', 297, 298,
  'v_pos_x := v_loc_x + v_ring_radius * cos(2 * pi() * v_escort_idx / 8);',
  'v_pos_y := v_loc_y + v_ring_radius * sin(2 * pi() * v_escort_idx / 8);');
const H15_NEW = `            -- 0336: the escort ring now composes combat_formation_point, the ONE authority for
            -- "where does slot k of a formation ring sit". The tick spawns enemy waves through the
            -- same leaf, so the two formations can never drift apart. At phase 0 and slots 0..7 the
            -- leaf evaluates to this line's own expression, so no existing fleet moves; slots 8 and
            -- beyond, which used to WRAP onto an occupied slot, now step out to a wider ring.
            select fp.x, fp.y into v_pos_x, v_pos_y
              from public.combat_formation_point(v_loc_x, v_loc_y, v_ring_radius, v_escort_idx, 0) fp;`;

const HUNKS = [
  // Declarations first: every later hunk references a local declared by H1, and each intermediate
  // CREATE OR REPLACE is validated by plpgsql, so a use may never precede its declaration.
  [1,  'process_combat_ticks', H1_OLD,  H1_NEW],
  [2,  'process_combat_ticks', H2_OLD,  H2_NEW],
  [3,  'process_combat_ticks', H3_OLD,  H3_NEW],
  [4,  'process_combat_ticks', H4A_OLD, H4A_NEW],
  [5,  'process_combat_ticks', H4B_OLD, H4B_NEW],
  [6,  'process_combat_ticks', H5_OLD,  H5_NEW],
  [7,  'process_combat_ticks', H6A_OLD, H6A_NEW],
  [8,  'process_combat_ticks', H6B_OLD, H6B_NEW],
  [9,  'process_combat_ticks', H7_OLD,  H7_NEW],
  [10, 'process_combat_ticks', H8_OLD,  H8_NEW],
  [11, 'process_combat_ticks', H9_OLD,  H9_NEW],
  [12, 'process_combat_ticks', H10_OLD, H10_NEW],
  [13, 'process_combat_ticks', H11_OLD, H11_NEW],
  [14, 'process_combat_ticks', H12_OLD, H12_NEW],
  [15, 'process_combat_ticks', H13_OLD, H13_NEW],
  [16, 'process_combat_ticks', H14_OLD, H14_NEW],
  [17, 'combat_create_group_encounter', H15_OLD, H15_NEW],
];

// Dollar-quote tags must not collide with anything inside the hunk text.
const rows = HUNKS.map(([idx, fname, oldT, newT]) => {
  const o = `$h${idx}o$`;
  const n = `$h${idx}n$`;
  for (const [tag, body] of [[o, oldT], [n, newT]]) {
    if (body.includes(tag)) throw new Error(`dollar-quote tag ${tag} collides with hunk ${idx}`);
    if (body.includes('$')) throw new Error(`hunk ${idx} contains '$' — dollar-quoting is unsafe`);
    if (!body.trim()) throw new Error(`hunk ${idx} sliced empty — a line range is wrong`);
    // the elite-stat proof greps the RAW tick body, comments included, on every chain.
    if (/elite/i.test(body)) throw new Error(`hunk ${idx} contains 'elite' — the elite-stat proof greps the RAW tick body`);
    // the tick's RNG-site count is pinned at 3 by elite-stat-wiring-proof.
    if (/[^_]random\(/.test(body)) throw new Error(`hunk ${idx} adds a random( call — the tick's RNG-site count is pinned`);
  }
  // PLPGSQL VARIABLE CAPTURE (the 0310 rev.2 lesson): process_combat_ticks declares record variables
  // cu / e / pr / loc and a uuid v_mv, and plpgsql resolves table-alias-qualified references against
  // variables too — an alias shadowing one of them raises "ambiguous" at FIRST EXECUTION only.
  // Applied to the NEW text only; the old text is the deployed head.
  {
    const m = newT.match(/\b(?:from|join)\s+[a-z_][a-z0-9_]*\s+(cu|e|pr|loc|mv|m)\b/i);
    if (m) throw new Error(`hunk ${idx} aliases a table as '${m[1]}' — that name is a plpgsql record variable and the reference would be ambiguous at first execution`);
  }
  return `    (${idx}, '${fname}',\n     ${o}${oldT}${o},\n     ${n}${newT}${n})`;
}).join(',\n');

// The rewrite is SEQUENTIAL over one body, so no hunk's old text may occur inside another hunk's
// text — otherwise the earlier rewrite would consume the later one's site (or double-apply).
for (let i = 0; i < HUNKS.length; i++) {
  for (let j = 0; j < HUNKS.length; j++) {
    if (i !== j && (HUNKS[j][3].includes(HUNKS[i][2]) || HUNKS[j][2].includes(HUNKS[i][2]))) {
      throw new Error(`hunk ${HUNKS[i][0]}'s old text occurs inside hunk ${HUNKS[j][0]} — the sequential rewrite would double-apply`);
    }
  }
}

const STRIP = `regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')`;

const sql = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0336 — COMBAT ENGINE REPAIRS
--        eight defects in the fight itself, read off the DEPLOYED body and confirmed on production
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- Migration 0335 is production's head. Everything below was verified against the DEPLOYED
-- pg_get_functiondef text (73,160 chars; no migration file holds the tick whole) and against live
-- production rows, read-only, on 2026-08-03.
--
-- ── THE EIGHT, RANKED BY LIVE HARM ───────────────────────────────────────────────────────────────
-- 1. A MULTI-GUN SHIP THREW AWAY ITS EXTRA GUNS ON KILL TICKS.  The target is resolved ONCE, before
--    the per-weapon loop. All of a ship's guns fired at that one row, and when gun 1 destroyed it
--    the damage step's found-guard DROPPED guns 2 and 3 instead of re-aiming them. Production holds
--    one ship with THREE fitted autocannons, and 0331 had just split its combat_power three ways to
--    feed them — so two thirds of its damage vanished on every kill tick.
-- 2. EVERY ENEMY IN A WAVE SPAWNED ON ONE IDENTICAL POINT.  Both spawn arms inserted all N units at
--    the engagement anchor. Measured on production: every encounter that ever held enemies holds
--    them at exactly ONE distinct position. Distance became a constant, the id tiebreak became
--    absolute, and every gun on every ship converged on the same row — compounding (1). It also
--    rendered the fight as a single pixel.
-- 3. RETREATING SPAWNED A FRESH WAVE THAT SHOT AT A FLEET WHICH COULD NOT SHOOT BACK.  The offense
--    gate silences the PLAYER only; the wave-spawn block carried no status guard at all. Production
--    holds four encounters that died inside the retreat window — 3.4, 4.6, 4.8 and 5.8 seconds in —
--    each becoming a 'defeat', which zeroes total_rewards_json. The entire haul, destroyed by
--    pressing Retreat.
-- 4. THE FOUR TERMINAL ARMS WERE UNCONFINED RAISE SITES.  fleet_destroy and presence_complete both
--    raise on a status mismatch and both ran before their arm's own status write, so a mismatch
--    rolled back the whole tick INCLUDING last_resolved_at and the encounter retried identically,
--    every tick, forever, silently. Only the 0310 auto-exit arm already carried a subtransaction.
-- 5. THREE OF THE FOUR LEAKED fleets.retreat_target_*.  Only the settle arm cleared it, while that
--    arm's own header states the invariant that the recording is ALWAYS consumed.
-- 6. THE ACTOR LOOP ORDER WAS HEAP ORDER.  The population freeze had no ORDER BY, so targeting was
--    deterministic but WHO FIRES FIRST was not — and with sequential damage that decides whose shots
--    are wasted. Any determinism harness over this tick was unsound without it.
-- 7. A LONGER GUN SILENTLY DISABLED A SHORTER ONE ON THE SAME SHIP.  The freeze carried
--    my_range = max(range) and the mover uses that for both the close decision and the kite cap,
--    while the fire gate is PER WEAPON. An Mk-II (range 6) beside an autocannon (range 5) holds the
--    hull at ~6 and the autocannon never fires — 0331's "better gun, less damage" defect recreated
--    through geometry. Latent today (no production ship carries two weapon TYPES); the Mk-II is
--    craftable.
-- 8. THE HIGHEST-DIFFICULTY SITE WAS AN UNWINNABLE STANDOFF.  Executed against the DEPLOYED mover,
--    read-only, at production's live knobs: at The Furnace (base_difficulty 60, hidden) the synthetic
--    enemy range is 3.6 + 0.04*60 = 6.0, the formation ring is 6.0, so the wave spawns INSIDE its own
--    range, immediately kites, and settles at 5.8 = enemy_range - player_speed. The player's gun
--    reaches 5. It never fires; the pirate fires every tick. Fixed by the INVARIANT below, not by a
--    number: the wave must spawn OUTSIDE its own reach so it closes instead of kiting.
--
-- ── WHAT THIS MIGRATION DOES ─────────────────────────────────────────────────────────────────────
-- FOUR NEW LEAVES, each the single authority for one concept, each composed rather than copied:
--   combat_formation_point         — where slot k of a formation ring sits. Composed by the tick's
--                                    two wave-spawn arms AND by the encounter creator's escort ring.
--   combat_acquire_target          — the nearest LIVE opposite-side unit. The head's candidates/tier
--                                    CTE, lifted whole, plus one liveness predicate. Composed at
--                                    first acquisition and at per-weapon re-acquisition.
--   fleet_consume_retreat_target   — read-and-clear fleets.retreat_target_*. Composed by all four
--                                    terminal arms.
--   combat_encounter_release       — the confined world-state release. Composed by all four arms.
-- SIXTEEN HUNKS in process_combat_ticks and ONE in combat_create_group_encounter, every old_t sliced
-- verbatim from the migration that owns its deployed text (0299 and 0315), every new_t derived from
-- that slice. Nothing retyped.
-- ONE KNOB, RAISED BY DERIVATION, NOT BY DECREE: spatial_formation_ring_radius is set to at least
-- one world unit beyond the widest synthetic enemy range any live location can produce, computed at
-- apply time from the live knobs and the live locations. On today's world that is 6.0 -> 7.0, which
-- clears all three Ember sites. It only ever RAISES the value.
--
-- ── BLAST RADIUS ON THE LIVE GAME ────────────────────────────────────────────────────────────────
--   * CREATE OR REPLACE of two functions plus four new ones: an atomic catalog swap. THE TICK BODY IS
--     READ FRESH EVERY 3 SECONDS, so the very next tick of every running fight runs the new body.
--     There is no per-fight opt-in and no drain. Read read-only at generation time: production had
--     ZERO encounters in status active or retreating, so nothing was mid-fight.
--   * combat_create_group_encounter changes only where an escort STANDS, and only for a fleet whose
--     ninth-or-later escort used to wrap onto an occupied slot. Slots 0..7 are value-identical.
--   * The knob write raises one game_config row. Every reader takes it on its next read.
--   * NO schema change, NO grant widening (the four leaves are revoked from every client role), NO
--     reward, drop, threshold or difficulty value moved.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed bodies with the hunks reverted (0299's and 0315's text), drop the four
-- leaves, and set spatial_formation_ring_radius back to its recorded prior value (captured into the
-- notice below at apply time). This migration writes no combat row and no player state.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
-- WHAT THESE PROVE, HONESTLY: that the emitted TEXT is what this migration intended — never that it
-- EXECUTES. Behaviour is proven by exactly one layer: the disposable apply-proof driving the REAL
-- tick (danger-combat-proof's eight 0336 blocks).
--   (a) the four leaves exist, with the right volatility/security, and no client can execute them
--   (b) ONE targeting authority: the tick's own candidates CTE is gone and both acquisitions compose
--       the leaf
--   (c) ONE liveness predicate, and the volley re-acquires
--   (d) the wave spawns through the formation leaf, on both arms, and no insert carries the anchor
--   (e) a retreating encounter cannot reach the spawn; the loop order is pinned; the kite is capped
--       by the shortest gun
--   (f) all four terminal arms are confined and all four consume the retreat target
--   (g) THE RANGE INVARIANT holds over every live location
--   (h) every carried-through 0299/0310/0314/0317/0331/0332 invariant survives the re-emission
--   (i) metadata parity: the two rewritten functions changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
declare
  v_tick text;
  v_ccge text;
begin
  if to_regprocedure('public.process_combat_ticks()') is null then
    raise exception '0336 PRECONDITION FAIL: process_combat_ticks is absent';
  end if;
  select prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_ccge from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if v_ccge is null then
    raise exception '0336 PRECONDITION FAIL: combat_create_group_encounter is absent';
  end if;
  -- the base must carry every predecessor whose text this slice sits beside:
  if position('presence_request_leave(e.presence_id)' in v_tick) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick lacks the 0310 auto-exit arm';
  end if;
  if position('v_hit_roll' in v_tick) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick lacks the 0314 per-hit roll';
  end if;
  if position('perform 1 from combat_units where id = v_ur.id and alive_count > 0;' in v_tick) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick lacks the 0317 actor-liveness guard';
  end if;
  if position('perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end if;' in v_tick) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick lacks the 0332 settle-arm reconcile';
  end if;
  if position('v_weight_total' in v_ccge) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed encounter creator lacks the 0331 share-weight fold';
  end if;
  if position('if v_is_lead then' in v_ccge) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed encounter creator lacks the 0315 lead election';
  end if;
  -- the defects must still be there, or somebody else edited this body and we must not guess.
  if position('public.combat_acquire_target(' in v_tick) > 0
     or position('public.combat_formation_point(' in v_tick) > 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick already composes a 0336 leaf — refusing to re-emit over an unknown edit';
  end if;
end $pre$;

-- ── 1. THE FOUR LEAVES ───────────────────────────────────────────────────────────────────────────
-- Created BEFORE the rewrite so the rewritten bodies never reference a missing function, and each
-- revoked from every client role in the same step: these are engine internals, not a new surface.
-- (The lockdown ESTABLISHES the posture by revoking rather than asserting it — the 0254 lesson.)

-- combat_formation_point — THE ONE AUTHORITY for "where does slot k of a formation ring sit".
-- Slots 0..7 at phase 0 reduce exactly to the escort ring's own cos/sin expression, so no existing
-- formation moves. The radius steps out by half a ring every 8 slots, which is what makes the point
-- distinct for a wave (or a fleet) larger than one ring — the old expression wrapped onto an
-- occupied slot. Phase is in SLOTS, not radians, so 0.5 means "half a slot off the player ring".
create or replace function public.combat_formation_point(
  p_anchor_x double precision,
  p_anchor_y double precision,
  p_radius   double precision,
  p_slot     integer,
  p_phase    double precision)
returns table(x double precision, y double precision)
language sql
immutable
set search_path to 'public'
as $ffp$
  select p_anchor_x + p_radius * (1 + floor(p_slot / 8.0) * 0.5) * cos(2 * pi() * (p_slot + p_phase) / 8.0),
         p_anchor_y + p_radius * (1 + floor(p_slot / 8.0) * 0.5) * sin(2 * pi() * (p_slot + p_phase) / 8.0);
$ffp$;

-- combat_acquire_target — THE ONE AUTHORITY for "who do I shoot". This is the tick's own
-- candidates/tier CTE, lifted whole: same projection, same osn_distance, same aggro-tier screen,
-- same dist-then-id ordering, same limit 1. The ONE addition is the liveness predicate — the same
-- combat_units.alive_count > 0 the actor guard and the damage read already use — so a corpse is not
-- a target and a dead escort does not screen the hull behind it. Positions still come from the
-- FROZEN pre-move snapshot the caller passes in; only liveness is read live.
create or replace function public.combat_acquire_target(
  p_units   jsonb,
  p_my_x    double precision,
  p_my_y    double precision,
  p_my_side text)
returns table(id uuid, pos_x double precision, pos_y double precision,
              my_range double precision, dist double precision)
language sql
stable
set search_path to 'public'
as $fat$
  with candidates as (
    select x.id, x.pos_x, x.pos_y, x.my_range, x.aggro_priority,
           public.osn_distance(p_my_x, p_my_y, x.pos_x, x.pos_y) as dist
    from jsonb_to_recordset(p_units) as x(
      id uuid, side text, pos_x double precision, pos_y double precision,
      my_range double precision, my_min_range double precision,
      move_speed double precision, aggro_priority integer, main_ship_id uuid)
    where x.side is distinct from p_my_side
      and exists (select 1 from public.combat_units cu where cu.id = x.id and cu.alive_count > 0)
  ),
  tier as (select min(aggro_priority) as m from candidates)
  select c.id, c.pos_x, c.pos_y, c.my_range, c.dist
  from candidates c, tier
  where tier.m is null or c.aggro_priority = tier.m
  order by c.dist asc, c.id asc
  limit 1;
$fat$;

-- fleet_consume_retreat_target — THE ONE AUTHORITY for consuming fleets.retreat_target_*. Returns
-- what it cleared, so the settle arm (which must READ the destination) composes the same leaf as the
-- three arms that only need it GONE. The exactly-one-of CHECK still guarantees at most one shape is
-- populated; this leaf neither validates nor interprets, it consumes.
create or replace function public.fleet_consume_retreat_target(p_fleet uuid)
returns table(target_location_id uuid, target_x double precision, target_y double precision)
language plpgsql
security definer
set search_path to 'public'
as $fcr$
begin
  select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y
    into target_location_id, target_x, target_y
    from public.fleets f where f.id = p_fleet;
  if target_location_id is not null or target_x is not null or target_y is not null then
    update public.fleets
       set retreat_target_location_id = null, retreat_target_x = null, retreat_target_y = null,
           updated_at = now()
     where id = p_fleet;
  end if;
  return next;
end;
$fcr$;

-- combat_encounter_release — THE ONE AUTHORITY for releasing a concluded encounter's world state,
-- CONFINED. Each call gets its OWN subtransaction so a failure in one cannot skip the other, and
-- query_canceled re-raises exactly as the outer per-encounter guard treats it: a cancellation must
-- kill the run, never be eaten as a skipped step. Returning normally is the whole point — it is what
-- lets the caller's status write LAND, so a status mismatch CONCLUDES the encounter with a warning
-- instead of rolling back the tick and retrying forever.
create or replace function public.combat_encounter_release(
  p_encounter uuid,
  p_fleet     uuid,
  p_presence  uuid,
  p_destroy_fleet boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $cer$
begin
  if p_destroy_fleet then
    begin
      perform public.fleet_destroy(p_fleet);
    exception
      when query_canceled then raise;
      when others then
        raise warning 'combat_encounter_release: encounter % — fleet % was not in a destroyable state, the encounter still concludes: %',
          p_encounter, p_fleet, sqlerrm;
    end;
  end if;
  begin
    perform public.presence_complete(p_presence);
  exception
    when query_canceled then raise;
    when others then
      raise warning 'combat_encounter_release: encounter % — presence % was not in an active state, the encounter still concludes: %',
        p_encounter, p_presence, sqlerrm;
  end;
end;
$cer$;

revoke all on function public.combat_formation_point(double precision, double precision, double precision, integer, double precision) from public;
revoke all on function public.combat_acquire_target(jsonb, double precision, double precision, text) from public;
revoke all on function public.fleet_consume_retreat_target(uuid) from public;
revoke all on function public.combat_encounter_release(uuid, uuid, uuid, boolean) from public;
revoke all on function public.combat_formation_point(double precision, double precision, double precision, integer, double precision) from anon, authenticated;
revoke all on function public.combat_acquire_target(jsonb, double precision, double precision, text) from anon, authenticated;
revoke all on function public.fleet_consume_retreat_target(uuid) from anon, authenticated;
revoke all on function public.combat_encounter_release(uuid, uuid, uuid, boolean) from anon, authenticated;

-- ── 2. CAPTURE METADATA BEFORE THE REWRITE (for parity check i) ──────────────────────────────────
create temp table _0336_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0336_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('process_combat_ticks', 'combat_create_group_encounter');

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
${rows}
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0336 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0336 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0336 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0336 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 17 then
    raise exception '0336 REWRITE FAIL: rewrote % site(s), expected 17', v_done;
  end if;
end $rewrite$;

-- ── 4. THE RANGE INVARIANT, ESTABLISHED BY DERIVATION ────────────────────────────────────────────
-- THE LAW: a wave must spawn OUTSIDE its own weapon range. Inside it, the wave kites on tick one and
-- settles at (enemy_range - player_speed), which for a high-difficulty site is beyond the player's
-- own gun: the pirate fires every tick and the player never fires at all. Outside it, the wave
-- CLOSES, overshoots the kite band, and both sides engage. That is the entire difference between a
-- fight and a firing squad, and it is decided by one comparison:
--
--     spatial_formation_ring_radius  >  enemy_synthetic_range_base
--                                       + enemy_synthetic_range_per_difficulty * base_difficulty
--
-- for EVERY location that can host a fight — including hidden ones, because a hidden site is a site
-- that has not been released YET.
--
-- THE NUMBER IS DERIVED, NEVER DECREED: the required radius is computed here from the live knobs and
-- the live locations, with one world unit of headroom, and the knob is only ever RAISED. On a world
-- whose widest synthetic range is 6.0 (The Furnace, base_difficulty 60) that yields 7.0. A future
-- site that outgrows the ring fails assert (g) rather than silently becoming unwinnable.
do $ring$
declare
  v_prev  double precision;
  v_need  double precision;
  v_next  double precision;
  v_worst text;
begin
  v_prev := coalesce(public.cfg_num('spatial_formation_ring_radius'), 30);
  select max(coalesce(public.cfg_num('enemy_synthetic_range_base'), 120)
             + l.base_difficulty * coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 5))
    into v_need
    from public.locations l
   where l.base_difficulty > 0;
  if v_need is null then
    raise notice '0336: no location carries a positive base_difficulty — the formation ring is left at %', v_prev;
    return;
  end if;
  select l.name into v_worst
    from public.locations l
   where l.base_difficulty > 0
   order by l.base_difficulty desc, l.name asc
   limit 1;
  v_next := greatest(v_prev, v_need + 1);
  if v_next <> v_prev then
    update public.game_config
       set value = to_jsonb(v_next), updated_at = now()
     where key = 'spatial_formation_ring_radius';
    if not found then
      raise exception '0336 RING FAIL: game_config has no spatial_formation_ring_radius row to raise';
    end if;
  end if;
  raise notice '0336: formation ring % -> % (widest synthetic enemy range % at %, plus one unit of headroom)',
    v_prev, v_next, v_need, v_worst;
end $ring$;

-- ── 5. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) the four leaves exist, with the right volatility/security, and NO client can execute them
do $a$
declare r record; v_n integer := 0;
begin
  for r in
    select * from (values
      ('combat_formation_point',       'i', false),
      ('combat_acquire_target',        's', false),
      ('fleet_consume_retreat_target', 'v', true),
      ('combat_encounter_release',     'v', true)
    ) as t(fname, vol, secdef)
  loop
    if to_regproc('public.' || r.fname) is null then
      raise exception '0336 ASSERT (a) FAIL: leaf public.% was not created', r.fname;
    end if;
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = r.fname
                      and p.provolatile = r.vol and p.prosecdef = r.secdef
                      and coalesce(array_to_string(p.proconfig, ','), '') = 'search_path=public') then
      raise exception '0336 ASSERT (a) FAIL: leaf public.% has the wrong volatility / security / search_path posture', r.fname;
    end if;
    if has_function_privilege('anon', (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                        where n.nspname = 'public' and p.proname = r.fname), 'EXECUTE')
       or has_function_privilege('authenticated', (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                        where n.nspname = 'public' and p.proname = r.fname), 'EXECUTE') then
      raise exception '0336 ASSERT (a) FAIL: leaf public.% is EXECUTE-able by a client role — these are engine internals, not a new surface', r.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 4 then
    raise exception '0336 ASSERT (a) FAIL: checked % leaf/leaves, expected 4', v_n;
  end if;
end $a$;

-- (b) ONE targeting authority: the tick's own CTE is GONE and both acquisitions compose the leaf
do $b$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('with candidates as (' in v_code) > 0 or position('tier as (select min(aggro_priority)' in v_code) > 0 then
    raise exception '0336 ASSERT (b) FAIL: the tick still carries its own targeting CTE — that is the second authority this slice exists to remove';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side)', '')))
         / length('public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side)');
  if v_n <> 2 then
    raise exception '0336 ASSERT (b) FAIL: % composition(s) of the targeting leaf (want exactly 2: first acquisition and the per-weapon re-acquisition)', v_n;
  end if;
  -- the leaf really is the head's CTE, not a rewrite of it
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_acquire_target';
  if position('order by c.dist asc, c.id asc' in v_code) = 0
     or position('where tier.m is null or c.aggro_priority = tier.m' in v_code) = 0
     or position('where x.side is distinct from p_my_side' in v_code) = 0
     or position('public.osn_distance(p_my_x, p_my_y, x.pos_x, x.pos_y)' in v_code) = 0 then
    raise exception '0336 ASSERT (b) FAIL: the targeting leaf is not the head CTE lifted whole (a screen, an ordering or the distance call is missing)';
  end if;
end $b$;

-- (c) ONE liveness predicate, and the volley re-acquires
do $c$
declare v_tick text; v_leaf text; v_n integer;
begin
  select ${STRIP} into v_tick
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  select ${STRIP} into v_leaf
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_acquire_target';
  if position('cu3.alive_count > 0' in v_tick) = 0 then
    raise exception '0336 ASSERT (c) FAIL: the per-weapon re-acquisition does not test the target''s liveness';
  end if;
  if position('if v_target_id is null then
                exit;' in v_tick) = 0 then
    raise exception '0336 ASSERT (c) FAIL: the volley does not END when nothing is left alive to shoot';
  end if;
  if position('cu.alive_count > 0' in v_leaf) = 0 then
    raise exception '0336 ASSERT (c) FAIL: the targeting leaf does not filter on liveness — a corpse would still absorb a whole volley';
  end if;
  -- ONE SPELLING, still. No second way to ask "is this unit alive".
  if position('is_destroyed' in v_tick) > 0 or position('alive_count <= 0' in v_tick) > 0
     or position('alive_count = 0' in v_tick) > 0 or position('alive_count <= 0' in v_leaf) > 0 then
    raise exception '0336 ASSERT (c) FAIL: a second spelling of "is this unit alive" is in the engine — one authority, one predicate';
  end if;
  -- the 0317 actor guard is untouched, and the target re-read still stands
  v_n := (length(v_tick) - length(replace(v_tick, 'perform 1 from combat_units where id = v_ur.id and alive_count > 0;', '')))
         / length('perform 1 from combat_units where id = v_ur.id and alive_count > 0;');
  if v_n <> 1 then
    raise exception '0336 ASSERT (c) FAIL: % actor-liveness guard(s) (0317''s must survive, exactly once)', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'from combat_units where id = v_target_id and alive_count > 0;', '')))
         / length('from combat_units where id = v_target_id and alive_count > 0;');
  if v_n <> 1 then
    raise exception '0336 ASSERT (c) FAIL: % target-liveness re-read(s) at the damage step (want exactly 1)', v_n;
  end if;
end $c$;

-- (d) the wave spawns through the formation leaf, on BOTH arms, and no enemy insert carries the anchor
do $d$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring_radius, v_spawn_slot, 0.5)', '')))
         / length('public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring_radius, v_spawn_slot, 0.5)');
  if v_n <> 2 then
    raise exception '0336 ASSERT (d) FAIL: % spawn arm(s) place their wave through the formation leaf (want exactly 2: the resolved arm and the synthetic arm)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'v_enemy_unit_hp, v_enemy_unit_hp, v_slot_x, v_slot_y, v_enemy_speed,', '')))
         / length('v_enemy_unit_hp, v_enemy_unit_hp, v_slot_x, v_slot_y, v_enemy_speed,');
  if v_n <> 2 then
    raise exception '0336 ASSERT (d) FAIL: % enemy insert(s) take the ring point (want exactly 2)', v_n;
  end if;
  if position('v_enemy_unit_hp, v_enemy_unit_hp, v_anchor_x, v_anchor_y, v_enemy_speed,' in v_code) > 0 then
    raise exception '0336 ASSERT (d) FAIL: an enemy insert still spawns AT the anchor — the whole wave would sit on one point again';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'v_spawn_slot := v_spawn_slot + 1;', '')))
         / length('v_spawn_slot := v_spawn_slot + 1;');
  if v_n <> 2 then
    raise exception '0336 ASSERT (d) FAIL: % slot advance(s) (want exactly 2 — a spawn arm that never advances puts the whole wave back on one point)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'v_spawn_slot := 0;', ''))) / length('v_spawn_slot := 0;');
  if v_n <> 2 then
    raise exception '0336 ASSERT (d) FAIL: % slot initialisation(s) (want exactly 2, one per spawn arm)', v_n;
  end if;
  -- and the creator's escort ring composes the SAME leaf
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('public.combat_formation_point(v_loc_x, v_loc_y, v_ring_radius, v_escort_idx, 0)' in v_code) = 0 then
    raise exception '0336 ASSERT (d) FAIL: the encounter creator does not compose the formation leaf — the ring formula would exist twice';
  end if;
  if position('v_ring_radius * cos(2 * pi() * v_escort_idx / 8)' in v_code) > 0 then
    raise exception '0336 ASSERT (d) FAIL: the creator still inlines the ring formula — that is the second authority this slice removes';
  end if;
end $d$;

-- (e) a retreating encounter cannot reach the spawn; the loop order is pinned; the kite is capped
do $e$
declare v_code text; v_n integer; v_spawn integer; v_guard integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_guard := position('if e.status = ''retreating'' then
          v_enemy_hp := e.enemy_integrity_max;
        elsif e.next_wave_at is not null and now() < e.next_wave_at then' in v_code);
  if v_guard = 0 then
    raise exception '0336 ASSERT (e) FAIL: the retreat guard is not the FIRST branch of the wave-spawn decision — a retreating fleet could still be sent a fresh wave';
  end if;
  v_spawn := position('delete from combat_units where encounter_id = e.id and side = ''enemy'';
          for v_spawn_i in 1 .. v_enemy_count loop' in v_code);
  if v_spawn = 0 or v_guard >= v_spawn then
    raise exception '0336 ASSERT (e) FAIL: the retreat guard does not precede the synthetic spawn (% vs %)', v_guard, v_spawn;
  end if;
  -- the loop order is no longer heap order
  if position('''main_ship_id'', cu2.main_ship_id) order by cu2.id), ''[]''::jsonb)' in v_code) = 0 then
    raise exception '0336 ASSERT (e) FAIL: the population freeze has no ORDER BY — who fires first would still be heap order, and every determinism harness over this tick would be unsound';
  end if;
  -- the kite is capped by the SHORTEST gun, and the target is still measured by its LONGEST
  if position('coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),' in v_code) = 0 then
    raise exception '0336 ASSERT (e) FAIL: the mover is not capped by the shortest gun — a longer gun would still disable a shorter one';
  end if;
  if position('coalesce(v_target_range,0));' in v_code) = 0 then
    raise exception '0336 ASSERT (e) FAIL: the target''s reach is no longer passed to the mover';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'my_min_range', ''))) / length('my_min_range');
  if v_n <> 4 then
    raise exception '0336 ASSERT (e) FAIL: my_min_range appears % time(s) (want 4: the freeze key, the two recordset column lists it must travel through, and the mover argument)', v_n;
  end if;
end $e$;

-- (f) all four terminal arms are confined, and all four consume the retreat target
do $f$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('perform fleet_destroy(e.fleet_id);' in v_code) > 0
     or position('perform presence_complete(e.presence_id);' in v_code) > 0 then
    raise exception '0336 ASSERT (f) FAIL: an UNCONFINED fleet_destroy / presence_complete survives in the tick — that arm can still wedge an encounter forever';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_release(e.id, e.fleet_id, e.presence_id,', '')))
         / length('public.combat_encounter_release(e.id, e.fleet_id, e.presence_id,');
  if v_n <> 4 then
    raise exception '0336 ASSERT (f) FAIL: % terminal arm(s) release through the confined leaf (want exactly 4: entry-defeat, settle, spatial death, aggregate death)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true)', '')))
         / length('public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true)');
  if v_n <> 3 then
    raise exception '0336 ASSERT (f) FAIL: % arm(s) destroy the fleet (want exactly 3 — the settle arm must NOT, a fleet that is leaving is not a wreck)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.fleet_consume_retreat_target(e.fleet_id)', '')))
         / length('public.fleet_consume_retreat_target(e.fleet_id)');
  if v_n <> 4 then
    raise exception '0336 ASSERT (f) FAIL: % arm(s) consume the retreat target (want exactly 4 — a leaked recording is flown by the NEXT sortie)', v_n;
  end if;
  if position('update fleets set retreat_target_location_id = null' in v_code) > 0 then
    raise exception '0336 ASSERT (f) FAIL: the tick still clears the retreat target inline — that is the second clearer this slice removes';
  end if;
  -- the leaf really confines, and really re-raises a cancellation
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_encounter_release';
  v_n := (length(v_code) - length(replace(v_code, 'when query_canceled then raise;', '')))
         / length('when query_canceled then raise;');
  if v_n <> 2 then
    raise exception '0336 ASSERT (f) FAIL: the release leaf carries % query_canceled re-raise(s) (want 2, one per confined call — a cancellation must kill the run, never be eaten)', v_n;
  end if;
end $f$;

-- (g) THE RANGE INVARIANT holds over every live location
do $g$
declare r record; v_ring double precision; v_n integer := 0;
begin
  v_ring := coalesce(public.cfg_num('spatial_formation_ring_radius'), 30);
  for r in
    select l.name, l.status, l.base_difficulty,
           coalesce(public.cfg_num('enemy_synthetic_range_base'), 120)
           + l.base_difficulty * coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 5) as enemy_range
      from public.locations l
     where l.base_difficulty > 0
  loop
    v_n := v_n + 1;
    if not (v_ring > r.enemy_range) then
      raise exception '0336 ASSERT (g) FAIL: % (%, base_difficulty %) spawns its wave INSIDE its own range — formation ring % is not greater than enemy range %. The wave kites on tick one and settles beyond the player''s gun: an unwinnable standoff. Raise spatial_formation_ring_radius, or lower enemy_synthetic_range_per_difficulty.',
        r.name, r.status, r.base_difficulty, v_ring, r.enemy_range;
    end if;
  end loop;
  -- NON-VACUITY: an empty location set would satisfy the loop above while proving nothing.
  if v_n = 0 then
    raise exception '0336 ASSERT (g) FAIL: no location carries a positive base_difficulty — the invariant was checked against an EMPTY set and proves nothing';
  end if;
  raise notice '0336 ASSERT (g) ok: the formation ring % clears the synthetic enemy range at all % hunt-capable location(s)', v_ring, v_n;
end $g$;

-- (h) every carried-through invariant survives the re-emission
do $h$
declare v_code text; v_n integer; v_tok text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('fleet_get_power' in v_code) > 0 then
    raise exception '0336 ASSERT (h) FAIL: fleet_get_power is back in the tick (0299 reverted)';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_side_power(e.id, ''player'')', '')))
         / length('public.combat_encounter_side_power(e.id, ''player'')');
  if v_n <> 2 then
    raise exception '0336 ASSERT (h) FAIL: % of 2 power writes read the 0299 authority', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'random(', ''))) / length('random(');
  if v_n <> 3 then
    raise exception '0336 ASSERT (h) FAIL: the tick carries % random( call(s) (want 3 — the elite-stat proof pins this count on every chain)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'movement_create(', ''))) / length('movement_create(');
  if v_n <> 2 then
    raise exception '0336 ASSERT (h) FAIL: the tick mints % movement leg(s) (want the head''s 2)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'jsonb_to_recordset(v_units)', ''))) / length('jsonb_to_recordset(v_units)');
  if v_n <> 1 then
    raise exception '0336 ASSERT (h) FAIL: % read(s) of the frozen snapshot inside the tick (want 1 — the actor loop; targeting''s read moved into the leaf)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'into v_units', ''))) / length('into v_units');
  if v_n <> 1 then
    raise exception '0336 ASSERT (h) FAIL: the tick builds the population snapshot % time(s) (want exactly 1 — re-freezing would destroy the simultaneity the freeze exists for)', v_n;
  end if;
  foreach v_tok in array array[
      'v_hit_roll double precision := greatest(0, (1 - v_hit_var_pct) + random() * (2 * v_hit_var_pct));',
      'v_dmg := v_w_power * v_hit_roll;',
      'now() + make_interval(secs => coalesce((v_weapon->>''cooldown_seconds'')::double precision, 0))',
      'v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)',
      'v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null',
      'if v_w_range is not null and v_target_dist <= v_w_range',
      'and (v_w_next_ready is null or now() >= v_w_next_ready) then',
      'jsonb_array_length(v_weapons_json) - 1',
      'select sum(msi.max_hp) into v_ae_cap',
      'presence_request_leave(e.presence_id)',
      'v_enemy_count  := least(coalesce(cfg_num(''enemy_synthetic_max_units''),6)::integer, greatest(1, v_danger));',
      '''module_type_id'', ''pirate_synthetic_weapon'', ''range'', v_enemy_range,',
      'v_reward_metal := round(coalesce(cfg_num(''reward_metal_base''),10) * greatest(loc.reward_tier,1)',
      'coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0)',
      'v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;',
      'v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);'
    ] loop
    if position(v_tok in v_code) = 0 then
      raise exception '0336 ASSERT (h) FAIL: the tick lost a pinned head guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
  -- the encounter creator kept everything this slice does not touch
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  foreach v_tok in array array[
      'v_is_lead := m.main_ship_id is not distinct from v_lead_ship_id;',
      'v_aggro_priority := case when v_is_lead then 100 else 0 end;',
      'public.module_is_firing_weapon(t)',
      'v_weight_total',
      'v_ring_radius := coalesce(public.cfg_num(''spatial_formation_ring_radius''), 30)'
    ] loop
    if position(v_tok in v_code) = 0 then
      raise exception '0336 ASSERT (h) FAIL: the encounter creator lost a pinned guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
end $h$;

-- (i) metadata parity: the two rewritten functions changed body and NOTHING else
do $i$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0336_before loop
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
      raise exception '0336 ASSERT (i) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0336 ASSERT (i) FAIL: public.% body is byte-identical — its hunks did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 2 then
    raise exception '0336 ASSERT (i) FAIL: parity-checked % function(s), expected 2', v_n;
  end if;
  raise notice '0336 SELF-ASSERT PASS: every gun in a volley re-aims; a wave stands on a ring outside its own reach; a retreating fleet is never sent a fresh wave; all four terminal arms are confined and all four consume the retreat target; the firing order is stable; and no ship holds at a range that silences its own shorter gun';
end $i$;

commit;
`;

if (sql.includes('\r')) {
  throw new Error('emitted 0336 carries a CR — the rewrite hunks would never match the deployed body');
}

if (process.argv.includes('--check')) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8').replace(/\r\n/g, '\n');
  } catch {
    console.error(`gen-0336: ${OUT} is MISSING — run the generator without --check to emit it.`);
    process.exit(1);
  }
  if (onDisk !== sql) {
    console.error('gen-0336: the migration on disk does NOT match what this generator emits.');
    console.error('  Either the file was hand-edited (regenerate it), or one of the source migrations');
    console.error('  it slices (0299 / 0315) moved under it (read the diff before regenerating).');
    process.exit(1);
  }
  console.log(`gen-0336: migration matches the slices it takes (${HUNKS.length} hunks over 2 functions).`);
  process.exit(0);
}

writeFileSync(OUT, sql);
console.log(`gen-0336: wrote ${OUT} (${sql.length} bytes, ${HUNKS.length} hunks over 2 functions).`);
