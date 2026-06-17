-- Byeharu — Phase 4: Pending Loot Bundle.
--
-- Generalize the metal-only pending reward into a future-proof PendingRewardBundle:
--   { "metal": 123, "items": [ { "item_id": "scrap", "quantity": 3 }, ... ] }
--
-- The bundle already rides the EXISTING jsonb columns end-to-end — no schema change,
-- no new column, no rename:
--   combat tick accrues → combat_encounters.total_rewards_json
--   on exit            → fleet_movements.reward_payload_json (via movement_attach_cargo)
--   on home arrival    → reward_grant('combat', encounter_id, player, base, bundle)
--
-- The ONLY change is reward_grant() — the secured-deposit owner. It now SPLITS the
-- bundle: metal → Base.base_add_resources (unchanged path); items[] →
-- Inventory.inventory_deposit (Phase 3 path). The reward timing law is untouched:
-- rewards stay pending while travelling, are secured ONCE on home arrival, and are
-- forfeited on defeat (combat sets total_rewards_json='{}' and creates no return move).
--
-- This migration adds NO new pirate item drops — combat still accrues only metal.
-- It is pure plumbing so Phase 5 (multi-item loot) becomes a data change, not engine work.

-- ── reward_grant: split the bundle (metal → Base, items[] → Inventory) ──────────
-- Idempotency:
--   · metal  — guarded by reward_grants UNIQUE (source_type, source_id): one grant/source.
--   · items  — same outer guard PLUS inventory_deposit's own ledger key
--     ('<source_type>:<source_id>:<item_id>'), so a re-derived deposit is a no-op.
-- Robustness ("fail safely"): item validation/dedup happens up front; unknown or
-- malformed entries are skipped with a logged WARNING and never forfeit the metal or
-- the valid items (per-item + outer exception isolation).
create or replace function public.reward_grant(
  p_source_type text, p_source_id uuid, p_player uuid, p_base uuid, p_rewards jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  if p_rewards is null or p_rewards = '{}'::jsonb then
    return;
  end if;

  -- One grant per source. If the row already exists this is a no-op replay: neither
  -- metal nor items are re-applied. This is the primary double-deposit guard.
  insert into reward_grants (source_type, source_id, player_id, base_id, rewards)
    values (p_source_type, p_source_id, p_player, p_base, p_rewards)
    on conflict (source_type, source_id) do nothing;
  if not found then
    return;  -- already granted
  end if;

  -- 1) METAL (and any other scalar resources) → Base. Strip 'items' first: base_add_
  --    resources casts every jsonb value to double precision and would choke on an array.
  if p_base is not null then
    perform base_add_resources(p_base, p_rewards - 'items');
  end if;

  -- 2) ITEMS → Inventory. Validate + dedup up front; deposit each once with a stable key.
  --    Outer block: a malformed items array can never forfeit the metal already deposited.
  begin
    for r in
      select item_id, sum(qty)::integer as qty
      from (
        select nullif(trim(el->>'item_id'), '') as item_id,
               (el->>'quantity')::numeric        as qty
        from jsonb_array_elements(coalesce(p_rewards->'items', '[]'::jsonb)) el
      ) s
      where item_id is not null
        and qty is not null
        and qty = floor(qty)   -- integer only
        and qty > 0            -- positive only (no zero / negative)
        and qty < 1e9          -- rejects NaN and Infinity (both compare > every finite),
                               -- and keeps the sum within integer range
      group by item_id         -- duplicate entries combined deterministically
    loop
      -- Inner block: one bad item never forfeits its siblings.
      begin
        if not exists (select 1 from item_types where item_id = r.item_id) then
          raise warning 'reward_grant: skipping unknown item % (source %/%)',
            r.item_id, p_source_type, p_source_id;
          continue;
        end if;
        perform inventory_deposit(
          p_player, r.item_id, r.qty,
          p_source_type || ':' || p_source_id::text || ':' || r.item_id);
      exception when others then
        raise warning 'reward_grant: item deposit failed for % (source %/%): %',
          r.item_id, p_source_type, p_source_id, sqlerrm;
      end;
    end loop;
  exception when others then
    raise warning 'reward_grant: items bundle malformed for source %/% : %',
      p_source_type, p_source_id, sqlerrm;
  end;
end;
$$;

-- Anti-cheat: reward_grant stays revoked from clients (create-or-replace preserves the
-- 0039 lockdown ACL). The CI verify runner (service_role only; never shipped to the
-- frontend) exercises it directly, mirroring inventory_deposit / process_build_queue.
grant execute on function public.reward_grant(text, uuid, uuid, uuid, jsonb) to service_role;
