# Byeharu — F2 Compatibility / Model Decision Packet (APPROVED COMPATIBILITY / WORLD-MODEL ARCHITECTURE)

> **APPROVED COMPATIBILITY / WORLD-MODEL ARCHITECTURE — NO IMPLEMENTATION AUTHORIZATION.**
> This document **records the APPROVED compatibility / world-model architecture direction** for
> Byeharu (Decision Ledger, §1). It authorizes **no implementation** (see §6). **This decision does
> not authorize implementation, including migrations, schema changes, `world_sites` or bridge
> creation, anchor seeding, resolver or DOCK-0 changes, OSN behavior changes, dock/recovery fields,
> capability or geographic-zone systems, pirate/encounter behavior, map changes, coordinate-bound
> changes, flag changes, census reruns, or changes to the protected dirty checkout.** OSN remains
> **paused**. The post-F2 sequence (§7) is conditional and illustrative; the five listed product
> decisions (§5) remain **open**.

**Evidence base:** the APPROVED architecture packet on `main`
(`docs/PORTCENTRIC_DECISION_PACKET.md`, PR #22 / `bd927f3`) + the completed **F1 World Model
Recon** (read-only, baseline `bd927f3`). F1 is not repeated here; its `path:line` evidence is cited
where a compatibility claim depends on it.

**Live baseline (unchanged):** migration head **`0063`**; flags `mainship_send_enabled='true'`,
`mainship_space_movement_enabled='false'`; `space_anchors` empty/dark; OSN paused.

**Purpose:** decide the *compatibility model* — how Byeharu evolves into a modular world-content
system **without breaking** existing `locations`, combat, reports, movement, DOCK-0, or player
history, and **without turning `locations` into a permanent dumping ground** for ports, pirates,
mining, exploration, zones, lifecycle, and future systems.

---

## 1. Decision summary

| # | F2 decision | Recommended model (this packet) | Status |
| --- | --- | --- | --- |
| F2-1 | World-object identity | **Option C** — additive canonical world-site identity layer (working name `world_sites`) + immutable legacy bridge; new responsibilities attach to the new layer, `locations.id` stays as compatibility key | ✅ **APPROVED architecture direction** |
| F2-1A | Transitional / authority / activity / port boundaries | Bridge cardinality (per-direction 1:1 for bridged rows; unbridged only while draft/hidden, no active anchor, no live reference); `world_sites` owns new-layer truth while `locations` stays operationally authoritative during transition; no dual-write; capabilities never auto-collapse to one `activity_type`; one active dock anchor per port, anchor≠port, identity never inferred | ✅ **Binding APPROVED direction** |
| F2-2 | Anchors | Keep `space_anchors` **closed `{base,location}`**, **location-backed anchors only**, **no base anchors** | ✅ **APPROVED initial transitional constraint** (later generalization separately gated) |
| F2-3 | Port capability | **Port-first** explicit capability on a canonical location anchor; never inferred | ✅ **APPROVED direction** (legacy `activity_type` remains runtime truth during transition) |
| F2-4 | Geographic zones | **New separate layer**, not `zone_state`/`location_state`; pirate interception via an adapter **outside OSN** | ✅ **APPROVED architecture direction** (geometry/crossing impl deferred) |
| F2-5 | Docking transition | **Dual-path + shadow verification**; DOCK-0 intact; future `docked_anchor_id` nullable + **asymmetric**; presence stays a projection | ✅ **APPROVED transition strategy** (no implementation or cutover authorized) |
| F2-6 | Recovery | **Ship-row-held** `last_safe_dock_anchor_id` + **Haven Prime fallback**; verified-dock-only; never inferred/backfilled | ✅ **APPROVED recovery direction** (no schema/implementation authorized) |
| F2-7 | Lifecycle | Mandatory safety rules over `draft/active/hidden/retired/archived` | ✅ **APPROVED safety direction** (final vocabulary + port evacuation/diversion policy remain OPEN) |
| F2-8 | Coordinate range | **Defer** envelope enlargement to the separate World-Range Recon; **±10000 unchanged** | ✅ **APPROVED deferral** (frontier unchanged pending World-Range Recon) |

The centerpiece is **F2-1**. Its corrected framing (Option C) is what keeps every other decision
additive and prevents both a big-bang FK rewrite **and** future capability/lifecycle spaghetti. The
**five product decisions in §5 remain OPEN.**

---

## 2. Options and recommendation for each F2 decision

### F2-1 — World-object identity (the centerpiece)

**Problem (from F1):** identity, coordinate, classification (`location_type`), activity
(`activity_type`), and economy are all **fused in one `locations` row**
(`world_map.sql:48-72`), mirrored in one `MapLocation` (`mapTypes.ts:22-34`). `locations.id` is the
de-facto identity, referenced by ~8 FK consumers (fleets, fleet_movements, location_presence,
combat_encounters, **combat_reports**, location_state, space_anchors, space-movements). Continuing
to bolt ports/pirate/mining/exploration/zones/lifecycle onto this single row is the spaghetti the
architecture forbids.

**Option A — Legacy-location-centered transition.** `locations.id` stays the canonical identity and
new feature responsibilities are added *as columns/flags on `locations`* (or satellite tables keyed
directly to `locations.id`). *Pro:* zero new identity layer, smallest first step. *Con:* directly
violates the product goal — `locations` becomes the permanent universal world-content table; every
new capability/lifecycle/zone responsibility fuses back into it; the very dumping-ground outcome to
avoid. **Rejected.**

**Option B — Immediate full world-object replacement.** Introduce a universal `world_objects` table
*now* and re-point every existing FK (fleets, movements, presence, combat, reports, anchors) to it
in one migration. *Pro:* cleanest end-state, single identity everywhere. *Con:* a **big-bang FK
rewrite** across the entire runtime + history surface — high blast radius, must preserve historical
`combat_reports.location_id` (NO ACTION, `report_system.sql:11`) and the `space_anchors.location_id`
RESTRICT (`0063:33`), and risks breaking combat/presence/movement in the first slice. F1 flags this
as the maximal-hazard path. **Rejected for the first transition.**

**Option C — Additive canonical world-site layer + 1:1 legacy bridge (RECOMMENDED).**
Introduce a **new canonical stable identity layer for point-like world content** — working name
`world_sites` (or `world_objects`; *final name and schema NOT locked here*). In the **first
transition slice** it is deliberately **minimal**: a stable ID + a **strict one-to-one immutable
bridge** to existing `locations`, plus the **attach points** for new architecture. Specifically:

- **Bridge contract:** each existing `locations` row maps to exactly **one** `world_sites` identity;
  the mapping is **unique, immutable after assignment, and the only approved identity-translation
  boundary.** No ad-hoc translation through names, coordinates, `activity_type`, or frontend logic.
- **What stays on `locations`:** all existing FK consumers continue to use `locations.id`
  unchanged; `activity_type` remains the runtime combat/presence switch (F2-3). `locations` becomes
  a **legacy compatibility / activity projection** — **no new feature-specific columns**, not the
  permanent universal table.
- **What attaches to `world_sites`:** canonical placement/anchors (F2-2), composable capabilities
  incl. future port identity (F2-3), lifecycle (F2-7), and future exploration/mining/pirate/trade/
  anomaly/event content — **none of which touch `locations`.**
- **Not a universal layer yet:** `world_sites` in slice 1 is the identity + bridge + attach point
  only. It does **not** absorb combat/presence/movement and does **not** trigger any FK rewrite.

**Precise trigger to broaden `world_sites` into a fuller/universal world-object model later:** when a
meaningful world object **cannot honestly be modeled as a location-or-anchored-site** without
breaking ownership, lifecycle, or history rules — e.g. a non-point region-owned object, an object
with no legacy-location ancestry, or one whose lifecycle/ownership can't be expressed through the
bridge. Until that trigger, the universal generalization stays deferred.

**Why C prevents a big-bang FK rewrite *and* future spaghetti:**
- *No big-bang rewrite:* existing FKs keep pointing at `locations.id`; the bridge is additive and
  read-through. Nothing in fleets/movements/presence/combat/reports/anchors changes in slice 1.
- *No future spaghetti:* every NEW responsibility is forced onto `world_sites`, never onto
  `locations`. `locations` is frozen as a legacy projection (no new feature columns), so it cannot
  grow into the universal dumping ground. Capabilities and lifecycle compose on the new identity
  with one translation boundary, so adding/transforming/hiding/retiring content does not ripple
  into unrelated location consumers.

**Material-objection check (per instruction "unless F1 reveals a material compatibility hazard"):**
F1 reveals **no** blocking hazard for Option C. Supporting points: `locations.id` is a stable UUID
(`world_map.sql:49`); the static-identity↔dynamic-state split already exists as precedent
(`location_state`/`zone_state` keyed to ids); `space_anchors` is dark and additively seedable; no
SQL reads `location_type` (so capability attachment doesn't disturb server logic). The only items to
respect (not blockers) are the **historical/RESTRICT FKs** and the **base-CASCADE vs
location-RESTRICT asymmetry** on anchors — handled by keeping `locations` and its FKs untouched in
slice 1.

> **F2-1 decision requested:** approve **Option C** (additive `world_sites` identity + 1:1 immutable
> bridge; `locations` frozen as legacy projection), with the universal-layer trigger as stated.

---

### F2-1A — Transitional compatibility & authority boundaries (Option C, approved in principle)

Option C is approved in principle. The following narrow boundaries are **binding direction**. Their
purpose is single and specific: prevent the new `world_sites` layer from being **quietly forced back
into `locations`** simply because the deployed `space_anchors` currently support only typed owners
`{base, location}`. They do **not** change the architecture goal and authorize no implementation.

**Transitional boundary**
1. `world_sites` is the future canonical stable identity for **point-like authored world content
   only.** It does **not** replace zones, and **void space requires no `world_site`.**
2. **Bridge cardinality (precise — replaces any "exactly one each" phrasing):**
   - Every existing legacy `locations` row has **exactly one** immutable bridge to **one**
     `world_site`.
   - Every **location-backed** `world_site` has **exactly one** immutable bridge to **one** legacy
     `location`.
   - A `world_site` may be **unbridged only while** it is `draft` or `hidden`, has **no active
     anchor**, and is **not referenced by any live** map, movement, docking, legacy activity,
     combat, presence, report, or other current runtime path.
   - An **unbridged `world_site` cannot become active runtime content** until a separately approved
     **anchor-generalization and compatibility decision** exists.
3. In the first compatibility transition, **any `world_site` that is active** in the existing map,
   movement, docking, legacy activity, or current anchor infrastructure **must be location-backed
   through its bridge.**
4. During that first transition, **canonical placement for such sites remains a
   `space_anchors(kind='location')` record.** New ports are therefore **location-backed world sites
   with explicit port capability and an active location anchor.**
5. Active **independent** (non-location-backed) world sites are **not supported by the currently
   deployed anchor schema** and must not be implied to be; such sites may exist **only** as
   `draft`/`hidden` design content until the separately approved anchor-generalization decision.
6. This bridge is a **temporary compatibility adapter**, **not** a permanent requirement that all
   future world content must live in `locations`.

**Authority boundary (transition)**
- **`world_sites` owns** new-layer stable identity, lifecycle, and composable capability **truth.**
- **During the first transition, `locations` remains *operationally authoritative*** for existing
  legacy status, `activity_type`, coordinates, and current runtime consumers (fleet, movement,
  presence, combat, report, legacy-map) **until a later, explicitly approved, server-owned
  projection or cutover.** `world_sites` owning new-layer truth does **not** transfer operational
  authority over legacy runtime away from `locations` yet.
- **New-layer lifecycle/capability state must not automatically alter legacy runtime behavior.**
- **Legacy `locations.x/y` remains compatibility input for old paths only** — it is **not** the
  long-term identity relationship.
- **No client, frontend component, or feature subsystem may dual-write or independently synchronize
  these layers.** Any bridge/projection synchronization must be **server-owned and explicitly
  defined later.**
- **"Freeze `locations`" means** no new world-feature semantics and no permanent feature columns; it
  does **not** prohibit future safety, bug-fix, or compatibility maintenance.

**Activity boundary**
- New capabilities **must never automatically collapse into one legacy `activity_type`.**
- During transition, any mapping from a new capability to legacy activity behavior is **explicit,
  server-owned, and limited to the particular legacy path being supported.**
- A **multi-capability world site must not be forced to pretend it has one permanent universal
  activity type** merely to satisfy future architecture.

**Port cardinality (product/invariant requirement; final schema not chosen here)**
- A **dockable-port capability has one canonical active dock anchor at a time.**
- An **active anchor is not automatically a port.**
- **Port identity is never inferred** from coordinates, legacy location type, activity type, display
  name, or base identity.

> **F2-1A recorded** as binding direction under the approved-in-principle Option C. It introduces no
> schema and authorizes nothing; the anchor-generalization that would permit active non-location
> world sites is a separate, future decision.

---

### F2-2 — Anchors (`space_anchors`)

**From F1:** `space_anchors` is **closed** to `kind {base,location}` with exactly-one-typed-owner
CHECK, base-CASCADE vs location-RESTRICT FKs, finite ±10000 coords, active/retired status,
immutability trigger, service-role-only, and is **read by nothing** (fully dark) (`0063` throughout).

**Options:** (A) widen `kind` / decouple anchor↔object now; (B) **keep closed, use `kind='location'`
only, no base anchors (RECOMMENDED)**; (C) build a parallel anchor table for world-sites.

**Recommendation → B.** For the first transition, keep `space_anchors` exactly as deployed and use
**only `kind='location'` anchors** for future port placement; **seed no base anchors.** This keeps
anchors dark and byte-compatible (no CHECK/owner/immutability change), avoids the base-CASCADE/
location-RESTRICT asymmetry becoming load-bearing, and avoids touching the closed-kind design.

**How this stays compatible while allowing later generalized world objects:** because Option C's
`world_sites` carries the canonical identity and each port maps via the bridge to a `locations` row,
a `kind='location'` anchor is sufficient to place a port *today* without generalizing anchors. Later,
when `world_sites` needs to anchor non-location objects, that is an **explicit future F2/F4-style
decision** — either add a new typed-owner arm (the 0063 header's prescribed path: real FK + its own
CHECK branch) or decouple anchor→`world_sites` identity. Neither is done or implied now.

> **F2-2 decision requested:** approve keeping `space_anchors` closed `{base,location}`, ports via
> `kind='location'` only, **no base anchors**; defer any kind generalization.

---

### F2-3 — Port-first capabilities

**From F1:** `activity_type` (not `location_type`) is the server behavioral truth — gates send RPCs
(`player_rpcs_combat.sql:42-44`), `activity_start` routing (`presence_combat_hook.sql:13-19`),
presence creation copy (`worldstate_fns.sql:185-187`), and all main-ship/dock gates require
`activity_type='none'`. **No SQL reads `location_type`** (presentation-only).

**Options:** (A) replace activity with a generic capability system now; (B) **port-first additive
capability, activity_type unchanged (RECOMMENDED)**; (C) derive activity_type from capabilities via
a shim now.

**Recommendation → B.** Introduce **only the dockable-port capability** first, modeled as an
**explicit capability/designation associated with a canonical location anchor** (via `world_sites`).
A port is dockable **only** because this explicit capability says so. It must **never be inferred**
from: an active anchor, `location_type`, `activity_type`, coordinate equality, display name, or a
legacy base. Legacy `activity_type` **remains the runtime combat/presence truth** during the
transition; hunt/mine/trade are **not** migrated to capabilities in slice 1. The
`{trade_outpost, safe_zone, rally_point}` + `activity_type='none'` rule remains a Generation-1
candidate-selection filter only (per the approved packet), never runtime identity.

> **F2-3 decision requested:** approve port-first explicit-capability model; keep `activity_type`
> as-is for combat/presence; do **not** replace activity logic now.

---

### F2-4 — Geographic zones

**From F1:** zones are stored as center+radius but `radius` is **display-only**; danger is
**named-location-keyed** (`location_state`/`zone_state` by id; combat reads `danger_modifier` by
`location_id`, `worldstate_fns.sql:305-308`). **No geographic membership / route-intersection test
exists anywhere**; the only distance math is OSN ETA (`s3_begin_move.sql:179`). OSN movement/arrival
functions are grep-clean of combat/danger.

**Options:** (A) extend `zone_state` with geometry/policy; (B) **new geographic-zone layer,
separate from current state tables (RECOMMENDED)**; (C) reuse pressure→danger contract conceptually
in a new layer without sharing tables.

**Recommendation → B (with C's conceptual reuse).** A future **geographic-zone layer** owns
**spatial geometry and policy only**, with **its own stable zone IDs and geometry**, kept
**separate** from `zone_state`/`location_state`/pressure and the named-location combat danger model;
it must **not share the current state tables by default.** It may conceptually reuse center/radius
and the danger idea, but the named-location danger system stays its own domain. Future pirate
interception uses an **adapter outside OSN**:

```text
OSN movement/route result → geographic-zone resolution → structured encounter opportunity
→ pirate system decision
```

The exact geometry (radius → boxes → richer) and the crossing/intersection algorithm are **not
designed here** — deferred. Zones are **not** locations and must **not** be forced into the
`world_sites` table merely because they contain content (F2-1 is point-like content; zones are
areas).

> **F2-4 direction requested:** approve a future separate geographic-zone layer + the OSN→zone→
> encounter→pirate adapter direction; defer geometry/algorithm design.

---

### F2-5 — Docking transition

**From F1:** DOCK-0 is the only `at_location` writer and depends on **exact `locations.x/y` ==
`movement.target_x/y`** (`dock0:83`); `at_location` forbids coords (`spatial_state.sql:62-74`); the
`validate_context` validator (`s2:91-171`) is the single coherence authority; presence is created
`'none'` on dock.

**Options:** (A) cut over to anchor docking directly; (B) **dual-path + shadow verification
(RECOMMENDED)**; (C) flag-gated per-port anchor docking.

**Recommendation → B.** **DOCK-0 remains behaviorally intact** during the transition. A future
`docked_anchor_id` is **nullable** and governed by the **asymmetric** invariant:

```text
docked_anchor_id IS NOT NULL  ⇒  spatial_state = 'at_location'
spatial_state = 'at_location'  does NOT initially require a docked anchor
```

so named-location DOCK-0 docks (anchor NULL) and anchor-docks coexist. **Shadow resolution** must
prove anchor-based docking would **agree with DOCK-0 settlement** (same arrived state, same single
active `'none'` presence at the same port, equivalent fleet/ship columns) **before any writer
cutover.** `location_presence` remains a **compatibility/activity projection — never dock identity.**
Any new field is made coherent in the `validate_context` validator or all coordinate writers reject.

> **F2-5 decision requested:** approve dual-path + shadow-verify direction with the asymmetric
> `docked_anchor_id`; **no writer cutover** without a passed shadow proof.

---

### F2-6 — Recovery

**From F1:** `destroyed` NULLs `spatial_state` (`s5:99-101`); `begin_move` clears coords/pointers
(`s3:226-244`); `fleets.main_ship_id` is write-once (`s1:166-185`) so fleet-held pointers don't
survive destroy/repair; repair lands `home` without spatial reset (`repair_safelock:48-51`).

**Recommendation:** recovery uses a **ship-row-held `last_safe_dock_anchor_id`** that **persists
through departure and destruction**, **updates only on a successful verified canonical dock**, and
is **never inferred or backfilled** from legacy location coordinates, `location_presence`, movement
history, fleet fields, or bases. Existing or never-verified-dock ships **fall back to Haven Prime**
(the Gen-1 shared recovery/starter port). **Legacy bases remain bootstrap/economy/one-time
assignment only** — never operational homes, ports, anchors, permanent origins, or normal recovery
dependencies; **no per-player base anchors.** (Ship-row-held is mandatory precisely because
F1 shows fleet-held and coordinate-derived pointers do not survive the destroy/repair/departure
paths.)

> **F2-6 decision requested:** approve ship-row-held `last_safe_dock_anchor_id` with the
> verified-dock-only update rule and Haven Prime fallback. (No implementation now.)

---

### F2-7 — Lifecycle

**From F1:** soft-state via `status` is universal; a **referenced location is undeletable** (NO
ACTION FKs incl. historical `combat_reports.location_id`; `space_anchors.location_id` RESTRICT); the
only safe retire primitive present is `status='hidden'` (filtered by `get_world_map`); base-CASCADE
vs location-RESTRICT asymmetry on anchors; `TRUNCATE CASCADE` exists as a migration hazard pattern.

**Bounded product decision (framed, not finalized):** a lifecycle over
**`draft → active → hidden → retired → archived`** (names refinable). **Mandatory safety rules
(adopt now):**
- **No hard deletion of referenced live world content.**
- **No port retirement while any ship is docked at it or inbound to it** without an explicit future
  evacuation/diversion/safe-settlement policy.
- **Preserve historical references and reports** (combat_reports, receipts, presence/movement
  history, `last_safe_dock` history) — never silently reinterpret history.

The **final lifecycle schema is deferred** (which states are columns vs. derived, where archival
lives, base vs location retirement unification).

> **F2-7 decision requested:** adopt the mandatory safety rules as binding direction; defer the
> final lifecycle schema.

---

### F2-8 — Coordinate range

**Recommendation:** **defer** any technical-envelope enlargement to the **separate World-Range
Recon** (F1 §E catalogued ≥6 independent ±10000 sites across DB and UI with no shared constant). The
current **±10000 frontier remains unchanged.** No range decision is requested in F2.

---

## 3. Compatibility impact on current tables / functions / paths

| Current artifact | Impact under the recommended model | Evidence (F1) |
| --- | --- | --- |
| `locations` | Frozen as **legacy compatibility/activity projection** (no new feature surface; still **operationally authoritative** for legacy runtime during transition); gains **exactly one** immutable bridge to a `world_site`; existing FKs untouched | `world_map.sql:48-72`; FK web in F1 §A |
| `activity_type` | **Unchanged runtime truth** for combat/presence/dock gates during transition; not replaced by capabilities | `player_rpcs_combat.sql:42-44`, `presence_combat_hook.sql:13-19`, `worldstate_fns.sql:185` |
| `location_presence` | Stays a **compatibility/activity projection**; never becomes dock identity or a recovery input; `'none'`-presence-on-dock behavior preserved | `presence_system.sql:17-41`, `dock0:138` |
| `space_anchors` | **Untouched schema**; stays dark; only `kind='location'` used later for ports; no base anchors; no kind generalization | `0063` throughout |
| DOCK-0 | **Behaviorally intact**; future anchor docking is dual-path + shadow-verified before any cutover | `dock0:79-138` |
| `main_ship_instances` | Future nullable `docked_anchor_id` (asymmetric) + ship-row `last_safe_dock_anchor_id`; both must be made coherent in the validator; not added now | `spatial_state.sql:62-74`, `s2:91-171`, `s1:142-161` |
| repair / destruction | Recovery pointer must **survive** `destroyed`→spatial NULL and `begin_move` clears; ship-row-held by design | `s5:99-101`, `s3:226-244`, `repair_safelock:48-51` |
| `zone_state` / `location_state` | **Unchanged**; future geographic-zone layer is separate and does not share these tables by default | `worldstate_tables.sql:13-32`, `worldstate_fns.sql:305-308` |
| map coordinate domains | **Unchanged**; legacy_dynamic vs open_space_fixed split preserved; no range/transform change | `resolveMainShipMarker.ts:22-31`, `openSpaceTransform.ts:36-40` |

---

## 4. Explicit preservation rules (binding direction if the model is approved)

1. **Existing FKs keep pointing at `locations.id`** through the first transition — no FK rewrite.
2. **The `locations`→`world_sites` bridge is the only identity-translation boundary** — unique,
   immutable after assignment; no translation via names, coordinates, `activity_type`, or FE logic.
3. **No new world-feature semantics or permanent feature columns on `locations`** ("freeze" = no
   new feature surface; future safety / bug-fix / compatibility maintenance remains allowed). During
   the transition `locations` stays **operationally authoritative** for legacy status/`activity_type`/
   coordinates/runtime consumers until an explicitly approved server-owned projection or cutover.
4. **`activity_type` remains the combat/presence runtime truth**; combat/presence behavior is not
   replaced in slice 1.
5. **DOCK-0 stays behaviorally intact**; no anchor-docking writer cutover without a passed shadow
   proof; presence is never dock identity.
6. **`space_anchors` schema unchanged**; no base anchors; ports via `kind='location'` only.
7. **`zone_state`/`location_state` unchanged**; geographic zones are a separate layer with their own
   IDs/geometry; zones are not locations and not `world_sites`.
8. **Void remains valid navigable coordinate space** — no site/object/anchor row required to travel
   through empty space.
9. **No hard deletion of referenced live world content**; preserve reports/receipts/history.
10. **±10000 unchanged**; no range edits outside the separate World-Range Recon.
11. **Recovery pointer is ship-row-held, verified-dock-only, never inferred/backfilled**; bases stay
    bootstrap/economy/one-time-assignment only.
12. **The bridge is immutable and one-to-one per direction for bridged rows** — each legacy
    `location` ↔ exactly one `world_site`, and each **location-backed** `world_site` ↔ exactly one
    `location`; a site may be **unbridged only while `draft`/`hidden`, with no active anchor and no
    live runtime reference**, and **cannot become active runtime content** until a separate
    anchor-generalization + compatibility decision (deployed anchors are `{base,location}` only) —
    see §F2-1A.
13. **No client / frontend / feature subsystem dual-writes `world_sites` and `locations`**; all
    bridge/projection synchronization is **server-owned and defined later.**
14. **A dockable-port capability has at most one canonical active dock anchor at a time; an active
    anchor is not automatically a port; port identity is never inferred** (coords / location type /
    activity type / name / base).
15. **New capabilities never auto-collapse into one legacy `activity_type`**; any capability→legacy
    mapping is explicit, server-owned, and scoped to the specific legacy path supported.

---

## 5. Deferred decisions

- Final **name and schema** of `world_sites`/`world_objects`; bridge representation (column vs. table).
- **When/whether** to broaden `world_sites` into a universal world-object model (gated by the F2-1
  trigger).
- **Anchor generalization** (new typed-owner arm vs. decouple to `world_sites`) — explicit future
  decision.
- **Capability schema** beyond port (hunt/mine/trade/exploration/anomaly/event) and any future
  `activity_type` derivation.
- **Geographic-zone geometry** (radius → boxes → richer) and the crossing/intersection algorithm.
- **Final lifecycle schema** and base/location retirement unification.
- **Exact constraint form** of `docked_anchor_id`/`last_safe_dock_anchor_id` and validator coherence.
- **Coordinate envelope** value + coordinated cutover — the separate World-Range Recon.

---

## 6. Explicit non-authorizations (durable; remain true after merge)

**This decision does not authorize implementation, including migrations, schema changes,
`world_sites` or bridge creation, anchor seeding, resolver or DOCK-0 changes, OSN behavior changes,
dock/recovery fields, capability or geographic-zone systems, pirate/encounter behavior, map changes,
coordinate-bound changes, flag changes, census reruns, or changes to the protected dirty checkout.**

Equivalently and specifically not approved: any migration (`0064`+); any schema change;
creating/altering `world_sites`, the `locations`→`world_sites` bridge, or any table; any
`space_anchors` schema change or **anchor seeding**; any resolver / DOCK-0 / OSN movement behavior
change; adding `docked_anchor_id` / `last_safe_dock_anchor_id`; any capability or geographic-zone
system; any pirate spawning / route-crossing / encounter work; any map/UI change; any
coordinate-bound change; any feature-flag change; any deployment; any census rerun; and any
modification of the protected dirty checkout (no stash/commit/delete/switch/fast-forward).

---

## 7. Conditional post-F2 sequence (illustrative; authorizes nothing)

> Each step requires its own explicit approval. No migration number, seed, resolver change, map
> change, or flag change is approved by listing it. A flag enable is a separate go/no-go gate.

| # | Step (conditional) | Nature | Gate |
| --- | --- | --- | --- |
| G0 | Approve the F2 compatibility model (this packet) | decision | ✅ **APPROVED** (this decision) |
| G1 | **Separately chartered technical design/recon for the first additive transition slice** — the minimal `world_sites` identity + bridge contract (design doc; names/schema TBD). **This — not migration `0064` — is the next authorized task.** | docs/recon | G0 ✅ |
| G2 | Define the **port capability** + `kind='location'` anchor association (design doc) | docs | G1 |
| G3 | Additive, dark schema slice for `world_sites` + bridge (no FK rewrite), verified on the disposable chain | future impl | G2 + explicit approval |
| G4 | Port anchor placement + **shadow** docking resolution (no cutover) | future impl | G3 verified |
| G5 | `docked_anchor_id` / `last_safe_dock_anchor_id` additive fields + validator coherence | future impl | G4 |
| G6 | Lifecycle states + port evacuation policy (after the F2-7 schema decision) | future impl | separate decision |
| Gx | Geographic-zone layer; capability generalization; anchor-kind generalization; range cutover | future impl | separate decisions (incl. World-Range Recon) |
| Gz | Any flag enablement | flag flip | separate go/no-go |

---

*APPROVED COMPATIBILITY / WORLD-MODEL ARCHITECTURE — no implementation authorization. The §1 ledger
is approved; the five §5 product decisions remain open. The only next authorized task is a
**separately chartered technical design/recon for the first additive transition slice (G1)** — not
migration `0064`. Everything beyond stays gated step-by-step; any flag enable is a separate go/no-go.
Baseline holds: migration head 0063, both flags as-is, `space_anchors` dark, OSN paused.*
