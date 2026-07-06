# TRADE-FLEET-0B — Multi-Ship + Volume-Cargo Contract (DESIGN / APPROVAL-ONLY)

> Recorded 2026-07-03. **Design/approval only. Nothing is built.** No branch, PR, migration, code, seed,
> workflow, deployment, production test, flag, or production-state change. **Migration head stays `0072`.**
> PORT-ENTRY, coordinate-travel (`mainship_coordinate_travel_enabled = false`), flags, movement systems, and all
> existing gameplay are untouched.
>
> **This document does exactly two things**, both grounded in `TRADE_FLEET_0A_IMPACT_AUDIT.md` (the 0A audit)
> and the **FIXED product direction** (`DEV_LOG.md` 2026-07-02; `ROADMAP.md` Phase-10 row + Standing-Law #1
> amendment): volume-only `m³`, ship-bound cargo (never pooled), multi-ship foundation, one selected/owned/docked
> ship per market action, ships as the first credit sink.
>
> ### ✅ Approval gate — APPROVED (planner design authority) 2026-07-03 — TRADE-FLEET-0C may begin
> The **five §1 resolutions below are APPROVED (planner design authority) 2026-07-03 — TRADE-FLEET-0C may begin.**
> They resolve the five open decisions in 0A §8.2. Nothing here invents new game direction — every proposal is
> tied to an existing doc. The §2 schema/API freeze is the contract that TRADE-FLEET-0C will implement *now that the
> five resolutions are approved*. **No repository / migration / flag / verifier / production state is changed by
> this document.**
>
> **Baseline referenced:** `origin/main` @ `f48bc53`, migration head **`0072`** (as recorded in `DEV_LOG.md`
> 2026-07-03). Concrete current-state anchors cited below were read read-only and are not modified.

---

## §1 — The five §8.2 product decisions — APPROVED (planner design authority) 2026-07-03 — TRADE-FLEET-0C may begin

Each resolution is a **proposal only**. Rationale is tied to existing docs; no new game direction is introduced.

### (a) Entry point for acquiring an additional main ship — *never implicit duplicate creation*

**Proposed resolution.** Add **one explicit authenticated RPC, `commission_additional_main_ship()`**, as the sole
surface through which a player obtains a 2nd+ main ship. It is a **deliberate player action**, structurally
distinct from the first-ship path:

- The existing first-ship idempotency (`commission_first_main_ship()` / `ensure_main_ship_for_player()`, which
  today rely on `main_ship_instances.player_id UNIQUE`) is **preserved for the 0-ship case only** — re-running it
  never creates a 2nd ship. When 0C drops the `player_id UNIQUE` constraint (0A §5, §8.1), the first-ship path is
  re-anchored on "player currently has **zero** ships" rather than on the row-level unique conflict.
- `commission_additional_main_ship()` reuses the deployed PORT-ENTRY commission machinery
  (`port_entry_commission_writer`, service-role-only, which inserts a ship DIRECTLY into canonical `at_location`;
  `DEV_LOG.md` 2026-06-30) so a new ship lands docked at the player's **current port**, in the same eligible
  state a first ship reaches. No new spatial/commission pattern is invented.
- **No implicit path may ever create a second ship.** This directly implements the 0A §5 migration guarantee
  ("dropping `player_id UNIQUE` must be paired with an **explicit add-ship** entry point … Adding ships is only
  ever an explicit action") and 0A §8.2.1 ("must be explicit; never implicit duplicate creation").

*Grounded in:* 0A §5 (migration guarantees), §8.2.1, §1.2 (`commission_first_main_ship` → "needs an **add-ship**
path"); `DEV_LOG.md` 2026-06-30 (PORT-ENTRY commission/normalize pattern).

### (b) Acquisition / progression model — cost / gating / pacing + per-player ship cap for V1

**Proposed resolution.** Ships are the **first credit sink** (Phase-10 row; 0A §8.2.2). For V1:

- **Hull:** V1 sells **only the existing starter hull** (`starter_frigate`, "Byeharu-class Frigate"). Larger /
  specialized hulls are **future-only** (0A §3, §8.2.2 "larger/specialized hulls later") and are **not** added now.
- **Cost / gating:** a **flat credit price** debited from the **lazy `player_wallet`** (the wallet retained in the
  Phase-10 row and 0A §3). Because the wallet lands with **TRADE-MARKET-1** (per the sequence), the *priced*
  acquisition sink **activates when the wallet exists**. The **explicit add-ship RPC + cap enforcement land in
  0C** (structural, so multi-ship coexistence can be proven); the **credit debit attaches at TRADE-MARKET-1**.
  Proposed price is deliberately deferred to market balance (like the hull's "conservative; not final balance"
  note) — **a placeholder, not a frozen number.**
- **Pacing:** **no build-queue / time-gate for ships in V1.** The serial build queue is the support-craft/module
  home (`ROADMAP.md` Standing Law #2; ARCHITECTURE §16 M4.5), **not** ships. Acquisition is gated by **credits +
  cap only**.
- **Per-player ship cap (V1):** proposed **cap = 3** ships per player. Rationale: keeps the "first credit sink"
  meaningful, makes concurrency (docked-while-travelling, 0A §4) directly testable with N ≥ 2, and is
  **conservative** in the same spirit as the single starter hull. The cap is a `game_config` value
  (`max_main_ships_per_player`) so it is tunable without redeploy (ARCHITECTURE §15 `game_config` pattern), and
  is enforced server-side inside `commission_additional_main_ship()` under the ship lock.

*Grounded in:* Phase-10 row ("ships as first credit sink"; "lazy wallet"); 0A §3 (lazy `player_wallet`), §8.2.2;
`ROADMAP.md` Standing Law #2 + ARCHITECTURE §16 (serial queue = support craft, not ships); ARCHITECTURE §15
(`game_config` tunables).

> **Sequencing note (not a new decision):** the *mechanism* (RPC + cap) is 0C; the *price debit* is
> TRADE-MARKET-1 (wallet dependency). This is a consequence of the already-approved slice order, surfaced here so
> approval is informed.

### (c) Canonical commodity denominations + fixed `unit_volume_m3`, and the starter-hull `base_cargo_capacity_m3`

**Proposed resolution.** Volume-only, canonical `m³` (FIXED direction #3–#4; 0A §3). Each denomination resolves
to a **fixed canonical `m³`**; capacity math is `unit_volume_m3 * qty` only — **no mass/density/dual-cap.**

**Denomination → fixed canonical volume (proposed):**

| Denomination | `unit_volume_m3` (proposed, FIXED per denomination) |
|---|---|
| `bundle` | `0.25` |
| `crate` | `1.0` |
| `tank` | `2.0` |
| `pallet` | `4.0` |
| `container` | `8.0` |

Rationale: `crate = 1 m³` makes the hold read intuitively (capacity in "crate-equivalents"); the rest form a
clean, defensible progression. These are the exact five denominations enumerated in 0A §3.

**Starter-hull capacity (proposed):** `base_cargo_capacity_m3 = 50.0`, **replacing the abstract `50`** currently
seeded on `main_ship_hull_types.base_cargo_capacity` for `starter_frigate` (verified read-only:
`20260617000043_main_ship_instance.sql:38`). Keeping the numeral **50 → 50 m³** preserves the existing
conservative scale (≈ 50 crates / ≈ 6 containers) with zero balance drift, and directly satisfies 0A §8.2.3
("+ the starter hull `base_cargo_capacity_m3` value (replacing the abstract 50)").

**Starter commodity seed (proposed; conservative, balance non-final):** each `trade_goods` row's
`unit_volume_m3` **equals its denomination's canonical volume** above.

| `good_id` | denomination | `unit_volume_m3` |
|---|---|---|
| `textiles` | `bundle` | `0.25` |
| `ore` | `crate` | `1.0` |
| `provisions` | `crate` | `1.0` |
| `reagents` | `tank` | `2.0` |
| `machinery` | `pallet` | `4.0` |
| `luxury_goods` | `container` | `8.0` |

`base_value` and the full commodity roster are **market-balance concerns finalized in TRADE-MARKET-1** (like the
hull's "not final balance" note); this seed exists so `ship_cargo_lots` has valid `good_id` FKs in 0C. **No fuel
commodity** is included (fuel is future-only, FIXED #7).

*Grounded in:* FIXED direction #3–#4; 0A §3 (`trade_goods`, denomination list, `unit_volume_m3 * qty`), §8.2.3;
`20260617000043_main_ship_instance.sql:38` (abstract `50`).

### (d) Cost-basis granularity — per-lot `unit_cost_basis` vs weighted-average per (ship, good)

**Proposed resolution.** **Per-lot `unit_cost_basis`** on `ship_cargo_lots` (exactly the 0A §3 shape).

Rationale, tied to the locality model (0A §2–§3):

1. The 0A §3 boundary already models **lots** carrying `origin_location_id`, `acquired_at`, and
   `unit_cost_basis` — per-lot provenance is the natural fit for later profit display, with **no valuation
   system** required.
2. A weighted-average-per-`(ship, good)` running figure would be a **mutable second source of truth** updated on
   every buy/sell, competing with the lot sum that 0A §3 declares authoritative ("the lot sum is the source of
   truth"). Per-lot avoids that duplicate writer and keeps the model structurally simple.
3. Per-lot preserves the **locality invariant chain** (0A §2): a lot belongs to one ship, travels by association,
   and never needs pooled/averaged cross-lot math.

Profit display (later) computes realized margin from the specific lot(s) consumed on sale — no mass, no density,
no account-level valuation.

*Grounded in:* 0A §2 (locality chain), §3 (`ship_cargo_lots … unit_cost_basis`; "lot sum is the source of
truth"), §8.2.4.

### (e) Destroyed-ship cargo policy

**Proposed resolution.** **Confirmed: cargo on a `destroyed` ship is simply inaccessible until repair — no loss,
no transfer, no special handling.**

- Cargo lots remain rows attached to the `destroyed` ship's `main_ship_id`; **nothing deletes or moves them.**
- A `destroyed` ship is **not `at_location`/eligible**, so every market write fails closed (0A §2 link 4, §5
  "no cargo on invalid/destroyed ships" — enforced **at the market write**, not by migration). Thus a destroyed
  ship can neither trade nor lose cargo.
- On **repair** (`repair_main_ship`, ship-scoped safelock; 0A §1.2), the ship returns to an eligible state and
  its lots are reachable again — idempotent, no duplication.
- **No ship-to-ship transfer** exists (FIXED #7; out of V1). Loss / insurance / piracy economics are
  **future-only** (0A §3).

*Grounded in:* FIXED #7 (transfer out of scope); 0A §2 (link 4), §3 (loss economics future-only), §5 (destroyed
state row); `ROADMAP.md` Standing Law #1 ("usually returns damaged / needs repair rather than being deleted").

---

## §2 — Frozen schema / API contract (consistent with 0A §3)

This is the **contract TRADE-FLEET-0C will implement** once §1 is approved. It is written at DDL/signature
granularity for review; **it is not a migration** and creates nothing. All ownership obeys
`SYSTEM_BOUNDARIES.md` (one sole writer per table; acyclic call graph; no client writes; server-authoritative).

### 2.1 Ownership additions (extends `SYSTEM_BOUNDARIES.md §1`)

| Table | Proposed sole writer (owner) | Read access |
|---|---|---|
| `trade_goods` | **Reference/Config** (admin/migration) | public read-only |
| `ship_cargo_lots` | **Trade Cargo** (new system) | owner (via join to `main_ship_instances.player_id`) |
| `trade_receipts` | **Trade Market** (TRADE-MARKET-1) | owner |
| `player_wallet` | **Trade Market** (TRADE-MARKET-1; lazy) | owner |

- **No second writer to `main_ship_instances`.** Per-ship occupied volume is **computed from the lot sum under
  the ship lock** (0A §3). A cached `cargo_volume_m3_used` column on the instance is **explicitly NOT added in
  V1**, because writing a Main-Ship-owned table from the Trade Cargo system would violate the single-writer law.
  (Future-only optimization, behind a Main-Ship-owned setter — not now.)
- **Call graph stays acyclic:** the market orchestrator (TRADE-MARKET-1) validates via **Main Ship**
  (ownership + `at_location` state), writes lots via **Trade Cargo**, debits **Wallet**, records
  **`trade_receipts`** — a one-directional fan-out, no cycle. TRADE-FLEET-0C introduces only the multi-ship +
  cargo *schema* and the command-signature conversion; market writes land in TRADE-MARKET-1.

### 2.2 `trade_goods` — commodity catalog (Reference/Config; public read)

```
trade_goods(
  good_id        text primary key,
  name           text    not null,
  description    text,
  denomination   text    not null check (denomination in ('bundle','crate','tank','pallet','container')),
  unit_volume_m3 numeric not null check (unit_volume_m3 > 0),   -- = the denomination's fixed canonical m³ (§1c)
  base_value     numeric not null default 0 check (base_value >= 0),
  active         boolean not null default true
)
```
- `unit_volume_m3` is the **only** capacity input; capacity math is `unit_volume_m3 * qty` (0A §3). No mass/density.
- Seeded with the §1(c) starter commodities. Public read-only; migration/admin sole writer (no client write).

### 2.3 Per-ship hold capacity (hull + instance)

**Hull `main_ship_hull_types`:**
- **Add** `base_cargo_capacity_m3 numeric not null check (base_cargo_capacity_m3 > 0)`; seed `starter_frigate =
  50.0` (§1c).
- The abstract `base_cargo_capacity int` (currently `50`) is **replaced** (0A §1.1 [M], §3). Verifiers that read
  the abstract column (`verify-phase7/8.mjs`) are updated in the **same 0C slice** (§2.7).

**Instance `main_ship_instances`:**
- **Add** `cargo_capacity_m3 numeric not null check (cargo_capacity_m3 > 0)`, **copied from the hull's
  `base_cargo_capacity_m3` at commission** (so larger/specialized hulls can diverge later; 0A §3).
- The abstract `cargo_used int` / `cargo_capacity int` columns (verified read-only:
  `20260617000043_main_ship_instance.sql:55–56`) are **replaced** by the volume model. Occupied volume is the
  **lot sum** (§2.4); no `cargo_used` counter is maintained.
- **Drop `player_id UNIQUE`** (0A §8.1 blocker (a)) — the single load-bearing multi-ship blocker. Owner-read RLS
  (`player_id = auth.uid()`) is unchanged and remains correct for N rows (0A §1.1 [C]).

### 2.4 `ship_cargo_lots` — per-ship cargo (keyed by `main_ship_id`; the locality anchor)

```
ship_cargo_lots(
  lot_id             uuid primary key default gen_random_uuid(),
  main_ship_id       uuid    not null references main_ship_instances(main_ship_id),  -- NEVER player_id
  good_id            text    not null references trade_goods(good_id),
  qty                numeric not null check (qty > 0),          -- in denomination units
  unit_cost_basis    numeric not null check (unit_cost_basis >= 0),  -- per-lot (§1d)
  origin_location_id uuid    references locations(location_id),
  acquired_at        timestamptz not null default now()
)
```
- **Keyed by `main_ship_id`, never `player_id`** (0A §2 link 1, §3). Player identity is derived **through** the
  ship (`main_ship_instances.player_id`), never stored redundantly — **no** account-scoped trade read exists.
- **Occupied volume per ship** = `sum(l.qty * g.unit_volume_m3)` over `ship_cargo_lots l join trade_goods g …
  where l.main_ship_id = X`, computed **under the ship lock** at trade time. Capacity check:
  `used + delta ≤ instance.cargo_capacity_m3` (0A §3).
- Owner-read RLS via join to `main_ship_instances.player_id = auth.uid()` (no direct `player_id` column to leak a
  pooled read). No client writes; Trade Cargo is sole writer.

### 2.5 Selected-ship command signatures — explicit `p_main_ship_id` + ownership assertion

**Every §1.2 site gains an explicit `p_main_ship_id uuid` argument and a server-side ownership assertion**
(`select … from main_ship_instances where main_ship_id = p_main_ship_id and player_id = auth.uid()` under the
existing per-ship lock; UI selection is never trusted — 0A §4). The current single-ship derivation
(`where player_id = v_player`) is removed **at every site in one coherent slice** (0A §5 safety rule; §8.3
TRADE-FLEET-0C) — **no partial migration.**

The per-ship **lock substrate is unchanged** (`mainship_space_lock_context(p_main_ship_id …)`, no advisory/player
lock — 0A §1.2, §4). Only callers change: they lock the **selected** ship, never a derived one.

| Function (current signature, read-only verified) | Class | Proposed change |
|---|---|---|
| `command_main_ship_space_move(double precision, double precision, uuid)` | [M] | **+ `p_main_ship_id uuid`** |
| `command_main_ship_space_stop(uuid)` | [M] | **+ `p_main_ship_id uuid`** |
| `command_main_ship_space_move_to_location(uuid, uuid)` | [M] | **+ `p_main_ship_id uuid`** |
| `get_my_current_dock_services()` | [M] | **+ `p_main_ship_id uuid`** (resolve *which* docked ship) |
| `get_osn_movement_readiness()` | [M] | **+ `p_main_ship_id uuid`** (per selected ship) |
| `repair_main_ship()` | [M] | **+ `p_main_ship_id uuid`** (ship-scoped safelock) |
| `normalize_main_ship_dock()` | [M] | **+ `p_main_ship_id uuid`** (ship-scoped) |
| `commission_first_main_ship()` | [M] | signature unchanged; **body re-anchored** on "zero ships" (idempotency reframe, §1a) |
| **`commission_additional_main_ship()`** (NEW) | [M] | **new** explicit add-ship RPC (§1a–b) |
| coordinate-gate command (`…0070…:62`) | [C] | **stays dark**; ship-scoped only when later touched — **deferred, not in 0C's active path** |
| port-launch reveal readiness (`…0068…:152`) | [C] | **deferred** |

**Already ship/fleet-addressed — NO signature change** (0A §1.2 [N]): `send_main_ship_expedition(jsonb, uuid)`,
`move_main_ship_to_location(uuid, uuid)`, `request_main_ship_return(uuid)`.

**Transition compat shim (implementation detail, resolved in 0C — 0A §8.2 note):** while a player has exactly one
ship, zero-arg legacy call paths may default to the sole ship; the shim is removed once the UI passes an explicit
`p_main_ship_id` (TRADE-UI-1). Not a permanent fallback.

### 2.6 `trade_receipts` — per-ship idempotency (frozen shape; lands with TRADE-MARKET-1)

```
trade_receipts(
  receipt_id   uuid primary key default gen_random_uuid(),
  main_ship_id uuid not null references main_ship_instances(main_ship_id),
  request_id   uuid not null,
  …            -- offer/qty/price columns finalized in TRADE-MARKET-1
  unique (main_ship_id, request_id)
)
```
- Idempotency key is **`(main_ship_id, request_id)`** — mirroring the existing command-receipt pattern
  (`main_ship_space_movements (main_ship_id, request_id)`, `20260618000060:35`; 0A §4). A player may have
  simultaneous in-flight buy/sell for **different** ships without collision.
- **Shape frozen here; the table + buy/sell RPCs are created in TRADE-MARKET-1**, not TRADE-FLEET-0C.

### 2.7 Same-slice verifier-inventory update plan

The 0A §7 tripwires **must be updated in the SAME slice as the RPC changes** or they fail closed. This plan freezes
*what changes where*; **nothing is edited by this document.**

**PORT-ENTRY exact-RPC-inventory** (`scripts/port-entry-1-production-verify.sql`, D2 `VALUES` list — verified
read-only: the complete **20-RPC** authenticated set must EQUAL the approved list by OID; any changed signature or
new RPC fails `INV_MISSING`/`INV_EXTRA`). In the **0C** slice the expected `VALUES` list must be updated for every
signature change in §2.5 (each is an OID change):
- `command_main_ship_space_move(double precision, double precision, uuid)` → new signature (+`uuid` ship arg)
- `command_main_ship_space_stop(uuid)` → new signature
- `command_main_ship_space_move_to_location(uuid, uuid)` → new signature
- `get_my_current_dock_services()` → new signature
- `get_osn_movement_readiness()` → new signature
- `repair_main_ship()` → new signature
- `normalize_main_ship_dock()` → new signature
- `commission_first_main_ship()` → signature unchanged (body-only reframe; see md5 pins below)
- **ADD** `commission_additional_main_ship(…)` to the expected set (else it trips `INV_EXTRA`)
- (Buy/sell/get-cargo RPCs update the inventory later, in **TRADE-MARKET-1's** slice — **not** 0C.)

**PORT-ENTRY prosrc md5 pins** (same script, the 3 pinned bodies: `port_entry_commission_writer`,
`commission_first_main_ship`, `normalize_main_ship_dock`). In the **0C** slice:
- `commission_first_main_ship` + `normalize_main_ship_dock` bodies change (zero-ship reframe / `p_main_ship_id`)
  → their md5 pins must be **re-pinned** in the same change.
- If `commission_additional_main_ship` reuses `port_entry_commission_writer` and its body changes → **re-pin**
  it too; if a distinct writer is introduced, add its pin.

**Other verifiers (updated in the same 0C slice; 0A §7):** `verify-phase7.mjs` / `verify-phase8.mjs`
(single-ship + abstract `cargo` → volume shape), `verify-mainship-*.mjs` (single derived ship → selected ship),
and dev commission/grant/cleanup helpers (one-ship provisioning → N-ship). A **new TRADE-FLEET verifier** proves
the 0A §7 eight properties (N-ship coexistence; independent per-ship movement; a lot reachable via exactly one
ship; volume-only capacity; docked-trade-while-another-in-transit concurrency; no pooled/remote path; legacy
one-ship validity; per-ship `(main_ship_id, request_id)` idempotency + exact-RPC inventory equals the new set).

### 2.8 Explicit V1 exclusions (kept out — FIXED direction #7; 0A §3)

**NOT in V1, and NOT added by this contract:** mass / `mass_kg` / density / dual mass+volume caps · fuel / range /
acceleration / handling · **ship-to-ship cargo transfer** · port warehouses · automated trade routes · pooled /
account-level trade inventory · remote / teleport market actions · cargo loss / piracy / insurance / destruction
economics · specialized cargo-hold modules · captain effects on cargo · larger/specialized hulls. The boundary is
**extensible** toward these (0A §3 reserved), but none are needed for V1 and **none are proposed here.**

---

## §3 — Deferral & scope boundary

- **TRADE-FLEET-0C (implementation — DEFERRED, not begun):** one coherent slice that drops
  `main_ship_instances.player_id UNIQUE`, adds the per-ship volume-cargo schema (§2.2–§2.4), converts **every**
  §2.5 command site to explicit `p_main_ship_id` + ownership assertion **together**, updates the §2.7 verifiers in
  the **same** slice, and proves N-ship coexistence / independent per-ship movement / concurrency / legacy
  one-ship validity (0A §8.3).
- **TRADE-MARKET-1 / "0C+" (DEFERRED):** `market_offers`, lazy `player_wallet`, atomic volume-checked buy/sell
  against a selected docked ship, `trade_receipts` (§2.6), and the credit-priced add-ship debit (§1b).
- **TRADE-UI-1 (DEFERRED):** ship switcher + selected-ship market/fleet UI; retires the sole-ship shim (§2.5).
- Mass / fuel / ship-to-ship transfer / warehouses remain **out of V1** (§2.8).

---

## §4 — State-change statement

**No repository, workflow, deployment, flag, migration, verifier, or production state is changed by this
document.** Migration head remains **`0072`**; `mainship_coordinate_travel_enabled` stays **false**; PORT-ENTRY,
coordinate-travel, movement, and existing gameplay are untouched. `DEV_LOG.md` and `ROADMAP.md` are **not** updated
by this document. The only artifact written is this design-record contract. **The five §1 resolutions are APPROVED
(planner design authority) 2026-07-03 — TRADE-FLEET-0C may begin; nothing is built by this document.**
