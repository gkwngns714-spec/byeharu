-- ENCOUNTER RESOLVER — disposable apply-proof for E3 (migration 0260). Run against a THROWAWAY local
-- Supabase (`supabase start` applies the full chain incl. 0260 + its self-assert). NEVER point at prod.
--
-- Proves the RISK-INFLECTION slice: process_combat_ticks now composes a quad-flag-gated encounter
-- resolver, and — the HARD REQUIREMENT — with encounter_resolver_enabled=false combat is BYTE-IDENTICAL
-- to pre-E3. Real-RPC provisioning end to end (reveal_starter_ports / commission_first_main_ship /
-- commission_additional_main_ship / reward_grant / craft_module / fit_module_to_ship / upsert_ship_group /
-- assign_ship_to_group / set_fleet_command_ship / send_ship_group_hunt / movement_settle_arrival) — the
-- combat chain writes combat_units, never this script. E0-E2 content is authored through the REAL owner
-- RPCs (reward_profile_create / enemy_archetype_create / enemy_fleet_template_create /
-- encounter_profile_create / location_encounter_binding_create). combat_damage_variance_pct is pinned 0
-- (v_variance=1) for determinism; no session RNG (the 0041 law).
--
-- SCENARIO GEOMETRY: a SINGLE armed command ship spawns at the hunt location center; the synthetic /
-- resolved pirate ALSO spawns at that center (dist 0) — so both HOLD (never move), keeping the enemy AT
-- the location center after the spawn tick (the exact position the pre-E3 spawn writes). enemy_attack_base
-- is zeroed so the player never dies; to force a deterministic wave-clear (for the reward assertions) the
-- surviving enemy's hp_current is set to 1 and the tick re-run — the CLEAR still runs through the real
-- process_combat_ticks path (the clock-rewind idiom's sibling, a sanctioned surgery, not a fabricated
-- combat write).
--
-- Self-rolling-back (begin;...rollback;): flips every gate flag ONLY inside the txn, keeps ZERO state.
--
-- E5 (0261): every existing DIRECT resolve_location_encounter(...) call now passes a FIXED per-location
-- seed (loc::text) so all existing markers still hold; the resolved combat path feeds e.id::text internally.
--
-- PASS markers: ER_PASS_VERBATIM, ER_PASS_FLAGOFF_ROWS, ER_PASS_FLAGOFF_REWARD, ER_PASS_RESOLVED_PLAN,
-- ER_PASS_MULTIWAVE, ER_PASS_NULL_FLAGS, ER_PASS_NULL_BINDING, ER_PASS_NULL_INACTIVE_LOC, ER_PASS_CAP,
-- ER_PASS_COOLDOWN, ER_PASS_DETERMINISM, ER_PASS_REWARD_SHARED, ER_PASS_UNIT_CLAMP, ER_PASS_SKIP_ZERO,
-- ER_PASS_REWARD_UNTOUCHED, ER_PASS_E5_VARIETY, ER_PASS_E5_SEED_STABLE, ER_PASS_E5_NO_ELITE,
-- ER_PASS_E5_ELITE_GUARD, "ENCOUNTER-RESOLVER PROOF PASSED".

\set ON_ERROR_STOP on

begin;

create temp table erfx(k text primary key, v uuid) on commit drop;

create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- ════════ STATIC PROOF 1 — ER_PASS_VERBATIM + ER_PASS_REWARD_UNTOUCHED (prosrc, no fixtures needed) ══
do $$
declare v_tick text; v_ccge text; v_reward text; v_base text; v_res text;
begin
  select pg_get_functiondef(oid) into v_tick   from pg_proc where proname='process_combat_ticks'          and pronamespace='public'::regnamespace;
  select pg_get_functiondef(oid) into v_ccge   from pg_proc where proname='combat_create_group_encounter' and pronamespace='public'::regnamespace;
  select pg_get_functiondef(oid) into v_reward from pg_proc where proname='reward_grant'                  and pronamespace='public'::regnamespace;
  select pg_get_functiondef(oid) into v_base   from pg_proc where proname='base_add_resources'            and pronamespace='public'::regnamespace;
  select pg_get_functiondef(oid) into v_res    from pg_proc where proname='resolve_location_encounter'    and pronamespace='public'::regnamespace;

  -- the VERBATIM pre-E3 synthetic-wave lines survive as the flag-OFF fallback.
  if strpos(v_tick, 'v_enemy_count  := least(coalesce(cfg_num(''enemy_synthetic_max_units''),6)::integer, greatest(1, v_danger));') = 0
     or strpos(v_tick, '''module_type_id'', ''pirate_synthetic_weapon'', ''range'', v_enemy_range,') = 0 then
    raise exception 'ER PROOF FAIL: the verbatim synthetic-wave lines are gone from process_combat_ticks';
  end if;
  -- the VERBATIM :898-899 reward formula survives as the flag-OFF reward fallback.
  if strpos(v_tick, 'v_reward_metal := round(coalesce(cfg_num(''reward_metal_base''),10) * greatest(loc.reward_tier,1)') = 0
     or strpos(v_tick, '* (1 + coalesce(cfg_num(''reward_danger_scale''),0.25) * v_danger) * coalesce(cfg_num(''reward_multiplier''),1.0));') = 0 then
    raise exception 'ER PROOF FAIL: the verbatim :898-899 reward formula is gone from process_combat_ticks';
  end if;
  -- the 0234 AGGREGATE (C) arm is unchanged (distinctive aggregate-only tokens).
  if strpos(v_tick, 'coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0)') = 0
     or strpos(v_tick, 'v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;') = 0
     or strpos(v_tick, 'v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);') = 0 then
    raise exception 'ER PROOF FAIL: the 0234 aggregate (C) arm was altered (out-of-scope change)';
  end if;
  -- combat_create_group_encounter carries NO E3 token (not redefined / not injected by E3).
  if v_ccge ilike '%resolve_location_encounter%' or v_ccge ilike '%resolved_plan_json%' then
    raise exception 'ER PROOF FAIL: combat_create_group_encounter carries an E3 token';
  end if;
  raise notice 'ER_PASS_VERBATIM';

  -- REWARD_UNTOUCHED: reward_grant + base_add_resources carry NO E3 token (this slice never redefines
  -- them; 0260 contains no create-or-replace of either — asserted structurally against the live bodies).
  if v_reward ilike '%resolve_location_encounter%' or v_reward ilike '%resolved_plan_json%' or v_reward ilike '%encounter_runtime_state%'
     or v_base ilike '%resolve_location_encounter%' or v_base ilike '%encounter_runtime_state%' then
    raise exception 'ER PROOF FAIL: reward_grant/base_add_resources carry an E3 token (blast radius breach)';
  end if;
  -- resolve_location_encounter is deterministic by construction (no RNG; hashtextextended + '':enc:'').
  if v_res ilike '%random(%' or v_res ilike '%setseed%' then
    raise exception 'ER PROOF FAIL: resolve_location_encounter carries a session-RNG token';
  end if;
  if v_res not ilike '%hashtextextended%' or v_res not ilike '%:enc:%' then
    raise exception 'ER PROOF FAIL: resolve_location_encounter lost the hashtextextended/'':enc:'' technique';
  end if;
  raise notice 'ER_PASS_REWARD_UNTOUCHED';
end $$;

-- ════════ SETUP: owner + funded player + reveal ports ════════════════════════════════════════════════
do $$
declare uZ uuid; uOwner uuid;
begin
  if (public.reveal_starter_ports()->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports'; end if;
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'erp.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into uZ;
  insert into erfx values ('uZ', uZ);
  insert into public.player_wallet (player_id, balance) values (uZ, 1000000)
    on conflict (player_id) do update set balance = excluded.balance;
  -- the owner (authoring caller) is the SAME player (simplest; is_owner via app_owners).
  insert into public.app_owners(user_id) values (uZ);
end $$;

-- dark gates flipped ONLY inside this rolled-back txn.
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='module_crafting_enabled';
update public.game_config set value='true'::jsonb where key='module_fitting_enabled';
update public.game_config set value='true'::jsonb where key='spatial_combat_enabled';
-- E0/E1/E2 on for authoring; E3 on for the direct resolver unit tests (toggled to false for FLAGOFF).
update public.game_config set value='true'::jsonb where key='enemy_content_registry_enabled';
update public.game_config set value='true'::jsonb where key='encounter_authoring_enabled';
update public.game_config set value='true'::jsonb where key='encounter_binding_authoring_enabled';
update public.game_config set value='true'::jsonb where key='encounter_resolver_enabled';

do $$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);   -- v_variance = 1
  perform public.set_game_config('combat_tick_logging',  'true'::jsonb);
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);
  perform public.set_game_config('enemy_hp_base',        '500'::jsonb);       -- enemy survives the spawn tick comfortably
  perform public.set_game_config('enemy_attack_base',    '0'::jsonb);         -- enemy does 0 damage (player never dies)
  perform public.set_game_config('enemy_synthetic_range_base', '10000'::jsonb); -- in range at dist 0 (fires, 0 damage)
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
end $$;

-- ════════ AUTHOR E0-E2 content through the REAL owner RPCs ═══════════════════════════════════════════
do $$
declare uZ uuid := (select v from erfx where k='uZ'); r jsonb;
  v_rp uuid; v_arch uuid; v_fleet uuid; v_ep uuid; v_ep_cd uuid;
begin
  -- reward profile with base=20 (DISTINCT from the config default 10, so the resolved reward VALUE proves
  -- the adapter branch was taken).
  r := pg_temp.call_as(uZ, 'public.reward_profile_create(''erp-rp-1'', ''{"key":"erp_reward","display_name":"ERP Reward","resource_grants":{"metal":{"base":20,"danger_coeff":0.25,"multiplier_ref":"reward_multiplier"}}}''::jsonb)');
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL reward_profile: %', r; end if;
  v_rp := (r->'result'->>'id')::uuid;

  r := pg_temp.call_as(uZ, format('public.enemy_archetype_create(%L, %L::jsonb)', 'erp-arch-1',
         jsonb_build_object('key','erp_arch','display_name','ERP Arch','unit_type_id','pirate_synthetic',
           'base_difficulty',5,'difficulty_rating',1,'default_reward_profile_id',v_rp::text)::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL archetype: %', r; end if;
  v_arch := (r->'result'->>'id')::uuid;

  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'erp-fleet-1',
         jsonb_build_object('key','erp_fleet','display_name','ERP Fleet',
           'members', jsonb_build_array(jsonb_build_object('enemy_archetype_id',v_arch::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL fleet: %', r; end if;
  v_fleet := (r->'result'->>'id')::uuid;

  -- er_ep: cap=1, cooldown=0 (the CAP witness; cooldown 0 keeps CAP isolated).
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'erp-ep-1',
         jsonb_build_object('key','erp_ep','display_name','ERP EP','active_encounter_cap',1,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_fleet::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep: %', r; end if;
  v_ep := (r->'result'->>'id')::uuid;

  -- er_ep_cd: cap=5, cooldown=60 (the COOLDOWN witness).
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'erp-epcd-1',
         jsonb_build_object('key','erp_ep_cd','display_name','ERP EP CD','active_encounter_cap',5,'cooldown_seconds',60,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_fleet::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_cd: %', r; end if;
  v_ep_cd := (r->'result'->>'id')::uuid;

  insert into erfx values ('rp', v_rp), ('arch', v_arch), ('fleet', v_fleet), ('ep', v_ep), ('ep_cd', v_ep_cd);
end $$;

-- ════════ AUTHOR multi-archetype Fix-test content (reward sharing / clamp / skip-zero) ═══════════════
do $$
declare uZ uuid := (select v from erfx where k='uZ'); r jsonb;
  v_rp uuid := (select v from erfx where k='rp'); v_arch uuid := (select v from erfx where k='arch');
  v_rp2 uuid; v_arch2 uuid; v_arch3 uuid; v_archbig uuid;
  v_f_same uuid; v_f_diff uuid; v_f_big uuid; v_f_zero uuid;
  v_ep_same uuid; v_ep_diff uuid; v_ep_ovr uuid; v_ep_big uuid; v_ep_zero uuid;
begin
  -- a SECOND reward profile (base 30) — the DIVERGENT default for the reward-sharing test.
  r := pg_temp.call_as(uZ, 'public.reward_profile_create(''erp-rp-2'', ''{"key":"erp_reward2","display_name":"ERP Reward 2","resource_grants":{"metal":{"base":30,"danger_coeff":0.25,"multiplier_ref":"reward_multiplier"}}}''::jsonb)');
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL rp2: %', r; end if;
  v_rp2 := (r->'result'->>'id')::uuid;

  -- er_arch2 shares er_reward (SAME default); er_arch3 defaults er_reward2 (DIVERGENT); er_arch_big shares er_reward.
  r := pg_temp.call_as(uZ, format('public.enemy_archetype_create(%L, %L::jsonb)', 'erp-arch-2',
         jsonb_build_object('key','erp_arch2','display_name','ERP Arch2','unit_type_id','pirate_synthetic','base_difficulty',5,'difficulty_rating',1,'default_reward_profile_id',v_rp::text)::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL arch2: %', r; end if;
  v_arch2 := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.enemy_archetype_create(%L, %L::jsonb)', 'erp-arch-3',
         jsonb_build_object('key','erp_arch3','display_name','ERP Arch3','unit_type_id','pirate_synthetic','base_difficulty',5,'difficulty_rating',1,'default_reward_profile_id',v_rp2::text)::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL arch3: %', r; end if;
  v_arch3 := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.enemy_archetype_create(%L, %L::jsonb)', 'erp-arch-big',
         jsonb_build_object('key','erp_arch_big','display_name','ERP ArchBig','unit_type_id','pirate_synthetic','base_difficulty',5,'difficulty_rating',1,'default_reward_profile_id',v_rp::text)::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL archbig: %', r; end if;
  v_archbig := (r->'result'->>'id')::uuid;

  -- fleets: SAME-reward pair, DIVERGENT-reward pair, an OVER-ceiling single (10 > 6), a ZERO+ONE pair.
  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'erp-fleet-same',
         jsonb_build_object('key','erp_fleet_same','display_name','ERP Fleet Same','members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id',v_arch::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0),
           jsonb_build_object('enemy_archetype_id',v_arch2::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL fleet_same: %', r; end if;
  v_f_same := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'erp-fleet-diff',
         jsonb_build_object('key','erp_fleet_diff','display_name','ERP Fleet Diff','members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id',v_arch::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0),
           jsonb_build_object('enemy_archetype_id',v_arch3::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL fleet_diff: %', r; end if;
  v_f_diff := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'erp-fleet-big',
         jsonb_build_object('key','erp_fleet_big','display_name','ERP Fleet Big','members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id',v_archbig::text,'min_count',10,'max_count',10,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL fleet_big: %', r; end if;
  v_f_big := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'erp-fleet-zero',
         jsonb_build_object('key','erp_fleet_zero','display_name','ERP Fleet Zero','members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id',v_arch3::text,'min_count',0,'max_count',0,'weight',1,'elite_chance',0),
           jsonb_build_object('enemy_archetype_id',v_arch::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL fleet_zero: %', r; end if;
  v_f_zero := (r->'result'->>'id')::uuid;

  -- encounter profiles (cap 5, cooldown 0). erp_ep_ovr sets reward_override_id = er_reward (override wins).
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'erp-ep-same',
         jsonb_build_object('key','erp_ep_same','display_name','ERP EP Same','active_encounter_cap',5,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_f_same::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_same: %', r; end if;
  v_ep_same := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'erp-ep-diff',
         jsonb_build_object('key','erp_ep_diff','display_name','ERP EP Diff','active_encounter_cap',5,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_f_diff::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_diff: %', r; end if;
  v_ep_diff := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'erp-ep-ovr',
         jsonb_build_object('key','erp_ep_ovr','display_name','ERP EP Ovr','active_encounter_cap',5,'cooldown_seconds',0,'reward_override_id',v_rp::text,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_f_diff::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_ovr: %', r; end if;
  v_ep_ovr := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'erp-ep-big',
         jsonb_build_object('key','erp_ep_big','display_name','ERP EP Big','active_encounter_cap',5,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_f_big::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_big: %', r; end if;
  v_ep_big := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'erp-ep-zero',
         jsonb_build_object('key','erp_ep_zero','display_name','ERP EP Zero','active_encounter_cap',5,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_f_zero::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_zero: %', r; end if;
  v_ep_zero := (r->'result'->>'id')::uuid;

  insert into erfx values ('rp2', v_rp2), ('arch2', v_arch2), ('arch3', v_arch3), ('archbig', v_archbig),
    ('ep_same', v_ep_same), ('ep_diff', v_ep_diff), ('ep_ovr', v_ep_ovr), ('ep_big', v_ep_big), ('ep_zero', v_ep_zero);
end $$;

-- ════════ Fix-test fixture locations + bindings ══════════════════════════════════════════════════════
do $$
declare uZ uuid := (select v from erfx where k='uZ'); r jsonb; v_zone uuid;
  v_ls uuid; v_ld uuid; v_lo uuid; v_lb uuid; v_lz uuid;
begin
  select id into v_zone from public.zones limit 1;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Same', 'pirate_hunt', 960, 960, 7, 'active') returning id into v_ls;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Diff', 'pirate_hunt', 961, 961, 7, 'active') returning id into v_ld;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Ovr', 'pirate_hunt', 962, 962, 7, 'active') returning id into v_lo;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Big', 'pirate_hunt', 963, 963, 7, 'active') returning id into v_lb;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Zero', 'pirate_hunt', 964, 964, 7, 'active') returning id into v_lz;
  insert into erfx values ('loc_same', v_ls), ('loc_diff', v_ld), ('loc_ovr', v_lo), ('loc_big', v_lb), ('loc_zero', v_lz);

  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-same',
         jsonb_build_object('location_id', v_ls::text, 'encounter_profile_id', (select v from erfx where k='ep_same')::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL same: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-diff',
         jsonb_build_object('location_id', v_ld::text, 'encounter_profile_id', (select v from erfx where k='ep_diff')::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL diff: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-ovr',
         jsonb_build_object('location_id', v_lo::text, 'encounter_profile_id', (select v from erfx where k='ep_ovr')::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL ovr: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-big',
         jsonb_build_object('location_id', v_lb::text, 'encounter_profile_id', (select v from erfx where k='ep_big')::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL big: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-zero',
         jsonb_build_object('location_id', v_lz::text, 'encounter_profile_id', (select v from erfx where k='ep_zero')::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL zero: %', r; end if;
end $$;

-- ════════ FIX 1/3/4 direct resolver tests: reward sharing, unit clamp, skip-zero ════════════════════
do $$
declare p jsonb;
begin
  -- FIX 1 (a): both spawning archetypes share ONE default reward ⇒ resolved (reward = the shared profile).
  p := public.resolve_location_encounter((select v from erfx where k='loc_same'), (select v from erfx where k='loc_same')::text);
  if p is null then raise exception 'ER PROOF FAIL SHARED: same-default fleet did not resolve'; end if;
  if jsonb_array_length(p->'units') <> 2 or (p->'reward_profile'->>'id') <> (select v from erfx where k='rp')::text then
    raise exception 'ER PROOF FAIL SHARED: expected 2 units + the shared reward, got %', p;
  end if;
  -- FIX 1 (b): DIVERGENT defaults, NO override ⇒ NOT runtime-eligible ⇒ NULL (falls back to legacy).
  if public.resolve_location_encounter((select v from erfx where k='loc_diff'), (select v from erfx where k='loc_diff')::text) is not null then
    raise exception 'ER PROOF FAIL SHARED: divergent-default fleet with no override did NOT return NULL';
  end if;
  -- FIX 1 (c): divergent defaults WITH an encounter reward_override ⇒ resolves via the override.
  p := public.resolve_location_encounter((select v from erfx where k='loc_ovr'), (select v from erfx where k='loc_ovr')::text);
  if p is null or (p->'reward_profile'->>'id') <> (select v from erfx where k='rp')::text then
    raise exception 'ER PROOF FAIL SHARED: the override did not decide the reward: %', p;
  end if;
  raise notice 'ER_PASS_REWARD_SHARED';
end $$;

do $$
declare p jsonb; v_ceiling int := coalesce(public.cfg_num('enemy_synthetic_max_units'),6)::int; v_sum int;
begin
  -- FIX 3: a fleet rolling 10 units is clamped to the synthetic ceiling (6).
  p := public.resolve_location_encounter((select v from erfx where k='loc_big'), (select v from erfx where k='loc_big')::text);
  if p is null then raise exception 'ER PROOF FAIL CLAMP: over-ceiling fleet did not resolve'; end if;
  select coalesce(sum((u->>'count')::int),0) into v_sum from jsonb_array_elements(p->'units') u;
  if v_sum <> v_ceiling then
    raise exception 'ER PROOF FAIL CLAMP: total units % not clamped to the ceiling % (rolled 10)', v_sum, v_ceiling;
  end if;
  raise notice 'ER_PASS_UNIT_CLAMP';
end $$;

do $$
declare p jsonb;
begin
  -- FIX 4: a member rolling count 0 is SKIPPED (not forced to 1); only the count-1 archetype spawns, and
  -- the skipped archetype's DIVERGENT default reward does NOT poison the reward sharing.
  p := public.resolve_location_encounter((select v from erfx where k='loc_zero'), (select v from erfx where k='loc_zero')::text);
  if p is null then raise exception 'ER PROOF FAIL SKIPZERO: zero+one fleet did not resolve'; end if;
  if jsonb_array_length(p->'units') <> 1 or (p->'units'->0->>'enemy_archetype_id') <> (select v from erfx where k='arch')::text
     or (p->'units'->0->>'count') <> '1' then
    raise exception 'ER PROOF FAIL SKIPZERO: expected exactly the 1 non-zero archetype, got %', p;
  end if;
  if (p->'reward_profile'->>'id') <> (select v from erfx where k='rp')::text then
    raise exception 'ER PROOF FAIL SKIPZERO: reward not the surviving archetype default (skipped archetype leaked): %', p;
  end if;
  raise notice 'ER_PASS_SKIP_ZERO';
end $$;

-- ════════ fixture locations + bindings (for the DIRECT resolver unit tests) ══════════════════════════
do $$
declare uZ uuid := (select v from erfx where k='uZ'); r jsonb;
  v_zone uuid; v_loc uuid; v_locked uuid; v_nobind uuid; v_cd uuid;
  v_ep uuid := (select v from erfx where k='ep'); v_ep_cd uuid := (select v from erfx where k='ep_cd');
begin
  select id into v_zone from public.zones limit 1;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Active', 'pirate_hunt', 950, 950, 7, 'active') returning id into v_loc;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Locked', 'pirate_hunt', 951, 951, 7, 'locked') returning id into v_locked;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Nobind', 'pirate_hunt', 952, 952, 7, 'active') returning id into v_nobind;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc CD', 'pirate_hunt', 953, 953, 7, 'active') returning id into v_cd;
  insert into erfx values ('loc', v_loc), ('locked', v_locked), ('nobind', v_nobind), ('loc_cd', v_cd);

  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-loc',
         jsonb_build_object('location_id', v_loc::text, 'encounter_profile_id', v_ep::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL loc: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-locked',
         jsonb_build_object('location_id', v_locked::text, 'encounter_profile_id', v_ep::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL locked: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-cd',
         jsonb_build_object('location_id', v_cd::text, 'encounter_profile_id', v_ep_cd::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL cd: %', r; end if;
end $$;

-- ════════ DIRECT unit tests: DETERMINISM, NULL_FLAGS, NULL_BINDING, NULL_INACTIVE_LOC, COOLDOWN ═══════
do $$
declare v_loc uuid := (select v from erfx where k='loc'); p1 jsonb; p2 jsonb;
begin
  p1 := public.resolve_location_encounter(v_loc, v_loc::text);
  p2 := public.resolve_location_encounter(v_loc, v_loc::text);
  if p1 is null then raise exception 'ER PROOF FAIL: resolve returned NULL with all flags on + a live bound location'; end if;
  if p1 is distinct from p2 then raise exception 'ER PROOF FAIL: two same-txn resolves differ (non-deterministic): % vs %', p1, p2; end if;
  if (p1->>'encounter_profile_id') <> (select v from erfx where k='ep')::text
     or jsonb_array_length(p1->'units') <> 1
     or (p1->'units'->0->>'unit_type_id') <> 'pirate_synthetic'
     or (p1->'units'->0->>'count') <> '1'
     or (p1->'reward_profile'->>'id') <> (select v from erfx where k='rp')::text then
    raise exception 'ER PROOF FAIL: resolved plan shape wrong: %', p1;
  end if;
  raise notice 'ER_PASS_DETERMINISM';
end $$;

do $$
declare v_loc uuid := (select v from erfx where k='loc'); k text;
begin
  foreach k in array array['enemy_content_registry_enabled','encounter_authoring_enabled','encounter_binding_authoring_enabled','encounter_resolver_enabled'] loop
    update public.game_config set value='false'::jsonb where key=k;
    if public.resolve_location_encounter(v_loc, v_loc::text) is not null then
      raise exception 'ER PROOF FAIL: resolve did not return NULL with % off', k;
    end if;
    update public.game_config set value='true'::jsonb where key=k;
  end loop;
  -- restored: resolve is non-null again.
  if public.resolve_location_encounter(v_loc, v_loc::text) is null then raise exception 'ER PROOF FAIL: resolve stayed NULL after restoring all flags'; end if;
  raise notice 'ER_PASS_NULL_FLAGS';
end $$;

do $$
declare v_nobind uuid := (select v from erfx where k='nobind');
begin
  if public.resolve_location_encounter(v_nobind, v_nobind::text) is not null then
    raise exception 'ER PROOF FAIL: an active location with NO active binding did not resolve to NULL';
  end if;
  raise notice 'ER_PASS_NULL_BINDING';
end $$;

do $$
declare v_locked uuid := (select v from erfx where k='locked');
begin
  if (select status from public.locations where id = v_locked) = 'active' then raise exception 'ER PROOF FAIL: locked fixture is active'; end if;
  if public.resolve_location_encounter(v_locked, v_locked::text) is not null then
    raise exception 'ER PROOF FAIL: a non-active (locked) bound location did not resolve to NULL';
  end if;
  raise notice 'ER_PASS_NULL_INACTIVE_LOC';
end $$;

do $$
declare v_cd uuid := (select v from erfx where k='loc_cd'); v_ep_cd uuid := (select v from erfx where k='ep_cd');
begin
  -- fresh: no runtime-state row ⇒ resolves.
  if public.resolve_location_encounter(v_cd, v_cd::text) is null then raise exception 'ER PROOF FAIL: cooldown fixture did not resolve when fresh'; end if;
  -- a recent spawn ⇒ cooldown BLOCKS.
  insert into public.encounter_runtime_state (location_id, encounter_profile_id, last_spawn_at, active_count)
    values (v_cd, v_ep_cd, now(), 1);
  if public.resolve_location_encounter(v_cd, v_cd::text) is not null then
    raise exception 'ER PROOF FAIL: resolve did not return NULL within the cooldown window';
  end if;
  -- back-date past the 60s window ⇒ the block CLEARS.
  update public.encounter_runtime_state set last_spawn_at = now() - interval '1 hour' where location_id = v_cd and encounter_profile_id = v_ep_cd;
  if public.resolve_location_encounter(v_cd, v_cd::text) is null then
    raise exception 'ER PROOF FAIL: resolve stayed NULL after the cooldown window elapsed';
  end if;
  delete from public.encounter_runtime_state where location_id = v_cd;   -- clean the fixture
  raise notice 'ER_PASS_COOLDOWN';
end $$;

-- ════════ provision TWO armed command ships (ship1 = flag-off, ship2 = resolved) ════════════════════
do $$
declare uZ uuid := (select v from erfx where k='uZ'); r jsonb; s1 uuid; s2 uuid; m1 uuid; m2 uuid; g1 uuid; g2 uuid;
begin
  r := pg_temp.call_as(uZ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL ship1: %', r; end if;
  select main_ship_id into s1 from public.main_ship_instances where player_id = uZ;
  r := pg_temp.call_as(uZ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'PROVISION FAIL ship2: %', r; end if;
  s2 := (r->>'main_ship_id')::uuid;
  insert into erfx values ('s1', s1), ('s2', s2);

  -- retire each commission dock fleet (the team-command-proof.sql normalization, mirrored).
  update public.main_ship_instances set status='home', updated_at=now() where main_ship_id in (s1, s2);
  update public.fleets set status='destroyed', location_mode='destroyed', active_movement_id=null,
         current_base_id=null, current_location_id=null, current_zone_id=null, current_sector_id=null, updated_at=now()
   where main_ship_id in (s1, s2) and status='present';
  update public.location_presence set status='completed', updated_at=now()
   where fleet_id in (select id from public.fleets where main_ship_id in (s1, s2) and status='destroyed') and status='active';

  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);

  r := pg_temp.call_as(uZ, 'public.craft_module(''erp-gun-1'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft1: %', r; end if;
  m1 := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''erp-fit-1'')', m1, s1));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit1: %', r; end if;
  r := pg_temp.call_as(uZ, 'public.craft_module(''erp-gun-2'', ''autocannon_battery'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft2: %', r; end if;
  m2 := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''erp-fit-2'')', m2, s2));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit2: %', r; end if;

  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(1, ''ERP One'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL g1: %', r; end if;
  g1 := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uZ, 'public.upsert_ship_group(2, ''ERP Two'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL g2: %', r; end if;
  g2 := (r->>'group_id')::uuid;
  insert into erfx values ('g1', g1), ('g2', g2);
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s1, g1));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign1: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', s2, g2));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign2: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s1));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL cmd1: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.set_fleet_command_ship(%L::uuid, true)', s2));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL cmd2: %', r; end if;
end $$;

-- select the real active hunt location + bind it to er_ep (for the resolved run).
do $$
declare uZ uuid := (select v from erfx where k='uZ'); r jsonb; v_hunt uuid; v_ep uuid := (select v from erfx where k='ep');
begin
  select id into v_hunt from public.locations where activity_type='hunt_pirates' and status='active'
    order by min_power_required asc, base_difficulty asc limit 1;
  if v_hunt is null then raise exception 'SETUP FAIL: no active hunt_pirates location'; end if;
  insert into erfx values ('hunt', v_hunt);
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-hunt',
         jsonb_build_object('location_id', v_hunt::text, 'encounter_profile_id', v_ep::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL hunt: %', r; end if;
end $$;

-- helper: send a group to the hunt location and settle the arrival, returning the encounter id.
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

-- ════════ FLAG-OFF SCENARIO (encounter_resolver_enabled=false ⇒ VERBATIM synthetic wave + reward) ════
update public.game_config set value='false'::jsonb where key='encounter_resolver_enabled';
do $$
declare uZ uuid := (select v from erfx where k='uZ'); g1 uuid := (select v from erfx where k='g1');
  v_hunt uuid := (select v from erfx where k='hunt'); v_enc uuid;
  v_lx double precision; v_ly double precision; n int;
  v_hpmax double precision; v_exp_hp double precision; v_px double precision; v_py double precision;
  v_metal double precision; v_exp_metal double precision; v_tier int;
begin
  select x, y, reward_tier into v_lx, v_ly, v_tier from public.locations where id = v_hunt;
  v_enc := pg_temp.send_and_settle(uZ, g1, v_hunt);
  insert into erfx values ('enc1', v_enc);

  -- tick 1: the synthetic wave spawns (resolver OFF ⇒ the pre-E3 arm).
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  -- exactly ONE synthetic enemy, side=enemy, pirate_synthetic, at the location center, resolved_plan_json NULL.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
  if n <> 1 then raise exception 'ER PROOF FAIL FLAGOFF: % enemy rows (want 1)', n; end if;
  select hp_max, pos_x, pos_y into v_hpmax, v_px, v_py from public.combat_units
    where encounter_id = v_enc and side='enemy' and unit_type_id='pirate_synthetic';
  v_exp_hp := (select base_difficulty from public.locations where id = v_hunt)
              * coalesce(public.cfg_num('enemy_hp_base'),14)
              * (1 + 1 * coalesce(public.cfg_num('enemy_hp_danger_scale'),0.6)) * 1;
  if abs(v_hpmax - v_exp_hp) > 0.001 then raise exception 'ER PROOF FAIL FLAGOFF: enemy hp_max % <> pre-E3 formula %', v_hpmax, v_exp_hp; end if;
  if v_px is distinct from v_lx or v_py is distinct from v_ly then raise exception 'ER PROOF FAIL FLAGOFF: enemy not at location center (% % vs % %)', v_px, v_py, v_lx, v_ly; end if;
  if (select resolved_plan_json from public.combat_encounters where id = v_enc) is not null then
    raise exception 'ER PROOF FAIL FLAGOFF: resolved_plan_json is not NULL on a synthetic encounter';
  end if;
  if exists (select 1 from public.encounter_runtime_state) then
    raise exception 'ER PROOF FAIL FLAGOFF: encounter_runtime_state is non-empty after a synthetic wave';
  end if;
  raise notice 'ER_PASS_FLAGOFF_ROWS';

  -- force a deterministic clear: knock the surviving enemy to 1 hp, then re-tick (real clear path).
  update public.combat_units set hp_current = 1 where encounter_id = v_enc and side='enemy';
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();
  if (select waves_cleared from public.combat_encounters where id = v_enc) < 1 then
    raise exception 'ER PROOF FAIL FLAGOFF: wave did not clear after forcing enemy to 1 hp';
  end if;
  v_metal := ((select total_rewards_json from public.combat_encounters where id = v_enc)->>'metal')::double precision;
  v_exp_metal := round(coalesce(public.cfg_num('reward_metal_base'),10) * greatest(v_tier,1)
                       * (1 + coalesce(public.cfg_num('reward_danger_scale'),0.25) * 1) * coalesce(public.cfg_num('reward_multiplier'),1.0));
  if v_metal is distinct from v_exp_metal then
    raise exception 'ER PROOF FAIL FLAGOFF: total metal % <> pre-E3 reward %', v_metal, v_exp_metal;
  end if;
  raise notice 'ER_PASS_FLAGOFF_REWARD';

  -- retire this encounter so it never re-waves during the resolved run.
  update public.combat_encounters set status='defeat', ended_at=now() where id = v_enc;
end $$;

-- ════════ RESOLVED SCENARIO (encounter_resolver_enabled=true ⇒ the authored plan) ════════════════════
update public.game_config set value='true'::jsonb where key='encounter_resolver_enabled';
do $$
declare uZ uuid := (select v from erfx where k='uZ'); g2 uuid := (select v from erfx where k='g2');
  v_hunt uuid := (select v from erfx where k='hunt'); v_ep uuid := (select v from erfx where k='ep'); v_enc uuid;
  v_lx double precision; v_ly double precision; n int;
  v_hpmax double precision; v_exp_hp double precision; v_px double precision; v_py double precision;
  v_metal double precision; v_exp_metal double precision; v_tier int; v_grants jsonb; v_plan jsonb;
begin
  select x, y, reward_tier into v_lx, v_ly, v_tier from public.locations where id = v_hunt;
  select resource_grants into v_grants from public.reward_profiles where id = (select v from erfx where k='rp');
  v_enc := pg_temp.send_and_settle(uZ, g2, v_hunt);
  insert into erfx values ('enc2', v_enc);

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  -- the resolved wave: 1 unit at the location center; the encounter tagged; the runtime ledger written.
  select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
  if n <> 1 then raise exception 'ER PROOF FAIL RESOLVED: % enemy rows (want 1)', n; end if;
  select hp_max, pos_x, pos_y into v_hpmax, v_px, v_py from public.combat_units where encounter_id = v_enc and side='enemy';
  v_exp_hp := 5 * coalesce(public.cfg_num('enemy_hp_base'),14) * (1 + 1 * coalesce(public.cfg_num('enemy_hp_danger_scale'),0.6)) * 1;  -- archetype base_difficulty=5
  if abs(v_hpmax - v_exp_hp) > 0.001 then raise exception 'ER PROOF FAIL RESOLVED: enemy hp_max % <> archetype-derived %', v_hpmax, v_exp_hp; end if;
  if v_px is distinct from v_lx or v_py is distinct from v_ly then raise exception 'ER PROOF FAIL RESOLVED: enemy not at location center'; end if;
  v_plan := (select resolved_plan_json from public.combat_encounters where id = v_enc);
  if v_plan is null or (v_plan->>'encounter_profile_id') <> v_ep::text then
    raise exception 'ER PROOF FAIL RESOLVED: encounter not tagged with the resolved plan: %', v_plan;
  end if;
  if not exists (select 1 from public.encounter_runtime_state s where s.location_id = v_hunt and s.encounter_profile_id = v_ep and s.last_spawn_at is not null) then
    raise exception 'ER PROOF FAIL RESOLVED: encounter_runtime_state last_spawn_at not set';
  end if;

  -- reward via the AUTHORED profile (base 20) — DISTINCT from the pre-E3 base-10 value, proving the adapter branch.
  update public.combat_units set hp_current = 1 where encounter_id = v_enc and side='enemy';
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();
  if (select waves_cleared from public.combat_encounters where id = v_enc) < 1 then
    raise exception 'ER PROOF FAIL RESOLVED: wave did not clear';
  end if;
  v_metal := ((select total_rewards_json from public.combat_encounters where id = v_enc)->>'metal')::double precision;
  v_exp_metal := public.resolve_encounter_reward_inputs(v_grants, v_tier, 1);
  if v_metal is distinct from v_exp_metal then
    raise exception 'ER PROOF FAIL RESOLVED: total metal % <> authored-profile reward %', v_metal, v_exp_metal;
  end if;
  if v_exp_metal = round(coalesce(public.cfg_num('reward_metal_base'),10) * greatest(v_tier,1) * (1 + 0.25*1) * coalesce(public.cfg_num('reward_multiplier'),1.0)) then
    raise exception 'ER PROOF FAIL RESOLVED: the authored (base 20) reward is indistinguishable from the pre-E3 (base 10) reward — the test cannot discriminate the branch';
  end if;
  raise notice 'ER_PASS_RESOLVED_PLAN';
end $$;

-- ════════ MULTI-WAVE (FIX 2): a resolved encounter REUSES its plan on wave 2 (not synthetic); reward stays resolved ═
do $$
declare v_enc uuid := (select v from erfx where k='enc2'); v_hunt uuid := (select v from erfx where k='hunt');
  v_ep uuid := (select v from erfx where k='ep'); v_grants jsonb; v_tier int; n int;
  v_hpmax double precision; v_exp_hp2 double precision; v_ac int; v_metal double precision; v_exp double precision;
begin
  select reward_tier into v_tier from public.locations where id = v_hunt;
  select resource_grants into v_grants from public.reward_profiles where id = (select v from erfx where k='rp');

  -- wave 1 already cleared (waves_cleared=1). Fast-forward the wave gate and tick → wave 2 spawns. With the
  -- FIX the encounter REUSES its plan (cap=1 would otherwise re-resolve, self-count, and degrade to synthetic).
  update public.combat_encounters set next_wave_at = now() - interval '1 second',
         last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  select count(*) into n from public.combat_units where encounter_id = v_enc and side='enemy';
  if n <> 1 then raise exception 'ER PROOF FAIL MULTIWAVE: % enemy rows on wave 2 (want 1)', n; end if;
  -- wave-2 danger = 1 + waves_cleared(1) = 2 ⇒ RESOLVED hp uses the archetype base_difficulty (5) at danger 2,
  -- NOT the synthetic loc.base_difficulty formula (that degradation is exactly what the fix prevents).
  select hp_max into v_hpmax from public.combat_units where encounter_id = v_enc and side='enemy';
  v_exp_hp2 := 5 * coalesce(public.cfg_num('enemy_hp_base'),14) * (1 + 2 * coalesce(public.cfg_num('enemy_hp_danger_scale'),0.6)) * 1;
  if abs(v_hpmax - v_exp_hp2) > 0.001 then
    raise exception 'ER PROOF FAIL MULTIWAVE: wave-2 hp_max % <> resolved archetype-derived % (degraded to synthetic?)', v_hpmax, v_exp_hp2;
  end if;
  if (select resolved_plan_json->>'encounter_profile_id' from public.combat_encounters where id = v_enc) <> v_ep::text then
    raise exception 'ER PROOF FAIL MULTIWAVE: the resolved tag was lost on wave 2';
  end if;
  -- the ledger was NOT re-upserted on the reused wave (active_count stays 1; the cooldown anchors on wave 1).
  select active_count into v_ac from public.encounter_runtime_state where location_id = v_hunt and encounter_profile_id = v_ep;
  if v_ac <> 1 then raise exception 'ER PROOF FAIL MULTIWAVE: runtime active_count % (want 1 — reuse must not re-upsert)', v_ac; end if;

  -- clear wave 2; the reward must STILL be resolved (base 20) ⇒ total = R(tier,1) + R(tier,2).
  update public.combat_units set hp_current = 1 where encounter_id = v_enc and side='enemy';
  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();
  if (select waves_cleared from public.combat_encounters where id = v_enc) < 2 then
    raise exception 'ER PROOF FAIL MULTIWAVE: wave 2 did not clear';
  end if;
  v_metal := ((select total_rewards_json from public.combat_encounters where id = v_enc)->>'metal')::double precision;
  v_exp := public.resolve_encounter_reward_inputs(v_grants, v_tier, 1) + public.resolve_encounter_reward_inputs(v_grants, v_tier, 2);
  if v_metal is distinct from v_exp then
    raise exception 'ER PROOF FAIL MULTIWAVE: accumulated metal % <> two resolved waves % (wave 2 paid synthetic?)', v_metal, v_exp;
  end if;
  raise notice 'ER_PASS_MULTIWAVE';
end $$;

-- ════════ CAP: the resolved encounter (still active, tagged er_ep, cap=1) blocks a 2nd resolve; heals ═
do $$
declare v_hunt uuid := (select v from erfx where k='hunt'); v_enc2 uuid := (select v from erfx where k='enc2');
begin
  -- enc2 is active + tagged er_ep ⇒ active_cnt = 1 = cap ⇒ NULL.
  if public.resolve_location_encounter(v_hunt, v_hunt::text) is not null then
    raise exception 'ER PROOF FAIL CAP: resolve did not block at the active_encounter_cap';
  end if;
  -- retire enc2 ⇒ active_cnt = 0 ⇒ resolves again (cooldown 0 on er_ep, so CAP is isolated).
  update public.combat_encounters set status='defeat', ended_at=now() where id = v_enc2;
  if public.resolve_location_encounter(v_hunt, v_hunt::text) is null then
    raise exception 'ER PROOF FAIL CAP: resolve did not self-heal after the encounter left active';
  end if;
  raise notice 'ER_PASS_CAP';
end $$;

-- ════════ E5 (0261): VARIETY + SEED-STABLE + ZERO-ELITE + ELITE-READINESS-GUARD ══════════════════════
-- Author a WIDE variety fixture (one archetype, count 1..6 — so the seed moves the composition) and an
-- elite_chance>0 fixture (for the readiness guard). All flags are still on here (the RESOLVED scenario left
-- encounter_resolver_enabled=true; NULL_FLAGS restored E0/E1/E2). resolve() is read-only (STABLE) — repeated
-- calls persist nothing.
do $$
declare uZ uuid := (select v from erfx where k='uZ'); r jsonb; v_zone uuid;
  v_arch uuid := (select v from erfx where k='arch');   -- default reward = er_reward (rp)
  v_f_var uuid; v_ep_var uuid; v_loc_var uuid;
  v_f_elite uuid; v_ep_elite uuid; v_loc_elite uuid;
begin
  select id into v_zone from public.zones limit 1;

  -- VARIETY: a single archetype with min_count 1, max_count 6 — the per-seed count roll spans [1,6].
  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'erp-fleet-var',
         jsonb_build_object('key','erp_fleet_var','display_name','ERP Fleet Var','members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id',v_arch::text,'min_count',1,'max_count',6,'weight',1,'elite_chance',0)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL fleet_var: %', r; end if;
  v_f_var := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'erp-ep-var',
         jsonb_build_object('key','erp_ep_var','display_name','ERP EP Var','active_encounter_cap',5,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_f_var::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_var: %', r; end if;
  v_ep_var := (r->'result'->>'id')::uuid;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Var', 'pirate_hunt', 970, 970, 7, 'active') returning id into v_loc_var;
  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-var',
         jsonb_build_object('location_id', v_loc_var::text, 'encounter_profile_id', v_ep_var::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL var: %', r; end if;

  -- ELITE fixture (fleet + ep + location authored now; bound active LATER, inside the guard test).
  r := pg_temp.call_as(uZ, format('public.enemy_fleet_template_create(%L, %L::jsonb)', 'erp-fleet-elite',
         jsonb_build_object('key','erp_fleet_elite','display_name','ERP Fleet Elite','members', jsonb_build_array(
           jsonb_build_object('enemy_archetype_id',v_arch::text,'min_count',1,'max_count',1,'weight',1,'elite_chance',0.5)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL fleet_elite: %', r; end if;
  v_f_elite := (r->'result'->>'id')::uuid;
  r := pg_temp.call_as(uZ, format('public.encounter_profile_create(%L, %L::jsonb)', 'erp-ep-elite',
         jsonb_build_object('key','erp_ep_elite','display_name','ERP EP Elite','active_encounter_cap',5,'cooldown_seconds',0,
           'members', jsonb_build_array(jsonb_build_object('fleet_template_id',v_f_elite::text,'weight',1)))::text));
  if (r->>'ok')::boolean is not true then raise exception 'AUTHOR FAIL ep_elite: %', r; end if;
  v_ep_elite := (r->'result'->>'id')::uuid;
  insert into public.locations (zone_id, name, location_type, x, y, base_difficulty, status)
    values (v_zone, 'ERP Loc Elite', 'pirate_hunt', 971, 971, 7, 'active') returning id into v_loc_elite;

  insert into erfx values ('loc_var', v_loc_var), ('ep_var', v_ep_var),
                          ('f_elite', v_f_elite), ('ep_elite', v_ep_elite), ('loc_elite', v_loc_elite);
end $$;

-- ER_PASS_E5_VARIETY: across 16 seeds the SAME location resolves >= 2 distinct unit compositions.
do $$
declare v_loc uuid := (select v from erfx where k='loc_var'); v_distinct int;
begin
  if public.resolve_location_encounter(v_loc, '0') is null then
    raise exception 'ER PROOF FAIL E5_VARIETY: variety fixture did not resolve';
  end if;
  select count(distinct (public.resolve_location_encounter(v_loc, g::text) -> 'units')::text)
    into v_distinct from generate_series(0, 15) g;
  if v_distinct < 2 then
    raise exception 'ER PROOF FAIL E5_VARIETY: only % distinct composition(s) across 16 seeds (want >= 2 — seed is not moving the roll)', v_distinct;
  end if;
  raise notice 'ER_PASS_E5_VARIETY';
end $$;

-- ER_PASS_E5_SEED_STABLE: the SAME (location, seed) resolves IDENTICALLY (deterministic).
do $$
declare v_loc uuid := (select v from erfx where k='loc_var'); a jsonb; b jsonb;
begin
  a := public.resolve_location_encounter(v_loc, 'sX');
  b := public.resolve_location_encounter(v_loc, 'sX');
  if a is null then raise exception 'ER PROOF FAIL E5_SEED_STABLE: resolve NULL for a live bound location'; end if;
  if a is distinct from b then
    raise exception 'ER PROOF FAIL E5_SEED_STABLE: the same (loc, seed) resolved differently: % vs %', a, b;
  end if;
  raise notice 'ER_PASS_E5_SEED_STABLE';
end $$;

-- ER_PASS_E5_NO_ELITE: no resolved unit carries an is_elite key; the plan tags elite_policy=disabled_v1;
--   the resolver source carries no is_elite token.
do $$
declare v_loc uuid := (select v from erfx where k='loc_var'); p jsonb; u jsonb; v_res text;
begin
  p := public.resolve_location_encounter(v_loc, 'ne');
  if p is null then raise exception 'ER PROOF FAIL E5_NO_ELITE: variety fixture did not resolve'; end if;
  for u in select value from jsonb_array_elements(p -> 'units') loop
    if u ? 'is_elite' then raise exception 'ER PROOF FAIL E5_NO_ELITE: a resolved unit still carries is_elite: %', u; end if;
  end loop;
  if (p ->> 'elite_policy') is distinct from 'disabled_v1' then
    raise exception 'ER PROOF FAIL E5_NO_ELITE: plan elite_policy % <> disabled_v1', (p ->> 'elite_policy');
  end if;
  select pg_get_functiondef(oid) into v_res from pg_proc where proname='resolve_location_encounter' and pronamespace='public'::regnamespace;
  if v_res ilike '%is_elite%' then raise exception 'ER PROOF FAIL E5_NO_ELITE: resolver source still references is_elite'; end if;
  raise notice 'ER_PASS_E5_NO_ELITE';
end $$;

-- ER_PASS_E5_ELITE_GUARD: the activate-encounter-resolver section-2b readiness SELECT reads 0 over the
--   elite_chance=0 fixtures, and > 0 once an elite_chance>0 fleet is bound active.
do $$
declare uZ uuid := (select v from erfx where k='uZ'); r jsonb; v_n int;
  v_loc_elite uuid := (select v from erfx where k='loc_elite'); v_ep_elite uuid := (select v from erfx where k='ep_elite');
begin
  select count(*) into v_n
    from public.location_encounter_bindings b
    join public.locations l                      on l.id = b.location_id and l.status = 'active'
    join public.encounter_profiles ep            on ep.id = b.encounter_profile_id and ep.active is true
    join public.encounter_profile_members epm     on epm.encounter_profile_id = ep.id
    join public.enemy_fleet_templates ft          on ft.id = epm.fleet_template_id and ft.active is true
    join public.enemy_fleet_template_members fm   on fm.fleet_template_id = ft.id
    join public.enemy_archetypes a                on a.id = fm.enemy_archetype_id and a.active is true
   where b.active is true and fm.elite_chance > 0;
  if v_n <> 0 then
    raise exception 'ER PROOF FAIL E5_ELITE_GUARD: readiness guard counted % elite binding(s) before any elite fixture was bound (want 0)', v_n;
  end if;

  r := pg_temp.call_as(uZ, format('public.location_encounter_binding_create(%L, %L::jsonb)', 'erp-bind-elite',
         jsonb_build_object('location_id', v_loc_elite::text, 'encounter_profile_id', v_ep_elite::text, 'weight', 1)::text));
  if (r->>'ok')::boolean is not true then raise exception 'BIND FAIL elite: %', r; end if;

  select count(*) into v_n
    from public.location_encounter_bindings b
    join public.locations l                      on l.id = b.location_id and l.status = 'active'
    join public.encounter_profiles ep            on ep.id = b.encounter_profile_id and ep.active is true
    join public.encounter_profile_members epm     on epm.encounter_profile_id = ep.id
    join public.enemy_fleet_templates ft          on ft.id = epm.fleet_template_id and ft.active is true
    join public.enemy_fleet_template_members fm   on fm.fleet_template_id = ft.id
    join public.enemy_archetypes a                on a.id = fm.enemy_archetype_id and a.active is true
   where b.active is true and fm.elite_chance > 0;
  if v_n < 1 then
    raise exception 'ER PROOF FAIL E5_ELITE_GUARD: readiness guard did NOT trip after an elite_chance>0 binding went active (got %)', v_n;
  end if;
  raise notice 'ER_PASS_E5_ELITE_GUARD';
end $$;

do $$ begin raise notice 'ENCOUNTER-RESOLVER PROOF PASSED'; end $$;

rollback;
