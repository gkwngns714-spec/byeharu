-- Byeharu — M4.5: production queue law fix (serial training + cancellation).
--
-- BUG: M7's train_units gave EVERY order a complete_at immediately, so all orders
-- "ticked down" in parallel. New law: ONE active slot. Only the active item has
-- started_at + completes_at; waiting items have NULL complete_at and do not progress.
-- When the active item completes, the next waiting item starts. Players can cancel.
--
-- SCOPE: Production system only. Combat/movement/world-state/reward untouched.
-- Absolute timestamps (started_at / complete_at); no per-tick decrement.

-- ── Config: one active production slot (designed to become N later) ──────────
insert into public.game_config (key, value, description) values
  ('max_active_ship_production_slots', '1', 'how many training orders may be ACTIVE (building) at once per player')
on conflict (key) do nothing;

-- ── Schema: states + nullable complete_at + started_at ──────────────────────
-- Clear any leftover M7 'queued' rows (test artifacts) into the new model.
update public.build_orders set status = 'cancelled', resolved_at = now(), updated_at = now() where status = 'queued';

alter table public.build_orders alter column complete_at drop not null;
alter table public.build_orders alter column status set default 'waiting';
alter table public.build_orders add column if not exists started_at timestamptz;
alter table public.build_orders drop constraint if exists build_orders_status_check;
alter table public.build_orders drop constraint if exists build_orders_check;
alter table public.build_orders
  add constraint build_orders_status_check check (status in ('waiting','active','completed','cancelled')),
  add constraint build_orders_complete_after_queue check (complete_at is null or complete_at >= queued_at);

-- ── production_start_next: promote oldest waiting → active while a slot is free ─
-- Activation stamps started_at = now and complete_at = now + duration (absolute).
create or replace function public.production_start_next(p_player uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max    integer := coalesce(cfg_num('max_active_ship_production_slots'), 1)::integer;
  v_active integer;
  v_next   record;
  v_secs   double precision;
begin
  loop
    select count(*) into v_active from build_orders where player_id = p_player and status = 'active';
    exit when v_active >= v_max;

    select bo.id, bo.quantity, ut.build_time_seconds
      into v_next
      from build_orders bo
      join unit_types ut on ut.id = bo.unit_type_id
      where bo.player_id = p_player and bo.status = 'waiting'
      order by bo.queued_at asc
      limit 1
      for update skip locked;
    exit when v_next.id is null;

    v_secs := greatest(
      coalesce(cfg_num('min_build_seconds'), 5),
      v_next.build_time_seconds * v_next.quantity * coalesce(cfg_num('build_time_scale'), 1.0));
    update build_orders set
      status      = 'active',
      started_at  = now(),
      complete_at = now() + make_interval(secs => v_secs),
      updated_at  = now()
    where id = v_next.id;
  end loop;
end;
$$;

-- ── production_create_order: now creates a WAITING order (no timestamps yet) ──
drop function if exists public.production_create_order(uuid, uuid, text, integer, double precision, timestamptz);
create or replace function public.production_create_order(
  p_player uuid, p_base uuid, p_unit_type text, p_quantity integer, p_metal double precision)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into build_orders (player_id, base_id, unit_type_id, quantity, metal_spent, status, queued_at)
    values (p_player, p_base, p_unit_type, p_quantity, p_metal, 'waiting', now())
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
  update build_orders set status = 'completed', resolved_at = now(), updated_at = now()
    where id = p_order and status = 'active';
end;
$$;

-- ── train_units: enqueue WAITING, then start next (fills the free active slot) ─
create or replace function public.train_units(p_base uuid, p_unit_type text, p_quantity integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_owns   boolean;
  v_cost   integer;
  v_active integer;
  v_max    integer := coalesce(cfg_num('max_build_orders'), 5)::integer;
  v_order  uuid;
begin
  if v_player is null then raise exception 'train_units: not authenticated'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'train_units: invalid quantity %', p_quantity; end if;

  select exists (select 1 from bases where id = p_base and player_id = v_player) into v_owns;
  if not v_owns then raise exception 'train_units: base % not owned by caller', p_base; end if;

  select metal_cost into v_cost from unit_types where id = p_unit_type and status = 'active';
  if v_cost is null then raise exception 'train_units: unknown or inactive unit %', p_unit_type; end if;

  -- total non-terminal orders (waiting + active) capped at max_build_orders
  select count(*) into v_active from build_orders where player_id = v_player and status in ('waiting','active');
  if v_active >= v_max then raise exception 'train_units: training queue full (max %)', v_max; end if;

  perform base_spend_resources(p_base, 'metal', (v_cost * p_quantity)::double precision);
  v_order := production_create_order(v_player, p_base, p_unit_type, p_quantity, (v_cost * p_quantity)::double precision);
  perform production_start_next(v_player);  -- promotes this order to active iff a slot is free
  return v_order;
end;
$$;

-- ── process_build_queue: complete due ACTIVE orders, then start the next ──────
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
    where status = 'active' and complete_at is not null and complete_at <= now()
    for update skip locked
  loop
    perform base_merge_units(o.base_id,
      jsonb_build_array(jsonb_build_object('unit_type_id', o.unit_type_id, 'quantity', o.quantity)));
    perform production_complete_order(o.id);
    perform production_start_next(o.player_id);  -- waiting → active for the freed slot
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ── cancel_build_order: player RPC, server-authoritative ─────────────────────
-- waiting → 100% metal refund · active → 50% · completed/cancelled → rejected.
create or replace function public.cancel_build_order(p_order uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o        build_orders%rowtype;
  v_refund double precision;
begin
  select * into o from build_orders where id = p_order for update;
  if not found then raise exception 'cancel_build_order: order % not found', p_order; end if;
  if o.player_id <> auth.uid() then raise exception 'cancel_build_order: not your order'; end if;
  if o.status not in ('waiting','active') then raise exception 'cancel_build_order: cannot cancel a % order', o.status; end if;

  v_refund := case when o.status = 'waiting' then o.metal_spent else floor(o.metal_spent * 0.5) end;
  update build_orders set status = 'cancelled', resolved_at = now(), updated_at = now() where id = o.id;
  if v_refund > 0 then
    perform base_add_resources(o.base_id, jsonb_build_object('metal', v_refund));  -- Base credits the refund
  end if;
  perform production_start_next(o.player_id);  -- if the active item was cancelled, the next starts
end;
$$;

-- ── Re-lock execute surface (anti-cheat). cancel_build_order is a new client RPC ─
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                           to anon, authenticated;
grant execute on function public.bootstrap_me()                            to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb) to authenticated;
grant execute on function public.request_leave_location(uuid)              to authenticated;
grant execute on function public.request_retreat(uuid)                     to authenticated;
grant execute on function public.get_combat_reports()                      to authenticated;
grant execute on function public.train_units(uuid, text, integer)          to authenticated;
grant execute on function public.cancel_build_order(uuid)                  to authenticated;
grant execute on function public.process_build_queue()                     to service_role;
