-- Byeharu — M7: Training / Production system (server-authoritative ship training).
--
-- OWNERSHIP (docs/SYSTEM_BOUNDARIES.md): the Production system is the SOLE writer of
-- build_orders. It NEVER writes base_units/base_resources directly — it spends metal
-- via Base.base_spend_resources and deposits finished ships via Base.base_merge_units.
-- Base stays the sole writer of base_units/base_resources. Acyclic: Production → Base.
--
-- FLOW
--   client → train_units (RPC) → validate auth/ownership/unit/qty/metal/queue-cap
--          → Base.base_spend_resources (debit metal up-front)
--          → Production.production_create_order (insert queued build_order)
--   cron   → process_build_queue → lock due orders FOR UPDATE SKIP LOCKED
--          → Base.base_merge_units (add ships) → Production.production_complete_order
--
-- Metal paid up-front; whole order completes atomically; no cancel/refund in M7.

-- ── build_orders: the training queue (Production-owned) ──────────────────────
create table public.build_orders (
  id            uuid primary key default gen_random_uuid(),
  player_id     uuid not null references auth.users (id) on delete cascade,
  base_id       uuid not null references public.bases (id) on delete cascade,
  unit_type_id  text not null references public.unit_types (id),
  quantity      integer not null check (quantity > 0),
  metal_spent   double precision not null default 0 check (metal_spent >= 0),
  status        text not null default 'queued' check (status in ('queued','completed','cancelled')),
  queued_at     timestamptz not null default now(),
  complete_at   timestamptz not null,
  resolved_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (complete_at >= queued_at)
);
create index build_orders_player_idx on public.build_orders (player_id, status);
create index build_orders_due_idx on public.build_orders (complete_at) where status = 'queued';

-- RLS: owner-read only; NO client writes (writes go through SECURITY DEFINER fns).
alter table public.build_orders enable row level security;
create policy "build_orders_select_own" on public.build_orders
  for select using (player_id = auth.uid());
grant select on public.build_orders to authenticated;

-- ── Base system: spend a resource (sole writer of base_resources) ────────────
-- Validates availability and debits. Mirror of base_reserve_units for resources.
create or replace function public.base_spend_resources(p_base uuid, p_resource text, p_amount double precision)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_have double precision;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'base_spend_resources: invalid amount %', p_amount;
  end if;
  select amount into v_have from base_resources
    where base_id = p_base and resource_code = p_resource for update;
  if v_have is null or v_have < p_amount then
    raise exception 'base_spend_resources: insufficient % (have %, need %)',
      p_resource, coalesce(v_have, 0), p_amount;
  end if;
  update base_resources set amount = amount - p_amount, updated_at = now()
    where base_id = p_base and resource_code = p_resource;
end;
$$;

-- ── Production system: create / complete an order (sole writer of build_orders) ─
create or replace function public.production_create_order(
  p_player uuid, p_base uuid, p_unit_type text, p_quantity integer, p_metal double precision, p_complete timestamptz)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into build_orders (player_id, base_id, unit_type_id, quantity, metal_spent, status, queued_at, complete_at)
    values (p_player, p_base, p_unit_type, p_quantity, p_metal, 'queued', now(), p_complete)
    returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.production_complete_order(p_order uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Only flips queued → completed, so a re-run can never double-complete.
  update build_orders set status = 'completed', resolved_at = now(), updated_at = now()
    where id = p_order and status = 'queued';
end;
$$;

-- ── Player RPC: start a training order ───────────────────────────────────────
create or replace function public.train_units(p_base uuid, p_unit_type text, p_quantity integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_owns     boolean;
  v_cost     integer;
  v_bsecs    integer;
  v_secs     double precision;
  v_active   integer;
  v_max      integer := coalesce(cfg_num('max_build_orders'), 5)::integer;
  v_complete timestamptz;
  v_order    uuid;
begin
  if v_player is null then raise exception 'train_units: not authenticated'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'train_units: invalid quantity %', p_quantity; end if;

  -- ownership of the base
  select exists (select 1 from bases where id = p_base and player_id = v_player) into v_owns;
  if not v_owns then raise exception 'train_units: base % not owned by caller', p_base; end if;

  -- unit must exist + be active; read its cost + build time
  select metal_cost, build_time_seconds into v_cost, v_bsecs
    from unit_types where id = p_unit_type and status = 'active';
  if v_cost is null then raise exception 'train_units: unknown or inactive unit %', p_unit_type; end if;

  -- queue cap (independent concurrent orders)
  select count(*) into v_active from build_orders where player_id = v_player and status = 'queued';
  if v_active >= v_max then raise exception 'train_units: training queue full (max %)', v_max; end if;

  -- cost + time
  v_secs := greatest(
    coalesce(cfg_num('min_build_seconds'), 5),
    v_bsecs * p_quantity * coalesce(cfg_num('build_time_scale'), 1.0));
  v_complete := now() + make_interval(secs => v_secs);

  -- spend metal (Base), then create the order (Production). If the spend raises
  -- (insufficient metal), the whole RPC rolls back — no order, no debit.
  perform base_spend_resources(p_base, 'metal', (v_cost * p_quantity)::double precision);
  v_order := production_create_order(v_player, p_base, p_unit_type, p_quantity, (v_cost * p_quantity)::double precision, v_complete);
  return v_order;
end;
$$;

-- ── Cron processor: complete due orders ──────────────────────────────────────
-- Idempotent + concurrency-safe: FOR UPDATE SKIP LOCKED on queued+due rows, and
-- production_complete_order only flips queued→completed, so ships are never
-- double-added and orders never double-completed.
create or replace function public.process_build_queue()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  o       build_orders%rowtype;
  v_count integer := 0;
begin
  for o in
    select * from build_orders
    where status = 'queued' and complete_at <= now()
    for update skip locked
  loop
    perform base_merge_units(o.base_id,
      jsonb_build_array(jsonb_build_object('unit_type_id', o.unit_type_id, 'quantity', o.quantity)));
    perform production_complete_order(o.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ── Re-lock execute surface (anti-cheat). New functions were added. ──────────
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
-- Existing client RPCs (unchanged) + the new train_units:
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
grant execute on function public.train_units(uuid, text, integer)          to authenticated;
-- Server/cron only (test runner via service_role); never clients:
grant execute on function public.process_build_queue()                     to service_role;
