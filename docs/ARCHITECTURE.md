# Byeharu — Foundation Architecture

> Source of truth for the game foundation. Read this before building any milestone.
> Byeharu is a **server-authoritative PvE space-strategy game** (no PvP for now).

---

## 1. Core principle

```
Map  →  Location  →  Movement  →  Presence  →  Activity  →  Result
```

- **Map** — where things *can* happen.
- **Movement** — getting a fleet there (server owns travel + arrival time).
- **Presence** — the fleet *is* there and exposed to the location's rules.
- **Activity** — what happens while present (combat is just one activity).
- **Result** — losses, rewards, return home, report.

The **client only displays what the server says**. The server owns: fleet
location, arrival time, unit quantities, combat results, rewards, retreat timing,
and death/survival. The client may animate, but the server decides the truth.

**Do not** build free-moving ships that chase/fight from live positions — that path
is bug-prone. Use discrete states: choose destination → validate → travel → arrive
→ present → activity → resolve.

**Most important rule:** build the game around **location presence**, not directly
around combat. Movement decides arrival; presence decides exposure; activity decides
what happens; combat is only one activity; reports show the result.

---

## 2. MVP economy decision (locked)

**Combat-reward economy only.** For this foundation:

- Player gets a **starter base** and **seeded starter units** (no training yet).
- Player sends fleets to pirate locations.
- Pirate combat grants **resources as rewards**, added to `base_resources` when the
  encounter ends.

**Deferred to a later phase** (do NOT build now): buildings, build queues, passive
production, lazy resource accrual, unit training, research, market/trade, cargo.

> `base_resources` exists only because rewards need somewhere to land. A resources
> *table* is not an economy *system*. We are not building production yet.

---

## 3. World hierarchy

```
Galaxy → Sector → Zone → Location
```

| Layer | Meaning |
|---|---|
| Galaxy | Whole game world (single galaxy for now; `galaxies` table deferred) |
| Sector | Large region (~12 sectors) |
| Zone | Playable area inside a sector (broad danger/reward level) |
| Location | Exact destination where an activity happens |

A player does not "enter a sector." A player **sends a fleet to a specific location
inside a zone**. One zone contains multiple locations with different danger, missions,
rewards, and unlocks — keep zone (area) and location (activity point) **separate**.

MVP location types: `pirate_hunt`, `safe_zone`. MVP activity types: `hunt_pirates`,
`none`.

---

## 4. System separation (do not couple these)

| System | Responsibility |
|---|---|
| Map | defines sectors/zones/locations; shows where players can go |
| Movement | sends fleets between places, computes travel time, resolves arrival — **never** computes combat |
| Presence | tracks fleets staying at locations; bridges movement → activity; knows who is exposed |
| Activity | decides what happens at a location (hunt / mine / explore — only `hunt`/`none` for MVP) |
| Combat | resolves pirate waves, applies losses, logs rounds — one *kind* of activity |
| Reward | computes rewards, grants resources/cargo |
| Report | player-facing history (UI only, never logic) |

Never mix combat / movement / map / resource logic in one file.

---

## 5. Movement system

- A trip is one `fleet_movements` row. **Do not** store/update live `fleet_x/y` every
  second. Store `origin_x/y`, `target_x/y`, `depart_at`, `arrive_at`.
- Visual position is interpolated **client-side** for animation:
  `progress = (now - depart_at) / (arrive_at - depart_at)`.
- The server only needs to know **not arrived** vs **arrived**.

**Travel time (server-computed, never trust client):**
```
distance      = sqrt((tx-ox)^2 + (ty-oy)^2)
fleet_speed   = slowest unit speed in the fleet
travel_seconds= distance / fleet_speed * travel_scale
```
Slowest-unit-speed creates the "fast & weak vs slow & strong" strategic choice.

**Arrival** is resolved by `process_fleet_movements()` (cron): lock the row, verify
unresolved, mark arrived, update fleet location, create `location_presence`, start the
correct activity. Movement never resolves combat directly.

---

## 6. Presence system (the bridge)

`location_presence` = "this fleet is currently at this location and exposed to its
rules." It is the bridge between movement and activity.

```
movement arrives → create presence → presence starts activity → activity processor runs
```

Statuses: `active → retreating → completed`; also `active → destroyed/expired`.

---

## 7. Activity system

`location_presence.activity_type` selects a processor. Same movement/presence
foundation supports many activities without rewriting movement:

- MVP: `process_combat_ticks()` (for `hunt_pirates`), `none` (safe zones).
- As-built (Phase 11): exploration shipped **OSN-native**, outside this presence dispatch — its own
  `process_exploration_securing()` cron secures pending discoveries (dark behind
  `exploration_enabled='false'`; see `docs/ACTIVITIES.md` §2 as-built clarification). The
  `explore_derelict` presence branch stays deliberately unwired.
- Later: `process_mining_ticks()`, `process_trade_ticks()`, and a presence-domain
  `process_exploration_ticks()` if exploration ever gets a location-presence form.

---

## 8. Pirate combat activity

Combat is one activity. Player stays as long as they dare; the result is usually
`escaped` / `defeat` / `completed` (not a classic "victory").

**Wave scaling** (rising tension — "can I survive one more wave?"):
```
danger_level = 1 + waves_cleared + floor(minutes_inside / 3)
enemy_power  = location.base_difficulty * (1 + danger_level * 0.3) * random(0.9..1.1)
```

**Simple power combat** (start simple, debuggable):
```
player_attack/defense/hull = sum(unit.stat * quantity)
damage_to_enemy  = player_attack  * random(0.9..1.1)
damage_to_player = enemy_attack   * random(0.9..1.1)
final_to_player  = damage_to_player * 100 / (100 + player_defense)
final_to_enemy   = damage_to_enemy  * 100 / (100 + enemy_defense)
player_loss_ratio= final_to_player / player_hull   → apply proportionally to each unit type
```
Deferred: target priority, ship classes, damage types, formations, captain skills,
crits, armor types.

`process_combat_ticks()` (cron): find active encounters → lock → check
`last_resolved_at` → load units → handle empty-fleet/defeat → handle retreat-timer →
spawn wave → compute damage → apply losses → reward if wave cleared → bump danger →
insert `combat_round` → update encounter → on end, create `combat_report`.

---

## 9. Retreat & return flow

- `request_leave_location(presence_id)` → presence `retreating`, encounter
  `retreating`. **Retreat is not instant** — `retreat_delay_seconds` (≈30s) during
  which combat continues and the fleet can still die. Tension by design.
- After the delay: combat ends, presence closes, **return movement** is created
  (`origin_type=location`, `target_type=base`, `mission_type=return_home`), fleet
  `returning`. **Never teleport home** — returning is also movement.
- On return arrival: merge surviving `fleet_units` back into `base_units`, fleet →
  `completed` (MVP uses temporary fleets — Option A), clear active movement.

---

## 10. Anti-cheat / server authority

The client **never** writes important game state. No direct client writes to:
`base_units`, `fleets`, `fleet_units`, `fleet_movements`, `location_presence`,
`combat_encounters`, `combat_rounds`, `combat_reports`, `zone_state`,
`location_state`, `base_resources`, rewards.

The client only calls RPCs. The server validates and decides results. Frontend
formulas are **previews only**; server formulas are authority.

**Every player RPC validates:** ownership (`auth.uid()`), unit availability &
positivity, location validity/active/unlocked, mission allowed there, fleet limit,
not-already-assigned, timing (movement really arrived / retreat delay done / tick
due), and legal state-machine transitions. Reject impossible transitions.

---

## 11. RLS / RPC rules

| Table group | Read | Write |
|---|---|---|
| `sectors`, `zones`, `locations` | everyone | server/admin only |
| `zone_state`, `location_state` | everyone (or limited) | server only |
| `base_units`, `base_resources`, `fleets`, `fleet_units`, `fleet_movements`, `location_presence`, `combat_*` | owner only | server RPC only (`SECURITY DEFINER`) |

Public map data is world-readable; all private fleet/movement/presence/combat/report
data is owner-only.

---

## 12. State machines (enforced in RPCs)

- **Fleet:** `idle → moving → present → returning → completed`; also `moving/present
  → destroyed`. Invalid: `idle→present`, `moving→combat`, `destroyed→returning`,
  `returning→present`, `present→idle` instantly.
- **Movement:** `moving → arrived` (later `moving → cancelled`). No reverse.
- **Presence:** `active → retreating → completed`; also `active → destroyed/expired`.
  No reverse.
- **Combat:** `active → retreating → escaped`; also `active → defeat/completed`.
  No reverse.

---

## 13. Constraints, locking, idempotency

- **DB constraints**, not just app logic: `quantity >= 0`, `travel_seconds > 0`,
  `arrive_at > depart_at`, `danger_level >= 1`, `waves_cleared >= 0`; enums/CHECKs
  for statuses.
- **Uniqueness (partial unique indexes):** one active movement per fleet; one active
  presence per fleet; one active encounter per presence; one active encounter per
  fleet. (A fleet can't be in two places / two fights at once.)
- **Row locking:** all processors use `FOR UPDATE SKIP LOCKED` (cron jobs can
  overlap → would otherwise double-arrive / double-reward / double-damage / dup
  reports / dup return).
- **Idempotency:** every processor safe to run twice. Guard with `resolved_at`,
  `ended_at`, `report_created_at`, `reward_granted_at`, `return_movement_id`.

---

## 14. Processors & cron timing

| Processor | Cadence | Notes |
|---|---|---|
| `process_fleet_movements()` | every 30s | resolves arrivals (outbound + return) |
| `process_combat_ticks()` | every 10–15s | one round per due encounter |
| `process_location_state_ticks()` | every 60s | pirate pressure / danger drift |
| `process_exploration_securing()` | every 60s | deposits pending exploration discovery bundles via `reward_grant('exploration', discovery_id, …)` once the carrying main ship settles safe (home / `at_location`); deliberately ignores `exploration_enabled` (in-flight safety) — pg_cron job `process-exploration-securing`, migration 0100 |
| `process_mining_securing()` | every 60s | deposits pending mining extraction bundles via `reward_grant('mining', extraction_id, …)` once the carrying main ship settles safe (home / `at_location`); deliberately ignores `mining_enabled` (in-flight safety) — pg_cron job `process-mining-securing`, migration 0105 |

Supabase Cron (pg_cron) supports **seconds-granularity** schedules on Postgres
`15.1.1.61`+ — so sub-minute cadence is native. Only server/cron calls processors.

---

## 15. MVP tables

**Static world:** `sectors`, `zones`, `locations`
**Dynamic world:** `zone_state`, `location_state`
**Player:** `profiles` (done), `bases`, `base_resources`, `unit_types`, `base_units`
**Fleets:** `fleets`, `fleet_units`, `fleet_movements`
**Presence:** `location_presence`
**Combat:** `combat_encounters`, `combat_rounds`, `combat_reports`
**Config:** `game_config`

### Gap resolutions added beyond the original spec
| Addition | Why | Shape |
|---|---|---|
| `base_resources` | rewards need somewhere to land | `base_id, resource_code, amount` |
| `initialize_new_player()` | no training in MVP → must seed | creates starter base + seeds `base_units` + `base_resources` |
| `game_config` | tunable balance without redeploy | key/value: `travel_scale`, `max_active_fleets`, `combat_tick_seconds`, `retreat_delay_seconds`, reward multipliers, random-variance bounds |

---

## 16. Milestone roadmap

> **Direction update (2026-06-17).** Byeharu is now a **main-ship expedition game** — see
> **`docs/ROADMAP.md`** for the forward plan (Main Ship + Captains + Modules + Support Craft
> → Expedition → Activity → Return → Inventory → Progression → Ranking). The milestones
> below are **reclassified, not rewritten**: **M2–M4 = the Expedition Engine** (reused by all
> future activities) and **M4.5 = the Serial Build Queue Foundation** (becomes support-craft /
> equipment production). The old "combat-reward-only economy" framing is superseded by the
> generic inventory + pending-loot-bundle model in ROADMAP Phases 3–5. **Standing law:** don't
> replace the engine — replace the *source* of expedition stats via
> `calculate_expedition_stats()` (capacity + tradeoffs, never a plain sum).
>
> **Phase 6 (2026-06-18).** `support_craft_types` seeds the **capacity-limited support craft**
> definitions (metadata only — Reference/Config, public read, no client write). They are NOT
> yet attached to expeditions and `support_capacity` is NOT yet enforced (no main ship yet);
> current combat is untouched and still uses `unit_types`. The serial build queue (M4.5) is
> the conceptual home for building them later. Capacity + tradeoffs will be enforced by
> `calculate_expedition_stats()` once Phases 7–8 land — never a plain additive sum.
>
> **Phase 7 (2026-06-18).** The **main ship** now exists: `main_ship_hull_types` (Reference/
> Config, one starter hull exposing `support_capacity` 10) + `main_ship_instances` (one per
> player, owner-read, created/renamed only via server-only `ensure_main_ship_for_player` /
> `get_main_ship` / `rename_main_ship`). It is the player identity (not stackable) but **does
> not drive expeditions yet** — it sits `home`, and combat/fleet/movement/production are
> unchanged. Phase 8's `calculate_expedition_stats()` will be the adapter that finally reads
> the ship (+ support craft, later captains/modules) into final expedition stats.
>
> **Phase 8 (2026-06-18).** `calculate_expedition_stats(player, main_ship_id, loadout,
> activity)` now exists — the **deterministic, read/compute stat adapter**. It reads the main
> ship + hull + `support_craft_types`, validates a support loadout (type/qty/positive-integer),
> **enforces `support_capacity` as a hard cap** (over-capacity → rejected; this is the
> anti-unlimited-stacking mechanism, not a plain sum), and returns normalized stats
> (`combat_power`, `survival`, `retreat_safety`, `scouting`, `mining_yield`, `repair`,
> `cargo_capacity`, `speed`, `pirate_attention`, `support_capacity_used/limit`, `warnings`).
> Effects derive from each craft's `base_stats_json` + role-based attention/speed rules.
> It **mutates nothing** and is **not wired into live combat** — the proven fleet-stack path
> still owns outcomes. Captains/modules will plug into this same function later; Phase 9/10+
> integrate it gradually (likely a shadow-read first).

| Milestone | Scope | Outcome |
|---|---|---|
| **M1** ✅ | Scaffold + auth + `profiles` | done |
| **M2** | World map tables + state + seed + `get_world_map()` + read-only map screen | see the galaxy |
| **M3** | `bases`/`base_resources`/`unit_types`/`base_units` + `initialize_new_player()` + `game_config`; `fleets`/`fleet_units`/`fleet_movements`; `location_presence` (activity `none`); `send_fleet_to_location()`, `process_fleet_movements()`, return; RLS | send fleet → travel → present at `safe_zone` → return → units merge back (**no combat**) |
| **M4** | `combat_encounters`/`combat_rounds`/`combat_reports`; `process_combat_ticks()`; wave scaling; `request_leave_location()` + retreat; reports | full pirate-hunt loop |
| **M5** | `process_location_state_ticks()` + zone/location dynamics; wire all cron jobs; balance | living world, unattended ticks |
| **M6** | Frontend depth: location panel, send-fleet panel + preview math, fleet status, active-combat panel, round log, report page | polished playable loop |
| **M7** | **Training / ship production** (Production system): `unit_types.metal_cost`; `build_orders` + `train_units()` + `process_build_queue()`; spend metal via `base_spend_resources`, deposit via `base_merge_units`; Train Ships + Training Queue UI *(client UI retired 2026-07-05 in the UX cleanup pass — server RPCs/cron remain)* | spend metal → train ships → stronger fleet |

### Migration order (timestamp-prefixed, one system per file)
`…0001_init_profiles` (done) → `world_map` → `bases` → `units` → `config` →
`fleets` → `movement` → `presence` → `combat` → `rls` → `rpc_player_actions` →
`rpc_processors` → `cron_jobs`.

---

## 17. Deferred — do NOT build yet

captains & skills · research · trade/market · cargo · alliances · PvP · moving NPC
pirates · manual targeting · projectile combat · formations · equipment · boss
mechanics · mining · derelict exploration · scouting/fog-of-war · buildings · build
queues · passive production · lazy resource accrual · unit training · multi-galaxy.

Create clean **extension points** only. First version must prove the one loop:
`map → location → movement → presence → combat → retreat → return → report`.
