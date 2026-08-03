-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0316 — COMBAT IS FIVE TIMES TIGHTER
--        (every distance and every distance-per-tick in the combat arena divided by 5, together,
--         so the geometry keeps its shape and every tick count stays exactly where it is)
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ── THE OWNER'S DECISION, VERBATIM ──────────────────────────────────────────────────────────────
--   "The combat is a mess. Nothing works perfectly. Start from reducing the range of the ship 5
--    times smaller"
--
-- ── WHY THE RANGE CANNOT MOVE ALONE ─────────────────────────────────────────────────────────────
-- Escorts spawn on spatial_formation_ring_radius (30) and enemies spawn AT the engagement anchor
-- (0299:765-774), so the ring IS the gap an escort has to close. Cutting the gun 25 -> 5 while the
-- ring stayed 30 would leave every escort 25 units OUTSIDE its own range, closing at the player's
-- in-combat speed of ~1 unit/tick plus the pirate's 5-8: 3-4 ticks of nothing at best, and a
-- permanent stall for any fleet the pirate does not walk toward. The cut is therefore applied as a
-- SIMILARITY TRANSFORM of the whole combat arena: every world-unit DISTANCE and every world-unit
-- RATE divided by 5, at once. The result is geometrically similar to today's fight at one fifth the
-- size — which is exactly why the tick arithmetic below comes out unchanged.
--
-- ── THE SCALING TABLE (every value, before -> after) ────────────────────────────────────────────
--   game_config.spatial_formation_ring_radius                     30    -> 6
--   game_config.enemy_synthetic_range_base                        18    -> 3.6
--   game_config.enemy_synthetic_range_per_difficulty              0.2   -> 0.04
--   game_config.combat_player_fallback_weapon_range               25    -> 5
--   game_config.enemy_synthetic_speed_base                        3     -> 0.6
--   game_config.enemy_synthetic_speed_per_difficulty              0.2   -> 0.04
--   game_config.enemy_synthetic_projectile_speed                  250   -> 50
--   game_config.combat_player_fallback_weapon_projectile_speed    300   -> 60
--   game_config.combat_player_speed_scale                         (new) -> 0.2
--   module_types.autocannon_battery.range                         25    -> 5
--   module_types.autocannon_battery.projectile_speed              300   -> 60
--   module_types.autocannon_battery_mk2.range                     30    -> 6
--   module_types.autocannon_battery_mk2.projectile_speed          320   -> 64
--   combat_units.move_speed for PLAYER rows  = hull speed         (x1)  -> x combat_player_speed_scale
--
-- Enemy range = 3.6 + 0.04.D; enemy speed = 0.6 + 0.04.D. At the three LIVE hunt difficulties
-- (Pirate Ambush Point 10, Raider Outpost 15, Pirate Den 25 — 0002:153-157) that is range 4.0 /
-- 4.2 / 4.6 against a 5 basic gun, and speed 1.0 / 1.2 / 1.6. At the hidden power-gated Ember tier
-- (40/50/60 — 0175:94-99) range 5.2 / 5.6 / 6.0: basic guns are out-ranged there and the Mk-II (6)
-- still is not, exactly the relation 0313 chose at the old scale.
--
-- ── SPEED: THE ONE THING THAT COULD NOT BE SCALED BY CONFIG, AND WHY IT HAD TO BE ────────────────
-- THE PLAYER'S IN-COMBAT SPEED IS NOT A KNOB. combat_create_group_encounter assigns it straight
-- from calculate_expedition_stats' 'speed' (0301:754) — the hull's base_speed folded through
-- modules/captains/traits (0043:39, 0122:259). That SAME number is the world-travel speed:
-- resolve_fleet_movement_speed (0051:47), begin_move (0057:170), the unified mover (0207:299) and
-- the docking clock (0219:234) all read it. Dividing main_ship_hull_types.base_speed by 5 would
-- make every voyage in the game five times longer. IT IS THEREFORE LEFT EXACTLY WHERE IT IS, and
-- the conversion is done where the two spaces actually meet: ONE new knob, combat_player_speed_scale
-- (0.2), read at the ONE line that turns travel speed into combat speed. That line is the only
-- writer of combat_units.move_speed for a player row in the entire database (grep-verified: 0234 ->
-- 0262 -> 0293 -> 0301, one assignment, never a second path), so the knob has ONE reader and one
-- authority. World travel is byte-untouched.
--
-- The alternative was to scale the ENEMY speeds and leave the player at world scale, and it does
-- not work — stated with the arithmetic rather than asserted:
--   • combat_unit_decide_move (0234:242-259) KITEs when my_range >= dist > target_range, stepping
--     least(my_speed, my_range - dist) — a kiter may never retreat past its own range edge. So a
--     player who out-ranges a pirate settles at the fixed point d* = R_player - v_enemy whenever
--     v_player >= v_enemy, and the pirate lands a shot only if d* <= R_enemy.
--   • With the player left at ~1.0 and the enemy divided by 5, at difficulty 10 that is v_e = 1.0
--     against v_p = 1.0 and d* = 5 - 1.0 = 4.0 exactly equal to R_enemy = 4.0 — a coin-flip on a
--     floating-point tie. Below difficulty 10 it inverts outright: at 0, v_e = 0.6 < v_p and
--     d* = 4.4 > R_enemy = 3.6, so the pirate would NEVER fire and the player would farm it for
--     free. That is 0313's standoff bug with the sides swapped.
--   • And leaving BOTH speeds unscaled is worse in the other direction: a difficulty-25 pirate
--     moves 8 units per tick into a 6-unit arena, so the CLOSE step (capped at the distance, never
--     overshooting) puts it ON TOP of its target on tick 1 and every unit HOLDs at contact for the
--     rest of the fight. Position would stop mattering again — the exact incoherence 0313 existed
--     to remove.
-- No single enemy-speed factor fixes both ends: v_e must exceed the unscaled ~1.3 player speed at
-- difficulty 0 (factor > 0.43) and stay under a third of the 6-unit ring at difficulty 60
-- (factor <= 0.13). The two demands are contradictory, which is the formal reason the player's
-- speed had to move. It is the only plpgsql this migration touches.
--
-- ── THE TICK ARITHMETIC — SPAWN TO FIRST SHOT, BEFORE AND AFTER ─────────────────────────────────
-- The engine freezes the population BEFORE any movement (0299:802-813), so within one tick both
-- sides step from the same pre-move distance and the gap closes by (v_player + v_enemy). The fire
-- gate is the PRE-MOVE distance against the firer's own range (0299:872-873). The lead hull spawns
-- at distance 0 (0315) and therefore fires on tick 1 in every row below, before and after.
--
--   d = escort-to-pirate gap at the START of each tick. Player hull = starter frigate (base 1.0).
--
--   BEFORE (ring 30, gun 25, R_e = 18+0.2D, v_e = 3+0.2D, v_p = 1.0)
--     D=10  t1 d=30 (silent)  -> t2 d=24 ESCORT FIRES -> t3 d=20 pirate fires, both hold
--     D=15  t1 d=30 (silent)  -> t2 d=23 ESCORT FIRES -> t3 d=18 pirate fires, both hold
--     D=25  t1 d=30 (silent)  -> t2 d=21 ESCORT FIRES and pirate fires, both hold
--
--   AFTER  (ring 6, gun 5, R_e = 3.6+0.04D, v_e = 0.6+0.04D, v_p = 0.2)
--     D=10  t1 d=6.0 (silent) -> t2 d=4.8 ESCORT FIRES -> t3 d=4.0 pirate fires, both hold
--     D=15  t1 d=6.0 (silent) -> t2 d=4.6 ESCORT FIRES -> t3 d=3.6 pirate fires, both hold
--     D=25  t1 d=6.0 (silent) -> t2 d=4.2 ESCORT FIRES and pirate fires, both hold
--
-- Every distance is exactly one fifth of the row above it and every TICK NUMBER is identical.
-- ESCORTS REACH FIRING RANGE IN ONE SILENT CLOSING TICK AND FIRE ON TICK 2 — that is the number
-- this slice ships, at every live difficulty, and it is the number the game has today. A Mk-II
-- escort (range 6 = the ring) fires from its formation slot on tick 1, as it does today at 30/30.
-- Assert (f6) below EXECUTES this recurrence against the live rows rather than trusting the table,
-- and refuses both a stall (first shot later than tick 3) and a collapse (nothing to close at all).
--
-- ── WHAT THIS DOES TO 0310'S AUTO-EXIT AND 0314'S ATTACK INTERVALS ──────────────────────────────
-- NOTHING, and that is the point of preserving the tick counts.
--   • 0314: every weapon's cooldown is TIME (2s / 2.5s / 2s), not distance, and all three are at or
--     under combat_tick_seconds (3), so each still fires exactly once per tick — 0314's own stated
--     rule, unchanged. No cooldown is scaled by this migration.
--   • Damage per landed hit is untouched (power, the defense curve, the per-hit roll).
--   • So the only way this migration could change how fast damage accumulates is by changing WHICH
--     TICK each side starts landing hits on. The table above shows it does not: escort tick 2,
--     pirate tick 2-3, before and after. The cumulative damage curve is therefore tick-for-tick
--     identical, and 0310's threshold fires on exactly the tick it fires on today.
--   • The counterfactual, stated because it is the thing that WOULD have broken it: leaving the
--     player at world speed makes the pirate's first hit land on tick 2 instead of tick 3 at
--     difficulties 10 and 15 — one extra tick of incoming fire per wave, about 3 seconds, against
--     a 30% capacity threshold. Scaling the player's speed is what keeps 0310 where the owner set it.
--   • The auto-exit arm reads hull sums and a percentage; it contains no distance. 0311's
--     reposition translates every unit by an exact delta and is scale-free. Neither is touched.
--
-- ── DELIBERATELY NOT SCALED (each asserted unchanged below) ─────────────────────────────────────
--   • mining_rig_extension.range (120) — slot_type='mining'. It is the mining EXTRACTION radius
--     (0229 §5) and it feeds a client map layer, not a gun; 0308's module_is_firing_weapon already
--     excludes it from combat. 0313 pinned it byte-for-byte and this migration keeps that pin.
--   • main_ship_hull_types.base_speed (1.0 / 0.8 / 1.3) — the WORLD-TRAVEL speed, shared with every
--     movement clock in the game. See the SPEED section: scaling it would make every voyage five
--     times longer. Left alone, loudly, and converted at the combat boundary instead.
--   • combat_tick_seconds, every cooldown_seconds, retreat/presence timers — TIME, not distance.
--     A similarity transform of space does not touch the clock, and scaling the clock would change
--     the pacing the owner did not ask about.
--   • enemy_synthetic_max_units, hp/attack/defense/variance knobs — counts and damage. The owner
--     cut RANGE; balance is a separate decision and must stay independently reversible.
--   • mining_extract_radius, exploration_scan_radius, territory_radius, danger_zones.boundary,
--     locations.x/y — the WORLD map, not the combat arena. They are shared with travel, docking,
--     mining and the zone renderer; shrinking them here would be a world rescale wearing a combat
--     slice's clothes. The fight now fits comfortably INSIDE the live pirate zones (28-79 units
--     across) instead of straddling them, which is the whole benefit of leaving them alone.
--   • aggro priorities, ring slot angles, the 8-slot formation — 0315's shape, untouched.
--
-- ── EVERY CONSUMER OF EVERY CHANGED VALUE (the whole-slice check) ───────────────────────────────
--   enemy_synthetic_range_* / speed_* / projectile_speed -> process_combat_ticks (TRUE head
--     0299:705-708 resolved arm, 0299:756-759 synthetic arm) -> frozen into the enemy row's
--     weapons_json and move_speed AT WAVE SPAWN.
--   spatial_formation_ring_radius -> combat_create_group_encounter (0301:723, carried through 0315)
--     -> frozen into combat_units.pos_x/pos_y AT ENCOUNTER CREATION.
--   combat_player_fallback_weapon_range / _projectile_speed -> the same builder (0301:794-796) ->
--     frozen into weapons_json at creation for any ship with no firing weapon fitted.
--   combat_player_speed_scale -> the same builder, the ONE line this migration rewrites -> frozen
--     into combat_units.move_speed at creation. No other reader anywhere.
--   module_types.range / .projectile_speed -> the builder's fitting join (0301:767-776, filtered by
--     module_is_firing_weapon since 0308) -> weapons_json; ship_weapon_modules (0229:159-188, no
--     live client caller); src/features/modules + ship/moduleInfoView.ts render whatever the row
--     says (derived, no constant); the tick's fire gate and movement snapshot read weapons_json,
--     never the catalog.
--   impact_delay_ms = round(1000 * dist / projectile_speed) (0299:884) — distance and projectile
--     speed both divided by 5, so the salvo-to-impact telegraph the client animates is UNCHANGED to
--     the millisecond. That is why the projectile speeds are in this slice: leaving them would have
--     shortened every impact delay fivefold for no reason.
--   CLIENT: src/features/map/spatialCombatLayer.ts derives every range ring from weapons_json (no
--     constant). src/features/map/fleetFightPosition.ts DOES carry a world-unit constant —
--     NEAREST_SHIP_MARGIN, the stability band that stops the fleet badge flapping between hulls —
--     and it is scaled 1 -> 0.2 in this same slice, with its spec's MARGIN literal. It is the only
--     hard-coded combat distance in the client and shipping it later would have made the badge
--     stick to one hull across a fifth of the whole arena.
--   PROOF HARNESSES repointed IN THIS SLICE: scripts/danger-combat-proof.sql (CLOSURE's premise +
--     the new tick-count assertion; LEAD's ring premise re-derived), scripts/combat-spatial-proof.sql
--     (its engineered ring/range geometry now DERIVES from the catalog gun instead of hard-coding
--     20 against a 25 that no longer exists) and both .sh selftests. combat-fallback-weapon-proof
--     already derives every expected value from the knobs and needed no repoint (its ring 500 /
--     pirate range 10 geometry is owned in-txn and is still far outside a 5-unit gun).
--
-- ── BLAST RADIUS ON THE LIVE ~30-PLAYER GAME (stated precisely) ─────────────────────────────────
--   - game_config is read PER TICK and AT EACH WAVE SPAWN. So the enemy knobs bite on the NEXT wave
--     of every fight, including fights already open right now: wave N+1 spawns with 3.6+0.04.D range
--     and 0.6+0.04.D speed.
--   - module_types ranges are FROZEN INTO weapons_json AT ENCOUNTER CREATION. A player unit in a
--     fight that is open at deploy keeps its 25/30 gun for the rest of that fight. So an in-flight
--     fight sees a MIXED scale for one wave boundary: 25-range players against 4-range pirates, with
--     the players' old long reach in their favour. It resolves itself when the fight ends; no fight
--     is repaired mid-flight and none is disturbed mid-flight.
--   - pos_x/pos_y and move_speed are likewise written ONCE at creation and never recomputed (the
--     tick MOVES units, 0311 TRANSLATES them, neither re-anchors). An open fight keeps its 30-unit
--     ring and its world-scale player speed until it ends. The new geometry appears at the NEXT
--     encounter creation: the next ambush, the next hunt arrival.
--   - The function change is a CREATE OR REPLACE by text surgery over pg_get_functiondef: an atomic
--     catalog swap. No table is locked by it, no row is written, nothing is backfilled.
--   - The config/catalog UPDATEs touch 8 game_config rows, insert 1, and update 2 module_types rows.
--     No player row is read or written by this migration at all.
--
-- ── EXACTLY-ONCE / FAIL-CLOSED ─────────────────────────────────────────────────────────────────
-- Every UPDATE is guarded on the exact OLD value. A re-apply, or an apply against a world whose
-- values have drifted off the chain, updates nothing — and the self-asserts then ABORT rather than
-- let a silent no-op ship. A later owner retune can never be clobbered by replaying this file. The
-- function hunk carries the same law in its own currency: the sliced text must occur EXACTLY once
-- in the deployed body and the rewrite must move the length by exactly the hunk delta.
--
-- ── WHY THE EXPLICIT TRANSACTION BLOCK (the same guard every sibling carries: 0310:174-177,
--    0311:202-205, 0312:107-110, 0313:113-116) ────────────────────────────────────────────────────
-- This file writes public.game_config and public.module_types — the two tables read by EVERY combat
-- tick (0299) and every fitting RPC — and re-creates the encounter builder, on a LIVE ~30-player
-- production. Without `set local lock_timeout`, an UPDATE that meets a concurrent tick's row lock
-- waits INDEFINITELY, and a migration hung inside `supabase db push` blocks every migration after
-- it. 5s fails fast instead; the deploy is then re-run in a quiet window. `statement_timeout` bounds
-- the self-asserts the same way, and `time zone 'UTC'` pins the now() the description updated_at
-- stamps carry. The block is also what makes `create temp table … on commit drop` mean anything:
-- outside an explicit transaction each statement is its own txn, so the capture tables would be
-- dropped before the asserts that read them ever ran.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────────────────────────
-- Multiply the thirteen values above back by 5 (and delete combat_player_speed_scale, or set it to
-- 1), then re-apply the builder with the hunk reverted to 0301:754. No state to unwind: this
-- migration writes no player data and backfills nothing.
--
-- Forward-only: 0001-0315 unedited.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ──────────────
do $pre$
declare v_src text;
begin
  if to_regprocedure('public.combat_create_group_encounter(uuid)') is null then
    raise exception '0316 PRECONDITION FAIL: public.combat_create_group_encounter(uuid) is absent';
  end if;
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  -- the 0301 lineage (mandatory engagement point) …
  if position('p_engagement_x' in v_src) = 0 then
    raise exception '0316 PRECONDITION FAIL: the deployed builder does not carry the 0301 mandatory engagement point — the slice was taken against a different head';
  end if;
  -- … with 0308's authorities …
  if position('group_sortie_live_members(pr.fleet_id)' in v_src) = 0
     or position('module_is_firing_weapon(t)' in v_src) = 0 then
    raise exception '0316 PRECONDITION FAIL: the deployed builder lacks the 0308 authorities — this is not the chain 0316 was generated against';
  end if;
  -- … and 0315's lead derivation already applied (the hunk below sits between them).
  if position('v_lead_ship_id' in v_src) = 0 or position('v_is_lead' in v_src) = 0 then
    raise exception '0316 PRECONDITION FAIL: the deployed builder has no 0315 lead derivation — the head this slice was cut against is not deployed';
  end if;
  if position('combat_player_speed_scale' in v_src) > 0 then
    raise exception '0316 PRECONDITION FAIL: the deployed builder already carries the combat speed scale — refusing to re-emit over an unknown edit';
  end if;
  -- the catalog rows and the weapon authority this migration reasons about must exist.
  if to_regprocedure('public.module_is_firing_weapon(public.module_types)') is null then
    raise exception '0316 PRECONDITION FAIL: public.module_is_firing_weapon is absent — the 0308 weapon authority this migration asserts against does not exist';
  end if;
end $pre$;

-- ── 1. CAPTURE the deliberately-untouched values BEFORE any write (derived, never hard-coded) ────
create temp table _0316_before (k text primary key, v text) on commit drop;

insert into _0316_before
select 'rig_' || key, value from (
  select 'range' as key, range::text as value from public.module_types where id = 'mining_rig_extension'
  union all select 'power', power::text from public.module_types where id = 'mining_rig_extension'
  union all select 'slot_type', slot_type from public.module_types where id = 'mining_rig_extension'
  union all select 'projectile_speed', coalesce(projectile_speed::text, '<null>') from public.module_types where id = 'mining_rig_extension'
  union all select 'cooldown_seconds', cooldown_seconds::text from public.module_types where id = 'mining_rig_extension'
) rig;

insert into _0316_before
select 'cfg_' || key, value::text from public.game_config
 where key in ('enemy_synthetic_max_units', 'enemy_synthetic_cooldown_seconds',
               'combat_player_fallback_weapon_cooldown_seconds',
               'combat_player_fallback_weapon_power_from_attack',
               'combat_tick_seconds', 'mining_extract_radius');

insert into _0316_before
select 'gun_' || id || '_' || key, value from (
  select id, 'power' as key, power::text as value from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
  union all select id, 'cooldown_seconds', cooldown_seconds::text from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
  union all select id, 'slot_type', slot_type from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
) guns;

insert into _0316_before
select 'hull_' || hull_type_id, base_speed::text from public.main_ship_hull_types;

create temp table _0316_fn (
  fname text primary key, body_md5 text, owner text, secdef boolean, volatility "char",
  parallel "char", proconfig text, args text, result text, acl text
) on commit drop;

insert into _0316_fn
select p.proname, md5(p.prosrc), pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile,
       p.proparallel, coalesce(array_to_string(p.proconfig, ','), ''),
       pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
       coalesce(p.proacl::text, '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';

-- ── 2. THE CONFIG SHRINK (guarded on the exact old values) ──────────────────────────────────────

update public.game_config
   set value = '6'::jsonb,
       description = 'COMBAT-S3 (0234, divided by 5 at 0316): radius (world units) of the escort ring '
                     'around the LEAD hull at spawn. It is also the gap an escort must close before it '
                     'can fire, because enemies spawn AT the anchor — keep it strictly above the basic '
                     'gun range (5) and strictly above the worst spawnable pirate range, or closure '
                     'stops happening and position stops mattering.',
       updated_at = now()
 where key = 'spatial_formation_ring_radius' and value = '30'::jsonb;

update public.game_config
   set value = '3.6'::jsonb,
       description = 'COMBAT-S3 (0234, retuned 0313, divided by 5 at 0316): synthetic pirate weapon '
                     'range at base_difficulty=0 (world units). With _per_difficulty this stays '
                     'strictly under the player basic gun at every LIVE difficulty; a pirate that '
                     'out-ranges the player settles at (its own range - the player speed) and the '
                     'player never lands a shot at all.',
       updated_at = now()
 where key = 'enemy_synthetic_range_base' and value = '18'::jsonb;

update public.game_config
   set value = '0.04'::jsonb,
       description = 'COMBAT-S3 (0234, retuned 0313, divided by 5 at 0316): synthetic pirate weapon '
                     'range added per point of base_difficulty. At live difficulties 10/15/25 enemy '
                     'range is 4.0/4.2/4.6 (under the 5 basic gun); at the hidden Ember tier (40-60) '
                     'it is 5.2-6.0 (basic guns are out-ranged there, Mk-II never is).',
       updated_at = now()
 where key = 'enemy_synthetic_range_per_difficulty' and value = '0.2'::jsonb;

update public.game_config
   set value = '5'::jsonb,
       description = 'COMBAT-FALLBACK (0262, retuned 0313, divided by 5 at 0316): world-unit range of '
                     'the synthesized basic player weapon. Kept equal to the entry-tier '
                     'autocannon_battery range (the player basic-weapon default), DISTINCT from the '
                     'enemy synthetic''s knob.',
       updated_at = now()
 where key = 'combat_player_fallback_weapon_range' and value = '25'::jsonb;

update public.game_config
   set value = '0.6'::jsonb,
       description = 'COMBAT-S3 (0234, divided by 5 at 0316): synthetic pirate ship move_speed at '
                     'base_difficulty=0, in world units per combat tick. Divided with the distances so '
                     'a pirate still takes the same NUMBER OF TICKS to cross the formation ring. It '
                     'must stay comfortably above the fastest hull''s in-combat speed (base_speed x '
                     'combat_player_speed_scale) or a kiting player holds it outside its own range '
                     'forever and never gets shot at.',
       updated_at = now()
 where key = 'enemy_synthetic_speed_base' and value = '3'::jsonb;

update public.game_config
   set value = '0.04'::jsonb,
       description = 'COMBAT-S3 (0234, divided by 5 at 0316): synthetic pirate ship move_speed added '
                     'per point of base_difficulty, in world units per combat tick. Live difficulties '
                     '10/15/25 give 1.0/1.2/1.6.',
       updated_at = now()
 where key = 'enemy_synthetic_speed_per_difficulty' and value = '0.2'::jsonb;

update public.game_config
   set value = '50'::jsonb,
       description = 'COMBAT-S3 (0234, divided by 5 at 0316): synthetic pirate weapon projectile_speed '
                     '(world units/sec). Divided with the distances so impact_delay_ms — which the '
                     'client animates as the salvo-to-impact gap — is unchanged to the millisecond.',
       updated_at = now()
 where key = 'enemy_synthetic_projectile_speed' and value = '250'::jsonb;

update public.game_config
   set value = '60'::jsonb,
       description = 'COMBAT-FALLBACK (0262, divided by 5 at 0316): projectile speed (world units/sec) '
                     'of the synthesized basic player weapon. Kept equal to the entry-tier '
                     'autocannon_battery muzzle velocity, DISTINCT from the enemy synthetic''s.',
       updated_at = now()
 where key = 'combat_player_fallback_weapon_projectile_speed' and value = '300'::jsonb;

-- THE NEW KNOB. Seeded, never clobbered on a re-apply (the house on-conflict law) — the invariant
-- asserts below read whatever value is actually there, so an owner retune is checked rather than
-- overwritten.
insert into public.game_config (key, value, description) values
  ('combat_player_speed_scale', '0.2',
   'COMBAT-TIGHT (0316): the conversion factor from a hull''s WORLD-TRAVEL speed '
   '(calculate_expedition_stats ''speed'', i.e. main_ship_hull_types.base_speed folded through '
   'modules/captains/traits) to its IN-COMBAT move speed in world units per tick. Read at exactly '
   'ONE line, in combat_create_group_encounter, and frozen into combat_units.move_speed at encounter '
   'creation. 0.2 because 0316 divided every combat distance by 5 and a speed is a distance per tick; '
   'before 0316 the two were implicitly equated at 1.0, which is why the player would have out-kited '
   'every pirate once the arena shrank. RAISING it makes players faster INSIDE fights only — it can '
   'never affect travel time — but past roughly half the pirate speed the kite becomes unbreakable '
   'and pirates stop landing shots.')
on conflict (key) do nothing;

-- ── 3. THE CATALOG SHRINK (the two firing weapons; nothing else in either row moves) ────────────
update public.module_types set range = 5,  projectile_speed = 60
 where id = 'autocannon_battery'     and range = 25 and projectile_speed = 300;

update public.module_types set range = 6,  projectile_speed = 64
 where id = 'autocannon_battery_mk2' and range = 30 and projectile_speed = 320;

-- ── 4. REWRITE THE ONE HUNK (located by exact deployed text, never retyped) ─────────────────────
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
    (1, 'combat_create_group_encounter',
     $h1o$          v_move_speed := coalesce((v_stats->>'speed')::double precision, 1);$h1o$,
     $h1n$          -- 0316 THE UNIT CONVERSION THAT WAS MISSING. v_stats->>'speed' is the hull's WORLD-TRAVEL
          -- speed (main_ship_hull_types.base_speed folded through modules/captains/traits, floored
          -- at 0.2 by 0122:259) — the same number resolve_fleet_movement_speed hands the travel
          -- clock. 0234 assigned it straight into combat_units.move_speed, i.e. it declared world
          -- units per SECOND of travel and world units per TICK of combat to be the same quantity.
          -- They are not, and once combat space is five times tighter (this migration) that identity
          -- is the one number left at the old scale: a hull would cross its own formation ring in 6
          -- ticks instead of 30 and out-kite every pirate at the low difficulties. The scale is a
          -- knob, not a literal, so the owner can see it and move it; the fallback is the shipped
          -- value, so a deleted key cannot silently restore world-scale speed inside a fight.
          v_move_speed := coalesce((v_stats->>'speed')::double precision, 1)
                          * coalesce(public.cfg_num('combat_player_speed_scale'), 0.2);$h1n$)
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0316 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0316 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0316 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0316 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 1 then
    raise exception '0316 REWRITE FAIL: rewrote % site(s), expected 1', v_done;
  end if;
  raise notice '0316: the player''s world-travel speed is now converted into a combat-space speed at the one line where the two meet';
end $rewrite$;

-- ── 5. SELF-ASSERTS — one DO block per check; every write asserted, every non-write pinned ──────

-- (a) the eight scaled knobs carry exactly the new values (a drifted base would have no-opped the
--     guarded UPDATE — this is the fail-closed abort for that case), and the new knob exists and is
--     a usable positive number (its VALUE is the owner's to tune; (f) checks what it has to satisfy).
do $a$
declare
  v_bad text;
  v_scale double precision;
begin
  select string_agg(x.k || ': ' || coalesce(public.cfg_num(x.k)::text, '<absent>') || ' (want ' || x.want::text || ')', '; ')
    into v_bad
    from (values ('spatial_formation_ring_radius',                 6.0::double precision),
                 ('enemy_synthetic_range_base',                    3.6::double precision),
                 ('enemy_synthetic_range_per_difficulty',          0.04::double precision),
                 ('combat_player_fallback_weapon_range',           5.0::double precision),
                 ('enemy_synthetic_speed_base',                    0.6::double precision),
                 ('enemy_synthetic_speed_per_difficulty',          0.04::double precision),
                 ('enemy_synthetic_projectile_speed',              50.0::double precision),
                 ('combat_player_fallback_weapon_projectile_speed', 60.0::double precision)) as x(k, want)
   where coalesce(public.cfg_num(x.k), -1) is distinct from x.want;
  if v_bad is not null then
    raise exception '0316 ASSERT (a) FAIL: a scaled knob did not land (%) — the guarded UPDATE no-opped, i.e. the deployed value had already drifted off the chain this migration was written against',
      v_bad;
  end if;
  v_scale := public.cfg_num('combat_player_speed_scale');
  if v_scale is null then
    raise exception '0316 ASSERT (a) FAIL: combat_player_speed_scale is absent — the builder would fall back to its literal and the knob would be unreachable';
  end if;
  if not (v_scale > 0) or v_scale > 1 then
    raise exception '0316 ASSERT (a) FAIL: combat_player_speed_scale is % — it must be a positive factor no greater than 1 (0 freezes every player hull in place, above 1 makes combat speed exceed travel speed)', v_scale;
  end if;
end $a$;

-- (b) the two guns carry exactly the new range and projectile speed, still satisfy the module_types
--     nonneg CHECKs (>0), and are still firing weapons by THE authority (0308's
--     module_is_firing_weapon), so the creator's fitting join still snapshots them.
do $b$
declare t public.module_types;
begin
  select * into t from public.module_types where id = 'autocannon_battery';
  if not found then raise exception '0316 ASSERT (b) FAIL: module_types row autocannon_battery is GONE'; end if;
  if t.range is distinct from 5 or t.projectile_speed is distinct from 60 then
    raise exception '0316 ASSERT (b) FAIL: autocannon_battery is range % / projectile_speed % (want 5 / 60)', t.range, t.projectile_speed;
  end if;
  if not public.module_is_firing_weapon(t) then
    raise exception '0316 ASSERT (b) FAIL: autocannon_battery no longer passes module_is_firing_weapon — the shrink broke the weapon authority';
  end if;
  select * into t from public.module_types where id = 'autocannon_battery_mk2';
  if not found then raise exception '0316 ASSERT (b) FAIL: module_types row autocannon_battery_mk2 is GONE'; end if;
  if t.range is distinct from 6 or t.projectile_speed is distinct from 64 then
    raise exception '0316 ASSERT (b) FAIL: autocannon_battery_mk2 is range % / projectile_speed % (want 6 / 64)', t.range, t.projectile_speed;
  end if;
  if not public.module_is_firing_weapon(t) then
    raise exception '0316 ASSERT (b) FAIL: autocannon_battery_mk2 no longer passes module_is_firing_weapon';
  end if;
end $b$;

-- (c) mining_rig_extension is BYTE-UNTOUCHED (compared to the pre-write capture, never a hard-coded
--     expectation) and is still NOT a firing weapon. ABSENCE IS FAILURE, not a pass: if the row were
--     gone, the pre-write capture would have inserted ZERO rig_* rows, the comparison below would
--     join against nothing and yield NULL, and the whole assert would pass while the mining
--     extraction radius had vanished. Both the row and the capture are pinned first. (0313's law,
--     carried forward verbatim — this is the value the owner said not to touch.)
do $c$
declare t public.module_types; v_bad text; v_n int;
begin
  select count(*) into v_n from _0316_before where k like 'rig\_%' escape '\';
  if v_n <> 5 then
    raise exception '0316 ASSERT (c) FAIL: the pre-write capture holds % mining_rig_extension attribute(s) (want 5) — the catalog row was already absent BEFORE this migration wrote anything, so the byte-comparison below would prove nothing', v_n;
  end if;
  select * into t from public.module_types where id = 'mining_rig_extension';
  if not found then
    raise exception '0316 ASSERT (c) FAIL: module_types row mining_rig_extension is GONE — the mining EXTRACTION radius (slot_type=mining, 0229 §5) this migration must never touch no longer exists';
  end if;
  select string_agg(b.k || ': ' || b.v || ' -> ' || cur.v, '; ') into v_bad
    from _0316_before b
    join (values ('rig_range',            t.range::text),
                 ('rig_power',            t.power::text),
                 ('rig_slot_type',        t.slot_type),
                 ('rig_projectile_speed', coalesce(t.projectile_speed::text, '<null>')),
                 ('rig_cooldown_seconds', t.cooldown_seconds::text)) as cur(k, v) on cur.k = b.k
   where cur.v is distinct from b.v;
  if v_bad is not null then
    raise exception '0316 ASSERT (c) FAIL: mining_rig_extension changed (%) — this migration must never touch the mining extraction radius', v_bad;
  end if;
  if public.module_is_firing_weapon(t) then
    raise exception '0316 ASSERT (c) FAIL: mining_rig_extension passes module_is_firing_weapon — a rig is a gun again (the 0308 defect resurrected)';
  end if;
end $c$;

-- (d) every knob and hull speed this slice deliberately did NOT move is byte-unchanged (derived from
--     the pre-write capture — asserting no collateral write, never an ambient seed). The hull speeds
--     are the load-bearing half: they are the WORLD-TRAVEL clock, and a migration that "helpfully"
--     scaled them would make every voyage in the game five times longer.
do $d$
declare v_bad text; v_n int;
begin
  select string_agg(b.k || ': ' || b.v || ' -> ' || coalesce(g.value::text, '<gone>'), '; ') into v_bad
    from _0316_before b
    left join public.game_config g on 'cfg_' || g.key = b.k
   where b.k like 'cfg\_%' escape '\'
     and coalesce(g.value::text, '<gone>') is distinct from b.v;
  if v_bad is not null then
    raise exception '0316 ASSERT (d) FAIL: an untouched config knob changed under this migration (%)', v_bad;
  end if;

  select count(*) into v_n from _0316_before where k like 'hull\_%' escape '\';
  if v_n < 1 then
    raise exception '0316 ASSERT (d) FAIL: the pre-write capture holds no hull base_speed rows — main_ship_hull_types was empty before this migration wrote anything, so the world-travel pin below would prove nothing';
  end if;
  select string_agg(b.k || ': ' || b.v || ' -> ' || coalesce(h.base_speed::text, '<gone>'), '; ') into v_bad
    from _0316_before b
    left join public.main_ship_hull_types h on 'hull_' || h.hull_type_id = b.k
   where b.k like 'hull\_%' escape '\'
     and coalesce(h.base_speed::text, '<gone>') is distinct from b.v;
  if v_bad is not null then
    raise exception '0316 ASSERT (d) FAIL: a hull base_speed changed under this migration (%) — that is the WORLD-TRAVEL speed, shared with every movement clock in the game; combat speed is converted at the builder instead',
      v_bad;
  end if;
end $d$;

-- (e) the guns' non-scaled attributes are byte-unchanged (power / cooldown / slot_type). Same
--     absence-is-failure pin as (c): a vanished gun row would empty one side of the join and the
--     comparison would pass vacuously. BOTH sides are counted first — 2 guns x 3 attributes = 6.
do $e$
declare v_bad text; v_n int; v_cur int;
begin
  select count(*) into v_n from _0316_before where k like 'gun\_%' escape '\';
  if v_n <> 6 then
    raise exception '0316 ASSERT (e) FAIL: the pre-write capture holds % gun attribute(s) (want 6 = 2 guns x 3 attributes) — a gun catalog row was already absent BEFORE this migration wrote anything, so the comparison below would prove nothing', v_n;
  end if;
  select count(*) into v_cur from public.module_types
   where id in ('autocannon_battery','autocannon_battery_mk2');
  if v_cur <> 2 then
    raise exception '0316 ASSERT (e) FAIL: % of the 2 gun catalog rows survive this migration — a firing-weapon row VANISHED', v_cur;
  end if;
  select string_agg(b.k || ': ' || b.v || ' -> ' || cur.v, '; ') into v_bad
    from _0316_before b
    join (select 'gun_' || id || '_' || key as k, value as v from (
            select id, 'power' as key, power::text as value from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
            union all select id, 'cooldown_seconds', cooldown_seconds::text from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
            union all select id, 'slot_type', slot_type from public.module_types where id in ('autocannon_battery','autocannon_battery_mk2')
          ) g) cur on cur.k = b.k
   where cur.v is distinct from b.v;
  if v_bad is not null then
    raise exception '0316 ASSERT (e) FAIL: a gun attribute other than range/projectile_speed changed (%) — damage and cadence are a separate balance decision', v_bad;
  end if;
end $e$;

-- (f) THE GEOMETRY THE NUMBERS WERE CHOSEN FOR, EXECUTED RATHER THAN TRUSTED — derived from the live
--     rows this chain actually carries, so a later retune that reintroduces the sprawl fails HERE
--     and not in a playtest:
--       f1 fallback range == basic gun range (one basic-weapon tier, two spellings);
--       f2 Mk-II strictly out-ranges the basic gun;
--       f3 the basic gun strictly out-ranges the synthetic pirate at EVERY difficulty either spawn
--          arm can actually mint (otherwise the standoff: a longer-ranged kiter settles at its own
--          range minus the player's speed and the player never lands a shot);
--       f4 the escort spawn ring strictly exceeds that same worst-case pirate range AND the basic
--          gun (the spawn gap is what forces closure — the mechanic 0313 unlocked);
--       f5 Mk-II covers the ring (a Mk-II escort fires from its formation slot on tick 1);
--       f6 THE CLOSURE TICK COUNT, computed by the engine's own recurrence: an escort must reach
--          firing range in at least one and at most two silent closing ticks — never instantly
--          (which would mean nothing has to close) and never a stall;
--       f7 the slowest pirate still out-paces the fastest hull's in-combat speed by 2x, so a kiting
--          player can never hold it outside its own range — the inverse of the f3 standoff, and the
--          invariant that stops a future speed retune quietly making pirates harmless;
--       f8 the FASTEST pirate cannot cross the whole spawn ring in one tick, so the approach is a
--          phase of the fight rather than a teleport. f6 and f8 are the two ends of the same bar:
--          f6 refuses a stall, f8 refuses a jump-cut, and between them position keeps mattering.
--
--     BOTH SPAWN ARMS, not just one (0313's finding, carried forward). enemy range/speed =
--     base + per_difficulty x D is evaluated in TWO places and D comes from a DIFFERENT source in
--     each: the SYNTHETIC arm (0299:756-759) reads the LOCATION's own base_difficulty, while the
--     RESOLVED arm (0299:705-708) reads the PER-UNIT base_difficulty the encounter plan carries,
--     which resolve_location_encounter materialises from enemy_archetypes.base_difficulty (0272:245)
--     amplified by encounter_elite_difficulty_multiplier where the member's elite_chance > 0
--     (0272:230-241, 0272:256). pirate_heavy is authored at 25 (0257:993) with no location column
--     constraining it, so an elite one is effective difficulty 50 — above anything a location-only
--     maximum would see. REACHABILITY for the resolved arm is the live binding chain the resolver
--     itself walks, so this can never fail on authored-but-unreachable content. ASSERTED
--     UNCONDITIONALLY, never under the resolver's flags: those are runtime toggles written by
--     set_game_config with no migration, so gating on them would let a later flip walk straight past
--     these invariants with nothing checking them.
do $f$
declare
  v_basic numeric; v_mk2 numeric; v_fallback numeric; v_ring numeric;
  v_scale double precision;
  v_elite_mult double precision;
  v_maxd double precision; v_maxd_syn double precision; v_maxd_res double precision;
  v_mind double precision; v_mind_syn double precision; v_mind_res double precision;
  v_arm text;
  v_enemy_max numeric; v_enemy_slowest double precision; v_enemy_fastest double precision;
  v_vp_fast double precision; v_vp_slow double precision;
  v_d double precision; v_t int;
begin
  select range into v_basic from public.module_types where id = 'autocannon_battery';
  select range into v_mk2   from public.module_types where id = 'autocannon_battery_mk2';
  v_fallback := public.cfg_num('combat_player_fallback_weapon_range');
  v_ring     := coalesce(public.cfg_num('spatial_formation_ring_radius'), 6);
  v_scale    := coalesce(public.cfg_num('combat_player_speed_scale'), 0.2);

  -- ARM 1 — the SYNTHETIC wave: the location's own difficulty.
  select coalesce(max(base_difficulty), 0), min(base_difficulty)
    into v_maxd_syn, v_mind_syn
    from public.locations where status = 'active' and activity_type = 'hunt_pirates';

  -- ARM 2 — the RESOLVED wave: the archetype difficulty reachable through a LIVE binding, amplified
  --          by the elite multiplier exactly where an elite can roll.
  v_elite_mult := greatest(1.0, coalesce(public.cfg_num('encounter_elite_difficulty_multiplier'), 2));
  select coalesce(max(a.base_difficulty
                      * case when coalesce(fm.elite_chance, 0) > 0 then v_elite_mult else 1.0::double precision end), 0),
         min(a.base_difficulty)
    into v_maxd_res, v_mind_res
    from public.location_encounter_bindings b
    join public.locations l                     on l.id  = b.location_id and l.status = 'active'
    join public.encounter_profiles ep           on ep.id = b.encounter_profile_id and ep.active is true
    join public.encounter_profile_members pm    on pm.encounter_profile_id = ep.id
    join public.enemy_fleet_templates ft        on ft.id = pm.fleet_template_id and ft.active is true
    join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
    join public.enemy_archetypes a              on a.id = fm.enemy_archetype_id and a.active is true
   where b.active is true;

  v_maxd := greatest(v_maxd_syn, v_maxd_res);
  -- the SLOWEST spawnable pirate sets the worst-case closure time; NULL from an arm that can mint
  -- nothing must not lower the bound, so each side falls back to the other.
  v_mind := least(coalesce(v_mind_syn, v_mind_res), coalesce(v_mind_res, v_mind_syn));
  if v_mind is null then
    raise exception '0316 ASSERT (f) FAIL: no spawn arm can mint an enemy at all (no active hunt location, no live binding) — every geometry check below would be vacuous';
  end if;
  v_arm  := case when v_maxd_res > v_maxd_syn
                 then format('the RESOLVED arm (encounter plan; synthetic arm tops out at %s)', v_maxd_syn)
                 else format('the SYNTHETIC arm (location base_difficulty; resolved arm tops out at %s)', v_maxd_res) end;
  v_enemy_max := public.cfg_num('enemy_synthetic_range_base')
               + v_maxd * public.cfg_num('enemy_synthetic_range_per_difficulty');
  v_enemy_slowest := public.cfg_num('enemy_synthetic_speed_base')
                   + v_mind * public.cfg_num('enemy_synthetic_speed_per_difficulty');
  v_enemy_fastest := public.cfg_num('enemy_synthetic_speed_base')
                   + v_maxd * public.cfg_num('enemy_synthetic_speed_per_difficulty');

  -- the player's IN-COMBAT speed band, derived from the hull catalog through the new conversion —
  -- never assumed. The floor mirrors calculate_expedition_stats' own greatest(0.2, …) (0122:259).
  select max(base_speed) * v_scale, greatest(0.2, min(base_speed)) * v_scale
    into v_vp_fast, v_vp_slow
    from public.main_ship_hull_types;
  if v_vp_fast is null or not (v_vp_slow > 0) then
    raise exception '0316 ASSERT (f) FAIL: the hull catalog yields no usable in-combat speed (fastest %, slowest %) — the closure arithmetic below has no player in it', v_vp_fast, v_vp_slow;
  end if;

  if v_fallback is distinct from v_basic then
    raise exception '0316 ASSERT (f1) FAIL: fallback range % <> basic gun range % — the basic-weapon tier split in two', v_fallback, v_basic;
  end if;
  if v_mk2 <= v_basic then
    raise exception '0316 ASSERT (f2) FAIL: Mk-II range % does not exceed the basic gun''s % — the upgrade lost its edge', v_mk2, v_basic;
  end if;
  if v_enemy_max >= v_basic then
    raise exception '0316 ASSERT (f3) FAIL: the worst spawnable enemy range is % (difficulty %, from %) >= the basic gun''s % — a kiter at that range would settle at (its range - the player''s speed) and the player would never land a shot',
      v_enemy_max, v_maxd, v_arm, v_basic;
  end if;
  if v_ring <= v_enemy_max then
    raise exception '0316 ASSERT (f4) FAIL: the % spawn ring is inside the worst spawnable enemy range % (difficulty %, from %) — enemies reach escorts on tick 1 and nothing ever closes',
      v_ring, v_enemy_max, v_maxd, v_arm;
  end if;
  if v_ring <= v_basic then
    raise exception '0316 ASSERT (f4) FAIL: the % spawn ring is inside the basic gun range % — every escort would spawn already in range and the CLOSE arm would never run again',
      v_ring, v_basic;
  end if;
  if v_mk2 < v_ring then
    raise exception '0316 ASSERT (f5) FAIL: Mk-II range % is under the % ring — a Mk-II escort could not fire from its formation slot', v_mk2, v_ring;
  end if;

  -- f6 — THE CLOSURE TICK COUNT. The engine's own recurrence, worst case: the SLOWEST hull closing
  -- on the SLOWEST spawnable pirate, both stepping from the same frozen pre-move snapshot
  -- (0299:802-813), each capped at the remaining distance (0234:249). The escort fires on the first
  -- tick whose PRE-MOVE distance is within its own range (0299:872-873).
  v_d := v_ring; v_t := 1;
  while v_d > v_basic and v_t <= 24 loop
    v_d := v_d - least(v_vp_slow, v_d) - least(v_enemy_slowest, v_d);
    v_t := v_t + 1;
  end loop;
  if v_t < 2 then
    raise exception '0316 ASSERT (f6) FAIL: an escort is inside its own range at spawn (ring %, gun %) — there is nothing to close and the approach has been retuned out of the game',
      v_ring, v_basic;
  end if;
  if v_t > 3 then
    raise exception '0316 ASSERT (f6) FAIL: the slowest escort (speed %) needs % ticks to reach firing range against the slowest spawnable pirate (difficulty %, speed %) across the % ring with a % gun — the sprawl is back; a fight must start shooting within one or two silent closing ticks, not stall',
      v_vp_slow, v_t, v_mind, v_enemy_slowest, v_ring, v_basic;
  end if;

  -- f7 — the pirate must always be able to close a KITING player. A player who out-ranges a pirate
  -- retreats least(v_p, R_p - d) every tick while the pirate closes v_e, so if v_e were at or below
  -- v_p the player would hold it outside its own range forever and take no fire at all. 2x is the
  -- margin the pre-0316 numbers already carried (5 against 1.3) and it is what leaves room for the
  -- speed modules and captain bonuses that fold into a hull's speed above its catalog base.
  if v_enemy_slowest < 2 * v_vp_fast then
    raise exception '0316 ASSERT (f7) FAIL: the slowest spawnable pirate moves % per tick against the fastest hull''s in-combat % — a kiting player would hold it at (gun range - its speed), outside its own reach, and never be shot at. Raise the enemy speed knobs or lower combat_player_speed_scale',
      v_enemy_slowest, v_vp_fast;
  end if;

  -- f8 — and the approach must not be a TELEPORT. The CLOSE step is capped at the remaining
  -- distance (0234:249), so a pirate whose per-tick speed reaches the whole spawn ring lands ON its
  -- target on tick 1 and every unit HOLDs at contact for the rest of the fight — position stops
  -- mattering again, which is the incoherence 0313 removed. Requiring at least two ticks to cross
  -- the ring is the bar the pre-0316 numbers already sat on (fastest 15 against a 30 ring), carried
  -- across the shrink unchanged.
  if v_enemy_fastest > v_ring / 2 then
    raise exception '0316 ASSERT (f8) FAIL: the fastest spawnable pirate (difficulty %, speed %) crosses more than half the % spawn ring in ONE tick — it would arrive on top of its target and every unit would HOLD at contact from tick 2 on, which is position ceasing to matter',
      v_maxd, v_enemy_fastest, v_ring;
  end if;

  raise notice '0316 GEOMETRY PASS: combat is five times tighter — basic gun %, Mk-II %, fallback %, spawn ring %; the worst enemy range ANY arm can mint is % at difficulty % (from %), strictly under the gun and strictly inside the ring; the slowest escort (in-combat speed %, scale %) reaches firing range on tick % against the slowest spawnable pirate (difficulty %, speed %), which still out-paces the fastest hull (%) by more than 2x. mining_rig_extension, every hull base_speed and every untouched knob byte-unchanged.',
    v_basic, v_mk2, v_fallback, v_ring, v_enemy_max, v_maxd, v_arm, v_vp_slow, v_scale, v_t, v_mind, v_enemy_slowest, v_vp_fast;
end $f$;

-- (g) ONE authority for the conversion: the builder reads the scale exactly once, still reads the
--     stats speed it converts, assigns move_speed exactly once, and acquired no second speed path.
do $g$
declare v_code text; v_n integer;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  v_n := (length(v_code) - length(replace(v_code, 'combat_player_speed_scale', ''))) / length('combat_player_speed_scale');
  if v_n <> 1 then
    raise exception '0316 ASSERT (g) FAIL: the builder reads combat_player_speed_scale % time(s) (want exactly 1 — one conversion, at the one line where travel space meets combat space)', v_n;
  end if;
  -- exactly ONE computing assignment. The needle is deliberately 'v_move_speed := coalesce(' and not
  -- the bare 'v_move_speed := ': the builder also carries the per-iteration inert reset
  -- (v_move_speed := null, 0301:739), which is the second occurrence and must stay.
  v_n := (length(v_code) - length(replace(v_code, 'v_move_speed := coalesce(', ''))) / length('v_move_speed := coalesce(');
  if v_n <> 1 then
    raise exception '0316 ASSERT (g) FAIL: v_move_speed is computed % time(s) (want exactly 1 — a second computing assignment is a second speed authority)', v_n;
  end if;
  if position('v_move_speed := null;' in v_code) = 0 then
    raise exception '0316 ASSERT (g) FAIL: the per-member inert reset (v_move_speed := null) is gone — a degraded member would inherit the previous hull''s speed';
  end if;
  if position('v_move_speed := coalesce((v_stats->>''speed'')::double precision, 1)' in v_code) = 0 then
    raise exception '0316 ASSERT (g) FAIL: the conversion no longer starts from calculate_expedition_stats'' own speed — the builder must SCALE the world-travel number, never invent a combat one';
  end if;
  -- 0315's lead derivation and 0308's authorities survive the re-emission (a stale-base rewrite
  -- would have silently reverted them).
  if position('order by msi.is_command_ship desc, msi.max_hp desc, gsm.main_ship_id asc' in v_code) = 0
     or position('v_is_lead := m.main_ship_id is not distinct from v_lead_ship_id;' in v_code) = 0 then
    raise exception '0316 ASSERT (g) FAIL: 0315''s lead derivation did not survive the rewrite';
  end if;
  if position('group_sortie_live_members(pr.fleet_id)' in v_code) = 0
     or position('module_is_firing_weapon(t)' in v_code) = 0 then
    raise exception '0316 ASSERT (g) FAIL: 0308''s roster/weapon authorities did not survive the rewrite';
  end if;
  if position('v_ring_radius := coalesce(public.cfg_num(''spatial_formation_ring_radius''), 30)' in v_code) = 0 then
    raise exception '0316 ASSERT (g) FAIL: the builder lost the ring read — the formation would collapse onto the anchor';
  end if;
  -- no RNG is introduced: the conversion is a multiplication, not a roll.
  v_n := (length(v_code) - length(replace(v_code, 'random(', ''))) / length('random(');
  if v_n <> 0 then
    raise exception '0316 ASSERT (g) FAIL: the builder carries % random( call(s) — spawn geometry must be deterministic (0041)', v_n;
  end if;
end $g$;

-- (h) metadata parity: the builder changed body and NOTHING else
do $h$
declare b record; a record; v_n integer := 0;
begin
  for b in select * from _0316_fn loop
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
      raise exception '0316 ASSERT (h) FAIL: public.% changed metadata across the rewrite', b.fname;
    end if;
    if a.body_md5 = b.body_md5 then
      raise exception '0316 ASSERT (h) FAIL: public.% body is byte-identical — the hunk did not land', b.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 1 then
    raise exception '0316 ASSERT (h) FAIL: parity-checked % function(s), expected 1', v_n;
  end if;
  raise notice '0316 SELF-ASSERT PASS: every combat distance and every combat rate divided by 5 together — ranges, the formation ring, the enemy speeds and the projectile speeds by config, and the player''s world-travel speed converted into a combat-space speed at the single line where the two meet. World travel, the mining extraction radius, every clock and every damage knob untouched.';
end $h$;

commit;
