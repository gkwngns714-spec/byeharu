-- COORDINATE-TRAVEL ACTIVATION — the free-coordinate-travel flip (FULL_CAPACITY_PLAN §B ladder:
-- the reachability prerequisite for the exploration/mining rungs; docs/WORLD_RECON_F1.md §7: "the
-- coordinate-travel flag, not the envelope, is the binding world-range decision").
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ───────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000178 (COORD-GUARD, the A0-fix) is deployed AND the guarded body
--       is REALLY live: the 4-arg command_main_ship_space_move's prosrc contains the resolver CALL
--       token `v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id)` (assignment
--       form) PAIRED with the negative check that the unguarded `where player_id = v_player` read is
--       GONE — the pair (presence of the call + absence of the old derivation) is the real teeth;
--       the old 3-arg identity is gone too. Multi-ship is LIVE (max_main_ships_per_player=24), so
--       flipping WITHOUT the guard would light an arbitrary-ship-read bug — this precondition is the
--       whole point of the COORD-GUARD slice.
--     • command_main_ship_space_stop is resolver-guarded too (0083 — the contemporary pattern).
--     • the readiness projection get_osn_movement_readiness(uuid) exists and derives
--       coordinate_travel_available (0071/0082) — the client's SOLE coordinate-targeting authority.
--     • the flag key mainship_coordinate_travel_enabled exists (0070 seed; refuse to invent keys).
--     • REACHABILITY RATIONALE (why this flip matters, asserted + documented): exploration_sites
--       (0098, 5 rows out to (-4100, 3600)) and mining_fields (0103, 5 rows out to (4200, 3100))
--       require a settled in_space ship within cfg_num radius (exploration_scan_radius /
--       mining_extract_radius, both default 750 — 0099:76 / 0104). The only dockable anchors are the
--       three 0066 port anchors (-50,-30) / (70,-10) / (10,80) (bbox x -50..70, y -30..80 — 0154 /
--       WORLD_RECON_F1 §7). Computed from those seeds: the NEAREST site to ANY anchor is
--       'Derelict Listening Post' (-1200, 850) at ~1,434 units from the (10,80) anchor — nearly
--       double the 750 radius — so port-to-port travel can NEVER put a ship in range of ANY site.
--       FREE coordinate travel is the ONLY path to every site/field; the preconditions compute and
--       print the live minimum anchor→site distance to prove it (and assert anchors exist at all).
--       Single-jump feasibility: the farthest site from its nearest anchor is 'Precursor Vault
--       Signal' (-4100, 3600) at ~5,411 units; at starter base_speed 1.0 that is ~5,411 s (~90 min),
--       far under max_coordinate_travel_seconds (default 86400, 0067:318) — one legal jump.
--   STAGE 1 — THE ONE WRITE (set_game_config; reversible one-liner):
--     • mainship_coordinate_travel_enabled  false → true
--       (command_main_ship_space_move stops rejecting at its step-2b gate; the readiness projection
--       starts returning coordinate_travel_available=true for anchored, movement-enabled callers.)
--   STAGE 2 — smoke asserts (read-only): the committed flag value + cfg_bool; the readiness RPC
--     exists with the coordinate_travel_available derivation in prosrc; the move AND stop commands
--     exist with guarded prosrc (the resolver token); ACL envelope sanity (authenticated EXECUTE on
--     the move command, anon denied); world-envelope sanity (every exploration/mining site is a
--     finite coordinate within the ±10000 movement envelope, 0055/0098/0103 CHECKs — i.e. every
--     site is a LEGAL coordinate target). Emits ACTIVATE_COORD_TRAVEL_PASS_* markers per stage and
--     one final PASS line; any failed assert RAISES → the whole transaction rolls back → NOTHING
--     is applied.
--
-- IDEMPOTENT: safe to re-run — the one write is a set_game_config upsert to the same target value.
--
-- ── NO CLIENT PR IS NEEDED (verified this slice, 2026-07-12) ─────────────────────────────────────
--   The S6C coordinate tap flow is SERVER-READINESS-DRIVEN, not compile-gated:
--     • osnReleaseGates.ts:5-16 — OSN_COORDINATE_TRAVEL_ENABLED is RETIRED as a UI authority
--       (kept `false` only for the osn-postenable-verify no-escape-hatch grep; imported by NO
--       component; never in the render path).
--     • osnReadiness.ts:63 — the strict-boolean parse of the server's coordinate_travel_available;
--       osnReadiness.ts:81-91 — isCoordinateTargetingActionable(readiness, …) is the ONE gate.
--     • GalaxyMap.tsx:93-101 — `canTarget = isCoordinateTargetingActionable(readiness, …)`; the
--       whole empty-space tap/crosshair/SpaceMoveControls surface mounts off it, and readiness
--       re-validates on mount + every ship/movement lifecycle change.
--   The moment stage 1 commits, the next readiness fetch returns coordinate_travel_available=true
--   for an anchored ship and the map's coordinate targeting UI lights. The COORD-GUARD slice also
--   shipped the ship-id passthrough (already merged with 0178 — part of the same slice, NOT a
--   flip-time PR): the S6C wrapper sends {p_target_x, p_target_y, p_request_id, p_main_ship_id}
--   (spaceMoveCommand.ts buildSpaceMoveRpcArgs, asserted by tests/spaceMoveCommand.spec.ts), with
--   the selected ship threaded from GalaxyMap exactly like the stop/settle/readiness siblings — so
--   a multi-ship player's tap targets the SAME ship the readiness projection was scoped to. An
--   id-less caller (old client / direct API) resolves via the trailing default: sole-ship shim at
--   N=1, fail-closed no_ship at N≠1.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • mainship_space_movement_enabled (already LIVE for port-to-port) and every other flag —
--     exploration_enabled / mining_enabled stay dark; their own activate scripts flip them AFTER
--     this one (reachability order). Any table other than game_config (via set_game_config only).
--     Any DDL. Any migration. Any verifier file (the 3-arg→4-arg signature-pin repoints are
--     recorded in docs/TRADE_FLEET_0C_VERIFIER_REPOINT.md for the deploy-time human gate).
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-coordinate-travel.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / management-API runner (it
--   contains no backslash commands to strip), or:
--     bash scripts/activate-coordinate-travel.sh run ACTIVATE_COORD_TRAVEL   # DB_URL required
--   AFTER a green run: manual smoke — anchor a ship at a port, open the map, tap empty space →
--   crosshair + Move control mount; command departs; Stop works mid-flight; on a multi-ship account
--   the tap moves the SELECTED ship (the readiness-scoped one), and an id-less direct API call at
--   N>1 gets the clean fail-closed no_ship reject.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). FLAG ONLY — and in-flight
--   coordinate movements settle server-side REGARDLESS of the flag: the arrival processor
--   process_mainship_space_arrivals (head 0064:95) reads NO game_config flag; the on-demand settle
--   command_main_ship_settle_arrival (0150:66) gates only on mainship_space_movement_enabled
--   (stays true); the stop writer only branches on a flag when the ship is NOT in transit
--   (0064:250-259 — a real in-flight move stops fine). Grep-verified: the ONLY readers of
--   mainship_coordinate_travel_enabled are the raw move command (0070→0178 step 2b) and the
--   readiness projection (0071/0082). No ship strands.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; v_src text; n int; v_mindist numeric; v_maxdist numeric;
begin
  -- (a) the COORD-GUARD migration is deployed and recorded.
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000178' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000178 — deploy COORD-GUARD (the A0-fix) first; flipping without it lights an arbitrary-ship read under multi-ship', coalesce(v_head, '(none)');
  end if;

  -- (b) the guarded body is REALLY live: the resolver-CALL token (assignment form) PAIRED with the
  --     negative check that the unguarded read is gone — the pair is the real teeth.
  if to_regprocedure('public.command_main_ship_space_move(double precision, double precision, uuid, uuid)') is null then
    raise exception 'PRECONDITION FAIL: 4-arg command_main_ship_space_move missing (0178 not applied?)';
  end if;
  if to_regprocedure('public.command_main_ship_space_move(double precision, double precision, uuid)') is not null then
    raise exception 'PRECONDITION FAIL: the OLD unguarded 3-arg command_main_ship_space_move still exists';
  end if;
  select p.prosrc into v_src from pg_proc p
    where p.oid = to_regprocedure('public.command_main_ship_space_move(double precision, double precision, uuid, uuid)');
  if position('v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id)' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed move command does not CALL mainship_resolve_owned_ship — refusing to flip onto an unguarded body';
  end if;
  if v_src like '%where player_id = v_player%' then
    raise exception 'PRECONDITION FAIL: the deployed move command still contains the unguarded single-ship read';
  end if;

  -- (c) the stop command is resolver-guarded too (0083 — the in-flight escape hatch must be per-ship safe).
  select p.prosrc into v_src from pg_proc p
    where p.oid = to_regprocedure('public.command_main_ship_space_stop(uuid, uuid)');
  if v_src is null or position('mainship_resolve_owned_ship' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: command_main_ship_space_stop(uuid, uuid) missing or not resolver-guarded (0083)';
  end if;

  -- (d) the readiness projection that DRIVES the client exists and derives the capability.
  select p.prosrc into v_src from pg_proc p
    where p.oid = to_regprocedure('public.get_osn_movement_readiness(uuid)');
  if v_src is null or position('coordinate_travel_available' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: get_osn_movement_readiness(uuid) missing or lacks the coordinate_travel_available derivation (0071/0082) — the client UI would never light';
  end if;

  -- (e) the flag key exists (0070 seed; refuse to invent config rows via a typo).
  if not exists (select 1 from public.game_config where key = 'mainship_coordinate_travel_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key mainship_coordinate_travel_enabled missing (0070 seed)';
  end if;

  -- (f) REACHABILITY RATIONALE, computed live: the content this flip unlocks exists, and none of it
  --     is reachable by port-to-port travel (every site farther from every dockable anchor than the
  --     LARGER interaction radius). Counts are asserted; the distances are printed as the record.
  select count(*) into n from public.exploration_sites where is_active;
  if n < 1 then raise exception 'PRECONDITION FAIL: no active exploration_sites — nothing for this flip to unlock (seed 0098 missing?)'; end if;
  raise notice 'precondition: active exploration_sites = %', n;
  select count(*) into n from public.mining_fields where is_active;
  if n < 1 then raise exception 'PRECONDITION FAIL: no active mining_fields (seed 0103 missing?)'; end if;
  raise notice 'precondition: active mining_fields = %', n;
  -- the anchors the distance record is computed AGAINST must exist too (zero anchors would make the
  -- reachability record vacuous — a NULL min-distance printed as if it proved something).
  select count(*) into n from public.space_anchors where status = 'active' and kind = 'location';
  if n < 1 then raise exception 'PRECONDITION FAIL: no active dockable location anchors (0066 seed missing?) — the reachability record would be vacuous'; end if;
  raise notice 'precondition: active dockable location anchors = %', n;

  select min(dist), max(dist) into v_mindist, v_maxdist from (
    select sqrt((s.space_x - a.space_x)^2 + (s.space_y - a.space_y)^2) as dist
    from (select space_x, space_y from public.exploration_sites where is_active
          union all
          select space_x, space_y from public.mining_fields where is_active) s
    cross join public.space_anchors a
    where a.status = 'active' and a.kind = 'location'
  ) d;
  raise notice 'precondition (reachability): anchor->site distance min=% max=% vs interaction radius % / % — port-to-port travel reaches NO site; free coordinate travel is the only path',
    round(v_mindist), round(v_maxdist),
    coalesce(public.cfg_num('exploration_scan_radius'), 750), coalesce(public.cfg_num('mining_extract_radius'), 750);
  if v_mindist is not null and v_mindist <= greatest(coalesce(public.cfg_num('exploration_scan_radius'), 750),
                                                     coalesce(public.cfg_num('mining_extract_radius'), 750)) then
    raise notice 'precondition NOTE: at least one site is already within interaction range of a port anchor — the reachability rationale is weaker than recorded, but the flip is still safe';
  end if;

  raise notice 'ACTIVATE_COORD_TRAVEL_PASS_PRECONDITIONS ok: head %, guarded move+stop live, readiness capability present, flag key present, sites/fields seeded', v_head;
end $$;

-- ══════════ STAGE 1 — THE ONE WRITE: the coordinate-travel gate opens ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'mainship_coordinate_travel_enabled';
  perform public.set_game_config('mainship_coordinate_travel_enabled', 'true'::jsonb);
  raise notice 'stage 1: mainship_coordinate_travel_enabled % -> true', v_before;

  raise notice 'ACTIVATE_COORD_TRAVEL_PASS_STAGE1 ok: mainship_coordinate_travel_enabled=true (the one write)';
end $$;

-- ══════════ STAGE 2 — smoke asserts (read-only) ══════════
do $$
declare
  v_src text; n int;
begin
  -- (a) the committed flag value is exactly the activation state.
  if (select value #>> '{}' from public.game_config where key = 'mainship_coordinate_travel_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: mainship_coordinate_travel_enabled committed value is not true';
  end if;
  if not public.cfg_bool('mainship_coordinate_travel_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(mainship_coordinate_travel_enabled) still false';
  end if;
  -- the movement domain the capability derives through must still be live (0071: coordinate_travel_available
  -- = osn_available AND the gate; if this were false the UI would stay dark despite the flip).
  if not public.cfg_bool('mainship_space_movement_enabled') then
    raise exception 'SMOKE FAIL: mainship_space_movement_enabled is false — coordinate_travel_available can never become true';
  end if;

  -- (b) the readiness RPC the client polls exists and carries the capability derivation.
  select p.prosrc into v_src from pg_proc p
    where p.oid = to_regprocedure('public.get_osn_movement_readiness(uuid)');
  if v_src is null or position('coordinate_travel_available' in v_src) = 0 then
    raise exception 'SMOKE FAIL: get_osn_movement_readiness(uuid) missing or lacks coordinate_travel_available';
  end if;

  -- (c) both space commands exist with GUARDED prosrc (the resolver token — never an unguarded read again).
  select p.prosrc into v_src from pg_proc p
    where p.oid = to_regprocedure('public.command_main_ship_space_move(double precision, double precision, uuid, uuid)');
  if v_src is null or position('mainship_resolve_owned_ship' in v_src) = 0 then
    raise exception 'SMOKE FAIL: guarded command_main_ship_space_move not live';
  end if;
  select p.prosrc into v_src from pg_proc p
    where p.oid = to_regprocedure('public.command_main_ship_space_stop(uuid, uuid)');
  if v_src is null or position('mainship_resolve_owned_ship' in v_src) = 0 then
    raise exception 'SMOKE FAIL: guarded command_main_ship_space_stop not live';
  end if;

  -- (d) ACL envelope sanity: the player command surface is authenticated-only.
  if not has_function_privilege('authenticated', 'public.command_main_ship_space_move(double precision, double precision, uuid, uuid)', 'EXECUTE') then
    raise exception 'SMOKE FAIL: authenticated cannot execute command_main_ship_space_move';
  end if;
  if has_function_privilege('anon', 'public.command_main_ship_space_move(double precision, double precision, uuid, uuid)', 'EXECUTE') then
    raise exception 'SMOKE FAIL: anon can execute command_main_ship_space_move';
  end if;

  -- (e) world-envelope sanity: every site/field this flip unlocks is a finite coordinate inside the
  --     ±10000 movement envelope (0055 CHECK) — i.e. a LEGAL coordinate target, no dead content.
  select count(*) into n from (
    select space_x, space_y from public.exploration_sites where is_active
    union all
    select space_x, space_y from public.mining_fields where is_active
  ) s
  where s.space_x is null or s.space_y is null
     or s.space_x < -10000 or s.space_x > 10000 or s.space_y < -10000 or s.space_y > 10000;
  if n <> 0 then
    raise exception 'SMOKE FAIL: % site/field row(s) outside the +-10000 movement envelope (unreachable content)', n;
  end if;

  raise notice 'ACTIVATE_COORD_TRAVEL_PASS_SMOKE ok: flag committed, readiness capability live, move+stop guarded, ACLs sane, all sites inside the envelope';
end $$;

select 'COORDINATE TRAVEL ACTIVATION PASS — free coordinate travel LIVE. Players get: tap empty space on the map -> crosshair + Move control (the S6C flow), fly ANY in-envelope coordinate, Stop mid-flight; exploration/mining sites (out to +-4200) are now physically REACHABLE for the first time. NO client PR is needed: the coordinate UI is driven SOLELY by the server-derived coordinate_travel_available (get_osn_movement_readiness -> osnReadiness.isCoordinateTargetingActionable -> GalaxyMap canTarget) and mounts on the next readiness fetch. Next: the exploration/mining flips (their activate scripts) now have their reachability prerequisite satisfied.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark free coordinate travel again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG ONLY — fully reversible. New coordinate commands reject at step 2b again
--     (coordinate_travel_disabled) and the readiness projection returns
--     coordinate_travel_available=false, so the client UI unmounts on its next readiness fetch.
--   • IN-FLIGHT coordinate movements settle server-side REGARDLESS (verified this slice):
--     process_mainship_space_arrivals (head 0064:95) reads NO game_config flag;
--     command_main_ship_settle_arrival (0150:66) gates only on mainship_space_movement_enabled
--     (stays true); mainship_space_stop only branches on a flag when the ship is NOT in transit
--     (0064:250-259), so an in-flight ship can still be stopped. The ONLY readers of
--     mainship_coordinate_travel_enabled are the raw move command (0178 step 2b) and the readiness
--     projection (0071/0082). No ship strands in space.
--   • If exploration/mining were flipped AFTER this, dark THEM FIRST (reachability order in
--     reverse) — otherwise their lit surfaces point at sites players can no longer fly to.
--
-- begin;
-- select public.set_game_config('mainship_coordinate_travel_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'mainship_coordinate_travel_enabled';
-- commit;
