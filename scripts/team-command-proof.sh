#!/usr/bin/env bash
# TEAM-COMMAND B-VERIFY — disposable proof orchestrator for the DARK team send/stop RPC surface
# (slices 0160..0164: ship_groups + upsert/assign/delete + group send/stop) plus the Slice-C0 captain
# block (0165: get_my_group_expedition_preview — an RPC-ONLY migration with NO data change; the
# captain_slots=6 hull bump is DEFERRED to activation, so the proof applies it in-txn before its
# captain commissions. Captains are provisioned only via the 0118/0119 sole writers) plus the
# Slice-D0 teamstats block (0166: get_my_group_expedition_totals — the AUTHORITATIVE team totals;
# proven by an independent per-member sum over direct adapter calls, and strict-vs-preview) plus the
# Slice-D1 combat-parity block (0167: the re-created LIVE combat tick/report keep LEGACY byte-parity —
# tick damage equals the proof's own independent Σ(attack×alive); one combat cron; identity CHECK).
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
MARKERS="TEAMCMD_PASS_DARK TEAMCMD_PASS_WRITE TEAMCMD_PASS_CAPTAINS TEAMCMD_PASS_TEAMSTATS TEAMCMD_PASS_SEND TEAMCMD_PASS_STOP TEAMCMD_PASS_DELETE TEAMCMD_PASS_COMBATPARITY"
PASS_LINE="TEAM-COMMAND B-VERIFY PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" team_command_enabled mainship_additional_commission_enabled mainship_send_enabled captain_assignment_enabled

  # ── provisions via the REAL commission RPCs (no direct ship inserts as the primary path). ─────────
  grep -q "public.commission_first_main_ship()"      "$SQL" || fail "harness does not provision via commission_first_main_ship"
  grep -q "public.commission_additional_main_ship()" "$SQL" || fail "harness does not exercise commission_additional_main_ship"

  # ── all SEVEN team RPCs are exercised (the five B-surface RPCs + the C0 group preview + the D0
  #    authoritative totals). ──────────────────────────────────────────────────────────────────────
  for fn in upsert_ship_group assign_ship_to_group delete_ship_group send_ship_group_expedition stop_ship_group_transit get_my_group_expedition_preview get_my_group_expedition_totals; do
    grep -q "public.$fn(" "$SQL" || fail "harness does not exercise the '$fn' RPC"
  done

  # ── C0 captains are provisioned ONLY via the sole writers (0118/0119) — the mint+assign calls are
  #    present, and NO direct insert into either Captain-owned table exists anywhere in the proof. ────
  grep -q "public.captains_mint_instance("  "$SQL" || fail "harness does not mint captains via captains_mint_instance"
  grep -q "public.captain_assign_apply("    "$SQL" || fail "harness does not assign captains via captain_assign_apply"
  # NEGATIVE: no DIRECT mutation of either Captain-owned table by ANY verb (insert/update/delete/copy),
  # qualified or not — only the sole writers may touch them. Strip comment lines first so the header's
  # prose ("never a direct insert into …") can't trip it.
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -qiE '(insert into|update|delete from|copy)[[:space:]]+(public\.)?(captain_instances|ship_captain_assignments)\b' \
    && fail "harness directly mutates a Captain-owned table (sole-writer law violation)" || true

  # ── every reject token is asserted (dark gate, validation, fail-closed resolves, send outcomes). Pin the
  #    ASSERT FORM (`is distinct from '<tok>'`), not a bare token match — a bare grep would also match the
  #    SQL header comments, so a gutted .sql that only mentions the tokens in prose could false-green. ────
  for tok in team_command_disabled invalid_group_index invalid_name ship_not_found group_not_found empty_group member_send_failed invalid_activity stats_invalid; do
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

  # ── C0 capacity: the preview's captain_slots_limit=6 is asserted in assert form. 0165 is RPC-only, so
  #    the proof applies the deferred activation hull bump IN-TXN before commissioning — assert both. ──
  grep -q "captain_slots_limit')::int is distinct from 6" "$SQL" \
    || fail "harness does not ASSERT captain_slots_limit=6 (is distinct from form)"
  grep -qE "update public\.main_ship_hull_types set base_captain_slots = 6 where hull_type_id = 'starter_frigate'" "$SQL" \
    || fail "harness does not apply the deferred activation hull bump (base_captain_slots=6) in-txn"

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

  # ── all eight block PASS markers present. ───────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing block PASS marker: $m"
  done

  tp_assert_out_of_scope "$SQL"

  echo "TEAM-COMMAND B-VERIFY SELFTEST: ALL PASSED (self-rolling-back; 4 dark flags toggled only in-txn; real-RPC provisioning + sole-writer captains; 7 RPCs + all reject tokens; all-or-nothing/stop-aggregate/held/SET-NULL/captain-fold/D0-delegation/D1-combat-parity specifics)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "TEAM-COMMAND B-VERIFY" "$SQL" "$PASS_LINE" "$MARKERS"

# post-run honesty check: EVERY committed flag the proof flips must still be false (the flips were rolled
# back). Check all four the harness toggles in-txn, not just the team gate.
for flag in team_command_enabled mainship_additional_commission_enabled mainship_send_enabled captain_assignment_enabled; do
  committed="$(psql "$DB_URL" -X -t -A -c "select coalesce((select value #>> '{}' from public.game_config where key = '$flag'), 'false')")" \
    || fail "could not read the committed '$flag' value"
  [ "$committed" = "false" ] || fail "committed $flag is '$committed' — the proof leaked a flag flip (must stay false)"
done

echo "TEAM-COMMAND B-VERIFY LOCAL PROOF: OVERALL_PASS (committed team_command_enabled/mainship_additional_commission_enabled/mainship_send_enabled/captain_assignment_enabled all still false)"
