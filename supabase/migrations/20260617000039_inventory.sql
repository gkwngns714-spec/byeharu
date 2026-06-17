-- Byeharu — Phase 3: generic item inventory foundation.
--
-- A clean, server-authoritative inventory for future item rewards / progression
-- materials. METAL IS UNTOUCHED — it stays in base_resources. A future
-- PendingRewardBundle deposits metal → base_resources (existing path) and items[] →
-- player_inventory (this path). No trading/mining/crafting/etc. here — just the store.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): item_types = Reference/Config (public read);
-- player_inventory + inventory_ledger = the Inventory system (owner-read, writes only
-- via SECURITY DEFINER functions). Frontend never mutates inventory.

-- ── item_types (Reference/Config; public read) ──────────────────────────────
create table public.item_types (
  item_id     text primary key,
  name        text not null,
  category    text not null,
  rarity      text not null default 'common',
  stackable   boolean not null default true,
  description text,
  icon_key    text,
  created_at  timestamptz not null default now()
);
alter table public.item_types enable row level security;
create policy "item_types_public_read" on public.item_types for select using (true);
grant select on public.item_types to anon, authenticated;

-- Small starter set only (NOT a full economy).
insert into public.item_types (item_id, name, category, rarity) values
  ('scrap',               'Scrap',                'material', 'common'),
  ('ore',                 'Ore',                  'material', 'common'),
  ('crystal',             'Crystal',              'material', 'uncommon'),
  ('pirate_alloy',        'Pirate Alloy',         'material', 'uncommon'),
  ('weapon_parts',        'Weapon Parts',         'component','uncommon'),
  ('engine_parts',        'Engine Parts',         'component','uncommon'),
  ('repair_parts',        'Repair Parts',         'component','common'),
  ('captain_memory_shard','Captain Memory Shard', 'progression','rare'),
  ('blueprint_fragment',  'Blueprint Fragment',   'progression','rare'),
  ('artifact_core',       'Artifact Core',        'progression','epic')
on conflict (item_id) do nothing;

-- ── player_inventory (Inventory-owned; owner-read; no client write) ──────────
create table public.player_inventory (
  player_id  uuid not null references auth.users (id) on delete cascade,
  item_id    text not null references public.item_types (item_id),
  quantity   integer not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now(),
  primary key (player_id, item_id)
);
alter table public.player_inventory enable row level security;
create policy "player_inventory_select_own" on public.player_inventory
  for select using (player_id = auth.uid());
grant select on public.player_inventory to authenticated;

-- ── inventory_ledger (audit + deposit idempotency) ──────────────────────────
create table public.inventory_ledger (
  id              bigint generated always as identity primary key,
  idempotency_key text unique,
  player_id       uuid not null references auth.users (id) on delete cascade,
  item_id         text not null references public.item_types (item_id),
  quantity_delta  integer not null,
  reason          text not null,
  source_type     text,
  source_id       uuid,
  created_at      timestamptz not null default now()
);
create index inventory_ledger_player_idx on public.inventory_ledger (player_id, created_at desc);
alter table public.inventory_ledger enable row level security;
create policy "inventory_ledger_select_own" on public.inventory_ledger
  for select using (player_id = auth.uid());
grant select on public.inventory_ledger to authenticated;

-- ── inventory_deposit: add items; idempotent when a key is provided ──────────
create or replace function public.inventory_deposit(p_player uuid, p_item text, p_qty integer, p_key text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_qty is null or p_qty <= 0 then raise exception 'inventory_deposit: invalid quantity %', p_qty; end if;
  if not exists (select 1 from item_types where item_id = p_item) then
    raise exception 'inventory_deposit: unknown item %', p_item;
  end if;

  -- Idempotency: the ledger insert is the guard. A duplicate key is a no-op.
  if p_key is not null then
    insert into inventory_ledger (idempotency_key, player_id, item_id, quantity_delta, reason)
      values (p_key, p_player, p_item, p_qty, 'deposit')
      on conflict (idempotency_key) do nothing;
    if not found then return; end if;  -- already applied
  else
    insert into inventory_ledger (player_id, item_id, quantity_delta, reason)
      values (p_player, p_item, p_qty, 'deposit');
  end if;

  insert into player_inventory (player_id, item_id, quantity)
    values (p_player, p_item, p_qty)
    on conflict (player_id, item_id)
    do update set quantity = player_inventory.quantity + excluded.quantity, updated_at = now();
end;
$$;

-- ── inventory_spend: subtract items transactionally; never negative ─────────
create or replace function public.inventory_spend(p_player uuid, p_item text, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_have integer;
begin
  if p_qty is null or p_qty <= 0 then raise exception 'inventory_spend: invalid quantity %', p_qty; end if;
  if not exists (select 1 from item_types where item_id = p_item) then
    raise exception 'inventory_spend: unknown item %', p_item;
  end if;
  select quantity into v_have from player_inventory
    where player_id = p_player and item_id = p_item for update;
  if v_have is null or v_have < p_qty then
    raise exception 'inventory_spend: insufficient % (have %, need %)', p_item, coalesce(v_have, 0), p_qty;
  end if;
  update player_inventory set quantity = quantity - p_qty, updated_at = now()
    where player_id = p_player and item_id = p_item;
  insert into inventory_ledger (player_id, item_id, quantity_delta, reason)
    values (p_player, p_item, -p_qty, 'spend');
end;
$$;

-- ── inventory_get_balance: safe read helper ─────────────────────────────────
create or replace function public.inventory_get_balance(p_player uuid, p_item text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select quantity from player_inventory where player_id = p_player and item_id = p_item), 0);
$$;

-- ── Re-lock execute surface (anti-cheat). Inventory writers are server-only. ─
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
-- Existing client RPCs (unchanged):
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
grant execute on function public.train_units(uuid, text, integer)          to authenticated;
grant execute on function public.cancel_build_order(uuid)                  to authenticated;
-- Server/cron + test-runner only (service_role); NEVER clients:
grant execute on function public.process_build_queue()                              to service_role;
grant execute on function public.inventory_deposit(uuid, text, integer, text)       to service_role;
grant execute on function public.inventory_spend(uuid, text, integer)               to service_role;
grant execute on function public.inventory_get_balance(uuid, text)                  to service_role;
