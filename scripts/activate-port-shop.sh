#!/usr/bin/env bash
# PORT-SHOP ACTIVATION runner — wraps the ONE buy-modules-and-ammo flip scripts/activate-port-shop.sql
# (the PORT-SHOP 0235 stack + the ShopPanel are fully built dark behind port_shop_enabled). ██ HUMAN TOOL ██
# — never wired into CI; each `run` is the human's recorded go decision. The activate-salvage.sh pattern
# (flag flip + a zero-write gate probe), port-shop domain. Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned set_game_config
#              writer, on exactly ONE approved key (port_shop_enabled -> true); is one timed UTC
#              BEGIN..COMMIT gated on 0235 recorded + the buy-RPC gate prosrc pin + the seeded 3×8 offer
#              table (referenced, NOT re-seeded); smokes the buy RPC's gate under a transaction-local fake
#              JWT (advances to ship_not_found for a no-ship subject — the gate opened, zero writes);
#              contains NO psql meta-command; keeps its ROLLBACK commented out.
#   run      — execute against $DB_URL and assert every stage marker. Requires the typed confirm token.
#
#   bash scripts/activate-port-shop.sh selftest
#   bash scripts/activate-port-shop.sh run ACTIVATE_PORT_SHOP           # DB_URL required
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_PORT_SHOP]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-port-shop.sql"
CONFIRM_TOKEN="ACTIVATE_PORT_SHOP"
MARKERS="ACTIVATE_PORTSHOP_PASS_PRECONDITIONS ACTIVATE_PORTSHOP_PASS_STAGE1 ACTIVATE_PORTSHOP_PASS_SMOKE"
PASS_LINE="PORT-SHOP ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"

  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  printf '%s' "$CLEAN" | grep -qiE '\bbegin;'  || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -qF "set local time zone 'UTC'" || fail "operation must pin the txn-local timezone to UTC"
  printf '%s' "$CLEAN" | grep -q "20260618000235" || fail "operation must precondition on the 0235 (PORT-SHOP) migration head"

  printf '%s' "$CLEAN" | grep -qF "port_shop_disabled" || fail "operation must prosrc-pin the buy-RPC dark gate (0235)"
  printf '%s' "$CLEAN" | grep -qF "from public.port_shop_offers" || fail "operation must reference the seeded offer table"
  printf '%s' "$CLEAN" | grep -qF "do not carry exactly 8 active offers" || fail "operation must precondition on the seeded 3×8 offers (accept, not re-seed)"

  # writes: exactly ONE set_game_config on the approved key; NEVER a table DML or DDL.
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('port_shop_enabled', 'true'::jsonb)" || fail "missing port_shop_enabled -> true (the only flag write)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only — the offer table is referenced, never re-seeded)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # the zero-write gate probe under a fake JWT (advances to ship_not_found).
  printf '%s' "$CLEAN" | grep -qF "set_config('request.jwt.claims'," || fail "missing the txn-local fake-JWT for the gate probe"
  printf '%s' "$CLEAN" | grep -qF "public.buy_shop_offer_at_port(gen_random_uuid(), 'autocannon_battery', 1, gen_random_uuid())" || fail "missing the buy-RPC gate probe call"
  printf '%s' "$CLEAN" | grep -qF "ship_not_found" || fail "the gate probe must assert it advanced past the gate to ship_not_found"
  printf '%s' "$CLEAN" | grep -qF "set_config('request.jwt.claims', '', true)" || fail "the fake JWT must be cleared after the probe"

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL" || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence loop"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL" || fail "operation must document the re-run no-op semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL" || fail "missing the marked manual ROLLBACK section"

  echo "PORT-SHOP ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 1 approved key -> true; single timed UTC BEGIN..COMMIT gated on 0235 recorded + the buy-RPC gate pin + the seeded offer table referenced not re-seeded; fake-JWT gate probe advances to ship_not_found; no meta-commands; no table/DDL writes; rollback commented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "PORT-SHOP ACTIVATION: OVERALL_PASS — port outfitter live (buy RPC gate open, ShopPanel mounts off the flag). Manual smoke: dock -> buy a module -> fittable pool + wallet debits; buy ammo -> inventory."
