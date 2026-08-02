#!/usr/bin/env node
// gen-0312-no-living-ships.mjs — emit (or --check) migration 0312.
//
// WHY A GENERATOR: 0312 rewrites one hunk in each of TWO live player RPCs (command_ship_group_go —
// the busiest RPC in the game — and command_ship_group_dock). The 0303 lesson — "never retype a
// live function body" — cost a silently-dropped guard once already, so each `old` below is SLICED
// verbatim out of the migration that last textually defines that hunk's text: 0301 for the mover
// (0305's go hunk replaced the sortie count at 0301:1659-1664 and 0307's replaced the loot comment
// at 0301:1740-1742 — both DISJOINT from the step-5 member block this slice extends, verified by
// reading both migrations' old texts) and 0219 for the dock verb (0305's dock hunk replaced the
// sortie guard at 0219:165-178 — disjoint from the step-3 resolve+lock block this slice extends;
// 0306 rewrote assign_ship_to_group/delete_ship_group only, never dock). The migration then proves
// each slice is still what is deployed (occurs EXACTLY once in pg_get_functiondef), replaces it,
// and proves the length moved by exactly the hunk delta — byte parity outside the hunk is a
// property of the method, not a review promise.
//
//   node scripts/gen-0312-no-living-ships.mjs          # write the migration
//   node scripts/gen-0312-no-living-ships.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000312_no_living_ships_no_orders.sql');

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECK: the slice sources must still be the newest TEXTUAL re-creates. ───────────────────
// 0305 rewrites both functions (and 0307 the mover) by replace() over pg_get_functiondef — no
// textual re-create — so a `create or replace function public.<fn>(` in any migration NEWER than
// the slice source means the head moved and this generator's slice is stale. Do NOT assume — scan.
{
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const heads = [
    ['command_ship_group_go',   '20260618000301'],
    ['command_ship_group_dock', '20260618000219'],
  ];
  for (const [fn, base] of heads) {
    const reCreate = new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${fn}\\s*\\(`, 'i');
    const newerHeads = readdirSync(MIGDIR)
      .filter((f) => f.endsWith('.sql') && version(f) > base && version(f) !== '20260618000312')
      .filter((f) => reCreate.test(readFileSync(MIG(f), 'utf8')));
    if (newerHeads.length > 0) {
      throw new Error(
        `${fn} was textually re-created AFTER ${base} by: ${newerHeads.join(', ')} — ` +
        're-point the slice at the new head before generating.');
    }
  }
}

const F301 = load('20260618000301_intercept_fires_at_zone_entry.sql');
const F219 = load('20260618000219_timed_docking.sql');

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

// ── Hunk 1: the mover's step-5 member block (0301:1576-1584) — the exact guard the owner's bug
// ── lives in. It counts MEMBERS; the 0312 liveness guard is APPENDED after its empty_group return,
// ── so empty_group keeps answering first (both states are real and must stay distinguishable).
const GO_MEMBERS = slice(F301, '0301', 1576, 1584, '-- 5) members', 'end if;');

const GO_MEMBERS_NEW = `${GO_MEMBERS}

  -- ── 0312: A DEAD FLEET TAKES NO MAP ORDERS. ────────────────────────────────────────────────────
  -- The owner's rule, verbatim: "when there is no fleet active, meaning if it has no hp, it should
  -- not be able to move to map." The member count above cannot see death: destroyed ships are never
  -- deleted (mainship_mark_combat_destroyed writes status/hp only, 0231:322-327), so a fleet whose
  -- every ship was wrecked still passed it and could be flown around the map. The ONE authority
  -- answers "is every ship in this group destroyed?" — dead = status = 'destroyed', NEVER hp = 0:
  -- the tick's hp sync rounds a fractional hull to integer (0234:851-852), so a merely damaged,
  -- still-fighting ship can legitimately read instance hp 0, and an hp predicate would call it
  -- dead. Distinct from empty_group above, and ordered AFTER it. Recovery composes nothing here:
  -- tow, repair, the roster writes and the brake never read this authority.
  if public.group_all_ships_destroyed(v_player, v_group) then
    return jsonb_build_object('ok', false, 'reason', 'no_living_ships');
  end if;
  -- ── end 0312 — the head continues verbatim from here ───────────────────────────────────────────`;

// ── Hunk 2: the dock verb's step-3 resolve+lock block (0219:156-163). The guard is APPENDED after
// ── the group lock, BEFORE the (0305-rewritten) sortie guard and the fleet resolve. HONESTY ABOUT
// ── REACH: the MOVER carries the live answer — dock's dark gate (0219:147-149) returns
// ── timed_docking_disabled before this guard can run, and timed_docking_enabled is FALSE in
// ── production, so hunk 2 is PRE-POSITIONED for whenever that key is lit and unreachable until
// ── then. The placement is still deliberate: reject-before-read keeps the flag gate first, and
// ── the liveness guard must already be standing on the day the key flips (the 0301 dock blind
// ── spot — a guard everyone meant to add "with the flag" — is why timed docking is held today).
const DOCK_LOCK = slice(F219, '0219', 156, 163, 'v_group := public.mainship_resolve_owned_group', 'end if;');

const DOCK_LOCK_NEW = `${DOCK_LOCK}

  -- ── 0312: A DEAD FLEET TAKES NO MAP ORDERS — dock included. ────────────────────────────────────
  -- Dock mints a movement leg like any other order; a group whose every ship is destroyed must not
  -- fly it to a port. REACHABILITY, honestly: the dark gate above answers timed_docking_disabled
  -- before this line runs while timed_docking_enabled is false — which it is in production — so
  -- this guard is INERT until that key is lit, and the MOVER's twin guard carries the live answer
  -- today. Even lit, today's writers cannot stage the state it refuses (a total defeat destroys
  -- the fleet WITH its ships — process_combat_ticks calls fleet_destroy then marks the members —
  -- so the live-fleet resolve below already answers no_fleet). Both of those safeties are EMERGENT
  -- — one from a flag value, one from the tick's write order — and emergent invariants are how
  -- this codebase has been hurt before; this guard makes the rule local to the verb, standing
  -- before either fact changes. Same ONE authority as the mover; an EMPTY group is not a dead
  -- fleet and keeps its own answers below.
  if public.group_all_ships_destroyed(v_player, v_group) then
    return jsonb_build_object('ok', false, 'reason', 'no_living_ships');
  end if;
  -- ── end 0312 — the head continues verbatim from here ───────────────────────────────────────────`;

const HUNKS = [
  [1, 'command_ship_group_go',   GO_MEMBERS, GO_MEMBERS_NEW],
  [2, 'command_ship_group_dock', DOCK_LOCK,  DOCK_LOCK_NEW],
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
-- 0312 — NO LIVING SHIPS, NO ORDERS (a dead fleet cannot be moved around the map)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- THE OWNER'S BUG REPORT, VERBATIM: "when there is no fleet active, meaning if it has no hp, it
-- should not be able to move to map."
--
-- THE DEFECT: command_ship_group_go's membership guard (deployed text from 0301:1576-1584) counts
-- MEMBERS, not living ships. mainship_mark_combat_destroyed (0231:322-327) only writes
-- status='destroyed', hp=0 — destroyed ships are NEVER deleted from main_ship_instances (no
-- \`delete from main_ship_instances\` exists anywhere in the chain) and a defeat does not un-group
-- them — so a fleet whose every ship was wrecked still had member rows, passed empty_group, fell
-- through step 9's fleet resolve (its fleet is 'destroyed', outside the live set) into the
-- BOOTSTRAP arm, and was handed a fresh fleet and a movement leg. A dead fleet could sail.
--
-- ── THE PREDICATE, PROVEN FROM SOURCE (why status, never hp) ─────────────────────────────────────
-- dead = status = 'destroyed'. NOT hp = 0, and NOT the conjunction:
--   * every writer of status='destroyed' sets hp=0 in the SAME statement
--     (mainship_mark_combat_destroyed 0231:325, dev_set_main_ship_destroyed 0059:100, the 0052
--     safelock's own arm), and both recovery writers restore the pair together
--     (repair_main_ship 0297: hp=max_hp, status='home'). status='destroyed' with hp>0 has no
--     writer.
--   * hp=0 with the ship ALIVE is REAL: mainship_sync_combat_hp (0167:134-145) writes
--     round(greatest(0, v_new_hp))::integer — hp ONLY, never status — and the tick keeps a unit
--     alive on any fractional hull (alive_count = ceil(hp/shiphp), 0234:846). A ship at unit hull
--     0.4 is alive and fighting while its instance row reads hp 0. An hp predicate would treat
--     that merely-damaged ship as dead — the exact mistake this header exists to forbid. The
--     owner's words name hp; the owner's INTENT is "wrecked", and 'destroyed' is the game's one
--     wrecked marker (repair, tow, get_my_disabled_ships and the position projection all already
--     key on it — 0297).
--
-- ── ONE AUTHORITY, COMPOSED PER VERB (the enumeration, with reasoning) ──────────────────────────
--   public.group_all_ships_destroyed(player, group) — true iff the group HAS members and every one
--   is destroyed. An empty group answers FALSE: empty_group and no_living_ships are different
--   states and the player must be able to tell them apart.
--
--   command_ship_group_go        — COMPOSED (hunk 1). The defect's own verb; the bootstrap arm is
--                                  what let a dead fleet mint a fresh fleet + leg.
--   command_ship_group_go_route  — covered BY COMPOSITION: leg 1 calls the mover unmodified and
--                                  returns its refusal before queueing anything (0301:2298-2305).
--                                  A second guard here would be a second copy of the predicate.
--   command_ship_group_dock      — COMPOSED (hunk 2), PRE-POSITIONED: its dark gate
--                                  (0219:147-149) answers timed_docking_disabled before this
--                                  guard while timed_docking_enabled is false — which it is in
--                                  production — so THE MOVER CARRIES THE LIVE ANSWER and hunk 2
--                                  is unreachable until that key is lit. It stands anyway: dock
--                                  mints a movement leg like the mover, and its only other
--                                  safety (no dead group owns a live parked fleet) is emergent
--                                  from the tick's fleet_destroy-then-mark write order, not
--                                  local. The guard must already exist on the day the key flips.
--   send_ship_group_hunt         — NOT composed: every one of its three arms already refuses any
--                                  fleet containing a ship at hp<=0 or not home/docked
--                                  (member_not_ready — 0231:558-562, :724-735, :745-760). A dead
--                                  ship is status='destroyed', hp=0: refused on all arms today.
--                                  Adding this authority there would be a SECOND refusal for the
--                                  same fact. (Self-assert (g) pins the existing refusal so this
--                                  exclusion cannot rot silently.)
--   command_ship_group_stop      — NOT composed, DELIBERATELY. The brake is an abort, not a map
--                                  order: it mints nothing, and on a dead group it is already an
--                                  idempotent no-op (no live fleet → 'no_fleet'). Blocking an
--                                  abort verb can only ever strand someone in a transient state.
--   assign/unassign/delete/upsert_ship_group, repair_main_ship, mainship_emergency_tow —
--                                  NOT composed: these ARE the recovery path. A dead fleet is
--                                  recovered by tow (berths the wreck, leaves the group) + repair
--                                  (at the port) + re-assign. Blocking any of them would strand
--                                  the player permanently — worse than the bug being fixed.
--                                  Self-assert (f) pins that none of them read this authority.
--
-- ── THE REASON CODE ──────────────────────────────────────────────────────────────────────────────
-- 'no_living_ships' — typed, new, DISTINCT from 'empty_group' (no members at all). The client maps
-- it in src/features/command/teamReasonMessage.ts in this same slice (never ship half a slice).
--
-- ── BLAST RADIUS ON LIVE PLAYERS ─────────────────────────────────────────────────────────────────
--   - No data written at deploy time: no backfill, no flag, no schema change. DDL = one CREATE
--     FUNCTION + one CREATE OR REPLACE each of the mover and the dock verb (pg_proc row locks).
--   - Which orders change behaviour: ONLY a MOVER order (go / route leg 1) on a group whose every
--     member is destroyed — today that order "succeeds" and flies wrecks around the map. The dock
--     hunk changes nothing observable in production: its dark gate answers first while
--     timed_docking_enabled is false (see the per-verb table). Groups with any living ship,
--     empty groups, mid-combat retreats, sorties: byte-identical to 0301+0305+0307.
--   - Recovery (tow/repair/roster) and the brake are untouched by construction and pinned so.
--   - NO DARK: no flag. The mover's refusal is live the moment this deploys, which is the owner's
--     order; the dock guard's reach is bounded by the pre-existing timed_docking key, not by any
--     flag of this slice's making.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed command_ship_group_go / command_ship_group_dock bodies with the 0312 hunks
-- reverted (the slice texts at 0301:1576-1584 and 0219:156-163), then:
--   drop function public.group_all_ships_destroyed(uuid, uuid);
-- Nothing else here writes state.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
--   (a) the authority exists with the right shape (STABLE, secdef, pinned search_path)
--   (b) ACLs: not client-callable; service_role may execute
--   (c) the predicate is status-shaped: 'destroyed' present, NO hp read (the damaged-is-dead trap),
--       both existential arms present; fail-closed smoke — an unknown/empty group answers false
--   (d) mover: composed exactly once, AFTER empty_group and BEFORE the sortie classify; exactly one
--       'no_living_ships' token
--   (e) dock: composed exactly once, BEFORE the sortie authority and the fleet resolve; exactly one
--       'no_living_ships' token
--   (f) the recovery surface is untouched: repair/tow/assign/delete/upsert/stop read neither the
--       authority nor the token
--   (g) the hunt exclusion cannot rot: send_ship_group_hunt still carries its own hp<=0 readiness
--   (k) metadata parity: both rewritten functions changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) ─────────────────────────────────────────────────────────────────
do $pre$
declare v_missing text;
begin
  if to_regclass('public.main_ship_instances') is null
     or to_regclass('public.ship_groups') is null then
    raise exception '0312 PRECONDITION FAIL: a table this migration composes over is absent';
  end if;
  if not exists (
    select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
     where t.relname = 'main_ship_instances'
       and c.conname = 'main_ship_instances_status_check'
       and pg_get_constraintdef(c.oid) like '%destroyed%') then
    raise exception '0312 PRECONDITION FAIL: main_ship_instances_status_check does not model ''destroyed'' (0231 §5)';
  end if;
  select string_agg(f, ', ') into v_missing
    from unnest(array[
      'command_ship_group_go',
      'command_ship_group_dock',
      'mainship_mark_combat_destroyed',
      'repair_main_ship',
      'mainship_emergency_tow',
      'send_ship_group_hunt'
    ]) as f
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f);
  if v_missing is not null then
    raise exception '0312 PRECONDITION FAIL: missing function(s): %', v_missing;
  end if;
end $pre$;

-- ── 1. THE LIVENESS AUTHORITY ────────────────────────────────────────────────────────────────────
-- ONE statement, ONE snapshot (the 0213 Finding-3 rule). STABLE (reads a table), SECURITY DEFINER +
-- pinned search_path to match both composition sites (both are security-definer engine functions).
-- NULL/garbage input, an unknown group and an EMPTY group all answer false: fail closed — this
-- authority can only ever REFUSE an order, so false means "do not refuse on liveness grounds".
create or replace function public.group_all_ships_destroyed(p_player uuid, p_group uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select exists (select 1 from public.main_ship_instances m
                  where m.player_id = p_player and m.group_id = p_group)
     and not exists (select 1 from public.main_ship_instances m
                      where m.player_id = p_player and m.group_id = p_group
                        and m.status <> 'destroyed');
$fn$;

comment on function public.group_all_ships_destroyed(uuid, uuid) is
  'THE one answer to "is this a dead fleet?" (0312): true iff the group HAS members and every one '
  'is status=''destroyed''. Dead is the status, never hp: the tick''s hp sync rounds a fractional '
  'hull to integer (0234:851-852), so a merely damaged, still-fighting ship can read instance hp 0 '
  '— an hp predicate would call it dead. An EMPTY group answers false: empty_group and '
  'no_living_ships are different states and each keeps its own reason code. Composed by '
  'command_ship_group_go and command_ship_group_dock; NEVER by the recovery surface (tow, repair, '
  'the roster writes, the brake), which must keep working on exactly the fleets this refuses.';

-- ACLs: internal leaf — both composers are security-definer engine functions. Explicitly revoked
-- rather than merely un-granted (the 0254 prod grant-drift lesson). It does not derive the actor —
-- it takes the player as an argument — which is exactly why the client must never call it (0309).
revoke execute on function public.group_all_ships_destroyed(uuid, uuid) from public, anon, authenticated;
grant execute on function public.group_all_ships_destroyed(uuid, uuid) to service_role;

-- ── 2. CAPTURE METADATA BEFORE THE REWRITE (for parity check k) ──────────────────────────────────
create temp table _0312_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0312_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('command_ship_group_go', 'command_ship_group_dock');

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
      raise exception '0312 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0312 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0312 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0312 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 2 then
    raise exception '0312 REWRITE FAIL: rewrote % site(s), expected 2', v_done;
  end if;
  raise notice '0312: a dead fleet takes no map orders; everything else is byte-identical';
end $rewrite$;

-- ── 4. SELF-ASSERTS — one DO block per check; every probe strips comments first ─────────────────

-- (a) the authority exists with the right shape
do $a$
begin
  if to_regprocedure('public.group_all_ships_destroyed(uuid, uuid)') is null then
    raise exception '0312 ASSERT (a) FAIL: the liveness authority is missing';
  end if;
  if (select provolatile from pg_proc
       where oid = 'public.group_all_ships_destroyed(uuid, uuid)'::regprocedure) <> 's' then
    raise exception '0312 ASSERT (a) FAIL: wrong volatility — the authority reads a table and must be STABLE';
  end if;
  if exists (select 1 from pg_proc
              where oid = 'public.group_all_ships_destroyed(uuid, uuid)'::regprocedure
                and (prosecdef is not true or not ('search_path=public' = any (proconfig)))) then
    raise exception '0312 ASSERT (a) FAIL: the authority lost SECURITY DEFINER or its pinned search_path';
  end if;
end $a$;

-- (b) ACLs: not client-callable; service_role may execute
do $b$
begin
  if has_function_privilege('authenticated', 'public.group_all_ships_destroyed(uuid, uuid)', 'execute')
     or has_function_privilege('anon', 'public.group_all_ships_destroyed(uuid, uuid)', 'execute') then
    raise exception '0312 ASSERT (b) FAIL: the authority is client-callable — it takes the actor as an argument (0309)';
  end if;
  if not has_function_privilege('service_role', 'public.group_all_ships_destroyed(uuid, uuid)', 'execute') then
    raise exception '0312 ASSERT (b) FAIL: the authority lacks the service_role grant';
  end if;
end $b$;

-- (c) the predicate is status-shaped, and fail-closed on unknown/empty input
do $c$
declare v_code text; v_n integer; v_ok boolean;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'group_all_ships_destroyed';
  if v_code is null then
    -- NULL-vacuity guard (the (f) idiom, applied uniformly): position(… in NULL) is NULL and no
    -- branch below would fire — this block must fail on absence by ITS OWN construction, never by
    -- another block's luck.
    raise exception '0312 ASSERT (c) FAIL: group_all_ships_destroyed is missing — every probe below would pass vacuously';
  end if;
  if position('status <> ''destroyed''' in v_code) = 0 then
    raise exception '0312 ASSERT (c) FAIL: the liveness predicate lost its status test';
  end if;
  if v_code ~* '\\mhp\\M' then
    raise exception '0312 ASSERT (c) FAIL: the liveness predicate reads hp — a merely damaged ship (hp rounded to 0, 0234:851-852) would be treated as dead';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'exists', ''))) / length('exists');
  if v_n <> 2 then
    raise exception '0312 ASSERT (c) FAIL: % existential arm(s) (want 2: has-members AND none-living) — an empty group must not read as a dead fleet', v_n;
  end if;
  -- read-only smoke, safe on any database including production:
  v_ok := public.group_all_ships_destroyed('00000000-0000-4312-8312-000000000312'::uuid,
                                           '00000000-0000-4312-8312-000000000312'::uuid);
  if v_ok is distinct from false then
    raise exception '0312 ASSERT (c) FAIL: an unknown/empty group answered % (want false — this authority may only ever REFUSE, so false is the safe answer)', v_ok;
  end if;
  v_ok := public.group_all_ships_destroyed(null, null);
  if v_ok is distinct from false then
    raise exception '0312 ASSERT (c) FAIL: NULL input answered % (want false — fail closed)', v_ok;
  end if;
end $c$;

-- (d) mover: composed exactly once, in order
do $d$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if v_code is null then
    raise exception '0312 ASSERT (d) FAIL: command_ship_group_go is missing — every probe below would pass vacuously (NULL position/NULL counters fire no branch)';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'group_all_ships_destroyed(v_player, v_group)', '')))
         / length('group_all_ships_destroyed(v_player, v_group)');
  if v_n <> 1 then
    raise exception '0312 ASSERT (d) FAIL: the mover composes the authority % time(s), want exactly 1', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, '''no_living_ships''', '')))
         / length('''no_living_ships''');
  if v_n <> 1 then
    raise exception '0312 ASSERT (d) FAIL: % no_living_ships token(s) in the mover, want exactly 1', v_n;
  end if;
  if position('''empty_group''' in v_code) = 0
     or position('''empty_group''' in v_code) > position('group_all_ships_destroyed(v_player, v_group)' in v_code) then
    raise exception '0312 ASSERT (d) FAIL: the liveness guard does not sit AFTER empty_group — the two states must answer in that order';
  end if;
  if position('group_sortie_is_open' in v_code) = 0
     or position('group_all_ships_destroyed(v_player, v_group)' in v_code) > position('group_sortie_is_open' in v_code) then
    raise exception '0312 ASSERT (d) FAIL: the liveness guard does not sit BEFORE the sortie classify — a dead fleet must get ONE answer, not group_on_sortie';
  end if;
end $d$;

-- (e) dock: composed exactly once, before the sortie authority and the fleet resolve
do $e$
declare v_code text; v_n integer;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_dock';
  if v_code is null then
    raise exception '0312 ASSERT (e) FAIL: command_ship_group_dock is missing — every probe below would pass vacuously (NULL position/NULL counters fire no branch)';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'group_all_ships_destroyed(v_player, v_group)', '')))
         / length('group_all_ships_destroyed(v_player, v_group)');
  if v_n <> 1 then
    raise exception '0312 ASSERT (e) FAIL: the dock verb composes the authority % time(s), want exactly 1', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, '''no_living_ships''', '')))
         / length('''no_living_ships''');
  if v_n <> 1 then
    raise exception '0312 ASSERT (e) FAIL: % no_living_ships token(s) in the dock verb, want exactly 1', v_n;
  end if;
  if position('group_sortie_is_open' in v_code) = 0
     or position('group_all_ships_destroyed(v_player, v_group)' in v_code) > position('group_sortie_is_open' in v_code) then
    raise exception '0312 ASSERT (e) FAIL: the dock guard does not sit BEFORE the sortie authority';
  end if;
  if position('ship_group_resolve_fleet' in v_code) = 0
     or position('group_all_ships_destroyed(v_player, v_group)' in v_code) > position('ship_group_resolve_fleet' in v_code) then
    raise exception '0312 ASSERT (e) FAIL: the dock guard does not sit BEFORE the fleet resolve — a dead fleet must answer no_living_ships, never no_fleet';
  end if;
end $e$;

-- (f) the recovery surface is untouched — none of these may ever refuse on liveness
do $f$
declare v_fn text; v_code text;
begin
  foreach v_fn in array array['repair_main_ship', 'mainship_emergency_tow', 'assign_ship_to_group',
                              'delete_ship_group', 'upsert_ship_group', 'command_ship_group_stop'] loop
    select ${STRIP} into v_code
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_code is null then
      raise exception '0312 ASSERT (f) FAIL: public.% is missing', v_fn;
    end if;
    if position('group_all_ships_destroyed' in v_code) > 0
       or position('no_living_ships' in v_code) > 0 then
      raise exception '0312 ASSERT (f) FAIL: public.% reads the liveness authority — it is a RECOVERY/abort verb and blocking it would strand the player (the whole point of the per-verb table)', v_fn;
    end if;
  end loop;
end $f$;

-- (g) the hunt exclusion cannot rot: its own readiness refusal must still exist
do $g$
declare v_code text;
begin
  select ${STRIP} into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_ship_group_hunt';
  if v_code is null then
    raise exception '0312 ASSERT (g) FAIL: send_ship_group_hunt is missing — the probe below would pass vacuously (NULL position fires no branch)';
  end if;
  if position('hp <= 0' in v_code) = 0 then
    raise exception '0312 ASSERT (g) FAIL: send_ship_group_hunt lost its hp<=0 readiness — 0312 deliberately did NOT guard the hunt because that refusal already covers a dead fleet; if it is gone, the hunt needs the liveness authority composed in a follow-up slice';
  end if;
  if position('group_all_ships_destroyed' in v_code) > 0 then
    raise exception '0312 ASSERT (g) FAIL: send_ship_group_hunt composes the liveness authority — that is a SECOND refusal for a fact its readiness already refuses (member_not_ready)';
  end if;
end $g$;

-- (k) metadata parity: both rewritten functions changed body and NOTHING else
do $k$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0312_before loop
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
      raise exception '0312 ASSERT (k) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0312 ASSERT (k) FAIL: public.% body is byte-identical — the hunk did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 2 then
    raise exception '0312 ASSERT (k) FAIL: parity-checked % function(s), expected 2', v_n;
  end if;
  raise notice '0312 SELF-ASSERT PASS: a dead fleet takes no map orders; recovery and the brake stay open; everything else byte-identical';
end $k$;

commit;
`;

if (sql.includes('\r')) {
  throw new Error('generated 0312 carries a CR — the rewrite hunk would never match the deployed body');
}

const check = process.argv.includes('--check');
if (check) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8');
  } catch {
    console.error('0312 CHECK FAIL: migration file is missing — run the generator');
    process.exit(1);
  }
  if (onDisk.replace(/\r\n/g, '\n') !== sql) {
    console.error('0312 CHECK FAIL: the migration on disk is not what the slice generates.');
    console.error('Either the source migration drifted or the file was hand-edited. Re-run the generator.');
    process.exit(1);
  }
  console.log('0312 CHECK OK: migration matches the slices taken from 0301 and 0219.');
} else {
  writeFileSync(OUT, sql);
  console.log(`0312 written: ${OUT}`);
  console.log(`  ${HUNKS.length} hunks sliced from 0301/0219 (nothing retyped)`);
}
