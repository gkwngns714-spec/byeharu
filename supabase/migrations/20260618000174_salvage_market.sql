-- Byeharu — SALVAGE-0/1: the combat-loot → port-economy feed (schema + seed + flag + sell RPC; DARK).
--
-- Queue slice #6 of the full-capacity plan (master plan §C P3): ports gain ITEM buy-lists
-- (`port_item_demand`) and ONE flag-gated sell RPC (`sell_item_at_port`) — the first item→credits
-- path (closes gap G3: "combat loot has no economy exit"). Everything DARK behind the NEW
-- `salvage_market_enabled` flag, seeded 'false'; the UI (SALVAGE-2, DockedPortCard) is a later slice.
--
-- ── PIPELINE LAW (ROADMAP law 3 / SYSTEM_BOUNDARIES core law) — UNCHANGED ────────────────────────
-- combat → pending bundle → secured on safe settle → player_inventory (reward_grant, 0040/0041).
-- SALVAGE consumes inventory EXACTLY like crafting does (0109/0126: pre-check via
-- inventory_get_balance, spend via Inventory's own `inventory_spend` writer — never a direct
-- player_inventory write) and credits ONLY through Wallet's `wallet_credit` (0093). Combat still
-- NEVER grants credits directly; selling is a player-initiated docked action, like a trade sell.
--
-- ── WHAT ACTUALLY DROPS (grep-verified against the REAL loot table) ──────────────────────────────
-- `pirate_loot_for_wave` — head 0041, re-created ONCE by 0171 (its only other create site; 0046/
-- 0167/0169 only CALL it). Per CLEARED wave w:
--     scrap ×1 (every wave) · +pirate_alloy (w≥3) · +weapon_parts (w≥5) · +engine_parts (w≥8)
--     · +repair_parts (w≥10) · captain_memory_shard (probabilistic, w≥2 — PROGRESSION, see below)
-- So the sellable combat-loot universe is EXACTLY these FIVE items. ore/crystal (mining) and
-- scan_data/anomaly_shard (exploration) are NOT combat drops and get no demand here (their economy
-- exits are later concerns); the progression items `captain_memory_shard` / `blueprint_fragment` /
-- `artifact_core` are NEVER sellable — excluded BY OMISSION (no row anywhere; the proof pins it).
--
-- ── PRICE MATH (proposed; [D] OWNER-TUNABLE — a price retune is a one-migration reseed) ──────────
-- Port role identities extend the 0173 trade roles onto items:
--     Slagworks (industrial recycler) pays BEST for scrap + pirate_alloy;
--     Haven (city/consumer)           pays BEST for repair_parts;
--     Driftmarch (frontier)           pays BEST for engine_parts + weapon_parts.
--
--     item          | Haven | Slagworks | Driftmarch
--     scrap         |   5   |    8      |    6
--     pirate_alloy  |  10   |   16      |   12
--     repair_parts  |  20   |   12      |   16
--     engine_parts  |  16   |   14      |   24
--     weapon_parts  |  15   |   13      |   22
--
-- Grounding (all [D]):
--   · TYPICAL SNARE RUN: the packet-§1.1 solo farm ceiling is ~3 cleared waves → 3 scrap +
--     1 pirate_alloy. Best-port sale (Slagworks) = 3×8 + 16 = 40 credits; worst (Haven) =
--     3×5 + 10 = 25. That puts the canonical run mid-band in the target ≈30–80 credits — real
--     pocket money next to the 0173 trade routes (+200/guaranteed trip) and the 250-credit ship,
--     without becoming the dominant faucet.
--   · DEEP TEAM RUN (17 waves, 6–8 ships): 17 scrap + 15 alloy + 13 weapon + 10 engine + 8 repair
--     → ≈1,060 credits selling each item at its best port (781 single-port Slagworks) — a whole
--     team's deep bd-25 push buys ~4 ships' worth, comparable to a sustained trade session.
--   · CRAFTING STAYS THE CEILING, SELLING THE FLOOR: the 0107 module baskets sell (best-port) for
--     autocannon_battery 4×22+2×16+6×8 = 168 · expanded_cargo_lattice 10×8+3×16+2×20 = 168 ·
--     vector_thruster_kit 4×24+4×8 = 128 (+2 crystal, unsellable here) — each well under the
--     250-credit hull price for a PERMANENT stat module that credits cannot buy at all, so
--     converting a full recipe's ingredients to credits is always the worse aggregate use.
--     Sell the surplus, craft the build. (Economy balance remains [D]; the proof pins the exact
--     seeded numbers, not the philosophy.)
--   · Scale check vs 0173 goods: scrap 5–8 sits under ore (9–20); parts 12–24 sit in the
--     provisions/reagents band — salvage never out-earns dedicated hauling per docked visit.
--
-- ── NO PUMP BY CONSTRUCTION ──────────────────────────────────────────────────────────────────────
-- `port_item_demand` is BUY-side only (the port PAYS; unit_price > 0). There is NO path that sells
-- items TO the player, so the market_offers spread constraint has no analogue to violate — a
-- buy-cheap/sell-dear loop cannot exist. Items enter play only through the reward pipeline.
--
-- ── OWNERSHIP (SYSTEM_BOUNDARIES rows land in THIS PR — the §E law) ──────────────────────────────
--   · port_item_demand  = Reference/Config: MIGRATION-SEEDED ONLY, NO runtime writer, ever
--                         (the market_offers 0085/0173 posture). Public read-only.
--   · salvage_receipts  = Salvage Market: sole writer = `sell_item_at_port` (this migration).
--                         Owner-read via the owning ship (the trade_receipts posture).
-- WHY A NEW RECEIPTS TABLE (not trade_receipts): 0086's `trade_receipts.good_id` is
-- `not null references trade_goods (good_id)` and `side` is CHECK-constrained to ('buy','sell') —
-- the table is structurally trade-goods-specific; an item sale cannot satisfy the FK. Rather than
-- weaken a live table's FK (a parity-law hazard for zero gain), salvage gets its own receipts
-- table with the IDENTICAL idempotency shape: (main_ship_id, request_id) unique, replay-verbatim.
--
-- Forward-only: 0001–0173 unedited. No client code in this slice.

-- ── 1) port_item_demand — Reference/Config item buy-list (migration-seeded ONLY; no runtime writer) ──
create table if not exists public.port_item_demand (
  location_id uuid    not null references public.locations (id),       -- locations PK is `id`
  item_id     text    not null references public.item_types (item_id),
  unit_price  numeric not null check (unit_price > 0),  -- credits the PORT PAYS per unit (buy-side only)
  active      boolean not null default true,
  primary key (location_id, item_id)
);

alter table public.port_item_demand enable row level security;
-- Public read-only (the market_offers 0085 posture): NO insert/update/delete policy and NO write
-- grant → clients cannot mutate; migrations/admin are the ONLY writer — no runtime writer exists.
create policy "port_item_demand_public_read" on public.port_item_demand for select using (true);
grant select on public.port_item_demand to anon, authenticated;

-- ── 2) Seed the 5-droppable × 3-port demand table (idempotent; converges on re-apply, 0173 idiom) ──
insert into public.port_item_demand (location_id, item_id, unit_price) values
  -- Haven Reach — city/consumer (top payer: repair_parts).
  ('b1a00001-0066-4a00-8a00-000000000001', 'scrap',         5),
  ('b1a00001-0066-4a00-8a00-000000000001', 'pirate_alloy', 10),
  ('b1a00001-0066-4a00-8a00-000000000001', 'repair_parts', 20),
  ('b1a00001-0066-4a00-8a00-000000000001', 'engine_parts', 16),
  ('b1a00001-0066-4a00-8a00-000000000001', 'weapon_parts', 15),
  -- Slagworks Anchorage — industrial recycler (top payer: scrap + pirate_alloy).
  ('b1a00002-0066-4a00-8a00-000000000002', 'scrap',         8),
  ('b1a00002-0066-4a00-8a00-000000000002', 'pirate_alloy', 16),
  ('b1a00002-0066-4a00-8a00-000000000002', 'repair_parts', 12),
  ('b1a00002-0066-4a00-8a00-000000000002', 'engine_parts', 14),
  ('b1a00002-0066-4a00-8a00-000000000002', 'weapon_parts', 13),
  -- Driftmarch Waypost — frontier (top payer: engine_parts + weapon_parts).
  ('b1a00003-0066-4a00-8a00-000000000003', 'scrap',         6),
  ('b1a00003-0066-4a00-8a00-000000000003', 'pirate_alloy', 12),
  ('b1a00003-0066-4a00-8a00-000000000003', 'repair_parts', 16),
  ('b1a00003-0066-4a00-8a00-000000000003', 'engine_parts', 24),
  ('b1a00003-0066-4a00-8a00-000000000003', 'weapon_parts', 22)
on conflict (location_id, item_id) do update
  set unit_price = excluded.unit_price,
      active     = true;

-- ── 3) the dark capability gate — seeded 'false' (the standard 0107 idiom) ───────────────────────
insert into public.game_config (key, value, description) values
  ('salvage_market_enabled', 'false',
   'SALVAGE (0174): server-authoritative dark gate for the port item-salvage market (combat loot '
   '-> credits via sell_item_at_port). OFF until the owner flips it (a later ACT-SALVAGE script, '
   'with the SALVAGE-2 UI). The sell RPC checks this FIRST and rejects before any read while '
   'false; no UI mounts in this slice.')
on conflict (key) do nothing;

-- ── 4) salvage_receipts — the per-ship idempotent sale record (the 0086 trade_receipts shape) ────
create table if not exists public.salvage_receipts (
  receipt_id   uuid    primary key default gen_random_uuid(),
  main_ship_id uuid    not null references public.main_ship_instances (main_ship_id),  -- NEVER player_id
  request_id   uuid    not null,
  item_id      text    not null references public.item_types (item_id),
  location_id  uuid    references public.locations (id),        -- the port the sale occurred at
  qty          numeric not null check (qty > 0),                -- whole items (integer-valued; the RPC enforces)
  unit_price   numeric not null check (unit_price >= 0),        -- per-unit credits at sale time
  total_price  numeric not null check (total_price >= 0),       -- qty * unit_price at sale time
  created_at   timestamptz not null default now(),
  unique (main_ship_id, request_id)                             -- per-ship idempotency key (0086 §2.6)
);
create index if not exists salvage_receipts_main_ship_id_idx on public.salvage_receipts (main_ship_id);

alter table public.salvage_receipts enable row level security;
-- Owner-read via join to the owning ship (the trade_receipts 0086 posture); authenticated, NOT
-- anon. NO client write policy/grant → sell_item_at_port (SECURITY DEFINER) is the sole writer.
create policy "salvage_receipts_select_own" on public.salvage_receipts
  for select using (
    exists (
      select 1 from public.main_ship_instances m
      where m.main_ship_id = salvage_receipts.main_ship_id
        and m.player_id = auth.uid()
    )
  );
grant select on public.salvage_receipts to authenticated;

-- ── 5) sell_item_at_port — the SALVAGE-1 sell orchestrator (the 0090/0138 sell shape, on items) ──
-- Atomic + idempotent, all in ONE function/transaction under the per-ship lock. Fan-out is
-- one-directional DOWNWARD: Main Ship (resolve/lock/dock, read-only) → Reference/Config
-- (port_item_demand) → Inventory (inventory_spend — the ONE player_inventory writer, exactly the
-- 0109 crafting edge) → Wallet (wallet_credit) → its own salvage_receipts. NO other table written.
--
-- REJECT ORDER (the charter's envelope order; each named): not_authenticated →
-- salvage_market_disabled (gate FIRST, before ANY read) → invalid_request → invalid_item → invalid_quantity
-- (items are INTEGER quantities — player_inventory.quantity is integer, 0039 — so fractional qty
-- is invalid, not rounded) → ship_not_found → not_docked → no_demand → idempotent_replay →
-- insufficient_items → ok. NOTE a deliberate delta from 0138's market_sell (replay before the
-- dock read): here the replay check sits AFTER not_docked/no_demand per the P3 charter — a retry
-- replays verbatim in the normal still-docked case; a retry after undocking re-validates context
-- first (stricter, never double-credits either way — the receipt check still precedes every write).
create or replace function public.sell_item_at_port(
  p_main_ship_id uuid, p_item_id text, p_quantity numeric, p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     uuid;
  v_loc      uuid;
  v_price    numeric;
  v_existing public.salvage_receipts%rowtype;
  v_qty      integer;
  v_have     integer;
  v_total    numeric;
  v_receipt  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject: reject deterministically BEFORE any ship/demand/inventory read.
  if not public.cfg_bool('salvage_market_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'salvage_market_disabled');
  end if;

  -- input validation. Items are INTEGER quantities (0039 player_inventory.quantity integer):
  -- null/non-positive/fractional all reject as invalid_quantity; the 1e6 cap keeps the integer
  -- cast safe (the reward_grant 0040 magnitude posture).
  if p_request_id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_request'); end if;
  if p_item_id is null or p_item_id = '' then return jsonb_build_object('ok', false, 'reason', 'invalid_item'); end if;
  if p_quantity is null or p_quantity <= 0 or p_quantity <> floor(p_quantity) or p_quantity > 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
  end if;
  v_qty := p_quantity::integer;

  -- resolve the SELECTED owned ship (ownership asserted) or the sole ship (shim); UI never trusted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;

  -- PER-SHIP LOCK (0090 idiom): held to txn end, so the replay + balance checks and the
  -- spend/credit/receipt writes below are race-safe against concurrent sales on the SAME ship.
  -- (Cross-ship same-player races are backstopped by inventory_spend's own FOR UPDATE re-check —
  -- the 0109 crafting posture: the pre-check gives the friendly envelope, the spend enforces.)
  perform public.mainship_space_lock_context(v_ship);

  -- DOCKED check via the ONE shared resolver (0092/0138 — never inlined, never the client).
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- DEMAND: this port's ACTIVE buy-list row for this item (Reference/Config; read-only).
  -- Unknown item ids fall out here too (no demand row can reference one — the FK).
  select d.unit_price into v_price from public.port_item_demand d
    where d.location_id = v_loc and d.item_id = p_item_id and d.active;
  if v_price is null then return jsonb_build_object('ok', false, 'reason', 'no_demand'); end if;

  -- IDEMPOTENCY: a receipt for (ship, request_id) already exists → replay verbatim, no write,
  -- no re-spend, no re-credit (the 0086/0090 trade-receipts semantics; no payload-conflict check).
  select * into v_existing from public.salvage_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'item_id', v_existing.item_id,
      'qty', v_existing.qty, 'unit_price', v_existing.unit_price,
      'total_price', v_existing.total_price, 'location_id', v_existing.location_id);
  end if;

  -- BALANCE pre-check via Inventory's read leaf (friendly envelope BEFORE anything is spent —
  -- the 0109 step-6 shape; authoritative enforcement stays inventory_spend's FOR UPDATE).
  v_have := public.inventory_get_balance(v_player, p_item_id);
  if v_have < v_qty then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_items',
      'item_id', p_item_id, 'have', v_have, 'need', v_qty);
  end if;

  v_total := v_qty * v_price;

  -- SPEND via Inventory (the sole player_inventory writer — salvage never touches it directly;
  -- an exception here aborts the WHOLE txn: nothing credited, no receipt — the 0109 step-7 law).
  perform public.inventory_spend(v_player, p_item_id, v_qty);

  -- CREDIT via Wallet (the sole player_wallet writer).
  perform public.wallet_credit(v_player, v_total);

  -- RECEIPT (Salvage Market writes salvage_receipts directly — its own table; the
  -- (main_ship_id, request_id) key finalizes idempotency atomically with the spend + credit).
  insert into public.salvage_receipts
    (main_ship_id, request_id, item_id, location_id, qty, unit_price, total_price)
    values (v_ship, p_request_id, p_item_id, v_loc, v_qty, v_price, v_total)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt,
    'item_id', p_item_id, 'qty', v_qty, 'unit_price', v_price, 'total_price', v_total,
    'location_id', v_loc);
end;
$$;
-- ACL: authenticated client RPC (server-rejected while dark — the 0090 posture); anon/public never.
revoke execute on function public.sell_item_at_port(uuid, text, numeric, uuid) from public, anon;
grant  execute on function public.sell_item_at_port(uuid, text, numeric, uuid) to authenticated;

-- ── 6) Self-assert: the seed is complete, role-differentiated, drop-grounded, progression-free ───
do $$
declare
  c_haven constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  -- EXACTLY the 0041/0171 combat-loot droppables (the sellable universe).
  v_drops constant text[] := array['scrap','pirate_alloy','weapon_parts','engine_parts','repair_parts'];
  v_n int;
begin
  -- 1. Completeness: each starter port carries exactly one ACTIVE demand row per droppable (5 each).
  select count(*) into v_n from unnest(array[c_haven, c_slag, c_drift]) p
    where (select count(*) from public.port_item_demand d
             where d.location_id = p and d.item_id = any(v_drops) and d.active) <> 5;
  if v_n <> 0 then
    raise exception 'SALVAGE-0 self-assert FAIL: % starter port(s) do not carry exactly 5 active demand rows', v_n;
  end if;

  -- 2. Drop-grounding: NO demand row anywhere for an item outside the combat drop table.
  select count(*) into v_n from public.port_item_demand where item_id <> all(v_drops);
  if v_n <> 0 then
    raise exception 'SALVAGE-0 self-assert FAIL: % demand row(s) for items that do not drop from combat', v_n;
  end if;

  -- 3. NEVER-SELLABLE: no progression-category item has a demand row (excluded BY OMISSION —
  --    captain_memory_shard / blueprint_fragment / artifact_core; category is the 0039 vocabulary).
  select count(*) into v_n
    from public.port_item_demand d join public.item_types t on t.item_id = d.item_id
    where t.category = 'progression';
  if v_n <> 0 then
    raise exception 'SALVAGE-0 self-assert FAIL: % progression item(s) have port demand (never sellable)', v_n;
  end if;

  -- 4. Role differentiation holds STRICTLY: for each item, the role port is the UNIQUE top payer
  --    (Slagworks: scrap + pirate_alloy · Haven: repair_parts · Driftmarch: engine_parts + weapon_parts).
  select count(*) into v_n from (values
      ('scrap', c_slag), ('pirate_alloy', c_slag),
      ('repair_parts', c_haven),
      ('engine_parts', c_drift), ('weapon_parts', c_drift)
    ) roles(item, top_port)
    where (select d.location_id from public.port_item_demand d
             where d.item_id = roles.item and d.active
             order by d.unit_price desc, d.location_id limit 1) is distinct from roles.top_port
       or 1 <> (select count(*) from public.port_item_demand d2
                  where d2.item_id = roles.item and d2.active
                    and d2.unit_price = (select max(d3.unit_price) from public.port_item_demand d3
                                           where d3.item_id = roles.item and d3.active));
  if v_n <> 0 then
    raise exception 'SALVAGE-0 self-assert FAIL: % item(s) violate strict port role differentiation', v_n;
  end if;

  -- 5. The canonical-run band: 3 scrap + 1 alloy at the best port lands in the 30..80 target.
  select 3 * (select unit_price from public.port_item_demand where location_id=c_slag and item_id='scrap')
       + (select unit_price from public.port_item_demand where location_id=c_slag and item_id='pirate_alloy')
    into v_n;
  if v_n < 30 or v_n > 80 then
    raise exception 'SALVAGE-0 self-assert FAIL: typical Snare run sale % outside the 30..80 band', v_n;
  end if;

  -- 6. The flag exists and is FALSE (dark).
  if public.cfg_bool('salvage_market_enabled') then
    raise exception 'SALVAGE-0 self-assert FAIL: salvage_market_enabled is not false at seed time';
  end if;

  raise notice 'SALVAGE-0 self-assert ok: 3 ports x 5 droppables active; drop-grounded; progression-free; roles strict; Snare-run sale % in 30..80; flag dark', v_n;
end $$;
