#!/usr/bin/env bash
# SHIELD ACTIVATION runner — wraps the ONE regenerating-shield flip scripts/activate-shield.sql
# (docs/ACTIVATION_GUIDE.md → ACT-SHIELD; the SHIELD-0/1/2 stack is fully built dark, DATA-gated with
# no shield_enabled flag). ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build time; each
# `run` is the human's recorded go decision.
#
# The activate-repair-econ.sh / activate-haul.sh pattern, shield domain — with ONE deliberate
# difference: this activator WRITES DATA (hull base_shield seed + a monotonic instance backfill),
# because the shield system is data-gated, not flag-gated. The selftest therefore ALLOWS exactly the
# two shield UPDATE statements (on main_ship_hull_types and main_ship_instances) and the two knob
# writes, and still forbids DDL, any other table, and any other window's config key.
# Modes:
#   selftest — DB-free static safety: the operation's writes are exactly (1) a monotonic base_shield
#              seed UPDATE on main_ship_hull_types, (2) a monotonic instance backfill UPDATE on
#              main_ship_instances, and (3) two set_game_config knob writes (shield_regen_combat_pct
#              -> 0.02, shield_regen_idle_pct -> 0.10) — never a flag, never another window's key,
#              never DDL, never any other table; is one timed UTC BEGIN..COMMIT gated on the shield
#              migrations (0191/0195/0197 recorded) + the deployed-body prosrc pins (the 0191 leaf
#              both-clamps, the 0195 ONE-absorb point + combat knob read, the 0197 idle-regen
#              set-statement + idle knob read) + both knobs at the dark seed '0'; contains NO psql
#              meta-command; keeps its ROLLBACK section commented out; documents the FIRST-FLIP
#              re-run semantics and the monotonic/deferred-bump backfill.
#   run      — execute against $DB_URL and assert every stage marker. Requires the typed confirm
#              token as the 2nd arg. No local psql? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead — it is self-contained and meta-command-free.
#
#   bash scripts/activate-shield.sh selftest
#   bash scripts/activate-shield.sh run ACTIVATE_SHIELD              # DB_URL required
#
# FLIP ORDER: pair with the hunting loop — shields only matter in combat.
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_SHIELD]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-shield.sql"
CONFIRM_TOKEN="ACTIVATE_SHIELD"
MARKERS="ACTIVATE_SHIELD_PASS_PRECONDITIONS ACTIVATE_SHIELD_PASS_STAGE1 ACTIVATE_SHIELD_PASS_STAGE2 ACTIVATE_SHIELD_PASS_STAGE3 ACTIVATE_SHIELD_PASS_SMOKE"
PASS_LINE="SHIELD ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere.
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT under txn-local UTC.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -qF "set local time zone 'UTC'" || fail "operation must pin the txn-local timezone to UTC"
  printf '%s' "$CLEAN" | grep -q "20260618000197" || fail "operation must precondition on the 0197 (SHIELD-2) migration head"
  for mv in 20260618000191 20260618000195 20260618000197; do
    printf '%s' "$CLEAN" | grep -qF "'$mv'" || fail "operation must assert migration $mv is recorded as deployed"
  done

  # the deployed-body prosrc pins.
  printf '%s' "$CLEAN" | grep -qF "least(max_shield, greatest(0, p_shield))" || fail "operation must prosrc-pin the 0191 leaf both-clamps"
  printf '%s' "$CLEAN" | grep -qF "least(coalesce(v_shield, 0), v_d_group)" || fail "operation must prosrc-pin the 0195 ONE shield-absorb point"
  printf '%s' "$CLEAN" | grep -qF "cfg_num('shield_regen_combat_pct')" || fail "operation must prosrc-pin the 0195 combat-regen knob read"
  printf '%s' "$CLEAN" | grep -qF "set shield = least(s.max_shield, s.shield + ceil(s.max_shield * v_idle)::integer)" || fail "operation must prosrc-pin the 0197 idle-regen set-statement"
  printf '%s' "$CLEAN" | grep -qF "cfg_num('shield_regen_idle_pct')" || fail "operation must prosrc-pin the 0197 idle-regen knob read"

  # the FIRST-FLIP knob-dark precondition.
  printf '%s' "$CLEAN" | grep -qF "is not the dark seed" || fail "operation must precondition both regen knobs at the dark seed '0' (first-flip guard)"

  # writes: exactly the two knob writes + the two monotonic UPDATEs. NEVER a flag/other-window key,
  # NEVER DDL, NEVER another table.
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "2" ] || fail "operation must have exactly 2 set_game_config call sites (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('shield_regen_combat_pct', '0.02'::jsonb)" || fail "missing shield_regen_combat_pct -> 0.02"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('shield_regen_idle_pct',   '0.10'::jsonb)" || fail "missing shield_regen_idle_pct -> 0.10"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(ship_traits_enabled|salvage_market_enabled|station_affinity_bonus|shipyard_enabled|blueprint_fragment_drop_rate|captain_assignment_enabled|captain_progression_enabled|mining_enabled|trade_market_enabled|haul_contracts_enabled|repair_economy_enabled|launch_from_dock_enabled)'" \
    && fail "operation writes another window's config key (out of the shield window's scope)" || true

  # the two shield data UPDATEs — the sanctioned data writes of this activator (occurrence-counted).
  n="$(printf '%s' "$CLEAN" | grep -c 'update public.main_ship_hull_types h' || true)"
  [ "$n" = "1" ] || fail "operation must carry exactly 1 main_ship_hull_types base_shield seed UPDATE (found $n)"
  printf '%s' "$CLEAN" | grep -qF "h.base_shield < v.bs" || fail "the base_shield seed must be MONOTONIC (raise only where lower)"
  n="$(printf '%s' "$CLEAN" | grep -c 'update public.main_ship_instances i' || true)"
  [ "$n" = "1" ] || fail "operation must carry exactly 1 main_ship_instances backfill UPDATE (found $n)"
  printf '%s' "$CLEAN" | grep -qF "i.max_shield < h.base_shield" || fail "the instance backfill must be MONOTONIC (deferred-bump: only ships below their hull value)"
  # no OTHER direct table DML beyond those two sanctioned UPDATEs.
  n="$(printf '%s' "$CLEAN" | grep -ciE 'update[[:space:]]+public\.[a-z_]+' || true)"
  [ "$n" = "2" ] || fail "operation carries $n UPDATE statements (want exactly the 2 sanctioned shield data writes)"
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|delete[[:space:]]+from)' && fail "operation writes a table via insert/delete (only the 2 shield UPDATEs + set_game_config allowed)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # markers, the final PASS line, the function-existence loop, the rollback + re-run documentation.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL" || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence loop"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL" || fail "operation must document the FIRST-FLIP re-run semantics"
  grep -q "deferred-bump" "$OP_SQL" || fail "operation must document the monotonic deferred-bump backfill"
  grep -qi "ROLLBACK (manual" "$OP_SQL" || fail "missing the marked manual ROLLBACK section"

  echo "SHIELD ACTIVATION SELFTEST: ALL PASSED (2 monotonic shield data UPDATEs + 2 knob writes on the shield window's own keys; single timed UTC BEGIN..COMMIT gated on 0191/0195/0197 recorded + the leaf/tick/reconciler prosrc pins + both knobs at the dark seed; no meta-commands; no flag/other-window/DDL/other-table writes; rollback commented; first-flip + deferred-bump documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "SHIELD ACTIVATION: OVERALL_PASS — regenerating shields live (hulls seeded, instances backfilled born-full, both regen knobs > 0). Manual smoke: hunt with a team and watch a member's shield absorb + refill."
