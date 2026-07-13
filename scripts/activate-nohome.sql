-- NO-HOME ACTIVATION — the STAGED FLIP that lights launch-from-dock (migration 0199).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT run by CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision for the
-- server-side switch that makes a DOCKED ship able to SEND/HUNT from its port and dock at a chosen
-- return port instead of re-homing (the owner's NO-HOME law).
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ───────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000199 (the NO-HOME migration is deployed);
--     • the launch_from_dock_enabled key already exists (no typo can invent a key);
--     • the widened send/hunt RPCs + the reconciler leaf are deployed (the 0199 surface is live).
--   STAGE 1 — the switch (reversible one-liner, set_game_config):
--     • launch_from_dock_enabled  false → true
--   STAGE 2 — smoke asserts (read-only): the committed flag value; the 0199 function surface exists
--     (the 3-arg send/hunt + the dock-at-return leaf + the 0153 dock helper); fleets.return_location_id
--     present. Emits ACTIVATE_NOHOME_PASS_* markers and one final PASS line; any failed assert RAISES
--     → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- IDEMPOTENT: safe to re-run — the write is a set_game_config upsert to the same target value.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • Any config key other than launch_from_dock_enabled. Any table. Any DDL. Any migration.
--   • team_command_enabled / mainship_send_enabled — those are their own activations; NO-HOME is
--     orthogonal (it changes HOW a launch is sourced/returned, not WHETHER send/hunt are lit).
--
-- ── THE CLIENT STEP (after this passes) ───────────────────────────────────────────────────────────
--   The client reads launch_from_dock_enabled at runtime (strictConfigFlag over game_config) — no
--   compile-time mirror to flip. Once the server flag is lit, a docked team reads as sendable and the
--   return-port picker appears. Server flag first, client is data-driven off it (a lagging read is
--   safe; the server rejects are the authority).
--
-- ── INVOCATION ───────────────────────────────────────────────────────────────────────────────────
--   psql "<prod conn>" -X -v ON_ERROR_STOP=1 -f scripts/activate-nohome.sql
--   No local psql? Paste this whole file into the Supabase Dashboard SQL editor and run it once; or
--   bash scripts/activate-nohome.sh run ACTIVATE_NOHOME   (DB_URL required).
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   Fully reversible — see the commented ROLLBACK at the bottom. Flipping the flag off strands
--   nothing: in-flight docked sorties finish on the recorded return port (the reconciler keys on
--   fleets.return_location_id, not the flag); only NEW launches revert to home-only + base origin.

\set ON_ERROR_STOP on

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare v_head text; fn text;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000199' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000199 — deploy the NO-HOME migration first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from public.game_config g where g.key = 'launch_from_dock_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key launch_from_dock_enabled missing (deploy 0199)';
  end if;
  -- the 0199 function surface must exist (widened RPCs + the reconcile leaf + the 0153 dock helper).
  foreach fn in array array[
    'public.send_main_ship_expedition(jsonb, uuid, uuid)',
    'public.send_ship_group_hunt(uuid, uuid, uuid)',
    'public.nohome_dock_returning_ship(uuid)',
    'public.mainship_mark_docked_at_location(uuid)',
    'public.process_mainship_expeditions()'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist (deploy 0199)', fn; end if;
  end loop;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'fleets' and column_name = 'return_location_id') then
    raise exception 'PRECONDITION FAIL: fleets.return_location_id missing (deploy 0199)';
  end if;
  raise notice 'ACTIVATE_NOHOME_PASS_PRECONDITIONS ok: head %, flag key present, 0199 surface deployed', v_head;
end $$;

-- ══════════ STAGE 1 — the switch ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'launch_from_dock_enabled';
  perform public.set_game_config('launch_from_dock_enabled', 'true'::jsonb);
  raise notice 'ACTIVATE_NOHOME_PASS_STAGE1 ok: launch_from_dock_enabled % -> true', v_before;
end $$;

-- ══════════ STAGE 2 — smoke asserts (read-only) ══════════
do $$
begin
  if (select value #>> '{}' from public.game_config where key = 'launch_from_dock_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: launch_from_dock_enabled is not true after the flip';
  end if;
  if not public.cfg_bool('launch_from_dock_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(launch_from_dock_enabled) still false';
  end if;
  raise notice 'ACTIVATE_NOHOME_PASS_SMOKE ok: launch_from_dock_enabled committed true; docked launch + dock-at-return are LIVE';
end $$;

select 'NO-HOME ACTIVATION PASS — launch-from-dock is LIVE. A docked ship/team now sends/hunts from its port and docks at the chosen return port; home is never required. The client reads the flag at runtime (no compile mirror to flip). Post-flip proof: scripts/team-command-proof.sh against the lit env (the TEAMCMD_PASS_NOHOME block).' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark launch-from-dock again, run the reverse write below (uncomment, run once). In-flight docked
-- sorties still finish on their recorded return port (the reconciler keys on fleets.return_location_id,
-- not the flag); only NEW launches revert to home-only + base origin.
-- begin;
-- select public.set_game_config('launch_from_dock_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'launch_from_dock_enabled';
-- commit;
