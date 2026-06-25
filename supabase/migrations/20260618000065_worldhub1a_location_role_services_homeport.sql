-- Byeharu — WORLD-HUB-1A: additive, dark, DISCONNECTED city/port + home-port domain foundation.
--
-- Creates the domain boundaries for future real cities/ports WITHOUT wiring them to anything. This phase is
-- additive schema only. It:
--   • seeds NO rows and reclassifies NO existing location (every existing location becomes 'unclassified');
--   • creates / consumes NO space_anchors (coordinate truth stays solely with space_anchors, untouched here);
--   • adds NO docking / market / repair / recruitment / movement logic and NO public RPC or UI;
--   • does NOT touch bases (no base anchor, no base coordinate authority, no base-return path), legacy `home`,
--     main_ship_instances spatial state, fleets, location_presence, repair, initialize_new_player,
--     bootstrap_me, OSN movement/Dock-0/arrival/Stop, get_world_map(), or either feature flag.
--
-- Ownership rules established by this phase (see docs/WORLDHUB_OWNERSHIP.md):
--   locations.physical_role  = a location's PHYSICAL IDENTITY (city/port/station/landmark/activity_site).
--   location_services        = a location's CITY/PORT CAPABILITIES (docking/market/repair/refit/recruitment).
--   space_anchors            = canonical COORDINATE truth (UNCHANGED; not created or consumed here).
--   player_home_port         = a player's default home-port AFFILIATION (NOT a base, NOT a ship position).
--   location_presence        = a ship's CURRENT physical location (UNCHANGED; owned by the presence system).
--   bases                    = non-spatial economy/admin (UNCHANGED; never a map coordinate).

-- ── A. Physical location role — explicit identity, separate from location_type / activity_type ───────────
-- `location_type` (pirate_hunt/safe_zone/...) and `activity_type` (hunt_pirates/none/...) describe gameplay
-- activity, NOT the durable physical "is this a city/port/station/landmark" identity. A dedicated role column
-- is the long-term city/port definition. Existing rows default to 'unclassified' (NO forced reinterpretation:
-- they are explicitly un-roled, not turned into cities/landmarks). locations stays client SELECT-only (no new
-- grant); get_world_map() selects explicit columns (never *), so this column is invisible to client/map until
-- a deliberate future phase exposes it.
alter table public.locations
  add column physical_role text not null default 'unclassified'
    check (physical_role in ('unclassified', 'city', 'port', 'station', 'landmark', 'activity_site'));

-- ── B. Location service/capability model — world-hub owned, server-only, EMPTY ───────────────────────────
-- A location's services are orthogonal to BOTH its coordinates (space_anchors) and its combat activity
-- (activity_type). A location may offer several services; at most one row per (location, service). No row is
-- created here, and no docking/market/repair/recruitment logic consumes these yet.
create table public.location_services (
  id          uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations (id) on delete cascade,
  service     text not null check (service in ('docking', 'market', 'repair', 'refit', 'recruitment')),
  status      text not null default 'active' check (status in ('active', 'disabled')),
  created_at  timestamptz not null default now(),
  constraint location_services_one_per_kind unique (location_id, service)
);
create index location_services_location_id_idx on public.location_services (location_id);

-- Private / server-owned: RLS on with NO policy (anon/authenticated denied), explicit revoke, service_role
-- only — mirrors the established OSN private-domain pattern (space_anchors / command receipts). No player
-- read/write/RPC; no consumer.
alter table public.location_services enable row level security;
revoke all on table public.location_services from public, anon, authenticated;
grant select, insert, update, delete on table public.location_services to service_role;

-- ── C. Player default home-port affiliation — player-level, server-owned, nullable by absence ────────────
-- A DEDICATED player→location relation rather than a profiles column: public.profiles carries an owner
-- UPDATE RLS policy (profiles_update_own), so a profiles column would be player-writable (or require invasive
-- column-grant surgery to lock down). A dedicated server-owned table guarantees "no player write" cleanly and
-- leaves profiles/initialization untouched. Affiliation is NOT a base, NOT a ship's physical position, and is
-- never the source of a ship's current location.
create table public.player_home_port (
  player_id     uuid primary key references auth.users (id) on delete cascade,
  location_id   uuid not null references public.locations (id) on delete restrict,
  affiliated_at timestamptz not null default now()
);
-- PK(player_id) = at most one home port per player. Absence of a row = no affiliation (the "nullable initial"
-- state). NO row is created here; no player is assigned; initialize_new_player / bootstrap_me / ship creation
-- / repair are UNCHANGED.

-- Owner MAY read their own affiliation (mirrors profiles_select_own visibility). There is NO write policy, and
-- authenticated receives NO insert/update/delete grant, so a player cannot set or rewrite their home port even
-- for their own row (doubly denied: no grant + no policy). Writes are service_role only (a future phase).
alter table public.player_home_port enable row level security;
create policy "player_home_port_select_own"
  on public.player_home_port for select using (auth.uid() = player_id);
revoke all on table public.player_home_port from public, anon, authenticated;
grant select on table public.player_home_port to authenticated;
grant select, insert, update, delete on table public.player_home_port to service_role;
