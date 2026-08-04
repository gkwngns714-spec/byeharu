#!/usr/bin/env bash
# STAT FOUNDATION (0340) proof orchestrator.
#
#   selftest — DB-free. Proves the harness is well-formed BEFORE anyone trusts a green run:
#              self-rolling-back, builds its own fixtures, guards every loop with a cardinality
#              check, and carries every PASS marker. A proof script that silently does nothing is
#              the failure mode this job exists to catch.
#   local    — runs the harness against $DB_URL (a disposable local Supabase) and requires EVERY
#              marker to appear. `supabase start` has already applied the whole migration chain by
#              then, so migration 0340's own self-asserts have run against real Postgres and real
#              CHECK constraints — that apply is itself the load-bearing proof.
set -euo pipefail

MODE="${1:-selftest}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$HERE/stat-foundation-proof.sql"
MIG="$HERE/../supabase/migrations/20260618000340_stats_have_one_authority.sql"

MARKERS=(
  SF_PASS_SHIP_PARITY
  SF_PASS_CARGO_QUARANTINE
  SF_PASS_FLEET_LIVE_SHAPES_UNCHANGED
  SF_PASS_INTENDED_DIFFERENCES
  SF_PASS_NO_UNDECLARED_DIFFERENCE
  SF_PASS_ROUTINE_CARRIES_NO_DORMANT
  SF_PASS_EMPTY_FLEET_EXPLICIT
  SF_PASS_SINGLE_SHIP_FLEET
  SF_PASS_BREAKDOWN_RECONCILES
  SF_PASS_DETERMINISM_ON_REAL_ROWS
  SF_PASS_MALFORMED_REFUSED
  SF_PASS_INSPECTION_SURFACE
  SF_PASS_ENGINE_STILL_INERT
)

fail() { echo "STAT-FOUNDATION PROOF SELFTEST FAIL: $*" >&2; exit 1; }

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "missing $SQL"
  [ -f "$MIG" ] || fail "missing migration $MIG"

  # (1) self-rolling-back — it must never leave a row behind
  grep -q '^begin;' "$SQL"    || fail "harness does not open a transaction"
  grep -q '^rollback;' "$SQL" || fail "harness does not ROLLBACK — it could mutate a real database"
  if grep -qE '^[[:space:]]*commit;' "$SQL"; then fail "harness contains a COMMIT"; fi

  # (2) it builds its OWN fixtures and depends on no production content
  grep -q 'insert into auth.users'                  "$SQL" || fail "harness does not create its own user"
  grep -q 'insert into public.main_ship_hull_types' "$SQL" || fail "harness does not create its own hulls"
  grep -q 'insert into public.main_ship_instances'  "$SQL" || fail "harness does not create its own ships"
  grep -q 'insert into public.module_types'         "$SQL" || fail "harness does not create its own module types"
  grep -q 'insert into public.ship_groups'          "$SQL" || fail "harness does not create its own group"

  # (3) every marker is actually emitted by the script
  for m in "${MARKERS[@]}"; do
    grep -q "$m" "$SQL" || fail "marker $m is never raised by the harness"
  done

  # (4) the harness compares against the DEPLOYED authorities, or it proves nothing
  grep -q 'calculate_expedition_stats'       "$SQL" || fail "harness never calls the deployed ship fold"
  grep -q 'calculate_group_expedition_stats' "$SQL" || fail "harness never calls the deployed fleet authority"
  grep -q 'resolve_effective_stats'          "$SQL" || fail "harness never calls the canonical resolver"

  # (5) NO FLAG. The owner's ruling: this slice introduces no dark gate, and the migration asserts
  #     its absence. If a flag ever creeps back in, this fails here first.
  if grep -q "stat_resolver_enabled', '" "$MIG"; then
    fail "migration 0340 seeds a feature flag — this slice must introduce none"
  fi
  grep -q 'get_my_effective_stats' "$MIG" || fail "migration 0340 has no inspection RPC — the owner cannot check it"
  grep -q 'get_stat_definitions'   "$MIG" || fail "migration 0340 has no registry read RPC"
  grep -q 'auth.uid()'             "$MIG" || fail "the inspection RPC is not ownership-scoped"

  # (6) the migration's own asserts must be NON-VACUOUS: exact cardinalities, not existence-only
  grep -q '<> 10 then' "$MIG" || fail "migration 0340 has no exact-cardinality guard on the seed"
  grep -q 'stat_combine(' "$MIG" || fail "migration 0340 never EXECUTES the pure fold in its self-assert"

  # (6b) THE LIFECYCLE RULING, and the two things about it that must never become prose:
  #      · the lifecycle vocabulary fails closed (the migration attempts an illegal value), and
  #      · a dormant stat is proven ABSENT from the routine snapshot, not merely filtered late.
  grep -q "lifecycle in ('active','dormant','deprecated')" "$MIG" \
    || fail "migration 0340 has no closed lifecycle vocabulary"
  grep -q 'the lifecycle vocabulary does not fail closed' "$MIG" \
    || fail "migration 0340 never PROBES the lifecycle CHECK — a CHECK nobody exercised is a CHECK nobody confirmed"
  grep -q 'a DORMANT stat is present in the ROUTINE registry snapshot' "$MIG" \
    || fail "migration 0340 does not prove dormant stats are absent from the routine path"
  grep -q 'a contribution to a DORMANT stat was accepted on the routine path' "$MIG" \
    || fail "migration 0340 does not prove a dormant contribution is REJECTED, not silently ignored"

  # (6c) THREE-WAY PROVENANCE: the partition law exists, and it is EXECUTED, not described.
  grep -q 'stat_assert_provenance_partition' "$MIG" \
    || fail "migration 0340 has no provenance partition law"
  grep -q 'appears in more than one provenance map' "$MIG" \
    || fail "the provenance law does not forbid a stat sitting in two maps"
  grep -q "'is_real_zero'" "$MIG" \
    || fail "a real zero is not distinguished from an unresolved or a not-applicable"

  # (6d) THE AMBUSH IMPOSSIBILITY PIN, and the proof the live consumer was NOT repaired.
  grep -q 'refusing to produce a number from a failed stat resolution' "$MIG" \
    || fail "migration 0340 does not prove a stat-resolution failure can never become a number"
  grep -q 'this is exactly the 0301:545-547 fail-open defect' "$MIG" \
    || fail "the ambush impossibility pin is missing"
  grep -q 'repairing the live ambush consumer is OUT OF SCOPE' "$MIG" \
    || fail "migration 0340 does not pin pirate_intercept_plan_leg as UNCHANGED"

  # (6e) THE CARGO RE-RULING: the conversion is structurally inert, not inert by convention.
  grep -q 'stat_definitions_undefined_conversion_accepts_nothing' "$MIG" \
    || fail "the cargo conversion guard is not a constraint"
  grep -q 'the unit conversion is NOT activated in this slice' "$SQL" \
    || fail "the harness does not prove on real rows that no source reaches cargo_volume_m3"
  grep -q 'this slice changed a live hold size' "$SQL" \
    || fail "the harness does not prove live hold sizes are unchanged"

  # (7) every loop in the harness is preceded by a cardinality guard (a loop is never the assertion)
  grep -q 'would be vacuous' "$SQL" || fail "harness has no explicit vacuity guard"

  echo "STAT-FOUNDATION proof selftest ok: harness is self-rolling-back, builds its own fixtures,"
  echo "  compares canonical vs deployed on both scopes, carries ${#MARKERS[@]} markers, guards its loops,"
  echo "  and the migration introduces NO feature flag while exposing an ownership-scoped inspection RPC."
  exit 0
fi

if [ "$MODE" = "local" ]; then
  : "${DB_URL:?DB_URL must be set (supabase status -o env)}"
  OUT="$(mktemp)"
  echo "── running the STAT FOUNDATION parity/difference harness on the disposable chain ──"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$SQL" 2>&1 | tee "$OUT"

  missing=0
  for m in "${MARKERS[@]}"; do
    if ! grep -q "$m" "$OUT"; then echo "MISSING MARKER: $m" >&2; missing=1; fi
  done
  [ "$missing" -eq 0 ] || { echo "STAT-FOUNDATION PROOF FAIL: a marker did not appear" >&2; exit 1; }

  echo "STAT-FOUNDATION proof ok: all ${#MARKERS[@]} markers present on a real disposable chain."
  exit 0
fi

echo "usage: $0 [selftest|local]" >&2
exit 2
