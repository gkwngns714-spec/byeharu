-- OSN-ANCHOR-1B — additive, EMPTY, server-only canonical anchor schema.
--
-- Creates public.space_anchors: the single canonical home for non-ship world coordinates in the shared OSN
-- galaxy frame [-10000,10000]^2. This phase is a SCHEMA FOUNDATION ONLY. It:
--   • seeds NO rows;
--   • copies/backfills NOTHING from bases.x/y or locations.x/y (those remain legacy display-only);
--   • is NOT read by mainship_space_resolve_origin (resolver intentionally UNCHANGED — home / at_location /
--     legacy_home / legacy_present still resolve as origin_not_anchored after this migration);
--   • does NOT change docking, the arrival processor, begin_move, main_ship_instances.space_x/y rules,
--     ship state transitions, any player RPC, any UI, or either feature flag.
--
-- Owner-kind discriminator is CLOSED to {base, location}; each row has EXACTLY ONE real typed owner FK
-- matching its kind (no ownerless row, no all-null owner columns, no loose polymorphic (kind, owner_uuid),
-- no future-kind placeholder). Future kinds require a separate deliberate migration that adds a real typed
-- owner relation + its own CHECK arm.
--
-- Lifecycle: an active anchor may transition ONLY to retired; its kind/owner/x/y/created_at are immutable;
-- a retired anchor may not be reactivated or edited. Relocation = retire old active + insert new active.
-- Exception: a hard base deletion intentionally CASCADES its anchor rows (incl. retired history) because the
-- owner itself is gone (base_id ON DELETE CASCADE). Location anchors are RESTRICT-protected (locations are
-- NO-ACTION/undeletable while referenced). No soft-delete/archive machinery is added to bases or locations.
--
-- Security: private/server-owned. RLS enabled with NO policy; explicit revoke from public/anon/authenticated;
-- explicit grant to service_role only — consistent with the existing OSN private-domain pattern
-- (main_ship_space_command_receipts). No player read/write grant, no player-facing RPC, no public read path.

-- ── 1. Table ───────────────────────────────────────────────────────────────────────────────────────────
create table public.space_anchors (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('base', 'location')),

  base_id     uuid references public.bases (id)      on delete cascade,
  location_id uuid references public.locations (id)  on delete restrict,

  space_x     double precision not null,
  space_y     double precision not null,

  status      text not null default 'active' check (status in ('active', 'retired')),
  created_at  timestamptz not null default now(),

  -- Exactly one real typed owner, matching kind. Rejects all-null, both-owner, and mismatched-kind rows.
  constraint space_anchors_exactly_one_owner check (
    (kind = 'base'     and base_id is not null     and location_id is null) or
    (kind = 'location' and location_id is not null and base_id is null)
  ),

  -- Canonical coordinate domain. NOT NULL columns reject NULL; the bounds reject NaN and ±Infinity too
  -- (Postgres float ordering puts -Inf below and +Inf/NaN above every finite value, so neither satisfies
  -- BETWEEN), and the explicit <> 'NaN' guards make the NaN rejection self-evident.
  constraint space_anchors_coords_finite_in_bounds check (
    space_x <> 'NaN'::double precision and space_y <> 'NaN'::double precision
    and space_x between -10000 and 10000
    and space_y between -10000 and 10000
  )
);

-- ── 2. Partial uniqueness: at most one ACTIVE anchor per owner. No (space_x, space_y) unique — intentional
--       co-location must remain possible. Retired rows are excluded so retire + replace is allowed. ───────
create unique index space_anchors_one_active_per_base
  on public.space_anchors (base_id)
  where status = 'active' and base_id is not null;

create unique index space_anchors_one_active_per_location
  on public.space_anchors (location_id)
  where status = 'active' and location_id is not null;

-- ── 3. Immutability / lifecycle guard (BEFORE UPDATE) ────────────────────────────────────────────────────
-- DELETE is intentionally NOT guarded: the base_id ON DELETE CASCADE must be allowed to remove anchor rows
-- (incl. retired history) when the owning base is hard-deleted; location_id RESTRICT prevents location loss
-- while anchored. Normal operation never deletes anchors — it retires them.
create or replace function public.space_anchors_immutability_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- A retired anchor is terminal: no reactivation, no edits.
  if old.status = 'retired' then
    raise exception 'space_anchors: retired anchor % is immutable (no reactivation or edit)', old.id;
  end if;

  -- old.status = 'active': kind / owner FK / coordinates / created_at are immutable. Relocate by
  -- retiring this row and inserting a new active one.
  if new.kind        is distinct from old.kind
     or new.base_id     is distinct from old.base_id
     or new.location_id is distinct from old.location_id
     or new.space_x     is distinct from old.space_x
     or new.space_y     is distinct from old.space_y
     or new.created_at  is distinct from old.created_at then
    raise exception 'space_anchors: active anchor % kind/owner/coordinates/created_at are immutable (retire + insert to relocate)', old.id;
  end if;

  -- Only status may change, and (since old is active and the column CHECK restricts to active|retired) the
  -- single permitted transition is active -> retired; active -> active is an accepted no-op.
  return new;
end;
$$;

create trigger space_anchors_immutability
  before update on public.space_anchors
  for each row execute function public.space_anchors_immutability_guard();

-- ── 4. Security boundary: private / server-owned. ────────────────────────────────────────────────────────
alter table public.space_anchors enable row level security;  -- RLS on, NO policy → anon/authenticated denied

-- Explicit revoke/regrant rather than relying on defaults (the table and the trigger function both default-
-- grant nothing-to/everything-from PUBLIC depending on object type; lock them explicitly).
revoke all on table public.space_anchors from public, anon, authenticated;
grant select, insert, update, delete on table public.space_anchors to service_role;

-- The trigger function default-grants EXECUTE to PUBLIC on create; re-lock it. (Triggers fire as the table
-- owner regardless of EXECUTE privilege, so no grant is required for the guard to run.)
revoke execute on function public.space_anchors_immutability_guard() from public, anon, authenticated;
