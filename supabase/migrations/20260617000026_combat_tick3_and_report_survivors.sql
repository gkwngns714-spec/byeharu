-- Byeharu — M4 clarity pass (backend bits): fixed 3s combat tick + per-unit
-- survivors in the report so the post-retreat summary is server-authoritative.
-- (Damage keeps a small ±10% variance; the TICK INTERVAL is fixed, not random.)

update public.game_config set value = '3', updated_at = now() where key = 'combat_tick_seconds';
select cron.unschedule(jobid) from cron.job where jobname = 'process-combat-ticks';
select cron.schedule('process-combat-ticks', '3 seconds', $$select public.process_combat_ticks();$$);

alter table public.combat_reports
  add column if not exists survivors_json jsonb not null default '{}'::jsonb;

-- Rebuild the report from per-unit combat state: exact survivors + losses.
create or replace function public.report_create(p_encounter uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  e          combat_encounters%rowtype;
  v_id       uuid;
  v_survivors jsonb;
  v_losses    jsonb;
  v_dur      integer;
begin
  select * into e from combat_encounters where id = p_encounter;
  if not found then
    raise exception 'report_create: encounter % not found', p_encounter;
  end if;
  if exists (select 1 from combat_reports where encounter_id = p_encounter) then
    return null;
  end if;

  select
    coalesce(jsonb_object_agg(unit_type_id, alive_count) filter (where alive_count > 0), '{}'::jsonb),
    coalesce(jsonb_object_agg(unit_type_id, initial_count - alive_count) filter (where initial_count - alive_count > 0), '{}'::jsonb)
    into v_survivors, v_losses
    from combat_units where encounter_id = p_encounter;

  v_dur := greatest(0, extract(epoch from (coalesce(e.ended_at, now()) - e.started_at))::integer);

  insert into combat_reports (
    encounter_id, player_id, fleet_id, location_id, result, waves_cleared,
    duration_seconds, total_losses_json, total_rewards_json, survivors_json, summary_text)
  values (
    e.id, e.player_id, e.fleet_id, e.location_id, e.status, e.waves_cleared,
    v_dur, coalesce(v_losses, '{}'::jsonb), e.total_rewards_json, coalesce(v_survivors, '{}'::jsonb),
    format('%s after %s wave(s) over %ss', e.status, e.waves_cleared, v_dur))
  on conflict (encounter_id) do nothing
  returning id into v_id;

  update combat_encounters set report_created_at = now() where id = p_encounter;
  return v_id;
end;
$$;
