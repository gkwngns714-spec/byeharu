#!/usr/bin/env bash
# RANKING-P17 — DYNAMIC commit-safety proof for public.ranking_accrue_standings against the REAL
# migrated local Supabase DB. Mirrors scripts/mining-p12-double-extract-concurrency.sh /
# scripts/osn3-s3-realchain-concurrency.sh point-for-point (FIFO-driven concurrent psql session,
# distinct application_name, pg_stat_activity state polling, a trap that restores ranking_enabled to
# 'false' and asserts it, cleans all fixtures, $DB_URL-gated, NEVER touches the shared/live DB).
#
# WHAT THIS PROVES — the exact bug the old cursor skipped forever, now COUNTED. `ranking_accrue_standings`
# (0130) folded grants by a TIMESTAMP high-water cursor `ranking_standings.last_counted_at`: it counted
# only grants with `granted_at > last_counted_at`. But `reward_grants.granted_at` defaults to the
# inserting txn's START time (0015:14) while the row is VISIBLE to the accrual reader only at COMMIT. A
# grant whose txn STARTED before an accrual run (small granted_at = T1) but COMMITS AFTER that run
# advanced the watermark past T1 is then PERMANENTLY SKIPPED — the next run's `granted_at >
# last_counted_at` filter excludes it forever. Slice B (0145) replaces that with a VISIBILITY-BASED
# per-(season, grant) anti-join against the `ranking_counted_grants` ledger (0144): a grant absent from
# the ledger — including one that committed after any prior run, regardless of its granted_at ordering —
# is folded on the next run and marked exactly once (`unique (season_id, grant_id)`). This script stages
# that precise interleaving and asserts the late-committing grant IS counted, with no double-count.
#
# THE COUNTERFACTUAL (documented, not executed — the old function no longer exists): with the 0130
# watermark, after run 1 folds B (advancing last_counted_at to ~T2 = B's granted_at), grant A's
# granted_at T1 < T2, so run 2's `granted_at > last_counted_at` would EXCLUDE A forever → A's reward
# silently lost. The script asserts T1 < (the run-1 watermark) to pin that this is exactly the skip
# case, then proves the 0145 anti-join counts A anyway — "no finalized reward is ever missed."
#
# INTERLEAVING:
#   1) fixtures (ranking_enabled true ONLY in this disposable stack): one ACTIVE ranking_seasons row
#      whose window spans the test, one throwaway player.
#   2) session A: `begin` + INSERT a reward_grants row (granted_at stamped at A's txn START = T1) and
#      HOLD the txn open (uncommitted ⇒ invisible).
#   3) session-less: INSERT+COMMIT grant B for a later granted_at (T2 > T1) in the same season window.
#   4) run ranking_accrue_standings() once → sees only B (A invisible): assert B folded into standings +
#      B in the ledger, and A NOT in the ledger.
#   5) COMMIT A (commit time T3 > T2, but A.granted_at is still the older T1 — the skip case).
#   6) run ranking_accrue_standings() again → assert A IS now folded (A in the ledger, standings score +
#      events_counted increased by exactly A's contribution), exactly TWO grants folded for (season,
#      player) total, and B still counted exactly once (no double-count — the ledger unique + anti-join).
#
# RUN (human owner's activation checklist — DEFERRED; this environment has no local DB):
#   DB_URL=postgres://... bash scripts/ranking-p17-commit-safe-accrual-proof.sh
# NOT wired into the dark `verify:*` block in package.json: it needs a LIT DB (ranking_enabled flipped
# true INSIDE this disposable stack only) and so cannot run in the flag-off verify sweep. Referenced
# only from this header and the DEV_LOG. Static-check any time with:
#   bash -n scripts/ranking-p17-commit-safe-accrual-proof.sh
set -uo pipefail
: "${DB_URL:?DB_URL required (dynamic proof; run only against a disposable local DB)}"

q() { PGAPPNAME="${2:-mon}" psql "$DB_URL" -X -q -t -A -c "$1"; }

# capture the original flag value so the trap restores it verbatim (never invent a fallback)
ORIG_ENABLED=$(q "select value from game_config where key='ranking_enabled'")
SEASON_LABEL="rank-commit-proof-$(q "select replace(gen_random_uuid()::text,'-','')")"
SID=""
U=""

FIFOA=$(mktemp -u)
cleanup() {
  { echo "rollback;" >&3; } 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  kill "$PA" 2>/dev/null || true
  # restore the flag this stack toggled, back to its captured original (flag → false)
  q "update game_config set value='${ORIG_ENABLED:-false}' where key='ranking_enabled';" >/dev/null 2>&1 || true
  # fixture cleanup: the test season (cascades its standings + counted_grants) + the throwaway player
  # (cascades its reward_grants + any standings/counted_grants rows).
  [ -n "$SID" ] && q "delete from ranking_seasons where season_id='$SID';" >/dev/null 2>&1 || true
  q "delete from auth.users where email like 'rankcommit.%@example.com';" >/dev/null 2>&1 || true
  # assert the master flag is dark again
  RESTORED=$(q "select value from game_config where key='ranking_enabled'" 2>/dev/null || echo '?')
  [ "$RESTORED" = "false" ] || echo "WARN: ranking_enabled not restored to false (is '$RESTORED') — investigate"
  rm -f "$FIFOA" 2>/dev/null || true
}
trap cleanup EXIT

# wait until session $1 is idle-in-transaction AFTER the reward_grants insert ran (not merely after BEGIN),
# so grant A is stamped + held uncommitted before the peer proceeds.
wait_idletx() {
  for _ in $(seq 1 150); do
    [ "$(q "select (state='idle in transaction' and query ilike '%reward_grants%') from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" = "t" ] && return 0
    sleep 0.2
  done; echo "FAIL: $1 not idle-in-transaction after the insert"; cat /tmp/ranksessA.log 2>/dev/null; exit 1
}
# wait until a grant id becomes VISIBLE from a fresh (committed-read) connection — i.e. session A committed.
wait_visible() {
  for _ in $(seq 1 150); do
    [ "$(q "select count(*) from reward_grants where id='$1'")" = "1" ] && return 0
    sleep 0.2
  done; echo "FAIL: grant $1 never became visible (A did not commit)"; cat /tmp/ranksessA.log 2>/dev/null; exit 1
}

mkfifo "$FIFOA"
PGAPPNAME=ranksessA psql "$DB_URL" -X -q < "$FIFOA" >/tmp/ranksessA.log 2>&1 & PA=$!
exec 3>"$FIFOA"

# ── fixtures: enable ranking ONLY in this disposable stack; one ACTIVE season spanning the test; one
#    throwaway player (the on_auth_user_created_base trigger provisions a base — unused here). ──
q "update game_config set value='true' where key='ranking_enabled';" >/dev/null
U=$(q "
  with u as (
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated','authenticated','rankcommit.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id)
  select id from u;")
[ -n "$U" ] || { echo "FAIL: could not create throwaway user"; exit 1; }
# active weekly season with a window comfortably spanning the (seconds-long) test — both grants fall in it.
SID=$(q "insert into ranking_seasons (cadence, label, starts_at, ends_at, status) values ('weekly', '$SEASON_LABEL', now() - interval '1 hour', now() + interval '1 hour', 'active') returning season_id;")
[ -n "$SID" ] || { echo "FAIL: could not create active season (a conflicting active weekly season may already exist)"; exit 1; }

echo "=== Commit-safety scenario: a grant that commits AFTER an overlapping accrual run is still counted ==="

# 2) session A: begin + insert grant A (granted_at = A's txn START = T1), HOLD open (uncommitted).
echo "begin; insert into reward_grants (source_type, source_id, player_id, rewards) values ('combat', gen_random_uuid(), '$U', '{\"metal\":3}'::jsonb) returning 'A_GRANT='||id;" >&3
wait_idletx ranksessA
AG=$(grep -o 'A_GRANT=[0-9a-f-]*' /tmp/ranksessA.log | tail -1 | cut -d= -f2)
[ -n "$AG" ] || { echo "FAIL: could not capture A's grant id"; cat /tmp/ranksessA.log; exit 1; }

# 3) grant B: insert + COMMIT (autocommit via q) for a LATER granted_at (T2 > T1), same season window.
BG=$(q "insert into reward_grants (source_type, source_id, player_id, rewards) values ('combat', gen_random_uuid(), '$U', '{\"metal\":5}'::jsonb) returning id;")
[ -n "$BG" ] || { echo "FAIL: could not insert grant B"; exit 1; }
# A is still uncommitted ⇒ invisible to a fresh connection; the run in step 4 cannot see it.
[ "$(q "select count(*) from reward_grants where id='$AG'")" = "0" ] \
  || { echo "FAIL: grant A is visible before commit — the interleaving is wrong"; exit 1; }

# 4) FIRST accrual run — sees only B.
R1=$(q "select public.ranking_accrue_standings();"); echo "  run 1: $R1"
S1=$(q "select coalesce(score,-1)||'/'||coalesce(events_counted,-1) from ranking_standings where season_id='$SID' and player_id='$U' and dimension='combat'")
[ "$S1" = "5/1" ] || { echo "FAIL: after run 1 expected standings score/events = 5/1 (B only), got '$S1'"; exit 1; }
[ "$(q "select count(*) from ranking_counted_grants where season_id='$SID' and grant_id='$BG'")" = "1" ] || { echo "FAIL: B not marked in ledger after run 1"; exit 1; }
[ "$(q "select count(*) from ranking_counted_grants where season_id='$SID' and grant_id='$AG'")" = "0" ] || { echo "FAIL: A marked in ledger though still uncommitted!"; exit 1; }
echo "  ok: run 1 folded ONLY B (A uncommitted/invisible); B in ledger, A absent"

# 5) COMMIT A (commit time T3 > T2, but A.granted_at is still the older T1).
echo "commit;" >&3
wait_visible "$AG"
# pin the SKIP case: A.granted_at (T1) is BELOW the watermark run 1 set (~T2) — the exact row the OLD
# 0130 `granted_at > last_counted_at` cursor would exclude forever.
[ "$(q "select (select granted_at from reward_grants where id='$AG') < (select granted_at from reward_grants where id='$BG')")" = "t" ] \
  || { echo "FAIL: precondition T1 < T2 not met (A must predate B)"; exit 1; }
[ "$(q "select (select granted_at from reward_grants where id='$AG') < (select last_counted_at from ranking_standings where season_id='$SID' and player_id='$U' and dimension='combat')")" = "t" ] \
  || { echo "FAIL: A.granted_at is not below the run-1 watermark — not the skip case"; exit 1; }
echo "  ok: A committed late; A.granted_at (T1) < the run-1 watermark — the OLD cursor would skip A forever"

# 6) SECOND accrual run — the commit-safe anti-join MUST now fold A.
R2=$(q "select public.ranking_accrue_standings();"); echo "  run 2: $R2"
S2=$(q "select coalesce(score,-1)||'/'||coalesce(events_counted,-1) from ranking_standings where season_id='$SID' and player_id='$U' and dimension='combat'")
[ "$S2" = "8/2" ] || { echo "FAIL: after run 2 expected standings score/events = 8/2 (A folded: +3, +1), got '$S2'"; exit 1; }
[ "$(q "select count(*) from ranking_counted_grants where season_id='$SID' and grant_id='$AG'")" = "1" ] || { echo "FAIL: A still not in ledger after run 2 — the commit-safe fix FAILED"; exit 1; }
[ "$(q "select count(*) from ranking_counted_grants where season_id='$SID' and grant_id='$BG'")" = "1" ] || { echo "FAIL: B double-counted (appears != once) — ledger unique/anti-join broken"; exit 1; }
TOT=$(q "select count(*) from ranking_counted_grants where season_id='$SID' and player_id='$U'")
[ "$TOT" = "2" ] || { echo "FAIL: expected exactly 2 grants folded for (season, player), got $TOT"; exit 1; }
echo "  ok: run 2 folded the late-committing A (score 5→8, events 1→2); exactly 2 grants folded, B still once"

echo "RANKING-P17 COMMIT-SAFETY PROOF: ALL PASSED (a grant committing after an overlapping run is counted; no reward skipped, no double-count)"
