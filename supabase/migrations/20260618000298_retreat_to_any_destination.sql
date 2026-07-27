-- 0298 — RETREAT TO ANY DESTINATION. A move order given mid-combat becomes a retreat to WHEREVER
-- THE PLAYER ORDERED — a port, or a bare point in open space. The port-only restriction 0292 shipped
-- is REMOVED, not made optional.
--
-- ── THE OWNER'S WORD, WHICH THIS FILE IMPLEMENTS ───────────────────────────────────────────────────
--   "i don't want to retreat to a port. i want to retreat to anywhere i want."
--   "it should just move, taking damage is okay, like retreating."
-- 0292 refused a coordinate order during live combat with a typed reject, and its own header named
-- the correct fix and deferred it:
--   "FUTURE EXTENSION POINT (not built here): coordinate retreat targets want an additive,
--    exactly-one-of shape on the SAME family — retreat_target_location_id XOR (retreat_target_x AND
--    retreat_target_y) — enforced by a CHECK constraint, with the completion branch choosing the
--    target shape from whichever side is populated."
-- That is exactly what this file builds. It is 0292's own design, finished — not a second mechanism
-- placed beside it. There is ONE retreat-destination concept with TWO representations, ONE writer
-- (command_ship_group_go step 8), ONE reader (process_combat_ticks' completion branch), and ONE
-- schema-level rule that makes "a location target OR a coordinate target, never both" a fact of the
-- table rather than a convention in two function bodies.
--
-- ── WHAT CHANGES — ONE COLUMN PAIR, ONE CONSTRAINT, TWO HUNKS IN TWO FUNCTIONS ─────────────────────
--   (0) fleets.retreat_target_x / fleets.retreat_target_y — additive, nullable, double precision, and
--       a CHECK that ties them to each other and to the existing retreat_target_location_id:
--         (retreat_target_x is null) = (retreat_target_y is null)
--         and not (retreat_target_location_id is not null and retreat_target_x is not null)
--       i.e. a fleet has a LOCATION target, or a COORDINATE target, or NEITHER — never both, and
--       never half a coordinate. The XOR-as-schema-fact idiom is the repo's own
--       (20260618000216_berth_model.sql:149-155, main_ship_instances_berth_xor_fleet).
--
--   (1) command_ship_group_go — re-emitted BYTE-IDENTICAL to its TRUE head
--       (20260618000292_retreat_to_chosen_destination.sql:164-710) EXCEPT step 8's (a)/(b) arm, where
--       the location-only restriction is DELETED. The four-way classification at step 8 is unchanged
--       — (a) encounter 'active' -> arm the retreat, (b) 'retreating' -> re-point only, (c) terminal
--       while settling -> 'movement_settled_retry', (d) sortie with no encounter -> 'group_on_sortie'.
--       ONLY the shape of the recorded destination widens: arms (a) and (b) now write whichever side
--       of the XOR the order carried, in ONE update that sets one side and clears the other, so the
--       constraint can never be transiently violated. The location-only reject is GONE — no code path
--       emits it any more, and the self-assert proves the token is absent from the deployed body.
--
--   (2) process_combat_ticks — re-emitted BYTE-IDENTICAL to its TRUE head
--       (20260618000294_combat_seeds_at_engagement_point.sql:255-1157) EXCEPT the completion branch's
--       destination resolution, which now reads BOTH sides of the XOR, CLEARS BOTH, and mints the
--       return leg to whichever was set:
--         * a LOCATION target is re-validated (still active) and resolves to that port's coordinate —
--           0292's rule, unchanged, including the fall-back-home-on-invalid behaviour;
--         * a COORDINATE target is used as stored. It is deliberately NOT re-validated: the mover
--           already bound-checked it (step 3, +/-10000, finite) and canonicalized it onto the integer
--           world grid BEFORE storing it, and unlike a location a point in space cannot stop existing.
--           Re-validating it would be a second authority over the world's edges.
--         * neither set -> origin_base_id, exactly as before. The fallback is intact.
--       The leg shape is the SAME in every case — a 'space'-target return_home leg departing from the
--       engagement anchor (0294 [T4]) — because 0292 already made a port destination fly to that
--       port's COORDINATE and park in orbit ('space' -> fleet_set_in_space -> status 'idle', which is
--       what un-wedges the sortie manifest; see 0292's header). So admitting a bare coordinate adds no
--       new leg kind, no new arrival branch and no new settle path: it is the identical leg with the
--       destination resolved one step earlier.
--
-- NO other function is re-created. NO existing column, constraint or row is altered. NO game_config
-- row is written and NO flag is flipped — the retreat path is ungated today and stays ungated (the
-- mover still reads exactly the head's two cfg_bool gates; the tick still reads exactly its eight).
--
-- ── WHAT HAPPENS TO A FLEET THAT IS ALREADY MID-RETREAT WHEN THIS DEPLOYS ──────────────────────────
-- IT KEEPS RETREATING TO THE PORT IT WAS ALREADY HEADING FOR, UNINTERRUPTED. Production is a live
-- ~30-player game and fleets are mid-retreat right now; this is the load-bearing property of the
-- slice.
--   * The DDL is purely additive: two NEW nullable columns, NULL on every existing row, and NO ROW IS
--     UPDATED BY THIS FILE. Other things DO read and write retreat_target_location_id throughout the
--     deploy and are meant to — the 3-second combat cron clears it as retreats complete, the
--     client-callable mover sets it as players give orders — which is exactly why nothing here may
--     assert a COUNT of them (see the last bullet). What matters is that none of that traffic is
--     disturbed: an additive nullable ADD COLUMN takes ACCESS EXCLUSIVE only for the catalog change,
--     rewrites no heap, and the writers resume against a table whose old columns are untouched.
--   * The CHECK is satisfied by every pre-existing row by construction — both new columns are NULL,
--     so `(null is null) = (null is null)` is true and `not (loc is not null and null is not null)` is
--     true whether or not a location target is set. A plain, validating ADD CONSTRAINT is therefore
--     safe: there is nothing to backfill and nothing that can fail. (This is the same reasoning 0216
--     used, except that 0216 needed a backfill first and this does not.)
--   * The tick's new branch reads retreat_target_location_id FIRST and treats it exactly as 0292/0294
--     did — re-validate, resolve to the port's coordinate, mint the same 'space' leg — so a fleet with
--     a location target in flight sees byte-equivalent behaviour. The coordinate arm is unreachable
--     for it: its retreat_target_x is NULL.
--   * NOT proven by a COUNT, deliberately. An earlier draft captured how many fleets carried a
--     location retreat target before the DDL and demanded the same number after. That check was
--     WRONG and would have aborted live production deploys on a false premise: process_combat_ticks
--     runs on pg_cron every THREE SECONDS (20260617000026:7) and legitimately CLEARS
--     retreat_target_location_id the moment a retreat completes, while command_ship_group_go stays
--     client-callable throughout the deploy and legitimately sets it. Under READ COMMITTED the
--     pre-count takes its own snapshot, and the ADD COLUMN's wait for ACCESS EXCLUSIVE is precisely a
--     wait on the transactions that move that number — so an ordinary tick landing in that window
--     makes before <> after with nothing wrong. It was also vacuous in CI, where both counts are 0.
--     A migration may pin its OWN effect; it may never pin a number a concurrent writer is allowed to
--     change. What IS asserted instead is the SHAPE — self-assert (9): no fleet row anywhere holds an
--     illegal retreat-target combination. That is this migration's own effect (the CHECK it installs),
--     it is immune to the cron, and it holds on an empty dataset as well as a busy one.
--
-- ── PARITY DISCIPLINE ──────────────────────────────────────────────────────────────────────────────
-- Both bodies below were spliced mechanically out of their TRUE heads; every byte outside the marked
-- hunks is the head's. Signatures, `security definer`, `search_path`, the grants and the exposure
-- posture are unchanged. The preconditions block refuses to run at all unless the DEPLOYED bodies
-- carry the guarantees this file's bases carry — a wrong base fails closed instead of silently
-- landing a revert. (That block is the 0294 lesson, encoded: the same invariant was reverted three
-- times by authors who copied from an older file.)
--
-- FOR THE NEXT AUTHOR: the TRUE head of command_ship_group_go is now THIS file, and the TRUE head of
-- process_combat_ticks is THIS file. 0292's and 0294's prosrc probes pinned the string
-- `select f.retreat_target_location_id into v_ret_loc from fleets f where f.id = e.fleet_id;`, which
-- this migration replaces with a two-column read. Copying 0292 reverts 0294's engagement anchor AND
-- this slice; copying 0294 reverts this slice.
--
-- Forward-only: 0292 and 0294 are not edited.


-- ── 0. PRECONDITIONS — refuse to re-emit over a base we did not build from ─────────────────────────
do $pre$
declare
  v_go   text;
  v_tick text;
begin
  if to_regprocedure('public.command_ship_group_go(uuid, uuid, double precision, double precision)') is null then
    raise exception '0298: command_ship_group_go(uuid, uuid, double precision, double precision) is missing — 0292 must be deployed';
  end if;
  if to_regprocedure('public.process_combat_ticks()') is null then
    raise exception '0298: process_combat_ticks() is missing — there is no tick to widen';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets'
                    and column_name = 'retreat_target_location_id') then
    raise exception '0298: fleets.retreat_target_location_id is missing — 0292 must be deployed';
  end if;

  select prosrc into v_go from pg_proc
   where oid = 'public.command_ship_group_go(uuid, uuid, double precision, double precision)'::regprocedure;
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';

  -- 0292 must be IN the deployed mover, or the body below is not a superset of what is live.
  if position('set retreat_target_location_id = p_location_id' in v_go) = 0 then
    raise exception '0298: the deployed command_ship_group_go does not record a chosen retreat destination — 0292 is not the live head; refusing to re-emit from an unknown base';
  end if;
  if position('presence_request_leave(v_enc.presence_id)' in v_go) = 0 then
    raise exception '0298: the deployed command_ship_group_go does not compose the retreat verb — refusing to re-emit from an unknown base';
  end if;
  -- The chosen-destination retreat must be IN the deployed tick — in EITHER of its two legal shapes.
  -- 0292's single-column read is the base this file was spliced from; the three-column read below is
  -- what this file EMITS. Accepting only the first would make this migration reject its own output,
  -- so a re-run — or a resumed run after a partial apply (`supabase db push` is NOT proven
  -- transaction-atomic; see .github/workflows/deploy-migrations.yml:9-12) — would abort here and wedge
  -- every later migration deploy. Every other guard in this file is already re-run-inert (`add column
  -- if not exists`, the `if not exists` constraint guard, `drop table if exists`); this one was the
  -- lone deviation, not a deliberate one-shot. What the probe still refuses is a tick that carries
  -- NEITHER shape — i.e. a base older than 0292, which is the case it exists to catch.
  if position('select f.retreat_target_location_id into v_ret_loc from fleets f where f.id = e.fleet_id;' in v_tick) = 0
     and position('into v_ret_loc, v_dest_x, v_dest_y from fleets f where f.id = e.fleet_id;' in v_tick) = 0 then
    raise exception '0298: the deployed process_combat_ticks does not carry a chosen-destination retreat in either 0292''s or 0298''s shape — refusing to re-emit from an unknown base';
  end if;
  -- 0294 must be IN the deployed tick. Re-emitting 0292's tick over it would revert the engagement
  -- anchor and send every retreat leg departing from a port the fleet never reached, again.
  if position('v_anchor_x := coalesce(e.engagement_x, loc.x);' in v_tick) = 0 then
    raise exception '0298: the deployed process_combat_ticks does not resolve the engagement anchor — 0294 has been reverted; fix that first, this migration will not mask it';
  end if;
  -- 0242/0291 must be IN the deployed tick. This exact line has now been reverted three times.
  if position('v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)' in v_tick) = 0 then
    raise exception '0298: the deployed process_combat_ticks does not derive spatial mode from persisted rows — 0242/0291 has been reverted AGAIN; fix that first, this migration will not mask it';
  end if;
end $pre$;


-- ══ 1. THE COORDINATE SIDE OF THE RETREAT DESTINATION (additive; the XOR made a schema fact) ═══════
-- Sole writer: command_ship_group_go's step-8 retreat arms. Sole reader: process_combat_ticks'
-- completion branch, which consumes and clears it. Same family, same lifecycle and same single
-- writer/reader pair as retreat_target_location_id — deliberately the SAME concept in a second
-- representation, never a second concept.
alter table public.fleets
  add column if not exists retreat_target_x double precision,
  add column if not exists retreat_target_y double precision;

comment on column public.fleets.retreat_target_x is
  'RETREAT TO ANY DESTINATION (0298): the x of the POINT IN OPEN SPACE a player named by issuing a '
  'coordinate move order while this fleet was IN COMBAT. Already bound-checked (+/-10000, finite) and '
  'canonicalized onto the integer world grid by command_ship_group_go before it is stored, so the '
  'tick consumes it as-is. Exactly-one-of with retreat_target_location_id, enforced by '
  'fleets_retreat_target_one_of. NULL (with retreat_target_y NULL) means "no coordinate was ordered". '
  'Written only by command_ship_group_go step 8; read and CLEARED by process_combat_ticks when the '
  'retreat window expires.';
comment on column public.fleets.retreat_target_y is
  'RETREAT TO ANY DESTINATION (0298): the y of the ordered open-space retreat point. See '
  'fleets.retreat_target_x.';

-- THE XOR — a schema fact, not a convention held up by two function bodies. Every pre-existing row
-- satisfies it the moment the columns are added (both are NULL), so a plain VALIDATING add is safe:
-- nothing to backfill, nothing that can fail, and no fleet mid-retreat is touched. The guard makes a
-- re-run inert; it does not weaken the constraint.
do $xor$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.fleets'::regclass
                    and conname = 'fleets_retreat_target_one_of') then
    alter table public.fleets
      add constraint fleets_retreat_target_one_of
      check (
        (retreat_target_x is null) = (retreat_target_y is null)
        and not (retreat_target_location_id is not null and retreat_target_x is not null)
      );
  end if;
end $xor$;

comment on constraint fleets_retreat_target_one_of on public.fleets is
  'RETREAT TO ANY DESTINATION (0298): a fleet has a LOCATION retreat target, or a COORDINATE retreat '
  'target, or neither — never both, and never half a coordinate. One destination concept, two '
  'representations; the tick reads whichever side is populated.';

-- The 0292 column comment is restated so the schema doc names both representations rather than
-- describing the port as the only one. Documentation only — no DDL, the column is unchanged.
comment on column public.fleets.retreat_target_location_id is
  'RETREAT TO A CHOSEN DESTINATION (0292, widened 0298): the PORT a player named by issuing a move '
  'order while this fleet was IN COMBAT. Exactly-one-of with (retreat_target_x, retreat_target_y) — '
  'the OPEN-SPACE form of the same order — enforced by fleets_retreat_target_one_of. Written only by '
  'command_ship_group_go step 8 (which also arms the retreat via presence_request_leave, in the same '
  'transaction); read, re-validated and CLEARED by process_combat_ticks when the retreat window '
  'expires — the fleet then flies to that port''s coordinate. All three columns NULL means "no '
  'destination was ordered": the retreat goes home to origin_base_id, exactly as it always has. '
  'Distinct from return_location_id, which is NO-HOME''s launch/return port and is not touched by the '
  'retreat path.';


-- ══ 2. command_ship_group_go — the 0292:164-710 TRUE HEAD verbatim, ONE widened hunk at step 8 ═════
-- The ONLY delta is inside step 8's (a)/(b) arm: the location-only refusal is deleted and the
-- destination write takes whichever side of the XOR the order carried. Everything else — the dark
-- gate, the target-shape rule, step 6's target legality, the S4 dock-translate hunk, member_busy, the
-- four-way classification and its settling-race guard, the sole call to presence_request_leave, the
-- no-restart rule for arm (b), the whole origin chain, the dissolve, the pirate-intercept hunk, the
-- return envelope, the grants — is the head, verbatim.
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
  'the newly-minted leg is rolled against every crossed danger zone. RETREAT TO ANY DESTINATION '
  '(0292, widened 0298): a move ordered while the group is IN COMBAT is not refused — step 8 '
  'classifies four ways. Encounter active -> the ordered destination is recorded and the fleet '
  'retreats toward it via the existing presence_request_leave verb (ok/retreat_started); encounter '
  'already retreating -> the stored destination is REPLACED only, the verb is not re-entered and the '
  'window is not restarted (ok/retreat_destination_updated); the encounter already terminal while its '
  'fleet settles -> movement_settled_retry; a sortie with no encounter -> group_on_sortie, unchanged. '
  'THE DESTINATION MAY BE ANYWHERE THE ORDER COULD NAME — a PORT (recorded in '
  'fleets.retreat_target_location_id) or a POINT IN OPEN SPACE (recorded in fleets.retreat_target_x/y, '
  'exactly-one-of with the port by CHECK constraint). A coordinate order mid-combat is no longer '
  'refused; the port-only restriction 0292 shipped is gone.';

revoke all on function public.command_ship_group_go(uuid, uuid, double precision, double precision) from public;
grant execute on function public.command_ship_group_go(uuid, uuid, double precision, double precision) to authenticated;

-- ══ 3. process_combat_ticks — the 0294:255-1157 TRUE HEAD verbatim, ONE widened completion hunk ════
-- Copied character-for-character from 20260618000294_combat_seeds_at_engagement_point.sql. The ONLY
-- delta is inside branch (B), the retreat/forced-extract completion: WHICH destination is resolved.
-- Every other arm — (A) destroyed, (C) the spatial and aggregate combat steps, 0294's engagement
-- anchor and all six of its consuming sites, the E3 resolver wiring, the wave lifecycle, the reward
-- formulas, the 8-second window, the reward lock, the v_offense disarm, the logging, the
-- per-encounter subtransaction contract — is the head, verbatim.
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
  -- ██ HUNK [T1] (0294) — v_loc_x / v_loc_y are RETIRED. The head carried the LOCATION's coordinate
  -- ██ in these two locals and re-read `locations` into them at THREE separate sites; each site was a
  -- ██ chance for a branch to be missed. They are replaced by ONE anchor, resolved once per encounter
  -- ██ at the top of the loop, used at every site. After this migration those two identifiers appear
  -- ██ NOWHERE in this function's code — which is exactly what the self-assert proves (it strips
  -- ██ line comments first, so this banner may name them without defeating its own probe).
  v_anchor_x      double precision;   -- THE ENGAGEMENT ANCHOR: where this fight physically is
  v_anchor_y      double precision;
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
    select base_difficulty, reward_tier, max_presence_seconds, x, y into loc from locations where id = e.location_id;

    -- ██ HUNK [T2] (0294) — THE ONE ENGAGEMENT-ANCHOR RESOLUTION. ████████████████████████████████████
    -- The encounter's LOCATION is its IDENTITY (difficulty, reward tier, presence cap — the three
    -- fields read above, all still read from `locations`, all unchanged). The encounter's ENGAGEMENT
    -- POINT is its POSITION, and 0293 made those two different questions: an INTERCEPT encounter is
    -- physically at the ambush point on the fleet's own leg, tens of world units from the linked
    -- location's centre, and 0293 parks the FLEET row there.
    --
    -- Everything in this function that decides a combat COORDINATE now derives from these two locals
    -- and from nothing else. The `x, y` appended to the read above is the ONLY new column traffic:
    -- the head's three extra `select x, y ... from locations` round trips are gone, so this is a net
    -- REDUCTION of three reads per encounter per tick.
    --
    -- coalesce, not a bare read: engagement_x/engagement_y are nullable and additive (0293), and the
    -- creator itself writes NULL when the linked location has vanished. NULL therefore keeps its
    -- 0293 meaning — "no recorded engagement point" — and resolves the way it always has, to the
    -- location centre. The migration ALSO backfills every non-terminal encounter (see section 2), so
    -- no fight in flight at deploy time relies on that fallback; the fallback remains as the law for
    -- an unstamped row, not as a legacy bridge. A vanished location leaves loc.x NULL, in which case
    -- a stamped engagement point still wins — which is strictly better than the head, which had
    -- nothing at all to fall back to.
    v_anchor_x := coalesce(e.engagement_x, loc.x);
    v_anchor_y := coalesce(e.engagement_y, loc.y);

    -- MODE IS DERIVED FROM PERSISTED DATA ONLY — 0242, restored by 0291, preserved HERE.
    --
    -- DO NOT REINTRODUCE A FLAG READ ON THIS LINE. The flag decides whether NEWLY CREATED encounters
    -- receive spatial data (combat_create_group_encounter reads it once, at creation). Existing
    -- encounter DATA decides which tick algorithm processes them. Conjoining the live flag here means
    -- darkening it mid-fight flips a live spatial encounter onto the AGGREGATE arm, whose stat SELECT
    -- sums every combat_units row with NO side filter — folding enemy rows into the player aggregate.
    --
    -- This line has now been reverted THREE times (0260, 0261, and this migration's own first draft),
    -- every time by re-emitting the tick body from a migration file older than the fix. If you are
    -- copying this function, copy it from the DEPLOYED pg_proc.prosrc, not from a migration.
    v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null);

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
      -- ██ HUNK [T3] (0294): the head re-read the LOCATION here to use as the return leg's ORIGIN.
      -- ██ That read is GONE. movement_create is not a symbolic API — it computes travel_distance
      -- ██ and travel_seconds straight from (origin_x, origin_y) and stores them on the leg — so an
      -- ██ origin at the location centre made an ambushed fleet's homeward leg depart from a port it
      -- ██ never reached: wrong distance, wrong ETA, and a client path that visibly starts somewhere
      -- ██ the ship is not. The origin is now v_anchor_x/v_anchor_y (see [T4]).
      v_speed := coalesce(fleet_speed(e.fleet_id), combat_fleet_return_speed(e.fleet_id));
      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform presence_complete(e.presence_id);
      -- ── ★ THE CHOSEN-DESTINATION HUNK (0292, WIDENED BY 0298) ★ ────────────────────────────────
      -- The 0261 head hardcoded the destination: always back to origin_base_id. 0292 made it prefer
      -- the PORT a player ordered mid-combat. 0298 widens that to the destination the player ordered,
      -- whatever shape it had — command_ship_group_go step 8 records exactly one of
      --   fleets.retreat_target_location_id            (a port), or
      --   fleets.retreat_target_x / retreat_target_y   (a point in open space)
      -- and this branch is their only reader. The exactly-one-of is a CHECK constraint
      -- (fleets_retreat_target_one_of), so exactly one arm below can be live for any fleet and the
      -- two can never disagree.
      --   * a LOCATION target is RE-VALIDATED (must still be an active location) and resolves to that
      --     port's coordinate. A destination that went invalid during the window therefore falls back
      --     home instead of leaving the encounter stuck retreating forever — 0292's rule, unchanged.
      --   * a COORDINATE target is used AS STORED. It is deliberately not re-validated: the mover
      --     bound-checked it and canonicalized it onto the integer world grid before storing, and a
      --     point in space — unlike a location — cannot stop existing. A second bounds check here
      --     would be a second authority over the world's edges.
      --   * neither -> origin_base_id, exactly as the head did. The fallback is intact.
      -- BOTH recordings are CONSUMED here — cleared together, whether or not the target was still
      -- usable — so neither can leak into a later sortie of the same fleet. They are this slice's own
      -- columns, so clearing them disturbs nothing else (NO-HOME's return_location_id is untouched,
      -- by design: see 0292's header). Nothing else in this branch changes: the window that got us
      -- here, the reward lock, the encounter update, the report, the presence completion,
      -- fleet_set_returning, the member marking and the cargo attach are all the head's lines,
      -- verbatim, and both movement_create arms still depart from the engagement anchor (0294 [T4]).
      -- The locals live in a nested DECLARE so the head's declaration block stays byte-identical.
      --
      -- WHY A 'space' TARGET, not a 'location' one — and why a bare coordinate needs no new path:
      -- the arrival must leave the fleet in a state where the sortie is OVER. The settle's location
      -- branch calls fleet_set_present -> status 'present', and every sortie-manifest predicate is
      -- live-scoped on 'moving'/'present'/'returning' (0169), so the members would stay pinned
      -- 'returning' forever and the group would answer 'group_on_sortie' to every later order — a
      -- permanent wedge. The space branch calls fleet_set_in_space -> status 'idle', which is exactly
      -- as dead as the base branch's fleet_complete as far as the manifest is concerned: the EXISTING
      -- reconciler frees the members, with no new writer, no manifest delete and no change to the
      -- settle. So 0292 already flew a PORT destination to that port's COORDINATE and parked the
      -- fleet in orbit — which is why an open-space destination adds NO new leg kind, NO new arrival
      -- branch and NO new settle path here. It is the identical leg; only the resolution of
      -- v_dest_x/v_dest_y differs, one step earlier.
      declare
        v_ret_loc uuid;
        v_dest_x  double precision;
        v_dest_y  double precision;
      begin
        select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y
          into v_ret_loc, v_dest_x, v_dest_y from fleets f where f.id = e.fleet_id;
        if v_ret_loc is not null or v_dest_x is not null then
          update fleets set retreat_target_location_id = null, retreat_target_x = null,
                 retreat_target_y = null, updated_at = now() where id = e.fleet_id;
        end if;
        if v_ret_loc is not null then
          select l.x, l.y into v_dest_x, v_dest_y
            from locations l where l.id = v_ret_loc and l.status = 'active';
        end if;
        if v_dest_x is not null and v_dest_y is not null then
          v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_anchor_x, v_anchor_y,
                                  'space', null, null, null, v_dest_x, v_dest_y, 'return_home', v_speed);
        else
          v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_anchor_x, v_anchor_y,
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
            -- plan's rolled count; every unit spawns at the ENGAGEMENT ANCHOR with the identical
            -- weapons_json shape. Tags the encounter + upserts the runtime ledger; emits a resolved
            -- wave_spawned event.
            -- ██ HUNK [T5] (0294): the head re-read the LOCATION here. That read is GONE; the spawn
            -- ██ point is the anchor resolved once at the top of the loop.
            v_wave_num := e.waves_cleared + 1;
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
                  v_enemy_unit_hp, v_enemy_unit_hp, v_anchor_x, v_anchor_y, v_enemy_speed,
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
          -- ██ HUNK [T6] (0294): the head re-read the LOCATION here. That read is GONE; the spawn
          -- ██ point is the anchor resolved once at the top of the loop. THIS is the block that seeds
          -- ██ WAVE ONE as well as every later wave — the encounter creator writes no enemy row at
          -- ██ all — so this single line is what put an intercept's pirates at the location centre
          -- ██ while the player's own fleet sat at the ambush point.
          v_enemy_range      := coalesce(cfg_num('enemy_synthetic_range_base'),120)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5);
          v_enemy_speed      := coalesce(cfg_num('enemy_synthetic_speed_base'),3)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2);
          v_enemy_proj_speed := coalesce(cfg_num('enemy_synthetic_projectile_speed'),250);
          v_enemy_cooldown   := coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2);
          v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;
          v_enemy_unit_power := v_enemy_attack / v_enemy_count;

          -- Pirates spawn AT THE ENGAGEMENT ANCHOR (0294) — every synthetic unit lands at the same
          -- point, and that point is now where the fight actually is rather than where its location is.
          delete from combat_units where encounter_id = e.id and side = 'enemy';
          for v_spawn_i in 1 .. v_enemy_count loop
            insert into combat_units (
              encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
              hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
            values (
              e.id, e.player_id, 'pirate_synthetic', 'enemy', v_enemy_unit_hp, 1, 1,
              v_enemy_unit_hp, v_enemy_unit_hp, v_anchor_x, v_anchor_y, v_enemy_speed,
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

comment on function public.process_combat_ticks() is
  'COMBAT TICK. ENGAGEMENT ANCHOR (0294): every combat COORDINATE this function decides derives from '
  'ONE anchor, resolved once per encounter per tick as coalesce(combat_encounters.engagement_x, '
  'locations.x) — both enemy wave spawns (the synthetic wave and the E3 resolved wave; the encounter '
  'creator writes no enemy row, so wave one is spawned here too) and the retreat/forced-extract return '
  'leg''s ORIGIN. The location remains the authority for encounter CONTENT (base_difficulty, '
  'reward_tier, max_presence_seconds) and is read exactly once for it. Spatial mode is still derived '
  'from PERSISTED DATA ONLY (0242/0291) — never from a live flag. RETREAT TO ANY DESTINATION (0292, '
  'widened 0298): the completion branch reads the ONE ordered retreat destination in whichever of its '
  'two exactly-one-of representations was recorded — fleets.retreat_target_location_id (a port, '
  're-validated as still active) or fleets.retreat_target_x/y (a point in open space, used as stored '
  'because the mover already bound-checked and canonicalized it) — CLEARS both, and falls back to '
  'origin_base_id when neither is set or the port went invalid. Engine-only: no client role may '
  'execute it.';

-- CREATE OR REPLACE preserves the existing ACL; this function has never been client-executable and
-- this migration does not change that. No grant statement is emitted, exactly as 0291/0292 emitted
-- none — the self-assert below proves the posture rather than re-asserting it by DDL.

-- ══ 4. SELF-ASSERT — the migration proves its OWN effect or refuses to land ════════════════════════
-- SCOPE OF THIS PROOF, STATED UP FRONT: it asserts only what THIS migration does, and it holds on an
-- EMPTY dataset. It asserts NO game_config VALUE, NO feature flag, and NO seed row — 0288 killed a
-- PRODUCTION deploy by demanding a flag be false when the owner had deliberately lit it, and a draft
-- in this same series broke its own proof by asserting a seed row existed. A flag's value and a
-- world's contents are the owner's; what a migration may promise is what it itself did.
--
-- PROSRC-ASSERT COUPLING (the 0221/0222/0234/0262/0291/0293/0294 house lesson): `--` line comments
-- are stripped from every body before the structural probes, so the banners inside the bodies may
-- NAME what this migration removes without the absence probes tripping over the explanation. The ONE
-- probe that runs against the RAW body is the retired-reject probe below — deliberately, because a
-- token that survives only in a comment is exactly the kind of ghost that misleads the next author,
-- and none of this file's banners write it.
do $retreat_any_assert$
declare
  v_go_raw   text;
  v_go       text;
  v_tick     text;
  v_bwin     text;
  v_bstart   integer;
  v_bend     integer;
  v_tok      text;
  v_n        integer;
  v_bad      integer;
  v_def      text;
  v_caught   boolean;
begin
  -- ── (0) THE BODIES ARE THERE AND UNIQUE ──────────────────────────────────────────────────────────
  select count(*) into v_n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_n <> 1 then
    raise exception '0298 FAIL: % pg_proc rows named process_combat_ticks (want exactly 1) — every prosrc-by-proname assert in the repo reads this name', v_n;
  end if;
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_go_raw from pg_proc
   where oid = 'public.command_ship_group_go(uuid, uuid, double precision, double precision)'::regprocedure;
  if v_tick is null or v_go_raw is null then
    raise exception '0298 FAIL: process_combat_ticks / command_ship_group_go missing after this migration';
  end if;
  v_go   := regexp_replace(v_go_raw, '--[^' || chr(10) || ']*', '', 'g');
  v_tick := regexp_replace(v_tick,   '--[^' || chr(10) || ']*', '', 'g');

  -- ── (1) THE RESTRICTION IS GONE — the headline effect of this slice ──────────────────────────────
  -- (1a) the retired reject token appears NOWHERE in the deployed mover, not even in a comment.
  if strpos(v_go_raw, 'retreat_needs_port') <> 0 then
    raise exception '0298 FAIL: the deployed command_ship_group_go still carries the retired port-only retreat reject — the restriction the owner ordered removed is still emitted';
  end if;
  if strpos(v_tick, 'retreat_needs_port') <> 0 then
    raise exception '0298 FAIL: the deployed process_combat_ticks carries the retired port-only retreat reject';
  end if;
  -- (1b) NO retreat-shaped REFUSAL of any kind survives in the mover. The four-way classification
  --      still refuses (c) and (d) with their own typed reasons, and the two retreat OUTCOMES are
  --      ok:true envelopes, so this probe is pinned to the reject shape specifically: nothing may
  --      refuse an order for the SHAPE of its destination any more.
  if strpos(v_go, '''ok'', false, ''reason'', ''retreat_') <> 0 then
    raise exception '0298 FAIL: the mover still returns a retreat-prefixed REJECT reason — a destination shape is being refused again';
  end if;

  -- ── (2) THE MOVER RECORDS WHICHEVER SIDE OF THE XOR THE ORDER CARRIED ────────────────────────────
  -- ONE update statement, setting one side and clearing the other, so the CHECK can never be
  -- transiently violated and a re-order can switch shapes freely.
  if strpos(v_go, 'set retreat_target_location_id = p_location_id,') = 0
     or strpos(v_go, 'retreat_target_x = case when p_location_id is null then v_t_x end,') = 0
     or strpos(v_go, 'retreat_target_y = case when p_location_id is null then v_t_y end,') = 0 then
    raise exception '0298 FAIL: the mover does not record the ordered destination in both representations — a coordinate order would be accepted and then lost';
  end if;
  v_n := (length(v_go) - length(replace(v_go, 'set retreat_target_location_id', '')))
         / length('set retreat_target_location_id');
  if v_n <> 1 then
    raise exception '0298 FAIL: the mover writes the retreat destination in % statements (want exactly 1) — one writer, or the XOR has two authorities', v_n;
  end if;
  -- The shape is decided by the PARAMETER, never by v_t_type (which the S4 dock-translate rewrites).
  if strpos(v_go, 'v_t_type = ''space''') <> 0 then
    raise exception '0298 FAIL: the mover branches the recorded retreat shape on v_t_type — the S4 dock translate would turn a PORT order into a coordinate one';
  end if;

  -- ── (3) 0292's RETREAT MACHINERY IS INTACT — this slice widens the destination and nothing else ──
  -- ONE retreat authority: the verb is composed exactly once, from arm (a) only. Arm (b) re-points
  -- without re-entering it, so a player cannot reset the damage window by re-issuing orders.
  v_n := (length(v_go) - length(replace(v_go, 'presence_request_leave(', ''))) / length('presence_request_leave(');
  if v_n <> 1 then
    raise exception '0298 FAIL: the mover calls the retreat verb % time(s), want exactly 1 (arm (a) only) — arm (b) must re-point without restarting the window', v_n;
  end if;
  foreach v_tok in array array[
      'retreat_started',
      'retreat_destination_updated',
      'movement_settled_retry',
      'group_on_sortie',
      'ce.status in (''active'', ''retreating'')',
      'for update of ce',
      'lp.id = v_enc.presence_id and lp.status = ''active''',
      'combat_destination',
      'invalid_target_shape',
      'target_out_of_bounds',
      'invalid_coordinate',
      'member_busy',
      'cfg_bool(''fleet_movement_unified_enabled'')',
      'cfg_bool(''timed_docking_enabled'')',
      'pirate_intercept_evaluate_leg(v_movement)',
      'movement_position_at('
    ] loop
    if strpos(v_go, v_tok) = 0 then
      raise exception '0298 FAIL: the mover lost a pinned 0208/0219/0233/0292 guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
  -- exactly the head's TWO gates; this slice adds none.
  v_n := (length(v_go) - length(replace(v_go, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 2 then
    raise exception '0298 FAIL: the mover carries % cfg_bool call(s) (want the 0292 count of 2 — this slice adds no gate)', v_n;
  end if;
  -- and NO-HOME's own return port is still none of this slice's business.
  if strpos(v_go, 'return_location_id') <> 0 then
    raise exception '0298 FAIL: the mover touches fleets.return_location_id — NO-HOME''s launch/return port must stay untouched by the retreat path';
  end if;

  -- ── (4) THE TICK READS BOTH REPRESENTATIONS, CLEARS BOTH, AND KEEPS THE FALLBACK ─────────────────
  v_bstart := strpos(v_tick, 'if v_retreat_done or v_forced then');
  v_bend   := strpos(v_tick, 'perform fleet_set_returning(e.fleet_id, v_mv);');
  if v_bstart = 0 or v_bend = 0 or v_bend < v_bstart then
    raise exception '0298 FAIL: the tick''s completion branch is not recognisable';
  end if;
  v_bwin := substr(v_tick, v_bstart, v_bend - v_bstart);
  if strpos(v_bwin, 'select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y') = 0
     or strpos(v_bwin, 'into v_ret_loc, v_dest_x, v_dest_y from fleets f where f.id = e.fleet_id;') = 0 then
    raise exception '0298 FAIL: the completion branch does not read BOTH representations of the ordered retreat destination — an open-space order would be silently ignored';
  end if;
  if strpos(v_bwin, 'update fleets set retreat_target_location_id = null, retreat_target_x = null,') = 0
     or strpos(v_bwin, 'retreat_target_y = null, updated_at = now() where id = e.fleet_id;') = 0 then
    raise exception '0298 FAIL: the completion branch does not CONSUME (clear) BOTH representations — a stale destination would leak into the next sortie';
  end if;
  if strpos(v_bwin, 'l.id = v_ret_loc and l.status = ''active''') = 0 then
    raise exception '0298 FAIL: a PORT retreat destination is used without re-validating it (0292 reverted)';
  end if;
  if strpos(v_bwin, '''space'', null, null, null, v_dest_x, v_dest_y, ''return_home'', v_speed);') = 0 then
    raise exception '0298 FAIL: no leg is minted toward the chosen destination (0292 reverted)';
  end if;
  if strpos(v_bwin, 'select origin_base_id into v_base_id from fleets where id = e.fleet_id;') = 0
     or strpos(v_bwin, '''base'', v_base_id, null, null, v_base_x, v_base_y, ''return_home'', v_speed);') = 0 then
    raise exception '0298 FAIL: the origin_base_id fallback was lost';
  end if;
  -- a stored coordinate is used AS STORED — no second bounds check, no second grid authority.
  if strpos(v_bwin, 'v_dest_x < ') <> 0 or strpos(v_bwin, 'round(v_dest_x') <> 0 then
    raise exception '0298 FAIL: the tick re-validates or re-rounds the stored retreat coordinate — the mover is the one authority over the world grid and its edges';
  end if;

  -- ── (5) 0294's ENGAGEMENT ANCHOR SURVIVES THIS RE-EMISSION, VERBATIM ─────────────────────────────
  if strpos(v_tick, 'v_anchor_x := coalesce(e.engagement_x, loc.x);') = 0
     or strpos(v_tick, 'v_anchor_y := coalesce(e.engagement_y, loc.y);') = 0 then
    raise exception '0298 FAIL: the tick no longer resolves the engagement anchor (0294 reverted)';
  end if;
  if strpos(v_tick, 'v_loc_x') <> 0 or strpos(v_tick, 'v_loc_y') <> 0 then
    raise exception '0298 FAIL: the head''s retired v_loc_x/v_loc_y location-coordinate locals are back (0294 reverted)';
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'v_anchor_x', ''))) / length('v_anchor_x');
  if v_n <> 6 then
    raise exception '0298 FAIL: v_anchor_x appears % time(s), want 0294''s 6 (declaration, resolution, 2 enemy spawns, 2 leg origins)', v_n;
  end if;
  v_n := (length(v_bwin) - length(replace(v_bwin, 'e.location_id, v_anchor_x, v_anchor_y,', '')))
         / length('e.location_id, v_anchor_x, v_anchor_y,');
  if v_n <> 2 then
    raise exception '0298 FAIL: only % of the completion branch''s 2 movement_create arms departs from the engagement anchor (0294 [T4] reverted)', v_n;
  end if;
  -- `locations` is still touched exactly twice in the whole tick: the CONTENT read, and the PORT
  -- retreat destination's re-validation. The coordinate arm adds NO read — that is the point of it.
  v_n := (length(v_tick) - length(replace(v_tick, 'from locations', ''))) / length('from locations');
  if v_n <> 2 then
    raise exception '0298 FAIL: the tick touches locations % time(s), want exactly 2 (the content read + the PORT destination re-validation)', v_n;
  end if;

  -- ── (6) 0242/0291's INVARIANT, RE-STATED VERBATIM (reverted three times; not a fourth) ───────────
  if position('v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)' in v_tick) = 0 then
    raise exception '0298 FAIL: the tick no longer derives spatial mode from persisted rows (0242/0291 reverted AGAIN)';
  end if;
  if position('v_is_spatial := v_spatial_combat_enabled' in v_tick) <> 0
     or position('cfg_bool(''spatial_combat_enabled'')' in v_tick) <> 0 then
    raise exception '0298 FAIL: the flag-conjoined spatial mode is back — darkening the flag would flip a live spatial fight onto the aggregate arm';
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 8 then
    raise exception '0298 FAIL: the tick carries % cfg_bool call(s) (want the 0291/0292/0294 count of 8; this slice adds no gate)', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception '0298 FAIL: the tick carries % random( call(s) (want the head''s 2 — this slice adds no randomness)', v_n;
  end if;
  -- ONE retreat authority: the tick still only CONSUMES retreat state, it never arms it.
  if strpos(v_tick, 'combat_set_retreating') <> 0 or strpos(v_tick, 'presence_request_leave') <> 0 then
    raise exception '0298 FAIL: the tick acquired retreat-arming code — presence_request_leave must remain the single retreat authority';
  end if;
  if strpos(v_tick, 'set return_location_id') <> 0 then
    raise exception '0298 FAIL: fleets.return_location_id was written by the tick — NO-HOME must stay untouched';
  end if;
  foreach v_tok in array array[
      'v_retreat_delay := coalesce(cfg_num(''retreat_delay_seconds''), 8);',
      'v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null',
      'and now() - e.retreat_started_at >= make_interval(secs => v_retreat_delay);',
      'v_offense  := (e.status = ''active'');',
      'v_offense      := (e.status = ''active'');',
      'v_cleared := v_offense and v_e_after <= 0;',
      'if v_cleared and v_offense then',
      'case when v_cleared and v_offense',
      'select base_difficulty, reward_tier, max_presence_seconds, x, y into loc from locations where id = e.location_id;',
      'v_resolver_engaged := cfg_bool(''enemy_content_registry_enabled'')',
      'if e.resolved_plan_json is not null then',
      'insert into encounter_runtime_state (location_id, encounter_profile_id, last_spawn_at, active_count)',
      'continue when v_enemy_count <= 0;',
      'public.combat_unit_decide_move(',
      'perform fleet_sync_quantities(e.fleet_id, v_counts);',
      'perform movement_attach_cargo(v_mv, e.id, e.total_rewards_json);',
      'when query_canceled then raise;'
    ] loop
    if strpos(v_tick, v_tok) = 0 then
      raise exception '0298 FAIL: the tick lost a pinned head guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;

  -- ── (7) THE SCHEMA THIS MIGRATION ADDED ──────────────────────────────────────────────────────────
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets'
                    and column_name in ('retreat_target_x','retreat_target_y')
                    and is_nullable = 'YES' and data_type = 'double precision'
                 having count(*) = 2) then
    raise exception '0298 FAIL: fleets.retreat_target_x/retreat_target_y are not the nullable double precision pair this migration adds';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets'
                    and column_name = 'retreat_target_location_id' and is_nullable = 'YES' and data_type = 'uuid') then
    raise exception '0298 FAIL: fleets.retreat_target_location_id is no longer the nullable uuid 0292 created — this migration must not have altered it';
  end if;
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conrelid = 'public.fleets'::regclass
     and c.conname = 'fleets_retreat_target_one_of'
     and c.contype = 'c'
     and c.convalidated;
  if v_def is null then
    raise exception '0298 FAIL: fleets_retreat_target_one_of is missing, is not a CHECK, or was left NOT VALID — the exactly-one-of shape is not a schema fact';
  end if;
  -- it must be a constraint over exactly the THREE retreat-target columns and nothing else.
  select coalesce(array_length(c.conkey, 1), 0) into v_bad
    from pg_constraint c
   where c.conrelid = 'public.fleets'::regclass and c.conname = 'fleets_retreat_target_one_of';
  select count(*) into v_n
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
   where c.conrelid = 'public.fleets'::regclass and c.conname = 'fleets_retreat_target_one_of'
     and a.attname in ('retreat_target_location_id','retreat_target_x','retreat_target_y');
  if v_n <> 3 or v_bad <> 3 then
    raise exception '0298 FAIL: fleets_retreat_target_one_of covers % column(s), % of them the retreat-target trio (want 3 and 3)', v_bad, v_n;
  end if;

  -- ── (8) THE CONSTRAINT ACTUALLY JUDGES — the DEPLOYED predicate, exercised on a scratch table ────
  -- pg_get_constraintdef pulls the predicate that is really installed; it is re-hung on a bare temp
  -- table carrying only the three columns, and every shape is pushed through it. No game row is read
  -- or written, so this proves the same thing on an EMPTY database as on production.
  execute 'drop table if exists tmp_0298_xor';
  execute format(
    'create temporary table tmp_0298_xor (
       retreat_target_location_id uuid,
       retreat_target_x double precision,
       retreat_target_y double precision,
       constraint tmp_0298_xor_ck %s)', v_def);
  -- LEGAL: no destination ordered; a PORT; a POINT; and the origin (0,0) — which is a real
  -- destination a player may name, and must never read as "unset".
  execute 'insert into tmp_0298_xor values (null, null, null)';
  execute 'insert into tmp_0298_xor values (''00000000-0000-0000-0000-00000000beef'', null, null)';
  execute 'insert into tmp_0298_xor values (null, 1204, -377)';
  execute 'insert into tmp_0298_xor values (null, 0, 0)';
  execute 'select count(*) from tmp_0298_xor' into v_n;
  if v_n <> 4 then
    raise exception '0298 FAIL: the constraint rejected one of the FOUR legal shapes (none / port / point / the origin point) — only % survived', v_n;
  end if;
  -- ILLEGAL: both representations at once, and either half of a coordinate on its own.
  foreach v_tok in array array[
      'insert into tmp_0298_xor values (''00000000-0000-0000-0000-00000000beef'', 5, 5)',
      'insert into tmp_0298_xor values (null, 5, null)',
      'insert into tmp_0298_xor values (null, null, 5)',
      'insert into tmp_0298_xor values (''00000000-0000-0000-0000-00000000beef'', 5, null)'
    ] loop
    v_caught := false;
    begin
      execute v_tok;
    exception when check_violation then
      v_caught := true;
    end;
    if not v_caught then
      raise exception '0298 FAIL: the deployed exactly-one-of constraint ADMITTED an illegal retreat-target shape (%)', v_tok;
    end if;
  end loop;
  execute 'drop table tmp_0298_xor';

  -- ── (9) THIS MIGRATION'S OWN DATA EFFECT — the SHAPE of every fleet row, never a COUNT ───────────
  -- No row is written by this file, so no fleet row may hold a combination the new CHECK forbids.
  -- This is the constraint's own effect restated over the real table, and it is the RIGHT assertion
  -- for a live deploy: it is true no matter what the 3-second combat cron and the client-callable
  -- mover do to individual rows while this runs, and it is equally true (vacuously so, and honestly)
  -- on CI's empty database. Deliberately NOT a before/after COUNT of in-flight port retreats: the
  -- cron CLEARS retreat_target_location_id on every completing retreat and the mover SETS it, both
  -- legitimately and both during the ADD COLUMN's own lock wait, so such a count would abort a live
  -- production deploy on a false premise. See the "already mid-retreat" section of the header.
  select count(*) into v_bad from public.fleets
   where (retreat_target_x is null) <> (retreat_target_y is null)
      or (retreat_target_location_id is not null and retreat_target_x is not null);
  if v_bad <> 0 then
    raise exception '0298 FAIL: % fleet row(s) hold an illegal retreat-target shape', v_bad;
  end if;

  -- ── (10) NO FLAG WRITTEN — and no game_config access at all in either body ───────────────────────
  -- Stated as THIS MIGRATION'S OWN EFFECT: NEITHER emitted body names game_config. Every config value
  -- both functions consult arrives through the cfg_bool/cfg_num leaves, so there is no statement in
  -- either that could read a flag off-authority or write one. This runs against the comment-stripped
  -- bodies, so a banner that merely mentions the table cannot satisfy or trip it, and it FIRES the
  -- moment a future edit inlines a game_config read or an update into either function.
  -- (The former shape of this probe — `game_config present AND cfg_bool absent` — could never fire:
  -- cfg_bool is asserted present, =2 in the mover and =8 in the tick, elsewhere in this same block.
  -- It advertised a property it did not check.) What the owner has any given flag SET to is still
  -- deliberately not this migration's business — 0288 failed a production deploy by making it so.
  if position('game_config' in v_go) <> 0 then
    raise exception '0298 FAIL: the deployed command_ship_group_go names game_config directly — every config read is the cfg_bool leaf''s and this slice writes no flag';
  end if;
  if position('game_config' in v_tick) <> 0 then
    raise exception '0298 FAIL: the deployed process_combat_ticks names game_config directly — every config read is the cfg_bool/cfg_num leaves'' and this slice writes no flag';
  end if;

  -- ── (11) EXPOSURE UNCHANGED — the mover stays authenticated-only, the tick stays engine-only ─────
  if not has_function_privilege('authenticated',
        'public.command_ship_group_go(uuid, uuid, double precision, double precision)', 'execute') then
    raise exception '0298 FAIL: authenticated lost execute on command_ship_group_go — the player cannot order a retreat at all';
  end if;
  if has_function_privilege('anon',
        'public.command_ship_group_go(uuid, uuid, double precision, double precision)', 'execute') then
    raise exception '0298 FAIL: anon can execute command_ship_group_go';
  end if;
  if has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception '0298 FAIL: process_combat_ticks became client-executable';
  end if;

  raise notice '0298 OK: a fleet in combat retreats to ANY destination the player orders. command_ship_group_go step 8 no longer refuses a coordinate order — it records whichever side of the exactly-one-of pair the order carried (fleets.retreat_target_location_id for a port, fleets.retreat_target_x/y for a point in open space) in ONE update that sets one side and clears the other, and the port-only reject token is absent from the deployed body entirely; the four-way classification, the single presence_request_leave call from arm (a) only, arm (b)''s no-restart rule, the settling-race guard, both cfg_bool gates and every 0208/0219/0233 guarantee are the head''s; process_combat_ticks'' completion branch reads BOTH representations, CLEARS both, re-validates only the PORT (a stored point needs no second authority over the world grid), keeps the origin_base_id fallback, and mints the SAME ''space'' return_home leg from the engagement anchor in every case — so an open-space destination adds no leg kind, no arrival branch and no settle path; 0294''s anchor (6 uses, 2 leg origins, locations touched exactly twice), 0242/0291''s data-derived spatial mode, cfg_bool=8 and random=2 all survive; the exactly-one-of CHECK is installed VALIDATED over exactly the three retreat-target columns and was exercised on a scratch table pulled from its own deployed definition — all four legal shapes (none / port / point / the origin point) accepted, all four illegal ones (both, and either half of a coordinate) rejected; no row was written and no fleet row holds an illegal retreat-target shape (asserted as a SHAPE over the live table, never as a before/after COUNT — the 3-second combat cron legitimately clears a completing retreat''s destination mid-deploy and a count would have failed on that); neither emitted body names game_config at all, so no game_config VALUE is asserted anywhere in this proof and no flag can be written by either function; no gate is added, grants unchanged';
end $retreat_any_assert$;
