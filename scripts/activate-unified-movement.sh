#!/usr/bin/env bash
# UNIFIED-MOVEMENT ACTIVATION runner — wraps the ONE 4b flip act scripts/activate-unified-movement.sql
# (docs/MOVEMENT_UNIFICATION_CHARTER.md §2 + step 4b, both ⚠ PRE-FLIP OBLIGATION blocks).
# ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build time; each `run` is the human's
# recorded go decision that makes the FLEET the only unit of movement (unified mover ON, the three
# per-ship movement flags OFF, one commit).
#
# The activate-fleet-control.sh selftest pattern; the RUN path is the repo's proven Management-API
# prod access (charter DB-access note: POST /v1/projects/<ref>/database/query with
# SUPABASE_ACCESS_TOKEN — no psql, no Docker on this machine). Modes:
#   selftest — DB-free static safety: the act writes game_config ONLY, via the owned set_game_config
#              writer, on exactly the FOUR approved keys (unified -> true, the three per-ship
#              movement flags -> false) and no other window's key; the SWEEP (S2 duplicate-fleet
#              FIRST, then S1 off-manifest scoped to MANIFEST-CARRYING fleets — the unified GO
#              mints no manifest, so healthy post-flip fleets never flag and the act is genuinely
#              re-runnable) sits BEFORE the first write so a RAISE means nothing changed;
#              preconditions on head >= 0214 + BOTH pre-flip obligations PINNED BY PROSRC (the
#              hunt composes ship_group_resolve_fleet = the real 0214, not just its number; the
#              brake references group_sortie_members = the 0209 brake-sortie slice — this one
#              FAILS against prod today BY DESIGN, blocking the flip until that slice deploys)
#              + the four unified functions + the four keys; one timed UTC BEGIN..COMMIT; NO psql
#              meta-command (management-API compatible); NO direct table DML / DDL; ROLLBACK
#              section commented out with the four inverse writes (flag-exact always; world-exact
#              only if no unified go ever ran — the .sql's rollback note says so honestly).
#   run      — execute against PROD via the Management API and assert the final PASS row. Requires
#              the typed confirm token as the 2nd arg. Credentials: SUPABASE_ACCESS_TOKEN +
#              SUPABASE_PROJECT_ID from .env.local at the repo root (environment variables
#              override). On a sweep RAISE the API returns the exception message — the runner
#              PRINTS it (the poison list + remediation) and exits nonzero; nothing was committed
#              (all-or-nothing txn, writes are sequenced after the sweep).
#              NOTE: the API path does not carry raise-notice output, so the ACTUNI_PASS_* stage
#              notices are not assertable here — the success signal is the post-COMMIT PASS row,
#              which is only reachable when every prior statement succeeded. Run via psql or the
#              Dashboard editor to see the per-stage notices.
#
#   bash scripts/activate-unified-movement.sh selftest
#   bash scripts/activate-unified-movement.sh run ACTIVATE_UNIFIED_MOVEMENT
#
# ██ PRE-FLIGHT CANARY (run FIRST, ~5 minutes) ██ — nothing in the repo yet PROVES that the
# database/query endpoint (a) treats one POSTed batch as a single all-or-nothing transaction and
# (b) surfaces a plpgsql RAISE as the error message. This act's safety story leans on both, so
# retire the assumption before the real run: POST this as the query, against the SAME endpoint —
#     begin; select 1; do $$ begin raise exception 'canary'; end $$; commit; select 'never';
# EXPECT: a non-2xx response whose body carries 'canary', and NO 'never' row anywhere. Then
# confirm no side effect committed (trivially true here — the canary writes nothing). If the
# response is 2xx, contains 'never', or hides the RAISE text: STOP — do NOT use this runner; run
# the act via psql or the Supabase Dashboard SQL editor instead, where the semantics are known.
#
# AFTER a green run: the unified surfaces are runtime-flag-gated server-side; stale cached clients
# are closed by the same commit (their per-ship RPCs now reject — the server is the authority).
# Coordinate travel continues via the fleet coordinate-go surface (0208).
# Rollback: the commented section at the bottom of the .sql (four inverse config writes, copy-paste;
# FLAG-exact always — WORLD-exact only if no unified go ever ran; see the .sql's honest scope note).
# CI proof (ACTUNI_RAISE_POISON / ACTUNI_FLAGS_ATOMIC / ACTUNI_PASS_CLEAN) is a SEPARATE later pass
# on scripts/fleetgo-proof.{sql,sh} — owned by that workstream, not this file.
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_UNIFIED_MOVEMENT]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-unified-movement.sql"
CONFIRM_TOKEN="ACTIVATE_UNIFIED_MOVEMENT"
MARKERS="ACTUNI_PASS_PRECONDITIONS ACTUNI_PASS_SWEEP ACTUNI_PASS_WRITES ACTUNI_PASS_SMOKE"
PASS_LINE="UNIFIED-MOVEMENT ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere.
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT under txn-local UTC.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -qF "set local time zone 'UTC'" || fail "operation must pin the txn-local timezone to UTC"

  # preconditions: the 0214 head gate, the four unified functions, the four keys.
  printf '%s' "$CLEAN" | grep -q "20260618000214" || fail "operation must precondition on the 0214 (hunt-unified) migration head"
  for fn in command_ship_group_go command_ship_group_stop mainship_resolve_fleet ship_group_resolve_fleet; do
    printf '%s' "$CLEAN" | grep -qF "'$fn'" || fail "operation must precondition on function $fn"
  done

  # H1 — the 0214 OBLIGATION pinned by prosrc, not just its number: some deployed
  # send_ship_group_hunt body must compose ship_group_resolve_fleet (the unified consume).
  printf '%s' "$CLEAN" | grep -qF "p.proname = 'send_ship_group_hunt'" || fail "operation must inspect the deployed send_ship_group_hunt body (H1)"
  printf '%s' "$CLEAN" | grep -qF "position('ship_group_resolve_fleet' in p.prosrc)" || fail "operation must prosrc-pin the hunt-unified obligation (send_ship_group_hunt composes ship_group_resolve_fleet — the real 0214, not a version number)"
  # H2 — the lit-brake obligation pinned by prosrc: command_ship_group_stop must reference the
  # frozen manifest (the 0209 brake-sortie slice). Correctly FAILS against prod today.
  printf '%s' "$CLEAN" | grep -qF "p.proname = 'command_ship_group_stop'" || fail "operation must inspect the deployed command_ship_group_stop body (H2)"
  printf '%s' "$CLEAN" | grep -qF "position('group_sortie_members' in p.prosrc)" || fail "operation must prosrc-pin the brake-sortie obligation (command_ship_group_stop references group_sortie_members)"

  # THE SWEEP exists and is sequenced BEFORE the first flag write (sweep RAISE => nothing changed).
  printf '%s' "$CLEAN" | grep -qF "group_sortie_members" || fail "S1 must check the frozen manifest (group_sortie_members)"
  printf '%s' "$CLEAN" | grep -qF "main_ship_id is null and group_id is not null" || fail "the sweep must key the group-shaped fleet (main_ship_id IS NULL + group_id set — never group_id alone)"
  grep -qF "SWEEP S1 FAIL" "$OP_SQL" || fail "missing the S1 off-manifest RAISE"
  grep -qF "SWEEP S2 FAIL" "$OP_SQL" || fail "missing the S2 duplicate-fleet RAISE"
  grep -qF "having count(*) > 1" "$OP_SQL" || fail "S2 must detect >1 live group-shaped fleet per (player, group)"
  grep -qF "unassign the listed ship(s) or wait for the sortie to settle, then re-run" "$OP_SQL" || fail "S1 must carry its remediation message"
  # M1 — S1 must be scoped to MANIFEST-CARRYING fleets (a unified GO fleet mints no manifest; an
  # unscoped S1 would flag every member of every healthy unified fleet on a post-flip re-run and
  # tell the owner to unassign them).
  printf '%s' "$CLEAN" | grep -qF "and exists (select 1 from public.group_sortie_members gsm2" || fail "S1 must be scoped to manifest-carrying fleets (the unified GO mints no manifest — unscoped S1 over-fires post-flip)"
  # L1 — both sweeps use the resolver's four-status live set; the narrower three-status set is banned.
  printf '%s' "$CLEAN" | grep -qF "status in ('idle', 'moving', 'present', 'returning')" || fail "the sweep must use the resolver's four-status live set (idle/moving/present/returning)"
  printf '%s' "$CLEAN" | grep -qF "status in ('moving', 'present', 'returning')" && fail "the sweep uses the narrower three-status set (idle must be included — the sweep guards UNKNOWN history)" || true
  # L3 — S2 (duplicate fleets) must run BEFORE S1, or a duplicate-fleet world surfaces as S1
  # offenders with the wrong "unassign" remediation.
  s2_line="$(grep -n "SWEEP S2 FAIL" "$OP_SQL" | head -1 | cut -d: -f1)"
  s1_line="$(grep -n "SWEEP S1 FAIL" "$OP_SQL" | head -1 | cut -d: -f1)"
  [ -n "$s2_line" ] && [ -n "$s1_line" ] && [ "$s2_line" -lt "$s1_line" ] || fail "S2 must be sequenced BEFORE S1 (S2 at line ${s2_line:-?}, S1 at line ${s1_line:-?})"
  # NOTE: the write anchor is the loop's VALUES row (the act's ONE real write path) — NOT the
  # commented ROLLBACK's set_game_config lines at the bottom, which would make this check vacuous.
  sweep_line="$(grep -n "SWEEP S1 FAIL" "$OP_SQL" | head -1 | cut -d: -f1)"
  write_line="$(grep -n "'fleet_movement_unified_enabled',     'true'::jsonb" "$OP_SQL" | head -1 | cut -d: -f1)"
  [ -n "$sweep_line" ] && [ -n "$write_line" ] && [ "$sweep_line" -lt "$write_line" ] || fail "the SWEEP must be sequenced BEFORE the flag writes (sweep at line ${sweep_line:-?}, first write at line ${write_line:-?})"

  # writes: the owned set_game_config writer only, exactly the four approved keys with the exact
  # target values (unified -> true, the three per-ship movement flags -> false); never another
  # window's key, never direct table DML, never DDL. (Comment-stripped, so the commented ROLLBACK
  # section cannot satisfy or violate these.) 1 call site = the ONE loop over the 4-key VALUES list.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site — the one 4-key write loop (found $n)"
  printf '%s' "$CLEAN" | grep -qF "('fleet_movement_unified_enabled',     'true'::jsonb)"   || fail "missing fleet_movement_unified_enabled -> true"
  printf '%s' "$CLEAN" | grep -qF "('mainship_send_enabled',              'false'::jsonb)"  || fail "missing mainship_send_enabled -> false"
  printf '%s' "$CLEAN" | grep -qF "('mainship_space_movement_enabled',    'false'::jsonb)"  || fail "missing mainship_space_movement_enabled -> false"
  printf '%s' "$CLEAN" | grep -qF "('mainship_coordinate_travel_enabled', 'false'::jsonb)"  || fail "missing mainship_coordinate_travel_enabled -> false"
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(team_command_enabled|fleet_control_enabled|launch_from_dock_enabled|mainship_additional_commission_enabled|module_crafting_enabled|module_fitting_enabled|salvage_market_enabled|mining_enabled|trade_market_enabled|exploration_enabled)'" \
    && fail "operation writes another window's config key (out of the 4b flip's scope)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only — the sweep reads, it never cleans)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden — an act is not a migration)" || true

  # markers + the documentation the human relies on.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "ACTUNI_PASS_FLAG" "$OP_SQL"                  || fail "missing the per-flag smoke confirmation notices"
  grep -q "$PASS_LINE" "$OP_SQL"                        || fail "missing final PASS line"
  grep -q "NOT A MIGRATION" "$OP_SQL"                   || fail "operation must document that it is an act, never a migration"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"                  || fail "operation must document the re-run no-op semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                 || fail "missing the marked manual ROLLBACK section"
  grep -q "WORLD-EXACT ONLY IF NO UNIFIED GO EVER RAN" "$OP_SQL" || fail "the ROLLBACK section must state its honest scope (flag-exact always; world-exact only if no unified go ever ran)"
  for k in "'fleet_movement_unified_enabled',     'false'" "'mainship_send_enabled',              'true'" "'mainship_space_movement_enabled',    'true'" "'mainship_coordinate_travel_enabled', 'true'"; do
    grep -qF "$k" "$OP_SQL" || fail "the commented ROLLBACK must carry the inverse write for ${k%%,*}"
  done

  echo "UNIFIED-MOVEMENT ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 4 approved keys — unified true + three per-ship movement flags false; sweep S2-then-S1 (S1 manifest-scoped, four-status set) sequenced before the writes in one timed UTC BEGIN..COMMIT gated on head >= 0214 + BOTH prosrc-pinned pre-flip obligations (hunt composes the unified leaf; brake carries the sortie guard) + the 4 unified functions + the 4 keys; no meta-commands; no other-window/table/DDL writes; rollback commented with the four inverse writes + its honest world-exact scope)"
  exit 0
fi

# ── run: the human's activation execution (Management-API path — the repo's proven prod access) ────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
for t in curl jq; do command -v "$t" >/dev/null 2>&1 || fail "required tooling missing: $t"; done

# Credentials: .env.local at the repo root (the charter's DB-access note); environment overrides.
if [ -f "$REPO_ROOT/.env.local" ]; then
  if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    SUPABASE_ACCESS_TOKEN="$(sed -nE 's/^[[:space:]]*SUPABASE_ACCESS_TOKEN[[:space:]]*=[[:space:]]*//p' "$REPO_ROOT/.env.local" | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
  fi
  if [ -z "${SUPABASE_PROJECT_ID:-}" ]; then
    SUPABASE_PROJECT_ID="$(sed -nE 's/^[[:space:]]*SUPABASE_PROJECT_ID[[:space:]]*=[[:space:]]*//p' "$REPO_ROOT/.env.local" | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
  fi
fi
[ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || fail "SUPABASE_ACCESS_TOKEN not set and not found in .env.local"
[ -n "${SUPABASE_PROJECT_ID:-}" ]  || fail "SUPABASE_PROJECT_ID not set and not found in .env.local"
printf '%s' "$SUPABASE_PROJECT_ID" | grep -qE '^[a-z0-9]{20}$' || fail "SUPABASE_PROJECT_ID does not look like a project ref"

echo "[act] UNIFIED-MOVEMENT flip against project $SUPABASE_PROJECT_ID (Management API database/query; one all-or-nothing transaction)"
BODY="$(jq -Rs '{query: .}' < "$OP_SQL")" || fail "could not encode the operation SQL"
RESP="$(curl --silent --show-error --proto '=https' --max-redirs 0 --connect-timeout 10 --max-time 120 \
  -w '\n%{http_code}' \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
  -X POST "https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_ID}/database/query" \
  --data-binary "$BODY")" || fail "the Management API request failed to send (nothing may have run — verify before retrying)"
HTTP_CODE="$(printf '%s' "$RESP" | tail -n 1)"
OUT="$(printf '%s' "$RESP" | sed '$d')"

if [ "${HTTP_CODE:0:1}" != "2" ]; then
  echo "── the act RAISED (HTTP $HTTP_CODE) — nothing was committed (all-or-nothing txn; the writes are sequenced AFTER the sweep) ──" >&2
  printf '%s\n' "$OUT" >&2   # carries the RAISE message: the sweep's poison list + remediation, verbatim
  fail "activation act FAILED — read the sweep/precondition message above, remediate, and re-run"
fi
printf '%s\n' "$OUT"
printf '%s' "$OUT" | grep -qF "$PASS_LINE" || fail "the act did not return the final PASS row (uncertain state — verify the four flags before anything else)"
echo "UNIFIED-MOVEMENT ACTIVATION: OVERALL_PASS — the fleet is the ONLY unit of movement. Unified mover LIVE; per-ship send/space/coordinate surfaces dark (stale clients closed server-side). Coordinate travel rides the fleet coordinate-go surface (0208). Rollback: the commented section at the bottom of the .sql."
