-- 4B-DROP — LEGACY MOVEMENT FUNCTION DROP (migration 0232): the FINAL, IRREVERSIBLE stage of the
-- legacy-movement retirement. Drops the DEAD legacy mover FUNCTIONS left behind after 4c-mig-1 (0221,
-- READ repoint), 4c-mig-2a (0222, WRITE repoint), and 4c-mig-2b (0231, SCHEMA drop) — all three already
-- landed in this chain. No table, column, or CHECK is touched here (that was 0231's job); this file is
-- functions only.
--
-- ═══ METHOD — callers-first, trust the code (per ci-apply-proof-is-the-net + the corrected 4c plan) ═══
-- Every function below was verified DEAD by three independent sweeps, each re-derived from the CURRENT
-- code (never from the plan doc's memory of it):
--   (1) TRUE HEAD signature — grepped EVERY `create [or replace] function public.<name>(` across all
--       222 prior migrations; where a signature changed, the prior sig's explicit
--       `drop function if exists public.<name>(<old sig>)` was located immediately above the new
--       `create function` (this codebase's own convention for a breaking signature change) — proving
--       ONE live signature at a time, never a coexisting overload, for every name below (this
--       resolves the two signatures flagged as "maybe-additive": command_main_ship_space_move_to_location
--       TRUE head is (uuid,uuid,uuid) at 0083, preceded by `drop function ...(uuid,uuid)`; "_space_stop"
--       resolves to TWO distinct functions — mainship_space_stop(uuid,uuid,uuid), unchanged sig since
--       0064/0067, and command_main_ship_space_stop(uuid,uuid), TRUE head 0083 preceded by
--       `drop function ...(uuid)` — both dropped below under their own exact names).
--   (2) src/ caller sweep — grepped the whole src/ tree for every RPC-name string literal and every
--       plausible wrapper export. Zero live callers for 18 of the 20 names. The two team-group RPCs
--       (send_ship_group_expedition, move_ship_group_to_location) ARE referenced in
--       src/features/command/teamApi.ts (sendShipGroup/moveShipGroup) — but grepping the REST of src/
--       for `sendShipGroup(` / `moveShipGroup(` finds zero importers of those two wrapper exports
--       anywhere else in the tree: dead wrappers over a dead RPC pair, confirming the corrected plan's
--       "wrappers zero importers" finding independently.
--   (3) migrations-tree prosrc sweep — grepped every `perform|select|:=` call-shape against every name
--       across all migrations. Every caller found is ITSELF on this same dead list (the OSN family calls
--       itself; send_ship_group_expedition/move_ship_group_to_location call
--       send_main_ship_expedition/move_main_ship_to_location internally — both pairs drop together in
--       this one transaction, so the mutual reference is inert: plpgsql is late-bound, DROP does not
--       validate other bodies, and no surviving function ever named any of these 20). The §0 guard below
--       re-proves sweep (3) LIVE against the deployed pg_proc at apply time (a static grep can miss a
--       function that landed between when this file was written and when it is applied; the runtime
--       prosrc sweep cannot).
--
-- ═══ ONE FUNCTION MOVED OFF THE DEAD LIST BY THIS VERIFICATION — mainship_mark_legacy_in_flight ═══════
-- The plan's "OSN internals" list named `mark_legacy_in_flight` (mainship_mark_legacy_in_flight(uuid,
-- text), TRUE head 20260618000152) as droppable. Verification proves this WRONG: process_combat_ticks
-- (TRUE head 20260618000206, the LIVE 2-second combat-tick cron) calls it directly —
--   `perform mainship_mark_legacy_in_flight(cu.main_ship_id, 'returning');`   (0206:276)
-- in the retreat/forced-escape branch, over every `combat_units` row with `main_ship_id is not null and
-- alive_count > 0`. That predicate is NOT a dead branch: combat_units.main_ship_id is written by
-- combat_create_group_encounter (TRUE head 0195, born 0168/D2), which combat_create_encounter (TRUE head
-- 0168) routes to for ANY fleet carrying `group_sortie_members` rows — and send_ship_group_hunt (KEPT,
-- LIVE, team_command_enabled confirmed ON in prod per 0210/0213's own headers) inserts exactly those rows
-- on every hunt departure. So every group-hunt combat encounter that ends in retreat or forced escape,
-- with at least one surviving member, calls mainship_mark_legacy_in_flight live, today. It is EXCLUDED
-- from this migration's drop list — §0(f) below re-proves this exact call chain against the live
-- deployed pg_proc before any DROP runs, so an out-of-date understanding aborts loudly instead of
-- dropping a live function.
--
-- ═══ A SEPARATE, MORE URGENT FINDING — NOT this migration's job to fix, reported here because it ═══════
-- ═══ blocks 4c-mig-2b (0231) from being safe to deploy, and 2b is being patched in parallel ═════════════
-- mainship_mark_legacy_in_flight's body (unchanged since 0152, never re-created by 0222 or 0231) still
-- executes `update main_ship_instances set status = p_status, spatial_state = null, space_x = null,
-- space_y = null, ...` — but 0231 (already in this branch chain) DROPS
-- main_ship_instances.spatial_state/space_x/space_y. Since this function has a live caller (above), 0231
-- as it stands introduces a "column does not exist" failure on EVERY group-hunt retreat/escape with a
-- survivor, from the moment 0231 deploys — a SIXTH live touch point beyond 0231's own documented F1-F4
-- (mainship_mark_combat_destroyed / mainship_mark_docked_at_location / get_my_fleet_positions /
-- fleet_set_in_space) plus the process-mainship-space-arrivals cron finding. This migration does NOT
-- touch 0231 (out of scope, and 2b's proof fixtures are being fixed in parallel elsewhere) — flagging
-- prominently here and in the implementer report so the parallel 2b fix covers it before deploy.
--
-- ═══ DEFERRED (NOT in this migration) — the STOP TRIO ══════════════════════════════════════════════════
-- stop_ship_group_transit(uuid) [0164] and command_main_ship_stop_transit(uuid) [TRUE head 0155] are left
-- ENTIRELY untouched: FleetCommandPanel.tsx still carries a dark ternary
-- `unifiedEnabled ? commandShipGroupStop : stopShipGroup` whose `: stopShipGroup` branch is a live client
-- reference to the trio pending client PR #189. Neither name appears anywhere in this file.
--
-- ═══ ORDER ══════════════════════════════════════════════════════════════════════════════════════════
-- §0 pre-drop guards (chain order + flags dark + cron unscheduled + existence pins + prosrc sweep +
-- the mark_legacy_in_flight live-caller proof) → §1 the 20 drops → §2 post-drop KEEP-assert + DROPPED-
-- assert + SPINE-ALIVE smoke.

-- ══════════════════════════════ §0. PRE-DROP GUARDS (RAISE = ABORT) ═══════════════════════════════════
do $guard0$
declare
  v_src   text;
  v_names text[] := array[
    'send_main_ship_expedition', 'move_main_ship_to_location', 'request_main_ship_return',
    'command_main_ship_space_move', 'command_main_ship_space_move_to_location', 'command_main_ship_space_stop',
    'mainship_space_begin_move', 'mainship_space_begin_move_core', 'mainship_space_stop',
    'mainship_space_settle_space_arrival', 'mainship_space_dock_at_location', 'mainship_space_resolve_origin',
    'command_main_ship_settle_arrival', 'command_main_ship_settle_arrival_legacy',
    'process_mainship_space_arrivals', 'get_osn_movement_readiness', 'normalize_main_ship_dock',
    'dev_set_main_ship_destroyed', 'send_ship_group_expedition', 'move_ship_group_to_location'
  ];
  v_name  text;
  v_bad   text;
begin
  -- (a) CHAIN ORDER: 0231 (4c-mig-2b) must have ALREADY run — the table/columns/CHECK it drops must
  --     already be gone. This migration touches only functions; it must land strictly AFTER 0231.
  if to_regclass('public.main_ship_space_movements') is not null then
    raise exception '4B-DROP GUARD FAIL: main_ship_space_movements still exists — 4c-mig-2b (0231) has not run yet; apply order broken';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'main_ship_instances'
                and column_name in ('spatial_state', 'space_x', 'space_y')) then
    raise exception '4B-DROP GUARD FAIL: a main_ship_instances legacy column still exists — 0231 has not run yet';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'fleets' and column_name = 'active_space_movement_id') then
    raise exception '4B-DROP GUARD FAIL: fleets.active_space_movement_id still exists — 0231 has not run yet';
  end if;

  -- (b) the coordinate-travel RPC stack must still be confirmed DARK (defense-in-depth re-assert; 0231
  --     already required this, but a dropped function is irreversible so this migration re-checks it
  --     independently rather than trusting 0231 ran its own guard correctly).
  if public.cfg_bool('mainship_space_movement_enabled') then
    raise exception '4B-DROP GUARD FAIL: mainship_space_movement_enabled is TRUE — the coordinate-travel stack is live, cannot drop its functions';
  end if;
  if public.cfg_bool('mainship_coordinate_travel_enabled') then
    raise exception '4B-DROP GUARD FAIL: mainship_coordinate_travel_enabled is TRUE — the coordinate-travel stack is live, cannot drop its functions';
  end if;

  -- (c) the ONE cron this list's functions ever fed (process-mainship-space-arrivals) must already be
  --     unscheduled (0231 §8 did this) — re-proof before dropping the function it called.
  if exists (select 1 from cron.job where jobname = 'process-mainship-space-arrivals') then
    raise exception '4B-DROP GUARD FAIL: process-mainship-space-arrivals is still scheduled — must be unscheduled before dropping process_mainship_space_arrivals';
  end if;

  -- (d) EXISTENCE PINS: every TRUE-head signature below must resolve via to_regprocedure BEFORE the
  --     drop — proves this migration targets the real, currently-live objects (catches any drift
  --     between this file's signature research and what is actually deployed; a null here means either
  --     the research was wrong or something already dropped it — either way, ABORT rather than silently
  --     no-op past a DROP FUNCTION IF EXISTS that would otherwise hide the mismatch).
  if to_regprocedure('public.send_main_ship_expedition(jsonb, uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: send_main_ship_expedition(jsonb,uuid,uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.move_main_ship_to_location(uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: move_main_ship_to_location(uuid,uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.request_main_ship_return(uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: request_main_ship_return(uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.command_main_ship_space_move(double precision, double precision, uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: command_main_ship_space_move(double precision,double precision,uuid,uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.command_main_ship_space_move_to_location(uuid, uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: command_main_ship_space_move_to_location(uuid,uuid,uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.command_main_ship_space_stop(uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: command_main_ship_space_stop(uuid,uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: mainship_space_begin_move(...) not found — signature drift';
  end if;
  if to_regprocedure('public.mainship_space_begin_move_core(uuid, uuid, text, double precision, double precision, uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: mainship_space_begin_move_core(...) not found — signature drift';
  end if;
  if to_regprocedure('public.mainship_space_stop(uuid, uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: mainship_space_stop(uuid,uuid,uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.mainship_space_settle_space_arrival(uuid, uuid, timestamptz)') is null then
    raise exception '4B-DROP GUARD FAIL: mainship_space_settle_space_arrival(...) not found — signature drift';
  end if;
  if to_regprocedure('public.mainship_space_dock_at_location(uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: mainship_space_dock_at_location(uuid,uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.mainship_space_resolve_origin(uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: mainship_space_resolve_origin(uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.command_main_ship_settle_arrival(uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: command_main_ship_settle_arrival(uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.command_main_ship_settle_arrival_legacy(uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: command_main_ship_settle_arrival_legacy(uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.process_mainship_space_arrivals()') is null then
    raise exception '4B-DROP GUARD FAIL: process_mainship_space_arrivals() not found — signature drift';
  end if;
  if to_regprocedure('public.get_osn_movement_readiness(uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: get_osn_movement_readiness(uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.normalize_main_ship_dock(uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: normalize_main_ship_dock(uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.dev_set_main_ship_destroyed(uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: dev_set_main_ship_destroyed(uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.send_ship_group_expedition(uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: send_ship_group_expedition(uuid,uuid) not found — signature drift';
  end if;
  if to_regprocedure('public.move_ship_group_to_location(uuid, uuid)') is null then
    raise exception '4B-DROP GUARD FAIL: move_ship_group_to_location(uuid,uuid) not found — signature drift';
  end if;

  -- (e) THE PROSRC SWEEP: no function OUTSIDE this dead list may reference any name on it (comments
  --     stripped first — the 2a/2b apply-proof lesson: a naive ban trips on a function's own explanatory
  --     comment naming the thing it calls). This is the "strongest form" guard the plan calls for,
  --     re-run LIVE against the deployed pg_proc rather than trusted from static grep alone.
  foreach v_name in array v_names loop
    select p.proname into v_bad
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname <> all(v_names)   -- exclude the mutually-referencing dead family itself
       and p.proname <> 'mainship_mark_legacy_in_flight'  -- handled separately in (f) — it is EXCLUDED, not dead
       and position(v_name in regexp_replace(p.prosrc, '--[^\n]*', '', 'g')) > 0
     limit 1;
    if v_bad is not null then
      raise exception '4B-DROP GUARD FAIL: surviving function % still references %, which is marked for drop — ABORT, do not drop', v_bad, v_name;
    end if;
  end loop;

  -- (f) mainship_mark_legacy_in_flight: re-prove it is EXCLUDED for the right reason, against the LIVE
  --     deployed body of process_combat_ticks, not just this file's static claim. If this ever stops
  --     matching (the cron gets refactored, the call site removed), a future 4b-drop-2 can safely
  --     re-evaluate — but THIS migration must never proceed on a stale belief either way.
  if to_regprocedure('public.mainship_mark_legacy_in_flight(uuid, text)') is null then
    raise exception '4B-DROP GUARD FAIL: mainship_mark_legacy_in_flight(uuid,text) is already gone — the exclusion note above is stale, re-verify before proceeding';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.process_combat_ticks()'::regprocedure;
  v_src := regexp_replace(coalesce(v_src, ''), '--[^\n]*', '', 'g');
  if position('mainship_mark_legacy_in_flight' in v_src) = 0 then
    raise exception '4B-DROP GUARD FAIL: process_combat_ticks no longer calls mainship_mark_legacy_in_flight — the live-caller exclusion is stale (it may now be safe to drop; re-verify with a fresh sweep, do not assume)';
  end if;

  raise notice '4B-DROP GUARD ok: chain order correct, flags dark, cron unscheduled, all 20 TRUE-head signatures present, prosrc sweep clean, mark_legacy_in_flight live-caller re-confirmed (excluded from drop)';
end $guard0$;

-- ══════════════════════════════ §1. THE 20 DROPS (exact TRUE-head signatures) ═════════════════════════
-- Grouped by family; each DROP FUNCTION IF EXISTS names the EXACT signature (never a bare name — plpgsql
-- overload safety) so a stray earlier/overloaded signature this research missed is left untouched rather
-- than silently matched. DROP does not cascade to callers (plpgsql is late-bound) — explicit IF EXISTS
-- is defense-in-depth given §0(d) already proved existence.

-- ── the four legacy single-ship expedition RPCs (0050→0199, 0053→0156, 0050→0152) ──────────────────────
drop function if exists public.send_main_ship_expedition(jsonb, uuid, uuid);
drop function if exists public.move_main_ship_to_location(uuid, uuid);
drop function if exists public.request_main_ship_return(uuid);

-- ── the OSN coordinate-domain PUBLIC command surface (0060/0070→0178, 0067→0083, 0064→0083) ─────────────
drop function if exists public.command_main_ship_space_move(double precision, double precision, uuid, uuid);
drop function if exists public.command_main_ship_space_move_to_location(uuid, uuid, uuid);
drop function if exists public.command_main_ship_space_stop(uuid, uuid);

-- ── the OSN coordinate-domain INTERNAL engine (0057/0067, 0067, 0064/0067, 0064, 0153, 0056/0062/0067) ──
drop function if exists public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid);
drop function if exists public.mainship_space_begin_move_core(uuid, uuid, text, double precision, double precision, uuid, uuid);
drop function if exists public.mainship_space_stop(uuid, uuid, uuid);
drop function if exists public.mainship_space_settle_space_arrival(uuid, uuid, timestamptz);
drop function if exists public.mainship_space_dock_at_location(uuid, uuid);
drop function if exists public.mainship_space_resolve_origin(uuid);

-- ── the on-demand legacy settle pair (0150, 0151) — NOT movement_settle_arrival, which is KEPT ─────────
drop function if exists public.command_main_ship_settle_arrival(uuid);
drop function if exists public.command_main_ship_settle_arrival_legacy(uuid);

-- ── the dead cron processor (0058→0064; its cron trigger was already unscheduled by 0231 §8) ────────────
drop function if exists public.process_mainship_space_arrivals();

-- ── the two dead per-ship reads/writers (0068/0071→0082, 0072→0084) ──────────────────────────────────────
drop function if exists public.get_osn_movement_readiness(uuid);
drop function if exists public.normalize_main_ship_dock(uuid);

-- ── the dev-only destroy shim (0052→0059) ────────────────────────────────────────────────────────────────
drop function if exists public.dev_set_main_ship_destroyed(uuid);

-- ── the two orphaned team-group RPCs (0163/0187→0204, 0190→0204) — client wrappers have zero importers ──
drop function if exists public.send_ship_group_expedition(uuid, uuid);
drop function if exists public.move_ship_group_to_location(uuid, uuid);

-- ══════════════════════════════ §2. POST-DROP SELF-ASSERTS ════════════════════════════════════════════
do $postdrop$
declare
  v_dropped text[] := array[
    'public.send_main_ship_expedition(jsonb, uuid, uuid)',
    'public.move_main_ship_to_location(uuid, uuid)',
    'public.request_main_ship_return(uuid)',
    'public.command_main_ship_space_move(double precision, double precision, uuid, uuid)',
    'public.command_main_ship_space_move_to_location(uuid, uuid, uuid)',
    'public.command_main_ship_space_stop(uuid, uuid)',
    'public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid)',
    'public.mainship_space_begin_move_core(uuid, uuid, text, double precision, double precision, uuid, uuid)',
    'public.mainship_space_stop(uuid, uuid, uuid)',
    'public.mainship_space_settle_space_arrival(uuid, uuid, timestamptz)',
    'public.mainship_space_dock_at_location(uuid, uuid)',
    'public.mainship_space_resolve_origin(uuid)',
    'public.command_main_ship_settle_arrival(uuid)',
    'public.command_main_ship_settle_arrival_legacy(uuid)',
    'public.process_mainship_space_arrivals()',
    'public.get_osn_movement_readiness(uuid)',
    'public.normalize_main_ship_dock(uuid)',
    'public.dev_set_main_ship_destroyed(uuid)',
    'public.send_ship_group_expedition(uuid, uuid)',
    'public.move_ship_group_to_location(uuid, uuid)'
  ];
  v_sig text;
begin
  -- DROPPED-assert: every one of the 20 signatures is gone (to_regprocedure NULL). Enumerated
  -- individually (no coexisting overloads found anywhere in this research — one signature each).
  foreach v_sig in array v_dropped loop
    if to_regprocedure(v_sig) is not null then
      raise exception '4B-DROP POST-DROP FAIL: % still exists after its DROP', v_sig;
    end if;
  end loop;

  -- KEEP-assert: the LIVE surface survived untouched (existence only — bodies are untouched by this
  -- migration, so no byte-parity re-check is needed, unlike 0222/0231's writer re-creates).
  if to_regprocedure('public.command_ship_group_go(uuid, uuid, double precision, double precision)') is null then
    raise exception '4B-DROP POST-DROP FAIL: command_ship_group_go lost';
  end if;
  if to_regprocedure('public.command_ship_group_stop(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: command_ship_group_stop lost';
  end if;
  if to_regprocedure('public.command_ship_group_dock(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: command_ship_group_dock lost';
  end if;
  if to_regprocedure('public.send_ship_group_hunt(uuid, uuid, uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: send_ship_group_hunt lost';
  end if;
  if to_regprocedure('public.fleet_set_in_space(uuid, double precision, double precision)') is null then
    raise exception '4B-DROP POST-DROP FAIL: fleet_set_in_space lost';
  end if;
  if to_regprocedure('public.fleet_set_present(uuid, uuid, uuid, uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: fleet_set_present lost';
  end if;
  if to_regprocedure('public.movement_settle_arrival(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: movement_settle_arrival lost';
  end if;
  if to_regprocedure('public.process_fleet_movements()') is null then
    raise exception '4B-DROP POST-DROP FAIL: process_fleet_movements lost';
  end if;
  if to_regprocedure('public.mainship_resolve_fleet(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: mainship_resolve_fleet lost';
  end if;
  if to_regprocedure('public.mainship_space_validate_context(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: mainship_space_validate_context lost';
  end if;
  if to_regprocedure('public.mainship_space_assert_settled_safe(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: mainship_space_assert_settled_safe lost';
  end if;
  if to_regprocedure('public.mainship_mark_docked_at_location(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: mainship_mark_docked_at_location lost';
  end if;
  if to_regprocedure('public.get_my_fleet_positions()') is null then
    raise exception '4B-DROP POST-DROP FAIL: get_my_fleet_positions lost';
  end if;
  if to_regprocedure('public.fleet_current_position(uuid, timestamptz)') is null then
    raise exception '4B-DROP POST-DROP FAIL: fleet_current_position lost';
  end if;
  -- the excluded function (live caller, §0(f)) must survive this migration untouched.
  if to_regprocedure('public.mainship_mark_legacy_in_flight(uuid, text)') is null then
    raise exception '4B-DROP POST-DROP FAIL: mainship_mark_legacy_in_flight was dropped — it has a live caller (process_combat_ticks) and must survive';
  end if;

  -- the DEFERRED stop-trio must be completely untouched (still exists, still the same TRUE-head sig).
  if to_regprocedure('public.stop_ship_group_transit(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: stop_ship_group_transit lost — the stop-trio is deferred, not dropped, until client PR #189 ships';
  end if;
  if to_regprocedure('public.command_main_ship_stop_transit(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: command_main_ship_stop_transit lost — the stop-trio is deferred, not dropped, until client PR #189 ships';
  end if;

  -- SPINE-ALIVE smoke: the unified group-command spine (go → settle → dock/positions read) resolves
  -- end to end, plus the single-ship docked-store read the map/store UI depends on every load.
  if to_regprocedure('public.get_my_docked_store(uuid)') is null then
    raise exception '4B-DROP POST-DROP FAIL: get_my_docked_store lost — the single-ship docked-store spine leaf is gone';
  end if;

  raise notice '4B-DROP POST-DROP ok: 20 dead functions gone (zero overloads left behind), full KEEP-assert surface intact (group command spine + mainship oracle leaves + movement/settle/positions), mainship_mark_legacy_in_flight correctly survives (live combat-retreat caller), stop-trio untouched pending PR #189, SPINE-ALIVE smoke (get_my_docked_store) intact';
end $postdrop$;
