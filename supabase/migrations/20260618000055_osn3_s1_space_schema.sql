-- Byeharu — OSN-3 S1: coordinate-domain SCHEMA, invariants, flag (NO writers, flag OFF).
--
-- First OSN-3 implementation slice. Adds the durable schema the future coordinate-movement system
-- needs, legacy-safe lifecycle constraints, a dedicated OFF flag, and the write-once association
-- trigger for fleets.main_ship_id. It adds NO coordinate writer, processor, cron, RPC, UI, or any
-- change to legacy movement/presence/reconciler/repair/destruction. Both flags stay false.
--
-- FK delete-action policy (PROVEN on a disposable postgres:15 in scripts/osn3-s1-trigger-proof.sql):
--   • fleets.main_ship_id → main_ship_instances  ON DELETE SET NULL  (UNCHANGED) + write-once trigger
--     that allows a change ONLY as parent-deletion orphaning (non-null→NULL while the ship is gone);
--     reassignment / late-attach / ordinary detach are rejected. The FK SET NULL runs AFTER the parent
--     row is deleted, so the trigger's NOT EXISTS sees no parent and permits the cascade orphaning.
--   • main_ship_space_movements.{main_ship_id,fleet_id,player_id} → CASCADE (a user/ship delete cleans
--     up its coordinate rows; no repaired ship remains).
--   • fleets.active_space_movement_id → main_ship_space_movements  ON DELETE SET NULL DEFERRABLE
--     INITIALLY DEFERRED — the fleets<->movements cycle is order-independent; a ship delete that
--     cascade-deletes the movement while the fleet survives defers the FK check to COMMIT.
--   • receipts.{main_ship_id,player_id} → CASCADE; receipts.movement_id → SET NULL.

-- ── 3.1  main_ship_space_movements (future coordinate route engine; separate from fleet_movements) ──
create table public.main_ship_space_movements (
  id                 uuid primary key default gen_random_uuid(),
  main_ship_id       uuid not null references public.main_ship_instances (main_ship_id) on delete cascade,
  fleet_id           uuid not null references public.fleets (id) on delete cascade,
  player_id          uuid not null references auth.users (id) on delete cascade,

  origin_kind        text not null check (origin_kind in ('base','location','space')),
  origin_x           double precision not null,
  origin_y           double precision not null,

  target_kind        text not null check (target_kind in ('space','location','base')),
  target_x           double precision not null,
  target_y           double precision not null,
  target_location_id uuid references public.locations (id),
  target_base_id     uuid references public.bases (id),

  status             text not null default 'moving'
                       check (status in ('moving','arrived','stopped','cancelled','failed')),
  terminal_reason    text,
  speed_used         double precision not null,
  depart_at          timestamptz not null,
  arrive_at          timestamptz not null,
  created_at         timestamptz not null default now(),
  resolved_at        timestamptz,

  -- arrive strictly after depart
  check (arrive_at > depart_at),

  -- speed finite and > 0 (reject NaN/±Inf which satisfy a plain > 0; same pattern as migration 0054)
  check (speed_used > 0
         and speed_used <> 'NaN'::double precision
         and speed_used <> 'Infinity'::double precision
         and speed_used <> '-Infinity'::double precision),

  -- all four coordinates finite AND inside the immutable world sanity envelope [-10000,10000]^2
  check (origin_x <> 'NaN'::double precision and origin_x <> 'Infinity'::double precision and origin_x <> '-Infinity'::double precision
         and origin_x >= -10000 and origin_x <= 10000),
  check (origin_y <> 'NaN'::double precision and origin_y <> 'Infinity'::double precision and origin_y <> '-Infinity'::double precision
         and origin_y >= -10000 and origin_y <= 10000),
  check (target_x <> 'NaN'::double precision and target_x <> 'Infinity'::double precision and target_x <> '-Infinity'::double precision
         and target_x >= -10000 and target_x <= 10000),
  check (target_y <> 'NaN'::double precision and target_y <> 'Infinity'::double precision and target_y <> '-Infinity'::double precision
         and target_y >= -10000 and target_y <= 10000),

  -- target-kind invariant: explicit three-branch boolean (no nullable-unknown acceptance)
  check (
        (target_kind = 'space'    and target_location_id is null     and target_base_id is null)
     or (target_kind = 'location' and target_location_id is not null and target_base_id is null)
     or (target_kind = 'base'     and target_base_id is not null     and target_location_id is null)
  ),

  -- status/timestamp integrity: resolved_at present exactly for terminal rows
  check (
        (status = 'moving' and resolved_at is null)
     or (status in ('arrived','stopped','cancelled','failed') and resolved_at is not null)
  )
);

-- one active coordinate move per main ship / per fleet; due-arrival lookup
create unique index main_ship_space_movements_one_active_per_ship
  on public.main_ship_space_movements (main_ship_id) where status = 'moving';
create unique index main_ship_space_movements_one_active_per_fleet
  on public.main_ship_space_movements (fleet_id) where status = 'moving';
create index main_ship_space_movements_due_idx
  on public.main_ship_space_movements (arrive_at) where status = 'moving';

alter table public.main_ship_space_movements enable row level security;
create policy "main_ship_space_movements_select_own" on public.main_ship_space_movements
  for select using (player_id = auth.uid());
grant select on public.main_ship_space_movements to authenticated;   -- owner READ only; no write grant

-- ── 3.2  fleets.active_space_movement_id (honest moving fleet pointer; cycle with the table above) ──
alter table public.fleets
  add column active_space_movement_id uuid;
alter table public.fleets
  add constraint fleets_active_space_movement_fk
  foreign key (active_space_movement_id) references public.main_ship_space_movements (id)
  on delete set null deferrable initially deferred;

-- the two movement pointers are mutually exclusive, and a coordinate pointer implies a moving fleet
alter table public.fleets
  add constraint fleets_movement_pointers_exclusive
  check (active_movement_id is null or active_space_movement_id is null);
alter table public.fleets
  add constraint fleets_active_space_movement_requires_moving
  check (
    active_space_movement_id is null
    or (active_movement_id is null and status = 'moving' and location_mode = 'movement')
  );

-- one fleet per active coordinate movement (no two fleets share a coordinate movement)
create unique index fleets_one_per_active_space_movement
  on public.fleets (active_space_movement_id) where active_space_movement_id is not null;

-- ── 3.3  main_ship_space_command_receipts (server-side idempotency state; schema prep only) ─────────
create table public.main_ship_space_command_receipts (
  id                    uuid primary key default gen_random_uuid(),
  main_ship_id          uuid not null references public.main_ship_instances (main_ship_id) on delete cascade,
  player_id             uuid not null references auth.users (id) on delete cascade,
  request_id            uuid not null,
  command_type          text not null,
  canonical_payload_hash text not null,
  outcome_status        text not null,
  result_json           jsonb,
  movement_id           uuid references public.main_ship_space_movements (id) on delete set null,
  created_at            timestamptz not null default now(),
  completed_at          timestamptz,
  unique (main_ship_id, request_id)
);
-- Server-side operational state: RLS on, NO authenticated read/write policy or grant (service-role only).
alter table public.main_ship_space_command_receipts enable row level security;

-- ── 3.4  main-ship status += 'stationary' + six legacy-safe lifecycle checks ────────────────────────
-- Replace the inline status domain CHECK (auto-named) additively (no existing value removed/renamed).
alter table public.main_ship_instances drop constraint if exists main_ship_instances_status_check;
alter table public.main_ship_instances
  add constraint main_ship_instances_status_check
  check (status in ('home','traveling','hunting','trading','exploring','mining',
                    'retreating','returning','repairing','destroyed','stationary'));

-- Forward-only spatial_state → status rules (vacuously true for legacy spatial_state = NULL rows).
alter table public.main_ship_instances
  add constraint main_ship_instances_ss_in_space_status
  check (spatial_state is distinct from 'in_space' or status = 'stationary');
alter table public.main_ship_instances
  add constraint main_ship_instances_ss_at_location_status
  check (spatial_state is distinct from 'at_location' or status = 'stationary');
alter table public.main_ship_instances
  add constraint main_ship_instances_ss_in_transit_status
  check (spatial_state is distinct from 'in_transit' or status = 'traveling');
alter table public.main_ship_instances
  add constraint main_ship_instances_ss_home_status
  check (spatial_state is distinct from 'home' or status = 'home');
alter table public.main_ship_instances
  add constraint main_ship_instances_ss_destroyed_status
  check (spatial_state is distinct from 'destroyed' or status = 'destroyed');
-- Reverse rule for the NEW status only. IS TRUE is mandatory: a normal CHECK passes on NULL/unknown,
-- so this rejects status='stationary' with spatial_state = NULL (or any non in_space/at_location value).
alter table public.main_ship_instances
  add constraint main_ship_instances_stationary_spatial_state
  check (status <> 'stationary' or (spatial_state in ('in_space','at_location')) is true);

-- ── 3.5  fleets.main_ship_id write-once association (proven safe vs ON DELETE SET NULL) ─────────────
-- A fleet may lose its main-ship link ONLY as parent-deletion orphaning (the FK SET NULL, which runs
-- after the ship row is gone). Reassignment, late attachment, and ordinary detach are forbidden.
create or replace function public.fleets_main_ship_id_write_once()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.main_ship_id is distinct from old.main_ship_id then
    if not (old.main_ship_id is not null
            and new.main_ship_id is null
            and not exists (select 1 from main_ship_instances m where m.main_ship_id = old.main_ship_id)) then
      raise exception 'fleets.main_ship_id is write-once; reassignment, late attachment, and ordinary detach are forbidden';
    end if;
  end if;
  return new;
end;
$$;
create trigger fleets_main_ship_id_write_once_trg
  before update of main_ship_id on public.fleets
  for each row execute function public.fleets_main_ship_id_write_once();

-- ── 3.6  dedicated feature flag (OFF). NOT wired into any writer (there are none). ──────────────────
insert into public.game_config (key, value, description) values
  ('mainship_space_movement_enabled', 'false',
   'OSN-3: enable coordinate-domain main-ship movement admission (begin/return/stop). OFF in S1; no writers exist.')
on conflict (key) do nothing;

-- ── 3.7  Re-lock execute surface (anti-cheat). The new trigger function default-grants to PUBLIC on
--         create; revoke and re-grant ONLY the canonical client RPC list (carried verbatim from
--         migration 0053). Trigger functions do not require EXECUTE to fire, so the write-once trigger
--         keeps working. No new client RPC is added in S1. Prior service_role grants survive the revoke.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                                  to anon, authenticated;
grant execute on function public.bootstrap_me()                                   to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb)        to authenticated;
grant execute on function public.request_leave_location(uuid)                     to authenticated;
grant execute on function public.request_retreat(uuid)                            to authenticated;
grant execute on function public.get_combat_reports()                             to authenticated;
grant execute on function public.train_units(uuid, text, integer)                 to authenticated;
grant execute on function public.cancel_build_order(uuid)                         to authenticated;
grant execute on function public.get_my_expedition_preview(jsonb, text)           to authenticated;
grant execute on function public.send_main_ship_expedition(jsonb, uuid)           to authenticated;
grant execute on function public.request_main_ship_return(uuid)                   to authenticated;
grant execute on function public.repair_main_ship()                               to authenticated;
grant execute on function public.move_main_ship_to_location(uuid, uuid)           to authenticated;
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.dev_set_main_ship_destroyed(uuid)                to service_role;
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
