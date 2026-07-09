-- Byeharu — TEAM-COMMAND Slice A: team/group DATA MODEL + multi-ship enablement FOUNDATION (DARK).
--
-- First slice of the team-command system (docs/TEAM_COMMAND.md, docs/HANDOFF.md §4). The player will
-- eventually command up to 3 teams of ~6–8 ships each. This migration lays ONLY the durable foundation:
-- the group table, the ship→group link, and the config that unblocks the multi-ship path. It ships NO
-- behavior — no team travel, no team combat, no ship commissioning is enabled here.
--
-- ── TERMINOLOGY (non-negotiable; see docs/TEAM_COMMAND.md) ─────────────────────────────────────────
--   "group" == the BACKEND / DB / code word (ship_groups, main_ship_instances.group_id).
--   "team"  == the UI word only.
-- The DB never says "team"; the UI never says "group". This mapping is deliberate and kept explicit.
--
-- ── ANTI-SPAGHETTI LAW (from the roadmap; enforced across all team slices) ─────────────────────────
--   • A group must eventually resolve into the EXISTING fleet_units / combat_units combat input — never a
--     second combat engine. Slice A introduces NO combat path.
--   • Reuse the EXISTING fleets movement spine — Slice A introduces NO movement path.
--   • group (code) = team (UI); one selection source.
--
-- ── DARK-STATE / GATE DECISIONS (Slice A) ─────────────────────────────────────────────────────────
-- 1) NEW flag `team_command_enabled` (game_config bool, seeded FALSE). Mirrors the compile-time
--    TEAM_COMMAND_ENABLED in src/features/map/osnReleaseGates.ts. The team roster UI is invisible and the
--    (future) team RPCs will reject-before-read until a HUMAN flips BOTH. NOT set true here.
-- 2) `mainship_additional_commission_enabled` — DECISION: LEFT FALSE (untouched). Raising the ship cap
--    (below) is the FOUNDATION; actual 2nd+ ship creation stays gated OFF so there is NO uncontrolled ship
--    creation. Multi-ship commissioning is a later, separately-approved step, not part of Slice A.
-- 3) `max_main_ships_per_player` raised 3 → 24 (3 teams × up-to-8 ships). This is INERT while (2) is dark:
--    commission_additional_main_ship() still rejects at the gate before it ever reads the cap. The raise
--    only pre-sizes the cap so it is not the binding limit once multi-ship is later lit.
--
-- Touches NO combat/movement/trade path, NO frozen verifier file, NO existing RPC signature. Adds a table,
-- one nullable column, two config rows (one raise, one new), and DROPS one proven-dead function.

-- ── A. ship_groups (Team system; owner-read; writes ONLY via future SECURITY DEFINER RPCs — no client write) ──
--    One row per (player, group_index). group_index ∈ 1..3 caps a player at three teams and gives each team a
--    deterministic slot. name is the UI-editable team label. There is NO write path in Slice A: the table is
--    created empty and populated by the Slice-B assignment RPC (which will assert same-player ownership via the
--    mainship_resolve_owned_ship contract). A ship carries its membership on main_ship_instances.group_id (B).
create table public.ship_groups (
  group_id    uuid primary key default gen_random_uuid(),
  player_id   uuid not null references auth.users (id) on delete cascade,
  group_index integer not null check (group_index between 1 and 3),
  name        text not null default 'Team' check (char_length(btrim(name)) between 1 and 40),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (player_id, group_index)
);
alter table public.ship_groups enable row level security;
create policy "ship_groups_select_own" on public.ship_groups
  for select using (player_id = auth.uid());
grant select on public.ship_groups to authenticated;
create index ship_groups_player_idx on public.ship_groups (player_id);

-- ── B. main_ship_instances.group_id — the ship→team link (nullable = UNGROUPED is the default & valid state).
--    ON DELETE SET NULL: deleting a team un-groups its ships; it NEVER deletes a ship (no uncontrolled ship
--    removal). INVARIANT (enforced by the future assign RPC, not the FK): a ship may only reference a group
--    owned by the SAME player — Slice A has no write path, so nothing can violate it yet.
alter table public.main_ship_instances
  add column group_id uuid references public.ship_groups (group_id) on delete set null;
create index main_ship_instances_group_idx on public.main_ship_instances (group_id);

-- ── C. Config: raise the cap (INERT while additional-commission is dark) + seed the new team gate (DARK).
--    Cap raise MUST overwrite the existing 0080 value → do update. Gate seed is a new key → do nothing.
insert into public.game_config (key, value, description) values
  ('max_main_ships_per_player', '24',
   'TEAM-COMMAND Slice A: per-player main-ship cap raised 3→24 (3 teams × up to 8 ships). Inert while '
   'mainship_additional_commission_enabled is false — commissioning still rejects at the gate.')
on conflict (key) do update set value = excluded.value, description = excluded.description, updated_at = now();

insert into public.game_config (key, value, description) values
  ('team_command_enabled', 'false',
   'TEAM-COMMAND Slice A: server gate for the team-command surface (roster now; team send/stop/combat later). '
   'Mirrors compile-time TEAM_COMMAND_ENABLED. OFF on live — dark until a human flips it.')
on conflict (key) do nothing;

-- ── D. Drop the proven-dead get_main_ship(uuid) (migration 0043). It is service_role-only with NO caller in
--    src/, tests/, or any RPC (the §2.5 conversions replaced every single-ship-derivation reader), and it uses
--    the unguarded `where player_id = p_player` shortcut that returns an ARBITRARY row once a player owns >1
--    ship — exactly the hazard Slice A's cap raise moves toward. HANDOFF §4 flags it for drop. Removing it now
--    eliminates the last arbitrary-ship reader before multi-ship can ever be lit.
drop function if exists public.get_main_ship(uuid);
