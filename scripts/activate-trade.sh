#!/usr/bin/env bash
# TRADE ACTIVATION runner — wraps the ONE Phase-10 flip operation scripts/activate-trade.sql
# (docs/FULL_CAPACITY_PLAN.md §B rung 3 "Trade market"; queue slice #5 ACT-TRADE; prereq
# ECON-SEED-1 / migration 0173). ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build
# time; each `run` is the human's recorded go decision.
#
# The activate-team-command.sh / activate-captains.sh / activate-exploration.sh pattern, trade
# domain. Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly TWO approved keys (trade_market_enabled +
#              trade_relief_enabled, BOTH -> true — plan §B rung 3: the relief backstop lights
#              with the market), never a relief/price knob and never another window's flag; is one
#              timed BEGIN..COMMIT gated on the 0173 seed (18 active offers, anti-pump recompute,
#              3 routes re-derived profitable) + the 0138 prosrc body pins (helper call +
#              trade_effective_price — the stale-0136-body guard); contains NO psql meta-command
#              (management-API compatible); keeps its ROLLBACK section commented out; and
#              documents the ONE remaining client step (the TRADE_MARKET_ENABLED one-line PR:
#              mounts MarketPanel on PortScreen; the ShipSwitcher OR-gate merely completes — the
#              switcher is already mounted via MAINSHIP_ADDITIONAL_ENABLED).
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and
#              assert every stage marker. Requires the typed confirm token as the 2nd arg.
#              No local psql on this machine? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead — it is self-contained, self-asserting,
#              and meta-command-free.
#
#   bash scripts/activate-trade.sh selftest
#   bash scripts/activate-trade.sh run ACTIVATE_TRADE                 # DB_URL required
#
# AFTER a green run (the plan §B order — server first, client second):
#   1. The ONE-LINE client PR: TRADE_MARKET_ENABLED -> true in src/features/map/osnReleaseGates.ts
#      (mounts MarketPanel on the Port screen, PortScreen.tsx:61 — the only newly visible surface —
#      and completes the ShipSwitcher OR-gate, ShipScreen.tsx:62; the switcher itself is ALREADY
#      mounted via MAINSHIP_ADDITIONAL_ENABLED=true since the 2026-07-12 team launch).
#   2. Manual smoke: dock Slagworks -> MarketPanel shows 6 offers -> buy ore 12 -> sail Haven ->
#      sell 16 (+4/unit); re-click replays idempotent; relief probe on a fresh 0/0 account (+250,
#      immediate second claim rejects relief_cooldown_active).
# Rollback: the commented section at the bottom of the .sql (the two reverse config writes only —
# wallets/cargo/receipts/relief claims persist inert; roll both flags back together).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_TRADE]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-trade.sql"
CONFIRM_TOKEN="ACTIVATE_TRADE"
MARKERS="ACTIVATE_TRADE_PASS_PRECONDITIONS ACTIVATE_TRADE_PASS_STAGE1 ACTIVATE_TRADE_PASS_SMOKE"
PASS_LINE="TRADE ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere (nothing for a runner to strip).
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT; gated on the 0173 seed + the 0138 deployed-body pins.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -q "20260618000173" || fail "operation must precondition on the 0173 multiport econ seed"
  printf '%s' "$CLEAN" | grep -qF "sell_price < buy_price" || fail "operation must recompute the anti-pump invariant over the seeded rows"
  for good in ore provisions machinery; do
    printf '%s' "$CLEAN" | grep -qF "'$good'" || fail "operation must re-derive the $good flagship route from live rows"
  done
  printf '%s' "$CLEAN" | grep -qF "'public.mainship_resolve_docked_location(v_ship)' in v_src" || fail "operation must prosrc-pin the 0138 docked-resolve helper call in every deployed trade RPC body (the 0136 stale-body guard)"
  printf '%s' "$CLEAN" | grep -qF "'trade_effective_price(' in v_src" || fail "operation must prosrc-pin the P19 price composition in every deployed trade RPC body (the pre-0136 body guard)"
  printf '%s' "$CLEAN" | grep -qF "relief_max_lifetime_claims" || fail "operation must sanity-assert the relief knobs (0094)"
  printf '%s' "$CLEAN" | grep -qF "starting_credits" || fail "operation must assert starting_credits exists (0093)"
  printf '%s' "$CLEAN" | grep -qF "main_ship_price" || fail "operation must assert main_ship_price present (read-only; 250 live already)"

  # writes: ONLY the owned set_game_config writer, exactly TWO call sites, BOTH the approved keys,
  # BOTH -> true; NEVER a knob rewrite, NEVER another window's flag, NEVER another table, NEVER DDL.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "2" ] || fail "operation must have exactly 2 set_game_config call sites (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('trade_market_enabled', 'true'::jsonb)" || fail "missing trade_market_enabled -> true"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('trade_relief_enabled', 'true'::jsonb)" || fail "missing trade_relief_enabled -> true (the no-softlock backstop must light with the market)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(relief_credits|relief_cooldown_seconds|relief_max_lifetime_claims|starting_credits|main_ship_price|max_active_fleets|max_main_ships_per_player)'" \
    && fail "operation rewrites an economy knob (assert-only; retunes are a separate deliberate write)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(exploration_enabled|mining_enabled|team_command_enabled|mainship_additional_commission_enabled|module_crafting_enabled|module_fitting_enabled|captain_assignment_enabled|captain_progression_enabled|captain_shard_drop_rate|station_storage_enabled|ranking_enabled|location_investment_enabled|world_balance_enabled|phase20_polish_enabled)'" \
    && fail "operation writes another window's key (out of the trade window's scope)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # smoke + follow-ups are documented/asserted: markers, the function-existence smoke over the whole
  # trade surface (client RPCs + internal leaves), the 18-offers/3-ports pin, the anti-pump
  # constraint pin, the cargo-table sanity select, and the client-PR mount documentation.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                                    || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence smoke"
  for fn in "public.get_market_offers(uuid)" "public.market_buy(uuid, text, numeric, uuid)" \
            "public.market_sell(uuid, text, numeric, uuid)" "public.market_claim_relief(uuid)" \
            "public.mainship_resolve_owned_ship(uuid, uuid)" "public.mainship_resolve_docked_location(uuid)" \
            "public.trade_effective_price(numeric, uuid)" "public.trade_cargo_add_lot(uuid, text, numeric, numeric, uuid)" \
            "public.trade_cargo_consume(uuid, text, numeric)" "public.wallet_ensure(uuid)" \
            "public.wallet_debit(uuid, numeric)" "public.wallet_credit(uuid, numeric)"; do
    printf '%s' "$CLEAN" | grep -qF "'$fn'" || fail "smoke does not cover $fn"
  done
  printf '%s' "$CLEAN" | grep -qF "count(distinct location_id)" || fail "missing the 18-offers-across-3-ports smoke pin"
  printf '%s' "$CLEAN" | grep -qF "sell_price >= buy_price" || fail "missing the anti-pump CHECK-constraint smoke pin"
  printf '%s' "$CLEAN" | grep -qF "from public.ship_cargo_lots" || fail "missing the ship_cargo_lots sanity select"
  grep -q "THE FINAL STEP IS NOT IN THIS FILE" "$OP_SQL"            || fail "operation must document the remaining one-line client PR"
  grep -q "PortScreen.tsx:61" "$OP_SQL"                             || fail "operation must document the verified MarketPanel mount (PortScreen)"
  grep -q "ShipScreen.tsx:62" "$OP_SQL"                             || fail "operation must document the verified ShipSwitcher OR-gate (already mounted via MAINSHIP_ADDITIONAL_ENABLED)"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                             || fail "missing the marked manual ROLLBACK section"

  echo "TRADE ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 2 approved keys, both -> true; 0173-seed-gated single timed BEGIN..COMMIT with the 0138 prosrc body pins + route recomputes; no meta-commands; no knob or other-window rewrites; rollback commented; client-PR mounts documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "TRADE ACTIVATION: OVERALL_PASS — trade market + relief live server-side. Next: the one-line client PR flipping TRADE_MARKET_ENABLED (mounts MarketPanel on PortScreen; the ShipSwitcher OR-gate completes — the switcher is already mounted), then the manual smoke + relief probe."
