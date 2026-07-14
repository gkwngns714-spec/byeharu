#!/usr/bin/env bash
# DECKS-3 ACTIVATION runner — wraps the ONE station-affinity flip scripts/activate-decks3.sql
# (docs/ACTIVATION_GUIDE.md → ACT-DECKS3; the 0196 affinity fold is fully built dark behind the
# station_affinity_bonus='0' knob). ██ HUMAN TOOL ██ — never wired into CI; each `run` is the
# human's recorded go decision.
#
# The activate-captains.sh / activate-haul.sh pattern (a config write hard-gated on another window),
# decks-3 domain. Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly ONE approved key (station_affinity_bonus -> 0.15) —
#              never a flag, never another window's key, never a table, never DDL; is one timed UTC
#              BEGIN..COMMIT gated on 0196 recorded + ██ the HARD captains gate (captain_assignment_
#              enabled committed true) ██ + the 0196 adapter prosrc pins (knob read, LEFT station
#              join, affinity CASE) + the 6-station catalog + the knob at the dark seed '0'; contains
#              NO psql meta-command; keeps its ROLLBACK commented out; documents the captains-first
#              flip order and the FIRST-FLIP re-run semantics.
#   run      — execute against $DB_URL and assert every stage marker. Requires the typed confirm
#              token as the 2nd arg. No local psql? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead.
#
#   bash scripts/activate-decks3.sh selftest
#   bash scripts/activate-decks3.sh run ACTIVATE_DECKS3             # DB_URL required
#
# FLIP ORDER: AFTER ACT-CAPTAINS (the script hard-preconditions on captain_assignment_enabled=true).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_DECKS3]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-decks3.sql"
CONFIRM_TOKEN="ACTIVATE_DECKS3"
MARKERS="ACTIVATE_DECKS3_PASS_PRECONDITIONS ACTIVATE_DECKS3_PASS_STAGE1 ACTIVATE_DECKS3_PASS_SMOKE"
PASS_LINE="DECKS-3 ACTIVATION PASS"

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
  printf '%s' "$CLEAN" | grep -q "20260618000196" || fail "operation must precondition on the 0196 (DECKS-3) migration head"

  # ██ the HARD captains gate ██ — asserted raw AND through cfg_bool.
  printf '%s' "$CLEAN" | grep -qF "key = 'captain_assignment_enabled'" || fail "operation must assert the raw captain_assignment_enabled value (the hard gate)"
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('captain_assignment_enabled')" || fail "operation must assert captain_assignment_enabled through cfg_bool (the hard gate)"

  # deployed-body prosrc pins.
  printf '%s' "$CLEAN" | grep -qF "cfg_num('station_affinity_bonus')" || fail "operation must prosrc-pin the once-at-entry knob read (0196)"
  printf '%s' "$CLEAN" | grep -qF "left join ship_stations st on st.station_id = a.station" || fail "operation must prosrc-pin the LEFT station join (0196)"
  printf '%s' "$CLEAN" | grep -qF "v_aff_mult := case when c.affinity_specialization = c.specialization then 1 + v_aff_bonus else 1 end" || fail "operation must prosrc-pin the affinity-match multiplier CASE (0196)"
  printf '%s' "$CLEAN" | grep -qF "from public.ship_stations" || fail "operation must assert the 6-station catalog"

  # the FIRST-FLIP knob-dark precondition.
  printf '%s' "$CLEAN" | grep -qF "is not the dark seed" || fail "operation must precondition the knob at the dark seed '0' (first-flip guard)"

  # writes: exactly ONE set_game_config on the approved key; NEVER a flag/other-window key, table, DDL.
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('station_affinity_bonus', '0.15'::jsonb)" || fail "missing station_affinity_bonus -> 0.15 (the only knob write)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(ship_traits_enabled|salvage_market_enabled|shipyard_enabled|blueprint_fragment_drop_rate|shield_regen_combat_pct|shield_regen_idle_pct|captain_assignment_enabled|captain_progression_enabled|mining_enabled|trade_market_enabled)'" \
    && fail "operation writes another window's config key (out of the decks-3 window's scope)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL" || fail "missing final PASS line"
  grep -q "THE HARD CAPTAINS GATE" "$OP_SQL" || fail "operation must document the hard captains gate + flip order"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL" || fail "operation must document the FIRST-FLIP re-run semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL" || fail "missing the marked manual ROLLBACK section"

  echo "DECKS-3 ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 1 approved knob -> 0.15; single timed UTC BEGIN..COMMIT gated on 0196 recorded + the HARD captains gate + the adapter affinity prosrc pins + the 6-station catalog + the knob dark seed; no meta-commands; no flag/other-window/table/DDL writes; rollback commented; captains-first + first-flip documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "DECKS-3 ACTIVATION: OVERALL_PASS — station-affinity bonus live (0.15 [D]; a matched captain scales by 1.15). Requires captains lit. Manual smoke: station a matching captain and watch the preview rise."
