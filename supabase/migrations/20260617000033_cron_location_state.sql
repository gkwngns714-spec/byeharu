-- Byeharu — M5: World State cron (60s living-world heartbeat).
--
-- ACYCLIC: process_location_state_ticks() orchestrates World State ONLY. It never
-- calls combat / fleet / reward / report / movement processors (Absolute Law §5).
-- Cron cadence summary across the game:
--   movement   : 30s  (process_fleet_movements)
--   combat     :  2s  (process_combat_ticks)
--   worldstate : 60s  (process_location_state_ticks)  ← this file

create or replace function public.process_location_state_ticks()
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  return worldstate_tick();
end;
$$;

-- Lock to server/cron. Granted to service_role for the integration test runner;
-- never to clients.
revoke execute on function public.process_location_state_ticks() from public, anon, authenticated;
grant execute on function public.process_location_state_ticks() to service_role;

-- ── Schedule every 60 seconds (idempotent re-run) ────────────────────────────
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname = 'process-location-state-ticks';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;

select cron.schedule(
  'process-location-state-ticks',
  '60 seconds',
  $$select public.process_location_state_ticks();$$
);
