#!/usr/bin/env node
// gen-0341-fights-you-can-keep-up-with.mjs — emit (or --check) migration 0341.
//
// WHY A GENERATOR: 0341 rewrites two hunks inside process_combat_ticks, which no migration file
// holds whole (73k chars live, surgery-assembled since 0299). Every `old_t` below is SLICED
// VERBATIM out of the migration that owns the DEPLOYED text of its region; every `new_t` is
// DERIVED from that slice by concatenation. Nothing is retyped (the 0303 lesson).
//
//   process_combat_ticks — TEXTUAL head 0299; replace-surgery since by 0310, 0314, 0317, 0332,
//                          0336, 0337, 0338, 0339.
//     * the DECLARE block's formation working set is 0339's own h5n output — slice source 0339.
//     * the synthetic wave's SIZING lines (v_enemy_hp / v_enemy_attack / v_enemy_count) have never
//       been re-emitted by any surgeon: 0336 h9 and 0339 h4 both start BELOW them, at the spawn
//       loop. So the deployed text of that region is still 0299's — slice source 0299.
//
//   node scripts/gen-0341-fights-you-can-keep-up-with.mjs          # write the migration
//   node scripts/gen-0341-fights-you-can-keep-up-with.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000341_fights_you_can_keep_up_with.sql');
const SELF = '20260618000341';

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR. A `\r` baked into a
// sliced hunk can NEVER match the deployed body and the production deploy fails at apply time.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECKS: establish that the files sliced below really own the deployed text. ─────────────
// Same two detectors as gen-0336/0337/0339: a later TEXTUAL re-create makes the slice source stale
// outright; a later HUNK ROW — the house `(idx, 'fname',` shape — means somebody surgically edited
// the body and a new slice must not be cut without reading that migration. Later rewriters are
// exempted BY NAME, never by widening the version window, so the gate stays live for 0342+.
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
  // Every later surgeon of the tick is named. 0339 is not merely exempted — it is the slice SOURCE
  // for the DECLARE hunk, and drift in it fails at the slice fence below rather than here.
  // 0310/0314/0317/0332/0336/0337/0338 own regions this file never reads.
  guard('process_combat_ticks', '20260618000299',
    new Set(['20260618000310', '20260618000314', '20260618000317', '20260618000332', '20260618000336',
             '20260618000337', '20260618000338', '20260618000339']));
}

const F299 = load('20260618000299_combat_card_reports_true_power.sql');
const F339 = load('20260618000339_a_fight_you_can_move_in.sql');

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
 *  rather than silently returning text with a `$h5n$` still glued to it. */
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

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// THE SLICES
// ═══════════════════════════════════════════════════════════════════════════════════════════════

// ── process_combat_ticks DECLARE: the formation working set, as 0339 left it ─────────────────────
const DECL_OLD = hunkBody(F339, '0339', 925, 926, 'h5n',
  'v_ring_radius            double precision;', 'v_spawn_slot             integer;');

// ── process_combat_ticks: the SYNTHETIC wave's sizing — the three lines that decide how big a wave
// ── is and how many bodies carry it. Still 0299's bytes: no surgeon has re-emitted them.
const SIZE_OLD = slice(F299, '0299', 746, 750,
  "v_enemy_hp     := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)",
  "v_enemy_count  := least(coalesce(cfg_num('enemy_synthetic_max_units'),6)::integer, greatest(1, v_danger));");

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// THE REPLACEMENTS
// ═══════════════════════════════════════════════════════════════════════════════════════════════

const DECL_NEW = `${DECL_OLD}
  -- ██ 0341 THE BAND, AND THE DANGER ONE PIRATE CARRIES ██
  -- v_band is how many danger steps a wave holds before it gains a body ("round 1~5 should be only
  -- 1, then round 5~10 should be 2" — the owner). v_pirate_danger is the share of the wave's danger
  -- that ONE of its bodies carries: danger / (band * bodies). It is what the two danger-scale knobs
  -- are now applied to, so a pirate stays a pirate and danger buys BODIES instead of fat.
  v_band                   double precision;
  v_pirate_danger          double precision;`;

const SIZE_NEW = `          -- ██ 0341 THE OWNER: "round 1~5 should be only 1, then round 5~10 should be 2" ██
          -- THE RAMP. The head added a body per danger step (danger 3 = 3 pirates). It now adds one
          -- per BAND of five, still under the same enemy_synthetic_max_units ceiling:
          --   danger 1-5 -> 1 body   6-10 -> 2   11-15 -> 3   16-20 -> 4   21-25 -> 5   26+ -> 6 (cap)
          -- The band is a knob because "how many rounds before another pirate turns up" is a number
          -- to tune; the BANDED SHAPE is structure and lives here, in the body, not in config.
          --
          -- ██ AND THE SPLIT IS RE-DERIVED, BECAUSE FEWER BODIES ALONE WOULD HAVE MADE IT HARDER ██
          -- The head sized the WAVE from danger and then divided that total by the body count
          -- (v_enemy_hp / v_enemy_count, two lines below — deliberately UNCHANGED). Under that rule
          -- cutting the count changes nothing about the wave's mass or its damage: it concentrates
          -- them. At Snare, danger 5 would have gone from five 112-hp pirates to ONE 560-hp pirate —
          -- same total, but with sequential focus fire the incoming damage never falls until that
          -- one hull dies, so damage taken per wave rises by (N_old+1)/2N_old : (N_new+1)/2N_new,
          -- i.e. 0.6 -> 1.0, a 1.67x NERF dressed up as a calmer screen. And the fire-rate halving
          -- shipped alongside cannot pay for it: halving both sides doubles the wall clock and
          -- leaves damage-per-wave exactly invariant. Provably, not approximately.
          -- SO THE PIRATE BECOMES THE PRIMITIVE. The two danger scales are applied to
          -- v_pirate_danger — the danger ONE body carries — and the wave total is bodies x pirate.
          -- A wave-3 fight is now one wave-3-sized pirate, not a wave-3-sized sponge. Both knobs
          -- keep their meaning and their names: past the cap, when no more bodies can arrive,
          -- v_pirate_danger climbs past 1 and danger resumes making pirates tougher — which is
          -- exactly what the head's ceiling always did, only now it is the ONLY place fat appears.
          v_band          := greatest(1, coalesce(cfg_num('enemy_synthetic_units_per_danger_band'), 5));
          v_enemy_count   := least(coalesce(cfg_num('enemy_synthetic_max_units'),6)::integer,
                                   greatest(1, ceil(v_danger::double precision / v_band)::integer));
          v_pirate_danger := v_danger::double precision / (v_band * v_enemy_count);
          v_enemy_hp     := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                            * (1 + v_pirate_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance
                            * v_enemy_count;
          v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                            * (1 + v_pirate_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25))
                            * v_enemy_count;`;

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// THE MIGRATION
// ═══════════════════════════════════════════════════════════════════════════════════════════════

const SQL = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0341 — FIGHTS YOU CAN KEEP UP WITH
--        one more pirate every five rounds instead of every round, a pirate that stays a pirate,
--        and every gun on both sides firing half as often
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- GENERATED BY scripts/gen-0341-fights-you-can-keep-up-with.mjs — DO NOT HAND-EDIT.
-- Regenerate with \`node scripts/gen-0341-fights-you-can-keep-up-with.mjs\`; the parity gate in
-- scripts/danger-combat-proof.sh runs \`--check\` and fails if this file drifted from the generator.
--
-- ── THE REPORT, VERBATIM ─────────────────────────────────────────────────────────────────────────
--   "right each round? new fleets are made and fight is made +1, meaning 1 ship, 2 ships, 3 ships
--    and so on. Reduce this. round 1~5 should be only 1, then round 5~10 should be 2. and make fire
--    rate also slower, 2 times slower"
--
-- ── (1) THE RAMP ─────────────────────────────────────────────────────────────────────────────────
-- The head: v_enemy_count := least(cap, greatest(1, v_danger)) — a body per danger step, and danger
-- is 1 + waves_cleared + minutes-in-zone/3, so round N of a fresh fight is danger N. Now banded:
--   danger 1-5 -> 1 body   6-10 -> 2   11-15 -> 3   16-20 -> 4   21-25 -> 5   26+ -> 6 (the cap,
--   enemy_synthetic_max_units, unchanged at 6)
-- The owner's "5~10" overlaps at 5; read as five-wave bands, and implemented as the general rule
-- rather than two hard-coded ranges. The band width is a NEW KNOB
-- (enemy_synthetic_units_per_danger_band, 5) because "how many rounds before another pirate turns
-- up" is a number. The banded SHAPE is structure and stays in the body — a structural rule smuggled
-- into config is not a tunable.
-- SCOPE: the SYNTHETIC wave only. The resolver arm takes its counts from an AUTHORED plan
-- (0299:699) and is not touched — authored content decides its own size, and always has.
--
-- ── (2) THE TRAP: FEWER BODIES, ON ITS OWN, IS A NERF ────────────────────────────────────────────
-- 0299:762-763 divides the WAVE total by the body count. The total is a function of danger ALONE, so
-- changing the count moves no mass and no damage — it concentrates them. At Snare (base_difficulty
-- 10) danger 5 would have gone from five 112-hp pirates to ONE 560-hp pirate. Same 560 hp, same 22.5
-- attack. But the player focuses fire sequentially, so incoming damage only steps down when a hull
-- DIES: damage taken over a wave is P x (H/dps) x (N+1)/(2N), and (N+1)/(2N) goes 0.6 -> 1.0 from
-- five bodies to one. A 1.67x NERF, on a screen that looks calmer. The audit called it "marginally
-- harder"; at the owner's own danger band it is 67% harder.
-- AND THE FIRE-RATE HALVING CANNOT PAY FOR IT. Halve both sides: P halves, dps halves, so H/dps
-- doubles and the product is unchanged. Symmetric slowdown is EXACTLY damage-neutral per wave — it
-- buys reaction time and nothing else. That is arithmetic, not a judgement.
-- SO THE SPLIT IS RE-DERIVED. The pirate becomes the primitive: the two danger scales apply to
-- v_pirate_danger = danger / (band x bodies) — the danger ONE body carries — and the wave total is
-- bodies x pirate. The two \`/ v_enemy_count\` division lines are left BYTE-UNCHANGED: they are still
-- the one authority for "a wave's mass, spread over its bodies". Only what is fed into them moves.
-- Past the cap v_pirate_danger climbs above 1 and danger resumes fattening pirates — the head's own
-- behaviour at its ceiling, now the only place fat appears.
--
-- ── (3) THE FIRE RATE, ON BOTH SIDES ─────────────────────────────────────────────────────────────
-- COOLDOWN IS CURRENTLY INERT. 0314 armed each weapon with its own cooldown_seconds, but
-- combat_tick_seconds is 3 and every live cooldown is 2 or 2.5, so the readiness gate reopens every
-- tick and every gun fires every tick. Doubling past 3 makes cooldown load-bearing FOR THE FIRST
-- TIME: 4 and 5 both mean "ready on the tick after next", so every gun fires every 2 ticks = every
-- 6s instead of 3s. Exactly 2x slower, exactly as asked, on both sides:
--   module_types.autocannon_battery      2   -> 4      (player, fitted)
--   module_types.autocannon_battery_mk2  2.5 -> 5      (player, fitted)
--   combat_player_fallback_weapon_cooldown_seconds  2 -> 4   (player, unfitted)
--   enemy_synthetic_cooldown_seconds                2 -> 4   (pirate)
-- WHY SYMMETRIC, STATED SO IT CAN BE OVERRULED CHEAPLY: the owner has separately asked to stay in
-- fights longer and to manoeuvre inside them; a symmetric slowdown buys reaction time without
-- swinging power. ENEMY-ONLY would instead have HALVED incoming damage per wave outright (a ~2x
-- power swing to the player) while leaving the player's own cadence — the thing that is hard to
-- keep up with — untouched. If that is what was wanted, it is one knob:
-- \`node scripts/set-knob.mjs enemy_synthetic_cooldown_seconds 8\` and revert the two module rows.
-- NOTE 4 and 5 both land on 2 ticks, so mk2's slower cadence is still invisible; separating them
-- needs a cooldown above 6 and is a balance question, not this slice.
--
-- ── (4) BEFORE / AFTER, AT LIVE NUMBERS ──────────────────────────────────────────────────────────
-- Snare, difficulty 10: hp_base 14, hp_danger_scale 0.6, attack_base 1.0, attack_danger_scale 0.25,
-- variance ~1. Player starter: 15 power, so 5.0 dps before (1 shot / 3s tick), 2.5 dps after
-- (1 shot / 2 ticks). "dmg/wave" = damage the player takes clearing one wave, P x (H/dps) x (N+1)/2N.
--
--   danger | bodies    | pirate hp     | wave hp      | clear time     | dmg/wave
--        1 | 1  ->  1  | 224 -> 157    | 224 -> 157   |  45s ->  63s   |  187 ->  110  (0.59x)
--        3 | 3  ->  1  | 131 -> 190    | 392 -> 190   |  78s ->  76s   |  305 ->  146  (0.48x)
--        5 | 5  ->  1  | 112 -> 224    | 560 -> 224   | 112s ->  90s   |  504 ->  187  (0.37x)
--        6 | 6  ->  2  | 107 -> 190    | 644 -> 381   | 129s -> 152s   |  626 ->  438  (0.70x)
--       10 | 6  ->  2  | 163 -> 224    | 980 -> 448   | 196s -> 179s   | 1333 ->  560  (0.42x)
--       15 | 6  ->  3  | 233 -> 224    |1400 -> 672   | 280s -> 269s   | 2586 -> 1120  (0.43x)
--       26 | 6  ->  6  | 387 -> 213    |2324 ->1277   | 465s -> 511s   | 6778 -> 3625  (0.53x)
--
-- Gentler at every danger (0.37x-0.70x damage per wave) and NEVER harsher — the concentration nerf
-- is paid for, not shipped. Wave clear time moves only -20%/+40% despite guns firing half as often,
-- because a wave now carries the mass its bodies justify.
-- INTERACTION WITH 0310's 30% AUTO-EXIT — which is what actually ends these fights: the damage that
-- ends a sortie is fixed (70% of fleet hull), so at ~0.45x damage per wave the player clears roughly
-- TWICE as many waves before being pulled out, and since per-wave clear time is roughly flat, a
-- sortie lasts about twice as long in real time. That is the ask: a longer fight you can follow.
-- ONE HONEST REGRESSION, NAMED: wave 1 is ~30% lighter than today (157 hp vs 224), because a lone
-- pirate now carries a fifth of a band of danger rather than a whole wave's worth. If the owner
-- wants wave 1 to be exactly today's pirate again that is one knob:
-- \`node scripts/set-knob.mjs enemy_hp_base 20\` (and attack_base 1.4).
--
-- ── (5) SPAGHETTI FOUND, AND WHY IT IS NOT FOLDED HERE ───────────────────────────────────────────
-- The danger formula is written TWICE in this function — 0299:647 (spatial arm) and 0299:1035
-- (aggregate arm), identical bar whitespace. That is a duplicate, but it is not two LIVE copies:
-- the aggregate arm is the "0228 HEAD, VERBATIM (the dark / no-positions byte-parity arm)" and is
-- reachable only by an encounter created while spatial_combat_enabled was dark and kept non-spatial
-- by 0242's stickiness. No such encounter can be created today. Folding a dead legacy arm into a new
-- shared leaf would add a function and two more hunks to a live 30-player game for no live benefit,
-- and the arm exists precisely to be byte-identical to 0228. NAMED, NOT SILENTLY TOLERATED: when the
-- aggregate arm is retired, the duplicate goes with it. This slice touches ONLY the spatial arm.
--
-- ── (6) BLAST RADIUS AND ROLLBACK ────────────────────────────────────────────────────────────────
-- BLAST RADIUS: total, immediate, no opt-in. process_combat_ticks is re-read by the 3-second cron,
-- so the NEXT tick of every running fight for every player runs the new body. Cooldowns are read out
-- of module_types and game_config per spawn/creation, so every fight created after this migration
-- fires at the new cadence; fights already running keep the weapons_json they were seeded with until
-- their next wave (enemy) or their next encounter (player) — a bounded, self-healing transition,
-- never a mixed rule inside one volley.
-- WHAT IS NOT TOUCHED: the resolver arm's authored counts; the aggregate arm; rewards and the reward
-- formulas; the ambush fail-open; cargo; the stat foundation and 0340 (still dark); port authorities;
-- retreat and 0310's auto-exit; target capacity / per-ship targeting; movement speed.
-- ROLLBACK:
--   fire rate — two knobs, live on the next fight:
--     node scripts/set-knob.mjs combat_player_fallback_weapon_cooldown_seconds 2
--     node scripts/set-knob.mjs enemy_synthetic_cooldown_seconds 2
--     update public.module_types set cooldown_seconds = 2   where id = 'autocannon_battery';
--     update public.module_types set cooldown_seconds = 2.5 where id = 'autocannon_battery_mk2';
--   ramp width — one knob, live on the next wave:
--     node scripts/set-knob.mjs enemy_synthetic_units_per_danger_band 1   (a body per danger step)
--   the SPLIT is a body change and is NOT knob-revertible: restoring 0299's sizing needs a follow-up
--   migration that re-applies the sliced text. Stated plainly rather than implied.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;

-- ── 1. PRECONDITIONS — refuse to build on a base this migration was not generated against ────────
-- Every hunk is located by exact deployed text further down and the rewrite loop demands exactly one
-- occurrence, but a failure there is a confusing "hunk text occurs 0 times". These raise first, and
-- name what actually drifted. Nothing has been written at this point.
do $pre$
declare
  v_src text;
  v_n   integer;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_src is null then
    raise exception '0341 PRECONDITION FAIL: public.process_combat_ticks does not exist';
  end if;

  -- (a) the sizing region is still 0299's bytes — no surgeon has re-emitted it
  if position($p1$          v_enemy_count  := least(coalesce(cfg_num('enemy_synthetic_max_units'),6)::integer, greatest(1, v_danger));$p1$ in v_src) = 0 then
    raise exception '0341 PRECONDITION FAIL: the synthetic wave sizing is not 0299''s deployed text — read the migration that changed it before regenerating';
  end if;

  -- (b) the division this slice deliberately does NOT touch is present, exactly twice (one per arm)
  v_n := (length(v_src) - length(replace(v_src, 'v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;', '')))
         / length('v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;');
  if v_n <> 2 then
    raise exception '0341 PRECONDITION FAIL: the wave split is written % time(s), expected 2 (resolved arm + synthetic arm)', v_n;
  end if;

  -- (c) the DECLARE working set is as 0339 left it
  if position($p2$  v_ring_radius            double precision;
  v_spawn_slot             integer;$p2$ in v_src) = 0 then
    raise exception '0341 PRECONDITION FAIL: the DECLARE working set is not 0339''s deployed text';
  end if;

  -- (d) the band knob must not already exist with a different meaning
  if exists (select 1 from public.game_config where key = 'enemy_synthetic_units_per_danger_band') then
    raise exception '0341 PRECONDITION FAIL: enemy_synthetic_units_per_danger_band already exists — this migration mints it';
  end if;

  -- (e) the four cooldowns are at the values this migration doubles. Fail CLOSED on drift (the 0254
  -- lesson): a guarded UPDATE that matches nothing would otherwise no-op silently.
  if (select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_cooldown_seconds') is distinct from '2' then
    raise exception '0341 PRECONDITION FAIL: combat_player_fallback_weapon_cooldown_seconds is not 2';
  end if;
  if (select value #>> '{}' from public.game_config where key = 'enemy_synthetic_cooldown_seconds') is distinct from '2' then
    raise exception '0341 PRECONDITION FAIL: enemy_synthetic_cooldown_seconds is not 2';
  end if;
  if (select cooldown_seconds from public.module_types where id = 'autocannon_battery') is distinct from 2 then
    raise exception '0341 PRECONDITION FAIL: autocannon_battery cooldown_seconds is not 2';
  end if;
  if (select cooldown_seconds from public.module_types where id = 'autocannon_battery_mk2') is distinct from 2.5 then
    raise exception '0341 PRECONDITION FAIL: autocannon_battery_mk2 cooldown_seconds is not 2.5';
  end if;
end $pre$;

-- ── 2. THE BAND KNOB — the only game_config row this migration mints ─────────────────────────────
insert into public.game_config (key, value, description) values
  ('enemy_synthetic_units_per_danger_band', '5',
   'how many danger steps a SYNTHETIC pirate wave holds before it gains another body (0341): '
   'v_enemy_count = least(enemy_synthetic_max_units, ceil(danger / this)). The owner: "round 1~5 '
   'should be only 1, then round 5~10 should be 2". 1 restores the pre-0341 body-per-danger-step '
   'ramp. It also sets the danger ONE body carries (danger / (this * bodies)), which is what the '
   'two danger-scale knobs are applied to, so widening the band makes waves grow more slowly in '
   'bodies AND in mass together rather than trading one for the other.')
on conflict (key) do nothing;

-- ── 3. THE FIRE RATE — 2x slower, both sides, guarded on the exact value being doubled ───────────
update public.game_config
   set value = '4'::jsonb,
       description = 'COMBAT-FALLBACK (0262, doubled 0341): seconds between shots for the synthesized '
                     'basic player weapon. Above combat_tick_seconds (3) ON PURPOSE — that is what '
                     'makes the readiness gate bite: one shot every two ticks, not every tick.',
       updated_at = now()
 where key = 'combat_player_fallback_weapon_cooldown_seconds' and value = '2'::jsonb;

update public.game_config
   set value = '4'::jsonb,
       description = 'COMBAT-S3 (0234, doubled 0341): synthetic pirate weapon cooldown between shots. '
                     'Above combat_tick_seconds (3) ON PURPOSE: one shot every two ticks.',
       updated_at = now()
 where key = 'enemy_synthetic_cooldown_seconds' and value = '2'::jsonb;

update public.module_types set cooldown_seconds = 4   where id = 'autocannon_battery'     and cooldown_seconds = 2;
update public.module_types set cooldown_seconds = 5   where id = 'autocannon_battery_mk2' and cooldown_seconds = 2.5;

-- ── 4. CAPTURE METADATA BEFORE THE REWRITE (for parity check (e)) ────────────────────────────────
create temp table _0341_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0341_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('process_combat_ticks');

-- ── 5. REWRITE THE HUNKS (located by exact deployed text, never retyped) ─────────────────────────
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
    (1, 'process_combat_ticks',
     $h1o$${DECL_OLD}$h1o$,
     $h1n$${DECL_NEW}$h1n$),
    (2, 'process_combat_ticks',
     $h2o$${SIZE_OLD}$h2o$,
     $h2n$${SIZE_NEW}$h2n$)
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0341 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0341 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0341 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0341 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 2 then
    raise exception '0341 REWRITE FAIL: rewrote % site(s), expected 2', v_done;
  end if;
end $rewrite$;

-- ── 6. SELF-ASSERTS — every one of them EXECUTES against the applied database ────────────────────
-- None of these reads this file's own text. (a)-(c) read pg_proc / game_config / module_types after
-- the writes above; (d) RUNS the ramp arithmetic; (e) is the metadata parity ledger. A vacuous
-- assert is worse than none (the 0300/0331/0333 lesson), so every check below fails on an
-- unmodified chain — verified by running the whole file against the pre-change body.

-- (a) the deployed tick carries the banded ramp and has LOST the head's per-danger-step ramp
do $a$
declare
  v_code text;
  v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';

  if position('greatest(1, v_danger))' in v_code) > 0 then
    raise exception '0341 ASSERT (a) FAIL: the head''s per-danger-step ramp is still in the tick';
  end if;
  if position($aq$greatest(1, ceil(v_danger::double precision / v_band)::integer)$aq$ in v_code) = 0 then
    raise exception '0341 ASSERT (a) FAIL: the banded ramp is not in the tick';
  end if;
  if position($aq$v_pirate_danger := v_danger::double precision / (v_band * v_enemy_count);$aq$ in v_code) = 0 then
    raise exception '0341 ASSERT (a) FAIL: the per-pirate danger is not derived in the tick';
  end if;

  -- the cap still binds, and it is still the same knob
  v_n := (length(v_code) - length(replace(v_code, $aq$least(coalesce(cfg_num('enemy_synthetic_max_units'),6)::integer,$aq$, '')))
         / length($aq$least(coalesce(cfg_num('enemy_synthetic_max_units'),6)::integer,$aq$);
  if v_n <> 1 then
    raise exception '0341 ASSERT (a) FAIL: the unit cap is read % time(s), expected 1', v_n;
  end if;

  -- the split is UNTOUCHED — still twice, one per arm. This slice changed what feeds it, not it.
  v_n := (length(v_code) - length(replace(v_code, 'v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;', '')))
         / length('v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;');
  if v_n <> 2 then
    raise exception '0341 ASSERT (a) FAIL: the wave split is written % time(s), expected 2 — this slice must not have moved it', v_n;
  end if;

  -- the RESOLVER arm still takes its count from the authored plan, untouched
  if position($aq$v_enemy_count := (v_weapon->>'count')::integer;$aq$ in v_code) = 0 then
    raise exception '0341 ASSERT (a) FAIL: the resolver arm no longer takes its count from the plan';
  end if;

  -- the AGGREGATE arm's sizing is untouched (this slice is spatial-arm only)
  if position($aq$v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;$aq$ in v_code) = 0 then
    raise exception '0341 ASSERT (a) FAIL: the aggregate arm lost a pinned head guarantee';
  end if;
end $a$;

-- (b) the four cooldowns landed, and every one of them now EXCEEDS the tick — which is the whole
-- behavioural claim: a gun that could fire every tick can no longer fire on consecutive ticks.
do $b$
declare
  v_tick double precision;
  v_fb   double precision;
  v_en   double precision;
  v_bat  numeric;
  v_mk2  numeric;
begin
  v_tick := coalesce(public.cfg_num('combat_tick_seconds'), 3);
  v_fb   := public.cfg_num('combat_player_fallback_weapon_cooldown_seconds');
  v_en   := public.cfg_num('enemy_synthetic_cooldown_seconds');
  select cooldown_seconds into v_bat from public.module_types where id = 'autocannon_battery';
  select cooldown_seconds into v_mk2 from public.module_types where id = 'autocannon_battery_mk2';

  if v_fb  is distinct from 4   then raise exception '0341 ASSERT (b) FAIL: fallback cooldown is %, want 4', v_fb;  end if;
  if v_en  is distinct from 4   then raise exception '0341 ASSERT (b) FAIL: enemy cooldown is %, want 4', v_en;    end if;
  if v_bat is distinct from 4   then raise exception '0341 ASSERT (b) FAIL: autocannon_battery cooldown is %, want 4', v_bat; end if;
  if v_mk2 is distinct from 5   then raise exception '0341 ASSERT (b) FAIL: autocannon_battery_mk2 cooldown is %, want 5', v_mk2; end if;

  -- THE POINT OF THE DOUBLING, asserted rather than assumed. 0314 arms next_ready_at with
  -- now() + cooldown and the gate is now() >= next_ready_at, so a cooldown at or under the tick
  -- reopens every tick. Every one of the four is now strictly above it.
  if v_fb <= v_tick or v_en <= v_tick or v_bat::double precision <= v_tick or v_mk2::double precision <= v_tick then
    raise exception '0341 ASSERT (b) FAIL: a cooldown (% / % / % / %) is not above the combat tick (%) — the readiness gate would still reopen every tick and nothing got slower',
      v_fb, v_en, v_bat, v_mk2, v_tick;
  end if;
  -- and not so far above that a gun skips more than the one tick the owner asked for
  if v_fb > 2 * v_tick or v_en > 2 * v_tick or v_bat::double precision > 2 * v_tick or v_mk2::double precision > 2 * v_tick then
    raise exception '0341 ASSERT (b) FAIL: a cooldown exceeds two ticks — that is slower than the 2x asked for';
  end if;
end $b$;

-- (c) the band knob exists, is the value the ramp was designed around, and no client role can see
-- game_config any differently than it did before (this migration adds no grant)
do $c$
declare v_band double precision;
begin
  v_band := public.cfg_num('enemy_synthetic_units_per_danger_band');
  if v_band is distinct from 5 then
    raise exception '0341 ASSERT (c) FAIL: enemy_synthetic_units_per_danger_band is %, want 5', v_band;
  end if;
end $c$;

-- (d) THE RAMP, RUN. Not a text match: the exact expression the tick now evaluates is executed here
-- against the SAME knobs the tick reads, for every danger from 1 to 30, and its answers are checked
-- against the owner's sentence. This fails on an unmodified chain because the band knob does not
-- exist there and the ceil() form is not what the head computes.
do $d$
declare
  d        integer;
  v_band   double precision := greatest(1, coalesce(public.cfg_num('enemy_synthetic_units_per_danger_band'), 5));
  v_cap    integer := coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::integer;
  v_count  integer;
  v_pd     double precision;
  v_prev   integer := 0;
begin
  for d in 1 .. 30 loop
    v_count := least(v_cap, greatest(1, ceil(d::double precision / v_band)::integer));
    v_pd    := d::double precision / (v_band * v_count);

    -- the owner's sentence, literally
    if d between 1 and 5   and v_count <> 1 then raise exception '0341 ASSERT (d) FAIL: danger % spawns %, want 1', d, v_count; end if;
    if d between 6 and 10  and v_count <> 2 then raise exception '0341 ASSERT (d) FAIL: danger % spawns %, want 2', d, v_count; end if;
    if d between 11 and 15 and v_count <> 3 then raise exception '0341 ASSERT (d) FAIL: danger % spawns %, want 3', d, v_count; end if;
    -- the cap still binds
    if v_count > v_cap then raise exception '0341 ASSERT (d) FAIL: danger % spawns %, above the cap %', d, v_count, v_cap; end if;
    -- monotone: a later round never brings FEWER bodies
    if v_count < v_prev then raise exception '0341 ASSERT (d) FAIL: danger % spawns % after %', d, v_count, v_prev; end if;
    v_prev := v_count;
    -- a pirate stays a pirate: while bodies can still arrive, one body never carries more than a
    -- full band's worth of danger. Past the cap it may, and that is the design.
    if v_count < v_cap and v_pd > 1.0000001 then
      raise exception '0341 ASSERT (d) FAIL: at danger % one body carries % bands of danger below the cap', d, v_pd;
    end if;
  end loop;
  if v_prev <> 6 then
    raise exception '0341 ASSERT (d) FAIL: danger 30 spawns %, want the cap 6', v_prev;
  end if;
end $d$;

-- (e) metadata parity: the rewritten function changed body and NOTHING else
do $e$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0341_before loop
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
      raise exception '0341 ASSERT (e) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0341 ASSERT (e) FAIL: public.% body is byte-identical — its hunks did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0341 ASSERT (e) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0341 SELF-ASSERT PASS: a synthetic wave gains one body per five danger steps under the same cap; the danger scales are applied to the danger ONE body carries so fewer pirates is a lighter wave and not a tankier one; the wave split is untouched; the resolver and aggregate arms are untouched; and every gun on both sides now carries a cooldown above the combat tick, so nothing fires on two consecutive ticks';
end $e$;

commit;
`;

const onDisk = () => readFileSync(OUT, 'utf8').replace(/\r\n/g, '\n');

if (process.argv.includes('--check')) {
  let cur;
  try {
    cur = onDisk();
  } catch {
    console.error(`gen-0341 --check FAIL: ${OUT} does not exist — run the generator.`);
    process.exit(1);
  }
  if (cur !== SQL) {
    console.error('gen-0341 --check FAIL: the migration on disk differs from what this generator emits.');
    process.exit(1);
  }
  console.log('gen-0341 --check ok');
} else {
  if (SQL.includes('\r')) throw new Error('gen-0341: refusing to emit a CR — slice sources were not normalised');
  writeFileSync(OUT, SQL, 'utf8');
  console.log(`wrote ${OUT} (${SQL.length} chars)`);
}
