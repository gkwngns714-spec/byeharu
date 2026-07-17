-- UNIFIED-MOVEMENT ACTIVATION — THE 4b FLIP ACT (docs/MOVEMENT_UNIFICATION_CHARTER.md §2 + step 4b,
-- including BOTH ⚠ PRE-FLIP OBLIGATION blocks). This is the act that makes the FLEET the only unit
-- of movement in the live game: the unified mover (command_ship_group_go / _stop, 0207-0213) lights,
-- and the three per-ship legacy movement surfaces go dark in the same commit.
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips
-- at build/deploy time. Each run of this file IS the recorded human go decision for the flip.
--
-- ██ THIS IS AN ACT SCRIPT, NOT A MIGRATION — DO NOT MOVE IT INTO supabase/migrations/ ██
--   A migration that RAISES wedges the deploy pipeline and turns the owner's go-moment into a CI
--   gate. An act that RAISES rolls itself back and blocks NOTHING: the world stays exactly as it
--   was, the owner fixes the listed poison, and re-runs when ready. The go decision stays human.
--
-- ── WHAT IT DOES (ONE transaction; the order is load-bearing) ─────────────────────────────────────
--   1. PRECONDITIONS (read-only; RAISE if unmet):
--        • migration head >= 20260618000214 — the hunt-unified migration (charter 4b's SECOND
--          pre-flip obligation: the hunt readiness taught the fleet / no second unified-shape fleet
--          minted mid-hunt) must be DEPLOYED before the flip can run. 0213 (the assign guard) and
--          everything below it ride along by ordering.
--        • the unified surface exists: command_ship_group_go (0207/0208), command_ship_group_stop
--          (0209), mainship_resolve_fleet (0210), ship_group_resolve_fleet (0213) — existence by
--          proname (0214 is deployed ahead of this act and may lawfully widen a signature; an exact
--          to_regprocedure pin here would make this act lie about a live function).
--        • all four game_config keys this act writes already exist (no typo can invent a key):
--          fleet_movement_unified_enabled (seeded 0207), mainship_send_enabled (0050),
--          mainship_space_movement_enabled (0055), mainship_coordinate_travel_enabled (0070).
--   2. THE SWEEP (read-only; RAISE on poison — the flip CANNOT happen over a dirty world):
--        • S1 OFF-MANIFEST MEMBERS (charter 4b ⚠: "a gated guard closes the WRITER going forward
--          only" — 0213 cannot retro-clean state written before it). For every LIVE group-shaped
--          fleet (main_ship_id IS NULL + group_id set + status moving/present/returning), every
--          live member ship of that (player, group) must be on the fleet's FROZEN manifest
--          (group_sortie_members, 0168 — manifest-wins law). A ship assigned into a hunting group
--          BEFORE the guard deployed is off-manifest: lit, mainship_resolve_fleet (0210) would
--          answer the HUNT's fleet for it — the ghost-dock duality (§0) in READ form.
--        • S2 AT-MOST-ONE live group-shaped fleet per (player, group) — the resolver's fail-closed
--          invariant (0210:90-92 returns NULL on v_n > 1, hiding every member on the whole map).
--   3. THE WRITES (LAST, so a sweep RAISE means nothing changed; via the owned set_game_config
--      writer, 0046):
--        fleet_movement_unified_enabled  -> true    (the ONE mover lights: go/stop/resolver/oracle)
--        mainship_send_enabled           -> false   (per-ship expedition send closes)
--        mainship_space_movement_enabled -> false   (per-ship OSN space move/stop closes)
--        mainship_coordinate_travel_enabled -> false (per-ship coordinate travel closes)
--      Turning the three legacy flags OFF is what closes the un-gated per-ship OSN surfaces AND
--      stale cached clients (the server rejects are the authority; a lagging client gate is safe).
--      NOTHING IS LOST: the unified mover carries coordinate travel on the fleet coordinate-go
--      surface (0208 — command_ship_group_go(group, x, y)).
--   4. SMOKE (read-only): the four committed flag values, raw AND through cfg_bool, with
--      ACTUNI_PASS_* NOTICE markers per flag.
--   Any failed assert RAISES → the whole transaction rolls back → NOTHING is applied.
--
-- RE-RUN SEMANTICS: safe no-op success. Every write is a set_game_config upsert to the same target
-- value; re-running after success re-sweeps (still clean — the flipped world mints no new hunts
-- off-manifest) and re-commits identical state. A re-run after a SWEEP RAISE is the designed loop:
-- fix the listed poison, run again.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ───────────────────────────────────────────────────────────
--   • Any table other than game_config (and that only via set_game_config). Any ship/fleet/manifest
--     row — the sweep READS them and refuses; it never "cleans" them itself (unassigning a player's
--     ship is the owner's call, not a side effect of an activation).
--   • Any DDL, any migration, any cron. The per-ship RPC/column/reconciler retirement is step 4b's
--     SERVER DROP migration work, not this act.
--   • Any other window's flag (team_command_enabled, fleet_control_enabled,
--     launch_from_dock_enabled etc. stay exactly as they are).
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ──────────────
--   bash scripts/activate-unified-movement.sh run ACTIVATE_UNIFIED_MOVEMENT
--     (the repo's proven prod path: POST https://api.supabase.com/v1/projects/<ref>/database/query
--      with SUPABASE_ACCESS_TOKEN + SUPABASE_PROJECT_ID from .env.local — see the charter's
--      DB-access note. NOTE: that path returns the LAST statement's rows and an error's message,
--      but NOT raise-notice output — the final PASS row after COMMIT is the success signal there;
--      the ACTUNI_PASS_* notices are visible when run via psql or the Supabase Dashboard editor.)
--   Or paste this whole file into the Supabase Dashboard SQL editor and run it once, or:
--   psql "<prod conn>" -X -v ON_ERROR_STOP=1 -f scripts/activate-unified-movement.sql
--
-- CI PROOF IS A SEPARATE, LATER PASS — NOT THIS FILE'S JOB: the ACTUNI_RAISE_POISON /
-- ACTUNI_FLAGS_ATOMIC / ACTUNI_PASS_CLEAN markers land in scripts/fleetgo-proof.{sql,sh} (owned by
-- that workstream) and prove this act's behavior on the disposable real chain.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). FLAG-ONLY and fully reversible:
--   the four inverse writes restore today's world (unified dark, the three per-ship surfaces back).
--   In-flight unified movements settle server-side regardless — movement_settle_arrival (0208) and
--   the cron read no flag — so flipping back strands nothing; only NEW unified go/stop calls reject.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ 1. PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head    text;
  v_missing text;
begin
  -- (a) the hunt-unified migration must be DEPLOYED: the flip may not run before 0214.
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000214' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000214 — deploy the hunt-unified migration (charter 4b second pre-flip obligation) before flipping', coalesce(v_head, '(none)');
  end if;

  -- (b) the whole unified movement surface exists (by proname — see header for why not
  --     to_regprocedure: 0214 deploys ahead of this act and may lawfully widen a signature).
  select string_agg(fn, ', ') into v_missing
    from unnest(array['command_ship_group_go', 'command_ship_group_stop',
                      'mainship_resolve_fleet', 'ship_group_resolve_fleet']) fn
   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = fn);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: unified movement function(s) missing: % (0207/0209/0210/0213 not all deployed?)', v_missing;
  end if;

  -- (c) every key this act writes must already exist (refuse to invent config rows via a typo).
  select string_agg(k, ', ') into v_missing
    from unnest(array['fleet_movement_unified_enabled', 'mainship_send_enabled',
                      'mainship_space_movement_enabled', 'mainship_coordinate_travel_enabled']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  raise notice 'ACTUNI_PASS_PRECONDITIONS ok: head % (>= 0214), 4 unified functions present, 4 config keys present', v_head;
end $$;

-- ══════════ 2. THE SWEEP (read-only; RAISE on poison — the flip cannot happen over a dirty world) ══
do $$
declare
  v_fleets   integer;
  v_offenders text;
begin
  -- FYI scale: how many live group-shaped fleets are being swept.
  select count(*) into v_fleets
    from public.fleets
   where main_ship_id is null and group_id is not null
     and status in ('moving', 'present', 'returning');
  raise notice 'sweep: % live group-shaped fleet(s) (main_ship_id NULL + group_id set + moving/present/returning)', v_fleets;

  -- S1 — OFF-MANIFEST MEMBERS. For each live group-shaped fleet, every live member ship of its
  -- (player, group) must have a frozen-manifest row (group_sortie_members, 0168: PK fleet_id +
  -- main_ship_id) for THAT fleet. These are ships assigned into a hunting group BEFORE the 0213
  -- guard deployed — the writer is closed going forward, but pre-guard state must be cleaned by a
  -- human, not by this act. ('live member' = status <> 'destroyed': a destroyed ship is pure
  -- lifecycle, 0167, and resolves nothing on the map.)
  select string_agg(format('ship %s (%s, status %s) of group %s is not on the manifest of fleet %s (status %s)',
                           m.main_ship_id, m.name, m.status, f.group_id, f.id, f.status), '; ')
    into v_offenders
    from public.fleets f
    join public.main_ship_instances m
      on m.group_id = f.group_id and m.player_id = f.player_id
   where f.main_ship_id is null and f.group_id is not null
     and f.status in ('moving', 'present', 'returning')
     and m.status <> 'destroyed'
     and not exists (select 1 from public.group_sortie_members gsm
                      where gsm.fleet_id = f.id and gsm.main_ship_id = m.main_ship_id);
  if v_offenders is not null then
    raise exception 'SWEEP S1 FAIL — off-manifest member(s) of a live group-shaped fleet: %. Lit, the resolver (0210) would answer the hunt fleet for these ships — the ghost-dock read duality. REMEDIATION: unassign the listed ship(s) or wait for the sortie to settle, then re-run.', v_offenders;
  end if;

  -- S2 — AT-MOST-ONE live group-shaped fleet per (player, group). Two live unified-shape fleets is
  -- the broken invariant mainship_resolve_fleet fails closed on (0210:90-92 → NULL → every member
  -- of the group goes hidden on the whole map). Same live-status set as the resolver and the 0213
  -- leaf: idle/moving/present/returning.
  select string_agg(format('player %s group %s has %s live group-shaped fleets', t.player_id, t.group_id, t.n), '; ')
    into v_offenders
    from (select player_id, group_id, count(*) as n
            from public.fleets
           where main_ship_id is null and group_id is not null
             and status in ('idle', 'moving', 'present', 'returning')
           group by player_id, group_id
          having count(*) > 1) t;
  if v_offenders is not null then
    raise exception 'SWEEP S2 FAIL — duplicate live group-shaped fleets (the resolver''s fail-closed invariant, 0210): %. REMEDIATION: settle or complete the stray fleet(s), then re-run.', v_offenders;
  end if;

  raise notice 'ACTUNI_PASS_SWEEP ok: no off-manifest members, no duplicate live group-shaped fleets — the world is clean under the flip';
end $$;

-- ══════════ 3. THE WRITES (LAST: if the sweep raised, nothing below ever ran) ══════════
do $$
declare
  v_before text;
  k        text;
  v        jsonb;
begin
  for k, v in select * from (values
      ('fleet_movement_unified_enabled',     'true'::jsonb),   -- the ONE mover lights
      ('mainship_send_enabled',              'false'::jsonb),  -- per-ship expedition send closes
      ('mainship_space_movement_enabled',    'false'::jsonb),  -- per-ship OSN space move/stop closes
      ('mainship_coordinate_travel_enabled', 'false'::jsonb)   -- per-ship coordinate travel closes
    ) t(key, want) loop
    select value::text into v_before from public.game_config where key = k;
    perform public.set_game_config(k, v);
    raise notice 'write: % % -> %', k, v_before, v;
  end loop;
  raise notice 'ACTUNI_PASS_WRITES ok: unified -> true; send/space/coordinate legacy flags -> false (one commit, no half-state)';
end $$;

-- ══════════ 4. SMOKE (read-only: the committed state is exactly the flipped world) ══════════
do $$
declare
  k text;
  v text;
begin
  for k, v in select * from (values
      ('fleet_movement_unified_enabled',     'true'),
      ('mainship_send_enabled',              'false'),
      ('mainship_space_movement_enabled',    'false'),
      ('mainship_coordinate_travel_enabled', 'false')) t(key, want) loop
    if (select value #>> '{}' from public.game_config where key = k) is distinct from v then
      raise exception 'SMOKE FAIL: % is % (want %)', k, (select value #>> '{}' from public.game_config where key = k), v;
    end if;
    raise notice 'ACTUNI_PASS_FLAG %: % (confirmed)', k, v;
  end loop;

  -- and through the server's own accessor (0046) — the value the RPC gates actually read.
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(fleet_movement_unified_enabled) is still false'; end if;
  if public.cfg_bool('mainship_send_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(mainship_send_enabled) is still true'; end if;
  if public.cfg_bool('mainship_space_movement_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(mainship_space_movement_enabled) is still true'; end if;
  if public.cfg_bool('mainship_coordinate_travel_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(mainship_coordinate_travel_enabled) is still true'; end if;

  raise notice 'ACTUNI_PASS_SMOKE ok: all four flags committed and readable through cfg_bool — the fleet is the only unit of movement';
end $$;

commit;

-- The success signal for the Management-API runner: the LAST statement's rows are what that path
-- returns, and this line is only reachable if every statement above succeeded and committed
-- (an error anywhere aborts the rest of the batch, so this select never runs on a failed act).
select 'UNIFIED-MOVEMENT ACTIVATION PASS — the fleet is the ONLY unit of movement. Unified mover LIVE (go/stop/resolver/oracle); the three per-ship movement surfaces are dark (send/space/coordinate). Coordinate travel continues on the fleet coordinate-go surface (0208). Rollback: the commented section at the bottom of this file.' as result;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- Copy-paste recovery: the four inverse writes restore today's exact world (unified dark, the three
-- per-ship surfaces live again). Safe at any time: in-flight unified movements settle server-side
-- regardless (movement_settle_arrival + the cron read no flag — 0208), so nothing strands; only NEW
-- unified go/stop calls reject, and the per-ship movers answer again on the client's next poll.
--
-- begin;
-- select public.set_game_config('fleet_movement_unified_enabled',     'false'::jsonb);
-- select public.set_game_config('mainship_send_enabled',              'true'::jsonb);
-- select public.set_game_config('mainship_space_movement_enabled',    'true'::jsonb);
-- select public.set_game_config('mainship_coordinate_travel_enabled', 'true'::jsonb);
-- select key, value from public.game_config
--  where key in ('fleet_movement_unified_enabled', 'mainship_send_enabled',
--                'mainship_space_movement_enabled', 'mainship_coordinate_travel_enabled')
--  order by key;
-- commit;
