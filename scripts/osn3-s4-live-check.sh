#!/usr/bin/env bash
# OSN-3 S4 — STRICTLY READ-ONLY live post-deploy verification of migration 0058. Read paths only:
#   1) migration list --linked            (0058 applied remotely)
#   2) direct psql catalog query via pooler (AUTHORITATIVE: processor identity/owner/ACL, S2/S3 helpers
#                                            still service_role-only, canonical RPC inventory, the single
#                                            arrival cron job, flags, cap, and zero movement/receipt rows)
#   3) REST table reads                    (corroborate flags/cap + zero movements + zero receipts)
# NEVER executes the processor / S3 writer / S2 helpers, NEVER mutates, NEVER changes a flag, NEVER seeds.
set -uo pipefail
: "${SUPABASE_DB_PASSWORD:?}" "${URL:?}" "${ANON:?}" "${SRV:?}" "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}"
REF="$SUPABASE_PROJECT_ID"
fail() { echo "FAIL: $1"; exit 1; }

echo "=== 1) migration 0058 applied on live ==="
supabase migration list --linked --password "$SUPABASE_DB_PASSWORD" | tee /tmp/migs
awk -F'|' '/20260618000058/{r=$2; gsub(/ /,"",r); if (r=="20260618000058") print "REMOTE_OK"}' /tmp/migs | grep -q REMOTE_OK \
  && echo "ok: migration 0058 is applied on the live database" || fail "0058 not shown applied remotely"

echo "=== 2) discover a read-only pooler connection ==="
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
  if PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=12 psql "host=$H port=$P user=$U dbname=postgres sslmode=require" -X -t -A -c "select 1" >/dev/null 2>/tmp/cerr; then
    CONN="host=$H port=$P user=$U dbname=postgres sslmode=require"; echo "[diag] connected via $H:$P"; break
  fi
done
[ -n "$CONN" ] || fail "could not establish a read-only connection to live"

echo "=== 3) AUTHORITATIVE catalog inspection (processor / ACL / cron / flags / counts) ==="
PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 psql "$CONN" -X -v ON_ERROR_STOP=1 <<'SQL' || fail "live catalog inspection failed"
\set ON_ERROR_STOP on
\pset pager off
\echo '--- processor + S3 writer + S2 helper metadata ---'
select p.proname, pg_get_function_identity_arguments(p.oid) args, p.prosecdef sd, p.proconfig cfg,
       pg_get_userbyid(p.proowner) owner,
       has_function_privilege('anon',p.oid,'EXECUTE') anon_x,
       has_function_privilege('authenticated',p.oid,'EXECUTE') auth_x,
       has_function_privilege('service_role',p.oid,'EXECUTE') srv_x, p.proacl::text acl
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('process_mainship_space_arrivals','mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
order by p.proname;
-- processor identity + boundary
do $$
declare r record;
begin
  select p.oid, p.prosecdef, p.proconfig, p.proacl, pg_get_userbyid(p.proowner) owner, pg_get_function_identity_arguments(p.oid) args, pg_get_functiondef(p.oid) def
    into r from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='process_mainship_space_arrivals';
  if r.oid is null then raise exception 'LIVE FAIL: processor missing'; end if;
  if r.args <> '' then raise exception 'LIVE FAIL: processor signature mismatch (args=%)', r.args; end if;
  if r.owner<>'postgres' or not r.prosecdef or r.proconfig is null or not ('search_path=public'=any(r.proconfig)) then raise exception 'LIVE FAIL: processor owner/definer/search_path drift'; end if;
  if r.def ~* 'execute format' or strpos(lower(r.def),'execute ''')>0 then raise exception 'LIVE FAIL: processor uses dynamic EXECUTE'; end if;
  if has_function_privilege('anon',r.oid,'EXECUTE') or has_function_privilege('authenticated',r.oid,'EXECUTE') then raise exception 'LIVE FAIL: processor client-executable'; end if;
  if not has_function_privilege('service_role',r.oid,'EXECUTE') then raise exception 'LIVE FAIL: processor lost service_role'; end if;
  if r.proacl is null or exists (select 1 from unnest(r.proacl) a where a::text like '=%') then raise exception 'LIVE FAIL: processor PUBLIC-executable'; end if;
  raise notice 'LIVE ok: process_mainship_space_arrivals() — no args, owner=postgres, SECURITY DEFINER, search_path=public, no dynamic SQL, no player wrapper; anon/authenticated/PUBLIC denied, service_role allowed';
end $$;
-- S3 writer + 4 S2 helpers still service_role-only
do $$
declare r record; c int := 0;
begin
  for r in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in ('mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion') loop
    c:=c+1;
    if has_function_privilege('anon',r.oid,'EXECUTE') or has_function_privilege('authenticated',r.oid,'EXECUTE') then raise exception 'LIVE FAIL: % client-executable', r.proname; end if;
    if not has_function_privilege('service_role',r.oid,'EXECUTE') then raise exception 'LIVE FAIL: % lost service_role', r.proname; end if;
  end loop;
  if c<>5 then raise exception 'LIVE FAIL: expected 5 server-only space fns, found %', c; end if;
  raise notice 'LIVE ok: S3 writer + four S2 helpers remain service_role-only';
end $$;
-- canonical client-RPC inventory unchanged; no server fn player-facing
do $$
declare expected text[] := array['bootstrap_me','cancel_build_order','get_combat_reports','get_my_expedition_preview','get_world_map','move_main_ship_to_location','repair_main_ship','request_leave_location','request_main_ship_return','request_retreat','send_fleet_to_location','send_main_ship_expedition','train_units'];
  actual text[]; server_only text[] := array['process_mainship_space_arrivals','mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion'];
begin
  select coalesce(array_agg(distinct p.proname order by p.proname),'{}') into actual from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('authenticated',p.oid,'EXECUTE');
  raise notice 'LIVE authenticated-executable public functions = %', actual;
  if actual && server_only then raise exception 'LIVE FAIL: a server-only fn is authenticated-executable: %', actual; end if;
  if not (actual @> expected) then raise exception 'LIVE FAIL: a canonical client RPC lost execute: expected=% actual=%', expected, actual; end if;
  if not (expected @> actual) then raise notice 'LIVE NOTE: extra authenticated-executable fn(s): %', (select array_agg(x) from unnest(actual) x where not (x = any(expected))); end if;
  if not has_function_privilege('anon','public.get_world_map()'::regprocedure,'EXECUTE') then raise exception 'LIVE FAIL: anon lost get_world_map'; end if;
  raise notice 'LIVE ok: canonical client-RPC inventory unchanged';
end $$;
-- public CREATE denied
do $$ begin
  if has_schema_privilege('anon','public','CREATE') or has_schema_privilege('authenticated','public','CREATE') then raise exception 'LIVE FAIL: client role can CREATE in public'; end if;
  raise notice 'LIVE ok: anon/authenticated cannot CREATE in public';
end $$;
-- exactly one arrival cron job with the established cadence; no duplicate
do $$
declare n int; sched text; cmd text;
begin
  select count(*), max(schedule), max(command) into n, sched, cmd from cron.job where jobname='process-mainship-space-arrivals';
  if n <> 1 then raise exception 'LIVE CRON FAIL: % arrival jobs (expected exactly 1, no duplicate)', n; end if;
  if sched <> '30 seconds' then raise exception 'LIVE CRON FAIL: schedule=%', sched; end if;
  if cmd <> 'select public.process_mainship_space_arrivals();' then raise exception 'LIVE CRON FAIL: command=%', cmd; end if;
  raise notice 'LIVE ok: exactly one cron job process-mainship-space-arrivals @ "30 seconds" → %', cmd;
end $$;
-- flags + cap + zero coordinate movements + zero receipts
do $$
declare a text; b text; c text; nm bigint; nr bigint;
begin
  select value::text into a from game_config where key='mainship_send_enabled';
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  select value::text into c from game_config where key='max_coordinate_travel_seconds';
  if a is distinct from 'true'  then raise exception 'LIVE FLAG FAIL: mainship_send_enabled=% (expected true)', a; end if;
  if b is distinct from 'false' then raise exception 'LIVE FLAG FAIL: mainship_space_movement_enabled=% (expected false)', b; end if;
  if c is distinct from '86400' then raise exception 'LIVE CONFIG FAIL: max_coordinate_travel_seconds=%', c; end if;
  select count(*) into nm from main_ship_space_movements; if nm<>0 then raise exception 'LIVE FAIL: main_ship_space_movements=%', nm; end if;
  select count(*) into nr from main_ship_space_command_receipts; if nr<>0 then raise exception 'LIVE FAIL: main_ship_space_command_receipts=%', nr; end if;
  raise notice 'LIVE ok: send=true, space_movement=false, cap=86400, main_ship_space_movements=0, command_receipts=0';
end $$;
select 'OSN-3 S4 LIVE READ-ONLY CATALOG INSPECTION: ALL PASSED' as result;
SQL
echo "ok: authoritative catalog inspection passed"

echo "=== 4) REST read-only corroboration ==="
flags=$(curl -s "$URL/rest/v1/game_config?key=in.(mainship_send_enabled,mainship_space_movement_enabled,max_coordinate_travel_seconds)&select=key,value" -H "apikey: $ANON" -H "Authorization: Bearer $ANON")
echo "flags/cap: $flags"
echo "$flags" | grep -qiE 'mainship_send_enabled.*true' || fail "send not true (REST)"
echo "$flags" | grep -qiE 'mainship_space_movement_enabled.*false' || fail "space not false (REST)"
echo "$flags" | grep -qiE 'max_coordinate_travel_seconds.*86400' || fail "cap not 86400 (REST)"
cm=$(curl -s -I "$URL/rest/v1/main_ship_space_movements?select=id" -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H "Prefer: count=exact" -H "Range: 0-0" | tr -d '\r' | grep -i '^content-range:' | awk -F/ '{print $NF}')
cr=$(curl -s -I "$URL/rest/v1/main_ship_space_command_receipts?select=id" -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H "Prefer: count=exact" -H "Range: 0-0" | tr -d '\r' | grep -i '^content-range:' | awk -F/ '{print $NF}')
echo "main_ship_space_movements=${cm:-?} ; command_receipts=${cr:-?}"
[ "${cm:-x}" = "0" ] && [ "${cr:-x}" = "0" ] || fail "coordinate movement/receipt count != 0"
echo "ok: send=true, space=false, cap=86400, zero movements + zero receipts (REST corroboration)"
echo "OSN-3 S4 LIVE SPOT CHECK (READ-ONLY): ALL PASSED"
