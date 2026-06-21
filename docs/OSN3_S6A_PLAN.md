# OSN-3 S6A — Public Coordinate Movement Boundary, Still Dark
## Concrete Implementation Plan (no code)

> **Scope:** the first, narrowest slice of OSN-3 S6. It adds the **public, authenticated, flag-gated
> command wrapper** around the existing private writer `mainship_space_begin_move`, with full
> authorization proof — and **nothing player-visible**. With `mainship_space_movement_enabled` FALSE
> on production (unchanged), the new RPC returns `feature_disabled` and writes nothing. **Net
> player-visible effect of S6A: none.**
>
> Decisions are fixed by `docs/OSN3_S6_CHARTER.md` → "Approved decisions (2026-06-21)". This plan does
> **not** implement, commit, push, flip a production flag, or begin S6B/C. It stops at the plan.
>
> **Verified anchors (read from source, not memory):** writer = migration `0057`
> (`mainship_space_begin_move`, success payload + reason vocabulary quoted in §3); chain tip = `0059`;
> every function-adding migration re-runs the **anti-cheat re-lock block** (0057 lines 269–292) — S6A
> must replicate it (§4). Flags live in `game_config`, written by `set_game_config(p_key,p_value)`;
> legacy flag tool = `scripts/dev-mainship-flag.mjs` (single-key, service-role) — mirror it (§6).

---

## 0. S6A scope (the nine boundaries, restated against ground truth)

1. **One migration** for the public wrapper + privileges + the re-lock block (§2–§4). No new table; the
   player-safe result is composed from the writer's existing jsonb (no new type needed).
2. **No change to the private writer's core lifecycle logic.** The wrapper only *canonicalizes inputs*
   and *delegates*. A writer change is permitted **only** if S6A's proof discovers a verified guard gap
   (e.g. the legacy↔coordinate exclusion turns out not to be enforced) — and only as a separate,
   documented additive guard, never a silent rewrite.
3. **No map tap interaction** (deferred to S6C).
4. **No inverse transform** / no `worldToMap`/`mapToWorld` (deferred to S6B).
5. **No player-visible CTA** (deferred to S6C).
6. **No production feature-flag enablement** — `mainship_space_movement_enabled` stays FALSE on live.
7. **Optional** typed frontend flag read only (§5) — uses the existing safe `game_config` read path,
   creates **zero** visible behavior. Recommended (zero-risk S6B seed) but droppable.
8. **One dedicated real-chain verification workflow + verifier** (§7).
9. **Explicit proof that legacy named travel still works and stays mutually exclusive** with coordinate
   travel (§7, matrix rows L1–L4).

---

## 1. Intended migration name

`supabase/migrations/20260618000060_osn3_s6a_public_space_move_command.sql`

(Next ordinal **0060** after `…0059_osn3_s5_destruction_coordinate_complete.sql`; same synthetic
`20260618…` date-prefix convention as the rest of the OSN-3 chain.)

---

## 2. Public wrapper — signature, hardening, behavior

### 2.1 Signature & player-safe response

```
public.command_main_ship_space_move(
  p_target_x   double precision,
  p_target_y   double precision,
  p_request_id uuid
) returns jsonb
```

- `language plpgsql`, **`security definer`**, **owner `postgres`**, **`set search_path = public`**
  (identical hardening to every audited definer fn in the chain; the live spot-checks already assert
  `owner=postgres / SECURITY DEFINER / search_path=public / no dynamic SQL` for this family).
- **All internal calls schema-qualified** (`public.mainship_space_begin_move`, `public.cfg_bool`,
  reads from `public.main_ship_instances` / `public.game_config`). **No dynamic SQL.**

**Player-safe success payload** (composed from the writer's result — see §3 for the writer's shape):
```json
{ "ok": true,
  "movement_id": "<uuid>",
  "main_ship_id": "<uuid>",
  "target_x": <int>,            // canonical accepted target (integer world units)
  "target_y": <int>,
  "depart_at": "<iso8601>",
  "arrive_at": "<iso8601>" }
```
**Player-safe failure payload:**
```json
{ "ok": false, "code": "<player_safe_code>", "message": "<short, non-technical>" }
```
Internal fields (`fleet_id`, `player_id`, `origin_*`, `speed_used`, raw writer `reason`, lock/receipt
internals) are **never** surfaced.

### 2.2 Behavior (delegation, not new movement math)

1. `v_player := auth.uid()`; if NULL → `{ ok:false, code:'not_authenticated' }`.
2. **Defense-in-depth flag check** (NOT the security boundary): if `not public.cfg_bool('mainship_space_movement_enabled')`
   → `{ ok:false, code:'feature_disabled' }`. *(The writer re-checks and remains the final authority —
   Approved Decision 2.)*
3. **Derive the caller's own ship server-side:** `select main_ship_id from public.main_ship_instances
   where player_id = v_player` (definer bypasses RLS). If none → `{ ok:false, code:'no_ship' }`.
   **No player/ship id is ever accepted from the client.**
4. **Canonicalize** the target to integer world units (Approved Decision 3): `round(p_target_x)`,
   `round(p_target_y)` (nearest integer; non-finite passes through unchanged and is rejected
   downstream). Canonicalization is a discrete-grid concern only — **not** idempotency.
5. **Delegate:** `v_res := public.mainship_space_begin_move(v_player, v_ship, v_cx, v_cy, p_request_id)`.
   The writer performs the authoritative flag/ownership/bounds/state/exclusion/travel-cap/lock/
   idempotency work and returns its jsonb (§3).
6. **Map** `v_res` to the player-safe payload (success → 7 whitelisted fields incl. the canonical target
   the writer echoes back; failure → `reason`→`code` per the §3 table). Never forward the raw jsonb.

> The wrapper writes **no** tables itself. Canonicalize → delegate → map. That is the whole boundary.

---

## 3. Writer contract consumed (verified from migration 0057)

**Success result** (`mainship_space_begin_move`, lines 247–253) already contains everything the
player-safe payload needs — including the **canonical accepted target** it stored:
`{ ok:true, movement_id, main_ship_id, fleet_id, player_id, origin_kind, origin_x, origin_y,
target_kind:'space', target_x, target_y, speed_used, depart_at, arrive_at, request_id }`.

**Reason → player-safe code mapping** (writer reasons are the exact strings in 0057 / S2 helpers):

| Writer `reason` | Wrapper `code` | Note |
|---|---|---|
| `feature_disabled` | `feature_disabled` | flag off (final authority) |
| `invalid_request_id` | `invalid_request` | |
| `invalid_coordinate` | `invalid_target` | non-finite target/origin |
| `target_out_of_bounds` | `out_of_bounds` | outside `[-10000,10000]` |
| `zero_distance` | `zero_distance` | target == current position |
| `travel_time_exceeds_limit` | `over_travel_cap` | > `max_coordinate_travel_seconds` |
| `request_id_payload_conflict` | `request_conflict` | same `request_id`, different target |
| `in_transit_must_stop` | `must_stop_first` | OSN-4 dependency (rejected, not built) |
| `destroyed` | `ship_destroyed` | repair first |
| `active_legacy_movement` | `busy_legacy` | legacy expedition in flight |
| `coordinate_pointer_mismatch` / `presence_conflict` / `contradictory_state` | `unavailable` | coherence guard (should not occur for a valid ship) |
| `missing_ship` / `not_owned` | `no_ship` | defensive; wrapper pre-resolves ship |
| `invalid_speed` / `origin_out_of_bounds` | `unavailable` | integrity guard |
| lock `skipped` / `lock_failed` | `busy` | transient; client may retry with the **same** `request_id` |

> **Confirm-on-implement:** re-read lines 247–253 to pin the exact success keys before wiring the
> field whitelist (already captured above — this note is a guardrail, not an open question).

---

## 4. Exact grants / revokes (replicate the 0057 anti-cheat re-lock block)

Creating a new function default-grants EXECUTE to PUBLIC, so the migration **must** re-run the canonical
re-lock (verbatim pattern from 0057 lines 269–292), adding only the new wrapper to the authenticated set
and leaving the writer/helpers/processor/destruction `service_role`-only:

```
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- canonical CLIENT RPC list (carried verbatim from 0057) + the ONE new S6A wrapper:
grant execute on function public.get_world_map()                                  to anon, authenticated;
grant execute on function public.bootstrap_me()                                   to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb)        to authenticated;
grant execute on function public.request_leave_location(uuid)                     to authenticated;
grant execute on function public.request_retreat(uuid)                            to authenticated;
grant execute on function public.get_combat_reports()                             to authenticated;
grant execute on function public.train_units(uuid, text, integer)                 to authenticated;
grant execute on function public.cancel_build_order(uuid)                         to authenticated;
grant execute on function public.get_my_expedition_preview(jsonb, text)           to authenticated;
grant execute on function public.send_main_ship_expedition(jsonb, uuid)           to authenticated;
grant execute on function public.request_main_ship_return(uuid)                   to authenticated;
grant execute on function public.repair_main_ship()                               to authenticated;
grant execute on function public.move_main_ship_to_location(uuid, uuid)           to authenticated;
grant execute on function public.command_main_ship_space_move(double precision, double precision, uuid) to authenticated;  -- NEW (S6A)

-- server / CI ONLY (service_role) — NEVER clients (writer stays internal):
grant execute on function public.dev_set_main_ship_destroyed(uuid)                to service_role;
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
grant execute on function public.process_mainship_space_arrivals()                to service_role;  -- (added since 0058)
grant execute on function public.mainship_space_lock_context(uuid, boolean)       to service_role;
grant execute on function public.mainship_space_validate_context(uuid)            to service_role;
grant execute on function public.mainship_space_resolve_origin(uuid)              to service_role;
grant execute on function public.mainship_space_assert_cross_domain_exclusion(uuid) to service_role;
grant execute on function public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid) to service_role;
```

> **Why the wrapper can call a `service_role`-only writer:** the definer runs as `postgres` (owner),
> which may invoke it. The **client** only ever holds EXECUTE on `command_main_ship_space_move`; it
> never gains access to `mainship_space_begin_move`. The proof (§7) asserts both halves.
> **Confirm-on-implement:** diff the canonical list against the then-current chain tip (it grew from
> 0056→0057; `process_mainship_space_arrivals` from 0058 must be in the service_role set) so the
> re-lock neither drops nor over-grants any function.

---

## 5. Optional frontend plumbing (no visible behavior)

- Add `fetchMainshipSpaceMovementEnabled()` to `src/lib/catalog.ts`, mirroring the existing
  `fetchMainshipSendEnabled()` (reads `game_config.mainship_space_movement_enabled` via the same public
  read path). **No component reads it in S6A** — it is a typed seed for S6B's gating.
- **Nothing else frontend.** No marker change, no panel, no CTA, no command call. Gated by `tsc -b` +
  `vite build` in `build.yml`.
- This item is **optional**; if any doubt, defer it to S6B. Its sole risk is an unused export.

---

## 6. Temporary test-flag procedure & guaranteed restoration

The success-path tests require `mainship_space_movement_enabled = TRUE`, but **only inside the
disposable Supabase instance in CI — never production.**

- **New sibling dev tool** `scripts/dev-mainship-space-movement-flag.mjs` (Approved Decision 7): a
  byte-for-byte clone of `dev-mainship-flag.mjs` with `FLAG_KEY = 'mainship_space_movement_enabled'`
  (the **only** key it may write), writing via the existing `set_game_config` RPC, service-role only,
  refusing unless `--enabled` is exactly `true|false`. The legacy `dev-mainship-flag.mjs` is **not**
  touched. *(In S6A this tool is created and unit-exercised in the proof; it is **not** dispatched
  against production.)*
- **In the real-chain proof** (disposable DB): set the flag TRUE for the success-path block, run those
  assertions, then **restore to FALSE** in an `if: always()` step and **assert it ends FALSE** — the
  exact restore-and-assert discipline S2–S5 proofs already use (they end with both flags at their
  baseline + `max_coordinate_travel_seconds=86400`).
- **Production guarantee:** `mainship_space_movement_enabled` is never written on live in S6A. A
  post-deploy live spot-check (§7) asserts the live flag is still **FALSE** (and `mainship_send_enabled`
  still **TRUE**), proving the deploy mutated no game state.

---

## 7. Test matrix (new `osn3-s6a-realchain-proof.yml`, disposable Supabase, full chain `0001..0060`)

Reuse the established proof scaffold (`supabase start` applies the chain; `perm`/`fixtures`/
`concurrency`/`rest` scripts; fixture users by email pattern; `if: always()` restore). New files:
`scripts/osn3-s6a-realchain-perm.sql`, `…-fixtures.sql`, `…-rest.sh` (+ reuse the S4
`…-concurrency.sh` style if needed).

### A — Authorization / permission (flag FALSE; the production-shaped state)
| # | Assertion |
|---|---|
| A1 | `command_main_ship_space_move` present: definer, owner `postgres`, `search_path=public`, no dynamic SQL (`has_function_privilege` + `pg_proc` metadata). |
| A2 | EXECUTE on the wrapper: **authenticated = yes; anon = no; public = no.** |
| A3 | EXECUTE on `mainship_space_begin_move`: **anon = no, authenticated = no** (unchanged) — REST `403` for both (canonical `…-rest.sh` pattern: admin-minted user + real password-grant JWT). |
| A4 | S2 helpers / `process_mainship_space_arrivals` / `dev_set_main_ship_destroyed` remain non-client-executable (regression). |
| A5 | With flag FALSE, an **authenticated** call to the wrapper returns `feature_disabled` and **writes no** `main_ship_space_movements` / `…_command_receipts` row; ship row unchanged. |

### B — Ownership / isolation (temp flag TRUE)
| # | Assertion |
|---|---|
| B1 | Player A's call only ever affects A's own ship (wrapper derives ship from `auth.uid()`); player B's ship/rows unaffected — **no id accepted from the client.** |
| B2 | Player A cannot SELECT player B's `main_ship_space_movements` (RLS owner-scope regression). |

### C — Target validation & canonicalization (temp flag TRUE; eligible ship)
| # | Assertion |
|---|---|
| C1 | Valid in-bounds target from `home` / `in_space` / `at_location` → success; ship → `in_transit`; exactly one active movement; response timing matches the stored row. |
| C2 | **Canonicalization:** non-integer target (e.g. `12.7, -3.2`) → accepted target returned as integers (`13, -3`); the `main_ship_space_movements` row stores the integers. |
| C3 | Out-of-bounds (`10001`) → `out_of_bounds`, no mutation. |
| C4 | Non-finite (`NaN` / `±Inf`) → `invalid_target`, no mutation. |
| C5 | Zero-distance (target == current position) → `zero_distance`, no mutation. |
| C6 | Over travel cap → `over_travel_cap`, no mutation. |

### D — Idempotency / replay (`p_request_id` is the key — Approved Decision 3)
| # | Assertion |
|---|---|
| D1 | Same `request_id`, same target, repeated → **single** movement; second call replays the identical result (no second row, no second receipt). |
| D2 | Same `request_id`, **different** target → `request_conflict`; no second movement; original intact. |
| D3 | Two raw targets that canonicalize to the **same** integer under one `request_id` → idempotent replay (same hash). |
| D4 | **Different** `request_id` while one movement is active → `busy_coordinate` (one-active-per-ship partial unique index is the backstop); no second movement. |

### E — State / exclusion matrix (temp flag TRUE)
| State | Expected |
|---|---|
| `home` / `legacy_home` | success (origin = base) |
| `in_space` (parked) | success (origin = `space_x/space_y`) |
| `at_location` / `legacy_present` | success (origin = location coord) |
| `in_transit` (coordinate) | `must_stop_first` (OSN-4 deferred — Approved Decision 8) |
| legacy expedition in flight | `busy_legacy` |
| legacy returning | `busy_legacy` |
| `destroyed` | `ship_destroyed` |

### L — Legacy ↔ coordinate mutual exclusion (the headline S6A guarantee)
| # | Assertion |
|---|---|
| L1 | A ship parked `in_space` / in coordinate `in_transit` → legacy `send_main_ship_expedition` **rejects** (record the exact precondition/reason it fails on). |
| L2 | Same ship → legacy `move_main_ship_to_location` **rejects** (no `present` fleet). |
| L3 | A ship in legacy travel → wrapper returns `busy_legacy`; fleet XOR CHECK (`active_movement_id` XOR `active_space_movement_id`) and one-active-per-ship both hold. |
| L4 | **If** L1/L2 rely only on state preconditions and any gap is found → document it and add a *minimal additive guard* in the legacy path (the **only** writer-side change S6A may make, per §0.2), with its own assertion. Otherwise the legacy path is untouched. |

### F — Processor regression (temp flag TRUE)
| # | Assertion |
|---|---|
| F1 | A wrapper-created movement settles via `process_mainship_space_arrivals` to `in_space` at the canonical target; S4 **exactly-once** holds under concurrent processor runs. |

### Restore / cleanup (every run, `if: always()`)
- Flags restored: `mainship_space_movement_enabled=FALSE`, `mainship_send_enabled` to baseline,
  `max_coordinate_travel_seconds=86400`; the S4 cron asserted present @30s; fixture users deleted by
  email pattern; assert final flag state.

### Post-deploy live spot-check (read-only, `osn3-s6a-live-spotcheck.yml`)
- `0060` applied; wrapper present with the approved signature/grants (authenticated-only); writer still
  non-client-executable; canonical client-RPC inventory unchanged + the one new wrapper; **live flags
  unchanged: `mainship_send_enabled=TRUE`, `mainship_space_movement_enabled=FALSE`**; movement/receipt
  tables show **no** rows created by the deploy.

---

## 8. Request-ID generation / retry expectations (documented for the future client; no client code in S6A)

- The future client generates **one** `request_id` (uuid) **when the confirm dialog opens**, not per
  render/keystroke.
- It **reuses** that `request_id` for retries of the **same confirmed target** (network retry, double
  tap) → idempotent replay returns the same result (D1/D3).
- A **new target** ⇒ a **new** `request_id`.
- Same `request_id` + a different target ⇒ `request_conflict` (treat as a client bug; regenerate) (D2).
- A `busy` (transient lock) ⇒ safe to retry with the **same** `request_id`.
- S6A ships **no** client command code — this is the contract S6C will implement against, enforced now
  by the wrapper + writer.

---

## 9. Regression chain (all green before S6A is considered closed)

- **New:** `osn3-s6a-realchain-proof.yml` (§7 matrix) on the full `0001..0060` chain.
- **OSN regression:** S1–S5 real-chain proofs (writer/processor/destruction unchanged), `verify:osn:resolver`.
- **Legacy regression:** `verify:mainship-send`, `verify:mainship-move`, `verify:mainship-repair`
  (legacy path intact; mutual exclusion proven in L-rows).
- **Build:** `build.yml` (`tsc -b` + `vite build`, Node 22) — covers the optional `catalog.ts` read.
- **Deploy:** `deploy-migrations.yml` (`supabase db push` on `supabase/migrations/**`) → then the
  read-only live spot-check (§7).
- *(Frontend deploy `pages.yml` only relevant once S6B/C add UI — not S6A.)*

---

## 10. Acceptance criteria

1. `0060` applies cleanly on the full chain; live confirms `0060` applied.
2. `command_main_ship_space_move` present and hardened (definer / owner `postgres` / `search_path=public`
   / no dynamic SQL); **EXECUTE = authenticated only** (anon + public denied).
3. `mainship_space_begin_move` **unchanged** and still **service_role-only** (anon + authenticated → REST `403`).
4. With production flag **FALSE**, the wrapper returns `feature_disabled` and writes nothing →
   **net player-visible effect: none.**
5. Entire §7 matrix green in disposable CI with the temp flag TRUE; flags restored to baseline and asserted.
6. Writer **core lifecycle logic unchanged** (unless an L4 guard gap was found, documented, and added as
   a minimal additive guard).
7. Legacy named travel proven still working and **mutually exclusive** with coordinate travel.
8. **Production flags unchanged:** `mainship_send_enabled=TRUE`, `mainship_space_movement_enabled=FALSE`.
9. `docs/DEV_LOG.md` + `docs/BYEHARU_PROJECT_GUIDE.md` updated **only on closure** (deployed + verified),
   per the guide-maintenance rule; the charter's S6A status flips to [Implemented] at that point.

---

## 11. Rollback / containment strategy

- **Dark by flag.** The feature is inert in production because `mainship_space_movement_enabled` stays
  FALSE; the wrapper returns `feature_disabled` regardless of deploy. There is **no player-facing
  exposure to roll back** after an S6A deploy.
- **Containment if a wrapper defect is found post-deploy** (migrations are forward-only — never edit in
  place): ship a follow-up migration that `REVOKE`s EXECUTE on the wrapper from `authenticated` (instant
  lockout) or `DROP`s it. Because the writer is untouched, legacy and the internal coordinate lifecycle
  are unaffected by any wrapper issue.
- **No client surface.** S6A ships no command UI, so there is no frontend rollback; the optional
  `catalog.ts` read is an unused export with no behavior.
- **Test-data containment.** All proof state is in disposable Supabase; live mutation is impossible
  because no production flag is flipped and the proof's `if: always()` restore + final assertion guard
  the flag baseline.

---

*Plan only — no code. Next action awaits explicit approval to implement S6A (and only S6A).*
