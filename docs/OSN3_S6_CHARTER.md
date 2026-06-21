# OSN-3 S6 — Public Coordinate Command & Map Surface
## Reconnaissance Charter

> **Status: RECONNAISSANCE ONLY.** This document defines the public boundary around the
> completed internal coordinate-movement engine and the mobile-first map interaction. **No
> code, migration, flag flip, RPC, or UI is authored by this charter.** It ends with the
> decisions that require approval before any S6 implementation slice begins.
>
> **Standing hard constraints (carried verbatim):**
> 1. `mainship_space_movement_enabled` stays **FALSE** in production; no hidden client bypass; the
>    private writer is never exposed directly to the client.
> 2. The legacy named-location path (`mainship_send_enabled`, currently **TRUE**) is preserved and
>    unchanged; coordinate and legacy movement stay **mutually exclusive** for the same ship, with
>    explicit rejection defined in both directions.
> 3. The existing private writer `mainship_space_begin_move` is **internal-only**; S6 adds a narrow,
>    player-safe public wrapper that authenticates ownership, validates availability, enforces the
>    flag, validates the target, and invokes the writer safely.
> 4. The player experience is **mobile-first**: tap/select destination → inspect → explicit confirm,
>    with no required hover / right-click / keyboard / desktop-density dependency.

---

## Approved decisions (recorded 2026-06-21) — AUTHORITATIVE

> These supersede any conflicting proposal in sections A–H below. Where a section recommended a now-
> rejected option, it is annotated **[SUPERSEDED — see Approved Decision N]**.

1. **Public command RPC.** `command_main_ship_space_move(p_target_x, p_target_y, p_request_id)`. Derives
   `p_player` from `auth.uid()`; derives the caller's own main ship server-side; **never** accepts a
   player id or main-ship id from the client; delegates to `mainship_space_begin_move(...)`; returns a
   narrow player-safe payload. The client never receives execute rights on, nor calls,
   `mainship_space_begin_move` directly.
2. **Security hardening (must be specified and proven).** `SECURITY DEFINER` only with: fixed safe
   search path; schema-qualified internal calls; explicit `auth.uid()` caller handling; execute granted
   only to the intended authenticated role; execute on the private writer revoked from normal client
   roles; **no reliance on client-side flag checks for security.** The internal writer remains the final
   authority for flag, ownership, bounds, state checks, travel-cap, locking, and idempotency.
3. **Coordinate canonicalization.** Canonical **integer world-unit** target grid. Client preview may
   snap to whole units; **server canonicalization is authoritative**; the RPC response returns the
   canonical accepted target. **Integer rounding is NOT the idempotency mechanism — `p_request_id` is
   the idempotency key.** Replay behavior (incl. **same request id + different target**) is in the proof.
4. **Targeting envelope.** Rejected the dynamic on-screen envelope. The coordinate command domain is the
   **fixed server domain `x,y ∈ [-10000, 10000]`**. Pan/zoom is a bounded camera only; commandability
   must not vary by viewport, device size, marker distribution, or loaded points.
5. **Transform design.** Do **not** make `buildNormalizer()` the command contract and do **not** add a
   fragile inverse to its dynamic envelope. For S6B/C, design one paired pure transform
   `worldToMap(worldX, worldY)` / `mapToWorld(mapX, mapY)` over the fixed `[-10000,10000]` domain, with
   Y inversion and correct live pan/zoom handling. The **same** transform source renders the
   coordinate-space ship, renders the selected target, derives a target from a tap, and displays the
   target's canonical coords. Existing dynamic normalization may remain for legacy visual content only —
   it must not determine coordinate-command validity or target conversion.
6. **Named-location scope.** Free-space targeting only. Named markers may be visible but are **not**
   coordinate-command destinations in S6. A coordinate target that coincides with a named location's
   coords still arrives free-space `in_space`: no docking, no presence, no rewards, no legacy
   replacement, no hidden bridge. Legacy named-location travel is unchanged and separately commanded.
7. **Flag tooling.** Create a narrow sibling dev tool `dev-mainship-space-movement-flag.mjs` for the
   coordinate flag. Do **not** generalize/refactor the existing legacy send-flag tool in S6A unless a
   concrete safety reason requires it.
8. **OSN-4 Stop.** Deferred. S6 **rejects** a new coordinate command while the ship is `in_transit`;
   no stop/cancel behavior is pre-built. OSN-4 follows after public start, observation, and arrival are
   proved.

**Concrete S6A implementation plan:** see `docs/OSN3_S6A_PLAN.md`.

---

## A. Verified current baseline

*(All facts below confirmed by reading the actual migrations, frontend source, and CI workflows
on 2026-06-21 — not from memory.)*

### A.1 Branch / commit / migration baseline
- `main == origin/main`, working tree clean. Tip commit **`ec0bfad`** (docs: OSN-3 S5 sync).
- Code/schema/deploy baseline: OSN-3 S5 merge **`0d84256`**, plus the read-only S5 live-spot-check
  tooling commit (`fda8778`); commits above those on `main` are documentation-only.
- **Database migrations applied through `0059`** (`20260618000059_osn3_s5_destruction_coordinate_complete.sql`).
  Full chain `0001..0059` lives under `supabase/migrations/`.
- **Flags (live):** `mainship_send_enabled = TRUE` (legacy named-location path live),
  `mainship_space_movement_enabled = FALSE` (coordinate domain dark).

### A.2 Internal coordinate engine — private / service-role-only today
| Component | Migration | Signature | Grant |
|---|---|---|---|
| **Writer** `mainship_space_begin_move` | 0057 | `(p_player uuid, p_main_ship_id uuid, p_target_x double precision, p_target_y double precision, p_request_id uuid) returns jsonb` | `service_role` only |
| **Arrival processor** `process_mainship_space_arrivals` | 0058 | `() returns integer`; pg_cron `process-mainship-space-arrivals` @ **30 seconds** | `service_role` only |
| S2 boundary `mainship_space_lock_context` | 0056 | `(p_main_ship_id uuid, p_skip_locked boolean default false) returns jsonb` | `service_role` only |
| S2 `mainship_space_validate_context` | 0056 | `(p_main_ship_id uuid) returns jsonb` | `service_role` only |
| S2 `mainship_space_resolve_origin` | 0056 | `(p_main_ship_id uuid) returns jsonb` | `service_role` only |
| S2 `mainship_space_assert_cross_domain_exclusion` | 0056 | `(p_main_ship_id uuid) returns jsonb` | `service_role` only |
| S5 destruction `dev_set_main_ship_destroyed` | 0059 | `(p_player uuid) returns jsonb` | `service_role` only |

**The writer (`mainship_space_begin_move`) already performs, before any mutation:** input
finite/in-bounds validation `[-10000,10000]²`; S2 lock context (canonical order ship→fleet→coord-mvmt
→presence, never locks legacy `fleet_movements`); ownership check; **idempotency** lookup
(`request_id` + canonical payload hash); **`cfg_bool('mainship_space_movement_enabled')` flag gate**;
S2 coherent-state validation; S2 cross-domain exclusion; S2 origin resolution (rejects
in_transit/destroyed); exact **zero-distance reject**; and a **travel-time cap** check against
`max_coordinate_travel_seconds` (default `86400`). → *The wrapper inherits all of this for free.*

### A.3 Legacy named-location RPCs — player-callable today (`authenticated`)
| RPC | Signature | Flag gate | Marks ship |
|---|---|---|---|
| `send_main_ship_expedition` | `(p_ships jsonb, p_location uuid)` | `mainship_send_enabled` | `status='traveling'`, fleet `active_movement_id` (legacy domain) |
| `move_main_ship_to_location` | `(p_fleet uuid, p_location uuid)` | `mainship_send_enabled` | `status='traveling'`, legacy domain |
| `request_main_ship_return` | `(p_fleet uuid)` | (reached only via gated send) | `status='returning'`, legacy domain |
| `repair_main_ship` | `()` | **ungated** (safelock guarantee) | `status='home'`, leaves `spatial_state` |
| `process_mainship_expeditions` | `()` cron @30s | none | reconciles legacy travel |

### A.4 Tables, RLS, config (player-readable vs server-only)
- `main_ship_instances` — **owner-read** (`select using player_id = auth.uid()`, granted `authenticated`).
  Spatial cols `spatial_state` (NULL | home|at_location|in_transit|in_space|destroyed), `space_x`,
  `space_y` (double precision; non-null IFF `spatial_state='in_space'`). One ship per player (UNIQUE
  `player_id`). Status enum includes `stationary`. **No client write.**
- `main_ship_space_movements` — **owner-read SELECT** granted `authenticated` (policy
  `..._select_own`). Holds origin/target x/y, `target_kind` (space|location|base), `status`
  (moving|arrived|stopped|cancelled|failed), `depart_at`/`arrive_at`, `speed_used`, `terminal_reason`.
  Partial-unique **one active (`status='moving'`) per ship and per fleet**. **No client write.**
- `main_ship_space_command_receipts` — **server-only** (RLS on, **no** authenticated policy/grant).
  Idempotency: `unique (main_ship_id, request_id)` + `canonical_payload_hash`.
- `fleets` — **owner-read**. `active_movement_id` (legacy) **XOR** `active_space_movement_id`
  (coordinate) enforced by CHECK; coordinate pointer implies `status='moving' & location_mode='movement'`.
- `game_config` — **public read** (`SELECT` to `anon, authenticated`); server reads via `cfg_bool(key)`
  / `cfg_num(key)`. Relevant keys: `mainship_send_enabled`, `mainship_space_movement_enabled`,
  `travel_scale` (1.0), `min_travel_seconds` (5), `max_coordinate_travel_seconds` (86400),
  `max_active_fleets` (3).

### A.5 Frontend surface that already exists (the read/observe half)
- `src/features/map/GalaxyMap.tsx` — SVG **viewBox `0..1000`** (`VIEW=1000`); `buildNormalizer()`
  projects world coords into the box (dynamic min/max bounds, **Y-flipped**, `PAD=0.08`); camera
  `<g transform="translate(tx ty) scale(k)">`, `k` clamped **0.4..8**, `clampPan()` keeps content
  on-screen; pan via Pointer API drag; zoom via wheel/buttons centered on `(500,500)`; `touch-none`;
  `onClick` background → deselect. **One-way transform only — no screen→world inverse exists.**
- `src/features/map/resolveMainShipMarker.ts` — single position resolver. Already renders
  **`in_space`** (from `space_x/space_y`) and interpolates **`in_transit`** from the active space
  movement; returns `ShipMarker { entityId, entityType:'main_ship', relation:'self', x, y, state }`
  or `null`. `MainShipMarker.tsx` draws a chevron (color by state, `r=7/k`, `pointer-events:none`,
  1 s tick only while moving).
- Data layer `src/features/map/mainshipApi.ts`: `fetchMyMainShip`, `fetchActiveMainShipFleet`,
  `fetchActiveMainShipPresence`, **`fetchActiveMainShipSpaceMovement`** (already polled). Map hook
  `useGalaxyMapData.ts` polls **4 s**; dashboard `useGameState.ts` polls **3 s**; **no realtime, no
  Zustand store** (React Context). Manual `refresh()` after each RPC.
- Command UI: `MainShipCommand.tsx` (`{location, mainShip, fleet, onSent}`) — legacy send/move,
  rendered only when `mainshipSendEnabled`. `MainShipPreview.tsx` — recall/repair. `MainShipPanel.tsx`
  — read-only command-center status. Client flag read: `fetchMainshipSendEnabled()` in
  `src/lib/catalog.ts` (reads `game_config.mainship_send_enabled`, **read once / static**).

### A.6 Proof harness
- **Real-chain proofs** (`.github/workflows/osn3-s{2..5}-realchain-proof.yml`): boot disposable
  Supabase (`supabase start` applies `0001..00NN`), run `perm`/`fixtures`/`concurrency`/`rest`
  scripts under `scripts/osn3-s*-realchain-*`, restore flags, delete fixture users.
- **REST/RLS denial canonical pattern**: `scripts/osn3-s4-realchain-rest.sh` (mint admin user + real
  password-grant JWT, probe RPC, assert 403 for anon **and** authenticated).
- **Permission SQL pattern**: `has_function_privilege(...)` assertions in `*-realchain-perm.sql`.
- **Resolver unit test**: `tests/resolveMainShipMarker.spec.ts` via `npm run verify:osn:resolver`
  (Playwright, no DB; workflow `verify-osn-resolver.yml`, dispatch-only).
- **Build gate**: `build.yml` (`tsc -b` + `vite build`, Node 22). **Deploy**: `deploy-migrations.yml`
  (`supabase db push` on `supabase/migrations/**`), `pages.yml` (frontend → GitHub Pages).
- **Flag toggle**: `scripts/dev-mainship-flag.mjs` via `set_game_config` RPC — **today it writes only
  `mainship_send_enabled`** (workflow `dev-mainship-flag.yml`). ⚠ No tooling flips
  `mainship_space_movement_enabled` yet (see §F / risks).
- **Local toolchain is unreliable** on the OneDrive path (node_modules corruption); **all verification
  must run in CI.**

---

## B. Public read model

**Finding: the read model largely already exists.** An authenticated player can already read, owner-
scoped via RLS, everything needed to render their ship and its coordinate movement:

| Datum | Source (already player-readable) |
|---|---|
| Spatial state | `main_ship_instances.spatial_state` |
| Current coordinate (parked) | `main_ship_instances.space_x/space_y` (when `in_space`) |
| Destination coordinate (moving) | `main_ship_space_movements.target_x/target_y` (active row) |
| Origin / travel timing | `main_ship_space_movements.origin_x/y`, `depart_at`, `arrive_at` |
| Movement status | `main_ship_space_movements.status` (`moving`…) |
| Destroyed / repair-required | `main_ship_instances.status='destroyed'` |
| Map bounds / coordinate system | world `[-10000,10000]²`; client viewBox `0..1000` via `buildNormalizer()` |

**Recommendation — keep it a typed query layer, not a new RPC/view.** Reuse the existing owner-read
SELECTs (`fetchMyMainShip`, `fetchActiveMainShipSpaceMovement`) and the 4 s poll. RLS already
restricts every row to `player_id = auth.uid()`.

- **Must remain server-only:** `main_ship_space_command_receipts` (idempotency), the S2 helpers, the
  writer, the processor — none gain client grants.
- **Named locations vs arbitrary targets are represented separately:** named locations come from
  `fetchWorldMap()` (`MapLocation{ id,name,x,y,activity_type,… }`) and stay on the **legacy** send/move
  path. Coordinate targets are raw `(x,y)` with `target_kind='space'`. **S6 does not let the player
  dock at a named location via the coordinate path** (proximity ≠ docked; deferred to OSN-5).
- **New read needed:** the client must learn `mainship_space_movement_enabled`. Add a sibling to
  `fetchMainshipSendEnabled()` (e.g. `fetchMainshipSpaceMovementEnabled()`) reading the same public
  `game_config`. This is the only new read in S6.

---

## C. Public movement-command contract

A single narrow player-facing RPC that authenticates, validates the flag, resolves the caller's own
ship, and **delegates all movement logic to the existing writer** (the wrapper adds no new movement
math, no new table writes).

- **Proposed name:** `command_main_ship_space_move`
- **Parameters:** `(p_target_x double precision, p_target_y double precision, p_request_id uuid)`
  — **no player or ship id from the client**; the wrapper derives both from `auth.uid()` (one ship
  per player).
- **Security:** `SECURITY DEFINER`, owner `postgres`, `search_path=public`, **granted to
  `authenticated`** (revoked from `public`/`anon`). It is the *only* function the client may call;
  `mainship_space_begin_move` stays `service_role`-only and is invoked in the wrapper's definer context.
- **Coordinate units / convention:** raw world units, same space as `space_x/space_y` and
  `main_ship_space_movements`. Domain `[-10000,10000]` on each axis; **+y is "up" in world space**
  (the client normalizer applies the Y-flip for the screen — the RPC never sees screen coords).
- **Validation order inside the wrapper:** (1) `request_id` non-null; (2) target finite & in-bounds;
  (3) `cfg_bool('mainship_space_movement_enabled')` — clean reject if false (defense-in-depth; the
  writer also re-checks); (4) resolve caller's ship via `auth.uid()` (reject if none / destroyed);
  (5) call `mainship_space_begin_move(auth.uid(), ship_id, x, y, request_id)`; (6) translate the
  writer's jsonb result into a player-safe payload.
- **Target == current position:** the writer already rejects exact zero-distance → wrapper returns
  `{ ok:false, code:'zero_distance' }`. **The client should also pre-block** an identical target.
- **Out of bounds:** writer/wrapper reject → `{ ok:false, code:'out_of_bounds' }`.
- **Rounding / precision policy** — **[SUPERSEDED — see Approved Decision 3]:** canonicalize to
  **integer world units** (server authoritative; response returns the canonical target). Canonicalization
  is a discrete-grid concern only; **idempotency is `p_request_id`, not rounding.**
- **Response payload (player-safe):** `{ ok:true, movement_id, main_ship_id, target_x, target_y,
  depart_at, arrive_at }` on success; `{ ok:false, code, message }` on rejection. **No internal lock
  state, no receipt internals, no origin-resolution detail leaked.**
- **Player-safe error codes:** `feature_disabled`, `no_ship`, `ship_destroyed`, `busy_legacy`,
  `busy_coordinate`, `must_stop_first` (in_transit), `zero_distance`, `out_of_bounds`, `invalid_target`,
  `over_travel_cap`. Each maps from a writer reason; messages are short and non-technical.
- **Idempotency / duplicate-submit:** client generates **one `request_id` (uuid) when the confirm
  dialog opens** and reuses it on confirm; replays return the stored receipt. The DB **one-active-per-
  ship** partial unique index is the backstop against two concurrent movements.
- **How the wrapper calls the private writer without leaking internals:** it calls the
  `service_role`-granted writer from its own definer context and **maps**, never forwards, the writer's
  raw jsonb (codes normalized, internal fields dropped).

---

## D. State & exclusion matrix

"May a **coordinate move begin** now?" — resolved by the existing S2 `validate_context` /
`resolve_origin` / `assert_cross_domain_exclusion`; the wrapper surfaces a clean code.

| Ship state | Coordinate move may begin? | Why / mechanism |
|---|---|---|
| **home** (`home`/`legacy_home`) | ✅ allowed | origin resolves to base |
| **at_location** (`stationary`, present) | ✅ allowed | origin resolves to location coord |
| **in_space** (`stationary`, parked) | ✅ allowed | origin resolves to `space_x/space_y` |
| **already in coordinate travel** (`in_transit`) | ❌ `must_stop_first` | `resolve_origin → in_transit_must_stop`; needs **OSN-4 Stop** |
| **in legacy named expedition** (fleet moving) | ❌ `busy_legacy` | `assert_cross_domain_exclusion` (active legacy movement) |
| **returning from legacy expedition** | ❌ `busy_legacy` | legacy_transit; same guard |
| **destroyed / repair-required** | ❌ `ship_destroyed` | `resolve_origin → destroyed`; repair first |
| **otherwise contradictory** | ❌ `invalid_target`/abort | `validate_context` rejects, no mutation |

**Cross-direction exclusion (the other way):**
- **Coordinate move targeting a named location's coordinate:** **out of scope for S6.** The wrapper
  only issues `target_kind='space'`; docking at a named location stays on the legacy path. (A `space`
  target that happens to sit on a location's coords just parks `in_space` near it — no presence.)
- **Legacy named-location move while a coordinate move/parked state exists:** must **reject**. A ship
  in the coordinate domain is `status='stationary'`/`spatial_state='in_space'` (or `in_transit`) — it
  is not `home` and has no `present` fleet, so `send_main_ship_expedition` (needs home) and
  `move_main_ship_to_location` (needs present) reject by precondition, and the fleet pointer XOR CHECK
  is the DB backstop. **S6 must assert this explicitly in proof** (and add a guard only if a gap is
  found — see open questions).
- **Stale UI / double taps:** one `request_id` per confirm dialog (idempotent) + one-active-per-ship
  index; the confirm handler **re-reads ship state at click time** (mirrors the existing
  `MainShipCommand` live-guard pattern) and the server is authoritative.
- **Refresh pattern:** keep **poll (4 s) + manual `refresh()` after command** — no realtime in S6.

---

## E. Map / command UI contract (minimal vertical slice)

**Not** a galaxy redesign. Only: safe coordinate selection, command submission, movement observation.

- **Coordinate transform contract — the key new piece.** `buildNormalizer()` is world→screen only.
  S6 needs the **inverse** (screen→world) to turn a tap into a target. Two sub-decisions:
  - *Inverse function:* add a pure `invertNormalizer()` companion (and unit-test it as the symmetric
    inverse, reusing the `resolveMainShipMarker` test style). Must undo the Y-flip, the `PAD`, the
    scale, **and** the live camera `translate(tx ty) scale(k)` so a tap maps to world coords.
  - *Selectable envelope* — **[SUPERSEDED — see Approved Decisions 4 & 5]:** the content envelope is
    rejected. Targeting is the **fixed `[-10000,10000]²` server domain** via a dedicated paired pure
    transform `worldToMap` / `mapToWorld` (Y-inverting, pan/zoom-aware) — **not** an inverse of the
    dynamic `buildNormalizer()`. Commandability must not vary by viewport or loaded points.
- **Seeing your own ship:** already done — `MainShipMarker` (in_space violet, in_transit
  interpolated). No change.
- **Tap → target:** tapping empty map space (when the coordinate flag + an eligible ship are present)
  sets a **selected target** (a distinct ghost marker at the tapped world coord). Re-tap moves it.
  This must not collide with location-marker taps (which select a location) or background-tap deselect
  — define a precedence: location tap > target placement > deselect.
- **Target preview contents:** target `(x,y)` (rounded per §C), **estimated** travel time (client
  estimate from hull speed + distance; the authoritative ETA returns from the command), current ship
  status, and a confirm/cancel control.
- **Command CTA per status:** `home`/`at_location`/`in_space` → "Send to coordinate" enabled;
  `in_transit` → disabled + "Stop the ship first" (OSN-4 dependency); legacy busy → disabled + "Finish
  the current expedition"; `destroyed` → disabled + "Repair first"; flag off → **no CTA at all**.
- **Movement-in-progress state:** show destination + live ETA/progress (reuse the `in_transit`
  interpolation + a countdown like `MainShipPanel.formatCountdown`).
- **Arrival state:** poll flips the ship to `in_space` at target; marker turns violet; panel shows
  "Parked in open space."
- **Rejection/error handling:** map the wrapper's `code`/`message` to a short inline toast/notice.
- **Loading / reconnect:** reuse the existing poll loading + manual refresh; on transient failure keep
  last good state (don't hide the ship).
- **Mobile interaction:** tap to place target, tap target/CTA to confirm — **no hover, no right-click,
  no keyboard**. Touch-sized controls (existing `h-8`/`py-2` conventions). Desktop = same flow; a
  debug-only coordinate readout may be shown on `md:` breakpoints.
- **Explicitly out of S6:** pirate combat, mining, trade, captains, zones, stations, broad visual
  polish.

---

## F. Feature-flag design

Gate at **both** boundaries.

- **Server boundary:** `command_main_ship_space_move` checks `cfg_bool('mainship_space_movement_enabled')`
  first and returns `feature_disabled`; the underlying writer **re-checks** (defense-in-depth). When
  the flag is FALSE, the public RPC is a safe no-op rejection even though it is grant-visible to
  `authenticated`.
- **Client boundary:** the new `fetchMainshipSpaceMovementEnabled()` gates **all** coordinate UI —
  no target placement, no CTA, no command call when false. Mirrors how `mainshipSendEnabled` gates the
  legacy command UI today.
- **Flag TRUE but ship ineligible** (legacy-busy / in_transit / destroyed): UI shows the disabled CTA
  with the reason; a forced call still rejects server-side with the matching code.
- **Older client loads** (cached bundle without S6 UI): harmless — it never calls the new RPC and
  never renders coordinate UI; the legacy path is untouched.
- **Client invokes the public RPC while UI unavailable:** server is authoritative — rejects on flag or
  state; no client trust.
- **Tooling** — **[SUPERSEDED — see Approved Decision 7]:** add a narrow sibling
  `dev-mainship-space-movement-flag.mjs` for `mainship_space_movement_enabled`; do **not** generalize
  the existing legacy send-flag tool in S6A. *Operational, not gameplay.*

---

## G. Proof plan

### Backend / authorization (new `osn3-s6-realchain-proof.yml`, full chain `0001..00NN`, reusing the §A.6 patterns)
- Player **cannot** read another player's coordinate movement / ship (RLS owner-scope).
- Player **cannot** command another player's ship (wrapper derives ship from `auth.uid()`; no client id).
- Direct call to `mainship_space_begin_move` **stays denied** to anon + authenticated (REST `403`).
- Flag FALSE **blocks** the public command (returns `feature_disabled`, no row written).
- Invalid / non-finite / malformed / out-of-bounds coords **fail safely** (no mutation).
- Duplicate / replayed `request_id` **cannot create two movements**; one-active-per-ship holds.
- Legacy and coordinate movement **cannot overlap** (both directions) — assert the in_space/in_transit
  ship rejects legacy send/move, and a legacy-busy ship rejects the coordinate command.
- Destroyed / repair-required ship **cannot move**.
- Arrival processor remains **exactly-once** under concurrent execution (regression of S4).
- Cleanup/deletion (FK cascade) remains safe; fixtures fully removed.

### Frontend
- Flag-false → **no** coordinate CTA / target placement anywhere.
- Player can inspect own ship state safely (no foreign data).
- Target selection + confirmation behave correctly (place, re-place, cancel, confirm).
- Loading / rejection / in-progress / arrival states are clear.
- **Phone-size usability explicitly tested** (Playwright mobile viewport).
- Legacy named-expedition UI remains functional (regression).
- New `invertNormalizer()` proven the exact inverse of `buildNormalizer()` (pure unit test).

### Regression
- `verify:mainship-send` / `-move` / `-repair`, `verify:osn:resolver`, S1–S5 real-chain proofs,
  `build.yml` (`tsc -b` + `vite build`), the disposable-Postgres migration-chain proof, and (when
  frontend lands) `pages.yml` deploy + a browser acceptance spec.

---

## H. Implementation slicing recommendation

Smallest safe, independently-verifiable steps; everything default-off until S6D.

- **S6A — Public read flag + flag-gated public command wrapper + backend proof.**
  Migration `00NN`: `command_main_ship_space_move(p_target_x, p_target_y, p_request_id)` (definer,
  `authenticated`) delegating to the writer; new `fetchMainshipSpaceMovementEnabled()` read.
  Ship/UI unchanged. New `osn3-s6-realchain-proof.yml`. **No player-visible behavior** (flag false).
- **S6B — Read-only / mobile-first map state surface.** `invertNormalizer()` + unit test; surface the
  destination coordinate + ETA in a panel for an already-moving ship; still no command CTA.
- **S6C — Command selection + confirmation UI (default-off).** Tap-to-place target, preview, confirm,
  wired to S6A's RPC, gated by the client flag (false) + ship eligibility; mobile usability proof.
- **S6D — Controlled enablement + acceptance.** Generalize/extend the flag tooling for
  `mainship_space_movement_enabled`; flip on in a controlled, reversible window; run end-to-end
  acceptance (send → travel → arrival observed) on a real account; flip off; record closure.

---

## Closing: required before any S6 implementation

### 1. Decisions — RESOLVED (approved 2026-06-21, see "Approved decisions" at top)
1. Public RPC `command_main_ship_space_move(p_target_x, p_target_y, p_request_id)` — **approved.**
2. Coordinate canonicalization to **integer world units**, server-authoritative; **idempotency is
   `p_request_id`, not rounding** — **approved.**
3. Targeting envelope = **fixed `[-10000,10000]²` server domain** (content envelope rejected); paired
   `worldToMap`/`mapToWorld` transform — **approved.**
4. S6 = **free-space `space` targets only**, no named-location docking — **approved.**
5. Flag tooling = **new sibling `dev-mainship-space-movement-flag.mjs`** (legacy tool untouched) —
   **approved.**
6. OSN-4 Stop **deferred**; `in_transit` rejects a new command — **approved.**

### 2. Risks / open questions
- **Transform inversion is the main technical risk:** the camera (`tx,ty,k`) + `PAD` + Y-flip must all
  be inverted exactly, or taps land on the wrong world coord. Mitigated by a pure, unit-tested
  `invertNormalizer()` before any command wiring.
- **Legacy↔coordinate exclusion may rely on preconditions, not an explicit guard.** Best evidence says
  an `in_space`/`in_transit`/`stationary` ship already fails legacy send/move by state precondition +
  the fleet XOR CHECK — **but this must be proven in S6's matrix**; add a small explicit guard *only*
  if the proof finds a gap (avoid touching the frozen legacy path otherwise).
- **Travel-time estimate vs. authoritative ETA:** the client preview is an estimate (it can't run
  server origin-resolution); the confirmed `depart_at`/`arrive_at` come back from the command. UI must
  present the preview as approximate.
- **One ship per player** is assumed throughout; multi-ship is deferred and out of scope.
- **No realtime:** arrival shows up on the next 4 s poll (acceptable; note it).
- **OSN-4 Stop is a hard dependency** for re-commanding an in-transit ship — S6 correctly rejects
  `in_transit` rather than pre-building Stop.

### 3. Proposed exact scope for S6A (first slice)
- **One migration** adding `command_main_ship_space_move(p_target_x double precision, p_target_y
  double precision, p_request_id uuid) returns jsonb`: `SECURITY DEFINER`, owner `postgres`,
  `search_path=public`, **granted `authenticated`** (revoked `public`/`anon`); checks the flag, finite/
  in-bounds target, resolves the caller's ship from `auth.uid()`, calls `mainship_space_begin_move`,
  and returns a **mapped player-safe payload** (no internal fields). No new table, no processor/cron,
  no writer change, **no flag flip** (`mainship_space_movement_enabled` stays FALSE).
- **One frontend read:** `fetchMainshipSpaceMovementEnabled()` in `src/lib/catalog.ts` (no UI wiring
  yet).
- **One new proof workflow** `osn3-s6-realchain-proof.yml` covering the §G backend/authorization list,
  plus the existing build/regression gates.
- **Out of S6A:** all map interaction, target selection, CTA, inverse transform, and any flag
  enablement (those are S6B/S6C/S6D).
- **Net player-visible effect of S6A: none** (the public RPC exists but returns `feature_disabled`).
```

---
*Reconnaissance only — no implementation performed. Awaiting decisions in “Closing §1” before S6A.*
