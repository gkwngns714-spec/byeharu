-- Byeharu — LOCATION-INVEST-P18 SLICE 1: the SOLE-writer invest command — the ONLY path that writes
-- `location_investments` — plus its one consumed tunable. Two-layer (public wrapper → private
-- writer), server-authoritative, DARK, a strict ONE-WAY SINK. NO read surface, NO frontend, NO cron,
-- NO flag flipped true.
--
-- THE ENTIRE SURFACE IS DARK TODAY: location_investment_enabled = 'false' (0132), and the private
-- writer rejects 'feature_disabled' BEFORE any other read (the 0107/0097 reject-before-any-read law),
-- with the defense-in-depth + anti-probe gate in the public wrapper too (0083/0099/0109 idiom — a
-- dark feature answers identically regardless of input).
--
-- IDIOM SOURCES (reused, never reinvented — verified against the actual signatures this slice):
--   · two-layer authenticated wrapper → private SECURITY DEFINER writer + per-function ACL:
--     craft_module / production_craft_module (0109:87–273).
--   · per-player advisory lock BEFORE the replay check + verbatim-replay idempotency (the ledger row
--     IS the receipt — NO separate receipts table, NO payload-conflict check): 0109:118–136, matched
--     to the trade-receipt semantics (0089:108–116 market_buy).
--   · ship ownership resolve → owned ship or null: mainship_resolve_owned_ship(player, ship) (0081;
--     the market_buy idiom, 0089:149–150).
--   · docked-location resolve: the shared read-only helper mainship_resolve_docked_location(ship)
--     (0092; internal — asserts NO ownership, so the wrapper asserts ownership FIRST, then the
--     definer writer calls it as owner). Returns the docked location id or NULL → 'not_docked'.
--   · one-way credit SINK: wallet_debit(player, amount) (0093; internal, row-locking conditional
--     debit — false if too poor, can never overdraw). There is NO wallet_credit / NO withdrawal / NO
--     payout anywhere in Investment — score/development can never be farmed (ROADMAP :93 guard "no
--     infinite exploit").
--
-- REQUEST_ID TYPE BRIDGE (deviation, reported): p_request_id is `uuid` (the same type as market_buy's
-- request_id, 0089:66 — the instruction's directive; uuid is intrinsically bounded, so a null-only
-- check suffices, exactly like market_buy). The shipped ledger column `location_investments.request_id`
-- is `text` (0132, mirroring module_craft_receipts, which pairs with a text-param command). 0132 is
-- forward-only / cannot be edited, so this command bridges the two at the single ledger boundary with
-- an explicit `p_request_id::text` cast (uuid → text is canonical + deterministic, so the
-- unique (player_id, request_id) idempotency key is preserved). This is the only place the two idioms
-- meet; documented so a future reader is not surprised by the cast.
--
-- ENVELOPES: code-keyed `{ok:false, code:'…'}` / `{ok:true, …}` (the 0131 Ranking read-surface
-- posture + this slice's directive), no localized message layer this slice (the read/UI slice owns
-- presentation). The private writer returns well-formed code envelopes; the wrapper passes them
-- through verbatim (it owns only auth + its anti-probe gate + ownership before delegating).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): §1 `location_investments` sole writer
-- becomes the concrete private writer `location_investment_invest` (via the public `invest_in_location`
-- wrapper), and the row moves to sit AFTER `ranking_standings` (tail-append — restoring Ranking's
-- contiguous two-row group). §2 records the two functions and the now-REALIZED edges, all DOWNWARD and
-- acyclic: Investment → Wallet (`wallet_debit`) · Main Ship (read via `mainship_resolve_owned_ship` +
-- `mainship_resolve_docked_location`) · Reference/Config (`cfg_bool` flag + `cfg_num` min-amount).
-- Nothing calls into Investment. Leaves `0001–0132` unedited; forward-only.

-- ── (a) the ONE consumed tunable — the anti-dust/spam minimum credits per investment ──────────────
insert into public.game_config (key, value, description) values
  ('location_investment_min_amount', '1',
   'LOCATION-INVEST-P18: minimum credits per single investment (anti-dust/spam floor). Consumed by '
   'location_investment_invest — an amount below this is rejected (invalid_amount) with nothing spent. '
   'The season-window tunables belong to the later read slice (no dead config).')
on conflict (key) do nothing;

-- ── (b1) location_investment_invest — PRIVATE writer; the SOLE writer of location_investments ──────
create or replace function public.location_investment_invest(
  p_player     uuid,
  p_ship       uuid,
  p_amount     numeric,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.location_investments%rowtype;
  v_loc      uuid;
  v_id       uuid;
  v_at       timestamptz;
begin
  -- 1) DARK GATE FIRST (0107 law / 0109:104–109): while location_investment_enabled is false, reject
  --    deterministically BEFORE any ledger/ship/wallet read.
  if not public.cfg_bool('location_investment_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- 2) input validation. request_id is uuid (intrinsically bounded — the market_buy null-only check,
  --    0089:96); the ship was already resolved+ownership-asserted by the wrapper.
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_request');
  end if;

  -- 3) per-player serialization BEFORE the replay check (the 0109:118–123 / 0078 advisory-lock idiom):
  --    concurrent invests for the SAME player queue here, so a same-request_id race always resolves to
  --    one debit+row + verbatim replay, and the debit/insert window below cannot be raced by this
  --    player. (Bridge cast on the key column below; the lock is keyed on the player only.)
  perform pg_advisory_xact_lock(hashtext('location_investment'), hashtext(p_player::text));

  -- 4) IDEMPOTENCY REPLAY (0109:125–136 / 0089:108–116 semantics): a ledger row for
  --    (player, request_id) already exists → rebuild the ORIGINAL success envelope from that row
  --    verbatim — no debit, no second row. The LEDGER ROW IS THE RECEIPT (no separate receipts table);
  --    NO payload-conflict check (the trade-receipt idiom).
  select * into v_existing from public.location_investments
    where player_id = p_player and request_id = p_request_id::text;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'investment_id', v_existing.investment_id, 'location_id', v_existing.location_id,
      'amount', v_existing.amount, 'invested_at', v_existing.invested_at);
  end if;

  -- 5) resolve the ship's CURRENTLY DOCKED location (the shared Main-Ship read helper Trade uses,
  --    0092). The wrapper asserted ownership first; this internal helper asserts none. NULL → the ship
  --    is not canonically docked. The resolved id is a real locations(id) (from the present/location
  --    fleet), so the ledger FK is satisfied by construction.
  v_loc := public.mainship_resolve_docked_location(p_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'code', 'not_docked');
  end if;

  -- 6) amount validation: strictly positive AND >= the anti-dust floor. cfg_num missing → coalesce to
  --    a safe floor of 1 (the seed exists this slice; the coalesce is defence-in-depth). Nothing spent
  --    on reject. (The table CHECK (amount > 0) is the DB backstop.)
  if p_amount is null or p_amount <= 0
     or p_amount < coalesce(public.cfg_num('location_investment_min_amount'), 1) then
    return jsonb_build_object('ok', false, 'code', 'invalid_amount');
  end if;

  -- 7) THE ONE-WAY SINK, then the ONE ledger row — inside a sub-block so a raced
  --    unique (player_id, request_id) trip (near-impossible under the step-3 player lock, but a
  --    correctness backstop) rolls back THIS debit at the savepoint (NO double-charge) and replays the
  --    now-existing original row verbatim. wallet_debit is atomic-conditional: false → too poor, and
  --    since the update matched nothing there is nothing to roll back and no ledger row is written.
  begin
    if not public.wallet_debit(p_player, p_amount) then
      return jsonb_build_object('ok', false, 'code', 'insufficient_credits');
    end if;

    insert into public.location_investments (player_id, request_id, location_id, amount)
      values (p_player, p_request_id::text, v_loc, p_amount)
      returning investment_id, invested_at into v_id, v_at;
  exception when unique_violation then
    select * into v_existing from public.location_investments
      where player_id = p_player and request_id = p_request_id::text;
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'investment_id', v_existing.investment_id, 'location_id', v_existing.location_id,
      'amount', v_existing.amount, 'invested_at', v_existing.invested_at);
  end;

  return jsonb_build_object('ok', true,
    'investment_id', v_id, 'location_id', v_loc, 'amount', p_amount, 'invested_at', v_at);
end;
$$;

-- ── (b2) invest_in_location — authenticated public wrapper (0109:200–273 wrapper idiom) ────────────
-- DARK TODAY: location_investment_enabled = 'false', so both the gate below and the writer's first
-- check reject every call — the entire surface ships server-rejected with no client UI.
create or replace function public.invest_in_location(
  p_ship       uuid,
  p_amount     numeric,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated');
  end if;

  -- flag gate FIRST (defense-in-depth + anti-probe, 0083/0109 idiom): while dark, the answer is
  -- identical regardless of input — no ship/dock/wallet info can be inferred. The writer re-checks
  -- first and is the final authority.
  if not public.cfg_bool('location_investment_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- resolve the caller's OWNED ship (the market_buy ownership idiom, 0089:149–150); UI selection is
  -- never trusted. Null (unowned / zero / ambiguous) → ship_not_owned.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_ship);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'code', 'ship_not_owned');
  end if;

  -- Delegate. The writer is the final authority on flag/validation/idempotency/docked/debit/append,
  -- and already returns a well-formed code envelope, so pass it through verbatim.
  return public.location_investment_invest(v_player, v_ship, p_amount, p_request_id);
end;
$$;

-- ── (c) ACL (anti-cheat; the 0109:265–273 targeted idiom — the 0064-era default-privileges revoke
--       already denies new functions; these re-assert explicitly. No existing grant is touched). ────
-- the private writer stays OFF the client surface (service-role/internal only):
revoke execute on function public.location_investment_invest(uuid, uuid, numeric, uuid) from public, anon, authenticated;
grant  execute on function public.location_investment_invest(uuid, uuid, numeric, uuid) to service_role;
-- the ONE new client command (dark: both its gate and the writer's first check reject today):
revoke execute on function public.invest_in_location(uuid, numeric, uuid) from public, anon;
grant  execute on function public.invest_in_location(uuid, numeric, uuid) to authenticated;
