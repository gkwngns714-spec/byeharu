-- ELITE STAT WIRING — disposable apply-proof for migration 0272. Run against a THROWAWAY local Supabase
-- (`supabase start` applies the full chain incl. 0272 + its self-assert). NEVER point at prod.
--
-- Proves the slice's whole claim through the REAL combat chain:
--   (a) SPAWN STATS   — an elite plan entry materialises real combat_units whose ship_hp is
--                       encounter_elite_difficulty_multiplier x the non-elite row's, through the
--                       IDENTICAL existing spawn insert (process_combat_ticks is not changed by 0272).
--   (b) CEILING       — the total spawned unit count still respects enemy_synthetic_max_units.
--   (c) LEGACY PARITY — elite_chance = 0 content resolves to a plan BYTE-EQUAL to the pre-0272 (0261)
--                       plan, compared against an INDEPENDENTLY recomputed 0261 expectation (the count
--                       roll re-derived here from the 0261 salt/idiom), across 16 seeds. Only the
--                       top-level elite_policy tag differs (disabled_v1 -> multiplier_v1).
--   (d) FLAG-OFF      — with encounter_resolver_enabled=false the wave is the VERBATIM synthetic one.
--   (e) DETERMINISM   — two resolves of the same (location, seed) are identical (the 0041 law).
--   (f) WEAPONS/DAMAGE— elite AND normal enemy units, and the player unit, all carry a NON-EMPTY
--                       weapons_json and real damage flows both ways. THIS IS THE FLEET-1 REGRESSION
--                       GUARD: an empty weapons_json silently yielding 0 damage is the exact failure
--                       that destroyed the owner's Fleet 1 (0262 is the fix path). Prove it cannot recur
--                       on the elite path.
--
-- Self-rolling-back (begin;...rollback;): flips every gate flag ONLY inside the txn, keeps ZERO state.
-- combat_damage_variance_pct is pinned 0 (v_variance = 1) so every hp/damage number is exact; no session
-- RNG is introduced (the 0041 law).
--
-- PASS markers: ELITE_PASS_SOURCE, ELITE_PASS_LEGACY_PARITY, ELITE_PASS_DETERMINISM,
-- ELITE_PASS_SPLIT_PLAN, ELITE_PASS_FLAGOFF_SYNTHETIC, ELITE_PASS_SPAWN_STATS,
-- ELITE_PASS_WEAPONS_DAMAGE, "ELITE STAT WIRING PROOF PASSED".

\set ON_ERROR_STOP on

begin;

create temp table elfx(k text primary key, v uuid) on commit drop;

create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- ════════ STATIC PROOF — ELITE_PASS_SOURCE (prosrc; no fixtures needed) ══════════════════════════════
do $$
declare v_tick text; v_res text; v_n int;
begin
  select prosrc into v_tick from pg_proc where proname='process_combat_ticks'       and pronamespace='public'::regnamespace;
  select prosrc into v_res  from pg_proc where proname='resolve_location_encounter' and pronamespace='public'::regnamespace;

  -- the TICK is elite-blind and byte-anchored (0272 does not re-create it).
  if v_tick ilike '%elite%' then
    raise exception 'ELITE PROOF FAIL SOURCE: process_combat_ticks references elite — the damage side must never learn what elite means';
  end if;
  if strpos(v_tick, 'resolve_location_encounter(e.location_id, e.id::text)') = 0
     or strpos(v_tick, 'v_resolver_engaged') = 0
     or strpos(v_tick, 'v_enemy_count  := least(coalesce(cfg_num(''enemy_synthetic_max_units''),6)::integer, greatest(1, v_danger));') = 0
     or strpos(v_tick, '''module_type_id'', ''pirate_synthetic_weapon'', ''range'', v_enemy_range,') = 0
     or strpos(v_tick, 'v_reward_metal := round(coalesce(cfg_num(''reward_metal_base''),10) * greatest(loc.reward_tier,1)') = 0 then
    raise exception 'ELITE PROOF FAIL SOURCE: a pinned process_combat_ticks anchor is gone (the tick must be untouched by 0272)';
  end if;
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception 'ELITE PROOF FAIL SOURCE: process_combat_ticks carries % random( call(s) (want exactly 2)', v_n;
  end if;

  -- the RESOLVER is deterministic and carries the elite salt + the honest tag.
  if v_res ilike '%random(%' or v_res ilike '%setseed%' then
    raise exception 'ELITE PROOF FAIL SOURCE: resolve_location_encounter carries a session-RNG token (the 0041 law)';
  end if;
  if strpos(v_res, ':enc:elite:') = 0 or strpos(v_res, 'multiplier_v1') = 0 or strpos(v_res, 'disabled_v1') > 0 then
    raise exception 'ELITE PROOF FAIL SOURCE: the resolver does not carry the '':enc:elite:'' salt / elite_policy=multiplier_v1';
  end if;
  -- no elite column was added to any combat/runtime table (no second authority).
  if exists (select 1 from information_schema.columns
              where table_schema='public'
                and table_name in ('combat_units','combat_encounters','encounter_runtime_state','combat_ticks','combat_events')
                and column_name ilike '%elite%') then
    raise exception 'ELITE PROOF FAIL SOURCE: a combat/runtime table grew an elite column';
  end if;
  -- ACL unchanged: engine-only.
  if has_function_privilege('authenticated', 'public.resolve_location_encounter(uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.resolve_location_encounter(uuid,text)', 'execute') then
    raise exception 'ELITE PROOF FAIL SOURCE: the resolver is client-executable';
  end if;
  raise notice 'ELITE_PASS_SOURCE';
end $$;

-- ════════ SETUP: owner + funded player + reveal ports ════════════════════════════════════════════════
do $$
declare uZ uuid;
begin
  if (public.reveal_starter_ports()->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports'; end if;
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'elp.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uZ;
  insert into elfx values ('uZ', uZ);
  insert into public.player_wallet (player_id, balance) values (uZ, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  insert into public.app_owners(user_id) values (uZ);
end $$;

-- dark gates flipped ONLY inside this rolled-back txn (all four resolver flags + the combat deps).
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
update public.game_config set value='true'::jsonb where key='enemy_content_registry_enabled';
update public.game_config set value='true'::jsonb where key='encounter_authoring_enabled';
update public.game_config set value='true'::jsonb where key='encounter_binding_authoring_enabled';
update public.game_config set value='true'::jsonb where key='encounter_resolver_enabled';

do $$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);   -- v_variance = 1 (exact numbers)
  perform public.set_game_config('combat_tick_logging',  'true'::jsonb);
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);
  perform public.set_game_config('enemy_synthetic_range_base', '10000'::jsonb); -- in range at dist 0
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  -- enemy_hp_base / enemy_attack_base stay at their DEFAULTS: the enemy must really shoot back, so the
  -- (f) damage assertions measure real two-way damage rather than a zeroed-out stub.
end $$;

-- ════════ AUTHOR content through the REAL owner RPCs ════════════════════════════════════════════════
-- Two archetypes with the SAME base_difficulty, unit_type and default reward. The elite fleet pairs them
-- with elite_chance 1 (arch_e: EVERY unit elite) and 0 (arch_n: NEVER elite), so the split is exact and
-- seed-independent — the elite and normal rows differ ONLY by the multiplier.
do $$
declare uZ uuid := (select v from elfx where k='uZ'); r jsonb;
  v_rp uuid; v_arch_e uuid; v_arch_n uuid; v_f_split uuid; v_ep_split uuid;
  v_arch_z uuid; v_f_zero uuid; v_ep_zero uuid;
begin
  r := pg_temp.call_as(uZ, 'public.reward_profile_create(''elp-rp-1'', ''{"key":"elp_reward","display_name":"ELP Reward","resource_grants":{"metal":{"base":20,"danger_coeff":0.25,"multiplier_ref":"reward_multiplier"}}}''::jsonb)');
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL reward_profile: %', r; end if;
  v_rp := (r->'result'->>'id')::uuid;

  r := pg_temp.call_as(uZ, format('public.enemy_archetype_create(%L, %L::jsonb)', 'elp-arch-e',
         jsonb_build_object('key','elp_arch_e','display_name','ELP Arch Elite','unit_type_id','pirate_synthetic',
           'base_difficulty',5,'difficulty_rating',1,'default_reward_profile_id',v_rp::text)::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL arch_e: %', r; end if;
  v_arch_e := (r->'result'->>'id')::uuid;

  r := pg_temp.call_as(uZ, format('public.enemy_archetype_create(%L, %L::jsonb)', 'elp-arch-n',
         jsonb_build_object('key','elp_arch_n','display_name','ELP Arch Normal','unit_type_id','pirate_synthetic',
           'base_difficulty',5,'difficulty_rating',1,'default_reward_profile_id',v_rp::text)::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL arch_n: %', r; end if;
  v_arch_n := (r->'result'->>'id')::uuid;

  -- the SPLIT fleet: 1 always-elite unit + 1 never-elite unit.
  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'elp-fleet-split',
         jsonb_build_object('key','elp_fleet_split','display_name','ELP Fleet Split','members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id',v_arch_e::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',1),
           jsonb_build_object('enemy_archetype_id',v_arch_n::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL fleet_split: %', r; end if;
  v_f_split := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'elp-ep-split',
         jsonb_build_object('key','elp_ep_split','display_name','ELP EP Split','active_encounter_cap',5,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_f_split::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_split: %', r; end if;
  v_ep_split := (r->'result'->>'id')::uuid;

  -- the LEGACY-PARITY fleet: ONE archetype, elite_chance 0, count range [1,6] so the seed really moves
  -- the roll and the recomputed 0261 expectation is a real (not degenerate) comparison.
  r := pg_temp.call_as(uZ, format('public.enemy_archetype_create(%L, %L::jsonb)', 'elp-arch-z',
         jsonb_build_object('key','elp_arch_z','display_name','ELP Arch Zero','unit_type_id','pirate_synthetic',
           'base_difficulty',5,'difficulty_rating',1,'default_reward_profile_id',v_rp::text)::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL arch_z: %', r; end if;
  v_arch_z := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'elp-fleet-zero',
         jsonb_build_object('key','elp_fleet_zero','display_name','ELP Fleet Zero','members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id',v_arch_z::text,'min_count',1,'max_count',6,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL fleet_zero: %', r; end if;
  v_f_zero := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'elp-ep-zero',
         jsonb_build_object('key','elp_ep_zero','display_name','ELP EP Zero','active_encounter_cap',5,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_f_zero::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_zero: %', r; end if;
  v_ep_zero := (r->'result'->>'id')::uuid;

  insert into elfx values ('rp', v_rp), ('arch_e', v_arch_e), ('arch_n', v_arch_n),
                          ('ep_split', v_ep_split), ('arch_z', v_arch_z), ('ep_zero', v_ep_zero);
end $$;

-- ════════ fixture locations + bindings for the DIRECT resolver tests ═════════════════════════════════
do $$
declare uZ uuid := (select v from elfx where k='uZ'); r jsonb; v_zone uuid; v_l_split uuid; v_l_zero uuid;
begin
  select id into v_zone from public.zones limit 1;
  if v_zone is null then raise exception 'SETUP FAIL: no zone'; end if;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ELP Loc Split', 'pirate_hunt', 980, 980, 7, 'active') returning id into v_l_split;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ELP Loc Zero', 'pirate_hunt', 981, 981, 7, 'active') returning id into v_l_zero;
  insert into elfx values ('loc_split', v_l_split), ('loc_zero', v_l_zero);

  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'elp-bind-split',
         jsonb_build_object('location_id', v_l_split::text, 'encounter_profile_id', (select v from elfx where k='ep_split')::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL split: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'elp-bind-zero',
         jsonb_build_object('location_id', v_l_zero::text, 'encounter_profile_id', (select v from elfx where k='ep_zero')::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL zero: %', r; end if;
end $$;

-- ════════ (c) ELITE_PASS_LEGACY_PARITY — elite_chance=0 ⇒ the plan the 0261 resolver would have emitted ═
-- The expectation is rebuilt INDEPENDENTLY here from the 0261 count-roll salt/idiom and the fixture rows —
-- it is NOT read back out of the plan under test. Only the top-level elite_policy tag may differ.
do $$
declare v_loc uuid := (select v from elfx where k='loc_zero'); v_arch uuid := (select v from elfx where k='arch_z');
  v_ep uuid := (select v from elfx where k='ep_zero'); v_rp uuid := (select v from elfx where k='rp');
  p jsonb; v_expect jsonb; v_grants jsonb; g int; v_cnt int; v_min int := 1; v_max int := 6; v_range int;
begin
  select resource_grants into v_grants from public.reward_profiles where id = v_rp;
  v_range := v_max - v_min + 1;
  for g in 0 .. 15 loop
    p := public.resolve_location_encounter(v_loc, g::text);
    if p is null then raise exception 'ELITE PROOF FAIL LEGACY_PARITY: zero-elite fixture did not resolve at seed %', g; end if;
    -- the 0261 count roll, re-derived here from first principles.
    v_cnt := v_min + (((hashtextextended(v_loc::text || ':' || g::text || ':enc:count:' || v_arch::text, 0) % v_range) + v_range) % v_range)::integer;
    v_expect := jsonb_build_object(
      'encounter_profile_id', v_ep,
      'active_encounter_cap', 5,
      'cooldown_seconds', 0,
      'reward_profile', jsonb_build_object('id', v_rp, 'resource_grants', v_grants),
      'units', jsonb_build_array(jsonb_build_object(
        'enemy_archetype_id', v_arch,
        'unit_type_id', 'pirate_synthetic',
        'base_difficulty', 5::double precision,
        'count', v_cnt,
        'stat_overrides', '{}'::jsonb)));
    if (p - 'elite_policy') is distinct from v_expect then
      raise exception 'ELITE PROOF FAIL LEGACY_PARITY at seed %: plan (minus elite_policy) % <> the independently recomputed 0261 plan %', g, (p - 'elite_policy'), v_expect;
    end if;
    if (p ->> 'elite_policy') is distinct from 'multiplier_v1' then
      raise exception 'ELITE PROOF FAIL LEGACY_PARITY: elite_policy % <> multiplier_v1', (p ->> 'elite_policy');
    end if;
    if exists (select 1 from jsonb_array_elements(p->'units') u where u.value ? 'elite') then
      raise exception 'ELITE PROOF FAIL LEGACY_PARITY: a zero-elite plan unit carries an elite marker at seed %', g;
    end if;
  end loop;
  raise notice 'ELITE_PASS_LEGACY_PARITY';
end $$;

-- ════════ (e) ELITE_PASS_DETERMINISM — same (location, seed) ⇒ identical plan ════════════════════════
do $$
declare v_loc uuid := (select v from elfx where k='loc_split'); a jsonb; b jsonb;
begin
  a := public.resolve_location_encounter(v_loc, 'det');
  b := public.resolve_location_encounter(v_loc, 'det');
  if a is null then raise exception 'ELITE PROOF FAIL DETERMINISM: split fixture did not resolve'; end if;
  if a is distinct from b then
    raise exception 'ELITE PROOF FAIL DETERMINISM: two resolves of the same (loc, seed) differ: % vs %', a, b;
  end if;
  raise notice 'ELITE_PASS_DETERMINISM';
end $$;

-- ════════ ELITE_PASS_SPLIT_PLAN — the plan carries a normal entry AND a multiplied elite entry ═══════
do $$
declare v_loc uuid := (select v from elfx where k='loc_split'); p jsonb; v_mult double precision;
  v_n_elite int; v_n_norm int; v_bd_e double precision; v_bd_n double precision; v_sum int; v_ceiling int;
begin
  v_mult   := coalesce(public.cfg_num('encounter_elite_difficulty_multiplier'), 2);
  v_ceiling := greatest(1, coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::integer);
  p := public.resolve_location_encounter(v_loc, 'split');
  if p is null then raise exception 'ELITE PROOF FAIL SPLIT_PLAN: split fixture did not resolve'; end if;

  select count(*) into v_n_elite from jsonb_array_elements(p->'units') u where (u.value->>'elite')::boolean is true;
  select count(*) into v_n_norm  from jsonb_array_elements(p->'units') u where not (u.value ? 'elite');
  if v_n_elite <> 1 or v_n_norm <> 1 then
    raise exception 'ELITE PROOF FAIL SPLIT_PLAN: expected exactly 1 elite + 1 normal entry, got % elite / % normal: %', v_n_elite, v_n_norm, p;
  end if;
  select (u.value->>'base_difficulty')::double precision into v_bd_e from jsonb_array_elements(p->'units') u where (u.value->>'elite')::boolean is true;
  select (u.value->>'base_difficulty')::double precision into v_bd_n from jsonb_array_elements(p->'units') u where not (u.value ? 'elite');
  if abs(v_bd_e - v_bd_n * v_mult) > 0.000001 then
    raise exception 'ELITE PROOF FAIL SPLIT_PLAN: elite base_difficulty % <> % x normal %', v_bd_e, v_mult, v_bd_n;
  end if;
  -- the ceiling still binds over the SPLIT entries.
  select coalesce(sum((u.value->>'count')::int), 0) into v_sum from jsonb_array_elements(p->'units') u;
  if v_sum > v_ceiling then
    raise exception 'ELITE PROOF FAIL SPLIT_PLAN: total plan units % exceeds the ceiling %', v_sum, v_ceiling;
  end if;
  raise notice 'ELITE_PASS_SPLIT_PLAN';
end $$;

-- ════════ provision TWO armed command ships (ship1 = flag-off run, ship2 = elite run) ════════════════
do $$
declare uZ uuid := (select v from elfx where k='uZ'); r jsonb; s1 uuid; s2 uuid; m1 uuid; m2 uuid; g1 uuid; g2 uuid;
begin
  r := pg_temp.call_as(uZ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL ship1: %', r; end if;
  select main_ship_id into s1 from public.main_ship_instances where player_id = uZ;
  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'PROVISION FAIL ship2: %', r; end if;
  s2 := (r->>'main_ship_id')::uuid;
  insert into elfx values ('s1', s1), ('s2', s2);

  update public.main_ship_instances set status='home', updated_at=now() where main_ship_id in (s1, s2);
  update public.fleets set status='destroyed', location_mode='destroyed', active_movement_id=null,
         current_base_id=null, current_location_id=null, current_zone_id=null, current_sector_id=null, updated_at=now()
   where main_ship_id in (s1, s2) and status='present';
  update public.location_presence set status='completed', updated_at=now()
   where fleet_id in (select id from public.fleets where main_ship_id in (s1, s2) and status='destroyed') and status='active';

  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);

  r := pg_temp.call_as(uZ, 'public.craft_module(''elp-gun-1'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft1: %', r; end if;
  m1 := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''elp-fit-1'')', m1, s1));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit1: %', r; end if;
  r := pg_temp.call_as(uZ, 'public.craft_module(''elp-gun-2'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft2: %', r; end if;
  m2 := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''elp-fit-2'')', m2, s2));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit2: %', r; end if;

  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''ELP One'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL g1: %', r; end if;
  g1 := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(2, ''ELP Two'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL g2: %', r; end if;
  g2 := (r->>'group_id')::uuid;
  insert into elfx values ('g1', g1), ('g2', g2);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s1, g1));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign1: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s2, g2));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign2: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s1));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL cmd1: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s2));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL cmd2: %', r; end if;
end $$;

-- bind the REAL hunt location to the SPLIT profile (sole active binding, so the pick is unambiguous).
do $$
declare uZ uuid := (select v from elfx where k='uZ'); r jsonb; v_hunt uuid; v_ep uuid := (select v from elfx where k='ep_split');
begin
  select id into v_hunt from public.locations where activity_type='hunt_pirates' and status='active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'SETUP FAIL: no active hunt_pirates location'; end if;
  insert into elfx values ('hunt', v_hunt);
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'elp-bind-hunt',
         jsonb_build_object('location_id', v_hunt::text, 'encounter_profile_id', v_ep::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL hunt: %', r; end if;
  update public.location_encounter_bindings set active = false
   where location_id = v_hunt and encounter_profile_id <> v_ep and active is true;
end $$;

create or replace function pg_temp.send_and_settle(p_uid uuid, p_group uuid, p_hunt uuid) returns uuid language plpgsql as $$
declare r jsonb; v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  r := pg_temp.call_as(p_uid, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', p_group, p_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  update public.fleet_movements set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute' where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then raise exception 'SETTLE FAIL: %', r; end if;
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status='active';
  if v_enc is null then raise exception 'SEND FAIL: no active encounter'; end if;
  return v_enc;
end $$;

-- ════════ (d) ELITE_PASS_FLAGOFF_SYNTHETIC — resolver off ⇒ the VERBATIM pre-resolver synthetic wave ══
update public.game_config set value='false'::jsonb where key='encounter_resolver_enabled';
do $$
declare uZ uuid := (select v from elfx where k='uZ'); g1 uuid := (select v from elfx where k='g1');
  v_hunt uuid := (select v from elfx where k='hunt'); v_enc uuid;
  v_lx double precision; v_ly double precision; n int;
  v_hpmax double precision; v_exp_hp double precision; v_px double precision; v_py double precision; v_ut text;
begin
  select x, y into v_lx, v_ly from public.locations where id = v_hunt;
  v_enc := pg_temp.send_and_settle(uZ, g1, v_hunt);
  insert into elfx values ('enc1', v_enc);

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
  if n <> 1 then raise exception 'ELITE PROOF FAIL FLAGOFF: % enemy rows (want the 1 synthetic)', n; end if;
  select hp_max, pos_x, pos_y, unit_type_id into v_hpmax, v_px, v_py, v_ut
    from public.combat_units where encounter_id = v_enc and side='enemy';
  if v_ut <> 'pirate_synthetic' then raise exception 'ELITE PROOF FAIL FLAGOFF: enemy unit_type % (want pirate_synthetic)', v_ut; end if;
  v_exp_hp := (select base_difficulty from public.locations where id = v_hunt)
              * coalesce(public.cfg_num('enemy_hp_base'),14)
              * (1 + 1 * coalesce(public.cfg_num('enemy_hp_danger_scale'),0.6)) * 1;
  if abs(v_hpmax - v_exp_hp) > 0.001 then raise exception 'ELITE PROOF FAIL FLAGOFF: enemy hp_max % <> the verbatim synthetic formula %', v_hpmax, v_exp_hp; end if;
  if v_px is distinct from v_lx or v_py is distinct from v_ly then raise exception 'ELITE PROOF FAIL FLAGOFF: enemy not at the location center'; end if;
  if (select resolved_plan_json from public.combat_encounters where id = v_enc) is not null then
    raise exception 'ELITE PROOF FAIL FLAGOFF: resolved_plan_json is not NULL on a synthetic encounter';
  end if;
  raise notice 'ELITE_PASS_FLAGOFF_SYNTHETIC';

  update public.combat_encounters set status='defeat', ended_at=now() where id = v_enc;
end $$;

-- ════════ (a)(b)(f) THE REAL CHAIN with the resolver ON — elite units spawn, are stronger, and FIGHT ══
update public.game_config set value='true'::jsonb where key='encounter_resolver_enabled';
do $$
declare uZ uuid := (select v from elfx where k='uZ'); g2 uuid := (select v from elfx where k='g2');
  v_hunt uuid := (select v from elfx where k='hunt'); v_enc uuid; v_plan jsonb;
  n int; v_ceiling int; v_mult double precision;
  v_hp_lo double precision; v_hp_hi double precision;
  v_pdmg double precision; v_edmg double precision; v_bad int;
begin
  v_ceiling := greatest(1, coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::integer);
  v_mult    := coalesce(public.cfg_num('encounter_elite_difficulty_multiplier'), 2);
  v_enc := pg_temp.send_and_settle(uZ, g2, v_hunt);
  insert into elfx values ('enc2', v_enc);

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  v_plan := (select resolved_plan_json from public.combat_encounters where id = v_enc);
  if v_plan is null then raise exception 'ELITE PROOF FAIL SPAWN: the encounter was not resolved (no plan tag)'; end if;
  if (v_plan->>'elite_policy') is distinct from 'multiplier_v1' then
    raise exception 'ELITE PROOF FAIL SPAWN: stored plan elite_policy % <> multiplier_v1', (v_plan->>'elite_policy');
  end if;

  -- (b) the ceiling still binds on what actually spawned.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
  if n <> 2 then raise exception 'ELITE PROOF FAIL SPAWN: % enemy rows (want 2 — 1 elite + 1 normal)', n; end if;
  if n > v_ceiling then raise exception 'ELITE PROOF FAIL SPAWN: % spawned enemy units exceeds the ceiling %', n, v_ceiling; end if;

  -- (a) the elite row's ship_hp is exactly the multiplier x the normal row's — through the IDENTICAL
  --     existing spawn insert (the tick has no elite branch).
  select min(ship_hp), max(ship_hp) into v_hp_lo, v_hp_hi
    from public.combat_units where encounter_id = v_enc and side='enemy';
  if v_hp_lo is null or v_hp_lo <= 0 then raise exception 'ELITE PROOF FAIL SPAWN: a spawned enemy has non-positive ship_hp'; end if;
  if abs(v_hp_hi - v_hp_lo * v_mult) > 0.001 then
    raise exception 'ELITE PROOF FAIL SPAWN: elite ship_hp % <> % x normal ship_hp % (the multiplier did not reach combat_units)', v_hp_hi, v_mult, v_hp_lo;
  end if;
  raise notice 'ELITE_PASS_SPAWN_STATS';

  -- (f) THE FLEET-1 REGRESSION GUARD. Every combat unit on BOTH sides must carry a non-empty
  --     weapons_json with positive power, and the tick must record real damage in BOTH directions.
  select count(*) into v_bad from public.combat_units cu
   where cu.encounter_id = v_enc
     and (cu.weapons_json is null
          or jsonb_typeof(cu.weapons_json) <> 'array'
          or jsonb_array_length(cu.weapons_json) = 0
          or not exists (select 1 from jsonb_array_elements(cu.weapons_json) w
                          where coalesce((w.value->>'power')::double precision, 0) > 0
                            and coalesce((w.value->>'range')::double precision, 0) > 0));
  if v_bad > 0 then
    raise exception 'ELITE PROOF FAIL WEAPONS: % combat_unit row(s) carry an empty/powerless weapons_json — this is the Fleet-1 zero-damage regression', v_bad;
  end if;
  select player_damage, enemy_damage into v_pdmg, v_edmg
    from public.combat_ticks where encounter_id = v_enc order by tick_number desc limit 1;
  if coalesce(v_pdmg, 0) <= 0 then
    raise exception 'ELITE PROOF FAIL DAMAGE: the player dealt % damage — the Fleet-1 zero-damage failure has recurred', v_pdmg;
  end if;
  if coalesce(v_edmg, 0) <= 0 then
    raise exception 'ELITE PROOF FAIL DAMAGE: the enemy (elite + normal) dealt % damage — the spawned enemies do not fight', v_edmg;
  end if;
  raise notice 'ELITE_PASS_WEAPONS_DAMAGE';
end $$;

do $$ begin raise notice 'ELITE STAT WIRING PROOF PASSED'; end $$;

rollback;
