-- Byeharu — STATION-STORAGE P1: per-port storage foundation (additive, DARK, disconnected).
--
-- GOAL (EVE-style): every dockable port/station gets its OWN independent, per-player storage
-- (resources + units). Anti-spaghetti decision: DO NOT create a second storage system. The
-- `bases` table + its primitives (base_reserve_units / base_merge_units / base_add_resources /
-- base_spend_resources) + rewards + production already ARE a per-player resource+unit store keyed
-- on `bases.id`. This phase GENERALIZES `bases` from "one Home Base per player" into "one store
-- per (player, dockable-port)" by adding `bases.location_id`. Every downstream consumer keeps
-- working unchanged (they key on base_id).
--
-- DARK + disconnected: this migration only adds a flag (default false), a nullable column, a
-- uniqueness constraint, one server-only helper, and stamps a location_id onto existing/new Home
-- Bases (a brand-new, unread column). It does NOT reveal any port, does NOT move any base
-- coordinate, does NOT touch get_world_map / OSN movement / Dock-0 / repair / any RPC or UI, and
-- reads NO flag at runtime. Production behavior is byte-identical until STATION-STORAGE P2 wires
-- the docked-port paths behind `station_storage_enabled`.
--
-- The starter port is the existing hidden WORLD-HUB-1B seed 'Haven Reach' (STARTER_PORT_1). It
-- stays hidden here; port reveal is a deliberate activation step (see verify script / a future
-- activation phase), never a silent live-map change.

-- ── 0. Feature flag (dark) ───────────────────────────────────────────────────────────────────
insert into public.game_config (key, value, description) values
  ('station_storage_enabled', 'false',
   'STATION-STORAGE: per-port (player,location) storage — depart/return/bank-loot/repair at the docked port')
on conflict (key) do nothing;

-- ── 1. Generalize `bases`: add the port a store lives at ─────────────────────────────────────
-- Nullable + ON DELETE RESTRICT (a location must never be deleted out from under a player's store;
-- locations are undeletable-while-referenced elsewhere too, e.g. space_anchors). Legacy Home Bases
-- have location_id = NULL until backfilled below. The column is NEW and read by nothing yet.
alter table public.bases
  add column location_id uuid references public.locations (id) on delete restrict;

create index if not exists bases_location_id_idx on public.bases (location_id);

-- ── 2. Backfill existing Home Bases onto the starter port ────────────────────────────────────
-- Each player currently has exactly one Home Base (initialize_new_player is idempotent-by-player).
-- Point it at the starter port so the player's existing stockpile/garrison BECOMES that port's
-- store. Coordinates (bases.x/y) are intentionally LEFT UNCHANGED (still 0,0) so the legacy home
-- marker does not move while dark — the store's spatial truth is the port's space_anchor (P2).
-- Guarded: only runs if the starter-port seed row exists (it does, from WORLD-HUB-1B / 0066).
do $$
declare
  v_starter uuid := 'b1a00001-0066-4a00-8a00-000000000001';  -- Haven Reach (STARTER_PORT_1)
begin
  if exists (select 1 from public.locations where id = v_starter) then
    update public.bases set location_id = v_starter where location_id is null;
  else
    raise notice 'STATION-STORAGE P1: starter port % missing; skipped Home Base backfill', v_starter;
  end if;
end $$;

-- ── 3. One store per (player, port) ──────────────────────────────────────────────────────────
-- Added AFTER the backfill so the newly-stamped rows never collide. NULL location_id rows remain
-- allowed (NULLs are distinct under a UNIQUE constraint) — harmless legacy/edge safety.
alter table public.bases
  add constraint bases_one_per_player_location unique (player_id, location_id);

-- ── 4. get_or_create_store — resolve/lazily-create a player's store at a dockable port ────────
-- The single seam P2 uses to turn "ship docked at location L" into "the base_id to read/write".
-- Dockability is gated by the CANONICAL 6-part port predicate `is_home_port_eligible` (city/port +
-- location/zone/sector active + active docking service + exactly one active anchor) — reused, not
-- reinvented. Store coords mirror the port's canonical anchor. SECURITY DEFINER (writes the
-- server-owned bases table); NOT client-callable. Idempotent + race-safe via the unique constraint.
create or replace function public.get_or_create_store(p_player uuid, p_location uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_store  uuid;
  v_sector uuid;
  v_name   text;
  v_x      double precision;
  v_y      double precision;
begin
  if p_player is null or p_location is null then
    raise exception 'get_or_create_store: player and location are required';
  end if;

  if not public.is_home_port_eligible(p_location) then
    raise exception 'get_or_create_store: location % is not a dockable port', p_location
      using errcode = 'check_violation';
  end if;

  select id into v_store
    from public.bases
    where player_id = p_player and location_id = p_location;
  if found then
    return v_store;
  end if;

  select z.sector_id, l.name into v_sector, v_name
    from public.locations l
    join public.zones z on z.id = l.zone_id
    where l.id = p_location;

  select a.space_x, a.space_y into v_x, v_y
    from public.space_anchors a
    where a.location_id = p_location and a.kind = 'location' and a.status = 'active';

  insert into public.bases (player_id, name, sector_id, x, y, status, location_id)
    values (p_player, v_name, v_sector, coalesce(v_x, 0), coalesce(v_y, 0), 'active', p_location)
    on conflict on constraint bases_one_per_player_location do nothing
    returning id into v_store;

  if v_store is null then  -- lost the race; the row now exists
    select id into v_store
      from public.bases
      where player_id = p_player and location_id = p_location;
  end if;

  return v_store;
end;
$$;

revoke all on function public.get_or_create_store(uuid, uuid) from public, anon, authenticated;
grant execute on function public.get_or_create_store(uuid, uuid) to service_role;

-- ── 5. New players: stamp the Home Base with the starter-port location_id ─────────────────────
-- Same seed allocation, now the base is explicitly the starter port's store. Coordinates stay 0,0
-- (legacy marker unchanged, dark). Idempotent-by-player guard preserved verbatim.
create or replace function public.initialize_new_player(p_player uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base    uuid;
  v_sector  uuid;
  v_starter uuid := 'b1a00001-0066-4a00-8a00-000000000001';  -- Haven Reach (STARTER_PORT_1)
begin
  if exists (select 1 from bases where player_id = p_player) then
    return;
  end if;

  select id into v_sector from sectors where sector_index = 1;  -- Outer Haven

  insert into bases (player_id, name, sector_id, x, y, location_id)
    values (
      p_player, 'Home Base', v_sector, 0, 0,
      (select id from public.locations where id = v_starter)  -- NULL-safe if seed absent
    )
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
