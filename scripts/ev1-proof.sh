#!/usr/bin/env bash
# EV-1 WORLD-EVENTS — disposable proof orchestrator for the 0182 worldstate threshold-event producer
# (worldstate_tick publishes STATE-detected pressure / depletion / drift-extreme events through the
# EXISTING sole writer world_events_publish, dedup-keyed per UTC day).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), enables BOTH dark gates (world_balance_enabled + phase20_polish_enabled) ONLY
#              inside the txn, keeps EVERY game_config write inside the txn, drives depletion ONLY via
#              the real sole writer worldstate_deplete_field, NEVER inserts world_events directly
#              (publish-only law), and exercises every property (dark, state-detected high/eased with
#              the never-high suppression, dedup, depletion, drift, publish-failure injection PLUS the
#              genuine state-retry, the uncastable/NaN knob guard, narrate-never-mutate).
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / flags-inside-txn / out-of-scope / local
# psql+markers) live in scripts/lib/trade-proof-lib.sh — the lib is feature-agnostic orchestrator
# plumbing (the salvage/haul precedent); EV-1 is worldstate-family but rides the same harness idiom.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/ev1-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="EV1_PASS_DARK EV1_PASS_PRESSURE_HIGH EV1_PASS_PRESSURE_EASED EV1_PASS_DEDUP EV1_PASS_DEPLETION EV1_PASS_DRIFT EV1_PASS_PUBLISH_FAILSAFE EV1_PASS_RETRY EV1_PASS_KNOB_GUARD EV1_PASS_NARRATE_ONLY"
PASS_LINE="EV-1 WORLD-EVENTS PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── BOTH dark gates are enabled ONLY strictly inside the begin;..rollback; scope. ─────────────────
  tp_assert_flags_inside_txn "$SQL" world_balance_enabled phase20_polish_enabled

  # ── EVERY game_config write (flags AND the transient baseline/decay tunings) is inside the txn. ───
  begin_ln="$(grep -niE '^[[:space:]]*begin;' "$SQL" | head -1 | cut -d: -f1)"
  rollback_ln="$(grep -niE '^[[:space:]]*rollback;' "$SQL" | tail -1 | cut -d: -f1)"
  while IFS= read -r cfg_ln; do
    { [ "$begin_ln" -lt "$cfg_ln" ] && [ "$cfg_ln" -lt "$rollback_ln" ]; } \
      || fail "a game_config write is not strictly inside begin;..rollback;"
  done < <(grep -niE 'update public\.game_config' "$SQL" | cut -d: -f1)

  # ── every dedup-key family the 0182 producer emits is asserted by exact key. ──────────────────────
  for k in pressure_high pressure_eased price_surge price_crash field_depleting; do
    grep -q "'$k:%s:%s'" "$SQL" || fail "harness does not assert the '$k' dedup-key family"
  done

  # ── the three severities and both scopes of the charter are pinned. ───────────────────────────────
  for tok in "severity='warning'" "severity='critical'" "severity='info'" "scope='location'" "scope='global'"; do
    grep -q "$tok" "$SQL" || fail "harness does not pin $tok"
  done

  # ── PUBLISH-ONLY LAW: the harness NEVER inserts world_events directly — depletion state is driven
  #    ONLY via the real sole writer; the failure injection + narrate-only probes are present. ───────
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?world_events' "$SQL" \
    && fail "harness inserts world_events directly (must go through the tick / world_events_publish)" || true
  grep -q "public.worldstate_deplete_field(" "$SQL" || fail "harness does not deplete via the real sole writer"
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?mining_field_state' "$SQL" \
    && fail "harness writes mining_field_state directly (World State's own writer must drive it)" || true
  grep -q "ev1_proof_publish_fail" "$SQL" || fail "harness lacks the publish-failure injection (D2 law)"
  grep -q "narrate-only probe" "$SQL"     || fail "harness lacks the narrate-never-mutate probe"

  # ── the hostile-review properties are exercised: the never-high eased suppression, the genuine
  #    state-retry after an injected failure, and BOTH knob-guard arms (uncastable + NaN). ───────────
  grep -q "suppression broken" "$SQL" || fail "harness lacks the never-high eased-suppression assert"
  grep -q "EV1_PASS_RETRY" "$SQL"     || fail "harness lacks the genuine-retry assert (state-detection payoff)"
  grep -q '"not-a-number"' "$SQL"     || fail "harness lacks the uncastable knob-guard arm"
  grep -q '"NaN"' "$SQL"              || fail "harness lacks the NaN knob-guard arm"

  # ── the lazy-row fixture ensure is present: location_state rows are LAZY on the real chain (0031
  #    seeded only the then-existing five; later locations get rows only on first presence) — without
  #    the 0031-shape ensure the 7-fixture pick underflows on a fresh chain (the CI failure). ────────
  grep -q "insert into public.location_state (location_id)" "$SQL" \
    || fail "harness lacks the location_state fixture ensure (lazy rows: a fresh chain has only 5)"
  grep -q "on conflict (location_id) do nothing" "$SQL" \
    || fail "harness location_state ensure is not the idempotent 0031 seed shape"

  # ── the tick is exercised repeatedly and no cron is touched. ──────────────────────────────────────
  grep -q "public.worldstate_tick()" "$SQL" || fail "harness never runs the real tick"
  grep -qi 'cron\.' "$SQL" && fail "harness touches cron (EV-1 adds NO cron)" || true

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "EV1 SELFTEST: ALL PASSED (self-rolling-back; both gates + every config write inside txn only; publish-only law; real-writer depletion; all 5 dedup families + severities/scopes; failure-injection + state-retry + eased-suppression + knob-guard + narrate-only probes present)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "EV1-WORLD-EVENTS" "$SQL" "$PASS_LINE" "$MARKERS"
echo "EV1 LOCAL PROOF: OVERALL_PASS"
