#!/usr/bin/env bash
# FLEET-GO — disposable proof orchestrator for the unified fleet-level mover (migration 0207,
# charter §3 step 3a). Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends
#              in ROLLBACK), toggles the dark flags ONLY inside the txn, provisions via the real RPCs,
#              and actually asserts the charter §2 properties (above all: NO ship writes).
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the real property proof).
# The shared shell blocks live in scripts/lib/trade-proof-lib.sh (sourced, never re-copied).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/fleetgo-proof.sql"
MIGRATION="$REPO_ROOT/supabase/migrations/20260618000207_fleetgo_unified_group_mover.sql"
MIGRATION_3B="$REPO_ROOT/supabase/migrations/20260618000208_fleetgo_coordinate_targets.sql"
# MIGRATION_STOP points at 0218, the brake's TRUE HEAD since the S3 position-leaf fold — NOT at
# 0215 (and never 0209). A static ban aimed at a superseded head guards nothing (the 0211 failure
# class: a re-create in a NEW file that the old-head-scoped checks never read). 0215's body is
# shipped history; 0218 runs.
MIGRATION_STOP="$REPO_ROOT/supabase/migrations/20260618000218_position_territory_leaves.sql"
# MIGRATION_S3 is 0218 — S3 POSLEAF: the 3 position/territory leaves + the PARITY re-creates of
# BOTH the mover (command_ship_group_go — its 0208 body is now superseded) and the brake.
# ⚠ MOVER-HEAD REPOINT (S4): since 0219 the MOVER's TRUE HEAD is MIGRATION_S4 — 0219 re-creates
# command_ship_group_go with the ONE translate hunk, so the S4 section below aims the LIVE
# mover-body pins (and the byte-parity diff) at 0219. The S3 section's mover pins stay aimed at
# the frozen 0218 file exactly as the 0208/0215 sections keep pinning their own shipped history.
# The BRAKE's true head remains 0218 (S4 re-creates no brake).
MIGRATION_S3="$REPO_ROOT/supabase/migrations/20260618000218_position_territory_leaves.sql"
# MIGRATION_S4 is 0219 — S4 TIMED DOCKING: the mission_type CHECK widen (+ its only 'dock' writer,
# command_ship_group_dock, in the SAME file), the mover PARITY re-create (ONE marked translate
# hunk vs the 0218 head), the timed_docking_enabled/docking_seconds seeds, and the S3-review
# territory_radius CHECK fold. The mover's TRUE HEAD since this file.
MIGRATION_S4="$REPO_ROOT/supabase/migrations/20260618000219_timed_docking.sql"
MIGRATION_3C="$REPO_ROOT/supabase/migrations/20260618000210_fleetgo_group_read_oracle.sql"
MIGRATION_3C2="$REPO_ROOT/supabase/migrations/20260618000211_fleetgo_dock_dedup.sql"
MIGRATION_3C3="$REPO_ROOT/supabase/migrations/20260618000212_fleetgo_map_read.sql"
MIGRATION_4B0="$REPO_ROOT/supabase/migrations/20260618000213_fleetgo_assign_guard.sql"
MIGRATION_4B1="$REPO_ROOT/supabase/migrations/20260618000214_fleetgo_hunt_unified.sql"
# MIGRATION_S1 is 0216 — the BERTH model. It is the NEW true head of assign_ship_to_group,
# delete_ship_group, port_entry_commission_build, ensure_main_ship_for_player, and
# get_my_fleet_positions; the static checks below aim at IT for those bodies (the 0215/0211 rule:
# a ban pointed at a superseded head guards nothing).
MIGRATION_S1="$REPO_ROOT/supabase/migrations/20260618000216_berth_model.sql"
# MIGRATION_S2 is 0217 — S2 TERRITORY: the additive locations.territory_radius column + seed, and
# the PARITY re-create of get_world_map (its 0002 TRUE head was never re-created before 0217; the
# parity diff below aims at 0002 because that IS the head being copied).
MIGRATION_S2="$REPO_ROOT/supabase/migrations/20260618000217_territory_radius.sql"
MIGRATION_0002="$REPO_ROOT/supabase/migrations/20260616000002_world_map.sql"
# MIGRATION_S2R is 0220 — the TERRITORY RETUNE (cross-slice audit fix): 0217's 25/35/15 mutually
# engulfed the real map (min inter-location distance 29.15) — 0220 is the seed-VALUE true head
# now (10/12/8/NULL, all overlap-free); the 0217 greps below keep pinning the frozen 0217 file as
# shipped history, the RUNTIME value pins aim at the deployed (retuned) state.
MIGRATION_S2R="$REPO_ROOT/supabase/migrations/20260618000220_territory_radius_retune.sql"

# Strip PROSE from a migration so the static bans below judge CODE, not documentation. Two kinds of prose
# name the banned constructs on purpose — the `--` header (explaining to the next reader WHY they are
# banned) and the `comment on function ... is '...'` string literal (which is shipped documentation, not
# an executable reference). A naive grep matches both and fails the honest file; the fix is not to stop
# documenting the ban, it is to read the code. (Both traps were hit for real while writing these.)
sql_code() { perl -0777 -pe "s/--[^\n]*//g; s/comment\s+on\s+\w+\s+.*?;//gsi" "$1"; }

MARKERS="FLEETGO_PASS_DARK FLEETGO_PASS_ONEFLEET FLEETGO_PASS_NOSHIPWRITE FLEETGO_PASS_NOGHOSTDOCK FLEETGO_PASS_COMBATDEST FLEETGO_PASS_SPEEDMIN FLEETGO_PASS_REDIRECT FLEETGO_PASS_GUARDS FLEETGO_PASS_TARGETSHAPE FLEETGO_PASS_COORD FLEETGO_PASS_SPACESETTLE FLEETGO_PASS_FROMSPACE FLEETGO_PASS_SETTLEPARITY FLEETGO_PASS_STOP FLEETGO_PASS_ORACLEPARITY FLEETGO_PASS_GROUPREAD FLEETGO_PASS_DOCKDEDUP_DARKPARITY FLEETGO_PASS_DOCKDEDUP_GROUPDOCKED FLEETGO_PASS_DOCKDEDUP_COMMISSION FLEETGO_PASS_ISOLATION FLEETGO_PASS_DOCKDEDUP_HUNTOVERLAP FLEETGO_PASS_DOCKDEDUP_LEGACYPRESENT FLEETGO_PASS_MAPTRANSIT_DARKPARITY FLEETGO_PASS_MAPTRANSIT_GROUP FLEETGO_PASS_MAPSPACE_GROUP FLEETGO_PASS_MAPSPACE_DARKPARITY FLEETGO_PASS_ASSIGNGUARD_DARKPARITY FLEETGO_PASS_ASSIGNGUARD_UNASSIGN FLEETGO_PASS_ASSIGNGUARD_INFLIGHT FLEETGO_PASS_ASSIGNGUARD_HUNTPRESENT FLEETGO_PASS_ASSIGNGUARD_READRIGHT FLEETGO_PASS_ASSIGNGUARD_ELSEWHERE FLEETGO_PASS_ASSIGNGUARD_IDLESPACE FLEETGO_PASS_ASSIGNGUARD_COLOCATED FLEETGO_PASS_ASSIGNGUARD_PERMEMBER_TAG FLEETGO_PASS_ASSIGNGUARD_ONSORTIE FLEETGO_PASS_ASSIGNGUARD_AMBIGUOUS HUNTUNI_DARKPARITY HUNTUNI_REJECT_INFLIGHT HUNTUNI_REJECT_ONSORTIE HUNTUNI_REJECT_MEMBERBUSY HUNTUNI_PASS_NOSECONDFLEET HUNTUNI_PASS_NOGHOSTDOCK HUNTUNI_PASS_RESOLVER HUNTUNI_PASS_AMBIGUOUS HUNTUNI_PASS_BOOTSTRAP HUNTUNI_PASS_FROMSPACE FLEETGO_PASS_STOP_REJECTS_SORTIE FLEETGO_PASS_STOP_DARKINERT FLEETGO_PASS_STOP_SORTIE_LIVESCOPE S3_PASS_POSLEAF_MIDPOINT S3_PASS_POSLEAF_AGREEMENT S3_PASS_POSLEAF_PARKED S3_PASS_POSLEAF_DOCKED S3_PASS_TERRITORY_IN S3_PASS_TERRITORY_OUT S4_PASS_DOCKLEG_MINT S4_PASS_DOCK_SETTLE S4_PASS_TRANSLATE_PARK S4_PASS_DARKPARITY_INSTANTDOCK S4_PASS_GUARD_NOTINTERRITORY S4_PASS_GUARD_ONSORTIE S4_PASS_GUARD_NOTPARKED S4_PASS_RALLY_UNTRANSLATED ASSIGN_CROSSGROUP_GUARDED COMMISSION_BERTHED BERTH_RESOLVER ASSIGN_CLEARS_BERTH UNASSIGN_BERTHS DELETE_BERTHS BERTH_XOR BERTH_BACKFILL TERRITORY_PASS_SEEDED TERRITORY_PASS_NOOVERLAP TERRITORY_PASS_MAPREAD"
PASS_LINE="FLEET-GO PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" fleet_movement_unified_enabled team_command_enabled mainship_additional_commission_enabled station_storage_enabled launch_from_dock_enabled mainship_send_enabled timed_docking_enabled

  # ── provisions via the REAL RPCs (no direct ship/group inserts as the primary path). ─────────────
  grep -q "public.commission_first_main_ship()"      "$SQL" || fail "harness does not provision via commission_first_main_ship"
  grep -q "public.commission_additional_main_ship()" "$SQL" || fail "harness does not provision via commission_additional_main_ship"
  grep -q "public.upsert_ship_group(1, ''Vanguard'')" "$SQL" || fail "harness does not create its group via the real RPC"
  grep -q "public.assign_ship_to_group" "$SQL"             || fail "harness does not assign members via the real RPC"

  # ── the dark gate is asserted with a NONEXISTENT group id (reject-before-read, no existence oracle) ──
  grep -q "unified_movement_disabled" "$SQL" || fail "harness does not assert the dark gate"
  grep -q "command_ship_group_go(gen_random_uuid(), gen_random_uuid())" "$SQL" \
    || fail "dark block does not probe with nonexistent ids (cannot prove reject-BEFORE-read)"

  # ── every property PASS marker is exercised. ─────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done

  # ── THE CROWN JEWEL: the §2 no-ship-write assertion must be real, not decorative. ────────────────
  # It must snapshot ships, diff BOTH directions (EXCEPT alone is asymmetric), guard against a vacuous
  # empty snapshot, and be applied after the go, after the redirect, AND after the rejected guards.
  grep -q "assert_ships_untouched" "$SQL" || fail "no ship-untouched assertion — the charter §2 property is unproven"
  grep -q "except" "$SQL"                 || fail "ship diff does not use EXCEPT"
  grep -q "before-snapshot is EMPTY"      "$SQL" || fail "ship diff does not guard against a vacuous (empty) snapshot"
  for ctx in "'first go'" "'redirect'" "'guards'"; do
    grep -q "assert_ships_untouched('before_.*', 'after_.*', $ctx)" "$SQL" \
      || fail "the §2 ship-untouched assertion is not applied to: $ctx"
  done
  # the snapshot must actually cover every column that could carry movement — S1-BERTH (0216) adds
  # berth_location_id: under the berth model the unfleeted ship's LOCATION lives there, so a mover
  # that wrote it would be a ship write the old snapshot was blind to.
  for col in status spatial_state space_x space_y berth_location_id updated_at; do
    grep -q "$col" "$SQL" || fail "ship snapshot does not cover the '$col' column"
  done

  # ── the redirect proof must be non-vacuous: now() is txn-constant, so without backdating t=0 and the
  #    "interpolated" point trivially equals the origin. The harness must backdate and assert a midpoint.
  grep -q "interval '30 seconds'" "$SQL" || fail "redirect block does not backdate the leg (t would be 0 → vacuous)"
  grep -q "exact midpoint"        "$SQL" || fail "redirect block does not assert the exact interpolated midpoint"

  # ── the speed fold must be recomputed INDEPENDENTLY, not read back from the same helper. ─────────
  grep -q "calculate_expedition_stats" "$SQL" \
    || fail "SPEEDMIN does not recompute from the per-member adapter (would agree with itself)"
  grep -q "calculate_group_expedition_stats" "$SQL" \
    && fail "SPEEDMIN must NOT reuse the same group helper the RPC used (self-agreeing)" || true

  # ── the migration itself must stay dark + additive: it may not re-create or alter a live path. ───
  # These checks judge CODE, not prose — see sql_code() above for why that distinction is load-bearing.
  [ -f "$MIGRATION" ] || fail "migration 0207 not found"
  MIG_CODE="$(sql_code "$MIGRATION")"
  grep -q "fleet_movement_unified_enabled" "$MIGRATION" || fail "migration does not seed its dark flag"
  printf '%s' "$MIG_CODE" | grep -qE "^[[:space:]]*(alter table|drop function|drop table)" \
    && fail "migration alters/drops an existing object (step 3a must be purely additive)" || true
  # THE MODEL: the mover must not write ship movement state. Enforced statically, not just by comment.
  printf '%s' "$MIG_CODE" | grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" \
    && fail "migration UPDATEs main_ship_instances — charter §2 says a ship does not move" || true
  # and it must not compose any per-ship mover (the §0 mistake / the old §3).
  for banned in command_main_ship_space_move mainship_space_begin_move move_main_ship_to_location command_main_ship_space_stop; do
    printf '%s' "$MIG_CODE" | grep -q "$banned" \
      && fail "migration composes the per-ship mover '$banned' — §2 retires them, never composes them" || true
  done
  # the prose ban must be real: the mover's own body must still contain no ship UPDATE (proven above),
  # AND the file must keep the marker that tells the next reader why (so the ban survives edits).
  grep -q "there is deliberately NO" "$MIGRATION" \
    || fail "migration lost the no-ship-write marker that explains the §2 omission to the next reader"

  # ── step 3b (0208): the same §2 bans, PLUS the live-cron parity discipline. ──────────────────────
  # 3b is NOT purely additive — it alters fleets/fleet_movements and re-creates a LIVE, cron-driven
  # function (movement_settle_arrival). That is allowed here and is exactly why the runtime parity pin
  # exists; what is NOT allowed is touching a ship or composing a per-ship mover.
  [ -f "$MIGRATION_3B" ] || fail "migration 0208 not found"
  MIG3B_CODE="$(sql_code "$MIGRATION_3B")"
  printf '%s' "$MIG3B_CODE" | grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" \
    && fail "0208 UPDATEs main_ship_instances — charter §2 says a ship does not move" || true
  for banned in command_main_ship_space_move mainship_space_begin_move move_main_ship_to_location command_main_ship_space_stop; do
    printf '%s' "$MIG3B_CODE" | grep -q "$banned" \
      && fail "0208 composes the per-ship mover '$banned' — §2 retires them, never composes them" || true
  done
  # the fleet — not the ship — must be where the position lands.
  printf '%s' "$MIG3B_CODE" | grep -q "alter table public.fleets add column if not exists space_x" \
    || fail "0208 does not give the FLEET its own position (the whole point of 3b)"
  # the re-created settle must KEEP every legacy branch it inherited from the 0153 head.
  for keep in fleet_set_present presence_create mainship_mark_docked_at_location base_merge_units fleet_complete reward_grant; do
    printf '%s' "$MIG3B_CODE" | grep -q "$keep" \
      || fail "0208's re-created movement_settle_arrival dropped the legacy call '$keep' — live-cron regression"
  done
  # the 2-arg mover must be DROPPED, not left as an overload (one command, one signature).
  printf '%s' "$MIG3B_CODE" | grep -q "drop function if exists public.command_ship_group_go(uuid, uuid)" \
    || fail "0208 does not drop the 2-arg mover — a stale overload would survive"
  # and the runtime must actually pin that parity + the coordinate round-trip.
  grep -q "FLEETGO_PASS_SETTLEPARITY" "$SQL" || fail "no runtime parity pin for the re-created live settle"
  grep -q "mainship_space_location_target_legal" "$SQL" \
    || fail "the parity pin does not assert the 0153 dock rule against the function's OWN legality rule"
  grep -q "the ship-free assertion is vacuous" "$SQL" \
    || fail "ISOLATION does not guard against the vacuous case (nothing moved at all)"
  grep -q "no fleet ever departed FROM its parked coordinate" "$SQL" \
    || fail "ISOLATION does not pin the coordinate round-trip (3b would be unproven)"
  for ctx in "'coordinate go'" "'space settle'" "'go from space'" "'fleet stop'"; do
    grep -q "assert_ships_untouched('before_.*', 'after_.*', $ctx)" "$SQL" \
      || fail "the §2 ship-untouched assertion is not applied to: $ctx"
  done

  # ── the fleet-level BRAKE (TRUE HEAD 0218 since the S3 fold; before that 0215, before that
  #    0209): same §2 bans, it must not be the composed model, and the guard must be present,
  #    LIVE-scoped, and ORDERED. These checks aim at 0218 because THAT is the body that runs — a
  #    ban pointed at a superseded head would green while the live function drifted (the 0211
  #    class). Static checks READ a mktemp FILE — never `printf | grep -q` (the S1 pipefail/EPIPE
  #    lesson): 0218 carries the whole mover + brake and is the largest stream in this arc.
  [ -f "$MIGRATION_STOP" ] || fail "migration 0218 (the brake TRUE HEAD) not found"
  MIGSTOP_TMP="$(mktemp)"
  sql_code "$MIGRATION_STOP" > "$MIGSTOP_TMP"
  grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" "$MIGSTOP_TMP" \
    && fail "0218 UPDATEs main_ship_instances — the legacy stop parks the SHIP; this must park the FLEET" || true
  # it must NOT loop the per-ship stop — that is exactly what 0164 does and what §2 replaces.
  for banned in command_main_ship_stop_transit command_main_ship_space_stop stop_ship_group_transit; do
    grep -q "$banned" "$MIGSTOP_TMP" \
      && fail "0218 composes the per-ship brake '$banned' — that is the composed model §2 retires" || true
  done
  # it must REUSE 3b's parking leaf, not invent a second parking mechanism.
  grep -q "fleet_set_in_space" "$MIGSTOP_TMP" \
    || fail "0218 does not compose 0208's fleet_set_in_space leaf (second parking mechanism?)"
  grep -qE "^[[:space:]]*(alter table|drop function)" "$MIGSTOP_TMP" \
    && fail "0218 alters/drops an existing object (the S3 re-creates must be purely additive)" || true
  # ── THE 0215 SORTIE GUARD (now living in the 0218 body), judged on the BODY's comment-stripped
  #    code (the 0213 lesson: a file-wide grep is satisfied by the self-assert's own literals).
  #    Requires: the gsm join, the reject token, the LIVE scope (bare EXISTS — the status set gone
  #    — bricks every post-hunt stop: FLEETGO_PASS_STOP_SORTIE_LIVESCOPE is its runtime red), and
  #    the ORDER gate < group lock < guard < fleet count (guard after the count answers
  #    no_fleet/ambiguous past a live sortie; guard before the gate leaks the read into the dark
  #    world — DARKINERT's red).
  #    MUTATIONS (the static reds executed while building; the runtime reds traced, CI-only):
  #    strip the hunk → this check red + FLEETGO_PASS_STOP_REJECTS_SORTIE red; bare EXISTS (drop
  #    the status set) → the live-scope regex red + FLEETGO_PASS_STOP_SORTIE_LIVESCOPE red; move
  #    the guard above the gate → the order chain red + FLEETGO_PASS_STOP_DARKINERT red. 0218's
  #    in-file self-assert reds the same three at deploy time.
  perl -0777 -ne '
    my $i = index($_, "create or replace function public.command_ship_group_stop");
    exit 1 if $i < 0;
    my $j = index($_, "\$function\$;", $i);
    exit 1 if $j < 0;
    my $body = substr($_, $i, $j - $i);
    my $gate = index($body, "cfg_bool(\x27fleet_movement_unified_enabled\x27)");
    my $lock = index($body, "from public.ship_groups where group_id = v_group and player_id = v_player for update");
    my $gsm  = index($body, "join public.fleets f on f.id = gsm.fleet_id");
    my $sort = index($body, "group_on_sortie");
    my $amb  = index($body, "fleet_ambiguous");
    exit 1 unless $gate >= 0 && $lock >= 0 && $gsm >= 0 && $sort >= 0 && $amb >= 0;
    exit 1 unless $gate < $lock && $lock < $gsm && $gsm < $sort && $sort < $amb;
    my $guard = substr($body, $gsm, $sort - $gsm);
    exit 1 unless $guard =~ /f\.status in \(.moving., .present., .returning.\)/;
    exit 0;' "$MIGSTOP_TMP" \
    || fail "0218's brake body lost the sortie guard, its LIVE scope, or its order (gate -> group lock -> gsm guard -> fleet count) — an unguarded brake mid-hunt parks an immortal manifest-attached idle fleet and bricks the group"
  # the runtime must pin that the brake and the redirect agree on where "here" is.
  grep -q "disagrees with the redirect interpolation" "$SQL" \
    || fail "no runtime pin that the brake and the redirect compute the SAME interpolated point"
  grep -q "double-stop did not report not_moving" "$SQL" \
    || fail "the brake's idempotence is not pinned (a brake that raises on a second press is a hazard)"
  # the 0215 runtime fixtures must be non-vacuous (each string is a RAISE that fires when the
  # fixture failed to reach the state its marker claims to pin).
  grep -q "the in-flight sortie state was not built" "$SQL" \
    || fail "STOP_REJECTS_SORTIE does not guard that the sortie is really moving (phase 1 vacuous otherwise)"
  grep -q "the mid-combat brake state was not built" "$SQL" \
    || fail "STOP_REJECTS_SORTIE does not guard the present-at-site mid-combat phase (the posture pin vacuous otherwise)"
  grep -q "no live encounter under the brake probe" "$SQL" \
    || fail "STOP_REJECTS_SORTIE does not guard that a LIVE encounter exists (the brake would be refused where it does not hurt)"
  grep -q "the sortie snapshot is empty" "$SQL" \
    || fail "STOP_REJECTS_SORTIE's zero-write diff does not guard against a vacuous empty snapshot"
  grep -q "the dark sortie state was not built" "$SQL" \
    || fail "STOP_DARKINERT does not guard that a live sortie exists while dark (the gate probe vacuous otherwise)"
  grep -q "the retained-manifest state was not built" "$SQL" \
    || fail "STOP_SORTIE_LIVESCOPE does not guard the completed-fleet + retained-manifest shape (the anti-overreach half unproven)"
  grep -q "a live group-shaped fleet survived the completed sortie" "$SQL" \
    || fail "STOP_SORTIE_LIVESCOPE does not guard that ONLY the retained dead manifest could block (ambiguous otherwise)"
  # request_retreat has NO 'ok' key: it RAISES on failure and succeeds with the bare
  # {return_movement_id: null} arm envelope (0019 → 0018's combat branch; the return leg is minted
  # LATER by the tick). The fixture must therefore pin the ARMED STATE, never an envelope key the
  # RPC never had — CI reddened exactly that mistake once (the recurring RPC-shape class).
  grep -q "request_retreat did not arm the encounter" "$SQL" \
    || fail "STOP_SORTIE_LIVESCOPE does not assert the armed-retreat STATE after request_retreat (its envelope has no ok key — asserting one reds a SUCCESSFUL call)"

  # ── THE GHOST-DOCK BAN: a fleet in flight must leave NO member docked behind it. ─────────────────
  # NOSHIPWRITE is structurally BLIND to this — it diffs main_ship_instances, and the leak lives in
  # fleets/location_presence. 3a shipped exactly this bug (it copied the hunt's fleet SHAPE but not its
  # DISSOLVE) and every proof went green. Two tables, two assertions. "The proof passed" is not "the
  # code is right"; a proof only pins the property you thought of.
  grep -q "assert_no_ghost_dock" "$SQL" \
    || fail "no ghost-dock assertion — a flying fleet could leave its ships docked and trading at the origin"
  for ctx in "'first go (bootstrap from the dock)'" "'redirect'" "'coordinate go'" "'go from space'"; do
    grep -q "assert_no_ghost_dock(uA, g, $ctx)" "$SQL" \
      || fail "the ghost-dock assertion is not applied to: $ctx"
  done
  # ...and the mover must actually dissolve them, composing the hunt's proven block (0204:664-676).
  printf '%s' "$MIG3B_CODE" | grep -q "main_ship_id = any(v_members) and status = 'present'" \
    || fail "0208 does not dissolve the members' own present fleets on departure (the ghost-dock bug)"

  # ── A MOVE IS NOT A HUNT: a combat destination settles into an encounter with no units and dies. ─
  printf '%s' "$MIG3B_CODE" | grep -q "combat_destination" \
    || fail "0208 does not refuse a combat destination (the fleet would be destroyed on arrival)"
  grep -q "the assertion would be vacuous" "$SQL" \
    || fail "COMBATDEST does not guard against a fixture with no hunt site (would pass vacuously)"

  # ── step 3c-1 (0210): the READ oracle. Widest blast radius in the charter — ten surfaces route
  #    through validate_context. The group branch must be DARK and the 0056 head must survive verbatim.
  [ -f "$MIGRATION_3C" ] || fail "migration 0210 not found"
  MIG3C_CODE="$(sql_code "$MIGRATION_3C")"
  printf '%s' "$MIG3C_CODE" | grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" \
    && fail "0210 UPDATEs main_ship_instances — the read oracle must never write a ship" || true
  # the group branch must be gated; an ungated widening would change ten live surfaces at once.
  printf '%s' "$MIG3C_CODE" | grep -q "cfg_bool('fleet_movement_unified_enabled') and v_ship.group_id is not null" \
    || fail "0210's group branch is not dark-gated (it would change ten live read surfaces immediately)"
  # the 0056 head must still be present in full — these are its load-bearing states.
  for keep in multiple_active_fleets unknown_spatial_state legacy_present legacy_transit legacy_home contradictory_state; do
    printf '%s' "$MIG3C_CODE" | grep -q "$keep" \
      || fail "0210's re-created validate_context dropped the 0056 state '$keep' — ten surfaces regress"
  done
  # the ONE resolver must exist and must be the thing the dock resolver uses.
  printf '%s' "$MIG3C_CODE" | grep -q "create or replace function public.mainship_resolve_fleet" \
    || fail "0210 does not add the ONE ship->fleet resolver"
  printf '%s' "$MIG3C_CODE" | grep -q "f.id = public.mainship_resolve_fleet(p_main_ship_id)" \
    || fail "0210's dock resolver still keys on main_ship_id (NULL on a unified fleet)"
  # the transition fallback must be marked for deletion, or step 4 will ship a lie.
  grep -q "DELETE THIS BRANCH AT STEP 4" "$MIGRATION_3C" \
    || fail "0210's per-ship transition fallback is not marked for deletion at step 4"
  # and the runtime must pin BOTH halves: dark parity, and the group actually becoming visible.
  grep -q "FLEETGO_PASS_ORACLEPARITY" "$SQL" || fail "no dark-parity pin for the re-created read oracle"
  grep -q "FLEETGO_PASS_GROUPREAD"    "$SQL" || fail "no pin that a member reads its FLEET's place (the 3c deliverable)"
  grep -q "the read could be answered by the retired layer" "$SQL" \
    || fail "GROUPREAD does not prove the answer came from the group (a stray per-ship fleet would fake it)"
  grep -q "assert_ships_untouched('before_groupsettle', 'after_groupsettle', 'group settle at a port')" "$SQL" \
    || fail "§2 is not asserted through the group's ARRIVAL (the cron must dock the fleet, never a ship)"

  # ── step 3c-2 (0211): the dock dedup — FOUR host re-creates onto the ONE resolver pair, plus the
  #    0210 in-place fix (LESSON THREE): the resolver's group branch must be GATED, because the LIVE
  #    hunt already mints the exact fleet shape it matches (group_id set + main_ship_id NULL) and
  #    assign_ship_to_group can put a docked ship into a hunting group mid-flight.
  [ -f "$MIGRATION_3C2" ] || fail "migration 0211 not found"
  MIG3C2_CODE="$(sql_code "$MIGRATION_3C2")"
  # the resolver gate (judged on CODE — the header names the ungated form on purpose, to explain it).
  printf '%s' "$MIG3C_CODE" | grep -q "cfg_bool('fleet_movement_unified_enabled') and v_group is not null" \
    || fail "0210's mainship_resolve_fleet group branch is not dark-gated — the live hunt's fleet would hijack every dock read for a mid-flight-assigned ship"
  grep -q "DELETE THE GATE AT STEP 4" "$MIGRATION_3C" \
    || fail "0210's resolver gate is not marked for deletion at step 4"
  # THE ANTI-FIFTH-COPY GUARD (0138 exists solely because 0136 re-inlined the dock block): no 0211 host
  # may carry a main_ship_id-keyed DOCK read. The legacy_transit read is exempt BY PATTERN (fm.status).
  printf '%s' "$MIG3C2_CODE" | grep -q "f.main_ship_id = v_ship" \
    && fail "0211 re-inlines a main_ship_id-keyed dock read — the fifth copy, the exact 0136 mistake" || true
  printf '%s' "$MIG3C2_CODE" | grep -q "f.main_ship_id = s.main_ship_id and f.status = 'present'" \
    && fail "0211's map dock read is still keyed on main_ship_id (NULL on a unified fleet — the group vanishes)" || true
  # the three at_location hosts compose the ONE dock helper (exactly thrice in code: A, B, and D)…
  [ "$(printf '%s' "$MIG3C2_CODE" | grep -c "public.mainship_resolve_docked_location(v_ship)")" = "3" ] \
    || fail "0211's three dock hosts do not all compose mainship_resolve_docked_location"
  # host D (commission_first_main_ship — the fifth copy the first cut missed) must be re-created here.
  # The "()" is load-bearing: a bare-name grep is prefix-satisfied by any renamed sibling (caught by
  # mutation testing — the rename survived the first version of this grep).
  printf '%s' "$MIG3C2_CODE" | grep -q "create or replace function public.commission_first_main_ship()" \
    || fail "0211 does not re-create commission_first_main_ship (the missed fifth copy stays live)"
  # …and the map read composes the ship→fleet resolver, KEEPING its own status='present' filter.
  printf '%s' "$MIG3C2_CODE" | grep -q "f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.status = 'present'" \
    || fail "0211's map read does not compose mainship_resolve_fleet (or dropped its own status='present' read)"
  # FINDING-1 GUARD: the map read must NOT be collapsed onto the at_location-only dock helper —
  # 'legacy_present' reaches it and prod's live ships are legacy-shaped; that collapse hides them all.
  printf '%s' "$MIG3C2_CODE" | grep -q "mainship_resolve_docked_location(s.main_ship_id)" \
    && fail "0211's map read collapsed onto the at_location-only dock helper — every legacy_present prod ship goes hidden" || true
  # posture: three re-creates and NOTHING else — no table change, no drop, no ship write, no flag.
  printf '%s' "$MIG3C2_CODE" | grep -qE "^[[:space:]]*(alter table|drop function|drop table)" \
    && fail "0211 alters/drops an existing object (3c-2 is three function re-creates ONLY)" || true
  printf '%s' "$MIG3C2_CODE" | grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" \
    && fail "0211 UPDATEs main_ship_instances — a read host must never write a ship" || true
  printf '%s' "$MIG3C2_CODE" | grep -qiE "(insert into|update)[[:space:]]+(public\.)?game_config" \
    && fail "0211 seeds or flips a flag (3c-2 changes no behavior on its own)" || true
  # the legacy_transit branch is 3c-3's problem and must survive UNTOUCHED (still main_ship_id-keyed).
  printf '%s' "$MIG3C2_CODE" | grep -q "f.main_ship_id = s.main_ship_id and fm.status = 'moving'" \
    || fail "0211 touched the legacy_transit branch — that is 3c-3's problem, not 3c-2's"
  # the true-head declaration: 3c-3 must copy get_my_fleet_positions from 0211, never from 0200.
  grep -q "TRUE-HEAD DECLARATION" "$MIGRATION_3C2" \
    || fail "0211 does not declare itself the true head — the 0136→0138 stale-head mistake repeats by default"
  # the runtime fixtures must be non-vacuous: each guard string below is a RAISE that fires when the
  # fixture failed to reach the state the marker claims to pin.
  grep -q "the frozen-vs-live split is gone" "$SQL" \
    || fail "HUNTOVERLAP does not guard that c2 is OFF the hunt manifest (a manifest member would pass vacuously)"
  grep -q "right/wrong answers indistinguishable" "$SQL" \
    || fail "HUNTOVERLAP does not guard that c2's port differs from the hunt site"
  grep -q "hunt fleet did not settle present at the hunt site" "$SQL" \
    || fail "HUNTOVERLAP does not guard the settled phase (phase 2 would be vacuous)"
  grep -q "fixture is not prod''s shape" "$SQL" \
    || fail "LEGACYPRESENT does not guard the one-active-fleet prod shape"
  grep -q "the grouped case would be vacuous" "$SQL" \
    || fail "DOCKDEDUP dark parity does not guard that the grouped ship is actually grouped"
  grep -q "DOCKDEDUP-GROUPDOCKED FAIL: % per-ship fleet" "$SQL" \
    || fail "GROUPDOCKED does not re-assert the zero-per-ship-fleet vacuity guard"
  grep -q "commission replay (grouped uA) drifted while dark" "$SQL" \
    || fail "DARKPARITY does not pin host D (the port-entry replay) while dark"
  grep -q "the replay could be answered by the retired layer" "$SQL" \
    || fail "COMMISSION does not guard the zero-per-ship-fleet vacuity"

  # ── step 3c-3 (0212): the map read — get_my_fleet_positions re-created from the 0211 TRUE HEAD.
  #    ONE function re-create, THREE hunks: the legacy_transit rekey, the fleet-first in_space read,
  #    and the emit reading the resolved coordinate. The ship-coordinate fallback must SURVIVE (it is
  #    the dark parity path), and 0211's docked hunk must survive VERBATIM (the anti-0136 tripwire).
  [ -f "$MIGRATION_3C3" ] || fail "migration 0212 not found"
  MIG3C3_CODE="$(sql_code "$MIGRATION_3C3")"
  # posture: exactly ONE re-create, and it is get_my_fleet_positions(). The "()" is load-bearing — a
  # bare-name grep is prefix-satisfied by any renamed sibling (the mutation-proven 0211 lesson).
  [ "$(printf '%s' "$MIG3C3_CODE" | grep -c "create or replace function")" = "1" ] \
    || fail "0212 must contain exactly ONE create or replace function (3c-3 re-creates the map read ONLY)"
  printf '%s' "$MIG3C3_CODE" | grep -q "create or replace function public.get_my_fleet_positions()" \
    || fail "0212's one re-create is not public.get_my_fleet_positions()"
  printf '%s' "$MIG3C3_CODE" | grep -qE "^[[:space:]]*(alter table|drop function|drop table)" \
    && fail "0212 alters/drops an existing object (3c-3 is ONE function re-create ONLY)" || true
  printf '%s' "$MIG3C3_CODE" | grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" \
    && fail "0212 UPDATEs main_ship_instances — a read host must never write a ship" || true
  printf '%s' "$MIG3C3_CODE" | grep -qiE "(insert into|update)[[:space:]]+(public\.)?game_config" \
    && fail "0212 seeds or flips a flag (3c-3 changes no behavior on its own)" || true
  # hunk 1: the transit rekey is present, and the OLD per-ship key is BANNED anywhere in 0212.
  printf '%s' "$MIG3C3_CODE" | grep -q "f.id = public.mainship_resolve_fleet(s.main_ship_id) and fm.status = 'moving'" \
    || fail "0212's legacy_transit read does not compose mainship_resolve_fleet (the 3c-3 hunk is missing — the flying group stays hidden)"
  printf '%s' "$MIG3C3_CODE" | grep -q "f.main_ship_id = s.main_ship_id" \
    && fail "0212 still carries the old per-ship key 'f.main_ship_id = s.main_ship_id' (NULL on a unified fleet)" || true
  # STALE-HEAD TRIPWIRE (anti-0136): 0211's docked hunk must SURVIVE in 0212 — a rebuild from the 0200
  # head lacks it and reds here instantly. Plus the true-head declaration itself.
  printf '%s' "$MIG3C3_CODE" | grep -q "f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.status = 'present'" \
    || fail "0212 lost 0211's docked hunk — it was rebuilt from a stale head (the exact 0136 mistake)"
  grep -q "TRUE-HEAD DECLARATION" "$MIGRATION_3C3" \
    || fail "0212 does not declare itself the true head — the 0136→0138 stale-head mistake repeats by default"
  # hunk 2: the fleet-first read AND the preserved ship fallback (the dark parity path).
  printf '%s' "$MIG3C3_CODE" | grep -q "f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.location_mode = 'space'" \
    || fail "0212's in_space arm does not read the FLEET's parked coordinate (hunk 2 missing — a parked fleet stays invisible)"
  printf '%s' "$MIG3C3_CODE" | grep -q "s.space_x is not null" \
    || fail "0212 dropped the ship-coordinate fallback — the dark parity path dies and every OSN-held prod ship goes hidden"
  # the runtime fixtures must be non-vacuous (each string is a RAISE that fires when the fixture failed
  # to reach the state its marker claims to pin).
  grep -q "did not reach legacy_transit" "$SQL" \
    || fail "MAPTRANSIT_DARKPARITY does not guard that the fixture reached legacy_transit (vacuous otherwise)"
  grep -q "the transit could be answered by the retired layer" "$SQL" \
    || fail "MAPTRANSIT_GROUP does not re-assert the zero-per-ship-fleet vacuity guard"
  grep -q "only the FLEET could have answered" "$SQL" \
    || fail "MAPSPACE_GROUP does not guard that zero ships carry a position"
  grep -q "did not reach in_space" "$SQL" \
    || fail "MAPSPACE_DARKPARITY does not guard that the oracle answers in_space (vacuous otherwise)"

  # ── step 4b-0 (0213): the PRE-FLIP assign guard. TWO re-creates ONLY (the 0204 assign head + the
  #    ONE new leaf), the guard hunk strictly BETWEEN the group lock and the ship write, the lit lock
  #    hardened to FOR UPDATE with the dark FOR SHARE preserved byte-identically, and the leaf keyed
  #    on the SHAPE (main_ship_id IS NULL — never group_id alone, the 0204:316 display-tag trap).
  [ -f "$MIGRATION_4B0" ] || fail "migration 0213 not found"
  MIG4B0_CODE="$(sql_code "$MIGRATION_4B0")"
  [ "$(printf '%s' "$MIG4B0_CODE" | grep -c "create or replace function")" = "2" ] \
    || fail "0213 must contain exactly TWO re-creates (the assign head + the ship_group_resolve_fleet leaf)"
  printf '%s' "$MIG4B0_CODE" | grep -q "create or replace function public.assign_ship_to_group(p_main_ship_id uuid, p_group_id uuid default null)" \
    || fail "0213 does not re-create assign_ship_to_group with the head's exact signature"
  printf '%s' "$MIG4B0_CODE" | grep -q "create or replace function public.ship_group_resolve_fleet(p_player uuid, p_group uuid)" \
    || fail "0213 does not add the ship_group_resolve_fleet leaf (the ONE authority on the group-fleet shape)"
  printf '%s' "$MIG4B0_CODE" | grep -qE "^[[:space:]]*(alter table|drop function|drop table)" \
    && fail "0213 alters/drops an existing object (4b-0 is two function re-creates ONLY)" || true
  printf '%s' "$MIG4B0_CODE" | grep -qiE "(insert into|update)[[:space:]]+(public\.)?game_config" \
    && fail "0213 seeds or flips a flag (the flip is 4b's LAST act, never a side effect)" || true
  # the leaf pins the SHAPE, and the guard composes it (no fifth inline copy of the shape). Judged on
  # the LEAF'S OWN BODY, not the whole file — the self-assert DO block quotes the same string as a
  # literal, which satisfied a file-wide grep while the leaf itself had lost the key (caught by
  # mutation testing: the first version of this check was vacuous).
  printf '%s' "$MIG4B0_CODE" | perl -0777 -ne '
    my $i = index($_, "create or replace function public.ship_group_resolve_fleet");
    exit 1 if $i < 0;
    my $j = index($_, "\$\$;", $i);
    exit 1 if $j < 0;
    my $leaf = substr($_, $i, $j - $i);
    exit 1 unless index($leaf, "main_ship_id is null") >= 0;
    exit 1 unless $leaf =~ /status in \(.idle., .moving., .present., .returning.\)/;
    exit 0;' \
    || fail "0213's leaf body lost the main_ship_id IS NULL key or the live-status set — group_id alone matches the legacy per-member tag"
  # the GATED lock branch: lit FOR UPDATE (the TOCTOU closure vs the sends' FOR SHARE), dark FOR SHARE
  # (the lock footprint is part of parity). Both arms must exist; the runtime race itself is NOT
  # testable here (single psql session — no deterministic two-session interleaving), so the closure is
  # lock-conflict reasoning + this mutation-tested assert, and 0213 must SAY so in-file rather than
  # decorate the proof with a marker that cannot fail.
  # Judged on the ASSIGN BODY'S OWN gated structure, not a file-wide substring — the self-assert DO
  # block quotes both lock strings as literals, which satisfied a file-wide grep while the body had
  # been flattened to a single un-gated lock (caught by mutation testing, same failure mode as the
  # leaf-shape check above).
  printf '%s' "$MIG4B0_CODE" | perl -0777 -ne '
    my $i = index($_, "create or replace function public.assign_ship_to_group");
    exit 1 if $i < 0;
    my $j = index($_, "\$\$;", $i);
    exit 1 if $j < 0;
    my $body = substr($_, $i, $j - $i);
    exit 1 unless $body =~ /if v_unified then\s*perform 1 from public\.ship_groups where group_id = v_group and player_id = v_player for update;\s*else\s*perform 1 from public\.ship_groups where group_id = v_group and player_id = v_player for share;\s*end if;/;
    exit 0;' \
    || fail "0213's assign body lost the GATED lock branch (lit FOR UPDATE closes the assign-vs-send TOCTOU; dark FOR SHARE is lock-footprint parity)"
  grep -q "deterministic two-session race" "$MIGRATION_4B0" \
    || fail "0213 does not state in-file that the two-session race is untestable here (honesty is part of the proof)"
  # ORDER (mutation-tested): lock → ambiguous → in-flight → elsewhere → on-sortie → cap → ship
  # write, on comment-stripped CODE, FIRST occurrences. A guard arm after the write guards nothing;
  # one before the lock IS the TOCTOU; the sortie arm must guard the would-be ALLOW (after the
  # elsewhere reject — a sortie is never joinable, co-located or not). This chain is ALSO the
  # body-presence check for every reject token: the self-assert DO block quotes each token as a
  # literal AFTER the ship write, so an arm deleted from the BODY relocates its first occurrence
  # past the update offset and the chain reds (the grep-vacuity trap the leaf/lock checks hit,
  # closed here by construction). The gsm-manifest read must sit inside the guard (before the
  # sortie token, after the lock) — the mover's guard-7 shape (0207:161-172).
  printf '%s' "$MIG4B0_CODE" | perl -0777 -ne '
    my $lock  = index($_, "from public.ship_groups");
    my $amb   = index($_, "fleet_ambiguous");
    my $guard = index($_, "group_fleet_in_flight");
    my $elsw  = index($_, "group_fleet_elsewhere");
    my $gsm   = index($_, "group_sortie_members");
    my $sort  = index($_, "group_on_sortie");
    my $cap   = index($_, "fleet_full");
    my $upd   = index($_, "update public.main_ship_instances");
    exit 1 unless $lock >= 0 && $amb >= 0 && $guard >= 0 && $elsw >= 0 && $gsm >= 0 && $sort >= 0 && $cap >= 0 && $upd >= 0;
    exit 1 unless $lock < $amb && $amb < $guard && $guard < $elsw && $elsw < $sort && $sort < $cap && $cap < $upd;
    exit 1 unless $lock < $gsm && $gsm < $sort;
    exit 0;' \
    || fail "0213's guard arms are not in lock -> ambiguous -> in-flight -> elsewhere -> on-sortie -> cap -> update order between the group lock and the ship write (an arm is missing or misplaced)"
  # the runtime fixtures must be non-vacuous (each string is a RAISE that fires when the fixture
  # failed to reach the state its marker claims to pin).
  grep -q "the in-flight state was not built" "$SQL" \
    || fail "ASSIGNGUARD does not guard that the hunt fleet is really moving (INFLIGHT/DARKPARITY vacuous otherwise)"
  grep -q "d2 is ON the hunt manifest" "$SQL" \
    || fail "ASSIGNGUARD does not guard that the assignee is OFF the frozen manifest (the frozen-vs-live split under test)"
  grep -q "d2''s port IS the hunt site" "$SQL" \
    || fail "ASSIGNGUARD does not guard that the assignee's port differs from the hunt site (right/wrong indistinguishable)"
  grep -q "empty before-snapshot" "$SQL" \
    || fail "ASSIGNGUARD-INFLIGHT's zero-write diff does not guard against a vacuous empty snapshot"
  grep -q "the present phase is vacuous" "$SQL" \
    || fail "ASSIGNGUARD-HUNTPRESENT does not guard the settled-at-hunt-site phase (the charter's own branch)"
  grep -q "the elsewhere phase is vacuous" "$SQL" \
    || fail "ASSIGNGUARD-ELSEWHERE does not guard that the fleet is really present at a different port"
  grep -q "co-location has nothing to compare" "$SQL" \
    || fail "ASSIGNGUARD does not guard the assignee's own dock shape (fleet+presence at its port)"
  grep -q "the idle phase is vacuous" "$SQL" \
    || fail "ASSIGNGUARD-IDLESPACE does not guard that the fleet is really parked idle in space"
  grep -q "the co-located phase is vacuous" "$SQL" \
    || fail "ASSIGNGUARD-COLOCATED does not guard that the fleet settled at the assignee's own port"
  grep -q "the tag fixture is vacuous" "$SQL" \
    || fail "ASSIGNGUARD-PERMEMBER does not guard that the tagged per-member fleet really exists and moves"
  grep -q "the key under test is not isolated" "$SQL" \
    || fail "ASSIGNGUARD-PERMEMBER does not guard that NO group-shaped fleet exists (the key would be untested)"
  grep -q "the co-located-sortie state was not built" "$SQL" \
    || fail "ASSIGNGUARD-ONSORTIE does not guard that the assignee is docked AT the site with the sortie fleet present there"
  grep -q "no open sortie for gD" "$SQL" \
    || fail "ASSIGNGUARD-ONSORTIE does not guard that an OPEN sortie exists (the sortie arm would be untested)"
  grep -q "the two-fleet broken invariant was not built" "$SQL" \
    || fail "ASSIGNGUARD-AMBIGUOUS does not guard that exactly two group-shaped fleets exist (the >1 arm would be untested)"

  # ── step 4b-1 (0214): the hunt learns the fleet. ONE re-create ONLY (the 0204 hunt head + hunks
  #    A/B/C), the 0213 leaf COMPOSED (never a fifth inline copy of the group-fleet shape), the lit
  #    lock hardened to FOR UPDATE with the dark FOR SHARE preserved byte-identically, the guard
  #    arms in leaf → ambiguous → in-flight → consume → mint order strictly BETWEEN the member lock
  #    and the head's readiness, and the head's arms surviving verbatim for the =0 fall-through.
  #    RUNTIME MUTATIONS (traced; the red runs need CI's disposable Postgres — none exists here):
  #      • force `v_unified := true`      → HUNTUNI_DARKPARITY's second probe answers
  #                                         group_fleet_in_flight, not member_not_ready → red.
  #      • delete the in-flight arm       → HUNTUNI_REJECT_INFLIGHT gets ok:true (the moving fleet
  #                                         is "consumed" from its anchor) → red; the order chain
  #                                         below also reds statically.
  #      • skip Hunk C's fleet-complete   → two live group-shaped fleets → HUNTUNI_PASS_NOSECONDFLEET
  #                                         red; the order chain below also reds statically.
  #      • delete the >1 arm              → the two-fleet fixture falls through to consume/in-flight
  #                                         → HUNTUNI_PASS_AMBIGUOUS red; the order chain reds.
  #      • drop the member-dock dissolve  → the co-located assignee (f3, the 0213 ALLOW shape) stays
  #                                         'present' with an active presence while hunting →
  #                                         HUNTUNI_PASS_NOGHOSTDOCK red; the count check below
  #                                         also reds statically.
  #      • drop the gsm manifest read (F1)→ the 'present' MID-COMBAT sortie fleet is treated as
  #                                         settled-consumable: the live encounter's presence is
  #                                         closed + the fleet completed + a second sortie minted
  #                                         (or the zero-distance leg raises) → HUNTUNI_REJECT_ONSORTIE
  #                                         red; the order chain below also reds statically.
  #      • drop the member-busy guard (F2)→ a member flying its own per-ship fleet is minted
  #                                         'hunting' → HUNTUNI_REJECT_MEMBERBUSY red; the order
  #                                         chain below also reds statically.
  [ -f "$MIGRATION_4B1" ] || fail "migration 0214 not found"
  MIG4B1_CODE="$(sql_code "$MIGRATION_4B1")"
  [ "$(printf '%s' "$MIG4B1_CODE" | grep -c "create or replace function")" = "1" ] \
    || fail "0214 must contain exactly ONE re-create (the send_ship_group_hunt head — the leaf lives in 0213)"
  printf '%s' "$MIG4B1_CODE" | grep -q "create or replace function public.send_ship_group_hunt(p_group_id uuid, p_location uuid, p_return_location_id uuid default null)" \
    || fail "0214 does not re-create send_ship_group_hunt with the head's exact 3-arg signature"
  printf '%s' "$MIG4B1_CODE" | grep -qE "^[[:space:]]*(alter table|drop function|drop table)" \
    && fail "0214 alters/drops an existing object (4b-1 is one function re-create ONLY)" || true
  printf '%s' "$MIG4B1_CODE" | grep -qiE "(insert into|update)[[:space:]]+(public\.)?game_config" \
    && fail "0214 seeds or flips a flag (the flip is 4b's LAST act, never a side effect)" || true
  # the leaf is COMPOSED (the 0213 authority), not re-inlined.
  printf '%s' "$MIG4B1_CODE" | grep -q "ship_group_resolve_fleet(v_player, v_group)" \
    || fail "0214 does not compose the 0213 leaf (a fifth inline copy of the group-fleet shape is the default outcome)"
  # per-ship movers stay uncomposed (§2 retires them; the §0 mistake).
  for banned in command_main_ship_space_move mainship_space_begin_move move_main_ship_to_location command_main_ship_space_stop; do
    printf '%s' "$MIG4B1_CODE" | grep -q "$banned" \
      && fail "0214 composes the per-ship mover '$banned' — §2 retires them, never composes them" || true
  done
  # the ONLY ship writes are the hunt's own status='hunting' signal, in exactly THREE mint paths
  # (Hunk C + the NOHOME launch branch + the 0168 dark head). The hunt is NOT the unified mover —
  # this write retires at 4c, not here — but a fourth write (or a dropped one) is a defect.
  [ "$(printf '%s' "$MIG4B1_CODE" | grep -cE "update[[:space:]]+(public\.)?main_ship_instances")" = "3" ] \
    || fail "0214's ship-write count drifted (expected the head's hunting write in exactly 3 mint paths)"
  [ "$(printf '%s' "$MIG4B1_CODE" | grep -c "set status = 'hunting'")" = "3" ] \
    || fail "0214's status='hunting' write is not in exactly 3 mint paths (a mint path lost the sortie signal)"
  grep -q "IT RETIRES AT STEP 4c" "$MIGRATION_4B1" \
    || fail "0214 lost the 4c-retirement marker on the kept ship write (the dependency note for the column narrowing)"
  # the consuming path must dissolve the members' OWN present fleets (the head's 0204:664-676 block,
  # composed — the mover composes the same block at every go). 0213's co-located ALLOW arm leaves an
  # assignee holding its dock pair; a sortie that keeps it active is §0 through the hunt's front
  # door. EXACTLY TWO occurrences: Hunk C's copy + the head's launch branch (one = the head only =
  # the consuming path lost its dissolve).
  [ "$(printf '%s' "$MIG4B1_CODE" | grep -c "main_ship_id = any(v_members) and status = 'present'")" = "2" ] \
    || fail "0214's consuming path lost the member-dock dissolve (the 0213 co-located assignee would be hunting and docked at once)"
  # the GATED lock branch: lit FOR UPDATE (serializes hunt-vs-go/stop/assign), dark FOR SHARE
  # byte-identical (the lock footprint is part of parity). Judged on the BODY's gated structure —
  # a file-wide substring is satisfied by the self-assert's own literals (the 0213 lesson).
  printf '%s' "$MIG4B1_CODE" | perl -0777 -ne '
    my $i = index($_, "create or replace function public.send_ship_group_hunt");
    exit 1 if $i < 0;
    my $j = index($_, "\$\$;", $i);
    exit 1 if $j < 0;
    my $body = substr($_, $i, $j - $i);
    exit 1 unless $body =~ /if v_unified then\s*perform 1 from public\.ship_groups where group_id = v_group and player_id = v_player for update;\s*else\s*perform 1 from public\.ship_groups where group_id = v_group and player_id = v_player for share;\s*end if;/;
    exit 0;' \
    || fail "0214's hunt body lost the GATED lock branch (lit FOR UPDATE serializes hunt-vs-go; dark FOR SHARE is lock-footprint parity)"
  # ORDER (mutation-tested): member-lock → leaf → ambiguous → in-flight → the gsm MANIFEST read →
  # on-sortie → hp-only check → member-busy → consume → mint → the head's readiness → the head's
  # launch branch, on comment-stripped CODE, FIRST occurrences. The manifest read must sit between
  # the status arm and anything settled-consumable (the F1 rule: a 'present' MID-COMBAT sortie is
  # never consumable — the status arm alone is NOT guard 8's twin, the manifest read is what makes
  # it one); Hunk C after the head's readiness would re-open the defect (stale per-ship signals
  # rejecting a settled fleet before the fleet is ever read); the consume must precede the mint
  # (terminal-before-new IS the at-most-one construction); and the head's readiness + launch arms
  # must survive AFTER the hunk (the =0 fall-through). This chain is also the body-presence check
  # for every arm: a deleted arm relocates its first occurrence into the self-assert literals past
  # the launch offset (or vanishes) and the chain reds.
  printf '%s' "$MIG4B1_CODE" | perl -0777 -ne '
    my $decl   = index($_, "v_unified boolean := public.cfg_bool(\x27fleet_movement_unified_enabled\x27)");
    my $mlock  = index($_, ") locked;");
    my $leaf   = index($_, "ship_group_resolve_fleet");
    my $amb    = index($_, "fleet_ambiguous");
    my $infl   = index($_, "group_fleet_in_flight");
    my $gsm    = index($_, "group_sortie_members");
    my $sort   = index($_, "group_on_sortie");
    my $hponly = index($_, "main_ship_id = any(v_members) and hp <= 0");
    my $busy   = index($_, "member_busy");
    my $cons   = index($_, "set status = \x27completed\x27");
    my $mint   = index($_, "current_base_id, group_id, return_location_id)");
    my $ready  = index($_, "if v_launch_from_dock then");
    my $launch = index($_, "if v_launch_from_dock and v_docked > 0 then");
    my $darkro = index($_, "status <> \x27home\x27 or hp <= 0");
    exit 1 unless $decl >= 0 && $mlock >= 0 && $leaf >= 0 && $amb >= 0 && $infl >= 0
               && $gsm >= 0 && $sort >= 0 && $busy >= 0
               && $hponly >= 0 && $cons >= 0 && $mint >= 0 && $ready >= 0 && $launch >= 0 && $darkro >= 0;
    exit 1 unless $decl < $mlock && $mlock < $leaf && $leaf < $amb && $amb < $infl
               && $infl < $gsm && $gsm < $sort && $sort < $hponly && $hponly < $busy
               && $busy < $cons && $cons < $mint && $mint < $ready
               && $ready < $launch && $ready < $darkro;
    exit 0;' \
    || fail "0214's hunk order broke: member-lock -> leaf -> ambiguous -> in-flight -> manifest-read -> on-sortie -> hp-only -> member-busy -> consume -> mint must sit BEFORE the head's readiness/launch arms (an arm is missing, misplaced, or the head's arms did not survive)"
  # the runtime fixtures must be non-vacuous (each string is a RAISE that fires when the fixture
  # failed to reach the state its marker claims to pin).
  grep -q "the docked-launch head path would be vacuous" "$SQL" \
    || fail "HUNTUNI_DARKPARITY does not guard that the member is really docked (the 0199 arm untested otherwise)"
  grep -q "this is not the head''s reachable dark state" "$SQL" \
    || fail "HUNTUNI_DARKPARITY does not guard that no group-shaped fleet pre-exists (parity asserted off the reachable state otherwise)"
  grep -q "the second probe would be vacuous" "$SQL" \
    || fail "HUNTUNI_DARKPARITY lacks the second probe's vacuity guard (the ONLY probe the v_unified mutation can redden)"
  grep -q "the mid-combat sortie state was not built" "$SQL" \
    || fail "HUNTUNI_REJECT_ONSORTIE does not guard that the sortie fleet is really present-at-site with an open manifest"
  grep -q "no live encounter on the sortie fleet" "$SQL" \
    || fail "HUNTUNI_REJECT_ONSORTIE does not guard that a LIVE encounter exists (the consume would be untested where it hurts)"
  grep -q "the busy-member state was not built" "$SQL" \
    || fail "HUNTUNI_REJECT_MEMBERBUSY does not guard that the member's per-ship fleet is really moving (the F2 guard untested otherwise)"
  grep -q "the consume phase is vacuous" "$SQL" \
    || fail "HUNTUNI_PASS_NOSECONDFLEET does not guard that the unified fleet really settled present (consume untested otherwise)"
  grep -q "the ghost-dock assertion would be vacuous" "$SQL" \
    || fail "HUNTUNI_PASS_NOGHOSTDOCK does not guard that an active presence existed to be closed"
  grep -q "the co-located shape was not built" "$SQL" \
    || fail "HUNTUNI_PASS_NOGHOSTDOCK does not guard the co-located assignee's dock pair (the member-dissolve untested otherwise)"
  grep -q "the catastrophe shape was not built" "$SQL" \
    || fail "HUNTUNI_PASS_NOSECONDFLEET does not guard the legacy-home zero-per-ship-fleet shape (the double-mint shape untested otherwise)"
  grep -q "the resolution could come from the retired layer" "$SQL" \
    || fail "HUNTUNI_PASS_RESOLVER does not guard that zero per-ship fleets exist"
  grep -q "this would not exercise the =0 arm" "$SQL" \
    || fail "HUNTUNI_PASS_BOOTSTRAP does not guard that the leaf really returns zero rows"
  grep -q "the from-space state was not built" "$SQL" \
    || fail "HUNTUNI_PASS_FROMSPACE does not guard that the fleet is really parked idle in space"
  grep -q "the origin could come from the retired layer" "$SQL" \
    || fail "HUNTUNI_PASS_FROMSPACE does not guard that zero ships carry a position"

  # ── THE TREE-WIDE DOCK-COPY BAN. 0072 proved an alias-free copy evades exact-substring greps, and
  # the recorded 0136 failure mode is a NEW file re-inlining the block — a file a 0211-only grep never
  # sees. So the ban is a comment-stripped, whitespace-collapsed, STATEMENT-level scan of EVERY
  # migration for the copy's shape: a SELECT of current_location_id FROM fleets keyed main_ship_id = …
  # with status = 'present'. The allowlist names every superseded body that legitimately still carries
  # the shape (shipped history — frozen files can never be edited); anything else, in ANY migration,
  # reds this selftest. Reasons: 0069/0082 = dock-services ancestor+head and 0158/0159 = docked-store
  # ancestor+head and 0200 = fleet-positions head (all superseded by 0211); 0072 = commission head,
  # superseded by 0211 host D (the missed fifth copy); 0087/0089/0090 = pre-0092 trade bodies and
  # 0136 = the recorded re-inline (superseded by 0092→0136→0138); 0092 = the helper's own original
  # body (superseded by 0210).
  # 0216 is allowlisted for ONE statement only: the S1-BERTH BACKFILL — the sanctioned one-time
  # conversion of the legacy corpse layer into berth_location_id (a data migration reading "the
  # ship's most recent 'present' fleet's port" ONCE, at deploy time; 0216's header records it and
  # its LIVE code paths compose mainship_resolve_fleet instead — the berth-read guard below pins
  # that no function body in 0216 carries the copy).
  DOCKCOPY_ALLOW="20260618000069_phase9_dock_services_read.sql
20260618000072_port_entry_commission_normalize.sql
20260618000082_trade_fleet_0c_cmd_p_main_ship_id_reads.sql
20260618000087_trade_market_1_get_offers.sql
20260618000089_trade_market_1_buy.sql
20260618000090_trade_market_1_sell.sql
20260618000092_trade_market_1_resolve_docked_location.sql
20260618000136_world_balance_p19_price_drift.sql
20260618000158_station_storage_p2_docked_store_read.sql
20260618000159_a0_owned_ship_resolve_docked_store_and_preview.sql
20260618000200_fleetmap_fleet_positions_read.sql
20260618000216_berth_model.sql"
  DOCKCOPY_HITS="$(perl -e '
    for my $f (@ARGV) {
      open my $h, "<", $f or next; local $/; my $s = <$h>;
      $s =~ s/--[^\n]*//g; $s =~ s/comment\s+on\s+\w+\s+.*?;//gsi;
      $s =~ s/\s+/ /g;
      for my $stmt (split /;/, $s) {
        # the copy PROJECTS the dock: select ... current_location_id ... from fleets (in that order).
        # A statement that merely FILTERS on current_location_id (e.g. 0199 resolving the fleet id at a
        # known port: `select id ... where ... current_location_id = v_loc.id`) is not the copy.
        next unless $stmt =~ /\bselect\b.*\bcurrent_location_id\b.*\bfrom\s+(public\.)?fleets\b/i;
        next unless $stmt =~ /\bmain_ship_id\s*=/i;
        next unless $stmt =~ /\bstatus\s*=\s*\x27present\x27/i;
        my $b = $f; $b =~ s|.*[\/\\]||; print "$b\n"; last;
      }
    }' "$REPO_ROOT"/supabase/migrations/*.sql)"
  for hit in $DOCKCOPY_HITS; do
    printf '%s\n' "$DOCKCOPY_ALLOW" | grep -qx "$hit" \
      || fail "NEW main_ship_id-keyed dock-read copy in supabase/migrations/$hit — compose mainship_resolve_docked_location / mainship_resolve_fleet instead (0211 header; 0138 is the cautionary tale)"
  done
  # guard the guard: the scanner must still detect the known alias-free copy (0072). If this fires, the
  # SCANNER went blind (regex rot), not the tree clean — a ban that detects nothing passes everything.
  printf '%s\n' "$DOCKCOPY_HITS" | grep -qx "20260618000072_port_entry_commission_normalize.sql" \
    || fail "the dock-copy scanner no longer detects 0072's known copy — the ban has gone blind"

  # ── S1 — THE BERTH MODEL (0216): the XOR schema fact + the five re-created true heads. ──────────
  # MUTATIONS (each executed statically while building — strip the construct, watch the named check
  # red, restore; the runtime reds are TRACED, CI-only — no local Docker):
  #   • drop the XOR CHECK          → the constraint grep reds; runtime BERTH_XOR's both-null/both-set
  #                                   probes "succeed" and raise.
  #   • drop the BACKFILL           → the derivation grep + order chain red; on any chain with data,
  #                                   0216's own in-file assert raises at deploy; runtime
  #                                   BERTH_BACKFILL reds on a berthless ungrouped ship.
  #   • drop assign HUNK E (berth)  → the update-clause grep reds; runtime: the first lit assign
  #                                   lands both-set → check_violation aborts ASSIGN_CLEARS_BERTH.
  #   • drop assign HUNK F (mint)   → the mint grep + order chain red; runtime ASSIGN_CLEARS_BERTH
  #                                   reds on "expected the ONE minted group fleet, found 0".
  #   • drop the unassign refusal   → the reason-form grep reds; runtime ASSIGNGUARD_UNASSIGN and
  #                                   UNASSIGN_BERTHS red on ok-instead-of-fleet_in_flight.
  #   • keep the old per-ship guard → the berth-read grep reds (and the banned old key trips);
  #                                   runtime ASSIGNGUARD_ELSEWHERE/COLOCATED drift off the berth.
  #   • drop delete HUNK C          → the order chain reds; runtime DELETE_BERTHS aborts on the FK
  #                                   SET-NULL check_violation (both-null members).
  #   • drop a creator's berth hunk → the two-creators grep reds; runtime COMMISSION_BERTHED aborts
  #                                   (the INSERT itself violates the XOR).
  #   • drop the map berthed hunk   → the gated-branch grep reds; runtime BERTH_RESOLVER phase B
  #                                   draws hidden; un-gate it → phase C draws berthed while dark.
  [ -f "$MIGRATION_S1" ] || fail "migration 0216 not found"
  # The stripped code goes into a TEMP FILE and every check READS THE FILE — never
  # `printf "$CODE" | grep -q`: under tp_init's pipefail, grep -q exits at its first match, the
  # still-writing printf takes EPIPE on a later stdio chunk, and the PIPELINE fails on a body that
  # MATCHED (CI-red / local-green — Windows pipe scheduling hides the race; the first 0216 CI run
  # died exactly here, at the XOR-CHECK grep). 0216's stripped code (~33KB) is the largest stream
  # in this arc, so it is the one that loses the race. perl -0777 slurps stdin and is immune, but
  # it reads the file too, for uniformity. The temp file is removed at the end of this section.
  MIGS1_TMP="$(mktemp)"
  sql_code "$MIGRATION_S1" > "$MIGS1_TMP"
  # the column + the XOR, and their ORDER: add column < backfill < coverage assert < add CHECK.
  grep -q "add column berth_location_id uuid null references public.locations" "$MIGS1_TMP" \
    || fail "0216 does not add the berth column (locations-FK'd, nullable)"
  grep -q "check ((group_id is null) = (berth_location_id is not null))" "$MIGS1_TMP" \
    || fail "0216's XOR CHECK is missing or does not state the mutual exclusion"
  grep -q "add constraint main_ship_instances_berth_xor_fleet" "$MIGS1_TMP" \
    || fail "0216's XOR CHECK does not carry the charter's constraint name"
  perl -0777 -ne '
    my $col   = index($_, "add column berth_location_id");
    my $bf    = index($_, "set berth_location_id = coalesce(");
    my $asrt  = index($_, "ungrouped ship(s) left berthless");
    my $chk   = index($_, "add constraint main_ship_instances_berth_xor_fleet");
    exit 1 unless $col >= 0 && $bf >= 0 && $asrt >= 0 && $chk >= 0;
    exit 1 unless $col < $bf && $bf < $asrt && $asrt < $chk;
    exit 0;' "$MIGS1_TMP" \
    || fail "0216's order broke: add-column -> backfill -> coverage-assert -> XOR CHECK (a CHECK before the backfill rejects every pre-existing ungrouped ship)"
  # the backfill derivation: most-recent 'present' corpse port, Haven fallback, ungrouped scope.
  grep -q "order by f.created_at desc" "$MIGS1_TMP" \
    || fail "0216's backfill lost the most-recent-'present' derivation (charter :292-295 shape)"
  grep -q "'b1a00001-0066-4a00-8a00-000000000001'::uuid)" "$MIGS1_TMP" \
    || fail "0216's backfill lost the Haven fallback"
  grep -q "where s.group_id is null" "$MIGS1_TMP" \
    || fail "0216's backfill is not scoped to UNGROUPED ships (grouped ships must stay berthless)"
  # exactly FIVE re-creates, and they are the five named true heads — never an md5-pinned body.
  [ "$(grep -c "create or replace function" "$MIGS1_TMP")" = "5" ] \
    || fail "0216 must contain exactly FIVE re-creates (assign / delete / build / ensure / map read)"
  for fn in "assign_ship_to_group(p_main_ship_id uuid, p_group_id uuid default null)" \
            "delete_ship_group(p_group_id uuid)" \
            "ensure_main_ship_for_player(p_player uuid)" \
            "get_my_fleet_positions()"; do
    grep -qF "create or replace function public.$fn" "$MIGS1_TMP" \
      || fail "0216 does not re-create public.$fn with its head's exact signature"
  done
  grep -q "create or replace function public.port_entry_commission_build" "$MIGS1_TMP" \
    || fail "0216 does not re-create port_entry_commission_build (its 0197 TRUE head)"
  for pinned in port_entry_commission_writer commission_first_main_ship normalize_main_ship_dock; do
    grep -q "create or replace function public.$pinned" "$MIGS1_TMP" \
      && fail "0216 re-creates the md5-PINNED port-entry body '$pinned' — the pins would be invalidated silently" || true
  done
  # §2 stays law: no per-ship mover composed anywhere in 0216.
  for banned in command_main_ship_space_move mainship_space_begin_move move_main_ship_to_location command_main_ship_space_stop; do
    grep -q "$banned" "$MIGS1_TMP" \
      && fail "0216 composes the per-ship mover '$banned' — §2 retires them, never composes them" || true
  done
  # the assign body: gated lock arms in BOTH branches survive; the guard's ship-side read is the
  # BERTH (the old per-ship key is BANNED); the S1-review arms exist — the SHIP-ROW lock (MAJOR-4),
  # the same-group short-circuit (MINOR-5), the cross-group must_unassign_first (MAJOR-1), the
  # mint's berth-legality gate (N-2) — in order: group lock -> SHIP lock -> ambiguous -> same-group
  # ok -> cross-group refusal -> in-flight -> elsewhere -> sortie -> cap -> update -> MINT (a mint
  # before the update could precede a reject; one before the cap leaks a fleet on fleet_full).
  grep -q "f.main_ship_id = v_ship" "$MIGS1_TMP" \
    && fail "0216's assign still carries the old per-ship dock pair read — the berth is the ONE ship-side authority now" || true
  grep -q "v_ship_berth = v_gf.current_location_id" "$MIGS1_TMP" \
    || fail "0216's co-location guard does not read the assignee's BERTH"
  grep -qF "'reason', 'fleet_in_flight'" "$MIGS1_TMP" \
    || fail "0216's unassign lost its fleet_in_flight refusal (reason-form; the bare token is a substring of group_fleet_in_flight)"
  grep -qF "'reason', 'must_unassign_first'" "$MIGS1_TMP" \
    || fail "0216's assign lost the cross-group must_unassign_first refusal (review MAJOR-1 — the leave-guard side door reopens)"
  # (the mint's legality gate is judged INSIDE the assign body below — a file-wide grep is
  # satisfied by the migration's own self-assert literal, the recurring grep-vacuity class.)
  # the two NEW sortie-manifest reads are LIVE-SCOPED (review MINOR-6): with the head's guard-7
  # read that is exactly THREE gsm-fleet joins carrying the live-status set.
  [ "$(grep -c "join public.fleets f on f.id = gsm.fleet_id" "$MIGS1_TMP")" = "3" ] \
    || fail "0216's sortie-manifest reads are not all live-scoped joins (a bare EXISTS lets a RETAINED dead manifest block — the 0169/0215 law)"
  perl -0777 -ne '
    my $i = index($_, "create or replace function public.assign_ship_to_group");
    exit 1 if $i < 0;
    my $j = index($_, "\$\$;", $i);
    exit 1 if $j < 0;
    my $body = substr($_, $i, $j - $i);
    exit 1 unless $body =~ /if v_unified then\s*perform 1 from public\.ship_groups where group_id = v_group and player_id = v_player for update;\s*else\s*perform 1 from public\.ship_groups where group_id = v_group and player_id = v_player for share;\s*end if;/;
    exit 1 unless $body =~ /if v_unified then\s*perform 1 from public\.ship_groups where group_id = v_cur_group and player_id = v_player for update;\s*else\s*perform 1 from public\.ship_groups where group_id = v_cur_group and player_id = v_player for share;\s*end if;/;
    my $lock  = index($body, "from public.ship_groups");
    my $slock = index($body, "main_ship_id = v_ship and player_id = v_player for update");
    my $amb   = index($body, "fleet_ambiguous");
    my $same  = index($body, "if v_cur_group = v_group then");
    my $cross = index($body, "\x27must_unassign_first\x27");
    my $infl  = index($body, "group_fleet_in_flight");
    my $elsw  = index($body, "group_fleet_elsewhere");
    my $sort  = index($body, "group_on_sortie");
    my $cap   = index($body, "fleet_full");
    my $upd   = index($body, "update public.main_ship_instances");
    my $mint  = index($body, "insert into public.fleets");
    my $pres  = index($body, "presence_create(v_player, v_mint");
    my $legal = index($body, "mainship_space_location_target_legal(v_ship_berth)");
    exit 1 unless $lock >= 0 && $slock >= 0 && $amb >= 0 && $same >= 0 && $cross >= 0 && $infl >= 0
               && $elsw >= 0 && $sort >= 0 && $cap >= 0 && $upd >= 0 && $mint >= 0 && $pres >= 0
               && $legal >= 0;
    exit 1 unless $lock < $slock && $slock < $amb && $amb < $same && $same < $cross && $cross < $infl
               && $infl < $elsw && $elsw < $sort && $sort < $cap && $cap < $upd && $upd < $mint && $mint < $pres;
    exit 1 unless $legal > $upd && $legal < $mint;
    exit 0;' "$MIGS1_TMP" \
    || fail "0216's assign body lost a gated lock branch, the ship-row lock, an S1-review arm, the mint legality gate (N-2, between update and mint), or its order (group lock -> ship lock -> ambiguous -> same-group ok -> must_unassign_first -> in-flight -> elsewhere -> sortie -> cap -> update -> mint(+presence))"
  # the XOR maintenance clause rides the ONE update.
  grep -q "berth_location_id = case when v_group is not null then null else v_berth end" "$MIGS1_TMP" \
    || fail "0216's assign update lost the XOR maintenance clause (group_id and berth must move in ONE statement)"
  # the delete body: leaf composed, consume + member-berth BEFORE the delete.
  perl -0777 -ne '
    my $i = index($_, "create or replace function public.delete_ship_group");
    exit 1 if $i < 0;
    my $j = index($_, "\$\$;", $i);
    exit 1 if $j < 0;
    my $body = substr($_, $i, $j - $i);
    my $leaf = index($body, "ship_group_resolve_fleet");
    my $cons = index($body, "set status = \x27completed\x27");
    my $bert = index($body, "update public.main_ship_instances");
    my $del  = index($body, "delete from public.ship_groups");
    exit 1 unless $leaf >= 0 && $cons >= 0 && $bert >= 0 && $del >= 0;
    exit 1 unless $leaf < $cons && $cons < $bert && $bert < $del;
    exit 0;' "$MIGS1_TMP" \
    || fail "0216's delete body lost its order (leaf -> consume -> berth-the-members -> delete) — the FK SET NULL alone is a guaranteed check_violation on every non-empty group"
  # BOTH creators carry the berth in their INSERT (creator consistency, the 0197 rule).
  [ "$(grep -c "berth_location_id)" "$MIGS1_TMP")" = "2" ] \
    || fail "0216's two ship creators do not BOTH add berth_location_id to their INSERT column lists"
  # the map read: true-head declaration, the 0211/0212 hunks survive (stale-head tripwires), the
  # berthed branch exists and is GATED, and it keys on the RESOLVER having no fleet.
  grep -q "TRUE-HEAD DECLARATION" "$MIGRATION_S1" \
    || fail "0216 does not declare itself get_my_fleet_positions' true head — the 0136 stale-head mistake repeats by default"
  grep -q "f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.status = 'present'" "$MIGS1_TMP" \
    || fail "0216's map read lost 0211's docked hunk — rebuilt from a stale head"
  grep -q "f.id = public.mainship_resolve_fleet(s.main_ship_id) and fm.status = 'moving'" "$MIGS1_TMP" \
    || fail "0216's map read lost 0212's transit hunk — rebuilt from a stale head"
  grep -q "f.id = public.mainship_resolve_fleet(s.main_ship_id) and f.location_mode = 'space'" "$MIGS1_TMP" \
    || fail "0216's map read lost 0212's fleet-first in_space hunk — rebuilt from a stale head"
  grep -q "s.space_x is not null" "$MIGS1_TMP" \
    || fail "0216's map read dropped the ship-coordinate fallback (the dark parity path dies)"
  grep -q "if v_unified and v_place = 'hidden' and s.berth_location_id is not null" "$MIGS1_TMP" \
    || fail "0216's berthed branch is missing or un-gated (rollback must keep the 0212 behavior byte-exact)"
  grep -q "and public.mainship_resolve_fleet(s.main_ship_id) is null then" "$MIGS1_TMP" \
    || fail "0216's berthed branch does not key on the RESOLVER having no fleet — a second location authority"
  # the runtime fixtures must be non-vacuous (each string is a RAISE that fires when the fixture
  # failed to reach the state its marker claims to pin).
  grep -q "the open-sortie state was not built (member off the live manifest)" "$SQL" \
    || fail "ASSIGN_CROSSGROUP does not guard that the member is really ON a LIVE manifest (the side-door probe vacuous otherwise)"
  grep -q "the member stepped off the frozen manifest" "$SQL" \
    || fail "ASSIGN_CROSSGROUP does not name its fail mode (ok on the cross-group probe = the manifest side door)"
  grep -q "never-blocked promise broke" "$SQL" \
    || fail "ASSIGN_CROSSGROUP does not pin the same-group re-assign (the 0204 :294 promise — MINOR-5)"
  grep -q "phase A would be vacuous" "$SQL" \
    || fail "BERTH_RESOLVER does not guard that the corpse-docked phase is real"
  grep -q "could be answered by the retired layer" "$SQL" \
    || fail "BERTH_RESOLVER does not guard that j1 resolves NO fleet before asserting berthed"
  grep -q "the contrast pin would be vacuous" "$SQL" \
    || fail "BERTH_RESOLVER does not guard the fleeted-ship contrast (fleeted must read the fleet)"
  grep -q "the mint port could come from the retired layer" "$SQL" \
    || fail "ASSIGN_CLEARS_BERTH does not guard that the mint's port can only come from the BERTH"
  grep -q "the docked phase would be vacuous" "$SQL" \
    || fail "UNASSIGN_BERTHS does not guard that the fleet is really docked"
  grep -q "the in-flight phase would be vacuous" "$SQL" \
    || fail "UNASSIGN_BERTHS does not guard that the fleet is really moving"
  grep -q "the flying phase would be vacuous" "$SQL" \
    || fail "DELETE_BERTHS does not guard that the fleet is really moving"
  grep -q "the docked phase would be vacuous" "$SQL" \
    || fail "DELETE_BERTHS does not guard the settled shape"
  grep -q "the accept half is vacuous" "$SQL" \
    || fail "BERTH_XOR does not guard that BOTH legal shapes exist in-world"
  grep -q "the sweep would be vacuous" "$SQL" \
    || fail "BERTH_BACKFILL does not guard that both populations exist"
  grep -q "executed only at the prod deploy" "$SQL" \
    || fail "BERTH_BACKFILL does not state the traced-vs-executed honesty (the real-data run is the deploy's)"
  rm -f "$MIGS1_TMP"

  # ── S2 — TERRITORY (0217): additive column + seed + the get_world_map PARITY re-create. ─────────
  # MUTATIONS (each executed statically while building — strip the construct, watch the named check
  # red, restore; the runtime reds are TRACED, CI-only — no local Docker):
  #   • drop the add-column          → the column grep reds; runtime: the seeding UPDATE (and the
  #                                    re-created read) error at deploy — nothing to trace.
  #   • drop the CASE seed           → the seed greps red; 0217's in-file assert raises at deploy.
  #                                    (Runtime SEEDED now pins 0220's RETUNED values — the 0220
  #                                    section below — since 0220 re-seeds over whatever 0217 left.)
  #   • drop a status='active' filter→ the filter grep + the parity diff red; 0217's in-file assert
  #                                    raises at deploy; runtime MAPREAD's structural re-pin reds
  #                                    (the 0175 pin ran against the PRE-0217 body — it cannot).
  #   • add a SECOND field / any body
  #     drift beyond the one hunk    → the byte-parity diff below reds (the whole point: PARITY
  #                                    means the 0002 head plus EXACTLY ONE added field).
  #   • drop the grant re-emit       → the grant grep reds.
  # Static checks READ THE mktemp FILE — never `printf | grep -q` (the S1 pipefail/EPIPE lesson:
  # grep -q exits at first match, the still-writing printf takes EPIPE, the pipeline fails on a
  # body that MATCHED).
  [ -f "$MIGRATION_S2" ] || fail "migration 0217 not found"
  MIGS2_TMP="$(mktemp)"
  sql_code "$MIGRATION_S2" > "$MIGS2_TMP"
  # the additive column (nullable numeric, no default surgery) + the CASE seed with the decided map.
  grep -q "alter table public.locations add column territory_radius numeric;" "$MIGS2_TMP" \
    || fail "0217 does not add locations.territory_radius (nullable numeric)"
  grep -q "set territory_radius = case location_type" "$MIGS2_TMP" \
    || fail "0217's seed is not a CASE on location_type"
  grep -q "when 'trade_outpost' then 25" "$MIGS2_TMP" || fail "0217's seed lost trade_outpost -> 25"
  grep -q "when 'pirate_hunt' then 35"   "$MIGS2_TMP" || fail "0217's seed lost pirate_hunt -> 35"
  grep -q "when 'pirate_den' then 35"    "$MIGS2_TMP" || fail "0217's seed lost pirate_den -> 35 (0 rows today; seeded for the day it gains one)"
  grep -q "when 'safe_zone' then 15"     "$MIGS2_TMP" || fail "0217's seed lost safe_zone -> 15"
  grep -q "when 'rally_point' then 15"   "$MIGS2_TMP" || fail "0217's seed lost rally_point -> 15"
  # posture: exactly ONE re-create and it is get_world_map(); exactly ONE alter table (the column);
  # no drops, no ship writes, no flag (additive data is always-on — a flag would gate nothing).
  [ "$(grep -c "create or replace function" "$MIGS2_TMP")" = "1" ] \
    || fail "0217 must contain exactly ONE re-create (the get_world_map parity copy)"
  grep -q "create or replace function public.get_world_map()" "$MIGS2_TMP" \
    || fail "0217's one re-create is not public.get_world_map()"
  [ "$(grep -c "alter table" "$MIGS2_TMP")" = "1" ] \
    || fail "0217 must contain exactly ONE alter table (the territory_radius column)"
  grep -qE "drop (function|table|column)" "$MIGS2_TMP" \
    && fail "0217 drops an existing object (S2 is purely additive)" || true
  grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" "$MIGS2_TMP" \
    && fail "0217 UPDATEs main_ship_instances — territory is world data, never a ship write" || true
  grep -qiE "(insert into|update)[[:space:]]+(public\.)?game_config" "$MIGS2_TMP" \
    && fail "0217 seeds or flips a flag (additive always-on data needs no gate)" || true
  # THE PARITY DIFF (the crown of this section): the 0217 get_world_map body must equal the 0002
  # TRUE-head body EXACTLY, minus the ONE added field — whitespace-normalized, judged on the raw
  # bodies (neither head carries comments inside the function). A second added field, a reordered
  # key, a dropped filter, or any silent drift reds here.
  perl -0777 -e '
    sub body {
      my ($f) = @_;
      open my $h, "<", $f or exit 1; local $/; my $s = <$h>;
      my $i = index($s, "create or replace function public.get_world_map()"); exit 1 if $i < 0;
      my $j = index($s, "\$\$;", $i); exit 1 if $j < 0;
      my $b = substr($s, $i, $j - $i); $b =~ s/\s+/ /g; return $b;
    }
    my $old = body($ARGV[0]);
    my $new = body($ARGV[1]);
    exit 1 unless $new =~ s/, \x27territory_radius\x27, l\.territory_radius//;
    exit($new eq $old ? 0 : 1);' "$MIGRATION_0002" "$MIGRATION_S2" \
    || fail "0217's get_world_map is NOT the 0002 head plus exactly the one territory_radius field — parity broke (drift, a second field, or a lost hunk)"
  # belt-and-braces: the three status='active' filters + the grant re-emit, named individually so a
  # red is actionable without reverse-engineering the parity diff.
  grep -qF "l.zone_id = z.id and l.status = 'active'" "$MIGS2_TMP" \
    || fail "0217's get_world_map lost the location-level status='active' filter (hidden-port leak)"
  grep -qF "z.sector_id = se.id and z.status = 'active'" "$MIGS2_TMP" \
    || fail "0217's get_world_map lost the zone-level status='active' filter (hidden-port leak)"
  grep -qF "se.status = 'active'" "$MIGS2_TMP" \
    || fail "0217's get_world_map lost the sector-level status='active' filter (hidden-port leak)"
  grep -qF "grant execute on function public.get_world_map() to anon, authenticated;" "$MIGS2_TMP" \
    || fail "0217 does not re-emit the anon/authenticated execute grant (0002:134)"
  # the header must record WHY the dormant zones.radius sibling is not reused (prose — raw file).
  grep -q "zones.radius" "$MIGRATION_S2" \
    || fail "0217's header does not explain why the dormant zones.radius sibling is not reused"
  # the runtime fixtures must be non-vacuous (each string is a RAISE that fires when the fixture
  # failed to reach the state its marker claims to pin).
  grep -q "the port probe would be vacuous" "$SQL" \
    || fail "TERRITORY_SEEDED does not guard that slag (the trade_outpost probe) exists"
  grep -q "the hostile probe would be vacuous" "$SQL" \
    || fail "TERRITORY_SEEDED does not guard that an ACTIVE hunt site exists"
  grep -q "the safe probe would be vacuous" "$SQL" \
    || fail "TERRITORY_SEEDED does not guard that a safe_zone exists"
  grep -q "the parity probe would be vacuous" "$SQL" \
    || fail "TERRITORY_MAPREAD does not guard that slag is actually IN the map read"
  grep -q "the NULL-key probe would be vacuous" "$SQL" \
    || fail "TERRITORY_MAPREAD does not guard that the NULL-territory fixture is IN the map read"
  rm -f "$MIGS2_TMP"

  # ── S2-RETUNE (0220): the audit fix — overlap-free radii sized to the MEASURED world. ───────────
  # 0217's 25/35/15 mutually engulfed the map (min inter-location distance 29.15, so 35-rings
  # contained each other's CENTERS): wrong orbit badges, mush rings, and the S4-review LOW — the
  # dock guard resolving a fleet parked AT a port to a different overlapping territory. 0220 is the
  # seed-VALUE true head: 10/12/8/NULL, every value < nearest-neighbour/2 for every member of its
  # type (tightest bound 14.58). MUTATIONS (each executed statically while building — strip the
  # construct, watch the named check red, restore; runtime reds TRACED, CI-only):
  #   • drop the retune CASE        → the value greps red; runtime TERRITORY_PASS_SEEDED reds on
  #                                   slag carrying 0217's 25.
  #   • widen a radius past a
  #     neighbour (e.g. pirate 35)  → 0220's own deploy assert raises; runtime
  #                                   TERRITORY_PASS_NOOVERLAP reds on the pair sweep.
  #   • drop the self-assert sweep  → the osn_distance / pair-sweep greps red.
  # Static checks READ THE mktemp FILE — never `printf | grep -q` (the S1 pipefail/EPIPE lesson).
  [ -f "$MIGRATION_S2R" ] || fail "migration 0220 (territory retune) not found"
  MIGS2R_TMP="$(mktemp)"
  sql_code "$MIGRATION_S2R" > "$MIGS2R_TMP"
  # the retuned CASE seed, per-type (the 0217 shape — one authority per concept, values superseded).
  grep -q "set territory_radius = case location_type" "$MIGS2R_TMP" \
    || fail "0220's retune is not a CASE on location_type"
  grep -q "when 'trade_outpost' then 10" "$MIGS2R_TMP" || fail "0220's retune lost trade_outpost -> 10"
  grep -q "when 'pirate_hunt' then 12"   "$MIGS2R_TMP" || fail "0220's retune lost pirate_hunt -> 12"
  grep -q "when 'pirate_den' then 12"    "$MIGS2R_TMP" || fail "0220's retune lost pirate_den -> 12 (0 rows today; retuned for the day it gains one)"
  grep -q "when 'safe_zone' then 8"      "$MIGS2R_TMP" || fail "0220's retune lost safe_zone -> 8"
  grep -q "when 'rally_point' then 8"    "$MIGS2R_TMP" || fail "0220's retune lost rally_point -> 8"
  # posture: ONE data UPDATE of locations and nothing else — no schema change, no function
  # re-create, no drop, no flag, no ship write (additive data riding the existing read, dark-safe).
  [ "$(grep -c "update public.locations" "$MIGS2R_TMP")" = "1" ] \
    || fail "0220 must contain exactly ONE update of public.locations (the retune seed)"
  [ "$(grep -c "create or replace function" "$MIGS2R_TMP")" = "0" ] \
    || fail "0220 re-creates a function (the retune is data-only)"
  [ "$(grep -c "alter table" "$MIGS2R_TMP")" = "0" ] \
    || fail "0220 alters a table (the retune is data-only)"
  grep -qE "drop (function|table|column|constraint)" "$MIGS2R_TMP" \
    && fail "0220 drops an existing object (the retune is data-only)" || true
  grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" "$MIGS2R_TMP" \
    && fail "0220 UPDATEs main_ship_instances — territory is world data, never a ship write" || true
  grep -qiE "(insert into|update)[[:space:]]+(public\.)?game_config" "$MIGS2R_TMP" \
    && fail "0220 seeds or flips a flag (additive data needs no gate)" || true
  # the deploy-time proof of the audit property: the pairwise disjointness sweep must compose the
  # ONE distance authority (osn_distance, 0099 — never a second formula) and must cover EVERY
  # status (hidden sites go active later).
  grep -q "osn_distance" "$MIGS2R_TMP" \
    || fail "0220's self-assert does not compose osn_distance (a second distance formula, or no overlap sweep)"
  grep -q "overlapping territory pair" "$MIGS2R_TMP" \
    || fail "0220's self-assert lost the pairwise-disjointness sweep"
  grep -q "reach another location" "$MIGS2R_TMP" \
    || fail "0220's self-assert lost the center-reach sweep (the S4-review wrong-port hazard)"
  # the header must record the measured geometry the values derive from (prose — raw file): the
  # minimum inter-location distance and the tightest nearest/2 bound.
  grep -q "29.15" "$MIGRATION_S2R" \
    || fail "0220's header does not record the measured minimum inter-location distance (29.15)"
  grep -q "14.58" "$MIGRATION_S2R" \
    || fail "0220's header does not record the tightest nearest-neighbour/2 bound (14.58)"
  # the runtime NOOVERLAP block must be non-vacuous and generic (survives future retunes).
  grep -q "the pairwise sweep would be vacuous" "$SQL" \
    || fail "TERRITORY_NOOVERLAP does not guard that at least two territory-bearing locations exist"
  grep -q "overlapping territory pair" "$SQL" \
    || fail "TERRITORY_NOOVERLAP lost the generic pair sweep (r_i + r_j must stay strictly below d)"
  grep -q "the dock guard could resolve the wrong port" "$SQL" \
    || fail "TERRITORY_NOOVERLAP lost the center-reach sweep (the S4-review wrong-port hazard)"
  rm -f "$MIGS2R_TMP"

  # ── S3 — POSITION + TERRITORY LEAVES (0218): the 3 leaves + the mover/brake PARITY fold. ────────
  # 0218 is the TRUE HEAD of BOTH the mover and the brake now (the brake checks above already aim
  # at it via MIGRATION_STOP; this section adds the leaf pins + the MOVER-body pins that used to be
  # meaningful only against 0208 — the 0211 pointer-discipline rule). Checks READ the mktemp file
  # already stripped for the brake section (same file — stripped once, judged twice).
  # MUTATIONS (each executed statically while building — strip the construct, watch the named
  # check red, restore; the runtime reds are TRACED, CI-only — no local Postgres):
  #   • drop a leaf                  → the 5-re-creates count / the signature grep reds; runtime:
  #                                    every S3_PASS_* block errors calling it.
  #   • re-inline the lerp in a host → the lerp-ABSENT body scan reds (and 0218's own self-assert
  #                                    raises at deploy); runtime MIDPOINT/AGREEMENT still green —
  #                                    which is WHY the ban is static: output-identical drift is
  #                                    invisible to output tests. That is the fold's whole point.
  #   • drop the leaf compose        → the composed-in-body scan reds + deploy self-assert raises.
  #   • make the leaf read a table   → the no-table-read scan reds (IMMUTABLE would be a lie).
  #   • drop the dissolve/gate/
  #     combat_destination hunk      → the retained-head greps red (the pins that used to live
  #                                    only against the superseded 0208 file).
  #   • drop the NOT-FOLDED ledger   → the header grep reds (the next reader "finishes the job").
  [ -f "$MIGRATION_S3" ] || fail "migration 0218 not found"
  # exactly FIVE re-creates: the 3 leaves + the mover + the brake.
  [ "$(grep -c "create or replace function" "$MIGSTOP_TMP")" = "5" ] \
    || fail "0218 must contain exactly FIVE re-creates (movement_position_at / fleet_current_position / fleet_in_territory / mover / brake)"
  grep -q "create or replace function public.movement_position_at(" "$MIGRATION_S3" \
    || fail "0218 does not mint movement_position_at (the ONE interpolation authority)"
  grep -q "create or replace function public.fleet_current_position(" "$MIGRATION_S3" \
    || fail "0218 does not mint fleet_current_position (the state dispatch)"
  grep -q "create or replace function public.fleet_in_territory(" "$MIGRATION_S3" \
    || fail "0218 does not mint fleet_in_territory (the S4 territory authority)"
  grep -q "create or replace function public.command_ship_group_go(" "$MIGRATION_S3" \
    || fail "0218 does not re-create the mover — the fold has no host"
  # the interpolation leaf is pure: sql immutable strict, and its body reads NO table (the body
  # sits between its signature and the first \$\$; a schema reference there means IMMUTABLE lies).
  perl -0777 -ne '
    my $i = index($_, "create or replace function public.movement_position_at");
    exit 1 if $i < 0;
    my $j = index($_, "\$\$;", $i);
    exit 1 if $j < 0;
    my $leaf = substr($_, $i, $j - $i);
    exit 1 unless $leaf =~ /language sql\s*\nimmutable\s*\nstrict/;
    my $b = index($leaf, "as \$\$");
    exit 1 if $b < 0;
    exit 1 if index(substr($leaf, $b), "public.") >= 0;
    exit 1 unless index($leaf, "nullif(extract(epoch from (p_arrive - p_depart)), 0)") >= 0;
    exit 0;' "$MIGSTOP_TMP" \
    || fail "0218's movement_position_at is not a pure sql IMMUTABLE STRICT leaf with the exact clamp/nullif math (or it reads a table)"
  # the territory leaf COMPOSES osn_distance (0099) — never a third distance formula — and carries
  # the client tiebreak (radius asc, id asc).
  grep -q "public.osn_distance(pos.o_x, pos.o_y, l.x, l.y) <= l.territory_radius" "$MIGSTOP_TMP" \
    || fail "0218's fleet_in_territory does not compose osn_distance against territory_radius (a third distance formula is the default outcome)"
  grep -q "order by l.territory_radius asc, l.id asc" "$MIGSTOP_TMP" \
    || fail "0218's fleet_in_territory lost the smallest-radius/lowest-id tiebreak (client territoryAt parity)"
  grep -q "sqrt" "$MIGSTOP_TMP" \
    && fail "0218 carries its own distance formula — compose public.osn_distance (0099), never a third copy" || true
  # THE FOLD, judged on each HOST BODY (not file-wide — the self-assert quotes the banned string
  # as a literal, the recurring grep-vacuity class): the leaf composed, the inline lerp ABSENT.
  for host in command_ship_group_go command_ship_group_stop; do
    perl -0777 -ne '
      my $i = index($_, "create or replace function public.'"$host"'");
      exit 1 if $i < 0;
      my $j = index($_, "\$function\$;", $i);
      exit 1 if $j < 0;
      my $body = substr($_, $i, $j - $i);
      exit 1 unless index($body, "movement_position_at") >= 0;
      exit 1 if index($body, "origin_x + (") >= 0;
      exit 0;' "$MIGSTOP_TMP" \
      || fail "0218's $host body does not compose movement_position_at, or an inline 'origin_x + (' lerp copy survives — the fold did not land"
  done
  # the MOVER head survived the parity copy — the pins that used to guard only the superseded 0208
  # file, retargeted at the body that runs: the in-body dark gate, the member-dock dissolve (the
  # ghost-dock fix), the combat-destination refusal, and NO ship write / no per-ship mover.
  perl -0777 -ne '
    my $i = index($_, "create or replace function public.command_ship_group_go");
    exit 1 if $i < 0;
    my $j = index($_, "\$function\$;", $i);
    exit 1 if $j < 0;
    my $body = substr($_, $i, $j - $i);
    exit 1 unless index($body, "cfg_bool(\x27fleet_movement_unified_enabled\x27)") >= 0;
    exit 1 unless index($body, "main_ship_id = any(v_members) and status = \x27present\x27") >= 0;
    exit 1 unless index($body, "combat_destination") >= 0;
    exit 1 unless index($body, "movement_create") >= 0;
    exit 1 unless index($body, "fleet_set_moving") >= 0;
    exit 0;' "$MIGSTOP_TMP" \
    || fail "0218's mover body lost a 0208 head pin (dark gate / member-dock dissolve / combat_destination / movement_create / fleet_set_moving) — parity broke"
  for banned in command_main_ship_space_move mainship_space_begin_move move_main_ship_to_location command_main_ship_space_stop; do
    grep -q "$banned" "$MIGSTOP_TMP" \
      && fail "0218 composes the per-ship mover '$banned' — §2 retires them, never composes them" || true
  done
  grep -qiE "(insert into|update)[[:space:]]+(public\.)?game_config" "$MIGSTOP_TMP" \
    && fail "0218 seeds or flips a flag — the fold is output-identical and needs NO flag" || true
  # pointer discipline: the true-head declaration + the deliberately-NOT-folded ledger (prose).
  grep -q "TRUE-HEAD DECLARATION" "$MIGRATION_S3" \
    || fail "0218 does not declare itself the mover+brake true head — the 0136/0211 stale-head mistake repeats by default"
  grep -q "DELIBERATELY NOT FOLDED" "$MIGRATION_S3" \
    || fail "0218 does not name the deliberately-not-folded copies (0149/0152/0155 travel_seconds family; 0064/0067 OSN family) — someone will 'finish the job'"
  # the runtime fixtures must be non-vacuous (each string is a RAISE that fires when the fixture
  # failed to reach the state its marker claims to pin).
  grep -q "the S3 leg is not status=''moving''" "$SQL" \
    || fail "S3 MIDPOINT does not guard that the seeded leg is really moving (t=0.5 asserted on nothing otherwise)"
  grep -q "S2 (0217)/retune (0220) is not on this chain" "$SQL" \
    || fail "S3 TERRITORY does not refuse an un-retuned territory_radius on slag (a chain missing S2/0220 would green vacuously)"
  grep -q "not parked in space — the territory probe" "$SQL" \
    || fail "S3 TERRITORY does not guard that the fleet really settled in open space"
  grep -q "the docked-leaf pin would be vacuous" "$SQL" \
    || fail "S3 DOCKED does not guard that the fleet really settled present at the port"
  rm -f "$MIGSTOP_TMP"

  # ── S4 — TIMED DOCKING (0219): the CHECK widen + the dock verb + the mover translate PARITY. ────
  # 0219 is the MOVER's TRUE HEAD now (the header repoint above) — the LIVE mover-body pins and the
  # byte-parity diff aim HERE; the S3 section keeps pinning the frozen 0218 file as shipped history.
  # MUTATIONS (each executed statically while building — strip the construct, watch the named check
  # red, restore; the runtime reds are TRACED, CI-only — no local Postgres):
  #   • drop 'dock' from the widen        → the widen-statement scan reds; 0219's self-assert (b)
  #                                         raises at deploy; runtime DOCKLEG_MINT dies on the CHECK.
  #   • split the widen from the dock RPC → the same-file greps red (widen + its ONLY writer land
  #                                         together, or a chain state exists with an orphan CHECK).
  #   • drop a dock-verb guard compose    → the body-scoped order chain reds; runtime GUARD_* red.
  #   • re-create the settle / add cron   → the settle/cron bans red — the model IS "the clock is
  #                                         arrive_at, the settle is the existing 30s cron".
  #   • re-create any dock consumer       → the byte-untouched pledge greps red.
  #   • drop or un-gate the translate hunk→ the gated-hunk scan reds; un-gated, runtime
  #                                         DARKPARITY_INSTANTDOCK reds (a dark go stops docking).
  #   • ANY other mover drift             → the byte-parity diff vs the 0218 head reds (the whole
  #                                         point: 0219's mover == 0218's + EXACTLY the one hunk).
  #   • drop a flag seed / radius CHECK   → the seed/CHECK greps red.
  [ -f "$MIGRATION_S4" ] || fail "migration 0219 not found"
  MIGS4_TMP="$(mktemp)"
  sql_code "$MIGRATION_S4" > "$MIGS4_TMP"
  # the widen: the re-stated CHECK carries every pre-existing mission PLUS 'dock' (a dropped legacy
  # mission would fail every live writer; judged on the widen STATEMENT, not the whole file).
  perl -0777 -ne '
    my $i = index($_, "add constraint fleet_movements_mission_type_check");
    exit 1 if $i < 0;
    my $j = index($_, ";", $i);
    exit 1 if $j < 0;
    my $stmt = substr($_, $i, $j - $i);
    for my $m (qw(hunt_pirates return_home scout reinforce mine explore trade rally dock)) {
      exit 1 unless index($stmt, "\x27$m\x27") >= 0;
    }
    exit 0;' "$MIGS4_TMP" \
    || fail "0219's mission_type widen is missing, lost a pre-existing mission, or does not add 'dock'"
  # the widen and its ONLY writer land in the SAME migration.
  grep -q "create or replace function public.command_ship_group_dock(p_group_id uuid)" "$MIGS4_TMP" \
    || fail "0219 does not mint command_ship_group_dock — the widen would land without its only 'dock' writer"
  # exactly TWO re-creates: the dock verb + the mover parity copy. NOTHING else is touched.
  [ "$(grep -c "create or replace function" "$MIGS4_TMP")" = "2" ] \
    || fail "0219 must contain exactly TWO re-creates (the dock verb + the mover parity copy)"
  # NO second settle/timer authority: the clock IS arrive_at, the settle IS process_fleet_movements.
  grep -q "cron.schedule" "$MIGS4_TMP" \
    && fail "0219 schedules a cron — S4's model is NO new timer (the existing 30s settle cron is the clock)" || true
  grep -q "create or replace function public.movement_settle_arrival" "$MIGS4_TMP" \
    && fail "0219 re-creates movement_settle_arrival — the dock leg must settle through the BYTE-UNTOUCHED location branch" || true
  # every dock consumer stays byte-untouched (the 0211/0216 heads keep running).
  for host in get_my_current_dock_services get_my_docked_store commission_first_main_ship get_my_fleet_positions mainship_resolve_docked_location mainship_resolve_fleet mainship_space_validate_context command_ship_group_stop process_fleet_movements; do
    grep -q "create or replace function public.$host" "$MIGS4_TMP" \
      && fail "0219 re-creates dock consumer/settle-path '$host' — S4 pledges every one of them byte-untouched" || true
  done
  # §2 stays law: no ship write, no per-ship mover composed.
  grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" "$MIGS4_TMP" \
    && fail "0219 UPDATEs main_ship_instances — charter §2 says a ship does not move (the settle's dock hunk writes the ship, not the dock verb)" || true
  for banned in command_main_ship_space_move mainship_space_begin_move move_main_ship_to_location command_main_ship_space_stop; do
    grep -q "$banned" "$MIGS4_TMP" \
      && fail "0219 composes the per-ship mover '$banned' — §2 retires them, never composes them" || true
  done
  # the DOCK BODY: composes the four authorities (never re-derives one) in the brake's order —
  # timed gate < unified gate < group lock < gsm join < sortie reject < 0213 leaf < parked <
  # territory leaf < its reject < the ONE dockability rule < its reject < mint < the flat clock <
  # fleet_set_moving — with the sortie guard LIVE-scoped and the 0149 transform shape intact.
  perl -0777 -ne '
    my $i = index($_, "create or replace function public.command_ship_group_dock");
    exit 1 if $i < 0;
    my $j = index($_, "\$function\$;", $i);
    exit 1 if $j < 0;
    my $body = substr($_, $i, $j - $i);
    my $tg   = index($body, "timed_docking_disabled");
    my $ug   = index($body, "unified_movement_disabled");
    my $lock = index($body, "from public.ship_groups where group_id = v_group and player_id = v_player for update");
    my $gsm  = index($body, "join public.fleets f on f.id = gsm.fleet_id");
    my $sort = index($body, "group_on_sortie");
    my $leaf = index($body, "ship_group_resolve_fleet");
    my $park = index($body, "not_parked");
    my $terr = index($body, "fleet_in_territory");
    my $nt   = index($body, "not_in_territory");
    my $leg  = index($body, "mainship_space_location_target_legal");
    my $nd   = index($body, "not_dockable");
    my $mk   = index($body, "movement_create(");
    my $sec  = index($body, "docking_seconds");
    my $sm   = index($body, "fleet_set_moving(");
    exit 1 unless $tg >= 0 && $ug >= 0 && $lock >= 0 && $gsm >= 0 && $sort >= 0 && $leaf >= 0
               && $park >= 0 && $terr >= 0 && $nt >= 0 && $leg >= 0 && $nd >= 0
               && $mk >= 0 && $sec >= 0 && $sm >= 0;
    exit 1 unless $tg < $ug && $ug < $lock && $lock < $gsm && $gsm < $sort && $sort < $leaf
               && $leaf < $park && $park < $terr && $terr < $nt && $nt < $leg && $leg < $nd
               && $nd < $mk && $mk < $sec && $sec < $sm;
    exit 1 unless $body =~ /f\.status in \(.moving., .present., .returning.\)/;
    exit 1 unless index($body, "make_interval(secs => v_secs)") >= 0;
    exit 1 unless index($body, "where id = v_movement and status = \x27moving\x27") >= 0;
    exit 0;' "$MIGS4_TMP" \
    || fail "0219's dock body lost a composed authority, its LIVE-scoped sortie guard, the 0149 flat-clock transform, or its order (timed gate -> unified gate -> group lock -> gsm guard -> leaf -> parked -> territory -> dockable -> mint -> clock -> set_moving)"
  # THE TRANSLATE HUNK, judged on the GO body: present, GATED on timed_docking_enabled, composed of
  # the ONE dockability rule, ordered inside the location branch (after combat_destination, before
  # guard 7 / member_busy), and rewriting to a coordinate leg (v_t_type/v_t_loc).
  perl -0777 -ne '
    my $i = index($_, "create or replace function public.command_ship_group_go");
    exit 1 if $i < 0;
    my $j = index($_, "\$function\$;", $i);
    exit 1 if $j < 0;
    my $body = substr($_, $i, $j - $i);
    my $cd = index($body, "combat_destination");
    my $hk = index($body, "cfg_bool(\x27timed_docking_enabled\x27)");
    my $mb = index($body, "member_busy");
    exit 1 unless $cd >= 0 && $hk >= 0 && $mb >= 0;
    exit 1 unless $cd < $hk && $hk < $mb;
    exit 1 unless $body =~ /if public\.cfg_bool\(\x27timed_docking_enabled\x27\)\s*and \(public\.mainship_space_location_target_legal\(v_loc\.id\)->>\x27ok\x27\)::boolean is true then\s*v_t_type := \x27space\x27; v_t_loc := null;\s*end if;/;
    exit 0;' "$MIGS4_TMP" \
    || fail "0219's mover lost the gated translate hunk, its ONE-dockability-rule compose, or its place in the location branch (after combat_destination, before guard 7)"
  # THE MOVER BYTE-PARITY DIFF (the crown of this section): the 0219 mover body must equal the 0218
  # TRUE-head body EXACTLY — comment-stripped, whitespace-normalized — after removing EXACTLY ONE
  # occurrence of the translate hunk. Any second delta (a reordered guard, a dropped dissolve, a
  # silent "improvement") reds here. Judged on the RAW files, stripped in-perl.
  perl -0777 -e '
    sub codebody {
      my ($f) = @_;
      open my $h, "<", $f or exit 1; local $/; my $s = <$h>;
      my $i = index($s, "create or replace function public.command_ship_group_go("); exit 1 if $i < 0;
      my $j = index($s, "\$function\$;", $i); exit 1 if $j < 0;
      my $b = substr($s, $i, $j - $i);
      $b =~ s/--[^\n]*//g;
      $b =~ s/\s+/ /g;
      return $b;
    }
    my $old = codebody($ARGV[0]);
    my $new = codebody($ARGV[1]);
    my $hunk = "if public.cfg_bool(\x27timed_docking_enabled\x27) and (public.mainship_space_location_target_legal(v_loc.id)->>\x27ok\x27)::boolean is true then v_t_type := \x27space\x27; v_t_loc := null; end if; ";
    exit 1 if index($new, $hunk) < 0;
    my $c = ($new =~ s/\Q$hunk\E//g);
    exit 1 unless $c == 1;
    exit($new eq $old ? 0 : 1);' "$MIGRATION_S3" "$MIGRATION_S4" \
    || fail "0219's mover is NOT the 0218 head plus exactly the ONE translate hunk — parity broke (a second delta, a lost hunk, or a rebuild from a stale head)"
  # the dark gate + the flat clock are seeded (on-conflict-do-nothing), and the S3-review fold landed.
  grep -q "'timed_docking_enabled'" "$MIGS4_TMP" || fail "0219 does not seed timed_docking_enabled"
  grep -q "'docking_seconds'" "$MIGS4_TMP"       || fail "0219 does not seed docking_seconds"
  grep -q "on conflict (key) do nothing" "$MIGS4_TMP" \
    || fail "0219's flag seeds are not on-conflict-do-nothing (a re-run would clobber a lit env)"
  grep -q "territory_radius is null or territory_radius > 0" "$MIGS4_TMP" \
    || fail "0219 lost the S3-review territory_radius CHECK fold (NULL-or-positive)"
  # pointer discipline: 0219 declares itself the mover's true head (prose — raw file).
  grep -q "TRUE-HEAD DECLARATION" "$MIGRATION_S4" \
    || fail "0219 does not declare itself the mover's true head — the 0136/0211 stale-head mistake repeats by default"
  # the runtime fixtures must be non-vacuous (each string is a RAISE that fires when the fixture
  # failed to reach the state its marker claims to pin) — and §2 must hold through the dock too.
  grep -q "the dark instant-dock contrast would be vacuous" "$SQL" \
    || fail "S4 DARKPARITY does not guard its fixture (seeded-false flag + a really-dockable port)"
  grep -q "the translate probe would be vacuous" "$SQL" \
    || fail "S4 TRANSLATE_PARK does not guard that the target port is really dockable"
  grep -q "the dock leg is not status" "$SQL" \
    || fail "S4 DOCKLEG_MINT does not guard that the minted dock leg is really moving"
  grep -q "not the EXACT flat 45s" "$SQL" \
    || fail "S4 DOCKLEG_MINT does not pin arrive_at - depart_at as the EXACT flat 45s (the 0149 transform's whole point)"
  grep -q "the not-in-territory probe would be vacuous" "$SQL" \
    || fail "S4 GUARD_NOTINTERRITORY does not guard that the fleet is really parked in open space outside every ring"
  grep -q "the S4 mid-combat sortie state was not built" "$SQL" \
    || fail "S4 GUARD_ONSORTIE does not guard that the sortie is really present-at-site with an open manifest"
  grep -q "no live encounter under the dock probe" "$SQL" \
    || fail "S4 GUARD_ONSORTIE does not guard that a LIVE encounter exists"
  grep -q "the not_parked probe would be vacuous" "$SQL" \
    || fail "S4 GUARD_NOTPARKED does not guard that the fleet is really docked (present) when the guard is probed"
  grep -q "the untranslated probe would be vacuous" "$SQL" \
    || fail "S4 RALLY_UNTRANSLATED does not guard that a non-dockable 'none' destination exists"
  grep -q "assert_ships_untouched('before_.*', 'after_.*', 'timed dock')" "$SQL" \
    || fail "the §2 ship-untouched assertion is not applied to: 'timed dock'"
  rm -f "$MIGS4_TMP"

  tp_assert_out_of_scope "$SQL"

  echo "FLEET-GO SELFTEST: ALL PASSED (self-rolling-back; flags in-txn only; real-RPC provisioning; dark reject-before-read; §2 no-ship-write asserted 3× with a non-vacuous both-way diff; non-vacuous redirect; independent speed fold; migration additive + composes no per-ship mover)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "FLEET-GO" "$SQL" "$PASS_LINE" "$MARKERS"
echo "FLEET-GO LOCAL PROOF: OVERALL_PASS"
