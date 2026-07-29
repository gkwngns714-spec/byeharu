-- 0294 — THE FIGHT MOVES TO WHERE THE FLEET IS. 0293 gave a combat encounter a POSITION of its own
-- (combat_encounters.engagement_x/engagement_y) and parked the ambushed FLEET at that position — and
-- then left the new columns UNREAD by everything that seeds the fight. This migration makes every
-- remaining combat-coordinate decision derive from the engagement anchor instead of locations.x/y.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- THE DEFECT, MEASURED IN PRODUCTION (not inferred)
--   One live encounter, status 'active':
--     combat_encounters.engagement_x/engagement_y = (-136, 80)      <- the ambush point, stamped by 0293
--     fleets.space_x/space_y                      = (-136, 80)      <- correct: 0293 parks the fleet there
--     fleets.status / location_mode               = idle / space    <- correct: the ambush shape
--     combat_units (the fleet's OWN ships)        = (-105, 120) and (-113.79, 141.21)
--     locations.x/y (the linked location)         ~ (-135, 120)
--   Those two unit coordinates are exactly (-135, 120) + 30·(cos 0°, sin 0°) and + 30·(cos 45°,
--   sin 45°) — the radius-30 escort ring combat_create_group_encounter lays out around its anchor.
--   The fleet row is 40 world units from its own battle. What the owner sees is an enemy ship
--   attacking a location their fleet is not in.
--
--   Before 0293 the fleet and the fight were both at the location: wrong, but SELF-CONSISTENT. 0293
--   moved one of the two. 0294 moves the other, and there is no third end state — landing only half
--   of this is worse than either, which is exactly why 0293 deferred it as a whole slice rather than
--   repointing one read at a time.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THE UNITS WERE AT THE LOCATION EVEN THOUGH THE ROW SAYS OTHERWISE
--   0293 hunk [A2] restated the ambush point on the ENCOUNTER ROW after the fact, because the creator
--   cannot learn it: pirate_intercept_evaluate_leg reaches combat_create_group_encounter through
--   presence_create -> activity_start -> combat_create_encounter, a chain that carries no coordinate,
--   and 0293 deliberately refused to thread combat coordinates through the PRESENCE system. So the
--   creator resolved coalesce(p_engagement_x, l.x) with the parameter absent — i.e. the location
--   centre — and seeded the player formation there. [A2] then corrected the row and not the rows that
--   ARE the fight. Hunk [E1] below finishes [A2] in [A2]'s own idiom: restate position after the fact,
--   at the one site that knows the answer.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS MIGRATION CHANGES — FOUR THINGS, ALL OF THEM COORDINATE-RESOLUTION
--   [T2] process_combat_ticks resolves ONE anchor per encounter per tick, at the top of the loop:
--        v_anchor_x := coalesce(e.engagement_x, loc.x). One resolution point, so no branch can be
--        missed. The head's v_loc_x/v_loc_y locals — re-read from `locations` at three separate
--        sites — are RETIRED; those identifiers appear nowhere in the new body's code.
--   [T6/T7] the synthetic enemy wave spawns at the anchor. THIS IS ALSO WAVE ONE: the encounter
--        creator writes no enemy row at all, so every pirate in the game is spawned by these two
--        blocks, and this one line is what put an intercept's pirates at the location centre.
--   [T5/T7] the E3 resolved-plan enemy wave spawns at the anchor (later waves and, when a plan is
--        resolved on the first wipe, the authored waves too).
--   [T3/T4] the retreat / forced-extract return leg DEPARTS from the anchor. movement_create is not a
--        symbolic API — it computes travel_distance and travel_seconds from (origin_x, origin_y) and
--        stores them on the leg — so the homeward leg was departing from a port the fleet never
--        reached: wrong distance, wrong ETA, and a client-drawn path starting where the ship is not.
--   [E0/E1] pirate_intercept_evaluate_leg translates the just-created player formation from the
--        location centre to the ambush point. A RIGID translation (pos := ambush + (pos - centre)),
--        applied microseconds after the INSERT in the same transaction, before any tick has run: the
--        ring geometry, the command-ship-at-centre rule and every inter-unit distance are preserved
--        bit for bit. No combat outcome changes; only the coordinate frame does.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- NULL HANDLING — THE DECISION, AND WHY (engagement_x/y is NULL on every pre-0293 encounter)
--   DECISION: backfill the NON-TERMINAL rows AND keep coalesce at read. Not one or the other.
--   • The backfill is what the LIVE fights need. A fleet already in combat at deploy time must not
--     have to wait for its encounter to end before the fix applies to it, and for a pre-0293 row the
--     backfilled value IS the location centre, so the write changes no behaviour at all — it only
--     removes a NULL. Bounded to status in ('active','retreating'): a terminal encounter is never
--     looped by the tick and never seeds another unit, so backfilling it is pure write amplification
--     over the largest table in the slice, for zero observable effect. Deliberately not done.
--   • The coalesce CANNOT be retired by any backfill, so framing it as a temporary bridge would be
--     false. combat_create_group_encounter still writes NULL by design when the linked location has
--     vanished (0293: "A vanished location leaves both NULL"), so new NULLs are producible after this
--     migration. Removing the fallback would mean a NOT NULL constraint plus a default — a schema
--     change beyond what is needed, which would make encounter creation RAISE in exactly the
--     degraded case the creator currently survives. The coalesce is therefore kept as the LAW —
--     "an unstamped encounter is at its location's centre" — not as a legacy path. As a bonus it is
--     strictly stronger than the head in the vanished-location case: a stamped engagement point now
--     wins over a NULL locations.x, where the head had nothing to fall back to at all.
--
--   The backfill is paired with a ONE-TIME REPAIR of the fights that are already split (section 2).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- PROVENANCE — WHICH BODY WAS COPIED FROM WHERE, AND EVERY HUNK ENUMERATED
--   A. public.process_combat_ticks()
--      COPIED FROM: 20260618000292_retreat_to_chosen_destination.sql:719-1565 — the TRUE head. 0293
--      did not touch this function; 0292 is its newest re-emitter, 0291 the one before that.
--      ⚠ NOT from 0261 and NOT from 0291. Copying 0261 reverts BOTH 0291's sticky-mode fix and 0292's
--      retreat work. Copying 0291 reverts 0292's retreat work. The precondition block below REFUSES
--      to run unless the DEPLOYED body carries both, so a wrong base fails closed instead of silently
--      landing a fourth revert.
--      HUNKS: [T1] declarations — v_loc_x/v_loc_y retired, v_anchor_x/v_anchor_y introduced
--             [T2] the one anchor resolution (and `x, y` appended to the existing per-encounter
--                  `locations` read, so this adds ZERO reads and removes three)
--             [T3] the completion branch's origin re-read of `locations` — DELETED
--             [T4] both movement_create origins take the anchor
--             [T5] the E3 resolved-wave re-read of `locations` — DELETED
--             [T6] the synthetic-wave re-read of `locations` — DELETED
--             [T7] both enemy-spawn INSERTs seed at the anchor
--      EVERYTHING ELSE BYTE-IDENTICAL, INCLUDING: 0242/0291's data-derived v_is_spatial, 0292's
--      chosen-destination retreat (read + clear + re-validate + origin_base_id fallback), the 8s
--      window, the reward lock, the v_offense disarm, the E3 resolver wiring and its fresh-resolve
--      ledger, the wave lifecycle and pacing formulas, every reward formula, the aggregate arm, the
--      logging, and the per-encounter subtransaction contract.
--
--   B. public.pirate_intercept_evaluate_leg(uuid)
--      COPIED FROM: 20260618000293_intercept_ambush_point_engagement_anchor.sql:472-731 — the head,
--      landed today.
--      HUNKS: [E0] `l.x, l.y` appended to the linked-location SELECT (additive; every existing field
--                  and every existing use of v_loc untouched)
--             [E1] the player formation is translated from the location centre to the ambush point,
--                  inside 0293's existing `if v_enc is not null then` guard, immediately after [A2]
--      EVERYTHING ELSE BYTE-IDENTICAL, INCLUDING: the dark gate, the 0276 typed-zone cutover and its
--      fail-closed exits, the stats fail-open, the single roll, the single pirate_intercepts insert,
--      the re-lock/race check, the cancel, all FOUR fleet_set_in_space ambush parks, the 0290
--      zero-manifest guard sited BEFORE presence_create, the presence_create composition, the [A2]
--      engagement stamp, the raise-free `exception when others` contract, and the grants.
--
--   NOT TOUCHED, ON PURPOSE:
--     • presence_request_leave (head 20260616000018:23) — CHECKED, and it does NOT need this
--       treatment. Its two branches are: activity_type 'none', the safe-zone leave, which mints a
--       return_home leg from locations.x/y — correct, because a 'none' presence is only ever created
--       by a real ARRIVAL, so the fleet IS at the location centre and no encounter (hence no
--       engagement point) exists for it; and activity_type 'hunt_pirates', the combat retreat, which
--       creates NO movement at all — it arms the retreat timer and returns NULL, and the return leg
--       is minted later by process_combat_ticks' completion branch, which is [T3]/[T4] above. The
--       origin defect lives entirely in the tick. Editing presence_request_leave would move a correct
--       read for no reason and would put a second retreat authority in play, which 0292's assert
--       explicitly forbids.
--     • combat_flee_pending (0230:194), which reuses the same safe-zone sequence, for the same reason:
--       a telegraphed pending encounter belongs to a fleet that actually docked, and no
--       combat_encounters row (hence no engagement point) exists yet.
--     • combat_create_group_encounter (0293) — already the single resolver, already stores the anchor.
--     • command_ship_group_go (0292), fleet_set_in_space/fleet_set_returning/fleet_destroy (0293),
--       movement_create (0007), process_pirate_route_legs (0233 — it parks nothing and calls the
--       evaluator, so it inherits [E1] without an edit).
--
-- No flag is flipped. No config key is written. No balance number changes — every coordinate change
-- in this migration is a rigid translation or a change of which point a spawn measures from, and no
-- distance, damage, hp, reward or timing formula is altered. Forward-only: 0292 and 0293 are not
-- edited in place.


-- ── 0. PRECONDITIONS — refuse to re-emit over a base we did not build from ─────────────────────────
-- This is the whole lesson of the day, encoded: the same guard was silently reverted three times by
-- authors who re-emitted a body copied from an older migration. A prosrc probe of the DEPLOYED body
-- is the only thing that can catch that, and it must run BEFORE the create-or-replace.
do $pre$
declare
  v_tick text;
  v_eval text;
begin
  if to_regprocedure('public.process_combat_ticks()') is null then
    raise exception '0294: process_combat_ticks() is missing — there is no tick to repoint';
  end if;
  if to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is null then
    raise exception '0294: pirate_intercept_evaluate_leg(uuid) is missing — 0293 must be deployed';
  end if;
  if to_regprocedure('public.combat_create_group_encounter(uuid, double precision, double precision)') is null then
    raise exception '0294: the 3-arg combat_create_group_encounter is missing — 0293 must be deployed';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_encounters' and column_name = 'engagement_x')
     or not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_encounters' and column_name = 'engagement_y') then
    raise exception '0294: combat_encounters.engagement_x/engagement_y are missing — 0293 must be deployed';
  end if;

  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_eval from pg_proc where oid = 'public.pirate_intercept_evaluate_leg(uuid)'::regprocedure;

  -- 0292 must be IN the deployed tick, or the body below (which is 0292's) is not a superset of it.
  if position('select f.retreat_target_location_id into v_ret_loc from fleets f where f.id = e.fleet_id;' in v_tick) = 0 then
    raise exception '0294: the deployed process_combat_ticks does not carry 0292''s chosen-destination retreat — refusing to re-emit from an unknown base';
  end if;
  -- 0242/0291 must be IN the deployed tick. If it is not, something already reverted it and this
  -- migration must not be the thing that quietly papers over that — fail, and let it be looked at.
  if position('v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)' in v_tick) = 0 then
    raise exception '0294: the deployed process_combat_ticks does not derive spatial mode from persisted rows — 0242/0291 has been reverted AGAIN; fix that first, this migration will not mask it';
  end if;
  -- 0293 must be IN the deployed evaluator.
  if position('set engagement_x = v_hit.ambush_x, engagement_y = v_hit.ambush_y' in v_eval) = 0 then
    raise exception '0294: the deployed pirate_intercept_evaluate_leg does not stamp the ambush point — refusing to re-emit from an unknown base';
  end if;
  if position('if v_manifest = 0 then' in v_eval) = 0 then
    raise exception '0294: the deployed evaluator does not carry 0290''s zero-manifest guard — refusing to re-emit from an unknown base';
  end if;
end $pre$;


-- ── 1. THE SCHEMA DOC CATCHES UP (documentation only — no DDL, no column added or altered) ─────────
-- 0293 wrote these comments in the future tense, naming this migration as the follow-up. It landed.
comment on column public.combat_encounters.engagement_x is
  'ENGAGEMENT POINT (0293): the x of the point in space where this fight physically is. An INTERCEPT '
  'encounter records the ambush point — ST_ClosestPoint(leg, zone centroid), the point on the fleet''s '
  'own leg where it met the danger zone. An ordinary location hunt records the location centre. '
  'Resolved and written ONCE by combat_create_group_encounter; an intercept restamps it with the ambush '
  'point. The linked location remains the authority for encounter CONTENT; this column is the authority '
  'for encounter POSITION. CONSUMED SINCE 0294: process_combat_ticks resolves coalesce(engagement_x, '
  'locations.x) ONCE per encounter per tick and every combat coordinate it decides — both enemy wave '
  'spawns, wave one included, and the retreat leg''s origin — derives from that anchor and from no '
  'other read. NULL keeps its meaning ("no recorded engagement point" -> the location centre); 0294 '
  'backfilled every non-terminal row so no live fight depends on that fallback.';
comment on column public.combat_encounters.engagement_y is
  'ENGAGEMENT POINT (0293), consumed since 0294. See combat_encounters.engagement_x.';


-- ── 2. THE ROWS THAT ALREADY EXIST — backfill, then repair the fights that are already split ───────
-- Both statements are bounded to status in ('active','retreating'). A terminal encounter is never
-- looped by the tick, never seeds another unit and never mints another leg; rewriting its rows would
-- be write amplification with no observable effect. See the NULL-HANDLING section in the header.
do $seed$
declare
  v_backfilled integer;
  v_repaired   integer;
begin
  -- (2a) BACKFILL. Every pre-0293 encounter has NULL engagement. For those rows the location centre
  -- IS the point the fight is at, so this write changes no behaviour — it removes a NULL, so a fight
  -- in flight at deploy time is anchored explicitly rather than through the fallback.
  update public.combat_encounters ce
     set engagement_x = l.x, engagement_y = l.y, updated_at = now()
    from public.locations l
   where l.id = ce.location_id
     and ce.status in ('active','retreating')
     and (ce.engagement_x is null or ce.engagement_y is null)
     and l.x is not null and l.y is not null;
  get diagnostics v_backfilled = row_count;

  -- (2b) REPAIR. Now every non-terminal encounter whose engagement point still DIFFERS from its
  -- location centre is, by construction, a 0293-era intercept: the ONLY writer that can produce that
  -- inequality is pirate_intercept_evaluate_leg's [A2] stamp, and in every one of those cases the
  -- creator had already seeded the units at the location centre and [A2] did not move them. (2a) has
  -- just erased the only other way the columns could disagree — a NULL — so this predicate selects
  -- exactly the split fights and nothing else.
  --
  -- The same rigid translation hunk [E1] applies going forward, and it is applied here to BOTH sides:
  -- translating only the player rows would leave the fight split rather than merely misplaced. Every
  -- inter-unit distance, every range check and every damage roll is unaffected — this moves the frame,
  -- not the fight. Positioned rows only; a dark/aggregate encounter has pos_x NULL and is untouched.
  update public.combat_units cu
     set pos_x = ce.engagement_x + (cu.pos_x - l.x),
         pos_y = ce.engagement_y + (cu.pos_y - l.y),
         updated_at = now()
    from public.combat_encounters ce
    join public.locations l on l.id = ce.location_id
   where cu.encounter_id = ce.id
     and ce.status in ('active','retreating')
     and cu.pos_x is not null and cu.pos_y is not null
     and ce.engagement_x is not null and ce.engagement_y is not null
     and l.x is not null and l.y is not null
     and (ce.engagement_x <> l.x or ce.engagement_y <> l.y);
  get diagnostics v_repaired = row_count;

  raise notice '0294 seed: % non-terminal encounter(s) backfilled to their location centre; % combat_unit row(s) rigidly translated onto their encounter''s engagement point',
    v_backfilled, v_repaired;
end $seed$;


-- ══ 3. process_combat_ticks — the 0292:719-1565 TRUE HEAD verbatim + hunks [T1]..[T7] ══════════════
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
  'from PERSISTED DATA ONLY (0242/0291) — never from a live flag. The retreat destination is still '
  'fleets.retreat_target_location_id, read-and-cleared with the origin_base_id fallback (0292). '
  'Engine-only: no client role may execute it.';

-- CREATE OR REPLACE preserves the existing ACL; this function has never been client-executable and
-- this migration does not change that. No grant statement is emitted, exactly as 0291/0292 emitted
-- none — the self-assert below proves the posture rather than re-asserting it by DDL.


-- ══ 4. pirate_intercept_evaluate_leg — the 0293:472-731 head verbatim + hunks [E0] [E1] ════════════
-- WHY THIS FUNCTION IS IN THIS SLICE AT ALL: section 3 makes the ENEMY waves spawn at the engagement
-- anchor. The PLAYER formation is seeded once, at creation, by combat_create_group_encounter — and on
-- the intercept path that creator is reached through a presence chain that carries no coordinate, so
-- it anchors on the location centre (0293 [A2] restated the point on the encounter row only). Shipping
-- section 3 alone would therefore spawn pirates at the ambush point while the player's own ships stay
-- ringed around the location — the two sides of the fight starting 40 world units apart, which is the
-- exact half-landed state 0293's header warned is worse than either end state. Both halves, one slice.
create or replace function public.pirate_intercept_evaluate_leg(p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv       record;
  v_fleet    record;
  v_hit      record;
  v_group    uuid;
  v_manifest integer;   -- 0290: rows frozen into the sortie manifest; ZERO must not open combat
  v_stats    jsonb;
  v_combined double precision;
  v_risk     double precision;
  v_roll     double precision;
  v_hitbool  boolean;
  v_now      timestamptz := now();
  v_loc      record;
  v_presence uuid;
  v_enc      uuid;
  v_log_id   uuid;
  -- 0276 cutover locals. Only ever populated on the typed-zone branch.
  v_typed    boolean;
  v_req      jsonb;
  v_res      jsonb;
  v_pe       jsonb;
begin
  -- DARK GATE FIRST — before any read at all.
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('hit', false, 'reason', 'dark');
  end if;

  select id, fleet_id, player_id, origin_x, origin_y, target_x, target_y, status
    into v_mv
    from public.fleet_movements
   where id = p_movement_id;
  if not found or v_mv.status <> 'moving' then
    return jsonb_build_object('hit', false, 'reason', 'not_moving');
  end if;

  select id, player_id, group_id, main_ship_id
    into v_fleet
    from public.fleets
   where id = v_mv.fleet_id;
  -- This hook only ever fires from the unified GROUP mover / route advance — the ONLY shapes that
  -- mint main_ship_id NULL + group_id SET fleets. Anything else (a legacy per-ship or unit fleet) is
  -- simply not this feature's concern for the prototype — skip cleanly, never guess.
  if not found or v_fleet.group_id is null or v_fleet.main_ship_id is not null then
    return jsonb_build_object('hit', false, 'reason', 'not_group_fleet');
  end if;
  v_group := v_fleet.group_id;

  -- ── 0276 CUTOVER POINT ──────────────────────────────────────────────
  -- Exactly ONE path decides, chosen once, here. The branches are never both run for side effects:
  -- whichever is authoritative produces v_hit, and everything downstream — the roll, the
  -- pirate_intercepts log, the cancel, the ambush — is shared and unchanged. With the flag dark
  -- (its seeded state) this is byte-for-byte the legacy 0233 decision.
  v_typed := coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), false);

  if not v_typed then
    -- LEGACY, authoritative while the flag is dark: deepest crossing wins (highest
    -- exposure_fraction); `limit 1` needs SOME order to be deterministic.
    select * into v_hit
      from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y)
     order by exposure_fraction desc, zone_id asc
     limit 1;
    if not found then
      return jsonb_build_object('hit', false, 'reason', 'no_crossing');
    end if;
  else
    -- TYPED-ZONE: the same geometry, but the decision comes from the pure V1 planner, so selection
    -- follows declared EFFECTS rather than the bare existence of a polygon. A zone carrying no
    -- pirate_intercept effect row is simply not planned — that is the point of the platform.
    v_req := public.typed_zone_pirate_candidates_v1(
               p_movement_id, v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, 0);
    v_res := public.typed_zone_effect_dispatch_v1(v_req);
    -- FAIL CLOSED, NEVER FAIL OPEN. A planner that cannot answer must not silently fall back to the
    -- legacy path — that would make the cutover unobservable and hide the fault — and must not
    -- invent an interception. It leaves the leg alone, exactly as 'no_crossing' does.
    if (v_res->>'ok') <> 'true' then
      raise warning 'pirate_intercept_evaluate_leg: typed-zone dispatch rejected movement % (leg left UNINTERRUPTED): %',
        p_movement_id, v_res->'error';
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
    if jsonb_array_length(v_res->'plan'->'planned_effects') = 0 then
      return jsonb_build_object('hit', false, 'reason', 'no_crossing');
    end if;
    v_pe := v_res->'plan'->'planned_effects'->0;
    -- Re-read the geometry row for the PLANNED zone: location_id and the ambush point drive the
    -- shared downstream, and they must come from the same authority the legacy branch uses.
    select h.* into v_hit
      from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y) h
     where h.zone_id = (v_pe->>'zone_id')::uuid;
    if not found then
      raise warning 'pirate_intercept_evaluate_leg: planned zone % is not among the leg hits for movement % (leg left UNINTERRUPTED)',
        v_pe->>'zone_id', p_movement_id;
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
  end if;

  -- combined stats: reuse the SAME group-stats adapter the mover already calls for speed (D0, 0166).
  -- Fail OPEN on any adapter raise (an illegal member state etc.) — treat as unknown/weak (combined=0,
  -- the conservative choice) rather than let a stats bug break a player's movement command.
  begin
    v_stats := public.calculate_group_expedition_stats(v_fleet.player_id, v_group, 'none');
    v_combined := coalesce((v_stats->'totals'->>'combat_power')::double precision, 0)
                + coalesce((v_stats->'totals'->>'survival')::double precision, 0);
  exception when others then
    v_combined := 0;
  end;

  -- The typed branch resolves risk from THIS zone's own effect config (per-zone overrides coalesced
  -- against the globals). Recomputing with pirate_intercept_compute_risk here would read the globals
  -- only and silently re-globalise a zone the owner had deliberately tuned. The candidate request is
  -- rebuilt with the real combined stats — it was first built with 0, before the stats adapter ran.
  if v_typed then
    v_res := public.typed_zone_effect_dispatch_v1(
               jsonb_set(v_req, '{event,combined_stats}', to_jsonb(v_combined)));
    if (v_res->>'ok') <> 'true' or jsonb_array_length(v_res->'plan'->'planned_effects') = 0 then
      raise warning 'pirate_intercept_evaluate_leg: typed-zone re-plan failed for movement % (leg left UNINTERRUPTED)',
        p_movement_id;
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
    v_risk := (v_res->'plan'->'planned_effects'->0->>'risk')::double precision;
  else
    v_risk := public.pirate_intercept_compute_risk(v_combined, v_hit.exposure_fraction);
  end if;
  v_roll    := random();
  v_hitbool := v_roll < v_risk;

  insert into public.pirate_intercepts (
    movement_id, fleet_id, player_id, zone_id, location_id,
    origin_x, origin_y, target_x, target_y, exposure_fraction,
    combined_stats, risk, roll, hit)
  values (
    p_movement_id, v_fleet.id, v_fleet.player_id, v_hit.zone_id, v_hit.location_id,
    v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, v_hit.exposure_fraction,
    v_combined, v_risk, v_roll, v_hitbool)
  returning id into v_log_id;

  if not v_hitbool then
    return jsonb_build_object('hit', false, 'risk', v_risk, 'roll', v_roll, 'zone_id', v_hit.zone_id);
  end if;

  -- ── THE AMBUSH ───────────────────────────────────────────────────────────────────────────────
  -- Re-lock + re-check: a concurrent brake/redirect may have resolved this movement between the
  -- first (unlocked) read above and here. Never double-trigger a settled/cancelled leg.
  perform 1 from public.fleet_movements where id = p_movement_id and status = 'moving' for update;
  if not found then
    update public.pirate_intercepts set hit = false, note = 'race_lost' where id = v_log_id;
    return jsonb_build_object('hit', false, 'reason', 'race_lost');
  end if;

  update public.fleet_movements set status = 'cancelled', resolved_at = v_now where id = p_movement_id;

  if v_hit.location_id is null then
    -- STANDALONE drawn zone (no linked pirate_hunt location): the documented combat stub. No
    -- location means no presence/encounter is possible without inventing one — instead the ambush
    -- is made TANGIBLE by forcing the fleet to a stop at the ambush point, the SAME leaf the brake
    -- (command_ship_group_stop, 0215/0218) uses to park a fleet mid-flight. Not a no-op.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'standalone_zone_stub_forced_stop' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'standalone_zone_stub', 'risk', v_risk, 'roll', v_roll);
  end if;

  -- 0294: l.x, l.y APPENDED — the creator (reached three calls below) anchors the player formation
  -- on the linked location's centre, so hunk [E1] needs that centre to translate the formation off it.
  -- Every existing field and every use of v_loc is untouched.
  select l.id, l.zone_id, z.sector_id, l.x, l.y
    into v_loc
    from public.locations l
    join public.zones z on z.id = l.zone_id
   where l.id = v_hit.location_id and l.status = 'active';
  if v_loc.id is null then
    -- the linked location vanished/deactivated since the zone was drawn/seeded — fail open: park,
    -- no combat, rather than reference a location that can no longer host a presence.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'location_missing' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'location_missing', 'risk', v_risk, 'roll', v_roll);
  end if;

  -- ██ HUNK [A1] (0293) — THE TELEPORT FIX. THE WHOLE POINT OF THIS MIGRATION. ██████████████████████
  -- This line used to be a call to the "arrived at the destination" leaf, which writes
  -- status='present', location_mode='location', current_location_id=<the linked location> — one
  -- UPDATE that stands the fleet at the far end of a journey it never completed. The leg had just
  -- been CANCELLED two statements above; there is no segment, no duration, nothing to interpolate.
  -- The fleet was ambushed at v_hit.ambush_x/ambush_y — ST_ClosestPoint(this leg, zone centroid), the
  -- point on the fleet's OWN path where it met the zone — so that is where it stops, via the identical
  -- leaf the standalone branch (above), the vanished-location fail-open (above) and the 0290
  -- zero-manifest guard (below) already use. ALL FOUR ambush exits now park at the same computed
  -- point; no exit from this function writes a position the fleet did not travel to.
  -- The linked location is NOT discarded — it stays the encounter's identity and owns the presence
  -- created below. It has simply stopped being the coordinate authority.
  perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);

  -- Freeze the sortie MANIFEST — byte-identical INSERT shape to send_ship_group_hunt's sole-writer
  -- freeze (0168:304-306), so combat_create_encounter's manifest-gated branch (0168) routes this
  -- fleet into combat_create_group_encounter exactly as a deliberate hunt does. ON CONFLICT DO
  -- NOTHING: idempotent against a (should-be-impossible) re-entry.
  insert into public.group_sortie_members (fleet_id, main_ship_id, player_id)
  select v_fleet.id, msi.main_ship_id, v_fleet.player_id
    from public.main_ship_instances msi
   where msi.group_id = v_group and msi.player_id = v_fleet.player_id
  on conflict (fleet_id, main_ship_id) do nothing;
  get diagnostics v_manifest = row_count;

  -- 0290 ZERO-MANIFEST GUARD. The freeze above reads LIVE main_ship_instances.group_id, so it
  -- can legitimately return no rows (an empty/disbanded group, every ship reassigned). 0168's
  -- combat_create_encounter is manifest-GATED: with no manifest it takes the legacy branch and
  -- inserts combat_units from fleet_units -- a table a TEAM-SORTIE fleet has no rows in (0168:276
  -- creates the fleet and never populates it; 0169:222 documents exactly this). The result is an
  -- encounter with ZERO combat_units: nothing to draw on the map, nothing to fight, and
  -- player_power_start = 0 because fleet_get_power sums the same empty table.
  --
  -- 0168:478-480 asserts that branch is "UNREACHABLE IN PROD" because send_ship_group_hunt is
  -- the manifest's sole writer. That expired the moment THIS function became a second manifest
  -- writer. Rather than reopen the frozen legacy creator, refuse here: an ambush that cannot
  -- field a single ship is not a fight. Reuse the EXISTING fail-open exit (location_missing's
  -- shape) -- park the fleet at the ambush point it actually reached, log why, no combat.
  -- 0293: the park is now REDUNDANT here (the fleet was already parked at the identical point by
  -- hunk [A1] above) and is KEPT anyway, unchanged. It is idempotent, it costs one UPDATE on a rare
  -- path, and it keeps this guard self-sufficient rather than dependent on a caller three statements
  -- away — which is precisely what made it a guard worth adding.
  if v_manifest = 0 then
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'empty_manifest' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'empty_manifest', 'risk', v_risk, 'roll', v_roll);
  end if;

  -- presence_create -> activity_start('hunt_pirates') -> combat_create_encounter -> (manifest exists)
  -- -> combat_create_group_encounter. FOUR frozen functions composed, ZERO re-created.
  v_presence := public.presence_create(v_fleet.player_id, v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'hunt_pirates');

  select id into v_enc from public.combat_encounters where presence_id = v_presence order by created_at desc limit 1;
  update public.pirate_intercepts set encounter_id = v_enc, presence_id = v_presence where id = v_log_id;

  -- ██ HUNK [A2] (0293) — ENCOUNTER IDENTITY vs ENCOUNTER POSITION. ████████████████████████████████
  -- The creator resolved this encounter's engagement point from the linked location's centre: the
  -- presence chain (presence_create -> activity_start -> combat_create_encounter) carries no
  -- coordinate, and threading combat coordinates through the PRESENCE system to change that would be
  -- the wrong coupling for the wrong reason. So the ONE authority that knows the real answer — this
  -- function, which computed the ambush point — restates it on the row the creator just wrote. The
  -- encounter's identity (location_id, its pirates, its rewards, its presence) is untouched; only its
  -- POSITION is corrected, and it is corrected to the same v_hit.ambush_x/ambush_y the fleet is
  -- parked at, so the fleet and the fight it is in agree on where they are.
  -- Guarded on v_enc: if the creator produced no encounter there is nothing to stamp.
  if v_enc is not null then
    update public.combat_encounters
       set engagement_x = v_hit.ambush_x, engagement_y = v_hit.ambush_y
     where id = v_enc;

    -- ██ HUNK [E1] (0294) — [A2] FINISHED. THE FLEET AND ITS OWN SHIPS MUST AGREE ON WHERE THEY ARE. █
    -- [A2] restated the encounter's POSITION on the encounter ROW. It did not restate it on the rows
    -- that ARE the fight. combat_create_group_encounter ran three calls up the presence chain with no
    -- engagement argument (the chain carries no coordinate — 0293 deliberately refused to thread one
    -- through the PRESENCE system), so it resolved the anchor to the linked location's centre and
    -- seeded the player formation there: command ship at the centre, escorts on the ring. Measured in
    -- production: fleet row parked at the ambush point (-136, 80) by [A1], its own combat_units on a
    -- radius-30 ring around the LOCATION centre (-135, 120). The owner sees ships being attacked at a
    -- location their fleet is not in.
    --
    -- The formation is translated, not re-derived: pos := ambush + (pos - location centre). Nothing
    -- has moved yet (these rows were INSERTed microseconds ago, in this same transaction, and the
    -- tick has not run), so the offset is exactly the formation offset the creator laid out — the
    -- ring geometry, the command-ship-at-centre rule and the escort ordering are preserved bit for
    -- bit, and no distance between any two units changes. It is a rigid move of the whole fight to
    -- the point the fleet is standing at, so it alters no combat outcome, only the coordinate frame.
    --
    -- Guarded three ways: only positioned rows (a dark/aggregate encounter has pos_x NULL and is
    -- skipped entirely), and only when the location actually has a coordinate to measure the offset
    -- from. Any of those NULL and the statement matches nothing — the pre-0294 shape, unchanged.
    -- WHY HERE and not in the creator: the creator does not know the ambush point and must not learn
    -- it through presence. This function computed it; this function is where position is restated.
    -- The encounter's IDENTITY is still untouched — location_id, its pirates, its rewards and its
    -- presence are exactly what [A2] left them.
    update public.combat_units cu
       set pos_x = v_hit.ambush_x + (cu.pos_x - v_loc.x),
           pos_y = v_hit.ambush_y + (cu.pos_y - v_loc.y),
           updated_at = now()
     where cu.encounter_id = v_enc
       and cu.pos_x is not null and cu.pos_y is not null
       and v_loc.x is not null and v_loc.y is not null;
  end if;

  return jsonb_build_object(
    'hit', true, 'risk', v_risk, 'roll', v_roll,
    'location_id', v_loc.id, 'presence_id', v_presence, 'encounter_id', v_enc);
exception
  when others then
    raise warning 'pirate_intercept_evaluate_leg: unexpected error for movement % (leg left UNINTERRUPTED): %',
      p_movement_id, sqlerrm;
    return jsonb_build_object('hit', false, 'reason', 'internal_error');
end;
$$;

-- The 0293 ACL posture, restated on the unchanged signature. CREATE OR REPLACE preserves grants; these
-- lines are idempotent and widen nothing.
revoke execute on function public.pirate_intercept_evaluate_leg(uuid) from public, anon, authenticated;
grant execute on function public.pirate_intercept_evaluate_leg(uuid) to service_role;

comment on function public.pirate_intercept_evaluate_leg(uuid) is
  'PIRATE INTERCEPT (0233) + TYPED-ZONE CUTOVER (0276) + ZERO-MANIFEST GUARD (0290) + AMBUSH-POINT '
  'PARK (0293) + AMBUSH-POINT FORMATION (0294). While '
  'typed_zone_pirate_intercept_runtime_enabled is false, zone selection and risk behave byte-for-byte '
  'as 0233 shipped them; while true they come from the pure V1 typed-zone planner. 0290: a sortie '
  'manifest that freezes ZERO rows opens NO combat. 0293: EVERY ambush exit parks the fleet at the '
  'computed ambush point via fleet_set_in_space, and the ambush point is restated on '
  'combat_encounters.engagement_x/engagement_y. 0294: the player formation the creator seeded at the '
  'linked location''s centre is RIGIDLY TRANSLATED onto that same ambush point, so the fleet, its own '
  'ships and the encounter row all agree on where the fight is; the translation preserves the ring '
  'geometry and every inter-unit distance exactly. Exactly one path decides; a planner failure leaves '
  'the leg UNINTERRUPTED rather than falling back.';


-- ══ 5. SELF-ASSERT — the migration proves its OWN effect or refuses to land ════════════════════════
-- SCOPE OF THIS PROOF, STATED UP FRONT: it asserts only what THIS migration does. It asserts NO
-- game_config VALUE. Four migrations today failed or nearly failed by asserting operator state —
-- 0288's production deploy died demanding typed_zone_authoring_enabled be false when the owner had
-- deliberately lit it. A flag's value is the owner's to choose; what a migration may promise is that
-- it did not write one, and that is the form used below.
--
-- PROSRC-ASSERT COUPLING (the 0221/0222/0234/0262/0291/0293 house lesson): `--` line comments are
-- stripped from every body before probing, so the banners above may NAME the identifiers and calls
-- this migration removes without the probes for their absence tripping over the explanation.
do $anchor_assert$
declare
  v_tick   text;
  v_eval   text;
  v_bwin   text;      -- the tick source between the completion branch's head and its tail anchor
  v_bstart integer;
  v_bend   integer;
  v_tok    text;
  v_n      integer;
  v_bad    integer;
begin
  select count(*) into v_n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_n <> 1 then
    raise exception '0294 FAIL: % pg_proc rows named process_combat_ticks (want exactly 1) — every prosrc-by-proname assert in the repo reads this name', v_n;
  end if;
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_eval from pg_proc where oid = 'public.pirate_intercept_evaluate_leg(uuid)'::regprocedure;
  if v_tick is null or v_eval is null then
    raise exception '0294 FAIL: process_combat_ticks / pirate_intercept_evaluate_leg missing after this migration';
  end if;
  v_tick := regexp_replace(v_tick, '--[^' || chr(10) || ']*', '', 'g');
  v_eval := regexp_replace(v_eval, '--[^' || chr(10) || ']*', '', 'g');

  -- ── (1) THE POSITION LAW: the tick derives combat position from the ENGAGEMENT ANCHOR ───────────
  -- (1a) there is exactly ONE resolution point, and it is the coalesce.
  if strpos(v_tick, 'v_anchor_x := coalesce(e.engagement_x, loc.x);') = 0
     or strpos(v_tick, 'v_anchor_y := coalesce(e.engagement_y, loc.y);') = 0 then
    raise exception '0294 FAIL: the tick does not resolve the engagement anchor — combat position is not derived from combat_encounters.engagement_x/y';
  end if;
  -- (1b) the ONLY read of the encounter's location is the CONTENT read, and it now carries x/y so the
  --      anchor costs no extra round trip. Any second `where id = e.location_id` read is a coordinate
  --      read that escaped the repoint.
  if strpos(v_tick, 'select base_difficulty, reward_tier, max_presence_seconds, x, y into loc from locations where id = e.location_id;') = 0 then
    raise exception '0294 FAIL: the per-encounter locations read does not carry x/y — the anchor would need a second read';
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'from locations where id = e.location_id', '')))
         / length('from locations where id = e.location_id');
  if v_n <> 1 then
    raise exception '0294 FAIL: the tick reads the encounter''s location % time(s), want exactly 1 (the CONTENT read) — a coordinate read survived', v_n;
  end if;
  -- (1c) `locations` is touched exactly twice in the whole body: that content read, and 0292's
  --      re-validation of the player's chosen retreat destination. Nothing else.
  v_n := (length(v_tick) - length(replace(v_tick, 'from locations', ''))) / length('from locations');
  if v_n <> 2 then
    raise exception '0294 FAIL: the tick touches locations % time(s), want exactly 2 (the content read + 0292''s retreat-destination re-validation)', v_n;
  end if;
  -- (1d) the head's coordinate locals are GONE, so no site can silently keep using a location centre.
  if strpos(v_tick, 'v_loc_x') <> 0 or strpos(v_tick, 'v_loc_y') <> 0 then
    raise exception '0294 FAIL: the tick still carries the head''s v_loc_x/v_loc_y location-coordinate locals';
  end if;
  -- (1e) every consuming site takes the anchor: BOTH enemy spawns and BOTH retreat-leg origins.
  v_n := (length(v_tick) - length(replace(v_tick, 'v_anchor_x, v_anchor_y, v_enemy_speed,', '')))
         / length('v_anchor_x, v_anchor_y, v_enemy_speed,');
  if v_n <> 2 then
    raise exception '0294 FAIL: % of 2 enemy-wave spawns seed at the engagement anchor (the synthetic wave — which is also WAVE ONE — and the E3 resolved wave)', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'e.location_id, v_anchor_x, v_anchor_y,', '')))
         / length('e.location_id, v_anchor_x, v_anchor_y,');
  if v_n <> 2 then
    raise exception '0294 FAIL: % of 2 retreat/extract return legs depart from the engagement anchor — the homeward leg still departs from a port the fleet never reached', v_n;
  end if;
  -- (1f) six uses in total: the declaration, the one resolution, two spawns, two leg origins. A
  --      seventh would mean a site was added without being named in the header's hunk list.
  v_n := (length(v_tick) - length(replace(v_tick, 'v_anchor_x', ''))) / length('v_anchor_x');
  if v_n <> 6 then
    raise exception '0294 FAIL: v_anchor_x appears % time(s), want exactly 6 (declaration, resolution, 2 enemy spawns, 2 leg origins)', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'v_anchor_y', ''))) / length('v_anchor_y');
  if v_n <> 6 then
    raise exception '0294 FAIL: v_anchor_y appears % time(s), want exactly 6', v_n;
  end if;
  -- (1g) the anchor is resolved BEFORE it is consumed, on every path (one resolution, at the top).
  if strpos(v_tick, 'v_anchor_x := coalesce(e.engagement_x, loc.x);')
     > strpos(v_tick, 'e.location_id, v_anchor_x, v_anchor_y,')
     or strpos(v_tick, 'v_anchor_x := coalesce(e.engagement_x, loc.x);')
        > strpos(v_tick, 'v_anchor_x, v_anchor_y, v_enemy_speed,') then
    raise exception '0294 FAIL: the anchor is consumed before it is resolved';
  end if;

  -- ── (2) INVARIANT (a), RE-STATED VERBATIM — 0242, restored by 0291, preserved by 0292, preserved
  --        HERE. An invariant living in a function body must be re-asserted by EVERY migration that
  --        re-emits that body, or it survives only until the next author copies from a stale file.
  --        This exact line has been reverted three times (0260, 0261, and 0292's first draft). ─────
  if position('v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)' in v_tick) = 0 then
    raise exception '0294 FAIL: the tick no longer derives spatial mode from persisted rows (0242/0291 reverted a FOURTH time)';
  end if;
  if position('v_is_spatial := v_spatial_combat_enabled' in v_tick) <> 0 then
    raise exception '0294 FAIL: the flag-conjoined spatial mode is back — darkening the flag would flip a live spatial fight onto the aggregate arm and fold enemy rows into the player total';
  end if;
  if position('cfg_bool(''spatial_combat_enabled'')' in v_tick) <> 0 then
    raise exception '0294 FAIL: the tick reads spatial_combat_enabled again; mode must come from data alone';
  end if;
  -- EIGHT cfg_bool reads, the 0291/0292 count. Nine means the spatial flag read came back with a
  -- stale-base re-emission; anything else means this slice added or dropped a gate, which it must not.
  v_n := (length(v_tick) - length(replace(v_tick, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 8 then
    raise exception '0294 FAIL: the tick carries % cfg_bool call(s) (want 8 — the 0291/0292 count; this slice adds no gate)', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception '0294 FAIL: the tick carries % random( call(s) (want the head''s 2 — this slice adds no randomness)', v_n;
  end if;

  -- ── (3) INVARIANT (b), RE-STATED — 0292's retreat work is intact inside the branch this slice
  --        edits. [T3]/[T4] change the leg's ORIGIN and nothing else about the branch. ─────────────
  v_bstart := strpos(v_tick, 'if v_retreat_done or v_forced then');
  v_bend   := strpos(v_tick, 'perform fleet_set_returning(e.fleet_id, v_mv);');
  if v_bstart = 0 or v_bend = 0 or v_bend < v_bstart then
    raise exception '0294 FAIL: the tick''s completion branch is not recognisable';
  end if;
  v_bwin := substr(v_tick, v_bstart, v_bend - v_bstart);
  if strpos(v_bwin, 'select f.retreat_target_location_id into v_ret_loc from fleets f where f.id = e.fleet_id;') = 0 then
    raise exception '0294 FAIL: the completion branch does not read the chosen retreat destination (0292 reverted)';
  end if;
  if strpos(v_bwin, 'update fleets set retreat_target_location_id = null') = 0 then
    raise exception '0294 FAIL: the completion branch does not CONSUME (clear) the chosen destination — it would leak into the next sortie (0292 reverted)';
  end if;
  if strpos(v_bwin, 'l.id = v_ret_loc and l.status = ''active''') = 0 then
    raise exception '0294 FAIL: the chosen destination is used without re-validating it (0292 reverted)';
  end if;
  if strpos(v_bwin, '''space'', null, null, null, v_dest_x, v_dest_y, ''return_home'', v_speed);') = 0 then
    raise exception '0294 FAIL: no leg is minted toward the chosen destination (0292 reverted)';
  end if;
  if strpos(v_bwin, 'select origin_base_id into v_base_id from fleets where id = e.fleet_id;') = 0
     or strpos(v_bwin, '''base'', v_base_id, null, null, v_base_x, v_base_y, ''return_home'', v_speed);') = 0 then
    raise exception '0294 FAIL: the origin_base_id fallback was lost (0292 reverted)';
  end if;
  -- BOTH arms of that fallback now depart from the anchor — the whole point of [T4].
  v_n := (length(v_bwin) - length(replace(v_bwin, 'e.location_id, v_anchor_x, v_anchor_y,', '')))
         / length('e.location_id, v_anchor_x, v_anchor_y,');
  if v_n <> 2 then
    raise exception '0294 FAIL: only % of the completion branch''s 2 movement_create arms departs from the engagement anchor', v_n;
  end if;
  -- the 8s window, the disarm and the reward lock are untouched.
  if strpos(v_tick, 'v_retreat_delay := coalesce(cfg_num(''retreat_delay_seconds''), 8);') = 0
     or strpos(v_tick, 'v_retreat_done := e.status=''retreating'' and e.retreat_started_at is not null') = 0
     or strpos(v_tick, 'and now() - e.retreat_started_at >= make_interval(secs => v_retreat_delay);') = 0 then
    raise exception '0294 FAIL: the 8-second retreat window lines are not the head''s';
  end if;
  if strpos(v_tick, 'v_offense  := (e.status = ''active'');') = 0
     or strpos(v_tick, 'v_offense      := (e.status = ''active'');') = 0 then
    raise exception '0294 FAIL: the retreating-fleet disarm (v_offense) was altered in one of the two combat arms';
  end if;
  if strpos(v_tick, 'v_cleared := v_offense and v_e_after <= 0;') = 0
     or strpos(v_tick, 'if v_cleared and v_offense then') = 0
     or strpos(v_tick, 'case when v_cleared and v_offense') = 0 then
    raise exception '0294 FAIL: the reward lock (rewards only under v_offense) was altered';
  end if;
  -- ONE retreat authority: the tick still only CONSUMES retreat state, it never arms it.
  if strpos(v_tick, 'combat_set_retreating') > 0 or strpos(v_tick, 'presence_request_leave') > 0 then
    raise exception '0294 FAIL: the tick acquired retreat-arming code — presence_request_leave must remain the single retreat authority';
  end if;
  -- and NO-HOME's own return port is still none of this slice's business.
  if strpos(v_tick, 'set return_location_id') > 0 then
    raise exception '0294 FAIL: fleets.return_location_id was written by the tick — NO-HOME must stay untouched';
  end if;
  -- every other pinned head guarantee survives the re-emission.
  foreach v_tok in array array[
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
      raise exception '0294 FAIL: the tick lost a pinned head guarantee (%) — a stale-base re-emission', v_tok;
    end if;
  end loop;

  -- ── (4) THE FLEET AND ITS OWN SHIPS AGREE: the intercept translates the formation it just seeded ─
  if strpos(v_eval, 'set engagement_x = v_hit.ambush_x, engagement_y = v_hit.ambush_y') = 0 then
    raise exception '0294 FAIL: 0293''s [A2] engagement stamp was lost';
  end if;
  if strpos(v_eval, 'set pos_x = v_hit.ambush_x + (cu.pos_x - v_loc.x),') = 0
     or strpos(v_eval, 'pos_y = v_hit.ambush_y + (cu.pos_y - v_loc.y),') = 0 then
    raise exception '0294 FAIL: the intercept does not translate the player formation onto the ambush point — the fleet would still sit apart from its own ships';
  end if;
  if strpos(v_eval, 'select l.id, l.zone_id, z.sector_id, l.x, l.y') = 0 then
    raise exception '0294 FAIL: the linked-location read does not carry the centre the formation must be translated off';
  end if;
  -- the translation must run AFTER the units exist (presence_create is what creates them, three calls
  -- down) and it must be scoped to the encounter just created, positioned rows only.
  if strpos(v_eval, 'public.presence_create(') > strpos(v_eval, 'set pos_x = v_hit.ambush_x') then
    raise exception '0294 FAIL: the formation translation runs BEFORE the units are created';
  end if;
  if strpos(v_eval, 'where cu.encounter_id = v_enc') = 0
     or strpos(v_eval, 'and cu.pos_x is not null and cu.pos_y is not null') = 0 then
    raise exception '0294 FAIL: the formation translation is not scoped to this encounter''s positioned rows';
  end if;
  -- 0293's own guarantees survive: all four parks, no docked-arrival leaf, the 0290 guard sited before
  -- presence_create, the 0276 cutover, one roll, one log insert.
  if strpos(v_eval, 'fleet_set_present') <> 0 then
    raise exception '0294 FAIL: the evaluator calls the docked-arrival leaf again — the 0293 teleport is back';
  end if;
  v_n := (length(v_eval) - length(replace(v_eval, 'public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y)', '')))
         / length('public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y)');
  if v_n <> 4 then
    raise exception '0294 FAIL: the evaluator parks at the ambush point % time(s), want exactly 4 (standalone stub, vanished location, the location-linked combat path, empty manifest)', v_n;
  end if;
  foreach v_tok in array array[
      'get diagnostics v_manifest = row_count',
      'if v_manifest = 0 then',
      'empty_manifest',
      'order by exposure_fraction desc, zone_id asc',
      'typed_zone_effect_dispatch_v1',
      'pirate_intercept_compute_risk',
      'typed_zone_dispatch_error',
      'insert into public.pirate_intercepts',
      'group_sortie_members',
      'public.presence_create',
      'standalone_zone_stub_forced_stop',
      'location_missing',
      'race_lost',
      'calculate_group_expedition_stats',
      'cfg_bool(''pirate_intercept_enabled'')',
      'when others then'
    ] loop
    if strpos(v_eval, v_tok) = 0 then
      raise exception '0294 FAIL: the evaluator lost a pinned 0233/0276/0290/0293 guarantee (%) — this migration changes ONLY the location read and the formation translation', v_tok;
    end if;
  end loop;
  if strpos(v_eval, 'if v_manifest = 0 then') > strpos(v_eval, 'public.presence_create(') then
    raise exception '0294 FAIL: the zero-manifest guard runs AFTER presence_create — 0290 was reverted';
  end if;
  v_n := (length(v_eval) - length(replace(v_eval, 'random()', ''))) / length('random()');
  if v_n <> 1 then
    raise exception '0294 FAIL: the evaluator rolls % time(s), want exactly 1', v_n;
  end if;
  v_n := (length(v_eval) - length(replace(v_eval, 'insert into public.pirate_intercepts', '')))
         / length('insert into public.pirate_intercepts');
  if v_n <> 1 then
    raise exception '0294 FAIL: the evaluator logs % time(s), want exactly 1', v_n;
  end if;
  v_n := (length(v_eval) - length(replace(v_eval, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 2 then
    raise exception '0294 FAIL: the evaluator carries % cfg_bool call(s) (want the 0293 count of 2 — this slice adds no gate)', v_n;
  end if;

  -- ── (5) THE MIGRATION'S OWN DATA EFFECT (section 2) ──────────────────────────────────────────────
  -- (5a) the backfill is complete: no non-terminal encounter is left unstamped while its location
  --      actually has a coordinate to stamp it with.
  select count(*) into v_bad
    from public.combat_encounters ce
    join public.locations l on l.id = ce.location_id
   where ce.status in ('active','retreating')
     and l.x is not null and l.y is not null
     and (ce.engagement_x is null or ce.engagement_y is null);
  if v_bad <> 0 then
    raise exception '0294 FAIL: % non-terminal encounter(s) still carry a NULL engagement point despite a located home — the backfill did not complete', v_bad;
  end if;
  -- (5b) the split-fight signature is gone: a unit sitting EXACTLY on its location's centre while the
  --      encounter's engagement point is somewhere else is the seeded-at-the-wrong-anchor fingerprint
  --      (a fresh spawn and a fresh command ship land exactly on the anchor). None may remain.
  select count(*) into v_bad
    from public.combat_units cu
    join public.combat_encounters ce on ce.id = cu.encounter_id
    join public.locations l on l.id = ce.location_id
   where ce.status in ('active','retreating')
     and cu.pos_x = l.x and cu.pos_y = l.y
     and ce.engagement_x is not null and ce.engagement_y is not null
     and (ce.engagement_x <> l.x or ce.engagement_y <> l.y);
  if v_bad <> 0 then
    raise exception '0294 FAIL: % combat_unit row(s) still sit exactly on their location centre while their encounter is engaged elsewhere — the repair did not complete', v_bad;
  end if;

  -- ── (6) NO FLAG FLIPPED, NO CONFIG VALUE ASSERTED. Stated as THIS MIGRATION'S OWN EFFECT: neither
  --        body touches game_config outside its own cfg_bool reads, and no game_config row is written
  --        anywhere in this file. What the owner has any given flag SET to is deliberately not this
  --        migration's business — 0288 failed a production deploy by making it so. ─────────────────
  if position('game_config' in v_tick) <> 0 and position('cfg_bool' in v_tick) = 0 then
    raise exception '0294 FAIL: the tick touches game_config outside its cfg_bool reads — this slice writes no flag';
  end if;
  if position('game_config' in v_eval) <> 0 and position('cfg_bool' in v_eval) = 0 then
    raise exception '0294 FAIL: the evaluator touches game_config outside its cfg_bool reads — this slice writes no flag';
  end if;

  -- ── (7) EXPOSURE UNCHANGED — the tick stays engine-only, the evaluator stays service_role-only ───
  if has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception '0294 FAIL: process_combat_ticks became client-executable';
  end if;
  if not has_function_privilege('service_role', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute') then
    raise exception '0294 FAIL: service_role lost execute on the intercept evaluator';
  end if;
  if has_function_privilege('anon', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute') then
    raise exception '0294 FAIL: a client role can execute the intercept evaluator';
  end if;

  -- ── (8) NO SCHEMA CHANGE BEYOND WHAT WAS NEEDED — which is none. 0293's columns are still the
  --        nullable additive pair it created; this migration added and altered nothing. ───────────
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_encounters'
                    and column_name in ('engagement_x','engagement_y')
                    and is_nullable = 'YES' and data_type = 'double precision'
                 having count(*) = 2) then
    raise exception '0294 FAIL: combat_encounters.engagement_x/engagement_y are no longer the nullable double precision pair 0293 created';
  end if;

  raise notice '0294 OK: the fight is where the fleet is. process_combat_ticks derives EVERY combat coordinate from ONE anchor resolved once per encounter per tick — v_anchor_x := coalesce(e.engagement_x, loc.x) — and from no other read: both enemy wave spawns (the synthetic wave, which is also WAVE ONE because the encounter creator writes no enemy row, and the E3 resolved wave) seed there, and BOTH arms of the retreat/forced-extract return leg depart from there instead of from a port the fleet never reached; the head''s v_loc_x/v_loc_y are retired, `locations` is touched exactly twice (the CONTENT read that now also carries x/y, and 0292''s retreat-destination re-validation) so the anchor costs zero extra reads and removes three; pirate_intercept_evaluate_leg now RIGIDLY TRANSLATES the player formation the creator seeded at the linked location''s centre onto the ambush point, after presence_create and scoped to that encounter''s positioned rows, so the fleet row, its own ships and the encounter row finally agree — ring geometry and every inter-unit distance preserved exactly; INVARIANT (a) re-stated verbatim (v_is_spatial is derived from persisted rows ONLY, the flag-conjoined form is absent, and the tick makes ZERO cfg_bool(''spatial_combat_enabled'') reads — cfg_bool=8, random=2, unchanged); INVARIANT (b) re-stated (the completion branch reads AND clears fleets.retreat_target_location_id, re-validates it, keeps the origin_base_id fallback, and the 8s window, the v_offense disarm and the reward lock are the head''s lines); 0293''s four ambush parks, [A2] stamp, the 0290 zero-manifest guard sited before presence_create, the 0276 cutover, one roll and one log insert all survive; every non-terminal encounter is backfilled and every already-split fight rigidly repaired; no game_config VALUE is asserted anywhere in this proof, no flag is written, no gate is added, no schema is changed, grants unchanged';
end $anchor_assert$;
