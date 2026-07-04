-- Byeharu — CAPTAIN-P15 SLICE B: the captain_instances schema + the single Captain mint writer
-- (table + RLS + ONE internal function ONLY; no assignment table, no receipts, no commands, no
-- read surface, no frontend; the feature stays fully DARK behind captain_assignment_enabled=false
-- from 0117 — NOTHING client-reachable can write this table, and no caller of the mint writer
-- exists yet).
--
-- Mirrors the P13 instances slice (0108 module_instances / modules_mint_instance) exactly,
-- deviating ONLY where the Phase-15 locked decisions require it (0117 header / DEV_LOG 2026-07-04
-- CAPTAIN-P15 SLICE A):
--
-- (1) INSTANCES ARE INDIVIDUAL ROWS, NEVER COUNTS (the same law ROADMAP :88 set for modules,
--     carried into Phase 15 "Captain instances + assignment", ROADMAP :90): one captain = one
--     captain_instances row, individually addressed by uuid, exactly like module_instances
--     modules and main_ship_instances ships are never fungible counts. NO quantity column exists
--     by design.
-- (2) NO ASSIGNMENT COLUMNS: assigned_ship_id / slot state / stat wiring belong to the later
--     assignment slices (the assignment junction table with its own sole writer — the
--     ship_module_fittings shape — and the adapter feed) and arrive FORWARD-ONLY there. Phase-15
--     slice-B instances sit unassigned in the player's possession.
-- (3) THE IDEMPOTENCY SPINE is mint_key (text, NOT NULL UNIQUE): the mint writer inserts
--     `on conflict (mint_key) do nothing` and on conflict returns the EXISTING instance id for
--     that key — true idempotent replay, the 0108:95–104 idiom (itself the inventory_deposit
--     ledger-insert-is-the-guard semantics, 0039:85–90). The same key can NEVER mint twice.
--     Key NAMESPACING is the caller's contract: each future producer derives its keys from its
--     own idempotency state, so distinct commands can never collide on a key.
-- (4) LOCKED DECISION — NO ACQUISITION PATH IS BUILT IN THIS SLICE: nothing calls
--     captains_mint_instance yet. It is the future downward leaf for whatever grants captains
--     (Phase-16 progression consuming inventory, or a later dark grant command), exactly as
--     modules_mint_instance (0108) predated its craft command (0109) by one slice. The system is
--     therefore inert AND dark: no client-reachable surface exists, and the flag (0117) is
--     'false' besides.
--
-- ── SOLE-WRITER LAW (docs/SYSTEM_BOUNDARIES.md, synced this same step) ────────────────────────────
-- captains_mint_instance() below is THE ONE writer of captain_instances. EVERY future producer of
-- captain instances — the Phase-16 progression path AND any earlier dark grant command — must mint
-- THROUGH this function and nothing else. No second insert path, ever. It is an INTERNAL LEAF
-- function (service_role only, exception-style errors like Inventory's and Modules' writers —
-- 0039/0108), not a player envelope RPC; player-facing envelopes belong to the commands that will
-- call it.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): captain_instances → Captain
-- (sole writer = captains_mint_instance; owner-read), and the §2 Captain system row is added NOW —
-- the system has its first writer, so the row is real (the 0108 precedent: Modules' §2 row arrived
-- with its mint writer). No new cross-system edge: nothing calls the mint helper yet, and the
-- helper itself reads only Captain's own catalog (captain_types — a downward, intra-system read).
-- No flag flipped; 0001–0117 unedited.

-- ── 1) captain_instances — per-player captain instances (Captain-owned) ───────────────────────────
create table public.captain_instances (
  id              uuid primary key default gen_random_uuid(),
  player_id       uuid not null references auth.users (id) on delete cascade,
  captain_type_id text not null references public.captain_types (id),
  -- the idempotency spine: producer-derived key; the unique constraint IS the replay guard
  -- (the 0108 mint_key idiom — NOT NULL, every mint is keyed).
  mint_key        text not null unique,
  created_at      timestamptz not null default now()
);
-- player roster ordering (the 0108:53–54 player-index idiom; serves the future read-surface slice)
create index captain_instances_player_idx
  on public.captain_instances (player_id, created_at desc);

-- Own-row read only (the 0108:60–63 shape); NO insert/update/delete policy and NO write grant —
-- the sole writer is captains_mint_instance() below (SECURITY DEFINER, service_role only), and
-- NOTHING calls it yet (locked decision (4)); the feature is dark behind
-- captain_assignment_enabled=false besides.
alter table public.captain_instances enable row level security;
create policy "captain_instances_select_own" on public.captain_instances
  for select using (player_id = auth.uid());
grant select on public.captain_instances to authenticated;

comment on table public.captain_instances is
  'CAPTAIN-P15: per-player captain instances — INDIVIDUAL rows, never counts (no quantity column '
  'by design). Sole writer = captains_mint_instance() (idempotent by mint_key; service_role '
  'only); every future producer — Phase-16 progression or a later dark grant command — must mint '
  'through it. No assignment columns: assignment is a later Phase-15 slice. Players read only '
  'their own rows. Feature DARK behind captain_assignment_enabled; no caller exists yet.';
comment on column public.captain_instances.mint_key is
  'Producer-derived idempotency key (NOT NULL UNIQUE — the replay guard). A replayed key returns '
  'the existing instance id instead of minting twice. Key namespacing is the producer''s '
  'contract (no producer exists yet — locked decision (4)).';

-- ── 2) captains_mint_instance — THE one writer of captain_instances (internal leaf) ───────────────
create or replace function public.captains_mint_instance(p_player_id uuid, p_captain_type_id text, p_mint_key text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  -- exception-style errors (the 0039/0108 internal-leaf idiom — this is not a player envelope
  -- RPC; future callers translate into their own client envelopes):
  if p_mint_key is null or p_mint_key = '' then
    raise exception 'captains_mint_instance: mint key is required';
  end if;
  if not exists (select 1 from captain_types where id = p_captain_type_id) then
    raise exception 'captains_mint_instance: unknown captain type %', p_captain_type_id;
  end if;

  -- Idempotency: the unique mint_key insert is the guard (0108:95–104 semantics). A duplicate key
  -- mints nothing and returns the EXISTING instance id for that key — true idempotent replay.
  insert into captain_instances (player_id, captain_type_id, mint_key)
    values (p_player_id, p_captain_type_id, p_mint_key)
    on conflict (mint_key) do nothing
    returning id into v_id;
  if v_id is null then
    select id into v_id from captain_instances where mint_key = p_mint_key;  -- already minted
  end if;
  return v_id;
end;
$$;

-- ── 3) ACL (anti-cheat; the targeted idiom, verbatim from 0108:108–113 — the 0064-era
--       default-privileges revoke already denies new functions, this re-asserts explicitly).
--       No existing grant is touched.
-- the mint writer stays OFF the client surface (internal leaf; server-side callers only):
revoke execute on function public.captains_mint_instance(uuid, text, text) from public, anon, authenticated;
grant  execute on function public.captains_mint_instance(uuid, text, text) to service_role;
