#!/usr/bin/env bash
# OSN-ANCHOR-1A — dedicated, STRICTLY READ-ONLY catalog-parity spotcheck for the deployed truthful-origin
# resolver public.mainship_space_resolve_origin(uuid) (migration 0062). Two modes:
#
#   local       Uses the disposable 0001..0062 stack ($DB_URL). Proves the script can produce the RAW catalog
#               function hash, validate the resolver security posture, assert migrations end exactly at 0062
#               (no 0063+), reject a synthetic mismatched hash WITHOUT normalization, and (self-tests) reject
#               malformed/empty hash input + bad project refs + external target overrides. NO production
#               env / secret / project / DB is referenced.
#
#   production  Computes the REFERENCE hash from the disposable local chain ($DB_URL) AND, over a direct,
#               ref-derived, hostname-verified-TLS production connection inside ONE explicit READ ONLY
#               transaction (gated BEFORE any catalog query), reads the LIVE resolver functiondef/descriptor/
#               flags. Verifies the protected link-state, then `supabase migration list --linked` (CLI
#               metadata). Passes ONLY when the raw catalog hashes are byte-identical AND descriptor/flags/
#               migration state are exactly correct.
#
# HARD READ-ONLY: never writes, never runs db push / db reset / migration apply / RPC / fixtures, never prints
# raw function text / base64 / secrets / connection strings / DB URLs. Only SHA-256 hashes + safe boolean/
# short descriptor metadata are emitted.
set -euo pipefail

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in local|production) : ;; *) echo "usage: $0 <local|production>" >&2; exit 2;; esac

REGPROC="'public.mainship_space_resolve_origin(uuid)'::regprocedure"
EXPECT_ARGS='p_main_ship_id uuid'
EXPECT_MIG='20260618000062'

# ── Fail-closed validators (Defect 1) ──────────────────────────────────────────────────────────────────
is_hex64() { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{64}$'; }
# A Supabase project ref is exactly 20 lowercase alphanumeric chars.
validate_ref() { printf '%s' "${1:-}" | grep -qE '^[a-z0-9]{20}$' || fail "invalid/empty project ref"; }
# Reject any externally-supplied target-overriding env var (production mode) before connecting (Defect 3).
reject_target_overrides() {
  local v
  for v in DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGSSLMODE PGHOSTADDR PGSERVICE PGURI; do
    [ -z "${!v:-}" ] || fail "external target override $v is set — refusing to run in production mode"
  done
}

# ── Governed read-only SQL (Defect 4): the read-only gate runs BEFORE any resolver/ACL/flag query. ─────
governed_sql() {
  cat <<SQL
\\set ON_ERROR_STOP on
\\pset pager off
begin transaction read only;
select current_setting('transaction_read_only') = 'on' as ro_ok \\gset
\\if :ro_ok
\\else
\\echo 'ERROR: transaction is not read-only'
\\quit 1
\\endif
select 'RO=' || current_setting('transaction_read_only');
select 'HASHB64=' || translate(encode(convert_to(pg_get_functiondef(${REGPROC}),'UTF8'),'base64'), E'\\n\\r', '');
select 'ARGS=' || pg_get_function_identity_arguments(p.oid),
       'OWNER=' || pg_get_userbyid(p.proowner),
       'SECDEF=' || p.prosecdef::text,
       'SPPUB=' || (p.proconfig is not null and 'search_path=public' = any(p.proconfig))::text,
       'SRVX=' || has_function_privilege('service_role',p.oid,'EXECUTE')::text,
       'ANONX=' || has_function_privilege('anon',p.oid,'EXECUTE')::text,
       'AUTHX=' || has_function_privilege('authenticated',p.oid,'EXECUTE')::text,
       'ACLNULL=' || (p.proacl is null)::text,
       'PUBX=' || coalesce((select bool_or(a.grantee=0) from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.privilege_type='EXECUTE'), false)::text
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='mainship_space_resolve_origin'
    and pg_get_function_identity_arguments(p.oid)='p_main_ship_id uuid';
select 'FLAG_SEND=' || (value#>>'{}') from game_config where key='mainship_send_enabled';
select 'FLAG_SPACE=' || (value#>>'{}') from game_config where key='mainship_space_movement_enabled';
commit;
SQL
}

# Run the governed session over a psql conninfo (the connection itself is the only reachability test).
catalog_readonly() { governed_sql | PGCONNECT_TIMEOUT=20 psql "$1" -X -v ON_ERROR_STOP=1 -t -A; }

# marker FROM raw output ('|' + newline split). Reads line-by-line (no pipe-to-early-exit) so it is safe
# under `set -e -o pipefail`. Returns the value after the first "$2=" prefix.
mval() {
  local all l; all="$(printf '%s' "${1:-}" | tr '|' '\n')"
  while IFS= read -r l; do
    case "$l" in "$2="*) printf '%s' "${l#"$2"=}"; return 0;; esac
  done <<< "$all"
  return 0
}

# Compute a validated SHA-256 of the EXACT raw function bytes from a base64 marker (fail-closed; hash only).
compute_hash() {
  local b="${1:-}" raw h
  [ -n "$b" ] || fail "empty base64 catalog payload"
  raw="$(printf '%s' "$b" | base64 -d 2>/dev/null || true)"
  [ -n "$raw" ] || fail "decoded catalog bytes are empty (corrupt/invalid base64)"
  h="$(printf '%s' "$raw" | sha256sum | awk '{print $1}')"
  is_hex64 "$h" || fail "computed SHA-256 is not 64 lowercase hex"
  printf '%s' "$h"
}

assert_descriptor() {
  local out="$1" label="$2" args owner secdef sppub srvx anonx authx aclnull pubx
  args="$(mval "$out" ARGS)"; owner="$(mval "$out" OWNER)"; secdef="$(mval "$out" SECDEF)"
  sppub="$(mval "$out" SPPUB)"; srvx="$(mval "$out" SRVX)"; anonx="$(mval "$out" ANONX)"
  authx="$(mval "$out" AUTHX)"; aclnull="$(mval "$out" ACLNULL)"; pubx="$(mval "$out" PUBX)"
  echo "[$label] args='$args' owner=$owner secdef=$secdef search_path_public=$sppub service_role_x=$srvx anon_x=$anonx authenticated_x=$authx acl_is_null=$aclnull public_x=$pubx"
  # boolean markers come from `::text` casts → the literals 'true'/'false' (accept 't'/'f' too defensively).
  is_true()  { [ "${1:-}" = "true" ]  || [ "${1:-}" = "t" ]; }
  is_false() { [ "${1:-}" = "false" ] || [ "${1:-}" = "f" ]; }
  [ "$args" = "$EXPECT_ARGS" ] || fail "[$label] signature drift: '$args'"
  [ "$owner" = "postgres" ]    || fail "[$label] owner=$owner (expected postgres)"
  is_true  "$secdef"  || fail "[$label] not SECURITY DEFINER ($secdef)"
  is_true  "$sppub"   || fail "[$label] search_path not pinned to public ($sppub)"
  is_true  "$srvx"    || fail "[$label] service_role lacks execute ($srvx)"
  is_false "$anonx"   || fail "[$label] anon HAS execute ($anonx)"
  is_false "$authx"   || fail "[$label] authenticated HAS execute ($authx)"
  # Effective PUBLIC: PUBX is computed over aclexplode(coalesce(proacl, acldefault('f',proowner))) so a NULL
  # ACL expands to the function default (PUBLIC EXECUTE) and is detected; acl_is_null reported for clarity.
  is_false "$pubx"    || fail "[$label] PUBLIC has effective execute ($pubx; acl_is_null=$aclnull)"
  echo "[$label] descriptor OK: signature/owner/SECDEF/search_path=public/service_role-only; anon,authenticated,PUBLIC denied (effective)"
}

assert_repo_migrations_through_0062() {
  local high cnt_after
  high="$(ls supabase/migrations/*.sql 2>/dev/null | sed 's#.*/##' | grep -oE '^[0-9]+' | sort | tail -1 || true)"
  [ -n "$high" ] || fail "no migrations found in repo"
  echo "[repo] highest migration version = $high"
  [ "$high" = "$EXPECT_MIG" ] || fail "[repo] highest migration = $high (expected $EXPECT_MIG)"
  cnt_after="$(ls supabase/migrations/*.sql 2>/dev/null | sed 's#.*/##' | grep -oE '^[0-9]+' | awk -v e="$EXPECT_MIG" '$1+0 > e+0' | wc -l | tr -d ' ' || true)"
  [ "$cnt_after" = "0" ] || fail "[repo] found $cnt_after migration(s) after 0062 (no 0063+ allowed)"
  echo "[repo] OK: repository migration history ends exactly at 0062, no 0063+"
}

hash_equal() { [ "$1" = "$2" ]; }

# ── LOCAL DISPOSABLE PROOF + SELF-TESTS ────────────────────────────────────────────────────────────────
if [ "$MODE" = "local" ]; then
  : "${DB_URL:?DB_URL (local disposable stack) required}"
  echo "=== local: raw resolver hash + descriptor from the disposable 0001..0062 chain ==="
  out="$(catalog_readonly "$DB_URL")" || fail "local catalog read failed"
  [ "$(mval "$out" RO)" = "on" ] || fail "local read-only transaction not active"
  LOCAL_HASH="$(compute_hash "$(mval "$out" HASHB64)")"
  echo "[local] resolver raw catalog SHA-256 = $LOCAL_HASH"
  assert_descriptor "$out" local
  echo "=== local: migration history ends exactly at 0062 (repo) ==="
  assert_repo_migrations_through_0062

  echo "=== local: synthetic mismatch is REJECTED without normalization ==="
  if hash_equal "$LOCAL_HASH" "0000000000000000000000000000000000000000000000000000000000000000"; then fail "comparator ACCEPTED a synthetic mismatch"; fi
  hash_equal "$LOCAL_HASH" "$LOCAL_HASH" || fail "comparator rejected identical hashes"
  echo "[local] OK: comparator rejects a deliberately mismatched hash and accepts an identical one (exact, no normalization)"

  echo "=== local self-tests: malformed/empty input + bad ref + target overrides all fail-closed ==="
  if ( compute_hash "" ) >/dev/null 2>&1; then fail "selftest: empty base64 not rejected"; fi
  echo "[selftest] OK: empty base64 rejected"
  if ( compute_hash "@@@not-base64@@@" ) >/dev/null 2>&1; then fail "selftest: malformed base64 not rejected"; fi
  echo "[selftest] OK: malformed base64 rejected"
  if is_hex64 "deadbeef"; then fail "selftest: is_hex64 accepted a short hash"; fi
  is_hex64 "$LOCAL_HASH" || fail "selftest: is_hex64 rejected a valid hash"
  echo "[selftest] OK: SHA-256 must be exactly 64 lowercase hex"
  if ( validate_ref "" ) >/dev/null 2>&1; then fail "selftest: empty ref not rejected"; fi
  if ( validate_ref "TOO-SHORT" ) >/dev/null 2>&1; then fail "selftest: malformed ref not rejected"; fi
  echo "[selftest] OK: empty/malformed project ref rejected"
  for v in DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGSSLMODE PGHOSTADDR; do
    if ( export "$v=override-attempt"; reject_target_overrides ) >/dev/null 2>&1; then fail "selftest: $v override not rejected"; fi
    echo "[selftest] OK: $v override rejected"
  done
  # the read-only gate must precede every catalog query in the generated SQL (Defect 4)
  sql="$(governed_sql)"
  gate_line="$(printf '%s\n' "$sql" | grep -nm1 'transaction_read_only' | cut -d: -f1 || true)"
  fn_line="$(printf '%s\n' "$sql" | grep -nm1 'pg_get_functiondef' | cut -d: -f1 || true)"
  acl_line="$(printf '%s\n' "$sql" | grep -nm1 'has_function_privilege' | cut -d: -f1 || true)"
  flag_line="$(printf '%s\n' "$sql" | grep -nm1 'mainship_send_enabled' | cut -d: -f1 || true)"
  [ -n "$gate_line" ] && [ -n "$fn_line" ] && [ -n "$acl_line" ] && [ -n "$flag_line" ] || fail "selftest: could not locate gate/query lines"
  [ "$gate_line" -lt "$fn_line" ] && [ "$gate_line" -lt "$acl_line" ] && [ "$gate_line" -lt "$flag_line" ] \
    || fail "selftest: read-only gate (line $gate_line) is NOT before functiondef/$fn_line, acl/$acl_line, flags/$flag_line"
  echo "[selftest] OK: read-only gate (line $gate_line) precedes functiondef ($fn_line), ACL ($acl_line), flags ($flag_line)"

  echo "OSN-ANCHOR-1A CATALOG SPOTCHECK (LOCAL DISPOSABLE PROOF): ALL PASSED"
  exit 0
fi

# ── PRODUCTION READ-ONLY EQUIVALENCE ──────────────────────────────────────────────────────────────────
: "${DB_URL:?DB_URL (disposable reference stack) required}"
: "${SUPABASE_DB_PASSWORD:?}" "${SUPABASE_PROJECT_ID:?}"
REF="$SUPABASE_PROJECT_ID"

# Defect 3: refuse any externally-supplied remote-target override; the production target is ref-derived only.
reject_target_overrides
validate_ref "$REF"

echo "=== production: reference resolver hash + descriptor from the disposable 0001..0062 chain ==="
ref_out="$(catalog_readonly "$DB_URL")" || fail "reference catalog read failed"
[ "$(mval "$ref_out" RO)" = "on" ] || fail "reference read-only transaction not active"
REF_HASH="$(compute_hash "$(mval "$ref_out" HASHB64)")"
echo "[reference] resolver raw catalog SHA-256 = $REF_HASH"
assert_descriptor "$ref_out" reference
assert_repo_migrations_through_0062

# Defect 2: the workflow ran `supabase link`; verify the local link-state ref equals the protected secret.
echo "=== production: verify protected link-state (linked ref == SUPABASE_PROJECT_ID) ==="
linked_ref="$(cat supabase/.temp/project-ref 2>/dev/null || true)"
[ -n "$linked_ref" ] || fail "no linked project ref (supabase link did not run before this step)"
[ "$linked_ref" = "$REF" ] || fail "linked project ref does NOT match the protected SUPABASE_PROJECT_ID"
echo "[production] OK: linked project ref matches the protected SUPABASE_PROJECT_ID"

# Defect 3: direct, ref-derived endpoint with hostname-verified TLS. No pooler, no weaker sslmode, no fallback.
command -v psql >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client >/dev/null; }
PHOST="db.${REF}.supabase.co"
CONN="host=${PHOST} port=5432 user=postgres dbname=postgres sslmode=verify-full sslrootcert=system"
echo "[diag] production target host (ref-derived, verify-full TLS) = ${PHOST}"

echo "=== production: LIVE resolver hash + descriptor + flags inside one READ ONLY transaction ==="
prod_out="$(PGPASSWORD="$SUPABASE_DB_PASSWORD" catalog_readonly "$CONN")" \
  || fail "live catalog read failed over the direct endpoint ${PHOST} with verify-full (see connectivity note in the workflow/report)"
[ "$(mval "$prod_out" RO)" = "on" ] || fail "PRODUCTION read-only gate did not report on"
echo "[production] proven: the read-only gate passed before any catalog query (transaction_read_only=on)"
PROD_HASH="$(compute_hash "$(mval "$prod_out" HASHB64)")"
echo "[production] resolver raw catalog SHA-256 = $PROD_HASH"
assert_descriptor "$prod_out" production

echo "=== production: flags (read-only, no mutation) ==="
PSEND="$(mval "$prod_out" FLAG_SEND)"; PSPACE="$(mval "$prod_out" FLAG_SPACE)"
echo "[production] mainship_send_enabled=$PSEND mainship_space_movement_enabled=$PSPACE"
[ "$PSEND" = "true" ]   || fail "mainship_send_enabled=$PSEND (expected true)"
[ "$PSPACE" = "false" ] || fail "mainship_space_movement_enabled=$PSPACE (expected false)"

echo "=== production: remote migration history ends exactly at 0062 (no 0063+) ==="
supabase migration list --linked --password "$SUPABASE_DB_PASSWORD" 2>/dev/null > /tmp/anchor1a_migs \
  || fail "supabase migration list --linked failed (project not linked?)"
REMOTE_HIGH="$(awk -F'|' '{r=$2; gsub(/[^0-9]/,"",r); if (length(r)>0) print r}' /tmp/anchor1a_migs | sort | tail -1 || true)"
[ -n "$REMOTE_HIGH" ] || fail "could not parse a remote migration version (empty/malformed migration list)"
echo "[production] highest REMOTE migration version = $REMOTE_HIGH"
[ "$REMOTE_HIGH" = "$EXPECT_MIG" ] || fail "remote highest migration = $REMOTE_HIGH (expected $EXPECT_MIG)"
LATER="$(awk -F'|' -v e="$EXPECT_MIG" '{r=$2; gsub(/[^0-9]/,"",r); if (length(r)>0 && r+0 > e+0) print r}' /tmp/anchor1a_migs || true)"
[ -z "$LATER" ] || fail "remote migration history contains a version after 0062 (no 0063+ allowed): $LATER"
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
