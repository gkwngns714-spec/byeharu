-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- ENCOUNTER CANARY — DISPOSABLE EXACT-CHAIN PROOF (§3.4)
--
-- ██ THROWAWAY DATABASES ONLY. NEVER point this at production. ██
--   Run against a disposable local Supabase (`supabase start` applies the WHOLE migration chain, so every
--   in-migration self-assert of 0257→0271 runs here against real Postgres first). This file is
--   SELF-ROLLING-BACK: `begin; … rollback;`. Every flag flip happens ONLY inside that transaction and is
--   discarded. It commits NOTHING and keeps ZERO rows. The CI job that runs it carries NO `environment:`
--   key, so it cannot read production secrets.
--
-- WHAT IT REPRODUCES: the EXACT production canary chain, authored through the REAL owner RPCs —
--   reward_profile_create(canary_reward: metal base 7, danger_coeff 0.25, multiplier_ref reward_multiplier)
--     → enemy_archetype_create(canary_pirate: pirate_synthetic / spatial_synthetic / base_difficulty 1)
--       → enemy_fleet_template_create(canary_fleet: min 1 / max 1 / weight 1 / elite_chance 0)
--         → encounter_profile_create(canary_encounter: difficulty 1, cap 1, cooldown 30s, no override)
--           → location_encounter_binding_create(<hunt location>) then set_active(false)  ⇒ revision 2,
--             the EXACT production posture (binding authored, INACTIVE, rev 2).
--   The bound location is normalised to Reaver's shape (base_difficulty 15, reward_tier 2,
--   activity_type hunt_pirates, status active) so the literal expected numbers below are production's.
--   Every OTHER binding (incl. the 0259-seeded Snare↔pirate_basic one) is deactivated through the real
--   set_active RPC, mirroring production's isolation.
--
-- WHAT IT PROVES (one greppable PASS marker each):
--   ECP_PASS_INACTIVE_BINDING_NO_SPAWN   an INACTIVE binding produces no runtime encounter (resolver ON)
--   ECP_PASS_RESOLVER_OFF_NO_SPAWN       resolver OFF produces no runtime encounter
--   ECP_PASS_BINDING_ONLY_NO_SPAWN       activating ONLY the binding, resolver still OFF ⇒ no encounter
--   ECP_PASS_ACTIVATED_SPAWN             resolver ON + valid ACTIVE binding ⇒ the EXPECTED encounter
--   ECP_PASS_ONE_RUNTIME_ROW             exactly ONE encounter_runtime_state row is created
--   ECP_PASS_COOLDOWN_BLOCKS             the 30 s cooldown prevents a duplicate spawn, and self-heals
--   ECP_PASS_FLEET_COMPOSITION           the wave is exactly ONE canary_pirate, per the template
--   ECP_PASS_REWARD_MATCHES              the reward is metal-only, base 7 (literal 18 at tier 2/danger 1)
--   ECP_PASS_NON_ELITE                   no unit is elite; the plan is tagged elite_policy=disabled_v1
--   ECP_PASS_BINDING_DISABLED_STOPS      disabling the binding stops future spawns
--   ECP_PASS_RESOLVER_DISABLED_STOPS     disabling the resolver stops ALL resolver behaviour
--   ECP_PASS_NO_NEW_ACTIVE_CONTENT       at end of transaction nothing authored here is left active
--   "ENCOUNTER-CANARY PROOF PASSED"
--   ECP_PASS_ROLLBACK_CLEAN is emitted AFTER the rollback, by scripts/encounter-canary-proof.sh /
--   the workflow's post-rollback step — it can only be asserted from OUTSIDE this transaction.
--
-- SCENARIO GEOMETRY (inherited from scripts/encounter-resolver-proof.sql, the proven idiom): every drive
-- uses its OWN player + own single armed command ship + own team (group_index is capped at 3 per player,
-- so five scenarios need five players). The player and the enemy both spawn at the location centre
-- (dist 0) so neither moves; enemy_attack_base is 0 so no player ever dies; combat_damage_variance_pct is
-- pinned 0 (v_variance = 1) for determinism — no session RNG (the 0041 law). To force a deterministic
-- wave clear the surviving enemy's hp_current is set to 1 and the tick re-run: the CLEAR still runs
-- through the real process_combat_ticks path (the sanctioned clock-rewind sibling, not a fabricated
-- combat write).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

begin;

create temp table ecfx(k text primary key, v uuid) on commit drop;
create temp table ecfn(k text primary key, v double precision) on commit drop;

create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- ════════ SETUP: owner + config pins ═════════════════════════════════════════════════════════════════
do $$
declare uO uuid;
begin
  if (public.reveal_starter_ports()->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports'; end if;
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'ecp.owner.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uO;
  insert into ecfx values ('owner', uO);
  insert into public.app_owners(user_id) values (uO);
end $$;

-- dark gates flipped ONLY inside this rolled-back txn.
update public.game_config set value='true'::jsonb  where key='team_command_enabled';
update public.game_config set value='true'::jsonb  where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb  where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb  where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb  where key='spatial_combat_enabled';
update public.game_config set value='true'::jsonb  where key='enemy_content_registry_enabled';    -- E0
update public.game_config set value='true'::jsonb  where key='encounter_authoring_enabled';       -- E1
update public.game_config set value='true'::jsonb  where key='encounter_binding_authoring_enabled'; -- E2
update public.game_config set value='false'::jsonb where key='encounter_resolver_enabled';        -- E3 starts DARK
update public.game_config set value='false'::jsonb where key='pirate_intercept_enabled';          -- no en-route ambush noise

do $$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);      -- v_variance = 1
  perform public.set_game_config('combat_tick_logging',  'true'::jsonb);
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);
  perform public.set_game_config('enemy_hp_base',        '500'::jsonb);          -- the enemy survives the spawn tick
  perform public.set_game_config('enemy_hp_danger_scale','0.6'::jsonb);
  perform public.set_game_config('enemy_attack_base',    '0'::jsonb);            -- no player ever dies
  perform public.set_game_config('enemy_synthetic_range_base', '10000'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_max_units', '6'::jsonb);
  -- reward tunables pinned to the PRODUCTION values so the literal expectations below are production's.
  perform public.set_game_config('reward_metal_base',   '10'::jsonb);
  perform public.set_game_config('reward_danger_scale', '0.25'::jsonb);
  perform public.set_game_config('reward_multiplier',   '1.0'::jsonb);
end $$;

-- ════════ author the EXACT canary chain through the REAL owner RPCs ══════════════════════════════════
do $$
declare uO uuid := (select v from ecfx where k='owner'); r jsonb;
  v_rp uuid; v_arch uuid; v_fleet uuid; v_ep uuid;
begin
  r := pg_temp.call_as(uO, 'public.reward_profile_create(''ecp-rp-canary'', ''{"key":"canary_reward","display_name":"Canary Reward","resource_grants":{"metal":{"base":7,"danger_coeff":0.25,"multiplier_ref":"reward_multiplier"}}}''::jsonb)');
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL canary_reward: %', r; end if;
  v_rp := (r->'result'->>'id')::uuid;

  r := pg_temp.call_as(uO, format('public.enemy_archetype_create(%L, %L::jsonb)', 'ecp-arch-canary',
         jsonb_build_object('key','canary_pirate','display_name','Canary Pirate','unit_type_id','pirate_synthetic',
           'behavior_key','spatial_synthetic','base_difficulty',1,'difficulty_rating',1,
           'stat_overrides', '{}'::jsonb, 'default_reward_profile_id', v_rp::text)::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL canary_pirate: %', r; end if;
  v_arch := (r->'result'->>'id')::uuid;

  r := pg_temp.call_as(uO, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'ecp-fleet-canary',
         jsonb_build_object('key','canary_fleet','display_name','Canary Fleet','members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id',v_arch::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL canary_fleet: %', r; end if;
  v_fleet := (r->'result'->>'id')::uuid;

  r := pg_temp.call_as(uO, format('public.encounter_profile_create(%L, %L::jsonb)', 'ecp-ep-canary',
         jsonb_build_object('key','canary_encounter','display_name','Canary Encounter','difficulty',1,
           'active_encounter_cap',1,'cooldown_seconds',30,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_fleet::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL canary_encounter: %', r; end if;
  v_ep := (r->'result'->>'id')::uuid;

  insert into ecfx values ('rp', v_rp), ('arch', v_arch), ('fleet', v_fleet), ('ep', v_ep);
end $$;

-- ════════ choose + normalise the bound location; isolate it (deactivate EVERY other binding) ═════════
do $$
declare uO uuid := (select v from ecfx where k='owner'); r jsonb; b record;
  v_loc uuid; v_ep uuid := (select v from ecfx where k='ep'); v_bind uuid; v_rev integer;
begin
  -- every pre-existing binding (incl. the 0259 seed) goes INACTIVE through the REAL owner RPC — the
  -- production posture, and the precondition the readiness verifier enforces (CH07 isolation).
  for b in select id, revision from public.location_encounter_bindings where active is true order by id loop
    r := pg_temp.call_as(uO, format('public.location_encounter_binding_set_active(%L, %L::jsonb)',
           'ecp-deact-'||b.id::text,
           jsonb_build_object('target_id', b.id::text, 'expected_revision', b.revision, 'active', false)::text));
    if (r->>'ok')::boolean is not true then raise exception 'ISOLATE FAIL deactivating %: %', b.id, r; end if;
  end loop;
  if exists (select 1 from public.location_encounter_bindings where active is true) then
    raise exception 'ISOLATE FAIL: an active binding survived the sweep';
  end if;

  -- the canary location: an active hunt_pirates location, normalised to Reaver's shape.
  select id into v_loc from public.locations
   where activity_type = 'hunt_pirates' and status = 'active'
   order by min_power_required asc, base_difficulty asc, id limit 1;
  if v_loc is null then raise exception 'SETUP FAIL: no active hunt_pirates location'; end if;
  update public.locations set base_difficulty = 15, reward_tier = 2 where id = v_loc;
  insert into ecfx values ('loc', v_loc);

  -- author the binding, then set it INACTIVE ⇒ revision 2: the EXACT production posture.
  r := pg_temp.call_as(uO, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'ecp-bind-canary',
         jsonb_build_object('location_id', v_loc::text, 'encounter_profile_id', v_ep::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL canary: %', r; end if;
  v_bind := (r->'result'->>'id')::uuid;
  insert into ecfx values ('bind', v_bind);
  select revision into v_rev from public.location_encounter_bindings where id = v_bind;
  r := pg_temp.call_as(uO, format('public.location_encounter_binding_set_active(%L, %L::jsonb)', 'ecp-bind-canary-off',
         jsonb_build_object('target_id', v_bind::text, 'expected_revision', v_rev, 'active', false)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL set inactive: %', r; end if;

  select active, revision into b from public.location_encounter_bindings where id = v_bind;
  if b.active is not false or b.revision <> 2 then
    raise exception 'SETUP FAIL: canary binding posture is (active=%, revision=%) — want (false, 2)', b.active, b.revision;
  end if;
  raise notice 'ECP_SETUP: canary binding % is active=false revision=2 at location % (base_difficulty 15, reward_tier 2)', v_bind, v_loc;
end $$;

-- helper: flip the canary binding active/inactive through the REAL owner RPC.
create or replace function pg_temp.set_binding(p_active boolean) returns void language plpgsql as $$
declare uO uuid := (select v from ecfx where k='owner'); v_bind uuid := (select v from ecfx where k='bind');
  v_rev integer; r jsonb;
begin
  select revision into v_rev from public.location_encounter_bindings where id = v_bind;
  r := pg_temp.call_as(uO, format('public.location_encounter_binding_set_active(%L, %L::jsonb)',
         'ecp-setactive-'||p_active::text||'-'||v_rev::text,
         jsonb_build_object('target_id', v_bind::text, 'expected_revision', v_rev, 'active', p_active)::text));
  if (r->>'ok')::boolean is not true then raise exception 'SET_BINDING FAIL (%): %', p_active, r; end if;
end $$;

-- helper: a brand-new player with ONE armed command ship in team slot 1; returns the group id.
create or replace function pg_temp.new_armed_player(p_tag text) returns uuid language plpgsql as $$
declare uP uuid; r jsonb; s uuid; m uuid; g uuid;
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'ecp.'||p_tag||'.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uP;
  insert into public.player_wallet (player_id, balance) values (uP, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;

  r := pg_temp.call_as(uP, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL ship (%): %', p_tag, r; end if;
  select main_ship_id into s from public.main_ship_instances where player_id = uP;

  -- retire the commission dock fleet (the team-command-proof normalisation, mirrored).
  update public.main_ship_instances set status='home', updated_at=now() where main_ship_id = s;
  update public.fleets set status='destroyed', location_mode='destroyed', active_movement_id=null,
         current_base_id=null, current_location_id=null, current_zone_id=null, current_sector_id=null, updated_at=now()
   where main_ship_id = s and status='present';
  update public.location_presence set status='completed', updated_at=now()
   where fleet_id in (select id from public.fleets where main_ship_id = s and status='destroyed') and status='active';

  perform public.reward_grant('combat', gen_random_uuid(), uP, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);
  r := pg_temp.call_as(uP, format('public.craft_module(%L, ''autocannon_battery'')', 'ecp-gun-'||p_tag));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft (%): %', p_tag, r; end if;
  m := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uP, format('public.fit_module_to_ship(%L::uuid, %L::uuid, %L)', m, s, 'ecp-fit-'||p_tag));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit (%): %', p_tag, r; end if;

  r := pg_temp.call_as(uP, format('public.upsert_ship_group(1, %L)', 'ECP '||p_tag));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group (%): %', p_tag, r; end if;
  g := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uP, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s, g));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign (%): %', p_tag, r; end if;
  r := pg_temp.call_as(uP, format('public.set_fleet_command_ship(%L::uuid, true)', s));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL command (%): %', p_tag, r; end if;

  insert into ecfx values ('u_'||p_tag, uP), ('g_'||p_tag, g);
  return g;
end $$;

-- helper: send that team to the canary location, settle arrival, and return the fresh encounter id.
create or replace function pg_temp.drive(p_tag text) returns uuid language plpgsql as $$
declare uP uuid := (select v from ecfx where k='u_'||p_tag); g uuid := (select v from ecfx where k='g_'||p_tag);
  v_loc uuid := (select v from ecfx where k='loc'); r jsonb; v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  r := pg_temp.call_as(uP, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', g, v_loc));
  if (r->>'ok')::boolean is not true then raise exception 'SEND FAIL (%): %', p_tag, r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  update public.fleet_movements set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute' where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then raise exception 'SETTLE FAIL (%): %', p_tag, r; end if;
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status='active';
  if v_enc is null then raise exception 'DRIVE FAIL (%): no active encounter', p_tag; end if;
  -- spawn tick.
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();
  insert into ecfx values ('enc_'||p_tag, v_enc);
  return v_enc;
end $$;

-- helper: assert the encounter took the LEGACY SYNTHETIC arm (no canary), and the ledger is untouched.
create or replace function pg_temp.assert_synthetic(p_tag text, p_ctx text) returns void language plpgsql as $$
declare v_enc uuid := (select v from ecfx where k='enc_'||p_tag); v_loc uuid := (select v from ecfx where k='loc');
  v_ep uuid := (select v from ecfx where k='ep'); n integer; v_hp double precision; v_exp double precision;
  v_ac integer; v_before integer;
begin
  if (select resolved_plan_json from public.combat_encounters where id = v_enc) is not null then
    raise exception 'ECP FAIL (%): resolved_plan_json is NOT NULL — a canary encounter was produced when it must not be', p_ctx;
  end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
  if n < 1 then raise exception 'ECP FAIL (%): no enemy spawned at all (% rows) — the legacy synthetic wave did not run', p_ctx, n; end if;
  select hp_max into v_hp from public.combat_units where encounter_id = v_enc and side='enemy' limit 1;
  -- the legacy arm scales off the LOCATION base_difficulty (15), not the archetype's (1).
  v_exp := 15 * public.cfg_num('enemy_hp_base') * (1 + 1 * public.cfg_num('enemy_hp_danger_scale')) / greatest(n,1);
  if abs(v_hp - v_exp) > 0.001 then
    raise exception 'ECP FAIL (%): enemy hp_max % <> the legacy synthetic per-unit value % — this is not the pre-canary wave', p_ctx, v_hp, v_exp;
  end if;
  -- the runtime ledger must not have gained a spawn.
  select coalesce((select v from ecfn where k='ledger_baseline'), 0)::integer into v_before;
  select coalesce((select s.active_count from public.encounter_runtime_state s
                    where s.location_id = v_loc and s.encounter_profile_id = v_ep), 0) into v_ac;
  if v_ac <> v_before then
    raise exception 'ECP FAIL (%): encounter_runtime_state.active_count moved % -> % — the resolver spawned when it must not have', p_ctx, v_before, v_ac;
  end if;
  -- retire this scenario's encounter so a LATER scenario's tick cannot re-wave (and possibly re-resolve)
  -- it, which would silently consume the canary's cap / cooldown budget.
  update public.combat_encounters set status='defeat', ended_at=now() where id = v_enc;
end $$;

do $$ begin insert into ecfn values ('ledger_baseline', 0); end $$;

-- ════════ SCENARIO 1 — resolver ON, binding INACTIVE ⇒ NO runtime canary encounter ═══════════════════
update public.game_config set value='true'::jsonb where key='encounter_resolver_enabled';
do $$
declare v_loc uuid := (select v from ecfx where k='loc'); g uuid;
begin
  if (select active from public.location_encounter_bindings where id = (select v from ecfx where k='bind')) is not false then
    raise exception 'ECP FAIL S1: the canary binding is not inactive at the start of scenario 1';
  end if;
  -- the resolver itself refuses: no ACTIVE binding at this location ⇒ NULL plan.
  if public.resolve_location_encounter(v_loc, 'ecp-s1') is not null then
    raise exception 'ECP FAIL INACTIVE_BINDING: resolve_location_encounter returned a plan for an INACTIVE binding';
  end if;
  g := pg_temp.new_armed_player('s1');
  perform pg_temp.drive('s1');
  perform pg_temp.assert_synthetic('s1', 'INACTIVE_BINDING');
  if exists (select 1 from public.encounter_runtime_state) then
    raise exception 'ECP FAIL INACTIVE_BINDING: encounter_runtime_state is non-empty — a canary spawn was recorded';
  end if;
  raise notice 'ECP_PASS_INACTIVE_BINDING_NO_SPAWN';
end $$;

-- ════════ SCENARIO 2 — binding ACTIVATED but resolver OFF ⇒ still NO runtime canary encounter ════════
do $$ begin perform pg_temp.set_binding(true); end $$;
update public.game_config set value='false'::jsonb where key='encounter_resolver_enabled';
do $$
declare v_loc uuid := (select v from ecfx where k='loc'); g uuid;
begin
  if (select active from public.location_encounter_bindings where id = (select v from ecfx where k='bind')) is not true then
    raise exception 'ECP FAIL S2: the canary binding did not activate';
  end if;
  -- (a) resolver OFF ⇒ the quad-flag gate short-circuits before any content read.
  if public.resolve_location_encounter(v_loc, 'ecp-s2') is not null then
    raise exception 'ECP FAIL RESOLVER_OFF: resolve_location_encounter returned a plan with encounter_resolver_enabled=false';
  end if;
  raise notice 'ECP_PASS_RESOLVER_OFF_NO_SPAWN';

  -- (b) and the REAL combat path with ONLY the binding activated still produces the legacy synthetic wave.
  g := pg_temp.new_armed_player('s2');
  perform pg_temp.drive('s2');
  perform pg_temp.assert_synthetic('s2', 'BINDING_ONLY');
  if exists (select 1 from public.encounter_runtime_state) then
    raise exception 'ECP FAIL BINDING_ONLY: encounter_runtime_state is non-empty — activating the binding alone spawned a canary';
  end if;
  raise notice 'ECP_PASS_BINDING_ONLY_NO_SPAWN';
end $$;

-- ════════ SCENARIO 3 — resolver ON + ACTIVE valid binding ⇒ the EXPECTED canary encounter ════════════
update public.game_config set value='true'::jsonb where key='encounter_resolver_enabled';
do $$
declare
  v_loc uuid := (select v from ecfx where k='loc'); v_ep uuid := (select v from ecfx where k='ep');
  v_arch uuid := (select v from ecfx where k='arch'); v_rp uuid := (select v from ecfx where k='rp');
  v_enc uuid; g uuid; n integer; v_plan jsonb; u jsonb; v_hp double precision; v_exp double precision;
  v_lx double precision; v_ly double precision; v_px double precision; v_py double precision;
  v_rows integer; v_ac integer; v_grants jsonb; v_reskey text;
begin
  select x, y into v_lx, v_ly from public.locations where id = v_loc;
  g := pg_temp.new_armed_player('s3');
  v_enc := pg_temp.drive('s3');

  -- ── the encounter is the RESOLVED one, tagged with the canary profile.
  v_plan := (select resolved_plan_json from public.combat_encounters where id = v_enc);
  if v_plan is null then
    raise exception 'ECP FAIL ACTIVATED: resolved_plan_json is NULL — the canary did NOT spawn with the resolver on and a valid active binding';
  end if;
  if (v_plan->>'encounter_profile_id') <> v_ep::text then
    raise exception 'ECP FAIL ACTIVATED: the encounter is tagged with profile % (want the canary %)', v_plan->>'encounter_profile_id', v_ep;
  end if;
  if (v_plan->>'active_encounter_cap') <> '1' or (v_plan->>'cooldown_seconds') <> '30' then
    raise exception 'ECP FAIL ACTIVATED: plan cap/cooldown are (%, %) — want (1, 30)', v_plan->>'active_encounter_cap', v_plan->>'cooldown_seconds';
  end if;
  raise notice 'ECP_PASS_ACTIVATED_SPAWN';

  -- ── ECP_PASS_ONE_RUNTIME_ROW: exactly ONE ledger row, for exactly this (location, profile), count 1.
  select count(*) into v_rows from public.encounter_runtime_state;
  if v_rows <> 1 then raise exception 'ECP FAIL ONE_RUNTIME_ROW: % encounter_runtime_state row(s) (want exactly 1)', v_rows; end if;
  select active_count into v_ac from public.encounter_runtime_state
   where location_id = v_loc and encounter_profile_id = v_ep;
  if v_ac is null then raise exception 'ECP FAIL ONE_RUNTIME_ROW: the single row is not for (canary location, canary profile)'; end if;
  if v_ac <> 1 then raise exception 'ECP FAIL ONE_RUNTIME_ROW: active_count % (want 1 on the first spawn)', v_ac; end if;
  update ecfn set v = 1 where ecfn.k = 'ledger_baseline';
  raise notice 'ECP_PASS_ONE_RUNTIME_ROW';

  -- ── ECP_PASS_FLEET_COMPOSITION: the plan and the spawned units are EXACTLY one canary_pirate.
  if jsonb_array_length(v_plan->'units') <> 1 then
    raise exception 'ECP FAIL FLEET_COMPOSITION: the plan carries % unit spec(s) (want 1): %', jsonb_array_length(v_plan->'units'), v_plan;
  end if;
  u := v_plan->'units'->0;
  if (u->>'enemy_archetype_id') <> v_arch::text or (u->>'count') <> '1'
     or (u->>'unit_type_id') <> 'pirate_synthetic' or (u->>'base_difficulty')::double precision <> 1 then
    raise exception 'ECP FAIL FLEET_COMPOSITION: unit spec % does not match the canary_pirate template member (1x, pirate_synthetic, base_difficulty 1)', u;
  end if;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
  if n <> 1 then raise exception 'ECP FAIL FLEET_COMPOSITION: % enemy combat_units row(s) (want exactly 1)', n; end if;
  select hp_max, pos_x, pos_y into v_hp, v_px, v_py from public.combat_units
   where encounter_id = v_enc and side='enemy' and unit_type_id='pirate_synthetic';
  -- resolved hp uses the ARCHETYPE base_difficulty (1), not the location's (15).
  v_exp := 1 * public.cfg_num('enemy_hp_base') * (1 + 1 * public.cfg_num('enemy_hp_danger_scale'));
  if abs(v_hp - v_exp) > 0.001 then
    raise exception 'ECP FAIL FLEET_COMPOSITION: enemy hp_max % <> archetype-derived % (degraded to the synthetic wave?)', v_hp, v_exp;
  end if;
  if abs(v_hp - 15 * public.cfg_num('enemy_hp_base') * (1 + 1 * public.cfg_num('enemy_hp_danger_scale'))) < 0.001 then
    raise exception 'ECP FAIL FLEET_COMPOSITION: the resolved hp is indistinguishable from the legacy synthetic hp — the test cannot discriminate the arm';
  end if;
  if v_px is distinct from v_lx or v_py is distinct from v_ly then
    raise exception 'ECP FAIL FLEET_COMPOSITION: the canary enemy is not at the location centre (%,% vs %,%)', v_px, v_py, v_lx, v_ly;
  end if;
  raise notice 'ECP_PASS_FLEET_COMPOSITION';

  -- ── ECP_PASS_NON_ELITE: elite_chance 0 stays non-elite; the plan is tagged elite_policy=disabled_v1.
  if (select elite_chance from public.enemy_fleet_template_members
       where fleet_template_id = (select v from ecfx where k='fleet')) <> 0 then
    raise exception 'ECP FAIL NON_ELITE: the canary template member does not carry elite_chance 0';
  end if;
  if (v_plan->>'elite_policy') is distinct from 'disabled_v1' then
    raise exception 'ECP FAIL NON_ELITE: plan elite_policy % <> disabled_v1', v_plan->>'elite_policy';
  end if;
  if u ? 'is_elite' then raise exception 'ECP FAIL NON_ELITE: the resolved unit carries an is_elite key: %', u; end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='combat_units' and column_name='is_elite') then
    raise exception 'ECP FAIL NON_ELITE: combat_units still carries an is_elite column (0261 dropped it)';
  end if;
  raise notice 'ECP_PASS_NON_ELITE';

  -- ── ECP_PASS_REWARD_MATCHES: metal-only, base 7. Force the wave clear through the REAL tick path.
  v_grants := v_plan->'reward_profile'->'resource_grants';
  if (v_plan->'reward_profile'->>'id') <> v_rp::text then
    raise exception 'ECP FAIL REWARD: the plan resolved reward profile % (want canary_reward %)', v_plan->'reward_profile'->>'id', v_rp;
  end if;
  for v_reskey in select jsonb_object_keys(v_grants) loop
    if v_reskey <> 'metal' then raise exception 'ECP FAIL REWARD: resource_grants carries an unsupported resource %: %', v_reskey, v_grants; end if;
  end loop;
  if (v_grants->'metal'->>'base')::double precision <> 7 then
    raise exception 'ECP FAIL REWARD: metal base % (want 7)', v_grants->'metal'->>'base';
  end if;

  update public.combat_units set hp_current = 1 where encounter_id = v_enc and side='enemy';
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();
  if (select waves_cleared from public.combat_encounters where id = v_enc) < 1 then
    raise exception 'ECP FAIL REWARD: the wave did not clear';
  end if;
  select ((total_rewards_json->>'metal')::double precision) into v_hp from public.combat_encounters where id = v_enc;
  -- reward_tier 2, danger 1 ⇒ round(7 * 2 * (1 + 0.25*1) * 1.0) = 18 (production's literal value).
  v_exp := public.resolve_encounter_reward_inputs(v_grants, 2, 1);
  if v_exp <> 18 then raise exception 'ECP FAIL REWARD: the canary reward formula yields % (want the production literal 18)', v_exp; end if;
  if v_hp is distinct from v_exp then
    raise exception 'ECP FAIL REWARD: paid metal % <> the canary profile value % (did the legacy base-10 formula pay instead?)', v_hp, v_exp;
  end if;
  if v_exp = round(public.cfg_num('reward_metal_base') * 2 * (1 + public.cfg_num('reward_danger_scale') * 1) * public.cfg_num('reward_multiplier')) then
    raise exception 'ECP FAIL REWARD: the canary (base 7) reward is indistinguishable from the legacy (base 10) reward — the test cannot discriminate';
  end if;
  raise notice 'ECP_PASS_REWARD_MATCHES';
end $$;

-- ════════ COOLDOWN — the 30 s throttle blocks a duplicate spawn, then self-heals ═════════════════════
do $$
declare v_loc uuid := (select v from ecfx where k='loc'); v_ep uuid := (select v from ecfx where k='ep');
  v_enc uuid := (select v from ecfx where k='enc_s3');
begin
  -- retire the scenario-3 encounter so the DERIVED cap (1) is no longer the reason for a NULL plan —
  -- isolating the cooldown as the ONLY remaining brake.
  update public.combat_encounters set status='defeat', ended_at=now() where id = v_enc;
  if public.resolve_location_encounter(v_loc, 'ecp-cd-1') is not null then
    raise exception 'ECP FAIL COOLDOWN: resolve returned a plan INSIDE the 30 s cooldown window';
  end if;
  -- back-date the ledger past the window ⇒ the brake releases (proving cooldown, not something else, blocked).
  update public.encounter_runtime_state set last_spawn_at = now() - interval '1 hour'
   where location_id = v_loc and encounter_profile_id = v_ep;
  if public.resolve_location_encounter(v_loc, 'ecp-cd-2') is null then
    raise exception 'ECP FAIL COOLDOWN: resolve stayed NULL after the cooldown window elapsed — something other than cooldown is blocking';
  end if;
  raise notice 'ECP_PASS_COOLDOWN_BLOCKS';
end $$;

-- ════════ SCENARIO 4 — the binding is DISABLED ⇒ future spawns stop (resolver still ON) ══════════════
do $$ begin perform pg_temp.set_binding(false); end $$;
do $$
declare v_loc uuid := (select v from ecfx where k='loc'); g uuid;
begin
  if public.cfg_bool('encounter_resolver_enabled') is not true then
    raise exception 'ECP FAIL S4: the resolver must still be ON so the BINDING is the only cause';
  end if;
  if public.resolve_location_encounter(v_loc, 'ecp-s4') is not null then
    raise exception 'ECP FAIL BINDING_DISABLED: resolve returned a plan after the binding was disabled';
  end if;
  g := pg_temp.new_armed_player('s4');
  perform pg_temp.drive('s4');
  perform pg_temp.assert_synthetic('s4', 'BINDING_DISABLED');
  raise notice 'ECP_PASS_BINDING_DISABLED_STOPS';
end $$;

-- ════════ SCENARIO 5 — the RESOLVER is disabled ⇒ all resolver behaviour stops (binding back ON) ══════
do $$ begin perform pg_temp.set_binding(true); end $$;
update public.game_config set value='false'::jsonb where key='encounter_resolver_enabled';
do $$
declare v_loc uuid := (select v from ecfx where k='loc'); v_ep uuid := (select v from ecfx where k='ep');
  g uuid; r record;
begin
  -- clear the cooldown so ONLY the resolver flag can be the cause.
  update public.encounter_runtime_state set last_spawn_at = now() - interval '1 hour'
   where location_id = v_loc and encounter_profile_id = v_ep;
  if (select active from public.location_encounter_bindings where id = (select v from ecfx where k='bind')) is not true then
    raise exception 'ECP FAIL S5: the binding must be ACTIVE so the RESOLVER flag is the only cause';
  end if;
  -- the resolver returns NULL for EVERY location while dark, not just this one.
  for r in select id from public.locations where status='active' limit 25 loop
    if public.resolve_location_encounter(r.id, 'ecp-s5') is not null then
      raise exception 'ECP FAIL RESOLVER_DISABLED: resolve returned a plan for location % with the resolver dark', r.id;
    end if;
  end loop;
  g := pg_temp.new_armed_player('s5');
  perform pg_temp.drive('s5');
  perform pg_temp.assert_synthetic('s5', 'RESOLVER_DISABLED');
  raise notice 'ECP_PASS_RESOLVER_DISABLED_STOPS';
end $$;

-- ════════ ROLLBACK POSTURE — nothing authored here is left ACTIVE inside the txn ═════════════════════
do $$ begin perform pg_temp.set_binding(false); end $$;
do $$
declare n integer;
begin
  if public.cfg_bool('encounter_resolver_enabled') is not false then
    raise exception 'ECP FAIL NO_NEW_ACTIVE_CONTENT: encounter_resolver_enabled is not false at the end of the proof';
  end if;
  select count(*) into n from public.location_encounter_bindings where active is true;
  if n <> 0 then raise exception 'ECP FAIL NO_NEW_ACTIVE_CONTENT: % active binding(s) remain', n; end if;
  raise notice 'ECP_PASS_NO_NEW_ACTIVE_CONTENT';
end $$;

do $$ begin raise notice 'ENCOUNTER-CANARY PROOF PASSED'; end $$;

rollback;
