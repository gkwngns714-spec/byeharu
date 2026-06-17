-- Byeharu — Phase 7: Main Ship Instance (additive foundation ONLY).
--
-- Creates the player's ONE main ship — the player identity, not stackable. This is the
-- emotional center of the future expedition: Main Ship + Captains + Modules + Support
-- Craft → Expedition. Phase 7 only CREATES it; the ship sits 'home' and is consumed by
-- NOTHING yet (no combat hook, no support-craft attachment, no calculate_expedition_stats,
-- no capacity enforcement — those are Phase 8+). The proven fleet/movement/combat/
-- production engine is completely untouched.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): main_ship_hull_types = Reference/Config (public read);
-- main_ship_instances = the Main Ship system (owner-read; writes ONLY via SECURITY
-- DEFINER functions). No client write path.

-- ── main_ship_hull_types (Reference/Config; public read) ────────────────────────
create table public.main_ship_hull_types (
  hull_type_id          text primary key,
  name                  text not null,
  description           text,
  base_hp               integer not null check (base_hp > 0),
  base_speed            numeric not null check (base_speed > 0),
  base_cargo_capacity   integer not null check (base_cargo_capacity >= 0),
  base_support_capacity integer not null check (base_support_capacity >= 0),
  base_captain_slots    integer not null check (base_captain_slots >= 0),
  base_module_slots     integer not null check (base_module_slots >= 0),
  base_stats_json       jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now()
);
alter table public.main_ship_hull_types enable row level security;
create policy "main_ship_hull_types_public_read" on public.main_ship_hull_types for select using (true);
grant select on public.main_ship_hull_types to anon, authenticated;

-- One starter hull only (conservative; not final balance). support_capacity 10 is the
-- finite loadout budget a future calculate_expedition_stats will enforce against
-- support_craft_types.capacity_cost.
insert into public.main_ship_hull_types
  (hull_type_id, name, description, base_hp, base_speed, base_cargo_capacity,
   base_support_capacity, base_captain_slots, base_module_slots) values
  ('starter_frigate', 'Byeharu-class Frigate', 'The player''s first main ship — survivable, flexible, modest cargo.',
   500, 1.0, 50, 10, 2, 3)
on conflict (hull_type_id) do nothing;

-- ── main_ship_instances (Main Ship system; owner-read; no client write) ─────────
-- One per player (player_id unique). Stats are copied from the hull on creation so the
-- instance can later diverge (damage, upgrades) without mutating the hull template.
create table public.main_ship_instances (
  main_ship_id     uuid primary key default gen_random_uuid(),
  player_id        uuid not null unique references auth.users (id) on delete cascade,
  hull_type_id     text not null references public.main_ship_hull_types (hull_type_id),
  name             text not null default 'Byeharu',
  status           text not null default 'home'
                     check (status in ('home','traveling','hunting','trading','exploring',
                                       'mining','retreating','returning','repairing','destroyed')),
  hp               integer not null check (hp >= 0),
  max_hp           integer not null check (max_hp > 0),
  cargo_used       integer not null default 0 check (cargo_used >= 0),
  cargo_capacity   integer not null check (cargo_capacity >= 0),
  support_capacity integer not null check (support_capacity >= 0),
  captain_slots    integer not null check (captain_slots >= 0),
  module_slots     integer not null check (module_slots >= 0),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table public.main_ship_instances enable row level security;
create policy "main_ship_instances_select_own" on public.main_ship_instances
  for select using (player_id = auth.uid());
grant select on public.main_ship_instances to authenticated;

-- ── ensure_main_ship_for_player: idempotent one-ship-per-player creator ──────────
create or replace function public.ensure_main_ship_for_player(p_player uuid)
returns public.main_ship_instances
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship public.main_ship_instances%rowtype;
begin
  -- Idempotent + concurrency-safe: the player_id UNIQUE constraint guards duplicates.
  insert into main_ship_instances
    (player_id, hull_type_id, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots)
  select p_player, h.hull_type_id, h.base_hp, h.base_hp, h.base_cargo_capacity,
         h.base_support_capacity, h.base_captain_slots, h.base_module_slots
    from main_ship_hull_types h
    where h.hull_type_id = 'starter_frigate'
  on conflict (player_id) do nothing;

  select * into v_ship from main_ship_instances where player_id = p_player;
  return v_ship;
end;
$$;

-- ── get_main_ship: safe owner read helper ───────────────────────────────────────
create or replace function public.get_main_ship(p_player uuid)
returns public.main_ship_instances
language sql
stable
security definer
set search_path = public
as $$
  select * from main_ship_instances where player_id = p_player;
$$;

-- ── rename_main_ship: server-authoritative rename (trim + length-limit) ──────────
create or replace function public.rename_main_ship(p_player uuid, p_name text)
returns public.main_ship_instances
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship  public.main_ship_instances%rowtype;
  v_clean text;
begin
  v_clean := btrim(coalesce(p_name, ''));
  if length(v_clean) = 0  then raise exception 'rename_main_ship: name cannot be empty'; end if;
  if length(v_clean) > 40 then raise exception 'rename_main_ship: name too long (max 40)'; end if;
  update main_ship_instances set name = v_clean, updated_at = now()
    where player_id = p_player
    returning * into v_ship;
  if not found then raise exception 'rename_main_ship: no main ship for player %', p_player; end if;
  return v_ship;
end;
$$;

-- ── Re-lock execute surface (anti-cheat). New functions default-grant to PUBLIC on
--    create → revoke and re-grant only the client RPCs. Main-ship writers are server-
--    only (service_role); clients READ their ship via owner-read RLS, never via RPC.
--    Prior service_role grants are untouched by a public/anon/authenticated revoke.
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
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.ensure_main_ship_for_player(uuid)         to service_role;
grant execute on function public.get_main_ship(uuid)                       to service_role;
grant execute on function public.rename_main_ship(uuid, text)              to service_role;
