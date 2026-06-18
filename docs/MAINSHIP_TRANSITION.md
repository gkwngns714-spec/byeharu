# Byeharu — Main Ship Transition Plan (Phase 10)

> **Status: Phase 10A design (audit) + 10B done/accepted (read-only preview).** Authoritative
> plan for moving from the current metal-built **disposable-ship** fleet loop to a persistent
> **Main Ship(s) + Captains + Modules + Support Craft** model — **without breaking or deleting
> the verified system**. Companion to `ARCHITECTURE.md` (engine), `SYSTEM_BOUNDARIES.md`
> (ownership), `ROADMAP.md` (forward plan), `ACTIVITIES.md` (activity abstraction). Recorded
> 2026-06-18; **clarified-vision update 2026-06-18** (see "★ Clarified core vision" below).
>
> **Standing law (unchanged):** *replace the SOURCE of expedition stats, never the engine.*
> The M2–M5 engine (travel · combat · retreat · return · reward-on-arrival · reports) stays.
>
> **Core vision (clarified):** the future model is **multiple persistent main ships with
> flexible, stat-driven assignment** — not "one ship" and not "one ship locked to one role."
> See the ★ section next.

---

## ★ Clarified core vision (2026-06-18) — multiple persistent main ships, flexible assignment

The future byeharu model is **multiple persistent main ships with flexible, stat-driven
assignment.** It is explicitly **NOT** "one main ship only" and **NOT** "one ship locked to one
role."

> **⚠️ Support capacity / support craft is DEPRECATED — not part of the core design (correction
> 2026-06-18).** The desired core is **multiple persistent main ships + captains + modules +
> upgrades** (and a ship's own hull/hp/cargo/slots stats). There is **no support-craft loadout**
> and **no support-capacity budget** in the player-facing game. The existing
> `support_craft_types` table, the `support_capacity` columns, and the support logic inside
> `calculate_expedition_stats` are **dormant scaffolding** — left in place for now (no sudden
> deletes) and **hidden from the UI**. They will be removed later, safely, only once no code
> path depends on them (see "Removing support — later" below). Treat every "support craft" /
> "support capacity" mention elsewhere in this doc as dormant/deprecated.

**What the player eventually controls:**
- **Several** persistent main ships, each a strategic asset with its own captains / modules /
  upgrades and hull stats (hp / cargo / captain & module slots / speed). *(No support capacity.)*
- **Free assignment** of any ship to any activity — combat, trading, mining, exploration, and
  future activities.

**Player freedom (must be preserved):**
- Send **all** main ships to combat if they want.
- Send **all** main ships to trade if they want.
- **Split** ships across multiple tasks simultaneously (strategic multitasking).
- Some content should **require or reward multiple main ships in the same area/group** —
  especially larger combat encounters; trading/mining/exploration may also benefit from multiple
  ships on the same task if the player chooses.

**No hardcoded ship classes / activity locks.** Do NOT build "combat ship can only fight",
"trade ship can only trade", "mining ship can only mine". Instead: **any ship can attempt any
activity; captains / modules / upgrades / loadout / stats determine how effective or risky it
is.** Role is *emergent from fit*, not a permanent type lock.

**Architectural implications (bake in now, even though we start with one ship):**
1. **"One main ship per player" is STARTER-PHASE behavior, not permanent architecture.** It is
   fine for Phase 10C to send/own exactly one ship for safety — but nothing in the wording, API,
   or schema may *assume one forever*.
2. **Avoid one-ship wording** in code/UI/docs ("your main ship", "the ship") where it implies a
   permanent cap. Prefer "a main ship" / "your main ships" framing as we go.
3. **Avoid API/schema that blocks multiple ships later.** Concretely:
   - `main_ship_instances.player_id` is currently **UNIQUE** (one row per player). This is the
     *starter constraint*; multi-ship will later **drop the UNIQUE** (an additive migration) so a
     player can own many `main_ship_instances`. **Do not relax it now**, but design every new
     function/RPC to **take an explicit `main_ship_id`** (not "the player's only ship"), so
     relaxing the constraint later requires no rewrites.
   - Send/preview/stats functions must be **ship-id-parameterized** (`calculate_expedition_stats`
     already takes `main_ship_id` ✓; the 10B preview wrapper currently derives the single ship —
     it will gain a `main_ship_id` arg when multi-ship lands).
4. **The send model is a "main-ship expedition GROUP."** Phase 10C may dispatch **one** ship for
   safety, but the RPC contract should be shaped so a *group* of ships (a list of `main_ship_id`)
   can be sent to one destination later **without a redesign** — e.g. accept a `p_ships jsonb`
   list even if 10C validates "exactly one".
5. **Combat eventually allows multiple main ships in the same area/group** (co-located
   expeditions stack into one larger encounter, or fight side-by-side). The engine already
   represents an expedition as `fleets`/`fleet_units`; a multi-ship group resolves into the same
   combat input — **no second combat system.**
6. **Trading / mining / exploration** likewise support multiple ships on the same activity if the
   player chooses.
7. **Activity rules stay stat-driven, never hardcoded per ship type** — the primary
   anti-spaghetti rule for the whole transition.

---

## 1. Why the current loop can softlock

The current core loop is **metal → build ships → send → maybe lose ships**:

- New players start with **125 ships** (scout 100 / corvette 20 / frigate 5) and **metal 0**
  (`initialize_new_player`, base_system 0005).
- **Metal is earned ONLY from won expeditions** — `reward_grant` → `base_add_resources`,
  deposited only on home arrival.
- **Training costs metal**, spent up front: scout 50 / corvette 150 / frigate 400
  (`unit_types.metal_cost`, `train_units` → `base_spend_resources`; rejects if insufficient).
- **Combat defeat permanently destroys the fleet** — `process_combat_ticks` on death calls
  `fleet_destroy(fleet_id)`; those ships are gone.
- **`initialize_new_player` is idempotent** — it returns early if a base exists, so it **never
  re-seeds**. There is **no free metal drip, no daily ship grant, no recovery path**.

### Exact softlock condition (no possible recovery)
A player is permanently locked when **all** of these are true:
1. `sum(base_units.quantity) = 0` (no ships at home), **and**
2. `base_resources.metal < 50` (cheapest trainable ship — can't train even one scout), **and**
3. no `fleets` with status in (`moving`, `present`, `returning`) (nothing out that could
   return with ships/rewards), **and**
4. no `build_orders` with status in (`waiting`, `active`) (no production in progress).

With (1)+(2) you can neither **send** (`send_fleet_to_location` requires non-empty units +
`fleet_power >= min_power_required`) nor **train**. With (3)+(4) nothing will ever change it.
→ **permanent softlock by design of the disposable-ship economy.**

**The fix direction:** a *persistent* main ship that can be **damaged but never destroyed**,
with **free slow self-repair to a minimum readiness** — so "0 ships" and "no metal" can never
fully lock the player out.

---

## 2. Current dependency map (what the disposable loop touches)

### Backend tables
| Table | Role | Coupling |
|---|---|---|
| `unit_types` | catalog: stats + `metal_cost` + `build_time` | Reference/Config; read by combat, production, fleet stats |
| `base_units` | ships at home | `base_reserve_units` (send) / `base_merge_units` (return, train) |
| `base_resources` | metal/crystal/energy | `base_spend_resources` (train) / `base_add_resources` (reward) |
| `build_orders` | serial training queue (M4.5) | `train_units`, `process_build_queue`, `cancel_build_order` |
| `fleets` / `fleet_units` | a dispatched group + composition | `fleet_create`, `fleet_sync_quantities`, **`fleet_destroy`** |
| `fleet_movements` | travel geometry (origin/target x/y, ETA) | `movement_create`, `process_fleet_movements` |
| `combat_encounters` / `combat_ticks` / `combat_events` | live combat + logs | `process_combat_ticks` |
| `combat_reports` | history | `report_create` |
| `reward_grants` | secured-deposit ledger | `reward_grant` |

### Backend functions (the engine — KEEP)
`send_fleet_to_location` (RPC) · `process_fleet_movements` (cron) · `process_combat_ticks`
(cron) · `request_retreat` / `request_leave_location` · `reward_grant` → `base_add_resources` /
`inventory_deposit` · `report_create` · `train_units` / `process_build_queue` /
`cancel_build_order`.

**The softlock coupling:** on death, `process_combat_ticks` calls **`fleet_destroy(fleet_id)`**
(permanent loss). This is the single behavior the new model must change for main-ship
expeditions (defeat → damaged/forced-retreat, not destroyed).

### Frontend touchpoints (unit selection / fleet send)
- `src/features/map/ExpeditionCommand.tsx` — **the only send surface** (`sendFleetToLocation`,
  unit picker).
- `src/features/map/useGalaxyMapData.ts` — loads `base_units` + `unit_types` (picker) +
  active movements (map).
- `src/features/dashboard/useGameState.ts` — polls base/units/resources/fleets/movements/
  build orders.
- `src/features/base/BasePanel.tsx` + `baseApi.ts` — units/resources display.
- `src/features/production/{TrainShipsPanel,productionApi,productionTypes}` — training queue.
- `src/features/fleets/{fleetApi,FleetStatusPanel}` — fleet status display.

### Tests pinning old unit/fleet behavior (must stay green)
`verify-m2/m3/m4/m45/m5` (send · combat · return · rewards), `tests/m45.spec.ts` (training
queue), `tests/galaxy9b.spec.ts` (unit-loadout send).

---

## 3. Existing main-ship foundation (already built, inert)

- **`main_ship_hull_types`** (Phase 7, Reference/Config, public read):
  `base_hp, base_speed, base_cargo_capacity, base_support_capacity, base_captain_slots,
  base_module_slots`. Seeded `starter_frigate` (hp 500, **support_capacity 10**, captain 2,
  module 3).
- **`main_ship_instances`** (Phase 7, owner-read, server-write only): one per player today via
  `player_id` **UNIQUE** — **starter-phase constraint only** (multi-ship later drops the UNIQUE,
  additive; see ★ vision). `hp/max_hp, cargo_used/cargo_capacity, support_capacity, captain_slots,
  module_slots`; **status enum already covers the full lifecycle**:
  `home, traveling, hunting, trading, exploring, mining, retreating, returning, repairing,
  destroyed`. Functions: `ensure_main_ship_for_player`, `get_main_ship`, `rename_main_ship`
  (all server-only today).
- **`calculate_expedition_stats(player, main_ship_id, support_loadout jsonb, activity_type)`**
  (Phase 8): deterministic, read/compute only; reads hull + `support_craft_types`; **enforces
  `support_capacity` as a hard cap**; returns `{combat_power, survival, retreat_safety,
  scouting, mining_yield, repair, cargo_capacity, speed, pirate_attention,
  support_capacity_used/limit, warnings}`. **service_role only today; consumed by nothing.**
- **`support_craft_types`** (Phase 6, metadata only): 8 capacity-limited craft (role,
  `capacity_cost`, activity tags, tradeoffs). No instances/ownership yet.

**The data model, the capacity law, and the stat adapter already exist — they just aren't
wired to combat or the client. This is the clean seam.**

---

## 4. Reuse plan (keep the engine, swap the source)

**Reuse as-is (no change):**
- `fleet_movements` — already stores origin/target x/y + ETA. A "main-ship expedition" is just
  **one `fleets` row** whose `fleet_units` are the *resolved* combat units derived from the
  ship + loadout.
- `combat_encounters` / `combat_ticks` / `combat_events` / `combat_reports` — unchanged.
- `reward_grants` / `reward_grant` / pending-bundle / return-on-arrival — unchanged (reward
  timing law stays).
- `process_fleet_movements` / `process_combat_ticks` cron spine — unchanged in structure.

**Reuse temporarily (bridge):**
- **Support craft ride `unit_types` + `fleet_units` initially.** A main-ship expedition
  *resolves* its loadout into `fleet_units`-shaped rows (each craft → synthetic unit with
  attack/defense/hp). Combat then runs exactly as today — **no second combat system.**
  `calculate_expedition_stats` becomes the thing that *produces* those resolved stats,
  replacing the raw `base_units` sum; the old fleet-stack path remains a fallback.

**Eventually deprecated (NOT now, NOT deleted):**
- `train_units` / `build_orders` as the *primary ship source* → later **support-craft / module
  / repair-kit production** (same serial queue).
- `base_units` as disposable combat bodies → later a *reserve/inventory of support craft*.
- `send_fleet_to_location`'s "pick raw units" input → later "send main ship + loadout" (keep
  the RPC; add a sibling, don't rewrite).

---

## 5. Proposed future expedition model

```
/galaxy: pick destination + an ACTIVITY (combat / trade / mine / explore)
  → SOURCE = one or more main_ship_instances (a "main-ship expedition GROUP") — not base_units
            (Phase 10C dispatches ONE ship for safety; the contract supports a group later)
  → each ship's effectiveness = its own hull stats + captains + modules + upgrades  (NO support craft)
  → a stat source per ship → final stats (captain/module/upgrade-driven, never a plain sum)
    [today's calculate_expedition_stats only computes the now-dormant support layer; the real
     captain/module/upgrade stat source replaces it later — support is not exposed]
  → travel (fleet_movements) → combat / scan / extract (existing engine, fed by computed stats)
  → DEFEAT = forced retreat + main ship(s) DAMAGED (never destroyed); loadout consequences
  → return home → rewards secured (unchanged) → repair over time
```

Any ship can attempt any activity; **effectiveness/risk come from captains/modules/loadout/
stats, never from a hardcoded ship class** (★ vision). Co-located ships on the same activity may
group into one larger encounter/effort.

Shifts from today:
- **Source:** one or more `main_ship_instance`(s) instead of `base_units` quantities.
- **Power:** from `calculate_expedition_stats` (enforces `support_capacity`), not
  `fleet_get_power(sum of units)`.
- **Defeat:** no `fleet_destroy` of the main ship — set the ship `repairing` with reduced
  `hp`, force a return, and apply *loadout* consequences (support craft consumed, cargo
  dropped, a module damaged, or a captain injured). The **main ship instance always survives.**
- **Rewards:** still pending → secured only on home arrival (no change).

---

## 6. Anti-softlock design (the persistent main ship IS the fix)

- The player **always has at least one persistent main ship** (never deleted/destroyed) → "0
  ships" is impossible; they can always launch *something*. (With multi-ship, losing a risky
  expedition still leaves the player's other main ships — and even the damaged ones survive.)
- **Defeat → damaged, not destroyed** (per ship in the group).
- **Free, slow self-repair to a minimum readiness:** a `repairing` ship auto-regenerates `hp`
  to an **expedition-ready floor** over time with **no metal/resource gate**. Metal / repair
  kits only *speed up* or *fully* repair — an optimization, never a gate. This removes the
  "no metal → stuck" branch.
- **Minimum emergency readiness:** even with zero support craft, zero metal, and a freshly
  damaged ship, a bare main-ship expedition can be sent to a low-difficulty target to earn the
  first reward. **Recovery is always possible by playing**, not by a handout.

**Avoiding free-resource abuse:**
- No free *resources* are granted — only the ship's own rate-limited hp regen to a floor.
  Nothing to farm: `support_capacity` caps loadout regardless, support craft must still be
  produced/owned, and repair regen is timer-rate-limited so spamming defeats yields nothing.
- **This supersedes the earlier "emergency recovery kit" idea** — a persistent self-repairing
  main ship makes a separate recovery-grant RPC largely unnecessary. (Recovery kit stays
  *unimplemented* per instruction.)

---

## 7. Safe phased transition (additive; old path stays green every phase)

| Phase | Scope | Touches | Old path |
|---|---|---|---|
| **10A** ◀ *(this doc)* | Audit + this design doc | docs only | untouched |
| **10B** | **Read-only** main-ship stats preview: client-scoped wrapper over `calculate_expedition_stats` (auth.uid → own ship) + a read-only `/galaxy` preview panel | 1 small migration (read-only RPC) + 1 read-only component + verify | untouched |
| **10C** | New **`send_main_ship_expedition(...)`** RPC (sibling of `send_fleet_to_location`), behind a flag — **group-shaped contract** (accept a `p_ships` list) but **validate exactly one ship for safety**; resolves ship+loadout → `fleets`/`fleet_units` → existing movement/combat. No client UI yet; new `verify:mainship` | 1 migration + verify | both coexist |
| **10D** | `/galaxy` `ExpeditionCommand` switches its send to the main-ship RPC (unit picker → **main-ship + captains/modules** loadout — NOT support craft). Old path still callable | frontend only | still callable |
| **10E** | Combat **defeat → damaged / forced-retreat** for main-ship expeditions (never destroyed) + **free slow repair** timer | combat function change (carefully, with regression) | disposable-fleet defeat unchanged |
| **10F** | Deprecate the old metal-built *send* path **only after** all tests green; **tables/functions stay (no deletes)** for a release, then revisit | flag flip + docs | retired, not deleted |
| **10G+** *(multi-ship, later)* | **Relax to multiple main ships:** drop `main_ship_instances.player_id` UNIQUE (additive); ship management UI (own/commission/assign several); enable **multi-ship expedition groups** (10C's `p_ships` list accepts >1); **co-located multi-ship combat** (larger encounters); multi-ship trade/mine/explore | migrations + UI + combat group resolution | engine reused, not replaced |

Every phase keeps `verify-m2..m5`, `m45`, `galaxy9b` green. **Nothing is deleted or renamed.**
**The 10C–10F contracts are shaped (ship-id-parameterized, group-ready) so 10G+ adds ships
without rewrites** (★ vision).

---

## 8. Spaghetti risks & mitigations

**Spaghetti**
- Combat must NOT branch "main-ship vs old-fleet" throughout `process_combat_ticks`.
  **Mitigation:** resolve *both* paths into the **same `fleet_units`-shaped combat input
  before combat starts**; combat stays single-path. The only real branch is **on defeat**
  (destroy vs damage), isolated in one named helper (e.g. `expedition_resolve_defeat(encounter)`),
  not inline `if`s.
- Stats must have **one source**: `calculate_expedition_stats`. The frontend must never
  re-derive stats.
- **Activity rules must be stat-driven, NOT hardcoded per ship class** (★ vision). No
  `if ship.type = 'combat'` style locks anywhere — any ship can attempt any activity; its
  captains/modules/loadout/stats (via `calculate_expedition_stats`) decide effectiveness/risk.
  This keeps the "can I send this ship here?" logic in *one* place (stats), not scattered.
- **Multi-ship later:** a group of ships must resolve into the **same `fleet_units`-shaped
  combat input** (sum the resolved units), so combat stays single-path. Do not add per-ship
  combat branches; group composition is just a bigger input.

**Duplicate systems**
- Two send RPCs (old + `send_main_ship_expedition`) coexist only during 10C–10F. `/galaxy` must
  call **exactly one** (the flag decides) — never two send buttons.
- No new combat/movement/reward tables — reuse the engine.

**Residual softlock**
- A `repairing` ship MUST always be sendable at ≥ a minimum-readiness floor (or auto-regen to
  it on a timer with no resource gate). If "damaged" = "unsendable", the lock returns.
- A weak loadout that can't beat *any* hunt is a **balance** issue, not a hard lock (low-tier /
  safe targets remain). Keep at least one always-winnable low-tier target.

---

## 9. What must NOT be touched yet

- `fleet_destroy` semantics for the **old disposable path** (until 10E, and even then only for
  main-ship expeditions).
- `reward_grant` / pending-bundle / **return-on-arrival reward law** (never).
- `combat_ticks`/`combat_events` logging controls, retention cleanup, test-cleanup
  (`Phase A/B/C` — orthogonal).
- `train_units` / `build_orders` (reframed later, not removed now).
- `base_units`, `fleet_units`, `unit_types`, `send_fleet_to_location`, existing combat
  functions — **kept and working.**
- No emergency-recovery-kit implementation (superseded by the persistent ship; stays parked).
- **Do NOT relax `main_ship_instances.player_id` UNIQUE yet** — multi-ship is 10G+; the
  intervening phases only need to be *shaped* for it (ship-id-parameterized, group-ready
  contracts), not actually multi-ship.

---

## 9b. Removing support capacity / support craft — later (safe order, NOT now)

Support is **deprecated/dormant**, not core. Remove it **only after** nothing depends on it,
in this order (each step keeps everything green; no sudden deletes):
1. **Hide from UI** *(done in this correction)* — the 10B preview shows the main ship only; no
   support-craft picker, no capacity bar, no support wording. Player-facing game has no support.
2. **Stop depending on the support stat path** — when the captain/module/upgrade stat source
   lands (replacing `calculate_expedition_stats`'s support math), drop the support layer from
   the preview/send code so no live path calls support logic.
3. **Deprecate the functions** — once unused: stop computing support in `calculate_expedition_stats`
   (or retire the function), and drop `get_my_expedition_preview`'s loadout arg.
4. **Drop the schema last** — only when no code references them: remove `support_craft_types`,
   the `support_capacity` / `base_support_capacity` columns, and update the `support_capacity_used`
   verify (Phase 6's `verify-phase6` will be retired/updated then).

Until step 4, **do not delete tables/columns** — they sit dormant and unused.

---

## 10. Recommended next implementation phase

**Phase 10B — read-only main-ship preview — DONE & accepted** (`get_my_expedition_preview` RPC,
read-only `/galaxy` panel, `verify:mainship-preview` 8/8). Strict no-write; validated the
stat-source model end-to-end.

**Next: Phase 10C — `send_main_ship_expedition` (new write path), behind a flag, no UI.** Key
shaping per the ★ vision:
- **Group-ready contract:** accept a `p_ships jsonb` list of `main_ship_id` (+ per-ship loadout)
  and `p_activity` — but **validate exactly one ship for safety** in 10C. This lets 10G+ allow
  groups without a redesign.
- **Ship-id-parameterized**, never "the player's only ship."
- Resolves ship+loadout → `fleets`/`fleet_units` (reusing the engine) → existing movement/combat;
  rewards/return unchanged.
- New `verify:mainship` script; old `send_fleet_to_location` path untouched.

**Gate:** 10C introduces writes, so it starts **only after** the player's **live-web check of
10B** and explicit approval. Do **not** start 10C until then.
