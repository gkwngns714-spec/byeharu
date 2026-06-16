-- Byeharu — M4: Reward system (sole writer of reward_grants).
--
-- reward_grant() is the ONLY path that applies rewards to a base. It is idempotent
-- via a unique (source_type, source_id): a given combat encounter can grant exactly
-- once, preventing duplicate-reward bugs even if a processor runs twice.

create table public.reward_grants (
  id          uuid primary key default gen_random_uuid(),
  source_type text not null,
  source_id   uuid not null,
  player_id   uuid not null references auth.users (id) on delete cascade,
  base_id     uuid references public.bases (id) on delete set null,
  rewards     jsonb not null default '{}'::jsonb,
  granted_at  timestamptz not null default now(),
  unique (source_type, source_id)
);

alter table public.reward_grants enable row level security;
create policy "reward_grants_select_own" on public.reward_grants
  for select using (player_id = auth.uid());
grant select on public.reward_grants to authenticated;

-- Grant rewards once for a source (e.g. a combat encounter). On first call it logs
-- the grant and applies the resources via Base.base_add_resources; subsequent calls
-- for the same source are no-ops.
create or replace function public.reward_grant(
  p_source_type text, p_source_id uuid, p_player uuid, p_base uuid, p_rewards jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_rewards is null or p_rewards = '{}'::jsonb then
    return;
  end if;

  insert into reward_grants (source_type, source_id, player_id, base_id, rewards)
    values (p_source_type, p_source_id, p_player, p_base, p_rewards)
    on conflict (source_type, source_id) do nothing;

  if found and p_base is not null then
    perform base_add_resources(p_base, p_rewards);
  end if;
end;
$$;
