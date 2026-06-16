-- Byeharu — M4 combat overhaul: readable pacing, decoupled wave HP vs damage,
-- per-unit-type combat HP with server-side damage distribution, carryover, and a
-- richer event feed. Server stays authoritative; client only renders.
--
-- Root cause of "instant waves": wave HP and wave damage were the same value, so a
-- 385-attack fleet one-shot a 195-HP wave. Now:
--   wave HP    = base_difficulty * enemy_hp_base * (1 + danger*enemy_hp_danger_scale)
--   wave attack= base_difficulty * enemy_attack_base * (1 + danger*enemy_attack_danger_scale)
-- HP is large (multi-tick); attack stays modest and scales separately with danger.

-- ── config: slower tick + decoupled scaling knobs ────────────────────────────
update public.game_config set value = '4', updated_at = now() where key = 'combat_tick_seconds';
insert into public.game_config (key, value, description) values
  ('enemy_hp_base',             '6',   'wave HP coefficient (x base_difficulty)'),
  ('enemy_hp_danger_scale',     '0.6', 'wave HP growth per danger level'),
  ('enemy_attack_base',         '1.0', 'wave per-tick attack coefficient (x base_difficulty)'),
  ('enemy_attack_danger_scale', '0.25','wave attack growth per danger level'),
  ('wave_transition_seconds',   '3',   'pause between a cleared wave and the next')
on conflict (key) do nothing;

-- ── encounter: wave bookkeeping ──────────────────────────────────────────────
alter table public.combat_encounters
  add column if not exists wave_number  integer not null default 0,
  add column if not exists next_wave_at timestamptz;

-- ── ticks: debug snapshot + wave number ──────────────────────────────────────
alter table public.combat_ticks
  add column if not exists wave_number       integer not null default 0,
  add column if not exists unit_snapshot_json jsonb not null default '{}'::jsonb;

-- ── combat_units: per-unit-type combat HP state (Combat system, sole writer) ──
create table if not exists public.combat_units (
  id            uuid primary key default gen_random_uuid(),
  encounter_id  uuid not null references public.combat_encounters (id) on delete cascade,
  player_id     uuid not null,
  unit_type_id  text not null references public.unit_types (id),
  ship_hp       double precision not null,
  initial_count integer not null,
  alive_count   integer not null,
  hp_max        double precision not null,   -- initial_count * ship_hp (fixed)
  hp_current    double precision not null,   -- carries damage across waves
  updated_at    timestamptz not null default now(),
  unique (encounter_id, unit_type_id)
);
create index if not exists combat_units_encounter_idx on public.combat_units (encounter_id);

alter table public.combat_units enable row level security;
create policy "combat_units_select_own" on public.combat_units
  for select using (player_id = auth.uid());
grant select on public.combat_units to authenticated;

-- ── Fleet function: sync alive counts from combat (Fleet stays sole writer) ───
create or replace function public.fleet_sync_quantities(p_fleet uuid, p_counts jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r record;
begin
  for r in select key, value from jsonb_each(p_counts) loop
    update fleet_units set quantity = greatest(0, (r.value #>> '{}')::integer), updated_at = now()
      where fleet_id = p_fleet and unit_type_id = r.key;
  end loop;
end;
$$;

-- ── combat_create_encounter: snapshot per-unit combat HP ─────────────────────
create or replace function public.combat_create_encounter(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pr      location_presence%rowtype;
  v_power double precision;
  v_hull  double precision;
  v_enc   uuid;
begin
  select * into pr from location_presence where id = p_presence;
  if not found then
    raise exception 'combat_create_encounter: presence % not found', p_presence;
  end if;
  v_power := fleet_get_power(pr.fleet_id);

  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current,
    player_integrity_max, player_integrity_current, enemy_integrity_max, enemy_integrity_current,
    wave_number, last_resolved_at)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, 0, 0, 0, 0, 0, now())
  returning id into v_enc;

  -- Per-unit combat state from the fleet's composition.
  insert into combat_units (encounter_id, player_id, unit_type_id, ship_hp, initial_count, alive_count, hp_max, hp_current)
  select v_enc, pr.player_id, fu.unit_type_id, ut.hull, fu.quantity, fu.quantity, fu.quantity * ut.hull, fu.quantity * ut.hull
  from fleet_units fu join unit_types ut on ut.id = fu.unit_type_id
  where fu.fleet_id = pr.fleet_id and fu.quantity > 0;

  select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;
  update combat_encounters set player_integrity_max = v_hull, player_integrity_current = v_hull where id = v_enc;

  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (v_enc, pr.player_id, 0, 0, 'wave_spawned', 'pirate', 'player', jsonb_build_object('wave', 1, 'danger', 1));
  return v_enc;
end;
$$;

-- ── process_combat_ticks: the readable, per-unit, decoupled model ────────────
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
begin
  v_tick_secs     := coalesce(cfg_num('combat_tick_seconds'), 4);
  v_retreat_delay := coalesce(cfg_num('retreat_delay_seconds'), 20);
  v_trans_secs    := coalesce(cfg_num('wave_transition_seconds'), 3);

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
    v_tick := e.tick_number + 1;
    select * into pr from location_presence where id = e.presence_id;
    select base_difficulty, reward_tier, max_presence_seconds into loc from locations where id = e.location_id;

    -- Current fleet aggregate from per-unit combat state.
    select coalesce(sum(ut.attack * cu2.alive_count), 0),
           coalesce(sum(ut.defense * cu2.alive_count), 0),
           coalesce(sum(cu2.hp_current), 0),
           coalesce(sum(cu2.alive_count), 0)
      into v_attack, v_defense, v_hp_total, v_alive_total
      from combat_units cu2 join unit_types ut on ut.id = cu2.unit_type_id
      where cu2.encounter_id = e.id;

    -- (A) Already destroyed → defeat, NO rewards.
    if v_hp_total <= 0 or v_alive_total <= 0 then
      perform fleet_destroy(e.fleet_id);
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), player_integrity_current=0, player_power_current=0,
             total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
      insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
             player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
        values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, 0, 0,
                e.enemy_integrity_current, e.enemy_integrity_current, 'defeat');
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, 0, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      perform report_create(e.id);
      v_count := v_count + 1; continue;
    end if;

    -- (B) End: retreat delay elapsed or forced auto-extract → grant locked rewards.
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
      v_speed := fleet_speed(e.fleet_id);
      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform reward_grant('combat', e.id, e.player_id, v_base_id, e.total_rewards_json);
      perform presence_complete(e.presence_id);
      v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
                              'base', v_base_id, null, null, v_base_x, v_base_y, 'return_home', v_speed);
      perform fleet_set_returning(e.fleet_id, v_mv);
      insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
             player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, reward_delta_json, result)
        values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, v_hp_total, v_hp_total,
                e.enemy_integrity_current, e.enemy_integrity_current, e.total_rewards_json, v_end);
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, 0, 'retreat_completed', 'player', 'player', jsonb_build_object('forced', v_forced));
      v_count := v_count + 1; continue;
    end if;

    -- (C) Combat step.
    v_danger       := 1 + e.waves_cleared + floor(v_secs_inside / 180)::integer;
    v_variance     := 0.9 + random() * 0.2;
    v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                      * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
    v_seq          := 0;
    v_offense      := (e.status = 'active');
    v_wave_num     := e.wave_number;

    -- Wave lifecycle: spawn if none and not mid-transition.
    if e.enemy_integrity_current <= 0 then
      if e.next_wave_at is not null and now() < e.next_wave_at then
        -- next wave incoming: pause; pirates regroup (no damage this tick).
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
          values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
        update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
        v_count := v_count + 1; continue;
      end if;
      -- spawn
      v_wave_num := e.waves_cleared + 1;
      v_enemy_hp := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),6)
                    * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
      v_e_before := v_enemy_hp;
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp)));
      v_seq := v_seq + 1;
    else
      v_enemy_hp := e.enemy_integrity_max;
      v_e_before := e.enemy_integrity_current;
    end if;

    -- Player offense (active only).
    if v_offense then
      v_player_damage := v_attack * v_variance;
      v_e_after := v_e_before - v_player_damage;
      v_cleared := v_e_after <= 0;
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'missile_salvo', 'player', 'pirate', 'missile', greatest(1, round(v_attack/50)::integer), 400,
                jsonb_build_object('damage', round(v_player_damage), 'wave', v_wave_num));
      v_seq := v_seq + 1;
    else
      v_player_damage := 0; v_e_after := v_e_before; v_cleared := false;
    end if;

    -- Pirates fire → mitigated total, distributed across unit groups by ship count.
    insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms)
      values (e.id, e.player_id, v_tick, v_seq, 'laser_burst', 'pirate', 'player', 'laser', greatest(1, v_danger), 600);
    v_seq := v_seq + 1;
    v_final_player := v_enemy_attack * 100.0 / (100.0 + v_defense) * v_variance;

    v_losses := '{}'::jsonb; v_counts := '{}'::jsonb; v_snapshot := '{}'::jsonb;
    for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 loop
      v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
      v_new_hp    := cu.hp_current - v_d_group;
      v_new_alive := greatest(0, least(cu.alive_count, ceil(v_new_hp / cu.ship_hp)::integer));
      v_destroyed := cu.alive_count - v_new_alive;
      update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive, updated_at = now()
        where id = cu.id;
      v_counts   := v_counts   || jsonb_build_object(cu.unit_type_id, v_new_alive);
      v_snapshot := v_snapshot || jsonb_build_object(cu.unit_type_id,
                       jsonb_build_object('alive', v_new_alive, 'hp', round(greatest(0, v_new_hp))));
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'hull_damage', 'pirate', 'player',
                jsonb_build_object('group', cu.unit_type_id, 'damage', round(v_d_group)));
      v_seq := v_seq + 1;
      if v_destroyed > 0 then
        v_losses := v_losses || jsonb_build_object(cu.unit_type_id, v_destroyed);
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed', 'pirate', 'player',
                  jsonb_build_object('group', cu.unit_type_id, 'count', v_destroyed));
        v_seq := v_seq + 1;
      end if;
    end loop;

    -- Sync surviving counts back to the Fleet system.
    perform fleet_sync_quantities(e.fleet_id, v_counts);
    select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id;

    -- Reward only on an actively cleared wave.
    v_reward_metal := 0; v_reward_delta := '{}'::jsonb;
    if v_cleared and v_offense then
      v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                              * (1 + 0.25 * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
      v_reward_delta := jsonb_build_object('metal', v_reward_metal);
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal));
      v_seq := v_seq + 1;
    end if;

    insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
           player_power_before, enemy_power, player_damage, enemy_damage,
           player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after,
           player_losses_json, reward_delta_json, unit_snapshot_json, result)
      values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
              v_hp_total, v_e_before, v_player_damage, v_final_player,
              v_hp_total, greatest(0, v_hp_after), v_e_before, greatest(0, v_e_after),
              v_losses, v_reward_delta, v_snapshot,
              case when v_cleared then 'wave_cleared' else 'ongoing' end);

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
                                   then total_rewards_json || jsonb_build_object(
                                          'metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                   else total_rewards_json end,
      last_resolved_at         = now(),
      updated_at               = now()
    where id = e.id;

    -- Wiped this tick → defeat, NO rewards.
    if v_hp_after <= 0 then
      perform fleet_destroy(e.fleet_id);
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
        values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      perform report_create(e.id);
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Re-schedule the combat cron at the new 4s cadence (idempotent).
select cron.unschedule(jobid) from cron.job where jobname = 'process-combat-ticks';
select cron.schedule('process-combat-ticks', '4 seconds', $$select public.process_combat_ticks();$$);
