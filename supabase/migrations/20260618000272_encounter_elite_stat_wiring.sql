-- Byeharu — ELITE STAT WIRING (migration 0272). Resolver-only, DARK, rides the EXISTING quad-flag
-- (enemy_content_registry_enabled AND encounter_authoring_enabled AND encounter_binding_authoring_enabled
-- AND encounter_resolver_enabled — all still seeded false). NO new flag: elite cannot go live independently
-- of the resolver, and the resolver is not live.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS UNBLOCKS
-- E5 (0261) DROPPED the inert is_elite roll and, to keep that honest, taught scripts/activate-encounter-
-- resolver.sql (and the combined one-shot) to REFUSE the flip while any active binding reaches a fleet
-- member with elite_chance>0. That refusal is today the ONLY hard blocker on the resolver go-live act.
-- This slice wires elite for real, so the refusal is removed (replaced by a notice).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE DESIGN — A PLAN SPLIT AT THE MATERIALIZATION BOUNDARY (compose, do not fork)
-- The elite roll happens ONCE, at encounter materialization, inside resolve_location_encounter. It
-- AMPLIFIES the stat value the EXISTING engine already reads and nothing else:
--
--   process_combat_ticks derives EVERY enemy stat of a resolved wave from the SINGLE plan field
--   base_difficulty (hp / attack / range / speed, then divides by the unit count and inserts). So the
--   resolver simply emits the elite subset of an archetype's rolled count as its OWN additional units[]
--   entry, carrying base_difficulty × encounter_elite_difficulty_multiplier and count = <elite count>,
--   with the remainder emitted as the ordinary entry. The tick spawns BOTH through the identical
--   existing insert with NO new branch, and the damage resolver never learns what "elite" means.
--
-- Consequences of that choice, stated plainly:
--   * process_combat_ticks is NOT re-created by this migration. Only ONE function changes.
--   * There is NO new runtime multiplier authority. enemy_fleet_template_members.elite_chance stays a
--     CREATION INPUT; the materialised plan / combat_units snapshot stays the COMBAT AUTHORITY. The
--     'elite': true key on an elite units[] entry is NON-COMBAT METADATA (display/audit) — it is never
--     read by the tick, never a damage input, and never used to re-transform materialised stats.
--   * Replay/retry cannot re-roll elite: the roll is a pure hashtextextended function of
--     (location, per-encounter seed, archetype, unit index), and a resolved encounter reuses its stored
--     resolved_plan_json on every later wave (the 0260 FIX 2) rather than re-querying the template.
--
-- HONEST TRADEOFFS (documented, not hidden):
--   (1) COUPLED BUFF — base_difficulty scales hp AND attack AND range AND speed together, so a v1 elite
--       is stronger in all four at once. Decoupled elite stats would require re-creating
--       process_combat_ticks (an expensive D1-class byte-parity exercise) and are OUT OF SCOPE.
--   (2) REWARDS DO NOT SCALE — the resolved reward is derived from reward_profile / locations.reward_tier
--       / danger, never from units[], so an elite wave is harder for the same loot until a later
--       reward-adapter slice.
--
-- LEGACY PARITY: with elite_chance = 0 (the current authored posture everywhere) the elite count is 0,
-- no elite entry is appended, no 'elite' key is emitted, and units[] is BYTE-IDENTICAL to 0261's. The
-- only difference in the whole plan is the honest top-level tag elite_policy: 'disabled_v1' -> 'multiplier_v1'.
--
-- STACKS ON: 0261 (E5). Signature UNCHANGED (uuid, text) — no pin anywhere has to move.
-- Out of scope: activation (a human gate), reward scaling, decoupled elite stats, any client surface.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. dependency gate — abort loudly if a surface this slice depends on is missing ────────────────
do $elitedep$
declare v_missing text;
begin
  if to_regprocedure('public.resolve_location_encounter(uuid,text)') is null then
    raise exception 'ELITE-WIRING: resolve_location_encounter(uuid,text) (0261/E5) missing — this slice replaces its body';
  end if;
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='enemy_fleet_template_members' and column_name='elite_chance') then
    raise exception 'ELITE-WIRING: enemy_fleet_template_members.elite_chance (0258/E1) missing — nothing to wire';
  end if;
  select string_agg(k, ', ') into v_missing
    from unnest(array['enemy_content_registry_enabled', 'encounter_authoring_enabled',
                      'encounter_binding_authoring_enabled', 'encounter_resolver_enabled']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'ELITE-WIRING: quad-flag game_config key(s) missing: %', v_missing;
  end if;
end $elitedep$;

-- ── 1. the ONE tunable — a CREATION INPUT, coalesce-defaulted at read time (the house convention;
--    seeding documents the chosen default, a re-apply never clobbers a tuned value). NO new flag: elite
--    rides the existing quad-gate, so it cannot go live independently of the resolver. ───────────────
insert into public.game_config (key, value, description) values
  ('encounter_elite_difficulty_multiplier', '2',
   'ELITE STAT WIRING (0272): multiplier applied to an enemy archetype''s base_difficulty for the ELITE '
   'subset of a resolved encounter''s rolled units. Read ONCE, at encounter materialization, inside '
   'resolve_location_encounter — process_combat_ticks NEVER reads it (it only reads the already-'
   'materialised plan field base_difficulty). NOT a runtime combat authority: changing it affects only '
   'encounters resolved AFTER the change; already-resolved encounters keep their stored plan. Because '
   'the tick derives hp/attack/range/speed from that one field, an elite is a COUPLED buff in v1.')
on conflict (key) do nothing;

-- ── 2. resolve_location_encounter — the 0261 body VERBATIM except PASS 1 (the elite split), the
--    materialisation step (which propagates the informational 'elite' marker) and the plan's
--    elite_policy tag. Signature, quad-flag gate, location check, binding/fleet weighted picks,
--    count-roll salt+formula, ceiling clamp, skip-zero, shared-reward resolution and plan shape are
--    UNTOUCHED. Determinism law (0041) preserved: hashtextextended over ':enc:' salts only, NO
--    random()/setseed. STABLE. ────────────────────────────────────────────────────────────────────
create or replace function public.resolve_location_encounter(p_location_id uuid, p_seed text)
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
  v_total           integer := 0;           -- running sum of rolled counts (for the ceiling clamp)
  v_ceiling         integer;
  v_i               integer;
  v_c               integer;
  v_reward_id       uuid;
  v_reward_grants   jsonb;
  v_shared_reward   uuid;                    -- the ONE default reward shared by every spawning archetype
  v_reward_conflict boolean := false;        -- true ⇒ spawning archetypes disagree (no arbitrary pick)
  -- ██ ELITE STAT WIRING (0272) — the split working set. All creation-time only. ██
  v_elem2           jsonb;                   -- the materialised unit object (+ the optional elite marker)
  v_elite_chance    double precision;        -- the member's authored elite_chance (a CREATION INPUT)
  v_elite           integer;                 -- how many of this member's rolled units are ELITE
  v_j               integer;                 -- the per-unit index folded into the elite salt
  v_mult            double precision;        -- encounter_elite_difficulty_multiplier, read ONCE below
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
   where pick.cum >= (((hashtextextended(p_location_id::text || ':' || p_seed || ':enc:binding', 0) % 1000000000) + 1000000000) % 1000000000)::double precision
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
  --     archetypes): count in [min,max] (salt ':enc:count:'||archetype_id, the 0186 (h%n+n)%n idiom).
  --     0272: the rolled count is then SPLIT into a normal + an elite subset (see PASS 1); the plan
  --     carries elite_policy=multiplier_v1.
  select pick.fleet_template_id into v_fleet_id
    from (
      select m.fleet_template_id,
             sum(m.weight) over (order by m.fleet_template_id::text collate pg_catalog."C") as cum,
             sum(m.weight) over () as total
        from public.encounter_profile_members m
        join public.enemy_fleet_templates ft on ft.id = m.fleet_template_id
       where m.encounter_profile_id = v_ep_id and ft.active is true
    ) pick
   where pick.cum >= (((hashtextextended(p_location_id::text || ':' || p_seed || ':enc:fleet', 0) % 1000000000) + 1000000000) % 1000000000)::double precision
                     / 1000000000.0 * pick.total
   order by pick.cum asc
   limit 1;
  if v_fleet_id is null then
    return null;
  end if;

  -- ELITE MULTIPLIER — read ONCE, here, at the materialization boundary. It is a CREATION INPUT: it is
  -- consumed to compute the base_difficulty the plan carries, and is then never referenced again by
  -- anything downstream (the tick reads only the materialised base_difficulty).
  v_mult := greatest(1.0, coalesce(public.cfg_num('encounter_elite_difficulty_multiplier'), 2));

  -- PASS 1: roll each ACTIVE archetype member's count (skip INACTIVE archetypes). Collect the
  -- rolls (incl. default_reward_profile_id) so the TOTAL can be clamped BEFORE units are materialised.
  -- ELITE STAT WIRING (0272): the count roll below is BYTE-IDENTICAL to 0261 (same salt, same idiom).
  -- What is new: the rolled count is SPLIT into a NORMAL subset and an ELITE subset. Each of the
  -- member's v_count units gets ONE deterministic elite roll — hashtextextended over the ':enc:elite:'
  -- salt folded with the per-encounter seed, the archetype id and the unit index (the 0041 law: NO
  -- session RNG of any kind) — compared against the authored elite_chance. The elite subset is appended as its
  -- OWN entry carrying base_difficulty x v_mult, so the existing spawn arm materialises it through the
  -- identical insert with no new branch. elite_chance = 0 ⇒ v_elite = 0 ⇒ exactly the 0261 entry, alone.
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
               + (((hashtextextended(p_location_id::text || ':' || p_seed || ':enc:count:' || v_m.enemy_archetype_id::text, 0) % v_range) + v_range) % v_range)::integer;
    v_elite_chance := coalesce(v_m.elite_chance, 0);
    v_elite := 0;
    if v_elite_chance > 0 and v_count > 0 then
      for v_j in 1 .. v_count loop
        if (((hashtextextended(p_location_id::text || ':' || p_seed || ':enc:elite:' || v_m.enemy_archetype_id::text || ':' || v_j::text, 0) % 1000000000) + 1000000000) % 1000000000)::double precision
             / 1000000000.0 < v_elite_chance then
          v_elite := v_elite + 1;
        end if;
      end loop;
    end if;
    -- the NORMAL remainder — emitted ALWAYS (a 0-count entry is skipped at materialisation, exactly as
    -- 0261 already handled a rolled-or-clamped 0), so with no elites this array is byte-identical to 0261.
    v_rolled := v_rolled || jsonb_build_array(jsonb_build_object(
      'enemy_archetype_id', v_m.enemy_archetype_id,
      'unit_type_id', v_m.unit_type_id,
      'base_difficulty', v_m.base_difficulty,
      'count', v_count - v_elite,
      'stat_overrides', v_m.stat_overrides,
      'default_reward_profile_id', v_m.default_reward_profile_id));
    -- the ELITE subset — appended ONLY when at least one unit rolled elite. Same archetype, same
    -- unit_type, same default reward (so the shared-reward resolution below is unaffected), amplified
    -- base_difficulty, and a NON-COMBAT 'elite' marker for display/audit.
    if v_elite > 0 then
      v_rolled := v_rolled || jsonb_build_array(jsonb_build_object(
        'enemy_archetype_id', v_m.enemy_archetype_id,
        'unit_type_id', v_m.unit_type_id,
        'base_difficulty', v_m.base_difficulty * v_mult,
        'count', v_elite,
        'stat_overrides', v_m.stat_overrides,
        'default_reward_profile_id', v_m.default_reward_profile_id,
        'elite', true));
    end if;
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
    -- ELITE STAT WIRING (0272): the unit object is the 0261 object VERBATIM; an elite entry additionally
    -- carries the informational 'elite': true marker (display/audit ONLY — the tick reads count /
    -- base_difficulty / unit_type_id and ignores every other key). A non-elite entry carries NO elite
    -- key at all, so a zero-elite plan is byte-identical to 0261's.
    v_elem2 := jsonb_build_object(
      'enemy_archetype_id', (v_elem->>'enemy_archetype_id')::uuid,
      'unit_type_id', v_elem->>'unit_type_id',
      'base_difficulty', (v_elem->>'base_difficulty')::double precision,
      'count', (v_elem->>'count')::integer,
      'stat_overrides', v_elem->'stat_overrides');
    if (v_elem->>'elite')::boolean is true then
      v_elem2 := v_elem2 || jsonb_build_object('elite', true);
    end if;
    v_units := v_units || jsonb_build_array(v_elem2);
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
    'elite_policy', 'multiplier_v1',
    'reward_profile', jsonb_build_object('id', v_reward_id, 'resource_grants', v_reward_grants),
    'units', v_units);
end $$;

comment on function public.resolve_location_encounter(uuid, text) is
  'ENCOUNTER RESOLVER (0272/ELITE STAT WIRING): quad-flag-gated deterministic encounter planner with a '
  'PER-ENCOUNTER seed. Returns ONE resolved plan {encounter_profile_id, active_encounter_cap, '
  'cooldown_seconds, elite_policy:multiplier_v1, reward_profile:{id,resource_grants}, '
  'units:[{enemy_archetype_id,unit_type_id,base_difficulty,count,stat_overrides[,elite:true]}]} or NULL. '
  'ELITE is decided ONCE here, at materialization: each of a member''s rolled units takes one '
  'deterministic '':enc:elite:'' roll against the authored elite_chance, and the elite subset is emitted '
  'as its OWN units[] entry with base_difficulty x encounter_elite_difficulty_multiplier. The tick spawns '
  'both entries through its identical existing insert — process_combat_ticks is NOT changed by 0272 and '
  'never learns what elite means. The ''elite'' key is NON-COMBAT metadata (display/audit) only. '
  'elite_chance = 0 ⇒ units[] byte-identical to 0261. hashtextextended over '':enc:'' salts only — NO '
  'random()/setseed (the 0041 law), so replay/retry re-derives the SAME roll and never re-rolls elite. '
  'TRADEOFFS: base_difficulty scales hp/attack/range/speed together (a coupled v1 buff), and rewards do '
  'NOT scale with elites (the reward comes from reward_profile/reward_tier/danger, not units[]).';

revoke all on function public.resolve_location_encounter(uuid, text) from public;
grant execute on function public.resolve_location_encounter(uuid, text) to service_role;

-- ── 3. SELF-ASSERTS — the migration proves its own grounding or refuses to land. Every check below
--    EXECUTES at apply time against the live catalog (no vacuous branches). The RUNTIME behavioural
--    proofs that need authored fixtures (elite rows really spawn at the multiplied hp; zero-elite
--    byte-parity through the real chain; determinism across two resolves; the weapons_json /
--    non-zero-damage regression guard) deliberately live in the disposable CI apply-proof
--    (.github/workflows/elite-stat-wiring-proof.yml + scripts/elite-stat-wiring-proof.sql), NOT here:
--    authoring encounter fixtures inside a production migration is not something this slice will do. ──
do $eliteassert$
declare
  v_tick   text;
  v_res    text;
  v_ccge   text;
  v_report text;
  v_reward text;
  v_base   text;
  v_n      integer;
  v_a      jsonb;
  v_b      jsonb;
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
    raise exception 'ELITE-WIRING self-assert FAIL: process_combat_ticks / resolve_location_encounter missing';
  end if;

  -- (1) DARK ON APPLY: the resolver flag is (still) committed false, so the whole elite path is
  --     unreachable the moment this migration lands.
  if coalesce((select value #>> '{}' from public.game_config where key = 'encounter_resolver_enabled'), 'false') <> 'false' then
    raise exception 'ELITE-WIRING self-assert FAIL: encounter_resolver_enabled is not false — this slice must land DARK';
  end if;
  -- and the new tunable is seeded (the on-conflict-do-nothing seed above must have produced a row).
  if not exists (select 1 from public.game_config where key = 'encounter_elite_difficulty_multiplier') then
    raise exception 'ELITE-WIRING self-assert FAIL: encounter_elite_difficulty_multiplier was not seeded';
  end if;
  if coalesce(public.cfg_num('encounter_elite_difficulty_multiplier'), 0) <= 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: encounter_elite_difficulty_multiplier does not read back as a positive number';
  end if;

  -- (2) process_combat_ticks is UNCHANGED by this slice — it is not re-created here, and every anchor
  --     0261 pinned must still be present in the DEPLOYED body.
  if strpos(v_tick, 'v_resolver_engaged') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: process_combat_ticks lost v_resolver_engaged (the tick must be untouched)'; end if;
  if strpos(v_tick, 'resolve_location_encounter(e.location_id, e.id::text)') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: process_combat_ticks lost the seeded resolver call'; end if;
  if strpos(v_tick, 'v_enemy_count  := least(coalesce(cfg_num(''enemy_synthetic_max_units''),6)::integer, greatest(1, v_danger));') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: the verbatim 0234 synthetic-wave count line is gone from process_combat_ticks'; end if;
  if strpos(v_tick, '''module_type_id'', ''pirate_synthetic_weapon'', ''range'', v_enemy_range,') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: the verbatim 0234 synthetic-wave weapon line is gone from process_combat_ticks'; end if;
  if strpos(v_tick, 'encounter_id, player_id, unit_type_id, side, ship_hp, initial_count, alive_count,') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: the verbatim 0234 synthetic-wave insert is gone from process_combat_ticks'; end if;
  if strpos(v_tick, 'v_reward_metal := round(coalesce(cfg_num(''reward_metal_base''),10) * greatest(loc.reward_tier,1)') = 0
     or strpos(v_tick, '* (1 + coalesce(cfg_num(''reward_danger_scale''),0.25) * v_danger) * coalesce(cfg_num(''reward_multiplier''),1.0));') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: the verbatim reward formula is gone from process_combat_ticks'; end if;
  if strpos(v_tick, 'resolve_encounter_reward_inputs(') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: process_combat_ticks lost the resolved reward adapter'; end if;
  -- the tick must NOT have learned what elite means (the damage side stays elite-blind).
  if v_tick ilike '%elite%' then
    raise exception 'ELITE-WIRING self-assert FAIL: process_combat_ticks references elite — the tick must stay elite-blind'; end if;
  -- exactly TWO random( calls, the 0234 head's two per-arm variance rolls — this slice adds none.
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 2 then
    raise exception 'ELITE-WIRING self-assert FAIL: process_combat_ticks carries % random( call(s) (want exactly 2 — 0272 adds none)', v_n; end if;

  -- (3) DETERMINISM LAW (0041): the resolver body carries no session RNG and keeps the hash idiom.
  if strpos(v_res, 'random(') > 0 or strpos(v_res, 'setseed') > 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: resolve_location_encounter carries a session-RNG token (the 0041 determinism law)'; end if;
  if strpos(v_res, 'hashtextextended') = 0 or strpos(v_res, ':enc:') = 0 or strpos(v_res, 'p_seed') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: resolve_location_encounter lost the hashtextextended / '':enc:'' / p_seed deterministic-roll technique'; end if;
  if strpos(v_res, ':enc:elite:') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: resolve_location_encounter carries no '':enc:elite:'' salt — elite is not wired'; end if;

  -- (4) LEGACY PARITY, structurally: the 0261 COUNT ROLL survives BYTE-IDENTICAL (same salt, same
  --     idiom), the elite work is guarded on elite_chance > 0, and the elite entry is appended only
  --     when at least one unit rolled elite. Together these make a zero-elite plan identical to 0261's
  --     units[]. The empirical byte-parity run is the CI proof's ELITE_PASS_LEGACY_PARITY marker.
  if strpos(v_res, ''':enc:count:'' || v_m.enemy_archetype_id::text, 0) % v_range) + v_range) % v_range)::integer') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: the 0261 count-roll expression changed (legacy parity breach)'; end if;
  if strpos(v_res, 'if v_elite_chance > 0 and v_count > 0 then') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: the elite roll is not guarded on elite_chance > 0 (legacy parity breach)'; end if;
  if strpos(v_res, 'if v_elite > 0 then') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: the elite plan entry is not guarded on a non-zero elite count (legacy parity breach)'; end if;
  if strpos(v_res, 'multiplier_v1') = 0 or strpos(v_res, 'disabled_v1') > 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: the plan does not carry the honest elite_policy=multiplier_v1 tag'; end if;

  -- (5) NO NEW RUNTIME MULTIPLIER AUTHORITY: no elite_* column was added to any combat/runtime table,
  --     and the multiplier is read ONLY through the config key, at materialization.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and table_name in ('combat_units','combat_encounters','encounter_runtime_state','combat_ticks','combat_events')
                and column_name ilike '%elite%') then
    raise exception 'ELITE-WIRING self-assert FAIL: a combat/runtime table grew an elite column — one authority per concept';
  end if;
  if strpos(v_res, 'cfg_num(''encounter_elite_difficulty_multiplier'')') = 0 then
    raise exception 'ELITE-WIRING self-assert FAIL: the resolver does not read the multiplier from its single config authority'; end if;

  -- (6) RUNTIME GATE, executed: with the quad-flag not all-lit (it is not — assert (1) pinned the
  --     resolver flag false) the resolver returns NULL, and two identical calls agree. This runs the
  --     real function against the real catalog; the fixture-backed determinism proof is CI's
  --     ELITE_PASS_DETERMINISM.
  v_a := public.resolve_location_encounter('00000000-0000-0000-0000-000000000000'::uuid, 'selfassert');
  v_b := public.resolve_location_encounter('00000000-0000-0000-0000-000000000000'::uuid, 'selfassert');
  if v_a is not null then
    raise exception 'ELITE-WIRING self-assert FAIL: the resolver returned non-NULL while the quad-flag is dark';
  end if;
  if v_a is distinct from v_b then
    raise exception 'ELITE-WIRING self-assert FAIL: two identical (location, seed) calls disagreed';
  end if;

  -- (7) BLAST RADIUS: the out-of-scope engine functions are not redefined here and carry no elite token.
  if v_ccge is null or v_report is null or v_reward is null or v_base is null then
    raise exception 'ELITE-WIRING self-assert FAIL: an out-of-scope engine function is missing'; end if;
  if v_ccge ilike '%elite%' or v_report ilike '%elite%' or v_reward ilike '%elite%' or v_base ilike '%elite%' then
    raise exception 'ELITE-WIRING self-assert FAIL: an out-of-scope engine function carries an elite token (blast radius breach)'; end if;

  -- (8) ACL: unchanged and engine-only — no new client grant anywhere.
  if has_function_privilege('authenticated', 'public.resolve_location_encounter(uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.resolve_location_encounter(uuid,text)', 'execute')
     or has_function_privilege('public', 'public.resolve_location_encounter(uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception 'ELITE-WIRING self-assert FAIL: an engine function is client-executable'; end if;
  if not has_function_privilege('service_role', 'public.resolve_location_encounter(uuid,text)', 'execute') then
    raise exception 'ELITE-WIRING self-assert FAIL: service_role lost execute on the resolver'; end if;

  raise notice 'ELITE-WIRING self-assert ok: lands DARK (encounter_resolver_enabled still false; no new flag; encounter_elite_difficulty_multiplier seeded and readable); process_combat_ticks NOT re-created and unchanged (v_resolver_engaged + the seeded resolver call + the 0234 synthetic-wave anchors + the verbatim reward formula + the reward adapter all present, exactly 2 random( calls, no elite token — the tick stays elite-blind); the resolver keeps the 0041 determinism law (hashtextextended/'':enc:''/p_seed, no random()/setseed) and adds the '':enc:elite:'' salt; the 0261 count-roll expression is byte-identical and the elite work is guarded on elite_chance>0 / elite_count>0 (legacy parity); plan tagged elite_policy=multiplier_v1; NO elite column on any combat/runtime table and the multiplier has ONE config authority read at materialization; the resolver returns NULL under the dark quad-flag and two identical calls agree; combat_create_group_encounter/report_create/reward_grant/base_add_resources not redefined and elite-free; ACL unchanged (engine-only, service_role execute, no client grant)';
end $eliteassert$;
