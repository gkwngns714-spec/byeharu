#!/usr/bin/env bash
# EMBER REACH REVEAL runner — wraps the ONE ZONES2-2 reveal operation scripts/reveal-ember-reach.sql
# (docs/FULL_CAPACITY_PLAN.md §C P4; queue slice #8; content seeded HIDDEN by migration 0175 / queue
# slice #7). ██ HUMAN TOOL ██ — never wired into CI; nothing reveals at build time; each `run` is the
# human's recorded go decision. Reveal IS the content cadence mechanism (ship hidden, reveal
# deliberately, ~monthly). Recommended timing: AFTER teams have kitted up (the gates price the sites
# at ~4/6/8 kitted+captained ships — TEAM_ACTIVATION_PACKET §0.3/§1.3-C).
#
# The activate-team-command / activate-trade wrapper pattern, ADAPTED to a REVEAL: the operation's
# ONLY write is ONE status UPDATE on public.locations scoped to the three fixed 0175 uuids — it is
# NOT a set_game_config flip, so the selftest asserts the write-shape inversion: zero set_game_config
# call sites, exactly one locations UPDATE, hidden→active only, nothing else writable anywhere.
# Modes:
#   selftest — DB-free static safety: the operation is one timed BEGIN..COMMIT with NO psql
#              meta-command (management-API compatible); preconditions on 0175 recorded + the
#              all-hidden baseline + exact seeded identity + active parents + the get_world_map
#              three-level status='active' prosrc pin + a behavioral no-leak pre-check; the ONLY
#              write is the one UPDATE public.locations SET status='active' scoped to the three
#              fixed uuids (no other table write, no set_game_config, no DDL, no 'hidden' write in
#              active code — the rollback stays commented); smoke covers net +3, the non-canonical
#              identity digest, the game_config digest, and the behavioral post-reveal map check.
#   run      — execute against $DB_URL and assert every stage marker. Requires the typed confirm
#              token as the 2nd arg. No local psql? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner — it is self-contained, self-asserting,
#              meta-command-free.
#
#   bash scripts/reveal-ember-reach.sh selftest
#   bash scripts/reveal-ember-reach.sh run REVEAL_EMBER_REACH          # DB_URL required
#
# AFTER a green run (manual smoke; no client PR — the galaxy map is data-driven, markerStyle.ts):
#   open the map → three new hostile triangle markers NE beyond Blackden (Ember Gate / Cinder Maw /
#   The Furnace); detail panel reads Danger High / Rewards Rich (client buckets — exact bd/gate numbers render nowhere yet); an under-powered team send
#   rejects power_below_required server-side.
# Rollback: the commented section at the bottom of the .sql — re-hiding IS supported for hunt sites
# (sends validate status at send time only; settle/combat/return key on location_id, nothing strands).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [REVEAL_EMBER_REACH]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/reveal-ember-reach.sql"
CONFIRM_TOKEN="REVEAL_EMBER_REACH"
MARKERS="REVEAL_EMBER_PASS_PRECONDITIONS REVEAL_EMBER_PASS_STAGE REVEAL_EMBER_PASS_SMOKE"
PASS_LINE="EMBER REACH REVEAL PASS"
UUID_GATE="eb000011-0175-4a00-8a00-000000000001"
UUID_MAW="eb000012-0175-4a00-8a00-000000000002"
UUID_FURN="eb000013-0175-4a00-8a00-000000000003"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere (nothing for a runner to strip).
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the reveal)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"

  # preconditions: the 0175 seed recorded; the all-hidden baseline; exact identity; active parents;
  # the map-read visibility pin (structural prosrc + behavioral no-leak).
  printf '%s' "$CLEAN" | grep -q "20260618000175" || fail "operation must precondition on the 0175 Ember Reach seed being recorded"
  printf '%s' "$CLEAN" | grep -qF "filter (where status = 'hidden')" || fail "operation must snapshot the hidden/active baseline"
  printf '%s' "$CLEAN" | grep -qF "v_active_before <> 0" || fail "operation must fail closed on an already-active canonical site (rerun safety)"
  for nm in "Ember Gate" "Cinder Maw" "The Furnace"; do
    printf '%s' "$CLEAN" | grep -qF "'$nm'" || fail "operation must pin the seeded identity of $nm"
  done
  for u in "$UUID_GATE" "$UUID_MAW" "$UUID_FURN"; do
    printf '%s' "$CLEAN" | grep -qF "$u" || fail "operation must target the fixed 0175 uuid $u"
  done
  printf '%s' "$CLEAN" | grep -qF "'hunt_pirates'" || fail "operation must pin the hunt_pirates activity identity"
  printf '%s' "$CLEAN" | grep -qF "150.0" && printf '%s' "$CLEAN" | grep -qF "220.0" && printf '%s' "$CLEAN" | grep -qF "300.0" || fail "operation must pin the min_power gates 150/220/300"
  printf '%s' "$CLEAN" | grep -q "from public.zones"   || fail "operation must assert the parent zone is active (else the reveal is invisible)"
  printf '%s' "$CLEAN" | grep -q "from public.sectors" || fail "operation must assert the parent sector is active (else the reveal is invisible)"
  printf '%s' "$CLEAN" | grep -qF "l.zone_id = z.id and l.status = ''active''" || fail "operation must prosrc-pin get_world_map's location-level status=active filter (the visibility authority)"
  printf '%s' "$CLEAN" | grep -qF "public.get_world_map()::text" || fail "operation must behaviorally check the map read output (pre-leak + post-reveal)"

  # THE WRITE-SHAPE LAW (the reveal adaptation of the activate-family write checks): the ONLY write
  # is ONE UPDATE on public.locations, hidden->active, scoped to the three fixed uuids.
  n="$(printf '%s' "$CLEAN" | grep -ciE 'update[[:space:]]+public\.locations' || true)"
  [ "$n" = "1" ] || fail "operation must contain exactly ONE update of public.locations (found $n)"
  n="$(printf '%s' "$CLEAN" | grep -ciE 'update[[:space:]]+(public\.)?[a-z_]+' || true)"
  [ "$n" = "1" ] || fail "operation updates a table other than public.locations (found $n update sites)"
  printf '%s' "$CLEAN" | grep -qF "set status = 'active'" || fail "the one update must set status = 'active' (the reveal)"
  printf '%s' "$CLEAN" | grep -qF "status = 'hidden'" || fail "the one update must be guarded to rows currently hidden"
  printf '%s' "$CLEAN" | grep -qF "set status = 'hidden'" && fail "active code writes status='hidden' (the rollback must stay commented)" || true
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "0" ] || fail "a content reveal must never call set_game_config (found $n call sites)"
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|delete[[:space:]]+from)' && fail "operation inserts/deletes rows (the only write is the one status UPDATE)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true
  printf '%s' "$CLEAN" | grep -qF "get diagnostics" && printf '%s' "$CLEAN" | grep -qF "v_n <> 3" || fail "the update must assert row_count exactly 3"

  # smoke: net +3, the offsetting-proof digest, the game_config digest, the behavioral post-check.
  printf '%s' "$CLEAN" | grep -qF "v_total_active_before + 3" || fail "missing the net-+3 active-location smoke"
  printf '%s' "$CLEAN" | grep -qF "id <> all(v_sites)" || fail "missing the non-canonical identity digest (offsetting-proof)"
  printf '%s' "$CLEAN" | grep -qF "from public.game_config" || fail "missing the game_config invariance digest (no flag may ride along)"

  # markers, PASS line, rollback documentation.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL" || fail "missing final PASS line"
  grep -qi "ROLLBACK (manual" "$OP_SQL" || fail "missing the marked manual ROLLBACK section"
  grep -qi "SEND time only" "$OP_SQL" || fail "operation must document the in-flight/re-hide consideration (sends validate at send time only; nothing strands)"

  echo "EMBER REACH REVEAL SELFTEST: ALL PASSED (single timed BEGIN..COMMIT, no meta-commands; 0175-gated with all-hidden baseline + identity pins + active parents + get_world_map prosrc/behavioral visibility pins; the ONLY write is the one locations UPDATE hidden->active on the 3 fixed uuids with row_count=3; zero set_game_config/insert/delete/DDL; net +3 + offsetting-proof + game_config digests; rollback commented + re-hide consideration documented)"
  exit 0
fi

# ── run: the human's reveal execution ─────────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "reveal operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "EMBER REACH REVEAL: OVERALL_PASS — Ember Gate / Cinder Maw / The Furnace live on the galaxy map. No client PR needed (data-driven map). Manual smoke: three hostile triangle markers NE beyond Blackden; gates 150/220/300 in the detail panel; under-powered sends reject power_below_required."
