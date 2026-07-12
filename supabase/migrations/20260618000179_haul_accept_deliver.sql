-- Byeharu — HAUL-2: the contract accept/deliver RPCs (+ receipts + the delivery deadline; DARK).
--
-- Queue continuation of the full-capacity plan §C P2 (HAUL-0/1 shipped as 0176): the two player-facing
-- state-transition writers for `haul_contracts` — `haul_accept_contract` (offered→accepted) and
-- `haul_deliver_contract` (accepted→delivered: Trade-Cargo consume + Wallet credit) — plus the
-- `haul_receipts` idempotency table 0176 deliberately deferred, the `deliver_by` delivery deadline, the
-- per-player active-contract cap, and the generator's deadline-cancel pass. Everything stays DARK behind
-- the SAME `haul_contracts_enabled` flag (still 'false'; no flag write here). The bulletin UI (HAUL-3)
-- and the ACT-HAUL flip are LATER slices — no client code in this slice.
--
-- ── OWNERSHIP (SYSTEM_BOUNDARIES rows land in THIS PR — the §E law) ──────────────────────────────
--   · haul_contracts = Haul Contracts. Writers are now COMPLETE and closed: `haul_generate_offers()`
--     (0176 mint + offered-only expiry, re-created here from its 0176 head with ONE marked hunk — the
--     accepted-past-`deliver_by` → 'cancelled' pass) and THESE two RPCs (offered→accepted→delivered).
--     No other system may write here, ever.
--   · haul_receipts  = Haul Contracts: sole writers = these two RPCs (this migration). 0176 shipped NO
--     receipts table (checked: the accept/deliver idempotency was explicitly deferred to HAUL-2, 0176
--     header §"FORWARD NOTES" / the haul_contracts row comment "+ its future receipts"). It mirrors
--     `salvage_receipts` (0174) point-for-point: unique (main_ship_id, request_id) — keyed by ship,
--     NEVER player_id — replay returns the original envelope verbatim; owner-read via the owning ship.
--     ONE table serves BOTH actions (an `action` discriminator) so a ship's request_id namespace is a
--     single idempotency domain — a reused request id replays whatever it originally did (the 0086
--     trade-receipts semantics: no payload-conflict check).
--   THE CHARTER GUARD (SYSTEM_BOUNDARIES Haul row, unchanged): cargo moves ONLY through Trade-Cargo's
--   own functions (`trade_cargo_consume` — the ONE FIFO cargo debiter, 0090) and credits ONLY through
--   Wallet (`wallet_credit`, 0090/0093). Accept moves NEITHER (see below). Deliver's fan-out is
--   one-directional DOWNWARD: Main Ship (resolve/lock/dock, read-only) → its own haul_contracts →
--   Trade-Cargo (consume) → Wallet (credit) → its own haul_receipts. NO other table written.
--
-- ── SEMANTICS DECISIONS (each [D]-documented; the plan's "deliver N×good to port B by T for C") ──
--   1. ACCEPT IS A CLAIM, NOT A TRANSACTION. Accepting moves NO cargo and NO credits: the contract is
--      a PROMISE — the player must SOURCE the goods themselves (buy them at the origin market, haul
--      existing cargo, or mine/loot-adjacent future sources). This is exactly what the 0176 reward
--      math prices in: reward > qty × origin.sell ALWAYS (the worth-taking invariant), i.e. the payout
--      covers buying the haul at the origin and still profits.
--   2. ORIGIN-PORT ACCEPT. The bulletin is per-port; accepting requires the resolved ship DOCKED at
--      the contract's origin port (the ONE resolver, 0092/0138). A contract at another port folds into
--      `contract_not_found` — it is simply not on THIS port's board.
--   3. OFFER EXPIRY IS CHECKED AT ACCEPT TOO (fail-closed). The generator's hourly pass flips stale
--      'offered'→'expired' with ≤1h latency; accept does NOT trust that pass — an 'offered' row whose
--      `expires_at` has passed rejects `contract_not_found` here even before the cron flips it.
--   4. ANY-OWNED-SHIP DELIVER. The contract is PLAYER-scoped (`accepted_by`); delivery may use ANY
--      ship the player owns that is docked at the destination and holds the goods. `accepted_ship` is
--      recorded at accept as provenance only — never an enforcement key. (The simplest honest rule:
--      forcing the accepting hull would punish fleet logistics for zero anti-abuse gain — the goods
--      still move only through Trade-Cargo on whichever ship carries them.)
--   5. deliver_by = accepted_at + template duration_seconds — THE DURATION RECONCILIATION. 0176's
--      `duration_seconds` anchored the OFFER pickup window (`expires_at = offered_at + duration`; the
--      0176 schema comment: "offer pickup deadline; the ACCEPTED delivery deadline is HAUL-2's
--      business"). 0176 shipped NO separate delivery window. Decision: reuse the SAME knob as the
--      delivery window — `duration_seconds` is the contract's TEMPO (short 6h staples, long 12h
--      premium runs), symmetric for both windows, one owner-tunable number per template, no reseed. A
--      future template wave can split it with a dedicated column if tuning ever demands it.
--   6. EXPIRY OF ACCEPTED-BUT-UNDELIVERED (the shape decision): the generator is re-created from its
--      0176 head under parity discipline with ONE marked hunk — pass (a2): 'accepted' rows past
--      `deliver_by` flip 'cancelled' (no penalty v1 [D]; cancelling frees the player's active-cap slot
--      because the cap counts status='accepted' only). Chosen over a second cron function: ONE
--      scheduled entrypoint, ONE dark gate, ONE envelope — the cron job stays untouched. The 0176
--      offered-only EXPIRY pass (a) is byte-identical — it still never touches accepted rows; (a2) is
--      the one sanctioned deadline writer. `haul_deliver_contract` REJECTS past-deadline attempts
--      (`deadline_passed`) but never flips the row itself — the cancel transition stays single-path.
--   7. COST BASIS IS CONSUMED AND LOST. `trade_cargo_consume` FIFO-consumes the lots and returns the
--      summed cost basis; a contract delivery has no "sale price" per unit — the reward IS the
--      compensation, and by the 0176 worth-taking invariant it exceeds the origin-market cost of the
--      haul. The fresh envelope reports `cost_basis_consumed` (the market_sell 0090 posture) so the
--      UI can show realized profit; the replay envelope omits it (exactly like trade/salvage replays).
--   8. PER-PLAYER ACTIVE CAP: new knob `haul_max_active_per_player` seeded 3 [D, owner-tunable];
--      counts status='accepted' rows for the player EXCLUDING the contract being (re)accepted — so a
--      RETRY of a successful accept at the cap still reaches the idempotent replay instead of bouncing
--      `too_many_active`. 0 is a legal owner value (= freeze new accepts).
--
-- ── REJECT ORDER (the charter's envelope order; gate-first — the 0174 freshest template) ─────────
--   accept : not_authenticated → haul_contracts_disabled (gate FIRST, before ANY read) →
--            invalid_request → ship_not_found (mainship_resolve_owned_ship) → [per-ship lock] →
--            not_docked (the ONE resolver) → contract_not_found (row FOR UPDATE: missing/terminal
--            status/not at THIS port/offered-but-expired — a null p_contract_id falls out here too) →
--            already_accepted_other (someone else holds it) → too_many_active (cap, excluding this
--            contract) → idempotent_replay (haul_receipts) → already_accepted (held by ME but a FRESH
--            request id — a double-tap with a regenerated request; no write) → ok.
--   deliver: not_authenticated → haul_contracts_disabled → invalid_request → ship_not_found →
--            [per-ship lock] → not_docked → contract_not_found (row missing) → idempotent_replay →
--            contract_not_found (state: not 'accepted' by THIS player — covers foreign/offered/
--            expired/cancelled/re-deliver-with-fresh-request) → wrong_port (docked ≠ dest — the
--            player OWNS this contract, so the honest actionable reason, not a fold) →
--            deadline_passed (past deliver_by; reject-only, see §6) → insufficient_cargo (inline
--            lot-sum pre-check — the market_sell 0090 read idiom; Trade-Cargo has no read leaf and
--            the sole-writer law governs WRITES) → ok (consume → credit → status flip → receipt, all
--            atomic in the one SECURITY DEFINER txn under the per-ship lock).
--   REPLAY PLACEMENT (deliberate, the 0174 charter delta): deliver's replay check sits AFTER
--   not_docked but BEFORE the state/port/deadline/cargo guards — a successful delivery flips the
--   status AND consumes the cargo, so a retry MUST replay before those now-false guards fire (the
--   exact reason salvage puts replay before its balance check). Accept's replay sits after the
--   contract guards per the charter order — a replayed accept from a ship still docked at the origin passes them; one that undocked/moved bounces not_docked/contract_not_found BEFORE the replay (zero-write, the salvage stricter-re-validation posture) (the
--   composite admits accepted-by-me, and the cap excludes this contract); the one stricter edge — a
--   retry AFTER the cron cancelled the contract re-validates first and rejects — is the sanctioned
--   0174 posture (stricter re-validation before replay; never double-writes either way).
--
-- Forward-only: 0001–0178 unedited. The generator re-create supersedes 0176 forward-only (parity
-- discipline: body byte-identical except the marked (a2) hunk + envelope field + declaration).
-- No client code in this slice.

-- ── 1) deliver_by — the accepted contract's delivery deadline (semantics §5) ─────────────────────
alter table public.haul_contracts add column if not exists deliver_by timestamptz;

-- fail-closed shape guard: an 'accepted' row MUST carry a deadline (else it would hold a cap slot
-- forever and the (a2) pass could never free it). The accept RPC always sets it; this pins it.
do $$
begin
  alter table public.haul_contracts add constraint haul_contracts_accepted_has_deliver_by
    check (status <> 'accepted' or deliver_by is not null);
exception
  when duplicate_object then null;  -- idempotent re-apply
end $$;

-- the (a2) cancel pass scans (status, deliver_by); the cap counts (accepted_by, status).
create index if not exists haul_contracts_status_deliver_by_idx on public.haul_contracts (status, deliver_by);
create index if not exists haul_contracts_accepted_by_status_idx on public.haul_contracts (accepted_by, status);

-- ── 2) the per-player active-contract cap knob (seeded; 0107/0174/0176 idiom) ────────────────────
insert into public.game_config (key, value, description) values
  ('haul_max_active_per_player', '3',
   'HAUL-2 (0179): how many contracts a player may hold in status=accepted at once. Accepting past '
   'the cap rejects too_many_active (the count excludes the contract being re-accepted, so replays '
   'at the cap still work). Owner-tunable; 0 freezes new accepts. Delivered/cancelled rows free '
   'their slot.')
on conflict (key) do nothing;

-- ── 3) haul_receipts — the per-ship idempotent action record (the salvage_receipts 0174 shape) ───
-- ONE table for BOTH actions (ownership block above): action='accept' records the claim (credits
-- moved = 0), action='deliver' records the payout. reward_credits = credits ACTUALLY moved by the
-- receipted action (0 on accept — the promise is on the contract row, not the receipt).
create table if not exists public.haul_receipts (
  receipt_id     uuid    primary key default gen_random_uuid(),
  main_ship_id   uuid    not null references public.main_ship_instances (main_ship_id),  -- NEVER player_id
  request_id     uuid    not null,
  contract_id    uuid    not null references public.haul_contracts (id),
  action         text    not null check (action in ('accept','deliver')),
  good_id        text    not null references public.trade_goods (good_id),
  quantity       integer not null check (quantity > 0),
  reward_credits numeric not null check (reward_credits >= 0),  -- credits moved BY THIS ACTION (accept = 0)
  location_id    uuid    references public.locations (id),      -- the port the action occurred at
  created_at     timestamptz not null default now(),
  unique (main_ship_id, request_id)                             -- per-ship idempotency key (0086 §2.6)
);
create index if not exists haul_receipts_main_ship_id_idx on public.haul_receipts (main_ship_id);
create index if not exists haul_receipts_contract_id_idx  on public.haul_receipts (contract_id);

alter table public.haul_receipts enable row level security;
-- Owner-read via join to the owning ship (the salvage_receipts/trade_receipts posture); authenticated,
-- NOT anon. NO client write policy/grant → the two SECURITY DEFINER RPCs below are the sole writers.
revoke all on table public.haul_receipts from public, anon, authenticated;   -- strip default grants (0176 posture)
create policy "haul_receipts_select_own" on public.haul_receipts
  for select using (
    exists (
      select 1 from public.main_ship_instances m
      where m.main_ship_id = haul_receipts.main_ship_id
        and m.player_id = auth.uid()
    )
  );
grant select on public.haul_receipts to authenticated;

-- ── 4) haul_accept_contract — offered→accepted (a CLAIM: no cargo, no credits; semantics §1–§3, §8) ─
create or replace function public.haul_accept_contract(
  p_main_ship_id uuid, p_contract_id uuid, p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     uuid;
  v_loc      uuid;
  v_c        public.haul_contracts%rowtype;
  v_existing public.haul_receipts%rowtype;
  v_cap      integer;
  v_active   integer;
  v_deadline timestamptz;
  v_dur      integer;
  v_receipt  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject: reject deterministically BEFORE any ship/contract read.
  if not public.cfg_bool('haul_contracts_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'haul_contracts_disabled');
  end if;

  -- input validation (a null p_contract_id simply finds no row below → contract_not_found).
  if p_request_id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_request'); end if;

  -- resolve the SELECTED owned ship (ownership asserted) or the sole ship (shim); UI never trusted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;

  -- PER-SHIP LOCK (0090 idiom): held to txn end — the replay check and the contract flip + receipt
  -- below are race-safe against concurrent haul actions on the SAME ship.
  perform public.mainship_space_lock_context(v_ship);

  -- DOCKED check via the ONE shared resolver (0092/0138 — never inlined, never the client).
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- CONTRACT row, FOR UPDATE: serializes racing accepts of the SAME contract across players (the
  -- per-ship lock cannot — different players hold different ship locks). Lock order everywhere is
  -- ship-lock THEN contract-lock; the generator takes only contract locks → no deadlock cycle.
  select * into v_c from public.haul_contracts where id = p_contract_id for update;
  if not found
     or v_c.status in ('delivered','expired','cancelled')       -- terminal — gone from every board
     or v_c.origin_location_id <> v_loc                          -- not on THIS port's bulletin (§2)
     or (v_c.status = 'offered' and v_c.expires_at <= now())     -- stale offer, fail-closed (§3)
  then
    return jsonb_build_object('ok', false, 'reason', 'contract_not_found');
  end if;

  -- someone else already holds it.
  if v_c.status = 'accepted' and v_c.accepted_by is distinct from v_player then
    return jsonb_build_object('ok', false, 'reason', 'already_accepted_other');
  end if;

  -- ACTIVE CAP (§8): count MY accepted contracts EXCLUDING this one, so a replayed accept at the
  -- cap still reaches the replay check below instead of bouncing here.
  -- PER-PLAYER serialization (review 2026-07-12): multi-ship is LIVE, so two of my ships docked at
  -- two ports could count-then-insert concurrently and transiently exceed the soft cap; the repo's
  -- 0078/0109/0112 advisory-lock idiom closes it (xact-scoped, ship locks already held — no new
  -- lock-order edge: the generator takes contract locks only, and this lock is player-keyed).
  perform pg_advisory_xact_lock(hashtext('haul_accept'), hashtext(v_player::text));
  v_cap := coalesce(public.cfg_num('haul_max_active_per_player'), 3)::integer;
  select count(*) into v_active from public.haul_contracts
    where accepted_by = v_player and status = 'accepted' and id <> v_c.id;
  if v_active >= v_cap then
    return jsonb_build_object('ok', false, 'reason', 'too_many_active',
      'active', v_active, 'max', v_cap);
  end if;

  -- IDEMPOTENCY: a receipt for (ship, request_id) already exists → replay verbatim, no write
  -- (the 0086/0174 semantics; no payload-conflict check).
  select * into v_existing from public.haul_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'contract_id', v_existing.contract_id,
      'action', v_existing.action, 'good_id', v_existing.good_id,
      'quantity', v_existing.quantity, 'reward_credits', v_existing.reward_credits,
      'location_id', v_existing.location_id);
  end if;

  -- held by ME already but under a FRESH request id: a duplicate accept (double-tap with a
  -- regenerated request). Honest reject — the claim exists; nothing to write.
  if v_c.status = 'accepted' then
    return jsonb_build_object('ok', false, 'reason', 'already_accepted',
      'contract_id', v_c.id, 'deliver_by', v_c.deliver_by);
  end if;

  -- OK: the claim. deliver_by = now() + the template's duration (the tempo reconciliation, §5).
  -- NO cargo and NO credits move here (§1) — the player sources the goods themselves.
  select t.duration_seconds into v_dur
    from public.haul_contract_templates t where t.template_id = v_c.template_id;
  v_deadline := now() + make_interval(secs => coalesce(v_dur, 21600));

  update public.haul_contracts
     set status       = 'accepted',
         accepted_by  = v_player,
         accepted_ship = v_ship,       -- provenance only, never an enforcement key (§4)
         accepted_at  = now(),
         deliver_by   = v_deadline
   where id = v_c.id;

  -- RECEIPT (Haul Contracts writes its own haul_receipts; reward_credits = 0 — nothing moved).
  insert into public.haul_receipts
    (main_ship_id, request_id, contract_id, action, good_id, quantity, reward_credits, location_id)
    values (v_ship, p_request_id, v_c.id, 'accept', v_c.good_id, v_c.quantity, 0, v_loc)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt,
    'contract_id', v_c.id, 'action', 'accept', 'good_id', v_c.good_id,
    'quantity', v_c.quantity, 'reward_credits', 0,
    'contract_reward_credits', v_c.reward_credits,     -- the PROMISE (paid at delivery)
    'dest_location_id', v_c.dest_location_id, 'deliver_by', v_deadline,
    'location_id', v_loc);
end;
$$;
-- ACL: authenticated client RPC (server-rejected while dark — the 0090/0174 posture); anon/public never.
revoke execute on function public.haul_accept_contract(uuid, uuid, uuid) from public, anon;
grant  execute on function public.haul_accept_contract(uuid, uuid, uuid) to authenticated;

-- ── 5) haul_deliver_contract — accepted→delivered (consume via Trade-Cargo + credit via Wallet) ──
create or replace function public.haul_deliver_contract(
  p_main_ship_id uuid, p_contract_id uuid, p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     uuid;
  v_loc      uuid;
  v_c        public.haul_contracts%rowtype;
  v_existing public.haul_receipts%rowtype;
  v_avail    numeric;
  v_cost     numeric;
  v_receipt  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject: reject deterministically BEFORE any ship/contract read.
  if not public.cfg_bool('haul_contracts_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'haul_contracts_disabled');
  end if;

  -- input validation (a null p_contract_id finds no row below → contract_not_found).
  if p_request_id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_request'); end if;

  -- resolve the SELECTED owned ship — ANY owned ship may deliver (§4); ownership asserted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;

  -- PER-SHIP LOCK (0090 idiom): the replay + cargo checks and the consume/credit/flip/receipt
  -- writes below are race-safe against concurrent actions on the SAME ship; cross-player races on
  -- the contract are serialized by the row lock below.
  perform public.mainship_space_lock_context(v_ship);

  -- DOCKED check via the ONE shared resolver (0092/0138).
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- CONTRACT row, FOR UPDATE (lock order: ship-lock then contract-lock — same as accept).
  select * into v_c from public.haul_contracts where id = p_contract_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'contract_not_found');
  end if;

  -- IDEMPOTENCY — BEFORE the state/port/deadline/cargo guards (header REPLAY PLACEMENT note): a
  -- successful delivery flips the status and consumes the cargo, so a retry must replay verbatim
  -- here, never bounce off the now-false guards. No write, no re-credit, no re-consume.
  select * into v_existing from public.haul_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'contract_id', v_existing.contract_id,
      'action', v_existing.action, 'good_id', v_existing.good_id,
      'quantity', v_existing.quantity, 'reward_credits', v_existing.reward_credits,
      'location_id', v_existing.location_id);
  end if;

  -- STATE: must be 'accepted' by THIS player (covers foreign/offered/expired/cancelled/delivered —
  -- accepted rows are owner-read anyway, so the fold leaks nothing).
  if v_c.status <> 'accepted' or v_c.accepted_by is distinct from v_player then
    return jsonb_build_object('ok', false, 'reason', 'contract_not_found');
  end if;

  -- DEST-PORT check (§4: any owned ship, but AT the destination). The player owns this contract,
  -- so the honest actionable reason — not a contract_not_found fold.
  if v_c.dest_location_id <> v_loc then
    return jsonb_build_object('ok', false, 'reason', 'wrong_port',
      'dest_location_id', v_c.dest_location_id);
  end if;

  -- DEADLINE (§6): reject-only — the accepted→cancelled flip stays the generator's (a2) pass, the
  -- single writer of that transition. deliver_by is NOT NULL for every accepted row (the CHECK).
  if v_c.deliver_by <= now() then
    return jsonb_build_object('ok', false, 'reason', 'deadline_passed',
      'deliver_by', v_c.deliver_by);
  end if;

  -- CARGO sufficiency pre-check under the lock (the market_sell 0090 inline lot-sum read — the
  -- sole-writer law governs writes; Trade-Cargo has no read leaf), so the consume never underflows.
  select coalesce(sum(l.qty), 0) into v_avail from public.ship_cargo_lots l
    where l.main_ship_id = v_ship and l.good_id = v_c.good_id;
  if v_avail < v_c.quantity then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_cargo',
      'good_id', v_c.good_id, 'available', v_avail, 'need', v_c.quantity);
  end if;

  -- CONSUME via Trade-Cargo (the ONE FIFO cargo debiter, 0090 — identical semantics to a market
  -- sell's debit: oldest lots first, returns the consumed cost basis). The basis is consumed and
  -- LOST (§7) — the reward covers it by the 0176 worth-taking invariant.
  v_cost := public.trade_cargo_consume(v_ship, v_c.good_id, v_c.quantity);

  -- CREDIT via Wallet (the sole player_wallet writer).
  perform public.wallet_credit(v_player, v_c.reward_credits);

  -- STATUS flip (its own table) + RECEIPT — atomic with the consume + credit in this one txn.
  update public.haul_contracts
     set status = 'delivered', delivered_at = now()
   where id = v_c.id;

  insert into public.haul_receipts
    (main_ship_id, request_id, contract_id, action, good_id, quantity, reward_credits, location_id)
    values (v_ship, p_request_id, v_c.id, 'deliver', v_c.good_id, v_c.quantity, v_c.reward_credits, v_loc)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt,
    'contract_id', v_c.id, 'action', 'deliver', 'good_id', v_c.good_id,
    'quantity', v_c.quantity, 'reward_credits', v_c.reward_credits,
    'location_id', v_loc, 'cost_basis_consumed', v_cost);
end;
$$;
-- ACL: authenticated client RPC (server-rejected while dark); the Trade-Cargo/Wallet internals it
-- calls stay revoked-from-clients exactly as 0089/0090/0093 left them.
revoke execute on function public.haul_deliver_contract(uuid, uuid, uuid) from public, anon;
grant  execute on function public.haul_deliver_contract(uuid, uuid, uuid) to authenticated;

-- ── 6) haul_generate_offers — 0176-head parity re-create + the ONE marked (a2) hunk (shape §6) ───
-- PARITY DISCIPLINE: body byte-identical to 0176 EXCEPT the three marked [HAUL-2 hunk] lines groups:
-- (i) the `v_cancelled` declaration, (ii) the (a2) deadline-cancel pass, (iii) the envelope field.
-- Pass (a) is UNCHANGED — its predicate is still status='offered' ONLY (an accepted row is never
-- 'expired'); (a2) is the single sanctioned writer of accepted→cancelled (no penalty v1 [D]; frees
-- the player's cap slot). It runs INSIDE the same gate: while dark, neither pass runs (the 0176
-- emergency-darkening note now covers stale accepted rows too — the ACT-HAUL rollback section must
-- run one manual pass or accept the freeze).
create or replace function public.haul_generate_offers()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day     date;
  v_n       integer;
  v_port    uuid;
  v_slot    integer;
  v_h       bigint;
  v_u       numeric;
  v_hq      bigint;
  v_span    integer;
  v_qty     integer;
  v_dest    uuid;
  v_buy     numeric;
  v_reward  numeric;
  v_ins     integer;
  v_created integer := 0;
  v_expired integer := 0;
  v_cancelled integer := 0;   -- [HAUL-2 hunk] the (a2) pass counter
  v_ports   integer := 0;
  r         record;
begin
  -- DARK gate FIRST (the D2/0145 cron-safety lesson): while false, return early — no read, no
  -- write, no raise. Every dark cron firing is an instant no-op.
  if not public.cfg_bool('haul_contracts_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- (a) EXPIRY: only 'offered' rows ever flip; accepted rows are NEVER touched here.
  update public.haul_contracts
     set status = 'expired'
   where status = 'offered'
     and expires_at <= now();
  get diagnostics v_expired = row_count;

  -- (a2) [HAUL-2 hunk] DELIVERY DEADLINE: 'accepted' rows past deliver_by → 'cancelled' (no penalty
  -- v1 [D]; frees the player's active-cap slot). The SINGLE writer of this transition — the deliver
  -- RPC rejects past-deadline attempts but never flips the row. Accepted rows WITHIN deliver_by
  -- remain untouchable by every pass.
  update public.haul_contracts
     set status = 'cancelled'
   where status = 'accepted'
     and deliver_by is not null
     and deliver_by <= now();
  get diagnostics v_cancelled = row_count;

  -- (b) GENERATION: deterministic per (day, port, slot). The day is the UTC calendar day —
  -- TimeZone-GUC-independent, so every caller (cron/psql/proof) agrees on the boundary.
  v_day := (now() at time zone 'utc')::date;
  v_n   := greatest(0, coalesce(public.cfg_num('haul_offers_per_port'), 2)::integer);

  for v_port in
    select l.id
      from public.locations l
     where l.status = 'active'
       and exists (select 1 from public.location_services s
                     where s.location_id = l.id and s.service = 'docking' and s.status = 'active')
       and exists (select 1 from public.market_offers o
                     where o.location_id = l.id and o.active)
     order by l.id
  loop
    v_ports := v_ports + 1;
    for v_slot in 1..v_n loop
      v_dest := null; v_buy := null;

      -- deterministic uniform in [0,1) for this (day, port, slot) — the pure-hash technique.
      -- to_char pins the salt's date rendering (DateStyle-GUC-independent).
      v_h := hashtextextended(format('haul:%s:%s:%s', to_char(v_day, 'YYYY-MM-DD'), v_port, v_slot), 0);
      v_u := (((v_h % 1000000) + 1000000) % 1000000)::numeric / 1000000.0;

      -- weighted template pick: cumulative weights in template_id order over the port's pool
      -- (origin fixed to this port, or NULL = 'any'); first bucket past the dart wins.
      select x.* into r from (
        select tt.*,
               sum(tt.weight) over (order by tt.template_id) as w_cum,
               sum(tt.weight) over ()                        as w_total
          from public.haul_contract_templates tt
         where tt.active
           and (tt.origin_location_id is null or tt.origin_location_id = v_port)
      ) x
      where x.w_cum > v_u * x.w_total
      order by x.template_id
      limit 1;
      if not found then continue; end if;   -- no template pool at this port → no offer, no raise

      -- resolve the destination: fixed, or (NULL = 'any') the top-paying OTHER active port.
      if r.dest_location_id is not null then
        v_dest := r.dest_location_id;
      else
        select o.location_id into v_dest
          from public.market_offers o
          join public.locations l2 on l2.id = o.location_id
         where o.good_id = r.good_id and o.active
           and o.location_id <> v_port
           and l2.status = 'active'
           and exists (select 1 from public.location_services s2
                         where s2.location_id = o.location_id
                           and s2.service = 'docking' and s2.status = 'active')
         order by o.buy_price desc, o.location_id
         limit 1;
      end if;
      if v_dest is null or v_dest = v_port then continue; end if;

      -- deterministic quantity in [qty_min, qty_max] (second salt, same technique).
      v_hq   := hashtextextended(format('haulqty:%s:%s:%s', to_char(v_day, 'YYYY-MM-DD'), v_port, v_slot), 0);
      v_span := r.qty_max - r.qty_min + 1;
      v_qty  := r.qty_min + (((v_hq % v_span) + v_span) % v_span)::integer;

      -- price off the LIVE destination market row (header math); no row → no offer, no raise.
      select o.buy_price into v_buy
        from public.market_offers o
       where o.location_id = v_dest and o.good_id = r.good_id and o.active;
      if v_buy is null then continue; end if;
      v_reward := round(r.reward_base + v_qty * (v_buy + r.reward_premium_per_unit));

      -- idempotent mint on the natural key: a re-run/racing double-fire creates NOTHING new.
      insert into public.haul_contracts
        (template_id, origin_location_id, dest_location_id, good_id, quantity, reward_credits,
         status, offered_at, expires_at, offer_day, slot)
      values
        (r.template_id, v_port, v_dest, r.good_id, v_qty, v_reward,
         'offered', now(), now() + make_interval(secs => r.duration_seconds), v_day, v_slot)
      on conflict (origin_location_id, offer_day, slot) do nothing;
      get diagnostics v_ins = row_count;
      v_created := v_created + v_ins;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'day', v_day, 'ports', v_ports,
                            'offers_created', v_created, 'offers_expired', v_expired,
                            'accepted_cancelled', v_cancelled);   -- [HAUL-2 hunk] envelope field
end;
$$;
-- ACL re-asserted on the re-created identity (the 0176 private-writer posture; create-or-replace
-- preserves grants — re-emitted for an explicit posture, the 0092 idiom).
revoke execute on function public.haul_generate_offers() from public, anon, authenticated;
grant  execute on function public.haul_generate_offers() to service_role;

-- ── 7) Self-assert: schema + receipts RLS + RPC ACLs + generator hunk + cron + flag still dark ───
do $$
declare
  v_n    integer;
  v_src  text;
  v_r    jsonb;
  v_rows integer;
begin
  -- 1. deliver_by + the accepted-has-deadline CHECK exist.
  if not exists (select 1 from information_schema.columns
                   where table_schema='public' and table_name='haul_contracts' and column_name='deliver_by') then
    raise exception 'HAUL-2 self-assert FAIL: haul_contracts.deliver_by missing';
  end if;
  if not exists (select 1 from pg_constraint
                   where conrelid = 'public.haul_contracts'::regclass
                     and conname = 'haul_contracts_accepted_has_deliver_by') then
    raise exception 'HAUL-2 self-assert FAIL: accepted-has-deliver_by CHECK missing';
  end if;

  -- 2. haul_receipts: RLS on, exactly ONE SELECT-only owner policy, SELECT-only grants (no writes).
  if not (select relrowsecurity from pg_class where oid = 'public.haul_receipts'::regclass) then
    raise exception 'HAUL-2 self-assert FAIL: RLS not enabled on haul_receipts';
  end if;
  select count(*) into v_n from pg_policies where schemaname='public' and tablename='haul_receipts';
  if v_n <> 1 then
    raise exception 'HAUL-2 self-assert FAIL: haul_receipts has % policies (want exactly 1)', v_n;
  end if;
  select count(*) into v_n from pg_policies
    where schemaname='public' and tablename='haul_receipts' and cmd <> 'SELECT';
  if v_n <> 0 then
    raise exception 'HAUL-2 self-assert FAIL: haul_receipts carries a non-SELECT policy';
  end if;
  if not has_table_privilege('authenticated', 'public.haul_receipts', 'SELECT')
     or has_table_privilege('anon', 'public.haul_receipts', 'SELECT')
     or has_table_privilege('authenticated', 'public.haul_receipts', 'INSERT, UPDATE, DELETE')
     or has_table_privilege('anon', 'public.haul_receipts', 'INSERT, UPDATE, DELETE') then
    raise exception 'HAUL-2 self-assert FAIL: haul_receipts grant surface wrong (want authenticated SELECT only)';
  end if;

  -- 3. Both RPCs exist, authenticated-executable, never anon/public; the internals they call stay
  --    client-revoked (0089/0090/0093 posture re-pinned).
  if to_regprocedure('public.haul_accept_contract(uuid,uuid,uuid)') is null
     or to_regprocedure('public.haul_deliver_contract(uuid,uuid,uuid)') is null then
    raise exception 'HAUL-2 self-assert FAIL: an RPC identity is missing';
  end if;
  if not has_function_privilege('authenticated', 'public.haul_accept_contract(uuid,uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.haul_deliver_contract(uuid,uuid,uuid)', 'execute') then
    raise exception 'HAUL-2 self-assert FAIL: an RPC is not authenticated-executable';
  end if;
  if has_function_privilege('anon', 'public.haul_accept_contract(uuid,uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'public.haul_deliver_contract(uuid,uuid,uuid)', 'execute') then
    raise exception 'HAUL-2 self-assert FAIL: an RPC is anon-executable';
  end if;
  if has_function_privilege('authenticated', 'public.trade_cargo_consume(uuid,text,numeric)', 'execute')
     or has_function_privilege('authenticated', 'public.wallet_credit(uuid,numeric)', 'execute')
     or has_function_privilege('authenticated', 'public.mainship_resolve_docked_location(uuid)', 'execute') then
    raise exception 'HAUL-2 self-assert FAIL: an internal leaf became client-executable';
  end if;

  -- 4. The cap knob seeded 3; the flag STILL dark (this migration writes no flag).
  if coalesce(public.cfg_num('haul_max_active_per_player'), -1) <> 3 then
    raise exception 'HAUL-2 self-assert FAIL: haul_max_active_per_player not seeded 3';
  end if;
  if public.cfg_bool('haul_contracts_enabled') then
    raise exception 'HAUL-2 self-assert FAIL: haul_contracts_enabled is not false after this migration';
  end if;

  -- 5. Generator parity + hunk: the re-created body carries the (a2) cancel pass AND still the
  --    0176 offered-only expiry predicate + the deterministic salts (parity spot-pins).
  select prosrc into v_src from pg_proc where oid = 'public.haul_generate_offers()'::regprocedure;
  if v_src not like '%deliver_by <= now()%' or v_src not like '%''cancelled''%' then
    raise exception 'HAUL-2 self-assert FAIL: generator lacks the (a2) deadline-cancel pass';
  end if;
  if v_src not like '%status = ''offered''%' or v_src not like '%hashtextextended%'
     or v_src not like '%on conflict (origin_location_id, offer_day, slot) do nothing%' then
    raise exception 'HAUL-2 self-assert FAIL: generator parity spot-pins missing (0176 body drifted)';
  end if;
  if has_function_privilege('authenticated', 'public.haul_generate_offers()', 'execute')
     or has_function_privilege('anon', 'public.haul_generate_offers()', 'execute')
     or not has_function_privilege('service_role', 'public.haul_generate_offers()', 'execute') then
    raise exception 'HAUL-2 self-assert FAIL: generator ACL drifted';
  end if;

  -- 6. Cron STILL scheduled exactly once (this migration must not touch the job).
  begin
    select count(*) into v_n from cron.job where jobname = 'haul-generate-offers';
    if v_n <> 1 then
      raise exception 'HAUL-2 self-assert FAIL: expected exactly 1 haul-generate-offers cron job, got %', v_n;
    end if;
  exception
    when undefined_table then
      raise notice 'HAUL-2 self-assert: cron.job absent (shadow db) — cron count check skipped';
  end;

  -- 7. DARK dry-runs. Generator: clean feature_disabled no-op, zero row delta. RPCs: with NO auth
  --    subject → not_authenticated (envelope-first); with a transient fake subject → the
  --    haul_contracts_disabled gate BEFORE any read; zero receipts either way.
  select count(*) into v_rows from public.haul_contracts;
  v_r := public.haul_generate_offers();
  if (v_r->>'ok')::boolean is not false or (v_r->>'code') is distinct from 'feature_disabled' then
    raise exception 'HAUL-2 self-assert FAIL: dark generator dry-run not a clean no-op: %', v_r;
  end if;
  select count(*) - v_rows into v_n from public.haul_contracts;
  if v_n <> 0 then
    raise exception 'HAUL-2 self-assert FAIL: dark generator dry-run changed % row(s)', v_n;
  end if;

  v_r := public.haul_accept_contract(null, null, null);
  if (v_r->>'reason') is distinct from 'not_authenticated' then
    raise exception 'HAUL-2 self-assert FAIL: unauthenticated accept did not envelope-reject: %', v_r;
  end if;
  v_r := public.haul_deliver_contract(null, null, null);
  if (v_r->>'reason') is distinct from 'not_authenticated' then
    raise exception 'HAUL-2 self-assert FAIL: unauthenticated deliver did not envelope-reject: %', v_r;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  v_r := public.haul_accept_contract(null, null, null);
  if (v_r->>'reason') is distinct from 'haul_contracts_disabled' then
    raise exception 'HAUL-2 self-assert FAIL: dark accept did not gate-first reject: %', v_r;
  end if;
  v_r := public.haul_deliver_contract(null, null, null);
  if (v_r->>'reason') is distinct from 'haul_contracts_disabled' then
    raise exception 'HAUL-2 self-assert FAIL: dark deliver did not gate-first reject: %', v_r;
  end if;
  perform set_config('request.jwt.claims', '', true);

  select count(*) into v_n from public.haul_receipts;
  if v_n <> 0 then
    raise exception 'HAUL-2 self-assert FAIL: dark dry-runs left % receipt row(s)', v_n;
  end if;

  raise notice 'HAUL-2 self-assert ok: deliver_by + accepted-deadline CHECK; haul_receipts owner-read/SELECT-only; RPCs authenticated-only, internals private; cap knob 3; generator parity + (a2) cancel hunk, service-role-only; cron once; flag dark; dark dry-runs clean (not_authenticated -> haul_contracts_disabled, zero writes)';
end $$;
