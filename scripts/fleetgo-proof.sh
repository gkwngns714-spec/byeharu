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
MIGRATION_STOP="$REPO_ROOT/supabase/migrations/20260618000209_fleetgo_unified_stop.sql"
MIGRATION_3C="$REPO_ROOT/supabase/migrations/20260618000210_fleetgo_group_read_oracle.sql"
MIGRATION_3C2="$REPO_ROOT/supabase/migrations/20260618000211_fleetgo_dock_dedup.sql"

# Strip PROSE from a migration so the static bans below judge CODE, not documentation. Two kinds of prose
# name the banned constructs on purpose — the `--` header (explaining to the next reader WHY they are
# banned) and the `comment on function ... is '...'` string literal (which is shipped documentation, not
# an executable reference). A naive grep matches both and fails the honest file; the fix is not to stop
# documenting the ban, it is to read the code. (Both traps were hit for real while writing these.)
sql_code() { perl -0777 -pe "s/--[^\n]*//g; s/comment\s+on\s+\w+\s+.*?;//gsi" "$1"; }

MARKERS="FLEETGO_PASS_DARK FLEETGO_PASS_ONEFLEET FLEETGO_PASS_NOSHIPWRITE FLEETGO_PASS_NOGHOSTDOCK FLEETGO_PASS_COMBATDEST FLEETGO_PASS_SPEEDMIN FLEETGO_PASS_REDIRECT FLEETGO_PASS_GUARDS FLEETGO_PASS_TARGETSHAPE FLEETGO_PASS_COORD FLEETGO_PASS_SPACESETTLE FLEETGO_PASS_FROMSPACE FLEETGO_PASS_SETTLEPARITY FLEETGO_PASS_STOP FLEETGO_PASS_ORACLEPARITY FLEETGO_PASS_GROUPREAD FLEETGO_PASS_DOCKDEDUP_DARKPARITY FLEETGO_PASS_DOCKDEDUP_GROUPDOCKED FLEETGO_PASS_DOCKDEDUP_COMMISSION FLEETGO_PASS_ISOLATION FLEETGO_PASS_DOCKDEDUP_HUNTOVERLAP FLEETGO_PASS_DOCKDEDUP_LEGACYPRESENT"
PASS_LINE="FLEET-GO PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" fleet_movement_unified_enabled team_command_enabled mainship_additional_commission_enabled station_storage_enabled launch_from_dock_enabled

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
  # the snapshot must actually cover every column that could carry movement.
  for col in status spatial_state space_x space_y updated_at; do
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

  # ── the fleet-level BRAKE (0209): same §2 bans, and it must not be the composed model. ──────────
  [ -f "$MIGRATION_STOP" ] || fail "migration 0209 not found"
  MIGSTOP_CODE="$(sql_code "$MIGRATION_STOP")"
  printf '%s' "$MIGSTOP_CODE" | grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" \
    && fail "0209 UPDATEs main_ship_instances — the legacy stop parks the SHIP; this must park the FLEET" || true
  # it must NOT loop the per-ship stop — that is exactly what 0164 does and what §2 replaces.
  for banned in command_main_ship_stop_transit command_main_ship_space_stop stop_ship_group_transit; do
    printf '%s' "$MIGSTOP_CODE" | grep -q "$banned" \
      && fail "0209 composes the per-ship brake '$banned' — that is the composed model §2 retires" || true
  done
  # it must REUSE 3b's parking leaf, not invent a second parking mechanism.
  printf '%s' "$MIGSTOP_CODE" | grep -q "fleet_set_in_space" \
    || fail "0209 does not compose 0208's fleet_set_in_space leaf (second parking mechanism?)"
  printf '%s' "$MIGSTOP_CODE" | grep -qE "^[[:space:]]*(alter table|drop function)" \
    && fail "0209 alters/drops an existing object (the brake must be purely additive)" || true
  # the runtime must pin that the brake and the redirect agree on where "here" is.
  grep -q "disagrees with the redirect interpolation" "$SQL" \
    || fail "no runtime pin that the brake and the redirect compute the SAME interpolated point"
  grep -q "double-stop did not report not_moving" "$SQL" \
    || fail "the brake's idempotence is not pinned (a brake that raises on a second press is a hazard)"

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
20260618000200_fleetmap_fleet_positions_read.sql"
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

  tp_assert_out_of_scope "$SQL"

  echo "FLEET-GO SELFTEST: ALL PASSED (self-rolling-back; flags in-txn only; real-RPC provisioning; dark reject-before-read; §2 no-ship-write asserted 3× with a non-vacuous both-way diff; non-vacuous redirect; independent speed fold; migration additive + composes no per-ship mover)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "FLEET-GO" "$SQL" "$PASS_LINE" "$MARKERS"
echo "FLEET-GO LOCAL PROOF: OVERALL_PASS"
