-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- ENCOUNTER RESOLVER + DAMAGE CANARY — the PRE-FLIP, ROLLBACK-ONLY production damage-path proof.
--
-- ONE transaction. It flips encounter_resolver_enabled ONLY inside this uncommitted txn (visible to
-- nothing else), inserts a UNIQUELY-TAGGED ('RDCANARY') synthetic expendable player + ships, drives the
-- REAL resolver + combat-damage engine (resolve_location_encounter(uuid,text) / combat_create_group_
-- encounter / process_combat_ticks) against that synthetic fleet, asserts the damage/reward/isolation
-- properties, and ALWAYS ends in `rollback;`. NOTHING commits — not the flag, not a fixture, not a tick.
--
-- WHY THIS EXISTS: encounter_resolver_enabled is committed-FALSE; flipping it globally fires the resolver
-- for all ~30 live players (OWNER-GATED, out of scope). A prior canary destroyed the owner's main fleet
-- because an empty player combat_units.weapons_json fired zero shots → 0 damage → guaranteed loss;
-- migration 0262 (combat_player_fallback_weapon) is the fix. This canary proves — WITHOUT flipping a real
-- flag or risking a real asset — that (A) an armed synthetic fleet deals real damage / earns exactly one
-- reward / stays isolated, and (B) the 0262 remediation holds for the exact prior catastrophe (an
-- empty-loadout unit still deals > 0 damage). It is prod-run OWNER-GATED (scripts/encounter-resolver-
-- damage-canary.sh production, `production` Environment).
--
-- REAL PATH DRIVEN (verified against the live migration chain, never invented):
--   • authoring:  reward_profile_create / enemy_archetype_create / enemy_fleet_template_create /
--                 encounter_profile_create / location_encounter_binding_create   (0257/0258/0259 owner RPCs)
--   • resolver:   resolve_location_encounter(uuid, text)   (0261 signature; 0272 live body — TWO-ARG form)
--   • encounter:  combat_create_group_encounter(uuid)      (the SOLE writer of a side='player' combat_units
--                 row with weapons_json — the 0262 surface), reached via the real send/settle chain
--                 send_ship_group_hunt → movement_settle_arrival.
--   • damage:     process_combat_ticks()                   (0261/0272 live body — the combat tick).
-- Provisioning is 100% real-RPC (reveal_starter_ports / commission_first_main_ship / commission_additional_
-- main_ship / captains_mint_instance / assign_captain_to_ship / reward_grant / craft_module /
-- fit_module_to_ship / upsert_ship_group / assign_ship_to_group / set_fleet_command_ship). combat_units and
-- group_sortie_members are written ONLY by those engine functions — never hand-rolled here (the sole-writer
-- law), save the ONE sanctioned knock-enemy-to-1-hp surgery to force a deterministic wave-clear through the
-- REAL tick (the encounter-resolver-proof clock-rewind idiom's sibling).
--
-- ██ BLAST-RADIUS CONFINEMENT (prod is LIVE multiplayer): process_combat_ticks() has no per-encounter
-- ██ scope, so BEFORE ticking we FENCE every OTHER active/retreating encounter (bump last_resolved_at =
-- ██ now(), so the tick's own `now() - last_resolved_at >= tick_secs` guard SKIPS them) and rewind ONLY the
-- ██ canary encounter. The tick therefore processes the canary encounter ALONE. We snapshot a digest of
-- ██ every non-canary combat_encounters / combat_units / fleets / main_ship_instances row AFTER the fence
-- ██ and re-check it after both canaries — assertion (8) fails CLOSED if the tick bled into any of them.
-- ██ The only non-canary writes are the fence bump + a defensive deactivation of any pre-existing binding
-- ██ at the hunt location — both rolled back, neither a fleet/ship/inventory/movement/ranking/combat row.
--
-- Determinism (the 0041 law): combat_damage_variance_pct pinned 0 (v_variance = 1); no session RNG in
-- combat math (gen_random_uuid() is fixture identity only). enemy_attack_base pinned 0 so the synthetic
-- pirate deals 0 damage — the canary fleet is never at risk and player-hull isolation is exact.
--
-- FINDINGS MODEL: fail-closed. Every property is a `raise exception` (CANARY_A_* / CANARY_B_* FAIL) so any
-- blocking finding aborts the run with a non-zero exit (the outer txn is left aborted → rolled back;
-- nothing commits). The `CANARY_RESULT: PASS` line prints ONLY when every assertion held; a finding is the
-- raised exception itself (CANARY_RESULT: FINDINGS is the aborted path).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

begin;

-- fail fast on the live pooler: cap the whole canary and never wait on a contended lock.
set local statement_timeout = '30s';
set local lock_timeout = '2s';

-- ── fixture registry (text-valued so it also holds the isolation digests) — rolled back with the txn ──
create temp table rdc(k text primary key, v text);

create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $fn$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $fn$;

-- digest of every NON-canary combat/fleet/ship row (assertion 8's witness). Computed AFTER the fence, so
-- the deliberate last_resolved_at bump is already in the baseline; any later delta = the tick bled out.
create or replace function pg_temp.noncanary_digest(p_uid uuid) returns text language sql as $fn$
  select md5(coalesce(string_agg(d, '|' order by d), ''))
  from (
    select 'ce:'||to_jsonb(ce.*)::text as d from public.combat_encounters   ce where ce.player_id is distinct from p_uid
    union all
    select 'cu:'||to_jsonb(cu.*)::text      from public.combat_units        cu where cu.player_id is distinct from p_uid
    union all
    select 'fl:'||to_jsonb(f.*)::text       from public.fleets              f  where f.player_id  is distinct from p_uid
    union all
    select 'ms:'||to_jsonb(m.*)::text       from public.main_ship_instances m  where m.player_id  is distinct from p_uid
  ) s
$fn$;

-- ════════ SETUP: reveal starter ports + ONE funded, uniquely-tagged expendable player (also the owner) ═
do $$
declare r jsonb; uZ uuid;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'CANARY SETUP FAIL: reveal_starter_ports %', r; end if;

  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'rdcanary.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uZ;
  insert into rdc values ('uZ', uZ::text);
  insert into public.player_wallet (player_id, balance) values (uZ, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  insert into public.app_owners(user_id) values (uZ);   -- authoring caller (is_owner via app_owners); canary-only
end $$;

-- ── dark capability gates — flipped ONLY inside this rolled-back txn (committed values stay false). The
--    resolver flag flip is THE canary's subject; the rest are the provisioning/authoring prerequisites. ─
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='captain_assignment_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
update public.game_config set value='true'::jsonb where key='enemy_content_registry_enabled';
update public.game_config set value='true'::jsonb where key='encounter_authoring_enabled';
update public.game_config set value='true'::jsonb where key='encounter_binding_authoring_enabled';
-- ██ THE SUBJECT OF THE CANARY: flip the resolver ON, ONLY inside this uncommitted txn. Rolled back. ██
update public.game_config set value='true'::jsonb where key='encounter_resolver_enabled';

-- ── tuning knobs (direct in-txn UPDATE — NO set_game_config, so nothing can persist a value outside the
--    txn). The engineered geometry (armed/fallback ship at the location center in weapon range; pirate at
--    the center dealing 0 damage) depends on these exact values. ─────────────────────────────────────
update public.game_config set value='0'::jsonb    where key='combat_damage_variance_pct';   -- v_variance = 1 (determinism)
update public.game_config set value='true'::jsonb where key='combat_tick_logging';           -- so combat_ticks rows land
update public.game_config set value='true'::jsonb where key='combat_event_logging';          -- so missile_salvo/explosion events land
update public.game_config set value='500'::jsonb  where key='enemy_hp_base';                  -- pirate survives the shot (hp falls, not to 0)
update public.game_config set value='0'::jsonb    where key='enemy_attack_base';              -- pirate deals 0 damage (fleet never at risk)
update public.game_config set value='10000'::jsonb where key='enemy_synthetic_range_base';    -- pirate in range at dist 0 (fires, 0 damage)
update public.game_config set value='0'::jsonb    where key='enemy_synthetic_range_per_difficulty';
update public.game_config set value='0'::jsonb    where key='enemy_synthetic_speed_base';     -- pirate holds at the center
update public.game_config set value='0'::jsonb    where key='enemy_synthetic_speed_per_difficulty';

-- ════════ AUTHOR the encounter content through the REAL owner RPCs (E0-E2). reward base=20 is DISTINCT
--          from the config default (10), so a resolved reward VALUE proves the adapter branch was taken. ═
do $$
declare uZ uuid := (select v::uuid from rdc where k='uZ'); r jsonb;
  v_rp uuid; v_arch uuid; v_fleet uuid; v_ep uuid;
begin
  r := pg_temp.call_as(uZ, 'public.reward_profile_create(''rdc-rp-1'', ''{"key":"rdc_reward","display_name":"RDC Reward","resource_grants":{"metal":{"base":20,"danger_coeff":0.25,"multiplier_ref":"reward_multiplier"}}}''::jsonb)');
  if (r->>'ok')::boolean is not true then raise exception 'CANARY AUTHOR FAIL reward_profile: %', r; end if;
  v_rp := (r->'result'->>'id')::uuid;

  r := pg_temp.call_as(uZ, format('public.enemy_archetype_create(%L, %L::jsonb)', 'rdc-arch-1',
         jsonb_build_object('key','rdc_arch','display_name','RDC Arch','unit_type_id','pirate_synthetic',
           'base_difficulty',5,'difficulty_rating',1,'default_reward_profile_id',v_rp::text)::text));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY AUTHOR FAIL archetype: %', r; end if;
  v_arch := (r->'result'->>'id')::uuid;

  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'rdc-fleet-1',
         jsonb_build_object('key','rdc_fleet','display_name','RDC Fleet',
           'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id',v_arch::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY AUTHOR FAIL fleet: %', r; end if;
  v_fleet := (r->'result'->>'id')::uuid;

  -- cap=1, cooldown=0: cap=1 is the idempotency/CAP witness; cooldown 0 keeps CAP isolated.
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'rdc-ep-1',
         jsonb_build_object('key','rdc_ep','display_name','RDC EP','active_encounter_cap',1,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_fleet::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY AUTHOR FAIL ep: %', r; end if;
  v_ep := (r->'result'->>'id')::uuid;

  insert into rdc values ('rp', v_rp::text), ('arch', v_arch::text), ('fleet', v_fleet::text), ('ep', v_ep::text);
end $$;

-- ════════ Select the real weakest hunt location + bind it to rdc_ep as the SOLE active binding ════════
do $$
declare uZ uuid := (select v::uuid from rdc where k='uZ'); r jsonb; v_hunt uuid; v_ep uuid := (select v::uuid from rdc where k='ep');
begin
  select id into v_hunt from public.locations
    where activity_type = 'hunt_pirates' and status = 'active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'CANARY SETUP FAIL: no active hunt_pirates location'; end if;
  insert into rdc values ('hunt', v_hunt::text);

  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'rdc-bind-hunt',
         jsonb_build_object('location_id', v_hunt::text, 'encounter_profile_id', v_ep::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY BIND FAIL hunt: %', r; end if;
  -- defensively make rdc_ep the SOLE active binding so the weighted pick is deterministic regardless of
  -- seed (rolled back; a binding row, not a fleet/ship/combat row — outside assertion-8 scope).
  update public.location_encounter_bindings set active = false
   where location_id = v_hunt and encounter_profile_id <> v_ep and active is true;
end $$;

-- ════════ PROVISION: s_arm (real autocannon — Canary A) + s_fb (captain attack, NO weapon — Canary B) ═
do $$
declare
  uZ uuid := (select v::uuid from rdc where k='uZ'); r jsonb;
  s_arm uuid; s_fb uuid; v_cap uuid; v_mod uuid; gA uuid; gB uuid;
begin
  r := pg_temp.call_as(uZ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL 1st ship: %', r; end if;
  select main_ship_id into s_arm from public.main_ship_instances where player_id = uZ;

  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'CANARY PROVISION FAIL 2nd ship: %', r; end if;
  s_fb := (r->>'main_ship_id')::uuid;
  insert into rdc values ('s_arm', s_arm::text), ('s_fb', s_fb::text);

  -- retire each ship's commission 'present' dock fleet + complete its presence (the team-command/combat-
  -- spatial-proof normalization, verbatim): the send readiness gate treats a dock-fleet member as NOT
  -- ready, and this leaves each ship settled-SAFE ('home') — the state fit/assign require.
  update public.main_ship_instances set status='home', updated_at=now() where main_ship_id in (s_arm, s_fb);
  update public.fleets set status='destroyed', location_mode='destroyed', active_movement_id=null,
         current_base_id=null, current_location_id=null, current_zone_id=null, current_sector_id=null, updated_at=now()
   where main_ship_id in (s_arm, s_fb) and status='present';
  update public.location_presence set status='completed', updated_at=now()
   where fleet_id in (select id from public.fleets where main_ship_id in (s_arm, s_fb) and status='destroyed') and status='active';

  -- s_arm: a real autocannon_battery (power 10, range 150). Fund the recipe via the real Reward writer.
  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 4}, {"item_id": "pirate_alloy", "quantity": 2}, {"item_id": "scrap", "quantity": 6}]}'::jsonb);
  r := pg_temp.call_as(uZ, 'public.craft_module(''rdc-gun-1'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL craft: %', r; end if;
  v_mod := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''rdc-fit-1'')', v_mod, s_arm));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL fit: %', r; end if;

  -- s_fb: a gunnery_veteran captain (attack → combat_power) with NO weapon module fitted → its RAW
  -- fitted-weapon join is EMPTY = the exact prior catastrophe (0262 must synthesize the fallback weapon).
  v_cap := public.captains_mint_instance(uZ, 'gunnery_veteran', 'rdc-cap-1');
  if v_cap is null then raise exception 'CANARY PROVISION FAIL mint captain: null'; end if;
  r := pg_temp.call_as(uZ, format('public.assign_captain_to_ship(%L, %L::uuid, %L::uuid, %L)', 'rdc-assign-1', v_cap, s_fb, 'gunnery'));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL assign captain: %', r; end if;

  -- two single-ship teams, each ship its own command ship (spawns at the location center, dist 0).
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''RDC A'')');
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL group A: %', r; end if;
  gA := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(2, ''RDC B'')');
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL group B: %', r; end if;
  gB := (r->>'group_id')::uuid;
  insert into rdc values ('gA', gA::text), ('gB', gB::text);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_arm, gA));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL assign A: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s_fb, gB));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL assign B: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_arm));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL command A: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s_fb));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY PROVISION FAIL command B: %', r; end if;
  raise notice 'CANARY setup ok: s_arm (autocannon) + s_fb (captain attack, NO weapon) provisioned; rdc_ep bound to the hunt';
end $$;

-- helper: send a group to the hunt + settle the arrival, returning the created encounter id.
create or replace function pg_temp.send_and_settle(p_uid uuid, p_group uuid, p_hunt uuid) returns uuid language plpgsql as $fn$
declare r jsonb; v_fleet uuid; v_mv uuid; v_enc uuid;
begin
  r := pg_temp.call_as(p_uid, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', p_group, p_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'CANARY SEND FAIL: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid; v_mv := (r->>'movement_id')::uuid;
  if v_fleet is null or v_mv is null then raise exception 'CANARY SEND FAIL envelope: %', r; end if;
  update public.fleet_movements set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute' where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'present' then raise exception 'CANARY SETTLE FAIL: %', r; end if;
  select id into v_enc from public.combat_encounters where fleet_id = v_fleet and status='active';
  if v_enc is null then raise exception 'CANARY SEND FAIL: no active encounter after arrival'; end if;
  return v_enc;
end $fn$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- CANARY A — KNOWN-GOOD ARMED FLEET (fixed hp/armor/weapon/enemy; variance 0). The resolver spawns the
-- authored wave; s_arm's real autocannon deals the damage.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
do $$
declare
  uZ uuid := (select v::uuid from rdc where k='uZ'); gA uuid := (select v::uuid from rdc where k='gA');
  v_hunt uuid := (select v::uuid from rdc where k='hunt'); v_ep uuid := (select v::uuid from rdc where k='ep');
  v_rp uuid := (select v::uuid from rdc where k='rp'); s_arm uuid := (select v::uuid from rdc where k='s_arm');
  v_enc uuid; v_plan jsonb; n int; v_settle_cnt int;
  v_e_hpmax double precision; v_e_hpcur double precision; v_player_dmg double precision; v_enemy_dmg double precision;
  v_hp_arm0 double precision; v_hp_arm1 double precision;
  v_tier int; v_grants jsonb; v_metal double precision; v_exp_metal double precision; v_syn_metal double precision;
  v_wave_events int; v_digest_base text; v_digest_post text;
begin
  -- the resolver is CONSULTED for this live bound location and returns a real authored plan (not NULL).
  v_plan := public.resolve_location_encounter(v_hunt, v_hunt::text);
  if v_plan is null then raise exception 'CANARY_A FAIL: resolve_location_encounter returned NULL for the live bound hunt location'; end if;
  if (v_plan->>'encounter_profile_id') <> v_ep::text then raise exception 'CANARY_A FAIL: resolver picked profile % (want rdc_ep %)', v_plan->>'encounter_profile_id', v_ep; end if;
  raise notice 'CANARY_A_RESOLVE ok: resolver returned the authored rdc_ep plan for the hunt location';

  -- ONE settlement: send + settle exactly once → exactly one active encounter for the fleet.
  v_enc := pg_temp.send_and_settle(uZ, gA, v_hunt);
  insert into rdc values ('encA', v_enc::text);
  select count(*) into v_settle_cnt from public.combat_encounters where fleet_id = (select fleet_id from public.combat_encounters where id = v_enc);
  if v_settle_cnt <> 1 then raise exception 'CANARY_A FAIL (5): % settlements for the fleet (want exactly 1)', v_settle_cnt; end if;
  raise notice 'CANARY_A_SETTLE ok: exactly ONE settlement (encounter %)', v_enc;

  -- ██ FENCE every OTHER active/retreating encounter so the global tick processes the canary ALONE ██
  update public.combat_encounters set last_resolved_at = now() where status in ('active','retreating') and id <> v_enc;
  -- baseline isolation digest (post-fence): the tick must not change any non-canary row beyond this.
  v_digest_base := pg_temp.noncanary_digest(uZ);
  insert into rdc values ('digest_base', v_digest_base);

  select hp_current into v_hp_arm0 from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
  if n <> 0 then raise exception 'CANARY_A FAIL precondition: % enemy rows before the first tick (want 0)', n; end if;

  -- rewind ONLY the canary encounter so it (and only it) is tick-eligible, then drive the REAL tick.
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  -- the RESOLVED authored wave spawned (tagged), exactly ONE pirate at the center; the encounter carries
  -- the resolved plan (proves the resolver damage branch, not the synthetic fallback, ran).
  select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
  if n <> 1 then raise exception 'CANARY_A FAIL: % enemy rows after spawn (want exactly 1)', n; end if;
  if (select resolved_plan_json->>'encounter_profile_id' from public.combat_encounters where id = v_enc) is distinct from v_ep::text then
    raise exception 'CANARY_A FAIL: encounter not tagged with the resolved rdc_ep plan (resolved damage branch did not run)'; end if;

  -- (1) player EFFECTIVE damage > 0, and (2) enemy hp DECREASED by the expected amount (one autocannon
  --     shot, power 10 × variance 1 = 10; enemy has no defense).
  select player_damage, enemy_damage into v_player_dmg, v_enemy_dmg from public.combat_ticks
    where encounter_id = v_enc and tick_number = 1;
  if coalesce(v_player_dmg,0) <= 0 then raise exception 'CANARY_A FAIL (1): player effective damage % <= 0', v_player_dmg; end if;
  select hp_max, hp_current into v_e_hpmax, v_e_hpcur from public.combat_units where encounter_id = v_enc and side='enemy';
  if v_e_hpcur >= v_e_hpmax then raise exception 'CANARY_A FAIL (2): enemy hp_current % not below hp_max %', v_e_hpcur, v_e_hpmax; end if;
  if abs((v_e_hpmax - v_e_hpcur) - v_player_dmg) > 0.001 then
    raise exception 'CANARY_A FAIL (2): enemy hp drop % <> logged player damage % (unexpected damage amount)', (v_e_hpmax - v_e_hpcur), v_player_dmg; end if;
  raise notice 'CANARY_A_DAMAGE ok: player dealt % → enemy hp %→% (>0, expected)', v_player_dmg, v_e_hpmax, v_e_hpcur;

  -- (3) enemy damage applied ONLY to the canary fleet: the pirate deals 0 (enemy_attack_base=0) so the
  --     armed ship's hull is untouched, and NO non-canary row changed (assertion 8 digest, below).
  select hp_current into v_hp_arm1 from public.combat_units where encounter_id = v_enc and main_ship_id = s_arm;
  if coalesce(v_enemy_dmg,0) <> 0 or v_hp_arm1 is distinct from v_hp_arm0 then
    raise exception 'CANARY_A FAIL (3): canary hull changed (enemy_dmg %, arm hp %→%) — enemy should deal 0', v_enemy_dmg, v_hp_arm0, v_hp_arm1; end if;

  -- (4) terminal state: force a deterministic wave-clear through the REAL tick (knock the surviving enemy
  --     to 1 hp — the sanctioned surgery — then re-tick). waves_cleared reaches 1.
  update public.combat_units set hp_current = 1 where encounter_id = v_enc and side='enemy';
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();
  if (select waves_cleared from public.combat_encounters where id = v_enc) < 1 then
    raise exception 'CANARY_A FAIL (4): wave did not clear after the surgery (terminal state not reached)'; end if;
  raise notice 'CANARY_A_TERMINAL ok: encounter reached the expected wave-cleared terminal state';

  -- (6) exactly ONE reward event on victory, drawn from the AUTHORED profile (base 20 ⇒ DISTINCT from the
  --     pre-E3 base-10 value — proving the resolved reward adapter branch, not the synthetic fallback).
  select count(*) into v_wave_events from public.combat_events
    where encounter_id = v_enc and event_type='explosion' and (payload_json->>'wave_cleared')::boolean is true;
  if v_wave_events <> 1 then raise exception 'CANARY_A FAIL (6): % wave-cleared reward events (want exactly 1)', v_wave_events; end if;
  select reward_tier into v_tier from public.locations where id = v_hunt;
  select resource_grants into v_grants from public.reward_profiles where id = v_rp;
  v_metal := ((select total_rewards_json from public.combat_encounters where id = v_enc)->>'metal')::double precision;
  v_exp_metal := public.resolve_encounter_reward_inputs(v_grants, v_tier, (select danger_level from public.combat_encounters where id = v_enc));
  if coalesce(v_metal,0) <= 0 then raise exception 'CANARY_A FAIL (6): reward metal % <= 0', v_metal; end if;
  v_syn_metal := round(coalesce(public.cfg_num('reward_metal_base'),10) * greatest(v_tier,1)
                       * (1 + coalesce(public.cfg_num('reward_danger_scale'),0.25) * (select danger_level from public.combat_encounters where id=v_enc)) * coalesce(public.cfg_num('reward_multiplier'),1.0));
  if v_metal is distinct from v_exp_metal then raise exception 'CANARY_A FAIL (6): reward metal % <> authored-profile reward %', v_metal, v_exp_metal; end if;
  if v_exp_metal = v_syn_metal then raise exception 'CANARY_A FAIL (6): authored (base 20) reward is indistinguishable from the synthetic (base 10) — cannot prove the resolved branch'; end if;
  raise notice 'CANARY_A_REWARD ok: exactly ONE reward event; metal % via the AUTHORED profile (synthetic would be %)', v_metal, v_syn_metal;

  -- (7) IDEMPOTENCY: while the canary encounter is active + tagged, cap=1 means the resolver produces NO
  --     second spawn (returns NULL), and re-ticking (inside the wave-transition gate) adds NO damage/reward.
  if public.resolve_location_encounter(v_hunt, v_hunt::text) is not null then
    raise exception 'CANARY_A FAIL (7): resolver produced a SECOND plan at cap=1 (not idempotent)'; end if;
  declare v_wc0 int; v_metal0 double precision; v_wc1 int; v_metal1 double precision;
  begin
    select waves_cleared, (total_rewards_json->>'metal')::double precision into v_wc0, v_metal0 from public.combat_encounters where id = v_enc;
    update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;  -- eligible again
    perform public.process_combat_ticks();  -- inside next_wave_at gate ⇒ paused ⇒ no spawn/damage/reward
    select waves_cleared, (total_rewards_json->>'metal')::double precision into v_wc1, v_metal1 from public.combat_encounters where id = v_enc;
    if v_wc1 is distinct from v_wc0 or v_metal1 is distinct from v_metal0 then
      raise exception 'CANARY_A FAIL (7): a re-tick changed waves_cleared %→% or reward %→% (not idempotent)', v_wc0, v_wc1, v_metal0, v_metal1; end if;
  end;
  raise notice 'CANARY_A_IDEMPOTENT ok: cap=1 blocks a 2nd resolve and a re-tick adds no damage/reward';

  -- (8) ZERO non-canary row changes: the fenced tick changed NOTHING outside the canary fleet.
  v_digest_post := pg_temp.noncanary_digest(uZ);
  if v_digest_post is distinct from v_digest_base then
    raise exception 'CANARY_A FAIL (8): non-canary combat/fleet/ship digest changed (% -> %) — the tick bled beyond the canary fleet', v_digest_base, v_digest_post; end if;
  raise notice 'CANARY_A_ISOLATED ok: ZERO non-canary combat_encounters/combat_units/fleets/main_ship_instances changes';

  -- retire the canary-A encounter so it never re-waves and frees the cap for Canary B.
  update public.combat_encounters set status='defeat', ended_at=now() where id = v_enc;
  raise notice 'CANARY_A: PASS';
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- CANARY B — EMPTY/INVALID WEAPONS (the EXACT prior catastrophe). Prove the 0262 remediation: the
-- empty-loadout player unit still deals > 0 effective damage (the synthesized fallback engaged), and the
-- canary fleet is NOT lost to a zero-damage bug. What must NOT happen: effective_damage = 0 → fleet loss.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
do $$
declare
  uZ uuid := (select v::uuid from rdc where k='uZ'); gB uuid := (select v::uuid from rdc where k='gB');
  v_hunt uuid := (select v::uuid from rdc where k='hunt'); s_fb uuid := (select v::uuid from rdc where k='s_fb');
  v_digest_base text := (select v from rdc where k='digest_base');
  v_enc uuid; n int; v_attack double precision; v_wc int; v_mid text; v_power double precision;
  v_hp_fb0 double precision; v_hp_fb1 double precision; v_e_hpmax double precision; v_e_hpcur double precision;
  v_player_salvo int; v_player_dmg double precision; v_digest_post text;
begin
  -- the exact prior catastrophe: s_fb's RAW fitted-weapon join (what the pre-0262 creator used) is EMPTY.
  select count(*) into n
    from public.ship_module_fittings f
    join public.module_instances i on i.id = f.module_instance_id
    join public.module_types t     on t.id = i.module_type_id
   where f.main_ship_id = s_fb and t.range is not null;
  if n <> 0 then raise exception 'CANARY_B FAIL: s_fb has % fitted range-weapon module(s) (want 0 — the empty-loadout catastrophe)', n; end if;

  v_enc := pg_temp.send_and_settle(uZ, gB, v_hunt);
  insert into rdc values ('encB', v_enc::text);

  -- 0262 REMEDIATION at combat-unit creation: an empty fitted array + positive attack_snapshot yields ONE
  -- synthesized basic_player_weapon (power = attack_snapshot). This is the structural refusal to let a
  -- zero-damage fleet enter combat: the unit fires SOMETHING instead of nothing.
  select attack_snapshot, jsonb_array_length(weapons_json), weapons_json->0->>'module_type_id', (weapons_json->0->>'power')::double precision
    into v_attack, v_wc, v_mid, v_power
    from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  if coalesce(v_attack,0) <= 0 then raise exception 'CANARY_B FAIL: s_fb attack_snapshot % <= 0 (captain did not contribute combat_power)', v_attack; end if;
  if v_wc <> 1 or v_mid <> 'basic_player_weapon' then
    raise exception 'CANARY_B FAIL: s_fb weapons_json is %/% (want exactly 1 synthesized basic_player_weapon — 0262 did NOT engage → the catastrophe is LIVE)', v_wc, v_mid; end if;
  if v_power is distinct from v_attack then raise exception 'CANARY_B FAIL: fallback power % <> attack_snapshot %', v_power, v_attack; end if;
  raise notice 'CANARY_B_FALLBACK ok: empty-loadout s_fb synthesized ONE basic_player_weapon (power=% = attack_snapshot) — 0262 engaged', v_power;

  -- FENCE others + rewind ONLY the canary-B encounter, then drive the REAL tick.
  update public.combat_encounters set last_resolved_at = now() where status in ('active','retreating') and id <> v_enc;
  select hp_current into v_hp_fb0 from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  -- THE PROOF: the empty-loadout unit dealt > 0 effective damage (a player missile_salvo fired; enemy hp
  --   fell). Pre-0262 this ship fired NOTHING → 0 damage → guaranteed loss.
  select count(*) into v_player_salvo from public.combat_events
    where encounter_id = v_enc and tick_number = 1 and event_type='missile_salvo' and source='player';
  if v_player_salvo < 1 then raise exception 'CANARY_B FAIL: no player missile_salvo on tick 1 — the empty-loadout unit fired NOTHING (the catastrophe)'; end if;
  select player_damage into v_player_dmg from public.combat_ticks where encounter_id = v_enc and tick_number = 1;
  if coalesce(v_player_dmg,0) <= 0 then raise exception 'CANARY_B FAIL: empty-loadout effective damage % <= 0 (the exact prior catastrophe — 0262 remediation did NOT hold)', v_player_dmg; end if;
  select hp_max, hp_current into v_e_hpmax, v_e_hpcur from public.combat_units where encounter_id = v_enc and side='enemy';
  if v_e_hpcur >= v_e_hpmax then raise exception 'CANARY_B FAIL: enemy hp % not below hp_max % (fallback dealt zero)', v_e_hpcur, v_e_hpmax; end if;

  -- and the canary fleet is NOT destroyed by a zero-damage bug (enemy deals 0; s_fb hull intact + alive).
  select hp_current into v_hp_fb1 from public.combat_units where encounter_id = v_enc and main_ship_id = s_fb;
  if v_hp_fb1 is distinct from v_hp_fb0 or v_hp_fb1 <= 0 then
    raise exception 'CANARY_B FAIL: canary fleet hull changed/lost (%→%) — must survive (enemy deals 0; the ship deals >0)', v_hp_fb0, v_hp_fb1; end if;
  raise notice 'CANARY_B_DAMAGE ok: empty-loadout s_fb dealt % (enemy hp %→%); fleet intact & NOT lost to a zero-damage bug', v_player_dmg, v_e_hpmax, v_e_hpcur;

  -- assertion 8 again: the whole canary (A + B) touched ZERO non-canary combat/fleet/ship rows.
  v_digest_post := pg_temp.noncanary_digest(uZ);
  if v_digest_post is distinct from v_digest_base then
    raise exception 'CANARY_B FAIL (8): non-canary digest drifted (% -> %) across the full canary run', v_digest_base, v_digest_post; end if;
  raise notice 'CANARY_B_ISOLATED ok: ZERO non-canary changes across the full A+B run';
  raise notice 'CANARY_B: PASS';
end $$;

do $$ begin raise notice 'CANARY_RESULT: PASS'; end $$;

rollback;   -- UNCONDITIONAL. The flag flip, every fixture, every tick — ALL rolled back. Nothing commits.
