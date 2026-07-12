#!/usr/bin/env bash
# TEAM-COMMAND B-VERIFY — disposable proof orchestrator for the DARK team send/stop RPC surface
# (slices 0160..0164: ship_groups + upsert/assign/delete + group send/stop) plus the Slice-C0 captain
# block (0165: get_my_group_expedition_preview — an RPC-ONLY migration with NO data change; the
# captain_slots=6 hull bump is DEFERRED to activation, so the proof applies it in-txn before its
# captain commissions. Captains are provisioned only via the 0118/0119 sole writers) plus the
# Slice-D0 teamstats block (0166: get_my_group_expedition_totals — the AUTHORITATIVE team totals;
# proven by an independent per-member sum over direct adapter calls, and strict-vs-preview) plus the
# Slice-D1 combat-parity block (0167: the re-created LIVE combat tick/report keep LEGACY byte-parity —
# tick damage equals the proof's own independent Σ(attack×alive); one combat cron; identity CHECK)
# plus the Slice-D2 team-hunt block (0168: send_ship_group_hunt → ONE fleet + frozen sortie manifest →
# member encounter routing — snapshots equal the proof's own direct adapter calls, speed equals the
# independent D0 totals.speed, tick damage equals Σ attack_snapshot, and the manifest-wins law; the
# manifest's sole writer is the RPC — never a direct insert, grep-enforced below) plus the Slice-D3
# team-settle block (0169: the escape tick marks surviving members 'returning', the reconciler
# re-homes them ONLY once the manifest fleet is finished — mid-combat/in-transit race guards — the
# manifest is retained, defeat + repair recovery, and the M1 single-send race-closure guard) plus
# the activation-prep hull-stats block (0170: every hull row carries seeded base attack/defense —
# starter_frigate 15/10 — and the re-created adapter folds them: bare ship == hull seed exactly)
# plus the captains-launch shard-drop block (0171: the once-deferred captain-slot bump now SHIPS as
# a migration — asserted in setup, no longer fixtured in-txn — and pirate_loot_for_wave's
# config-gated captain_memory_shard drop: rate-0 byte-parity with the 0041 head, rate-1 wave-2
# drop, wave-1 threshold, and the TEAMSETTLE end-to-end carry into player_inventory) plus the
# CAPXP captain-XP-foundation block (0177: captain_xp_accrue over the TEAMSETTLE fixture — dark
# no-op with grants present, current-assignment accrual crediting the 3 assigned manifest captains
# exactly knob×1 grant each with the level-2 boundary at 100 xp, the per-(grant, captain)
# captain_counted_grants ledger + the NULL-captain orphan sentinel, zero grants unconsumed,
# grantless-ship + unassigned captains untouched, and the re-run exactly-once anti-join pin).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), toggles the dark flags ONLY inside the txn, provisions via the real commission
#              RPCs (and captains via the sole writers, never direct inserts), exercises all seven team
#              RPCs + every reject token, and asserts the all-or-nothing / stop-aggregate /
#              held-in-space / SET-NULL / captain-fold / D0-delegation specifics.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual behavior proof),
#              then verify the COMMITTED team_command_enabled flag is still 'false'.
# The shared blocks (arg scaffold / self-rolling-back / flag-inside-txn / out-of-scope / local psql+markers)
# live in scripts/lib/trade-proof-lib.sh; only this proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/team-command-proof.sql"

# the block PASS markers and the final PASS line this proof must exercise.
MARKERS="TEAMCMD_PASS_DARK TEAMCMD_PASS_HULLSTATS TEAMCMD_PASS_WRITE TEAMCMD_PASS_CAPTAINS TEAMCMD_PASS_TEAMSTATS TEAMCMD_PASS_SEND TEAMCMD_PASS_STOP TEAMCMD_PASS_DELETE TEAMCMD_PASS_COMBATPARITY TEAMCMD_PASS_TEAMHUNT TEAMCMD_PASS_SHARDDROP TEAMCMD_PASS_TEAMSETTLE TEAMCMD_PASS_CAPXP"
PASS_LINE="TEAM-COMMAND B-VERIFY PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" team_command_enabled mainship_additional_commission_enabled mainship_send_enabled captain_assignment_enabled captain_growth_enabled

  # ── provisions via the REAL commission RPCs (no direct ship inserts as the primary path). ─────────
  grep -q "public.commission_first_main_ship()"      "$SQL" || fail "harness does not provision via commission_first_main_ship"
  grep -q "public.commission_additional_main_ship()" "$SQL" || fail "harness does not exercise commission_additional_main_ship"

  # ── all EIGHT team RPCs are exercised (the five B-surface RPCs + the C0 group preview + the D0
  #    authoritative totals + the D2 combat team-send). ──────────────────────────────────────────────
  for fn in upsert_ship_group assign_ship_to_group delete_ship_group send_ship_group_expedition stop_ship_group_transit get_my_group_expedition_preview get_my_group_expedition_totals send_ship_group_hunt; do
    grep -q "public.$fn(" "$SQL" || fail "harness does not exercise the '$fn' RPC"
  done

  # ── C0 captains are provisioned ONLY via the sole writers (0118/0119) — the mint+assign calls are
  #    present, and NO direct insert into either Captain-owned table exists anywhere in the proof. ────
  grep -q "public.captains_mint_instance("  "$SQL" || fail "harness does not mint captains via captains_mint_instance"
  grep -q "public.captain_assign_apply("    "$SQL" || fail "harness does not assign captains via captain_assign_apply"
  # NEGATIVE: no DIRECT mutation of ANY Captain-owned table by ANY verb (insert/update/delete/copy),
  # qualified or not — only the sole writers may touch them (incl. the 0177 XP ledger
  # captain_counted_grants, whose sole writer is captain_xp_accrue, and captain_instances.xp/level,
  # which only the accrual may move). Strip comment lines first so the header's prose ("never a
  # direct insert into …") can't trip it.
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -qiE '(insert into|update|delete from|copy)[[:space:]]+(public\.)?(captain_instances|ship_captain_assignments|captain_counted_grants)\b' \
    && fail "harness directly mutates a Captain-owned table (sole-writer law violation)" || true

  # ── D2 (0168) sole-writer law: group_sortie_members (the sortie MANIFEST) may only be written by
  #    send_ship_group_hunt — the proof reads it (SELECT asserts) but NEVER mutates it directly, by
  #    ANY verb (the captains negative-grep convention applied to the manifest table). ────────────────
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -qiE '(insert into|update|delete from|copy)[[:space:]]+(public\.)?group_sortie_members\b' \
    && fail "harness directly mutates group_sortie_members (manifest sole-writer law violation)" || true

  # ── every reject token is asserted (dark gate, validation, fail-closed resolves, send outcomes). Pin the
  #    ASSERT FORM (`is distinct from '<tok>'`), not a bare token match — a bare grep would also match the
  #    SQL header comments, so a gutted .sql that only mentions the tokens in prose could false-green. ────
  for tok in team_command_disabled invalid_group_index invalid_name ship_not_found group_not_found empty_group member_send_failed invalid_activity stats_invalid invalid_location member_not_ready; do
    grep -q "is distinct from '$tok'" "$SQL" || fail "harness does not ASSERT the '$tok' reject (is distinct from form)"
  done

  # ── D0 (0166) delegation pin: the TEAMSTATS block must compute its OWN independent per-member sums
  #    via DIRECT calculate_expedition_stats calls and assert the totals against them (sum + min-speed
  #    forms) — a totals RPC that re-implemented stat arithmetic could not be caught by token greps. ──
  grep -qF "public.calculate_expedition_stats(uA, a1, '[]'::jsonb, 'none')" "$SQL" \
    || fail "harness does not call the adapter directly for the independent sum (delegation pin)"
  grep -qF "(r->'totals'->>sk)::numeric is distinct from (s1->>sk)::numeric + (s2->>sk)::numeric" "$SQL" \
    || fail "harness does not ASSERT totals = the independent per-member sum"
  grep -qF "least((s1->>'speed')::numeric, (s2->>'speed')::numeric)" "$SQL" \
    || fail "harness does not ASSERT totals.speed = min member speed"

  # ── 0170 hull-stats pins (activation prep): the seed VALUES and the adapter fold, in assert
  #    form — a gutted .sql that only mentions them in prose cannot false-green. ────────────────────
  grep -qF "(want attack 15 / defense 10 — the 0170 seed)" "$SQL" \
    || fail "harness does not ASSERT the 0170 starter_frigate hull seed values (15/10)"
  grep -qF "diverge from the hull seed" "$SQL" \
    || fail "harness does not ASSERT the adapter folds hull base stats (bare ship == hull seed)"

  # ── C0 capacity: the preview's captain_slots_limit=6 is asserted in assert form. Migration 0171
  #    (captains-launch prep) now SHIPS the once-deferred hull bump + instance backfill, so the
  #    harness ASSERTS the migration state instead of fixturing it — and must never write the hull
  #    table again (the retired pre-0171 fixture bump must not creep back). ─────────────────────────
  grep -q "captain_slots_limit')::int is distinct from 6" "$SQL" \
    || fail "harness does not ASSERT captain_slots_limit=6 (is distinct from form)"
  grep -qF "(want 0 — the 0171 captains-launch bump)" "$SQL" \
    || fail "harness does not ASSERT the 0171 hull bump (base_captain_slots=6 as migration state)"
  grep -qF "(want 0 — the 0171 backfill)" "$SQL" \
    || fail "harness does not ASSERT the 0171 instance backfill (no ship below its hull)"
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -qiE '(insert into|update|delete from|copy)[[:space:]]+(public\.)?main_ship_hull_types\b' \
    && fail "harness mutates main_ship_hull_types (the bump is migration 0171, never a fixture)" || true

  # ── behavior specifics: all-or-nothing send rollback; the EXACT mixed + idempotent stop aggregates;
  #    the physical held-in-open-space shape; delete's SET-NULL member un-grouping. ───────────────────
  grep -qi "all-or-nothing" "$SQL"                                    || fail "harness does not assert the all-or-nothing send rollback"
  grep -q "status in ('moving','present','returning')" "$SQL"        || fail "all-or-nothing does not assert zero active fleets for the rolled-back member"
  grep -q "'stopped')::int is distinct from 2" "$SQL"                 || fail "harness does not assert the exact mixed stop aggregate (stopped=2)"
  grep -q "'skipped')::int is distinct from 3" "$SQL"                 || fail "harness does not assert the exact idempotent double-stop aggregate (skipped=3)"
  grep -q "spatial_state = 'in_space'" "$SQL"                         || fail "harness does not assert the held-in-open-space physical shape"
  grep -qi "on delete set null" "$SQL"                                || fail "harness does not assert the delete SET-NULL member un-grouping"
  grep -q "group_id is null" "$SQL"                                   || fail "harness does not assert members are un-grouped after delete"

  # ── D1 (0167) combat-parity pins: the COMBATPARITY block must compute its OWN independent
  #    Σ(unit_types.attack × alive_count) / Σ(defense × alive_count) and ASSERT the tick's
  #    player_damage AND enemy_damage against them, and must ASSERT the no-second-engine cron count —
  #    pinned in assert form so a gutted .sql that merely mentions them in prose cannot false-green. ──
  grep -qF "select sum(ut.attack * cu.alive_count), sum(ut.defense * cu.alive_count), sum(cu.hp_current)" "$SQL" \
    || fail "harness does not compute the independent legacy attack+defense sums (D1 parity pin)"
  grep -qF "if t.player_damage is distinct from v_expected_attack then" "$SQL" \
    || fail "harness does not ASSERT tick player_damage = the independent attack sum"
  grep -qF "if t.enemy_damage is distinct from v_expected_enemy then" "$SQL" \
    || fail "harness does not ASSERT tick enemy_damage = the independent defense-curve value"
  grep -qF "from cron.job where jobname like '%combat%'" "$SQL" \
    || fail "harness does not count the combat cron jobs (no-second-engine pin)"
  grep -qF "% combat cron jobs (want exactly 1)" "$SQL" \
    || fail "harness does not ASSERT exactly one combat cron job"
  grep -qF "exception when check_violation then null; end;" "$SQL" \
    || fail "harness does not probe the combat_units exactly-one-identity CHECK"

  # ── D2 (0168) team-hunt pins, in assert form (a gutted .sql that only mentions them in prose
  #    cannot false-green): movement speed == the independent D0 totals.speed; each member's
  #    attack_snapshot == the proof's OWN direct adapter call; exactly ONE fleet per team send;
  #    encounter power_start == the independent totals.combat_power; tick damage == Σ member
  #    attack_snapshot; and the manifest-wins unassign assert. ────────────────────────────────────────
  grep -qF "speed_used is not distinct from (t->'totals'->>'speed')::double precision" "$SQL" \
    || fail "harness does not ASSERT movement speed_used = the independent D0 totals.speed"
  grep -qF "attack_snapshot  is not distinct from (s1->>'combat_power')::double precision" "$SQL" \
    || fail "harness does not ASSERT member attack_snapshot = the independent per-member adapter power"
  grep -qF "% active fleets for the team send (want exactly ONE)" "$SQL" \
    || fail "harness does not ASSERT the team send produced exactly ONE fleet"
  grep -qF "player_power_start is not distinct from (t->'totals'->>'combat_power')::double precision" "$SQL" \
    || fail "harness does not ASSERT encounter player_power_start = the independent D0 totals.combat_power"
  grep -qF "(select sum(attack_snapshot * alive_count) from public.combat_units where encounter_id = v_enc)" "$SQL" \
    || fail "harness does not ASSERT tick player_damage = the summed member attack_snapshots"
  grep -qF "manifest has % rows after unassign (want still 2)" "$SQL" \
    || fail "harness does not ASSERT the manifest-wins mid-flight-unassign pin"
  # H1 cron-safety pins: the zero-hp member send reject, the settle-succeeds-despite-a-degraded-member
  # assert (the crown jewel — a creator raise inside the cron's one-txn scan would roll back every
  # other arrival AND wedge the movement forever), and the degraded row's dead-on-arrival shape.
  grep -qF "TEAMHUNT FAIL hp-zero send" "$SQL" \
    || fail "harness does not ASSERT the zero-hp member send reject (H1 send guard)"
  grep -qF "settle did NOT succeed despite the degraded member (cron-safety pin)" "$SQL" \
    || fail "harness does not ASSERT the degraded-member settle-succeeds cron-safety pin (H1)"
  grep -qF "alive_count = 0 and attack_snapshot = 0 and defense_snapshot = 0 and hp_current = 0" "$SQL" \
    || fail "harness does not ASSERT the degraded member row shape (alive_count=0 / zero snapshots)"

  # ── D3 (0169) team-settle pins, in assert form (a gutted .sql that only mentions them in prose
  #    cannot false-green): the escape's returning-status delta (pair-shape), the reconciler re-home
  #    in the legacy write shape, BOTH reconciler race guards (mid-combat + in-transit), the manifest
  #    retention decision, the M1 hunting-reject WITHOUT a lost update, and the repair revival. ──────
  grep -qF "and status = 'returning' and spatial_state is null" "$SQL" \
    || fail "harness does not ASSERT the D3 returning-status delta (pair-shape form)"
  grep -qF "(want 2 home/legacy-shape after the reconciler)" "$SQL" \
    || fail "harness does not ASSERT the reconciler re-home (legacy write shape)"
  grep -qF "reconciler touched a mid-combat member (race guard)" "$SQL" \
    || fail "harness does not ASSERT the mid-combat reconciler race guard"
  grep -qF "reconciler yanked a returning member home mid-flight (guard breach)" "$SQL" \
    || fail "harness does not ASSERT the in-transit reconciler race guard"
  grep -qF "(want 2 retained)" "$SQL" \
    || fail "harness does not ASSERT the manifest retention decision"
  grep -qF "live single send ACCEPTED a hunting ship (M1)" "$SQL" \
    || fail "harness does not ASSERT the M1 hunting-reject pin"
  grep -qF "the rejected single send moved the hunting ship (lost update)" "$SQL" \
    || fail "harness does not ASSERT the no-lost-update half of the M1 pin"
  grep -qF "repair did not revive the destroyed member (want home @ max_hp)" "$SQL" \
    || fail "harness does not ASSERT the repair revival (recovery pin)"

  # ── 0171 shard-drop pins (captains launch), in assert form (a gutted .sql that only mentions
  #    them in prose cannot false-green): committed seed 0; rate-0 byte-parity with the 0041
  #    bundle; the knob raised via the REAL set_game_config; rate-1 wave-2 exactly-one-shard +
  #    the wave-1 threshold; and the end-to-end carry (bundle + player_inventory deposit). ─────────
  grep -qF "(want 0 — the 0171 dark seed)" "$SQL" \
    || fail "harness does not ASSERT the committed captain_shard_drop_rate seed is 0"
  grep -qF "rate-0 loot diverges from the legacy 0041 bundle" "$SQL" \
    || fail "harness does not ASSERT rate-0 byte-parity with the 0041 loot bundle"
  grep -qF "set_game_config('captain_shard_drop_rate', '1'::jsonb)" "$SQL" \
    || fail "harness does not raise the shard rate via the real set_game_config (in-txn)"
  grep -qF "(want exactly 1, qty 1)" "$SQL" \
    || fail "harness does not ASSERT the rate-1 wave-2 exactly-one-shard drop"
  grep -qF "rate-1 wave-1 loot is not scrap-only (threshold breach)" "$SQL" \
    || fail "harness does not ASSERT the wave-1 threshold holds at rate 1"
  grep -qF "won bundle carries % shard elements" "$SQL" \
    || fail "harness does not ASSERT the won encounter's bundle carries the shard (end-to-end)"
  grep -qF "carried shard not deposited to player_inventory" "$SQL" \
    || fail "harness does not ASSERT the shard deposit into player_inventory (the recruit currency)"

  # ── CAPXP (0177) pins, in assert form (a gutted .sql that only mentions them in prose cannot
  #    false-green): the accrual fn is exercised; the committed flag/knob seeds are pinned; the dark
  #    no-op envelope; the knob raised via the REAL set_game_config to the level-2 boundary; the
  #    exact knob×grants credit + the boundary level; the grantless/unassigned negatives; the
  #    per-(grant, captain) ledger shape + the orphan sentinel + full consumption; the independently
  #    recomputed curve; and the re-run exactly-once anti-join pin. ─────────────────────────────────
  grep -qF "public.captain_xp_accrue()" "$SQL" \
    || fail "harness does not exercise captain_xp_accrue"
  grep -qF "(want ''false'' — the 0177 dark seed)" "$SQL" \
    || fail "harness does not ASSERT the committed captain_growth_enabled seed is false"
  grep -qF "(want 10 — the 0177 knob seed)" "$SQL" \
    || fail "harness does not ASSERT the committed captain_xp_per_combat_grant seed is 10"
  grep -qF "CAPXP FAIL dark:" "$SQL" \
    || fail "harness does not ASSERT the dark accrual no-op envelope"
  grep -qF "dark run left % ledger row(s) (want 0)" "$SQL" \
    || fail "harness does not ASSERT the dark run wrote zero ledger rows"
  grep -qF "set_game_config('captain_xp_per_combat_grant', '100'::jsonb)" "$SQL" \
    || fail "harness does not raise the xp knob via the real set_game_config (in-txn)"
  grep -qF "(want exactly the knob 100 × 1 qualifying grant on all 3)" "$SQL" \
    || fail "harness does not ASSERT the exact knob × qualifying-grant credit"
  grep -qF "at the 100-xp boundary (want all 3 exactly 2)" "$SQL" \
    || fail "harness does not ASSERT the level-2 boundary at 100 xp"
  grep -qF "the grantless-ship captain moved (want xp 0 / level 1)" "$SQL" \
    || fail "harness does not ASSERT the grantless-ship captain gains nothing"
  grep -qF "the unassigned captain gained xp" "$SQL" \
    || fail "harness does not ASSERT the unassigned captain gains nothing"
  grep -qF "(want 3 — one per assigned manifest captain)" "$SQL" \
    || fail "harness does not ASSERT the per-(grant, captain) credit-row shape"
  grep -qF "(want 1 sentinel row — consumed, never credited)" "$SQL" \
    || fail "harness does not ASSERT the orphan NULL-captain sentinel"
  grep -qF "grants left unconsumed after the run (want 0)" "$SQL" \
    || fail "harness does not ASSERT full grant consumption (every grant examined exactly once)"
  grep -qF "level <> 1 + floor(sqrt(xp / 100.0))::integer" "$SQL" \
    || fail "harness does not RECOMPUTE the level curve independently"
  grep -qF "re-run double-counted (want all-zero envelope)" "$SQL" \
    || fail "harness does not ASSERT the re-run exactly-once anti-join pin"
  grep -qF "re-run grew the ledger to % row(s) (want still 4)" "$SQL" \
    || fail "harness does not ASSERT the ledger is unchanged by the re-run"

  # ── all thirteen block PASS markers present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing block PASS marker: $m"
  done

  tp_assert_out_of_scope "$SQL"

  echo "TEAM-COMMAND B-VERIFY SELFTEST: ALL PASSED (self-rolling-back; 5 dark flags toggled only in-txn; real-RPC provisioning + sole-writer captains + sole-writer manifest + sole-writer XP ledger; 8 RPCs + all reject tokens; 0170-hull-stats/all-or-nothing/stop-aggregate/held/SET-NULL/captain-fold/D0-delegation/D1-combat-parity/D2-team-hunt/0171-shard-drop/D3-team-settle/0177-capxp specifics; 0171 bump asserted-not-fixtured)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "TEAM-COMMAND B-VERIFY" "$SQL" "$PASS_LINE" "$MARKERS"

# post-run honesty check: EVERY committed flag the proof flips must still be false (the flips were rolled
# back). Check all five the harness toggles in-txn, not just the team gate.
for flag in team_command_enabled mainship_additional_commission_enabled mainship_send_enabled captain_assignment_enabled captain_growth_enabled; do
  committed="$(psql "$DB_URL" -X -t -A -c "select coalesce((select value #>> '{}' from public.game_config where key = '$flag'), 'false')")" \
    || fail "could not read the committed '$flag' value"
  [ "$committed" = "false" ] || fail "committed $flag is '$committed' — the proof leaked a flag flip (must stay false)"
done

# same honesty check for the shard-drop KNOB: the proof sets it to 1 in-txn (SHARDDROP/TEAMSETTLE);
# the committed value must still be the 0171 seed '0' — a leak here would silently start dropping
# shards in a dark game.
committed_rate="$(psql "$DB_URL" -X -t -A -c "select coalesce((select value #>> '{}' from public.game_config where key = 'captain_shard_drop_rate'), '0')")" \
  || fail "could not read the committed 'captain_shard_drop_rate' value"
[ "$committed_rate" = "0" ] || fail "committed captain_shard_drop_rate is '$committed_rate' — the proof leaked the knob (must stay 0)"

# same honesty check for the 0177 XP KNOB: the proof raises it to 100 in-txn (the CAPXP boundary
# test); the committed value must still be the 0177 seed '10' — a leak would silently 10× captain
# XP the moment the owner lights captain_growth_enabled.
committed_xp="$(psql "$DB_URL" -X -t -A -c "select coalesce((select value #>> '{}' from public.game_config where key = 'captain_xp_per_combat_grant'), '10')")" \
  || fail "could not read the committed 'captain_xp_per_combat_grant' value"
[ "$committed_xp" = "10" ] || fail "committed captain_xp_per_combat_grant is '$committed_xp' — the proof leaked the knob (must stay 10)"

echo "TEAM-COMMAND B-VERIFY LOCAL PROOF: OVERALL_PASS (committed team_command_enabled/mainship_additional_commission_enabled/mainship_send_enabled/captain_assignment_enabled/captain_growth_enabled all still false; captain_shard_drop_rate still 0; captain_xp_per_combat_grant still 10)"
