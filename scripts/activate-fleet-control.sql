-- FLEET-CONTROL ACTIVATION — the owner's fleet control-model flip (docs/FULL_CAPACITY_PLAN.md §FLEET;
-- migration 0204). The model is FULLY BUILT DARK: the is_command_ship column + set_fleet_command_ship
-- setter, the 8-ship-per-fleet cap in assign_ship_to_group, and the command-ship-required gate in the
-- three group movement RPCs (send_ship_group_expedition / move_ship_group_to_location /
-- send_ship_group_hunt) — all gated on fleet_control_enabled (seeded false). The client mirrors read the
-- SAME flag at runtime via strictConfigFlag('fleet_control_enabled').
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips at
-- build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ██ THE BIG BEHAVIOR CHANGE (read before flipping) ██
--   Flipping this flag instantly INACTIVATES every fleet that has ZERO command ships: it can no longer
--   move, send, or hunt (the group RPCs reject fleet_inactive_no_command) until its owner designates a
--   command ship (Set as command ship, in the Fleets panel → set_fleet_command_ship). On deploy NO ship
--   is a command ship (is_command_ship defaults false), so AT FLIP TIME EVERY EXISTING FLEET IS INACTIVE.
--   This is the owner's deliberate reshape (everything moves as a fleet; a fleet needs a command ship).
--   The smoke below reports how many fleets are currently command-shipless (an FYI, not a block) so the
--   scale of the change is visible. It also enforces the 8-ship-per-fleet assign cap for new adds.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ─────────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000204 AND 0204 recorded in supabase_migrations.schema_migrations;
--     • main_ship_instances.is_command_ship exists; the game_config key fleet_control_enabled exists
--       (0204 seeds it false — a typo can never invent a key; its VALUE is not asserted false so a
--       RE-RUN after success is a supported no-op);
--     • the whole FLEET-CONTROL function surface exists via to_regprocedure (the REAL signatures) AND
--       the DEPLOYED bodies are the CURRENT 0204 heads, prosrc-pinned: set_fleet_command_ship carries
--       the ship_not_in_fleet guard and does NOT read fleet_control_enabled (the designation is always
--       settable); the three movement RPCs carry the fleet_inactive_no_command reject; assign carries
--       the fleet_full cap;
--     • team_command_enabled is COMMITTED true — FLEET-CONTROL reshapes the LIVE team/fleet command
--       system; flipping it on a game where fleets are dark is a dead affordance.
--   STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer):
--     fleet_control_enabled → true.
--   SMOKE (read-only): the flag is committed (raw + cfg_bool); an FYI count of currently-command-shipless
--     fleets (now inactive); the set_fleet_command_ship ACL posture (authenticated-only, never anon).
--   Emits ACTIVATE_FLEETCTRL_PASS_* markers per stage and one final PASS line; any failed assert RAISES
--   → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): safe no-op success. The flag write is a set_game_config upsert
-- to the same value; nothing else is written.
--
-- ── NO CLIENT PR IS NEEDED ─────────────────────────────────────────────────────────────────────────
--   The FLEET-CONTROL client surfaces are RUNTIME-flag-gated (strictConfigFlag('fleet_control_enabled'),
--   read by fetchFleetControlEnabled), NOT compile-gated — there is NO FLEET_CONTROL_* constant in
--   osnReleaseGates.ts. The command-ship toggle + the fleet active/inactive indicator (TeamRosterPanel),
--   the 8-cap surfacing (add-ship picker), the inactive-fleet disable + hint (TeamMapSend), and the hidden
--   per-ship Move affordance (MainShipCommand) all light the moment this flag commits and the client
--   re-polls the config — no deploy, no PR.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ────────────────────────────────────────────────────────────
--   • main_ship_instances.is_command_ship rows — NEVER written here (only set_fleet_command_ship writes
--     them; this script's only direct write is the ONE set_game_config upsert). Owners designate their
--     own command ships from the Fleets panel after the flip.
--   • Every other window's key. Any table other than game_config. Any DDL. Any migration.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ───────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-fleet-control.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / management-API runner, or:
--     bash scripts/activate-fleet-control.sh run ACTIVATE_FLEETCTRL      # DB_URL required
--   AFTER a green run: manual smoke — open Fleets → each fleet shows "Fleet inactive — set a command
--   ship"; Set as command ship on one member → the fleet reads Active and can send/move/hunt again; the
--   add-ship picker refuses a 9th member (Fleet full — 8 ships max); on the map a lone ship shows "Add
--   this ship to a fleet to move it" and the per-ship Move affordance is gone.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). FLAG-ONLY: fleet_control_enabled →
--   false. Every group RPC drops its command-ship gate + the 8-cap again (byte-identical to today), and
--   the client mirrors fall back to today's behavior on their next config poll — INSTANTLY. The
--   is_command_ship designations persist untouched (inert while dark) and reactivate on a re-flip.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; v_missing text; fn text; v_src text;
begin
  -- 0204 deployed AND recorded (head alone is not enough).
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000204' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000204 (the FLEET-CONTROL migration) — deploy it first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations s where s.version = '20260618000204') then
    raise exception 'PRECONDITION FAIL: migration 20260618000204 not recorded as deployed';
  end if;

  -- the additive column + the flag key.
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='main_ship_instances' and column_name='is_command_ship') then
    raise exception 'PRECONDITION FAIL: main_ship_instances.is_command_ship missing (deploy 0204)';
  end if;
  if not exists (select 1 from public.game_config where key = 'fleet_control_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key fleet_control_enabled missing (0204 seeds it false)';
  end if;

  -- the whole FLEET-CONTROL function surface exists — the REAL signatures.
  foreach fn in array array[
    'public.set_fleet_command_ship(uuid, boolean)',
    'public.assign_ship_to_group(uuid, uuid)',
    'public.send_ship_group_expedition(uuid, uuid)',
    'public.move_ship_group_to_location(uuid, uuid)',
    'public.send_ship_group_hunt(uuid, uuid, uuid)',
    'public.cfg_bool(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  -- the DEPLOYED set_fleet_command_ship body: the ship_not_in_fleet guard, and it must NOT read the flag
  -- (the designation is always settable — additive data, inert until the flag gates movement).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.set_fleet_command_ship(uuid, boolean)')::oid;
  if position('ship_not_in_fleet' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed set_fleet_command_ship body lacks the ship_not_in_fleet guard (0204)';
  end if;
  if position('fleet_control_enabled' in v_src) > 0 then
    raise exception 'PRECONDITION FAIL: the deployed set_fleet_command_ship reads fleet_control_enabled (it must be un-gated — the designation is always settable)';
  end if;

  -- the three movement RPCs carry the command-ship gate; assign carries the 8-cap.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.send_ship_group_expedition(uuid, uuid)')::oid;
  if position('fleet_inactive_no_command' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: send_ship_group_expedition lacks the fleet_inactive_no_command gate (0204)'; end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.move_ship_group_to_location(uuid, uuid)')::oid;
  if position('fleet_inactive_no_command' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: move_ship_group_to_location lacks the fleet_inactive_no_command gate (0204)'; end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.send_ship_group_hunt(uuid, uuid, uuid)')::oid;
  if position('fleet_inactive_no_command' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: send_ship_group_hunt lacks the fleet_inactive_no_command gate (0204)'; end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.assign_ship_to_group(uuid, uuid)')::oid;
  if position('fleet_full' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: assign_ship_to_group lacks the fleet_full 8-ship cap (0204)'; end if;

  -- FLEET-CONTROL reshapes the LIVE fleet command system: team_command_enabled must be committed true.
  if (select value #>> '{}' from public.game_config where key = 'team_command_enabled') is distinct from 'true'
     or not public.cfg_bool('team_command_enabled') then
    raise exception 'PRECONDITION FAIL: team_command_enabled is not committed true — FLEET-CONTROL reshapes the live fleet command system; activate it on a live fleet game only';
  end if;

  -- ACL posture: set_fleet_command_ship is authenticated-only, never anon.
  if not has_function_privilege('authenticated', 'public.set_fleet_command_ship(uuid, boolean)', 'execute')
     or has_function_privilege('anon', 'public.set_fleet_command_ship(uuid, boolean)', 'execute') then
    raise exception 'PRECONDITION FAIL: set_fleet_command_ship ACL drifted (want authenticated-only, never anon)';
  end if;

  raise notice 'ACTIVATE_FLEETCTRL_PASS_PRECONDITIONS ok: head %, 0204 recorded, is_command_ship column + fleet_control_enabled key present, the 5 FLEET-CONTROL functions present (real signatures) with the command-ship gate / 8-cap / ship_not_in_fleet-and-un-gated-setter bodies prosrc-pinned, team_command_enabled committed true, ACL intact', v_head;
end $$;

-- ══════════ STAGE 1 — the switch (the ONE flag write) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'fleet_control_enabled';
  perform public.set_game_config('fleet_control_enabled', 'true'::jsonb);
  raise notice 'stage 1: fleet_control_enabled % -> true', v_before;
  raise notice 'ACTIVATE_FLEETCTRL_PASS_STAGE1 ok: fleet_control_enabled=true (uncommitted until the smoke passes — one all-or-nothing txn)';
end $$;

-- ══════════ SMOKE — read-only ══════════
do $$
declare v_inactive int; v_total int;
begin
  -- (a) the committed flag value is exactly the activation state (raw + through the reader).
  if (select value #>> '{}' from public.game_config where key = 'fleet_control_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: fleet_control_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'fleet_control_enabled');
  end if;
  if not public.cfg_bool('fleet_control_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(fleet_control_enabled) still false'; end if;

  -- (b) FYI — how many fleets are now INACTIVE (zero command ships). This is the scale of the reshape:
  --     these fleets cannot move/send/hunt until their owners designate a command ship. NOT a block.
  select count(*) into v_total from public.ship_groups;
  select count(*) into v_inactive from public.ship_groups g
   where not exists (select 1 from public.main_ship_instances i
                       where i.group_id = g.group_id and i.is_command_ship);
  raise notice 'smoke: % of % fleet(s) are now INACTIVE (zero command ships) — their owners must designate a command ship in the Fleets panel to move them again', v_inactive, v_total;

  raise notice 'ACTIVATE_FLEETCTRL_PASS_SMOKE ok: flag committed true; % of % existing fleets inactive pending a command-ship designation (owner action)', v_inactive, v_total;
end $$;

select 'FLEET-CONTROL ACTIVATION PASS — the fleet control-model is LIVE. Every group movement RPC now requires the fleet to have >= 1 command ship (fleet_inactive_no_command otherwise), assign enforces the 8-ship-per-fleet cap (fleet_full), and lone ships route movement through fleets. NO client PR is needed: the FLEET-CONTROL client surfaces are runtime-flag-gated (strictConfigFlag/fetchFleetControlEnabled) and light on the next config poll. IMMEDIATE PLAYER IMPACT: every fleet with no command ship is inactive until its owner uses "Set as command ship" in the Fleets panel.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the fleet control-model again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY: fleet_control_enabled → false. The three group RPCs drop the command-ship gate and
--     assign drops the 8-cap (byte-identical to today's fleet game); the client mirrors fall back to
--     today's behavior on the next config poll — INSTANTLY.
--   • is_command_ship designations persist untouched (inert while dark) and reactivate on a re-flip —
--     nothing to clean up. No table other than game_config was ever written by this script.
--
-- begin;
-- select public.set_game_config('fleet_control_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'fleet_control_enabled';
-- commit;
