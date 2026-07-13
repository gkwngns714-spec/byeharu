-- Byeharu — SHIPYARD-2 (the SHIPYARD charter, slice 2 of SHIPYARD-0..3 + ACT-SHIPYARD): hull-build
-- DELIVERY — the 0038 queue engine learns the HULL arm (promotion with recipe `build_seconds` +
-- completion → commission delivery) and `cancel_build_order` learns hull-aware refunds. This closes
-- ALL THREE recorded pre-flip requirements from the 0188 seam list (FULL_CAPACITY_PLAN §C P6):
--   1. the engine's hull arm (activation + completion),
--   2. delivery through the ONE commission build core,
--   3. hull-aware cancel refund semantics.
-- Everything stays DARK behind `shipyard_enabled='false'` (0185, unchanged here) and DOUBLE-INERT:
-- while dark no hull order can exist (the 0188 writer rejects gate-first), and with ZERO hull rows
-- every re-created body behaves BYTE-IDENTICALLY to its head (the parity law — see each hunk).
--
-- ── TRUE HEADS (grep-verified across 0001–0189 before a line was written) ─────────────────────────
--   `production_start_next` / `production_complete_order` / `process_build_queue` /
--   `cancel_build_order` — created ONLY at 0036/0038; 0038 is the live head of all four (every
--   later mention is a grant/comment; 0188 deliberately did NOT re-create them — its self-assert
--   pinned their invisibility to hull rows instead; 0190–0193 touch none of them).
--   `port_entry_commission_build` — head 0193 (0080 → 0184 NAME hunk → 0193 SOUL-1 gated
--   trait-roll hook; re-verified after #134/#135/#136 merged — 0193's own collision note
--   prescribes exactly this slice's renumber + re-create-from-0193). `wallet_credit` — head 0093
--   (over 0090).
--   `inventory_deposit` — head 0039 (sole create site; optional idempotency key `p_key`).
--   `train_units` / `production_create_order` — head 0038, UNTOUCHED here (the unit ORDER side
--   needs nothing). Each body below is copied VERBATIM from its head; every delta is a marked
--   `SHIPYARD-2 (0194)` hunk — extract-and-diff-able.
--
-- ── THE DESIGN (each decision recorded; [D] = implementer decision, documented) ──────────────────
--   PROMOTION — `production_start_next` gains a SECOND candidate branch (the hull arm): the oldest
--   waiting hull row (join `hull_build_recipes` — the strict-FK mirror of the unit arm's
--   `unit_types` join) competes with the oldest waiting unit row by `queued_at`; strictly-older
--   hull wins, ties go to the unit arm (deterministic; sub-µs ties are unreachable in practice).
--   The unit arm's join/predicates/formula/update are BYTE-IDENTICAL to 0038 (the only unit-side
--   deltas are `bo.queued_at` added to the SELECT list for the fairness compare — behaviorally
--   inert — and the per-player 'production_start' advisory xact lock at the top, review M1: two
--   CONCURRENT start_next calls for one player could both read v_active = 0 and, with the two
--   pick statements' skip-locked reads diverging, promote TWO rows past max=1; the lock
--   serializes promotion per player (the 0078 lock idiom). This is the ONE deliberate unit-path
--   behavior delta: strictly a race-closure — it can only prevent over-promotion, never change a
--   serial outcome). Hull duration = greatest(min_build_seconds floor, recipe `build_seconds`) [D]: the
--   0038 min floor is kept (degenerate-config guard), the unit `build_time_scale` knob is NOT
--   applied — recipe seconds are already directly owner-tunable per hull in the 0185 catalog, and
--   quantity is always 1 on hull rows (0188).
--   THE PROMOTER TRIGGER — hull orders enqueue with NO immediate start (0188 step 11 deliberately
--   skipped the `production_start_next` call: "the activation semantics belong to the SHIPYARD-2
--   engine re-create"). Units get promoted at `train_units` time; hull orders get promoted by a
--   NEW hull-only sweep at the end of `process_build_queue` (the 30s cron, 0037): every player
--   holding a waiting HULL order gets a `production_start_next` pass. With zero hull rows the
--   sweep selects NOBODY — byte-identical cron behavior (the double-inert law). [D] chosen over
--   re-creating the 0188 order RPC with an immediate-start call: this keeps the whole ORDER side
--   untouched (one fewer live-function re-create) at the cost of ≤30s activation latency, and the
--   sweep also self-heals any stalled hull queue (e.g. after an aborted delivery txn retries).
--   COMPLETION → DELIVERY — `production_complete_order` completes the row exactly as 0038 (same
--   UPDATE statement + a RETURNING clause) and, for a hull row, delivers through the ONE
--   commission build core: `port_entry_commission_build`, re-created from its 0193 head taking
--   `p_hull_type_id text default 'starter_frigate'` — the charter's "parity re-create": every
--   existing caller (`port_entry_commission_writer` 0080, `commission_additional_main_ship` 0091 —
--   grep-verified the only callers, both single-arg positional) resolves through the default to
--   the EXACT starter behavior, name expression AND the SOUL-1 gated trait-roll hook included
--   ('Sparrow' + per-player roman numeral; the hook rides verbatim — a delivered hull is born
--   with its soul when lit, exactly the P12 "every new ship" reading, and stays a zero-call
--   no-op while ship_traits_enabled is dark).
--   A non-starter hull rides the SAME insert path: the hull row's base stats/hp/slots (columns not
--   enumerated — e.g. the 0191 shield columns — ride their defaults), the 0184 naming idiom
--   with the class display name from the hull row + the numeral counting ALL of the player's
--   ships ACROSS classes (a player whose third ship is their first Mule gets
--   'Mule-class Hauler III' — the 0184 per-player-ordinal law, NOT a per-class counter; the 0184
--   header pre-recorded the class-name source: "when multi-hull commissioning lands, the class
--   name should ride the hull row"), docked at the canonical commission port (Haven Reach) with
--   the fleet + presence + at_location coherence gate — all byte-identical to 0193. [D] DELIVERY LOCATION: the charter
--   says "delivered at the ORDERING port", but 0188 records NO ordering port (no port column on
--   build_orders; ordering is not port-scoped) — ambiguous, so per the standing instruction the
--   0184 behavior is kept: every commissioned ship lands docked at Haven Reach. A future slice
--   that adds port-scoped ordering owns the generalization. [D] SHIP CAP: delivery does NOT check
--   `max_main_ships_per_player` — the cap guards the commission RPCs (a purchase gate); a built
--   hull is already bought and paid, and blocking at delivery would wedge the cron or strand paid
--   value. Pending builds stay bounded by the SHARED `max_build_orders` cap. Recorded for the
--   ACT-SHIPYARD flip review. ALL-OR-NOTHING, PER ORDER (review H1): ship insert + fleet +
--   presence + order completion are atomic — but a failed delivery must NEVER wedge the whole
--   production cron (pg_cron runs process_build_queue as ONE txn; an unguarded raise would abort
--   EVERY player's completion EVERY tick, indefinitely — reachable: Haven docking disabled →
--   every pending delivery raises). So the hull arm of the completion loop runs in its OWN
--   begin/exception subtransaction (the EV-1 0182 per-publication precedent, query_canceled
--   re-raised): on failure that ORDER's completion+delivery roll back together, a NOTICE logs the
--   order id + sqlerrm, the order stays 'active' and retries next tick, and the loop CONTINUES —
--   other players' completions proceed. The unit arm keeps the exact 0038 posture (unguarded — a
--   base_merge_units failure still aborts the txn; byte-parity with zero hull rows). No
--   notification write: no notification system exists (grep-verified).
--   THE NAMING RACE — every 0184 caller of build holds the per-player 'main_ship_commission'
--   advisory lock before build runs (the count-then-insert numeral race law, 0184 header);
--   `production_complete_order`'s hull arm takes the SAME lock before delivering.
--   CANCEL — `cancel_build_order` (0038 head: a live client RPC) keeps its unit arm byte-identical
--   (waiting → 100% metal, active → 50%, terminal → reject; refund via `base_add_resources` — on a
--   hull row `metal_spent` = 0 by construction and the refund call is skipped at 0, `base_id` is
--   NULL anyway) and gains the HULL refund arm, MATCHING the unit arm's semantics [D]:
--   waiting → 100% credits + 100% ingredients; active → 50% credits (floored, the unit-arm floor
--   idiom) + floor(qty/2) per ingredient (an item's half may floor to 0 — e.g. 1 blueprint → 0 —
--   the same lossy-active-cancel law the unit arm already has). Credits return via Wallet's
--   `wallet_credit` (0093 — Wallet stays the sole player_wallet writer; it takes NO idempotency
--   key — for credits the FOR UPDATE status flip is the SOLE double-refund guard, and it
--   suffices: a second cancel rejects at the status check before any refund line runs);
--   ingredients return via Inventory's `inventory_deposit` (0039 — the spend writer's inverse,
--   Inventory stays the sole player_inventory writer), each DEPOSIT keyed
--   'hull_cancel:<order>:<item>' (idempotent belt-and-braces on top of the same status-flip
--   guard). The refund bill is read from
--   the DURABLE receipt ledger `hull_build_receipts.ingredients_json` (0188 — the recorded exact
--   spends), matched on (player_id, order_id) — the (player_id, …) index leads the probe. A hull
--   order with NO receipt row is impossible by the 0188 writer's atomicity (order + receipt in one
--   txn) → treated as corruption: hard raise, never a silent partial refund. Deterministic item
--   order (`order by item_id` — the 0041 law). The receipt is NEVER rewritten on cancel: replay of
--   the original request_id still returns the ORIGINAL success envelope verbatim (the 0089/0095
--   law — the receipt is the bill of what was ORDERED, not a state mirror).
--   REPLAY SAFETY — delivery/cancel cannot break the 0188 replay guarantee by construction: the
--   0188 writer's replay step reads ONLY `hull_build_receipts` (never order state, prosrc-pinned
--   at 0188 apply), and nothing here writes that table.
--   CAP COHERENCE — the SHARED `max_build_orders` cap (train_units 0038 + the 0188 writer) counts
--   `status in ('waiting','active')` — promotion only moves rows BETWEEN those two counted states,
--   so the cap stays correct for both kinds after this slice (verified, no change needed).
--
-- ── THE FLEETS-SHIM EXCEPTION (SYSTEM_BOUNDARIES §1 `fleets` row) — EXPLICIT DEFERRAL [D] ─────────
--   The charter sketched this slice as the rework that retires the sanctioned commission fleets
--   shim (repoint `fleets` writes through a Fleet-exposed function + re-derive the PORT-ENTRY
--   prosrc-md5 pins + delete the note). DEFERRED, deliberately: (a) `port_entry_commission_build`
--   is NOT one of the three md5-pinned bodies (the PORT-ENTRY verifier pins
--   `port_entry_commission_writer` / `commission_first_main_ship` / `normalize_main_ship_dock` —
--   grep-verified in scripts/port-entry-1-production-verify.{sh,sql}; 0184 already re-created
--   build without a pin re-derivation, the standing precedent), and ALL THREE pinned bodies are
--   byte-untouched here — no pin is invalidated, nothing is due at the deploy gate; (b) the
--   fleets INSERT inside build is byte-identical to 0193/0184 — this slice adds no new fleets
--   write and widens nothing (the same insert now also serves hull delivery, own-player rows only);
--   (c) the full retirement requires re-creating `normalize_main_ship_dock` — a FROZEN md5-pinned
--   live onboarding body — purely for boundary hygiene: exactly the "live-path risk for zero
--   functional gain" the exception note itself records as the reason not to. The exception note is
--   UPDATED (not deleted) this PR with this recorded deferral; the retirement stays a named
--   follow-up (boundary hygiene, NOT an ACT-SHIPYARD pre-flip requirement — it changes no
--   behavior).
--
-- ── FAN-OUT (one-directional DOWNWARD, acyclic — the §3 edge law) ────────────────────────────────
--   Production (queue engine) → Main Ship commission core (delivery — the shim's sanctioned
--   fleets/presence writes ride inside it, unchanged) · Wallet (`wallet_credit` — cancel refund) ·
--   Inventory (`inventory_deposit` — cancel refund) · Base (`base_merge_units`/`base_add_resources`
--   — the 0038 unit arm, unchanged) · Reference/Config (cfg + `hull_build_recipes` read) · its own
--   `build_orders` + `hull_build_receipts` (READ-only here — the refund bill). NO new writer of
--   any other system's table.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same PR): `build_orders` row (seam CLOSED),
-- Production row (engine hull arm + delivery + cancel refunds), `fleets` row (the recorded
-- deferral above), Main Ship row (build's new hull param + new internal caller). Docs synced:
-- FULL_CAPACITY_PLAN (§C P6 — pre-flip seam list → RESOLVED; what ACT-SHIPYARD still needs),
-- DEV_LOG. Proof: scripts/shipyard-proof.{sql,sh} extended (4 new markers — PROMOTE / DELIVER /
-- DELIVERY_GUARD / CANCEL_REFUND — the existing 8 stay green).
--
-- Forward-only: 0001–0193 unedited. (RENUMBERED 0192 → 0194 per 0193's recorded collision
-- choreography: 0193 re-created build with the SOUL-1 hook, so this file must apply AFTER it on
-- every chain and re-create build from the 0193 head — both hunks coexist below.)

-- ── (a) production_start_next — 0038 head + the marked HULL-arm hunks ─────────────────────────────
-- Copied VERBATIM from 20260617000038:31-68. Deltas (all marked): the `v_hull` declare, the unit
-- SELECT list gains `bo.queued_at` (fairness compare only — join/predicates/order/lock unchanged),
-- and the hull candidate branch. With ZERO hull rows the hull SELECT returns nothing and the
-- branch never fires → behavior byte-identical to 0038 (the double-inert law).
create or replace function public.production_start_next(p_player uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max    integer := coalesce(cfg_num('max_active_ship_production_slots'), 1)::integer;
  v_active integer;
  v_next   record;
  v_hull   record;   -- SHIPYARD-2 (0194): the hull-arm candidate
  v_secs   double precision;
begin
  -- ── SHIPYARD-2 (0194) HUNK (review M1): per-player promotion serialization — two CONCURRENT
  --    start_next calls for one player (train_units + the cron sweep, or two cron overlaps) could
  --    both read v_active = 0 and, with the two pick statements' skip-locked reads diverging,
  --    promote TWO rows past max_active = 1. The xact-scoped per-player advisory lock (the 0078
  --    commission-lock idiom) serializes the whole count→pick→promote critical section; strictly
  --    a race-closure — it can only prevent over-promotion, never change a serial outcome. ──────
  perform pg_advisory_xact_lock(hashtext('production_start'), hashtext(p_player::text));
  -- ── END SHIPYARD-2 (0194) HUNK ───────────────────────────────────────────────────────────────
  loop
    select count(*) into v_active from build_orders where player_id = p_player and status = 'active';
    exit when v_active >= v_max;

    select bo.id, bo.quantity, ut.build_time_seconds, bo.queued_at   -- SHIPYARD-2 (0194): + bo.queued_at (fairness compare; nothing else changed on this statement)
      into v_next
      from build_orders bo
      join unit_types ut on ut.id = bo.unit_type_id
      where bo.player_id = p_player and bo.status = 'waiting'
      order by bo.queued_at asc
      limit 1
      for update skip locked;

    -- ── SHIPYARD-2 (0194) HUNK: the HULL arm — the oldest waiting hull row (the strict
    --    hull_build_recipes join mirrors the unit arm's unit_types join: only a recipe-carrying
    --    hull row can promote) competes with the unit candidate by queued_at; strictly-older hull
    --    wins, ties go to the unit arm (deterministic). Duration = the recipe's build_seconds
    --    under the same 0038 min floor; NO build_time_scale (recipe seconds are owner-tuned
    --    directly; quantity is always 1 on hull rows — 0188). Zero hull rows → no candidate →
    --    this whole hunk is a no-op and the flow below is the 0038 head verbatim. ──────────────
    select bo.id, hr.build_seconds, bo.queued_at
      into v_hull
      from build_orders bo
      join hull_build_recipes hr on hr.hull_type_id = bo.hull_type_id
      where bo.player_id = p_player and bo.status = 'waiting'
      order by bo.queued_at asc
      limit 1
      for update skip locked;
    if v_hull.id is not null and (v_next.id is null or v_hull.queued_at < v_next.queued_at) then
      v_secs := greatest(coalesce(cfg_num('min_build_seconds'), 5), v_hull.build_seconds);
      update build_orders set
        status      = 'active',
        started_at  = now(),
        complete_at = now() + make_interval(secs => v_secs),
        updated_at  = now()
      where id = v_hull.id;
      continue;   -- re-enter the loop: recount active slots exactly like a unit promotion would
    end if;
    -- ── END SHIPYARD-2 (0194) HUNK ─────────────────────────────────────────────────────────────
    exit when v_next.id is null;

    v_secs := greatest(
      coalesce(cfg_num('min_build_seconds'), 5),
      v_next.build_time_seconds * v_next.quantity * coalesce(cfg_num('build_time_scale'), 1.0));
    update build_orders set
      status      = 'active',
      started_at  = now(),
      complete_at = now() + make_interval(secs => v_secs),
      updated_at  = now()
    where id = v_next.id;
  end loop;
end;
$$;

-- ── (b) production_complete_order — 0038 head + the marked DELIVERY hunk ──────────────────────────
-- Copied VERBATIM from 20260617000038:89-99. Deltas (marked): the declares, a RETURNING clause on
-- the SAME completion UPDATE (behaviorally inert — same rows, same writes), and the hull delivery
-- branch. A unit order (hull_type_id NULL) takes the exact 0038 path.
create or replace function public.production_complete_order(p_order uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hull   text;    -- SHIPYARD-2 (0194)
  v_player uuid;    -- SHIPYARD-2 (0194)
  v_res    jsonb;   -- SHIPYARD-2 (0194)
begin
  update build_orders set status = 'completed', resolved_at = now(), updated_at = now()
    where id = p_order and status = 'active'
    returning hull_type_id, player_id into v_hull, v_player;   -- SHIPYARD-2 (0194): RETURNING added to the byte-identical 0038 UPDATE
  -- ── SHIPYARD-2 (0194) HUNK: hull DELIVERY through the ONE commission build core (the charter:
  --    "the queue completion commissions the built ship through the ONE commission build core").
  --    The per-player 'main_ship_commission' advisory lock FIRST — the 0184 naming-race law:
  --    every caller of build holds it before the count-then-insert numeral expression runs.
  --    ALL-OR-NOTHING: a failed delivery raises → THIS order's completion rolls back with it
  --    (atomic), and the raise is CONFINED by the caller's per-order subtransaction guard
  --    (process_build_queue's hull arm, review H1) — the order stays 'active' and retries next
  --    tick while other orders' completions proceed. Replay safety: nothing here touches
  --    hull_build_receipts — the 0188 replay guarantee (receipt-only reads) is untouched. ───────
  if v_hull is not null then
    perform pg_advisory_xact_lock(hashtext('main_ship_commission'), hashtext(v_player::text));
    v_res := public.port_entry_commission_build(v_player, v_hull);
    if (v_res->>'created')::boolean is not true then
      raise exception 'production_complete_order: hull delivery failed for order % (hull %): %',
        p_order, v_hull, v_res;
    end if;
  end if;
  -- ── END SHIPYARD-2 (0194) HUNK ───────────────────────────────────────────────────────────────
end;
$$;

-- ── (c) process_build_queue — 0038 head + the marked kind-dispatch + guard + hull-sweep hunks ─────
-- Copied VERBATIM from 20260617000038:137-160. Deltas (marked): the completion loop dispatches by
-- kind — the UNIT arm keeps the exact 0038 statements unguarded (a hull row has NO base/unit; a
-- base_merge_units failure keeps its 0038 abort posture), the HULL arm runs in a per-order
-- begin/exception subtransaction (review H1 — a permanently-failing delivery must never wedge the
-- whole cron) — plus the trailing hull-only promoter sweep. With ZERO hull rows: every due row
-- takes the unit arm (0038 statements verbatim) and the sweep selects nobody → byte-identical cron.
create or replace function public.process_build_queue()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  o       build_orders%rowtype;
  p       record;      -- SHIPYARD-2 (0194): the sweep cursor
  v_count integer := 0;
begin
  for o in
    select * from build_orders
    where status = 'active' and complete_at is not null and complete_at <= now()
    for update skip locked
  loop
    -- SHIPYARD-2 (0194) HUNK: kind dispatch — the unit-shaped base delivery must never fire on a
    -- hull row (base_id/unit_type_id NULL); hull delivery is owned by production_complete_order.
    if o.hull_type_id is null then
      -- the UNIT arm: the exact 0038 statements, unguarded (a base_merge_units failure keeps its
      -- 0038 abort-the-txn posture — byte-parity with zero hull rows).
      perform base_merge_units(o.base_id,
        jsonb_build_array(jsonb_build_object('unit_type_id', o.unit_type_id, 'quantity', o.quantity)));
      perform production_complete_order(o.id);
      perform production_start_next(o.player_id);  -- waiting → active for the freed slot
      v_count := v_count + 1;
    else
      -- the HULL arm, PER-ORDER GUARDED (review H1; the EV-1 0182 per-publication subtransaction
      -- precedent): a permanently-failing delivery (e.g. the commission port undockable) must
      -- never wedge the WHOLE production cron — pg_cron runs this as ONE txn, so an unguarded
      -- raise would abort every player's completion every tick, indefinitely. On failure THIS
      -- order's completion+delivery roll back together (the subtransaction), a NOTICE logs it,
      -- the order stays 'active' and retries next tick, and the loop continues — other orders'
      -- completions proceed. query_canceled re-raised (the EV-1 posture: never swallow a cancel).
      begin
        perform production_complete_order(o.id);
        perform production_start_next(o.player_id);  -- waiting → active for the freed slot
        v_count := v_count + 1;
      exception
        when query_canceled then raise;
        when others then
          raise notice 'process_build_queue: hull delivery failed for order % (left active; retries next tick): %',
            o.id, sqlerrm;
      end;
    end if;
    -- END SHIPYARD-2 (0194) HUNK
  end loop;
  -- ── SHIPYARD-2 (0194) HUNK: the hull PROMOTER SWEEP — hull orders enqueue with NO immediate
  --    start (0188 step 11: activation belongs to this engine), so the cron promotes them: every
  --    player holding a waiting HULL order gets a start_next pass (which serially promotes the
  --    oldest waiting order of EITHER kind iff a slot is free — the one-queue law). Zero hull
  --    rows → zero players selected → byte-identical cron behavior (the double-inert law). Also
  --    self-heals a stalled hull queue (e.g. an aborted delivery retry freed no slot). ──────────
  for p in
    select distinct bo.player_id from build_orders bo
    where bo.status = 'waiting' and bo.hull_type_id is not null
  loop
    perform production_start_next(p.player_id);
  end loop;
  -- ── END SHIPYARD-2 (0194) HUNK ───────────────────────────────────────────────────────────────
  return v_count;
end;
$$;

-- ── (d) cancel_build_order — 0038 head + the marked HULL-refund hunk ──────────────────────────────
-- Copied VERBATIM from 20260617000038:164-186 (a LIVE client RPC — the unit arm's auth/ownership/
-- status checks, 100%/50% metal law, base_add_resources call and trailing start_next are all
-- byte-identical). Delta (marked): the declares + the hull refund arm. On a unit row the hunk is
-- a no-op (hull_type_id NULL); on a hull row the unit arm's refund is inert by construction
-- (metal_spent = 0 → the >0 guard skips base_add_resources; base_id is NULL anyway).
create or replace function public.cancel_build_order(p_order uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o        build_orders%rowtype;
  v_refund double precision;
  v_rcpt    hull_build_receipts%rowtype;   -- SHIPYARD-2 (0194)
  v_credits numeric;                       -- SHIPYARD-2 (0194)
  v_qty     integer;                       -- SHIPYARD-2 (0194)
  r         record;                        -- SHIPYARD-2 (0194)
begin
  select * into o from build_orders where id = p_order for update;
  if not found then raise exception 'cancel_build_order: order % not found', p_order; end if;
  if o.player_id <> auth.uid() then raise exception 'cancel_build_order: not your order'; end if;
  if o.status not in ('waiting','active') then raise exception 'cancel_build_order: cannot cancel a % order', o.status; end if;

  v_refund := case when o.status = 'waiting' then o.metal_spent else floor(o.metal_spent * 0.5) end;
  update build_orders set status = 'cancelled', resolved_at = now(), updated_at = now() where id = o.id;
  if v_refund > 0 then
    perform base_add_resources(o.base_id, jsonb_build_object('metal', v_refund));  -- Base credits the refund
  end if;
  -- ── SHIPYARD-2 (0194) HUNK: the HULL refund arm — the unit arm's semantics, matched exactly
  --    (waiting → 100%, active → 50% floored, terminal already rejected above; o.status is the
  --    pre-cancel snapshot, same as v_refund's read). Credits back via Wallet's wallet_credit
  --    (0093 — sole player_wallet writer); ingredients back via Inventory's inventory_deposit
  --    (0039 — sole player_inventory writer, the spend's inverse), each idempotency-keyed
  --    'hull_cancel:<order>:<item>' (belt-and-braces; the FOR UPDATE status flip above is the
  --    primary double-refund guard — a second cancel rejects at the status check). The bill is
  --    the DURABLE receipt ledger's ingredients_json (0188 — the recorded exact spends); a hull
  --    order without its receipt is impossible by the 0188 writer's atomicity → hard raise
  --    (corruption surface, never a silent partial refund). Deterministic item order (0041).
  --    The receipt itself is NEVER rewritten — replay of the original request_id keeps returning
  --    the ORIGINAL success envelope verbatim (the 0089/0095 law). ─────────────────────────────
  if o.hull_type_id is not null then
    v_credits := case when o.status = 'waiting' then o.credits_spent else floor(o.credits_spent * 0.5) end;
    if v_credits > 0 then
      perform public.wallet_credit(o.player_id, v_credits);
    end if;
    select * into v_rcpt from hull_build_receipts
      where player_id = o.player_id and order_id = o.id;
    if not found then
      raise exception 'cancel_build_order: no hull_build_receipt for hull order % (refund bill missing — corruption)', o.id;
    end if;
    for r in
      select el->>'item_id' as item_id, (el->>'quantity')::integer as qty
        from jsonb_array_elements(v_rcpt.ingredients_json) el
        order by el->>'item_id'
    loop
      v_qty := case when o.status = 'waiting' then r.qty else floor(r.qty * 0.5)::integer end;
      if v_qty > 0 then
        perform public.inventory_deposit(o.player_id, r.item_id, v_qty,
                                         'hull_cancel:' || o.id || ':' || r.item_id);
      end if;
    end loop;
  end if;
  -- ── END SHIPYARD-2 (0194) HUNK ───────────────────────────────────────────────────────────────
  perform production_start_next(o.player_id);  -- if the active item was cancelled, the next starts
end;
$$;

-- ── (e) port_entry_commission_build — 0193 head generalized to the hull parameter ─────────────────
-- The signature changes (uuid) → (uuid, text default 'starter_frigate'), so the old function is
-- DROPPED first (create-or-replace cannot change a signature; leaving both would make the
-- single-arg calls ambiguous). Callers (grep-verified, the ONLY three after this file):
-- `port_entry_commission_writer` (0080, md5-PINNED body — calls build(p_player)) and
-- `commission_additional_main_ship` (0091 — calls build(v_player)) both resolve through the new
-- default UNCHANGED (byte-inert: the default parameter reproduces the 0193 body exactly — the
-- 'Sparrow' name literal AND the SOUL-1 gated trait-roll hook included);
-- `production_complete_order` (above) is the new two-arg caller (a delivered hull is therefore
-- born with its soul when lit — the P12 "every new ship" reading; zero calls while dark).
-- Body copied VERBATIM from 20260618000193:82-171 (= the 0184 body + the SOUL-1 hook, per 0193's
-- own recorded collision choreography — NEVER from the stale 0184 head); the deltas are the TWO
-- marked hunks (the hull row select + the class-name source). The SOUL-1 hook / fleets insert /
-- presence / coherence gate are byte-identical — the sanctioned SYSTEM_BOUNDARIES fleets-shim
-- writes neither move nor widen (see the deferral section in the header).
drop function public.port_entry_commission_build(uuid);
create or replace function public.port_entry_commission_build(
  p_player       uuid,
  p_hull_type_id text default 'starter_frigate'   -- SHIPYARD-2 (0194): the hull parameter; default = the exact 0193 behavior
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_haven  constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  v_ship   uuid;
  v_zone   uuid;
  v_sector uuid;
  v_base   uuid;
  v_fleet  uuid;
begin
  -- Insert the ship DIRECTLY in canonical at_location shape (status='stationary',
  -- spatial_state='at_location', x/y NULL) so there is never a committed intermediate bare
  -- home/legacy_home row. No on-conflict: the CALLER already serialized + checked existence/cap.
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, space_x, space_y,
     hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots)
  select p_player, h.hull_type_id,
         -- [0184 NAME HUNK, generalized by SHIPYARD-2 (0194)] EVE-style default: the class name +
         -- a per-player roman numeral from the SECOND ship on. The class-name SOURCE is the only
         -- 0194 delta: the starter keeps the exact 0184 'Sparrow' literal (byte-inert through the
         -- default parameter); any other hull rides its catalog display name (h.name), the
         -- numeral still counting ALL of the player's ships ACROSS classes — a player whose
         -- third ship is their first Mule gets 'Mule-class Hauler III' (the 0184
         -- per-player-ordinal law, NOT a per-class counter) — exactly as the 0184 header
         -- pre-recorded: "when multi-hull commissioning lands, the class name should ride the
         -- hull row". Safe: every caller holds the per-player commission advisory lock before build.
         (case when p_hull_type_id = 'starter_frigate' then 'Sparrow' else h.name end)
           || (select case when count(*) = 0 then ''
                           else ' ' || to_char(count(*) + 1, 'FMRN') end
                 from public.main_ship_instances m where m.player_id = p_player),
         'stationary', 'at_location', null, null,
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3, h.base_support_capacity, h.base_captain_slots, h.base_module_slots
    from public.main_ship_hull_types h
    where h.hull_type_id = p_hull_type_id   -- SHIPYARD-2 (0194): was the 'starter_frigate' literal
  returning main_ship_id into v_ship;

  if v_ship is null then
    return jsonb_build_object('created', false);     -- hull row missing / nothing inserted
  end if;

  -- SOUL-1 (0193) HOOK: every new ship is born with its soul WHEN LIT (P12). Double-gated — the
  -- gate is checked HERE (dark = ZERO calls, byte-parity with the 0184 head) AND the roll fn
  -- gates first itself (0186). Definer-to-definer (the 0169 leaf-call pattern): this SECURITY
  -- DEFINER body executes as the function owner, which may execute the service_role-only roll
  -- writer. Deterministic + idempotent (0186) — a re-fired hook can never re-roll or re-raise hp;
  -- the envelope is discarded (failure codes impossible-by-construction here; a mid-txn config
  -- race fails CLOSED to dark and stays re-runnable). hp_mult lands here, once, via the roll.
  -- [Carried VERBATIM from the 0193 head by SHIPYARD-2 (0194) — a DELIVERED hull passes through
  -- this same hook, so built ships are born with souls when lit too.]
  if public.cfg_bool('ship_traits_enabled') then
    perform public.soul_roll_traits_for_ship(v_ship);
  end if;
  -- END SOUL-1 (0193) hook — everything below is the 0184 head, byte-identical.

  -- ── Phase B: lock the Haven Reach target hierarchy in the canonical order (sector → zone → location →
  --    anchor → docking service, FOR SHARE — conflicts with a status disable/retire) and REVALIDATE legality
  --    through the single canonical rule AFTER the locks are held, immediately before the fleet/presence write.
  select l.zone_id, z.sector_id into v_zone, v_sector
    from public.locations l join public.zones z on z.id = l.zone_id
    where l.id = c_haven;
  if v_zone is null then
    raise exception 'port_entry_commission: Haven Reach location not found';
  end if;
  perform 1 from public.sectors           where id = v_sector for share;
  perform 1 from public.zones             where id = v_zone   for share;
  perform 1 from public.locations         where id = c_haven  for share;
  perform 1 from public.space_anchors     where location_id = c_haven and kind = 'location' and status = 'active' for share;
  perform 1 from public.location_services where location_id = c_haven and service = 'docking' and status = 'active' for share;

  if (public.mainship_space_location_target_legal(c_haven)->>'ok')::boolean is not true then
    raise exception 'port_entry_commission: Haven Reach is not dockable';   -- rolls back the ship insert (atomic)
  end if;

  -- exactly ONE present/location fleet at Haven (origin_base_id = the player's base if one exists, else NULL —
  -- NOT a home-port assignment; current_base_id stays NULL, matching a docked OSN fleet).
  select id into v_base from public.bases where player_id = p_player and status = 'active' order by created_at limit 1;
  v_fleet := gen_random_uuid();
  insert into public.fleets
    (id, player_id, origin_base_id, status, location_mode, current_base_id,
     current_location_id, current_zone_id, current_sector_id, main_ship_id)
  values (v_fleet, p_player, v_base, 'present', 'location', null,
          c_haven, v_zone, v_sector, v_ship);

  -- exactly ONE active presence through the established presence path (activity 'none', like the dock writer).
  perform public.presence_create(p_player, v_fleet, v_sector, v_zone, c_haven, 'none');

  -- final coherence gate: the ship MUST now be canonical at_location, else abort the whole transaction.
  if (public.mainship_space_validate_context(v_ship)->>'state') is distinct from 'at_location' then
    raise exception 'port_entry_commission: post-write state is not canonical at_location';
  end if;

  return jsonb_build_object('created', true, 'main_ship_id', v_ship, 'location_id', c_haven);
end;
$$;

-- ── (f) ACL (the targeted 0109/0188 idiom — the 0064-era default-privileges revoke already denies
--        new functions; these re-assert explicitly; create-or-replace preserved the others'). ─────
-- the re-signed commission core stays OFF the client surface (the 0080 posture):
revoke execute on function public.port_entry_commission_build(uuid, text) from public, anon, authenticated;
grant  execute on function public.port_entry_commission_build(uuid, text) to service_role;
-- the engine trio stays server-side (0038 posture: only process_build_queue carries a grant —
-- service_role for the cron/CI surface; start_next/complete_order stay internal):
revoke execute on function public.production_start_next(uuid)      from public, anon, authenticated;
revoke execute on function public.production_complete_order(uuid)  from public, anon, authenticated;
revoke execute on function public.process_build_queue()            from public, anon, authenticated;
grant  execute on function public.process_build_queue()            to service_role;
-- the ONE client RPC keeps its 0038 grant:
revoke execute on function public.cancel_build_order(uuid) from public, anon;
grant  execute on function public.cancel_build_order(uuid) to authenticated;

-- ── (g) SELF-ASSERTS — the migration proves its own grounding or refuses to land ──────────────────
do $$
declare
  v_src   text;
  v_n     integer;
  v_args  text;
  v_tok   text;
begin
  -- (1) the gate is still DARK and ZERO hull orders exist — this slice lands DOUBLE-inert (no
  --     hull row can have been created while the 0188 writer was gate-first dark).
  if coalesce(public.cfg_bool('shipyard_enabled'), false) then
    raise exception 'SHIPYARD-2 self-assert FAIL: shipyard_enabled reads true at apply time (this slice must land dark)';
  end if;
  select count(*) into v_n from public.build_orders where hull_type_id is not null;
  if v_n <> 0 then
    raise exception 'SHIPYARD-2 self-assert FAIL: % hull order row(s) exist at apply time (dark-flag breach upstream?)', v_n;
  end if;

  -- (2) production_start_next: the unit arm is byte-intact (the exact 0038 join + formula tokens)
  --     AND the hull arm landed (the mirrored recipe join + the recipe-seconds promotion).
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'production_start_next';
  if v_src is null then raise exception 'SHIPYARD-2 self-assert FAIL: production_start_next not deployed'; end if;
  foreach v_tok in array array[
    'join unit_types ut on ut.id = bo.unit_type_id',
    'v_next.build_time_seconds * v_next.quantity * coalesce(cfg_num(''build_time_scale''), 1.0)',
    'join hull_build_recipes hr on hr.hull_type_id = bo.hull_type_id',
    'greatest(coalesce(cfg_num(''min_build_seconds''), 5), v_hull.build_seconds)',
    'v_hull.queued_at < v_next.queued_at',
    'pg_advisory_xact_lock(hashtext(''production_start''), hashtext(p_player::text))'] loop
    if strpos(v_src, v_tok) = 0 then
      raise exception 'SHIPYARD-2 self-assert FAIL: production_start_next missing token ''%'' (unit-parity, hull-arm, or M1-lock breach)', v_tok;
    end if;
  end loop;

  -- (3) process_build_queue: still active-rows-only (the 0188-pinned invariant), base_merge_units
  --     now guarded BEHIND the hull-null dispatch (token order), and the hull sweep landed.
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_build_queue';
  if v_src is null then raise exception 'SHIPYARD-2 self-assert FAIL: process_build_queue not deployed'; end if;
  if strpos(v_src, 'status = ''active''') = 0 then
    raise exception 'SHIPYARD-2 self-assert FAIL: process_build_queue no longer loops active rows only';
  end if;
  if strpos(v_src, 'if o.hull_type_id is null then') = 0
     or strpos(v_src, 'if o.hull_type_id is null then') > strpos(v_src, 'base_merge_units') then
    raise exception 'SHIPYARD-2 self-assert FAIL: base_merge_units is not guarded behind the hull-null kind dispatch';
  end if;
  --   the H1 per-order delivery guard: the hull arm's subtransaction exists, re-raises
  --   query_canceled (the EV-1 posture), and sits AFTER the kind dispatch (the unit arm stays
  --   unguarded — 0038 posture, byte-parity with zero hull rows).
  if strpos(v_src, 'when query_canceled then raise') = 0
     or strpos(v_src, 'hull delivery failed for order') = 0
     or strpos(v_src, 'when query_canceled then raise') < strpos(v_src, 'if o.hull_type_id is null then') then
    raise exception 'SHIPYARD-2 self-assert FAIL: the per-order hull delivery guard (H1 subtransaction, query_canceled re-raise) is missing or misplaced';
  end if;
  if strpos(v_src, 'bo.status = ''waiting'' and bo.hull_type_id is not null') = 0 then
    raise exception 'SHIPYARD-2 self-assert FAIL: the hull promoter sweep is missing';
  end if;

  -- (4) production_complete_order: the 0038 completion UPDATE survives; the delivery hunk calls
  --     the ONE commission core UNDER the 0184 naming-race lock (lock token BEFORE the call).
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'production_complete_order';
  if v_src is null then raise exception 'SHIPYARD-2 self-assert FAIL: production_complete_order not deployed'; end if;
  foreach v_tok in array array[
    'status = ''completed''', 'main_ship_commission', 'port_entry_commission_build'] loop
    if strpos(v_src, v_tok) = 0 then
      raise exception 'SHIPYARD-2 self-assert FAIL: production_complete_order missing token ''%''', v_tok;
    end if;
  end loop;
  if strpos(v_src, 'main_ship_commission') > strpos(v_src, 'port_entry_commission_build') then
    raise exception 'SHIPYARD-2 self-assert FAIL: delivery does not take the commission lock BEFORE the build call (the 0184 naming-race law)';
  end if;

  -- (5) cancel_build_order: the unit arm byte-intact (the exact 0038 50% floor + base refund),
  --     the hull arm complete (wallet_credit + receipt bill + inventory_deposit + the key idiom).
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'cancel_build_order';
  if v_src is null then raise exception 'SHIPYARD-2 self-assert FAIL: cancel_build_order not deployed'; end if;
  foreach v_tok in array array[
    'floor(o.metal_spent * 0.5)', 'base_add_resources',
    'floor(o.credits_spent * 0.5)', 'wallet_credit', 'from hull_build_receipts',
    'ingredients_json', 'inventory_deposit', 'hull_cancel:', 'order by el->>''item_id'''] loop
    if strpos(v_src, v_tok) = 0 then
      raise exception 'SHIPYARD-2 self-assert FAIL: cancel_build_order missing token ''%'' (unit-parity or refund-arm breach)', v_tok;
    end if;
  end loop;

  -- (6) the commission core: the OLD (uuid) signature is GONE (no ambiguity for single-arg
  --     callers), the new (uuid, text) resolves with the 'starter_frigate' default, the 'Sparrow'
  --     literal + the class-name hunk + the SOUL-1 hook (0193 head-parity: the gated roll call,
  --     exactly once) + the UNMOVED sanctioned fleets insert are all in the body, and the two
  --     0184-era callers still delegate single-arg (byte-untouched — their md5 pins, where
  --     pinned, stay valid).
  if to_regprocedure('public.port_entry_commission_build(uuid)') is not null then
    raise exception 'SHIPYARD-2 self-assert FAIL: the old port_entry_commission_build(uuid) still exists (single-arg calls would be ambiguous)';
  end if;
  if to_regprocedure('public.port_entry_commission_build(uuid, text)') is null then
    raise exception 'SHIPYARD-2 self-assert FAIL: port_entry_commission_build(uuid, text) not deployed';
  end if;
  select pg_get_function_arguments('public.port_entry_commission_build(uuid, text)'::regprocedure) into v_args;
  if strpos(v_args, 'DEFAULT ''starter_frigate''::text') = 0 then
    raise exception 'SHIPYARD-2 self-assert FAIL: the hull parameter default is not ''starter_frigate'' (got: %)', v_args;
  end if;
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'port_entry_commission_build';
  foreach v_tok in array array[
    '''Sparrow''', 'else h.name end', 'h.hull_type_id = p_hull_type_id',
    'insert into public.fleets', 'presence_create', 'to_char(count(*) + 1, ''FMRN'')',
    'if public.cfg_bool(''ship_traits_enabled'') then'] loop
    if strpos(v_src, v_tok) = 0 then
      raise exception 'SHIPYARD-2 self-assert FAIL: port_entry_commission_build missing token ''%''', v_tok;
    end if;
  end loop;
  --     the SOUL-1 hook survives this re-create with EXACTLY one gated roll call (the 0193
  --     assert-2 pin, re-run on the new body — the renumber choreography's whole point).
  v_tok := 'perform public.soul_roll_traits_for_ship(';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'SHIPYARD-2 self-assert FAIL: build carries % SOUL-1 roll-hook call site(s) (want exactly 1 — the 0193 hook must survive the 0194 re-create)', v_n;
  end if;
  if strpos(v_src, 'if public.cfg_bool(''ship_traits_enabled'') then') > strpos(v_src, v_tok) then
    raise exception 'SHIPYARD-2 self-assert FAIL: the SOUL-1 roll call is not behind its ship_traits_enabled gate';
  end if;
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'port_entry_commission_writer';
  if v_src is null or strpos(v_src, 'port_entry_commission_build(p_player)') = 0 then
    raise exception 'SHIPYARD-2 self-assert FAIL: port_entry_commission_writer no longer delegates single-arg (must ride the starter default)';
  end if;
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'commission_additional_main_ship';
  if v_src is null or strpos(v_src, 'port_entry_commission_build(v_player)') = 0 then
    raise exception 'SHIPYARD-2 self-assert FAIL: commission_additional_main_ship no longer delegates single-arg (must ride the starter default)';
  end if;

  -- (7) determinism (the 0041 law): no random() in ANY body this migration re-created.
  select count(*) into v_n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname in ('production_start_next', 'production_complete_order',
                        'process_build_queue', 'cancel_build_order', 'port_entry_commission_build')
      and strpos(p.prosrc, 'random()') <> 0;
  if v_n <> 0 then
    raise exception 'SHIPYARD-2 self-assert FAIL: % re-created body(ies) call random() (the 0041 determinism law)', v_n;
  end if;

  -- (8) ACL posture: the commission core + engine internals are OFF the client surface; the cron
  --     processor is service_role; cancel stays the authenticated client RPC (anon never).
  if has_function_privilege('authenticated', 'public.port_entry_commission_build(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.port_entry_commission_build(uuid, text)', 'execute') then
    raise exception 'SHIPYARD-2 self-assert FAIL: the commission core is client-executable';
  end if;
  if not has_function_privilege('service_role', 'public.port_entry_commission_build(uuid, text)', 'execute') then
    raise exception 'SHIPYARD-2 self-assert FAIL: service_role cannot execute the commission core';
  end if;
  if has_function_privilege('authenticated', 'public.production_start_next(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.production_complete_order(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.process_build_queue()', 'execute') then
    raise exception 'SHIPYARD-2 self-assert FAIL: an engine internal is client-executable';
  end if;
  if not has_function_privilege('service_role', 'public.process_build_queue()', 'execute') then
    raise exception 'SHIPYARD-2 self-assert FAIL: service_role cannot execute process_build_queue (the cron/CI surface)';
  end if;
  if not has_function_privilege('authenticated', 'public.cancel_build_order(uuid)', 'execute')
     or has_function_privilege('anon', 'public.cancel_build_order(uuid)', 'execute') then
    raise exception 'SHIPYARD-2 self-assert FAIL: cancel_build_order client ACL is wrong (want authenticated-only)';
  end if;

  -- (9) the replay guarantee's grounding survives: the 0188 writer still rebuilds replays from
  --     hull_build_receipts ONLY — no order-state read anywhere near its replay step (token pin:
  --     the receipt select exists; no 'from build_orders' read occurs BEFORE it in the body).
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'production_start_hull_build';
  if v_src is null or strpos(v_src, 'from hull_build_receipts') = 0 then
    raise exception 'SHIPYARD-2 self-assert FAIL: the 0188 writer''s receipt-only replay read is gone';
  end if;
  if strpos(v_src, 'from build_orders') <> 0
     and strpos(v_src, 'from build_orders') < strpos(v_src, 'from hull_build_receipts') then
    raise exception 'SHIPYARD-2 self-assert FAIL: the 0188 writer reads build_orders before its replay step (replay must never consult order state)';
  end if;

  -- (10) cap coherence: both cap sites still count the SHARED waiting+active predicate (one
  --      queue, one cap — promotion only moves rows between the two counted states).
  select count(*) into v_n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname in ('train_units', 'production_start_hull_build')
      and strpos(p.prosrc, 'status in (''waiting'',''active'')')
        + strpos(p.prosrc, 'status in (''waiting'', ''active'')') > 0;
  if v_n <> 2 then
    raise exception 'SHIPYARD-2 self-assert FAIL: % of 2 cap sites carry the shared waiting+active predicate', v_n;
  end if;

  raise notice 'SHIPYARD-2 self-assert ok: dark + zero hull orders (double-inert); start_next unit tokens byte-intact + hull arm (recipe join, min-floor seconds, queued_at fairness) + the M1 per-player promotion lock; process_build_queue active-only + guarded base_merge_units + the H1 per-order delivery guard (query_canceled re-raised) + hull sweep; complete_order delivers via the ONE commission core under the naming-race lock; cancel unit arm intact + hull refund arm (wallet_credit + receipt bill + keyed inventory_deposit, deterministic); commission core re-signed from the 0193 head (old (uuid) gone, starter default, Sparrow literal + h.name hunk + the SOUL-1 gated roll hook exactly once, fleets insert unmoved) with both 0184-era callers still single-arg; determinism; ACLs (core+internals off-client, cron service_role, cancel authenticated); 0188 receipt-only replay grounding intact; shared cap predicate at both sites';
end $$;
