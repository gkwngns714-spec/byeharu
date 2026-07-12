#!/usr/bin/env bash
# MINING ACTIVATION runner — wraps the ONE Phase-12 flip operation scripts/activate-mining.sql
# (the full-capacity plan's second activity window; the exploration §7 posture applied to mining).
# ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build time; each `run` is the human's
# recorded go decision.
#
# The activate-team-command.sh / activate-captains.sh pattern, mining domain. Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly ONE approved key (mining_enabled -> true),
#              never the exploration/team/captain keys and never the radius/cooldown knobs
#              (assert-only); is one timed BEGIN..COMMIT gated on the 0172 writer reconcile (the H2
#              fix: the deployed writer must carry BOTH the 0143 advisory lock AND the 0137
#              worldstate_deplete_field depletion hook — prosrc-bound) + the 0103 seed; contains
#              NO psql meta-command (management-API compatible); keeps its
#              ROLLBACK section commented out; documents the NO-client-PR fact (MiningPanel is
#              server-lit and already mounted — no osnReleaseGates constant exists for mining) and
#              the post-flip pending-yield watch (secured_at NULL = pending, secures on the next
#              safe settle — documented, deliberately not asserted).
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and
#              assert every stage marker. Requires the typed confirm token as the 2nd arg.
#              No local psql on this machine? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead — it is self-contained, self-asserting,
#              and meta-command-free.
#
#   bash scripts/activate-mining.sh selftest
#   bash scripts/activate-mining.sh run ACTIVATE_MINING                # DB_URL required
#
# RUN ORDER (the full-capacity plan): exploration flips FIRST (scripts/activate-exploration.sh,
# packet §7); mining follows a FEW DAYS LATER once exploration looks healthy. Independent scripts.
#
# AFTER a green run (NO client PR — the panel mounts off the server envelope):
#   1. node scripts/verify-mining.mjs (service-role env) — the behavior proof.
#   2. Manual smoke: undock → settle within 750 of a field → MiningPanel appears → extract →
#      pending yield → immediate re-extract rejects cooldown (retry_after_seconds) → settle safe →
#      the securing cron deposits the items within a minute.
#   3. POST-FLIP WATCH: mining_extractions rows with secured_at NULL are pending yields (secure on
#      the ship's next safe settle, 0105) — watch the count trend, only a growing floor of OLD
#      pending rows is a signal.
# Rollback: the commented section at the bottom of the .sql (the one reverse config write only;
# extractions persist harmlessly, pending ones still secure — the processor ignores the flag).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_MINING]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-mining.sql"
CONFIRM_TOKEN="ACTIVATE_MINING"
MARKERS="ACTIVATE_MINING_PASS_PRECONDITIONS ACTIVATE_MINING_PASS_STAGE1 ACTIVATE_MINING_PASS_SMOKE"
PASS_LINE="MINING ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere (nothing for a runner to strip).
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT; gated on the double-extract guard + the seeded content.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -q "20260618000172" || fail "operation must precondition on the 0172 writer reconcile (the H2 depletion fix)"
  for field in "Sparse Ore Belt" "Ferrous Drift Field" "Crystalline Shelf" "Deep Vein Cluster" "Singularity Scar"; do
    printf '%s' "$CLEAN" | grep -qF "$field" || fail "operation must precondition on the seeded field: $field"
  done
  printf '%s' "$CLEAN" | grep -qF "'pg_advisory_xact_lock' in v_src" || fail "operation must assert the 0143 advisory lock in the deployed writer body"
  printf '%s' "$CLEAN" | grep -qF "'worldstate_deplete_field' in v_src" || fail "operation must assert the 0172-restored depletion hook in the deployed writer body (the H2 binding)"
  printf '%s' "$CLEAN" | grep -qF "mining_extractions_cooldown_idx" || fail "operation must assert the 0103 cooldown index by name"
  printf '%s' "$CLEAN" | grep -qF "item_types" || fail "operation must assert the bundle catalog closure"

  # writes: ONLY the owned set_game_config writer, exactly ONE approved key, exact value;
  # NEVER the exploration/team/captain keys, NEVER the knobs, NEVER another table, NEVER DDL.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('mining_enabled', 'true'::jsonb)" || fail "missing mining_enabled -> true"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(mining_extract_radius|mining_extract_cooldown_seconds)'" && fail "operation rewrites a mining knob (assert-only; retunes are a separate deliberate write)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(exploration_enabled|exploration_scan_radius)'" && fail "operation writes an EXPLORATION key (that is scripts/activate-exploration.sql's window)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(team_command_enabled|mainship_additional_commission_enabled|module_crafting_enabled|module_fitting_enabled|main_ship_price|max_active_fleets|captain_assignment_enabled|captain_progression_enabled|captain_shard_drop_rate)'" \
    && fail "operation rewrites a team/captain-window key (out of this window's scope)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # smoke + follow-ups are documented/asserted: markers, the function-existence smoke over the
  # whole mining surface, the securing-cron pin, the NO-client-PR note, and the pending-yield watch.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                                    || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence smoke"
  for fn in "public.command_mining_extract(uuid, uuid)" "public.get_my_mining_extractions()" \
            "public.mining_extract(uuid, uuid, uuid)" "public.process_mining_securing()" \
            "public.osn_distance(double precision, double precision, double precision, double precision)" \
            "public.reward_grant(text, uuid, uuid, uuid, jsonb)" \
            "public.worldstate_field_remaining(uuid)" "public.worldstate_deplete_field(uuid)"; do
    printf '%s' "$CLEAN" | grep -qF "$fn" || fail "smoke does not cover $fn"
  done
  printf '%s' "$CLEAN" | grep -qF "process-mining-securing" || fail "missing the securing-cron smoke assert"
  grep -q "NO CLIENT PR IS NEEDED" "$OP_SQL"                        || fail "operation must document the no-client-PR verification (server-lit panel)"
  grep -q "RUN ORDER" "$OP_SQL"                                     || fail "operation must document the run-order recommendation (exploration first, mining later)"
  grep -q "POST-FLIP WATCH" "$OP_SQL"                               || fail "operation must document the pending-yield (secured_at NULL) post-flip watch"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                             || fail "missing the marked manual ROLLBACK section"

  echo "MINING ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 1 approved key; 0172-reconcile-gated single timed BEGIN..COMMIT with the H2 worldstate_deplete_field prosrc binding; no meta-commands; no exploration/team/captain-key or knob rewrites; rollback commented; no-client-PR + run-order + pending-yield watch documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "MINING ACTIVATION: OVERALL_PASS — mining live (no client PR needed; the panel mounts off the server envelope). Next: node scripts/verify-mining.mjs + manual smoke; watch pending (secured_at NULL) extraction rows secure on safe settles."
