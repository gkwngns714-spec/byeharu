-- 0292 — RETREAT TO A CHOSEN DESTINATION: a move order given mid-combat becomes a RETREAT.
--
-- ── WHAT CHANGES (exactly two hunks, in two functions) ──────────────────────────────────────────────
--   (1) command_ship_group_go — re-emitted BYTE-IDENTICAL to its TRUE head
--       (20260618000233_pirate_intercept_danger_zones.sql:589-995) EXCEPT step 8 (head :751-762).
--       The head counted the group's live sortie and refused unconditionally with 'group_on_sortie'.
--       It now performs an authoritative encounter lookup and classifies FOUR ways:
--         (a) encounter 'active'      -> validate the target, store the destination, compose
--                                        presence_request_leave -> ok, reason 'retreat_started'.
--         (b) encounter 'retreating'  -> validate the target, REPLACE the stored destination only —
--                                        no second call to presence_request_leave, no restarted
--                                        timer -> ok, reason 'retreat_destination_updated'.
--         (c) the sortie is TERMINAL/SETTLING (the encounter has ended but its fleet is still
--                                        present/returning) -> typed 'movement_settled_retry'.
--         (d) a sortie with NO encounter at all (legacy / non-combat sortie state) -> the head's
--                                        'group_on_sortie' refusal, unchanged.
--       No sortie -> falls through to the mover below, byte-identical to the head. Everything else in
--       the mover — the dark gate, the target-shape rule, the S4 dock-translate hunk, member_busy, the
--       whole origin chain, the dissolve, the pirate-intercept hunk, the return envelope, the grants —
--       is the 0233 head, verbatim. The head's DECLARE block is untouched: the hunk's locals live in a
--       nested DECLARE inside step 8.
--
--   (2) process_combat_ticks — re-emitted BYTE-IDENTICAL to its TRUE head
--       (20260618000261_encounter_variety_zero_elite.sql:268-1067) EXCEPT the completion branch
--       (head :471-500), where ONLY THE DESTINATION CHOICE changes. The head hardcoded it (`select
--       origin_base_id into v_base_id from fleets` -> a 'base'-target leg). It now resolves:
--         destination := fleets.retreat_target_location_id when set AND STILL VALID (an active
--                        location), else origin_base_id — so a destination that went invalid during
--                        the window falls back home instead of leaving the encounter stuck retreating;
--       and CONSUMES the recording (clears retreat_target_location_id) so it can never leak into a
--       later sortie. Every other line of the branch — the v_end shape, the three reads, the speed fold,
--       encounter update, report_create, presence_complete, the normal timed movement_create, the
--       existing fleet_set_returning, the D3 member marking, movement_attach_cargo, both log inserts,
--       the counter — is the head, verbatim, and so is the rest of the function.
--
--   (0) ONE additive nullable column, fleets.retreat_target_location_id — the recording the two hunks
--       above hand between them. Why it is a NEW column rather than the obvious existing one is the
--       next section, and it is the single most important decision in this file.
--
-- NO other function is re-created. NO existing column, constraint or row is altered. NO new
-- game_config row and NO flag flipped — the retreat path is ungated today and stays ungated (the mover
-- still reads exactly the head's two cfg_bool gates; the tick still reads exactly the head's nine).
-- The new column is NULL on every existing row, so the tick's new arm is unreachable until a player
-- actually orders a move mid-combat: for every encounter that exists today the completion branch
-- behaves exactly as 0261 shipped it.
--
-- ── ONE RETREAT AUTHORITY (the no-spaghetti constraint) ─────────────────────────────────────────────
-- presence_request_leave's hunt arm is COMPOSED, never re-implemented. The mover writes no presence
-- 'retreating' status, no request timestamp, no retreat-start timestamp, never calls the retreat-arming
-- leaf directly, and never reads the retreat window config. The disarm (v_offense := (e.status =
-- 'active')), the enemy-damage rule that keeps hitting a retreating fleet, the reward lock (rewards
-- accrue only under v_offense) and the 8-second window all stay exactly where they already live, in
-- the tick, byte-identical. This slice decides ONLY where the fleet goes when the window expires.
-- The self-assert below re-proves each of those.
--
-- ── ONE TRANSACTION, SO THERE IS NO VISIBILITY RACE ────────────────────────────────────────────────
-- Storing the destination and arming the retreat happen in the SAME transaction — the mover is one
-- RPC, and both writes sit inside it, after a FOR UPDATE lock on the encounter row. The tick worker
-- (which takes that same row FOR UPDATE for the whole tick) therefore can never observe half the
-- change: it sees either no retreat at all, or a retreat WITH its destination already recorded.
-- Lock order here is combat_encounters -> fleets -> location_presence, which is the tick's own order,
-- so the two can never deadlock. If the tick settles the encounter first, the locked re-read no longer
-- matches and the order takes the typed 'movement_settled_retry' / refusal arms — never a guess.
--
-- ── THE DESTINATION COLUMN: fleets.retreat_target_location_id (ONE additive nullable FK) ───────────
-- The obvious candidate was fleets.return_location_id ("the port this fleet goes back to", 0199:66-76)
-- and this slice was drafted against it. IT DOES NOT FIT, and the reason is load-bearing:
-- return_location_id ALREADY HAS A WRITER for exactly the fleets this feature acts on. The unified
-- hunt records the launch port on every sortie that leaves from a port —
--   `v_return := coalesce(p_return_location_id, v_gf.current_location_id);`  (0214:358, and the
--   docked-members arm at 0214:495; the lit NO-HOME send does the same, 0199:174/399)
-- and the hunt fleet is minted carrying it (0214:408). If the tick treated that value as "the player
-- ordered this destination", then EVERY port-launched team hunt that escaped — with nobody having
-- ordered anything — would stop flying home and divert to its launch port. Two things break: the
-- cargo it is carrying is only ever DEPOSITED by a BASE arrival (movement_settle_arrival's base
-- branch is the sole reward_grant site), so its loot would be silently destroyed; and consuming
-- (clearing) the value would strip the port the SHIP-side reconciler reads to dock the returning
-- members (nohome_dock_returning_ship, 0199:676-685), degrading NO-HOME to its re-home fallback.
-- A column that already means something else cannot also mean "the player ordered this" — that is the
-- exact overloading this slice forbids. So the recording gets its OWN column, written by nothing but
-- the mid-combat order and read by nothing but the completion branch:
--   fleets.retreat_target_location_id uuid null references locations(id) on delete set null
-- Consequences, all good: NULL on every existing row, so the tick's new arm is UNREACHABLE until a
-- player actually orders a mid-combat move (the completion branch is behaviourally identical to 0261
-- for every encounter that exists today); ON DELETE SET NULL makes a deleted destination degrade to
-- the origin_base_id fallback by schema, not by code; and return_location_id keeps its meaning, its
-- writers and its ship-side lifecycle completely untouched.
-- Rejected alternatives: fleets.space_x/space_y is the fleet's OWN position, not a destination;
-- fleet_route_legs is a QUEUE with a documented sole-writer law (0233:282-286) and a cron consumer
-- that would race the tick, and it would tie the retreat to pirate_intercept_enabled; combat_encounters
-- has no free column.
-- LOCATION TARGETS ONLY: the column is a location FK, so a combat-time redirect is accepted ONLY for a
-- location target. A coordinate / open-space order during combat returns a TYPED rejection —
-- {ok:false, reason:'retreat_needs_port_destination'} — it is never silently discarded and never
-- quietly turned into a return home as if the player had not asked. The column is NEVER overloaded
-- with serialized coordinates.
-- FUTURE EXTENSION POINT (not built here): coordinate retreat targets want an additive, exactly-one-of
-- shape on the SAME family — retreat_target_location_id XOR (retreat_target_x AND retreat_target_y) —
-- enforced by a CHECK constraint, with the completion branch choosing the target shape from whichever
-- side is populated. That is its own slice: it needs the columns, the constraint, and its own proof.
--
-- ── WHY THE RETREAT LEG TARGETS THE PORT'S COORDINATE ('space'), NOT THE PORT ('location') ──────────
-- The arrival must leave the fleet in a state where the sortie is OVER. movement_settle_arrival's
-- 'location' branch (0208:112-141) calls fleet_set_present, which leaves the fleet 'present' — and
-- EVERY sortie-manifest predicate is live-scoped on `fleets.status in ('moving','present','returning')`
-- (0169's retention rule: manifests are never deleted, they are scoped by fleet status). A fleet
-- parked 'present' with a live manifest would pin its member ships in 'returning' forever
-- (process_mainship_expeditions frees them only when no live manifest fleet remains) and would answer
-- 'group_on_sortie' to every later order: a permanent wedge. The 'space' branch (0208:163-166) calls
-- fleet_set_in_space -> status 'idle', which is exactly as dead as the base branch's fleet_complete as
-- far as the manifest is concerned, so the EXISTING reconciler frees the members with no new writer,
-- no manifest delete, and no change to the settle. The fleet therefore ends parked in ORBIT at the
-- chosen port — the same place the mover's own S4 timed-docking translate (:723-731) parks a port move
-- — idle and immediately commandable (go again, or the separate dock verb). A retreat is an escape
-- vector, not a docking maneuver.
-- CONSEQUENCE, deliberate: loot earned BEFORE the order rides the leg as cargo (movement_attach_cargo
-- is re-emitted verbatim) but is only ever DEPOSITED by a BASE arrival, so naming a destination
-- forfeits the deposit until the fleet later returns to a base. The plain retreat (request_retreat,
-- untouched) records no destination, still flies to origin_base_id, and still banks it. The mover's ok
-- envelope returns 'carried_rewards' so the choice can be made with that in view.
--
-- ── A SECOND, DIFFERENT MOVE ORDER MID-RETREAT (required semantics, implemented deterministically) ──
-- IT RETARGETS; IT NEVER RESTARTS. Arm (b) rewrites fleets.retreat_target_location_id (last write wins) and
-- touches nothing else: presence_request_leave is called ONLY from arm (a), i.e. only while the
-- encounter is still 'active' and its presence is still 'active'. An already-retreating group
-- therefore never re-enters the retreat verb, the retreat start timestamp is never re-stamped, and a
-- player cannot reset (or shorten) the damage window by re-issuing move orders: the window always runs
-- from the FIRST order. Whichever destination is recorded when it expires is where the fleet goes —
-- the tick reads the column once, at completion, and clears it. Concurrent re-orders are serialized by
-- the mover's existing ship_groups FOR UPDATE (step 4) plus the encounter row lock above. The envelope
-- names which arm ran: reason 'retreat_started' vs 'retreat_destination_updated'.
-- The same path covers the reverse: a player who pressed the ordinary retreat button first can then
-- name a destination and the in-flight retreat is re-targeted without disturbing the clock.
--
-- Server-authoritative throughout: the client sends only (group, port); every classification, the
-- destination legality (step 6's active + NON-COMBAT rule, unchanged and still ahead of this hunk),
-- the retreat arming and the destination choice are decided here.
--
-- Forward-only: 0233 and 0261 are not edited.


-- ══ 0. fleets.retreat_target_location_id — the ordered retreat destination (additive, nullable) ════
-- Sole writer: command_ship_group_go's step-8 retreat arms. Sole reader: process_combat_ticks'
-- completion branch, which consumes and clears it. Deliberately NOT fleets.return_location_id (see the
-- header): that column already carries the LAUNCH port of every port-launched sortie, and conflating
-- the two would divert ordinary hunt returns and destroy their cargo.
-- ON DELETE SET NULL: a deleted destination simply un-records the order and the retreat falls back to
-- origin_base_id — the fallback is enforced by the schema, not only by the branch.
alter table public.fleets
  add column if not exists retreat_target_location_id uuid references public.locations (id) on delete set null;

comment on column public.fleets.retreat_target_location_id is
  'RETREAT TO A CHOSEN DESTINATION (0292): the port a player named by issuing a move order while this '
  'fleet was IN COMBAT. Written only by command_ship_group_go step 8 (which also arms the retreat via '
  'presence_request_leave, in the same transaction); read, re-validated and CLEARED by '
  'process_combat_ticks when the retreat window expires — the fleet then flies to that port''s '
  'coordinate instead of origin_base_id. NULL means "no order was given": the retreat goes home, '
  'exactly as it always has. Distinct from return_location_id, which is NO-HOME''s launch/return port '
  'and is not touched by the retreat path. If coordinate destinations are ever added, the shape is '
  'exactly-one-of: retreat_target_location_id XOR (retreat_target_x AND retreat_target_y).';


-- ══ 1. command_ship_group_go — the 0233 TRUE HEAD verbatim, ONE new hunk at step 8 ═════════════════
create or replace function public.command_ship_group_go(
  p_group_id    uuid,
  p_location_id uuid default null,
  p_target_x    double precision default null,
  p_target_y    double precision default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
  -- PIRATE-INTERCEPT: the leaf's dark-gated jsonb envelope ({hit:false,...} while dark — no writes).
  v_intercept  jsonb;
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
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');

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
      -- LOCATION TARGETS ONLY. The destination is recorded in fleets.retreat_target_location_id — the
      -- column this slice adds, whose ONLY writer is this arm and whose only reader is the tick's
      -- completion branch — and it is a location FK (deliberately NOT the NO-HOME return port, which
      -- already carries the launch port for every port-launched sortie; see the file header).
      -- A coordinate / open-space order therefore cannot be recorded: it is REFUSED TYPED, never
      -- silently dropped and never quietly turned into a return home as if the player had not asked.
      -- (The additive XOR shape that would admit coordinates is named in the file header.)
      if p_location_id is null then
        return jsonb_build_object('ok', false, 'reason', 'retreat_needs_port_destination');
      end if;
      -- CLASSIFY BEFORE WRITING: presence_request_leave demands an ACTIVE presence, so an encounter
      -- that reads 'active' against a presence that no longer does is a settling race — answer it
      -- typed, with NO write left behind, rather than let the verb raise (this RPC returns envelopes,
      -- never raises, at its boundary).
      if v_enc.status = 'active'
         and not exists (select 1 from public.location_presence lp
                          where lp.id = v_enc.presence_id and lp.status = 'active') then
        return jsonb_build_object('ok', false, 'reason', 'movement_settled_retry');
      end if;
      -- Store (or REPLACE) the destination. Last write wins; the tick reads it once, at completion.
      update public.fleets
         set retreat_target_location_id = p_location_id, updated_at = v_now
       where id = v_enc.fleet_id and player_id = v_player;

      if v_enc.status = 'active' then
        -- (a) FIRST order: arm the retreat through presence_request_leave — the sole retreat
        --     authority (0018:60-69). It is the only thing that may move a presence into retreat, set
        --     its timestamps and start the window; this hunk reproduces none of that.
        perform public.presence_request_leave(v_enc.presence_id);
        return jsonb_build_object(
          'ok', true,
          'outcome', 'retreat_started',
          'reason', 'retreat_started',
          'group_id', v_group,
          'fleet_id', v_enc.fleet_id,
          'encounter_id', v_enc.id,
          'presence_id', v_enc.presence_id,
          'member_count', v_member_n,
          'destination_location_id', p_location_id,
          -- Loot earned BEFORE the order rides the leg as cargo but is only ever DEPOSITED by a BASE
          -- arrival (the settle's base branch, untouched here), so naming a destination forfeits the
          -- deposit until the fleet later returns to a base. Surfaced, never hidden.
          'carried_rewards', coalesce(v_enc.total_rewards_json, '{}'::jsonb));
      end if;

      -- (b) ALREADY RETREATING: the destination above is the ONLY thing that changed. The retreat
      --     verb is deliberately not called a second time — re-entering it would re-stamp the retreat
      --     clock and hand the player a free reset of the damage window. The window keeps running
      --     from the FIRST order.
      return jsonb_build_object(
        'ok', true,
        'outcome', 'retreat_destination_updated',
        'reason', 'retreat_destination_updated',
        'group_id', v_group,
        'fleet_id', v_enc.fleet_id,
        'encounter_id', v_enc.id,
        'presence_id', v_enc.presence_id,
        'member_count', v_member_n,
        'destination_location_id', p_location_id,
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

  -- ── ★ THE PIRATE-INTERCEPT HUNK (pirate_intercept_enabled) — the ONLY delta this migration adds  ★
  -- ── ★ to the mover. The leaf's OWN first statement is the flag gate, so this call is a TRUE     ★
  -- ── ★ no-op while dark: zero reads, zero writes, `v_intercept = {hit:false,reason:'dark'}`. On  ★
  -- ── ★ a hit the leg this RPC just minted is cancelled and the fleet is routed into the existing ★
  -- ── ★ combat path (see pirate_intercept_evaluate_leg) — all within this SAME transaction.       ★
  v_intercept := public.pirate_intercept_evaluate_leg(v_movement);
  -- ── ★ END OF THE PIRATE-INTERCEPT HUNK ★ ─────────────────────────────────────────────────────

  select arrive_at into v_arrive from public.fleet_movements where id = v_movement;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'fleet_id', v_fleet,
    'movement_id', v_movement,
    'arrive_at', v_arrive,
    'member_count', v_member_n,
    'redirected', v_redirected,
    'origin_type', v_o_type,
    'target_type', v_t_type,
    'target_x', v_t_x,
    'target_y', v_t_y,
    'intercepted', coalesce((v_intercept->>'hit')::boolean, false),
    'intercept_encounter_id', v_intercept->>'encounter_id');
end;
$function$;

comment on function public.command_ship_group_go(uuid, uuid, double precision, double precision) is
  'FLEET-GO (charter §2): the ONE fleet-level mover. Moves a ship_group as a single atomic fleet to a '
  'port OR a world coordinate, from wherever it is (port, open space, anchor, or mid-flight); re-issue '
  'to redirect. Writes NO per-ship movement state — that omission is the point. DARK behind '
  'fleet_movement_unified_enabled. S4 TIMED DOCKING (0219): under timed_docking_enabled a DOCKABLE '
  'port target is translated to its coordinate. PIRATE INTERCEPT (0233): under pirate_intercept_enabled '
  'the newly-minted leg is rolled against every crossed danger zone. RETREAT TO A CHOSEN DESTINATION '
  '(0292): a move ordered while the group is IN COMBAT is no longer refused — step 8 classifies four '
  'ways. Encounter active -> the ordered PORT is stored in fleets.retreat_target_location_id and the '
  'fleet '
  'retreats toward it via the existing presence_request_leave verb (ok/retreat_started); encounter '
  'already retreating -> the stored destination is REPLACED only, the verb is not re-entered and the '
  'window is not restarted (ok/retreat_destination_updated); the encounter already terminal while its '
  'fleet settles -> movement_settled_retry; a sortie with no encounter -> group_on_sortie, unchanged. '
  'A COORDINATE order during combat is refused typed (retreat_needs_port_destination) because the '
  'recording column is a location FK — never silently dropped, never quietly sent home.';

revoke all on function public.command_ship_group_go(uuid, uuid, double precision, double precision) from public;
grant execute on function public.command_ship_group_go(uuid, uuid, double precision, double precision) to authenticated;


-- ══ 2. process_combat_ticks — the 0261 TRUE HEAD verbatim, ONE new hunk in the completion branch ═══
-- Copied character-for-character from 20260618000261_encounter_variety_zero_elite.sql:268-1067. The
-- ONLY delta is inside branch (B), the retreat/forced-extract completion: the DESTINATION CHOICE.
-- Every other arm — (A) destroyed, (C) spatial and aggregate combat steps, the E3 resolver wiring, the
-- wave lifecycle, the reward formulas, the 8-second window, the reward lock, the logging, the
-- per-encounter exception contract — is the head, verbatim.
create or replace function public.process_combat_ticks()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  e               combat_encounters%rowtype;
  pr              location_presence%rowtype;
  loc             record;
  cu              record;
  v_tick          integer;
  v_tick_secs     double precision;
  v_retreat_delay double precision;
  v_trans_secs    double precision;
  v_var_pct       double precision;
  v_def_base      double precision;
  v_secs_inside   double precision;
  v_max_secs      double precision;
  v_forced        boolean;
  v_retreat_done  boolean;
  v_danger        integer;
  v_variance      double precision;
  v_attack        double precision;
  v_defense       double precision;
  v_hp_total      double precision;
  v_alive_total   integer;
  v_wave_num      integer;
  v_enemy_hp      double precision;
  v_e_before      double precision;
  v_e_after       double precision;
  v_enemy_attack  double precision;
  v_player_damage double precision;
  v_final_player  double precision;
  v_cleared       boolean;
  v_offense       boolean;
  v_d_group       double precision;
  v_new_hp        double precision;
  v_new_alive     integer;
  v_destroyed     integer;
  v_losses        jsonb;
  v_counts        jsonb;
  v_snapshot      jsonb;
  v_hp_after      double precision;
  v_reward_metal  double precision;
  v_reward_delta  jsonb;
  v_loot_items    jsonb;
  v_seq           integer;
  v_end           text;
  v_base_id       uuid;
  v_base_x        double precision;
  v_base_y        double precision;
  v_loc_x         double precision;
  v_loc_y         double precision;
  v_speed         double precision;
  v_mv            uuid;
  v_count         integer := 0;
  v_log_ticks     boolean;
  v_log_events    boolean;
  v_log_debug     boolean;
  v_shield_regen  double precision;
  v_shield        double precision;
  v_absorb        double precision;
  v_per_ship_targeting boolean;
  v_target_unit        uuid;
  -- ██ COMBAT-S3 (0234) — the spatial working set ██
  v_spatial_combat_enabled boolean;  -- read ONCE per invocation, alongside every other one-read knob
  v_is_spatial             boolean;  -- read ONCE per encounter per tick (the null-pos fallback decision)
  v_wave_paused            boolean;
  v_units                  jsonb;    -- frozen pre-move snapshot: id/side/pos/my_range/move_speed/aggro/main_ship_id
  v_ur                     record;   -- the acting unit, looped from v_units
  v_target_id              uuid;
  v_target_x               double precision;
  v_target_y               double precision;
  v_target_range           double precision;
  v_target_dist            double precision;
  v_move_action            text;
  v_new_x                  double precision;
  v_new_y                  double precision;
  v_weapons_json           jsonb;
  v_weapons_out            jsonb;
  v_widx                   integer;
  v_weapon                 jsonb;
  v_w_range                double precision;
  v_w_pspeed               double precision;
  v_w_power                double precision;
  v_w_ammo_type            text;
  v_w_ammo_per_shot        integer;
  v_w_next_ready           timestamptz;
  v_new_ammo               integer;
  v_t_hp                   double precision;
  v_t_shield               double precision;
  v_t_shieldmax            double precision;
  v_t_alive                integer;
  v_t_shiphp               double precision;
  v_t_side                 text;
  v_t_defense              double precision;
  v_t_mainship             uuid;
  v_dmg                    double precision;
  v_shield_new             double precision;
  v_enemy_count            integer;
  v_enemy_range            double precision;
  v_enemy_speed            double precision;
  v_enemy_proj_speed       double precision;
  v_enemy_cooldown         double precision;
  v_enemy_unit_hp          double precision;
  v_enemy_unit_power       double precision;
  v_spawn_i                integer;
  v_dmg_player_total       double precision;
  v_dmg_enemy_total        double precision;
  -- ██ E3 (0260) — the encounter-resolver working set ██
  v_resolver_engaged      boolean;   -- read ONCE per invocation (the quad-flag AND); see the one-read block
  v_plan                  jsonb;     -- the resolved plan for THIS spawn, or NULL (resolver dark / no plan)
  v_fresh_resolve         boolean;   -- true only on the FIRST resolve of an encounter (gates tag + ledger)
begin
  v_tick_secs     := coalesce(cfg_num('combat_tick_seconds'), 3);
  v_retreat_delay := coalesce(cfg_num('retreat_delay_seconds'), 8);
  v_trans_secs    := coalesce(cfg_num('wave_transition_seconds'), 3);
  v_var_pct       := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
  v_def_base      := coalesce(cfg_num('defense_curve_base'), 100);
  v_log_ticks     := cfg_bool('combat_tick_logging');
  v_log_events    := cfg_bool('combat_event_logging');
  v_log_debug     := cfg_bool('combat_debug_logging');
  v_shield_regen  := coalesce(cfg_num('shield_regen_combat_pct'), 0);
  v_per_ship_targeting := cfg_bool('per_ship_targeting_enabled');
  -- COMBAT-S3 (0234): joins the SAME one-read-per-invocation block, never re-read inside the loop.
  v_spatial_combat_enabled := cfg_bool('spatial_combat_enabled');
  -- E3 (0260): the QUAD-FLAG resolver gate — read ONCE here, never re-read in the loop. INERT unless all
  -- four flags are lit; flag OFF => the resolved branch is unreachable and combat is byte-identical to pre-E3.
  v_resolver_engaged := cfg_bool('enemy_content_registry_enabled')
                        and cfg_bool('encounter_authoring_enabled')
                        and cfg_bool('encounter_binding_authoring_enabled')
                        and cfg_bool('encounter_resolver_enabled');

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
    begin
    v_tick := e.tick_number + 1;
    select * into pr from location_presence where id = e.presence_id;
    select base_difficulty, reward_tier, max_presence_seconds into loc from locations where id = e.location_id;

    -- COMBAT-S3 (0234): THE NULL-POS FALLBACK. Read once per encounter per tick, BEFORE the aggregate
    -- select. An encounter with even one NULL pos_x row (dark at creation time, or created before the
    -- flag lit) is NEVER spatial, regardless of what the flag reads THIS tick — an in-flight battle is
    -- never spatialized mid-fight.
    v_is_spatial := v_spatial_combat_enabled
      and exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null);

    -- COMBAT-S3 (0234): THE ONE MARKED AGGREGATE-SELECT HUNK. Dark/no-positions arm is the 0228 head
    -- SELECT, byte-identical (extract-and-diff: the else-arm below is untouched).
    if v_is_spatial then
      select coalesce(sum(hp_current), 0), coalesce(sum(alive_count), 0)
        into v_hp_total, v_alive_total
        from combat_units where encounter_id = e.id and side = 'player';
      v_attack := 0; v_defense := 0;
    else
      -- SLICE D1: member rows have no unit_types match → LEFT JOIN + snapshot-first stat reads. Every
      -- legacy row matches (FK) and has NULL snapshots, so coalesce resolves to the same catalog stats.
      select coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0),
             coalesce(sum(coalesce(cu2.defense_snapshot, ut.defense) * cu2.alive_count), 0),
             coalesce(sum(cu2.hp_current), 0),
             coalesce(sum(cu2.alive_count), 0)
        into v_attack, v_defense, v_hp_total, v_alive_total
        from combat_units cu2 left join unit_types ut on ut.id = cu2.unit_type_id
        where cu2.encounter_id = e.id;
    end if;

    -- (A) Already destroyed → defeat, NO rewards. [SHARED — 0228 head, unmodified: its only combat_units
    --     read filters `main_ship_id is not null`, which already excludes every enemy row.]
    if v_hp_total <= 0 or v_alive_total <= 0 then
      perform fleet_destroy(e.fleet_id);
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
        perform mainship_mark_combat_destroyed(cu.main_ship_id);
      end loop;
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), player_integrity_current=0, player_power_current=0,
             total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
          values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, 0, 0,
                  e.enemy_integrity_current, e.enemy_integrity_current, 'defeat');
      end if;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, 0, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      end if;
      perform report_create(e.id);
      v_count := v_count + 1; continue;
    end if;

    -- (B) End: retreat delay elapsed or forced auto-extract. [SHARED — 0228 head, unmodified: its
    --     member-repatriation read also filters `main_ship_id is not null`.]
    v_secs_inside  := extract(epoch from (now() - e.started_at));
    v_max_secs     := coalesce(loc.max_presence_seconds, cfg_num('max_presence_seconds_default'), 1800);
    v_forced       := v_secs_inside >= v_max_secs;
    v_retreat_done := e.status='retreating' and e.retreat_started_at is not null
                      and now() - e.retreat_started_at >= make_interval(secs => v_retreat_delay);
    if v_retreat_done or v_forced then
      v_end := case when v_forced and e.status <> 'retreating' then 'completed' else 'escaped' end;
      select origin_base_id into v_base_id from fleets where id = e.fleet_id;
      select x, y into v_base_x, v_base_y from bases where id = v_base_id;
      select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
      v_speed := coalesce(fleet_speed(e.fleet_id), combat_fleet_return_speed(e.fleet_id));
      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform presence_complete(e.presence_id);
      -- ── ★ THE CHOSEN-DESTINATION HUNK (the ONLY delta vs the 0261 head) ★ ──────────────────────
      -- The head hardcoded the destination: always back to origin_base_id. It now PREFERS the
      -- destination the player ordered mid-combat (command_ship_group_go step 8 stores it in
      -- fleets.retreat_target_location_id, a column whose only writer is that order) and falls back to
      -- origin_base_id when none is stored — or when the stored port is no longer an active location,
      -- so a destination that went invalid during the window sends the fleet home instead of leaving
      -- the encounter stuck retreating forever.
      -- The recording is CONSUMED here — cleared whether or not it was still usable — so it can never
      -- leak into a later sortie of the same fleet. It is this slice's own column, so clearing it
      -- disturbs nothing else (NO-HOME's return_location_id is untouched, by design: see the header).
      -- Nothing else in this branch changes: the window that got us here, the reward
      -- lock, the encounter update, the report, the presence completion, fleet_set_returning, the
      -- member marking and the cargo attach are all the head's lines, verbatim. The locals live in a
      -- nested DECLARE so the head's declaration block stays byte-identical.
      --
      -- WHY A 'space' TARGET, not a 'location' one: the arrival must leave the fleet in a state where
      -- the sortie is OVER. The settle's location branch calls fleet_set_present -> status 'present',
      -- and every sortie-manifest predicate is live-scoped on 'moving'/'present'/'returning' (0169),
      -- so the members would stay pinned 'returning' forever and the group would answer
      -- 'group_on_sortie' to every later order — a permanent wedge. The space branch calls
      -- fleet_set_in_space -> status 'idle', which is exactly as dead as the base branch's
      -- fleet_complete as far as the manifest is concerned: the EXISTING reconciler frees the members,
      -- with no new writer, no manifest delete and no change to the settle. The fleet parks in ORBIT
      -- at the chosen port — where the mover's own S4 translate parks a port move — and DOCK stays
      -- its own verb.
      declare
        v_ret_loc uuid;
        v_dest_x  double precision;
        v_dest_y  double precision;
      begin
        select f.retreat_target_location_id into v_ret_loc from fleets f where f.id = e.fleet_id;
        if v_ret_loc is not null then
          update fleets set retreat_target_location_id = null, updated_at = now() where id = e.fleet_id;
          select l.x, l.y into v_dest_x, v_dest_y
            from locations l where l.id = v_ret_loc and l.status = 'active';
        end if;
        if v_dest_x is not null and v_dest_y is not null then
          v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
                                  'space', null, null, null, v_dest_x, v_dest_y, 'return_home', v_speed);
        else
          v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
                                  'base', v_base_id, null, null, v_base_x, v_base_y, 'return_home', v_speed);
        end if;
      end;
      -- ── ★ END OF THE CHOSEN-DESTINATION HUNK — the head continues verbatim from here ★ ─────────
      perform fleet_set_returning(e.fleet_id, v_mv);
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null and alive_count > 0 loop
        perform mainship_mark_legacy_in_flight(cu.main_ship_id, 'returning');
      end loop;
      if e.total_rewards_json is not null and e.total_rewards_json <> '{}'::jsonb then
        perform movement_attach_cargo(v_mv, e.id, e.total_rewards_json);
      end if;
      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, reward_delta_json, result)
          values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, v_hp_total, v_hp_total,
                  e.enemy_integrity_current, e.enemy_integrity_current, e.total_rewards_json, v_end);
      end if;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, 0, 'retreat_completed', 'player', 'player', jsonb_build_object('forced', v_forced));
      end if;
      v_count := v_count + 1; continue;
    end if;

    -- (C) Combat step.
    if v_is_spatial then
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      -- COMBAT-S3 (0234) SPATIAL COMBAT STEP — replaces the aggregate-damage step for any encounter
      -- whose combat_units carry positions. See the migration header for the full design walkthrough.
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      v_danger   := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
      v_variance := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_offense  := (e.status = 'active');
      v_wave_num := e.wave_number;
      v_seq      := 0;
      v_wave_paused := false;

      select coalesce(sum(hp_current), 0) into v_e_before from combat_units where encounter_id = e.id and side = 'enemy';

      -- Wave lifecycle: spawn a fresh synthetic pirate wave when the enemy side is wiped — the exact
      -- mirror of the aggregate arm's `enemy_integrity_current <= 0` branch, now materialized as
      -- combat_units rows split across N units instead of a lone scalar.
      if v_e_before <= 0 then
        if e.next_wave_at is not null and now() < e.next_wave_at then
          v_wave_paused := true;
          if v_log_ticks then
            insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                   player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
              values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
          end if;
          update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
          v_count := v_count + 1;
        else
          -- E3 (0260): a resolved encounter REUSES its own plan on every wave (resolved_plan_json set) —
          -- never re-resolving, which with cap=1 would count the encounter against itself and degrade
          -- wave 2+ to a synthetic wave while the sticky tag still paid the resolved reward. Only a FRESH
          -- encounter (tag NULL) calls the resolver, so cap/cooldown apply just at first resolution
          -- (correctly excluding self — the tag is written AFTER the first spawn). A NULL plan (resolver
          -- dark / no binding / cap / cooldown / no unit) falls through to the VERBATIM pre-E3 wave below.
          v_fresh_resolve := false;
          if v_resolver_engaged then
            if e.resolved_plan_json is not null then
              v_plan := e.resolved_plan_json;
            else
              v_plan := public.resolve_location_encounter(e.location_id, e.id::text);
              v_fresh_resolve := true;
            end if;
          end if;
          if v_resolver_engaged and v_plan is not null then
            -- E3 (0260) RESOLVED WAVE: instantiate the authored plan. SAME pacing formulas as the
            -- synthetic arm (690-703), substituting each unit-archetype base_difficulty and the
            -- plan's rolled count; every unit spawns at the location center with the identical weapons_json
            -- shape. Tags the encounter + upserts the runtime ledger; emits a resolved wave_spawned event.
            v_wave_num := e.waves_cleared + 1;
            select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
            v_enemy_proj_speed := coalesce(cfg_num('enemy_synthetic_projectile_speed'),250);
            v_enemy_cooldown   := coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2);
            delete from combat_units where encounter_id = e.id and side = 'enemy';
            v_e_before := 0;
            for v_weapon in select value from jsonb_array_elements(v_plan->'units') loop
              v_enemy_count := (v_weapon->>'count')::integer;
              continue when v_enemy_count <= 0;   -- FIX 4: a 0-count plan unit spawns nothing (no phantom 1)
              v_enemy_hp     := (v_weapon->>'base_difficulty')::double precision * coalesce(cfg_num('enemy_hp_base'),14)
                                * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
              v_enemy_attack := (v_weapon->>'base_difficulty')::double precision * coalesce(cfg_num('enemy_attack_base'),1.0)
                                * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
              v_enemy_range  := coalesce(cfg_num('enemy_synthetic_range_base'),120)
                                + (v_weapon->>'base_difficulty')::double precision * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5);
              v_enemy_speed  := coalesce(cfg_num('enemy_synthetic_speed_base'),3)
                                + (v_weapon->>'base_difficulty')::double precision * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2);
              v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;
              v_enemy_unit_power := v_enemy_attack / v_enemy_count;
              for v_spawn_i in 1 .. v_enemy_count loop
                insert into combat_units (
                  encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
                  hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
                values (
                  e.id, e.player_id, v_weapon->>'unit_type_id', 'enemy', v_enemy_unit_hp, 1, 1,
                  v_enemy_unit_hp, v_enemy_unit_hp, v_loc_x, v_loc_y, v_enemy_speed,
                  jsonb_build_array(jsonb_build_object(
                    'module_type_id', 'pirate_synthetic_weapon', 'range', v_enemy_range,
                    'projectile_speed', v_enemy_proj_speed, 'power', v_enemy_unit_power,
                    'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', v_enemy_cooldown,
                    'next_ready_at', null, 'ammo_remaining', null)));
              end loop;
              v_e_before := v_e_before + v_enemy_hp;
            end loop;
            v_enemy_hp := v_e_before;   -- the wave TOTAL (enemy_integrity_max mirrors the synthetic arm)
            if v_fresh_resolve then
              -- tag + the cooldown/active-count ledger are written ONLY at first resolution; a reused
              -- plan (wave 2+) leaves both untouched so the cooldown anchors on the FIRST spawn only.
              update combat_encounters set resolved_plan_json = v_plan where id = e.id;
              insert into encounter_runtime_state (location_id, encounter_profile_id, last_spawn_at, active_count)
                values (e.location_id, (v_plan->>'encounter_profile_id')::uuid, now(), 1)
                on conflict (location_id, encounter_profile_id)
                do update set last_spawn_at = now(), active_count = encounter_runtime_state.active_count + 1;
            end if;
            if v_log_events then
              insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
                values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                        jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_e_before), 'units', jsonb_array_length(v_plan->'units'), 'resolved', true));
            end if;
            v_seq := v_seq + 1;
          else
          v_wave_num     := e.waves_cleared + 1;
          -- SAME wave-hp/wave-attack formulas the aggregate arm has always used — UNCHANGED config
          -- keys — so a spatial wave's total hp/dps matches what the aggregate arm would have rolled.
          v_enemy_hp     := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                            * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
          v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                            * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
          v_enemy_count  := least(coalesce(cfg_num('enemy_synthetic_max_units'),6)::integer, greatest(1, v_danger));
          select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
          v_enemy_range      := coalesce(cfg_num('enemy_synthetic_range_base'),120)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5);
          v_enemy_speed      := coalesce(cfg_num('enemy_synthetic_speed_base'),3)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2);
          v_enemy_proj_speed := coalesce(cfg_num('enemy_synthetic_projectile_speed'),250);
          v_enemy_cooldown   := coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2);
          v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;
          v_enemy_unit_power := v_enemy_attack / v_enemy_count;

          -- Pirates spawn from the ZONE/LOCATION CENTER — every synthetic unit lands at the same point.
          delete from combat_units where encounter_id = e.id and side = 'enemy';
          for v_spawn_i in 1 .. v_enemy_count loop
            insert into combat_units (
              encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
              hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
            values (
              e.id, e.player_id, 'pirate_synthetic', 'enemy', v_enemy_unit_hp, 1, 1,
              v_enemy_unit_hp, v_enemy_unit_hp, v_loc_x, v_loc_y, v_enemy_speed,
              jsonb_build_array(jsonb_build_object(
                'module_type_id', 'pirate_synthetic_weapon', 'range', v_enemy_range,
                'projectile_speed', v_enemy_proj_speed, 'power', v_enemy_unit_power,
                'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', v_enemy_cooldown,
                'next_ready_at', null, 'ammo_remaining', null)));
          end loop;
          v_e_before := v_enemy_hp;  -- the fresh wave's starting total (mirrors the aggregate arm's v_e_before)
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                      jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp), 'units', v_enemy_count));
          end if;
          v_seq := v_seq + 1;
          end if;
        end if;
      else
        v_enemy_hp := e.enemy_integrity_max;  -- ongoing wave: the ceiling carries over, unchanged
      end if;

      if not v_wave_paused then
        -- Shield regen — once per unit per tick, BEFORE any fire this tick (the SHIELD-1 pattern,
        -- reused: a NULL shield_max row is untouched, exactly the shieldless-unit no-op).
        for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 and shield_max is not null loop
          update combat_units set shield_current = least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen)
            where id = cu.id;
        end loop;

        -- Freeze this tick's population BEFORE any movement is applied — every targeting decision
        -- below reads THIS snapshot, never the live table, so a unit processed earlier in the loop
        -- can never contaminate a later unit's pre-move distance.
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', cu2.id, 'side', cu2.side, 'pos_x', cu2.pos_x, 'pos_y', cu2.pos_y,
                 'my_range', (select max((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'move_speed', coalesce(cu2.move_speed, 0),
                 'aggro_priority', cu2.aggro_priority,
                 'main_ship_id', cu2.main_ship_id)), '[]'::jsonb)
          into v_units
          from combat_units cu2
          where cu2.encounter_id = e.id and cu2.alive_count > 0;

        v_dmg_player_total := 0; v_dmg_enemy_total := 0;

        for v_ur in
          select * from jsonb_to_recordset(v_units) as x(
            id uuid, side text, pos_x double precision, pos_y double precision,
            my_range double precision, move_speed double precision, aggro_priority integer, main_ship_id uuid)
        loop
          -- Retreating player ships hold position and cease fire (the v_offense gate, mirrored — the
          -- enemy side is NEVER gated by this, exactly matching the aggregate arm's asymmetry).
          if v_ur.side = 'player' and not v_offense then
            continue;
          end if;

          -- TARGETING: nearest alive opposite-side unit, aggro-tier-filtered (S1's screening, reused
          -- verbatim in spirit — while any escort, aggro 0, is alive, only escorts are targetable; the
          -- player side has no aggro filter since every enemy row's aggro_priority is NULL).
          v_target_id := null; v_target_x := null; v_target_y := null; v_target_range := null; v_target_dist := null;
          with candidates as (
            select x.id, x.pos_x, x.pos_y, x.my_range, x.aggro_priority,
                   public.osn_distance(v_ur.pos_x, v_ur.pos_y, x.pos_x, x.pos_y) as dist
            from jsonb_to_recordset(v_units) as x(
              id uuid, side text, pos_x double precision, pos_y double precision,
              my_range double precision, move_speed double precision, aggro_priority integer, main_ship_id uuid)
            where x.side is distinct from v_ur.side
          ),
          tier as (select min(aggro_priority) as m from candidates)
          select c.id, c.pos_x, c.pos_y, c.my_range, c.dist
            into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
          from candidates c, tier
          where tier.m is null or c.aggro_priority = tier.m
          order by c.dist asc, c.id asc
          limit 1;

          if v_target_id is null then
            continue;
          end if;

          -- MOVEMENT — combat_unit_decide_move, the pure leaf.
          select action, new_x, new_y into v_move_action, v_new_x, v_new_y
            from public.combat_unit_decide_move(
              v_ur.pos_x, v_ur.pos_y, coalesce(v_ur.my_range,0), coalesce(v_ur.move_speed,0),
              v_target_x, v_target_y, coalesce(v_target_range,0));
          update combat_units set pos_x = v_new_x, pos_y = v_new_y, updated_at = now() where id = v_ur.id;

          -- FIRE — this unit's own weapons_json. Safe to read live: only the unit itself ever writes
          -- its own weapons_json (no other unit's processing this tick can have touched it).
          select weapons_json into v_weapons_json from combat_units where id = v_ur.id;
          v_weapons_out := v_weapons_json;
          for v_widx in 0 .. jsonb_array_length(v_weapons_json) - 1 loop
            v_weapon      := v_weapons_json -> v_widx;
            v_w_range     := (v_weapon->>'range')::double precision;
            v_w_pspeed    := coalesce((v_weapon->>'projectile_speed')::double precision, 300);
            v_w_power     := coalesce((v_weapon->>'power')::double precision, 0);
            v_w_ammo_type := v_weapon->>'ammo_type';
            v_w_ammo_per_shot := coalesce((v_weapon->>'ammo_per_shot')::integer, 0);
            v_w_next_ready := nullif(v_weapon->>'next_ready_at','')::timestamptz;

            if v_w_range is not null and v_target_dist <= v_w_range
               and (v_w_next_ready is null or now() >= v_w_next_ready) then
              if v_log_events then
                insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target,
                      projectile_type, projectile_count, impact_delay_ms, payload_json)
                  values (e.id, e.player_id, v_tick, v_seq,
                          'missile_salvo',
                          case when v_ur.side = 'enemy' then 'pirate' else 'player' end,
                          case when v_ur.side = 'enemy' then 'player' else 'pirate' end,
                          coalesce(v_weapon->>'module_type_id', 'weapon'), 1,
                          round(1000 * v_target_dist / nullif(v_w_pspeed,0))::integer,
                          jsonb_build_object('unit_id', v_ur.id, 'target_id', v_target_id));
              end if;
              v_seq := v_seq + 1;

              -- DAMAGE — re-read the target fresh (it may already have taken an earlier shot THIS
              -- tick from a different firer); a target that died to an earlier shot simply takes no
              -- further damage from this one (`if found` guards it) — no error, no double-kill.
              select hp_current, shield_current, shield_max, alive_count, ship_hp, side, defense_snapshot, main_ship_id
                into v_t_hp, v_t_shield, v_t_shieldmax, v_t_alive, v_t_shiphp, v_t_side, v_t_defense, v_t_mainship
                from combat_units where id = v_target_id and alive_count > 0;
              if found then
                -- The aggregate arm's own asymmetry, reused: player fire on enemies is NEVER
                -- defense-mitigated (enemies carry no defense_snapshot); enemy fire on players IS,
                -- via the same def_base curve.
                if v_t_side = 'enemy' then
                  v_dmg := v_w_power * v_variance;
                else
                  v_dmg := v_w_power * v_def_base / (v_def_base + coalesce(v_t_defense,0)) * v_variance;
                end if;
                -- SHIELD-1 (0195) absorb pattern, reused verbatim: shield soaks min(pool,damage); only
                -- the overflow reaches hp.
                v_absorb     := least(coalesce(v_t_shield,0), v_dmg);
                v_shield_new := case when v_t_shieldmax is not null then v_t_shield - v_absorb else null end;
                v_new_hp     := v_t_hp - (v_dmg - v_absorb);
                v_new_alive  := greatest(0, least(v_t_alive, ceil(v_new_hp / v_t_shiphp)::integer));
                v_destroyed  := v_t_alive - v_new_alive;
                update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive,
                       shield_current = v_shield_new, updated_at = now()
                  where id = v_target_id;
                if v_t_side = 'player' then
                  perform mainship_sync_combat_hp(v_t_mainship, round(greatest(0, v_new_hp))::integer);
                  if v_shield_new is not null then
                    perform mainship_sync_combat_shield(v_t_mainship, round(v_shield_new)::integer);
                  end if;
                  v_dmg_enemy_total := v_dmg_enemy_total + v_dmg;
                else
                  v_dmg_player_total := v_dmg_player_total + v_dmg;
                end if;
                if v_log_debug then
                  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
                    values (e.id, e.player_id, v_tick, v_seq, 'hull_damage',
                            case when v_ur.side='enemy' then 'pirate' else 'player' end,
                            case when v_ur.side='enemy' then 'player' else 'pirate' end,
                            jsonb_build_object('unit_id', v_target_id, 'damage', round(v_dmg)));
                  v_seq := v_seq + 1;
                end if;
                if v_destroyed > 0 and v_log_events then
                  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
                    values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed',
                            case when v_ur.side='enemy' then 'pirate' else 'player' end,
                            case when v_ur.side='enemy' then 'player' else 'pirate' end,
                            jsonb_build_object('unit_id', v_target_id, 'count', v_destroyed));
                  v_seq := v_seq + 1;
                end if;
              end if;

              -- Ammo decrement (per the charter) — documented-inert scaffolding: no module seeds
              -- ammo_type yet (S0's own deferral), so this never actually consumes anything today,
              -- and fire eligibility above is NOT gated on ammo_remaining (no inventory source is
              -- wired to initialize it — a future slice's decision).
              v_new_ammo := case when v_w_ammo_type is not null
                                 then greatest(0, coalesce((v_weapon->>'ammo_remaining')::integer, 0) - v_w_ammo_per_shot)
                                 else null end;
              v_weapons_out := jsonb_set(v_weapons_out, array[v_widx::text],
                                  v_weapon || jsonb_build_object('next_ready_at', now(), 'ammo_remaining', v_new_ammo));
            end if;
          end loop;
          update combat_units set weapons_json = v_weapons_out where id = v_ur.id;
        end loop;

        -- Wave-clear + per-tick bookkeeping — the aggregate arm's shape, computed over per-unit sums.
        select coalesce(sum(hp_current), 0) into v_e_after from combat_units where encounter_id = e.id and side = 'enemy';
        v_cleared := v_offense and v_e_after <= 0;
        select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id and side = 'player';

        v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
        if v_cleared then
          -- E3 (0260): a resolved encounter draws its reward from the AUTHORED profile via the algebraic
          -- mirror of the pre-E3 formula; else the VERBATIM :898-899 reward line (byte-identical when dark).
          if e.resolved_plan_json is not null and v_resolver_engaged then
            v_reward_metal := public.resolve_encounter_reward_inputs(e.resolved_plan_json->'reward_profile'->'resource_grants', loc.reward_tier, v_danger);
          else
          v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                  * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
          end if;
          v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);
          v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                      jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
            v_seq := v_seq + 1;
          end if;
        end if;

        if v_log_ticks then
          insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                 player_power_before, enemy_power, player_damage, enemy_damage,
                 player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after,
                 player_losses_json, reward_delta_json, unit_snapshot_json, result)
            values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
                    v_hp_total, v_e_before, v_dmg_player_total, v_dmg_enemy_total,
                    v_hp_total, greatest(0, v_hp_after), v_e_before, greatest(0, v_e_after),
                    '{}'::jsonb, v_reward_delta, '{}'::jsonb,
                    case when v_cleared then 'wave_cleared' else 'ongoing' end);
        end if;

        update combat_encounters set
          tick_number              = v_tick,
          danger_level             = v_danger,
          wave_number              = v_wave_num,
          waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),
          player_integrity_current = greatest(0, v_hp_after),
          enemy_integrity_max      = v_enemy_hp,
          enemy_integrity_current  = greatest(0, v_e_after),
          enemy_power_current      = greatest(0, v_e_after),
          next_wave_at             = case when v_cleared then now() + make_interval(secs => v_trans_secs) else e.next_wave_at end,
          player_power_current     = fleet_get_power(e.fleet_id),
          total_rewards_json       = case when v_cleared
                                       then total_rewards_json
                                            || jsonb_build_object('metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                            || jsonb_build_object('items', loot_merge_items(total_rewards_json->'items', v_loot_items))
                                       else total_rewards_json end,
          last_resolved_at         = now(),
          updated_at               = now()
        where id = e.id;

        if v_hp_after <= 0 then
          perform fleet_destroy(e.fleet_id);
          for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
            perform mainship_mark_combat_destroyed(cu.main_ship_id);
          end loop;
          perform presence_complete(e.presence_id);
          update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
          end if;
          perform report_create(e.id);
        end if;

        v_count := v_count + 1;
      end if; -- not v_wave_paused
    else
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      -- 0228 HEAD — (C) Combat step, VERBATIM (the dark / no-positions byte-parity arm).
      -- ██████████████████████████████████████████████████████████████████████████████████████████
      v_danger       := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
      v_variance     := (1 - v_var_pct) + random() * (2 * v_var_pct);
      v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                        * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
      v_seq          := 0;
      v_offense      := (e.status = 'active');
      v_wave_num     := e.wave_number;

      if e.enemy_integrity_current <= 0 then
        if e.next_wave_at is not null and now() < e.next_wave_at then
          if v_log_ticks then
            insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                   player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
              values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
          end if;
          update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
          v_count := v_count + 1; continue;
        end if;
        v_wave_num := e.waves_cleared + 1;
        v_enemy_hp := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                      * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
        v_e_before := v_enemy_hp;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                    jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp)));
        end if;
        v_seq := v_seq + 1;
      else
        v_enemy_hp := e.enemy_integrity_max;
        v_e_before := e.enemy_integrity_current;
      end if;

      if v_offense then
        v_player_damage := v_attack * v_variance;
        v_e_after := v_e_before - v_player_damage;
        v_cleared := v_e_after <= 0;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'missile_salvo', 'player', 'pirate', 'missile', greatest(1, round(v_attack/50)::integer), 400,
                    jsonb_build_object('damage', round(v_player_damage), 'wave', v_wave_num));
        end if;
        v_seq := v_seq + 1;
      else
        v_player_damage := 0; v_e_after := v_e_before; v_cleared := false;
      end if;

      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms)
          values (e.id, e.player_id, v_tick, v_seq, 'laser_burst', 'pirate', 'player', 'laser', greatest(1, v_danger), 600);
      end if;
      v_seq := v_seq + 1;
      v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;

      v_target_unit := null;
      if v_per_ship_targeting then
        select id into v_target_unit
          from combat_units
         where encounter_id = e.id and alive_count > 0 and aggro_priority is not null
         order by aggro_priority asc, id asc
         limit 1;
      end if;

      v_losses := '{}'::jsonb; v_counts := '{}'::jsonb; v_snapshot := '{}'::jsonb;
      for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 loop
        v_shield    := least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen);
        if v_target_unit is not null then
          v_d_group := case when cu.id = v_target_unit then v_final_player else 0 end;
        else
          v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
        end if;
        v_absorb    := least(coalesce(v_shield, 0), v_d_group);
        v_shield    := v_shield - v_absorb;
        v_new_hp    := cu.hp_current - (v_d_group - v_absorb);
        v_new_alive := greatest(0, least(cu.alive_count, ceil(v_new_hp / cu.ship_hp)::integer));
        v_destroyed := cu.alive_count - v_new_alive;
        update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive,
               shield_current = v_shield,
               updated_at = now()
          where id = cu.id;
        if cu.unit_type_id is not null then
          v_counts := v_counts || jsonb_build_object(cu.unit_type_id, v_new_alive);
        else
          perform mainship_sync_combat_hp(cu.main_ship_id, round(greatest(0, v_new_hp))::integer);
          if v_shield is not null then
            perform mainship_sync_combat_shield(cu.main_ship_id, round(v_shield)::integer);
          end if;
        end if;
        v_snapshot := v_snapshot || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text),
                         jsonb_build_object('alive', v_new_alive, 'hp', round(greatest(0, v_new_hp))));
        if v_log_debug then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'hull_damage', 'pirate', 'player',
                    jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'damage', round(v_d_group)));
        end if;
        v_seq := v_seq + 1;
        if v_destroyed > 0 then
          v_losses := v_losses || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text), v_destroyed);
          if v_log_events then
            insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
              values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed', 'pirate', 'player',
                      jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'count', v_destroyed));
          end if;
          v_seq := v_seq + 1;
        end if;
      end loop;

      perform fleet_sync_quantities(e.fleet_id, v_counts);
      select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id;

      v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
      if v_cleared and v_offense then
        v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                                * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
        v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);
        v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                    jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
        end if;
        v_seq := v_seq + 1;
      end if;

      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_power_before, enemy_power, player_damage, enemy_damage,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after,
               player_losses_json, reward_delta_json, unit_snapshot_json, result)
          values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
                  v_hp_total, v_e_before, v_player_damage, v_final_player,
                  v_hp_total, greatest(0, v_hp_after), v_e_before, greatest(0, v_e_after),
                  v_losses, v_reward_delta, v_snapshot,
                  case when v_cleared then 'wave_cleared' else 'ongoing' end);
      end if;

      update combat_encounters set
        tick_number              = v_tick,
        danger_level             = v_danger,
        wave_number              = v_wave_num,
        waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),
        player_integrity_current = greatest(0, v_hp_after),
        enemy_integrity_max      = v_enemy_hp,
        enemy_integrity_current  = case when v_cleared then 0 else greatest(0, v_e_after) end,
        enemy_power_current      = case when v_cleared then 0 else greatest(0, v_e_after) end,
        next_wave_at             = case when v_cleared then now() + make_interval(secs => v_trans_secs) else e.next_wave_at end,
        player_power_current     = fleet_get_power(e.fleet_id),
        total_rewards_json       = case when v_cleared and v_offense
                                     then total_rewards_json
                                          || jsonb_build_object('metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                          || jsonb_build_object('items', loot_merge_items(total_rewards_json->'items', v_loot_items))
                                     else total_rewards_json end,
        last_resolved_at         = now(),
        updated_at               = now()
      where id = e.id;

      if v_hp_after <= 0 then
        perform fleet_destroy(e.fleet_id);
        for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
          perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end loop;
        perform presence_complete(e.presence_id);
        update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
        end if;
        perform report_create(e.id);
      end if;

      v_count := v_count + 1;
    end if;
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_combat_ticks: tick failed for encounter % (left in-place; retries next tick): %',
          e.id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;

-- ══ 3. SELF-ASSERT — the migration proves its own grounding or refuses to land ═════════════════════
do $retreat_assert$
declare
  v_go     text;
  v_tick   text;
  v_leave  text;
  v_gate   integer;   -- strpos of the retreat classification gate in the mover
  v_refuse integer;   -- strpos of the surviving non-combat sortie refusal
  v_window text;      -- the mover source BETWEEN the gate and that refusal
  v_bstart integer;   -- strpos of the tick's completion-branch head
  v_bend   integer;   -- strpos of the tick's fleet_set_returning (the branch's tail anchor)
  v_bwin   text;      -- the tick source BETWEEN them
  v_n      integer;
begin
  select prosrc into v_go
    from pg_proc where oid = 'public.command_ship_group_go(uuid,uuid,double precision,double precision)'::regprocedure;
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_leave from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'presence_request_leave';
  if v_go is null or v_tick is null or v_leave is null then
    raise exception '0292 self-assert FAIL: command_ship_group_go / process_combat_ticks / presence_request_leave missing after this migration';
  end if;

  -- ── (1) THE FOUR CLASSIFICATION ARMS all exist, and the blanket refusal is GONE ────────────────
  -- NOTE: every probe below pins a STATEMENT, never a bare token — prosrc carries the body's comments
  -- too, and a comment that merely mentions a reason string must not satisfy (or defeat) a proof.
  v_gate   := strpos(v_go, 'if v_enc.id is not null then');
  v_refuse := strpos(v_go, 'return jsonb_build_object(''ok'', false, ''reason'', ''group_on_sortie'');');
  if v_gate = 0 then
    raise exception '0292 self-assert FAIL: the mover has no encounter classification gate — step 8 was not re-shaped'; end if;
  if strpos(v_go, '''outcome'', ''retreat_started''') = 0 then
    raise exception '0292 self-assert FAIL: arm (a) missing — no ok/retreat_started result'; end if;
  if strpos(v_go, '''outcome'', ''retreat_destination_updated''') = 0 then
    raise exception '0292 self-assert FAIL: arm (b) missing — no ok/retreat_destination_updated result'; end if;
  -- arm (c): 'movement_settled_retry' also exists in the 0233 head (the redirect race), so presence
  -- alone proves nothing — the new arms make it appear MORE than once.
  v_n := (length(v_go) - length(replace(v_go, '''movement_settled_retry''', ''))) / length('''movement_settled_retry''');
  if v_n < 2 then
    raise exception '0292 self-assert FAIL: arm (c) missing — movement_settled_retry appears % time(s), the head''s redirect race only', v_n; end if;
  if v_refuse = 0 then
    raise exception '0292 self-assert FAIL: arm (d) missing — the non-combat sortie refusal (group_on_sortie) was lost'; end if;
  -- THE BLANKET REFUSAL IS GONE: the refusal can only be reached AFTER the classification gate, and
  -- the classification must return ok (a retreat) before it.
  if v_refuse < v_gate then
    raise exception '0292 self-assert FAIL: group_on_sortie is still refused BEFORE the encounter is classified — the blanket refusal survives'; end if;
  v_window := substr(v_go, v_gate, v_refuse - v_gate);
  if strpos(v_window, 'presence_request_leave(') = 0 or strpos(v_window, '''ok'', true') = 0 then
    raise exception '0292 self-assert FAIL: the in-combat arm does not compose the retreat verb and return ok before the sortie refusal'; end if;

  -- ── (2) COORDINATE TARGETS ARE REJECTED TYPED, ahead of any retreat arming ─────────────────────
  if strpos(v_go, '''retreat_needs_port_destination''') = 0 then
    raise exception '0292 self-assert FAIL: a coordinate order in combat is not rejected typed'; end if;
  if strpos(v_go, '''retreat_needs_port_destination''') > strpos(v_go, 'presence_request_leave(') then
    raise exception '0292 self-assert FAIL: the coordinate rejection runs AFTER the retreat is armed'; end if;
  -- and the destination is recorded in the location FK, never as serialized coordinates.
  if strpos(v_go, 'set retreat_target_location_id = p_location_id') = 0 then
    raise exception '0292 self-assert FAIL: the ordered destination is not stored in fleets.retreat_target_location_id'; end if;
  -- and it does NOT touch the NO-HOME return port, whose launch-port value must keep its own meaning.
  if strpos(v_go, 'return_location_id') > 0 or strpos(v_tick, 'set return_location_id') > 0 then
    raise exception '0292 self-assert FAIL: fleets.return_location_id was written by this slice — the NO-HOME return port must stay untouched'; end if;

  -- ── (3) THE COMPLETION BRANCH READS the chosen destination AND CLEARS it, keeping the fallback ──
  v_bstart := strpos(v_tick, 'if v_retreat_done or v_forced then');
  v_bend   := strpos(v_tick, 'perform fleet_set_returning(e.fleet_id, v_mv);');
  if v_bstart = 0 or v_bend = 0 or v_bend < v_bstart then
    raise exception '0292 self-assert FAIL: the tick''s completion branch is not recognisable'; end if;
  v_bwin := substr(v_tick, v_bstart, v_bend - v_bstart);
  if strpos(v_bwin, 'select f.retreat_target_location_id into v_ret_loc from fleets f where f.id = e.fleet_id;') = 0 then
    raise exception '0292 self-assert FAIL: the completion branch does not read the chosen destination'; end if;
  if strpos(v_bwin, 'update fleets set retreat_target_location_id = null') = 0 then
    raise exception '0292 self-assert FAIL: the completion branch does not CONSUME (clear) the chosen destination — it would leak into the next sortie'; end if;
  if strpos(v_bwin, 'l.id = v_ret_loc and l.status = ''active''') = 0 then
    raise exception '0292 self-assert FAIL: the chosen destination is used without re-validating it'; end if;
  if strpos(v_bwin, '''space'', null, null, null, v_dest_x, v_dest_y, ''return_home'', v_speed);') = 0 then
    raise exception '0292 self-assert FAIL: no leg is minted toward the chosen destination'; end if;
  -- the HOME fallback is the head's, verbatim, and still reachable.
  if strpos(v_bwin, 'select origin_base_id into v_base_id from fleets where id = e.fleet_id;') = 0
     or strpos(v_bwin, '''base'', v_base_id, null, null, v_base_x, v_base_y, ''return_home'', v_speed);') = 0 then
    raise exception '0292 self-assert FAIL: the origin_base_id fallback was lost'; end if;

  -- ── (4) presence_request_leave is COMPOSED, never duplicated ───────────────────────────────────
  if strpos(v_go, 'public.presence_request_leave(') = 0 then
    raise exception '0292 self-assert FAIL: the mover does not compose presence_request_leave'; end if;
  if strpos(v_go, 'combat_set_retreating') > 0
     or strpos(v_go, 'retreat_requested_at') > 0
     or strpos(v_go, 'retreat_started_at') > 0
     or strpos(v_go, 'retreat_delay_seconds') > 0
     or strpos(v_go, 'set status = ''retreating''') > 0 then
    raise exception '0292 self-assert FAIL: the mover re-implements part of the retreat state machine — there must be exactly ONE retreat authority'; end if;
  if strpos(v_leave, 'combat_set_retreating') = 0 or strpos(v_leave, 'retreat_requested_at') = 0 then
    raise exception '0292 self-assert FAIL: presence_request_leave is no longer the retreat authority'; end if;
  if strpos(v_tick, 'combat_set_retreating') > 0 or strpos(v_tick, 'presence_request_leave') > 0 then
    raise exception '0292 self-assert FAIL: the tick acquired retreat-arming code (it must only CONSUME the retreat state)'; end if;

  -- ── (5) THE 8-SECOND WINDOW, THE DISARM AND THE REWARD LOCK are the 0261 lines, byte-identical ──
  if strpos(v_tick, 'v_retreat_delay := coalesce(cfg_num(''retreat_delay_seconds''), 8);') = 0
     or strpos(v_tick, 'v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null') = 0
     or strpos(v_tick, 'and now() - e.retreat_started_at >= make_interval(secs => v_retreat_delay);') = 0 then
    raise exception '0292 self-assert FAIL: the 8-second retreat window lines are not the 0261 head''s'; end if;
  if strpos(v_tick, 'v_offense  := (e.status = ''active'');') = 0
     or strpos(v_tick, 'v_offense      := (e.status = ''active'');') = 0 then
    raise exception '0292 self-assert FAIL: the retreating-fleet disarm (v_offense) was altered in one of the two combat arms'; end if;
  if strpos(v_tick, 'v_cleared := v_offense and v_e_after <= 0;') = 0
     or strpos(v_tick, 'if v_cleared and v_offense then') = 0
     or strpos(v_tick, 'case when v_cleared and v_offense') = 0 then
    raise exception '0292 self-assert FAIL: the reward lock (rewards only under v_offense) was altered'; end if;

  -- ── (6) BYTE-IDENTITY ANCHORS: this migration adds no gate and no randomness ───────────────────
  v_n := (length(v_go) - length(replace(v_go, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 2 then
    raise exception '0292 self-assert FAIL: the mover carries % cfg_bool call(s) (want exactly the head''s 2 — the retreat path adds NO gate)', v_n; end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 9 then
    raise exception '0292 self-assert FAIL: the tick carries % cfg_bool call(s) (want exactly the 0261 head''s 9)', v_n; end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception '0292 self-assert FAIL: the tick carries % random( call(s) (want exactly the 0261 head''s 2)', v_n; end if;

  -- ── (7) NO FLAG FLIPPED, no new flag: the retreat path is ungated and stays ungated ────────────
  if exists (select 1 from public.game_config where key ilike '%retreat%' and key <> 'retreat_delay_seconds') then
    raise exception '0292 self-assert FAIL: a retreat-related game_config key appeared — this slice introduces no flag'; end if;
  if coalesce((select value #>> '{}' from public.game_config where key = 'retreat_delay_seconds'), '') <> '8' then
    raise exception '0292 self-assert FAIL: retreat_delay_seconds is no longer 8 — the window must not move here'; end if;

  -- ── (8) SCHEMA ANCHOR: the recording column is the existing nullable location FK ───────────────
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'fleets'
       and column_name = 'retreat_target_location_id' and is_nullable = 'YES' and data_type = 'uuid') then
    raise exception '0292 self-assert FAIL: fleets.retreat_target_location_id is missing or not a nullable uuid'; end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'fleets' and column_name = 'return_location_id') then
    raise exception '0292 self-assert FAIL: fleets.return_location_id vanished — this slice must not disturb NO-HOME'; end if;

  -- ── (9) EXPOSURE UNCHANGED: the mover stays a player RPC, the tick stays engine-only ───────────
  if not has_function_privilege('authenticated', 'public.command_ship_group_go(uuid,uuid,double precision,double precision)', 'execute') then
    raise exception '0292 self-assert FAIL: authenticated lost execute on the mover'; end if;
  if has_function_privilege('anon', 'public.command_ship_group_go(uuid,uuid,double precision,double precision)', 'execute') then
    raise exception '0292 self-assert FAIL: anon gained execute on the mover'; end if;
  if has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception '0292 self-assert FAIL: process_combat_ticks became client-executable'; end if;

  raise notice '0292 OK: command_ship_group_go classifies four ways (active -> retreat_started via presence_request_leave; retreating -> retreat_destination_updated, destination REPLACED with no re-arm; terminal -> movement_settled_retry; sortie-without-encounter -> group_on_sortie) and rejects coordinate targets typed; the blanket refusal is gone; the tick''s completion branch reads AND clears fleets.retreat_target_location_id (fleets.return_location_id untouched), re-validates it, and keeps the verbatim origin_base_id fallback; the retreat state machine exists ONLY in presence_request_leave (mover carries none of it, tick arms none of it); the 8s window, the disarm and the reward lock are the 0261 lines byte-identical; mover cfg_bool=2, tick cfg_bool=9 / random=2 (no new gate, no new randomness); no retreat flag introduced; grants unchanged';
end $retreat_assert$;
