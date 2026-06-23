#!/usr/bin/env bash
# OSN-ANCHOR-1A — dedicated, STRICTLY READ-ONLY catalog-parity spotcheck for the deployed truthful-origin
# resolver public.mainship_space_resolve_origin(uuid) (migration 0062). Two modes:
#
#   local       Uses the disposable 0001..0062 stack ($DB_URL). Proves the script can produce the raw stored
#               PL/pgSQL body hash, validate the resolver security posture (incl. language=plpgsql), assert
#               migrations end exactly at 0062, reject a synthetic mismatch WITHOUT normalization, and
#               (self-tests) reject malformed input / bad refs / target overrides / unbound pooler tenants /
#               bad pooler ports / ambiguous Management-API shapes, build a full descriptor record, and detect
#               an injected mismatch in EVERY descriptor field. NO production env / secret / project / DB.
#
#   production  Computes the REFERENCE descriptor + stored-body hash from the disposable local chain ($DB_URL)
#               AND, over the approved IPv4 pooler (host from the Management API keyed by the protected ref;
#               tenant bound via user=postgres.<ref>; sslmode=verify-full) inside ONE explicit READ ONLY
#               transaction (gated BEFORE any catalog query), reads the LIVE descriptor + stored body + flags.
#               Passes ONLY when the raw stored-body hashes are byte-identical, the full descriptor record is
#               field-by-field identical local-vs-production, the fixed security invariants hold, and the
#               migration/flag state is exactly correct.
#
# EQUALITY SOURCE = p.prosrc (the raw STORED PL/pgSQL body) — NOT pg_get_functiondef(), whose deparser output
# is Postgres-version-sensitive. Descriptor fields are the separate semantic-wrapper comparison.
#
# HARD READ-ONLY: never writes, never runs db push / db reset / migration apply / RPC / fixtures, never prints
# stored body / base64 / secrets / connection strings / DB URLs / raw API responses. Only SHA-256 hashes +
# safe catalog descriptor metadata are emitted.
set -euo pipefail

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in local|production) : ;; *) echo "usage: $0 <local|production>" >&2; exit 2;; esac

EXPECT_ARGS='p_main_ship_id uuid'
EXPECT_MIG='20260618000062'
# Ordered descriptor field set compared local-vs-production (catalog-derived values, no OIDs).
DESC_FIELDS="SCHEMA FNAME ARGS RET LANG PROKIND PROVOLATILE PROISSTRICT PROSECDEF PROLEAKPROOF PROPARALLEL PROCONFIG OWNER SRVX ANONX AUTHX PUBX"

# ── Pinned CA trust material (official Supabase Server root CA; PUBLIC trust material, not a secret) ─────
REPO_ROOT="$(git rev-parse --show-toplevel)"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"  # Supabase Root 2021 CA (prod-ca-2021.crt)

# ── Fail-closed validators ─────────────────────────────────────────────────────────────────────────────
is_hex64() { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{64}$'; }
validate_ref() { printf '%s' "${1:-}" | grep -qE '^[a-z0-9]{20}$' || fail "invalid/empty project ref"; }
# Ambient target/trust override variables that must NOT influence the production target or TLS config.
OVERRIDE_VARS="DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGHOSTADDR PGSERVICE PGURI PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL PGPASSWORD"
reject_target_overrides() {
  local v
  for v in $OVERRIDE_VARS; do
    [ -z "${!v:-}" ] || fail "external target/trust override $v is set — refusing to run in production mode"
  done
}
# Normalized SHA-256 of a PEM cert: 64 lowercase hex (strip 'sha256 Fingerprint=', remove colons).
ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z'; }
# Admit the pinned CA: exists, non-empty, exactly one cert, parses, not expired, fingerprint == pinned.
# Logs ONLY fingerprint/subject/notAfter — never certificate contents.
verify_ca() {
  local f="$1" n fp
  [ -f "$f" ] || fail "CA file not found: scripts/supabase-prod-ca.crt"
  [ -s "$f" ] || fail "CA file is empty"
  n="$(grep -c 'BEGIN CERTIFICATE' "$f" || true)"
  [ "$n" = "1" ] || fail "CA file must contain exactly one certificate (found $n)"
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || fail "CA file is not a valid PEM certificate"
  openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 || fail "CA certificate is expired"
  fp="$(ca_fingerprint "$f")"
  is_hex64 "$fp" || fail "CA fingerprint is not 64 lowercase hex"
  [ "$fp" = "$EXPECTED_CA_SHA256" ] || fail "CA fingerprint mismatch (pinned $EXPECTED_CA_SHA256, got $fp)"
  echo "[ca] SHA-256 fingerprint = $fp"
  echo "[ca] subject = $(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  echo "[ca] notAfter = $(openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
}
# Build the verifier connection. Port is FORCED to the SESSION pooler (5432); CA is the pinned tracked file;
# verify-full is mandatory. The Management-API-returned port is NEVER used for the connection.
build_verifier_conn() {  # $1=host $2=ref $3=ca_file
  printf 'host=%s port=5432 user=postgres.%s dbname=postgres sslmode=verify-full sslrootcert=%s' "$1" "$2" "$3"
}
# Strict pooler binding: host must be <label>.pooler.supabase.com; port exactly 5432 or 6543; tenant exactly
# postgres.<protected-ref>. Any miss fails closed.
require_pooler_binding() {
  local h="${1:-}" pt="${2:-}" u="${3:-}" r="${4:-}"
  validate_ref "$r"
  [ -n "$h" ] || fail "pooler host not resolved from protected configuration"
  printf '%s' "$h" | grep -qE '^[a-z0-9][a-z0-9.-]*\.pooler\.supabase\.com$' || fail "host is not a <label>.pooler.supabase.com endpoint"
  case "$pt" in 5432|6543) : ;; *) fail "pooler port '$pt' is not in the permitted set {5432,6543}";; esac
  [ "$u" = "postgres.${r}" ] || fail "pooler tenant user is not bound to the protected project ref"
}
# Parse EXACTLY ONE pooler endpoint from a Management API response. Accepts a single object {db_host,db_port}
# OR a one-element array of it. Any other shape (malformed/missing/empty/0-or-multi-element/nested) errors.
# Echoes 'host|port'. Never prints the raw response.
parse_pooler_endpoint() {
  printf '%s' "${1:-}" | jq -er '
    ( if   type=="array"  then (if length==1 then .[0] else error("array length not exactly 1") end)
      elif type=="object" then .
      else error("unexpected top-level type") end ) as $e
    | ($e.db_host // error("missing db_host")) as $h
    | ($e.db_port // error("missing db_port")) as $p
    | (if ($h|type)=="string" and ($h|length)>0 then . else error("empty/invalid db_host") end)
    | "\($h)|\($p)"
  ' 2>/dev/null
}

# ── Governed read-only SQL: read-only gate BEFORE any catalog query; body hash from raw stored p.prosrc. ──
governed_sql() {
  cat <<'SQL'
\set ON_ERROR_STOP on
\pset pager off
begin transaction read only;
select current_setting('transaction_read_only') = 'on' as ro_ok \gset
\if :ro_ok
\else
\echo 'ERROR: transaction is not read-only'
\quit 1
\endif
select 'RO=' || current_setting('transaction_read_only');
select 'HASHB64=' || translate(encode(convert_to(p.prosrc,'UTF8'),'base64'), E'\n\r', '')
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language  l on l.oid = p.prolang
  where n.nspname='public' and p.proname='mainship_space_resolve_origin'
    and pg_get_function_identity_arguments(p.oid)='p_main_ship_id uuid'
    and l.lanname='plpgsql';
select 'SCHEMA=' || n.nspname,
       'FNAME=' || p.proname,
       'ARGS=' || pg_get_function_identity_arguments(p.oid),
       'RET=' || pg_get_function_result(p.oid),
       'LANG=' || l.lanname,
       'PROKIND=' || p.prokind::text,
       'PROVOLATILE=' || p.provolatile::text,
       'PROISSTRICT=' || p.proisstrict::text,
       'PROSECDEF=' || p.prosecdef::text,
       'PROLEAKPROOF=' || p.proleakproof::text,
       'PROPARALLEL=' || p.proparallel::text,
       'PROCONFIG=' || coalesce(array_to_string(p.proconfig, ','), ''),
       'OWNER=' || pg_get_userbyid(p.proowner),
       'SRVX=' || has_function_privilege('service_role',p.oid,'EXECUTE')::text,
       'ANONX=' || has_function_privilege('anon',p.oid,'EXECUTE')::text,
       'AUTHX=' || has_function_privilege('authenticated',p.oid,'EXECUTE')::text,
       'PUBX=' || coalesce((select bool_or(a.grantee=0) from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.privilege_type='EXECUTE'), false)::text,
       'ACLNULL=' || (p.proacl is null)::text
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language  l on l.oid = p.prolang
  where n.nspname='public' and p.proname='mainship_space_resolve_origin'
    and pg_get_function_identity_arguments(p.oid)='p_main_ship_id uuid';
select 'FLAG_SEND=' || (value#>>'{}') from game_config where key='mainship_send_enabled';
select 'FLAG_SPACE=' || (value#>>'{}') from game_config where key='mainship_space_movement_enabled';
commit;
SQL
}

catalog_readonly() { governed_sql | PGCONNECT_TIMEOUT=20 psql "$1" -X -v ON_ERROR_STOP=1 -t -A; }

mval() {
  local all l; all="$(printf '%s' "${1:-}" | tr '|' '\n')"
  while IFS= read -r l; do
    case "$l" in "$2="*) printf '%s' "${l#"$2"=}"; return 0;; esac
  done <<< "$all"
  return 0
}

compute_hash() {
  local b="${1:-}" raw h
  [ -n "$b" ] || fail "empty base64 catalog payload (resolver missing / not plpgsql / wrong signature?)"
  raw="$(printf '%s' "$b" | base64 -d 2>/dev/null || true)"
  [ -n "$raw" ] || fail "decoded catalog bytes are empty (corrupt/invalid base64)"
  h="$(printf '%s' "$raw" | sha256sum | awk '{print $1}')"
  is_hex64 "$h" || fail "computed SHA-256 is not 64 lowercase hex"
  printf '%s' "$h"
}

is_true()  { [ "${1:-}" = "true" ]  || [ "${1:-}" = "t" ]; }
is_false() { [ "${1:-}" = "false" ] || [ "${1:-}" = "f" ]; }

# Fixed security INVARIANTS (each side must satisfy these regardless of the cross-comparison).
assert_descriptor() {
  local out="$1" label="$2"
  local args lang owner sd sp srvx anonx authx pubx aclnull
  args="$(mval "$out" ARGS)"; lang="$(mval "$out" LANG)"; owner="$(mval "$out" OWNER)"
  sd="$(mval "$out" PROSECDEF)"; sp="$(mval "$out" PROCONFIG)"; srvx="$(mval "$out" SRVX)"
  anonx="$(mval "$out" ANONX)"; authx="$(mval "$out" AUTHX)"; pubx="$(mval "$out" PUBX)"; aclnull="$(mval "$out" ACLNULL)"
  echo "[$label] args='$args' lang=$lang owner=$owner prosecdef=$sd proconfig='$sp' service_role_x=$srvx anon_x=$anonx authenticated_x=$authx public_x=$pubx acl_is_null=$aclnull"
  [ "$args" = "$EXPECT_ARGS" ] || fail "[$label] signature drift: '$args'"
  [ "$lang" = "plpgsql" ]      || fail "[$label] language=$lang (expected plpgsql)"
  [ "$owner" = "postgres" ]    || fail "[$label] owner=$owner (expected postgres)"
  is_true  "$sd"   || fail "[$label] not SECURITY DEFINER ($sd)"
  printf '%s' "$sp" | grep -q 'search_path=public' || fail "[$label] search_path not pinned to public ('$sp')"
  is_true  "$srvx" || fail "[$label] service_role lacks execute ($srvx)"
  is_false "$anonx" || fail "[$label] anon HAS execute ($anonx)"
  is_false "$authx" || fail "[$label] authenticated HAS execute ($authx)"
  is_false "$pubx"  || fail "[$label] PUBLIC has effective execute ($pubx; acl_is_null=$aclnull)"
  echo "[$label] invariants OK: plpgsql/args/owner=postgres/SECDEF/search_path=public/service_role-only; anon,authenticated,PUBLIC denied"
}

# Field-by-field local-vs-production descriptor difference (fails on ANY difference; prints only field +
# safe local/production values — never prosrc/raw text).
diff_descriptors() {
  local rout="$1" pout="$2" f lv pv mismatch=0
  for f in $DESC_FIELDS; do
    lv="$(mval "$rout" "$f")"; pv="$(mval "$pout" "$f")"
    if [ "$lv" != "$pv" ]; then echo "[descriptor-diff] FIELD=$f local='$lv' production='$pv'"; mismatch=1; fi
  done
  [ "$mismatch" = "0" ] || fail "descriptor field-by-field mismatch (see [descriptor-diff] lines)"
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
  echo "=== local: admit the pinned CA trust material (same checks the production path runs) ==="
  verify_ca "$CA_FILE"
  [ "$CA_FILE" = "$(git rev-parse --show-toplevel)/scripts/supabase-prod-ca.crt" ] || fail "CA path is not resolved from the git repo root"
  echo "[local] OK: CA admitted + fingerprint pinned; path is repo-root-resolved (not \$(pwd))"
  echo "=== local: raw stored-body (prosrc) hash + full descriptor from the disposable 0001..0062 chain ==="
  out="$(catalog_readonly "$DB_URL")" || fail "local catalog read failed"
  [ "$(mval "$out" RO)" = "on" ] || fail "local read-only transaction not active"
  LOCAL_HASH="$(compute_hash "$(mval "$out" HASHB64)")"
  echo "[local] resolver raw stored-body SHA-256 = $LOCAL_HASH"
  assert_descriptor "$out" local
  # complete descriptor record (item 9)
  for f in $DESC_FIELDS; do
    [ -n "$(mval "$out" "$f")" ] || [ "$f" = "PROCONFIG" ] || fail "[local] descriptor field $f is empty"
  done
  echo "[local] descriptor record produced for all 17 fields: $DESC_FIELDS"
  echo "=== local: migration history ends exactly at 0062 (repo) ==="
  assert_repo_migrations_through_0062

  echo "=== local: synthetic body-hash mismatch is REJECTED without normalization ==="
  if hash_equal "$LOCAL_HASH" "0000000000000000000000000000000000000000000000000000000000000000"; then fail "comparator ACCEPTED a synthetic mismatch"; fi
  hash_equal "$LOCAL_HASH" "$LOCAL_HASH" || fail "comparator rejected identical hashes"
  echo "[local] OK: body-hash comparator rejects a mismatch and accepts an identical one (exact, no normalization)"

  echo "=== local self-tests ==="
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
  for v in $OVERRIDE_VARS; do
    if ( export "$v=override-attempt"; reject_target_overrides ) >/dev/null 2>&1; then fail "selftest: $v override not rejected"; fi
    echo "[selftest] OK: $v override rejected"
  done
  # Management API response-shape parsing (Blocker 1)
  R="$(parse_pooler_endpoint '{"db_host":"aws-0-x.pooler.supabase.com","db_port":6543}')" || fail "selftest: single object rejected"
  [ "$R" = "aws-0-x.pooler.supabase.com|6543" ] || fail "selftest: single object parse wrong ($R)"
  echo "[selftest] OK: single-object response accepted"
  parse_pooler_endpoint '[{"db_host":"aws-0-x.pooler.supabase.com","db_port":5432}]' >/dev/null || fail "selftest: one-element array rejected"
  echo "[selftest] OK: one-element array response accepted"
  if ( parse_pooler_endpoint '[]' ) >/dev/null 2>&1; then fail "selftest: zero-candidate array not rejected"; fi
  echo "[selftest] OK: zero-candidate array rejected"
  if ( parse_pooler_endpoint '[{"db_host":"a.pooler.supabase.com","db_port":6543},{"db_host":"b.pooler.supabase.com","db_port":6543}]' ) >/dev/null 2>&1; then fail "selftest: multi-candidate array not rejected"; fi
  echo "[selftest] OK: multi-candidate array rejected"
  if ( parse_pooler_endpoint '{"db_port":6543}' ) >/dev/null 2>&1; then fail "selftest: missing host not rejected"; fi
  echo "[selftest] OK: missing db_host rejected"
  if ( parse_pooler_endpoint '{"db_host":"a.pooler.supabase.com"}' ) >/dev/null 2>&1; then fail "selftest: missing port not rejected"; fi
  echo "[selftest] OK: missing db_port rejected"
  if ( parse_pooler_endpoint 'not json' ) >/dev/null 2>&1; then fail "selftest: malformed JSON not rejected"; fi
  echo "[selftest] OK: malformed JSON rejected"
  # pooler binding: host suffix + port set + tenant
  if ( require_pooler_binding "evil.example.com" "6543" "postgres.aaaaaaaaaaaaaaaaaaaa" "aaaaaaaaaaaaaaaaaaaa" ) >/dev/null 2>&1; then fail "selftest: bad host suffix not rejected"; fi
  echo "[selftest] OK: unexpected host suffix rejected"
  if ( require_pooler_binding "aws-0-x.pooler.supabase.com" "9999" "postgres.aaaaaaaaaaaaaaaaaaaa" "aaaaaaaaaaaaaaaaaaaa" ) >/dev/null 2>&1; then fail "selftest: bad port not rejected"; fi
  echo "[selftest] OK: port outside {5432,6543} rejected"
  if ( require_pooler_binding "aws-0-x.pooler.supabase.com" "6543" "postgres.WRONGTENANTxxxxxxx" "aaaaaaaaaaaaaaaaaaaa" ) >/dev/null 2>&1; then fail "selftest: unbound tenant not rejected"; fi
  echo "[selftest] OK: tenant not bound to protected ref rejected"
  require_pooler_binding "aws-0-x.pooler.supabase.com" "5432" "postgres.aaaaaaaaaaaaaaaaaaaa" "aaaaaaaaaaaaaaaaaaaa" || fail "selftest: valid binding (5432) rejected"
  require_pooler_binding "aws-0-x.pooler.supabase.com" "6543" "postgres.aaaaaaaaaaaaaaaaaaaa" "aaaaaaaaaaaaaaaaaaaa" || fail "selftest: valid binding (6543) rejected"
  echo "[selftest] OK: valid ref-bound pooler binding accepted (ports 5432/6543)"
  # equality source is p.prosrc, not pg_get_functiondef
  sql="$(governed_sql)"
  hb="$(printf '%s\n' "$sql" | grep 'HASHB64=' || true)"
  printf '%s' "$hb" | grep -q 'prosrc' || fail "selftest: equality hash source is not p.prosrc"
  if printf '%s' "$hb" | grep -q 'pg_get_functiondef'; then fail "selftest: equality hash source uses pg_get_functiondef"; fi
  echo "[selftest] OK: equality hash source is p.prosrc, NOT pg_get_functiondef"
  if grep -nE 'db\.\$\{|host=db\.' "$0" >/dev/null 2>&1; then fail "selftest: a direct per-project host construction is present"; fi
  echo "[selftest] OK: no direct per-project host construction (pooler endpoint only)"
  # read-only gate precedes every catalog query
  gate_line="$(printf '%s\n' "$sql" | grep -nm1 'transaction_read_only' | cut -d: -f1 || true)"
  fn_line="$(printf '%s\n' "$sql" | grep -nm1 'prosrc' | cut -d: -f1 || true)"
  acl_line="$(printf '%s\n' "$sql" | grep -nm1 'has_function_privilege' | cut -d: -f1 || true)"
  flag_line="$(printf '%s\n' "$sql" | grep -nm1 'mainship_send_enabled' | cut -d: -f1 || true)"
  [ -n "$gate_line" ] && [ -n "$fn_line" ] && [ -n "$acl_line" ] && [ -n "$flag_line" ] || fail "selftest: could not locate gate/query lines"
  [ "$gate_line" -lt "$fn_line" ] && [ "$gate_line" -lt "$acl_line" ] && [ "$gate_line" -lt "$flag_line" ] \
    || fail "selftest: read-only gate (line $gate_line) is NOT before prosrc/$fn_line, acl/$acl_line, flags/$flag_line"
  echo "[selftest] OK: read-only gate (line $gate_line) precedes prosrc-hash ($fn_line), ACL ($acl_line), flags ($flag_line)"
  # CA admission negatives (temp files in /tmp; untracked; cleaned up inline)
  t="$(mktemp)"; if ( verify_ca "$t" ) >/dev/null 2>&1; then fail "selftest: empty CA not rejected"; fi; rm -f "$t"
  echo "[selftest] OK: empty CA rejected"
  t="$(mktemp)"; printf 'not a certificate\n' > "$t"; if ( verify_ca "$t" ) >/dev/null 2>&1; then fail "selftest: invalid PEM not rejected"; fi; rm -f "$t"
  echo "[selftest] OK: invalid PEM rejected"
  t="$(mktemp)"; cat "$CA_FILE" "$CA_FILE" > "$t"; if ( verify_ca "$t" ) >/dev/null 2>&1; then fail "selftest: multi-cert file not rejected"; fi; rm -f "$t"
  echo "[selftest] OK: multiple-certificate file rejected"
  t="$(mktemp)"; openssl req -x509 -newkey rsa:2048 -keyout /dev/null -out "$t" -days 1 -nodes -subj "/CN=selftest-anchor1a" >/dev/null 2>&1; if ( verify_ca "$t" ) >/dev/null 2>&1; then fail "selftest: fingerprint mismatch not rejected"; fi; rm -f "$t"
  echo "[selftest] OK: a valid-but-wrong cert (fingerprint mismatch) rejected"
  # verifier connection template: verify-full + pinned CA path + forced session port 5432; never 6543; never weaker TLS
  ctmpl="$(build_verifier_conn "aws-0-x.pooler.supabase.com" "aaaaaaaaaaaaaaaaaaaa" "$CA_FILE")"
  printf '%s' "$ctmpl" | grep -q 'sslmode=verify-full' || fail "selftest: conn template missing verify-full"
  printf '%s' "$ctmpl" | grep -qF "sslrootcert=$CA_FILE" || fail "selftest: conn template missing pinned CA path"
  printf '%s' "$ctmpl" | grep -q 'port=5432' || fail "selftest: conn template not on session port 5432"
  if printf '%s' "$ctmpl" | grep -qE 'port=6543|sslmode=(require|prefer|allow|disable)|sslrootcert=system'; then fail "selftest: conn template uses 6543 or weaker TLS"; fi
  echo "[selftest] OK: verifier conn template = verify-full + pinned CA + session port 5432 (no 6543, no weaker TLS)"
  # an API endpoint on 6543 passes endpoint validation (metadata) but the verifier conn still forces 5432
  require_pooler_binding "aws-0-x.pooler.supabase.com" "6543" "postgres.aaaaaaaaaaaaaaaaaaaa" "aaaaaaaaaaaaaaaaaaaa" || fail "selftest: API metadata port 6543 wrongly rejected"
  printf '%s' "$(build_verifier_conn "aws-0-x.pooler.supabase.com" "aaaaaaaaaaaaaaaaaaaa" "$CA_FILE")" | grep -q 'port=5432' || fail "selftest: verifier did not force 5432"
  echo "[selftest] OK: API port 6543 accepted as metadata but verifier connection forced to 5432"

  # descriptor field-by-field: an injected mismatch in EVERY field is detected (item 10)
  for f in $DESC_FIELDS; do
    injected="$f=__INJECTED__"$'\n'"$out"   # mval returns the first occurrence → the injected value for $f
    if ( diff_descriptors "$out" "$injected" ) >/dev/null 2>&1; then fail "selftest: injected mismatch in field $f NOT detected"; fi
    echo "[selftest] OK: descriptor mismatch in $f detected"
  done

  echo "OSN-ANCHOR-1A CATALOG SPOTCHECK (LOCAL DISPOSABLE PROOF): ALL PASSED"
  exit 0
fi

# ── PRODUCTION READ-ONLY EQUIVALENCE ──────────────────────────────────────────────────────────────────
: "${DB_URL:?DB_URL (disposable reference stack) required}"
: "${SUPABASE_DB_PASSWORD:?}" "${SUPABASE_PROJECT_ID:?}" "${SUPABASE_ACCESS_TOKEN:?}"
REF="$SUPABASE_PROJECT_ID"

reject_target_overrides
validate_ref "$REF"
echo "=== production: admit the pinned CA trust material (fail-closed BEFORE any Management API or psql action) ==="
verify_ca "$CA_FILE"

echo "=== production: reference stored-body hash + descriptor from the disposable 0001..0062 chain ==="
ref_out="$(catalog_readonly "$DB_URL")" || fail "reference catalog read failed"
[ "$(mval "$ref_out" RO)" = "on" ] || fail "reference read-only transaction not active"
REF_HASH="$(compute_hash "$(mval "$ref_out" HASHB64)")"
echo "[reference] resolver raw stored-body SHA-256 = $REF_HASH"
assert_descriptor "$ref_out" reference
assert_repo_migrations_through_0062

echo "=== production: verify protected link-state (linked ref == SUPABASE_PROJECT_ID) ==="
linked_ref="$(cat supabase/.temp/project-ref 2>/dev/null || true)"
[ -n "$linked_ref" ] || fail "no linked project ref (supabase link did not run before this step)"
[ "$linked_ref" = "$REF" ] || fail "linked project ref does NOT match the protected SUPABASE_PROJECT_ID"
echo "[production] OK: linked project ref matches the protected SUPABASE_PROJECT_ID"

echo "=== production: resolve EXACTLY ONE protected IPv4 pooler endpoint (strict; fail before any DB connect) ==="
command -v psql >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client >/dev/null; }
command -v jq   >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq jq >/dev/null; }
POOLER="$(curl --fail --silent --show-error --proto '=https' --max-redirs 0 --connect-timeout 10 --max-time 30 \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/${REF}/config/database/pooler")" \
  || fail "Management API request failed (HTTP/TLS error)"
ENDPOINT="$(parse_pooler_endpoint "$POOLER")" || fail "Management API response is not exactly one {db_host, db_port} endpoint"
PHOST="${ENDPOINT%%|*}"; API_PORT="${ENDPOINT##*|}"
PUSER="postgres.${REF}"   # ref-bound tenant selector — derived ONLY from the protected project ref
require_pooler_binding "$PHOST" "$API_PORT" "$PUSER" "$REF"   # API port validated as endpoint METADATA only (5432|6543)
# Verifier session: SESSION pooler port 5432 + pinned CA + verify-full, regardless of the API-returned port.
CONN="$(build_verifier_conn "$PHOST" "$REF" "$CA_FILE")"
echo "[diag] API metadata=${PHOST}:${API_PORT} ; verifier=${PHOST}:5432 (session pooler) ; tenant=postgres.<ref> ; tls=verify-full ; sslrootcert=pinned CA"

echo "=== production: LIVE stored-body hash + descriptor + flags inside one READ ONLY transaction ==="
prod_out="$(PGPASSWORD="$SUPABASE_DB_PASSWORD" catalog_readonly "$CONN")" \
  || fail "live catalog read failed over the pooler ${PHOST}:${PPORT} with verify-full (see transport note in the report)"
[ "$(mval "$prod_out" RO)" = "on" ] || fail "PRODUCTION read-only gate did not report on"
echo "[production] proven: the read-only gate passed before any catalog query (transaction_read_only=on)"
PROD_HASH="$(compute_hash "$(mval "$prod_out" HASHB64)")"
echo "[production] resolver raw stored-body SHA-256 = $PROD_HASH"
assert_descriptor "$prod_out" production

echo "=== production: descriptor parity (field-by-field local vs production) ==="
diff_descriptors "$ref_out" "$prod_out"
echo "[production] descriptor parity OK: all 17 fields identical local vs production ($DESC_FIELDS)"

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

echo "=== production: EXACT raw stored-body hash equivalence (no normalization) ==="
echo "[compare] reference=$REF_HASH production=$PROD_HASH"
if ! hash_equal "$REF_HASH" "$PROD_HASH"; then
  echo "MISMATCH: the deployed resolver stored body differs from the disposable 0062 reference."
  echo "  reference_sha256 = $REF_HASH"
  echo "  production_sha256 = $PROD_HASH"
  echo "  (stored body deliberately NOT printed; no normalization attempted; failing without retry)"
  exit 1
fi
echo "[compare] OK: production resolver raw stored body is byte-identical to the disposable 0062 reference"

echo "OSN-ANCHOR-1A CATALOG SPOTCHECK (PRODUCTION READ-ONLY EQUIVALENCE): ALL PASSED"
