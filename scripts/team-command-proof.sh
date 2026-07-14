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
# grantless-ship + unassigned captains untouched, and the re-run exactly-once anti-join pin) plus
# the C2-2 captain-level-fold block (0180: the re-created adapter scales each captain's stats_json
# contribution by the DOUBLY-gated (1 + (level-1) × captain_level_bonus_per_level) multiplier —
# exact lit bonus over the level-1 baseline on the CAPXP level-2 fixture, flag-off + level-2 =
# the level-1 world exactly, flag-on + level-1 byte-identical to dark, tradeoffs level-flat) plus
# the MOD2-1 shield-line block (0183: both module gates committed-dark then in-txn-lit on a fresh
# fixture user — exact-price craft via craft_module spending to zero with the insufficient_items
# boundary + verbatim replay, fit via fit_module_to_ship, and the 0180 adapter deltas: survival
# +12 exactly (hull-only 10 → 22) and mining_yield +8 exactly, minus-key isolation both fits)
# plus the MOD2-2 Mk-II tier block (0202: autocannon_battery_mk2 attack 18 / shield_lattice_mk2
# defense 20, both slot_cost 2 — each on its own fresh fixture user since a slot-2 pair overflows
# the 3-slot frigate; exact-price craft + insufficient_items boundary; the shield fit lands survival
# +20 exactly on the else-0 arm, and the autocannon fit lands the FULL weapon tradeoff — combat_power
# +18, pirate_attention +4, speed × 0.94 exactly — the first end-to-end pin of the weapon slot_type
# tradeoff arm, minus-key isolation both fits)
# plus the SHIPYARD-0 foundation block (0185: shipyard_enabled + blueprint_fragment_drop_rate
# asserted COMMITTED-dark and never flipped; the 2 T1 hull rows + 2 recipe headers + 10 ingredient
# rows pinned exact; the blueprint faucet at its deterministic endpoints — rate-0 byte-parity with
# the 0171 head, rate-1 wave-8 exactly-one-appended-blueprint, and the w<8 / wave-1 thresholds) plus
# the SOUL-0 per-ship-traits block (0186: ship_traits_enabled committed-dark + the roll writer's
# gate-first reject, the 8-trait catalog pinned verbatim, deterministic rolls proven by INLINE
# re-derivation of the pure-hash ':soul:' salts on fresh-commissioned fixtures — both the
# veteran_frame hp_mult arm and the plain arm every run — slot distinctness, exact
# max_hp = round(base × 1.08), and idempotent-replay immutability; the harness never writes a
# Ship-Soul table directly, negative-grepped below)
# plus the TEAMMAP-1 group-tag block (0187: send_ship_group_expedition re-created from its 0163
# head with ONE marked hunk tagging the member fleets with the team's group_id — a 2-ship team
# send tags both fleets = exactly the envelope's sent[] ids with no strays, and the arrival settle
# docks both members at the port with the informational, display-only tag surviving the settle)
# plus the SHIELD-0 foundation block (0191: the shield schema foundation asserted DEPLOY-INERT —
# both regen knobs (`shield_regen_combat_pct`/`shield_regen_idle_pct`) committed '0' and NEVER
# touched, even in-txn (no consumer exists; negative-grepped below); the exact schema shape
# (3 integer default-0 columns, 2 nullable combat snapshot columns, 5 named CHECKs, the regen
# partial index); total inertness (every hull 0, every instance 0/0, every combat row shield-NULL,
# the regen predicate empty); and the mainship_sync_combat_shield leaf smoke — floor/ceiling
# clamps + in-range write exact, missing ship = zero rows, shield_le_max trips, hp/max_hp
# byte-untouched, service-role-only ACL + shield-only prosrc)
# plus the TEAMMOVE-1 group-move block (0190: move_ship_group_to_location — a DOCKED team moves
# onward as one via per-member delegation to the UNCHANGED live move_main_ship_to_location (0156
# head): mid-flight and split-port members reject member_not_ready with zero departures, a
# manufactured mid-loop presence failure proves the all-or-nothing rollback of the already-departed
# member, and the happy path re-departs the members' OWN docked fleets moving + group-tagged, then
# docks the whole team at the onward port with the tag surviving)
# plus the SOUL-1 hook+fold block (0193: the commission roll hook — a DARK commission writes zero
# trait rows, a LIT commission births exactly 2 derivation-matching traits through the real RPC,
# ensure_main_ship_for_player hooks its create branch only (a lit replay never rolls an existing
# unrolled ship) — and the adapter trait fold: dark output byte-identical to the never-rolled
# baseline despite stored rows (knob-gated read), lit totals = dark baseline + the stored traits'
# stats_json sums exactly per key with speed inside the one multiplier, hp_mult applied once at
# the commission roll and never re-scaled by the adapter; the SOUL0 block reconciled to commission
# its roll fixtures DARK before its in-txn flip and the gate re-darkened before TEAMMAP so the
# downstream SHIELD0/TEAMMOVE fixtures stay byte-identical).
# plus the SHIELD-1 engine block (0195: the tick/creator parity re-creates — the ZERO state
# (member rows exist, none carries a shield snapshot, no fought ship's instance shield ever moved;
# the earlier exact-damage blocks ran against the SHIELD-1 tick as the live parity proof) and the
# in-txn LIT arm (snapshot 40/3 carries the CURRENT pool with max frozen, knob-'0' absorb-first
# drains min(pool, damage) with the hull taking only the overflow vs an independent damage
# derivation, knob-'1' regen climbs 0→40 exactly then CAPS at max, the 0191 leaf mirrors
# round(pool) each tick, integrity + defeat stay hull-only — a fully-shielded ship dies at hull 0).
# SHIELD-1 gives shield_regen_combat_pct its consumer, so that knob joins the in-txn
# set_game_config knob idiom (raised '1', restored '0'); shield_regen_idle_pct keeps the full
# never-touch posture until SHIELD-2 builds its consumer)
# plus the DECKS-3 station-affinity block (0196: the re-created adapter scales a captain whose
# specialization matches their held station's affinity_specialization by (1 +
# station_affinity_bonus), composed at the 0180 scale sites — committed seed '0' pinned; knob-0
# totals with a gunnery-stationed matching captain = the pre-DECKS3 expectation to the byte; knob
# 0.15 in-txn = baseline + knob × the independently-derived MATCHED share exactly (composed with a
# REAL level-2 multiplier, the NULL-affinity bridge holder earning nothing); a
# medbay(mismatch)+bridge(NULL) board byte-identical lit or dark; the unstationed arm pinned
# structurally — LEFT station join + the literal-1 no-match ELSE — because no writer can produce a
# station-NULL row post-0189 and the sole-writer law forbids fixturing one).
# plus the SHIELD-2 regen-home block (0197: the out-of-combat idle regen in the re-created
# process_mainship_expeditions + the commission base_shield copy — the committed idle knob '0' at
# entry makes every earlier reconciler pass the knob-0 byte-parity witness; knob-0 zero-writes
# pinned by an updated_at sentinel (the guarded statement never fires); the lit climb exact with
# ceil pinned (knob 0.03), least-capped, full pools never rewritten; the active/retreating
# encounter-membership exclusion + the destroyed exclusion both held on REAL fixtures; and both
# real creators birth ships BORN FULL under a sanctioned surgically-raised-then-restored
# base_shield=25 hull seed. SHIELD-2 gives shield_regen_idle_pct its consumer, so the IDLE knob
# moves from the never-touch posture to the raised-and-restored-in-txn set_game_config idiom —
# exactly what SHIELD-1 did for the combat knob — and the hull-table negative grep is tightened
# (not dropped): only the `set base_shield` fixture form is permitted, with the restore required).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), toggles the dark flags ONLY inside the txn, provisions via the real commission
#              RPCs (and captains via the sole writers, never direct inserts), exercises all nine team
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
# (SOUL1 is the 21st marker, SHIELD1 the 22nd, DECKS3 the 23rd, SHIELD2 the 24th, NANGUARD the
# 25th — the both-blocks-kept reconcile routine (SHIELD-1 landed first, then DECKS-3 rebased to the
# 23rd slot, then SHIELD-2 appended as the 24th, then NANGUARD (0198) appended as the 25th), then
# NO-HOME (0199) appended as the 26th; then FLEET-CONTROL (0204) inserted before NOHOME as the 27th
# marker (NOHOME shifts to the 28th tail); then COMMAND-BUFFS (0205) appended as the 29th tail —
# the FINALE of the fleet reshape. SHIPYARD-2 (#138, merged) has its own proof file and never
# touched this pair.)
MARKERS="TEAMCMD_PASS_DARK TEAMCMD_PASS_HULLSTATS TEAMCMD_PASS_WRITE TEAMCMD_PASS_CAPTAINS TEAMCMD_PASS_TEAMSTATS TEAMCMD_PASS_SEND TEAMCMD_PASS_STOP TEAMCMD_PASS_DELETE TEAMCMD_PASS_COMBATPARITY TEAMCMD_PASS_TEAMHUNT TEAMCMD_PASS_SHARDDROP TEAMCMD_PASS_TEAMSETTLE TEAMCMD_PASS_CAPXP TEAMCMD_PASS_CAPLEVEL TEAMCMD_PASS_MOD2 TEAMCMD_PASS_MOD22 TEAMCMD_PASS_SHIPYARD0 TEAMCMD_PASS_SOUL0 TEAMCMD_PASS_TEAMMAP TEAMCMD_PASS_SHIELD0 TEAMCMD_PASS_TEAMMOVE TEAMCMD_PASS_SOUL1 TEAMCMD_PASS_SHIELD1 TEAMCMD_PASS_DECKS3 TEAMCMD_PASS_SHIELD2 TEAMCMD_PASS_NANGUARD TEAMCMD_PASS_FLEETCTRL TEAMCMD_PASS_NOHOME TEAMCMD_PASS_CMDBUFF"
PASS_LINE="TEAM-COMMAND B-VERIFY PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" team_command_enabled mainship_additional_commission_enabled mainship_send_enabled captain_assignment_enabled captain_growth_enabled module_crafting_enabled module_fitting_enabled ship_traits_enabled launch_from_dock_enabled fleet_control_enabled command_buffs_enabled

  # ── GATE-FLAG set_game_config hardening (the shipyard_enabled review-M lesson, applied to every
  #    boolean gate): tp_assert_flags_inside_txn only fences the RAW-update form, so a smuggled
  #    `set_game_config('<gate>','true')` placed after the ROLLBACK would autocommit a committed
  #    flag flip and evade it. The harness's ONLY sanctioned gate flip is the raw in-txn update —
  #    set_game_config is reserved for the numeric KNOBS (shard/xp/blueprint rates) — so ANY
  #    set_game_config touch of a gate, anywhere in the file, fails closed. ─────────────────────────
  for gate in team_command_enabled mainship_additional_commission_enabled mainship_send_enabled captain_assignment_enabled captain_growth_enabled module_crafting_enabled module_fitting_enabled ship_traits_enabled launch_from_dock_enabled fleet_control_enabled command_buffs_enabled; do
    grep -viE '^[[:space:]]*--' "$SQL" \
      | grep -q "set_game_config('$gate'" \
      && fail "harness writes the gate '$gate' via set_game_config (gates ride the raw in-txn update only)" || true
  done

  # ── provisions via the REAL commission RPCs (no direct ship inserts as the primary path). ─────────
  grep -q "public.commission_first_main_ship()"      "$SQL" || fail "harness does not provision via commission_first_main_ship"
  grep -q "public.commission_additional_main_ship()" "$SQL" || fail "harness does not exercise commission_additional_main_ship"

  # ── all NINE team RPCs are exercised (the five B-surface RPCs + the C0 group preview + the D0
  #    authoritative totals + the D2 combat team-send + the TEAMMOVE-1 docked-team group move) plus the
  #    FLEET-CONTROL (0204) command-ship setter. ─────────────────────────────────────────────────────
  for fn in upsert_ship_group assign_ship_to_group delete_ship_group send_ship_group_expedition stop_ship_group_transit get_my_group_expedition_preview get_my_group_expedition_totals send_ship_group_hunt move_ship_group_to_location set_fleet_command_ship; do
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
  for tok in team_command_disabled invalid_group_index invalid_name ship_not_found group_not_found empty_group member_send_failed invalid_activity stats_invalid invalid_location member_not_ready fleet_inactive_no_command fleet_full ship_not_in_fleet; do
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
  grep -q "captain_slots_limit')::int is distinct from 8" "$SQL" \
    || fail "harness does not ASSERT captain_slots_limit=8 (is distinct from form)"
  grep -qF "(want 0 — the ROOMS-8 6→8 bump, 0203)" "$SQL" \
    || fail "harness does not ASSERT the ROOMS-8 hull bump (base_captain_slots=8 as migration state)"
  grep -qF "(want 0 — the 0171 backfill)" "$SQL" \
    || fail "harness does not ASSERT the 0171 instance backfill (no ship below its hull)"
  # TIGHTENED (not dropped) by SHIELD-2: insert/delete/copy on the hull table still always fail;
  # the ONE sanctioned update form is the SHIELD2 block's `set base_shield` fixture surgery
  # (base_shield has no runtime writer — ACT-SHIELD is the future data path), which must ALSO
  # restore the seed to 0 (both forms required below). Every other hull update still fails.
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -qiE '(insert into|delete from|copy)[[:space:]]+(public\.)?main_ship_hull_types\b' \
    && fail "harness inserts/deletes/copies main_ship_hull_types (migration-seeded only)" || true
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -iE 'update[[:space:]]+(public\.)?main_ship_hull_types\b' \
    | grep -qviE 'set base_shield' \
    && fail "harness mutates a main_ship_hull_types column other than the sanctioned SHIELD-2 base_shield fixture (the 0171 bump law: hull stats are migrations, never fixtures)" || true
  grep -qF "update public.main_ship_hull_types set base_shield = 25 where hull_type_id = 'starter_frigate'" "$SQL" \
    || fail "harness does not arm the SHIELD-2 commission-copy fixture (base_shield = 25 surgery)"
  grep -qF "update public.main_ship_hull_types set base_shield = 0 where hull_type_id = 'starter_frigate'" "$SQL" \
    || fail "harness does not RESTORE base_shield to 0 after the commission-copy arm (the required restore)"

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

  # ── CAPLEVEL (0180 / C2-2) pins, in assert form (a gutted .sql that only mentions them in prose
  #    cannot false-green): the committed knob seed; the direct lit/dark adapter calls on the
  #    level-2 fixture; the exact-bonus compare (baseline + knob × Σ(level-1)×attack); the
  #    dark-at-level-2 absolute baseline (hull + Σ captain attack); the only-combat_power-moves
  #    isolation pin; the flag-on-at-level-1 byte-identity; and the real-bonus (never 0=0) guard. ──
  grep -qF "(want ''0.10'' — the 0180 knob seed)" "$SQL" \
    || fail "harness does not ASSERT the committed captain_level_bonus_per_level seed is 0.10"
  grep -qF "s_on := public.calculate_expedition_stats(uC, c1, '[]'::jsonb, 'none')" "$SQL" \
    || fail "harness does not call the adapter directly on the level-2 fixture (lit arm)"
  grep -qF "(s_off->>'combat_power')::numeric + round(v_knob * v_lvl, 2)" "$SQL" \
    || fail "harness does not ASSERT the exact C2-2 bonus (baseline + knob × Σ(level-1)×attack)"
  grep -qF "(want hull attack % + Σ captain attack % exactly)" "$SQL" \
    || fail "harness does not ASSERT flag-off + level-2 = the level-1 world absolute baseline"
  grep -qF "the level fold moved a non-captain-stat key" "$SQL" \
    || fail "harness does not ASSERT the fold moves ONLY the captain-contributed combat_power"
  grep -qF "flag on + level 1 diverged from its dark baseline" "$SQL" \
    || fail "harness does not ASSERT flag-on + level-1 byte-identity (the second inertness arm)"
  grep -qF "the bonus under test must be REAL (a 0=0 compare can only false-green)" "$SQL" \
    || fail "harness does not GUARD the exact-bonus pin against a zero-bonus false-green"

  # ── MOD2 (0183 / MOD2-1) pins, in assert form (a gutted .sql that only mentions them in prose
  #    cannot false-green): the committed dark seeds for BOTH module gates; the real craft + fit
  #    RPCs exercised; the exact-price spend-to-zero; the insufficient_items boundary; the exact
  #    survival +12 / mining_yield +8 adapter deltas; and BOTH minus-key isolation pins. Plus the
  #    sole-writer negatives: the harness never writes a Modules/Fitting/Inventory-owned table
  #    directly — ingredients ride reward_grant, modules ride craft_module/fit_module_to_ship. ────
  grep -qF "public.craft_module(''mod2-shield-1'', ''shield_lattice'')" "$SQL" \
    || fail "harness does not craft the shield via the real craft_module RPC"
  grep -qF "public.fit_module_to_ship(%L::uuid, %L::uuid, ''mod2-fit-1'')" "$SQL" \
    || fail "harness does not fit the shield via the real fit_module_to_ship RPC"
  grep -qF "(want ''false'' — the 0107/0183 dark seeds)" "$SQL" \
    || fail "harness does not ASSERT the committed module gate seeds are false"
  grep -qF "the recipe spend did not land the balance at 0 (exact price)" "$SQL" \
    || fail "harness does not ASSERT the exact-price spend-to-zero"
  grep -qF "(want insufficient_items — the exact-price boundary)" "$SQL" \
    || fail "harness does not ASSERT the insufficient_items boundary after the exact spend"
  grep -qF "(s0->>'survival')::numeric + 12" "$SQL" \
    || fail "harness does not ASSERT the exact survival +12 shield delta"
  grep -qF "(s1->>'mining_yield')::numeric + 8" "$SQL" \
    || fail "harness does not ASSERT the exact mining_yield +8 rig delta"
  grep -qF "the shield moved a non-defense key" "$SQL" \
    || fail "harness does not ASSERT the shield minus-key isolation pin"
  grep -qF "the rig moved a non-mining key" "$SQL" \
    || fail "harness does not ASSERT the rig minus-key isolation pin"
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -qiE '(insert into|update|delete from|copy)[[:space:]]+(public\.)?(module_instances|module_craft_receipts|ship_module_fittings|module_fitting_receipts|module_types|module_recipe_ingredients|player_inventory|inventory_ledger|reward_grants)\b' \
    && fail "harness directly mutates a Modules/Fitting/Inventory/Reward-owned table (sole-writer law violation)" || true

  # ── MOD22 (0202 / MOD2-2) pins, in assert form (a gutted .sql that only mentions them in prose
  #    cannot false-green): the exact 0202 Mk-II catalog (attack 18 / defense 20, slot_cost 2); BOTH
  #    Mk-II crafted + fitted via the real RPCs; the exact survival +20 shield delta (else-0 arm) and
  #    the FULL weapon tradeoff arm — combat_power +18, pirate_attention +4, the biting speed penalty
  #    — plus both isolation pins. The sole-writer negative is the shared grep above (whole file). ──
  grep -qF "public.craft_module(''mod22-shield-1'', ''shield_lattice_mk2'')" "$SQL" \
    || fail "harness does not craft the Mk-II shield via the real craft_module RPC"
  grep -qF "public.craft_module(''mod22-auto-1'', ''autocannon_battery_mk2'')" "$SQL" \
    || fail "harness does not craft the Mk-II autocannon via the real craft_module RPC"
  grep -qF "public.fit_module_to_ship(%L::uuid, %L::uuid, ''mod22-fit-a'')" "$SQL" \
    || fail "harness does not fit the Mk-II autocannon via the real fit_module_to_ship RPC"
  grep -qF "% of 2 Mk-II module rows carry the exact 0202 seed shape" "$SQL" \
    || fail "harness does not ASSERT the exact 0202 Mk-II catalog (attack 18 / defense 20, slot_cost 2)"
  grep -qF "(s0->>'survival')::numeric + 20" "$SQL" \
    || fail "harness does not ASSERT the exact survival +20 Mk-II shield delta"
  grep -qF "(s0->>'combat_power')::numeric + 18" "$SQL" \
    || fail "harness does not ASSERT the exact combat_power +18 Mk-II autocannon delta"
  grep -qF "(s0->>'pirate_attention')::numeric + 4" "$SQL" \
    || fail "harness does not ASSERT the exact pirate_attention +4 weapon tradeoff (2 × slot_cost 2)"
  grep -qF "v_base_speed * (1 - 0.06)" "$SQL" \
    || fail "harness does not ASSERT the exact slot-2 weapon speed penalty (× 0.94)"
  grep -qF "the weapon speed penalty did not bite" "$SQL" \
    || fail "harness does not GUARD the speed penalty against a 0-penalty false-green"
  grep -qF "the Mk-II shield moved a non-defense key" "$SQL" \
    || fail "harness does not ASSERT the Mk-II shield minus-key isolation pin"
  grep -qF "the Mk-II autocannon moved a key outside {combat_power, pirate_attention, speed, slots}" "$SQL" \
    || fail "harness does not ASSERT the Mk-II autocannon minus-key isolation pin (the weapon tradeoff set)"

  # ── SHIPYARD0 (0185 / SHIPYARD-0) pins, in assert form (a gutted .sql that only mentions them in
  #    prose cannot false-green): BOTH committed dark seeds (the flag is never flipped, even in-txn
  #    — no shipyard RPC exists); the exact T1 hull/recipe catalog pins; the blueprint faucet's
  #    rate-0 parity, the real set_game_config raise, the rate-1 wave-8 exactly-one-blueprint +
  #    appended-last + additive-only pins, and BOTH thresholds (w<8 and the deterministic wave 1).
  #    Plus the catalog sole-writer negatives: the harness never mutates the two Reference/Config
  #    recipe tables (migration-seeded only — the main_ship_hull_types negative-grep convention).
  grep -qF "(want ''false'' — the 0185 dark seed)" "$SQL" \
    || fail "harness does not ASSERT the committed shipyard_enabled seed is false"
  grep -qF "(want 0 — the 0185 faucet seed)" "$SQL" \
    || fail "harness does not ASSERT the committed blueprint_fragment_drop_rate seed is 0"
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -qE "set value='true'::jsonb where key='shipyard_enabled'" \
    && fail "harness flips shipyard_enabled (must stay dark even in-txn — no shipyard RPC exists to exercise)" || true
  # review M (2026-07-12): ALSO catch the set_game_config idiom — the raw-update grep alone
  # was mutation-evadable (a perform set_game_config('shipyard_enabled','true') would pass).
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -q "set_game_config('shipyard_enabled'" \
    && fail "harness flips shipyard_enabled via set_game_config (must never be flipped, even in-txn)" || true
  grep -qF "% of 2 T1 hull rows carry the exact 0185 seed" "$SQL" \
    || fail "harness does not ASSERT the exact 0185 T1 hull catalog (stats + display names)"
  grep -qF "% of 2 recipe header rows carry the exact 0185 seed" "$SQL" \
    || fail "harness does not ASSERT the exact 0185 recipe headers (credits/build_seconds/NULL gates)"
  grep -qF "% of 10 ingredient rows carry the exact 0185 seed" "$SQL" \
    || fail "harness does not ASSERT the exact 0185 ingredient rows"
  grep -qF "(want exactly 10 — no strays)" "$SQL" \
    || fail "harness does not ASSERT the stray-free ingredient count"
  grep -qF "rate-0 wave-8 bundle diverges from the 0171 head output" "$SQL" \
    || fail "harness does not ASSERT rate-0 byte-parity with the 0171 loot bundle (wave 8)"
  grep -qF "set_game_config('blueprint_fragment_drop_rate', '1'::jsonb)" "$SQL" \
    || fail "harness does not raise the blueprint rate via the real set_game_config (in-txn)"
  grep -qF "(want exactly 1 blueprint, qty 1)" "$SQL" \
    || fail "harness does not ASSERT the rate-1 wave-8 exactly-one-blueprint drop"
  grep -qF "the blueprint is not appended after every 0171 element" "$SQL" \
    || fail "harness does not ASSERT the blueprint is appended last (additive-only order)"
  grep -qF "rate-1 wave-8 bundle minus the blueprint is not the 0171 bundle" "$SQL" \
    || fail "harness does not ASSERT the additive-only (bundle minus blueprint) pin"
  grep -qF "rate-1 wave-7 loot carries a blueprint (w>=8 threshold breach)" "$SQL" \
    || fail "harness does not ASSERT the w<8 threshold holds at rate 1"
  grep -qF "wave-1 loot is not scrap-only with both knobs at 1" "$SQL" \
    || fail "harness does not ASSERT wave 1 stays scrap-only with both knobs raised"
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -qiE '(insert into|update|delete from|copy)[[:space:]]+(public\.)?(hull_build_recipes|hull_recipe_ingredients)\b' \
    && fail "harness directly mutates a hull-recipe Reference/Config table (migration-seeded only)" || true

  # ── SOUL0 (0186 / SOUL-0) pins, in assert form (a gutted .sql that only mentions them in prose
  #    cannot false-green): the committed dark seed + the gate-first reject; the verbatim 8-trait
  #    catalog pin; the INLINE hash re-derivation (the exact salt/technique tokens) and the
  #    rolled-equals-derived assert; slot distinctness; the exact veteran_frame hp_mult; the
  #    idempotent-replay immutability trio (inserted 0 / no trait change / no hp re-raise). Plus
  #    the sole-writer negative: the harness NEVER writes a Ship-Soul table directly — traits
  #    exist only through the real soul_roll_traits_for_ship writer. ────────────────────────────────
  grep -qF "public.soul_roll_traits_for_ship(" "$SQL" \
    || fail "harness does not exercise the SOUL-0 roll writer"
  grep -qF "(want ''false'' — the 0186 dark seed)" "$SQL" \
    || fail "harness does not ASSERT the committed ship_traits_enabled seed is false"
  grep -qF "SOUL0 FAIL dark:" "$SQL" \
    || fail "harness does not ASSERT the dark gate-first reject on the roll writer"
  grep -qF "(want 8 traits exact — the 0186 catalog verbatim)" "$SQL" \
    || fail "harness does not pin the 0186 trait catalog verbatim"
  grep -qF "hashtextextended(p_ship::text || ':soul:1', 0)" "$SQL" \
    || fail "harness does not re-derive the trait hash inline (the determinism pin)"
  grep -qF 'order by trait_type_id collate "C"' "$SQL" \
    || fail "harness re-derivation is not collate-\"C\"-pinned (the derivation-order collation law)"
  grep -qF "the roll is not the pinned pure function" "$SQL" \
    || fail "harness does not ASSERT rolled traits = the inline re-derivation"
  grep -qF "the replay envelope does not report the STORED roll" "$SQL" \
    || fail "harness does not ASSERT the replay envelope reports the stored roll (traits + real hp_mult)"
  grep -qF "distinctness breach" "$SQL" \
    || fail "harness does not ASSERT slot-1/slot-2 distinctness"
  grep -qF "— the hp_mult exactly)" "$SQL" \
    || fail "harness does not ASSERT the exact veteran_frame hp_mult application"
  grep -qF "(want inserted 0 — the idempotent replay)" "$SQL" \
    || fail "harness does not ASSERT the second-roll idempotent replay"
  grep -qF "re-roll breach" "$SQL" \
    || fail "harness does not ASSERT the second roll changes no rolled trait"
  grep -qF "hp applies once" "$SQL" \
    || fail "harness does not ASSERT the second roll cannot re-raise max_hp"
  grep -qF "a plain (mult-1.0) roll moved hp/max_hp" "$SQL" \
    || fail "harness does not ASSERT the plain arm leaves hp/max_hp untouched"
  grep -viE '^[[:space:]]*--' "$SQL" \
    | grep -qiE '(insert into|update|delete from|copy)[[:space:]]+(public\.)?(ship_trait_types|main_ship_traits)\b' \
    && fail "harness directly mutates a Ship-Soul-owned table (sole-writer law violation)" || true

  # ── TEAMMAP (0187 / TEAMMAP-1) pins, in assert form (a gutted .sql that only mentions them in
  #    prose cannot false-green): the group-tag hunk assert (member fleets carry the team's
  #    group_id), the envelope-exactness assert (tagged set = the sent[] fleet ids), the no-strays
  #    assert, the arrival-dock assert (0153 dock shape), and the tag-survives-the-settle assert
  #    (the map's docked-team badge read). ─────────────────────────────────────────────────────────
  grep -qF "(want 2 — the 0187 tag hunk)" "$SQL" \
    || fail "harness does not ASSERT the 0187 group-tag hunk (member fleets carry group_id)"
  grep -qF "tagged fleets are not exactly the envelope" "$SQL" \
    || fail "harness does not ASSERT the tagged set = the envelope's sent[] fleet ids"
  grep -qF "(want exactly the 2 member fleets — no strays)" "$SQL" \
    || fail "harness does not ASSERT the no-stray-tags pin"
  grep -qF "(want 2 — the 0153 dock write)" "$SQL" \
    || fail "harness does not ASSERT arrival docks both members (0153 stationary/at_location)"
  grep -qF "(want 2 — the docked-team badge read)" "$SQL" \
    || fail "harness does not ASSERT the tag survives the settle (present member fleets at the port)"

  # ── SHIELD0 (0191 / SHIELD-0) pins, in assert form (a gutted .sql that only mentions them in
  #    prose cannot false-green): BOTH committed knob seeds (never raised, even in-txn — no
  #    consumer exists; negative-grepped below, the shipyard_enabled posture applied to KNOBS);
  #    the exact schema-shape pins; the total-inertness pins; the leaf smoke (floor/ceiling/
  #    in-range clamps, missing-ship zero rows, the shield_le_max CHECK probe) and the
  #    one-leaf-one-concern hp-untouched pin + the shield-only prosrc pin. ───────────────────────
  grep -qF "(want ''0'' — the 0191 dark seeds)" "$SQL" \
    || fail "harness does not ASSERT the committed shield regen knob seeds are '0'"
  for knob in shield_regen_combat_pct shield_regen_idle_pct; do
    grep -qF "key = '$knob'" "$SQL" \
      || fail "harness does not read the committed '$knob' value"
    # NEITHER knob may ever ride the raw-update idiom (that form is reserved for the boolean
    # gates; knobs ride set_game_config — the SHARDDROP/CAPXP/SHIPYARD0 convention).
    grep -viE '^[[:space:]]*--' "$SQL" \
      | grep -qE "update public\.game_config set .* where key='$knob'" \
      && fail "harness writes the shield knob '$knob' via a raw update (knobs ride set_game_config only)" || true
  done
  # SHIELD-1 reconcile (0195): the COMBAT knob HAS a consumer (the tick), so the SHIELD1 block
  # raises it in-txn via the real set_game_config — required below with its restore.
  # SHIELD-2 reconcile (0197): the IDLE knob now HAS its consumer too (the reconciler's regen
  # home), so it moves from the never-touch posture to the SAME raised-and-restored-in-txn idiom
  # (required in the SHIELD2 pin section below; the committed-'0' honesty check after the local
  # run still holds — the raise is in-txn only).
  grep -qF "public.mainship_sync_combat_shield(" "$SQL" \
    || fail "harness does not exercise the SHIELD-0 sync leaf"
  grep -qF "% of 3 shield columns carry integer/not-null/default-0" "$SQL" \
    || fail "harness does not ASSERT the 3 default-0 shield columns (the 0191 shape)"
  grep -qF "% of 2 combat snapshot columns are nullable double precision, no default" "$SQL" \
    || fail "harness does not ASSERT the 2 nullable combat shield snapshot columns"
  grep -qF "% of 5 named shield CHECKs present" "$SQL" \
    || fail "harness does not ASSERT the 5 named shield CHECKs (incl. the member-only pairing)"
  grep -qF "(want 0 — every hull base_shield 0)" "$SQL" \
    || fail "harness does not ASSERT every hull base_shield is 0 (inertness)"
  grep -qF "(want 0 — every instance at 0/0)" "$SQL" \
    || fail "harness does not ASSERT every instance is at shield 0/0 (inertness)"
  grep -qF "(want 0 — every combat row shield-NULL)" "$SQL" \
    || fail "harness does not ASSERT every combat row carries NULL shields (inertness)"
  grep -qF "(want 0 — nothing to regenerate while 0/0)" "$SQL" \
    || fail "harness does not ASSERT the regen partial-index predicate matches zero rows"
  grep -qF "(want 0 — the floor clamp)" "$SQL" \
    || fail "harness does not ASSERT the leaf's greatest(0,...) floor clamp"
  grep -qF "(want 50 — the max_shield ceiling clamp)" "$SQL" \
    || fail "harness does not ASSERT the leaf's least(max_shield,...) ceiling clamp"
  grep -qF "(want 30 — the in-range write)" "$SQL" \
    || fail "harness does not ASSERT the leaf's exact in-range write"
  grep -qF "(want zero-rows semantics)" "$SQL" \
    || fail "harness does not ASSERT the missing-ship zero-rows semantics"
  grep -qF "did not trip shield_le_max" "$SQL" \
    || fail "harness does not probe the shield_le_max CHECK"
  grep -qF "the shield leaf moved hp/max_hp (one leaf one concern breach)" "$SQL" \
    || fail "harness does not ASSERT hp/max_hp are byte-untouched by the shield leaf"
  grep -qF "the shield leaf body mentions hp (one leaf one concern breach)" "$SQL" \
    || fail "harness does not PIN the leaf's shield-only prosrc (no hp token)"

  # ── TEAMMOVE (0190 / TEAMMOVE-1) pins, in assert form (a gutted .sql that only mentions them in
  #    prose cannot false-green): the mid-flight and split-port member_not_ready rejects (each with
  #    its zero-departures half), the all-or-nothing rollback (member_send_failed pinned to the
  #    mid-loop presence raise + zero moving fleets + both fleets still docked), the happy-path
  #    present-departure envelopes over the members' OWN fleets, the moving + group-tagged departure
  #    with the no-strays pin, and the onward dock with the tag surviving. ───────────────────────────
  grep -qF "TEAMMOVE FAIL not-docked reject" "$SQL" \
    || fail "harness does not ASSERT the mid-flight-member member_not_ready reject"
  grep -qF "the not-docked reject departed t1" "$SQL" \
    || fail "harness does not ASSERT zero departures on the not-docked reject"
  grep -qF "TEAMMOVE FAIL mixed-location reject" "$SQL" \
    || fail "harness does not ASSERT the split-port-team member_not_ready reject"
  grep -qF "the mixed-location reject departed a member" "$SQL" \
    || fail "harness does not ASSERT zero departures on the mixed-location reject"
  grep -qF "all-or-nothing detail not pinned to t2''s presence raise" "$SQL" \
    || fail "harness does not PIN the all-or-nothing abort to the mid-loop member raise"
  grep -qF "(want 0 — the TEAMMOVE all-or-nothing rollback)" "$SQL" \
    || fail "harness does not ASSERT zero moving fleets after the aborted team move"
  grep -qF "(want 2 — the departed member must be rolled back)" "$SQL" \
    || fail "harness does not ASSERT both fleets still docked after the aborted team move"
  grep -qF "present-departure envelopes from Slagworks to Driftmarch (want 2)" "$SQL" \
    || fail "harness does not ASSERT the 0156 present-departure envelope shape"
  grep -qF "are not the members'' own docked fleets" "$SQL" \
    || fail "harness does not ASSERT the wrapper re-departs the members' OWN fleets (composes, never re-creates)"
  grep -qF "(want 2 — the TEAMMOVE group departure)" "$SQL" \
    || fail "harness does not ASSERT all members traveling with group-tagged fleets"
  grep -qF "(want 2 — the team docked at Driftmarch)" "$SQL" \
    || fail "harness does not ASSERT the onward arrival docks the team (0153 pair)"
  grep -qF "(want 2 — the moved team present at Driftmarch, tag surviving)" "$SQL" \
    || fail "harness does not ASSERT the tag survives the onward settle"

  # ── SOUL1 (0193 / SOUL-1) pins, in assert form (a gutted .sql that only mentions them in prose
  #    cannot false-green): the dark-commission zero-roll (the call-site gate); the dark-parity
  #    byte-identity despite stored rows (the knob-gated read); the lit fold exactness against the
  #    independent stored-rows × catalog sums + the 0=0 false-green guard + the exact speed formula
  #    + the non-stat-key isolation; the lit-commission hook (exactly 2 rows = the inline
  #    derivation); the hp_mult once-at-roll + never-re-scaled pair; and the ensure hooks (create
  #    WITH soul lit, the create-branch replay law, the empty-loop inert arm). The Ship-Soul
  #    sole-writer negative grep above already covers this block (reads only; rolls ride the real
  #    writer/RPCs). ────────────────────────────────────────────────────────────────────────────
  grep -qF "dark commission rolled traits (hook gate breach)" "$SQL" \
    || fail "harness does not ASSERT the dark commission writes zero trait rows (the call-site gate)"
  grep -qF "rolled rows must be invisible while dark" "$SQL" \
    || fail "harness does not ASSERT dark adapter byte-identity despite stored trait rows (the knob-gated read)"
  grep -qF "the trait fold under test must be REAL (a 0=0 compare can only false-green)" "$SQL" \
    || fail "harness does not GUARD the trait-fold exactness pin against an all-zero false-green"
  grep -qF "the exact trait fold: dark baseline + the stored traits'' stats_json" "$SQL" \
    || fail "harness does not ASSERT the lit fold = dark baseline + the independent stored-trait sums"
  grep -qF "round(greatest(0.2, v_base_speed * (1 + t_spd)), 3)" "$SQL" \
    || fail "harness does not ASSERT the exact trait speed formula (inside the ONE multiplier)"
  grep -qF "the trait fold moved a non-stat key" "$SQL" \
    || fail "harness does not ASSERT the trait-fold non-stat-key isolation"
  grep -qF "(want exactly 2 — the SOUL-1 commission hook)" "$SQL" \
    || fail "harness does not ASSERT the lit commission births exactly 2 trait rows"
  grep -qF "the hook did not land the derivation" "$SQL" \
    || fail "harness does not ASSERT the hook-rolled traits = the inline re-derivation"
  grep -qF "hp_mult applied ONCE at the commission roll" "$SQL" \
    || fail "harness does not ASSERT hp_mult lands once at the commission roll (max_hp = round(base × mult))"
  grep -qF "the adapter re-scaled max_hp (hp_mult double-application)" "$SQL" \
    || fail "harness does not ASSERT the adapter never re-scales max_hp (non-double-application)"
  grep -qF "(want exactly 2 — the ensure hook: starter ships get souls)" "$SQL" \
    || fail "harness does not ASSERT the ensure creator hooks (starter ships get souls)"
  grep -qF "an existing unrolled ship must NOT get rolled by the ensure replay" "$SQL" \
    || fail "harness does not ASSERT the ensure create-branch replay law (no retroactive roll)"
  grep -qF "the empty-loop inert arm must be byte-identical" "$SQL" \
    || fail "harness does not ASSERT the lit + zero-rows empty-loop inert arm"
  # ── SHIELD1 (0195 / SHIELD-1) pins, in assert form (a gutted .sql that only mentions them in
  #    prose cannot false-green): the zero state (non-vacuous member-row precondition; no snapshot
  #    on any pre-lit member row; the leaf never fired for a NULL pool); the lit-arm exacts (the
  #    40/3 CURRENT-pool snapshot, the absorb + overflow arithmetic vs the independent derivation,
  #    the regen climb + the max cap, the leaf mirror, hull-only integrity at a nonzero pool, the
  #    hull-only defeat + D1 terminal); the degeneracy guard; and the combat knob's in-txn
  #    raise-and-restore via the real set_game_config. ───────────────────────────────────────────
  grep -qF "no member combat rows exist to zero-state-check" "$SQL" \
    || fail "harness does not GUARD the zero-state arm against vacuous green (member rows must exist)"
  grep -qF "the SHIELD-1 zero state: no shield snapshot on any pre-lit member row" "$SQL" \
    || fail "harness does not ASSERT the zero state (no shield snapshot on any pre-lit member row)"
  grep -qF "the leaf must never fire for NULL pools" "$SQL" \
    || fail "harness does not ASSERT the leaf never fires for a NULL pool (write-count parity)"
  grep -qF "(want 40/3 — max frozen, CURRENT pool carried)" "$SQL" \
    || fail "harness does not ASSERT the encounter snapshot carries the CURRENT pool (40/3)"
  grep -qF "integrity accounting must stay hull-only" "$SQL" \
    || fail "harness does not ASSERT player_integrity_max excludes the shield pool"
  grep -qF "the pool drops by min(pool, damage) exactly" "$SQL" \
    || fail "harness does not ASSERT the absorb-first arithmetic (min(pool, damage))"
  grep -qF "the hull takes ONLY the overflow" "$SQL" \
    || fail "harness does not ASSERT the hull takes only the absorb overflow"
  grep -qF "the pool climbs by max_shield" "$SQL" \
    || fail "harness does not ASSERT the knob-driven regen climb"
  grep -qF "regen must cap at max_shield, never overshoot" "$SQL" \
    || fail "harness does not ASSERT the regen cap at max_shield"
  grep -qF "the leaf did not mirror round(pool) to the ship row" "$SQL" \
    || fail "harness does not ASSERT the 0191 leaf mirrors the pool to the ship row"
  grep -qF "hull-only, the shield pool is NOT integrity" "$SQL" \
    || fail "harness does not ASSERT tick integrity stays hull-only at a nonzero pool"
  grep -qF "a shielded ship at hull 0 must be dead (defeat is hull-only" "$SQL" \
    || fail "harness does not ASSERT hull-only defeat (a shielded ship at hull 0 is dead)"
  grep -qF "the D1 destroyed terminal did not fire on the shielded member" "$SQL" \
    || fail "harness does not ASSERT the D1 destroyed terminal on the shielded member"
  grep -qF "the absorb/cap pins would degenerate" "$SQL" \
    || fail "harness does not GUARD the lit-arm damage window (3 < damage < 40)"
  grep -qF "set_game_config('shield_regen_combat_pct', '1'::jsonb)" "$SQL" \
    || fail "harness does not raise the combat regen knob via the real set_game_config (in-txn)"
  grep -qF "set_game_config('shield_regen_combat_pct', '0'::jsonb)" "$SQL" \
    || fail "harness does not restore the combat regen knob to the dark seed in-txn"

  # ── DECKS3 (0196 / DECKS-3) pins, in assert form (a gutted .sql that only mentions them in
  #    prose cannot false-green): the committed knob seed '0'; the knob-0 parity assert (the
  #    pre-DECKS3 expectation with a stationed MATCHING captain aboard); the real set_game_config
  #    knob raise to 0.15 in-txn; the matched-share 0=0 guard AND the matched<full guard (the
  #    bridge-earns-nothing half must be testable); the exact-bonus assert; the isolation pin; the
  #    explicit-station mismatch fixture riding the REAL sole writer; the mismatch/bridge
  #    byte-identity; and the structural unstationed pins (LEFT join + the literal-1 ELSE). The
  #    knob is a numeric KNOB (the SHARDDROP/CAPXP posture), never a gate — its committed-'0'
  #    honesty check runs in local mode below. ─────────────────────────────────────────────────────
  grep -qF "(want ''0'' — the 0196 affinity seed)" "$SQL" \
    || fail "harness does not ASSERT the committed station_affinity_bonus seed is '0'"
  grep -qF "diverged from the pre-DECKS3 expectation" "$SQL" \
    || fail "harness does not ASSERT knob-0 byte-parity (the pre-DECKS3 expectation with a stationed matching captain)"
  grep -qF "set_game_config('station_affinity_bonus', '0.15'::jsonb)" "$SQL" \
    || fail "harness does not raise the affinity knob via the real set_game_config (in-txn)"
  grep -qF "the matched share under test must be REAL (a 0=0 compare can only false-green)" "$SQL" \
    || fail "harness does not GUARD the matched share against a zero-share false-green"
  grep -qF "a NON-matching captain must be aboard (bridge affinity NULL)" "$SQL" \
    || fail "harness does not GUARD that a NULL-affinity holder is aboard (the bridge-earns-nothing half)"
  grep -qF "the exact DECKS-3 affinity bonus" "$SQL" \
    || fail "harness does not ASSERT the exact affinity bonus (baseline + knob × the matched share, composed with the level fold)"
  grep -qF "the affinity fold moved a non-captain-stat key" "$SQL" \
    || fail "harness does not ASSERT the affinity fold moves ONLY the captain-contributed combat_power"
  grep -qF "public.captain_assign_apply(uX, capm, x1, 'medbay')" "$SQL" \
    || fail "harness does not station the mismatch captain explicitly via the real sole writer"
  grep -qF "mismatched/bridge captains must stay" "$SQL" \
    || fail "harness does not ASSERT the no-match absolute baseline (hull + Σ attack exactly, knob lit)"
  grep -qF "must be byte-identical — no match anywhere on board" "$SQL" \
    || fail "harness does not ASSERT the mismatch/bridge board is byte-identical lit or dark"
  grep -qF "an unstationed captain would be DROPPED from the fold" "$SQL" \
    || fail "harness does not PIN the LEFT station join (the structural unstationed arm)"
  grep -qF "must fall to the literal-1 ELSE" "$SQL" \
    || fail "harness does not PIN the literal-1 no-match ELSE (NULL affinity can never reach the knob arm)"

  # ── SHIELD2 (0197 / SHIELD-2) pins, in assert form (a gutted .sql that only mentions them in
  #    prose cannot false-green): the committed-'0' entry pin (the byte-parity witness's honesty
  #    condition); the knob-0 zero-writes sentinel pair (shield untouched AND updated_at
  #    untouched — the statement never FIRES); the idle knob's raise-and-restore via the real
  #    set_game_config (its consumer arrived — the SHIELD-1 combat-knob precedent) incl. the
  #    ceil-pinning 0.03 arm; the exact climb / least cap / full-pool-never-rewritten trio; the
  #    in-encounter exclusion on a REAL active encounter + the destroyed exclusion; and the
  #    commission copy born FULL through BOTH real creators (the hull surgery + restore are
  #    required by the tightened hull-table greps above). ────────────────────────────────────────
  grep -qF "every reconciler pass above must have run dark" "$SQL" \
    || fail "harness does not PIN the committed idle knob '0' at SHIELD2 entry (the byte-parity witness condition)"
  grep -qF "shield moved to % under the committed knob ''0''" "$SQL" \
    || fail "harness does not ASSERT the knob-0 pass leaves the damaged shield untouched"
  grep -qF "a same-value UPDATE still writes rows; the v_idle > 0 guard must skip it entirely" "$SQL" \
    || fail "harness does not ASSERT the updated_at sentinel (knob-0 must never FIRE the statement)"
  grep -qF "set_game_config('shield_regen_idle_pct', '0.03'::jsonb)" "$SQL" \
    || fail "harness does not raise the idle knob to the ceil-pinning 0.03 via the real set_game_config (in-txn)"
  grep -qF "the climb must be CEIL, floor/trunc would land 4" "$SQL" \
    || fail "harness does not PIN the ceil arithmetic (3 + ceil(40 × 0.03) = 5)"
  grep -qF "(want 15 = 5 + ceil(40 × 0.25) exactly)" "$SQL" \
    || fail "harness does not ASSERT the exact lit idle climb"
  grep -qF "least(max_shield, 35 + 10) must bind, uncapped would be 45" "$SQL" \
    || fail "harness does not ASSERT the least() cap at max_shield"
  grep -qF "shield < max_shield must exclude it" "$SQL" \
    || fail "harness does not ASSERT a FULL pool is never rewritten (the partial-index predicate)"
  grep -qF "while an encounter is active/retreating the tick is the SOLE shield writer" "$SQL" \
    || fail "harness does not ASSERT the in-encounter exclusion on a REAL active encounter"
  grep -qF "dead ships do not regenerate; repair is the revival path" "$SQL" \
    || fail "harness does not ASSERT the destroyed exclusion"
  grep -qF "shield = max_shield = base_shield, BORN FULL through the build core" "$SQL" \
    || fail "harness does not ASSERT the commission copy (born full via commission_first_main_ship → build)"
  grep -qF "(want 25/25 — the two creators must stay consistent)" "$SQL" \
    || fail "harness does not ASSERT the ensure creator's copy (creator consistency)"
  grep -qF "set_game_config('shield_regen_idle_pct', '0'::jsonb)" "$SQL" \
    || fail "harness does not restore the idle regen knob to the dark seed in-txn"

  # ── NANGUARD (0198) pins, in assert form (a gutted .sql that only mentions them in prose cannot
  #    false-green): the fix is INERT at seed 0, so the witness must POISON a knob with the jsonb
  #    string "NaN" in-txn and prove the fixed guard floors it to 0 — the affinity witness must be
  #    NON-VACUOUS (a real matched contribution, else a 0-share NaN can't reach the math), the
  #    adapter output must stay byte-identical to the knob-0 baseline with a finite (never-NaN)
  #    combat_power, the reconciler must stay a clean no-op (shield 3 untouched, no ceil(NaN)::int
  #    abort), and BOTH poisoned knobs must be set via the jsonb "NaN" literal AND restored to '0'. ──
  grep -qF "set_game_config('station_affinity_bonus', '\"NaN\"'::jsonb)" "$SQL" \
    || fail "harness does not POISON the affinity knob with the jsonb \"NaN\" string (the NANGUARD witness)"
  grep -qF "set_game_config('shield_regen_idle_pct', '\"NaN\"'::jsonb)" "$SQL" \
    || fail "harness does not POISON the idle-regen knob with the jsonb \"NaN\" string (the NANGUARD witness)"
  grep -qF "a 0-share NaN test can only false-green" "$SQL" \
    || fail "harness does not GUARD the affinity NaN witness against a vacuous 0-share (non-vacuity pin)"
  grep -qF "combat_power is NaN under a \"NaN\" affinity knob" "$SQL" \
    || fail "harness does not ASSERT combat_power is a finite number (never NaN) under a \"NaN\" affinity knob"
  grep -qF "want byte-identical to the knob-0 baseline — the fixed guard floors NaN to 0" "$SQL" \
    || fail "harness does not ASSERT the \"NaN\" affinity knob is byte-identical to the knob-0 baseline"
  grep -qF "want 3 untouched — the floor sends v_idle to 0 so the statement is skipped, never a NaN write" "$SQL" \
    || fail "harness does not ASSERT the \"NaN\" idle-regen knob leaves the shield a clean no-op (no ceil(NaN)::int abort)"

  # ── FLEET-CONTROL (0204) witness pins, in assert form (a gutted .sql that only mentions them in prose
  #    cannot false-green): the committed-dark flag pin; the DARK no-command-requirement (a zero-command
  #    fleet sends while dark, fleet_inactive_no_command NEVER appears) + the DARK no-8-cap (9 members);
  #    the LIT reject on ALL THREE movement RPCs; the activation (designate → reject disappears + the
  #    is_command_ship persistence); the exact 8th-OK / 9th-fleet_full boundary held at 8; and the
  #    designation guard (ungrouped → ship_not_in_fleet) + the stand-down re-inactivation round-trip. ──
  grep -qF "FLEETCTRL FAIL: fleet_control_enabled is not committed false (dark)" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the committed-dark flag"
  grep -qF "a no-command fleet was blocked while dark (want no command requirement)" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the DARK no-command-requirement (send succeeds, no fleet_inactive reject)"
  grep -qF "want 9 — no 8-cap while dark" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the DARK no-8-cap (9 members assigned)"
  grep -qF "FLEETCTRL FAIL lit send inactive" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the LIT send fleet_inactive_no_command reject"
  grep -qF "FLEETCTRL FAIL lit move inactive" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the LIT move fleet_inactive_no_command reject"
  grep -qF "FLEETCTRL FAIL lit hunt inactive" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the LIT hunt fleet_inactive_no_command reject"
  grep -qF "is_command_ship did not persist on the designated ship" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the command-ship designation persists"
  grep -qF "the fleet is still inactive after designating a command ship" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT designation ACTIVATES the fleet (reject disappears)"
  grep -qF "the 8th member was rejected (want ok)" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the 8th member assign is OK under the lit cap"
  grep -qF "the 9th member was not rejected fleet_full" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the 9th member rejects fleet_full"
  grep -qF "the rejected 9th must not have been written" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the fleet is held at 8 (the rejected 9th is not written)"
  grep -qF "the command role was NOT cleared when the ship changed fleets" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the per-fleet command-role reset on a fleet change"
  grep -qF "designating an ungrouped ship was not rejected ship_not_in_fleet" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the ungrouped-ship designation guard (ship_not_in_fleet)"
  grep -qF "standing down the last command ship did not re-inactivate the fleet" "$SQL" \
    || fail "FLEETCTRL: harness does not ASSERT the stand-down re-inactivation round-trip"

  # ── NO-HOME (0199) witness pins (the NANGUARD posture — a future edit can't gut a NOHOME assertion and
  #    stay green): (a) launch origin is the docked LOCATION, not the base; (b) the return port is recorded;
  #    (c) the reconciler DOCKS the returner, never re-homes it under the flag; (d) H1 — a returned docked
  #    team can LAUNCH AGAIN (the second-launch regression witness the per-ship split guarantees). ─────────
  grep -qF "origin_type='location' and origin_location_id=slag and target_type='location'" "$SQL" \
    || fail "NOHOME: harness does not ASSERT the docked launch departs from the port LOCATION (not the base)"
  grep -qF "(r->>'return_location_id')::uuid is distinct from slag" "$SQL" \
    || fail "NOHOME: harness does not ASSERT the chosen/origin return port is recorded on the launch envelope"
  grep -qF "the returning member was re-homed under the lit flag" "$SQL" \
    || fail "NOHOME: harness does not ASSERT the reconciler DOCKS (never re-homes) the returner under the flag"
  grep -qF "a returned docked team could not launch again" "$SQL" \
    || fail "NOHOME: harness does not ASSERT the H1 second-launch witness (a returned team hunts AGAIN)"
  grep -qF "has no per-ship tagged present fleet at the return port (H1 wedge)" "$SQL" \
    || fail "NOHOME: harness does not ASSERT the H1 per-ship fleet split (each returned member owns a tagged fleet)"

  # ── COMMAND-BUFFS (0205) witness pins, in assert form (a gutted .sql that only mentions them in prose
  #    cannot false-green): the committed-dark flag; the commission-trigger roll = the deterministic hash
  #    derivation; the DARK inertness (a designated command ship's buff is inert while dark, byte-identical
  #    to the baseline); the LIT fleet-wide buff-fold EXACTNESS (combat_power gains the buff attack exactly);
  #    the ZERO-command-fleet no-buff; and the group_id gate (an ungrouped ship folds nothing). The three
  #    mutation-gutting targets are the buff-fold-exactness / dark-parity / no-command-no-buff asserts. ────
  grep -qF "CMDBUFF FAIL: command_buffs_enabled is not committed false (dark)" "$SQL" \
    || fail "CMDBUFF: harness does not ASSERT the committed-dark flag"
  grep -qF "the stored buff is not the deterministic hash derivation" "$SQL" \
    || fail "CMDBUFF: harness does not ASSERT the commission-trigger roll = the deterministic hash derivation"
  grep -qF "a command ship''s buff folded while command_buffs_enabled DARK" "$SQL" \
    || fail "CMDBUFF: harness does not ASSERT the DARK-parity inertness (gutting target: dark parity)"
  grep -qF "combat_power did not gain the command buff attack exactly (buff-fold exactness)" "$SQL" \
    || fail "CMDBUFF: harness does not ASSERT the LIT fleet-wide buff-fold exactness (gutting target: buff-fold exactness)"
  grep -qF "the command ship itself did not receive its own fleet-wide buff" "$SQL" \
    || fail "CMDBUFF: harness does not ASSERT the command ship receives its own fleet-wide buff"
  grep -qF "two command ships did not SUM both buffs (backups)" "$SQL" \
    || fail "CMDBUFF: harness does not ASSERT multiple command ships sum their buffs (backups)"
  grep -qF "a fleet with ZERO command ships still folded a buff" "$SQL" \
    || fail "CMDBUFF: harness does not ASSERT the no-command-ship-no-buff arm (gutting target: no-command-no-buff)"
  grep -qF "an ungrouped ship folded a fleet buff (the group_id gate breach)" "$SQL" \
    || fail "CMDBUFF: harness does not ASSERT the group_id gate (an ungrouped ship folds nothing)"
  # the adapter is called DIRECTLY (service-role) for the independent per-key derivation — the delegation
  # posture (a re-implemented fold could not be caught by token greps). Pin one such direct call.
  grep -qF "public.calculate_expedition_stats(uCB, sB, '[]'::jsonb, 'none')" "$SQL" \
    || fail "CMDBUFF: harness does not call the adapter directly for the independent per-key derivation"

  # ── all twenty-nine block PASS markers present. ──────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing block PASS marker: $m"
  done

  tp_assert_out_of_scope "$SQL"

  echo "TEAM-COMMAND B-VERIFY SELFTEST: ALL PASSED (self-rolling-back; dark flags (incl. command_buffs_enabled) toggled only in-txn; real-RPC provisioning + sole-writer captains + sole-writer manifest + sole-writer XP ledger + sole-writer modules/inventory + migration-only hull recipes + sole-writer ship-soul traits; 9 RPCs + all reject tokens; 0170-hull-stats/all-or-nothing/stop-aggregate/held/SET-NULL/captain-fold/D0-delegation/D1-combat-parity/D2-team-hunt/0171-shard-drop/D3-team-settle/0177-capxp/0180-caplevel/0183-mod2/0202-mod22/0185-shipyard0/0186-soul0/0187-teammap/0191-shield0/0190-teammove/0193-soul1/0195-shield1/0196-decks3/0197-shield2/0198-nanguard/0199-nohome/0205-cmdbuff specifics; 0171 bump asserted-not-fixtured; hull-table writes fenced to the sanctioned base_shield fixture WITH its restore; shipyard_enabled never flipped; BOTH shield knobs raised-and-restored in-txn only via set_game_config; NANGUARD poisons the affinity + idle knobs with the jsonb \"NaN\" string in-txn and proves the fixed guard floors it to 0, both restored)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "TEAM-COMMAND B-VERIFY" "$SQL" "$PASS_LINE" "$MARKERS"

# post-run honesty check: EVERY committed flag the proof flips must still be false (the flips were rolled
# back). Check all eight the harness toggles in-txn, not just the team gate.
for flag in team_command_enabled mainship_additional_commission_enabled mainship_send_enabled captain_assignment_enabled captain_growth_enabled module_crafting_enabled module_fitting_enabled ship_traits_enabled launch_from_dock_enabled fleet_control_enabled command_buffs_enabled; do
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

# same honesty check for the 0185 BLUEPRINT KNOB: the SHIPYARD0 block raises it to 1 in-txn; the
# committed value must still be the 0185 seed '0' — a leak here would silently start dropping
# blueprint fragments in a dark game. The shipyard FLAG needs no leak check beyond the loop above's
# pattern: the proof never writes it at all (asserted by the selftest negative grep).
committed_bp="$(psql "$DB_URL" -X -t -A -c "select coalesce((select value #>> '{}' from public.game_config where key = 'blueprint_fragment_drop_rate'), '0')")" \
  || fail "could not read the committed 'blueprint_fragment_drop_rate' value"
[ "$committed_bp" = "0" ] || fail "committed blueprint_fragment_drop_rate is '$committed_bp' — the proof leaked the knob (must stay 0)"
committed_sy="$(psql "$DB_URL" -X -t -A -c "select coalesce((select value #>> '{}' from public.game_config where key = 'shipyard_enabled'), 'false')")" \
  || fail "could not read the committed 'shipyard_enabled' value"
[ "$committed_sy" = "false" ] || fail "committed shipyard_enabled is '$committed_sy' — must stay false (the proof never touches it)"

# same honesty check for the 0196 AFFINITY KNOB: the DECKS3 block raises it to 0.15 in-txn; the
# committed value must still be the 0196 seed '0' — a leak here would silently start paying
# station-affinity bonuses in a game whose owner never flipped ACT-DECKS3.
committed_aff="$(psql "$DB_URL" -X -t -A -c "select coalesce((select value #>> '{}' from public.game_config where key = 'station_affinity_bonus'), '0')")" \
  || fail "could not read the committed 'station_affinity_bonus' value"
[ "$committed_aff" = "0" ] || fail "committed station_affinity_bonus is '$committed_aff' — the proof leaked the knob (must stay 0)"

# same honesty check for the 0191 SHIELD REGEN KNOBS: the SHIELD1 block raises the COMBAT knob to
# '1' in-txn (SHIELD-1 wired its consumer) and the SHIELD2 block raises the IDLE knob to
# 0.03/0.25 in-txn (SHIELD-2 wired its consumer — the regen home); both are restored in-txn and
# rolled back regardless. The committed values must still be the 0191 seeds '0' — a leak would
# silently regenerate live shields the moment pools go nonzero.
for knob in shield_regen_combat_pct shield_regen_idle_pct; do
  committed_sr="$(psql "$DB_URL" -X -t -A -c "select coalesce((select value #>> '{}' from public.game_config where key = '$knob'), '0')")" \
    || fail "could not read the committed '$knob' value"
  [ "$committed_sr" = "0" ] || fail "committed $knob is '$committed_sr' — the proof leaked the knob (must stay 0)"
done

# SHIELD-2 honesty check for the sanctioned base_shield fixture: the in-txn surgery (25, restored
# 0, rolled back regardless) must never leak — a committed nonzero base_shield would silently arm
# the commission copy in a dark game.
committed_bs="$(psql "$DB_URL" -X -t -A -c "select coalesce((select base_shield::text from public.main_ship_hull_types where hull_type_id = 'starter_frigate'), '0')")" \
  || fail "could not read the committed starter_frigate base_shield"
[ "$committed_bs" = "0" ] || fail "committed starter_frigate base_shield is '$committed_bs' — the proof leaked the hull fixture (must stay 0 until ACT-SHIELD)"

# (the 0199 NO-HOME flag launch_from_dock_enabled is covered by the committed-false flag loop above —
#  the NOHOME block flips it 'true' in-txn to prove the lit launch/dock-at-return and it must roll back.)

echo "TEAM-COMMAND B-VERIFY LOCAL PROOF: OVERALL_PASS (committed team_command_enabled/mainship_additional_commission_enabled/mainship_send_enabled/captain_assignment_enabled/captain_growth_enabled/module_crafting_enabled/module_fitting_enabled/shipyard_enabled/ship_traits_enabled/launch_from_dock_enabled/fleet_control_enabled all still false; captain_shard_drop_rate still 0; captain_xp_per_combat_grant still 10; blueprint_fragment_drop_rate still 0; shield_regen_combat_pct/shield_regen_idle_pct still 0; station_affinity_bonus still 0; starter_frigate base_shield still 0)"
