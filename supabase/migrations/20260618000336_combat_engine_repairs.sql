-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0336 — COMBAT ENGINE REPAIRS
--        eight defects in the fight itself, read off the DEPLOYED body and confirmed on production
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- Migration 0335 is production's head. Everything below was verified against the DEPLOYED
-- pg_get_functiondef text (73,160 chars; no migration file holds the tick whole) and against live
-- production rows, read-only, on 2026-08-03.
--
-- ── THE EIGHT, RANKED BY LIVE HARM ───────────────────────────────────────────────────────────────
-- 1. A MULTI-GUN SHIP THREW AWAY ITS EXTRA GUNS ON KILL TICKS.  The target is resolved ONCE, before
--    the per-weapon loop. All of a ship's guns fired at that one row, and when gun 1 destroyed it
--    the damage step's found-guard DROPPED guns 2 and 3 instead of re-aiming them. Production holds
--    one ship with THREE fitted autocannons, and 0331 had just split its combat_power three ways to
--    feed them — so two thirds of its damage vanished on every kill tick.
-- 2. EVERY ENEMY IN A WAVE SPAWNED ON ONE IDENTICAL POINT.  Both spawn arms inserted all N units at
--    the engagement anchor. Measured on production: every encounter that ever held enemies holds
--    them at exactly ONE distinct position. Distance became a constant, the id tiebreak became
--    absolute, and every gun on every ship converged on the same row — compounding (1). It also
--    rendered the fight as a single pixel.
-- 3. RETREATING SPAWNED A FRESH WAVE THAT SHOT AT A FLEET WHICH COULD NOT SHOOT BACK.  The offense
--    gate silences the PLAYER only; the wave-spawn block carried no status guard at all. Production
--    holds four encounters that died inside the retreat window — 3.4, 4.6, 4.8 and 5.8 seconds in —
--    each becoming a 'defeat', which zeroes total_rewards_json. The entire haul, destroyed by
--    pressing Retreat.
-- 4. THE FOUR TERMINAL ARMS WERE UNCONFINED RAISE SITES.  fleet_destroy and presence_complete both
--    raise on a status mismatch and both ran before their arm's own status write, so a mismatch
--    rolled back the whole tick INCLUDING last_resolved_at and the encounter retried identically,
--    every tick, forever, silently. Only the 0310 auto-exit arm already carried a subtransaction.
-- 5. THREE OF THE FOUR LEAKED fleets.retreat_target_*.  Only the settle arm cleared it, while that
--    arm's own header states the invariant that the recording is ALWAYS consumed.
-- 6. THE ACTOR LOOP ORDER WAS HEAP ORDER.  The population freeze had no ORDER BY, so targeting was
--    deterministic but WHO FIRES FIRST was not — and with sequential damage that decides whose shots
--    are wasted. Any determinism harness over this tick was unsound without it.
-- 7. A LONGER GUN SILENTLY DISABLED A SHORTER ONE ON THE SAME SHIP.  The freeze carried
--    my_range = max(range) and the mover uses that for both the close decision and the kite cap,
--    while the fire gate is PER WEAPON. An Mk-II (range 6) beside an autocannon (range 5) holds the
--    hull at ~6 and the autocannon never fires — 0331's "better gun, less damage" defect recreated
--    through geometry. Latent today (no production ship carries two weapon TYPES); the Mk-II is
--    craftable.
-- 8. THE HIGHEST-DIFFICULTY SITE WAS AN UNWINNABLE STANDOFF.  Executed against the DEPLOYED mover,
--    read-only, at production's live knobs: at The Furnace (base_difficulty 60, hidden) the synthetic
--    enemy range is 3.6 + 0.04*60 = 6.0, the formation ring is 6.0, so the wave spawns INSIDE its own
--    range, immediately kites, and settles at 5.8 = enemy_range - player_speed. The player's gun
--    reaches 5. It never fires; the pirate fires every tick. Fixed STRUCTURALLY, not by a number:
--    the wave now spawns at (player ring + its own range + 1), so it is outside its own reach of
--    EVERY player ship by construction and closes instead of kiting. No knob is moved.
--
-- ── WHAT THIS MIGRATION DOES ─────────────────────────────────────────────────────────────────────
-- FOUR NEW LEAVES, each the single authority for one concept, each composed rather than copied:
--   combat_formation_point         — where slot k of a formation ring sits. Composed by the tick's
--                                    two wave-spawn arms AND by the encounter creator's escort ring.
--   combat_acquire_target          — the nearest LIVE opposite-side unit. The head's candidates/tier
--                                    CTE, lifted whole, plus one liveness predicate. Composed at
--                                    first acquisition and at per-weapon re-acquisition.
--   fleet_consume_retreat_target   — read-and-clear fleets.retreat_target_*. Composed by all four
--                                    terminal arms.
--   combat_encounter_release       — the confined world-state release. Composed by all four arms.
-- SEVENTEEN HUNKS in process_combat_ticks and ONE in combat_create_group_encounter, every old_t sliced
-- verbatim from the migration that owns its deployed text (0299 and 0315), every new_t derived from
-- that slice. Nothing retyped.
-- NO KNOB IS MOVED, AND THAT IS DELIBERATE. An earlier draft of this slice raised
-- spatial_formation_ring_radius 6.0 -> 7.0 so that the ring would clear the widest synthetic enemy
-- range. Adversarial review killed it, correctly, for a reason worth recording: spawning the wave on
-- the ESCORT RING does not establish the invariant at all. The escorts sit on that same circle, so
-- the nearest escort is a CHORD away — 2*R*sin(pi/16) = 0.39*R, i.e. 2.73 at live numbers against a
-- reach of 6.0 — and the property held only for the lead, the one hull at the anchor. Raising a knob
-- to paper over that would have needed R > 2.56 * enemy_range, a ring of 16 rather than 7.
-- The wave instead spawns at (spatial_formation_ring_radius + its own range + 1). Every player ship
-- sits at radius <= spatial_formation_ring_radius, so the minimum distance from ANY player ship to
-- ANY enemy is exactly that range + 1 — outside the wave's reach BY CONSTRUCTION, at every
-- difficulty, with no tuning that can drift and no balance change riding along in this slice.
--
-- ── BLAST RADIUS ON THE LIVE GAME ────────────────────────────────────────────────────────────────
--   * CREATE OR REPLACE of two functions plus four new ones: an atomic catalog swap. THE TICK BODY IS
--     READ FRESH EVERY 3 SECONDS, so the very next tick of every running fight runs the new body.
--     There is no per-fight opt-in and no drain. Read read-only at generation time: production had
--     ZERO encounters in status active or retreating, so nothing was mid-fight.
--   * combat_create_group_encounter changes only where an escort STANDS, and only for a fleet whose
--     ninth-or-later escort used to wrap onto an occupied slot. Slots 0..7 are value-identical.
--   * NO game_config write at all. NO schema change, NO grant widening (the four leaves are revoked
--     from every client role), NO reward, drop, threshold, range, speed or difficulty value moved.
--     This slice writes not one row outside pg_proc.
--   * WHERE A FIGHT NOW OPENS FROM: the wave stands further out, so a fleet takes one to two more
--     silent closing ticks before the first shot. Measured against the DEPLOYED mover at live knobs
--     and the production minimum player combat speed of 0.2: the player fires on tick 1 at
--     base_difficulty 40-60 and on tick 2 at 10-25, versus tick 1 everywhere before — except at The
--     Furnace, where before this migration the player NEVER fires at all.
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
-- Re-apply the deployed bodies with the hunks reverted (0299's and 0315's text) and drop the four
-- leaves. There is nothing else to unwind: this migration writes no config, no combat row and no
-- player state.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
-- WHAT THESE PROVE, HONESTLY: that the emitted TEXT is what this migration intended — never that it
-- EXECUTES. Behaviour is proven by exactly one layer: the disposable apply-proof driving the REAL
-- tick (danger-combat-proof's eight 0336 blocks).
--   (a) the four leaves exist, with the right volatility/security, and no client can execute them
--   (b) ONE targeting authority: the tick's own candidates CTE is gone and both acquisitions compose
--       the leaf
--   (c) ONE liveness predicate, and the volley re-acquires
--   (d) the wave spawns through the formation leaf, on both arms, at (player ring + its own range
--       + 1), and no insert carries the anchor — this is where invariant (A) is actually pinned
--   (e) a retreating encounter cannot reach the spawn; the loop order is pinned; the kite is capped
--       by the shortest gun
--   (f) all four terminal arms are confined and all four consume the retreat target
--   (g) invariant (B), the half geometry cannot establish: a closing wave comes to rest inside the
--       WEAKEST player gun, at every location with a positive difficulty, hidden ones included
--   (h) every carried-through 0299/0310/0314/0317/0331/0332 invariant survives the re-emission
--   (i) metadata parity: the two rewritten functions changed body and NOTHING else
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
declare
  v_tick text;
  v_ccge text;
begin
  if to_regprocedure('public.process_combat_ticks()') is null then
    raise exception '0336 PRECONDITION FAIL: process_combat_ticks is absent';
  end if;
  select prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_ccge from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if v_ccge is null then
    raise exception '0336 PRECONDITION FAIL: combat_create_group_encounter is absent';
  end if;
  -- the base must carry every predecessor whose text this slice sits beside:
  if position('presence_request_leave(e.presence_id)' in v_tick) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick lacks the 0310 auto-exit arm';
  end if;
  if position('v_hit_roll' in v_tick) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick lacks the 0314 per-hit roll';
  end if;
  if position('perform 1 from combat_units where id = v_ur.id and alive_count > 0;' in v_tick) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick lacks the 0317 actor-liveness guard';
  end if;
  if position('perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end if;' in v_tick) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick lacks the 0332 settle-arm reconcile';
  end if;
  if position('v_weight_total' in v_ccge) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed encounter creator lacks the 0331 share-weight fold';
  end if;
  if position('if v_is_lead then' in v_ccge) = 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed encounter creator lacks the 0315 lead election';
  end if;
  -- the defects must still be there, or somebody else edited this body and we must not guess.
  if position('public.combat_acquire_target(' in v_tick) > 0
     or position('public.combat_formation_point(' in v_tick) > 0 then
    raise exception '0336 PRECONDITION FAIL: the deployed tick already composes a 0336 leaf — refusing to re-emit over an unknown edit';
  end if;
end $pre$;

-- ── 1. THE FOUR LEAVES ───────────────────────────────────────────────────────────────────────────
-- Created BEFORE the rewrite so the rewritten bodies never reference a missing function, and each
-- revoked from every client role in the same step: these are engine internals, not a new surface.
-- (The lockdown ESTABLISHES the posture by revoking rather than asserting it — the 0254 lesson.)

-- combat_formation_point — THE ONE AUTHORITY for "where does slot k of a formation ring sit".
-- Slots 0..7 at phase 0 reduce exactly to the escort ring's own cos/sin expression, so no existing
-- formation moves. The radius steps out by half a ring every 8 slots, which is what makes the point
-- distinct for a wave (or a fleet) larger than one ring — the old expression wrapped onto an
-- occupied slot. Phase is in SLOTS, not radians, so 0.5 means "half a slot off the player ring".
create or replace function public.combat_formation_point(
  p_anchor_x double precision,
  p_anchor_y double precision,
  p_radius   double precision,
  p_slot     integer,
  p_phase    double precision)
returns table(x double precision, y double precision)
language sql
immutable
set search_path to 'public'
as $ffp$
  select p_anchor_x + p_radius * (1 + floor(p_slot / 8.0) * 0.5) * cos(2 * pi() * (p_slot + p_phase) / 8.0),
         p_anchor_y + p_radius * (1 + floor(p_slot / 8.0) * 0.5) * sin(2 * pi() * (p_slot + p_phase) / 8.0);
$ffp$;

-- combat_acquire_target — THE ONE AUTHORITY for "who do I shoot". This is the tick's own
-- candidates/tier CTE, lifted whole: same projection, same osn_distance, same aggro-tier screen,
-- same dist-then-id ordering, same limit 1. The ONE addition is the liveness predicate — the same
-- combat_units.alive_count > 0 the actor guard and the damage read already use — so a corpse is not
-- a target and a dead escort does not screen the hull behind it. Positions still come from the
-- FROZEN pre-move snapshot the caller passes in; only liveness is read live.
create or replace function public.combat_acquire_target(
  p_units   jsonb,
  p_my_x    double precision,
  p_my_y    double precision,
  p_my_side text)
returns table(id uuid, pos_x double precision, pos_y double precision,
              my_range double precision, dist double precision)
language sql
stable
set search_path to 'public'
as $fat$
  with candidates as (
    select x.id, x.pos_x, x.pos_y, x.my_range, x.aggro_priority,
           public.osn_distance(p_my_x, p_my_y, x.pos_x, x.pos_y) as dist
    from jsonb_to_recordset(p_units) as x(
      id uuid, side text, pos_x double precision, pos_y double precision,
      my_range double precision, my_min_range double precision,
      move_speed double precision, aggro_priority integer, main_ship_id uuid)
    where x.side is distinct from p_my_side
      and exists (select 1 from public.combat_units cu where cu.id = x.id and cu.alive_count > 0)
  ),
  tier as (select min(aggro_priority) as m from candidates)
  select c.id, c.pos_x, c.pos_y, c.my_range, c.dist
  from candidates c, tier
  where tier.m is null or c.aggro_priority = tier.m
  order by c.dist asc, c.id asc
  limit 1;
$fat$;

-- fleet_consume_retreat_target — THE ONE AUTHORITY for consuming fleets.retreat_target_*. Returns
-- what it cleared, so the settle arm (which must READ the destination) composes the same leaf as the
-- three arms that only need it GONE. The exactly-one-of CHECK still guarantees at most one shape is
-- populated; this leaf neither validates nor interprets, it consumes.
create or replace function public.fleet_consume_retreat_target(p_fleet uuid)
returns table(target_location_id uuid, target_x double precision, target_y double precision)
language plpgsql
security definer
set search_path to 'public'
as $fcr$
begin
  select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y
    into target_location_id, target_x, target_y
    from public.fleets f where f.id = p_fleet;
  if target_location_id is not null or target_x is not null or target_y is not null then
    update public.fleets
       set retreat_target_location_id = null, retreat_target_x = null, retreat_target_y = null,
           updated_at = now()
     where id = p_fleet;
  end if;
  return next;
end;
$fcr$;

-- combat_encounter_release — THE ONE AUTHORITY for releasing a concluded encounter's world state,
-- CONFINED. Each call gets its OWN subtransaction so a failure in one cannot skip the other, and
-- query_canceled re-raises exactly as the outer per-encounter guard treats it: a cancellation must
-- kill the run, never be eaten as a skipped step. Returning normally is the whole point — it is what
-- lets the caller's status write LAND, so a status mismatch CONCLUDES the encounter with a warning
-- instead of rolling back the tick and retrying forever.
create or replace function public.combat_encounter_release(
  p_encounter uuid,
  p_fleet     uuid,
  p_presence  uuid,
  p_destroy_fleet boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $cer$
begin
  if p_destroy_fleet then
    begin
      perform public.fleet_destroy(p_fleet);
    exception
      when query_canceled then raise;
      when others then
        raise warning 'combat_encounter_release: encounter % — fleet % was not in a destroyable state, the encounter still concludes: %',
          p_encounter, p_fleet, sqlerrm;
    end;
  end if;
  begin
    perform public.presence_complete(p_presence);
  exception
    when query_canceled then raise;
    when others then
      raise warning 'combat_encounter_release: encounter % — presence % was not in an active state, the encounter still concludes: %',
        p_encounter, p_presence, sqlerrm;
  end;
end;
$cer$;

revoke all on function public.combat_formation_point(double precision, double precision, double precision, integer, double precision) from public;
revoke all on function public.combat_acquire_target(jsonb, double precision, double precision, text) from public;
revoke all on function public.fleet_consume_retreat_target(uuid) from public;
revoke all on function public.combat_encounter_release(uuid, uuid, uuid, boolean) from public;
revoke all on function public.combat_formation_point(double precision, double precision, double precision, integer, double precision) from anon, authenticated;
revoke all on function public.combat_acquire_target(jsonb, double precision, double precision, text) from anon, authenticated;
revoke all on function public.fleet_consume_retreat_target(uuid) from anon, authenticated;
revoke all on function public.combat_encounter_release(uuid, uuid, uuid, boolean) from anon, authenticated;

-- ── 2. CAPTURE METADATA BEFORE THE REWRITE (for parity check i) ──────────────────────────────────
create temp table _0336_before (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0336_before
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('process_combat_ticks', 'combat_create_group_encounter');

-- ── 3. REWRITE THE HUNKS (located by exact deployed text, never retyped) ─────────────────────────
do $rewrite$
declare
  r record;
  v_oid oid;
  v_src text;
  v_new text;
  v_n integer;
  v_done integer := 0;
begin
  for r in
    select * from (values
    (1, 'process_combat_ticks',
     $h1o$  v_spawn_i                integer;$h1o$,
     $h1n$  v_spawn_i                integer;
  -- ██ 0336 THE FORMATION WORKING SET ██
  -- v_ring_radius is read ONCE per invocation from the SAME game_config key the encounter creator
  -- reads for the player escort ring, so both formations are laid out by one knob and one leaf.
  -- v_spawn_slot is the wave's running 0-based slot, carried ACROSS plan units so a resolved wave
  -- of several archetypes still lands on one ring rather than restarting at slot 0 per archetype.
  v_ring_radius            double precision;
  v_spawn_slot             integer;
  v_slot_x                 double precision;
  v_slot_y                 double precision;$h1n$),
    (2, 'process_combat_ticks',
     $h2o$  v_per_ship_targeting := cfg_bool('per_ship_targeting_enabled');$h2o$,
     $h2n$  v_per_ship_targeting := cfg_bool('per_ship_targeting_enabled');
  -- 0336: the formation ring radius joins the one-read block, never re-read inside the loop. It is
  -- the same key, with the same fallback, that combat_create_group_encounter reads to place the
  -- player escort ring — ONE knob decides how far apart a formation stands, on both sides.
  v_ring_radius   := coalesce(cfg_num('spatial_formation_ring_radius'), 30);$h2n$),
    (3, 'process_combat_ticks',
     $h3o$    if v_hp_total <= 0 or v_alive_total <= 0 then
      perform fleet_destroy(e.fleet_id);
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
        perform mainship_mark_combat_destroyed(cu.main_ship_id);
      end loop;
      perform presence_complete(e.presence_id);$h3o$,
     $h3n$    if v_hp_total <= 0 or v_alive_total <= 0 then
      -- ██ 0336 THE TERMINAL ARM IS CONFINED, AND THE ENCOUNTER STILL CONCLUDES ██
      -- fleet_destroy and presence_complete both RAISE on a status mismatch (fleet_destroy: not in a
      -- destroyable state; presence_complete: presence not in an active state). Neither was guarded
      -- here, and both run BEFORE this arm's own status write — so a mismatch rolled the whole tick
      -- back INCLUDING last_resolved_at, and the encounter retried, identically, every tick, forever
      -- and silently (the 0206 per-row guard downgrades the raise to a warning and the cron keeps
      -- returning normally). That is the wedge send_ship_group_hunt already names in prose.
      -- ONE LEAF, FOUR ARMS: combat_encounter_release confines each call in its own subtransaction
      -- so one failure cannot skip the other, re-raises query_canceled exactly as the outer guard
      -- does, and returns normally — which is what lets the status write below LAND. A mismatch now
      -- CONCLUDES the encounter with a warning instead of wedging it.
      -- ORDER IS IMMATERIAL, CHECKED: fleet_destroy writes fleets, presence_complete writes
      -- location_presence (+ the worldstate cache), mainship_mark_combat_destroyed writes
      -- main_ship_instances. No two of the three read what another writes, so folding the pair into
      -- one call at the head of the arm changes no outcome.
      -- AND THE RETREAT TARGET IS ALWAYS CONSUMED: only the settle arm ever cleared
      -- fleets.retreat_target_*, while its own header states the invariant that the recording is
      -- ALWAYS consumed. A fleet that died, or was wiped mid-fight, kept a stale destination that
      -- the NEXT sortie's settle would then fly to. One leaf, called by all four arms.
      perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
      perform public.fleet_consume_retreat_target(e.fleet_id);
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
        perform mainship_mark_combat_destroyed(cu.main_ship_id);
      end loop;$h3n$),
    (4, 'process_combat_ticks',
     $h4o$      perform report_create(e.id);
      perform presence_complete(e.presence_id);$h4o$,
     $h4n$      perform report_create(e.id);
      -- ██ 0336 THE TERMINAL ARM IS CONFINED, AND THE ENCOUNTER STILL CONCLUDES ██
      -- fleet_destroy and presence_complete both RAISE on a status mismatch (fleet_destroy: not in a
      -- destroyable state; presence_complete: presence not in an active state). Neither was guarded
      -- here, and both run BEFORE this arm's own status write — so a mismatch rolled the whole tick
      -- back INCLUDING last_resolved_at, and the encounter retried, identically, every tick, forever
      -- and silently (the 0206 per-row guard downgrades the raise to a warning and the cron keeps
      -- returning normally). That is the wedge send_ship_group_hunt already names in prose.
      -- ONE LEAF, FOUR ARMS: combat_encounter_release confines each call in its own subtransaction
      -- so one failure cannot skip the other, re-raises query_canceled exactly as the outer guard
      -- does, and returns normally — which is what lets the status write below LAND. A mismatch now
      -- CONCLUDES the encounter with a warning instead of wedging it.
      -- ORDER IS IMMATERIAL, CHECKED: fleet_destroy writes fleets, presence_complete writes
      -- location_presence (+ the worldstate cache), mainship_mark_combat_destroyed writes
      -- main_ship_instances. No two of the three read what another writes, so folding the pair into
      -- one call at the head of the arm changes no outcome.
      -- AND THE RETREAT TARGET IS ALWAYS CONSUMED: only the settle arm ever cleared
      -- fleets.retreat_target_*, while its own header states the invariant that the recording is
      -- ALWAYS consumed. A fleet that died, or was wiped mid-fight, kept a stale destination that
      -- the NEXT sortie's settle would then fly to. One leaf, called by all four arms.
      -- This arm consumes the retreat target a few lines below, where it also READS it, so it takes
      -- the release call alone (p_destroy_fleet false: a fleet that is leaving is not a wreck).
      perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, false);$h4n$),
    (5, 'process_combat_ticks',
     $h5o$        select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y
          into v_ret_loc, v_dest_x, v_dest_y from fleets f where f.id = e.fleet_id;
        if v_ret_loc is not null or v_dest_x is not null then
          update fleets set retreat_target_location_id = null, retreat_target_x = null,
                 retreat_target_y = null, updated_at = now() where id = e.fleet_id;
        end if;$h5o$,
     $h5n$        -- 0336 ONE RETREAT-TARGET CLEARER, COMPOSED HERE. The read-then-clear pair moves into
        -- fleet_consume_retreat_target so the OTHER three terminal arms can consume the recording
        -- without re-implementing it. The leaf returns what it cleared, so this arm loses nothing:
        -- the exactly-one-of CHECK, the location re-validation below, the coordinate-as-stored rule
        -- and the origin_base_id fallback are all unchanged and all still live in this branch.
        select t.target_location_id, t.target_x, t.target_y
          into v_ret_loc, v_dest_x, v_dest_y
          from public.fleet_consume_retreat_target(e.fleet_id) t;$h5n$),
    (6, 'process_combat_ticks',
     $h6o$      if v_e_before <= 0 then
        if e.next_wave_at is not null and now() < e.next_wave_at then$h6o$,
     $h6n$      if v_e_before <= 0 then
        -- ██ 0336 A RETREATING FLEET IS NEVER SENT A FRESH WAVE ██
        -- The offense gate below silences the PLAYER while retreating; the enemy side is never
        -- gated, by design (the aggregate arm's asymmetry, mirrored). But this block had NO status
        -- guard at all, so clearing a wave during the retreat window spawned a LARGER one — danger
        -- rises with waves_cleared — that then shot at a fleet which could not shoot back for the
        -- remaining seconds of the window. Production carries four encounters that died exactly
        -- that way, 3.4 to 5.8 seconds into an 8-second window, and a death is a 'defeat', which
        -- zeroes total_rewards_json: the whole haul, destroyed by pressing Retreat.
        -- ONE CONDITION, AND NO NEW PATH: a retreating encounter with a cleared enemy side simply
        -- carries its ceiling over, exactly as an ONGOING wave does in the else arm below, and
        -- falls through to the normal per-tick bookkeeping. Nothing is spawned, no new tick label
        -- is invented, and branch (B) above still completes the retreat when the delay elapses.
        if e.status = 'retreating' then
          v_enemy_hp := e.enemy_integrity_max;
        elsif e.next_wave_at is not null and now() < e.next_wave_at then$h6n$),
    (7, 'process_combat_ticks',
     $h7o$            delete from combat_units where encounter_id = e.id and side = 'enemy';
            v_e_before := 0;
            for v_weapon in select value from jsonb_array_elements(v_plan->'units') loop$h7o$,
     $h7n$            delete from combat_units where encounter_id = e.id and side = 'enemy';
            v_e_before := 0;
            -- 0336: the slot counter is initialised for the WHOLE resolved wave, outside the
            -- per-archetype loop, so a plan of several unit types still lays out one ring.
            v_spawn_slot := 0;
            for v_weapon in select value from jsonb_array_elements(v_plan->'units') loop$h7n$),
    (8, 'process_combat_ticks',
     $h8o$              for v_spawn_i in 1 .. v_enemy_count loop
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
              end loop;$h8o$,
     $h8n$              -- ██ 0336 THE WAVE SPAWNS ON A RING, NOT ON ONE POINT ██
              -- Every unit of a wave was inserted at the identical anchor. Production proves the effect:
              -- every encounter that ever held enemies holds them at exactly ONE distinct position. Three
              -- consequences, all bad: distance from any actor to every enemy is the same constant, so the
              -- id-ascending tiebreak in targeting became absolute and EVERY gun of EVERY ship converged on
              -- one row; the fight rendered as a single pixel; and the whole wave sat inside the enemy's own
              -- range from tick zero, which is the basin the standoff lives in.
              -- MIRRORS THE PLAYER FORMATION, THROUGH THE SAME LEAF: combat_formation_point is the ONE
              -- authority for "where does slot k of a formation ring sit", composed here and by the encounter
              -- creator's escort ring. Slots 0..7 at phase 0 reproduce the creator's own cos/sin expression
              -- value-for-value, so no player formation moves; the wave takes phase 0.5 — half a slot — so
              -- an enemy never lands exactly on an escort, and the radius steps out every 8 slots so a wave
              -- larger than the ring still has distinct points.
              -- AND THE RADIUS IS THE PLAYER RING PLUS THE WAVE'S OWN REACH, WHICH IS THE WHOLE POINT.
              -- Spawning the wave ON the escort ring would NOT establish the invariant: the escorts sit on
              -- that same circle, so the nearest escort is a CHORD away — 2*R*sin(pi/16), i.e. 0.39*R — and
              -- at live numbers that is 2.73 against a reach of 6.0, deep inside the wave's own range. The
              -- invariant would then hold only for the lead, the one hull standing at the anchor.
              -- Every player ship sits at radius <= v_ring_radius from the anchor, so putting the wave at
              -- v_ring_radius + its own range + 1 makes the minimum distance from ANY player ship to ANY
              -- enemy exactly that range + 1: strictly outside the wave's reach, BY CONSTRUCTION, at every
              -- difficulty. That is why this slice raises no knob and asserts no knob comparison — the
              -- geometry is not a tuning that can drift, it is an identity. What a CI assertion still has to
              -- check is the OTHER half, which geometry cannot fix: that when the closing wave stops closing
              -- it is inside the PLAYER's range (see the range-invariant assert).
              for v_spawn_i in 1 .. v_enemy_count loop
                select fp.x, fp.y into v_slot_x, v_slot_y
                  from public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring_radius + v_enemy_range + 1, v_spawn_slot, 0.5) fp;
                insert into combat_units (
                  encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
                  hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
                values (
                  e.id, e.player_id, v_weapon->>'unit_type_id', 'enemy', v_enemy_unit_hp, 1, 1,
                  v_enemy_unit_hp, v_enemy_unit_hp, v_slot_x, v_slot_y, v_enemy_speed,
                  jsonb_build_array(jsonb_build_object(
                    'module_type_id', 'pirate_synthetic_weapon', 'range', v_enemy_range,
                    'projectile_speed', v_enemy_proj_speed, 'power', v_enemy_unit_power,
                    'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', v_enemy_cooldown,
                    'next_ready_at', null, 'ammo_remaining', null)));
                v_spawn_slot := v_spawn_slot + 1;
              end loop;$h8n$),
    (9, 'process_combat_ticks',
     $h9o$          for v_spawn_i in 1 .. v_enemy_count loop
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
          end loop;$h9o$,
     $h9n$          -- ██ 0336 THE WAVE SPAWNS ON A RING, NOT ON ONE POINT ██
          -- Every unit of a wave was inserted at the identical anchor. Production proves the effect:
          -- every encounter that ever held enemies holds them at exactly ONE distinct position. Three
          -- consequences, all bad: distance from any actor to every enemy is the same constant, so the
          -- id-ascending tiebreak in targeting became absolute and EVERY gun of EVERY ship converged on
          -- one row; the fight rendered as a single pixel; and the whole wave sat inside the enemy's own
          -- range from tick zero, which is the basin the standoff lives in.
          -- MIRRORS THE PLAYER FORMATION, THROUGH THE SAME LEAF: combat_formation_point is the ONE
          -- authority for "where does slot k of a formation ring sit", composed here and by the encounter
          -- creator's escort ring. Slots 0..7 at phase 0 reproduce the creator's own cos/sin expression
          -- value-for-value, so no player formation moves; the wave takes phase 0.5 — half a slot — so
          -- an enemy never lands exactly on an escort, and the radius steps out every 8 slots so a wave
          -- larger than the ring still has distinct points.
          -- AND THE RADIUS IS THE PLAYER RING PLUS THE WAVE'S OWN REACH, WHICH IS THE WHOLE POINT.
          -- Spawning the wave ON the escort ring would NOT establish the invariant: the escorts sit on
          -- that same circle, so the nearest escort is a CHORD away — 2*R*sin(pi/16), i.e. 0.39*R — and
          -- at live numbers that is 2.73 against a reach of 6.0, deep inside the wave's own range. The
          -- invariant would then hold only for the lead, the one hull standing at the anchor.
          -- Every player ship sits at radius <= v_ring_radius from the anchor, so putting the wave at
          -- v_ring_radius + its own range + 1 makes the minimum distance from ANY player ship to ANY
          -- enemy exactly that range + 1: strictly outside the wave's reach, BY CONSTRUCTION, at every
          -- difficulty. That is why this slice raises no knob and asserts no knob comparison — the
          -- geometry is not a tuning that can drift, it is an identity. What a CI assertion still has to
          -- check is the OTHER half, which geometry cannot fix: that when the closing wave stops closing
          -- it is inside the PLAYER's range (see the range-invariant assert).
          v_spawn_slot := 0;
          for v_spawn_i in 1 .. v_enemy_count loop
            select fp.x, fp.y into v_slot_x, v_slot_y
              from public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring_radius + v_enemy_range + 1, v_spawn_slot, 0.5) fp;
            insert into combat_units (
              encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
              hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
            values (
              e.id, e.player_id, 'pirate_synthetic', 'enemy', v_enemy_unit_hp, 1, 1,
              v_enemy_unit_hp, v_enemy_unit_hp, v_slot_x, v_slot_y, v_enemy_speed,
              jsonb_build_array(jsonb_build_object(
                'module_type_id', 'pirate_synthetic_weapon', 'range', v_enemy_range,
                'projectile_speed', v_enemy_proj_speed, 'power', v_enemy_unit_power,
                'ammo_type', null, 'ammo_per_shot', 0, 'cooldown_seconds', v_enemy_cooldown,
                'next_ready_at', null, 'ammo_remaining', null)));
            v_spawn_slot := v_spawn_slot + 1;
          end loop;$h9n$),
    (10, 'process_combat_ticks',
     $h10o$        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', cu2.id, 'side', cu2.side, 'pos_x', cu2.pos_x, 'pos_y', cu2.pos_y,
                 'my_range', (select max((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'move_speed', coalesce(cu2.move_speed, 0),
                 'aggro_priority', cu2.aggro_priority,
                 'main_ship_id', cu2.main_ship_id)), '[]'::jsonb)
          into v_units
          from combat_units cu2
          where cu2.encounter_id = e.id and cu2.alive_count > 0;$h10o$,
     $h10n$        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', cu2.id, 'side', cu2.side, 'pos_x', cu2.pos_x, 'pos_y', cu2.pos_y,
                 'my_range', (select max((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'my_min_range', (select min((w->>'range')::double precision) from jsonb_array_elements(cu2.weapons_json) w),
                 'move_speed', coalesce(cu2.move_speed, 0),
                 'aggro_priority', cu2.aggro_priority,
                 'main_ship_id', cu2.main_ship_id) order by cu2.id), '[]'::jsonb)
          into v_units
          from combat_units cu2
          where cu2.encounter_id = e.id and cu2.alive_count > 0;$h10n$),
    (11, 'process_combat_ticks',
     $h11o$        for v_ur in
          select * from jsonb_to_recordset(v_units) as x(
            id uuid, side text, pos_x double precision, pos_y double precision,
            my_range double precision, move_speed double precision, aggro_priority integer, main_ship_id uuid)
        loop$h11o$,
     $h11n$        for v_ur in
          select * from jsonb_to_recordset(v_units) as x(
            id uuid, side text, pos_x double precision, pos_y double precision,
            my_range double precision, my_min_range double precision,
            move_speed double precision, aggro_priority integer, main_ship_id uuid)
        loop$h11n$),
    (12, 'process_combat_ticks',
     $h12o$          v_target_id := null; v_target_x := null; v_target_y := null; v_target_range := null; v_target_dist := null;
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
          limit 1;$h12o$,
     $h12n$          -- ██ 0336 ONE TARGETING AUTHORITY, COMPOSED — NEVER A SECOND ONE ██
          -- The candidates/tier CTE moved WHOLE into combat_acquire_target: same projection, same
          -- osn_distance, same aggro-tier screen, same dist-then-id ordering, same limit 1. It is
          -- lifted rather than copied precisely so the per-weapon RE-ACQUISITION below can ask the
          -- identical question instead of growing a second targeting rule.
          -- ONE LIVENESS PREDICATE: the leaf adds combat_units.alive_count > 0 on the LIVE row — the
          -- same column comparison the actor guard and the damage read already use, in a third role.
          -- A corpse is no longer a target, and a dead escort no longer screens the hull behind it.
          v_target_id := null; v_target_x := null; v_target_y := null; v_target_range := null; v_target_dist := null;
          select t.id, t.pos_x, t.pos_y, t.my_range, t.dist
            into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
            from public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side) t;$h12n$),
    (13, 'process_combat_ticks',
     $h13o$          -- NOT re-read: the snapshot. Only the actor's own liveness. Targeting still resolves from
          -- the frozen population, which is why a surviving unit still fires at a hull that died
          -- earlier in the tick (its shot simply lands on a corpse and deals nothing, exactly as
          -- before) rather than silently re-acquiring — simultaneity is preserved.$h13o$,
     $h13n$          -- NOT re-read: the snapshot. Only the actor's own liveness, and the target's.
          -- ██ 0336 CORRECTS THE SENTENCE THAT STOOD HERE ██ 0317 wrote that a surviving unit still
          -- fires at a hull which died earlier in the tick "rather than silently re-acquiring —
          -- simultaneity is preserved". That is no longer true, and it should not have been the rule:
          -- the whole defect 0336 fixes is a shot thrown away because its target was already dead,
          -- and a shot wasted on a corpse killed by SOMEBODY ELSE is the same waste as one wasted on
          -- a corpse killed by this ship's own first gun. Treating them differently would be two
          -- rules for one question. So targeting now asks for a LIVE target, at both acquisition
          -- sites, through one leaf.
          -- WHAT IS ACTUALLY SIMULTANEOUS, AND STILL IS: POSITION. Every unit resolves its target and
          -- its close/kite decision from the frozen pre-move world, so no unit gains ground on
          -- another by being processed earlier. DAMAGE has been strictly sequential since 0234 — the
          -- target re-read means a dying unit stops absorbing hits the instant it dies — so death has
          -- always taken effect immediately in the TARGET role. This slice makes it take effect in
          -- the TARGETING role too, which is the consistent end of the same rule.
          -- THE BALANCE CONSEQUENCE, STATED RATHER THAN SMUGGLED: fewer shots are wasted, on both
          -- sides, on every tick where anything dies. Waves are endless and the player destroys far
          -- more units per fight than it loses, so this favours the player — the same direction and
          -- the same mechanism as 0317, and for the same reason. It changes no reward, no drop, no
          -- threshold and no config value.$h13n$),
    (14, 'process_combat_ticks',
     $h14o$          -- MOVEMENT — combat_unit_decide_move, the pure leaf.
          select action, new_x, new_y into v_move_action, v_new_x, v_new_y
            from public.combat_unit_decide_move(
              v_ur.pos_x, v_ur.pos_y, coalesce(v_ur.my_range,0), coalesce(v_ur.move_speed,0),
              v_target_x, v_target_y, coalesce(v_target_range,0));$h14o$,
     $h14n$          -- MOVEMENT — combat_unit_decide_move, the pure leaf.
          select action, new_x, new_y into v_move_action, v_new_x, v_new_y
            from public.combat_unit_decide_move(
              -- 0336 NEVER RETREAT PAST YOUR SHORTEST GUN. The mover uses this argument for BOTH
              -- the close decision and the kite cap, so passing the LONGEST gun made a ship hold at
              -- its longest reach and silently disable every shorter one: the fire gate below is
              -- per weapon, so an Mk-II (range 6) fitted beside an autocannon (range 5) parks the
              -- hull at ~6 and the autocannon never fires — a better gun buying LESS damage, which
              -- is the very defect 0331 was written to end, recreated through geometry.
              -- my_min_range is MY engagement range; the target's my_range stays the LONGEST, because
              -- what I must respect about the enemy is its full reach. Two questions, two values.
              -- Single-weapon ships have min = max, so their movement is byte-identical to the head.
              v_ur.pos_x, v_ur.pos_y, coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),
              v_target_x, v_target_y, coalesce(v_target_range,0));$h14n$),
    (15, 'process_combat_ticks',
     $h15o$            if v_w_range is not null and v_target_dist <= v_w_range
               and (v_w_next_ready is null or now() >= v_w_next_ready) then$h15o$,
     $h15n$            -- ██ 0336 A KILL DOES NOT DISARM THE REST OF THE VOLLEY ██
            -- The target was resolved ONCE, above, before this per-weapon loop. Every gun on the
            -- ship fired at that one row, and when gun 1 destroyed it the damage step's `if found`
            -- simply DROPPED guns 2 and 3 — their shots vanished rather than being re-aimed. On a
            -- ship carrying three autocannons (production has one) that is two thirds of its damage
            -- gone on every kill tick, and 0331 had just split its combat_power three ways to feed
            -- those three barrels. Compounded by the single-point wave spawn, which made every gun
            -- converge on the same row in the first place.
            -- THE SAME AUTHORITY, ASKED AGAIN: re-acquire through combat_acquire_target — no second
            -- targeting rule, no live-table scan of its own. The actor's frozen pre-move position is
            -- still what distance is measured from, exactly as at first acquisition, so the freeze
            -- and its simultaneity are untouched. With nothing left alive to shoot, the volley ends.
            if not exists (select 1 from combat_units cu3 where cu3.id = v_target_id and cu3.alive_count > 0) then
              select t.id, t.pos_x, t.pos_y, t.my_range, t.dist
                into v_target_id, v_target_x, v_target_y, v_target_range, v_target_dist
                from public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side) t;
              if v_target_id is null then
                exit;
              end if;
            end if;
            if v_w_range is not null and v_target_dist <= v_w_range
               and (v_w_next_ready is null or now() >= v_w_next_ready) then$h15n$),
    (16, 'process_combat_ticks',
     $h16o$        if v_hp_after <= 0 then
          perform fleet_destroy(e.fleet_id);
          for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
            perform mainship_mark_combat_destroyed(cu.main_ship_id);
          end loop;
          perform presence_complete(e.presence_id);$h16o$,
     $h16n$        if v_hp_after <= 0 then
          -- ██ 0336 THE TERMINAL ARM IS CONFINED, AND THE ENCOUNTER STILL CONCLUDES ██
          -- fleet_destroy and presence_complete both RAISE on a status mismatch (fleet_destroy: not in a
          -- destroyable state; presence_complete: presence not in an active state). Neither was guarded
          -- here, and both run BEFORE this arm's own status write — so a mismatch rolled the whole tick
          -- back INCLUDING last_resolved_at, and the encounter retried, identically, every tick, forever
          -- and silently (the 0206 per-row guard downgrades the raise to a warning and the cron keeps
          -- returning normally). That is the wedge send_ship_group_hunt already names in prose.
          -- ONE LEAF, FOUR ARMS: combat_encounter_release confines each call in its own subtransaction
          -- so one failure cannot skip the other, re-raises query_canceled exactly as the outer guard
          -- does, and returns normally — which is what lets the status write below LAND. A mismatch now
          -- CONCLUDES the encounter with a warning instead of wedging it.
          -- ORDER IS IMMATERIAL, CHECKED: fleet_destroy writes fleets, presence_complete writes
          -- location_presence (+ the worldstate cache), mainship_mark_combat_destroyed writes
          -- main_ship_instances. No two of the three read what another writes, so folding the pair into
          -- one call at the head of the arm changes no outcome.
          -- AND THE RETREAT TARGET IS ALWAYS CONSUMED: only the settle arm ever cleared
          -- fleets.retreat_target_*, while its own header states the invariant that the recording is
          -- ALWAYS consumed. A fleet that died, or was wiped mid-fight, kept a stale destination that
          -- the NEXT sortie's settle would then fly to. One leaf, called by all four arms.
          perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
          perform public.fleet_consume_retreat_target(e.fleet_id);
          for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
            perform mainship_mark_combat_destroyed(cu.main_ship_id);
          end loop;$h16n$),
    (17, 'process_combat_ticks',
     $h17o$      if v_hp_after <= 0 then
        perform fleet_destroy(e.fleet_id);
        for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
          perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end loop;
        perform presence_complete(e.presence_id);$h17o$,
     $h17n$      if v_hp_after <= 0 then
        -- ██ 0336 THE TERMINAL ARM IS CONFINED, AND THE ENCOUNTER STILL CONCLUDES ██
        -- fleet_destroy and presence_complete both RAISE on a status mismatch (fleet_destroy: not in a
        -- destroyable state; presence_complete: presence not in an active state). Neither was guarded
        -- here, and both run BEFORE this arm's own status write — so a mismatch rolled the whole tick
        -- back INCLUDING last_resolved_at, and the encounter retried, identically, every tick, forever
        -- and silently (the 0206 per-row guard downgrades the raise to a warning and the cron keeps
        -- returning normally). That is the wedge send_ship_group_hunt already names in prose.
        -- ONE LEAF, FOUR ARMS: combat_encounter_release confines each call in its own subtransaction
        -- so one failure cannot skip the other, re-raises query_canceled exactly as the outer guard
        -- does, and returns normally — which is what lets the status write below LAND. A mismatch now
        -- CONCLUDES the encounter with a warning instead of wedging it.
        -- ORDER IS IMMATERIAL, CHECKED: fleet_destroy writes fleets, presence_complete writes
        -- location_presence (+ the worldstate cache), mainship_mark_combat_destroyed writes
        -- main_ship_instances. No two of the three read what another writes, so folding the pair into
        -- one call at the head of the arm changes no outcome.
        -- AND THE RETREAT TARGET IS ALWAYS CONSUMED: only the settle arm ever cleared
        -- fleets.retreat_target_*, while its own header states the invariant that the recording is
        -- ALWAYS consumed. A fleet that died, or was wiped mid-fight, kept a stale destination that
        -- the NEXT sortie's settle would then fly to. One leaf, called by all four arms.
        perform public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true);
        perform public.fleet_consume_retreat_target(e.fleet_id);
        for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
          perform mainship_mark_combat_destroyed(cu.main_ship_id);
        end loop;$h17n$),
    (18, 'combat_create_group_encounter',
     $h18o$            v_pos_x := v_loc_x + v_ring_radius * cos(2 * pi() * v_escort_idx / 8);
            v_pos_y := v_loc_y + v_ring_radius * sin(2 * pi() * v_escort_idx / 8);$h18o$,
     $h18n$            -- 0336: the escort ring now composes combat_formation_point, the ONE authority for
            -- "where does slot k of a formation ring sit". The tick spawns enemy waves through the
            -- same leaf, so the two formations can never drift apart. At phase 0 and slots 0..7 the
            -- leaf evaluates to this line's own expression, so no existing fleet moves; slots 8 and
            -- beyond, which used to WRAP onto an occupied slot, now step out to a wider ring.
            select fp.x, fp.y into v_pos_x, v_pos_y
              from public.combat_formation_point(v_loc_x, v_loc_y, v_ring_radius, v_escort_idx, 0) fp;$h18n$)
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0336 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0336 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0336 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0336 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 18 then
    raise exception '0336 REWRITE FAIL: rewrote % site(s), expected 18', v_done;
  end if;
end $rewrite$;

-- ── 4. SELF-ASSERTS — one DO block per check; every prosrc probe strips comments first ───────────

-- (a) the four leaves exist, with the right volatility/security, and NO client can execute them
do $a$
declare r record; v_n integer := 0;
begin
  for r in
    select * from (values
      ('combat_formation_point',       'i', false),
      ('combat_acquire_target',        's', false),
      ('fleet_consume_retreat_target', 'v', true),
      ('combat_encounter_release',     'v', true)
    ) as t(fname, vol, secdef)
  loop
    if to_regproc('public.' || r.fname) is null then
      raise exception '0336 ASSERT (a) FAIL: leaf public.% was not created', r.fname;
    end if;
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = r.fname
                      and p.provolatile = r.vol and p.prosecdef = r.secdef
                      and coalesce(array_to_string(p.proconfig, ','), '') = 'search_path=public') then
      raise exception '0336 ASSERT (a) FAIL: leaf public.% has the wrong volatility / security / search_path posture', r.fname;
    end if;
    if has_function_privilege('anon', (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                        where n.nspname = 'public' and p.proname = r.fname), 'EXECUTE')
       or has_function_privilege('authenticated', (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                        where n.nspname = 'public' and p.proname = r.fname), 'EXECUTE') then
      raise exception '0336 ASSERT (a) FAIL: leaf public.% is EXECUTE-able by a client role — these are engine internals, not a new surface', r.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 4 then
    raise exception '0336 ASSERT (a) FAIL: checked % leaf/leaves, expected 4', v_n;
  end if;
end $a$;

-- (b) ONE targeting authority: the tick's own CTE is GONE and both acquisitions compose the leaf
do $b$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('with candidates as (' in v_code) > 0 or position('tier as (select min(aggro_priority)' in v_code) > 0 then
    raise exception '0336 ASSERT (b) FAIL: the tick still carries its own targeting CTE — that is the second authority this slice exists to remove';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side)', '')))
         / length('public.combat_acquire_target(v_units, v_ur.pos_x, v_ur.pos_y, v_ur.side)');
  if v_n <> 2 then
    raise exception '0336 ASSERT (b) FAIL: % composition(s) of the targeting leaf (want exactly 2: first acquisition and the per-weapon re-acquisition)', v_n;
  end if;
  -- the leaf really is the head's CTE, not a rewrite of it
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_acquire_target';
  if position('order by c.dist asc, c.id asc' in v_code) = 0
     or position('where tier.m is null or c.aggro_priority = tier.m' in v_code) = 0
     or position('where x.side is distinct from p_my_side' in v_code) = 0
     or position('public.osn_distance(p_my_x, p_my_y, x.pos_x, x.pos_y)' in v_code) = 0 then
    raise exception '0336 ASSERT (b) FAIL: the targeting leaf is not the head CTE lifted whole (a screen, an ordering or the distance call is missing)';
  end if;
end $b$;

-- (c) ONE liveness predicate, and the volley re-acquires
do $c$
declare v_tick text; v_leaf text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_tick
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_leaf
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_acquire_target';
  if position('cu3.alive_count > 0' in v_tick) = 0 then
    raise exception '0336 ASSERT (c) FAIL: the per-weapon re-acquisition does not test the target''s liveness';
  end if;
  if position('if v_target_id is null then
                exit;' in v_tick) = 0 then
    raise exception '0336 ASSERT (c) FAIL: the volley does not END when nothing is left alive to shoot';
  end if;
  if position('cu.alive_count > 0' in v_leaf) = 0 then
    raise exception '0336 ASSERT (c) FAIL: the targeting leaf does not filter on liveness — a corpse would still absorb a whole volley';
  end if;
  -- ONE SPELLING, still. No second way to ask "is this unit alive".
  if position('is_destroyed' in v_tick) > 0 or position('alive_count <= 0' in v_tick) > 0
     or position('alive_count = 0' in v_tick) > 0 or position('alive_count <= 0' in v_leaf) > 0 then
    raise exception '0336 ASSERT (c) FAIL: a second spelling of "is this unit alive" is in the engine — one authority, one predicate';
  end if;
  -- the 0317 actor guard is untouched, and the target re-read still stands
  v_n := (length(v_tick) - length(replace(v_tick, 'perform 1 from combat_units where id = v_ur.id and alive_count > 0;', '')))
         / length('perform 1 from combat_units where id = v_ur.id and alive_count > 0;');
  if v_n <> 1 then
    raise exception '0336 ASSERT (c) FAIL: % actor-liveness guard(s) (0317''s must survive, exactly once)', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'from combat_units where id = v_target_id and alive_count > 0;', '')))
         / length('from combat_units where id = v_target_id and alive_count > 0;');
  if v_n <> 1 then
    raise exception '0336 ASSERT (c) FAIL: % target-liveness re-read(s) at the damage step (want exactly 1)', v_n;
  end if;
end $c$;

-- (d) the wave spawns through the formation leaf, on BOTH arms, and no enemy insert carries the anchor
do $d$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring_radius + v_enemy_range + 1, v_spawn_slot, 0.5)', '')))
         / length('public.combat_formation_point(v_anchor_x, v_anchor_y, v_ring_radius + v_enemy_range + 1, v_spawn_slot, 0.5)');
  if v_n <> 2 then
    raise exception '0336 ASSERT (d) FAIL: % spawn arm(s) place their wave through the formation leaf (want exactly 2: the resolved arm and the synthetic arm)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'v_enemy_unit_hp, v_enemy_unit_hp, v_slot_x, v_slot_y, v_enemy_speed,', '')))
         / length('v_enemy_unit_hp, v_enemy_unit_hp, v_slot_x, v_slot_y, v_enemy_speed,');
  if v_n <> 2 then
    raise exception '0336 ASSERT (d) FAIL: % enemy insert(s) take the ring point (want exactly 2)', v_n;
  end if;
  if position('v_enemy_unit_hp, v_enemy_unit_hp, v_anchor_x, v_anchor_y, v_enemy_speed,' in v_code) > 0 then
    raise exception '0336 ASSERT (d) FAIL: an enemy insert still spawns AT the anchor — the whole wave would sit on one point again';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'v_spawn_slot := v_spawn_slot + 1;', '')))
         / length('v_spawn_slot := v_spawn_slot + 1;');
  if v_n <> 2 then
    raise exception '0336 ASSERT (d) FAIL: % slot advance(s) (want exactly 2 — a spawn arm that never advances puts the whole wave back on one point)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'v_spawn_slot := 0;', ''))) / length('v_spawn_slot := 0;');
  if v_n <> 2 then
    raise exception '0336 ASSERT (d) FAIL: % slot initialisation(s) (want exactly 2, one per spawn arm)', v_n;
  end if;
  -- and the creator's escort ring composes the SAME leaf
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if position('public.combat_formation_point(v_loc_x, v_loc_y, v_ring_radius, v_escort_idx, 0)' in v_code) = 0 then
    raise exception '0336 ASSERT (d) FAIL: the encounter creator does not compose the formation leaf — the ring formula would exist twice';
  end if;
  if position('v_ring_radius * cos(2 * pi() * v_escort_idx / 8)' in v_code) > 0 then
    raise exception '0336 ASSERT (d) FAIL: the creator still inlines the ring formula — that is the second authority this slice removes';
  end if;
end $d$;

-- (e) a retreating encounter cannot reach the spawn; the loop order is pinned; the kite is capped
do $e$
declare v_code text; v_n integer; v_spawn integer; v_guard integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  v_guard := position('if e.status = ''retreating'' then
          v_enemy_hp := e.enemy_integrity_max;
        elsif e.next_wave_at is not null and now() < e.next_wave_at then' in v_code);
  if v_guard = 0 then
    raise exception '0336 ASSERT (e) FAIL: the retreat guard is not the FIRST branch of the wave-spawn decision — a retreating fleet could still be sent a fresh wave';
  end if;
  -- Located by each spawn arm's OWN insert row rather than by the lines around it: this slice
  -- inserts the slot counter and the formation-point read between the delete and the loop, so a
  -- locator built from adjacency would be invalidated by the very change it is checking.
  v_spawn := position('e.id, e.player_id, ''pirate_synthetic'', ''enemy'', v_enemy_unit_hp, 1, 1,' in v_code);
  if v_spawn = 0 or v_guard >= v_spawn then
    raise exception '0336 ASSERT (e) FAIL: the retreat guard does not precede the SYNTHETIC spawn (% vs %) — a retreating fleet could still be sent a fresh wave', v_guard, v_spawn;
  end if;
  v_spawn := position('e.id, e.player_id, v_weapon->>''unit_type_id'', ''enemy'', v_enemy_unit_hp, 1, 1,' in v_code);
  if v_spawn = 0 or v_guard >= v_spawn then
    raise exception '0336 ASSERT (e) FAIL: the retreat guard does not precede the RESOLVED spawn (% vs %) — an authored wave could still be spawned on a retreating fleet', v_guard, v_spawn;
  end if;
  -- the loop order is no longer heap order
  if position('''main_ship_id'', cu2.main_ship_id) order by cu2.id), ''[]''::jsonb)' in v_code) = 0 then
    raise exception '0336 ASSERT (e) FAIL: the population freeze has no ORDER BY — who fires first would still be heap order, and every determinism harness over this tick would be unsound';
  end if;
  -- the kite is capped by the SHORTEST gun, and the target is still measured by its LONGEST
  if position('coalesce(v_ur.my_min_range, v_ur.my_range, 0), coalesce(v_ur.move_speed,0),' in v_code) = 0 then
    raise exception '0336 ASSERT (e) FAIL: the mover is not capped by the shortest gun — a longer gun would still disable a shorter one';
  end if;
  if position('coalesce(v_target_range,0));' in v_code) = 0 then
    raise exception '0336 ASSERT (e) FAIL: the target''s reach is no longer passed to the mover';
  end if;
  -- THE SHORTEST GUN MUST TRAVEL THE WHOLE WAY — three sites in the tick, and no more: the freeze
  -- KEY that computes it, the actor loop's recordset COLUMN so it survives jsonb_to_recordset, and
  -- the MOVER ARGUMENT that consumes it. Counted on comment-stripped text. The targeting CTE's own
  -- column list is deliberately NOT a fourth site: it moved into combat_acquire_target, which is
  -- checked separately just below. A value computed and never read IS this defect's shape, so both
  -- ends are pinned rather than only the count.
  v_n := (length(v_code) - length(replace(v_code, 'my_min_range', ''))) / length('my_min_range');
  if v_n <> 3 then
    raise exception '0336 ASSERT (e) FAIL: my_min_range appears % time(s) in the tick (want 3: the freeze key, the actor recordset column it must survive, and the mover argument)', v_n;
  end if;
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_acquire_target';
  if position('my_min_range double precision' in v_code) = 0 then
    raise exception '0336 ASSERT (e) FAIL: the targeting leaf''s recordset list does not name my_min_range — the leaf and the frozen snapshot would disagree about the record shape';
  end if;
end $e$;

-- (f) all four terminal arms are confined, and all four consume the retreat target
do $f$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('perform fleet_destroy(e.fleet_id);' in v_code) > 0
     or position('perform presence_complete(e.presence_id);' in v_code) > 0 then
    raise exception '0336 ASSERT (f) FAIL: an UNCONFINED fleet_destroy / presence_complete survives in the tick — that arm can still wedge an encounter forever';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_release(e.id, e.fleet_id, e.presence_id,', '')))
         / length('public.combat_encounter_release(e.id, e.fleet_id, e.presence_id,');
  if v_n <> 4 then
    raise exception '0336 ASSERT (f) FAIL: % terminal arm(s) release through the confined leaf (want exactly 4: entry-defeat, settle, spatial death, aggregate death)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true)', '')))
         / length('public.combat_encounter_release(e.id, e.fleet_id, e.presence_id, true)');
  if v_n <> 3 then
    raise exception '0336 ASSERT (f) FAIL: % arm(s) destroy the fleet (want exactly 3 — the settle arm must NOT, a fleet that is leaving is not a wreck)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.fleet_consume_retreat_target(e.fleet_id)', '')))
         / length('public.fleet_consume_retreat_target(e.fleet_id)');
  if v_n <> 4 then
    raise exception '0336 ASSERT (f) FAIL: % arm(s) consume the retreat target (want exactly 4 — a leaked recording is flown by the NEXT sortie)', v_n;
  end if;
  if position('update fleets set retreat_target_location_id = null' in v_code) > 0 then
    raise exception '0336 ASSERT (f) FAIL: the tick still clears the retreat target inline — that is the second clearer this slice removes';
  end if;
  -- the leaf really confines, and really re-raises a cancellation
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_encounter_release';
  v_n := (length(v_code) - length(replace(v_code, 'when query_canceled then raise;', '')))
         / length('when query_canceled then raise;');
  if v_n <> 2 then
    raise exception '0336 ASSERT (f) FAIL: the release leaf carries % query_canceled re-raise(s) (want 2, one per confined call — a cancellation must kill the run, never be eaten)', v_n;
  end if;
end $f$;

-- (g) THE HALF OF THE RANGE INVARIANT THAT GEOMETRY CANNOT ESTABLISH, over every live location
--
-- A fight needs two things, and only one of them is a shape.
--   (A) THE WAVE MUST START OUTSIDE ITS OWN REACH, or it kites from tick zero and settles at
--       (its range - the player's closing speed), which for a high-difficulty site is beyond the
--       player's own gun: the pirate fires every tick and the player never fires at all. That is a
--       firing squad, not a fight, and production's highest-difficulty site was exactly it.
--       ⟶ (A) IS NOW STRUCTURAL. The wave spawns at v_ring_radius + its own range + 1, and every
--       player ship sits at radius <= v_ring_radius, so the minimum distance from ANY player ship
--       to ANY enemy is that range + 1. It cannot be violated by a knob, so there is nothing here
--       to assert about it; assert (d) pins the EXPRESSION instead, which is the real guarantee.
--   (B) WHEN THE CLOSING WAVE STOPS CLOSING, IT MUST BE INSIDE THE PLAYER'S RANGE. This one is NOT
--       a shape and no spawn point can fix it. The mover stops closing at its own range, so the
--       wave comes to rest somewhere in (its_range - its_speed, its_range]. If the whole of that
--       interval is beyond the player's gun, the player still never fires — the standoff returns
--       with a longer approach. It is avoided when either
--            enemy_range(D) <= player_min_range        (the wave must come inside to shoot at all)
--         or enemy_speed(D)  >  enemy_range(D) - player_min_range   (its last step overshoots past
--                                                                    the player's range edge)
--       PLAYER_MIN_RANGE IS THE WORST GUN IN THE GAME, derived: the synthesized fallback and every
--       catalog firing weapon. The weakest-armed hull is the one that decides whether a site is
--       playable, so the invariant is stated over it rather than over a hull anyone happens to fly.
--
-- Checked over EVERY location with a positive base_difficulty, hidden ones included — a hidden site
-- is a site that has not been released YET, and releasing one must never be how this is discovered.
do $g$
declare r record; v_rp double precision; v_n integer := 0;
begin
  select least(coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 'Infinity'::double precision),
               coalesce((select min(t.range) from public.module_types t
                          where public.module_is_firing_weapon(t)), 'Infinity'::double precision))
    into v_rp;
  -- NON-VACUITY: with no derivable player weapon range every comparison below would be against
  -- Infinity and would pass unconditionally. Absence is failure, not a pass.
  if v_rp is null or v_rp = 'Infinity'::double precision then
    raise exception '0336 ASSERT (g) FAIL: no player weapon range could be derived — combat_player_fallback_weapon_range is absent AND the catalog carries no firing weapon, so the invariant would be checked against nothing';
  end if;
  for r in
    select l.name, l.status, l.base_difficulty,
           coalesce(public.cfg_num('enemy_synthetic_range_base'), 120)
           + l.base_difficulty * coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 5) as enemy_range,
           coalesce(public.cfg_num('enemy_synthetic_speed_base'), 3)
           + l.base_difficulty * coalesce(public.cfg_num('enemy_synthetic_speed_per_difficulty'), 0.2) as enemy_speed
      from public.locations l
     where l.base_difficulty > 0
  loop
    v_n := v_n + 1;
    if not (r.enemy_range <= v_rp or r.enemy_speed > r.enemy_range - v_rp) then
      raise exception '0336 ASSERT (g) FAIL: % (%, base_difficulty %) is an UNWINNABLE STANDOFF. Its wave reaches % and closes % per tick, so it comes to rest between % and % — entirely beyond the weakest player gun, which reaches %. The wave fires every tick and the player never fires at all. Fix the NUMBERS, not the spawn point: lower enemy_synthetic_range_per_difficulty, raise enemy_synthetic_speed_per_difficulty, or give the player a longer basic weapon.',
        r.name, r.status, r.base_difficulty, r.enemy_range, r.enemy_speed,
        r.enemy_range - r.enemy_speed, r.enemy_range, v_rp;
    end if;
  end loop;
  -- NON-VACUITY: an empty location set would satisfy the loop above while proving nothing.
  if v_n = 0 then
    raise exception '0336 ASSERT (g) FAIL: no location carries a positive base_difficulty — the invariant was checked against an EMPTY set and proves nothing';
  end if;
  raise notice '0336 ASSERT (g) ok: at all % hunt-capable location(s), a closing wave comes to rest inside the weakest player gun (reach %)', v_n, v_rp;
end $g$;

-- (h) every carried-through invariant survives the re-emission
do $h$
declare v_code text; v_n integer; v_tok text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if position('fleet_get_power' in v_code) > 0 then
    raise exception '0336 ASSERT (h) FAIL: fleet_get_power is back in the tick (0299 reverted)';
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'public.combat_encounter_side_power(e.id, ''player'')', '')))
         / length('public.combat_encounter_side_power(e.id, ''player'')');
  if v_n <> 2 then
    raise exception '0336 ASSERT (h) FAIL: % of 2 power writes read the 0299 authority', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'random(', ''))) / length('random(');
  if v_n <> 3 then
    raise exception '0336 ASSERT (h) FAIL: the tick carries % random( call(s) (want 3 — the elite-stat proof pins this count on every chain)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'movement_create(', ''))) / length('movement_create(');
  if v_n <> 2 then
    raise exception '0336 ASSERT (h) FAIL: the tick mints % movement leg(s) (want the head''s 2)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'jsonb_to_recordset(v_units)', ''))) / length('jsonb_to_recordset(v_units)');
  if v_n <> 1 then
    raise exception '0336 ASSERT (h) FAIL: % read(s) of the frozen snapshot inside the tick (want 1 — the actor loop; targeting''s read moved into the leaf)', v_n;
  end if;
  v_n := (length(v_code) - length(replace(v_code, 'into v_units', ''))) / length('into v_units');
  if v_n <> 1 then
    raise exception '0336 ASSERT (h) FAIL: the tick builds the population snapshot % time(s) (want exactly 1 — re-freezing would destroy the simultaneity the freeze exists for)', v_n;
  end if;
  foreach v_tok in array array[
      'v_hit_roll double precision := greatest(0, (1 - v_hit_var_pct) + random() * (2 * v_hit_var_pct));',
      'v_dmg := v_w_power * v_hit_roll;',
      'now() + make_interval(secs => coalesce((v_weapon->>''cooldown_seconds'')::double precision, 0))',
      'v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)',
      'v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null',
      'if v_w_range is not null and v_target_dist <= v_w_range',
      'and (v_w_next_ready is null or now() >= v_w_next_ready) then',
      'jsonb_array_length(v_weapons_json) - 1',
      'select sum(msi.max_hp) into v_ae_cap',
      'presence_request_leave(e.presence_id)',
      'v_enemy_count  := least(coalesce(cfg_num(''enemy_synthetic_max_units''),6)::integer, greatest(1, v_danger));',
      '''module_type_id'', ''pirate_synthetic_weapon'', ''range'', v_enemy_range,',
      'v_reward_metal := round(coalesce(cfg_num(''reward_metal_base''),10) * greatest(loc.reward_tier,1)',
      'coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0)',
      'v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;',
      'v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);'
    ] loop
    if position(v_tok in v_code) = 0 then
      raise exception '0336 ASSERT (h) FAIL: the tick lost a pinned head guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
  -- the encounter creator kept everything this slice does not touch
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  foreach v_tok in array array[
      'v_is_lead := m.main_ship_id is not distinct from v_lead_ship_id;',
      'v_aggro_priority := case when v_is_lead then 100 else 0 end;',
      'public.module_is_firing_weapon(t)',
      'v_weight_total',
      'v_ring_radius := coalesce(public.cfg_num(''spatial_formation_ring_radius''), 30)'
    ] loop
    if position(v_tok in v_code) = 0 then
      raise exception '0336 ASSERT (h) FAIL: the encounter creator lost a pinned guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;
end $h$;

-- (i) metadata parity: the two rewritten functions changed body and NOTHING else
do $i$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0336_before loop
    select md5(p.prosrc) as body_md5, pg_get_userbyid(p.proowner) as owner, p.prosecdef as secdef,
           p.provolatile as volatility, p.proparallel as parallel,
           coalesce(array_to_string(p.proconfig, ','), '') as proconfig,
           pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as result,
           coalesce(p.proacl::text, '') as acl
      into a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = b.fname;
    if a.owner is distinct from b.owner or a.secdef is distinct from b.secdef
       or a.volatility is distinct from b.volatility or a.parallel is distinct from b.parallel
       or a.proconfig is distinct from b.proconfig or a.args is distinct from b.args
       or a.result is distinct from b.result or a.acl is distinct from b.acl then
      raise exception '0336 ASSERT (i) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0336 ASSERT (i) FAIL: public.% body is byte-identical — its hunks did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 2 then
    raise exception '0336 ASSERT (i) FAIL: parity-checked % function(s), expected 2', v_n;
  end if;
  raise notice '0336 SELF-ASSERT PASS: every gun in a volley re-aims; a wave stands on a ring outside its own reach; a retreating fleet is never sent a fresh wave; all four terminal arms are confined and all four consume the retreat target; the firing order is stable; and no ship holds at a range that silences its own shorter gun';
end $i$;

commit;
