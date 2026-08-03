-- Byeharu — 0333: ITEMS HAVE A PLACE.   (rev.2 — see THE ABORTED DEPLOY below)
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE ABORTED DEPLOY (2026-08-03) — read this before touching any grant in this file.
--
-- rev.1 of this migration merged and then STOPPED ITS OWN PRODUCTION DEPLOY at check (c):
--     ERROR: 0333 (c) FAIL: anon can SELECT base_items (SQLSTATE P0001)
-- The transaction guard rolled everything back — head stayed 20260618000332, base_items/volume_m3/
-- transfer_items never existed, nothing partially applied. The assert was RIGHT; the migration was
-- wrong. It ASSERTED a posture it had never ESTABLISHED, which is the repo's own recorded lesson
-- from the 0254 danger_zones abort and the 0309 grant sweep, repeated verbatim.
--
-- THE EVIDENCE, read off production rather than reasoned about (pg_default_acl, 2026-08-03):
--     objtype 'r' (table) · owner postgres · schema public
--     default_acl = {postgres=arwdDxtm/postgres, anon=arwdDxtm/postgres,
--                    authenticated=arwdDxtm/postgres, service_role=arwdDxtm/postgres}
-- `arwdDxtm` = INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN. Every new
-- public table owned by postgres inherits ALL EIGHT for anon and authenticated at creation.
-- rev.1 revoked three of them and asserted on a fourth.
--
-- The FUNCTION default on the same project is `{postgres=X, service_role=X}` — no anon, no
-- authenticated — which is exactly why every function ACL check in (c) passed on production and only
-- the table check failed. The asymmetry is real and worth keeping in mind: functions are safe by
-- default here, tables are wide open by default.
--
-- WHY CI COULD NOT HAVE CAUGHT IT: a disposable `supabase start` has no project default ACLs, so on
-- the throwaway chain anon never held SELECT, the assert passed, and every proof was green. 0318
-- documented this same blindness across 67 public tables. The fix is not a better test — the fix is
-- that a revoke must be a SUPERSET of any default (`revoke all`), so it is correct without needing
-- to know what the default is, in both worlds.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE OWNER'S DESIGN LAWS THIS MIGRATION EXISTS TO SATISFY (stated long ago, repeated 2026-08-03):
--   1. Items are NOT unlimited — VOLUME matters. An item with no volume is a bug.
--   2. Storage is PER-PORT. Each city holds its own stock.
--   3. You can only reach a port's storage while DOCKED there. No remote retrieval, EVER.
--   4. The player moves items between the SHIP'S HOLD and the PORT'S STORAGE. That transfer is
--      the core logistics verb.
--
-- Before this migration the game contradicted 1, 2 and 3 outright: `player_inventory`
-- (player_id, item_id, quantity) was a single GLOBAL, LOCATION-LESS, WEIGHTLESS pool. There was no
-- per-port item store and there was no transfer verb of any kind — grep confirms ZERO transfer RPCs
-- in 331 migrations.
--
-- ── THE MODEL (the owner chose it explicitly; it is NOT re-litigated here) ────────────────────────
--   · `player_inventory` is REDEFINED as THE SHIP'S HOLD. Same shape, same sole writers
--     (inventory_deposit / inventory_spend, 0039) — what changes is that it now has a CAPACITY and
--     an opposite number to move things to.
--   · `base_items` (NEW) is per-port item storage, keyed to the player's `bases` row for that port.
--     `bases` has been the per-(player, location) store since 0157 and `base_resources` (0005) is
--     its RESOURCE sibling. Items are the sibling that was never built. `base_items` is a
--     BYTE-FOR-BYTE mirror of `base_resources`' posture: same column shape, same owner-read-only
--     RLS through `bases`, same "SECURITY DEFINER functions are the only writers" law.
--   · `item_types.volume_m3` is the one number per item type, catalog-set.
--   · Transfer is hold <-> that port's storage, only while docked there.
--   · The 312 existing `player_inventory` rows are NOT moved. They are already in the hold.
--
-- WHY THIS SHAPE AND NOT A PER-PORT STORE BESIDE A STILL-GLOBAL INVENTORY: that would be TWO
-- AUTHORITIES for "how much ore do I have". ONE AUTHORITY PER PLACE — the hold, or one specific
-- port — is the invariant. Every read and every write below keys on exactly one of those places.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ── WHAT CAPS THE HOLD, AND WHY (the question the owner asked; answered from PROD, not from memory)
--
-- Facts read off production on 2026-08-03 before choosing:
--   · every one of the 77 `main_ship_instances` rows has `cargo_capacity_m3` = 50 (74 alive, 3
--     destroyed). `cargo_capacity` (integer 50) and `cargo_used` (integer 0) are DEAD columns —
--     declared in 0043:55 and read/written by NOTHING in the repo. Only `cargo_capacity_m3` is live.
--   · 157 players hold `player_inventory` rows. Only **2 of them own a ship at all**. 73 players own
--     ships. The two sets are very nearly disjoint.
--   · `ship_cargo_lots` (TRADE cargo) has **0 rows game-wide**; its sole producer `market_buy`
--     (0089:135-145) is compile-dark on the client.
--
-- THE CAP CHOSEN: hold capacity = SUM of `cargo_capacity_m3` over the player's NON-DESTROYED ships.
--   · ONE authority: `main_ship_instances.cargo_capacity_m3`, the same column `market_buy` and the
--     commissioning path already use, and the same one the client already displays. No new capacity
--     column, no new config knob, nothing to keep in sync. "Make the hold bigger" stays ONE number.
--   · FLEET-SHAPED because the game is fleet-shaped ("the fleet is the only unit of movement; a ship
--     does not move"). A per-SHIP item hold would require re-keying `player_inventory` onto a ship,
--     which is IMPOSSIBLE without destroying data: 155 of the 157 item-holding players own no ship
--     to key onto. That is a measured fact, not a preference.
--   · A destroyed ship carries nothing, so it does not count.
--
-- TRADE CARGO DOES **NOT** SHARE THIS CAP — they are SEPARATE HOLDS, and here is the justification
-- the owner asked for:
--   · Different keys. `ship_cargo_lots` is keyed `main_ship_id`; `player_inventory` is keyed
--     `player_id`. They are not the same place and cannot be summed into one occupancy without
--     re-keying one of them — see above for why neither can be re-keyed here.
--   · Different catalogs. `item_types` (13 rows: loot, materials, components, progression; INTEGER
--     quantities) vs `trade_goods` (6 rows: market commodities; NUMERIC qty, volumes quoted per
--     DENOMINATION — "1 crate of Raw Ore = 1.0 m3"). They share only the literal string 'ore', and
--     it means different things on each side.
--   · Making `market_buy` fleet-wide would be WRONG: a lot physically sits on ONE hull, so its
--     per-ship check is the correct check. Making the item hold per-ship is impossible (above).
--   · THE ONE DUALITY THIS SLICE DOES NOT CLOSE, NAMED HERE SO IT IS NOT DISCOVERED LATER: a hull's
--     50 m3 is counted once for items (fleet-wide) and once for trade lots (per-ship). It is INERT
--     today — `ship_cargo_lots` has zero rows game-wide and its producer is client-dark. Closing it
--     means unifying `item_types` and `trade_goods` into one catalog with one volume column and one
--     per-ship store. That is a bigger, owner-facing change and it is deliberately NOT smuggled in
--     here; `market_buy` is left BYTE-UNTOUCHED by this migration.
--
-- WHERE THE CAP IS ENFORCED, AND WHERE IT DELIBERATELY IS NOT:
--   · ENFORCED in `transfer_items` — the one place a player DELIBERATELY loads the hold. Over
--     capacity is REFUSED with the numbers in the envelope; it is never clamped, never truncated.
--   · NOT enforced inside `inventory_deposit`. That leaf has six callers (0040 loot bundle, 0109
--     craft, 0126 recruit, 0174 salvage, 0188/0194 shipyard order + CANCEL REFUND). A raise there
--     would make combat loot destroy itself and would make a cancel-refund abort its whole
--     transaction. Incidental grants may therefore push a hold over capacity; the consequence is
--     that the player can then only UNLOAD, never load — which is exactly how a real over-full hold
--     behaves, and it loses nobody anything.
--
-- ── BACKFILL / DAY-ONE OVER-CAPACITY (nobody loses an item) ──────────────────────────────────────
-- No row moves. All 312 `player_inventory` rows stay exactly where they are — they ARE the hold.
-- Measured on production with the exact volumes set below (2026-08-03):
--   · the largest hold anywhere is 23.0 m3 (`ore x10, scrap x6`), held by several DORMANT accounts
--     that own no ship — so they are over capacity, at 23 m3 against 0;
--   · the owner's own hold is 22.7 m3 (15 pirate_alloy + 28 scrap + 6 weapon_parts) against a
--     250 m3 fleet capacity — 9% full, nowhere near the cap;
--   · of the 24 accounts that signed in within 30 days, exactly FOUR are over capacity on day one,
--     and every one of them holds the same thing: a single `scrap`, 0.5 m3, against 0 capacity
--     because they own no ship;
--   · across all 469 accounts, 155 of the 157 item-holders own no ship at all.
-- WHAT HAPPENS TO THEM: nothing is deleted, nothing is confiscated, nothing raises. Over capacity
-- is a legal STATE, not an error. They can deposit every item they hold into their port's storage
-- (that direction is always allowed — it only ever REDUCES the load); they cannot withdraw until
-- they own a ship. `get_my_hold` reports `over_capacity: true` with the real numbers so the state is
-- visible rather than mysterious. A volume cap the player cannot see would be a trap.
--
-- ── BLAST RADIUS (production is a LIVE ~30-player game) ──────────────────────────────────────────
--   ADDS:    `item_types.volume_m3`; the `base_items` table; `item_transfer_receipts`;
--            `base_items_add` / `base_items_take` / `hold_capacity_m3` / `hold_used_m3` (leaves,
--            service-role only); `transfer_items` + `get_my_hold` (authenticated RPCs).
--   CHANGES: `get_my_docked_store` — re-created from its textual head 0211:131-215 (which is
--            byte-identical to the live prod body, verified by pg_get_functiondef on 2026-08-03).
--            EVERY existing key in EVERY one of its six return branches is preserved verbatim; the
--            change is purely ADDITIVE keys, kept uniform across all six so the client parser keeps
--            ONE contract, exactly as that function's own header requires.
--   GRANTS:  the FULL posture — `revoke all ... from public, anon, authenticated` then grant back
--            exactly what is meant — on the five tables this slice's invariant rests on:
--              base_items              SELECT to authenticated only   (new; mirrors base_resources)
--              item_transfer_receipts  SELECT to authenticated only   (new; mirrors salvage_receipts)
--              player_inventory        SELECT to authenticated only   (re-issues 0039:52)
--              inventory_ledger        SELECT to authenticated only   (re-issues 0039:70)
--              item_types              SELECT to anon AND authenticated (re-issues 0039:25 — this is
--                                      a deliberate PUBLIC-READ Reference/Config catalog; revoking
--                                      anon here would break the client's catalog read)
--            `revoke all` rather than a verb list because the project default grants eight verbs and
--            a list can be short; `public` named alongside the roles because PUBLIC-held privilege
--            survives a revoke that omits it (0309). service_role is untouched — it is the definer
--            seat. On a fresh chain every one of these revokes is a no-op, so the same statements are
--            correct with and without the project defaults present.
--            `base_resources` / `base_units` / `ship_cargo_lots` carry the same drift and are
--            deliberately left for their own slice — this migration cures only what it makes
--            load-bearing.
--   TOUCHES NOT AT ALL: any cron, any combat function, any movement function, `market_buy`,
--            `ship_cargo_lots`, `base_resources`, `base_units`, and every existing
--            `player_inventory` row. No feature flag is created; the slice rides the ALREADY-LIT
--            `station_storage_enabled` (true on prod) because it IS the per-port storage feature
--            finally completed. Shipping LIT is the standing order; a new dark flag would be a
--            second dead path.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
--   (a) every item type carries a POSITIVE volume, and the CHECK that guarantees it is validated
--   (b) `base_items` mirrors `base_resources`: shape, RLS enabled, exactly one owner-scoped SELECT
--       policy, SELECT granted to authenticated and NOT anon, and NO client write grant anywhere
--   (c) ACLs, each ESTABLISHED here and then asserted: the two RPCs authenticated-only, the four
--       leaves service-role only, and client table-write revoked on all four load-bearing tables
--   (d) `transfer_items` composes the ONE authority for every fact it needs and acquires no second
--       one: the docked resolver, the ownership resolver, the ship lock, the port predicate, the
--       store resolver, and the 0039 inventory writers — and it writes `player_inventory` and
--       `base_items` through NOTHING ELSE
--   (e) `get_my_docked_store` carried through every 0211 invariant: all six branches, the dark gate,
--       the resolver chain, the storeless-port branch, and the uniform envelope shape
--   (f) the capacity leaves are derived, not stored: they read `cargo_capacity_m3` and
--       `item_types.volume_m3` and no other capacity source exists
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
begin
  if to_regclass('public.player_inventory') is null
     or to_regclass('public.item_types') is null
     or to_regclass('public.bases') is null
     or to_regclass('public.base_resources') is null then
    raise exception '0333 PRECONDITION FAIL: an inventory/base table this slice extends is absent';
  end if;

  if to_regclass('public.base_items') is not null then
    raise exception '0333 PRECONDITION FAIL: public.base_items already exists — this migration must not re-run or land over an unknown edit';
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'item_types' and column_name = 'volume_m3') then
    raise exception '0333 PRECONDITION FAIL: item_types.volume_m3 already exists — same reason';
  end if;

  -- the capacity authority must be the column this slice believes it is.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name = 'cargo_capacity_m3' and data_type = 'numeric'
                    and is_nullable = 'NO') then
    raise exception '0333 PRECONDITION FAIL: main_ship_instances.cargo_capacity_m3 is not the numeric NOT NULL capacity column — the hold has no capacity authority';
  end if;

  -- bases must already BE the per-port store (0157), or "per-port" has nothing to key on.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'bases' and column_name = 'location_id') then
    raise exception '0333 PRECONDITION FAIL: bases.location_id is missing — bases is not the per-port store this slice keys on';
  end if;

  -- every function this migration COMPOSES must exist. It invents none of them.
  if to_regprocedure('public.inventory_deposit(uuid,text,integer,text)') is null
     or to_regprocedure('public.inventory_spend(uuid,text,integer)') is null
     or to_regprocedure('public.inventory_get_balance(uuid,text)') is null
     or to_regprocedure('public.get_or_create_store(uuid,uuid)') is null
     or to_regprocedure('public.is_home_port_eligible(uuid)') is null
     or to_regprocedure('public.mainship_resolve_owned_ship(uuid,uuid)') is null
     or to_regprocedure('public.mainship_resolve_docked_location(uuid)') is null
     or to_regprocedure('public.mainship_space_lock_context(uuid,boolean)') is null
     or to_regprocedure('public.get_my_docked_store(uuid)') is null
     or to_regprocedure('public.cfg_bool(text)') is null then
    raise exception '0333 PRECONDITION FAIL: a function this migration composes is missing';
  end if;

  -- the gate this slice rides must already exist (0157). It is NOT created or flipped here.
  if not exists (select 1 from public.game_config where key = 'station_storage_enabled') then
    raise exception '0333 PRECONDITION FAIL: station_storage_enabled is absent — this slice rides that gate, it does not invent one';
  end if;
end $pre$;

-- ═══ 1. VOLUME — one number per item type, catalog-set ═══════════════════════════════════════════
-- DEFAULT 1.0 is deliberate and load-bearing: law 1 says an item with no volume is a bug, so a
-- future catalog row can never be volumeless. NOT NULL + CHECK (> 0) makes zero-volume — the
-- "infinite items" loophole — unrepresentable rather than merely discouraged.
alter table public.item_types
  add column volume_m3 numeric not null default 1.0
  constraint item_types_volume_m3_positive check (volume_m3 > 0);

-- The scale, set against the 50 m3 starter hull so the numbers mean something in play:
-- 50 m3 holds 25 ore, or 50 crystal, or 100 scrap, or 250 weapon_parts, or 1000 autocannon rounds.
-- Bulk raw material is big; refined components are small; data and progression tokens are tiny but
-- never free. The five the owner named keep exactly the values he gave.
update public.item_types t set volume_m3 = v.m3
  from (values
    -- materials — the bulk end of the scale
    ('ore',                  2.00),   -- owner-set: unrefined rock, the bulkiest thing you mine
    ('crystal',              1.00),   -- owner-set
    ('scrap',                0.50),   -- owner-set
    ('pirate_alloy',         0.50),   -- owner-set
    ('anomaly_shard',        0.20),   -- a shard, not a seam: well under a whole crystal
    -- components — refined, compact, carried by the hundred
    ('weapon_parts',         0.20),   -- owner-set; the reference point for the component class
    ('repair_parts',         0.20),   -- same class, same size
    ('engine_parts',         0.30),   -- a drive assembly is the bulkiest of the three
    -- ammunition — you carry it in quantity or it is not ammunition
    ('autocannon_rounds',    0.05),
    -- data — near-massless, never weightless (law 1)
    ('scan_data',            0.01),
    -- progression — small tokens, but an artifact core is a real object
    ('captain_memory_shard', 0.10),
    ('blueprint_fragment',   0.10),
    ('artifact_core',        0.50)
  ) as v(item_id, m3)
 where t.item_id = v.item_id;

-- ═══ 2. base_items — per-port item storage, mirroring base_resources exactly ═════════════════════
-- Column shape, FK-with-cascade, uniqueness and RLS are a deliberate byte-mirror of
-- `base_resources` (0005:31-38 / :53-58). The ONLY differences are the value domain (INTEGER
-- quantity, because `player_inventory.quantity` is integer and an item is a whole thing) and the FK
-- on `item_types`, which `base_resources.resource_code` has no equivalent of.
create table public.base_items (
  id         uuid    primary key default gen_random_uuid(),
  base_id    uuid    not null references public.bases (id) on delete cascade,
  item_id    text    not null references public.item_types (item_id),
  quantity   integer not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now(),
  unique (base_id, item_id)
);
create index base_items_base_id_idx on public.base_items (base_id);

alter table public.base_items enable row level security;

-- Owner-read through the owning base — the base_resources_select_own policy, verbatim in shape.
create policy "base_items_select_own" on public.base_items
  for select using (exists (
    select 1 from public.bases b where b.id = base_items.base_id and b.player_id = auth.uid()
  ));

-- ── ESTABLISH the WHOLE posture. REVOKE EVERYTHING FIRST, then grant back exactly what is meant. ──
-- THIS IS THE HUNK THAT ABORTED THE FIRST PRODUCTION DEPLOY OF THIS MIGRATION. rev.1 revoked only
-- insert/update/delete and then asserted that anon could not SELECT — an assertion it had never
-- established. On production the deploy stopped at its own check (c) with
-- `0333 (c) FAIL: anon can SELECT base_items`, and the transaction guard rolled the whole migration
-- back: nothing partially applied, head stayed 20260618000332.
--
-- WHY THE REVOKE MUST BE TOTAL, read off production rather than assumed (pg_default_acl, 2026-08-03):
--   objtype 'r' (table) · owner postgres · schema public
--   default_acl = {postgres=arwdDxtm/postgres, anon=arwdDxtm/postgres,
--                  authenticated=arwdDxtm/postgres, service_role=arwdDxtm/postgres}
-- `arwdDxtm` is INSERT, **SELECT**, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN. Every
-- new public table owned by postgres inherits ALL EIGHT for anon and authenticated the instant it is
-- created. rev.1 named three of them. A disposable `supabase start` carries no such default, so the
-- other five were invisible to every proof — the exact CI blindness 0318 documented across 67 tables.
--
-- `revoke all` is a SUPERSET of any default this project may ever carry, so it cannot be short by
-- construction — it does not need to know the default, which is what makes it safe against future
-- drift as well. `public` is named alongside the two roles because privilege held via the PUBLIC
-- pseudo-role survives a revoke that names only anon/authenticated (the 0309 lesson), and
-- has_table_privilege — used in the asserts below — is the only check that can see it.
-- On a fresh chain the grants do not exist and the revoke is a harmless no-op, so this one statement
-- is correct in BOTH worlds; nothing here is conditional on which world it lands in.
-- service_role is deliberately untouched: it is the server/definer seat, exactly as on base_resources.
revoke all on table public.base_items from public, anon, authenticated;

-- ...and now the intended posture, stated positively and owned by this migration rather than
-- inherited: authenticated may SELECT (RLS scopes every row to the owning player), anon may not, and
-- nobody but the SECURITY DEFINER writers may write. This mirrors base_resources (0005:58), whose
-- grant is `authenticated` only.
grant select on table public.base_items to authenticated;

-- ═══ 3. The SOLE writers of base_items (the Base-system law, 0005:3-7) ═══════════════════════════
-- Mirrors base_merge_units / base_reserve_units. Nothing else in the schema may write this table;
-- self-assert (d) proves the transfer RPC does not.
create or replace function public.base_items_add(p_base uuid, p_item text, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_base is null or p_item is null then
    raise exception 'base_items_add: base and item are required';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'base_items_add: invalid quantity %', p_qty;
  end if;
  if not exists (select 1 from public.item_types where item_id = p_item) then
    raise exception 'base_items_add: unknown item %', p_item;
  end if;

  insert into public.base_items (base_id, item_id, quantity)
    values (p_base, p_item, p_qty)
    on conflict (base_id, item_id)
    do update set quantity = base_items.quantity + excluded.quantity, updated_at = now();
end;
$$;

create or replace function public.base_items_take(p_base uuid, p_item text, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_have integer;
begin
  if p_base is null or p_item is null then
    raise exception 'base_items_take: base and item are required';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'base_items_take: invalid quantity %', p_qty;
  end if;

  -- FOR UPDATE re-check under the row lock IS the authoritative enforcement (the inventory_spend
  -- 0039:117-121 posture); a caller's friendly pre-check never is.
  select quantity into v_have from public.base_items
    where base_id = p_base and item_id = p_item for update;
  if v_have is null or v_have < p_qty then
    raise exception 'base_items_take: insufficient % (have %, need %)', p_item, coalesce(v_have, 0), p_qty;
  end if;

  update public.base_items set quantity = quantity - p_qty, updated_at = now()
    where base_id = p_base and item_id = p_item;
end;
$$;

revoke all on function public.base_items_add(uuid, text, integer)  from public, anon, authenticated;
revoke all on function public.base_items_take(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.base_items_add(uuid, text, integer)  to service_role;
grant execute on function public.base_items_take(uuid, text, integer) to service_role;

-- ═══ 4. The capacity leaves — DERIVED, never stored ══════════════════════════════════════════════
-- There is no `hold_capacity` column anywhere and there must never be one: a stored copy of a
-- derivable number is a second authority that drifts. Both leaves are STABLE and read exactly one
-- source each.
create or replace function public.hold_capacity_m3(p_player uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  -- SUM over the player's NON-DESTROYED ships. A wreck carries nothing. Zero ships -> 0 capacity,
  -- which is the honest answer, not an error (see the over-capacity note in the header).
  select coalesce((
    select sum(m.cargo_capacity_m3)
      from public.main_ship_instances m
     where m.player_id = p_player and m.status <> 'destroyed'
  ), 0)::numeric;
$$;

create or replace function public.hold_used_m3(p_player uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  -- The hold's occupancy: every carried stack at its catalog volume. Items only — trade cargo is a
  -- separate hold on purpose (see the header).
  select coalesce((
    select sum(pi.quantity * t.volume_m3)
      from public.player_inventory pi
      join public.item_types t on t.item_id = pi.item_id
     where pi.player_id = p_player and pi.quantity > 0
  ), 0)::numeric;
$$;

revoke all on function public.hold_capacity_m3(uuid) from public, anon, authenticated;
revoke all on function public.hold_used_m3(uuid)     from public, anon, authenticated;
grant execute on function public.hold_capacity_m3(uuid) to service_role;
grant execute on function public.hold_used_m3(uuid)     to service_role;

-- ═══ 5. item_transfer_receipts — per-ship idempotency (the 0174 salvage_receipts shape) ══════════
create table public.item_transfer_receipts (
  receipt_id   uuid    primary key default gen_random_uuid(),
  main_ship_id uuid    not null references public.main_ship_instances (main_ship_id),  -- NEVER player_id
  request_id   uuid    not null,
  direction    text    not null check (direction in ('to_storage', 'to_hold')),
  item_id      text    not null references public.item_types (item_id),
  base_id      uuid    not null references public.bases (id),
  location_id  uuid    not null references public.locations (id),   -- the port the move happened at
  qty          integer not null check (qty > 0),
  volume_m3    numeric not null check (volume_m3 > 0),              -- the moved volume, at move time
  created_at   timestamptz not null default now(),
  unique (main_ship_id, request_id)                                 -- per-ship idempotency key
);
create index item_transfer_receipts_main_ship_id_idx on public.item_transfer_receipts (main_ship_id);

alter table public.item_transfer_receipts enable row level security;
-- Owner-read via the owning ship (the salvage_receipts 0174:141-148 posture); authenticated, NOT
-- anon. NO client write policy/grant -> transfer_items (SECURITY DEFINER) is the sole writer.
create policy "item_transfer_receipts_select_own" on public.item_transfer_receipts
  for select using (
    exists (
      select 1 from public.main_ship_instances m
      where m.main_ship_id = item_transfer_receipts.main_ship_id
        and m.player_id = auth.uid()
    )
  );
-- Same total revoke-then-grant as base_items above, and for the same reason: this table is created
-- HERE, so it inherits the project's arwdDxtm default for anon and authenticated at creation.
revoke all on table public.item_transfer_receipts from public, anon, authenticated;
grant select on table public.item_transfer_receipts to authenticated;

-- ═══ 6. transfer_items — THE ONE AUTHORITY FOR MOVING A STACK ════════════════════════════════════
--
-- ONE RPC, not two. The two directions share the ENTIRE spine — resolve the owned ship, take the
-- per-ship lock, resolve the dock server-side, resolve the port's store, check the replay, move,
-- receipt. Splitting them would copy that spine twice, which is precisely the copy-paste the
-- no-spaghetti law forbids. The direction decides two things only: which side is decremented, and
-- whether the capacity check applies.
--
-- LAW 3 IS ENFORCED BY CONSTRUCTION, NOT BY A CHECK: there is no p_location_id parameter. The port
-- is DERIVED from the ship's validated dock via mainship_resolve_docked_location — the one shared
-- resolver (0211), which itself goes through mainship_space_validate_context and accepts only
-- 'at_location'. A caller cannot name a port at all, so "withdraw from a port I am not docked at"
-- is not a request the surface can express. The client gate is not a security boundary and is not
-- relied on anywhere below.
--
-- REJECT ORDER (the 0174 charter's envelope order; each named):
--   not_authenticated -> station_storage_disabled (gate FIRST, before ANY read) -> invalid_request
--   -> invalid_direction -> invalid_item -> invalid_quantity -> ship_not_found -> [LOCK]
--   -> not_docked -> port_has_no_storage -> idempotent_replay -> insufficient_items /
--   insufficient_stored -> hold_over_capacity -> ok
--
-- ATOMICITY: one function, one transaction. The spend, the add and the receipt commit or roll back
-- TOGETHER — any raise from an Inventory/Base leaf aborts the whole thing, so an item can never be
-- in both places or in neither.
--
-- CONCURRENCY: two locks, in this order. The per-PLAYER advisory lock (the 0078/0109/0112 house
-- idiom) comes first because the capacity check reads the WHOLE hold, which is player-scoped — a
-- per-ship lock alone would let two of one player's ships each pass the check and land the hold
-- over capacity between them, and no leaf below can re-check a capacity. The per-SHIP row lock
-- comes second and protects the replay check against a concurrent transfer on the same ship.
create or replace function public.transfer_items(
  p_main_ship_id uuid, p_direction text, p_item_id text, p_quantity numeric, p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     uuid;
  v_loc      uuid;
  v_store    uuid;
  v_qty      integer;
  v_vol      numeric;
  v_have     integer;
  v_used     numeric;
  v_cap      numeric;
  v_delta    numeric;
  v_existing public.item_transfer_receipts%rowtype;
  v_receipt  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- The gate this slice rides (0157). Reject deterministically BEFORE any ship/store/inventory read.
  if not public.cfg_bool('station_storage_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'station_storage_disabled');
  end if;

  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request');
  end if;
  if p_direction is null or p_direction not in ('to_storage', 'to_hold') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_direction');
  end if;
  if p_item_id is null or p_item_id = '' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_item');
  end if;
  -- Items are INTEGER quantities (0039 player_inventory.quantity integer): null / non-positive /
  -- fractional all reject as invalid_quantity rather than rounding. The 1e6 cap keeps the integer
  -- cast safe (the 0040 reward_grant magnitude posture).
  if p_quantity is null or p_quantity <= 0 or p_quantity <> floor(p_quantity) or p_quantity > 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
  end if;
  v_qty := p_quantity::integer;

  -- The catalog volume. An unknown item falls out here (there is no volumeless item — the column is
  -- NOT NULL with a CHECK (> 0), so a found row always yields a usable volume).
  select t.volume_m3 into v_vol from public.item_types t where t.item_id = p_item_id;
  if v_vol is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_item');
  end if;

  -- Resolve the SELECTED owned ship (ownership asserted server-side) or the sole ship (shim);
  -- UI selection is never trusted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_found');
  end if;

  -- PLAYER LOCK FIRST (the 0078/0109/0112 house idiom: advisory, per-domain, per-player, taken
  -- BEFORE any row lock). The capacity check below reads the WHOLE hold, which is player-scoped, so
  -- a per-ship lock alone would let two ships of one player each pass the check and land the hold
  -- over capacity between them. inventory_spend and base_items_take backstop the BALANCES with
  -- their own FOR UPDATE re-checks, but neither can re-check a capacity, so this is the only place
  -- that invariant can be made authoritative rather than advisory.
  perform pg_advisory_xact_lock(hashtext('item_transfer'), hashtext(v_player::text));

  -- PER-SHIP LOCK (the 0090/0174 idiom): held to txn end, so the replay check and the receipt's
  -- (main_ship_id, request_id) key are race-safe against concurrent transfers on the SAME ship.
  perform public.mainship_space_lock_context(v_ship);

  -- LAW 3, SERVER-SIDE: the port comes from the ONE shared docked resolver. Never inlined, never
  -- the client, never a parameter.
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- Only a real dockable port carries a store (the canonical 6-part predicate, reused).
  if not public.is_home_port_eligible(v_loc) then
    return jsonb_build_object('ok', false, 'reason', 'port_has_no_storage', 'location_id', v_loc);
  end if;

  -- IDEMPOTENCY: a receipt for (ship, request_id) already exists -> replay verbatim, no write, no
  -- re-move (the 0174 semantics; no payload-conflict check).
  select * into v_existing from public.item_transfer_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'direction', v_existing.direction,
      'item_id', v_existing.item_id, 'qty', v_existing.qty, 'volume_m3', v_existing.volume_m3,
      'location_id', v_existing.location_id,
      'hold_used_m3', public.hold_used_m3(v_player),
      'hold_capacity_m3', public.hold_capacity_m3(v_player));
  end if;

  -- The player's store AT THIS PORT (idempotent, race-safe; materializes an empty store on first
  -- dock exactly as get_my_docked_store already does).
  v_store := public.get_or_create_store(v_player, v_loc);

  v_delta := v_qty * v_vol;

  if p_direction = 'to_storage' then
    -- HOLD -> PORT. Always allowed on capacity grounds: it only ever REDUCES the hold's load. This
    -- is the direction that keeps an over-capacity player from being stuck.
    v_have := public.inventory_get_balance(v_player, p_item_id);
    if v_have < v_qty then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_items',
        'item_id', p_item_id, 'have', v_have, 'need', v_qty);
    end if;
    perform public.inventory_spend(v_player, p_item_id, v_qty);   -- the 0039 sole writer
    perform public.base_items_add(v_store, p_item_id, v_qty);     -- the base_items sole writer
  else
    -- PORT -> HOLD. This is the direction the capacity governs.
    select coalesce(bi.quantity, 0) into v_have from public.base_items bi
      where bi.base_id = v_store and bi.item_id = p_item_id;
    v_have := coalesce(v_have, 0);
    if v_have < v_qty then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_stored',
        'item_id', p_item_id, 'have', v_have, 'need', v_qty, 'location_id', v_loc);
    end if;

    -- CAPACITY: REFUSE, never clamp. The player asked to move N; they get N or a refusal with the
    -- numbers, never a silent partial move they did not ask for.
    v_used := public.hold_used_m3(v_player);
    v_cap  := public.hold_capacity_m3(v_player);
    if v_used + v_delta > v_cap then
      return jsonb_build_object('ok', false, 'reason', 'hold_over_capacity',
        'item_id', p_item_id, 'qty', v_qty,
        'hold_used_m3', v_used, 'hold_capacity_m3', v_cap, 'delta_m3', v_delta,
        'hold_free_m3', greatest(v_cap - v_used, 0));
    end if;

    perform public.base_items_take(v_store, p_item_id, v_qty);            -- the base_items sole writer
    -- p_key is deliberately NULL: the receipt's unique (main_ship_id, request_id) under the
    -- per-ship lock is the ONE idempotency authority for this verb. A second key in the ledger
    -- could silently swallow the deposit while base_items_take had already succeeded — i.e. it
    -- could LOSE an item — which is exactly the kind of second authority the law forbids.
    perform public.inventory_deposit(v_player, p_item_id, v_qty, null);   -- the 0039 sole writer
  end if;

  -- RECEIPT — the (main_ship_id, request_id) key finalizes idempotency atomically with the move.
  insert into public.item_transfer_receipts
    (main_ship_id, request_id, direction, item_id, base_id, location_id, qty, volume_m3)
    values (v_ship, p_request_id, p_direction, p_item_id, v_store, v_loc, v_qty, v_delta)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt,
    'direction', p_direction, 'item_id', p_item_id, 'qty', v_qty, 'volume_m3', v_delta,
    'location_id', v_loc,
    'hold_used_m3', public.hold_used_m3(v_player),
    'hold_capacity_m3', public.hold_capacity_m3(v_player));
end;
$$;

revoke execute on function public.transfer_items(uuid, text, text, numeric, uuid) from public, anon;
grant  execute on function public.transfer_items(uuid, text, text, numeric, uuid) to authenticated;

-- ═══ 7. get_my_hold — THE ONE AUTHORITY FOR THE HOLD ═════════════════════════════════════════════
-- The hold is a PLACE, so it gets exactly one read authority, the same way the docked port has one
-- (get_my_docked_store). Every m3 number the player ever sees comes from here; the client computes
-- none of them, because a client-side second copy of the capacity formula is the drift this whole
-- migration exists to prevent.
--
-- No ship argument: the hold is player-wide and its capacity is fleet-wide (see the header). It is
-- readable wherever the player is — the hold travels with them; only the PORT's storage is
-- location-gated.
create or replace function public.get_my_hold()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_items  jsonb;
  v_used   numeric;
  v_cap    numeric;
  c_empty  constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated',
      'items', c_empty, 'used_m3', 0, 'capacity_m3', 0, 'free_m3', 0, 'over_capacity', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
             'item_id', pi.item_id, 'quantity', pi.quantity,
             'volume_m3', t.volume_m3, 'stack_m3', pi.quantity * t.volume_m3)
           order by pi.item_id), c_empty)
    into v_items
    from public.player_inventory pi
    join public.item_types t on t.item_id = pi.item_id
   where pi.player_id = v_player and pi.quantity > 0;

  v_used := public.hold_used_m3(v_player);
  v_cap  := public.hold_capacity_m3(v_player);

  return jsonb_build_object(
    'ok', true,
    'items', coalesce(v_items, c_empty),
    'used_m3', v_used,
    'capacity_m3', v_cap,
    'free_m3', greatest(v_cap - v_used, 0),
    -- An honest state, never an error: a player can be over capacity (loot and refunds do not
    -- refuse), and when they are they may still unload. The client says so instead of hiding it.
    'over_capacity', v_used > v_cap);
end;
$$;

revoke execute on function public.get_my_hold() from public, anon;
grant  execute on function public.get_my_hold() to authenticated;

-- ═══ 8. get_my_docked_store — the 0211:131-215 body; the port's ITEMS join the projection ════════
-- PARITY: the body below is the textual head from 0211:131-215, byte-verified against the LIVE prod
-- definition (pg_get_functiondef, 2026-08-03) before slicing. TWO marked hunks, both purely
-- additive:
--   HUNK 1 — every one of the six return envelopes gains an 'items' key. Uniform across all six,
--            because this function's own header states the shape must be byte-identical on every
--            return so the client parser has ONE contract. Existing keys are untouched.
--   HUNK 2 — the docked-with-a-store branch reads base_items alongside base_resources/base_units,
--            in the same coalesce(jsonb_agg(... order by ...), c_empty) idiom, with the catalog
--            volume joined in so the panel never has to compute one.
-- Nothing else changes: not the dark gate, not the resolver chain, not the storeless-port branch,
-- not the ACL, not one existing key or literal.
create or replace function public.get_my_docked_store(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player    uuid := auth.uid();
  v_ship      uuid;
  v_ctx       jsonb;
  v_ok        boolean;
  v_vstate    text;
  v_loc       uuid;
  v_name      text;
  v_store     uuid;
  v_resources jsonb;
  v_units     jsonb;
  v_items     jsonb;   -- ★ 0333 HUNK 2
  c_empty     constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  end if;

  -- DARK gate: feature off → inert empty surface (panel hidden), production byte-unchanged.
  if not cfg_bool('station_storage_enabled') then
    return jsonb_build_object('state','disabled','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  end if;

  -- §2.5: resolve the SELECTED owned ship (explicit p_main_ship_id, ownership asserted server-side) or the
  -- sole ship (shim); UI selection is never trusted. Null (no ship / unowned / zero / ambiguous >1) → the
  -- existing no_main_ship projection, verbatim (was: `where player_id = v_player`, arbitrary at N>1).
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  end if;

  -- Canonical validated ship context (coherence-checked: fleet + presence + movement). SAME authority the
  -- dock-services read uses; never invents a dock from stale fields.
  v_ctx    := public.mainship_space_validate_context(v_ship);
  v_ok     := (v_ctx->>'ok')::boolean;
  v_vstate := v_ctx->>'state';

  if v_ok is true and v_vstate = 'at_location' then
    -- FLEET-GO 3c-2 (the ONE hunk): the dock comes from the ONE shared resolver instead of the inlined
    -- `f.main_ship_id = <ship>` read (NULL on a unified fleet — a docked group's hangar vanished).
    -- Dark → the resolver's per-ship fallback returns the exact row the inline read selected →
    -- byte-identical. Null keeps collapsing to the same incoherent envelope below.
    v_loc := public.mainship_resolve_docked_location(v_ship);
    if v_loc is null then
      return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
    end if;

    select l.name into v_name from public.locations l where l.id = v_loc;

    -- Only a real dockable port carries a store (canonical 6-part predicate, reused). A docked-but-not-storable
    -- location returns docked=true with an empty, storeless surface (defensive — Dock-0 only docks eligible ports).
    if not public.is_home_port_eligible(v_loc) then
      return jsonb_build_object('state','at_location','docked',true,'location_id',v_loc,'location_name',v_name,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
    end if;

    v_store := public.get_or_create_store(v_player, v_loc);

    select coalesce(jsonb_agg(jsonb_build_object('resource_code', r.resource_code, 'amount', r.amount)
                              order by r.resource_code), c_empty)
      into v_resources
      from public.base_resources r where r.base_id = v_store;

    select coalesce(jsonb_agg(jsonb_build_object('unit_type_id', u.unit_type_id, 'quantity', u.quantity)
                              order by u.unit_type_id), c_empty)
      into v_units
      from public.base_units u where u.base_id = v_store and u.quantity > 0;

    -- ★ 0333 HUNK 2: this port's own ITEM stock, with the catalog volume carried so the panel shows
    -- what a withdrawal would cost in hold space without computing a volume of its own.
    select coalesce(jsonb_agg(jsonb_build_object('item_id', i.item_id, 'quantity', i.quantity,
                                                 'volume_m3', t.volume_m3,
                                                 'stack_m3', i.quantity * t.volume_m3)
                              order by i.item_id), c_empty)
      into v_items
      from public.base_items i
      join public.item_types t on t.item_id = i.item_id
     where i.base_id = v_store and i.quantity > 0;

    return jsonb_build_object(
      'state','at_location','docked',true,
      'location_id',v_loc,'location_name',v_name,'store_id',v_store,
      'resources',coalesce(v_resources, c_empty),'units',coalesce(v_units, c_empty),
      'items',coalesce(v_items, c_empty));

  elsif v_ok is true and v_vstate in ('in_transit','in_space','destroyed') then
    return jsonb_build_object('state',v_vstate,'docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  else
    -- home / legacy_home / legacy_present / contradictory / unknown → no hangar surface.
    return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  end if;
end;
$$;

revoke all    on function public.get_my_docked_store(uuid) from public;
grant  execute on function public.get_my_docked_store(uuid) to authenticated;

-- ═══ 9. The grant posture of every table this slice's invariant rests on ═════════════════════════
-- All three carry the Supabase project-default arwdDxtm for anon AND authenticated that no migration
-- ever revoked (verified on production 2026-08-03). RLS with no write policy denies the writes
-- today, so the write half is defense in depth — but the 2026-07-20 danger_zones abort, and this
-- migration's OWN rev.1 abort, are the standing lesson: a publish slice ESTABLISHES its posture, it
-- never merely asserts one. `inventory_ledger` is here specifically because it is the idempotency
-- guard for transfer_items' deposits: a client able to pre-insert an idempotency key could make a
-- legitimate transfer silently no-op.
--
-- SAME total revoke-then-grant as the two new tables, but these three ALREADY EXIST, so the re-grant
-- is not a design choice — it REPRODUCES what a migration deliberately established, and nothing else.
-- Grepped the whole chain: `grant` on these three appears in exactly three places, all in 0039 —
--   0039:25  grant select on public.item_types       to anon, authenticated;   <- PUBLIC-READ catalog
--   0039:52  grant select on public.player_inventory to authenticated;
--   0039:70  grant select on public.inventory_ledger to authenticated;
-- so revoking everything and re-issuing exactly those three lines lands on the migration-intended
-- state and strips only the project-default drift. Anything I did not re-grant below was never
-- granted by any migration — it was inherited.
--
-- ⚠ item_types KEEPS its anon SELECT ON PURPOSE. It is Reference/Config with an `using(true)` read
-- policy (0039:24-25), the same posture as module_types/market_offers, and the client's catalog read
-- depends on it. A blind `revoke all` with no re-grant here would have been a self-inflicted outage —
-- which is exactly why this block enumerates a per-table INTENDED posture instead of applying one
-- rule to every table it touches.
revoke all on table public.player_inventory from public, anon, authenticated;
revoke all on table public.inventory_ledger from public, anon, authenticated;
revoke all on table public.item_types       from public, anon, authenticated;

grant select on table public.player_inventory to authenticated;              -- 0039:52, verbatim
grant select on table public.inventory_ledger to authenticated;              -- 0039:70, verbatim
grant select on table public.item_types       to anon, authenticated;        -- 0039:25, verbatim

-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SELF-ASSERTS — one DO block per check. Absence is FAILURE, never a pass.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── (a) every item type carries a POSITIVE volume, and the CHECK is present AND validated ────────
do $a$
declare
  v_n        integer;
  v_bad      integer;
  v_conv     boolean;
  v_default  text;
begin
  select count(*) into v_n from public.item_types;
  if v_n < 13 then
    raise exception '0333 (a) FAIL: expected at least the 13 seeded item types, found %', v_n;
  end if;

  -- LAW 1, established: not one row is volumeless or zero-volume.
  select count(*) into v_bad from public.item_types where volume_m3 is null or volume_m3 <= 0;
  if v_bad <> 0 then
    raise exception '0333 (a) FAIL: % item type(s) have no positive volume', v_bad;
  end if;

  -- the owner's five, pinned exactly as he gave them.
  if (select volume_m3 from public.item_types where item_id = 'ore')          <> 2.0
     or (select volume_m3 from public.item_types where item_id = 'crystal')      <> 1.0
     or (select volume_m3 from public.item_types where item_id = 'scrap')        <> 0.5
     or (select volume_m3 from public.item_types where item_id = 'weapon_parts') <> 0.2
     or (select volume_m3 from public.item_types where item_id = 'pirate_alloy') <> 0.5 then
    raise exception '0333 (a) FAIL: an owner-set volume does not match the value he gave';
  end if;

  -- the CHECK must EXIST and be VALIDATED (a NOT VALID constraint would let a bad row in later).
  select c.convalidated into v_conv
    from pg_constraint c
    where c.conrelid = 'public.item_types'::regclass
      and c.conname  = 'item_types_volume_m3_positive'
      and c.contype  = 'c';
  if v_conv is null then
    raise exception '0333 (a) FAIL: the volume_m3 > 0 CHECK is absent';
  end if;
  if v_conv is not true then
    raise exception '0333 (a) FAIL: the volume_m3 CHECK exists but is NOT VALIDATED';
  end if;

  -- the DEFAULT is what makes a future volumeless catalog row impossible.
  select column_default into v_default from information_schema.columns
    where table_schema = 'public' and table_name = 'item_types' and column_name = 'volume_m3';
  if v_default is null or position('1.0' in v_default) = 0 then
    raise exception '0333 (a) FAIL: volume_m3 has no 1.0 default — a new item type could arrive volumeless (got %)', coalesce(v_default, '<null>');
  end if;

  -- and the deployed CHECK, EVALUATED rather than re-typed: it must actually reject 0 and negatives.
  begin
    insert into public.item_types (item_id, name, category, volume_m3)
      values ('_0333_probe_', 'probe', 'material', 0);
    raise exception '0333 (a) FAIL: the deployed CHECK accepted volume_m3 = 0';
  exception when check_violation then
    null;  -- correct: the real constraint expression rejected it
  end;

  raise notice '0333 SELF-ASSERT (a) PASS: % item types, every one with a positive volume; the owner-set five pinned; CHECK present, validated and proven to reject zero; default 1.0 makes a volumeless item unrepresentable', v_n;
end $a$;

-- ── (b) base_items mirrors base_resources: shape, RLS, one owner-scoped SELECT policy, no writes ──
do $b$
declare
  v_n    integer;
  v_qual text;
begin
  if to_regclass('public.base_items') is null then
    raise exception '0333 (b) FAIL: public.base_items was not created';
  end if;

  -- shape parity with base_resources: id / base_id / <code> / <amount> / updated_at, same PK+FK+unique.
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='base_items' and column_name='base_id'
                    and data_type='uuid' and is_nullable='NO') then
    raise exception '0333 (b) FAIL: base_items.base_id is not the NOT NULL uuid key base_resources uses';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='base_items' and column_name='quantity'
                    and data_type='integer' and is_nullable='NO') then
    raise exception '0333 (b) FAIL: base_items.quantity is not NOT NULL integer';
  end if;

  -- ON DELETE CASCADE from bases (base_resources' rule) — a deleted store takes its items with it.
  if not exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.base_items'::regclass and c.contype = 'f'
       and c.confrelid = 'public.bases'::regclass and c.confdeltype = 'c') then
    raise exception '0333 (b) FAIL: base_items.base_id does not cascade from bases the way base_resources does';
  end if;

  -- FK on item_types: an item id that is not in the catalog (and so has no volume) is unstorable.
  if not exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.base_items'::regclass and c.contype = 'f'
       and c.confrelid = 'public.item_types'::regclass) then
    raise exception '0333 (b) FAIL: base_items.item_id is not FK-bound to item_types — an uncatalogued (volumeless) item could be stored';
  end if;

  -- one stack per (store, item) — base_resources' unique (base_id, resource_code).
  if not exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.base_items'::regclass and c.contype = 'u'
       and c.conkey @> array[
             (select attnum from pg_attribute where attrelid='public.base_items'::regclass and attname='base_id'),
             (select attnum from pg_attribute where attrelid='public.base_items'::regclass and attname='item_id')]::smallint[]) then
    raise exception '0333 (b) FAIL: base_items has no unique (base_id, item_id) — a port could hold two stacks of one item';
  end if;

  -- RLS on, and EXACTLY one policy, and it is a SELECT policy (no write policy may ever appear).
  if not (select relrowsecurity from pg_class where oid = 'public.base_items'::regclass) then
    raise exception '0333 (b) FAIL: RLS is not enabled on base_items';
  end if;
  select count(*) into v_n from pg_policies where schemaname='public' and tablename='base_items';
  if v_n <> 1 then
    raise exception '0333 (b) FAIL: base_items has % policies, expected exactly 1 (the owner-scoped SELECT)', v_n;
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='base_items'
                   and policyname='base_items_select_own' and cmd='SELECT') then
    raise exception '0333 (b) FAIL: the one base_items policy is not the owner-scoped SELECT';
  end if;

  -- ...and the policy's EXPRESSION actually scopes to the owner. A table-level grant with no policy,
  -- or a policy that exists but reads `using (true)`, is a DIFFERENT failure from a missing policy
  -- and would leak every player's port storage to every other player. Read the deployed qual, do not
  -- trust the policy's name.
  select pg_get_expr(p.polqual, p.polrelid) into v_qual
    from pg_policy p where p.polrelid = 'public.base_items'::regclass and p.polname = 'base_items_select_own';
  if v_qual is null then
    raise exception '0333 (b) FAIL: the base_items SELECT policy has no USING expression — it would admit every row';
  end if;
  if position('auth.uid()' in v_qual) = 0 or position('player_id' in v_qual) = 0
     or position('bases' in v_qual) = 0 then
    raise exception '0333 (b) FAIL: the base_items SELECT policy does not scope through bases.player_id = auth.uid() (got: %)', v_qual;
  end if;

  -- the same for the receipt ledger: RLS on, exactly one SELECT policy, scoped through the ship.
  if not (select relrowsecurity from pg_class where oid = 'public.item_transfer_receipts'::regclass) then
    raise exception '0333 (b) FAIL: RLS is not enabled on item_transfer_receipts';
  end if;
  select count(*) into v_n from pg_policies where schemaname='public' and tablename='item_transfer_receipts';
  if v_n <> 1 then
    raise exception '0333 (b) FAIL: item_transfer_receipts has % policies, expected exactly 1', v_n;
  end if;
  select pg_get_expr(p.polqual, p.polrelid) into v_qual
    from pg_policy p where p.polrelid = 'public.item_transfer_receipts'::regclass;
  if v_qual is null or position('auth.uid()' in v_qual) = 0 or position('main_ship_instances' in v_qual) = 0 then
    raise exception '0333 (b) FAIL: the item_transfer_receipts policy does not scope through the owning ship (got: %)', coalesce(v_qual,'<null>');
  end if;

  raise notice '0333 SELF-ASSERT (b) PASS: base_items mirrors base_resources — cascade from bases, FK to item_types, one stack per (store,item); both new tables have RLS on with exactly one SELECT policy whose DEPLOYED expression really scopes to the owner (bases.player_id / main_ship_instances.player_id = auth.uid())';
end $b$;

-- ── (c) ACLs, ESTABLISHED above and asserted here ────────────────────────────────────────────────
do $c$
declare
  v_t         text;
  v_g         text;
  v_bad       text;
  v_n         bigint;
  v_prev_role text;
begin
  -- the two client RPCs: authenticated YES, anon/public NO.
  if not has_function_privilege('authenticated', 'public.transfer_items(uuid,text,text,numeric,uuid)', 'execute') then
    raise exception '0333 (c) FAIL: transfer_items is not executable by authenticated';
  end if;
  if has_function_privilege('anon', 'public.transfer_items(uuid,text,text,numeric,uuid)', 'execute')
     or has_function_privilege('public', 'public.transfer_items(uuid,text,text,numeric,uuid)', 'execute') then
    raise exception '0333 (c) FAIL: transfer_items is reachable by anon/public';
  end if;
  if not has_function_privilege('authenticated', 'public.get_my_hold()', 'execute') then
    raise exception '0333 (c) FAIL: get_my_hold is not executable by authenticated';
  end if;
  if has_function_privilege('anon', 'public.get_my_hold()', 'execute')
     or has_function_privilege('public', 'public.get_my_hold()', 'execute') then
    raise exception '0333 (c) FAIL: get_my_hold is reachable by anon/public';
  end if;
  -- the carried-through 0211 ACL on the re-created read.
  if not has_function_privilege('authenticated', 'public.get_my_docked_store(uuid)', 'execute') then
    raise exception '0333 (c) FAIL: the re-created get_my_docked_store lost its authenticated grant';
  end if;

  -- the four leaves are SERVER-ONLY. A client-callable base_items_add would be an item printer.
  foreach v_g in array array['public.base_items_add(uuid,text,integer)',
                             'public.base_items_take(uuid,text,integer)',
                             'public.hold_capacity_m3(uuid)',
                             'public.hold_used_m3(uuid)'] loop
    if has_function_privilege('anon', v_g, 'execute')
       or has_function_privilege('authenticated', v_g, 'execute')
       or has_function_privilege('public', v_g, 'execute') then
      raise exception '0333 (c) FAIL: leaf % is client-callable', v_g;
    end if;
    if not has_function_privilege('service_role', v_g, 'execute') then
      raise exception '0333 (c) FAIL: leaf % is not executable by service_role', v_g;
    end if;
  end loop;

  -- ── THE WHOLE TABLE MATRIX, not just the write half. ──────────────────────────────────────────
  -- rev.1 checked three verbs and shipped; the project default grants EIGHT, and the deploy died on
  -- the SELECT it never revoked. So: every verb the default can carry x every client grantee, 5
  -- tables x 8 verbs x 3 grantees = 120 assertions, and each one is measured against a stated
  -- INTENDED posture rather than against whatever happened to be inherited.
  -- has_table_privilege is the check — it folds in privilege held via the PUBLIC pseudo-role, which
  -- information_schema.role_table_grants and a naive read of pg_class.relacl both miss (0309).
  --
  -- NOT-ALLOWED = everything, for every client grantee, on every one of the five tables...
  select string_agg(t || '.' || v || ' [' || r || ']', ', ' order by t, v, r) into v_bad
    from unnest(array['base_items', 'item_transfer_receipts', 'player_inventory',
                      'item_types', 'inventory_ledger'])                              as t
   cross join unnest(array['INSERT','SELECT','UPDATE','DELETE',
                           'TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'])              as v
   cross join unnest(array['anon', 'authenticated', 'public'])                         as r
   where has_table_privilege(r, 'public.' || t, v)
     -- ...EXCEPT the three reads a migration deliberately established (0039:25/52/70) and the two
     -- this slice establishes for its own new tables. Anything outside this allow-list is drift.
     and not (v = 'SELECT' and r = 'authenticated')                       -- all five: owner-scoped read
     and not (v = 'SELECT' and r = 'anon' and t = 'item_types');          -- the PUBLIC-READ catalog
  if v_bad is not null then
    raise exception '0333 (c) FAIL: privilege OUTSIDE the intended posture survives on: %', v_bad;
  end if;

  -- ...and the reads that MUST survive really did. A revoke that took too much is as broken as one
  -- that took too little — it would blind the hangar or the item catalog.
  select string_agg(t || ' [authenticated]', ', ' order by t) into v_bad
    from unnest(array['base_items', 'item_transfer_receipts', 'player_inventory',
                      'item_types', 'inventory_ledger']) as t
   where not has_table_privilege('authenticated', 'public.' || t, 'SELECT');
  if v_bad is not null then
    raise exception '0333 (c) FAIL: the revoke took an authenticated SELECT it must keep — lost on: %', v_bad;
  end if;
  if not has_table_privilege('anon', 'public.item_types', 'SELECT') then
    raise exception '0333 (c) FAIL: the revoke took anon SELECT on item_types — it is a PUBLIC-READ Reference/Config catalog (0039:24-25) and the client catalog read would break';
  end if;

  -- ── AND THE SAME QUESTION ANSWERED BY EXECUTION, not by reading a catalog. ────────────────────
  -- has_table_privilege reports what the ACL says; this proves what the database DOES. Each probe
  -- BECOMES the anon seat and tries the read. Permission denied (42501) is the pass. If the grant
  -- were still open the select would SUCCEED — and RLS would hand back zero rows, so a row-count
  -- check would be fooled into calling that safe — which is why the probe asserts on the RAISE, not
  -- on the count. Same "evaluate the deployed rule, never re-type it" shape as the volume CHECK in (a).
  --
  -- Verified on production before relying on any of it (2026-08-03): PostgreSQL 17.6, so MAINTAIN is
  -- a real privilege verb; anon/authenticated/service_role all exist; `postgres` is a member of anon
  -- WITH ADMIN OPTION, so the deploy role can assume the seat; and `postgres` carries BYPASSRLS,
  -- which the seat change correctly drops.
  --
  -- The role is restored via set_config('role', <saved>, true) rather than RESET ROLE: RESET returns
  -- to the SESSION user, which is only the same thing if the deploy connected as the role it is
  -- currently running as. Saving and restoring the actual GUC is exact under any connection shape.
  -- `set local` is transaction-scoped anyway, so an aborted subtransaction unwinds it regardless —
  -- the explicit restore is what keeps the SUCCESS path (the positive control) honest.
  v_prev_role := current_setting('role');   -- 'none' when no SET ROLE is active

  begin
    set local role anon;
    execute 'select count(*) from public.base_items' into v_n;
    perform set_config('role', v_prev_role, true);
    raise exception '0333 (c) FAIL: the anon seat could SELECT base_items — the table grant is still open (RLS returning 0 rows is NOT the boundary being asserted)';
  exception
    when insufficient_privilege then
      perform set_config('role', v_prev_role, true);   -- the pass: the grant is genuinely gone
  end;

  begin
    set local role anon;
    execute 'select count(*) from public.player_inventory' into v_n;
    perform set_config('role', v_prev_role, true);
    raise exception '0333 (c) FAIL: the anon seat could SELECT player_inventory';
  exception
    when insufficient_privilege then
      perform set_config('role', v_prev_role, true);
  end;

  -- THE POSITIVE CONTROL. Without it the two probes above would pass for a reason that has nothing
  -- to do with this migration — an anon seat that cannot read anything at all, or a probe that never
  -- actually changed seat, produces the same 42501. anon MUST still reach the PUBLIC-READ catalog.
  begin
    set local role anon;
    execute 'select count(*) from public.item_types' into v_n;
    perform set_config('role', v_prev_role, true);
  exception
    when insufficient_privilege then
      perform set_config('role', v_prev_role, true);
      raise exception '0333 (c) FAIL: the anon seat CANNOT read item_types — either the catalog grant was lost, or the two probes above passed vacuously because the seat can read nothing at all';
  end;

  -- and prove the seat was really restored, or every later statement in this migration would run as
  -- anon and fail in a way that points nowhere near here.
  if current_setting('role') is distinct from v_prev_role then
    raise exception '0333 (c) FAIL: the anon probes did not restore the role (now %, expected %)', current_setting('role'), v_prev_role;
  end if;

  raise notice '0333 SELF-ASSERT (c) PASS: transfer_items + get_my_hold authenticated-only; the four leaves service-role only; ALL EIGHT privileges checked across 5 tables x 3 client grantees (120 assertions) against a stated intended posture, not against whatever was inherited; the authenticated reads and the item_types PUBLIC-READ catalog both survived; and the anon SEAT was made to try the reads for real — denied on base_items and player_inventory, allowed on item_types as the positive control';
end $c$;

-- ── (d) transfer_items composes the ONE authority for every fact, and acquires no second one ─────
do $d$
declare
  v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'transfer_items';
  if v_src is null then
    raise exception '0333 (d) FAIL: transfer_items is absent';
  end if;
  -- strip comments so no probe below can be satisfied by prose alone (the 0222 vacuity lesson).
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');

  -- LAW 3: the dock comes from the ONE shared resolver, and the surface CANNOT name a port.
  if position('mainship_resolve_docked_location(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not resolve the dock through the one shared resolver';
  end if;
  -- Not a text probe of the body: the SIGNATURE ITSELF, read from the catalog, must carry no
  -- location-shaped argument. This is what makes law 3 unexpressable rather than merely checked.
  if (select pg_get_function_identity_arguments(p.oid)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname='public' and p.proname='transfer_items') ilike '%location%' then
    raise exception '0333 (d) FAIL: transfer_items has a location-shaped parameter — law 3 must be unexpressable, not merely checked';
  end if;
  if (select pg_get_function_identity_arguments(p.oid)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname='public' and p.proname='transfer_items')
     is distinct from 'p_main_ship_id uuid, p_direction text, p_item_id text, p_quantity numeric, p_request_id uuid' then
    raise exception '0333 (d) FAIL: transfer_items signature drifted from the one this slice established (got %)',
      (select pg_get_function_identity_arguments(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname='transfer_items');
  end if;

  -- ownership, the lock, and the port predicate all come from the existing authorities.
  if position('mainship_resolve_owned_ship(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not assert ownership through the one resolver';
  end if;
  if position('mainship_space_lock_context(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not take the per-ship lock';
  end if;
  -- and the PLAYER-scoped advisory lock, WITHOUT which the capacity check is only advisory: two of
  -- one player's ships could each pass it and land the hold over capacity between them.
  if position('pg_advisory_xact_lock(hashtext(''item_transfer'')' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not take the per-player advisory lock — the capacity check would not be authoritative across a player''s ships';
  end if;
  -- ORDER MATTERS (the 0112:30 law): the advisory lock is taken BEFORE any row lock, or two
  -- transactions can acquire them in opposite orders and deadlock.
  if position('pg_advisory_xact_lock(' in v_src) > position('mainship_space_lock_context(' in v_src) then
    raise exception '0333 (d) FAIL: the per-ship row lock is taken BEFORE the per-player advisory lock — inverted lock order';
  end if;
  if position('is_home_port_eligible(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not reuse the canonical port predicate';
  end if;
  if position('get_or_create_store(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not resolve the store through the one resolver';
  end if;
  if position('auth.uid()' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not derive the actor from auth.uid()';
  end if;

  -- the writes go through the sole writers and through NOTHING else.
  if position('inventory_spend(' in v_src) = 0 or position('inventory_deposit(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not move the hold through the 0039 sole writers';
  end if;
  if position('base_items_add(' in v_src) = 0 or position('base_items_take(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not move the port stock through the base_items sole writers';
  end if;
  if v_src ~* 'insert\s+into\s+public\.player_inventory'
     or v_src ~* 'update\s+public\.player_inventory'
     or v_src ~* 'delete\s+from\s+public\.player_inventory' then
    raise exception '0333 (d) FAIL: transfer_items writes player_inventory directly — a second writer';
  end if;
  if v_src ~* 'insert\s+into\s+public\.base_items'
     or v_src ~* 'update\s+public\.base_items'
     or v_src ~* 'delete\s+from\s+public\.base_items' then
    raise exception '0333 (d) FAIL: transfer_items writes base_items directly — a second writer';
  end if;
  -- and it touches nothing outside its own domain.
  if v_src ~* '(insert\s+into|update|delete\s+from)\s+public\.(base_resources|base_units|ship_cargo_lots|player_wallet|main_ship_instances|fleets)' then
    raise exception '0333 (d) FAIL: transfer_items writes a table outside the item-transfer domain';
  end if;

  -- capacity is REFUSED, never clamped: the reject envelope exists and no clamping verb appears.
  if position('hold_over_capacity' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items has no over-capacity refusal';
  end if;
  if v_src ~* 'least\s*\(\s*v_qty' or v_src ~* 'v_qty\s*:=\s*least' then
    raise exception '0333 (d) FAIL: transfer_items clamps the quantity instead of refusing';
  end if;

  -- idempotency is the receipt key, not a best-effort guess.
  if position('item_transfer_receipts' in v_src) = 0 or position('idempotent_replay' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items is not receipt-idempotent';
  end if;

  raise notice '0333 SELF-ASSERT (d) PASS: transfer_items composes the docked/ownership/lock/port/store authorities, moves both sides only through their sole writers, cannot name a port at all, refuses over-capacity without clamping, and is receipt-idempotent';
end $d$;

-- ── (e) get_my_docked_store carried through every 0211 invariant ─────────────────────────────────
do $e$
declare
  v_src text;
  v_n   integer;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_my_docked_store';
  if v_src is null then
    raise exception '0333 (e) FAIL: get_my_docked_store is absent';
  end if;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');

  -- EIGHT return envelopes (0211 had eight: two no_main_ship, disabled, the null-dock incoherent,
  -- the storeless port, the full docked return, the in_transit/in_space/destroyed branch and the
  -- else) plus the THREE aggregate builders in the docked branch = exactly 11 sites. Any other
  -- number means a branch was lost or duplicated in the re-create.
  select count(*) into v_n from regexp_matches(v_src, 'jsonb_build_object\(', 'g');
  if v_n <> 11 then
    raise exception '0333 (e) FAIL: the re-created body has % jsonb_build_object sites, expected exactly 11 — a return branch was lost or duplicated', v_n;
  end if;

  -- every carried-through state literal must still be emitted.
  if position('''no_main_ship''' in v_src) = 0
     or position('''disabled''' in v_src) = 0
     or position('''at_location''' in v_src) = 0
     or position('''incoherent_or_unavailable''' in v_src) = 0
     or position('''in_transit''' in v_src) = 0
     or position('''in_space''' in v_src) = 0
     or position('''destroyed''' in v_src) = 0 then
    raise exception '0333 (e) FAIL: a 0211 state literal is missing from the re-created body';
  end if;

  -- the dark gate, the resolver chain and the port predicate all survived.
  if position('cfg_bool(''station_storage_enabled'')' in v_src) = 0 then
    raise exception '0333 (e) FAIL: the station_storage_enabled gate was lost';
  end if;
  if position('mainship_resolve_owned_ship(' in v_src) = 0
     or position('mainship_space_validate_context(' in v_src) = 0
     or position('mainship_resolve_docked_location(' in v_src) = 0
     or position('is_home_port_eligible(' in v_src) = 0
     or position('get_or_create_store(' in v_src) = 0 then
    raise exception '0333 (e) FAIL: a 0211 resolver was lost from the re-created body';
  end if;

  -- the existing projections are untouched.
  if position('base_resources' in v_src) = 0 or position('base_units' in v_src) = 0 then
    raise exception '0333 (e) FAIL: the resources/units projections were lost';
  end if;

  -- HUNK 1: the 'items' key is on EVERY return, so the client parser keeps ONE contract — exactly
  -- eight emissions, one per envelope. Fewer means an envelope shape diverged.
  select count(*) into v_n from regexp_matches(v_src, '''items''', 'g');
  if v_n <> 8 then
    raise exception '0333 (e) FAIL: the items key appears on % sites, expected exactly 8 — it is not uniform across every envelope', v_n;
  end if;

  -- HUNK 2: the port's item stock is read from base_items, joined to the catalog for the volume.
  if position('public.base_items' in v_src) = 0 then
    raise exception '0333 (e) FAIL: the docked branch does not read base_items';
  end if;
  if position('volume_m3' in v_src) = 0 then
    raise exception '0333 (e) FAIL: the item projection carries no volume — the panel would have to compute one';
  end if;

  -- it acquired no write authority: a read function must stay a read function (get_or_create_store's
  -- lazy store materialization is the one pre-existing exception, unchanged from 0211).
  if v_src ~* '(insert\s+into|update|delete\s+from)\s+public\.(base_items|player_inventory|base_resources|base_units)' then
    raise exception '0333 (e) FAIL: the re-created read acquired a write';
  end if;

  raise notice '0333 SELF-ASSERT (e) PASS: get_my_docked_store kept all six branches, every state literal, the dark gate and the whole resolver chain; the items key is uniform across every envelope and the docked branch reads base_items with the catalog volume';
end $e$;

-- ── (f) the capacity is DERIVED from one source, and no second capacity authority exists ─────────
do $f$
declare
  v_cap  text;
  v_used text;
  v_n    integer;
begin
  select pg_get_functiondef(p.oid) into v_cap
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='hold_capacity_m3';
  select pg_get_functiondef(p.oid) into v_used
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='hold_used_m3';
  if v_cap is null or v_used is null then
    raise exception '0333 (f) FAIL: a capacity leaf is absent';
  end if;
  v_cap  := regexp_replace(v_cap,  '--[^\n]*', '', 'g');
  v_used := regexp_replace(v_used, '--[^\n]*', '', 'g');

  -- capacity reads cargo_capacity_m3 and excludes wrecks.
  if position('cargo_capacity_m3' in v_cap) = 0 then
    raise exception '0333 (f) FAIL: hold_capacity_m3 does not read cargo_capacity_m3';
  end if;
  if position('destroyed' in v_cap) = 0 then
    raise exception '0333 (f) FAIL: hold_capacity_m3 counts destroyed ships';
  end if;
  -- and it reads the DEAD integer columns from 0043 nowhere (they are a lookalike trap).
  if position('cargo_capacity ' in v_cap) <> 0 or position('cargo_used' in v_cap) <> 0 then
    raise exception '0333 (f) FAIL: hold_capacity_m3 reads the dead 0043 cargo columns';
  end if;

  -- occupancy reads the catalog volume, and only the hold.
  if position('volume_m3' in v_used) = 0 or position('player_inventory' in v_used) = 0 then
    raise exception '0333 (f) FAIL: hold_used_m3 is not the item-volume fold over the hold';
  end if;

  -- NO STORED CAPACITY COLUMN may exist anywhere — a stored copy is the drift this prevents.
  select count(*) into v_n from information_schema.columns
   where table_schema='public' and column_name in ('hold_capacity_m3','hold_used_m3','hold_capacity');
  if v_n <> 0 then
    raise exception '0333 (f) FAIL: % stored hold-capacity column(s) exist — capacity must be derived, never stored', v_n;
  end if;

  -- market_buy is left BYTE-UNTOUCHED: trade cargo keeps its own per-ship check (see the header).
  if to_regprocedure('public.market_buy(uuid,text,numeric,uuid)') is not null then
    if (select position('ship_cargo_lots' in pg_get_functiondef(to_regprocedure('public.market_buy(uuid,text,numeric,uuid)')::oid))) = 0 then
      raise exception '0333 (f) FAIL: market_buy no longer checks ship_cargo_lots — this migration must not have touched it';
    end if;
  end if;

  raise notice '0333 SELF-ASSERT (f) PASS: hold capacity is DERIVED from cargo_capacity_m3 over non-destroyed ships, occupancy from item_types.volume_m3 over the hold; no stored capacity column exists; market_buy untouched';
end $f$;

-- ── final ────────────────────────────────────────────────────────────────────────────────────────
do $z$
declare
  v_over integer;
  v_tot  integer;
begin
  select count(*) into v_tot from public.player_inventory;
  -- Report, do not act. Nobody's items are moved, clamped or deleted by this migration.
  select count(*) into v_over from (
    select pi.player_id
      from public.player_inventory pi
      join public.item_types t on t.item_id = pi.item_id
     where pi.quantity > 0
     group by pi.player_id
    having sum(pi.quantity * t.volume_m3) > public.hold_capacity_m3(pi.player_id)
  ) s;
  raise notice '0333 BACKFILL: % player_inventory rows left exactly where they are (they ARE the hold). % player(s) are over capacity on day one — nothing was deleted, clamped or confiscated; they can still deposit to a port, and get_my_hold reports over_capacity honestly.', v_tot, v_over;
  raise notice '0333 SELF-ASSERT PASS: items have a place — a volume, a per-port store, and one docked-only transfer verb between the hold and that port.';
end $z$;

commit;
