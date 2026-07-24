# OSN-3 S6B-PRES-0 — Legacy → OSN-Only Cutover Audit (STRICT CLEAN-CUT, revised)

> **Status: AUDIT ONLY.** No code, no migration, no coordinate change, no flag change, no deletion, no
> commit/push, no PRES-1 / S6C / S6D / OSN-4. This revision **supersedes** the prior reconnaissance-grade
> PRES-0 and the preserve-legacy framing of `OSN3_S6B_PRES_CHARTER.md` §(Product direction / D / H).
> All file:line facts below were **verified against the working tree**, not carried over from recon.
>
> **Baseline (verified):** code/migrations/flags identical to `3c7e7a8` (HEAD `d74b289` is docs-only ahead);
> migrations through `0060`; `mainship_send_enabled=FALSE` (`0050:34`), `mainship_space_movement_enabled=FALSE`
> (`0055:188`); S6A deployed but dark; S6B closed; legacy named-location map/travel live. Pre-launch dev
> project, no real players.

## Locked direction — FULL CLEAN CUT (no long-term legacy compatibility)
The final architecture has exactly **one** of each: canonical galaxy coordinate system; fixed map renderer;
main-ship movement engine (**OSN**); arrival-interpretation layer; truthful galaxy map. It contains **none**
of: `buildNormalizer()`; content-derived dynamic bounds; `legacy_dynamic` / the `coordinateSpace`
discriminant; the old main-ship send/return/direct-move route or its UI; any permanent coordinate adapter or
compatibility bridge; obsolete legacy tests/workflows/docs after cutover. Old `x∈[9,33] / y∈[4,23]` location
values are **prototype data**, replaced later by a **hand-designed canonical galaxy** (NOT designed here, and
NOT a rescale of the prototype). Reusable concepts kept **only where still valuable** (named locations as
content; home/base; main-ship ownership/hulls/repair; combat/rewards/resources; generic fleet infra **iff
independently useful** — open product decision **D1**). **No old implementation is kept merely because it
exists.** Superseded and intentionally absent here: uniform-scale options, conservative/medium/broad rescales,
timing-preservation, permanent bridges, a separate free-space map mode, any indefinite `legacy_dynamic`.

**Disposition keys:** **R** = retain reusable domain concept (impl may be reworked) · **O** = replace with OSN
implementation (player behavior rebuilt before cutover) · **X** = retire completely (removed after replacement).

---

# A. Clean-cut dependency inventory (full retain / replace / retire table)

> "Safe deletion point" references the **D. Cutover sequence** steps (D1…D8). "Live/test" = whether the
> artifact is on a production code path or test/CI-only.

### A.1 — Legacy main-ship named-location travel (backend RPCs/cron)
| Artifact (file:line) | Current purpose | Direct callers / dependents | Live/test | Disp. | OSN replacement req? | Safe deletion point | Risk if removed early |
|---|---|---|---|---|---|---|---|
| `send_main_ship_expedition` (`0050:48-154`, refactor `0051:65-157`) | main-ship base→named location | client `sendMainShipExpedition`; gated `mainship_send_enabled` (`0051:88`) | live (dark) | **O→X** | yes (command + location-targeting) | D7 | client send breaks; flag is off so no prod impact |
| `move_main_ship_to_location` (`0053:14-113`) | main-ship location→location | client `moveMainShipToLocation`; gated `mainship_send_enabled` (`0053:34`) | live (dark) | **O→X** | yes (re-command from `in_space`) | D7 | client move breaks |
| `request_main_ship_return` (`0050:159-228`, refactor `0051:160-218`) | main-ship location→home | client `requestMainShipReturn`; **NOT flag-gated** | live | **O→X** | yes (recall-to-`(0,0)` affordance) | D7 | recall breaks; **note: ungated**, so reachable today |
| `process_mainship_expeditions` (`0050:234-258`) + cron `process-mainship-expeditions` 30s (`0050:260-266`) | legacy status reconciler | pg_cron only; service_role | live | **O→X** | S4 `process_mainship_space_arrivals` is the analogue | D7 | reconciler stops; only legacy `traveling/returning` ships affected |
| `mainship_send_enabled` flag (`0050:34-36`, default false) | legacy travel gate | read by send/move RPCs | live | **X** | — | D7 (with RPCs) | nothing (already false) |

### A.2 — Shared movement spine (unit-fleet ↔ main-ship), gated on D1
| Artifact (file:line) | Current purpose | Direct callers / dependents | Live/test | Disp. | OSN replacement req? | Safe deletion point | Risk if removed early |
|---|---|---|---|---|---|---|---|
| `movement_create` (`0007:68-125`) | distance→`fleet_movements` row; travel formula `:105-106` | `send_fleet_to_location`, all 3 legacy main-ship RPCs, `presence_request_leave` | live | **R / X(if D1=drop fleets)** | main-ship must stop calling it | D8 (after D1) | **deletes break unit fleets** — main-ship decouples first (D2) |
| `process_fleet_movements` (`0009:12-66`) + cron 30s (`0011:20-24`) | resolves `fleet_movements` arrivals; **on location arrival creates `location_presence` + starts activity** | pg_cron | live | **R / X(if D1)** | OSN must replicate the **docking** branch | D8 | **this is the legacy docking semantics OSN lacks** (Special-check 1) |
| `fleet_movements` table (`0007:9-46`) | generic travel rows | sole writer `movement_create`; reader `process_fleet_movements`; cleanup `0047:144-156` | live | **R / X(if D1)** | main-ship stops using it (uses `main_ship_space_movements`) | D8 | unit-fleet travel breaks |
| `send_fleet_to_location` (`0010:10-83`, refactor `0051:224-296`) | generic unit-fleet send | client fleet send UI | live | **R / X(if D1)** | n/a (unit-fleet, not main-ship) | D8 | unit-fleet dispatch breaks |
| `fleet_speed` (`0006:87-98`) | slowest-unit speed | `presence_request_leave`, `resolve_fleet_movement_speed`, `fleet_get_power` | live | **R / X(if D1)** | n/a | D8 | unit-fleet speed + leave break |
| `resolve_fleet_movement_speed` (`0051:32-61`) | routes `main_ship_id`→hull speed else `fleet_speed` | all 3 legacy main-ship RPCs, `send_fleet_to_location`, **`mainship_space_begin_move` (`0057:205`)** | live | **R** | no — **OSN uses it** | keep | OSN coordinate moves lose speed resolution |
| `fleets` table + `main_ship_id` (`0050:40-43`, write-once trig `0055:166-185`) + `active_movement_id` (`0007:55-57`) + `active_space_movement_id` (`0055:94-98`) + exclusion CHECK (`0055:102-103`) | fleet container & movement pointers | legacy + OSN both attach a main-ship fleet | live | **R (decouple)** | main-ship uses **only** `active_space_movement_id` post-cutover | columns: keep; legacy pointer cleared D6 | dropping pointers breaks both paths |

### A.3 — Frontend dynamic renderer (the ONE renderer is already built: `openSpaceTransform`)
| Artifact (file:line) | Current purpose | Direct callers / dependents | Live/test | Disp. | OSN replacement req? | Safe deletion point | Risk if removed early |
|---|---|---|---|---|---|---|---|
| `buildNormalizer` + `PAD` (`GalaxyMap.tsx:17,21-35`) + `norm` memo (`:78-86`) | content-derived dynamic bounds | 4 call sites below | live | **X** | `worldToViewBox` already exists | D5 | map placement breaks until swap done |
| `norm(...)` sites: home `:135`, movement endpoints `:164-165`, location markers `:205`, prop→marker `:225` | world→viewBox for each entity | `GalaxyMap` render | live | **X** | replace with `worldToViewBox` | D5 | wrong placement if swapped before canonical coords (D3) |
| `markerViewBoxPoint` legacy arm (`MainShipMarker.tsx:15-17` → `norm`) | ship legacy-state placement | `MainShipMarker.tsx:60` | live | **X** | fixed arm (`:18-19`) already exists | D5 (last) | ship marker mis-placed |
| `coordinateSpace` type + member (`resolveMainShipMarker.ts:22,31`) | legacy/fixed routing discriminant | resolver + marker | live | **X (collapse)** | becomes single-valued → removed | D5 | — (vestigial once legacy gone) |
| resolver `legacy_dynamic` returns (`resolveMainShipMarker.ts:121,131,147,157,161`) | at_location / home / legacy in-flight placement | resolver §D/§E/§F | live | **X** | open-space returns (`:82,:105`) remain | D5 | resolver loses legacy placement |
| `openSpaceTransform.ts` `worldToViewBox` (`:72-85`) + constants (`:35-40`) | the ONE world→viewBox map | marker fixed arm; future all entities | live | **R** | this **is** the replacement | keep | — |
| `FleetMovementLine.tsx`, `LocationMarker.tsx`, `LocationPanel.tsx` | pure presentation (pre-normalized input) | `GalaxyMap` | live | **R** | no — consume whatever transform feeds them | keep | — |
| `GalaxyMap` camera/pan-zoom (`:37-133`) + SVG frame (`viewBox 0 0 1000 1000`) | viewBox-local pan/zoom | independent of `norm` | live | **R** | no | keep | — |

### A.4 — Frontend main-ship UI / client API
| Artifact (file:line) | Current purpose | Direct callers / dependents | Live/test | Disp. | OSN replacement req? | Safe deletion point | Risk if removed early |
|---|---|---|---|---|---|---|---|
| `mainshipApi.ts` reads: `fetchMyMainShip:55`, `fetchActiveMainShipFleet:91`, `fetchActiveMainShipPresence:150`, `fetchActiveMainShipSpaceMovement:124`, `deriveMainShipStatus:168` | ship/fleet/presence/movement status | dashboard + map + resolver | live | **R** | no | keep | status/markers break |
| `mainshipApi.ts` writes: `sendMainShipExpedition:183`, `requestMainShipReturn:193`, `moveMainShipToLocation:210` | legacy travel commands | `MainShipCommand`, `MainShipPreview` | live | **X** | OSN command API replaces | D5 (UI) → callers gone | uncalled after UI removal |
| `repairMainShip:219` | repair recovery | `MainShipPreview:97`, `MainShipPanel:45` | live | **R** | no (travel-independent) | keep | repair breaks |
| `MainShipCommand.tsx` (`:17-153`; calls `moveMainShipToLocation:56`, `sendMainShipExpedition:59`) | legacy send/move command UI | `GalaxyMapScreen` (gated `mainshipSendEnabled`) | live | **X** | OSN command surface (S6C) replaces | D5 | no legacy travel UI (intended) |
| `MainShipPreview.tsx` recall block (`requestMainShipReturn:80`) | legacy recall UI | `GalaxyMapScreen` overlay | live | **X** | OSN recall affordance | D5 | recall UI gone (intended) |
| `MainShipPreview.tsx` ship-stats + repair (`repairMainShip:97`) | status/HP/repair display | overlay | live | **R** | no | keep | — |
| `MainShipPanel.tsx` (dashboard; repair `:45`, `deriveMainShipStatus:70`) | status + repair only | Dashboard (`:81-88`, gated) | live | **R** | no | keep | — |
| `MainShipMarker.tsx` component (`:34-74`) | pure ship marker | `GalaxyMap` | live | **R** (legacy arm only is X) | no | keep | — |
| `GalaxyMapScreen.tsx` wiring of `MainShipCommand`/`MainShipPreview` | mounts legacy travel UI on `mainshipSendEnabled` | route `/galaxy` | live | **O** | rewire to OSN command surface | D5 | — |
| `travelPreview.ts:9 distance()` (+ `slowestSpeed/previewTravelSeconds`) | **generic** travel preview math | fleet send preview (not main-ship) | live | **R / X(if D1)** | no | D8 (with fleets) | unit-fleet preview breaks |

### A.5 — Coordinate data & the OSN engine (for contrast / the replacement)
| Artifact (file:line) | Current purpose | Direct callers / dependents | Live/test | Disp. | OSN replacement req? | Safe deletion point | Risk if removed early |
|---|---|---|---|---|---|---|---|
| Prototype location seed `x∈[9,33] y∈[4,23]` (`world_map.sql:151-162`); **no CHECK** on `locations.x/y` | prototype layout | renderer + legacy movement coords | live | **X (reseed)** | canonical galaxy seed (PRES-1) | D3 | renderer/targeting wrong if changed alone |
| Base coords `(0,0)` (`base_system.sql` `initialize_new_player`); no CHECK | player home | renderer + return-home | live | **R** | value OK (home `(0,0)`) | keep | — |
| `main_ship_space_movements` table (`0055:21-77`, CHECK `[-10000,10000]`+finite; cols incl. `target_kind`,`target_location_id`,`target_base_id`) | OSN movement log | OSN writer/processor | live (dark) | **R** | this is the model | keep | — |
| `mainship_space_begin_move` (`0057:45-264`, gated `0057:131`, formula `:179-180`) | OSN coordinate writer (service_role) | `command_main_ship_space_move` (`0060:88`) | live (dark) | **R** | extend for location targets | keep | — |
| `process_mainship_space_arrivals` (`0058:25-116`) + cron 30s (`0058:129-133`) | OSN arrival → `in_space` (**no docking**) | pg_cron | live (dark) | **R / O** | **must add location-docking** (blocker) | keep | — |
| `command_main_ship_space_move` (`0060:38-134`, canonicalizes target) | S6A public wrapper (authenticated) | future S6C UI | live (dark) | **R** | UI (S6C) + location-target form | keep | — |
| `mainship_space_movement_enabled` flag (`0055:188-191`) | OSN gate | writer (auth) + wrapper (defense) | live | **R** | flip ON at cutover (D4); flag itself retire only at end-state | keep→opt-X | premature ON exposes incomplete OSN |

### A.6 — Tests / verifiers / workflows / dev-tools / docs (see **C. Deletion inventory** for the exact list)
| Group | Disp. | Notes |
|---|---|---|
| `verify-mainship-{send,move,repair,preview}.mjs` + matching `.yml` + `package.json` `verify:mainship-*` (×4) | **X** | pure legacy-main-ship RPC proofs |
| `dev-mainship-flag`, `dev-commission-mainship`, `dev-destroy-mainship` (`.mjs`+`.yml`) | **X** | legacy flag/fixture tooling |
| `osn3-legacy-send-live-check.sh` + `osn3-legacy-send-activation-check.yml` | **X** | legacy-send activation audit |
| `MAINSHIP_TRANSITION.md` | **X (supersede)** | legacy Phase-10 design spec |
| `resolveMainShipMarker.spec.ts` (legacy_dynamic assertions), `verify-speed-resolver.*` (legacy branch), `galaxy*.spec.ts` | **edit (not delete)** | strip legacy assertions; speed/galaxy parts ride on D1 |
| `dev-mainship-space-movement-flag.*`, `openSpaceTransform.spec.ts`, `devFixedSpacePreview.spec.ts`, `verify-osn*`, `verify-osn-resolver/s6b/s6b3` | **R** | OSN infra |
| `SYSTEM_BOUNDARIES.md`, `BYEHARU_PROJECT_GUIDE.md`, `DEV_LOG.md` | **R (update)** | update ownership/phase rows |

---

# Required special checks

## Special-check 1 — Main-ship legacy movement replacement gap
What the legacy route provides that OSN does **not** yet provide:

| Legacy behavior | Existing OSN equivalent | Missing replacement work | Required before legacy disable? |
|---|---|---|---|
| Travel to a **named location** | `command_main_ship_space_move` (coordinate-only `x,y`) | location→coordinate **targeting**; a `target_kind='location'` move form | **Yes** |
| **Return home** | command to `(0,0)` (mechanically works) | a **recall affordance** + home-arrival meaning (base presence) | **Yes** |
| **Location arrival** | `process_mainship_space_arrivals` → `in_space` only | **docking**: on location arrival create `location_presence` + start activity (port `process_fleet_movements` branch) | **Yes — THE BLOCKER** |
| **Presence / docking** | none (proximity ≠ docked) | establish `location_presence` for the main ship on arrival | **Yes** |
| **Command UI** | none (S6A wrapper is dark, headless) | S6C select/confirm + recall UI on the fixed map | **Yes** |
| **Travel ETA / status** | `main_ship_space_movements.depart_at/arrive_at` + resolver `in_transit` marker (`:105`) | a UI surface for ETA/status | **Yes (UI only)** |
| **Movement visualization** | resolver in-transit marker via `worldToViewBox`; `FleetMovementLine` is generic | route-line wiring for coordinate endpoints | Partial — nice-to-have at cutover |
| **Failure / retry** | wrapper maps reasons + `p_request_id` idempotency (`0060`) | — (covered) | No |
| **Repair / destroyed-state** | shared `repair_main_ship` + S5 destruction cleanup (unaffected) | — (covered) | No |
| **Player notifications / reports** | none either side (combat reports separate) | — (parity) | No |
| **Test coverage** | S1–S6A real-chain proofs exist | **acceptance parity**: command→travel→arrive→**dock**→recall, dark-proven | **Yes** |

**Conclusion:** the single hard blocker is **arrival-at-location → docking/presence/activity**. Targeting,
recall, command UI (S6C), and acceptance parity are the surrounding required work. Everything else is at parity.

## Special-check 2 — Named-location conversion gap (data model + arrival contract only)
Named locations stay as content; their **coordinates** do not. Questions to resolve (no actual coordinates
designed here):

- **Where canonical coords live:** the existing `locations.x/y` (`double precision`) and `bases.x/y` already
  match the OSN domain type. **Question (D-data):** replace the **values in place** + add a finite/bounds
  `CHECK [-10000,10000]` (mirroring `main_ship_space_movements`), **or** introduce a separate canonical model?
  *Provisional finding:* in-place value replacement + CHECK is sufficient — **no new coordinate model needed**;
  the schema already supports the canonical domain.
- **Data to reset / discard / migrate (pre-launch):** prototype `locations.x/y` + any base coords → **reseed**;
  active `fleet_movements` (main-ship + unit) + main-ship fleet legacy pointers → **reset**; historical/terminal
  movement rows → **discard** (no real-player history obligation). No coordinate **bridge** is created.
- **What "arrival at a named location" must mean in OSN terms:** a movement with **`target_kind='location'`**
  (and `target_location_id` set — columns already exist in `0055`) whose arrival, processed by
  `process_mainship_space_arrivals`, **establishes `location_presence` and starts the activity** — i.e. the
  legacy `process_fleet_movements` docking branch, ported. **Open question (D2-contract):** is docking keyed on
  `target_kind='location'`+`target_location_id` (recommended, explicit) or on coordinate proximity ε to a
  location? *Recommend the explicit kind/id contract* (no fuzzy proximity).

## Special-check 3 — Shared-system safety (don't delete what other systems use)
| System / object | Classification | Action before any legacy deletion |
|---|---|---|
| `fleets` table + `main_ship_id` + movement pointers | **currently shared; decouple** | main ship uses **only** `active_space_movement_id`; verify no main-ship fleet references `active_movement_id` before D7 |
| `movement_create` / `fleet_movements` / `process_fleet_movements` (+ cron) | **shared with unit fleets** | decouple main ship now (it already has `mainship_space_begin_move`); spine **stays iff unit fleets stay (D1)** |
| `resolve_fleet_movement_speed` | **reusable generic (OSN uses it)** | **retain** |
| `fleet_speed` | **unit-fleet-only** | retire **iff** unit fleets retired (D1) |
| `location_presence` / location ownership | **reusable generic** | **retain** — it is the **docking target** OSN must reuse (Special-check 1) |
| Combat / rewards / resources / world-state | **reusable generic** | **retain** — untouched |
| `repair_main_ship` + S5 main-ship destruction cleanup | **main-ship, NOT legacy-travel** | **retain** |
| Crons: `process-fleet-movements` / `process-mainship-expeditions` / `process-mainship-space-arrivals` | shared / legacy-only / OSN | retire #2 at D7; #1 only if D1=drop fleets; **retain** #3 |

**⚠ Gating product decision D1 — do generic unit fleets survive?** If the final game (Main Ship + Captains +
Modules + Support Craft) does **not** keep OGame-style disposable unit fleets, the **entire** generic spine
(`send_fleet_to_location`, `fleet_units`, `fleet_speed`, `movement_create`, `process_fleet_movements`,
`fleet_movements`, `travelPreview`, `galaxy9b` test) becomes **X** — a much larger retirement. If they survive,
all of that is **R** and only the **main-ship's use** of it is severed. **This decision sets the deletion scope
and must be made before D8.** It does **not** block the first slice (E).

## Special-check 4 — Cutover state policy
| State at cutover | Options | Recommendation |
|---|---|---|
| Active legacy main-ship movements | (a) clean reset (b) migrate to OSN rows (c) drain-then-cut | **(a)** — pre-launch, disposable; no bridge |
| Legacy linked fleets / pointers | reset `active_movement_id`; keep fleet/`main_ship_id` | clear legacy pointer at D6 |
| Active + historical movement rows | discard / archive-for-telemetry / migrate | **discard** (archive optional, out-of-band) |
| Test users & fixtures | existing `verify-cleanup` / `dev-clean-test-users` | use existing cleanup |
| Prod vs dev data | pre-launch → prod is disposable | treat prod data as resettable |
| Rollback **before** deletion (D1–D6) | git revert + **flag flip back** (additive migrations, reversible) | fully reversible — flags are the safety valve |
| Rollback **after** deletion (D7–D8) | git history / down-migration only — **irreversible** for dropped objects | gate deletion last; require green acceptance + a tagged pre-deletion commit |

**Clean reset acceptable at this stage?** **Yes.** No real players, no history obligation, no compatibility
contract. **Recommended policy: clean reset (Option a) + discard history + reversible-until-D6.**

---

# B. OSN replacement checklist (must exist before legacy main-ship travel is disabled)
1. **Arrival-at-location docking** — `process_mainship_space_arrivals` establishes `location_presence` +
   starts the activity for `target_kind='location'` arrivals. *(The blocker.)*
2. **Location targeting** — a `target_kind='location'` move form in `mainship_space_begin_move` /
   `command_main_ship_space_move` (resolve a chosen location → its canonical coordinate).
3. **Recall-to-home affordance** — command to `(0,0)` with a clear home/base-presence arrival meaning.
4. **Player command surface (S6C)** — select/confirm a destination + recall, on the fixed map, calling the
   S6A wrapper. *(No tap-wiring exists today.)*
5. **Canonical coordinates for locations/base** (PRES-1 data) — so targeting/docking/rendering are truthful.
6. **Controlled enablement (S6D)** — flip `mainship_space_movement_enabled=true` (reversible) after proofs.
7. **Acceptance parity** — command → travel → arrive → **dock** → recall, proven end-to-end (real-chain),
   before the flag flip.

*(Not blockers: OSN-4 Stop/mid-travel halt — QoL. Repair/destroyed — already at parity.)*

# C. Deletion inventory (removable **after** cutover)
**Backend (migration-dropped objects, D7):** `send_main_ship_expedition`, `move_main_ship_to_location`,
`request_main_ship_return`, `process_mainship_expeditions` (+ its cron), `mainship_send_enabled` flag.
**Backend (only if D1 = drop unit fleets, D8):** `send_fleet_to_location`, `movement_create`,
`process_fleet_movements` (+ cron), `fleet_movements` table, `fleet_speed`, the `fleets.active_movement_id`
pointer.
**Frontend (D5):** `buildNormalizer` + `PAD` + `norm` (4 call sites) in `GalaxyMap.tsx`; the
`markerViewBoxPoint` `legacy_dynamic` arm; the `coordinateSpace` discriminant + the 5 `legacy_dynamic` resolver
returns; `mainshipApi` `sendMainShipExpedition`/`requestMainShipReturn`/`moveMainShipToLocation`;
`MainShipCommand.tsx`; `MainShipPreview` recall block. *(Only if D1: `travelPreview.ts`.)*
**Tests / verifiers / workflows / dev-tools (D7–D8):** `scripts/verify-mainship-{send,move,repair,preview}.mjs`
+ `.github/workflows/verify-mainship-{send,move,repair,preview}.yml`;
`scripts/dev-mainship-flag.mjs|.yml`, `scripts/dev-commission-mainship.mjs|.yml`,
`scripts/dev-destroy-mainship.mjs|.yml`; `scripts/osn3-legacy-send-live-check.sh` +
`.github/workflows/osn3-legacy-send-activation-check.yml`; `package.json` `verify:mainship-*` (×4).
**Edits (not deletions):** `resolveMainShipMarker.spec.ts` (drop `legacy_dynamic` assertions);
`verify-speed-resolver.*` (drop legacy fleet-speed branch if D1); `galaxy.spec.ts`/`galaxy9b.spec.ts` (ride on
D1). **Docs:** `MAINSHIP_TRANSITION.md` → superseded; `SYSTEM_BOUNDARIES.md`/`BYEHARU_PROJECT_GUIDE.md`/
`DEV_LOG.md` → updated.
**Invariant:** nothing deleted while a live reference exists — order is **UI → client API → RPC → flag →
renderer → tests/tooling → (spine if D1) → docs**.

# D. Cutover sequence (numbered; rollback at each stage)
1. **D1 — Freeze + decide.** Freeze new legacy main-ship feature work (net-zero code). Make the **unit-fleet
   survival decision (D1)** and the **arrival contract (D2-contract)**. *Rollback: n/a.*
2. **D2 — Build OSN replacements (additive, dark, flag-gated).** Arrival-docking, location targeting, recall,
   S6C command surface — proven on synthetic coords; production unchanged. *Rollback: revert commits; flags
   still off.* **← E recommends starting the docking piece here.**
3. **D3 — Canonical galaxy coordinates (PRES-1 data).** Forward migration replaces location/base coords with
   the hand-designed canonical values + adds finite/bounds CHECK. No renderer/flag change; map still looks the
   same (dynamic normalizer fits any bounds). *Rollback: down-migration to prior values (pre-launch, safe).*
4. **D4 — Cutover flip (reversible).** `mainship_space_movement_enabled=true`, `mainship_send_enabled=false`
   after acceptance parity (B7). Legacy RPCs now unreachable but still present. *Rollback: flip flags back.*
5. **D5 — Unified renderer + remove legacy main-ship UI/API.** Swap the 4 `norm` sites → `worldToViewBox`;
   drop the `legacy_dynamic` marker arm; collapse/remove `coordinateSpace`; delete `buildNormalizer`/`PAD`;
   remove `MainShipCommand`, the `MainShipPreview` recall block, and the 3 legacy client write fns. *Rollback:
   git revert (frontend only).*
6. **D6 — Reset active legacy state.** Clear active legacy main-ship movements + legacy fleet pointers; discard
   historical rows. *Rollback: this is the last fully-reversible point (restore from a tagged snapshot).*
7. **D7 — Drop legacy main-ship backend + tooling (irreversible).** Migration drops the 4 RPCs + reconciler
   cron + `mainship_send_enabled`; remove legacy verifiers/workflows/dev-tools/`package.json` entries; supersede
   `MAINSHIP_TRANSITION.md`. *Rollback: only via git history / down-migration — gate on green acceptance + a
   pre-deletion tag.*
8. **D8 — (If D1 = drop unit fleets) retire the generic spine** + `travelPreview` + `galaxy9b`, after
   confirming zero consumers; update docs. *Rollback: git history only.*

# E. Recommended first implementation slice (smallest clean-cut step)
**OSN-DOCK-0 — Arrival-at-location docking, dark.** Extend `process_mainship_space_arrivals` so that a
`target_kind='location'` arrival (using the already-present `target_location_id` column) **establishes
`location_presence` and starts the activity** — the legacy `process_fleet_movements` docking branch ported into
the OSN processor. Proven entirely on **synthetic location-targeted fixtures** via the existing disposable-
Postgres real-chain harness; `mainship_space_movement_enabled` stays **false**; **no UI, no flag flip, no
coordinate design, no deletion, no client change.**

*Why this first:* it closes the **single hard blocker** (Special-check 1) in isolation; it is additive,
reversible, and production-dark; and — unlike PRES-1 — it needs **no galaxy-coordinate design** (the user
explicitly defers that), so it can begin immediately after this audit. It makes every later step (targeting,
S6C, the flag flip) a wiring-and-data exercise on top of proven arrival semantics. *Smaller alternative if even
this is too much:* an additive `CHECK`-constraint + decision packet only — but that defers the real blocker, so
OSN-DOCK-0 is preferred. *Decision dependency:* only **D2-contract** (kind/id vs proximity) — recommended kind/id.

# F. Explicit non-goals (untouched during the first slice)
- No flag flip (`mainship_send_enabled` stays TRUE, `mainship_space_movement_enabled` stays FALSE).
- No deletion of any legacy RPC, UI, renderer code, test, workflow, tool, or doc.
- No coordinate/galaxy design; no reseed; no rescale; no CHECK-constraint migration on `locations`/`bases`.
- No renderer swap (`buildNormalizer`/`legacy_dynamic` stay); no `coordinateSpace` collapse.
- No S6C command UI, no tap-to-select/target persistence, no client command-RPC call, no recall affordance.
- No change to `mainship_space_begin_move` / `command_main_ship_space_move` (targeting comes in a later slice).
- No unit-fleet retirement; the D1 product decision is **identified, not executed**.
- No commit/push without explicit instruction.

---

*Strict audit only — no code, migration, coordinate change, flag change, or deletion performed. Open decisions
before implementation: **D1** (unit-fleet survival → deletion scope), **D2-contract** (location-arrival docking
key), **D-data** (in-place reseed + CHECK), and an explicit "begin OSN-DOCK-0". S6C must not begin before the
docking + targeting + recall replacements are chartered; S6D stays blocked until the unified renderer + OSN
main-ship travel (incl. docking) are complete and approved.*
