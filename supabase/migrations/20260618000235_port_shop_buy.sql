-- Byeharu — PORT-SHOP (0235): the port outfitter — buy cheap ENTRY-LEVEL fitting modules + ammo at a
-- port, for credits. The BUY-side mirror of SALVAGE (0174 sell_item_at_port) and the credit-debit
-- twin of REPAIR (0201). DARK behind the NEW `port_shop_enabled` flag, seeded 'false'.
--
-- ── WHY (owner playtest directive) ───────────────────────────────────────────────────────────────
-- A new player docks and needs to KIT OUT their first ship — offense, defense/shields, mobility — but
-- today the ONLY way to obtain a fitting module is to CRAFT it (craft_module, 0109: items-only recipes,
-- gated on deep combat/mining drops). There is no credits→gear path at all. This slice adds the first
-- one: a per-port outfitter that SELLS the existing beginner module catalog (+ one ammo item) for
-- credits, granting them into the SAME player possession the fitting flow already reads —
-- module_instances (get_my_module_instances → fit_module_to_ship) for modules, player_inventory for
-- items. No parallel gear system: the shop is a new CREDITS ENTRY onto the shipped Modules/Fitting/
-- Inventory pipeline, nothing more.
--
-- ── COMPOSES, FORKS NOTHING (the no-spaghetti law) ───────────────────────────────────────────────
--   • MODULE grant  → `modules_mint_instance` (0108) — the ONE module_instances writer, already the
--     craft command's mint path (0109). The shop is its SECOND caller, same key contract
--     ('shop:'||player||':'||request_id, the 0108 producer-namespacing law).
--   • ITEM grant    → `inventory_deposit` (0039) — the ONE player_inventory writer (idempotent by key).
--   • CREDIT debit  → `wallet_debit` (0093/0089) — the ONE player_wallet debiter (atomic conditional),
--     EXACTLY the repair (0201) + market_buy (0089) edge. Never a direct wallet write.
--   • DOCK / OWNERSHIP / LOCK → the shared resolvers mainship_resolve_owned_ship (0081),
--     mainship_resolve_docked_location (0092), mainship_space_lock_context (0138) — the salvage/repair
--     posture verbatim. UI is never trusted for ownership or docking.
--   • The bought modules feed calculate_expedition_stats through the EXISTING fitting join — their
--     stats_json (attack/defense/evasion/speed_mult_bonus/…) and combat attributes (range/power, 0229)
--     are the SAME columns the adapter + ship_weapon_modules already read; the shop adds no stat wiring.
--
-- ── WHAT'S SOLD (the beginner outfit; [D] owner-tunable — a retune is a one-migration reseed) ─────
-- MODULES (mint one instance per buy) — the shipped BEGINNER tier, one per archetype so a first ship
-- can cover offense / defense / mobility / utility. Mk-II tiers (0202) are DELIBERATELY excluded
-- (progression gear, craft-gated on blueprint_fragment/artifact_core — never a cash beginner buy):
--   autocannon_battery      weapon  slot 1  attack 10           120 cr   (basic weapon — offense)
--   shield_generator        defense slot 1  defense  6           80 cr   (NEW: entry shield — see below)
--   shield_lattice          defense slot 1  defense 12          140 cr   (standard shield, 0183)
--   vector_thruster_kit     engine  slot 1  evasion 3/+10% spd  100 cr   (movement-speed — mobility)
--   deep_scan_sensor_array  sensor  slot 1  scan 8               90 cr   (utility — vision)
--   expanded_cargo_lattice  cargo   slot 2  cargo 25            130 cr   (utility — hold)
--   mining_rig_extension    mining  slot 1  mining 8            110 cr   (utility — extraction)
-- ITEMS (deposit into inventory) :
--   autocannon_rounds  (NEW ammo item)                            2 cr/unit  (bulk kinetic rounds)
-- All prices sit cheap against the 250-credit hull and the ~30–80-credit salvage run (0174): a couple
-- of hunts buys a first module. All three starter ports carry the IDENTICAL outfit — a port is a port
-- for the beginner shop (role-differentiation is the SELL-side salvage market's job, 0174, not this).
--
-- ── TWO NEW CATALOG ROWS (the coordinator's "seed cheap beginner entries if they don't exist") ────
--   1. item_types 'autocannon_rounds' — the FIRST ammunition item. The module_types.ammo_type column
--      (0229) was built "for a FUTURE ammo-tracked weapon … forward-only"; this slice takes that
--      forward step: it seeds the ammo item AND wires autocannon_battery.ammo_type → it (a guarded,
--      write-once UPDATE). INERT TODAY: no combat consumer reads ammo_type yet (0229 states ammo
--      consumption has no engine consumer — module_range_attributes_enabled gates only the range
--      read), so wiring it changes NO behavior; it makes the ammo item MEANINGFUL (the autocannon's
--      declared ammunition) rather than a vacuous item (the F4 "never seed an item nothing uses" law),
--      and it is reversible (ammo_type back to NULL).
--   2. module_types 'shield_generator' — a NEW entry-tier defense module (defense 6, slot 1), the
--      cheap first shield that sits UNDER shield_lattice (defense 12). Additive catalog data exactly
--      like 0183 added shield_lattice: reuses the 'defense' archetype and the adapter-read 'defense'
--      stats_json key (prosrc-pinned below, the 0183/0202 stat-key law). SHOP-ONLY by design — it
--      carries NO module_recipe_ingredients (it is a bought beginner module, not a crafted one); a
--      recipe can be added forward-only later. It does NOT touch the shield-BAR resource
--      (main_ship_instances.shield, 0191) — wiring a module to that bar is a shield-engine change,
--      out of this seed slice's scope; 'defense' is the survival-stat contribution the fitting adapter
--      already folds.
--
-- ── DARK BY CONSTRUCTION ─────────────────────────────────────────────────────────────────────────
-- `port_shop_enabled` seeded 'false'. buy_shop_offer_at_port checks it FIRST and rejects
-- (port_shop_disabled) before ANY read; get_port_shop rejects the same while dark so the UI panel
-- renders nothing (the get_my_ship_fittings 0116 gated-read posture). Activation is the human's
-- scripts/activate-port-shop.sql (flag flip only), never a migration. Rollback = flag back to false.
-- The two new catalog rows are inert public data until then (a shop that cannot be reached sells
-- nothing; ammo_type wiring has no consumer). This migration flips NOTHING.
--
-- ── OWNERSHIP (docs/SYSTEM_BOUNDARIES.md posture) ────────────────────────────────────────────────
--   • port_shop_offers   = Reference/Config: MIGRATION-SEEDED ONLY, no runtime writer (the
--     port_item_demand 0174 posture). Public read-only.
--   • port_shop_receipts = Port Shop: sole writer = buy_shop_offer_at_port (this migration).
--     Owner-read via the owning ship (the salvage_receipts/repair_receipts posture).
--   • module_instances / player_inventory / player_wallet: the shop is an ADDITIONAL authorized
--     CALLER of their sole writers (mint/deposit/debit) — never a direct writer of any of them.
-- WHY A NEW RECEIPTS TABLE (not salvage/repair): those pin their own domain columns (item_id+qty /
-- hp fields); a purchase is polymorphic (module OR item). Its own table carries the IDENTICAL
-- idempotency shape: (main_ship_id, request_id) unique, replay-verbatim (the 0174/0201 law).
--
-- Forward-only: 0001–0234 unedited. modules_mint_instance / inventory_deposit / wallet_debit /
-- craft_module / the resolvers are UNTOUCHED (no re-create — new additive surface only).

-- ── 1) the dark capability gate — seeded 'false' (the 0174/0201 idiom) ───────────────────────────
insert into public.game_config (key, value, description) values
  ('port_shop_enabled', 'false',
   'PORT-SHOP (0235): server-authoritative dark gate for the port outfitter — buy entry-level '
   'fitting modules + ammo for credits at a port (buy_shop_offer_at_port; get_port_shop read). OFF '
   'until the owner flips it (scripts/activate-port-shop.sql). Both RPCs check this FIRST and reject '
   '(port_shop_disabled) before any read while false; the ShopPanel renders nothing.')
on conflict (key) do nothing;

-- ── 2) the NEW ammo item + the NEW entry-shield module (idempotent catalog seeds) ────────────────
insert into public.item_types (item_id, name, category, rarity, stackable, description) values
  ('autocannon_rounds', 'Autocannon Rounds', 'ammunition', 'common', true,
   'Standard kinetic rounds for autocannon batteries. Bought in bulk at a port outfitter; the '
   'autocannon''s declared ammunition.')
on conflict (item_id) do nothing;

insert into public.module_types (id, name, slot_type, description, slot_cost, stats_json) values
  ('shield_generator', 'Shield Generator', 'defense',
   'A compact deflector generator — the cheapest first answer to incoming fire. Lighter protection '
   'than a full Shield Lattice, at an entry-level price for a new ship''s first loadout.',
   1, '{"defense": 6}'::jsonb)
on conflict (id) do nothing;

-- Wire the autocannon's ammunition forward-only (the 0229 ammo_type column's stated purpose). Guarded
-- write-once (only when still NULL) so a later owner retune is never clobbered. INERT: no consumer
-- reads ammo_type for consumption yet, so this changes no behavior — it only makes the ammo meaningful.
update public.module_types
   set ammo_type = 'autocannon_rounds'
 where id = 'autocannon_battery' and ammo_type is null;

-- ── 3) port_shop_offers — Reference/Config buy-list (migration-seeded ONLY; no runtime writer) ────
-- Polymorphic by (kind, module_type_id|item_id): a module offer mints an instance, an item offer
-- deposits inventory. ref_id (= the module_type_id or item_id) is the per-port key; the CHECK binds
-- kind ↔ the matching non-null FK ↔ ref_id so a row can never be half-typed.
create table if not exists public.port_shop_offers (
  location_id    uuid    not null references public.locations (id),
  kind           text    not null check (kind in ('module', 'item')),
  module_type_id text    references public.module_types (id),
  item_id        text    references public.item_types (item_id),
  ref_id         text    not null,                          -- = module_type_id (module) | item_id (item)
  price          numeric not null check (price > 0),        -- credits per unit (module: per instance)
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  primary key (location_id, ref_id),
  constraint port_shop_offers_kind_ref check (
    (kind = 'module' and module_type_id is not null and item_id is null and ref_id = module_type_id) or
    (kind = 'item'   and item_id is not null and module_type_id is null and ref_id = item_id))
);

alter table public.port_shop_offers enable row level security;
-- Public read-only (the port_item_demand 0174 posture): NO insert/update/delete policy and NO write
-- grant → clients cannot mutate; migrations/admin are the ONLY writer. Visibility is gated at the
-- get_port_shop RPC (dark → the panel renders nothing); the table read is harmless price data.
create policy "port_shop_offers_public_read" on public.port_shop_offers for select using (true);
grant select on public.port_shop_offers to anon, authenticated;

-- ── 4) Seed the beginner outfit at all 3 starter ports (idempotent; converges on re-apply) ───────
-- Same outfit at every starter port (a port is a port for the beginner shop). Prices [D].
insert into public.port_shop_offers (location_id, kind, module_type_id, item_id, ref_id, price)
select p.location_id, o.kind, o.module_type_id, o.item_id, o.ref_id, o.price
from (values
    ('b1a00001-0066-4a00-8a00-000000000001'::uuid),   -- Haven Reach
    ('b1a00002-0066-4a00-8a00-000000000002'::uuid),   -- Slagworks Anchorage
    ('b1a00003-0066-4a00-8a00-000000000003'::uuid)    -- Driftmarch Waypost
  ) p(location_id)
cross join (values
    ('module', 'autocannon_battery',      null, 'autocannon_battery',     120::numeric),
    ('module', 'shield_generator',        null, 'shield_generator',        80::numeric),
    ('module', 'shield_lattice',          null, 'shield_lattice',         140::numeric),
    ('module', 'vector_thruster_kit',     null, 'vector_thruster_kit',    100::numeric),
    ('module', 'deep_scan_sensor_array',  null, 'deep_scan_sensor_array',  90::numeric),
    ('module', 'expanded_cargo_lattice',  null, 'expanded_cargo_lattice', 130::numeric),
    ('module', 'mining_rig_extension',    null, 'mining_rig_extension',   110::numeric),
    ('item',   null, 'autocannon_rounds', 'autocannon_rounds',             2::numeric)
  ) o(kind, module_type_id, item_id, ref_id, price)
on conflict (location_id, ref_id) do update
  set price = excluded.price, active = true;

-- ── 5) port_shop_receipts — the per-ship idempotent purchase record (the 0174/0201 receipts shape) ──
create table if not exists public.port_shop_receipts (
  receipt_id   uuid    primary key default gen_random_uuid(),
  main_ship_id uuid    not null references public.main_ship_instances (main_ship_id),  -- NEVER player_id
  request_id   uuid    not null,
  location_id  uuid    references public.locations (id),        -- the port the purchase occurred at
  kind         text    not null,                               -- 'module' | 'item' (snapshot)
  ref_id       text    not null,                               -- module_type_id | item_id purchased
  quantity     integer not null check (quantity > 0),          -- module: always 1; item: units bought
  unit_price   numeric not null check (unit_price >= 0),       -- per-unit credits at purchase time
  total_price  numeric not null check (total_price >= 0),      -- quantity * unit_price at purchase time
  instance_id  uuid    references public.module_instances (id),-- the minted instance (module buys only)
  created_at   timestamptz not null default now(),
  unique (main_ship_id, request_id)                            -- per-ship idempotency key (0174 §4)
);
create index if not exists port_shop_receipts_main_ship_id_idx on public.port_shop_receipts (main_ship_id);

alter table public.port_shop_receipts enable row level security;
-- Owner-read via join to the owning ship (the salvage/repair receipts posture); authenticated, NOT
-- anon. NO client write policy/grant → buy_shop_offer_at_port (SECURITY DEFINER) is the sole writer.
create policy "port_shop_receipts_select_own" on public.port_shop_receipts
  for select using (
    exists (
      select 1 from public.main_ship_instances m
      where m.main_ship_id = port_shop_receipts.main_ship_id
        and m.player_id = auth.uid()
    )
  );
grant select on public.port_shop_receipts to authenticated;

-- ── 6) buy_shop_offer_at_port — the purchase orchestrator (the 0174 sell mold, buy-side) ─────────
-- Atomic + idempotent, ONE function/transaction under the per-ship lock. Fan-out one-directional
-- DOWNWARD: Main Ship (resolve/lock/dock, read-only) → Reference/Config (port_shop_offers) → Wallet
-- (wallet_debit — the ONE player_wallet writer) → Modules (modules_mint_instance) OR Inventory
-- (inventory_deposit) → its own port_shop_receipts. NO other table written.
--
-- REJECT ORDER (each named): not_authenticated → port_shop_disabled (gate FIRST, before ANY read) →
-- invalid_request → invalid_ref → invalid_quantity (units are INTEGER; fractional/non-positive/>1e6
-- reject) → ship_not_found → not_docked → no_offer → module_qty_must_be_one (a module buy is always
-- exactly one instance) → idempotent_replay → insufficient_credits (wallet_debit false — NOTHING
-- written) → ok. All-or-nothing: any raise/false rolls the whole txn back.
create or replace function public.buy_shop_offer_at_port(
  p_main_ship_id uuid, p_ref_id text, p_quantity numeric, p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     uuid;
  v_loc      uuid;
  v_offer    public.port_shop_offers%rowtype;
  v_existing public.port_shop_receipts%rowtype;
  v_qty      integer;
  v_total    numeric;
  v_instance uuid;
  v_receipt  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject: reject deterministically BEFORE any ship/offer read.
  if not public.cfg_bool('port_shop_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'port_shop_disabled');
  end if;

  -- input validation. Units are INTEGER (module instances + player_inventory.quantity are integer):
  -- null/non-positive/fractional reject; the 1e6 cap keeps the integer cast safe.
  if p_request_id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_request'); end if;
  if p_ref_id is null or p_ref_id = '' then return jsonb_build_object('ok', false, 'reason', 'invalid_ref'); end if;
  if p_quantity is null or p_quantity <= 0 or p_quantity <> floor(p_quantity) or p_quantity > 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
  end if;
  v_qty := p_quantity::integer;

  -- resolve the SELECTED owned ship (ownership asserted) or the sole ship (shim); UI never trusted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;

  -- PER-SHIP LOCK (0138 idiom): held to txn end, so the replay check and the debit/mint/deposit/
  -- receipt writes below are one race-safe critical section against concurrent buys on the SAME ship.
  perform public.mainship_space_lock_context(v_ship);

  -- DOCKED check via the ONE shared resolver (0092/0138 — never inlined, never the client).
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- OFFER: this port's ACTIVE offer row for this ref (Reference/Config; read-only). Unknown refs and
  -- offers at another port fall out here (no_offer).
  select * into v_offer from public.port_shop_offers
    where location_id = v_loc and ref_id = p_ref_id and active;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_offer'); end if;

  -- A module purchase is ALWAYS exactly one instance (one mint per buy — the 0108 one-craft-one-
  -- instance law). Multi-unit is items-only (ammo).
  if v_offer.kind = 'module' and v_qty <> 1 then
    return jsonb_build_object('ok', false, 'reason', 'module_qty_must_be_one');
  end if;

  -- IDEMPOTENCY: a receipt for (ship, request_id) already exists → replay verbatim, no write, no
  -- re-debit, no re-mint/deposit (the 0174 salvage-receipts semantics; no payload-conflict check).
  select * into v_existing from public.port_shop_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'main_ship_id', v_ship,
      'kind', v_existing.kind, 'ref_id', v_existing.ref_id, 'quantity', v_existing.quantity,
      'unit_price', v_existing.unit_price, 'total_price', v_existing.total_price,
      'instance_id', v_existing.instance_id, 'location_id', v_existing.location_id);
  end if;

  v_total := v_qty * v_offer.price;

  -- WALLET debit (atomic conditional; false → too poor → NOTHING granted/receipted — the 0089/0201 law).
  if not public.wallet_debit(v_player, v_total) then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_credits',
      'price', v_total, 'quantity', v_qty, 'unit_price', v_offer.price);
  end if;

  -- GRANT: mint a module instance OR deposit the item, through the EXISTING sole writers. An exception
  -- here aborts the WHOLE txn: the debit rolls back, no receipt — all-or-nothing.
  if v_offer.kind = 'module' then
    -- key namespaced per the 0108 producer contract (the craft command's 'craft:' sibling).
    v_instance := public.modules_mint_instance(
      v_player, v_offer.module_type_id, 'shop:' || v_player::text || ':' || p_request_id::text);
  else
    -- idempotent deposit (the ledger insert is the guard, 0039); same key namespace.
    perform public.inventory_deposit(
      v_player, v_offer.item_id, v_qty, 'shop:' || v_player::text || ':' || p_request_id::text);
  end if;

  -- RECEIPT (Port Shop writes port_shop_receipts directly — its own table; the (main_ship_id,
  -- request_id) key finalizes idempotency atomically with the debit + grant).
  insert into public.port_shop_receipts
    (main_ship_id, request_id, location_id, kind, ref_id, quantity, unit_price, total_price, instance_id)
    values (v_ship, p_request_id, v_loc, v_offer.kind, p_ref_id, v_qty, v_offer.price, v_total, v_instance)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt, 'main_ship_id', v_ship,
    'kind', v_offer.kind, 'ref_id', p_ref_id, 'quantity', v_qty,
    'unit_price', v_offer.price, 'total_price', v_total,
    'instance_id', v_instance, 'location_id', v_loc);
end;
$$;
-- ACL: authenticated client RPC (server-rejected while dark — the 0174 posture); anon/public never.
revoke execute on function public.buy_shop_offer_at_port(uuid, text, numeric, uuid) from public, anon;
grant  execute on function public.buy_shop_offer_at_port(uuid, text, numeric, uuid) to authenticated;

-- ── 7) get_port_shop — the gated read surface for the shop panel (the 0116 gated-read posture) ────
-- Returns this port's active offers joined DOWNWARD to their catalog display (module: name/slot_type/
-- slot_cost/stats_json/range/power/ammo_type; item: name/category/rarity/description) so the panel and
-- the item-info surface read the SAME attributes. Gate FIRST → port_shop_disabled while dark, so the
-- panel renders nothing (the get_my_ship_fittings 0116 idiom). Read-only; writes nothing.
create or replace function public.get_port_shop(p_location_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_offers jsonb;
  c_empty  constant jsonb := '[]'::jsonb;
begin
  -- DARK server-reject FIRST (identical envelope regardless of caller — no probing while dark).
  if not public.cfg_bool('port_shop_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'port_shop_disabled');
  end if;
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  if p_location_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_location');
  end if;

  select coalesce(jsonb_agg(offer_json order by kind, name), c_empty) into v_offers
  from (
    select o.kind,
           coalesce(mt.name, it.name) as name,
           jsonb_build_object(
             'kind', o.kind, 'ref_id', o.ref_id, 'price', o.price,
             'name', coalesce(mt.name, it.name),
             'slot_type', mt.slot_type, 'slot_cost', mt.slot_cost, 'stats_json', mt.stats_json,
             'range', mt.range, 'power', mt.power, 'ammo_type', mt.ammo_type,
             'category', it.category, 'rarity', it.rarity,
             'description', coalesce(mt.description, it.description)) as offer_json
      from public.port_shop_offers o
      left join public.module_types mt on mt.id = o.module_type_id
      left join public.item_types  it on it.item_id = o.item_id
     where o.location_id = p_location_id and o.active
  ) s;

  return jsonb_build_object('ok', true, 'location_id', p_location_id, 'offers', coalesce(v_offers, c_empty));
end;
$$;
revoke execute on function public.get_port_shop(uuid) from public, anon;
grant  execute on function public.get_port_shop(uuid) to authenticated;

-- ── 8) Self-assert: seeds complete, catalog rows sane, gate dark, RPCs gate-first + ACL correct ──
do $$
declare
  c_haven constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_n     integer;
  v_src   text;
begin
  -- 1. the gate exists and is FALSE (dark) at seed time.
  if public.cfg_bool('port_shop_enabled') then
    raise exception 'PORT-SHOP self-assert FAIL: port_shop_enabled is not false at seed time';
  end if;

  -- 2. the two new catalog rows exist with the exact seeded shape.
  if not exists (select 1 from public.item_types
                  where item_id = 'autocannon_rounds' and category = 'ammunition' and stackable) then
    raise exception 'PORT-SHOP self-assert FAIL: autocannon_rounds ammo item missing/mis-shaped';
  end if;
  if not exists (select 1 from public.module_types
                  where id = 'shield_generator' and slot_type = 'defense' and slot_cost = 1
                    and stats_json = '{"defense": 6}'::jsonb) then
    raise exception 'PORT-SHOP self-assert FAIL: shield_generator module missing/mis-shaped';
  end if;
  -- shield_generator fits the smallest shipped hull (slot_cost <= min base_module_slots).
  if (select slot_cost from public.module_types where id = 'shield_generator')
     > (select min(base_module_slots) from public.main_ship_hull_types) then
    raise exception 'PORT-SHOP self-assert FAIL: shield_generator cannot fit the smallest hull';
  end if;

  -- 3. STAT-KEY PIN (the 0183 law): shield_generator's 'defense' key is one the DEPLOYED adapter reads,
  --    so it is not a dead module.
  select prosrc into v_src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'calculate_expedition_stats';
  if v_src is null or strpos(v_src, '(m.stats_json->>''defense'')') = 0 then
    raise exception 'PORT-SHOP self-assert FAIL: adapter does not read the ''defense'' key shield_generator seeds (dead module)';
  end if;

  -- 4. the autocannon's ammo_type is wired to the new ammo item (the forward-only 0229 step).
  if not exists (select 1 from public.module_types
                  where id = 'autocannon_battery' and ammo_type = 'autocannon_rounds') then
    raise exception 'PORT-SHOP self-assert FAIL: autocannon_battery.ammo_type not wired to autocannon_rounds';
  end if;

  -- 5. every offered module ref is a real module_types row, every item ref a real item_types row
  --    (the CHECK + FKs enforce this — asserted anyway so a future relaxation cannot orphan an offer).
  select count(*) into v_n from public.port_shop_offers o
    where (o.kind = 'module' and not exists (select 1 from public.module_types m where m.id = o.module_type_id))
       or (o.kind = 'item'   and not exists (select 1 from public.item_types  t where t.item_id = o.item_id));
  if v_n <> 0 then
    raise exception 'PORT-SHOP self-assert FAIL: % shop offer(s) reference a missing catalog row', v_n;
  end if;

  -- 6. completeness: each starter port carries the full beginner outfit (7 modules + 1 item = 8 active).
  select count(*) into v_n from unnest(array[c_haven, c_slag, c_drift]) p
    where (select count(*) from public.port_shop_offers o where o.location_id = p and o.active) <> 8;
  if v_n <> 0 then
    raise exception 'PORT-SHOP self-assert FAIL: % starter port(s) do not carry exactly 8 active offers', v_n;
  end if;
  -- the Mk-II progression tiers are NOT sold (beginner shop only).
  if exists (select 1 from public.port_shop_offers
              where ref_id in ('autocannon_battery_mk2', 'shield_lattice_mk2')) then
    raise exception 'PORT-SHOP self-assert FAIL: a Mk-II progression module is on sale (beginner shop only)';
  end if;

  -- 7. both RPCs exist, gate FIRST while dark, and are authenticated-only (never anon).
  if to_regprocedure('public.buy_shop_offer_at_port(uuid, text, numeric, uuid)') is null then
    raise exception 'PORT-SHOP self-assert FAIL: buy_shop_offer_at_port(uuid,text,numeric,uuid) missing';
  end if;
  if to_regprocedure('public.get_port_shop(uuid)') is null then
    raise exception 'PORT-SHOP self-assert FAIL: get_port_shop(uuid) missing';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.buy_shop_offer_at_port(uuid, text, numeric, uuid)')::oid;
  if position('port_shop_disabled' in v_src) = 0 then
    raise exception 'PORT-SHOP self-assert FAIL: buy_shop_offer_at_port lacks the dark gate reject';
  end if;
  if not has_function_privilege('authenticated', 'public.buy_shop_offer_at_port(uuid,text,numeric,uuid)', 'execute')
     or has_function_privilege('anon', 'public.buy_shop_offer_at_port(uuid,text,numeric,uuid)', 'execute') then
    raise exception 'PORT-SHOP self-assert FAIL: buy_shop_offer_at_port ACL drifted (want authenticated-only, never anon)';
  end if;
  if not has_function_privilege('authenticated', 'public.get_port_shop(uuid)', 'execute')
     or has_function_privilege('anon', 'public.get_port_shop(uuid)', 'execute') then
    raise exception 'PORT-SHOP self-assert FAIL: get_port_shop ACL drifted (want authenticated-only, never anon)';
  end if;

  raise notice 'PORT-SHOP self-assert ok: gate dark; autocannon_rounds + shield_generator seeded (defense-6, adapter-read, fits smallest hull); autocannon ammo wired; 3 ports x 8 active offers (Mk-II excluded); buy + read RPCs gate-first, authenticated-only';
end $$;
