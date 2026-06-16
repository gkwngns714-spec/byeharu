-- Byeharu — M3a: Base system.
--
-- OWNERSHIP (docs/SYSTEM_BOUNDARIES.md): the Base system is the SOLE writer of
-- bases / base_units / base_resources. Other systems mutate them only through the
-- functions exposed here (reserve / merge / [add_resources in M4]). Clients never
-- write these tables — RLS grants owner SELECT only; all writes go through
-- SECURITY DEFINER functions.

-- ── tables ───────────────────────────────────────────────────────────────────
create table public.bases (
  id         uuid primary key default gen_random_uuid(),
  player_id  uuid not null references auth.users (id) on delete cascade,
  name       text not null default 'Home Base',
  sector_id  uuid references public.sectors (id),
  x          double precision not null default 0,
  y          double precision not null default 0,
  status     text not null default 'active' check (status in ('active', 'destroyed')),
  created_at timestamptz not null default now()
);
create index bases_player_id_idx on public.bases (player_id);

create table public.base_units (
  id           uuid primary key default gen_random_uuid(),
  base_id      uuid not null references public.bases (id) on delete cascade,
  unit_type_id text not null references public.unit_types (id),
  quantity     integer not null default 0 check (quantity >= 0),
  updated_at   timestamptz not null default now(),
  unique (base_id, unit_type_id)
);

create table public.base_resources (
  id            uuid primary key default gen_random_uuid(),
  base_id       uuid not null references public.bases (id) on delete cascade,
  resource_code text not null,
  amount        double precision not null default 0 check (amount >= 0),
  updated_at    timestamptz not null default now(),
  unique (base_id, resource_code)
);

-- ── RLS: owner-read only, no client writes ───────────────────────────────────
alter table public.bases          enable row level security;
alter table public.base_units     enable row level security;
alter table public.base_resources enable row level security;

create policy "bases_select_own" on public.bases
  for select using (player_id = auth.uid());

create policy "base_units_select_own" on public.base_units
  for select using (exists (
    select 1 from public.bases b where b.id = base_units.base_id and b.player_id = auth.uid()
  ));

create policy "base_resources_select_own" on public.base_resources
  for select using (exists (
    select 1 from public.bases b where b.id = base_resources.base_id and b.player_id = auth.uid()
  ));

grant select on public.bases, public.base_units, public.base_resources to authenticated;

-- ── Base system functions (SECURITY DEFINER; the only writers) ────────────────

-- Subtract units from a base. Validates positive quantities and availability.
-- p_units: [{"unit_type_id":"scout","quantity":10}, ...]
create or replace function public.base_reserve_units(p_base uuid, p_units jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  item   jsonb;
  v_code text;
  v_qty  integer;
  v_have integer;
begin
  for item in select * from jsonb_array_elements(p_units) loop
    v_code := item->>'unit_type_id';
    v_qty  := (item->>'quantity')::integer;
    if v_qty is null or v_qty <= 0 then
      raise exception 'base_reserve_units: invalid quantity for %', v_code;
    end if;
    select quantity into v_have
      from base_units
      where base_id = p_base and unit_type_id = v_code
      for update;
    if v_have is null or v_have < v_qty then
      raise exception 'base_reserve_units: insufficient % (have %, need %)',
        v_code, coalesce(v_have, 0), v_qty;
    end if;
    update base_units
      set quantity = quantity - v_qty, updated_at = now()
      where base_id = p_base and unit_type_id = v_code;
  end loop;
end;
$$;

-- Add units back to a base (e.g. survivors returning home). Upsert.
create or replace function public.base_merge_units(p_base uuid, p_units jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  item   jsonb;
  v_code text;
  v_qty  integer;
begin
  for item in select * from jsonb_array_elements(p_units) loop
    v_code := item->>'unit_type_id';
    v_qty  := (item->>'quantity')::integer;
    if v_qty is null or v_qty <= 0 then
      continue;
    end if;
    insert into base_units (base_id, unit_type_id, quantity)
      values (p_base, v_code, v_qty)
      on conflict (base_id, unit_type_id)
      do update set quantity = base_units.quantity + excluded.quantity, updated_at = now();
  end loop;
end;
$$;

-- Create a starter base + seed units/resources for a player. Idempotent.
create or replace function public.initialize_new_player(p_player uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base   uuid;
  v_sector uuid;
begin
  if exists (select 1 from bases where player_id = p_player) then
    return;
  end if;

  select id into v_sector from sectors where sector_index = 1;  -- Outer Haven

  insert into bases (player_id, name, sector_id, x, y)
    values (p_player, 'Home Base', v_sector, 0, 0)
    returning id into v_base;

  insert into base_units (base_id, unit_type_id, quantity) values
    (v_base, 'scout', 100),
    (v_base, 'corvette', 20),
    (v_base, 'frigate', 5)
  on conflict (base_id, unit_type_id) do nothing;

  insert into base_resources (base_id, resource_code, amount) values
    (v_base, 'metal', 0),
    (v_base, 'crystal', 0),
    (v_base, 'energy', 0)
  on conflict (base_id, resource_code) do nothing;
end;
$$;

-- Client-callable safety net so a logged-in player can ensure their base exists.
create or replace function public.bootstrap_me()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'bootstrap_me: not authenticated';
  end if;
  perform public.initialize_new_player(auth.uid());
end;
$$;

grant execute on function public.bootstrap_me() to authenticated;

-- ── Auto-bootstrap on signup (Base system's own trigger, separate from Auth's) ─
create or replace function public.handle_new_user_base()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.initialize_new_player(new.id);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_base on auth.users;
create trigger on_auth_user_created_base
  after insert on auth.users
  for each row execute function public.handle_new_user_base();

-- ── Backfill existing users (e.g. the M2 test account) ────────────────────────
do $$
declare
  u record;
begin
  for u in select id from auth.users loop
    perform public.initialize_new_player(u.id);
  end loop;
end;
$$;
