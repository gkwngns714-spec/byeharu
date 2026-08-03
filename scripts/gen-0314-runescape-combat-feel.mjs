#!/usr/bin/env node
// gen-0314-runescape-combat-feel.mjs — emit (or --check) migration 0314.
//
// WHY A GENERATOR: 0314 rewrites FIVE hunks inside the live process_combat_ticks body. The true
// textual head of the tick is 0299:308 (verified: 0301's only mention is a comment; 0302/0305/
// 0306/0307/0308 rewrite OTHER functions or only probe this one; 0310 rewrites the tick by
// replace() over pg_get_functiondef with ONE hunk sliced from 0299:1026-1030 — statically DISJOINT
// from every hunk below, so 0299's text is still the slice source for all five). The 0303 lesson —
// "never retype a live function body" — holds: every `old_t` below is SLICED verbatim out of 0299,
// and every `new_t` is CONSTRUCTED from that slice by exactly-once string edits, so even the
// unchanged lines inside a replaced hunk are byte-copies, never retyped. The migration then proves
// each slice is still what is deployed (occurs EXACTLY once in pg_get_functiondef), replaces it,
// and proves the length moved by exactly the hunk delta.
//
//   node scripts/gen-0314-runescape-combat-feel.mjs          # write the migration
//   node scripts/gen-0314-runescape-combat-feel.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000314_runescape_combat_feel.sql');

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECK: 0299 must still be the newest TEXTUAL re-create of process_combat_ticks. ─────────
// Replace-rewriters (0310's shape, and this migration's own) do not move the textual head, but any
// later `create or replace function public.process_combat_ticks` means the slice source is stale.
{
  const reCreate = /create\s+or\s+replace\s+function\s+(?:public\.)?process_combat_ticks\s*\(/i;
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const newerHeads = readdirSync(MIGDIR)
    .filter((f) => f.endsWith('.sql') && version(f) > '20260618000299' && version(f) !== '20260618000314')
    .filter((f) => {
      // strip `--` line comments first: 0301 names the create in a comment, deliberately.
      const src = readFileSync(MIG(f), 'utf8').replace(/--[^\n]*/g, '');
      return reCreate.test(src);
    });
  if (newerHeads.length > 0) {
    throw new Error(
      `process_combat_ticks was textually re-created AFTER 0299 by: ${newerHeads.join(', ')} — ` +
      're-point the slices at the new head before generating.');
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

/** Replace `from` with `to` in `base`, demanding `from` occurs EXACTLY once — the parity guard
 *  that lets new_t be CONSTRUCTED from the slice instead of retyped. */
function edit(base, from, to) {
  const n = base.split(from).length - 1;
  if (n !== 1) throw new Error(`edit(): needle occurs ${n} time(s), want exactly 1: ${JSON.stringify(from)}`);
  return base.replace(from, to);
}

// ── THE FIVE HUNKS ────────────────────────────────────────────────────────────────────────────────
// All sliced from 0299; all pairwise disjoint; all disjoint from 0310's replace-site (0299:1026-1030,
// fenced there by 'perform report_create(e.id);' .. 'end if; -- not v_wave_paused').

// [H1] one new declaration, appended after the variance-percent local (0299:323).
const H1_OLD = slice(F299, '0299', 323, 323, 'v_var_pct       double precision;', 'v_var_pct       double precision;');
const H1_NEW = H1_OLD + '\n' +
`  v_hit_var_pct   double precision;   -- 0314: the PER-HIT damage roll's spread (read once below)`;

// [H2] the per-hit variance knob, read the existing way, appended after the tick-shared one (0299:431).
const H2_OLD = slice(F299, '0299', 431, 431, "coalesce(cfg_num('combat_damage_variance_pct'), 0.10);", "coalesce(cfg_num('combat_damage_variance_pct'), 0.10);");
const H2_NEW = H2_OLD + '\n' +
`  -- 0314 PER-HIT VARIANCE: every SHOT rolls its own damage in the fire loop below, while v_var_pct
  -- keeps seeding wave HP exactly as before — two concerns, two knobs. combat_hit_variance_pct
  -- INHERITS combat_damage_variance_pct when the key is absent, so any world that pinned the old
  -- knob (every determinism harness pins it 0) gets byte-identical numbers, and production starts
  -- at today's spread simply re-rolled per hit. Widening the feel (OSRS rolls 0..max, i.e. 1.0
  -- here) is ONE config write to the new key and never touches wave seeding.
  v_hit_var_pct   := coalesce(cfg_num('combat_hit_variance_pct'), v_var_pct);`;

// [H3] the damage roll moves INSIDE the shot (0299:897-901) — this is "everytime it deals differently".
const H3_OLD = slice(F299, '0299', 897, 901, "if v_t_side = 'enemy' then", 'end if;');
const H3_NEW = edit(
  edit(
    edit(
      `                -- 0314 THE PER-HIT ROLL: one roll PER SHOT, never the tick-shared v_variance
                -- (that roll still seeds wave HP above — a different concern, deliberately left
                -- alone). greatest(0, ...) keeps the multiplier total for ANY knob value: a spread
                -- above 1.0 could otherwise roll negative damage, which would HEAL the target
                -- through the hp subtraction below.
                declare
                  v_hit_roll double precision := greatest(0, (1 - v_hit_var_pct) + random() * (2 * v_hit_var_pct));
                begin
` + H3_OLD.replace(/^ {16}/gm, '                  ') + '\n' +
`                end;`,
      'v_dmg := v_w_power * v_variance;',
      'v_dmg := v_w_power * v_hit_roll;'),
    'v_dmg := v_w_power * v_def_base / (v_def_base + coalesce(v_t_defense,0)) * v_variance;',
    'v_dmg := v_w_power * v_def_base / (v_def_base + coalesce(v_t_defense,0)) * v_hit_roll;'),
  // self-check that the indent shift really nested the old block two spaces deeper:
  "                  if v_t_side = 'enemy' then",
  "                  if v_t_side = 'enemy' then");

// [H4] the hitsplat event rides EVENT logging (lit in production), not DEBUG (0299:921-928), and
//      carries the exact per-hit damage (display rounds; the payload states the fact).
const H4_OLD = slice(F299, '0299', 921, 928, 'if v_log_debug then', 'end if;');
const H4_NEW =
`                -- 0314 THE HITSPLAT EVENT: each landed hit emits its own hull_damage — the number,
                -- on the target, per hit — under combat_event_logging (lit in production) instead
                -- of combat_debug_logging (dark everywhere), which is why per-hit damage was never
                -- visible. The map splat layer and the battle feed already render exactly this
                -- payload. The damage is the UNROUNDED fact; every renderer rounds for display.
                -- (The aggregate arm's group-keyed twin stays debug-gated: byte-parity legacy path.)
` + edit(
      edit(H4_OLD, 'if v_log_debug then', 'if v_log_events then'),
      "jsonb_build_object('unit_id', v_target_id, 'damage', round(v_dmg)));",
      "jsonb_build_object('unit_id', v_target_id, 'damage', v_dmg));");

// [H5] the attack interval becomes real: arm the weapon with ITS OWN cooldown (0299:946-947).
const H5_OLD = slice(F299, '0299', 946, 947, 'v_weapons_out := jsonb_set(v_weapons_out, array[v_widx::text],', "jsonb_build_object('next_ready_at', now(), 'ammo_remaining', v_new_ammo));");
const H5_NEW =
`              -- 0314 THE ATTACK INTERVAL: arm the weapon with ITS OWN cooldown_seconds. The head
              -- armed with bare now(), so the readiness gate above (now() >= next_ready_at, which
              -- this migration does NOT touch) reopened every tick and module_types.cooldown_seconds
              -- never did anything. A missing/zero cooldown arms now()+0 — ready again next tick,
              -- exactly the head's behaviour: fail open to today. The tick cadence stays the FLOOR:
              -- a cooldown at or under combat_tick_seconds still fires every tick, never sub-tick.
` + edit(H5_OLD,
      "'next_ready_at', now(),",
      `'next_ready_at',
                                    now() + make_interval(secs => coalesce((v_weapon->>'cooldown_seconds')::double precision, 0)),`);

const HUNKS = [
  [1, 'process_combat_ticks', H1_OLD, H1_NEW],
  [2, 'process_combat_ticks', H2_OLD, H2_NEW],
  [3, 'process_combat_ticks', H3_OLD, H3_NEW],
  [4, 'process_combat_ticks', H4_OLD, H4_NEW],
  [5, 'process_combat_ticks', H5_OLD, H5_NEW],
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
    if (!body.trim()) throw new Error(`hunk ${idx} sliced empty — a line range is wrong`);
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

// the hunks must be PAIRWISE DISJOINT as text (a later replace must never hit an earlier result).
for (let i = 0; i < HUNKS.length; i++) {
  for (let j = 0; j < HUNKS.length; j++) {
    if (i !== j && (HUNKS[j][3].includes(HUNKS[i][2]) || HUNKS[j][2].includes(HUNKS[i][2]))) {
      throw new Error(`hunk ${HUNKS[i][0]}'s old text occurs inside hunk ${HUNKS[j][0]} — the sequential rewrite would double-apply`);
    }
  }
}

// Comment-stripping idiom proven by 0305/0306/0308/0310 against this database's settings.
const STRIP = `regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')`;

const sql = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0314 — THE RUNESCAPE COMBAT FEEL: REAL ATTACK INTERVALS, A FRESH DAMAGE ROLL PER HIT,
--        AND EVERY HIT VISIBLE AS IT LANDS
--        (the owner's ask, verbatim: "i once told you that with what we have now, i want a
--         runescape-like battle experience. Where you attack with interval, showing hp, and
--         everytime it deals differently. Implement it, work in a loop, no spaghetti")
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- "WITH WHAT WE HAVE NOW" — this is a REPAIR of three existing pieces, not a new system. No new
-- event channel, no new timing mechanism, no second damage formula, no schema change.
--
--   1. THE ATTACK INTERVAL EXISTS AND WAS DEAD. The fire gate (0299:872-873) already reads
--      next_ready_at — but every shot re-armed it with BARE now() (0299:947), so every weapon was
--      ready every tick and module_types.cooldown_seconds (autocannon 2.5s, fallback knob 2s,
--      enemy synthetic knob 2s) never did anything. The fix arms the weapon with ITS OWN
--      cooldown_seconds, already carried by every weapons_json entry (0262/0299/0301 all seed it).
--      THE TICK IS THE FLOOR, STATED PLAINLY: the engine runs every combat_tick_seconds (live 3s),
--      so a cooldown at or under 3s fires exactly once per tick — a 2s or 2.5s weapon's cadence is
--      unchanged by this migration. Only a cooldown ABOVE the tick period changes behaviour: a 5s
--      weapon now fires every 2nd tick, a 9s weapon every 3rd. There is NO sub-tick fire and this
--      migration adds none — attack speed is real from here on, resolved at tick granularity.
--   2. DAMAGE WAS ROLLED ONCE PER TICK, NOT PER HIT. v_variance (0299:648) is rolled once in the
--      wave/danger section and was reused for enemy wave HP seeding (0299:702/:747) AND for every
--      weapon's damage (0299:898-900) — so every shot in a tick dealt the same number, which is
--      exactly why "everytime it deals differently" failed. The fix rolls INSIDE the shot:
--      v_hit_roll, one roll per hit. The wave-HP-seeding use of v_variance is DELIBERATELY
--      untouched — seeding spread and hit spread are different concerns, and conflating them is
--      how this became one variable in the first place.
--      THE KNOB: combat_hit_variance_pct, read the existing cfg_num way, INHERITING
--      combat_damage_variance_pct (live 0.10) when absent. So production ships with today's ±10%
--      spread re-rolled per hit, and every determinism harness that pins the old knob to 0 keeps
--      byte-exact numbers. THE PROPOSAL, WHICH IS THE OWNER'S CALL AND IS NOT SEEDED HERE:
--      set combat_hit_variance_pct to 0.5 (hits roll 50%..150% of weapon power, mean unchanged)
--      for a visible RuneScape spread; 1.0 is the full OSRS 0..2x feel. One config write, no
--      deploy, reversible. This migration writes NO game_config row.
--   3. THE HITSPLAT WAS EMITTED ONLY IN A DARK DEBUG CHANNEL. The spatial arm already built the
--      exact per-hit event — hull_damage {unit_id, damage} (0299:921-928) — but gated it on
--      combat_debug_logging (dark everywhere) instead of combat_event_logging (lit in production).
--      The client has been ready for it all along: the map's splat layer
--      (src/features/map/spatialCombatLayer.ts resolveHitSplats) floats exactly this payload over
--      the unit that took the hit, and the battle feed renders it too. The fix moves the emission
--      under v_log_events and ships the payload's damage UNROUNDED (it is a fact, not a display;
--      every renderer rounds). No new event_type: 'hull_damage' has been in combat_events' CHECK
--      since 20260616000014:71, so no constraint is widened and no client default-arm can leak.
--
-- ── WHAT A PLAYER SEES, HIT BY HIT ───────────────────────────────────────────────────────────────
-- Each poll (~1.5s against a 3s tick): every shot that landed draws its own damage number on the
-- battle map over the ship that took it (red on your own hull), and a feed line with the same
-- number; numbers now differ shot to shot; a slow weapon's silence between volleys is real. HP was
-- already live and per-unit — combat_encounters.player_integrity_current every tick and each
-- unit's hp_current/hp_max bar — and is untouched here.
--
-- ── EVERY CONSUMER CHECKED (the never-ship-half-a-slice ledger) ──────────────────────────────────
--   the fire gate 0299:872-873      — UNTOUCHED; it always honoured next_ready_at.
--   weapons_json shape              — no key added/removed; only next_ready_at's VALUE changes
--                                     after a shot. Writers (0262/0301 builders, enemy spawns) and
--                                     the one reader (the gate) unchanged. The client reads only
--                                     'range' from weapons_json (unitWeaponRange).
--   combat_events consumers         — CombatEventLayer (feed copy made side-aware in this same
--                                     slice: the old copy assumed pirate-sourced group-keyed
--                                     payloads) and spatialCombatLayer (renders unchanged; it
--                                     already rounds). Volume: +1 row per LANDED hit per tick,
--                                     same order as the existing per-shot missile_salvo.
--   the aggregate arm               — byte-identical: shared-roll damage, debug-gated group splat.
--                                     It is the position-less legacy parity path (0310's posture);
--                                     no live fight reaches it (spatial mode is sticky per data).
--   proofs that drive multi-tick fire in ONE txn — now() is txn-frozen there, so a real cooldown
--                                     means fire-once-per-proof. Each affected harness now OWNS its
--                                     precondition (zeroed cooldown knobs/catalog in-txn), and the
--                                     cooldown property itself is proven where it is owned:
--                                     danger-combat-proof's RSFEEL block (3600s cooldown, tick 2
--                                     silent). elite-stat-wiring's random( count repoints 2 -> 3
--                                     (the per-hit roll is a THIRD known RNG site).
--
-- ── BLAST RADIUS ON LIVE PLAYERS ─────────────────────────────────────────────────────────────────
--   - CREATE OR REPLACE of the tick only: atomic swap, no table lock, no row written at deploy.
--   - In-flight fights: weapons whose next_ready_at is already stamped bare-now() stay ready and
--     simply pick up real cooldowns from their next shot. No backfill.
--   - Balance: mean damage per hit is unchanged; CADENCE changes only for weapons with cooldown
--     above 3s (none of the live seeded weapons: 2.5s / 2s / 2s — so live DPS is unchanged until
--     the owner tunes a slower, harder-hitting weapon, which this makes possible).
--   - Event volume: hull_damage rows now land under the lit event flag — bounded by shots per
--     tick, same class as missile_salvo, same owner-scoped RLS, cascade-deleted with the fight.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed tick with the five hunks reverted (0299's text at :323/:431/:897-901/
-- :921-928/:946-947). No state to unwind: this migration writes no rows, no schema, no grants.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
-- WHAT THESE PROVE, HONESTLY: that the emitted TEXT is what this migration intended — never that
-- it EXECUTES (plpgsql resolves nothing until first execution). Behaviour is proven by exactly one
-- layer: the disposable apply-proof driving the REAL tick (danger-combat-proof's RSFEEL block).
--   (a) the per-hit knob is read once, the existing way, inheriting the old knob when absent
--   (b) the roll is per hit: v_hit_roll rolled inside the shot, used by BOTH damage formulas; the
--       tick-shared roll is GONE from the fire loop but every wave-seeding use survives
--   (c) the hitsplat rides EVENT logging with the unrounded amount; the aggregate arm's debug twin
--       is the only debug gate left
--   (d) the arming carries the weapon's own cooldown; the bare-now() arming is gone; the readiness
--       gate itself is untouched
--   (e) every carried-through 0299/0310 invariant survives the re-emission (incl. the auto-exit
--       arm and its confinement handler)
--   (f) metadata parity: the tick changed body and NOTHING else
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
    raise exception '0314 PRECONDITION FAIL: process_combat_ticks is absent';
  end if;
  select prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  -- the base must be the post-0310 body (0314 numbers after 0310 and its hunks assume that chain):
  if position('presence_request_leave(e.presence_id)' in v_tick) = 0 then
    raise exception '0314 PRECONDITION FAIL: the deployed tick lacks the 0310 auto-exit arm — this is not the chain 0314 was generated against';
  end if;
  if position('combat_hit_variance_pct' in v_tick) > 0 or position('v_hit_roll' in v_tick) > 0 then
    raise exception '0314 PRECONDITION FAIL: the deployed tick already carries the per-hit roll — refusing to re-emit over an unknown edit';
  end if;
  if position('public.combat_encounter_side_power(e.id, ''player'')' in v_tick) = 0 then
    raise exception '0314 PRECONDITION FAIL: the deployed tick is not the 0299 lineage (the snapshot-power authority is absent)';
  end if;
end $pre$;

-- ── 1. CAPTURE METADATA BEFORE THE REWRITE (for parity check f) ──────────────────────────────────
create temp table _0314_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0314_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'process_combat_ticks';

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
      raise exception '0314 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0314 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0314 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0314 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 5 then
    raise exception '0314 REWRITE FAIL: rewrote % site(s), expected 5', v_done;
  end if;
  raise notice '0314: real attack intervals, a fresh roll per hit, and a visible hitsplat per landed shot';
end $rewrite$;

-- ── 3. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) the per-hit knob is read once, the existing way, inheriting the old knob when absent
do $a$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'coalesce(cfg_num(''combat_hit_variance_pct''), v_var_pct)', '')))
         / length('coalesce(cfg_num(''combat_hit_variance_pct''), v_var_pct)');
  if v_n <> 1 then
    raise exception '0314 ASSERT (a) FAIL: % per-hit-knob reads (want exactly 1, inheriting combat_damage_variance_pct when absent)', v_n;
  end if;
end $a$;

-- (b) the roll is PER HIT and the wave-seeding roll survives untouched
do $b$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('v_hit_roll double precision := greatest(0, (1 - v_hit_var_pct) + random() * (2 * v_hit_var_pct));' in v_code) = 0 then
    raise exception '0314 ASSERT (b) FAIL: the clamped per-hit roll is gone (greatest(0,...) is what keeps a wide knob from rolling healing)';
  end if;
  if position('v_dmg := v_w_power * v_hit_roll;' in v_code) = 0
     or position('v_dmg := v_w_power * v_def_base / (v_def_base + coalesce(v_t_defense,0)) * v_hit_roll;' in v_code) = 0 then
    raise exception '0314 ASSERT (b) FAIL: a damage formula does not use the per-hit roll';
  end if;
  if position('v_dmg := v_w_power * v_variance;' in v_code) > 0
     or position('coalesce(v_t_defense,0)) * v_variance;' in v_code) > 0 then
    raise exception '0314 ASSERT (b) FAIL: the tick-shared roll is back in the fire loop — every shot in a tick would deal the same number again';
  end if;
  -- the wave-HP-seeding uses of v_variance are a DIFFERENT concern and must survive verbatim:
  -- the two spatial wave seeds + the aggregate arm's seed all end with this exact text.
  v_n := (length(v_code) - length(replace(v_code, '),0.6)) * v_variance;', ''))) / length('),0.6)) * v_variance;');
  if v_n <> 3 then
    raise exception '0314 ASSERT (b) FAIL: % wave-HP seeds read v_variance (want the head''s 3 — this slice must not touch seeding)', v_n;
  end if;
  if position('v_player_damage := v_attack * v_variance;' in v_code) = 0
     or position('v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;' in v_code) = 0 then
    raise exception '0314 ASSERT (b) FAIL: the aggregate arm''s shared-roll damage drifted — that arm is the byte-parity legacy path and must not change';
  end if;
end $b$;

-- (c) the hitsplat rides EVENT logging with the unrounded amount
do $c$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('jsonb_build_object(''unit_id'', v_target_id, ''damage'', v_dmg));' in v_code) = 0 then
    raise exception '0314 ASSERT (c) FAIL: the spatial per-hit hull_damage payload is gone or re-rounded';
  end if;
  if position('round(v_dmg)' in v_code) > 0 then
    raise exception '0314 ASSERT (c) FAIL: a rounded per-hit damage survives — the payload states the fact, renderers round';
  end if;
  -- exactly ONE debug gate left: the aggregate arm's group-keyed twin (the legacy parity path).
  v_n := (length(v_code) - length(replace(v_code, 'if v_log_debug then', ''))) / length('if v_log_debug then');
  if v_n <> 1 then
    raise exception '0314 ASSERT (c) FAIL: % debug-gated event blocks (want exactly 1 — the aggregate arm''s; the spatial hitsplat must ride v_log_events)', v_n;
  end if;
end $c$;

-- (d) the arming carries the weapon's own cooldown; the readiness gate is untouched
do $d$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'now() + make_interval(secs => coalesce((v_weapon->>''cooldown_seconds'')::double precision, 0))', '')))
         / length('now() + make_interval(secs => coalesce((v_weapon->>''cooldown_seconds'')::double precision, 0))');
  if v_n <> 1 then
    raise exception '0314 ASSERT (d) FAIL: % cooldown armings (want exactly 1)', v_n;
  end if;
  if position('''next_ready_at'', now(),' in v_code) > 0 then
    raise exception '0314 ASSERT (d) FAIL: the bare-now() arming is back — every weapon would be ready every tick again';
  end if;
  if position('and (v_w_next_ready is null or now() >= v_w_next_ready) then' in v_code) = 0 then
    raise exception '0314 ASSERT (d) FAIL: the readiness gate changed — this slice arms the clock, it never touches the gate';
  end if;
end $d$;

-- (e) every carried-through 0299/0310 invariant survives the re-emission
do $e$
declare v_code text; v_n integer; v_tok text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('fleet_get_power' in v_code) > 0 then
    raise exception '0314 ASSERT (e) FAIL: fleet_get_power is back in the tick (0299 reverted)';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_side_power(e.id, ''player'')', '')))
         / length('public.combat_encounter_side_power(e.id, ''player'')');
  if v_n <> 2 then
    raise exception '0314 ASSERT (e) FAIL: % of 2 power writes read the 0299 authority', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 8 then
    raise exception '0314 ASSERT (e) FAIL: the tick carries % cfg_bool call(s) (want the head''s 8 — this slice adds no gate)', v_n;
  end if;
  -- random( goes 2 -> 3: the two wave-seed rolls plus the ONE per-hit roll. Anything else is drift.
  v_n := (length(v_code) - length(replace(v_code, 'random(', ''))) / length('random(');
  if v_n <> 3 then
    raise exception '0314 ASSERT (e) FAIL: the tick carries % random( call(s) (want exactly 3: two wave seeds + the per-hit roll)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'movement_create(', ''))) / length('movement_create(');
  if v_n <> 2 then
    raise exception '0314 ASSERT (e) FAIL: the tick mints % movement leg(s) (want the head''s 2)', v_n;
  end if;
  -- the 0310 auto-exit arm, intact: composed once, confined, with both query_canceled re-raises.
  v_n := (length(v_code) - length(replace(v_code, 'presence_request_leave(e.presence_id)', '')))
         / length('presence_request_leave(e.presence_id)');
  if v_n <> 1 then
    raise exception '0314 ASSERT (e) FAIL: the 0310 auto-exit arm composes presence_request_leave % time(s) (want exactly 1)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'when query_canceled then raise;', '')))
         / length('when query_canceled then raise;');
  if v_n <> 2 then
    raise exception '0314 ASSERT (e) FAIL: % query_canceled re-raise line(s) (want exactly 2 — the 0206 guard''s and the 0310 arm''s)', v_n;
  end if;
  if position('select sum(msi.max_hp) into v_ae_cap' in v_code) = 0 then
    raise exception '0314 ASSERT (e) FAIL: the 0310 capacity denominator is gone — a stale-base re-emission';
  end if;
  foreach v_tok in array array[
      'select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y',
      'v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)',
      'v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null',
      'if e.next_wave_at is not null and now() < e.next_wave_at then',
      'if v_w_range is not null and v_target_dist <= v_w_range'
    ] loop
    if position(v_tok in v_code) = 0 then
      raise exception '0314 ASSERT (e) FAIL: the tick lost a pinned head guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
end $e$;

-- (f) metadata parity: the tick changed body and NOTHING else
do $f$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0314_before loop
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
      raise exception '0314 ASSERT (f) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0314 ASSERT (f) FAIL: public.% body is byte-identical — the hunks did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0314 ASSERT (f) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0314 SELF-ASSERT PASS: attack intervals are real (armed from each weapon''s own cooldown, tick-floored), every hit rolls its own damage (knob combat_hit_variance_pct, inheriting the live spread until the owner widens it), and every landed hit emits its visible hull_damage under the lit event flag';
end $f$;

commit;
`;

if (sql.includes('\r')) {
  throw new Error('generated 0314 carries a CR — the rewrite hunks would never match the deployed body');
}

const check = process.argv.includes('--check');
if (check) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8');
  } catch {
    console.error('0314 CHECK FAIL: migration file is missing — run the generator');
    process.exit(1);
  }
  if (onDisk.replace(/\r\n/g, '\n') !== sql) {
    console.error('0314 CHECK FAIL: the migration on disk is not what the slices generate.');
    console.error('Either the 0299 source drifted or the file was hand-edited. Re-run the generator.');
    process.exit(1);
  }
  console.log('0314 CHECK OK: migration matches the slices taken from 0299.');
} else {
  writeFileSync(OUT, sql);
  console.log(`0314 written: ${OUT}`);
  console.log(`  ${HUNKS.length} hunks sliced from 0299 (nothing retyped; new text constructed from the slices)`);
}
