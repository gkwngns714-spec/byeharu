# Byeharu — Port-Centric + Modular World Content Architecture Decision Packet (DRAFT)

> **DRAFT — NO IMPLEMENTATION AUTHORIZATION.**
> Design/product only. This document recommends architectural direction and *requests* decisions;
> it authorizes **nothing**. No code, schema, migration, seed, resolver, flag, map-behavior, or
> OSN-implementation change is proposed *active* here. No migration number, seeding, resolver
> extension, UI/map change, world-boundary change, or flag enablement in this packet is approved.
> OSN remains **paused**; no OSN restart is authorized by this packet.

**Canonical basis (do not relitigate):** ANCHOR-2 P0-A census + PORT-CENTRIC pivot at
**PR #21 / `dc58993`**. Census ran **once** (run `28061856879`, commit `a12743f`, read-only
`REPEATABLE READ` → `ROLLBACK`): `TOTAL_SHIPS=72`, `ELIGIBLE=72`, `UNRESOLVED=0`, zero anomalies.
**Must not be rerun.** Used here only as evidence that *legacy base data is clean* — never as a
reason to promote a base into a port, home, or anchor.

**Live baseline (verified against `origin/main`@`dc58993`):** migration head **`0063`**
(`space_anchors` — additive, empty, dark, service-role-only). Flags in `game_config`:
`mainship_send_enabled='true'`, `mainship_space_movement_enabled='false'`. **OSN PAUSED.**

**What changed in this revision:** the packet is reframed from "a five-port plan" into a **modular,
expandable world-content architecture** in which OSN is the *navigation foundation* and gameplay
content systems sit **above** it through narrow contracts. The five-port plus-core is demoted to
**Generation-1 infrastructure only** (Part C), not the definition of the world.

---

## 0. Grounding — current repository & deployed boundaries (read-only recon of what exists)

Verified against migrations on `origin/main`. This is the factual substrate; the architecture in
Part A must remain compatible with it until a proven, separately-approved migration changes it.

| Object / consumer | Where | Current shape (facts) | Relevance to this packet |
| --- | --- | --- | --- |
| **`sectors` / `zones` / `locations`** | mig 0002 | Static 3-level hierarchy. `zones` already carry **`x,y,radius`** (a *circle* — a primitive spatial area). `locations`: `location_type ∈ {pirate_hunt, pirate_den, mining_site, derelict_station, trade_outpost, rally_point, safe_zone, event_site}`, `activity_type ∈ {hunt_pirates, mine_resource, explore_derelict, trade_visit, rally, none}`, `status ∈ {active, locked, hidden}`, `x/y`, `is_public`, `max_presence_seconds`. Map-owned, public-read, no client write. | `location_type` is a **single mutable classification** — exactly the "giant switch" risk to dismantle (A3). Zone `radius` is the seed of a real geometry model (A4). |
| **`location_state` / `zone_state`** | mig 0031–0034 | Dynamic per-location/zone: `pressure`, `danger_modifier`, `active_fleets`, tick timestamps. World-State is sole writer; public-read; Combat reads `danger_modifier`. `active_fleets` is a reconciled cache; truth = active `location_presence`. | Proves the **static identity ↔ dynamic state** split already exists for locations/zones; A1/A4 generalize it. |
| **`bases` / `base_units` / `base_resources`** | mig 0005 | `player_id`→`auth.users`, `name`, `x/y` default 0, `status ∈ {active,destroyed}`. Owner-read; writes via SECURITY DEFINER only. Census: 72 clean, one per owner. | Bootstrap/economy/one-time-assignment only (A7); never port/home/anchor. |
| **`location_presence`** | mig 0008 | `fleet_id`, `location_id`, `activity_type`, `status ∈ {active, retreating, leaving, completed, destroyed, expired}`, partial-unique **one active per fleet**. `activity_start` router: only `'none'` implemented; `hunt_pirates` is the M4 extension point. | **Activity-presence projection** only (A7) — not dock identity, not a recovery input. |
| **`main_ship_instances`** | mig 0043 / 0054 | One per player. `status ∈ {home,traveling,hunting,trading,exploring,mining,retreating,returning,repairing,destroyed}`. `spatial_state ∈ {NULL(legacy), home, at_location, in_transit, in_space, destroyed}`; `space_x/space_y` present **iff** `in_space` (finite). | Canonical **ship spatial-state owner** (OSN scope, A9); future dock-identity fields attach here (A7). |
| **`main_ship_space_movements`** | mig 0055 | `origin_kind/target_kind ∈ {base,location,space}`, `origin_x/y`,`target_x/y`, `target_location_id`, `target_base_id`, `status ∈ {moving,arrived,stopped,cancelled,failed}`, `terminal_reason`, `speed_used`, `depart_at/arrive_at`, one-active-per-ship/fleet. **±10000 CHECK on all four coords.** | OSN movement record (A9). Range consumer (Part B). |
| **`space_anchors`** | mig 0063 (dark, EMPTY) | `kind ∈ {base,location}`, typed owner FK (`base_id` CASCADE / `location_id` RESTRICT), `space_x/y` NOT NULL finite **∈ ±10000**, `status ∈ {active,retired}`, one-active-per-owner, immutable, service-role-only. Seeds nothing; not read by resolver. | The **canonical authored placement** primitive (A2). Note: `kind` is **closed to {base,location}** today — generalizing to arbitrary world objects (A1/A2) is an **open schema decision**, not done here. |
| **`mainship_space_resolve_origin`** | mig 0062 | `home/legacy_home/at_location/legacy_present → origin_not_anchored`; `in_space → ship space_x/y`; `in_transit → must_stop`; `destroyed → destroyed`. service-role-only. | Already truthful: legacy `x/y` are not canonical origins (A2 "coordinates ≠ identity"). |
| **DOCK-0 primitive** | mig 0061 (dark) | Location-targeted move with `status='active'` + `activity_type='none'` + **exact `x/y` match** → dock (presence + `at_location`); else terminal failure floating `in_space`. | Behavior any anchor-based docking cutover must **preserve/prove** before retiring (A7). |
| **`game_config`** | mig 0003; flag seeded 0055 | Config/flag store; `cfg_bool('mainship_space_movement_enabled')` gates begin-move/command/arrival admission. | Flag store; **no flag change authorized**. |
| **Range consumers of ±10000** | migs 0055 (movements CHECK), 0057 (`begin_move` `c_lo/c_hi`), 0060 (S6A canonicalization), 0063 (anchors CHECK); **frontend** `src/features/map/openSpaceTransform.ts` (`WORLD_MIN=-10000`, `WORLD_MAX=10000`, `VIEWBOX_SIZE=1000`, scale `0.05`), `GalaxyMap.tsx` (`viewBox 0 0 1000 1000`, pan/zoom). | **Multiple independent** ±10000 sites in DB **and** UI — a boundary change touches all of them (Part B / World-Range Recon). |

**Recon conclusion:** the codebase already separates *static identity* (`locations`/`zones`) from
*dynamic state* (`location_state`/`zone_state`), already has a *placement primitive*
(`space_anchors`) distinct from identity, and already has a *primitive area* (zone `x,y,radius`).
The gaps the architecture must close are: (1) world-object **identity is currently fused to
`location_type`** (a mutable single-role classification); (2) **capabilities are exclusive**
(one type per location) rather than independent/composable; (3) `space_anchors.kind` is **closed**
and location/base-only; (4) **range bounds are hard-coded in ≥6 places** across DB and UI.

---

# PART A — Architecture direction (proposed; requires approval)

OSN is the **navigation foundation underneath** the world, not a competing system. The intended
stack — each layer depending only on narrow explicit contracts of the layer below:

```text
OSN / spatial movement foundation
  → world-object identity + spatial anchors
  → world zones / region topology
  → encounter / activity contracts
  → pirate · exploration · mining · trade · port · event gameplay
  → map / UI (renders authored data; never a source of gameplay truth)
```

### A1 — Stable world-object identity
Every meaningful place (pirate hideout, ruin, mine, anomaly, trade hub, port, exploration site,
temporary event) has a **stable canonical identity** (a durable world-object ID). Identity is
**never derived from** coordinates, display name, legacy base, mutable location type, zone
membership, or map position. A place may be renamed, reclassified, hidden, reactivated, moved
(through an explicit controlled procedure), or given new features **without becoming a different
object**. *Coordinates are placement, not identity.*

> Compatibility note: today identity is effectively a `locations.id` fused to `location_type`.
> Whether the canonical world-object becomes a generalization of `locations`, a new table, or a
> superset is an **open technical decision** (the recon, Part E, must precede it).

### A2 — Spatial anchor
A `space_anchor` is the **canonical authored coordinate placement** for a world object. It is **not
automatically** a port, dockable, safe, a pirate site, a mine, or an exploration site. It is only a
stable spatial reference navigation/map can read. **Coordinate equality is never identity** — no
system may infer "which object" from matching/near coordinates.

> Compatibility note: `space_anchors.kind` is currently closed to `{base,location}`. Generalizing
> anchors to arbitrary world-object kinds (or decoupling anchor↔object via the A1 ID) is an **open
> schema decision** — not made here, and not by widening the closed CHECK informally.

### A3 — Feature / capability layer
World objects gain/lose **multiple independent capabilities over time** — dockable port, safe
haven, trade, pirate activity, mining, exploration, combat encounter, anomaly, quest/event,
repair/service, (later) faction control. **Do not model the world as one exclusive
`location_type = port | pirate | mine | …`.** A location may be more than one thing, and may change
(pirate hideout → abandoned ruin + exploration site → trade outpost) while **identity and anchor
persist**.

A **port is an explicit capability**. It is **never inferred** from: having an active anchor; a
coordinate; a name; `activity_type`; or a legacy classification. The current
`{trade_outpost, safe_zone, rally_point}` + `activity_type='none'` rule may remain **only** as a
temporary **Generation-1 candidate-selection policy** (Part C), never as permanent runtime
identity.

### A4 — Zone / region layer
A **zone is an area of space**, not a point and not a port. A zone may contain void, ports, pirate
sites, mines, exploration sites, anomalies, events, many locations, or no fixed location at all. A
zone may define danger, theme, (later) faction/region identity, spawn/encounter policy,
environmental effects, exploration progression, and content-population rules. **Zone membership is
independent of an object's identity and anchor.** A zone can be added, resized, split, merged, or
re-themed **without relocating contained content or rewriting port logic**.

**Geometry — staged, not locked now.** The architecture must support *true spatial areas*, not mere
lists of location IDs. The recon should evaluate a staged model appropriate to the stack —
**bounded regions first** (e.g. center+radius, as zones already have, and/or axis-aligned boxes),
**richer shapes later** — without prematurely overbuilding (no commitment to PostGIS/polygons yet).
Final zone geometry is an **open technical decision**.

### A5 — Void space
Void is **valid navigable world space between authored locations**. It requires **no fake
ports/locations**. A ship may traverse void; void may later belong to a zone with danger/events/
hazards or to no gameplay effect at all.

### A6 — Lifecycle layer
Live content is normally **retired/hidden/archived, not hard-deleted**. Use a lifecycle concept
such as **draft → active → hidden → retired → archived** (exact names refinable later; the *safety
principle is mandatory*). For referenced live content: **preserve stable identity; preserve
historical reports/receipts/activity/movement references; stop new access per feature-specific
rules; break no unrelated system; never silently reinterpret history.** Hard deletion is limited to
genuinely unused, unreferenced draft/test content.

**Port-specific lifecycle rules (mandatory):**
- A port **cannot be retired/deactivated while any ship is currently docked there.**
- A port **cannot be retired while ships are inbound** without an explicit future policy for
  cancellation / diversion / safe settlement.
- Port retirement requires an explicit future **evacuation/transition procedure**.
- A retired/inactive port **remains valid in historical references and `last_safe_dock` history**.
- **Recovery falls back to Haven Prime** when a stored last-safe port is no longer valid.

### A7 — Current dock & recovery model (carried forward, made compatibility-safe)
- **`docked_anchor_id`** = current dock **only while actually docked**; cleared on departure.
- **`last_safe_dock_anchor_id`** persists after departure; **updates only after a successful
  verified canonical docking**; it is the **sole recovery input**.
- **Recovery** = last confirmed safe dock, else the shared **Haven Prime**.
- **`location_presence`** is a compatibility/activity-presence projection — **not** dock identity,
  **not** a recovery input.
- Recovery **never infers** a port from coordinates, movement origin/target, legacy bases, or
  location presence.
- **Legacy bases** remain bootstrap/economy/**one-time** starter-or-migration assignment records
  only — never operational homes, ports, anchors, permanent origins, or normal recovery
  dependencies. **No per-player base anchors.**
- **Transitional invariant is ASYMMETRIC** (preserves named-location / DOCK-0 behavior before full
  anchor-based docking cutover):

```text
docked_anchor_id IS NOT NULL  ⇒  spatial_state = 'at_location'
spatial_state = 'at_location'  does NOT yet imply  docked_anchor_id IS NOT NULL
```

### A8 — Dangerous zones & movement crossings (future contract; not built now)
A dangerous zone must be able to **react when a ship enters it**. Intended flow:

```text
depart port → move through void → cross a dangerous-zone boundary
→ zone-entry rule becomes eligible → pirate/encounter system decides interception/encounter
```

A route **must not be judged only by its destination coordinate** — an A→B route may cross several
zones between the endpoints. The architecture must therefore *support* (without building now):
**route/segment ↔ zone-boundary intersection**, **ordered zone-entry/exit events**, and **rules on
entry / while-inside / on-exit**. Future integration contract:

```text
OSN resolves a movement/state transition or route crossing
→ zone resolver determines relevant zone transition(s)
→ zone policy exposes a structured event opportunity
→ pirate/encounter system decides content + outcome
```

**OSN must not contain pirate-combat rules.** Do **not** implement route-zone intersection, pirate
spawning, or encounters now — but do not design zones in a way that makes them impossible or forces
an OSN rewrite.

### A9 — Feature ownership boundaries (explicit)
- **OSN / Navigation-docking** owns **only**: ship spatial state; ship coordinates; movement
  origin/target/route/arrival/terminal state; docking-state transitions; legality of movement &
  docking; movement history/idempotency/safety; anchor reachability; dock eligibility; recovery
  transition *mechanics*. OSN owns **none** of: pirate spawns, mining rewards, exploration content,
  trade logic, zone danger rules, or a `location_type` switch.
- **Zone system** owns region boundaries, region identity, generic zone policy.
- **Pirate system** owns pirate population, interception, encounter construction, pirate rewards.
- **Mining system** owns nodes, extraction, depletion, mining rewards.
- **Exploration system** owns discoveries, site progression, exploration rewards.
- **Trade system** owns markets, routes, services, trade results.
- **Map/UI** renders authored world data + player visibility; **never** a source of gameplay truth.

All systems may reference common **stable world-object IDs and anchor IDs**; they must **not**
depend on each other's private fields, and there must be **no universal all-purpose location RPC**.

---

# PART B — Coordinate range & future map growth

The goal is **outward growth without moving existing content**, not "make the empty map bigger."
Keep **four concepts strictly separate** — none inferred from another:

1. **Technical coordinate envelope** — coordinates the server policy allows (today ±10000 in ≥6
   sites: movements CHECK 0055, `begin_move` 0057, S6A 0060, anchors 0063, frontend
   `openSpaceTransform.ts`, GalaxyMap viewBox).
2. **Authored content extent** — where ports/zones/sites/events currently exist.
3. **Navigation / travel limits** — how far/long ships may *directly* travel and under what
   progression rules.
4. **Map/UI viewport & discovery visibility** — what the player can currently see/access.

**Hard rules:** the technical envelope must **not** be inferred from the farthest anchor/ship/
location/zone; the viewport must **not** be inferred from content extent; a technically valid
coordinate does **not** imply a player may directly travel there; adding an outer zone must **not**
rescale/relocate existing ports/ships/anchors/locations. The current **`[-10000,+10000]²` is a
temporary implementation frontier, not a lore edge. Do not enlarge it now.**

Before any future boundary change: a dedicated **read-only World Range Recon** (Part E) covering
*every* range consumer — DB constraints, RPC validation, resolver assumptions, travel-duration
interactions, map transforms, pan/zoom limits, UI assumptions, seed validation, tests, verifier
fixtures, deployment checks — then a **separate explicit approval**, then a **single coordinated**
change to a generous long-term envelope.

---

# PART C — Generation-1 content decisions (infrastructure only; not the world)

The five-port plus-core is **Generation-1 bootstrap infrastructure only** — the minimum to stand up
docking/recovery — **never** the definition of the world. It does not constrain A1–A9.

- **Candidate-selection policy (temporary, Gen-1 only):** `status='active'` + `activity_type='none'`
  + `location_type ∈ {trade_outpost, safe_zone, rally_point}`. This is a *design-time filter to pick
  what to anchor first* — it confers **no runtime dockability**. (Port = explicit capability, A3.)
- **Proposed Gen-1 layout (design only; nothing seeded):** 5 ports in a dense plus-core, envelope
  ≈ `[-2000,2000]²` (frontier ≈ `[-10000,10000]²` unchanged):

| Port | Gen-1 candidate type | Role | Sketch coord (authored, not copied from legacy `x/y`) |
| --- | --- | --- | --- |
| **Haven Prime** | `safe_zone` | Shared recovery / starter haven; always active | `(0, 0)` |
| North Exchange | `trade_outpost` | Trade hub | `(0, 1500)` |
| East Exchange | `trade_outpost` | Second trade node | `(1500, 0)` |
| South Muster | `rally_point` | Staging / rally | `(0, -1500)` |
| West Muster | `rally_point` | Second staging node | `(-1500, 0)` |

- **Haven Prime** = the single deterministic, always-active shared recovery/starter port (A7), an
  ordinary anchored port, never a base.
- **Outward-only / never-remap** growth is a standing rule (Part B); the 0063 per-row immutability
  guard already forbids changing an existing anchor's coordinate.

---

# PART D — Decision Ledger

### D1. Approved architectural direction (requested for approval)
- OSN is the **navigation foundation**; gameplay content sits **above** it via narrow contracts;
  OSN owns only ship spatial-state / movement / docking-legality / recovery mechanics (A9).
- **Identity ≠ coordinates ≠ type ≠ zone ≠ name** (A1); **anchor = placement only** (A2);
  **capabilities are independent & composable**, port is an explicit capability (A3).
- **Zones are real spatial areas**, membership independent of identity/anchor; geometry staged
  bounded-first (A4). **Void is first-class** navigable space (A5).
- **Lifecycle = retire/hide/archive, preserve history**; port retirement needs evacuation rules
  (A6).
- **Dock/recovery** per A7 incl. the **asymmetric** transitional invariant; **legacy bases** stay
  bootstrap/economy/one-time-assignment only.
- **Zone-entry / route-crossing** is a future contract OSN must *enable but not own* (A8).
- **Four separated range concepts**; ±10000 frozen now (Part B).

### D2. Proposed Generation-1 content decisions (requested for approval)
- Gen-1 candidate policy `{trade_outpost, safe_zone, rally_point}` + `activity_type='none'`
  (temporary selection filter only).
- 5-port dense plus-core in ≈ `[-2000,2000]²`, **Haven Prime** at origin as shared recovery/starter
  port. **Design only — nothing seeded.**

### D3. Open PRODUCT decisions (need your input)
1. Initial capability set to support first (which of port/safe-haven/pirate/mining/exploration/
   trade/event lands in early generations, and in what order).
2. Lifecycle state names + the **port evacuation/diversion** policy for retiring a port with
   docked/inbound ships.
3. Zone theming/identity model (faction/region later?) and danger semantics relative to existing
   `location_state.pressure` / `danger_modifier`.
4. Whether `derelict_station` (and other current types) join Gen-1 capabilities or wait.
5. Long-term world-growth cadence (how/when outer regions are authored).

### D4. Open TECHNICAL / SCHEMA decisions (need recon first — Part E)
1. World-object identity representation: generalize `locations`, new table, or superset (A1).
2. `space_anchors` generalization: widen `kind`, decouple anchor↔object, or keep closed +
   adapter (A2).
3. Capability modeling: capability table(s) vs. tags vs. typed feature rows — replacing the
   single `location_type` (A3).
4. Zone geometry: center+radius (exists) vs. boxes vs. later richer shapes; route↔zone
   intersection representation (A4/A8).
5. Dock-identity fields on `main_ship_instances` (`docked_anchor_id`, `last_safe_dock_anchor_id`)
   + the asymmetric invariant's exact constraint form (A7).
6. The eventual long-term technical coordinate envelope value + the single coordinated cutover
   (Part B) — **after** the World-Range Recon.

### D5. Explicit NON-authorizations (in force)
No merge of PR #22; no migration `0064`+; no `space_anchors` seed or schema change; no DOCK-0 /
resolver / OSN movement behavior change; no zones / pirate spawning / route crossings / encounters;
no map change; no coordinate-bound change; no flag change; no census rerun. **No** touching the
dirty checkout, its stale untracked draft, or its worktree (no stash/commit/delete/switch/
fast-forward).

---

# PART E — Read-only World Model Recon plan (must precede ANY schema/seed/resolver/map/flag work)

Each item is **read-only inspection** producing findings + compatibility requirements. No writes.

1. **World-object identity & classification** — every reader/writer of `locations.location_type`,
   `activity_type`, `status`, `is_public`; enumerate the implicit "type switch" sites (SQL + TS).
   *Output:* what fuses identity to type, and what must change to introduce a stable ID.
2. **Anchor model** — `space_anchors` consumers (none read it yet), the closed `kind` CHECK, FK
   delete-actions; what generalizing kind/decoupling would touch.
3. **Dynamic state split** — `location_state` / `zone_state` writers/readers; confirm the
   identity↔state separation generalizes to capabilities/zones.
4. **Zone geometry feasibility** — current `zones.x,y,radius` usage; `get_world_map`; what a
   bounded-region (and later richer) model implies for readers; route↔zone intersection feasibility
   on this stack (no PostGIS commitment).
5. **Ship spatial-state & dock identity** — `main_ship_instances` spatial invariants (0054),
   DOCK-0 (0061), resolver (0062), `location_presence` (0008); precise compatibility surface for
   adding `docked_anchor_id` / `last_safe_dock_anchor_id` under the **asymmetric** invariant without
   breaking named-location behavior.
6. **Movement & history** — `main_ship_space_movements` (0055), begin-move (0057), arrival
   processor (0058), destruction/coordinate completion (0059), S6A command (0060); idempotency/
   safety guarantees the content layers must not violate.
7. **Recovery references** — everything that would read `last_safe_dock`; confirm no path infers
   dock from presence/movement/legacy-base/coordinates.
8. **Map / frontend coordinate consumers** — `src/features/map/openSpaceTransform.ts`
   (`WORLD_MIN/MAX`, `VIEWBOX_SIZE`, scale), `GalaxyMap.tsx` (viewBox, pan/zoom bounds), markers,
   `mapApi`/`mapTypes`, `get_world_map`; what "render authored data, not gameplay truth" requires.
9. **Lifecycle references** — all FKs/joins/history (reports, receipts, presence, movements)
   that must survive retire/hide/archive; where hard-delete is currently possible.
10. **Ownership-boundary audit** — confirm no cross-system private-field dependency and no
    universal location RPC is implied by any proposal.
11. **(Separate) World-Range Recon** — *every* ±10000 consumer (Part B list) as a precondition to
    any envelope change; produces the coordinated single-change plan.

---

# PART F — Proposed conditional sequence (illustrative; authorizes nothing)

> **NOT an authorization.** No step is approved by listing it. No migration number is implied as
> approved. Each step needs its own explicit go-ahead; a future flag enable is a **separate
> go/no-go gate**.

| # | Step (conditional) | Nature | Gate |
| --- | --- | --- | --- |
| **F0** | **Approve the broadened architecture** (Part A) + Gen-1 content direction (Part C). | decision | this packet |
| **F1** | **Read-only World Model Recon** (Part E §1–10). | read-only | F0 |
| **F2** | **Compatibility / model decision** — resolve D4 (identity, anchor, capabilities, zone geometry, dock fields) from F1 findings. | decision (docs) | F1 |
| **F3** | **Separate World-Range Recon + decision** (Part E §11 / Part B) — only if/when a boundary change is wanted. | read-only + decision | independent |
| **F4** | **Only then:** later **additive, dark** implementation + **Generation-1 seeding**, each step independently approved, verified on the disposable chain, flags untouched. | future work | F2 (+F3 if range) |
| **F5** | **Enablement** — any flag flip is its own recorded go/no-go, after the above prove green. | flag flip | **separate gate** |

**Explicitly NOT authorized by this packet:** any flag flip; any migration `0064`+; any
`space_anchors` seed/schema change; any DOCK-0 / resolver / OSN movement change; any zones / pirate
/ route-crossing / encounter work; any map change; any coordinate-bound change; any census rerun;
any touch of the dirty checkout / its stale draft / its worktree.

---

*DRAFT — design/product only, no implementation authorization. Approve Part A (architecture) and
Part C (Gen-1 direction), or amend per section, to make **F0 → F1 (recon)** eligible — everything
beyond stays gated step-by-step. Baseline holds: migration head 0063, both flags as-is, OSN paused.*
