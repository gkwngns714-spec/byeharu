-- TEAM-COMMAND ACTIVATION — the STAGED FLIP operation (docs/TEAM_ACTIVATION_PACKET.md §6,
-- recommendations approved 2026-07-12; docs/TEAM_COMMAND.md → ACTIVATION CHECKLIST).
--
-- ██ HUMAN ACTIVATION TOOL ██ — this script is run BY THE HUMAN, deliberately, against prod.
-- It is NOT run by CI and nothing flips at build/deploy time. Each run of this file IS the
-- recorded human go decision for the server-side switch.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ───────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000170 (the hull-stats prep migration is deployed);
--     • starter_frigate carries the seeded base stats {attack 15, defense 10} (0170 really applied);
--     • every config key this script writes already exists (no typo can invent a key).
--   STAGE 1 — pre-flip knobs (packet §6 stage 1.2; reversible one-liners, set_game_config):
--     • main_ship_price        1000 → 250   (§2: seed capital buys a 5-ship roster; unread until
--                                            commissioning lights, so inert seconds later at most)
--     • max_active_fleets      3    → 6     (§4: 3 team slots + 3 solo-send headroom; LIVE-shared
--                                            with legacy sends — harmless at 6, sends are
--                                            self-limited by owned ships)
--   STAGE 2 — the switch (packet §6 stage 2 order):
--     1. mainship_additional_commission_enabled → true  (commissioning opens; §2)
--     2. team_command_enabled                   → true  (every team RPC lights; §6)
--     3. module_crafting_enabled                → true  (§1.4.2: modules are the designed
--     4. module_fitting_enabled                 → true   mid-game damage source — lit WITH teams)
--   STAGE 3 — smoke asserts (read-only): committed cfg values; the team RPC surface exists
--     (all eight client RPCs + the two internal authorities); ship_groups /
--     group_sortie_members selectable; EXACTLY ONE combat cron job (no-second-engine).
--   Emits ACTIVATE_TEAMCMD_PASS_* markers per stage and one final PASS line; any failed assert
--   RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- IDEMPOTENT: safe to re-run — every write is a set_game_config upsert to the same target value;
-- re-running after success just re-asserts and re-commits identical state.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • captain_assignment_enabled / captain_progression_enabled / the captain-slot bump / the
--     memory-shard drop — captains are the FAST-FOLLOW window (packet §3: launch uncaptained).
--   • exploration_enabled — an independent flip (packet §7, scripts/verify-exploration.mjs).
--   • Any table other than game_config. Any DDL. Any migration.
--
-- ── THE FINAL STEP IS NOT IN THIS FILE (packet §6 stage 2.4) ─────────────────────────────────────
--   AFTER this script passes against prod, ship the ONE-LINE frontend PR flipping BOTH compile
--   mirrors in src/features/map/osnReleaseGates.ts:
--       export const TEAM_COMMAND_ENABLED = true as const
--       export const MAINSHIP_ADDITIONAL_ENABLED = true as const
--   → admin merge → Pages deploy mounts: TeamRosterPanel (CommandScreen — the roster/Hunt UI, via
--   TEAM_COMMAND_ENABLED) + the Commission-ship control (CommissionShipPanel) and the ship
--   switcher (ShipScreen aside rail, via MAINSHIP_ADDITIONAL_ENABLED) — the in-client path to
--   ship #2+. (Server flags first, client second — the server rejects are the authority; a
--   lagging client gate is safe, the reverse is not.)
--   THEN run the post-flip proof + manual smoke (packet §6 stage 3;
--   scripts/team-command-proof.sh against the lit environment).
--
-- ── INVOCATION ───────────────────────────────────────────────────────────────────────────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full — the osn-enable.sh pattern)>" \
--        -X -v ON_ERROR_STOP=1 -f scripts/activate-team-command.sql
--   No local psql on this machine (see docs / tooling notes)? Equivalent options:
--     • paste this whole file into the Supabase Dashboard SQL editor and run it once; or
--     • bash scripts/activate-team-command.sh run   (wraps the psql invocation; DB_URL required).
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the clearly-marked ROLLBACK section at the BOTTOM of this file (commented out). Flags are
--   fully reversible; flipping team_command_enabled off strands nothing (the combat cron, settle
--   path, and D3 reconciler key on manifest rows, not the flag — in-flight sorties finish
--   server-side; only NEW team RPC calls reject). Commissioned ships persist (no un-commission
--   path). NEVER lower captain slots once captains occupy them (not this script's concern — it
--   never touches slots — recorded here because it is the one activation write that must never
--   be reversed later).

\set ON_ERROR_STOP on

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; v_atk numeric; v_def numeric; v_missing text;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000170' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000170 — deploy the hull-stats prep migration first', coalesce(v_head, '(none)');
  end if;

  select (base_stats_json->>'attack')::numeric, (base_stats_json->>'defense')::numeric
    into v_atk, v_def from public.main_ship_hull_types where hull_type_id = 'starter_frigate';
  if v_atk is distinct from 15 or v_def is distinct from 10 then
    raise exception 'PRECONDITION FAIL: starter_frigate base stats are attack=% defense=% (want 15/10 — the 0170 seed)', v_atk, v_def;
  end if;

  -- every key this script writes must already exist (refuse to invent config rows via a typo).
  select string_agg(k, ', ') into v_missing
    from unnest(array['main_ship_price','max_active_fleets','mainship_additional_commission_enabled',
                      'team_command_enabled','module_crafting_enabled','module_fitting_enabled']) k
    where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  raise notice 'ACTIVATE_TEAMCMD_PASS_PRECONDITIONS ok: head %, hull stats 15/10 seeded, all 6 config keys present', v_head;
end $$;

-- ══════════ STAGE 1 — pre-flip knobs (packet §6 stage 1.2; §2 price, §4 fleet cap) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'main_ship_price';
  perform public.set_game_config('main_ship_price', '250'::jsonb);
  raise notice 'stage 1: main_ship_price % -> 250', v_before;

  select value::text into v_before from public.game_config where key = 'max_active_fleets';
  perform public.set_game_config('max_active_fleets', '6'::jsonb);
  raise notice 'stage 1: max_active_fleets % -> 6', v_before;

  raise notice 'ACTIVATE_TEAMCMD_PASS_STAGE1 ok: main_ship_price=250, max_active_fleets=6';
end $$;

-- ══════════ STAGE 2 — the switch (packet §6 stage 2, in its order) ══════════
do $$
declare v_before text; k text;
begin
  foreach k in array array['mainship_additional_commission_enabled',  -- 2.1 commissioning opens
                           'team_command_enabled',                    -- 2.2 every team RPC lights
                           'module_crafting_enabled',                 -- §1.4.2 modules light with teams
                           'module_fitting_enabled'] loop
    select value::text into v_before from public.game_config where key = k;
    perform public.set_game_config(k, 'true'::jsonb);
    raise notice 'stage 2: % % -> true', k, v_before;
  end loop;
  raise notice 'ACTIVATE_TEAMCMD_PASS_STAGE2 ok: commission + team_command + module crafting/fitting enabled';
end $$;

-- ══════════ STAGE 3 — smoke asserts (read-only) ══════════
do $$
declare
  n int; k text; v text; fn text;
begin
  -- (a) committed cfg values are exactly the activation state.
  for k, v in select * from (values
      ('team_command_enabled',                    'true'),
      ('mainship_additional_commission_enabled',  'true'),
      ('module_crafting_enabled',                 'true'),
      ('module_fitting_enabled',                  'true'),
      ('main_ship_price',                         '250'),
      ('max_active_fleets',                       '6')) t(key, want) loop
    if (select value #>> '{}' from public.game_config where key = k) is distinct from v then
      raise exception 'SMOKE FAIL: % is % (want %)', k, (select value #>> '{}' from public.game_config where key = k), v;
    end if;
  end loop;
  if not public.cfg_bool('team_command_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(team_command_enabled) still false'; end if;

  -- (b) the whole team RPC surface exists (the eight client RPCs + the two internal authorities +
  --     the adapter). Existence, not execution — the flag-on behavior proof is
  --     scripts/team-command-proof.sh (packet §6 stage 3), run separately.
  foreach fn in array array[
    'public.upsert_ship_group(integer, text)',
    'public.assign_ship_to_group(uuid, uuid)',
    'public.delete_ship_group(uuid)',
    'public.send_ship_group_expedition(uuid, uuid)',
    'public.stop_ship_group_transit(uuid)',
    'public.get_my_group_expedition_preview(uuid, text)',
    'public.get_my_group_expedition_totals(uuid, text)',
    'public.send_ship_group_hunt(uuid, uuid)',
    'public.calculate_group_expedition_stats(uuid, uuid, text)',
    'public.combat_create_group_encounter(uuid)',
    'public.calculate_expedition_stats(uuid, uuid, jsonb, text)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'SMOKE FAIL: function % does not exist', fn; end if;
  end loop;

  -- (c) one cheap sanity select each on the team tables (exist + selectable; counts are FYI).
  select count(*) into n from public.ship_groups;
  raise notice 'smoke: ship_groups rows = %', n;
  select count(*) into n from public.group_sortie_members;
  raise notice 'smoke: group_sortie_members rows = %', n;

  -- (d) EXACTLY ONE combat cron job — the no-second-engine pin (the proof's D1 assert, live).
  select count(*) into n from cron.job where jobname like '%combat%';
  if n <> 1 then raise exception 'SMOKE FAIL: % combat cron jobs (want exactly 1)', n; end if;

  raise notice 'ACTIVATE_TEAMCMD_PASS_SMOKE ok: 6 cfg values, 11 functions present, team tables selectable, 1 combat cron';
end $$;

select 'TEAM-COMMAND ACTIVATION PASS — server side LIVE. Next: the one-line client PR flipping TEAM_COMMAND_ENABLED + MAINSHIP_ADDITIONAL_ENABLED in src/features/map/osnReleaseGates.ts (mounts the roster/Hunt UI + the Commission-ship control + the ship switcher), then scripts/team-command-proof.sh + manual smoke (packet §6 stage 3). Captains remain the fast-follow window.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the server surfaces again, run the reverse writes below (uncomment, run once). Notes:
--   • Flipping team_command_enabled off strands NOTHING: in-flight sorties settle server-side
--     (cron/settle/reconciler key on manifest rows, not the flag); only NEW team RPC calls reject.
--   • Commissioned ships PERSIST (there is no un-commission path); reverting main_ship_price /
--     max_active_fleets is safe and takes effect immediately.
--   • The frontend gate may lag safely in either direction — the server rejects are the authority.
--   • If the captains fast-follow already ran: roll back the captain FLAGS only — NEVER lower
--     base_captain_slots / captain_slots once captains occupy slots 3-6 (the 0122 adapter would
--     raise over-capacity → stats_invalid everywhere).
--
-- begin;
-- select public.set_game_config('team_command_enabled',                   'false'::jsonb);
-- select public.set_game_config('mainship_additional_commission_enabled', 'false'::jsonb);
-- select public.set_game_config('module_crafting_enabled',                'false'::jsonb);
-- select public.set_game_config('module_fitting_enabled',                 'false'::jsonb);
-- select public.set_game_config('max_active_fleets',                      '3'::jsonb);
-- select public.set_game_config('main_ship_price',                        '1000'::jsonb);
-- select key, value from public.game_config
--  where key in ('team_command_enabled','mainship_additional_commission_enabled',
--                'module_crafting_enabled','module_fitting_enabled','max_active_fleets','main_ship_price')
--  order by key;
-- commit;
-- (Also revert the frontend constants to `false as const` in a follow-up PR if they were flipped.)
