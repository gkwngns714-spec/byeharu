-- Byeharu — COMBAT-FALLBACK: spatial-mode player ships with NO fitted weapon module fire a
-- SYNTHESIZED basic weapon (migration 0262). Forward-only; redefines combat_create_group_encounter
-- (the 0234 HEAD) with ONE marked additive hunk. The tick (process_combat_ticks) is UNTOUCHED — it
-- stays a pure consumer of combat_units.weapons_json.
--
-- ══ THE BUG (confirmed on production, spatial_combat_enabled=true) ═══════════════════════════════════
-- In spatial combat, process_combat_ticks (0234/0260) makes each unit fire ONLY from its own
-- combat_units.weapons_json array — its fire loop is `for v_widx in 0 .. jsonb_array_length(
-- weapons_json) - 1 loop … damage … end loop`. A player unit whose weapons_json='[]' therefore fires
-- NOTHING and deals ZERO damage, EVEN WHEN its attack_snapshot (aggregate combat_power) is positive.
-- combat_create_group_encounter (0234) builds a player ship's weapons_json SOLELY from the ship's
-- fitted range-carrying weapon modules:
--     select coalesce(jsonb_agg(…), '[]')  from ship_module_fittings f
--       join module_instances i … join module_types t …  where … and t.range is not null;
-- A ship whose combat_power comes from a CAPTAIN command fold (0205 captain attack), a hull/trait
-- fold, or any non-range source — but which has NO autocannon/range weapon fitted — lands
-- weapons_json='[]' with attack_snapshot>0. In the dark (aggregate) combat arm this is harmless (that
-- arm reads attack_snapshot directly), but in SPATIAL mode it means the ship is a sitting duck: it
-- takes fire and is destroyed while dealing zero damage back. This is a FITTING GAP (no weapon module
-- fitted → the fitting join is legitimately empty), NOT a snapshot serialization bug — a starter ship
-- has no weapon module fitted by default, yet can carry a positive attack from a captain.
--
-- ══ THE FIX ("option B" — materialize at creation, keep the tick a pure consumer) ═══════════════════
-- At combat-unit creation, when a player ship's computed weapons array is EMPTY *and* its
-- attack_snapshot (v_attack) is positive, synthesize ONE fallback "basic player weapon" whose:
--   • power            = attack_snapshot × combat_player_fallback_weapon_power_from_attack (1.0),
--   • range/proj/cd    = the DEDICATED combat_player_fallback_weapon_* config knobs (a distinct
--                        BASIC PLAYER weapon profile — NOT a copy of the enemy synthetic's numbers),
--   • module_type_id   = the combat_player_fallback_weapon_module_type_id label (telemetry tag only).
-- A ship that DID fit a range weapon keeps its weapons_json byte-untouched (the hunk is guarded on the
-- array being EMPTY). Fires only in spatial mode (the hunk is inside the LIT-only spatial snapshot
-- block, so dark creation stays byte-parity with 0234).
--
-- ══ CONFIG KEYS (all coalesce-defaulted at read time — the house convention; seeding documents the
--    chosen defaults, a re-apply never clobbers a tuned value) ══════════════════════════════════════
-- Player basic-weapon defaults match the entry-tier autocannon_battery (0229: range 150, projectile
-- 300, cooldown 2) — a coherent "your basic gun" profile — and are DELIBERATELY separate from the
-- enemy synthetic weapon knobs (enemy_synthetic_range_base 120 / _projectile_speed 250 / _cooldown 2).
insert into public.game_config (key, value, description) values
  ('combat_player_fallback_weapon_power_from_attack', '1',
   'COMBAT-FALLBACK (0262): multiplier applied to a player ship''s attack_snapshot (combat_power) to '
   'set the synthesized fallback weapon''s power when the ship has NO fitted range-weapon module. 1 = '
   'the fallback gun hits exactly as hard as the ship''s aggregate attack. Read ONLY at combat-unit '
   'creation (combat_create_group_encounter); process_combat_ticks never reads it.'),
  ('combat_player_fallback_weapon_range', '150',
   'COMBAT-FALLBACK (0262): world-unit range of the synthesized basic player weapon. 150 = the '
   'entry-tier autocannon_battery range (0229) — the player''s basic-weapon default, DISTINCT from '
   'the enemy synthetic''s 120.'),
  ('combat_player_fallback_weapon_cooldown_seconds', '2',
   'COMBAT-FALLBACK (0262): seconds between shots for the synthesized basic player weapon (the '
   'autocannon_battery cadence, 0229).'),
  ('combat_player_fallback_weapon_projectile_speed', '300',
   'COMBAT-FALLBACK (0262): projectile speed (world units/sec) of the synthesized basic player '
   'weapon. 300 = the autocannon_battery muzzle velocity (0229) — DISTINCT from the enemy '
   'synthetic''s 250.'),
  ('combat_player_fallback_weapon_module_type_id', '"basic_player_weapon"',
   'COMBAT-FALLBACK (0262): the module_type_id LABEL stamped on the synthesized fallback weapon''s '
   'weapons_json entry. A display/telemetry tag ONLY — like the enemy''s ''pirate_synthetic_weapon'' '
   'label, it is NOT an FK into module_types.')
on conflict (key) do nothing;

-- ── combat_create_group_encounter — 0234 body VERBATIM + the marked COMBAT-FALLBACK (0262) hunk ─────
create or replace function public.combat_create_group_encounter(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pr        location_presence%rowtype;
  m         record;
  v_stats   jsonb;
  v_roster  jsonb := '[]'::jsonb;
  v_power   double precision := 0;
  v_attack  double precision;
  v_defense double precision;
  v_hp      double precision;
  v_alive   integer;
  v_shield_max double precision;
  v_shield_cur double precision;
  v_aggro_priority integer;
  v_hull    double precision;
  v_enc     uuid;
  -- COMBAT-S3 (0234): the player position/speed/weapons snapshot — LIT-only working set. Gate read
  -- ONCE at entry (the 0198 v_growth / 0193 v_traits_enabled posture, mirrored). v_loc_x/v_loc_y/
  -- v_ring_radius are only ever populated when lit; the per-member locals (v_pos_x/v_pos_y/
  -- v_move_speed/v_weapons_json) are reset to the inert NULL/NULL/NULL/'[]' shape at the TOP of every
  -- loop iteration (the exact v_attack/v_defense/... reset law already in this function) so a dark or
  -- degraded member always lands the byte-equivalent-to-"column doesn't exist" shape.
  v_spatial_enabled boolean := public.cfg_bool('spatial_combat_enabled');
  v_loc_x           double precision;
  v_loc_y           double precision;
  v_ring_radius     double precision;
  v_escort_idx      integer := 0;
  v_pos_x           double precision;
  v_pos_y           double precision;
  v_move_speed      double precision;
  v_weapons_json    jsonb;
begin
  select * into pr from location_presence where id = p_presence;
  if not found then
    raise exception 'combat_create_group_encounter: presence % not found', p_presence;
  end if;

  -- COMBAT-S3 (0234): the arrival location's own center — the formation anchor (command ship spawns
  -- HERE; escorts ring around it). ONE extra read, dark-gated; a NEW statement, touches nothing else.
  if v_spatial_enabled then
    select x, y into v_loc_x, v_loc_y from locations where id = pr.location_id;
    v_ring_radius := coalesce(public.cfg_num('spatial_formation_ring_radius'), 30);
  end if;

  for m in
    select gsm.main_ship_id, gsm.player_id, msi.hp, msi.shield, msi.max_shield, msi.is_command_ship
      from group_sortie_members gsm
      join main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
     where gsm.fleet_id = pr.fleet_id
     order by gsm.main_ship_id
  loop
    v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
    v_shield_max := null; v_shield_cur := null;
    v_aggro_priority := case when m.is_command_ship then 100 else 0 end;
    -- COMBAT-S3 (0234): the inert default — reset EVERY iteration, before the hp>0 branch (the same
    -- unconditional-reset law aggro_priority already follows), so a degraded member's row lands
    -- exactly the "no spatial data" shape regardless of why it degraded.
    v_pos_x := null; v_pos_y := null; v_move_speed := null; v_weapons_json := '[]'::jsonb;
    if m.hp > 0 then
      begin
        v_stats   := public.calculate_expedition_stats(m.player_id, m.main_ship_id, '[]'::jsonb, 'pirate_hunt');
        v_attack  := coalesce((v_stats->>'combat_power')::double precision, 0);
        v_defense := coalesce((v_stats->>'survival')::double precision, 0);
        v_hp      := m.hp;
        v_alive   := 1;
        if m.max_shield > 0 then
          v_shield_max := m.max_shield;
          v_shield_cur := m.shield;
        end if;
        -- COMBAT-S3 (0234): position/speed/weapons — LIT only, computed from the SAME successful
        -- adapter call above (v_stats) — no second calculate_expedition_stats invocation.
        if v_spatial_enabled then
          v_move_speed := coalesce((v_stats->>'speed')::double precision, 1);
          if m.is_command_ship then
            v_pos_x := v_loc_x;
            v_pos_y := v_loc_y;
          else
            v_pos_x := v_loc_x + v_ring_radius * cos(2 * pi() * v_escort_idx / 8);
            v_pos_y := v_loc_y + v_ring_radius * sin(2 * pi() * v_escort_idx / 8);
            v_escort_idx := v_escort_idx + 1;
          end if;
          -- The S0 ship_weapon_modules (0229) fitting join, INLINED (that leaf filters
          -- player_id = auth.uid(), unusable from this security-definer engine context — see the
          -- header grounding). Frozen next_ready_at/ammo_remaining = NULL: every weapon is ready to
          -- fire tick 1.
          select coalesce(jsonb_agg(jsonb_build_object(
                   'module_type_id', t.id, 'range', t.range, 'projectile_speed', t.projectile_speed,
                   'power', t.power, 'ammo_type', t.ammo_type, 'ammo_per_shot', t.ammo_per_shot,
                   'cooldown_seconds', t.cooldown_seconds, 'next_ready_at', null, 'ammo_remaining', null)),
                 '[]'::jsonb)
            into v_weapons_json
            from ship_module_fittings f
            join module_instances i on i.id = f.module_instance_id
            join module_types t     on t.id = i.module_type_id
           where f.main_ship_id = m.main_ship_id and t.range is not null;
          -- ██ COMBAT-FALLBACK (0262): NO-WEAPON-MODULE PLAYER SHIPS STILL FIRE IN SPATIAL MODE ██
          -- A player ship whose fitted modules yield an EMPTY weapons array (no range-carrying
          -- weapon module fitted) but which still carries a positive attack_snapshot (v_attack —
          -- its combat_power from captain/hull/trait folds) would, in spatial mode, fire NOTHING
          -- and deal ZERO damage: the tick is a pure consumer of weapons_json and its fire loop
          -- `for v_widx in 0 .. jsonb_array_length(weapons_json) - 1` never iterates over an empty
          -- array. Materialize ONE synthesized "basic player weapon" HERE (at creation, never in
          -- the tick), deriving its power from the ship's OWN attack_snapshot and its range/
          -- projectile_speed/cooldown from the dedicated combat_player_fallback_weapon_* knobs (the
          -- player's basic-weapon profile — DELIBERATELY separate from the enemy synthetic's). A
          -- ship that DID fit a range weapon keeps its weapons_json byte-untouched (guarded on the
          -- array being EMPTY). Same entry shape as the fitted case (module_type_id/range/
          -- projectile_speed/power/ammo_type/ammo_per_shot/cooldown_seconds/next_ready_at/
          -- ammo_remaining) so the tick reads it identically.
          if jsonb_array_length(v_weapons_json) = 0 and coalesce(v_attack, 0) > 0 then
            v_weapons_json := jsonb_build_array(jsonb_build_object(
              'module_type_id',   coalesce((select value #>> '{}' from game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon'),
              'range',            coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 150),
              'projectile_speed', coalesce(public.cfg_num('combat_player_fallback_weapon_projectile_speed'), 300),
              'power',            v_attack * coalesce(public.cfg_num('combat_player_fallback_weapon_power_from_attack'), 1),
              'ammo_type',        null,
              'ammo_per_shot',    0,
              'cooldown_seconds', coalesce(public.cfg_num('combat_player_fallback_weapon_cooldown_seconds'), 2),
              'next_ready_at',    null,
              'ammo_remaining',   null));
          end if;
        end if;
      exception when others then
        v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
        v_shield_max := null; v_shield_cur := null;
      end;
    end if;
    v_power  := v_power + v_attack;
    v_roster := v_roster || jsonb_build_array(jsonb_build_object(
      'main_ship_id', m.main_ship_id, 'player_id', m.player_id, 'hp', v_hp,
      'alive', v_alive, 'attack', v_attack, 'defense', v_defense,
      'shield_max', v_shield_max, 'shield_cur', v_shield_cur,
      'aggro_priority', v_aggro_priority,
      'pos_x', v_pos_x, 'pos_y', v_pos_y, 'move_speed', v_move_speed, 'weapons_json', v_weapons_json));
  end loop;

  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current,
    player_integrity_max, player_integrity_current, enemy_integrity_max, enemy_integrity_current,
    wave_number, last_resolved_at)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, 0, 0, 0, 0, 0, now())
  returning id into v_enc;

  -- COMBAT-S3 (0234): pos_x, pos_y, move_speed, weapons_json, side APPENDED to the existing column and
  -- SELECT lists — every pre-existing column/value is untouched (extract-and-diff proof: nothing
  -- before 'aggro_priority)' in the column list or before the aggro_priority cast in the SELECT list
  -- changed). side is always 'player' here (this function never writes an enemy row) — a literal, not
  -- roster-carried.
  insert into combat_units (
    encounter_id, player_id, unit_type_id, main_ship_id, attack_snapshot, defense_snapshot,
    ship_hp, initial_count, alive_count, hp_max, hp_current,
    shield_max, shield_current,
    aggro_priority,
    pos_x, pos_y, move_speed, weapons_json, side)
  select v_enc, (e->>'player_id')::uuid, null, (e->>'main_ship_id')::uuid,
         (e->>'attack')::double precision, (e->>'defense')::double precision,
         (e->>'hp')::double precision, 1, (e->>'alive')::integer,
         (e->>'hp')::double precision, (e->>'hp')::double precision,
         (e->>'shield_max')::double precision, (e->>'shield_cur')::double precision,
         (e->>'aggro_priority')::integer,
         (e->>'pos_x')::double precision, (e->>'pos_y')::double precision,
         (e->>'move_speed')::double precision, coalesce(e->'weapons_json', '[]'::jsonb), 'player'
  from jsonb_array_elements(v_roster) as e;

  select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;
  update combat_encounters set player_integrity_max = v_hull, player_integrity_current = v_hull where id = v_enc;

  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (v_enc, pr.player_id, 0, 0, 'wave_spawned', 'pirate', 'player', jsonb_build_object('wave', 1, 'danger', 1));
  return v_enc;
end;
$$;

-- ── SELF-ASSERTS — deploy-time; the migration proves its own grounding or refuses to land ───────────
-- The creator needs a live auth.users→main_ship_instances→group_sortie_members fixture chain that no
-- migration can build inside itself (the 0234 precedent), so the CREATOR is proven by prosrc/structural
-- token-pinning; the config values + the synthesized jsonb SHAPE are proven EXECUTABLY. The full
-- spawn→tick end-to-end scenario is scripts/combat-fallback-weapon-proof (CI disposable apply-proof).
do $$
declare
  v_creator text;
  v_probe   jsonb;
begin
  select prosrc into v_creator from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  if v_creator is null then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: combat_create_group_encounter is missing';
  end if;
  -- PROSRC-ASSERT COUPLING (the 0221/0222/0234 house lesson): strip `--` line comments before probing.
  v_creator := regexp_replace(v_creator, '--[^\n]*', '', 'g');

  -- (1) the 5 config keys are seeded with the exact chosen defaults.
  if coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_power_from_attack'), '') <> '1' then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: power_from_attack not seeded 1'; end if;
  if coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_range'), '') <> '150' then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: range not seeded 150'; end if;
  if coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_cooldown_seconds'), '') <> '2' then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: cooldown_seconds not seeded 2'; end if;
  if coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_projectile_speed'), '') <> '300' then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: projectile_speed not seeded 300'; end if;
  if coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_module_type_id'), '') <> 'basic_player_weapon' then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: module_type_id label not seeded basic_player_weapon'; end if;

  -- (2) the creator carries the fallback hunk: guarded on the EMPTY array (so armed ships are
  --     untouched) AND a positive attack, and derives power from attack_snapshot × the multiplier knob.
  if strpos(v_creator, 'if jsonb_array_length(v_weapons_json) = 0 and coalesce(v_attack, 0) > 0 then') = 0 then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: creator is missing the empty-array + positive-attack fallback guard';
  end if;
  if strpos(v_creator, 'v_attack * coalesce(public.cfg_num(''combat_player_fallback_weapon_power_from_attack''), 1)') = 0 then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: fallback power is not derived from attack_snapshot × the multiplier knob';
  end if;
  if strpos(v_creator, 'combat_player_fallback_weapon_range') = 0
     or strpos(v_creator, 'combat_player_fallback_weapon_projectile_speed') = 0
     or strpos(v_creator, 'combat_player_fallback_weapon_cooldown_seconds') = 0
     or strpos(v_creator, 'combat_player_fallback_weapon_module_type_id') = 0 then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: fallback weapon does not read the dedicated player-basic-weapon config knobs';
  end if;

  -- (3) the pre-existing fitting join survives verbatim (the fallback ONLY fills its empty result —
  --     it never replaces the real fitted-weapon path).
  if strpos(v_creator, 'where f.main_ship_id = m.main_ship_id and t.range is not null;') = 0 then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: creator lost the fitted-weapon range join (the real weapons path)';
  end if;
  -- the 0234 spatial INSERT column append survives (the whole spatial spawn is intact).
  if strpos(v_creator, 'pos_x, pos_y, move_speed, weapons_json, side)') = 0 then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: creator lost the 0234 spatial INSERT column append';
  end if;
  -- the fallback lives INSIDE the LIT-only spatial block (dark creation stays 0234 byte-parity): the
  -- hunk appears AFTER the `if v_spatial_enabled then` that opens the snapshot block.
  if strpos(v_creator, 'if v_spatial_enabled then') = 0
     or strpos(v_creator, 'if jsonb_array_length(v_weapons_json) = 0') < strpos(v_creator, 'v_move_speed := coalesce((v_stats->>''speed'')::double precision, 1);') then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: the fallback hunk is not inside the LIT-only spatial snapshot block';
  end if;

  -- (4) EXECUTABLE shape/values proof: build the synthesized entry with a stand-in attack of 42 and
  --     assert power = 42 × 1 and the dedicated range/projectile/cooldown/label land exactly (no live
  --     fixture needed — this is the same jsonb_build_object shape the creator uses).
  v_probe := jsonb_build_object(
    'module_type_id',   coalesce((select value #>> '{}' from public.game_config where key = 'combat_player_fallback_weapon_module_type_id'), 'basic_player_weapon'),
    'range',            coalesce(public.cfg_num('combat_player_fallback_weapon_range'), 150),
    'projectile_speed', coalesce(public.cfg_num('combat_player_fallback_weapon_projectile_speed'), 300),
    'power',            42 * coalesce(public.cfg_num('combat_player_fallback_weapon_power_from_attack'), 1),
    'ammo_type',        null,
    'ammo_per_shot',    0,
    'cooldown_seconds', coalesce(public.cfg_num('combat_player_fallback_weapon_cooldown_seconds'), 2),
    'next_ready_at',    null,
    'ammo_remaining',   null);
  if (v_probe->>'power')::numeric <> 42
     or (v_probe->>'range')::numeric <> 150
     or (v_probe->>'projectile_speed')::numeric <> 300
     or (v_probe->>'cooldown_seconds')::numeric <> 2
     or (v_probe->>'module_type_id') <> 'basic_player_weapon'
     or (v_probe->>'ammo_per_shot')::integer <> 0 then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: synthesized fallback weapon shape/values wrong: %', v_probe;
  end if;

  -- (5) ACL: the re-created engine function stays non-client-executable (unchanged 0234 posture).
  if has_function_privilege('authenticated', 'public.combat_create_group_encounter(uuid)', 'execute')
     or has_function_privilege('anon', 'public.combat_create_group_encounter(uuid)', 'execute') then
    raise exception 'COMBAT-FALLBACK self-assert FAIL: combat_create_group_encounter became client-executable';
  end if;

  raise notice 'COMBAT-FALLBACK self-assert ok: 5 combat_player_fallback_weapon_* config keys seeded (power_from_attack 1 / range 150 / cooldown 2 / projectile_speed 300 / label basic_player_weapon — distinct from the enemy synthetic); combat_create_group_encounter synthesizes ONE fallback weapon ONLY when the fitted-weapon array is EMPTY and attack_snapshot>0, deriving power from attack_snapshot × the multiplier knob, inside the LIT-only spatial block, with the fitted-weapon range join and the 0234 spatial INSERT append both intact; synthesized-entry shape/values proven executably (power=42 for attack 42, range 150, projectile 300, cooldown 2, label basic_player_weapon); ACL non-client-executable';
end $$;
