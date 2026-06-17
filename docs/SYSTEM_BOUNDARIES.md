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
| `unit_types`, `game_config`, `item_types` | **Reference/Config** (admin/migration) | public read-only |
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
| **Movement** | fleet_movements | `movement_create(fleet,origin,target,mission)`, `process_fleet_movements()` | combat math · spawn pirates · rewards · unit losses · victory/defeat |
| **Presence** | location_presence | `presence_create(fleet,loc,activity)`, `presence_request_leave(presence)`, `presence_complete/destroy/expire(...)` | combat damage · resource writes · map writes |
| **Activity** *(no table — router)* | — | `activity_start(presence,type)` → `hunt_pirates`→Combat, `none`→no-op | own gameplay state; MVP only dispatches |
| **Combat** | combat_encounters, combat_rounds | `combat_create_encounter(presence)`, `process_combat_ticks()`, `combat_set_retreating(enc)` | move fleets (except request return via Movement) · edit map · add resources directly · mining/trade/captains |
| **Reward** | reward_grants | `reward_grant(source_type,source_id,player,base,bundle)` *(idempotent; splits the `{metal?, items[]}` bundle: metal → `Base.base_add_resources` (sole caller), items → `Inventory.inventory_deposit`)* | combat math · movement · write inventory/base tables directly |
| **Report** | combat_reports | `report_create(encounter)` *(idempotent)*, `get_combat_reports()` | **any** gameplay mutation · be a source of truth for active state |
| **Production** (Training) | build_orders | `train_units(base,unit,qty)` *(player)*, `process_build_queue()` *(cron)*, `production_create_order/complete_order(...)` *(internal)* | write base_units/base_resources directly (spends via `Base.base_spend_resources`, deposits via `Base.base_merge_units`) · touch combat/world-state/movement · change reward logic |
| **Inventory** | player_inventory, inventory_ledger | `inventory_deposit(player,item,qty,key?)` *(idempotent)*, `inventory_spend(player,item,qty)` *(transactional)*, `inventory_get_balance(player,item)` | combat/movement/world-state · be a source of truth for live combat · client writes · touch metal/`base_resources` (metal stays Base-owned) |

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
  *(→ `Reward.grant(bundle)` secures the carried `{metal?, items[]}` once: metal →
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
