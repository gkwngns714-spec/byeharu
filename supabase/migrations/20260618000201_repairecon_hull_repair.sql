-- Byeharu — REPAIR-ECON (P9 / gap G8): the paid hull-repair economy, DARK behind repair_economy_enabled.
--
-- Queue slice P9 of the full-capacity plan (FULL_CAPACITY_PLAN.md §C P9 "REPAIR-ECON"; §A gap G8 "No
-- repair economy: repair_main_ship is the free/instant safelock, 0052, flagged as temporary"). The
-- game's design law (ROADMAP §"Main Ship Repair & Recovery"): ships come home DAMAGED (not deleted);
-- repair is the recovery loop. This slice adds the FIRST real repair ECONOMY: pay credits, at a port,
-- to mend a ship's HULL — everything DARK behind the NEW `repair_economy_enabled` flag (seeded false).
--
-- ── THE SEAM — do NOT break the destroyed-ship safelock (G8 is explicit) ──────────────────────────
-- Two DISTINCT recovery paths, never conflated:
--   • DESTROYED (status='destroyed', hp 0) → the FREE, INSTANT safelock `repair_main_ship()` (true
--     head 0052; re-created VERBATIM-else-branch by 0199 for the NO-HOME dock-in-place path — the
--     current live head). G8 says the ECONOMY is what's missing, NOT that destroyed-recovery should
--     cost — the no-progress-loss guarantee (never a permanent account lock) must survive. This slice
--     LEAVES repair_main_ship 100% UNTOUCHED (no re-create — a NEW additive RPC, so the live safelock
--     function is not even in the diff).
--   • DAMAGED-BUT-ALIVE (hp < max_hp, not destroyed) → the NEW PAID hull repair below,
--     `repair_ship_hull_at_port`, DARK behind repair_economy_enabled. A destroyed ship is REJECTED by
--     this RPC (reason ship_destroyed → "use the free recovery") so the two paths can never overlap.
--
-- ── v1 SCOPE (deliberate; the honest-minimal slice — richer model is the documented follow-up) ────
-- HULL only. Not shield: shield SELF-REGENS (0195/0197 shield tick + regen) — paying to top up a bar
-- that refills for free is a non-feature; the directive's "hull is the point". CREDITS only, INSTANT
-- at-port. FULL_CAPACITY_PLAN P9 RR-1 sketches a FULLER model (credits + repair_parts materials +
-- duration via the reused M4.5 build-queue); MAINSHIP_TRANSITION §13 lists cost (materials/currency/
-- service fee) AND server-authoritative duration as OPEN design questions. v1 intentionally ships the
-- simplest honest surface — credits-only, instant — behind the SAME flag, so the RR-1 materials +
-- repair-time model slots in as a follow-up (a re-create of THIS new RPC, never the live safelock)
-- with no player-visible break. Follow-up knobs noted [D] below.
--
-- ── COST MODEL ([D] owner-tunable; a retune is a one-row set_game_config write, no deploy) ────────
--   total_credits = hp_restored × `repair_credits_per_hp`   (charge for what you FIX — proportional
--   to hp missing on a full mend; to hp requested on a partial). Seeded conservatively:
--     repair_credits_per_hp = 0.5 [D]  → a full 500-hp rebuild of the starter Frigate = 250 credits
--     (exactly one ship's commissioning price — thematically "as much as a new hull"); a ~120-hp
--     combat dent = 60 credits (a single Snare-run's salvage, 0174's 30..80 band) — real recovery
--     cost that a hunt pays for, never a wall. Wallet is numeric (0093), so a fractional total is
--     legal (the trade-price precedent); a rounding policy is a [D] follow-up if whole-credit display
--     is wanted. FOLLOW-UP [D] knobs (NOT seeded here — RR-1-full): repair_parts_per_hp (materials),
--     repair_seconds_per_hp (the M4.5-queue duration model).
--
-- ── OWNERSHIP (SYSTEM_BOUNDARIES rows land in THIS PR — the §E law) ───────────────────────────────
--   • repair_receipts = Repair Economy: sole writer = `repair_ship_hull_at_port` (this migration).
--                       Owner-read via the owning ship (the salvage_receipts/trade_receipts posture).
--   • main_ship_instances.hp: the new RPC becomes an ADDITIONAL authorized writer of hp (alongside
--     combat-settle sync, repair_main_ship, the reconcilers) — a credit-gated heal, never a create.
--   • player_wallet: debited ONLY through Wallet's own `wallet_debit` (0093) — never a direct write.
-- WHY A NEW RECEIPTS TABLE (not salvage/trade_receipts): those FK item_id/good_id and CHECK side —
-- a repair has neither. Rather than weaken a live table's FK (a parity hazard for zero gain), repair
-- gets its own receipts table with the IDENTICAL idempotency shape: (main_ship_id, request_id) unique.
--
-- Forward-only: 0001–0200 unedited. repair_main_ship / dev_set_main_ship_destroyed UNTOUCHED (the
-- safelock is preserved, not edited — the G8 mandate). No live plpgsql re-created (no parity risk).

-- ── 1) the dark capability gate + the cost knob — seeded (the 0174 idiom; knob is the cfg_num shape) ──
insert into public.game_config (key, value, description) values
  ('repair_economy_enabled', 'false',
   'REPAIR-ECON (0201): server-authoritative dark gate for the PAID hull-repair economy '
   '(repair_ship_hull_at_port — pay credits at a port to mend a DAMAGED-but-alive ship''s hull). '
   'OFF until the owner flips it (scripts/activate-repair-econ.sql). The repair RPC checks this FIRST '
   'and rejects (repair_economy_disabled) before any read while false; the RepairPanel renders '
   'nothing. The FREE destroyed-ship safelock (repair_main_ship) is UNAFFECTED — recovery is never '
   'gated (0052 guarantee).'),
  ('repair_credits_per_hp', '0.5',
   'REPAIR-ECON (0201): [D] owner-tunable credits charged per hull HP restored by '
   'repair_ship_hull_at_port. Seeded 0.5 → a full 500-hp Frigate rebuild = 250 credits (one ship''s '
   'price); a ~120-hp dent = 60 credits (a Snare-run salvage). A retune is a one-row set_game_config '
   'write (no deploy). Read via cfg_num at repair time; the client reads it public for cost DISPLAY '
   'only (the server recomputes the authoritative charge under the per-ship lock).')
on conflict (key) do nothing;

-- ── 2) repair_receipts — the per-ship idempotent repair record (the 0174 salvage_receipts shape) ──
create table if not exists public.repair_receipts (
  receipt_id     uuid    primary key default gen_random_uuid(),
  main_ship_id   uuid    not null references public.main_ship_instances (main_ship_id),  -- NEVER player_id
  request_id     uuid    not null,
  location_id    uuid    references public.locations (id),        -- the port the repair occurred at
  hp_before      integer not null check (hp_before >= 0),         -- hull hp at repair time (pre)
  hp_after       integer not null check (hp_after  >= 0),         -- hull hp after the mend (<= max_hp)
  hp_restored    integer not null check (hp_restored > 0),        -- hp_after - hp_before (> 0: a no-op never writes)
  credits_per_hp numeric not null check (credits_per_hp >= 0),    -- the knob value at repair time
  total_price    numeric not null check (total_price >= 0),       -- hp_restored × credits_per_hp at repair time
  created_at     timestamptz not null default now(),
  unique (main_ship_id, request_id)                               -- per-ship idempotency key (0174 §4)
);
create index if not exists repair_receipts_main_ship_id_idx on public.repair_receipts (main_ship_id);

alter table public.repair_receipts enable row level security;
-- Owner-read via join to the owning ship (the salvage_receipts 0174 posture); authenticated, NOT
-- anon. NO client write policy/grant → repair_ship_hull_at_port (SECURITY DEFINER) is the sole writer.
create policy "repair_receipts_select_own" on public.repair_receipts
  for select using (
    exists (
      select 1 from public.main_ship_instances m
      where m.main_ship_id = repair_receipts.main_ship_id
        and m.player_id = auth.uid()
    )
  );
grant select on public.repair_receipts to authenticated;

-- ── 3) repair_ship_hull_at_port — the paid hull-repair orchestrator (the 0174 sell_item_at_port mold) ──
-- Atomic + idempotent, all in ONE function/transaction under the per-ship lock. Fan-out is
-- one-directional DOWNWARD: Main Ship (resolve/lock/dock, read-only) → Reference/Config
-- (cfg_num knob) → Wallet (wallet_debit — the ONE player_wallet writer, exactly the 0138 market edge)
-- → Main Ship hp write (its own damaged-alive heal) → its own repair_receipts. NO other table written.
--
-- REJECT ORDER (the charter envelope order; each named): not_authenticated →
-- repair_economy_disabled (gate FIRST, before ANY read) → invalid_request → invalid_amount (hull hp
-- is INTEGER — main_ship_instances.hp is integer, 0043 — so null/non-positive/fractional is invalid,
-- not rounded; the 1e6 magnitude cap keeps the integer cast safe) → ship_not_found → ship_destroyed
-- (THE SAFELOCK SEAM — a destroyed ship must use the FREE repair_main_ship, never this paid path) →
-- not_docked → idempotent_replay → nothing_to_repair (already at full hull) → repair_misconfigured
-- (knob absent/non-positive) → insufficient_credits (wallet_debit false — too poor, NOTHING written)
-- → ok. p_repair_hp is the hp the player WANTS restored; it is CLAMPED to the actual missing hull
-- (least(request, missing)) so an over-request tops up to max_hp and never over-charges — you always
-- pay for exactly the hp restored (the receipt pins it). All-or-nothing: any raise/false rolls the
-- whole txn back — no partial debit, no partial heal, no receipt.
create or replace function public.repair_ship_hull_at_port(
  p_main_ship_id uuid, p_repair_hp numeric, p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     public.main_ship_instances%rowtype;
  v_ship_id  uuid;
  v_loc      uuid;
  v_existing public.repair_receipts%rowtype;
  v_want     integer;
  v_missing  integer;
  v_restore  integer;
  v_per_hp   numeric;
  v_total    numeric;
  v_after    integer;
  v_receipt  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject: reject deterministically BEFORE any ship/knob read. Flag false (production
  -- today) → no ship read, no wallet touch, no heal — the deploy-inert guarantee.
  if not public.cfg_bool('repair_economy_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'repair_economy_disabled');
  end if;

  -- input validation. Hull hp is INTEGER (0043 main_ship_instances.hp integer): null/non-positive/
  -- fractional all reject as invalid_amount (never rounded); the 1e6 cap keeps the integer cast safe.
  if p_request_id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_request'); end if;
  if p_repair_hp is null or p_repair_hp <= 0 or p_repair_hp <> floor(p_repair_hp) or p_repair_hp > 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  v_want := p_repair_hp::integer;

  -- resolve the SELECTED owned ship (ownership asserted) or the sole ship (shim); UI never trusted.
  v_ship_id := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship_id is null then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;

  -- PER-SHIP LOCK (0138 idiom) acquired BEFORE the hull read: held to txn end, so the row read below,
  -- the replay + missing-hp compute, and the debit/heal/receipt writes are all one race-safe critical
  -- section against concurrent repairs on the SAME ship (a stale pre-lock hp could over-heal/mis-charge).
  perform public.mainship_space_lock_context(v_ship_id);
  select * into v_ship from public.main_ship_instances where main_ship_id = v_ship_id;

  -- THE SAFELOCK SEAM: a DESTROYED ship (status='destroyed', hp 0) is NOT a paid-repair subject —
  -- it recovers through the FREE, never-gated repair_main_ship() safelock (0052/0199). Reject here
  -- so the paid path can never touch a destroyed ship (and never charge for the safelock's job).
  if v_ship.status = 'destroyed' then
    return jsonb_build_object('ok', false, 'reason', 'ship_destroyed');
  end if;

  -- DOCKED check via the ONE shared resolver (0092 — never inlined, never the client): the ship must
  -- be canonically at_location (the settled-safe rule). A destroyed ship (spatial_state NULL, 0059)
  -- also fails this, but the explicit ship_destroyed above gives the honest reason first.
  v_loc := public.mainship_resolve_docked_location(v_ship_id);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- IDEMPOTENCY: a receipt for (ship, request_id) already exists → replay verbatim, no write, no
  -- re-debit, no re-heal (the 0174 salvage-receipts semantics; no payload-conflict check).
  select * into v_existing from public.repair_receipts
    where main_ship_id = v_ship_id and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'main_ship_id', v_ship_id,
      'hp_before', v_existing.hp_before, 'hp_after', v_existing.hp_after,
      'hp_restored', v_existing.hp_restored, 'credits_per_hp', v_existing.credits_per_hp,
      'total_price', v_existing.total_price, 'location_id', v_existing.location_id);
  end if;

  -- MISSING hull (re-read under the lock via the row already fetched — hp cannot change under our
  -- lock; recompute from v_ship for clarity). Nothing to mend → reject (no zero-hp receipt: the
  -- hp_restored > 0 CHECK would reject one anyway, but the friendly reason comes first).
  if v_ship.max_hp is null or v_ship.max_hp <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');  -- defensive: bad hull row
  end if;
  v_missing := v_ship.max_hp - v_ship.hp;
  if v_missing <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_repair',
      'hp', v_ship.hp, 'max_hp', v_ship.max_hp);
  end if;

  -- CLAMP the request to the actual missing hull: over-request tops up to max_hp, never over-charges.
  v_restore := least(v_want, v_missing);

  -- COST knob (Reference/Config; cfg_num). Absent/non-positive → misconfig (the seed guarantees it,
  -- but a bad manual retune must fail closed, never heal for free).
  v_per_hp := public.cfg_num('repair_credits_per_hp');
  if v_per_hp is null or v_per_hp <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'repair_misconfigured');
  end if;
  v_total := v_restore * v_per_hp;
  v_after := v_ship.hp + v_restore;

  -- WALLET debit (atomic conditional; false → too poor → NOTHING healed/receipted — the 0138 law).
  if not public.wallet_debit(v_player, v_total) then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_credits',
      'price', v_total, 'hp_restored', v_restore, 'credits_per_hp', v_per_hp);
  end if;

  -- HEAL the hull (Main Ship writes its own hp — a credit-gated damaged-alive mend; never a create,
  -- never touches status/spatial/fleets). An exception here aborts the WHOLE txn: the debit above
  -- rolls back too, no receipt — all-or-nothing.
  update public.main_ship_instances
    set hp = v_after, updated_at = now()
    where main_ship_id = v_ship_id;

  -- RECEIPT (Repair Economy writes repair_receipts directly — its own table; the
  -- (main_ship_id, request_id) key finalizes idempotency atomically with the debit + heal).
  insert into public.repair_receipts
    (main_ship_id, request_id, location_id, hp_before, hp_after, hp_restored, credits_per_hp, total_price)
    values (v_ship_id, p_request_id, v_loc, v_ship.hp, v_after, v_restore, v_per_hp, v_total)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt, 'main_ship_id', v_ship_id,
    'hp_before', v_ship.hp, 'hp_after', v_after, 'hp_restored', v_restore,
    'credits_per_hp', v_per_hp, 'total_price', v_total, 'location_id', v_loc);
end;
$$;
-- ACL: authenticated client RPC (server-rejected while dark — the 0174 posture); anon/public never.
revoke execute on function public.repair_ship_hull_at_port(uuid, numeric, uuid) from public, anon;
grant  execute on function public.repair_ship_hull_at_port(uuid, numeric, uuid) to authenticated;

-- ── 4) Self-assert: the flag is dark, the knob is sane, the safelock is UNTOUCHED, seam is clean ──
do $$
declare v_src text;
begin
  -- 1. the gate exists and is FALSE (dark) at seed time.
  if public.cfg_bool('repair_economy_enabled') then
    raise exception 'REPAIR-ECON self-assert FAIL: repair_economy_enabled is not false at seed time';
  end if;

  -- 2. the cost knob exists and is sane (> 0) — a repair can never heal for free by a missing knob.
  if public.cfg_num('repair_credits_per_hp') is null or public.cfg_num('repair_credits_per_hp') <= 0 then
    raise exception 'REPAIR-ECON self-assert FAIL: repair_credits_per_hp missing or non-positive (%)',
      public.cfg_num('repair_credits_per_hp');
  end if;

  -- 3. THE SAFELOCK SEAM: the FREE recovery path repair_main_ship is UNTOUCHED by this migration and
  --    still gates ONLY on status='destroyed' (never on repair_economy_enabled — recovery is never
  --    gated, the 0052 guarantee). The paid RPC is a SEPARATE function; the two never overlap.
  select prosrc into v_src from pg_proc
    where oid = to_regprocedure('public.repair_main_ship(uuid)')::oid;
  if v_src is null then
    raise exception 'REPAIR-ECON self-assert FAIL: the free safelock repair_main_ship(uuid) is missing';
  end if;
  if position('repair_economy_enabled' in v_src) <> 0 then
    raise exception 'REPAIR-ECON self-assert FAIL: repair_main_ship references repair_economy_enabled (the safelock must stay UNGATED)';
  end if;
  if position('ship is not disabled' in v_src) = 0 then
    raise exception 'REPAIR-ECON self-assert FAIL: repair_main_ship lost its destroyed-only guard (the safelock changed)';
  end if;

  -- 4. the NEW paid RPC exists with the real signature and rejects gate-first while dark.
  if to_regprocedure('public.repair_ship_hull_at_port(uuid, numeric, uuid)') is null then
    raise exception 'REPAIR-ECON self-assert FAIL: repair_ship_hull_at_port(uuid,numeric,uuid) missing';
  end if;

  raise notice 'REPAIR-ECON self-assert ok: gate dark; repair_credits_per_hp % sane; free safelock repair_main_ship UNTOUCHED + ungated + destroyed-only; new paid RPC present (gate-first while dark)',
    public.cfg_num('repair_credits_per_hp');
end $$;
