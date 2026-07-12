<!-- WORLD-RECON-F1 (second run) — read-only recon, PORTCENTRIC_DECISION_PACKET.md Part E §1-10.
     Produced 2026-07-12 at migration head 0177 by the full-capacity plan queue (#14).
     PRECONDITION for F2′ sign-off: a read-only PRODUCTION live-state check (flag values, revealed
     port set, anchor rows, world_sites absence) — repo evidence alone cannot prove live state
     (finding §10.6). -->

# WORLD-RECON-F1 — Read-Only World Model Recon (second run, migration head **0177**)

**Charter:** `docs/PORTCENTRIC_DECISION_PACKET.md` Part E §1–10 (F1 in the Part F sequence).
Read-only; nothing was edited.

**Critical framing finding (read first):** this is the **second** F1. A prior F1 ran at baseline
`bd927f3` / head **0063**, and its output already produced an **approved F2 packet**
(`docs/F2_COMPATIBILITY_MODEL_DECISION_PACKET.md`, §1 ledger: Option C `world_sites` + immutable
bridge, closed anchors, port-first capability, dual-path docking, ship-row recovery). Since then
**114 migrations (0064–0177)** landed, several flags were flipped operationally, and the world model
evolved in ways that **contradict parts of the approved F2 direction**. This recon therefore answers
the ten questions against the *actual* head and treats the existing F2 packet as a stale input that
F2′ must revise, not confirm.

---

## §1 — World-object identity & the `location_type` switch

**The feared "giant type switch" is dead in SQL and alive only in display code.**

- Schema: `locations.location_type` is still the closed 8-value CHECK —
  `supabase/migrations/20260616000002_world_map.sql:52-56`; `activity_type` at `0002:61-64`;
  `status {active,locked,hidden}` at `0002:68-69`; `is_public` at `0002:67`.
- **No server function branches on `location_type`.** Occurrences in migrations are only: the 0002
  definition/seed, seed literals (`20260618000066…sql:45-48`, `20260618000175_zones2_ember_reach.sql:92-101`),
  and the `get_world_map` display projection (`0002:114`). Dockability/legality is decided by
  `physical_role` + services + anchors instead (`20260618000067…sql:89-99`).
- The durable physical identity axis was **added post-packet**: `locations.physical_role ∈
  {unclassified, city, port, station, landmark, activity_site}`
  (`20260618000065_worldhub1a_location_role_services_homeport.sql:27-29`), explicitly documented as
  separate from `location_type`/`activity_type` (`0065:20-26`).
- `activity_type` remains the runtime combat/presence truth (target legality rejects
  `activity <> 'none'`, `0067:90-91`; hunt sends gate on it) — exactly as F2-3 froze it.
- **Frontend residue:** the UI still *infers dockable-port display* from `location_type`:
  `src/features/portentry/portEntry.ts:111,134` (`isDockablePortForDisplay(loc.location_type)`),
  `src/features/portentry/PortEntryPanel.tsx:121`, `src/features/map/markerStyle.ts:37-75`, with the
  coupling risk self-documented at `src/features/map/mapTypes.ts:22-34`. This can silently diverge
  from the `location_services` truth (a `trade_outpost` without a docking service would *display*
  dockable).
- **Stable identity is solved in practice:** fixed literal UUID PKs are the identity convention
  (`0066:40-43`; renames in `20260618000148_location_names_single_word.sql:29-34` prove name is
  mutable display data; `0175:73-77` repeats the idiom). Coordinates were even *moved* under stable
  identity (`20260618000154_map_declutter_waypoints.sql`) without breaking anything.

**What fuses identity to type today:** nothing on the server; only the UI display mapping. **What
must change to introduce a stable ID:** nothing — `locations.id` already *is* the stable ID, and it
has become dramatically more load-bearing (see §9/§10).

## §2 — `space_anchors.kind` generalization

- The schema is byte-identical to 0063: closed `kind ∈ {base,location}` (`20260618000063…sql:30`),
  exactly-one-typed-owner CHECK (`0063:42-45`), ±10000 finite CHECK (`0063:50-54`),
  one-active-per-owner partial uniques (`0063:59-65`), retired-is-terminal immutability trigger
  (`0063:71-101`), base-CASCADE vs location-RESTRICT (`0063:32-33`).
- It is **no longer dark**. Three `kind='location'` anchors are seeded for the starter ports, exactly
  aligned to `locations.x/y` (`20260618000066…sql:51-54`) and are load-bearing in: origin resolution
  (`0067:451-468`), target legality (`0067:97-108`), Dock-0 arrival revalidation + anchor-snapshot
  exact match (`0067:543-572`), reveal invariants (`20260618000068…sql:94-101`), and home-port
  eligibility (`0066:85-86`). **No base anchor was ever seeded.** F2-2 (keep closed, location-only)
  was followed exactly.
- **Generalization pressure never materialized** — because new non-dockable world-object kinds
  *bypassed anchors entirely*: `exploration_sites` and `mining_fields` carry their own `space_x/space_y`
  with the 0055 CHECK idiom copied verbatim (`20260618000098…sql:41-42,54-57`;
  `20260618000103…sql:53-54,66-69`). The world now has **three coordinate authorities**:
  `space_anchors` (dockable ports), `locations.x/y` (legacy map/travel — still live-read at send time
  by the legacy movement path, `0154:26-29`), and per-table `space_x/y` (proximity content).

## §3 — Zone geometry reality (what zones actually DO)

- `zones.x, y, radius` (`0002:31-33`): **`radius` is consumed by zero SQL logic** — the only
  migration occurrences are the 0002 definition and the Ember Reach seed value (`0175:86-88`). It
  flows through `get_world_map` (`0002:106`) into `mapTypes.ts:55`, but the client renders no
  zone/sector visuals at all (`0175:50-51`: "nothing renders zones/sectors as visuals — verified").
- What zones/sectors actually do: (a) **hierarchy + status gating** — `get_world_map` filters all
  three levels on `status='active'` (`0002:121,125,129`, structurally *pinned* by the 0175
  self-assert at `0175:163-171`); target legality and docking require active zone+sector
  (`0067:87-88`); (b) **dynamic state rollup** (`zone_state`, migs 0031–0034, unchanged;
  World-Balance P19 extends `location_state.pressure` from combat defeats,
  `20260618000135…sql:4-9,26-30`); (c) display stats.
- **Real circle geometry now exists — just not on zones:** `osn_distance` is the shared Euclidean
  leaf (`20260618000099…sql:45-53`), and scan/extract enforce center+radius containment against a
  tunable 750-unit radius (`0099:174-183`; `20260618000104…sql:147-155`). Bounded-region
  (center+radius) zone membership is therefore **proven feasible in plain SQL on this stack** — no
  PostGIS needed.
- **Route↔zone intersection still exists nowhere.** Movement geometry is straight-line interpolation
  only (`0067:790-793`). A8's segment-circle intersection would be new math, but of the same
  complexity class as `osn_distance`.

## §4 — `docked_anchor_id` / `last_safe_dock_anchor_id` feasibility

- **Neither column exists anywhere in `supabase/`** (repo-wide grep hits only the two decision docs).
  F2-5/F2-6 remain unimplemented.
- The invariant substrate is unchanged: `spatial_state` domain + coords-iff-`in_space` CHECKs
  (`20260618000054_mainship_spatial_state.sql:40-75`) — `at_location` still forbids coordinates, so
  the asymmetric invariant (`docked_anchor_id ⇒ at_location`, not conversely) remains the right shape.
- **The compatibility surface changed materially — mostly favorably:**
  - There are now **two dock-settling routes**: OSN Dock-0 (`0067:499-627`) and the legacy arrival
    path (`20260618000153_mainship_legacy_arrival_docks_ship.sql`), which deliberately extracted
    **one shared docked-ship write helper** used by both ("the docked-ship write now lives in exactly
    one" place — 0153 header). That helper is the **single natural attach point** for setting
    `docked_anchor_id` + `last_safe_dock_anchor_id`, far better than the 0063-era world where DOCK-0
    was an exact-`locations.x/y` match.
  - Dock-0 already revalidates the anchor at arrival and refuses moved anchors (`0067:564-572`), so a
    verified-dock-only update rule has a concrete hook.
  - **Caution:** current dock *identity* is effectively the validated `fleets.current_location_id` —
    a fleet-held pointer read by dock-services (`20260618000069…sql:57-66`), trade
    (`20260618000092…sql:40-50` `mainship_resolve_docked_location`), station storage, and origin
    resolution (`0067:451-455`). F2-6's evidence that fleet-held pointers don't survive
    destroy/repair still holds, so the recovery pointer must be ship-row-held, as approved.
- **Recovery target does not exist:** "Haven Prime" appears only in the two decision docs. The de
  facto shared recovery-ish port is **Haven (`b1a00001-0066-…-000000000001`)**: the server-fixed
  commissioning spawn port (`20260618000072…sql:14-19`) and the station-storage backfill target
  (`20260618000157…sql:38-45`). F2-6's "Haven Prime fallback" should be re-pointed at this real,
  revealed port rather than an unseeded (0,0) five-port core.

## §5 — `location_services` coverage vs the type switch

- Table: `20260618000065…sql:35-43` — `service ∈ {docking, market, repair, refit, recruitment}`,
  `status {active,disabled}`, unique per (location, service), server-only.
- **Only `docking` is real.** It is the authority in target legality (`0067:93-95`), home-port
  eligibility (`0066:83-84`), Dock-0 revalidation (`0067:544`), and reveal invariants
  (`0068:103-108`). The only seeded service rows are the three docking rows (`0066:57-60`).
- **Every other capability was built as a per-feature satellite table keyed on `locations.id`,
  bypassing `location_services`:** market = `market_offers` rows (`20260618000085…sql:26`, seeded
  per-port in `0173`); salvage = `port_item_demand` (`20260618000174_salvage_market.sql:77,129`);
  haul contracts = per-port generated offers (`20260618000176…sql:101-102,161-162`); investment =
  `location_invest` ledger (`20260618000132…sql:88`); station storage = `bases.location_id` stores
  (`0157:33`); world events (`20260618000139…sql:64`). The A3 "composable capabilities" vision
  exists — but as N independent tables, not the unified capability table.
  `get_my_current_dock_services` (`0069`) surfaces the `services` array to the UI, so the
  fragmentation is also a UI-truth gap: a port with a market has `market_offers` rows but no
  `'market'` service row.

## §6 — Reveal / lifecycle machinery state

- **Reveal is the established content-cadence mechanism**: seed hidden → human runs a one-way,
  all-or-nothing, invariant-asserting reveal operation. Primitive: `reveal_starter_ports()`
  (`0068:23-127`; explicit "NO unreveal", `0068:12`). Generalized by convention, not by function:
  Ember Reach ships hidden with its own reveal script (`0175:1-8`; `scripts/reveal-ember-reach.{sql,sh}`),
  and runbooks exist (`docs/REVEAL_STARTER_PORTS_RUNBOOK.md`, `docs/POSTREVEAL_VERIFY_RUNBOOK.md`).
- Lifecycle vocabulary in practice: locations/zones/sectors `{active,locked,hidden}`
  (`0002:21-22,39-40,68-69`); anchors `{active,retired}` terminal-retired (`0063:38,77-95`); services
  `{active,disabled}` (`0065:39`); exploration/mining `is_active` soft-disable (`0098:44-47`,
  `0103:56-58`). **No `draft/retired/archived` states, no port-retirement/evacuation machinery** —
  F2-7's schema remains open, but the safety rules are being honored: no migration hard-deletes world
  content (TRUNCATE appears only in the dev runtime-churn cleanup `0045:18`; the retention cleaner is
  delete-batched, runtime-only, "NEVER TRUNCATE" `0047:3`); anchors are RESTRICT-protected;
  `bases.location_id` is RESTRICT (`0157:31-33`).
- **Two hiding regimes now exist:** `status='hidden'` locations are still raw-readable via public RLS
  (accepted teaser, `0175:53-55`), whereas exploration/mining content is truly server-only (RLS with
  no policy/grant, `0098:60-63`). A lifecycle decision should name this distinction rather than
  inherit it accidentally.

## §7 — Coordinate envelope + world-range reality

- **±10000 consumer count grew from ≥6 to ≥10 in the DB alone:** 0055 (movements CHECK), 0057
  (`c_lo/c_hi`), 0060, `0063:50-54`, `0067:106,133-134`, `0068:97`, `0098:54-57`, `0103:66-69`,
  `0175:186-188` — plus frontend `openSpaceTransform.ts:36-38` (`WORLD_MIN/MAX`, span 20000) and
  `galaxyCamera.ts:14-17`. There is still **no shared constant**; an envelope change is now strictly
  more expensive than when Part B was written. The deferral (F2-8) remains correct.
- Part B's four-concept separation is **holding**: authored content extent (ports bbox x −50…70,
  y −30…80 per `0154`; Ember Reach to (150,130), `0175:38-39`; exploration/mining out to ±4200,
  `0098:99-112`, `0103:143-158`) ≪ envelope; travel limits enforced by
  `max_coordinate_travel_seconds` (`0067:318-322`); viewport is a content-fit camera concern (`0154`).
- **New range-adjacent fact:** free coordinate travel is server-gated OFF by a *second* flag
  `mainship_coordinate_travel_enabled` (`20260618000070…sql:18-24`), while
  `mainship_space_movement_enabled` is **TRUE on live** for port-to-port (`0070:4`). But
  exploration/mining sites sit at up to ±4200 and require a settled `in_space` ship within 750
  units — those features are **unreachable until free coordinate travel is enabled**. The
  coordinate-travel flag, not the envelope, is the binding world-range decision for the next
  activation.

## §8 — What Gen-1-style expansion seeding requires (as-built recipe)

The D2 five-port plus-core at ±2000 was **never seeded**; the real Gen-1 is 3 ports at (−50,−30),
(70,−10), (10,80). The proven seeding recipe, extracted from `0066`/`0173`/`0175`:

**New dockable port (one fail-closed migration + one reveal script):** fixed-literal-UUID `locations`
row (active parents, `physical_role ∈ {city,port}`, `activity_type='none'`, `status='hidden'`) —
`0066:41-48`; exactly one active `space_anchors(kind='location')` row with `space_x/y` **exactly
equal** to `locations.x/y` (`0066:50-54`; Dock-0 snapshot match `0067:564-572`; the 0154 standing
invariant for relocation: move both in one migration, retire+insert the anchor); exactly one active
docking `location_services` row (`0066:57-60`); economy rows (`market_offers` per good `0173`,
optional `port_item_demand` `0174`, haul templates `0176`); optional per-player station stores via
`bases.location_id` (`0157`); then the one-way reveal operation with full structural invariants
(`0068:75-123`).

**New activity zone (Ember Reach pattern, `0175`):** active sector+zone containers, hidden fixed-UUID
sites, **self-asserting** migration proving monotonic difficulty/power/distance gates
(`0175:141-150`), game-wide name uniqueness (`0175:154-158`), get_world_map filter pinned
structurally and behaviorally (`0175:163-181`), envelope + bbox-disjointness (`0175:185-191`), marker
separation ≥ ~9% of content span (`0154`, `0175:40-42`), and **no anchors/services for non-dockable
sites** (`0175:61-63`).

## §9 — D4 decision inputs (what F2′ must choose between)

**D4-1 identity.** F2-1's Option C (`world_sites` + bridge) was approved but **never built** — the
only trace is a comment (`0072:16`). Meanwhile the "frozen legacy projection" grew ~9 *new* FK
consumers plus two feature columns (`physical_role`, and `bases.location_id` pointing *into* it),
i.e. `locations.id` is now the de facto canonical world-object ID with ~17 FK consumers. Realistic
options now:
- **(a) Ratify locations-as-identity** (abandon `world_sites`): matches all shipped code; zero
  migration cost; cost = the dumping-ground concern is accepted permanently. *Evidence for
  viability:* the type switch is display-only (§1), identity is UUID-stable, satellite tables have
  kept `locations` itself narrow (only `physical_role` was added to the row since 0002).
- **(b) Build `world_sites` now**: the bridge surface roughly tripled since approval; every new
  satellite table would eventually need re-pointing; no shipped system needs it. *Maximal cost, no
  current demand.*
- **(c) Hybrid (recommended input):** `locations.id` stays canonical for point-like *map* content;
  new non-map world-object kinds continue getting their own tables (the
  `exploration_sites`/`mining_fields` precedent, §2/§10) — effectively what the codebase already
  decided by behavior. F2′ should say this out loud and retire the `world_sites` plan or re-scope it
  to the (still unmet) universal-layer trigger of F2-1.

**D4-2 anchors.** Keep closed `{base,location}` — F2-2 is working live and generalization pressure
was absorbed by the per-table `space_x/y` pattern. Decide instead whether that third coordinate-truth
pattern is *policy* (name it) or *debt* (fold future proximity content into anchors).

**D4-3 capabilities.** The unified capability table exists (`location_services`) but only `docking`
is real; markets/salvage/haul/storage/invest became satellite tables (§5). Choose: retrofit
(`'market'` etc. rows + consumers — touches live trade paths) vs ratify
satellite-tables-as-capabilities (cheap, but `get_my_current_dock_services` and the UI never see a
unified truth, and the `portEntry.ts` display-inference bug class stays open).

**D4-4 zone geometry.** Center+radius containment is proven cheap (`osn_distance`, §3). If dangerous
zones are wanted, the missing pieces are: zone rows gaining *consumed* geometry, and segment-circle
intersection for routes — both plain SQL. Nothing built forecloses A8; OSN remains grep-clean of
combat/danger.

**D4-5 dock/recovery fields.** Attach `docked_anchor_id`/`last_safe_dock_anchor_id` writes to the
**one shared docked-ship helper** (0153) so both dock routes (OSN + legacy arrival) stay coherent;
extend `mainship_space_validate_context`; re-point the fallback from unseeded "Haven Prime" to real
**Haven `b1a00001…`** (`0072:14`); reconcile with the two other recovery-ish concepts that now exist
(`player_home_port` 0065, fixed spawn port 0072).

**D4-6 envelope.** Defer, unchanged — but note the consumer list grew (§7) and the *actual* near-term
range decision is the `mainship_coordinate_travel_enabled` flip that exploration/mining activation
requires.

## §10 — NEW findings (post-packet systems the authors couldn't know)

1. **OSN is live.** Port-to-port movement is enabled in production (`0070:4`); starter ports are
   revealed (reveal/post-reveal runbooks + scripts); DOCK-0 has been **anchor-based since 0067** —
   `locations.x/y` is consulted nowhere in OSN (`0067:36`, `0154:31-33`). The packet's "OSN PAUSED,
   anchors dark" baseline is history.
2. **Team command activated 2026-07-12** (`src/features/map/osnReleaseGates.ts:26-29,37-41`; `0160`;
   `0170`; `0171`): ship cap 3→24 (`0160:66-71`), hull combat stats (`0170`), captain slots 2→6
   prepped (`0171`). Crucially, **group movement reuses the *legacy* expedition spine verbatim** —
   `send_ship_group_expedition` loops the live single-ship send inside one subtransaction and "writes
   NO … main_ship_space_movements row" (`20260618000163_slice_b_group_send.sql:1-16`). **Multi-ship
   play therefore runs on the legacy location/presence system, not OSN.** The legacy path — including
   its live `l.x/l.y` distance read at send time (`0154:26-29`) — became *more* load-bearing on
   activation day. F2′ must drop the implicit assumption that legacy is a shrinking projection: today
   **OSN is the solo port-to-port lane; legacy is the growth lane.** Any dock-identity/recovery field
   must cover both (the 0153 shared helper is the bridge).
3. **Ember Reach (`0175`)** is the first content expansion and codifies the seeding law (§8): fixed
   UUIDs embedding the migration number, self-asserting migrations, hidden-until-reveal cadence,
   monotonic distance/difficulty gates, first honest `physical_role='activity_site'`, and **no
   anchors for non-dockable content**. Content expansion is now a repeatable data-only operation —
   Gen-1 seeding (F4) is largely de-risked.
4. **Independent coordinate world objects shipped**: `exploration_sites` (0098) and `mining_fields`
   (0103) are precisely the "active independent (non-location-backed) world sites" F2-1A §5 declared
   unsupported — built anyway as standalone tables with their own OSN-convention coordinates, no
   bridge, no anchors, server-only RLS, and `osn_distance` proximity interaction. This is the
   strongest single input to D4-1: the codebase already chose "new kinds get new tables."
5. **`bases` was repurposed** from "bootstrap-only, never spatial" (A7) into the per-(player, port)
   **station-storage primitive** via `bases.location_id` (`0157:5-11,31-45`), backfilled onto Haven.
   Bases still own no coordinates, but the A7 sentence "never operational" is now false in the
   storage sense.
6. **The activation wave is operational, not migratory**: 22 dark flags exist (all seeded `'false'`
   in migrations), flipped by human-run `scripts/activate-*` scripts. Currently lit per repo
   evidence: OSN port-to-port, mainship send, team command, additional commissioning, modules
   (`osnReleaseGates.ts:26-29,37-41`); captains are the prepped fast-follow (`0171`); trade market
   and free coordinate travel remain dark (`osnReleaseGates.ts:25`, `0070:21`). **The repo cannot
   prove live flag state** — comments and scripts are the only witnesses.
7. **Living-world dynamics landed on the existing state split** (W-B P19: defeat-driven pressure
   `0135`, price drift `0136`, field depletion `0137`) — the identity↔state separation the packet
   praised generalized cleanly, validating F2-4's "separate layers" instinct.
8. **Ownership boundaries held** (Part E §10): `SYSTEM_BOUNDARIES.md` is actively maintained by
   migrations (0098/0103/0176 headers), no universal location RPC appeared (`0069:7-8` explicitly
   disclaims it), and cross-system access keeps being extracted into narrow named leaves (`0092`,
   `osn_distance` 0099).

---

## GO/NO-GO recommendation for F2

**GO — but as F2′ (a revision), not a first decision.** The F1→F2 loop already ran once; what gates
further schema work now is *reconciling the approved F2 packet with 114 migrations of contrary or
superseding fact*. Concretely: F2-2/F2-3/F2-7-safety/F2-8 were followed and can be re-affirmed
cheaply; **F2-1/F2-1A (world_sites + frozen locations) were overtaken by events** and must be
re-decided (§9 D4-1, options a/c favored by all shipped evidence); F2-5/F2-6 remain unbuilt but now
have *better* attach points (0153 shared helper; real Haven fallback) and one new obligation (cover
the legacy dock route that team command just made primary).

**Highest-risk unknowns (name-checked):**
1. **Live-state opacity.** Flags, reveals, and seeds are flipped/run operationally; this recon proves
   only repo intent (`0070:4`, gate constants, runbooks). A read-only production check (flag values,
   revealed-port set, anchor rows, `world_sites` absence) must precede any F2′ sign-off — schema
   decisions keyed to a wrong live baseline are exactly how the first F2 went stale.
2. **Dual movement/docking spines.** OSN (solo, anchor-authoritative) and legacy (teams/hunts,
   `locations.x/y`-reading) both settle ships into `at_location` through one shared helper but arrive
   there by different legality rules (`0067:60-112` vs the legacy dockable/non-dockable split in
   `0153`). Adding `docked_anchor_id`/`last_safe_dock_anchor_id` without a single written invariant
   covering *both* writers risks silent divergence — the exact bug class 0152/0153 just spent two
   migrations fixing.
3. **Capability-model fork.** Retrofitting `location_services` versus ratifying satellite tables (§5)
   is a one-way door: retrofit touches live trade/salvage/haul writers; ratification permanently
   forecloses a unified capability read (and leaves the `portEntry.ts:134` display-inference
   divergence class open). Neither option is obviously wrong, which is why it must be decided
   explicitly, with the UI-truth surface (`get_my_current_dock_services`) in scope.
