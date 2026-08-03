#!/usr/bin/env node
// gen-0318-drawn-zones-stay-drawn.mjs — emit (or --check) migration 0318.
//
// WHY A GENERATOR: 0318 rewrites TWO hunks inside the live zone_update body. The true textual head of
// zone_update is 0287:74 — verified two ways: (1) the head check below refuses to run if any migration
// after 0287 textually re-creates it, and (2) production's pg_proc.prosrc for
// public.zone_update(text,jsonb) is BYTE-IDENTICAL to 0287's file body (md5
// b21f912267d32718fddb969f4802831f, 20931 bytes, measured 2026-08-03 through the Management API). The
// 0303 lesson — "never retype a live function body" — holds: every `old_t` below is SLICED verbatim out
// of 0287, and every `new_t` is CONSTRUCTED from that slice by exactly-once string edits, so even the
// unchanged lines inside a replaced hunk are byte-copies, never retyped. The migration then proves each
// slice is still what is deployed (occurs EXACTLY once in pg_get_functiondef), replaces it, and proves
// the length moved by exactly the hunk delta.
//
//   node scripts/gen-0318-drawn-zones-stay-drawn.mjs          # write the migration
//   node scripts/gen-0318-drawn-zones-stay-drawn.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000318_drawn_zones_stay_drawn.sql');

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECK: 0287 must still be the newest TEXTUAL re-create of zone_update. ──────────────────
// zone_update has been re-created by surgery five times (0266 → 0283 → 0284 → 0286 → 0287), which is
// exactly why this check exists rather than a comment claiming 0287 is the head. Replace-rewriters
// (this migration's own shape) do not move the textual head, but any later
// `create or replace function public.zone_update` means the slice source is stale.
{
  const reCreate = /create\s+or\s+replace\s+function\s+(?:public\.)?zone_update\s*\(/i;
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const newerHeads = readdirSync(MIGDIR)
    .filter((f) => f.endsWith('.sql') && version(f) > '20260618000287' && version(f) !== '20260618000318')
    .filter((f) => {
      // strip `--` line comments first: several migrations name the create in a comment, deliberately.
      const src = readFileSync(MIG(f), 'utf8').replace(/--[^\n]*/g, '');
      return reCreate.test(src);
    });
  if (newerHeads.length > 0) {
    throw new Error(
      `zone_update was textually re-created AFTER 0287 by: ${newerHeads.join(', ')} — ` +
      're-point the slices at the new head before generating.');
  }
}

const F287 = load('20260618000287_zone_edit_revision_concurrency.sql');

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

// ── THE TWO HUNKS ─────────────────────────────────────────────────────────────────────────────────
// Both sliced from 0287; disjoint; H1 is the prose that this change falsifies, H2 is the change.

// [H1] the claim that an edit preserves `source` bit-for-bit (0287:397-399). It is a COMMENT, and it
//      is now false — leaving it would be a second, contradictory statement of the rule inside the one
//      function that implements it. Correct it in the same slice that changes the behaviour.
const H1_OLD = slice(F287, '0287', 397, 399,
  'rollback', 'cannot change what KIND of row this is or who authored it).');
const H1_NEW =
`  -- rollback — no torn write). boundary + name + location_id + updated_at + revision are written, and
  -- since 0318 SO IS source, which this function sets to 'drawn' on every applied edit (see the hunk
  -- below for why). zone_kind ('pirate'), created_by, created_at and provenance are still preserved
  -- bit-for-bit: an edit cannot change what KIND of row this is, who authored it, or — the
  -- reversibility claim 0282/0283 rest on — its immutable protection class.`;

// [H2] the UPDATE's SET list (0287:405-412) — the one-line fix 0296:66-68 wrote down and deferred.
const H2_OLD = slice(F287, '0287', 405, 412,
  'update public.danger_zones', 'revision    = revision + 1');
const H2_NEW = edit(H2_OLD,
  `           updated_at  = now(),`,
`           -- ── 0318: THE ONE LINE THAT MAKES THE TWO BOUNDARY WRITERS DISJOINT BY CONSTRUCTION ──
           -- danger_zones.boundary has two writers. This one materializes an OWNER-AUTHORED ring.
           -- The other, danger_zone_rematerialize_for_location (0296:164-172), regenerates a DERIVED
           -- polygon from its location's (x, y, territory_radius) using 0237's random() generator,
           -- and it selects its rows with  where dz.source = 'circle'  — fired by location_update on
           -- every edit that moves one of those three inputs (0296:569-573).
           -- Until now this function preserved source bit-for-bit, so an owner who reshaped a
           -- seeded zone left the row still flagged 'circle', still inside the derived writer's
           -- selection — and the next location edit silently replaced their shape with a random
           -- blob. Unrecoverable, because the generator is random: there is nothing to invert.
           -- Setting source HERE moves the row out of that selection permanently. It is not a
           -- guard bolted onto the regenerator (that would be a second copy of the same rule in a
           -- second place); it is the two writers being made disjoint at the point where a row
           -- stops being derived. 0296:62-68 named this exact fix and left it to zone_update's own
           -- slice. This is that slice, and this is that line.
           -- WHAT IT DOES NOT TOUCH: provenance. 'seeded' stays 'seeded' (0282's immutable trigger),
           -- so seeded_zone_edit_enabled remains a genuine two-way toggle and this is not the
           -- one-way door that flipping source for PROTECTION would have been — 0282 split those two
           -- questions apart precisely so this answer could be given to the geometry one alone.
           source      = 'drawn',
           updated_at  = now(),`);

const HUNKS = [
  [1, 'zone_update', H1_OLD, H1_NEW],
  [2, 'zone_update', H2_OLD, H2_NEW],
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

// THE BACKFILL PREDICATE, written once here and emitted into both the UPDATE and its self-assert so
// the migration cannot drift between what it repairs and what it then claims to have repaired.
const PREDICATE = (alias) => `${alias}.source = 'circle' and exists (
      select 1
        from public.world_editor_audit a
       where a.command_type = 'zone_update'
         and a.target_type  = 'zone'
         and a.target_id    = ${alias}.id::text
         and a.after_snapshot ? 'boundary_wkt'
         and public.st_orderingequals(
               ${alias}.boundary,
               public.st_geomfromtext(a.after_snapshot->>'boundary_wkt', public.st_srid(${alias}.boundary))))`;

const sql = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0318 — A ZONE THE OWNER DREW STAYS DRAWN: zone_update claims the row for the authored writer,
--        and the rows already at risk are claimed retroactively from the audit ledger.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE DEFECT: TWO WRITERS, ONE ROW, AND A RANDOM GENERATOR ──────────────────────────────────────
-- public.danger_zones.boundary has two writers:
--   * zone_update (0266, head 0287:405) — materializes the ring the OWNER drew in the World Editor.
--   * danger_zone_rematerialize_for_location (0296:141) — regenerates a DERIVED polygon from its
--     location's (x, y, territory_radius) with 0237's random() generator. It selects
--     \`where dz.source = 'circle'\` (0296:169) and location_update fires it whenever any of those
--     three inputs changes (0296:569-573).
-- zone_update never flipped a reshaped row to source='drawn'. So an owner-reshaped SEEDED zone kept
-- source='circle', stayed inside the derived writer's selection, and the next edit of its location
-- would overwrite the owner's hand-drawn shape with a random blob. random() has no inverse: there is
-- nothing to recover, and world_editor_revert cannot help (it re-applies an audit snapshot; it does
-- not re-derive geometry — verified against production).
--
-- 0296 SAW THIS AND LEFT IT (0296:62-68), on the stated premise that "the flag being dark means no
-- such row can exist today". THAT PREMISE IS FALSE ON PRODUCTION: seeded_zone_edit_enabled was lit by
-- 0300:85-86, and a row in exactly this state exists. Measured read-only through the Management API
-- on 2026-08-03 (production head was 20260618000316 when measured and 20260618000317 by the time this
-- slice was renumbered off that collision — 0317 went to the_dead_do_not_shoot, which re-creates
-- process_combat_ticks and touches neither zone_update nor danger_zones, so no reading below moved):
--   * 11 zone_update audit rows, targeting the three seeded source='circle' zones
--     (Blackden x6, Snare x3, Reaver x2). Every one of them recorded after_snapshot.source = 'circle'.
--   * Snare (d14306c7…): danger_zones.updated_at = 2026-07-26 23:51:36.587011+00, EXACTLY the
--     created_at of its last zone_update audit row, and ST_AsText(boundary) is BYTE-IDENTICAL to that
--     row's after_snapshot->>'boundary_wkt' (265 chars, 19 points, ST_OrderingEquals true). Its
--     geometry IS the owner's, intact, and one location edit from being destroyed.
--   * Blackden and Reaver: updated_at = 2026-07-26 23:30:25.264762+00 for BOTH — later than either
--     one's last zone_update, matching no audit row, and their current boundaries match none of their
--     own snapshots. That timestamp is 0296's backfill sweep. Their authored shapes are already gone.
--
-- ── PART 1 — THE FIX: ONE LINE, AND THE WRITERS ARE DISJOINT BY CONSTRUCTION ──────────────────────
-- zone_update sets source='drawn' when it materializes an owner ring. From that instant the row is
-- outside \`where dz.source = 'circle'\` forever, so the derived writer can never select it again.
--
-- WHY NOT A GUARD ON THE REGENERATOR. Because that would be a SECOND place stating the same rule —
-- the regenerator already asks "is this row derived?" and answers it with \`source\`. Adding
-- "…unless it was hand-edited" beside it makes two authorities for one question and leaves the row
-- itself still lying about what it is. Setting \`source\` fixes the LIE, and every reader of it —
-- present and future — inherits the fix without knowing this migration happened. One authority.
--
-- WHY THIS IS NOT THE ONE-WAY DOOR THAT WAS REJECTED. Flipping \`source\` to unlock seeded zones was
-- rejected, correctly (0283:7). At that time \`source\` carried TWO questions at once: geometry
-- representation AND protection class. 0282 split them: \`provenance\` (immutable, trigger-enforced)
-- now answers protection, and every protection guard was re-pointed at it (zone_update 0287:173,
-- zone_unpublish 0286:497, zone_set_active 0286:663). This migration answers ONLY the geometry
-- question and never writes \`provenance\` — so a seeded row stays seeded, seeded_zone_edit_enabled
-- stays a genuine two-way toggle, and turning it off still restores protection exactly.
--
-- ── PART 2 — THE BACKFILL: CLAIM WHAT IS PROVABLY AUTHORED, AND NOTHING ELSE ──────────────────────
-- THE PREDICATE, stated plainly: a row is claimed iff source='circle' AND its CURRENT boundary is
-- structurally identical (ST_OrderingEquals — same vertices, same order) to the after_snapshot of at
-- least one of its OWN zone_update audit rows.
--
-- That is not a shape heuristic. It is the ledger: the World Editor records, for every applied edit,
-- the exact WKT it wrote (0287:415-417). If the boundary sitting in the table today is still that
-- geometry, then the last thing to write this row was the owner, and no sweep has been over it since.
-- If it is not, some other writer has already replaced it and there is nothing left to rescue — the
-- migration says so and leaves the row alone rather than mislabelling a derived blob as authored.
-- ST_OrderingEquals, not ST_Equals: this asks "is this the SAME geometry", not "does it cover the
-- same area" — two different rings can be topologically equal and this must not accept them.
--
-- BOTH ERROR DIRECTIONS WERE WEIGHED, and the predicate is exact rather than merely cautious:
--   * A row wrongly claimed would stop tracking its location forever — silent, permanent.
--   * A row wrongly skipped stays exposed to the very defect this fixes.
-- The generator produces doubles from random(); the probability that a regenerated polygon reproduces
-- an owner snapshot vertex-for-vertex is not a risk that needs hedging. So the predicate is neither
-- widened by shape statistics (Blackden's equivalent radius sits INSIDE the generator's 0.492x..1.77x
-- band and Snare's does not — but that is a coincidence of this dataset, not evidence, and a
-- migration must not key on it) nor narrowed to "the LATEST audit row" (if the live boundary matches
-- ANY authored snapshot, the owner authored what is there now).
--
-- ON PRODUCTION THIS SELECTS EXACTLY ONE ROW: Snare. Evaluated read-only before writing this file —
-- 14 zones, 3 with source='circle', all 3 with zone_update history, 1 matching. Blackden and Reaver
-- are DELIBERATELY LEFT: the ledger says their authored geometry is already lost, and flipping them
-- would freeze a random blob in place while claiming an owner drew it.
--
-- On a fresh disposable stack it selects ZERO rows (no audit history exists), which is correct and
-- makes every assert below vacuously true there — the 0295 lesson: a migration must never require a
-- seed row to exist.
--
-- WHAT THE BACKFILL DOES NOT WRITE: not provenance (immutable, and the protection class is unchanged),
-- not boundary, not revision, not updated_at, not location_id, not name, not status. Deliberately not
-- revision: this is a classification repair, not an edit, and bumping the concurrency token would
-- invalidate an open owner draft for no reason. Deliberately not updated_at: it is the evidence.
--
-- ── BLAST RADIUS ON ~30 LIVE PLAYERS ──────────────────────────────────────────────────────────────
--   ROWS WRITTEN: exactly 1 on production (Snare), 0 on a fresh stack. One column, one value.
--   COMBAT / INTERCEPTS / FIGHTS IN FLIGHT: UNCHANGED. Nothing on the ambush path reads \`source\`.
--     pirate_intercept_leg_zone_hits (0301:379) filters status='active' + ST_Intersects and no more;
--     pirate_intercept_plan_leg / _leg_entry / _evaluate_leg / _resolve_due_for_movement,
--     danger_zone_contains_point and combat_encounter_zone_admits_point (0311) never mention it.
--     Verified against production's live prosrc, not inferred. Boundaries do not move, so a pending
--     intercept, an open encounter and a leg mid-flight all see the identical geometry they saw
--     before the deploy. A zone that was tracking its location CORRECTLY is not touched at all.
--   WHAT DOES CHANGE, STATED HONESTLY — three reader-visible consequences for the one flipped row:
--     1. THE MAP. src/features/map/dangerZoneLayer.ts:65 tones a zone by \`source\`, and :115 dashes
--        the outline for 'drawn'. Snare renders amber-dashed instead of red-solid for every player.
--        This is cosmetic and it is the TRUTHFUL rendering: it is a hand-drawn ring and now says so.
--        No client change ships with this migration because none is needed — the client already
--        renders exactly this distinction; it was the DATA that was wrong.
--     2. THE EDITOR'S LIFECYCLE BUTTON. src/features/worldeditor/zoneLifecycle.ts:79 enables
--        Unpublish/Reactivate only for 'drawn'. It becomes enabled for Snare — which merely stops the
--        client contradicting the SERVER, where zone_set_active/zone_unpublish have gated on
--        provenance + seeded_zone_lifecycle_enabled (lit, 0300) since 0286. Owner-only surface.
--     3. world_editor_revert (0267:611) is the ONE protection guard 0283 did not re-point: it still
--        refuses \`v_live.source <> 'drawn'\`, unconditionally. Snare therefore becomes revertable
--        through the History panel. Owner-only, audited, itself revertible, and it does NOT
--        re-derive geometry (confirmed against production's live body). It is not fixed here —
--        re-pointing that guard at \`provenance\` is its own slice and mixing it in would put two
--        unrelated changes behind one deploy. It is named here so it is not discovered later.
--   ROLLBACK: \`update public.danger_zones set source='circle' where id = <the flipped id>\` restores
--     the classification exactly (provenance never moved, so nothing else has to be undone), and
--     re-applying 0287's two hunks restores the function. No state to unwind; no schema, grant, flag,
--     policy, cron or game_config row is touched by this migration.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ──────────────
--   (a) zone_update sets source='drawn' exactly once, and the falsified "preserved bit-for-bit"
--       claim is gone from its body
--   (b) zone_update kept every 0287 guarantee across the re-emission (revision authority, the
--       provenance-based seeded gate, the ST_Equals compare still absent, the 0239 lockdown)
--   (c) THE DISJOINTNESS INVARIANT: no row is left where source='circle' AND the live boundary is a
--       recorded authored geometry — the two writers' selections no longer overlap
--   (d) the backfill wrote ONLY \`source\`, and ONLY on rows the predicate selects — proven against a
--       before-snapshot, not asserted
--   (e) provenance moved nowhere (this is not a laundering of seeded content into owner content)
--   (f) the derived writer is UNTOUCHED and still selects source='circle' — one authority, not two
--   (g) danger_zones grants / the 0239 lockdown intact
--   (h) metadata parity: zone_update changed body and NOTHING else
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
  if to_regclass('public.danger_zones') is null then
    raise exception '0318 PRECONDITION FAIL: public.danger_zones (0233) is absent';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception '0318 PRECONDITION FAIL: public.world_editor_audit (0243/0244) is absent — the backfill reads its ledger';
  end if;
  if to_regprocedure('public.zone_update(text,jsonb)') is null then
    raise exception '0318 PRECONDITION FAIL: public.zone_update(text,jsonb) is absent';
  end if;
  if to_regprocedure('public.danger_zone_rematerialize_for_location(uuid)') is null then
    raise exception '0318 PRECONDITION FAIL: public.danger_zone_rematerialize_for_location(uuid) (0296) is absent — the writer this slice becomes disjoint from must exist';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='danger_zones' and column_name='provenance') then
    raise exception '0318 PRECONDITION FAIL: danger_zones.provenance (0282) is absent — the split this slice depends on has not landed';
  end if;
  -- the exact signature strings already proven by shipped gates (0254:74, 0267:85, 0296:114-117).
  if to_regprocedure('public.st_orderingequals(public.geometry, public.geometry)') is null
     or to_regprocedure('public.st_geomfromtext(text, integer)') is null
     or to_regprocedure('public.st_srid(public.geometry)') is null then
    raise exception '0318 PRECONDITION FAIL: PostGIS (installed by 0233) is missing the exact-geometry comparison this backfill predicate composes';
  end if;

  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='zone_update';
  -- the base must be the 0287 lineage (revision is the concurrency authority, provenance is the gate):
  if position('v_exp_rev::bigint is distinct from v_live.revision' in v_src) = 0 then
    raise exception '0318 PRECONDITION FAIL: the deployed zone_update is not the 0287 lineage (the revision concurrency authority is absent)';
  end if;
  if position('v_live.provenance = ''seeded''' in v_src) = 0 then
    raise exception '0318 PRECONDITION FAIL: the deployed zone_update lacks the provenance-based seeded gate — this is not the chain 0318 was generated against';
  end if;
  if position('source      = ''drawn''' in v_src) > 0 then
    raise exception '0318 PRECONDITION FAIL: the deployed zone_update already sets source — refusing to re-emit over an unknown edit';
  end if;
end $pre$;

-- ── 1. CAPTURE STATE BEFORE THE REWRITE + BACKFILL (for parity checks d/e/h) ─────────────────────
create temp table _0318_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0318_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'zone_update';

-- EVERY zone row as it stands right now, plus whether the predicate selects it. Check (d) then proves
-- the backfill changed exactly \`source\`, exactly on the selected set, and nothing else anywhere —
-- against a snapshot rather than against a promise (the 0296:229-233 idiom).
create temp table _0318_zones_before on commit drop as
  select z.id,
         z.source,
         z.provenance,
         z.location_id,
         z.name,
         z.status,
         z.zone_kind,
         z.revision,
         z.updated_at,
         public.st_asbinary(z.boundary) as wkb,
         (${PREDICATE('z')}) as selected
    from public.danger_zones z;

-- ── 2. REWRITE THE TWO HUNKS (located by exact deployed text, never retyped) ─────────────────────
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
      raise exception '0318 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0318 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0318 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0318 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 2 then
    raise exception '0318 REWRITE FAIL: rewrote % site(s), expected 2', v_done;
  end if;
  raise notice '0318: zone_update now claims the row for the authored writer (source := drawn)';
end $rewrite$;

-- ── 3. THE BACKFILL — claim the rows the ledger proves are already owner-authored ────────────────
-- Vacuous on a fresh disposable stack (no audit history), which is correct: this is data repair.
do $backfill$
declare
  v_n integer;
  v_names text;
begin
  select string_agg(z.name, ', ' order by z.name) into v_names
    from public.danger_zones z
   where ${PREDICATE('z')};

  update public.danger_zones z
     set source = 'drawn'
   where ${PREDICATE('z')};
  get diagnostics v_n = row_count;

  raise notice '0318: claimed % zone(s) as owner-authored from the world_editor_audit ledger: %',
    v_n, coalesce(v_names, '(none — no zone carries a live boundary matching one of its own zone_update snapshots)');
end $backfill$;

-- ── 4. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) zone_update sets source='drawn' exactly once, and the falsified claim is gone
do $a$
declare v_code text; v_def text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'zone_update';
  v_n := (length(v_code) - length(replace(v_code, 'source      = ''drawn'',', '')))
         / length('source      = ''drawn'',');
  if v_n <> 1 then
    raise exception '0318 ASSERT (a) FAIL: zone_update sets source % time(s) (want exactly 1 — the write that makes the two boundary writers disjoint)', v_n;
  end if;
  -- it must be in the UPDATE's SET list, not somewhere incidental: the surrounding write survives.
  if position('update public.danger_zones' in v_code) = 0
     or position('revision    = revision + 1' in v_code) = 0 then
    raise exception '0318 ASSERT (a) FAIL: the danger_zones UPDATE or its revision bump did not survive the rewrite';
  end if;
  -- the COMMENT that claimed source is preserved is false now; it must not survive (checked against
  -- the UNSTRIPPED definition, because that is the only place a comment exists).
  v_def := pg_get_functiondef(to_regprocedure('public.zone_update(text, jsonb)'));
  if position('created_by and created_at are preserved bit-for-bit' in v_def) > 0 then
    raise exception '0318 ASSERT (a) FAIL: zone_update still carries the falsified claim that an edit preserves source bit-for-bit — a second, contradictory statement of the rule this migration changes';
  end if;
end $a$;

-- (b) every 0287 guarantee survived the re-emission
do $b$
declare v_code text; v_n integer; v_set text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'zone_update';
  -- revision is still the ONE concurrency authority (0287's whole point)
  if position('v_exp_rev::bigint is distinct from v_live.revision' in v_code) = 0 then
    raise exception '0318 ASSERT (b) FAIL: the revision concurrency compare is gone (0287 regressed)';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'revision    = revision + 1', ''))) / length('revision    = revision + 1');
  if v_n <> 1 then
    raise exception '0318 ASSERT (b) FAIL: % revision bump(s) (want exactly 1 — the token must still advance)', v_n;
  end if;
  -- the seeded gate is still provenance-based and still flag-gated (0287:173-179)
  if position('v_live.provenance = ''seeded''' in v_code) = 0
     or position('cfg_bool(''seeded_zone_edit_enabled'')' in v_code) = 0 then
    raise exception '0318 ASSERT (b) FAIL: the provenance-based seeded gate or its flag is gone — protection must not move with the geometry flag';
  end if;
  -- zone_update must NEVER write provenance (the reversibility claim of 0282/0283). Probed on the
  -- UPDATE's SET LIST ONLY, isolated between its own fences: a naive search for 'provenance' would
  -- match the READ at the seeded gate above (v_live.provenance = 'seeded') and fire on a correct body.
  v_set := substring(v_code from position('update public.danger_zones' in v_code));
  v_set := substring(v_set for position('where id = v_live.id' in v_set));
  if v_set = '' or position('set boundary    = v_boundary,' in v_set) = 0 then
    raise exception '0318 ASSERT (b) FAIL: could not isolate the danger_zones UPDATE set-list — the fences moved, so this check cannot be trusted';
  end if;
  if position('provenance' in v_set) > 0 then
    raise exception '0318 ASSERT (b) FAIL: zone_update writes provenance — lighting the edit flag would become a ONE-WAY DOOR';
  end if;
  -- the same isolation proves the new write is IN the set-list rather than merely somewhere in the body
  if position('source      = ''drawn'',' in v_set) = 0 then
    raise exception '0318 ASSERT (b) FAIL: the source write is not inside the danger_zones UPDATE set-list';
  end if;
  -- the lossy ST_Equals compare 0287 deleted must stay deleted (no second concurrency authority)
  if position('st_equals(v_exp_boundary' in v_code) > 0 then
    raise exception '0318 ASSERT (b) FAIL: the ST_Equals expected-boundary compare is back — one concurrency authority only';
  end if;
  -- the 0239 lockdown: zone_update never reaches a locked pirate_zone surface
  if position('pirate_zone' in v_code) > 0 then
    raise exception '0318 ASSERT (b) FAIL: zone_update references a 0239-locked pirate_zone surface';
  end if;
end $b$;

-- (c) THE DISJOINTNESS INVARIANT — the headline property of this migration
do $c$
declare v_bad integer;
begin
  select count(*) into v_bad
    from public.danger_zones z
   where ${PREDICATE('z')};
  if v_bad > 0 then
    raise exception '0318 ASSERT (c) FAIL: % zone(s) still carry source=circle while their live boundary IS a recorded owner-authored geometry — the derived writer would regenerate over them on the next location edit', v_bad;
  end if;
end $c$;

-- (d) the backfill wrote ONLY source, ONLY on selected rows — proven against the before-snapshot
do $d$
declare v_bad integer; v_moved integer;
begin
  -- no row appeared or vanished, and nothing but source moved ANYWHERE
  select count(*) into v_bad
    from _0318_zones_before b
    full outer join (
      select z.id, z.source, z.provenance, z.location_id, z.name, z.status, z.zone_kind,
             z.revision, z.updated_at, public.st_asbinary(z.boundary) as wkb
        from public.danger_zones z
    ) a on a.id = b.id
   where a.id is null
      or b.id is null
      or a.wkb        is distinct from b.wkb
      or a.provenance is distinct from b.provenance
      or a.location_id is distinct from b.location_id
      or a.name       is distinct from b.name
      or a.status     is distinct from b.status
      or a.zone_kind  is distinct from b.zone_kind
      or a.revision   is distinct from b.revision
      or a.updated_at is distinct from b.updated_at;
  if v_bad > 0 then
    raise exception '0318 ASSERT (d) FAIL: % zone row(s) changed something other than source — this migration writes exactly one column', v_bad;
  end if;

  -- every SELECTED row moved circle -> drawn; every UNSELECTED row kept its source verbatim
  select count(*) into v_bad
    from _0318_zones_before b
    join public.danger_zones a on a.id = b.id
   where (b.selected and not (b.source = 'circle' and a.source = 'drawn'))
      or (not b.selected and a.source is distinct from b.source);
  if v_bad > 0 then
    raise exception '0318 ASSERT (d) FAIL: % zone row(s) do not match the predicate''s verdict — a row was claimed that the ledger does not prove, or a claimed row did not move', v_bad;
  end if;

  select count(*) into v_moved from _0318_zones_before where selected;
  raise notice '0318 (d) OK: exactly % row(s) moved circle -> drawn, and nothing else changed on any zone', v_moved;
end $d$;

-- (e) provenance moved nowhere — this is not a laundering of seeded content into owner content
do $e$
declare v_bad integer;
begin
  select count(*) into v_bad
    from _0318_zones_before b
    join public.danger_zones a on a.id = b.id
   where a.provenance is distinct from b.provenance;
  if v_bad > 0 then
    raise exception '0318 ASSERT (e) FAIL: % zone(s) changed provenance — a seeded zone must stay seeded so seeded_zone_edit_enabled remains a two-way toggle', v_bad;
  end if;
  -- and a claimed row is still protectable material: it kept whatever provenance it had.
  if exists (select 1 from _0318_zones_before b join public.danger_zones a on a.id = b.id
              where b.selected and a.provenance <> b.provenance) then
    raise exception '0318 ASSERT (e) FAIL: a claimed row was reclassified — 0282''s immutable protection class must survive this repair';
  end if;
end $e$;

-- (f) the derived writer is UNTOUCHED and still selects source='circle' — ONE authority, not two
do $f$
declare v_code text;
begin
  select prosrc into v_code from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'danger_zone_rematerialize_for_location';
  if position('dz.source = ''circle''' in v_code) = 0 then
    raise exception '0318 ASSERT (f) FAIL: the derived writer no longer restricts itself to source=circle — this slice makes the two writers disjoint by fixing the ROW, never by weakening the regenerator';
  end if;
  -- it must not have grown a second, duplicated guard (the no-spaghetti law, asserted not promised)
  if position('provenance' in v_code) > 0 or position('world_editor_audit' in v_code) > 0 then
    raise exception '0318 ASSERT (f) FAIL: the derived writer acquired a second selection rule — the source predicate is its ONE authority';
  end if;
  if has_function_privilege('anon', 'public.danger_zone_rematerialize_for_location(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.danger_zone_rematerialize_for_location(uuid)', 'execute') then
    raise exception '0318 ASSERT (f) FAIL: a client role can execute the re-materialization authority — it is definer-internal (0296)';
  end if;
end $f$;

-- (g) danger_zones grants / the 0239 lockdown intact
do $g$
begin
  if has_table_privilege('authenticated', 'public.danger_zones', 'INSERT')
     or has_table_privilege('authenticated', 'public.danger_zones', 'UPDATE')
     or has_table_privilege('authenticated', 'public.danger_zones', 'DELETE')
     or has_table_privilege('anon', 'public.danger_zones', 'UPDATE') then
    raise exception '0318 ASSERT (g) FAIL: a client role holds a write grant on danger_zones (0239/0254 lockdown regressed)';
  end if;
  if not has_function_privilege('authenticated', 'public.zone_update(text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.zone_update(text,jsonb)', 'execute') then
    raise exception '0318 ASSERT (g) FAIL: zone_update grants moved — it is authenticated-only, never anon';
  end if;
end $g$;

-- (h) metadata parity: zone_update changed body and NOTHING else
do $h$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0318_before loop
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
      raise exception '0318 ASSERT (h) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0318 ASSERT (h) FAIL: public.% body is byte-identical — the hunks did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0318 ASSERT (h) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0318 SELF-ASSERT PASS: a zone the owner draws is flagged drawn at the moment it is drawn, the derived regenerator can never select it again, and every row whose live boundary the audit ledger proves is owner-authored has been claimed — provenance, geometry, revision and every grant untouched';
end $h$;

commit;
`;

if (sql.includes('\r')) {
  throw new Error('generated 0318 carries a CR — the rewrite hunks would never match the deployed body');
}

const check = process.argv.includes('--check');
if (check) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8');
  } catch {
    console.error('0318 CHECK FAIL: migration file is missing — run the generator');
    process.exit(1);
  }
  if (onDisk.replace(/\r\n/g, '\n') !== sql) {
    console.error('0318 CHECK FAIL: the migration on disk is not what the slices generate.');
    console.error('Either the 0287 source drifted or the file was hand-edited. Re-run the generator.');
    process.exit(1);
  }
  console.log('0318 CHECK OK: migration matches the slices taken from 0287.');
} else {
  writeFileSync(OUT, sql);
  console.log(`0318 written: ${OUT}`);
  console.log(`  ${HUNKS.length} hunks sliced from 0287 (nothing retyped; new text constructed from the slices)`);
}
