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
--   (d) FLAG-OFF      — with encounter_resolver_enabled=false the wave is the VERBATIM synthetic one:
--                       the right row count, unit_type_id, hp_max formula and a NULL resolved_plan_json,
--                       and (0336 repoint) the unit standing exactly on
--                       combat_formation_point(anchor, MEASURED player extent + its OWN weapon range
--                       + 1, slot, phase 0.5) — the ring replaced "at the location center", which was
--                       only ever true while both spawn arms inserted every unit on the anchor.
--   (e) DETERMINISM   — two resolves of the same (location, seed) are identical (the 0041 law).
--   (f) WEAPONS/DAMAGE— elite AND normal enemy units, and the player unit, all carry a NON-EMPTY
--                       weapons_json and real damage flows both ways. THIS IS THE FLEET-1 REGRESSION
--                       GUARD: an empty weapons_json silently yielding 0 damage is the exact failure
--                       that destroyed the owner's Fleet 1 (0262 is the fix path). Prove it cannot recur
--                       on the elite path. (0336 repoint: the two-way damage is read from the tick it
--                       is OBSERVED on rather than from the spawn tick — a wave now arrives outside its
--                       own reach and has to CLOSE before it can fight back.)
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
     -- ██ RE-POINTED BY 0341, BY NAME, NEVER BY WIDENING ██ This pinned the synthetic wave's sizing
     -- line so 0272 could not have quietly moved it. 0341 changed that line on purpose — the wave
     -- gains a body per BAND of danger steps instead of per step, and the danger scales are applied
     -- to the danger ONE body carries. The pin follows the line rather than being deleted, and is
     -- STRICTLY STRONGER than the old form: it now names all three of the sizing's parts (the cap,
     -- the banded ramp and the per-pirate danger), so a future migration can move none of them
     -- silently. This proof is still about the tick OWNING the synthetic sizing, which 0341 keeps.
     or strpos(v_tick, 'least(coalesce(cfg_num(''enemy_synthetic_max_units''),6)::integer,') = 0
     or strpos(v_tick, 'greatest(1, ceil(v_danger::double precision / v_band)::integer)') = 0
     or strpos(v_tick, 'v_pirate_danger := v_danger::double precision / (v_band * v_enemy_count);') = 0
     -- ██ RE-POINTED BY 0339, BY NAME, NEVER BY WIDENING ██ This pinned the wave's weapons_json
     -- delivery shape inside the tick. 0339 folded the enemy-spawn loop — which existed TWICE,
     -- differing only in indentation, and which every migration since 0299 had to patch in lockstep
     -- — into combat_spawn_wave_units, so the literal now lives in that leaf. The pin FOLLOWS it
     -- rather than being deleted or loosened: the tick must COMPOSE the one spawn authority, and the
     -- authority must still carry the shape. Strictly stronger than the old form, which was
     -- satisfiable by either of two copies while the other drifted.
     or strpos(v_tick, 'public.combat_spawn_wave_units(') = 0
     or strpos((select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'combat_spawn_wave_units'),
               '''module_type_id'', ''pirate_synthetic_weapon'', ''range'', p_range,') = 0
     or strpos(v_tick, 'v_reward_metal := round(coalesce(cfg_num(''reward_metal_base''),10) * greatest(loc.reward_tier,1)') = 0 then
    raise exception 'ELITE PROOF FAIL SOURCE: a pinned process_combat_ticks anchor is gone (the tick must be untouched by 0272)';
  end if;
  -- 0314 repointed this pin 2 -> 3: the tick's known RNG sites are the two wave-seed variance
  -- rolls (spatial + aggregate arm) plus the PER-HIT damage roll 0314 added inside the fire loop
  -- ("everytime it deals differently"). The property is unchanged — every RNG site is known and
  -- counted; anything else is drift.
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 3 then
    raise exception 'ELITE PROOF FAIL SOURCE: process_combat_ticks carries % random( call(s) (want exactly 3: two wave seeds + the 0314 per-hit roll)', v_n;
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
-- 0300 lit combat_telegraph_enabled in the CHAIN, so a hunt arrival now QUEUES a telegraph instead
-- of opening combat inline — and this harness's send-then-settle staging found "no active
-- encounter" on every post-0300 chain (verified 2026-08-02: identical failure on main, no 0314).
-- This proof's subject is the TICK, not the telegraph — so it OWNS the inline-opening world the
-- danger-combat way: telegraph pinned dark in-txn (rolled back with everything else).
update public.game_config set value='false'::jsonb where key='combat_telegraph_enabled';

do $$
begin
  perform public.set_game_config('combat_damage_variance_pct', '0'::jsonb);   -- v_variance = 1 (exact numbers)
  -- 0320 pins the SECOND spread knob too. The per-hit roll 0314 added reads
  --   coalesce(cfg_num('combat_hit_variance_pct'), v_var_pct)
  -- so it INHERITED the damage-variance pin above only while that key did not exist. 0320 seeds it
  -- (production runs it at 0.5), and the moment it exists the inheritance stops and every exact
  -- damage equality below becomes a +/-50% roll. A proof must state the precondition it owns
  -- rather than rely on a row's ABSENCE.
  perform public.set_game_config('combat_hit_variance_pct', '0'::jsonb);      -- exact numbers (0314 per-hit roll)
  perform public.set_game_config('combat_tick_logging',  'true'::jsonb);
  perform public.set_game_config('combat_event_logging', 'true'::jsonb);
  -- ── THE FROZEN-CLOCK COOLDOWN WORLD, OWNED — the house idiom this file was the only combat proof
  --    never to adopt, and the reason (f) measured a player that dealt 0 damage. ─────────────────
  -- 0314 arms REAL weapon cooldowns (next_ready_at = now() + cooldown_seconds) and now() is FROZEN
  -- for this whole transaction, so ANY positive cooldown means a weapon fires at most ONCE per proof
  -- run. This file's two ships each carry a FITTED autocannon_battery, whose 2s cooldown comes from
  -- the CATALOG — combat_create_group_encounter freezes module_types.cooldown_seconds into
  -- weapons_json at creation (0301:770) — so neither cooldown KNOB can reach it.
  -- WHY IT ONLY BIT AFTER 0336, AND WHY IT IS THE FIXTURE RATHER THAN THE ENGINE: while every enemy
  -- spawned ON the player, both sides fired on the SAME tick — the wave's first shot and the player's
  -- one and only shot were both tick 1, which is the tick (f) read. 0336 stands a wave outside its
  -- own reach, so its first shot lands a tick or more later, by which time the player's single shot
  -- is long spent and its clock can never come round again under a frozen now(). CI read exactly
  -- that: `the player dealt 0 damage on tick 2 (encounter active, nearest living enemy 1.800 away,
  -- weakest player reach 5)` — in range, armed, not retreating, and simply not ready. In the real
  -- game the cron advances the clock and the gun fires again two seconds later.
  -- The property (f) asserts is UNCHANGED — real damage in BOTH directions on ONE tick — and this is
  -- the same fire-every-tick precondition five other combat proofs in this repo already own with
  -- these exact three lines (team-command-proof.sql:1147-1149 among them). Reverted by the ROLLBACK.
  -- The cooldown property ITSELF is proven where it is owned: danger-combat-proof's RSFEEL block.
  perform public.set_game_config('enemy_synthetic_cooldown_seconds', '0'::jsonb);
  perform public.set_game_config('combat_player_fallback_weapon_cooldown_seconds', '0'::jsonb);
  update public.module_types set cooldown_seconds = 0 where cooldown_seconds is not null and cooldown_seconds > 0;
  -- ── 0336 REPOINTED THIS SCENARIO'S GEOMETRY, AND THE OLD SPELLING IS NOW ACTIVELY HARMFUL ──────
  -- This line used to read `enemy_synthetic_range_base = 10000  -- in range at dist 0`. Both halves of
  -- that comment are dead:
  --   * "at dist 0" — every enemy used to be inserted ON the engagement anchor, i.e. on top of the
  --     player's lead ship. 0336 lays a wave out on a ring at (the MEASURED player-formation extent +
  --     THAT unit's own weapon range + 1), so nothing stands at distance 0 from anything any more.
  --   * "in range"  — a wave now arrives strictly OUTSIDE its own reach BY CONSTRUCTION, at every
  --     difficulty. No range value can put it in range at spawn; that is the whole point of the fix.
  -- What the 10000 does UNDER 0336 is exile the wave 10,001 units from a player whose gun reaches 5:
  -- the enemy is unreachable, the player never fires, and every downstream assert in this file that
  -- needs a shot to land dies with it. That ~10,000-unit spawn is the RULE WORKING, not a runaway —
  -- recorded here so nobody re-chases it as a spawn bug.
  -- THE REPOINT: choose a range whose STRUCTURAL clearance (range + 1) still fits inside the player's
  -- own gun, so the wave lands where the player can reach it. This value serves the FLAG-OFF block
  -- only, which derives its expected radius from the spawned row's own frozen range and is therefore
  -- correct at any value. The RESOLVED run below does not inherit it: it SOLVES for its own base from
  -- the weakest gun actually on its field and the widest difficulty its own binding can mint, because
  -- that run asserts real two-way damage and a typed-in number there would be a coincidence that the
  -- next catalog change breaks silently.
  perform public.set_game_config('enemy_synthetic_range_base', '3'::jsonb);
  -- and the wave HOLDS exactly where 0336 puts it, so the FLAG-OFF block can compare its position
  -- against combat_formation_point with no tolerance to hide behind. Raised to a positive value before
  -- the RESOLVED run below, where the enemy has to CLOSE into its own range for the (f) two-way
  -- damage assert.
  perform public.set_game_config('enemy_synthetic_speed_base', '0'::jsonb);
  perform public.set_game_config('enemy_synthetic_speed_per_difficulty', '0'::jsonb);
  -- ── AND THE PLAYER HOLDS TOO — 0336's other consequence, OWNED rather than suffered. ───────────
  -- A wave standing outside its own reach means every player ship can hit it while it cannot hit back,
  -- which is precisely the KITE arm of combat_unit_decide_move: the player retreats to the edge of its
  -- own range on every tick of every fight in this file. That drags the player formation's extent up
  -- tick by tick, which moves the NEXT wave's spawn radius, which eventually pushes a wave outside the
  -- player's gun and stalls the run. This file's scenario has always been "nothing moves"; under 0336
  -- that costs BOTH speeds, not just the enemy's. Zeroing the scale makes every player row's
  -- combat_units.move_speed 0, so the KITE step is least(0, ...) = 0 — the ship holds, and still fires.
  perform public.set_game_config('combat_player_speed_scale', '0'::jsonb);
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

  -- ── ARM BOTH SHIPS BEFORE THE FLEET RETIREMENT BELOW (0333) ─────────────────────────────────
  -- Items live PER PORT now (`base_items`) and `craft_module` derives the port it spends from the
  -- crafting ship's VALIDATED DOCK. Retiring the commission fleets (immediately below) is exactly
  -- what stops a ship being 'at_location', so a craft after it would answer `not_docked`. Both
  -- crafts therefore run while s1/s2 are still docked at Haven Reach, and each NAMES its ship —
  -- uZ owns TWO, so the sole-ship shim cannot resolve one and would answer `ship_not_found`.
  -- A NULL-base grant lands in uZ's oldest active base (the Home Base, location_id = Haven), which
  -- IS that store. Fitting is legal at 'at_location' as well as 'home' (0114's settled-SAFE set).
  perform public.reward_grant('combat', gen_random_uuid(), uZ, null,
    '{"items": [{"item_id": "weapon_parts", "quantity": 8}, {"item_id": "pirate_alloy", "quantity": 4}, {"item_id": "scrap", "quantity": 12}]}'::jsonb);

  r := pg_temp.call_as(uZ, format('public.craft_module(''elp-gun-1'', ''autocannon_battery'', %L::uuid)', s1));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft1: %', r; end if;
  m1 := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''elp-fit-1'')', m1, s1));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit1: %', r; end if;
  r := pg_temp.call_as(uZ, format('public.craft_module(''elp-gun-2'', ''autocannon_battery'', %L::uuid)', s2));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL craft2: %', r; end if;
  m2 := (r->>'instance_id')::uuid;
  r := pg_temp.call_as(uZ, format('public.fit_module_to_ship(%L::uuid, %L::uuid, ''elp-fit-2'')', m2, s2));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL fit2: %', r; end if;

  update public.main_ship_instances set status='home', updated_at=now() where main_ship_id in (s1, s2);
  update public.fleets set status='destroyed', location_mode='destroyed', active_movement_id=null,
         current_base_id=null, current_location_id=null, current_zone_id=null, current_sector_id=null, updated_at=now()
   where main_ship_id in (s1, s2) and status='present';
  update public.location_presence set status='completed', updated_at=now()
   where fleet_id in (select id from public.fleets where main_ship_id in (s1, s2) and status='destroyed') and status='active';

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
-- ── 0336 RE-PREMISED: "AT THE LOCATION CENTER" IS DEAD; THE RING IT LANDS ON IS NOT ──────────────
-- The property this block owns is UNCHANGED: with encounter_resolver_enabled=false the tick must
-- spawn the VERBATIM pre-E3 synthetic wave — the right row count, the right unit_type_id, the right
-- hp_max formula, resolved_plan_json still NULL. Exactly ONE clause of it died. "the enemy is at the
-- location center" was true only because both spawn arms inserted every unit at the engagement
-- anchor; 0336 gives each unit its own slot on a ring, so that clause is now a statement about a
-- world that no longer exists — and deleting it outright would throw away the only positional
-- coverage this block has.
-- IT IS REPLACED BY THE GEOMETRY THAT IS NOW TRUE, AND THAT GEOMETRY IS STRICTLY MORE INFORMATIVE:
-- the unit must sit exactly on combat_formation_point(anchor, extent + its OWN weapon range + 1,
-- slot, 0.5) for some slot of this wave. Every input is DERIVED, never typed in — the anchor from the
-- same coalesce(engagement_x, loc.x) the tick evaluates, the extent MEASURED off the living player
-- rows before the wave exists, and the range read back off the row's own frozen weapons_json. The old
-- clause pinned two coordinates against one point; this pins them against the leaf the engine itself
-- composes, so a spawn arm that stopped using combat_formation_point, or used it at the wrong radius,
-- phase or slot, fails HERE rather than rendering a fight in the wrong place.
update public.game_config set value='false'::jsonb where key='encounter_resolver_enabled';
do $$
declare uZ uuid := (select v from elfx where k='uZ'); g1 uuid := (select v from elfx where k='g1');
  v_hunt uuid := (select v from elfx where k='hunt'); v_enc uuid;
  n_players int; n_enemy int; v_slot int; v_slot_found int := null;
  v_hpmax double precision; v_exp_hp double precision; v_px double precision; v_py double precision; v_ut text;
  v_ax double precision; v_ay double precision; v_extent double precision; v_erange double precision;
  v_sx double precision; v_sy double precision;  -- (0338) the encounter's own site: where a wave comes FROM
  v_fx double precision; v_fy double precision;
begin
  v_enc := pg_temp.send_and_settle(uZ, g1, v_hunt);
  insert into elfx values ('enc1', v_enc);

  -- ── 0336: THE ANCHOR AND THE PLAYER EXTENT, BOTH READ BEFORE THE WAVE EXISTS ──────────────────
  -- The tick places a wave around coalesce(combat_encounters.engagement_x, locations.x) — composed
  -- here as the same expression, never as a literal. The extent is measured over the LIVING player
  -- rows, which is what the spawn arm itself does, and it has to be read BEFORE the spawn tick: the
  -- spawn happens before any movement inside that tick, so a reading taken afterwards would be the
  -- extent of a formation that has already moved, not the one the wave was placed against.
  select coalesce(ce.engagement_x, l.x), coalesce(ce.engagement_y, l.y), l.x, l.y into v_ax, v_ay, v_sx, v_sy
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  if v_ax is null or v_ay is null then
    raise exception 'ELITE PROOF FAIL FLAGOFF: the encounter has no engagement anchor (engagement_x/y and the location centre are both NULL) — the spawn geometry below would be measured from nothing';
  end if;
  select count(*), coalesce(max(public.osn_distance(v_ax, v_ay, u.pos_x, u.pos_y)), 0)
    into n_players, v_extent
    from public.combat_units u
   where u.encounter_id = v_enc and u.side = 'player' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null;
  -- NON-VACUITY: with no positioned living player row the coalesce would hand back a DEFAULT 0 that
  -- looks exactly like a real measurement of a lone hull standing on the anchor.
  if n_players < 1 then
    raise exception 'ELITE PROOF FAIL FLAGOFF: no positioned living player unit before the spawn tick — the extent below would be a default rather than a measurement, and the radius assert would prove nothing';
  end if;

  update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
  perform public.process_combat_ticks();

  select count(*) into n_enemy from public.combat_units where encounter_id = v_enc and side='enemy';
  if n_enemy <> 1 then raise exception 'ELITE PROOF FAIL FLAGOFF: % enemy rows (want the 1 synthetic)', n_enemy; end if;
  select hp_max, pos_x, pos_y, unit_type_id into v_hpmax, v_px, v_py, v_ut
    from public.combat_units where encounter_id = v_enc and side='enemy';
  if v_ut <> 'pirate_synthetic' then raise exception 'ELITE PROOF FAIL FLAGOFF: enemy unit_type % (want pirate_synthetic)', v_ut; end if;
  v_exp_hp := (select base_difficulty from public.locations where id = v_hunt)
              * coalesce(public.cfg_num('enemy_hp_base'),14)
              * (1 + 1 * coalesce(public.cfg_num('enemy_hp_danger_scale'),0.6)) * 1;
  if abs(v_hpmax - v_exp_hp) > 0.001 then raise exception 'ELITE PROOF FAIL FLAGOFF: enemy hp_max % <> the verbatim synthetic formula %', v_hpmax, v_exp_hp; end if;

  -- ── 0336 REPOINT OF THE POSITION CLAUSE ───────────────────────────────────────────────────────
  -- NULL-PINNED FIRST: `x is distinct from NULL` is TRUE for every real number, so an unwritten
  -- coordinate would have satisfied the OLD clause and would satisfy a naive distance form of the new
  -- one. Absence of a position is failure here, never evidence.
  if v_px is null or v_py is null then
    raise exception 'ELITE PROOF FAIL FLAGOFF: the spawned enemy carries a NULL coordinate (%,%) — a missing position must fail, never pass a geometry assert by absence', v_px, v_py;
  end if;
  select max((w->>'range')::double precision) into v_erange
    from public.combat_units cu, jsonb_array_elements(cu.weapons_json) w
   where cu.encounter_id = v_enc and cu.side = 'enemy';
  if v_erange is null then
    raise exception 'ELITE PROOF FAIL FLAGOFF: the spawned enemy carries no weapon range in its own weapons_json — the spawn radius is DERIVED from that range and cannot be formed';
  end if;
  for v_slot in 0 .. n_enemy - 1 loop
    select fp.x, fp.y into v_fx, v_fy
      from public.combat_formation_point(v_ax, v_ay, v_extent + v_erange + 1, v_slot,
              public.combat_wave_arrival_phase(v_ax, v_ay, v_sx, v_sy, v_slot)) fp;
    if v_fx is not null and v_fy is not null
       and abs(v_px - v_fx) <= 0.000001 and abs(v_py - v_fy) <= 0.000001 then
      v_slot_found := v_slot; exit;
    end if;
  end loop;
  if v_slot_found is null then
    raise exception 'ELITE PROOF FAIL FLAGOFF: the synthetic enemy stands at (%,%), which is not combat_formation_point(anchor %,%, radius % = measured extent % + its own range % + 1, slot, the 0338 arrival phase toward its own site) for any slot of this wave — the flag-off arm is no longer laying the pre-E3 wave out through the one formation authority',
      v_px, v_py, v_ax, v_ay, v_extent + v_erange + 1, v_extent, v_erange;
  end if;

  if (select resolved_plan_json from public.combat_encounters where id = v_enc) is not null then
    raise exception 'ELITE PROOF FAIL FLAGOFF: resolved_plan_json is not NULL on a synthetic encounter';
  end if;
  raise notice 'ELITE_PASS_FLAGOFF_SYNTHETIC (verbatim pre-E3 wave: 1 pirate_synthetic row, hp_max %, resolved_plan_json NULL, standing exactly on combat_formation_point(anchor %,%, extent % + its own range % + 1, slot %, the 0338 arrival phase))',
    round(v_hpmax::numeric, 3), v_ax, v_ay, v_extent, v_erange, v_slot_found;

  update public.combat_encounters set status='defeat', ended_at=now() where id = v_enc;
end $$;

-- ════════ (a)(b)(f) THE REAL CHAIN with the resolver ON — elite units spawn, are stronger, and FIGHT ══
update public.game_config set value='true'::jsonb where key='encounter_resolver_enabled';
-- ── 0336: THE WAVE HAS TO BE ABLE TO CLOSE HERE, WHICH THE FLAG-OFF BLOCK DELIBERATELY DENIED IT ──
-- The FLAG-OFF block above froze the enemy at speed 0 so its position could be compared against
-- combat_formation_point exactly. This block asserts (f), REAL TWO-WAY DAMAGE, and under 0336 a wave
-- arrives strictly outside its own reach — so with speed 0 it would stand there forever and the enemy
-- half of (f) could never be satisfied on a correct engine. The wave is given a speed so it CLOSES,
-- which is what a wave does in the real game; the player still holds (combat_player_speed_scale 0), so
-- the approach converges instead of turning into a kite chase. Owned in-txn like every other knob here
-- and rolled back with the transaction.
do $$ begin perform public.set_game_config('enemy_synthetic_speed_base', '2'::jsonb); end $$;
do $$
declare uZ uuid := (select v from elfx where k='uZ'); g2 uuid := (select v from elfx where k='g2');
  v_hunt uuid := (select v from elfx where k='hunt'); v_enc uuid; v_plan jsonb;
  n int; i int; v_ceiling int; v_mult double precision;
  v_hp_lo double precision; v_hp_hi double precision;
  v_pdmg double precision; v_edmg double precision; v_bad int;
  v_alive int; v_dmg_tick int := null;
  -- 0336: the spawn radius is DERIVED, then verified back against the rows the tick produced.
  v_ax double precision; v_ay double precision; v_extent double precision; v_preach double precision;
  v_dmax double precision; v_perdiff double precision; v_rbase double precision;
  v_mind double precision; v_players int; v_status text;
begin
  v_ceiling := greatest(1, coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::integer);
  v_mult    := coalesce(public.cfg_num('encounter_elite_difficulty_multiplier'), 2);
  v_enc := pg_temp.send_and_settle(uZ, g2, v_hunt);
  insert into elfx values ('enc2', v_enc);

  -- ── 0336: PUT THE WAVE WHERE THE PLAYER CAN ACTUALLY REACH IT, BY DERIVING THE RANGE ────────────
  -- (f) needs REAL two-way damage, and under 0336 that is no longer a given: a wave spawns at
  -- (the MEASURED player-formation extent + THAT unit's own weapon range + 1), which is a distance
  -- the fixture chooses through `enemy_synthetic_range_base` — and this file also pins
  -- combat_player_speed_scale to 0, so a player that cannot reach the wave at spawn can NEVER reach
  -- it. The old `10000` put the wave 10,001 units away and the player half of (f) was structurally
  -- unsatisfiable; a typed-in `3` merely happens to fit today's catalog and would break silently the
  -- next time a gun range or the per-difficulty coefficient moves. So the range is SOLVED FOR here,
  -- from this encounter's own rows and the same expressions the spawn arm evaluates, and then
  -- verified against the spawned rows below. Every input is derived, none is typed in.
  select coalesce(ce.engagement_x, l.x), coalesce(ce.engagement_y, l.y) into v_ax, v_ay
    from public.combat_encounters ce join public.locations l on l.id = ce.location_id
   where ce.id = v_enc;
  if v_ax is null or v_ay is null then
    raise exception 'ELITE PROOF FAIL REACH: the encounter has no engagement anchor — the spawn radius below would be solved against nothing';
  end if;
  -- the formation extent the spawn arm will measure, and the WEAKEST gun on the field (0336's own
  -- player_min_range: the hull that decides whether a site is playable is the worst-armed one).
  select count(*),
         coalesce(max(public.osn_distance(v_ax, v_ay, u.pos_x, u.pos_y)), 0),
         min((select max((w->>'range')::double precision) from jsonb_array_elements(u.weapons_json) w))
    into v_players, v_extent, v_preach
    from public.combat_units u
   where u.encounter_id = v_enc and u.side = 'player' and u.alive_count > 0
     and u.pos_x is not null and u.pos_y is not null;
  -- NON-VACUITY: with no positioned living player row the coalesce hands back a DEFAULT 0 extent
  -- that looks exactly like a real measurement of a lone hull on the anchor, and v_preach comes back
  -- NULL — which would make the derivation below NULL and every comparison silently true.
  if v_players < 1 or v_preach is null or not (v_preach > 0) then
    raise exception 'ELITE PROOF FAIL REACH: % positioned living player row(s), weakest reach % — the spawn radius would be derived from a default rather than a measurement', v_players, v_preach;
  end if;
  -- the WIDEST difficulty this site's live binding can mint, through 0316's own expression (the elite
  -- multiplier applies exactly where an elite can roll), so the derivation covers the elite unit too.
  select max(a.base_difficulty
             * case when coalesce(fm.elite_chance, 0) > 0 then v_mult else 1.0::double precision end)
    into v_dmax
    from public.location_encounter_bindings b
    join public.encounter_profiles ep           on ep.id = b.encounter_profile_id and ep.active is true
    join public.encounter_profile_members pm    on pm.encounter_profile_id = ep.id
    join public.enemy_fleet_templates ft        on ft.id = pm.fleet_template_id and ft.active is true
    join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
    join public.enemy_archetypes a              on a.id = fm.enemy_archetype_id and a.active is true
   where b.location_id = v_hunt and b.active is true;
  if v_dmax is null or not (v_dmax > 0) then
    raise exception 'ELITE PROOF FAIL REACH: the hunt site''s live binding yields no positive archetype difficulty (%) — the spawn radius could not be solved and the elite half of the plan would not be covered', v_dmax;
  end if;
  v_perdiff := coalesce(public.cfg_num('enemy_synthetic_range_per_difficulty'), 5);
  -- radius(D) = extent + (base + D*perdiff) + 1, and the widest unit must land at 80% of the weakest
  -- gun: comfortably inside it, with room for the range to grow with difficulty and no reliance on a
  -- knife-edge equality.
  v_rbase := 0.8 * v_preach - v_extent - 1 - v_dmax * v_perdiff;
  if not (v_rbase > 0) then
    raise exception 'ELITE PROOF FAIL REACH: no positive synthetic range base fits (weakest reach %, extent %, widest difficulty %, per-difficulty % -> base %) — the wave cannot both stand outside its own reach and inside the player''s, and this fixture can no longer stage (f)',
      v_preach, v_extent, v_dmax, v_perdiff, v_rbase;
  end if;
  perform public.set_game_config('enemy_synthetic_range_base', to_jsonb(round(v_rbase::numeric, 6)));

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

  -- ── 0336: THE HALF THE GEOMETRY CANNOT ESTABLISH — THE WAVE IS INSIDE THE PLAYER'S REACH ────────
  -- 0336 makes "the wave is outside its OWN reach at spawn" structural, and says in its own header
  -- that what a CI assertion still has to check is the other half: that the player can reach it.
  -- This is that check, on a real staged wave, measured — not inferred from the knob solved above.
  -- It is a NEW clause and it is what turns the failure this block used to give ("the player dealt 0
  -- damage") from a mystery into a named geometric fact. NULL-PINNED: a unit with no coordinate
  -- counts as UNREACHABLE, because `is distinct from NULL` is TRUE for every real number and a
  -- missing position must never satisfy a geometry assert by absence.
  select count(*) into v_bad
    from public.combat_units e
   where e.encounter_id = v_enc and e.side = 'enemy'
     and (e.pos_x is null or e.pos_y is null
          or not exists (
            select 1 from public.combat_units p
             where p.encounter_id = v_enc and p.side = 'player' and p.alive_count > 0
               and p.pos_x is not null and p.pos_y is not null
               and public.osn_distance(p.pos_x, p.pos_y, e.pos_x, e.pos_y)
                   <= (select max((w->>'range')::double precision)
                         from jsonb_array_elements(p.weapons_json) w)));
  if v_bad > 0 then
    select min(public.osn_distance(p.pos_x, p.pos_y, e.pos_x, e.pos_y)) into v_mind
      from public.combat_units p, public.combat_units e
     where p.encounter_id = v_enc and p.side = 'player' and p.alive_count > 0
       and e.encounter_id = v_enc and e.side = 'enemy';
    raise exception 'ELITE PROOF FAIL REACH: % spawned enemy row(s) stand outside every player gun (nearest player-to-enemy distance %, weakest reach %, derived range base % at extent % / widest difficulty %) — with combat_player_speed_scale pinned 0 the player can never close, so the (f) player half could not be satisfied by any number of ticks',
      v_bad, round(coalesce(v_mind, -1)::numeric, 3), v_preach, round(v_rbase::numeric, 3), v_extent, v_dmax;
  end if;

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
  -- ── 0336: DRIVE TICKS UNTIL THE WAVE HAS CLOSED AND FOUGHT BACK ───────────────────────────────
  -- (f) used to read the ONE tick this block ran, because before 0336 every enemy was inserted on top
  -- of the player and both sides fired the instant the wave existed. 0336 stands a wave at (measured
  -- player extent + its own range + 1), strictly outside its own reach, so the enemy half of (f) is
  -- simply not true yet on the spawn tick — on a CORRECT engine. The property is unchanged and the
  -- assertions below are untouched; only the tick they are read from is now OBSERVED rather than
  -- assumed to be the first. Bounded, with a loud failure and the living-enemy count in the message.
  for i in 1 .. 12 loop
    exit when v_dmg_tick is not null;
    select count(*) into v_alive from public.combat_units
     where encounter_id = v_enc and side = 'enemy' and alive_count > 0;
    if v_alive < 1 then
      raise exception 'ELITE PROOF FAIL DAMAGE: every spawned enemy was destroyed before it closed into its own range — the enemy half of (f) was never exercised';
    end if;
    update public.combat_encounters set last_resolved_at = last_resolved_at - interval '1 minute' where id = v_enc;
    perform public.process_combat_ticks();
    select tick_number into v_dmg_tick from public.combat_ticks
     where encounter_id = v_enc and coalesce(enemy_damage, 0) > 0
     order by tick_number desc limit 1;
  end loop;
  if v_dmg_tick is null then
    raise exception 'ELITE PROOF FAIL DAMAGE: no tick recorded any enemy damage within 12 ticks of the spawn — the spawned enemies never closed into their own range, so they do not fight';
  end if;
  -- NON-VACUITY: 0336 makes the spawn tick silent by construction, so the observed damage tick must be
  -- strictly later. A tick-1 answer would mean the structural clearance is gone, not that (f) holds.
  if v_dmg_tick < 2 then
    raise exception 'ELITE PROOF FAIL DAMAGE: enemy damage is recorded on tick % — 0336 stands a wave outside its own reach at spawn, so it cannot have fought back on the tick it arrived', v_dmg_tick;
  end if;

  select player_damage, enemy_damage into v_pdmg, v_edmg
    from public.combat_ticks where encounter_id = v_enc and tick_number = v_dmg_tick;
  if coalesce(v_pdmg, 0) <= 0 then
    -- DIAGNOSABLE, not merely red. On a correct engine there are exactly THREE ways a player with a
    -- real weapon (guarded above) deals nothing on a tick the enemy fought in: it is out of reach, it
    -- is retreating and silenced by the v_offense gate, or its clock is not ready. All three are in
    -- the message, because the FIRST version of this assert reported only the first two and the real
    -- cause was the third — a fitted 2s catalog cooldown against a frozen now(), which is why the
    -- three cooldown-zeroing lines at the top of this file exist.
    select status into v_status from public.combat_encounters where id = v_enc;
    select min(public.osn_distance(p.pos_x, p.pos_y, e.pos_x, e.pos_y)) into v_mind
      from public.combat_units p, public.combat_units e
     where p.encounter_id = v_enc and p.side = 'player' and p.alive_count > 0
       and e.encounter_id = v_enc and e.side = 'enemy' and e.alive_count > 0;
    select count(*) into v_bad
      from public.combat_units p, jsonb_array_elements(p.weapons_json) w
     where p.encounter_id = v_enc and p.side = 'player' and p.alive_count > 0
       and nullif(w->>'next_ready_at','') is not null
       and (w->>'next_ready_at')::timestamptz > now();
    raise exception 'ELITE PROOF FAIL DAMAGE: the player dealt % damage on tick % — the Fleet-1 zero-damage failure has recurred (encounter %, nearest living enemy % away, weakest player reach %, % player weapon(s) still on cooldown against a FROZEN now())',
      v_pdmg, v_dmg_tick, v_status, round(coalesce(v_mind, -1)::numeric, 3), v_preach, v_bad;
  end if;
  if coalesce(v_edmg, 0) <= 0 then
    raise exception 'ELITE PROOF FAIL DAMAGE: the enemy (elite + normal) dealt % damage — the spawned enemies do not fight', v_edmg;
  end if;
  raise notice 'ELITE_PASS_WEAPONS_DAMAGE (two-way damage measured on tick %, after the 0336 approach: player % / enemy %)',
    v_dmg_tick, round(v_pdmg::numeric, 3), round(v_edmg::numeric, 3);
end $$;

do $$ begin raise notice 'ELITE STAT WIRING PROOF PASSED'; end $$;

rollback;
