# Byeharu — Forward Roadmap & Game Direction

> Authoritative statement of where Byeharu is going, recorded 2026-06-17 (Phase 1
> reconciliation). The engine design lives in `ARCHITECTURE.md`; the per-system
> ownership law in `SYSTEM_BOUNDARIES.md`; the running history in `DEV_LOG.md`.

## Final game identity

Byeharu is a **main-ship expedition game** — not mass anonymous fleet management.

```
One main ship + captains + modules + support craft + cargo
  → send an Expedition to a pirate / trade / exploration / mining location
  → fight / trade / scan / extract
  → return home to secure loot, profit, resources, discoveries, ranking points
  → craft / upgrade / repair → stronger next expedition
```

Core fantasy: *"my ship and crew go on dangerous expeditions, return with rewards, and
become stronger."*

## What is already built (KEEP — reclassified, not rewritten)

- **M2–M4 = the Expedition Engine.** travel · arrival · pirate combat (3s ticks) · rising
  waves · per-unit HP/losses · retreat (still takes damage) · return movement ·
  **reward deposit only on home arrival** · combat report. Reused by every future activity.
- **M4.5 = the Serial Build Queue Foundation.** serial queue · one active slot · waiting
  orders don't tick · cancel + refund/penalty preview · per-ship + total time · active
  progress · history fold · friendly location labels. Future meaning: **support craft /
  module / repair-kit / drone / equipment production** (same queue).
- **M5–M7** (also done): World State pressure/danger (60s cron, decay-to-baseline);
  frontend depth (location panel, round log, /reports); metal-spend ship training.

## Standing laws (every future system obeys these)

1. **Main-ship centered.** The main ship is a unique INSTANCE (not stackable), the emotional
   center; usually returns damaged / needs repair rather than being deleted.
2. **Support craft are capacity-limited loadout choices, NOT additive power.** Each consumes
   `support_capacity`; specialized roles with opposing tradeoffs (combat↔cargo, safety↔speed,
   scouting↔fighting, repair↔damage, mining↔protection, heavy-trade↔low-risk). More support
   also costs more (fuel/supply, speed, pirate attention, replacement loss). You can never
   bring every best type at once.
3. **The pipeline is one-directional — systems never mutate each other:**
   ```
   Activity creates a PENDING result
     → Return-home SECURES it (idempotent; lost if the expedition fails before return)
     → Inventory STORES it
     → Progression (crafting / captains / modules) CONSUMES inventory
     → Ranking READS finalized result events
   ```
   Wrong: mining crafts modules directly · exploration upgrades captains directly · combat
   fits modules directly · trading resets rankings directly.
4. **Don't replace the engine — replace the SOURCE of expedition stats.** Combat/trade/etc.
   read final stats from `calculate_expedition_stats(main ship + captains + modules + support
   craft + cargo + activity)`, which **enforces capacity + tradeoffs (never a plain sum)**.
5. **One owner per system** (extends `SYSTEM_BOUNDARIES.md`): Movement=travel/return ·
   Combat=ticks/damage · Return-home=secured deposit · Production=support craft/crafting ·
   Inventory=item balances · Main Ship=ship instance · Fitting=modules · Captain=assignment ·
   World State=location/zone state · Ranking=seasons/leaderboards · Report=history.
   Server-authoritative everywhere; frontend never mutates inventory/fitting/captains/rankings.
6. **Don't rename backend tables yet** (`fleet_id` → conceptually `expedition_id` later);
   rename only after behavior is stable and tests green. Activity types route via the existing
   Activity system: `pirate_hunt`, `trade_run`, `exploration`, `mining` (more later).

## Phased plan (incremental — M2/M3/M4/M4.5 stay green every phase; nothing built until asked)

| Phase | Scope | Notes |
|---|---|---|
| **1** ✅ | **Docs/roadmap reconciliation** | this doc + README/ARCHITECTURE; no code |
| **2** ✅ | Expedition activity architecture (design only) → **`docs/ACTIVITIES.md`** | clean activity abstraction; no giant switch |
| **3** ✅ | Generic inventory (`item_types`, `player_inventory`, `inventory_ledger`; deposit/spend/balance fns) | metal kept in base_resources; items in player_inventory |
| **4** ✅ | Pending **loot bundle** (`{ metal?, items[] }`) — `reward_grant` splits metal→base_resources, items→player_inventory | jsonb-only (no schema change); deposit-on-arrival law kept; no new drops yet |
| **5** ✅ | Multi-item pirate loot — `pirate_loot_for_wave` (deterministic, seeded items) merged into the combat bundle | combat → pending bundle; secured on return only; no crafting/UI yet |
| **6** ✅ | **support craft metadata** (`support_craft_types`: role + capacity_cost + activity tags + tradeoffs; 8 seeded) | metadata-only reframe; no instances/attachment/enforcement yet; serial queue reused conceptually |
| **7** ✅ | `main_ship_hull_types` + `main_ship_instances` (one per player; hull base stats; ensure/get/rename) | server-authoritative; sits `home`; doesn't drive expeditions yet |
| 8 | `calculate_expedition_stats()` (capacity + tradeoffs, not a sum) | old fleet-stack path = fallback |
| 9 | Expedition UI reframe (Fleet→Ship, Train Ships→Support Craft, Send Fleet→Send Expedition) | no table renames |
| 10 | Trading (buy low / travel / sell high; cargo, route danger) | activity-isolated |
| 11 | Exploration (scan/discover → data/shards/blueprints) | pending discovery rewards |
| 12 | Mining (extract → ore/crystal/cores) | pending resource rewards |
| 13 | Module instances + crafting | instances, not stack-only |
| 14 | Module fitting (`fit_module_to_ship`) | server-validated; feeds stats |
| 15 | Captain instances + assignment | effects via `calculate_expedition_stats` |
| 16 | Captain progression (consumes inventory) | inventory is the bridge |
| 17 | Ranking / competition (weekly/monthly seasons; combat/trade/explore/mine) | reads finalized events; reset by season, not deletion |
| 18 | Location investment (seasonal score vs persistent state) | no infinite exploit |
| 19 | World balance / living economy (pirate pressure, price drift, field depletion) | world-state owns world-state |
| 20 | Polish / expansion (map UI, portraits, icons, events; guilds/PvP much later, if ever) | |

**Each phase has its own acceptance criteria + verification; backend changes go through a
migration with a `verify:*` script, and the engine's M2/M3/M4/M4.5 tests must stay green.**
