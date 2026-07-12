#!/usr/bin/env bash
# HAUL ACTIVATION runner — wraps the ONE contracts flip operation scripts/activate-haul.sql
# (docs/FULL_CAPACITY_PLAN.md §C P2 "HAUL"; the ACT-HAUL closer of queue #12; ROADMAP phase-22.
# The contracts stack 0176 + 0179 + 0181 is fully built dark). ██ HUMAN TOOL ██ — never wired into
# CI; nothing flips at build time; each `run` is the human's recorded go decision.
#
# The activate-trade.sh / activate-ranking.sh / activate-captains.sh pattern, haul domain.
# Modes:
#   selftest — DB-free static safety: the operation's only DIRECT write is game_config, via the
#              owned set_game_config writer, on exactly ONE approved key (haul_contracts_enabled
#              -> true), never a knob rewrite and never another window's flag; its ONE other
#              mutation is the SANCTIONED generator invoke (public.haul_generate_offers() — the
#              sole mint entrypoint, called exactly once in stage 2 for INSTANT offers, envelope-
#              asserted: the hourly '7 * * * *' cron would otherwise leave the bulletin empty up
#              to ~1h; same-day re-runs tolerated as no-ops via the idempotency natural key); it
#              NEVER writes haul tables directly; is one timed UTC BEGIN..COMMIT gated on the haul
#              migrations (0176/0179/0181 recorded) + the deployed-body prosrc pins (the 0179 (a2)
#              deadline-cancel hunk — the stale-0176 generator guard — plus the accept cap/advisory
#              serialization, the deliver trade_cargo_consume + wallet_credit charter fan-out, and
#              the 0181 gate/fresh-offered/caller-scoped-mine pins) + the 10-template worth-taking
#              recompute + the cron scheduled exactly once + ██ the TRADE PRECONDITION ██
#              (trade_market_enabled committed true — deliver consumes ship_cargo_lots and
#              market_buy is the SOLE cargo-lot producer; mining's ore is an inventory ITEM, never
#              cargo, so dark-trade contracts are 100% undeliverable); smokes the authed client
#              read RPC under a transaction-local fake JWT (the proofs' set_config technique —
#              activate-captains stopped at existence because its RPCs were only surface-checked;
#              here the ONE bulletin read the panel rides is called for real and matched against
#              the table truth); contains NO psql meta-command (management-API compatible); keeps
#              its ROLLBACK section commented out (flag-only + the EXPIRY FREEZE choice
#              documented); documents the flag-BEFORE-generator ordering (the generator dark-gates
#              on the flag), the re-run no-op semantics, and the server-lit mount
#              (PortScreen.tsx:80 — NO client PR needed, no HAUL_* compile constant exists).
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and
#              assert every stage marker. Requires the typed confirm token as the 2nd arg.
#              No local psql on this machine? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead — it is self-contained, self-asserting,
#              and meta-command-free.
#
#   bash scripts/activate-haul.sh selftest
#   bash scripts/activate-haul.sh run ACTIVATE_HAUL                 # DB_URL required
#
# FLIP ORDER: AFTER ACT-TRADE (the script hard-preconditions on trade_market_enabled=true).
# AFTER a green run:
#   1. NO client PR — HaulBoardPanel is already mounted server-lit on the Port screen aside rail
#      (PortScreen.tsx:80; isServerLit gate HaulBoardPanel.tsx:120; no HAUL_* constant in
#      osnReleaseGates.ts or anywhere in src). The board appears on the next docked Port render —
#      IMMEDIATELY stocked at all 3 starter ports (~2 offers each), because stage 2 pre-ran the
#      generator in-txn.
#   2. Manual smoke: dock Haven Reach -> the Contracts bulletin shows ~2 offers -> Accept -> buy
#      the goods at the origin market -> sail to the destination -> Deliver -> wallet +reward,
#      contract leaves the board; a re-click replays idempotent ("Your contracts n/3" tracks the
#      cap).
#   3. OPERATIONAL: the hourly minute-7 cron now does the daily work (new-day mints, <=1h expiry
#      sweeps, blown-deadline cancels) — nothing to roll manually, unlike ranking seasons.
# Rollback: the commented section at the bottom of the .sql (ONE reverse config write — the board
# vanishes instantly via the gated read RPC, the 0181 rationale; the EXPIRY FREEZE note: darkening
# freezes both generator passes, and a dark generator run no-ops — accept the frozen rows
# (recommended; re-light sweeps them) or run the commented manual service-role sweep).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_HAUL]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-haul.sql"
CONFIRM_TOKEN="ACTIVATE_HAUL"
MARKERS="ACTIVATE_HAUL_PASS_PRECONDITIONS ACTIVATE_HAUL_PASS_STAGE1 ACTIVATE_HAUL_PASS_STAGE2 ACTIVATE_HAUL_PASS_SMOKE"
PASS_LINE="HAUL ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere (nothing for a runner to strip).
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT under txn-local UTC (the generator's day anchor is UTC).
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -qF "set local time zone 'UTC'" || fail "operation must pin the txn-local timezone to UTC (the generator's offer_day anchor)"
  printf '%s' "$CLEAN" | grep -q "20260618000181" || fail "operation must precondition on the 0181 read-surface migration head"
  for mv in 20260618000176 20260618000179 20260618000181; do
    printf '%s' "$CLEAN" | grep -qF "'$mv'" || fail "operation must assert migration $mv is recorded as deployed"
  done

  # the deployed-body pins: the generator must be the 0179 re-create (the (a2) hunk — the stale
  # 0176 body carries neither token) with the 0176 determinism/idempotency intact; accept/deliver/
  # read carry their load-bearing clauses.
  printf '%s' "$CLEAN" | grep -qF "position('deliver_by <= now()' in v_src)" || fail "operation must prosrc-pin the 0179 (a2) deadline-cancel pass in the deployed generator (the stale-0176 guard)"
  printf '%s' "$CLEAN" | grep -qF "position('''cancelled''' in v_src)" || fail "operation must prosrc-pin the cancelled transition token in the deployed generator"
  printf '%s' "$CLEAN" | grep -qF "position('hashtextextended' in v_src)" || fail "operation must prosrc-pin the generator's pure-hash determinism (0176)"
  printf '%s' "$CLEAN" | grep -qF "position('on conflict (origin_location_id, offer_day, slot) do nothing' in v_src)" || fail "operation must prosrc-pin the generator's natural-key idempotent mint (0176)"
  printf '%s' "$CLEAN" | grep -qF "position('too_many_active' in v_src)" || fail "operation must prosrc-pin the accept active-cap reject (0179)"
  printf '%s' "$CLEAN" | grep -qF "hashtext(''haul_accept'')" || fail "operation must prosrc-pin the accept per-player advisory serialization (the 0179 cap-race fix)"
  printf '%s' "$CLEAN" | grep -qF "position('trade_cargo_consume' in v_src)" || fail "operation must prosrc-pin the deliver Trade-Cargo fan-out (the charter guard)"
  printf '%s' "$CLEAN" | grep -qF "position('wallet_credit' in v_src)" || fail "operation must prosrc-pin the deliver Wallet fan-out (the charter guard)"
  printf '%s' "$CLEAN" | grep -qF "position('deadline_passed' in v_src)" || fail "operation must prosrc-pin the deliver reject-only deadline (0179 §6)"
  printf '%s' "$CLEAN" | grep -qF "position('expires_at > now()' in v_src)" || fail "operation must prosrc-pin the 0181 fresh-offered predicate in the deployed read RPC"
  printf '%s' "$CLEAN" | grep -qF "position('accepted_by = v_player' in v_src)" || fail "operation must prosrc-pin the 0181 caller-scoped mine read"

  # the seed + eligibility + knob + cron preconditions.
  printf '%s' "$CLEAN" | grep -qF "reward_base + q.qty * (od.buy_price + t.reward_premium_per_unit)" || fail "operation must re-derive the 0176 worth-taking invariants from the live market rows"
  printf '%s' "$CLEAN" | grep -qF "haul_offers_per_port" || fail "operation must sanity-assert the haul_offers_per_port knob (read-only)"
  printf '%s' "$CLEAN" | grep -qF "haul_max_active_per_player" || fail "operation must sanity-assert the haul_max_active_per_player knob (read-only)"
  printf '%s' "$CLEAN" | grep -qF "jobname = 'haul-generate-offers'" || fail "operation must pin the 0176 cron jobname (haul-generate-offers)"
  printf '%s' "$CLEAN" | grep -qF "%haul_generate_offers%" || fail "operation must assert the cron command invokes haul_generate_offers"

  # ██ the TRADE PRECONDITION ██ — the deliverability gate (market_buy is the sole cargo-lot
  # producer; mining does not substitute): committed-true asserted raw AND through the reader.
  printf '%s' "$CLEAN" | grep -qF "key = 'trade_market_enabled'" || fail "operation must assert the raw trade_market_enabled value (the deliverability precondition)"
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('trade_market_enabled')" || fail "operation must assert trade_market_enabled through cfg_bool (the deliverability precondition)"

  # writes: the ONE set_game_config call site on the ONE approved key -> true, plus the ONE
  # sanctioned generator invoke; NEVER a knob rewrite, another window's flag, direct table DML,
  # or DDL. (The to_regprocedure signature strings in the preconditions are existence checks, not
  # call sites — invocations are counted by their distinctive call forms.)
  # occurrence-count (grep -o | wc -l), not line-count: same-line doubling can't evade (review M6).
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('haul_contracts_enabled', 'true'::jsonb)" || fail "missing haul_contracts_enabled -> true (the only flag write)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(haul_offers_per_port|haul_max_active_per_player|trade_market_enabled|trade_relief_enabled|exploration_enabled|mining_enabled|team_command_enabled|mainship_additional_commission_enabled|module_crafting_enabled|module_fitting_enabled|captain_assignment_enabled|captain_progression_enabled|captain_growth_enabled|captain_shard_drop_rate|station_storage_enabled|salvage_market_enabled|ranking_enabled|location_investment_enabled|world_balance_enabled|phase20_polish_enabled)'" \
    && fail "operation writes a knob or another window's key (out of the haul window's scope)" || true
  # both call forms (:= and perform), occurrence-counted — the perform-form gap was review M6.
  n="$(printf '%s' "$CLEAN" | grep -oE '(:=|perform)[[:space:]]+public\.haul_generate_offers\(\)' | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must invoke the sanctioned generator exactly ONCE (the instant-offers stage; found $n invocations)"
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config + the generator invoke only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # stage 2 — instant offers: envelope-asserted (ok + exactly 3 ports), same-day re-run tolerated
  # ONLY when today's rows already exist, and every starter port stocked for today.
  printf '%s' "$CLEAN" | grep -qF -- "->> 'ok'" || fail "the generator envelope must be asserted (ok)"
  printf '%s' "$CLEAN" | grep -qF -- "(v_res ->> 'ports')::int, -1) <> 3" || fail "the generator envelope must assert exactly 3 ports visited"
  printf '%s' "$CLEAN" | grep -qF "offer_day = v_day" || fail "stage 2 must assert today's slots exist (the re-run-tolerant instant-offers check)"
  grep -q "SAME-DAY RE-RUN" "$OP_SQL" || fail "operation must document the same-day re-run no-op tolerance"

  # smoke + follow-ups documented/asserted: markers, the function-existence loop over the REAL haul
  # signatures + the charter leaves + market_buy (the sourcing faucet), the authed client-RPC smoke
  # under a txn-local fake JWT (called AND matched against the table truth, mine leak-checked,
  # claims cleared), the receipts sanity select, the ordering/re-run/mount/rollback documentation.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                                    || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence loop"
  for fn in "public.haul_generate_offers()" "public.haul_accept_contract(uuid, uuid, uuid)" \
            "public.haul_deliver_contract(uuid, uuid, uuid)" "public.get_port_contracts(uuid)" \
            "public.trade_cargo_consume(uuid, text, numeric)" "public.wallet_credit(uuid, numeric)" \
            "public.mainship_resolve_owned_ship(uuid, uuid)" "public.mainship_resolve_docked_location(uuid)" \
            "public.market_buy(uuid, text, numeric, uuid)" "public.cfg_bool(text)" \
            "public.cfg_num(text)" "public.set_game_config(text, jsonb)"; do
    printf '%s' "$CLEAN" | grep -qF "'$fn'" || fail "preconditions do not cover $fn"
  done
  printf '%s' "$CLEAN" | grep -qF "set_config('request.jwt.claims'," || fail "missing the txn-local fake-JWT for the authed bulletin-read smoke (the proofs' technique)"
  printf '%s' "$CLEAN" | grep -qF "public.get_port_contracts(c_haven)" || fail "missing the lit-client-RPC smoke (get_port_contracts call on a real port)"
  printf '%s' "$CLEAN" | grep -qF "jsonb_array_length(v_res -> 'offered')" || fail "the bulletin-read smoke must match the RPC offered array against the table truth"
  printf '%s' "$CLEAN" | grep -qF "jsonb_array_length(v_res -> 'mine')" || fail "the bulletin-read smoke must leak-check mine == [] for the fake subject"
  printf '%s' "$CLEAN" | grep -qF "set_config('request.jwt.claims', '', true)" || fail "the fake JWT must be cleared after the smoke"
  printf '%s' "$CLEAN" | grep -qF "from public.haul_receipts" || fail "missing the haul_receipts sanity select"
  grep -q "ORDERED BEFORE THE GENERATOR INVOKE" "$OP_SQL"           || fail "operation must document the flag-BEFORE-generator ordering (the generator dark-gates on the flag)"
  grep -q "INSTANT OFFERS" "$OP_SQL"                                || fail "operation must document the instant-offers decision (in-stage generator invoke vs the ~1h cron wait)"
  grep -q "THE TRADE PRECONDITION" "$OP_SQL"                        || fail "operation must document the trade deliverability precondition (+ the mining-is-not-cargo note)"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"                              || fail "operation must document the re-run no-op semantics"
  grep -q "NO CLIENT PR IS NEEDED" "$OP_SQL"                        || fail "operation must document that the surface is server-lit (no compile constant)"
  grep -q "PortScreen.tsx:80" "$OP_SQL"                             || fail "operation must document the verified HaulBoardPanel mount (Port screen aside rail)"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                             || fail "missing the marked manual ROLLBACK section"
  grep -q "THE EXPIRY FREEZE" "$OP_SQL"                             || fail "operation must document the lit->dark expiry-freeze note (0176 forward note + the 0179 (a2) extension) in the rollback section"

  echo "HAUL ACTIVATION SELFTEST: ALL PASSED (set_game_config-only direct writes on the 1 approved key -> true + exactly 1 sanctioned generator invoke, envelope-asserted with the same-day re-run tolerance; single timed UTC BEGIN..COMMIT gated on 0176/0179/0181 recorded + the deployed-body prosrc pins + the worth-taking recompute + the cron exactly once + trade_market_enabled committed true; authed bulletin-read smoke under a cleared txn-local fake JWT matched to table truth; no meta-commands; no knob/other-window/direct-table writes; rollback commented with the expiry-freeze choice; ordering, instant-offers, re-run and server-lit-mount documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "HAUL ACTIVATION: OVERALL_PASS — delivery contracts live server-side with a PRE-STOCKED board (the generator ran in-txn: fresh offers at all 3 starter ports immediately; the hourly minute-7 cron takes over from here). NO client PR needed — HaulBoardPanel mounts server-lit (PortScreen.tsx:80). Manual smoke: dock Haven Reach -> Accept -> buy at the origin market -> sail -> Deliver -> wallet +reward."
