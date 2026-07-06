-- Byeharu — MODULES-P13 SLICE C: the dark craft command — module_craft_receipts (player-scoped
-- idempotency ledger, Production-owned) + the two-layer craft_module wrapper → private
-- production_craft_module writer. NO read surface, NO frontend this slice.
--
-- THE ENTIRE SURFACE IS DARK TODAY: module_crafting_enabled = 'false' (0107), and the private
-- writer rejects 'feature_disabled' BEFORE any other read (the 0097/0102 reject-before-any-read
-- law), with the defense-in-depth + anti-probe gate in the public wrapper too (0083/0099 idiom —
-- a dark feature answers identically regardless of input).
--
-- IDIOM SOURCES (matched line-by-line, per the locked decisions — DEV_LOG 2026-07-04 SLICE A):
--   · two-layer wrapper → private writer + reason→code/message map + ACL: 0099:221–311 / 0104.
--   · dark-gate-first + envelope error style: 0099:108–118 / 0089:90–98 (jsonb {ok:false, reason}).
--   · player-scoped receipts table shape + RLS: 0094:24–43 (trade_relief_claims — the account-scoped
--     precedent: unique (player_id, request_id), owner-read select, no write path) and 0086:38–68.
--   · REPLAY SEMANTICS — matched to the TRADE receipts idiom (0089:108–116 market_buy /
--     0095:60–66 market_claim_relief): a receipt for (player, request_id) replays the ORIGINAL
--     success envelope rebuilt VERBATIM from the receipt row, flagged 'idempotent_replay', with
--     NO payload-conflict check (a same-key-different-module_type replay returns the original
--     receipt's data, exactly as a same-key-different-good market_buy replay does). The
--     request_id_payload_conflict hash check (0099:140–148) belongs to the ship-scoped
--     main_ship_space_command_receipts idiom, which this player-scoped command does NOT use —
--     stated explicitly per the slice request.
--   · insufficient-balance envelope: 0089:150–153 (market_buy's 'insufficient_credits' + context
--     fields) → 'insufficient_items' + {item_id, have, need}, checked BEFORE any spend.
--   · per-player race-safety lock BEFORE the replay check: the shipped commission advisory-lock
--     idiom pg_advisory_xact_lock(hashtext(<domain>), hashtext(player)) (0078:43/79, 0080) — the
--     player-scoped analogue of market_buy's per-ship lock (0089:104–106) and relief's wallet
--     FOR UPDATE (0095:53–57), both taken before their idempotency checks for the same reason.
--
-- LOCKED-DECISION ENFORCEMENT (0107 header / DEV_LOG SLICE A):
--   · The command belongs to PRODUCTION (decision 1): module_craft_receipts is Production-owned;
--     the writer fans out one-directionally DOWNWARD to Inventory (inventory_spend — its FIRST
--     live caller) and Modules (modules_mint_instance) — acyclic, no second writer to any table.
--     Crafting NEVER touches player_inventory / inventory_ledger / module_instances directly —
--     only through the two leaf functions (the forbidden-column law).
--   · INSTANT + IDEMPOTENT (decision 2): one SECURITY DEFINER function = one transaction; the
--     ingredient spends, the mint, and the receipt commit or roll back TOGETHER. inventory_spend's
--     exceptions (insufficient/unknown — 0039:113–121) abort the whole craft: a failed craft
--     writes NO receipt (the 0099/0104 failure-writes-no-receipt law) and spends nothing.
--   · ITEMS-ONLY COST (decision 3): the recipe rows are the entire price — no metal, no credits,
--     no Base/Wallet edge.
--   · ONE CRAFT = ONE INSTANCE (decision 4): exactly one modules_mint_instance call per craft,
--     mint key 'craft:' || player || ':' || request_id — namespaced per 0108's key contract, so a
--     replayed insert race can never mint twice and no other producer can collide.
--   · request_id is TEXT (the locked craft_module(p_request_id text, …) signature — the shipped
--     receipt columns are uuid; text is validated non-empty and length-capped below since it
--     lacks uuid's intrinsic bound; clients send crypto.randomUUID() strings).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): module_craft_receipts →
-- Production (sole writer = production_craft_module; owner-read). The Modules §1/§2 "nothing
-- calls it yet" notes are replaced: craft_module (0109) is now modules_mint_instance's ONE
-- caller. New edges, all DOWNWARD: Production → Inventory (spend), Production → Modules (mint),
-- Production → Reference/Config (cfg read) — no cycle. No flag flipped; 0001–0108 unedited.

-- ── 1) module_craft_receipts — per-player idempotent craft ledger (Production-owned) ──────────────
create table public.module_craft_receipts (
  receipt_id     uuid primary key default gen_random_uuid(),
  player_id      uuid not null references auth.users (id) on delete cascade,
  request_id     text not null,                                     -- idempotency key (per-player)
  module_type_id text not null references public.module_types (id),
  -- on delete cascade: an instance row only ever disappears via the auth.users cascade today (no
  -- delete path exists); cascading the receipt with it keeps account deletion order-safe across
  -- the multi-path cascade graph (the 0088 child-FK lesson).
  instance_id    uuid not null references public.module_instances (id) on delete cascade,
  created_at     timestamptz not null default now(),
  unique (player_id, request_id)                                    -- per-player idempotent craft key
);
-- No extra index: the unique (player_id, request_id) index leads on player_id and already covers
-- both idempotency probes and owner-scoped lookups (the 0086:53–55 comment idiom).

alter table public.module_craft_receipts enable row level security;
-- Owner-read only (0094:38–43 posture verbatim); granted to authenticated, NOT anon. NO insert/
-- update/delete policy and NO write grant → clients cannot mutate; Production is sole writer
-- (server-only RPC below).
create policy "module_craft_receipts_select_own" on public.module_craft_receipts
  for select using (player_id = auth.uid());
grant select on public.module_craft_receipts to authenticated;

comment on table public.module_craft_receipts is
  'MODULES-P13: per-player idempotent craft ledger (Production-owned; sole writer = '
  'production_craft_module via the public craft_module wrapper). unique (player_id, request_id) '
  'is the replay key — a replayed craft returns the original envelope verbatim (0089/0095 trade '
  'semantics, no payload-conflict check). Players read only their own rows. Feature DARK behind '
  'module_crafting_enabled.';

-- ── 2) production_craft_module — PRIVATE writer (Production); SOLE writer of module_craft_receipts ─
create or replace function public.production_craft_module(
  p_player      uuid,
  p_module_type text,
  p_request_id  text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rcpt     module_craft_receipts%rowtype;
  r          record;
  v_have     integer;
  v_instance uuid;
  v_receipt  uuid;
  v_created  timestamptz;
begin
  -- 1) DARK GATE FIRST (0107 law / 0099:108–113 idiom): while module_crafting_enabled is false,
  --    reject deterministically BEFORE any other read — no receipt read, no catalog read, no
  --    balance read.
  if not public.cfg_bool('module_crafting_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation. request_id is TEXT (the locked signature): non-empty, sanity-capped
  --    (uuid receipts were intrinsically bounded; a text key must not become an unbounded indexed
  --    payload — clients send 36-char crypto.randomUUID() strings).
  if p_request_id is null or p_request_id = '' or length(p_request_id) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) per-player serialization BEFORE the replay check (the 0078/0080 commission advisory-lock
  --    idiom — the player-scoped analogue of market_buy's per-ship lock / relief's wallet
  --    FOR UPDATE, 0089:104–106 / 0095:53–57): concurrent crafts for the SAME player queue here,
  --    so a same-request_id race always resolves to one craft + one verbatim replay, and the
  --    pre-check → spend window below cannot be raced by another craft of this player.
  perform pg_advisory_xact_lock(hashtext('module_craft'), hashtext(p_player::text));

  -- 4) IDEMPOTENCY REPLAY (0089:108–116 / 0095:60–66 semantics, matched exactly): a receipt for
  --    (player, request_id) already exists → rebuild the ORIGINAL success envelope from the
  --    receipt row verbatim — no write, no re-spend, no re-mint. NO payload-conflict check (the
  --    trade-receipts idiom; the 0099 hash check belongs to the ship-scoped space receipts this
  --    player-scoped command does not use).
  select * into v_rcpt from module_craft_receipts
    where player_id = p_player and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_rcpt.receipt_id, 'instance_id', v_rcpt.instance_id,
      'module_type_id', v_rcpt.module_type_id, 'crafted_at', v_rcpt.created_at);
  end if;

  -- 5) catalog validation: the module type must exist AND have a recipe. A catalog row with no
  --    module_recipe_ingredients rows is uncraftable — a DISTINCT truthful reason (no_recipe), so
  --    a seed gap is diagnosable and never conflated with a bad id (unknown_module).
  if p_module_type is null
     or not exists (select 1 from module_types where id = p_module_type) then
    return jsonb_build_object('ok', false, 'reason', 'unknown_module');
  end if;
  if not exists (select 1 from module_recipe_ingredients where module_type_id = p_module_type) then
    return jsonb_build_object('ok', false, 'reason', 'no_recipe');
  end if;

  -- 6) ingredient pre-check via Inventory's read leaf — friendly envelope BEFORE anything is
  --    spent (the 0089:150–153 insufficient_credits shape, with per-item context). Authoritative
  --    enforcement stays inventory_spend's own FOR UPDATE re-check; this pre-check exists so the
  --    common shortfall answers with an envelope instead of an exception. Race-safe for crafts by
  --    the step-3 player lock; no other inventory spender exists (this command is
  --    inventory_spend's first caller).
  for r in
    select item_id, qty from module_recipe_ingredients
      where module_type_id = p_module_type
      order by item_id
  loop
    v_have := public.inventory_get_balance(p_player, r.item_id);
    if v_have < r.qty then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_items',
        'item_id', r.item_id, 'have', v_have, 'need', r.qty);
    end if;
  end loop;

  -- 7) SPEND via Inventory (the sole player_inventory/inventory_ledger writer — crafting never
  --    touches them directly). Each call is row-locked + transactional (0039:113–125); any
  --    exception (raced insufficiency, unknown item) aborts THIS WHOLE transaction — every prior
  --    spend rolls back, nothing is minted, and NO receipt is written (0099/0104 law).
  for r in
    select item_id, qty from module_recipe_ingredients
      where module_type_id = p_module_type
      order by item_id
  loop
    perform public.inventory_spend(p_player, r.item_id, r.qty);
  end loop;

  -- 8) MINT exactly ONE instance via the Modules leaf (0108's sole writer; decision 4). The key
  --    is namespaced per 0108's producer contract — 'craft:<player>:<request_id>' can never
  --    collide with another producer's keys, and a replayed insert can never mint twice.
  v_instance := public.modules_mint_instance(
    p_player, p_module_type, 'craft:' || p_player::text || ':' || p_request_id);

  -- 9) RECEIPT (Production writes module_craft_receipts directly — its own table; the
  --    (player_id, request_id) key finalizes idempotency atomically with the spends + mint).
  insert into module_craft_receipts (player_id, request_id, module_type_id, instance_id)
    values (p_player, p_request_id, p_module_type, v_instance)
    returning receipt_id, created_at into v_receipt, v_created;

  return jsonb_build_object('ok', true,
    'receipt_id', v_receipt, 'instance_id', v_instance,
    'module_type_id', p_module_type, 'crafted_at', v_created);
end;
$$;

-- ── 3) craft_module — authenticated public wrapper (0099:221–300 wrapper idiom) ───────────────────
-- DARK TODAY: module_crafting_enabled = 'false', so both the gate below and the writer's first
-- check reject every call — the entire surface ships server-rejected with no client UI.
create or replace function public.craft_module(
  p_request_id  text,
  p_module_type text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_res    jsonb;
  v_reason text;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated', 'message', 'You must be signed in.');
  end if;

  -- flag gate FIRST (defense-in-depth + anti-probe, 0083/0099 idiom): while dark, the answer is
  -- identical regardless of input — no catalog/recipe/balance info can be inferred. The writer
  -- re-checks first and is the final authority.
  if not public.cfg_bool('module_crafting_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Module crafting is not available yet.');
  end if;

  -- Delegate. The writer is the final authority on flag/validation/idempotency/spend/mint.
  v_res := public.production_craft_module(v_player, p_module_type, p_request_id);

  if (v_res->>'ok')::boolean is true then
    return jsonb_build_object(
      'ok', true,
      'idempotent_replay', coalesce((v_res->>'idempotent_replay')::boolean, false),
      'receipt_id', v_res->'receipt_id',
      'instance_id', v_res->'instance_id',
      'module_type_id', v_res->'module_type_id',
      'crafted_at', v_res->'crafted_at');
  end if;

  v_reason := coalesce(v_res->>'reason', 'unavailable');
  return jsonb_build_object(
    'ok', false,
    'code', case v_reason
      when 'feature_disabled'   then 'feature_disabled'
      when 'invalid_request_id' then 'invalid_request'
      when 'unknown_module'     then 'unknown_module'
      when 'no_recipe'          then 'no_recipe'
      when 'insufficient_items' then 'insufficient_items'
      else 'unavailable'
    end,
    'message', case v_reason
      when 'feature_disabled'   then 'Module crafting is not available yet.'
      when 'invalid_request_id' then 'Invalid command request.'
      when 'unknown_module'     then 'Unknown module design.'
      when 'no_recipe'          then 'This module design cannot be crafted yet.'
      when 'insufficient_items' then 'Not enough materials to craft this module.'
      else 'Module crafting is unavailable right now.'
    end)
    -- the insufficient_items failure passes its per-item context through (the 0104
    -- retry_after_seconds pass-through idiom):
    || case when v_reason = 'insufficient_items'
         then jsonb_build_object('item_id', v_res->'item_id', 'have', v_res->'have', 'need', v_res->'need')
         else '{}'::jsonb
       end;
end;
$$;

-- ── 4) ACL (anti-cheat; targeted 0083/0095 idiom, verbatim from 0099:302–311 / 0104:291–299 —
--       the 0064-era default-privileges revoke already denies new functions, these re-assert
--       explicitly). No existing grant is touched.
-- the private writer stays OFF the client surface:
revoke execute on function public.production_craft_module(uuid, text, text) from public, anon, authenticated;
grant  execute on function public.production_craft_module(uuid, text, text) to service_role;
-- the ONE new client command (dark: both its gate and the writer's first check reject today):
revoke execute on function public.craft_module(text, text) from public, anon;
grant  execute on function public.craft_module(text, text) to authenticated;
