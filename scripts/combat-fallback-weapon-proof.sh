#!/usr/bin/env bash
# COMBAT-FALLBACK — disposable proof orchestrator for the player-fallback-weapon slice (migration 0262:
# a spatial-combat player ship with NO fitted weapon module but a positive attack_snapshot fires a
# SYNTHESIZED basic weapon instead of dealing zero damage). Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), toggles every dark capability flag ONLY inside the txn, provisions ONLY via the
#              real RPCs/writers (commission/mint-captain/assign/craft/fit/group/send —
#              group_sortie_members and combat_units are NEVER hand-written), and pins every property in
#              assert-form.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the live-DB scenario:
#              commission → captain → send → settle → creator synthesizes the fallback weapon → tick →
#              the pirate takes real damage from the synthesized weapon alone).
# The shared blocks live in scripts/lib/trade-proof-lib.sh — sourced, not re-copied (the house
# convention). Standalone pair (the decks/combat-spatial precedent): NOT appended to any contended proof.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/combat-fallback-weapon-proof.sql"

MARKERS="CFALLBACK_PASS_PREFIX_EMPTY CFALLBACK_PASS_SYNTH CFALLBACK_PASS_ARMED CFALLBACK_PASS_DAMAGE"
PASS_LINE="COMBAT-FALLBACK PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # every dark capability flag this scenario needs is enabled ONLY strictly inside the txn.
  tp_assert_flags_inside_txn "$SQL" team_command_enabled mainship_additional_commission_enabled \
    module_crafting_enabled module_fitting_enabled captain_assignment_enabled spatial_combat_enabled

  # the readiness precondition: the commission 'present' fleet is retired (else send rejects member_not_ready).
  grep -q "status = 'destroyed', location_mode = 'destroyed'" "$SQL" || fail "harness does not retire the commission 'present' fleet"
  grep -q "and status = 'present';" "$SQL" || fail "harness's fleet-retirement UPDATE is missing its status='present' scope"
  grep -q "public.reveal_starter_ports()" "$SQL" || fail "harness does not reveal the starter ports (commission would fail closed on a fresh chain)"

  # SOLE-WRITER LAW: group_sortie_members and combat_units are NEVER hand-written.
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?group_sortie_members' "$SQL" \
    && fail "harness inserts group_sortie_members directly (send_ship_group_hunt is its sole writer)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?combat_units' "$SQL" \
    && fail "harness inserts combat_units directly (combat_create_group_encounter/the tick are the sole writers)" || true
  grep -qiE 'update[[:space:]]+(public\.)?combat_units' "$SQL" \
    && fail "harness UPDATEs combat_units directly (only the engine functions may write it)" || true

  # provisioning is 100% real-RPC/real-writer.
  grep -q "public.commission_first_main_ship(" "$SQL"      || fail "harness does not commission via the real RPC"
  grep -q "public.commission_additional_main_ship(" "$SQL" || fail "harness does not commission additional ships via the real RPC"
  grep -q "public.captains_mint_instance(" "$SQL"          || fail "harness does not mint the captain via the real writer (the fallback ship's attack source)"
  grep -q "public.assign_captain_to_ship(" "$SQL"          || fail "harness does not assign the captain via the real RPC"
  grep -q "public.reward_grant(" "$SQL"                    || fail "harness does not fund crafting materials via the real Reward writer"
  grep -q "public.craft_module(" "$SQL"                    || fail "harness does not craft the armed-witness weapon via the real RPC"
  grep -q "public.fit_module_to_ship(" "$SQL"              || fail "harness does not fit the armed-witness weapon via the real RPC"
  grep -q "public.upsert_ship_group(" "$SQL"               || fail "harness does not form the team via the real RPC"
  grep -q "public.assign_ship_to_group(" "$SQL"            || fail "harness does not assign ships via the real RPC"
  grep -q "public.set_fleet_command_ship(" "$SQL"          || fail "harness does not designate the command ship via the real RPC"
  grep -q "public.send_ship_group_hunt(" "$SQL"            || fail "harness does not send the hunt via the real RPC"
  grep -q "public.movement_settle_arrival(" "$SQL"         || fail "harness does not settle arrival via the real leaf"

  # exactly ONE process_combat_ticks() invocation (tick 1: spawn + first fire pass).
  n="$(grep -c 'perform public\.process_combat_ticks();' "$SQL" || true)"
  [ "$n" = "1" ] || fail "expected exactly 1 process_combat_ticks() call, found $n"

  # the fallback ship's ATTACK source is a captain, and it fits NO weapon (an empty fitted-weapon join).
  grep -q "'gunnery_veteran'" "$SQL" || fail "harness does not give the fallback ship a captain for attack"

  # the engineered geometry: the escort is out of its own range (ring 500), the pirate can't reach it
  # (range 10), variance zeroed — gutting any one silently degrades the attribution.
  grep -q "spatial_formation_ring_radius', '500'" "$SQL" || fail "harness lost the escort-out-of-range ring radius (damage attribution depends on it)"
  grep -q "enemy_synthetic_range_base', '10'" "$SQL"     || fail "harness lost the tuned-low pirate range (the pirate must not fire tick 1)"
  grep -q "combat_damage_variance_pct', '0'" "$SQL"      || fail "harness lost the determinism knob (0 variance)"
  grep -q "'autocannon_battery'" "$SQL"                  || fail "harness does not use the real S0 weapon catalog entry for the armed witness"

  # every property is asserted in assert-form (gutting any one block fails here).
  grep -q "PREFIX_EMPTY FAIL" "$SQL" || fail "harness lacks the pre-fix empty-fitted-weapon assert"
  grep -q "SYNTH FAIL: fallback power" "$SQL" || fail "harness lacks the power = attack_snapshot assert"
  grep -q "SYNTH FAIL: fallback module_type_id" "$SQL" || fail "harness lacks the basic_player_weapon label assert"
  grep -q "ARMED FAIL: s_arm weapon is" "$SQL" || fail "harness lacks the armed-ship-unchanged assert"
  grep -q "DAMAGE FAIL: pirate hp_current" "$SQL" || fail "harness lacks the pirate-hp-fell (nonzero damage) assert"
  grep -q "DAMAGE FAIL attribution" "$SQL" || fail "harness lacks the damage-attribution asserts"

  # determinism (0041): no random() anywhere. gen_random_uuid( has "_uuid" between "random" and "(".
  grep -qE 'random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  echo "COMBAT-FALLBACK SELFTEST: ALL PASSED (self-rolling-back; every dark flag — team_command/additional_commission/module_crafting/module_fitting/captain_assignment/spatial_combat — enabled only inside the txn; sole-writer law for group_sortie_members + combat_units; provisioning 100% real-RPC incl. mint/assign captain + craft/fit; exactly 1 tick invocation; engineered geometry (ring 500 / pirate range 10 / variance 0) present; every property — pre-fix empty fitted join, synthesized power=attack_snapshot @ basic_player_weapon 150/300/2, armed ship unchanged, pirate hp fell with clean attribution — asserted in assert-form; no random())"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "COMBAT-FALLBACK" "$SQL" "$PASS_LINE" "$MARKERS"
echo "COMBAT-FALLBACK LOCAL PROOF: OVERALL_PASS"
