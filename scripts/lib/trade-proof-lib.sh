# trade-proof-lib.sh — the shared shell blocks of the trade proof orchestrators.
#
# Sourced (never executed) by scripts/trade-economy-bootstrap-proof.sh,
# scripts/trade-fleet-0c-proof.sh, and scripts/trade-market-1-proof.sh — the .sh side of the
# write-then-ROLLBACK proof harness idiom. Extracted because the five blocks below lived as
# near-byte-identical copies in all three; NEW trade-proof scripts must source this lib rather
# than re-copying the blocks. Each caller passes only its specifics (SQL path, flag list,
# marker list, PASS line, proof name); anything feature-specific (provisioning greps,
# reject-token asserts, property-specific checks, the final selftest summary echo) stays in
# the calling script — the lib never forks per caller.
#
#   tp_init <mode>                          — arg/usage scaffold: shell options, fail(), sets
#                                             the global MODE, rejects anything but
#                                             <selftest|local> (usage → exit 2)
#   tp_assert_self_rolling_back <sql>       — DB-free static checks: opens a txn, ends in
#                                             ROLLBACK (as the LAST txn verb), NEVER commits
#   tp_assert_flags_inside_txn <sql> <flag…>— every dark flag is enabled ONLY strictly inside
#                                             the begin;..rollback; scope (list/loop form; a
#                                             single flag is a one-element call)
#   tp_assert_out_of_scope <sql>            — the proof references no src/ or migrations/ path
#   tp_run_local <name> <sql> <pass-line> <markers>
#                                           — the local-mode psql run + PASS-line + per-marker
#                                             greps ($MARKERS/$PASS_LINE interface; the caller
#                                             asserts its DB_URL env contract first)

fail() { echo "FAIL: $1" >&2; exit 1; }

# ── (1) arg/usage scaffold: shell options + mode validation. Sets the global MODE. ────────────────
tp_init() {
  set -uo pipefail
  set +x
  MODE="${1:-}"
  case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac
}

# ── (2) self-rolling-back: opens a txn, ends in ROLLBACK, and NEVER commits. ──────────────────────
#    ROLLBACK must also be the last STATEMENT, not merely the last txn verb: psql AUTOCOMMITS any
#    statement placed after the final rollback; (it runs OUTSIDE the txn), so trailing SQL would
#    silently persist state — only comments/whitespace may follow.
tp_assert_self_rolling_back() {
  local sql="$1" last_verb rollback_ln same_line_rest trailing
  grep -qiE '^[[:space:]]*begin;' "$sql"    || fail "harness does not open a transaction (begin;)"
  grep -qiE '^[[:space:]]*rollback;' "$sql" || fail "harness does not end in ROLLBACK"
  # last SQL statement must be the ROLLBACK (strip any inline comment before matching).
  last_verb="$(grep -iE '^[[:space:]]*(commit|rollback);' "$sql" | tail -1 | sed -E 's/--.*//' | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  [ "$last_verb" = "rollback;" ] || fail "final transaction verb is not ROLLBACK (got '$last_verb')"
  # NO COMMIT anywhere (a stray commit would persist test state / a flag flip).
  grep -qiE '^[[:space:]]*commit;' "$sql" && fail "harness contains a COMMIT (must never persist state)" || true
  # NOTHING but comments/whitespace may follow the final ROLLBACK — on its own line or any later one.
  rollback_ln="$(grep -niE '^[[:space:]]*rollback;' "$sql" | tail -1 | cut -d: -f1)"
  same_line_rest="$(sed -n "${rollback_ln}p" "$sql" | sed -E 's/^[[:space:]]*[Rr][Oo][Ll][Ll][Bb][Aa][Cc][Kk];//' | sed -E 's/--.*//' | tr -d '[:space:]')"
  [ -z "$same_line_rest" ] || fail "SQL follows the final ROLLBACK on its line (would autocommit outside the txn)"
  trailing="$(tail -n +"$((rollback_ln + 1))" "$sql" | sed -E 's/--.*//' | tr -d '[:space:]')"
  [ -z "$trailing" ] || fail "SQL follows the final ROLLBACK (would autocommit outside the txn)"
}

# ── (3) the dark flags are toggled ONLY inside the txn (between begin; and rollback;). ────────────
#    The committed/production flag values are never written outside the txn (no COMMIT above
#    guarantees revert).
tp_assert_flags_inside_txn() {
  local sql="$1" begin_ln rollback_ln flag flag_ln
  shift
  begin_ln="$(grep -niE '^[[:space:]]*begin;' "$sql" | head -1 | cut -d: -f1)"
  rollback_ln="$(grep -niE '^[[:space:]]*rollback;' "$sql" | tail -1 | cut -d: -f1)"
  for flag in "$@"; do
    grep -qE "update public\.game_config set value='true'::jsonb where key='$flag';" "$sql" \
      || fail "harness does not enable the dark flag '$flag' inside the txn"
    # EVERY occurrence (not just the first) must sit strictly inside begin;..rollback; — a second
    # toggle appended after the ROLLBACK would autocommit outside the txn and persist the flag.
    while IFS= read -r flag_ln; do
      { [ "$begin_ln" -lt "$flag_ln" ] && [ "$flag_ln" -lt "$rollback_ln" ]; } \
        || fail "a '$flag' toggle is not strictly inside begin;..rollback;"
    done < <(grep -nE "set value='true'::jsonb where key='$flag'" "$sql" | cut -d: -f1)
  done
}

# ── (4) does NOT touch src/ or migrations. ────────────────────────────────────────────────────────
tp_assert_out_of_scope() {
  grep -qiE '\.\./src|/src/|migrations/' "$1" && fail "proof references src/ or migrations (out of scope)" || true
}

# ── (5) local: run the write-then-ROLLBACK proof against a disposable DB_URL, then assert the
#    PASS line + every property marker in the output. The caller asserts its DB_URL contract
#    (`: "${DB_URL:?…}"`) before calling, so the diagnostic names the script, not this lib.
tp_run_local() {
  local name="$1" sql="$2" pass_line="$3" markers="$4" out m
  out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$sql" 2>&1)" || { echo "$out" >&2; fail "real-chain $name proof failed"; }
  printf '%s\n' "$out"
  # Here-strings, NOT `printf | grep -q`: under `set -o pipefail`, grep -q exits on first match
  # while printf is still writing, printf takes EPIPE, and pipefail turns a MATCHED grep into a
  # failed pipeline — a race that intermittently reports a PRESENT marker as missing on large
  # output (the team-command proof's marker stream is the biggest). A here-string has no pipe.
  grep -q "$pass_line" <<<"$out" || fail "proof did not report PASS"
  for m in $markers; do
    grep -q "$m" <<<"$out" || fail "proof missing marker $m"
  done
}
