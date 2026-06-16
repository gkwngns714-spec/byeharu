-- Byeharu — M4: wire combat into Presence (Presence stays the owner of these fns).
-- activity_start now routes hunt_pirates → Combat. presence_request_leave gains the
-- combat retreat branch (start the retreat timer; the combat tick creates the
-- return after retreat_delay, preserving the risk window).

create or replace function public.activity_start(p_presence uuid, p_activity text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_activity = 'none' then
    return;  -- safe zone
  elsif p_activity = 'hunt_pirates' then
    perform combat_create_encounter(p_presence);
  else
    raise exception 'activity_start: unknown activity %', p_activity;
  end if;
end;
$$;

create or replace function public.presence_request_leave(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  p          location_presence%rowtype;
  v_base     record;
  v_loc      record;
  v_speed    double precision;
  v_movement uuid;
  v_enc      uuid;
begin
  select * into p from location_presence where id = p_presence for update;
  if not found then
    raise exception 'presence_request_leave: presence % not found', p_presence;
  end if;
  if p.status <> 'active' then
    raise exception 'presence_request_leave: presence % not active (is %)', p_presence, p.status;
  end if;

  if p.activity_type = 'none' then
    -- Safe zone: immediate leave + return home.
    select b.id, b.x, b.y into v_base
      from fleets f join bases b on b.id = f.origin_base_id where f.id = p.fleet_id;
    select x, y into v_loc from locations where id = p.location_id;
    v_speed := fleet_speed(p.fleet_id);
    perform presence_complete(p_presence);
    v_movement := movement_create(
      p.player_id, p.fleet_id,
      'location', null, p.zone_id, p.location_id, v_loc.x, v_loc.y,
      'base', v_base.id, null, null, v_base.x, v_base.y,
      'return_home', v_speed);
    perform fleet_set_returning(p.fleet_id, v_movement);
    return v_movement;

  elsif p.activity_type = 'hunt_pirates' then
    -- Combat retreat: arm the retreat timer; the combat tick handles the rest.
    select id into v_enc from combat_encounters where presence_id = p_presence and status = 'active';
    if v_enc is null then
      raise exception 'presence_request_leave: no active combat for presence %', p_presence;
    end if;
    update location_presence set status = 'retreating', retreat_requested_at = now(), updated_at = now()
      where id = p_presence;
    perform combat_set_retreating(v_enc);
    return null;  -- return movement is created later by process_combat_ticks()

  else
    raise exception 'presence_request_leave: unsupported activity %', p.activity_type;
  end if;
end;
$$;
