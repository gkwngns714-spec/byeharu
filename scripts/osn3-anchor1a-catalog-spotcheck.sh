#!/usr/bin/env bash
# OSN-ANCHOR-1A — dedicated, STRICTLY READ-ONLY catalog-parity spotcheck for the deployed truthful-origin
# resolver public.mainship_space_resolve_origin(uuid) (migration 0062). Two modes:
#
#   local       Build nothing here (the workflow boots the disposable 0001..0062 stack and passes DB_URL).
#               Proves the script can: produce the RAW catalog function hash; validate the resolver security
#               posture; assert the migration chain ends exactly at 0062 with no 0063+; and REJECT a synthetic
#               mismatched hash WITHOUT normalization. Touches NO production env / secret / project / DB.
#
#   production  Computes the REFERENCE hash from the disposable local chain ($DB_URL) AND, inside an explicit
#               READ ONLY transaction, reads the LIVE resolver functiondef/descriptor/flags + remote migration
#               history. Passes ONLY when the raw catalog hashes are byte-identical AND descriptor/flags/
#               migration state are exactly correct.
#
# HARD READ-ONLY: never writes, never runs a migration / db push / db reset, never calls a player RPC, never
# seeds or creates fixtures, never prints raw function text / base64 / secrets / connection strings. Only
# SHA-256 hashes + safe boolean/short descriptor metadata are emitted. Reuses the live-spotcheck pooler
# connection-discovery pattern (scripts/osn3-s6a-live-check.sh); invents no new secret scheme.
set -uo pipefail

MODE="${1:-}"
case "$MODE" in local|production) : ;; *) echo "usage: $0 <local|production>"; exit 2;; esac
fail() { echo "FAIL: $1"; exit 1; }

REGPROC="'public.mainship_space_resolve_origin(uuid)'::regprocedure"
EXPECT_ARGS='p_main_ship_id uuid'

# ── Single READ ONLY catalog read over a psql conninfo. Emits ONLY safe markers (hash is base64-of-raw,
#    consumed locally then discarded — never printed). `-A` uses '|' as the column separator; the caller
#    splits on '|' so the multi-column descriptor row parses cleanly. ──
catalog_readonly() {
  PGCONNECT_TIMEOUT=20 psql "$1" -X -t -A -v ON_ERROR_STOP=1 <<SQL
begin transaction read only;
select 'RO=' || current_setting('transaction_read_only');
select 'HASHB64=' || translate(encode(convert_to(pg_get_functiondef(${REGPROC}),'UTF8'),'base64'), E'\n\r', '');
select 'ARGS=' || pg_get_function_identity_arguments(p.oid),
       'OWNER=' || pg_get_userbyid(p.proowner),
       'SECDEF=' || p.prosecdef::text,
       'SPPUB=' || (p.proconfig is not null and 'search_path=public' = any(p.proconfig))::text,
       'SRVX=' || has_function_privilege('service_role',p.oid,'EXECUTE')::text,
       'ANONX=' || has_function_privilege('anon',p.oid,'EXECUTE')::text,
       'AUTHX=' || has_function_privilege('authenticated',p.oid,'EXECUTE')::text,
       'ACLNULL=' || (p.proacl is null)::text,
       'PUBX=' || coalesce((select bool_or(a.grantee=0) from aclexplode(p.proacl) a where a.privilege_type='EXECUTE'), false)::text
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='mainship_space_resolve_origin'
    and pg_get_function_identity_arguments(p.oid)='p_main_ship_id uuid';
select 'FLAG_SEND=' || (value#>>'{}') from game_config where key='mainship_send_enabled';
select 'FLAG_SPACE=' || (value#>>'{}') from game_config where key='mainship_space_movement_enabled';
commit;
SQL
}

# marker FROM raw-output: get the value of KEY= (first match) from a '|'-and-newline-split stream
mval() { printf '%s' "$1" | tr '|' '\n' | sed -n "s/^$2=//p" | head -1; }

# Compute SHA-256 of the EXACT raw function bytes from a base64 marker; emits the hash only.
hash_from_b64() { printf '%s' "$1" | base64 -d | sha256sum | awk '{print $1}'; }

# Validate the resolver descriptor markers against the required posture. Prints only safe metadata.
assert_descriptor() {
  local out="$1" label="$2"
  local args owner secdef sppub srvx anonx authx aclnull pubx
  args="$(mval "$out" ARGS)"; owner="$(mval "$out" OWNER)"; secdef="$(mval "$out" SECDEF)"
  sppub="$(mval "$out" SPPUB)"; srvx="$(mval "$out" SRVX)"; anonx="$(mval "$out" ANONX)"
  authx="$(mval "$out" AUTHX)"; aclnull="$(mval "$out" ACLNULL)"; pubx="$(mval "$out" PUBX)"
  echo "[$label] args='$args' owner=$owner secdef=$secdef search_path_public=$sppub service_role_x=$srvx anon_x=$anonx authenticated_x=$authx acl_is_null=$aclnull public_x=$pubx"
  [ "$args" = "$EXPECT_ARGS" ] || fail "[$label] signature drift: '$args'"
  [ "$owner" = "postgres" ]    || fail "[$label] owner=$owner (expected postgres)"
  [ "$secdef" = "t" ] || [ "$secdef" = "true" ] || fail "[$label] not SECURITY DEFINER ($secdef)"
  [ "$sppub" = "t" ] || [ "$sppub" = "true" ] || fail "[$label] search_path not pinned to public ($sppub)"
  [ "$srvx" = "t" ] || [ "$srvx" = "true" ] || fail "[$label] service_role lacks execute ($srvx)"
  [ "$anonx" = "f" ] || [ "$anonx" = "false" ] || fail "[$label] anon HAS execute ($anonx)"
  [ "$authx" = "f" ] || [ "$authx" = "false" ] || fail "[$label] authenticated HAS execute ($authx)"
  # PUBLIC must not have execute: a NULL ACL means the default (PUBLIC EXECUTE) → unsafe; an explicit ACL
  # must contain no grantee=0 EXECUTE. (anon/authenticated effective checks above also catch the null-ACL
  # case, since both inherit PUBLIC — belt and suspenders.)
  [ "$aclnull" = "f" ] || [ "$aclnull" = "false" ] || fail "[$label] proacl is NULL → PUBLIC has default execute"
  [ "$pubx" = "f" ] || [ "$pubx" = "false" ] || fail "[$label] PUBLIC has an explicit execute grant ($pubx)"
  echo "[$label] descriptor OK: signature/owner/SECDEF/search_path=public/service_role-only; anon,authenticated,PUBLIC denied"
}

# Repository migration-history check: highest version == 0062, no 0063+.
assert_repo_migrations_through_0062() {
  local high cnt_after
  high="$(ls supabase/migrations/*.sql 2>/dev/null | sed 's#.*/##' | grep -oE '^[0-9]+' | sort | tail -1)"
  [ -n "$high" ] || fail "no migrations found in repo"
  echo "[repo] highest migration version = $high"
  [ "$high" = "20260618000062" ] || fail "[repo] highest migration = $high (expected 20260618000062)"
  cnt_after="$(ls supabase/migrations/*.sql 2>/dev/null | sed 's#.*/##' | grep -oE '^[0-9]+' | awk '$1 > 20260618000062' | wc -l | tr -d ' ')"
  [ "$cnt_after" = "0" ] || fail "[repo] found $cnt_after migration(s) after 0062 (no 0063+ allowed)"
  echo "[repo] OK: repository migration history ends exactly at 0062, no 0063+"
}

# Exact (no-normalization) hash comparator used for the synthetic mismatch proof + prod equivalence.
hash_equal() { [ "$1" = "$2" ]; }

# ── LOCAL DISPOSABLE PROOF ────────────────────────────────────────────────────────────────────────────
if [ "$MODE" = "local" ]; then
  : "${DB_URL:?DB_URL (local disposable stack) required}"
  echo "=== local: produce raw resolver hash + descriptor from the disposable 0001..0062 chain ==="
  out="$(catalog_readonly "$DB_URL")" || fail "local catalog read failed"
  [ "$(mval "$out" RO)" = "on" ] || fail "local read-only transaction not active (RO=$(mval "$out" RO))"
  b64="$(mval "$out" HASHB64)"; [ -n "$b64" ] || fail "could not obtain resolver functiondef (is 0062 applied locally?)"
  LOCAL_HASH="$(hash_from_b64 "$b64")"; unset b64
  echo "[local] resolver raw catalog SHA-256 = $LOCAL_HASH"
  assert_descriptor "$out" local

  echo "=== local: migration history ends exactly at 0062 (repo) ==="
  assert_repo_migrations_through_0062

  echo "=== local: synthetic mismatch is REJECTED without normalization ==="
  BOGUS="0000000000000000000000000000000000000000000000000000000000000000"
  if hash_equal "$LOCAL_HASH" "$BOGUS"; then fail "comparator ACCEPTED a synthetic mismatch"; fi
  echo "[local] OK: comparator rejected a deliberately mismatched hash (exact compare, no normalization)"
  # also prove the comparator is exact: the same hash compares equal to itself
  hash_equal "$LOCAL_HASH" "$LOCAL_HASH" || fail "comparator rejected identical hashes"

  echo "OSN-ANCHOR-1A CATALOG SPOTCHECK (LOCAL DISPOSABLE PROOF): ALL PASSED"
  exit 0
fi

# ── PRODUCTION READ-ONLY EQUIVALENCE ──────────────────────────────────────────────────────────────────
# Required env (reused from the approved live-spotcheck infra): a local disposable DB_URL for the reference,
# plus the production read-only access secrets.
: "${DB_URL:?DB_URL (disposable reference stack) required}"
: "${SUPABASE_DB_PASSWORD:?}" "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}"
REF="$SUPABASE_PROJECT_ID"

echo "=== production: reference resolver hash + descriptor from the disposable 0001..0062 chain ==="
ref_out="$(catalog_readonly "$DB_URL")" || fail "reference catalog read failed"
[ "$(mval "$ref_out" RO)" = "on" ] || fail "reference read-only transaction not active"
ref_b64="$(mval "$ref_out" HASHB64)"; [ -n "$ref_b64" ] || fail "reference resolver functiondef unavailable (0062 applied locally?)"
REF_HASH="$(hash_from_b64 "$ref_b64")"; unset ref_b64
echo "[reference] resolver raw catalog SHA-256 = $REF_HASH"
assert_descriptor "$ref_out" reference
assert_repo_migrations_through_0062

echo "=== production: discover a READ-ONLY pooler connection (no credentials printed) ==="
command -v psql >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client >/dev/null; }
POOLER=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" "https://api.supabase.com/v1/projects/$REF/config/database/pooler" || true)
PHOST=$(echo "$POOLER" | jq -r 'if type=="array" then .[0].db_host else .db_host end // empty' 2>/dev/null || true)
PPORT=$(echo "$POOLER" | jq -r 'if type=="array" then (.[0].db_port|tostring) else (.db_port|tostring) end // empty' 2>/dev/null || true)
PUSER=$(echo "$POOLER" | jq -r 'if type=="array" then .[0].db_user else .db_user end // empty' 2>/dev/null || true)
REGION=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" "https://api.supabase.com/v1/projects" \
         | jq -r --arg ref "$REF" '.[] | select(.id==$ref) | .region' 2>/dev/null || true)
echo "[diag] pooler_host=${PHOST:-<none>} pooler_port=${PPORT:-<none>} region=${REGION:-<none>}"
CANDS=()
[ -n "${PHOST:-}" ] && CANDS+=("$PHOST|${PPORT:-6543}|${PUSER:-postgres.$REF}")
if [ -n "${REGION:-}" ]; then for pre in aws-0 aws-1; do for prt in 6543 5432; do CANDS+=("$pre-$REGION.pooler.supabase.com|$prt|postgres.$REF"); done; done; fi
CANDS+=("db.$REF.supabase.co|5432|postgres")
CONN=""
for c in "${CANDS[@]}"; do
  IFS='|' read -r H P U <<<"$c"
  if PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=12 psql "host=$H port=$P user=$U dbname=postgres sslmode=require" -X -t -A -c "select 1" >/dev/null 2>/dev/null; then
    CONN="host=$H port=$P user=$U dbname=postgres sslmode=require"; echo "[diag] connected via $H:$P"; break
  fi
done
[ -n "$CONN" ] || fail "could not establish a read-only connection to production"

echo "=== production: LIVE resolver hash + descriptor + flags inside BEGIN TRANSACTION READ ONLY ==="
prod_out="$(PGPASSWORD="$SUPABASE_DB_PASSWORD" catalog_readonly "$CONN")" || fail "live catalog read failed"
[ "$(mval "$prod_out" RO)" = "on" ] || fail "PRODUCTION read-only transaction was NOT active (RO=$(mval "$prod_out" RO))"
echo "[production] proven: all production SQL ran after BEGIN TRANSACTION READ ONLY (transaction_read_only=on)"
prod_b64="$(mval "$prod_out" HASHB64)"; [ -n "$prod_b64" ] || fail "live resolver functiondef unavailable"
PROD_HASH="$(hash_from_b64 "$prod_b64")"; unset prod_b64
echo "[production] resolver raw catalog SHA-256 = $PROD_HASH"
assert_descriptor "$prod_out" production

echo "=== production: flags (read-only, no mutation) ==="
PSEND="$(mval "$prod_out" FLAG_SEND)"; PSPACE="$(mval "$prod_out" FLAG_SPACE)"
echo "[production] mainship_send_enabled=$PSEND mainship_space_movement_enabled=$PSPACE"
[ "$PSEND" = "true" ]   || fail "mainship_send_enabled=$PSEND (expected true)"
[ "$PSPACE" = "false" ] || fail "mainship_space_movement_enabled=$PSPACE (expected false)"

echo "=== production: remote migration history ends exactly at 0062 (no 0063+) ==="
supabase migration list --linked --password "$SUPABASE_DB_PASSWORD" 2>/dev/null | tee /tmp/anchor1a_migs >/dev/null || fail "migration list --linked failed"
REMOTE_HIGH="$(awk -F'|' '{r=$2; gsub(/[^0-9]/,"",r); if (length(r)>0) print r}' /tmp/anchor1a_migs | sort | tail -1)"
echo "[production] highest REMOTE migration version = ${REMOTE_HIGH:-<none>}"
[ "$REMOTE_HIGH" = "20260618000062" ] || fail "remote highest migration = ${REMOTE_HIGH:-<none>} (expected 20260618000062)"
if awk -F'|' '{r=$2; gsub(/[^0-9]/,"",r); if (length(r)>0 && r+0 > 20260618000062) print r}' /tmp/anchor1a_migs | grep -q .; then
  fail "remote migration history contains a version after 0062 (no 0063+ allowed)"
fi
echo "[production] OK: remote migration history ends exactly at 0062, no 0063+"

echo "=== production: EXACT raw-catalog hash equivalence (no normalization) ==="
echo "[compare] reference=$REF_HASH production=$PROD_HASH"
if ! hash_equal "$REF_HASH" "$PROD_HASH"; then
  echo "MISMATCH: the deployed resolver definition differs from the disposable 0062 reference."
  echo "  reference_sha256 = $REF_HASH"
  echo "  production_sha256 = $PROD_HASH"
  echo "  (raw function text deliberately NOT printed; no normalization attempted; failing without retry)"
  exit 1
fi
echo "[compare] OK: production resolver raw catalog definition is byte-identical to the disposable 0062 reference"

echo "OSN-ANCHOR-1A CATALOG SPOTCHECK (PRODUCTION READ-ONLY EQUIVALENCE): ALL PASSED"
