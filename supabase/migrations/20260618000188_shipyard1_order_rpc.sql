-- Byeharu — SHIPYARD-1 (the SHIPYARD charter, slice 1 of SHIPYARD-0..3 + ACT-SHIPYARD): the hull
-- BUILD COMMAND — `start_hull_build` enqueues a T1+ hull build on the REUSED M4.5 `build_orders`
-- serial queue (never a second timer system), spending ingredients via Inventory's
-- `inventory_spend` + credits via Wallet's `wallet_debit`, enforcing the 0185 recipe gates
-- (required hull / required captain level, both dormant-NULL on the T1 seeds). Everything DARK
-- behind `shipyard_enabled='false'` (0185 — unchanged here; every reject is gate-first,
-- reject-before-any-read, in BOTH layers).
--
-- ── THE SEAM DIVISION (the charter, verbatim discipline) ─────────────────────────────────────────
--   SHIPYARD-1 (THIS slice) owns the ORDER side ONLY: validate → spend → enqueue → receipt.
--   SHIPYARD-2 owns build COMPLETION → DELIVERY: it re-creates the queue engine
--   (`production_start_next` / `process_build_queue`, head 0038) with the hull arm and commissions
--   the built ship through the ONE commission build core (`port_entry_commission_build`
--   parity re-create taking p_hull_type_id — retiring the SYSTEM_BOUNDARIES fleets-shim exception).
--   THIS SLICE TOUCHES NO LIVE FUNCTION. That is deliberate and load-bearing:
--
-- ── HULL ORDERS ARE INVISIBLE TO THE 0038 QUEUE ENGINE — BY CONSTRUCTION, VERIFIED ───────────────
--   A hull order lands 'waiting' with unit_type_id NULL. The 0038 engine cannot see it:
--     · `production_start_next` (TRUE head 0038 — grep-verified: 0036/0038 are the ONLY create
--       sites of every queue function; later files only grant/reference) selects the next waiting
--       row through `join unit_types ut on ut.id = bo.unit_type_id` — a NULL-unit row never joins,
--       so a hull order is NEVER promoted to 'active' and never gets a complete_at. Unit training
--       is untouched: the join filters hull rows out of the pick, waiting unit rows still promote.
--     · `process_build_queue` (head 0038) loops `status = 'active'` rows only — a hull order never
--       reaches it, so its unit-shaped `base_merge_units(o.base_id, …)` delivery can never fire on
--       a NULL base/unit row. The self-assert below PINS both prosrc facts at apply time.
--   Honest-dark: `shipyard_enabled` is committed FALSE, so no hull order can exist in production
--   until ACT-SHIPYARD — whose preconditions REQUIRE SHIPYARD-2 (the delivery half) shipped.
--   A lit hull order sits 'waiting' (credits+items already paid, the M4.5 pay-up-front law) until
--   the SHIPYARD-2 engine starts its timer and delivers it.
--   KNOWN SEAM ITEM FOR SHIPYARD-2 (documented, not a live hazard): `cancel_build_order` (0038, a
--   live client RPC, untouched here) would flip a waiting hull order to 'cancelled' refunding only
--   metal_spent (= 0 on hull orders; its base_add_resources call is skipped at refund 0, and
--   base_id is NULL anyway) — the ingredients/credits would be eaten. Cannot fire while dark (no
--   hull order can exist); SHIPYARD-2 MUST ship hull-aware cancel/refund semantics before
--   ACT-SHIPYARD flips. Recorded in FULL_CAPACITY_PLAN §C P6 this same PR.
--
-- ── WHAT THIS SHIPS ──────────────────────────────────────────────────────────────────────────────
--   1. ADDITIVE `build_orders` generalization (forward-only; the 0038 alter idiom):
--      `unit_type_id` + `base_id` drop NOT NULL, new `hull_type_id` (FK `hull_build_recipes` — the
--      STRICT FK: only a recipe-carrying hull is orderable, so T0 `starter_frigate` — deliberately
--      recipe-less, the credits-only commission — can never be enqueued), new `credits_spent`
--      (>= 0, default 0), and the `build_orders_kind_coherent` CHECK: a row is EITHER a unit order
--      (unit + base set, hull NULL — every pre-0188 row) OR a hull order (hull set, unit + base
--      NULL — a hull build has no base; delivery commissions a ship at a port, SHIPYARD-2).
--   2. `hull_build_receipts` — the per-player idempotency ledger (Production-owned), the
--      module_craft_receipts (0109) / captain_recruit_receipts (0126) posture point-for-point:
--      unique (player_id, request_id), owner-read RLS, NO client write path, replay returns the
--      ORIGINAL success envelope rebuilt verbatim from the receipt (the 0089/0095 trade-receipts
--      semantics — deliberately NO payload-conflict check). request_id is uuid (the 0174/0179
--      receipt idiom). LIFETIME (review H1): receipts OUTLIVE their order rows — the 0047 reaper
--      deletes terminal build_orders >30d, so order_id is ON DELETE SET NULL; replay + audit are
--      guaranteed by the receipt row alone (only account deletion removes it, via player_id).
--   3. `production_start_hull_build(player, hull_type, request_id)` — the PRIVATE Production
--      writer (service_role/internal; the 0109 two-layer idiom): gate-first → input → per-player
--      advisory lock ('hull_build' domain, BEFORE the replay check) → replay → catalog
--      (unknown_hull vs no_recipe — the 0109 distinct-truthful-reason posture) → progression gates
--      (required hull owned & not destroyed / any owned captain at required level — the 0177
--      `captain_instances.level` column; both arms dormant on the NULL T1 seeds, enforced the day
--      a T2 recipe sets them) → the SHARED M4.5 queue cap (`max_build_orders` over waiting+active,
--      the train_units 0038 predicate verbatim — one queue, one cap) → ingredient pre-check
--      (friendly envelope BEFORE any write) → `wallet_debit` (the FIRST write; false = friendly
--      insufficient_credits envelope — at that point nothing has been spent, wallet_ensure's
--      idempotent seed insert being the only side effect, exactly the 0089 market_buy posture) →
--      `inventory_spend` per ingredient (its exceptions abort the WHOLE txn — debit included:
--      all-or-nothing; a failed order writes NO receipt, the 0099/0104 law) → the build_orders
--      insert (quantity 1, status 'waiting', NO complete_at — the M4.5 serial law: only ACTIVE
--      rows carry timestamps) → its own receipt. DETERMINISTIC throughout (the 0041 law): no
--      random(), ingredient order pinned `order by item_id`, price/time read from the catalog row.
--   4. `start_hull_build(request_id, hull_type)` — the authenticated PUBLIC wrapper (0109
--      craft_module idiom): auth → anti-probe gate (while dark the answer is IDENTICAL regardless
--      of input — no hull-existence oracle) → delegate → reason→code/message map.
--   5. NO cron edits, NO engine edits, NO client code. Proof = scripts/shipyard-proof.{sql,sh} +
--      .github/workflows/shipyard-proof.yml (standalone — team-command-proof is contended by two
--      in-flight slices; modeled on trade-v1-proof.yml, REUSING scripts/lib/trade-proof-lib.sh).
--
-- ── FAN-OUT (one-directional DOWNWARD, acyclic — the §3 edge law) ────────────────────────────────
--   Production (this command) → Reference/Config (cfg + hull_build_recipes/hull_recipe_ingredients
--   read — their first live reader) · Main Ship (main_ship_instances read-only, the required-hull
--   gate) · Captain (captain_instances read-only, the level gate) · Inventory (inventory_get_balance
--   read + inventory_spend — the sole player_inventory writer) · Wallet (wallet_debit — the sole
--   player_wallet writer) → its own build_orders + hull_build_receipts. NO other table written.
--   Production NEVER writes player_inventory/inventory_ledger/player_wallet directly.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same PR — the §E law): build_orders row gains
-- the hull-order shape + this writer; hull_build_receipts → Production (sole writer =
-- production_start_hull_build via start_hull_build); the two 0185 recipe tables' "NOTHING reads it
-- today" notes are replaced (this command is their first reader). Docs synced: FULL_CAPACITY_PLAN
-- (P6 SHIPYARD-1 → shipped + the SHIPYARD-2 seam items), DEV_LOG.
--
-- Forward-only: 0001–0185 unedited. (0186/0187 are claimed by in-flight slices.)

-- ── (a) build_orders — the ADDITIVE hull-order generalization (the 0038 alter idiom) ─────────────
alter table public.build_orders alter column unit_type_id drop not null;
alter table public.build_orders alter column base_id drop not null;
alter table public.build_orders
  add column if not exists hull_type_id text references public.hull_build_recipes (hull_type_id);
alter table public.build_orders
  add column if not exists credits_spent numeric not null default 0 check (credits_spent >= 0);
-- kind coherence: EITHER a unit order (the entire pre-0188 population) OR a hull order — never a
-- hybrid, never a bare row. Validates every existing row at apply time (unit + base were NOT NULL
-- until this migration, hull_type_id is brand new → all legacy rows take the first arm).
alter table public.build_orders drop constraint if exists build_orders_kind_coherent;
alter table public.build_orders add constraint build_orders_kind_coherent check (
  (hull_type_id is null and unit_type_id is not null and base_id is not null)
  or
  (hull_type_id is not null and unit_type_id is null and base_id is null)
);

-- ── (b) hull_build_receipts — per-player idempotent order ledger (Production-owned; 0109 shape) ──
create table public.hull_build_receipts (
  receipt_id    uuid primary key default gen_random_uuid(),
  player_id     uuid not null references auth.users (id) on delete cascade,
  request_id    uuid not null,                                       -- idempotency key (per-player)
  hull_type_id  text not null references public.hull_build_recipes (hull_type_id),
  -- ON DELETE SET NULL, nullable — THE LIFETIME STORY (review H1, 2026-07-13): build_orders is
  -- RUNTIME data with a live reaper — maintenance_cleanup_runtime_data (0047 §10, cron) deletes
  -- terminal (completed/cancelled) orders older than 30 days. The receipt is the DURABLE
  -- idempotency + audit ledger and MUST outlive its order row: a cascade here would let the
  -- reaper silently expire the replay guarantee (a stale retry after the purge would place a
  -- SECOND full-price order) and destroy the audit bill. So the reap sets order_id NULL and the
  -- receipt survives; replay is guaranteed by the receipt row ALONE (the writer's step 4 reads
  -- only hull_build_receipts — never through this FK). The 0109/0126 cascade precedent does NOT
  -- transfer: those FK durable property tables (module/captain instances), not reaped runtime
  -- rows. Player-deletion cleanup still holds via the player_id cascade above.
  order_id      uuid references public.build_orders (id) on delete set null,
  credits_spent numeric not null check (credits_spent >= 0),
  -- the exact ingredient spends at order time (audit; [{item_id, quantity}, …] in item_id order —
  -- deterministic). The receipt is the replay source: the envelope rebuilds from THIS row verbatim.
  ingredients_json jsonb not null default '[]'::jsonb,
  created_at    timestamptz not null default now(),
  unique (player_id, request_id)                                     -- per-player idempotent key
);
-- No extra index: the unique (player_id, request_id) index leads on player_id and already covers
-- both idempotency probes and owner-scoped lookups (the 0086/0109 comment idiom).

alter table public.hull_build_receipts enable row level security;
-- Owner-read only (the 0094/0109 posture verbatim); granted to authenticated, NOT anon. NO insert/
-- update/delete policy and NO write grant → clients cannot mutate; Production is sole writer.
create policy "hull_build_receipts_select_own" on public.hull_build_receipts
  for select using (player_id = auth.uid());
grant select on public.hull_build_receipts to authenticated;

comment on table public.hull_build_receipts is
  'SHIPYARD-1: per-player idempotent hull-build-order ledger (Production-owned; sole writer = '
  'production_start_hull_build via the public start_hull_build wrapper). unique (player_id, '
  'request_id) is the replay key — a replayed order returns the original envelope verbatim '
  '(0089/0095 trade semantics, no payload-conflict check). Players read only their own rows. '
  'Feature DARK behind shipyard_enabled.';

-- ── (c) production_start_hull_build — PRIVATE writer (Production); the ORDER side of SHIPYARD ────
create or replace function public.production_start_hull_build(
  p_player       uuid,
  p_hull_type_id text,
  p_request_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rcpt    hull_build_receipts%rowtype;
  v_recipe  hull_build_recipes%rowtype;
  r         record;
  v_have    integer;
  v_max     integer;
  v_active  integer;
  v_spent   jsonb := '[]'::jsonb;
  v_order   uuid;
  v_receipt uuid;
  v_created timestamptz;
begin
  -- 1) DARK GATE FIRST (the 0185 header's standing order / 0099:108–113 idiom): while
  --    shipyard_enabled is false, reject deterministically BEFORE any other read — no receipt
  --    read, no catalog read, no balance read, no existence oracle.
  if not public.cfg_bool('shipyard_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation (request_id is uuid — intrinsically bounded, the 0174/0179 idiom).
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) per-player serialization BEFORE the replay check (the 0078/0080 commission advisory-lock
  --    idiom, exactly the 0109 step-3 posture, own domain): concurrent orders for the SAME player
  --    queue here, so a same-request_id race always resolves to one order + one verbatim replay,
  --    and the pre-check → spend window below cannot be raced by another hull order of this
  --    player. (Cross-command races on the same inventory — craft/recruit/salvage — are backstopped
  --    by inventory_spend's own FOR UPDATE re-check: a raced shortfall raises and aborts this whole
  --    txn, spends + debit + order + receipt together — the all-or-nothing law.)
  perform pg_advisory_xact_lock(hashtext('hull_build'), hashtext(p_player::text));

  -- 4) IDEMPOTENCY REPLAY (0089:108–116 / 0095:60–66 semantics, matched exactly): a receipt for
  --    (player, request_id) already exists → rebuild the ORIGINAL success envelope from the
  --    receipt row verbatim — no write, no re-spend, no re-debit, no second order. NO
  --    payload-conflict check (the trade-receipts idiom).
  select * into v_rcpt from hull_build_receipts
    where player_id = p_player and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_rcpt.receipt_id, 'order_id', v_rcpt.order_id,
      'hull_type_id', v_rcpt.hull_type_id, 'credits_spent', v_rcpt.credits_spent,
      'ingredients_spent', v_rcpt.ingredients_json, 'queued_at', v_rcpt.created_at);
  end if;

  -- 5) catalog validation (the 0109 step-5 distinct-truthful-reason posture): a hull id absent
  --    from the hull register is unknown_hull; a REAL hull with no build recipe (T0
  --    starter_frigate — the credits-only commission, deliberately recipe-less) is no_recipe.
  if p_hull_type_id is null
     or not exists (select 1 from main_ship_hull_types where hull_type_id = p_hull_type_id) then
    return jsonb_build_object('ok', false, 'reason', 'unknown_hull');
  end if;
  select * into v_recipe from hull_build_recipes where hull_type_id = p_hull_type_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_recipe');
  end if;

  -- 6) PROGRESSION GATES (the 0185 T2+ columns; both NULL on the T1 seeds → dormant arms,
  --    enforced the day a recipe sets them — "enforcing the recipe gates when lit", the charter).
  --    required_hull_type_id: the player must OWN a non-destroyed ship of the prerequisite hull.
  if v_recipe.required_hull_type_id is not null and not exists (
       select 1 from main_ship_instances
       where player_id = p_player
         and hull_type_id = v_recipe.required_hull_type_id
         and status <> 'destroyed') then
    return jsonb_build_object('ok', false, 'reason', 'hull_prerequisite_not_met',
      'required_hull_type_id', v_recipe.required_hull_type_id);
  end if;
  --    required_captain_level: ANY owned captain at the required level (the owner's "level
  --    requirement"; captain_instances.level is the 0177 column, sole writer captain_xp_accrue).
  if v_recipe.required_captain_level is not null and not exists (
       select 1 from captain_instances
       where player_id = p_player and level >= v_recipe.required_captain_level) then
    return jsonb_build_object('ok', false, 'reason', 'captain_level_too_low',
      'required_captain_level', v_recipe.required_captain_level);
  end if;

  -- 7) the SHARED M4.5 queue cap — ONE queue, ONE cap: hull orders and training orders count
  --    together (the train_units 0038 predicate verbatim: waiting + active, non-terminal).
  v_max := coalesce(cfg_num('max_build_orders'), 5)::integer;
  select count(*) into v_active from build_orders
    where player_id = p_player and status in ('waiting', 'active');
  if v_active >= v_max then
    return jsonb_build_object('ok', false, 'reason', 'queue_full', 'max', v_max);
  end if;

  -- 8) ingredient pre-check via Inventory's read leaf — friendly envelope BEFORE any write (the
  --    0109 step-6 shape, per-item context). Authoritative enforcement stays inventory_spend's own
  --    FOR UPDATE re-check. Recipe quantities are integral by the catalog law (self-asserted at
  --    apply time below); a fractional row is catalog corruption → hard abort, never a rounding.
  for r in
    select item_id, qty from hull_recipe_ingredients
      where hull_type_id = p_hull_type_id
      order by item_id
  loop
    if r.qty <> floor(r.qty) then
      raise exception 'production_start_hull_build: non-integral recipe qty % for % (catalog corruption)',
        r.qty, r.item_id;
    end if;
    v_have := public.inventory_get_balance(p_player, r.item_id);
    if v_have < r.qty then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_items',
        'item_id', r.item_id, 'have', v_have, 'need', r.qty::integer);
    end if;
  end loop;

  -- 9) CREDITS via Wallet (the sole player_wallet writer) — the FIRST write. wallet_debit's
  --    conditional UPDATE row-locks the wallet and returns false if too poor (the 0089 market_buy
  --    posture): at that point NOTHING has been spent (the only side effect is wallet_ensure's
  --    idempotent seed insert, exactly as market_buy), so the friendly envelope is safe to return.
  if not public.wallet_debit(p_player, v_recipe.credits_cost) then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_credits',
      'need', v_recipe.credits_cost);
  end if;

  -- 10) SPEND via Inventory (the sole player_inventory/inventory_ledger writer — this command
  --     never touches them directly). Each call is row-locked + transactional (0039:113–125); any
  --     exception (raced insufficiency, unknown item) aborts THIS WHOLE transaction — the step-9
  --     debit and every prior spend roll back, no order is enqueued, and NO receipt is written
  --     (the 0099/0104 failure-writes-no-receipt law). Deterministic item_id order.
  for r in
    select item_id, qty from hull_recipe_ingredients
      where hull_type_id = p_hull_type_id
      order by item_id
  loop
    perform public.inventory_spend(p_player, r.item_id, r.qty::integer);
    v_spent := v_spent || jsonb_build_object('item_id', r.item_id, 'quantity', r.qty::integer);
  end loop;

  -- 11) ENQUEUE on the M4.5 serial queue (Production's own table): status 'waiting', quantity 1,
  --     NO complete_at/started_at — the M4.5 law (only ACTIVE rows carry timestamps; the
  --     SHIPYARD-2 engine will promote it with complete_at = start + recipe build_seconds).
  --     DELIBERATELY not calling production_start_next: the 0038 engine's unit_types join cannot
  --     see hull rows (pinned below) — the call would be a provable no-op on this order, and the
  --     activation semantics belong to the SHIPYARD-2 engine re-create (the charter seam).
  insert into build_orders (player_id, hull_type_id, quantity, credits_spent, status, queued_at)
    values (p_player, p_hull_type_id, 1, v_recipe.credits_cost, 'waiting', now())
    returning id into v_order;

  -- 12) RECEIPT (Production writes hull_build_receipts directly — its own table; the
  --     (player_id, request_id) key finalizes idempotency atomically with the debit + spends +
  --     order).
  insert into hull_build_receipts
    (player_id, request_id, hull_type_id, order_id, credits_spent, ingredients_json)
    values (p_player, p_request_id, p_hull_type_id, v_order, v_recipe.credits_cost, v_spent)
    returning receipt_id, created_at into v_receipt, v_created;

  return jsonb_build_object('ok', true,
    'receipt_id', v_receipt, 'order_id', v_order,
    'hull_type_id', p_hull_type_id, 'credits_spent', v_recipe.credits_cost,
    'ingredients_spent', v_spent, 'queued_at', v_created);
end;
$$;

-- ── (d) start_hull_build — authenticated public wrapper (the 0109 craft_module idiom) ────────────
-- DARK TODAY: shipyard_enabled = 'false', so both the gate below and the writer's first check
-- reject every call — the entire surface ships server-rejected with no client UI (SHIPYARD-3).
create or replace function public.start_hull_build(
  p_request_id   uuid,
  p_hull_type_id text
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
  -- identical regardless of input — no hull/recipe/balance/queue info can be inferred. The writer
  -- re-checks first and is the final authority.
  if not public.cfg_bool('shipyard_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Ship production is not available yet.');
  end if;

  -- Delegate. The writer is the final authority on flag/validation/gates/idempotency/spend/enqueue.
  v_res := public.production_start_hull_build(v_player, p_hull_type_id, p_request_id);

  if (v_res->>'ok')::boolean is true then
    return jsonb_build_object(
      'ok', true,
      'idempotent_replay', coalesce((v_res->>'idempotent_replay')::boolean, false),
      'receipt_id', v_res->'receipt_id',
      'order_id', v_res->'order_id',
      'hull_type_id', v_res->'hull_type_id',
      'credits_spent', v_res->'credits_spent',
      'ingredients_spent', v_res->'ingredients_spent',
      'queued_at', v_res->'queued_at');
  end if;

  v_reason := coalesce(v_res->>'reason', 'unavailable');
  return jsonb_build_object(
    'ok', false,
    'code', case v_reason
      when 'feature_disabled'          then 'feature_disabled'
      when 'invalid_request_id'        then 'invalid_request'
      when 'unknown_hull'              then 'unknown_hull'
      when 'no_recipe'                 then 'no_recipe'
      when 'hull_prerequisite_not_met' then 'hull_prerequisite_not_met'
      when 'captain_level_too_low'     then 'captain_level_too_low'
      when 'queue_full'                then 'queue_full'
      when 'insufficient_items'        then 'insufficient_items'
      when 'insufficient_credits'      then 'insufficient_credits'
      else 'unavailable'
    end,
    'message', case v_reason
      when 'feature_disabled'          then 'Ship production is not available yet.'
      when 'invalid_request_id'        then 'Invalid command request.'
      when 'unknown_hull'              then 'Unknown hull class.'
      when 'no_recipe'                 then 'This hull cannot be built at a shipyard.'
      when 'hull_prerequisite_not_met' then 'You must own the prerequisite hull first.'
      when 'captain_level_too_low'     then 'A higher-level captain is required.'
      when 'queue_full'                then 'Your build queue is full.'
      when 'insufficient_items'        then 'Not enough materials to start this build.'
      when 'insufficient_credits'      then 'Not enough credits to start this build.'
      else 'Ship production is unavailable right now.'
    end)
    -- failure context pass-through (the 0104/0109 idiom): per-item shortfall, gate identities,
    -- the cap, or the credit need ride the envelope so the SHIPYARD-3 UI can be truthful.
    || case v_reason
         when 'insufficient_items' then
           jsonb_build_object('item_id', v_res->'item_id', 'have', v_res->'have', 'need', v_res->'need')
         when 'insufficient_credits' then
           jsonb_build_object('need', v_res->'need')
         when 'hull_prerequisite_not_met' then
           jsonb_build_object('required_hull_type_id', v_res->'required_hull_type_id')
         when 'captain_level_too_low' then
           jsonb_build_object('required_captain_level', v_res->'required_captain_level')
         when 'queue_full' then
           jsonb_build_object('max', v_res->'max')
         else '{}'::jsonb
       end;
end;
$$;

-- ── (e) ACL (anti-cheat; the targeted 0109 idiom — the 0064-era default-privileges revoke already
--        denies new functions, these re-assert explicitly). No existing grant is touched. ─────────
-- the private writer stays OFF the client surface:
revoke execute on function public.production_start_hull_build(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function public.production_start_hull_build(uuid, text, uuid) to service_role;
-- the ONE new client command (dark: both its gate and the writer's first check reject today):
revoke execute on function public.start_hull_build(uuid, text) from public, anon;
grant  execute on function public.start_hull_build(uuid, text) to authenticated;

-- ── (f) SELF-ASSERTS — the migration proves its own grounding or refuses to land ─────────────────
do $$
declare
  v_n     integer;
  v_src   text;
  v_gate  integer;
  v_tok   text;
begin
  -- (1) the gate is still DARK — this slice lands inert (the 0185 standing order).
  if coalesce(public.cfg_bool('shipyard_enabled'), false) then
    raise exception 'SHIPYARD-1 self-assert FAIL: shipyard_enabled reads true at apply time (this slice must land dark)';
  end if;

  -- (2) the build_orders generalization landed exactly: unit_type_id + base_id nullable,
  --     hull_type_id + credits_spent present, the kind CHECK + the strict recipe FK in place.
  select count(*) into v_n from information_schema.columns
    where table_schema = 'public' and table_name = 'build_orders'
      and ((column_name in ('unit_type_id', 'base_id') and is_nullable = 'YES')
        or (column_name = 'hull_type_id' and is_nullable = 'YES')
        or (column_name = 'credits_spent' and is_nullable = 'NO'));
  if v_n <> 4 then
    raise exception 'SHIPYARD-1 self-assert FAIL: build_orders column shape is wrong (% of 4 checks)', v_n;
  end if;
  if not exists (select 1 from pg_constraint
                   where conname = 'build_orders_kind_coherent'
                     and conrelid = 'public.build_orders'::regclass and contype = 'c') then
    raise exception 'SHIPYARD-1 self-assert FAIL: build_orders_kind_coherent CHECK missing';
  end if;
  if not exists (select 1 from pg_constraint
                   where conrelid = 'public.build_orders'::regclass and contype = 'f'
                     and confrelid = 'public.hull_build_recipes'::regclass) then
    raise exception 'SHIPYARD-1 self-assert FAIL: build_orders.hull_type_id FK to hull_build_recipes missing (the only-buildable-hulls law)';
  end if;

  -- (3) THE ENGINE-INVISIBILITY GROUNDING (the load-bearing seam facts, pinned against the
  --     DEPLOYED bodies): production_start_next still picks through the unit_types join (a
  --     NULL-unit hull row can never be promoted), and process_build_queue still loops 'active'
  --     rows only (a never-promoted hull row can never reach its unit-shaped delivery).
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'production_start_next';
  if v_src is null or strpos(v_src, 'join unit_types ut on ut.id = bo.unit_type_id') = 0 then
    raise exception 'SHIPYARD-1 self-assert FAIL: production_start_next lost its unit_types join — the hull-order invisibility seam is broken (SHIPYARD-2 owns the hull arm)';
  end if;
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_build_queue';
  if v_src is null or strpos(v_src, 'status = ''active''') = 0 then
    raise exception 'SHIPYARD-1 self-assert FAIL: process_build_queue no longer loops active rows only — the hull-order invisibility seam is broken';
  end if;

  -- (4) the private writer is gate-FIRST: shipyard_enabled is checked BEFORE every read of the
  --     receipt/catalog/gate/balance surfaces (token-order pin over the deployed prosrc).
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'production_start_hull_build';
  if v_src is null then
    raise exception 'SHIPYARD-1 self-assert FAIL: production_start_hull_build not deployed';
  end if;
  -- anchor on the actual guard CALL token, not a comment mention (review N1, 2026-07-13).
  v_gate := strpos(v_src, 'cfg_bool(''shipyard_enabled''');
  if v_gate = 0 then
    raise exception 'SHIPYARD-1 self-assert FAIL: the writer does not gate on cfg_bool(shipyard_enabled)';
  end if;
  -- read/call-form tokens (never the bare table names — those also appear in the DECLARE block,
  -- which prosrc places before the gate):
  foreach v_tok in array array['from hull_build_receipts', 'from hull_build_recipes',
                               'from hull_recipe_ingredients', 'from main_ship_hull_types',
                               'from captain_instances', 'inventory_get_balance(',
                               'wallet_debit(', 'inventory_spend('] loop
    if strpos(v_src, v_tok) = 0 or strpos(v_src, v_tok) < v_gate then
      raise exception 'SHIPYARD-1 self-assert FAIL: gate-first order broken — ''%'' is read before the shipyard_enabled gate (or missing)', v_tok;
    end if;
  end loop;
  -- deterministic (the 0041 law): no random() anywhere in EITHER new body (review N2: the
  -- wrapper's prosrc is checked too, not just the writer's).
  if strpos(v_src, 'random()') <> 0 then
    raise exception 'SHIPYARD-1 self-assert FAIL: the writer calls random() (the 0041 determinism law)';
  end if;
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'start_hull_build';
  if v_src is null then
    raise exception 'SHIPYARD-1 self-assert FAIL: start_hull_build wrapper not deployed';
  end if;
  if strpos(v_src, 'random()') <> 0 then
    raise exception 'SHIPYARD-1 self-assert FAIL: the wrapper calls random() (the 0041 determinism law)';
  end if;

  -- (5) ACL posture: the wrapper is authenticated-only; the private writer is OFF the client
  --     surface entirely (service_role/owner only) — the 0109 posture.
  if not has_function_privilege('authenticated', 'public.start_hull_build(uuid, text)', 'execute') then
    raise exception 'SHIPYARD-1 self-assert FAIL: authenticated cannot execute start_hull_build';
  end if;
  if has_function_privilege('anon', 'public.start_hull_build(uuid, text)', 'execute') then
    raise exception 'SHIPYARD-1 self-assert FAIL: anon can execute start_hull_build';
  end if;
  if has_function_privilege('authenticated', 'public.production_start_hull_build(uuid, text, uuid)', 'execute')
     or has_function_privilege('anon', 'public.production_start_hull_build(uuid, text, uuid)', 'execute') then
    raise exception 'SHIPYARD-1 self-assert FAIL: the private writer is client-executable';
  end if;

  -- (6) receipts table posture: RLS on, exactly ONE policy (owner-read select), no write grant to
  --     client roles (the 0109 sole-writer posture).
  if not (select relrowsecurity from pg_class where oid = 'public.hull_build_receipts'::regclass) then
    raise exception 'SHIPYARD-1 self-assert FAIL: hull_build_receipts RLS is off';
  end if;
  select count(*) into v_n from pg_policies
    where schemaname = 'public' and tablename = 'hull_build_receipts';
  if v_n <> 1 then
    raise exception 'SHIPYARD-1 self-assert FAIL: hull_build_receipts has % policies (want exactly the one owner-read select)', v_n;
  end if;
  select count(*) into v_n from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'hull_build_receipts'
      and grantee in ('anon', 'authenticated') and privilege_type <> 'SELECT';
  if v_n <> 0 then
    raise exception 'SHIPYARD-1 self-assert FAIL: hull_build_receipts carries % non-SELECT client grant(s)', v_n;
  end if;
  --     the LIFETIME FKs (review H1): order_id SET-NULLs (the 0047 reaper deletes terminal
  --     build_orders >30d — it must never destroy the replay/audit ledger), player_id cascades
  --     (account deletion still removes the player's receipts).
  if not exists (select 1 from pg_constraint
                   where conrelid = 'public.hull_build_receipts'::regclass and contype = 'f'
                     and confrelid = 'public.build_orders'::regclass and confdeltype = 'n') then
    raise exception 'SHIPYARD-1 self-assert FAIL: hull_build_receipts.order_id FK is not ON DELETE SET NULL (the 0047 reaper would expire the replay guarantee)';
  end if;
  if not exists (select 1 from pg_constraint
                   where conrelid = 'public.hull_build_receipts'::regclass and contype = 'f'
                     and confrelid = 'auth.users'::regclass and confdeltype = 'c') then
    raise exception 'SHIPYARD-1 self-assert FAIL: hull_build_receipts.player_id FK is not ON DELETE CASCADE';
  end if;

  -- (7) the integral-quantity catalog law the spend cast relies on: every seeded recipe qty is a
  --     whole number (the RPC hard-aborts on a fractional row; this pins the seeds themselves).
  select count(*) into v_n from public.hull_recipe_ingredients where qty <> floor(qty);
  if v_n <> 0 then
    raise exception 'SHIPYARD-1 self-assert FAIL: % recipe ingredient row(s) carry non-integral qty', v_n;
  end if;

  -- (8) the 0185 T1 catalog is still exactly as seeded (the price this command charges): 2 headers
  --     at 400 credits / 3600s / NULL gates, 10 ingredient rows, no strays (light re-pin).
  select count(*) into v_n from public.hull_build_recipes
    where hull_type_id in ('bulk_hauler', 'strike_corvette')
      and credits_cost = 400 and build_seconds = 3600
      and required_hull_type_id is null and required_captain_level is null;
  if v_n <> 2 then
    raise exception 'SHIPYARD-1 self-assert FAIL: the 0185 T1 recipe headers moved (% of 2 exact)', v_n;
  end if;
  select count(*) into v_n from public.hull_recipe_ingredients;
  if v_n <> 10 then
    raise exception 'SHIPYARD-1 self-assert FAIL: hull_recipe_ingredients has % rows (want exactly the 10 0185 seeds)', v_n;
  end if;

  raise notice 'SHIPYARD-1 self-assert ok: gate dark; build_orders generalized (nullable unit/base + hull FK to recipes + credits_spent + kind CHECK); 0038 engine invisibility pinned (unit_types join + active-only loop); writer gate-first (cfg_bool-call anchored) over every surface + both bodies deterministic; ACL two-layer (authenticated wrapper, private writer off-client); receipts owner-read sole-writer with the reaper-safe SET-NULL order FK + player cascade; recipe qty integral; 0185 T1 catalog intact';
end $$;
