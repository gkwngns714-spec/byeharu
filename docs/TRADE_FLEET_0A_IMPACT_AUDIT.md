# TRADE-FLEET-0A — Multi-Ship + Volume-Cargo Impact Audit (READ-ONLY)

> Recorded 2026-07-02. **Read-only audit. Nothing implemented.** No branch, PR, migration, code, seed,
> workflow, deployment, production test, flag, or production-state change. PORT-ENTRY, coordinate-travel,
> flags, movement systems, and existing gameplay are untouched.
>
> **Baseline:** `origin/main` @ `addc023` (PR #65), migration head **`0072`**, read from an isolated clone of
> `main`; the protected working checkout was not touched.
>
> **Fixed product direction** (see `DEV_LOG.md` 2026-07-02): multiple persistent main ships from the start;
> cargo **ship-bound**, **never pooled**, **no account-level trade inventory**, no remote/teleport trades;
> capacity is **volume-only, canonical `m³`** (no abstract units, **no kg/mass/density/dual-cap** in V1 —
> those are future-only); each commodity has a fixed canonical `m³` denomination; every market action targets
> **one selected, owned, docked, eligible ship**; coordinate travel stays dark (port-to-port suffices).
>
> **Legend for classification:** **[M]** mandatory for multi-ship Trading V1 · **[C]** compatibility-sensitive ·
> **[F]** optional/future enhancement · **[N]** not affected.

---

## §1 — Current one-main-ship assumptions (by surface)

### 1.1 Database

| Object | File:line | Assumption | Class |
|---|---|---|---|
| `main_ship_instances.player_id … UNIQUE` | `20260617000043_main_ship_instance.sql` (`player_id uuid not null unique`) | **Hard** one-ship-per-player constraint — the single load-bearing blocker. | **[M]** |
| `ensure_main_ship_for_player` `on conflict (player_id) do nothing` | `20260617000043:80` | One-ship idempotent creator. | **[M]** |
| `get_main_ship(p_player)` | `20260617000043:87` | Returns *the* one row per player. | **[M]** |
| `rename_main_ship(p_player,name)` `update … where player_id` | `20260617000043:100`+ | Renames the single ship. | **[M]** |
| Owner-read RLS `player_id = auth.uid()` (select) | `20260617000043` | Still correct with N rows, but readers assuming one row must change. | **[C]** |
| Abstract cargo columns `cargo_used int`, `cargo_capacity int` | `20260617000043` | Abstract-unit capacity on the instance. | **[M]** (replace w/ per-ship `cargo_capacity_m3`) |
| Hull `main_ship_hull_types.base_cargo_capacity int` (+ seed 50) | `20260617000043` | Abstract capacity in the catalog. | **[M]** (→ `base_cargo_capacity_m3`) |
| Status/`spatial_state` check constraints (home/traveling/…/destroyed; at_location/in_space) | `20260617000043`, `20260618000054_mainship_spatial_state.sql` | Per-ship (fine), but state machine assumed **one** ship per player context. | **[C]** |
| `fleets.main_ship_id` linkage + `… where main_ship_id = v_ship … limit 1` | `20260616000006_fleet_system.sql`, `20260618000072` | Already **ship-scoped** (good); must never be re-collapsed to "the player's fleet." | **[C]** |
| `main_ship_space_movements` partial-unique (one active per ship) + `(main_ship_id,request_id)` idempotency | `20260618000055_osn3_s1_space_schema.sql`, `20260618000060:35` | Already **per-ship** — supports concurrent ships. | **[N]** |
| `location_presence` (per fleet) | `20260616000008_presence_system.sql` | Per fleet/ship; correct for N ships. | **[N]** |
| **Trade-cargo table** | *does not exist* | Must be **per-`main_ship_id`** (never `player_id`). | **[M]** new |
| `player_inventory` (non-trade loot) | `20260617000039_inventory.sql` | Stays account-level for **loot only**; must **not** become a trade hold. | **[N]** (must stay uninvolved) |

### 1.2 Backend RPC / functions — the uniform single-ship derivation

**Every ship-scoped command resolves the ship implicitly** as
`select … main_ship_id … from main_ship_instances where player_id = v_player`. This *is* the "single active
ship" assumption. Each must gain an explicit **`main_ship_id` argument + server-side ownership assertion**:

| Function | File:line | Class |
|---|---|---|
| `command_main_ship_space_move` (zero ship arg) | `20260618000060_osn3_s6a_public_space_move_command.sql:68` | **[M]** |
| `command_main_ship_space_stop` | `20260618000064_osn3_osn4_space_stop.sql:363` | **[M]** |
| `command_main_ship_space_move_to_location` (port-to-port) | `20260618000067_osn_hub1a_canonical_location_targets.sql:859` | **[M]** |
| `get_my_current_dock_services` (zero-arg "my dock") | `20260618000069_phase9_dock_services_read.sql:46` | **[M]** (must resolve **which** docked ship) |
| coordinate-gate command | `20260618000070_osn_coord_gate_server_authoritative.sql:62` | **[C]** (stays dark; ship-scope when touched) |
| `get_osn_movement_readiness` / capability | `20260618000071_osn_coord_enable_1b_readiness_capability.sql:53` | **[M]** (per selected ship) |
| port-launch reveal readiness | `20260618000068_portlaunch1a_reveal_readiness.sql:152` | **[C]** |
| `commission_first_main_ship` ("FIRST" ship, single) | `20260618000072_port_entry_commission_normalize.sql:117,129` | **[M]** (needs an **add-ship** path) |
| `normalize_main_ship_dock` (zero-arg, single) | `20260618000072:179` | **[M]** (ship-scoped) |
| `mainship_preview` writer | `20260618000049_mainship_preview.sql:36` | **[C]** |
| `repair_main_ship` (single-ship safelock) | `20260618000052_mainship_repair_safelock.sql:37,80` | **[M]** |
| destruction / coordinate-complete | `20260618000059_osn3_s5_destruction_coordinate_complete.sql:46` | **[M]** |
| `send_main_ship_expedition(p_ships[],…)` / `move_main_ship_to_location(p_fleet,…)` / `request_main_ship_return(p_fleet)` | send/move path (`mainshipApi.ts` wrappers; 10C RPCs) | Already **ship/fleet-addressed** (take ship/fleet id). | **[N]** |

**Locking substrate — already ship-scoped (key positive finding).**
`mainship_space_lock_context(p_main_ship_id, …)` locks `main_ship_instances where main_ship_id = … for update`,
then that ship's fleet → active space-movement → presence, **with no advisory lock and no player-level lock**
(`20260618000056_osn3_s2_transition_core.sql:13,20,38-69`). `mainship_space_validate_context(main_ship_id)` is
likewise per-ship. → Concurrent operation of a player's ships is **not** blocked by the lock model today; only
the *caller-side derivation* forces one ship. **[N]** (substrate) / **[M]** (callers that feed it the derived ship).

### 1.3 Frontend

| Surface | File:line | Assumption | Class |
|---|---|---|---|
| `fetchMyMainShip()` `.maybeSingle()` | `src/features/map/mainshipApi.ts:59-72` | "the caller's **single** ship"; `has_ship` bool. | **[M]** → list + selected id |
| `MainShipRow.cargo_capacity:number` | `mainshipApi.ts:24-33` | Abstract unit. | **[M]** → `cargo_capacity_m3` |
| OSN command wrappers send **no ship id** | `mainshipApi.ts:248,258,274` | Server derives ship from `auth.uid()`. | **[M]** → send selected `main_ship_id` |
| `fetchMyCurrentDockServices()` zero-arg | `mainshipApi.ts:186-190` | "my dock" (one ship). | **[M]** |
| Port-entry API `.maybeSingle()` / `hasShip` | `src/features/portentry/portEntryApi.ts:60-61`, `portEntry.ts:104,122` | "Claim First Ship" (one). | **[C]** (keep first-ship flow; add "another ship") |
| Map/preview/marker/state | `useGalaxyMapData.ts`, `MainShipPreview.tsx`, `MainShipMarker.tsx`, `resolveMainShipMarker.ts`, `Dashboard.tsx`, `useGameState.ts`, `MainShipPanel.tsx`, `MainShipCommand.tsx` | Render/track one ship. | **[M]** (map/selection) / **[C]** (panels) |

### 1.4 Verifiers / tests / onboarding

| Surface | File:line | Assumption | Class |
|---|---|---|---|
| PORT-ENTRY realchain proof | `scripts/port-entry-1-proof.sql:39,64` | new player = **0** ships; post-commission **exactly 1** (`if n<>1 then raise exception '% ships'`). | **[M]** |
| PORT-ENTRY prod verifier — exact auth RPC inventory (by OID) | `scripts/port-entry-1-production-verify.sql:83-120` | The complete authenticated RPC set must **EQUAL** the approved list; any new/re-signed RPC fails `INV_MISSING`/`INV_EXTRA`. | **[M]** (tripwire — expected `VALUES` list `:89`+ must be updated in-change) |
| PORT-ENTRY prod verifier — prosrc md5 pins | `scripts/port-entry-1-production-verify.sql:13-14` | Exact body md5 of the 3 PORT-ENTRY fns. | **[M]** |
| Phase-7 / Phase-8 verifiers | `scripts/verify-phase7.mjs`, `verify-phase8.mjs` | single-ship shape + abstract `cargo`. | **[M]** |
| mainship send/move/repair/preview verifiers | `scripts/verify-mainship-*.mjs` | single derived ship. | **[C]** |
| dev commission/grant helpers | `.github/workflows/dev-commission-mainship.yml`, `scripts/dev-commission-mainship.mjs`, `dev-grant-ships.mjs` | one-ship provisioning; test users. | **[C]** |
| test-user cleanup | `scripts/dev-clean-test-users.mjs`, `20260617000029_dev_reset_player.sql` | cleanup assumes one ship per user. | **[C]** |

---

## §2 — Cargo-locality guarantees (how the model enforces them)

Target invariant chain:
```
cargo lot → one player → one ship → reachable only via that ship → moves only when that ship moves
          → tradeable only while that ship is docked at the current port
```
The model enforces each link **structurally**, with **no** pooled-ledger shortcut:

1. **belongs to one player / one ship** — the trade-cargo row is keyed by `main_ship_id` (FK →
   `main_ship_instances`), and player identity is derived **through** the ship (`main_ship_instances.player_id`),
   never stored redundantly as a pooling key. There is **no** `player_id`-keyed trade-cargo table.
2. **available only through that ship** — all reads/writes join `… where main_ship_id = <selected>` with an
   ownership assertion (`instances.player_id = auth.uid()`). No account-scoped cargo read exists to bypass it.
3. **moves only when the ship moves** — cargo has no position of its own; its location is *implicitly* the
   ship's location (fleet/presence/spatial_state). Because nothing else references the lot, a ship move needs
   **no cargo write at all** — the lot travels by association. (This is why per-ship locality is cheaper than a
   pooled ledger, not just safer.)
4. **tradeable only while docked at the current port** — buy/sell/validate resolve the ship's **live** dock via
   the existing canonical dock/presence context (`get_my_current_dock_services` per selected ship →
   `at_location` + active `market` service), re-checked **inside** the transaction under the ship lock.

**Rejected shortcut:** a per-player pooled cargo ledger with a `ship_id` tag column would violate links 1–3
(a pooled table invites account-scoped reads and pooled capacity math) and is **not** proposed.

---

## §3 — Minimal design-level data boundary (proposal only; nothing built)

**Commodity catalog (reference/config; public read):**
- `trade_goods(good_id pk, name, description, denomination text /* crate|pallet|tank|container|bundle */,
  unit_volume_m3 numeric not null check >0, base_value numeric, active bool)` — each denomination resolves to a
  **fixed canonical `m³`**; capacity math uses `unit_volume_m3 * qty` only.

**Per-ship hold capacity (on the instance / hull):**
- hull `base_cargo_capacity_m3 numeric` (replaces `base_cargo_capacity`); instance `cargo_capacity_m3 numeric`
  (copied from hull at commission so larger/specialized hulls diverge later). **No** mass/density columns.

**Per-ship cargo lots (per-`main_ship_id`; the locality anchor):**
- `ship_cargo_lots(lot_id pk, main_ship_id fk NOT NULL, good_id fk, qty numeric,
  origin_location_id, acquired_at timestamptz, unit_cost_basis numeric /* for later profit display */)`.
  Lots are **ship-scoped**; `qty` in denomination units, occupied volume derived as `qty * unit_volume_m3`.
- **Occupied volume per ship** = `sum(qty * unit_volume_m3) over lots where main_ship_id = X` — computed under
  the ship lock at trade time (optionally cached on the instance as `cargo_volume_m3_used`, but the lot sum is
  the source of truth). Capacity check: `used + delta ≤ cargo_capacity_m3`.

**Selected-ship market context (server-authoritative):**
- market RPCs take `p_main_ship_id`; server asserts (a) owned by `auth.uid()`, (b) ship `at_location` at the
  port whose offer is being traded, (c) eligible state, (d) atomic volume check — all in one transaction with
  `trade_receipts(main_ship_id, request_id)` idempotency + `market_offers` (server-owned) + lazy `player_wallet`.

**Future-only (explicitly NOT in V1, reserved so the boundary is extensible):** `mass_kg` / density / fuel /
range / acceleration / handling; specialized cargo-hold modules; captain effects; larger hulls (credit sink);
insurance/loss economics; ship-to-ship transfer; warehouses. None are needed for V1 and none are added now.

---

## §4 — Multi-ship concurrency & safety

Target future state that must be permitted:
```
Ship A: docked at Haven, trading
Ship B: travelling toward Slagworks
Ship C: docked at Driftmarch with separate cargo
```

- **Lock order** — already defined **per ship**: instance → fleet → space-movement → presence, `for update`,
  no advisory/player lock (`20260618000056:13,38-69`). Two ships of one player lock **disjoint** rows → no
  cross-ship contention. **No change needed to the lock order**; callers must lock the *selected* ship, not a
  derived one.
- **Command-receipt scoping** — idempotency is already `(main_ship_id, request_id)` (`20260618000060:35`), and
  `trade_receipts` must follow the same **per-ship** key. A player may have simultaneous in-flight commands for
  different ships without collision.
- **Ship-specific movement ownership** — `fleets.main_ship_id` + `main_ship_space_movements.main_ship_id` +
  the one-active-movement-per-ship partial unique already isolate movement per ship. **[N]**
- **Ship-specific port presence** — `location_presence` is per fleet/ship; A docked while B moving is already
  representable. **[N]**
- **Server-authoritative selected-ship validation** — the **only** new safety rule: every ship-scoped command
  validates `p_main_ship_id` ownership + state server-side; **UI selection is never trusted**.
- **UI selection vs backend truth** — the client holds a "selected ship" for convenience; the server re-derives
  ownership/state from `auth.uid()` + `p_main_ship_id` on every call.
- **Cross-ship interference risk** — with per-ship rows and per-ship locks, one ship's move/repair/destruction
  cannot mutate another ship's state **provided** no code path reintroduces a `where player_id` single-row
  write. The audit found **no** player-level ship lock or global "current ship" row — so the substrate is safe;
  the discipline is: **never resolve "the player's ship" again.**

**Blocker-level statement:** the backend does **not** rely on one global player ship state today (state is
per-instance/per-fleet). The single global-ish coupling is the derivation convenience + the UNIQUE constraint —
both removed by TRADE-FLEET-0. No architectural blocker to safe concurrency was found.

---

## §5 — Compatibility & migration risks (design-level)

The future migration must carry all existing accounts (exactly one ship today) into an N-ship world with **zero**
disruption, across every ship state:

| State | Source | Requirement |
|---|---|---|
| `home` / `legacy_home` | pre-PORT-ENTRY ships | remain valid, single ship; no forced cargo/dock. |
| `legacy_present` | legacy send path | still normalizable via `normalize_main_ship_dock` (unchanged behavior). |
| `at_location` | PORT-ENTRY commission | the tradeable state; unchanged. |
| `in_transit` / `in_space` | movement / (dark) coordinate | must not be corrupted; movement stays per-ship. |
| `destroyed` | safelock | **no cargo may attach**; repaired ship rejoins as one of N. |
| repaired / normalized | recovery paths | idempotent; no duplicate ship. |

**Migration guarantees (design intent):**
- **No duplicate ship creation** — dropping `player_id UNIQUE` must be paired with an **explicit add-ship**
  entry point; the existing `commission_first_main_ship`/`ensure_main_ship_for_player` "first ship" idempotency
  is preserved so re-running never creates a 2nd ship implicitly. Adding ships is only ever an explicit action.
- **No movement corruption** — movement/presence rows are already per-ship; the migration adds **no** movement
  writes. Dropping the constraint is metadata-only.
- **No incorrect dock normalization** — `normalize_main_ship_dock` stays ship-scoped and idempotent; unchanged.
- **No accidental cargo creation** — cargo tables start **empty**; no backfill; a legacy ship simply has zero
  lots until it trades.
- **No cargo on invalid/destroyed ships** — cargo insert requires an eligible `at_location` selected ship; a
  `destroyed`/`home` ship cannot receive lots (enforced at the market write, not by migration).
- **No player lockout** — read paths must tolerate 1..N ships; the first-ship onboarding continues to work for
  new players via the deployed PORT-ENTRY flow.
- **No breakage to port-to-port gameplay** — `command_main_ship_space_move_to_location` and the send/return
  path are untouched in behavior; they only gain an explicit ship selector (defaulting, during a transition
  window, to the player's sole ship if exactly one exists — a **[C]** compatibility shim, not a permanent
  fallback).

**Risk called out:** the biggest data-integrity risk is a *partial* migration where the UNIQUE constraint is
dropped but some read/write path still assumes one row (a `where player_id` single write) — that path could then
mutate the wrong ship. Mitigation: TRADE-FLEET-0 must convert **all** §1.2 call sites in one coherent slice and
prove it with the §7 verifier before any cargo/market code lands.

---

## §6 — Affected frontend surfaces (change-timing)

**Must become multi-ship-aware BEFORE Trading:**
- ship selection state/store (new "selected ship") — feeds every market/command call.
- `mainshipApi.ts` (list fetch + ship-id on command wrappers), `useGalaxyMapData.ts` (multi-marker),
  `MainShipMarker.tsx` / `resolveMainShipMarker.ts` (N markers), `useDockServices.ts` /
  `DockServicesPanel.tsx` (per selected ship), `usePortMoveCommand.ts` / `PortNavPanel.tsx` (act on selected).

**May remain single-ship presentation TEMPORARILY (compat shim, default to sole ship):**
- `Dashboard.tsx`, `useGameState.ts`, `MainShipPanel.tsx`, `MainShipPreview.tsx` — can show the selected/only
  ship until TRADE-UI-1 adds the fleet switcher.
- Port-entry UI (`src/features/portentry/*`) — keep "Claim First Ship" for the 0-ship case; add "commission
  another ship" later; no change required for the first Trading slice beyond not blocking N ships.

**Should NOT be changed during TRADE-FLEET-0 (out of scope):**
- coordinate-travel UI (stays dark), combat/expedition wiring, `SpaceRouteLine.tsx` behavior, any flag-gated
  surface. No visual trading UI in 0 (that's TRADE-UI-1).

---

## §7 — Verifier & test implications

**Existing (identified; NOT modified):** `port-entry-1-proof.sql` one-ship asserts (`:64`);
`port-entry-1-production-verify.sql` exact-RPC-inventory + prosrc md5 (`:83-120,:13-14`) — the tripwire that any
new/re-signed ship RPC must update in the same change; `verify-phase7/8.mjs` single-ship + abstract cargo;
`verify-mainship-*.mjs`; dev commission/grant/cleanup helpers + test-user setup.

**A dedicated TRADE-FLEET verifier must prove (future):**
1. multiple ships coexist for one player (N ≥ 2 rows, distinct ids, both owner-readable);
2. movement is **independent per ship** (A moves while B stays docked; no shared state mutated);
3. a cargo lot is assigned to **exactly one** ship and unreachable via any other ship or account read;
4. capacity is enforced **by volume only (m³)** — over-volume buy rejected, no kg/mass anywhere;
5. a **docked** ship can trade while **another owned ship is in transit** (concurrency);
6. **no pooled cargo and no remote/teleport market action** is possible (account-scoped trade read/write fails
   closed; a not-docked or unowned `p_main_ship_id` is rejected);
7. **legacy one-ship accounts remain valid** (single-ship read/trade path still works);
8. buy/sell/idempotency are **per-ship** (`(main_ship_id, request_id)`), and the exact-RPC inventory equals the
   new approved set.

---

## §8 — Blockers, open decisions, slice order

### 8.1 Architectural blockers to multi-ship safety
- **None fatal.** The lock/idempotency/movement/presence substrate is already per-ship (§4). The two removals
  required are mechanical: (a) `main_ship_instances.player_id UNIQUE`; (b) the uniform `where player_id =
  v_player` ship derivation across §1.2. The chief *risk* (not blocker) is doing (a) without completing (b)
  (§5).

### 8.2 The FIVE unresolved product decisions before TRADE-FLEET-0B
1. **Entry point for acquiring additional ships** — the concrete action/surface through which a player obtains a
   2nd+ main ship (must be explicit; never implicit duplicate creation).
2. **Acquisition/progression model for additional ships** — cost/gating/pacing (ships are the intended first
   credit sink; larger/specialized hulls later), and any per-player ship cap for V1.
3. **Canonical commodity denomination & volume convention** — the fixed `m³` unit-volume per trade denomination
   (crate / pallet / tank / container / bundle…) + the starter hull `base_cargo_capacity_m3` value (replacing the
   abstract 50). Volume-only; no mass/density.
4. **Cost-basis granularity** — per-lot `unit_cost_basis` vs weighted-average per (ship, good), sufficient for
   later profit display without any mass/valuation system.
5. **Destroyed-ship cargo policy** — since loss economics are out of V1 scope, confirm cargo on a `destroyed`
   ship is simply inaccessible until repair (no loss, no transfer, no special handling).

*(Implementation-detail, not a product decision: a temporary sole-ship compatibility shim — zero-arg legacy RPCs
defaulting to the player's sole ship while `count = 1`, removed once the UI passes an explicit `main_ship_id` — is
resolved inside TRADE-FLEET-0C, §8.3.)*

### 8.3 Recommended slice order (AFTER this audit; nothing built here)
1. **TRADE-FLEET-0A** — read-only impact audit + fixed direction. ✅ (this document; design record only)
2. **TRADE-FLEET-0B** — explicit **user-approved multi-ship + volume-cargo contract**: resolve the five §8.2
   decisions and freeze the exact schema/API contract (per-ship `cargo_capacity_m3`; `trade_goods.unit_volume_m3`;
   `ship_cargo_lots` keyed by `main_ship_id`; selected-ship command signatures; the same-slice verifier-inventory
   update plan). **Design/approval only — still nothing built.**
3. **TRADE-FLEET-0C** — one **coherent implementation slice**: drop `main_ship_instances.player_id UNIQUE`; add the
   per-ship volume-cargo schema; convert **every** §1.2 `where player_id` command site to an explicit
   `p_main_ship_id` + ownership assertion **together** (the §5 safety rule — no partial migration); update the
   PORT-ENTRY production-verifier RPC inventory in the **same** slice; prove N-ship coexistence, independent
   per-ship movement, concurrency, and legacy-one-ship validity.
4. **TRADE-MARKET-1** — `market_offers`, `player_wallet`, atomic **volume-checked** buy/sell against a selected
   docked ship, `trade_receipts` per-ship idempotency.
5. **TRADE-UI-1** — ship switcher + selected-ship market/fleet UI; retire the sole-ship shim.

---

## §9 — State-change statement

**No repository state, workflow state, deployment state, flag, migration, or production data was changed.** This
audit was produced from a read-only isolated clone of `origin/main` @ `addc023` (head `0072`). The only artifacts
written are design-record docs (this file + the `DEV_LOG.md` 2026-07-02 entry + the `ROADMAP.md` Phase-10 row and
Standing-Law amendment) in that clone. PORT-ENTRY, coordinate-travel (`mainship_coordinate_travel_enabled=false`),
movement systems, and existing gameplay are untouched. **TRADE-FLEET-0 implementation has NOT begun.**
