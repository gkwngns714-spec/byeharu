-- Byeharu — THE FLEET NO LONGER TELEPORTS INTO A ZONE. The ambush happens WHERE the leg first
-- enters the zone and WHEN the fleet gets there.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT WAS ACTUALLY WRONG (verified at file:line, not assumed)
--
--   1. WRONG POINT. pirate_intercept_leg_zone_hits (0233:318-319) computed the ambush point as
--      ST_ClosestPoint(leg, ST_Centroid(zone)) — the perpendicular foot from the zone CENTRE onto the
--      leg. Every seeded zone is a circle centred on its location (0233:215-221), so for a leg aimed
--      at that location the foot resolves at or beside the location marker. The "ambush point" was a
--      restatement of the destination, which is exactly what the teleport looked like.
--
--   2. WRONG TIME. command_ship_group_go minted a real timed leg (0292:657-663) and then, in the SAME
--      transaction (0292:670), called pirate_intercept_evaluate_leg, which cancelled that leg
--      (0294:1322) and called fleet_set_in_space (0294:1362). The fleet never travelled. With the
--      0236 knobs (base 1.0 / min 0.98) every crossing rolled a hit.
--
--   3. TWO WRITERS OF ONE POINT. combat_create_group_encounter (0293:198) took p_engagement_x/y and
--      shipped a COMMENT (0293:413-420) calling itself the authority — while having ZERO callers that
--      passed them; then 0294:1415-1418 restamped engagement_x/y and 0294:1444-1450 translated
--      combat_units.pos_x/pos_y microseconds later. Three places decided one coordinate.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS MIGRATION DOES — ONE SLICE, NO FLAG, THE OLD PATH DELETED
--
-- There is deliberately NO new feature flag. Dark code the owner cannot see is not verifiable, and a
-- flag would mean two live ambush paths at once — the spaghetti the standing law forbids. So the
-- legacy immediate-ambush path DIES HERE: pirate_intercept_evaluate_leg is DROPPED, no order-time
-- cancel/park/combat survives anywhere, and the deprecated `intercepted` / `intercept_encounter_id`
-- envelope fields are REMOVED rather than kept as shims.
--
--   GEOMETRY   pirate_intercept_leg_entry — a NEW pure, table-free geometry leaf: the first TRUE
--              INTERIOR entry of a leg into a zone. It partitions the leg by every boundary-touch
--              fraction and takes the first span whose MIDPOINT is strictly contained, so a leg that
--              runs ALONG a boundary before entering resolves at the LATER, real entry, a tangent is
--              NOT an entry, an origin already inside is fraction 0, and a hole is not "inside".
--              pirate_intercept_leg_zone_hits now COMPOSES that leaf: ambush_x/ambush_y keep their
--              names and their meaning ("where the ambush happens") and finally carry the right
--              value; entry_fraction is the one new output column.
--
--   TIMING     pirate_intercept_plan_leg  — rolls at ORDER time, writes a PENDING row, cancels
--                                            nothing, moves nothing, creates no combat.
--              pirate_intercept_resolve_due_for_movement — the ONLY thing that turns pending into
--                                            combat, and only once the fleet has actually got there.
--
--   ONE DOOR   movement_advance — the ONE pre-settlement dispatcher. It resolves a due intercept
--              FIRST and only then settles an arrival. EVERY movement-settling consumer now goes
--              through it: process_fleet_movements (both its new due-intercept scan and its arrival
--              scan) and command_main_ship_settle_arrival_legacy. movement_settle_arrival keeps its
--              body byte-for-byte and simply stops being called directly.
--
--   THE POINT  combat_create_group_encounter's p_engagement_x/p_engagement_y are now MANDATORY (the
--              defaults are dropped, which is why the function is dropped and re-created). Its ONE
--              caller, combat_create_encounter, resolves the point explicitly and passes it. The
--              restamp and the unit translation are DELETED with the evaluator that held them.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT A PLAYER EXPERIENCES AT DEPLOY TIME — stated plainly, because this ships LIT
--
--   • A fleet ALREADY IN FLIGHT right now: nothing happens to it. No pirate_intercepts row existed in
--     the 'pending' state before this migration (the state is created here), so its leg carries no
--     planned ambush and simply ARRIVES as it would have. It is not ambushed by the deploy, and it is
--     not stranded: process_fleet_movements' arrival scan is unchanged in predicate and effect.
--
--   • A fleet ALREADY AMBUSHED and in combat: untouched. This migration deletes CODE, not rows. The
--     encounter, its engagement_x/engagement_y (whatever 0293/0294 stamped) and its already-translated
--     combat_units all stay exactly as they are; process_combat_ticks is NOT re-created here, so the
--     fight continues and retreat still works.
--
--   • The FIRST NEW order after deploy: the fleet actually travels. If its leg crosses an active
--     danger zone and the roll hits, the ambush fires when the fleet reaches the zone's edge — the
--     fleet is placed AT that edge and combat opens there. Resolution rides the existing 30-second
--     process-fleet-movements cron (0011), which this migration does NOT reschedule, so an ambush
--     fires at the first tick at or after its trigger time: up to 30s late, and the fleet is then
--     placed back at the recorded entry point rather than wherever it had drifted to. That step back
--     is bounded by 30 seconds of travel and is the honest position — it is where the fleet met the
--     zone.
--
--   • The RPC envelope changes. command_ship_group_go no longer returns `intercepted` or
--     `intercept_encounter_id` (it cannot know: the roll's outcome is in the future). It returns
--     `order_outcome` = 'movement_started' | 'retreat_started' | 'retreat_destination_updated'.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- PROVENANCE — every re-emitted body names its source and enumerates its deltas.
--
--   pirate_intercept_leg_zone_hits   FROM 0233:292-323.  DROP+CREATE (return type gains a column).
--   combat_create_group_encounter    FROM 0293:198-405.  DROP+CREATE (defaults cannot be removed by
--                                    CREATE OR REPLACE). ONLY delta: `default null` removed from the
--                                    two engagement params. The 0291-pinned creation-time
--                                    v_spatial_enabled, the 0234 ring formation, the 0262 fallback
--                                    weapon, [B2]'s single anchor resolution and [B3]'s INSERT append
--                                    are byte-identical.
--   combat_create_encounter          FROM 0168:481-528.  ONLY delta: the group branch resolves the
--                                    engagement point and passes it. The legacy branch is untouched.
--   process_fleet_movements          FROM 0206:65-103.   Deltas: a NEW due-intercept scan placed
--                                    BEFORE the arrival scan, and the arrival loop body calls
--                                    movement_advance instead of movement_settle_arrival. The 0206
--                                    CRON-GUARD subtransaction, the arrival predicate, the FOR UPDATE
--                                    SKIP LOCKED and the uncounted-failure posture all survive.
--   command_main_ship_settle_arrival_legacy  FROM 0151:126-210. ONLY delta: movement_advance.
--   command_ship_group_go            FROM 0298:220-760 (NOT 0292 — 0298 re-created it to widen the
--                                    retreat destination to a coordinate; splicing from 0292 would
--                                    have reverted that). Deltas: plan instead of evaluate; a due-
--                                    intercept resolution inside the redirect branch (a re-order may
--                                    not outrun an ambush that is already owed); pending rows
--                                    cancelled on a legitimate re-order; the new envelope. Steps 1-8
--                                    including the whole 0292 retreat hunk are verbatim.
--   command_ship_group_stop          FROM 0218:635-776.  Deltas: the same due-intercept resolution
--                                    and pending-cancel, after the movement lock. The 0215 sortie
--                                    guard and the S3 fold are verbatim.
--   command_ship_group_go_route      FROM 0233:1011-1115. ONLY delta: the dead `intercepted` branch is
--                                    deleted (leg 1 can no longer be intercepted at order time).
--   process_pirate_route_legs        FROM 0233:1128-1222. ONLY delta: plan instead of evaluate.
--
--   NOT RE-EMITTED, ON PURPOSE: process_combat_ticks — its head is now 20260618000299:272 (0298
--   re-created it for the coordinate retreat destination, 0299 again for combat_encounter_side_power);
--   this slice adds no consumer of it, and re-emitting ~1000 lines would risk 0291's sticky-mode
--   guard a fourth time and 0298/0299's work a first. Verified absent: this file contains no
--   `create or replace function public.process_combat_ticks`. Also not re-emitted: movement_settle_arrival
--   (0208:90 — byte-untouched; it simply stops being called directly), presence_create (0032:175),
--   activity_start (0230:98), typed_zone_pirate_candidates_v1 (0275:80 — it selects ambush_x/ambush_y
--   by name and those names and meanings are preserved), fleet_set_in_space (0231:1146).
--
-- Forward-only: 0001-0300 unedited. No game_config key is written, no flag is flipped, no balance
-- number changes.


-- ── 0. PRECONDITIONS — every base this migration copies from or deletes must actually be there ──────
do $pre$
begin
  if to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is null then
    raise exception '0301: pirate_intercept_evaluate_leg(uuid) is missing — the path this migration retires is not deployed';
  end if;
  if to_regprocedure('public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision)') is null then
    raise exception '0301: pirate_intercept_leg_zone_hits is missing — there is no geometry leaf to correct';
  end if;
  if to_regprocedure('public.combat_create_group_encounter(uuid, double precision, double precision)') is null then
    raise exception '0301: combat_create_group_encounter(uuid, double precision, double precision) is missing — 0293 must be deployed';
  end if;
  if to_regprocedure('public.movement_settle_arrival(uuid)') is null
     or to_regprocedure('public.process_fleet_movements()') is null then
    raise exception '0301: the movement processor / settle leaf is missing — there is nothing to route through the dispatcher';
  end if;
  -- The bases we copy must be the ones we think they are. These probes read CODE, and the deployed
  -- bodies carry no comment containing these strings.
  if position('if v_manifest = 0 then' in
              (select prosrc from pg_proc where oid = 'public.pirate_intercept_evaluate_leg(uuid)'::regprocedure)) = 0 then
    raise exception '0301: the deployed evaluator does not carry 0290''s zero-manifest guard — refusing to inherit its blocks from an unknown base';
  end if;
  if position('v_spatial_enabled boolean := public.cfg_bool(''spatial_combat_enabled'')' in
              (select prosrc from pg_proc where oid = 'public.combat_create_group_encounter(uuid, double precision, double precision)'::regprocedure)) = 0 then
    raise exception '0301: the deployed encounter creator does not carry 0291''s creation-time sticky-mode read — refusing to re-emit from an unknown base';
  end if;
  if position('perform movement_settle_arrival(m.id)' in
              (select prosrc from pg_proc where oid = 'public.process_fleet_movements()'::regprocedure)) = 0 then
    raise exception '0301: the deployed movement processor is not 0206''s shared-helper form — refusing to re-emit from an unknown base';
  end if;
  -- 0298 IS A HARD BASE, not an optional predecessor. This migration re-emits command_ship_group_go
  -- SPLICED FROM 0298, so a chain without it would have this file silently REVERT
  -- retreat-to-any-destination (and emit a body writing columns that do not exist). The base moved
  -- under this slice once already; make the next move fail loudly at the door instead of quietly in
  -- the body. Both halves are checked — the schema 0298 added, and its actual code landing in the
  -- deployed mover.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets'
                    and column_name in ('retreat_target_x', 'retreat_target_y')
                  having count(*) = 2) then
    raise exception '0301: fleets.retreat_target_x/retreat_target_y are missing — 0298 (retreat to any destination) must be deployed; this migration re-emits command_ship_group_go from its body';
  end if;
  if position('retreat_target_x = case when p_location_id is null then v_t_x end' in
              (select prosrc from pg_proc where oid = 'public.command_ship_group_go(uuid, uuid, double precision, double precision)'::regprocedure)) = 0 then
    raise exception '0301: the deployed command_ship_group_go does not carry 0298''s coordinate retreat destination — refusing to re-emit from an unknown base';
  end if;
end $pre$;


-- ── 1. pirate_intercepts LEARNS A LIFECYCLE ─────────────────────────────────────────────────────────
-- The table already is the intercept audit trail (0233:224). It becomes the schedule as well, because
-- a second scheduling table would be a second source of truth about the same event. fleet_route_legs
-- is NOT reused for this (its sole-writer law, 0233:282-286, is about the waypoint queue and stays).
--
--   pending   — rolled and owed. The fleet has not reached the entry point yet.
--   fired     — resolved into combat at the recorded entry point. Terminal.
--   missed    — the roll failed for this zone. Terminal, and written even though nothing happens,
--               because the ABSENCE of a row is what proves a leg never crossed anything.
--   cancelled — owed, then rendered moot (the player stopped, re-ordered, the zone went inactive, the
--               movement ended). Terminal, and always carries a reason.
alter table public.pirate_intercepts
  add column if not exists lifecycle_state text,
  add column if not exists entry_fraction  double precision,
  add column if not exists entry_x         double precision,
  add column if not exists entry_y         double precision,
  add column if not exists trigger_at      timestamptz,
  add column if not exists resolved_at     timestamptz,
  add column if not exists cancelled_at    timestamptz,
  add column if not exists cancel_reason   text;

-- BACKFILL. Every historical row is TERMINAL by construction — the order-time evaluator either opened
-- combat in its own transaction or did not. hit=true rows are exactly the ones that opened it; the
-- rest (including the ones the evaluator flipped back to hit=false on a lost race) opened nothing.
-- No historical row can be 'pending', so the pending CHECK below cannot fail on existing data.
update public.pirate_intercepts
   set lifecycle_state = case when hit then 'fired' else 'missed' end
 where lifecycle_state is null;

alter table public.pirate_intercepts alter column lifecycle_state set not null;
-- Deliberately NO default: every writer names the state it is creating.

do $lc$
begin
  if not exists (select 1 from pg_constraint where conname = 'pirate_intercepts_lifecycle_state_check') then
    alter table public.pirate_intercepts
      add constraint pirate_intercepts_lifecycle_state_check
      check (lifecycle_state in ('pending', 'missed', 'fired', 'cancelled'));
  end if;
  -- A PENDING row is a promise the resolver must be able to keep: it needs a point to fire at, a
  -- fraction to compare the fleet's progress against, and a time. Terminal rows are unconstrained.
  if not exists (select 1 from pg_constraint where conname = 'pirate_intercepts_pending_is_actionable_check') then
    alter table public.pirate_intercepts
      add constraint pirate_intercepts_pending_is_actionable_check
      check (
        lifecycle_state <> 'pending'
        or (entry_x is not null and entry_y is not null
            and entry_fraction is not null and entry_fraction >= 0 and entry_fraction <= 1
            and trigger_at is not null and movement_id is not null)
      );
  end if;
end $lc$;

-- The due-scan index: the movement processor's new first loop reads exactly this shape.
create index if not exists pirate_intercepts_pending_due_idx
  on public.pirate_intercepts (trigger_at, movement_id)
  where lifecycle_state = 'pending';

-- ONE owed ambush per movement, enforced by the database rather than by the planner's good manners.
-- This is what makes "cancel every OTHER pending row after firing" structurally unnecessary, and what
-- makes two concurrent resolvers unable to create two encounters for one leg.
create unique index if not exists pirate_intercepts_one_pending_per_movement_uidx
  on public.pirate_intercepts (movement_id)
  where lifecycle_state = 'pending';

comment on table public.pirate_intercepts is
  'PIRATE INTERCEPT: one row per zone-crossing risk roll, and — since 0301 — the SCHEDULE for the '
  'ambushes those rolls owe. lifecycle_state pending|missed|fired|cancelled. A pending row carries the '
  'entry point and fraction it was accepted with and the trigger_at the fleet is expected to reach it; '
  'the resolver never recomputes that geometry from the current world. Writers: '
  'pirate_intercept_plan_leg (missed + pending), pirate_intercept_resolve_due_for_movement (fired), '
  'pirate_intercept_cancel_pending_for_movement (cancelled).';

comment on column public.pirate_intercepts.lifecycle_state is
  'PIRATE INTERCEPT (0301): pending (rolled, owed, the fleet has not reached the entry point yet) | '
  'missed (the roll failed for this zone) | fired (resolved into combat) | cancelled (owed then '
  'rendered moot — always with cancel_reason). Historical pre-0301 rows were backfilled fired/missed '
  'from hit, because the retired order-time evaluator left nothing owed.';
comment on column public.pirate_intercepts.entry_fraction is
  'PIRATE INTERCEPT (0301): where along the leg the zone was first truly ENTERED, in [0,1]. The '
  'resolver re-derives the fleet''s current fraction and refuses to fire before this one.';
comment on column public.pirate_intercepts.entry_x is
  'PIRATE INTERCEPT (0301): the x of the first true interior entry point, captured at ORDER time and '
  'never recomputed. The fleet is placed here when the ambush fires and the encounter is created here.';
comment on column public.pirate_intercepts.entry_y is
  'PIRATE INTERCEPT (0301): the y of the first true interior entry point. See entry_x.';
comment on column public.pirate_intercepts.trigger_at is
  'PIRATE INTERCEPT (0301): depart_at + (arrive_at - depart_at) * entry_fraction — when the fleet is '
  'expected to reach the entry point. The ambush fires at the first movement-processor tick at or '
  'after this, and never before it.';
comment on column public.pirate_intercepts.cancel_reason is
  'PIRATE INTERCEPT (0301): why an owed ambush was cancelled — player_stop | movement_superseded | '
  'zone_inactive | movement_not_moving | fleet_in_combat | fleet_changed.';


-- ── 2. pirate_intercept_leg_entry — THE GEOMETRY AUTHORITY (new, pure, table-free) ──────────────────
-- WHERE does a leg first get INSIDE a zone? Not "the minimum boundary intersection": a leg can run
-- ALONG a boundary for a while, touching it at many fractions, without ever being inside. The only
-- answer that is right in every case is to partition the leg at every boundary-touch fraction and take
-- the FIRST resulting span whose MIDPOINT is strictly contained.
--
-- That single rule produces every required behaviour without a special case for any of them:
--   origin strictly inside           -> 0.0 is in the fraction set, span [0, first exit] is contained
--   the whole leg inside             -> the only span is [0,1], contained
--   origin ON the boundary, inward   -> the 0.0 touch dedups with the leg start; the span is contained
--   origin ON the boundary, outward  -> the span's midpoint is outside -> NO HIT
--   tangent                          -> touching is not entering; no span is contained -> NO HIT
--   running along the boundary first -> that span's midpoint is ON the boundary, and ST_Contains
--                                       excludes the boundary -> the LATER, true entry wins
--   MultiPolygon                     -> the first entered COMPONENT wins, for free
--   a polygon with a HOLE            -> the hole's ring is part of ST_Boundary and a midpoint inside
--                                       the hole is not contained -> the hole is not "inside"
--
-- PURE AND TABLE-FREE ON PURPOSE: this is the leaf the migration's own self-assert exercises with
-- literal geometry, on an EMPTY database, so the rules above are proven at apply time rather than
-- asserted in prose.
--
-- FAIL CLOSED, NEVER OPEN. A leg that is not a single LINESTRING (NULL, a MULTILINESTRING, a point) is
-- NOT silently reinterpreted — it yields no rows. A zone with no areal part after repair yields no
-- rows. In this function "no rows" means "this leg does not enter this zone", which is the safe answer.
create or replace function public.pirate_intercept_leg_entry(
  p_leg  geometry,
  p_zone geometry
)
returns table (
  entry_x        double precision,
  entry_y        double precision,
  entry_fraction double precision
)
language sql
immutable
set search_path = public
as $$
  with leg as (
    select case when ST_GeometryType(p_leg) = 'ST_LineString' then p_leg end as g
  ),
  vz as (
    -- The zone as VALID POLYGONAL geometry: self-intersections repaired (ST_MakeValid), non-areal
    -- fragments discarded (ST_CollectionExtract ... 3), overlapping parts merged (ST_UnaryUnion).
    -- Without this, ST_Contains on a self-intersecting owner-drawn polygon is undefined.
    select ST_UnaryUnion(ST_CollectionExtract(ST_MakeValid(p_zone), 3)) as g
  ),
  fr as (
    -- every fraction at which the leg touches the boundary, plus the leg's own two ends.
    -- UNION (not UNION ALL) so a repeated touch collapses to one partition point.
    select 0.0::double precision as f from leg where ST_Length(leg.g) > 0
    union
    select 1.0::double precision from leg where ST_Length(leg.g) > 0
    union
    select ST_LineLocatePoint(leg.g, d.geom)
      from leg, vz, ST_DumpPoints(ST_Intersection(ST_Boundary(vz.g), leg.g)) d
     where ST_Length(leg.g) > 0
  ),
  spans as (
    select fr.f as f0, lead(fr.f) over (order by fr.f) as f1 from fr
  )
  select ST_X(u.pt), ST_Y(u.pt), u.f
    from (
      -- (i) DEGENERATE LEG (origin = target). There is no span to partition; the entry is the point
      --     itself, and only when that point is strictly inside.
      select 0.0::double precision as f, ST_StartPoint(leg.g) as pt
        from leg, vz
       where ST_Length(leg.g) = 0
         and ST_Contains(vz.g, ST_StartPoint(leg.g))
      union all
      -- (ii) the FIRST span that is genuinely interior.
      select s.f0, ST_LineInterpolatePoint(leg.g, s.f0)
        from spans s, leg, vz
       where s.f1 is not null
         and s.f1 > s.f0
         and ST_Contains(vz.g, ST_LineInterpolatePoint(leg.g, (s.f0 + s.f1) / 2.0))
    ) u
   order by u.f
   limit 1
$$;

revoke execute on function public.pirate_intercept_leg_entry(geometry, geometry) from public, anon, authenticated;
grant  execute on function public.pirate_intercept_leg_entry(geometry, geometry) to service_role;

comment on function public.pirate_intercept_leg_entry(geometry, geometry) is
  'PIRATE INTERCEPT (0301): THE geometry authority — the first TRUE INTERIOR entry of a leg into a '
  'zone, as (x, y, fraction). Partitions the leg at every boundary touch and takes the first span '
  'whose midpoint is strictly contained, so touching a boundary is not entering it and running along '
  'one is not either. Returns NO ROWS for a tangent, for a leg that never gets inside, for a non-'
  'LINESTRING leg and for a zone with no areal part — "no rows" is always the fail-closed answer. '
  'Pure and table-free so it can be proven with literal geometry on an empty database.';


-- ── 3. pirate_intercept_leg_zone_hits — 0233:292-323 with the WRONG POINT REPLACED ─────────────────
-- DROP+CREATE because the return type gains entry_fraction; CREATE OR REPLACE cannot widen it.
--
-- ambush_x / ambush_y KEEP THEIR NAMES AND THEIR MEANING — "the point where the ambush happens" — and
-- finally carry the right value. Renaming them would fork the typed-zone dispatch contract, which two
-- IMMUTABLE dispatcher versions (0274, 0279) validate by those exact keys and which the client mirrors
-- in src/features/worldeditor/zoneEffectDispatchContract.ts. One name, one meaning, one correct value
-- is the anti-duality answer; adding entry_x/entry_y beside a surviving centroid foot would have been
-- the duality itself.
--
-- exposure_fraction is BYTE-IDENTICAL to 0233 (crossing length / leg length, capped) — it feeds the
-- risk formula and this migration changes no balance number.
drop function if exists public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision);

create or replace function public.pirate_intercept_leg_zone_hits(
  p_ox double precision, p_oy double precision,
  p_tx double precision, p_ty double precision
)
returns table (
  zone_id           uuid,
  location_id       uuid,
  exposure_fraction double precision,
  ambush_x          double precision,
  ambush_y          double precision,
  entry_fraction    double precision
)
language sql
stable
security definer
set search_path = public
as $$
  with leg as (
    select ST_MakeLine(ST_MakePoint(p_ox, p_oy), ST_MakePoint(p_tx, p_ty)) as geom
  )
  select
    z.id,
    z.location_id,
    case when ST_Length(leg.geom) > 0
      then least(1.0, ST_Length(ST_Intersection(z.boundary, leg.geom)) / ST_Length(leg.geom))
      else 1.0
    end as exposure_fraction,
    e.entry_x,
    e.entry_y,
    e.entry_fraction
  from public.danger_zones z
  cross join leg
  -- CROSS JOIN LATERAL over a set-returning leaf: a zone the leg only TOUCHES produces no entry row
  -- and therefore drops out of the result entirely. Intersecting is no longer sufficient to be hit.
  cross join lateral public.pirate_intercept_leg_entry(leg.geom, z.boundary) e
  where z.status = 'active'
    and ST_Intersects(z.boundary, leg.geom)
$$;

revoke execute on function public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision) from public, anon, authenticated;
grant execute on function public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision) to service_role;

comment on function public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision) is
  'PIRATE INTERCEPT: the ONE segment-vs-polygon crossing test. One row per ACTIVE danger_zone the leg '
  '(origin)->(target) truly ENTERS, with exposure_fraction = (crossing length)/(leg length) unchanged '
  'since 0233, and — since 0301 — ambush_x/ambush_y = the FIRST TRUE INTERIOR ENTRY POINT (composed '
  'from pirate_intercept_leg_entry) rather than the closest point on the leg to the zone centroid, '
  'plus entry_fraction, where along the leg that happens. A leg that merely touches or grazes a zone '
  'no longer appears at all. Composed by the intercept planner AND the read-only route preview.';


-- ── 4. pirate_intercept_cancel_pending_for_movement — the ONE way an owed ambush is called off ──────
-- Three callers need this (the brake, the re-order, and the resolver's own "this can no longer fire"
-- exits) and they must all leave the same record. So it is a leaf, not three copies.
-- Idempotent: a movement with nothing owed returns 0 and writes nothing.
create or replace function public.pirate_intercept_cancel_pending_for_movement(
  p_movement uuid,
  p_reason   text
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n integer;
begin
  if p_movement is null then
    return 0;
  end if;
  update public.pirate_intercepts
     set lifecycle_state = 'cancelled',
         cancelled_at    = now(),
         cancel_reason   = p_reason
   where movement_id = p_movement
     and lifecycle_state = 'pending';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public.pirate_intercept_cancel_pending_for_movement(uuid, text) from public, anon, authenticated;
grant  execute on function public.pirate_intercept_cancel_pending_for_movement(uuid, text) to service_role;

comment on function public.pirate_intercept_cancel_pending_for_movement(uuid, text) is
  'PIRATE INTERCEPT (0301): calls off every ambush a movement still OWES, with a reason. The one '
  'authority for that transition — the brake, the re-order and the resolver''s own dead-end exits all '
  'compose it rather than writing lifecycle_state themselves. Idempotent; returns the row count.';


-- ── 5. pirate_intercept_plan_leg — THE ROLL, AT ORDER TIME. IT CHANGES NOTHING ELSE. ────────────────
-- This is what replaces pirate_intercept_evaluate_leg at both leg-minting sites. It reads, it rolls,
-- and it writes pirate_intercepts rows. It does NOT cancel the movement, does NOT move the fleet, does
-- NOT freeze a manifest, does NOT create a presence and does NOT create combat. Those all belong to
-- the resolver, later, when the fleet has actually got there.
--
-- ZONES ARE EVALUATED IN ASCENDING entry_fraction, and the loop STOPS at the first hit. A fleet cannot
-- physically reach a later zone before an earlier one, so a later zone's roll is not merely unlikely
-- to matter — it is unreachable, and rolling it would silently pre-decide an ambush the fleet may
-- never survive to face. Failed rolls before the first success are recorded as terminal 'missed' rows,
-- because the audit trail's value is that a leg which crossed nothing has NO rows at all.
--
-- FAIL OPEN, exactly as the retired evaluator did: any unexpected error leaves the leg unplanned and
-- untouched rather than breaking a player's movement command. The exception handler makes the whole
-- body one subtransaction, so a raise after some rows were written discards those rows too.
create or replace function public.pirate_intercept_plan_leg(p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv       record;
  v_fleet    record;
  v_group    uuid;
  v_hit      record;
  v_stats    jsonb;
  v_combined double precision;
  v_risk     double precision;
  v_roll     double precision;
  v_trigger  timestamptz;
  v_id       uuid;
  v_missed   integer := 0;
  -- 0276 cutover locals. Only ever populated on the typed-zone branch.
  v_typed    boolean;
  v_req      jsonb;
  v_res      jsonb;
  v_planned  jsonb;
begin
  -- DARK GATE FIRST — before any read at all (the 0233 posture, unchanged).
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('planned', false, 'reason', 'dark');
  end if;

  select id, fleet_id, player_id, origin_x, origin_y, target_x, target_y, status, depart_at, arrive_at
    into v_mv
    from public.fleet_movements
   where id = p_movement_id;
  if not found or v_mv.status <> 'moving' then
    return jsonb_build_object('planned', false, 'reason', 'not_moving');
  end if;
  -- A leg with no clock cannot be scheduled against. Refuse rather than divide by nothing.
  if v_mv.depart_at is null or v_mv.arrive_at is null or v_mv.arrive_at < v_mv.depart_at then
    return jsonb_build_object('planned', false, 'reason', 'unschedulable_leg');
  end if;

  select id, player_id, group_id, main_ship_id
    into v_fleet
    from public.fleets
   where id = v_mv.fleet_id;
  -- Unchanged from 0233: this only ever concerns the unified GROUP fleet shape (main_ship_id NULL +
  -- group_id SET). A legacy per-ship or unit fleet is not this feature's concern — skip, never guess.
  if not found or v_fleet.group_id is null or v_fleet.main_ship_id is not null then
    return jsonb_build_object('planned', false, 'reason', 'not_group_fleet');
  end if;
  v_group := v_fleet.group_id;

  -- combined stats: the SAME group-stats adapter the mover already calls for speed (D0, 0166).
  -- Fail OPEN on any adapter raise — treat as unknown/weak (combined = 0, the conservative choice)
  -- rather than let a stats bug break a player's movement command. Verbatim from the retired
  -- evaluator, but hoisted ABOVE the zone loop because the typed planner needs the real number and
  -- the loop must not rebuild a request per zone.
  begin
    v_stats := public.calculate_group_expedition_stats(v_fleet.player_id, v_group, 'none');
    v_combined := coalesce((v_stats->'totals'->>'combat_power')::double precision, 0)
                + coalesce((v_stats->'totals'->>'survival')::double precision, 0);
  exception when others then
    v_combined := 0;
  end;

  -- ── 0276 CUTOVER POINT, preserved ───────────────────────────────────────────────────────────────
  -- Exactly ONE path decides. While typed_zone_pirate_intercept_runtime_enabled is dark this is the
  -- legacy 0233 decision; while lit, eligibility and risk come from the pure V1 typed-zone planner, so
  -- a zone carrying no pirate_intercept effect row is simply not planned. FAIL CLOSED, NEVER OPEN: a
  -- planner that cannot answer leaves the leg alone rather than falling back and hiding the fault.
  v_typed := coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), false);
  if v_typed then
    v_req := public.typed_zone_pirate_candidates_v1(
               p_movement_id, v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, v_combined);
    v_res := public.typed_zone_effect_dispatch_v1(v_req);
    if (v_res->>'ok') <> 'true' then
      raise warning 'pirate_intercept_plan_leg: typed-zone dispatch rejected movement % (leg left UNPLANNED): %',
        p_movement_id, v_res->'error';
      return jsonb_build_object('planned', false, 'reason', 'typed_zone_dispatch_error');
    end if;
    v_planned := v_res->'plan'->'planned_effects';
  end if;

  for v_hit in
    select h.zone_id, h.location_id, h.exposure_fraction, h.ambush_x, h.ambush_y, h.entry_fraction
      from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y) h
     order by h.entry_fraction asc, h.zone_id asc
  loop
    if v_typed then
      -- Only a zone the typed planner actually planned is eligible, and its risk is ITS answer —
      -- recomputing here would read the globals and silently re-globalise a deliberately tuned zone.
      select (pe->>'risk')::double precision
        into v_risk
        from jsonb_array_elements(coalesce(v_planned, '[]'::jsonb)) pe
       where (pe->>'zone_id')::uuid = v_hit.zone_id;
      if v_risk is null then
        continue;
      end if;
    else
      v_risk := public.pirate_intercept_compute_risk(v_combined, v_hit.exposure_fraction);
    end if;

    v_roll := random();
    -- WHEN the fleet reaches this zone's edge, on this leg's own clock.
    v_trigger := v_mv.depart_at + (v_mv.arrive_at - v_mv.depart_at) * v_hit.entry_fraction;

    insert into public.pirate_intercepts (
      movement_id, fleet_id, player_id, zone_id, location_id,
      origin_x, origin_y, target_x, target_y, exposure_fraction,
      combined_stats, risk, roll, hit,
      lifecycle_state, entry_fraction, entry_x, entry_y, trigger_at)
    values (
      p_movement_id, v_fleet.id, v_fleet.player_id, v_hit.zone_id, v_hit.location_id,
      v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, v_hit.exposure_fraction,
      v_combined, v_risk, v_roll, (v_roll < v_risk),
      case when v_roll < v_risk then 'pending' else 'missed' end,
      v_hit.entry_fraction, v_hit.ambush_x, v_hit.ambush_y,
      case when v_roll < v_risk then v_trigger end)
    returning id into v_id;

    if v_roll < v_risk then
      -- STOP. The fleet meets this zone first; anything beyond it is unreachable from here.
      return jsonb_build_object(
        'planned', true, 'intercept_id', v_id, 'zone_id', v_hit.zone_id,
        'entry_fraction', v_hit.entry_fraction, 'trigger_at', v_trigger, 'missed', v_missed);
    end if;
    v_missed := v_missed + 1;
  end loop;

  return jsonb_build_object(
    'planned', false,
    'reason', case when v_missed > 0 then 'all_missed' else 'no_crossing' end,
    'missed', v_missed);
exception
  when others then
    raise warning 'pirate_intercept_plan_leg: unexpected error for movement % (leg left UNPLANNED): %',
      p_movement_id, sqlerrm;
    return jsonb_build_object('planned', false, 'reason', 'internal_error');
end;
$$;

revoke execute on function public.pirate_intercept_plan_leg(uuid) from public, anon, authenticated;
grant  execute on function public.pirate_intercept_plan_leg(uuid) to service_role;

comment on function public.pirate_intercept_plan_leg(uuid) is
  'PIRATE INTERCEPT (0301): rolls a freshly-minted leg against every ACTIVE danger zone it truly '
  'enters, in ascending entry_fraction, and STOPS at the first hit — a later zone is unreachable '
  'before an earlier one. Records terminal ''missed'' rows for the failed rolls before it and exactly '
  'ONE ''pending'' row for the hit, carrying the entry point, the entry fraction and the trigger_at '
  'the fleet is expected to reach it. It CANCELS NOTHING, MOVES NOTHING and CREATES NO COMBAT: that is '
  'pirate_intercept_resolve_due_for_movement''s job, later. Dark behind pirate_intercept_enabled; the '
  '0276 typed-zone cutover and its fail-closed exits are preserved; fails OPEN, leaving the leg '
  'unplanned rather than breaking a movement command.';


-- ── 6. combat_create_group_encounter — 0293:198-405 VERBATIM, with the ENGAGEMENT POINT MADE REAL ───
-- 0293 gave this function two optional engagement parameters and a COMMENT declaring it "THE single
-- authority that decides where a fight physically is" — while NOT ONE CALLER passed them, and while
-- 0294 restamped the row and translated the units microseconds later. A parameter nobody supplies is
-- not an authority; it is a comment. This migration makes it true instead of deleting it:
--
--   [C1] the two params LOSE their defaults. They are MANDATORY. (This is why the function is dropped
--        and re-created — PostgreSQL refuses to remove parameter defaults with CREATE OR REPLACE.)
--        A NULL VALUE is still legal and still means "this fight has no known coordinate", which is
--        byte-equivalent to what a vanished location produced before.
--   [C2] 0293's [B2] read of locations.x/y is DELETED, not moved. The caller resolves the point; this
--        function persists it. It no longer derives a coordinate from anything, so it can no longer
--        derive a DIFFERENT one.
--
-- EVERYTHING ELSE IS BYTE-IDENTICAL to 0293:198-405, including: the 0291-pinned creation-time flag
-- read `v_spatial_enabled boolean := public.cfg_bool('spatial_combat_enabled')` (sticky mode is still
-- DECIDED here, at creation), the 0234 ring formation and escort ordering, the fitted-weapon range
-- join, the 0262 empty-array + positive-attack fallback weapon inside the LIT-only block, the 0234
-- spatial INSERT column append, [B3]'s engagement_x/engagement_y append, the hull rollup and the
-- wave_spawned seed event.
drop function if exists public.combat_create_group_encounter(uuid, double precision, double precision);

create or replace function public.combat_create_group_encounter(
  p_presence      uuid,
  -- ██ HUNK [C1] (0301): the ENGAGEMENT POINT, MANDATORY. Every caller states where the fight is.
  p_engagement_x  double precision,
  p_engagement_y  double precision)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pr        location_presence%rowtype;
  m         record;
  v_stats   jsonb;
  v_roster  jsonb := '[]'::jsonb;
  v_power   double precision := 0;
  v_attack  double precision;
  v_defense double precision;
  v_hp      double precision;
  v_alive   integer;
  v_shield_max double precision;
  v_shield_cur double precision;
  v_aggro_priority integer;
  v_hull    double precision;
  v_enc     uuid;
  -- ██ HUNK [C1] (0301): the engagement point, taken from the caller and never recomputed.
  v_eng_x   double precision;
  v_eng_y   double precision;
  -- COMBAT-S3 (0234): the player position/speed/weapons snapshot — LIT-only working set. Gate read
  -- ONCE at entry (the 0198 v_growth / 0193 v_traits_enabled posture, mirrored). v_loc_x/v_loc_y/
  -- v_ring_radius are only ever populated when lit; the per-member locals (v_pos_x/v_pos_y/
  -- v_move_speed/v_weapons_json) are reset to the inert NULL/NULL/NULL/'[]' shape at the TOP of every
  -- loop iteration (the exact v_attack/v_defense/... reset law already in this function) so a dark or
  -- degraded member always lands the byte-equivalent-to-"column doesn't exist" shape.
  v_spatial_enabled boolean := public.cfg_bool('spatial_combat_enabled');
  v_loc_x           double precision;
  v_loc_y           double precision;
  v_ring_radius     double precision;
  v_escort_idx      integer := 0;
  v_pos_x           double precision;
  v_pos_y           double precision;
  v_move_speed      double precision;
  v_weapons_json    jsonb;
begin
  select * into pr from location_presence where id = p_presence;
  if not found then
    raise exception 'combat_create_group_encounter: presence % not found', p_presence;
  end if;

  -- ██ HUNK [C2] (0301): THE POINT IS THE CALLER'S. 0293's read of locations.x/y is GONE — not moved,
  -- ██ not coalesced, gone. This function persists what it is handed and seeds the formation around
  -- ██ it; it never resolves, re-reads or rewrites a coordinate. That is what makes it the single
  -- ██ WRITER of engagement_x/engagement_y without also being a second RESOLVER of them.
  v_eng_x := p_engagement_x;
  v_eng_y := p_engagement_y;

  -- COMBAT-S3 (0234): the formation anchor — command ship spawns HERE; escorts ring around it.
  -- 0293 [B2]: v_loc_x/v_loc_y take the resolved anchor. The gate, the ring radius knob and every use
  -- of v_loc_x/v_loc_y below are untouched.
  if v_spatial_enabled then
    v_loc_x := v_eng_x;
    v_loc_y := v_eng_y;
    v_ring_radius := coalesce(public.cfg_num('spatial_formation_ring_radius'), 30);
  end if;

  for m in
    select gsm.main_ship_id, gsm.player_id, msi.hp, msi.shield, msi.max_shield, msi.is_command_ship
      from group_sortie_members gsm
      join main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
     where gsm.fleet_id = pr.fleet_id
     order by gsm.main_ship_id
  loop
    v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
    v_shield_max := null; v_shield_cur := null;
    v_aggro_priority := case when m.is_command_ship then 100 else 0 end;
    -- COMBAT-S3 (0234): the inert default — reset EVERY iteration, before the hp>0 branch (the same
    -- unconditional-reset law aggro_priority already follows), so a degraded member's row lands
    -- exactly the "no spatial data" shape regardless of why it degraded.
    v_pos_x := null; v_pos_y := null; v_move_speed := null; v_weapons_json := '[]'::jsonb;
    if m.hp > 0 then
      begin
        v_stats   := public.calculate_expedition_stats(m.player_id, m.main_ship_id, '[]'::jsonb, 'pirate_hunt');
        v_attack  := coalesce((v_stats->>'combat_power')::double precision, 0);
        v_defense := coalesce((v_stats->>'survival')::double precision, 0);
        v_hp      := m.hp;
        v_alive   := 1;
        if m.max_shield > 0 then
          v_shield_max := m.max_shield;
          v_shield_cur := m.shield;
        end if;
        -- COMBAT-S3 (0234): position/speed/weapons — LIT only, computed from the SAME successful
        -- adapter call above (v_stats) — no second calculate_expedition_stats invocation.
        if v_spatial_enabled then
          v_move_speed := coalesce((v_stats->>'speed')::double precision, 1);
          if m.is_command_ship then
            v_pos_x := v_loc_x;
            v_pos_y := v_loc_y;
          else
            v_pos_x := v_loc_x + v_ring_radius * cos(2 * pi() * v_escort_idx / 8);
            v_pos_y := v_loc_y + v_ring_radius * sin(2 * pi() * v_escort_idx / 8);
            v_escort_idx := v_escort_idx + 1;
          end if;
          -- The S0 ship_weapon_modules (0229) fitting join, INLINED (that leaf filters
          -- player_id = auth.uid(), unusable from this security-definer engine context — see the
          -- header grounding). Frozen next_ready_at/ammo_remaining = NULL: every weapon is ready to
          -- fire tick 1.
          select coalesce(jsonb_agg(jsonb_build_object(
                   'module_type_id', t.id, 'range', t.range, 'projectile_speed', t.projectile_speed,
                   'power', t.power, 'ammo_type', t.ammo_type, 'ammo_per_shot', t.ammo_per_shot,
                   'cooldown_seconds', t.cooldown_seconds, 'next_ready_at', null, 'ammo_remaining', null)),
                 '[]'::jsonb)
            into v_weapons_json
            from ship_module_fittings f
            join module_instances i on i.id = f.module_instance_id
            join module_types t     on t.id = i.module_type_id
           where f.main_ship_id = m.main_ship_id and t.range is not null;
          -- ██ COMBAT-FALLBACK (0262): NO-WEAPON-MODULE PLAYER SHIPS STILL FIRE IN SPATIAL MODE ██
          -- A player ship whose fitted modules yield an EMPTY weapons array (no range-carrying
          -- weapon module fitted) but which still carries a positive attack_snapshot (v_attack —
          -- its combat_power from captain/hull/trait folds) would, in spatial mode, fire NOTHING
          -- and deal ZERO damage: the tick is a pure consumer of weapons_json and its fire loop
          -- `for v_widx in 0 .. jsonb_array_length(weapons_json) - 1` never iterates over an empty
          -- array. Materialize ONE synthesized "basic player weapon" HERE (at creation, never in
          -- the tick), deriving its power from the ship's OWN attack_snapshot and its range/
          -- projectile_speed/cooldown from the dedicated combat_player_fallback_weapon_* knobs (the
          -- player's basic-weapon profile — DELIBERATELY separate from the enemy synthetic's). A
          -- ship that DID fit a range weapon keeps its weapons_json byte-untouched (guarded on the
          -- array being EMPTY). Same entry shape as the fitted case (module_type_id/range/
          -- projectile_speed/power/ammo_type/ammo_per_shot/cooldown_seconds/next_ready_at/
          -- ammo_remaining) so the tick reads it identically.
          if jsonb_array_length(v_weapons_json) = 0 and coalesce(v_attack, 0) > 0 then
            v_weapons_json := jsonb_build_array(jsonb_build_object(
              'module_type_id',   coalesce((select value #>> '{}' from game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon'),
              'range',            coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 150),
              'projectile_speed', coalesce(public.cfg_num('combat_player_fallback_weapon_projectile_speed'), 300),
              'power',            v_attack * coalesce(public.cfg_num('combat_player_fallback_weapon_power_from_attack'), 1),
              'ammo_type',        null,
              'ammo_per_shot',    0,
              'cooldown_seconds', coalesce(public.cfg_num('combat_player_fallback_weapon_cooldown_seconds'), 2),
              'next_ready_at',    null,
              'ammo_remaining',   null));
          end if;
        end if;
      exception when others then
        v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
        v_shield_max := null; v_shield_cur := null;
      end;
    end if;
    v_power  := v_power + v_attack;
    v_roster := v_roster || jsonb_build_array(jsonb_build_object(
      'main_ship_id', m.main_ship_id, 'player_id', m.player_id, 'hp', v_hp,
      'alive', v_alive, 'attack', v_attack, 'defense', v_defense,
      'shield_max', v_shield_max, 'shield_cur', v_shield_cur,
      'aggro_priority', v_aggro_priority,
      'pos_x', v_pos_x, 'pos_y', v_pos_y, 'move_speed', v_move_speed, 'weapons_json', v_weapons_json));
  end loop;

  -- ██ HUNK [B3] (0293): engagement_x, engagement_y APPENDED to the existing column and value lists —
  -- ██ every pre-existing column/value is untouched and in its original order (the 0234 append law).
  -- ██ This INSERT is the ONLY write of engagement_x/engagement_y anywhere in the database (0301).
  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current,
    player_integrity_max, player_integrity_current, enemy_integrity_max, enemy_integrity_current,
    wave_number, last_resolved_at,
    engagement_x, engagement_y)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, 0, 0, 0, 0, 0, now(),
    v_eng_x, v_eng_y)
  returning id into v_enc;

  -- COMBAT-S3 (0234): pos_x, pos_y, move_speed, weapons_json, side APPENDED to the existing column and
  -- SELECT lists — every pre-existing column/value is untouched (extract-and-diff proof: nothing
  -- before 'aggro_priority)' in the column list or before the aggro_priority cast in the SELECT list
  -- changed). side is always 'player' here (this function never writes an enemy row) — a literal, not
  -- roster-carried. These positions are FINAL: nothing translates them afterwards (0301 deleted the
  -- only thing that did).
  insert into combat_units (
    encounter_id, player_id, unit_type_id, main_ship_id, attack_snapshot, defense_snapshot,
    ship_hp, initial_count, alive_count, hp_max, hp_current,
    shield_max, shield_current,
    aggro_priority,
    pos_x, pos_y, move_speed, weapons_json, side)
  select v_enc, (e->>'player_id')::uuid, null, (e->>'main_ship_id')::uuid,
         (e->>'attack')::double precision, (e->>'defense')::double precision,
         (e->>'hp')::double precision, 1, (e->>'alive')::integer,
         (e->>'hp')::double precision, (e->>'hp')::double precision,
         (e->>'shield_max')::double precision, (e->>'shield_cur')::double precision,
         (e->>'aggro_priority')::integer,
         (e->>'pos_x')::double precision, (e->>'pos_y')::double precision,
         (e->>'move_speed')::double precision, coalesce(e->'weapons_json', '[]'::jsonb), 'player'
  from jsonb_array_elements(v_roster) as e;

  select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;
  update combat_encounters set player_integrity_max = v_hull, player_integrity_current = v_hull where id = v_enc;

  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (v_enc, pr.player_id, 0, 0, 'wave_spawned', 'pirate', 'player', jsonb_build_object('wave', 1, 'danger', 1));
  return v_enc;
end;
$$;

-- Internal engine leaf — the 0168:467-471 / 0293:407-411 ACL posture, restated on the same signature
-- (the drop above took the previous grants with it).
revoke execute on function public.combat_create_group_encounter(uuid, double precision, double precision) from public, anon, authenticated;
grant  execute on function public.combat_create_group_encounter(uuid, double precision, double precision) to service_role;

comment on function public.combat_create_group_encounter(uuid, double precision, double precision) is
  'GROUP ENCOUNTER CREATOR (0168 + 0195/0228/0234/0262 + 0293) + MANDATORY ENGAGEMENT POINT (0301). '
  'It PERSISTS the engagement point its caller supplies — into combat_encounters.engagement_x/'
  'engagement_y and as the anchor of the player formation — and it DERIVES NO GEOMETRY OF ITS OWN and '
  'REWRITES NONE afterwards. p_engagement_x/p_engagement_y are required arguments; a NULL value is '
  'legal and means "this fight has no known coordinate", exactly what a vanished location produced '
  'before. This INSERT is the only write of engagement_x/engagement_y in the database, and the '
  'combat_units positions it seeds are final. Where the fight IS gets decided by the caller: '
  'combat_create_encounter resolves it, and for an ambush the point comes from '
  'pirate_intercept_leg_entry via the pending pirate_intercepts row. Spatial mode is still DECIDED '
  'here, at creation, from spatial_combat_enabled (0242/0291 sticky mode).';


-- ── 7. combat_create_encounter — 0168:481-528 with the ENGAGEMENT POINT RESOLVED AND PASSED ─────────
-- The signature is DELIBERATELY UNCHANGED, so activity_start (0230:122), the telegraph resolver
-- (0230:294) and presence_request_leave's chain all keep working untouched. What changes is one
-- branch: the group branch now states where the fight is instead of leaving the creator to guess.
--
-- THE RESOLUTION RULE, in one sentence: A FIGHT HAPPENS WHERE ITS FLEET IS. A fleet parked in open
-- space (location_mode='space' — which is exactly what an ambushed fleet is, because the resolver
-- parked it at the entry point before creating the presence) fights AT that point; a fleet present at
-- a location fights at the location's centre. That is one rule with one reader, not two authorities:
-- pirate_intercept_leg_entry decides the ambush geometry, the resolver puts the fleet there, this
-- function reads where the fleet is, and combat_create_group_encounter persists it.
--
-- NOTE on location_mode rather than space_x IS NOT NULL: fleet_set_present (0006:128) does not clear
-- space_x/space_y, so a fleet that was once parked in space and later docked still carries stale
-- coordinates. location_mode is the authoritative discriminator; space_x/space_y are only meaningful
-- while it says 'space'.
create or replace function public.combat_create_encounter(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pr      location_presence%rowtype;
  v_power double precision;
  v_hull  double precision;
  v_enc   uuid;
  -- 0301: the engagement-point resolution working set.
  v_fleet record;
  v_eng_x double precision;
  v_eng_y double precision;
begin
  select * into pr from location_presence where id = p_presence;
  if not found then
    raise exception 'combat_create_encounter: presence % not found', p_presence;
  end if;
  -- SLICE D2: a fleet with a sortie MANIFEST routes to the member encounter creator. Keys on
  -- group_sortie_members ONLY (never live group membership, never fleets.group_id — the
  -- manifest-wins law).
  if exists (select 1 from group_sortie_members gsm where gsm.fleet_id = pr.fleet_id) then
    -- ██ 0301: RESOLVE THE ENGAGEMENT POINT, THEN HAND IT OVER. The creator's parameters are
    -- ██ mandatory precisely so this decision has to be made somewhere visible, exactly once.
    select f.location_mode, f.space_x, f.space_y into v_fleet from fleets f where f.id = pr.fleet_id;
    if v_fleet.location_mode = 'space' and v_fleet.space_x is not null and v_fleet.space_y is not null then
      v_eng_x := v_fleet.space_x;
      v_eng_y := v_fleet.space_y;
    else
      -- The location's centre — what every caller before 0293 meant implicitly. A vanished location
      -- leaves both NULL, which is the shape the creator has always produced in that case.
      select l.x, l.y into v_eng_x, v_eng_y from locations l where l.id = pr.location_id;
    end if;
    return combat_create_group_encounter(p_presence, v_eng_x, v_eng_y);
  end if;
  v_power := fleet_get_power(pr.fleet_id);

  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current,
    player_integrity_max, player_integrity_current, enemy_integrity_max, enemy_integrity_current,
    wave_number, last_resolved_at)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, 0, 0, 0, 0, 0, now())
  returning id into v_enc;

  -- Per-unit combat state from the fleet's composition.
  insert into combat_units (encounter_id, player_id, unit_type_id, ship_hp, initial_count, alive_count, hp_max, hp_current)
  select v_enc, pr.player_id, fu.unit_type_id, ut.hull, fu.quantity, fu.quantity, fu.quantity * ut.hull, fu.quantity * ut.hull
  from fleet_units fu join unit_types ut on ut.id = fu.unit_type_id
  where fu.fleet_id = pr.fleet_id and fu.quantity > 0;

  select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;
  update combat_encounters set player_integrity_max = v_hull, player_integrity_current = v_hull where id = v_enc;

  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (v_enc, pr.player_id, 0, 0, 'wave_spawned', 'pirate', 'player', jsonb_build_object('wave', 1, 'danger', 1));
  return v_enc;
end;
$$;

comment on function public.combat_create_encounter(uuid) is
  'ENCOUNTER CREATOR (0017/0022/0023 + 0168 manifest routing) + ENGAGEMENT-POINT RESOLUTION (0301). '
  'The manifest branch now RESOLVES where the fight physically is — a fleet parked in open space '
  'fights at its own coordinate (an ambushed fleet is parked at the zone entry point before this runs); '
  'a fleet present at a location fights at that location''s centre — and passes it to '
  'combat_create_group_encounter, whose engagement parameters are mandatory. The legacy '
  'fleet_units branch is byte-untouched. Signature deliberately unchanged so activity_start and the '
  'telegraph resolver need no edit.';


-- ── 8. pirate_intercept_resolve_due_for_movement — THE ONLY THING THAT TURNS PENDING INTO COMBAT ────
-- Called by movement_advance, and by nothing else. It is TERMINALISING BY CONTRACT: for a DUE pending
-- row it always leaves the row in a terminal state — fired, or cancelled with a reason. That contract
-- is what guarantees a movement can never be wedged behind an ambush that will not resolve, and it is
-- why the dispatcher's refuse-to-settle guard below is a safety net rather than a live branch.
--
-- TWO CONDITIONS, BOTH REQUIRED, ONE CLOCK. v_now is captured ONCE. The ambush fires only when the
-- wall clock has passed trigger_at AND the fleet's own interpolated progress along the leg has
-- actually reached entry_fraction. Time alone is not enough: a leg can be re-timed, and a fraction
-- computed from a stale clock would fire an ambush at a point the fleet is not at.
--
-- THE GEOMETRY IS NOT RECOMPUTED. The order keeps the point it was accepted with. Re-deriving the
-- entry from the CURRENT boundary would let an owner edit — or 0296-style re-materialisation — move
-- an ambush a player has already been committed to. Only LIVENESS is revalidated.
--
-- LOCK ORDER, EVERYWHERE: movement -> pending intercept -> fleet.
create or replace function public.pirate_intercept_resolve_due_for_movement(p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now      timestamptz := clock_timestamp();
  v_mv       record;
  v_pi       record;
  v_claim    record;
  v_fleet    record;
  v_group    uuid;
  v_frac     double precision;
  v_pos      record;
  v_zone_ok  boolean;
  v_manifest integer;
  v_loc      record;
  v_presence uuid;
  v_enc      uuid;
begin
  -- 1) THE MOVEMENT, LOCKED FIRST. A movement that is no longer moving owes nothing: terminalise
  --    whatever it still had pending rather than leaving a row that can never fire.
  select id, fleet_id, player_id, origin_x, origin_y, target_x, target_y, status, depart_at, arrive_at
    into v_mv
    from public.fleet_movements
   where id = p_movement_id
     for update;
  if not found or v_mv.status <> 'moving' then
    perform public.pirate_intercept_cancel_pending_for_movement(p_movement_id, 'movement_not_moving');
    return jsonb_build_object('fired', false, 'reason', 'not_moving');
  end if;

  -- 2) THE OWED AMBUSH, LOCKED SECOND. At most one can exist — the unique partial index says so —
  --    which is also why nothing below needs to sweep "the other" pending rows after firing.
  select *
    into v_pi
    from public.pirate_intercepts
   where movement_id = p_movement_id
     and lifecycle_state = 'pending'
     for update;
  if not found then
    return jsonb_build_object('fired', false, 'reason', 'nothing_pending');
  end if;

  -- 3) NOT YET. Both gates, against the one captured clock.
  if v_now < v_pi.trigger_at then
    return jsonb_build_object('fired', false, 'reason', 'not_due');
  end if;
  select o_x, o_y into v_pos
    from public.movement_position_at(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y,
                                     v_mv.depart_at, v_mv.arrive_at, v_now);
  -- Where along its own leg the fleet has actually got to. A degenerate leg is treated as fully
  -- travelled (there is nowhere else to be), matching movement_position_at's own clamp behaviour.
  select case
           when ST_Length(ST_MakeLine(ST_MakePoint(v_mv.origin_x, v_mv.origin_y),
                                      ST_MakePoint(v_mv.target_x, v_mv.target_y))) > 0
           then ST_LineLocatePoint(
                  ST_MakeLine(ST_MakePoint(v_mv.origin_x, v_mv.origin_y),
                              ST_MakePoint(v_mv.target_x, v_mv.target_y)),
                  ST_MakePoint(v_pos.o_x, v_pos.o_y))
           else 1.0
         end
    into v_frac;
  if coalesce(v_frac, 0) + 1e-9 < v_pi.entry_fraction then
    return jsonb_build_object('fired', false, 'reason', 'not_reached', 'progress', v_frac);
  end if;

  -- 4) LIVENESS REVALIDATION — never geometry. Each failure TERMINALISES the row.
  --    (a) the fleet must still be the one that was ambushed, and still be the unified group shape.
  select id, player_id, group_id, main_ship_id
    into v_fleet
    from public.fleets
   where id = v_mv.fleet_id
     for update;
  if not found or v_fleet.id is distinct from v_pi.fleet_id
     or v_fleet.group_id is null or v_fleet.main_ship_id is not null then
    perform public.pirate_intercept_cancel_pending_for_movement(p_movement_id, 'fleet_changed');
    return jsonb_build_object('fired', false, 'reason', 'fleet_changed');
  end if;
  v_group := v_fleet.group_id;

  --    (b) a fleet already in a fight cannot be pulled into a second one.
  if exists (select 1 from public.combat_encounters ce
              where ce.fleet_id = v_fleet.id and ce.status in ('active', 'retreating')) then
    perform public.pirate_intercept_cancel_pending_for_movement(p_movement_id, 'fleet_in_combat');
    return jsonb_build_object('fired', false, 'reason', 'fleet_in_combat');
  end if;

  --    (c) the zone must still be lit. An owner who unpublishes a zone (0255) or deactivates it (0268)
  --        calls off the ambushes it owes — the movement then simply continues to its destination.
  --        Under the typed-zone runtime the effect row must still exist too, for the same reason.
  select (z.status = 'active')
     and (not coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), false)
          or exists (select 1 from public.zone_effect_pirate_intercept ze where ze.zone_id = z.id))
    into v_zone_ok
    from public.danger_zones z
   where z.id = v_pi.zone_id;
  if coalesce(v_zone_ok, false) is not true then
    perform public.pirate_intercept_cancel_pending_for_movement(p_movement_id, 'zone_inactive');
    return jsonb_build_object('fired', false, 'reason', 'zone_inactive');
  end if;

  -- 5) CLAIM IT. Conditional on the row still being pending: if a concurrent worker got here first,
  --    no row comes back and this one aborts without touching anything. Two workers cannot both fire.
  update public.pirate_intercepts
     set lifecycle_state = 'fired', resolved_at = v_now
   where id = v_pi.id and lifecycle_state = 'pending'
  returning * into v_claim;
  if not found then
    return jsonb_build_object('fired', false, 'reason', 'lost_race');
  end if;

  -- ── FROM HERE THE AMBUSH IS COMMITTED. The blocks below are 0294:1322-1402 with the restamp and
  -- ── the unit translation removed, and the ambush point taken from the row instead of recomputed.

  update public.fleet_movements set status = 'cancelled', resolved_at = v_now where id = p_movement_id;

  -- THE FLEET STOPS WHERE IT WAS AMBUSHED. This is the 0293 [A1] leaf, and it now runs BEFORE the
  -- presence exists — which is what lets combat_create_encounter read the fleet's own position as the
  -- engagement point instead of anything restamping it afterwards.
  perform public.fleet_set_in_space(v_fleet.id, v_pi.entry_x, v_pi.entry_y);

  -- The rest of a plotted route is ABANDONED, not silently resumed later from an unplanned position.
  -- 0233 made exactly this decision at command_ship_group_go_route:1085-1089 for the order-time
  -- ambush; deferring the ambush must not quietly reverse it. This makes the resolver a documented
  -- writer of fleet_route_legs (see that table's comment).
  delete from public.fleet_route_legs where fleet_id = v_fleet.id;

  if v_pi.location_id is null then
    -- STANDALONE drawn zone (no linked pirate_hunt location): the documented combat stub. No location
    -- means no presence/encounter is possible without inventing one — the ambush is made TANGIBLE by
    -- the forced stop above. Not a no-op.
    update public.pirate_intercepts set note = 'standalone_zone_stub_forced_stop' where id = v_pi.id;
    return jsonb_build_object('fired', true, 'reason', 'standalone_zone_stub', 'intercept_id', v_pi.id);
  end if;

  select l.id, l.zone_id, z.sector_id
    into v_loc
    from public.locations l
    join public.zones z on z.id = l.zone_id
   where l.id = v_pi.location_id and l.status = 'active';
  if v_loc.id is null then
    -- the linked location vanished/deactivated since the zone was drawn/seeded — fail open: parked,
    -- no combat, rather than reference a location that can no longer host a presence.
    update public.pirate_intercepts set note = 'location_missing' where id = v_pi.id;
    return jsonb_build_object('fired', true, 'reason', 'location_missing', 'intercept_id', v_pi.id);
  end if;

  -- Freeze the sortie MANIFEST — byte-identical INSERT shape to send_ship_group_hunt's sole-writer
  -- freeze (0168:304-306), so combat_create_encounter's manifest-gated branch routes this fleet into
  -- combat_create_group_encounter exactly as a deliberate hunt does. ON CONFLICT DO NOTHING:
  -- idempotent against a (should-be-impossible) re-entry.
  insert into public.group_sortie_members (fleet_id, main_ship_id, player_id)
  select v_fleet.id, msi.main_ship_id, v_fleet.player_id
    from public.main_ship_instances msi
   where msi.group_id = v_group and msi.player_id = v_fleet.player_id
  on conflict (fleet_id, main_ship_id) do nothing;
  get diagnostics v_manifest = row_count;

  -- 0290 ZERO-MANIFEST GUARD, sited exactly where 0290 put it: BEFORE presence_create. The freeze
  -- reads LIVE main_ship_instances.group_id and can legitimately return no rows (an empty/disbanded
  -- group, every ship reassigned). With no manifest, 0168's combat_create_encounter takes the legacy
  -- branch and inserts combat_units from fleet_units — a table a TEAM-SORTIE fleet has no rows in —
  -- producing an encounter with ZERO combat_units: nothing to draw, nothing to fight, and
  -- player_power_start = 0. An ambush that cannot field a single ship is not a fight. The fleet is
  -- already parked at the point it actually reached; log why and open nothing.
  if v_manifest = 0 then
    update public.pirate_intercepts set note = 'empty_manifest' where id = v_pi.id;
    return jsonb_build_object('fired', true, 'reason', 'empty_manifest', 'intercept_id', v_pi.id);
  end if;

  -- presence_create -> activity_start('hunt_pirates') -> combat_create_encounter -> (manifest exists)
  -- -> combat_create_group_encounter. FOUR frozen functions composed, ZERO re-created here. The
  -- presence carries NO coordinate and still does not need to: the fleet is already standing at the
  -- ambush point, and combat_create_encounter reads it from there.
  v_presence := public.presence_create(v_fleet.player_id, v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'hunt_pirates');

  select id into v_enc from public.combat_encounters where presence_id = v_presence order by created_at desc limit 1;
  update public.pirate_intercepts
     set encounter_id = v_enc, presence_id = v_presence
   where id = v_pi.id;

  -- combat_telegraph_enabled (lit by 0300) makes activity_start record a pending_encounters row and
  -- return WITHOUT creating the encounter; the telegraph cron opens it a few seconds later. The
  -- ambush has still FIRED — the leg is cancelled and the fleet is parked at the entry point — there
  -- is simply no encounter row to record yet. Say which of the two happened rather than reporting a
  -- null encounter_id as 'combat_started'. When the telegraph cron does open it, the fleet is still
  -- parked in open space at the entry point, so combat_create_encounter resolves the same engagement
  -- point this resolution would have.
  return jsonb_build_object(
    'fired', true,
    'reason', case when v_enc is null then 'combat_telegraphed' else 'combat_started' end,
    'intercept_id', v_pi.id, 'zone_id', v_pi.zone_id,
    'entry_x', v_pi.entry_x, 'entry_y', v_pi.entry_y,
    'location_id', v_loc.id, 'presence_id', v_presence, 'encounter_id', v_enc);
end;
$$;

revoke execute on function public.pirate_intercept_resolve_due_for_movement(uuid) from public, anon, authenticated;
grant  execute on function public.pirate_intercept_resolve_due_for_movement(uuid) to service_role;

comment on function public.pirate_intercept_resolve_due_for_movement(uuid) is
  'PIRATE INTERCEPT (0301): THE ONLY path from a pending pirate_intercepts row to combat. Fires only '
  'when ONE captured clock has passed trigger_at AND the fleet''s interpolated progress has reached '
  'entry_fraction. Never recomputes the entry geometry — the order keeps the point it was accepted '
  'with; only liveness (movement still moving, same unified group fleet, not already in combat, zone '
  'still active/effective) is revalidated, and every failure TERMINALISES the row so a movement can '
  'never wedge behind it. Claims the row with a conditional UPDATE, so two concurrent workers cannot '
  'both fire. On firing: cancels the leg, parks the fleet at the entry point, abandons the rest of a '
  'plotted route, freezes the manifest (0290 zero-manifest guard intact), and opens the encounter '
  'through the frozen presence chain. Deliberately NOT raise-free at its boundary: a failure must roll '
  'the whole resolution back and retry, never half-open a fight. Lock order movement -> intercept -> fleet.';


-- ── 9. movement_advance — THE ONE PRE-SETTLEMENT DISPATCHER ─────────────────────────────────────────
-- Every consumer that used to call movement_settle_arrival directly now calls this instead. There is
-- exactly one door into settlement, and an owed ambush is resolved before anyone walks through it.
--
-- WHY THE REFUSAL BELOW IS NOT DEAD CODE: the resolver terminalises every DUE row, so in normal
-- operation the check cannot be true. It exists for the case where that contract is broken — and in
-- that case settling would let a fleet ARRIVE past an ambush it had already earned, which is the exact
-- evasion this migration exists to close. So it RAISES: the caller's per-row subtransaction rolls the
-- movement back to 'moving' and it retries on the next tick, rather than silently arriving.
create or replace function public.movement_advance(p_movement uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res    jsonb;
  v_settle jsonb;
begin
  -- The movement row FIRST, matching the resolver's lock order. For the cron this is a no-op re-take
  -- of a lock it already holds; for the on-demand RPC it is the authoritative claim.
  perform 1 from public.fleet_movements where id = p_movement for update;

  v_res := public.pirate_intercept_resolve_due_for_movement(p_movement);
  if coalesce((v_res->>'fired')::boolean, false) then
    return jsonb_build_object('advanced', true, 'outcome', 'intercepted', 'intercept', v_res);
  end if;

  if exists (select 1 from public.pirate_intercepts pi
              where pi.movement_id = p_movement
                and pi.lifecycle_state = 'pending'
                and pi.trigger_at <= clock_timestamp()) then
    raise exception 'movement_advance: movement % still owes a DUE intercept after resolution — refusing to settle an arrival past an ambush', p_movement;
  end if;

  v_settle := public.movement_settle_arrival(p_movement);
  return jsonb_build_object('advanced', true, 'outcome', 'settled', 'settle', v_settle);
end;
$$;

revoke execute on function public.movement_advance(uuid) from public, anon, authenticated;
grant  execute on function public.movement_advance(uuid) to service_role;

comment on function public.movement_advance(uuid) is
  'MOVEMENT (0301): the ONE pre-settlement dispatcher. Resolves any DUE pirate intercept for this '
  'movement FIRST and settles the arrival only if none fired. Every settlement consumer goes through '
  'it — process_fleet_movements'' due-intercept scan and its arrival scan, and '
  'command_main_ship_settle_arrival_legacy — so arrival can never precede resolution. '
  'movement_settle_arrival is byte-untouched and simply stops being called directly.';


-- ── 10. process_fleet_movements — 0206:65-103 VERBATIM + ONE NEW SCAN IN FRONT ──────────────────────
-- The arrival scan's predicate (`status='moving' and arrive_at<=now()` FOR UPDATE SKIP LOCKED), the
-- 0206 CRON-GUARD per-movement subtransaction, the query_canceled re-raise, the WARNING severity and
-- the uncounted-failure posture are all UNCHANGED. Two deltas:
--
--   [D1] A NEW due-intercept scan runs FIRST. It has to: the arrival scan only ever selects movements
--        that have ALREADY ARRIVED, so an ambush at fraction 0.3 of a leg would otherwise not be
--        looked at until the fleet had reached its destination — which is the defect wearing a new
--        hat. This scan selects movements that are still in flight but whose owed ambush is due.
--   [D2] The arrival loop body calls movement_advance instead of movement_settle_arrival. Ordering
--        alone would nearly do (an intercept resolved in [D1] cancels its movement, so [D2]'s scan no
--        longer sees it), but "nearly" is how a fleet evades an ambush by arriving. The dispatcher
--        makes it structural.
--
-- STILL EXACTLY ONE SETTLEMENT ENGINE. Both loops enter through movement_advance; movement_advance is
-- the only caller of movement_settle_arrival in the movement processor.
create or replace function public.process_fleet_movements()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  m       record;
  v_count integer := 0;
begin
  -- ── [D1] DUE-INTERCEPT SCAN (0301). Movements still in flight whose owed ambush has come due. ────
  --    Locks the MOVEMENT only (the declared lock order: movement -> intercept -> fleet); the
  --    resolver takes the intercept row itself. SKIP LOCKED so a movement another session is holding
  --    is simply left for the next tick. Wrapped in the same per-row subtransaction as below: an
  --    ambush that cannot resolve must not wedge anyone else's, and must leave its own movement
  --    'moving' to retry. These do NOT count toward the processed total — v_count is the arrival
  --    count and stays comparable across this change.
  for m in
    select fm.id
      from public.pirate_intercepts pi
      join public.fleet_movements fm on fm.id = pi.movement_id
     where pi.lifecycle_state = 'pending'
       and pi.trigger_at <= now()
       and fm.status = 'moving'
     order by pi.trigger_at
       for update of fm skip locked
  loop
    begin
      perform movement_advance(m.id);
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_fleet_movements: intercept resolution failed for movement % (left moving; retries next tick): %',
          m.id, sqlerrm;
    end;
  end loop;
  -- ── END [D1] ─────────────────────────────────────────────────────────────────────────────────────

  for m in
    select * from fleet_movements
    where status = 'moving' and arrive_at <= now()
    for update skip locked
  loop
    -- ── CRON-GUARD (0206) HUNK: the per-movement subtransaction (the 0194 per-order guard, mirrored).
    --    A raise inside the settle (e.g. presence_create → activity_start 'unknown activity' for an
    --    allowed-but-undispatched location activity_type) must NOT abort the whole 30s run and
    --    re-raise forever for every player. On failure THIS movement's settle rolls back (the
    --    subtransaction), a WARNING logs it, the movement is left 'moving' (pre-iteration state) to
    --    retry next tick, and the loop CONTINUES — other players' arrivals settle. query_canceled
    --    re-raised (never swallow a statement-timeout cancel — the 0194/0182 posture). v_count sits
    --    INSIDE the guard, so a failed settle is UNCOUNTED (the 0194 posture — a poison row never
    --    inflates the processed count). ─────────────────────────────────────────────────────────────
    begin
    -- 0301 [D2]: the ONE door. movement_advance resolves a due ambush before it settles anything.
    perform movement_advance(m.id);
    v_count := v_count + 1;
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_fleet_movements: settle failed for movement % (left moving; retries next tick): %',
          m.id, sqlerrm;
    end;
    -- ── END CRON-GUARD (0206) HUNK ───────────────────────────────────────────────────────────────
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.process_fleet_movements() from public, anon, authenticated;

comment on function public.process_fleet_movements() is
  'MOVEMENT PROCESSOR (0011/0151/0206) + DUE-INTERCEPT RESOLUTION (0301). Two scans, in this order: '
  'movements still in flight whose owed pirate ambush has come due, then movements that have arrived. '
  'Both enter through movement_advance, so an arrival can never be settled past an ambush the fleet '
  'already earned. The 0206 per-row CRON-GUARD subtransaction, the arrival predicate and the '
  'uncounted-failure posture are unchanged; the returned count is still the ARRIVAL count.';


-- ── 11. command_main_ship_settle_arrival_legacy — 0151:126-210 VERBATIM + the ONE dispatcher line ───
-- This is the second — and last — production consumer that settled a movement independently. It is a
-- LEGACY MAIN-SHIP path (it rejects any fleet with main_ship_id NULL), and the intercept planner only
-- ever plans for the unified GROUP shape (main_ship_id NULL + group_id SET), so no fleet reachable
-- here can carry a pending ambush. Routing it through the dispatcher is therefore behaviour-neutral
-- TODAY — and it is done anyway, because "no second direct settlement consumer" is the property worth
-- having, not "no second consumer that currently matters".
create or replace function public.command_main_ship_settle_arrival_legacy(p_fleet uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_fleet  fleets%rowtype;
  v_n      integer;
  m        fleet_movements%rowtype;
  v_act    text;
  v_res    jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- The EXISTING legacy-send human gate (0050/0053).
  if not cfg_bool('mainship_send_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- Resolve the fleet: explicit id (owned) or the sole in-flight main-ship fleet (the 0081 resolver's
  -- fail-closed shape — ambiguity forces explicit selection).
  if p_fleet is not null then
    select * into v_fleet from fleets where id = p_fleet and player_id = v_player;
    if v_fleet.id is null then
      return jsonb_build_object('ok', false, 'reason', 'fleet_not_found');
    end if;
  else
    select count(*) into v_n from fleets
      where player_id = v_player and main_ship_id is not null and status in ('moving', 'returning');
    if v_n = 0 then
      return jsonb_build_object('ok', true, 'settled', false, 'reason', 'no_active_movement');
    elsif v_n > 1 then
      return jsonb_build_object('ok', false, 'reason', 'ambiguous_fleet');
    end if;
    select * into v_fleet from fleets
      where player_id = v_player and main_ship_id is not null and status in ('moving', 'returning');
  end if;
  -- Main-ship fleets only (the request_main_ship_return predicate, 0050:185-187).
  if v_fleet.main_ship_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_main_ship_fleet');
  end if;

  -- Claim the active movement the cron's OWN way: row lock, SKIP LOCKED (contention → the cron wins).
  select * into m from fleet_movements
    where fleet_id = v_fleet.id and status = 'moving'
    for update skip locked;
  if m.id is null then
    if exists (select 1 from fleet_movements where fleet_id = v_fleet.id and status = 'moving') then
      return jsonb_build_object('ok', true, 'settled', false, 'reason', 'busy');
    end if;
    -- No moving row: a settled fleet reads as already_settled (the raced case); anything else is idle.
    if v_fleet.status in ('present', 'completed') then
      return jsonb_build_object('ok', true, 'settled', false, 'reason', 'already_settled');
    end if;
    return jsonb_build_object('ok', true, 'settled', false, 'reason', 'no_active_movement');
  end if;

  if m.arrive_at > now() then
    return jsonb_build_object('ok', true, 'settled', false, 'reason', 'not_due', 'arrive_at', m.arrive_at);
  end if;

  -- NON-COMBAT SCOPING: never drive combat init from the on-demand path (structurally unreachable for a
  -- main-ship fleet — 0050:104/0053:71 — but enforced HERE regardless).
  if m.target_type = 'location' then
    select activity_type into v_act from locations where id = m.target_location_id;
    if v_act is distinct from 'none' then
      return jsonb_build_object('ok', false, 'reason', 'combat_target_unsupported');
    end if;
  elsif m.target_type <> 'base' then
    return jsonb_build_object('ok', false, 'reason', 'unsupported_target');
  end if;

  -- 0301: through the ONE dispatcher, exactly like the cron. No copied settlement body, ever, and no
  -- second way past a due ambush.
  v_res := public.movement_advance(m.id);
  v_res := coalesce(v_res->'settle', '{}'::jsonb);
  if (v_res->>'settled')::boolean is true then
    return jsonb_build_object('ok', true, 'settled', true,
      'outcome', v_res->>'outcome', 'movement_id', m.id);
  end if;
  return jsonb_build_object('ok', true, 'settled', false, 'reason', 'already_settled');
end;
$$;

revoke execute on function public.command_main_ship_settle_arrival_legacy(uuid) from public, anon;
grant  execute on function public.command_main_ship_settle_arrival_legacy(uuid) to authenticated;


-- ── 12. command_ship_group_go — 0298's TRUE HEAD VERBATIM + the deferral deltas ─────────────────────
-- ⚠ THE BASE MOVED WHILE THIS SLICE WAS BEING WRITTEN. 0292 is NO LONGER this function's head:
-- 20260618000298_retreat_to_any_destination.sql:220 re-created it to record a COORDINATE retreat
-- destination (fleets.retreat_target_x/retreat_target_y, exactly-one-of with
-- retreat_target_location_id under the fleets_retreat_target_one_of CHECK), deleting 0292's
-- retreat_needs_port_destination refusal and adding destination_x/destination_y to both retreat
-- envelopes. This body is spliced from 0298, so that widening survives verbatim; re-emitting from
-- 0292 would have silently reverted it — the exact stale-base class 0293's header records and 0299
-- hit again days later.
-- Steps 1-8 (auth, dark gate, target shape, group lock, members, destination legality incl. the 0219
-- timed-docking translate, the transition guard, and the ENTIRE 0292+0298 mid-combat retreat hunk)
-- are the head, character for character. The deltas are:
--
--   [G1] declare: v_intercept -> v_plan, plus v_due for the redirect branch.
--   [G2] REDIRECT BRANCH — an owed ambush cannot be outrun by re-ordering. Immediately after the
--        movement is locked, any DUE intercept is resolved. If it fires, the fleet is now in combat
--        and this order is REJECTED (intercepted_in_transit) — re-issuing then goes down the step-8
--        retreat path, which is the correct verb for a fleet in a fight. If nothing fires, the
--        ambushes this leg still owed are CANCELLED (movement_superseded): the player legitimately
--        changed course before reaching the zone, and the NEW leg gets its own roll below.
--   [G3] the leg is PLANNED, not evaluated. Nothing is cancelled, nothing is moved, no combat opens.
--   [G4] the envelope. `intercepted` and `intercept_encounter_id` are GONE — this RPC can no longer
--        know either, because the roll's consequence is in the future. `order_outcome` replaces them.
--
-- WHAT THIS FUNCTION NO LONGER DOES, ANYWHERE, UNDER ANY CONDITION: cancel the leg it just minted,
-- call fleet_set_in_space, or create combat.
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
  -- ██ HUNK [G1] (0301): the PLAN envelope from pirate_intercept_plan_leg, and the due-resolution
  -- ██ verdict used by the redirect branch. Neither can move this fleet or open combat by itself.
  v_plan       jsonb;
  v_due        jsonb;
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
          'order_outcome', 'retreat_started',
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
        'order_outcome', 'retreat_destination_updated',
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

    -- ██ HUNK [G2] (0301) — A RE-ORDER MAY NOT OUTRUN AN AMBUSH THAT IS ALREADY OWED. ██████████████
    -- The movement is locked; resolve any DUE intercept in the SAME transaction, before this order
    -- gets to cancel the leg. This closes the window between trigger_at and the next cron tick, in
    -- which a player who saw the fleet touch a zone could otherwise re-order out of the ambush.
    -- If it FIRES the fleet is in combat now and this order is not a move any more — refuse typed and
    -- let the caller re-issue, which lands on step 8's retreat verb. If it does NOT fire, the leg is
    -- legitimately being replaced, so whatever it still owed is cancelled and the NEW leg is rolled
    -- from scratch below. Lock order (movement -> intercept -> fleet) is the resolver's own.
    -- The resolver is deliberately NOT raise-free (a half-opened fight must roll back). This RPC IS
    -- raise-free at its boundary, so the call is fenced — and the fence FAILS THE ORDER rather than
    -- letting it through, because "the ambush could not be resolved" must never mean "so you may go".
    begin
      v_due := public.pirate_intercept_resolve_due_for_movement(v_mv.id);
    exception when others then
      raise warning 'command_ship_group_go: intercept resolution failed for movement % (order REFUSED): %',
        v_mv.id, sqlerrm;
      return jsonb_build_object('ok', false, 'reason', 'intercept_resolution_failed');
    end;
    if coalesce((v_due->>'fired')::boolean, false) then
      return jsonb_build_object('ok', false, 'reason', 'intercepted_in_transit',
                                'encounter_id', v_due->>'encounter_id');
    end if;
    perform public.pirate_intercept_cancel_pending_for_movement(v_mv.id, 'movement_superseded');
    -- ██ END HUNK [G2] ████████████████████████████████████████████████████████████████████████████

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

  -- ██ HUNK [G3] (0301) — THE LEG IS PLANNED, NOT AMBUSHED. ███████████████████████████████████████
  -- The leaf's OWN first statement is the pirate_intercept_enabled gate, so this is a true no-op
  -- while dark. When lit it rolls, records, and RETURNS — the movement it was handed is still
  -- 'moving' when this line finishes, the fleet has not been touched, and no encounter exists. The
  -- ambush it may have scheduled is fired later, by the movement processor, when the fleet arrives
  -- at the zone's edge.
  v_plan := public.pirate_intercept_plan_leg(v_movement);
  -- ██ END HUNK [G3] ███████████████████████████████████████████████████████████████████████████████

  select arrive_at into v_arrive from public.fleet_movements where id = v_movement;

  -- ██ HUNK [G4] (0301) — THE ENVELOPE. The two retired ambush fields are REMOVED, not kept as
  -- ██ shims: this call can no longer know either, and returning a predicted ambush would leak a
  -- ██ random result the player has not lived through yet. Nothing about a planned intercept is
  -- ██ surfaced here at all. movement_eta names the same instant arrive_at always did.
  -- ██ (Their names are deliberately NOT written here: the self-assert greps this very body for them
  -- ██ as MUST-BE-ABSENT, and a probe matching its own explanatory comment is how 0222 aborted every
  -- ██ deploy. The comment stripper would handle it; not relying on the stripper is cheaper.)
  return jsonb_build_object(
    'ok', true,
    'order_outcome', 'movement_started',
    'group_id', v_group,
    'fleet_id', v_fleet,
    'movement_id', v_movement,
    'movement_eta', v_arrive,
    'arrive_at', v_arrive,
    'member_count', v_member_n,
    'redirected', v_redirected,
    'origin_type', v_o_type,
    'target_type', v_t_type,
    'target_x', v_t_x,
    'target_y', v_t_y);
end;
$function$;

comment on function public.command_ship_group_go(uuid, uuid, double precision, double precision) is
  'FLEET-GO (charter §2): the ONE fleet-level mover. Moves a ship_group as a single atomic fleet to a '
  'port OR a world coordinate, from wherever it is; re-issue to redirect. DARK behind '
  'fleet_movement_unified_enabled. S4 TIMED DOCKING (0219) and the 0292 mid-combat retreat '
  'classification as widened by 0298 (a retreat destination may be a PORT or a COORDINATE, '
  'exactly-one-of) are unchanged. PIRATE INTERCEPT (0301): the newly-minted leg is PLANNED — rolled '
  'against every zone it truly enters, with at most one ambush SCHEDULED for the moment the fleet '
  'reaches that zone''s edge. This RPC no longer cancels the leg, moves the fleet or opens combat '
  'under any condition, and no longer returns `intercepted`/`intercept_encounter_id` (it cannot know '
  'them). It returns order_outcome = movement_started | retreat_started | '
  'retreat_destination_updated, plus movement_id and movement_eta. Re-ordering while an ambush is '
  'already DUE resolves it first and is refused with intercepted_in_transit; re-ordering before it is '
  'due cancels it and rolls the new leg.';

revoke all on function public.command_ship_group_go(uuid, uuid, double precision, double precision) from public;
grant execute on function public.command_ship_group_go(uuid, uuid, double precision, double precision) to authenticated;


-- ── 13. command_ship_group_stop — 0218:635-776 VERBATIM + the same due-resolution ───────────────────
-- The brake gets the identical treatment as the re-order, for the identical reason: between trigger_at
-- and the next cron tick there is a window in which a player watching the map could hit Stop to escape
-- an ambush they have already sailed into. The movement is locked here anyway, so resolving costs
-- nothing and closes the window. If it fires, the fleet is in combat and the brake is refused (a fight
-- is left via Retreat, never the brake — the same rule the 0215 sortie guard already enforces).
-- The 0215 sortie guard and the S3 fold hunk are the head, character for character.
create or replace function public.command_ship_group_stop(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_player   uuid := auth.uid();
  v_group    uuid;
  v_fleet    uuid;
  v_fleet_row record;
  v_unified_n integer;
  v_hunting   integer;
  v_mv       record;
  v_x        double precision;
  v_y        double precision;
  v_now      timestamptz := now();
  -- 0301: the due-resolution verdict. Cannot move this fleet or open combat by itself.
  v_due      jsonb;
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gate — reject before ANY read, lock, or write.
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) resolve + LOCK the group. FOR UPDATE, the same first lock the mover takes.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- ── ★ THE 0215 HUNK — the group must not be mid-sortie. A hunt is a commitment of a frozen     ★ ──
  -- ── ★ roster: the player aborts it with Retreat, never the brake. Braking a sortie fleet would ★ ──
  -- ── ★ park it IDLE with its manifest attached and BRICK THE GROUP. LIVE-scoped join, never a   ★ ──
  -- ── ★ bare EXISTS (a finished sortie's manifest is retained up to 14d).                        ★ ──
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');
  if v_hunting > 0 then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;
  -- ── ★ END OF THE 0215 HUNK — the head continues verbatim from here ★ ──────────────────────────

  -- 4) the group's ONE unified fleet.
  select count(*) into v_unified_n
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning');
  if v_unified_n > 1 then
    return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
  end if;
  if v_unified_n = 0 then
    return jsonb_build_object('ok', true, 'group_id', v_group, 'stopped', false, 'reason_code', 'no_fleet');
  end if;

  select * into v_fleet_row
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning')
   for update;
  v_fleet := v_fleet_row.id;

  -- 5) not in flight → nothing to halt. Idempotent.
  if v_fleet_row.active_movement_id is null then
    return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_fleet,
                              'stopped', false, 'reason_code', 'not_moving');
  end if;

  select * into v_mv
    from public.fleet_movements
   where id = v_fleet_row.active_movement_id
   for update;
  if v_mv.id is null or v_mv.status <> 'moving' then
    return jsonb_build_object('ok', true, 'group_id', v_group, 'fleet_id', v_fleet,
                              'stopped', false, 'reason_code', 'already_settled');
  end if;

  -- ██ HUNK [S1] (0301) — THE BRAKE MAY NOT OUTRUN AN AMBUSH THAT IS ALREADY OWED. ████████████████
  -- Same reasoning and same lock order as command_ship_group_go's [G2]. Fired -> the fleet is in a
  -- fight and the brake is refused; not fired -> the leg is legitimately being ended here, so what it
  -- still owed is cancelled with the player's own reason.
  -- Fenced for the same reason as the mover's [G2], and it fails the BRAKE rather than letting it
  -- through: an unresolvable ambush must never be an escape hatch.
  begin
    v_due := public.pirate_intercept_resolve_due_for_movement(v_mv.id);
  exception when others then
    raise warning 'command_ship_group_stop: intercept resolution failed for movement % (brake REFUSED): %',
      v_mv.id, sqlerrm;
    return jsonb_build_object('ok', false, 'reason', 'intercept_resolution_failed');
  end;
  if coalesce((v_due->>'fired')::boolean, false) then
    return jsonb_build_object('ok', false, 'reason', 'intercepted_in_transit',
                              'encounter_id', v_due->>'encounter_id');
  end if;
  perform public.pirate_intercept_cancel_pending_for_movement(v_mv.id, 'player_stop');
  -- ██ END HUNK [S1] ██████████████████████████████████████████████████████████████████████████████

  -- 6) WHERE IT ACTUALLY IS. Byte-identical to the mover's redirect interpolation — a redirect is
  --    "stop here, then go there", so both must agree on "here".
  -- ── ★ THE S3 FOLD HUNK (2 of 2) — the same movement_position_at compose the mover uses.      ★ ──
  select o_x, o_y into v_x, v_y
    from public.movement_position_at(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y,
                                     v_mv.depart_at, v_mv.arrive_at, v_now);
  -- ── ★ END OF THE S3 FOLD HUNK — the 0215 head continues verbatim from here ★ ────────────────

  -- ── WRITES ─────────────────────────────────────────────────────────────────────────────────────
  -- NOTE FOR EVERY FUTURE READER: there is deliberately NO `update main_ship_instances` below.

  update public.fleet_movements
     set status = 'cancelled', resolved_at = v_now
   where id = v_mv.id and status = 'moving';

  -- STOP = HOLD (the 0155 semantic, kept): the fleet holds position in open space at the turn point.
  perform public.fleet_set_in_space(v_fleet, v_x, v_y);

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'fleet_id', v_fleet,
    'stopped', true,
    'cancelled_movement_id', v_mv.id,
    'space_x', v_x,
    'space_y', v_y);
end;
$function$;

comment on function public.command_ship_group_stop(uuid) is
  'FLEET-STOP (charter §2): the ONE fleet-level brake. Halts the group''s fleet and HOLDS it in open '
  'space at the interpolated turn point, immediately re-commandable. Idempotent. Refuses an OPEN '
  'SORTIE (group_on_sortie). PIRATE INTERCEPT (0301): an ambush that is already DUE is resolved '
  'BEFORE the brake takes effect — if it fires the fleet is in combat and the brake is refused '
  '(intercepted_in_transit, abort a fight via Retreat); otherwise the ambushes this leg still owed are '
  'cancelled as player_stop. DARK behind fleet_movement_unified_enabled.';

revoke all on function public.command_ship_group_stop(uuid) from public;
grant execute on function public.command_ship_group_stop(uuid) to authenticated;


-- ── 14. command_ship_group_go_route — 0233:1011-1115 VERBATIM minus ONE now-impossible branch ───────
-- The head short-circuited on `v_first->>'intercepted'` to avoid queueing a route for a fleet that had
-- already been pulled into combat by leg 1. Leg 1 can no longer be intercepted at order time, so that
-- branch is not merely dead — reading a field the mover no longer returns would be a silent
-- always-false. It is DELETED. The equivalent protection now lives where the ambush actually happens:
-- pirate_intercept_resolve_due_for_movement abandons the remaining queue when it fires.
create or replace function public.command_ship_group_go_route(
  p_group_id          uuid,
  p_waypoints         jsonb,
  p_target_location_id uuid default null,
  p_target_x          double precision default null,
  p_target_y          double precision default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_max_wp  integer;
  v_n       integer;
  v_i       integer;
  v_wx      double precision;
  v_wy      double precision;
  v_first   jsonb;
  v_fleet   uuid;
  v_seq     integer;
  c_lo constant double precision := -10000;
  c_hi constant double precision :=  10000;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any read (the reject-before-read posture this whole slice follows).
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'pirate_intercept_disabled');
  end if;

  if p_waypoints is null or jsonb_typeof(p_waypoints) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_waypoints');
  end if;
  v_n := jsonb_array_length(p_waypoints);
  v_max_wp := coalesce(public.cfg_num('pirate_route_max_waypoints'), 3)::integer;
  if v_n < 1 or v_n > v_max_wp then
    return jsonb_build_object('ok', false, 'reason', 'invalid_waypoint_count');
  end if;
  for v_i in 0 .. v_n - 1 loop
    v_wx := (p_waypoints->v_i->>'x')::double precision;
    v_wy := (p_waypoints->v_i->>'y')::double precision;
    if v_wx is null or v_wy is null
       or v_wx = 'NaN'::double precision or v_wx = 'Infinity'::double precision or v_wx = '-Infinity'::double precision
       or v_wy = 'NaN'::double precision or v_wy = 'Infinity'::double precision or v_wy = '-Infinity'::double precision
       or v_wx < c_lo or v_wx > c_hi or v_wy < c_lo or v_wy > c_hi then
      return jsonb_build_object('ok', false, 'reason', 'invalid_waypoint_point');
    end if;
  end loop;

  -- final target shape — the SAME exclusive-or rule as command_ship_group_go.
  if p_target_location_id is not null then
    if p_target_x is not null or p_target_y is not null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
    end if;
  elsif p_target_x is null or p_target_y is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
  end if;

  -- LEG 1: compose the EXISTING mover, unmodified call shape, toward waypoint[0]. Every dark gate,
  -- ownership check, origin-resolution branch, and the intercept ROLL itself all come along for free.
  v_first := public.command_ship_group_go(
    p_group_id, null,
    (p_waypoints->0->>'x')::double precision,
    (p_waypoints->0->>'y')::double precision);
  if coalesce((v_first->>'ok')::boolean, false) is not true then
    return v_first;
  end if;
  v_fleet := (v_first->>'fleet_id')::uuid;

  -- Queue the REMAINING legs (waypoints[1..] as space legs, then the real final target last).
  -- Clear any stale queue first (re-issuing a route is safe / idempotent for the fleet).
  delete from public.fleet_route_legs where fleet_id = v_fleet and player_id = v_player;

  v_seq := 1;
  for v_i in 1 .. v_n - 1 loop
    insert into public.fleet_route_legs (fleet_id, player_id, seq, target_type, target_x, target_y)
    values (v_fleet, v_player, v_seq,
            'space',
            (p_waypoints->v_i->>'x')::double precision,
            (p_waypoints->v_i->>'y')::double precision);
    v_seq := v_seq + 1;
  end loop;

  if p_target_location_id is not null then
    insert into public.fleet_route_legs (fleet_id, player_id, seq, target_type, target_location_id)
    values (v_fleet, v_player, v_seq, 'location', p_target_location_id);
  else
    insert into public.fleet_route_legs (fleet_id, player_id, seq, target_type, target_x, target_y)
    values (v_fleet, v_player, v_seq, 'space', p_target_x, p_target_y);
  end if;

  return v_first || jsonb_build_object('leg_count', v_n + 1, 'queued_legs', v_seq);
end;
$$;

revoke all on function public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision) from public;
grant execute on function public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision) to authenticated;

comment on function public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision) is
  'PIRATE INTERCEPT / waypoint routing: plots a multi-leg route (1-3 intermediate space waypoints + a '
  'final port-or-coordinate target). Leg 1 composes the UNMODIFIED command_ship_group_go (zero '
  'duplicated origin logic); the remaining legs queue into fleet_route_legs and are advanced '
  'leg-by-leg by process_pirate_route_legs. 0301: leg 1 can no longer be intercepted at order time, so '
  'the route is always queued; if an ambush later fires mid-route the resolver abandons the remaining '
  'queue. DARK behind pirate_intercept_enabled.';


-- ── 15. process_pirate_route_legs — 0233:1128-1222 VERBATIM + plan instead of evaluate ──────────────
-- The second leg-minting site. It gets the SAME single authority the mover does; a leg is a leg.
create or replace function public.process_pirate_route_legs()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r          record;
  v_next     record;
  v_stats    jsonb;
  v_speed    double precision;
  v_movement uuid;
  v_loc      record;
  v_count    integer := 0;
begin
  -- DARK GATE FIRST — no-op, zero reads, while the flag is false.
  if not public.cfg_bool('pirate_intercept_enabled') then
    return 0;
  end if;

  for r in
    select f.id as fleet_id, f.player_id, f.group_id, f.space_x, f.space_y
      from public.fleets f
     where f.status = 'idle' and f.location_mode = 'space'
       and f.active_movement_id is null
       and f.group_id is not null and f.main_ship_id is null
       and exists (select 1 from public.fleet_route_legs rl where rl.fleet_id = f.id)
     for update of f skip locked
  loop
    begin
      select * into v_next from public.fleet_route_legs
       where fleet_id = r.fleet_id
       order by seq asc
       limit 1
       for update skip locked;
      if not found then
        continue;
      end if;

      begin
        v_stats := public.calculate_group_expedition_stats(r.player_id, r.group_id, 'none');
        v_speed := (v_stats->'totals'->>'speed')::double precision;
      exception when others then
        v_speed := null;
      end;
      if v_speed is null or not (v_speed > 0) then
        -- The team can no longer be validly folded — abandon the WHOLE remaining route rather than
        -- spin forever retrying a leg that can never mint. The fleet itself is untouched.
        delete from public.fleet_route_legs where fleet_id = r.fleet_id;
        continue;
      end if;

      if v_next.target_type = 'location' then
        select l.id, l.x, l.y, l.zone_id into v_loc
          from public.locations l
         where l.id = v_next.target_location_id and l.status = 'active';
        if v_loc.id is null then
          -- destination went inactive/vanished since the route was plotted — drop just this leg.
          delete from public.fleet_route_legs where id = v_next.id;
          continue;
        end if;
        v_movement := public.movement_create(
          r.player_id, r.fleet_id,
          'space', null, null, null, r.space_x, r.space_y,
          'location', null, null, v_loc.id, v_loc.x, v_loc.y,
          'rally', v_speed);
      else
        v_movement := public.movement_create(
          r.player_id, r.fleet_id,
          'space', null, null, null, r.space_x, r.space_y,
          'space', null, null, null, v_next.target_x, v_next.target_y,
          'rally', v_speed);
      end if;

      perform public.fleet_set_moving(r.fleet_id, v_movement);
      delete from public.fleet_route_legs where id = v_next.id;

      -- EVERY leg gets the SAME roll — one authority, called from every leg-minting site (the mover
      -- via its own hunk, and here for legs 2..N). 0301: it PLANS. This tick no longer opens combat.
      perform public.pirate_intercept_plan_leg(v_movement);

      v_count := v_count + 1;
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_pirate_route_legs: advance failed for fleet % (left queued; retries next tick): %',
          r.fleet_id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.process_pirate_route_legs() from public, anon, authenticated;

comment on function public.process_pirate_route_legs() is
  'PIRATE INTERCEPT / waypoint routing: the queue-advance tick. A SEPARATE pg_cron job. DARK-FIRST '
  'no-op while pirate_intercept_enabled is false. Per-fleet subtransaction isolation (the 0206 '
  'CRON-GUARD lesson). 0301: each minted leg is PLANNED, not ambushed — this tick creates no combat '
  'and moves no fleet; the movement processor fires what the plan owes.';


-- ── 16. THE LEGACY IMMEDIATE-AMBUSH PATH IS DELETED ─────────────────────────────────────────────────
-- pirate_intercept_evaluate_leg was the one function that cancelled a leg, teleported the fleet and
-- opened combat inside the order transaction, and it also carried 0293's engagement restamp and
-- 0294's combat_units translation. Both of its callers (command_ship_group_go, above; and
-- process_pirate_route_legs, above) now call the planner instead, so it has NO callers left. It is
-- DROPPED rather than left dormant: a feature shipping while its predecessor stays live is spaghetti,
-- and a dormant second ambush path would be the worst kind — invisible until something calls it.
drop function if exists public.pirate_intercept_evaluate_leg(uuid);

-- fleet_route_legs gains a documented fourth writer: the resolver clears a fleet's remaining queue
-- when an ambush fires, preserving 0233's own "do not silently resume an abandoned route" decision.
comment on table public.fleet_route_legs is
  'PIRATE INTERCEPT / waypoint routing (prototype): the QUEUE of remaining legs for a plotted route. '
  'fleet_movements keeps its one-active-leg-per-fleet invariant (0007) untouched — this table holds '
  'what comes NEXT. Sole writers: command_ship_group_go_route (inserts) + process_pirate_route_legs '
  '(consumes) + command_ship_group_cancel_route (clears) + pirate_intercept_resolve_due_for_movement '
  '(clears, when an ambush fires and the rest of the route is abandoned — 0301).';


-- ══ 17. SELF-ASSERT — this migration proves its OWN effect or refuses to land ═══════════════════════
-- SCOPE, STATED UP FRONT. It asserts ONLY what THIS migration does. It asserts NO game_config VALUE
-- and no flag (0288's production deploy died demanding a flag the owner had deliberately lit). It
-- asserts NO row count that a concurrent writer could change — process_combat_ticks runs every 3s and
-- process_fleet_movements every 30s, and a count either of them can move is not a proof, it is a
-- coin flip. It holds on a COMPLETELY EMPTY dataset: every behavioural assertion below is run against
-- LITERAL GEOMETRY through the pure leaf, which is exactly why that leaf was built table-free.
--
-- Source probes read CODE, never comments: each body is passed through a comment stripper first (the
-- 0222 lesson — a probe that matches its own comment aborts every deploy, and a probe that matches a
-- comment it also strips passes vacuously forever).
do $a301$
declare
  v_src     text;
  v_other   text;
  v_outcols text[];
  r       record;
  n       integer;
  f       double precision;
  x       double precision;
  y       double precision;
  -- the fixtures. A unit square, an L whose boundary the leg lies ON before entering, a U whose
  -- centroid sits in its own notch, a two-part multipolygon, and a square with a hole.
  c_sq    constant geometry := ST_GeomFromText('POLYGON((0 0,10 0,10 10,0 10,0 0))');
  c_L     constant geometry := ST_GeomFromText('POLYGON((0 5,10 5,10 0,20 0,20 10,0 10,0 5))');
  c_U     constant geometry := ST_GeomFromText('POLYGON((0 0,30 0,30 10,20 10,20 4,10 4,10 10,0 10,0 0))');
  c_multi constant geometry := ST_GeomFromText('MULTIPOLYGON(((30 0,40 0,40 10,30 10,30 0)),((0 0,10 0,10 10,0 10,0 0)))');
  c_hole  constant geometry := ST_GeomFromText('POLYGON((0 0,20 0,20 20,0 20,0 0),(5 5,15 5,15 15,5 15,5 5))');
  function_missing text;
begin
  -- ── (A) THE SHAPE OF THE WORLD AFTER THIS MIGRATION ──────────────────────────────────────────────
  -- The retired path is GONE, not dormant.
  if to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is not null then
    raise exception '0301 FAIL: pirate_intercept_evaluate_leg still exists — the legacy immediate-ambush path was not retired';
  end if;
  -- The new spine exists.
  select string_agg(fn.sig, ', ')
    into function_missing
    from unnest(array[
      'public.pirate_intercept_leg_entry(geometry, geometry)',
      'public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision)',
      'public.pirate_intercept_plan_leg(uuid)',
      'public.pirate_intercept_resolve_due_for_movement(uuid)',
      'public.pirate_intercept_cancel_pending_for_movement(uuid, text)',
      'public.movement_advance(uuid)',
      'public.process_fleet_movements()',
      'public.movement_settle_arrival(uuid)',
      'public.combat_create_encounter(uuid)',
      'public.combat_create_group_encounter(uuid, double precision, double precision)'
    ]) as fn(sig)
   where to_regprocedure(fn.sig) is null;
  if function_missing is not null then
    raise exception '0301 FAIL: missing after this migration: %', function_missing;
  end if;

  -- The geometry leaf's ENTIRE ordered output list, from the catalog.
  -- WHY NOT information_schema.parameters: that view maps pg_proc.proargmodes 't' (a RETURNS TABLE
  -- column) to parameter_mode 'OUT'. It never emits the string 'TABLE', so a probe filtering on
  -- parameter_mode = 'TABLE' matches zero rows FOR EVERY FUNCTION and raises on every apply no matter
  -- what the function returns. That is exactly what the first cut of this migration did, and it is
  -- the 0222 vacuity lesson inverted: a probe that can never be SATISFIED is as bad as one that can
  -- never FAIL. pg_proc is the authority; read it.
  -- Pinned as the whole ordered list rather than a set membership, so a RENAME or a REORDER fails too
  -- — ambush_x/ambush_y must keep those names (0274/0279, two IMMUTABLE typed-zone dispatchers,
  -- validate them by exactly those keys, and src/features/worldeditor/zoneEffectDispatchContract.ts
  -- mirrors them) and entry_fraction must exist for the planner to order zones by.
  select array_agg(p.proargnames[i] order by i)
    into v_outcols
    from pg_proc p, generate_subscripts(p.proargnames, 1) i
   where p.oid = 'public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision)'::regprocedure
     and p.proargmodes[i] = 't';
  if v_outcols is distinct from
     array['zone_id','location_id','exposure_fraction','ambush_x','ambush_y','entry_fraction']::text[] then
    raise exception '0301 FAIL: pirate_intercept_leg_zone_hits returns % — want {zone_id, location_id, exposure_fraction, ambush_x, ambush_y, entry_fraction}', v_outcols;
  end if;

  -- The engagement parameters are MANDATORY. pronargdefaults counts trailing defaulted params; the
  -- whole point of dropping and re-creating this function was to make that number zero.
  if (select pronargdefaults from pg_proc
       where oid = 'public.combat_create_group_encounter(uuid, double precision, double precision)'::regprocedure) <> 0 then
    raise exception '0301 FAIL: combat_create_group_encounter still has defaulted parameters — the engagement point is still optional';
  end if;
  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.proname = 'combat_create_group_encounter') <> 1 then
    raise exception '0301 FAIL: combat_create_group_encounter is overloaded — exactly one row must keep that name (every prosrc-by-proname probe in this repo depends on it)';
  end if;

  -- ── (B) NOTHING BUT THE CREATOR WRITES engagement_x/engagement_y ──────────────────────────────────
  -- This is the probe that would have caught 0294's restamp. It sweeps EVERY function in the schema.
  select string_agg(p.proname, ', ')
    into v_other
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.prokind = 'f'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* 'set[[:space:]]+engagement_x';
  if v_other is not null then
    raise exception '0301 FAIL: % writes engagement_x by UPDATE — combat_create_group_encounter must be the only writer, and it writes it once, on INSERT', v_other;
  end if;

  -- ── (C) EVERY CREATION CALL SUPPLIES COORDINATES ─────────────────────────────────────────────────
  select string_agg(p.proname, ', ')
    into v_other
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.prokind = 'f'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'combat_create_group_encounter[[:space:]]*\([[:space:]]*p_presence[[:space:]]*\)';
  if v_other is not null then
    raise exception '0301 FAIL: % still calls combat_create_group_encounter with a bare presence — every creation call must state where the fight is', v_other;
  end if;
  v_src := regexp_replace((select prosrc from pg_proc where oid = 'public.combat_create_encounter(uuid)'::regprocedure), '--[^\n]*', '', 'g');
  if position('combat_create_group_encounter(p_presence, v_eng_x, v_eng_y)' in v_src) = 0 then
    raise exception '0301 FAIL: combat_create_encounter does not hand a resolved engagement point to the creator';
  end if;

  -- ── (D) ONE DOOR INTO SETTLEMENT ─────────────────────────────────────────────────────────────────
  -- movement_advance is the ONLY thing left that calls movement_settle_arrival.
  select string_agg(p.proname, ', ')
    into v_other
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.prokind = 'f'
     and p.proname <> 'movement_advance'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'movement_settle_arrival[[:space:]]*\(';
  if v_other is not null then
    raise exception '0301 FAIL: % still settles a movement directly — every consumer must go through movement_advance: %', v_other, v_other;
  end if;
  -- ...and it resolves the intercept BEFORE it settles.
  v_src := regexp_replace((select prosrc from pg_proc where oid = 'public.movement_advance(uuid)'::regprocedure), '--[^\n]*', '', 'g');
  if position('pirate_intercept_resolve_due_for_movement' in v_src) = 0
     or position('movement_settle_arrival' in v_src) = 0
     or position('pirate_intercept_resolve_due_for_movement' in v_src) > position('movement_settle_arrival' in v_src) then
    raise exception '0301 FAIL: movement_advance does not resolve a due intercept BEFORE settling the arrival';
  end if;
  -- the processor carries the due-intercept scan and enters through the dispatcher in BOTH loops.
  v_src := regexp_replace((select prosrc from pg_proc where oid = 'public.process_fleet_movements()'::regprocedure), '--[^\n]*', '', 'g');
  if position('lifecycle_state = ''pending''' in v_src) = 0
     or position('pi.trigger_at <= now()' in v_src) = 0 then
    raise exception '0301 FAIL: process_fleet_movements has no due-intercept scan — an ambush mid-leg would wait for the arrival that must never happen';
  end if;
  if (select count(*) from regexp_matches(v_src, 'perform movement_advance\(m\.id\)', 'g')) <> 2 then
    raise exception '0301 FAIL: process_fleet_movements does not enter movement_advance from BOTH of its loops';
  end if;
  if position('status = ''moving'' and arrive_at <= now()' in v_src) = 0 then
    raise exception '0301 FAIL: process_fleet_movements lost the 0206 arrival predicate';
  end if;

  -- ── (E) NO ORDER-TIME AMBUSH SURVIVES ANYWHERE ───────────────────────────────────────────────────
  v_src := regexp_replace((select prosrc from pg_proc where oid = 'public.command_ship_group_go(uuid, uuid, double precision, double precision)'::regprocedure), '--[^\n]*', '', 'g');
  if position('pirate_intercept_plan_leg(v_movement)' in v_src) = 0 then
    raise exception '0301 FAIL: command_ship_group_go does not PLAN the leg it minted';
  end if;
  if position('fleet_set_in_space' in v_src) > 0 then
    raise exception '0301 FAIL: command_ship_group_go still parks a fleet — the order-time ambush was not removed';
  end if;
  if position('''intercepted''' in v_src) > 0 or position('intercept_encounter_id' in v_src) > 0 then
    raise exception '0301 FAIL: command_ship_group_go still returns the deprecated intercepted / intercept_encounter_id fields';
  end if;
  if position('''order_outcome'', ''movement_started''' in v_src) = 0 then
    raise exception '0301 FAIL: command_ship_group_go does not report order_outcome = movement_started';
  end if;
  -- the STOP/re-order evasion window is closed on BOTH verbs.
  if position('pirate_intercept_resolve_due_for_movement(v_mv.id)' in v_src) = 0 then
    raise exception '0301 FAIL: command_ship_group_go re-order does not resolve a DUE ambush before cancelling the leg';
  end if;
  v_src := regexp_replace((select prosrc from pg_proc where oid = 'public.command_ship_group_stop(uuid)'::regprocedure), '--[^\n]*', '', 'g');
  if position('pirate_intercept_resolve_due_for_movement(v_mv.id)' in v_src) = 0
     or position('''player_stop''' in v_src) = 0 then
    raise exception '0301 FAIL: command_ship_group_stop does not resolve a DUE ambush before braking, or does not cancel what the leg still owed';
  end if;
  -- the route advance plans, and the route RPC no longer reads a field that cannot exist.
  v_src := regexp_replace((select prosrc from pg_proc where oid = 'public.process_pirate_route_legs()'::regprocedure), '--[^\n]*', '', 'g');
  if position('pirate_intercept_plan_leg(v_movement)' in v_src) = 0 then
    raise exception '0301 FAIL: process_pirate_route_legs does not PLAN the leg it minted';
  end if;
  v_src := regexp_replace((select prosrc from pg_proc where oid = 'public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision)'::regprocedure), '--[^\n]*', '', 'g');
  if position('''intercepted''' in v_src) > 0 then
    raise exception '0301 FAIL: command_ship_group_go_route still branches on a field the mover no longer returns (a silent always-false)';
  end if;

  -- ── (F) THE LIFECYCLE IS REAL SCHEMA, NOT A CONVENTION ───────────────────────────────────────────
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'pirate_intercepts'
         and column_name in ('lifecycle_state','entry_fraction','entry_x','entry_y','trigger_at','resolved_at','cancelled_at','cancel_reason')) <> 8 then
    raise exception '0301 FAIL: pirate_intercepts is missing lifecycle columns';
  end if;
  if (select is_nullable from information_schema.columns
       where table_schema='public' and table_name='pirate_intercepts' and column_name='lifecycle_state') <> 'NO' then
    raise exception '0301 FAIL: pirate_intercepts.lifecycle_state is nullable — a row with no state is a row no scan can reason about';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'pirate_intercepts_lifecycle_state_check')
     or not exists (select 1 from pg_constraint where conname = 'pirate_intercepts_pending_is_actionable_check') then
    raise exception '0301 FAIL: the pirate_intercepts lifecycle CHECKs are missing';
  end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='pirate_intercepts_pending_due_idx') then
    raise exception '0301 FAIL: the due-scan index is missing — the movement processor would sequential-scan the audit log every 30s';
  end if;
  if not exists (select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
                  where c.relname = 'pirate_intercepts_one_pending_per_movement_uidx' and i.indisunique) then
    raise exception '0301 FAIL: the one-pending-per-movement index is missing or not UNIQUE — two workers could open two fights for one leg';
  end if;
  -- The CHECK is enforced, not decorative: a pending row with no entry geometry must be rejected.
  begin
    insert into public.pirate_intercepts (
      fleet_id, player_id, origin_x, origin_y, target_x, target_y,
      exposure_fraction, combined_stats, risk, roll, hit, lifecycle_state)
    values (
      '00000000-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-000000000000'::uuid,
      0, 0, 1, 1, 0, 0, 0, 0, true, 'pending');
    raise exception '0301 FAIL: a pending intercept with no entry point, no fraction and no trigger_at was ACCEPTED';
  exception
    when check_violation or foreign_key_violation or not_null_violation then null;  -- rejected: correct
  end;

  -- ── (G) THE GEOMETRY, PROVEN — literal shapes through the pure leaf, on an empty database ────────
  -- G1. OUTSIDE -> INSIDE returns the first BOUNDARY point, not the centroid foot.
  select entry_x, entry_y, entry_fraction into x, y, f
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(-5 5,5 5)'), c_sq);
  if f is null or abs(f - 0.5) > 1e-9 or abs(x - 0) > 1e-9 or abs(y - 5) > 1e-9 then
    raise exception '0301 GEOM FAIL G1: outside->inside entry is (%,% @ %), want (0,5 @ 0.5)', x, y, f;
  end if;

  -- G2. ORIGIN STRICTLY INSIDE -> fraction 0, at the origin itself.
  select entry_x, entry_y, entry_fraction into x, y, f
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(5 5,20 5)'), c_sq);
  if f is null or abs(f) > 1e-9 or abs(x - 5) > 1e-9 or abs(y - 5) > 1e-9 then
    raise exception '0301 GEOM FAIL G2: origin-inside entry is (%,% @ %), want (5,5 @ 0)', x, y, f;
  end if;

  -- G3. ENTIRELY INSIDE -> fraction 0.
  select entry_fraction into f
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(2 2,8 8)'), c_sq);
  if f is null or abs(f) > 1e-9 then
    raise exception '0301 GEOM FAIL G3: an entirely-interior leg entered at fraction % (want 0)', f;
  end if;

  -- G4. TANGENT -> NO HIT. Touching a boundary is not entering it.
  select count(*) into n
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(5 15,15 5)'), c_sq);
  if n <> 0 then
    raise exception '0301 GEOM FAIL G4: a corner-tangent leg produced % entry rows (want 0)', n;
  end if;
  -- ...and so is grazing an entire edge without ever getting inside.
  select count(*) into n
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(-5 10,15 10)'), c_sq);
  if n <> 0 then
    raise exception '0301 GEOM FAIL G4b: a leg running along an edge produced % entry rows (want 0)', n;
  end if;

  -- G5. ORIGIN ON THE BOUNDARY: inward -> 0; outward -> NO HIT.
  select entry_fraction into f
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(0 5,5 5)'), c_sq);
  if f is null or abs(f) > 1e-9 then
    raise exception '0301 GEOM FAIL G5a: boundary-origin heading inward entered at % (want 0)', f;
  end if;
  select count(*) into n
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(0 5,-5 5)'), c_sq);
  if n <> 0 then
    raise exception '0301 GEOM FAIL G5b: boundary-origin heading outward produced % entry rows (want 0)', n;
  end if;

  -- G6. BOUNDARY OVERLAP THEN ENTRY -> the LATER, TRUE entry. This is the case a "minimum boundary
  --     intersection" implementation gets wrong: the leg lies ON the L's edge from x=0 to x=10 and
  --     only becomes interior at x=10, so the answer is fraction 0.5, NOT 0.1666...
  select entry_x, entry_fraction into x, f
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(-5 5,25 5)'), c_L);
  if f is null or abs(f - 0.5) > 1e-9 or abs(x - 10) > 1e-9 then
    raise exception '0301 GEOM FAIL G6: overlap-then-entry resolved at x=% fraction=% (want x=10 fraction=0.5) — a boundary run was mistaken for an entry', x, f;
  end if;

  -- G7. MULTIPOLYGON -> the FIRST ENTERED COMPONENT, not the first listed one.
  select entry_x, entry_fraction into x, f
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(-5 5,45 5)'), c_multi);
  if f is null or abs(f - 0.1) > 1e-9 or abs(x - 0) > 1e-9 then
    raise exception '0301 GEOM FAIL G7: multipolygon entry is x=% fraction=% (want x=0 fraction=0.1) — the listed order won instead of the travelled order', x, f;
  end if;

  -- G8. A CONCAVE ZONE DOES NOT USE ITS CENTROID. The U's centroid sits in its own notch; the retired
  --     formula would have answered the foot of the perpendicular from there.
  select entry_x, entry_fraction into x, f
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(-5 2,35 2)'), c_U);
  if f is null or abs(f - 0.125) > 1e-9 or abs(x - 0) > 1e-9 then
    raise exception '0301 GEOM FAIL G8: concave-zone entry is x=% fraction=% (want x=0 fraction=0.125)', x, f;
  end if;
  select ST_X(ST_ClosestPoint(ST_GeomFromText('LINESTRING(-5 2,35 2)'), ST_Centroid(c_U))) into y;
  if abs(x - y) < 1e-6 then
    raise exception '0301 GEOM FAIL G8b: the entry point coincides with the centroid foot (%) — the retired formula is still in play', y;
  end if;

  -- G9. A HOLE IS NOT INSIDE. The leg crosses the outer ring, the hole, and out again; the entry is
  --     the OUTER ring, and the hole never counts as interior.
  select entry_x, entry_fraction into x, f
    from public.pirate_intercept_leg_entry(ST_GeomFromText('LINESTRING(-5 10,25 10)'), c_hole);
  if f is null or abs(x - 0) > 1e-9 then
    raise exception '0301 GEOM FAIL G9: holed-polygon entry is x=% (want x=0, the outer ring)', x;
  end if;

  -- G10. FAIL CLOSED. A MULTILINESTRING leg is NOT silently reinterpreted, and neither is a NULL.
  select count(*) into n
    from public.pirate_intercept_leg_entry(ST_GeomFromText('MULTILINESTRING((-5 5,5 5))'), c_sq);
  if n <> 0 then
    raise exception '0301 GEOM FAIL G10: a MULTILINESTRING leg produced % entry rows — it must fail closed, never be reinterpreted', n;
  end if;
  select count(*) into n from public.pirate_intercept_leg_entry(null, c_sq);
  if n <> 0 then
    raise exception '0301 GEOM FAIL G10b: a NULL leg produced % entry rows', n;
  end if;
  select count(*) into n from public.pirate_intercept_leg_zone_hits(null, 0, 10, 10);
  if n <> 0 then
    raise exception '0301 GEOM FAIL G10c: a NULL origin coordinate produced % zone hits', n;
  end if;

  -- G11. TRIGGER TIME IS A PLAIN INTERPOLATION OF THE LEG'S OWN CLOCK. Proven as arithmetic here so
  --      the planner's one-line expression cannot drift from what this migration claims it computes.
  if (timestamptz '2026-01-01 00:00:00+00'
      + (timestamptz '2026-01-01 00:10:00+00' - timestamptz '2026-01-01 00:00:00+00') * 0.25)
     <> timestamptz '2026-01-01 00:02:30+00' then
    raise exception '0301 FAIL G11: trigger_at interpolation does not land where the fleet does';
  end if;

  raise notice '0301 OK: the ambush is where the leg ENTERS the zone and when the fleet GETS there. '
    'pirate_intercept_leg_entry is the one geometry authority and it is proven on literal shapes — '
    'outside->inside gives the boundary point, an origin already inside gives 0, a wholly-interior leg '
    'gives 0, a tangent and an edge-graze give NOTHING, a boundary run followed by a real entry gives '
    'the LATER entry, a multipolygon gives the first TRAVELLED component, a concave zone does not use '
    'its centroid (and is asserted to differ from the centroid foot), a hole is not inside, and a '
    'MULTILINESTRING/NULL leg fails closed. The order-time ambush is deleted: '
    'pirate_intercept_evaluate_leg no longer exists, command_ship_group_go neither parks a fleet nor '
    'returns intercepted/intercept_encounter_id, and both leg-minting sites PLAN. movement_advance is '
    'the only caller of movement_settle_arrival left in the schema and it resolves before it settles; '
    'process_fleet_movements enters it from BOTH its new due-intercept scan and its unchanged 0206 '
    'arrival scan. combat_create_group_encounter has NO defaulted parameters, exactly one pg_proc row, '
    'and is the only function that writes engagement_x — no function calls it with a bare presence. '
    'The pirate_intercepts lifecycle is enforced by CHECKs (proven by rejecting an unactionable '
    'pending row), a due-scan index and a UNIQUE one-pending-per-movement index. No game_config value '
    'is read or asserted, no flag is written, no row count is asserted, and every geometry assertion '
    'holds on an empty database.';
end $a301$;
