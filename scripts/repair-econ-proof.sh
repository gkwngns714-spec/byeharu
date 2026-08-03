#!/usr/bin/env bash
# ONE WAY TO REPAIR — disposable proof orchestrator for the unified repair verb (migration 0335:
# public.repair_ship_hull, replacing 0201's repair_ship_hull_at_port and 0297's repair_main_ship),
# the repair_economy_enabled gate, the repair_credits_per_hp knob and the repair_receipts ledger.
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends
#              in ROLLBACK), OWNS every flag and knob value it asserts (it sets them in-txn and never
#              trusts a seed), provisions via the REAL RPCs (commission_first_main_ship; damage via a
#              fixture hp write, never a direct receipt insert), and exercises the whole reject
#              vocabulary, the exact-cost economics, the wreck policy, the zero-is-free correction,
#              the knob-still-governs pin, the one-authority pin and the position unification.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / flags-inside-txn / out-of-scope / local psql+markers)
# live in scripts/lib/trade-proof-lib.sh (repair is a docked-port economy in the trade family); only this
# proof's specifics live here. Standalone (NOT team-command-proof: a parallel MOD2-2 slice owns that block).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/repair-econ-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="REPAIR_PASS_DARK_GATE REPAIR_PASS_SEED REPAIR_PASS_HAPPY REPAIR_PASS_PARTIAL REPAIR_PASS_IDEMPOTENT REPAIR_PASS_GUARDS REPAIR_PASS_WRECK REPAIR_PASS_ZERO_IS_FREE REPAIR_PASS_MISCONFIG REPAIR_PASS_KNOB_GOVERNS REPAIR_PASS_ONE_AUTHORITY REPAIR_PASS_ONE_POSITION"
PASS_LINE="ONE-WAY-TO-REPAIR PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── the ONE gate flag is enabled ONLY strictly inside the begin;..rollback; scope. ────────────────
  tp_assert_flags_inside_txn "$SQL" repair_economy_enabled

  # ── THE HARNESS OWNS ITS PRECONDITIONS. A proof that asserts an ambient default is asserting a
  #    WORLD, not a property, and goes red the day the owner legitimately retunes it — which is
  #    exactly how three sibling proofs sat silently wrong for weeks after 0300. So: the dark phase
  #    must SET the flag false itself (never inherit the seed), and every price asserted must be one
  #    this file set. These two greps are the static gate that makes that unskippable. ──────────────
  grep -qF "update public.game_config set value='false'::jsonb where key='repair_economy_enabled';" "$SQL" \
    || fail "harness does not SET repair_economy_enabled false itself — the dark phase would be asserting the chain seed"
  grep -q "pg_temp.set_rate(" "$SQL" \
    || fail "harness does not own the price it asserts (no pg_temp.set_rate) — a knob value it did not set is an ambient default"
  grep -qF "no ambient default is asserted anywhere in this file" "$SQL" \
    || fail "harness lost the owned-precondition statement in its seed phase"

  # ── all three starter-port identities (fixed 0066 UUIDs) are referenced (Haven repair site + move target). ──
  for pid in b1a00001-0066-4a00-8a00-000000000001 \
             b1a00002-0066-4a00-8a00-000000000002 \
             b1a00003-0066-4a00-8a00-000000000003; do
    grep -q "$pid" "$SQL" || fail "harness does not reference port $pid"
  done

  # ── the ONE verb, and ONLY the one verb. A proof that still calls a dropped predecessor is a proof
  #    that would wedge the whole chain the moment 0335 applies. ─────────────────────────────────────
  grep -q "public.repair_ship_hull(" "$SQL" || fail "harness does not exercise the unified repair verb"
  # a CALL, not a mention: P10 names both dropped functions inside to_regprocedure() on purpose (to
  # prove they are absent), so the ban is on invoking them — which in this harness only ever happens
  # through pg_temp.call_as or a bare `:= public.<fn>(`.
  grep -nE 'public\.repair_main_ship\(|public\.repair_ship_hull_at_port\(' "$SQL" \
    | grep -v 'to_regprocedure' \
    && fail "harness still calls a repair function 0335 DROPPED — repoint it onto repair_ship_hull" || true

  # ── every reject envelope of the unified vocabulary is exercised. ─────────────────────────────────
  for tok in repair_economy_disabled invalid_request invalid_amount ship_not_found not_at_port \
             nothing_to_repair repair_misconfigured insufficient_credits idempotent_replay; do
    grep -q "'$tok'" "$SQL" || fail "harness does not exercise reject/replay envelope '$tok'"
  done
  # the two reasons 0335 RETIRED must not come back: a wreck is no longer refused, and position has
  # exactly one name.
  grep -q "'ship_destroyed'" "$SQL" && fail "harness asserts ship_destroyed — 0335 recovers a wreck instead of refusing it" || true
  grep -q "'not_docked'" "$SQL"     && fail "harness asserts not_docked — 0335 has ONE position reason, not_at_port" || true

  # ── the exact-delta economics are pinned: 120hp→60cr full mend, 40hp→20cr partial, no double-charge. ──
  grep -q "want exactly -60" "$SQL"      || fail "harness does not pin the exact -60 full-mend wallet delta"
  grep -q "restore 40, debit 20" "$SQL"  || fail "harness does not pin the exact partial-mend economics"
  grep -q "hp_restored=120" "$SQL"       || fail "harness does not pin the clamped 120-hp restore + receipt fields"

  # ── ██ THE WRECK POLICY ██ — the one essential difference between the two deleted functions, now
  #    eight lines of policy: a DESTROYED ship recovers whole and FREE, at a NON-ZERO knob, for a
  #    player with an EMPTY wallet, and is never gated by the economy flag. ─────────────────────────
  grep -q "public.dev_set_main_ship_destroyed" "$SQL" || fail "harness does not wreck a ship via the real primitive"
  grep -q "the economy flag gated a WRECK recovery" "$SQL" \
    || fail "harness does not prove recovery survives a DARK economy flag (a gated recovery is a permanently lost ship)"
  grep -q "recovery was PRICED" "$SQL" \
    || fail "harness does not prove wreck recovery is free AT A NON-ZERO KNOB (free-because-the-knob-is-0 proves nothing)"
  grep -q "recovery was partial" "$SQL" \
    || fail "harness does not pin that a wreck restores the WHOLE hull"

  # ── ██ ZERO IS FREE ██ — RED BY CONSTRUCTION against 0201, whose `v_per_hp <= 0` reject turned the
  #    owner's deliberate free-repair setting into a game-wide outage. Must be proven at knob 0 AND
  #    the knob must still be proven to GOVERN at a non-zero value, or "free" is indistinguishable
  #    from "hardcoded". ──────────────────────────────────────────────────────────────────────────
  grep -q "pg_temp.set_rate(0)" "$SQL" || fail "harness never sets the price to 0 — the owner's live production value is untested"
  grep -q "setting repairs free must make them FREE, not unavailable" "$SQL" \
    || fail "harness does not assert that a 0 price REPAIRS rather than rejecting"
  grep -q "pg_temp.set_rate(3)" "$SQL" || fail "harness never sets a NON-ZERO price — restoring the price later is untested"
  grep -q "the knob did not govern the charge" "$SQL" \
    || fail "harness does not prove the knob still governs the charge at a non-zero price"
  grep -q "pg_temp.set_rate(-1)" "$SQL" || fail "harness does not prove a NEGATIVE price still fails closed"

  # ── ██ ONE AUTHORITY ██ — the whole point of the slice. Both predecessors gone, exactly one
  #    client-executable repair verb, and a ledger the client cannot forge. ─────────────────────────
  grep -q "client-executable repair\* functions" "$SQL" \
    || fail "harness does not COUNT the client-executable repair verbs (a third one must be caught, not just the two known names)"
  grep -q "repair_receipts','insert'" "$SQL" \
    || fail "harness does not assert the receipt ledger is client-unwritable"

  # ── ██ THE POSITION UNIFICATION ██ — a berthed, fleet-less ship mends where it is, and the harness
  #    PROVES the old resolver disagreed rather than asserting the fix in a vacuum. ────────────────
  grep -q "public.mainship_port_of_ship(" "$SQL" \
    || fail "harness does not read the ONE position authority"
  grep -q "public.mainship_resolve_docked_location(" "$SQL" \
    || fail "harness does not show the OLD dock resolver disagreeing — without that, the position unification proves nothing"
  grep -q "the divergence this phase exists to close is not present" "$SQL" \
    || fail "harness does not fail loudly when its own divergence premise stops holding"

  # ── provisioning is via the REAL RPC, never a direct repair_receipts insert (the RPC is the sole writer). ──
  grep -q "public.commission_first_main_ship()" "$SQL" || fail "harness does not commission ships via the real RPC"
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.repair_receipts' "$SQL" \
    && fail "harness inserts repair_receipts directly (must be minted by repair_ship_hull only)" || true

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "ONE-WAY-TO-REPAIR SELFTEST: ALL PASSED (self-rolling-back; owns every flag/knob value it asserts; real-RPC provisioning; exact-cost economics; full reject vocabulary with the two retired reasons banned; wreck-is-free-at-a-nonzero-knob; zero-is-free + knob-still-governs + negative-fails-closed; one-authority count + ledger lockdown; position unification proven against the old resolver)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "ONE-WAY-TO-REPAIR" "$SQL" "$PASS_LINE" "$MARKERS"
echo "ONE-WAY-TO-REPAIR LOCAL PROOF: OVERALL_PASS"
