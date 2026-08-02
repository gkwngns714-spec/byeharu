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
      -- STRICTLY INSIDE an active danger zone that ALSO holds this encounter's engagement anchor
      -- MOVES the fleet, and the fight moves with it — no retreat armed, no destination stored, no
      -- window, no leg. Everything else falls through to the (a)/(b) retreat arms below, byte-
      -- identical. The admission QUANTIFIES over every anchor-holding zone — a PURE RELAXATION of
      -- the first cut's area tie-break, whose chosen zone could VETO a destination genuinely
      -- inside another anchor-holding zone (adversarial review's finding; every grant the old rule
      -- made is still a grant, since its winner is in the quantified set). Under overlap the
      -- admitting zone may differ from the one the ambush fired in — INTENDED, not prevented.
      -- Gated to encounter 'active': a 'retreating' fight may only update its stored destination
      -- in arm (b) — a mid-window jump would be a free escape from the damage window. False/NULL
      -- anywhere (unstamped anchor, no zone, boundary graze) falls through to retreat: fail closed.
      if v_enc.status = 'active' then
        declare
          v_rz_admits boolean := false;
          v_rz_mode   text;
          v_rz_eng_x  double precision;
          v_rz_eng_y  double precision;
        begin
          -- FENCED: this RPC never raises at its boundary (the 0301 posture), and the admission
          -- puts a PostGIS read under every mid-combat order — including site fights that
          -- previously touched no geometry. A geometry failure must never break the retreat:
          -- it reads as "not an in-zone move" and falls through.
          begin
            v_rz_admits := public.combat_encounter_zone_admits_point(v_enc.id, v_t_x, v_t_y);
          exception when others then
            v_rz_admits := false;
          end;
          if v_rz_admits then
          -- The fleet row, locked in this block's own order (encounter -> fleet).
          select f.location_mode into v_rz_mode
            from public.fleets f
           where f.id = v_enc.fleet_id and f.player_id = v_player
           for update;
          if v_rz_mode = 'space' then
            select ce.engagement_x, ce.engagement_y into v_rz_eng_x, v_rz_eng_y
              from public.combat_encounters ce where ce.id = v_enc.id;
            -- THE THREE WRITES, all composing what already exists:
            -- 1. the fleet moves — fleet_set_in_space, the ONE writer of fleets.space_x/y and the
            --    SAME primitive the ambush park uses (0301:1109). Deliberately NO movement_create:
            --    a leg would put the fleet back to 'moving' (a state step 7 and the tick assume it
            --    is not in mid-fight) and would re-roll an ambush inside the zone it is already
            --    fighting in.
            perform public.fleet_set_in_space(v_enc.fleet_id, v_t_x, v_t_y);
            -- 2. the player formation TRANSLATES by (destination - engagement) through the ONE
            --    translation leaf — never re-seeded, so the 0301:749-757 ring survives by
            --    construction. Enemy rows are NOT touched (see the header's blast-radius note on
            --    what that means at production geometry).
            perform public.combat_translate_player_formation(v_enc.id, v_t_x - v_rz_eng_x, v_t_y - v_rz_eng_y);
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
              'member_count', v_member_n,
              'destination_location_id', p_location_id,
              'destination_x', v_t_x,
              'destination_y', v_t_y);
          end if;
          -- NOT parked in open space (a hunt fight 'present' at its site): fall THROUGH to the
          -- retreat arms below — today's behaviour EXACTLY, byte-for-byte from here down.
          -- Reposition stays open-space-only because fleet_set_in_space nulls
          -- current_location_id, and its interaction with a live 'present' location_presence is
          -- UNVERIFIED. The first cut REFUSED here instead, and adversarial review showed the
          -- refusal regressed a capability every site fight has today (an in-zone-destination
          -- retreat order). Falling through takes nothing away from anyone.
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
-- THE RULE THIS MIGRATION INSTALLS: reposition iff there EXISTS an active danger zone that (a)
-- holds the encounter's engagement anchor and (b) strictly contains the ordered destination.
-- Everything else retreats, byte-identical to today.
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
-- ── THREE NEW AUTHORITIES ────────────────────────────────────────────────────────────────────────
--   1. public.danger_zone_contains_point(zone, x, y) — "is this point strictly inside this active
--      zone?" COMPOSED from pirate_intercept_leg_entry's degenerate zero-length-leg arm
--      (0301:337-340), which already carries the ST_MakeValid/ST_CollectionExtract/ST_UnaryUnion
--      repair (0301:317) that makes containment defined on self-intersecting owner-drawn polygons.
--      No geometry re-implemented. STRICT on purpose: a reposition destination must be genuinely
--      inside the zone — a boundary graze is not "inside".
--   2. public.combat_encounter_zone_admits_point(encounter, x, y) — "is this an in-zone move for
--      this fight?" TRUE iff some active zone holds the engagement anchor under a closure test
--      (ST_DWithin, 1e-6) AND strictly contains the point (composing authority 1). It QUANTIFIES —
--      it never resolves "the" zone. The first cut returned one zone chosen by an
--      ST_Area-ascending tie-break; adversarial review proved the CHOICE could VETO a destination
--      genuinely inside an anchor-holding zone (the smallest holder won and was tested alone).
--      The existential is a PURE RELAXATION of that rule: the tie-break winner is itself in the
--      quantified set, so GRANT_old implies GRANT_new unconditionally — only the veto class is
--      removed, and there is no choice left to get wrong. Under overlap the admitting zone may be
--      a DIFFERENT anchor-holding zone than the one the ambush fired in, and moving between
--      overlapping zones that both hold the fight is INTENDED — this rule does not (and by design
--      does not try to) fence the fleet into the single polygon the ambush rolled in. FALSE when
--      the anchor is unstamped or nothing qualifies — and false means "not an in-zone move" =>
--      retreat => today's behaviour, the fail-closed default protecting existing players.
--
--      ★ WHY THE ANCHOR ARM IS CLOSURE-WITH-EPSILON, NOT STRICT (the one deviation from the design
--      packet, verified and upheld by adversarial review): the primary case this slice ships for —
--      the ambush-born fight — anchors its engagement point AT THE ZONE ENTRY POINT (the resolver
--      parks the fleet at entry_x/y, 0301:1109, and combat_create_encounter reads that position;
--      scripts/danger-combat-proof.sql's ENGAGEMENT block pins engagement == the recorded entry
--      point). An entry point is BY CONSTRUCTION a point on the zone boundary
--      (pirate_intercept_leg_entry returns the first boundary-crossing of the leg), where strict
--      ST_Contains answers FALSE — modulo one ulp of interpolation noise in either direction. The
--      literal strict composition would have answered false for exactly the fights the owner's
--      directive is about, shipping the feature dead, nondeterministically. Closure-with-epsilon
--      (distance to the polygon <= 1e-6 — interior 0, boundary 0, one ulp outside ~1e-13) is
--      deterministic on both sides of that boundary and gameplay-indistinguishable from
--      containment (1e-6 world units on a ±10000 world). A player has no lever to place an anchor
--      1e-6 outside a zone (review verified this too). The raw-boundary idiom follows the deployed
--      prefilter at 0301:414-415; distance is not a topology predicate and needs no validity repair.
--   3. public.combat_translate_player_formation(encounter, dx, dy) — THE one rigid translation of
--      a fight's player formation (side='player' only; enemies never move). Extracted so
--      combat_units.pos_x/pos_y keeps a countable writer set: the builder seeds (0301:749-757),
--      the tick moves/spawns (0234/0299), and this leaf translates. There is NO other live
--      translate site to re-point onto it: 0294's ambush translate lived in
--      pirate_intercept_evaluate_leg, which 0301:2457 DROPPED — the resolver that replaced it
--      parks the fleet BEFORE the encounter exists and never translates (0301:1101-1109).
--
-- ── WHERE THE BRANCH SITS (one hunk, located by exact deployed text, never retyped) ──────────────
-- Inside step 8's "if v_enc.id is not null" block, AFTER the settling-race guard (0301:1706-1710)
-- and BEFORE the destination write (0301:1715). Only when v_enc.status = 'active'; a 'retreating'
-- encounter falls to arm (b) untouched — a mid-window jump would be a free escape from the damage
-- window. A fleet whose location_mode is not 'space' FALLS THROUGH to the retreat arms — today's
-- behaviour exactly. (The first cut refused typed here; adversarial review showed that REGRESSED a
-- real capability: every hunt fight sits 'present' at a site that carries a circle zone, so an
-- in-zone-destination retreat order — legal today — would have started answering a refusal.
-- Reposition stays open-space-only because fleet_set_in_space nulls current_location_id and its
-- interaction with a live 'present' location_presence is unverified; falling through keeps the
-- scope without taking anything away.)
--
-- ── WHAT MOVES (three writes, all composing existing primitives) ─────────────────────────────────
--   fleets.space_x/y      — via fleet_set_in_space (0231:1146), the ONE writer, the ambush park's
--                           own primitive. NO fleet_movements leg (see the branch comment).
--   combat_units pos      — side='player' rows TRANSLATE by (destination - engagement) through
--                           combat_translate_player_formation; never re-seeded, so the
--                           0301:749-757 ring formation survives by construction.
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
--   command_ship_group_go_route— ★ NAMED NON-GOAL, NOT COVERED BY THIS SLICE. Leg 1 composes the
--                                mover (0301:2298), then queues legs 2..N into fleet_route_legs
--                                (0301:2308-2327) EVEN when leg 1 came back as a combat outcome
--                                with no movement — and process_pirate_route_legs (0301:2364-2372)
--                                advances any idle/space fleet with queued legs, with NO encounter
--                                guard. That seam is PRE-EXISTING (the retreat arm has the same
--                                shape today: a mid-combat route order queues legs while the fleet
--                                sits in its retreat window) and 0311 CHEAPENS it on the new arm:
--                                pre-0311 every such escape ran with a retreat ARMED — presence
--                                retreating, the damage window charging — while a REPOSITIONED
--                                fleet's queued legs can be flown out by the route cron with the
--                                encounter fully 'active' and no window ever charged. The new arm
--                                is also NARROW, which is why deferring is tolerable: it needs
--                                waypoint[0] to land strictly inside an anchor-holding zone
--                                (today's live zones span ~29-79 world units), where the
--                                pre-existing retreat arm triggers on ANY mid-combat route order.
--                                Closing it needs its own slice (an encounter guard in the route
--                                cron, or queue abandonment in step 8) — deliberately not smuggled
--                                in here. The CLIENT half is honest now: PirateInterceptPanel
--                                composes routeCombatOutcomeMessage (the combat-copy authority
--                                named with leg 1's target), so a combat-time route order reports
--                                what actually happened instead of "fleet underway".
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
--   client                     — fleetRetreatOutcomeMessage gains 'repositioned';
--                                PirateInterceptPanel consults it. Same slice.
--
-- ── BLAST RADIUS ON LIVE PLAYERS ─────────────────────────────────────────────────────────────────
--   - No data written at deploy time: no backfill, no flag, no schema change. DDL = three CREATE
--     FUNCTIONs + one CREATE OR REPLACE of the mover (row locks in pg_proc, no table lock).
--   - Which live fights change behaviour: only an order (a) against an ACTIVE encounter (b) from a
--     fleet parked in open space (c) whose destination is strictly inside an active zone that also
--     holds the engagement anchor — i.e. exactly the ambush-born fight redirected within its zone.
--     A 'present'/docked fleet's orders reach the SAME outcomes as today (the branch reads and
--     falls through — identical envelope, identical writes; the only delta is the added zone
--     reads). Retreating fights, no-zone fights, outside destinations, no fight at all:
--     byte-identical to 0301+0305+0307.
--   - The reposition is INSTANT (the ambush park's own primitive). Enemy rows are NOT moved;
--     whether an enemy keeps firing after the jump depends on its weapon range against the jump
--     distance — the tick's existing 'close' arm (0234:242-244) pursues anything out of range.
--     THE CEILING AT TODAY'S PRODUCTION GEOMETRY (measured on production 2026-08-02 by the
--     coordinator, via the Management API against danger_zones where status='active'): the three
--     live zones span Snare 79.2x47, Reaver 35.1x31, Blackden 28.6x30 world units, against enemy
--     weapon range 120+ — NO in-zone reposition on today's zones can leave anyone's weapon range.
--     The mechanic is correct and currently cannot dodge fire — by geometry, not by defect; a
--     larger drawn zone changes that, a code change does not.
--     ★ THE OBSERVED SPANS DISAGREE WITH THE CHAIN-DERIVED BOUND, AND THAT IS A REAL PRODUCTION
--     FINDING (pre-existing; neither caused nor fixed by this slice). The chain materializes a
--     source='circle' boundary at 0.492x..1.77x of territory_radius (0296:11-12), and every live
--     zone's radius is 12 (0289:69-72) => maximum span ~42.5. Blackden (28.6) and Reaver (35.1)
--     comply; SNARE AT 79.2 IS ~1.9x THAT MAXIMUM — a hand-reshaped polygon still carrying
--     source='circle' (zone_update preserves source bit-for-bit; 0300 lit seeded_zone_edit_enabled
--     after 0296 deployed). Consequence the next reader needs: the next location_update touching
--     Snare's x/y or territory_radius calls danger_zone_rematerialize_for_location (0296:141),
--     which selects on source='circle' and will REGENERATE A RANDOM BLOB OVER THE OWNER'S SHAPE.
--     The largest zone in the game — the most permissive for repositioning — is also the one most
--     likely to be silently destroyed. Its fix is a provenance/source slice, not this one.
--   - Lock-on, enemy spawn spread and the weapon-cooldown fix are slices 0312/0313 and a separate
--     bug — deliberately NOT here.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed command_ship_group_go body with the 0311 hunk reverted (the guard text at
-- 0301:1706-1710), then:
--   drop function public.combat_encounter_zone_admits_point(uuid, double precision, double precision);
--   drop function public.danger_zone_contains_point(uuid, double precision, double precision);
--   drop function public.combat_translate_player_formation(uuid, double precision, double precision);
-- Nothing else here writes state.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
--   (a) the three authorities exist with the right shape (secdef, pinned path, right volatility)
--   (b) ACLs: no authority is client-callable; service_role may execute all three
--   (c) the admission QUANTIFIES: exists-shape, composes the containment leaf, and carries NO
--       zone-choosing machinery (no order by / ST_Area / limit); fail-closed smoke on empty input
--   (d) the destination test COMPOSES the geometry leaf (no second repair chain)
--   (e) mover: the reposition branch is present and composed (admission + park + translate leaf)
--   (f) mover ORDER: guard -> admission -> destination write -> retreat verbs
--   (g) mover: retreat arms intact, exactly one retreat-destination write, the retired refusal
--       token is ABSENT (site fights fall through, they are never refused)
--   (h) mover: never touches combat_units directly (the leaf does), restamp present; the leaf is
--       a pure translation scoped to the one encounter's player side
--   (i) mover: the admission is FENCED (a geometry failure falls through to retreat) and gated on
--       'active' (exactly one such branch); arm (a) keeps its own gate
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
  'combat_encounter_zone_admits_point for the ORDERED DESTINATION.';

-- ── 2. THE ADMISSION AUTHORITY ───────────────────────────────────────────────────────────────────
-- Quantified, never a choice — see the header for why there is no "the" zone and why the anchor
-- arm is closure-with-epsilon while the destination arm is strict.
create or replace function public.combat_encounter_zone_admits_point(
  p_encounter uuid,
  p_x         double precision,
  p_y         double precision
) returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select exists (
    select 1
      from public.combat_encounters ce
      join public.danger_zones z
        on z.status = 'active'
       and ST_DWithin(z.boundary, ST_MakePoint(ce.engagement_x, ce.engagement_y), 1e-6)
     where ce.id = p_encounter
       and ce.engagement_x is not null
       and ce.engagement_y is not null
       and public.danger_zone_contains_point(z.id, p_x, p_y)
  );
$fn$;

comment on function public.combat_encounter_zone_admits_point(uuid, double precision, double precision) is
  'THE one answer to "is this destination an in-zone move for this fight?" (0311): TRUE iff some '
  'active danger zone holds the encounter''s engagement anchor (closure test, 1e-6 — an ambush '
  'anchors its fight ON the zone boundary, 0301:1109, where strictness is undefined to one ulp) '
  'AND strictly contains the destination (composing danger_zone_contains_point). QUANTIFIED over '
  'every anchor-holding zone — never "the" zone: a pure relaxation of the first cut''s area '
  'tie-break, whose chosen zone could veto a genuinely in-zone destination; under overlap ANY '
  'anchor-holding zone may admit, by design. The linkage is DERIVED from engagement_x/y (the 0293 '
  'position authority), never stored. FALSE on an unstamped anchor or no qualifying zone — the '
  'mover then falls through to the retreat arms: fail closed.';

-- ── 3. THE TRANSLATION LEAF ──────────────────────────────────────────────────────────────────────
-- The ONE rigid translation of a fight's player formation. Enemy rows are never touched here.
-- No other live site to fold in: 0294's ambush translate died with pirate_intercept_evaluate_leg
-- (dropped 0301:2457).
create or replace function public.combat_translate_player_formation(
  p_encounter uuid,
  p_dx        double precision,
  p_dy        double precision
) returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_n integer;
begin
  if p_dx is null or p_dy is null then
    raise exception 'combat_translate_player_formation: delta required (encounter %)', p_encounter;
  end if;
  update public.combat_units
     set pos_x = pos_x + p_dx,
         pos_y = pos_y + p_dy,
         updated_at = now()
   where encounter_id = p_encounter
     and side = 'player';
  get diagnostics v_n = row_count;
  return v_n;
end $fn$;

comment on function public.combat_translate_player_formation(uuid, double precision, double precision) is
  'THE one rigid translation of a fight''s player formation (0311): every side=''player'' row of '
  'the encounter moves by exactly (dx, dy); enemy rows never move here (the tick''s close arm '
  'pursues instead). Translation, never re-seeding — the spawn ring survives by construction. '
  'Composed by command_ship_group_go''s reposition arm. combat_units.pos writers stay countable: '
  'the builder seeds, the tick moves/spawns, this leaf translates.';

-- ACLs: internal leaves — the composer is a security-definer engine function. Explicitly revoked
-- rather than merely un-granted (the 0254 prod grant-drift lesson). None takes the acting player
-- as an argument (the 0309 lesson).
revoke execute on function public.danger_zone_contains_point(uuid, double precision, double precision) from public, anon, authenticated;
revoke execute on function public.combat_encounter_zone_admits_point(uuid, double precision, double precision) from public, anon, authenticated;
revoke execute on function public.combat_translate_player_formation(uuid, double precision, double precision) from public, anon, authenticated;
grant execute on function public.danger_zone_contains_point(uuid, double precision, double precision) to service_role;
grant execute on function public.combat_encounter_zone_admits_point(uuid, double precision, double precision) to service_role;
grant execute on function public.combat_translate_player_formation(uuid, double precision, double precision) to service_role;

-- ── 4. CAPTURE METADATA BEFORE THE REWRITE (for parity check k) ──────────────────────────────────
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

-- ── 5. REWRITE THE HUNK (located by exact deployed text, never retyped) ──────────────────────────
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

-- ── 6. SELF-ASSERTS — one DO block per check; every probe strips comments first ─────────────────

-- (a) the three authorities exist with the right shape
do $a$
begin
  if to_regprocedure('public.danger_zone_contains_point(uuid, double precision, double precision)') is null
     or to_regprocedure('public.combat_encounter_zone_admits_point(uuid, double precision, double precision)') is null
     or to_regprocedure('public.combat_translate_player_formation(uuid, double precision, double precision)') is null then
    raise exception '0311 ASSERT (a) FAIL: an authority is missing';
  end if;
  if (select provolatile from pg_proc where oid = 'public.danger_zone_contains_point(uuid, double precision, double precision)'::regprocedure) <> 's'
     or (select provolatile from pg_proc where oid = 'public.combat_encounter_zone_admits_point(uuid, double precision, double precision)'::regprocedure) <> 's'
     or (select provolatile from pg_proc where oid = 'public.combat_translate_player_formation(uuid, double precision, double precision)'::regprocedure) <> 'v' then
    raise exception '0311 ASSERT (a) FAIL: wrong volatility — the two reads are STABLE, the translate is VOLATILE';
  end if;
  if exists (select 1 from pg_proc
              where oid in ('public.danger_zone_contains_point(uuid, double precision, double precision)'::regprocedure,
                            'public.combat_encounter_zone_admits_point(uuid, double precision, double precision)'::regprocedure,
                            'public.combat_translate_player_formation(uuid, double precision, double precision)'::regprocedure)
                and (prosecdef is not true or not ('search_path=public' = any (proconfig)))) then
    raise exception '0311 ASSERT (a) FAIL: an authority lost SECURITY DEFINER or its pinned search_path';
  end if;
end $a$;

-- (b) ACLs: no authority is client-callable; service_role may execute all three
do $b$
declare v_n integer;
begin
  select count(*) into v_n
    from (values ('public.danger_zone_contains_point(uuid, double precision, double precision)'),
                 ('public.combat_encounter_zone_admits_point(uuid, double precision, double precision)'),
                 ('public.combat_translate_player_formation(uuid, double precision, double precision)')) as t(sig)
   where has_function_privilege('authenticated', t.sig, 'execute')
      or has_function_privilege('anon', t.sig, 'execute');
  if v_n > 0 then
    raise exception '0311 ASSERT (b) FAIL: % authority function(s) are client-callable', v_n;
  end if;
  select count(*) into v_n
    from (values ('public.danger_zone_contains_point(uuid, double precision, double precision)'),
                 ('public.combat_encounter_zone_admits_point(uuid, double precision, double precision)'),
                 ('public.combat_translate_player_formation(uuid, double precision, double precision)')) as t(sig)
   where not has_function_privilege('service_role', t.sig, 'execute');
  if v_n > 0 then
    raise exception '0311 ASSERT (b) FAIL: % authority function(s) lack the service_role grant', v_n;
  end if;
end $b$;

-- (c) the admission QUANTIFIES — no zone-choosing machinery survives; fail-closed smoke
do $c$
declare v_code text; v_ok boolean;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_encounter_zone_admits_point';
  if position('exists' in v_code) = 0 or position('danger_zone_contains_point' in v_code) = 0 then
    raise exception '0311 ASSERT (c) FAIL: the admission is not an existential over the containment leaf';
  end if;
  if position('order by' in v_code) > 0 or position('ST_Area' in v_code) > 0 or position('limit' in v_code) > 0 then
    raise exception '0311 ASSERT (c) FAIL: the admission still CHOOSES a zone (order by / ST_Area / limit) — the tie-break defect adversarial review killed';
  end if;
  if position('engagement_x is not null' in v_code) = 0 then
    raise exception '0311 ASSERT (c) FAIL: the unstamped-anchor guard is gone';
  end if;
  if position('ST_DWithin' in v_code) = 0 then
    raise exception '0311 ASSERT (c) FAIL: the anchor arm lost its closure test — every ambush-born fight would retreat';
  end if;
  -- read-only smoke, safe on any database including production:
  v_ok := public.combat_encounter_zone_admits_point('00000000-0000-4311-8311-000000000311'::uuid, 0, 0);
  if v_ok is distinct from false then
    raise exception '0311 ASSERT (c) FAIL: an encounter that does not exist admits a point (%) — must be false, fail closed', v_ok;
  end if;
  v_ok := public.danger_zone_contains_point('00000000-0000-4311-8311-000000000311'::uuid, 0, 0);
  if v_ok is distinct from false then
    raise exception '0311 ASSERT (c) FAIL: a zone that does not exist answered % (want false — fail closed)', v_ok;
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
  if position('combat_encounter_zone_admits_point(v_enc.id, v_t_x, v_t_y)' in v_code) = 0 then
    raise exception '0311 ASSERT (e) FAIL: the mover does not compose the admission authority';
  end if;
  if position('fleet_set_in_space(v_enc.fleet_id, v_t_x, v_t_y)' in v_code) = 0 then
    raise exception '0311 ASSERT (e) FAIL: the reposition does not park through the one fleets.space writer';
  end if;
  if position('combat_translate_player_formation(v_enc.id, v_t_x - v_rz_eng_x, v_t_y - v_rz_eng_y)' in v_code) = 0 then
    raise exception '0311 ASSERT (e) FAIL: the reposition does not translate through the one formation leaf';
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

-- (f) mover ORDER: settling-race guard -> admission -> destination write -> retreat verb
do $f$
declare v_code text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('movement_settled_retry' in v_code) = 0
     or position('movement_settled_retry' in v_code) > position('combat_encounter_zone_admits_point(v_enc.id' in v_code) then
    raise exception '0311 ASSERT (f) FAIL: the reposition branch does not sit AFTER the settling-race guard';
  end if;
  if position('combat_encounter_zone_admits_point(v_enc.id' in v_code) > position('retreat_target_location_id = p_location_id' in v_code) then
    raise exception '0311 ASSERT (f) FAIL: the reposition branch does not sit BEFORE the retreat-destination write — a reposition would leave a stored destination behind';
  end if;
  if position('''order_outcome'', ''repositioned''' in v_code) > position('presence_request_leave(v_enc.presence_id)' in v_code) then
    raise exception '0311 ASSERT (f) FAIL: the reposition return does not precede the retreat verb';
  end if;
end $f$;

-- (g) mover: retreat arms intact, exactly one retreat-destination write, no refusal token
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
  if position('reposition_requires_open_space' in v_code) > 0 then
    raise exception '0311 ASSERT (g) FAIL: the retired refusal token survives — a site fight must FALL THROUGH to the retreat, never be refused (the 131e027 regression adversarial review caught)';
  end if;
end $g$;

-- (h) mover never touches combat_units directly; restamp present; the leaf is a scoped translation
do $h$
declare v_code text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('combat_units' in v_code) > 0 then
    raise exception '0311 ASSERT (h) FAIL: the mover touches combat_units directly — the translation leaf is the one writer here';
  end if;
  if position('set engagement_x = v_t_x' in v_code) = 0 then
    raise exception '0311 ASSERT (h) FAIL: the engagement restamp is gone — wave 2 would spawn at the abandoned point';
  end if;
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_translate_player_formation';
  if position('pos_x = pos_x + p_dx' in v_code) = 0 or position('pos_y = pos_y + p_dy' in v_code) = 0 then
    raise exception '0311 ASSERT (h) FAIL: the leaf does not TRANSLATE (re-seeding would fork the formation authority)';
  end if;
  if position('side = ''player''' in v_code) = 0 then
    raise exception '0311 ASSERT (h) FAIL: the leaf is not scoped to the player side — enemy rows must not move';
  end if;
  if position('encounter_id = p_encounter' in v_code) = 0 then
    raise exception '0311 ASSERT (h) FAIL: the leaf is not scoped to the one encounter — it would translate every player unit in the database';
  end if;
end $h$;

-- (i) the admission is FENCED and gated on 'active'; arm (a) keeps its own gate
do $i$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  select count(*) into v_n
    from regexp_matches(v_code,
      'v_rz_admits := public\\.combat_encounter_zone_admits_point\\(v_enc\\.id, v_t_x, v_t_y\\);\\s+exception when others then\\s+v_rz_admits := false;', 'g');
  if v_n <> 1 then
    raise exception '0311 ASSERT (i) FAIL: the admission call is not fenced (% match(es)) — a geometry failure would break the retreat; this RPC never raises at its boundary (0301)', v_n;
  end if;
  select count(*) into v_n
    from regexp_matches(v_code, 'if v_enc\\.status = ''active'' then\\s+declare\\s+v_rz_admits boolean := false;', 'g');
  if v_n <> 1 then
    raise exception '0311 ASSERT (i) FAIL: % active-gated admission branch(es) (want exactly 1) — a ''retreating'' fight must never reposition', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'if v_enc.status = ''active'' then', '')))
         / length('if v_enc.status = ''active'' then');
  if v_n <> 2 then
    raise exception '0311 ASSERT (i) FAIL: % single-line active gates (want exactly 2: the admission branch + retreat arm a)', v_n;
  end if;
end $i$;

-- (j) mover: no inline geometry — the authorities stay the only geometry readers
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
