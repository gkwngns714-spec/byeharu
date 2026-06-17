# Byeharu — Expedition Activity Architecture (Phase 2, design only)

> **Design doc only — no code, no migrations.** Defines how future activity types
> (`pirate_hunt`, `trade_run`, `exploration`, `mining`) plug into the existing Expedition
> Engine without a giant switch-function. Companion to `ARCHITECTURE.md`,
> `SYSTEM_BOUNDARIES.md`, and `ROADMAP.md`. Nothing here is implemented yet.

## 0. It builds on a seam that already exists

The engine already has the extension point — Phase 2 just formalizes it:

- **`location.activity_type`** and **`location_presence.activity_type`** already enumerate
  `hunt_pirates`, `mine_resource`, `explore_derelict`, `trade_visit`, `rally`, `none`.
- **`activity_start(presence, activity_type)`** (Presence system) already dispatches:
  `none` → no-op, `hunt_pirates` → `combat_create_encounter(presence)`. It is a **thin
  router**, not business logic.
- **Combat** already follows the per-activity pattern: a `*_create_encounter()` + an
  independent cron processor `process_combat_ticks()` + accrues pending reward on its own
  state (`combat_encounters.total_rewards_json`).
- **Return-home** already carries pending reward home (`movement_attach_cargo` →
  `process_fleet_movements` return branch → `reward_grant`) and deposits **only on arrival**.

So a new activity = "be like Combat": its own create fn + its own cron + its own pending
reward accrual. No existing processor is edited.

---

## 1. `ExpeditionActivityType`

The closed set of what an expedition *does* at a location (extensible later):

```
pirate_hunt   -- fight pirate waves            (today: 'hunt_pirates')
trade_run     -- buy / sell goods for profit   (today: 'trade_visit')
exploration   -- scan / discover               (today: 'explore_derelict')
mining        -- extract resources             (today: 'mine_resource')
none          -- safe zone / rally
```

(Existing enum values in parentheses; renaming is a later, optional cleanup — not Phase 2.)
A location declares its `activity_type`; the engine routes to the matching handler. **Adding
a new type is additive** (a new enum value + a new handler), never an edit to a shared
processor.

## 2. Shared Expedition Lifecycle (owned by the Engine, identical for every activity)

```
idle → moving → present → (activity runs) → leaving/retreating → returning → completed
                                                              ↘ destroyed (on failure)
```

The **Expedition Engine** (Movement + Presence + Return) owns, for ALL activities:
- **travel** (slowest-unit speed, server-computed) and **arrival**,
- **presence** creation at the location (`location_presence`),
- **activity dispatch** (`activity_start`),
- **pending-reward accrual hook** (the activity writes into the expedition's pending bundle),
- **return movement** home,
- **secured deposit on home arrival** (idempotent; lost if the expedition is destroyed first),
- **expedition status transitions** and **report creation** at the end.

The engine knows the *lifecycle*; it does NOT know any activity's internal rules.

## 3. Activity Ownership Boundaries (one owner per activity)

| Activity | Owns ONLY | Produces (pending) |
|---|---|---|
| **pirate_hunt** | combat waves · enemy destruction · retreat pressure · combat loot rolls | metal + combat items (scrap/alloy/parts/fragments/blueprints) |
| **trade_run** | market prices · buy/sell · cargo goods · investment · profit | profit (metal) + delivered-goods outcomes |
| **exploration** | scanning · discovery rolls · anomalies · hidden sites | data / shards / blueprint fragments / artifact cores |
| **mining** | extraction ticks · resource fields · mining danger | ore / crystal / rare minerals / cores |

Each owns **only its own state table(s) and processor**. None reads or writes another
activity's tables. None writes inventory, fitting, captains, world-state, or rankings.

## 4. Activity Handler contract (the "interface", Postgres-functions style)

There is no class polymorphism in SQL; instead every activity implements the **same named
contract**, and the engine calls only the contract:

```
<activity>_create(presence)            -- start the activity (e.g. combat_create_encounter)
process_<activity>_ticks()             -- independent cron processor (e.g. process_combat_ticks)
<activity>_request_leave(presence)     -- optional: how the player ends it early (retreat/leave)
                                          [the processor accrues pending rewards onto its state,
                                           and on end calls Engine.finish(presence, bundle)]
```

- **Dispatch** = `activity_start(presence, type)` maps `type → <activity>_create`. One branch
  per activity, each a single call — a registry, not logic.
- **Scheduling** = one cron job per activity at its own cadence (combat 2s, mining/trade/
  explore at their own rates). Each processor selects only its own due rows
  (`FOR UPDATE SKIP LOCKED`, idempotent). **There is no shared `process_all_activities()`.**
- **Finish** = when an activity ends, it hands the Engine a `PendingRewardBundle` and asks the
  Engine to create the return movement + carry the bundle (today: `movement_attach_cargo`).

Frontend mirror: a shared expedition-status view + **one panel per activity type** (combat
panel exists; trade/explore/mining panels added in their phases). The dashboard picks the
panel by `activity_type` — again a registry, not a mega-component.

## 5. `PendingRewardBundle` concept

Generalizes today's `total_rewards_json = { metal: N }` into a future-proof bundle:

```ts
type PendingRewardBundle = {
  metal?: number
  items: { item_id: string; quantity: number }[]
}
```

Rules (unchanged reward law): the bundle is **pending** while the expedition is out,
**secured only on home arrival** (deposited idempotently into Inventory — Phase 3/4), and
**forfeited** if the expedition is destroyed before returning. Every activity writes ONLY into
its expedition's pending bundle; it never deposits to inventory directly. (Phase 2 defines the
shape; Phases 4–5 wire items through.)

**Phase 5 — `pirate_hunt` loot is live.** On each cleared wave, `process_combat_ticks`
accrues item drops next to metal via the server-only, deterministic helper
`pirate_loot_for_wave(wave, danger)` (merged into `total_rewards_json.items` with
`loot_merge_items`). Conservative v1 loot table (small, clamped, seeded items only): scrap
(every wave) · pirate_alloy (wave ≥3) · weapon_parts (≥5) · engine_parts (≥8) · repair_parts
(≥10). Loot is computed **server-side only** — the frontend never rolls or awards loot.
captain_memory_shard / blueprint_fragment / artifact_core stay reserved for later rare/
progression drops. Other activities (trade/explore/mine) will add their own loot sources the
same way — by writing into the pending bundle, never by touching Inventory directly.

## 6. Report / result shape concept

The expedition produces a **history-only** report on completion (never a source of truth for
live state — same law as `combat_reports`):

```
expedition report:
  activity_type · location · outcome (escaped/defeat/completed/...) · duration
  secured PendingRewardBundle (what was actually banked)
  activity_summary  -- per-activity: waves_cleared | profit | discoveries | resources_mined
```

`combat_reports` is the existing instance for `pirate_hunt`; later activities either extend it
or a generic `expedition_reports` table carries `activity_type` + an `activity_summary_json`.
(Design choice deferred to Phase 6+; not decided here.)

## 7. Adding a future activity WITHOUT a giant switch

To add (e.g.) `mining`:
1. add the enum value (`mine_resource` already exists),
2. add its state table(s) + `mining_create` + `process_mining_ticks` cron + (optional)
   `mining_request_leave`,
3. add **one branch** to `activity_start` (`mine_resource → mining_create`),
4. add a `MiningPanel` keyed by `activity_type` on the frontend.

No existing activity, the engine, inventory, or reports change. The dispatch grows by one
line; nothing becomes a monolith.

## 8. Anti-spaghetti call-graph rules (extends `SYSTEM_BOUNDARIES.md`)

**Allowed edges:**
```
Engine(Movement/Presence) → activity_start → <activity>_create
process_<activity>_ticks (cron) → writes its own state + pending bundle → on end:
    Engine.finish → Movement.create(return) + carry bundle
Return-home arrival → Inventory.deposit (Phase 3) / reward_grant (today) → Report.create
Ranking (Phase 17) → READS finalized report/result events
```

**Forbidden (the law):** activities never mutate each other; an activity never writes
inventory / fitting / captains / world-state / rankings directly; combat never fits modules;
mining never crafts; exploration never upgrades captains; trading never resets rankings.
Always: **activity → pending → secure-on-return → inventory → progression → ranking.**

## 9. What Phase 2 does NOT implement

No code, no migrations, no `src/` changes. **Not** building: trade_run / exploration / mining
processors, inventory, the item-based loot bundle, main ship, captains, modules, support
craft, ranking, or any schema. Pure architecture.

## 10. Phase 2 acceptance criteria

- [x] Docs explain how `pirate_hunt` / `trade_run` / `exploration` / `mining` share the one
  Expedition Engine (lifecycle, dispatch, return, deposit, reports).
- [x] Each activity has a single clear owner; engine owns the lifecycle only.
- [x] No giant mixed activity processor — one processor + one cron per activity; dispatch is a
  thin registry.
- [x] No gameplay code changed; no migrations; `src/` untouched.
- [x] M2/M3/M4/M4.5 remain green because nothing executable changed.
