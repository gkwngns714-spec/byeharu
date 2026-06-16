-- Byeharu — M3b: Movement processor.
--
-- OWNERSHIP: part of the Movement system (writes only fleet_movements). On arrival
-- it hands off via other systems' functions — it never writes their tables:
--   outbound (→ location): Fleet.set_present + Presence.create (which starts activity)
--   return  (→ base):      Base.merge_units + Fleet.complete
--
-- IDEMPOTENT & CONCURRENCY-SAFE: selects only status='moving' due rows with
-- FOR UPDATE SKIP LOCKED and flips status to 'arrived' in the same transaction, so
-- overlapping cron runs can't double-resolve, double-merge, or double-create.

create or replace function public.process_fleet_movements()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  m         record;
  v_loc     record;
  v_units   jsonb;
  v_count   integer := 0;
begin
  for m in
    select * from fleet_movements
    where status = 'moving' and arrive_at <= now()
    for update skip locked
  loop
    if m.target_type = 'location' then
      -- Outbound arrival → become present and start the location's activity.
      select l.activity_type as activity, l.zone_id as zone_id, z.sector_id as sector_id
        into v_loc
        from locations l join zones z on z.id = l.zone_id
        where l.id = m.target_location_id;

      update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;

      perform fleet_set_present(m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id);
      perform presence_create(m.player_id, m.fleet_id, v_loc.sector_id, v_loc.zone_id,
                              m.target_location_id, v_loc.activity);

    elsif m.target_type = 'base' then
      -- Return arrival → merge survivors back to base, complete the fleet.
      select jsonb_agg(jsonb_build_object('unit_type_id', unit_type_id, 'quantity', quantity))
        into v_units
        from fleet_units
        where fleet_id = m.fleet_id and quantity > 0;

      update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;

      if v_units is not null then
        perform base_merge_units(m.target_base_id, v_units);
      end if;
      perform fleet_complete(m.fleet_id);

    else
      -- Unknown target — mark failed rather than loop forever.
      update fleet_movements set status = 'failed', resolved_at = now() where id = m.id;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
