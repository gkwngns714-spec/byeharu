#!/usr/bin/env bash
# CAPTAINS ACTIVATION runner — wraps the ONE captains fast-follow flip operation
# scripts/activate-captains.sql (docs/TEAM_ACTIVATION_PACKET.md §3, approved 2026-07-12;
# docs/TEAM_COMMAND.md → ACTIVATION CHECKLIST item 2/④). ██ HUMAN TOOL ██ — never wired into CI;
# nothing flips at build time; each `run` is the human's recorded go decision.
#
# The activate-team-command.sh pattern, captains domain. Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly the three approved keys (shard-rate knob +
#              assignment/progression flags), never a team/module/commission flag and never a
#              slot column; is one timed BEGIN..COMMIT gated on the 0171 bump preconditions;
#              contains NO psql meta-command (management-API compatible); keeps its ROLLBACK
#              section commented out; and documents the NO-client-PR fact (all captain surfaces
#              are server-lit — no osnReleaseGates constant exists for captains).
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and
#              assert every stage marker. Requires the typed confirm token as the 2nd arg.
#              No local psql on this machine? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead — it is self-contained, self-asserting,
#              and meta-command-free.
#
#   bash scripts/activate-captains.sh selftest
#   bash scripts/activate-captains.sh run ACTIVATE_CAPTAINS          # DB_URL required
#
# AFTER a green run (NO client PR — the surfaces mount off the server envelope):
#   1. bash scripts/team-command-proof.sh (against a disposable FRESH-migration chain — dark seeds; the proof lights flags in-txn and hard-fails on lit config by design) — the CAPTAINS +
#      SHARDDROP blocks are the behavior proof.
#   2. Manual smoke: hunt past wave 2 → shard drops → recruit a captain → assign to a team
#      member → C0 preview / D0 totals move by the captain's stats; "Captain seats" shows n/6.
# Rollback: the commented section at the bottom of the .sql (reverse config writes only; NEVER
# lower slot counts once captains occupy slots 3-6).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_CAPTAINS]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-captains.sql"
CONFIRM_TOKEN="ACTIVATE_CAPTAINS"
MARKERS="ACTIVATE_CAPTAINS_PASS_PRECONDITIONS ACTIVATE_CAPTAINS_PASS_STAGE1 ACTIVATE_CAPTAINS_PASS_STAGE2 ACTIVATE_CAPTAINS_PASS_SMOKE"
PASS_LINE="CAPTAINS ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere (nothing for a runner to strip).
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT; gated on the 0171 prep migration + both bump halves.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -q "20260618000171" || fail "operation must precondition on the 0171 captains-launch prep migration"
  printf '%s' "$CLEAN" | grep -qF "base_captain_slots is distinct from 8" || fail "operation must precondition on the hull bump (every hull at 8 seats — the ROOMS-8 0203 raise)"
  printf '%s' "$CLEAN" | grep -qF "i.captain_slots < h.base_captain_slots" || fail "operation must precondition on the instance backfill"

  # writes: ONLY the owned set_game_config writer, exactly the three approved keys, exact values;
  # NEVER a team/module/commission flag, NEVER a slot column, NEVER another table, NEVER DDL.
  # 2 call sites = the stage-1 knob write + the ONE stage-2 loop write over the 2-flag array.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "2" ] || fail "operation must have exactly 2 set_game_config call sites (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('captain_shard_drop_rate', '0.15'::jsonb)" || fail "missing captain_shard_drop_rate -> 0.15"
  for k in captain_assignment_enabled captain_progression_enabled; do
    printf '%s' "$CLEAN" | grep -qF "'$k'" || fail "missing flag $k"
  done
  printf '%s' "$CLEAN" | grep -qF "set_game_config(k, 'true'::jsonb)"                  || fail "stage-2 flags must be set to true via set_game_config"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(team_command_enabled|mainship_additional_commission_enabled|module_crafting_enabled|module_fitting_enabled|main_ship_price|max_active_fleets)'" \
    && fail "operation rewrites a team-launch key (already live — out of this window's scope)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+public\.|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE 'set[[:space:]]+(base_)?captain_slots' && fail "operation writes a slot column (the bump is migration 0171, never a script write)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # smoke + follow-ups are documented/asserted: markers, function-existence + catalog smoke, the
  # F5 economy-closure assert, and the NO-client-PR note (the captains window's key difference).
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                                    || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence smoke"
  for fn in recruit_captain assign_captain_to_ship unassign_captain_from_ship get_my_captain_instances get_my_ship_captains pirate_loot_for_wave; do
    printf '%s' "$CLEAN" | grep -qF "public.$fn(" || fail "smoke does not cover $fn"
  done
  printf '%s' "$CLEAN" | grep -qF "captain type(s) without a recruit recipe" || fail "missing the every-type-recruitable smoke assert"
  printf '%s' "$CLEAN" | grep -qF "no recipe consumes captain_memory_shard" || fail "missing the shard economy-closure smoke assert"
  grep -q "NO CLIENT PR IS NEEDED" "$OP_SQL"                        || fail "operation must document the no-client-PR verification (server-lit surfaces)"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                             || fail "missing the marked manual ROLLBACK section"
  grep -qi "NEVER lower base_captain_slots" "$OP_SQL"               || fail "missing the never-lower-slots irreversibility warning"

  echo "CAPTAINS ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 3 approved keys; 0171-bump-gated single timed BEGIN..COMMIT; no meta-commands; no team-key rewrites; no slot writes; rollback commented; no-client-PR documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "CAPTAINS ACTIVATION: OVERALL_PASS — captains live (no client PR needed; surfaces mount off the server envelope). Next: scripts/team-command-proof.sh + manual smoke."
