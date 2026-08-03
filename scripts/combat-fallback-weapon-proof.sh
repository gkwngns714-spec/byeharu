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
#
# 0336 REPOINT. 0336 spawns each enemy wave on a formation ring at (spatial_formation_ring_radius +
# the wave's OWN weapon range + 1), phase 0.5, instead of on the engagement anchor. The ring therefore
# moves the WAVE as well as the escort, which is exactly what killed the old "ring 500 = the escort is
# out of range while the command ship stands ON the pirate" fixture: at 500 the wave stands 511 from
# the command ship and the synthesized weapon — this proof's whole subject — would never fire. The
# .sql was repointed onto the new geometry (a ring sized so the escort's chord clears the catalog gun,
# a fallback range owned above the lead's full radius, and an attribution DERIVED from the measured
# reaches then NAMED by the salvo event's own unit_id); the greps below were repointed with it.
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

  # ── the engineered geometry, 0336 REPOINT ───────────────────────────────────────────────────────
  # The old pair here was ring 500 + pirate range 10, and it meant "the escort is parked far out while
  # the command ship stands ON the pirate". 0336 spawns the wave at (ring + its own range + 1), so the
  # ring now moves the WAVE too: at 500 the wave would stand 511 from the command ship, its synthesized
  # weapon would never reach, and this proof's own subject would never fire. The separation is now a
  # RANGE gap — the ring is sized so the escort's CHORD to the wave (8.89) clears the catalog gun (5),
  # while the fallback range is owned ABOVE the lead's full radius (30 > 23). Gutting any one of these
  # silently degrades the attribution.
  grep -q "spatial_formation_ring_radius', '20'" "$SQL" || fail "harness lost the owned ring (it sizes the escort CHORD to the wave — 8.89 — clear of the catalog gun 5, which is what keeps s_arm silent after 0336)"
  grep -q "combat_player_fallback_weapon_range', '30'" "$SQL" || fail "harness lost the OWNED fallback range above the lead's radius (ring 20 + wave range 2 + 1 = 23); without it the synthesized weapon cannot reach and this proof's subject never fires"
  grep -q "enemy_synthetic_range_base', '2'" "$SQL"      || fail "harness lost the tuned-low wave range (it sizes the spawn radius, and the wave must not fire tick 1)"
  grep -q "enemy_synthetic_speed_base', '0'" "$SQL"      || fail "harness lost the PARKED wave (its post-tick position must BE its spawn point for the exact spawn-point pin below)"
  grep -q "enemy_synthetic_speed_per_difficulty', '0'" "$SQL" || fail "harness lost the per-difficulty speed pin (the wave would move again at any positive difficulty)"
  grep -q "combat_damage_variance_pct', '0'" "$SQL"      || fail "harness lost the determinism knob (0 variance)"
  grep -q "combat_hit_variance_pct', '0'" "$SQL"         || fail "harness lost the 0314 per-hit roll pin (0320 seeds that key, so the inheritance from the damage-variance pin stops the moment it exists)"
  grep -q "set value='false'::jsonb where key='combat_telegraph_enabled'" "$SQL" \
    || fail "harness does not keep combat_telegraph_enabled dark (0300 lit it; a lit telegraph queues the encounter instead of opening it inline at the settle)"
  grep -q "'autocannon_battery'" "$SQL"                  || fail "harness does not use the real S0 weapon catalog entry for the armed witness"

  # every property is asserted in assert-form (gutting any one block fails here).
  grep -q "PREFIX_EMPTY FAIL" "$SQL" || fail "harness lacks the pre-fix empty-fitted-weapon assert"
  grep -q "SYNTH FAIL: fallback power" "$SQL" || fail "harness lacks the power = attack_snapshot assert"
  grep -q "SYNTH FAIL: fallback module_type_id" "$SQL" || fail "harness lacks the basic_player_weapon label assert"
  grep -q "ARMED FAIL: s_arm weapon is" "$SQL" || fail "harness lacks the armed-ship-unchanged assert"
  grep -q "DAMAGE FAIL: pirate hp_current" "$SQL" || fail "harness lacks the pirate-hp-fell (nonzero damage) assert"
  grep -q "DAMAGE FAIL: no player missile_salvo on tick 1" "$SQL" || fail "harness lacks the the-fallback-weapon-fired assert"
  grep -q "DAMAGE FAIL: a player ship took damage on tick 1" "$SQL" || fail "harness lacks the clean-tick assert"
  # 0336: the wave's spawn point is PINNED against a point predicted from the knobs before the tick,
  # through combat_formation_point — the very leaf the tick composes.
  grep -q "DAMAGE FAIL: the wave stands at" "$SQL" || fail "harness lacks the 0336 wave-spawn-point pin (radius = ring + the wave's own range + 1, slot 0, phase 0.5) — without it every pre-move distance below is measured against a guess"
  grep -q "DAMAGE FAIL: the wave carries range" "$SQL" || fail "harness lacks the cross-check that the wave's frozen weapons_json range IS the one the spawn radius was predicted from"

  # ── NON-VACUITY: the attribution is DERIVED from the measured geometry and then NAMED — a retune
  #    that puts the wrong hull in reach must fail loudly rather than re-attribute the damage. ──────
  grep -q "DAMAGE FAIL attribution: s_fb is" "$SQL" || fail "harness lacks the guard that s_fb can actually reach the wave (otherwise the DAMAGE assert tests an engine that never fired)"
  grep -q "DAMAGE FAIL attribution: s_arm is" "$SQL" || fail "harness lacks the guard that s_arm is out of its own reach (a firing escort would muddy the attribution)"
  grep -q "DAMAGE FAIL attribution: the nearest player hull is" "$SQL" || fail "harness lacks the derived form of 0336's spawn invariant (every hull outside the wave's reach), without which 'the pirate fired nothing' is unexplained"
  grep -q "DAMAGE FAIL attribution: pirate fired" "$SQL" || fail "harness lacks the pirate-silence assert"
  grep -q "DAMAGE FAIL attribution: the derivation expects" "$SQL" || fail "harness lacks the derived in-reach count (exactly one hull may fire)"
  grep -q "DAMAGE FAIL attribution: % player missile_salvo event(s)" "$SQL" || fail "harness no longer compares the observed tick-1 salvo count against that derived count"
  grep -q "DAMAGE FAIL attribution: the tick-1 player salvo came from unit" "$SQL" || fail "harness lacks the NAMED attribution (the salvo event's own payload unit_id must BE s_fb's combat unit)"
  # 0313 repoint: the expected weapon values must stay DERIVED (knobs/catalog), never re-hard-coded seeds.
  grep -q "derived at assert time" "$SQL" || fail "harness's expected weapon values are no longer derived at assert time (a hard-coded seed would break on every future retune)"

  # determinism (0041): no random() anywhere. gen_random_uuid( has "_uuid" between "random" and "(".
  grep -qE 'random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  echo "COMBAT-FALLBACK SELFTEST: ALL PASSED (self-rolling-back; every dark flag — team_command/additional_commission/module_crafting/module_fitting/captain_assignment/spatial_combat — enabled only inside the txn; sole-writer law for group_sortie_members + combat_units; provisioning 100% real-RPC incl. mint/assign captain + craft/fit; exactly 1 tick invocation; the 0336 geometry present (ring 20 -> escort chord 8.89 clear of the catalog gun 5, owned fallback range 30 above the lead's radius 23, wave range 2, PARKED wave, both variance knobs 0); every property — pre-fix empty fitted join, synthesized power=attack_snapshot @ basic_player_weapon with knob-derived range/projectile/cooldown (0313 repoint: never the hard-coded seeds), armed ship unchanged at its catalog row, the wave standing exactly on combat_formation_point(anchor, ring + its own range + 1, slot 0, phase 0.5), and pirate hp fell with the attribution DERIVED from the measured reaches and NAMED by the salvo event's own unit_id — asserted in assert-form; no random())"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "COMBAT-FALLBACK" "$SQL" "$PASS_LINE" "$MARKERS"
echo "COMBAT-FALLBACK LOCAL PROOF: OVERALL_PASS"
