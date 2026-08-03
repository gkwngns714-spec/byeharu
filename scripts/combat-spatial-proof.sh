#!/usr/bin/env bash
# COMBAT-SPATIAL — disposable proof orchestrator for the S3 spatial-combat slice (migration 0234:
# per-ship positions, the CLOSE-vs-KITE-vs-HOLD movement/targeting AI, synthetic wave spawn, per-weapon
# fire events, and damage). Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends
#              in ROLLBACK), toggles every dark capability flag ONLY inside the txn, provisions ONLY
#              via the real RPCs (commission/craft/fit/group/send — group_sortie_members and
#              combat_units are NEVER hand-written), and exercises every property this slice's own
#              migration self-assert could not (no live fixture exists inside a migration).
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual live-DB
#              scenario proof: spawn → tick → verify positions/kite/close/fire/damage/approach/
#              hold/screening).
#
# 0336 REPOINT. 0336 moved the enemy wave OFF the engagement anchor and onto a formation ring at
# (spatial_formation_ring_radius + the wave's own weapon range + 1), on the bearing to the zone's own city (0338). Every player hull is
# therefore at least (that range + 1) from every enemy at spawn, so NO PLAYER SHIP CAN BE IN HOLD ON
# TICK 1 at any knob setting, and the lead — alone on the anchor while the escorts stand on the ring —
# is now the FURTHEST player hull from the wave rather than the nearest. The .sql was repointed onto
# that geometry (HOLD is proven on the hull that CLOSES to contact, and each witness's arm is DERIVED
# and guarded before its movement is asserted); the greps below were repointed with it. The knob
# assertions here pin the ENGINEERED GEOMETRY, and each of the new guards has its own assert-form grep
# so that gutting one fails HERE rather than silently proving less.
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
  # ── ONE AUTHORITY for "advance one tick": the clock rewind and the cron leaf are a single pg_temp
  #    leaf, because the approach below runs a DERIVED number of ticks rather than a typed one. So
  #    process_combat_ticks() must appear EXACTLY ONCE in the file — inside that leaf. A second
  #    textual call site is a second, drifting definition of "one tick"; zero means nothing ticks. ───
  grep -q "create or replace function pg_temp.cs_tick(" "$SQL" \
    || fail "harness lost the pg_temp.cs_tick leaf (the ONE authority for rewind-then-tick)"
  n="$(grep -c 'perform public\.process_combat_ticks();' "$SQL" || true)"
  [ "$n" = "1" ] || fail "expected exactly 1 textual process_combat_ticks() call (inside pg_temp.cs_tick — the approach runs a derived number of ticks through that leaf), found $n"
  # and the ONE authority for "which arm is this unit in", which every witness guard composes.
  grep -q "create or replace function pg_temp.cs_arm(" "$SQL" \
    || fail "harness lost the pg_temp.cs_arm leaf (the ONE authority for the derived CLOSE/KITE/HOLD arm each witness is guarded against)"
  grep -q "then 'unknown'" "$SQL" \
    || fail "pg_temp.cs_arm no longer answers 'unknown' on a NULL input — a NULL would fall through the CASE and report a motionless-by-accident unit as a passing HOLD"

  # ── the engineered geometry itself: the tuning knobs that make CLOSE/KITE/HOLD all reachable are
  #    present (gutting any one would silently degrade the scenario). 0336 REPOINT — the ring and the
  #    pirate range now size a CHORD (escort-to-wave) and a RADIUS (lead-to-wave), not a spawn-on-top-
  #    of-the-lead; the pirate is parked; the player step is owned so the approach converges. ────────
  grep -q "enemy_synthetic_range_base', '2'" "$SQL"     || fail "harness lost the tuned-low wave weapon range (the whole 0336 geometry — spawn radius, KITE band and the HOLD terminus — is sized off it)"
  grep -q "spatial_formation_ring_radius', '4'" "$SQL"  || fail "harness lost the tuned escort ring radius (4: the escort chord to the wave is then 3.642 — inside the post-0316 catalog gun 5, outside the wave's 2 and the owned fallback 1 — while the lead sits at the full 7)"
  grep -q "enemy_synthetic_speed_base', '0'" "$SQL"     || fail "harness lost the PARKED wave (a moving wave walks toward whichever of two equidistant escorts a float-noise id tiebreak picks, and every later position becomes a coin flip; parked also lets PASS_ENEMY pin the spawn point exactly)"
  grep -q "enemy_synthetic_speed_per_difficulty', '0'" "$SQL" || fail "harness lost the per-difficulty speed pin (the wave would move again at any positive difficulty)"
  grep -q "combat_player_speed_scale', '1'" "$SQL"      || fail "harness lost the OWNED player step (0316 ships this at 0.2, at which the approach to HOLD takes fourteen ticks instead of three)"
  grep -q "combat_damage_variance_pct', '0'" "$SQL"     || fail "harness lost the determinism knob (0 variance)"
  grep -q "combat_hit_variance_pct', '0'" "$SQL"        || fail "harness lost the 0314 per-hit roll pin (0320 seeds that key, so the inheritance from the damage-variance pin stops the moment it exists)"
  grep -q "enemy_attack_base', '1'" "$SQL"              || fail "harness lost the OWNED wave attack (COMBATSPATIAL_PASS_SCREEN stakes 'an escort's hp FELL' on the one landed salvo dealing a positive amount)"
  grep -q "combat_player_fallback_weapon_range', '1'" "$SQL" || fail "harness lost the OWNED fallback range (since 0262 the unfitted escort carries the fallback weapon; it is the CLOSE witness because that range is under the chord, and the HOLD witness because it is at or under the wave's own reach)"
  grep -q "set value='false'::jsonb where key='combat_telegraph_enabled'" "$SQL" \
    || fail "harness does not keep combat_telegraph_enabled dark (0300 lit it; a lit telegraph queues the encounter instead of opening it inline at the settle)"
  grep -q "'autocannon_battery'" "$SQL"                 || fail "harness does not craft the real S0 weapon catalog entry"
  grep -q "the catalog autocannon_battery range" "$SQL" || fail "harness's fitted-range assert is no longer derived from the catalog (the 0313 repoint regressed to a hard-coded seed)"

  # ── every property is asserted in assert-form (gutting any one block fails here). ──────────────────
  grep -q "SPAWN FAIL: command ship not at the engagement anchor" "$SQL" || fail "harness lacks the lead-on-the-anchor assert"
  grep -q "escort ring distances wrong" "$SQL"                     || fail "harness lacks the escort-ring-distance assert"
  grep -q "weapon counts wrong" "$SQL"                             || fail "harness lacks the weapons_json shape assert"
  grep -q "unit_type_id = 'pirate_synthetic'" "$SQL"               || fail "harness lacks the synthetic-pirate-identity assert"
  grep -q "TICK1 FAIL ENEMY: the wave stands at" "$SQL"            || fail "harness lacks the 0336 wave-spawn-point pin (radius = ring + the wave's own range + 1, slot 0, the 0338 arrival phase — the assert the old 'at the location centre' one was repointed into)"
  grep -q "TICK1 FAIL ENEMY: the wave carries range" "$SQL"        || fail "harness lacks the cross-check that the wave's frozen weapons_json range IS the one the spawn radius was predicted from"
  grep -q "TICK1 FAIL KITE: armed escort distance did not increase" "$SQL" || fail "harness lacks the KITE (armed escort retreat) assert"
  grep -q "TICK1 FAIL KITE: armed escort retreated past its own frozen" "$SQL" || fail "harness lacks the KITE cap assert (0234 never retreats past its own range edge)"
  grep -q "TICK1 FAIL CLOSE: fallback escort distance did not decrease" "$SQL" || fail "harness lacks the CLOSE (fallback escort advances) assert"
  grep -q "TICK1 FAIL CLOSE: lead distance did not decrease" "$SQL" || fail "harness lacks the CLOSE (lead advances) assert — after 0336 the lead is the FURTHEST hull and must close"
  grep -q "TICK1 FAIL FIRE: pirate fired" "$SQL"                    || fail "harness lacks the tick-1 wave-silence assert"
  grep -q "TICK1 FAIL DAMAGE" "$SQL"                                || fail "harness lacks the pirate-hp-fell assert"
  grep -q "HOLD FAIL: the holding hull moved" "$SQL"                || fail "harness lacks the HOLD (byte-identical position) assert"
  # 0336: the arm must come from the ENGINE's own leaf, never from the harness's mirror of it. A
  # mirror that drifts is what turned a vanishing KITE step into a "the hull moved" failure printing
  # a byte-identical before/after — the server renders only 15 significant digits.
  grep -q "HOLD FAIL: the ENGINE says" "$SQL"                       || fail "harness no longer takes the HOLD arm from combat_unit_decide_move itself — a hand-written mirror can drift from the mover it copies"
  grep -q "lateral public.combat_unit_decide_move(" "$SQL"          || fail "harness lacks the direct composition of the engine mover for the HOLD arm"
  grep -q "HOLD FAIL: the tick wrote" "$SQL"                        || fail "harness lacks the pin that the tick wrote exactly what the mover predicted"
  grep -q "HOLD FAIL: the engine mover returned no arm" "$SQL"      || fail "harness lacks the NULL-arm vacuity guard on the engine mover"
  grep -q "SCREEN FAIL: lead hp changed" "$SQL"                     || fail "harness lacks the aggro-tier screening assert"
  grep -q "aggro screening breached" "$SQL"                        || fail "harness lacks the lead-never-hit assert wording"

  # ── NON-VACUITY: every witness proves it is in the arm it is named for BEFORE its movement is
  #    asserted, and every silence/stillness proves there was something to be silent or still about.
  #    A retune that slides a witness into another arm must fail LOUDLY, not pass. ──────────────────
  grep -q "TICK1 FAIL premise: the escort chord % is not outside" "$SQL"    || fail "harness lacks the premise that the escort chord is outside the wave's reach (0336's range+1 invariant)"
  grep -q "TICK1 FAIL premise: the escort chord % is not inside" "$SQL"     || fail "harness lacks the premise that the escort chord is inside the armed escort's own reach (it would CLOSE, not KITE)"
  grep -q "TICK1 FAIL FIRE: the nearest player hull is" "$SQL"              || fail "harness lacks the derived form of 0336's spawn invariant (the nearest hull is outside the wave's reach), without which 'the pirate did not fire' is unexplained"
  grep -q "TICK1 FAIL premise: the fallback escort''s chord" "$SQL"          || fail "harness lacks the premise that the fallback escort starts out of its own reach (else the approach never starts)"
  grep -q "TICK1 FAIL premise: the fallback range" "$SQL"                   || fail "harness lacks the premise that the fallback range is at or under the wave's — a hull that out-ranges the enemy rests at its own kite edge and NEVER reaches HOLD"
  grep -q "TICK1 FAIL premise: the lead''s distance" "$SQL"                  || fail "harness lacks the premise that the lead opens out of its own reach (its CLOSE witness would be in another arm)"
  grep -q "TICK1 FAIL KITE: the armed escort''s derived arm" "$SQL"          || fail "harness lacks the KITE vacuity guard (the derived arm must BE 'kite')"
  grep -q "TICK1 FAIL CLOSE: the fallback escort''s derived arm" "$SQL"      || fail "harness lacks the fallback-escort CLOSE vacuity guard (the derived arm must BE 'close')"
  grep -q "TICK1 FAIL CLOSE: the lead''s derived arm" "$SQL"                 || fail "harness lacks the lead CLOSE vacuity guard (the derived arm must BE 'close')"
  grep -q "TICK1 FAIL FIRE: the derivation expects ZERO player salvos" "$SQL" || fail "harness lacks the fire vacuity guard (a scenario in which nothing can fire would make PASS_DAMAGE vacuous)"
  grep -q "derivation expects %" "$SQL"                                     || fail "harness no longer compares the tick-1 salvo count against a DERIVED in-reach count (a hard-coded count would not follow a retune)"
  grep -q "HOLD FAIL: the fallback escort''s derived arm is" "$SQL"          || fail "harness lacks the mid-approach guard (every closing tick must be genuinely in CLOSE)"
  grep -q "HOLD FAIL: a closing tick did not shorten the gap" "$SQL"        || fail "harness lacks the guard that a closing tick actually closes (the approach loop could otherwise become a no-op)"
  grep -q "HOLD FAIL: the fallback escort was already in HOLD" "$SQL"       || fail "harness lacks the guard that the HOLD witness ARRIVED (a hull born in range would prove nothing about the arm)"
  grep -q "HOLD FAIL: the fallback escort is still" "$SQL"                  || fail "harness lacks the bounded-approach guard (a non-converging tuning must fail, not spin)"
  grep -q "HOLD FAIL: the holding hull is not alive" "$SQL"                 || fail "harness lacks the corpse guard (0317 skips a dead actor entirely, so a destroyed hull sits byte-identically still and would pass the HOLD assert)"
  grep -q "HOLD FAIL: the encounter is no longer active" "$SQL"             || fail "harness lacks the live-fight guard (a concluded encounter is not ticked at all, so every position is untouched and the stillness is vacuous)"
  grep -q "SCREEN FAIL: no pirate-sourced missile_salvo" "$SQL"             || fail "harness lacks the screen vacuity guard (with no pirate fire at all, 'the lead was not hit' proves nothing)"

  # ── determinism: no random() anywhere (0041 law). gen_random_uuid() (fixture identity only) never
  #    contains the substring "random(" — "gen_random_uuid(" has "_uuid" between "random" and "(" — so
  #    this plain check (the decks-proof.sh precedent) correctly never flags it.
  grep -qE 'random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  echo "COMBAT-SPATIAL SELFTEST: ALL PASSED (self-rolling-back; every dark flag — team_command/additional_commission/module_crafting/module_fitting/spatial_combat — enabled only inside the txn; sole-writer law for group_sortie_members + combat_units; provisioning 100% real-RPC incl. craft/fit/group/send/settle; ONE authority each for advance-a-tick (pg_temp.cs_tick, the single textual process_combat_ticks call) and for which-arm-is-this (pg_temp.cs_arm, NULL-safe); the 0336 geometry knobs present (wave range 2 / ring 4 -> escort chord 3.642 inside the catalog gun 5 and lead radius 7 outside it / owned fallback range 1 / PARKED wave / owned player step 1 / owned wave attack / both variance knobs 0) with the fitted range still derived from the catalog; every property — spawn positions, the wave standing exactly on combat_formation_point(anchor, ring + its own range + 1, slot 0, the 0338 arrival phase), KITE, CLOSE, the DERIVED tick-1 fire count, pirate hp fell, the arrived HOLD and the aggro-tier screen — asserted in assert-form, each behind a non-vacuity guard on the DERIVED arm; no random())"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "COMBAT-SPATIAL" "$SQL" "$PASS_LINE" "$MARKERS"
echo "COMBAT-SPATIAL LOCAL PROOF: OVERALL_PASS"
