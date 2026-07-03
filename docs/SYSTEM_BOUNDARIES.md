# Byeharu — System Boundaries & Ownership Contract

> Companion to `docs/ARCHITECTURE.md`. This file is the **law of separation**.
> Approved 2026-06-16. Read before adding any table, function, or migration.

## Core law

Each system owns only its own responsibility and communicates through clear
server-side functions — **never** by directly changing another system's tables.

- **No system secretly controls another.** No spaghetti logic.
- **One sole writer per table.** Everyone else goes through that system's functions.
- **The cross-system call graph is acyclic.**
- **No direct client writes** to game state — only `SECURITY DEFINER` RPCs.
- **No combat logic inside movement.** No movement logic inside combat except
  *requesting* return via `Movement.create`.
- **No reward duplication.** No hidden state changes.

---

## 1. Master table → sole-writer matrix

| Table | Sole writer (owner) | Read access |
|---|---|---|
| `profiles` | **Auth** | owner |
| `sectors`, `zones`, `locations` | **Map** | public |
| `unit_types`, `game_config`, `item_types`, `support_craft_types`, `main_ship_hull_types` | **Reference/Config** (admin/migration) | public read-only |
| `zone_state`, `location_state` | **World State** | public |
| `bases`, `base_units`, `base_resources` | **Base** | owner |
| `fleets`, `fleet_units` | **Fleet** | owner |
| `fleet_movements` | **Movement** | owner |
| `location_presence` | **Presence** | owner |
| `combat_encounters`, `combat_rounds` | **Combat** | owner |
| `reward_grants` | **Reward** | owner |
| `combat_reports` | **Report** | owner |
| `build_orders` | **Production** (Training) | owner |
| `player_inventory`, `inventory_ledger` | **Inventory** | owner |
| `main_ship_instances` | **Main Ship** | owner |
| `trade_goods` | **Reference/Config** (admin/migration; Trade Market catalog) | public read-only |
| `ship_cargo_lots` | **Trade Cargo** | owner |
| `player_wallet` | **Wallet** | owner |
| `trade_receipts` | **Trade Market** | owner |
| `trade_relief_claims` | **Trade Market** | owner (owner-read) |
| `exploration_sites` | **Reference/Config** (admin/migration; static hidden world data — NO runtime writer) | **server-only** (RLS with no client policy/grant: site coordinates are never client-readable before discovery) |
| `exploration_discoveries` | **Exploration** (future RPC/processor — nothing writes it yet; DARK) | owner |

**Source of truth for active combat** = `combat_encounters` + `combat_rounds` +
`fleet_units` + `location_presence`. **Never** `combat_reports` (history only).

---

## 2. Per-system contract (owns / exposes / forbidden)

| System | Owns (writes) | Public functions (only way in) | Must NOT |
|---|---|---|---|
| **Map** | sectors, zones, locations | `get_world_map()`, `get_location_detail()` | move fleets · combat · rewards · change unit counts · create presence |
| **World State** | zone_state, location_state | `worldstate_register_presence(loc)`, `worldstate_unregister_presence(loc)`, `worldstate_tick()` | touch fleets/combat/rewards |
| **Base** | bases, base_units, base_resources | `initialize_new_player()`, `base_reserve_units(base,units)`, `base_merge_units(base,units)`, `base_add_resources(base,rewards)` *(only Reward calls this)*, `base_spend_resources(base,resource,amount)` *(only Production calls this)* | movement/combat logic |
| **Fleet** | fleets, fleet_units | `fleet_create(...)`, `fleet_set_moving/present/returning/complete/destroy(...)` *(state-guarded)*, `fleet_combat_stats(fleet)`, `fleet_sync_quantities(fleet,counts)`, `fleet_get_power(fleet)` | write base_/combat_/movement tables |
| **Movement** | fleet_movements | `movement_create(fleet,origin,target,mission)`, `movement_attach_cargo(movement,source,bundle,source_type='combat')` *(internal; attaches the pending `{metal?, items[]}` bundle + its activity-agnostic `reward_source_type` to the return movement — the ONE shared carrier every activity reuses)*, `process_fleet_movements()` | combat math · spawn pirates · rewards · unit losses · victory/defeat |
| **Presence** | location_presence | `presence_create(fleet,loc,activity)`, `presence_request_leave(presence)`, `presence_complete/destroy/expire(...)` | combat damage · resource writes · map writes |
| **Activity** *(no table — router)* | — | `activity_start(presence,type)` → `hunt_pirates`→Combat, `none`→no-op | own gameplay state; MVP only dispatches |
| **Combat** | combat_encounters, combat_rounds | `combat_create_encounter(presence)`, `process_combat_ticks()`, `combat_set_retreating(enc)` | move fleets (except request return via Movement) · edit map · add resources directly · mining/trade/captains |
| **Reward** | reward_grants | `reward_grant(source_type,source_id,player,base,bundle)` *(idempotent; splits the `{metal?, items[]}` bundle: metal → `Base.base_add_resources` (sole caller), items → `Inventory.inventory_deposit`)* | combat math · movement · write inventory/base tables directly |
| **Report** | combat_reports | `report_create(encounter)` *(idempotent)*, `get_combat_reports()` | **any** gameplay mutation · be a source of truth for active state |
| **Production** (Training) | build_orders | `train_units(base,unit,qty)` *(player)*, `process_build_queue()` *(cron)*, `production_create_order/complete_order(...)` *(internal)* | write base_units/base_resources directly (spends via `Base.base_spend_resources`, deposits via `Base.base_merge_units`) · touch combat/world-state/movement · change reward logic |
| **Inventory** | player_inventory, inventory_ledger | `inventory_deposit(player,item,qty,key?)` *(idempotent)*, `inventory_spend(player,item,qty)` *(transactional)*, `inventory_get_balance(player,item)` | combat/movement/world-state · be a source of truth for live combat · client writes · touch metal/`base_resources` (metal stays Base-owned) |
| **Main Ship** | main_ship_instances | `ensure_main_ship_for_player(player)` *(idempotent; ensures the first/sole ship)*, `get_main_ship(player)`, `rename_main_ship(player,name)`, `commission_first_main_ship()` / `commission_additional_main_ship()` *(the priced additional-ship path — DARK)* *(all server-only)*, `mainship_resolve_docked_location(ship)` *(shared read-only docked-location helper; internal, called DOWNWARD by the Trade Market RPCs)* — a player MAY own multiple `main_ship_instances` rows (the `player_id` UNIQUE was dropped in 0079); sole-ship is now a runtime shim / dark gate, not a schema constraint | touch fleets/combat/movement/production · drive expeditions yet · client writes |
| **Wallet** | player_wallet | `wallet_ensure(player)` *(the ONE shared lazy-ensure + seed: inserts the wallet exactly once with balance = `cfg_num('starting_credits')`; idempotent + unfarmable by the `player_id` conflict)*, `wallet_debit(player,amount)` *(ensure, then atomic conditional debit; false if too poor)*, `wallet_credit(player,amount)` *(ensure, then unconditional add)* — **internal** (no client grant); both writers call `wallet_ensure` (no duplicated ensure block). Called DOWNWARD by Main Ship (additional-ship commission debits `main_ship_price`) and Trade Market (buy debits / sell credits); reads `cfg_num('starting_credits')` from Reference/Config — a DOWNWARD read to an existing leaf. A **downward leaf**: depends on nothing above it → no cycle, no mutual/two-way dependency | write any other system's table · be called cyclically · client writes |
| **Trade Cargo** | ship_cargo_lots | `trade_cargo_add_lot(ship,good,qty,cost,origin)` *(insert)*, `trade_cargo_consume(ship,good,qty)` *(FIFO delete/update; returns consumed cost basis)* — **internal** (no client grant); per-ship, volume-keyed cargo lots hung on a `main_ship_instances` ship. A **leaf** Trade Market depends on downward | write main_ship_instances/player_wallet/trade_receipts · cache volume on the instance · client writes |
| **Trade Market** | trade_receipts, trade_relief_claims | `get_market_offers(ship)` *(read)*, `market_buy(ship,good,qty,req)`, `market_sell(ship,good,qty,req)` *(authenticated; idempotent on (ship,request_id))* — orchestrates buy/sell by fanning out one-directionally DOWNWARD to Wallet (debit/credit) + Trade Cargo (add/consume lots), reading `trade_goods` + the docked-location context (via the shared Main-Ship helper `mainship_resolve_docked_location`); writes only its own `trade_receipts`. **DARK**: every trade RPC is server-rejected while `trade_market_enabled=false`. The **no-softlock relief** orchestrator `market_claim_relief(request_id)` *(authenticated; idempotent on (player,request_id))* is sited here too and is the **SOLE writer** of `trade_relief_claims` (per-player idempotent ledger). It grants the relief credit THROUGH `wallet_credit` (so `player_wallet`'s sole-writer invariant holds — relief NEVER writes `player_wallet` directly), and reuses the EXISTING downward fan-out: it reads `player_wallet` directly `FOR UPDATE` (the rock-bottom balance check + per-account lock — a downward read, the write still goes only through Wallet), and reads `ship_cargo_lots` + `main_ship_instances` downward for the cargo check — so it introduces **no new edge and no cycle**, and Wallet stays a downward leaf. **DARK**: gated by `trade_relief_enabled=false`. Tunables (Reference/Config): `relief_credits`, `relief_cooldown_seconds`, `relief_max_lifetime_claims` | write ship_cargo_lots/player_wallet/main_ship_instances directly · second-write any table · run while the gate is off |

| **Exploration** | exploration_discoveries | *(none yet — Phase 11 in progress)*: every future exploration RPC/processor is **DARK** behind `exploration_enabled=false` (0097) and must reject-before-any-read while the gate is off. Will read `exploration_sites` DOWNWARD (server-only hidden Reference/Config data; seeded in 0098 with deterministic `reward_bundle_json` pending bundles) and hand rewards to the Engine via the existing activity-agnostic carrier (`movement_attach_cargo(…, 'exploration')` → `process_fleet_movements` → `Reward.grant`) — never a parallel deposit path | write exploration_sites (no runtime writer exists) · write inventory/base/fleet/movement/combat/world-state tables directly · read/write another activity's tables · expose an undiscovered site's coordinates to a client · run while the gate is off |

> **Trade fan-out is acyclic.** Trade Market → {Wallet, Trade Cargo}, Trade Market → Main Ship (read-only, via
> `mainship_resolve_docked_location`), and Main Ship → Wallet are all one-directional DOWNWARD edges. Wallet and
> Trade Cargo are leaves — each writes only its own table and calls nothing above it. (The Trade Market →
> Main-Ship-read edge already existed inline in the RPCs; it is now the single named helper.) Each of `trade_goods` / `ship_cargo_lots` / `player_wallet` / `trade_receipts` has
> exactly **one** sole-writer and **no second writer anywhere**. The whole trade feature stays DARK while
> `trade_market_enabled=false`. `trade_relief_claims` is Trade-Market-owned with exactly one
> sole-writer, `market_claim_relief` (DARK behind `trade_relief_enabled=false`), and no second writer anywhere. Its
> writer adds no new cross-system edge: the relief credit flows through `wallet_credit` (Wallet remains the sole
> `player_wallet` writer), and its `player_wallet`/`ship_cargo_lots`/`main_ship_instances` accesses are all
> DOWNWARD reads — so Wallet stays a downward leaf and the fan-out stays acyclic.

---

## 3. The only allowed call-edges (5 entry points)

Player RPCs and cron processors are **orchestrators**. They call system functions in
order and never write another system's tables.

**`send_fleet_to_location(base, location, units)`** *(player RPC)*
→ validate (ownership · units available & positive · location valid/active/unlocked ·
mission allowed · fleet limit · not-already-assigned)
→ `Base.reserve_units` → `Fleet.create` → `Movement.create` → `Fleet.set_moving`

**`process_fleet_movements()`** *(cron 30s · `FOR UPDATE SKIP LOCKED` · idempotent on `resolved_at`)*
- outbound arrival → `Movement.mark_arrived` → `Fleet.set_present` → `Presence.create`
  *(→ `WorldState.register_presence` + `Activity.start` → `Combat.create_encounter` for hunt)*
- return arrival → `Movement.mark_arrived` → `Base.merge_units` → `Fleet.complete`
  *(→ `Reward.grant(reward_source_type, bundle)` secures the carried `{metal?, items[]}` once
  under the movement's activity-agnostic `reward_source_type` — today always `'combat'`;
  exploration/mining/trade reuse the same carrier additively: metal →
  `Base.add_resources`, items → `Inventory.inventory_deposit`)*

**`process_combat_ticks()`** *(cron 10–15s · locked · idempotent on `last_resolved_at`/`ended_at`)*
→ load units via `Fleet.get` → spawn wave → `Fleet.apply_losses` → accrue pending
reward on encounter → insert `combat_round`
→ on end: rewards ride the return movement as a `{metal?, items[]}` bundle and are
secured by `Reward.grant` **on home arrival only** *(→ `Base.add_resources` for metal,
`Inventory.inventory_deposit` for items)* → `Report.create` →
`Presence.complete` *(→ `WorldState.unregister_presence`)* →
`Movement.create(return)` + `Fleet.set_returning`, **or** `Fleet.destroy` on death

**`request_leave_location(presence)`** *(player RPC)*
→ validate → `Presence.set_retreating` → `Combat.set_retreating`
*(return movement created later by the combat tick after `retreat_delay_seconds`)*

**`process_location_state_ticks()`** *(cron 60s)* → `WorldState.tick()` only

### Explicitly forbidden edges
- Movement → never writes `base_units`/`fleet_units`/`combat_*`.
- Combat → never writes `base_resources` (only via `Reward.grant`); never writes
  `fleet_movements` except via `Movement.create`.
- Presence → never writes `location_state` (only via `WorldState.*`) or `combat_*`.
- Report → writes only `combat_reports`; never read as source of truth for active state.
- Client → writes nothing; calls RPCs only.

---

## 4. Beyond-spec ownership decisions (approved 2026-06-16)

1. **Fleet System** split from Movement — sole owner of `fleets`+`fleet_units`.
2. **Base System** — sole owner of `base_units`+`base_resources` via reserve/merge/add.
3. **World State System** — sole owner of `zone_state`+`location_state`; Map stays static.
4. **Reward ledger** `reward_grants` + idempotent `reward_grant()` = only reward path.
5. **Activity** owns no table in MVP — thin router / extension point.
6. **Support craft (Phase 6)** — `support_craft_types` is **Reference/Config metadata only**
   (public read, no client write, no functions). Capacity-limited loadout definitions
   (`capacity_cost`, role, activity tags, tradeoffs). **No instances, no expedition
   attachment, no capacity enforcement, no stat consumption yet** — combat still uses
   `unit_types` (separate namespace). A future main ship exposes finite `support_capacity`
   and `calculate_expedition_stats` consumes these (Phases 7–8).
7. **Main Ship (Phase 7)** — `main_ship_hull_types` = Reference/Config (public read);
   `main_ship_instances` = the Main Ship system (owner-read). It was originally one row per player via a
   `player_id` UNIQUE, but that UNIQUE was **dropped in migration 0079 (TRADE-FLEET-0C)** — a player MAY now
   own multiple `main_ship_instances` rows. Multi-ship is structurally allowed but stays **DARK**: the
   sole-ship behavior is now a runtime shim / dark gate (`mainship_additional_commission_enabled=false`), NOT a
   schema UNIQUE. Writes only through the Main-Ship server functions (`ensure/get/rename` + the priced
   commission path), all server-only. The hull
   exposes the finite `support_capacity` a future `calculate_expedition_stats` will enforce.
   **Phase 7 does NOT drive expeditions** — the ship sits `home`, untouched by combat/fleet/
   movement/production; nothing consumes it yet.
8. **Stat adapter (Phase 8)** — `calculate_expedition_stats(player, main_ship_id, loadout,
   activity)` owns **no table**; it is a **pure read/compute** function (reads
   `main_ship_instances` + `main_ship_hull_types` + `support_craft_types`, enforces
   `support_capacity` as a hard cap, returns normalized stats). It **must NOT** mutate any
   state — no expeditions/fleets/combat/rewards/inventory/ranking/reports/ship/support counts.
   It is the future single source of expedition stats (later +captains +modules), but is
   **not wired into live combat yet** — the proven fleet-stack path still owns outcomes.

These keep every architecture law enforceable with a single-writer-per-table rule.

---

## 5. Invariant checklist (every PR/migration must keep true)

- [ ] Each table still has exactly one writing system.
- [ ] Cross-system changes go only through the exposed functions above.
- [ ] Call graph remains acyclic (Combat→Movement only via `create(return)`).
- [ ] Activity remains table-less for MVP.
- [ ] `reward_grants` remains the only reward-application path.
- [ ] `combat_reports` remains history only, never source of truth.
- [ ] No client write path to any game-state table.
