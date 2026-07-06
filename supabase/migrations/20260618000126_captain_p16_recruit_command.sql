-- Byeharu — CAPTAIN-P16 SLICE 3: the dark recruit command — captain_recruit_receipts (player-scoped
-- idempotency ledger, Production-owned) + the two-layer recruit_captain wrapper → private
-- production_recruit_captain writer. NO read surface, NO adapter change, NO frontend this slice.
--
-- This is the 0109 module-craft command mirrored POINT-FOR-POINT with the captain domain
-- substituted: crafting a module → recruiting a captain. Same two-layer wrapper, same
-- dark-gate-first, same advisory lock before replay, same verbatim replay, same insufficient_items
-- pre-check, same spend loop, same single mint, same receipt, same ACLs, same reason→code/message
-- map. Only the domain nouns and the mint/recipe leaves change.
--
-- THE ENTIRE SURFACE IS DARK TODAY: captain_progression_enabled = 'false' (0124), and the private
-- writer rejects 'feature_disabled' BEFORE any other read (the 0097/0102 reject-before-any-read
-- law), with the defense-in-depth + anti-probe gate in the public wrapper too (0083/0099 idiom —
-- a dark feature answers identically regardless of input).
--
-- IDIOM SOURCES (all inherited via the 0109 mirror):
--   · two-layer wrapper → private writer + reason→code/message map + ACL: 0109 (itself 0099/0104).
--   · dark-gate-first + envelope error style: 0109:104–116 (jsonb {ok:false, reason}).
--   · player-scoped receipts table shape + RLS: 0109:55–84 (module_craft_receipts — the
--     Production-owned per-player idempotent ledger: unique (player_id, request_id), owner-read
--     select, no write path).
--   · REPLAY SEMANTICS — the TRADE/craft player-scoped idiom (0109:125–136): a receipt for
--     (player, request_id) replays the ORIGINAL success envelope rebuilt VERBATIM from the receipt
--     row, flagged 'idempotent_replay', with NO payload-conflict check (a same-key-different-type
--     replay returns the original receipt's data). The ship-scoped hash check does not apply — this
--     is player-scoped, like craft_module.
--   · insufficient-balance envelope: 0109:161–164 ('insufficient_items' + {item_id, have, need}),
--     checked BEFORE any spend.
--   · per-player race-safety lock BEFORE the replay check: 0109:123 (the 0078/0080 commission
--     advisory-lock idiom pg_advisory_xact_lock(hashtext(<domain>), hashtext(player))).
--
-- LOCKED-DECISION ENFORCEMENT (Phase-16 design, DEV_LOG 2026-07-04 SLICE 1/2):
--   · The command belongs to PRODUCTION (ROADMAP law 5 "Production = crafting"): captain_recruit_
--     receipts is Production-owned; the writer fans out one-directionally DOWNWARD to Inventory
--     (inventory_spend — reusing Production's EXISTING spend edge from 0109) and Captain
--     (captains_mint_instance — 0118's sole writer, whose FIRST caller this now is), reading the
--     Captain recipe config (captain_recipe_ingredients) DOWNWARD — acyclic, no second writer to any
--     table. Recruitment NEVER touches player_inventory / inventory_ledger / captain_instances
--     directly — only through the two leaf functions (the forbidden-column law). Captain stays a
--     pure instance-leaf: NO Captain→Inventory edge (the recipe CONFIG is Captain's, the recruit
--     COMMAND is Production's).
--   · INSTANT + IDEMPOTENT: one SECURITY DEFINER function = one transaction; the ingredient spends,
--     the mint, and the receipt commit or roll back TOGETHER. inventory_spend's exceptions
--     (insufficient/unknown — 0039:113–121) abort the whole recruit: a failed recruit writes NO
--     receipt (0099/0104/0109 failure-writes-no-receipt law) and spends nothing.
--   · ITEMS-ONLY COST: the recipe rows (0125) are the entire price — no metal, no credits, no
--     Base/Wallet edge.
--   · ONE RECRUIT = ONE INSTANCE: exactly one captains_mint_instance call per recruit, mint key
--     'recruit:' || player || ':' || request_id — namespaced per 0108's key contract, so a replayed
--     insert race can never mint twice and can never collide with 'craft:' or any other producer.
--   · request_id is TEXT (the locked recruit_captain(p_request_id text, …) signature; validated
--     non-empty and length-capped below since text lacks uuid's intrinsic bound; clients send
--     crypto.randomUUID() strings).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): captain_recruit_receipts →
-- Production (sole writer = production_recruit_captain; owner-read). The Captain §1/§2
-- "NO caller exists yet" note on captains_mint_instance is replaced: production_recruit_captain
-- (0126) is now its ONE caller (the 0109-replaces-Modules-note precedent). New edges, all DOWNWARD:
-- Production → Captain (mint), Production → Captain recipe read, reusing Production → Inventory
-- (spend) + Production → Reference/Config (cfg read) — no cycle. No flag flipped; 0001–0125 unedited.

-- ── 1) captain_recruit_receipts — per-player idempotent recruit ledger (Production-owned) ─────────
create table public.captain_recruit_receipts (
  receipt_id      uuid primary key default gen_random_uuid(),
  player_id       uuid not null references auth.users (id) on delete cascade,
  request_id      text not null,                                     -- idempotency key (per-player)
  captain_type_id text not null references public.captain_types (id),
  -- on delete cascade: an instance row only ever disappears via the auth.users cascade today (no
  -- delete path exists); cascading the receipt with it keeps account deletion order-safe across
  -- the multi-path cascade graph (the 0088 child-FK lesson).
  instance_id     uuid not null references public.captain_instances (id) on delete cascade,
  created_at      timestamptz not null default now(),
  unique (player_id, request_id)                                     -- per-player idempotent recruit key
);
-- No extra index: the unique (player_id, request_id) index leads on player_id and already covers
-- both idempotency probes and owner-scoped lookups (the 0109:68–69 comment idiom).

alter table public.captain_recruit_receipts enable row level security;
-- Owner-read only (0109:72–77 posture verbatim); granted to authenticated, NOT anon. NO insert/
-- update/delete policy and NO write grant → clients cannot mutate; Production is sole writer
-- (server-only RPC below).
create policy "captain_recruit_receipts_select_own" on public.captain_recruit_receipts
  for select using (player_id = auth.uid());
grant select on public.captain_recruit_receipts to authenticated;

comment on table public.captain_recruit_receipts is
  'CAPTAIN-P16: per-player idempotent recruit ledger (Production-owned; sole writer = '
  'production_recruit_captain via the public recruit_captain wrapper). unique (player_id, request_id) '
  'is the replay key — a replayed recruit returns the original envelope verbatim (0089/0095/0109 '
  'trade semantics, no payload-conflict check). Players read only their own rows. Feature DARK behind '
  'captain_progression_enabled.';

-- ── 2) production_recruit_captain — PRIVATE writer (Production); SOLE writer of captain_recruit_receipts ─
create or replace function public.production_recruit_captain(
  p_player       uuid,
  p_captain_type text,
  p_request_id   text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rcpt     captain_recruit_receipts%rowtype;
  r          record;
  v_have     integer;
  v_instance uuid;
  v_receipt  uuid;
  v_created  timestamptz;
begin
  -- 1) DARK GATE FIRST (0124 law / 0109:104–109 idiom): while captain_progression_enabled is false,
  --    reject deterministically BEFORE any other read — no receipt read, no catalog read, no
  --    balance read.
  if not public.cfg_bool('captain_progression_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation. request_id is TEXT (the locked signature): non-empty, sanity-capped
  --    (a text key must not become an unbounded indexed payload — clients send 36-char
  --    crypto.randomUUID() strings). The 0109:111–116 check verbatim.
  if p_request_id is null or p_request_id = '' or length(p_request_id) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) per-player serialization BEFORE the replay check (the 0078/0080 commission advisory-lock
  --    idiom, 0109:118–123): concurrent recruits for the SAME player queue here, so a
  --    same-request_id race always resolves to one recruit + one verbatim replay, and the
  --    pre-check → spend window below cannot be raced by another recruit of this player.
  perform pg_advisory_xact_lock(hashtext('captain_recruit'), hashtext(p_player::text));

  -- 4) IDEMPOTENCY REPLAY (0109:125–136 semantics, matched exactly): a receipt for
  --    (player, request_id) already exists → rebuild the ORIGINAL success envelope from the receipt
  --    row verbatim — no write, no re-spend, no re-mint. NO payload-conflict check (the trade/craft
  --    player-scoped idiom).
  select * into v_rcpt from captain_recruit_receipts
    where player_id = p_player and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_rcpt.receipt_id, 'instance_id', v_rcpt.instance_id,
      'captain_type_id', v_rcpt.captain_type_id, 'recruited_at', v_rcpt.created_at);
  end if;

  -- 5) catalog validation: the captain type must exist AND have a recipe. A catalog row with no
  --    captain_recipe_ingredients rows is unrecruitable — a DISTINCT truthful reason (no_recipe), so
  --    a seed gap is diagnosable and never conflated with a bad id (unknown_captain). The 0109:138–147
  --    check verbatim.
  if p_captain_type is null
     or not exists (select 1 from captain_types where id = p_captain_type) then
    return jsonb_build_object('ok', false, 'reason', 'unknown_captain');
  end if;
  if not exists (select 1 from captain_recipe_ingredients where captain_type_id = p_captain_type) then
    return jsonb_build_object('ok', false, 'reason', 'no_recipe');
  end if;

  -- 6) ingredient pre-check via Inventory's read leaf — friendly envelope BEFORE anything is spent
  --    (the 0109:149–165 shape, with per-item context). Authoritative enforcement stays
  --    inventory_spend's own FOR UPDATE re-check; this pre-check exists so the common shortfall
  --    answers with an envelope instead of an exception. Race-safe for recruits by the step-3
  --    player lock.
  for r in
    select item_id, qty from captain_recipe_ingredients
      where captain_type_id = p_captain_type
      order by item_id
  loop
    v_have := public.inventory_get_balance(p_player, r.item_id);
    if v_have < r.qty then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_items',
        'item_id', r.item_id, 'have', v_have, 'need', r.qty);
    end if;
  end loop;

  -- 7) SPEND via Inventory (the sole player_inventory/inventory_ledger writer — recruitment never
  --    touches them directly). Each call is row-locked + transactional (0039:113–125); any
  --    exception (raced insufficiency, unknown item) aborts THIS WHOLE transaction — every prior
  --    spend rolls back, nothing is minted, and NO receipt is written (0099/0104/0109 law).
  for r in
    select item_id, qty from captain_recipe_ingredients
      where captain_type_id = p_captain_type
      order by item_id
  loop
    perform public.inventory_spend(p_player, r.item_id, r.qty);
  end loop;

  -- 8) MINT exactly ONE instance via the Captain leaf (0118's sole writer). The key is namespaced
  --    per 0108's producer contract — 'recruit:<player>:<request_id>' can never collide with
  --    'craft:' or another producer's keys, and a replayed insert can never mint twice.
  v_instance := public.captains_mint_instance(
    p_player, p_captain_type, 'recruit:' || p_player::text || ':' || p_request_id);

  -- 9) RECEIPT (Production writes captain_recruit_receipts directly — its own table; the
  --    (player_id, request_id) key finalizes idempotency atomically with the spends + mint).
  insert into captain_recruit_receipts (player_id, request_id, captain_type_id, instance_id)
    values (p_player, p_request_id, p_captain_type, v_instance)
    returning receipt_id, created_at into v_receipt, v_created;

  return jsonb_build_object('ok', true,
    'receipt_id', v_receipt, 'instance_id', v_instance,
    'captain_type_id', p_captain_type, 'recruited_at', v_created);
end;
$$;

-- ── 3) recruit_captain — authenticated public wrapper (0109:197–263 wrapper idiom) ────────────────
-- DARK TODAY: captain_progression_enabled = 'false', so both the gate below and the writer's first
-- check reject every call — the entire surface ships server-rejected with no client UI.
create or replace function public.recruit_captain(
  p_request_id   text,
  p_captain_type text
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

  -- flag gate FIRST (defense-in-depth + anti-probe, 0083/0099/0109 idiom): while dark, the answer is
  -- identical regardless of input — no catalog/recipe/balance info can be inferred. The writer
  -- re-checks first and is the final authority.
  if not public.cfg_bool('captain_progression_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Captain recruitment is not available yet.');
  end if;

  -- Delegate. The writer is the final authority on flag/validation/idempotency/spend/mint.
  v_res := public.production_recruit_captain(v_player, p_captain_type, p_request_id);

  if (v_res->>'ok')::boolean is true then
    return jsonb_build_object(
      'ok', true,
      'idempotent_replay', coalesce((v_res->>'idempotent_replay')::boolean, false),
      'receipt_id', v_res->'receipt_id',
      'instance_id', v_res->'instance_id',
      'captain_type_id', v_res->'captain_type_id',
      'recruited_at', v_res->'recruited_at');
  end if;

  v_reason := coalesce(v_res->>'reason', 'unavailable');
  return jsonb_build_object(
    'ok', false,
    'code', case v_reason
      when 'feature_disabled'   then 'feature_disabled'
      when 'invalid_request_id' then 'invalid_request'
      when 'unknown_captain'    then 'unknown_captain'
      when 'no_recipe'          then 'no_recipe'
      when 'insufficient_items' then 'insufficient_items'
      else 'unavailable'
    end,
    'message', case v_reason
      when 'feature_disabled'   then 'Captain recruitment is not available yet.'
      when 'invalid_request_id' then 'Invalid command request.'
      when 'unknown_captain'    then 'Unknown captain.'
      when 'no_recipe'          then 'This captain cannot be recruited yet.'
      when 'insufficient_items' then 'Not enough materials to recruit this captain.'
      else 'Captain recruitment is unavailable right now.'
    end)
    -- the insufficient_items failure passes its per-item context through (the 0104/0109
    -- pass-through idiom):
    || case when v_reason = 'insufficient_items'
         then jsonb_build_object('item_id', v_res->'item_id', 'have', v_res->'have', 'need', v_res->'need')
         else '{}'::jsonb
       end;
end;
$$;

-- ── 4) ACL (anti-cheat; verbatim from 0109:265–273 — the 0064-era default-privileges revoke already
--       denies new functions, these re-assert explicitly). No existing grant is touched.
-- the private writer stays OFF the client surface:
revoke execute on function public.production_recruit_captain(uuid, text, text) from public, anon, authenticated;
grant  execute on function public.production_recruit_captain(uuid, text, text) to service_role;
-- the ONE new client command (dark: both its gate and the writer's first check reject today):
revoke execute on function public.recruit_captain(text, text) from public, anon;
grant  execute on function public.recruit_captain(text, text) to authenticated;
