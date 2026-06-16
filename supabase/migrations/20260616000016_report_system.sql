-- Byeharu — M4: Report system (sole writer of combat_reports).
--
-- Reports are HISTORY ONLY and never drive game logic. report_create() is
-- idempotent (one report per encounter). get_combat_reports() is a client read RPC.

create table public.combat_reports (
  id                 uuid primary key default gen_random_uuid(),
  encounter_id       uuid not null references public.combat_encounters (id) on delete cascade unique,
  player_id          uuid not null references auth.users (id) on delete cascade,
  fleet_id           uuid,
  location_id        uuid references public.locations (id),
  result             text not null,
  waves_cleared      integer not null default 0,
  duration_seconds   integer not null default 0,
  total_losses_json  jsonb not null default '{}'::jsonb,
  total_rewards_json jsonb not null default '{}'::jsonb,
  summary_text       text,
  created_at         timestamptz not null default now()
);
create index combat_reports_player_idx on public.combat_reports (player_id, created_at desc);

alter table public.combat_reports enable row level security;
create policy "combat_reports_select_own" on public.combat_reports
  for select using (player_id = auth.uid());
grant select on public.combat_reports to authenticated;

-- Build the final report from the encounter + its ticks. Idempotent.
create or replace function public.report_create(p_encounter uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  e        combat_encounters%rowtype;
  v_id     uuid;
  v_losses jsonb;
  v_dur    integer;
begin
  select * into e from combat_encounters where id = p_encounter;
  if not found then
    raise exception 'report_create: encounter % not found', p_encounter;
  end if;
  if exists (select 1 from combat_reports where encounter_id = p_encounter) then
    return null;  -- already created
  end if;

  -- Aggregate total player losses across all ticks of this encounter.
  select coalesce(
           jsonb_object_agg(k, v),
           '{}'::jsonb)
    into v_losses
    from (
      select key as k, sum((value #>> '{}')::numeric) as v
      from combat_ticks t, jsonb_each(t.player_losses_json)
      where t.encounter_id = p_encounter
      group by key
    ) agg;

  v_dur := greatest(0, extract(epoch from (coalesce(e.ended_at, now()) - e.started_at))::integer);

  insert into combat_reports (
    encounter_id, player_id, fleet_id, location_id, result, waves_cleared,
    duration_seconds, total_losses_json, total_rewards_json, summary_text)
  values (
    e.id, e.player_id, e.fleet_id, e.location_id, e.status, e.waves_cleared,
    v_dur, coalesce(v_losses, '{}'::jsonb), e.total_rewards_json,
    format('%s after %s wave(s) over %ss', e.status, e.waves_cleared, v_dur))
  on conflict (encounter_id) do nothing
  returning id into v_id;

  update combat_encounters set report_created_at = now() where id = p_encounter;
  return v_id;
end;
$$;

-- Client read: a player's combat history (most recent first).
create or replace function public.get_combat_reports()
returns setof public.combat_reports
language sql
stable
security definer
set search_path = public
as $$
  select * from combat_reports where player_id = auth.uid() order by created_at desc limit 50;
$$;
