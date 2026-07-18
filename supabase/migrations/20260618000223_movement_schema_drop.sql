-- 4C-MIG-2B — MOVEMENT SCHEMA DROP (migration 0223): the IRREVERSIBLE stage of the legacy-movement
-- retirement. In ONE all-or-nothing transaction this migration: (1) reconciles orphan legacy data,
-- (2) stops the LAST live writers from touching the doomed columns, (3) drops the 0054/0055 spatial
-- CHECK constraints, (4) narrows the status CHECK (retires 'stationary'), (5) drops
-- main_ship_instances.spatial_state/space_x/space_y, (6) drops fleets.active_space_movement_id (+its
-- FK/2 CHECKs/index), (7) drops main_ship_space_command_receipts.movement_id, (8) DROPs TABLE
-- main_ship_space_movements, and (9) unschedules the one cron job that reads it. Deploys strictly
-- AFTER 4c-mig-1 (0221, READ repoint) and 4c-mig-2a (0222, WRITE repoint) — both dual-safe, both
-- already live in this chain. NO FUNCTION is dropped here (that is 4b-drop's job); the stop-trio
-- (stop_ship_group_transit / command_main_ship_stop_transit) is untouched (needs PR #189 first).
--
-- ═══ SEVEN FINDINGS BEYOND THE NAMED PLAN — VERIFIED BY GREP, NOT ASSUMED ══════════════════════════════
-- The corrected plan named FIVE writers 4c-mig-2a already repointed (send_ship_group_hunt,
-- repair_main_ship, port_entry_commission_build, mainship_mark_combat_destroyed [skipped, already
-- clean], ensure_main_ship_for_player [skipped, already clean]). Re-deriving the TRUE HEAD of every
-- function that still touches the doomed columns (by grep, per the ci-apply-proof-is-the-net lesson
-- — "trust the code, not the plan") surfaces SEVEN more live touch points 2a's dual-safe stage
-- correctly left alone (columns still existed) but that WILL error the instant the columns are gone:
--
--   (F1) mainship_mark_combat_destroyed (TRUE head 20260618000167:160, never re-created — 2a's own
--        §4 note documents it has zero delta from its head) still writes
--        `spatial_state = null, space_x = null, space_y = null` — every combat-kill tick would error
--        "column does not exist" the instant the columns drop. Re-created here dropping the clears.
--   (F2) mainship_mark_docked_at_location (TRUE head 20260618000153:59, never re-created) still
--        writes `status = 'stationary', spatial_state = 'at_location', space_x = null, space_y =
--        null`. This is NOT dead code: it is called from movement_settle_arrival (TRUE head 0208:90,
--        the body process_fleet_movements — the live 30s cron, TRUE head 0206 — invokes on EVERY
--        arrival of a main-ship-owned per-ship fleet at a dockable port) AND from
--        nohome_dock_returning_ship (TRUE head 0199:662, called by process_mainship_expeditions —
--        TRUE head 0199:546, ALSO a live cron — for every returning/hunting ship once its manifest
--        fleet finishes). Under the live NO-HOME law (launch_from_dock_enabled = true in prod,
--        confirmed by 2a's own b4/b5 hunks targeting exactly that branch) THIS is the path every
--        returning hunt team's ships dock through — the single most-exercised of all the touch
--        points found in this migration. Left unfixed, EVERY hunt return would error, retried
--        forever, from the moment this migration deploys. Re-created here dropping the retired
--        write; 'stationary' becomes 'home' (the same swap 2a already made in b1/b4/b5 — 'stationary'
--        is retired below, so no writer may mint it any more).
--   (F3) get_my_fleet_positions (TRUE head 20260618000221:381) still SELECTs main_ship_instances.
--        spatial_state and emits it as a passthrough field — 0221's own header AND its own §8
--        self-assert (`the client-contract passthrough field left the map emit early (that retires
--        with 4c-client + 4c-mig-2)`) both flag this as 4c-mig-2's job. The client-side reader was
--        already removed (commit 026abf9, merged into this chain: `grep spatial_state
--        src/features/map/mainshipApi.ts` shows only comments — "No client code reads
--        main_ship_instances.spatial_state anymore; 4c-mig-2 drops it"). Left unfixed, the map's
--        primary read RPC — called on every page load, authenticated-executable — errors instantly.
--        Re-created here dropping the select-list column and the emit key (client contract intact:
--        it never read the field).
--   (F4) fleet_set_in_space(p_fleet uuid, p_x double precision, p_y double precision) (TRUE head
--        20260618000208:61, the ONLY definition — no later create-or-replace through 0222/0223)
--        still writes `active_movement_id = null, active_space_movement_id = null` on the fleets
--        table. §7 below drops fleets.active_space_movement_id — the NEXT call would error "column
--        does not exist". NOT dead: it is the leaf `command_ship_group_stop` (the player Stop/brake
--        RPC, src/features/command/teamApi.ts:256, granted to authenticated) calls when parking a
--        braked fleet in open space — gated on fleet_movement_unified_enabled, confirmed TRUE in prod
--        (0219's header) — AND the leaf movement_settle_arrival's target_type='space' branch
--        (0208:165) calls on every coordinate-target arrival. Left unfixed, the next player who
--        presses Stop on a fleet headed into open space breaks the brake for everyone, forever.
--        Re-created here dropping ONLY the active_space_movement_id=null clause — active_movement_id
--        (a DIFFERENT, KEPT fleets column, the legacy fleet_movements pointer) and every other clause
--        (space_x/space_y/status/location_mode/current_*) survive verbatim.
--   (F5) mainship_mark_legacy_in_flight(p_main_ship_id uuid, p_status text) (TRUE head 20260618000152:48,
--        the ONE shared "ship -> legacy in-flight" leaf) still writes `spatial_state = null, space_x =
--        null, space_y = null` alongside `status = p_status`. Its callers include three functions on
--        the 4b-drop DEAD list (send_main_ship_expedition, request_main_ship_return,
--        move_main_ship_to_location's 'present' branch) — but ALSO process_combat_ticks (TRUE head
--        0206:276), the LIVE 2-4s combat-tick cron: every retreat/escape that completes marks its
--        surviving members 'returning' through this SAME leaf, on ordinary, frequent gameplay. Left
--        unfixed, the next combat retreat after this migration deploys errors "column does not
--        exist". Re-created here dropping the clears; the domain check (traveling|returning only)
--        and status=p_status survive verbatim.
--   (F6) send_main_ship_expedition(jsonb, uuid, uuid) (TRUE head 20260618000199:82 — a DROP+CREATE
--        that widened the 0169 2-arg signature, so this 3-arg form is the ONLY current definition)
--        still decides its NOHOME "docked launch" branch via the retired
--        status='stationary'/spatial_state='at_location' pair — the SAME check 2a's b5 hunk already
--        repointed to fleet truth inside send_ship_group_hunt, but this sibling (single-ship send)
--        never received the same treatment since it has zero live client callers (2a's scope was the
--        5 named functions only). Exercised in depth by team-command-proof.sql's BLOCK NOHOME via the
--        similarly-dead send_ship_group_expedition wrapper the CI still calls directly — left
--        unfixed, every docked-launch assertion in that block breaks with no substitute path to
--        preserve the coverage. Repointed here to fleet truth (mainship_resolve_fleet + present/
--        location/presence, composed at all three sites: availability check, docked-launch guard,
--        re-claim-under-lock re-check) mirroring 2a's b5 predicate exactly — not a new formula.
--        SELF-CAUGHT BUG (via the CI apply-proof, fleetgo-proof.sql BLOCK ASSIGNGUARD-PERMEMBER):
--        the first draft repointed the re-claim-under-lock re-check to the SAME fleet-truth
--        predicate too — but that re-check runs AFTER this same branch's own writes (presence
--        completed, fleet status -> 'moving'), which ALWAYS invalidate that exact predicate for
--        THIS fleet. It failed on every docked-launch call, not just a genuine race. Removed —
--        the guarded fleet UPDATE's own "where ... and status = 'present'" (already raising above
--        if not found) is the real race-closure, mirroring how move_main_ship_to_location (0156)
--        needs no separate re-check either.
--   (F7) move_ship_group_to_location(uuid, uuid) (TRUE head 20260618000204:331, the ONE definition
--        since 0190; no later create-or-replace) decides its "every member docked together"
--        readiness check via the SAME retired status='stationary'/spatial_state='at_location' pair
--        — the THIRD sibling of this exact pattern (after send_ship_group_hunt/2a-b5 and F6's
--        send_main_ship_expedition), also with zero live client callers (moveShipGroup in
--        teamApi.ts has zero importers). Found via the CI apply-proof: team-command-proof.sql's
--        BLOCK TEAMMOVE calls it directly and repeatedly (empty/foreign/not-docked/mixed-location/
--        all-or-nothing/happy-path), so every call hit this line the instant the columns dropped.
--        Repointed to fleet truth identically to F6; the function's SECOND readiness check (every
--        member resolves to exactly one 'present' fleet, all at the same location) already used a
--        direct per-ship fleet join and is unchanged.
--
-- ═══ AN EIGHTH FINDING: THE DEAD RPC'S LIVE CRON ═════════════════════════════════════════════════════
-- process_mainship_space_arrivals (TRUE head 0064:95) is a DEAD function per the 4b-drop plan (the
-- OSN coordinate-domain arrival processor; both its gating flags are false in prod, verified in §0
-- below) — but it is SCHEDULED via pg_cron ('process-mainship-space-arrivals', every 30s, set up at
-- 0058 and never unscheduled since). A scheduled cron job is an ACTIVE trigger, unlike a dead RPC
-- nobody calls: it will fire on schedule and SELECT FROM main_ship_space_movements regardless of
-- whether any client ever calls the RPC family built on top of it. Left unscheduled, every tick from
-- the moment this migration deploys raises "relation does not exist" forever. §8 below unschedules
-- it (idempotent — the same unschedule-by-jobname idiom 0058/0061/0064 already use for re-scheduling
-- the SAME job). This does not drop the function (4b-drop's job); it only silences its cron trigger,
-- consistent with the DEAD list's own "[unschedule cron first]" note.
--
-- ═══ CONSTRAINT/INDEX/FK NAMES — VERIFIED AGAINST 0054/0055 SOURCE, NOT MEMORY ═══════════════════
--   main_ship_instances (0054): main_ship_instances_spatial_state_domain, main_ship_instances_space_coords
--   main_ship_instances (0055): main_ship_instances_status_check (re-narrowed, not dropped-and-gone),
--     main_ship_instances_ss_in_space_status, main_ship_instances_ss_at_location_status,
--     main_ship_instances_ss_in_transit_status, main_ship_instances_ss_home_status,
--     main_ship_instances_ss_destroyed_status, main_ship_instances_stationary_spatial_state
--   fleets (0055): fleets_active_space_movement_fk (FK), fleets_movement_pointers_exclusive (CHECK,
--     ALSO references the KEPT column active_movement_id — dropped here because it references the
--     column being dropped, NOT because active_movement_id itself is retiring),
--     fleets_active_space_movement_requires_moving (CHECK), fleets_one_per_active_space_movement
--     (partial unique index)
--   main_ship_space_command_receipts (0055): movement_id column (inline FK, auto-drops with the
--     column — no separate named constraint to drop)
--   main_ship_space_movements (0055): the table itself. VERIFIED (grep) the ONLY two inbound FKs are
--     fleets.active_space_movement_id and receipts.movement_id — both dropped in this same
--     transaction BEFORE the DROP TABLE, so no CASCADE is ever invoked (RESTRICT succeeds cleanly).
--
-- ═══ ORDER (constraints before columns; FKs before the table; data-fix before the CHECK narrow) ════
--   §0 pre-drop guards → §1 orphan reconciliation (DATA-FIX) → §2 DRAINGUARD →
--   §3 re-create the 7 live writers + 1 live reader that still touch the doomed columns →
--   §4 drop the 0054/0055 spatial CHECKs → §5 narrow the status CHECK →
--   §6 drop main_ship_instances.spatial_state/space_x/space_y →
--   §7 drop fleets' 2 CHECKs + index + FK + active_space_movement_id →
--   §8 unschedule the dead cron + drop receipts.movement_id → §9 DROP TABLE main_ship_space_movements →
--   §10 post-drop self-asserts.
--
-- TRANSACTION SCOPE: no explicit BEGIN/COMMIT here — matching every other migration in this tree
-- (grep confirms none of the other 222 files wraps itself), the Supabase migration runner already
-- applies each migration file as a single all-or-nothing transaction; any RAISE EXCEPTION in any of
-- the do-blocks below aborts the whole file, including every DDL statement already run in it.

-- ══════════════════════════════ §0. PRE-DROP GUARDS (RAISE = ABORT) ═══════════════════════════════
do $guard0$
declare
  v_src text;
begin
  -- (a) migration-chain order: the legacy schema must still be FULLY intact at apply time (2a/2b's
  --     own dual-safe contract) — this migration is the FIRST to touch it.
  if to_regclass('public.main_ship_space_movements') is null then
    raise exception '4C-MIG-2B GUARD FAIL: main_ship_space_movements is already gone — this must be the FIRST migration to drop it (apply order broken)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name in ('spatial_state', 'space_x', 'space_y')
                  having count(*) = 3) then
    raise exception '4C-MIG-2B GUARD FAIL: a main_ship_instances legacy column is already gone — apply order broken';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets' and column_name = 'active_space_movement_id') then
    raise exception '4C-MIG-2B GUARD FAIL: fleets.active_space_movement_id is already gone — apply order broken';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_space_command_receipts' and column_name = 'movement_id') then
    raise exception '4C-MIG-2B GUARD FAIL: receipts.movement_id is already gone — apply order broken';
  end if;
  if not exists (
      select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
       where t.relname = 'main_ship_instances' and c.contype = 'c'
         and pg_get_constraintdef(c.oid) like '%stationary%') then
    raise exception '4C-MIG-2B GUARD FAIL: the status CHECK no longer admits ''stationary'' — 2b already ran (apply order broken)';
  end if;

  -- (b) 4c-mig-2a's writer repoints are LIVE: prosrc-pin the pre-image of every function this
  --     migration is about to re-create, so a drift in what's actually deployed aborts LOUD rather
  --     than silently overwriting a body this migration's authors never actually reviewed.
  select prosrc into v_src from pg_proc where oid = 'public.mainship_mark_combat_destroyed(uuid)'::regprocedure;
  if v_src is null or position('status = ''destroyed'', hp = 0, spatial_state = null, space_x = null, space_y = null' in v_src) = 0 then
    raise exception '4C-MIG-2B GUARD FAIL: mainship_mark_combat_destroyed does not match its expected pre-drop (0167) shape';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.repair_main_ship(uuid)'::regprocedure;
  if v_src is null or position('status = ''home'', spatial_state = null,' in v_src) = 0 then
    raise exception '4C-MIG-2B GUARD FAIL: repair_main_ship does not match its expected pre-drop (0222/b4) shape — 2a may not have landed';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.send_ship_group_hunt(uuid, uuid, uuid)'::regprocedure;
  if v_src is null
     or (length(v_src) - length(replace(v_src,
          'set status = ''hunting'', spatial_state = null, space_x = null, space_y = null, updated_at = now()', ''))
        ) / length('set status = ''hunting'', spatial_state = null, space_x = null, space_y = null, updated_at = now()') <> 3 then
    raise exception '4C-MIG-2B GUARD FAIL: send_ship_group_hunt does not carry exactly 3 pre-drop (0222/b5) departure writes — 2a may not have landed';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.mainship_mark_docked_at_location(uuid)'::regprocedure;
  if v_src is null or position('status = ''stationary'', spatial_state = ''at_location''' in v_src) = 0 then
    raise exception '4C-MIG-2B GUARD FAIL: mainship_mark_docked_at_location does not match its expected pre-drop (0153) shape';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.get_my_fleet_positions()'::regprocedure;
  if v_src is null or position('''spatial_state'', s.spatial_state' in v_src) = 0 then
    raise exception '4C-MIG-2B GUARD FAIL: get_my_fleet_positions does not match its expected pre-drop (0221) shape';
  end if;
  -- F4: fleet_set_in_space (TRUE head 0208, never re-created) must still carry the doomed clause
  -- BEFORE this migration re-creates it — same pre-image discipline as F1/F2/F3 above.
  select prosrc into v_src from pg_proc where oid = 'public.fleet_set_in_space(uuid, double precision, double precision)'::regprocedure;
  if v_src is null or position('active_movement_id = null, active_space_movement_id = null' in v_src) = 0 then
    raise exception '4C-MIG-2B GUARD FAIL: fleet_set_in_space does not match its expected pre-drop (0208) shape';
  end if;
  -- F5: mainship_mark_legacy_in_flight (TRUE head 0152, never re-created) must still carry the
  -- doomed clause BEFORE this migration re-creates it — same pre-image discipline as F1-F4 above.
  select prosrc into v_src from pg_proc where oid = 'public.mainship_mark_legacy_in_flight(uuid, text)'::regprocedure;
  if v_src is null or position('status = p_status, spatial_state = null, space_x = null, space_y = null' in v_src) = 0 then
    raise exception '4C-MIG-2B GUARD FAIL: mainship_mark_legacy_in_flight does not match its expected pre-drop (0152) shape';
  end if;
  -- F6: send_main_ship_expedition (TRUE head 0199, the 3-arg NOHOME overload) must still carry the
  -- doomed docked-check pair BEFORE this migration repoints it — same pre-image discipline as F1-F5.
  select prosrc into v_src from pg_proc where oid = 'public.send_main_ship_expedition(jsonb, uuid, uuid)'::regprocedure;
  if v_src is null or position('v_ship.status = ''stationary'' and v_ship.spatial_state = ''at_location''' in v_src) = 0 then
    raise exception '4C-MIG-2B GUARD FAIL: send_main_ship_expedition does not match its expected pre-drop (0199) shape';
  end if;
  -- F7: move_ship_group_to_location (TRUE head 0204, never re-created) must still carry the doomed
  -- docked-check pair BEFORE this migration repoints it — same pre-image discipline as F1-F6.
  select prosrc into v_src from pg_proc where oid = 'public.move_ship_group_to_location(uuid, uuid)'::regprocedure;
  if v_src is null or position('status <> ''stationary'' or spatial_state is distinct from ''at_location''' in v_src) = 0 then
    raise exception '4C-MIG-2B GUARD FAIL: move_ship_group_to_location does not match its expected pre-drop (0204) shape';
  end if;
  -- port_entry_commission_build / ensure_main_ship_for_player: already clean since 2a (2a's own §8
  -- proved this) — pin they STAY clean (no doomed-column mint survives) so a regression is caught.
  -- STRIP `--` comments before these negative bans (the 2a apply-proof lesson): b1's OWN hunk
  -- comment in port_entry_commission_build names the retired columns it DELETED, so a naive prosrc
  -- probe trips on the comment, not the (clean) INSERT column list. Ban the real code only.
  select prosrc into v_src from pg_proc where oid = 'public.port_entry_commission_build(uuid, text)'::regprocedure;
  if v_src is null or position('spatial_state, space_x, space_y' in regexp_replace(v_src, '--[^\n]*', '', 'g')) > 0 then
    raise exception '4C-MIG-2B GUARD FAIL: port_entry_commission_build mints a retired column — 2a''s repoint regressed';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.ensure_main_ship_for_player(uuid)'::regprocedure;
  v_src := regexp_replace(coalesce(v_src, ''), '--[^\n]*', '', 'g');
  if v_src = '' or position('spatial_state' in v_src) > 0 or position('space_x' in v_src) > 0 or position('space_y' in v_src) > 0 then
    raise exception '4C-MIG-2B GUARD FAIL: ensure_main_ship_for_player mints a retired column — 2a''s no-hunk claim regressed';
  end if;

  -- (c) the coordinate-travel RPC stack sitting on top of main_ship_space_movements is DARK: both of
  --     its gating flags must be false, else dropping the table out from under a live-reachable
  --     dark-gated-first call would be unsafe (the gate only protects while it stays off).
  if public.cfg_bool('mainship_space_movement_enabled') then
    raise exception '4C-MIG-2B GUARD FAIL: mainship_space_movement_enabled is TRUE — the coordinate-travel stack is live, dropping main_ship_space_movements would break it';
  end if;
  if public.cfg_bool('mainship_coordinate_travel_enabled') then
    raise exception '4C-MIG-2B GUARD FAIL: mainship_coordinate_travel_enabled is TRUE — the coordinate-travel stack is live, dropping main_ship_space_movements would break it';
  end if;

  raise notice '4C-MIG-2B GUARD ok: chain order correct, 2a''s repoints intact, coordinate-travel stack confirmed dark';
end $guard0$;

-- ══════════════ §1. ORPHAN DATA RECONCILIATION (the DATA-FIX) — must run BEFORE the status ════════
-- ══════════════ CHECK is narrowed (no row may carry 'stationary' when the CHECK stops admitting it). ═
do $reconcile$
declare
  v_status_orphans integer;
  v_spatial_orphans integer;
  v_reconciled integer;
begin
  select count(*) into v_status_orphans from public.main_ship_instances
   where status in ('stationary', 'traveling');
  select count(*) into v_spatial_orphans from public.main_ship_instances
   where spatial_state is not null or space_x is not null or space_y is not null;

  -- expected magnitudes (pulled at plan time): 5 status-orphans (68 home/3 destroyed/3
  -- stationary/2 traveling → the 3 stationary + 2 traveling), 3 spatial-orphans (the 3 at_location
  -- ships, which are the same 3 stationary rows). Defensive, not brittle: ABORT only if reality is
  -- wildly off (> 15), a sign the prod census changed materially since this migration was written.
  if v_status_orphans > 15 or v_spatial_orphans > 15 then
    raise exception '4C-MIG-2B DATA-FIX ABORT: orphan counts wildly exceed expectations (status=%, spatial=%; expected ~5/~3) — re-verify the census before reapplying', v_status_orphans, v_spatial_orphans;
  end if;

  update public.main_ship_instances
     set status = case when status in ('stationary', 'traveling') then 'home' else status end,
         spatial_state = null,
         space_x = null,
         space_y = null
   where status in ('stationary', 'traveling')
      or spatial_state is not null
      or space_x is not null
      or space_y is not null;
  get diagnostics v_reconciled = row_count;

  if exists (select 1 from public.main_ship_instances where status in ('stationary', 'traveling')) then
    raise exception '4C-MIG-2B DATA-FIX ABORT: rows still carry status stationary/traveling after reconciliation';
  end if;
  if exists (select 1 from public.main_ship_instances
              where spatial_state is not null or space_x is not null or space_y is not null) then
    raise exception '4C-MIG-2B DATA-FIX ABORT: rows still carry non-null spatial_state/space_x/space_y after reconciliation';
  end if;

  raise notice '4C-MIG-2B DATA-FIX ok: % row(s) reconciled (pre-fix: % status-orphan(s), % spatial-orphan(s)); zero remain of either kind', v_reconciled, v_status_orphans, v_spatial_orphans;
end $reconcile$;

-- ══════════════════════════════ §2. DRAINGUARD ═════════════════════════════════════════════════════
do $drainguard$
declare
  v_n integer;
begin
  select count(*) into v_n from public.fleets where active_space_movement_id is not null;
  if v_n > 0 then
    raise exception '4C-MIG-2B DRAINGUARD ABORT: % fleet(s) still carry a live active_space_movement_id — a legacy coordinate movement is in flight, must NOT drop', v_n;
  end if;
  raise notice '4C-MIG-2B DRAINGUARD ok: zero fleets carry active_space_movement_id';
end $drainguard$;

-- ══════════════════ §3. RE-CREATE THE LAST LIVE TOUCH POINTS (findings F1/F2/F3/F4/F5/F6/F7) ══════════════
-- No FUNCTION is dropped; each is CREATE OR REPLACE, byte-identical to its pre-drop TRUE head except
-- the doomed-column reference is removed (F1/F2/F4/F5/F6/F7: deleted from the write; F3: deleted from the read).

-- F1 — mainship_mark_combat_destroyed (TRUE head 0167:160). The spatial clears retire WITH the
-- columns: they existed only to satisfy the 0055 ss_* CHECK coupling, which is dropped in §4 below,
-- in the SAME transaction — never a moment where the clears are needed but the columns are gone.
create or replace function public.mainship_mark_combat_destroyed(p_main_ship_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.main_ship_instances
    set status = 'destroyed', hp = 0, updated_at = now()
    where main_ship_id = p_main_ship_id;
end;
$$;
revoke execute on function public.mainship_mark_combat_destroyed(uuid) from public, anon, authenticated;
grant  execute on function public.mainship_mark_combat_destroyed(uuid) to service_role;

-- F1b — repair_main_ship (TRUE head 0222/b4). Same retirement: the docked-revival branch's
-- spatial_state/space_x/space_y=null co-change was CHECK-required only while the columns existed.
-- status stays 'home' (unchanged from 2a); the 0081 dark branch never touched these columns.
create or replace function public.repair_main_ship(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   main_ship_instances%rowtype;
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
begin
  if v_player is null then
    raise exception 'repair_main_ship: not authenticated';
  end if;

  select * into v_ship from main_ship_instances
    where main_ship_id = public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship.main_ship_id is null then
    raise exception 'repair_main_ship: no main ship found';
  end if;
  if v_ship.status <> 'destroyed' then
    raise exception 'repair_main_ship: ship is not disabled (status %) — nothing to repair', v_ship.status;
  end if;
  if v_ship.max_hp is null or v_ship.max_hp <= 0 then
    raise exception 'repair_main_ship: invalid max_hp (%)', v_ship.max_hp;
  end if;

  if v_launch_from_dock then
    -- 4C-MIG-2B HUNK: the spatial_state/space_x/space_y=null co-change retires WITH the columns
    -- (it existed only to satisfy the 0055 CHECK coupling, dropped in §4 below in this same
    -- transaction). status='home' is unchanged from 2a's b4 hunk.
    update main_ship_instances
      set hp = v_ship.max_hp, status = 'home', updated_at = now()
      where main_ship_id = v_ship.main_ship_id;
    return jsonb_build_object(
      'main_ship_id', v_ship.main_ship_id, 'status', 'home',
      'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
  end if;

  -- 0081 HEAD (DARK path — byte-identical): restore to full readiness, back home.
  update main_ship_instances
    set hp = v_ship.max_hp, status = 'home', updated_at = now()
    where main_ship_id = v_ship.main_ship_id;

  return jsonb_build_object(
    'main_ship_id', v_ship.main_ship_id, 'status', 'home',
    'hp', v_ship.max_hp, 'max_hp', v_ship.max_hp);
end;
$$;
revoke execute on function public.repair_main_ship(uuid) from public, anon;
grant execute on function public.repair_main_ship(uuid) to authenticated;

-- F1c — send_ship_group_hunt (TRUE head 0222/b5). Same retirement, at all THREE departure-write
-- sites (Hunk C's mint, the NOHOME launch-branch mint, the 0168 dark head's mint): the
-- spatial_state/space_x/space_y=null clears were CHECK-required only while the columns existed.
-- status='hunting' is unchanged from 2a (the sortie/combat layer's own signal — it retires with the
-- status-CHECK narrow, which is §5 below, NOT this hunk). Every other line is byte-identical to the
-- 0222 TRUE head — the ONLY delta anywhere in this body is the 3 deleted clear-clauses.
create or replace function public.send_ship_group_hunt(p_group_id uuid, p_location uuid, p_return_location_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
      if exists (select 1 from public.group_sortie_members where fleet_id = v_gf.id) then
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
$$;
revoke execute on function public.send_ship_group_hunt(uuid, uuid, uuid) from public, anon;
grant  execute on function public.send_ship_group_hunt(uuid, uuid, uuid) to authenticated;

-- F2 — mainship_mark_docked_at_location (TRUE head 0153:59). THE HIGHEST-RISK re-create in this
-- migration: called live, every tick, via movement_settle_arrival (0208, driven by process_fleet_
-- movements — the 30s cron) for a per-ship main-ship fleet arriving at a dockable port, AND via
-- nohome_dock_returning_ship (0199, driven by process_mainship_expeditions — ALSO a live cron) for
-- every returning/hunting ship once its manifest fleet finishes — i.e. every hunt team's return.
-- 'stationary' is retired below (§5); the replacement literal is 'home', the SAME swap 2a already
-- made for every other writer that used to mint 'stationary' (b1/b4/b5). Dockedness itself is no
-- longer decided by this column at all (0221 R1-f reads fleet+presence truth) — this write becomes
-- a pure status-lifecycle settle, matching the b1/b4 pattern exactly.
create or replace function public.mainship_mark_docked_at_location(p_main_ship_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.main_ship_instances
    set status = 'home', updated_at = now()
    where main_ship_id = p_main_ship_id;
end;
$$;
revoke execute on function public.mainship_mark_docked_at_location(uuid) from public, anon, authenticated;
grant  execute on function public.mainship_mark_docked_at_location(uuid) to service_role;

-- F3 — get_my_fleet_positions (TRUE head 0221). The spatial_state passthrough field retires WITH the
-- column, exactly as 0221's own header/self-assert anticipated. The client reader was already
-- removed (commit 026abf9, ancestor of this chain — src/features/map/mainshipApi.ts no longer reads
-- it). Every other line is byte-identical to the 0221 TRUE head — the ONLY delta is the deleted
-- select-list column and the deleted emit key.
create or replace function public.get_my_fleet_positions()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_out    jsonb := '[]'::jsonb;
  s        record;
  v_ctx    jsonb;
  v_ok     boolean;
  v_state  text;
  v_place  text;
  v_loc    uuid;
  v_seg    jsonb;
  v_lm     record;
  -- FLEET-GO 3c-3 additions: the resolved in_space coordinate (fleet-first, ship fallback).
  v_sx     double precision;
  v_sy     double precision;
  -- S1-BERTH (0216) addition: the gate, read ONCE (not per ship row).
  v_unified boolean := public.cfg_bool('fleet_movement_unified_enabled');
begin
  if v_player is null then
    return v_out;
  end if;

  -- Every owned, non-destroyed ship (owner-read scope). `order by created_at` is stable enumeration only —
  -- the marker placement per ship is decided below, never by row order.
  -- 4C-MIG-2B HUNK: spatial_state leaves the select-list — the last live reader of it (the emit
  -- below) is deleted in the same hunk; nothing else in this body ever read s.spatial_state.
  for s in
    select main_ship_id, name, hull_type_id, status,
           berth_location_id   -- S1-BERTH (0216): read with the row (part of the ONE hunk)
      from public.main_ship_instances
     where player_id = v_player
       and status <> 'destroyed'
     order by created_at asc
  loop
    v_place := 'hidden';
    v_loc   := null;
    v_seg   := null;
    -- FLEET-GO 3c-3: reset WITH the others. plpgsql variables persist across loop iterations, so a
    -- coordinate surviving into a later row is a ship drawn where a DIFFERENT fleet parked.
    v_sx    := null;
    v_sy    := null;

    -- Canonical coherence oracle — the SAME authority the single-ship dock/store reads trust. It fully
    -- validates fleet + presence + movement coherence and returns the ship's honest state (or ok=false).
    v_ctx   := public.mainship_space_validate_context(s.main_ship_id);
    v_ok    := coalesce((v_ctx->>'ok')::boolean, false);
    v_state := v_ctx->>'state';

    if v_ok then
      if v_state = 'in_space' then
        -- FLEET-GO 3c-3 (hunk 2 of 3): FLEET-FIRST. The unified world parks the FLEET
        -- (fleet_set_in_space, 0208) and never writes a ship coordinate, so a parked/braked group was
        -- INVISIBLE here — the old arm read only the ship's own columns. The fleet's coordinate now
        -- answers first (0210:188-189: the position is read from the FLEET, never the ship).
        select f.space_x, f.space_y
          into v_sx, v_sy
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.location_mode = 'space'
         limit 1;
        if v_sx is not null and v_sy is not null then
          v_place := 'in_space';
        end if;

      elsif v_state in ('at_location', 'legacy_present') then
        -- FLEET-GO 3c-2 (the ONE hunk): rekeyed from `f.main_ship_id = <ship>` (NULL on a unified
        -- fleet — the whole group vanished on arrival) to the ONE ship→fleet resolver, KEEPING this
        -- site's own status='present' read: 'legacy_present' reaches here too, and the at_location-only
        -- dock helper would return NULL for every legacy-shaped prod ship (a live map regression).
        -- Dark → both oracle guards pin exactly ONE active per-ship fleet, the resolver's fallback
        -- returns it, and f.id = <that one row> makes the old `order by created_at desc` dead weight.
        select f.current_location_id
          into v_loc
          from public.fleets f
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.status = 'present'
         limit 1;
        if v_loc is not null then
          v_place := 'docked';
        end if;

      elsif v_state = 'legacy_transit' then
        -- Legacy (spatial-era NULL) transit — the committed fleet_movements segment.
        select fm.origin_x, fm.origin_y, fm.target_x, fm.target_y, fm.target_type, fm.depart_at, fm.arrive_at
          into v_lm
          from public.fleet_movements fm
          join public.fleets f on f.id = fm.fleet_id
         where f.id = public.mainship_resolve_fleet(s.main_ship_id) and fm.status = 'moving'
         order by fm.depart_at desc
         limit 1;
        if found then
          v_place := 'transit';
          v_seg   := jsonb_build_object(
            'origin_x', v_lm.origin_x, 'origin_y', v_lm.origin_y,
            'target_x', v_lm.target_x, 'target_y', v_lm.target_y,
            'target_kind', v_lm.target_type,
            'depart_at', v_lm.depart_at, 'arrive_at', v_lm.arrive_at);
        end if;

      -- 'home' / 'legacy_home' → hidden: a ship idle at home is NOT drawn on the port map (mirrors the
      -- single-ship resolver §E/§F). Any other ok state falls through to hidden too (fail closed).
      end if;
    end if;

    -- S1-BERTH (0216) — THE ONE HUNK: the BERTHED branch. A ship no arm above placed, that the ONE
    -- resolver has no fleet for, and that carries a berth → place='berthed' at the berth port.
    -- Post-flip this is prod's majority ungrouped shape once the corpses die (4c/4d); until then a
    -- coherent corpse still answers 'docked' above (resolver non-NULL) and this branch stays quiet.
    -- A FLEETED ship with a broken fleet invariant has berth NULL → stays hidden (fail closed).
    -- Gated: dark = 0212 byte-identically.
    if v_unified and v_place = 'hidden' and s.berth_location_id is not null
       and public.mainship_resolve_fleet(s.main_ship_id) is null then
      v_place := 'berthed';
      v_loc   := s.berth_location_id;
    end if;

    -- Append as a single-element ARRAY (array || array is unambiguous concatenation).
    -- 4C-MIG-2B HUNK: 'spatial_state' key is DELETED from the emit — it retires with the column
    -- (0221's header/self-assert both flagged this; the client reader is already gone, see the
    -- file-header F3 note).
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'main_ship_id', s.main_ship_id,
      'name',         s.name,
      'class',        s.hull_type_id,
      'status',       s.status,
      'place',        v_place,
      'location_id',  v_loc,
      'space_x',      case when v_place = 'in_space' then v_sx else null end,
      'space_y',      case when v_place = 'in_space' then v_sy else null end,
      'segment',      v_seg
    ));
  end loop;

  return v_out;
end;
$$;
revoke all on function public.get_my_fleet_positions() from public;
grant execute on function public.get_my_fleet_positions() to authenticated;

-- F4 — fleet_set_in_space (TRUE head 0208:61, the ONLY definition — no later create-or-replace
-- exists through 0222/0223). LIVE, not dead: called by command_ship_group_stop (the player Stop/
-- brake RPC, src/features/command/teamApi.ts:256, granted to authenticated, gated on
-- fleet_movement_unified_enabled — TRUE in prod per 0219's header) via 0209/0215/0218, AND by
-- movement_settle_arrival's target_type='space' branch (0208:165) on every coordinate-target
-- arrival. §7 below drops fleets.active_space_movement_id; this write retires WITH that column.
-- 4C-MIG-2B HUNK: active_space_movement_id=null retires WITH the fleets column — deleted from the
-- SET. active_movement_id=null is UNCHANGED (a DIFFERENT, KEPT fleets column — the legacy
-- fleet_movements pointer this migration never touches), and every other clause
-- (status/location_mode/space_x/space_y/current_*) survives byte-identical to the 0208 head.
create or replace function public.fleet_set_in_space(p_fleet uuid, p_x double precision, p_y double precision)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_x is null or p_y is null then
    raise exception 'fleet_set_in_space: coordinates required (fleet %)', p_fleet;
  end if;
  -- Mirrors fleet_set_present: clears the movement pointer + every "somewhere else" pointer, and
  -- writes the one place the fleet now IS. status 'idle' (not 'present'): 'present' means docked at a
  -- location and carries a location_presence row; open space has no presence to create.
  update fleets
     set status = 'idle', location_mode = 'space',
         space_x = p_x, space_y = p_y,
         active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where id = p_fleet;
  if not found then
    raise exception 'fleet_set_in_space: fleet % not found', p_fleet;
  end if;
end;
$function$;
revoke all on function public.fleet_set_in_space(uuid, double precision, double precision) from public;

-- F5 — mainship_mark_legacy_in_flight (TRUE head 0152:48, the ONE shared "ship -> legacy in-flight"
-- leaf every legacy departure/return/retreat write goes through — grep-verified callers:
-- send_main_ship_expedition (0152/0169), request_main_ship_return (0152), move_main_ship_to_location
-- (0156, 'present'-departure branch), AND — the reason this is a required fix, not a dead-branch
-- exemption — process_combat_ticks (TRUE head 0206:276, the LIVE 2-4s combat cron): every retreat/
-- escape that completes marks its surviving member ships 'returning' through this SAME leaf. This
-- fires on ordinary, frequent gameplay (any retreat), not a corner case. Still writes
-- `spatial_state = null, space_x = null, space_y = null` — §6 below drops those columns, so the very
-- next retreat-completion tick after this migration deploys would error "column does not exist" and
-- (depending on the cron's per-row isolation) at minimum permanently wedge that ship's return.
-- 4C-MIG-2B HUNK: the spatial_state/space_x/space_y=null clears retire WITH the columns (they only
-- ever cleared an already-null value for any status this leaf's own domain check allows — traveling/
-- returning — so dropping them changes no observable behavior). status = p_status is unchanged; the
-- domain check (traveling|returning only) and the exception message survive verbatim.
create or replace function public.mainship_mark_legacy_in_flight(p_main_ship_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status not in ('traveling', 'returning') then
    raise exception 'mainship_mark_legacy_in_flight: illegal legacy in-flight status % (traveling|returning only)', p_status;
  end if;
  update public.main_ship_instances
    set status = p_status, updated_at = now()
    where main_ship_id = p_main_ship_id;
end;
$$;
revoke execute on function public.mainship_mark_legacy_in_flight(uuid, text) from public, anon, authenticated;
grant  execute on function public.mainship_mark_legacy_in_flight(uuid, text) to service_role;

-- F6 — send_main_ship_expedition(jsonb, uuid, uuid) (TRUE head 0199:82 — the 3-arg NOHOME widening
-- DROP+CREATEd the 2-arg 0169 signature out of existence, so this is the ONLY current definition).
-- Its NOHOME "docked launch" branch (dark unless launch_from_dock_enabled — confirmed TRUE in prod)
-- still decides "is this ship docked" via `v_ship.status = 'stationary' and v_ship.spatial_state =
-- 'at_location'` — the SAME retired ship-column pair 2a's b5 hunk already repointed to FLEET TRUTH
-- inside send_ship_group_hunt (0221 R1-f). This sibling function implements the identical NO-HOME
-- feature for single-ship sends and was never given the same repoint (out of 2a's 5-named scope,
-- since the RPC has zero live client callers). It is exercised in depth, however, by
-- team-command-proof.sql's BLOCK NOHOME (the CI's coverage of the NO-HOME law) via the
-- also-dead-but-CI-exercised send_ship_group_expedition wrapper — left unfixed, every docked-launch
-- assertion in that block breaks the instant the columns drop, and there is no substitute path that
-- exercises this SAME function's docked branch. Repointed here rather than gutting that coverage,
-- mirroring 2a's b5 fleet-truth predicate exactly (mainship_resolve_fleet + present/location/
-- presence) — NOT a new formula.
-- 4C-MIG-2B HUNK: v_docked (fleet truth, computed once) replaces the retired
-- status='stationary'/spatial_state='at_location' pair at all three sites (the availability check,
-- the docked-launch branch guard, and the re-claim-under-lock re-check). Every other line — the
-- 0169 dark-path tail, the docked-launch mechanics, the raise messages — survives byte-identical
-- to the 0199 head.
create or replace function public.send_main_ship_expedition(p_ships jsonb, p_location uuid, p_return_location_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship_id  uuid;
  v_ship     record;
  v_base     record;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_speed    double precision;
  v_fleet    uuid;
  v_movement uuid;
  v_arrive   timestamptz;
  v_launch_from_dock boolean := public.cfg_bool('launch_from_dock_enabled');
  v_present  record;
  v_cur      record;
  v_return   uuid;
  v_docked   boolean;
begin
  if v_player is null then
    raise exception 'send_main_ship_expedition: not authenticated';
  end if;

  if not cfg_bool('mainship_send_enabled') then
    raise exception 'send_main_ship_expedition: feature disabled';
  end if;

  if p_ships is null or jsonb_typeof(p_ships) <> 'array' or jsonb_array_length(p_ships) <> 1 then
    raise exception 'send_main_ship_expedition: exactly one ship required';
  end if;
  v_ship_id := (p_ships->>0)::uuid;
  if v_ship_id is null then
    raise exception 'send_main_ship_expedition: invalid ship id';
  end if;

  select * into v_ship from main_ship_instances
    where main_ship_id = v_ship_id and player_id = v_player;
  if v_ship.main_ship_id is null then
    raise exception 'send_main_ship_expedition: ship not found or not owned';
  end if;
  v_docked := exists (
    select 1 from public.fleets f
     where f.id = public.mainship_resolve_fleet(v_ship_id)
       and f.status = 'present' and f.location_mode = 'location'
       and f.current_location_id is not null and f.active_movement_id is null
       and exists (
         select 1 from public.location_presence lp
          where lp.fleet_id = f.id and lp.status = 'active'
            and lp.location_id = f.current_location_id)
  );
  -- 4C-MIG-2B GATE FIX (found via the CI apply-proof, team-command-proof.sql BLOCK NOHOME's DARK
  -- witness): the ORIGINAL 0199 gate keyed on `v_ship.status <> 'home'` because a DOCKED ship was
  -- status='stationary' — a value distinct from 'home' by construction, so the dark (non-docked)
  -- gate rejected it for free. Post-repoint, F2's mainship_mark_docked_at_location writes
  -- status='home' for a DOCKED ship too (status is now a pure lifecycle signal — 0221), so
  -- `status <> 'home'` can no longer tell a docked ship from a truly-home one AT ALL, dark or lit.
  -- Check v_docked FIRST, independent of status: a fleet-truth-docked ship requires the LIT flag
  -- regardless of its (now-shared) 'home' label; a non-docked ship keeps the exact original
  -- status='home' requirement. This is the same fleet-truth-first restructuring as v_docked's own
  -- introduction — not a new rule, just correctly ordered against the label collision F2 created.
  if v_docked then
    if not v_launch_from_dock then
      raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
    end if;
  elsif v_ship.status <> 'home' then
    raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
  end if;

  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' then
    raise exception 'send_main_ship_expedition: location not found or inactive';
  end if;
  if v_loc.activity_type <> 'none' then
    raise exception 'send_main_ship_expedition: only non-combat locations supported in Phase 10C (got %)', v_loc.activity_type;
  end if;

  if v_launch_from_dock and v_docked then
    select f.id, f.main_ship_id into v_present
      from fleets f
      where f.id = public.mainship_resolve_fleet(v_ship_id) and f.player_id = v_player and f.status = 'present';
    if v_present.id is null then
      raise exception 'send_main_ship_expedition: docked ship has no present fleet';
    end if;
    select lp.id as presence_id, lp.location_id, lp.zone_id, l.x, l.y
      into v_cur
      from location_presence lp join locations l on l.id = lp.location_id
      where lp.fleet_id = v_present.id and lp.status = 'active';
    if v_cur.location_id is null then
      raise exception 'send_main_ship_expedition: docked ship has no active presence';
    end if;
    if p_location = v_cur.location_id then
      raise exception 'send_main_ship_expedition: main ship is already at that location';
    end if;
    v_return := coalesce(p_return_location_id, v_cur.location_id);

    v_speed := resolve_fleet_movement_speed(v_present.id);
    v_movement := movement_create(
      v_player, v_present.id,
      'location', null, v_cur.zone_id, v_cur.location_id, v_cur.x, v_cur.y,
      'location', null, null, v_loc.id, v_loc.x, v_loc.y,
      'rally', v_speed);
    perform presence_complete(v_cur.presence_id);
    update fleets
      set status = 'moving', location_mode = 'movement', active_movement_id = v_movement,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          return_location_id = v_return, updated_at = now()
      where id = v_present.id and active_movement_id is null and status = 'present';
    if not found then
      raise exception 'send_main_ship_expedition: docked ship % no longer present', v_ship_id;
    end if;
    -- 4C-MIG-2B BUG FIX (found via the CI apply-proof, fleetgo-proof.sql BLOCK
    -- ASSIGNGUARD-PERMEMBER): the ORIGINAL 0199 head re-verified the ship's OWN status/
    -- spatial_state columns here (the 0169 M1 race-closure idiom) — columns the writes ABOVE never
    -- touch, so re-checking them after the fact was sound. Repointing that re-check to the SAME
    -- fleet-truth predicate as v_docked is WRONG: the guarded fleet UPDATE just above (status->
    -- 'moving', presence completed) ALWAYS invalidates that exact predicate for THIS fleet, so a
    -- fleet-truth re-check here would fail on every single call, never just a genuine race. The
    -- guarded UPDATE's own "where ... and active_movement_id is null and status = 'present'" (with
    -- its "if not found then raise" above) IS the race-closure now — a concurrent modification to
    -- this fleet already fails there, exactly mirroring how move_main_ship_to_location (0156) closes
    -- the identical race with no separate re-check of its own. Removed; proceed directly to the
    -- in-flight mark.
    perform public.mainship_mark_legacy_in_flight(v_ship_id, 'traveling');

    select arrive_at into v_arrive from fleet_movements where id = v_movement;
    return jsonb_build_object(
      'fleet_id', v_present.id, 'movement_id', v_movement,
      'main_ship_id', v_ship_id, 'arrive_at', v_arrive, 'return_location_id', v_return);
  end if;

  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    raise exception 'send_main_ship_expedition: active fleet limit reached (%/%)', v_active, v_max;
  end if;

  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    raise exception 'send_main_ship_expedition: no active home base';
  end if;

  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_ship_id)
    returning id into v_fleet;

  v_speed := resolve_fleet_movement_speed(v_fleet);

  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'rally', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  perform 1 from main_ship_instances
    where main_ship_id = v_ship_id and status = 'home'
    for update;
  if not found then
    select * into v_ship from main_ship_instances where main_ship_id = v_ship_id;
    raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
  end if;
  perform public.mainship_mark_legacy_in_flight(v_ship_id, 'traveling');

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'fleet_id', v_fleet, 'movement_id', v_movement,
    'main_ship_id', v_ship_id, 'arrive_at', v_arrive);
end;
$$;
revoke execute on function public.send_main_ship_expedition(jsonb, uuid, uuid) from public, anon;
grant  execute on function public.send_main_ship_expedition(jsonb, uuid, uuid) to authenticated;

-- F7 — move_ship_group_to_location(uuid, uuid) (TRUE head 0204:331, the ONE definition since 0190;
-- no later create-or-replace). Its readiness check decides "is every member docked together" via
-- the SAME retired status='stationary'/spatial_state='at_location' pair 2a's b5 hunk already
-- repointed to fleet truth inside send_ship_group_hunt, and F6 just repointed inside
-- send_main_ship_expedition — but this THIRD sibling (the team-move wrapper) was never touched, out
-- of 2a's 5-named scope (zero live client callers: `moveShipGroup` in teamApi.ts has zero
-- importers, same as `sendShipGroup`). Found via CI: team-command-proof.sql's BLOCK TEAMMOVE calls
-- it directly and repeatedly (the empty/foreign/not-docked/mixed-location/all-or-nothing/happy-path
-- sub-tests), so every single call hit this line the instant the columns dropped. Repointed to fleet
-- truth (mainship_resolve_fleet + present/location/presence), mirroring 2a's b5 / F6's predicate
-- exactly — not a new formula. The SECOND readiness check just below it (every member resolves to
-- exactly one 'present' fleet, all at the SAME location) already used a direct per-ship fleet join,
-- unaffected by this hunk, and is unchanged.
create or replace function public.move_ship_group_to_location(p_group_id uuid, p_location_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player     uuid := auth.uid();
  v_group      uuid;
  v_members    uuid[];
  v_fleets     uuid[];
  v_fleet      uuid;
  v_locked     integer;
  v_not_docked integer;
  v_loc_count  integer;
  v_null_locs  integer;
  v_res        jsonb;
  v_sent       jsonb := '[]'::jsonb;
  v_fleet_control boolean := public.cfg_bool('fleet_control_enabled');
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

  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
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

  if v_fleet_control then
    if not exists (
      select 1 from public.main_ship_instances
       where group_id = v_group and player_id = v_player and is_command_ship
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fleet_inactive_no_command');
    end if;
  end if;

  select count(*) into v_locked from (
    select main_ship_id from public.main_ship_instances
     where main_ship_id = any(v_members) and player_id = v_player
     for update
  ) locked;
  if v_locked <> array_length(v_members, 1) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  -- ── ★ 4C-MIG-2B HUNK: "docked" is FLEET TRUTH (mirrors 0221 R1-f / 2a's b5 / F6), not the      ★ ──
  -- ── ★ retired ship-column status='stationary'/spatial_state='at_location' pair.                ★ ──
  select count(*) into v_not_docked
    from public.main_ship_instances s
    where s.main_ship_id = any(v_members)
      and not exists (
        select 1 from public.fleets f
         where f.id = public.mainship_resolve_fleet(s.main_ship_id)
           and f.status = 'present' and f.location_mode = 'location'
           and f.current_location_id is not null and f.active_movement_id is null
           and exists (
             select 1 from public.location_presence lp
              where lp.fleet_id = f.id and lp.status = 'active'
                and lp.location_id = f.current_location_id)
      );
  if v_not_docked > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  select coalesce(array_agg(f.id order by msi.created_at), '{}'),
         count(distinct f.current_location_id),
         count(*) filter (where f.current_location_id is null)
    into v_fleets, v_loc_count, v_null_locs
    from public.main_ship_instances msi
    join public.fleets f
      on f.main_ship_id = msi.main_ship_id and f.player_id = v_player and f.status = 'present'
   where msi.main_ship_id = any(v_members);
  if coalesce(array_length(v_fleets, 1), 0) <> array_length(v_members, 1)
     or v_loc_count <> 1 or v_null_locs > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_ready');
  end if;

  begin
    foreach v_fleet in array v_fleets loop
      select public.move_main_ship_to_location(v_fleet, p_location_id) into v_res;
      v_sent := v_sent || jsonb_build_array(v_res);
    end loop;
  exception
    when others then
      return jsonb_build_object('ok', false, 'reason', 'member_send_failed', 'detail', sqlerrm);
  end;

  update public.fleets
     set group_id = v_group
   where player_id = v_player
     and id in (select (e->>'fleet_id')::uuid from jsonb_array_elements(v_sent) e);

  return jsonb_build_object('ok', true, 'group_id', v_group, 'sent', v_sent);
end;
$$;
revoke execute on function public.move_ship_group_to_location(uuid, uuid) from public, anon;
grant  execute on function public.move_ship_group_to_location(uuid, uuid) to authenticated;

-- ══════════════ §4. DROP THE 0054/0055 SPATIAL CHECK CONSTRAINTS (before the columns) ══════════════
alter table public.main_ship_instances drop constraint if exists main_ship_instances_ss_in_space_status;
alter table public.main_ship_instances drop constraint if exists main_ship_instances_ss_at_location_status;
alter table public.main_ship_instances drop constraint if exists main_ship_instances_ss_in_transit_status;
alter table public.main_ship_instances drop constraint if exists main_ship_instances_ss_home_status;
alter table public.main_ship_instances drop constraint if exists main_ship_instances_ss_destroyed_status;
alter table public.main_ship_instances drop constraint if exists main_ship_instances_stationary_spatial_state;
alter table public.main_ship_instances drop constraint if exists main_ship_instances_spatial_state_domain;
alter table public.main_ship_instances drop constraint if exists main_ship_instances_space_coords;

-- ══════════════════════════ §5. NARROW THE STATUS CHECK (retire 'stationary') ═══════════════════════
-- Verified against the 0055 source (the ONLY re-creation since 0043): the current membership is
-- exactly ('home','traveling','hunting','trading','exploring','mining','retreating','returning',
-- 'repairing','destroyed','stationary'). Correction #1: do NOT narrow to {home,destroyed} — 'hunting'
-- is written directly by send_ship_group_hunt on every departure. Remove ONLY 'stationary'.
alter table public.main_ship_instances drop constraint if exists main_ship_instances_status_check;
alter table public.main_ship_instances
  add constraint main_ship_instances_status_check
  check (status in ('home','traveling','hunting','trading','exploring','mining',
                    'retreating','returning','repairing','destroyed'));

-- ══════════════ §6. DROP main_ship_instances.spatial_state / space_x / space_y ═══════════════════════
alter table public.main_ship_instances
  drop column if exists spatial_state,
  drop column if exists space_x,
  drop column if exists space_y;

-- ══════════════ §7. DROP fleets' 2 CHECKs + partial unique index + FK + the column ══════════════════
-- fleets_movement_pointers_exclusive ALSO mentions active_movement_id (the KEPT legacy fleet-movement
-- pointer) — it is dropped here because it REFERENCES the column being dropped, not because
-- active_movement_id itself retires (it stays; fleet_movements/process_fleet_movements are KEPT).
alter table public.fleets drop constraint if exists fleets_movement_pointers_exclusive;
alter table public.fleets drop constraint if exists fleets_active_space_movement_requires_moving;
drop index if exists fleets_one_per_active_space_movement;
alter table public.fleets drop constraint if exists fleets_active_space_movement_fk;
alter table public.fleets drop column if exists active_space_movement_id;

-- ═══════════════ §8. UNSCHEDULE THE DEAD CRON + DROP receipts.movement_id ═══════════════════════════
-- process_mainship_space_arrivals (TRUE head 0064) is dead per the 4b-drop plan (both its gating
-- flags are confirmed false in §0(c) above) but is SCHEDULED via pg_cron and reads FROM
-- main_ship_space_movements on every tick — unschedule its trigger BEFORE the table is gone, else
-- every tick errors "relation does not exist" forever starting the moment this migration deploys.
-- Idempotent (the same by-jobname idiom 0058/0061/0064 already use to re-schedule this SAME job).
do $unschedule$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'process-mainship-space-arrivals';
exception
  when undefined_table then null;  -- cron schema not present (should not happen this late; defensive)
end;
$unschedule$;

-- receipts.movement_id carries the inbound FK to main_ship_space_movements (0055, inline, auto-named
-- — no separate constraint name to drop). Dropping the column drops the FK with it. The table KEEPS
-- existing (correction #5: mining_extract has no natural idempotency; dropping receipts would
-- double-mint rewards on replay).
alter table public.main_ship_space_command_receipts drop column if exists movement_id;

-- ══════════════════════ §9. DROP TABLE main_ship_space_movements ════════════════════════════════════
-- Both inbound FKs (fleets.active_space_movement_id, receipts.movement_id) are gone as of §7/§8 above
-- — verified (grep) to be the ONLY two inbound FKs in the whole schema, so this plain DROP TABLE
-- (no CASCADE) succeeds cleanly with no surprise object removed. Its own indexes / RLS policy /
-- grants are dropped automatically with the table.
drop table if exists public.main_ship_space_movements;

-- ══════════════════════════════ §10. POST-DROP SELF-ASSERTS ══════════════════════════════════════════
do $postdrop$
declare
  v_src text;
  v_def text;
begin
  -- the table is gone.
  if to_regclass('public.main_ship_space_movements') is not null then
    raise exception '4C-MIG-2B POST-DROP FAIL: main_ship_space_movements still exists';
  end if;

  -- the 3 main_ship_instances columns are gone.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'main_ship_instances'
                and column_name in ('spatial_state', 'space_x', 'space_y')) then
    raise exception '4C-MIG-2B POST-DROP FAIL: a doomed main_ship_instances column still exists';
  end if;

  -- fleets.active_space_movement_id + its 2 CHECKs + its index + its FK are gone.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'fleets' and column_name = 'active_space_movement_id') then
    raise exception '4C-MIG-2B POST-DROP FAIL: fleets.active_space_movement_id still exists';
  end if;
  if exists (select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
              where t.relname = 'fleets' and c.conname in
                ('fleets_movement_pointers_exclusive', 'fleets_active_space_movement_requires_moving',
                 'fleets_active_space_movement_fk')) then
    raise exception '4C-MIG-2B POST-DROP FAIL: a fleets active_space_movement CHECK/FK still exists';
  end if;
  if to_regclass('public.fleets_one_per_active_space_movement') is not null then
    raise exception '4C-MIG-2B POST-DROP FAIL: fleets_one_per_active_space_movement index still exists';
  end if;

  -- receipts table STILL EXISTS (correction #5) but movement_id is gone.
  if to_regclass('public.main_ship_space_command_receipts') is null then
    raise exception '4C-MIG-2B POST-DROP FAIL: main_ship_space_command_receipts was dropped — it must be KEPT (mining_extract has no natural idempotency)';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'main_ship_space_command_receipts' and column_name = 'movement_id') then
    raise exception '4C-MIG-2B POST-DROP FAIL: receipts.movement_id still exists';
  end if;

  -- the 0054 CHECKs are gone.
  if exists (select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
              where t.relname = 'main_ship_instances' and c.contype = 'c'
                and c.conname in ('main_ship_instances_spatial_state_domain', 'main_ship_instances_space_coords',
                                  'main_ship_instances_ss_in_space_status', 'main_ship_instances_ss_at_location_status',
                                  'main_ship_instances_ss_in_transit_status', 'main_ship_instances_ss_home_status',
                                  'main_ship_instances_ss_destroyed_status', 'main_ship_instances_stationary_spatial_state')) then
    raise exception '4C-MIG-2B POST-DROP FAIL: a 0054/0055 spatial CHECK still exists on main_ship_instances';
  end if;

  -- the status CHECK no longer admits 'stationary' — probe pg_get_constraintdef directly (the
  -- authoritative deployed definition, not this file's text).
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c join pg_class t on t.oid = c.conrelid
   where t.relname = 'main_ship_instances' and c.conname = 'main_ship_instances_status_check';
  if v_def is null then
    raise exception '4C-MIG-2B POST-DROP FAIL: main_ship_instances_status_check is missing entirely';
  end if;
  if v_def like '%stationary%' then
    raise exception '4C-MIG-2B POST-DROP FAIL: the status CHECK still admits ''stationary''';
  end if;
  if v_def not like '%hunting%' or v_def not like '%home%' or v_def not like '%destroyed%' then
    raise exception '4C-MIG-2B POST-DROP FAIL: the narrowed status CHECK lost a value it must keep (home/hunting/destroyed)';
  end if;
  -- REAL is_valid probe (not vacuous — the ci-apply-proof-is-the-net lesson: a zero-row UPDATE never
  -- evaluates a CHECK at all, so it would prove nothing). If any real ship row exists, attempt to
  -- write 'stationary' to it: the live CHECK MUST reject it (check_violation). PL/pgSQL's own
  -- BEGIN/EXCEPTION block already takes an implicit savepoint and rolls back to it on the caught
  -- exception — no explicit SAVEPOINT/ROLLBACK TO is valid (or needed) inside a plpgsql body. If the
  -- write is NOT rejected (the narrow failed to land), the RAISE EXCEPTION immediately below aborts
  -- this migration's whole outer transaction, which undoes the stray write along with everything
  -- else — so no separate cleanup path is needed for that case either.
  if exists (select 1 from public.main_ship_instances limit 1) then
    declare
      v_probe_id uuid;
      v_rejected boolean := false;
    begin
      select main_ship_id into v_probe_id from public.main_ship_instances limit 1;
      begin
        update public.main_ship_instances set status = 'stationary' where main_ship_id = v_probe_id;
        -- if we get here, the write was NOT rejected — the narrow failed to land.
      exception when check_violation then
        v_rejected := true;  -- expected outcome; PL/pgSQL already rolled back this statement
      end;
      if not v_rejected then
        raise exception '4C-MIG-2B POST-DROP FAIL: writing status=''stationary'' to a real ship row was NOT rejected by the live CHECK — the narrow did not land';
      end if;
    end;
  else
    raise notice '4C-MIG-2B POST-DROP: no main_ship_instances row exists to probe with a real write — relying on the pg_get_constraintdef proof above only';
  end if;

  -- zero rows anywhere carry a status outside the narrowed set (defensive re-proof beyond the
  -- constraint itself — belt AND braces).
  if exists (select 1 from public.main_ship_instances
              where status not in ('home','traveling','hunting','trading','exploring','mining',
                                    'retreating','returning','repairing','destroyed')) then
    raise exception '4C-MIG-2B POST-DROP FAIL: a live row carries a status outside the narrowed CHECK set';
  end if;

  -- the 9 re-created functions no longer reference the doomed columns (post-drop prosrc re-pin —
  -- belt-and-braces beyond "it compiled": these are TEXT bodies, so a stray reference would only
  -- surface as a runtime error on next call, never at CREATE time).
  -- Every probe below strips `--` comments FIRST (the 2a apply-proof lesson): each re-created body
  -- carries a "4C-MIG-2B HUNK: the spatial_state/... clears retire WITH the columns" comment naming
  -- the removed columns, so a naive prosrc ban would trip on the function's OWN explanation. Ban the
  -- real CODE only.
  select prosrc into v_src from pg_proc where oid = 'public.mainship_mark_combat_destroyed(uuid)'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state' in v_src) > 0 or position('space_x' in v_src) > 0 or position('space_y' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: mainship_mark_combat_destroyed still references a doomed column';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.repair_main_ship(uuid)'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state' in v_src) > 0 or position('space_x' in v_src) > 0 or position('space_y' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: repair_main_ship still references a doomed column';
  end if;
  -- NOTE: send_ship_group_hunt legitimately reads/writes fleets.space_x/space_y (v_gf.space_x,
  -- v_o_x := v_gf.space_x, the consumed-fleet clear `space_x = null, space_y = null` on the FLEETS
  -- table — all the FLEET's own KEPT coordinate columns, not main_ship_instances'), so a blanket
  -- space_x/space_y ban would false-positive here. 'spatial_state' has no such collision (only
  -- main_ship_instances ever had that column, and every doomed write coupled it in the SAME clause
  -- as the space_x/space_y=null it sat beside) — it alone is the precise, collision-free probe.
  select prosrc into v_src from pg_proc where oid = 'public.send_ship_group_hunt(uuid, uuid, uuid)'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: send_ship_group_hunt still references spatial_state';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.mainship_mark_docked_at_location(uuid)'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state' in v_src) > 0 or position('space_x' in v_src) > 0 or position('space_y' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: mainship_mark_docked_at_location still references a doomed column';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.get_my_fleet_positions()'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: get_my_fleet_positions still references spatial_state';
  end if;
  if not has_function_privilege('authenticated', 'public.get_my_fleet_positions()', 'execute') then
    raise exception '4C-MIG-2B POST-DROP FAIL: get_my_fleet_positions lost its authenticated grant';
  end if;
  -- F4: fleet_set_in_space legitimately KEEPS space_x/space_y (the fleet's own coords, written every
  -- call — `space_x = p_x, space_y = p_y`), so the collision-free probe is `active_space_movement_id`
  -- specifically, not a bare space_x/space_y ban. Strip comments first (the hunk comment above names
  -- the retired clause).
  select prosrc into v_src from pg_proc where oid = 'public.fleet_set_in_space(uuid, double precision, double precision)'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('active_space_movement_id' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: fleet_set_in_space still references active_space_movement_id';
  end if;
  if position('active_movement_id = null' in v_src) = 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: fleet_set_in_space lost its active_movement_id=null clear (a DIFFERENT, KEPT fleets column) — byte-parity broken beyond the marked hunk';
  end if;
  -- F5: mainship_mark_legacy_in_flight no longer references the doomed columns; its domain check
  -- and status=p_status write survive.
  select prosrc into v_src from pg_proc where oid = 'public.mainship_mark_legacy_in_flight(uuid, text)'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state' in v_src) > 0 or position('space_x' in v_src) > 0 or position('space_y' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: mainship_mark_legacy_in_flight still references a doomed column';
  end if;
  if position('status = p_status, updated_at = now()' in v_src) = 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: mainship_mark_legacy_in_flight lost its status=p_status write';
  end if;
  if position('p_status not in (''traveling'', ''returning'')' in v_src) = 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: mainship_mark_legacy_in_flight lost its traveling|returning domain check';
  end if;
  -- F6: send_main_ship_expedition no longer references the doomed columns; the fleet-truth v_docked
  -- compose landed at the availability check, the docked-launch guard, and the re-claim re-check.
  select prosrc into v_src from pg_proc where oid = 'public.send_main_ship_expedition(jsonb, uuid, uuid)'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state' in v_src) > 0 or position('space_x' in v_src) > 0 or position('space_y' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: send_main_ship_expedition still references a doomed column';
  end if;
  -- TWO sites (the availability check's v_docked compose, and the docked-launch branch's own
  -- fleet resolve) — the THIRD (a re-check-under-lock, after the fleet UPDATE already invalidates
  -- the same predicate) was a genuine bug, found via the CI apply-proof, and removed; see the hunk
  -- comment in §3.
  if (length(v_src) - length(replace(v_src, 'public.mainship_resolve_fleet(v_ship_id)', ''))) / length('public.mainship_resolve_fleet(v_ship_id)') < 2 then
    raise exception '4C-MIG-2B POST-DROP FAIL: send_main_ship_expedition does not compose mainship_resolve_fleet at both fleet-truth sites';
  end if;
  -- the REMOVED bug's exact bare-lock text (no status filter — unlike the dark path's legitimate
  -- `main_ship_id = v_ship_id and status = 'home' for update`, which must NOT trip this ban).
  if position('main_ship_id = v_ship_id for update' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: send_main_ship_expedition still carries the broken post-write fleet-truth re-check-under-lock';
  end if;
  -- GATE FIX: v_docked is checked FIRST, independent of status (a docked ship requires the lit flag
  -- regardless of its shared 'home' label) — the buggy `if v_ship.status <> 'home' then if not
  -- (v_launch_from_dock and v_docked)` (which skips the WHOLE check whenever status='home', letting
  -- every docked ship through even while dark) must be gone.
  if position('if v_docked then' in v_src) = 0 or position('if not v_launch_from_dock then' in v_src) = 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: send_main_ship_expedition lost the v_docked-first gate restructure — a docked ship would bypass the dark gate again';
  end if;
  -- NOTE: position('if v_ship.status <> ''home'' then' in v_src) is NOT a safe probe here — it
  -- false-positives on the NEW code's own `elsif v_ship.status <> 'home' then` (elsIF contains the
  -- substring "if v_ship.status <> 'home' then" starting mid-keyword: "els" + "if ..."). This bit
  -- 2a's comment-strip lesson in spirit but the actual mechanism here is a keyword substring
  -- collision in LIVE code, not a comment — stripping `--` comments does not touch it. Ban the
  -- precise OLD buggy inner condition instead, which cannot collide with "elsif" or the new code.
  if position('if not (v_launch_from_dock and v_docked) then' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: send_main_ship_expedition still nests the docked check under the buggy status<>home guard';
  end if;
  if not has_function_privilege('authenticated', 'public.send_main_ship_expedition(jsonb, uuid, uuid)', 'execute') then
    raise exception '4C-MIG-2B POST-DROP FAIL: send_main_ship_expedition lost its authenticated grant';
  end if;
  -- F7: move_ship_group_to_location no longer references the doomed columns; the fleet-truth
  -- readiness compose landed.
  select prosrc into v_src from pg_proc where oid = 'public.move_ship_group_to_location(uuid, uuid)'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('spatial_state' in v_src) > 0 or position('space_x' in v_src) > 0 or position('space_y' in v_src) > 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: move_ship_group_to_location still references a doomed column';
  end if;
  if position('public.mainship_resolve_fleet(s.main_ship_id)' in v_src) = 0 then
    raise exception '4C-MIG-2B POST-DROP FAIL: move_ship_group_to_location does not compose mainship_resolve_fleet for its readiness check';
  end if;
  if not has_function_privilege('authenticated', 'public.move_ship_group_to_location(uuid, uuid)', 'execute') then
    raise exception '4C-MIG-2B POST-DROP FAIL: move_ship_group_to_location lost its authenticated grant';
  end if;

  -- the dead cron is gone.
  if exists (select 1 from cron.job where jobname = 'process-mainship-space-arrivals') then
    raise exception '4C-MIG-2B POST-DROP FAIL: the process-mainship-space-arrivals cron job is still scheduled — it reads a now-dropped table';
  end if;

  raise notice '4C-MIG-2B POST-DROP ok: table gone, 3 ship columns gone, fleets pointer+2 CHECKs+index+FK gone, receipts kept (movement_id gone), status CHECK narrowed (stationary rejected, home/hunting/destroyed kept), all 9 re-created functions clean, dead cron unscheduled';
end $postdrop$;
