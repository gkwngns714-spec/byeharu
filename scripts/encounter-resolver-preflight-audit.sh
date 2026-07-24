#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# ENCOUNTER RESOLVER — PRE-FLIP PREFLIGHT AUDIT RUNNER (thin wrapper; READ-ONLY, gated)
#
# ██ Runs scripts/encounter-resolver-preflight-audit.sql against production by DELEGATING to the ONE
# ██ gated read-only-prod entrypoint, scripts/prod-readonly-sql.sh. It adds NO connection/trust logic
# ██ and NO second verifier of its own — compose, do not fork. prod-readonly-sql.sh enforces the
# ██ read-only contract (READ ONLY txn + rollback, no write verb, no activation vocabulary) and supplies
# ██ the pinned-CA / verify-full / Management-API session-pooler connection.
#
# ██ READ-ONLY, ENFORCED BY THE DELEGATE:
# ██   1. the audit .sql opens `begin transaction read only` + ends in `rollback` — Postgres rejects writes.
# ██   2. prod-readonly-sql.sh selftest greps the .sql for write verbs / activation vocabulary and refuses.
# ██   3. Nothing here activates a binding, flips encounter_resolver_enabled, deploys, or approves anything.
#
# MODES
#   selftest     No database, no secrets. Static safety gate (delegates to prod-readonly-sql.sh selftest).
#   production   Gated by the protected `production` GitHub Environment. Read-only.
#
# USAGE
#   scripts/encounter-resolver-preflight-audit.sh selftest
#   scripts/encounter-resolver-preflight-audit.sh production
#
# EXIT: mirrors prod-readonly-sql.sh — 0 ok (selftest pass / audit PASS) · 1 contract or AUDIT FINDINGS ·
#       2 usage · 4 could not establish the approved production connection.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|production) : ;; *) echo "usage: $0 <selftest|production>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/prod-readonly-sql.sh"
AUDIT_SQL="$REPO_ROOT/scripts/encounter-resolver-preflight-audit.sql"

[ -f "$RUNNER" ]    || fail "generic read-only runner not found: scripts/prod-readonly-sql.sh"
[ -f "$AUDIT_SQL" ] || fail "audit sql not found: scripts/encounter-resolver-preflight-audit.sql"
bash -n "$RUNNER" || fail "generic read-only runner is not valid bash"
bash -n "$0"      || fail "this wrapper is not valid bash"

# Delegate. The generic runner re-asserts the read-only contract for BOTH modes before it does anything.
bash "$RUNNER" "$MODE" "$AUDIT_SQL"
exit $?
