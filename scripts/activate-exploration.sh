#!/usr/bin/env bash
# EXPLORATION ACTIVATION runner — wraps the ONE Phase-11 flip operation
# scripts/activate-exploration.sql (docs/TEAM_ACTIVATION_PACKET.md §7 "the exploration flip (can
# go first)", ✅ GO 2026-07-12). ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build
# time; each `run` is the human's recorded go decision.
#
# The activate-team-command.sh / activate-captains.sh pattern, exploration domain. Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly ONE approved key (exploration_enabled -> true),
#              never the mining/team/captain keys and never the scan-radius knob (assert-only);
#              is one timed BEGIN..COMMIT gated on the 0172 writer reconcile (the H1 securing fix:
#              the deployed writer must record main_ship_id on discoveries — prosrc-bound) + the
#              0146 dup-guard handler + the 0098 seed; contains
#              NO psql meta-command (management-API compatible); keeps its ROLLBACK section
#              commented out; and documents the NO-client-PR fact (ExplorationPanel is server-lit
#              and already mounted — no osnReleaseGates constant exists for exploration).
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and
#              assert every stage marker. Requires the typed confirm token as the 2nd arg.
#              No local psql on this machine? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead — it is self-contained, self-asserting,
#              and meta-command-free.
#
#   bash scripts/activate-exploration.sh selftest
#   bash scripts/activate-exploration.sh run ACTIVATE_EXPLORATION      # DB_URL required
#
# RUN ORDER (the full-capacity plan): exploration flips FIRST (packet §7 — low-risk, independent);
# mining follows a few days later via scripts/activate-mining.sh. The scripts are independent.
#
# AFTER a green run (NO client PR — the panel mounts off the server envelope):
#   1. node scripts/verify-exploration.mjs (service-role env) — the behavior proof (packet §7.1).
#   2. Manual smoke (packet §7.3): undock → settle within 750 of a site → ExplorationPanel appears
#      → scan → discovery + pending bundle → re-scan rejects already_discovered (0146) → settle
#      safe → the securing cron deposits the bundle within a minute.
# Rollback: the commented section at the bottom of the .sql (the one reverse config write only;
# discoveries persist harmlessly, pending ones still secure — the processor ignores the flag).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_EXPLORATION]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-exploration.sql"
CONFIRM_TOKEN="ACTIVATE_EXPLORATION"
MARKERS="ACTIVATE_EXPLORATION_PASS_PRECONDITIONS ACTIVATE_EXPLORATION_PASS_STAGE1 ACTIVATE_EXPLORATION_PASS_SMOKE"
PASS_LINE="EXPLORATION ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere (nothing for a runner to strip).
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT; gated on the dup-guard migration + the seeded content.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -q "20260618000172" || fail "operation must precondition on the 0172 writer reconcile (the H1 securing fix)"
  for site in "Derelict Listening Post" "Shattered Survey Buoy" "Anomalous Debris Field" "Silent Foundry Wreck" "Precursor Vault Signal"; do
    printf '%s' "$CLEAN" | grep -qF "$site" || fail "operation must precondition on the seeded site: $site"
  done
  printf '%s' "$CLEAN" | grep -qF "exploration_discoveries_player_id_site_id_key" || fail "operation must assert the 0098 unique pair constraint by name"
  printf '%s' "$CLEAN" | grep -qF "'unique_violation' in v_src" || fail "operation must assert the 0146 unique_violation handler in the deployed writer body"
  printf '%s' "$CLEAN" | grep -qF "'pending_bundle_json, main_ship_id' in v_src" || fail "operation must assert the 0172-restored main_ship_id insert in the deployed writer body (the H1 binding)"
  printf '%s' "$CLEAN" | grep -qF "item_types" || fail "operation must assert the bundle catalog closure"

  # writes: ONLY the owned set_game_config writer, exactly ONE approved key, exact value;
  # NEVER the mining/team/captain keys, NEVER the radius knob, NEVER another table, NEVER DDL.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('exploration_enabled', 'true'::jsonb)" || fail "missing exploration_enabled -> true"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('exploration_scan_radius'" && fail "operation rewrites the scan-radius knob (assert-only; retunes are a separate deliberate write)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(mining_enabled|mining_extract_radius|mining_extract_cooldown_seconds)'" && fail "operation writes a MINING key (that is scripts/activate-mining.sql's window)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(team_command_enabled|mainship_additional_commission_enabled|module_crafting_enabled|module_fitting_enabled|main_ship_price|max_active_fleets|captain_assignment_enabled|captain_progression_enabled|captain_shard_drop_rate)'" \
    && fail "operation rewrites a team/captain-window key (out of this window's scope)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # smoke + follow-ups are documented/asserted: markers, the function-existence smoke over the
  # whole exploration surface, the securing-cron pin, and the NO-client-PR note.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                                    || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence smoke"
  for fn in "public.command_exploration_scan(uuid, uuid)" "public.get_my_exploration_discoveries()" \
            "public.exploration_scan(uuid, uuid, uuid)" "public.process_exploration_securing()" \
            "public.osn_distance(double precision, double precision, double precision, double precision)" \
            "public.reward_grant(text, uuid, uuid, uuid, jsonb)"; do
    printf '%s' "$CLEAN" | grep -qF "$fn" || fail "smoke does not cover $fn"
  done
  printf '%s' "$CLEAN" | grep -qF "process-exploration-securing" || fail "missing the securing-cron smoke assert"
  grep -q "NO CLIENT PR IS NEEDED" "$OP_SQL"                        || fail "operation must document the no-client-PR verification (server-lit panel)"
  grep -q "RUN ORDER" "$OP_SQL"                                     || fail "operation must document the run-order recommendation (exploration first)"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                             || fail "missing the marked manual ROLLBACK section"

  echo "EXPLORATION ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 1 approved key; 0172-reconcile-gated single timed BEGIN..COMMIT with the H1 main_ship_id prosrc binding; no meta-commands; no mining/team/captain-key or knob rewrites; rollback commented; no-client-PR + run-order documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "EXPLORATION ACTIVATION: OVERALL_PASS — exploration live (no client PR needed; the panel mounts off the server envelope). Next: node scripts/verify-exploration.mjs + the packet §7 manual smoke. Mining follows in a few days via scripts/activate-mining.sh."
