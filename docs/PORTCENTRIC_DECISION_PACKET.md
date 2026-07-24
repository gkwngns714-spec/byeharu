# Byeharu — Port-Centric Product-Decision Packet

**Status:** DESIGN / PRODUCT DECISIONS ONLY. No code, schema, migration, seed, resolver,
flag, map-behavior, or OSN-implementation change is proposed *active* here. Nothing in this
packet is authorized until explicitly approved; the "Implementation sequence" at the end
becomes the authorized work list *only after* a decision is recorded.

**Canonical basis (do not relitigate):** ANCHOR-2 P0-A census + PORT-CENTRIC pivot at
**PR #21 / `dc58993`**. Census ran **once** (run `28061856879`, commit `a12743f`,
read-only `REPEATABLE READ` → `ROLLBACK`): `TOTAL_SHIPS=72`, `ELIGIBLE=72`, `UNRESOLVED=0`,
one-base-per-owner invariant held, zero anomalies. **The census must not be rerun.**

**Live baseline at this writing (unchanged):** production migrations end at **0063**
(`space_anchors` — additive, empty, dark, service-role-only). Flags:
`mainship_send_enabled=true`, `mainship_space_movement_enabled=false`. **OSN is PAUSED.**

---

## 0. Grounding — what exists today (canonical, verified against migrations)

| Object | Migration | Relevant shape | Role for ports |
| --- | --- | --- | --- |
| `locations` | 0002 | `location_type ∈ {pirate_hunt, pirate_den, mining_site, derelict_station, trade_outpost, rally_point, safe_zone, event_site}`, `activity_type ∈ {hunt_pirates, mine_resource, explore_derelict, trade_visit, rally, none}`, `status ∈ {active, locked, hidden}`, `x/y` (legacy), `is_public`, `max_presence_seconds` | The **port candidate set**. Public-read, no client writes. |
| `zones` / `sectors` | 0002 | static hierarchy, own `x/y` | Spatial grouping; not ports themselves. |
| `bases` | 0005 | `player_id`→`auth.users`, `name` default `'Home Base'`, `x/y` default `0`, `status ∈ {active, destroyed}` | **Legacy starter/registration record.** Owner-read only. 72 clean rows. |
| `location_presence` | 0008 | `fleet_id`, `location_id`, `activity_type`, `status ∈ {active, retreating, leaving, completed, destroyed, expired}`, partial-unique **one active per fleet** | The **proto dock record** (fleet is "at" a location). |
| `main_ship_instances` | 0043 / 0054 | `player_id` unique, `status`, `spatial_state ∈ {NULL(legacy), home, at_location, in_transit, in_space, destroyed}`, `space_x/space_y` (set IFF `in_space`) | The one ship per player; `at_location` is the proto "docked" spatial mode. |
| `space_anchors` | 0063 (dark, EMPTY) | `kind ∈ {base, location}`, `base_id`→`bases` CASCADE, `location_id`→`locations` RESTRICT, `space_x/space_y` NOT NULL finite ∈ `[-10000,10000]²`, `status ∈ {active, retired}`, one active per owner, immutable, service-role-only | The **future canonical coordinate** for ports. Not yet seeded, not yet read by the resolver. |
| `mainship_space_resolve_origin` | 0062 | `home/legacy_home/at_location/legacy_present → origin_not_anchored`; `in_space → ship space_x/y`; `in_transit → must_stop`; `destroyed → destroyed` | Today **refuses** to treat a docked/home position as a movement origin until an anchor exists. |
| DOCK-0 dock primitive | 0061 (dark) | location target + `status='active'` + `activity_type='none'` + **exact `x/y` match** → dock (presence + `at_location`); else terminal failure floating `in_space` | Proto docking — exact-match against legacy `locations.x/y`, not yet anchors. |

**The central gap this packet closes:** the resolver is truthful (legacy `x/y` are *not*
canonical OSN positions) but there is **no canonical coordinate** for any port yet, so no
docked/home ship can currently originate a coordinate move. Ports become real only when
`space_anchors` is seeded and the resolver/docking read it.

---

## 1. Port eligibility — which locations can become ports, and the criteria

**Question:** Of the 8 `location_type`s, which may carry a dockable port, and what makes a
specific location eligible *now*?

### Options

- **E-A — All active locations are ports.** Every `locations` row with `status='active'`
  is dockable. *Pro:* simplest; no new classification. *Con:* docks a ship into hostile
  activity sites (`pirate_hunt`/`pirate_den`) and `event_site`s that are encounters, not
  harbors — conflates "a place you fight" with "a place you berth." Breaks the DOCK-0
  invariant that only `activity_type='none'` is dockable.
- **E-B — Port = curated `location_type` whitelist + `status='active'`.** Ports are exactly
  the *harbor-like* types: **`trade_outpost`, `safe_zone`, `rally_point`** (and
  `derelict_station` *only* once it has a non-hostile docking mode). Hostile/activity sites
  (`pirate_hunt`, `pirate_den`, `mining_site`, `event_site`) are **destinations you travel
  to and act at**, never berths. *Pro:* matches DOCK-0's `activity_type='none'` rule and the
  fiction (you dock at harbors, you raid dens). Eligibility is data-driven and auditable.
  *Con:* needs an explicit "is this type a port" rule (a small reference fact, not new
  gameplay).
- **E-C — Explicit per-row port flag.** Add an authored boolean/role on each location
  ("this specific row is a port") independent of type. *Pro:* maximum curation control;
  lets one `mining_site` be a port and another not. *Con:* new authored column + seeding
  burden on every location; over-engineered for an MVP with a handful of harbor types.

### Recommendation → **E-B (type-whitelist), with the eligibility predicate anchored on `activity_type`, not `location_type` alone.**

Concretely, a location is **port-eligible** iff:
1. `status = 'active'`, **and**
2. `activity_type = 'none'` (the DOCK-0-proven "you can just be here" predicate), **and**
3. `location_type ∈ {trade_outpost, safe_zone, rally_point}` for the first port generation.

This keeps eligibility *derivable from existing columns* (no new authored data), is exactly
the set DOCK-0 already accepts, and leaves `derelict_station` as a deliberate **Phase-2**
candidate (it needs an "explore vs. dock" decision first). `is_public=false` locations may be
eligible *types* but are **out of the initial seed scope** (see §5). Hostile sites stay
travel-and-act destinations forever — they are not ports.

> Decision needed: confirm the three-type initial whitelist, and whether `derelict_station`
> joins generation 1 or waits for its docking-vs-exploration mode.

---

## 2. Dock identity — the canonical "this ship is docked at this port" record

**Question:** What single record is the source of truth that a given main ship is currently
berthed at a given port?

### Options

- **D-A — `location_presence` is the dock record (status quo, formalized).** A fleet's active
  `location_presence` row (`status ∈ {active,...}`, unique one-active-per-fleet) + the fleet's
  `current_location_id` + the ship's `spatial_state='at_location'` *is* "docked." *Pro:* zero
  new tables; this is the DOCK-0 settlement target already; the partial-unique index already
  enforces "one place at a time." *Con:* `location_presence` is overloaded — it also models
  *hostile activity exposure* (`hunt_pirates`, retreat/leave/expire lifecycle). "Docked at a
  safe port" and "exposed at a combat site" would share one table and one status enum.
- **D-B — New dedicated `ship_dockings` record.** A purpose-built row keyed to the main ship +
  port (anchor) with a clean `docked/departed` lifecycle, separate from presence. *Pro:* clean
  separation (NEVER spaghetti): "berthed" and "in a fight" stop sharing a table. *Con:* new
  schema + a second source of "where is the ship," risk of divergence from `spatial_state`
  unless one is derived from the other.
- **D-C — `main_ship_instances` IS the dock identity (spatial_state + a port pointer).** The
  ship row itself is canonical: `spatial_state='at_location'` plus a (future) `docked_anchor_id`
  / `current_location_id`-equivalent pointing at the port's `space_anchors` row. Presence stays
  the *activity* record only. *Pro:* there is already exactly one `main_ship_instances` row per
  player; spatial truth already lives there (`spatial_state`, `space_x/y`); no second "where"
  table. *Con:* needs an additive pointer column on the ship + a rule binding it to a port
  anchor; must keep presence and ship-state mutually consistent under the S2 lock order.

### Recommendation → **D-C: the main ship row is the canonical dock identity; presence is downgraded to "activity only."**

`spatial_state='at_location'` already means "berthed/stationary at a named location." Make that
truth *complete* by adding (later, additively) a **`docked_anchor_id` → `space_anchors(id)`**
pointer that is non-null **iff** `spatial_state='at_location'`, mirroring the existing
"`space_x/y` non-null iff `in_space`" invariant. Then:

- **Canonical "docked-at" = `main_ship_instances.spatial_state='at_location'` + `docked_anchor_id`.**
- `location_presence` keeps describing *activity exposure* only (DOCK-0 already creates a
  `'none'` presence on dock; that stays as the "present, no activity" marker but is **not** the
  identity of record).

This preserves NEVER-spaghetti separation (port identity ≠ combat exposure), reuses the proven
one-row-per-ship spatial owner, and means the resolver can answer "what is this docked ship's
canonical origin?" by reading `docked_anchor_id → space_anchors.space_x/y` — closing the
`origin_not_anchored` gap *for ports* without ever touching legacy `locations.x/y`.

> Decision needed: accept the ship row (+ `docked_anchor_id`) as canonical dock identity, with
> presence demoted to activity-only. (Implementation is additive, dark, and post-approval — §
> sequence step S2.)

---

## 3. Legacy-base role — what `bases` remain responsible for (and what they must NOT be)

**Question:** Now that the permanent home-base plan is cancelled, what is a `bases` row *for*?

### Bases REMAIN responsible for (bootstrap / starter / recovery only):

1. **Player registration / bootstrap.** `initialize_new_player()` creating the starter base +
   starter units + starter resources stays the onboarding anchor — a player still "starts
   somewhere."
2. **Economy container (current).** `base_resources` / `base_units` remain the landing spot for
   combat rewards and the unit ledger as they exist today. (No economy redesign here.)
3. **Recovery designation (see §4).** A base is a *candidate* recovery destination — a place a
   stranded/repaired ship can be returned to — but only via the explicit recovery path, never as
   ordinary navigation.

### Bases are EXPLICITLY EXCLUDED from being:

- ❌ **An operational "home" you navigate to/from.** "Return home" is **not** ordinary
  movement (pivot §2). No player travel command may take a base as a normal origin/destination.
- ❌ **A permanent ship origin.** No `home_base_id` on `main_ship_instances`, no NOT-NULL/FK
  backfill binding a ship to a base. The cancelled P0 plan stays cancelled.
- ❌ **A canonical OSN coordinate.** `bases.x/y` are **legacy display-only** and never a movement
  origin (the resolver already enforces this: `home → origin_not_anchored`). A base acquires a
  *canonical* coordinate only if/when a `space_anchors(kind='base')` row is deliberately seeded
  for recovery (§4) — and even then it is a recovery target, not a navigable home.

### Options for how far to formalize this now

- **B-A — Documentation-only (recommended).** Record the role boundary in
  `docs/SYSTEM_BOUNDARIES.md` / architecture; change no schema. *Pro:* zero risk, matches "no
  base column change" constraint. *Con:* relies on discipline, not a constraint.
- **B-B — Rename/relabel `bases.name` default & add a `role` note column.** *Con:* schema churn
  on a table we are deliberately freezing; rejected.
- **B-C — Hard-deprecate base writes.** Lock base mutation further. *Con:* premature; economy
  still uses base tables. Rejected for now.

### Recommendation → **B-A.** Freeze `bases` schema; document the role as *bootstrap + economy
container + recovery candidate*, and codify the three exclusions above as a boundary rule. The
only place a base ever gains a canonical coordinate is an explicit, opt-in
`space_anchors(kind='base')` recovery seed — never automatically from `bases.x/y`.

---

## 4. Recovery model — where repaired / destroyed / stranded ships return (anti-softlock)

**Question:** A ship can end up `destroyed`, mid-repair, or stranded `in_space` with
`origin_not_anchored` (no port to leave from). Where does it come back, and how do we guarantee
it can *always* act again?

### Failure states to cover

- `spatial_state='in_space'` with no reachable port (DOCK-0 terminal failure leaves a ship
  floating at a destination coordinate).
- `status='destroyed'` / `spatial_state='destroyed'` (needs a respawn home).
- `repairing` / `returning` legacy statuses needing a defined endpoint.
- A docked ship whose port becomes `inactive`/`locked` under it.

### Options

- **R-A — Recover to the player's bootstrap base.** Repaired/destroyed ships re-home to their
  registration `bases` row, given a canonical recovery anchor. *Pro:* every player provably has
  exactly one clean base (census: 72/72, one per owner) → a guaranteed, already-existing,
  unambiguous recovery target. *Con:* requires seeding one `space_anchors(kind='base')` per
  player so the recovery destination has a *canonical* coordinate (not legacy `x/y`).
- **R-B — Recover to nearest eligible port (anchor).** Return to the closest active
  `space_anchors(kind='location')`. *Pro:* port-centric and lore-consistent. *Con:* "nearest"
  needs canonical distances over a fully-seeded port graph; until seeding is complete some
  players could have *no* eligible port in range → softlock risk. Not safe as the **floor**.
- **R-C — Designated spawn/haven port(s).** One or more guaranteed-always-active "haven" ports
  (a curated `safe_zone`) act as the universal fallback. *Pro:* a single always-valid target
  removes per-player seeding from the *floor*. *Con:* needs at least one anchored haven seeded
  and kept active forever.

### Recommendation → **R-A as the guaranteed anti-softlock FLOOR, R-C as the player-facing default, R-B deferred.**

**Anti-softlock rule (invariant):** *A player must always have at least one valid, canonically
anchored recovery destination.* Guarantee it in this priority order:

1. **Floor (always valid):** the player's **bootstrap base**, which carries exactly one
   `space_anchors(kind='base', status='active')` recovery anchor. The census proves this target
   exists and is unique for all 72 ships → no player can be left without a return point. Recovery
   to the base is an **explicit recovery action**, never ordinary navigation.
2. **Default (preferred):** if a curated **haven port** (R-C, an anchored `safe_zone`) exists and
   is active, recovery routes there for fiction/UX. If the haven is unavailable, fall through to
   the base floor.
3. **Destroyed ships** respawn at the floor (base anchor) with defined HP/cooldown (balance TBD,
   not decided here).
4. **Stranded `in_space`** ships get an explicit "emergency recover" command → floor anchor.
   This is recovery, not movement; it does not read legacy `x/y`.
5. **Port pulled out from under a docked ship** (`status` flips off `active`): the ship is
   treated as stranded and is eligible for emergency recovery to the floor.

This makes "you can never be permanently stuck" a *structural* guarantee backed by the census,
while keeping the player-facing story port-centric. It is also the **only** sanctioned reason a
base ever gets a canonical anchor — recovery, not navigation.

> Decision needed: approve base-as-recovery-floor + haven-as-default; confirm we seed exactly
> one base recovery anchor per player (post-approval, §ssequence). Respawn balance is out of scope.

---

## 5. Anchor-seeding scope — what gets seeded first, what stays unseeded, how `space_anchors` becomes canonical without legacy `x/y`

**Question:** `space_anchors` is empty and dark. What is the *first* canonical coordinate set,
and how does it become authoritative without copying `locations.x/y`?

### Hard rule (from 0063 charter, non-negotiable)

`space_anchors` **must not be a backfill of `locations.x/y` or `bases.x/y`.** Legacy `x/y` are a
*dynamic display map*, not canonical OSN positions. Anchors must be **authored canonical
coordinates** in the `[-10000,10000]²` frame, even if some initially coincide numerically with a
legacy value — the *provenance* is "authored canonical," not "copied legacy."

### Options

- **S-A — Seed every active location + every base at once.** *Pro:* one migration, whole world
  anchored. *Con:* mass authored-coordinate work up front; couples the foundation to a final map
  layout we have *not* decided (§6); high blast radius for a first canonical write.
- **S-B — Seed only the initial port set first; everything else stays unseeded (recommended).**
  Generation 1 = the **eligible ports from §1** in the **dense central region** (§6), plus the
  **per-player base recovery anchors** required by §4's floor. Hostile sites, `event_site`s,
  out-of-region locations, and `is_public=false` locations **stay unseeded** (no anchor →
  resolver still returns `origin_not_anchored` for them → they remain non-navigable origins,
  which is correct). *Pro:* smallest first canonical write; matches eligibility + recovery
  decisions exactly; lets the port graph grow port-by-port. *Con:* a partially anchored world —
  acceptable because un-anchored = "not a port origin yet," not a bug.
- **S-C — Seed nothing; resolve ports from `locations` directly.** *Con:* violates the truthful-
  origin decision and the 0063 charter; rejected outright.

### Recommendation → **S-B, in this order, each additive + dark + service-role-only:**

1. **Port anchors:** one `space_anchors(kind='location', status='active')` per §1-eligible port
   in the §6 central region, with **authored** canonical coordinates (not copied from
   `locations.x/y`).
2. **Recovery base anchors:** one `space_anchors(kind='base', status='active')` per player base
   (the §4 floor), authored canonical coordinates.
3. **Everything else stays unseeded** until a deliberate later generation.

**How it becomes canonical (the cutover, post-approval, sequenced):**

- Seed anchors (dark) → **verify** (anchor exists, one-active-per-owner, in-bounds, finite) →
  then, and only then, extend the **resolver** so `at_location` resolves its origin from the
  ship's `docked_anchor_id → space_anchors.space_x/y` (replacing `origin_not_anchored` *for
  anchored ports only*; unanchored stays `origin_not_anchored`). Legacy `x/y` are never read.
- DOCK-0 docking likewise migrates from "exact match against `locations.x/y`" to "dock at the
  port's canonical anchor coordinate" — a later, separately-verified step, not part of seeding.

> Decision needed: approve seed generation-1 = (central-region eligible ports) + (per-player base
> recovery anchors); confirm authored-coordinate provenance (no `x/y` copy).

---

## 6. Initial central-region layout — dense core, outward expansion, coordinate preservation

**Question:** How is the first anchored region shaped, and how does the world grow without
breaking anything already placed?

### Fixed constraints (from the pivot, non-negotiable)

- Boundary stays **≈ `[-10000, 10000]²`** — a *temporary technical frontier*, not a lore edge.
  **No map-size expansion is authorized now.**
- Expansion grows **outward** and **preserves all existing coordinates** — never remap, move, or
  renumber an existing port, anchor, ship, or player position.
- Keep the initial central region **dense**; reserve outer space for later.

### Options

- **L-A — Dense central disc/box around origin.** Generation-1 ports occupy a small central
  region (e.g. roughly `[-2000, 2000]²`, exact radius TBD) around `(0,0)`; outer ring reserved.
  *Pro:* short early travel times, a legible "core," clean outward growth. *Con:* must choose a
  core radius (a balance knob, not decided here).
- **L-B — Spread ports across the full frontier immediately.** *Con:* long early travels, sparse
  feel, contradicts "keep the core dense / reserve the outside." Rejected.
- **L-C — Cluster ports by sector at sector coordinates.** Use existing `sectors.x/y` as cluster
  centers. *Pro:* reuses authored sector structure. *Con:* sector coords are part of the legacy
  *display* map; using them as canonical risks re-importing legacy layout we just declared
  non-canonical. Use as *inspiration* for authored anchors, not as a copy source.

### Recommendation → **L-A: a dense authored central core, with an explicit "outward-only, preserve-everything" growth policy.**

- **Generation 1** ports + base recovery anchors are authored into a **dense central region**
  near `(0,0)` (core radius is a tunable to confirm; default proposal ≈ `[-2000, 2000]²`).
- **Growth policy (codified as a rule):** new content is authored at **larger radii**, monotically
  outward; **no existing anchor's coordinate is ever changed** (the 0063 immutability guard
  already enforces per-row coordinate immutability — relocation is retire+insert, which we will
  *not* use for world growth). The `[-10000,10000]²` bound is a movable technical frontier to be
  widened only by a *future, separately-authorized* decision — not now.
- **Preservation guarantee:** because anchors are immutable and seeding is additive, every
  coordinate placed in generation 1 is permanent; later generations only *add*.

> Decision needed: confirm dense-core approach + the core radius knob, and ratify "outward-only,
> never-remap" as a standing world-growth rule. (No boundary change is being requested.)

---

## 7. Recommendation — proposed canonical model + post-approval implementation sequence

### Proposed canonical model (one sentence each)

1. **Ports** = active locations with `activity_type='none'` in the type whitelist
   `{trade_outpost, safe_zone, rally_point}` (E-B).
2. **Dock identity of record** = `main_ship_instances.spatial_state='at_location'` +
   `docked_anchor_id → space_anchors`; `location_presence` is **activity-only** (D-C).
3. **Bases** = bootstrap + economy container + recovery candidate **only** — never an
   operational home or permanent ship origin; legacy `x/y` never canonical (B-A).
4. **Recovery** = guaranteed floor at the player's single census-proven **base recovery anchor**,
   preferred default to an anchored **haven** port; "always a valid recovery target" is a
   structural invariant (R-A + R-C).
5. **Seeding** = generation-1 only — central-region eligible ports + per-player base recovery
   anchors, **authored** canonical coords; everything else stays unseeded; legacy `x/y` never
   copied (S-B).
6. **Layout** = dense authored central core, **outward-only, never-remap** growth, frontier
   `[-10000,10000]²` unchanged (L-A).

### Exact implementation sequence — authorized ONLY after this packet is approved

Each step is **additive + dark + service-role-only where applicable**, verified on the
disposable real-chain before any production-gated apply, with **both flags unchanged** until the
final, separately-authorized enablement. Migrations would continue from **0064**.

| # | Step | Nature | Gate |
| --- | --- | --- | --- |
| **S0** | **Record decisions** in `docs/SYSTEM_BOUNDARIES.md` + `DEV_LOG.md` (port definition, dock identity, base role + 3 exclusions, recovery invariant, seeding rule, growth rule). | docs only | this approval |
| **S1** | **Eligibility view/helper** (dark, read-only): a server-side predicate enumerating port-eligible locations from existing columns. No new authored data, no writes. | additive, read-only | S0 |
| **S2** | **Dock-identity column** (additive, dark): `main_ship_instances.docked_anchor_id → space_anchors(id)`, NULL, with the invariant `docked_anchor_id NOT NULL IFF spatial_state='at_location'`. No backfill, no writer yet. | additive schema | S1 |
| **S3** | **Seed generation-1 anchors** (dark): authored central-region port anchors + per-player base recovery anchors into `space_anchors`. **No `x/y` copy.** Verify one-active-per-owner / bounds / finiteness on disposable chain. | seed (anchors only) | S2 |
| **S4** | **Resolver extension** (dark): `at_location` resolves origin from `docked_anchor_id → space_anchors.space_x/y` (anchored ports only; unanchored stays `origin_not_anchored`). Legacy `x/y` never read. | resolver replace | S3 + S3 verified |
| **S5** | **Docking cutover** (dark): DOCK-0 docks at the port's canonical anchor coordinate instead of exact `locations.x/y` match; writes `docked_anchor_id`. | docking primitive | S4 |
| **S6** | **Recovery path** (dark): explicit emergency-recover RPC → floor base anchor (haven default); enforces the anti-softlock invariant; never ordinary navigation. | additive RPC | S5 |
| **S7** | **Enablement** (separate, explicitly authorized): flip `mainship_space_movement_enabled` only after S1–S6 are verified green and a go/no-go is recorded. | flag flip | separate approval |

**Not authorized by this packet (still deferred):** any flag flip (S7 is its own decision), any
boundary/map-size change, mass anchoring beyond generation 1, economy/buildings/training work,
hostile-site or `derelict_station` port modes, respawn balance, and **rerunning the census**.

---

*Packet is design/product only. Approve the §7 model (or amend per-section), and S0–S7 becomes
the authorized work list. Until then, baseline holds: migrations end at 0063, both flags as-is,
OSN paused.*
