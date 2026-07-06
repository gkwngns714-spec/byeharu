-- Byeharu — FITTING-P14 SLICE B: the fitting-state table + THE ONE writer (table + RLS + ONE
-- internal function ONLY; no RPC wrapper, no receipts table, no adapter change, no frontend; the
-- feature stays fully DARK behind module_fitting_enabled=false from 0111 — NOTHING client-reachable
-- can write this table, and no caller of the writer exists yet).
--
-- Mirrors the Phase-13 instances slice (0108 module_instances + modules_mint_instance) and the 0109
-- per-player advisory-lock idiom, deviating ONLY where the locked Phase-14 decisions require it
-- (0111 header / DEV_LOG 2026-07-04 FITTING-P14 SLICE A):
--
-- (1) THE PK IS THE INVARIANT: `module_instance_id` is the PRIMARY KEY, so one module instance is
--     fitted to at most one ship, EVER — a schema fact, not writer discipline (the one-active-owner
--     idiom: a ship is owned by exactly one movement system; a module is held by at most one ship).
-- (2) FIT AND UNFIT ARE ONE WRITER: fitting_apply(p_player, p_module_instance_id, p_main_ship_id)
--     — p_main_ship_id NOT NULL = FIT, NULL = UNFIT. One sole writer per table covers ALL mutations
--     of that table (insert AND delete); two writer functions would be two writers.
-- (3) THE WRITER OWNS TABLE INVARIANTS ONLY. Structural invariants are enforced HERE so no future
--     caller can violate them: module ownership (module_instances.player_id = p_player), ship
--     ownership on FIT (main_ship_instances.player_id = p_player — the 0043 ownership shape),
--     one-ship-per-module (the PK + an explicit `already_fitted` reject that NAMES the current ship
--     rather than silently re-homing the module), and the CAPACITY HARD CAP: Σ module_types.slot_cost
--     of the ship's currently fitted modules + the new module's slot_cost must be
--     ≤ main_ship_instances.module_slots, else reject `insufficient_slots` with {used, cost, limit}
--     — a hard rejection mirroring 0044:112–115 (exception-not-clamp semantics, in envelope form),
--     NEVER a clamp. GAME-RULE checks deliberately do NOT live here: the `module_fitting_enabled`
--     dark gate, the ship-must-be-home spatial rule, and receipt-keyed idempotency all belong to the
--     slice-C COMMAND layer (the 0099/0104/0109 two-layer idiom — the command gates and dedups; the
--     writer guards the table). This writer is unreachable by clients (service_role-only) until that
--     gated command exists, so the feature stays fully dark.
-- (4) RACE SAFETY (the exact 0109 key-derivation idiom): the per-player
--     pg_advisory_xact_lock(hashtext('module_fitting'), hashtext(p_player::text)) is taken FIRST,
--     serializing ALL of a player's fitting mutations. Every row of a ship's fit set belongs to the
--     ship's owner (ownership checks above), so the capacity sum read under this lock cannot be
--     raced by another mutation of the same ship — the read-sum → insert window is single-writer by
--     construction. Envelope style is the 0104/0109 private-writer form ({ok:false, reason, …} —
--     the slice-C wrapper will map reasons to client codes/messages), not 0039/0108
--     exception-style: fit/unfit has friendly, expected failure paths (already_fitted /
--     insufficient_slots) that commands must surface, not catch.
--
-- ── SOLE-WRITER LAW (docs/SYSTEM_BOUNDARIES.md, synced this same step) ────────────────────────────
-- fitting_apply() below is THE sole writer of ship_module_fittings — every mutation (fit AND unfit),
-- from the slice-C command or ANY future path, goes through this function. No second
-- insert/update/delete path, ever. Validation failures write nothing.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): ship_module_fittings → Fitting (NEW
-- leaf system per ROADMAP law 5 "Fitting=modules"; sole writer = fitting_apply, service_role-only,
-- called by NOTHING yet). Edges all DOWNWARD, acyclic: Fitting → Modules (read module_instances) ·
-- Main Ship (read main_ship_instances ownership + module_slots) · Reference/Config (read
-- module_types.slot_cost). No system depends on Fitting yet; the Phase-14 adapter slice will later
-- add the Expedition-stats → Fitting downward READ edge. No flag flipped; 0001–0111 unedited.

-- ── 1) ship_module_fittings — which module instance is fitted to which ship (Fitting-owned) ───────
create table public.ship_module_fittings (
  -- the PK IS the one-ship-per-module invariant: a module instance appears at most once.
  module_instance_id uuid primary key references public.module_instances (id) on delete cascade,
  main_ship_id       uuid not null references public.main_ship_instances (main_ship_id) on delete cascade,
  player_id          uuid not null references auth.users (id) on delete cascade,
  fitted_at          timestamptz not null default now()
);
-- per-ship fit-set lookups (the capacity sum + the future adapter read):
create index ship_module_fittings_ship_idx
  on public.ship_module_fittings (main_ship_id);

-- Own-row read only (the 0108 posture verbatim): RLS on, one owner-select policy, select granted to
-- authenticated; NO insert/update/delete policy and NO write grant — the sole writer is
-- fitting_apply() below (SECURITY DEFINER, service_role only), whose only future caller is DARK
-- behind module_fitting_enabled=false. NOTHING calls it yet.
alter table public.ship_module_fittings enable row level security;
create policy "ship_module_fittings_select_own" on public.ship_module_fittings
  for select using (player_id = auth.uid());
grant select on public.ship_module_fittings to authenticated;

comment on table public.ship_module_fittings is
  'FITTING-P14: which module instance is fitted to which main ship. The module_instance_id PK IS '
  'the invariant: one module is fitted to at most one ship, ever. Sole writer = fitting_apply() '
  '(FIT and UNFIT through the ONE function; service_role only); it enforces owner-consistency and '
  'the sum(slot_cost) <= module_slots hard cap. Players read only their own rows. Feature DARK '
  'behind module_fitting_enabled.';

-- ── 2) fitting_apply — THE one writer of ship_module_fittings (internal; fit AND unfit) ───────────
create or replace function public.fitting_apply(
  p_player             uuid,
  p_module_instance_id uuid,
  p_main_ship_id       uuid  -- NOT NULL = FIT to this ship · NULL = UNFIT
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_module      module_instances%rowtype;
  v_ship_owner  uuid;
  v_slots_limit integer;
  v_cost        integer;
  v_used        integer;
  v_current     uuid;
  v_fitted_at   timestamptz;
  v_unfit_ship  uuid;
begin
  -- 1) per-player serialization FIRST (the exact 0109:118–123 idiom, fitting domain): ALL of a
  --    player's fitting mutations queue here, so the capacity sum below cannot be raced by another
  --    fit/unfit of the same player (and every fitting on a ship belongs to the ship's owner, so
  --    per-player IS per-ship-fit-set).
  perform pg_advisory_xact_lock(hashtext('module_fitting'), hashtext(p_player::text));

  -- 2) the module instance must exist AND belong to p_player (Modules read, DOWNWARD). One reason
  --    for both cases — another player's instance answers exactly like a nonexistent one.
  select * into v_module from module_instances
    where id = p_module_instance_id and player_id = p_player;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'module_not_owned');
  end if;

  -- ── UNFIT (p_main_ship_id NULL): delete the module's fitting row ────────────────────────────────
  if p_main_ship_id is null then
    delete from ship_module_fittings
      where module_instance_id = p_module_instance_id
      returning main_ship_id into v_unfit_ship;
    if v_unfit_ship is null then
      -- distinct truthful reason; idempotency ENVELOPES are the slice-C command's job (receipt
      -- replay), not this writer's — a bare re-unfit is a real not_fitted here.
      return jsonb_build_object('ok', false, 'reason', 'not_fitted');
    end if;
    return jsonb_build_object('ok', true, 'unfitted', true,
      'module_instance_id', p_module_instance_id, 'main_ship_id', v_unfit_ship);
  end if;

  -- ── FIT (p_main_ship_id NOT NULL) ───────────────────────────────────────────────────────────────
  -- 3) the target ship must exist AND belong to p_player (Main Ship read, DOWNWARD — the 0043
  --    ownership shape; also fixes owner-consistency: row.player_id = module owner = ship owner).
  select player_id, module_slots into v_ship_owner, v_slots_limit
    from main_ship_instances where main_ship_id = p_main_ship_id;
  if v_ship_owner is null or v_ship_owner <> p_player then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_owned');
  end if;

  -- 4) one-ship-per-module: an already-fitted module is REJECTED naming its current ship — never
  --    silently re-homed (an explicit unfit must come first). The PK backstops this check.
  select main_ship_id into v_current from ship_module_fittings
    where module_instance_id = p_module_instance_id;
  if v_current is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_fitted', 'main_ship_id', v_current);
  end if;

  -- 5) CAPACITY HARD CAP (the 0044:112–115 mechanism in envelope form — reject, NEVER clamp):
  --    Σ slot_cost currently fitted to the ship + this module's slot_cost ≤ ship.module_slots.
  --    Race-free under the step-1 player lock (see header (4)).
  select slot_cost into v_cost from module_types where id = v_module.module_type_id;
  select coalesce(sum(t.slot_cost), 0) into v_used
    from ship_module_fittings f
    join module_instances i on i.id = f.module_instance_id
    join module_types t     on t.id = i.module_type_id
    where f.main_ship_id = p_main_ship_id;
  if v_used + v_cost > v_slots_limit then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_slots',
      'used', v_used, 'cost', v_cost, 'limit', v_slots_limit);
  end if;

  -- 6) the ONE mutation. Plain insert: the PK cannot conflict here — step 4 ran under the step-1
  --    lock, and only the owner (serialized above) can reference this module.
  insert into ship_module_fittings (module_instance_id, main_ship_id, player_id)
    values (p_module_instance_id, p_main_ship_id, p_player)
    returning fitted_at into v_fitted_at;

  return jsonb_build_object('ok', true, 'fitted', true,
    'module_instance_id', p_module_instance_id, 'main_ship_id', p_main_ship_id,
    'slot_cost', v_cost, 'slots_used', v_used + v_cost, 'slots_limit', v_slots_limit,
    'fitted_at', v_fitted_at);
end;
$$;

-- ── 3) ACL (anti-cheat; the 0108:108–113 relock idiom verbatim — the 0064-era default-privileges
--       revoke already denies new functions, this re-asserts explicitly). No existing grant touched.
-- the ONE writer stays OFF the client surface (internal; server-side callers only — none exist yet):
revoke execute on function public.fitting_apply(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.fitting_apply(uuid, uuid, uuid) to service_role;
