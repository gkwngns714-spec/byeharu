# Byeharu — Port-Centric Product-Decision Packet (DRAFT)

> **DRAFT — PRODUCT DECISION PACKET. NO IMPLEMENTATION AUTHORIZATION.**
> This document is design/product only. It recommends decisions; it authorizes **nothing**.
> No code, schema, migration, seed, resolver, flag, map-behavior, or OSN-implementation change
> is proposed *active* here. The §7 "conditional future sequencing" is illustrative planning —
> it does **not** authorize implementation, migration `0064+`, resolver changes, anchor seeding,
> map work, or any flag change. A future flag enable is a **separate go/no-go gate**.

**Canonical basis (do not relitigate):** ANCHOR-2 P0-A census + PORT-CENTRIC pivot at
**PR #21 / `dc58993`**. Census ran **once** (run `28061856879`, commit `a12743f`, read-only
`REPEATABLE READ` → `ROLLBACK`): `TOTAL_SHIPS=72`, `ELIGIBLE=72`, `UNRESOLVED=0`,
one-base-per-owner invariant held, zero anomalies. **The census must not be rerun.** Its result
is used here **only** as evidence that *legacy base data is clean* — never as a reason to promote
bases into ports, homes, or anchors.

**Live baseline at this writing (unchanged):** production migrations end at **0063**
(`space_anchors` — additive, empty, dark, service-role-only). Flags:
`mainship_send_enabled=true`, `mainship_space_movement_enabled=false`. **OSN is PAUSED.**

---

## 0. Grounding — what exists today (canonical, verified against migrations)

| Object | Migration | Relevant shape | Role for ports |
| --- | --- | --- | --- |
| `locations` | 0002 | `location_type ∈ {pirate_hunt, pirate_den, mining_site, derelict_station, trade_outpost, rally_point, safe_zone, event_site}`, `activity_type ∈ {hunt_pirates, mine_resource, explore_derelict, trade_visit, rally, none}`, `status ∈ {active, locked, hidden}`, `x/y` (legacy), `is_public`, `max_presence_seconds` | The **port candidate set** (mutable type data — never a dock identity by itself). |
| `zones` / `sectors` | 0002 | static hierarchy, own `x/y` | Spatial grouping; not ports. |
| `bases` | 0005 | `player_id`→`auth.users`, `name` default `'Home Base'`, `x/y` default `0`, `status ∈ {active, destroyed}` | **Legacy bootstrap/starter/recovery record only.** Owner-read. 72 clean rows. **Never a port/home/anchor/coordinate source.** |
| `location_presence` | 0008 | `fleet_id`, `location_id`, `activity_type`, `status ∈ {active, retreating, leaving, completed, destroyed, expired}`, partial-unique **one active per fleet** | **Activity-presence projection** (today also the proto "where"). |
| `main_ship_instances` | 0043 / 0054 | `player_id` unique, `status`, `spatial_state ∈ {NULL(legacy), home, at_location, in_transit, in_space, destroyed}`, `space_x/space_y` (set IFF `in_space`) | One ship per player; the intended **canonical dock-identity owner**. |
| `space_anchors` | 0063 (dark, EMPTY) | `kind ∈ {base, location}`, `base_id`→`bases` CASCADE, `location_id`→`locations` RESTRICT, `space_x/space_y` NOT NULL finite ∈ `[-10000,10000]²`, `status ∈ {active, retired}`, one active per owner, immutable, service-role-only | The **future canonical coordinate / dockability record** for ports. Empty; not read by resolver yet. |
| `mainship_space_resolve_origin` | 0062 | `home/legacy_home/at_location/legacy_present → origin_not_anchored`; `in_space → ship space_x/y`; `in_transit → must_stop`; `destroyed → destroyed` | Today **refuses** docked/home as a movement origin until a canonical anchor exists. |
| DOCK-0 dock primitive | 0061 (dark) | location target + `status='active'` + `activity_type='none'` + **exact `x/y` match** → dock (presence + `at_location`); else terminal failure floating `in_space` | Proto docking — exact-match vs legacy `locations.x/y`; the behavior any cutover must preserve/prove against. |

**The central gap:** the resolver is truthful (legacy `x/y` are not canonical OSN positions) but
**no port has a canonical coordinate yet**, so no docked/home ship can originate a coordinate
move. Ports become real only when an explicit, enabled `space_anchors` record represents them.

---

## 1. Port eligibility — which locations can become ports, and the criteria

**Question:** Which `location_type`s may carry a dockable port, and what makes a location eligible?

### Critical distinction (load-bearing for the whole packet)

There are **two separate concepts** and they must never be collapsed:

- **Candidate-selection policy** — a *design-time filter* over mutable `locations` data used to
  decide *which locations we propose to anchor first*. This is advisory and can change.
- **Runtime dockability** — the *authoritative, server-side fact* that a ship may dock here. This
  comes **solely from an explicit, enabled, canonical `space_anchors` record representing a
  port** (`kind='location'`, `status='active'`). **A mutable `location_type` must never become a
  permanent dock identity by itself.** A location is dockable iff a live port anchor points at it.

### Options (for the candidate-selection policy only)

- **E-A — All active locations are candidates.** *Con:* would propose anchoring hostile/activity
  sites (`pirate_hunt`/`pirate_den`/`event_site`) as ports — wrong, and breaks DOCK-0's
  `activity_type='none'` rule. Rejected.
- **E-B — Whitelist + `activity_type='none'` (recommended as candidate policy).** Generation-1
  candidates = locations with `status='active'`, `activity_type='none'`, and
  `location_type ∈ {trade_outpost, safe_zone, rally_point}`. *Pro:* matches DOCK-0's proven
  predicate and the fiction; derivable from existing columns; auditable. *Con:* it is only a
  *selection filter* — it grants no dockability on its own (which is intended).
- **E-C — Explicit per-row authored port flag.** *Con:* over-engineered for an MVP; a per-row
  `space_anchors` record already *is* the explicit per-port fact. Rejected.

### Recommendation → **E-B as a generation-one CANDIDATE-SELECTION policy ONLY.**

- The whitelist `{trade_outpost, safe_zone, rally_point}` + `activity_type='none'` + `status='active'`
  defines **which locations we would propose to anchor first** — nothing more.
- **Runtime dockability is conferred exclusively by an explicit enabled canonical `space_anchors`
  record** (`kind='location'`, `status='active'`) representing that port. No anchor ⇒ not a port,
  regardless of `location_type`.
- `derelict_station` stays a deliberate later candidate (needs an explore-vs-dock mode first).
  `is_public=false` locations are out of generation-1 scope.

> Decision needed: ratify E-B as *candidate policy only*, and the rule that **port identity =
> an enabled `space_anchors` record, never a location type**.

---

## 2. Dock identity — the canonical "this ship is docked at this port" record

**Question:** What single record is the source of truth that a ship is berthed at a port?

### Options

- **D-A — `location_presence` is the dock record (status quo).** *Con:* overloads presence
  (it also models hostile activity exposure + retreat/expire lifecycle). "Docked at a safe port"
  and "exposed at a combat site" would share one table/status enum. Conflates concerns.
- **D-B — New dedicated `ship_dockings` table.** *Con:* a second "where is the ship" source that
  can diverge from `spatial_state`; unnecessary given the ship row already owns spatial truth.
- **D-C — `main_ship_instances` is canonical; presence becomes a projection (recommended).** The
  ship row is the source of truth (`spatial_state='at_location'` + a future
  `docked_anchor_id → space_anchors`). `location_presence` is a **compatibility / activity-presence
  projection** derived from / consistent with the ship's dock state — describing *activity
  exposure*, not *identity*.

### Recommendation → **D-C: the ship row is canonical for dock identity; `location_presence` is a compatibility/activity-presence projection.**

The ship row owns dock truth, but dock identity is **two distinct fields with different
lifetimes** — conflating them would break recovery, because a ship *ceases to be docked the
moment it departs*:

- **Current dock identity — `docked_anchor_id → space_anchors(id)`.** **Nullable; valid ONLY while
  the ship is actually docked.** Non-null **iff** `spatial_state='at_location'` (mirroring
  "`space_x/y` non-null iff `in_space`"). On departure it is **cleared to NULL** — a departed ship
  has no current dock. This answers "where is the ship berthed *right now*."
- **Last confirmed safe dock — `last_safe_dock_anchor_id → space_anchors(id)`.** **Retained across
  departure** (not cleared when the ship leaves). It is **updated ONLY by a successful, verified
  docking** (the same verified-dock event that sets `docked_anchor_id`), never by any other write.
  This is the field the **recovery model (§4) reads** — "the last port we can prove the ship was
  safely berthed at." A brand-new / never-docked ship has it NULL → recovery falls through to the
  shared Haven Prime (§4).
- **Recovery must NEVER infer the last dock from anything else.** Specifically it must not derive
  the last dock from `location_presence`, from movement origin/target records, from legacy base
  coordinates, or from any coordinate matching/proximity. Only an explicit successful verified
  docking updates `last_safe_dock_anchor_id`; only that field (else Haven Prime) drives recovery.
- **`location_presence` is downgraded to a compatibility / activity-presence projection** — it
  represents "present here, exposed to this activity" (DOCK-0 creates a `'none'` presence on dock),
  but it is **not** the identity of record and is **not** a recovery input.
- **Consistency obligation (explicit):** the later cutover must **preserve or prove consistency
  with existing DOCK-0 behavior before any legacy behavior is retired.** Concretely: while both
  exist, the projection must agree with the ship row (a docked ship has exactly one active `'none'`
  presence at the same port; a non-docked ship has none). DOCK-0's current settlement (presence +
  `at_location`) must be shown byte-equivalent or behavior-equivalent under the new anchor-based
  path *before* the exact-`x/y`-match path is removed. No legacy retirement without that proof.

> Decision needed: accept the ship row as canonical dock identity with **two fields** — current
> `docked_anchor_id` (nullable, cleared on departure) and retained `last_safe_dock_anchor_id`
> (updated only by verified docking, the sole recovery input) — presence as a derived projection,
> and "prove DOCK-0 consistency before retiring legacy" as a hard gate.

---

## 3. Legacy-base role — what `bases` remain responsible for (and what they must NOT be)

**Question:** With the permanent home-base plan cancelled, what is a `bases` row *for*?

### Bases REMAIN responsible for (bootstrap / starter / recovery only):

1. **Player registration / bootstrap.** `initialize_new_player()` seeding the starter base +
   starter units + starter resources stays the onboarding record.
2. **Economy container (current).** `base_resources` / `base_units` remain the reward-landing /
   unit ledger as they exist today. (No economy redesign here.)
3. **One-time starter / migration assignment input only (see §4).** Legacy base data may be read
   **only** for a *one-time* starter or migration assignment (e.g. which region a player is seeded
   into at account/migration time). **Normal repair/recovery must not read a player's legacy base
   as an operational dependency.** The base **itself** is never the recovery port or anchor, and
   recovery is driven by the last confirmed safe dock, else Haven Prime — never by the base.

### Bases are EXPLICITLY EXCLUDED from being:

- ❌ **An operational "home" you navigate to/from.** "Return home" is not ordinary movement.
- ❌ **A permanent ship origin.** No `home_base_id`, no FK/NOT-NULL/backfill binding a ship to a
  base. The cancelled P0 plan stays cancelled.
- ❌ **A port or dock target.** A base is never dockable and never gains a port anchor.
- ❌ **A canonical coordinate / anchor source.** `bases.x/y` are legacy display-only and never a
  movement origin or an anchor seed. **No `space_anchors(kind='base')` is recommended by this
  packet.** (The 0063 schema *permits* `kind='base'`, but this packet does **not** propose seeding
  any base anchor — see §4 and §5.)

### Options

- **B-A — Documentation-only (recommended).** Record the role + exclusions in
  `docs/SYSTEM_BOUNDARIES.md`; change no schema. Matches "no base column change."
- **B-B / B-C — rename/relabel or hard-deprecate base writes.** Premature schema churn on a table
  we are freezing; rejected.

### Recommendation → **B-A.** Freeze `bases` schema; document the role as *bootstrap + economy
container + one-time starter/migration assignment input*, and codify all four exclusions. Bases
never become ports, homes, anchors, coordinate sources, or operational recovery dependencies;
normal repair/recovery never reads a player's legacy base.

---

## 4. Recovery model — where repaired / destroyed / stranded ships return (anti-softlock)

**Question:** A ship can end up `destroyed`, mid-repair, or stranded `in_space` with
`origin_not_anchored` (no port to leave from). Where does it come back, and how is "you can never
be permanently stuck" guaranteed — **without** turning a base into a port/anchor?

### Failure states to cover

- `spatial_state='in_space'` with no reachable port (DOCK-0 terminal failure floats a ship at a
  destination coordinate).
- `status='destroyed'` / `spatial_state='destroyed'` (needs a respawn destination).
- `repairing` / `returning` legacy statuses needing a defined endpoint.
- A docked ship whose port flips off `active` under it.

### Recommended recovery model

A repaired or recovered ship returns, in this deterministic priority order:

1. **Last confirmed safe dock.** Return to the port recorded in the ship's
   `last_safe_dock_anchor_id` (§2) — the retained, verified-docking-only field — provided that
   anchor is still enabled/active. This is the natural, port-centric outcome and requires no base.
   The last dock is **never inferred** from `location_presence`, movement origin/target records,
   legacy base coordinates, or coordinate matching — only the explicitly recorded verified-dock
   field counts.
2. **Deterministic shared recovery haven / starter port (Haven Prime).** If `last_safe_dock_anchor_id`
   is NULL (brand-new / never-docked ship) **or** its port is unavailable (retired/inactive), the
   ship returns to a single, deterministic, always-active **shared recovery haven, Haven Prime** —
   a curated starter port that is itself an ordinary enabled `space_anchors(kind='location')` port
   at the central origin (see §6). This is the universal floor and removes any softlock.
3. **Legacy base data = one-time starter/migration assignment ONLY.** Legacy base data may inform a
   *one-time* starter or migration assignment (which region a player is seeded into at
   account/migration time). **Normal repair/recovery must NOT read a player's legacy base as an
   operational dependency.** The base is **never** the recovery port and **never** becomes an
   anchor. Every recovery destination is a real port anchor (the last confirmed safe dock, else
   Haven Prime).
4. **Recovery is an explicit anti-softlock action, never ordinary navigation.** It is a distinct
   command/path (emergency recover / respawn), not a player travel order, and it never reads legacy
   `x/y` as a coordinate.

**Anti-softlock invariant:** *every ship always has at least one valid, canonically anchored
recovery destination* — guaranteed because the shared recovery haven is a permanently-active port
anchor that any ship can fall back to regardless of history. Destroyed ships respawn at the
resolved recovery destination (HP/cooldown balance TBD, out of scope).

> Decision needed: approve "last confirmed safe dock (`last_safe_dock_anchor_id`) → else Haven
> Prime; last dock never inferred from presence/movement/legacy-base/coordinate-matching; legacy
> base data = one-time starter/migration assignment only, never an operational recovery dependency;
> recovery is explicit, never navigation." Confirm **no base anchor is seeded.**

---

## 5. Anchor-seeding scope — what is seeded first, what stays unseeded, how `space_anchors` becomes canonical without legacy `x/y`

**Question:** `space_anchors` is empty and dark. What is the *first* canonical coordinate set, and
how does it become authoritative without copying `locations.x/y` / `bases.x/y`?

### Hard rule (from the 0063 charter, non-negotiable)

`space_anchors` **must not be a backfill of `locations.x/y` or `bases.x/y`.** Anchors are
**authored canonical coordinates** in the `[-10000,10000]²` frame. Even where an authored value
coincides numerically with a legacy one, the *provenance* is "authored canonical," not "copied."

### Recommendation → seed **only** generation-1 *location* port anchors; seed **no base anchors**.

1. **Seed (gen-1):** one `space_anchors(kind='location', status='active')` per §1-candidate port in
   the §6 dense central region — including **the one shared recovery/starter haven** (§4/§6) as an
   ordinary port anchor. **Authored** canonical coordinates (never copied from `locations.x/y`).
2. **Do NOT seed:** any `space_anchors(kind='base')` (per §3/§4 — recovery never anchors a base);
   hostile/activity sites; `event_site`s; out-of-region locations; `is_public=false` locations.
   Unseeded ⇒ resolver keeps returning `origin_not_anchored` for them — correct, not a bug.

**How it becomes canonical (the cutover — conditional future work, see §7):** seed anchors (dark)
→ **verify** (anchor exists, one-active-per-owner, in-bounds, finite, count/role as designed) →
*then* extend the resolver so `at_location` resolves its origin from the ship's
`docked_anchor_id → space_anchors.space_x/y` (anchored ports only; unanchored stays
`origin_not_anchored`); legacy `x/y` never read. DOCK-0 docking migrates from exact-`x/y`-match to
"dock at the port's canonical anchor coordinate" as a **separate** step gated on the §2 consistency
proof.

> Decision needed: approve gen-1 seed = central-region candidate ports incl. the shared haven,
> **no base anchors**, authored-coordinate provenance (no `x/y` copy).

---

## 6. Initial central-region layout — concrete generation-one design (design only; no seeding)

**Fixed constraints (from the pivot, non-negotiable):** boundary stays **≈ `[-10000,10000]²`** (a
temporary technical frontier, **no expansion authorized now**); growth is **outward-only** and
**preserves all existing coordinates** (never remap/move/renumber an existing port, anchor, ship,
or player); keep the **core dense**, reserve outer space for later.

### Recommended generation-one layout (one concrete proposal — design only)

**A dense central core of 5 ports inside an envelope of ≈ `[-2000, 2000]²` around the origin,
with one of them designated the shared recovery/starter haven.** Coordinates below are an authored
*sketch* (canonical-frame, not copied from any legacy `x/y`) to make the shape concrete; exact
values are a tunable to confirm at decision time.

| # | Proposed port | `location_type` candidate | Role | Sketch coord (authored) |
| --- | --- | --- | --- | --- |
| 1 | **Haven Prime** | `safe_zone` | **Shared recovery / starter haven** — always active; universal recovery floor (§4); new-player start. | `(0, 0)` — center |
| 2 | **North Exchange** | `trade_outpost` | Trade/commerce hub | `(0, 1500)` |
| 3 | **East Exchange** | `trade_outpost` | Second trade node (gives the core a route, not a single dot) | `(1500, 0)` |
| 4 | **South Muster** | `rally_point` | Staging / rally before outward expeditions | `(0, -1500)` |
| 5 | **West Muster** | `rally_point` | Second staging node, opposite side | `(-1500, 0)` |

```
                North Exchange (0,1500)
                        |
 West Muster ---- Haven Prime ---- East Exchange
  (-1500,0)        (0,0)            (1500,0)
                        |
                South Muster (0,-1500)
        core envelope ≈ [-2000,2000]^2   (frontier ≈ [-10000,10000]^2)
```

- **One shared recovery/starter haven** = **Haven Prime** at the origin: a single deterministic
  fallback for §4, kept permanently active.
- **Why 5 / this shape:** small enough to seed and verify in one generation; a plus-shaped spread
  gives short, legible early travel (≤ ~2121 units corner-to-center) and an obvious dense core,
  while leaving the entire outer annulus (`> ±2000` out to `±10000`) reserved.
- **Outward-only expansion rule (codified):** later content is authored at **strictly larger
  radii**, monotonically outward; **no existing anchor coordinate is ever changed** (the 0063
  per-row immutability guard already enforces this; world growth only *adds* anchors, never
  relocates them). The `[-10000,10000]²` frontier widens only by a future, separately-authorized
  decision — **not now**.

**This section is design only. No anchor, port, or coordinate is seeded by this packet.**

> Decision needed: confirm 5-port dense plus-core, Haven Prime as the shared haven, the
> ≈ `[-2000,2000]²` envelope (and whether the sketch coords are the starting proposal), and ratify
> outward-only / never-remap as a standing rule.

---

## 7. Recommendation — proposed canonical model + conditional future sequencing

### Proposed canonical model (one line each)

1. **Ports** — runtime dockability = an explicit enabled canonical `space_anchors(kind='location')`
   record; the `{trade_outpost, safe_zone, rally_point}` + `activity_type='none'` whitelist is a
   **gen-1 candidate-selection policy only** (E-B). A mutable `location_type` is never a dock
   identity by itself.
2. **Dock identity of record** — `main_ship_instances` owns two fields: current
   `docked_anchor_id` (nullable, non-null IFF `at_location`, **cleared on departure**) and
   `last_safe_dock_anchor_id` (**retained**, updated **only** by verified docking, the sole
   recovery input); `location_presence` is a **compatibility/activity-presence projection**; DOCK-0
   consistency must be proven before any legacy retirement (D-C).
3. **Bases** — bootstrap + economy container + **one-time** starter/migration assignment input
   **only**; never a home, port, anchor, coordinate source, or operational recovery dependency (B-A).
4. **Recovery** — last confirmed safe dock (`last_safe_dock_anchor_id`) → else **Haven Prime**;
   last dock **never inferred** from presence/movement/legacy-base/coordinate-matching; base data =
   one-time starter/migration only; explicit anti-softlock action, never navigation; **no base
   anchor** (§4).
5. **Seeding** — gen-1 = central-region candidate ports incl. the shared haven, **authored** coords,
   **no base anchors**; everything else unseeded; legacy `x/y` never copied (S-B).
6. **Layout** — dense 5-port plus-core in ≈ `[-2000,2000]²` with Haven Prime at origin;
   outward-only, never-remap; frontier `[-10000,10000]²` unchanged (L-A).

### Conditional future sequencing — **illustrative planning only; authorizes nothing**

> **The table below is NOT an authorization.** It does not authorize implementation, any
> migration `0064+`, resolver changes, anchor seeding, map work, or any flag change. Each step
> would require its own explicit approval; a future flag enable is a **separate go/no-go gate**.
> Listing a step here does not start it.

| # | Step (conditional) | Nature | Would gate on |
| --- | --- | --- | --- |
| **S0** | Record decisions in `docs/SYSTEM_BOUNDARIES.md` + `DEV_LOG.md`. | docs only | approval of this packet |
| **S1** | Eligibility/candidate helper (read-only) enumerating candidate ports from existing columns. | additive, read-only | S0 |
| **S2** | Additive dark dock-identity fields on `main_ship_instances`: current `docked_anchor_id → space_anchors` (non-null IFF `at_location`, cleared on departure) + retained `last_safe_dock_anchor_id → space_anchors` (set only by verified docking); no backfill/writer. | additive schema | S1 |
| **S3** | Seed gen-1 *location* port anchors (incl. shared haven), authored coords, **no base anchors**; verify on disposable chain. | seed (dark) | S2 + explicit seed approval |
| **S4** | Resolver extension: `at_location` resolves origin from `docked_anchor_id` anchor (anchored ports only). | resolver replace | S3 verified |
| **S5** | DOCK-0 cutover to dock at canonical anchor coord; **prove consistency with current DOCK-0 before retiring exact-`x/y` path**. | docking primitive | S4 + §2 consistency proof |
| **S6** | Explicit recovery path: `last_safe_dock_anchor_id` → else Haven Prime; reads only the verified-dock field (never presence/movement/legacy-base/coords); enforces anti-softlock; never navigation. | additive RPC | S5 |
| **S7** | **Enablement** — flip `mainship_space_movement_enabled` only after S1–S6 verified green and a recorded go/no-go. | flag flip | **separate go/no-go gate** |

**Explicitly NOT authorized by this packet:** any flag flip, any migration `0064+`, any resolver
change, any anchor seeding, any map/boundary change, mass anchoring beyond gen-1, any base anchor,
economy/buildings/training work, respawn balance, and **rerunning the census**.

---

*DRAFT packet — design/product only, no implementation authorization. Approve the §7 model (or
amend per section) to make S0 (and only then, step-by-step with their own gates) eligible for
future authorization. Until then the baseline holds: migrations end at 0063, both flags as-is,
OSN paused.*
