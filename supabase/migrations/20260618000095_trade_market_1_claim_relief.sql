-- Byeharu — TRADE-MARKET-1: no-softlock relief claim orchestrator (Trade Market; DARK; server-rejected).
--
-- The relief floor's writer: one Trade-Market orchestrator that grants `relief_credits` to a GENUINELY
-- softlocked player and records the claim. Same structure/idiom as market_buy (0089): DARK server-reject before
-- any read, per-account lock, (player_id, request_id) idempotency, one SECURITY DEFINER function = one txn so a
-- retry never double-grants. It is the SOLE writer of `trade_relief_claims`. DARK behind trade_relief_enabled.
--
-- ── DESIGN (planner authority; anti-farm) ─────────────────────────────────────────────────────────
-- SOLE WRITER PRESERVED: trade_relief_claims ← ONLY market_claim_relief. The relief CREDIT flows THROUGH
--   Wallet's wallet_credit, so Wallet stays the sole player_wallet writer — relief NEVER writes player_wallet
--   directly. Downward reads only (player_wallet for the rock-bottom balance, ship_cargo_lots + main_ship_instances
--   for cargo) — a one-directional ACYCLIC fan-out; Wallet remains a downward leaf, no new cycle.
-- REQUIRES AN EXISTING WALLET ROW (no wallet_ensure here): a player with NO wallet row hasn't entered the economy
--   and gets the normal starting_credits seed on first trade — NOT relief. If relief called wallet_ensure, a
--   rock-bottom player with no row would be seeded starting_credits (1000) AND granted relief (250) — a farming
--   hole. So relief reads the EXISTING row FOR UPDATE and rejects with no_wallet when absent; it never ensures.
-- ACCOUNT LOCK: the rock-bottom read is `select balance … for update` on the existing wallet row, serializing
--   concurrent relief claims for the account. Every check + the write below run under that lock, so distinct
--   request_id races cannot bypass the cap/cooldown.
-- EXACT ROCK-BOTTOM: relief requires balance = 0 AND zero cargo across ALL the player's ships — a genuine
--   softlock, not "low". Bounded by a lifetime cap and a per-claim cooldown (both Reference/Config tunables).

create or replace function public.market_claim_relief(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player     uuid := auth.uid();
  v_balance    numeric;
  v_existing   public.trade_relief_claims%rowtype;
  v_cargo      numeric;
  v_count      integer;
  v_last       timestamptz;
  v_cooldown   interval;
  v_amount     numeric;
  v_claim      uuid;
  v_claimed_at timestamptz;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject: reject deterministically BEFORE any read (mirror market_buy's trade_market_enabled gate).
  if not public.cfg_bool('trade_relief_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'trade_relief_disabled');
  end if;

  -- input validation
  if p_request_id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_request'); end if;

  -- ACCOUNT LOCK + rock-bottom balance read in one step: FOR UPDATE on the EXISTING wallet row serializes
  -- concurrent claims for this account; every check and the write below run under it. NO wallet_ensure here — a
  -- player with NO wallet row hasn't entered the economy, so the seed path (starting_credits on first trade)
  -- applies, NOT relief. Ensuring here would double-grant seed (1000) + relief (250) — a farming hole.
  select balance into v_balance from public.player_wallet where player_id = v_player for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_wallet'); end if;

  -- IDEMPOTENCY: a claim for (player, request_id) already exists → replay it verbatim, no write, no re-grant.
  select * into v_existing from public.trade_relief_claims
    where player_id = v_player and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'claim_id', v_existing.claim_id, 'amount', v_existing.amount, 'claimed_at', v_existing.claimed_at);
  end if;

  -- ROCK-BOTTOM (wallet): relief requires an exactly-empty balance (genuine softlock, not merely "low").
  if v_balance <> 0 then
    return jsonb_build_object('ok', false, 'reason', 'wallet_not_empty', 'balance', v_balance);
  end if;

  -- ROCK-BOTTOM (cargo across ALL the player's ships): inline downward read (consistent with market_buy's inline
  -- main_ship_instances/ship_cargo_lots reads — no speculative helper). Any cargo → not a softlock.
  select coalesce(sum(l.qty), 0) into v_cargo
    from public.ship_cargo_lots l
    join public.main_ship_instances m on m.main_ship_id = l.main_ship_id
    where m.player_id = v_player;
  if v_cargo <> 0 then
    return jsonb_build_object('ok', false, 'reason', 'cargo_not_empty', 'cargo_qty', v_cargo);
  end if;

  -- LIFETIME CAP: bound total relief per player (still guarantees genuine-softlock recovery up to the cap).
  select count(*), max(claimed_at) into v_count, v_last from public.trade_relief_claims
    where player_id = v_player;
  if v_count >= public.cfg_num('relief_max_lifetime_claims')::int then
    return jsonb_build_object('ok', false, 'reason', 'relief_cap_reached', 'claims', v_count);
  end if;

  -- COOLDOWN: minimum spacing between claims (prevents rapid re-farming).
  v_cooldown := (public.cfg_num('relief_cooldown_seconds') || ' seconds')::interval;
  if v_last is not null and v_last > now() - v_cooldown then
    return jsonb_build_object('ok', false, 'reason', 'relief_cooldown_active',
      'next_eligible_at', v_last + v_cooldown);
  end if;

  -- GRANT via Wallet (sole player_wallet writer); relief NEVER writes player_wallet directly.
  v_amount := public.cfg_num('relief_credits')::numeric;
  perform public.wallet_credit(v_player, v_amount);

  -- LEDGER (Trade Market sole writer; (player_id, request_id) idempotency key).
  insert into public.trade_relief_claims (player_id, request_id, amount)
    values (v_player, p_request_id, v_amount)
    returning claim_id, claimed_at into v_claim, v_claimed_at;

  return jsonb_build_object('ok', true, 'claim_id', v_claim, 'amount', v_amount, 'claimed_at', v_claimed_at);
end;
$$;
-- ACL: authenticated client RPC (server-rejected while dark). Mirror market_buy's ACL exactly.
revoke execute on function public.market_claim_relief(uuid) from public, anon;
grant  execute on function public.market_claim_relief(uuid) to authenticated;
