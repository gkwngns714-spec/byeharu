-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0330 — THE MOVER IS IN THE REPO (restore the repository as the source of truth for movement)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ⛔ THIS MIGRATION CHANGES NO BEHAVIOUR. Not one byte of any function body moves. It exists so that
--    the next person who has to CHANGE the fleet mover can read it in a file instead of reconstructing
--    it from production.
--
-- ── THE FINDING ─────────────────────────────────────────────────────────────────────────────────
-- The repository did not contain the source of the fleet mover.
--
-- `command_ship_group_go`'s last full `create or replace` is
-- 20260618000301_intercept_fires_at_zone_entry.sql:1474. Since then it has been modified IN PLACE,
-- four times, by text surgery — `pg_get_functiondef` -> `replace` -> `execute` — in 0305, 0307, 0311
-- and 0312. Its live body is 39,019 characters and NO FILE HELD IT. The same pattern had eaten four
-- more movement verbs:
--
--   function                     last full definition in the repo    surgeries applied since
--   command_ship_group_go        0301:1474                           0305, 0307, 0311, 0312
--   command_ship_group_dock      0219:115                            0305, 0312
--   command_ship_group_stop      0301:2079                           0305 (x2), 0308
--   send_ship_group_hunt         0231:393                            0305
--   movement_settle_arrival      0208:90                             0307
--
-- Counted in this tree: 34 migrations reference `pg_get_functiondef`, and 10 of them execute a
-- rewritten definition — that is the surgery population. It is a GOOD pattern for what it was built
-- for: it makes byte parity OUTSIDE a marked hunk a property of the method rather than a review
-- promise, and it has caught real drift. What it does not do is leave a readable head behind. After
-- four surgeries the only complete copy of the mover is the one running in production, and a
-- reviewer cannot diff a proposal against a body that exists nowhere.
--
-- ── WHY IT IS DANGEROUS, NOT MERELY UNTIDY ──────────────────────────────────────────────────────
-- The disposable-Postgres apply-proof is this project's only real net — it is the sole layer that
-- executes a migration's own self-asserts. That net is worth exactly as much as the assumption that
-- the chain reproduces production, and when the chain is the ONLY description of a function, NOTHING
-- CHECKS THAT ASSUMPTION. The failure mode is silent by construction: a hand-run script, a hotfix
-- applied through the SQL editor, or a surgery whose `old` text matched something slightly different
-- on production than on a fresh chain, and from then on CI proves things about a body no player runs.
--
-- A CORRECTION, because this file must not repeat an unverified claim. The audit that commissioned
-- this slice reported `location_create` as an existing example of exactly that divergence —
-- "production raises canonical_coord_violation; the repo's last full definition at 0264:100 does
-- not". That is FALSE, and it was checked before writing this line: production's `location_create`
-- is md5 32781fb03c2b8c1a96e6675912b37d7a / 10855 bytes, which is BYTE-IDENTICAL to the repo's last
-- full definition — not 0264:100 but 20260618000265_canonical_coord_validation_authority.sql:804,
-- which re-created the function and does contain `canonical_coord_violation`. The audit read one
-- definition too early in the chain. No divergence has been demonstrated anywhere yet.
--
-- That correction makes the case for this slice STRONGER, not weaker. The hazard was never a known
-- drift someone could point at; it is that a drift would be invisible. What makes it invisible is a
-- function whose text lives only in a database, and that is the condition this migration ends for the
-- movement family.
--
-- ── WHAT WAS VERIFIED BEFORE WRITING THIS FILE (2026-08-03, read-only against production) ────────
-- The repo chain was replayed offline — take each function's last full definition, apply every later
-- surgery hunk in migration order, hash the result — and compared with the live `prosrc`. ALL SEVEN
-- movement-family functions matched byte-for-byte:
--
--   command_ship_group_go        39019  b176b274a048d704ba82c72fa4393c99
--   command_ship_group_go_route   3724  cc0d071d5bacdff28123fd1f03988ad7
--   command_ship_group_dock       9367  4dea7327d0aa3e5fa9ab7332890f8cd0
--   command_ship_group_stop       9032  c29e23a5e8c3bc478a00c2c1364e9c0b
--   send_ship_group_hunt         31686  c75969122eda408eb5410bccd9a42ebb
--   movement_settle_arrival       7255  9ce1178b8910e89c08070990718afa76
--   send_fleet_to_location        2561  5dff35cc9f972c3d8173025bc762c260
--
-- So for the MOVEMENT family the chain and production agree today, and this migration is a genuine
-- no-op on both. That is the finding, not an assumption: the self-asserts below re-prove it wherever
-- this file is applied, and ABORT if it is ever false.
--
-- ── WHAT THIS MIGRATION DOES ────────────────────────────────────────────────────────────────────
-- 1. Re-creates FIVE functions from the exact `pg_get_functiondef` text captured from production, so
--    the repository holds them again. The bytes are production's, not a re-typing.
-- 2. Proves it: every body's md5 is captured BEFORE and asserted UNCHANGED after, and asserted equal
--    to the production constant baked in below. A single differing byte aborts the migration.
-- 3. ESTABLISHES the movement client surface by REVOKE + GRANT rather than asserting it (the 0254
--    prod grant-drift lesson) — revoking from PUBLIC BY NAME, never just `anon, authenticated` (the
--    0309 lesson: a revoke naming only those two leaves a PUBLIC-held privilege standing) — and then
--    asserts the EXECUTE grantee list is UNCHANGED from before it ran, plus who may and may not
--    reach it. See the note above check (d) for why `service_role` is tolerated but never granted.
-- 4. Retires `send_fleet_to_location` from the client surface — see §5.
--
-- ── WHY `command_ship_group_go_route` IS NOT RE-EMITTED HERE ────────────────────────────────────
-- Because it does not need to be, and copying it would create the second authority this slice exists
-- to remove. 0301:2235 is still its LAST and TRUE definition — no surgery has ever touched it, and
-- the replay above confirms that text is byte-identical to what production runs
-- (cc0d071d5bacdff28123fd1f03988ad7). Its GRANTS are established here with the rest of the family,
-- because grants are a surface this migration owns; its BODY is not, and this file deliberately does
-- not assert an md5 for a body it does not write.
--
-- ── WHY THERE IS NO GENERATOR FOR THIS MIGRATION ────────────────────────────────────────────────
-- Every sibling that re-creates live plpgsql ships a `scripts/gen-*.mjs` whose `--check` re-derives
-- the migration from the repo files it slices. That machinery cannot apply here: this migration's
-- source is PRODUCTION, and a `--check` would have to reach the live database over the network, which
-- CI cannot and must not do. The migration file IS the authority — which is the entire point of the
-- slice. The generated-migration parity gate in scripts/danger-combat-proof.sh is unaffected: it
-- enumerates scripts/gen-*.mjs, and this slice adds none.
--
-- ── THE ONE THING FUTURE SLICES MUST DO DIFFERENTLY ─────────────────────────────────────────────
-- After this migration, 0330 — not 0301/0219/0231/0208 — is the head text of those five functions.
-- A new surgery slice must cut its `old` hunks from THIS FILE. gen-0311 and gen-0312 already scan for
-- exactly that condition; their scan windows are corrected in this slice to end at their own version
-- (a re-creation numbered ABOVE a generated migration applies AFTER it and cannot invalidate its
-- slices), so they keep firing for anything that lands between their base and themselves.
--
-- ── BLAST RADIUS ON LIVE PLAYERS ────────────────────────────────────────────────────────────────
--   - Zero behaviour change, by construction and by self-assert. No data written, no schema change,
--     no flag, no backfill.
--   - DDL: five CREATE OR REPLACE FUNCTION (pg_proc row locks, sub-millisecond) plus GRANT/REVOKE.
--   - The ONE deliberate surface change is §5: `send_fleet_to_location` stops being callable by
--     `authenticated`. No client code path calls it (verified: zero hits in src/).
--   - `create or replace` preserves the oid, so COMMENTs and dependencies survive; parity check (c)
--     pins both.
--
-- ── ROLLBACK ────────────────────────────────────────────────────────────────────────────────────
-- The bodies are byte-identical to what was already deployed, so there is nothing to roll back in
-- them. To restore §5 only:
--   grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
--   (0) preconditions: every function present, exactly one overload each
--   (a) BEFORE: the deployed body is the production body this file carries (else the DB has drifted
--       away from the text below and re-creating it WOULD change behaviour — abort, do not ship)
--   (b) AFTER: every body md5 is UNCHANGED, and equals the production constant. Zero behaviour change.
--   (c) metadata + comment parity: owner / secdef / volatility / parallel / proconfig / args / result
--       / cost / strict / retset / leakproof / obj_description all unchanged
--   (d) the movement client surface, as an exact EXECUTE grantee SET per function (PUBLIC included in
--       the comparison, by name) AND unchanged from what was captured before anything was replaced
--   (e) §5: send_fleet_to_location is no longer client-callable by PUBLIC, anon OR authenticated, no
--       unintended role holds it, and its BODY was not touched
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) ─────────────────────────────────────────────────────────────────
do $pre$
declare v_missing text; v_dup text;
begin
  select string_agg(f, ', ') into v_missing
    from unnest(array[
      'command_ship_group_go',
      'command_ship_group_go_route',
      'command_ship_group_dock',
      'command_ship_group_stop',
      'send_ship_group_hunt',
      'movement_settle_arrival',
      'send_fleet_to_location']) as f
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f);
  if v_missing is not null then
    raise exception '0330 PRECONDITION FAIL: missing function(s): %', v_missing;
  end if;

  -- Every probe below locates a function BY NAME. An overload would make "the" body ambiguous and
  -- every md5 comparison silently meaningless, so refuse rather than guess (the 0312 idiom).
  select string_agg(d.proname, ', ') into v_dup
    from (select p.proname
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname = any (array['command_ship_group_go', 'command_ship_group_go_route', 'command_ship_group_dock', 'command_ship_group_stop', 'send_ship_group_hunt', 'movement_settle_arrival', 'send_fleet_to_location'])
           group by p.proname having count(*) > 1) d;
  if v_dup is not null then
    raise exception '0330 PRECONDITION FAIL: overloaded function(s): % — refusing to guess which body this migration describes', v_dup;
  end if;
end $pre$;

-- ── 1. THE PRODUCTION BODIES THIS FILE CARRIES ───────────────────────────────────────────────────
-- Captured read-only from production on 2026-08-03 with md5(prosrc) / length(prosrc). These are not
-- a description of the bodies below; they are the gate that proves the bodies below are unchanged.
create temp table _0330_expected (fname text primary key, body_md5 text not null, srclen integer not null)
  on commit drop;
insert into _0330_expected (fname, body_md5, srclen) values
    ('command_ship_group_go',     'b176b274a048d704ba82c72fa4393c99', 39019),
    ('command_ship_group_dock',   '4dea7327d0aa3e5fa9ab7332890f8cd0', 9367),
    ('command_ship_group_stop',   'c29e23a5e8c3bc478a00c2c1364e9c0b', 9032),
    ('send_ship_group_hunt',      'c75969122eda408eb5410bccd9a42ebb', 31686),
    ('movement_settle_arrival',   '9ce1178b8910e89c08070990718afa76', 7255);

-- ── 2. CAPTURE THE DEPLOYED STATE, BEFORE ANYTHING IS REPLACED ──────────────────────────────────
create temp table _0330_before (
  fname text primary key, body_md5 text, srclen integer, owner text, secdef boolean,
  volatility "char", parallel "char", strict_ boolean, retset boolean, leakproof boolean,
  cost real, proconfig text, args text, result text, fn_comment text, exec_grants text
) on commit drop;

insert into _0330_before
select p.proname, md5(p.prosrc), length(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef,
       p.provolatile, p.proparallel, p.proisstrict, p.proretset, p.proleakproof, p.procost,
       coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(obj_description(p.oid, 'pg_proc'), ''),
       coalesce((select string_agg(coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC'), ',' order by 1)
                   from aclexplode(p.proacl) a where a.privilege_type = 'EXECUTE'), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname = any (array['command_ship_group_go', 'command_ship_group_go_route', 'command_ship_group_dock', 'command_ship_group_stop', 'send_ship_group_hunt', 'movement_settle_arrival', 'send_fleet_to_location']);

-- (a) BEFORE — the deployed body must already BE the production body written below. If it is not,
-- this file would CHANGE the running code, which is the one thing this slice must never do.
do $a$
declare r record; v_live text; v_len integer;
begin
  for r in select * from _0330_expected order by fname loop
    select md5(p.prosrc), length(p.prosrc) into v_live, v_len
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_live is null then
      raise exception '0330 ASSERT (a) FAIL: public.% vanished between the precondition block and here', r.fname;
    end if;
    if v_live <> r.body_md5 then
      raise exception '0330 ASSERT (a) FAIL: public.% deployed body is % (% bytes), but this migration carries % (% bytes). The database has drifted away from the text in this file — applying it would CHANGE BEHAVIOUR. Do NOT regenerate blindly: read the drift first (a later migration may have rewritten this function, or this database is not on the chain this file was captured from).',
        r.fname, v_live, v_len, r.body_md5, r.srclen;
    end if;
  end loop;
end $a$;

-- ── 3. THE RESTORATION ──────────────────────────────────────────────────────────────────────────
-- Verbatim `pg_get_functiondef` output from production. Nothing below was typed by hand, and nothing
-- below is allowed to differ from what was already running — check (b) is what makes that true rather
-- than promised.

CREATE OR REPLACE FUNCTION public.command_ship_group_go(p_group_id uuid, p_location_id uuid DEFAULT NULL::uuid, p_target_x double precision DEFAULT NULL::double precision, p_target_y double precision DEFAULT NULL::double precision)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player     uuid := auth.uid();
  v_group      uuid;
  v_members    uuid[];
  v_member_n   integer;
  v_loc        record;
  v_fleet      uuid;
  v_fleet_row  record;
  v_unified_n  integer;
  v_busy       integer;
  v_hunting    integer;
  v_mv         record;
  v_old_mv     uuid;
  v_o_type     text;
  v_o_base     uuid;
  v_o_zone     uuid;
  v_o_loc      uuid;
  v_o_x        double precision;
  v_o_y        double precision;
  v_t_type     text;
  v_t_loc      uuid;
  v_t_x        double precision;
  v_t_y        double precision;
  v_stats      jsonb;
  v_speed      double precision;
  v_movement   uuid;
  v_arrive     timestamptz;
  v_redirected boolean := false;
  v_max        integer;
  v_active     integer;
  v_base       record;
  v_dock_n     integer;
  v_dock       record;
  v_now        timestamptz := now();
  -- ██ HUNK [G1] (0301): the PLAN envelope from pirate_intercept_plan_leg, and the due-resolution
  -- ██ verdict used by the redirect branch. Neither can move this fleet or open combat by itself.
  v_plan       jsonb;
  v_due        jsonb;
  -- The navigable square. COPIED from mainship_space_begin_move_core (0067:133-134) so a fleet and a
  -- ship agree on the world's edges; it is NOT a second authority. Step 4 retires 0067 — fold these
  -- into one shared bound then rather than leaving two copies.
  c_lo constant double precision := -10000;
  c_hi constant double precision :=  10000;
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gate — reject before ANY read, lock, or write (the 0161/0178 reject-before-read posture).
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) TARGET SHAPE — exactly one of {port} or {coordinate}. Validated BEFORE any read, so a
  --    malformed command never costs a lock (and never leaks whether a group exists).
  --    The 0067 rule, reused: client coordinates are NEVER accepted alongside a location target —
  --    a port's position is the server's to know, not the caller's to assert.
  if p_location_id is not null then
    if p_target_x is not null or p_target_y is not null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
    end if;
    v_t_type := 'location';
  elsif p_target_x is not null and p_target_y is not null then
    v_t_type := 'space';
    if p_target_x = 'NaN'::double precision or p_target_x = 'Infinity'::double precision or p_target_x = '-Infinity'::double precision
       or p_target_y = 'NaN'::double precision or p_target_y = 'Infinity'::double precision or p_target_y = '-Infinity'::double precision then
      return jsonb_build_object('ok', false, 'reason', 'invalid_coordinate');
    end if;
    if p_target_x < c_lo or p_target_x > c_hi or p_target_y < c_lo or p_target_y > c_hi then
      return jsonb_build_object('ok', false, 'reason', 'target_out_of_bounds');
    end if;
    -- canonicalize to the integer world grid (the 0178 rule) BEFORE anything reads it.
    v_t_x := round(p_target_x::numeric)::double precision;
    v_t_y := round(p_target_y::numeric)::double precision;
  else
    -- neither, or a half-specified coordinate.
    return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
  end if;

  -- 4) resolve + LOCK the group. FOR UPDATE (not FOR SHARE): two concurrent go's on the SAME group
  --    must serialize, or both could create a fleet / both redirect. This is the first lock taken;
  --    every other group RPC also takes ship_groups first, so the order is consistent.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- 5) members. Read-only: the members are the fleet's manifest, never movement subjects.
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  v_member_n := coalesce(array_length(v_members, 1), 0);
  if v_member_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

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
  -- ── end 0312 — the head continues verbatim from here ───────────────────────────────────────────

  -- 6) destination: a port must exist, be active, and be NON-COMBAT.
  --    The activity_type check is the SAME rule the legacy per-ship move enforces (0156: active +
  --    non-combat) — composed, not invented. It is a TARGET-legality check, not a readiness branch (§4):
  --    it asks what the destination IS, never where the fleet is.
  --    WHY IT IS LOAD-BEARING: the settle creates a presence carrying the target's activity_type
  --    (0153/this file's location branch), and an activity='hunt_pirates' presence is what
  --    combat_create_encounter routes on. A unified fleet has NO combat_units — it is not a sortie, it
  --    has no group_sortie_members manifest — so it would snapshot zero units and the tick's defeat
  --    branch would DESTROY it on arrival. A move is not a hunt: hunts go through
  --    send_ship_group_hunt (0168/0204), which builds the manifest. Found by the step-3c/4 recon; the
  --    3a/3b proofs never flew to a hunt site so they never saw it.
  if v_t_type = 'location' then
    select l.id, l.x, l.y, l.status, l.zone_id, l.activity_type, z.sector_id
      into v_loc
      from public.locations l
      join public.zones z on z.id = l.zone_id
     where l.id = p_location_id;
    if v_loc.id is null or v_loc.status <> 'active' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_location');
    end if;
    if v_loc.activity_type is distinct from 'none' then
      return jsonb_build_object('ok', false, 'reason', 'combat_destination');
    end if;
    v_t_loc := v_loc.id; v_t_x := v_loc.x; v_t_y := v_loc.y;
    -- ── ★ THE S4 TRANSLATE HUNK (0219, unchanged by this file) — TIMED DOCKING: a DOCKABLE port  ★ ──
    -- ── ★ target becomes its COORDINATE. The fleet parks in orbit inside the port's territory   ★ ──
    -- ── ★ and DOCK is the separate 45s verb (command_ship_group_dock). Dark -> this if is       ★ ──
    -- ── ★ skipped -> byte-identical instant dock.                                                ★ ──
    if public.cfg_bool('timed_docking_enabled')
       and (public.mainship_space_location_target_legal(v_loc.id)->>'ok')::boolean is true then
      v_t_type := 'space'; v_t_loc := null;   -- v_t_x/v_t_y already carry the port's coordinate
    end if;
    -- ── ★ END OF THE S4 TRANSLATE HUNK — the head continues verbatim from here ★ ────────────────
  end if;

  -- 7) TRANSITION GUARD (delete me at step 4, not before).
  --    While the per-ship movers still exist and are flag-ON, a member could be flying its OWN
  --    per-ship fleet. If the group also flew, that ship would be in two places at once — the exact
  --    duality §2 kills. So: no member may hold a live per-ship fleet.
  --    This is NOT the "per-command readiness branch" §4 forbids: it does not gate on where the
  --    fleet IS (there is deliberately no home/docked precondition below). It rejects a state that
  --    only exists because the OLD layer is still alive, and it becomes unreachable — and must be
  --    removed — the moment step 4 retires the per-ship movers.
  select count(*) into v_busy
    from public.fleets f
   where f.player_id = v_player
     and f.main_ship_id = any(v_members)
     and f.status in ('moving', 'returning');
  if v_busy > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_busy');
  end if;

  -- 8) ── ★ THE MID-COMBAT RE-ORDER HUNK (the ONLY delta vs the 0233 head) ★ ──────────────────────
  --    The head counted the group's live sortie and refused, always: 'group_on_sortie'. It now looks
  --    the group's encounter up authoritatively and classifies FOUR ways:
  --      (a) encounter 'active'     -> validate the target, store the destination, and RETREAT via
  --                                    the ONE existing retreat verb -> ok / 'retreat_started'.
  --      (b) encounter 'retreating' -> validate the target and REPLACE the stored destination ONLY.
  --                                    The verb is NOT called again and the window is NOT restarted
  --                                    -> ok / 'retreat_destination_updated'.
  --      (c) TERMINAL/SETTLING      -> the encounter has ended but its fleet is still settling its
  --                                    way out -> typed 'movement_settled_retry' (the head's own
  --                                    vocabulary for "your view is stale, re-issue").
  --      (d) sortie, NO encounter   -> the head's 'group_on_sortie' refusal, unchanged: there is no
  --                                    retreat to compose and steering a committed non-combat sortie
  --                                    is still out of scope — fail closed rather than guess.
  --    No sortie at all -> falls through to step 9, byte-identical to the head.
  --    ORDER MATTERS AND IS UNCHANGED: this is still step 8, so step 6's target legality (the port
  --    must exist, be active and be NON-COMBAT) and step 7's member_busy have already run. A retreat
  --    destination is validated by exactly the same rules as any other move; nothing here re-checks
  --    or relaxes them. The retreat state machine itself is NOT reproduced here — no presence status
  --    write, no timestamps, no damage rule, no reward lock, no window: those live where they always
  --    have (presence_request_leave and process_combat_ticks).
  v_hunting := case when public.group_sortie_is_open(v_player, v_group) then 1 else 0 end;

  declare
    v_enc      record;
    v_settling integer;
  begin
    -- The encounter is read AND LOCKED before this hunk writes anything, and the destination write +
    -- the retreat arming below then happen in this SAME transaction — the tick can never observe half
    -- of it. Lock order combat_encounters -> fleets -> location_presence is the tick's own order, so
    -- the two can never deadlock; if the tick settled this encounter first, the locked re-read simply
    -- no longer matches and we fall through to (c)/(d).
    select ce.id, ce.presence_id, ce.fleet_id, ce.status, ce.total_rewards_json
      into v_enc
      from public.combat_encounters ce
      join public.fleets f on f.id = ce.fleet_id
     where f.group_id = v_group
       and ce.player_id = v_player
       and ce.status in ('active', 'retreating')
     order by ce.created_at desc
     limit 1
     for update of ce;

    if v_enc.id is not null then
      -- ── (a)/(b) THE COMBAT-TIME REDIRECT ──────────────────────────────────────────────────────
      -- ANY DESTINATION THE ORDER COULD NAME. 0292 recorded only a port and refused a coordinate
      -- order typed; 0298 DELETES that refusal and records whichever side of the exactly-one-of pair
      -- the order carried — fleets.retreat_target_location_id for a port, (retreat_target_x,
      -- retreat_target_y) for a point in open space. ONE destination concept in two representations:
      -- one writer (this arm), one reader (the tick's completion branch), and one CHECK constraint
      -- (fleets_retreat_target_one_of) making the exclusivity a fact of the table rather than a
      -- convention. Nothing else about the retreat changes — the fleet still breaks off under fire,
      -- still takes damage for the whole window, and still leaves only when the window expires.
      -- WHICH SHAPE IT IS is decided by p_location_id alone — the parameter the caller actually sent
      -- — and never by v_t_type, which step 6's S4 dock-translate rewrites to 'space' for a DOCKABLE
      -- port under timed_docking_enabled. A port order stays a port order.
      -- The coordinate stored is v_t_x/v_t_y: bound-checked and canonicalized onto the integer world
      -- grid by step 3 before anything read it, so the tick consumes it with no second validation and
      -- the world's edges keep exactly one authority.
      -- CLASSIFY BEFORE WRITING: presence_request_leave demands an ACTIVE presence, so an encounter
      -- that reads 'active' against a presence that no longer does is a settling race — answer it
      -- typed, with NO write left behind, rather than let the verb raise (this RPC returns envelopes,
      -- never raises, at its boundary).
      if v_enc.status = 'active'
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
      -- ── end 0311 — the head continues verbatim from here ───────────────────────────────────────
      -- Store (or REPLACE) the destination — ONE update that sets one side of the exactly-one-of
      -- pair and clears the other in the SAME statement, so fleets_retreat_target_one_of can never be
      -- transiently violated and a re-order can freely switch a port target to an open-space one, or
      -- back. Last write wins; the tick reads it once, at completion.
      update public.fleets
         set retreat_target_location_id = p_location_id,
             retreat_target_x = case when p_location_id is null then v_t_x end,
             retreat_target_y = case when p_location_id is null then v_t_y end,
             updated_at = v_now
       where id = v_enc.fleet_id and player_id = v_player;

      if v_enc.status = 'active' then
        -- (a) FIRST order: arm the retreat through presence_request_leave — the sole retreat
        --     authority (0018:60-69). It is the only thing that may move a presence into retreat, set
        --     its timestamps and start the window; this hunk reproduces none of that.
        perform public.presence_request_leave(v_enc.presence_id);
        return jsonb_build_object(
          'ok', true,
          'order_outcome', 'retreat_started',
          'outcome', 'retreat_started',
          'reason', 'retreat_started',
          'group_id', v_group,
          'fleet_id', v_enc.fleet_id,
          'encounter_id', v_enc.id,
          'presence_id', v_enc.presence_id,
          'member_count', v_member_n,
          'destination_location_id', p_location_id,
          'destination_x', case when p_location_id is null then v_t_x end,
          'destination_y', case when p_location_id is null then v_t_y end,
          -- Loot earned BEFORE the order rides the leg as cargo and is DEPOSITED ON ARRIVAL
          -- (0307): a port destination banks it in the player's store at that port; an open-space
          -- destination banks it at the oldest active store. Choosing a destination costs nothing.
          'carried_rewards', coalesce(v_enc.total_rewards_json, '{}'::jsonb));
      end if;

      -- (b) ALREADY RETREATING: the destination above is the ONLY thing that changed. The retreat
      --     verb is deliberately not called a second time — re-entering it would re-stamp the retreat
      --     clock and hand the player a free reset of the damage window. The window keeps running
      --     from the FIRST order.
      return jsonb_build_object(
        'ok', true,
        'order_outcome', 'retreat_destination_updated',
        'outcome', 'retreat_destination_updated',
        'reason', 'retreat_destination_updated',
        'group_id', v_group,
        'fleet_id', v_enc.fleet_id,
        'encounter_id', v_enc.id,
        'presence_id', v_enc.presence_id,
        'member_count', v_member_n,
        'destination_location_id', p_location_id,
        'destination_x', case when p_location_id is null then v_t_x end,
        'destination_y', case when p_location_id is null then v_t_y end,
        'carried_rewards', coalesce(v_enc.total_rewards_json, '{}'::jsonb));
    end if;

    if v_hunting > 0 then
      -- (c) The sortie's encounter is already TERMINAL while its fleet is still on the way out (the
      --     tick ended the fight and the return leg is in flight). Nothing here can redirect that leg
      --     — the fleet parks itself at the end of it and is commandable again — so answer with the
      --     head's own retryable vocabulary rather than the sortie refusal, which would be a lie.
      select count(*) into v_settling
        from public.combat_encounters ce
        join public.fleets f on f.id = ce.fleet_id
       where f.group_id = v_group
         and ce.player_id = v_player
         and ce.status in ('escaped', 'completed', 'defeat')
         and f.status in ('present', 'returning');
      if v_settling > 0 then
        return jsonb_build_object('ok', false, 'reason', 'movement_settled_retry');
      end if;
      -- (d) a sortie with NO encounter — the head's refusal, unchanged.
      return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
    end if;
  end;
  -- ── ★ END OF THE MID-COMBAT RE-ORDER HUNK — the head continues verbatim from here ★ ────────────

  -- 9) THE MOVER: the group's ONE unified fleet.
  --    Keyed group_id + main_ship_id IS NULL — NOT group_id alone: the legacy expedition send TAGS
  --    group_id onto PER-MEMBER fleets (0204:316, display-only, "routing never reads it"), so
  --    group_id alone would match N member envelopes and pick one at random.
  select count(*) into v_unified_n
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning');
  if v_unified_n > 1 then
    -- Never silently pick one. Two live unified fleets for one group is a broken invariant.
    return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
  end if;

  if v_unified_n = 1 then
    select * into v_fleet_row
      from public.fleets
     where group_id = v_group and player_id = v_player and main_ship_id is null
       and status in ('idle', 'moving', 'present', 'returning')
     for update;
    v_fleet := v_fleet_row.id;
  end if;

  -- 10) ORIGIN — "the fleet moves from wherever it is" (§2). No home/docked precondition.
  --    STRUCTURE NOTE: the `v_fleet is null` bootstrap MUST be the first branch, so the later branches
  --    only ever touch v_fleet_row once it is assigned. Do NOT rewrite this as
  --    `if v_fleet is not null and v_fleet_row.status = ...` — SQL's AND does not guarantee
  --    left-to-right short-circuit, and reading a field of an unassigned RECORD raises
  --    "record is not assigned yet" regardless of the guard. (The CI proof caught exactly that.)
  if v_fleet is null then
    -- ── BOOTSTRAP (transition-only): the group has no fleet yet, so its position must be derived
    --    ONCE from its members' per-ship state — the only place this function reads ship state as a
    --    position, and only to create the group's first fleet. After step 4 ships have no position
    --    and a group's fleet is created with the group, so this branch disappears.
    select count(distinct lp.location_id) into v_dock_n
      from public.main_ship_instances s
      join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
     where s.main_ship_id = any(v_members);

    if v_dock_n = 1 then
      select lp.location_id, lp.zone_id, l.x, l.y into v_dock
        from public.main_ship_instances s
        join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
        join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
        join public.locations l on l.id = lp.location_id
       where s.main_ship_id = any(v_members)
       limit 1;
      v_o_type := 'location'; v_o_base := null; v_o_zone := v_dock.zone_id; v_o_loc := v_dock.location_id;
      v_o_x := v_dock.x; v_o_y := v_dock.y;
    elsif v_dock_n = 0 then
      select b.id, b.x, b.y, b.sector_id into v_base
        from public.bases b where b.player_id = v_player and b.status = 'active'
        order by b.created_at limit 1;
      if v_base.id is null then
        return jsonb_build_object('ok', false, 'reason', 'no_origin');
      end if;
      v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
      v_o_x := v_base.x; v_o_y := v_base.y;
    else
      -- Members split across ports: the group has no single position to depart from. BOOTSTRAP-only
      -- (the old world let ships scatter); once the fleet exists it always has exactly one position.
      return jsonb_build_object('ok', false, 'reason', 'group_scattered');
    end if;

  elsif v_fleet_row.active_movement_id is not null then
    -- ── REDIRECT: cancel the live leg at its INTERPOLATED point, then depart from there. ─────────
    select * into v_mv
      from public.fleet_movements
     where id = v_fleet_row.active_movement_id
     for update;
    if v_mv.id is null or v_mv.status <> 'moving' then
      -- The settle cron took it between our reads; the fleet is no longer where we thought.
      -- Fail closed and let the caller re-issue against fresh state rather than guess.
      return jsonb_build_object('ok', false, 'reason', 'movement_settled_retry');
    end if;

    -- ██ HUNK [G2] (0301) — A RE-ORDER MAY NOT OUTRUN AN AMBUSH THAT IS ALREADY OWED. ██████████████
    -- The movement is locked; resolve any DUE intercept in the SAME transaction, before this order
    -- gets to cancel the leg. This closes the window between trigger_at and the next cron tick, in
    -- which a player who saw the fleet touch a zone could otherwise re-order out of the ambush.
    -- If it FIRES the fleet is in combat now and this order is not a move any more — refuse typed and
    -- let the caller re-issue, which lands on step 8's retreat verb. If it does NOT fire, the leg is
    -- legitimately being replaced, so whatever it still owed is cancelled and the NEW leg is rolled
    -- from scratch below. Lock order (movement -> intercept -> fleet) is the resolver's own.
    -- The resolver is deliberately NOT raise-free (a half-opened fight must roll back). This RPC IS
    -- raise-free at its boundary, so the call is fenced — and the fence FAILS THE ORDER rather than
    -- letting it through, because "the ambush could not be resolved" must never mean "so you may go".
    begin
      v_due := public.pirate_intercept_resolve_due_for_movement(v_mv.id);
    exception when others then
      raise warning 'command_ship_group_go: intercept resolution failed for movement % (order REFUSED): %',
        v_mv.id, sqlerrm;
      return jsonb_build_object('ok', false, 'reason', 'intercept_resolution_failed');
    end;
    if coalesce((v_due->>'fired')::boolean, false) then
      return jsonb_build_object('ok', false, 'reason', 'intercepted_in_transit',
                                'encounter_id', v_due->>'encounter_id');
    end if;
    perform public.pirate_intercept_cancel_pending_for_movement(v_mv.id, 'movement_superseded');
    -- ██ END HUNK [G2] ████████████████████████████████████████████████████████████████████████████

    -- ── ★ THE S3 FOLD HUNK — the inline lerp is a compose of movement_position_at, the ONE      ★ ──
    -- ── ★ interpolation authority. Output-identical by construction; the self-assert re-proves  ★ ──
    -- ── ★ it at deploy time — so NO new flag.                                                    ★ ──
    select o_x, o_y into v_o_x, v_o_y
      from public.movement_position_at(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y,
                                       v_mv.depart_at, v_mv.arrive_at, v_now);
    -- ── ★ END OF THE S3 FOLD HUNK — the head continues verbatim from here ★ ────────────────────
    v_o_type := 'space';   -- allowed by fleet_movements_origin_type_check since 0156
    v_o_base := null; v_o_zone := null; v_o_loc := null;
    v_old_mv := v_mv.id;
    v_redirected := true;

  elsif v_fleet_row.location_mode = 'space' then
    -- ── FLEET-GO 3b: the fleet is PARKED in open space at its own coordinate. Depart from there.
    --    This is the branch that makes the model closed: a coordinate arrival (the settle's new
    --    'space' branch) leaves the fleet here, and it can set off again without ever touching a port.
    v_o_type := 'space'; v_o_base := null; v_o_zone := null; v_o_loc := null;
    v_o_x := v_fleet_row.space_x; v_o_y := v_fleet_row.space_y;

  elsif v_fleet_row.status = 'present' and v_fleet_row.current_location_id is not null then
    -- Parked at a port: depart from that port.
    select l.id, l.x, l.y, l.zone_id into v_dock
      from public.locations l where l.id = v_fleet_row.current_location_id;
    if v_dock.id is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_origin');
    end if;
    v_o_type := 'location'; v_o_base := null; v_o_zone := v_dock.zone_id; v_o_loc := v_dock.id;
    v_o_x := v_dock.x; v_o_y := v_dock.y;

  else
    -- The group's fleet exists but is neither in flight, in space, nor docked (idle / returning with
    -- no leg). Its anchor is its origin base — the same anchor the hunt uses for return mechanics.
    -- Not a rejection: §2 says the fleet moves from wherever it is, and "at its anchor" is a place.
    select b.id, b.x, b.y, b.sector_id into v_base
      from public.bases b
     where b.player_id = v_player and b.status = 'active'
       and (v_fleet_row.origin_base_id is null or b.id = v_fleet_row.origin_base_id)
     order by b.created_at limit 1;
    if v_base.id is null then
      return jsonb_build_object('ok', false, 'reason', 'no_origin');
    end if;
    v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
    v_o_x := v_base.x; v_o_y := v_base.y;
  end if;

  -- 11) SPEED — D0's authoritative group stats (0166): delegates per-member to 0122, sums additive
  --     keys, takes speed = MIN over members, and raises rather than clamping. Reused, not re-folded.
  begin
    v_stats := public.calculate_group_expedition_stats(v_player, v_group, 'none');
  exception when others then
    -- 0166 is STRICT by design (refuse-don't-clamp): a member's bad stats raise and refuse the whole
    -- team context. Caught here and returned as an envelope — this RPC never raises at its boundary.
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;
  -- NOTE: 0166 nests the folds under 'totals' — `v_stats->>'speed'` is NULL at the top level and
  -- silently degrades to stats_invalid. (The CI proof caught exactly that.)
  v_speed := (v_stats->'totals'->>'speed')::double precision;
  if v_speed is null or not (v_speed > 0) then
    -- fleet_movements_speed_used_check demands > 0; reject rather than feed the spine a bad row.
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end if;

  -- 12) fleet budget — only when this call would CREATE a fleet. A redirect/re-launch of the group's
  --     existing fleet consumes no new slot.
  if v_fleet is null then
    v_max := coalesce(public.cfg_num('max_active_fleets'), 3);
    select count(*) into v_active
      from public.fleets
     where player_id = v_player and status in ('moving', 'present', 'returning');
    if v_active >= v_max then
      return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
    end if;
  end if;

  -- ── WRITES ─────────────────────────────────────────────────────────────────────────────────────
  -- NOTE FOR EVERY FUTURE READER: there is deliberately NO `update main_ship_instances` below.
  -- That absence is the charter's §2. If you are here to add one, re-read §2 and §0 first.

  -- ★ DISSOLVE THE MEMBERS' OWN DOCKS — the ships leave the port to fly with the fleet. ★
  -- This is send_ship_group_hunt's block (0204:664-676), composed verbatim rather than re-invented.
  perform public.presence_complete(lp.id)
    from public.fleets f
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
   where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
  update public.fleets
     set status = 'completed', location_mode = 'movement', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = v_now
   where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

  if v_redirected then
    -- Retire the cancelled leg BEFORE the fleet is re-pointed (fleets_movement_pointers_exclusive).
    update public.fleet_movements
       set status = 'cancelled', resolved_at = v_now
     where id = v_old_mv and status = 'moving';
  end if;

  if v_fleet is null then
    -- The group's ONE fleet: the hunt's proven shape (main_ship_id NULL + group_id set).
    -- origin_base_id anchors the existing return-to-base mechanics, exactly as the hunt does.
    -- Born 'idle' — which is precisely what fleet_set_moving demands below.
    select b.id into v_base
      from public.bases b where b.player_id = v_player and b.status = 'active'
      order by b.created_at limit 1;
    insert into public.fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
      values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
      returning id into v_fleet;
  else
    -- Return the group's EXISTING fleet to 'idle' so fleet_set_moving's frozen precondition holds.
    perform public.presence_complete(lp.id)
      from public.location_presence lp
     where lp.fleet_id = v_fleet and lp.status = 'active';
    update public.fleets
       set status = 'idle', location_mode = 'movement', active_movement_id = null,
           space_x = null, space_y = null,
           current_location_id = null, current_zone_id = null, current_sector_id = null,
           updated_at = v_now
     where id = v_fleet;
  end if;

  -- ONE movement for the ONE fleet. mission 'rally' = the spine's generic reposition
  -- (fleet_movements_mission_type_check). For a 'space' target the location id is NULL and the
  -- coordinate carries the destination; for a port it is the reverse (0067's target-shape rule).
  v_movement := public.movement_create(
    v_player, v_fleet,
    v_o_type, v_o_base, v_o_zone, v_o_loc, v_o_x, v_o_y,
    v_t_type, null, null, v_t_loc, v_t_x, v_t_y,
    'rally', v_speed);

  perform public.fleet_set_moving(v_fleet, v_movement);

  -- ██ HUNK [G3] (0301) — THE LEG IS PLANNED, NOT AMBUSHED. ███████████████████████████████████████
  -- The leaf's OWN first statement is the pirate_intercept_enabled gate, so this is a true no-op
  -- while dark. When lit it rolls, records, and RETURNS — the movement it was handed is still
  -- 'moving' when this line finishes, the fleet has not been touched, and no encounter exists. The
  -- ambush it may have scheduled is fired later, by the movement processor, when the fleet arrives
  -- at the zone's edge.
  v_plan := public.pirate_intercept_plan_leg(v_movement);
  -- ██ END HUNK [G3] ███████████████████████████████████████████████████████████████████████████████

  select arrive_at into v_arrive from public.fleet_movements where id = v_movement;

  -- ██ HUNK [G4] (0301) — THE ENVELOPE. The two retired ambush fields are REMOVED, not kept as
  -- ██ shims: this call can no longer know either, and returning a predicted ambush would leak a
  -- ██ random result the player has not lived through yet. Nothing about a planned intercept is
  -- ██ surfaced here at all. movement_eta names the same instant arrive_at always did.
  -- ██ (Their names are deliberately NOT written here: the self-assert greps this very body for them
  -- ██ as MUST-BE-ABSENT, and a probe matching its own explanatory comment is how 0222 aborted every
  -- ██ deploy. The comment stripper would handle it; not relying on the stripper is cheaper.)
  return jsonb_build_object(
    'ok', true,
    'order_outcome', 'movement_started',
    'group_id', v_group,
    'fleet_id', v_fleet,
    'movement_id', v_movement,
    'movement_eta', v_arrive,
    'arrive_at', v_arrive,
    'member_count', v_member_n,
    'redirected', v_redirected,
    'origin_type', v_o_type,
    'target_type', v_t_type,
    'target_x', v_t_x,
    'target_y', v_t_y);
end;
$function$;

CREATE OR REPLACE FUNCTION public.command_ship_group_dock(p_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player    uuid := auth.uid();
  v_group     uuid;
  v_gf        public.fleets%rowtype;
  v_gf_n      integer;
  v_hunting   integer;
  v_fleet     uuid;
  v_fleet_row record;
  v_port      uuid;
  v_loc       record;
  v_stats     jsonb;
  v_speed     double precision;
  v_o_x       double precision;
  v_o_y       double precision;
  v_movement  uuid;
  v_secs      double precision;
  v_arrive    timestamptz;
  v_now       timestamptz := now();
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gates — reject before ANY read, lock, or write (the 0161/0178 reject-before-read
  --    posture): the S4 flag FIRST, then the unification gate the whole fleet layer lives behind.
  if not public.cfg_bool('timed_docking_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'timed_docking_disabled');
  end if;
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) resolve + LOCK the group (0208:270-277 verbatim): FOR UPDATE, the same first lock every
  --    group RPC takes, so a dock serializes against a concurrent go/stop/hunt on the same group.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

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
  -- ── end 0312 — the head continues verbatim from here ───────────────────────────────────────────

  -- 4) 0305: the ONE sortie authority. A fight that is genuinely open still refuses a dock; a
  --    finished one no longer does, because "finished" is now a fact and not a leftover row.
  if public.group_sortie_is_open(v_player, v_group) then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;

  -- 5) the group's ONE live fleet through the 0213 leaf (composed, never a fifth inline copy of
  --    the shape) — the 0214 one-scan count+capture idiom (one READ COMMITTED snapshot; never
  --    count in one statement and re-select in another). Then re-take the row FOR UPDATE by id.
  v_gf_n := 0;
  for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_group) loop
    v_gf_n := v_gf_n + 1;
  end loop;
  if v_gf_n > 1 then
    -- Two live group-shaped fleets is the broken invariant — never pick one (the mover's token).
    return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
  end if;
  if v_gf_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_fleet');
  end if;
  select * into v_fleet_row from public.fleets where id = v_gf.id for update;
  v_fleet := v_fleet_row.id;

  -- 6) PARKED guard — dock is FROM ORBIT only: the fleet must be holding in open space at its own
  --    coordinate (the exact state the translated go's settle leaves it in, and the brake's HOLD
  --    state). Everything else — docked already, in flight, at a base — is not_parked. Judged on
  --    the POST-LOCK row, so a settle/go racing this call cannot slip a stale state through.
  if not (v_fleet_row.status = 'idle'
          and v_fleet_row.location_mode = 'space'
          and v_fleet_row.space_x is not null and v_fleet_row.space_y is not null
          and v_fleet_row.active_movement_id is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_parked');
  end if;

  -- 7) TERRITORY guard — the S3 leaf IS the authority (fleet_current_position + osn_distance +
  --    territory_radius; smallest-radius/lowest-id tiebreak). NULL = open space = nothing to dock
  --    at. The 0104/0172 definer-composition precedent: the leaf is service_role-only and this
  --    SECURITY DEFINER body composes it with the definer's rights.
  v_port := public.fleet_in_territory(v_fleet);
  if v_port is null then
    return jsonb_build_object('ok', false, 'reason', 'not_in_territory');
  end if;

  -- 8) DOCKABLE guard — the SAME predicate the settle's dock hunk uses (0067's ONE legality rule:
  --    active hierarchy + city|port role + activity 'none' + one active docking service + one
  --    active in-bounds anchor). Composed, never re-derived — a port this refuses is exactly a
  --    port the settle would refuse to dock a main ship at.
  if (public.mainship_space_location_target_legal(v_port)->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', 'not_dockable');
  end if;
  select l.id, l.x, l.y, l.zone_id into v_loc from public.locations l where l.id = v_port;

  -- 9) SPEED — the mover's fold VERBATIM (0208:465-478): D0's strict group stats; raises →
  --    stats_invalid; the folds nest under 'totals'. Kept for the movement_create contract
  --    (speed_used > 0) even though the transform below overwrites the derived clock.
  begin
    v_stats := public.calculate_group_expedition_stats(v_player, v_group, 'none');
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;
  v_speed := (v_stats->'totals'->>'speed')::double precision;
  if v_speed is null or not (v_speed > 0) then
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end if;

  -- ── WRITES ─────────────────────────────────────────────────────────────────────────────────────
  -- NOTE FOR EVERY FUTURE READER: there is deliberately NO `update main_ship_instances` below.
  -- That absence is the charter's §2 — the settle's own dock hunk writes the ship, not this verb.

  -- Capture the origin FIRST (the release below clears it), then the mover's re-launch release
  -- VERBATIM (0218's else-branch): close any active presence (a no-op for a space-parked fleet —
  -- kept for shape parity with the mover), release the fleet into the idle/movement shape
  -- fleet_set_moving demands, and clear the parked coordinate — the fleet is under way.
  v_o_x := v_fleet_row.space_x; v_o_y := v_fleet_row.space_y;
  perform public.presence_complete(lp.id)
    from public.location_presence lp
   where lp.fleet_id = v_fleet and lp.status = 'active';
  update public.fleets
     set status = 'idle', location_mode = 'movement', active_movement_id = null,
         space_x = null, space_y = null,
         current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = v_now
   where id = v_fleet;

  -- ONE movement for the ONE fleet: a NORMAL location-target leg, mission 'dock' — the settle's
  -- untouched location branch (0208:112-141) is what docks it on arrival.
  v_movement := public.movement_create(
    v_player, v_fleet,
    'space', null, null, null, v_o_x, v_o_y,
    'location', null, v_loc.zone_id, v_port, v_loc.x, v_loc.y,
    'dock', v_speed);

  -- ★ THE FLAT CLOCK — the 0149:116-134 transform idiom (mint, then overwrite the SAME row's clock
  -- under this txn's constant now()): arrive_at − depart_at = EXACTLY v_secs, because
  -- movement_create's depart_at is the same txn-constant now() as v_now. The one marked soft spot
  -- of this slice (kept over widening the 16-arg movement_create); the self-assert + CI pin the
  -- exact 45. The `status = 'moving'` guard mirrors 0149: if anything settled the row between the
  -- mint and here (impossible in one txn — kept for the idiom's shape), this touches nothing. ★
  v_secs := coalesce(public.cfg_num('docking_seconds'), 45);
  update public.fleet_movements
     set arrive_at = v_now + make_interval(secs => v_secs),
         travel_seconds = v_secs
   where id = v_movement and status = 'moving';

  perform public.fleet_set_moving(v_fleet, v_movement);

  select arrive_at into v_arrive from public.fleet_movements where id = v_movement;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'fleet_id', v_fleet,
    'movement_id', v_movement,
    'port_id', v_port,
    'arrive_at', v_arrive);
end;
$function$;

CREATE OR REPLACE FUNCTION public.command_ship_group_stop(p_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player   uuid := auth.uid();
  v_group    uuid;
  v_fleet    uuid;
  v_fleet_row record;
  v_unified_n integer;
  v_hunting   integer;
  v_mv       record;
  v_x        double precision;
  v_y        double precision;
  v_now      timestamptz := now();
  -- 0301: the due-resolution verdict. Cannot move this fleet or open combat by itself.
  v_due      jsonb;
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gate — reject before ANY read, lock, or write.
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) resolve + LOCK the group. FOR UPDATE, the same first lock the mover takes.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- ── 0305: STOP ALWAYS WORKS. ───────────────────────────────────────────────────────────────
  -- The 0215 refusal is GONE. It asked "does this group hold a frozen roster AND is a fleet
  -- moving?" — but a roster is written once and never released, and ordinary travel sets a fleet
  -- 'moving', so after a single fight every ordinary trip could be started and never stopped.
  -- An open fight is now answered, not refused: the brake composes with presence_request_leave,
  -- the SAME retreat authority the mover's arm (a) uses (0301:1726). It does not reproduce the
  -- retreat — no window, no clock, no damage rule — and it never re-enters the verb on a retreat
  -- already running, so Stop can never hand back a free reset of the damage window.
  -- A sortie LEG with no encounter (outbound hunt / the way home) falls through to the ordinary
  -- brake below and simply stops: that is the capability the owner asked for.
  if public.group_sortie_is_open(v_player, v_group) then
    declare
      v_enc record;
    begin
      select ce.id, ce.presence_id, ce.fleet_id, ce.status
        into v_enc
        from public.combat_encounters ce
        join public.fleets f on f.id = ce.fleet_id
       where f.group_id = v_group
         and ce.player_id = v_player
         and ce.status in ('active', 'retreating')
       order by ce.created_at desc
       limit 1
       for update of ce;
      if v_enc.id is not null then
        -- 'active' against a presence that is no longer active is the settling race the mover
        -- already names: answer it typed, leave no write behind (0301:1706-1710).
        if v_enc.status = 'active'
           and exists (select 1 from public.location_presence lp
                        where lp.id = v_enc.presence_id and lp.status = 'active') then
          perform public.presence_request_leave(v_enc.presence_id);
          return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_enc.fleet_id,
                                    'stopped', false, 'reason_code', 'retreat_started',
                                    'encounter_id', v_enc.id, 'presence_id', v_enc.presence_id);
        end if;
        return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_enc.fleet_id,
                                  'stopped', false, 'reason_code', 'retreat_already_underway',
                                  'encounter_id', v_enc.id, 'presence_id', v_enc.presence_id);
      end if;
    end;
  end if;
  -- ── end 0305 ───────────────────────────────────────────────────────────────────────────────

  -- 4) the group's ONE unified fleet.
  select count(*) into v_unified_n
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning');
  if v_unified_n > 1 then
    return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
  end if;
  if v_unified_n = 0 then
    return jsonb_build_object('ok', true, 'group_id', v_group, 'stopped', false, 'reason_code', 'no_fleet');
  end if;

  select * into v_fleet_row
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning')
   for update;
  v_fleet := v_fleet_row.id;

  -- 5) not in flight → nothing to halt. Idempotent.
  if v_fleet_row.active_movement_id is null then
    return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_fleet,
                              'stopped', false, 'reason_code', 'not_moving');
  end if;

  select * into v_mv
    from public.fleet_movements
   where id = v_fleet_row.active_movement_id
   for update;
  if v_mv.id is null or v_mv.status <> 'moving' then
    return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_fleet,
                              'stopped', false, 'reason_code', 'already_settled');
  end if;

  -- ██ HUNK [S1] (0301) — THE BRAKE MAY NOT OUTRUN AN AMBUSH THAT IS ALREADY OWED. ████████████████
  -- Same reasoning and same lock order as command_ship_group_go's [G2]. Fired -> the fleet is in a
  -- fight and the brake is refused; not fired -> the leg is legitimately being ended here, so what it
  -- still owed is cancelled with the player's own reason.
  -- Fenced for the same reason as the mover's [G2], and it fails the BRAKE rather than letting it
  -- through: an unresolvable ambush must never be an escape hatch.
  begin
    v_due := public.pirate_intercept_resolve_due_for_movement(v_mv.id);
  exception when others then
    raise warning 'command_ship_group_stop: intercept resolution failed for movement % (brake REFUSED): %',
      v_mv.id, sqlerrm;
    return jsonb_build_object('ok', false, 'reason', 'intercept_resolution_failed');
  end;
  if coalesce((v_due->>'fired')::boolean, false) then
    return jsonb_build_object('ok', false, 'reason', 'intercepted_in_transit',
                              'encounter_id', v_due->>'encounter_id');
  end if;
  perform public.pirate_intercept_cancel_pending_for_movement(v_mv.id, 'player_stop');
  -- ██ END HUNK [S1] ██████████████████████████████████████████████████████████████████████████████

  -- 6) WHERE IT ACTUALLY IS. Byte-identical to the mover's redirect interpolation — a redirect is
  --    "stop here, then go there", so both must agree on "here".
  -- ── ★ THE S3 FOLD HUNK (2 of 2) — the same movement_position_at compose the mover uses.      ★ ──
  select o_x, o_y into v_x, v_y
    from public.movement_position_at(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y,
                                     v_mv.depart_at, v_mv.arrive_at, v_now);
  -- ── ★ END OF THE S3 FOLD HUNK — the 0215 head continues verbatim from here ★ ────────────────

  -- ── WRITES ─────────────────────────────────────────────────────────────────────────────────────
  -- NOTE FOR EVERY FUTURE READER: there is deliberately NO `update main_ship_instances` below.

  update public.fleet_movements
     set status = 'cancelled', resolved_at = v_now
   where id = v_mv.id and status = 'moving';

  -- STOP = HOLD (the 0155 semantic, kept): the fleet holds position in open space at the turn point.
  perform public.fleet_set_in_space(v_fleet, v_x, v_y);

  -- ── 0305: ABORTING A SORTIE RELEASES ITS ROSTER. ───────────────────────────────────────────
  -- The roster had a beginning (send_ship_group_hunt freezes it) and NO END — that is the whole
  -- defect this migration exists for. Its only consumers are the encounter builders
  -- (combat_create_group_encounter / combat_create_encounter, 0168), which read it to decide WHO
  -- fights; nothing else reads it, and battle reports do not. So a roster left on a fleet the
  -- player has just recalled is not history — it is a stale answer waiting to be given to the
  -- NEXT fight, because the freeze is idempotent (ON CONFLICT DO NOTHING, the 0303 defect).
  -- This is reached ONLY when the brake actually halted the fleet, which by construction means
  -- no encounter was open (an open fight returned above, through the retreat compose) and no
  -- ambush was owed (hunk [S1] refused the brake if one fired). Scoped to THIS fleet, inside the
  -- player's own explicit order. No backfill, no other fleet, no other player.
  -- 0308: the release is now THE one idiom, public.group_sortie_release — same delete, same
  -- fleet+caller scope, one definition (the ambush freeze composes the very same one).
  perform public.group_sortie_release(v_player, v_fleet);
  -- ── end 0305 ───────────────────────────────────────────────────────────────────────────────

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'fleet_id', v_fleet,
    'stopped', true,
    'cancelled_movement_id', v_mv.id,
    'space_x', v_x,
    'space_y', v_y);
end;
$function$;

CREATE OR REPLACE FUNCTION public.send_ship_group_hunt(p_group_id uuid, p_location uuid, p_return_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player   uuid := auth.uid();
  v_group    uuid;
  v_members  uuid[];
  v_locked   integer;
  v_not_home integer;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_base     record;
  v_ship     uuid;
  v_stats    jsonb;
  v_ms       double precision;
  v_power    double precision;
  v_speed    double precision;
  v_fleet    uuid;
  v_movement uuid;
  v_arrive   timestamptz;
  -- NOHOME (0199): the gate + docked-launch working set. Dark seed → false → the 0168 head runs verbatim.
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
  v_docked   integer;   -- members currently docked, per FLEET TRUTH (0221 R1-f / 2a's b5 repoint)
  v_dockcount integer;  -- distinct docked ports across the members (must be exactly 1)
  v_dock_loc uuid;      -- the ONE common docked port (all members) — the launch origin
  v_cur      record;    -- docked-port coordinates + zone/sector
  v_return   uuid;      -- chosen (or origin) return port recorded on the team fleet
  -- FLEET-CONTROL (0204): the gate, read ONCE. Dark seed → false → the command-ship hunk is skipped and the
  -- 0199 body runs verbatim.
  v_fleet_control boolean := public.cfg_bool('fleet_control_enabled');
  -- HUNT-UNI (0214) HUNK A: the unification gate, read ONCE at the top (the 0204/0213 idiom directly
  -- above, verbatim). Dark seed → false → Hunk B below keeps the head's FOR SHARE and Hunk C is
  -- skipped entirely — a side-effect-free stable read is the WHOLE dark delta of this migration.
  v_unified boolean := public.cfg_bool('fleet_movement_unified_enabled');
  v_gf_n    integer;              -- live group-shaped fleets found by the 0213 leaf
  v_gf      public.fleets%rowtype; -- the ONE such fleet, when v_gf_n = 1
  v_busy    integer;              -- members flying their OWN per-ship fleet (the guard-7 read, F2)
  v_gfl     record;               -- the consumed fleet's port row (coords for the origin)
  v_o_type  text;                 -- sortie origin, captured FROM THE FLEET (the 0208 arm naming)
  v_o_base  uuid;
  v_o_zone  uuid;
  v_o_loc   uuid;
  v_o_x     double precision;
  v_o_y     double precision;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- HUNT-UNI (0214) HUNK B: lock STRENGTH only — the statement and the envelope are the head's
  -- either way. LIT takes FOR UPDATE so this hunt SERIALIZES against command_ship_group_go/stop's
  -- group FOR UPDATE (0208:274, 0209:66) and 0213's lit assign arm: a hunt and a go that interleave
  -- their fleet reads could BOTH mint — the exact two-fleet catastrophe this migration exists to
  -- kill, arriving by race instead of by readiness hole. Whoever commits second re-reads the leaf
  -- under the lock and sees the other's fleet. DARK keeps FOR SHARE byte-identically — the lock
  -- footprint is part of parity (the 0213 rule). AT STEP 4 (flag permanently lit): collapse to the
  -- FOR UPDATE arm.
  if v_unified then
    perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  else
    perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  if array_length(v_members, 1) is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- FLEET-CONTROL (0204): the ONE marked command-ship hunk. DARK — skipped (v_fleet_control false) → 0199
  -- behavior. LIT — a fleet with zero command ships is INACTIVE and cannot hunt: reject before the
  -- destination/readiness reads (the fleet's own property).
  if v_fleet_control then
    if not exists (
      select 1 from public.main_ship_instances
       where group_id = v_group and player_id = v_player and is_command_ship
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fleet_inactive_no_command');
    end if;
  end if;

  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, l.min_power_required, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' or v_loc.activity_type is distinct from 'hunt_pirates' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_location');
  end if;

  select count(*) into v_locked from (
    select main_ship_id from public.main_ship_instances
     where main_ship_id = any(v_members) and player_id = v_player
     for update
  ) locked;
  if v_locked <> array_length(v_members, 1) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- HUNT-UNI (0214) HUNK C: lit only — the hunt CONSUMES the settled unified fleet; readiness IS
  -- the fleet. Dark skips straight to the head's readiness, so the head's flow is untouched.
  -- Composes the 0213 leaf (ship_group_resolve_fleet) with ONE scan that counts and captures (one
  -- READ COMMITTED snapshot — the 0213 Finding-3 rule: never count in one statement and re-select
  -- in another). Policy over the rows:
  --   >1 → fleet_ambiguous (fail closed — the mover/brake/0213 token for this broken invariant);
  --   =1 moving/returning → group_fleet_in_flight (the mover's guard-8 twin: no hunt during a go);
  --   =1 settled → capture the origin FROM THE FLEET, consume it terminally, mint (below);
  --   =0 → fall through — the head's arms run VERBATIM (bootstrap parity: a pre-first-go group
  --        still carries per-ship dock shapes and the 0199 lit arm is the right reader for them).
  if v_unified then
    v_gf_n := 0;
    for v_gf in select * from public.ship_group_resolve_fleet(v_player, v_group) loop
      v_gf_n := v_gf_n + 1;
    end loop;
    if v_gf_n > 1 then
      -- Two live group-shaped fleets is the broken invariant this migration exists to prevent —
      -- never mint a third on top of it. Same fail-closed token as the mover/brake/assign guard.
      return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
    end if;
    if v_gf_n = 1 then
      if v_gf.status in ('moving', 'returning') then
        -- The group's ONE fleet is under way (a go in flight, or a sortie leg flying). A hunt is a
        -- commitment from a settled position, not a redirect of a live leg — fail closed. NOTE this
        -- status read alone is NOT the mover's guard-8 twin — guard 8 (0208:332-343) reads the
        -- MANIFEST; the manifest read is the NEXT arm, and the two arms together are the twin.
        return jsonb_build_object('ok', false, 'reason', 'group_fleet_in_flight');
      end if;

      -- AN OPEN SORTIE IS NEVER CONSUMABLE (the 0214 review's F1 — HIGH). A hunt's sortie fleet
      -- sits 'present' AT ITS HUNT SITE for the whole encounter (0169's race pin says it in words:
      -- 'present' = MID-COMBAT), so the status arm above waves it through — and "consuming" it
      -- would presence_complete the LIVE encounter's presence and complete the fleet under it,
      -- then the escape/extract tick (0169:210-230) runs fleet_set_returning on a completed
      -- fleet: a wedged encounter raising every tick, or a resurrected 'returning' fleet → v_n=2
      -- → the map blackout this migration exists to kill, re-minted by its own consume. The dark
      -- head rejected this for free (members read 'hunting' → member_not_ready); the lit hp-only
      -- readiness removed that guard, and THIS is its replacement — the mover's guard-8 manifest
      -- read, with 0213's token and posture (0213:250-268: a sortie is a frozen-roster
      -- commitment; nothing joins it, nothing consumes it). v_gf is live by the leaf's
      -- definition, so ANY manifest row on it IS an open sortie (finished fleets are outside the
      -- leaf's status set).
      -- 0305: the ONE sortie authority. This copy was a bare EXISTS over group_sortie_members —
      -- no join, no scope — i.e. "has this fleet EVER been on a sortie". It is gone.
      if public.group_sortie_is_open(v_player, v_group) then
        return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
      end if;

      -- SETTLED. The per-ship home/stationary readiness is deliberately NOT read here: the unified
      -- mover writes no ship rows (§2), so those signals are stale echoes of the retired layer —
      -- the settled fleet IS the readiness. What survives is the hp > 0 check: lifecycle, not
      -- movement (the same split step 4c preserves when it narrows the status column).
      select count(*) into v_not_home
        from public.main_ship_instances
        where main_ship_id = any(v_members) and hp <= 0;
      if v_not_home > 0 then
        return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
      end if;

      -- TRANSITION GUARD (the 0214 review's F2 — delete me at step 4 alongside the mover's guard 7,
      -- 0208:315-330, whose read this composes verbatim). While the per-ship movers are still live,
      -- a member could be flying its OWN per-ship fleet; the hp-only readiness above would mint it
      -- 'hunting' and its per-ship leg would later settle present + active presence — a ship
      -- hunting AND docked at once (§0 through a third door). The dark head rejects this via its
      -- status readiness ('traveling'/'returning' are neither home nor docked); the lit consume
      -- path must therefore carry the mover's own guard. One bounded count over fleets.
      select count(*) into v_busy
        from public.fleets f
       where f.player_id = v_player
         and f.main_ship_id = any(v_members)
         and f.status in ('moving', 'returning');
      if v_busy > 0 then
        return jsonb_build_object('ok', false, 'reason', 'member_busy');
      end if;

      -- Active-fleet limit EXCLUDING the fleet being consumed below AND the members' own present
      -- fleets (both are dissolved by this call — the head's launch-branch budget idiom, 0204:630-637,
      -- with the consumed unified fleet excluded on top: the sortie replaces them all, one slot net).
      v_max := coalesce(cfg_num('max_active_fleets'), 3);
      select count(*) into v_active
        from fleets
        where player_id = v_player and status in ('moving','present','returning')
          and id <> v_gf.id
          and (main_ship_id is null or not (main_ship_id = any(v_members)));
      if v_active >= v_max then
        return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
      end if;

      -- Team stats over the LOCKED members (the 0168 fold verbatim; raises → stats_invalid).
      v_power := 0;
      v_speed := null;
      begin
        foreach v_ship in array v_members loop
          v_stats := public.calculate_expedition_stats(v_player, v_ship, '[]'::jsonb, 'pirate_hunt');
          v_power := v_power + coalesce((v_stats->>'combat_power')::double precision, 0);
          v_ms    := (v_stats->>'speed')::double precision;
          v_speed := least(coalesce(v_speed, v_ms), v_ms);
        end loop;
      exception when others then
        return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
      end;
      if v_power < coalesce(v_loc.min_power_required, 0) then
        return jsonb_build_object('ok', false, 'reason', 'power_below_required');
      end if;

      -- origin_base anchors the return-to-base mechanics — the escape/extract tick reads
      -- origin_base_id off the sortie fleet (0169:217-228) on EVERY sortie, which is why the head
      -- rejects no_home_base on every mint path and why this select cannot move into the anchor
      -- arm alone (a present/space sortie with a NULL anchor would strand the escape tick).
      -- The HEAD's OWN select, verbatim (0204:657-659): plain first-active-base, NO preference for
      -- the consumed fleet's origin_base_id — the 0214 review's F3: a preference on a STALE anchor
      -- (base no longer active) dead-ends every consuming hunt even when other active bases exist.
      select id, x, y, sector_id into v_base
        from bases where player_id = v_player and status = 'active'
        order by created_at limit 1;
      if v_base.id is null then
        return jsonb_build_object('ok', false, 'reason', 'no_home_base');
      end if;

      -- ── THE ORIGIN, FROM THE FLEET (the mover's three settled arms, 0208:430-461, read the same
      --    way): present@port → the port; parked → the fleet's own coordinate; else its anchor. ──
      if v_gf.status = 'present' and v_gf.current_location_id is not null then
        select l.id, l.x, l.y, l.zone_id into v_gfl
          from locations l where l.id = v_gf.current_location_id;
        if v_gfl.id is null then
          return jsonb_build_object('ok', false, 'reason', 'invalid_origin');
        end if;
        v_o_type := 'location'; v_o_base := null; v_o_zone := v_gfl.zone_id; v_o_loc := v_gfl.id;
        v_o_x := v_gfl.x; v_o_y := v_gfl.y;
        -- the return port defaults to the port the fleet sails from (the 0199 launch-branch rule).
        v_return := coalesce(p_return_location_id, v_gf.current_location_id);
      elsif v_gf.location_mode = 'space' then
        -- Parked in open space (0208/0209) — depart the fleet's OWN coordinate. No port origin, so
        -- the return port is only what the caller chose (NULL → the reconciler's re-home path,
        -- exactly as the 0168 head's fleets carry no return_location_id).
        v_o_type := 'space'; v_o_base := null; v_o_zone := null; v_o_loc := null;
        v_o_x := v_gf.space_x; v_o_y := v_gf.space_y;
        v_return := p_return_location_id;
      else
        -- Idle at its anchor (the mover's fall-through place, 0208:447-461): depart the base.
        v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
        v_o_x := v_base.x; v_o_y := v_base.y;
        v_return := p_return_location_id;
      end if;

      -- ── WRITES (all-or-nothing) ────────────────────────────────────────────────────────────────
      -- Dissolve each member's OWN present fleet FIRST — the head's dissolve block (0204:664-676),
      -- composed verbatim, exactly as the mover composes it at every go (0208:496-520). This is NOT
      -- vestigial in the consuming path: 0213's co-location arm ALLOWS assigning a docked ship into
      -- a group whose fleet is present at the SAME port, and that assignee KEEPS its own per-ship
      -- present fleet + active presence (0213 chose guard-assignment over dissolve-at-assignment).
      -- A sortie that left that pair active would be a ship hunting AND docked at once — §0's
      -- ghost-dock duality through the hunt's own front door.
      perform presence_complete(lp.id)
        from public.fleets f
        join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
        where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
      update public.fleets
        set status = 'completed', location_mode = 'movement', active_movement_id = null,
            current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
            updated_at = now()
        where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

      -- CONSUME the settled fleet: close its dock presence and complete it — the mover's own
      -- release idiom (0208:549-557), made TERMINAL ('completed', not 'idle') because the hunt
      -- mints a NEW fleet below. The old fleet is terminal before the new one exists, in the same
      -- transaction: at-most-one live group-shaped fleet is restored BY CONSTRUCTION, and no
      -- presence is orphaned (§0's ghost-dock class — asserted by HUNTUNI_PASS_NOGHOSTDOCK).
      perform presence_complete(lp.id)
        from public.location_presence lp
        where lp.fleet_id = v_gf.id and lp.status = 'active';
      update public.fleets
        set status = 'completed', location_mode = 'movement', active_movement_id = null,
            space_x = null, space_y = null,
            current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
            updated_at = now()
        where id = v_gf.id;

      -- ONE team fleet (main_ship_id NULL; members carried by the manifest) — the head's own mint,
      -- with the origin captured from the consumed fleet instead of a per-ship dock join.
      insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id, return_location_id)
        values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group, v_return)
        returning id into v_fleet;

      v_movement := movement_create(
        v_player, v_fleet,
        v_o_type, v_o_base, v_o_zone, v_o_loc, v_o_x, v_o_y,
        'location', null, null, v_loc.id, v_loc.x, v_loc.y,
        'hunt_pirates', v_speed);
      perform fleet_set_moving(v_fleet, v_movement);

      -- 4C-MIG-2B HUNK: the spatial_state/space_x/space_y=null clears retire WITH the columns
      -- (2a's b5 kept them CHECK-required; the CHECK is dropped in §4 below, same transaction).
      -- status='hunting' is unchanged — it is the sortie/combat layer's own signal and retires with
      -- the status-CHECK narrow in §5, not this hunk.
      update main_ship_instances
        set status = 'hunting', updated_at = now()
        where main_ship_id = any(v_members);

      insert into group_sortie_members (fleet_id, main_ship_id, player_id)
        select v_fleet, m, v_player from unnest(v_members) as m;

      select arrive_at into v_arrive from fleet_movements where id = v_movement;
      return jsonb_build_object(
        'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
        'arrive_at', v_arrive, 'member_count', array_length(v_members, 1), 'return_location_id', v_return);
    end if;
    -- v_gf_n = 0 → fall through: the head's readiness + launch arms run VERBATIM (bootstrap parity).
  end if;

  -- Readiness UNDER the locks. NOHOME (0199): the ONE marked readiness hunk. DARK — home-only
  -- (a fleet-truth-docked member does NOT count as ready while dark — see the 4C-MIG-2B GATE FIX
  -- note below). LIT — a member is ready if home OR DOCKED (the settled-safe pair) AND hp>0; a
  -- docked team is checked for a common port in the launch branch.
  if v_launch_from_dock then
    -- 2a's b5 fleet-truth repoint (unchanged here): "docked" is FLEET TRUTH, mirroring 0221 R1-f.
    select count(*) into v_not_home
      from public.main_ship_instances s
      where s.main_ship_id = any(v_members)
        and (not (s.status = 'home' or exists (
               select 1 from public.fleets f
               where f.id = public.mainship_resolve_fleet(s.main_ship_id)
                 and f.status = 'present' and f.location_mode = 'location'
                 and f.current_location_id is not null and f.active_movement_id is null
                 and exists (
                   select 1 from public.location_presence lp
                    where lp.fleet_id = f.id and lp.status = 'active'
                      and lp.location_id = f.current_location_id)
             )) or s.hp <= 0);
  else
    -- 4C-MIG-2B GATE FIX (the SAME bug class the CI apply-proof found in send_main_ship_expedition's
    -- gate, fixed here proactively): the ORIGINAL 0168 dark check was `status <> 'home' or hp <= 0`
    -- because a DOCKED member was status='stationary' — distinct from 'home' by construction, so
    -- the dark (home-only) check rejected it for free. Post-repoint, F2 writes status='home' for a
    -- DOCKED member too, so `status <> 'home'` alone can no longer tell a docked member from a
    -- truly-home one while dark. A fleet-truth-docked member must still count as NOT ready here
    -- (dark = home-only, no dock exception — matching the exact original intent), else it would
    -- fall through to the 0168 dark tail and mint a SECOND, phantom base fleet alongside its real
    -- dock fleet.
    select count(*) into v_not_home
      from public.main_ship_instances s
      where s.main_ship_id = any(v_members)
        and (s.status <> 'home' or s.hp <= 0
             or exists (
               select 1 from public.fleets f
               where f.id = public.mainship_resolve_fleet(s.main_ship_id)
                 and f.status = 'present' and f.location_mode = 'location'
                 and f.current_location_id is not null and f.active_movement_id is null
                 and exists (
                   select 1 from public.location_presence lp
                    where lp.fleet_id = f.id and lp.status = 'active'
                      and lp.location_id = f.current_location_id)
             ));
  end if;
  if v_not_home > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- ── NOHOME (0199) LAUNCH-FROM-DOCK BRANCH — the whole team launches as ONE fleet from its port ──────
  -- Triggers ONLY when the flag is lit AND at least one member is docked. A docked team must be gathered
  -- at ONE port (else member_not_ready — the same all-or-nothing posture the move-team gate uses, 0190).
  -- The members' own present fleets are dissolved (they leave to fly with the team); the ONE new team
  -- fleet departs from the common port; origin_base_id stays the legacy base so the escape tick's
  -- return-to-base mechanics (process_combat_ticks 0169:217-228 — UNTOUCHED) still work, and the chosen
  -- (or origin) return port is recorded so the reconciler docks the team there instead of re-homing.
  -- (N2) count docked members ONLY when lit — the DARK path never touches this (v_docked stays NULL and
  -- the short-circuit `v_launch_from_dock and …` below never evaluates it).
  if v_launch_from_dock then
    select count(*) into v_docked
      from public.main_ship_instances s
      where s.main_ship_id = any(v_members)
        and exists (
          select 1 from public.fleets f
          where f.id = public.mainship_resolve_fleet(s.main_ship_id)
            and f.status = 'present' and f.location_mode = 'location'
            and f.current_location_id is not null and f.active_movement_id is null
            and exists (
              select 1 from public.location_presence lp
               where lp.fleet_id = f.id and lp.status = 'active'
                 and lp.location_id = f.current_location_id)
        );
  end if;

  if v_launch_from_dock and v_docked > 0 then
    -- EVERY member must be docked at ONE common port (a mixed home/docked team, or a split-port team,
    -- is not a coherent single-origin launch → member_not_ready).
    if v_docked <> array_length(v_members, 1) then
      return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
    end if;
    select count(distinct f.current_location_id) into v_dockcount
      from public.main_ship_instances s
      join public.fleets f on f.id = public.mainship_resolve_fleet(s.main_ship_id)
                           and f.player_id = v_player and f.status = 'present'
                           and f.location_mode = 'location' and f.current_location_id is not null
                           and f.active_movement_id is null
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
                                       and lp.location_id = f.current_location_id
      where s.main_ship_id = any(v_members);
    if v_dockcount is distinct from 1 then
      return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
    end if;
    -- the ONE common port + its coordinates (distinct count proved a single location above); read
    -- FROM THE FLEET (f.current_location_id / current_zone_id), not the presence row.
    select f.current_location_id as location_id, f.current_zone_id as zone_id, l.x, l.y, z.sector_id
      into v_cur
      from public.main_ship_instances s
      join public.fleets f on f.id = public.mainship_resolve_fleet(s.main_ship_id)
                           and f.player_id = v_player and f.status = 'present'
                           and f.location_mode = 'location' and f.current_location_id is not null
                           and f.active_movement_id is null
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
                                       and lp.location_id = f.current_location_id
      join public.locations l on l.id = f.current_location_id
      join public.zones z on z.id = l.zone_id
      where s.main_ship_id = any(v_members)
      limit 1;
    v_dock_loc := v_cur.location_id;
    v_return   := coalesce(p_return_location_id, v_dock_loc);

    -- Active-fleet limit EXCLUDING the members' own present fleets (they are dissolved below; the team
    -- consumes ONE slot net — the 0168/0019 shared-budget idiom, adjusted for the dissolve).
    v_max := coalesce(cfg_num('max_active_fleets'), 3);
    select count(*) into v_active
      from fleets
      where player_id = v_player and status in ('moving','present','returning')
        and (main_ship_id is null or not (main_ship_id = any(v_members)));
    if v_active >= v_max then
      return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
    end if;

    -- Team stats over the LOCKED members (the 0168 fold verbatim; raises → stats_invalid envelope).
    v_power := 0;
    v_speed := null;
    begin
      foreach v_ship in array v_members loop
        v_stats := public.calculate_expedition_stats(v_player, v_ship, '[]'::jsonb, 'pirate_hunt');
        v_power := v_power + coalesce((v_stats->>'combat_power')::double precision, 0);
        v_ms    := (v_stats->>'speed')::double precision;
        v_speed := least(coalesce(v_speed, v_ms), v_ms);
      end loop;
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
    end;
    if v_power < coalesce(v_loc.min_power_required, 0) then
      return jsonb_build_object('ok', false, 'reason', 'power_below_required');
    end if;

    -- origin_base anchors the return-to-base mechanics (the escape tick reads origin_base_id).
    select id, x, y, sector_id into v_base
      from bases where player_id = v_player and status = 'active'
      order by created_at limit 1;
    if v_base.id is null then
      return jsonb_build_object('ok', false, 'reason', 'no_home_base');
    end if;

    -- ── WRITES (all-or-nothing) ─────────────────────────────────────────────────────────────────────
    -- Dissolve each docked member's OWN present fleet: close its active presence and complete the fleet
    -- (the ship leaves the dock to fly with the team). fleet_complete requires 'returning', so this is a
    -- direct completed-write (the dock had no movement).
    perform presence_complete(lp.id)
      from public.fleets f
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
      where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
    update public.fleets
      set status = 'completed', location_mode = 'movement', active_movement_id = null,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = now()
      where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

    -- ONE team fleet (main_ship_id NULL; members carried by the manifest) tagged with the group, origin
    -- the legacy base (return mechanics) + the recorded return port.
    insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id, return_location_id)
      values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group, v_return)
      returning id into v_fleet;

    -- Depart from the COMMON DOCKED PORT (origin_type='location', the port coordinates), mission
    -- 'hunt_pirates' — NOT from the (0,0) base.
    v_movement := movement_create(
      v_player, v_fleet,
      'location', null, v_cur.zone_id, v_dock_loc, v_cur.x, v_cur.y,
      'location', null, null, v_loc.id, v_loc.x, v_loc.y,
      'hunt_pirates', v_speed);
    perform fleet_set_moving(v_fleet, v_movement);

    -- 4C-MIG-2B HUNK: same retirement as the first departure write above.
    update main_ship_instances
      set status = 'hunting', updated_at = now()
      where main_ship_id = any(v_members);

    insert into group_sortie_members (fleet_id, main_ship_id, player_id)
      select v_fleet, m, v_player from unnest(v_members) as m;

    select arrive_at into v_arrive from fleet_movements where id = v_movement;
    return jsonb_build_object(
      'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
      'arrive_at', v_arrive, 'member_count', array_length(v_members, 1), 'return_location_id', v_return);
  end if;

  -- ── 0168 HEAD (DARK path — byte-identical to send_ship_group_hunt 0168:226-312) ─────────────────────
  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
  end if;

  v_power := 0;
  v_speed := null;
  begin
    foreach v_ship in array v_members loop
      v_stats := public.calculate_expedition_stats(v_player, v_ship, '[]'::jsonb, 'pirate_hunt');
      v_power := v_power + coalesce((v_stats->>'combat_power')::double precision, 0);
      v_ms    := (v_stats->>'speed')::double precision;
      v_speed := least(coalesce(v_speed, v_ms), v_ms);
    end loop;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;

  if v_power < coalesce(v_loc.min_power_required, 0) then
    return jsonb_build_object('ok', false, 'reason', 'power_below_required');
  end if;

  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_home_base');
  end if;

  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
    returning id into v_fleet;

  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'hunt_pirates', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  -- 4C-MIG-2B HUNK: same retirement as the two departure writes above — this is the 0168 dark path.
  update main_ship_instances
    set status = 'hunting', updated_at = now()
    where main_ship_id = any(v_members);

  insert into group_sortie_members (fleet_id, main_ship_id, player_id)
    select v_fleet, m, v_player from unnest(v_members) as m;

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'ok', true, 'group_id', v_group, 'fleet_id', v_fleet, 'movement_id', v_movement,
    'arrive_at', v_arrive, 'member_count', array_length(v_members, 1));
end;
$function$;

CREATE OR REPLACE FUNCTION public.movement_settle_arrival(p_movement uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m           fleet_movements%rowtype;
  v_loc       record;
  v_units     jsonb;
  v_main_ship uuid;
begin
  -- Guarded locked re-read: still moving AND due. For the cron this is a no-op re-take of a lock it
  -- already holds on a row it already proved due (now() is constant within the txn) — byte-equivalent.
  -- For the on-demand RPC it is the authoritative claim.
  select * into m from fleet_movements
    where id = p_movement and status = 'moving' and arrive_at <= now()
    for update;
  if not found then
    return jsonb_build_object('settled', false, 'reason', 'not_settleable');
  end if;

  if m.target_type = 'location' then
    select l.activity_type as activity, l.zone_id as zone_id, z.sector_id as sector_id
      into v_loc from locations l join zones z on z.id = l.zone_id where l.id = m.target_location_id;
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    perform fleet_set_present(m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id);
    perform presence_create(m.player_id, m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id, v_loc.activity);

    -- Main-ship fleets: settle the SHIP too (0153; decision doc §5 arrival rule). Dock-vs-legacy split:
    --   • DOCKABLE target — the SINGLE canonical legality rule (mainship_space_location_target_legal: active
    --     sector/zone/location + role city|port + activity 'none' + one active docking service + one active
    --     in-bounds anchor) — → the canonical docked pair via the ONE shared docked-ship helper.
    --     fleet_set_present already set the fleet present/location-mode with active_movement_id=NULL and
    --     presence_create added the matching active presence (legacy fleets never carry an
    --     active_space_movement_id), so the ship reads as a coherent at_location per
    --     mainship_space_validate_context.
    --   • otherwise — a main-ship fleet arriving at an active 'none' but NON-dockable target (REACHABLE:
    --     the seed safe-zones Safe Rally Point / Quiet Drift have no role/docking service/anchor) — write
    --     NOTHING to main_ship_instances: the ship is already in the legacy spatial_state=NULL
    --     representation from its departure write (0152's mainship_mark_legacy_in_flight), which is
    --     constraint-legal, coherent legacy_present.
    -- The v_main_ship IS NOT NULL gate keeps ordinary unit fleets (main_ship_id NULL) untouched.
    -- FLEET-GO 3b note: a UNIFIED group fleet has main_ship_id NULL by construction, so it takes the
    -- same "ordinary fleet" path here and no ship is written — §2 holds through the settle, for free.
    select main_ship_id into v_main_ship from fleets where id = m.fleet_id;
    if v_main_ship is not null
       and (public.mainship_space_location_target_legal(m.target_location_id)->>'ok')::boolean is true then
      perform public.mainship_mark_docked_at_location(v_main_ship);
    end if;

    return jsonb_build_object('settled', true, 'outcome', 'present', 'movement_id', m.id);

  elsif m.target_type = 'base' then
    select jsonb_agg(jsonb_build_object('unit_type_id', unit_type_id, 'quantity', quantity))
      into v_units from fleet_units where fleet_id = m.fleet_id and quantity > 0;
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    if v_units is not null then
      perform base_merge_units(m.target_base_id, v_units);
    end if;
    perform fleet_complete(m.fleet_id);
    -- Deposit carried rewards now that the fleet is safely home (idempotent via
    -- reward_grants unique source), under the movement's activity source type.
    if m.reward_payload_json is not null and m.reward_payload_json <> '{}'::jsonb and m.reward_grant_source is not null then
      perform reward_grant(m.reward_source_type, m.reward_grant_source, m.player_id, m.target_base_id, m.reward_payload_json);
    end if;
    return jsonb_build_object('settled', true, 'outcome', 'completed', 'movement_id', m.id);

  -- ★ FLEET-GO 3b (0208), REWRITTEN BY 0307: LOOT SECURES ON ARRIVAL ★ — a coordinate arrival
  -- parks the fleet in open space at the target. No presence (open space has no location), no
  -- units merge, and — as everywhere in the charter — NO ship write. The 0208 text also said
  -- "no rewards" and called this branch unreachable while the mover was dark; 0300 lit the gate,
  -- and the chosen-destination retreat (0292/0298) made this the arrival every surviving fight
  -- is steered to — and it paid nothing. 0307 retires that: the bundle this movement carries
  -- (attached by the tick's retreat-completion branch, 0299:626) is deposited HERE, by the same
  -- sole depositor the 'base' arm calls, under the same guard, idempotent the same way
  -- (reward_grants UNIQUE (source_type, source_id)); a replayed settle cannot even re-enter this
  -- arm, because the guarded locked re-read above only admits status='moving'.
  elsif m.target_type = 'space' then
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    perform public.fleet_set_in_space(m.fleet_id, m.target_x, m.target_y);
    if m.reward_payload_json is not null and m.reward_payload_json <> '{}'::jsonb and m.reward_grant_source is not null then
      declare
        v_port    uuid;
        v_deposit uuid;
      begin
        -- Deposit target (NO-HOME): a port-destination retreat resolves the ordered port to its
        -- own l.x/l.y and mints the leg with exactly those values (0299:608-614), so an arrival
        -- coordinate that IS an active dockable port's coordinate deposits into the player's
        -- store AT that port — get_or_create_store, the one store authority (0157); dockability
        -- is judged by ITS own predicate (is_home_port_eligible), called here only to pick the
        -- candidate, never re-implemented. Anywhere else in open space: the proven securing-
        -- processor idiom, the player's oldest active base (0221:1031-1036, verbatim). Never
        -- grant against NULL — that would burn the one idempotency key on a half deposit; with
        -- no reward_grants row written, the bundle stays grantable by a future repair.
        select l.id into v_port
          from locations l
         where l.status = 'active' and l.x = m.target_x and l.y = m.target_y
           and public.is_home_port_eligible(l.id)
         order by l.created_at, l.id
         limit 1;
        if v_port is not null then
          v_deposit := public.get_or_create_store(m.player_id, v_port);
        else
          select b.id into v_deposit
            from bases b
           where b.player_id = m.player_id and b.status = 'active'
           order by b.created_at
           limit 1;
        end if;
        if v_deposit is not null then
          perform reward_grant(m.reward_source_type, m.reward_grant_source, m.player_id, v_deposit, m.reward_payload_json);
        end if;
      end;
    end if;
    return jsonb_build_object('settled', true, 'outcome', 'in_space', 'movement_id', m.id);

  else
    update fleet_movements set status = 'failed', resolved_at = now() where id = m.id;
    return jsonb_build_object('settled', true, 'outcome', 'failed', 'movement_id', m.id);
  end if;
end;
$function$;

-- ── 4. THE MOVEMENT CLIENT SURFACE — ESTABLISHED, NOT ASSUMED ───────────────────────────────────
-- 0254 cost a production deploy by ASSERTING a lockdown a migration had never established; 0309 cost
-- a second round by revoking from `anon, authenticated` while PUBLIC quietly kept the privilege. So:
-- revoke from PUBLIC BY NAME, then grant the one client role this surface is meant to have. Every
-- statement here is a no-op against the ACLs that already exist on both production and a disposable
-- chain — check (d) proves that, by requiring the grantee list to be UNCHANGED across this file.
-- `service_role` is deliberately NOT granted; the note above check (d) says why.
revoke execute on function public.command_ship_group_go(uuid, uuid, double precision, double precision) from public, anon;
grant  execute on function public.command_ship_group_go(uuid, uuid, double precision, double precision) to authenticated;
revoke execute on function public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision) from public, anon;
grant  execute on function public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision) to authenticated;
revoke execute on function public.command_ship_group_dock(uuid) from public, anon;
grant  execute on function public.command_ship_group_dock(uuid) to authenticated;
revoke execute on function public.command_ship_group_stop(uuid) from public, anon;
grant  execute on function public.command_ship_group_stop(uuid) to authenticated;
revoke execute on function public.send_ship_group_hunt(uuid, uuid, uuid) from public, anon;
grant  execute on function public.send_ship_group_hunt(uuid, uuid, uuid) to authenticated;
revoke execute on function public.movement_settle_arrival(uuid) from public, anon, authenticated;

-- ── 5. THE ORPHANED PRE-TEAM MOVER ──────────────────────────────────────────────────────────────
-- `send_fleet_to_location` (last defined 20260618000051_resolve_fleet_movement_speed.sql:224) is the
-- M3-era single-fleet dispatcher: it reserves `base_units`, mints a `fleets` row and a
-- `fleet_movements` leg. It is a MOVER, and it is granted to `authenticated` on production today.
--
-- It has no client caller. 0232 retired twenty legacy mover functions and this one was missed — its
-- `grant execute … to authenticated` was simply carried forward by every ACL-restating migration from
-- 0010 through 0068 and never revisited. Verified before revoking: zero references in `src/` (the
-- client's entire RPC surface is 70 `.rpc()` names and this is not one of them).
--
-- WHAT STILL CALLS IT, and why each is unaffected or accepted:
--   * scripts/team-command-proof.sql:1116,4428,4432,4500,4504 — the disposable-Postgres harness. It
--     calls through pg_temp.call_as, which only sets `request.jwt.claims` and runs as the psql
--     superuser; it never assumes the `authenticated` GRANT. Unaffected by this revoke.
--   * scripts/verify-m3|m4|m5|phase5|mainship-send|mainship-move|speed-resolver.mjs — legacy
--     workflow_dispatch verifiers of the retired M3/M4 disposable-fleet era, which call it over
--     PostgREST as a signed-in user. They will now fail at that step. None of them gates CI, and the
--     path they exercise is the one 0232 retired. Deleting them is its own slice; this migration does
--     not pretend they still work.
--   * scripts/osn3-*-realchain-perm.sql and siblings list it in an expected authenticated-surface
--     array. Those files are era snapshots that already name `move_main_ship_to_location`, which 0232
--     DROPPED, so they cannot pass on the current chain regardless; they fire only on `osn3-**`
--     branches. Recorded, not repaired here.
--
-- The BODY is deliberately untouched: the repo already holds its true text (no surgery has ever
-- rewritten it) and check (e) pins that this migration changed the surface and nothing else.
-- (No `grant … to service_role` here, for the reason spelled out above check (d): service_role's
-- EXECUTE on production comes from the Supabase project defaults, never from this chain, and granting
-- it would make this migration change an ACL on a disposable database.)
revoke execute on function public.send_fleet_to_location(uuid, uuid, jsonb) from public, anon, authenticated;

-- ── 6. SELF-ASSERTS ─────────────────────────────────────────────────────────────────────────────

-- (b) ZERO BEHAVIOUR CHANGE: every restored body is byte-identical to what was already deployed, and
-- equal to the production constant. This is the whole contract of the slice.
do $b$
declare b record; v_after text; v_len integer; v_expected text; v_n integer := 0;
begin
  for b in select * from _0330_before where fname = any (array['command_ship_group_go', 'command_ship_group_dock', 'command_ship_group_stop', 'send_ship_group_hunt', 'movement_settle_arrival']) order by fname loop
    select md5(p.prosrc), length(p.prosrc) into v_after, v_len
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = b.fname;
    select body_md5 into v_expected from _0330_expected where fname = b.fname;
    if v_after is null then
      raise exception '0330 ASSERT (b) FAIL: public.% is gone after the re-creation', b.fname;
    end if;
    if v_after <> b.body_md5 then
      raise exception '0330 ASSERT (b) FAIL: public.% body CHANGED across the re-creation (% -> %, % -> % bytes). This migration is a byte-for-byte restoration and must never alter a body.',
        b.fname, b.body_md5, v_after, b.srclen, v_len;
    end if;
    if v_after <> v_expected then
      raise exception '0330 ASSERT (b) FAIL: public.% is % but the production body this file carries is % — the CREATE OR REPLACE above did not land the text it was supposed to (line endings? a truncated body?)',
        b.fname, v_after, v_expected;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 5 then
    raise exception '0330 ASSERT (b) FAIL: verified % restored function(s), expected 5', v_n;
  end if;
end $b$;

-- (c) METADATA + COMMENT PARITY: a re-creation may not quietly change what the function IS. Includes
-- obj_description because `create or replace` keeps the oid and therefore the COMMENT — if one went
-- missing, the text was not a faithful pg_get_functiondef capture.
do $c$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0330_before where fname = any (array['command_ship_group_go', 'command_ship_group_dock', 'command_ship_group_stop', 'send_ship_group_hunt', 'movement_settle_arrival']) order by fname loop
    select pg_get_userbyid(p.proowner) as owner, p.prosecdef as secdef, p.provolatile as volatility,
           p.proparallel as parallel, p.proisstrict as strict_, p.proretset as retset,
           p.proleakproof as leakproof, p.procost as cost,
           coalesce(array_to_string(p.proconfig, ','), '') as proconfig,
           pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as result,
           coalesce(obj_description(p.oid, 'pg_proc'), '') as fn_comment
      into a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = b.fname;
    if a.owner is distinct from b.owner then
      raise exception '0330 ASSERT (c) FAIL: public.% changed owner (% -> %)', b.fname, b.owner, a.owner;
    end if;
    if a.secdef is distinct from b.secdef or a.proconfig is distinct from b.proconfig then
      raise exception '0330 ASSERT (c) FAIL: public.% changed its security context (secdef %->%, config %->%)',
        b.fname, b.secdef, a.secdef, b.proconfig, a.proconfig;
    end if;
    if a.volatility is distinct from b.volatility or a.parallel is distinct from b.parallel
       or a.strict_ is distinct from b.strict_ or a.retset is distinct from b.retset
       or a.leakproof is distinct from b.leakproof or a.cost is distinct from b.cost then
      raise exception '0330 ASSERT (c) FAIL: public.% changed a planner/behaviour attribute', b.fname;
    end if;
    if a.args is distinct from b.args or a.result is distinct from b.result then
      raise exception '0330 ASSERT (c) FAIL: public.% changed signature (% -> %) / result (% -> %)',
        b.fname, b.args, a.args, b.result, a.result;
    end if;
    if a.fn_comment is distinct from b.fn_comment then
      raise exception '0330 ASSERT (c) FAIL: public.% lost or changed its COMMENT across the re-creation', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 5 then
    raise exception '0330 ASSERT (c) FAIL: parity-checked % function(s), expected 5', v_n;
  end if;
end $c$;

-- (d) THE MOVEMENT CLIENT SURFACE. Three things, because no one of them is enough on its own:
--   1. UNCHANGED from what was captured before any statement above ran. This is the claim the slice
--      makes — a byte-for-byte restoration may not move a grant — and it is exact: the full EXECUTE
--      grantee list, PUBLIC included by name.
--   2. PUBLIC / anon / authenticated answered individually by has_function_privilege, which counts a
--      privilege held THROUGH PUBLIC (the 0309 lesson: a revoke naming only anon and authenticated
--      leaves a PUBLIC-held privilege standing, and a per-role has_*_privilege probe is what catches
--      it).
--   3. No grantee OUTSIDE the intended set holds EXECUTE — so an unexpected fourth role fails here
--      rather than being discovered on production.
--
-- WHY `service_role` IS EXCLUDED FROM (3)'s COMPARISON AND IS NOT REQUIRED. Production's ACL for
-- these functions reads {postgres,service_role,authenticated}, but NO MIGRATION EVER GRANTED
-- service_role — 0309:184-198 established that with a chain-wide sweep for the two functions it
-- touched, and the same holds here. It comes from the Supabase PROJECT-LEVEL default privileges,
-- which a disposable `supabase start` Postgres does NOT reproduce (that gap is exactly what aborted
-- the 0254 production deploy — see the danger_zones grant-drift finding). So service_role's presence
-- is an ambient property of the hosting project, not of this chain: asserting it would be asserting a
-- world this migration does not own, and GRANTING it here would make this migration change an ACL on
-- the disposable DB — the one thing checked (1) forbids. It is tolerated where it appears and
-- required nowhere. The function owner is tolerated for the same reason.
do $d$
declare r record; v_actual text; v_extra text; v_before text; v_owner text; v_n integer := 0;
begin
  for r in
    select * from (values
    ('command_ship_group_go',        'public.command_ship_group_go(uuid, uuid, double precision, double precision)', true),
    ('command_ship_group_go_route',  'public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision)', true),
    ('command_ship_group_dock',      'public.command_ship_group_dock(uuid)', true),
    ('command_ship_group_stop',      'public.command_ship_group_stop(uuid)', true),
    ('send_ship_group_hunt',         'public.send_ship_group_hunt(uuid, uuid, uuid)', true),
    ('movement_settle_arrival',      'public.movement_settle_arrival(uuid)', false)
    ) as t(fname, sig, client_callable)
    order by fname
  loop
    -- the CASE is load-bearing: a function with NO acl entries produces one NULL-extended row from
    -- the LEFT JOIN, and NULL::regrole::text is also NULL — so a bare coalesce(...,'PUBLIC') would
    -- report an EMPTY grant list as "PUBLIC holds it". string_agg skips NULLs; that row must be one.
    select coalesce(string_agg(case when a.grantee is null then null
                                    else coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC') end,
                               ',' order by 1), ''),
           pg_get_userbyid(p.proowner)
      into v_actual, v_owner
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      left join lateral aclexplode(p.proacl) a on a.privilege_type = 'EXECUTE'
     where n.nspname = 'public' and p.proname = r.fname
     group by p.proowner;

    -- 1. unchanged. Whatever the surface was before this migration touched anything, it still is.
    select exec_grants into v_before from _0330_before where fname = r.fname;
    if v_before is null then
      raise exception '0330 ASSERT (d) FAIL: no BEFORE row for % — the capture in §2 missed it and this check would pass vacuously', r.fname;
    end if;
    if v_before is distinct from v_actual then
      raise exception '0330 ASSERT (d) FAIL: % EXECUTE grantees moved across this migration ([%] -> [%]) — the restoration was supposed to leave the surface exactly as it found it',
        r.sig, v_before, v_actual;
    end if;

    -- 2. the roles a player can actually reach, answered one at a time
    if has_function_privilege('public', r.sig, 'execute') or has_function_privilege('anon', r.sig, 'execute') then
      raise exception '0330 ASSERT (d) FAIL: % is reachable by PUBLIC or anon', r.sig;
    end if;
    if has_function_privilege('authenticated', r.sig, 'execute') is distinct from r.client_callable then
      raise exception '0330 ASSERT (d) FAIL: % authenticated-executable = %, expected %',
        r.sig, has_function_privilege('authenticated', r.sig, 'execute'), r.client_callable;
    end if;

    -- 3. nobody else
    select string_agg(g, ',' order by g) into v_extra
      from unnest(string_to_array(v_actual, ',')) as g
     where g <> '' and g <> v_owner and g <> 'service_role'
       and not (r.client_callable and g = 'authenticated');
    if v_extra is not null then
      raise exception '0330 ASSERT (d) FAIL: % grants EXECUTE to [%], which is nobody this surface intends (owner=% and service_role are tolerated)',
        r.sig, v_extra, v_owner;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 6 then
    raise exception '0330 ASSERT (d) FAIL: checked % surface(s), expected 6', v_n;
  end if;
end $d$;

-- (e) §5: the orphaned pre-team mover is off the client surface, and ONLY its surface moved.
do $e$
declare v_sig constant text := 'public.send_fleet_to_location(uuid, uuid, jsonb)';
        v_actual text; v_extra text; v_owner text; v_before text; v_after text;
begin
  select coalesce(string_agg(case when a.grantee is null then null
                                  else coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC') end,
                             ',' order by 1), ''),
         pg_get_userbyid(p.proowner)
    into v_actual, v_owner
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    left join lateral aclexplode(p.proacl) a on a.privilege_type = 'EXECUTE'
   where n.nspname = 'public' and p.proname = 'send_fleet_to_location'
   group by p.proowner;

  if has_function_privilege('public', v_sig, 'execute')
     or has_function_privilege('anon', v_sig, 'execute')
     or has_function_privilege('authenticated', v_sig, 'execute') then
    raise exception '0330 ASSERT (e) FAIL: send_fleet_to_location is STILL client-callable (EXECUTE grantees: [%]) — the revoke did not take', v_actual;
  end if;

  -- nobody outside the owner and the ambient service_role may hold it (same reasoning as check (d))
  select string_agg(g, ',' order by g) into v_extra
    from unnest(string_to_array(v_actual, ',')) as g
   where g <> '' and g <> v_owner and g <> 'service_role';
  if v_extra is not null then
    raise exception '0330 ASSERT (e) FAIL: send_fleet_to_location still grants EXECUTE to [%]', v_extra;
  end if;

  select body_md5 into v_before from _0330_before where fname = 'send_fleet_to_location';
  select md5(p.prosrc) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_fleet_to_location';
  if v_before is null or v_after is null or v_before <> v_after then
    raise exception '0330 ASSERT (e) FAIL: send_fleet_to_location body changed (% -> %) — this slice revokes a grant and touches nothing else', v_before, v_after;
  end if;

  raise notice '0330 SELF-ASSERT PASS: five movement bodies restored to the repository byte-for-byte, the movement client surface is exactly as production holds it, and send_fleet_to_location is off it.';
end $e$;

commit;
