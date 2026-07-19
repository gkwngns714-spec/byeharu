#!/usr/bin/env bash
# DANGER-ZONE COMBAT — disposable proof orchestrator for the owner's #1 chain: "send a fleet into a
# danger zone → you visibly get jumped by pirates." Drives the REAL entry path end to end:
#   command_ship_group_go (leg crosses a drawn danger_zone) → pirate_intercept_evaluate_leg (risk 1.0 →
#   certain HIT) → manifest freeze + presence_create + activity_start → combat_create_encounter (group
#   branch) → combat_create_group_encounter (SPATIAL positions) → process_combat_ticks (synthetic pirate
#   spawn + fire). Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back, toggles every dark
#              flag ONLY inside the txn, provisions ONLY via the real RPCs (group_sortie_members and
#              combat_units are NEVER hand-written), and asserts every property in assert-form.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL: send-through-zone → assert
#              intercept + spatial encounter → one tick → assert a spawned + firing pirate.
# The shared blocks live in scripts/lib/trade-proof-lib.sh (the house convention; sourced, not re-copied).
#
# HOST NOTE: a NEW, standalone proof pair + workflow (the combat-spatial-proof.sh / decks-proof.sh
# precedent) — NOT a block appended to any contended proof file. Flips NO committed flag.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/danger-combat-proof.sql"

MARKERS="DZCOMBAT_PASS_INTERCEPT DZCOMBAT_PASS_SPATIAL DZCOMBAT_PASS_PIRATEFIRE"
PASS_LINE="DANGER-ZONE COMBAT PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # every dark capability flag this scenario needs is enabled ONLY strictly inside the txn.
  tp_assert_flags_inside_txn "$SQL" team_command_enabled mainship_additional_commission_enabled \
    module_crafting_enabled module_fitting_enabled spatial_combat_enabled pirate_intercept_enabled \
    fleet_movement_unified_enabled

  # the commission precondition: a fresh disposable chain seeds the starter ports INACTIVE.
  grep -q "public.reveal_starter_ports()" "$SQL" || fail "harness does not reveal the starter ports (commission would fail closed)"

  # combat_telegraph stays DARK so the ambush opens combat synchronously inside the go call.
  grep -q "set value='false'::jsonb where key='combat_telegraph_enabled'" "$SQL" \
    || fail "harness does not keep combat_telegraph_enabled dark (the encounter must open synchronously)"

  # the DETERMINISTIC-AMBUSH knobs: risk = 1.0 for any crossing (so the hit needs no harness random()).
  grep -q "set_game_config('pirate_intercept_base_risk',      '1.0'" "$SQL"      || fail "harness lost the base_risk=1.0 determinism knob"
  grep -q "set_game_config('pirate_intercept_min_risk',       '1.0'" "$SQL"      || fail "harness lost the min_risk=1.0 determinism knob"
  grep -q "set_game_config('pirate_intercept_max_risk',       '1.0'" "$SQL"      || fail "harness lost the max_risk=1.0 determinism knob"
  grep -q "set_game_config('pirate_intercept_exposure_floor', '1.0'" "$SQL"      || fail "harness lost the exposure_floor=1.0 determinism knob"

  # SOLE-WRITER LAW: group_sortie_members and combat_units are NEVER hand-written.
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?group_sortie_members' "$SQL" \
    && fail "harness inserts group_sortie_members directly (the intercept is its sole writer here)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?combat_units' "$SQL" \
    && fail "harness inserts combat_units directly (the engine functions are its sole writers)" || true
  grep -qiE 'update[[:space:]]+(public\.)?combat_units' "$SQL" \
    && fail "harness UPDATEs combat_units directly (only the engine functions may write it)" || true

  # provisioning + the entry path are 100% real-RPC.
  grep -q "public.commission_first_main_ship(" "$SQL" || fail "harness does not commission via the real RPC"
  grep -q "public.craft_module("               "$SQL" || fail "harness does not craft the weapon via the real RPC"
  grep -q "public.fit_module_to_ship("         "$SQL" || fail "harness does not fit the weapon via the real RPC"
  grep -q "public.upsert_ship_group("          "$SQL" || fail "harness does not form the team via the real RPC"
  grep -q "public.assign_ship_to_group("       "$SQL" || fail "harness does not assign the ship via the real RPC"
  grep -q "public.set_fleet_command_ship("     "$SQL" || fail "harness does not designate the command ship via the real RPC"
  grep -q "public.pirate_zone_create("         "$SQL" || fail "harness does not draw the danger zone via the real RPC"
  grep -q "public.command_ship_group_go("      "$SQL" || fail "harness does not send the fleet via the real unified mover (the path under test)"
  grep -q "public.reward_grant("               "$SQL" || fail "harness does not fund crafting materials via the real Reward writer"

  # exactly ONE process_combat_ticks() invocation (the first wave spawn + fire pass).
  n="$(grep -c 'perform public\.process_combat_ticks();' "$SQL" || true)"
  [ "$n" = "1" ] || fail "expected exactly 1 process_combat_ticks() call, found $n"

  # every property is asserted in assert-form (gutting any block fails here).
  grep -q "was NOT intercepted"                                   "$SQL" || fail "harness lacks the intercept-hit assert"
  grep -q "pirate_intercepts hit rows for this fleet"             "$SQL" || fail "harness lacks the pirate_intercepts hit-log assert"
  grep -q "intercepted movement was not cancelled"               "$SQL" || fail "harness lacks the leg-cancelled assert"
  grep -q "the encounter is NOT spatial"                          "$SQL" || fail "harness lacks the positioned-units (spatial) assert"
  grep -q "command ship weapons_json did not carry the fitted range" "$SQL" || fail "harness lacks the weapons_json range assert"
  grep -q "no positioned synthetic pirate spawned"               "$SQL" || fail "harness lacks the synthetic-pirate-spawn assert"
  grep -q "no pirate-sourced spatial missile_salvo"              "$SQL" || fail "harness lacks the pirate-fire assert"
  grep -q "no damage exchanged"                                   "$SQL" || fail "harness lacks the damage-dealt assert"

  # determinism: no session random() (0041 law). gen_random_uuid() is fixture identity only.
  grep -qE 'random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  echo "DANGER-ZONE COMBAT SELFTEST: ALL PASSED (self-rolling-back; every dark flag — team_command/additional_commission/module_crafting/module_fitting/spatial_combat/pirate_intercept/fleet_movement_unified — enabled only inside the txn; combat_telegraph kept dark for synchronous combat; risk knobs = 1.0 for a certain hit; sole-writer law for group_sortie_members + combat_units; provisioning + entry 100% real-RPC incl. pirate_zone_create + command_ship_group_go; exactly 1 tick; every property — intercept hit + leg cancelled, spatial positioned units, spawned + firing pirate + damage — asserted in assert-form; no random())"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "DANGER-ZONE COMBAT" "$SQL" "$PASS_LINE" "$MARKERS"
echo "DANGER-ZONE COMBAT LOCAL PROOF: OVERALL_PASS"
