-- COMBAT-FALLBACK — disposable proof for the player-fallback-weapon slice (migration 0262): a spatial
-- combat player ship with NO fitted weapon module but a positive attack_snapshot fires a SYNTHESIZED
-- basic weapon (power = attack_snapshot) instead of dealing ZERO damage. Driven through the REAL chain
-- (commission → mint/assign a captain for attack → send_ship_group_hunt → movement_settle_arrival →
-- combat_create_group_encounter → process_combat_ticks), never a hand-rolled combat_units/
-- group_sortie_members write.
--
-- ── THE BUG THIS PROVES FIXED ────────────────────────────────────────────────────────────────────────
-- process_combat_ticks (the tick) is a PURE CONSUMER of combat_units.weapons_json — its fire loop is
-- `for v_widx in 0 .. jsonb_array_length(weapons_json) - 1`, which never iterates over an empty array.
-- Before 0262, combat_create_group_encounter built a player ship's weapons_json SOLELY from fitted
-- range-carrying weapon modules, so a ship whose combat_power comes from a CAPTAIN (no weapon module
-- fitted) landed weapons_json='[]' and dealt ZERO damage in spatial mode. 0262 synthesizes ONE fallback
-- weapon from attack_snapshot when the fitted array is empty.
--
-- ── SCENARIO (engineered so the fallback ship is the SOLE damage source) ──────────────────────────────
-- One team of 2 ships:
--   • s_fb  — the COMMAND ship (spawns at the location center, dist 0 from the pirate). Carries a
--             gunnery_veteran CAPTAIN (attack 4, folded into combat_power) but NO weapon module fitted
--             → its RAW fitted-weapon join is EMPTY (the pre-fix state — asserted directly). 0262
--             synthesizes a basic_player_weapon (power = attack_snapshot = 4, range 150).
--   • s_arm — an armed escort with a real autocannon_battery fitted, parked on the formation ring tuned
--             to radius 500 — OUTSIDE its own 150 weapon range, so it CLOSEs (does not fire) on tick 1.
--             Its ONLY role here is the "armed ship's weapons_json is UNCHANGED (real autocannon, not
--             the fallback)" witness.
-- The synthetic pirate spawns at the center with weapon range tuned to 10 and targets the escort (aggro
-- 0) under the S1 aggro screen — the escort sits 500 away, far out of the pirate's 10 range, so the
-- pirate fires NOTHING on tick 1. Therefore the ONLY unit that can damage the pirate on tick 1 is s_fb's
-- SYNTHESIZED weapon — so the pirate's hp falling is unambiguously attributable to the fallback fix.
-- combat_damage_variance_pct is zeroed for determinism; enemy_hp_base is raised so the pirate survives.
--
-- ── PROPERTIES PROVEN (each a PASS marker below) ───────────────────────────────────────────────────────
--   CFALLBACK_PASS_PREFIX_EMPTY — s_fb's RAW fitted-weapon join (ship_module_fittings→module_types,
--                                 range not null) is EMPTY: pre-fix its weapons_json would be '[]', and
--                                 the tick's 0-length-safe fire loop would fire zero shots → zero damage.
--   CFALLBACK_PASS_SYNTH        — POST-fix: s_fb's weapons_json carries exactly ONE synthesized entry —
--                                 module_type_id='basic_player_weapon', power = attack_snapshot (4),
--                                 range 150 / projectile_speed 300 / cooldown 2 (the dedicated player
--                                 basic-weapon knobs, NOT the enemy synthetic's numbers).
--   CFALLBACK_PASS_ARMED        — s_arm (real autocannon fitted) keeps its own weapons_json: exactly one
--                                 entry, module_type_id='autocannon_battery', power 10, range 150 — the
--                                 fallback did NOT overwrite an already-armed ship.
--   CFALLBACK_PASS_DAMAGE       — after tick 1 the pirate's hp_current fell below its frozen hp_max, and
--                                 (attribution) s_fb is the only player unit within weapon range of the
--                                 pirate while s_arm is out of range and the pirate fired nothing — so
--                                 the synthesized fallback weapon dealt the damage (NONZERO after the
--                                 fix, ZERO before).
--
-- Self-rolling-back (begin;...rollback;, no COMMIT); every dark flag flipped ONLY inside the txn;
-- provisioning is 100% real-RPC/real-writer (commission_first_main_ship / commission_additional_main_ship
-- / captains_mint_instance / assign_captain_to_ship / reward_grant / craft_module / fit_module_to_ship /
-- upsert_ship_group / assign_ship_to_group / set_fleet_command_ship / send_ship_group_hunt /
-- movement_settle_arrival); group_sortie_members and combat_units are NEVER hand-written. No session RNG
-- (the 0041 determinism law) — gen_random_uuid() is fixture identity only, never combat math.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table cfb(k text primary key, v uuid) on commit preserve rows;

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- ════════ SETUP: reveal starter ports (fresh disposable chain seeds them INACTIVE — commission hard-
--          requires Haven dockable), then one funded fixture player ════════════════════════════════════
do $$
declare r jsonb; uZ uuid;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'cfb.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uZ;
  insert into cfb values ('uZ', uZ);
  insert into public.player_wallet (player_id, balance) values (uZ, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- dark capability gates — flipped ONLY inside this rolled-back txn (committed/production values stay
-- false; a fresh disposable chain has ALL of these seeded false, so every one is load-bearing here).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='captain_assignment_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';

-- tuning knobs (numeric, not capability gates) — all reverted by ROLLBACK. The engineered geometry
-- (header) depends on these EXACT values.
do $$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);          -- determinism
  perform public.set_game_config('combat_tick_logging', 'true'::jsonb);              -- so combat_ticks rows land
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);             -- so fire events land
  perform public.set_game_config('enemy_hp_base', '1000'::jsonb);                    -- pirate survives the fallback hit
  perform public.set_game_config('spatial_formation_ring_radius', '500'::jsonb);     -- escort OUT of its own 150 range (CLOSE, no fire)
  perform public.set_game_config('enemy_synthetic_range_base', '10'::jsonb);         -- pirate can't reach the 500-away escort
  perform public.set_game_config('enemy_synthetic_range_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base', '3'::jsonb);          -- pirate cannot close 500 in one tick
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
end $$;

-- ════════ PROVISION: 2 ships via the real commission RPCs; s_fb gets a CAPTAIN (attack, NO weapon),
--          s_arm gets a real autocannon; a real team with s_fb designated command ════════════════════
do $$
declare
  r jsonb;
  uZ uuid := (select v from cfb where k='uZ');
  s_fb uuid; s_arm uuid;
  v_cap uuid; v_mod_arm uuid;
begin
  r := pg_temp.call_as(uZ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL first ship: %', r; end if;
  select main_ship_id into s_fb from public.main_ship_instances where player_id = uZ;

  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then
    raise exception 'PROVISION FAIL 2nd ship: %', r; end if;
  s_arm := (r->>'main_ship_id')::uuid;

  insert into cfb values ('s_fb', s_fb), ('s_arm', s_arm);

  -- FIXTURE NORMALIZATION — retire each ship's commission 'present' fleet + complete its presence (the
  -- team-command/combat-spatial-proof precedent, verbatim): send_ship_group_hunt's dark-path readiness
  -- gate treats a fleet-truth-docked member as NOT ready, so a team fleet on top of a live dock fleet
  -- would be a phantom second fleet. This leaves each ship settled-SAFE ('home') — the state both
  -- fit_module_to_ship and assign_captain_to_ship require.
  update public.main_ship_instances
     set status = 'home', updated_at = now()
   where main_ship_id in (s_fb, s_arm);
  update public.fleets
     set status = 'destroyed', location_mode = 'destroyed', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where main_ship_id in (s_fb, s_arm) and status = 'present';
  update public.location_presence
     set status = 'completed', updated_at = now()
   where fleet_id in (select id from public.fleets
                        where main_ship_id in (s_fb, s_arm) and status = 'destroyed')
     and status = 'active';

  -- s_fb: a gunnery_veteran captain (0117: stats_json attack 4) via the real writers — combat_power
  -- WITHOUT any weapon module fitted (the production scenario). Mint (service_role writer) + assign
  -- (client wrapper, owner-scoped).
  v_cap := public.captains_mint_instance(uZ, 'gunnery_veteran', 'cfb-cap-1');
  if v_cap is null then raise exception 'PROVISION FAIL mint captain: null'; end if;
  r := pg_temp.call_as(uZ, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'cfb-assign-1', v_cap, s_fb, 'gunnery'));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign captain: %', r; end if;
  -- s_fb gets NO weapon module — its RAW fitted-weapon join must stay EMPTY (the fallback trigger).

  -- s_arm: a real autocannon_battery — the "armed ship weapons_json unchanged" witness. Fund the
  -- recipe (weapon_parts x4, pirate_alloy x2, scrap x6 — the S0/0107 seed) via the real Reward writer.
  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 4}, {"item_id": "pirate_alloy", "quantity": 2}, {"item_id": "scrap", "quantity": 6}]}'::jsonb);
  r := pg_temp.call_as(uZ, 'public.craft_module(''cfb-gun-1'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft gun: %', r; end if;
  v_mod_arm := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''cfb-fit-1'')', v_mod_arm, s_arm));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit gun: %', r; end if;

  -- form the team, assign both, designate s_fb the command ship (spawns at the location center).
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''Fallback'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group create: %', r; end if;
  insert into cfb values ('gZ', (r->>'group_id')::uuid);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_fb,  (select v from cfb where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign fb: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_arm, (select v from cfb where k='gZ')));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign arm: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_fb));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL designate command: %', r; end if;

  raise notice 'setup ok: s_fb (captain attack, NO weapon, command) + s_arm (real autocannon escort) provisioned';
end $$;

-- ════════ SEND + SETTLE: the real chain ═══════════════════════════════════════════════════════════════
do $$
declare
  r jsonb; n int;
  uZ uuid := (select v from cfb where k='uZ');
  gZ uuid := (select v from cfb where k='gZ');
  v_hunt uuid; v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'SEND FAIL: no active hunt_pirates location'; end if;
  insert into cfb values ('v_hunt', v_hunt);

  r := pg_temp.call_as(uZ, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gZ, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  if v_fleet is null or v_mv is null then raise exception 'SEND FAIL envelope: %', r; end if;

  select count(*) into n from public.group_sortie_members where fleet_id = v_fleet;
  if n <> 2 then raise exception 'SEND FAIL: % manifest rows (want 2)', n; end if;

  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then
    raise exception 'SEND FAIL settle: %', r; end if;

  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status = 'active';
  if v_enc is null then raise exception 'SEND FAIL: no active encounter after arrival'; end if;
  insert into cfb values ('v_enc', v_enc);
  raise notice 'setup ok: sortie sent, settled, encounter % active', v_enc;
end $$;

-- ════════ BLOCK PREFIX_EMPTY + SYNTH + ARMED: the creator's fallback hunk landed correctly ═══════════
do $$
declare
  n int; v_enc uuid := (select v from cfb where k='v_enc');
  s_fb uuid := (select v from cfb where k='s_fb');
  s_arm uuid := (select v from cfb where k='s_arm');
  v_attack_fb double precision; v_wc int;
  v_mid text; v_power double precision; v_range double precision; v_pspeed double precision; v_cd double precision;
  v_tick text;
begin
  -- ── PREFIX_EMPTY: s_fb's RAW fitted-weapon join (what the pre-0262 creator used) is EMPTY. ──────────
  select count(*) into n
    from public.ship_module_fittings f
    join public.module_instances i on i.id = f.module_instance_id
    join public.module_types t     on t.id = i.module_type_id
   where f.main_ship_id = s_fb and t.range is not null;
  if n <> 0 then raise exception 'PREFIX_EMPTY FAIL: s_fb has % fitted range-weapon module(s) (want 0 — the fallback trigger requires an empty fitted array)', n; end if;
  -- and the tick fires SOLELY from weapons_json via a 0-length-safe loop — so an empty array = zero
  -- shots = zero damage (the pre-fix behavior). Pin the loop token in the live tick source.
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_tick is null or position('jsonb_array_length(v_weapons_json) - 1' in v_tick) = 0 then
    raise exception 'PREFIX_EMPTY FAIL: process_combat_ticks does not fire from weapons_json via the 0-length-safe loop';
  end if;
  raise notice 'CFALLBACK_PASS_PREFIX_EMPTY ok: s_fb''s raw fitted-weapon join is empty (pre-fix weapons_json=[]); the tick fires only from weapons_json via `for v_widx in 0..jsonb_array_length-1`, so an empty array = zero shots = zero damage';

  -- ── SYNTH: POST-fix s_fb carries exactly ONE synthesized fallback weapon, power = attack_snapshot. ──
  select attack_snapshot, jsonb_array_length(weapons_json) into v_attack_fb, v_wc
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  if v_attack_fb is null or v_attack_fb <= 0 then
    raise exception 'SYNTH FAIL: s_fb attack_snapshot is % (want > 0 — the captain must contribute combat_power)', v_attack_fb; end if;
  if v_wc <> 1 then raise exception 'SYNTH FAIL: s_fb weapons_json has % entries (want exactly 1 synthesized)', v_wc; end if;
  select weapons_json->0->>'module_type_id',
         (weapons_json->0->>'power')::double precision,
         (weapons_json->0->>'range')::double precision,
         (weapons_json->0->>'projectile_speed')::double precision,
         (weapons_json->0->>'cooldown_seconds')::double precision
    into v_mid, v_power, v_range, v_pspeed, v_cd
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  if v_mid <> 'basic_player_weapon' then raise exception 'SYNTH FAIL: fallback module_type_id is % (want basic_player_weapon)', v_mid; end if;
  if v_power is distinct from v_attack_fb then raise exception 'SYNTH FAIL: fallback power % <> attack_snapshot %', v_power, v_attack_fb; end if;
  if v_range <> 150 or v_pspeed <> 300 or v_cd <> 2 then
    raise exception 'SYNTH FAIL: fallback range/projectile/cooldown = %/%/% (want 150/300/2 — the player basic-weapon knobs)', v_range, v_pspeed, v_cd; end if;
  raise notice 'CFALLBACK_PASS_SYNTH ok: s_fb synthesized ONE basic_player_weapon (power=% = attack_snapshot, range 150, projectile 300, cooldown 2)', v_power;

  -- ── ARMED: s_arm (real autocannon fitted) keeps its OWN weapons_json — the fallback did NOT touch it.
  select jsonb_array_length(weapons_json), weapons_json->0->>'module_type_id', (weapons_json->0->>'power')::double precision, (weapons_json->0->>'range')::double precision
    into v_wc, v_mid, v_power, v_range
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  if v_wc <> 1 then raise exception 'ARMED FAIL: s_arm weapons_json has % entries (want exactly 1 real autocannon)', v_wc; end if;
  if v_mid <> 'autocannon_battery' then raise exception 'ARMED FAIL: s_arm weapon is % (want autocannon_battery — the fallback overwrote a fitted weapon!)', v_mid; end if;
  if v_power <> 10 or v_range <> 150 then raise exception 'ARMED FAIL: s_arm autocannon power/range = %/% (want 10/150 — real fitted stats)', v_power, v_range; end if;
  raise notice 'CFALLBACK_PASS_ARMED ok: s_arm keeps its real autocannon_battery (power 10, range 150) — an already-armed ship''s weapons_json is unchanged by the fallback';
end $$;

-- ════════ BLOCK DAMAGE: tick 1 — the synthesized weapon deals REAL damage to the pirate ═══════════════
do $$
declare
  n int; v_enc uuid := (select v from cfb where k='v_enc');
  s_fb uuid := (select v from cfb where k='s_fb');
  s_arm uuid := (select v from cfb where k='s_arm');
  v_hunt uuid := (select v from cfb where k='v_hunt');
  v_loc_x double precision; v_loc_y double precision;
  v_dist_fb double precision; v_dist_arm double precision;
  v_e_hpmax double precision; v_e_hpcur double precision;
  v_pirate_fire int;
  v_hp_fb0 double precision; v_hp_arm0 double precision; v_hp_fb1 double precision; v_hp_arm1 double precision;
begin
  select x, y into v_loc_x, v_loc_y from public.locations where id = v_hunt;

  select hp_current into v_hp_fb0  from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  select hp_current into v_hp_arm0 from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;

  -- no enemy yet — wave 1 spawns and takes its first fire pass INSIDE this tick call.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if n <> 0 then raise exception 'DAMAGE FAIL precondition: % enemy rows before the first tick (want 0)', n; end if;

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  -- exactly ONE synthetic pirate (danger 1) spawned at the center.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side = 'enemy' and unit_type_id = 'pirate_synthetic';
  if n <> 1 then raise exception 'DAMAGE FAIL: % synthetic pirate row(s) (want exactly 1)', n; end if;

  -- ATTRIBUTION: s_fb (command, at center) is in weapon range of the pirate (dist 0 <= 150); s_arm sits
  -- ~500 out (its own 150 range can't reach) so it CLOSEs, does not fire; the pirate (range 10, targeting
  -- the far escort under the aggro screen) fires NOTHING on tick 1. So any pirate damage is s_fb's alone.
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_fb  from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  select public.osn_distance(pos_x, pos_y, v_loc_x, v_loc_y) into v_dist_arm from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  if v_dist_fb > 150 then raise exception 'DAMAGE FAIL attribution: s_fb is % from center, out of its own 150 range', v_dist_fb; end if;
  if v_dist_arm <= 150 then raise exception 'DAMAGE FAIL attribution: s_arm is % from center, within its 150 range (it would fire and muddy attribution)', v_dist_arm; end if;
  select count(*) into v_pirate_fire from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'pirate';
  if v_pirate_fire <> 0 then raise exception 'DAMAGE FAIL attribution: pirate fired % time(s) on tick 1 (want 0 — the escort is out of its range)', v_pirate_fire; end if;

  -- a PLAYER missile_salvo fired on tick 1 (the synthesized weapon), and the pirate's hp fell below max.
  select count(*) into n from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type = 'missile_salvo' and source = 'player';
  if n < 1 then raise exception 'DAMAGE FAIL: no player missile_salvo on tick 1 (the fallback weapon did not fire)'; end if;
  select hp_max, hp_current into v_e_hpmax, v_e_hpcur from public.combat_units where encounter_id = v_enc and side = 'enemy';
  if v_e_hpcur >= v_e_hpmax then
    raise exception 'DAMAGE FAIL: pirate hp_current (%) is not below hp_max (%) — the fallback weapon dealt ZERO damage', v_e_hpcur, v_e_hpmax; end if;

  -- and no player ship was hit (the pirate fired nothing) — a clean tick.
  select hp_current into v_hp_fb1  from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  select hp_current into v_hp_arm1 from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  if v_hp_fb1 is distinct from v_hp_fb0 or v_hp_arm1 is distinct from v_hp_arm0 then
    raise exception 'DAMAGE FAIL: a player ship took damage on tick 1 (pirate should have fired nothing)'; end if;

  raise notice 'CFALLBACK_PASS_DAMAGE ok: tick 1 — pirate hp fell %->% (NONZERO, from s_fb''s synthesized weapon alone: s_fb in range at dist %, s_arm out of range at dist %, pirate fired 0); pre-fix (empty weapons_json) this ship would have dealt ZERO', v_e_hpmax, v_e_hpcur, v_dist_fb, v_dist_arm;
end $$;

do $$ begin raise notice 'COMBAT-FALLBACK PROOF PASSED'; end $$;

rollback;   -- self-rolling-back: ZERO persisted state (no COMMIT anywhere above).
