-- 0300 — LIGHTS ON. Every dark capability this project built is switched on.
--
-- THE ORDER. The owner, 2026-07-27: "stop freeze and dark. it is usuless if i can't see and check",
-- then "while you are at it, make every dark we've developed open." Dark code they cannot see or
-- verify is worthless to them. This migration is that decision, recorded.
--
-- ── WHAT THIS COSTS, STATED PLAINLY ─────────────────────────────────────────────────────────────
-- Production is a LIVE ~30-player game. Every key below lights for EVERY player at the same instant.
--
-- Most of these flags have a matching scripts/activate-*.sql — a HUMAN activation tool that flips the
-- same key only after asserting preconditions (migration head recorded, the DEPLOYED function body
-- still carries the hooks it needs, seed rows present, exactly one cron job, catalog ids valid...).
-- Those guards exist because of a real incident: 0143 re-created mining_extract "verbatim from 0104"
-- and silently clobbered 0137's depletion hooks, so a flip against that body would have killed the
-- depletion subsystem invisibly. THIS MIGRATION DOES NOT RE-VERIFY THOSE PRECONDITIONS. It cannot —
-- they are written against a live database this author had no credentials to read.
--
-- So the honest framing: this is the FLIP, not the PROOF. The safer path for any single capability is
-- still to run its activate-*.sql by hand. The keys below are flipped together because the owner
-- asked for exactly that, and because a capability nobody can see is one nobody can report bugs on.
--
-- ── WHAT A PLAYER EXPERIENCES AT DEPLOY ─────────────────────────────────────────────────────────
--   MID-FLIGHT: nothing interrupts. No key here reads inside a movement leg's settle path; legs
--     already minted keep their target, speed and ETA.
--   MID-COMBAT: nothing interrupts. combat_telegraph_enabled and per_ship_targeting_enabled affect
--     how the NEXT encounter is presented and resolved, not one already running.
--   DOCKED / IDLE: the visible change is large — shipyard, port shop, trade, salvage, haul contracts,
--     module fitting and crafting, captains, ranking, repair economy and station storage all appear.
--
-- ── SCOPE ───────────────────────────────────────────────────────────────────────────────────────
-- Config writes only. No DDL, no function re-create, no grant change, no geometry touched.

do $$
declare
  v_key  text;
  v_lit  integer := 0;
  v_miss text[] := '{}';
begin
  foreach v_key in array array[
    -- ECONOMY & PORT SERVICES — the docked-player surface
    'shipyard_enabled',
    'port_shop_enabled',
    'trade_market_enabled',
    'trade_relief_enabled',
    'haul_contracts_enabled',
    'salvage_market_enabled',
    'station_storage_enabled',
    'repair_economy_enabled',
    'location_investment_enabled',
    -- SHIPS: fitting, crafting, traits, extra hulls
    'module_fitting_enabled',
    'module_crafting_enabled',
    'module_range_attributes_enabled',
    'ship_traits_enabled',
    'mainship_additional_commission_enabled',
    -- CAPTAINS
    'captain_assignment_enabled',
    'captain_progression_enabled',
    'captain_growth_enabled',
    'command_buffs_enabled',
    -- ACTIVITIES
    'mining_enabled',
    'exploration_enabled',
    'ranking_enabled',
    'world_balance_enabled',
    -- MOVEMENT & FLEETS
    'team_command_enabled',
    'fleet_control_enabled',
    'fleet_movement_unified_enabled',
    'mainship_send_enabled',
    'mainship_space_movement_enabled',
    'mainship_coordinate_travel_enabled',
    'launch_from_dock_enabled',
    'timed_docking_enabled',
    -- COMBAT PRESENTATION & RESOLUTION
    'combat_telegraph_enabled',
    'per_ship_targeting_enabled',
    'spatial_combat_enabled',
    'pirate_intercept_enabled',
    'enemy_content_registry_enabled',
    -- WORLD EDITOR / AUTHORING
    'encounter_authoring_enabled',
    'encounter_binding_authoring_enabled',
    'typed_zone_authoring_enabled',
    'seeded_zone_edit_enabled',
    'seeded_zone_lifecycle_enabled',
    -- TYPED-ZONE RUNTIME CUTOVERS
    'typed_zone_combat_runtime_enabled',
    'typed_zone_mining_runtime_enabled',
    'typed_zone_exploration_runtime_enabled',
    'typed_zone_pirate_intercept_runtime_enabled',
    -- POLISH
    'phase20_polish_enabled'
  ]
  loop
    -- A key this migration does not own must not be INVENTED. If it is absent the capability was
    -- never seeded here, and writing it would create a key no reader ever looks up.
    if exists (select 1 from public.game_config where key = v_key) then
      update public.game_config set value = 'true' where key = v_key and value is distinct from 'true';
      v_lit := v_lit + 1;
    else
      v_miss := v_miss || v_key;
    end if;
  end loop;

  raise notice '0300: % capability key(s) present and set true', v_lit;
  if array_length(v_miss, 1) is not null then
    raise notice '0300: % key(s) absent from game_config and deliberately NOT created: %',
      array_length(v_miss, 1), array_to_string(v_miss, ', ');
  end if;
end $$;

-- ── DELIBERATELY LEFT DARK — uncomment individually, with intent ────────────────────────────────
--
-- encounter_resolver_enabled
--   A prior production canary on this path destroyed the owner's main Fleet 1 through an unproven
--   combat-damage path (fixed by 0262; see the canary-readiness record). There is a recorded owner
--   NO-GO on the global flip. It is the ONE key here with a history of destroying a real asset, so
--   it does not ride in with the rest — flip it deliberately, ideally with an expendable canary.
--   update public.game_config set value = 'true' where key = 'encounter_resolver_enabled';
--
-- combat_debug_logging / combat_tick_logging
--   Not capabilities — diagnostic firehoses. The tick runs every 3 seconds against every live
--   encounter; lighting these writes log rows continuously for all ~30 players. Turn on while
--   diagnosing something specific, then off.
--   update public.game_config set value = 'true' where key in ('combat_debug_logging','combat_tick_logging');
--
-- combat_event_logging and runtime_cleanup_enabled are seeded TRUE already and are not touched.

-- ── SELF-ASSERT — pins THIS migration's own effect, nothing else ─────────────────────────────────
-- (0288 failed a PRODUCTION deploy by asserting a flag value it did not own. This asserts only the
--  keys this file wrote, holds on an EMPTY dataset, and asserts no count a concurrent writer moves.)
do $$
declare
  v_bad text[];
begin
  select coalesce(array_agg(key order by key), '{}')
    into v_bad
    from public.game_config
   where key in (
      'shipyard_enabled','port_shop_enabled','trade_market_enabled','trade_relief_enabled',
      'haul_contracts_enabled','salvage_market_enabled','station_storage_enabled',
      'repair_economy_enabled','location_investment_enabled','module_fitting_enabled',
      'module_crafting_enabled','module_range_attributes_enabled','ship_traits_enabled',
      'mainship_additional_commission_enabled','captain_assignment_enabled',
      'captain_progression_enabled','captain_growth_enabled','command_buffs_enabled',
      'mining_enabled','exploration_enabled','ranking_enabled','world_balance_enabled',
      'team_command_enabled','fleet_control_enabled','fleet_movement_unified_enabled',
      'mainship_send_enabled','mainship_space_movement_enabled','mainship_coordinate_travel_enabled',
      'launch_from_dock_enabled','timed_docking_enabled','combat_telegraph_enabled',
      'per_ship_targeting_enabled','spatial_combat_enabled','pirate_intercept_enabled',
      'enemy_content_registry_enabled','encounter_authoring_enabled',
      'encounter_binding_authoring_enabled','typed_zone_authoring_enabled',
      'seeded_zone_edit_enabled','seeded_zone_lifecycle_enabled',
      'typed_zone_combat_runtime_enabled','typed_zone_mining_runtime_enabled',
      'typed_zone_exploration_runtime_enabled','typed_zone_pirate_intercept_runtime_enabled',
      'phase20_polish_enabled')
     and value is distinct from 'true';

  if array_length(v_bad, 1) is not null then
    raise exception '0300: key(s) this migration wrote are not true: %', array_to_string(v_bad, ', ');
  end if;

  -- The parked key must still be dark — this migration's effect includes NOT lighting it.
  if exists (select 1 from public.game_config
              where key = 'encounter_resolver_enabled' and value = 'true') then
    raise notice '0300: encounter_resolver_enabled is true — this migration did not set it; a prior activation did';
  end if;

  raise notice '0300 OK: every capability key this migration owns reads true; encounter_resolver_enabled and the two debug-logging keys were deliberately left for a separate, deliberate flip';
end $$;
