-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 0342 — THE SHOP STOPS SELLING THE DEEP-SCAN ARRAY (server-authoritative, three rows)
--
-- THE VERDICT THIS OBEYS (owner, 2026-08-04): "A disabled React button is not purchase prevention."
--
-- The slice before this one established the fact and got the presentation right: the Deep-Scan
-- Sensor Array's ONLY claimed effect is the `scan` catalog key, which migration 0340 registers as
-- `scouting`, lifecycle DORMANT — no engine consumer, no presentation consumer, nothing in the game
-- reads it. Its `range` and `power` are explicitly NULL (0229:134), and it changes no scan radius:
-- every scan reads the flat cfg key exploration_scan_radius (0099:176, 0146:136, 0172:149,
-- 0221:642) and no module contributes to it. The module is therefore inert, and the shop was
-- charging 90 credits for it.
--
-- That slice then withdrew the Buy button IN REACT ONLY. The offer stayed `active = true` at all
-- three starter ports, so `buy_shop_offer_at_port` would still have sold it to any caller that
-- reached the RPC — a stale tab, a replayed request, a direct call. The gate was never engaged.
--
-- THE GATE ALREADY EXISTED AND WAS NOT USED. `port_shop_offers.active` IS the server-side
-- availability switch, and BOTH RPCs already read it:
--   · buy_shop_offer_at_port (0235:258-260)  select … where location_id = v_loc and ref_id = p_ref_id
--                                            and active;  if not found → {'ok':false,'reason':'no_offer'}
--   · get_port_shop          (0235:355-358)  from public.port_shop_offers o … where o.location_id =
--                                            p_location_id and o.active
-- Both are asserted below BEFORE the flip: a switch is only worth throwing once you have proven it
-- is wired to something. `port_shop_offers` is Reference/Config — migration-seeded, NO runtime
-- writer ever (0235:74, 0235:117-141: public read policy, no write policy, no write grant) — so a
-- forward migration is the only way its value can change, and this is that migration.
--
-- WHAT THIS DOES: sets `active = false` on EXACTLY the three seeded `deep_scan_sensor_array` offers,
-- one per starter port. Nothing else.
--
-- WHAT THIS DOES NOT DO: it does not delete the offer rows, does not touch the
-- `deep_scan_sensor_array` module_types definition, does not change any price, does not change any
-- other item's availability, does not refund anything, does not touch any player's wallet,
-- inventory, module_instances or ship_module_fittings, does not unfit or destroy an owned array,
-- does not activate scan gameplay, and does not add a flag. An array a player already owns stays
-- owned and stays fitted; it simply continues to do what it has always done, which is nothing —
-- and the client now says so rather than selling more of them.
--
-- BLAST RADIUS: three rows of one Reference/Config table, at the three starter ports
-- (b1a00001-…0001 Haven Reach, b1a00002-…0002 Slagworks Anchorage, b1a00003-…0003 Driftmarch
-- Waypost). Player-visible effect: the Deep-Scan Sensor Array disappears from the port shop's offer
-- list, and a purchase attempt returns the server's own `no_offer`. Every other offer at every port
-- keeps its price and its availability. No player state of any kind is read or written.
--
-- ROLLBACK: a forward migration setting the same three rows back to `active = true`:
--   update public.port_shop_offers set active = true
--    where ref_id = 'deep_scan_sensor_array'
--      and location_id in ('b1a00001-0066-4a00-8a00-000000000001'::uuid,
--                          'b1a00002-0066-4a00-8a00-000000000002'::uuid,
--                          'b1a00003-0066-4a00-8a00-000000000003'::uuid);
-- No data is destroyed here, so the rollback is exact and total.
--
-- FAIL-CLOSED, NOT BEST-EFFORT (the 0254 grant-drift lesson: ESTABLISH, never assert). This
-- migration does NOT "deactivate whatever currently matches". It states the world it expects —
-- three offers, all active, all priced 90, at exactly those three locations, with no fourth
-- anywhere — and ABORTS the whole deploy on any mismatch, because a mismatch means production is
-- not the catalog this change was audited against.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions — the world this change was audited against, stated and required ───────────
do $pre$
declare
  c_ref   constant text := 'deep_scan_sensor_array';
  c_locs  constant uuid[] := array[
    'b1a00001-0066-4a00-8a00-000000000001'::uuid,   -- Haven Reach
    'b1a00002-0066-4a00-8a00-000000000002'::uuid,   -- Slagworks Anchorage
    'b1a00003-0066-4a00-8a00-000000000003'::uuid];  -- Driftmarch Waypost
  v_n   integer;
  v_src text;
begin
  if to_regclass('public.port_shop_offers') is null then
    raise exception '0342 PRECONDITION FAIL: public.port_shop_offers (0235) is missing';
  end if;
  if to_regprocedure('public.buy_shop_offer_at_port(uuid, text, numeric, uuid)') is null then
    raise exception '0342 PRECONDITION FAIL: buy_shop_offer_at_port(uuid,text,numeric,uuid) is missing';
  end if;
  if to_regprocedure('public.get_port_shop(uuid)') is null then
    raise exception '0342 PRECONDITION FAIL: get_port_shop(uuid) is missing';
  end if;

  -- (a) THE SWITCH IS WIRED. Flipping `active` is only purchase prevention if the purchase path
  --     actually reads it. Prove it on the DEPLOYED function bodies before writing anything.
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.buy_shop_offer_at_port(uuid, text, numeric, uuid)')::oid;
  if v_src is null or position('ref_id = p_ref_id and active' in v_src) = 0 then
    raise exception '0342 PRECONDITION FAIL: buy_shop_offer_at_port does not select the offer on `active` — deactivating a row would prevent no purchase';
  end if;
  if position('''no_offer''' in v_src) = 0 then
    raise exception '0342 PRECONDITION FAIL: buy_shop_offer_at_port no longer answers no_offer when the offer lookup finds nothing';
  end if;
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_port_shop(uuid)')::oid;
  if v_src is null or position('o.location_id = p_location_id and o.active' in v_src) = 0 then
    raise exception '0342 PRECONDITION FAIL: get_port_shop does not filter its offer list on `active` — the shop read would still list a withdrawn offer';
  end if;

  -- (b) EXACTLY THREE offers carry this ref, anywhere in the table. A fourth (a new port, a
  --     hand-inserted row) means the audited catalog is not the catalog in front of us.
  select count(*) into v_n from public.port_shop_offers where ref_id = c_ref;
  if v_n <> 3 then
    raise exception '0342 PRECONDITION FAIL: % offer(s) carry ref_id %, expected exactly 3', v_n, c_ref;
  end if;

  -- (c) their identities are the three audited ones — the PK is (location_id, ref_id), so pinning
  --     the location set pins the rows themselves. Set equality in BOTH directions.
  select count(*) into v_n from public.port_shop_offers
   where ref_id = c_ref and location_id <> all (c_locs);
  if v_n <> 0 then
    raise exception '0342 PRECONDITION FAIL: % offer(s) for % sit at an unaudited location', v_n, c_ref;
  end if;
  select count(*) into v_n from unnest(c_locs) l
   where not exists (select 1 from public.port_shop_offers o where o.location_id = l and o.ref_id = c_ref);
  if v_n <> 0 then
    raise exception '0342 PRECONDITION FAIL: % audited location(s) carry no % offer', v_n, c_ref;
  end if;

  -- (d) all three are CURRENTLY ACTIVE and priced 90, and are module offers bound to the module
  --     catalog row (never an item). Anything else and this is not the state that was audited.
  select count(*) into v_n from public.port_shop_offers
   where ref_id = c_ref
     and (active is not true or price <> 90 or kind <> 'module'
          or module_type_id is distinct from c_ref or item_id is not null);
  if v_n <> 0 then
    raise exception '0342 PRECONDITION FAIL: % of the 3 % offers are not the audited shape (active=true, price=90, kind=module, module_type_id=%, item_id=null)', v_n, c_ref, c_ref;
  end if;

  -- (e) the module catalog row this offer points at still exists. This migration must leave it
  --     alone, so it has to be there to be left alone.
  if not exists (select 1 from public.module_types where id = c_ref) then
    raise exception '0342 PRECONDITION FAIL: module_types row % is missing', c_ref;
  end if;

  raise notice '0342 preconditions ok: both RPCs read port_shop_offers.active; exactly 3 % offers, all active at 90 credits, at the 3 audited starter ports, no fourth anywhere', c_ref;
end $pre$;

-- ── 0b. pre-image of the WHOLE offer table, for the nothing-else-moved assert at the end ────────
-- Every column of every row, not just the ones being touched (the 0273 untouched-parity idiom).
-- `on commit drop` — the temp table never outlives this migration's transaction.
create temporary table _ps0342_before on commit drop as
  select location_id, kind, module_type_id, item_id, ref_id, price, active, created_at
    from public.port_shop_offers;

-- ── 0c. the table has no client writer, and this migration ESTABLISHES that rather than hoping ──
-- 0254's recorded failure: a Supabase-default GRANT ALL had silently made a Reference/Config table
-- client-writable, and the migration that merely ASSERTED the correct state aborted on its own
-- self-assert. Deactivating an offer is server-authoritative only while no client role can write
-- the row back. So: revoke first (a no-op when the grant was never there — 0235 issued only
-- `grant select`), then assert. Read stays open: the offer list is public price data (0235:137-141).
revoke insert, update, delete, truncate on public.port_shop_offers from anon, authenticated;

-- ── 1. THE CHANGE — exactly the three audited rows, `active` only ────────────────────────────────
-- Only the `active` column is named. price, kind, module_type_id, item_id, ref_id, location_id and
-- created_at are not in the SET list and therefore cannot move.
update public.port_shop_offers
   set active = false
 where ref_id = 'deep_scan_sensor_array'
   and location_id in ('b1a00001-0066-4a00-8a00-000000000001'::uuid,
                       'b1a00002-0066-4a00-8a00-000000000002'::uuid,
                       'b1a00003-0066-4a00-8a00-000000000003'::uuid);

-- ── 2. self-assert — EXECUTED, and it aborts the deploy on any drift ─────────────────────────────
do $post$
declare
  c_ref   constant text := 'deep_scan_sensor_array';
  c_locs  constant uuid[] := array[
    'b1a00001-0066-4a00-8a00-000000000001'::uuid,
    'b1a00002-0066-4a00-8a00-000000000002'::uuid,
    'b1a00003-0066-4a00-8a00-000000000003'::uuid];
  v_n integer;
begin
  -- (1) EXACTLY THREE ROWS CHANGED. The pre-image says which rows differ from the post-image; that
  --     set must be precisely the three audited offers, and the ONLY column that may differ is
  --     `active`, and it may only have gone true → false.
  select count(*) into v_n
    from public.port_shop_offers o
    full outer join _ps0342_before b
      on b.location_id = o.location_id and b.ref_id = o.ref_id
   where o.location_id is null
      or b.location_id is null
      or o.kind           is distinct from b.kind
      or o.module_type_id is distinct from b.module_type_id
      or o.item_id        is distinct from b.item_id
      or o.price          is distinct from b.price
      or o.created_at     is distinct from b.created_at
      or o.active         is distinct from b.active;
  if v_n <> 3 then
    raise exception '0342 SELF-ASSERT FAIL: % offer row(s) differ from the pre-image, expected exactly 3', v_n;
  end if;
  select count(*) into v_n
    from public.port_shop_offers o
    join _ps0342_before b on b.location_id = o.location_id and b.ref_id = o.ref_id
   where o.ref_id = c_ref
     and o.location_id = any (c_locs)
     and b.active is true and o.active is false
     and o.kind = b.kind and o.module_type_id is not distinct from b.module_type_id
     and o.item_id is not distinct from b.item_id and o.price = b.price
     and o.created_at = b.created_at;
  if v_n <> 3 then
    raise exception '0342 SELF-ASSERT FAIL: only % of the 3 audited offers went active true→false with every other column preserved', v_n;
  end if;

  -- (2) NO UNRELATED OFFER CHANGED — every row that is not one of the three is byte-identical to
  --     its pre-image, including its price and its availability.
  select count(*) into v_n
    from public.port_shop_offers o
    full outer join _ps0342_before b
      on b.location_id = o.location_id and b.ref_id = o.ref_id
   where coalesce(o.ref_id, b.ref_id) is distinct from c_ref
     and (o.location_id is null
       or b.location_id is null
       or o.kind           is distinct from b.kind
       or o.module_type_id is distinct from b.module_type_id
       or o.item_id        is distinct from b.item_id
       or o.price          is distinct from b.price
       or o.active         is distinct from b.active
       or o.created_at     is distinct from b.created_at);
  if v_n <> 0 then
    raise exception '0342 SELF-ASSERT FAIL: % unrelated shop offer row(s) drifted — this migration must touch nothing but the deep-scan array', v_n;
  end if;

  -- (3) THE THREE ARE INACTIVE, AND STILL PRESENT AND STILL PRICED. Nothing was deleted; the row
  --     survives with its price so the rollback is a one-line flip and nothing has to be re-derived.
  select count(*) into v_n from public.port_shop_offers
   where ref_id = c_ref and location_id = any (c_locs) and active is false and price = 90;
  if v_n <> 3 then
    raise exception '0342 SELF-ASSERT FAIL: % of the 3 % offers are inactive-and-still-priced-90, expected 3', v_n, c_ref;
  end if;
  select count(*) into v_n from public.port_shop_offers where ref_id = c_ref and active;
  if v_n <> 0 then
    raise exception '0342 SELF-ASSERT FAIL: % % offer(s) are still active somewhere', v_n, c_ref;
  end if;

  -- (4) THE MODULE ITSELF IS UNTOUCHED — the catalog definition, an owned instance and a fitting are
  --     all none of this migration's business.
  if not exists (select 1 from public.module_types where id = c_ref) then
    raise exception '0342 SELF-ASSERT FAIL: the % module_types row was removed', c_ref;
  end if;

  -- (5) EACH STARTER PORT NOW CARRIES 7 ACTIVE OFFERS (the 0235 beginner outfit of 8, minus this
  --     one). Stated as the exact new number so a silent drift in either direction goes red.
  select count(*) into v_n from unnest(c_locs) p
   where (select count(*) from public.port_shop_offers o where o.location_id = p and o.active) <> 7;
  if v_n <> 0 then
    raise exception '0342 SELF-ASSERT FAIL: % starter port(s) do not carry exactly 7 active offers', v_n;
  end if;

  -- (6) THE MINING RIG IS EXPLICITLY UNAFFECTED. It claims the dormant `mining` key too, but its
  --     range 120 is REAL — mining_extract takes the mining radius from max(mt.range) over fitted
  --     mining modules (0229:309-321) — so it has a live effect and must stay on sale. Named here
  --     because "we withdrew the dead one" is only true if the live one survived.
  select count(*) into v_n from public.port_shop_offers
   where ref_id = 'mining_rig_extension' and active and price = 110;
  if v_n <> 3 then
    raise exception '0342 SELF-ASSERT FAIL: % active mining_rig_extension offers at 110 credits, expected 3', v_n;
  end if;
  if not exists (select 1 from public.module_types where id = 'mining_rig_extension' and range = 120) then
    raise exception '0342 SELF-ASSERT FAIL: mining_rig_extension lost its live range 120';
  end if;

  -- (7) NO CLIENT ROLE CAN WRITE THE SWITCH BACK. Read stays public (price data); write is
  --     migrations/admin only, which is what makes `active` a server-authoritative gate at all.
  if has_table_privilege('anon', 'public.port_shop_offers', 'INSERT')
     or has_table_privilege('anon', 'public.port_shop_offers', 'UPDATE')
     or has_table_privilege('anon', 'public.port_shop_offers', 'DELETE')
     or has_table_privilege('authenticated', 'public.port_shop_offers', 'INSERT')
     or has_table_privilege('authenticated', 'public.port_shop_offers', 'UPDATE')
     or has_table_privilege('authenticated', 'public.port_shop_offers', 'DELETE') then
    raise exception '0342 SELF-ASSERT FAIL: a client role can write public.port_shop_offers — `active` is not a server-authoritative gate';
  end if;
  if not has_table_privilege('anon', 'public.port_shop_offers', 'SELECT')
     or not has_table_privilege('authenticated', 'public.port_shop_offers', 'SELECT') then
    raise exception '0342 SELF-ASSERT FAIL: the public read of the offer list was lost — the shop catalog must stay readable';
  end if;

  raise notice '0342 self-assert ok: exactly 3 rows changed (deep_scan_sensor_array active true->false at the 3 starter ports, price 90 preserved); no unrelated offer, price or catalog row moved; mining_rig_extension still on sale at 110 with range 120; each starter port now carries 7 active offers; port_shop_offers stays client-read-only';
end $post$;
