# Runbook & design note — controlled starter-port reveal (PORT-LAUNCH-2C)

**Status:** operational path created and proved on a disposable stack. **Not executed.** No port has been
revealed; no production workflow has been dispatched; no production approval gate has been approved.

This document is the design note for the single, narrow, human-gated operation that will (in a *separate,
later, explicitly-approved* step) make the three canonical starter ports public.

---

## 1. The canonical starter-port contract (fixed — never operator-supplied)

The operation targets ONLY the three fixed ids owned by `reveal_starter_ports()` (migrations 0066/0068):

| id | name | role |
|----|------|------|
| `b1a00001-0066-4a00-8a00-000000000001` | Haven Reach | city |
| `b1a00002-0066-4a00-8a00-000000000002` | Slagworks Anchorage | port |
| `b1a00003-0066-4a00-8a00-000000000003` | Driftmarch Waypost | port |

These are the same constants the reveal function uses internally. The workflow accepts **no** port list,
SQL, flag, environment, host, or ref input — there is nothing to inject.

## 2. Hidden/active fields and predicates

- Visibility lives in `public.locations.status` ∈ {`hidden`, `active`}. `get_world_map()` returns only
  `status='active'` locations, so flipping `hidden → active` is exactly "make the port public".
- The reveal itself is `public.reveal_starter_ports()` — service-role-owned, all-or-nothing, one-way:
  - all three hidden ⇒ flips all three to active and returns `{ok:true, revealed:3, already_active:false}`;
  - all three active ⇒ idempotent no-op `{ok:true, revealed:0, already_active:true}`;
  - mixed/invalid ⇒ raises, no write.
- Feature flags: `public.game_config` keys `mainship_send_enabled` (true) and
  `mainship_space_movement_enabled` (false), read with `public.cfg_bool(key)`.

## 3. Transaction boundary (`scripts/reveal-starter-ports-operation.sql`)

One session, one explicit `BEGIN … COMMIT` with conservative `lock_timeout`/`statement_timeout`/
`idle_in_transaction_session_timeout`. Inside it:

1. lock the three canonical port rows (`FOR UPDATE`, id order) so the snapshot→reveal→postcondition window
   is atomic against any concurrent change;
2. snapshot the canonical port state, the total active-location count, and both flags;
3. **assert preconditions** — exactly 3 canonical rows, all hidden, none active, `send=true`, `space=false`
   (reveal is **not** called unless all hold);
4. call `reveal_starter_ports()` **exactly once**;
5. **assert postconditions** — same 3 ports now active; net active-location change exactly `+3` (nothing
   else moved); no canonical port left non-active; both flags byte-for-byte unchanged;
6. emit machine-readable markers (`PRECONDITIONS_PASS=true … REVEAL_OPERATION_PASS=true`);
7. `COMMIT` only if every assertion passed.

Any failed assertion / SQL error / timeout aborts the `DO` block; under `ON_ERROR_STOP` the session stops
before `COMMIT`, so the transaction is **rolled back** — fail-closed, no partial write.

## 4. One-shot / rerun behaviour

A second run after a successful reveal hits the precondition "a canonical port is already active" and **fails
closed before calling `reveal_starter_ports()` again**. "Already active" is treated as an error, never as
success — the operation never re-invokes the reveal.

## 5. No-retry rule (uncertain connectivity)

The workflow runs the operation in **one** `psql` invocation with **no** automatic retry. If connectivity is
lost or the result is uncertain, the job fails closed. A later human must run a **separate read-only
post-reveal verification** to learn the true state before deciding whether any follow-up is appropriate.
Re-dispatching is also safe by construction: if the first attempt actually committed, the rerun fails closed
at the precondition (already active); if it did not, the precondition still holds and a fresh approved run
may proceed.

## 6. Trigger, gate, connection

- `workflow_dispatch` only; runs **only** from `refs/heads/main`; requires the typed confirmation
  `REVEAL_THREE_STARTER_PORTS` (checked before any DB connection); gated by the protected `production`
  GitHub Environment (human approval); concurrency group `starter-port-reveal-production`,
  `cancel-in-progress: false`; `permissions: contents: read`; shell tracing disabled (secrets never printed).
- Connection = the proven **Supabase Management-API session-pooler + pinned CA (`807025ad…`) +
  `sslmode=verify-full`** path, identical to the read-only catalog verifier. No direct host, no weakened
  TLS, no new connection pattern.

## 7. Separation from the post-reveal verifier

This workflow **only reveals**. It does **not** verify afterward, change flags, enable OSN, assign home
ports, or run onboarding. The authoritative post-reveal check is the **separate, human-gated, read-only**
production catalog verifier (`osn-hub1a-production-catalog-verify.yml`), whose `A9` block already proves the
pre-reveal preconditions and which, after a reveal, would confirm the three ports active + flags still off.

## 8. Sequence (each step separately, explicitly approved)

1. (this PR) merge the operational path — changes no production state.
2. Separate human-gated **read-only pre-reveal** production catalog verification.
3. Separate human-gated **reveal** (this workflow) — one-way.
4. Immediately after: separate human-gated **read-only post-reveal** verification.
5. Much later, fully separate: the OSN flag-enable decision (`mainship_space_movement_enabled = true`).

Throughout reveal and early onboarding: **`mainship_space_movement_enabled = false`**.
