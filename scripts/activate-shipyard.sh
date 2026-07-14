#!/usr/bin/env bash
# SHIPYARD ACTIVATION runner — wraps ██ THE BUILD-LOOP UNLOCK ██ scripts/activate-shipyard.sql
# (docs/ACTIVATION_GUIDE.md → ACT-SHIPYARD; the 0185/0188/0194 stack is fully built dark behind
# shipyard_enabled + the blueprint_fragment_drop_rate='0' faucet). ██ HUMAN TOOL ██ — never wired
# into CI; each `run` is the human's recorded go decision.
#
# The activate-haul.sh pattern (a config flip hard-gated on a dependency), shipyard domain. Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly TWO approved keys (shipyard_enabled -> true,
#              blueprint_fragment_drop_rate -> 0.15) — never another window's key, never a table,
#              never DDL; is one timed UTC BEGIN..COMMIT gated on 0185/0188/0194 recorded + ██ the
#              HARD mining gate (mining_enabled committed true — the ore/crystal faucet) ██ + the
#              order-RPC gate prosrc pin + the loot faucet hunk + ██ SHIPYARD-2's hull-aware cancel
#              refund pin (0194) ██ + ██ the REACHABILITY check (every recipe ingredient has a live
#              faucet, else RAISE) ██ + the flag/faucet at their dark seeds; contains NO psql
#              meta-command; keeps its ROLLBACK commented out; documents the dependency chain and the
#              FIRST-FLIP re-run semantics.
#   run      — execute against $DB_URL and assert every stage marker. Requires the typed confirm
#              token as the 2nd arg. No local psql? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead.
#
#   bash scripts/activate-shipyard.sh selftest
#   bash scripts/activate-shipyard.sh run ACTIVATE_SHIPYARD         # DB_URL required
#
# FLIP ORDER: AFTER ACT-MINING (ore/crystal) and with COMBAT live (weapon_parts / the now-open
# blueprint faucet). The script hard-preconditions mining_enabled and verifies every ingredient faucet.
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_SHIPYARD]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-shipyard.sql"
CONFIRM_TOKEN="ACTIVATE_SHIPYARD"
MARKERS="ACTIVATE_SHIPYARD_PASS_PRECONDITIONS ACTIVATE_SHIPYARD_PASS_STAGE1 ACTIVATE_SHIPYARD_PASS_STAGE2 ACTIVATE_SHIPYARD_PASS_SMOKE"
PASS_LINE="SHIPYARD ACTIVATION PASS"

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
  printf '%s' "$CLEAN" | grep -q "20260618000194" || fail "operation must precondition on the 0194 (SHIPYARD-2) migration head"
  for mv in 20260618000185 20260618000188 20260618000194; do
    printf '%s' "$CLEAN" | grep -qF "'$mv'" || fail "operation must assert migration $mv is recorded as deployed"
  done

  # ██ the HARD mining gate ██ — raw AND cfg_bool.
  printf '%s' "$CLEAN" | grep -qF "key = 'mining_enabled'" || fail "operation must assert the raw mining_enabled value (the ore/crystal faucet gate)"
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('mining_enabled')" || fail "operation must assert mining_enabled through cfg_bool"

  # deployed-body prosrc pins.
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('shipyard_enabled'" || fail "operation must prosrc-pin the order-RPC shipyard_enabled gate (0188)"
  printf '%s' "$CLEAN" | grep -qF "blueprint_fragment_drop_rate" || fail "operation must reference the blueprint faucet knob"
  printf '%s' "$CLEAN" | grep -qF "p_wave >= 8" || fail "operation must prosrc-pin the w>=8 blueprint faucet hunk (0185)"

  # ██ SHIPYARD-2's hull-aware cancel refund pin (0194) ██
  printf '%s' "$CLEAN" | grep -qF "from hull_build_receipts" || fail "operation must prosrc-pin the 0194 cancel refund receipt-bill read"
  printf '%s' "$CLEAN" | grep -qF "hull_cancel:" || fail "operation must prosrc-pin the 0194 keyed inventory_deposit cancel refund"
  printf '%s' "$CLEAN" | grep -qF "lets a cancel EAT" || fail "operation must document/enforce the 0194 cancel-refund pre-flip requirement"

  # ██ the REACHABILITY check ██ — every ingredient faucet, RAISE if unbuildable.
  printf '%s' "$CLEAN" | grep -qF "select distinct item_id from public.hull_recipe_ingredients" || fail "operation must loop every distinct recipe ingredient for a faucet"
  printf '%s' "$CLEAN" | grep -qF "from public.mining_fields" || fail "operation must check the mining faucet for ore/crystal"
  printf '%s' "$CLEAN" | grep -qF "from public.exploration_sites" || fail "operation must check the exploration one-shot faucet"
  printf '%s' "$CLEAN" | grep -qF "NO live faucet" || fail "operation must RAISE when an ingredient has no faucet (unbuildable)"

  # the FIRST-FLIP dark-seed preconditions.
  printf '%s' "$CLEAN" | grep -qF "shipyard_enabled is not ''false''" || fail "operation must precondition the flag at 'false' (first-flip)"
  printf '%s' "$CLEAN" | grep -qF "blueprint_fragment_drop_rate is not the dark seed" || fail "operation must precondition the faucet at the dark seed '0' (first-flip)"

  # writes: exactly TWO set_game_config on the approved keys; NEVER another window's key, table, DDL.
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "2" ] || fail "operation must have exactly 2 set_game_config call sites (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('shipyard_enabled', 'true'::jsonb)" || fail "missing shipyard_enabled -> true"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('blueprint_fragment_drop_rate', '0.15'::jsonb)" || fail "missing blueprint_fragment_drop_rate -> 0.15"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(ship_traits_enabled|salvage_market_enabled|station_affinity_bonus|shield_regen_combat_pct|shield_regen_idle_pct|captain_assignment_enabled|mining_enabled|trade_market_enabled|haul_contracts_enabled)'" \
    && fail "operation writes another window's config key (out of the shipyard window's scope)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL" || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence loop"
  grep -q "THE DEPENDENCY CHAIN" "$OP_SQL" || fail "operation must document the mining+combat dependency chain"
  grep -q "REACHABILITY FINDING" "$OP_SQL" || fail "operation must state the build-loop reachability finding"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL" || fail "operation must document the FIRST-FLIP re-run semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL" || fail "missing the marked manual ROLLBACK section"

  echo "SHIPYARD ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 2 approved keys -> true/0.15; single timed UTC BEGIN..COMMIT gated on 0185/0188/0194 recorded + the HARD mining gate + the order-RPC gate pin + the loot faucet hunk + the 0194 hull-aware cancel-refund pin + the per-ingredient reachability check + the flag/faucet dark seeds; no meta-commands; no other-window/table/DDL writes; rollback commented; dependency chain + reachability finding + first-flip documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "SHIPYARD ACTIVATION: OVERALL_PASS — build loop unlocked (flag + blueprint faucet open; every recipe ingredient sourced). Requires mining + combat lit. Next: a build-order UI (SHIPYARD-3)."
