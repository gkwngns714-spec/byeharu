#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# ENCOUNTER CANARY — disposable exact-chain proof runner (§3.4).
#
# ██ THROWAWAY DATABASES ONLY — NEVER point this at production. ██
# Drives scripts/encounter-canary-proof.sql against a disposable DB_URL and asserts every PASS marker.
# The SQL is self-rolling-back (begin;…rollback;): it flips gate flags ONLY inside the transaction,
# authors the canary chain, proves twelve behaviours, and leaves ZERO persisted state.
#
# After the rollback this runner re-connects and proves — from OUTSIDE the transaction — that nothing
# survived: no canary content, no active binding beyond the pre-existing seed posture, an empty runtime
# ledger, and encounter_resolver_enabled still false. That check emits ECP_PASS_ROLLBACK_CLEAN.
#
# Local:
#   DB_URL="$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2-)" ./scripts/encounter-canary-proof.sh
# ════════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$SCRIPT_DIR/encounter-canary-proof.sql"
[ -f "$SQL" ] || { echo "proof sql not found: $SQL"; exit 1; }
: "${DB_URL:?DB_URL (disposable stack) required}"

# NO-LEAK BASELINE (the proofs-never-assert-ambient-defaults rule, fix shape 3): capture the
# COMMITTED resolver flag BEFORE the run and demand it UNCHANGED after — never a hard-coded value.
# The old check pinned `false`, the pre-0300 seed; 0300 lights the flag IN THE CHAIN, so the pin
# failed on every post-0300 chain while proving nothing about leakage in either world.
flag_before="$(psql "$DB_URL" -X -t -A -c "select public.cfg_bool('encounter_resolver_enabled')")"

# capture without aborting so the psql output (incl. any RAISE) is always printed for diagnosis; the
# marker loop below is the pass/fail gate.
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)" || true
echo "$out"

  # 0344: six markers are GONE and deliberately not replaced by weaker forms —
  # ACTIVATED_SPAWN, ONE_RUNTIME_ROW, COOLDOWN_BLOCKS, FLEET_COMPOSITION,
  # REWARD_MATCHES and NON_ELITE each asserted that the tick INSTANTIATES an
  # authored plan, and 0344 deletes the only branch that ever did. Pinning them
  # would DEMAND the deleted wave sizer. ECP_PASS_CANARY_INERT replaces all six.
for marker in \
  ECP_PASS_INACTIVE_BINDING_NO_SPAWN \
  ECP_PASS_RESOLVER_OFF_NO_SPAWN \
  ECP_PASS_BINDING_ONLY_NO_SPAWN \
  ECP_PASS_CANARY_INERT \
  ECP_PASS_BINDING_DISABLED_STOPS \
  ECP_PASS_RESOLVER_DISABLED_STOPS \
  ECP_PASS_NO_NEW_ACTIVE_CONTENT \
  'ENCOUNTER-CANARY PROOF PASSED'; do
  echo "$out" | grep -q "$marker" || { echo "MISSING PASS MARKER: $marker"; exit 1; }
done

# ── POST-ROLLBACK: the transaction is gone; prove nothing it authored survived. ─────────────────────
post="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -t -A -c "
do \$\$
declare n integer;
begin
  select count(*) into n from public.reward_profiles      where key = 'canary_reward';
  if n <> 0 then raise exception 'ECP ROLLBACK FAIL: % canary_reward reward profile(s) survived', n; end if;
  select count(*) into n from public.enemy_archetypes     where key = 'canary_pirate';
  if n <> 0 then raise exception 'ECP ROLLBACK FAIL: % canary_pirate archetype(s) survived', n; end if;
  select count(*) into n from public.enemy_fleet_templates where key = 'canary_fleet';
  if n <> 0 then raise exception 'ECP ROLLBACK FAIL: % canary_fleet template(s) survived', n; end if;
  select count(*) into n from public.encounter_profiles   where key = 'canary_encounter';
  if n <> 0 then raise exception 'ECP ROLLBACK FAIL: % canary_encounter profile(s) survived', n; end if;
  select count(*) into n from public.encounter_runtime_state;
  if n <> 0 then raise exception 'ECP ROLLBACK FAIL: % encounter_runtime_state row(s) survived', n; end if;
  -- (the resolver flag's no-leak check moved OUT of this block: the runner compares the COMMITTED
  --  value before vs after the run — derived, never a hard-coded seed.)
  select count(*) into n from public.world_editor_audit where request_id like 'ecp-%';
  if n <> 0 then raise exception 'ECP ROLLBACK FAIL: % owner-RPC audit row(s) survived', n; end if;
  raise notice 'ECP_PASS_ROLLBACK_CLEAN';
end \$\$;" 2>&1)" || true
echo "$post"
echo "$post" | grep -q 'ECP_PASS_ROLLBACK_CLEAN' || { echo "MISSING PASS MARKER: ECP_PASS_ROLLBACK_CLEAN"; exit 1; }

flag_after="$(psql "$DB_URL" -X -t -A -c "select public.cfg_bool('encounter_resolver_enabled')")"
[ "$flag_after" = "$flag_before" ] \
  || { echo "ECP ROLLBACK FAIL: encounter_resolver_enabled leaked across the rollback ($flag_before -> $flag_after)"; exit 1; }

echo 'ALL ENCOUNTER-CANARY PASS MARKERS PRESENT'
