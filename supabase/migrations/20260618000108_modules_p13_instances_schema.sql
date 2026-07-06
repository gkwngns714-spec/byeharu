-- Byeharu — MODULES-P13 SLICE B: the module_instances schema + the single Modules mint writer
-- (table + RLS + ONE internal function ONLY; no craft command, no receipts table, no read surface,
-- no frontend; the feature stays fully DARK behind module_crafting_enabled=false from 0107 —
-- NOTHING client-reachable can write this table, and no caller of the mint writer exists yet).
--
-- Mirrors the P11/P12 player-state schema slices (0098 exploration_discoveries / 0103
-- mining_extractions) and the 0039 Inventory writer pattern, deviating ONLY where the locked
-- Phase-13 decisions require it (0107 header / DEV_LOG 2026-07-04 MODULES-P13 SLICE A):
--
-- (1) INSTANCES ARE INDIVIDUAL ROWS, NEVER COUNTS (the Phase 13 law — ROADMAP :88 "instances, not
--     stack-only"): one crafted module = one module_instances row, individually addressed by uuid,
--     exactly like main_ship_instances ships are never fungible counts. NO quantity column exists
--     by design.
-- (2) NO FITTING COLUMNS: fitted_ship_id / slot assignment / stat wiring are Phase 14's job
--     (`fit_module_to_ship` feeding calculate_expedition_stats) and arrive FORWARD-ONLY there.
--     Phase 13 instances sit unattached in the player's possession.
-- (3) THE IDEMPOTENCY SPINE is mint_key (text, NOT NULL UNIQUE): the mint writer inserts
--     `on conflict (mint_key) do nothing` and on conflict returns the EXISTING instance id for
--     that key — true idempotent replay, mirroring inventory_deposit(p_key)'s
--     ledger-insert-is-the-guard semantics (0039:85–90). The same key can NEVER mint twice.
--     Key NAMESPACING is the caller's contract: each producer derives its keys from its own
--     idempotency state (the slice-C craft command will derive them from its player-scoped
--     receipts, e.g. one key per committed craft receipt), so distinct commands can never collide
--     on a key.
--
-- ── SOLE-WRITER LAW (docs/SYSTEM_BOUNDARIES.md, synced this same step) ────────────────────────────
-- modules_mint_instance() below is THE ONE writer of module_instances. EVERY future producer of
-- module instances — the Phase-13 craft command (a Production-system RPC, per locked decision 1)
-- AND any future build_orders serial-queue completion path (the recorded M4.5 retirement note:
-- when module production later moves onto the queue, its completion MUST call this same helper) —
-- must mint THROUGH this function and nothing else. No second insert path, ever. It is an
-- INTERNAL LEAF function (service_role only, exception-style errors like Inventory's writers —
-- 0039), not a player envelope RPC; player-facing envelopes belong to the commands that call it.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): module_instances → Modules
-- (sole writer = modules_mint_instance; owner-read). The §1/§2 "no runtime writer yet" notes from
-- 0107 are replaced by this now-true fact. No new cross-system edge: nothing calls the mint helper
-- yet, and the helper itself reads only Modules' own catalog (module_types — a downward,
-- intra-system read). No flag flipped; 0001–0107 unedited.

-- ── 1) module_instances — per-player crafted module instances (Modules-owned) ─────────────────────
create table public.module_instances (
  id             uuid primary key default gen_random_uuid(),
  player_id      uuid not null references auth.users (id) on delete cascade,
  module_type_id text not null references public.module_types (id),
  -- the idempotency spine: producer-derived key; the unique constraint IS the replay guard
  -- (0039 inventory_ledger.idempotency_key idiom, but NOT NULL — every mint is keyed).
  mint_key       text not null unique,
  created_at     timestamptz not null default now()
);
-- player inventory-of-instances ordering (the 0098/0103 player-index idiom; serves the future
-- read-surface slice)
create index module_instances_player_idx
  on public.module_instances (player_id, created_at desc);

-- Own-row read only (0015 reward_grants_select_own idiom, via 0098/0103); NO insert/update/delete
-- policy and NO write grant — the sole writer is modules_mint_instance() below (SECURITY DEFINER,
-- service_role only), and its only future callers are DARK behind module_crafting_enabled=false.
-- NOTHING calls it yet.
alter table public.module_instances enable row level security;
create policy "module_instances_select_own" on public.module_instances
  for select using (player_id = auth.uid());
grant select on public.module_instances to authenticated;

comment on table public.module_instances is
  'MODULES-P13: per-player crafted module instances — INDIVIDUAL rows, never counts (one craft = '
  'one instance; no quantity column by design). Sole writer = modules_mint_instance() (idempotent '
  'by mint_key; service_role only); every producer — the Phase-13 craft command and any future '
  'build_orders completion — must mint through it. No fitting columns: attachment is Phase 14. '
  'Players read only their own rows. Feature DARK behind module_crafting_enabled.';
comment on column public.module_instances.mint_key is
  'Producer-derived idempotency key (NOT NULL UNIQUE — the replay guard). A replayed key returns '
  'the existing instance id instead of minting twice. Key namespacing is the producer''s '
  'contract (the craft command derives keys from its own receipts).';

-- ── 2) modules_mint_instance — THE one writer of module_instances (internal leaf) ─────────────────
create or replace function public.modules_mint_instance(p_player uuid, p_module_type text, p_key text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  -- exception-style errors (the 0039 Inventory internal-leaf idiom — this is not a player
  -- envelope RPC; callers translate into their own client envelopes):
  if p_key is null or p_key = '' then
    raise exception 'modules_mint_instance: mint key is required';
  end if;
  if not exists (select 1 from module_types where id = p_module_type) then
    raise exception 'modules_mint_instance: unknown module type %', p_module_type;
  end if;

  -- Idempotency: the unique mint_key insert is the guard (0039:85–90 semantics). A duplicate key
  -- mints nothing and returns the EXISTING instance id for that key — true idempotent replay.
  insert into module_instances (player_id, module_type_id, mint_key)
    values (p_player, p_module_type, p_key)
    on conflict (mint_key) do nothing
    returning id into v_id;
  if v_id is null then
    select id into v_id from module_instances where mint_key = p_key;  -- already minted
  end if;
  return v_id;
end;
$$;

-- ── 3) ACL (anti-cheat; targeted 0083/0095 idiom, verbatim from 0099/0104 — the 0064-era
--       default-privileges revoke already denies new functions, this re-asserts explicitly).
--       No existing grant is touched.
-- the mint writer stays OFF the client surface (internal leaf; server-side callers only):
revoke execute on function public.modules_mint_instance(uuid, text, text) from public, anon, authenticated;
grant  execute on function public.modules_mint_instance(uuid, text, text) to service_role;
