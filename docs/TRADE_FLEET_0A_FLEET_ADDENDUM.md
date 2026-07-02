# TRADE-FLEET-0A-FLEET — Fleet-Group Addendum Audit (READ-ONLY)

> Recorded 2026-07-02. **Read-only addendum. Nothing implemented.** No branch beyond a docs branch, no PR
> merge, no code, schema, migration, seed, test, workflow, flag, production verification, deployment, or
> production interaction. Baseline: `origin/main` @ `f48bc539` (PR #66 merged), migration head **`0072`**.
>
> **Companion to — does not replace —** [`TRADE_FLEET_0A_IMPACT_AUDIT.md`](TRADE_FLEET_0A_IMPACT_AUDIT.md).
> That audit is preserved verbatim; this addendum records exactly which of its findings remain valid and which
> are superseded by the new fleet-group direction.
>
> **New authoritative direction (2026-07-02):** the **strategic movement / docking / location / activity owner
> is a FLEET GROUP** (≈6–8 main ships that travel, arrive, dock, and enter activities **together** and share one
> location + activity state), **not** an individual ship. This supersedes **only** the 0A assumption that several
> owned ships move/trade independently. Cargo stays **ship-bound, volume-only (`m³`)**; per-ship hull/stats/
> skills/captains/cargo remain meaningful; additional ships are **built from activity rewards, not bought**.

---

## §0 — Headline finding: the legacy `fleets` table is a hard naming + role collision

`public.fleets` (migration `20260616000006_fleet_system.sql`) **already exists** and is the game's
**movement / presence / location carrier**:
- Columns `status` (idle/moving/present/returning/completed/destroyed), `location_mode`
  (base/movement/location/destroyed), `current_base_id`, `current_sector/zone/location_id`,
  `active_movement_id` — i.e. **`fleets` already owns exactly the strategic state the new "fleet group" is meant
  to own** (where a thing is, whether it's moving/docked).
- It is the sole writer-owned movement record (SYSTEM_BOUNDARIES: "sole writer of fleets / fleet_units";
  Movement/Presence/Combat mutate it only via SECURITY DEFINER state-machine functions).
- The main ship links to it via `fleets.main_ship_id` (index `fleets_main_ship_id_idx`, migration
  `20260618000050`; **not unique**). A main-ship's linked fleet **carries zero `fleet_units`** — it exists purely
  to carry movement/presence/location and to be addressed by fleet id (`request_main_ship_return(p_fleet)`,
  `move_main_ship_to_location(p_fleet,…)`).
- `fleet_units` (unit-stack quantities) is the **legacy pre-main-ship combat** shape; main-ship fleets never
  use it.

**Collision:** the new "fleet group" is a *different* concept — a **persistent group of several main ships** —
but it wants the **same name** and the **same role** (movement/location owner) as the existing per-ship `fleets`
row. Overloading `public.fleets` for both would be spaghetti (a `fleets` row would ambiguously mean "one ship's
movement record" **and** "a group of ships"). **The ROADMAP already flags `fleets` as a legacy misnomer**
("Don't rename backend tables yet — `fleet_id` → conceptually `expedition_id` later").

**Design consequence (boundary, not implementation):** introduce a **new, distinctly-named** persistent identity
for the group — e.g. `fleet_groups` (working name; final name is a 0B decision, candidates: `fleet_groups` /
`squadrons` / `expeditions`) — and **do not overload `public.fleets`.** The cleanest target is that the group
becomes the movement/presence/location owner and the legacy per-ship `fleets` row is either (a) subsumed as the
group's single movement record, or (b) retired in favor of a group-owned movement record — **which of (a)/(b) is
a 0B decision.** Per the never-spaghetti rule, whichever is chosen must fully replace the old role, leaving no
dual-owner ambiguity.

---

## §1 — 0A findings: still valid vs superseded

### Still valid (carry forward unchanged)
- **One-ship constraints are real blockers:** `main_ship_instances.player_id UNIQUE` + `on conflict do nothing`;
  the uniform implicit `where player_id = v_player` ship derivation across command RPCs (0A §1.1, §1.2).
- **Locking / idempotency / movement / presence substrate is already ship-scoped:**
  `mainship_space_lock_context(main_ship_id)` locks by ship with **no advisory / no player-level lock**
  (`20260618000056:13,38-69`); idempotency keyed `(main_ship_id, request_id)` (`20260618000060:35`,
  `20260618000055:128`). This remains true and is *helpful* — per-ship locks **compose under a group lock**.
- **Cargo is ship-bound and volume-only (`m³`)** — unchanged and reinforced (§4 below). No abstract units, no kg/
  mass/density/dual-cap. No pooled/account cargo, no remote/teleport trades.
- **PORT-ENTRY verifier freezes the exact authenticated-RPC inventory** — still the tripwire; any group-scoped or
  ship-parameterized RPC must update it in the **same** slice (0A §7).
- **Partial-migration wrong-ship risk + "one coherent slice"** — still the chief risk; now extended to
  wrong-**group** mutation (§7 below).

### Superseded by fleet-group movement
- **0A §4 "concurrent independent per-ship movement"** — the example *"Ship A docked at Haven Reach trading while
  Ship B travels toward Slagworks"* is **explicitly reversed**: ships in the **same active fleet group** move,
  arrive, dock, and enter activities **together** and share one location/activity state. Concurrency (if any) now
  lives at the **fleet-group** level, and **whether a player may run multiple independently-moving fleet groups is
  an open 0B decision** (do **not** assume it).
- **0A "explicit ship selection on every ship-scoped command"** — refined: **movement/docking/activity** commands
  now target a **fleet group**; only **cargo/market-loading** targets a specific ship (or is deterministically
  allocated across the group's holds — a 0B decision, §4). The "selected ship" concept splits into
  **selected fleet group** (strategic) + **selected/target ship** (cargo).

---

## §2 — Surface-by-surface effect of moving the strategic owner ship → group

Classification: **[M]** mandatory foundation · **[C]** compatibility-sensitive · **[D]** deferred capability ·
**[N]** not affected.

### 2.1 Database / backend
| Surface | File | Effect | Class |
|---|---|---|---|
| Legacy `fleets` / `fleet_units` / `fleet_create` / `send_fleet_to_location` | `20260616000006_fleet_system.sql` | Name+role collision (§0). New group identity must not overload `fleets`; the movement-owner role migrates to the group. | **[M]** |
| `fleets.main_ship_id` (non-unique index) | `20260618000050:42` | Today 1 active movement-fleet per ship. Under groups, movement/presence is **one per group**; member ships map to the group, not each to their own moving `fleets` row. | **[M]** |
| `main_ship_instances.spatial_state` / `space_x/y` (per-ship) | `20260618000054` | Per-ship position/state becomes **derived from / subordinate to** the group's position; independent per-ship `in_space` coordinates conflict with "travel together". Group holds the authoritative position; ship state mirrors membership. | **[M]** |
| Movement begin/arrival/stop processors (`mainship_space_begin_move`, arrival, `command_main_ship_space_stop`) | `20260618000056/57/59/64` | Must operate on the **group** (one depart/one arrival/one stop for all members) rather than per ship. | **[M]** |
| Presence (`location_presence`, `presence_create`) | `20260616000008` | One **group** presence at the docked location; member ships derive presence from the group (not one presence row per ship). | **[M]** |
| Port/location state, dock services (`get_my_current_dock_services`) | `20260618000069` | Resolve the docked **group** → its port → services; "which ship" only matters for cargo. | **[C]** |
| Repair / destruction / recovery (`repair_main_ship`, destruction paths) | `20260618000052/59` | Remain **per-ship** (a ship is damaged/destroyed, not the group), but must interact with group membership (a destroyed member stays with the group or is detached — 0B). | **[C]** |
| PORT-ENTRY commission / normalize | `20260618000072` | First ship must be wrapped in a **singleton fleet group** (§6). Commission creates ship + group(1) + one group movement/presence. | **[M]** |
| Command receipts / idempotency | `20260618000055/60` | **Movement/activity** receipts move to **group scope**; **cargo/market** receipts stay **per-ship**. | **[M]** |
| Cargo (ship-bound, volume-only) | *new in 0C* | **Unchanged** design: per-`main_ship_id` holds; fleet total is a derived read. | **[N]** (valid) |

### 2.2 Frontend
| Surface | File | Effect | Class |
|---|---|---|---|
| Galaxy Map / markers / route | `useGalaxyMapData.ts`, `MainShipMarker.tsx`, `resolveMainShipMarker.ts`, `SpaceRouteLine.tsx` | One **group marker/route** (ships travel together), not N independent markers. | **[M]** |
| Port travel / move / stop controls | `usePortMoveCommand.ts`, `PortNavPanel.tsx`, `useSpaceMoveCommand.ts`, `useSpaceStopCommand.ts`, `mainshipApi.ts` command wrappers | Act on the **selected group**; send group id, not per-ship id. | **[M]** |
| Dock services panel | `useDockServices.ts`, `DockServicesPanel.tsx` | Shows the **group's** dock + services; per-ship only for cargo. | **[C]** |
| Dashboard / ship status / Command Center | `Dashboard.tsx`, `useGameState.ts`, `MainShipPanel.tsx`, `MainShipPreview.tsx`, `MainShipCommand.tsx` | Group summary + per-ship roster (hull/stats/skills/captains/cargo). Fleet total = derived. | **[C]** |
| PORT-ENTRY UI | `src/features/portentry/*` | Keep "Claim First Ship"; the claimed ship is a **group of one**. | **[C]** |
| Selection state | (new store) | Split into **selected fleet group** (strategic) + **target ship** (cargo). | **[M]** |
| Cargo/market UI | *new in TRADE-UI-1* | Fleet cargo aggregate derived from per-ship holds; loading interaction is a 0B decision (§4). | **[D]** |

### 2.3 Tests / verifiers / fixtures
| Surface | File | Effect | Class |
|---|---|---|---|
| PORT-ENTRY realchain proof (one-ship asserts) | `scripts/port-entry-1-proof.sql:39,64` | `n=1` ship asserts must accommodate a singleton **group**; new assert: exactly one group per commissioned player. | **[M]** |
| PORT-ENTRY prod verifier — exact RPC inventory + prosrc md5 | `scripts/port-entry-1-production-verify.sql:13-14,83-120` | Group-scoped movement RPCs change the frozen inventory → same-slice update. | **[M]** |
| Phase-7/8 verifiers | `scripts/verify-phase7.mjs`, `verify-phase8.mjs` | Single-ship + abstract cargo shape → re-baselined for groups + volume cargo. | **[C]** |
| mainship send/move/repair/preview verifiers, dev commission/grant/cleanup, test users | `scripts/verify-mainship-*.mjs`, `dev-*`, `20260617000029_dev_reset_player.sql` | Assume one ship / per-ship movement / one test user = one ship → group-aware. | **[C]** |

---

## §3 — Lock order & transaction discipline (fleet group → members → movement → cargo)

- **Canonical acquisition order (proposed):** `fleet_group` row → member `main_ship_instances` **in a
  deterministic order** (e.g. ascending `main_ship_id`, or formation order) → group movement record → per-ship
  cargo holds. A single fixed order across every writer prevents deadlock between two operations touching
  overlapping groups/ships.
- The existing per-ship `mainship_space_lock_context(main_ship_id)` (no advisory/player lock) **composes**: a
  group lock is "lock the group, then each member via the existing per-ship path in id order." No global player
  lock is introduced.
- **Movement/activity** transactions lock the **group + all members** (they act together); **cargo/market**
  transactions lock the **group (share) + the one target ship (update)** so a cargo write on ship X doesn't block
  a cargo write on ship Y in the same docked group unnecessarily — but both still validate the group is docked.
- **Idempotency scope:** movement/arrival/stop/activity receipts key on `(fleet_group_id, request_id)`; cargo/
  market receipts key on `(main_ship_id, request_id)` (unchanged from 0A). This split keeps a group move
  idempotent while preserving per-ship trade idempotency.

---

## §4 — Cargo (unchanged design) + fleet aggregate (derived only)

Fixed and carried forward from 0A: cargo is **physically per-ship**, **volume-only (`m³`)**, moves only because
its ship moves **with its group**; **no** abstract units / kg / mass / density / dual-cap; **no** account/pooled
cargo, remote sell/buy, or teleportation.

A **fleet-level cargo aggregate is a READ MODEL derived from individual holds only** — never a stored pooled
balance:
```
Fleet cargo: 142.0 m³ / 190.0 m³
  Ship A: 22.0 / 30.0 m³
  Ship B: 18.0 / 25.0 m³
  Ship C: 42.0 / 50.0 m³
```
`fleet_total_used = Σ ship.used`, `fleet_total_cap = Σ ship.cap`, computed at read time; the per-ship hold is the
source of truth.

**Market loading/selling allocation — ANALYZED, NOT CHOSEN (0B decision):**
1. **Explicit target ship** — player picks the receiving/selling ship; server validates that ship's `m³`.
2. **Fleet-level + server allocation** — player transacts at fleet level; server deterministically distributes
   across valid holds (needs a documented, stable allocation rule + capacity-exceeded semantics).
3. **Fleet-level + confirmed plan** — player selects a fleet transaction and confirms an explicit per-ship
   allocation plan before commit.
Trade-offs: (1) simplest, most predictable, least UI; (2) fewest clicks but hides allocation + needs a
tie-break/rounding rule; (3) most control but most UI + a two-step commit. **No recommendation is treated as
approved.**

---

## §5 — Minimum safe design boundary (proposal only; no schema/code)

- **Persistent fleet-group identity** — `fleet_groups(fleet_group_id pk, player_id fk, name, status, created_at)`
  where `status` carries the **strategic** state (idle/moving/present/…); **distinct table, not `public.fleets`.**
- **Fleet membership** — `fleet_group_members(fleet_group_id, main_ship_id unique, formation_order,
  membership_state)` with `main_ship_id` unique **globally** (a ship belongs to at most one group at a time).
- **Leader / formation order** — `formation_order` (and/or a `leader_main_ship_id`) **only if** needed for
  speed/label/marker; keep optional until a 0B rule requires it.
- **Active vs inactive membership** — `membership_state` (active / reserve / detached) so a damaged/destroyed or
  under-construction ship can be a member without contributing to movement/activity.
- **Fleet-level movement/docking/location/activity state** — owned by `fleet_groups` (one movement record, one
  presence, one dock) — the role migrated off the per-ship `fleets` row (§0).
- **Per-ship contribution** — hull/stats/ship-skills/cargo(`m³`)/captain-assignments stay on the ship; the
  fleet's ability is an **aggregate read** over members (formulas are 0B, §3 of the packet).
- **Read models** — `get_my_fleet_group()` (group + members + derived totals) and per-ship reads; fleet totals
  are always derived, never stored authoritative.
- **Safe lock order** — §3.
- **Fleet-level command receipts** — §3 (movement/activity group-scoped; cargo per-ship).
- **PORT-ENTRY compatibility** — §6.

---

## §6 — Compatibility: existing one-ship accounts → one-ship fleet groups

Every existing/PORT-ENTRY account has exactly one ship today. The migration wraps each such ship in a
**singleton fleet group** with **zero disruption**:
- **No relocation / no dock change** — the group inherits the ship's *current* `fleets` movement/presence/location
  as-is; the ship does not move, re-dock, or change `spatial_state`.
- **No duplicate ships / no accidental group** — creation is idempotent and derived from the existing ship
  (one ship ⇒ exactly one group of size 1); re-running never makes a second ship or a second group.
- **No movement corruption** — the group adopts the ship's existing movement record; no new movement is written by
  the wrap.
- **No incorrect dock normalization** — `normalize_main_ship_dock` stays ship-scoped and idempotent; the group
  reflects the normalized state.
- **PORT-ENTRY onboarding** — a new player's "Claim First Ship" produces ship + singleton group + one group
  presence at Haven Reach (the current commission flow, extended to also create the group). Home / legacy_home /
  legacy_present / at_location / in_transit / in_space / destroyed all map into a size-1 group without special
  cases beyond the state they already carry.
- **No player lockout** — reads tolerate a group of size 1..N; the first-ship flow is unchanged for the player.

---

## §7 — Blockers, risks, and the coherent-slice rule (extended)

- **No new architectural blocker.** The substrate is per-ship and composable; the group is an additive owning
  layer above it. The two 0A removals (UNIQUE + `where player_id` derivation) still apply, now feeding a group.
- **Chief risk (extended):** a partial migration that leaves **any** `where player_id`-derived single-ship
  movement/presence write, **or** any code path that still treats the per-ship `fleets` row as the movement owner,
  could mutate the **wrong ship or desynchronize a group** (a member moving independently of its group). ⇒ the
  **movement-owner migration (ship→group) + all command-site conversions must land in ONE coherent slice**
  (TRADE-FLEET-0C), with the verifier RPC-inventory updated in the same slice.
- **Naming discipline:** do not overload `public.fleets`; introduce the distinct group identity (§0) so no row
  ever means two things.

---

## §8 — State-change statement
No repository state (beyond a docs branch + this addendum + DEV_LOG/ROADMAP edits), workflow, deployment, flag,
migration, or production data was changed. Produced from a read-only isolated clone of `origin/main` @ `f48bc539`
(head `0072`). The preserved `TRADE_FLEET_0A_IMPACT_AUDIT.md` was **not** modified. Coordinate travel stays dark.
**No TRADE-FLEET-0B or 0C implementation has begun.**
