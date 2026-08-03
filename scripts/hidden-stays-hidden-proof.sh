#!/usr/bin/env bash
# HIDDEN-STAYS-HIDDEN — disposable proof orchestrator for migration 0318 (an unreleased row of the
# static world is invisible to an ANONYMOUS caller, while the player map, a logged-in player and the
# owner's World Editor all keep exactly the reach they had). Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back, actually LEAVES
#              the superuser seat (a proof of an RLS property that never switches role proves
#              nothing, because postgres carries BYPASSRLS), owns every row it later reads, and pins
#              each property in assert-form rather than printing a notice.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL.
# The shared blocks live in scripts/lib/trade-proof-lib.sh — sourced, not re-copied (house
# convention). Standalone pair: NOT appended to any contended proof suite.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/hidden-stays-hidden-proof.sql"
MIG="$REPO_ROOT/supabase/migrations/20260618000318_hidden_stays_hidden.sql"

MARKERS="HSH_PASS_ANON_BLIND HSH_PASS_AUTH_BLIND HSH_PASS_ANON_MAP_INTACT HSH_PASS_SERVER_VIEW_UNCHANGED HSH_PASS_OWNER_SEES_UNRELEASED HSH_PASS_ONE_AUTHORITY HSH_PASS_GRANT_END_STATE HSH_PASS_REVOKE_EFFECTIVE"
PASS_LINE="HIDDEN-STAYS-HIDDEN PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"
  [ -f "$MIG" ] || fail "migration 0318 not found — this proof exists to gate it"

  tp_assert_self_rolling_back "$SQL"

  # ── THE LOAD-BEARING ONE: the proof must leave the superuser seat. ──────────────────────────────
  # postgres carries BYPASSRLS, so every assertion made from the default seat is blind to policies by
  # construction — a "security proof" that never SET ROLEs is the vacuous-self-assert failure mode
  # wearing a different hat. Both client roles must be entered, and both must be left again (a
  # dangling role would make every later section run as anon and fail for the wrong reason).
  grep -qE '^set local role anon;' "$SQL"          || fail "harness never enters the anon seat — it cannot observe an RLS policy at all (postgres has BYPASSRLS)"
  grep -qE '^set local role authenticated;' "$SQL" || fail "harness never enters the authenticated seat — a logged-in player is untested"
  n_set="$(grep -cE '^set local role ' "$SQL" || true)"
  n_reset="$(grep -cE '^reset role;' "$SQL" || true)"
  [ "$n_set" = "$n_reset" ] || fail "unbalanced role switches: $n_set 'set local role', $n_reset 'reset role' (a dangling seat makes later sections fail for the wrong reason)"

  # ── the proof OWNS its preconditions (never asserts an ambient seed). ───────────────────────────
  grep -q "insert into public.sectors"   "$SQL" || fail "harness does not seed its own sector fixtures"
  grep -q "insert into public.zones"     "$SQL" || fail "harness does not seed its own zone fixtures"
  grep -q "insert into public.locations" "$SQL" || fail "harness does not seed its own location fixtures"
  grep -q "insert into public.space_anchors" "$SQL" \
    || fail "harness does not anchor its location fixtures — get_world_map INNER-JOINs the active anchor since 0264, so the map assertions would pass vacuously"

  # every status a row can be unreleased with, plus both nesting cases — a policy that is too loose
  # OR too tight has to be caught, and dropping any one of these silently narrows the proof.
  for fx in HSH-Loc-Active HSH-Loc-Hidden HSH-Loc-Locked HSH-Loc-UnderHiddenZone HSH-Loc-UnderHiddenSector \
            HSH-Zone-Active HSH-Zone-Hidden HSH-Zone-UnderHiddenSector HSH-Sector-Active HSH-Sector-Hidden; do
    grep -q "$fx" "$SQL" || fail "harness lost the $fx fixture"
  done

  # the hidden fixture must carry is_public=true, or the proof cannot show that is_public is NOT the
  # gate (all three real hidden Ember rows carry is_public=true).
  grep -q "9001, 9001, true, 'hidden'" "$SQL" \
    || fail "the hidden location fixture is no longer is_public=true — the proof would stop showing that a policy keyed on is_public leaks"

  # ── every property is asserted, not merely printed. ────────────────────────────────────────────
  grep -q "an ANONYMOUS caller can read unreleased location" "$SQL" || fail "harness lacks the anon hidden-location assert (the leak itself)"
  grep -q "an ANONYMOUS caller can read unreleased zone"     "$SQL" || fail "harness lacks the anon hidden-zone assert"
  grep -q "an ANONYMOUS caller can read the unreleased sector" "$SQL" || fail "harness lacks the anon hidden-sector assert"
  grep -q "the policy is too tight and the map would go blank" "$SQL" || fail "harness lacks the too-tight assert (a deny-all policy would pass a leak-only proof)"
  grep -q "an AUTHENTICATED player can read unreleased location" "$SQL" || fail "harness lacks the authenticated hidden-location assert"
  grep -q "the repoint changed the server-side view"        "$SQL" || fail "harness lacks the get_world_map unchanged-output assert"
  grep -q "not a data change"                               "$SQL" || fail "harness lacks the rows-still-exist assert (hiding must not be deleting)"
  grep -q "tightening RLS blinded the owner tool"           "$SQL" || fail "harness lacks the owner-still-sees-inactive assert — that is the most likely way this fix breaks the game"
  grep -q "two authorities that must agree is the defect"   "$SQL" || fail "harness lacks the one-authority assert"
  grep -q "client write privilege survives on"              "$SQL" || fail "harness lacks the grant end-state assert"
  grep -q "SELECT was revoked along with the writes"        "$SQL" || fail "harness lacks the SELECT-survives assert"
  grep -q "did not remove the drift"                        "$SQL" || fail "harness lacks the revoke-efficacy assert"

  # the owner path must be exercised by CALLING the owner-only reader, not by reading its catalog row.
  grep -q "public.world_editor_entity_catalog(" "$SQL" || fail "harness does not call the owner catalog RPC"
  grep -q "insert into public.app_owners"       "$SQL" || fail "harness does not seed a real owner (is_owner() would reject)"

  # section H must ESTABLISH the drift before revoking it, or it is vacuous on a disposable chain
  # (Supabase's project-level default grants are not reproduced by `supabase start`).
  grep -q "grant insert, update, delete on table public.zones to anon, authenticated;" "$SQL" \
    || fail "section H does not establish the drift precondition — the revoke check would be vacuous"
  grep -q "could not establish the drift precondition" "$SQL" \
    || fail "section H does not verify that the drift it created is real"

  # has_table_privilege, with `public` among the grantees — the 0309 lesson: a privilege held via the
  # PUBLIC pseudo-role is invisible to information_schema and to a naive relacl read.
  grep -q "has_table_privilege" "$SQL" || fail "harness does not use has_table_privilege for the grant end state"
  grep -q "'anon', 'authenticated', 'public'" "$SQL" \
    || fail "harness does not check the PUBLIC pseudo-role — a privilege held through PUBLIC would pass unnoticed"

  # determinism (0041): no random() anywhere. gen_random_uuid( has "_uuid" between "random" and "(".
  grep -qE 'random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  # ── the MIGRATION itself must establish, never merely assert (the 0254 / 0309 lesson). ─────────
  grep -q "revoke insert, update, delete on table public.zones   from public, anon, authenticated;" "$MIG" \
    || fail "0318 does not REVOKE the drifted write grant on zones from public, anon, authenticated"
  grep -q "revoke insert, update, delete on table public.sectors from public, anon, authenticated;" "$MIG" \
    || fail "0318 does not REVOKE the drifted write grant on sectors from public, anon, authenticated"
  grep -q "revoke insert, update, delete on table public.bases   from public, anon, authenticated;" "$MIG" \
    || fail "0318 does not REVOKE the drifted write grant on bases from public, anon, authenticated"
  grep -q 'drop policy if exists "locations_public_read" on public.locations;' "$MIG" \
    || fail "0318 does not DROP the permissive locations policy — two SELECT policies OR together, so the new one would be decoration"
  grep -q 'drop policy if exists "zones_public_read"     on public.zones;' "$MIG" \
    || fail "0318 does not DROP the permissive zones policy"
  grep -q 'drop policy if exists "sectors_public_read"   on public.sectors;' "$MIG" \
    || fail "0318 does not DROP the permissive sectors policy"
  grep -q "6c2f30dad96990a5a4839f29329df7c8" "$MIG" \
    || fail "0318 lost its get_world_map full-body md5 pin — a re-created live function with no parity pin can silently revert a later edit"
  grep -q "reverse-derived md5" "$MIG" \
    || fail "0318 lost the reverse-derivation parity assert (byte parity outside the three hunks)"
  grep -qE '^begin;$' "$MIG" || fail "0318 does not open a transaction"
  grep -q "set local lock_timeout = '5s';"      "$MIG" || fail "0318 lost the house lock_timeout guard"
  grep -q "set local statement_timeout = '120s';" "$MIG" || fail "0318 lost the house statement_timeout guard"
  grep -q "set local time zone 'UTC';"          "$MIG" || fail "0318 lost the house time zone guard"

  echo "HIDDEN-STAYS-HIDDEN SELFTEST: ALL PASSED (self-rolling-back; the proof LEAVES the superuser seat for both anon and authenticated with balanced resets — without which an RLS assertion is vacuous under BYPASSRLS; it seeds all ten of its own fixtures incl. both nesting cases and an is_public=true hidden row; every property — anon blind to hidden/locked/under-hidden-zone/under-hidden-sector rows and to hidden zones+sectors, anon still reads the released row and still gets a populated get_world_map, authenticated identical, server-side view unchanged, rows still present, the OWNER catalog still returns the unreleased rows, one composed authority with no status literal left in get_world_map, grant end state via has_table_privilege incl. the PUBLIC pseudo-role, SELECT survives, and the revoke proven effective against a drift the proof establishes itself — is asserted in assert-form; no random(); and migration 0318 REVOKEs rather than asserts, drops all three permissive policies, and pins get_world_map by full-body md5 with a reverse-derivation parity assert)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "HIDDEN-STAYS-HIDDEN" "$SQL" "$PASS_LINE" "$MARKERS"
echo "HIDDEN-STAYS-HIDDEN LOCAL PROOF: OVERALL_PASS"
