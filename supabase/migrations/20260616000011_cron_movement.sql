-- Byeharu — M3b: schedule the movement processor.
--
-- pg_cron with sub-minute (seconds) scheduling (Supabase Postgres 15.1.1.61+).
-- Only the cron job calls the processor; clients never do. The processor itself is
-- idempotent + FOR UPDATE SKIP LOCKED, so overlapping ticks are safe.

create extension if not exists pg_cron;

-- Idempotent (re-runnable): drop any existing job of this name first.
do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname = 'process-fleet-movements';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;

select cron.schedule(
  'process-fleet-movements',
  '30 seconds',
  $$select public.process_fleet_movements();$$
);
