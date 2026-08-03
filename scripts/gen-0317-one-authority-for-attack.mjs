#!/usr/bin/env node
// gen-0317-one-authority-for-attack.mjs — emit (or --check) migration 0317.
//
// WHY A GENERATOR: 0317 rewrites TWO live plpgsql functions by hunk surgery —
//   calculate_expedition_stats      (TRUE head 0205 §8; nothing has re-created it since, and the
//                                    deployed prosrc is byte-identical to that file's body)
//   combat_create_group_encounter   (TRUE head = 0301's text with 0308's two, 0315's five and
//                                    0316's one replace-surgery hunks applied on top)
// so the slice source is PER HUNK, not per file. Every `old_t` below is SLICED verbatim out of the
// migration that owns the deployed text of that region, and every `new_t` is CONSTRUCTED from that
// slice by exactly-once string edits — so even the unchanged words inside a replaced hunk are
// byte-copies, never retyped (the 0303 lesson). The migration then proves each slice is still what
// is deployed (occurs EXACTLY once in pg_get_functiondef), replaces it, and proves the length moved
// by exactly the hunk delta.
//
//   node scripts/gen-0317-one-authority-for-attack.mjs          # write the migration
//   node scripts/gen-0317-one-authority-for-attack.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000317_one_authority_for_attack.sql');
const SELF = '20260618000317';

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECKS ─────────────────────────────────────────────────────────────────────────────────
// Establish, mechanically, that the files sliced below really are the deployed text.
//   (1) calculate_expedition_stats: no `create or replace` after 0205 (the last one). A later
//       re-create makes every 0205 slice stale outright.
//   (2) calculate_expedition_stats: no later REPLACE-REWRITER (the house `(idx, 'fname',` hunk-row
//       shape). There has never been one; this gate is what keeps that true.
//   (3) combat_create_group_encounter: no `create or replace` after 0301.
//   (4) combat_create_group_encounter: no hunk-row rewriter after 0316 (the newest one).
// `--` line comments are stripped first — several migrations name these functions in prose.
{
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const files = readdirSync(MIGDIR).filter((f) => f.endsWith('.sql') && version(f) !== SELF);
  const stripped = new Map(
    files.map((f) => [f, readFileSync(MIG(f), 'utf8').replace(/--[^\n]*/g, '')]));

  const guard = (fname, headVer, surgeryVer) => {
    const reCreate = new RegExp(`create\\s+or\\s+replace\\s+function\\s+(?:public\\.)?${fname}\\s*\\(`, 'i');
    const newerHeads = files.filter((f) => version(f) > headVer && reCreate.test(stripped.get(f)));
    if (newerHeads.length > 0) {
      throw new Error(
        `${fname} was textually re-created AFTER ${headVer.slice(-4)} by: ${newerHeads.join(', ')} — ` +
        're-point the slices at the new head before generating.');
    }
    const reHunkRow = new RegExp(`\\(\\s*\\d+\\s*,\\s*'${fname}'\\s*,`);
    const newerSurgery = files.filter((f) => version(f) > surgeryVer && reHunkRow.test(stripped.get(f)));
    if (newerSurgery.length > 0) {
      throw new Error(
        `${fname} was rewritten by hunk surgery AFTER ${surgeryVer.slice(-4)} by: ${newerSurgery.join(', ')} — ` +
        'read that migration and re-point these slices; do not regenerate blindly.');
    }
  };
  guard('calculate_expedition_stats', '20260618000205', '20260618000205');
  guard('combat_create_group_encounter', '20260618000301', '20260618000316');
}

const F205 = load('20260618000205_cmdbuff_command_buffs.sql');
const F301 = load('20260618000301_intercept_fires_at_zone_entry.sql');
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

/** Slice a region whose LAST line is the closing line of a dollar-quoted hunk body inside an
 *  already-generated migration, and strip the emitter's closing tag. Asserting the exact suffix is
 *  what stops a silent mis-slice: if the emitted shape ever changes, this throws instead of
 *  carrying a stray `$h3n$),` into a new hunk. */
function sliceHunkTail(lines, file, from, to, startsWith, endsWith, tail) {
  const text = slice(lines, file, from, to, startsWith, endsWith);
  if (!text.endsWith(tail)) {
    throw new Error(`${file}:${to} does not end with ${JSON.stringify(tail)} — the emitted hunk shape moved`);
  }
  return text.slice(0, text.length - tail.length);
}

/** Replace `from` with `to` in `base`, demanding `from` occurs EXACTLY once — the parity guard
 *  that lets new_t be CONSTRUCTED from the slice instead of retyped. */
function edit(base, from, to) {
  const n = base.split(from).length - 1;
  if (n !== 1) throw new Error(`edit(): needle occurs ${n} time(s), want exactly 1: ${JSON.stringify(from)}`);
  return base.replace(from, to);
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════
// THE FOLD — calculate_expedition_stats (nine hunks, all sliced from 0205)
// ══════════════════════════════════════════════════════════════════════════════════════════════════

// [F1] the declare block loses the three locals that existed ONLY for the support-craft path.
const F1_OLD = slice(F205, '0205', 329, 341, 'r        record;', "v_warnings  jsonb := '[]'::jsonb;");
const F1_NEW = edit(
  edit(F1_OLD,
    '  r        record;\n  v_used   integer := 0;\n  -- accumulated support contributions\n',
    '  -- 0317: r / v_used / v_warnings are GONE with the support-craft loop that was their only\n' +
    '  -- reader. What survives is the accumulator SET — every source (hull, traits, command buffs,\n' +
    '  -- modules, captains) folds into these and nothing else.\n'),
  "\n  v_warnings  jsonb := '[]'::jsonb;", '');

// [F2] THE HULL READS THE WHOLE VOCABULARY. The head read two keys of eight while every other
//      source read all of them.
const F2_OLD = slice(F205, '0205', 418, 421,
  'select coalesce(base_stats_json,', "a_survival := a_survival + coalesce((v_hull_stats->>'defense')::numeric, 0);");
const F2_NEW = edit(F2_OLD,
  "  a_combat   := a_combat   + coalesce((v_hull_stats->>'attack')::numeric, 0);\n" +
  "  a_survival := a_survival + coalesce((v_hull_stats->>'defense')::numeric, 0);",
  '  -- 0317: THE HULL SPEAKS THE SHARED VOCABULARY. The head read exactly two keys — attack and\n' +
  '  -- defense — while the trait loop below, the command-buff loop, the module loop and the captain\n' +
  '  -- loop all read eight. A hull could therefore declare repair/cargo/scan/mining/evasion or a\n' +
  '  -- pirate_attention in its base_stats_json and the fold would silently drop them: the same class\n' +
  '  -- of "the catalog can say it and nothing listens" defect this migration exists to remove.\n' +
  '  -- BYTE-INERT TODAY, verified on production: all three live hulls carry exactly {attack,defense}\n' +
  '  -- (starter_frigate 15/10, bulk_hauler 5/15, strike_corvette 30/10), so every added coalesce\n' +
  '  -- resolves to +0 and no live number moves.\n' +
  '  -- speed_mult_bonus is DELIBERATELY NOT read here, and that is not an oversight: the hull\n' +
  '  -- already owns the speed authority as main_ship_hull_types.base_speed — the multiplicand of the\n' +
  '  -- one speed expression — so a hull-level speed_mult_bonus would be a SECOND hull speed knob,\n' +
  '  -- the exact duplication this slice is removing elsewhere. A hull changes its speed by changing\n' +
  '  -- base_speed.\n' +
  "  a_combat   := a_combat   + coalesce((v_hull_stats->>'attack')::numeric, 0);\n" +
  "  a_survival := a_survival + coalesce((v_hull_stats->>'defense')::numeric, 0);\n" +
  "  a_repair    := a_repair    + coalesce((v_hull_stats->>'repair')::numeric, 0);\n" +
  "  a_cargo     := a_cargo     + coalesce((v_hull_stats->>'cargo')::numeric, 0);\n" +
  "  a_scout     := a_scout     + coalesce((v_hull_stats->>'scan')::numeric, 0);\n" +
  "  a_mining    := a_mining    + coalesce((v_hull_stats->>'mining')::numeric, 0);\n" +
  "  a_retreat   := a_retreat   + coalesce((v_hull_stats->>'evasion')::numeric, 0);\n" +
  "  a_attention := a_attention + coalesce((v_hull_stats->>'pirate_attention')::numeric, 0);");

// [F3] the TRAIT loop gains pirate_attention (the ninth key of the shared vocabulary).
const F3_OLD = slice(F205, '0205', 441, 448,
  "a_combat    := a_combat    + coalesce((tr.stats_json->>'attack')::numeric, 0);",
  'v_trait_speed_bonus := v_trait_speed_bonus +');
const F3_NEW = edit(F3_OLD,
  "      a_retreat   := a_retreat   + coalesce((tr.stats_json->>'evasion')::numeric, 0);\n",
  "      a_retreat   := a_retreat   + coalesce((tr.stats_json->>'evasion')::numeric, 0);\n" +
  "      -- 0317: pirate_attention joins the shared vocabulary. A trait had NO way to say it before —\n" +
  "      -- the only sources of attention were three hardcoded CASEs over role/slot_type/specialization,\n" +
  "      -- so no catalog row could ever set it. Absent key = +0, so this is byte-inert for all eight\n" +
  "      -- seeded traits.\n" +
  "      a_attention := a_attention + coalesce((tr.stats_json->>'pirate_attention')::numeric, 0);\n");

// [F4] the COMMAND-BUFF loop gains the same key.
const F4_OLD = slice(F205, '0205', 474, 481,
  "a_combat    := a_combat    + coalesce((cb.stats_json->>'attack')::numeric, 0);",
  'v_cmdbuff_speed_bonus := v_cmdbuff_speed_bonus +');
const F4_NEW = edit(F4_OLD,
  "      a_retreat   := a_retreat   + coalesce((cb.stats_json->>'evasion')::numeric, 0);\n",
  "      a_retreat   := a_retreat   + coalesce((cb.stats_json->>'evasion')::numeric, 0);\n" +
  "      -- 0317: pirate_attention joins the shared vocabulary here too — a command buff is a fleet\n" +
  "      -- identity and 'this doctrine makes you conspicuous' is exactly the kind of thing it should\n" +
  "      -- be able to say. Absent key = +0: byte-inert for all twenty seeded buffs.\n" +
  "      a_attention := a_attention + coalesce((cb.stats_json->>'pirate_attention')::numeric, 0);\n");

// [F5] THE DEAD SUPPORT-CRAFT PATH — deleted, and the parameter made fail-closed.
const F5_OLD = slice(F205, '0205', 487, 537,
  '(3)(4)(5)(6)(8) Normalize + validate the loadout', 'end if;');
const F5_NEW =
`  -- 0317 THE SUPPORT-CRAFT PATH IS DELETED (51 lines of unreachable code, not disabled — removed).
  -- p_loadout is a literal '[]' at every call site in the database: calculate_group_expedition_stats,
  -- combat_create_group_encounter, get_my_group_expedition_preview and send_ship_group_hunt all pass
  -- an empty array, and get_my_expedition_preview merely FORWARDS its own argument, whose only
  -- caller — src/features/map/mainshipApi.ts:247 — hard-codes []. So the normalize/validate loop,
  -- the support_capacity HARD CAP, the role tradeoff CASE (the only writer of a_attention that no
  -- catalog row could reach) and the entire v_warnings array could never execute. They are gone.
  -- THE PARAMETER STAYS, deliberately. Dropping it would mean re-creating five live functions and
  -- changing the signature of a client-granted RPC (get_my_expedition_preview) — a wide, live-game
  -- blast radius for no player-visible gain. Instead it is now FAIL-CLOSED: a non-empty loadout is
  -- REFUSED rather than silently ignored, so nothing can quietly stop working. get_my_expedition_preview
  -- already catches this function's raises and reports valid:false with the message, exactly as it
  -- does for every other validation, so the client degrades the way it always has.
  if coalesce(jsonb_array_length(coalesce(p_loadout, '[]'::jsonb)), 0) <> 0 then
    raise exception 'calculate_expedition_stats: support craft are retired — p_loadout must be empty (got % entries)',
      jsonb_array_length(p_loadout);
  end if;`;

// [F6] the MODULE loop: pirate_attention becomes catalog-settable, the CASE stays as the DEFAULT.
const F6_OLD = slice(F205, '0205', 569, 569,
  "a_attention := a_attention + (case m.slot_type when 'weapon' then 2",
  'else 0 end) * m.slot_cost;');
const F6_NEW =
`    -- 0317: pirate_attention IS NOW A CATALOG KEY, and the CASE below is its DEFAULT — used only
    -- when the row does not state a value. Before this, attention could be produced by exactly three
    -- hardcoded CASEs and by nothing else, so "this module draws pirates" was a fact no module could
    -- state about itself. Byte-inert for the nine seeded module types (none carries the key).
` + edit(
    edit(F6_OLD,
      'a_attention := a_attention + (case m.slot_type',
      "a_attention := a_attention +\n" +
      "      case when m.stats_json ? 'pirate_attention'\n" +
      "           then coalesce((m.stats_json->>'pirate_attention')::numeric, 0)\n" +
      "           else (case m.slot_type"),
    'else 0 end) * m.slot_cost;',
    'else 0 end) * m.slot_cost\n      end;');

// [F7] the CAPTAIN loop: the same, and DELIBERATELY unscaled by level/affinity — the head already
//      keeps the attention tradeoff level-flat ("growth is never a stealth cost raise").
const F7_OLD = slice(F205, '0205', 641, 641,
  "a_attention := a_attention + (case c.specialization when 'combat' then 2",
  'else 0 end);');
const F7_NEW =
`    -- 0317: pirate_attention IS NOW A CATALOG KEY here too, with the CASE as its default. It is
    -- NOT multiplied by v_lvl_mult / v_aff_mult — the head keeps the attention tradeoff level-flat
    -- and station-flat on purpose ("growth is never a stealth cost raise"), and a stated value must
    -- follow the same law as the default it replaces. Byte-inert for the five seeded captain types.
` + edit(
    edit(F7_OLD,
      'a_attention := a_attention + (case c.specialization',
      "a_attention := a_attention +\n" +
      "      case when c.stats_json ? 'pirate_attention'\n" +
      "           then coalesce((c.stats_json->>'pirate_attention')::numeric, 0)\n" +
      "           else (case c.specialization"),
    'else 0 end);',
    'else 0 end)\n      end;');

// [F8] the return object drops the two support-capacity fields.
const F8_OLD = slice(F205, '0205', 666, 672,
  'return jsonb_build_object(', "'module_slots_limit',     v_ship.module_slots,");
const F8_NEW = edit(F8_OLD,
  "    'support_capacity_used',  v_used,\n    'support_capacity_limit', v_ship.support_capacity,\n",
  '    -- 0317: support_capacity_used / support_capacity_limit are GONE with the loop that computed\n' +
  '    -- them. Nothing read either one: no in-database function and no line of src/ (the client\n' +
  "    -- shapes are ShipStatsStrip and MemberStats/ADDITIVE_STAT_KEYS, neither of which lists them),\n" +
  "    -- and the ship's own support_capacity column is still reported by get_my_expedition_preview's\n" +
  '    -- ship object, so the number itself has not become unreachable — only its duplicate here.\n');

// [F9] …and the warnings array, which only the deleted loop could ever append to.
const F9_OLD = slice(F205, '0205', 683, 685,
  "'pirate_attention', greatest(0, round(a_attention, 2)),", ');');
const F9_NEW =
`    -- 0317: 'warnings' is GONE. The deleted support-craft loop was its only writer, so after this
    -- slice it could only ever be [] — a field that exists to say nothing. No in-database reader and
    -- no client reader (grep-verified across src/).
` + edit(F9_OLD,
    "    'pirate_attention', greatest(0, round(a_attention, 2)),\n    'warnings',         v_warnings\n  );",
    "    'pirate_attention', greatest(0, round(a_attention, 2))\n  );");

// ══════════════════════════════════════════════════════════════════════════════════════════════════
// THE BUILDER — combat_create_group_encounter (eight hunks; sources 0301 / 0315)
// ══════════════════════════════════════════════════════════════════════════════════════════════════

// [B1] three new locals, appended after 0315's last declaration (0315 owns that line's deployed text).
const B1_OLD = sliceHunkTail(F315, '0315', 213, 213, 'v_is_lead         boolean;', 'v_is_lead', '$h1n$),');
const B1_NEW = B1_OLD + '\n' +
`  -- 0317 THE ONE AUTHORITY FOR ATTACK: v_weight_total is the sum of the SHARE WEIGHTS over this
  -- ship's weapon entries, used at exactly one line to turn weights into damage. v_hp_max is the
  -- ship's CAPACITY (main_ship_instances.max_hp), which the head confused with its current hp.
  v_weight_total    double precision;
  v_hp_max          double precision;
  v_hull_cur        double precision;`;

// [B2] the member projection carries max_hp (0315 owns this line's deployed text).
const B2_OLD = sliceHunkTail(F315, '0315', 272, 272,
  'select gsm.main_ship_id, gsm.player_id', 'msi.max_shield', '$h3n$),');
const B2_NEW =
`    -- 0317: msi.max_hp joins the projection. The builder already reads this row; the ONE thing it
    -- never took from it was the ship's capacity, which is why the fleet's integrity bar and 0310's
    -- auto-exit denominator could disagree.
` + edit(B2_OLD, 'msi.max_shield', 'msi.max_shield, msi.max_hp');

// [B3] hp_max is seeded UNCONDITIONALLY, at the top of the loop, beside the other per-member resets.
const B3_OLD = slice(F301, '0301', 733, 734,
  'v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;', 'v_shield_max := null; v_shield_cur := null;');
const B3_NEW = B3_OLD + '\n' +
`    -- 0317 THE INTEGRITY BAR TELLS THE TRUTH. combat_units.hp_max was seeded from the ship's
    -- CURRENT hp, so player_integrity_max (the sum of it, below) always equalled
    -- player_integrity_current at creation and every fleet entered every fight showing a FULL bar,
    -- however battered it was. Meanwhile 0310's auto-exit divides by sum(main_ship_instances.max_hp),
    -- recomputed live each tick — real capacity. Two fleet-level "how much hull" numbers that could
    -- never agree: measured on the owner's own fleet, 583 hull against 2000 capacity displayed as
    -- 583/583 (a full bar) and auto-exited on tick 1 at a 30% threshold with nothing on screen
    -- explaining it. hp_max now means capacity, from the one column that has always meant it, so
    -- both numbers derive from a single definition. Set unconditionally — outside the hp>0 branch,
    -- like v_aggro_priority — because 0310's denominator counts every player row including wrecks,
    -- and the two sums must be equal by construction, not by coincidence.
    v_hp_max := m.max_hp;`;

// [B4] the roster entry carries it through to the INSERT.
const B4_OLD = slice(F301, '0301', 810, 815,
  'v_roster := v_roster || jsonb_build_array(jsonb_build_object(', "'weapons_json', v_weapons_json));");
const B4_NEW = edit(B4_OLD,
  "      'main_ship_id', m.main_ship_id, 'player_id', m.player_id, 'hp', v_hp,",
  "      'main_ship_id', m.main_ship_id, 'player_id', m.player_id, 'hp', v_hp, 'hp_max', v_hp_max,");

// [B5] the INSERT reads hp_max from the roster instead of re-using hp.
const B5_OLD = slice(F301, '0301', 847, 848,
  "(e->>'hp')::double precision, 1, (e->>'alive')::integer,", "(e->>'hp')::double precision, (e->>'hp')::double precision,");
const B5_NEW = edit(B5_OLD,
  "         (e->>'hp')::double precision, (e->>'hp')::double precision,",
  "         (e->>'hp_max')::double precision, (e->>'hp')::double precision,");
// ship_hp (the first value on the line above) is deliberately UNTOUCHED: it is the per-stack hull
// size the tick divides by to derive alive_count, and for a one-ship member row "the hp it entered
// with" is exactly the right divisor. Only hp_max changes meaning here.

// [B6] …and the encounter's two integrity columns stop being the same number.
const B6_OLD = slice(F301, '0301', 855, 856,
  'select coalesce(sum(hp_max), 0) into v_hull', 'update combat_encounters set player_integrity_max = v_hull');
const B6_NEW =
`  -- 0317: MAX and CURRENT are now two different sums, because they are two different questions.
  -- The head asked sum(hp_max) once and wrote the answer into both columns — which was self-
  -- consistent only while hp_max meant "hp at entry". With hp_max meaning capacity (B3), current
  -- integrity is sum(hp_current), the same quantity process_combat_ticks recomputes and writes every
  -- tick (0299:718 / :1002, greatest(0, sum(hp_current) over the player side)). So the bar the
  -- player sees at tick 0 is now continuous with the one the tick maintains from tick 1 on, and
  -- player_integrity_max equals 0310's live denominator exactly.
` + edit(
    edit(B6_OLD,
      '  select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;',
      '  select coalesce(sum(hp_max), 0), coalesce(sum(hp_current), 0) into v_hull, v_hull_cur\n' +
      '    from combat_units where encounter_id = v_enc;'),
    'player_integrity_current = v_hull where id = v_enc;',
    'player_integrity_current = v_hull_cur where id = v_enc;');

// [B7] the fallback weapon carries a WEIGHT, not a power.
const B7_OLD = slice(F301, '0301', 796, 796,
  "'power',            v_attack * coalesce(public.cfg_num('combat_player_fallback_weapon_power_from_attack'), 1),",
  'combat_player_fallback_weapon_power_from_attack');
const B7_NEW =
`              -- 0317: THE SYNTHESIZED WEAPON CARRIES A WEIGHT OF 1, NOT A POWER. It is the ship's
              -- only weapon entry, so it takes the whole share and the normalisation below resolves
              -- it to exactly the ship's combat_power — which is what the knob
              -- combat_player_fallback_weapon_power_from_attack (seeded 1) was expressing. That knob
              -- is DELETED by this migration: it was a second, independently-settable multiplier on
              -- one of the two paths, i.e. precisely the drift this slice exists to remove. The
              -- fitted path and the no-weapon path now run the SAME rule, at the same line.
              'power',            1,`;
// (B7_NEW is a full replacement of the single sliced line; the slice is retained above only as the
//  exactly-once locator. Its own text is not reused because every word of it is being removed.)

// [B8] THE NORMALISATION — the one line where the fold becomes damage. Appended after the fallback
//      block so it governs BOTH paths.
const B8_OLD = slice(F301, '0301', 801, 802, "'ammo_remaining',   null));", 'end if;');
const B8_NEW = B8_OLD + '\n' +
`
          -- ██ 0317 ONE AUTHORITY FOR ATTACK ██████████████████████████████████████████████████████
          -- THE FOLD DECIDES HOW MUCH; THE WEAPON DECIDES HOW. Every entry's power is rewritten from
          -- this ship's combat_power (v_attack — calculate_expedition_stats' fold of hull + traits +
          -- command buffs + modules + captains, the number the card shows) split across the ship's
          -- weapon entries in proportion to their catalog module_types.power, which is from this
          -- migration a unitless SHARE WEIGHT and never a damage number.
          -- WHY: the head copied module_types.power into weapons_json flat, and process_combat_ticks
          -- reads ONLY weapons_json for damage (0299:568 -> :607/:609) — attack_snapshot is used for
          -- damage exactly zero times on the spatial arm, which is the live arm. So a hull's attack,
          -- every captain, every trait and every command buff contributed NOTHING to damage for any
          -- ship with a gun fitted, and the two numbers were kept equal only by the hand-sync
          -- convention 0229:88-91 writes down in prose. Fitting a better gun could LOWER a ship's
          -- damage while its card said it had got stronger.
          -- SHARE, NOT EACH: a ship's weapons together deliver its combat_power per volley, so the
          -- card is exactly right. Giving every gun the full combat_power would make a second gun
          -- double the damage while the card moved by only that module's own attack — the same lie
          -- in the other direction. Fitting a gun still makes a ship stronger, because the module's
          -- stats_json.attack raises combat_power: that is now the ONE place a module's damage is
          -- expressed, and module_types.power only decides which of its guns carries which slice of it.
          -- SCALE-INVARIANT BY CONSTRUCTION: the weights appear only as p_i / sum(p), so doubling
          -- every catalog power changes nothing. That is what makes the column unable to drift back
          -- into being a damage authority, and it is why this migration does NOT assert that a
          -- module's power equals its stats_json.attack — asserting that would re-create the very
          -- hand-sync convention it is deleting.
          -- A ship whose combat_power is 0 now deals 0 with a gun fitted. That is the rule working,
          -- not a regression: unreachable in the live catalog (any firing weapon contributes at
          -- least +10 attack through the fold) and stated here so it is a decision, not a surprise.
          select coalesce(sum(coalesce((w->>'power')::double precision, 0)), 0)
            into v_weight_total
            from jsonb_array_elements(v_weapons_json) as w;
          if v_weight_total > 0 then
            select coalesce(jsonb_agg(z.w || jsonb_build_object('power',
                     coalesce(v_attack, 0) * coalesce((z.w->>'power')::double precision, 0) / v_weight_total)
                     order by z.ord), '[]'::jsonb)
              into v_weapons_json
              from jsonb_array_elements(v_weapons_json) with ordinality as z(w, ord);
          end if;`;

const HUNKS = [
  [1, 'calculate_expedition_stats', F1_OLD, F1_NEW],
  [2, 'calculate_expedition_stats', F2_OLD, F2_NEW],
  [3, 'calculate_expedition_stats', F3_OLD, F3_NEW],
  [4, 'calculate_expedition_stats', F4_OLD, F4_NEW],
  [5, 'calculate_expedition_stats', F5_OLD, F5_NEW],
  [6, 'calculate_expedition_stats', F6_OLD, F6_NEW],
  [7, 'calculate_expedition_stats', F7_OLD, F7_NEW],
  [8, 'calculate_expedition_stats', F8_OLD, F8_NEW],
  [9, 'calculate_expedition_stats', F9_OLD, F9_NEW],
  [10, 'combat_create_group_encounter', B1_OLD, B1_NEW],
  [11, 'combat_create_group_encounter', B2_OLD, B2_NEW],
  [12, 'combat_create_group_encounter', B3_OLD, B3_NEW],
  [13, 'combat_create_group_encounter', B4_OLD, B4_NEW],
  [14, 'combat_create_group_encounter', B5_OLD, B5_NEW],
  [15, 'combat_create_group_encounter', B6_OLD, B6_NEW],
  [16, 'combat_create_group_encounter', B7_OLD, B7_NEW],
  [17, 'combat_create_group_encounter', B8_OLD, B8_NEW],
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
  // PLPGSQL VARIABLE CAPTURE (the 0310 rev.2 / 0314 / 0315 lesson): plpgsql resolves table-alias-
  // qualified references against VARIABLES too, so an alias that shadows a declared record variable
  // raises "ambiguous" at FIRST EXECUTION only — no static probe can see it. The two functions
  // rewritten here declare, between them, the record variables pr, m, r, c, tr, cb and z is free.
  // Applied to the NEW text; the old text is the deployed head.
  {
    const captured = fname === 'combat_create_group_encounter' ? 'pr|m' : 'r|m|c|tr|cb';
    const mm = newT.match(new RegExp(`\\b(?:from|join)\\s+[a-z_][a-z0-9_.]*\\s+(?:as\\s+)?(${captured})\\b`, 'i'));
    if (mm) throw new Error(`hunk ${idx} aliases a table as '${mm[1]}' — that name is a plpgsql record variable in ${fname} and the reference would be ambiguous at first execution`);
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

const sql = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0317 — ONE AUTHORITY FOR ATTACK
--        (the fold's combat_power becomes the damage a ship deals; a weapon decides HOW it is
--         delivered, never HOW MUCH — and the fold itself stops carrying a dead path)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE OWNER'S DESIGN, VERBATIM ────────────────────────────────────────────────────────────────
--   "we can set power, range, speed, accuracy for each ship, modules and captains. Total power will
--    be shown on fleet as a whole … when changing a captain, ship, module, the code can simply
--    apply simple number then it will be done - no spaghetti."
--
-- ── THE DEFECT: TWO AUTHORITIES FOR ATTACK, AND THE WRONG ONE DECIDED DAMAGE ────────────────────
--   THE FOLD.  calculate_expedition_stats (0205 §8) combines hull + ship traits + command buffs +
--              fitted modules + assigned captains into ONE number, 'combat_power'. That is the
--              number the ship card, the fleet card and player_power_start all show.
--   THE DAMAGE. process_combat_ticks reads combat_units.weapons_json->'power' and nothing else:
--              0299:568 loads it, :607 and :609 multiply it into the hit. attack_snapshot — the
--              column that holds the folded combat_power — is used for DAMAGE exactly ZERO times on
--              the spatial arm, and the spatial arm is the live arm (spatial_combat_enabled = true
--              in production). weapons_json's power was copied FLAT off module_types.power at
--              encounter creation.
--   They were kept equal by hand. 0229:88-91 says so in prose ("keep .power in step with
--   stats_json.attack"), and production still shows the convention holding by luck:
--   autocannon_battery attack 10 / power 10, autocannon_battery_mk2 attack 18 / power 18.
--
--   THE CONSEQUENCE, on the live game: every hull attack, every captain, every trait and every
--   command buff contributed NOTHING to damage for any ship with a weapon fitted. Fitting a gun
--   REPLACED the ship's own strength with the gun's — so a strike_corvette (hull attack 30) with a
--   captain and a trait reading combat_power 46 would, on fitting an autocannon_battery, show a
--   HIGHER card (56) and deal LESS damage (10 instead of 46). The fix that made this visible was
--   0308, which stopped a mining rig counting as a gun; this migration removes the class.
--
-- ── THE RULE THIS MIGRATION SHIPS ───────────────────────────────────────────────────────────────
--   A SHIP'S WEAPONS TOGETHER DELIVER ITS combat_power PER VOLLEY, SPLIT IN PROPORTION TO THEIR
--   CATALOG module_types.power.
--
--     weapons_json[i].power := combat_power * power_i / sum(power over the ship's firing weapons)
--
--   • ONE number now means "how hard does this ship hit", and it is the number on the card.
--   • module_types.power is REDEFINED as a unitless SHARE WEIGHT (see the column comment this
--     migration writes). It appears only as a ratio, so its SCALE cannot affect anything: doubling
--     every catalog power changes no damage at all. That is what makes it structurally incapable of
--     drifting back into a second damage authority, and it is why this migration deliberately does
--     NOT assert power = stats_json.attack — such an assert would re-create the hand-sync
--     convention it is deleting.
--   • A module's contribution to DAMAGE is its stats_json.attack, folded like everything else. That
--     is the one place it is expressed. Fitting a gun still makes a ship stronger.
--   • MULTI-WEAPON: share, not each. Production ships all carry module_slots = 3 and one live ship
--     has THREE autocannon_batteries fitted, so this is not hypothetical. If every gun carried the
--     full combat_power, a second gun would double damage while the card moved by only that
--     module's own attack — the same lie in the other direction. Sharing keeps the card exact.
--   • THE FITTED AND UNFITTED PATHS ARE ONE RULE, AT ONE LINE. The 0262 synthesized basic weapon is
--     given a weight of 1 and then runs through the SAME normalisation; being the only entry, it
--     takes the whole share and resolves to exactly combat_power. The knob that used to express
--     that separately, combat_player_fallback_weapon_power_from_attack, is DELETED — a second,
--     independently-settable multiplier on one of the two paths is exactly the drift being removed.
--   • WHAT A WEAPON STILL DECIDES: range (whether the volley reaches), cooldown_seconds (how often
--     it lands), projectile_speed (the telegraph), ammo, and its SHARE of the volley. combat_power
--     is damage per volley; the weapon's cadence is what turns that into damage per second.
--
-- ── THE ENEMY SIDE: UNCHANGED, AND ALREADY THIS SHAPE ───────────────────────────────────────────
-- Nothing about enemy damage is touched. It is worth stating WHY that leaves the two sides coherent
-- rather than merely untouched: the synthetic spawn (0299:748-763, and the resolved twin at
-- :703-710) computes ONE wave-level attack total — base_difficulty x enemy_attack_base x
-- (1 + danger x scale) — and then divides it across the units it spawns
-- (v_enemy_unit_power := v_enemy_attack / v_enemy_count). That is the same shape this migration
-- gives the player: one folded total, shared across the delivery points. An enemy unit carries one
-- weapon, so its share is its power; a player ship carries N, so they share its combat_power. After
-- this slice both sides answer "how hard does this side hit" from exactly one number each.
--
-- ── BALANCE: WHO GETS STRONGER, EXACTLY (live catalog, live knobs, read from production) ────────
-- Every live hull is a starter_frigate (attack 15, defense 10, max_hp 500, module_slots 3); zero
-- ship traits are rolled and zero captains are assigned in production; the only command buff in
-- play grants cargo. combat_tick_seconds = 3 and every firing weapon's cooldown (2 / 2.5, and the
-- fallback's 2) is at or under it, so every fitted weapon fires once per tick and
-- dps = (sum of entry power) / 3. The per-hit roll is symmetric (combat_hit_variance_pct 0.5) with
-- mean 1.0, and player fire on enemies is not defense-mitigated.
--
--   configuration                                card   BEFORE volley/dps   AFTER volley/dps   x
--   starter_frigate, no weapon (76 of 77 ships)    15     15  / 5.00          15  / 5.00        1.00
--   + 1 autocannon_battery                         25     10  / 3.33          25  / 8.33        2.50
--   + 2 autocannon_battery                         35     20  / 6.67          35  / 11.67       1.75
--   + 3 autocannon_battery  (the ONE live fit)     45     30  / 10.00         45  / 15.00       1.50
--   + 1 autocannon_battery_mk2                     33     18  / 6.00          33  / 11.00       1.83
--   + mk2 + battery (3 slots)                      43     28  / 9.33          43  / 14.33       1.54
--   strike_corvette + 1 battery (not live yet)     40     10  / 3.33          40  / 13.33       4.00
--   bulk_hauler + 1 battery      (not live yet)    15     10  / 3.33          15  / 5.00        1.50
--   any of the above + gunnery_veteran captain     +4     no change           +1.33 dps         —
--   any of the above + hungry_guns trait           +6     no change           +2.00 dps         —
--   any of the above + t1_gunnery_doctrine buff    +6     no change           +2.00 dps         —
--   any of the above + ill_omened trait            -2     no change           -0.67 dps         —
--
--   WHO GETS WEAKER: nobody, in the live catalog. after - before collapses to
--   (hull attack + traits + captains + buffs), because both live guns happen to carry
--   stats_json.attack = power. That sum is >= 0 for every live ship. The ONLY way a ship loses
--   damage under this rule is if its non-module attack contributions sum NEGATIVE, which needs a
--   negative-attack trait on a zero-attack hull — no hull has attack 0. So: 76 of 77 live ships are
--   unchanged today (they carry no weapon and already fired their own attack through the 0262
--   fallback), 1 gains x1.5, and every ship gains the moment it fits a gun.
--   THE ENEMY IS NOT COMPENSATED. This is a straight buff to armed players of roughly 1.5x-2.5x at
--   the live catalog, and up to 4x on hulls that are not yet flyable. Holding difficulty constant is
--   a SEPARATE decision with its own levers (enemy_hp_base 14, enemy_attack_base 1.0) and this
--   migration deliberately touches neither: a balance retune must stay independently reversible.
--
-- ── ALSO IN THIS MIGRATION (same two functions, so one re-creation rather than four) ────────────
--   FOLD HYGIENE
--   1. THE HULL READS ALL EIGHT STAT KEYS (0205:418-421 read two of them). Byte-inert today —
--      verified on production: all three hulls carry exactly {attack, defense}. speed_mult_bonus is
--      deliberately excluded; the hull's speed authority is base_speed and a second one would be
--      the duplication this slice removes.
--   2. THE DEAD SUPPORT-CRAFT PATH IS DELETED (0205:487-537 plus its declares and output fields).
--      p_loadout is '[]' at every call site in the database and the single client caller hard-codes
--      [] — so the loop, the support_capacity cap, the role tradeoff CASE and the warnings array
--      were unreachable. The parameter stays (dropping it would re-create five live functions and
--      change a client-granted signature) but is now fail-closed rather than silently ignored.
--      p_activity_type is NOT vestigial in the same sense and is NOT touched: it still gates the
--      function (an unknown activity raises, which is how get_my_group_expedition_preview reports
--      invalid_activity) and is still echoed. What IS now true of it, and is stated at the site, is
--      that it influences no number this function returns.
--   3. pirate_attention JOINS THE SHARED VOCABULARY. It could previously be produced by three
--      hardcoded CASEs and by NOTHING ELSE — no module, captain or trait row could set it. Every
--      source now reads the key; where a CASE exists it becomes the DEFAULT, used only when the row
--      is silent. Byte-inert: no seeded row carries the key.
--   THE INTEGRITY BAR (folded in because it lives in the same function)
--   4. combat_units.hp_max WAS THE SHIP'S CURRENT HP. So player_integrity_max = sum(hp_max) equalled
--      player_integrity_current at creation and every fleet entered every fight with a FULL bar,
--      however damaged — while 0310's auto-exit divides by sum(main_ship_instances.max_hp), real
--      capacity, recomputed live. Measured on the owner's own fleet: 583 hull of 2000 capacity shown
--      as 583/583 and auto-exited on tick 1 at a 30% threshold with nothing explaining it. hp_max
--      now means capacity and current integrity is sum(hp_current), so the two fleet-level numbers
--      derive from ONE definition. The two readers of hp_max are the client's per-unit bar
--      (ActiveCombatPanel.tsx:149, spatialCombatLayer.ts:70), which becomes truthful, and this sum.
--      combat_create_encounter's legacy fleet_units arm is untouched — its hp_max is already
--      quantity x unit_types.hull, a real maximum.
--
-- ── WHAT THIS MIGRATION DELIBERATELY DOES NOT DO ────────────────────────────────────────────────
--   • No accuracy stat. No shield change. The additive-into-one-accumulator design and the speed
--     pipeline are untouched — both were found correct.
--   • module_types.power is NOT dropped and NOT renamed. Dropping it would take module_is_firing_weapon
--     (its power > 0 test IS the "is a gun" discriminator), ship_weapon_modules, 0316's pins and the
--     client module panel with it. It is redefined and documented at the column instead.
--   • calculate_group_expedition_stats (0166) is NOT touched. It sums the SAME per-ship authority
--     this builder does — calculate_expedition_stats — over a DIFFERENT membership (every ship with
--     the group_id, wrecks included) than the builder's sortie manifest filtered to living hulls.
--     That is two questions, not two authorities, and merging them would mean the builder calling
--     the per-ship fold twice per ship and taking a roster the 0308 defect was about. 0166's
--     wreck-counting is a real defect in 0166's own readers and belongs to its own slice; nothing
--     here makes that seam harder to close.
--   • No player row is read or written. No table is backfilled. No grant changes.
--
-- ── BLAST RADIUS ON THE LIVE ~30-PLAYER GAME (stated precisely) ─────────────────────────────────
--   • weapons_json, hp_max and the two integrity columns are written ONCE, AT ENCOUNTER CREATION,
--     and never recomputed (the tick MOVES units and rewrites next_ready_at; 0311 TRANSLATES them;
--     neither re-anchors). SO AN IN-FLIGHT FIGHT SEES NONE OF THIS. A fight that is open when this
--     migration lands keeps its flat catalog powers, its full-looking bar and its old auto-exit
--     mismatch until it ends. Every property here appears at the NEXT encounter creation: the next
--     ambush, the next hunt arrival. Nothing is repaired mid-flight and nothing is disturbed
--     mid-flight. At the time of writing production has ZERO active encounters.
--   • calculate_expedition_stats is STABLE and read on every card, preview and fight entry. Its
--     output loses three fields (support_capacity_used, support_capacity_limit, warnings) that no
--     database function and no line of src/ reads, and gains nothing. Every number it returns is
--     unchanged for every live ship: the hull-vocabulary and pirate_attention additions resolve to
--     +0 against the deployed catalog, and the loadout deletion removes a path no caller enters.
--   • Both function changes are CREATE OR REPLACE by text surgery over pg_get_functiondef: atomic
--     catalog swaps. No table is locked, no row is written, nothing is backfilled.
--   • The only data write is the DELETE of one game_config row
--     (combat_player_fallback_weapon_power_from_attack) whose sole reader is removed in the same
--     statement block, plus one column comment.
--
-- ── EXACTLY-ONCE / FAIL-CLOSED ─────────────────────────────────────────────────────────────────
-- Each of the seventeen hunks must occur EXACTLY once in the deployed body and the rewrite must
-- move the length by exactly that hunk's delta, or the migration aborts before writing anything
-- else. A re-apply cannot double-apply: the second run finds zero occurrences and raises.
--
-- ── WHY THE EXPLICIT TRANSACTION BLOCK (the same guard every sibling carries: 0310:174-177,
--    0311:202-205, 0312:107-110, 0313:113-116, 0316:354-357) ─────────────────────────────────────
-- This file re-creates the two functions every combat entry and every ship card runs through, and
-- deletes a public.game_config row, on a LIVE ~30-player production. Without \`set local
-- lock_timeout\` a write that meets a concurrent tick's row lock waits INDEFINITELY, and a migration
-- hung inside \`supabase db push\` blocks every migration after it. 5s fails fast instead; the deploy
-- is then re-run in a quiet window. \`statement_timeout\` bounds the self-asserts the same way, and
-- \`time zone 'UTC'\` pins the now() any updated_at stamp carries. The block is also what makes
-- \`create temp table … on commit drop\` mean anything: outside an explicit transaction each statement
-- is its own txn, so the capture table would be dropped before the asserts that read it ever ran.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────────────────────────
-- Re-apply the two functions with every hunk reverted (each new_t back to its old_t), re-insert
-- combat_player_fallback_weapon_power_from_attack at 1, and restore the old column comment. No
-- state to unwind: this migration writes no player data and backfills nothing. Fights opened under
-- it are unaffected by the revert for the same freeze-at-creation reason stated above.
--
-- Forward-only: 0001-0316 unedited.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ──────────────
do $pre$
declare v_src text; v_n integer;
begin
  -- calculate_expedition_stats — located BY NAME (its 4-arg signature is stable, but the loop below
  -- locates by name and the overload count is what makes that safe).
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'calculate_expedition_stats';
  if v_n <> 1 then
    raise exception '0317 PRECONDITION FAIL: public.calculate_expedition_stats has % definition(s), want exactly 1', v_n;
  end if;
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'calculate_expedition_stats';
  if position('v_cmdbuffs_enabled' in v_src) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed fold does not carry the 0205 command-buff hunk — the slices were cut against a different head';
  end if;
  if position('support_craft_types' in v_src) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed fold has no support-craft loop — it has already been simplified by something this migration does not know about';
  end if;
  if position('pirate_attention' in v_src) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed fold does not emit pirate_attention at all — this is not the function 0317 was generated against';
  end if;

  -- combat_create_group_encounter — BY NAME, never by a typed signature: 0301 gave it two more
  -- parameters, so to_regprocedure('…(uuid)') answers NULL on the very chain this is built for.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if v_n <> 1 then
    raise exception '0317 PRECONDITION FAIL: public.combat_create_group_encounter has % definition(s), want exactly 1', v_n;
  end if;
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('p_engagement_x' in v_src) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed builder does not carry the 0301 mandatory engagement point';
  end if;
  if position('group_sortie_live_members(pr.fleet_id)' in v_src) = 0
     or position('module_is_firing_weapon(t)' in v_src) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed builder lacks the 0308 authorities';
  end if;
  if position('v_lead_ship_id' in v_src) = 0 or position('v_is_lead' in v_src) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed builder has no 0315 lead derivation';
  end if;
  if position('combat_player_speed_scale' in v_src) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed builder has no 0316 combat speed scale — the head this slice was cut against is not deployed';
  end if;
  if position('v_weight_total' in v_src) > 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed builder already normalises weapon power — refusing to re-emit over an unknown edit';
  end if;
end $pre$;

-- ── 1. CAPTURE what must not move, BEFORE any write (derived, never hard-coded) ─────────────────
create temp table _0317_before (k text primary key, v text) on commit drop;

insert into _0317_before
select 'mod_' || id || '_' || key, value from (
  select id, 'power' as key, coalesce(power::text, '<null>') as value from public.module_types
  union all select id, 'range', coalesce(range::text, '<null>') from public.module_types
  union all select id, 'cooldown_seconds', coalesce(cooldown_seconds::text, '<null>') from public.module_types
  union all select id, 'slot_type', slot_type from public.module_types
  union all select id, 'stats_json', stats_json::text from public.module_types
) m;

insert into _0317_before
select 'cfg_' || key, value::text from public.game_config
 where key in ('combat_player_fallback_weapon_range', 'combat_player_fallback_weapon_projectile_speed',
               'combat_player_fallback_weapon_cooldown_seconds', 'combat_player_fallback_weapon_module_type_id',
               'combat_tick_seconds', 'enemy_attack_base', 'enemy_hp_base', 'spatial_formation_ring_radius');

insert into _0317_before
select 'hull_' || hull_type_id, base_stats_json::text from public.main_ship_hull_types;

insert into _0317_before
select 'fn_' || p.proname, pg_get_userbyid(p.proowner) || '|' || p.prosecdef::text || '|' || p.provolatile::text
       || '|' || coalesce(array_to_string(p.proconfig, ','), '') || '|' || pg_get_function_identity_arguments(p.oid)
       || '|' || pg_get_function_result(p.oid) || '|' || coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('calculate_expedition_stats', 'combat_create_group_encounter');

-- ── 2. REWRITE THE SEVENTEEN HUNKS (located by exact deployed text, never retyped) ──────────────
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
      raise exception '0317 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0317 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0317 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0317 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 17 then
    raise exception '0317 REWRITE FAIL: rewrote % site(s), expected 17', v_done;
  end if;
  raise notice '0317: a ship now hits for exactly the number on its card, and a weapon decides only how that number is delivered';
end $rewrite$;

-- ── 3. THE KNOB THAT EXPRESSED THE OLD SECOND RULE IS DELETED ───────────────────────────────────
-- Its sole reader in the entire database was the line hunk 16 just rewrote. Guarded on the exact
-- value the chain seeded, so an owner who had retuned it is never silently overridden — the assert
-- below then aborts rather than letting a partial slice ship.
delete from public.game_config
 where key = 'combat_player_fallback_weapon_power_from_attack' and value = '1'::jsonb;

-- ── 4. THE COLUMN SAYS WHAT IT NOW MEANS ────────────────────────────────────────────────────────
comment on column public.module_types.power is
  'COMBAT-S0, REDEFINED BY 0317: for a FIRING WEAPON (slot_type=weapon — see module_is_firing_weapon) '
  'this is a unitless SHARE WEIGHT, never a damage number. combat_create_group_encounter splits the '
  'ship''s folded combat_power across its fitted weapons in proportion to it, so only the RATIOS '
  'between a ship''s guns matter and the absolute scale of this column affects nothing. A module''s '
  'damage contribution lives in stats_json.attack, which calculate_expedition_stats folds into '
  'combat_power — that is the one place it is expressed, and this column must never be read as an '
  'amount of damage again. A positive value here is also part of the "this is a gun" test. For the '
  'mining archetype (slot_type=mining) the column is inert: nothing reads it (mining_extract sizes '
  'its radius from .range), and 0316 pins the row byte-for-byte. NULL = not a weapon and not read.';

-- ── 5. SELF-ASSERTS — one DO block per property; RED on the pre-0317 body by construction ───────

-- (a) THE ONE AUTHORITY IS INSTALLED. The builder derives every weapon's power from the ship's
--     folded attack and from nothing else, and the deleted knob has no reader left anywhere.
do $a$
declare v_src text; v_n int;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('v_weight_total' in v_src) = 0 then
    raise exception '0317 ASSERT (a) FAIL: the builder carries no weight normalisation — hunk 17 did not land';
  end if;
  if position('combat_player_fallback_weapon_power_from_attack' in v_src) > 0 then
    raise exception '0317 ASSERT (a) FAIL: the builder still reads the deleted knob — the fitted and unfitted paths are still two rules';
  end if;
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and position('combat_player_fallback_weapon_power_from_attack' in p.prosrc) > 0;
  if v_n <> 0 then
    raise exception '0317 ASSERT (a) FAIL: % function(s) still read combat_player_fallback_weapon_power_from_attack after its row was deleted — a live reader would silently fall back to its literal', v_n;
  end if;
  if exists (select 1 from public.game_config where key = 'combat_player_fallback_weapon_power_from_attack') then
    raise exception '0317 ASSERT (a) FAIL: combat_player_fallback_weapon_power_from_attack still exists — the guarded DELETE no-opped, i.e. the deployed value had drifted off the chain this migration was written against';
  end if;
end $a$;

-- (b) THE FOLD IS SIMPLIFIED AND ITS VOCABULARY IS SHARED. Every property is read off the deployed
--     text: the dead path is gone, all eight keys reach the hull, and pirate_attention is settable
--     by all five sources.
do $b$
declare v_src text; v_k text; v_missing text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'calculate_expedition_stats';
  if position('support_craft_types' in v_src) > 0
     or position('support_capacity_used' in v_src) > 0
     or position('v_warnings' in v_src) > 0 then
    raise exception '0317 ASSERT (b) FAIL: the support-craft path survived the rewrite';
  end if;
  if position('support craft are retired' in v_src) = 0 then
    raise exception '0317 ASSERT (b) FAIL: p_loadout is not fail-closed — a non-empty loadout would be silently ignored';
  end if;
  foreach v_k in array array['attack','defense','repair','cargo','scan','mining','evasion','pirate_attention'] loop
    if position('v_hull_stats->>''' || v_k || '''' in v_src) = 0 then
      raise exception '0317 ASSERT (b) FAIL: the hull fold does not read the shared key %', v_k;
    end if;
  end loop;
  if position('v_hull_stats->>''speed_mult_bonus''' in v_src) > 0 then
    raise exception '0317 ASSERT (b) FAIL: the hull fold reads speed_mult_bonus — that would be a second hull speed authority beside base_speed';
  end if;
  v_missing := '';
  foreach v_k in array array['tr','cb','m','c'] loop
    if position(v_k || '.stats_json' in v_src) = 0 then
      raise exception '0317 ASSERT (b) FAIL: source % no longer folds stats_json at all', v_k;
    end if;
    if position(v_k || '.stats_json->>''pirate_attention''' in v_src) = 0 then
      v_missing := v_missing || v_k || ' ';
    end if;
  end loop;
  if v_missing <> '' then
    raise exception '0317 ASSERT (b) FAIL: these sources still cannot set pirate_attention: % — the key is not shared vocabulary yet', v_missing;
  end if;
end $b$;

-- (c) THE FOLD STILL RETURNS THE SAME NUMBERS FOR EVERY LIVE SHIP. Executed, not trusted: the fold
--     is called for real, on every living main ship in the database, and each result is compared
--     against the value assembled from the catalog independently of the function.
--     A FRESHLY-APPLIED DISPOSABLE CHAIN HAS NO SHIPS, and a migration may not create player data to
--     give itself something to measure. So an empty world SAYS SO, loudly, instead of either
--     aborting the apply or passing in silence — and the behavioural burden for that case is carried
--     in CI by DZCOMBAT_PASS_ONEPOWER in scripts/danger-combat-proof.sql, which builds its own five
--     hulls and asserts the rule end to end. On production, where the ships exist, this runs.
do $c$
declare
  s record; v_stats jsonb; v_n int := 0; v_bad text := '';
  v_expect numeric;
begin
  select count(*) into v_n from public.main_ship_instances where hp > 0;
  if v_n < 1 then
    raise notice '0317: this database holds no living main ship, so the executed fold-vs-catalog comparison had nothing to run against (expected on a freshly-applied chain; on production it would mean the fleet table is empty). The property is proven behaviourally by DZCOMBAT_PASS_ONEPOWER.';
    return;
  end if;
  for s in select msi.main_ship_id, msi.player_id, msi.hull_type_id from public.main_ship_instances msi where msi.hp > 0 loop
    v_stats := public.calculate_expedition_stats(s.player_id, s.main_ship_id, '[]'::jsonb, 'pirate_hunt');
    -- the expected combat_power, assembled from the catalog independently of the function: the hull,
    -- every rolled trait, every buff on an ACTIVE command ship of the same fleet, every fitted
    -- module, every assigned captain (level/affinity multipliers included).
    select coalesce((h.base_stats_json->>'attack')::numeric, 0)
      into v_expect from public.main_ship_hull_types h where h.hull_type_id = s.hull_type_id;
    v_expect := v_expect
      + coalesce((select sum(coalesce((y.stats_json->>'attack')::numeric, 0))
                    from public.main_ship_traits mt join public.ship_trait_types y on y.trait_type_id = mt.trait_type_id
                   where mt.main_ship_id = s.main_ship_id and public.cfg_bool('ship_traits_enabled')), 0)
      + coalesce((select sum(coalesce((cbt.stats_json->>'attack')::numeric, 0))
                    from public.main_ship_instances cs
                    join public.command_buff_types cbt on cbt.buff_id = cs.command_buff_id
                   where public.cfg_bool('command_buffs_enabled')
                     and cs.group_id = (select group_id from public.main_ship_instances where main_ship_id = s.main_ship_id)
                     and cs.group_id is not null and cs.player_id = s.player_id and cs.is_command_ship), 0)
      + coalesce((select sum(coalesce((t.stats_json->>'attack')::numeric, 0))
                    from public.ship_module_fittings f
                    join public.module_instances i on i.id = f.module_instance_id
                    join public.module_types t on t.id = i.module_type_id
                   where f.main_ship_id = s.main_ship_id), 0)
      + coalesce((select sum(coalesce((ct.stats_json->>'attack')::numeric, 0)
                             * (case when public.cfg_bool('captain_growth_enabled')
                                     then 1 + (ci.level - 1) * greatest(0, coalesce(public.cfg_num('captain_level_bonus_per_level'), 0)::numeric)
                                     else 1 end)
                             * (case when st.affinity_specialization = ct.specialization
                                     then 1 + greatest(0, coalesce(public.cfg_num('station_affinity_bonus'), 0)::numeric)
                                     else 1 end))
                    from public.ship_captain_assignments a
                    join public.captain_instances ci on ci.id = a.captain_instance_id
                    join public.captain_types ct on ct.id = ci.captain_type_id
                    left join public.ship_stations st on st.station_id = a.station
                   where a.main_ship_id = s.main_ship_id), 0);
    if (v_stats->>'combat_power')::numeric is distinct from greatest(0, round(v_expect, 2)) then
      v_bad := v_bad || s.main_ship_id::text || ' (fold ' || (v_stats->>'combat_power') || ' vs catalog ' || greatest(0, round(v_expect, 2))::text || ') ';
    end if;
    if v_stats ? 'warnings' or v_stats ? 'support_capacity_used' or v_stats ? 'support_capacity_limit' then
      raise exception '0317 ASSERT (c) FAIL: the fold still emits a retired field for ship %', s.main_ship_id;
    end if;
  end loop;
  if v_bad <> '' then
    raise exception '0317 ASSERT (c) FAIL: the fold disagrees with the catalog for: % — the rewrite changed a number it must not have', v_bad;
  end if;
  raise notice '0317: the fold returns the identical combat_power for all % living ships (hull vocabulary + pirate_attention additions are byte-inert against the deployed catalog)', v_n;
end $c$;

-- (d) THE LOADOUT PARAMETER IS FAIL-CLOSED, PROVEN BY CALL. A non-empty loadout must raise; the
--     empty one must still work. Run against a real ship, so a body that quietly ignored the
--     argument would pass (b)'s text probe and fail here. Same empty-world rule as (c): no ships
--     means the probe says so rather than aborting the apply or passing in silence.
do $d$
declare s_id uuid; s_pl uuid; v_ok boolean := false;
begin
  select main_ship_id, player_id into s_id, s_pl from public.main_ship_instances where hp > 0 order by main_ship_id limit 1;
  if s_id is null then
    raise notice '0317: no living ship to call the fold on, so the fail-closed p_loadout probe did not run (expected on a freshly-applied chain). scripts/verify-phase8.mjs and verify-mainship-preview.mjs assert the same refusal against a real database.';
    return;
  end if;
  perform public.calculate_expedition_stats(s_pl, s_id, '[]'::jsonb, 'pirate_hunt');
  begin
    perform public.calculate_expedition_stats(s_pl, s_id, '[{"support_craft_type_id":"scout_escort","quantity":1}]'::jsonb, 'pirate_hunt');
  exception when others then
    v_ok := true;
  end;
  if not v_ok then
    raise exception '0317 ASSERT (d) FAIL: a non-empty p_loadout was ACCEPTED — the retired parameter is being silently ignored rather than refused';
  end if;
end $d$;

-- (e) NOTHING ELSE MOVED. Every module_types attribute, every hull base_stats_json, the surviving
--     fallback knobs and both functions' metadata (owner / security / volatility / search_path /
--     signature / result / ACL) are compared against the pre-write capture. ABSENCE IS FAILURE on
--     both sides: the counts are pinned first so an emptied table cannot make the join vacuous.
do $e$
declare v_bad text; v_n int; v_cur int;
begin
  select count(*) into v_n from _0317_before where k like 'mod\\_%' escape '\\';
  select count(*) * 5 into v_cur from public.module_types;
  if v_n < 5 or v_n <> v_cur then
    raise exception '0317 ASSERT (e) FAIL: the module_types capture holds % attribute rows against % expected — a catalog row appeared or vanished under this migration', v_n, v_cur;
  end if;
  select string_agg(b.k || ': ' || b.v || ' -> ' || cur.v, '; ') into v_bad
    from _0317_before b
    join (select 'mod_' || id || '_' || key as k, value as v from (
            select id, 'power' as key, coalesce(power::text, '<null>') as value from public.module_types
            union all select id, 'range', coalesce(range::text, '<null>') from public.module_types
            union all select id, 'cooldown_seconds', coalesce(cooldown_seconds::text, '<null>') from public.module_types
            union all select id, 'slot_type', slot_type from public.module_types
            union all select id, 'stats_json', stats_json::text from public.module_types
          ) q) cur on cur.k = b.k
   where cur.v is distinct from b.v;
  if v_bad is not null then
    raise exception '0317 ASSERT (e) FAIL: a module_types attribute changed (%) — this migration redefines what power MEANS, it must not move a single value', v_bad;
  end if;

  select count(*) into v_n from _0317_before where k like 'hull\\_%' escape '\\';
  if v_n < 1 then
    raise exception '0317 ASSERT (e) FAIL: the hull capture is empty — the byte-inertness pin below would prove nothing';
  end if;
  select string_agg(b.k || ': ' || b.v || ' -> ' || coalesce(h.base_stats_json::text, '<gone>'), '; ') into v_bad
    from _0317_before b
    left join public.main_ship_hull_types h on 'hull_' || h.hull_type_id = b.k
   where b.k like 'hull\\_%' escape '\\'
     and coalesce(h.base_stats_json::text, '<gone>') is distinct from b.v;
  if v_bad is not null then
    raise exception '0317 ASSERT (e) FAIL: a hull base_stats_json changed under this migration (%)', v_bad;
  end if;

  select string_agg(b.k || ': ' || b.v || ' -> ' || coalesce(g.value::text, '<gone>'), '; ') into v_bad
    from _0317_before b
    left join public.game_config g on 'cfg_' || g.key = b.k
   where b.k like 'cfg\\_%' escape '\\'
     and coalesce(g.value::text, '<gone>') is distinct from b.v;
  if v_bad is not null then
    raise exception '0317 ASSERT (e) FAIL: a knob this migration must not touch changed (%) — the enemy and the fallback profile are a separate balance decision', v_bad;
  end if;

  select count(*) into v_n from _0317_before where k like 'fn\\_%' escape '\\';
  if v_n <> 2 then
    raise exception '0317 ASSERT (e) FAIL: the function-metadata capture holds % row(s) (want 2)', v_n;
  end if;
  select string_agg(b.k || ': ' || b.v || ' -> ' || cur.v, '; ') into v_bad
    from _0317_before b
    join (select 'fn_' || p.proname as k,
                 pg_get_userbyid(p.proowner) || '|' || p.prosecdef::text || '|' || p.provolatile::text
                 || '|' || coalesce(array_to_string(p.proconfig, ','), '') || '|' || pg_get_function_identity_arguments(p.oid)
                 || '|' || pg_get_function_result(p.oid) || '|' || coalesce(p.proacl::text, '') as v
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('calculate_expedition_stats', 'combat_create_group_encounter')) cur
      on cur.k = b.k
   where cur.v is distinct from b.v;
  if v_bad is not null then
    raise exception '0317 ASSERT (e) FAIL: a re-created function changed more than its body (%) — a CREATE OR REPLACE that alters owner/security/volatility/search_path/signature/ACL is a different function wearing the same name', v_bad;
  end if;
end $e$;

-- (f) THE GEOMETRY OF THE RULE, EXECUTED OVER THE LIVE CATALOG rather than asserted:
--       f1 every firing weapon carries a POSITIVE share weight (a zero-weight gun would take no
--          share, and a whole catalog of them would leave a ship unable to deliver its own power);
--       f2 the weights normalise: for every fittable combination the shares sum to exactly 1, which
--          is the formal statement of "the card is the volley";
--       f3 fitting a STRICTLY stronger weapon can never reduce a ship's volley — the property the
--          owner's design turns on. Checked as the catalog fact it rests on: for every pair of
--          firing weapons, the one with the greater stats_json.attack raises combat_power more, and
--          the volley IS combat_power, so the ordering cannot invert;
--       f4 the no-weapon fallback and the fitted path are the SAME rule — the synthesized entry's
--          weight is 1 and the normalisation is the only power writer, so a single-entry array
--          always resolves to combat_power exactly.
do $f$
declare v_n int; v_bad text; v_src text;
begin
  select count(*) into v_n from public.module_types t where public.module_is_firing_weapon(t);
  if v_n < 1 then
    raise exception '0317 ASSERT (f) FAIL: the catalog contains no firing weapon at all — every property below would be vacuous';
  end if;
  select string_agg(t.id || ' weight ' || coalesce(t.power::text, '<null>'), '; ') into v_bad
    from public.module_types t
   where public.module_is_firing_weapon(t) and coalesce(t.power, 0) <= 0;
  if v_bad is not null then
    raise exception '0317 ASSERT (f1) FAIL: a firing weapon carries a non-positive share weight (%) — it would take no share of its ship''s volley', v_bad;
  end if;
  -- f2/f4: the builder's normalisation divides by the sum of the weights over the SHIP's entries,
  -- so the shares sum to 1 for any non-empty set with a positive total. f1 has just established
  -- every weight is positive, which is exactly the precondition that makes that total positive for
  -- every fittable combination and for the single-entry fallback array alike.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('/ v_weight_total' in v_src) = 0 then
    raise exception '0317 ASSERT (f2) FAIL: the builder does not divide by the weight total — the shares would not sum to the card';
  end if;
  if position('''power'',            1,' in v_src) = 0 then
    raise exception '0317 ASSERT (f4) FAIL: the synthesized fallback weapon does not carry a weight of 1 — the fitted and unfitted paths are not the same rule';
  end if;
  -- f3: the ordering fact the property rests on. Both live guns satisfy it (battery attack 10 <
  -- mk2 attack 18); a future weapon that raised power without raising attack would fail here rather
  -- than silently make a better gun a downgrade.
  select string_agg(a.id || ' (attack ' || coalesce((a.stats_json->>'attack'), '<none>') || ', weight ' || a.power::text || ')'
                    || ' vs ' || b2.id || ' (attack ' || coalesce((b2.stats_json->>'attack'), '<none>') || ', weight ' || b2.power::text || ')', '; ')
    into v_bad
    from public.module_types a, public.module_types b2
   where public.module_is_firing_weapon(a) and public.module_is_firing_weapon(b2)
     and a.power < b2.power
     and coalesce((a.stats_json->>'attack')::numeric, 0) >= coalesce((b2.stats_json->>'attack')::numeric, 0);
  if v_bad is not null then
    raise exception '0317 ASSERT (f3) FAIL: a weapon with a LARGER share weight contributes no more attack than a smaller one (%) — fitting the bigger gun would not raise the ship''s volley, and the owner''s "a better module is simply a bigger number" would stop holding', v_bad;
  end if;
end $f$;

-- (g) THE INTEGRITY BAR. The builder seeds hp_max from capacity and current from live hp, and the
--     encounter's two integrity columns are two different sums. Read off the deployed text — there
--     is no open encounter to observe in a migration, and the behavioural half is proven by the
--     DZCOMBAT_PASS_ONEPOWER block in scripts/danger-combat-proof.sql.
do $g$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('v_hp_max := m.max_hp;' in v_src) = 0 then
    raise exception '0317 ASSERT (g) FAIL: the builder does not seed hp_max from the ship''s capacity';
  end if;
  if position('(e->>''hp_max'')::double precision, (e->>''hp'')::double precision,' in v_src) = 0 then
    raise exception '0317 ASSERT (g) FAIL: the combat_units INSERT still writes current hp into hp_max — the bar would still open full on a damaged fleet';
  end if;
  if position('player_integrity_current = v_hull_cur' in v_src) = 0 then
    raise exception '0317 ASSERT (g) FAIL: player_integrity_current is still the same sum as player_integrity_max';
  end if;
  if position('coalesce(sum(hp_current), 0)' in v_src) = 0 then
    raise exception '0317 ASSERT (g) FAIL: current integrity is not summed from hp_current';
  end if;
  -- and the denominator 0310 divides by must be the same quantity, from the same column.
  if position('sum(msi.max_hp)' in (select pg_get_functiondef(p.oid)
                                      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                     where n.nspname = 'public' and p.proname = 'process_combat_ticks')) = 0 then
    raise exception '0317 ASSERT (g) FAIL: the tick no longer divides by sum(main_ship_instances.max_hp) — the definition this migration just aligned the bar to has moved, and the two numbers would disagree again';
  end if;
end $g$;

commit;
`;

if (sql.includes('\r')) throw new Error('emitted SQL contains a CR — the migration must be LF-only');

if (process.argv.includes('--check')) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8').replace(/\r\n/g, '\n');
  } catch {
    console.error(`gen-0317: ${OUT} is MISSING — run the generator without --check to emit it.`);
    process.exit(1);
  }
  if (onDisk !== sql) {
    console.error('gen-0317: the migration on disk does NOT match what this generator emits.');
    console.error('  Either the file was hand-edited (regenerate it), or one of the source migrations');
    console.error('  it slices (0205 / 0301 / 0315) moved under it (read the diff before regenerating).');
    process.exit(1);
  }
  console.log('gen-0317: migration matches the slices it takes (17 hunks over 2 functions).');
  process.exit(0);
}

writeFileSync(OUT, sql);
console.log(`gen-0317: wrote ${OUT} (${sql.length} bytes, 17 hunks over 2 functions).`);
