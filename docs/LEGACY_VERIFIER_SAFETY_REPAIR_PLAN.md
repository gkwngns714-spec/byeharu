# Legacy Main-Ship Verifier Safety Repair — Reconnaissance & Repair Plan (PLAN ONLY)

> **Status: PLANNING ONLY — local-only, code-free.** No code, commit, push, PR, secret/flag/Environment/
> migration change, no verifier dispatch, no OSN-DOCK-0 / PR #9 change. Awaiting review + explicit
> authorization before implementation.

**Why this is next:** the legacy `verify-mainship-{send,move,repair}` verifiers force
`mainship_send_enabled = false` in their `finally`, so re-running any of them silently disables the legacy
main-ship send feature (this is the directly-evidenced cause of the current `send=false`, last write
`verify-mainship-repair` 2026-06-21T14:40:19Z). They must be repaired **before** any flag restoration or
before they are ever run again.

---

## A. Verified current behavior (read-only evidence)

### Defect 1 — flag restored to a hardcoded `false` (not the captured original)
| Verifier | Captures `origSend`? | Writes `mainship_send_enabled` | `finally` restore |
|---|---|---|---|
| `scripts/verify-mainship-send.mjs` | ❌ no | sets `false` (`:93`) then `true` (`:100`) | **hardcoded** `setCfg('mainship_send_enabled', false)` (`:205`) |
| `scripts/verify-mainship-move.mjs` | ❌ no | sets `true` (`:65`) | **hardcoded** `false` (`:163`) |
| `scripts/verify-mainship-repair.mjs` | ❌ no | sets `true` (`:65`) | **hardcoded** `false` (`:147`) |
| `scripts/verify-mainship-preview.mjs` | n/a | **does not touch the flag** | `finally` only logs (`:79`) — **no flag defect** |

Each captures `origScale`/`origMin` (travel knobs) and restores those correctly — only the **send flag** is
mishandled.

### Defect 2 — test data is never cleaned up
All four create a throwaway user via `newUser()` (emails `mssendtest.` / `msmovetest.` / `msrepairtest.` /
`mspreviewtest.` `<tag>.<timestamp>@example.com`; e.g. `verify-mainship-send.mjs:51-53`). **No** verifier
deletes its user in `finally` — `finally` only restores config (flag + travel). Result: leaked
`auth.users` rows and everything that cascades from them (profiles, bases, base_units, main_ship_instances,
fleets, fleet_units, fleet_movements, main_ship_space_movements, location_presence) accumulate in the **live**
DB. *(`repair`'s `dev_set_main_ship_destroyed` cleanup at `:88-96` is test logic, not teardown.)*

---

## B. Required repair (per verifier; minimal)

### B1 — Capture & restore the original `mainship_send_enabled`
- **Add a capture** of the original value **before** the first `setCfg('mainship_send_enabled', …)`:
  `origSend = await cfgVal('mainship_send_enabled')` (declare `origSend` alongside `origScale`/`origMin`).
- **Replace the hardcoded restore** in `finally` with the captured value:
  `try { if (origSend !== undefined) await setCfg('mainship_send_enabled', origSend) } catch {}`.
- Exact anchors: send — declare `:60`, capture before `:93`, restore `:205`; move — declare `:56`, capture
  before `:65`, restore `:163`; repair — declare `:56`, capture before `:65`, restore `:147`.
- **Net effect:** if `send` was `false` before a run, it ends `false`; if `true`, it ends `true`. The verifier
  never changes the resting flag state.

### B2 — Clean up created test data in `finally`, and prove it
- **Track created user IDs** (push each `newUser()` result to a `createdUserIds[]`).
- **Delete them in `finally`** via the service-role admin API
  (`admin.auth.admin.deleteUser(id)`), which **cascades** to base/units/ship/fleet/units/movements/
  coordinate-movements/presence (all FK `on delete cascade` from `auth.users`/`bases`/`fleets`).
- **Prove zero residue:** after deletion, assert no rows remain for those user IDs across
  `auth.users` + the cascaded tables (or, equivalently, that the IDs no longer exist and no orphan rows
  reference them).
- *(Alternative considered: reuse the existing pattern-based `verify-cleanup.mjs` / `dev-clean-test-users.mjs`.
  Self-tracking by ID is preferred — precise, no cross-run interference, and provable within the same run.)*

### B3 — `finally` ordering / robustness
- `finally` runs on success **and** failure (it already does). Wrap each restore/delete in `try/catch` so a
  later step can't skip an earlier one. **Restore the flag even if cleanup throws, and attempt cleanup even if
  the body aborted early** (track IDs as they're created, not at the end).

**Files changed (repair):** `scripts/verify-mainship-send.mjs`, `…-move.mjs`, `…-repair.mjs`.
**Decision point (P1):** include `verify-mainship-preview.mjs` in the **cleanup** fix (it shares Defect 2 but
not Defect 1)? Recommended **yes** for consistency, but it's outside the user's named three — defer to approval.
**Not changed:** the `.yml` workflows (they just `npm run …`); no flag/secret/Environment/migration change.

---

## C. Proof plan (no production touch)
Prove the repair on a **disposable** stack — never against the shared/live DB — mirroring the project's
real-chain proof pattern:
1. `supabase start` (local disposable stack on the real migration chain); export its env (URL/anon/service_role).
2. **Flag-restore proof (both directions):**
   - set `mainship_send_enabled = true` on the disposable DB → run the repaired verifier → assert the flag is
     **still `true`** afterward (restored to captured original);
   - set it `false` → run → assert **still `false`**.
3. **Cleanup proof:** after each run, assert **zero** residual rows for the run's test users (users +
   cascaded base/ship/fleet/movement/presence) — the disposable DB is clean.
4. **Behavioral parity:** the verifier's own pass/fail assertions still pass on the disposable stack (the
   repair changes only setup-capture + teardown, not the test logic).
5. Static diff review: changes limited to capture + `finally` (restore-original + tracked-delete + residue
   assert); no test-logic change.

*No live-DB run is part of the repair proof. The verifiers stay un-dispatched against prod until repaired +
proven; even then, dispatching them is a separate decision.*

---

## D. Sequencing (per the confirmed order)
1. **Repair** the three (+ optionally preview cleanup) → prove on a disposable stack (C) → PR → review →
   merge (separately authorized).
2. **Separate operational decision** — whether `mainship_send_enabled` should return to `true`; restore it
   (via the `dev-mainship-flag` tool, not the verifiers) **only after** the verifier repair is verified, so it
   can't be silently undone again.
3. **Resume OSN-DOCK-0 / PR #9** — rebase `2961b61` onto current `main`, inspect the fresh diff, rerun its
   required gates, then decide on merge separately.
4. **Phase B** (repo-secret retirement) stays **deferred** pending a new full consumer audit — not urgent.

---

## E. Explicit non-goals / holds
- Do **not** restore `mainship_send_enabled` in this task (that's step D2, separate).
- Do **not** dispatch any `verify-mainship-*` workflow (including to "test" the repair) — proof is
  disposable-stack only.
- Do **not** change `.yml` workflows, secrets, Environment policy, migrations, game code, flags, or OSN-DOCK-0
  / PR #9.
- Do **not** start Phase B secret retirement.

*Plan only — awaiting review + an explicit authorization to begin the repair implementation.*
