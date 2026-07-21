-- Byeharu — E3: ENCOUNTER RUNTIME RESOLVER — the RISK-INFLECTION slice (migration 0260). It MODIFIES the
-- live combat function process_combat_ticks (0234). DARK behind the fail-closed quad-flag
-- encounter_resolver_enabled (seeded false).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE HARD GUARANTEE: with encounter_resolver_enabled=false (the default) the resolved branch is
-- UNREACHABLE and combat is BYTE-IDENTICAL to pre-E3. v_resolver_engaged is the AND of all FOUR flags
-- (enemy_content_registry_enabled + encounter_authoring_enabled + encounter_binding_authoring_enabled +
-- encounter_resolver_enabled); with any one off it is false, so:
--   • the spatial "spawn now" arm falls straight through to the 0234 synthetic-wave lines (687-726),
--     copied CHARACTER-FOR-CHARACTER into the fallback else,
--   • the wave-clear reward uses the 0234 :898-899 reward formula, copied CHARACTER-FOR-CHARACTER into
--     the fallback else.
-- Proven by scripts/encounter-resolver-proof (ER_PASS_VERBATIM / ER_PASS_FLAGOFF_ROWS /
-- ER_PASS_FLAGOFF_REWARD) and this migration's own deploy self-assert. NOTHING else in the tick changes:
-- the aggregate/legacy (C) arm, combat_create_group_encounter, report_create, reward_grant and
-- base_add_resources are NOT redefined here.
--
-- WHAT THIS ADDS (all additive; the flag-OFF path touches NOTHING):
--   (1) combat_encounters.resolved_plan_json jsonb default null — NULL on every existing/legacy row =
--       "not a resolved encounter"; the ONLY signal the resolved reward/cap logic keys off.
--   (2) encounter_runtime_state — the per (location, profile) cooldown / active-count ledger (DARK-table
--       posture: RLS on, client writes revoked, no public write — mirrors 0259).
--   (3) resolve_encounter_reward_inputs — the algebraic mirror of the 0234 :898-899 reward formula,
--       driven by an AUTHORED reward profile's resource_grants instead of the game_config reward_* keys.
--   (4) resolve_location_encounter — reads the E0-E2 content (quad-flag-gated) and returns ONE
--       DETERMINISTIC resolved encounter plan (hashtextextended only — NO random()/setseed), or NULL.
--   (5) process_combat_ticks — the 0234 body VERBATIM + a one-read resolver-engaged flag + TWO wrapped
--       arms (the spatial spawn arm and the spatial reward line); every fallback branch is 0234 text.
--
-- STACKS ON: E0 (0257 registry), E1 (0258 fleet/encounter profiles), E2 (0259 bindings) + the 0234
-- spatial combat core. Out of scope: World Editor UI (E4), activation (a human gate).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if a surface this slice builds on is missing ────────────────
do $erdep$
begin
  if to_regclass('public.reward_profiles') is null
     or to_regclass('public.enemy_archetypes') is null then
    raise exception 'ENCOUNTER-RESOLVER: E0 (0257) registry tables missing — resolver reads them';
  end if;
  if to_regclass('public.enemy_fleet_templates') is null
     or to_regclass('public.enemy_fleet_template_members') is null
     or to_regclass('public.encounter_profiles') is null
     or to_regclass('public.encounter_profile_members') is null then
    raise exception 'ENCOUNTER-RESOLVER: E1 (0258) fleet/encounter tables missing — resolver reads them';
  end if;
  if to_regclass('public.location_encounter_bindings') is null then
    raise exception 'ENCOUNTER-RESOLVER: E2 (0259) location_encounter_bindings missing — resolver reads it';
  end if;
  if to_regprocedure('public.is_owner()') is null then
    raise exception 'ENCOUNTER-RESOLVER: public.is_owner() (0243) missing';
  end if;
  if to_regprocedure('public.cfg_bool(text)') is null then
    raise exception 'ENCOUNTER-RESOLVER: public.cfg_bool(text) (0046) missing';
  end if;
  if to_regprocedure('public.cfg_num(text)') is null then
    raise exception 'ENCOUNTER-RESOLVER: public.cfg_num(text) missing';
  end if;
  if to_regclass('public.world_editor_audit') is null then
    raise exception 'ENCOUNTER-RESOLVER: public.world_editor_audit (0243) missing';
  end if;
  if to_regclass('public.locations') is null then
    raise exception 'ENCOUNTER-RESOLVER: public.locations (0002) missing — resolver filters active locations';
  end if;
  if to_regclass('public.combat_encounters') is null or to_regclass('public.combat_units') is null then
    raise exception 'ENCOUNTER-RESOLVER: combat_encounters/combat_units (combat core) missing';
  end if;
  if to_regprocedure('public.process_combat_ticks()') is null then
    raise exception 'ENCOUNTER-RESOLVER: process_combat_ticks() (0234) missing — this slice re-creates it';
  end if;
end $erdep$;

-- ── 1. combat_encounters.resolved_plan_json — additive, NULL on every existing/legacy row ─────────
-- NULL = "not a resolved encounter" (zero behavior change on every pre-existing row — no backfill). Set
-- ONLY by process_combat_ticks' new resolved spawn arm, reachable only when the quad-flag is lit.
alter table public.combat_encounters
  add column if not exists resolved_plan_json jsonb default null;

comment on column public.combat_encounters.resolved_plan_json is
  'ENCOUNTER RESOLVER (0260/E3): the resolved encounter plan (from resolve_location_encounter) for a wave '
  'spawned by the resolved branch, or NULL. NULL = a legacy / synthetic (pre-E3) encounter — the reward + '
  'cap logic key off `is not null`. Every existing row is NULL (no backfill) ⇒ zero behavior change.';

-- ── 2. encounter_runtime_state — the per (location, profile) cooldown / active-count ledger ───────
-- DARK-table posture (mirrors 0259): RLS enabled, ALL client writes revoked, no public write path. Only
-- process_combat_ticks (SECURITY DEFINER) upserts it.
create table if not exists public.encounter_runtime_state (
  location_id          uuid not null,
  encounter_profile_id uuid not null,
  last_spawn_at        timestamptz not null,
  active_count         integer not null default 0,
  primary key (location_id, encounter_profile_id)
);

comment on table public.encounter_runtime_state is
  'ENCOUNTER RESOLVER (0260/E3): per (location, encounter_profile) runtime ledger — last_spawn_at (the '
  'cooldown anchor) + active_count. Written ONLY by process_combat_ticks'' resolved spawn arm (SECURITY '
  'DEFINER); DARK-table posture — RLS on, client writes revoked. Empty until the quad-flag is lit.';

alter table public.encounter_runtime_state enable row level security;
create policy "encounter_runtime_state_public_read" on public.encounter_runtime_state for select using (true);
grant select on table public.encounter_runtime_state to anon, authenticated;
revoke insert, update, delete on table public.encounter_runtime_state from anon, authenticated;

-- ── 3. fail-closed feature flag (seeded false; do NOT overwrite if already set) ────────────────────
insert into public.game_config (key, value, description) values
  ('encounter_resolver_enabled', 'false',
   'E3 dark gate for resolve_location_encounter + the resolved branch in process_combat_ticks; INERT '
   'unless ALL FOUR of enemy_content_registry_enabled + encounter_authoring_enabled + '
   'encounter_binding_authoring_enabled + this are true; flag OFF => combat byte-identical to pre-E3')
on conflict (key) do nothing;

-- ── 4. resolve_encounter_reward_inputs — the algebraic mirror of the 0234 :898-899 reward formula ──
-- Pre-E3: round(cfg_num('reward_metal_base') * greatest(reward_tier,1) * (1 + cfg_num('reward_danger_scale')
-- * danger) * cfg_num('reward_multiplier')). E3: the SAME shape, drawing base / danger_coeff from the
-- AUTHORED reward profile's resource_grants.metal and the multiplier from the config key it names
-- (multiplier_ref, pinned to 'reward_multiplier' by the E0 validator). IMMUTABLE-except-cfg → STABLE is
-- not needed; cfg_num is STABLE so this is at most STABLE, but the arithmetic itself is pure, so we mark
-- it IMMUTABLE only if cfg_num were immutable — it is not, so we keep it SECURITY DEFINER + STABLE-safe
-- by NOT marking volatility strictly; PostgreSQL treats an unmarked plpgsql/sql fn as VOLATILE, which is
-- always safe. (Correctness, not planner hints, is the concern on the combat path.)
create or replace function public.resolve_encounter_reward_inputs(p_grants jsonb, p_reward_tier integer, p_danger integer)
returns double precision
language sql
security definer
set search_path = ''
as $$
  select round(
           (p_grants->'metal'->>'base')::double precision
           * greatest(p_reward_tier, 1)
           * (1 + coalesce((p_grants->'metal'->>'danger_coeff')::double precision, 0) * p_danger)
           * coalesce(public.cfg_num(p_grants->'metal'->>'multiplier_ref'), 1.0));
$$;

comment on function public.resolve_encounter_reward_inputs(jsonb, integer, integer) is
  'ENCOUNTER RESOLVER (0260/E3): the algebraic mirror of the pre-E3 :898-899 reward metal formula, driven '
  'by an authored reward profile''s resource_grants.metal (base / danger_coeff) and the config multiplier '
  'it names. For pirate_standard {base:10,danger_coeff:0.25,multiplier_ref:reward_multiplier} + default '
  'config it returns EXACTLY the legacy scalar value.';

revoke all on function public.resolve_encounter_reward_inputs(jsonb, integer, integer) from public;
grant execute on function public.resolve_encounter_reward_inputs(jsonb, integer, integer) to service_role;

-- ── 5. resolve_location_encounter — the DETERMINISTIC, quad-flag-gated encounter planner (or NULL) ─
-- Reads the E0-E2 content and returns ONE resolved plan jsonb, or NULL when the resolver is dark / the
-- location is not live / no active binding / cap or cooldown blocks / no spawnable unit / no active
-- reward profile. Determinism law (0041/0186): hashtextextended over ':enc:' salts only — NO
-- random()/setseed; every order-by is byte-order-pinned (collate pg_catalog."C"). STABLE (reads only).
create or replace function public.resolve_location_encounter(p_location_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ep_id           uuid;
  v_cap             integer;
  v_cooldown        integer;
  v_reward_over     uuid;
  v_fleet_id        uuid;
  v_active_cnt      integer;
  v_units           jsonb := '[]'::jsonb;
  v_rolled          jsonb := '[]'::jsonb;   -- pass-1 per-archetype rolls {…, count} before the clamp
  v_elem            jsonb;
  v_m               record;
  v_count           integer;
  v_range           integer;
  v_is_elite        boolean;
  v_total           integer := 0;           -- running sum of rolled counts (for the ceiling clamp)
  v_ceiling         integer;
  v_i               integer;
  v_c               integer;
  v_reward_id       uuid;
  v_reward_grants   jsonb;
  v_shared_reward   uuid;                    -- the ONE default reward shared by every spawning archetype
  v_reward_conflict boolean := false;        -- true ⇒ spawning archetypes disagree (no arbitrary pick)
begin
  -- (a) QUAD-FLAG gate — inert unless all four are lit (the E2->E1->E0 chain + this slice's own flag).
  if not (public.cfg_bool('enemy_content_registry_enabled')
          and public.cfg_bool('encounter_authoring_enabled')
          and public.cfg_bool('encounter_binding_authoring_enabled')
          and public.cfg_bool('encounter_resolver_enabled')) then
    return null;
  end if;

  -- (b) the location must EXIST and be active (runtime liveness — E2 deferred this filter to here).
  if not exists (select 1 from public.locations where id = p_location_id and status = 'active') then
    return null;
  end if;

  -- (c) deterministic WEIGHTED pick of ONE active binding for this location (order by id::text collate pg_catalog."C",
  --     salt p_location_id||':enc:binding'). Cumulative-weight walk: the first row whose running weight
  --     total reaches the hashed fraction of the grand total. None ⇒ NULL.
  select pick.encounter_profile_id into v_ep_id
    from (
      select w.encounter_profile_id,
             sum(w.weight) over (order by w.id::text collate pg_catalog."C") as cum,
             sum(w.weight) over () as total
        from public.location_encounter_bindings w
       where w.location_id = p_location_id and w.active is true
    ) pick
   where pick.cum >= (((hashtextextended(p_location_id::text || ':enc:binding', 0) % 1000000000) + 1000000000) % 1000000000)::double precision
                     / 1000000000.0 * pick.total
   order by pick.cum asc
   limit 1;
  if v_ep_id is null then
    return null;
  end if;

  -- (d) the bound encounter profile must be active → cap / cooldown / reward_override.
  select ep.active_encounter_cap, ep.cooldown_seconds, ep.reward_override_id
    into v_cap, v_cooldown, v_reward_over
    from public.encounter_profiles ep
   where ep.id = v_ep_id and ep.active is true;
  if v_cap is null then
    return null;
  end if;

  -- (e) CAP (DERIVED — count active/retreating combat_encounters at this location tagged with this
  --     profile in resolved_plan_json; NO combat-end write) AND COOLDOWN gates.
  select count(*) into v_active_cnt
    from public.combat_encounters ce
   where ce.location_id = p_location_id
     and ce.status in ('active', 'retreating')
     and ce.resolved_plan_json->>'encounter_profile_id' = v_ep_id::text;
  if v_active_cnt >= v_cap then
    return null;
  end if;
  if v_cooldown > 0 and exists (
       select 1 from public.encounter_runtime_state s
        where s.location_id = p_location_id and s.encounter_profile_id = v_ep_id
          and now() - s.last_spawn_at < make_interval(secs => v_cooldown)) then
    return null;
  end if;

  -- (f) deterministic WEIGHTED pick of ONE active fleet template from the profile's members (salt
  --     ':enc:fleet'), then expand each ACTIVE archetype member into a unit spec (skip inactive
  --     archetypes): count in [min,max] (salt ':enc:count:'||archetype_id, the 0186 (h%n+n)%n idiom),
  --     elite via elite_chance (salt ':enc:elite:'||archetype_id).
  select pick.fleet_template_id into v_fleet_id
    from (
      select m.fleet_template_id,
             sum(m.weight) over (order by m.fleet_template_id::text collate pg_catalog."C") as cum,
             sum(m.weight) over () as total
        from public.encounter_profile_members m
        join public.enemy_fleet_templates ft on ft.id = m.fleet_template_id
       where m.encounter_profile_id = v_ep_id and ft.active is true
    ) pick
   where pick.cum >= (((hashtextextended(p_location_id::text || ':enc:fleet', 0) % 1000000000) + 1000000000) % 1000000000)::double precision
                     / 1000000000.0 * pick.total
   order by pick.cum asc
   limit 1;
  if v_fleet_id is null then
    return null;
  end if;

  -- PASS 1: roll each ACTIVE archetype member's count + elite (skip INACTIVE archetypes). Collect the
  -- rolls (incl. default_reward_profile_id) so the TOTAL can be clamped BEFORE units are materialised.
  for v_m in
    select fm.enemy_archetype_id, fm.min_count, fm.max_count, fm.elite_chance,
           a.unit_type_id, a.base_difficulty, a.stat_overrides, a.default_reward_profile_id
      from public.enemy_fleet_template_members fm
      join public.enemy_archetypes a on a.id = fm.enemy_archetype_id
     where fm.fleet_template_id = v_fleet_id and a.active is true
     order by fm.enemy_archetype_id::text collate pg_catalog."C"
  loop
    v_range := v_m.max_count - v_m.min_count + 1;
    v_count := v_m.min_count
               + (((hashtextextended(p_location_id::text || ':enc:count:' || v_m.enemy_archetype_id::text, 0) % v_range) + v_range) % v_range)::integer;
    v_is_elite := (((hashtextextended(p_location_id::text || ':enc:elite:' || v_m.enemy_archetype_id::text, 0) % 1000000000) + 1000000000) % 1000000000)::double precision
                  / 1000000000.0 < v_m.elite_chance;
    v_rolled := v_rolled || jsonb_build_array(jsonb_build_object(
      'enemy_archetype_id', v_m.enemy_archetype_id,
      'unit_type_id', v_m.unit_type_id,
      'base_difficulty', v_m.base_difficulty,
      'count', v_count,
      'stat_overrides', v_m.stat_overrides,
      'is_elite', v_is_elite,
      'default_reward_profile_id', v_m.default_reward_profile_id));
    v_total := v_total + v_count;
  end loop;

  -- (f2) CLAMP the TOTAL unit count to the synthetic ceiling (cron-stall guard: the spatial targeting
  --      step is O(n^2) in live units, so an unbounded authored fleet could blow statement_timeout and
  --      abort the WHOLE combat cron). Trim deterministically from the LAST-sorted archetype downward
  --      until the total fits — reuse the synthetic arm's own cap key so authored + synthetic waves share
  --      ONE unit ceiling.
  v_ceiling := greatest(1, coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::integer);
  if v_total > v_ceiling then
    for v_i in reverse (jsonb_array_length(v_rolled) - 1) .. 0 loop
      exit when v_total <= v_ceiling;
      v_c := (v_rolled->v_i->>'count')::integer;
      if v_c > 0 then
        v_count := greatest(0, v_c - (v_total - v_ceiling));
        v_total := v_total - (v_c - v_count);
        v_rolled := jsonb_set(v_rolled, array[v_i::text, 'count'], to_jsonb(v_count));
      end if;
    end loop;
  end if;

  -- (f3) MATERIALISE units — skip any archetype whose (possibly clamped) count is 0 (FIX 4: no phantom
  --      1-unit spawn) — and determine the SHARED reward profile over the SPAWNING archetypes only.
  for v_i in 0 .. jsonb_array_length(v_rolled) - 1 loop
    v_elem := v_rolled -> v_i;
    if (v_elem->>'count')::integer <= 0 then
      continue;
    end if;
    if v_shared_reward is null then
      v_shared_reward := (v_elem->>'default_reward_profile_id')::uuid;
    elsif (v_elem->>'default_reward_profile_id')::uuid is distinct from v_shared_reward then
      v_reward_conflict := true;
    end if;
    v_units := v_units || jsonb_build_array(jsonb_build_object(
      'enemy_archetype_id', (v_elem->>'enemy_archetype_id')::uuid,
      'unit_type_id', v_elem->>'unit_type_id',
      'base_difficulty', (v_elem->>'base_difficulty')::double precision,
      'count', (v_elem->>'count')::integer,
      'stat_overrides', v_elem->'stat_overrides',
      'is_elite', (v_elem->>'is_elite')::boolean));
  end loop;
  if jsonb_array_length(v_units) = 0 then
    return null;   -- every archetype inactive / rolled-or-clamped to 0 ⇒ nothing spawnable ⇒ NOT resolved.
  end if;

  -- (g) reward profile: the encounter OVERRIDE if set; else the ONE default shared by every SPAWNING
  --     archetype; else — divergent defaults with no override — the encounter is NOT runtime-eligible
  --     (return NULL ⇒ legacy synthetic wave). NO arbitrary pick. The chosen profile must be active.
  if v_reward_over is not null then
    v_reward_id := v_reward_over;
  elsif v_reward_conflict then
    return null;
  else
    v_reward_id := v_shared_reward;
  end if;
  select rp.resource_grants into v_reward_grants
    from public.reward_profiles rp
   where rp.id = v_reward_id and rp.active is true;
  if v_reward_grants is null then
    return null;
  end if;

  return jsonb_build_object(
    'encounter_profile_id', v_ep_id,
    'active_encounter_cap', v_cap,
    'cooldown_seconds', v_cooldown,
    'reward_profile', jsonb_build_object('id', v_reward_id, 'resource_grants', v_reward_grants),
    'units', v_units);
end $$;

comment on function public.resolve_location_encounter(uuid) is
  'ENCOUNTER RESOLVER (0260/E3): quad-flag-gated deterministic encounter planner. Returns ONE resolved '
  'plan {encounter_profile_id, active_encounter_cap, cooldown_seconds, reward_profile:{id,resource_grants}, '
  'units:[{enemy_archetype_id,unit_type_id,base_difficulty,count,stat_overrides,is_elite}]} or NULL. '
  'hashtextextended over '':enc:'' salts only — NO random()/setseed (the 0041 determinism law).';

revoke all on function public.resolve_location_encounter(uuid) from public;
grant execute on function public.resolve_location_encounter(uuid) to service_role;

-- ── 6. process_combat_ticks — the 0234 body VERBATIM + the resolver-engaged read + TWO wrapped arms.
--    Every fallback (flag-OFF) branch below is the 0234 text, copied CHARACTER-FOR-CHARACTER; the only
--    additions are the `v_resolver_engaged`/`v_plan` locals, the one-read quad-flag assignment, and the
--    two `if v_resolver_engaged ... then <new> else <0234 verbatim> end if` wrappers. ────────────────
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
  v_loc_x         double precision;
  v_loc_y         double precision;
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
  v_spatial_combat_enabled boolean;  -- read ONCE per invocation, alongside every other one-read knob
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
  v_spatial_combat_enabled := cfg_bool('spatial_combat_enabled');
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
    select base_difficulty, reward_tier, max_presence_seconds into loc from locations where id = e.location_id;

    -- COMBAT-S3 (0234): THE NULL-POS FALLBACK. Read once per encounter per tick, BEFORE the aggregate
    -- select. An encounter with even one NULL pos_x row (dark at creation time, or created before the
    -- flag lit) is NEVER spatial, regardless of what the flag reads THIS tick — an in-flight battle is
    -- never spatialized mid-fight.
    v_is_spatial := v_spatial_combat_enabled
      and exists (select 1 from combat_units where encounter_id = e.id and pos_x is not null);

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
      select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
      v_speed := coalesce(fleet_speed(e.fleet_id), combat_fleet_return_speed(e.fleet_id));
      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform presence_complete(e.presence_id);
      v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
                              'base', v_base_id, null, null, v_base_x, v_base_y, 'return_home', v_speed);
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
              v_plan := public.resolve_location_encounter(e.location_id);
              v_fresh_resolve := true;
            end if;
          end if;
          if v_resolver_engaged and v_plan is not null then
            -- E3 (0260) RESOLVED WAVE: instantiate the authored plan. SAME pacing formulas as the
            -- synthetic arm (690-703), substituting each unit-archetype base_difficulty and the
            -- plan's rolled count; every unit spawns at the location center with the identical weapons_json
            -- shape. Tags the encounter + upserts the runtime ledger; emits a resolved wave_spawned event.
            v_wave_num := e.waves_cleared + 1;
            select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
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
                  v_enemy_unit_hp, v_enemy_unit_hp, v_loc_x, v_loc_y, v_enemy_speed,
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
          select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
          v_enemy_range      := coalesce(cfg_num('enemy_synthetic_range_base'),120)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_range_per_difficulty'),5);
          v_enemy_speed      := coalesce(cfg_num('enemy_synthetic_speed_base'),3)
                                 + loc.base_difficulty * coalesce(cfg_num('enemy_synthetic_speed_per_difficulty'),0.2);
          v_enemy_proj_speed := coalesce(cfg_num('enemy_synthetic_projectile_speed'),250);
          v_enemy_cooldown   := coalesce(cfg_num('enemy_synthetic_cooldown_seconds'),2);
          v_enemy_unit_hp    := v_enemy_hp / v_enemy_count;
          v_enemy_unit_power := v_enemy_attack / v_enemy_count;

          -- Pirates spawn from the ZONE/LOCATION CENTER — every synthetic unit lands at the same point.
          delete from combat_units where encounter_id = e.id and side = 'enemy';
          for v_spawn_i in 1 .. v_enemy_count loop
            insert into combat_units (
              encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,
              hp_max, hp_current, pos_x, pos_y, move_speed, weapons_json)
            values (
              e.id, e.player_id, 'pirate_synthetic', 'enemy', v_enemy_unit_hp, 1, 1,
              v_enemy_unit_hp, v_enemy_unit_hp, v_loc_x, v_loc_y, v_enemy_speed,
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
          player_power_current     = fleet_get_power(e.fleet_id),
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
        player_power_current     = fleet_get_power(e.fleet_id),
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

-- ── 7. SELF-ASSERTS — the migration proves its own grounding or refuses to land ───────────────────
do $erassert$
declare
  v_tick   text;
  v_res    text;
  v_ccge   text;
  v_report text;
  v_reward text;
  v_base   text;
  v_n      integer;
begin
  select prosrc into v_tick   from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  select prosrc into v_res    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'resolve_location_encounter';
  select prosrc into v_ccge   from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  select prosrc into v_report from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'report_create';
  select prosrc into v_reward from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'reward_grant';
  select prosrc into v_base   from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'base_add_resources';
  if v_tick is null or v_res is null then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: process_combat_ticks / resolve_location_encounter missing';
  end if;

  -- (1) the flag is committed DARK.
  if coalesce((select value #>> '{}' from public.game_config where key = 'encounter_resolver_enabled'), 'false') <> 'false' then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: encounter_resolver_enabled is not seeded false';
  end if;

  -- (2) the additive column + the DARK ledger table (RLS on, no client write grant).
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='combat_encounters' and column_name='resolved_plan_json' and is_nullable='YES') then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: combat_encounters.resolved_plan_json missing/not nullable'; end if;
  select count(*) into v_n from public.combat_encounters where resolved_plan_json is not null;
  if v_n <> 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: % pre-existing combat_encounters row(s) already tagged resolved (want 0)', v_n; end if;
  if to_regclass('public.encounter_runtime_state') is null then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: encounter_runtime_state table missing'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.encounter_runtime_state'::regclass) then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: RLS not enabled on encounter_runtime_state'; end if;
  if has_table_privilege('authenticated', 'public.encounter_runtime_state', 'INSERT')
     or has_table_privilege('authenticated', 'public.encounter_runtime_state', 'UPDATE')
     or has_table_privilege('authenticated', 'public.encounter_runtime_state', 'DELETE')
     or has_table_privilege('anon', 'public.encounter_runtime_state', 'INSERT')
     or has_table_privilege('anon', 'public.encounter_runtime_state', 'UPDATE')
     or has_table_privilege('anon', 'public.encounter_runtime_state', 'DELETE') then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: a client role holds a write grant on encounter_runtime_state'; end if;
  select count(*) into v_n from public.encounter_runtime_state;
  if v_n <> 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: encounter_runtime_state is non-empty at migration time (want 0)'; end if;

  -- (3) THE VERBATIM FLAG-OFF ARMS survive in process_combat_ticks — the byte-identity anchors. These
  --     distinctive single-line tokens are the 0234 synthetic-wave + reward lines, copied unchanged into
  --     the fallback else branches (strpos, single-line — the 0228/0234 house convention).
  if strpos(v_tick, 'v_enemy_count  := least(coalesce(cfg_num(''enemy_synthetic_max_units''),6)::integer, greatest(1, v_danger));') = 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: the verbatim synthetic-wave count line is gone (byte-identity breach)'; end if;
  if strpos(v_tick, '''module_type_id'', ''pirate_synthetic_weapon'', ''range'', v_enemy_range,') = 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: the verbatim synthetic-wave weapon line is gone (byte-identity breach)'; end if;
  if strpos(v_tick, 'encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,') = 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: the verbatim synthetic-wave insert is gone (byte-identity breach)'; end if;
  -- the verbatim :898-899 reward formula (multi-line; pinned by two distinctive fragments).
  if strpos(v_tick, 'v_reward_metal := round(coalesce(cfg_num(''reward_metal_base''),10) * greatest(loc.reward_tier,1)') = 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: the verbatim :898 reward formula head is gone (byte-identity breach)'; end if;
  if strpos(v_tick, '* (1 + coalesce(cfg_num(''reward_danger_scale''),0.25) * v_danger) * coalesce(cfg_num(''reward_multiplier''),1.0));') = 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: the verbatim :899 reward formula tail is gone (byte-identity breach)'; end if;
  -- the 0234 AGGREGATE (C) arm survives unchanged (distinctive aggregate-only tokens).
  if strpos(v_tick, 'coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0)') = 0
     or strpos(v_tick, 'v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;') = 0
     or strpos(v_tick, 'v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);') = 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: the 0234 aggregate (C) arm is altered (out-of-scope change)'; end if;

  -- (4) the NEW resolved branch + reward adapter are present and wired.
  if strpos(v_tick, 'v_resolver_engaged') = 0 or strpos(v_tick, 'resolve_location_encounter(e.location_id)') = 0
     or strpos(v_tick, 'resolve_encounter_reward_inputs(') = 0
     or strpos(v_tick, 'encounter_runtime_state') = 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: the resolved branch / reward adapter / runtime-state wiring is missing'; end if;

  -- (5) determinism: NO new random() in the tick beyond the 0234 head's two per-arm variance rolls; the
  --     resolver body uses hashtextextended + '':enc:'' only, never random()/setseed.
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: process_combat_ticks carries % random( call(s) (want exactly 2 — the resolver adds none)', v_n; end if;
  if strpos(v_res, 'random(') > 0 or strpos(v_res, 'setseed') > 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: resolve_location_encounter carries a session-RNG token (the 0041 determinism law)'; end if;
  if strpos(v_res, 'hashtextextended') = 0 or strpos(v_res, ':enc:') = 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: resolve_location_encounter lost the hashtextextended / '':enc:'' deterministic-roll technique'; end if;

  -- (6) the out-of-scope engine functions are NOT redefined here — they exist and their bodies carry NO
  --     E3 token (proving 0260 injected nothing into them).
  if v_ccge is null or v_report is null or v_reward is null or v_base is null then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: an out-of-scope engine function is missing'; end if;
  if strpos(v_ccge, 'resolve_location_encounter') > 0 or strpos(v_ccge, 'resolved_plan_json') > 0
     or strpos(v_report, 'resolve_location_encounter') > 0 or strpos(v_report, 'resolved_plan_json') > 0
     or strpos(v_reward, 'resolve_location_encounter') > 0 or strpos(v_reward, 'resolved_plan_json') > 0 or strpos(v_reward, 'encounter_runtime_state') > 0
     or strpos(v_base, 'resolve_location_encounter') > 0 or strpos(v_base, 'encounter_runtime_state') > 0 then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: an out-of-scope engine function carries an E3 token (blast radius breach)'; end if;

  -- (7) the reward adapter is algebraically the legacy formula for pirate_standard + default config.
  if public.resolve_encounter_reward_inputs(
       '{"metal":{"base":10,"danger_coeff":0.25,"multiplier_ref":"reward_multiplier"}}'::jsonb, 1, 1)
     is distinct from round(coalesce(public.cfg_num('reward_metal_base'),10) * greatest(1,1)
                            * (1 + coalesce(public.cfg_num('reward_danger_scale'),0.25) * 1) * coalesce(public.cfg_num('reward_multiplier'),1.0)) then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: resolve_encounter_reward_inputs is not algebraically the legacy reward formula'; end if;

  -- (7b) reward adapter NULL-safety: a missing multiplier_ref key must yield 1.0 (the coalesce guard),
  --      never NULL (which would poison the wave-clear reward on the resolved path).
  if public.resolve_encounter_reward_inputs('{"metal":{"base":10,"multiplier_ref":"__er_no_such_key__"}}'::jsonb, 1, 1) is null then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: resolve_encounter_reward_inputs returns NULL for a missing multiplier_ref (coalesce guard lost)';
  end if;

  -- (8) ACL: the tick + the two resolver functions stay non-client-executable (engine-only).
  if has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('authenticated', 'public.resolve_location_encounter(uuid)', 'execute')
     or has_function_privilege('anon', 'public.resolve_location_encounter(uuid)', 'execute') then
    raise exception 'ENCOUNTER-RESOLVER self-assert FAIL: an engine function is client-executable'; end if;

  raise notice 'ENCOUNTER-RESOLVER self-assert ok: encounter_resolver_enabled seeded dark; resolved_plan_json additive (0 tagged rows) + encounter_runtime_state DARK (RLS on, no client write, empty); the verbatim 0234 synthetic-wave + :898-899 reward lines + the whole aggregate (C) arm survive byte-identical in the flag-OFF fallback; the resolved branch + reward adapter + runtime-state upsert are wired; the tick carries exactly 2 random( calls (resolver adds none) and resolve_location_encounter is hashtextextended/'':enc:''-deterministic with no RNG; combat_create_group_encounter/report_create/reward_grant/base_add_resources are not redefined and carry no E3 token; the reward adapter equals the legacy scalar formula; ACL on the engine functions unchanged (non-client-executable)';
end $erassert$;

