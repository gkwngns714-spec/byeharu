-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- ENCOUNTER RESOLVER — READ-ONLY PRE-FLIP PREFLIGHT AUDIT (go / no-go for encounter_resolver_enabled)
--
-- ██ READ-ONLY. THIS FILE PERFORMS NO WRITE OF ANY KIND. ██
--   It opens `begin transaction read only;` so PostgreSQL ITSELF rejects any INSERT/UPDATE/DELETE/DDL,
--   and closes with `rollback;`. There is no write verb, no set_game_config, no activation vocabulary,
--   no flag flip, no RPC that mutates. It NEVER flips encounter_resolver_enabled — that flip is
--   OWNER-GATED and out of scope. This is a pure SELECT / DO-NOTICE diagnostic, safe against production.
--
-- WHAT IT ANSWERS: "before the owner flips encounter_resolver_enabled (currently false), is the world in
-- a state where lighting the pirate-encounter resolver is safe?"  It reports three sections, each with
-- greppable RAISE NOTICE tags, and ends with ONE verdict line — AUDIT_RESULT: PASS or AUDIT_RESULT:
-- FINDINGS. It FAILS CLOSED: any blocking finding ends the run with a non-zero exit (RAISE), so a red CI
-- run == no-go. Nothing is ever written.
--
-- ── SECTION 1  AUDIT_CODE_*  — is the fixed code actually applied at prod? ──────────────────────────────
--   md5(pg_get_functiondef(oid)) + proname + identity args for the runtime-resolver functions from
--   migration 0260 (resolve_location_encounter, resolve_encounter_reward_inputs, process_combat_ticks)
--   and the combat player-side unit writer touched by 0262 (combat_create_group_encounter — the ONLY
--   writer of a side='player' combat_units row carrying weapons_json, i.e. the exact surface the
--   destroyed-fleet zero-damage bug lived on) plus its caller combat_create_encounter. Reads the live
--   value of encounter_resolver_enabled + the quad-flag prerequisites + the spatial/team/intercept gates
--   through the code's own getter public.cfg_bool(text). Confirms the five 0262 fallback config keys.
--
-- ── SECTION 2  AUDIT_RESOLVER_* / AUDIT_ZERO_DAMAGE_RISK_UNITS — the dominant risk ──────────────────────
--   The destroyed-fleet incident: a player unit whose combat_units.weapons_json snapshotted to '[]' fired
--   zero shots in SPATIAL combat and dealt zero damage. 0262 synthesizes ONE fallback weapon at unit
--   creation WHEN the fitted-weapon array is empty AND the ship's attack_snapshot (combat_power) > 0.
--   So a resolver-eligible player unit deals zero damage in spatial combat iff:
--       (has NO fitted range-carrying module with power > 0)  AND  (combat_power <= 0)
--   because a fitted ranged weapon keeps a non-empty weapons_json (fallback never applies), and an empty
--   weapons_json is rescued by the fallback only when combat_power > 0.
--   This audit walks EVERY commissioned player main ship with hp>0 (the exact snapshot domain of
--   combat_create_group_encounter's `if m.hp > 0` branch — one side='player' combat_unit per manifest
--   member), reproducing the SAME reads the creator does: the fitted-weapon join (0262 lines 159-162,
--   `t.range is not null`) for the weapons array, and public.calculate_expedition_stats(player, ship,
--   '[]', 'pirate_hunt') for combat_power. It counts the residual zero-damage-risk units 0262 does NOT
--   cover (combat_power<=0, no ranged weapon). With 0262 live this SHOULD be 0.
--
-- ── SECTION 3  AUDIT_DRIFT_*  — unresolved / residual runtime state ─────────────────────────────────────
--   Non-terminal combat_encounters (status active/retreating), any live resolver-produced encounter
--   (resolved_plan_json not null) while the resolver is supposed to be dark, unresolved pirate_intercept
--   ambushes, and every encounter_runtime_state row: its CUMULATIVE active_count (never decremented — NOT
--   a live count) vs the DERIVED live tagged encounters (the real cap authority, 0260 step (e)). The
--   known residual (active_count=2 at the canary pair) is classified STALE-vs-LIVE, not blindly rejected.
--
-- ── VERDICT ────────────────────────────────────────────────────────────────────────────────────────────
--   AUDIT_FINDING [BLOCK|WARN|INFO] <code> …    one line per finding
--   AUDIT_RESULT: PASS                          zero blocking findings — safe pre-flip posture
--   AUDIT_RESULT: FINDINGS n=<N>                N blocking findings; the run then RAISES (non-zero exit)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

begin transaction read only;
set local statement_timeout = '120s';

-- ══════════ 0. init the finding tallies (read-only session GUCs) ══════════
do $$
begin
  perform set_config('audit.blockers', '0', true);
  perform set_config('audit.warns',    '0', true);
  raise notice '════════ ENCOUNTER RESOLVER PRE-FLIP PREFLIGHT AUDIT — READ-ONLY ════════';
  raise notice 'database now() : %', now();
end $$;

-- ══════════ 1. AUDIT_CODE — is the fixed code applied at prod, and what is the flag posture? ══════════
do $$
declare
  v_b     integer := current_setting('audit.blockers')::int;
  v_w     integer := current_setting('audit.warns')::int;
  v_head  text;
  v_sig   text;
  v_oid   oid;
  v_on    boolean;
  k       text;
  v_missing text;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  raise notice 'AUDIT_FINDING [INFO] AUDIT_CODE_MIGRATION_HEAD head=% :: (0260 resolver / 0262 fallback / 0272 elite expected present)', coalesce(v_head, '(none)');
  if v_head is null or v_head < '20260618000262' then
    raise notice 'AUDIT_FINDING [BLOCK] AUDIT_CODE_HEAD_BELOW_0262 head=% :: the combat player-fallback fix (0262) is not deployed — flipping the resolver would re-expose the zero-damage bug', coalesce(v_head, '(none)');
    v_b := v_b + 1;
  end if;

  -- md5 fingerprint + identity of each function the go/no-go depends on.
  foreach v_sig in array array[
      'public.resolve_location_encounter(uuid, text)',
      'public.resolve_encounter_reward_inputs(jsonb,integer,integer)',
      'public.process_combat_ticks()',
      'public.combat_create_group_encounter(uuid)',
      'public.combat_create_encounter(uuid)'] loop
    v_oid := to_regprocedure(v_sig);
    if v_oid is null then
      raise notice 'AUDIT_FINDING [BLOCK] AUDIT_CODE_FN_MISSING sig=% :: a function the resolver / player-fallback surface depends on is absent', v_sig;
      v_b := v_b + 1;
    else
      raise notice 'AUDIT_FINDING [INFO] AUDIT_CODE_FN sig=% proname=% args=(%) def_md5=%',
        v_sig,
        (select p.proname from pg_proc p where p.oid = v_oid),
        (select pg_get_function_identity_arguments(v_oid)),
        md5(pg_get_functiondef(v_oid));
    end if;
  end loop;

  -- the DEPLOYED process_combat_ticks must carry the 0260 resolved branch (a head number alone proves
  -- nothing about WHICH body landed): the quad-flag resolver-engaged read + the resolve call.
  if to_regprocedure('public.process_combat_ticks()') is not null then
    if (select position('v_resolver_engaged' in p.prosrc) = 0
          or position('resolve_location_encounter(e.location_id, e.id::text)' in p.prosrc) = 0
        from pg_proc p where p.oid = 'public.process_combat_ticks()'::regprocedure) then
      raise notice 'AUDIT_FINDING [BLOCK] AUDIT_CODE_TICK_BODY :: the deployed process_combat_ticks does not carry the 0260/0261/0272 resolver-engaged branch (no v_resolver_engaged / resolve_location_encounter(e.location_id, e.id::text))';
      v_b := v_b + 1;
    else
      raise notice 'AUDIT_FINDING [INFO] AUDIT_CODE_TICK_BODY :: process_combat_ticks carries the 0260 resolver-engaged branch';
    end if;
  end if;

  -- the DEPLOYED combat_create_group_encounter must carry the 0262 fallback hunk (empty-array AND
  -- positive-attack guard, deriving power from attack_snapshot).
  if to_regprocedure('public.combat_create_group_encounter(uuid)') is not null then
    if (select position('if jsonb_array_length(v_weapons_json) = 0 and coalesce(v_attack, 0) > 0 then' in p.prosrc) = 0
        from pg_proc p where p.oid = 'public.combat_create_group_encounter(uuid)'::regprocedure) then
      raise notice 'AUDIT_FINDING [BLOCK] AUDIT_CODE_FALLBACK_HUNK :: the deployed combat_create_group_encounter does not carry the 0262 empty-array + positive-attack fallback guard';
      v_b := v_b + 1;
    else
      raise notice 'AUDIT_FINDING [INFO] AUDIT_CODE_FALLBACK_HUNK :: combat_create_group_encounter carries the 0262 fallback-weapon guard';
    end if;
  end if;

  -- the five 0262 fallback config keys (coalesce-defaulted at read time, so absence is a WARN not a block).
  select string_agg(kk, ', ') into v_missing
    from unnest(array['combat_player_fallback_weapon_power_from_attack',
                      'combat_player_fallback_weapon_range',
                      'combat_player_fallback_weapon_cooldown_seconds',
                      'combat_player_fallback_weapon_projectile_speed',
                      'combat_player_fallback_weapon_module_type_id']) kk
   where not exists (select 1 from public.game_config g where g.key = kk);
  if v_missing is not null then
    raise notice 'AUDIT_FINDING [WARN] AUDIT_CODE_FALLBACK_CONFIG_MISSING missing=% :: 0262 config keys absent (defaults still apply via coalesce)', v_missing;
    v_w := v_w + 1;
  else
    raise notice 'AUDIT_FINDING [INFO] AUDIT_CODE_FALLBACK_CONFIG :: all five 0262 combat_player_fallback_weapon_* keys are seeded';
  end if;

  -- flag posture through the code's own getter.
  if to_regprocedure('public.cfg_bool(text)') is null then
    raise notice 'AUDIT_FINDING [BLOCK] AUDIT_CODE_CFG_BOOL_MISSING :: public.cfg_bool(text) getter is absent — cannot read the resolver flag the way the code does';
    v_b := v_b + 1;
  else
    v_on := public.cfg_bool('encounter_resolver_enabled');
    if v_on then
      raise notice 'AUDIT_FINDING [BLOCK] AUDIT_CODE_RESOLVER_ALREADY_ON :: encounter_resolver_enabled is ALREADY true — this is not a pre-flip state; the resolver is live for everyone', v_on;
      v_b := v_b + 1;
    else
      raise notice 'AUDIT_FINDING [INFO] AUDIT_CODE_RESOLVER_FLAG encounter_resolver_enabled=false :: correct pre-flip posture (this audit is the go/no-go for flipping it)';
    end if;
    -- the quad-flag prerequisites (the resolver is inert unless all four are lit) + the gates that decide
    -- whether the spatial player-fallback path is even reachable.
    foreach k in array array['enemy_content_registry_enabled','encounter_authoring_enabled',
                             'encounter_binding_authoring_enabled','spatial_combat_enabled',
                             'team_command_enabled','pirate_intercept_enabled'] loop
      raise notice 'AUDIT_FINDING [INFO] AUDIT_CODE_FLAG flag=% value=%', k, public.cfg_bool(k);
    end loop;
    raise notice 'AUDIT_FINDING [INFO] AUDIT_CODE_GATE_NOTE :: the spatial player-fallback path (0262) is reachable only when spatial_combat_enabled AND a group sortie enters combat (team_command_enabled); the resolver flip changes ONLY the enemy side, so it does not narrow the player-eligible set';
  end if;

  perform set_config('audit.blockers', v_b::text, true);
  perform set_config('audit.warns',    v_w::text, true);
end $$;

-- ══════════ 2. WEAPONS / EFFECTIVE-DAMAGE AUDIT — every resolver-eligible player unit ══════════
-- Population = commissioned player main ships with hp>0 (the combat_create_group_encounter snapshot
-- domain; one side='player' combat_unit per member). Any such ship can be placed in a ship_group and
-- sent to a resolver-bound hunt_pirates location via send_ship_group_hunt while spatial_combat_enabled.
do $$
declare
  v_b            integer := current_setting('audit.blockers')::int;
  v_w            integer := current_setting('audit.warns')::int;
  r              record;
  v_maxpow       double precision;
  v_nweap        integer;
  v_stats        jsonb;
  v_cp           double precision;
  v_eff_positive boolean;
  v_units        integer := 0;
  v_fleets       integer := 0;
  v_risk         integer := 0;
  v_fallback     integer := 0;
  v_armed        integer := 0;
  v_adapter_err  integer := 0;
  v_have_adapter boolean;
  v_missing_tbl  text;
begin
  select string_agg(t, ', ') into v_missing_tbl
    from unnest(array['public.main_ship_instances','public.ship_module_fittings',
                      'public.module_instances','public.module_types']) t
   where to_regclass(t) is null;
  v_have_adapter := to_regprocedure('public.calculate_expedition_stats(uuid, uuid, jsonb, text)') is not null;

  if v_missing_tbl is not null then
    raise notice 'AUDIT_FINDING [BLOCK] AUDIT_RESOLVER_SURFACE_MISSING missing=% :: cannot audit player weapons/damage', v_missing_tbl;
    v_b := v_b + 1;
  elsif not v_have_adapter then
    raise notice 'AUDIT_FINDING [BLOCK] AUDIT_RESOLVER_ADAPTER_MISSING :: public.calculate_expedition_stats(uuid,uuid,jsonb,text) absent — cannot compute combat_power the way the creator does';
    v_b := v_b + 1;
  else
    -- dispatchable-fleet count: each ship_group with >=1 eligible ship is one team; an ungrouped
    -- eligible ship is its own singleton dispatch unit.
    select coalesce(count(distinct group_id) filter (where group_id is not null), 0)
         + coalesce(count(*) filter (where group_id is null), 0)
      into v_fleets
      from public.main_ship_instances where hp > 0;

    for r in
      select msi.main_ship_id, msi.player_id, msi.hp, msi.status, msi.group_id
        from public.main_ship_instances msi
       where msi.hp > 0
       order by msi.main_ship_id
    loop
      v_units := v_units + 1;

      -- fitted range-carrying modules — the EXACT join combat_create_group_encounter uses (0262 159-162):
      -- weapons_json is non-empty iff at least one fitted module has range not null; a synthesized
      -- fallback fires only when that array is EMPTY.
      select count(*), max(t.power)
        into v_nweap, v_maxpow
        from public.ship_module_fittings f
        join public.module_instances i on i.id = f.module_instance_id
        join public.module_types t     on t.id = i.module_type_id
       where f.main_ship_id = r.main_ship_id and t.range is not null;

      -- combat_power the way the creator reads it (empty support loadout, pirate_hunt), degrade-not-raise
      -- on an illegal member state exactly like the creator (0262 line 190) — a degraded member spawns
      -- alive_count=0 and is INERT (not a live zero-damage combatant), so it is counted separately.
      v_cp := null;
      begin
        v_stats := public.calculate_expedition_stats(r.player_id, r.main_ship_id, '[]'::jsonb, 'pirate_hunt');
        v_cp := coalesce((v_stats->>'combat_power')::double precision, 0);
      exception when others then
        v_cp := null;   -- adapter refused → would spawn alive_count=0 (inert), not a live sitting duck
      end;

      if v_cp is null then
        v_adapter_err := v_adapter_err + 1;
        raise notice 'AUDIT_FINDING [INFO] AUDIT_RESOLVER_ADAPTER_DEGRADE ship=% player=% :: stat adapter refused this ship — it would snapshot as alive_count=0 (inert), never a live combatant', r.main_ship_id, r.player_id;
        continue;
      end if;

      -- effective spatial attack: a fitted ranged weapon fires from weapons_json (fallback never applies),
      -- so it deals damage iff its max power > 0; an empty weapons array is rescued by the fallback iff
      -- combat_power > 0.
      if v_nweap > 0 then
        v_eff_positive := coalesce(v_maxpow, 0) > 0;
        if v_eff_positive then v_armed := v_armed + 1; end if;
      else
        v_eff_positive := v_cp > 0;
        if v_eff_positive then v_fallback := v_fallback + 1; end if;
      end if;

      if not v_eff_positive then
        v_risk := v_risk + 1;
        raise notice 'AUDIT_FINDING [BLOCK] AUDIT_RESOLVER_ZERO_DMG_UNIT ship=% player=% status=% fitted_ranged=% max_weapon_power=% combat_power=% :: this ship would deal ZERO damage in spatial combat (no ranged weapon with power>0, and 0262 fallback cannot fire because combat_power<=0) — a guaranteed-loss sitting duck if sent into a resolver encounter',
          r.main_ship_id, r.player_id, r.status, v_nweap, coalesce(v_maxpow, 0), v_cp;
        v_b := v_b + 1;
      end if;
    end loop;

    raise notice 'AUDIT_RESOLVER_ELIGIBLE_FLEETS=%', v_fleets;
    raise notice 'AUDIT_RESOLVER_ELIGIBLE_UNITS=%', v_units;
    raise notice 'AUDIT_ZERO_DAMAGE_RISK_UNITS=%', v_risk;
    raise notice 'AUDIT_FINDING [INFO] AUDIT_RESOLVER_COVERAGE armed_with_weapon=% fallback_covered_empty_weapon=% adapter_degraded_inert=% :: coverage breakdown of the % eligible units', v_armed, v_fallback, v_adapter_err, v_units;
    if v_risk = 0 then
      raise notice 'AUDIT_FINDING [INFO] AUDIT_RESOLVER_ZERO_DMG_CLEAR :: every hp>0 player main ship either fires a real weapon or is covered by the 0262 fallback (combat_power>0) — no zero-damage sitting duck';
    end if;
  end if;

  perform set_config('audit.blockers', v_b::text, true);
  perform set_config('audit.warns',    v_w::text, true);
end $$;

-- ══════════ 3. AUDIT_DRIFT — unresolved / residual runtime state ══════════
do $$
declare
  v_b        integer := current_setting('audit.blockers')::int;
  v_w        integer := current_setting('audit.warns')::int;
  v_open     integer;
  v_resolved integer;
  v_icpt_open integer;
  v_icpt_orphan integer;
  v_rs_rows  integer := 0;
  v_rs_ac_total integer := 0;
  v_live_total integer := 0;
  r          record;
  v_live     integer;
begin
  -- non-terminal combat_encounters (status active/retreating).
  select count(*) into v_open from public.combat_encounters where status in ('active','retreating');
  raise notice 'AUDIT_FINDING [INFO] AUDIT_DRIFT_OPEN_ENCOUNTERS count=% :: non-terminal combat_encounters (active/retreating) in the world right now', v_open;

  -- live RESOLVER-PRODUCED encounters while the resolver is supposed to be dark — an anomaly.
  select count(*) into v_resolved
    from public.combat_encounters
   where status in ('active','retreating') and resolved_plan_json is not null;
  if v_resolved > 0 then
    raise notice 'AUDIT_FINDING [BLOCK] AUDIT_DRIFT_LIVE_RESOLVED count=% :: resolver-produced encounters (resolved_plan_json not null) are LIVE while encounter_resolver_enabled is supposed to be false — the pre-flip state is not clean', v_resolved;
    v_b := v_b + 1;
  else
    raise notice 'AUDIT_FINDING [INFO] AUDIT_DRIFT_LIVE_RESOLVED count=0 :: no live resolver-produced encounter exists anywhere (correct for a dark resolver)';
  end if;

  -- pirate-intercept ambushes lacking resolution (prototype table; guard existence).
  if to_regclass('public.pirate_intercepts') is not null then
    select count(*) into v_icpt_open
      from public.pirate_intercepts pi
      join public.combat_encounters ce on ce.id = pi.encounter_id
     where pi.hit is true and ce.status in ('active','retreating');
    select count(*) into v_icpt_orphan
      from public.pirate_intercepts pi
     where pi.hit is true and pi.encounter_id is null;
    raise notice 'AUDIT_FINDING [INFO] AUDIT_DRIFT_INTERCEPT unresolved_hits_with_open_encounter=% hits_without_encounter_link=% :: pirate_intercept ambushes (open combat is normal living-game state; unlinked hits are historical/prototype rows)', v_icpt_open, v_icpt_orphan;
  else
    raise notice 'AUDIT_FINDING [INFO] AUDIT_DRIFT_INTERCEPT :: public.pirate_intercepts absent — nothing to audit';
  end if;

  -- encounter_runtime_state: CUMULATIVE active_count (never decremented — NOT a live count) vs the DERIVED
  -- live tagged encounters (the real cap authority, 0260 step (e)). Classify each row STALE vs LIVE.
  if to_regclass('public.encounter_runtime_state') is not null then
    for r in
      select s.location_id, s.encounter_profile_id, s.last_spawn_at, s.active_count
        from public.encounter_runtime_state s
       order by s.location_id::text collate pg_catalog."C", s.encounter_profile_id::text collate pg_catalog."C"
    loop
      v_rs_rows := v_rs_rows + 1;
      v_rs_ac_total := v_rs_ac_total + r.active_count;
      select count(*) into v_live
        from public.combat_encounters ce
       where ce.location_id = r.location_id
         and ce.status in ('active','retreating')
         and ce.resolved_plan_json->>'encounter_profile_id' = r.encounter_profile_id::text;
      v_live_total := v_live_total + v_live;
      if v_live > 0 then
        raise notice 'AUDIT_FINDING [BLOCK] AUDIT_DRIFT_RUNTIME_LIVE location=% profile=% active_count=% derived_live=% :: this runtime pair carries LIVE tagged encounters while the resolver is dark — unaccounted state', r.location_id, r.encounter_profile_id, r.active_count, v_live;
        v_b := v_b + 1;
      else
        raise notice 'AUDIT_FINDING [INFO] AUDIT_DRIFT_RUNTIME_STALE location=% profile=% active_count=% derived_live=0 last_spawn_at=% :: STALE residual (cumulative active_count from an earlier live window; no live encounter tagged — harmless, intentionally retained)', r.location_id, r.encounter_profile_id, r.active_count, r.last_spawn_at;
      end if;
    end loop;
    raise notice 'AUDIT_FINDING [INFO] AUDIT_DRIFT_ACTIVE_COUNT_VS_LIVE runtime_rows=% cumulative_active_count_sum=% derived_live_tagged_sum=% :: active_count is a cumulative spawn counter (never decremented) and is NOT the live-encounter count; the derived live sum is the truth', v_rs_rows, v_rs_ac_total, v_live_total;
  else
    raise notice 'AUDIT_FINDING [INFO] AUDIT_DRIFT_RUNTIME :: public.encounter_runtime_state absent — nothing to audit';
  end if;

  perform set_config('audit.blockers', v_b::text, true);
  perform set_config('audit.warns',    v_w::text, true);
end $$;

-- ══════════ 9. VERDICT ══════════
do $$
declare v_b integer := current_setting('audit.blockers')::int; v_w integer := current_setting('audit.warns')::int;
begin
  raise notice '════════ VERDICT ════════';
  if v_b = 0 then
    raise notice 'AUDIT_RESULT: PASS blockers=0 warnings=% :: no blocking finding. Nothing was written. This is the read-only PRE-FLIP go/no-go; the actual flip of encounter_resolver_enabled remains OWNER-GATED (this audit never flips it).', v_w;
  else
    raise notice 'AUDIT_RESULT: FINDINGS n=% warnings=% :: see every AUDIT_FINDING [BLOCK] line above — each is a separate no-go reason. DO NOT flip encounter_resolver_enabled until they are cleared.', v_b, v_w;
  end if;
end $$;

-- ══════════ 10. FAIL CLOSED — raise (non-zero exit) if anything blocks ══════════
do $$
declare v_b integer := current_setting('audit.blockers')::int;
begin
  if v_b > 0 then
    raise exception 'ENCOUNTER RESOLVER PREFLIGHT AUDIT: % blocking finding(s) — see the AUDIT_FINDING [BLOCK] lines above. NOTHING was written (read-only transaction).', v_b;
  end if;
end $$;

rollback;
