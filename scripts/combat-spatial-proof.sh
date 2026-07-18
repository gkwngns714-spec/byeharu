#!/usr/bin/env bash
# COMBAT-SPATIAL — disposable proof orchestrator for the S3 spatial-combat slice (migration 0234:
# per-ship positions, the CLOSE-vs-KITE movement/targeting AI, synthetic pirate spawn at the location
# center, per-weapon fire events, and damage). Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends
#              in ROLLBACK), toggles every dark capability flag ONLY inside the txn, provisions ONLY
#              via the real RPCs (commission/craft/fit/group/send — group_sortie_members and
#              combat_units are NEVER hand-written), and exercises every property this slice's own
#              migration self-assert could not (no live fixture exists inside a migration).
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual live-DB
#              scenario proof: spawn → tick → verify positions/kite/close/fire/damage/screening).
# The shared blocks (arg scaffold / self-rolling-back / flags-inside-txn / out-of-scope / local
# psql+markers) live in scripts/lib/trade-proof-lib.sh — sourced, not re-copied (the house convention;
# this lib is feature-agnostic orchestrator plumbing, not owned by any one proof family).
#
# HOST NOTE: this is a NEW, standalone proof pair + (future) workflow — NOT a block appended to
# fleetgo-proof.{sql,sh} or team-command-proof.{sql,sh}. Both of those pairs are being concurrently
# repointed by other in-flight slices; this script never reads or writes either of them (the
# decks-proof.sh precedent: "so DECKS ships as its own family-pure standalone pair ... instead of a
# new block there").
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/combat-spatial-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="COMBATSPATIAL_PASS_SPAWN COMBATSPATIAL_PASS_ENEMY COMBATSPATIAL_PASS_HOLD COMBATSPATIAL_PASS_KITE COMBATSPATIAL_PASS_CLOSE COMBATSPATIAL_PASS_FIRE COMBATSPATIAL_PASS_DAMAGE COMBATSPATIAL_PASS_SCREEN"
PASS_LINE="COMBAT-SPATIAL PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── every dark capability flag this scenario needs is enabled ONLY strictly inside the txn. ────────
  tp_assert_flags_inside_txn "$SQL" team_command_enabled mainship_additional_commission_enabled \
    module_crafting_enabled module_fitting_enabled spatial_combat_enabled

  # ── the readiness precondition: every freshly commissioned ship carries a real 'present' commission
  #    fleet + active presence at Haven (the "corpse dock"), which send_ship_group_hunt's dark-path
  #    readiness gate deliberately treats as NOT ready (member_not_ready) — without retiring it, every
  #    send would reject. The team-command-proof.sql PROVISION-block precedent, lifted verbatim. ──────
  grep -q "status = 'destroyed', location_mode = 'destroyed'" "$SQL" || fail "harness does not retire the commission 'present' fleet (send_ship_group_hunt would reject member_not_ready)"
  grep -q "and status = 'present';" "$SQL" || fail "harness's fleet-retirement UPDATE is missing its status='present' scope"

  # ── the commission precondition: a fresh disposable chain seeds the starter ports INACTIVE, and
  #    port_entry_commission_build hard-requires Haven to be dockable — without this call every
  #    commission fails closed (commission_unavailable). The team-command-proof.sql precedent's own
  #    first setup step, mirrored. ─────────────────────────────────────────────────────────────────────
  grep -q "public.reveal_starter_ports()" "$SQL" || fail "harness does not reveal the starter ports (commission would fail closed on a fresh chain)"

  # ── SOLE-WRITER LAW: group_sortie_members and combat_units are NEVER hand-written — provisioning
  #    and the encounter/tick both go through the real writers only. ──────────────────────────────────
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?group_sortie_members' "$SQL" \
    && fail "harness inserts group_sortie_members directly (send_ship_group_hunt is its sole writer)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?combat_units' "$SQL" \
    && fail "harness inserts combat_units directly (combat_create_group_encounter/the tick are the sole writers)" || true
  grep -qiE 'update[[:space:]]+(public\.)?combat_units' "$SQL" \
    && fail "harness UPDATEs combat_units directly (only the engine functions may write it)" || true
  grep -q "public.commission_first_main_ship(" "$SQL"      || fail "harness does not commission via the real RPC"
  grep -q "public.commission_additional_main_ship(" "$SQL" || fail "harness does not commission additional ships via the real RPC"
  grep -q "public.craft_module(" "$SQL"                    || fail "harness does not craft weapons via the real RPC"
  grep -q "public.fit_module_to_ship(" "$SQL"               || fail "harness does not fit weapons via the real RPC"
  grep -q "public.upsert_ship_group(" "$SQL"                || fail "harness does not form the team via the real RPC"
  grep -q "public.assign_ship_to_group(" "$SQL"             || fail "harness does not assign ships via the real RPC"
  grep -q "public.set_fleet_command_ship(" "$SQL"           || fail "harness does not designate the command ship via the real RPC"
  grep -q "public.send_ship_group_hunt(" "$SQL"              || fail "harness does not send the hunt via the real RPC"
  grep -q "public.movement_settle_arrival(" "$SQL"           || fail "harness does not settle arrival via the real leaf (the cron's own per-movement settle)"
  grep -q "public.reward_grant(" "$SQL"                      || fail "harness does not fund crafting materials via the real Reward writer"
  # exactly TWO process_combat_ticks() invocations (tick 1 spawn+first pass, tick 2 the retaliation) —
  # a third or a zeroth would silently change what property is actually being proven.
  n="$(grep -c 'perform public\.process_combat_ticks();' "$SQL" || true)"
  [ "$n" = "2" ] || fail "expected exactly 2 process_combat_ticks() calls (tick 1 + tick 2), found $n"

  # ── the engineered geometry itself: the tuning knobs that make CLOSE/KITE/HOLD all reachable in
  #    ONE deterministic pass are present (gutting any one would silently degrade the scenario). ──────
  grep -q "enemy_synthetic_range_base', '10'" "$SQL"    || fail "harness lost the tuned-low pirate weapon range (the KITE/CLOSE geometry depends on it)"
  grep -q "spatial_formation_ring_radius', '50'" "$SQL" || fail "harness lost the tuned escort ring radius"
  grep -q "enemy_synthetic_speed_base', '60'" "$SQL"    || fail "harness lost the tuned pirate closing speed (needed for the tick-2 retaliation)"
  grep -q "combat_damage_variance_pct', '0'" "$SQL"     || fail "harness lost the determinism knob (0 variance)"
  grep -q "'autocannon_battery'" "$SQL"                 || fail "harness does not craft the real S0 weapon catalog entry"

  # ── every property is asserted in assert-form (gutting any one block fails here). ──────────────────
  grep -q "SPAWN FAIL: command ship not at location center" "$SQL" || fail "harness lacks the command-ship-at-center assert"
  grep -q "escort ring distances wrong" "$SQL"                     || fail "harness lacks the escort-ring-distance assert"
  grep -q "weapon counts wrong" "$SQL"                             || fail "harness lacks the weapons_json shape assert"
  grep -q "unit_type_id = 'pirate_synthetic'" "$SQL"               || fail "harness lacks the synthetic-pirate-identity assert"
  grep -q "TICK1 FAIL HOLD" "$SQL"                                 || fail "harness lacks the HOLD (command ship unchanged) assert"
  grep -q "TICK1 FAIL KITE" "$SQL"                                 || fail "harness lacks the KITE (armed escort retreat) assert"
  grep -q "TICK1 FAIL CLOSE" "$SQL"                                || fail "harness lacks the CLOSE (unarmed escort advance) assert"
  grep -q "TICK1 FAIL FIRE" "$SQL"                                  || fail "harness lacks the tick-1 fire-event assert"
  grep -q "TICK1 FAIL DAMAGE" "$SQL"                                || fail "harness lacks the pirate-hp-fell assert"
  grep -q "TICK2 FAIL SCREEN" "$SQL"                                || fail "harness lacks the aggro-tier screening assert"
  grep -q "aggro screening breached" "$SQL"                        || fail "harness lacks the command-ship-never-hit assert wording"

  # ── determinism: no random() anywhere (0041 law). gen_random_uuid() (fixture identity only) never
  #    contains the substring "random(" — "gen_random_uuid(" has "_uuid" between "random" and "(" — so
  #    this plain check (the decks-proof.sh precedent) correctly never flags it.
  grep -qE 'random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  echo "COMBAT-SPATIAL SELFTEST: ALL PASSED (self-rolling-back; every dark flag — team_command/additional_commission/module_crafting/module_fitting/spatial_combat — enabled only inside the txn; sole-writer law for group_sortie_members + combat_units; provisioning 100% real-RPC incl. craft/fit/group/send/settle; exactly 2 tick invocations; the engineered geometry knobs (range 10 / ring 50 / pirate speed 60 / variance 0) present; every property — spawn positions, synthetic pirate at center, HOLD/KITE/CLOSE, tick-1 fire, pirate hp fell, tick-2 aggro-tier screening — asserted in assert-form; no random())"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "COMBAT-SPATIAL" "$SQL" "$PASS_LINE" "$MARKERS"
echo "COMBAT-SPATIAL LOCAL PROOF: OVERALL_PASS"
