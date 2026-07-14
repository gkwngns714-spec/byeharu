#!/usr/bin/env bash
# REPAIR-ECON ACTIVATION runner — wraps the ONE repair flip operation scripts/activate-repair-econ.sql
# (docs/FULL_CAPACITY_PLAN.md §C P9 "REPAIR-ECON"; gap G8; the ACT-REPAIR closer). The repair economy
# stack (migration 0201) is fully built dark. ██ HUMAN TOOL ██ — never wired into CI; nothing flips at
# build time; each `run` is the human's recorded go decision. The activate-haul.sh pattern, repair domain.
# Modes:
#   selftest — DB-free static safety: the operation's only DIRECT write is game_config, via the owned
#              set_game_config writer, on exactly ONE approved key (repair_economy_enabled -> true),
#              never a knob rewrite and never another window's flag; it NEVER writes repair_receipts /
#              main_ship_instances; is one timed UTC BEGIN..COMMIT gated on the 0201 migration recorded
#              + the deployed-body prosrc pins (the paid RPC's gate + ship_destroyed seam; the free
#              safelock repair_main_ship UNGATED + destroyed-only) + the knob sane + the ACL posture;
#              smokes the paid RPC's gate transition under a transaction-local fake JWT (a no-ship
#              subject -> ship_not_found, proving the gate opened while writing nothing); contains NO
#              psql meta-command (management-API compatible); keeps its ROLLBACK section commented out.
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and assert
#              every stage marker. Requires the typed confirm token as the 2nd arg. No local psql? Paste
#              the .sql into the Supabase Dashboard SQL editor / management-API runner (self-contained,
#              self-asserting, meta-command-free).
#
#   bash scripts/activate-repair-econ.sh selftest
#   bash scripts/activate-repair-econ.sh run ACTIVATE_REPAIR              # DB_URL required
#
# FLIP ORDER: independent — repair needs only credits (Rung 3) and a docked damaged ship; no other flag
# is a hard precondition (a repair with no credits simply returns insufficient_credits). AFTER a green run:
#   1. NO separate client PR — the RepairPanel ships dark in THIS slice, mounted on the Port screen main
#      rail (PortScreen.tsx, the SalvageMarketPanel neighbour), gated on repair_economy_enabled read from
#      public game_config; it appears on the next docked Port render.
#   2. Manual smoke: dock a DAMAGED ship -> the Repair desk shows the hull bar + cost -> Repair (full or
#      partial) -> wallet debits hp_restored x repair_credits_per_hp (0.5), hull mends; a destroyed ship
#      still shows the FREE recovery (unchanged).
# Rollback: the commented section at the bottom of the .sql (ONE reverse config write; the panel vanishes
# on its next read; past repairs stand; the free safelock is unaffected).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_REPAIR]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-repair-econ.sql"
CONFIRM_TOKEN="ACTIVATE_REPAIR"
MARKERS="ACTIVATE_REPAIR_PASS_PRECONDITIONS ACTIVATE_REPAIR_PASS_STAGE1 ACTIVATE_REPAIR_PASS_SMOKE"
PASS_LINE="REPAIR ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere.
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # exactly ONE timed BEGIN..COMMIT under txn-local UTC.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"

  # preconditions: the 0201 migration recorded + the function-existence loop over the REAL signatures.
  printf '%s' "$CLEAN" | grep -q "20260618000201" || fail "operation must precondition on the 0201 migration head/recorded"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence loop"
  for fn in "public.repair_ship_hull_at_port(uuid, numeric, uuid)" "public.repair_main_ship(uuid)" \
            "public.wallet_debit(uuid, numeric)" "public.mainship_resolve_owned_ship(uuid, uuid)" \
            "public.mainship_resolve_docked_location(uuid)" "public.cfg_bool(text)" \
            "public.cfg_num(text)" "public.set_game_config(text, jsonb)"; do
    printf '%s' "$CLEAN" | grep -qF "'$fn'" || fail "preconditions do not cover $fn"
  done

  # the deployed-body pins: the paid RPC gate + seam, and ██ the SAFELOCK PRECONDITION ██ (the free
  # path stays ungated + destroyed-only).
  printf '%s' "$CLEAN" | grep -qF "position('repair_economy_disabled' in v_src)" || fail "operation must prosrc-pin the paid-RPC dark gate reject"
  printf '%s' "$CLEAN" | grep -qF "position('ship_destroyed' in v_src)" || fail "operation must prosrc-pin the paid-RPC destroyed-safelock seam"
  printf '%s' "$CLEAN" | grep -qF "position('repair_economy_enabled' in v_src) <> 0" || fail "operation must prosrc-pin that repair_main_ship does NOT reference the economy flag (ungated safelock)"
  printf '%s' "$CLEAN" | grep -qF "position('ship is not disabled' in v_src)" || fail "operation must prosrc-pin repair_main_ship's destroyed-only guard (the safelock is unchanged)"

  # the knob is sanity-asserted, READ-ONLY (never rewritten).
  printf '%s' "$CLEAN" | grep -qF "repair_credits_per_hp" || fail "operation must sanity-assert the repair_credits_per_hp knob"

  # writes: exactly ONE set_game_config call site on the ONE approved key -> true; never a knob
  # rewrite, another window's flag, direct table DML, or DDL.
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('repair_economy_enabled', 'true'::jsonb)" || fail "missing repair_economy_enabled -> true (the only flag write)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(repair_credits_per_hp|repair_parts_per_hp|salvage_market_enabled|trade_market_enabled|haul_contracts_enabled|exploration_enabled|mining_enabled|team_command_enabled|ranking_enabled|world_balance_enabled|phase20_polish_enabled)'" \
    && fail "operation writes a knob or another window's key (out of the repair window's scope)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # smoke: the zero-write gate probe under a cleared txn-local fake JWT (no-ship subject -> ship_not_found).
  printf '%s' "$CLEAN" | grep -qF "set_config('request.jwt.claims'," || fail "missing the txn-local fake-JWT gate probe (the proofs' technique)"
  printf '%s' "$CLEAN" | grep -qF "public.repair_ship_hull_at_port(gen_random_uuid()" || fail "missing the paid-RPC gate-open smoke call"
  printf '%s' "$CLEAN" | grep -qF "distinct from 'ship_not_found'" || fail "the gate-open smoke must assert the RPC advances past the gate to ship_not_found"
  printf '%s' "$CLEAN" | grep -qF "set_config('request.jwt.claims', '', true)" || fail "the fake JWT must be cleared after the smoke"
  printf '%s' "$CLEAN" | grep -qF "from public.repair_receipts" || fail "missing the repair_receipts sanity select"

  # markers + final PASS + documentation.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                        || fail "missing final PASS line"
  grep -q "THE SAFELOCK PRECONDITION" "$OP_SQL"         || fail "operation must document the free-safelock-stays-ungated precondition (the G8 mandate)"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"                  || fail "operation must document the re-run no-op semantics"
  grep -q "NO SEPARATE CLIENT PR IS NEEDED" "$OP_SQL"   || fail "operation must document that the panel ships dark in-slice (no compile constant)"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                 || fail "missing the marked manual ROLLBACK section"

  echo "REPAIR-ECON ACTIVATION SELFTEST: ALL PASSED (set_game_config-only direct write on the 1 approved key -> true; single timed UTC BEGIN..COMMIT gated on 0201 recorded + the paid-RPC gate/seam pins + the ungated-safelock precondition + the sane knob + the ACL; zero-write gate-open smoke under a cleared txn-local fake JWT; no meta-commands; no knob/other-window/direct-table/DDL writes; rollback commented; the safelock + re-run + in-slice-panel documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "REPAIR-ECON ACTIVATION: OVERALL_PASS — the paid hull-repair economy is live server-side. NO separate client PR needed — the RepairPanel mounts dark in this slice on the Port screen main rail. Manual smoke: dock a DAMAGED ship -> Repair desk -> pay hp_restored x 0.5 -> hull mends; destroyed ships still recover free."
