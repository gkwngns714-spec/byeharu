-- Byeharu — CAPTAIN-P15 SLICE C: the assignment-state table + THE ONE writer (table + RLS + ONE
-- internal function ONLY; no RPC wrapper, no receipts table, no settled-SAFE rule, no read
-- surface, no adapter change, no frontend; the feature stays fully DARK behind
-- captain_assignment_enabled=false from 0117 — NOTHING client-reachable can write this table, and
-- no caller of the writer exists yet).
--
-- Mirrors the Phase-14 fittings slice (0112 ship_module_fittings + fitting_apply) structure,
-- naming, and layering, deviating ONLY where the locked Phase-15 decisions require it (0117/0118
-- headers / DEV_LOG 2026-07-04 CAPTAIN-P15 SLICES A–B):
--
-- (1) THE PK IS THE INVARIANT: `captain_instance_id` is the PRIMARY KEY, so one captain instance
--     is assigned to at most one ship, EVER — a schema fact, not writer discipline (the exact
--     0112:54 one-ship-per-module shape; the one-active-owner idiom).
-- (2) ASSIGN AND UNASSIGN ARE ONE WRITER: captain_assign_apply(p_player_id,
--     p_captain_instance_id, p_main_ship_id) — p_main_ship_id NOT NULL = ASSIGN, NULL = UNASSIGN.
--     One sole writer per table covers ALL mutations of that table (insert AND delete); two
--     writer functions would be two writers.
-- (3) THE WRITER OWNS STRUCTURAL INVARIANTS ONLY, rejecting — never clamping: captain ownership
--     (captain_instances.player_id = p_player_id), ship ownership on ASSIGN read by the
--     (main_ship_id, player_id) PAIR — never "the player's ship" singular, the player_id UNIQUE
--     was dropped in 0079 (multi-ship) — one-ship-per-captain (the PK + an explicit
--     `already_assigned` reject NAMING the current ship rather than silently re-homing the
--     captain; the PK backstops it), and the HEADCOUNT HARD CAP: count(*) of the ship's existing
--     assignments must be < main_ship_instances.captain_slots, else raise — the captain analogue
--     of the Σ slot_cost ≤ module_slots gate (0112:144–156 / 0044:112–115), using count because
--     slice A locked one-captain-one-slot (captain_slots is a headcount, not a point budget; NO
--     slot_cost exists). OWNER-CONSISTENCY: the stored player_id equals both the captain
--     instance's owner and the ship's owner — the same guarantee fitting_apply provides that
--     later lets the adapter join the ship's assignment set without a player filter
--     (0115:47–50).
--     GAME-RULE checks deliberately do NOT live here (LOCKED DECISION): the
--     `captain_assignment_enabled` dark gate, the settled-SAFE spatial rule (ship must be
--     home/at_location — the 0114 layer), and receipt-keyed idempotency all belong to the later
--     COMMAND slice, exactly as P14 split 0112 (structure) from 0113/0114 (command + game rule).
--     Until that command slice exists NOTHING can call this writer (service_role-only), so the
--     system stays inert AND dark.
-- (4) RACE SAFETY (the exact 0112:99–103 idiom, captain domain): the per-player
--     pg_advisory_xact_lock(hashtext('captain_assignment'), hashtext(p_player_id::text)) is
--     taken FIRST, serializing ALL of a player's assignment mutations. Every assignment on a
--     ship belongs to the ship's owner (owner-consistency above), so the headcount read under
--     this lock cannot be raced by another mutation of the same ship — the count → insert window
--     is single-writer by construction.
-- (5) ERROR STYLE — exception-style (LOCKED DECISION for this slice), the 0039/0108
--     internal-leaf idiom, NOT 0112's {ok:false, reason} envelopes: every rejection RAISES with
--     a stable reason-prefixed message (captain_not_owned / ship_not_owned / already_assigned /
--     captain_slots_full / not_assigned). This is a deliberate, documented deviation from
--     fitting_apply, not drift; the later command slice translates raised reasons into its
--     client envelopes (the wrapper mapper idiom, 0113) instead of passing envelopes through.
--     Success returns nothing — the command layer composes its own success envelope.
--
-- ── SOLE-WRITER LAW (docs/SYSTEM_BOUNDARIES.md, synced this same step) ────────────────────────────
-- captain_assign_apply() below is THE sole writer of ship_captain_assignments — every mutation
-- (assign AND unassign), from the future command slice or ANY other path, goes through this
-- function. No second insert/update/delete path, ever. Validation failures write nothing.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): ship_captain_assignments →
-- Captain (sole writer = captain_assign_apply, service_role-only, called by NOTHING yet); the §2
-- Captain row now names the table + writer. Edges all DOWNWARD, acyclic: Captain → Main Ship
-- (read main_ship_instances ownership + captain_slots — the system's FIRST cross-system edge,
-- read-only) · its own captain_types/captain_instances (intra-system). No system depends on
-- Captain; the Phase-15 adapter slice will later add the Expedition-stats → Captain downward READ
-- edge (the 0115 precedent). No flag flipped; 0001–0118 unedited.

-- ── 1) ship_captain_assignments — which captain instance serves on which ship (Captain-owned) ─────
create table public.ship_captain_assignments (
  -- the PK IS the one-ship-per-captain invariant: a captain instance appears at most once.
  captain_instance_id uuid primary key references public.captain_instances (id) on delete cascade,
  main_ship_id        uuid not null references public.main_ship_instances (main_ship_id) on delete cascade,
  player_id           uuid not null references auth.users (id) on delete cascade,
  assigned_at         timestamptz not null default now()
);
-- per-ship assignment-set lookups (the headcount cap + the future adapter read, 0115:162–167):
create index ship_captain_assignments_ship_idx
  on public.ship_captain_assignments (main_ship_id);

-- Own-row read only (the 0108/0112 posture verbatim): RLS on, one owner-select policy, select
-- granted to authenticated; NO insert/update/delete policy and NO write grant — the sole writer
-- is captain_assign_apply() below (SECURITY DEFINER, service_role only), whose only future caller
-- is DARK behind captain_assignment_enabled=false. NOTHING calls it yet.
alter table public.ship_captain_assignments enable row level security;
create policy "ship_captain_assignments_select_own" on public.ship_captain_assignments
  for select using (player_id = auth.uid());
grant select on public.ship_captain_assignments to authenticated;

comment on table public.ship_captain_assignments is
  'CAPTAIN-P15: which captain instance serves on which main ship. The captain_instance_id PK IS '
  'the invariant: one captain is assigned to at most one ship, ever. Sole writer = '
  'captain_assign_apply() (ASSIGN and UNASSIGN through the ONE function; service_role only); it '
  'enforces owner-consistency and the count(*) < captain_slots headcount hard cap (one captain = '
  'one slot; no slot_cost). Players read only their own rows. Feature DARK behind '
  'captain_assignment_enabled; no caller exists yet.';

-- ── 2) captain_assign_apply — THE one writer of ship_captain_assignments (internal) ──────────────
create or replace function public.captain_assign_apply(
  p_player_id           uuid,
  p_captain_instance_id uuid,
  p_main_ship_id        uuid  -- NOT NULL = ASSIGN to this ship · NULL = UNASSIGN
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_captain     captain_instances%rowtype;
  v_ship_owner  uuid;
  v_slots_limit integer;
  v_used        integer;
  v_current     uuid;
  v_prev_ship   uuid;
begin
  -- 1) per-player serialization FIRST (the exact 0112:99–103 idiom, captain domain): ALL of a
  --    player's assignment mutations queue here, so the headcount below cannot be raced by
  --    another assign/unassign of the same player (and every assignment on a ship belongs to the
  --    ship's owner, so per-player IS per-ship-assignment-set).
  perform pg_advisory_xact_lock(hashtext('captain_assignment'), hashtext(p_player_id::text));

  -- 2) the captain instance must exist AND belong to p_player_id (intra-system read). One reason
  --    for both cases — another player's instance answers exactly like a nonexistent one.
  select * into v_captain from captain_instances
    where id = p_captain_instance_id and player_id = p_player_id;
  if not found then
    raise exception 'captain_assign_apply: captain_not_owned — captain instance % not found for player %',
      p_captain_instance_id, p_player_id;
  end if;

  -- ── UNASSIGN (p_main_ship_id NULL): delete the captain's assignment row ─────────────────────────
  if p_main_ship_id is null then
    delete from ship_captain_assignments
      where captain_instance_id = p_captain_instance_id
      returning main_ship_id into v_prev_ship;
    if v_prev_ship is null then
      -- distinct truthful reason; idempotency ENVELOPES are the future command slice's job
      -- (receipt replay), not this writer's — a bare re-unassign is a real not_assigned here.
      raise exception 'captain_assign_apply: not_assigned — captain instance % has no assignment',
        p_captain_instance_id;
    end if;
    return;
  end if;

  -- ── ASSIGN (p_main_ship_id NOT NULL) ────────────────────────────────────────────────────────────
  -- 3) the target ship is read by the (main_ship_id, player_id) PAIR — never "the player's ship"
  --    singular (the player_id UNIQUE was dropped in 0079; the 0115:96–101 shape). Also fixes
  --    owner-consistency: row.player_id = captain owner = ship owner (0115:47–50).
  select player_id, captain_slots into v_ship_owner, v_slots_limit
    from main_ship_instances where main_ship_id = p_main_ship_id;
  if v_ship_owner is null or v_ship_owner <> p_player_id then
    raise exception 'captain_assign_apply: ship_not_owned — ship % not found for player %',
      p_main_ship_id, p_player_id;
  end if;

  -- 4) one-ship-per-captain: an already-assigned captain is REJECTED naming its current ship —
  --    never silently re-homed (an explicit unassign must come first). The PK backstops this
  --    check.
  select main_ship_id into v_current from ship_captain_assignments
    where captain_instance_id = p_captain_instance_id;
  if v_current is not null then
    raise exception 'captain_assign_apply: already_assigned — captain instance % is assigned to ship %',
      p_captain_instance_id, v_current;
  end if;

  -- 5) HEADCOUNT HARD CAP (the captain analogue of the Σ slot_cost ≤ module_slots gate,
  --    0112:144–156 / 0044:112–115 — reject, NEVER clamp): count, not a slot_cost sum, because
  --    one captain occupies exactly one slot (slice-A locked decision; captain_slots is a
  --    headcount). Race-free under the step-1 player lock (see header (4)).
  select count(*) into v_used from ship_captain_assignments
    where main_ship_id = p_main_ship_id;
  if v_used >= v_slots_limit then
    raise exception 'captain_assign_apply: captain_slots_full — ship % has % of % captain slots occupied',
      p_main_ship_id, v_used, v_slots_limit;
  end if;

  -- 6) the ONE mutation. Plain insert: the PK cannot conflict here — step 4 ran under the step-1
  --    lock, and only the owner (serialized above) can reference this captain.
  insert into ship_captain_assignments (captain_instance_id, main_ship_id, player_id)
    values (p_captain_instance_id, p_main_ship_id, p_player_id);
end;
$$;

-- ── 3) ACL (anti-cheat; the 0108:108–113 relock idiom verbatim — the 0064-era default-privileges
--       revoke already denies new functions, this re-asserts explicitly). No existing grant touched.
-- the ONE writer stays OFF the client surface (internal; server-side callers only — none exist yet):
revoke execute on function public.captain_assign_apply(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.captain_assign_apply(uuid, uuid, uuid) to service_role;
