#!/usr/bin/env node
// gen-0317-the-dead-do-not-shoot.mjs — emit (or --check) migration 0317.
//
// WHY A GENERATOR: 0317 rewrites ONE hunk inside the live process_combat_ticks body. The true
// TEXTUAL head of the tick is still 0299:308 — verified below, programmatically: no migration after
// 0299 carries a `create or replace function … process_combat_ticks`. Two later migrations DID edit
// the body, both by replace-surgery over pg_get_functiondef rather than by re-creating it:
//   0310 — ONE hunk sliced from 0299:1026-1030 (the auto-exit arm), and
//   0314 — FIVE hunks sliced from 0299:323 / :431 / :897-901 / :921-928 / :946-947.
// Every one of those sites is statically DISJOINT from the hunk below (0299:822-826, the top of the
// spatial per-unit loop body), so 0299's text is still the correct slice source for this migration.
// The 0303 lesson — "never retype a live function body" — holds: `old_t` is SLICED verbatim out of
// 0299 and `new_t` is that slice with new text PREPENDED, so every deployed line inside the replaced
// hunk is a byte-copy. The migration then proves the slice is still what is deployed (occurs EXACTLY
// once in pg_get_functiondef), replaces it, and proves the length moved by exactly the hunk delta.
//
//   node scripts/gen-0317-the-dead-do-not-shoot.mjs          # write the migration
//   node scripts/gen-0317-the-dead-do-not-shoot.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000317_the_dead_do_not_shoot.sql');

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECKS: establish that 0299 really is the deployed text this hunk is cut from. ──────────
// (1) No later TEXTUAL re-create. Any `create or replace function … process_combat_ticks` after
//     0299 would make the slice stale. 0301 names the create in a comment, deliberately, so `--`
//     line comments are stripped before the test (the 0314 idiom, same reason).
// (2) No UNKNOWN later REPLACE-REWRITER. A migration after 0299 that carries this function name in
//     a hunk row — the house `(idx, 'fname',` shape used by 0310 and 0314 — has surgically edited
//     the body, and a NEW slice must not be cut without reading it. 0310 and 0314 are exempt BY
//     NAME rather than by widening the window (the gen-0315 idiom): their sites are disjoint from
//     this one, checked by hand at the line numbers listed in the header above, and naming them
//     keeps the gate live for 0318 and everything after it. A migration that merely NAMES the
//     function in a read-only probe or a comment is not drift and must not fail this gate.
{
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const files = readdirSync(MIGDIR)
    .filter((f) => f.endsWith('.sql') && version(f) !== '20260618000317');
  const stripped = new Map(
    files.map((f) => [f, readFileSync(MIG(f), 'utf8').replace(/--[^\n]*/g, '')]));

  const reCreate = /create\s+or\s+replace\s+function\s+(?:public\.)?process_combat_ticks\s*\(/i;
  const newerHeads = files.filter((f) => version(f) > '20260618000299' && reCreate.test(stripped.get(f)));
  if (newerHeads.length > 0) {
    throw new Error(
      `process_combat_ticks was textually re-created AFTER 0299 by: ${newerHeads.join(', ')} — ` +
      're-point the slice at the new head before generating.');
  }

  // 0332 JOINS THE EXEMPTION — by name, never by widening the window. It rewrites the settle arm's
  // member-repatriation loop, sliced from 0299:622-624, so a dead member of a fight the fleet
  // SURVIVED finally gets the terminal write the defeat arm always gave it. That site is statically
  // DISJOINT from this migration's (0299:822-826, the top of the spatial per-unit loop): different
  // branch of the tick, ~200 lines apart, and 0332 neither reads nor writes the actor-liveness guard
  // — it only turns a `for … and alive_count > 0 loop` into a `for … loop` with an if/else inside,
  // which is why this file's own slice and every assert count in it are unaffected (0332 keeps the
  // alive_count > 0 site count at the 7 assert (d) pins, by MOVING one site rather than adding one).
  // Naming it here keeps this gate live for 0333 and everything after it.
  //
  // 0337 JOINS, by name. It makes a reposition a MOVE instead of a teleport, and its four tick hunks
  // are the declare block, the v_is_spatial line, the per-unit POSITION write and the foot of the
  // spatial arm. This file's slice is the actor-liveness guard at the TOP of the per-unit loop;
  // 0337's nearest site is the position write ~35 lines below it, inside the same loop but after
  // the targeting block, and 0337 neither reads nor writes the liveness guard. It also adds no
  // `alive_count > 0` site to the loop (its own use is inside combat_fleet_move_speed, a separate
  // function), so assert (d)'s site count here is unaffected.
  const KNOWN_LATER_REWRITERS = new Set(['20260618000310', '20260618000314', '20260618000332', '20260618000336',
                                         '20260618000337']);
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

// ── THE ONE HUNK ─────────────────────────────────────────────────────────────────────────────────
// The top of the spatial per-unit loop body: 0299's own retreat/offense gate, with its two comment
// lines, sliced whole so the comment stays attached to the gate it explains. The new guard is
// PREPENDED, which is why the slice is byte-identical inside the replacement.
const H1_OLD = slice(F299, '0299', 822, 826,
  '-- Retreating player ships hold position and cease fire',
  'end if;');

const H1_NEW =
`          -- 0317 THE DEAD DO NOT ACT. v_units is frozen ABOVE, before any movement, deliberately:
          -- it is what makes every unit on both sides resolve its target and its close/kite decision
          -- from ONE pre-move world. That freeze is NOT touched here. What it must never mean is
          -- that a unit destroyed EARLIER IN THIS SAME TICK still gets a turn — until this guard it
          -- kept its snapshot row and so it still MOVED (the position write below) and still FIRED.
          -- ONE AUTHORITY, ASKED TWICE: "alive right now" is combat_units.alive_count > 0, read from
          -- the LIVE table. The damage step below already asks exactly that of the TARGET, in the
          -- same found-idiom; this asks it of the ACTOR. Same table, same column, same comparison —
          -- one question, two roles, and no second notion of death is introduced.
          -- SYMMETRIC BY CONSTRUCTION: this guard names no side, so a destroyed pirate stops firing
          -- on exactly the terms a destroyed player hull does. Anything else would be a balance
          -- change wearing a bug fix.
          -- ONE GUARD, NOT TWO: skipping the whole iteration stops the corpse MOVING as well as
          -- shooting. A dead hull sliding across the arena is the same defect in other clothes, and
          -- a second guard for it would be a second authority for the same question.
          -- NOT re-read: the snapshot. Only the actor's own liveness. Targeting still resolves from
          -- the frozen population, which is why a surviving unit still fires at a hull that died
          -- earlier in the tick (its shot simply lands on a corpse and deals nothing, exactly as
          -- before) rather than silently re-acquiring — simultaneity is preserved.
          perform 1 from combat_units where id = v_ur.id and alive_count > 0;
          if not found then
            continue;
          end if;
` + H1_OLD;

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

// Comment-stripping idiom proven by 0305/0306/0308/0310/0314 against this database's settings.
const STRIP = `regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')`;

const sql = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0317 — THE DEAD DO NOT SHOOT (and the dead do not move)
--        a unit destroyed earlier in a tick takes no turn for the rest of that tick
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE DEFECT, READ OFF THE DEPLOYED BODY ───────────────────────────────────────────────────────
-- The spatial arm of process_combat_ticks freezes this tick's population into v_units BEFORE any
-- movement (0299:805-813) and then iterates that snapshot (0299:817-821). Inside the loop:
--   * the TARGET's liveness IS re-read from the live table before damage is applied
--     (0299:890-893: "from combat_units where id = v_target_id and alive_count > 0" + "if found"),
--     so a target that died to an earlier shot this tick simply takes no further damage; but
--   * the ACTOR's liveness is NEVER re-read. The loop variable came from the frozen snapshot, so a
--     unit destroyed earlier in the SAME tick still reached its own iteration, still had its
--     position written (0299:857) and still fired every weapon in range (0299:863-949).
-- A ship destroyed on tick N therefore got a posthumous shot AND a posthumous move. That is true on
-- both sides: the loop is one loop over both, and nothing in it is side-conditioned except the
-- retreat gate.
--
-- ── WHAT THIS MIGRATION DOES, AND THE SEMANTICS IT PINS ──────────────────────────────────────────
-- ONE guard, at the top of the per-unit loop body, before anything else in it: re-read the ACTOR's
-- liveness from the live table and skip the whole iteration when it is gone.
--   * BOTH SIDES, SYMMETRICALLY. The guard names no side. A dead pirate stops firing on exactly the
--     terms a dead player hull does.
--   * IT STOPS THE MOVE TOO. The position write is inside the same iteration, so skipping the
--     iteration ends the corpse's slide across the arena as well as its fire. One guard, not two:
--     "does this unit still exist" is one question and it gets one answer.
--   * THE FREEZE IS UNTOUCHED. This does NOT re-read the snapshot per unit. Targeting, the aggro
--     tier filter and combat_unit_decide_move all still resolve from the frozen pre-move
--     population, which is what makes the kite/close arms fair. The ONLY thing read from current
--     state is the actor's own liveness — exactly as the target's already was.
--   * A SHOT AT A CORPSE STILL HAPPENS, UNCHANGED. A living unit whose snapshot target died earlier
--     in the tick still emits its salvo and still deals nothing (the target re-read finds no row).
--     That is the head's behaviour and this slice deliberately does not change it: changing it
--     would mean re-targeting from live state, i.e. destroying the simultaneity above.
--
-- ── ONE AUTHORITY FOR "IS THIS UNIT ALIVE RIGHT NOW" ─────────────────────────────────────────────
-- combat_units.alive_count > 0, evaluated against the LIVE table. That is the whole predicate; it
-- is a single column comparison, not a derivation, and it is what every other liveness read in this
-- function already uses (the shield-regen loop, the snapshot itself, the target re-read, the
-- aggregate arm's two reads). The new actor guard is the SEVENTH site of that one predicate and
-- introduces no second spelling: no helper function, no cached flag, no "is_destroyed" column.
-- Wrapping it in a new leaf would have created a second name for a predicate the body already
-- states literally, plus a new grantable surface — that is the spaghetti this law forbids, not the
-- cure for it. Self-assert (d) below pins the count so a future author cannot quietly add an
-- eighth, differently-worded one.
--
-- ── ORDERING FAIRNESS: A FINDING, NOT A CHANGE ───────────────────────────────────────────────────
-- Once the dead stop shooting, WHO DIES FIRST inside a tick starts to matter, and it did not
-- before. It is therefore worth stating plainly what decides the order:
--   THE LOOP ORDER IS NOT DETERMINISTIC. v_units is built by jsonb_agg over
--   "select … from combat_units cu2 where cu2.encounter_id = e.id and cu2.alive_count > 0" with NO
--   order by (0299:805-813), and the loop iterates that array. jsonb_agg preserves the order the
--   scan produced, which for this table is physical heap order — insertion order for freshly
--   inserted rows, but not stable afterwards: the shield-regen UPDATE runs immediately before the
--   snapshot, every damaged row is rewritten each tick, and each wave spawn DELETEs and re-INSERTs
--   the whole enemy side (0299:768). So the firing order within a tick is effectively arbitrary and
--   can change from tick to tick.
--   CONSEQUENCE, STATED HONESTLY: a MUTUAL kill no longer resolves as it did. Before this
--   migration, two units that could each destroy the other in one tick both died, because the
--   loser's shot still landed after its own death. After it, whichever the loop reaches first kills
--   and survives. This is a deliberate, argued change, not an oversight:
--     * the engine has ALWAYS been strictly sequential in DAMAGE — the target re-read means a unit
--       that dies mid-tick immediately stops absorbing hits. Death already took effect instantly
--       for the dying unit in its TARGET role. The firer exemption was the anomaly, not the rule,
--       and "simultaneous" was never the model: only POSITION is simultaneous, via the freeze.
--     * the alternative — keep the dead firing so mutual kills stay mutual — is exactly the defect.
--   THIS MIGRATION DOES NOT CHANGE THE ORDER. Sorting the snapshot (by id, say) would make the tick
--   reproducible but no fairer: a uuid order is just as arbitrary, and it would permanently hand
--   every mutual kill to the same hull. A genuinely fair model (resolve all fire from the snapshot,
--   then apply damage together) is a different design and the owner's call — it is recorded here as
--   an open decision, not smuggled in.
--
-- ── BLAST RADIUS ON THE LIVE GAME ────────────────────────────────────────────────────────────────
--   * CREATE OR REPLACE of one function: an ATOMIC CATALOG SWAP. No table lock, no row written at
--     deploy, no schema change, no grant change. Unlike the frozen weapons_json values a wave
--     snapshots at spawn, the tick body is read fresh on every invocation, so THE VERY NEXT TICK OF
--     EVERY RUNNING FIGHT RUNS THE NEW BODY. There is no per-fight opt-in and no drain.
--   * NOTHING IS STRANDED MID-WAVE. The guard writes nothing, reads nothing new, and changes no
--     state a later tick depends on. A fight that is mid-wave when this lands simply has one fewer
--     class of shot from the next tick on; wave counters, next_wave_at, retreat clocks, the
--     auto-exit arm and the reward path are all untouched.
--   * HOW MANY SHOTS DISAPPEAR — against LIVE production config, read read-only on 2026-08-03:
--     combat_tick_seconds 3, enemy_synthetic_max_units 6, enemy_hp_base 14,
--     enemy_hp_danger_scale 0.6, danger_time_divisor_seconds 180, and the three ACTIVE hunt
--     grounds carry base_difficulty 10 / 15 / 25.
--     What is removed is exactly the shots a unit would have fired in the tick it died, AFTER its
--     death. With an arbitrary firing order that is, in expectation, HALF the units destroyed in
--     that tick, times one weapon each (every live unit carries exactly one — the fitted gun, the
--     0262 fallback, or the synthetic pirate gun). So: about 0.5 shots per DESTROYED unit, and
--     nothing at all in a tick where nobody dies, which is most ticks.
--     Per fight: a wave is min(6, danger) pirates, and danger rises by one per wave cleared plus
--     one per 180s, so from the sixth wave on every wave is six. A 14-wave fight — the length the
--     2026-07-22 canary actually reached before dying — destroys on the order of 65-70 pirate
--     units, so ROUGHLY 30-35 PIRATE SHOTS VANISH ACROSS THE WHOLE FIGHT. As a fraction it is 0.5
--     divided by the average number of ticks a unit survives: a wave one-shotted on the tick it
--     spawns loses up to half its fire, a wave that lives three ticks about a sixth. Call it
--     10-20% of incoming pirate fire in a heavy fight, concentrated entirely on kill ticks.
--   * WHO IT FAVOURS: the side that lands the killing blow first stops eating a return shot. At
--     live difficulties the player is that side by a wide margin — a hunt combat is an endless
--     escalating wave ladder, so ONE fight destroys those 65-70 pirate units while the pirates
--     destroy the player's 1-4 hulls once, on the tick the fight ends. SO THIS FAVOURS THE PLAYER:
--     fights get modestly more survivable, entirely on wave-clearing ticks. The pirates gain the
--     mirror benefit only on that final tick, which the player was losing anyway. It changes no
--     reward, no drop, no threshold and no config value.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed tick with the guard removed (0299's text at :822-826). No state to unwind:
-- this migration writes no rows, no schema, no grants, no game_config.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
-- WHAT THESE PROVE, HONESTLY: that the emitted TEXT is what this migration intended — never that it
-- EXECUTES (plpgsql resolves nothing until first execution). Behaviour is proven by exactly one
-- layer: the disposable apply-proof driving the REAL tick (danger-combat-proof's DEADFIRE block).
--   (a) the actor guard exists exactly once and reads the LIVE table
--   (b) it is side-blind, and it precedes both the retreat gate and the position write
--   (c) the freeze survives: one snapshot build, two reads of it, no per-unit re-read
--   (d) the target's liveness authority is unchanged, and the one predicate now has exactly 7 sites
--   (e) every carried-through 0299/0310/0314 invariant survives the re-emission
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
    raise exception '0317 PRECONDITION FAIL: process_combat_ticks is absent';
  end if;
  select prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  -- the base must be the post-0310 body (the auto-exit arm):
  if position('presence_request_leave(e.presence_id)' in v_tick) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed tick lacks the 0310 auto-exit arm — this is not the chain 0317 was generated against';
  end if;
  -- …and the post-0314 body (the per-hit roll):
  if position('v_hit_roll' in v_tick) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed tick lacks the 0314 per-hit roll — this is not the chain 0317 was generated against';
  end if;
  if position('public.combat_encounter_side_power(e.id, ''player'')' in v_tick) = 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed tick is not the 0299 lineage (the snapshot-power authority is absent)';
  end if;
  -- the defect must still be there: the actor's liveness is not re-read anywhere yet.
  if position('perform 1 from combat_units where id = v_ur.id and alive_count > 0;' in v_tick) > 0 then
    raise exception '0317 PRECONDITION FAIL: the deployed tick already carries an actor-liveness guard — refusing to re-emit over an unknown edit';
  end if;
end $pre$;

-- ── 1. CAPTURE METADATA BEFORE THE REWRITE (for parity check f) ──────────────────────────────────
create temp table _0317_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0317_before
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

  if v_done <> 1 then
    raise exception '0317 REWRITE FAIL: rewrote % site(s), expected 1', v_done;
  end if;
  raise notice '0317: a unit destroyed earlier in a tick no longer moves and no longer fires — on both sides';
end $rewrite$;

-- ── 3. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) the actor guard exists exactly once and reads the LIVE table
do $a$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'perform 1 from combat_units where id = v_ur.id and alive_count > 0;', '')))
         / length('perform 1 from combat_units where id = v_ur.id and alive_count > 0;');
  if v_n <> 1 then
    raise exception '0317 ASSERT (a) FAIL: % actor-liveness guard(s) (want exactly 1, reading the LIVE combat_units row rather than the frozen snapshot)', v_n;
  end if;
  if position('perform 1 from combat_units where id = v_ur.id and alive_count > 0;
          if not found then
            continue;
          end if;' in v_code) = 0 then
    raise exception '0317 ASSERT (a) FAIL: the guard does not skip the iteration on a missing row — a guard that reads and does not act is not a guard';
  end if;
end $a$;

-- (b) the guard is SIDE-BLIND, and it precedes both the retreat gate and the position write
do $b$
declare v_code text; v_g integer; v_gate integer; v_move integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_g    := position('perform 1 from combat_units where id = v_ur.id and alive_count > 0;' in v_code);
  v_gate := position('if v_ur.side = ''player'' and not v_offense then' in v_code);
  v_move := position('update combat_units set pos_x = v_new_x, pos_y = v_new_y, updated_at = now() where id = v_ur.id;' in v_code);
  if v_g = 0 or v_gate = 0 or v_move = 0 then
    raise exception '0317 ASSERT (b) FAIL: guard/retreat-gate/position-write not all present (% / % / %) — absence is failure, not a pass', v_g, v_gate, v_move;
  end if;
  if v_g >= v_gate then
    raise exception '0317 ASSERT (b) FAIL: the actor guard does not precede the retreat gate — a dead unit must be out before any side-conditioned test runs';
  end if;
  if v_g >= v_move then
    raise exception '0317 ASSERT (b) FAIL: the actor guard does not precede the position write — a corpse would still slide across the arena';
  end if;
  -- SIDE-BLINDNESS: between the guard and the retreat gate there is no side test at all, so the
  -- guard cannot have acquired one. The retreat gate itself is the FIRST side-conditioned line.
  if position('side' in substr(v_code, v_g, v_gate - v_g)) > 0 then
    raise exception '0317 ASSERT (b) FAIL: a side reference sits between the actor guard and the retreat gate — the guard must be symmetric (a dead pirate stops firing on the same terms as a dead player hull)';
  end if;
end $b$;

-- (c) the freeze survives: one snapshot build, two reads of it, no per-unit re-read
do $c$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'into v_units', ''))) / length('into v_units');
  if v_n <> 1 then
    raise exception '0317 ASSERT (c) FAIL: the tick builds the population snapshot % time(s) (want exactly 1 — re-freezing per unit would destroy the simultaneity the freeze exists for)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'jsonb_to_recordset(v_units)', ''))) / length('jsonb_to_recordset(v_units)');
  if v_n <> 2 then
    raise exception '0317 ASSERT (c) FAIL: % read(s) of the frozen snapshot (want the head''s 2 — the unit loop and the targeting candidates)', v_n;
  end if;
  if position('where cu2.encounter_id = e.id and cu2.alive_count > 0;' in v_code) = 0 then
    raise exception '0317 ASSERT (c) FAIL: the snapshot no longer filters on liveness at freeze time — the head''s own precondition is gone';
  end if;
end $c$;

-- (d) the target's liveness authority is unchanged, and the ONE predicate has exactly 7 sites
do $d$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'from combat_units where id = v_target_id and alive_count > 0;', '')))
         / length('from combat_units where id = v_target_id and alive_count > 0;');
  if v_n <> 1 then
    raise exception '0317 ASSERT (d) FAIL: % target-liveness re-read(s) (want exactly 1 — this slice mirrors that authority for the actor, it does not touch it)', v_n;
  end if;
  -- ONE AUTHORITY: the same column predicate, and only it. 6 in the head (the shield-regen loop,
  -- the hull-sync loop, the snapshot build, the target re-read, and the aggregate arm's two) plus
  -- the new actor guard = 7. An eighth would mean somebody wrote a second way to ask this.
  v_n := (length(v_code) - length(replace(v_code, 'alive_count > 0', ''))) / length('alive_count > 0');
  if v_n <> 7 then
    raise exception '0317 ASSERT (d) FAIL: the tick carries % site(s) of the alive_count > 0 predicate (want exactly 7: the head''s 6 plus this slice''s actor guard)', v_n;
  end if;
  -- and no SECOND spelling of the same question crept in alongside it.
  if position('is_destroyed' in v_code) > 0 or position('alive_count <= 0' in v_code) > 0
     or position('alive_count = 0' in v_code) > 0 then
    raise exception '0317 ASSERT (d) FAIL: a second spelling of "is this unit alive" is in the tick — one authority, one predicate';
  end if;
end $d$;

-- (e) every carried-through 0299/0310/0314 invariant survives the re-emission
do $e$
declare v_code text; v_n integer; v_tok text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('fleet_get_power' in v_code) > 0 then
    raise exception '0317 ASSERT (e) FAIL: fleet_get_power is back in the tick (0299 reverted)';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_side_power(e.id, ''player'')', '')))
         / length('public.combat_encounter_side_power(e.id, ''player'')');
  if v_n <> 2 then
    raise exception '0317 ASSERT (e) FAIL: % of 2 power writes read the 0299 authority', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 8 then
    raise exception '0317 ASSERT (e) FAIL: the tick carries % cfg_bool call(s) (want the head''s 8 — this slice adds no gate)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'random(', ''))) / length('random(');
  if v_n <> 3 then
    raise exception '0317 ASSERT (e) FAIL: the tick carries % random( call(s) (want the post-0314 3: two wave seeds + the per-hit roll)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'movement_create(', ''))) / length('movement_create(');
  if v_n <> 2 then
    raise exception '0317 ASSERT (e) FAIL: the tick mints % movement leg(s) (want the head''s 2)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'presence_request_leave(e.presence_id)', '')))
         / length('presence_request_leave(e.presence_id)');
  if v_n <> 1 then
    raise exception '0317 ASSERT (e) FAIL: the 0310 auto-exit arm composes presence_request_leave % time(s) (want exactly 1)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'when query_canceled then raise;', '')))
         / length('when query_canceled then raise;');
  if v_n <> 2 then
    raise exception '0317 ASSERT (e) FAIL: % query_canceled re-raise line(s) (want exactly 2 — the 0206 guard''s and the 0310 arm''s)', v_n;
  end if;
  if position('select sum(msi.max_hp) into v_ae_cap' in v_code) = 0 then
    raise exception '0317 ASSERT (e) FAIL: the 0310 capacity denominator is gone — a stale-base re-emission';
  end if;
  foreach v_tok in array array[
      'v_hit_roll double precision := greatest(0, (1 - v_hit_var_pct) + random() * (2 * v_hit_var_pct));',
      'v_dmg := v_w_power * v_hit_roll;',
      'jsonb_build_object(''unit_id'', v_target_id, ''damage'', v_dmg));',
      'now() + make_interval(secs => coalesce((v_weapon->>''cooldown_seconds'')::double precision, 0))',
      'select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y',
      'v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)',
      'v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null',
      'if e.next_wave_at is not null and now() < e.next_wave_at then',
      'if v_w_range is not null and v_target_dist <= v_w_range',
      'and (v_w_next_ready is null or now() >= v_w_next_ready) then'
    ] loop
    if position(v_tok in v_code) = 0 then
      raise exception '0317 ASSERT (e) FAIL: the tick lost a pinned head guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
end $e$;

-- (f) metadata parity: the tick changed body and NOTHING else
do $f$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0317_before loop
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
      raise exception '0317 ASSERT (f) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0317 ASSERT (f) FAIL: public.% body is byte-identical — the hunk did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0317 ASSERT (f) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0317 SELF-ASSERT PASS: a unit destroyed earlier in the tick takes no turn — no move, no shot — on either side; the population freeze, the targeting, the target-liveness authority and every 0299/0310/0314 guarantee are untouched';
end $f$;

commit;
`;

if (sql.includes('\r')) {
  throw new Error('generated 0317 carries a CR — the rewrite hunk would never match the deployed body');
}

const check = process.argv.includes('--check');
if (check) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8');
  } catch {
    console.error('0317 CHECK FAIL: migration file is missing — run the generator');
    process.exit(1);
  }
  if (onDisk.replace(/\r\n/g, '\n') !== sql) {
    console.error('0317 CHECK FAIL: the migration on disk is not what the slices generate.');
    console.error('Either the 0299 source drifted or the file was hand-edited. Re-run the generator.');
    process.exit(1);
  }
  console.log('0317 CHECK OK: migration matches the slice taken from 0299.');
} else {
  writeFileSync(OUT, sql);
  console.log(`0317 written: ${OUT}`);
  console.log(`  ${HUNKS.length} hunk sliced from 0299 (nothing retyped; the new guard is prepended to the slice)`);
}
