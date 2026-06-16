-- Byeharu — DEV-ONLY reset helper. NOT granted to clients (the re-lock below leaves
-- it callable only via the SQL editor / service role). Clears a test player's stuck
-- combat / movement / presence and frees their fleets. Does NOT touch base_units or
-- base_resources (avoids surprise data loss). Usage (SQL editor):
--   select public.dev_reset_player('<player-uuid>');

create or replace function public.dev_reset_player(p_player uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update combat_encounters set status = 'completed', ended_at = now(), updated_at = now()
    where player_id = p_player and status in ('active', 'retreating');
  update fleet_movements set status = 'cancelled', resolved_at = now()
    where player_id = p_player and status = 'moving';
  update location_presence set status = 'expired', updated_at = now()
    where player_id = p_player and status in ('active', 'retreating', 'leaving');
  update fleets set status = 'completed', location_mode = 'base', active_movement_id = null, updated_at = now()
    where player_id = p_player and status in ('moving', 'present', 'returning');
end;
$$;

-- Re-lock (a new function was added): revoke all, grant only the client RPCs.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
