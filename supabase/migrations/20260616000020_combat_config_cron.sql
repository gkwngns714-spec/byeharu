-- Byeharu — M4: combat timing config + cron schedule.
-- Active-feeling combat: 2s tick, 20s retreat, 30-min forced auto-extract safety.

update public.game_config set value = '2',  updated_at = now() where key = 'combat_tick_seconds';
update public.game_config set value = '20', updated_at = now() where key = 'retreat_delay_seconds';

insert into public.game_config (key, value, description) values
  ('max_presence_seconds_default', '1800', 'forced auto-extract safety cap (30 min) if no per-location override'),
  ('reward_metal_base',            '10',   'base metal per cleared wave before tier/danger scaling')
on conflict (key) do nothing;

-- Schedule the combat processor every 2 seconds (idempotent).
select cron.unschedule(jobid) from cron.job where jobname = 'process-combat-ticks';
select cron.schedule('process-combat-ticks', '2 seconds', $$select public.process_combat_ticks();$$);
