-- 0299 -- THE COMBAT CARD REPORTS A TRUE POWER, AND EXPLAINS THE 3-SECOND PAUSE.
-- Two defects, ONE slice, because they are the same card on the same render and fixing one alone
-- leaves the other lying to the player on the surface the fix just touched.
--
-- ===================================================================================================
-- DEFECT A -- "power 0" IS FABRICATED (server side; this migration)
--   The owner watched a healthy 4-ship team fight and the map card read "4 ships . power 0".
--   process_combat_ticks wrote player_power_current = fleet_get_power(e.fleet_id) at both of its
--   encounter-update sites. fleet_get_power (20260616000006:101-112) is
--       select coalesce(sum(ut.power_score * fu.quantity), 0)
--         from fleet_units fu join unit_types ut on ut.id = fu.unit_type_id
--        where fu.fleet_id = p_fleet;
--   -- and a GROUP-SORTIE fleet has ZERO fleet_units rows. send_ship_group_hunt mints the team fleet
--   and never populates them (20260618000231:687-689 is the head's own INSERT INTO fleets, with no
--   fleet_units insert anywhere after it); the repo states it outright at 20260618000169:220-221 and
--   again at 20260618000294:1379-1381 ("player_power_start = 0 because fleet_get_power sums the same
--   empty table"). So the sum is over nothing, the coalesce turns it into 0, and 0 is written on
--   EVERY tick of EVERY group encounter. src/features/map/CombatMapCard.tsx renders it verbatim.
--
--   A SECOND, SMALLER BLEED, verified while auditing: the SPATIAL arm never calls
--   fleet_sync_quantities (that call sits in the aggregate arm only). So even a LEGACY
--   fleet_units-backed fleet fighting spatially reported its PRE-BATTLE power forever -- the number
--   never moved as its ships died. Both bleeds close here for the same reason: an encounter's power
--   must come from the encounter.
--
-- THE FIX -- ONE COMBAT-SIDE AUTHORITY, NO NEW SNAPSHOT COLUMN
--   public.combat_encounter_side_power(encounter, side) sums the encounter's OWN live combat_units.
--   It does NOT invent a formula and it does NOT add a second snapshot: it is exactly the two
--   definitions of player_power_start that the two encounter creators already write --
--     * a MEMBER row (main_ship_id set) contributes attack_snapshot. combat_create_group_encounter
--       (20260618000293:198-408) sets v_attack := calculate_expedition_stats(...)->>'combat_power',
--       writes it to attack_snapshot, and writes player_power_start := sum(v_attack). attack_snapshot
--       IS the canonical per-ship power, already frozen at creation. A new power_rating column would
--       be a SECOND snapshot of that same fact -- a second source of truth, so it is not added.
--     * a CATALOG row (unit_type_id set) contributes unit_types.power_score, which is precisely what
--       fleet_get_power meant, and what combat_create_encounter (20260618000168:504) writes as
--       player_power_start for a legacy fleet.
--   The snapshot-first coalesce(attack_snapshot, catalog stat) shape is the house idiom already used
--   by the tick's own offense fold -- reused, not reinvented.
--
--   CONSEQUENCE, DELIBERATE: an out-of-combat fleet edit can no longer move a running encounter's
--   displayed power. That is the point of a snapshot.
--
-- fleet_get_power IS NOT CHANGED, AND HERE IS THE FULL CALLER AUDIT THAT SAYS WHY
--   Every reference across supabase/migrations, src/, scripts/ and .github/ was enumerated and
--   attributed to its enclosing function; there are ZERO callers outside SQL. Live callers, at head:
--     1. process_combat_ticks           -- the two sites repointed here.
--     2. combat_create_encounter        head 20260618000168:504 -- the LEGACY branch, reached only
--        when the fleet has no group_sortie_members manifest. That fleet DOES have fleet_units, so
--        fleet_get_power is correct there; a manifest fleet is routed to the group creator one line
--        earlier and never reaches it.
--     3. send_fleet_to_location         head 20260618000051:279 -- the legacy dispatch gate against
--        locations.min_power_required. Legacy fleets only; correct there. Never dropped.
--   So fleet_get_power is not wrong -- it is the right answer to "what is this FLEET's roster worth",
--   and it was being asked a question it cannot answer ("what is this ENCOUNTER fielding"). Changing
--   it globally would silently move the dispatch gate and legacy encounter creation, which is why the
--   change is made at the call site instead. fleet_units is NOT populated for group sorties either:
--   that would create a second fleet-membership representation alongside group_sortie_members.
--
-- ===================================================================================================
-- DEFECT B -- "ENEMY 0 ships . integrity 0/285" UNEXPLAINED (client side; same slice, no SQL)
--   That is not a bug in the numbers, it is the 3-second inter-wave pause showing through. The tick
--   clears the enemy side on a wipe (enemy_integrity_current = greatest(0, v_e_after)) and stamps
--   next_wave_at = now() + wave_transition_seconds (default 3s), then pauses until it passes.
--   src/features/combat/ActiveCombatPanel.tsx ALREADY derived and rendered this; next_wave_at was
--   already on the wire (src/features/combat/combatTypes.ts:25). The map card simply never got it.
--   Fixed by EXTRACTING that derivation into ONE shared pure selector,
--   src/features/combat/combatPhase.ts (selectCombatPhase + nextWaveSeconds + nextWaveText), and
--   composing it into BOTH ActiveCombatPanel and CombatMapCard -- extracted, never duplicated.
--   Between waves the map card now says "Next wave incoming" and SUPPRESSES the placeholder
--   0 ships / 0/285 values. Covered by tests/combatPhase.spec.ts (Playwright, pure-unit).
--
-- ===================================================================================================
-- NO FLAG. STATED PLAINLY, BECAUSE DARK-FIRST IS THE STANDING LAW HERE AND THIS DEPARTS FROM IT.
--   The owner's direction for this slice was explicit: "stop freeze and dark. it is useless if i
--   can't see and check." A flag would gate a DISPLAY-VALUE CORRECTION with no gameplay effect behind
--   a switch that would then have to be flipped before the owner could look at the thing they asked
--   to look at -- ceremony that defeats the purpose of the fix. So this migration takes effect the
--   moment it applies. It writes no game_config row, reads no new gate, and adds no cfg call.
--
-- WHAT A PLAYER CURRENTLY IN AN ENCOUNTER SEES AT THE MOMENT THIS DEPLOYS
--   This migration rewrites NO rows -- there is no backfill, because the tick's own next pass is the
--   backfill. process_combat_ticks runs on pg_cron every 3 seconds; create or replace swaps the body
--   atomically, so the FIRST tick after this commits writes the corrected player_power_current onto
--   every active/retreating encounter it loops. In practice: within ~3 seconds a fleet reading
--   "4 ships . power 0" reads its true power, with no reload and no interruption of the fight.
--   Two exact caveats, both verified in the head:
--     * an encounter sitting inside the 3-second inter-wave PAUSE is refreshed by the first tick
--       AFTER the pause ends -- the paused branch writes tick_number/danger_level/last_resolved_at
--       only and never wrote power, before or after this slice.
--     * the value shown will now FALL as ships are destroyed (it is current power, not starting
--       power). For a legacy aggregate fight that was already true; for a group fight and for any
--       spatial fight it is new, and it is correct.
--   Nothing else about any live fight changes: no damage, hp, shield, wave, danger, reward, timing or
--   coordinate value is touched, and no encounter is created, ended or re-targeted by this file.
--
-- ===================================================================================================
-- THE BASE MOVED UNDER THIS SLICE, AND THE PROOF CAUGHT IT. READ THIS BEFORE EDITING.
--   The first draft of 0299 spliced 20260618000294:255-1157, which WAS the true head when this slice
--   was authored. While it was in flight, 20260618000298_retreat_to_any_destination.sql landed and
--   re-created process_combat_ticks, making 0298 the true head. The disposable-matrix apply-proof
--   (run 30229320374, full chain, real Postgres) went RED on THIS migration's own precondition:
--       ERROR: 0299: the deployed process_combat_ticks does not carry 0292's chosen-destination
--              retreat -- refusing to re-emit from an unknown base (SQLSTATE P0001)
--   That was the guard working exactly as designed, and it was load-bearing: had the precondition
--   been one shade laxer, 0299 would have applied and SILENTLY REVERTED retreat-to-any-destination
--   -- the owner's most-repeated instruction of the session -- on a live ~30-player game, because the
--   spliced 0294 body still carried 0292's single-column read.
--   TWO things were wrong and both are fixed below: the precondition was pinned to a literal 0298
--   deliberately deleted (it now accepts EITHER shape), and the emitted body was a revert (it is now
--   spliced from 0298, and the self-assert pins 0298's shape POSITIVELY and pins 0292's superseded
--   read ABSENT). The lesson is the one this repo keeps paying for: a prosrc precondition is the only
--   thing that can catch a stale-base re-emission, so it must be WIDE enough to survive a legitimate
--   change to the base and NARROW enough to reject an unknown one.
--
-- ===================================================================================================
-- PROVENANCE -- WHICH BODY WAS COPIED FROM WHERE, AND EVERY HUNK ENUMERATED
--   A. public.process_combat_ticks()
--      COPIED FROM: 20260618000298_retreat_to_any_destination.sql:802-1706 -- the TRUE head. 0298
--      re-created this function to widen the completion branch to a coordinate destination; 0294 is
--      the one before it, 0292 before that.
--      WARNING TO THE NEXT AUTHOR: copying 0294 reverts 0298's retreat-to-ANY-destination; copying
--      0292 reverts that AND 0294's engagement anchor; copying 0291 reverts all of it. The
--      precondition block below refuses to run unless the DEPLOYED body carries 0242/0291, a
--      chosen-destination retreat read in EITHER the 0292 or the 0298 shape, and 0294's anchor --
--      and unless fleets.retreat_target_x/y exist, because the body emitted here READS them.
--      HUNKS: [P1] the two `player_power_current = fleet_get_power(e.fleet_id)` assignments -- one in
--             the spatial arm, one in the aggregate arm -- become
--             `public.combat_encounter_side_power(e.id, 'player')`. That is the ENTIRE delta.
--      EVERYTHING ELSE BYTE-IDENTICAL, INCLUDING: 0298's three-column retreat-destination read, its
--      clear of all three columns, its port-only re-validation and BOTH movement_create arms (the
--      'space' coordinate leg and the 'base' origin fallback); 0242/0291's data-derived v_is_spatial;
--      the 8s window, the reward lock, the v_offense disarm; 0294's ONE-anchor rule
--      (v_anchor_x := coalesce(e.engagement_x, loc.x)) and all six of its consuming sites; the E3
--      resolver wiring and its fresh-resolve ledger, the wave lifecycle and pacing formulas, every
--      reward formula, the per-ship targeting, the logging and the per-encounter subtransaction
--      contract. The self-assert re-states each of them, because an invariant that lives in a
--      function body survives only as long as the next author re-asserts it.
--
--   NOT TOUCHED, ON PURPOSE:
--     * public.fleet_get_power (0006) -- see the caller audit above. Unchanged, still correct.
--     * public.command_ship_group_go -- 0298 re-created it for the same retreat feature; this
--       migration does not re-emit it and has no business in it.
--     * public.pirate_intercept_evaluate_leg -- 0290's zero-manifest guard and 0293's four ambush
--       parks live there and this migration does not re-emit that function at all. The self-assert
--       still PROVES they are present, because "I did not touch it" is a claim and a probe is not.
--     * public.combat_create_encounter / combat_create_group_encounter -- they already write
--       player_power_start from exactly the definitions this authority unifies. Repointing them
--       would change nothing and would re-emit two more live bodies for no reason.
--     * combat_encounters.enemy_power_current -- deliberately NOT repointed. The head defines it as
--       remaining enemy INTEGRITY (greatest(0, v_e_after)), and every synthetic pirate row is
--       FK-anchored to unit_types 'pirate_synthetic', whose power_score is a dummy 0
--       (20260618000234:207-208), so a naive repoint would replace a meaningful bar with a
--       structural zero. Changing what the enemy number MEANS is a player-visible semantic change
--       that is not this slice's job. The authority below takes `side` because a side's power is one
--       concept, not two -- but it is called with 'player' only, and this paragraph is why.
--
-- No flag is flipped. No config key is written. No column is added or altered. No row is inserted,
-- updated or deleted by this file. Forward-only: 0298 is not edited in place.


-- -- 0. PRECONDITIONS -- refuse to re-emit over a base we did not build from -------------------------
-- A prosrc probe of the DEPLOYED bodies is the only thing that catches a stale-base re-emission, and
-- it must run BEFORE the create-or-replace. See "THE BASE MOVED UNDER THIS SLICE" above for why every
-- clause here is shaped the way it is.
do $pre$
declare
  v_tick text;
  v_eval text;
begin
  if to_regprocedure('public.process_combat_ticks()') is null then
    raise exception '0299: process_combat_ticks() is missing -- there is no tick to repoint';
  end if;
  if to_regprocedure('public.fleet_get_power(uuid)') is null then
    raise exception '0299: fleet_get_power(uuid) is missing -- the head this slice replaces at two call sites is not there';
  end if;

  -- 0298's COLUMNS. The body emitted below reads fleets.retreat_target_x/y, and plpgsql does not
  -- resolve table references until run time -- so without this check a chain missing 0298 would
  -- accept the new body happily and then fail on the first real retreat, in production.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleets'
                    and column_name in ('retreat_target_x','retreat_target_y')
                 having count(*) = 2) then
    raise exception '0299: fleets.retreat_target_x/retreat_target_y are missing -- 0298 must be deployed; the tick body this migration emits reads them';
  end if;

  -- the columns the new authority reads must all exist, or it would be born broken.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'combat_units'
                    and column_name in ('side','attack_snapshot','alive_count','main_ship_id','unit_type_id','encounter_id')
                 having count(*) = 6) then
    raise exception '0299: combat_units is missing one of side/attack_snapshot/alive_count/main_ship_id/unit_type_id/encounter_id -- 0167/0234 must be deployed';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'unit_types' and column_name = 'power_score') then
    raise exception '0299: unit_types.power_score is missing -- the catalog half of the power definition does not exist';
  end if;
  -- the XOR identity CHECK is what makes coalesce(attack_snapshot, power_score) unambiguous: without
  -- it a row could carry both and the coalesce would silently prefer one.
  if not exists (select 1 from pg_constraint where conname = 'combat_units_exactly_one_identity') then
    raise exception '0299: combat_units_exactly_one_identity (0167) is gone -- coalesce(attack_snapshot, power_score) would no longer be unambiguous';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'combat_units_member_snapshot_pairing') then
    raise exception '0299: combat_units_member_snapshot_pairing (0167) is gone -- a member row could carry a NULL attack_snapshot and contribute a silent zero';
  end if;

  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_tick is null then
    raise exception '0299: could not read the deployed process_combat_ticks body';
  end if;

  -- the defect must actually be there. If it is not, something already repointed these sites and
  -- this migration must not blindly re-emit a 900-line body over an unknown edit.
  if position('player_power_current     = fleet_get_power(e.fleet_id)' in v_tick) = 0 then
    raise exception '0299: the deployed process_combat_ticks does not write player_power_current from fleet_get_power -- the base is not the expected head and this re-emission would clobber an unknown edit';
  end if;
  -- THE CHOSEN-DESTINATION RETREAT, IN EITHER SHAPE. 0298 deliberately DELETED 0292's single-column
  -- read and replaced it with the three-column one that made retreat-to-anywhere possible. Pinning
  -- the 0292 literal is what turned this migration red on the apply-proof; pinning nothing at all
  -- would let a body with no retreat destination through. So: one of the two, and no third option.
  if position('select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y' in v_tick) = 0
     and position('select f.retreat_target_location_id into v_ret_loc from fleets f where f.id = e.fleet_id;' in v_tick) = 0 then
    raise exception '0299: the deployed process_combat_ticks carries neither 0298''s three-column retreat-destination read nor 0292''s single-column one -- refusing to re-emit from an unknown base';
  end if;
  -- 0294 must be IN the deployed tick, or the body below (which is 0298's, itself a superset of
  -- 0294's) would move the engagement anchor backwards.
  if position('v_anchor_x := coalesce(e.engagement_x, loc.x);' in v_tick) = 0 then
    raise exception '0299: the deployed process_combat_ticks does not carry 0294''s engagement anchor -- refusing to re-emit from an unknown base';
  end if;
  -- 0242/0291 must be IN the deployed tick. If it is not, something already reverted it and this
  -- migration must not be the thing that quietly papers over that.
  if position('v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)' in v_tick) = 0 then
    raise exception '0299: the deployed process_combat_ticks does not derive spatial mode from persisted rows -- 0242/0291 has been reverted AGAIN; fix that first, this migration will not mask it';
  end if;

  -- the intercept evaluator is NOT re-emitted here, but its two most-reverted guarantees are checked
  -- on the way in so that a base missing them is never mistaken for one that has them.
  select prosrc into v_eval from pg_proc where oid = 'public.pirate_intercept_evaluate_leg(uuid)'::regprocedure;
  if v_eval is null then
    raise exception '0299: pirate_intercept_evaluate_leg(uuid) is missing -- 0293 must be deployed';
  end if;
  if position('if v_manifest = 0 then' in v_eval) = 0 then
    raise exception '0299: the deployed evaluator does not carry 0290''s zero-manifest guard';
  end if;
  if position('set engagement_x = v_hit.ambush_x, engagement_y = v_hit.ambush_y' in v_eval) = 0 then
    raise exception '0299: the deployed evaluator does not stamp the ambush point (0293 reverted)';
  end if;
end $pre$;


-- == 1. THE COMBAT-SIDE POWER AUTHORITY -- new, and the ONLY place this value is derived ============
-- An encounter is a SNAPSHOT. Its power is what its own combat_units are worth, not what its fleet's
-- roster happens to hold this second. Per-row contribution:
--   member row  (main_ship_id set)  -> attack_snapshot, the combat_power frozen by
--                                      combat_create_group_encounter (0293:288) and summed by it into
--                                      player_power_start (0293:380).
--   catalog row (unit_type_id set)  -> unit_types.power_score, exactly what fleet_get_power summed
--                                      and what combat_create_encounter (0168:504) writes.
-- The 0167 XOR identity CHECK makes coalesce(attack_snapshot, ut.power_score) unambiguous, and the
-- member-snapshot pairing CHECK forbids the NULL-member-snapshot case that would contribute a silent
-- zero; both are re-verified in the preconditions above.
--
-- `* alive_count` is the same per-stack scaling fleet_get_power applied via fu.quantity: a catalog row
-- is a STACK of alive_count ships, a member row is one ship (alive_count 1, or 0 once destroyed).
-- The `alive_count > 0` filter is NOT redundant with that multiplication: combat_units.alive_count
-- carries no >= 0 CHECK (it is only ever written through greatest(0, ...) by the tick), so without the
-- filter a single negative value would SUBTRACT power. It is the cheap guard, not decoration.
--
-- side: parameterised because "a combat side's power" is one concept. Called with 'player' only --
-- see the header for why enemy_power_current is deliberately left meaning enemy integrity.
create or replace function public.combat_encounter_side_power(p_encounter uuid, p_side text)
returns double precision
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(coalesce(cu.attack_snapshot, ut.power_score, 0) * cu.alive_count), 0)
    from combat_units cu
    left join unit_types ut on ut.id = cu.unit_type_id
   where cu.encounter_id = p_encounter
     and cu.side = p_side
     and cu.alive_count > 0;
$$;

comment on function public.combat_encounter_side_power(uuid, text) is
  'COMBAT SNAPSHOT POWER (0299): the ONE authority for what one side of a combat encounter is '
  'currently worth. Sums the encounter''s own live combat_units -- attack_snapshot for a member ship '
  '(the combat_power frozen at encounter creation), unit_types.power_score for a catalog stack -- '
  'times alive_count, so it falls as ships die and is immune to a fleet roster edited outside the '
  'fight. This REPLACED fleet_get_power at process_combat_ticks'' two player_power_current writes: a '
  'group-sortie fleet has no fleet_units rows, so that call summed an empty table and wrote 0 on '
  'every tick. Returns 0 (never NULL) for an unknown encounter or an empty side. Engine-only: no '
  'client role may execute it.';

-- REVOKE, never merely assert (the 0254 lesson: Supabase grants EXECUTE on new functions to PUBLIC by
-- default, and prod carried that drift for a whole release). This is a SECURITY DEFINER reader over
-- combat_units, whose RLS restricts a client to its own rows -- so an unrevoked grant would let any
-- authenticated player read another player's encounter strength. Mirrors the
-- combat_create_group_encounter posture (0293:410-411).
revoke execute on function public.combat_encounter_side_power(uuid, text) from public, anon, authenticated;
grant  execute on function public.combat_encounter_side_power(uuid, text) to service_role;


-- == 2. process_combat_ticks -- the 0298:802-1706 TRUE HEAD verbatim + hunk [P1] (x2) ===============
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
          -- HUNK [P1] (0299) SPATIAL ARM. The head asked fleet_get_power, which sums fleet_units
          -- x unit_types -- a table a TEAM-SORTIE fleet has ZERO rows in, so this wrote 0 on every
          -- tick of every group fight and the map card rendered 'power 0' on healthy ships. An
          -- encounter is a SNAPSHOT: its power comes from its own combat_units, never from a live
          -- fleet roster that can be edited out of combat while the fight is running.
          player_power_current     = public.combat_encounter_side_power(e.id, 'player'),
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
        -- HUNK [P1] (0299) AGGREGATE ARM. Same repoint, same reason. For a legacy fleet_units
        -- fleet this arm is value-identical: fleet_sync_quantities ran a few lines above and set
        -- fleet_units.quantity to the very alive_count the new authority sums.
        player_power_current     = public.combat_encounter_side_power(e.id, 'player'),
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
  'COMBAT TICK. SNAPSHOT POWER (0299): player_power_current is written from '
  'combat_encounter_side_power(e.id, ''player'') at BOTH encounter-update sites -- the encounter''s own '
  'combat_units, never fleet_units. fleet_get_power summed an empty table for a group-sortie fleet and '
  'wrote 0 on every tick. RETREAT TO ANY DESTINATION (0298, carried through verbatim): the completion '
  'branch reads all three of fleets.retreat_target_location_id / retreat_target_x / retreat_target_y, '
  'clears all three, re-validates only the PORT, and mints the return leg to a stored coordinate when '
  'there is one, falling back to origin_base_id. ENGAGEMENT ANCHOR (0294): every combat COORDINATE '
  'this function decides derives from ONE anchor, resolved once per encounter per tick as '
  'coalesce(combat_encounters.engagement_x, locations.x) -- both enemy wave spawns (the synthetic wave '
  'and the E3 resolved wave; the encounter creator writes no enemy row, so wave one is spawned here '
  'too) and BOTH return-leg origins. The location remains the authority for encounter CONTENT '
  '(base_difficulty, reward_tier, max_presence_seconds) and is read exactly once for it. Spatial mode '
  'is still derived from PERSISTED DATA ONLY (0242/0291) -- never from a live flag. Engine-only: no '
  'client role may execute it.';

-- CREATE OR REPLACE preserves the existing ACL; this function has never been client-executable and
-- this migration does not change that. No grant statement is emitted, exactly as 0291/0292/0294/0298
-- emitted none -- the self-assert below proves the posture rather than re-asserting it by DDL.


-- == 3. SELF-ASSERT -- the migration proves its OWN effect or refuses to land =======================
-- SCOPE OF THIS PROOF, STATED UP FRONT. It asserts only what THIS migration does: the shape of the
-- two bodies it emits, the exposure of the function it creates, and the invariants it had to carry
-- through a re-emission. It asserts NO game_config VALUE and NO flag -- 0288's production deploy died
-- demanding a flag be false when the owner had deliberately lit it. It asserts NO seed row exists.
-- And it counts NOTHING that a concurrent writer can move: process_combat_ticks runs on pg_cron every
-- 3 seconds, so any assertion over combat_encounters / combat_units row counts would be a coin flip
-- against the clock. Every probe below is a function-definition probe, a catalog probe, or a call on
-- an encounter id that does not exist -- all of which hold identically on an EMPTY dataset and on a
-- busy production one.
--
-- PROSRC-ASSERT COUPLING (the 0221/0222/0234/0262/0291/0293/0294 house lesson): `--` line comments are
-- stripped from every body before probing, so the hunk banners above may NAME the calls this
-- migration removes without the probes for their absence tripping over the explanation.
do $power_assert$
declare
  v_tick   text;
  v_pow    text;
  v_eval   text;
  v_bwin   text;
  v_bstart integer;
  v_bend   integer;
  v_tok    text;
  v_n      integer;
  v_val    double precision;
begin
  select count(*) into v_n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_n <> 1 then
    raise exception '0299 FAIL: % pg_proc rows named process_combat_ticks (want exactly 1) -- every prosrc-by-proname assert in the repo reads this name', v_n;
  end if;
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_pow  from pg_proc where oid = 'public.combat_encounter_side_power(uuid, text)'::regprocedure;
  select prosrc into v_eval from pg_proc where oid = 'public.pirate_intercept_evaluate_leg(uuid)'::regprocedure;
  if v_tick is null or v_pow is null or v_eval is null then
    raise exception '0299 FAIL: process_combat_ticks / combat_encounter_side_power / pirate_intercept_evaluate_leg missing after this migration';
  end if;
  v_tick := regexp_replace(v_tick, '--[^' || chr(10) || ']*', '', 'g');
  v_pow  := regexp_replace(v_pow,  '--[^' || chr(10) || ']*', '', 'g');
  v_eval := regexp_replace(v_eval, '--[^' || chr(10) || ']*', '', 'g');

  -- -- (1) THE POWER LAW: the tick reads the ENCOUNTER, never the fleet roster ----------------------
  -- (1a) fleet_get_power is gone from the tick entirely. Not "mostly gone" -- one surviving call would
  --      be one arm still writing 0 for a team fight, which is the defect.
  if strpos(v_tick, 'fleet_get_power') <> 0 then
    raise exception '0299 FAIL: the tick still calls fleet_get_power -- a group-sortie fleet has no fleet_units rows, so that call writes 0';
  end if;
  -- (1b) and BOTH sites now take the snapshot authority. Exactly two: the spatial arm and the
  --      aggregate arm. One means an arm was missed; three means a site was added unannounced.
  v_n := (length(v_tick) - length(replace(v_tick, 'public.combat_encounter_side_power(e.id, ''player'')', '')))
         / length('public.combat_encounter_side_power(e.id, ''player'')');
  if v_n <> 2 then
    raise exception '0299 FAIL: % of the 2 player_power_current writes read the combat-side power authority (want exactly 2 -- the spatial arm and the aggregate arm)', v_n;
  end if;
  -- (1c) the tick still writes the column at exactly the same places it always did: two conditional
  --      writes plus the (A) already-destroyed branch's literal zero. Three in total, as in the head.
  v_n := (length(v_tick) - length(replace(v_tick, 'player_power_current', ''))) / length('player_power_current');
  if v_n <> 3 then
    raise exception '0299 FAIL: the tick writes player_power_current % time(s), want the head''s 3 (spatial arm, aggregate arm, and the destroyed-fleet zero)', v_n;
  end if;
  if strpos(v_tick, 'player_integrity_current=0, player_power_current=0') = 0 then
    raise exception '0299 FAIL: the destroyed-fleet branch no longer zeroes player_power_current -- a wiped fleet would report residual power';
  end if;
  -- (1d) the tick did not grow its OWN power arithmetic. The authority is a call, not a copy.
  if strpos(v_tick, 'power_score') <> 0 then
    raise exception '0299 FAIL: the tick derives power from unit_types.power_score itself -- that arithmetic belongs to combat_encounter_side_power and nowhere else';
  end if;

  -- -- (2) THE AUTHORITY ITSELF -- shape, then behaviour ------------------------------------------
  -- (2a) it reads the ENCOUNTER's rows. If it ever reads fleet_units it has become the bug it fixes.
  if strpos(v_pow, 'fleet_units') <> 0 then
    raise exception '0299 FAIL: combat_encounter_side_power reads fleet_units -- that is exactly the empty table that produced power 0';
  end if;
  if strpos(v_pow, 'combat_units') = 0 then
    raise exception '0299 FAIL: combat_encounter_side_power does not read combat_units';
  end if;
  -- (2b) it uses the EXISTING canonical definitions, both of them, and no invented formula.
  if strpos(v_pow, 'coalesce(cu.attack_snapshot, ut.power_score, 0)') = 0 then
    raise exception '0299 FAIL: the snapshot-first power expression is not the canonical coalesce(attack_snapshot, power_score) pair';
  end if;
  if strpos(v_pow, '* cu.alive_count') = 0 then
    raise exception '0299 FAIL: the authority does not scale by alive_count -- a half-destroyed stack would report full power';
  end if;
  if strpos(v_pow, 'cu.side = p_side') = 0 then
    raise exception '0299 FAIL: the authority does not filter by side -- an enemy wave would be folded into the player total';
  end if;
  if strpos(v_pow, 'cu.alive_count > 0') = 0 then
    raise exception '0299 FAIL: the authority does not exclude non-positive alive_count (the column carries no >= 0 CHECK, so a negative would subtract power)';
  end if;
  -- (2c) it is a pure read: no gate, no config, no write.
  if strpos(v_pow, 'cfg_bool') <> 0 or strpos(v_pow, 'cfg_num') <> 0 or strpos(v_pow, 'game_config') <> 0 then
    raise exception '0299 FAIL: combat_encounter_side_power reads configuration -- this slice adds no gate and no flag';
  end if;
  foreach v_tok in array array['insert ', 'update ', 'delete '] loop
    if strpos(v_pow, v_tok) <> 0 then
      raise exception '0299 FAIL: combat_encounter_side_power contains a write statement (%) -- it is a read-only authority', v_tok;
    end if;
  end loop;
  -- (2d) declared STABLE and SECURITY DEFINER with a pinned search_path, like every engine leaf here.
  if not exists (select 1 from pg_proc p
                  where p.oid = 'public.combat_encounter_side_power(uuid, text)'::regprocedure
                    and p.provolatile = 's' and p.prosecdef
                    and exists (select 1 from unnest(p.proconfig) cfg where cfg = 'search_path=public')) then
    raise exception '0299 FAIL: combat_encounter_side_power is not STABLE + SECURITY DEFINER + search_path=public';
  end if;
  -- (2e) BEHAVIOUR, on an id that does not exist -- true on an empty database and on a live one, and
  --      it pins the contract the card depends on: 0, never NULL. A NULL would blank the readout.
  select public.combat_encounter_side_power(gen_random_uuid(), 'player') into v_val;
  if v_val is null or v_val <> 0 then
    raise exception '0299 FAIL: an unknown encounter returns % rather than 0 -- the coalesce contract the map card depends on is broken', coalesce(v_val::text, 'NULL');
  end if;
  select public.combat_encounter_side_power(gen_random_uuid(), 'enemy') into v_val;
  if v_val is null or v_val <> 0 then
    raise exception '0299 FAIL: the enemy side of an unknown encounter returns % rather than 0 -- the side argument is not accepted cleanly', coalesce(v_val::text, 'NULL');
  end if;

  -- -- (3) INVARIANT (a) -- 0242, restored by 0291, preserved by 0292/0294/0298, preserved HERE. This
  --        exact line has been reverted four times by authors copying a stale body. ----------------
  if position('v_is_spatial := exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null)' in v_tick) = 0 then
    raise exception '0299 FAIL: the tick no longer derives spatial mode from persisted rows (0242/0291 reverted a FIFTH time)';
  end if;
  if position('v_is_spatial := v_spatial_combat_enabled' in v_tick) <> 0 then
    raise exception '0299 FAIL: the flag-conjoined spatial mode is back -- darkening the flag would flip a live spatial fight onto the aggregate arm and fold enemy rows into the player total';
  end if;
  if position('cfg_bool(''spatial_combat_enabled'')' in v_tick) <> 0 then
    raise exception '0299 FAIL: the tick reads spatial_combat_enabled again; mode must come from data alone';
  end if;
  -- EIGHT cfg_bool reads, the 0291/0292/0294/0298 count. This slice adds no gate, so it cannot move.
  v_n := (length(v_tick) - length(replace(v_tick, 'cfg_bool(', ''))) / length('cfg_bool(');
  if v_n <> 8 then
    raise exception '0299 FAIL: the tick carries % cfg_bool call(s) (want 8 -- the 0291/0292/0294/0298 count; this slice adds no gate)', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception '0299 FAIL: the tick carries % random( call(s) (want the head''s 2 -- this slice adds no randomness)', v_n;
  end if;

  -- -- (4) 0294's SINGLE-ANCHOR RULE, re-stated in full ------------------------------------------
  if strpos(v_tick, 'v_anchor_x := coalesce(e.engagement_x, loc.x);') = 0
     or strpos(v_tick, 'v_anchor_y := coalesce(e.engagement_y, loc.y);') = 0 then
    raise exception '0299 FAIL: the tick does not resolve the engagement anchor -- 0294 reverted';
  end if;
  if strpos(v_tick, 'select base_difficulty, reward_tier, max_presence_seconds, x, y into loc from locations where id = e.location_id;') = 0 then
    raise exception '0299 FAIL: the per-encounter locations read does not carry x/y -- 0294 reverted';
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'from locations where id = e.location_id', '')))
         / length('from locations where id = e.location_id');
  if v_n <> 1 then
    raise exception '0299 FAIL: the tick reads the encounter''s location % time(s), want exactly 1 (the CONTENT read) -- a coordinate read came back', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'from locations', ''))) / length('from locations');
  if v_n <> 2 then
    raise exception '0299 FAIL: the tick touches locations % time(s), want exactly 2 (the content read + the retreat-destination port re-validation)', v_n;
  end if;
  if strpos(v_tick, 'v_loc_x') <> 0 or strpos(v_tick, 'v_loc_y') <> 0 then
    raise exception '0299 FAIL: the head''s retired v_loc_x/v_loc_y location-coordinate locals are back -- 0294 reverted';
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'v_anchor_x, v_anchor_y, v_enemy_speed,', '')))
         / length('v_anchor_x, v_anchor_y, v_enemy_speed,');
  if v_n <> 2 then
    raise exception '0299 FAIL: % of 2 enemy-wave spawns seed at the engagement anchor -- 0294 reverted', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'e.location_id, v_anchor_x, v_anchor_y,', '')))
         / length('e.location_id, v_anchor_x, v_anchor_y,');
  if v_n <> 2 then
    raise exception '0299 FAIL: % of 2 return legs depart from the engagement anchor -- 0294 reverted', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'v_anchor_x', ''))) / length('v_anchor_x');
  if v_n <> 6 then
    raise exception '0299 FAIL: v_anchor_x appears % time(s), want exactly 6 (declaration, resolution, 2 enemy spawns, 2 leg origins)', v_n;
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'v_anchor_y', ''))) / length('v_anchor_y');
  if v_n <> 6 then
    raise exception '0299 FAIL: v_anchor_y appears % time(s), want exactly 6', v_n;
  end if;

  -- -- (5) INVARIANT (b) -- 0298's RETREAT TO ANY DESTINATION. This is the invariant this migration
  --        very nearly destroyed: its first draft spliced the 0294 head, which still carried 0292's
  --        single-column read, and only the precondition stopped it landing on a live game. So the
  --        emitted body is pinned to the 0298 shape POSITIVELY (the three-column read is present)
  --        and NEGATIVELY (0292's superseded read is absent). Both, because either alone can pass on
  --        a body that is half-reverted. ------------------------------------------------------------
  v_bstart := strpos(v_tick, 'if v_retreat_done or v_forced then');
  v_bend   := strpos(v_tick, 'perform fleet_set_returning(e.fleet_id, v_mv);');
  if v_bstart = 0 or v_bend = 0 or v_bend < v_bstart then
    raise exception '0299 FAIL: the tick''s completion branch is not recognisable';
  end if;
  v_bwin := substr(v_tick, v_bstart, v_bend - v_bstart);
  if strpos(v_bwin, 'select f.retreat_target_location_id, f.retreat_target_x, f.retreat_target_y') = 0 then
    raise exception '0299 FAIL: the completion branch does not read all THREE retreat-destination columns -- 0298''s retreat-to-any-destination is REVERTED, which is exactly what this migration''s first draft would have done';
  end if;
  if strpos(v_tick, 'select f.retreat_target_location_id into v_ret_loc from fleets f where f.id = e.fleet_id;') <> 0 then
    raise exception '0299 FAIL: 0292''s superseded single-column retreat read is back -- this body was spliced from a pre-0298 head and would revert retreat-to-any-destination';
  end if;
  if strpos(v_bwin, 'update fleets set retreat_target_location_id = null, retreat_target_x = null,') = 0
     or strpos(v_bwin, 'retreat_target_y = null') = 0 then
    raise exception '0299 FAIL: the completion branch does not CLEAR all three retreat-destination columns -- a chosen destination would leak into the next sortie (0298 reverted)';
  end if;
  if strpos(v_bwin, 'l.id = v_ret_loc and l.status = ''active''') = 0 then
    raise exception '0299 FAIL: the chosen PORT destination is used without re-validating it (0298/0292 reverted)';
  end if;
  if strpos(v_bwin, 'if v_dest_x is not null and v_dest_y is not null then') = 0
     or strpos(v_bwin, '''space'', null, null, null, v_dest_x, v_dest_y, ''return_home'', v_speed);') = 0 then
    raise exception '0299 FAIL: no leg is minted toward a chosen COORDINATE -- retreating anywhere is the whole point of 0298';
  end if;
  if strpos(v_bwin, 'select origin_base_id into v_base_id from fleets where id = e.fleet_id;') = 0
     or strpos(v_bwin, '''base'', v_base_id, null, null, v_base_x, v_base_y, ''return_home'', v_speed);') = 0 then
    raise exception '0299 FAIL: the origin_base_id fallback was lost (0298/0292 reverted)';
  end if;
  -- the retreat mints exactly TWO legs and no more: the chosen-destination arm and the fallback.
  v_n := (length(v_tick) - length(replace(v_tick, 'movement_create(', ''))) / length('movement_create(');
  if v_n <> 2 then
    raise exception '0299 FAIL: the tick mints % movement leg(s), want exactly 2 (the chosen-destination arm and the origin_base_id fallback)', v_n;
  end if;
  -- the coordinate column is named exactly twice: the read and the clear.
  v_n := (length(v_tick) - length(replace(v_tick, 'retreat_target_x', ''))) / length('retreat_target_x');
  if v_n <> 2 then
    raise exception '0299 FAIL: fleets.retreat_target_x is named % time(s), want exactly 2 (the read and the clear) -- 0298''s coordinate destination is not intact', v_n;
  end if;
  if strpos(v_tick, 'v_retreat_delay := coalesce(cfg_num(''retreat_delay_seconds''), 8);') = 0
     or strpos(v_tick, 'and now() - e.retreat_started_at >= make_interval(secs => v_retreat_delay);') = 0 then
    raise exception '0299 FAIL: the 8-second retreat window lines are not the head''s';
  end if;
  if strpos(v_tick, 'v_offense  := (e.status = ''active'');') = 0
     or strpos(v_tick, 'v_offense      := (e.status = ''active'');') = 0 then
    raise exception '0299 FAIL: the retreating-fleet disarm (v_offense) was altered in one of the two combat arms';
  end if;
  if strpos(v_tick, 'v_cleared := v_offense and v_e_after <= 0;') = 0
     or strpos(v_tick, 'if v_cleared and v_offense then') = 0
     or strpos(v_tick, 'case when v_cleared and v_offense') = 0 then
    raise exception '0299 FAIL: the reward lock (rewards only under v_offense) was altered';
  end if;
  if strpos(v_tick, 'combat_set_retreating') > 0 or strpos(v_tick, 'presence_request_leave') > 0 then
    raise exception '0299 FAIL: the tick acquired retreat-arming code -- presence_request_leave must remain the single retreat authority';
  end if;
  if strpos(v_tick, 'set return_location_id') > 0 then
    raise exception '0299 FAIL: fleets.return_location_id was written by the tick -- NO-HOME must stay untouched';
  end if;

  -- -- (6) THE INTER-WAVE PAUSE the client half of this slice now renders. It must still be exactly
  --        what it was: this slice explains that state, it does not change it. -------------------
  if strpos(v_tick, 'if e.next_wave_at is not null and now() < e.next_wave_at then') = 0
     or strpos(v_tick, 'v_wave_paused := true;') = 0 then
    raise exception '0299 FAIL: the inter-wave pause branch is gone -- the client copy this slice added would describe a state that no longer exists';
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'next_wave_at             = case when v_cleared then now() + make_interval(secs => v_trans_secs) else e.next_wave_at end,', '')))
         / length('next_wave_at             = case when v_cleared then now() + make_interval(secs => v_trans_secs) else e.next_wave_at end,');
  if v_n <> 2 then
    raise exception '0299 FAIL: % of 2 arms stamp next_wave_at on a cleared wave -- the pause the map card now explains would not be signalled', v_n;
  end if;
  if strpos(v_tick, 'v_trans_secs    := coalesce(cfg_num(''wave_transition_seconds''), 3);') = 0 then
    raise exception '0299 FAIL: the wave-transition duration is no longer read from wave_transition_seconds';
  end if;

  -- -- (7) every other pinned head guarantee survives the re-emission --------------------------
  foreach v_tok in array array[
      'v_resolver_engaged := cfg_bool(''enemy_content_registry_enabled'')',
      'if e.resolved_plan_json is not null then',
      'insert into encounter_runtime_state (location_id, encounter_profile_id, last_spawn_at, active_count)',
      'continue when v_enemy_count <= 0;',
      'public.combat_unit_decide_move(',
      'perform fleet_sync_quantities(e.fleet_id, v_counts);',
      'perform movement_attach_cargo(v_mv, e.id, e.total_rewards_json);',
      'coalesce(cu2.attack_snapshot, ut.attack)',
      'when query_canceled then raise;'
    ] loop
    if strpos(v_tick, v_tok) = 0 then
      raise exception '0299 FAIL: the tick lost a pinned head guarantee (%) -- a stale-base re-emission', v_tok;
    end if;
  end loop;

  -- -- (8) 0290's ZERO-MANIFEST GUARD and 0293's FOUR AMBUSH PARKS. This migration does not re-emit
  --        pirate_intercept_evaluate_leg at all; these probes prove that non-touch held, rather than
  --        asserting it. ----------------------------------------------------------------------
  foreach v_tok in array array[
      'get diagnostics v_manifest = row_count',
      'if v_manifest = 0 then',
      'empty_manifest'
    ] loop
    if strpos(v_eval, v_tok) = 0 then
      raise exception '0299 FAIL: the evaluator lost 0290''s zero-manifest guard (%)', v_tok;
    end if;
  end loop;
  if strpos(v_eval, 'if v_manifest = 0 then') > strpos(v_eval, 'public.presence_create(') then
    raise exception '0299 FAIL: the zero-manifest guard runs AFTER presence_create -- 0290 was reverted';
  end if;
  v_n := (length(v_eval) - length(replace(v_eval, 'public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y)', '')))
         / length('public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y)');
  if v_n <> 4 then
    raise exception '0299 FAIL: the evaluator parks at the ambush point % time(s), want 0293''s exactly 4 (standalone stub, vanished location, the location-linked combat path, empty manifest)', v_n;
  end if;
  if strpos(v_eval, 'set engagement_x = v_hit.ambush_x, engagement_y = v_hit.ambush_y') = 0 then
    raise exception '0299 FAIL: 0293''s engagement stamp was lost';
  end if;

  -- -- (9) NO FLAG FLIPPED, NO CONFIG VALUE ASSERTED. Stated as THIS MIGRATION'S OWN EFFECT: neither
  --        emitted body touches game_config outside its own cfg reads, and no game_config row is
  --        written anywhere in this file. What the owner has any given flag SET to is deliberately
  --        not this migration's business -- 0288 failed a production deploy by making it so. ------
  if position('game_config' in v_tick) <> 0 and position('cfg_bool' in v_tick) = 0 then
    raise exception '0299 FAIL: the tick touches game_config outside its cfg_bool reads -- this slice writes no flag';
  end if;

  -- -- (10) EXPOSURE -- the tick stays engine-only, and the NEW function is born locked ----------
  if has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception '0299 FAIL: process_combat_ticks became client-executable';
  end if;
  if has_function_privilege('authenticated', 'public.combat_encounter_side_power(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.combat_encounter_side_power(uuid, text)', 'execute')
     or has_function_privilege('public', 'public.combat_encounter_side_power(uuid, text)', 'execute') then
    raise exception '0299 FAIL: combat_encounter_side_power is client-executable -- a SECURITY DEFINER reader over combat_units must not be, it would expose another player''s encounter strength';
  end if;
  if not has_function_privilege('service_role', 'public.combat_encounter_side_power(uuid, text)', 'execute') then
    raise exception '0299 FAIL: service_role lost execute on combat_encounter_side_power';
  end if;

  -- -- (11) fleet_get_power IS STILL THERE, UNCHANGED. This slice repoints two call sites; it does
  --         not retire the function, because two live callers (combat_create_encounter's legacy
  --         branch and send_fleet_to_location) are RIGHT to use it. -------------------------------
  if to_regprocedure('public.fleet_get_power(uuid)') is null then
    raise exception '0299 FAIL: fleet_get_power was dropped -- combat_create_encounter''s legacy branch and send_fleet_to_location still call it';
  end if;

  raise notice '0299 OK: a combat encounter now reports its OWN power. combat_encounter_side_power(encounter, side) is the single authority -- it sums the encounter''s live combat_units as coalesce(attack_snapshot, unit_types.power_score) * alive_count, side-filtered, non-positive stacks excluded, returning 0 and never NULL for an unknown encounter (proven by call, on an id that cannot exist, so the probe holds on an empty database); it invents no formula, reusing attack_snapshot (the combat_power combat_create_group_encounter already freezes and sums into player_power_start) and power_score (what fleet_get_power itself summed), and it adds no snapshot column because attack_snapshot already IS the snapshot. process_combat_ticks writes player_power_current from it at BOTH sites -- the spatial arm and the aggregate arm -- and calls fleet_get_power ZERO times, so a group-sortie fleet (which has no fleet_units rows) stops reporting power 0 and a legacy fleet fighting spatially stops reporting its pre-battle power forever; the destroyed-fleet branch still zeroes the column and the tick grew no power arithmetic of its own. fleet_get_power is untouched and still live for its two correct callers. THE BODY IS SPLICED FROM 0298, NOT 0294: 0298''s retreat-to-ANY-destination survives intact -- the completion branch reads all three retreat-target columns, clears all three, re-validates only the port, mints the coordinate leg with the origin_base_id fallback, exactly 2 movement legs in the whole body, and 0292''s superseded single-column read is provably ABSENT (this migration''s first draft carried it and only the precondition stopped the revert reaching a live game). Also re-stated through the re-emission: INVARIANT (a) v_is_spatial derived from persisted rows only, flag-conjoined form absent, zero spatial_combat_enabled reads, cfg_bool=8 and random=2 unchanged; the 8s window, the v_offense disarm and the reward lock; 0294''s ONE anchor with its content read carrying x/y, locations touched exactly twice, v_loc_x/v_loc_y still retired and all six anchor sites intact; the inter-wave pause branch and both next_wave_at stamps that the map card''s new copy describes. 0290''s zero-manifest guard still sited before presence_create and 0293''s four ambush parks still present in an evaluator this migration never re-emitted. No game_config VALUE is asserted anywhere in this proof, no flag is written or read, no row is inserted/updated/deleted, no column added or altered, no count taken of anything the 3-second combat cron can move; the tick stays engine-only and the new authority is born revoked from every client role';
end $power_assert$;
