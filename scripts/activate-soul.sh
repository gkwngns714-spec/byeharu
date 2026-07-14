#!/usr/bin/env bash
# SOUL ACTIVATION runner — wraps the ONE ship-traits flip scripts/activate-soul.sql
# (docs/ACTIVATION_GUIDE.md → ACT-SOUL; the SOUL-0/1 stack is fully built dark behind
# ship_traits_enabled). ██ HUMAN TOOL ██ — never wired into CI; each `run` is the human's recorded
# go decision.
#
# The activate-haul.sh pattern (flag flip BEFORE a sanctioned writer invoke), soul domain. Modes:
#   selftest — DB-free static safety: the operation's only DIRECT write is game_config on exactly ONE
#              approved key (ship_traits_enabled -> true), via the owned set_game_config writer; its
#              ONE other mutation is the SANCTIONED backfill — soul_roll_traits_for_ship() called per
#              soul-less ship (idempotent, on-conflict-do-nothing); it NEVER writes the trait tables
#              directly; is one timed UTC BEGIN..COMMIT gated on the soul migrations (0186/0193
#              recorded) + ██ the CATALOG-FREEZE precondition (exactly 8 trait types) ██ + the
#              deployed-body prosrc pins (the idempotent roll insert, the knob-gated adapter fold,
#              the commission roll hook) + the flag reading false; contains NO psql meta-command;
#              keeps its ROLLBACK commented out; documents the flag-BEFORE-backfill ordering, the
#              catalog freeze, and the FIRST-FLIP / idempotent-backfill semantics.
#   run      — execute against $DB_URL and assert every stage marker. Requires the typed confirm
#              token as the 2nd arg. No local psql? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead.
#
#   bash scripts/activate-soul.sh selftest
#   bash scripts/activate-soul.sh run ACTIVATE_SOUL                 # DB_URL required
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_SOUL]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-soul.sql"
CONFIRM_TOKEN="ACTIVATE_SOUL"
MARKERS="ACTIVATE_SOUL_PASS_PRECONDITIONS ACTIVATE_SOUL_PASS_STAGE1 ACTIVATE_SOUL_PASS_STAGE2 ACTIVATE_SOUL_PASS_SMOKE"
PASS_LINE="SOUL ACTIVATION PASS"

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
  printf '%s' "$CLEAN" | grep -q "20260618000193" || fail "operation must precondition on the 0193 (SOUL-1) migration head"
  for mv in 20260618000186 20260618000193; do
    printf '%s' "$CLEAN" | grep -qF "'$mv'" || fail "operation must assert migration $mv is recorded as deployed"
  done

  # ██ the CATALOG-FREEZE precondition ██
  printf '%s' "$CLEAN" | grep -qF "from public.ship_trait_types" || fail "operation must precondition on the trait catalog count"
  printf '%s' "$CLEAN" | grep -qiE 'holds % rows \(want the FROZEN 8' || fail "operation must assert the catalog is frozen at exactly 8 (the ACT-SOUL catalog-freeze law)"

  # deployed-body prosrc pins.
  printf '%s' "$CLEAN" | grep -qF "on conflict (main_ship_id, slot) do nothing" || fail "operation must prosrc-pin the idempotent roll insert (0186)"
  printf '%s' "$CLEAN" | grep -qF "if v_traits_enabled then" || fail "operation must prosrc-pin the knob-gated adapter trait fold (0193)"
  printf '%s' "$CLEAN" | grep -qF "perform public.soul_roll_traits_for_ship(" || fail "operation must prosrc-pin the commission roll hook (0193) AND invoke the sanctioned backfill"

  # writes: exactly ONE set_game_config on the approved key + the ONE sanctioned backfill invoke;
  # NEVER another window's key, NEVER direct trait-table DML, NEVER DDL.
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('ship_traits_enabled', 'true'::jsonb)" || fail "missing ship_traits_enabled -> true (the only flag write)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(salvage_market_enabled|station_affinity_bonus|shipyard_enabled|blueprint_fragment_drop_rate|shield_regen_combat_pct|shield_regen_idle_pct|captain_assignment_enabled|mining_enabled|trade_market_enabled)'" \
    && fail "operation writes another window's config key (out of the soul window's scope)" || true
  # the backfill invoke — occurrence-counted (roll writer called exactly once as a perform).
  n="$(printf '%s' "$CLEAN" | grep -oE ':=[[:space:]]+public\.soul_roll_traits_for_ship\(' | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must invoke the sanctioned roll writer exactly ONCE in the backfill loop (found $n)"
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config + the roll invoke only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # backfill idempotence: rolls only soul-less ships.
  printf '%s' "$CLEAN" | grep -qF "not exists (select 1 from public.main_ship_traits t" || fail "the backfill must roll ONLY ships with no existing soul rows (idempotence)"

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL" || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence loop"
  grep -q "ORDERED BEFORE THE BACKFILL" "$OP_SQL" || fail "operation must document the flag-BEFORE-backfill ordering (the roll writer gate-rejects while dark)"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL" || fail "operation must document the FIRST-FLIP / idempotent-backfill semantics"
  grep -q "CATALOG-FREEZE PRECONDITION" "$OP_SQL" || fail "operation must document the catalog-freeze precondition"
  grep -qi "ROLLBACK (manual" "$OP_SQL" || fail "missing the marked manual ROLLBACK section"

  echo "SOUL ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 1 approved key -> true + exactly 1 sanctioned roll-writer backfill invoke; single timed UTC BEGIN..COMMIT gated on 0186/0193 recorded + the catalog-freeze-at-8 + the roll/fold/hook prosrc pins + flag false; no meta-commands; no other-window/direct-table/DDL writes; rollback commented; ordering + freeze + first-flip documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "SOUL ACTIVATION: OVERALL_PASS — ship traits live (flag flipped, existing ships backfilled with deterministic birthmarks). NO client PR needed for the gameplay fold."
