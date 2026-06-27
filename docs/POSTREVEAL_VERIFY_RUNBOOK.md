# Runbook & design note — independent post-reveal verification (PORT-LAUNCH-2E)

**Status:** verifier built and proved on a disposable stack. **Not run against production** during this phase.

This is the **independent, read-only** check that the live production state matches the approved *post-reveal*
baseline (the three canonical starter ports are **active/public**), separate from the reveal workflow's own
transaction log.

## 1. Why the existing dark-state verifier cannot be reused

`osn-hub1a-production-catalog-verify.*` is a **dark-state** verifier: its `P1_OK/P2_OK/P3_OK` assert
`status='hidden'` and `MAP_LEAK/MAP_LEAK_ID` assert the ports are **absent** from `get_world_map()`. After the
reveal those checks are the exact inverse of reality, so it would (correctly) fail by design. It is left
**unchanged** — it remains the authoritative *pre-reveal / dark-state* verifier. PORT-LAUNCH-2E adds a new,
post-reveal-specific verifier instead of weakening that one.

## 2. What the post-reveal verifier asserts (read-only)

**Server-side catalog** (`scripts/postreveal-verify.sql`): migration head `0068`; exactly three canonical
starter ports exist; all three **active**; **zero hidden**; each matches its approved identity (name / role /
coords / active parent hierarchy); no unexpected role-bearing location; the three canonical anchors + docking
services intact; `mainship_send_enabled=true`; `mainship_space_movement_enabled=false`.

**Authenticated/public read boundary** via the existing `get_world_map()` wrapper (which filters
`status='active'` and exposes `id/name/type` — never `physical_role`): the three canonical active ports are
returned; no hidden starter-port record is exposed (structurally impossible — the RPC returns only active);
no unexpected extra starter-family port id is exposed; only active locations appear.

It tests **both** layers (catalog **and** the public boundary), never merely raw rows. It requires/creates
**no** test player and never assigns a home port.

## 3. Read-only enforcement

One `BEGIN … ISOLATION LEVEL REPEATABLE READ READ ONLY` + `SET LOCAL default_transaction_read_only = on`
snapshot that emits only `KEY=value` lines and `ROLLBACK`s. The DB-free self-test enforces a SQL allowlist
(`BEGIN/SET LOCAL/SELECT/WITH/ROLLBACK` only), no write/DDL keyword outside string literals, the read-only
gate before the first query, and that `reveal_starter_ports` never appears. Connection = pinned-CA
(`807025ad…`) + `sslmode=verify-full` + Management-API session pooler (`postgres.<ref>`, port 5432); weaker
TLS / port 6543 / system CA and target-override env vars are rejected.

## 4. Fail-closed behavior

`OVERALL_PASS=false` (non-zero exit) if: head ≠ `0068`; canonical active ≠ 3; any canonical hidden; any
unexpected starter-port state; either flag differs; the map boundary omits a canonical port or exposes an
unexpected/hidden one; or the read-only gate is not `on`.

Output markers: `MIGRATION_HEAD`, `CANONICAL_PORTS_EXPECTED/ACTIVE/HIDDEN`, `UNEXPECTED_PORT_STATE_CHANGES`,
`AUTHENTICATED_MAP_PORTS_EXPECTED/VISIBLE`, `MAINSHIP_SEND_ENABLED`, `MAINSHIP_SPACE_MOVEMENT_ENABLED`,
`OVERALL_PASS`.

## 5. Disposable proof (no production)

`ok[1]` post-reveal active state passes · `ok[2]` a hidden canonical port fails · `ok[3]` wrong active-port
count fails · `ok[4]` feature-flag change fails · `ok[5]` map omission **and** unexpected exposure fail ·
`ok[6]` scope guard (no migration/frontend/flag/onboarding/OSN change). The disposable post-reveal state is
created by a **direct status update** on the throwaway stack — `reveal_starter_ports()` is **never** called.

## 6. Workflows

- `postreveal-verify.yml` — `workflow_dispatch` only, `refs/heads/main` only, `environment: production`
  (human-gated), `permissions: contents: read`, a DB-free self-test gate, then the read-only verification.
  **Not dispatched during PORT-LAUNCH-2E.**
- `postreveal-verify-proof.yml` — disposable proof (no `environment:`): self-test + scope guard + the
  verification matrix.

## 7. Sequence

The reveal (PORT-LAUNCH-2D) already executed and was verified in-transaction. This verifier provides the
**independent** read-only confirmation. After this PR is merged, dispatching `postreveal-verify.yml` against
production is a **separate, explicit, human-gated** decision. Throughout: `mainship_space_movement_enabled = false`.
