-- Byeharu — M7: schedule the training-queue processor.
--
-- ACYCLIC: process_build_queue completes training orders via Base functions only;
-- it never calls Combat / World State / Movement. Cron cadence summary:
--   movement   : 30s
--   combat     :  2s
--   worldstate : 60s
--   training   : 30s  ← this file

create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname = 'process-build-queue';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;

select cron.schedule(
  'process-build-queue',
  '30 seconds',
  $$select public.process_build_queue();$$
);
