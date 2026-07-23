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
-- ██ THIS ACT CORRECTLY REFUSES TO RUN TODAY ██ — precondition (b3) requires the deployed brake
--   (command_ship_group_stop, 0209) to carry a sortie guard, and today it does not: a lit brake
--   pressed during a live hunt would cancel the encounter's transit and strand the members hunting
--   with a fleet parked in space. The 0209 brake-sortie slice (pre-flip obligation #4) must deploy
--   first; until then this act RAISES at preconditions and commits nothing. That is by design.
--
-- ── WHAT IT DOES (ONE transaction; the order is load-bearing) ─────────────────────────────────────
--   1. PRECONDITIONS (read-only; RAISE if unmet):
--        • migration head >= 20260618000214 — AND, because a version number alone proves nothing
--          about WHICH migration landed as 0214, the hunt-unified OBLIGATION itself is pinned by
--          prosrc: some deployed send_ship_group_hunt body must compose ship_group_resolve_fleet
--          (the unified-fleet consume — charter 4b's SECOND pre-flip obligation: the hunt taught
--          the fleet / no second unified-shape fleet minted mid-hunt).
--        • the deployed brake carries the sortie guard: command_ship_group_stop's prosrc must
--          reference group_sortie_members (pre-flip obligation #4, the 0209 brake-sortie slice).
--          TODAY THIS FAILS — see the block banner above; that is the gate doing its job.
--        • the unified surface exists: command_ship_group_go (0207/0208), command_ship_group_stop
--          (0209), mainship_resolve_fleet (0210), ship_group_resolve_fleet (0213) — existence by
--          proname (0214 is deployed ahead of this act and may lawfully widen a signature; an exact
--          to_regprocedure pin here would make this act lie about a live function).
--        • all four game_config keys this act writes already exist (no typo can invent a key):
--          fleet_movement_unified_enabled (seeded 0207), mainship_send_enabled (0050),
--          mainship_space_movement_enabled (0055), mainship_coordinate_travel_enabled (0070).
--   2. THE SWEEP (read-only; RAISE on poison — the flip CANNOT happen over a dirty world):
--        • S2 FIRST — AT-MOST-ONE live group-shaped fleet per (player, group) — the resolver's
--          fail-closed invariant (0210:90-92 returns NULL on v_n > 1, hiding every member on the
--          whole map). Checked before S1 because a duplicate-fleet world would otherwise surface
--          as S1 offenders carrying the WRONG "unassign" remediation.
--        • S1 OFF-MANIFEST MEMBERS (charter 4b ⚠: "a gated guard closes the WRITER going forward
--          only" — 0213 cannot retro-clean state written before it). For every LIVE group-shaped
--          fleet (main_ship_id IS NULL + group_id set + status idle/moving/present/returning)
--          THAT CARRIES A FROZEN MANIFEST (>= 1 group_sortie_members row — i.e. a hunt sortie;
--          the unified GO mints no manifest, so this scope is loss-free pre-flip and is what makes
--          the act re-runnable post-flip), every live member ship of that (player, group) must be
--          on the fleet's manifest (0168 — manifest-wins law). A ship assigned into a hunting
--          group BEFORE the guard deployed is off-manifest: lit, mainship_resolve_fleet (0210)
--          would answer the HUNT's fleet for it — the ghost-dock duality (§0) in READ form.
--   3. THE WRITES (LAST, so a sweep RAISE means nothing changed; ONE DO block, so no execution
--      model can half-flip; via the owned set_game_config writer, 0046):
--        fleet_movement_unified_enabled  -> true    (the ONE mover lights: go/stop/resolver/oracle)
--        mainship_send_enabled           -> false   (per-ship expedition send closes)
--        mainship_space_movement_enabled -> false   (per-ship OSN space move/stop closes)
--        mainship_coordinate_travel_enabled -> false (per-ship coordinate travel closes)
--      Turning the three legacy flags OFF is what closes the un-gated per-ship OSN surfaces AND
--      stale cached clients (the server rejects are the authority; a lagging client gate is safe).
--      NOTHING IS LOST: the unified mover carries coordinate travel on the fleet coordinate-go
--      surface (0208 — command_ship_group_go(group, x, y)).
--   4. SMOKE (read-only, PRE-COMMIT): the four written flag values, raw AND through cfg_bool, with
--      ACTUNI_PASS_* NOTICE markers per flag. A failed smoke still rolls the WHOLE act back —
--      nothing is committed until the final COMMIT below it succeeds.
--   Any failed assert RAISES → the whole transaction rolls back → NOTHING is applied.
--
-- RE-RUN SEMANTICS: genuinely re-runnable, and here is the actual reasoning (not hand-waving):
--   the writes are set_game_config upserts to fixed target values (idempotent), and S1 is scoped
--   to MANIFEST-CARRYING fleets — a healthy unified GO fleet mints no group_sortie_members rows,
--   so a post-flip (or rollback→re-flip) world with unified fleets present/moving does NOT flag
--   their members. Post-flip hunts mint manifests through the 0214 unified-consume hunt and the
--   0213 assign guard, so they sweep clean too. A re-run after a SWEEP RAISE is the designed loop:
--   fix the listed poison, run again.
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
--      DB-access note. Run the CANARY documented in the .sh header FIRST. NOTE: that path returns
--      the LAST statement's rows and an error's message, but NOT raise-notice output — the final
--      PASS row after COMMIT is the success signal there; the ACTUNI_PASS_* notices are visible
--      when run via psql or the Supabase Dashboard editor.)
--   Or paste this whole file into the Supabase Dashboard SQL editor and run it once, or:
--   psql "<prod conn>" -X -v ON_ERROR_STOP=1 -f scripts/activate-unified-movement.sql
--
-- CI PROOF IS A SEPARATE, LATER PASS — NOT THIS FILE'S JOB: the ACTUNI_RAISE_POISON /
-- ACTUNI_FLAGS_ATOMIC / ACTUNI_PASS_CLEAN markers land in scripts/fleetgo-proof.{sql,sh} (owned by
-- that workstream) and prove this act's behavior on the disposable real chain.
--
-- ── ROLLBACK — ⛔ RETIRED. THERE IS NO ONE-COMMAND ROLLBACK ANY MORE ⛔ ─────────────────────────────
--   The four-inverse-write rollback this header used to promise was DESTROYED BY THE SERVER DROPS
--   (migrations 0231 + 0232) that landed after the flip. Re-lighting the legacy flags today does
--   not restore the legacy movement path — it re-opens a path whose schema and functions no longer
--   exist. The ROLLBACK section at the BOTTOM is now a FAIL-CLOSED GUARD: uncomment and run it and
--   it RAISES on its first statement, before any write. Full explanation there.
--   Restoring legacy movement now requires NEW FORWARD MIGRATIONS, not a flag flip.

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
  -- (a) the 0214 head gate — necessary but NOT sufficient (any migration could carry that number);
  --     the obligation itself is pinned at (b2).
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

  -- (b2) the hunt-unified OBLIGATION, pinned by prosrc — the version number at (a) proves only
  --      that SOME 0214 landed; THIS proves it was the right one. The unified-consume hunt
  --      composes ship_group_resolve_fleet (the 0213 leaf), which the pre-0214 hunt provably
  --      does not — so an unrelated migration wearing the 0214 number cannot open this gate.
  if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'send_ship_group_hunt'
         and position('ship_group_resolve_fleet' in p.prosrc) > 0) then
    raise exception 'PRECONDITION FAIL: the deployed hunt is not the unified-consume version — 0214 not applied (no send_ship_group_hunt body composes ship_group_resolve_fleet)';
  end if;

  -- (b3) the lit-brake OBLIGATION (pre-flip obligation #4) — the deployed brake must carry a
  --      sortie guard. The 0209 body has NONE today: lit, a player pressing Stop during a live
  --      hunt cancels the encounter's transit and strands the members hunting with a fleet parked
  --      in space. The brake-sortie slice re-creates command_ship_group_stop reading the frozen
  --      manifest; until that body is the deployed one, THIS act refuses to flip.
  if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'command_ship_group_stop'
         and position('group_sortie_members' in p.prosrc) > 0) then
    raise exception 'PRECONDITION FAIL: the lit brake has no sortie guard — the 0209 brake-sortie slice must deploy before the flip (command_ship_group_stop does not reference group_sortie_members)';
  end if;

  -- (c) every key this act writes must already exist (refuse to invent config rows via a typo).
  select string_agg(k, ', ') into v_missing
    from unnest(array['fleet_movement_unified_enabled', 'mainship_send_enabled',
                      'mainship_space_movement_enabled', 'mainship_coordinate_travel_enabled']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  raise notice 'ACTUNI_PASS_PRECONDITIONS ok: head % (>= 0214), hunt composes the unified leaf, brake carries the sortie guard, 4 unified functions present, 4 config keys present', v_head;
end $$;

-- ══════════ 2. THE SWEEP (read-only; RAISE on poison — the flip cannot happen over a dirty world) ══
do $$
declare
  v_fleets    integer;
  v_manifest  integer;
  v_offenders text;
begin
  -- FYI scale: how many live group-shaped fleets are being swept, and how many carry a manifest
  -- (the S1 scope — pre-flip every live group-shaped fleet is a hunt and carries one; a unified
  -- GO fleet mints none).
  select count(*) into v_fleets
    from public.fleets f
   where f.main_ship_id is null and f.group_id is not null
     and f.status in ('idle', 'moving', 'present', 'returning');
  select count(*) into v_manifest
    from public.fleets f
   where f.main_ship_id is null and f.group_id is not null
     and f.status in ('idle', 'moving', 'present', 'returning')
     and exists (select 1 from public.group_sortie_members gsm2 where gsm2.fleet_id = f.id);
  raise notice 'sweep: % live group-shaped fleet(s); % carry a frozen manifest (the S1 scope)', v_fleets, v_manifest;

  -- S2 FIRST — AT-MOST-ONE live group-shaped fleet per (player, group). Two live unified-shape
  -- fleets is the broken invariant mainship_resolve_fleet fails closed on (0210:90-92 → NULL →
  -- every member of the group goes hidden on the whole map). Same live-status set as the resolver
  -- and the 0213 leaf: idle/moving/present/returning. Ordered before S1 because a duplicate-fleet
  -- world would otherwise surface as S1 offenders with the wrong "unassign" remediation.
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

  -- S1 — OFF-MANIFEST MEMBERS, scoped to MANIFEST-CARRYING fleets. For each live group-shaped
  -- fleet that has >= 1 frozen-manifest row (group_sortie_members, 0168: PK fleet_id +
  -- main_ship_id — i.e. a hunt sortie; the unified GO mints no manifest, which is exactly why the
  -- scope makes this act re-runnable post-flip without flagging healthy unified fleets), every
  -- live member ship of its (player, group) must be ON that manifest. These offenders are ships
  -- assigned into a hunting group BEFORE the 0213 guard deployed — the writer is closed going
  -- forward, but pre-guard state must be cleaned by a human, not by this act. ('live member' =
  -- status <> 'destroyed': a destroyed ship is pure lifecycle, 0167, and resolves nothing on the
  -- map.)
  select string_agg(format('ship %s (%s, status %s) of group %s is not on the manifest of fleet %s (status %s)',
                           m.main_ship_id, m.name, m.status, f.group_id, f.id, f.status), '; ')
    into v_offenders
    from public.fleets f
    join public.main_ship_instances m
      on m.group_id = f.group_id and m.player_id = f.player_id
   where f.main_ship_id is null and f.group_id is not null
     and f.status in ('idle', 'moving', 'present', 'returning')
     and exists (select 1 from public.group_sortie_members gsm2
                  where gsm2.fleet_id = f.id)
     and m.status <> 'destroyed'
     and not exists (select 1 from public.group_sortie_members gsm
                      where gsm.fleet_id = f.id and gsm.main_ship_id = m.main_ship_id);
  if v_offenders is not null then
    raise exception 'SWEEP S1 FAIL — off-manifest member(s) of a live sortie fleet: %. Lit, the resolver (0210) would answer the hunt fleet for these ships — the ghost-dock read duality. REMEDIATION: unassign the listed ship(s) or wait for the sortie to settle, then re-run.', v_offenders;
  end if;

  raise notice 'ACTUNI_PASS_SWEEP ok: no duplicate live group-shaped fleets, no off-manifest sortie members — the world is clean under the flip';
end $$;

-- ══════════ 3. THE WRITES (LAST: if the sweep raised, nothing below ever ran; ONE block: atomic) ══
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
  raise notice 'ACTUNI_PASS_WRITES ok: unified -> true; send/space/coordinate legacy flags -> false (one block, one commit, no half-state)';
end $$;

-- ══════════ 4. SMOKE (read-only, PRE-COMMIT: a failed assert still rolls the whole act back) ══════
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

  raise notice 'ACTUNI_PASS_SMOKE ok: all four flags written and readable through cfg_bool — the commit below makes the fleet the only unit of movement';
end $$;

commit;

-- The success signal for the Management-API runner: the LAST statement's rows are what that path
-- returns, and this line is only reachable if every statement above succeeded and committed
-- (an error anywhere aborts the rest of the batch, so this select never runs on a failed act).
select 'UNIFIED-MOVEMENT ACTIVATION PASS — the fleet is the ONLY unit of movement. Unified mover LIVE (go/stop/resolver/oracle); the three per-ship movement surfaces are dark (send/space/coordinate). Coordinate travel continues on the fleet coordinate-go surface (0208). Rollback: the commented section at the bottom of this file.' as result;

-- ═══════════ ROLLBACK (manual) — ⛔ RETIRED: THE FLAG ROLLBACK IS GONE AND FAILS CLOSED ⛔ ═════════
--
-- ██ DO NOT RE-LIGHT mainship_send_enabled / mainship_space_movement_enabled /
--    mainship_coordinate_travel_enabled. ██  The four inverse set_game_config writes that used to
-- live here were deleted on purpose. They are no longer a recovery; they are an OUTAGE TRIGGER.
--
-- WHY (the drops that landed AFTER the flip — this is not speculation, it is deployed schema):
--   • 20260618000231_movement_schema_drop.sql §6 (:1559-1562) DROPPED the columns
--     main_ship_instances.spatial_state, .space_x and .space_y. The same migration's §5
--     (:1552-1556) also removed 'stationary' from main_ship_instances_status_check.
--   • 20260618000232_movement_function_drop.sql §1 (:231-264) DROPPED all 20 legacy movement
--     functions — send_main_ship_expedition, move_main_ship_to_location, request_main_ship_return,
--     the command_main_ship_space_* surface, the mainship_space_* engine, the legacy settle pair,
--     process_mainship_space_arrivals, get_osn_movement_readiness, normalize_main_ship_dock,
--     dev_set_main_ship_destroyed, send_ship_group_expedition, move_ship_group_to_location.
--     A flag cannot un-drop a function. Re-lighting the flags re-opens client entry points whose
--     server functions do not exist (PostgREST 404 / "function does not exist").
--   • THE SPECIFIC HAZARD — command_main_ship_stop_transit(uuid) SURVIVED the 0232 drop on purpose
--     (0232:67, and its post-drop self-assert at 0232:354-355 requires it to still exist, because
--     the stop-trio retirement is deferred until client PR #189 ships). Its deployed body is the
--     0155 one, and that body still READS spatial_state (20260618000155…:104) and still WRITES
--     status='stationary', spatial_state, space_x, space_y (…:148-153) — all of which 0231 removed.
--     TODAY it is harmless: its very first gate is `if not cfg_bool('mainship_send_enabled')`
--     (…:79-81), so with the flag FALSE it returns a clean {ok:false, code:'feature_disabled'} and
--     touches nothing. RE-LIGHTING mainship_send_enabled CONVERTS THAT CLEAN REJECT INTO A RUNTIME
--     `column "spatial_state" does not exist` RAISE ON A LIVE PRODUCTION PATH — for every player
--     who presses Stop mid-transit. That is the whole reason this section now fails closed.
--
-- WHAT A REAL ROLLBACK WOULD REQUIRE NOW (forward migrations, reviewed and deployed — never a flip):
--   1. re-add main_ship_instances.spatial_state / space_x / space_y and re-widen the status CHECK
--      to accept 'stationary' (undo 0231 §5/§6), plus a backfill decision for every existing row;
--   2. re-create the 20 dropped functions from their last-known bodies with their grants (undo 0232);
--   3. reconcile the world: a unified go DISSOLVES its members' per-ship fleets + presences (0208),
--      so — WORLD-EXACT ONLY IF NO UNIFIED GO EVER RAN — members of any group that moved would read
--      contradictory_state/hidden with no per-ship fleet for the re-lit legacy movers to drive;
--   4. only THEN consider the flag values. The flags are the last step of a rollback, not the whole
--      rollback. (Historical note, kept so the record is not lost: before the drops this section was
--      four inverse set_game_config writes and was genuinely flag-exact.)
--
-- The block below is the ONLY thing that remains here. If you uncomment and run it — and someone
-- eventually will — it RAISES on its first statement, before any write of any kind.
--
-- begin;
-- do $rollback_retired$
-- begin
--   raise exception using
--     errcode = 'raise_exception',
--     message = 'LEGACY MOVEMENT ROLLBACK IS RETIRED — REFUSING TO RUN (no write was made)',
--     detail  = 'Flipping mainship_send_enabled / mainship_space_movement_enabled / '
--               'mainship_coordinate_travel_enabled back to true does NOT restore legacy movement. '
--               'Migration 0231 dropped main_ship_instances.spatial_state/space_x/space_y (and '
--               'removed ''stationary'' from the status CHECK); migration 0232 dropped all 20 legacy '
--               'movement functions. command_main_ship_stop_transit(uuid) deliberately SURVIVED 0232 '
--               'and its deployed 0155 body still reads spatial_state and writes space_x/space_y — '
--               'today mainship_send_enabled=false makes it reject cleanly with feature_disabled, but '
--               're-lighting that flag turns the clean reject into a live "column spatial_state does '
--               'not exist" error for every player who presses Stop mid-transit.',
--     hint    = 'Restoring the legacy movement path requires NEW FORWARD MIGRATIONS that re-create the '
--               '0231 columns/CHECK and the 0232 functions (and reconcile members whose per-ship fleets '
--               'a unified go dissolved). Only after those deploy may the flags be reconsidered.';
-- end
-- $rollback_retired$;
-- commit;
