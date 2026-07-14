#!/usr/bin/env bash
# SALVAGE ACTIVATION runner — wraps the ONE sell-loot flip scripts/activate-salvage.sql
# (docs/ACTIVATION_GUIDE.md → ACT-SALVAGE; the SALVAGE 0174 stack + the SALVAGE-2 UI #128 are fully
# built dark behind salvage_market_enabled). ██ HUMAN TOOL ██ — never wired into CI; each `run` is
# the human's recorded go decision.
#
# The activate-repair-econ.sh pattern (flag flip + a zero-write gate probe), salvage domain. Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly ONE approved key (salvage_market_enabled -> true) —
#              never another window's key, never a table, never DDL; is one timed UTC BEGIN..COMMIT
#              gated on 0174 recorded + the sell-RPC gate prosrc pin + the seeded 3×5 demand table
#              (referenced, NOT re-seeded); smokes the sell RPC's gate under a transaction-local fake
#              JWT (advances to ship_not_found for a no-ship subject — the gate opened, zero writes);
#              contains NO psql meta-command; keeps its ROLLBACK commented out; documents the
#              already-mounted SALVAGE-2 UI and the re-run no-op.
#   run      — execute against $DB_URL and assert every stage marker. Requires the typed confirm
#              token as the 2nd arg. No local psql? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead.
#
#   bash scripts/activate-salvage.sh selftest
#   bash scripts/activate-salvage.sh run ACTIVATE_SALVAGE           # DB_URL required
#
# FLIP ORDER: pair with the hunting loop — salvage sells combat loot.
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_SALVAGE]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-salvage.sql"
CONFIRM_TOKEN="ACTIVATE_SALVAGE"
MARKERS="ACTIVATE_SALVAGE_PASS_PRECONDITIONS ACTIVATE_SALVAGE_PASS_STAGE1 ACTIVATE_SALVAGE_PASS_SMOKE"
PASS_LINE="SALVAGE ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"

  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -qF "set local time zone 'UTC'" || fail "operation must pin the txn-local timezone to UTC"
  printf '%s' "$CLEAN" | grep -q "20260618000174" || fail "operation must precondition on the 0174 (SALVAGE) migration head"

  # deployed-body gate pin + the seeded-table reference (never re-seeded).
  printf '%s' "$CLEAN" | grep -qF "salvage_market_disabled" || fail "operation must prosrc-pin the sell-RPC dark gate (0174)"
  printf '%s' "$CLEAN" | grep -qF "from public.port_item_demand" || fail "operation must reference the seeded demand table"
  printf '%s' "$CLEAN" | grep -qF "do not carry exactly 5 active demand rows" || fail "operation must precondition on the seeded 3×5 demand rows (accept, not re-seed)"

  # writes: exactly ONE set_game_config on the approved key; NEVER another window's key, table DML, DDL.
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('salvage_market_enabled', 'true'::jsonb)" || fail "missing salvage_market_enabled -> true (the only flag write)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(ship_traits_enabled|station_affinity_bonus|shipyard_enabled|blueprint_fragment_drop_rate|shield_regen_combat_pct|shield_regen_idle_pct|captain_assignment_enabled|mining_enabled|trade_market_enabled)'" \
    && fail "operation writes another window's config key (out of the salvage window's scope)" || true
  # a re-seed of the demand table would be an INSERT/UPDATE against it — forbidden here.
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only — the price table is referenced, never re-seeded)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # the zero-write gate probe under a fake JWT (advances to ship_not_found).
  printf '%s' "$CLEAN" | grep -qF "set_config('request.jwt.claims'," || fail "missing the txn-local fake-JWT for the gate probe"
  printf '%s' "$CLEAN" | grep -qF "public.sell_item_at_port(gen_random_uuid(), 'scrap', 1, gen_random_uuid())" || fail "missing the sell-RPC gate probe call"
  printf '%s' "$CLEAN" | grep -qF "ship_not_found" || fail "the gate probe must assert it advanced past the gate to ship_not_found"
  printf '%s' "$CLEAN" | grep -qF "set_config('request.jwt.claims', '', true)" || fail "the fake JWT must be cleared after the probe"

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL" || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence loop"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL" || fail "operation must document the re-run no-op semantics"
  grep -q "SALVAGE-2 UI already ships" "$OP_SQL" || fail "operation must document the already-mounted SALVAGE-2 UI"
  grep -qi "ROLLBACK (manual" "$OP_SQL" || fail "missing the marked manual ROLLBACK section"

  echo "SALVAGE ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 1 approved key -> true; single timed UTC BEGIN..COMMIT gated on 0174 recorded + the sell-RPC gate pin + the seeded demand table referenced not re-seeded; fake-JWT gate probe advances to ship_not_found; no meta-commands; no other-window/table/DDL writes; rollback commented; UI + re-run documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "SALVAGE ACTIVATION: OVERALL_PASS — port salvage market live (sell RPC gate open, SALVAGE-2 UI mounts off the flag). Manual smoke: dock with loot -> sell -> wallet credits."
