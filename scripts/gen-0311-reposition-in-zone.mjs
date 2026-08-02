#!/usr/bin/env node
// gen-0311-reposition-in-zone.mjs — emit (or --check) migration 0311.
//
// WHY A GENERATOR: 0311 rewrites ONE hunk inside the live command_ship_group_go (the busiest player
// RPC in the game). The 0303 lesson — "never retype a live function body" — cost a silently-dropped
// guard once already, so the `old_t` below is SLICED verbatim out of 0301, the migration that last
// defines the hunk's text (0305's hunk replaced the sortie count at 0301:1659-1664 and 0307's
// replaced the loot comment at 0301:1740-1742 — both DISJOINT from this hunk, verified by reading
// both migrations' `old_t` texts). The migration then proves the slice is still what is deployed
// (occurs EXACTLY once in pg_get_functiondef), replaces it, and proves the length moved by exactly
// the hunk delta — byte parity outside the hunk is a property of the method, not a review promise.
//
//   node scripts/gen-0311-reposition-in-zone.mjs          # write the migration
//   node scripts/gen-0311-reposition-in-zone.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000311_reposition_inside_the_fights_zone.sql');

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECK: 0301 must still be the newest textual re-create of command_ship_group_go. ─────────
// 0305/0307 rewrite it by replace() over pg_get_functiondef (no textual re-create), so a textual
// `create or replace function public.command_ship_group_go(` in any migration NEWER than 0301 means
// the head moved and this generator's slice source is stale. Do NOT assume — scan.
{
  const reCreate = /create\s+or\s+replace\s+function\s+public\.command_ship_group_go\s*\(/i;
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const newerHeads = readdirSync(MIGDIR)
    .filter((f) => f.endsWith('.sql') && version(f) > '20260618000301' && version(f) !== '20260618000311')
    .filter((f) => reCreate.test(readFileSync(MIG(f), 'utf8')));
  if (newerHeads.length > 0) {
    throw new Error(
      `command_ship_group_go was textually re-created AFTER 0301 by: ${newerHeads.join(', ')} — ` +
      're-point the slice at the new head before generating.');
  }
}

const F301 = load('20260618000301_intercept_fires_at_zone_entry.sql');

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

// ── The one hunk: step 8's settling-race guard (0301:1706-1710). Untouched by 0302..0309 (0305's
// ── go hunk replaced the sortie count; 0307's replaced the loot comment; nothing else touched go).
// ── The reposition branch is INSERTED between this guard and the destination write at 0301:1715.
const G_GUARD = slice(F301, '0301', 1706, 1710, "if v_enc.status = 'active'", 'end if;');

const G_GUARD_NEW = `      if v_enc.status = 'active'
         and not exists (select 1 from public.location_presence lp
                          where lp.id = v_enc.presence_id and lp.status = 'active') then
        return jsonb_build_object('ok', false, 'reason', 'movement_settled_retry');
      end if;

      -- ── 0311: REPOSITION INSIDE THE FIGHT'S OWN ZONE — "repositioning is a tactical move". ─────
      -- The owner's law: only an order OUT of the zone breaks combat. An order whose destination is
      -- STRICTLY INSIDE the same active danger zone that anchors this encounter's engagement point
      -- MOVES the fleet, and the fight moves with it — no retreat armed, no destination stored, no
      -- window, no leg. Everything else falls through to the (a)/(b) retreat arms below, byte-
      -- identical. Gated to encounter 'active': a 'retreating' fight may only update its stored
      -- destination in arm (b) — a mid-window jump would be a free escape from the damage window.
      -- The zone linkage is DERIVED from engagement_x/y (combat_encounter_zone), never stored:
      -- NULL means "not in a zone" and falls through to retreat — the fail-closed default.
      if v_enc.status = 'active' then
        declare
          v_rz_zone  uuid;
          v_rz_mode  text;
          v_rz_eng_x double precision;
          v_rz_eng_y double precision;
        begin
          v_rz_zone := public.combat_encounter_zone(v_enc.id);
          if v_rz_zone is not null
             and public.danger_zone_contains_point(v_rz_zone, v_t_x, v_t_y) then
            -- The fleet row, locked in this block's own order (encounter -> fleet).
            select f.location_mode into v_rz_mode
              from public.fleets f
             where f.id = v_enc.fleet_id and f.player_id = v_player
             for update;
            if v_rz_mode is distinct from 'space' then
              -- A fleet that is NOT parked in open space (a hunt sortie 'present' at its site) is
              -- REFUSED, typed: fleet_set_in_space nulls current_location_id, and whether that
              -- corrupts the settle for a 'present' fleet holding an active location_presence is
              -- UNVERIFIED. Refusing is the honest scope — this ships for ambush-born fights,
              -- which always park in open space (0301:1109). Returned BEFORE any write.
              return jsonb_build_object('ok', false, 'reason', 'reposition_requires_open_space');
            end if;
            select ce.engagement_x, ce.engagement_y into v_rz_eng_x, v_rz_eng_y
              from public.combat_encounters ce where ce.id = v_enc.id;
            -- THE THREE WRITES, all composing what already exists:
            -- 1. the fleet moves — fleet_set_in_space, the ONE writer of fleets.space_x/y and the
            --    SAME primitive the ambush park uses (0301:1109). Deliberately NO movement_create:
            --    a leg would put the fleet back to 'moving' (a state step 7 and the tick assume it
            --    is not in mid-fight) and would re-roll an ambush inside the zone it is already
            --    fighting in.
            perform public.fleet_set_in_space(v_enc.fleet_id, v_t_x, v_t_y);
            -- 2. the player formation TRANSLATES by (destination - engagement) — never re-seeded,
            --    so the 0301:749-757 ring survives by construction. Enemy rows are NOT touched:
            --    the distance opens and the tick's existing 'close' arm (0234:242-244) pursues.
            update public.combat_units
               set pos_x = pos_x + (v_t_x - v_rz_eng_x),
                   pos_y = pos_y + (v_t_y - v_rz_eng_y),
                   updated_at = v_now
             where encounter_id = v_enc.id and side = 'player';
            -- 3. the engagement anchor RESTAMPS. Mandatory: the tick reads it fresh each pass
            --    (0299:477-478) and uses it for every later wave spawn (0299:713-722, :768-782)
            --    and both retreat-leg origins (0299:613, :616) — without this, wave 2 spawns at
            --    the abandoned point and a later retreat departs from where the fleet is not.
            update public.combat_encounters
               set engagement_x = v_t_x, engagement_y = v_t_y, updated_at = v_now
             where id = v_enc.id;
            return jsonb_build_object(
              'ok', true,
              'order_outcome', 'repositioned',
              'outcome', 'repositioned',
              'reason', 'repositioned',
              'group_id', v_group,
              'fleet_id', v_enc.fleet_id,
              'encounter_id', v_enc.id,
              'presence_id', v_enc.presence_id,
              'zone_id', v_rz_zone,
              'member_count', v_member_n,
              'destination_location_id', p_location_id,
              'destination_x', v_t_x,
              'destination_y', v_t_y);
          end if;
        end;
      end if;
      -- ── end 0311 — the head continues verbatim from here ───────────────────────────────────────`;

const HUNKS = [
  [1, 'command_ship_group_go', G_GUARD, G_GUARD_NEW],
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

// Comment-stripping idiom proven by 0305/0306/0308 against this database's settings.
const STRIP = `regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g')`;

const sql = `-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0311 — REPOSITION INSIDE THE FIGHT'S OWN ZONE
--        (an in-zone re-order is a tactical move; only leaving the zone breaks combat)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- THE OWNER'S DIRECTIVE, VERBATIM: "there should only be breaking combat when it is outside the
-- zone. When i am inside the zone and moving(redirecting), it should just move without breaking
-- combat, and battles being continued." And on why: "yes repositioning is a tacticle move."
--
-- TODAY: command_ship_group_go step 8 (head 0301:1706-1744) treats EVERY move order against an
-- 'active' encounter as a retreat — it writes fleets.retreat_target_* and calls
-- presence_request_leave, the sole retreat authority. There is no notion of WHERE the order points:
-- redirecting inside the fight and fleeing to another system are the same action.
--
-- THE RULE THIS MIGRATION INSTALLS: reposition iff the ordered destination is STRICTLY INSIDE the
-- same active danger zone that anchors the encounter's engagement point. Everything else retreats,
-- byte-identical to today.
--
-- ── THE ZONE LINKAGE IS DERIVED, NEVER STORED ────────────────────────────────────────────────────
-- combat_encounters has no zone column, location_presence.zone_id is the LEGACY zones table, and
-- pirate_intercepts.encounter_id is NULL for every telegraphed fight (0301:1167-1178 records it
-- only when the encounter opens inline; combat_telegraph_enabled is lit, 0300:76). A stored
-- danger_zone_id would need three writers and could disagree with the geometry — so the linkage is
-- derived from combat_encounters.engagement_x/engagement_y, which 0293:180-186 declares THE
-- authority for where a fight physically is. A zone drawn AFTER a fight opened therefore governs it
-- too — the linkage is live geometry, not a snapshot.
--
-- ── TWO NEW AUTHORITIES ──────────────────────────────────────────────────────────────────────────
--   1. public.danger_zone_contains_point(zone, x, y) — "is this point strictly inside this active
--      zone?" COMPOSED from pirate_intercept_leg_entry's degenerate zero-length-leg arm
--      (0301:337-340), which already carries the ST_MakeValid/ST_CollectionExtract/ST_UnaryUnion
--      repair (0301:317) that makes containment defined on self-intersecting owner-drawn polygons.
--      No geometry re-implemented. STRICT on purpose: a reposition destination must be genuinely
--      inside the zone — a boundary graze is not "inside".
--   2. public.combat_encounter_zone(encounter) — which active zone anchors this fight? Resolves the
--      zone whose CLOSURE the engagement point touches within 1e-6 world units (ST_DWithin), NULL
--      when engagement_x is NULL or no zone qualifies — and NULL means "not in a zone" => retreat
--      => today's behaviour, the fail-closed default protecting existing players.
--
--      ★ THE ONE DELIBERATE DEVIATION FROM THE DESIGN PACKET, AND WHY: the packet specified strict
--      containment (composing authority 1) for this resolver too. But the primary case this slice
--      ships for — the ambush-born fight — anchors its engagement point AT THE ZONE ENTRY POINT
--      (the resolver parks the fleet at entry_x/y, 0301:1109, and combat_create_encounter reads
--      that position; scripts/danger-combat-proof.sql's ENGAGEMENT block pins engagement == the
--      recorded entry point). An entry point is BY CONSTRUCTION a point on the zone boundary
--      (pirate_intercept_leg_entry returns the first boundary-crossing of the leg), where strict
--      ST_Contains answers FALSE — modulo one ulp of interpolation noise in either direction. The
--      literal composition would therefore have resolved NULL for exactly the fights the owner's
--      directive is about, shipping the feature dead, nondeterministically. Closure-with-epsilon
--      (distance to the polygon <= 1e-6 — interior distance is 0, boundary distance is 0, one ulp
--      outside is ~1e-13) is deterministic on both sides of that boundary and is gameplay-
--      indistinguishable from containment (1e-6 world units on a ±10000 world). The raw-boundary
--      idiom follows the deployed prefilter at 0301:414-415 (ST_Intersects on z.boundary); distance
--      is not a topology predicate and does not need the validity repair.
--
--      OVERLAPPING ZONES: two active zones can contain one point and danger_zones has NO unique key
--      on location_id. Tie-break deterministically: ST_Area(z.boundary) asc, z.id asc — the
--      tightest zone wins; a nondeterministic predicate is not acceptable.
--
-- ── WHERE THE BRANCH SITS (one hunk, located by exact deployed text, never retyped) ──────────────
-- Inside step 8's "if v_enc.id is not null" block, AFTER the settling-race guard (0301:1706-1710)
-- and BEFORE the destination write (0301:1715). Only when v_enc.status = 'active'; a 'retreating'
-- encounter falls to arm (b) untouched — a mid-window jump would be a free escape from the damage
-- window. A fleet whose location_mode is not 'space' is REFUSED typed
-- ('reposition_requires_open_space'), never silently retreated: fleet_set_in_space nulls
-- current_location_id and its interaction with a live 'present' location_presence is unverified —
-- refusing is the safe, honest scope, and the client maps the reason to player copy.
--
-- ── WHAT MOVES (three writes, all composing existing primitives) ─────────────────────────────────
--   fleets.space_x/y      — via fleet_set_in_space (0231:1146), the ONE writer, the ambush park's
--                           own primitive. NO fleet_movements leg (see the branch comment).
--   combat_units pos      — side='player' rows TRANSLATE by (destination - engagement); never
--                           re-seeded, so the 0301:749-757 ring formation survives by construction.
--                           Enemy rows untouched: the distance opens and the tick's existing
--                           'close' arm (0234:242-244) pursues — deployed behaviour, not new code.
--   combat_encounters     — engagement_x/y RESTAMP to the destination. The tick reads the anchor
--                           fresh each pass (0299:477-478); later waves (0299:713-722, :768-782)
--                           and both retreat-leg origins (0299:613, :616) follow the fight.
--
-- ── A 0301 INVARIANT, DELIBERATELY SUPERSEDED ────────────────────────────────────────────────────
-- 0301's self-assert (E) (0301:2623-2625) required command_ship_group_go's body to be free of
-- fleet_set_in_space — that pinned the removal of the ORDER-TIME ambush park (an order that starts
-- a journey must not move the fleet). That assert ran at 0301's own apply time and still passes
-- there in every fresh chain. The reposition arm is reachable ONLY against a live encounter — the
-- order path that mints a leg still never parks, which scripts/danger-combat-proof.sql's ORDER
-- block keeps proving behaviourally on every run.
--
-- ── EVERY CONSUMER OF WHAT CHANGED, AND THE IMPACT ───────────────────────────────────────────────
--   command_ship_group_go      — the one rewritten function; retreat arms byte-identical.
--   command_ship_group_go_route— leg 1 composes the mover; a mid-combat route order hits the same
--                                branch and may now answer 'repositioned' (ok:true, no leg) — its
--                                client reader (readFleetOrderOutcome) treats an unknown outcome as
--                                movement-started copy only after fleetRetreatOutcomeMessage, which
--                                gains the new outcome in the same slice (never ship half).
--   command_ship_group_dock    — dark-path (timed_docking dark) submits through the mover with a
--                                PORT target; a port strictly inside the fight's zone now
--                                repositions to the port's coordinate instead of arming a retreat —
--                                the fleet stays in the fight, which is the owner's rule; docking
--                                during a fight remains refused by the dock verb itself.
--   command_ship_group_stop    — 0305's brake composes presence_request_leave directly, NOT this
--                                branch: Stop during a fight still retreats. Untouched.
--   process_combat_ticks       — 0310 (in flight on another branch) touches it; this migration does
--                                NOT touch it anywhere, so the two slices cannot conflict. The tick
--                                is a pure reader of the restamped anchor.
--   presence_request_leave     — stays the sole retreat authority; the reposition arm never calls
--                                it and never writes retreat/presence state.
--   fleet_set_in_space         — stays the sole writer of fleets.space_x/y; composed, not copied.
--   client                     — fleetRetreatOutcomeMessage gains 'repositioned'; teamReasonMessage
--                                gains 'reposition_requires_open_space'. Same slice.
--
-- ── BLAST RADIUS ON LIVE PLAYERS ─────────────────────────────────────────────────────────────────
--   - No data written at deploy time: no backfill, no flag, no schema change. DDL = two CREATE
--     FUNCTIONs + one CREATE OR REPLACE of the mover (row lock in pg_proc, no table lock).
--   - Which live fights change behaviour: only an order (a) against an ACTIVE encounter (b) whose
--     engagement point lies in an active danger zone (c) whose destination is strictly inside that
--     same zone (d) from a fleet parked in open space — i.e. exactly the ambush-born fight
--     redirected within its zone. Every other combination — outside destination, no zone,
--     retreating fight, docked/present fleet, no fight at all — is byte-identical to 0301+0305+0307
--     (the retreat arms and the whole no-combat path are untouched text).
--   - The reposition is INSTANT (the ambush park's own primitive). Enemies keep firing through the
--     jump: lock-on, spawn spread and the weapon-cooldown fix are slices 0312/0313 and a separate
--     bug — deliberately NOT here.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed command_ship_group_go body with the 0311 hunk reverted (the guard text at
-- 0301:1706-1710), then:
--   drop function public.combat_encounter_zone(uuid);
--   drop function public.danger_zone_contains_point(uuid, double precision, double precision);
-- Nothing else here writes state.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
--   (a) the two authorities exist with the right shape (STABLE, SECURITY DEFINER, pinned path)
--   (b) ACLs: neither authority is client-callable; service_role may execute
--   (c) zone resolver: deterministic tie-break pinned; fail-closed NULL/false smoke on empty input
--   (d) the destination test COMPOSES the geometry leaf (no second repair chain)
--   (e) mover: the reposition branch is present and composed (resolver + containment + the park)
--   (f) mover ORDER: guard -> reposition -> destination write -> retreat verbs
--   (g) mover: retreat arms intact, exactly one retreat-destination write, refusal typed
--   (h) mover: translate + restamp present, player-side scoped
--   (i) mover: the branch gates on 'active' exactly like arm (a) — two gates, no more
--   (j) mover: no inline geometry (the authorities stay the only geometry readers)
--   (k) metadata parity: the mover changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) ─────────────────────────────────────────────────────────────────
do $pre$
declare v_missing text;
begin
  if to_regclass('public.danger_zones') is null
     or to_regclass('public.combat_encounters') is null
     or to_regclass('public.combat_units') is null
     or to_regclass('public.fleets') is null then
    raise exception '0311 PRECONDITION FAIL: a table this migration composes over is absent';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_encounters'
                    and column_name in ('engagement_x', 'engagement_y')
                 having count(*) = 2) then
    raise exception '0311 PRECONDITION FAIL: combat_encounters lacks engagement_x/y (0293)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_units'
                    and column_name in ('pos_x', 'pos_y', 'side')
                 having count(*) = 3) then
    raise exception '0311 PRECONDITION FAIL: combat_units lacks pos_x/pos_y/side (0234)';
  end if;
  select string_agg(f, ', ') into v_missing
    from unnest(array[
      'command_ship_group_go',
      'pirate_intercept_leg_entry',
      'fleet_set_in_space',
      'presence_request_leave'
    ]) as f
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f);
  if v_missing is not null then
    raise exception '0311 PRECONDITION FAIL: missing function(s): %', v_missing;
  end if;
end $pre$;

-- ── 1. THE CONTAINMENT AUTHORITY ─────────────────────────────────────────────────────────────────
-- STRICT interior test, COMPOSED from the deployed geometry leaf's degenerate zero-length-leg arm
-- (0301:337-340) — including its validity repair. Zero new geometry.
create or replace function public.danger_zone_contains_point(
  p_zone uuid,
  p_x    double precision,
  p_y    double precision
) returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select exists (
    select 1
      from public.danger_zones z
     cross join lateral public.pirate_intercept_leg_entry(
       ST_MakeLine(ST_MakePoint(p_x, p_y), ST_MakePoint(p_x, p_y)), z.boundary) e
     where z.id = p_zone
       and z.status = 'active'
  );
$fn$;

comment on function public.danger_zone_contains_point(uuid, double precision, double precision) is
  'THE one answer to "is this point strictly inside this ACTIVE danger zone?" (0311). Composes '
  'pirate_intercept_leg_entry''s degenerate zero-length-leg arm — the deployed repair + strict '
  'containment — never a second geometry implementation. NULL/garbage input, an inactive or '
  'missing zone, and a boundary graze all answer false: fail closed. Composed by '
  'command_ship_group_go''s reposition arm for the ORDERED DESTINATION.';

-- ── 2. THE ZONE-OF-THE-FIGHT AUTHORITY ───────────────────────────────────────────────────────────
-- See the header for why this one is closure-with-epsilon rather than strict: an ambush-born
-- fight's engagement point IS a zone-boundary point, where strictness is a coin flip.
create or replace function public.combat_encounter_zone(p_encounter uuid)
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select z.id
    from public.combat_encounters ce
    join public.danger_zones z
      on z.status = 'active'
     and ST_DWithin(z.boundary, ST_MakePoint(ce.engagement_x, ce.engagement_y), 1e-6)
   where ce.id = p_encounter
     and ce.engagement_x is not null
     and ce.engagement_y is not null
   order by ST_Area(z.boundary) asc, z.id asc
   limit 1;
$fn$;

comment on function public.combat_encounter_zone(uuid) is
  'THE one answer to "which active danger zone anchors this fight?" (0311). DERIVED from '
  'combat_encounters.engagement_x/y — the 0293 position authority — never stored. Closure test '
  'with a 1e-6 tolerance because an ambush anchors its fight ON the zone boundary (the entry '
  'point, 0301:1109), where strict containment is undefined to one ulp. NULL when the engagement '
  'point is unstamped or no active zone holds it — and NULL means "not in a zone", so the mover '
  'falls through to the retreat arms: fail closed. Overlaps tie-break tightest-first '
  '(ST_Area asc, id asc), deterministically.';

-- ACLs: internal leaves — the composer is a security-definer engine function. Explicitly revoked
-- rather than merely un-granted (the 0254 prod grant-drift lesson). Neither takes the acting player
-- as an argument (the 0309 lesson).
revoke execute on function public.danger_zone_contains_point(uuid, double precision, double precision) from public, anon, authenticated;
revoke execute on function public.combat_encounter_zone(uuid) from public, anon, authenticated;
grant execute on function public.danger_zone_contains_point(uuid, double precision, double precision) to service_role;
grant execute on function public.combat_encounter_zone(uuid) to service_role;

-- ── 3. CAPTURE METADATA BEFORE THE REWRITE (for parity check k) ──────────────────────────────────
create temp table _0311_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0311_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname = 'command_ship_group_go';

-- ── 4. REWRITE THE HUNK (located by exact deployed text, never retyped) ──────────────────────────
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
      raise exception '0311 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0311 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0311 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0311 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 1 then
    raise exception '0311 REWRITE FAIL: rewrote % site(s), expected 1', v_done;
  end if;
  raise notice '0311: the mover now repositions inside the fight''s own zone; everything else retreats, byte-identical';
end $rewrite$;

-- ── 5. SELF-ASSERTS — one DO block per check; every probe strips comments first ─────────────────

-- (a) the two authorities exist with the right shape
do $a$
begin
  if to_regprocedure('public.danger_zone_contains_point(uuid, double precision, double precision)') is null
     or to_regprocedure('public.combat_encounter_zone(uuid)') is null then
    raise exception '0311 ASSERT (a) FAIL: an authority is missing';
  end if;
  if (select provolatile from pg_proc where oid = 'public.danger_zone_contains_point(uuid, double precision, double precision)'::regprocedure) <> 's'
     or (select prosecdef from pg_proc where oid = 'public.danger_zone_contains_point(uuid, double precision, double precision)'::regprocedure) is not true
     or (select provolatile from pg_proc where oid = 'public.combat_encounter_zone(uuid)'::regprocedure) <> 's'
     or (select prosecdef from pg_proc where oid = 'public.combat_encounter_zone(uuid)'::regprocedure) is not true then
    raise exception '0311 ASSERT (a) FAIL: both authorities must be STABLE SECURITY DEFINER';
  end if;
  if not exists (select 1 from pg_proc where oid = 'public.combat_encounter_zone(uuid)'::regprocedure
                    and 'search_path=public' = any (proconfig))
     or not exists (select 1 from pg_proc where oid = 'public.danger_zone_contains_point(uuid, double precision, double precision)'::regprocedure
                    and 'search_path=public' = any (proconfig)) then
    raise exception '0311 ASSERT (a) FAIL: an authority lost its pinned search_path';
  end if;
end $a$;

-- (b) ACLs: neither authority is client-callable; service_role may execute
do $b$
declare v_n integer;
begin
  select count(*) into v_n
    from (values ('public.danger_zone_contains_point(uuid, double precision, double precision)'),
                 ('public.combat_encounter_zone(uuid)')) as t(sig)
   where has_function_privilege('authenticated', t.sig, 'execute')
      or has_function_privilege('anon', t.sig, 'execute');
  if v_n > 0 then
    raise exception '0311 ASSERT (b) FAIL: % authority function(s) are client-callable', v_n;
  end if;
  select count(*) into v_n
    from (values ('public.danger_zone_contains_point(uuid, double precision, double precision)'),
                 ('public.combat_encounter_zone(uuid)')) as t(sig)
   where not has_function_privilege('service_role', t.sig, 'execute');
  if v_n > 0 then
    raise exception '0311 ASSERT (b) FAIL: % authority function(s) lack the service_role grant', v_n;
  end if;
end $b$;

-- (c) zone resolver: deterministic tie-break pinned; fail-closed smoke on empty input
do $c$
declare v_code text; v_zone uuid; v_in boolean;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_encounter_zone';
  if position('ST_Area' in v_code) = 0 or position('order by' in v_code) = 0
     or position('limit 1' in v_code) = 0 then
    raise exception '0311 ASSERT (c) FAIL: the tie-break (ST_Area asc, id asc, limit 1) is gone — overlapping zones would resolve nondeterministically';
  end if;
  if position('engagement_x is not null' in v_code) = 0 then
    raise exception '0311 ASSERT (c) FAIL: the unstamped-engagement guard is gone';
  end if;
  -- read-only smoke, safe on any database including production:
  v_zone := public.combat_encounter_zone('00000000-0000-4311-8311-000000000311'::uuid);
  if v_zone is not null then
    raise exception '0311 ASSERT (c) FAIL: an encounter that does not exist resolved zone % (want NULL — fail closed)', v_zone;
  end if;
  v_in := public.danger_zone_contains_point('00000000-0000-4311-8311-000000000311'::uuid, 0, 0);
  if v_in is distinct from false then
    raise exception '0311 ASSERT (c) FAIL: a zone that does not exist answered % (want false — fail closed)', v_in;
  end if;
end $c$;

-- (d) the destination test COMPOSES the geometry leaf — no second repair chain anywhere new
do $d$
declare v_code text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'danger_zone_contains_point';
  if position('pirate_intercept_leg_entry' in v_code) = 0 then
    raise exception '0311 ASSERT (d) FAIL: the containment test does not compose the geometry leaf';
  end if;
  if position('ST_MakeValid' in v_code) > 0 or position('ST_Contains' in v_code) > 0 then
    raise exception '0311 ASSERT (d) FAIL: the containment test re-implements the repair/containment — a second geometry authority';
  end if;
  if position('status = ''active''' in v_code) = 0 then
    raise exception '0311 ASSERT (d) FAIL: the containment test lost its active-zone scope';
  end if;
end $d$;

-- (e) mover: the reposition branch is present and composed
do $e$
declare v_code text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('combat_encounter_zone(v_enc.id)' in v_code) = 0
     or position('danger_zone_contains_point(v_rz_zone, v_t_x, v_t_y)' in v_code) = 0 then
    raise exception '0311 ASSERT (e) FAIL: the mover does not compose the two zone authorities';
  end if;
  if position('fleet_set_in_space(v_enc.fleet_id, v_t_x, v_t_y)' in v_code) = 0 then
    raise exception '0311 ASSERT (e) FAIL: the reposition does not park through the one fleets.space writer';
  end if;
  if position('''order_outcome'', ''repositioned''' in v_code) = 0 then
    raise exception '0311 ASSERT (e) FAIL: the reposition envelope is missing';
  end if;
  -- the mover's ONE movement_create is the ordinary-move path (0301's WRITES section) and the
  -- reposition return must sit strictly BEFORE it — a reposition never mints a leg.
  if position('''order_outcome'', ''repositioned''' in v_code) > position('movement_create' in v_code) then
    raise exception '0311 ASSERT (e) FAIL: the reposition return does not precede the leg minter — a reposition must never mint a leg';
  end if;
end $e$;

-- (f) mover ORDER: settling-race guard -> reposition -> destination write -> retreat verb
do $f$
declare v_code text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('movement_settled_retry' in v_code) = 0
     or position('movement_settled_retry' in v_code) > position('combat_encounter_zone(v_enc.id)' in v_code) then
    raise exception '0311 ASSERT (f) FAIL: the reposition branch does not sit AFTER the settling-race guard';
  end if;
  if position('combat_encounter_zone(v_enc.id)' in v_code) > position('retreat_target_location_id = p_location_id' in v_code) then
    raise exception '0311 ASSERT (f) FAIL: the reposition branch does not sit BEFORE the retreat-destination write — a reposition would leave a stored destination behind';
  end if;
  if position('''order_outcome'', ''repositioned''' in v_code) > position('presence_request_leave(v_enc.presence_id)' in v_code) then
    raise exception '0311 ASSERT (f) FAIL: the reposition return does not precede the retreat verb';
  end if;
end $f$;

-- (g) mover: retreat arms intact, exactly one retreat-destination write, refusal typed
do $g$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('presence_request_leave(v_enc.presence_id)' in v_code) = 0
     or position('''order_outcome'', ''retreat_started''' in v_code) = 0
     or position('''order_outcome'', ''retreat_destination_updated''' in v_code) = 0 then
    raise exception '0311 ASSERT (g) FAIL: a retreat arm lost a piece — the fall-through is no longer today''s behaviour';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'retreat_target_location_id = p_location_id', '')))
         / length('retreat_target_location_id = p_location_id');
  if v_n <> 1 then
    raise exception '0311 ASSERT (g) FAIL: % retreat-destination writes (want exactly the one 0298 update — the reposition arm must never write retreat_target_*)', v_n;
  end if;
  if position('reposition_requires_open_space' in v_code) = 0 then
    raise exception '0311 ASSERT (g) FAIL: the non-space refusal is not typed';
  end if;
end $g$;

-- (h) mover: translate + restamp present, player-side scoped
do $h$
declare v_code text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('pos_x = pos_x + (v_t_x - v_rz_eng_x)' in v_code) = 0
     or position('pos_y = pos_y + (v_t_y - v_rz_eng_y)' in v_code) = 0 then
    raise exception '0311 ASSERT (h) FAIL: the formation translate is gone (or re-seeds instead of translating)';
  end if;
  if position('side = ''player''' in v_code) = 0 then
    raise exception '0311 ASSERT (h) FAIL: the translate is not scoped to the player side — enemy rows must not move';
  end if;
  if position('set engagement_x = v_t_x' in v_code) = 0 then
    raise exception '0311 ASSERT (h) FAIL: the engagement restamp is gone — wave 2 would spawn at the abandoned point';
  end if;
end $h$;

-- (i) mover: the branch gates on 'active' exactly like arm (a) — two single-line gates, no more
do $i$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  v_n := (length(v_code) - length(replace(v_code, 'if v_enc.status = ''active'' then', '')))
         / length('if v_enc.status = ''active'' then');
  if v_n <> 2 then
    raise exception '0311 ASSERT (i) FAIL: % single-line active gates (want 2: the reposition gate + retreat arm a) — a ''retreating'' fight must never reposition', v_n;
  end if;
end $i$;

-- (j) mover: no inline geometry — the two authorities stay the only geometry readers
do $j$
declare v_code text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('ST_' in v_code) > 0 then
    raise exception '0311 ASSERT (j) FAIL: the mover carries inline PostGIS — geometry must live only in the authorities';
  end if;
end $j$;

-- (k) metadata parity: the mover changed body and NOTHING else
do $k$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0311_before loop
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
      raise exception '0311 ASSERT (k) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0311 ASSERT (k) FAIL: public.% body is byte-identical — the hunk did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0311 ASSERT (k) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0311 SELF-ASSERT PASS: in-zone re-orders reposition the fight; everything else retreats, byte-identical';
end $k$;

commit;
`;

if (sql.includes('\r')) {
  throw new Error('generated 0311 carries a CR — the rewrite hunk would never match the deployed body');
}

const check = process.argv.includes('--check');
if (check) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8');
  } catch {
    console.error('0311 CHECK FAIL: migration file is missing — run the generator');
    process.exit(1);
  }
  if (onDisk.replace(/\r\n/g, '\n') !== sql) {
    console.error('0311 CHECK FAIL: the migration on disk is not what the slice generates.');
    console.error('Either the source migration drifted or the file was hand-edited. Re-run the generator.');
    process.exit(1);
  }
  console.log('0311 CHECK OK: migration matches the slice taken from 0301.');
} else {
  writeFileSync(OUT, sql);
  console.log(`0311 written: ${OUT}`);
  console.log(`  ${HUNKS.length} hunk sliced from 0301 (nothing retyped)`);
}
