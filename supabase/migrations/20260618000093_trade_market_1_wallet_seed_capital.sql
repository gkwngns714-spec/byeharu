-- Byeharu — TRADE-MARKET-1: seed capital + single shared Wallet lazy-ensure (de-duplication).
--
-- One commit adds the `starting_credits` tunable and extracts the ONE shared `wallet_ensure(player)` Wallet-leaf
-- helper, then repoints both wallet writers at it — killing the two copies of the "lazy ensure" block that lived
-- inline in wallet_debit (0089) and wallet_credit (0090). Behavior is preserved on both paths.
--
-- ── DESIGN (planner authority; §2.1 Wallet-leaf) ─────────────────────────────────────────────────
-- SOLE WRITER PRESERVED: player_wallet ← Wallet only. wallet_ensure is the single internal lazy-ensure+seed;
--   wallet_debit and wallet_credit both call it (no second copy of the ensure logic anywhere).
-- SEED-ON-CREATE, UNFARMABLE: wallet_ensure inserts the row exactly once with balance = starting_credits
--   (cfg_num tunable, default 1000). The `on conflict (player_id) do nothing` makes a re-call a no-op — the row
--   is only ever inserted once, so the seed cannot be farmed by repeated calls.
-- DOWNWARD READ: wallet_ensure reads cfg_num('starting_credits') from Reference/Config (game_config) — a
--   one-directional DOWNWARD read to an existing leaf. Wallet remains a downward leaf: no new cycle, no new
--   writer to any non-Wallet table.
-- DARK: no flag default changes. A wallet is only ever created by a wallet-creation path (market_buy/market_sell
--   under trade_market_enabled=false, additional-ship commission under mainship_additional_commission_enabled=
--   false) — all server-rejected while dark. So no wallet, and thus no seed, occurs while trade/commission stay
--   dark. This slice ships DARK behind the existing flags; no flag is set true.

-- ── 1) starting_credits tunable (Reference/Config; server-owned, no client write; numeric-seed idiom of 0003). ──
insert into public.game_config (key, value, description) values
  ('starting_credits', '1000',
   'TRADE-MARKET-1: credit balance seeded into a player_wallet on FIRST creation (via wallet_ensure). '
   'Placeholder economy value; inert until a wallet is actually created.')
on conflict (key) do nothing;

-- ── 2) wallet_ensure: the ONE shared lazy-ensure + seed (the de-duplication target; internal). ──
--    Inserts the wallet exactly once with the seeded starting balance; idempotent + unfarmable by the
--    player_id primary-key conflict (a re-call is a no-op — the row is only ever inserted once).
create or replace function public.wallet_ensure(p_player uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.player_wallet (player_id, balance)
    values (p_player, coalesce(public.cfg_num('starting_credits'), 0)::numeric)
    on conflict (player_id) do nothing;
end;
$$;
-- Internal: no client grant.
revoke execute on function public.wallet_ensure(uuid) from public, anon, authenticated;

-- ── 3) wallet_debit: seed on first touch (shared ensure), then the existing atomic conditional debit. ──
--    The conditional UPDATE (balance >= p_amount) row-locks the wallet, so concurrent debits — even across
--    different ships of the same player — are serialized and can never overdraw. Returns false if too poor.
--    Behavior preserved: former inline `insert … on conflict do nothing` is now `perform wallet_ensure(...)`.
create or replace function public.wallet_debit(p_player uuid, p_amount numeric)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.wallet_ensure(p_player);
  update public.player_wallet
    set balance = balance - p_amount, updated_at = now()
    where player_id = p_player and balance >= p_amount;
  return found;
end;
$$;
-- Internal: no client grant.
revoke execute on function public.wallet_debit(uuid, numeric) from public, anon, authenticated;

-- ── 4) wallet_credit: ensure-then-add (shared ensure, then unconditional credit). ──
--    Reworked from the former upsert-add into ensure-then-add so the ensure logic lives in ONE place. The
--    ensure guarantees the row exists (seeded on first creation), then the amount adds on top of the
--    seeded/existing balance — credit semantics preserved.
create or replace function public.wallet_credit(p_player uuid, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.wallet_ensure(p_player);
  update public.player_wallet
    set balance = balance + p_amount, updated_at = now()
    where player_id = p_player;
end;
$$;
-- Internal: no client grant.
revoke execute on function public.wallet_credit(uuid, numeric) from public, anon, authenticated;
